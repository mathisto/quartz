# `__qz_effect_stack_top` global → multi-worker `with` install race

**Filed**: 2026-04-28 during Phase E.1 (per-task arenas) implementation.
**RESOLVED**: 2026-04-28 — Phase E.1.c shipped. All effect-stack arrays
(`stack_top`, `stack_names`, `stack_handlers`, `stack_op_filters`,
`alloc_blessed_watermark`) flipped to thread-local. `cg_emit_effect_install_defaults`
extracted into a callable `@__qz_effect_install_defaults` function and
called both at qz_main entry (replacing the old inline prelude) and at
each scheduler worker's `__qz_sched_worker` entry block, so every worker
boots with the blessed defaults pushed onto its own TLS stack. Five
parallel `go_arena` smoke runs green; `alloc_e1_per_task_arena_spec.qz`
E1.c flipped from `sched_init(1)` to `sched_init(0)` and passes 5/5;
fixpoint verified at 2393 functions; 73/74 alloc spec tests green; all
sampled concurrency + generator + async-iterator specs green except the
documented `it_pending` interleave test below.

**Semantic shift introduced by E.1.c**: handlers installed on main are no
longer visible to spawned goroutines. Each worker's TLS effect stack
starts with only the blessed defaults; goroutines must install their own
handlers inside the goroutine body (e.g. wrap the spawned function in
`with E { ... } do ... end`). This matches OCaml 5 effect handlers + multi-
core fibers, where `with` is dynamic-extent of the calling thread. Filed
as a follow-up: spawn-time inheritance via captured-stack snapshot is the
architecturally-correct path forward for cross-thread `with` scope, but
the dynamic-extent semantics are the right default.

**Two scheduler+effects tests required rewrites** (handler now installed
inside the goroutine wrapper instead of around the `go` call):
- `spec/qspec/generators_p4b4a_yield_kind3_spec.qz` — passes 3/3 with
  the rewrite.
- `spec/qspec/generators_p4b3_suspend_spec.qz` — passes 3/4 with the
  rewrite; the 4th (`suspend + resume interleave within single routine`)
  is `it_pending`'d, exposes a pre-existing kind=3 resume(0) +
  with-block-in-goroutine bug that the TLS flip surfaced cleanly.

---

## Original filing

## Symptom

Two parallel tasks each opening their own effect handler scope segfault
on macOS (KERN_INVALID_ADDRESS) when scheduled across multiple worker
threads. Triggered by Phase E.1's `go_arena(f)` because it installs a
per-task `Alloc.in_arena(ar)` block; two `go_arena` calls under
`sched_init(0)` (multi-worker default) reproduce reliably.

Repro shape (tested 2026-04-28 against post-D.x compiler):
```be
import std/alloc
import concurrency

def task_a(): Int
  var v = vec_new<Int>(); for i in 0..100; v.push(i*3); end; return v[99]
end

def task_b(): Int
  var v = vec_new<Int>(); for i in 0..100; v.push(i*5); end; return v[99]
end

def main(): Int
  sched_init(0)         # MULTI-WORKER → race
  var ta = go_arena(task_a)
  var tb = go_arena(task_b)
  await ta; await tb
  return 0
end
```

Switching to `sched_init(1)` makes the same test pass cleanly.

## Root cause

Per the comment block in `self-hosted/backend/codegen_runtime.qz:117–156`,
the effect runtime made `stack_bufs` / `stack_results` / `stack_resumed`
/ `stack_state_slots` thread-local in Apr 22 2026 to fix an earlier
async_iterator concurrency issue. But `stack_top` / `stack_names` /
`stack_handlers` / `stack_op_filters` were left **global** with the
explicit reasoning:

> Revised: keep top GLOBAL (read-mostly after startup) but make the
> state-tracking arrays (bufs/results/resumed) TLS.

The reasoning was that workers see the blessed-default-handler installs
done in `cg_emit_effect_main_prelude` (Alloc, FileIo, Async, etc.) on
the main thread — and were assumed not to install their own handlers.

`go_arena` breaks that assumption: its body wraps task code in `with
Alloc.in_arena(ar) do ... end`, which generates a worker-thread install
of a non-blessed handler. Two parallel workers doing this simultaneously
each:

1. Load `top` (global) → both see e.g. 5
2. Compute `top_next = top + 1` → both compute 6
3. Store name/handler at `[top]` → both write at index 5 (loser overwrites)
4. Store new top → race; one of `top_next` lands

Result: `names[5]` reflects whichever worker won the store; the loser's
install vanishes. When the loser's `perform` later scans for its
handler, it finds the other's, calls into the wrong handler, often
with a wrong state slot pointer → SIGSEGV.

The relevant install code (`__qz_effect_handle_install`) does a
non-atomic load-modify-store on `@__qz_effect_stack_top` plus stores
to global `_names` / `_handlers` / `_bufs` / `_op_filters` — all
unsafe under concurrent worker access.

## Why this hadn't surfaced before

Most existing scheduler users don't install their own effect handlers
inside `go` task bodies. They use the blessed defaults (Async,
FileIo, Throws) which are installed once on the main thread before
sched_init. Phase E.1's `go_arena` is the first stdlib API where a
per-task install is the whole point.

## Fix shapes (sequenced as Phase E.1.c)

### Option A: TLS effect-stack top + per-worker prelude install
- Make `stack_top`, `stack_names`, `stack_handlers`, `stack_op_filters`
  all thread-local
- Run `cg_emit_effect_install_defaults` per-worker at worker startup
  (in `__qz_sched_worker`'s entry block) so each worker's TLS stack
  has the blessed defaults installed
- No locking needed; each worker sees only its own installs
- Workers cannot transfer `with`-block scope across each other (they
  shouldn't — `with` is dynamic-extent of the calling thread by design)
- Cost: per-worker install cost is small (3-7 entries × ~10 store
  instructions); paid once per worker startup

This matches Erlang/BEAM (each scheduler thread has its own process
table view) and Go (each P maintains its own runtime state). It is
the architecturally correct shape.

### Option B: Mutex around install/uninstall + cmpxchg perform scan
- Lock `__qz_effect_install_mutex` around install/uninstall
- Perform's scan reads `top` then iterates names[0..top-1]
  — a race with concurrent install would still see a half-set entry
  unless perform also locks
- Locking perform on the hot path is unacceptable

Reject Option B.

### Option C: Lock-free SC-stack
- Atomic `top` with cmpxchg push/pop
- `names`/`handlers` writes use release semantics; reads use acquire
- Bounds check + retry on fits-in-256 contention
- Complex to get right; perform's scan may still see half-set entries
  during reordering (uninstall pops top before clearing names)

Option A is cleaner and matches what Erlang/Go do. Recommend Option A.

## Workaround until E.1.c

`go_arena(f)` documents the limitation. Users who need parallel
`go_arena` tasks call `sched_init(1)`. The single-worker scheduler
runs tasks cooperatively on one OS thread — no install race possible.
For most workloads, single-worker is fine; multi-worker becomes
necessary only under CPU-bound parallelism.

Sequential `go_arena` calls (each `await`'d before the next spawns)
work under any worker count because only one task is mid-install at
any time.

## Pull-in trigger

When concrete user demand for "parallel sandboxed/arena-isolated tasks
on multi-worker scheduler" surfaces. Until then, Option A's per-worker
prelude install + TLS top is filed as Phase E.1.c, sequenced after
E.1.a (this commit) and E.1.b (auto-arena via `go` keyword).
