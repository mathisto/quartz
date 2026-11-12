---
title: `recv` on a pthread-blocking channel path starves scheduler under `go`
severity: Medium (affects std/sync primitives called from goroutines)
surfaced: 2026-04-22 (separated from GO_SCHED_BLOCKING_MUTEX_HANG after
          fixing the `mutex_lock` half)
status: ✅ RESOLVED 2026-04-30 — Cause B closed at the recv-rewrite layer
        (not the sync-send layer the original analysis suggested).
        `semaphore_spec` rate_limiting now passes 5/5; lock-in regression
        spec at `spec/qspec/nested_poll_recv_park_spec.qz`.
---

# Update 2026-04-30 — full fix landed (Cause B at the right layer)

The original Cause B diagnosis was off by one layer. Sync `send` already
**did** wake parked recv frames (see `cg_intrinsic_conc_channel.qz`'s
`snd_wake_*` blocks dequeueing `recv_q` and calling `__qz_sched_wake`).
The actual bug was in the **recv-async-rewrite at `mir_lower_expr_handlers.qz:2641`**:
when a user-level helper (e.g. `def my_acquire(ch) = recv(ch)` or
`std/sync::semaphore_acquire`) is called from a goroutine, PASS 0.99b
auto-promotes it to a `$poll`. Inside that nested `$poll`, the rewrite
parks `self` (= the inner my_acquire frame) — but the scheduler tracks
tasks by the **top-level** frame the worker last set
`@__qz_current_frame` to. Waking the inner frame would re-poll
my_acquire$poll standalone (treating it as if it were the task), never
resuming the outer task$poll that called it, so the receiver hung
forever despite send firing the wake correctly.

Fix: replace `mir_emit_load_var("self")` with `mir_emit_intrinsic("task_self", ...)`
(loads `@__qz_current_frame`) in the recv WAIT block. For the simple
case (no nesting — `task` calls `recv` directly), `self == @__qz_current_frame`,
so the read is unchanged. For the nested case, it now correctly parks
the top-level task.

`send` and `mutex_lock` async-rewrites use `mir_emit_async_suspend_point`
(busy-yield, not parking) — no fix needed for those.

8-spec concurrency regression sweep green: concurrency_spec 57/57 +
scheduler_spec 4/4 + sync_primitives_spec 9/9 + spawn_await_spec 3/3 +
await_nonasync_spec 6/6 + colorblind_async_spec 13/13 + async_channel_spec 6/6 +
channel_handoff_spec 7/7 = 105/105. Plus semaphore_spec 5/5 (was blocked
on rate_limiting). Plus new `nested_poll_recv_park_spec.qz` 3/3
(user-wrapper 3-tasks/1-permit/1-worker, user-wrapper 6-tasks/2-permits/4-workers,
std/sync 6-tasks/2-permits/4-workers + sched_yield max≤2 enforcement).
Fixpoint 2425 (function-count-neutral). Smokes (style_demo + brainfuck +
expr_eval) green.

# Update 2026-04-22 — partial fix landed (colorless dispatch ordering)

Investigation this session revealed the hang has TWO independent causes:

## Cause A (FIXED this session)

`$poll` bodies for `go` targets were generated in PASS 1.2a **before**
PASS 1.3 auto-registered user helper functions (like `semaphore_acquire`)
as async targets. The colorless-dispatch check inside PASS 1.2a's $poll
generation (`mir_lower_expr_handlers.qz:2752`) then saw the helper as a
plain sync function and emitted a direct `call @helper`, not a
`call @__Future_helper$new`/`$poll` pair. Result: when the go-target
entered the sync helper, its worker parked in `pthread_cond_wait`
(for blocking `recv`) or spin-yielded via `usleep(1)`
(for a user-written `try_recv + sched_yield` loop), never returning to
the scheduler to run other tasks.

Fix: added **PASS 0.99b** (AST-level suspend-effect fixpoint) to
`mir_lower.qz` + three helpers in `mir_lower_async_registry.qz`
(`mir_is_suspend_leaf_name`, `mir_strip_module_prefix`,
`mir_ast_collect_callees`, `mir_propagate_suspend_ast`). Walks every
user function's body AST once, seeds from known suspend leaves
(`sched_yield`, `recv`, `io_suspend`, `io_suspend_timeout`,
`sched_sleep`, `sched_park`, `proc_suspend`), fixpoint-propagates
through the AST-level call graph, then auto-registers every transitively
suspendable user function as an async target (and seeds
`_effect_leaves` with EFFECT_SUSPEND=2 so the colorless-dispatch's
`mir_has_effect` check also succeeds).

Also added `__lambda_` / `__closure_` exclusions to the PASS 1.3
auto-registration — lambdas can't become $poll state machines because
their `__env` param layout is incompatible with the `self`-frame
contract. Without this, the broader suspend propagation caused by
PASS 0.99b unblocked a latent bug where lambda-called suspend helpers
tried to make the lambda itself async.

Impact: **user-written `try_recv + sched_yield` helpers inside a
function now correctly become $poll state machines** when called from
a go target. Proof: minimal reproducer (`/tmp/sr8.qz`, a local
`local_sem_acquire` wrapper used by 6 goroutines contending a 2-permit
channel) hangs on pre-fix, passes cleanly on post-fix.

## Cause B (REMAINING)

`std/sync::semaphore_acquire` uses `recv(sem)`, which (inside a $poll
body, courtesy of Cause A being fixed) now lowers to
`try_recv + channel_park_recv + async_suspend_point` — the task parks
itself on the channel and sets `__qz_sched_park_pending` so the scheduler
won't re-enqueue it. It waits for a corresponding `send` to call
`__qz_sched_reenqueue` to wake it up.

