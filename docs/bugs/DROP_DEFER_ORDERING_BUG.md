---
title: defer runs after drop on reassignment (drop_spec "defer + drop + reassignment", opt-level-independent)
severity: Medium — MIR-level ordering bug in the defer/drop emission; observable wrong cleanup order (a `defer`ed action fires after a `drop` instead of before). Not masked by opt level, so it's a genuine emission-order defect, not IR UB.
surfaced: 2026-07-07 (WS2 triage re-reproduction, isolated from the now-closed DROP_SPEC_FAILS_AT_O0.md whose "all-fail-at-O0" premise is fixed)
related: docs/bugs/done/DROP_SPEC_FAILS_AT_O0.md (parent doc — its O0/O2-split premise is FIXED; this is the one residual failure carved out of it), docs/design/SCOPED_RESOURCES.md
---

# Summary

`spec/qspec/drop_spec.qz` has exactly ONE failing test — the "defer + drop +
reassignment" case — and it fails **at both `-O0` and `-O2`** (opt-level
INDEPENDENT). Everything else in the suite passes (33/34 at both levels). This
is distinct from the old DROP_SPEC_FAILS_AT_O0 bug (an all-`✗`-at-`-O0` symptom
that is now fixed): because this failure does not depend on the LLVM opt level,
it is a genuine ordering defect in the MIR-level defer/drop emission, not
IR-UB-the-optimizer-hides.

# Symptom

On a reassignment that both (a) has a pending `defer`ed action and (b) drops a
value being overwritten, the `defer` fires in the wrong position relative to the
`drop`:

```
Expected:  'cleanup\ndrop RR\ndrop RR'
Got:       'drop RR\ncleanup\ndrop RR'
```

i.e. the `defer`ed action (`cleanup`) should run BEFORE the drop of the
reassigned-over value, but it currently runs AFTER the first `drop RR`.

# Reproduction

The spec spawns a subprocess compiler, so `QUARTZ_COMPILER` MUST be exported or
the run reports spurious "QUARTZ_COMPILER not set" failures (this footgun masked
the real single-failure signal in the parent doc's original repro):

```
INC="-I std -I . -I self-hosted -I self-hosted/shared -I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend -I spec/qspec/fixtures"
./self-hosted/bin/quartz --no-cache $INC spec/qspec/drop_spec.qz > /tmp/d.ll 2>/dev/null
llc -O0 -filetype=obj /tmp/d.ll -o /tmp/d0.o && clang /tmp/d0.o -o /tmp/d0 -lm -lpthread
llc -O2 -filetype=obj /tmp/d.ll -o /tmp/d2.o && clang /tmp/d2.o -o /tmp/d2 -lm -lpthread
QUARTZ_COMPILER=$(pwd)/self-hosted/bin/quartz /tmp/d0   # 34 tests, 33 pass, 1 fail ("defer + drop + reassignment")
QUARTZ_COMPILER=$(pwd)/self-hosted/bin/quartz /tmp/d2   # identical: 34 tests, 33 pass, 1 fail
```

Both builds produce the identical result — confirming opt-level independence.

# Hypothesis / where to look

The bug is in the MIR emission that sequences a scope's pending `defer` actions
against the `drop` of a value being overwritten by a reassignment. On a rebind
that overwrites a drop-owning binding, the emitter appears to run the old
value's drop before flushing the pending defer, when the correct order is
defer-then-drop (defers unwind LIFO-nested relative to the drops of the same
scope). Start from the drop/defer ordering in the MIR rebind/reassignment path
(the `NODE_ASSIGN` / rebind drop lowering) and the defer-flush point at scope
exit, and diff the emitted ordering against the LIFO contract in
`docs/design/SCOPED_RESOURCES.md`.

# Verification checklist

* drop_spec "defer + drop + reassignment" passes → full drop_spec 34/34 at BOTH
  `-O0` and `-O2` (with `QUARTZ_COMPILER` exported).
* `quake guard` fixpoint byte-identical + Rule-2 smokes.
* Spot-check `cross_defer_safety` / `scoped_resources` specs for the same
  defer-vs-drop ordering class.

# Scope note

Opt-level-independent, so classify on its own when picked up — likely a hot MIR
drop/defer emission path (attended-only until inertness is confirmed). This is
the sole residual carved out of the now-closed DROP_SPEC_FAILS_AT_O0.md.
