# Phase 4 — Generators via Effects: Retrospective

> **Epic**: Operation Piezoelectric Effects · `[piezo]` · Phase 4 (Path B)
> **Status**: **CLOSED** 2026-04-25.
> **Companion docs** (still canonical, not archived):
> - [`PHASE_4_GENERATORS_VIA_EFFECTS.md`](PHASE_4_GENERATORS_VIA_EFFECTS.md) — design memo
> - [`EFFECT_MIGRATION_PLAYBOOK.md`](EFFECT_MIGRATION_PLAYBOOK.md) — discipline + ledger (gained §3.6 from this phase)
> - [`../research/PHASE_4_NONDET_GENERATORS_RESEARCH.md`](../research/PHASE_4_NONDET_GENERATORS_RESEARCH.md) — upstream research synthesis
> **Archived handoffs** (frozen for history):
> - [`../handoff/done/piezo-phase-4-kickoff.md`](../handoff/done/piezo-phase-4-kickoff.md)
> - [`../handoff/done/piezo-phase-4-b7-handoff.md`](../handoff/done/piezo-phase-4-b7-handoff.md)

## 1. What we built

22 commits, three calendar days (2026-04-23 → 2026-04-25). The bespoke generator state machine (`mir_lower_gen.qz::mir_lower_generator`, ~500 LOC of frame-layout + resume-label scaffolding) is gone; every `yield v` now lowers to `perform Yield.yield(v)` through the same kind=3 `$poll` machinery that async/await/spawn/suspend already use. Surface syntax is unchanged; the 23 pre-existing `generator_spec.qz` tests stayed green at every commit; AsyncIterator parity (`effect_poly_for_in_f3c_spec.qz`) held throughout.

| Slice | Commit | Headline |
|-------|--------|----------|
| 4 research | `333edf07` (Apr 23) | Non-det + generators synthesis |
| 4 kickoff | `2b3b3b6e` (Apr 23) | Path C locked, then immediately scope-reset |
| 4a.1 | `e8879c28` (Apr 23) | `effect Yield<T>` decl in `std/gen.qz` |
| 4 scope reset | `39789172` (Apr 24) | Path C → Path B (existing generator runtime exists; migrate it) |
| 4.B.2 | `46b2a039` (Apr 24) | Typechecker pushes `Yield` onto handler stack inside generator bodies; modular `can Yield` helpers compile |
| 4.B.3 | `ff6d4776` (Apr 24) | `POLL_SUSPENDED` sentinel + `__qz_effect_suspend` runtime |
| 4.B.4.a | `a9f86a36` (Apr 24) | `--piezo-gen-b` flag lit; NODE_YIELD routes through kind=3 for `can Yield` helpers |
| 4.B.4.b | `1c229340` (Apr 24) | `Stream<T>` + `.next()` consumer-drive surface |
| 4.B.4.c | `ae8d83fc` (Apr 24) | `impl Iterator<T>` migrates onto kind=3 `$poll` |
| 4.B.5 | `41887b6a` (Apr 24) | `for-in` desugar unification under flag |
| 4.B.6 | `f3f71dee` (Apr 24) | Flag flip — `--piezo-gen-b` deleted, std/gen prelude auto-import |
| 4.B.7.a | `09239242` (Apr 24) | Delete legacy sync-gen state machine (-284 LOC) |
| 4.B.7.b | `142882f4` (Apr 24) | Unify NODE_YIELD routing for async generators (+ default Yield handler) |
| 4.B.7.c | `b95fb63e` (Apr 24) | Rename `__AsyncGen_*$next$poll` → `__Future_*$poll` |
| 4.B.8.a | `465ab0fc` (Apr 25) | Cooperative kind=3 suspend (`resumed=0 ∧ park_rv != 1` returns instead of unwinds) |
| 4.B.8.b | `31755ef1` (Apr 25) | Colorless lift of `can Yield` helpers (PASS 0.99 yield detection + generator-skip) |
| 4.B.8.c | `f3e9d987` (Apr 25) | Modular yield helpers spec (11 tests / 319 LOC) |
| 4.B.8 docs | `e6cb367e` (Apr 25) | Playbook ledger §3.6 (kind=3 cooperative dispatch) |
| 4.B.9.1 | `e0ff7ccc` (Apr 25) | Generator effect composition spec (Yield+Throws, Yield+State) |
| 4.B.9.2 | `573887ae` (Apr 25) | For-loop state preservation across yield (12-line MIR fix) |
| 4.B.9.3 | `f720dca8` (Apr 25) | Generic helper for-in scope (11-line typecheck fix) |
| 4.B.10 | _this commit_ | Retrospective + epic archive |

