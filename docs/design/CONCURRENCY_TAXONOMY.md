# CONCURRENCY_TAXONOMY — std/sync/ four-shapes reorg (D.10)

**Status:** Design — Phase 1 in progress
**Filed:** 2026-05-11
**Drives:** D.10 in `docs/ROADMAP.md`; unblocks D.11 (capstone http_server + Soul of Quartz rebuild)

## Pitch

> Quartz concurrency is two layers — actors at the top for 95% of code (`std/actor.qz`), four-shapes toolkit underneath. One scope for cancellation, one `select` for composition, one `with` for resources.

The four shapes:

| Shape | What it solves | Primitives |
|---|---|---|
| **Communication** | Move values between concurrent units | `Channel`, `BroadcastChannel`, actor mailbox |
| **Exclusion** | Serialize access to mutable state | `Mutex<T>`, `RwLock<T>`, `Spinlock`, `Semaphore`, `Barrier` |
| **Atomicity** | Lock-free single-word state | `Atomic`, atomic intrinsics, memory fences |
| **Composition** | Coordinate, race, cancel, deadline | `Future`, `select{}`, `Scope`, `Signal`, `Scoped`/`Selectable` traits |

These are genuinely different problems. We do **not** try to collapse them — atomics solve "lock-free single-word state," mutex solves "block until you own this," channels solve "hand off a value," and futures solve "await this completion." Each is the right hammer for its shape.

## Why not collapse?

The temptation: "everything is a channel" (Go) or "everything is an Erlang process" (BEAM). Rejected because:

- **Channels** introduce a memory copy per message. For atomic-counter-style hot paths (the Soul of Quartz heartbeat counter, SMP per-CPU `ready_count`), this is 100×–1000× too slow.
- **Mutexes** make sense only when an outer block holds the lock across multiple operations. For "increment-this-counter-from-an-ISR," they're the wrong shape (ISRs can't block).
- **Atomics** can't model "wait until this is ready" — you'd burn CPU spinning.

Keep them distinct, name them clearly, and put them in obviously different directory sections.

## Final layout

```
std/
  scoped.qz                     -- trait (resource protocol; pervasive — io, net, sync)
  selectable.qz                 -- trait (select{} arm protocol; pervasive)
  sched.qz                      -- effect (Sync-bound checker; not a sync primitive)
  async.qz                      -- effect (Async runtime; type-level)
  actor.qz                      -- Layer 1: actors (stays)
  sync/
    scheduler.qz                -- M:N runtime exposition (stays — observability, not a primitive)
    communication/
      channel.qz                -- struct Channel + send/recv/try_recv/close + Result variants
      broadcast.qz              -- broadcast/fan-out channel (extracted from concurrency.qz)
    exclusion/
      mutex.qz                  -- struct Mutex + MutexGuard (already exists; move)
      rwlock.qz                 -- struct RwLock + Read/Write guards (already exists; move)
      spinlock.qz               -- struct Spinlock + extend (NEW wrapper around raw intrinsics)
      semaphore.qz              -- DEFERRED — primitive doesn't exist yet
      barrier.qz                -- struct Barrier (extracted from concurrency.qz)
    atomic/
      atomic_int.qz             -- struct Atomic + load/store/cas/add/sub (NEW wrapper)
      atomic_ptr.qz             -- DEFERRED — pointer atomics not implemented yet
      fence.qz                  -- DEFERRED — fence intrinsic not exposed yet
    composition/
      future.qz                 -- async_all / async_race / async_map / async_timeout (was futures.qz)
      select.qz                 -- Selectable adapters (was selectable.qz portions)
      scope.qz                  -- Scope + scope_with + scope_with_cancel (already exists; move)
      signal.qz                 -- signal-handler integration (was signal.qz; move)
      awaitable.qz              -- FutureSelectable (already exists; move)
      go.qz                     -- go() / structured_scope / supervisor wrappers (drained from concurrency.qz)
```

### Files DELETED at end of D.10

- `std/channels.qz` → folded into `std/sync/communication/channel.qz` (Result variants merge in)
- `std/concurrency.qz` → drained into `std/sync/composition/go.qz` (legacy wrappers) + `std/sync/exclusion/barrier.qz` + `std/sync/communication/broadcast.qz`
- `std/futures.qz` → `std/sync/composition/future.qz`
- `std/signal.qz` → `std/sync/composition/signal.qz`
- `std/sync/channel.qz` → `std/sync/communication/channel.qz`
- `std/sync/mutex.qz` → `std/sync/exclusion/mutex.qz`
- `std/sync/rwlock.qz` → `std/sync/exclusion/rwlock.qz`
- `std/sync/spinlock.qz` → `std/sync/exclusion/spinlock.qz`
- `std/sync/scope.qz` → `std/sync/composition/scope.qz`
- `std/sync/awaitable.qz` → `std/sync/composition/awaitable.qz`

