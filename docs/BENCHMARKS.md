# Quartz Benchmark Methodology

> **Version**: 2.3 | **Doc updated**: 2026-07-04 (measurements) / Feb 28, 2026 (methodology)
> **Suite**: 12 benchmark pairs (Quartz vs C, Go added for the 8 core micro-benchmarks) + infrastructure
> **Runner**: `benchmarks/run.sh` with optional `hyperfine` — use `quake bench_compile` for compile-only
>
> Latest numbers: **[Latest Measured Results (2026-07-04)](#latest-measured-results-2026-07-04)**
> below (Quartz v5.12.21-alpha, dev Mac / Darwin arm64, + a Go 1.25.5 column).

---

## Overview

This document describes the methodology, design principles, and known limitations of
the Quartz benchmark suite. The goal is **honest, reproducible measurement** that
fairly compares Quartz to C, accounting for Quartz's existential type model (everything
is `i64` at runtime).

---

## Benchmark Inventory

| # | Benchmark | Stress Target | QZ Source | C Source | Fair? |
|:-:|-----------|---------------|-----------|----------|:-----:|
| 1 | `fibonacci` | Function call overhead | `fibonacci/fib.qz` | `fibonacci/fib.c` | ✅ |
| 2 | `sum` | Basic loop, accumulator | `sum/sum.qz` | `sum/sum.c` | ✅ |
| 3 | `sieve` | Array access, loops | `sieve/sieve.qz` | `sieve/sieve.c` | ✅ |
| 4 | `matrix` | Nested loops, indexing | `matrix/matrix.qz` | `matrix/matrix.c` | ✅ |
| 5 | `string_concat` | String allocation | `string_concat/concat.qz` | `string_concat/concat.c` | ✅ |
| 6 | `binary_trees` | Allocation, recursion (malloc) | `binary_trees/trees.qz` | `binary_trees/trees.c` | ✅ |
| 7 | `binary_trees_bump` | Allocation, recursion (bump alloc) | `binary_trees/trees_bump.qz` | `binary_trees/trees_bump.c` | ✅ |
| 8 | `nbody` | Integer arithmetic, arrays | `nbody/nbody.qz` | `nbody/nbody.c` | ✅ |
| 9 | `hash_map_bench` | Hash table, string ops | `hash_map_bench.qz` | `c/hash_map_bench.c` | ✅ |
| 10 | `linked_list` | Pointer manipulation | `linked_list.qz` | `c/linked_list.c` | ✅ |
| 11 | `json_parse` | String parsing, tokenization | `json_parse/json_parse.qz` | `c/json_parse.c` | ✅ |

All benchmarks use **equivalent algorithms** in both languages. The C versions use
`long` (64-bit) to match Quartz's universal `i64`.

### Fairness Principles

1. **Same algorithm**: Both implementations use identical algorithmic approaches
2. **Same data types**: C uses `long` (not `int`) to match Quartz's `i64`
3. **Same allocator**: `malloc`/`free` in both (unless explicitly comparing allocators)
4. **Same optimization**: Both compiled with `-O2` (Quartz via `llc -O2`, C via `clang -O2`)
5. **Same I/O**: Both print results to verify correctness (prevents dead code elimination)

### Known Fairness Issues (Resolved)

- **Hash map**: C version now uses dynamic resizing at 75% load + backward-shift deletion
  (not a trivial open-addressing stub)
- **JSON parse**: C equivalent now exists (`c/json_parse.c`) for fair comparison
- **Linked list**: Quartz version fixed to free deleted nodes (no memory leak)
- **Binary trees**: Both malloc and bump-allocator variants provided

---

## Compilation

### Quartz Compilation Pipeline

```bash
# Step 1: Quartz → LLVM IR
./self-hosted/bin/quartz program.qz > program.ll

# Step 2: LLVM IR → object file (with optimization)
llc -O2 -filetype=obj -o program.o program.ll

# Step 3: Object file → native binary
clang -O2 program.o -o program -lm
```

**Note**: `clang -O2 -x ir` is NOT used because it miscompiles the self-hosted compiler
IR (SIGSEGV on self-compile). `llc -O2` provides codegen-level optimization only.

### C Compilation

```bash
clang -O2 -o program program.c -lm
```

### Optimization Equivalence

