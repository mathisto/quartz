---
title: scoped_async_yield_resume_spec deterministically hangs at `llc -O0`, passes at `-O2`
severity: Medium-High (real concurrency bug masked at -O2; the spec is the only repro so far, but an -O0-sensitive scheduler hang likely affects other scope/yield-resume code)
surfaced: 2026-06-05 (A.44 run #4 — surfaced by the qspec serial-retry pass, which reproduced the hang serially under `--no-cache -O0`)
status: ✅ FIXED 2026-06-05 — root-caused to a generator save-set gap; see Resolution
related: docs/bugs/done/POLL_BODY_MATCH_ARM_LOCAL_NOT_SAVED.md (sibling of the same class — save-set gap), docs/design/SCOPE_UNIFICATION.md
---

# Resolution (2026-06-05)

Not a scheduler race — a **generator-frame save-set gap**, the same class as the
`POLL_BODY_MATCH_ARM_LOCAL_NOT_SAVED` sibling. The loop induction variable `i`
(declared `var i = 0` inside the `with Scoped do tag -> ... end` body) was never
added to the `$poll` coroutine's save/restore set, so on every cooperative-yield
resume `i` was read from a freshly-allocated (uninitialized) stack `alloca`. At
`-O0` that fresh slot reads 0 → `i++` → 1 → suspend again with `frame[0]==1` →
the state machine spun forever at the same suspend state (the deterministic
hang). At `-O2` mem2reg turned the no-dominating-store load into `undef` and the
optimizer collapsed the loop, so it "passed" by exploiting UB — exactly
hypothesis #2 below.

Traced decisively by instrumenting the worker dispatch: `poll_result=-1
state=1` printed in an infinite stream at `-O0` (one line at `-O2`).

**Why the collector missed `i` — three gaps, all fixed:**

1. `mir_collect_generator_locals` had no `NODE_EXPR_STMT` case. A `with ... do
   ... end` in statement position is wrapped in `NODE_EXPR_STMT` (inner expr =
   `left`). The collector walked the function body `NODE_BLOCK` → children
   (`NODE_EXPR_STMT`, `NODE_RETURN`) but never unwrapped the `NODE_EXPR_STMT`,
   so it never reached the `NODE_WITH` inside. **Fix:** add a `NODE_EXPR_STMT`
   case that recurses into the inner expression (`mir_lower_gen.qz`). This is
   the load-bearing fix — it also makes any statement-position `match`/`with`
   body's locals collectable.
2. Even once reached, the collector had no `NODE_WITH` case. **Fix:** add one —
   collect the bound param (`tag`) and recurse into the body (`right`) for `i`.
3. The synthesized guard-self (`__qz_scoped_self_*`) and unnamed-`v`
   (`__qz_scoped_v_*`) slots don't exist in the AST (created during MIR
   lowering), so the static collector can't see them. **Fix:** register them as
   dynamic generator locals via `mir_gen_register_dynamic_local` in
   `mir_lower_with_scoped` (`mir_lower.qz`), mirroring `__preempt_ctr` /
   for-in temps. No-op outside a generator.

After the fix the suspend block spills `tag`, `i`, and `__qz_scoped_self_*` to
the frame; the spec passes at BOTH `-O0` and `-O2`, fixpoint holds.

Files: `self-hosted/backend/mir_lower_gen.qz`, `self-hosted/backend/mir_lower.qz`.

---

# Summary

`spec/qspec/scoped_async_yield_resume_spec.qz` (1 test:
"acquire fires before body, release fires after natural exit") **hangs
forever when its binary is built with `llc -O0`**, but **passes when
built with default `llc` (`-O2`)**. The Quartz source and the emitted
LLVM IR are identical between the two — only the LLVM backend opt level
differs.

This is why it shows up as a rotating "TIMEOUT (>300s)" in the full
qspec suite: `_qspec_run_one` assembles native specs (those calling
`@__qz_sched_init`) at `llc -O0` (Quakefile.qz ~4926, chosen for 3×
faster assembly). `quake qspec_file` and the smoke tests use default
`llc` (`-O2`, Quakefile.qz ~6184), so the spec passes there — which is
why every prior "standalone-triage" of this spec reported PASS and it
was bucketed as pool contention.

