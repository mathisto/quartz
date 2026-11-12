# Payload-Type De-Erasure (Option/Result concrete payload through generics)

**Created:** 2026-07-08 · **Status:** design approved, Phases 0→2 in flight (attended)
**Owner decision:** de-erase the representation (not a side-table); drive Phases 0→2 this session.

## Problem

An `Option<T>` / `Result<T,E>` payload's **concrete monomorphic type** is dropped at
several seams, then two consumers that need it fail:

- **Typecheck** assigns `TYPE_INT` to a `Some(s)` binding or a `??` result → false-positive
  QZ0201/R2.3 type errors (worked around narrowly in `15ef66e7` / `5cff669a` by only
  flagging *literal* int RHS). These are symptom masks.
- **MIR/codegen** lacks the concrete type at the match-arm bind, so it mis-selects
  *interior-address* (inline value struct) vs *loaded-pointer* (boxed) → the
  `option_boxed_struct_niche_spec` **runtime SIGSEGV** on `match inner { Some(p) => p.x }`
  where `inner` is itself an outer-match payload (bound as abstract `T`).

Both descend from one root: Quartz's **i64-existential erasure model** folds String / struct /
Int into one "i64 handle" class (`tc_is_i64_type`, `typecheck.qz:2918`) and drops the
concrete payload arg through generic instantiation and nested binding. The niche machinery is
**LIVE** (`mir_boxed_niche_enabled()` = 1 since `e2ffe0a0`), so these holes are active
miscompiles, not dormant scaffolding.

## The architectural decision — DE-ERASE (not a side-table)

Research across Rust, Swift, OCaml/GHC, Go, MLton (full brief in the execution log):

- **Monomorphize (Rust, MLton):** concrete `T` lives in the IR per instantiation; niche
  layout is a pure function of it — nothing to recover.
- **Uniform representation (OCaml/GHC):** erase to one word; no static niche packing at all;
  `UNPACK`/levity-polymorphism is the opt-*out*.
- **Witness tables / dictionaries (Swift, Go):** erase but carry the concrete type in a
  side-channel consulted at the use site.

**Quartz is a whole-program monomorphizing compiler — the Rust/MLton regime.** Its i64-erasure
is a GHC-uniform-representation choice bolted onto a Rust-shaped compiler: it pays
monomorphization's full cost and discards the concrete type that makes it worth paying. The
side-table (Go/Swift) is the design forced on backends that *refuse* to monomorphize —
adopting it imports runtime-recovery machinery to solve a problem monomorphization already
solves statically, and *"every erased-value-plus-parallel-annotation scheme is one missed
lookup away from the current bug class"* (which is exactly this segfault). Quartz's own F4 work
(`mir_is_value_layout_type`, `mir_deerase_vec_arg_type`) already de-erased and fixed both FPs
and segfaults. **So: de-erase; keep i64-erasure only as the narrow escape hatch for genuinely
un-monomorphizable payloads (the Rust-`dyn`/GHC-lifted-box corner) — inverted from GHC's default.**

## The unifying invariant

> A variable's tracked type — TC ptype-arg (`ptype_arg1s/arg2s/names`, `typecheck.qz:4459`)
> / MIR type-string (`struct_types` table, `mir.qz:5595/5665`) — **always carries the concrete
> `<payload>` arg whenever the monomorphizer knows it.**

Niche layout, inline-vs-boxed bind, field-access `struct_name`, and the 5 QZ0201 checks are all
pure functions of that string. The type is already carried on the working paths (annotated /
monomorphic returns); it breaks across exactly **two seams**:

1. **Generic function-return instantiation.** TC: `tc_parse_type` knows only *trait*-level type
   params, not *function*-level ones → inner arg = `TYPE_ERROR`, repaired at call site by
   `tc_substitute_annotation` only when it hits (`typecheck_expr_handlers.qz:4883-4935`). MIR:
   `mir_subst_return_type_for_call` leaves `U` unbound when `U` sits inside a `Fn(T):U` arg
   (`mir.qz:5839-5897`). Witness: `list_selected_item<Item>(l): Option<Item>` → bare `Option`.
