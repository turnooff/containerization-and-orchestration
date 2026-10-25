#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help ]]; then
  cat <<'HELP'
Запуск из корня репозитория:
  bash "lab 4/run-k6.sh" cpu
  bash "lab 4/run-k6.sh" memory

Параметры по умолчанию: RATE=10 DURATION=8m SLA_P95_MS=300 SLA_SUCCESS_RATE=0.99
Короткая проверка без перегрузки:
  RATE=2 DURATION=20s bash "lab 4/run-k6.sh" smoke

Скрипт только создаёт заказы и сохраняет измерения. Он не переключает Helm-профили.
Пока k6 работает, в другом терминале повторите условия части 6 или 7.
Для сравнения нужны участки обычной работы, перегрузки и восстановления.
После теста HTML-графики, JSON-метрики и события находятся в reports/sla/<имя-прогона>/.
Экспорт HTML не требует открытого браузера или работающей Grafana.
HELP
  exit 0
fi

lab4_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
run_mode=${1:-baseline}
if [[ ! $run_mode =~ ^[a-zA-Z0-9_-]+$ ]]; then
  printf 'Имя прогона может содержать только буквы, цифры, _ и -.\n' >&2
  exit 2
fi
if (( $# > 1 )); then
  printf 'Ожидается одно имя прогона. См. --help.\n' >&2
  exit 2
fi

rate=${RATE:-10}
duration=${DURATION:-8m}
sla_p95_ms=${SLA_P95_MS:-300}
sla_success_rate=${SLA_SUCCESS_RATE:-0.99}
node_container=lab4-control-plane
k6_image='grafana/k6@sha256:e66db15b860113878fa74670e31f5e274830b7b6e42c8bff28b2f2d86a257603'
kubectl_lab4=(kubectl --context kind-lab4 --request-timeout=15s)

# Сеть существующей kind-ноды даёт доступ к ClusterIP Service без port-forward.
# Сам k6 работает отдельным Docker-контейнером и не становится жертвой eviction в worker.
service_ip=$("${kubectl_lab4[@]}" -n default get service shop-api -o jsonpath='{.spec.clusterIP}')
if [[ -z $service_ip || $service_ip == None ]]; then
  printf 'У shop-api нет ClusterIP.\n' >&2
  exit 1
fi
if [[ $(docker inspect "$node_container" --format '{{.State.Running}}') != true ]]; then
  printf 'Контейнер %s должен быть запущен.\n' "$node_container" >&2
  exit 1
fi

mkdir -p -- "$lab4_dir/reports/sla"
report_dir=$(mktemp -d "$lab4_dir/reports/sla/${run_mode}-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
run_label="lab4-sla-$(basename -- "$report_dir")"
docker_name="lab4-k6-$(basename -- "$report_dir" | tr '[:upper:]' '[:lower:]')"
events_pid=''

cleanup() {
  if [[ -n $events_pid ]]; then
    kill "$events_pid" 2>/dev/null || true
    wait "$events_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'docker stop --signal SIGINT --timeout 15 "$docker_name" >/dev/null 2>&1 || true; exit 130' INT TERM

printf 'Результаты: %s\n' "$report_dir"
printf 'Нагрузка: %s заказов/с в течение %s\n' "$rate" "$duration"
printf 'Во втором терминале можно включать и выключать перегрузку.\n'
{
  printf 'started_at_utc=%s\n' "$(date -u +%FT%TZ)"
  printf 'mode=%s\nrate=%s\nduration=%s\np95_limit_ms=%s\nminimum_success_rate=%s\n' \
    "$run_mode" "$rate" "$duration" "$sla_p95_ms" "$sla_success_rate"
  printf 'base_url=http://%s\ncustomer=%s\nk6_image=%s\n' "$service_ip" "$run_label" "$k6_image"
} > "$report_dir/run.txt"

"${kubectl_lab4[@]}" -n default get pods -o wide > "$report_dir/pods-before.txt"
"${kubectl_lab4[@]}" get events -A -o json > "$report_dir/events-before.json"
kubectl --context kind-lab4 get events -A --watch-only \
  -o custom-columns='TIME:.lastTimestamp,NAMESPACE:.metadata.namespace,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' \
  > "$report_dir/events-live.log" 2> "$report_dir/events-watch-errors.log" &
events_pid=$!

set +e
docker run --rm --init --name "$docker_name" \
  --network "container:$node_container" \
  --user "$(id -u):$(id -g)" --cpus=1 --memory=512m \
  --mount "type=bind,source=$lab4_dir/k6-sla.js,target=/scripts/k6-sla.js,readonly" \
  --mount "type=bind,source=$report_dir,target=/out" \
  -e "BASE_URL=http://$service_ip" \
  -e "RATE=$rate" -e "DURATION=$duration" \
  -e "SLA_P95_MS=$sla_p95_ms" -e "SLA_SUCCESS_RATE=$sla_success_rate" \
  -e "RUN_LABEL=$run_label" -e SUMMARY_PATH=/out/summary.json \
  -e K6_WEB_DASHBOARD=true -e K6_WEB_DASHBOARD_PORT=-1 \
  -e K6_WEB_DASHBOARD_PERIOD=5s -e K6_WEB_DASHBOARD_EXPORT=/out/report.html \
  "$k6_image" run --out json=/out/metrics.json /scripts/k6-sla.js \
  2>&1 | tee "$report_dir/k6.log"
k6_exit=${PIPESTATUS[0]}
set -e

"${kubectl_lab4[@]}" -n default get pods -o wide > "$report_dir/pods-after.txt" || true
"${kubectl_lab4[@]}" get events -A -o json > "$report_dir/events-after.json" || true
{
  printf 'finished_at_utc=%s\n' "$(date -u +%FT%TZ)"
  printf 'exit_code=%s\n' "$k6_exit"
} >> "$report_dir/run.txt"
printf '\nКод завершения k6: %s. Результаты: %s\n' "$k6_exit" "$report_dir"
printf 'Проверьте графики именно в интервале перегрузки, а не только p95 всего прогона.\n'
exit "$k6_exit"