Fixpoint stamp went 2316 → 2333 (+17 net new functions, mostly std/gen helpers and runtime stubs). Every commit was guard-verified, smoke-tested against `style_demo.qz` + `brainfuck.qz`, and passed cache-enabled cold+warm self-compile.

### New capabilities Path B unlocked

1. **Modular yield helpers** (4.B.8): `def emit_pair(a, b): Void can Yield<Int> { yield a; yield b }` callable from any `def gen(): impl Iterator<Int>` body. Helper-calls-helper composition works (`emit_three(a,b,c)` via three `emit_one` calls). The capability has no analog under the old state-machine path — it would have required per-feature codegen extensions.
2. **Effect composition** (4.B.9.1): `def parse(): impl Iterator<Tok> can Throws<E>` and `def with_state(): impl Iterator<Int> can State<Int>` compile and run, with the generator's row carrying both `Yield` and the secondary effect. Falls out of row polymorphism; no new MIR.
3. **For-loop state across yield** (4.B.9.2): `for x in v ; yield x ; end` inside generator/helper bodies preserves loop iterators across yield re-entry.
4. **Generic helper for-in scope** (4.B.9.3): `def emit_each<T>(items: Vec<T>): Void can Yield<T> ; for x in items ; yield x ; end` typechecks. Generic params no longer poison for-in iter binding via TYPE_ERROR.
5. **One desugar rule for for-in** (4.B.5): same `with Yield { ... } do -> body end` synthesis covers `impl Iterator<T>` and `impl AsyncIterator<T>`. F.3c's hardcoded special case is fold-able once row-poly Stream lands (filed; see §4).

## 2. What surprised us

### The mid-phase scope reset paid off

The Phase 4 kickoff (`2b3b3b6e`) was written assuming a greenfield generator build. The 4a.1 commit landed an `effect Yield<T>` declaration; investigation immediately after discovered Quartz already had a fully-working bespoke generator path (`mir_lower_gen.qz`, 1745 LOC, 23 green tests, AsyncIterator F.3c machinery). Path C's 4a milestones would have duplicated that runtime alongside an effect-based one.

The honest answer was **Path B**: migrate the existing runtime onto kind=3, matching Koka / OCaml 5 / Effekt / Frank literature unanimity. The "universal foundation for non-local control flow" claim that justifies the entire effect epic would have been a lie if generators stayed a runtime carve-out alongside the effect machinery in the same compiler.

The scope-reset commit (`39789172`) and the design memo (`PHASE_4_GENERATORS_VIA_EFFECTS.md`) were the load-bearing decision. Everything after was mechanical: route NODE_YIELD through `mir_emit_kind3_perform_suspend`, replace the bespoke `mir_lower_generator` with `mir_lower_generator_effect` (~80 LOC of thin constructor + Stream wrap), wire the `with Yield { yield: __qz_gen_yield_capture } do -> ... end` install into `Stream.next()`, and lean on the existing `_suspendable_funcs` registry the async path already used.

**Lesson**: PD2 ("design the full correct solution before building — and research what the world already knows") is most load-bearing when current code already kind-of-works. The instinct to leave the working thing alone was wrong; the entire epic's narrative would have been compromised. The user's explicit PD2 invocation at the kickoff/scope-reset boundary is what bought the migration.

### "1-session spec exercise" was wrong twice

4.B.7.b's commit message claimed kind=3 unification delivered modular yield helpers; the original 4.B.8 handoff framed the milestone as "spec writing on a stable substrate." Both were wrong. A 30-second smoke test (`def emit_pair(a, b): Void can Yield<Int> { yield a; yield b } / def my_gen(): impl Iterator<Int> { emit_pair(1, 2); emit_pair(3, 4) }` expected 10, got 0) would have caught it before the handoff was written.

