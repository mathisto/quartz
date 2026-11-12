# Operation Piezoelectric Effects — Implementation Plan

> **🟢 EPIC COMPLETE — ARCHIVED 2026-04-26.** Every active phase has shipped. The two open items (Phase 4b multi-shot/`Ndet`, Phase 6.3 REPL) are explicitly deferred indefinitely with concrete-user-need pull-in triggers; no calendar deadline is attached to either. This document is preserved for archival reference — design decisions, milestone trackers, and lessons learned. **Live priorities now live in [`docs/ROADMAP.md`](../ROADMAP.md).** Do not pick up work from this file without coordinating with ROADMAP first.

Living plan document (now archive) for the algebraic effects epic in Quartz.

> **Epic name**: Operation Piezoelectric Effects (commit tag `[piezo]`, casually "Piezo"). Named after the piezoelectric effect — the physical property of quartz crystals that converts mechanical stress into electric charge. Curie brothers, 1880.

## Status

**EPIC COMPLETE.** Final summary as of 2026-04-26:

| Phase | Status | Closeout |
|---|---|---|
| 0 — Research | ✅ DONE 2026-04-18 | Three-kind taxonomy committed (Xie & Leijen 2020); evidence-passing compilation. |
| 1 — Throws pilot | ✅ DONE 2026-04-19 | End-to-end `effect / can / with`; `std/log` + `std/parse` pilots. Fixpoint 2210. |
| 2 — State / Reader | ✅ DONE 2026-04-22 | `State<S>` + `Reader<R>` shipped with CLI pilot. 4 milestones. |
| 3 — Async-as-effect | ✅ DONE 2026-04-21/22 | `--piezo-async-await` flag deleted; `spawn` keyword deleted; ~110 user-facing migrations to `go`. P3.0 kind=3 CPS substrate is the foundation for everything below. 10 milestones. |
| 4 — Generators (Path B) | ✅ DONE 2026-04-25 | `mir_lower_generator` deleted; modular `can Yield` helpers; effect composition (Yield + Throws/State). Retro: [`PHASE_4_GENERATORS_RETRO.md`](../design/PHASE_4_GENERATORS_RETRO.md). 22 commits. |
| 4D — Row-poly Stream consolidation | ✅ DONE 2026-04-25 | F.3c folded; `Stream<T,e>` row-polymorphic; struct-level row vars. 14 commits. Memo: [`PHASE_4D_ROW_POLY_STREAM.md`](../design/PHASE_4D_ROW_POLY_STREAM.md). |
| 4b — Multi-shot / `Ndet` | ⏸ DEFERRED INDEFINITELY | Pull-in trigger: concrete user need. Decision memo: [`PHASE_4B_MULTISHOT_DECISION.md`](PHASE_4B_MULTISHOT_DECISION.md). Quartz lives single-shot like Haskell+mtl did for ~20 years; multi-shot is additive when pulled. |
| 5 — Compiler dogfood | ✅ DONE 2026-04-23 | All five compiler-dogfood effects shipped: `Diag` (5.1), `State<TcCtx>` (5.2), `Emit` (5.3), `FileIo` (5.4), `Intern` (5.5). 5.6 retrospective + playbook ([`EFFECT_MIGRATION_PLAYBOOK.md`](../design/EFFECT_MIGRATION_PLAYBOOK.md)) + 3-pass-bootstrap discipline + bridge-over-cascade pattern + 5-incident ledger. ~40 commits. |
| 6.1 — HTTP server effect-first | ✅ DONE 2026-04-26 | 5 subphases, 10 commits, single calendar day. `effect HttpRoute` block-DSL; FileIo-mockable middleware; per-request Throws install. Headline ambition met: **first production HTTP server in any algebraic-effects-native language** per the [framework survey](PHASE_6_HTTP_FRAMEWORK_SURVEY.md). |
| 6.2 — Quake migration | ✅ DONE 2026-04-26 | 3 subphases + closeout, single calendar day. `Reader<Verbosity>` + `Log` + `Exec` + `Throws<BuildError>` migrations. Free `--dry-run` and `--keep-going` flags. Cascade-over-blessed-relaxation lesson captured. |
| 6.3 — REPL | ⏸ DEFERRED INDEFINITELY | Pull-in trigger: web playground / REPL test harness materializes. |

**What landed**: every committed effect from the v6.0 blessed stdlib effects set (14 atomic + 1 row alias) is in production. `Async`, `Yield<T>`, `Throws<E>`, `State<S>`, `Reader<R>`, `FileIo`, `Log`, `Diag`, `Emit`, `Intern`, `HttpRoute`, `Exec`, `Panic`, `ParseError`. Effects are the organizing principle at the foundation level. Single-shot semantics for everything; multi-shot deferred but additive when pulled.

**Total scope**: ~8 calendar days for Phases 1-5 + 4D (Apr 18-25) + 1 calendar day for Phase 6.1 + 1 calendar day for Phase 6.2 + the small `tools/quake.qz` exit-code follow-on that pre-dated the entire epic. Traditional 21-29 weeks ≈ Quartz-time 5-8 weeks; actual delivery was tighter.

**Where to look next**:
- Live priorities: [`docs/ROADMAP.md`](../ROADMAP.md)
- Effect machinery reference: [`docs/EFFECTS.md`](../EFFECTS.md)
- Migration playbook (apply to future effect dogfooding): [`docs/design/EFFECT_MIGRATION_PLAYBOOK.md`](../design/EFFECT_MIGRATION_PLAYBOOK.md)
- Phase 4 generators retro: [`docs/design/PHASE_4_GENERATORS_RETRO.md`](../design/PHASE_4_GENERATORS_RETRO.md)
- Companion research docs: [`NOTATION_PRIMER.md`](NOTATION_PRIMER.md), [`EFFECT_SYSTEMS_NOTES.md`](EFFECT_SYSTEMS_NOTES.md), [`EFFECTS_LLVM_COMPILATION_MEMO.md`](EFFECTS_LLVM_COMPILATION_MEMO.md)
- Active handoffs: none — all `piezo-*` handoffs archived to `docs/handoff/done/` 2026-04-26.

---

## Historical detail (preserved for reference)

The remainder of this document is the as-shipped milestone tracker for each phase, plus design decisions, the decision log, and the teaching/docs cross-cuts. It is preserved because it captures the *why* behind dozens of subtle choices (handler kinds, row polymorphism shape, bridge-over-cascade pattern, etc.) that future effect work will need to consult. New work should not edit this section — file it in ROADMAP and crosslink back here when relevant.

### Phase 4 (formerly active) — closeout

