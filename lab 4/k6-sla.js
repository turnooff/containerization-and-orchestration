import http from 'k6/http';
import { check, fail } from 'k6';

// Часть 8. Создание заказа: 10 запросов/с, p95 < 300 мс, успех >= 99%.
// k6-order.js оставлен без изменений как исходный замер для части 3.
const baseURL = (__ENV.BASE_URL || 'http://127.0.0.1:8084').replace(/\/$/, '');
const rate = Number(__ENV.RATE || 10);
const duration = __ENV.DURATION || '8m';
const p95Limit = Number(__ENV.SLA_P95_MS || 300);
const successRate = Number(__ENV.SLA_SUCCESS_RATE || 0.99);
const runLabel = __ENV.RUN_LABEL || 'lab4-sla';

if (!Number.isInteger(rate) || rate < 1) {
  throw new Error('RATE должен быть положительным целым числом');
}
if (!/^[1-9]\d*(s|m)$/.test(duration)) {
  throw new Error('DURATION задаётся целыми секундами или минутами: 30s, 8m');
}
if (!Number.isFinite(p95Limit) || p95Limit <= 0
    || !Number.isFinite(successRate) || successRate <= 0 || successRate > 1) {
  throw new Error('Некорректные SLA_P95_MS или SLA_SUCCESS_RATE');
}

export const options = {
  scenarios: {
    orders: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs: 20,
      maxVUs: 100,
      gracefulStop: '10s',
    },
  },
  // Новое соединение на запрос позволяет Service распределять нагрузку
  // между репликами, вместо закрепления всех запросов за несколькими TCP-сессиями.
  noConnectionReuse: true,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  thresholds: {
    'http_req_duration{endpoint:order}': [`p(95)<${p95Limit}`],
    'http_req_failed{endpoint:order}': [`rate<=${Number((1 - successRate).toFixed(6))}`],
    'checks{endpoint:order}': [`rate>=${successRate}`],
    // Потерянные итерации означают, что заданная частота не была выдержана.
    dropped_iterations: ['count==0'],
  },
};

export function setup() {
  const response = http.get(`${baseURL}/health`, {
    timeout: '5s',
    tags: { endpoint: 'health' },
  });
  if (response.status !== 200) {
    fail(`API не готов: GET /health вернул ${response.status}`);
  }
  console.log(`SLA: ${rate} заказов/с; p95 < ${p95Limit} мс; успех >= ${successRate * 100}%; ${duration}`);
}

export default function () {
  const response = http.post(
    `${baseURL}/order`,
    JSON.stringify({ customer: runLabel, item: 'coffee' }),
    {
      headers: { 'Content-Type': 'application/json' },
      timeout: '5s',
      redirects: 0,
      tags: { endpoint: 'order', name: 'POST /order' },
      responseCallback: http.expectedStatuses(201),
    },
  );

  let orderCreated = false;
  if (response.status === 201) {
    try {
      const id = response.json('id');
      orderCreated = typeof id === 'number' && id > 0;
    } catch (_) {
      orderCreated = false;
    }
  }
  check(response, { 'заказ создан: 201 и id': () => orderCreated }, { endpoint: 'order' });
}

export function handleSummary(data) {
  const latency = data.metrics['http_req_duration{endpoint:order}']?.values || {};
  const errors = data.metrics['http_req_failed{endpoint:order}']?.values || {};
  const checks = data.metrics['checks{endpoint:order}']?.values || {};
  const dropped = data.metrics.dropped_iterations?.values?.count || 0;
  const failed = Object.entries(data.metrics).flatMap(([name, metric]) =>
    Object.entries(metric.thresholds || {})
      .filter(([, result]) => !result.ok)
      .map(([threshold]) => `${name}: ${threshold}`),
  );
  const result = {
    stdout: [
      '\nРезультат проверки SLA:',
      `p95 POST /order: ${latency['p(95)'] ?? 'нет данных'} мс`,
      `Ошибки HTTP: ${((errors.rate ?? 1) * 100).toFixed(2)}%`,
      `Заказ создан (201 и id): ${((checks.rate ?? 0) * 100).toFixed(2)}%`,
      `Не запущено итераций: ${dropped}`,
      failed.length ? `НЕ ПРОЙДЕНО:\n${failed.join('\n')}` : 'Все заданные thresholds пройдены.',
      '',
    ].join('\n'),
  };
  if (__ENV.SUMMARY_PATH) {
    result[__ENV.SUMMARY_PATH] = JSON.stringify(data, null, 2);
  }
  return result;
}