2. **Nested-match binding.** MIR `mir_mark_pattern_bindings_typed` (`mir.qz:8614`) stores the
   abstract enum field-type `T`; the concrete override (`mir.qz:8637-8656`) fires ONLY for a
   nested `Option<X>` whose inner `X` niches — every other shape keeps `T`.

## Phases (each commits + validates independently)

### Phase 0 — `??` de-erase  (gate-1-inert)
`typecheck_helpers.qz:215`: `??` returns `right_type` (the default operand's concrete type),
not `TYPE_INT`. The compiler uses the `??` operator **zero** times (only a string literal in
`lexer.qz:754`) and `??` MIR lowering is node-driven, so this is inert → fixpoint byte-identical.
Validation: `error_quality_spec` / `option_boxed_builtin_niche_spec` targeted + fixpoint +
brainfuck/style_demo smoke. Does NOT yet remove the literal-narrowing gate (other producers
still erase until Phase 2).

### Phase 1 — nested-match de-erase (MIR)  (gate-0-LIVE, memory-safety)
Widen `mir_mark_pattern_bindings_typed` (`mir.qz:8637-8656`) so a single-payload Option/Result
match binding carries its concrete `concrete_pl` — not only the narrow nested-Option-that-niches
case. Fixes the `Some(Some(struct))` SIGSEGV (inner subject typed concretely → `is_inline`
correct → interior-address bind). **Caution:** the current gate has a documented nested-Option
OUTER-layout carve-out; widen without regressing that. Validation: `option_boxed_struct_niche_spec`
green + fixpoint + **full suite** (now runnable, ~15min flat) + smoke.

### Phase 2 — generic-return de-erase (TC + MIR)  (hottest, foundational)
Thread function-level type params so a generic `Option<T>` return keeps its arg:
- TC: bind func-level type params in `tc_parse_type` / always run `tc_substitute_annotation`
  when the callee has type-params + a return annotation + inferrable args
  (`typecheck_expr_handlers.qz:4900-4935`).
- MIR: `mir_subst_return_type_for_call` bind `U` from the arg/receiver
  (`mir.qz:5878`, cf. item-42 note).
Then **delete the literal-narrowing carve-out** (`typecheck.qz:3074-3083`) — all producers
de-erased, so the QZ0201 checks can be strict again. Fixes `Some(s)` from generic returns +
QZ0406 (`vec_pop_chained_unwrap_niche`). Validation: full suite + the R2.3/field-store specs +
smoke.

### Phase 3 — (DEFERRED, own session) retire i64-fold interchangeability + light up String niche 6.4b
Once payloads are de-erased, stop folding String↔Int for checked directions and re-enable
`Vec<Option<String>>` (String was bisected out of the niche because it crashed the form-widget
call graph — itself an instance of this erasure surface). Riskiest; the payoff (zero-cost
`Option<String>`). Not in this session's scope.

## Validation protocol (every phase)
Per-phase: targeted `FILE=<spec> quake qspec_file` red→green → `quake guard` fixpoint → brainfuck
+ style_demo smoke byte-identical (normalize the `%ret.bp.<addr>` nondeterminism per
`docs/bugs/VALUE_RETURN_SSA_NAME_NONDETERMINISM.md`) → **for Phases 1 & 2, full `quake qspec`**
(memory-aware cap holds now; watch `memory_pressure`, `pkill` after) → commit. Save
`quartz-pre-deerase-golden` before touching MIR (Bootstrap-Island Rule 1).

## Execution log

### STATUS SUMMARY (2026-07-08, attended)
- **Phase 0** (`7cf28e2b`) — `??` de-erase — LANDED, gate-1-inert.
- **Phase 1** (`85dcfc2d`) — nested-match struct-payload SIGSEGV — LANDED, full-suite validated (zero regressions).
- **Phase 2 (Path A)** — explicit generic-return de-erasure (`first_of<Point>()`) — implemented, full-suite validating. TC was already done by prior generics work; the gap was MIR-only (`mir_subst_return_type_for_call` bound a type-param only on exact `pann==tp_name`). **Fix = Path A: bind func-level type params from the call's EXPLICIT type-args (`first_of<Point>`); the original exact-match arg-inference fallback is retained unchanged.** A first attempt also added Path B (structural `Base<T>`-vs-`Base<arg>` arg unification) — **REVERTED**: it over-bound inferred generic-Option returns and regressed all of `tui_focus_ring_spec` (`focus_ring_current`). Caught by the full-suite diff (fail on P2, pass on P1); the revert restored FocusRing 23/23 while keeping genret's explicit case fixed. LESSON: gate-0-live generic-typing changes MUST full-suite-diff before commit — the targeted spec was green but a different generic-Option consumer broke.
- **REMAINING de-erasure tail (filed, NOT this session):**
  1. **Path B / inferred-from-arg** — `first_of(ps)` with no explicit type-arg still erases because the local `ps = vec_new<Point>()` isn't tracked as `Vec<Point>` at the call site (marked `it_pending` in the spec).
  2. **Inferred-inline construction** — `opt = Some(Some(Point{..}))` unannotated still SIGSEGVs (construction-time inference).
  Both are the SAME root: a local bound from a generic constructor/return doesn't carry its concrete type-arg. This is the next de-erasure sub-phase (local/construction concrete-tracking).
- **Phase 2c — DELETE the literal-narrowing workaround (`typecheck.qz:3074-3083`): GATED, NOT SAFE YET.** The carve-out masks FPs for ALL erased-Int payloads; while the tail (Path B + construction) remains erased, removing it would re-expose those FPs. Workaround removal is gated on completing the de-erasure tail.

### Detail log
- 2026-07-08: design approved (de-erase, Phases 0→2). Research + data-flow map complete.
- 2026-07-08: **Phase 0 LANDED** (`7cf28e2b`) — `??` yields `right_type`; gate-1-inert, fixpoint 3298, smokes inert, niche spec 36/36.
- 2026-07-08: **Phase 1 LANDED** (`85dcfc2d`) — widened the `mir_mark_pattern_bindings_typed` override (`mir.qz:8646`) to carry the concrete payload type for ALL single-payload Option/Result bindings (was: only nested `Option<X>` that niches). Root of the nested-`Some` SIGSEGV: a plain struct payload (`Some(p)` where `p: Point`) kept abstract `T` → boxed-load path → bound a scalar as a pointer → `p.x` segfault. **VALIDATED gate-0-live: full-suite golden-vs-Phase-1 failing-file sets IDENTICAL (zero regressions); `option_boxed_struct_niche_spec` golden ✗SIGSEGV → Phase-1 ✓ 16/16** (the fix, visible in the full suite itself). The lone diff `graceful_shutdown_spec` is the known intermittent shutdown race — confirmed flaky (3/4 green), orthogonal to Option typing. Fixpoint 3298, byte-identical.
  - METHOD NOTE: the fix chains — outer `Some(inner)` must track `inner` concretely for the inner match to resolve `p`. Verified via annotated (Test C) + typed-return (`some_some()`) forms: golden SIGSEGV → Phase-1 42/pass. (Beware: testing a binary from `backups/` or scratchpad breaks argv[0]-relative stdlib resolution — swap into `self-hosted/bin/quartz` for standalone repros.)
  - **REMAINING (filed, D6): inferred-inline nested construction still SIGSEGVs.** `opt = Option::Some(Option::Some(Point{...}))` with NO annotation / NO typed-return source crashes, because `opt`'s construction-time inferred type is not the full `Option<Option<Point>>` (so the outer `concrete_pl` can't resolve the inner `Point`). The real spec + Test C (annotated) + Test D (typed return) all work — this is a **construction-time type-inference gap**, adjacent to Phase 2's inference threading, NOT the Phase-1 bind logic. Repro: `$SP/nested.qz` (exit 139); annotate `opt: Option<Option<Point>>` → exit 0. Fix belongs with construction/generic-return inference (Phase 2 or a Phase-2 sibling).
