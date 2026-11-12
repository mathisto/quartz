# Handoff: Priority Sprint — Apr 12, 2026

> **Context**: Stack-ranked priority items 1-4 from the updated roadmap.
> **Goal**: Evaluation + implementation plan for a fresh context session.

---

## TL;DR

| # | Item | Verdict | Action |
|---|------|---------|--------|
| 1 | Scheduler park/wake refactor | **Real bug, hard fix** | 2-3 day sprint, detailed plan below |
| 2 | Option smart narrowing (Phase 4) | **No existing narrowing infra** | 2-3 day sprint, detailed plan below |
| 3 | @value Option (Phase 6) | **@value infra exists, adapt for Option** | 1-2 days, leverages existing machinery |
| 4 | Future non-determinism | **May already be fixed** | Verify first (30 min), fix if needed |

---

## Item 1: Scheduler Park/Wake Refactor

### The Bug

~3% hang rate caused by a CAS race on `frame[5]` (park_state) during re-park scenarios. `sched_park_spec.qz` test 4 ("repeated park/wake on same task") is explicitly `it_pending` with note: "blocked: needs async go closures."

### Root Cause

`sched_park()` uses **spin-park** (state 3) — the task stays on the worker thread busy-waiting via `sched_yield()`. When a task parks, gets woken, then parks again, there's a race:

```
Task A: sched_park() → CAS RUNNING(0)→SPIN_PARKED(3) → spin-wait → woken → exit
Task A: sched_park() again → CAS RUNNING(0)→SPIN_PARKED(3) ...
Task C: sched_wake(A) → CAS RUNNING(0)→WAKE_PENDING(2) ← CONCURRENT

If Task C's CAS lands between Task A's "exit from park" and "re-enter park":
  Task A sees frame[5]=2, CAS fails, skips park entirely
  Task A returns from sched_park() without blocking → livelock
```

### State Machine

```
frame[5] values:
  0 = RUNNING
  1 = PARKED (true async park, worker loop manages)
  2 = WAKE_PENDING (wake arrived before park completed)
  3 = SPIN_PARKED (busy-wait on worker thread)
```

### Current Architecture

**Scheduler globals** (`@__qz_sched`, 36 slots): `codegen_runtime.qz:801-872`
**Per-worker data** (12 slots each): local deque, pipes for idle parking
**Worker loop**: `codegen_runtime.qz:1423-2100+` — Chase-Lev work-stealing, LIFO fairness limit (999)
**Park codegen**: `cg_intrinsic_conc_sched.qz:2901-3025` — CAS 0→3, spin-wait loop
**Wake codegen**: `cg_intrinsic_conc_sched.qz:2387-2423` — CAS 1→0 or 3→0, re-enqueue

### Implementation Plan

**The fix**: Convert `sched_park()` from inline spin-park to **cooperative yield-park**. Instead of the task spinning on the worker, `sched_park()` should:

1. Set `frame[0] = YIELD_STATE` (some reserved state number)
2. Set a "park_pending" flag on the frame
3. Return from `$poll` to the worker loop
4. Worker loop sees park_pending → CAS `frame[5]` RUNNING(0)→PARKED(1)
5. Worker does NOT re-enqueue the frame (task is dormant)
6. `sched_wake(frame)` CAS PARKED(1)→RUNNING(0), re-enqueues

This eliminates the re-park race because the worker loop is the sole owner of the CAS transition (no concurrent task execution during transition).

**Phases**:

1. **Add park_pending flag to frame layout** (frame[N] or a MIR-level flag)
   - Files: `codegen_runtime.qz` (frame layout docs), `cg_intrinsic_conc_sched.qz`
   - ~50 lines

2. **Rewrite `sched_park()` intrinsic codegen** to yield instead of spin
   - Instead of CAS 0→3 + spin loop, set park_pending + yield
   - File: `cg_intrinsic_conc_sched.qz:2901-3025`
   - ~100 lines (replace spin codegen with yield codegen)

3. **Update worker loop** to check park_pending after poll returns
   - After `poll_fn(frame)` returns with state >= 0, check park_pending
   - If set: CAS RUNNING(0)→PARKED(1), clear park_pending, skip re-enqueue
   - File: `codegen_runtime.qz` (worker loop)
   - ~40 lines

4. **Update `sched_wake()` to handle PARKED(1) only** (no more SPIN_PARKED(3))
   - Simplify: only CAS PARKED(1)→RUNNING(0) + re-enqueue
   - Keep WAKE_PENDING(2) for wake-before-park race
   - File: `cg_intrinsic_conc_sched.qz:2387-2423`
   - ~30 lines

5. **Un-pend test 4** in `sched_park_spec.qz` and add new stress tests
   - File: `spec/qspec/sched_park_spec.qz`
   - ~50 lines

