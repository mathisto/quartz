# Phase 4e.8 — Active-wake retrofit: design

**Status:** filed 2026-05-03 at session start. Captures the audit-and-design
phase that precedes implementation. Supersedes the rough sketch in
[`SCOPE_PHASE_4E_AWAIT_IO_DEFERRED.md`](SCOPE_PHASE_4E_AWAIT_IO_DEFERRED.md).

## What the prior memo got right

The Phase 4e.6/4e.7 deferral memo correctly identified that:

- The chunked-poll-first recipe doesn't fit `await fut` / `io_suspend`.
- A unified register-park-unregister shape would amortize infra cost
  across all blocking primitives.
- `sched_wake(frame)` already exists and is race-safe (CAS protocol
  on `frame[5]` park_state with WAKE_PENDING handling).

## What the prior memo got wrong

The recipe shape it proposed —

```
def scope_<primitive>(...):
  ...
  _scope_register_waiter(s, task_self())
  r = blocking_<primitive>(...)
  _scope_unregister_waiter(s, task_self())
  scope_check(s)
```

— assumes `blocking_<primitive>(...)` is a goroutine-aware suspend
that can be woken by `sched_wake`. **Most are not.**

- `mutex_lock(m)` lowers to a direct `pthread_mutex_lock` call — it
  blocks the *worker thread*, not the goroutine. The scheduler can't
  wake it because the worker is parked in the kernel.
- `rwlock_read` / `rwlock_write` — same.
- `sched_sleep(ms)` — registers a one-shot kqueue/epoll timer and
  parks the task via the io_suspend path. **Empirically verified
  2026-05-03**: a task in `sched_sleep(2000)` woken via `sched_wake`
  at 100ms still slept the full 2006ms. The io_suspend path doesn't
  set `frame[5]=PARKED`, so `sched_wake`'s CAS lands `WAKE_PENDING(2)`
  but nothing comes back to `task_yield` to consume it.
- `try_send`, `try_recv_or_closed`, `mutex_try_lock`, `rwlock_try_read`,
  `rwlock_try_write` — non-blocking; they return immediately. The
  current chunked-poll loops use these between `sched_sleep(chunk)`
  intervals.

The async parking-lot variants (`async_mutex_lock`, `async_rwlock_read`,
`async_rwlock_write`, `channel_park_recv`) DO suspend the goroutine
correctly via `sched_park()` and are wake-able by `sched_wake`. But
the existing scope helpers don't use them — they use the synchronous
`mutex_lock` / etc. via try-and-poll.

## The right mechanism

Two layers of work, and they decompose cleanly:

### Layer A — make `sched_sleep` interruptible by `sched_wake`

Today `sched_sleep(ms)` → `io_set_pending_sleep` + suspend via
`__qz_sched_register_timer`. The timer registers in kqueue (macOS)
or via timerfd+epoll (Linux); when it fires the I/O poller re-enqueues
the task. The park_state machinery is not involved.

To make `sched_wake` interrupt:

1. **Track the pending timer per task.** New side table
   `__qz_task_timers` (mirrors the `__qz_task_scopes` shape: flat
   pairs of `(frame_ptr, timer_ident_or_fd)` under a mutex). Populated
   by `__qz_sched_register_timer` after the kqueue/epoll registration
   succeeds. Capacity-1 per task is sufficient: a task can only be in
   one `sched_sleep` at a time.

