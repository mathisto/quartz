# SCOPE_INHERITANCE_SPAWN_THEN_CANCEL_FLAKE

**Filed:** 2026-05-02 (during B.7 Phase 4d landing)
**Closed:** 2026-05-03 (Phase 4e.8 active-wake substrate; test moved to standalone smoke)
**Status:** RESOLVED
**Severity:** low (test-only — production-relevant guarantees still hold lazy)

## Resolution

Removed the flaky `it("spawn-then-cancel + yield — child observes on
recheck")` test from `spec/qspec/scope_inheritance_spec.qz` and moved
its semantics to a standalone smoke at
`spec/qz/scope_spawn_then_cancel_smoke.qz`. The standalone form uses
`scope_sleep_ms` (Phase 4e.1) wrapped in `scope_with` (so the throw
bridges through `_sw_catch` to the outer Throws handler); the
parent's `scope_cancel_with` triggers the Phase 4e.8 active-wake
walker, the parked sleep wakes within microseconds, throws, the
child catches via `with Throws { throw: cap }`, and rechecks
`scope_is_cancelled(current_scope())`. 20/20 deterministic across
runs.

The qspec format itself fundamentally cannot express the
worker-blocks-then-cancel pattern reliably: per the May 3 2026
spec-authoring caveat in `CLAUDE.md`, qspec describe/it lambda
bodies treat `go fn()` as a Future created+polled inline (not a
real worker-thread spawn), so the parent thread is blocked inside
the inline poll while the "worker" runs cooperatively. The
standalone `def main()` form gives `go` real worker-thread
semantics.

A separate gap was discovered while building the smoke test:
`scope_sleep_ms` called directly inside `with Throws { throw: cap }`
(without a `scope_with` wrap) does NOT propagate its throw to cap
when `current_scope()` was inherited via Phase 4b TLS round-trip.
Filed as a follow-up at
`docs/bugs/SCOPE_THROW_BYPASS_WITHOUT_SCOPE_WITH.md`.
**Test:** `spec/qspec/scope_inheritance_spec.qz` — `it("spawn-then-cancel + yield — child observes on recheck")`
**Phase of origin:** B.7 Phase 4c (`223804c5`, 2026-05-02). Pre-dates Phase 4d.

## Symptom

The test fails ~80% of the time (4/5 runs in a tight loop). On the failure path the second assertion fails:

```
Expected 1, got 0 — si_child_cancel_after_recheck
```

First run after a fresh build typically passes. Subsequent runs fail at the same rate regardless of whether the build cache is fresh.

## Reproduce

```bash
rm -rf .quartz-cache
./self-hosted/bin/quartz -I self-hosted/frontend -I self-hosted/middle \
  -I self-hosted/backend -I self-hosted/error -I self-hosted/shared -I std \
  spec/qspec/scope_inheritance_spec.qz > /tmp/sis.ll
( cd /tmp && export PATH="/opt/homebrew/opt/llvm/bin:$PATH" \
  && llc -filetype=obj sis.ll -o sis.o \
  && clang sis.o -o sis -lm -lpthread )
for i in 1 2 3 4 5; do /tmp/sis 2>&1 | grep -E "passed|failed"; done
```

## Test logic

```be
def si_record_cancel_after(): Int
  if scope_is_cancelled(current_scope())
    si_child_cancel_after_first = 1
  end
  sched_yield()
  if scope_is_cancelled(current_scope())
    si_child_cancel_after_recheck = 1
  end
  return 0
end

def si_spawn_then_cancel_body(): Int
  var h = go si_record_cancel_after()
  sched_yield()
  scope_cancel(current_scope())
  await h
  return 0
end

# In `it("...")`:
var s = scope_with_cancel(scope_root())
scope_with(s, si_spawn_then_cancel_body)
assert_eq(si_child_cancel_after_first, 0)        # OK — fires before cancel
assert_eq(si_child_cancel_after_recheck, 1)      # FLAKES — sometimes 0
```

## Diagnosis trail

**Pre-existing, not caused by Phase 4d.** Verified by stashing the Phase 4d
diff to `std/sync/scope.qz` (the only file Phase 4d touched in stdlib),
rebuilding, and running the spec five times — same 4/5 fail rate. The
proactive deadline timer is not in this code path: `scope_with_cancel(root)`
passes `NO_DEADLINE` through `_scope_make_child`, which skips
`scope_register_deadline`.

The handoff committed as `223804c5` records "6/6 first run" — first run after
build matches the observed pattern; the flake hides on the warm-up run and
surfaces on subsequent invocations.

## Hypothesized root cause

`sched_yield()` is not a hard scheduling barrier. The scheduler may resume
the parent immediately if no other ready task is on the local worker; on a
multi-worker scheduler, the spawned child may be on a different worker and
not have run its second `is_cancelled` check before the parent's `await h`
returns. If the child resumes after `await` already saw the child as
"completed" (because completion races with the second-check write), the
recheck flag write gets clobbered or never reached.

A second possibility: the worker `$poll` dispatch's TLS save/restore (Phase
4b) saves `current_scope_handle` at every poll exit. If the child task's
final return path takes a fast path that skips the side-table update, the
recheck `current_scope()` read may see the worker's previous TLS scope (the
parent's, which IS cancelled at that point). That would actually make the
test PASS more often, not less — so this is unlikely the root cause.

Most likely: `await h` returns before the child has run its second check.
The `sched_yield` in the child is supposed to give the parent a turn, but
the parent's `scope_cancel` + `await` is short enough that by the time the
child resumes, its frame has already been collected. Or the await wakes the
parent before the child's recheck completes — `await` reads the result slot
once the child returns 0, and the order of "set result" vs "set
si_child_cancel_after_recheck" inside the child function is not enforced
across sched_yield boundaries.

## Fix space

This is a structural test reliability issue, not a soundness bug:

1. **Tighter synchronization in the test.** Replace `sched_yield()` with
   an explicit channel send/recv pair so the parent waits for the child's
   first check to complete before cancelling, then signals back to wake
   the recheck. Removes scheduler-jitter dependency.
2. **Loop-and-retry inside the recheck.** Have the child loop on
   `is_cancelled` for up to N ms before giving up. Forgiving but masks the
   underlying race.
3. **Phase 4e (recv/send wake on cancel) makes this trivially correct.**
   Once blocking primitives consult the scope, the child's "waiting on
   cancel" path becomes deterministic — it parks on a scope condvar that
   the cancel walk wakes. Replace the test's `sched_yield()` with a
   `scope_check()` that throws on cancel, caught by the test harness.
   The flake then disappears as a side effect of the wake-protocol
   guarantee.

Recommended path: defer the fix to Phase 4e. The test is exercising a
substrate guarantee that Phase 4e will make robust by construction; fixing
it locally with channel handshakes adds noise that gets ripped out later.

## Production impact

None. User code that needs to observe cancellation across yield boundaries
should call `scope_check()` (which throws via the unified Throws transport)
or — once Phase 4e ships — use a blocking primitive that wakes on scope
cancel. The lazy-fire path used by `scope_is_cancelled` is correct; the
flake is in how this specific test orders writes around `await`, not in the
substrate's correctness.