**Phase 4 FULLY CLOSED ✅ 2026-04-25.** Path B (generators-via-effects) shipped in 22 commits across 3 calendar days; legacy `mir_lower_generator` deleted; every `yield v` now lowers through `perform Yield.yield(v)` on the kind=3 `$poll` substrate. Modular `can Yield` helpers + effect composition (Yield + Throws / State) end-to-end. Retro: [`docs/design/PHASE_4_GENERATORS_RETRO.md`](../design/PHASE_4_GENERATORS_RETRO.md). Multi-shot/Ndet (Phase 4b) deferred per [`docs/research/PHASE_4B_MULTISHOT_DECISION.md`](PHASE_4B_MULTISHOT_DECISION.md).
- **Phase 5 FULLY CLOSED ✅ 2026-04-23.** All five compiler-dogfood effects (Diag/State/Emit/FileIo/Intern) at infrastructure level. Phase 5.6 retrospective shipped (`cda7a3cc`): `docs/design/EFFECT_MIGRATION_PLAYBOOK.md` + new "Effect Machinery" section in `docs/ARCHITECTURE.md` + Tier 4 #26/#27/#28 filings. Measured perf delta of wrap deletion: < 0.1 % of wall on self-compile (3 runs each, 13.34 s). Playbook captures three-pass bootstrap discipline + bridge-over-cascade + five-incident ledger. Total Phase 5 commits: ~40; fixpoint 2277 → 2325 across the arc.
- **Phase 4D row-polymorphic Stream consolidation FULLY CLOSED ✅** 2026-04-25 across 14 commits (`9c62955c` kickoff … `07885700` 4D.5c.5 producer-merge fold, plus `90fd9a5a` 4D.6 TC cleanup interleaved, plus this commit's 4D.7 end-to-end spec). All registries deleted; F.3c folded into the general for-in rule; producer-side `$poll` consolidation done; struct-level row-var infrastructure in place; row-poly `Stream<T, e>` shipped in `std/gen.qz`; consumer-side merge (5 subphases 4D.5c.1 → 4D.5c.5) shipped via Path B (kept inline for-in state machine, regularized on `Stream<T,e>` value shape, introduced `__qz_async_park_propagate(rv)` intrinsic for park-encoding propagation). Multi-spec sweep 23/23 across the entire 4D arc. Closing spec: [`spec/qspec/phase_4d7_end_to_end_spec.qz`](../../spec/qspec/phase_4d7_end_to_end_spec.qz) (8 cross-arc invariant tests). Memo: [`docs/design/PHASE_4D_ROW_POLY_STREAM.md`](../design/PHASE_4D_ROW_POLY_STREAM.md). Consumer-merge subarc memo: [`docs/design/PHASE_4D_5C_CONSUMER_MERGE.md`](../design/PHASE_4D_5C_CONSUMER_MERGE.md). Phase 4b (multi-shot / `Ndet`) remains deferred per [`PHASE_4B_MULTISHOT_DECISION.md`](PHASE_4B_MULTISHOT_DECISION.md). Phase 4D.5d (`Stream.next` inlining for explicit `.next()` from async callers) remains a documented Path-B limitation; pull-in trigger is concrete user need.
- **Remaining Phase 3 work**: P3.F (effect-polymorphic async combinators) ✅ **SHIPPED 2026-04-21** across 7 commits (`a37efbde` F.1, `22010548` F.2, `7d40831a` F.3a, `6bf6bcad` F.3b+F.4, `2689558b` F.6, `ee12f372` F.3c, `2001e0f8` close-out memo). Free-function row polymorphism + `Fn(T): U can e` + trait method row storage + `impl Trait<T> can e` + std/streams callback polymorphism + bare `for v in src` auto-dispatch + concrete fix suggestions in QZ0610 errors. Close-out: [`docs/design/P3_F_ROW_POLYMORPHISM.md`](../design/P3_F_ROW_POLYMORPHISM.md) §Close-out.
- **Phase 5 LOC audit COMPLETE 2026-04-25.** Result: **+3.65 % growth** across 20 migrated/infra files (31,368 → 32,513), not the −10–15 % target. Findings + per-effect breakdown in [`EFFECT_MIGRATION_PLAYBOOK.md` §7](../design/EFFECT_MIGRATION_PLAYBOOK.md). Hole filed: 5.1 Diag never got Pass 2b — ~26 surviving body-wraps (~130 LOC) recoverable via blessed-relaxation drop. Tier 4 followup queued (see playbook §7.1).
- **Phase 6 — User-tool dogfooding** (Phase 6.1 ✅ DONE 2026-04-26; Phase 6.2 queued). Phase 6.1 (HTTP server effect-first) shipped end-to-end in 5 subphases, 10 commits, single calendar day: 6.1.a Log migration (41 sites; `e2dfbc2f` + `a1ac20e5`), 6.1.b Throws<HttpError> init-error migration (31 sites across 6 entry points; `7df8b805` + `7867b938` + `ea2ccd09`), 6.1.c per-request frame substrate verified at 1000 fibers + Throws kind=2 unwind + per-request `with Throws` install (`7268556e` + `02203e43` + `a6fa4838`), 6.1.d `effect HttpRoute` + block-DSL `http_serve(port, body)` overload + `route_<method>` verb performers (`70869a78`), 6.1.e middleware migration: `_static_handle_request` routes filesystem access through the FileIo effect (`fio_read`/`fio_exists`), unlocking `with FileIo { fio_read: fixture, fio_exists: predicate } do -> http_serve(...) end` test mocking with no real filesystem; with_logging already routed through Log effect (6.1.a); with_cors stays plain (no I/O surface); new `examples/http_effects.qz` shows the canonical 5-line hello world + a `_demo_unit_test` running the full pipeline through mocked FileIo+Log; 5-test acceptance spec covers default-handler path, FileIo mock injection, falls-through-on-deny, R3 Log ordering equivalence, and full FileIo+Log composition (5/5 green; broader regression sweep 87/87 across 13 specs). v2-v4 (named pipelines, typed extractors, Tapir-style `Endpoint<I,O,E,eff>`, Effekt-style capabilities) filed as 6.1.f-k follow-ons. Phase 6.2 (Quake migration) — 3 subphases, ~1-2 quartz-days; ships free `--dry-run` and `--keep-going` modes. Phase 6.3 (REPL) deferred indefinitely. Design memos: [`docs/design/PHASE_6_1_HTTP_EFFECTS.md`](../design/PHASE_6_1_HTTP_EFFECTS.md), [`docs/design/PHASE_6_2_QUAKE_EFFECTS.md`](../design/PHASE_6_2_QUAKE_EFFECTS.md). Research: [`docs/research/PHASE_6_HTTP_FRAMEWORK_SURVEY.md`](PHASE_6_HTTP_FRAMEWORK_SURVEY.md) — 4-agent parallel survey of ~30 frameworks; **headline finding: no production HTTP server exists in any algebraic-effects-native language as of April 2026**. Handoff: [`docs/handoff/piezo-phase-6-kickoff.md`](../handoff/piezo-phase-6-kickoff.md).
- **Last updated**: 2026-04-26 (Phase 6.1 DONE end-to-end in a single calendar day — 6.1.e closes with FileIo migration of `_static_handle_request` + canonical `examples/http_effects.qz` + 5-test acceptance spec; no quake guard needed since std/net + std/file_io not on compiler's import graph).
- **Governing doc**: [`docs/EFFECTS.md`](../EFFECTS.md) (stubbed 2026-04-18)
- **Companion docs**: [`docs/research/NOTATION_PRIMER.md`](NOTATION_PRIMER.md), [`docs/research/EFFECT_SYSTEMS_NOTES.md`](EFFECT_SYSTEMS_NOTES.md), [`docs/research/EFFECTS_LLVM_COMPILATION_MEMO.md`](EFFECTS_LLVM_COMPILATION_MEMO.md), [`docs/design/EFFECT_MIGRATION_PLAYBOOK.md`](../design/EFFECT_MIGRATION_PLAYBOOK.md)
- **Session handoff (current)**: [`docs/handoff/piezo-phase-6-kickoff.md`](../handoff/piezo-phase-6-kickoff.md) — Phase 6 user-tool dogfooding. **Phase 6.1 closed**; **Phase 6.2 (Quake migration) is next**.
- **Predecessor handoffs**: archived in `docs/handoff/done/` — see `piezo-phase-4-kickoff.md` and `piezo-phase-4-b7-handoff.md` (this epic), `piezo-phase-5-6-handoff.md`, `piezo-phase-5-5-c-followup-handoff.md`, back through milestones A/B/C/D and Phase 2/3.

### Phase 1 milestone tracker

| Milestone | Status | Commits | Deliverable |
|---|---|---|---|
| A — surface syntax | ✅ SHIPPED 2026-04-18 | `86e0f906` | Parser accepts `effect / can / with / reify` (data discarded). |
| B — typecheck rows | ✅ SHIPPED 2026-04-19 | `6b2af5ba` (B.1), `3ecde1a4` (B.2), `12b1f992` (B.3), `31ba2f97` (B.4), `ea7a7cb7` (B.5), `6fbf38f0` (B.6), `54dcdf5b` (B.7), B.8 integration | Type system understands effects; QZ0610 fires at call-site mismatches. 38 piezo QSpec tests across 7 spec files. Fixpoint 2147 → 2181. |
| C — MIR + AST + handler narrow | ✅ SHIPPED 2026-04-20 | `6e94caa8` (C.1), `82914b75` (C.2), `fea2a4c9` (C.3), `cfb3edfb` (C.4), `4539fd77` (C.7), `d869d499` (C.8) | NODE_WITH + tc narrowing + MIR_PERFORM_OP/HANDLE_INSTALL/UNINSTALL + kind 0/1 classifier. 88+ piezo tests across 15 specs. Fixpoint 2181 → 2199. |
| D — codegen + runtime + stdlib | ✅ SHIPPED 2026-04-20 | `a28466ba` (D.1+2+3), `c8b09217` (D.4), `c4fef68f` (D.5), `22a05329` (D.5b), `04f723cf` (D.7), `02ffe2e2` (D.8) | End-to-end dispatch: default Throws + Log handlers; user handler records; arg0 threading; cross-module effect decl registration via `RESOLVE_TAG_EFFECT_DECL`; std/log pilot. 141 tests across 20 specs. Fixpoint 2199 → 2210. |

### Phase 2 milestone tracker (post-D follow-ons)

| Milestone | Status | Commits | Deliverable |
|---|---|---|---|
| F — kind=2 resumable ops | ✅ SHIPPED 2026-04-20 (F.3c-real deferred) | `f7af5986` (F.2), `20176cd8` (F.3a), `72c0ee94` (F.3b), F.3c-integration | F.1 verified parser retention; F.2 classifier; F.3a `resume(v)` = `return v` sugar; F.3b setjmp/longjmp unwind for kind=2 (install+perform take buf/kind; new runtime globals stack_bufs/stack_results). Exception-style algebraic effects end-to-end. F.3c-real (handler continues after resume via CPS / $poll state-machine reuse per memo §3) filed as separate multi-session milestone. 189 piezo tests across 25 specs. Fixpoint 2210 → 2214. |
| G — static evidence dispatch (Path A, MVP kind<2) | ✅ SHIPPED 2026-04-20 | `c275449f` | Lexical handler stack on MirContext pushed/popped at NODE_WITH (expr + stmt). `mir_emit_perform_op` consults it; matching (eff, op) stashes the handler fn as-int onto `operand1`. Codegen fast-paths kind<2 (function-kind) annotated performs to a direct `@handler(op, argc, argv)` call — no `__qz_effect_perform` scan, no `cstr_eq`, no kind arg. Dynamic dispatch preserved for non-lexical performs (transitively-called functions with `can` rows) and kind=2 (unwind via longjmp). ABI-identical direct call; smoke tests (style_demo + brainfuck) and 28/28 effect specs green. 3 IR-shape assertions updated from `@__qz_effect_perform(ptr ` pattern to `@handler(ptr ` pattern. Fixpoint 2219 → 2222 (+3 helpers: `mir_ctx_push_handler_entry`, `mir_ctx_pop_handler_entries`, `mir_ctx_lookup_handler`). G-extended (kind=2 fast path, requires wb.jmpbuf + result-slot threading at perform site) filed as followup below. |
| H — handler record multi-op dispatch | ✅ SHIPPED 2026-04-20 | `833e0f7e` | MIR lowering synthesizes one `__qz_eff_shim_N` per multi-op `with E { op1: h1, op2: h2 } do ... end`; codegen emits shims in `cg_emit_effect_dispatch_shims` (block-chain of `__qz_effect_cstr_eq` checks routing to the matching user handler). Install uses the shim as its single fn ptr. Single-field path unchanged. Unlisted-op → `__qz_effect_unhandled`. 8 tests `effect_multi_op_dispatch_h_spec.qz`. Fixpoint 2214 → 2221. |
| E(post) — full argc/argv op arguments | ✅ SHIPPED 2026-04-20 | `21f81dab` | Runtime `__qz_effect_perform(ptr eff, ptr op, i64 argc, ptr argv, i64 kind)`. Each call site stack-allocas `[argc x i64]`, stores each arg, passes ptr. Handler/shim/default-handler ABI now `i64 (ptr op, i64 argc, ptr argv)`. User handlers decode via `load(argv, i)`; String args round-trip through `as_string()`. Zero-arg ops pass `argc=0, argv=null`. 14 new tests (7 migrated D.5b + 7 new multi-arg E). Fixpoint 2221 → 2221 (bodies-only change). |
| I — typed effect-arg decode helpers | ✅ SHIPPED 2026-04-20 | `f2b4600c` | New `std/effects.qz` module exporting `effect_arg_int(argv, i)` and `effect_arg_string(argv, i)` — one-line wrappers around `load(argv, i)` and `as_string(load(argv, i))` respectively. Cosmetic but lets handler bodies read like typed functions rather than scatter `as_string(load(...))` boilerplate. 3-test `std_effects_i_spec.qz` (int-only op, string-only op, mixed-kind 3-arg op — the parse-error shape). |
| J — std/parse pilot | ✅ SHIPPED 2026-04-20 | `82e09b06` | `std/parse.qz` minimal arithmetic expression parser (int literals, `+`, `-`, `*`, `/`, parens, whitespace; recursive descent with precedence). Error reporting via `ParseError` effect with 3-arg op `parse_error(line: Int, col: Int, msg: String): Int = resume(0)` (kind=2 — G-extended fast-pathed). Proves end-to-end: multi-arg argc/argv ABI, kind=2 static unwind, cross-function `can ParseError` propagation, handler-return-becomes-with-block-value semantics. 10-test acceptance spec `std_parse_j_spec.qz` (happy paths + 4 distinct error shapes + semantics verification). Also fixed pre-existing `std_log_d7_spec` regression — the spec's handler used the retired D.5b `(op_name, arg0)` ABI; migrated to current `(op_name, argc, argv)` and updated std/log's docstring to match. |
| K — effect+generic composition audit | ✅ SHIPPED 2026-04-20 | `c504bc8e` | 5-test audit `effect_generic_composition_k_spec.qz`: bounded generic with `can Throws`; generic calling multi-arg op; implicit row inheritance; B-era QZ0611 still fires in generic body; two-generic-param fn with multi-arg op. All green; B+D+E(post) layers compose cleanly. |
| F.3c-real — continuation-preserving resume | ➡️ moved to Phase 3 as P3.0 (2026-04-20) | — | Reclassified as the foundation milestone of Phase 3 (async-as-effect). The original deferral note was correct — F.3c-real and Phase 3 share the same $poll-reuse machinery; sequencing them together removes duplicated design work. See Phase 3 tracker below and [`docs/handoff/piezo-phase-3-kickoff.md`](../handoff/piezo-phase-3-kickoff.md). |
| G-extended — static fast path for kind=2 | ✅ SHIPPED 2026-04-20 | `aca96e99` | Extends G.MVP to kind=2 (operation-kind / unwind) performs. `mir_ctx_lookup_install_dest` parallel-walks the handler stack for the matching install's dest register; stashed on `MirInstr.op` (NOT operand2 — that's `func_name`). Codegen emits: direct handler call → store rv to `@__qz_effect_stack_results[%wb.pretop.<install_dest>]` (slot 0 of the N-wide OR-fold is sufficient; all slots are zero-initialized at install) → `call void @longjmp(ptr %wb.jmpbuf.<install_dest>, i32 1)`. `@longjmp` is already declared `noreturn`, so LLVM treats fall-through as dead. Now bypasses `__qz_effect_perform` for lexical Throws/Panic/user-`= operation(...)` performs — the most-common effect path in the current codebase. Discovered mid-implementation: operand2 is shared with `func_name` (op name) via `mir_instr_set_func_name`; first attempt clobbered op name, causing SIGSEGV in `qz_str_get_len` at codegen. Fix routed install_dest through `op` field instead. 28/28 effect specs green + smoke (style_demo, brainfuck). Fixpoint 2222 → 2223 (+1 helper). |
| H-delegate — outer-handler fall-through for unlisted ops | ✅ SHIPPED 2026-04-20 | `9c0e2b11` | Dropped shim synthesis entirely. Multi-op `with` records push ONE stack entry per op (new parallel `@__qz_effect_stack_op_filters` array carries op-name ptr, 0 = "any op"). `__qz_effect_perform` scan matches `eff_name AND (op_filter == null OR cstr_eq(op_filter, op))`. Install ABI gained a 4th param (op_filter). MIR_HANDLE_INSTALL rewritten to carry an entries vec (pairs of op_filter+handler_fn); codegen emits shared jmpbuf/result_slot frame + N runtime install calls. UNINSTALL pops N entries. Deleted: `cg_emit_effect_dispatch_shims` (~90 LOC), `mir_register_effect_shim` + 5 accessor fns (~40 LOC), MirProgram effect_shim_* fields (~15 LOC). Net LOC delta: ~-150. Silently fixes single-field bug (was binding handler to ALL ops of effect; now binds only named op). Fixpoint 2221 → 2214 (-7 fns deleted). 5 new tests `effect_h_delegate_fallthrough_spec.qz` + 3 rewritten H regression tests. 28 specs / ~215 tests. |

### Phase 3 milestone tracker (async-as-effect migration)

Per [`docs/handoff/piezo-phase-3-kickoff.md`](../handoff/piezo-phase-3-kickoff.md). F.3c-real moved here as P3.0 foundation — always was the unblocker for async migration per memo §3.

| Milestone | Status | Commits | Deliverable |
|---|---|---|---|
| P3.0 — F.3c-real: continuation-preserving resume | ✅ SHIPPED 2026-04-20/21 | P3.0a…c-runtime, `3a2f373f`, `04e9f94d`, `9044546e`, `76017e3d`, `2cf9a645`, `e8011737` | `resume(v)` in kind=3 handlers delivers `v` into the continuation via `__qz_effect_resume_cont` nested-invocation of the caller's `$poll`; handler continues past its own resume call; with-block = body's return (memo §Q6). Kind=2 retained for unwind/escape (Throws, Panic, ParseError). E2E spec `effect_op_kind3_p3c_perform_spec.qz` 4/4 green. Fixpoint 2232. Scheduler integration: kind=3 callers use `go` (same as existing EFFECT_SUSPEND functions — no compiler magic). |
| P3.A — Async effect decl + three-kind classifier | ✅ SHIPPED 2026-04-21 | `b9832a44` | `effect Async { await, spawn, suspend, yield }` in `std/async.qz`; each op tagged `= operation`. Classifier helper `tc_body_is_operation_marker` upgrades matching body shape to kind=3 before resume-call dispatch — memo §2.4 explicit-syntax knob. All four Async ops now kind=3 (was 1/1/1/0 transitional). 6/6 P3.A spec tests green. Fixpoint 2232 → 2233. Dormant: routing (NODE_AWAIT → perform) is P3.C. |
| P3.B — Scheduler as default Async handler | ✅ SHIPPED 2026-04-20 | `254ea836` | `__qz_default_async_handler(op, argc, argv)` emitted in `codegen_runtime.qz`; dispatches on op name via `__qz_effect_cstr_eq`: `yield` → `usleep(1)`, others (`await/spawn/suspend`) → stub return 0. Install hooked into `cg_emit_effect_main_prelude` before `qz_main()`; `op_filter=null` catches any Async op. User `with Async { op: h } do ... end` overrides via standard H-delegate top-of-stack wins. 7/7 P3.B spec tests green. Stubs get real scheduler delegation at P3.C/D/E migration cutover. |
| P3.C — Migrate NODE_AWAIT → `perform(Async, await)` | 🟢 FULL PATH VALIDATED (default + user override) | `25978823` (C.0), `d3b090d8` (C.1), `82c6d594` (C.2+C.3 bundle), `a6b038df` (C.4), `a22b2b60` (parser hang fix) | Under `--piezo-async-await`, NODE_AWAIT in $poll-lowered callers routes through `mir_emit_kind3_perform_suspend(ctx, "await", "Async", [handle])`. Default `__qz_default_async_handler`'s await branch busy-polls, loads result, calls `__qz_effect_resume_cont(rv)` → kind=3 re-enters caller's $poll. User override via `with Async { await: my_h } do ... end` also works end-to-end (`a22b2b60` fixed the parser hang that blocked reserved-keyword op-filter keys). E2E `piezo_async_await_migration_p3c_spec` 7/7 (single-await, chained awaits, nested async pyramid, eager-done fast path, user override). Flag-OFF bit-for-bit identical to pre-P3.C. P3.G prerequisite (parser fix) cleared. Remaining for P3.C: none — ready for P3.G's deletion commit once P3.D/E also migrate. Design memo: `docs/design/P3_C_AWAIT_MIGRATION.md`. Busy-poll is baseline — park-for-wake deferred. |
| P3.D — Migrate NODE_GO / go-lambda → `Async.spawn` | ✅ SHIPPED 2026-04-21 | `7f564002` | Under `--piezo-async-await`, both NODE_GO shapes (lambda + named-fn) build frames as before, then dispatch the scheduler enqueue via `perform(Async, spawn, [frame])` at **kind=1** (function-kind) instead of the `sched_spawn` intrinsic. `spawn` dropped its `= operation` marker in `std/async.qz` — semantically spawn returns a handle and does not capture the caller's continuation, so kind=1 is correct (forcing kind=3 would $poll-lower every `go`-containing function including synchronous `main`, a large regression surface with no benefit). Default `__qz_default_async_handler`'s `do_spawn` branch auto-inits scheduler + calls `__qz_sched_spawn(frame)` + returns frame. Handler's spawn branch is gated on `prog.mir_get_uses_scheduler()` (new runtime-emit parameter threaded through `cg_emit_effect_runtime`) — dormant `import std/async` programs with no `go` get a `ret 0` stub (no scheduler runtime emitted → no undefined symbols). G-extended static fast path fires for lexical `with Async { spawn: h } do ... end` overrides. 6/6 e2e `piezo_async_spawn_migration_p3d_spec`: single `go f() + await`, go-lambda statement form with captured variable sent over channel, flag on/off parity, multi-spawn compose (await-all), user override via H-delegate, dormant-import-no-go. `std_async_p3a_spec` updated to expect `spawn kind=1`. Flag-OFF bit-for-bit identical to pre-P3.D. Fixpoint 2235 unchanged (same function count as pre-P3.D — no new helpers). |
| P3.E-lite — Async row propagation for scheduler intrinsics | ✅ SHIPPED 2026-04-21 | `9852cf7d` | Under `--piezo-async-await`, calls to `io_suspend`, `io_suspend_timeout`, `sched_yield`, `sched_sleep`, `proc_suspend` widen the caller's effect row with `Async` (same shape as P3.C.1 for NODE_AWAIT). Row propagation only — the runtime intrinsics + `mir_emit_async_suspend_point` park-for-wake mechanism stay exactly as-is. Split from P3.E because real runtime migration requires extending kind=3 to support handler-driven park (see P3.E-runtime below). 4/4 `piezo_async_io_row_p3e_lite_spec` regression tests green (flag-on parity on sched_yield in loop, explicit `can Async` idempotence, non-Async `can Throws` tolerates sched_yield via blessed-effect relaxation, io_suspend-backed channel recv parity). Observable row-widening is invisible today — `tc_dump_effect_rows` reads stored-row labels, not walked tails — matching the P3.C.1 precedent. The widening surfaces at P3.E-runtime (or a future walked-tail dump mode). Fixpoint 2235 unchanged. |
| P3.E-runtime — park-for-wake kind=3 + runtime migration | ✅ SHIPPED 2026-04-21 | `9bee1493` | Extended `mir_emit_kind3_perform_suspend` epilogue: resets new `@__qz_effect_park_rv` TLS to POLL_READY before perform, loads TLS after perform, `ret %tls_rv` instead of hard-coded POLL_READY. New runtime helpers `@__qz_effect_park(fd)` (stashes `-(fd+2)` into TLS — same encoding today's `io_suspend` emits from `mir_emit_async_suspend_point`), `@__qz_effect_park_reset()` (TLS ← 1), `@__qz_effect_park_get_rv()` (load TLS). Default Async handler `do_suspend` branch: call `__qz_effect_park(argv[0])`, ret 0. All 5 scheduler intrinsics migrated under `--piezo-async-await`: `io_suspend(fd)`, `io_suspend_timeout(fd, ms, ev)`, `sched_yield()`, `sched_sleep(ms)`, `proc_suspend(pid)` all route through `mir_emit_kind3_perform_suspend(ctx, "suspend", "Async", [fd_or_pid_or_0_or_-1])`. Pre-TLS flags (io_set_pending_proc/timeout/events/sleep) set in MIR lowering BEFORE the perform — unchanged from today's intrinsic path. Worker's `task_io_real` read-and-dispatch on those TLS flags unchanged. Yield uses fd=-1 → TLS encodes -1 → scheduler task_yield branch (poll_result < -1 is false, so goes to re-enqueue). Backward compat: handlers that resume synchronously (P3.C await default, P3.0c resume sites) don't touch TLS → outer ret POLL_READY as before. Flag OFF: legacy `mir_emit_async_suspend_point` path unchanged. 5/5 new `piezo_async_suspend_migration_p3e_runtime_spec` (yield loop, single-channel recv, multi-producer/consumer, await backward-compat, spawn backward-compat). Fixpoint 2235 → 2238 (+3 helpers). **Unblocks P3.G** — all scheduler intrinsics now dispatch through the effect system; the dedicated NODE_AWAIT/NODE_GO/io_suspend special-case lowering can be deleted once flag-on is proven the default. |
| P3.F — Effect-polymorphic async combinators | ✅ SHIPPED 2026-04-21 | `a37efbde` (F.1), `22010548` (F.2), `7d40831a` (F.3a), `6bf6bcad` (F.3b+F.4), `2689558b` (F.6), `ee12f372` (F.3c), `2001e0f8` (close-out memo) | All six F milestones shipped same-day. F.1 row-var scope env in function signatures (lowercase = row var, uppercase = type var). F.2 `Fn(T): U can e` + call-site instantiation reading ORIGINAL tail (not walked — critical for multi-site polymorphism). F.3a trait method row storage. F.3b `impl Trait<T> can e` parses + std/streams (5 combinators) callback-polymorphic. F.3c bare `for v in src` auto-dispatches async iteration (consumer-widens convention). F.6 concrete fix suggestions in QZ0610 errors. Fixpoint 2236 → 2253 (+17 helpers). 5/5 `effect_poly_stream_f4_spec` + 4/4 `effect_poly_fn_can_f2_spec` + collection-combinator polymorphism. **Open followup** (multi-session): row-polymorphic Stream consolidation — Stream<T,e> as a value-type API, deletes `_async_gen_func_names` registry, folds F.3c's hardcoded for-await special case into general for-in rule, reduces `mir_lower_async_generator` to thin variant. Kickoff: [`docs/design/PHASE_4D_ROW_POLY_STREAM.md`](../design/PHASE_4D_ROW_POLY_STREAM.md). Close-out memo: [`docs/design/P3_F_ROW_POLYMORPHISM.md`](../design/P3_F_ROW_POLYMORPHISM.md). |
| P3.G — Delete `--piezo-async-await` flag (PD7) | ✅ SHIPPED 2026-04-21 | `3b21ffa8` | Flag deleted. All four flag-gated callsites (`typecheck_walk.qz` NODE_AWAIT row widen, `typecheck_expr_handlers.qz` scheduler-intrinsic row widen, `mir_lower.qz` NODE_GO + NODE_AWAIT routing, `mir_lower_expr_handlers.qz` 5 scheduler intrinsics) inlined to the Piezo path only. `self-hosted/shared/feature_flags.qz` deleted; CLI flag `--piezo-async-await` removed. P3.C/D/E spec files rewritten without flag gating; P3.C.0 flag-plumbing spec deleted. Fixpoint 2238 → 2236 (-2 fns: setter + getter). **Narrower scope than brief:** MIR_SPAWN / MIR_AWAIT opcodes **not** deleted — they remain live for `spawn expr` keyword (`NODE_SPAWN` → `MIR_SPAWN` → pthread_create) and the outside-$poll NODE_AWAIT pthread_join fallback (`mir_lower.qz:1363,1373`), neither of which was ever routed through the Piezo flag. Migrating those is filed as **P3.G-followup** (see below). Inside-$poll dead-code branches in `mir_lower.qz` NODE_AWAIT handler (`is_known_lazy` lazy-poll + `dyn_*` dynamic-poll — lines ~1161-1315) also not touched this commit; per-PD7 they're now unreachable and should be deleted in a follow-up surgical pass. Dropped in the P3.G commit: flag reader at 4 sites + CLI flag + module + 1 spec. Regression sweep green: 132/132 tests across 19 effect + scheduler specs, 65/65 across 11 async-surface specs, 3/3 smoke (brainfuck, style_demo, expr_eval). Surfaced pre-existing scheduler flake (`docs/bugs/PIEZO_KIND3_CONCURRENT_PIPE_FLAKE.md`) in `async_io_spec` concurrent-pipe tests (~15% flake rate — 100-run bisection confirms same rate on pre-P3.E-runtime legacy path, so NOT a Piezo regression; root cause in the scheduler's fd-registration vs poller-wake race, orthogonal to Phase 3). P3.H scheduler perf benches use channel notify-fds, not raw pipes, and are NOT blocked. |
| P3.G-followup — unify concurrency under `go`, delete MIR_SPAWN/MIR_AWAIT opcodes | ✅ SHIPPED 2026-04-22 | this commit | **Forcing-question decision: unify under `go` (Option B).** `spawn` keyword deleted entirely from lexer/parser/ast/typecheck/mir_lower/codegen. All ~110 user-facing `spawn <expr>` sites (32 spec files + std/futures.qz + std/concurrency.qz + examples + benchmarks + tools + projects/gossip-chat) migrated via `perl -i -pe` to `go`. `go` extended to auto-wrap bare lambdas (`go (-> body)` → `go (-> body)()` inside parser, so pre-existing go_is_lambda MIR branch handles the canonical call shape). Fixed latent `mir_lower_go_lambda_poll` bug: bare-expression lambda bodies (`-> 42`) were lowered as stmt and their value discarded — now kind-branches on NODE_BLOCK vs bare expr and stores expr value into frame[1]. **Deletions:** TOK_SPAWN + keyword-map entry (lexer.qz), `TOK_SPAWN` constant (token_constants.qz), `ps_is_stmt_starter` + `ps_is_method_name_token` TOK_SPAWN checks (parser.qz), `ast_spawn` helper + `NodeSpawn` enum + `NODE_SPAWN` constant (ast.qz + node_constants.qz), macro_expand NodeSpawn branch, typecheck NODE_SPAWN branch + `tc_check_spawn` (typecheck_walk.qz + typecheck_concurrency.qz), NODE_SPAWN handler in mir_lower (~65 LOC), NODE_AWAIT outside-$poll pthread-fallback three-way dispatch (~50 LOC collapsed to two-way eager-future vs completion_await), `MIR_SPAWN` + `MIR_AWAIT` opcodes in mir.qz + mir_emit_spawn/mir_emit_await helpers, 212 LOC codegen_instr.qz handlers (pthread_create + pthread_join + all three wrapper branches), `cg_emit_spawn_wrappers` entirely (~145 LOC emitting `__closure_spawn_wrapper` + `__qz_spawn_indirect_1` + per-function `$spawn_wrapper`), 4 CodegenState fields (`needs_closure_wrapper`, `needs_indirect_spawn`, `spawned_func_names`, `spawned_func_arg_counts`) + `cg_register_spawned_func`, 4 call sites to `cg_emit_spawn_wrappers` (2 in codegen.qz + 2 in codegen_separate.qz), MIR_SPAWN/AWAIT references in mir_opt (3 sites) + egraph_opt (7 sites) + codegen_wasm (1 no-op branch). **Total deletion: ~650 LOC source, -6 functions (2256 → 2250 fixpoint).** Regression sweep: 41/41 effect+piezo+async specs PASS (effect_* + piezo_* + std_async_p3a + async_default_handler_p3b), 15/17 concurrency specs PASS (spawn_await, p3d, p3a, scheduler, async_combinators, recv_timeout, oneshot_channel, sync_primitives, task_group, await_nonasync, concurrency_advanced, concurrency_stress, cancel_token, multi_level_capture, async_spill_regression, fn_type_registry, concurrency base). **Surfaced issue** (filed, not blocking): `cs_mutex_concurrent_src` + `send_sync_spec "Mutex is Send"` hang when 3 concurrent `go`-tasks contend for `mutex_lock`. Reproduces on pre-P3.G-followup golden with hand-rewritten `go` source, so NOT a migration regression — it's the sync `pthread_mutex_lock` path interacting poorly with the M:N scheduler. Memo: `docs/bugs/GO_SCHED_BLOCKING_MUTEX_HANG.md`. Workaround available today: scheduler-aware `async_mutex_lock` intrinsic. Smoke tests green (brainfuck, style_demo). Fixpoint 2236→2250 (binary sizes differ; verified gen1==gen2 byte-identical). |
| P3.H — Validation + benchmark + fixpoint | 🟢 mostly done (full QSpec pending user) | `3b21ffa8` | Smoke tests ✅ (brainfuck + style_demo + expr_eval green). Fixpoint ✅ (2238 → 2236). Regression sweep ✅ (132/132 effect+sched + 65/65 async-surface + 5/5 P3C + 5/5 P3D + 4/4 P3E-lite + 5/5 P3E-runtime). ROADMAP + memory ✅. **Scheduler perf:** pre-P3.G vs post-P3.G direct comparison (sched_bench_quick, both same SHA 84849893): spawn_rate +21%, channel_throughput +20%, fanout_fanin -4% (noise), contention +2% (noise), steal_throughput ~same, wake_burst ~same, scalability_curve +12%, memory_efficiency ~same — **all metrics within 10% kill criterion; several improved**. Pre-existing regressions vs 3-week-old `c847bf8` baseline (fanout_fanin -80%, steal_throughput -83%, wake_burst -85%) are perf drift accumulated across Phase 2 + earlier Phase 3 work; filed for investigation but orthogonal to P3.G's closure. ⏳ Full QSpec (~10 min; user-run per CLAUDE.md) is the only outstanding item. |

**Phase 3 total estimate**: 7-10 quartz-days · 10-14 sessions · kill-criterion LOC ceiling 4000 net · kill-criterion scheduler perf 10%. Highest-risk and load-bearing per plan.

## Design Philosophy: Invisible by Default, Rich When Wielded

Effects are pervasive *internally* — the language is effect-typed all the way down. But they are optional *externally*. The user engages at three levels, all first-class:

| Level | What the user writes | Example |
|---|---|---|
| **Invisible** | No `can` annotations. No `try`. No `with`. Code reads as if effects don't exist. Prelude-installed default handlers do the right thing. | `def main(); puts("hello"); end` |
| **Implicit** | Effect rows inferred by the typechecker; visible in LSP hover, `quartz doc`, error messages. Code stays clean. | `def greet(name) = puts("hi, " + name)` — inferred `can StdIo`, not annotated |
| **Explicit** | Full `can` rows, hand-crafted `with` handlers, `try` markers on propagation points, effect-polymorphic combinators, sandboxing. | `def sandbox_app() can FileIo = ...` composed with `with net_denied do ... end` |

The substrate is the same at all levels. The *surface* is progressive disclosure.

### Non-negotiables

- Trivial programs have zero effect ceremony.
- `can` annotations are never *required* for correctness — inference fills them in. They document or constrain.
- The rich explicit features (`with catch`, row polymorphism, `try` markers, effect-polymorphic `map`) are first-class, reachable from any scope — not gated by mode switches, pragmas, or "advanced mode."
- Writing invisibly never locks you out of wielding — you can drop into explicit at any expression boundary.
- Effects are the *substrate*, not an "advanced feature layer." Rules about visibility are about noise, not capability.

### Philosophy alignment (cross-cutting)

This matches Quartz's existing pattern:
- Const by default, `var` to opt in
- Infer types everywhere, annotate at boundaries
- Types rich at compile time, erased at runtime
- Implicit `it` in blocks, explicit parameter names when you want them
- Open UFCS: three levels of dispatch (impl method → trait method → open UFCS)
- Async colorless — no coloring tax
- Trait auto-satisfaction (no `impl Container for Queue` needed when members already satisfy)
- Drop/RAII automatic; custom Drop for cleanup

Effects take the next step: error handling, Io, state, diagnostics, allocator, async — all substrate. You wield them when you want to.

### Filter for downstream decisions

When picking between options in the remaining design space, the tie-break is:

1. Does this work with zero effect annotations in simple programs? (If no, redesign.)
2. If the user wants to be explicit, is the rich form at hand?
3. Are both paths first-class, or is one second-class?

## What's committed (decisions made in planning so far)

### Syntax
- **`can` keyword** for effect annotations (not `!` — Quartz already uses `!` as Option unwrap)
- Effect rows with comma-separated labels: `can Io, Throws<E>`
- `with ... do ... end` for handler installation
- `effect ... end` blocks for effect declaration
- Inference by default; annotations at API boundaries only

### Type system
- Row polymorphism, Rémy-style unification
- HM-extended inference including effect row variables
- Effects are part of function types: `(args) → ε return` (Koka convention)
- Every function has an effect row (empty ⇒ pure, equivalent to `total`)

### Migration strategy
- **Stdlib-first** pilot sequence: `log` → `random`/`clock` → QSpec capture helpers
- **`Result`**: kept as a type; the convention of returning `Result` for control-flow errors migrates to `Throws`. Result stays for error-as-data use cases.
- **`opt!` (Option unwrap)**: may become sugar for `throw(None)`; decision deferred
- **Compiler dogfooding**: Phase 5, not Phase 1. Prove machinery on stdlib first.

### Soundness
- Effect system is load-bearing, not decorative
- No unchecked-exception escape hatches
- Requires operational semantics + soundness proof (feeds the existing formal spec work)

### Main and defaults (§8.5 of future EFFECTS.md)
- Prelude installs default handlers for Throws, Panic, Log, FileIo, NetIo, ProcIo, StdIo, Clock, Random, Env (full v6.0 blessed Phase-1 set)
- Trivial `def main()` programs have no effect ceremony
- Custom handlers are strictly additive overrides

### Default handler behaviors (committed 2026-04-18)

**`Panic` effect** — confirmed as a first-class effect, not a separate language builtin. Default handler prints a structured error message + stack trace to stderr, flushes all buffered output, and exits with code 101. Custom handlers unlock: structured JSON crash reports, debugger hooks (trigger `int3` on panic), test-harness capture (QSpec installs a handler so a panicking test doesn't kill the runner), cleanup-before-die (flush logs, close sockets, delete temp files), telemetry emission.

**`StdIo` effect buffering** — Option D (line-buffered for TTY, block-buffered for redirect/pipe, auto-flush on panic via the `Panic` default handler). Rationale:
- TTY → line buffering is what users expect from a REPL/CLI; each line appears as written
- Pipe/file → block buffering gives libc-level throughput when output is redirected
- Auto-flush on panic is the killer missing guarantee in libc-style programs (last writes lost on crash); the `Panic` handler + `StdIo` handler composition provides it for free
- Custom `StdIo` handlers enable: in-memory capture for tests, unbuffered mode for debugging, structured emit (JSON per write) for log aggregators

Both behaviors are example cases of "invisible default, rich when wielded" — the user who writes `puts("hi")` gets sensible behavior with zero config; the user who wants custom behavior installs a handler.

### Error-handling surface cleanup (committed 2026-04-18)

Rather than stack Throws on top of the existing `!` / `$try` / Option / Result / Panic surface, unify the whole thing into four clear tiers:

| Tier | Semantics | Catchable? | Typed? | Form |
|---|---|---|---|---|
| **Assertion** | "I proved this; crash if wrong" | No | No | `x!` (panics) |
| **Control flow (effect)** | "Empty/Err is a legit outcome for my caller" | Yes | `can Throws<E>` | `try x`, `throw(e)` |
| **Error as data** | "I want the error *value* to store/pass/serialize" | N/A (data) | Return type | `Result<T, E>` |
| **Panic** | "Unrecoverable (OOM, invariant)" | No | No | `panic(msg)` |

Per user-intent mapping (each intent gets exactly one canonical form):

| Intent | Canonical form | Notes |
|---|---|---|
| Test | `x.some?` / `x.ok?` | Unchanged |
| Narrow | `x is Some(v)` | Unchanged |
| Destructure | `match`, `if let` | Unchanged |
| Assert | `x!` (panics, uncatchable) | Unchanged |
| Propagate | `try x` (prefix keyword, **optional** per philosophy) | **Replaces `$try(x)` macro** |
| Default | `x ?? default`, `x.unwrap_or(d)` | Both kept (ergonomic chaining) |
| Chain-through | `a?.b?.c` | Unchanged |
| Transform | `x.map(f)`, `x.flat_map(f)` | Unchanged |
| Reify (effect→Result) | `reify { ... }` block | New |
| Convert (Result→effect) | `try res` | Same form as propagate |

Key decisions:
- `try` is **optional sugar**, not mandatory (per philosophy: invisible default, explicit when wielded). Implicit propagation still happens through effect-row inference; `try` is for when the user wants the propagation visible to a reader.
- `!` stays as assertion (panics, uncatchable, not effect-typed). Aligns with Rust `.unwrap()`. Three distinct intents keep three distinct forms (`!` / `try` / `match`).
- `$try(x)` macro **deleted** in favor of `try` keyword.
- Option propagation uses **unified Throws** with an `Empty` payload (not a separate `Partial` effect). Simpler substrate; catchable via standard `with catch` handlers.
- `throw` is an **expression** (Never type), consistent with `return` and `panic`.
- Error messages **grade down by engagement level**: invisible-level users see "uncaught throw, add `can Throws<X>` or install a handler"; explicit-level users see full row-diff vocabulary.

### Compilation model
- **Committed (2026-04-18)**: **evidence-passing** (Koka, Leijen 2017 style)
- Single-shot direct-call on the fast path; multi-shot exists as a slower escape hatch
- Rejected alternatives:
  - **Stack-copying / fibers** (OCaml 5) — uniform but heavy per-op cost; per-target stack-switch assembly burden
  - **Capability-passing** (Effekt) — highest type-theory load; duplicates what evidence already gives us
- Rationale: every effect on the Quartz roadmap (Throws, Io, Log, Clock, Random, State, Reader, Async) is single-shot. Ndet (multi-shot) is the only Phase 4 candidate and explicitly deferred indefinitely as nice-to-have. Evidence-passing's single-shot fast path wins the 95% case at a fraction of the impl burden of fibers.

## Open decisions (must close before Phase 1 begins)

1. ~~**Compilation model**~~ — ✅ **CLOSED 2026-04-18**: evidence-passing. See Decision log.
2. ~~**Scoped / duplicate labels**~~ — ✅ **CLOSED 2026-04-18**: allow duplicates with lexical shadowing (Model B, Koka-style). Inner handlers shadow outer; `throw` binds to innermost matching handler; re-throw propagates outward. Matches Koka, Effekt, OCaml 5, Eff. See Decision log.
3. ~~**Initial effect set**~~ — ✅ **CLOSED 2026-04-18**: 14 blessed atomic effects + 1 row alias. Phase 1 pilot: Log first, Parse second. See Decision log for full set.
4. ~~**`opt!` sugar**~~ — ✅ **CLOSED 2026-04-18**: `!` stays as assertion / panic path, NOT effect-typed. See Error-handling surface cleanup below and Decision log.
5. ~~**Effect row subtyping**~~ — ✅ **CLOSED 2026-04-18** (see #8 below): flat row equality + tail polymorphism. Subtyping rejected.
6. ~~**Error message quality bar**~~ — ✅ **CLOSED 2026-04-18**: six operational commitments + engagement-level detection heuristic. See Decision log and Phase 1 § "Error messages."
7. ~~**`Io` granularity**~~ — ✅ **CLOSED 2026-04-18**: hybrid. Atomic labels `FileIo`, `NetIo`, `ProcIo`, `StdIo`, `Clock`, `Random`; `Io` is a row alias for their union. Stdlib signatures default to atomic (information-dense); `Io` alias available as escape hatch. See Decision log.
8. ~~**Effect row subtyping (Decision #5)**~~ — ✅ **CLOSED 2026-04-18** as fallout of hybrid: flat row equality + tail polymorphism (Koka-style). Row subtyping rejected (HM inference interaction, error-message complexity, rejected by Koka for the same reasons). Hybrid model works cleanly with flat rows via tail-polymorphic row variables `can Io | ε`.

## Phase 0 — Research completion

**Goal**: understand the design space deeply enough to make Phase 1 decisions irrevocable.

**Entry criteria** (met):
- Notation primer complete
- Abstract + §1 of Leijen 2014 read and unpacked

**Deliverables**:
- Read Leijen 2014 §2–6 (rest of the paper) — *deferred, largely subsumed by 2017 paper*
- ✅ Read Leijen 2017 "Type Directed Compilation of Row-Typed Algebraic Effects" (2026-04-18 — validates type system + scoped labels + inference rules)
- ✅ Read Xie & Leijen 2020 "Effect Handlers in Haskell, Evidently" (2026-04-18 — validates evidence-passing compilation; surfaced three-kind operation taxonomy as critical design insight)
- Skim Rémy row polymorphism (for unification details) — *deferred, papers cover enough*
- Skim Effekt (Brachthäuser) for capability-passing contrast — *deferred, capability-passing rejected*
- Skim OCaml 5 effects RFC for the alternative compilation model — *deferred, fibers rejected*
- ✅ Populate `docs/research/EFFECT_SYSTEMS_NOTES.md` with per-paper notes (Leijen 2017 + Xie-Leijen 2020 entries)
- ✅ Close each open decision above with a position in the decision log (10/10 decisions closed)
- ✅ **NEW**: LLVM-specific compilation memo — `docs/research/EFFECTS_LLVM_COMPILATION_MEMO.md`

**Exit criteria**:
- ✅ Compilation model chosen, with rationale (evidence-passing, Xie-Leijen 2020; rationale in both papers + LLVM memo)
- ✅ Initial effect set curated (14 atomic effects + `Io` alias; Ndet + Yield deferred)
- ✅ Syntax locked (`can`, `effect...end`, `with...do...end`, `try`, `reify {}`, `throw`, `resume`)
- ✅ `docs/EFFECTS.md` stubbed with full phase structure

**Phase 0 complete 2026-04-18.** All exit criteria met. Phase 1 can begin.

**Estimate**: 3–5 quartz-days · 4–6 sessions

## Phase 1 — Throws pilot (end-to-end)

**Goal**: working `Throws` effect, one stdlib module migrated, default main handler, real error messages. Proves the full machinery on the simplest useful effect.

**Entry**: Phase 0 exit met.

### Parser (`self-hosted/frontend/parser.qz`)
- `can` keyword in function signatures
- `effect ... end` declaration block
- `with ... do ... end` handler block
- Effect rows in generic parameter lists

### Type system (`self-hosted/middle/typecheck*.qz`)
- `Row` representation: labels + optional tail variable
- Row registry in `TcRegistry`
- Row unification (Rémy-style, no duplicate labels yet)
- Row substitution, occurs check, pretty-print
- Effect row on function types (extend structured function type representation)
- Call-site effect propagation: inherit callee's row into caller's
- Effect subtraction at handler boundaries
- Effect-op call: adds op's label to caller's row
- Effect polymorphism in generalization/instantiation
- Soundness story for let-polymorphism + effects (value restriction replacement)

### MIR (`self-hosted/backend/mir*.qz`)
- Effect-op primitive
- Handler install / uninstall primitives
- Effect row metadata on MIR function types

### Codegen (`self-hosted/backend/codegen*.qz`)
- Evidence parameter generation
- Handler dispatch at effect-op sites
- Stack-allocated handler structs

### Stdlib
- `std/log` module migrated (simplest effect) OR `std/parse` (clear Throws use case)
- Default main-handler installation via prelude injection

### Testing
- QSpec specs for Throws: throw, catch, row in signatures, inference
- Smoke programs (`brainfuck.qz`, `style_demo.qz`) continue to pass
- Fixpoint (gen1 == gen2 byte-identical) holds through the transition

### Error messages (quality bar — six commitments)

Every Phase 1 effect error message must:

1. **Point at the offending source location** — file:line:col, rustc-style caret underlining, with the effect-producing expression clearly marked.
2. **Name the effect in plain English first, row-syntax second** — "this can fail" before "adds `Throws<ParseError>` to the row."
3. **Suggest a concrete fix** — never just "error: row mismatch." Always include either (a) the signature change to make, or (b) the handler to wrap with. Suggested code is compilable as shown.
4. **Grade by engagement level.** See detection heuristic below.
5. **Never leak implementation vocabulary** — no "unification failure," no "ρ₁₂₇," no "row variable tail," no "substitution." Use "row," "handler," "catches," "throws," "effect."
6. **Runtime uncaught-throw** reaches `main` formatted with a stack trace and a remediation hint — not a bare `panic: ...`.

### Engagement-level detection (committed 2026-04-18)

User is classified per-error-site by the typechecker using this heuristic (first match wins):

| Trigger | Level | Message form |
|---|---|---|
| User code uses row variables (`can X \| ε`), explicit handler composition, or effect-polymorphic combinators in the enclosing scope | **Expert** | Terse row-diff. Zero teaching. No sidebars. `expected row {FileIo, Throws<E>}, found {FileIo}`. |
| Enclosing function has `can ...` annotation OR an enclosing `with ... do ... end` block | **Explicit** | Full row-diff + concrete fix shown as code. Skip the conceptual teaching paragraph. |
| No `can` annotations anywhere in enclosing function, no `with` in scope | **Invisible / learning** | Plain-English description first ("this can fail"), then the concrete fix, then *why* (one sentence on what an effect row is). Show both the signature-widening path AND the handler-wrapping path. |

Filter principle (user quote, 2026-04-18): "If we detect that they're big enough to be on the ride, we can allow them in on some of the sausage making. Otherwise, we insulate."

Insulation means: the user who has never written `can` in their life never sees the words "row," "label," or "unification" in an error message. They see "this can fail — handle it here or declare it on your function signature." Period.

### Error-case coverage (Phase 1 must ship)

- **Uncaught throw** — call-site view at Invisible level (full teaching) and Explicit level (row-diff).
- **Row mismatch at call site** — show caller row, callee row, specific missing label(s), concrete fix.
- **Handler catches wrong label** — point at both the handler declaration and the throw site, show combined-handler fix.
- **Inference ambiguity** — when a function's row can't be determined, name the ambiguous binding in plain English, suggest an annotation.
- **Effect in pure-context** — if a `Fn(Int): Int` (no row) binding receives a function that has effects, explain the row mismatch at binding type and at the lambda, not just at the call.

### Phase 1 kill criterion

If any of these messages cannot be produced without a major type-system rewrite, Phase 1 is at risk. The messages ARE the product — not decoration.

**Exit criteria**:
- All Phase 1 QSpec specs green
- Fixpoint verified
- Smoke programs pass
- Error-message quality bar met (no row-unification jargon leaks)
- Default main handler works end-to-end

**Estimate**: 5–7 quartz-days · 7–10 sessions

### Phase 1 risks
- Row unification edge cases harder than expected
- Evidence-passing perf worse than direct-call baseline
- Interaction with existing generic / HM inference surfaces latent bugs
- Error messages require major type-system introspection to make teaching-grade

### Phase 1 kill criteria
- > 2x estimated effort with no end in sight
- Evidence-passing > 10% slower than direct-call baseline
- Error messages can't be made teaching-grade without major type-system rework

## Phase 2 — State and Reader ✅ SHIPPED 2026-04-22

**Goal**: multi-effect composition works. Inference stress-tested with multiple labels per row. — **Met.**

**Entry**: Phase 1 exit met. — **Met.**

**Deliverables** — all shipped:
- `State<S>` effect: `get` / `set` operations — `std/state.qz` (P2.a, `dc8a713b`).
- `Reader<R>` effect: `ask` / `local` operations — `std/reader.qz` (P2.b, `83ace16b`).
- Rémy merging across multi-effect rows — validated via P2.c multi-compose specs.
- Pilot CLI subsystem — `examples/cli_effects.qz` + `effect_cli_pilot_p2d_spec.qz` (P2.d, `717e5dff`).
- Handler composition: `with state(0), reader(config) do ... end` — parser sugar shipped P2.c (`500cc78a`).

**Exit** — all met:
- Multi-label rows unify cleanly: 6/6 multi-compose specs green.
- Inference predictable: State + Reader + Log + Throws 4-effect rows typecheck and dispatch correctly.
- QSpec coverage: 25 new tests across 4 specs (effect_state_p2a 8, effect_reader_p2b 7, effect_multi_compose_p2c 6, effect_cli_pilot_p2d 4). All 14 pre-existing effect specs still green.
- Pilot: cli_effects handles default / --verbose / --silent / --help / sum correctly.

**Estimate**: 3-5 quartz-days. **Actual**: 1 quartz-day (one session, 4 commits).

### Phase 2 design decision

**Option B (evidence-slot per install, Xie-Leijen 2020 style).** Each `with E(v)` install pushes an entry to `@__qz_effect_stack_state_slots[K]` parallel to the existing `effect_stack_names/handlers/bufs/filters`. Stateful effects (`State<S>`, `Reader<R>`) route `get/set/ask` to `__qz_default_state_handler` / `__qz_default_reader_handler`, which read/write `slots[current_install_idx]`. Nested `with State(a) do with State(b)` gets two slots and correct shadow semantics without compile-time magic.

Rationale vs. rejected alternatives (full memo in `docs/handoff/piezo-phase-2-kickoff.md` §3):
- Option A (module-level sink like Phase 5.1 Diagnostics): would collapse on nesting, violating the exit criterion directly.
- Option C (closure handlers): touches capture analysis and widens the handler ABI — out of scope for a 3-5 day phase; filed as a Phase 4+ conversation.

### Phase 2 followups filed

- **Struct-init `with State { initial: 42, get: my_get } do ... end`** — custom handler + init value combined. P2.a ships the call form `with State(v)` with default handlers and the struct form `with State { get: my_get }` with custom handlers but no init. Combined form TBD.
- **Save/restore `@__qz_effect_current_install_idx` across nested performs inside a single handler frame** — not exercised by current specs. Filed as a safety hardening item.
- **Pre-existing implicit-return-type inference bug** when `can <Row>` present on a function signature without explicit `: Int`. Filed in `docs/bugs/IMPLICIT_RETURN_TYPE_WITH_CAN_ROW.md`. Reproduces on pre-P2 golden. Not blocking (explicit return type fixes it); not a Piezo deliverable.
- **Quake argv port** — scoped out of P2.d (quake.qz is 24 KB and its parser is intertwined with subcommand dispatch). `examples/cli_effects.qz` is a standalone demo; a quake port is a Phase 2 polish followup or Phase 5.x dogfood target.

### Phase 2 milestone tracker

| Milestone | Status | Commit | Deliverable |
|---|---|---|---|
| P2.a — State<S> schema + evidence-slot infra | ✅ SHIPPED 2026-04-22 | `dc8a713b` | `std/state.qz`; `@__qz_effect_stack_state_slots` TLS; `__qz_default_state_handler` + `__qz_effect_state_get/set` helpers; `mir_emit_handle_install` gains `init_state_reg` param; G.2 / G-extended fast paths set `@__qz_effect_current_install_idx` before direct handler call; effect-op detection skips UFCS calls to avoid `.get`/`.set` collision with State's ops. 8/8 spec tests. Fixpoint 2302 → 2306 (+4 helpers). |
| P2.b — Reader<R> + local + lambda handler-stack fix | ✅ SHIPPED 2026-04-22 | `83ace16b` | `std/reader.qz` (`effect Reader { ask }` + `def local(f, body) can Reader`); `__qz_default_reader_handler`; `mir_lower_lambda` now saves/clears/restores the lexical handler-stack (fixes pre-P2.a latent bug where lambda bodies emitted `%wb.pretop.<install_dest>` SSA refs to the enclosing function's scope). 7/7 spec tests. Fixpoint 2306 → 2307 (+1 helper). Pre-existing can-row return-type inference bug filed at `docs/bugs/IMPLICIT_RETURN_TYPE_WITH_CAN_ROW.md`. |
| P2.c — multi-effect composition + comma-list `with` sugar | ✅ SHIPPED 2026-04-22 | `500cc78a` | Parser: `with H1, H2, H3 do body end` desugars at parse time to nested with-blocks (first handler = outermost install). 6/6 spec tests incl. 4-effect row Throws+Log+Reader+State with longjmp unwind across intermediate State install. Fixpoint unchanged (2307). |
| P2.d — CLI pilot | ✅ SHIPPED 2026-04-22 | `717e5dff` | `examples/cli_effects.qz` (~165 LOC) demonstrating State<Int> cursor + Reader<Int> verbosity + gated Log-via-handler. 4/4 spec tests. Quake port scoped out as followup. Fixpoint unchanged (2307). |

Total Phase 2 delta: 4 commits, 25 new tests, fixpoint +5 helpers (2302 → 2307).

## Phase 3 — Async-as-effect migration

**Goal**: migrate colorless async from its current special-case MIR lowering to the general effect machinery. Proves effects are Quartz's unifying mechanism.

**Entry**: Phases 1–2 exit met.

**Deliverables**:
- `Async` effect: `await`, `suspend`, `spawn` operations
- Handler = scheduler
- Migrate existing `$poll` state-machine lowering to effect-lowering
- All existing async code continues to work (no user-visible regression)
- Effect-polymorphic async combinators (`go`, `await`)

**Exit**:
- All existing async QSpec passes unchanged
- Special-case async MIR lowering deleted (Prime Directive 7, no compat shim)
- Effect-polymorphic map / filter / etc. work with async functions
- Scheduler intrinsics integrate cleanly with handler discharge

**Estimate**: 7–10 quartz-days · 1.5–2 calendar weeks. Highest risk. Load-bearing.

### Phase 3 kill criteria
- Migration requires > 2x the LOC of current async impl → redesign
- Scheduler performance regresses > 10% → redesign
- Effect-polymorphic call sites can't monomorphize cleanly → reconsider compilation model

## Phase 4 — Non-determinism and generators

**Status**: ✅ **PATH B (generators) FULLY CLOSED** 2026-04-25 in 22 commits across 3 calendar days. Phase 4b (multi-shot) deferred per [`docs/research/PHASE_4B_MULTISHOT_DECISION.md`](PHASE_4B_MULTISHOT_DECISION.md). Planning doc: [`docs/research/PHASE_4_NONDET_GENERATORS_RESEARCH.md`](PHASE_4_NONDET_GENERATORS_RESEARCH.md). Retrospective: [`docs/design/PHASE_4_GENERATORS_RETRO.md`](../design/PHASE_4_GENERATORS_RETRO.md). Archived kickoff: [`docs/handoff/done/piezo-phase-4-kickoff.md`](../handoff/done/piezo-phase-4-kickoff.md).

**Goal**: multi-shot handlers + generators. The handler-invocation patterns that evidence-passing alone doesn't cover.

**Entry**: Phases 1-3 + 5 exit met. Phase 5 stabilized the effect machinery; Phase 4 now has a solid substrate to build on.

**Deliverables** (staged — see research doc for detail):
- **Phase 4a — `Yield<T>` + generators** (~3-5 quartz-days). Heap-allocated generator frame; reuses $poll state-machine with consumer-side resume. One-shot semantics, Python/ES6/Rust-generator-equivalent. Covers the practical 80%.
- **Phase 4b — Multi-shot via opt-in frame clone** (~5-7 quartz-days, research-heavy). `effect Ndet { choose @multishot }`; typechecker rejects Drop types at perform sites in multi-shot bodies; runtime shallow-clones the state-machine struct per resumption. Ndet/backtracking/probabilistic programming unlocked.
- **Phase 4c — Effect-polymorphic generators** (~1-2 quartz-days). `def stream_over<ε>(...) can Yield<T>, ε` composes with any outer effect; primarily typecheck work, $poll already handles multiple effects.

**Exit**:
- 4a: Yield<T> generators work on non-trivial programs (at least one stdlib combinator library). Composes with outer effects.
- 4b: Multi-shot handlers work on `Ndet.choose` backtracking example. Typechecker rejects Drop types in multi-shot scope.
- 4c: Effect-polymorphic generators round-trip through outer handlers.

**Kill criteria**:
- 4a: Generator call overhead > 3× equivalent iterator loop → redesign.
- 4b: Frame-clone ABI requires GC integration → deferred indefinitely.
- 4b: Typechecker restriction is so tight that Ndet bodies can't use `String`, `Vec<Int>`, or common types → redesign.

**Estimate**: 4a + 4c ~5 quartz-days; 4b optional stretch ~7 quartz-days. Total floor ~5, ceiling ~12 quartz-days.

## Phase 5 — Compiler dogfooding ✅ FULLY CLOSED 2026-04-23

**Status**: all five dogfood effects at infrastructure level + retrospective shipped.

**Entry**: Phases 1–3 exit met (4 sequenced after). Effect machinery stable and battle-tested.

**Deliverables** (each a sub-phase, all ✅ SHIPPED):
1. Diagnostics as effect (`Diag`) — P5.1 (91% migrated, full closure deferred as non-urgent residue)
2. Type context / scope state as `State<TcCtx>` — P5.2 + Option Z
3. LLVM IR emission as `Emit` effect — P5.3 + Option Z
4. Module resolution with `FileIo` effect — P5.4 full cycle: flat-op pilot + prelude install + wrap deletion (after effect-stack cap fix `a6f174ae`)
5. Symbol / intern tables as `Intern` effect — P5.5 (3-pass bootstrap including retrofit)
6. Retrospective + perf + arch doc + Tier 4 filings — P5.6 (`cda7a3cc`)

**Exit criteria met**:
- ✅ Fixpoint holds through each migration (verified at every commit).
- ✅ Error-reporting pipeline simpler / more readable.
- ✅ Compilation performance not regressed (measured: wrap-delete overhead < 0.1 % of wall self-compile time).
- ❌ Compiler LOC reduced measurably (target: 10–15%) — **NOT MET**. Audited 2026-04-25: net **+3.65 %** across 20 migrated/infra files. Per-effect breakdown + structural rationale in [`EFFECT_MIGRATION_PLAYBOOK.md` §7](../design/EFFECT_MIGRATION_PLAYBOOK.md). Re-baseline before next epic; raw-LOC was the wrong metric — per-callsite ergonomics did improve. ~130 LOC recoverable via Diag Pass 2b (Tier 4 §7.1).

**Retrospective**: [`docs/design/EFFECT_MIGRATION_PLAYBOOK.md`](../design/EFFECT_MIGRATION_PLAYBOOK.md) — three-pass bootstrap, bridge-over-cascade, five-incident ledger, checklist, estimation calibration, §6 perf.

**Exit**:
- Compiler LOC reduced measurably (target: 10–15%)
- Compilation performance not regressed
- Fixpoint holds through each migration
- Error-reporting pipeline simpler / more readable

**Estimate**: 2–3 quartz-weeks · 20–30 sessions. Large, but each sub-migration is contained.

### Phase 5.2 milestone tracker

| Milestone | Status | Commit | Deliverable |
|---|---|---|---|
| P5.2.a — bridge + scope-stack slice pilot | ✅ SHIPPED 2026-04-22 | `ca4f887c` | `self-hosted/middle/typecheck_ctx.qz` — single-slot TypecheckState bridge (mirrors `typecheck_diag.qz`); `tc_ctx_set(tc)` installed in `compile()` next to `tc_diag_set(tc)`. `tc_enter_scope(tc)` migrated to body-wrap with `with State(as_int(tc)) do -> var tc_e = as_type<TypecheckState>(get()); tc_set_depth(tc_e, tc_get_depth(tc_e)+1) end` — dogfoods evidence-slot State on the compiler's own depth counter. Body-wrap keeps outer signature `tc`-keyed, no `can State` cascade up the ~30 callers. Fixpoint 2307 → 2311 (+4 helpers). Smoke green; effect specs green. |
| P5.2.b — handler-effect stack slice | ✅ SHIPPED 2026-04-22 | `ff95dbe2` | `tc_handler_effect_push/pop/contains` all routed through `State<TcCtx>` via same body-wrap. `contains` is the Bool-return shape — uses `return with State(...) do -> … bare_expr end` to respect the body-wrap last-stmt gotcha (no trailing `return X` inside the wrap; early `return true` rewritten to break-via-index). Called on every NODE_WITH typecheck — stress-tests the wrap under repeated handler installs. Fixpoint unchanged (2311, body-only). 7/7 handler_narrow_c2 + 6/6 narrow + 8/8 state_p2a + 7/7 reader_p2b + 6/6 multi_compose_p2c green with fresh cache. |
| P5.2.c — tv_current_level pair | ✅ SHIPPED 2026-04-22 | `754bb323` | `tc_tv_enter_level/tc_tv_exit_level` body-wrapped through `State<TcCtx>`. Fires on every NODE_LET typecheck — the hottest tv-mutation path after tc_error. Third demonstrator slice (paired counter, paired vec, bool return all exercised across a/b/c). Pattern cemented. Fixpoint unchanged (2311). functions_spec 49/49, let_polymorphism_spec 5/5 green. |
| P5.2.d — docs + handoff | ✅ SHIPPED 2026-04-22 | this commit | `docs/EFFECTS.md` §7.5 documents the `State<T>` struct-pointer body-wrap pattern with the body-wrap last-stmt gotcha call-out. `EFFECTS_IMPLEMENTATION_PLAN.md` §Phase 5.2 tracker populated. Phase 2 handoff archived; Phase 5.3 kickoff draft covers `Emit` effect slice. |
| P5.2.e — ambient State install at compile() | ✅ SHIPPED 2026-04-23 | `d220c25c` | Option Z Step 1 (mirror of P5.3.d.1 for Emit). `with State(as_int(tc)) do -> with Diag { … } do -> tc_program() end end` installed at compile() in quartz.qz:681. No call-graph changes. Existing body-wraps in P5.2.a-c become nested installs under this outer one — nested installs push a new slot with same tc value, so get() returns the same pointer. Semantically identical; fixpoint 2316 byte-identical. Unblocks P5.2.f (body-wrap drop + can State cascade). |
| P5.2.f — body-wrap drop + can State cascade | ⏳ pending — kickoff filed | — | Probe attempted this session: strip `tc_enter_scope` body-wrap, add `can State`. Build-time cascade scope was small (3 fns: tc_enter_scope, tc_function/tc_parse_type_impl, tc_program). **Runtime failure**: pre-registration phases in compile() (Phase 4.0 struct/fn/trait/impl registration at lines 510-660) call tc_parse_type → tc_parse_type_impl → transitively any `can State` fn, and those phases run **before** the P5.2.e install at line 682 — no State in scope ⇒ "unhandled effect op called". Probe reverted; state stable. Recommended next-session path: (1) widen the State install to cover lines 507-~700 (everything from tc_ctx_set through tc_program); (2) retry the cascade probe; (3) drop `tc` from tc_enter_scope's signature; (4) repeat for other 5 body-wrapped leaves. Full kickoff: [`piezo-phase-5-2-option-z-kickoff.md`](../handoff/piezo-phase-5-2-option-z-kickoff.md). |

Total Phase 5.2 delta: 4 commits P5.2.a-d (fixpoint 2307 → 2311, +4 helpers, three demonstrator slices) + 1 commit P5.2.e (fixpoint 2311 → 2316 unchanged at step — byte-identical; delta vs. Phase 5.2 start reflects post-5.3 state).

### Phase 5.3 milestone tracker

| Milestone | Status | Commit | Deliverable |
|---|---|---|---|
| P5.3.a — Emit effect + bridge + inttoptr pilot | ✅ SHIPPED 2026-04-22 | `31ffbea8` | `std/emit.qz` (3 ops: emit/emit_line/emit_int, Void return); `self-hosted/backend/codegen_ctx.qz` single-slot bridge + 3 default handlers forwarding to `codegen_util::cg_emit*`; `cg_emit_inttoptr` body-wrapped through Emit with `cg_ctx_set(out)` + `with Emit { … }`. Fires at ~10 callsites from `cg_intrinsic_sb.qz` during self-compilation. Fixpoint 2311 → 2317 (+6 helpers). Byte-identical IR verified via gen1==gen2. |
| P5.3.b — inttoptr_is + ptrtoint_is | ✅ SHIPPED 2026-04-22 | `28f7dab2` | Both int-variant helpers migrated through same body-wrap template. Exercises `emit_int` alongside `emit` / `emit_line`. Fixpoint 2317 unchanged (body-only). Smoke + regression specs green. |
| P5.3.c — broader codegen_util migration | ✅ SHIPPED 2026-04-23 | `781b21b6` | Extended pilot to 5 more helpers: `cg_emit_ptrtoint`, `cg_emit_vec_unpack_header`, `cg_emit_vec_unpack_data`, `cg_emit_vec_alloc`, `cg_emit_option_some_inline`, `cg_emit_option_none_inline`. `cg_emit_vec_unpack` (2-line dispatcher) pass-through. 8 of 15 codegen_util emit helpers now Emit-routed. Fixpoint 2317 unchanged (body-only). Load-bearing helpers fire during self-compilation via Vec intrinsics; byte-identical fixpoint confirms emission preserved. Remaining 7 helpers are primitives (backs the handlers, must stay direct to avoid recursion) or top-level orchestrators (warrant ambient-Emit treatment, filed). |
| P5.3.d.1 — Option Z Step 1 — ambient install | ✅ SHIPPED 2026-04-23 | `ab732ac4` | `with Emit { … } do -> …` installed at `cg_codegen` wrapping the function-emission loop (lines 1005-1008 pre-change). Single pass-boundary install; all codegen transitively called from the loop can declare `can Emit` and call bare `emit(...)` — handlers forward through `codegen_ctx::cg_ctx_get()` (set to `out` immediately before the install). No behavior change: existing direct-API helpers unchanged; P5.3.a-c body-wrapped helpers create nested installs (semantically fine). Fixpoint 2317 unchanged. Install scope narrower than whole-body — other cg_codegen emission sites (runtime decls, main wrapper, etc.) continue on direct API. Unblocks **P5.3.d.2 — Step 2 cascade** (add `can Emit` to cg_emit_instr + sub-dispatchers + migrated leaves, drop their local body-wraps). Filed as next session's work. |
| P5.3.d.2 — Step 2 cascade — backbone + leaf migrations | ✅ SHIPPED 2026-04-23 | `2e71c0ac`, `9eaadfe0`, `22ad0d8f`, `76ebac8a` | Four commits: PD7 prelude (delete dead `cg_emit_ptrtoint_is`), backbone `can Emit` sweep (4 backbone fns + 17 sub-dispatchers + 3 internal helpers), inttoptr leaves + cg_ctx routing fix in `_cg_emit_function_with_linkage`, then remaining 6 vec/option leaves. **All 7 body-wrapped leaves** in `codegen_util.qz` now declare `can Emit` and emit bare via the algebraic effect. `out: Int` params retained on leaves (drop deferred). Wider entry-point installs (kickoff plan) replaced with **per-call minimal wraps** because of an unrelated lambda-method-resolution bug — `with E { … } do -> ... local.method() … end` fails to resolve method calls and emits IR loading the method name as a closure variable. Bug filed in followup §7. Fixpoint 2316 byte-identical at every commit; smoke (style_demo, brainfuck) green. Followup: [`piezo-phase-5-3-step-2-cascade-handoff.md`](../handoff/piezo-phase-5-3-step-2-cascade-handoff.md). |
| P5.3.d.3 — drop dead `out: Int` from migrated leaves | ✅ SHIPPED 2026-04-23 | `369f765f`, `77c2e847`, `db43aaf6`, `2547d4b5`, `d06fbf75`, `6627f466`, `4a6446e2` | Seven one-leaf-per-commit migrations retire the `out: Int` parameter that survived P5.3.d.2 as dead weight on every migrated leaf. Bodies have been effect-routed since Step 2 — `out` was declared but never read. Signatures shrink: `cg_emit_option_some_inline(prefix, val_reg)`, `cg_emit_option_none_inline(prefix)`, `cg_emit_vec_unpack_header(p, d, src)`, `cg_emit_vec_unpack_data(p, d)`, `cg_emit_vec_unpack(p, d, src)`, `cg_emit_vec_alloc(p, d, cap_val, len_val)`, `cg_emit_inttoptr(dest, src, lltype)`, `cg_emit_ptrtoint(dest, src, lltype)`, `cg_emit_inttoptr_is(dest_id, dest_suffix, src_id, lltype)`. Caller edits: 263 across 10 intrinsic files. Ordered smallest-first (6 → 6 → 32 → 12 → 35 → 58 → 114) so any regression would surface on a small commit. Fixpoint 2316 byte-identical at every guard; smoke green throughout. **Closes P5.3.d** at the leaf layer — the `Emit` effect's promise that "handle routing lives in one place" is now fully realized at leaf signatures. |
| P5.3.d.3 — bug hygiene + dead-file cleanup | ✅ SHIPPED 2026-04-23 | `66b63a8e`, `d3e0c215`, `b2b1672d` | Three Tier-2 items from the P5.3.d.2 handoff §7: (1) [`docs/bugs/LAMBDA_METHOD_RESOLUTION_IN_WITH.md`](../bugs/LAMBDA_METHOD_RESOLUTION_IN_WITH.md) memoizes the wide-install lambda-method-resolution bug discovered during Step 2 (six minimal repros failed to trigger — filed the trigger shape, workaround, and investigation path so the next contributor has a runway); (2) fixed `has_original_init` shadow in `cg_codegen_separate` (line 556 `var` created a local that went out of scope — outer stayed 0, so `@__qz_original_module_init()` call was never emitted in `--separate` builds of modules with complex computed globals); (3) deleted dead `codegen_main.qz` per PD7 (split from `codegen.be` for C bootstrap, retired Feb 2026; zero callers tree-wide). separate_compilation_spec: 6/6 green. Fixpoint 2316. |
| P5.3.d.3+ — Tier A wide-install reconciliation | ✅ SHIPPED 2026-04-23 | `f400f1c2`, `de6f8308` | Investigation under P5.3.d.3's Tier A. Reduced from production shape: tried the exact widenings described in the P5.3.d.2 handoff §3 at two callsites (`cg_codegen_incremental`'s changed-module branch + `cg_codegen_separate`'s `__qz_module_init` branch). **Both built clean.** Fixpoint byte-identical, separate_compilation_spec 6/6, smoke green. The pattern that failed at P5.3.d.2 shipping no longer triggers — one of the intervening commits (mechanical out-param drops, shadow fix, codegen_main deletion, or fixpoint byte-identical change earlier) silently resolved it; mechanism unknown. Shipped the widenings as real improvements in `f400f1c2` — `cg_codegen_separate` now uses wide ambient installs matching `cg_codegen`/`cg_codegen_debug`. Bug memo updated in `de6f8308` to mark unreproducible, old diagnosis preserved for the "if it resurfaces" case. **Emit cascade Option Z is FULLY CLOSED across all four cg_codegen variants.** |
| P5.3.d — docs + handoff | ✅ SHIPPED 2026-04-22 | this session | `docs/handoff/piezo-phase-5-3-handoff.md` documents pilot; kickoff archived to `docs/handoff/done/`. EFFECTS.md §7.5 from Phase 5.2 already covers the `State<T>` body-wrap shape — Emit migration is the natural analog. |

### Phase 5.5 milestone tracker

| Milestone | Status | Commit | Deliverable |
|---|---|---|---|
| P5.5.a (infra) — `effect Intern` + default handler + QSpec | ✅ SHIPPED 2026-04-23 | `45781879` | `std/intern.qz` declares `effect Intern { intern(s): Int, resolve(id): String }` (both kind=1) + `intern_default_handler(op_name, argc, argv)` Quartz-level default forwarding to `string_intern::intern_global()` for `intern` and `string_intern::intern_resolve_int(intern_global(), id)` for `resolve`. `spec/qspec/intern_effect_p55a_spec.qz` with 4 acceptance tests: default handler dedup + round-trip, custom handler substitution (counting-handler demo), `can Intern` threading through intermediate callers, resolve round-trip under default. Kickoff doc shipped at `docs/handoff/piezo-phase-5-5-kickoff.md`. No self-hosted source changes in this commit — the effect stands alone until P5.5.a migration lands. |
| P5.5.a (migration) — typecheck_registry pilot (17 sites) | ✅ SHIPPED 2026-04-23 | `30e90980` | `self-hosted/middle/typecheck_registry.qz`: two module-private wrappers `_tc_intern(name)` and `_tc_resolve(id)` body-wrap with `with Intern { intern: intern::intern_default_handler, resolve: intern::intern_default_handler } do -> intern(name) end`. 17 registry callsites migrated: 4 PUSH sites (`g_func_name_ids`/`g_struct_name_ids`/`g_enum_name_ids`/`g_trait_name_ids`), 11 LOOKUP sites across 6 `tc_lookup_*` / overload / arity functions, 2 impl-registry intern sites in `tc_register_impl`, 1 `intern_resolve` in missing-trait-names diagnostic. Registry IDs now come from `intern_global()` instead of per-tc `tc.interner` — safe because `g_*_name_ids` vectors are module-private (grep-verified no external readers) and push/lookup both moved together. Embedded `tc_run_subsume_tests` at lines 4490/4660/4755 + row-label interning in `typecheck_expr_handlers.qz:1505,1557` + other tc.interner uses stay on `tc.interner` (different data structures, different consistency contract). Fixpoint 2322 → 2325 (+3 helpers). Bug caught mid-migration: first `replace_all intern(name) → _tc_intern(name)` caught the effect-op call INSIDE `_tc_intern`'s own body, creating infinite recursion → binary SIGSEGV on any compile. 1-line revert fixed it; memo "replace_all on helper renames must exclude the helper's body" recorded. |
| P5.5.b — build_cache remap loop migration (1 site demonstrator) | ✅ SHIPPED 2026-04-23 | `b7207798` | `self-hosted/shared/build_cache.qz`: the cache-load AST remap loop (`for ri in 0..saved_strings.size; remap.push(intern_id(intern_global(), ...))`) now routes through an inline `with Intern { ... } do -> intern(saved_strings[ri]) end` wrap. Different wrap style than P5.5.a — inline-once-per-loop instead of per-call helper — because the install cost amortizes across the typically-large `saved_strings` vec. Proves the migration pattern extends to a second module with a different loop shape. Fixpoint 2325 (body-only change, no new fn). Cache idempotence verified: second compile of style_demo byte-identical to first. |
| P5.5.c — Option X: blessed-relaxation + drop body-wraps | ✅ SHIPPED 2026-04-23 | `0e3d1d4c` (Pass 1) + `2d7eadbb` (Pass 2a) + `a6f174ae` (effect-stack 32→256 cap fix) + `2f026294` (Pass 2b) | Three-pass bootstrap: (1) add `Intern` to D.4 blessed-relaxation in `typecheck_expr_handlers.qz` so bare `intern(...)` typechecks without `can Intern` cascade; (2) install `@__qz_default_intern_handler` in main prelude when `uses_intern == 1`; (2b) drop the 17 `_tc_intern` / 1 `_tc_resolve` body-wraps in `typecheck_registry.qz` + the inline wrap in `build_cache.qz`. Cap-fix at `a6f174ae` (32→256) was the load-bearing prerequisite — body-wrap deletion uncovered FileIo wrap-deletion symptoms tracing back to install asymmetry. Outer callers wrapping `compile()` with `with Intern { intern: my_mock }` now override the registry's interning end-to-end (no inner install competes on top-down scan). Deeper migration of ~80 additional sites across AstStorage-local, tc.interner-keyed, and lsp/repl bindings remains a Tier 4 enhancement (handoff §3 categorises). |
| P5.5.d — handoff + plan tracker update | ✅ SHIPPED 2026-04-23 | this session | `docs/handoff/piezo-phase-5-5-handoff.md` documents shipped commits + customization limitation + remaining migration sites + recommended next session (Path A FileIo bug chase → Phase 5.5 Option X retrofit → Phase 5.6). Kickoff archived to `docs/handoff/done/`. `EFFECTS_IMPLEMENTATION_PLAN.md` Phase 5 item 5 marked SHIPPED; Phase 5.5 tracker section (this one) populated. |

### Phase 5.2 followups (not blocking 5.3)

- **Ambient `can State` signature migration (Design Z)**. Current slices all use the body-wrap pattern — the outer fn keeps `tc: TypecheckState` in its signature, and the State handler is installed fresh on every call. The "true ambient" design installs `with State(as_int(tc))` at the top of `compile()` around `tc_program`, drops `tc` from every function signature in the call chain, and propagates `can State` up to the install. Estimate: 2-4 quartz-days for the full typecheck surface; dozens of signature edits. Not blocking 5.3, but the payoff is real — removes one parameter from ~half the compiler's typecheck functions.
- **More TcCtx subsystem slices**. `tv_origin_descs` push/pop, `last_unify_*` cache, interner caches, `scope.binding_*` parallel vecs, `safety.borrow_*`, `loop_labels`. Same body-wrap template, mechanical follow-on. Punctuates the story but doesn't unlock anything new.
- **Pattern inversion: `State<T>` as abstraction over TLS / thread-local**. P5.2.a-c treat State as "ambient payload broadcast." A more radical use would be to migrate the ~dozen `@__qz_*` TLS globals (current_install_idx, effect_park_rv, effect_current_cont_frame, etc.) to `State<T>` slots. That's a compiler-runtime refactor, not a typecheck refactor — defer past Phase 5.

## Cross-cutting: teaching + docs

**Ships with Phase 1 (non-negotiable)**:
- `docs/EFFECTS.md` tutorial chapter
- 10–15 curated examples in `examples/effects/`
- CLAUDE.md section on effect idioms (teaching material for future contributors, human or LLM)
- Effect-system error-message style guide

**Accumulates through Phases 2–4**:
- More examples per new effect
- Pattern cookbook (common handler patterns, common anti-patterns)
- Migration guide for existing code

**Ships with Phase 5**:
- Retrospective on the dogfooding migration
- Performance benchmarks, before/after
- Compiler architecture doc updated

## Project-level kill criteria

Conditions that trigger abandonment or major redesign of the effects direction:
- Phase 3 async migration requires > 2x current async impl
- Effect polymorphism inference fails without pervasive annotations
- Evidence-passing > 10% slower than direct-call baseline
- Linear/move-semantics interaction forces unacceptable handler restrictions
- Error messages can't be made teaching-grade in Phase 1

## Estimation summary (quartz-time)

| Phase | Traditional | Quartz-time | Sessions |
|---|---|---|---|
| 0 — Research | 1–2 weeks | 3–5 days | 4–6 |
| 1 — Throws pilot | 3–4 weeks | 5–7 days | 7–10 |
| 2 — State/Reader | 2 weeks | 3–5 days | 4–6 |
| 3 — Async migration | 4–6 weeks | 7–10 days | 10–14 |
| 4 — Multi-shot | 3 weeks | 5–7 days | 6–10 |
| 5 — Compiler dogfooding | 8–12 weeks | 2–3 weeks | 20–30 |
| **Total** | **21–29 weeks** | **5–8 weeks** | **~50–75 sessions** |

Phases 1 and 3 are load-bearing. If both succeed, effects become Quartz's organizing principle. If Phase 1 succeeds but Phase 3 doesn't migrate cleanly, keep Phases 1–2 as a new feature and defer the unification story.

## Decision log

Append-only. New entries at the bottom, never rewrite history.

- **2026-04-17** — `can` chosen over `!` (collision with Option unwrap). Strongman revisited after pushback; see earlier planning session.
- **2026-04-17** — Effect inference is a Phase 1 hard requirement, not a later addition. Based on Koka's empirical track record.
- **2026-04-17** — Stdlib-first migration order committed. Compiler dogfooding explicitly deferred to Phase 5.
- **2026-04-17** — Systems-language positioning: Quartz qualifies (LLVM IR, self-hosting, manual memory, cross-platform, no GC). Koka does not (C backend, Perceus RC). Phrase "first systems language with first-class algebraic effects" cleared for §1 of EFFECTS.md.
- **2026-04-17** — §8.5 "Main and the Default Handler Stack" added as a distinctive Quartz design element. Prelude-installed default handlers mean trivial `def main()` has zero effect ceremony.
- **2026-04-17** — Evidence-passing is the leading compilation model. Explicit commit deferred until Leijen 2017 is read.
- **2026-04-18** — Compilation model **committed**: evidence-passing (Xie & Leijen **2020** "Effect Handlers in Haskell, Evidently" style — NOT Leijen 2017, which is type-directed selective CPS). Committed on pragmatic grounds: every effect on the Quartz roadmap is single-shot. Ndet was the sole multi-shot case; deferred indefinitely as nice-to-have. Stack-copying/fibers rejected (uniform but heavy per-op, per-target assembly burden); capability-passing rejected (highest type-theory load, duplicates evidence's value proposition). Leijen 2017 read (2026-04-18, same session): validates type system, row polymorphism, scoped labels with duplicates (Model B), OPEN/CLOSE inference rules, and selective translation as the >80% cost reduction that makes the approach practical. But 2017 describes selective CPS, not evidence-passing — commitment validation continues in Xie-Leijen 2020 (next reading target). One design hole surfaced regardless of model: polymorphic-effect functions (`map`, `filter`, `fold`) need special compilation (worker-wrapper + runtime dispatch) — ~20% core-library code bloat per Koka's experience.
- **2026-04-18** — `Io` granularity **committed**: hybrid. Atomic labels `FileIo`, `NetIo`, `ProcIo`, `StdIo`, `Clock`, `Random` (exact set TBD with Decision #3). `Io` is a row alias for their union. Stdlib signatures default to atomic labels (information-dense for readers and for sandbox handlers); `Io` alias available as escape hatch for code that doesn't care. Implies positioning commitment: sandbox-friendly runtime is on Quartz's future roadmap (capability-style effect handlers become the enforcement mechanism — `with net_denied do -> run_untrusted() end`).
- **2026-04-18** — Effect row subtyping **rejected**: flat row equality + tail-polymorphic row variables (Koka-style). Subtyping's HM-inference interaction and error-message complexity are well-known pain points; Koka tried it and walked back. Hybrid `Io` model works cleanly with flat rows via `can Io | ε` tail polymorphism for call-site openness.
- **2026-04-18** — **Design Philosophy committed**: "Invisible by Default, Rich When Wielded." Three engagement levels (invisible / implicit / explicit), all first-class. Non-negotiable: trivial programs have zero effect ceremony; `can` never required for correctness; rich features reachable from any scope, not gated. Governs all downstream decisions.
- **2026-04-18** — **`Panic` default handler** committed: print structured message + trace to stderr, flush buffered output, exit 101. Custom handlers unlock crash reports, debugger hooks, test-harness capture, cleanup-before-die. Panic remains uncatchable as an effect semantically (no catching in user `with catch`) but the default-handler pattern gives the rich-wielded escape hatch.
- **2026-04-18** — **`StdIo` buffering discipline** committed: Option D (line-buffered for TTY, block-buffered for redirect/pipe, auto-flush on panic via composed Panic handler). Resolves the libc "pipe-to-grep shows nothing" surprise and the "last writes lost on crash" footgun in one pattern.
- **2026-04-18** — **Phase 2 pilot committed**: world-class CLI / config system (Ruby-Gemfile-quality, not Python-ecosystem style). Replaces ad-hoc argv handling; dogfoods `Reader<Config>` + `State<ArgState>`. Quake tooling gets a DX win as a byproduct.
- **2026-04-18** — **Scoped labels committed**: Model B — labels can appear multiple times in a row; handlers shadow lexically; `throw` binds to innermost matching handler; re-throw propagates to next outer. Matches Koka, Effekt, OCaml 5, Eff. Typechecker takes on label-scope discipline as the cost; expressiveness gain (nested catch, handler pipelining, re-throw) is worth it. Model A (flat, no duplicates) rejected: simpler typechecker but forces users to rename errors to layer catches, which is friction for no gain.
- **2026-04-18** — **Initial effect set committed** (v6.0 blessed stdlib effects): 14 atomic effects + 1 row alias.
  - **Phase 1 (Throws pilot infrastructure)**: `Throws<E>`, `Panic`, `Log`, `FileIo`, `NetIo`, `ProcIo`, `StdIo`, `Clock`, `Random`, `Env`
  - **Phase 2**: `State<S>`, `Reader<R>`, `Alloc`
  - **Phase 3 (migration)**: `Async`
  - **Row alias**: `Io = {FileIo, NetIo, ProcIo, StdIo, Clock, Random, Env}`
  - **Deferred**: `Ndet` (multi-shot, indefinitely nice-to-have), `Yield<T>` (part of deferred Phase 4 — generators stay compile-time state-machine lowering until Phase 4 ever ships)
  - **Explicitly subsumed / not blessed**: `Debug`/`Trace` (subsumed under `Log` with severity levels), `Exit` (use `Panic` or `Throws<ExitRequested>`)
  - **`Env` rationale**: atomic effect (not subsumed under `ProcIo`). Security-audit use case — sandboxed runtimes and security software want to intercept every env var read/write. Default handler wraps `getenv`/`setenv`; custom handlers enable deny-all, log-all-reads, or deterministic fake-values-for-tests. Include in `Io` row alias for ergonomics; atomic form available when precise capability matters.
- **2026-04-18** — **Phase 1 pilot sequencing committed**: `std/log` module migrated first (mechanical proof — simplest possible effect, no error type, single-line handler), then `std/parse` migrated (proves parameterized `Throws<E>` end-to-end). Debugging loop: Log breaking = infrastructure bug; Parse breaking after Log works = Throws-specific bug. Smaller test before bigger test.
- **2026-04-18** — **Error message quality bar committed**: six operational commitments (source location + carets, plain-English first, concrete compilable fix, grade by engagement level, never leak implementation vocab, runtime uncaught-throw shows trace + hint) + engagement-level detection heuristic (Invisible / Explicit / Expert, first-match-wins on per-error-site basis). Governing principle (user quote): "If we detect that they're big enough to be on the ride, we can allow them in on some of the sausage making. Otherwise, we insulate." Operational: invisible-level users never see "row," "label," "unification," "ρ," "substitution" in any effect error message. Detection: expert = uses row variables or effect-polymorphic combinators; explicit = function has `can` annotation OR enclosing `with`; invisible = neither.
- **2026-04-18** — **Xie & Leijen 2020 read** ("Effect Handlers in Haskell, Evidently"). Validates evidence-passing compilation commitment. Surfaced CRITICAL design insight: **three-kind operation taxonomy**. Every effect op is classified at declaration as `value` (constant resume), `function` (tail-resumptive, evaluates in-place, direct indirect call), or `operation` (general, captures continuation via multi-prompt control). In Quartz's committed effect set, ONLY `Throws.throw` (aborts — free), `Async.{await, spawn, suspend}` (Phase 3), `Panic.panic` (aborts), and deferred `Ndet.choose` are operation-kind. All other 10+ ops are function-kind and hit the fast path. Benchmark evidence in paper §6: evidence-passing library (EV) is constant-time in deep effect stacks, ~1.5x faster than next alternative in realistic workloads, within 1% of pure on abort-like effects. Key implementation insight: operation-kind ops reuse Quartz's existing `$poll` state-machine lowering — Phase 3 (async migration) is reframing, not rewriting. Full compilation strategy documented in `EFFECTS_LLVM_COMPILATION_MEMO.md`. Phase 0 exit criteria all met.
- **2026-04-18** — **Error-handling surface unified** into four tiers (Assertion / Effect / Data / Panic) with exactly one canonical form per user intent. Resolves Option/Result/`!`/`$try`/Panic ambiguity. Sub-decisions:
  - `!` stays as assertion (panics, uncatchable, not effect-typed). Closes Open Decision #4.
  - `$try(x)` macro **deleted** — replaced by `try` prefix keyword.
  - `try` is **optional sugar**, not mandatory (per Design Philosophy — invisible default, loud when wielded).
  - Option propagation uses **unified `Throws<Empty>`** (not a separate `Partial` effect). One substrate.
  - `throw` is an expression with Never type.
  - `reify { ... }` block added for effect→Result conversion.
  - `??` and `.unwrap_or()` both kept (ergonomic chaining, minor redundancy acceptable for "sexiest API" surface).
  - Error messages grade down by engagement level.

## Next session when returning

**🟢 None.** The epic is complete. See the closure summary at the top of this file. Live priorities track in [`docs/ROADMAP.md`](../ROADMAP.md).

Two phases remain explicitly deferred with concrete-user-need pull-in triggers:

- **Phase 4b — Multi-shot / `Ndet`.** Pull-in trigger: a concrete user need that single-shot evidence-passing cannot serve. Rationale: multi-shot continuation capture is strictly more expensive than single-shot, no current Quartz program needs it, Haskell lived with single-shot via mtl for ~20 years, and the addition is non-breaking. Decision memo: [`PHASE_4B_MULTISHOT_DECISION.md`](PHASE_4B_MULTISHOT_DECISION.md).
- **Phase 6.3 — REPL.** Pull-in trigger: web playground or REPL test harness materializes as a real surface that needs the effect-runtime threading.

If either trigger fires, file a fresh kickoff under `docs/handoff/` and link from ROADMAP — do not resurrect this archived plan as a living doc.
