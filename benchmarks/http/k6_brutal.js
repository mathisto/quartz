// k6 brutal load test — find the absolute ceiling
// Usage: k6 run benchmarks/http/k6_brutal.js --env TARGET=http://localhost:18084
//
// Stages:
//   1. Warmup     (5s,   500 VUs)
//   2. Heavy      (15s,  2000 VUs)
//   3. Extreme    (15s,  5000 VUs)
//   4. Brutal     (15s,  8000 VUs)
//   5. Insane     (15s,  10000 VUs)
//   6. Cooldown   (5s,   100 VUs)

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

const errorRate = new Rate('errors');
const latency = new Trend('req_latency', true);

const TARGET = __ENV.TARGET || 'http://localhost:18084';

export const options = {
  stages: [
    { duration: '5s',  target: 500 },
    { duration: '15s', target: 2000 },
    { duration: '15s', target: 5000 },
    { duration: '15s', target: 8000 },
    { duration: '15s', target: 10000 },
    { duration: '5s',  target: 100 },
  ],
  thresholds: {
    req_latency: ['p(95)<5000'],
  },
};

export default function () {
  const res = http.get(TARGET);
  const ok = check(res, {
    'status 200': (r) => r.status === 200,
  });
  errorRate.add(!ok);
  if (res.timings.duration > 0) {
    latency.add(res.timings.duration);
  }
}
