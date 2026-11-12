---
title: Concurrent `go` tasks contending for `mutex_lock` hang under M:N scheduler
severity: Medium (load-bearing concurrency primitive pair, pre-existing)
surfaced: 2026-04-22 (P3.G-followup migration exposed it)
status: FIXED 2026-04-22 — root cause was wrong success-check in async
        mutex_lock lowering (compared returned value to 1 instead of
        success sentinel). Semaphore rate-limiting test remains open
        as a separate `recv`-in-worker scheduler starvation issue.
---

# Resolution (2026-04-22)

Root cause: `mir_emit_expr_handlers.qz`'s async-context `mutex_lock`
lowering (the `try_lock` + `async_suspend_point` loop) compared
`mutex_try_lock(m) == 1` as the "lock acquired" predicate. But
`mutex_try_lock` returns the mutex's STORED VALUE (offset 64) on
success, or `-1` on contention — not a boolean. The check was correct
only when the mutex happened to hold the value 1; for any other
value (including the 0 the test initializes with) it looped forever
yielding instead of completing the lock acquisition. Starved
workers then had nothing to schedule, main's `sched_shutdown` hung
waiting for `active_tasks == 0`.

Fix: `mir_emit_expr_handlers.qz:2629`:
- Predicate changed from `OP_EQ, const 1` to `OP_NE, const -1`
- Return value changed from `const 0` to the actual loaded mutex value
  (a new dynamic local stashes the try-lock result across the suspend)

Verified fixes:
- `concurrency_spec` (57/57 green; "protects concurrent increments"
  was the previously-failing test)
- `send_sync_spec` (14/14 green; "Mutex is Send — shared across
  threads" was the previously-failing test)
- 50-run standalone repro: 50/50 pass (pre-fix: 5/5 hang)
- Regression sweep (scheduler_spec, task_group_spec, spawn_await_spec,
  sync_primitives_spec, async_combinators_spec, async_io_spec, effect
  specs): all green

Known remaining issue — `semaphore_spec`'s "rate limits concurrent
tasks to permit count" test still hangs. That is a DIFFERENT bug:
`semaphore_acquire` (std/sync.qz) calls `recv(channel)` which, because
`semaphore_acquire` is not itself async, goes through the sync
blocking-recv path (pthread_mutex_lock + cond_wait). Six `go` tasks
calling `semaphore_acquire` in parallel starve 4 workers the same way
the old buggy mutex_lock did. Scope of fix is larger — either make std
sync primitives effect-aware (propagate `can Async`) or add a
runtime-level "am I on a scheduler worker" check to the blocking recv
codegen. Filed separately below.

---

# Symptom

```be
def incrementer(mx: Int): Int
  var idx = 0
  while idx < 100
    val = mutex_lock(mx)
    mutex_unlock(mx, val + 1)
    idx += 1
  end
  return 0
end
def main(): Int
  mx = mutex_new(0)
  h1 = go incrementer(mx)
  h2 = go incrementer(mx)
  h3 = go incrementer(mx)
  await h1
  await h2
  await h3
  final = mutex_lock(mx)
  mutex_unlock(mx, final)
  return (final == 300 ? 0 : 1)
end
```

Runs at ~585% CPU indefinitely. Killed at 30s timeout. Forward progress
never completes; `final != 300` if we could observe it.

Reproduces on:
- Post-P3.G-followup binary (2250 fns)
- Pre-P3.G-followup golden (2256 fns — `quartz-pre-p3g-followup-golden`)

Does NOT reproduce when the source uses pthread-backed `spawn` (now
deleted by P3.G-followup): `spawn incrementer(mx)` + `await h1/2/3`
completes normally with `final == 300`.

# Failing specs (surfaced Apr 22 2026 by migration)

- `spec/qspec/concurrency_spec.qz` — `"protects concurrent increments"`
  (subprocess-compiled `cs_mutex_concurrent_src`)
- `spec/qspec/send_sync_spec.qz` — `"Mutex is Send — shared across threads"`
- `spec/qspec/semaphore_spec.qz` — `"rate limits concurrent tasks to permit count"`
  (6 go-tasks contending for `semaphore_acquire` with 2 permits; same root cause
  — semaphore_acquire ultimately parks/blocks in a way that starves the scheduler
  coordination loop. The 3-test `test_sem_rate_limiting` path hangs at ~30s timeout;
  other 4 semaphore tests run sequentially and pass.)

Both tests previously exercised the pthread-backed `spawn` path. After
P3.G-followup (spawn keyword deleted, all routes go through the M:N
scheduler via `go`), they hang.

# Why this is pre-existing, not a P3.G-followup regression

The two failing tests are the ONLY concurrency regressions post-migration.
Every other scheduler/async/effect spec (~17 tested: spawn_await, p3d, p3a,
scheduler, async_combinators, recv_timeout, oneshot_channel, sync_primitives,
task_group, await_nonasync, concurrency_advanced, concurrency_stress,
cancel_token, multi_level_capture, async_spill_regression, fn_type_registry,
concurrency base tests) passes on the post-migration binary.

Pre-migration golden reproduces the same hang when the source is hand-rewritten
to use `go` instead of `spawn`. So the hang lives in the scheduler's
interaction with blocking-pthread-mutex primitives, not in the P3.G-followup
deletion work.

# Hypothesis

`mutex_lock` codegen emits `pthread_mutex_lock(mx)` directly
(`self-hosted/backend/cg_intrinsic_conc_sched.qz:53`). Under `spawn`,
each OS thread blocks independently and forward progress is natural. Under
`go`, three scheduler workers can be simultaneously blocked on the same
pthread mutex, starving the poller/pusher or creating a dependency cycle
with `completion_await` in main's await path.

Candidate root causes:
1. Worker-blocking-mutex starves async poller, and main's `completion_await`
   never gets signaled.
2. Fairness/livelock in pthread_mutex + scheduler spin → 100% CPU.
3. Possible interaction between scheduler's sched_yield / worker-steal and
   pthread_mutex ownership.

# Not fixed in P3.G-followup

Scope of P3.G-followup was: migrate `spawn`/outside-$poll await through
Piezo + delete MIR_SPAWN/MIR_AWAIT opcodes. The deletion is complete; the
pre-existing scheduler/mutex interaction is orthogonal and needs a
separate scheduler-level fix.

# Workaround

Use the scheduler-aware `async_mutex_lock` / `async_mutex_unlock`
intrinsics (already exist, see `cg_intrinsic_conc_sync.qz`) for go-spawned
tasks. Sync `mutex_lock` remains correct for `spawn`-style pthread work
when that pattern returns (it was deleted in P3.G-followup — task code
should prefer the async variant).

# Next steps

- Confirm worker count on hang (1 or N?).
- Inspect completion_await signaling during the hang.
- Probably need: `mutex_lock` on scheduler workers should yield to scheduler
  on contention (cooperative park-wake) instead of pthread_mutex_lock
  blocking the whole worker.

Filed as roadmap follow-up (Tier 3 scheduler refinement) and tracker entry
(memory).
