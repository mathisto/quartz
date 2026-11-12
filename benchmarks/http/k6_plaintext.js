// k6 HTTP plaintext benchmark — ramps from light to extreme load
// Usage: k6 run benchmarks/http/k6_plaintext.js --env TARGET=http://localhost:18080
//
// Stages:
//   1. Warmup (10s, 50 VUs)
//   2. Moderate (20s, 200 VUs)
//   3. Heavy (20s, 500 VUs)
//   4. Extreme (20s, 1000 VUs)
//   5. Overload (20s, 2000 VUs)
//   6. Cooldown (10s, 50 VUs)

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const latency = new Trend('req_latency', true);

const TARGET = __ENV.TARGET || 'http://localhost:18080';

export const options = {
  stages: [
    { duration: '10s', target: 50 },
    { duration: '20s', target: 200 },
    { duration: '20s', target: 500 },
    { duration: '20s', target: 1000 },
    { duration: '20s', target: 2000 },
    { duration: '10s', target: 50 },
  ],
  thresholds: {
    errors: ['rate<0.01'],
    req_latency: ['p(95)<500'],
  },
};

export default function () {
  const res = http.get(TARGET);
  const ok = check(res, {
    'status 200': (r) => r.status === 200,
    'body correct': (r) => r.body === 'Hello, World!',
  });
  errorRate.add(!ok);
  latency.add(res.timings.duration);
}
