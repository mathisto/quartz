// k6 systematic VU sweep — holds each level for 15s to get stable measurements
// Usage: k6 run benchmarks/http/k6_sweep.js --env TARGET=http://localhost:18084 --env MAX=20000
//
// Produces stable per-stage metrics for charting throughput vs concurrency.

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const latency = new Trend('req_latency', true);

const TARGET = __ENV.TARGET || 'http://localhost:18084';
const MAX = parseInt(__ENV.MAX || '20000');

// Build stages: ramp to level in 2s, hold for 15s, repeat
const levels = [100, 500, 1000, 2000, 3000, 5000, 8000, 10000, 12000, 15000, 20000].filter(v => v <= MAX);
const stages = [];
for (const vus of levels) {
  stages.push({ duration: '2s', target: vus });
  stages.push({ duration: '15s', target: vus });
}
stages.push({ duration: '3s', target: 10 });

export const options = { stages };

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
