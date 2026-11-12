## Scheduler — concurrent-pipe I/O flake (pre-dates Phase 3)

### Status: FIXED 2026-04-22

Root cause was **not** in the scheduler or kqueue registration at all — it was
in the effect-runtime's `@__qz_effect_current_cont_frame` TLS slot. Nested
kind=3 `perform` calls (e.g. the busy-poll handler for `await r1` polling
`r1$poll` which itself performs `suspend`) clobbered the outer frame's
continuation pointer. When the outer handler eventually called `resume_cont`,
it re-entered the WRONG frame (the inner task, which was already done) instead
of the outer awaiting frame. The outer frame's state never transitioned to -1,
so the worker saw it as I/O-parked (`state=1`, `poll_result=-(fd+2)`), routed
through `task_io_real` → `register_io`, and the task's ultimate completion
depended on kqueue re-firing against a pipe whose byte had no consumer — racy
under scheduler contention.

Fix: save/restore `current_cont_frame` lexically around each kind=3 perform
site (`mir_emit_kind3_perform_suspend` in `self-hosted/backend/mir_lower_gen.qz`).
Also hardened `@__qz_effect_stack_bufs/results/resumed` to thread-local storage
to eliminate a secondary cross-worker race on those arrays (semantically
correct already since all reads/writes are same-thread under the single-prelude
install pattern).

Verification 2026-04-22:
- Standalone 3-pipe/4-worker repro: 200/200 pass (pre-fix: 7/100 flake).
- `spec/qspec/async_io_spec.qz`: 6/6 tests green on first run (pre-fix: ~15%
  flake per test; 30% whole-file flake).
- Regression sweep (piezo_async_await_migration_p3c, effect_integration,
  effect_handler_narrow, spawn_await, async_combinators, recv_timeout,
  oneshot_channel, scheduler, task_group, await_nonasync): 60+ tests all
  green, no regressions.
- Flake reproduces on pre-fix `quartz-pre-piezo-tls-fix-golden`, does not
  reproduce on post-fix binary.

Separately: the Piezo epic's P3.0 design memo explicitly flagged
"single-level nesting is in-scope for P3.0c-perform; multi-level is P3
followup" (runtime's resume_cont comment). This was the followup.

---

**Pre-existing.** Originally filed under suspicion of P3.E-runtime regression;
100-run bisection shows the flake rate is **the same on the pre-P3.E-runtime
legacy `mir_emit_async_suspend_point` path as on the current kind=3 perform
path**, so the root cause is in the scheduler runtime (`task_io_real`,
`__qz_sched_register_io`, or kqueue/epoll dispatch) — NOT in anything Piezo
added. (The 100-run bisection was misleading: the flake reproduced on both
code paths because *both* used kind=3 perform after P3.E-runtime and thus
shared the cont_frame clobber. Filed under "scheduler" initially by process
of elimination; diagnosis in 2026-04-22 session correctly identified it as
an effect-runtime issue.)

Keeping the file for trackability but renamed in spirit. Cross-referenced from
the Phase 3 tracker so P3.H scheduler perf benching knows to fix this (or
accept the noise) before the 10% kill-criterion gate kicks in.

### Measured flake rates (2026-04-21, 100 runs each, 5s timeout)

| Compiler | Flake rate (timeouts / 100) |
|---|---|
| Pre-P3.E-runtime (commit `9852cf7d`), flag OFF (legacy path) | **17 / 100** |
| Post-P3.G (current, kind=3 perform is only path) | **14 / 100** |

Within noise of each other. The flake does NOT correlate with Piezo changes.

Earlier 20-run sample showed 5/20 on `pre-P3.E-runtime + flag ON` (25%) and
1/20 on other configs — not statistically meaningful; the 100-run numbers
are the authoritative picture.

### Symptom

`spec/qspec/async_io_spec.qz` — two tests:

- `concurrent async I/O tasks multiplex on scheduler` (3 pipes, 4 workers)
- `pipe-based async echo via scheduler` (1 pipe + read)

Subprocess binary times out (SIGKILL, exit 124 or 137) on ~15% of runs. The
other 4 tests in the file are green 100% of runs.

### Reproduction

See `spec/qspec/async_io_spec.qz::concurrent_io_src()` for the source. Compile
and loop:

```bash
./self-hosted/bin/quartz /tmp/concurrent_io.qz > /tmp/ci.ll
llc -filetype=obj /tmp/ci.ll -o /tmp/ci.o
clang /tmp/ci.o -o /tmp/ci -lm -lpthread
for i in $(seq 1 100); do timeout 5 /tmp/ci; echo "Run $i: $?"; done | grep 124 | wc -l
```

Expect 10-20 timeouts out of 100.

### Hypothesis (post-bisection)

The race is in the scheduler's I/O poller thread vs. worker-thread fd
registration path. `__qz_sched_register_io(fd, task)` registers the task on
the I/O poller's kqueue/epoll. If the write to a pipe happens BEFORE the
registration (tiny window between `io_suspend(fd)` returning and the poller
wake-up), the read-ready event fires before kqueue has the fd in its set,
and the event is lost. The task never wakes up → `sched_shutdown()` hits its
idle-drain timeout.

This is a classic edge-triggered-poller registration-race and is orthogonal
to the Piezo migration. Fixes in the space:

- Register the fd BEFORE the write happens (sequencing guarantee).
- Use level-triggered (epoll default) or EVFILT_READ with EV_CLEAR cleared
  (kqueue) so ready state is latched across the race.
- Poll the fd once at registration time and short-circuit wake if already
  ready.

### Files to inspect

- `self-hosted/backend/cg_intrinsic_conc_sched.qz` — `__qz_sched_register_io`
  codegen.
- Scheduler C runtime (embedded in codegen): `__qz_sched_task_io_real` and
  the worker poller loop.
- Kqueue/epoll setup in the scheduler thread spawn.

### Impact

- `spec/qspec/async_io_spec.qz` flakes on default `quake qspec` runs at
  ~15% per-test; two tests in the file means ~28% whole-file flake.
- Scheduler perf benches (`quake sched_bench`) use channel-notify-fds,
  NOT raw user-pipe fds — they don't hit this path. P3.H perf benching
  is NOT blocked.
- Other async specs that were stable in the pre-P3.G regression sweep
  (`async_channel`, `async_mutex`, etc.) don't hit this path because they
  use channel notify-fds, not raw user-pipe fds.

### Next step

Separate work from Phase 3 closure. Can be tackled independently as a
scheduler-perf pre-work chunk. Not blocking P3.F or P3.G-followup.

### Cross-reference

- `docs/bugs/ASYNC_ITER_UTF8_OUTPUT_TRUNCATION.md` — unrelated pre-existing
  flake, different spec, different cause.
