// k6 connection churn test — new TCP connection per request (no keepalive)
// Usage: k6 run benchmarks/http/k6_no_keepalive.js --env TARGET=http://localhost:18084
//
// Forces Connection: close to stress accept/close path.

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const latency = new Trend('req_latency', true);

const TARGET = __ENV.TARGET || 'http://localhost:18084';

export const options = {
  stages: [
    { duration: '5s',  target: 100 },
    { duration: '15s', target: 500 },
    { duration: '15s', target: 1000 },
    { duration: '15s', target: 2000 },
    { duration: '15s', target: 3000 },
    { duration: '5s',  target: 50 },
  ],
};

const params = {
  headers: { 'Connection': 'close' },
};

export default function () {
  const res = http.get(TARGET, params);
  const ok = check(res, {
    'status 200': (r) => r.status === 200,
  });
  errorRate.add(!ok);
  if (res.timings.duration > 0) {
    latency.add(res.timings.duration);
  }
}
