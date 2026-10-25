#!/usr/bin/env python3
"""Управляемый опыт eviction на worker kind-lab4.

prepare: сохранить конфигурацию и рассчитать порог на обычном лёгком batch.
Затем применить values-memory-pressure.yaml с --wait.
trigger: проверить измерения тяжёлого batch, включить мягкий порог с задержкой
1 минута, дождаться первого eviction и автоматически восстановить kubelet.
restore: аварийное восстановление. Потребление batch возвращается обычным Helm-профилем.
"""

import argparse
from datetime import datetime, timezone
import json
import subprocess
import sys
import time

import yaml

NODE = "lab4-worker"
CONFIG = "/var/lib/kubelet/config.yaml"
BACKUP = "/var/lib/kubelet/config.yaml.before-lab4-memory-pressure"
STATE = BACKUP + ".json"
KUBECTL = ["kubectl", "--context", "kind-lab4", "--request-timeout=15s"]
MIB = 1024**2


class SampleNotReady(RuntimeError):
    """Контейнер или его измерения ещё не готовы; давление включать рано."""


def run(command, *, data=None):
    return subprocess.check_output(command, input=data, text=True, timeout=45,
                                   stderr=subprocess.PIPE)


def api(path):
    return json.loads(run(KUBECTL + ["get", "--raw=" + path]))


def read_file(path):
    return run(["docker", "exec", NODE, "cat", path])


def write_file(path, data):
    run(["docker", "exec", "-i", NODE, "sh", "-c", 'cat > "$1"', "sh", path], data=data)


def backup_exists():
    result = subprocess.run(["docker", "exec", NODE, "test", "-e", BACKUP], timeout=15)
    if result.returncode not in (0, 1):
        raise RuntimeError("Не удалось проверить резервную копию на worker")
    return result.returncode == 0


def memory_settings(config):
    return {key: (config.get(key) or {}).get("memory.available")
            for key in ("evictionHard", "evictionSoft", "evictionSoftGracePeriod")}


def restart_and_check(expected):
    run(["docker", "exec", NODE, "systemctl", "restart", "kubelet"])
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            config = api(f"/api/v1/nodes/{NODE}/proxy/configz")["kubeletconfig"]
            if memory_settings(config) == memory_settings(expected):
                print("kubelet подтвердил настройки памяти:", memory_settings(config), flush=True)
                return
        except (subprocess.SubprocessError, KeyError, ValueError):
            pass
        time.sleep(2)
    raise RuntimeError("Не подтверждена загрузка конфигурации kubelet; резервная копия сохранена")


def ready_deployment(name, replicas):
    deployment = api(f"/apis/apps/v1/namespaces/default/deployments/{name}")
    status = deployment.get("status", {})
    if (deployment["spec"]["replicas"] != replicas
            or any(status.get(key, 0) != replicas
                   for key in ("readyReplicas", "updatedReplicas", "replicas"))
            or status.get("observedGeneration", 0) < deployment["metadata"]["generation"]):
        raise RuntimeError(f"Дождитесь готовности {replicas} реплик {name} и окончания rollout")
    return deployment


def memory_env(deployment):
    env = deployment["spec"]["template"]["spec"]["containers"][0].get("env", [])
    return next((entry.get("value") for entry in env if entry["name"] == "MEMORY_MIB"), None)


def check_node():
    node = api(f"/api/v1/nodes/{NODE}")
    conditions = {c["type"]: c["status"] for c in node["status"]["conditions"]}
    if conditions.get("Ready") != "True" or conditions.get("MemoryPressure") != "False":
        raise RuntimeError("Worker должен быть Ready и без MemoryPressure")
    return node


def check_host():
    with open("/proc/meminfo") as source:
        available = next(int(line.split()[1]) * 1024 for line in source
                         if line.startswith("MemAvailable:"))
    if available < 4 * 1024**3:
        raise RuntimeError("На хосте меньше 4 GiB доступной памяти; опыт отменён")


