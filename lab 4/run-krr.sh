#!/usr/bin/env bash
set -euo pipefail

lab4_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
report_dir="$lab4_dir/reports"
runtime_dir=$(mktemp -d /tmp/lab4-krr.XXXXXX)
trap 'rm -rf -- "$runtime_dir"' EXIT
umask 077

mkdir -p -- "$report_dir"

# Только контекст lab4; временный kubeconfig не попадает в репозиторий.
kubectl --context kind-lab4 config view --minify --flatten --raw \
  > "$runtime_dir/kubeconfig"

if [[ ! -f "$report_dir/values-before-krr.yaml" ]]; then
  cp -- "$lab4_dir/chart/values.yaml" "$report_dir/values-before-krr.yaml"
fi

# Требуется работающий port-forward Prometheus на localhost:9094.
# Анализ читает данные; рекомендации не применяются к Kubernetes.
docker run --rm --network host \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  --mount "type=bind,source=$runtime_dir/kubeconfig,target=/kubeconfig,readonly" \
  --mount "type=bind,source=$report_dir,target=/reports" \
  robustadev/krr:v1.31.1 \
  python krr.py simple \
  --kubeconfig /kubeconfig \
  --context kind-lab4 \
  --namespace default \
  --selector app.kubernetes.io/instance=shop \
  --prometheus-url http://127.0.0.1:9094 \
  --history_duration 1 \
  --timeframe_duration 0.5 \
  --max-workers 3 \
  --formatter json \
  --fileoutput /reports/krr-report.json \
  --logtostderr \
  2>&1 | tee "$report_dir/krr-run.log"
