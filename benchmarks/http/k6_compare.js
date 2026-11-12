// k6 head-to-head comparison — run against one server at a time
// Usage: k6 run benchmarks/http/k6_compare.js --env TARGET=http://localhost:18083
//
// Aggressive ramp: pushes to 3000 VUs to find the breaking point.
// Stages:
//   1. Warmup     (5s,  100 VUs)
//   2. Moderate   (15s, 500 VUs)
//   3. Heavy      (15s, 1000 VUs)
//   4. Extreme    (15s, 2000 VUs)
//   5. Overload   (15s, 3000 VUs)
//   6. Cooldown   (5s,  50 VUs)

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

const errorRate = new Rate('errors');
const latency = new Trend('req_latency', true);
const totalReqs = new Counter('total_requests');

const TARGET = __ENV.TARGET || 'http://localhost:18080';

export const options = {
  stages: [
    { duration: '5s',  target: 100 },
    { duration: '15s', target: 500 },
    { duration: '15s', target: 1000 },
    { duration: '15s', target: 2000 },
    { duration: '15s', target: 3000 },
    { duration: '5s',  target: 50 },
  ],
  thresholds: {
    req_latency: ['p(95)<2000'],
  },
};

export default function () {
  const res = http.get(TARGET);
  totalReqs.add(1);
  const ok = check(res, {
    'status 200': (r) => r.status === 200,
    'body correct': (r) => r.body === 'Hello, World!',
  });
  errorRate.add(!ok);
  if (res.timings.duration > 0) {
    latency.add(res.timings.duration);
  }
}