2. **Cancel the timer in `sched_wake`'s wake path.** Extend
   `__qz_sched_wake(task)` to:
   - Look up `__qz_task_timers[task]` under the side-table mutex.
   - If found: clear the side-table entry, clear `__qz_io_map[ident]`
     (so the eventual timer fire doesn't double-enqueue), call
     `kevent(EV_DELETE)` (macOS) or `epoll_ctl(EPOLL_CTL_DEL)` +
     `close(timerfd)` (Linux) to remove the kernel-side registration.
   - Then proceed with the existing CAS wake protocol (which now
     includes a dispatch path for "task was sleeping" → re-enqueue
     immediately, no CAS needed since the io_map clear already
     guarantees the timer-fire path is a no-op).

3. **Worker path doesn't need changes.** When the woken task is
   re-enqueued and runs its $poll, it resumes from the suspend point
   inserted by the `sched_sleep` MIR lowering. From the task's
   perspective, the sleep returned early — no semantic difference
   from the timer firing.

### Layer B — scope waiter list + cancel-walk wake

Built on Layer A:

1. **Each Scope node grows a waiter list.** Resize the node from
   `mem_alloc(64)` (8 i64 slots) to `mem_alloc(72)` (9 slots).
   Slot 8 holds an intrusive Vec<Int> of waiting task frames,
   lazily allocated (0 == empty).

2. **Register / unregister helpers** in `std/sync/scope.qz`:
   - `_scope_register_waiter(s, frame)`: under the tree mutex,
     create the vec if needed, append frame.
   - `_scope_unregister_waiter(s, frame)`: under the tree mutex,
     find and remove. O(n) where n is small (~1-2 typical).

3. **Cancel walker invokes `sched_wake`.** Extend
   `_scope_cancel_descendants_locked` to also walk each cancelled
   scope's waiter list and call `sched_wake(frame)` for each.
   Already running under the tree mutex.

4. **Update the 6 scope_X helpers** to register/unregister around
   their existing chunked-poll loops:

   ```
   def scope_lock(m: Int): Int
     var s = current_scope()
     if s == scope_root() return mutex_lock(m) end
     scope_check(s)
     _scope_register_waiter(s, task_self())
     while true
       var r = mutex_try_lock(m)
       if r != -1
         _scope_unregister_waiter(s, task_self())
         return r
       end
       <chunk math>
       sched_sleep(chunk)
       scope_check(s)
     end
   end
   ```

   The chunk-size math stays the same (50ms cap, deadline-clamped).
   What changes: `scope_check(s)` after the wake observes cancel
   immediately (because `sched_wake` cut the sleep short). Cancel
   observation drops from ~50ms → ~0ms (limited only by
   `sched_wake` → kqueue cancel → re-enqueue → worker pick-up →
   $poll resume, all microsecond-scale).

   Note: `scope_check` runs INSIDE the wait-list registration. If
   it throws, the throw propagates through `with Throws { throw: ... }`
   handlers above. We need to ensure unregistration happens on the
   throw path. Two options:
   - (a) Wrap the loop body in `with Throws { throw: <unreg-then-rethrow> }`
   - (b) Move the throw OUT of the loop: have `scope_check` return a
     bool, unregister explicitly, then throw.
   
   Going with (b) — simpler and avoids effect-handler nesting in
   stdlib hot paths. New helper `scope_is_cancelled_now(s)` that's
   the same as `scope_is_cancelled` but doesn't throw.

5. **Throws-safety** for the unregistration. If `mutex_try_lock` or
   any other intrinsic throws (it shouldn't, but defense in depth),
   we'd leak a waiter entry. Since these are stdlib primitives that
   don't throw, treat as a non-issue. Document the assumption.

## Race surface

### Race 1: cancel during register

Sequence:
1. Task A calls `scope_lock(m)`.
2. Sibling thread calls `scope_cancel(s)`.
3. The cancel walker takes the tree mutex, walks descendants, finds
   no waiters yet (task A hasn't called register yet), exits.
4. Task A's `_scope_register_waiter` takes the tree mutex, appends
   itself.
5. Task A's `scope_check(s)` observes the cancel flag, throws.

Outcome: cancel observed immediately on first scope_check, no wake
needed. Safe.

### Race 2: cancel between register and sched_sleep

Sequence:
1. Task A registers waiter, releases tree mutex.
2. Cancel walker fires, takes tree mutex, sees task A in waiters,
   calls `sched_wake(task_A)`. Task A's frame[5] is RUNNING; CAS
   sets WAKE_PENDING(2).
3. Task A calls `mutex_try_lock` → -1.
4. Task A calls `sched_sleep(chunk)` → wraps into io_suspend.
5. The io_suspend path does NOT check WAKE_PENDING (the existing
   `task_yield`-only check). The task parks in kqueue.
6. The kqueue timer fires after `chunk`ms, task wakes, `scope_check`
   observes cancel → throws.

Outcome: cancel observed within `chunk`ms instead of immediately.
**This is a lost-wake.** To fix: extend the io_suspend path to also
check WAKE_PENDING before parking, mirroring `task_yield`'s logic.
Same shape: load `frame[5]`, if 2 then re-enqueue immediately
instead of parking.

### Race 3: wake during sleep

Sequence:
1. Task A is in `sched_sleep(50)` waiting for kqueue timer.
2. Cancel walker calls `sched_wake(task_A)`.
3. `sched_wake` looks up `__qz_task_timers[A]`, finds timer ident.
4. Clears side-table entry, clears io_map slot, kevent EV_DELETE.
5. Re-enqueues task A.
6. Task A wakes, `scope_check` throws.

Outcome: cancel observed in microseconds. The kqueue cancel may
race with the timer firing — if the timer already fired and
re-enqueued the task, `__qz_task_timers[A]` is already 0 (cleared
by the timer-fire path), so `sched_wake` finds nothing to cancel
and falls through to the existing CAS protocol. No double-enqueue.

### Race 4: timer fires between sched_wake's clear and EV_DELETE

Sequence:
1. `sched_wake` reads `__qz_task_timers[A]` = ident T.
2. Timer T fires in kqueue between this read and the EV_DELETE call.
3. Poller picks up the event, looks up io_map[T], gets task A,
   re-enqueues task A.
4. `sched_wake` proceeds with EV_DELETE (no-op since one-shot timer
   already auto-removed) and re-enqueues task A again. Double-enqueue.

Mitigation: have `sched_wake` perform the io_map clear FIRST (atomic
swap to 0 returning the old value); only proceed if it observed the
old value as the task. If it observed 0, the timer-fire path already
processed the task — no need to re-enqueue.

```
sched_wake(task):
  ident = __qz_task_timers[task]
  if ident != 0:
    old = atomic_swap(io_map[ident], 0)
    if old == task:
      kevent(EV_DELETE, ident)  # may be no-op if already auto-removed
      __qz_task_timers[task] = 0
      <re-enqueue task>
      return
  <fall through to existing CAS protocol>
```

The atomic_swap on io_map[ident] is the synchronization point.
Whoever wins (sched_wake vs poller) is responsible for re-enqueueing.

## Sizing

| Layer | Effort |
|---|---|
| A — sched_wake interrupts sched_sleep (compiler) | ~1 quartz-day |
| B — scope waiter list + cancel-walk wake (stdlib) | ~0.3 quartz-day |
| Spec coverage (latency-bound assertions across 6 primitives) | ~0.3 quartz-day |
| **Total** | **~1.5-1.7 quartz-day** |

Matches the SCOPE_PHASE_4E_AWAIT_IO_DEFERRED memo's 1.5-2 day estimate.

## Implementation order (as shipped)

1. **Layer A** — the scheduler integration. ~250 lines of LLVM IR in
   codegen_runtime.qz: side-table decl + init in sched_init, three
   helpers (`__qz_task_timer_set`/`_take`), `__qz_task_timer_set` call
   in `__qz_sched_register_timer` (both macOS + Linux paths), expanded
   `__qz_sched_wake` with timer-claim path (atomic xchg io_map +
   kevent EV_DELETE / epoll DEL+close), atomic xchg in poller's
   ev_lookup + `__qz_task_timer_take` after re-enqueue.
2. **Layer B** — the scope waiter list (~100 lines stdlib in
   `std/sync/scope.qz`): node grew from 8 → 9 i64 slots
   (`SLOT_WAITERS = 8`), `_scope_register_waiter` /
   `_scope_unregister_waiter` (intrusive Vec<Int> on the scope node,
   tree-mutex serialized), `_scope_wake_waiters_locked` walks and
   calls `sched_wake`, integrated into `_scope_fire_cancel` (originator)
   and `_scope_cancel_descendants_locked` (descendants). All 6
   `scope_X` helpers wrap their chunked-poll loops with
   register/unregister + post-loop scope_check.
3. **Smoke tests** in `spec/qz/`:
   - `sched_wake_interrupts_sleep_smoke.qz` — Layer A in isolation
     (parker sched_sleep(2000), waker sched_wake at 100ms; asserts
     wake at <200ms). Pre-fix would fail at 2006ms.
   - `scope_active_wake_smoke.qz` — combined Layer A+B end-to-end
     (worker in scope_sleep_ms(5000) under a goroutine, main fires
     scope_cancel at +50ms; asserts cancel→throw latency <30ms).
     Observed 0ms in CI; pre-Phase-4e.8 would have been ~50ms.
4. **Regression** — all 8 existing scope specs (substrate 18/18,
   with 8/8, inheritance 6/6, deadline_timer 6/6, sleep 7/7,
   channel 9/9, mutex 4/4, rwlock_read 4/4, rwlock_write 4/4) green
   under the new chunked-poll-plus-active-wake helpers.

## Spec authoring caveat

Active-wake validation could not be expressed in the qspec
`describe`/`it` lambda format because `go fn()` inside an async lambda
context lowers to `Future_X$new + $poll` polled inline (not a real
goroutine spawn on a worker thread). The worker-blocks-then-cancel
pattern requires the worker to actually run on a separate thread so
main can issue scope_cancel from outside the worker's blocking call.
Standalone `def main()`-driven smoke tests in `spec/qz/` work because
they exercise `go` from a non-async-lambda context. Filed for
follow-up: investigate making `go fn()` inside async lambdas spawn
real tasks (or document the limitation in the language reference).

## Non-goals

- **Don't replace chunked-poll with single-park-and-wake.** The
  underlying primitives (mutex_try_lock etc.) don't have a
  notification path for "primitive became available" — only
  polling tells us. Active-wake covers the cancel side; polling
  still covers the completion side.
- **Don't migrate to async_mutex_lock / async_rwlock / channel_park_recv
  in scope helpers.** Those parking-lot patterns work but adopting
  them would require modifying every blocking primitive's wait-node
  layout to ALSO be cancel-walker-aware. Too much churn for too
  little benefit; the chunk-poll + active-wake gives the same
  user-visible latency at a fraction of the implementation cost.
- **Don't address Phase 4e.6 (await fut) / 4e.7 (io_suspend).**
  Their semantics are fundamentally different from blocking
  primitives — `await` is a future-completion wait (wake comes from
  the future's resolution, not from a primitive); `io_suspend` is
  fd-readiness park (wake comes from kqueue fd event). Both could
  use the waiter list infrastructure, but the integration is
  separate (and `await`'s scope cancel needs to interact with the
  future's completion machinery — out of scope for Phase 4e.8).

---

Filed at start of B.7 Phase 4e.8 implementation, 2026-05-03.