def prepare():
    if backup_exists():
        raise RuntimeError("Подготовка уже выполнена: сначала restore и обычный Helm-профиль")
    ready_deployment("shop-api", 3)
    if memory_env(ready_deployment("shop-batch", 1)) != "64":
        raise RuntimeError("Сначала верните MEMORY_MIB=64 обычным Helm-профилем")
    node = check_node()
    check_host()
    config = yaml.safe_load(read_file(CONFIG))
    live = api(f"/api/v1/nodes/{NODE}/proxy/configz")["kubeletconfig"]
    if any(memory_settings(config).values()) or any(memory_settings(live).values()):
        raise RuntimeError("У worker уже задан порог памяти; автоматическая замена отменена")
    available = api(f"/api/v1/nodes/{NODE}/proxy/stats/summary")["node"]["memory"]["availableBytes"]
    threshold_mib = available // MIB - 512
    if threshold_mib < 1024:
        raise RuntimeError("Недостаточно свободной памяти worker для опыта")
    state = {"node_uid": node["metadata"]["uid"], "threshold_mib": threshold_mib}
    run(["docker", "exec", NODE, "cp", "-p", CONFIG, BACKUP])
    write_file(STATE, json.dumps(state))
    print(f"Порог рассчитан: {threshold_mib} MiB, но ещё НЕ включён.", flush=True)
    print("Примените values-memory-pressure.yaml с --wait --timeout 5m.")
    print("Когда тяжёлый batch готов, запустите этот скрипт с trigger.")


