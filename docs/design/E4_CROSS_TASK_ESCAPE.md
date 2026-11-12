# Phase E.4 — Cross-Task Escape Mechanism for Reference-Typed Goroutine Returns

**Filed**: 2026-04-28 (post-E.6 ship + POLL_BODY dominance fix).
**Status**: Design memo. Not yet implemented.
**Owner of record**: next session that picks up Phase E.

---

## The problem

Phase E.1.b ships auto-arena via the `go` keyword: every `go fn(args)` where `fn` returns a value type (Int/Bool/Void/Float/Char/CPtr/Symbol) is rewritten at MIR-lowering time to wrap the body in a per-task arena.

```be
go heavy_alloc()
# becomes
go (-> {
  var ar = arena_new(8192)
  var r = with Alloc.in_arena(ar) do -> heavy_alloc() end
  arena_destroy(ar)
  r
})()
```

The conservative gate at `_mir_should_auto_arena` skips reference-typed returns (String, Vec<T>, structs), because the heap pointer they return points into arena pages that `arena_destroy` munmaps — the value would dangle the moment the parent reads it.

E.4 is the mechanism that lifts that gate. After E.4, `go fn()` is auto-arena'd regardless of return type; the runtime promotes the returned value to the parent's allocator before destroying the task arena.

This is the difference between "per-task arena for value-typed scratch" (E.1.b ships this) and "Erlang-style per-process structured memory by default" (the full Phase E exit criterion).

## What other languages do

A research sub-agent surveyed prior art across Rust, Go, Erlang/BEAM, Pony, Koka, Roc, OCaml 5, and the region-typing literature (Tofte/Talpin, Cyclone, MLton, Pacmpl 2023). Highlights:

| Runtime | Mechanism | Cost model |
|---|---|---|
| **Rust + bumpalo** | Type system forbids escape; programmer writes the copy explicitly | Zero runtime; heavy programmer cost; needs lifetime polymorphism |
| **Go** | Compiler escape analysis promotes to global GC heap at allocation time | One global allocation; no copy; GC pressure per escaped value |
| **Erlang/BEAM** | Inter-process message send deep-copies the term graph (`copy.c:copy_struct`); refc binaries >64 B use shared off-heap RC tier | O(value size) per copy; refc tier amortises large payloads |
| **Pony** | Reference capabilities (`iso`/`val`) — sender consumes alias, pointer transfers without copy | Zero runtime; type-system cost; ORCA distributed RC for cross-actor liveness |
| **Cyclone (regions)** | Region-polymorphic types; compiler refuses escapes from region | Zero runtime; static rejection forces explicit copy or global allocation |

The full survey, with citations, lives in this session's transcript and was the primary input to this memo.

**Pattern Quartz is closest to:** a hybrid of **Erlang's copy-on-send** and **Go's escape semantics**. Quartz cannot today take Pony's path (no reference capabilities), and cannot take Rust's path (the auto-arena rewrite needs to be silent — programmers don't see the wrap, so they can't write explicit copies). Erlang's deep-copy on cross-process boundaries maps cleanly: per-task arenas are private heaps, and `await` is the cross-process boundary.

## Recommended approach: per-type promote-fn at task-end

Synthesizing the research:

> **At task body end, before `arena_destroy`, the compiler-emitted glue calls `__qz_promote_<T>(value, parent_alloc) -> heap_value` to deep-copy the return into the parent's allocator. The arena is then destroyed.**

Concretely:

1. **Codegen pass (new):** for each goroutine spawn site that auto-arenas (E.1.b's gate output) AND whose return type is reference-typed, the compiler ensures a `__qz_promote_<MangledType>` function exists in the program. One per type instantiation; closed-world.

2. **Promote-fn shape (per type):**
   - Reference type `T` lays out as known struct/Vec/String at codegen time (Quartz's existential type model: types vanish at runtime but layout is recorded in codegen tables).
   - The fn allocates a fresh value via the parent's `Alloc` handler (NOT under `Alloc.in_arena`), copies header + payload, and recurses on each field if that field is itself reference-typed. For `Vec<T>` of value-typed `T`, payload is one O(n) memcpy. For `Vec<Struct>`, recurse per element.
   - Return value: pointer to the heap-allocated copy.

3. **Spawn-time wrapping (extend E.1.b's MIR synthesis):**
   - Current AST synthesis: `var r = with Alloc.in_arena(ar) do -> fn(args) end; arena_destroy(ar); r`
   - E.4 extension when return-type is reference-typed:
     ```be
     var r_arena = with Alloc.in_arena(ar) do -> fn(args) end
     var r = __qz_promote_<T>(r_arena)   # routes through parent Alloc handler
     arena_destroy(ar)
     r
     ```
   - The promote call deliberately runs *outside* the `with Alloc.in_arena` block, so allocations route to the parent.

4. **Failure path:** If the task panics, the future stores an error result. Promote runs only on success. Error values that are themselves reference-typed need their own promote — gate on result kind. Two promote sites, one per result kind, both before `arena_destroy`.

### Why not the alternatives

- **Copy-on-await (option 2 in the original sketch):** delays the cost to await time. Requires the runtime hook to identify "this pointer belongs to a dead arena" — would need pointer tagging or per-task pointer-range tracking, both nontrivial. Erlang doesn't do this for the same reason: copy-on-send keeps the bookkeeping local.

- **Refcounted arena (option 3):** defeats the eager-free property that motivated per-task arenas. The whole point of E.1.b is "task ends, memory is gone, predictable RSS bound." Refcounting reintroduces the GC-style latency tail. Erlang only refcounts the off-heap binary tier (>64 B), not the per-process heap — that's the right precedent.

- **Promote-on-return (option 4 in the original sketch):** structurally identical to per-type promote-fn; (4) is the same approach described from the codegen-site angle. Adopt (1)'s vocabulary as the canonical formulation.

## Design pivot in the proposed approach

The original ALLOC_EFFECT_PLAN's E.4 entry hand-waved with "per-type promote-fn generation OR copy-on-await runtime hook." The research closes that to **per-type promote-fn**, full stop, on the strength of:

1. Quartz already has all needed type info at codegen time (struct field layouts, Vec element types via codegen tables).
2. Self-hosted compiler can emit the deep-copy walker as plain Quartz IR — no runtime ABI changes needed.
3. The cost model matches Erlang's, which scales to BEAM-class workloads (millions of processes per node).

## Implementation sketch (expected ~2-3 quartz-days, multi-session)

The work decomposes into three slices that can ship across sessions:

### E.4.a — Promote-fn registry + emission (1 quartz-day)

- Detect at MIR-lowering time which types appear as goroutine returns under auto-arena.
- For each, emit `__qz_promote_<MangledType>(src: i64, parent_alloc: i64): i64`.
  - Walks the type's layout from codegen tables.
  - Recursively promotes reference-typed fields.
  - Returns pointer to the new heap-allocated copy.
- Promote-fn registry mirrors the existing intrinsic registry shape (one function per type, dispatched by mangled name).

### E.4.b — Extend `_mir_synthesize_arena_wrap` to call promote (0.5-1 quartz-day)

- Lift the value-type-only gate in `_mir_should_auto_arena`.
- When the callee's return type is reference-typed and a promote-fn exists, synthesize the extended AST:
  ```
  var r_arena = with Alloc.in_arena(ar) do -> fn(args) end
  var r = __qz_promote_<T>(r_arena)
  arena_destroy(ar)
  r
  ```
- Failure path: extend `panic_caught` glue at task-end to promote the error value too.

### E.4.c — Spec coverage (0.5 quartz-day)

- New `spec/qspec/alloc_e4_cross_task_escape_spec.qz`:
  - `String`-returning goroutine: outer reads correct content post-task.
  - `Vec<Int>`-returning goroutine: length + contents preserved.
  - `Vec<Struct>` with reference fields: nested promote works.
  - Closure-returning goroutine (E.4 stretch — see Open Question 2 below).
  - Failure path: panic-returning goroutine's reference-typed error survives.
  - 1000-iteration lifetime test: arena_destroy + promote pair leaks no libc memory (RSS stays bounded across 1000 spawn+await cycles).

## Open design questions before implementing

These need a call before E.4.a can ship cleanly:

1. **Cycle handling.** Quartz Vecs of structs that contain Vecs work fine (tree shape). What if a returned struct contains an internal cycle (rare but possible via `Vec<Box<Self>>` or graph types)? Tofte-Talpin doesn't have this problem (acyclic by construction); BEAM doesn't either (no cycles between immutable terms). Quartz needs an explicit answer:
   - **Detect-and-reject at compile time?** Cleanest. Type-level analysis says "this type is potentially cyclic, refuse to auto-arena it for goroutine returns."
   - **Identity-map in the walker?** Slower but more permissive. Allocates a hashtable per promote.
   - **Most likely landing**: forbid returning self-referential types from goroutines until cycle support is needed; document the restriction.

2. **Closure / function-value returns.** A returned closure may capture arena-allocated environment cells. The promote-fn must walk the closure's capture list. Verify the existing closure-capture metadata is reachable from codegen at promote-emit time.

3. **Generic / polymorphic returns.** `def task<T>(): T` — when T is reference-typed, the promote-fn must be specialised per T. Quartz already monomorphises generics, so each instantiation gets its own promote — but the registry needs to be keyed by mangled instantiation name, not by source-level T. Verify against the current generic-mangling scheme.

4. **Watermark vs. always-copy.** Go-style escape analysis could prove that some goroutines *don't* need promote (e.g., the returned Vec was allocated before any `arena_alloc` happened, or via an explicitly outer allocator). Worth doing as a follow-up optimisation; for E.4 baseline, always-promote is correct and simpler.

5. **`__qz_promote_<T>` discoverability under the cache.** Quartz's separate-compilation cache (`.quartz-cache`) needs to know promote-fns are dependent on type-info hashes; cache-bust correctly when a struct field is added. Same hazard as the existing arena-resident-state cache bug (memory entry [feedback_arena_resident_state_promotion]). Verify the cache key includes the type's layout fingerprint.

6. **Interaction with handler inheritance (E.1.c.b).** The spawn-time effect-stack snapshot installs the parent's handlers in the worker. The promote-fn must run *with* that snapshot active so the parent's `Alloc` is the routing target. Verify the apply-count restoration discipline (memory entry [feedback_e1cb_apply_count_vs_save_top]) covers the post-promote teardown ordering.

7. **Large-value tier (deferred).** Erlang's experience: deep-copying very large messages is unacceptable; their refc-binary tier amortises the cost via shared RC. Quartz analogue would be a sendable-by-pointer tier for large `Bytes` / value-typed-element arrays above some threshold. **Do not entangle with E.4.** File as Phase F territory; the deep-copy default is the right baseline.

## Sequencing

E.4 requires:
- E.1.b shipped ✅ (auto-arena via `go` keyword for value-typed)
- E.1.c shipped ✅ (multi-worker TLS effect stack)
- E.1.c.b shipped ✅ (handler inheritance via snapshot)

E.4 unblocks:
- E.7 (worker-local arena pool — sequencing per ALLOC_EFFECT_PLAN.md).
- Full Phase E exit criterion: "1000s of goroutines each allocating 1 MB, RSS stays bounded, reference-typed returns survive."

E.4 does NOT block:
- E.5 (`arena_destroy` corruption fix) — independent latent bug.
- Compiler dogfood (Phase D was different scope and largely retired).

## Comparable prior art (with citations)

- Erlang/BEAM `copy.c:copy_struct` — the canonical reference implementation. Read [Heap Architectures for Concurrent Languages, Sagonas et al., ISMM '02](https://www.fantasi.se/publications/ISMM02.pdf) for the design rationale (private heaps + copy-on-send beats shared heap on per-process GC isolation).
- Pony's reference capabilities — *not* what Quartz should do (would require a major type system addition), but read [Orca, Clebsch et al., OOPSLA '17](http://janvitek.org/pubs/oopsla17a.pdf) for the cross-actor liveness story.
- Go's escape analysis — the cheapest-at-runtime alternative; rejected because Quartz's per-task arena promise is "tasks have private memory by default," not "compiler proves escape and global-allocates." Quartz is in the BEAM column, not the Go column.
- Tofte-Talpin region typing — instructive for the failure mode: MLton implemented region inference and abandoned it for traditional GC. Lesson: regions are a powerful local optimisation but cannot replace a heap. Quartz's per-task arenas are a *complement* to libc heap, not a replacement.

---

## Cross-links

- **ALLOC_EFFECT_PLAN.md** §Phase E table — E.4 row should be updated to point at this memo as the design call.
- **ROADMAP.md** Tier 1 entry #1 — E.4 is the next-largest unshipped Phase E sub-phase.
- **POLL_BODY_WB_RESULT_SLOT_DOMINANCE.md** — RESOLVED 2026-04-28 (sibling work; not on E.4's path but discovered during E.6 spec authoring).
- Memory entries that load-bear on E.4:
  - [feedback_arena_resident_state_promotion.md] — promote/cache-bust hazard (Open Question 5).
  - [feedback_e1cb_apply_count_vs_save_top.md] — restoration discipline (Open Question 6).
  - [feedback_arena_reserved_keyword.md] — name choice for any new helper functions.

## Pull-in trigger

E.4 is the right next-largest piece of the Alloc-effect initiative. Pull in when:

- A user-level pattern needs a goroutine to return a String / Vec / struct under E.1.b's auto-arena (current workaround: write the goroutine to return Int and reconstruct the value in the caller, OR opt out of auto-arena — both ergonomically painful).
- The full Phase E exit criterion is the next milestone.
- Multi-session budget is available (E.4.a + E.4.b + E.4.c each fit a session).

When pulled in, this memo's "Implementation sketch" section is the entry point. Open Questions 1-6 must be resolved (or explicitly deferred with rationale) before E.4.a starts emission work.

---

## Addendum 2026-04-28 — Open questions resolved

Following four parallel research passes against current source, the six open questions have answers. E.4.a is now unblocked.

### Q1 — Cycle handling: COMPILE-TIME REJECT (forbid + document)

E.4 baseline does NOT support self-referential types as goroutine returns. The MIR-lowering gate (extension of `_mir_should_auto_arena`) inspects the return type's struct registry for direct or transitive self-reference; if found, the auto-arena gate falls through to "current behavior (libc heap, value escapes naturally)." Diagnostic emitted only when the user explicitly requests auto-arena via `go_arena(f)` and the return type is cyclic — silent fallthrough for the implicit `go fn()` form so cyclic returns aren't an error, just an opt-out.

Tofte-Talpin and BEAM both rely on tree-shape immutable values; Quartz inherits the same constraint. Identity-map walker is a Phase F line item, not E.4.

### Q2 — Closure-return promote: DEFERRED to E.4-stretch / Phase F

Sub-agent investigation of `typecheck_capture.qz` and `mir_lower_expr_handlers.qz:431-597` confirms: no closure-metadata registry exists today. Closure capture is materialized at MIR lowering time (`alloc(capture_count + 1)` with `[fn_ptr, cap1, cap2, ...]`), then the metadata is discarded — there is no codegen-time table mapping mangled-closure-name → capture layout.

Adding a `closures_registry: Map<String, ClosureMetadata>` to `MirContext` populated during `mir_lower_lambda()` is feasible but adds ~1-1.5 quartz-days to E.4.a. Goroutine-returning-closure is also an untested code path today (no spec covers it). **Out of E.4 baseline**; covered types are: `String`, `Vec<value-typed-T>`, `Vec<Struct>` (recursing per element), simple structs with reference fields. Function-typed returns from goroutines emit a clear diagnostic: "function-typed goroutine return values not yet supported under auto-arena (Phase F)."

### Q3 — Generic mangling: SUFFICIENT, with one gate fix

Quartz's `mir_flatten_type_for_symbol` / `mir_lower_specialized_function` produce stable mangled names (`Vec$Int`, `Box$String$Int`) sufficient for keying the promote-fn registry. Layout derivation is deterministic via the struct registry + specialization context (`ctx.generics.spec_param_types`).

**Gate hazard:** `_mir_should_auto_arena` at `mir_lower.qz:946` uses `mir_lookup_function(bare_name)` which returns 0 for spec'd names. Same shape as `feedback_spec_async_gen_new_emission.md` (PASS 1.3c miss). E.4.a must extend the gate to also resolve through the specialization path — either by checking `ctx.generics.spec_param_types` after the bare-name lookup misses, or by eagerly registering goroutine-spec'd targets in `mir_lower_specialized_function` (mirrors PASS 1.2a async-target registration).

### Q4 — Watermark optimisation: LOCKED at always-copy baseline

Always-promote is correct for E.4 baseline. Go-style escape analysis (proving "this Vec was allocated outside any in_arena scope, no copy needed") is a follow-up optimization, not an E.4 line item.

### Q5 — Cache discoverability: BASELINE SAFE

`.quartz-cache` keys via source-text content hashes (`std/content_hash`) over the file + every imported `.qz` in the dep graph. Struct layout changes propagate transitively: edit a struct's field → source hash changes → all importing modules' cache fragments invalidate → promote-fns re-emit alongside the modules that use the struct. No explicit interface-hash extension needed.

**Caveat:** Cross-binary cache pollution (`feedback_quartz_cache_pollution.md`) is the existing latent hazard. E.4.a does NOT introduce new cache-correctness risk — promote-fns inherit the same source-hash transitive discipline as every other emitted function. If the cross-binary issue is ever fixed (binary-hash component added to cache key), promote-fns get the fix for free.

### Q6 — E.1.c.b apply-count vs promote ordering: SUCCESS PATH FREE, PANIC PATH NEEDS ORDERING

**Success path:** Snapshot is active through `task_done` (apply-count `top -= K` only undoes the snapshot's K entries; parent's installed handlers above the watermark stay visible). The promote call between `with Alloc.in_arena` exit and `arena_destroy` runs with the parent's `Alloc` correctly routed. No new save/restore needed.

**Panic path:** `panic_caught` (`mir_lower.qz` ~line 4177) tears down the snapshot at `__qz_task_snapshot_take()` (~line 4240) BEFORE returning to scheduler. If E.4 emits a reference-typed-error promote, that promote MUST execute *inside* `panic_caught` *before* line 4240 — or it sees only blessed-watermark `Alloc`, not the parent's installed handler.

**E.4.b requirement:** Extend `panic_caught` to emit promote-and-free for reference-typed error results BEFORE snapshot teardown, mirroring the success-path promote-then-destroy ordering.

---

## E.4.a entry-point summary (post-addendum)

The work to start emission:

1. **Extend `_mir_should_auto_arena` gate** (mir_lower.qz:931–974):
   - Lift the value-type-only restriction at line 973.
   - For reference types, check the struct/Vec/String registry to confirm layout is reachable AND not self-referential (Q1 reject).
   - Resolve through specialization context for spec'd callees (Q3 fix).
   - Skip closure/function-typed returns with a clear diagnostic (Q2 deferral).

2. **Add promote-fn emission pass.** Walks all goroutine-spawn sites the gate accepts; collects unique reference-typed return mangled names; emits one `__qz_promote_<MangledType>` per. Walker body uses codegen layout tables; recurses on reference-typed fields.

3. **Extend `_mir_synthesize_arena_wrap`** (mir_lower.qz:990–1033) to insert the promote call between the `with Alloc.in_arena` exit (`r_let`) and `destroy_call`. New AST shape:
   ```
   var ar = arena_new(8192)
   var r_arena = with Alloc.in_arena(ar) do orig_call end
   var r = __qz_promote_<T>(r_arena)
   arena_destroy(ar)
   return r
   ```

4. **E.4.b panic-path extension** (separate slice): emit promote-and-free for reference-typed error results inside `panic_caught` before `__qz_task_snapshot_take()`.

5. **E.4.c spec coverage:** 5-6 tests covering String/Vec<Int>/Vec<Struct>/simple-struct, success path + panic path, 1000-iter RSS bound. Closure-returning goroutine test deferred (will fail with Q2 diagnostic — and that is correct E.4 baseline behavior).
