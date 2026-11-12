---
title: drop_spec — every Drop test fails at `llc -O0`, all pass at `-O2`
severity: Low-Medium (latent: the qspec suite runs drop_spec at -O2 where it passes, so it is NOT a suite failure today — but a real -O0 codegen/UB issue in the `trait Drop` scope-exit path)
surfaced: 2026-06-05 (A.44 — found while A/B-verifying the scoped_async_yield_resume -O0 fix; golden-identical, pre-existing, NOT a regression of that fix)
related: docs/bugs/done/SCOPED_ASYNC_YIELD_RESUME_O0_HANG.md (sibling opt-level-sensitivity, different root area — that one was a generator save-set gap; this one has no async/suspend at all), docs/design/SCOPED_RESOURCES.md
---

> **CLOSED-STALE 2026-07-07** — re-reproduced fixed on current binary; see docs/sagas/r24-groundwork-inert-holes-2026-07-07-research/ws2-triage.md. The documented "all-tests-fail-at-`-O0`, all-pass-at-`-O2`" premise is DEAD: with `QUARTZ_COMPILER` set (the spec spawns a subprocess compiler — the original repro omitted this), both `-O0` and `-O2` builds now give the identical 33/34 result. The all-`✗`-at-`-O0` symptom is gone (SHA not pinned). ONE surviving failure — defer/drop ordering on reassignment, opt-level-independent — was refiled as `docs/bugs/DROP_DEFER_ORDERING_BUG.md`.

# Summary

`spec/qspec/drop_spec.qz` (the `trait Drop` lifetime-cleanup suite) **fails
ALL of its tests when built with `llc -O0`** (every `✗`), but **passes 6/6+
when built with default `llc` (`-O2`)**. The Quartz source and emitted IR are
identical between the two — only the LLVM backend opt level differs.

drop_spec uses **no** async / scheduler / suspend machinery (`grep -c
'async|sched_init|sched_yield|await|go ' = 0`), so this is distinct from the
generator save-set class. It exercises only `trait Drop` (`std/memory.qz`) —
`def drop(self): Void` firing when a binding dies at scope exit.

# Why it's latent (not a current suite failure)

`_qspec_run_one` assembles native specs (those calling `@__qz_sched_init`) at
`llc -O0`; all others at `-O2` (Quakefile.qz ~4926 / ~6184). drop_spec has no
`sched_init`, so the suite builds it at `-O2`, where it passes. The -O0 failure
only surfaces if you force `llc -O0` manually (as the scoped_async A/B did).

# Reproduction (deterministic)

```
INC="-I std -I . -I self-hosted -I self-hosted/shared -I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend -I spec/qspec/fixtures"
./self-hosted/bin/quartz --no-cache $INC spec/qspec/drop_spec.qz > /tmp/d.ll 2>/dev/null
llc -O0 -filetype=obj /tmp/d.ll -o /tmp/d0.o && clang /tmp/d0.o -o /tmp/d0 -lm -lpthread && /tmp/d0   # ALL ✗
llc -O2 -filetype=obj /tmp/d.ll -o /tmp/d2.o && clang /tmp/d2.o -o /tmp/d2 -lm -lpthread && /tmp/d2   # passes
```

First failing assertions: "calls drop at end of scope", "calls drop before
return", "calls drop on early return", "calls drop in reverse order (LIFO)",
"drops inner scope before outer", "handles multiple nested scopes" — i.e. drop
is either not firing, firing in the wrong order, or the side-effect the test
observes (a counter / log) isn't landing at -O0.

A/B confirmed pre-existing: the pre-fix golden
(`self-hosted/bin/backups/quartz-pre-scoped-suspend-locals-golden`) produces
the identical all-`✗` at -O0.

# Hypothesis

Two candidates, same as any -O0/-O2 split:

1. **IR UB the optimizer hides.** The Drop scope-exit lowering emits a
   load/store/call sequence with an uninitialized or aliasing slot that -O2
   proves dead and drops (so the observable side effect happens to land) while
   -O0 faithfully executes the broken path. Most likely: the drop-flag /
   drop-list slot tracking which bindings still need dropping is read before a
   dominating store, or the observed counter is stored through a slot that -O0
   doesn't keep coherent.
2. **Drop ordering depends on an -O2 pass.** Less likely (drop insertion is
   MIR-level, pre-llc), but worth ruling out by diffing the -O0 vs -O2 machine
   behavior.

Start by narrowing to the single simplest test ("calls drop at end of scope"),
dump its IR, and `opt -O2 -print-after-all` / bisect passes to find which one
flips the result — that pass is masking the UB.

# Verification checklist

* `llc -O0` build of drop_spec → 6/6+ pass (not all-`✗`).
* `quake guard` fixpoint + Rule-2 smokes.
* Spot-check the other Scoped/Drop specs (`scoped_resources`, `cross_defer_safety`)
  at `-O0` for the same class.

# Scope note

Deterministic at -O0, opt-level-independent of pool/cache. Pre-existing
(golden-identical). NOT exercised by the suite today. A candidate for making
the suite assemble a sample of non-native specs at -O0 too, so this class stops
hiding behind the -O2 default.
