# Benchmark Analysis — v5.25.0-alpha

> **Date**: 2026-02-16 | **Commit**: b9d5066 | **Tests**: 3,274

## Results Summary

| Benchmark | Quartz (self-hosted) | C (clang -O2) | Ratio | Status |
|-----------|---------------------|----------------|-------|--------|
| fibonacci | 316.8ms | 317.8ms | **1.0x** | ✅ Tied |
| sum | 2.3ms | 2.2ms | **1.1x** | ✅ Tied |
| sieve | 63.7ms | 13.7ms | **4.7x** | 🔴 Needs work |
| string_concat | 2.4ms | 2.6ms | **0.9x** | ✅ Faster than C |
| matrix | 5.4ms | 5.3ms | **1.0x** | ✅ Tied |
| binary_trees | — | 5.8ms | — | ⚠️ Self-hosted failed to compile |

Quartz (bootstrap) on binary_trees: 4.9ms (0.8x C — faster).

### Cross-Language Comparison

| Benchmark | Quartz | C | Rust | Zig | Notes |
|-----------|--------|---|------|-----|-------|
| fibonacci | 316.8ms | 317.8ms | 317.2ms | 317.9ms | All tied |
| sum | 2.3ms | 2.2ms | 2.4ms | 2.3ms | All tied |
| sieve | 63.7ms | 13.7ms | 12.9ms | 13.4ms | **Quartz 4.7x slower** |
| string_concat | 2.4ms | 2.6ms | 2.6ms | 2.2ms | Quartz beats C & Rust |
| matrix | 5.4ms | 5.3ms | 5.6ms | 5.7ms | Quartz beats Rust & Zig |
| binary_trees | 4.9ms* | 5.8ms | 6.0ms | 2.9ms | **Zig 0.5x C** |

*Bootstrap only; self-hosted failed to compile.

---

## Analysis

### Why Quartz Beats C at String Concat

Quartz uses `sb_new()` / `sb_append()` — a StringBuilder intrinsic with an optimized append-only buffer (built during Phase B Benchmark Optimization Sprint). The C version uses `malloc` + `realloc` with manual 2x growth, where every `realloc` potentially copies the entire buffer.

The ~10% win is an implementation quality difference: the Quartz StringBuilder was specifically tuned for this pattern.

### Why Sieve Is 4.7x Slower — The Real Issue

**Root cause: 8x memory footprint.**

- **C**: `char *sieve = malloc(n)` — 1 byte per element, flat array, direct `sieve[i]`
- **Quartz**: `var sieve = vec_new()` + `vec_push(1)` — 8 bytes per element (i64), heap Vec

For n=10M: C uses ~10MB (fits in L2/L3), Quartz uses ~80MB (blows past L3). The 4.7x ratio maps almost perfectly to cache hierarchy penalties.

The Quartz sieve already uses `vec_get_unchecked` / `vec_set_unchecked`, so bounds checking isn't the issue — it's pure data size.

**Fixes (ranked by impact)**:
1. **`Vec<U8>` or `Bytes` type for sieve** — Use byte-width storage, matching C's memory footprint
2. **BitVec type** — 8 flags per byte (1.25MB for n=10M), would likely *beat* C
3. **SoA (Struct of Arrays) layout** — pack boolean flags into cache-friendly layout

### Why Zig Wins Binary Trees (0.5x C)

Zig uses an **arena allocator**:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
_ = arena.reset(.retain_capacity);  // Frees ALL nodes in O(1)
```

All tree nodes are bump-allocated into a contiguous region. When done, the entire arena resets in O(1) instead of walking every node to free it.

- **C**: `malloc` per node + recursive `tree_free` (32,768 free calls per depth-15 tree)
- **Zig**: Bump-allocate + O(1) arena reset
- **Quartz**: `alloc(24)` per node, never freed (leaks intentionally)

### Binary Trees Self-Hosted Compilation Failure

**Root cause: missing `alloc` intrinsic in self-hosted codegen.**

The self-hosted compiler emits `; WARNING: Unknown intrinsic 'alloc'` and falls through
to `%v1 = add i64 0, 0` — storing null (0) as the pointer. When the program then tries
to write tree node fields at offsets 0, 8, 16 from null, it hits a **trace trap** (SIGILL,
exit code 133).

The bootstrap compiler correctly translates `alloc(24)` → `malloc(24 * 8)`:
```llvm
; Bootstrap (correct):
%v0.bytes = mul i64 24, 8
%v0.ptr = call i8* @malloc(i64 %v0.bytes)
%v0 = ptrtoint i8* %v0.ptr to i64

; Self-hosted (broken):
; WARNING: Unknown intrinsic 'alloc'
%v1 = add i64 0, 0          ; ← null pointer!
store i64 %v1, i64* %ptr    ; ptr = 0
```

**Fix**: Add `alloc` to the self-hosted compiler's intrinsic dispatch table.
This is separate from the `malloc` FFI declaration — `alloc(n)` is a Quartz-level
intrinsic that allocates `n * 8` bytes (word-sized slots).

---

## Research: Closing the Remaining Gaps

### Arena Allocators (Highest Impact)

**Papers**: Tofte & Talpin (1997) "Region-Based Memory Management". MLKit proved compile-time region inference is feasible.

**Approach for Quartz**: Add arena allocator intrinsics:
- `arena_new()` / `arena_alloc(arena, size)` / `arena_reset(arena)` / `arena_free(arena)`
- Unlocks fast binary trees AND is exactly what web servers need (per-request arenas)

### Bounds Check Elimination

LLVM can eliminate redundant bounds checks if given proper metadata:
- `!range` metadata on loads
- Induction variable analysis for loop-indexed access
- Quartz could emit `nuw`/`nsw` flags on index arithmetic

### Narrow Collection Types

The sieve benchmark proves that i64-everywhere has a real cost for data-parallel workloads. Options:
- `Vec<U8>` / `Vec<I32>` with monomorphized element width
- `BitVec` for boolean flag arrays
- `Bytes` (already implemented) for byte buffers, but needs sieve-friendly API

### SoA/AoS Layout Control

For struct-heavy benchmarks, allow programmers to request Structure-of-Arrays layout:
```
@soa struct Particle { x: F32, y: F32, z: F32, mass: F32 }
```
This is a stretch goal but would make Quartz competitive in HPC/game engine scenarios.