| Stage | Quartz | C |
|-------|--------|---|
| Frontend optimization | None (Quartz emits unoptimized IR) | clang frontend optimizations |
| IR optimization | None (`llc` doesn't run opt passes) | clang `-O2` runs full LLVM opt pipeline |
| Codegen optimization | `llc -O2` (instruction selection, scheduling, register allocation) | Same (clang uses llc internally) |

> [!IMPORTANT]
> Quartz's LLVM IR does not go through `opt`. C code compiled with `clang -O2` benefits
> from the full LLVM optimization pipeline (inlining, loop unrolling, vectorization, etc.).
> This means C benchmarks may have an optimization advantage beyond algorithmic differences.
> This is intentional — it represents real-world compilation.

---

## Measurement

### Runtime Measurement

**Primary method**: `hyperfine` (if installed)
- Warmup: 1 run
- Measured runs: ≥5
- Reports: mean ± stddev, min, max, median

**Fallback method**: `time` (built-in)
- Reports: real (wall clock), user (CPU), sys (kernel)

### Memory Measurement

Peak RSS (Resident Set Size) measured via `/usr/bin/time -l` on macOS:
- Reports maximum resident set size in bytes
- Converted to KB in output

### Running

```bash
# Full suite (compile + run)
bash benchmarks/run.sh

# With hyperfine
bash benchmarks/run.sh --hyperfine

# Compile only (no execution)
bash benchmarks/run.sh --compile-only

# Via Quake
./self-hosted/bin/quake bench_compile
```

---

## Hardware Specs Template

When reporting benchmark results, include:

```
Machine:      [model]
CPU:          [model, cores, frequency]
RAM:          [size, type]
OS:           [version]
Quartz:       [version, git hash]
LLVM:         [version]
C compiler:   [clang/gcc version]
```

---

## Known Limitations

### The i64-Everywhere Model

Quartz uses `i64` universally at runtime. This means:
- No narrow integer optimizations (can't pack arrays of `u8` tighter than `i64` unless using `Vec<U8>`)
- No register-width flexibility (everything is 64-bit)
- Struct fields are all `i64` (no struct packing optimization)

The `sieve` benchmark uses `Vec<U8>` (1 byte per element, introduced in Memory Model V2)
to demonstrate that Quartz CAN use narrow storage when the programmer opts in.

### No Floating-Point Benchmarks

The `nbody` benchmark uses **integer arithmetic** (scaled by 1000) instead of doubles,
because Quartz's existential model makes float benchmarks tricky — floats are `bitcast`
to/from `i64` at every operation boundary, adding overhead that's inherent to the model
but not representative of algorithmic performance.

### Single-Threaded Only

All benchmarks are single-threaded. Quartz has concurrency primitives (`spawn`, `await`,
channels) but no parallel benchmark has been created yet.

### Missing Benchmark Categories

| Category | Description | Status |
|----------|-------------|--------|
| Struct-heavy | Create/access/destroy thousands of structs | Planned |
| Bare-metal | No stdlib, direct syscalls | Blocked on `--target freestanding` |
| Sorting | QuickSort, MergeSort on large arrays | Easy to add |
| Graph algorithms | BFS/DFS on adjacency lists | Easy to add |
| Regex | Pattern matching on large text | Requires PCRE2 runtime |

---

## Adding a New Benchmark

1. Create `benchmarks/<name>/<name>.qz` with `def main(): Int` returning 0
2. Create `benchmarks/<name>/<name>.c` (or `benchmarks/c/<name>.c`) with equivalent C
3. Add entry to `benchmarks/run.sh` `BENCHMARKS` array
4. Verify both compile and produce identical output
5. Run `bash benchmarks/run.sh --hyperfine` to validate measurement

### Test That Output Matches

```bash
diff <(./build/<name>_qz) <(./build/<name>_c)
```

---

## Latest Measured Results (2026-07-04)

Refreshed on the self-hosted **v5.12.21-alpha** compiler (`./self-hosted/bin/quartz --version`),
on the **dev Mac (Darwin arm64)** under normal desktop load. These are **indicative**, not
controlled-lab numbers — a developer laptop with background processes produces noisy timings,
especially for the sub-5 ms benchmarks where process-startup dominates. A **Go 1.25.5** column
is included this pass.

- **Pipeline (Quartz):** `quartz src.qz` → `llc -O2 -filetype=obj` → `clang -O2 obj -lm`
  (the canonical CLAUDE.md pipeline, **no `opt -O2` pass**). See the caveat below — running the
  IR through `opt -O2` currently **miscompiles `matrix`** (prints garbage) and does not change
  the crash on `nbody`, so this refresh uses the `llc -O2`-only path that produces correct output.
- **C:** `clang -O2 src.c -lm`. **Go:** `go build` (Go 1.25.5, default optimizer).
- **Timing:** best-of-3 wall clock via Python `time.perf_counter()` around each process,
  run **strictly serially** (one process at a time). Output parity verified across all three
  languages before timing (identical stdout).

| Benchmark | Size | Quartz | C | Go | Ratio (C / Go) |
|---|---|---:|---:|---:|---|
| fibonacci (recursive) | fib(40) | 726 ms | 320 ms | 353 ms | C 2.27× / Go 2.05× faster |
| sum | 0..100 M accumulate | 225 ms | 2.0 ms | 37 ms | C 112× / Go 6.1× faster |
| sieve | n = 10 M (Vec\<U8\>) | 84 ms | 14 ms | 22 ms | C 6.1× / Go 3.9× faster |
| matrix | 200×200 mul | 55 ms | 5.3 ms | 11 ms | C 10.4× / Go 4.9× faster |
| string_concat | 100 K appends | 3.0 ms | 2.6 ms | 3.5 ms | ≈ startup-bound |
| binary_trees (malloc) | depth 15 | 3.9 ms | 3.7 ms | 4.3 ms | ≈ startup-bound |
| binary_trees (bump) | depth 15 | 3.1 ms | 2.2 ms | 3.3 ms | ≈ startup-bound |
| nbody | 500 K steps | — | 237 ms | 296 ms | **Quartz PARKED** — binary segfaults |

The nbody C and Go numbers above are freshly measured this pass (best-of-3); only the Quartz
side is parked because its binary segfaults (see caveat).

**Honest summary:** Quartz still trails `clang -O2` on every measurable benchmark —
roughly at parity on tiny startup-bound work, **~2×** on call-heavy recursion, **~6–10×**
on un-vectorized numeric loops, and pathologically on `sum` (clang reduces the accumulate
idiom to closed form; Go partially, Quartz runs the loop). Go lands between Quartz and C on
the numeric kernels. The back end emits correct but scalar code (no auto-vectorization yet).
Correctness and self-hosting came first; back-end performance is the active frontier. We
publish what we measure, including where we lose.

> **Caveats & benchmark-rot fixes (2026-07-04 pass):**
> - **`binary_trees` (malloc variant) FIXED.** It previously failed to compile — it called the
>   removed `alloc` builtin and used *byte* offsets (0/8/16) for `store`/`load`. Under the
>   current compiler `store`/`load` index in **i64 words** (`getelementptr i64`), so the fix
>   swaps `alloc(24)`→`mem_alloc(24)` (24 bytes = 3 words) and rewrites offsets to word units
>   (0/1/2), matching the `bump` variant. It now builds and prints `65519` at depth 15,
>   identical to `trees.c` and `trees.go`.
> - **`matrix` under `opt -O2` is miscompiled** (prints a garbage i64 instead of `0`). The
>   canonical `llc -O2`-only pipeline produces the correct `0`. This is a Quartz codegen bug
>   exposed by the LLVM `opt` pipeline — filed for the compiler track; this doc measures the
>   correct (`llc -O2`) build.
> - **`nbody` is PARKED.** The Quartz binary segfaults (`EXC_BAD_ACCESS` in `advance`, bad
>   deref at `+0x8`) regardless of the `opt` pass — a pre-existing runtime bug with the
>   module-level `var` Vec globals it accesses inside `advance`. Filed for the compiler track.
> - These are dev-laptop numbers under load — treat as **indicative**, not controlled results.

### Historical record — May 2026 (v5.28.0-alpha tag)

Measured on `62e06ff3` — **version string pre-renumber**: the `VERSION` value at that commit
was actually 5.12.x; "5.28.0-alpha" is a forward-looking milestone tag captured at measurement
time, not a shipped `VERSION` string. Apple M1 Max, LLVM 21.1.8, `hyperfine -N --warmup 2
--min-runs 8`, pipeline `quartz → opt -O2 → llc -O2 → cc -O2`. Full point-in-time record:
`docs/BENCHMARKS_2026-05.md`.

| Benchmark | Quartz | clang -O2 | Ratio |
|---|---:|---:|---|
| string_concat | 1.9 ms | 1.5 ms | C 1.33× faster |
| binary_trees (bump) | 2.1 ms | 1.6 ms | C 1.30× faster |
| nbody | 456.8 ms | 241.2 ms | C 1.89× faster |
| fibonacci | 833.1 ms | 322.1 ms | C 2.59× faster |
| matrix | 20.4 ms | 4.6 ms | C 4.42× faster |
| sieve | 83.0 ms | 14.4 ms | C 5.78× faster |
| sum | 217.7 ms | 1.5 ms | C 149× faster (clang folds the loop) |

> Note (May 2026, now resolved): the legacy `binary_trees` (malloc variant) did not compile
> then (removed `alloc` builtin) — fixed in the 2026-07-04 pass above.

---

## Interpretation Guidelines

1. **Equal times** = Quartz generates comparable code to C for this workload
2. **Quartz slower** = likely due to:
   - Missing LLVM `opt` passes (inlining, vectorization)
   - Runtime overhead (tagged pointers for closures, bounds checks on Vec)
   - The i64-everywhere model (no narrow types, bitcast overhead for floats)
3. **C slower** = unlikely, but could happen if Quartz's algorithm is simpler
   (would indicate the benchmark isn't fair — fix the C version)

The benchmarks represent **what Quartz can achieve today**. As the compiler adds
optimization passes (P.5, inlining, loop unrolling), these numbers should improve.
