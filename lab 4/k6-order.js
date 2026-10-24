import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 2,
  duration: '5m',
};

export default function () {
  const response = http.post(
    'http://127.0.0.1:8084/order',
    JSON.stringify({
      customer: 'lab4-k6',
      item: 'coffee',
    }),
    {
      headers: { 'Content-Type': 'application/json' },
      timeout: '5s',
    },
  );

  check(response, {
    'заказ создан': (r) => r.status === 201,
  });

  sleep(0.2);
}