# Reproduction (deterministic)

```
INC="-I std -I . -I self-hosted -I self-hosted/shared -I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend -I spec/qspec/fixtures"
./self-hosted/bin/quartz --no-cache $INC spec/qspec/scoped_async_yield_resume_spec.qz > /tmp/s.ll 2>/dev/null

# Hangs (kill after a few seconds):
llc -O0 -filetype=obj /tmp/s.ll -o /tmp/s0.o && clang /tmp/s0.o -o /tmp/s0 -lm -lpthread && /tmp/s0   # HANGS

# Passes:
llc -O2 -filetype=obj /tmp/s.ll -o /tmp/s2.o && clang /tmp/s2.o -o /tmp/s2 -lm -lpthread && /tmp/s2   # prints + exits 0
```

Confirmed 2026-06-05: `-O0` → SIGALRM at 25 s (hang); `-O2` → PASS.
Cache state is irrelevant (`--no-cache` repros). The match-arm save-set
fix `eff70c0b` is NOT the cause — the spec passes at `-O2` with the same
binary, and an A/B against the pre-`eff70c0b` golden would show the same
opt-level split (the bug predates this session; it was in the rotating
"contention" cluster across multiple earlier runs).

# Why this matters / hypothesis

`-O0` produces correct-but-unoptimized machine code; it does not
"miscompile" valid IR. A hang that appears only at `-O0` therefore points
to one of:

1. A **timing-sensitive scheduler race** in the scope/yield-resume path
   (`std/sync/scope`, the `Scoped`/`acquire`/`release` machinery, the
   active-wake park/unpark from Phase 4e.8). `-O0` code runs slower and
   with different instruction scheduling, widening or shifting a window
   that `-O2` timing happens to avoid. The deadlock is most likely a
   missed-wakeup / lost-signal between a parked goroutine and its waker.
2. **Undefined behavior in the emitted IR** (uninitialized slot, a
   load/store the optimizer can prove dead and drops at `-O2` but `-O0`
   faithfully executes into a spin/park that never gets signaled).

The spec exercises a `with`-scoped resource whose body yields and
resumes — i.e. a suspend point inside a `Scoped` `acquire`/`release`
bracket. Start by dumping where the `-O0` binary is stuck:

```
llc -O0 -filetype=obj /tmp/s.ll -o /tmp/s0.o && clang -g /tmp/s0.o -o /tmp/s0 -lm -lpthread
/tmp/s0 &   # then: lldb -p <pid>, `bt all` — find the parked goroutine + the waker that never fires
```

# Fix direction (once root-caused)

If it's a missed-wakeup: the park and the wake must publish/observe a
flag with a barrier such that a wake that races the park is never lost
(the classic "check-then-park" must re-check under the lock / after
registering as a waiter). If it's IR UB: find the uninitialized/dropped
slot (compare `-O0` vs `-O2` behavior with `opt -O2 -print-after-all`,
or bisect IR passes). The sibling save-set bugs this session
(`POLL_BODY_*`) are a reminder that suspend-point state handling is a
recurring soft spot.

# Verification checklist

* `llc -O0` build of the spec → prints and exits 0 (not a hang).
* Full qspec suite: `scoped_async_yield_resume_spec` stops appearing in
  the rotating-TIMEOUT set across ≥3 runs.
* Scope/async sweep green: `scope_with`, `go_scope`, `scope_sleep`,
  `await_nonasync`, `colorblind_async`, `concurrency`.
* `quake guard` fixpoint + Rule-2 smokes.

# Scope note

Deterministic at `-O0`. Distinct from pool contention (reproduces
serially, `--no-cache`, single process). The qspec serial-retry pass
(2026-06-05) correctly keeps it FAILED rather than masking it as a
contention victim, because the retry runs the same `-O0` path.