Two structural breakages had to be fixed before "spec writing":

1. **Kind=3 perform unwinds outer state-machine frames** (4.B.8.a). The default kind=3 dispatch longjmps to the matched handler's setjmp buf whenever the handler returns without resuming, even when the handler explicitly suspended. The unwind tears down every C frame between the perform site and the install site, including any intermediate `$poll` state machines mid-poll. Invisible while every yield happened in the body of the same `$poll` whose constructor installed the consumer-drive setjmp (`Stream.next`'s pattern); surfaced the moment a generator delegated to a `can Yield` helper. Fix: split kind=3 dispatch on `(resumed, park_rv)` so cooperative suspend (`park_rv != 1`) returns the handler's value normally rather than unwinding. Now §3.6 of the migration playbook.
2. **PASS 0.99 yield detection** (4.B.8.b). The colorless-call dispatch path needed helpers with `can Yield` to be registered as async targets *before* PASS 1.2a synthesizes parent generators' `$poll` bodies. New synthetic edge to `__qz_yield_marker__` in `mir_propagate_suspend_ast` seeds the fixpoint. Plus generator-skip in the colorless gate (without it, generator-of-generator patterns SIGSEGV).

**Lesson**: when promising scope, the question is "does the headline use case actually work end-to-end?" not "does the compiler accept it?" Smoke-test before sizing. Filed as `feedback_smoke_test_before_sizing.md` candidate for future sessions.

### Bug-doc estimates were systematically too high

Two of the 4.B.9 slices were anticipated as multi-quartz-day architectural rewrites in their bug docs. Both turned out to be 10-12 line fixes:

- **4.B.9.2** (`573887ae`): `FOR_LOOP_STATE_NOT_PRESERVED_IN_POLL.md` sketched a 2-3 day rewrite of `mir_collect_generator_locals` (two-phase collection or post-lowering finalization). Reality: the existing `mir_gen_register_dynamic_local` hook + `GEN_FRAME_PADDING = 32` reserve already supported runtime-time frame registration; six iter-lowering sites in `mir_lower_iter.qz` had simply never called it. The pattern matched what `lower_custom_iteration` and `_lower_async_gen_iter_impl` already did. 12 lines.
- **4.B.9.3** (`f720dca8`): `def f<T>(items: Vec<T>); for x in items; yield x; end; end` emitted "Undefined variable: x" because `tc_parse_type("T")` returns TYPE_ERROR for unresolved generic params, the for-in iter binding stored TYPE_ERROR, and the NODE_IDENT lookup chain treats TYPE_ERROR as "not found." `tc_function`'s parameter-binding code (lines 3992-3997) already had the exact fallback. 11 lines.

**Lesson**: a bug doc's "architectural fix sketch" is a hypothesis written when the symptom is fresh, not a sized estimate. Re-audit current source before trusting it. Two new memory entries (`feedback_existing_dynamic_local_hook.md`, `feedback_type_error_sentinel_dual_purpose.md`) document the existing infra so future sessions don't re-discover.

### `_gen_active` was a four-valued discriminant during the migration (now two-valued)

> **2026-04-25 update**: post-4.B.7.b the discriminant is two-valued — only 0 (inactive) and 2 ($poll rebuild — sync, async, helper) are live. Values 1 and 3 retired with the legacy state-machine path (4.B.7.a) and the inline async-gen $poll emission (later folded by 4D.5b). The lesson below is preserved for the historical record of the migration's biggest near-miss; the four-value model itself is gone.

During the migration, the legacy `_gen_active` module-global was set to four distinct values during MIR lowering, with different runtime contracts:

- `0` — not in a generator/helper body (default).
- `1` — inside the legacy `mir_lower_generator` state-machine path. Deleted in 4.B.7.a.
- `2` — inside an `impl Iterator<T>` body via `mir_lower_generator_effect`. Routes NODE_YIELD through kind=3.
- `3` — inside an `impl AsyncIterator<T>` body via `mir_lower_async_generator`. Stashes via legacy `option_some(val)` to `frame[1]` for the for-await reader. Deleted in 4.B.7.b (async generators now also set `_gen_active = 2` and route yields through kind=3, sharing the same `mir_lower_async_poll` body lowering as sync generators post-4D.5b).

`mir_lower_stmt_yield`'s kind=3 routing condition was tightened from `_gen_active >= 2` to `_gen_active == 2` in 4.B.6 so async generators kept using their legacy stash path until 4.B.7.b explicitly migrated them. The `>= 2` form had wrongly routed async-gen yields through kind=3 perform without an installed handler, producing "unhandled effect op called" runtime crashes on every async-gen test. Recorded as `feedback_gen_active_kind3_routing.md`.

**Lesson**: when broadening a discriminant condition, audit every setter first. The four values had separate contracts; a single broadening assumed two of them shared one.

### The default-handler pattern proved itself again

Three Phase-5 effects (Async, FileIo, Intern) shipped their default handlers in the main prelude via `cg_emit_effect_main_prelude`. Phase 4 followed suit: `__qz_gen_yield_capture` is registered as a program-lifetime default Yield handler, so `Stream.next()`'s `with Yield { yield: __qz_gen_yield_capture } do -> ... end` install is just an H-delegate scan re-affirmation rather than a fresh stack push.

The first-cut design tried wrapping each `$poll` re-entry in its own `mir_emit_handle_install`. That allocated a setjmp frame inside the caller's async `$poll` state machine — and state-dispatch re-entry paths (yield_resume / k3_perform_resume blocks reached via `poll_switch` on state > 0) bypass the install block, violating SSA dominance for the alloca's downstream uses (4.B.7.b commit message captures the diagnosis).

**Lesson**: install/uninstall via `ctx.mir_emit_handle_install` cannot span multiple state-machine iterations of an async `$poll`. The alloca's defining block won't dominate non-state-0 resume paths. Use a default handler (program-lifetime install via `cg_emit_effect_main_prelude`) or wrap each poll in its own self-contained install scope.

This codifies a pattern from Phase 5 that wasn't explicit in the playbook: the prelude-install path is the right answer not just for "an effect we want to dogfood" but for any effect whose handlers must persist across `$poll` re-entries.

## 3. What we'd do differently

