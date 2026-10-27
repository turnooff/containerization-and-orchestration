"""digest-exporter — метрики процесса «дайджест роста спроса» в формате Prometheus.

Источники:
  * n8n REST API (executions с данными) — запуски, аномалии/отчёты, вызовы модели;
  * папка ./reports (только чтение) — доля отчётов «причина не найдена».

Данные обновляются в фоне раз в REFRESH_SECONDS, /metrics отдаёт последний снимок.
"""

import json
import os
import re
import threading
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from prometheus_client import Gauge, start_http_server

N8N_URL = os.environ.get("N8N_URL", "http://n8n:5678")
N8N_API_KEY = os.environ["N8N_API_KEY"]
WORKFLOW_NAME = os.environ.get("WORKFLOW_NAME", "Demand spike digest")
REPORTS_DIR = Path(os.environ.get("REPORTS_DIR", "/reports"))
DAILY_QUOTA = int(os.environ.get("MODEL_DAILY_QUOTA", "50"))
REFRESH_SECONDS = int(os.environ.get("REFRESH_SECONDS", "30"))
MAX_EXECUTIONS = int(os.environ.get("MAX_EXECUTIONS", "100"))

# Имена нод в workflow (их можно переименовать — тогда поправить env)
NODE_FIND = os.environ.get("NODE_FIND", "Find anomalies")
NODE_WRITE = os.environ.get("NODE_WRITE", "Read/Write Files from Disk")
MODEL_NODE_MARKER = os.environ.get("MODEL_NODE_MARKER", "Chat Model")

g_api_up = Gauge("digest_n8n_api_up", "1, если n8n API ответил при последнем обновлении")
g_last_success = Gauge("digest_last_success_timestamp_seconds", "Время окончания последнего успешного запуска workflow")
g_exec_24h = Gauge("digest_executions_24h", "Запуски workflow за последние 24 часа", ["status"])
g_found = Gauge("digest_last_run_anomalies_found", "Сколько аномалий нашёл последний завершённый запуск")
g_written = Gauge("digest_last_run_reports_written", "Сколько отчётов записал последний завершённый запуск")
g_calls_per_item = Gauge("digest_last_run_model_calls_per_item", "Вызовы модели на один товар в последнем завершённом запуске")
g_calls_today = Gauge("digest_model_calls_today", "Вызовы модели workflow с 00:00 UTC (момент сброса квоты OpenRouter)")
g_quota = Gauge("digest_model_daily_quota", "Дневная квота бесплатных запросов к модели")
g_reports = Gauge("digest_reports_total", "Всего файлов отчётов в ./reports")
g_not_found = Gauge("digest_reports_cause_not_found_total", "Отчёты, где ни одна гипотеза не подтвердилась")
g_quota.set(DAILY_QUOTA)


def api(path: str) -> dict:
    req = urllib.request.Request(f"{N8N_URL}/api/v1{path}", headers={"X-N8N-API-KEY": N8N_API_KEY})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def ts(s: str | None) -> float | None:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() if s else None


def items_out(runs: list) -> int:
    """Сколько элементов суммарно вышло из ноды по всем её запускам (в цикле их несколько)."""
    total = 0
    for r in runs or []:
        for branch in (r.get("data") or {}).get("main") or []:
            total += len(branch or [])
    return total


def collect_executions() -> None:
    wf = [w for w in api("/workflows?limit=100")["data"] if w["name"] == WORKFLOW_NAME]
    if not wf:
        raise RuntimeError(f"workflow {WORKFLOW_NAME!r} не найден")
    wid = wf[0]["id"]

    execs, cursor = [], None
    while len(execs) < MAX_EXECUTIONS:
        page = api(f"/executions?workflowId={wid}&includeData=true&limit=50" + (f"&cursor={cursor}" if cursor else ""))
        execs += page["data"]
        cursor = page.get("nextCursor")
        if not cursor:
            break

    now = time.time()
    day_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    by_status: dict[str, int] = {}
    calls_today = 0
    last_success = None
    last_finished = None

    for e in execs:  # API отдаёт от новых к старым
        started, stopped = ts(e.get("startedAt")), ts(e.get("stoppedAt"))
        run_data = ((e.get("data") or {}).get("resultData") or {}).get("runData") or {}
        model_calls = sum(len(v) for k, v in run_data.items() if MODEL_NODE_MARKER in k)

        if started and started >= now - 86400:
            by_status[e["status"]] = by_status.get(e["status"], 0) + 1
        if started and started >= day_start:
            calls_today += model_calls
        if e["status"] == "success" and stopped and last_success is None:
            last_success = stopped
        if stopped and last_finished is None:
            last_finished = (run_data, model_calls)

    for status in ("success", "error", "running", "canceled", "crashed"):
        g_exec_24h.labels(status).set(by_status.get(status, 0))
    g_calls_today.set(calls_today)
    if last_success:
        g_last_success.set(last_success)
    if last_finished:
        run_data, model_calls = last_finished
        found = items_out(run_data.get(NODE_FIND))
        g_found.set(found)
        g_written.set(items_out(run_data.get(NODE_WRITE)))
        g_calls_per_item.set(model_calls / found if found else 0)


CONFIRMED = re.compile(r"(?<!не )подтверждена")


def cause_not_found(text: str) -> bool:
    low = text.lower()
    if "причина не найдена" in low:
        return True
    rows = [l.replace("*", "") for l in low.splitlines() if re.match(r"\|\s*[1-4]\s*\|", l)]
    return bool(rows) and not any(CONFIRMED.search(r) for r in rows)


def collect_reports() -> None:
    files = list(REPORTS_DIR.glob("*.md"))
    g_reports.set(len(files))
    g_not_found.set(sum(cause_not_found(f.read_text(encoding="utf-8", errors="replace")) for f in files))


def loop() -> None:
    while True:
        try:
            collect_executions()
            g_api_up.set(1)
        except Exception as exc:  # экспортер не должен падать из-за недоступного n8n
            g_api_up.set(0)
            print(f"n8n API error: {exc}", flush=True)
        try:
            collect_reports()
        except Exception as exc:
            print(f"reports error: {exc}", flush=True)
        time.sleep(REFRESH_SECONDS)


if __name__ == "__main__":
    start_http_server(9200)
    print("digest-exporter listening on :9200", flush=True)
    loop()
