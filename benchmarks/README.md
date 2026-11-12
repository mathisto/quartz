# Quartz Benchmark Suite

## Overview

This directory contains performance benchmarks for the Quartz programming language,
with equivalent implementations in C for cross-language comparison.

## Benchmarks

| Benchmark | Description | Stress Target |
|-----------|-------------|---------------|
| `binary_trees/` | Recursive tree construction + checksum | Allocation, recursion |
| `nbody/` | N-body gravitational simulation | Struct field access, arithmetic |
| `fibonacci/` | Fibonacci sequence (recursive + iterative) | Function call overhead |
| `sieve/` | Sieve of Eratosthenes | Array access, loops |
| `matrix/` | Matrix multiplication | Nested loops, indexing |
| `string_concat/` | String concatenation | String allocation |
| `sum/` | Sum of integers | Basic loop, accumulator |
| `hash_map_bench.qz` | HashMap insert/lookup/delete at scale | Hash table, string ops |
| `linked_list.qz` | Linked list insert/traverse/delete | Pointer manipulation |

## Methodology

### What We Measure

1. **Wall-clock time** — total execution time including startup
2. **Multiple runs** — minimum 3 runs (10 if using `hyperfine`)
3. **Warmup** — 1 warmup run discarded when using `hyperfine`

### Environment Requirements

- **Quartz compiler**: `./self-hosted/bin/quartz`
- **LLVM tools**: `llc` and `lli` (via `llvm` package, e.g. `/opt/homebrew/opt/llvm/bin`)
- **C compiler**: `cc` (clang or gcc)
- **Optional**: [`hyperfine`](https://github.com/sharkdp/hyperfine) for statistical benchmarking

### Compilation

Quartz programs are compiled to LLVM IR, then to native binary via `llc` + `clang`:

```bash
./self-hosted/bin/quartz program.qz > program.ll
llc -O2 -filetype=obj -o program.o program.ll
clang -O2 program.o -o program
```

C programs are compiled directly:

```bash
cc -O2 -o program program.c
```

### Running

```bash
# Run all benchmarks
bash benchmarks/run.sh

# Run individual benchmark
./self-hosted/bin/quartz benchmarks/hash_map_bench.qz | lli
```

## Adding a New Benchmark

1. Create `benchmarks/my_bench.qz` with `def main(): Int` entry point returning 0
2. Create `benchmarks/c/my_bench.c` with equivalent C implementation
3. Add entries to `run.sh`
4. Verify both compile and produce equivalent output

## Interpretation Notes

- Quartz uses `i64` universally at runtime — no type-based optimizations
- All heap allocation uses `malloc`/`free` (no GC)
- Quartz closures use tagged pointers with an extra indirection
- C benchmarks compiled at `-O2` represent the "speed of light" target
- Differences reflect Quartz's abstraction overhead, not inefficient algorithms