1. **Smoke-test the headline use case before writing the next handoff.** 4.B.8 was framed as a 1-session spec exercise after 4.B.7.b. A single `def emit_pair(a, b): Void can Yield<Int>; def my_gen(): impl Iterator<Int> { emit_pair(1, 2); emit_pair(3, 4) }; for x in my_gen() ...` smoke would have surfaced both structural bugs in advance. Cost: 30 seconds. Saved: a full session and an inaccurate handoff.
2. **Audit discriminant setters when broadening conditions.** The `_gen_active >= 2` regression (4.B.6 build run #1) cost a fixpoint cycle. A pre-broaden grep would have revealed three setters with three contracts.
3. **Re-audit current source before trusting bug-doc fix sketches.** Two of three 4.B.9 slices were sketched as architectural rewrites and turned out to be ≤12 lines. The bug-doc author's diagnosis ≠ the bug-doc author's estimate; the latter is a hypothesis, not a measurement.
4. **Default-handler-via-prelude is the default for cross-`$poll` effects.** Phase 5 used it pragmatically for Async/FileIo/Intern; Phase 4 had to re-discover that per-install scoping breaks under state-dispatch re-entry. Codify in the playbook (see §3 below) so future effects start with the prelude pattern unless they explicitly need scoped customization.

## 4. What's still open

Filed as separate items for future sessions; none block Phase 4 closure.

### Multi-shot / `Ndet` (Phase 4b)

The third leg of the original epic. Filed as [`docs/research/PHASE_4B_MULTISHOT_DECISION.md`](../research/PHASE_4B_MULTISHOT_DECISION.md). Pull-in trigger: concrete user need (logic programming, probabilistic programming, backtracking parsers). Until that arrives, the additive cost (frame-clone discipline + Drop-type restriction at perform sites) doesn't pay back.

### Row-polymorphic `Stream<T>`

Memo §3.5's "AsyncIterator unification" proposes folding `impl Iterator<T>` and `impl AsyncIterator<T>` into a single shape parameterized by the source's effect row. Today they share kind=3 but diverge at the consumer:

- `Stream.next()` installs `with Yield { yield: __qz_gen_yield_capture } do ->` and reads `__qz_gen_take_stashed()` on POLL_SUSPENDED.
- For-await over `impl AsyncIterator<T>` reads frame[1] directly (legacy `option_some(val)` stash) and is gated by `_async_gen_func_names`.

Unification needs Stream.next to be row-polymorphic over `can Async` (or a separate AsyncStream<T>), at which point `_async_gen_func_names` deletes, F.3c's hardcoded special case folds into the general for-in rule, and `mir_lower_async_generator` becomes a thin variant of `mir_lower_generator_effect`. This is the row-poly Stream work flagged in 4.B.7's followup list and 4.B.8's "what's still pending" — multi-session, depends on the row-polymorphism story being lifted from Fn callbacks (P3.F) into Stream's value-type API. Open.

### Async-gen + helper interleaving — RESOLVED 2026-04-25 by 4D.5b

`def emit_pair(a, b): Void can Yield<Int>` callable from `def my_gen(): impl AsyncIterator<Int>` works correctly post-4D.5b (`2ca90be3`). Originally filed as blocked on the row-poly Stream consolidation; the producer-side `$poll` merge in 4D.5b (which folded `mir_lower_async_generator`'s inline body lowering into `mir_lower_async_poll`'s state machine) incidentally unblocked it — once both sync and async generators route their bodies through the same kind=3 dispatch, helper composition follows the same path that `generators_p4b8_modular_helpers_spec.qz` already covers for sync generators. Locked in by `phase_4d5b_async_gen_helper_interleaving_spec.qz` (8 tests covering single/multi-yield helpers, conditional helpers, helper-calls-helper composition, mixed direct+helper yields, parameterization, NODE_FOR consumer drive, and row-poly `impl Iterator<T> can Async` form).

### Compiler bugs surfaced during Phase 4 (filed, not fixed)

- [`docs/bugs/GENERATOR_NESTED_WHILE_DOUBLE_YIELD.md`](../bugs/GENERATOR_NESTED_WHILE_DOUBLE_YIELD.md) — pre-existing; reproduces on pre-4.B.6-flag-flip golden. Both legacy and kind=3 paths emit each value twice; bug sits in shared for-in / option-extraction layer.
- [`docs/bugs/VEC_NEW_TYARG_IN_GEN_BODY_CRASH.md`](../bugs/VEC_NEW_TYARG_IN_GEN_BODY_CRASH.md) — `var v = vec_new<Int>()` inside `impl Iterator` body crashes the compiler at exactly 3 pushes. Workaround: annotated binding `var v: Vec<Int> = vec_new()`.
- [`docs/bugs/MAP_KV_GENERIC_PARAM_CRASH.md`](../bugs/MAP_KV_GENERIC_PARAM_CRASH.md) — `def f<K, V>(m: Map<K, V>)` alone (no body) crashes the compiler with "unhandled effect op called". Workaround: concrete or single-generic Map. Same TYPE_ERROR-fallback strategy applies once the underlying ptype-construction path is fixed.
- Async-iterator duplicate `__Future_*$poll` codegen — observed against 4.B.9 baseline; pre-existing.
- Async_iterator scheduler hangs (12/27 tests) — pre-existing, [`docs/bugs/GO_SCHED_BLOCKING_MUTEX_HANG.md`](../bugs/GO_SCHED_BLOCKING_MUTEX_HANG.md) and [`docs/bugs/PIEZO_KIND3_CONCURRENT_PIPE_FLAKE.md`](../bugs/PIEZO_KIND3_CONCURRENT_PIPE_FLAKE.md). Identical pre/post Phase 4. Not a Phase 4 regression.

### Cleanup followups from 4.B.7

Documented in `project_piezo_phase_4_b7.md`; all blocked on row-poly Stream:

1. Consolidate `mir_lower_async_generator` into `mir_lower_generator_effect` + `mir_lower_async_poll`.
2. Delete `_async_gen_func_names` registry.
3. Fold F.3c AsyncIterator row-widening into the general for-in rule.
4. Delete QZ0170 + `tc.reserved[0]` + channel 1 of `_tc_p4b_yield_in_scope`.

## 5. Measured cost

- **Calendar time**: 3 days (2026-04-23 → 2026-04-25), single contributor + Claude.
- **Quartz-time estimate (per CLAUDE.md §9)**: 5-8 quartz-days. Actual: ~3.5. The "÷4 traditional" calibration held; the +0.5 over-estimate covered the scope-reset session.
- **Commits**: 22 (including 2 docs-only and 1 retro/archive — this commit).
- **Net LOC delta**: -200ish overall. 4.B.7.a alone shed -284 (legacy state machine); 4.B.7.b shed another -222; 4.B.7.c shed -20. The kind=3 routing additions and Stream wrappers added back ~300 across mir_lower_gen.qz / mir_lower_async_registry.qz / std/gen.qz / codegen_runtime.qz.
- **Fixpoint stamp**: 2316 → 2333 (+17 functions).
- **Acceptance specs**: 5 new files (`generators_p4b2_typecheck_spec`, `_p4b4a_yield_kind3_spec`, `_p4b4b_stream_next_spec`, `_p4b4c_iterator_poll_spec`, `_p4b5_for_in_spec`, `_p4b8_modular_helpers_spec`, `for_loop_state_in_poll_spec`, `generic_helper_for_in_spec`, `_p4b9_effect_composition_spec`) plus rewrites of 4 existing P4.B specs at the flag-flip. ~70+ tests, ~1000+ LOC of spec code.
- **No runtime perf measurement** — Phase 4 didn't touch the hot path; kind=3 dispatch was already in production for async/await/spawn/suspend, and the migration lowered NODE_YIELD onto the same path. A bench would be measuring the same code as Phase 5's perf measurement (which showed < 0.1% wall delta).

## 6. Cross-references

- Migration playbook: [`EFFECT_MIGRATION_PLAYBOOK.md`](EFFECT_MIGRATION_PLAYBOOK.md) §3.6 (kind=3 cooperative dispatch — added during this phase).
- Architecture doc: [`../ARCHITECTURE.md`](../ARCHITECTURE.md) "Effect Machinery" section. Continuation kind=3 description applies verbatim to generators; no new section needed.
- Project memories (per-slice details):
  - [`project_piezo_phase_4a.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/project_piezo_phase_4a.md) — early slices (4.B.1–4.B.6).
  - [`project_piezo_phase_4_b7.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/project_piezo_phase_4_b7.md) — async-gen unification.
  - [`project_piezo_phase_4_b8.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/project_piezo_phase_4_b8.md) — modular yield helpers.
  - [`project_piezo_phase_4_b9.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/project_piezo_phase_4_b9.md) — composition + state preservation + generic helpers.
- Feedback memos filed during the phase:
  - `feedback_gen_active_kind3_routing.md` — the four-valued discriminant.
  - `feedback_resolver_project_root_autoinclude.md` — prelude import path quirks.
  - `feedback_existing_dynamic_local_hook.md` — for-loop state preservation infra.
  - `feedback_type_error_sentinel_dual_purpose.md` — TYPE_ERROR as "not found" sentinel.

## 7. Phase 4 status

**CLOSED** at the infrastructure level. `Yield<T>` is a first-class effect; `impl Iterator<T>` and `impl AsyncIterator<T>` route through kind=3 like every other suspending op; modular `can Yield` helpers compose; effect composition (Yield + Throws / State) works end-to-end. The "universal foundation for non-local control flow" claim now holds at the foundation.

Multi-shot (Phase 4b) remains deferred per [`PHASE_4B_MULTISHOT_DECISION.md`](../research/PHASE_4B_MULTISHOT_DECISION.md). Row-polymorphic Stream consolidation and the four 4.B.7 cleanup items are filed and tractable; pull when row polymorphism in value types is ready.