**Key files**:
- `self-hosted/backend/cg_intrinsic_conc_sched.qz` — park/wake codegen
- `self-hosted/backend/codegen_runtime.qz` — worker loop, scheduler init
- `self-hosted/backend/mir_lower_gen.qz` — async state machine generation
- `spec/qspec/sched_park_spec.qz` — tests

**Risk**: This touches the scheduler's hot path. Every `go` task flows through the worker loop. Regression testing must include `concurrency_stress_spec.qz`, `priority_sched_spec.qz`, `fairness_spec.qz`.

---

## Item 2: Option Smart Narrowing (Phase 4)

### Current State

**Zero flow-sensitive narrowing exists.** After `if opt is Some`, the compiler still treats `opt` as `Option<T>`. Calling `opt!` always does: load tag → compare with 0 → branch to panic/extract.

### Current Option Pipeline

```
opt!
  → parser desugars to $unwrap(opt)                [parser.qz:2763-2769]
  → macro expands to match opt { Some(v)=>v, None=>panic }  [macro_expand.qz:1220-1258]
  → MIR lowers to: tag_check + conditional branch + payload load
  → codegen emits: load tag, icmp eq 0, br, load payload
```

`is Some` check:
```
opt is Some
  → NODE_IS_CHECK (kind 92)                        [ast.qz:977]
  → MIR: load tag, compare with variant index       [mir_lower.qz:1913-1924]
  → codegen: standard i64 comparison
```

These are **completely disconnected** — the `is` check result doesn't propagate to narrowing.

### Implementation Plan

**Phase 4a: Typecheck narrowing context** (~150 lines)

Add a "narrowing map" to `TypecheckState` that tracks which variables are known to be specific variants in the current scope.

1. In `typecheck_walk.qz`, when processing `NODE_IF` where condition is `NODE_IS_CHECK`:
   - Extract subject variable name and variant name
   - Push narrowing entry: `{var_name: "opt", known_variant: "Some"}` for then-block
   - Pop narrowing entry when exiting then-block
   - For else-block: push opposite narrowing (`"None"`)

2. Store narrowings as a stack (scope-aware): `Vec<NarrowingEntry>` on TypecheckState
   - Push on if-then entry, pop on if-then exit
   - Nested ifs stack correctly

**Phase 4b: MIR lowering optimization** (~100 lines)

When lowering `$unwrap(opt)` (which desugars to a match):
1. Check if `opt` has a narrowing entry for "Some"
2. If yes: emit `mir_load_offset(opt, 1)` directly (skip tag check)
3. If no: emit full match (current behavior)

Key file: `mir_lower_expr_handlers.qz` — where match expressions are lowered.

Alternative approach (simpler): Instead of teaching MIR about narrowing, teach the **macro expander** to check narrowing context. If `$unwrap(opt)` is called on a known-Some variable, expand to just `option_get(opt)` instead of a full match.

**Phase 4c: if-let integration** (~50 lines)

`if let v = opt` already desugars to `if Some(v) = opt` with binding. After the binding, `opt` should be marked as narrowed in the then-block. This is the same machinery as Phase 4a applied to the if-let pattern.

**Key files**:
- `self-hosted/middle/typecheck_walk.qz` — add narrowing context to if/elsif
- `self-hosted/middle/typecheck.qz` or `typecheck_util.qz` — NarrowingEntry struct
- `self-hosted/backend/mir_lower_expr_handlers.qz` — skip tag check on narrowed vars
- `self-hosted/frontend/macro_expand.qz` — optional: optimize $unwrap expansion

**Test plan**: New `spec/qspec/option_narrowing_spec.qz`:
- `if opt is Some` then `opt!` doesn't panic (behavioral, already works)
- IR verification: no tag check in then-block (assert_ir_not_contains tag load)
- Nested narrowing: `if a is Some` + `if b is Some`
- Else-block narrowing: `if opt is None` then else-block knows opt is Some
- Re-assignment breaks narrowing: `opt = other_opt` clears narrowing

---

## Item 3: @value Option (Phase 6)

### Current State

Option uses `malloc(16)` for every construction — both Some and None.

**@value struct infrastructure already exists**:
- `mir.qz:2512-2524` — `mir_ctx_is_value_struct()` checks @value flag
- `codegen_instr.qz:710-741` — `MIR_ALLOC_STACK` uses alloca (hoisted to entry), with escape analysis for heap-promotion
- `codegen.qz:87-114` — escape analysis decides alloca vs malloc

### Implementation Plan

**Phase 6a: Mark Option as @value** (~20 lines)

In `typecheck_builtins.qz` where Option is registered as an enum, also register it in the @value struct registry. This needs a bridge: Option is an enum, not a struct, but the @value allocation machinery works on any fixed-size type.

Alternative: Add `MIR_ALLOC_STACK` emission directly in `option_some`/`option_none` intrinsic handlers.

**Phase 6b: Replace malloc with alloca in Option intrinsics** (~80 lines)