**But `semaphore_release` calls sync `send`**, because `send` is
registered only with `EFFECT_IO` in `mir_init_effect_leaves`, not
`EFFECT_SUSPEND`. So `semaphore_release` is NOT a $poll function and
its `send` call uses the blocking sync emitter at
`cg_intrinsic_conc_channel.qz:237`. That emitter does `pthread_mutex_lock`
+ writes buffer + `pthread_cond_signal` on the internal condvar — it
does **not** call `__qz_sched_reenqueue` and does **not** wake async
parkers. Result: the parked receiver in `semaphore_acquire` never wakes.

The minimal reproducer `/tmp/sem_rl4.qz` (2 tasks, 1 permit, 2 workers,
using `std/sync`'s `semaphore_acquire`/`release`) still hangs after
Task 0 completes — Task 1 is parked on `channel_park_recv` forever.

Options for closing Cause B:
1. **Make sync `send` also wake async parkers.** Add the `ioslot` atomic
   xchg + `__qz_sched_reenqueue` calls (same pattern as the sync close
   path at `cg_intrinsic_conc_channel.qz:2240-2260`) to the sync
   `send` intrinsic's post-buffer-write block. Localized, no API change.
2. **Mark `send` as EFFECT_SUSPEND** so `semaphore_release` becomes
   async and uses the existing async-aware `send` rewrite. Broader
   scope — adds extra $poll bodies for every function calling `send`.
3. **Propagate `can Async` through `std/sync`** (the memo's original
   option 2). Principled long-term per Piezo Phase 3 but touches every
   caller's public API.

Recommended: Option 1 as a follow-up to Cause A. Cause B is orthogonal
to Cause A — both must be fixed for `semaphore_spec` rate_limiting to
pass. Filed as **Cause B remaining work**; not blocking other tests.

---

# Original filing (obsolete — kept for history)

# Symptom

`spec/qspec/semaphore_spec.qz`'s "rate limits concurrent tasks to permit
count" test hangs. Failing core pattern:

```be
def sem_rate_limited_task(sem: Int): Int
  semaphore_acquire(sem)   # <-- blocks on cond_var in recv
  ...
  semaphore_release(sem)
  return 0
end

def main(): Int
  var sem = semaphore_new(2)   # 2 permits, 6 contending tasks
  sched_init(4)
  # spawn 6, await all, shutdown
  ...
end
```

# Root cause

`std/sync.qz::semaphore_acquire` is a sync (non-async) function that
calls `recv(sem)`. In the MIR lowering, the async-context rewrite of
`recv` (`mir_lower_expr_handlers.qz:2497`) only fires when
`mir_gen_is_active() >= 2` — which checks whether the ENCLOSING function
being lowered is async, not whether the eventual runtime caller is a
goroutine. Since `semaphore_acquire` itself is a regular function,
`recv` falls through to the blocking intrinsic implementation
(`cg_intrinsic_conc_channel.qz:879`), which locks a pthread mutex and
`pthread_cond_wait`s on it.

When 4 workers each pick up a goroutine that calls `semaphore_acquire`
on a 2-permit semaphore, 2 block on the cond_var and 2 proceed. If the
2 that proceed yield (via `sched_yield()`), they reenqueue — but there
are no free workers to pick them back up because 2 workers are stuck
in `pthread_cond_wait`. Classic starvation.

Same class of bug as the now-fixed `mutex_lock`-in-goroutine (see
`done/GO_SCHED_BLOCKING_MUTEX_HANG.md`) but the fix is not as localized.
The mutex fix was a one-line predicate correction in an existing
try-lock-loop emitter; the recv version would require either:

1. **Inline the blocking call into the async caller's $poll.** Pros:
   minimally invasive. Cons: requires the caller's $poll to know how
   to state-machine-ize the callee — impractical for std library
   primitives.

2. **Propagate `can Async` through std/sync.** Mark
   `semaphore_acquire` / `semaphore_release` / `mutex_lock` (sync
   variant) / etc. as performing the `Async` effect. Callers have to
   add `can Async` to their own signature, which propagates up through
   goroutine bodies, making their $poll state-machines understand
   suspension at these points.
   Pros: principled, solves the whole class. Cons: touches every caller
   of std/sync primitives, changes public API surface.

3. **Runtime check in the blocking recv emitter.** Read
   `@__qz_current_worker_id`; if `>= 0` (on a worker), take the
   `try_recv` + `sched_yield` loop instead of
   `pthread_cond_wait`. Pros: localized, no API change. Cons: busy
   yield is less efficient than proper parking; doesn't compose with
   the generator-state-machine park/wake mechanism, so the task
   effectively spins.

4. **Convert std/sync to use the existing async-aware intrinsics.**
   `semaphore_acquire` could be rewritten to inline the try-loop
   pattern that the async `recv` emitter produces — but this only
   works if the caller happens to be in $poll context.

Recommended: option 2 long-term (aligns with Piezo), option 3 as a
short-term mitigation. Either is multi-session work and out of scope
for the single-session bugfix chain that closed the mutex hang.

# Workaround

Avoid `semaphore_*` from `go` tasks. If you need rate-limiting, use an
explicit async channel-based pattern inside the goroutine.

# Related

- `done/GO_SCHED_BLOCKING_MUTEX_HANG.md` — the sibling bug, fixed
  2026-04-22.
- Note: `sync_primitives_spec` (9/9 green) doesn't hit this because
  its tests don't contend a blocking primitive across multiple
  goroutines — they test the primitives' single-thread invariants.
