# Quartz Benchmarks — May 2026

Honest, reproducible micro-benchmarks of the **self-hosted Quartz compiler** against
`clang -O2`. We publish what we measure, including where we lose.

## Environment

| | |
|---|---|
| Date | 2026-05-31 |
| Quartz | v5.28.0-alpha (`62e06ff3`) — version string pre-renumber; the `VERSION` value at `62e06ff3` was actually 5.12.x. "5.28.0-alpha" never shipped as a `VERSION` string; it is a forward-looking milestone tag captured at measurement time. |
| Machine | Apple M1 Max, 10 cores, 64 GB |
| OS | macOS 15.7.1 |
| LLVM | 21.1.8 (Homebrew) |
| Pipeline | `quartz src.qz` → `opt -O2` → `llc -O2` → `cc -O2`; C built with `cc -O2` |
| Measurement | `hyperfine -N --warmup 2 --min-runs 8` |

Both sides produce native binaries through the same LLVM back end at `-O2`. The only
difference is the front end that emits the IR (the Quartz compiler vs. clang).

## Results

| Benchmark | Quartz | clang -O2 | Ratio |
|---|---:|---:|---|
| string_concat | 1.9 ms | 1.5 ms | C 1.33× faster |
| binary_trees (bump) | 2.1 ms | 1.6 ms | C 1.30× faster |
| nbody | 456.8 ms | 241.2 ms | C 1.89× faster |
| fibonacci (recursive) | 833.1 ms | 322.1 ms | C 2.59× faster |
| matrix | 20.4 ms | 4.6 ms | C 4.42× faster |
| sieve | 83.0 ms | 14.4 ms | C 5.78× faster |
| sum | 217.7 ms | 1.5 ms | C 149× faster |

**Quartz currently loses every benchmark.** That is the honest state of a five-month-old
self-hosted optimizer, and we would rather say so than ship a flattering table that
doesn't reproduce.

## Reading the numbers

- **string_concat and binary_trees (bump) — ~1.3×.** These are allocation- and
  memory-movement-bound. Quartz's bump allocator and string builder are within a third of
  clang here. This is the closest the back end gets today.
- **nbody / fibonacci — ~1.9–2.6×.** Call- and float-heavy. The gap is real and reflects
  missing back-end optimizations (inlining heuristics, no auto-vectorization).
- **matrix / sieve — ~4–6×.** Tight numeric loops. Quartz emits correct but scalar loops;
  the compile logs are full of `loop not vectorized` remarks. Closing this gap (loop
  vectorization, idiom recognition) is the single biggest performance lever and is tracked
  on the roadmap.
- **sum — 149×.** A microbenchmark artifact: clang recognizes the `0..N` accumulate idiom
  and reduces the entire loop to a closed-form/vectorized constant. Quartz runs the loop.
  This overstates the "real" gap, but we report it as measured rather than dropping the
  inconvenient row.

## Methodology notes & caveats

- The legacy `binary_trees` (malloc variant) source no longer compiles on the current
  compiler — it references a removed `alloc` builtin. Only the `bump` variant is reported.
  Tracked as a benchmark-rot fix.
- No Rust or Zig numbers: the harness (`benchmarks/run.sh`) only builds Quartz and C, so we
  do not publish Rust/Zig comparisons we did not actually run.
- These are single-machine micro-benchmarks. They measure back-end code quality on small
  kernels, not real-world application throughput.

## The honest summary

Quartz compiles to native machine code with no GC and no runtime, and it is **correct**.
On raw speed it sits roughly **1.3–2× behind `clang -O2`** on allocation- and string-bound
work, and **4–6× behind** on un-vectorized numeric loops. Correctness and self-hosting came
first; back-end performance is the next frontier, not a solved problem. We will update this
file as the optimizer improves.
