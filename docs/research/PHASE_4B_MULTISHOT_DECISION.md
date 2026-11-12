# Phase 4b — Multi-shot handlers (`Ndet`): pull-in decision memo

> **Epic**: Operation Piezoelectric Effects · `[piezo]` · Phase 4b
> **Status**: **DEFERRED.** Filed for future evaluation.
> **Filed**: 2026-04-25, on Phase 4 (Path B, generators-via-effects) closure.
> **Predecessor research**: [`PHASE_4_NONDET_GENERATORS_RESEARCH.md`](PHASE_4_NONDET_GENERATORS_RESEARCH.md) §3.2 / §4 / §5.7.
> **Phase 4 retrospective**: [`../design/PHASE_4_GENERATORS_RETRO.md`](../design/PHASE_4_GENERATORS_RETRO.md).

## 1. What this memo is

Phase 4 shipped *single-shot* effects: `Yield<T>`, `Throws<E>`, `State<S>`, `Reader<R>`, `Async`, `FileIo`, `Intern`, plus everything else built on the kind=3 `$poll` machinery. Each handler resumes its continuation **at most once** (or aborts the with-block via the unwind path).

**Multi-shot** = a handler resumes its continuation **more than once**. Each resume runs the body forward from the perform site to the with-block's end (or the next perform), collecting whatever the body returns. The classical use cases:

- **Non-determinism**: `effect Ndet { choose(a, b): Int }` — handler runs the continuation once with `a`, again with `b`, accumulates both results into a vec. Body of `with Ndet do -> [perform_choose(1, 2) * 10] end` evaluates to `[10, 20]`.
- **Probabilistic programming**: each resume carries a probability weight; samples accumulate.
- **Backtracking search**: handler explores branches, body computes from each one.
- **List monad / logic programming**: same shape as Ndet, broader use.

This memo lays out: when to pull Phase 4b in, what we learned about the substrate during 4.B that affects feasibility, and the open questions that need to be answered before committing.

## 2. Pull-in trigger criteria

Phase 4b is **not** scheduled. Pull in when *any* of:

1. **Concrete user demand.** A user (or our own dogfooding) has a real program that wants `choose` semantics — backtracking parser, probabilistic model, logic-programming experiment, search-heavy combinator. "Wouldn't it be cool" doesn't count; "I cannot express my program without it" does.
2. **A research demonstration that anchors the language's identity.** If Quartz wants to be "the systems language with full algebraic effects" alongside Koka / Effekt / Unison, multi-shot is the missing leg. Decision in this direction is a marketing/identity call, not a technical one.
3. **Phase 4 substrate makes it nearly free.** Honest evaluation post-4 (see §3 below): we have the consumer-drive `$poll` re-entry and cooperative kind=3 dispatch. The remaining cost is frame-cloning + Drop-type discipline. If a low-cost path emerges (e.g. arena-allocated frames with bulk-copy semantics), the calculus shifts.

Until one of those triggers fires, the additive cost (compile-time work + Drop-type restriction tax on user code that uses Ndet effects) does not pay back. Haskell shipped without first-class multi-shot for ~20 years; OCaml 5 deliberately doesn't include multi-shot in the core (Dolan-White-Sivaramakrishnan 2021). Quartz can wait.

## 3. What Phase 4 taught us about the substrate

These observations supersede the 2026-04-23 research synthesis on points where Phase 4 actually exercised the relevant machinery.

### 3.1 Cooperative kind=3 dispatch is the right shape for multi-shot too

Phase 4.B.8.a (`465ab0fc`) split kind=3 dispatch on `(resumed, park_rv)`:

| Handler action | `resumed` | `park_rv` | Outer `$poll` outcome |
|---|---|---|---|
| `resume(v)` synchronously | 1 | (any) | Body's final value (existing P3.0c). |
| Returns without action | 0 | 1 (default) | **Unwind** — handler abort, with-block early-exit (kind=2-style). |
| `__qz_effect_suspend()` → 0, OR `__qz_effect_park(fd)` → -(fd+2) | 0 | ≠ 1 | **Cooperative return** — perform caller's post-perform reads `park_rv` and propagates POLL_SUSPENDED up the `$poll` chain. |

