#!/bin/bash
echo "Starting graceful chaos... Press Ctrl+C to stop."
while true; do
  PODS=$(kubectl get pods -n shop -l 'app.kubernetes.io/component in (api,worker)' -o jsonpath='{.items[*].metadata.name}')
  if [ -n "$PODS" ]; then
    POD=$(echo $PODS | tr ' ' '\n' | shuf -n 1)
    echo "Killing pod: $POD"
    kubectl delete pod -n shop $POD --timeout=5s 2>/dev/null
  fi
  sleep 5
done