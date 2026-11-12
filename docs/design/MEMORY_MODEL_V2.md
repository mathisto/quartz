# Memory Model V2 — Design Study

> **Status**: PARTIAL — superseded by [`MEMORY_MODEL_V3.md`](MEMORY_MODEL_V3.md). Width-aware `Vec` + `@value` landed in *narrow* form; `@repr(C)` is partial; selective monomorphization never started. See V3 for the finalized plan (B.10 epic).
> **Author**: Compiler Team | **Date**: Feb 2026
> **Version**: v5.25.0-alpha | **Design Commit**: 7e44d1e | **Partial implementation**: 1b5f544, fe5573e, 5822a00, dfddf50

---

## 1. Current Model Analysis

### How It Works

Quartz uses an **existential type model**: types exist at compile time but vanish at runtime. Every value is represented as `i64` (64-bit integer). Structs are heap-allocated via `malloc`, with fields accessed via pointer offset arithmetic:

```llvm
; struct Point { x: Int, y: Int }
; p = Point { x: 10, y: 20 }
%ptr = call i8* @malloc(i64 16)       ; 2 fields × 8 bytes
%p = ptrtoint i8* %ptr to i64
%x_ptr = inttoptr i64 %p to i64*
store i64 10, i64* %x_ptr             ; p.x = 10
%y_addr = add i64 %p, 8
%y_ptr = inttoptr i64 %y_addr to i64*
store i64 20, i64* %y_ptr             ; p.y = 20
```

### What Works Well

| Strength | Benefit |
|----------|---------|
| Uniform representation | No monomorphization explosion, small binaries |
| Simple calling convention | Every function takes/returns `i64`, no type dispatch at call sites |
| First-class functions | Function pointers and closures share `i64` representation trivially |
| Fast compilation | No template instantiation, no specialization overhead |
| Self-hosting simplicity | Compiler can be written in its own language without bootstrapping complexity |

### What Costs

| Cost | Measured Impact | Affected Benchmarks |
|------|----------------|---------------------|
| 8 bytes per boolean/byte element | 8× memory for byte arrays, L3 cache blowout | sieve: **4.7× slower** than C |
| Every struct heap-allocated | malloc per struct, pointer indirection | binary_trees: allocation-bound |
| No packed/value types | Can't have stack-allocated structs, no SIMD-friendly layouts | nbody: predicted 3-5× slower |
| No narrow integer types at runtime | U8/I16 values stored as i64, wasting 7 bytes each | Data-parallel workloads |
| Pointer tagging for closures | Low bit check on every function call | HOF-heavy code |

### Quantified Cost: The i64 Tax

Based on existing benchmarks (BENCHMARK_ANALYSIS.md):

- **fibonacci/sum/matrix**: 1.0× C — LLVM optimizes away the i64 representation entirely
- **sieve (n=10M)**: 4.7× C — 80MB vs 10MB, cache hierarchy penalty
- **string_concat**: 0.9× C — StringBuilder quality win overwhelms type system cost
- **binary_trees**: ~1.0× C (malloc strategy) — type system cost hidden by allocation cost

The i64 tax is **zero for scalar code** (LLVM eliminates it) and **catastrophic for dense data** (cache misses dominate).

---

## 2. Candidate Approaches

###2A: Zig-Style Comptime Type Erasure

**How it works**: Types are erased at compile time but the compiler chooses optimal runtime representations. Generics are resolved at compile time (`comptime`), producing specialized code without monomorphization.

**Key ideas for Quartz**:
- Keep existential model for function signatures (`i64` calling convention)
- Add `comptime` evaluation to specialize collection element widths
- `Vec<U8>` lowers to byte-width storage, `Vec<Int>` stays 8-byte
- Struct fields with known small types use packed layout internally

**Tradeoffs**:

| Pro | Con |
|-----|-----|
| Backwards compatible — existing code works | Requires comptime evaluator (mir_const.qz extended significantly) |
| Incremental adoption | Two representations for same type → conversion overhead at boundaries |
| No ABI break | Comptime complexity (Zig's comptime is notoriously complex) |
| Preserves simple calling convention | Limited benefit for struct-heavy code |

**Estimated effort**: 3-4 months (comptime evaluator + collection specialization)

### 2B: Selective Monomorphization (Rust-inspired)

**How it works**: Generic functions/types get specialized implementations for each concrete type. `Vec<U8>` and `Vec<Int>` become separate functions with different layouts.

**Key ideas for Quartz**:
- Monomorphize only annotated types (`@specialize Vec<T>`)
- Default remains existential (i64) for unannotated generics
- Struct fields can be laid out at natural widths when types are known
- Functions taking concrete types get specialized calling conventions

**Tradeoffs**:

| Pro | Con |
|-----|-----|
| Maximum performance for hot paths | Code size explosion for heavily generic code |
| Natural SIMD-friendly layouts | Two calling conventions (i64 vs specialized) |
| Familiar model (Rust/C++ devs) | Major compiler complexity (MIR + codegen changes) |
| Opt-in preserves backwards compat | Separate compilation becomes harder |

**Estimated effort**: 6-8 months (type specialization + calling convention + codegen)

### 2C: Generational References (Vale-inspired)

**How it works**: Replace raw pointers with generational indices. Each allocation gets a generation number; references encode (pointer, generation). UAF is caught at runtime by comparing generations.

**Key ideas for Quartz**:
- Structs still heap-allocated but tracked via generation table
- `Drop` trait becomes enforced: compiler inserts generation invalidation
- References become (pointer << 16 | generation) packed into i64
- Runtime overhead: one comparison per dereference

**Tradeoffs**:

| Pro | Con |
|-----|-----|
| Memory safety without borrow checker | Runtime overhead per access (~5-15%) |
| Compatible with i64 representation | Generation table memory overhead |
| Incremental — can coexist with raw pointers | Doesn't solve data layout problem (still i64-everywhere) |
| Catches real bugs (UAF, dangling refs) | Novel — less proven than regions or RAII |

**Estimated effort**: 4-5 months (generation table + instrumented accesses)

---

## 3. Recommendation: Approach 2A (Comptime Type Erasure) + Selective 2B

### Rationale

The i64 tax is **data-layout specific**, not **control-flow specific**. Fibonacci proves the calling convention is fine. Sieve proves the storage width matters.

We should:

1. **Phase 1 (Month 1-2)**: Extend `comptime` to specialize collection storage widths
   - `Vec<U8>` → byte-width backing array
   - `Vec<I32>` → 4-byte-width backing array
   - Default `Vec<T>` → 8-byte-width (unchanged)
   - This alone closes the sieve gap

2. **Phase 2 (Month 3-4)**: Value types for small structs
   - `@value struct Point { x: Int, y: Int }` → stack-allocated, 16 bytes
   - Passed by value (2 × i64 in registers), no malloc
   - Addresses nbody and struct-heavy benchmarks

3. **Phase 3 (Month 5-6, stretch)**: Selective monomorphization for hot generics
   - `@specialize` annotation on functions/types
   - Compiler generates specialized versions alongside generic fallback
   - Only for performance-critical paths

### Why Not 2C (Generational References)

Generational references solve a *different* problem (memory safety) that our Drop/defer system already partially addresses. The primary bottleneck is data layout, not lifetime tracking. We can revisit 2C later if safety becomes a priority over performance.

---

## 4. Impact on Existing Code

### Backwards Compatibility

| Aspect | Impact |
|--------|--------|
| Existing programs | **None** — all changes are opt-in via annotations |
| `i64` calling convention | **Preserved** — specialization is internal |
| FFI/C interop | **None** — CPtr, CInt etc. already have correct widths |
| Self-hosting | **Internal** — compiler itself can use new features incrementally |
| Fixpoint | **Must hold** — changes cannot break self-compilation |

### Migration Path

```
v5.26: Vec<U8>/Vec<I32> specialized storage (Phase 1)
v5.27: @value structs (Phase 2)
v5.28: @specialize generics (Phase 3, stretch)
```

Each version is independently shippable. No big-bang migration required.

---

## 5. Implementation Phases

### Phase 1: Collection Width Specialization (Months 1-2)

**Files changed**:
- `middle/typecheck.qz` — detect concrete element types for Vec/Array
- `backend/mir.qz` — emit width-aware alloc/load/store
- `backend/codegen_intrinsics.qz` — specialize vec_push/vec_get/vec_set
- `middle/typecheck_builtins.qz` — width-aware type registration

**Risk**: Medium — codegen changes are localized to collection intrinsics

### Phase 2: Value Types (Months 3-4)

**Files changed**:
- `frontend/parser.qz` — parse `@value` annotation
- `middle/typecheck.qz` — track value vs heap types
- `backend/mir.qz` — stack allocation for value types
- `backend/codegen.qz` — pass value types in registers, no malloc

**Risk**: High — calling convention changes affect every function call

### Phase 3: Selective Monomorphization (Months 5-6)

**Files changed**:
- `middle/typecheck.qz` — `@specialize` annotation, type substitution
- `backend/mir.qz` — generate specialized function variants
- `backend/codegen.qz` — specialized calling conventions
- `self-hosted/quartz.qz` — resolve specialized vs generic dispatch

**Risk**: Very High — fundamental change to compilation model

---

## 6. Open Questions

1. **How to handle `as_int()/as_string()` boundary crossing?** — Specialized collections need to widen/narrow at i64 boundaries. Can this be zero-cost with proper inlining?

2. **Should value types support `Drop`?** — Stack-allocated structs with destructors need compiler-inserted cleanup at scope exit (RAII). This interacts with defer.

3. **Monomorphization vs. virtual dispatch for trait objects?** — If we monomorphize trait implementations, we lose dynamic dispatch. Need to keep both paths.

4. **Impact on closure capture?** — Closures capture variables as i64. Value types would need to be boxed for closure capture, adding overhead.

5. **Interaction with arena allocators?** — Arena-allocated value types would be a contradiction. Need clear rules for which allocator strategy applies.
