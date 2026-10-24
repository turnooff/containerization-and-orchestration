# Оценка ресурсов PostgreSQL из Prometheus

Это отдельный расчёт по метрикам, а не строка исходного отчёта krr. Ресурсы не изменены.

Окно: 24 октября 2026, 13:23:07–14:23:07 МСК (10:23:07–11:23:07 UTC).
Конец окна закреплён через `@ 1792840987`, чтобы сохранить интервал, использованный при запуске krr.
Контекст `kind-lab4`, namespace `default`, под `shop-postgres-1`, контейнер `postgres`.

Метод повторяет настройки стратегии simple: CPU — p95 значений rate за 30 секунд, память — максимум working set +15%; окно час, шаг 30 секунд. Получено 120 точек CPU и памяти.

| Показатель | Результат |
| --- | --- |
| CPU p95 | 15.7738m |
| CPU request после округления вверх до 1m | 16m |
| Максимум памяти | 160.0352 MiB |
| Максимум памяти +15% | 184.0404 MiB |
| Memory request/limit после округления вверх до 1Mi | 185Mi |

В стратегии также есть минимумы 10m и 100Mi; здесь расчёт выше обоих минимумов. CPU limit этим расчётом не определяется; гвардрейлы требуют его наличия.

Исходные настройки PostgreSQL сохранены: requests `100m / 128Mi`, limits `200m / 256Mi`. Файл values.yaml совпадает с values-before-krr.yaml, действующий Cluster также содержит исходные ресурсы.

Запрос CPU (результат в миллиядрах):

```promql
quantile_over_time(0.95, (max by (container, pod, job) (rate(container_cpu_usage_seconds_total{namespace="default",pod="shop-postgres-1",container="postgres"}[30s])))[1h:30s] @ 1792840987) * 1000
```

Запрос пика памяти (результат в байтах; умножить на 1.15 и разделить на 1024^2 для оценки с запасом в MiB):

```promql
max_over_time((max by (container, pod, job) (container_memory_working_set_bytes{namespace="default",pod="shop-postgres-1",container="postgres"}))[1h:30s] @ 1792840987)
```

В браузере Prometheus выбрать Table и выполнить запрос. JSON с исходными ответами сохранён в postgres-estimate.json.

Ограничения: короткое учебное окно включает простой и пятиминутный тест около 9.66 заказа/с, направленный на одну реплику api. Расчёт не гарантирует достаточность ресурсов при любой нагрузке.

Алгоритм и запросы проверены по исходникам krr v1.31.1: [CPU](https://github.com/robusta-dev/krr/blob/v1.31.1/robusta_krr/core/integrations/prometheus/metrics/cpu.py), [память](https://github.com/robusta-dev/krr/blob/v1.31.1/robusta_krr/core/integrations/prometheus/metrics/memory.py).
