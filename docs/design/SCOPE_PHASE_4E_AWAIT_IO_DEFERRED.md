# Phase 4e.6/4e.7 — `await` and `io_suspend` deferred-shape

**Status:** filed 2026-05-03, after Phase 4e.5 ships. Captures why the
chunked-poll-first recipe that landed Phase 4e.1 (sleep), 4e.2 (channel
recv/send), 4e.3 (mutex), 4e.4 (rwlock_read), and 4e.5 (rwlock_write)
**does not fit** the remaining two primitives (`await fut`, `io_suspend`),
and what the right next move is.

## The recipe that worked (5 iterations, ~0.3 quartz-day each)

```
def scope_<primitive>(...):
  s = current_scope()
  if s == scope_root() return raw_<primitive>(...) end
  scope_check(s)                          # preflight throw if cancelled
  loop:
    r = try_<primitive>(...)              # NON-BLOCKING attempt
    if r succeeded return r
    chunk = min(SCOPE_SLEEP_CHUNK_MS, deadline_remaining_ms), clamped >= 1
    sched_sleep(chunk)
    scope_check(s)                        # throw if cancelled during sleep
```

Two structural requirements held for all five iterations:

1. **A non-blocking `try_<primitive>` exists** (or can be added cheaply via
   the 5-step intrinsic recipe — Phase 4e.4 prereq added two new ones
   in ~0.2 quartz-day).
2. **Failure is observable as a return-value sentinel** (`-1` for the
   try-lock variants, `0` for `try_send`, atomic empty/closed for
   `try_recv_or_closed`).

When both hold, the helper is ~70 lines of stdlib + a 4-test spec, no
compiler-source touch.

## Phase 4e.6 — `await fut`

**Why it doesn't fit:**

`await` is **not** a try-then-block primitive. It is a yield/resume
mechanism: when a task awaits a future, the worker poll-dispatch
parks the task frame, walks the scheduler's ready queue for the next
runnable task, and the resumed-via-`__qz_sched_wake` path delivers
the value back. There is no "non-blocking try-await" intrinsic and
adding one would be a different mechanism — it would have to peek at
the future's completion slot without registering the awaiting task as
a continuation, then re-poll the ready queue, then sleep. That's not
"a small intrinsic," that's "a parallel scheduler dispatch path."

A chunked-poll `scope_await(fut)` would have **busy-poll semantics**:
loop checking the future's done-flag with a short sleep between checks.
That works but throws away the scheduler's existing zero-overhead
wake-on-resolve, replacing it with periodic CPU wakes. For
latency-sensitive futures that resolve in microseconds, this is a
1000x regression on observation latency. For long-running futures, it
wakes the scheduler ~20 times per second to no purpose.

**Status:** not the right shape. Don't ship a chunked-poll variant.

## Phase 4e.7 — `io_suspend`

**Why it doesn't fit:**

`io_suspend` is itself a scheduler-level park-on-fd-readiness primitive.
It's used internally by the I/O runtime to suspend a task until kqueue
fires for a file descriptor. There is no "non-blocking try-io_suspend"
intrinsic because the operation is inherently a "register interest +
park" pair — not a "check if ready right now."

A chunked-poll `scope_io_suspend(fd)` would need to:

1. Issue a non-blocking `read`/`write`/`accept` against the fd
2. Branch on `EAGAIN`/`EWOULDBLOCK` to determine "not ready"
3. Sleep for chunk_ms
4. Loop

This is replacing `io_suspend` with a busy-loop reimplementation.
It doesn't reuse the kqueue infrastructure already wired into the
runtime, and it pays a CPU wake every chunk_ms for an idle fd.
For a server holding 10,000 idle connections under a scope, that's
200,000 wakes/sec for no work — pathological.

**Status:** not the right shape. Don't ship a chunked-poll variant.

## The right next move — Phase 4e.8 active-wake protocol

The recipe was always lazy/chunked-poll-first because it sidesteps the
infrastructure problem of "how does a scope notify a parked task that
it's been cancelled." For the five primitives where `try_X` exists,
sidestepping was the right call — we got working scope-aware versions
in five days at zero compiler cost.

