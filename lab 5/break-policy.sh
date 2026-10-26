#!/bin/bash
# break-policy.sh — случайная поломка NetworkPolicy
# Только реальные ключи из values.yaml

BREAK=$((RANDOM % 4))

case $BREAK in
  0)
    echo "Поломка #0: неверный порт postgres (5433 вместо 5432)"
    helm upgrade shop ./chart -n shop --set networkPolicy.db.port=5433
    ;;
  1)
    echo "Поломка #1: неверный лейбл CNPG-кластера в селекторе"
    helm upgrade shop ./chart -n shop --set networkPolicy.db.clusterLabelValue=wrong-postgres
    ;;
  2)
    echo "Поломка #2: сломан DNS (порты 9999 вместо 53)"
    helm upgrade shop ./chart -n shop \
      --set networkPolicy.dns.udpPort=9999 \
      --set networkPolicy.dns.tcpPort=9999
    ;;
  3)
    echo "Поломка #3: неверный ingress-порт для api (9999 вместо 8080)"
    helm upgrade shop ./chart -n shop --set networkPolicy.api.ingressPort=9999
    ;;
esac

echo "Ждём 5 секунд, пока Cilium применит политики..."
sleep 5
echo "Поломка применена. Проверяй симптом:"
echo "   curl -4 -s -w '\\nHTTP %{http_code}\\n' --max-time 5 http://127.0.0.1:30000/orders"