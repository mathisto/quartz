// k6 sustained load benchmark — constant rate for measuring steady-state throughput
// Usage: k6 run benchmarks/http/k6_sustained.js --env TARGET=http://localhost:18080 --env RPS=10000
//
// Holds a constant request rate to measure sustained throughput and tail latencies.

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const latency = new Trend('req_latency', true);

const TARGET = __ENV.TARGET || 'http://localhost:18080';
const RPS = parseInt(__ENV.RPS || '10000');

export const options = {
  scenarios: {
    sustained: {
      executor: 'constant-arrival-rate',
      rate: RPS,
      timeUnit: '1s',
      duration: '30s',
      preAllocatedVUs: 200,
      maxVUs: 2000,
    },
  },
  thresholds: {
    errors: ['rate<0.01'],
    req_latency: ['p(99)<1000'],
  },
};

export default function () {
  const res = http.get(TARGET);
  const ok = check(res, {
    'status 200': (r) => r.status === 200,
  });
  errorRate.add(!ok);
  latency.add(res.timings.duration);
}