Multi-shot's natural shape: handler stashes the resume-value, returns "cooperatively" with a multi-shot sentinel, harness re-enters the `$poll` from the recorded resume state, repeat per choice, accumulate. The cooperative path (already shipped) is the foundation; multi-shot adds **frame snapshotting before each resume** so subsequent resumes start from the same parked state instead of advancing past the previous one.

This was not obvious at research-synthesis time (the synthesis assumed multi-shot would need a fundamentally different dispatch). Cooperative dispatch turns out to be the right primitive for both.

### 3.2 Frame cloning is the load-bearing primitive — and we now know its shape

The `$poll` state machine is a heap-allocated frame with:

- `frame[0]` = state discriminant.
- `frame[1]` = result slot.
- `frame[2]` = poll_fn pointer.
- `frame[3..]` = locals (registered via `mir_gen_register_dynamic_local` + reserved padding `GEN_FRAME_PADDING = 32`; Phase 4.B.9.2 wired six iter-lowering sites into this).

A multi-shot resume is **`memcpy(new_frame, parked_frame, frame_size); call poll_fn(new_frame, resume_value)`**. The frame is dense (no embedded Drop types per §3.3) and has a known size at codegen time (the largest dynamic-local offset + padding). The runtime helper would be `__qz_eff_clone_frame(src) -> dst` — a fixed-size memcpy. No new TLS slot, no new dispatch path beyond cooperative-with-multi-shot-sentinel.

**Cost estimate** (revised post-4.B.8): 3-5 quartz-days for the runtime + typechecker restriction, vs the synthesis's 8-12. The substrate is more reusable than the synthesis predicted.

### 3.3 Drop-type restriction is the real friction

Frame cloning by memcpy assumes every value in the frame is `Copy`. Anything with a non-trivial Drop (`String`, `Vec<T>`, `Box<T>`, `Arc<T>`, user types with `def drop(self): Void`) cannot be cloned safely — a memcpy creates two owners of the same allocation; either owner's drop double-frees.

Three options for the restriction:

1. **Reject Drop types at multi-shot perform sites.** Cleanest semantics. Forbids `perform Ndet.choose(some_string, other_string)`. Workable for the classical Ndet-over-Int example; painful for "real" multi-shot use (probabilistic programs over distributions backed by `Vec<f64>`).
2. **Reject Drop types in the body of any `with Ndet do -> ... end`.** Strictest. The entire body must be Copy-only. Eliminates the surprise of "this works until I introduce a `String`", but tighter than necessary.
3. **Require explicit `Clone` for cross-resume types.** Multi-shot perform sites accept any value; before each resume, the runtime calls user-defined `clone()` on every Drop-typed local. Maximally flexible; complicates codegen (every dynamic-local needs an emit_clone slot) and incurs a per-resume O(n_locals) cost.

The decision is a design call, not a technical one. Rust's `Generator` / `Pin` API takes Option 1 (effectively — `Generator` futures are not `Clone` by default). Koka takes Option 3 implicitly (no Drop types — GC manages everything). Quartz has the move-semantics machinery for Option 1 already; the typechecker can refuse `move` of a Drop type into a multi-shot frame.

**Recommendation when Phase 4b ships**: Option 1, scoped tightly. Reject Drop types at multi-shot perform sites only. Accept the friction; document the workaround (lift Drop-typed values to handles with `Copy` indices). If Option 3 becomes worth the codegen cost, add it later as a stretch.

### 3.4 Shallow vs deep handlers

Phase 4 shipped **deep** handlers (the handler-stack scan walks back to the install). Multi-shot conventionally wants **shallow** handlers (the handler runs once, must re-install itself if the body re-performs). The current handler-stack scanner is one-shot-friendly because each `with E do -> body end` pushes a single entry that lives for the body's duration.

For `Ndet.choose`: the handler body wants `with Ndet do -> resume(true); resume(false) end` semantics, where each resume re-enters the body as a fresh continuation. Today's deep semantics would scan the handler stack and find the same install entry; that's the right answer here too because Ndet's handler is meant to be deep.

**For now**: Phase 4b can be implemented entirely with deep handlers. If a future use case wants shallow (rare; Effekt and Frank survive without), add it as a separate effect-modifier (`@shallow` annotation on the handler op).

## 4. Estimated cost (revised, post-Phase-4)