For `await` and `io_suspend`, sidestepping costs CPU wakes that are
visible in production. The right answer is to build the infra:

**Phase 4e.8 active-wake** (compiler + scheduler):

1. Each `Scope` node gains a **waiter slot** — a single-element queue
   of `(task_frame, primitive_kind)` pairs for tasks parked on this
   scope. Capacity 1 is fine because per-task (recursion: a task can
   only be parked on one primitive at a time).
2. Blocking-primitive runtimes (`sched_sleep`, `try_recv_or_closed`,
   `mutex_lock`, `rwlock_read`/`write`, `__qz_sched_park_for_io`,
   `await`-resume dispatch) call `_scope_register_waiter(scope, frame)`
   on the way in and `_scope_unregister_waiter(scope, frame)` on the
   way out.
3. `_scope_fire_cancel(scope)` walks the scope's child-tree depth-first
   collecting waiters, then calls `__qz_sched_wake(frame)` for each
   one. The waiter wakes early, observes `is_cancelled(scope) == 1`,
   and throws via the unified Throws transport.

Once the active-wake infra exists, the five chunked-poll helpers (`scope_sleep_ms`, `scope_recv`/`send`, `scope_lock`, `scope_rwlock_read`/`write`) are **rewritten to use it** — the chunked-poll loops collapse into a single `register-waiter + park + unregister + recheck` sequence. They become structurally identical to `scope_await`/`scope_io_suspend`, and the recipe becomes:

```
def scope_<primitive>(...):
  s = current_scope()
  if s == scope_root() return raw_<primitive>(...) end
  scope_check(s)
  _scope_register_waiter(s, task_self())
  r = blocking_<primitive>(...)
  _scope_unregister_waiter(s, task_self())
  scope_check(s)                          # cancel may have woken us
  return r
```

This is the **uniform shape** that pays back the active-wake infra
cost across all blocking primitives in one commit. Phase 4e.6/4e.7
are not separate phases — they're the natural consumers of Phase
4e.8 once it ships.

## Sizing

- **Phase 4e.8 active-wake protocol** (single compiler-touch commit):
  ~1.5-2 quartz-days. Touches scope.qz (waiter slot, register/unregister
  helpers, walk-and-wake in `_scope_fire_cancel`), the existing
  blocking-primitive runtime functions in codegen_runtime.qz (5-7
  call-site additions per primitive: park-in, unregister-out), and
  spec coverage proving zero-latency cancel observation across all
  primitives. Reduces total scope-helper line count by ~250 (the five
  chunked-poll loops become 5-line register-park-unregister sequences).
- **Phases 4e.6 / 4e.7 as standalone** (chunked-poll variants):
  technically possible at ~0.3 day each but **not recommended** for
  the reasons above. Both should fold into 4e.8.

## Recommendation

1. Skip Phases 4e.6 / 4e.7 as standalone. Mark them deferred-shape in
   the roadmap (already done in the May 3 update).
2. When picking up B.7 again, sequence Phase 5 (legacy primitive
   migration: `go_cancellable` semantic decision + `go_scope_timeout`
   thin-wrapper) before Phase 4e.8 — Phase 5 is a smaller commitment
   and unblocks deletion of the old `_current_scope_*` ambient state
   in std/concurrency.qz.
3. Then Phase 4e.8 active-wake. Then Phase 6 (docs).

## Calibration notes

The five-iteration chunked-poll recipe held at ~0.3 quartz-day per
primitive. The one-iteration active-wake retrofit is sized at ~1.5-2
quartz-days. The amortization is favorable: one 1.5-day commit replaces
the ~1.5 days that would have been spent shipping 4e.6 + 4e.7 as
standalone busy-poll variants AND retrofitting 4e.1-5 to active-wake
later anyway. Net savings ~1 quartz-day, and the resulting code is
~250 lines smaller.

The handoff that orchestrated Phases 4e.3-5 explicitly recommended
this sequencing: "If you find yourself with extra capacity, file a
docs/design/ memo about the shape mismatch instead of forcing the
recipe."

---

Filed at end of B.7 Phase 4e.3-5 overnight session, 2026-05-03.
Next session: B.7 Phase 5 → Phase 4e.8 → Phase 6.
