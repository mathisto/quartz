---
title: graceful_shutdown_spec intermittently SIGSEGVs (load-correlated scheduler race)
severity: Medium (intermittent; passes standalone most of the time, but a real crash under load — a scheduler/shutdown race)
surfaced: 2026-06-05 (A.44 run #4 — SIGSEGV in the parallel pool AND in 2 serial retries, but passes when run in isolation moments later)
status: ⛔ OPEN — root-cause LOCALIZED 2026-06-05 (worker null-derefs a zeroed @__qz_sched base after cleanup); fix not yet written
related: docs/bugs/HOSTED_SUPERVISED_SHUTDOWN_DRAIN_HANGS.md (adjacent — graceful-drain/shutdown machinery), docs/design/SCOPE_UNIFICATION.md
---

# Findings 2026-06-05 (A.44 — localized to a worker / cleanup lifecycle race)

Chased on the local Mac after fixing the sibling `scoped_async_yield_resume`
hang. Three concrete results that move this from "not reliably reproducible" to
"localized":

1. **Reproduces STANDALONE ~1 in 3** (the original report's "6/6 PASS standalone"
   was machine/timing luck). Build the spec at `llc -O0` (suite path) and run it
   bare in a loop:
   ```
   INC="-I std -I . -I self-hosted -I self-hosted/shared -I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend -I spec/qspec/fixtures"
   ./self-hosted/bin/quartz --no-cache $INC spec/qspec/graceful_shutdown_spec.qz > /tmp/g.ll
   llc -O0 -filetype=obj /tmp/g.ll -o /tmp/g.o && clang -g /tmp/g.o -o /tmp/g -lm -lpthread
   for i in $(seq 1 30); do /tmp/g >/dev/null 2>&1; [ $? -eq 139 ] && echo "CRASH $i"; done   # ~10/30 SIGSEGV
   ```
2. **NOT fd exhaustion.** Crashes at the default `ulimit -n` (1048576) just as
   readily as at `ulimit -n 64`. The earlier "use-after-free during drain"
   hypothesis is the right family; the fd-leak angle is ruled out.
3. **Faulting frame (lldb, EXC_BAD_ACCESS code=1 address=0x0):**
   ```
   thread 'qz-sched-N', __qz_sched_worker + 1764
   ->  ldr x8, [x8]        ; x8 == 0  → load through a NULL base
   ```
   A **worker thread** dereferences a **null base pointer**. `address=0x0` is the
   tell: `__qz_sched_shutdown`'s cleanup phase `store i64 0`s the queue (slot 1),
   mutex (slot 6), condvar (slot 7), and **wdata (slot 17)** after freeing them.
   The worker loop reloads `@__qz_sched[17]` (wdata base) every iteration for the
   anti-starvation tick + busy_ns accounting (`%tk.wd.i = load slot 17` →
   `inttoptr` → `gep`), and the global-queue dequeue reloads slot 1. A worker
   still executing after cleanup reads one of these as 0 → `ldr x8,[x8]` faults.

**Mechanism (confirmed from the IR):** `__qz_sched_shutdown_graceful(timeout)`
(codegen_runtime.qz ~10208) does **NOT join the worker threads** — it timed-waits
for `active_tasks==0`, and on timeout force-zeros `active_tasks`, sets the
shutdown flag (slot 8), broadcasts, and returns *with the workers still alive*.
The spec then calls `sched_shutdown()`, which sets the flag, `pthread_join`s the
workers, then frees+zeros the `@__qz_sched` arrays. The null-deref means a worker
is still running its loop when the zeroing happens — a **join/quiesce gap**. The
spec does this **6× back-to-back** (`sched_init(2); sched_shutdown_graceful(T);
sched_shutdown();` per test), so a worker from cycle N can survive into cycle
N+1's re-`sched_init` / the zeroed window. (Why join doesn't catch it is the open
question — candidates: a worker parked in `pthread_cond_wait` on a condvar that
gets `pthread_cond_destroy`'d, a stale worker-tid in slot 0 after re-init reuses
the global array, or graceful's force-zero of `active_tasks` letting
`sched_shutdown` proceed to free while a worker is mid-loop and not yet parked.)

**Fix direction:** the worker threads must be fully quiesced/joined before ANY
`@__qz_sched` slot is freed or zeroed. Either (a) make `sched_shutdown` prove all
workers have exited their loop (a per-worker "exited" flag the cleanup spins on,
in addition to `pthread_join`), or (b) have the worker re-check the shutdown flag
and bail BEFORE every slot-17/slot-1 reload and tolerate a zeroed base, or (c)
make graceful_shutdown + shutdown share one lifecycle so the second call can't
race a still-live worker from the first. Verify under TSan on a Linux build (per
[[feedback-mn-mutex-pthread-thread-ownership-race]] — TSan on the real x86 box
catches the data race that gdb/lldb timing perturbs away). The
`ldr x8,[x8]` + `address=0x0` + slot-17 reload is the exact spot to instrument.

---

# Summary

`spec/qspec/graceful_shutdown_spec.qz` (6 tests covering
`sched_shutdown_graceful`, `sched_shutdown_on_signal`, and the draining
flag) **intermittently crashes with SIGSEGV**. It is NOT deterministic:

* Full qspec suite run (2026-06-05): SIGSEGV in the parallel pool.
* Serial retry pass (same run, `--no-cache`, no pool contention):
  SIGSEGV on BOTH retry attempts.
* Minutes later, standalone (`quake qspec_file`, and raw `llc -O0`/`-O2`
  builds): **6/6 PASS** every time tried.

So it is a genuine race whose probability rises sharply under system
load (many concurrent processes), not a clean deterministic bug and not
pure pool contention (it did reproduce serially during the loaded run).
Unlike `scoped_async_yield_resume` (deterministic at `-O0`), this one is
opt-level-independent — it passed at both `-O0` and `-O2` when retried in
isolation.

# What the spec does

Exercises `sched_shutdown_graceful` (drain tasks up to a timeout, return
0 if all complete / 1 if a CPU-bound task exceeds the timeout),
`sched_shutdown_on_signal` (installs SIGINT/SIGTERM handlers), and a
"draining" flag that blocks new spawns after graceful shutdown begins.

# Hypothesis

A use-after-free / race in the scheduler shutdown path: a worker thread
or goroutine touches a task/scope/channel structure that the
graceful-drain path is concurrently tearing down. Candidates:

* The drain loop frees or resets task-pool state while a still-running
  worker dereferences it.
* The signal-handler install races with shutdown (a handler fires or is
  read mid-teardown).
* The "draining" flag is checked-then-acted-upon without the barrier that
  the spawn path needs, so a spawn slips in against a half-torn-down pool.

Under heavy load the scheduler's threads interleave differently and the
teardown window widens — matching "only crashes under load."

# Reproduction strategy (since it's intermittent)

Run it under artificial load and/or in a tight loop to raise the
crash probability, with a core dump / lldb attached:

```
# Loop the standalone binary many times under parallel load:
INC="-I std -I . -I self-hosted -I self-hosted/shared -I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend -I spec/qspec/fixtures"
./self-hosted/bin/quartz --no-cache $INC spec/qspec/graceful_shutdown_spec.qz > /tmp/g.ll 2>/dev/null
llc -O0 -filetype=obj /tmp/g.ll -o /tmp/g.o && clang -g /tmp/g.o -o /tmp/g -lm -lpthread
# stress: run N copies concurrently in a loop until one faults, then inspect the core
for r in $(seq 1 200); do for c in $(seq 1 16); do /tmp/g >/dev/null 2>&1 & done; wait; done
# Or run the whole suite repeatedly (it crashed there) and lldb the faulting /tmp/qspec_*_graceful_shutdown_spec
```

On macOS enable cores (`ulimit -c unlimited`, check `/cores`), then
`lldb /tmp/g -c /cores/core.<pid>` → `bt all` to find the faulting
thread and the structure it touched mid-teardown. TSan on a Linux build
(per the M:N-mutex memory) is the strongest tool here — a shutdown
use-after-free / data race is exactly what TSan reports cleanly while
gdb/strace miss it.

# Verification checklist

* The stress loop above runs thousands of iterations + concurrent copies
  with zero faults.
* `graceful_shutdown_spec` stops appearing in the suite's rotating
  failure set across ≥3 full runs.
* `quake guard` fixpoint + Rule-2 smokes.

# Scope note

Intermittent / load-correlated. The qspec serial-retry pass keeps it
FAILED when it reproduces (correct — it's a real crash), and the
"recovered on serial retry" logging makes a run where it flakes-then-
passes visible rather than silent. If it recovers most runs, treat the
recovered-log line as the signal to chase it under stress.

## Corroboration 2026-06-07 (during B.10 P3.4-ii-b): definitively NOT codegen

Reproduced standalone on a fresh compiler build (3 runs: 1 pass, 2 SIGSEGV).
Ruled out a codegen cause rigorously: compiled this spec with the current
compiler AND the pre-change golden binary and `diff`'d the IR — **byte-identical
(65029 lines, empty diff)**. The golden binary's compiled output is **equally
flaky** (4 runs: 3× exit 139, 1× exit 0). So the crash is purely a runtime /
concurrency race in the hosted graceful-shutdown path, independent of the
compiler version — byte-identical IR across two compiler builds is a stronger
proof than fixpoint (which only covers self-compile). Chase under TSan on the
real Linux box per [[feedback-mn-mutex-pthread-thread-ownership-race]].

## Corroboration 2026-06-10 (during B.15d/N3.1 sentinel→Option migration): re-confirmed pre-existing

Surfaced again as the sole non-recovered failure in a full qspec run while
migrating `mir_ctx_get_struct_fields` → `Option<Vec<Int>>` (a change that does
touch drop-traversal codegen — `type_needs_drop`/`emit_nested_drops` — so it
was a plausible suspect). Ruled out by matched 10-run standalone samples on the
same machine: **pre-N3.1 golden 6/10 SIGSEGV vs post-migration current 3/10
SIGSEGV** — the golden (pre-change) crashes at an *equal-or-higher* rate, so the
Option migration neither introduced nor worsened it. Consistent with the
byte-identical-IR proof above. Still a runtime race, still OPEN.