- **Original synthesis estimate**: 8-12 quartz-days.
- **Revised estimate**: 3-5 quartz-days, contingent on Option 1 (Drop-types-at-perform-sites restriction) and reusing cooperative kind=3 dispatch.
- **Breakdown**:
  - +1 day: typechecker restriction — `@multishot` op annotation, reject Drop-typed args at perform sites. Spec coverage.
  - +1-2 days: runtime primitive — `__qz_eff_clone_frame` codegen + frame-size threading + per-resume multi-shot dispatch path. Smoke tests.
  - +0.5 day: `Ndet` stdlib effect declaration + `choose(a, b)` op + `with_collect_all do -> ... end` combinator handler.
  - +0.5-1 day: acceptance specs + bench (multi-shot vs hand-coded backtracking).
  - +0.5 day: docs + arch update.

If the restriction proves too tight for the user's actual use case, escalate to Option 3 (explicit `Clone`) — adds 2-3 days for the per-local clone-emit infrastructure.

## 5. Open questions to resolve before pulling in

These are the questions a Phase 4b kickoff handoff would need to answer. Filed here so the kickoff doesn't re-discover them.

1. **`Ndet.choose` arity.** `choose(a, b): T` (binary, classical) vs `choose(opts: Vec<T>): T` (variadic) vs both? The literature standard is binary; Vec-form is sugar.
2. **Result aggregation handler.** `with_collect_all` returns `Vec<T>` of all branch outcomes. Do we ship just this, or also `with_first_success` (returns first non-Err) / `with_weighted` (probabilistic)? Pragmatic: ship `with_collect_all` only; let users build the rest.
3. **Interaction with `Throws` in the body.** If a branch throws, does the harness skip it (collect remaining) or unwind the entire with-block? Skip-this-branch matches probabilistic programming intuition; whole-unwind matches strict semantics. Decision needed before implementation.
4. **Diagnostic surface.** `QZ06xx` for "Drop type in multi-shot perform site." Fix-suggestion text needs to point at the specific binding and recommend the handle-with-Copy-index workaround.
5. **Fixpoint risk.** Multi-shot adds frame-clone codegen to MIR/codegen; Phase 4 hot-path stays untouched. Pre-flight: smoke test that `__qz_eff_clone_frame` doesn't fire for any single-shot effect under the gate. The 4.B.6 `_gen_active >= 2 → == 2` lesson (`feedback_gen_active_kind3_routing.md`) applies — audit every kind=3 site for assumed-single-shot semantics before broadening.

## 6. Decision matrix

| Trigger observed? | Action |
|---|---|
| User has a concrete use case that needs multi-shot | Schedule Phase 4b. Use this memo as the kickoff outline. |
| "We want to ship `Ndet` for the launch blog post" | Defer until launch is on the calendar. Marketing-driven scheduling. |
| Phase 4b "would be nice" / "we have time" | **Reject.** Quartz launches without multi-shot, like OCaml 5. The Drop-type tax on user code is real; don't pay it without payoff. |
| A faster substrate emerges (arena-frame, pool allocator, etc.) | Re-read this memo, re-cost, re-decide. |

## 7. References

- Leijen 2017/2020 — *Structured asynchrony with algebraic effects* (Koka multi-shot semantics).
- Dolan, White, Sivaramakrishnan 2021 — *Retrofitting effect handlers onto OCaml* (one-shot decision rationale).
- Brachthäuser, Schuster, Ostermann 2020 — *Effects as capabilities* (Effekt's no-multi-shot stance).
- Kiselyov, Sabry, Swords 2013 — *Extensible effects* (multi-shot in Haskell via library).
- [`PHASE_4_NONDET_GENERATORS_RESEARCH.md`](PHASE_4_NONDET_GENERATORS_RESEARCH.md) — upstream synthesis (still canonical for the world-survey portion; §4 path estimates superseded by §4 of this memo).
- [`../design/PHASE_4_GENERATORS_RETRO.md`](../design/PHASE_4_GENERATORS_RETRO.md) — what Phase 4 (Path B) actually shipped and learned.
- [`../design/EFFECT_MIGRATION_PLAYBOOK.md`](../design/EFFECT_MIGRATION_PLAYBOOK.md) §3.6 — kind=3 cooperative dispatch (the substrate).