In `cg_intrinsic_memory.qz:2710-2831`:
- `option_some()`: Replace `call ptr @malloc(i64 16)` with `alloca [2 x i64]` (hoisted to fn entry)
- `option_none()`: Same replacement
- Add escape analysis: if the Option pointer is stored to a non-local location, heap-promote

Key challenge: Multiple Option constructions in one function need unique alloca names. Use the existing dest register number for uniqueness.

**Phase 6c: Update all 16 intrinsics returning Option** (~50 lines)

Every intrinsic that returns `TYPE_OPTION` (listed in research: `map_get`, `vec_pop`, `str_find`, etc.) constructs Option internally. All use `cg_emit_option_some_inline()` / `cg_emit_option_none_inline()` from `codegen_util.qz:1015-1082`. Update these two inline helpers to use alloca.

**Phase 6d: Escape analysis for Option** (~100 lines)

An Option that escapes its function scope (passed to another function, stored in a collection, returned) must be heap-promoted. Reuse the existing `escaped_regs` tracking from `codegen.qz`.

**Key files**:
- `self-hosted/backend/cg_intrinsic_memory.qz:2710-2831` — Option intrinsic handlers
- `self-hosted/backend/codegen_util.qz:1015-1082` — inline Option construction helpers
- `self-hosted/backend/codegen_instr.qz:710-741` — MIR_ALLOC_STACK handling
- `self-hosted/backend/codegen.qz:87-114` — escape analysis

**Dependencies**: Phase 6 is independent of Phase 4 (narrowing), but they synergize: narrowed Some values that are also stack-allocated become pure SSA registers after LLVM mem2reg.

---

## Item 4: Future Non-Determinism Fix

### Current State — May Already Be Fixed

Investigation found that **all current `__Future_` symbol names use stable string identifiers**, NOT pointer values:

- `mir_lower_gen.qz:1009` — `"__Future_#{name}$new"` where `name` is the function name
- `mir_lower.qz:4237` — `"__Future_#{poll_name}$new"` where `poll_name` = `mangle(actor_name, "__poll")`
- Go-lambdas: `"__Future___go_lambda_#{num}$new"` where `num` is a stable counter

The HANDOFF_SESSION_4 document (Apr 11) described `@__Future_1082221776$new` — a literal pointer value — but the current code doesn't appear to generate such names.

### Verification Step (do this FIRST, ~30 min)

```bash
# Compile actor_spec twice and diff IR
./self-hosted/bin/quartz --no-cache spec/qspec/actor_spec.qz > /tmp/actor1.ll 2>/dev/null
./self-hosted/bin/quartz --no-cache spec/qspec/actor_spec.qz > /tmp/actor2.ll 2>/dev/null
diff /tmp/actor1.ll /tmp/actor2.ll
# If identical: bug is fixed. If different: grep for the non-deterministic symbol.
```

If the bug still exists, search `git log` for changes to `mir_lower.qz` and `mir_lower_gen.qz` around the actor lowering code to find when the pointer-based naming was removed or if it's in a conditional path.

### If Still Broken

Replace any `as_int(obj)` → string conversion used for naming with a monotonic counter. The `mir_ctx_next_lambda()` pattern (`mir.qz:1793-1797`) is the right model — a `u64` counter incremented per function, producing `__Future_actor_0$new`, `__Future_actor_1$new`, etc.

---

## Recommended Sprint Order

1. **Future non-determinism** — Verify first (30 min). If fixed, cross it off. If not, ~1-2 hours to fix.
2. **Option smart narrowing** (Phase 4) — Highest impact compiler change. Flow-sensitive narrowing is foundational.
3. **@value Option** (Phase 6) — Leverages existing @value infra. Natural follow-up to Phase 4.
4. **Scheduler park/wake** — Hardest, most risk. Do last when everything else is green. Needs stress testing.

---

## Key Invariants

- **Fixpoint must hold** after every change. Run `quake guard` before committing.
- **Smoke tests** after guard: `brainfuck.qz` + `expr_eval.qz` (catch semantic regressions).
- **Backup before compiler builds**: `cp self-hosted/bin/quartz self-hosted/bin/backups/quartz-pre-<fix>-golden`
- **Never skip the pre-commit hook.** It exists because 100+ commits were lost without it.

---

## Files Quick Reference

| Area | Key Files |
|------|-----------|
| Scheduler park/wake | `cg_intrinsic_conc_sched.qz`, `codegen_runtime.qz`, `mir_lower_gen.qz` |
| Option intrinsics | `cg_intrinsic_memory.qz`, `codegen_util.qz` |
| Option narrowing | `typecheck_walk.qz`, `typecheck.qz`, `mir_lower_expr_handlers.qz`, `macro_expand.qz` |
| @value structs | `codegen_instr.qz`, `codegen.qz`, `mir.qz` |
| Future naming | `mir_lower_gen.qz`, `mir_lower.qz` |
| Tests | `sched_park_spec.qz`, `force_unwrap_spec.qz`, `actor_spec.qz` |