def batch_sample(summary, pods):
    """Требуем свежие данные всех подов и готовый batch с самым низким приоритетом."""
    active = [pod for pod in pods if pod["spec"].get("nodeName") == NODE
              and pod["status"].get("phase") not in ("Succeeded", "Failed")
              and not pod["metadata"].get("deletionTimestamp")]
    stats = {pod["podRef"]["uid"]: pod for pod in summary.get("pods", [])}
    batches = [pod for pod in active
               if pod["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "batch"
               and pod["metadata"].get("namespace") == "default"]
    if len(batches) != 1:
        raise SampleNotReady("На worker должен быть ровно один активный batch")
    batch = batches[0]
    if not any(c["type"] == "Ready" and c["status"] == "True"
               for c in batch["status"].get("conditions", [])):
        raise SampleNotReady("Тяжёлый batch ещё не готов")
    now = datetime.now(timezone.utc)
    for pod in active:
        memory = stats.get(pod["metadata"]["uid"], {}).get("memory", {})
        stamp = memory.get("time")
        if (memory.get("workingSetBytes") is None or not stamp
                or not 0 <= (now - datetime.fromisoformat(stamp.replace("Z", "+00:00"))).total_seconds() <= 30):
            raise SampleNotReady("Нет свежих измерений памяти: " + pod["metadata"]["name"])
    used = stats[batch["metadata"]["uid"]]["memory"]["workingSetBytes"]
    if used < 1024 * MIB:
        raise SampleNotReady("batch ещё не занял 1 GiB; ожидаю обновления измерений")
    if batch["status"].get("qosClass") != "Burstable":
        raise RuntimeError("Для опыта batch должен быть Burstable")
    containers = batch["spec"]["containers"]
    if (len(containers) != 1
            or containers[0].get("resources", {}).get("requests", {}).get("memory") != "64Mi"
            or containers[0].get("resources", {}).get("limits", {}).get("memory") != "2Gi"):
        raise RuntimeError("Примените профиль values-memory-pressure.yaml: request 64Mi, limit 2Gi")
    if any(pod["metadata"]["uid"] != batch["metadata"]["uid"]
           and pod["spec"].get("priority", 0) <= batch["spec"].get("priority", 0)
           for pod in active):
        raise RuntimeError("На worker есть другой под с таким же или меньшим приоритетом")
    return batch["metadata"]["uid"], used


def evictions():
    events = [event for event in api("/api/v1/events?fieldSelector=reason%3DEvicted")["items"]
              if event.get("source", {}).get("host") == NODE
              or event.get("reportingInstance") == NODE]
    return sorted(events, key=lambda event: event.get("lastTimestamp")
                  or event["metadata"].get("creationTimestamp", ""))


def trigger():
    if not backup_exists():
        raise RuntimeError("Сначала выполните prepare на обычном лёгком batch")
    state = json.loads(read_file(STATE))
    node = check_node()
    if node["metadata"]["uid"] != state["node_uid"]:
        raise RuntimeError("Нода пересоздана после prepare; выполните restore")
    check_host()
    ready_deployment("shop-api", 3)
    if memory_env(ready_deployment("shop-batch", 1)) != "1280":
        raise RuntimeError("Сначала примените values-memory-pressure.yaml и дождитесь готовности")
    threshold = state["threshold_mib"] * MIB
    batch_uid = None
    # Ready не гарантирует, что cAdvisor уже измерил заполненный буфер.
    deadline = time.monotonic() + 120
    consecutive = 0
    while consecutive < 3:
        if time.monotonic() >= deadline:
            raise RuntimeError("За 2 минуты не получены устойчивые измерения; порог не включён")
        summary = api(f"/api/v1/nodes/{NODE}/proxy/stats/summary")
        pods = api("/api/v1/pods")["items"]
        try:
            uid, used = batch_sample(summary, pods)
        except SampleNotReady as exc:
            consecutive = 0
            print(f"Порог ещё не включён: {exc}.", flush=True)
            time.sleep(10)
            continue
        if batch_uid is not None and uid != batch_uid:
            raise RuntimeError("batch сменился во время проверки; повторите trigger")
        batch_uid = uid
        if summary["node"]["memory"]["availableBytes"] >= threshold:
            raise RuntimeError("Нагрузка не пересекла рассчитанный порог; верните обычный профиль и повторите prepare")
        consecutive += 1
        print(f"Измерение {consecutive}/3: batch использует {used / MIB:.0f} MiB.", flush=True)
        if consecutive < 3:
            time.sleep(10)
    before = {e["metadata"]["uid"]: e.get("count", 1) for e in evictions()}
    config = yaml.safe_load(read_file(BACKUP))
    config.setdefault("evictionSoft", {})["memory.available"] = f'{state["threshold_mib"]}Mi'
    config.setdefault("evictionSoftGracePeriod", {})["memory.available"] = "1m0s"
    config["evictionMaxPodGracePeriod"] = 0
    print("Включаю мягкий порог. Eviction возможен после минуты непрерывного давления.", flush=True)
    print("После первого eviction порог восстановится автоматически. Ctrl+C также запускает восстановление.", flush=True)
    try:
        write_file(CONFIG, yaml.safe_dump(config, sort_keys=False))
        restart_and_check(config)
        deadline = time.monotonic() + 180
        last_report = 0
        while time.monotonic() < deadline:
            for event in evictions():
                if event.get("count", 1) <= before.get(event["metadata"]["uid"], 0):
                    continue
                print("Evicted:", event["involvedObject"]["name"], event.get("message"), flush=True)
                if event["involvedObject"]["uid"] != batch_uid:
                    raise RuntimeError("Первым выселен другой под; опыт остановлен, результат требует разбора")
                print("Первой жертвой стал проверенный тяжёлый batch.", flush=True)
                return
            if time.monotonic() - last_report >= 10:
                print("Ожидаю eviction; смотрите MemoryPressure и SLA в Grafana…", flush=True)
                last_report = time.monotonic()
            time.sleep(2)
        raise RuntimeError("За 3 минуты eviction не получен; порог будет восстановлен")
    finally:
        restore()


def restore():
    if not backup_exists():
        print("Резервной копии нет: этому запуску нечего восстанавливать.", flush=True)
        return
    original = read_file(BACKUP)
    config = yaml.safe_load(original)
    write_file(CONFIG, original)
    restart_and_check(config)
    run(["docker", "exec", NODE, "rm", "-f", BACKUP, STATE])
    print("Исходная конфигурация worker восстановлена.", flush=True)
    print("Верните обычный Helm-профиль, чтобы снизить потребление batch до 64 MiB.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "trigger", "restore"])
    args = parser.parse_args()
    try:
        {"prepare": prepare, "trigger": trigger, "restore": restore}[args.action]()
    except KeyboardInterrupt:
        print("Остановлено. Верните обычный Helm-профиль; при необходимости выполните restore.", file=sys.stderr)
        return 130
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, RuntimeError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            print(exc.stderr.strip(), file=sys.stderr)
        print("При необходимости выполните restore и верните обычный Helm-профиль.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
