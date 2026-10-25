#!/usr/bin/env python3
"""Временный порог eviction для части 7 на существующем worker kind-lab4.

Сначала применить обычный chart/values.yaml и дождаться готовности shop.
prepare: порог на 512 MiB ниже текущего memory.available, без запуска нагрузки.
Затем применить chart/values-memory-pressure.yaml и наблюдать Evicted.
restore: вернуть исходную конфигурацию kubelet; затем применить обычный чарт.
Значение memory.available берётся у kubelet, а не из free на хосте.
"""

import argparse
import json
import subprocess
import sys
import time

import yaml

NODE = "lab4-worker"
CONFIG = "/var/lib/kubelet/config.yaml"
BACKUP = "/var/lib/kubelet/config.yaml.before-lab4-memory-pressure"
KUBECTL = ["kubectl", "--context", "kind-lab4", "--request-timeout=15s"]
MIB = 1024**2


def run(command, *, data=None):
    return subprocess.check_output(command, input=data, text=True, timeout=45)


def api(path):
    return json.loads(run(KUBECTL + ["get", "--raw=" + path]))


def restart_and_check(expected):
    run(["docker", "exec", NODE, "systemctl", "restart", "kubelet"])
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            config = api(f"/api/v1/nodes/{NODE}/proxy/configz")["kubeletconfig"]
            if config.get("evictionHard", {}).get("memory.available") == expected:
                print("kubelet применил memory.available:", expected or "порог отсутствует")
                return
        except (subprocess.SubprocessError, KeyError, ValueError):
            pass
        time.sleep(2)
    raise RuntimeError("Не подтверждена загрузка конфигурации kubelet; резервная копия сохранена")


def prepare():
    exists = subprocess.run(
        ["docker", "exec", NODE, "test", "-e", BACKUP], check=False, timeout=15
    )
    if exists.returncode == 0:
        raise RuntimeError("Подготовка уже выполнена: сначала запустите restore")
    if exists.returncode != 1:
        raise RuntimeError("Не удалось проверить резервную копию на worker")

    for name, replicas in [("shop-api", 3), ("shop-batch", 1)]:
        deployment = api(f"/apis/apps/v1/namespaces/default/deployments/{name}")
        status = deployment.get("status", {})
        if (deployment["spec"]["replicas"] != replicas
                or status.get("readyReplicas", 0) != replicas
                or status.get("updatedReplicas", 0) != replicas
                or status.get("replicas", 0) != replicas
                or status.get("observedGeneration", 0) < deployment["metadata"]["generation"]):
            raise RuntimeError("Сначала примените обычный чарт и дождитесь 3 API и 1 batch")
        if name == "shop-batch":
            env = deployment["spec"]["template"]["spec"]["containers"][0].get("env", [])
            if next((e.get("value") for e in env if e["name"] == "MEMORY_MIB"), None) != "64":
                raise RuntimeError("Сначала верните MEMORY_MIB=64 обычным чартом")

    node = api(f"/api/v1/nodes/{NODE}")
    conditions = {c["type"]: c["status"] for c in node["status"]["conditions"]}
    if conditions.get("Ready") != "True" or conditions.get("MemoryPressure") != "False":
        raise RuntimeError("Worker должен быть Ready и без MemoryPressure")

    host_available = next(
        int(line.split()[1]) * 1024
        for line in open("/proc/meminfo") if line.startswith("MemAvailable:")
    )
    if host_available < 4 * 1024**3:
        raise RuntimeError("На хосте меньше 4 GiB доступной памяти; эксперимент не подготовлен")

    available = api(f"/api/v1/nodes/{NODE}/proxy/stats/summary")["node"]["memory"]["availableBytes"]
    threshold_mib = available // MIB - 512
    if threshold_mib < 1024:
        raise RuntimeError("Недостаточно свободной памяти worker для выбранного эксперимента")
    config = yaml.safe_load(run(["docker", "exec", NODE, "cat", CONFIG]))
    if "memory.available" in config.get("evictionHard", {}):
        raise RuntimeError("У worker уже задан memory.available; автоматическая замена отменена")
    config.setdefault("evictionHard", {})["memory.available"] = f"{threshold_mib}Mi"
    run(["docker", "exec", NODE, "cp", "-p", CONFIG, BACKUP])
    run(["docker", "exec", "-i", NODE, "sh", "-c", 'cat > "$1"', "sh", CONFIG],
        data=yaml.safe_dump(config, sort_keys=False))
    restart_and_check(f"{threshold_mib}Mi")
    print(f"До нагрузки доступно {available / MIB:.0f} MiB; порог {threshold_mib} MiB.")
    print("При снижении примерно на 512 MiB kubelet начнёт eviction.")
    print("Это повышенный учебный порог, а не исчерпание физической памяти компьютера.")
    print('Теперь примените values-memory-pressure.yaml. После первого eviction запустите restore.')


def restore():
    original = run(["docker", "exec", NODE, "cat", BACKUP])
    expected = yaml.safe_load(original).get("evictionHard", {}).get("memory.available")
    run(["docker", "exec", NODE, "cp", "-p", BACKUP, CONFIG])
    restart_and_check(expected)
    run(["docker", "exec", NODE, "rm", BACKUP])
    print("Исходная конфигурация worker восстановлена.")
    print("Теперь примените обычный чарт без values-memory-pressure.yaml, чтобы вернуть batch к 64 MiB.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "restore"])
    args = parser.parse_args()
    try:
        {"prepare": prepare, "restore": restore}[args.action]()
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, RuntimeError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        print("Если конфигурация уже менялась, используйте restore; резервная копия находится на worker.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