### Files STAYING at top level (despite the temptation to move)

- `std/scoped.qz` — pervasive trait used by `std/io/file.qz`, `std/net/tcp.qz`, `std/net/event_loop.qz`. NOT just a sync concern.
- `std/selectable.qz` — pervasive trait (analogous to `Scoped`). Concrete `Selectable` impls go into `std/sync/composition/`; the trait declaration stays at top level so non-sync code (a hypothetical I/O-readiness `Selectable`) can implement it without an awkward import path.
- `std/sched.qz` — `Sched` effect. Type-level marker for foreign-thread callback contexts. Belongs alongside `Async` effect, not under sync.
- `std/async.qz` — `Async` effect. Same reasoning.
- `std/sync/scheduler.qz` — runtime observability for the K8 SMP scheduler. Not a primitive. Stays where it is.

## Naming convention

Primitives expose a `def new(...)` associated function on their wrapping struct:

```qz
var ch  = Channel.new(64)        -- not channel_new(64)
var m   = Mutex.new(0)           -- not mutex(0)
var rw  = RwLock.new(0)          -- not rwlock(0)
var s   = Spinlock.new()         -- not spinlock_new()
var a   = Atomic.new(0)          -- not atomic_new(0)
```

Method calls use UFCS / paren-optional dot:

```qz
ch.send(42)                       -- not channel_send(ch, 42)
ch.recv                           -- paren-optional, zero-arg
m.lock                            -- returns MutexGuard for `with`-block
rw.read                           -- returns RwLockReadGuard
a.load                            -- paren-optional
a.cas(expected, desired)
```

Adapter functions (Selectable constructors) keep lowercase free-fn names because they read as adjectives in `select` arms:

```qz
select
  case msg = recvable(ch) => process(msg)
  case _   = deadline_ms(5000) => give_up()
  case _   = cancellable(scope) => bail()
end
```

`recvable` / `sendable` / `awaitable` / `deadline_ms` / `cancellable` stay as free functions. They are *not* primitives; they are select-arm DSL.

## Migration order

| Phase | Work | Reversible? |
|---|---|---|
| 1 | Add `def new(...)` to existing struct extensions (Mutex, RwLock). Pure additive. No callsite changes. | Yes — old constructors still work |
| 2 | Add NEW struct wrappers for currently-raw-handle primitives: Channel, Spinlock, Atomic | Yes — additive |
| 3 | Move files into subdirs (`std/sync/communication/`, `exclusion/`, `atomic/`, `composition/`), update imports atomically | Hard to revert (touches many imports) |
| 4 | Migrate all callsites from old free-fn constructors to `Type.new(...)` | Each callsite reversible individually |
| 5 | Delete old top-level facade files (`std/channels.qz`, `std/concurrency.qz`, `std/futures.qz`, `std/signal.qz`) | Final |
| 6 | Update `docs/QUARTZ_REFERENCE.md` with four-shapes section | Final |

Each phase ships through `quake guard` (fixpoint + smoke) as a single commit. Phases 1–2 can land in one session; phases 3–6 are larger and probably land across 2–3 sessions.

## Open questions

- **Mailbox.** Should the actor `inbox` get a `Mailbox` struct wrapper in `std/sync/communication/mailbox.qz`, or stay as the opaque `actor.inbox: Int`? Defer — touches C.14 internals and risks regressions.
- **CancelToken** lives in `std/concurrency.qz` today as a capability-style cancellation token. It's orthogonal to the Scope structural cancellation. Goes where? Proposal: `std/sync/composition/cancel_token.qz`.
- **WaitGroup / OnceCell.** Both live in `std/concurrency.qz` today. WaitGroup → `std/sync/exclusion/waitgroup.qz` (it's a counter, exclusion-shaped). OnceCell → `std/sync/composition/oncecell.qz` (it's a one-shot future-like).

## Non-goals

- Reorganizing `std/actor.qz` (Layer 1 stays at top level; it's THE flagship API).
- Reorganizing `std/io/`, `std/net/` (those are I/O, not concurrency).
- Adding new primitives (semaphore, condvar, atomic_ptr, fence) — those are deferred until a real consumer needs them.

## References

- `docs/ROADMAP.md` D.10
- `docs/design/ACTOR_MODEL.md` (Layer 1)
- `docs/design/SCOPE_UNIFICATION.md` (B.7 — composition substrate)
- `docs/design/SCOPED_RESOURCES.md` (B.8 — Scoped trait)
- `docs/design/SELECT_UNIFICATION.md` (C.13 — Selectable trait)
- `docs/design/SCOPE_PHASE_5_LEGACY_MIGRATION.md` (precedent for draining `std/concurrency.qz`)
