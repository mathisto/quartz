# Generalized `select` (C.13) — design memo

**Status**: Phase 1 design.
**Filed**: 2026-05-10.
**Pairs with**: B.7 (Scope unification — wake protocol substrate), B.8 (Scoped resources — `with`-block consumption surface), C.14 (Actor + Supervisor — `actor.recv` is a Selectable), D.10 (sync/ four-shapes reorg — Composition lives at `std/sync/composition/select.qz`).
**Roadmap link**: [`docs/ROADMAP.md`](../ROADMAP.md) row C.13.

---

## Problem

Quartz today has a `select` block, but it is **arm-keyword-bound**. Each
arm is one of five hardcoded shapes:

```be
select
  recv(ch) as x => body            # op_kind = 0
  send(ch, v) => body              # op_kind = 1
  default => body                  # op_kind = 2
  await(task) as x => body         # op_kind = 3
  timeout(ms) => body              # op_kind = 4
end
```

The five op-kinds are dispatched in the parser (parser.qz:5008-5060) and
again at MIR lowering (mir_lower_expr_handlers.qz:4029+, ~700 LOC of
hand-rolled per-arm-shape codegen) and again at typecheck
(typecheck_concurrency.qz:tc_check_select_arm). Every arm shape is
hardcoded at all three layers.

**The cost is two-fold.** First, every new "thing you can wait on" needs
parser + typecheck + MIR + a special-case lowering branch. Phase 14
fairness (Fisher-Yates shuffle across recv/send/await — but NOT timeout
and NOT default) is wired into the per-kind dispatch; adding a new kind
forces a decision about whether to participate in fairness, and the
codegen has to know. Second, **users cannot put a Selectable thing in
the select**. A goroutine that wants to race `ch.recv()` against
`scope.cancelled()` against a manually-set `Future<Reply>` against a
deadline can today only express the first via `recv` and the third via
`await`. The other two have to live outside select, which means they
can't share fairness, can't compose, and the consumer has to write
hand-rolled multiplexing.

After B.7 Phase 4e.8 every blocking primitive in std/sync/scope.qz
already implements a uniform wake protocol — register a waiter frame on
the resource, run the body, sched_wake the frame on completion. Channel
recv/send have a similar shape via `channel_notify_fd`. The substrate
for "register interest in N events, suspend until any fires, dispatch
the winner's continuation" already exists at the runtime level; the
language-level surface that exposes it as one syntactic form does not.

C.13 closes the gap. It's the **consumption-side unifier** — pairs with
B.7 (cancellation-side unifier — one Scope) and B.8 (resource-side
unifier — one `with`).

> *Two layers — actors at the top for 95% of code, four-shapes toolkit
> (Communication / Synchronization / Atomicity / Composition) underneath.
> One scope for cancellation. **One `select` for composition.** One
> `with` for resources.*

That sentence is the launch-blog one-paragraph pitch. C.13 is the second
clause.

---

## Goal

One trait — `Selectable<R>` — and one syntactic form — `select { case
x = <Selectable> => body ... }` — under which **anything that can be
polled and woken** races for completion.

```be
select
  case msg = ch.recv() => process(msg)
  case f = future_handle => use_result(f)
  case _ = scope.cancelled() => cleanup_and_throw()
  case _ = deadline_ms(5_000) => give_up()
  case _ = signal_on(SIGINT) => graceful_shutdown()
  case _ = mtx.try_lock() => fast_path()
  case (fd, ev) = ev_loop.ready() => handle_io(fd, ev)
  default => non_blocking_fallback()
end
```

All five existing arm forms (recv/send/await/timeout/default) get
replaced: only `default` survives unchanged — it's the no-block fallback,
not a Selectable. Per the project's pre-launch policy
(CLAUDE.md "Pre-launch reality check" + Prime Directive 7), we delete
the old arm-keyword forms in the same commit that ships the
replacement; no compat sugar.

The deletion is mechanical — the existing five forms map cleanly:

| Old | New |
|---|---|
| `recv(ch) as x => body` | `case x = ch.recv() => body` |
| `send(ch, v) => body` | `case _ = ch.send(v) => body` |
| `await(task) as x => body` | `case x = task => body` *(Future is itself Selectable)* |
| `timeout(ms) => body` | `case _ = deadline_ms(ms) => body` |
| `default => body` | `default => body` *(unchanged)* |

---

## Prior-art compass

| System | Surface | Polymorphic | Cancellation safety | First-class events | Notes |
|---|---|---|---|---|---|
| **Go `select`** | statement, channels-only | no | n/a (no cancellation primitive) | no | Uniform random fairness; the gold-standard syntax but channel-only. |
| **Erlang `receive`** | statement, mailboxes-only | no | n/a (no cancel; processes die instead) | no | Pattern-matched mailbox dispatch + after-clause; built on the BEAM mailbox primitive. |
| **Tokio `tokio::select!`** | macro | yes (any `Future`) | **footgun** — drop-on-cancel loses partial state | no | Polymorphic via Future trait; cancellation safety is the [#1 source of subtle bugs](https://docs.rs/tokio/latest/tokio/macro.select.html#cancellation-safety). |
| **Concurrent ML / OCaml `Event`** | function, events | yes | yes | **yes** (events are values, composed via `choose`/`wrap`/`guard`) | The academic gold standard. Reppy's PhD thesis (1992). Events are values: `choose [recv ch1; recv ch2]` is itself an event. |
| **Racket `sync`** | function, evt | yes | yes | yes (`evt?` interface, user-extensible) | Adopted CML's events; user types implement `gen:evt` to integrate with `sync`. |
| **Trio nurseries + `wait_any`** | function, awaitables | yes (any awaitable) | yes (cancellation is structural) | partial | Python; cancellation propagates via Trio's checkpoint-and-cancel-scope model. |
| **Pony behaviors** | n/a (actor-only) | n/a | n/a | no | Actors only receive via behavior dispatch; no select primitive. |
| **Haskell STM `orElse`** | monadic combinator | yes | yes (transactional rollback) | yes (STM actions are values) | Composes by "try first; if it retries, try second"; semantics via STM rollback. |
| **Akka `selectAll` / Future combinators** | combinator | yes (any Future) | yes (Future cancellation) | yes (Futures are values) | Closer to Tokio's shape than CML's events. |

**Key takeaways:**

1. **CML's first-class events is the design north star.** Events are
   values: you can build them, store them, pass them, combine them with
   `choose` into compound events that are themselves selectable. Quartz
   is a curly-statement-language not a functional ML, so we don't ship
   `wrap`/`guard`/`choose` as combinators — but we DO make Selectable a
   trait that user types can implement, so a user-defined "wait until N
   things happen" type is selectable in `select`. **This is what Tokio
   and Go don't have.** Pony actors and Erlang `receive` are
   mailbox-only.
2. **Tokio's cancellation footgun is a warning sign.** When `select!`
   picks one branch, the others' Futures get *dropped*. If a Future has
   acquired but not released a resource — say it pulled a value off a
   channel and was about to write it somewhere — that value is **lost**.
   Quartz's design must avoid this. The Selectable trait will require
   `try_poll` to be **non-destructive** — it observes readiness, but
   does not consume the value. Consumption is a separate `complete`
   step that runs only when the arm wins. Channel recv = peek-then-pop.
3. **Go's uniform random fairness is the right default.** Phase 14 of
   the existing select already does Fisher-Yates shuffle for
   recv/send/await arms; we keep this, extend to all Selectable arms.
4. **Erlang's `after` clause maps cleanly to a Selectable for deadline.**
   It's not a special syntax — it's an event whose readiness is "N ms
   have passed." Quartz ships `deadline_ms(ms)` as a free function
   returning `Selectable<Void>`.
5. **Racket's user-extensibility is the model.** Anyone can define
   their own `Selectable` impl and it slots into the existing `select`
   block. Without this, the trait isn't actually generalized — it's
   just a closed taxonomy with new names.

---

## Design

### The trait

```be
## A thing that can be raced inside a `select` block. Implementations
## express two ops: try_poll observes readiness without consuming the
## payload, and register_waker installs a callback so the polling task
## wakes when this Selectable becomes ready. complete is called by the
## select runtime on the winner; cancel is called on the losers.
trait Selectable<R>
  ## Non-destructive readiness check. Returns Some(payload) if the
  ## resource has progress to make right now, None if not. MUST NOT
  ## consume the payload — `complete` is the only function that may
  ## mutate the underlying resource. Channel recv: peeks at queue head;
  ## scope.cancelled(): observes the cancel flag; deadline_ms: compares
  ## time_mono_ns to deadline.
  def try_poll(self): Option<R>

  ## Install a wake notification on this resource. When the resource
  ## becomes ready, the implementation MUST call sched_wake(frame).
  ## Idempotent — registering the same frame twice is a no-op. The
  ## frame is the polling task's `task_self()`. Multiple selectables in
  ## the same select all register the same frame.
  def register_waker(self, frame: Int): Void

  ## Tear down the waker registration installed by register_waker.
  ## Always called when select abandons this branch (winner won, or
  ## select is itself cancelled mid-poll). Idempotent.
  def unregister_waker(self, frame: Int): Void

  ## Consume the payload now that this branch has won. Channel recv:
  ## actually pops from the queue. Channel send: actually pushes the
  ## value. Future: marks the future as awaited. scope.cancelled():
  ## throws via Throws (control never returns). Symmetric with
  ## try_poll's Some return — complete should match what try_poll saw,
  ## but the runtime guarantees complete is called only after a
  ## successful try_poll, so impls don't need to re-validate.
  ## Returns the payload that the user binding receives.
  def complete(self): R
end
```

The split between `try_poll` (non-destructive) and `complete`
(destructive) is what fixes Tokio's cancellation footgun. A losing
arm's Selectable is `unregister_waker`'d but never `complete`'d, so its
underlying resource is unchanged. There is no "the value got pulled out
and now it's gone" failure mode.

### The wake protocol

Every Selectable wakes via the same primitive: `sched_wake(frame)`.
This already exists in Quartz's M:N scheduler (B.7 Phase 4e.8 added the
race-safe CAS protocol on `frame[5]`). `sched_wake` is idempotent and
safe to call from any thread — it interrupts the target frame's
pending `sched_sleep` within microseconds.

The four classes of Selectable get four register_waker strategies, all
landing on `sched_wake(frame)`:

| Selectable class | register_waker strategy |
|---|---|
| **Scope-based** (`scope.cancelled()`) | `_scope_register_waiter(scope, frame)`. Existing B.7 4e.8 substrate. `scope_cancel` walks the waiter list and `sched_wake`s every entry. |
| **Channel-based** (`ch.recv()`, `ch.send(v)`) | New `channel_register_waker(ch, frame, kind)` intrinsic. Channel internals get a per-channel list of `(frame, kind)` pairs — kind=READ for recv, kind=WRITE for send. send/recv producer/consumer paths walk the list, sched_wake. |
| **Time-based** (`deadline_ms(ms)`) | Schedules a single-shot timer (existing B.7 4d proactive deadline timer infrastructure) that calls `sched_wake(frame)` at the deadline. |
| **I/O-based** (`fd.readable()`, `fd.writable()`, `signal_on(N)`) | Adds the fd to a thread-local epoll/kqueue, with a callback that sched_wakes the frame when the fd is ready. Signal arms get a self-pipe pre-installed at process start; signal handler writes a byte; the read-end is the fd. |

Channels get a small extension to today's `channel_notify_fd` — instead
of one fd per channel that signals "queue state changed," each channel
maintains a frame waiter list, walked on every send/recv operation
that changes the queue's emptiness. This is symmetric with the
B.7 4e.8 scope waiter list and eliminates the per-channel pipe-fd cost
when the channel is exclusively used in select. Existing
`channel_notify_fd` callers (the channels-iteration loop and chunked
poll) keep working — the new waker list is additive.

### Syntax (parser)

Today's `ps_parse_select` (parser.qz:4942) parses select as a sequence
of `ps_parse_select_arm` calls. Replace with a smaller, uniform parser:

```be
select
  case <pattern> = <expr> => body         # one or more case arms
  case _ = <expr> => body
  default => body                          # zero or one default arm
end
```

Where `<expr>` is any expression that typechecks as `impl Selectable<R>`
and `<pattern>` is a binding name (no destructuring in v1; defer to a
follow-up). `_` is the wildcard pattern (no binding installed).

The arm parser becomes ~30 LOC: read `case`, read pattern (ident or `_`),
read `=`, read full expression via `ps_parse_expr`, read `=>`, read body.
The current 100-LOC `ps_parse_select_arm` with its op-kind switch goes
away.

`default` arm is a separate path: read `default`, read `=>`, read body —
no Selectable, just the no-block fallback. Exactly one default per
select; multiple defaults emit QZ0625.

### Typecheck

`tc_check_select` (typecheck_concurrency.qz:161) becomes a real
typechecker instead of a stub:

1. For each `case <pat> = <expr> => body` arm:
   1. Typecheck `<expr>`. Result must be `impl Selectable<R>` for some
      R; otherwise QZ0626 ("expression in select case must implement
      Selectable").
   2. Bind `<pat>` (if not `_`) with type `R` in the body's scope.
   3. Typecheck `body`. Body's type contributes to the select's result
      type (unify across arms — same rule as match arms today).
4. Default arm body's type also unifies.
5. Select's overall type = unified arm body type. (Today it's TYPE_VOID
   because all arm bodies are statements. We keep `select` working as
   both expression and statement, like the existing one — see
   typecheck_walk.qz NODE_SELECT handling.)

The Selectable-impl lookup uses the same machinery `with`-blocks added
in B.8 Phase 3 for Scoped trait dispatch. Reuse `tc_lookup_trait_impl`
(typecheck_walk.qz:760+).

### MIR lowering

The current ~700-LOC `NODE_SELECT` handler in
`mir_lower_expr_handlers.qz` shrinks to ~250 LOC. The new lowering
shape:

```
                                       ; allocate result slot
%result_slot = alloca i64
                                       ; evaluate each Selectable expr
%sel_0 = lower(arms[0].selectable)     ; always evaluate (CML guards: this is
%sel_1 = lower(arms[1].selectable)     ; "guard fn" — side effects at sync time)
...

                                       ; Phase 14 fairness shuffle
%perm = qz_select_shuffle(N)           ; existing helper

select_poll_loop:
  ; one pass through all selectables in shuffled order
  for i in 0..N:
    %j = perm[i]
    %r = qz_selectable_try_poll(%sel_j)    ; calls Selectable::try_poll(self)
    if %r is Some(v):
      ; this arm wins
      qz_selectable_unregister_all_others(%sel_j, %sel_0..N)
      %payload = qz_selectable_complete(%sel_j)  ; runs once, consumes
      jump to body_j with %payload bound to arm's pattern
  endfor

  ; nobody ready — register wakers + park
  if has_default:
    jump default_body                    ; no blocking
  else:
    qz_selectable_register_all(%sel_0..N, task_self())
    qz_selectable_park()                 ; sched_park; wakes when any sched_wake fires
    qz_selectable_unregister_all(%sel_0..N, task_self())
    jump select_poll_loop
  endif

select_done:
  load %result_slot
```

Three new MIR ops: `qz_selectable_try_poll(sel)`, `qz_selectable_register_waker`,
`qz_selectable_unregister_waker`, `qz_selectable_complete(sel)`. Each
emits a virtual call through the Selectable trait's vtable — same
machinery as the Scoped trait's `acquire`/`release` dispatch in B.8.

`qz_selectable_park` is a new runtime helper: equivalent to
`sched_park(task_self())` with a deadline-aware short timeout (default
~50ms, matching the existing B.7 chunked-poll cadence; on each wake-up
the loop re-polls all selectables). The reason for the short timeout
rather than indefinite park is identical to the chunked-poll case —
it's a defensive hedge against races between try_poll observing "not
ready" and a producer arriving and missing the wake-up because the
waker hadn't been registered yet. With the active-wake substrate this
race is closed at the protocol level (register-then-recheck), but
keeping a coarse timeout means a missed wake is bounded delay, not
indefinite hang. Phase 4e.8's bound is preserved.

The `qz_selectable_complete` call runs **inside** the select block —
after the chosen arm wins but before its body executes. This is where
the destructive op happens (channel pop, future await, deadline throw,
etc). On `scope.cancelled()` arm, complete throws via Throws, which the
outer scope catches; the select's other branches were already
unregistered.

### Stdlib `impl Selectable` matrix (Phase 5)

| Type | Module | `R` (payload) | try_poll | complete | register_waker (as shipped) |
|---|---|---|---|---|---|
| `RecvSelectable<T>` | std/sync/channel.qz | `T` | `try_recv(ch)` (destructive — pops) | no-op (return 0; binding from try_poll payload) | `waiter_register(@ch, frame)` — kind-tagged read-waiters key (C.13.6) |
| `SendSelectable<T>` | std/sync/channel.qz | `Void` | `try_send(ch, v)` (destructive — pushes) | no-op | `waiter_register(@ch \| 1, frame)` — kind-tagged write-waiters key (C.13.6) |
| `FutureSelectable` (`awaitable(t)`) | std/sync/awaitable.qz | `R` | reads `load(frame, 0/1)` (non-destructive) | no-op | `waiter_register(@task_handle, frame)` — task_done/panic_caught notifies |
| `ScopeCancelSelectable` (`cancellable(s)`) | std/sync/scope.qz | `Void` | `scope_is_cancelled(s)` | `throw(scope_cancel_reason(s))` | piggybacks on scope's pthread cond — `scope_cancel` wakes waiters |
| `DeadlineSelectable` (`deadline_ms(ms)`) | std/sync/scope.qz | `Void` | compares `time_mono_ns()` to deadline | `throw("deadline_exceeded")` | piggybacks on `scope_deadline(scope_root(), deadline_ns)` — B.7 4e.8 plumbing |
| `MutexTrySelectable` (`try_lockable(m)`) | std/sync/mutex.qz | `Int` (protected value) | `mutex_try_lock(m)` | no-op (lock now held by current thread) | `waiter_register(@mutex_handle, frame)` — `mutex_unlock` notifies |
| `SignalSelectable` (`signal_ready(sig)`) | std/sync/signal.qz | `Int` (signal number) | reads signal-fired flag (non-destructive) | clears flag | **polling-only** — 10ms cadence (can't `sched_wake` from async-signal context) |
| ~~`IoReadySelectable`~~ | deferred to C.13.8 | — | — | — | needs `std/net/event_loop.qz` integration; hold until a real consumer demands it |

The wake side runs through a single resource-waiter side-table
(`@__qz_waiters`) shaped as `(target_key: i64, waiter_frame: i64)`
pairs. `target_key` is kind-tagged for multi-event resources —
channels use `handle | 0` for recv-waiters and `handle | 1` for
send-waiters; `channel_close` notifies both. Handles are
≥16-byte-aligned (malloc invariant; verified 128/128) so the low 3
bits are reliably free for tag bits. The encoding scales to 4 event
classes per resource without colliding with the handle bits — RwLock
read/write/upgrade is the obvious next consumer.

Per project memory `feedback_task_waiters_side_table_pattern.md`:
this is the general pattern for any future "sched_wake on resource
state-change" need.

### Decision tree (for users)

```
Need to wait on multiple things, with at least one being non-channel?
└─ select with case x = <Selectable> arms

Need to wait on N channels of the same kind?
└─ select with case msg = ch.recv() arms (one per channel)
   — OR — for await msg in ch (when single channel and consumption is iter-shaped)

Need to wait on one thing, with cancellation?
└─ scope-aware blocking helper (scope_recv, scope_lock, scope_sleep_ms)
   — these are Selectable's degenerate single-arm case, optimized

Need to wait on N futures, "first wins"?
└─ select with case x = future_N arms — Phase 5's Future impl makes this work

Need to compose Selectables (build then race later)?
└─ Defer. CML-style choose/wrap/guard combinators are out of v1.
   File as C.13.5 follow-up if a real use case surfaces.
```

### Non-goals

- **No CML choose/wrap/guard combinators in v1.** Selectables are
  materialized at the select site, not built up as values. If a real
  use case surfaces, file as C.13.5.
- **No automatic stream merging.** Tokio recommends `tokio_stream::merge`
  over `loop { select { ... } }` for hot loops; Quartz iterators don't
  yet have a parallel concept. Defer to D.10 four-shapes reorg or a
  later channel-iteration revision.
- **No biased select.** Tokio offers a `biased` mode that disables the
  random shuffle. Phase 14 fairness is the default; if a real use case
  emerges, ship as a `select biased` syntax extension. Out of v1.
- **No `select` over arbitrary I/O without an EventLoop.** Phase 5's
  `IoReadySelectable` requires the user to have an EventLoop; we don't
  ship process-global epoll. (B.7's scope timer thread is a process
  singleton; the I/O multiplexer should not be — too much hidden state.)
- **No retroactive cleanup of `with await(t)` style sugar.** Users who
  want await-with-default for a non-blocking poll can write the explicit
  select. The `await` keyword as expression-level continues to mean
  "block until done" — unchanged.
- **No try_poll-must-not-block enforcement.** It's a contract, not a
  type rule. `Selectable::try_poll` impls that block are a footgun;
  document loudly + ship a debug-mode timer that flags slow try_polls.
  Phase 7 doc work covers this.

### Open questions

1. **Trait erasure and the `R` type-parameter.** Same shape as
   `Scoped<R>` from B.8 — generic erasure means `R` is always `Int` at
   runtime. The arm's bound name has the typed shape (`x: T` for
   `RecvSelectable<T>`), but the IR sees `i64`. The substrate already
   shipped this for Scoped; no new work.

2. **Cancellation safety contract for impls.** A user's `Selectable`
   impl could register a waker on resource A, win the select, complete
   the win, but forget to unregister from resource B (which it doesn't
   own). The runtime's `qz_selectable_unregister_all_others` walks the
   list of arms and calls `unregister_waker` on each loser, so as long
   as each impl unregisters cleanly when asked, this works. **Document
   in QUARTZ_REFERENCE.md** as part of Phase 7. No type rule.

3. **Same Selectable used twice in one select.** `case x = ch.recv() =>
   ... case y = ch.recv() => ...` — one arm wins, the other's
   register_waker is torn down cleanly. Channel impl's waker list is
   per-frame, not per-(frame, op_kind), so registering the same frame
   twice for the same channel is a no-op (idempotent). No special
   handling needed.

4. **Dynamic select (Vec-of-Selectables).** Tokio has a separate
   `FuturesUnordered`; Go has reflect.Select. Quartz's compile-time
   select fits 95% of cases; for the dynamic case, expose a
   `select_dynamic(arms: Vec<Selectable<Int>>): Int` stdlib helper
   returning the winning index. **Defer the helper to Phase 5.5; the
   compile-time syntax ships in Phase 4.**

5. **`with`-block inside a select arm body.** A select arm wins; its
   body might `with X do v -> ... end` something. Today's NODE_BLOCK
   lowering handles this; the wrap_stack drain machinery from B.8
   Phase 4 covers early returns out of arm bodies. Verified — see
   B.8 spec `scoped_writeback_spec.qz:throw_path` for the relevant
   case shape. **No new design work needed.**

6. **`break`/`continue` inside select arm body.** A select arm body that
   `break`s out of an enclosing loop must not skip the implicit
   `unregister_all` step on the OTHER arms. This is the same wrap_stack
   drain issue as B.8 — solve identically: select-arm registration
   pushes a wrap_stack entry whose drain calls `unregister_all_losers`.
   **Touches mir.qz wrap_stack — see Phase 4 risk note.**

---

## Phase plan

**Status as of 2026-05-10**: Phases 1–7 shipped except C.13.8
(IoReadySelectable, deferred) and C.13.9 (select_dynamic, filed).
C.13.6 channel-waker landed with kind-tagged side-table keys
(`@ch` / `@ch | 1`). C.13.7 renamed the runtime registry to its
generic form (`waiter_*` / `@__qz_waiters`) to reflect that it now
backs task / mutex / channel waiters.

| Phase | Work | Estimate | Status |
|---|---|---|---|
| 1 | Design memo (this) | done | ✅ 2026-05-10 |
| 2 | Parser: uniform `case <pat> = <expr> => body` shape | ~0.3d | ✅ shipped |
| 3 | Typecheck: `Selectable<R>` trait, `tc_check_select` dispatch | ~0.5d | ✅ shipped |
| 4a | MIR lower: poll-loop + register/park/poll/unregister; fairness shuffle | ~0.8d | ✅ shipped |
| 4b | wrap_stack integration: drain unregister_waker on NODE_RETURN/break/continue | ~0.4d | ✅ shipped (`518b1032`); Plan A eager unregister is throw-safe |
| 5 | Stdlib `impl Selectable` matrix (Recv/Send/Future/ScopeCancel/Deadline/Mutex/Signal) | ~1d | ✅ shipped (`4e2822e9` Future + `task_waiters` side-table introduced) |
| 5.5 | (deferred) `select_dynamic` for Vec-of-Selectables | ~0.3d | filed as C.13.9 |
| 6 | Migrate `std/futures.qz:sched_timeout` and examples | ~0.3d | ✅ shipped |
| 6.5 | Channel waker — active-wake for RecvSelectable / SendSelectable | — | ✅ C.13.6 `c9d5deed` (v1 shared key) → `2981fbc9` (kind-tag flip) |
| 6.6 | Resource-waiter rename — `task_waiter_*` → `waiter_*`, `@__qz_task_waiters` → `@__qz_waiters` | ~0.2d | ✅ C.13.7 — registry now reflects task/mutex/channel multi-resource use |
| 7 | Docs: `QUARTZ_REFERENCE.md` "Generalized select" subsection; this design doc's matrix updated to as-shipped | ~0.3d | ✅ shipped |
| 8 | IoReadySelectable: `std/net/event_loop.qz` integration | — | **deferred** as C.13.8; hold until a real consumer demands it |

**Total**: ~3.6 quartz-days. ROADMAP estimate was "~1 quartz-week" =
~5 quartz-days. Substrate already shipped (B.7 4e.8 wake protocol,
channel notify-fd, B.8 trait-dispatch path) covers ~30% of what would
otherwise be from-scratch work.

**Calibration note**: B.8 was originally sized "~1-2 quartz-weeks" and
shipped in 2 calendar days end-to-end (Phase 1-7, design through
docs). C.13's design relies on B.8's substrate (trait dispatch,
wrap_stack discipline) plus B.7's substrate (active-wake, scope waiter
list) — both already paid down. The dominant remaining cost is the
stdlib impl matrix (Phase 5), which mirrors B.8 Phase 5's shape
(8 types, ~1d).

**Parallelism**: Phases 2-4 are sequential. Phase 5 starts after 4a
green; signals + I/O-ready can be developed in parallel by the same
session since they're independent. Phase 6 unblocked by Phase 5.
Phase 7 final.

---

## Risks / dependencies

- **Channel waker-list addition (Phase 5).** Today channels expose
  `channel_notify_fd` (a per-channel pipe-fd that signals queue-state
  change). Selectable's `register_waker(frame)` wants a per-channel
  `(frame, kind)` list that send/recv producers walk. This is new
  channel-internal state — touches the channel's mutex-guarded queue
  struct. **Mitigation**: ship the waker list as ADDITIVE to
  `channel_notify_fd` (which keeps working). Existing chunked-poll
  helpers (`scope_recv`/`scope_send`) keep using their current loop;
  only the new Selectable impl uses the new waker list.
- **Cancellation safety contract has no type-system enforcement.** A
  user impl that does mutation in `try_poll` is a footgun; we ship the
  contract as documentation, not as a checker. This is the same
  posture as Tokio (where impl Future poll() doing pre-consume is a
  bug nobody can catch automatically). **Mitigation**: ship a
  debug-mode `qz_selectable_observe_try_poll` that records every
  try_poll call and barfs if a `Selectable` mutates between two
  try_polls without a `complete` between. Phase 7 doc + Phase 5
  debug-mode infra. Pre-launch project, debug-mode footgun-detector
  is an acceptable mitigation.
- **Migrating `examples/` and `std/futures.qz:sched_timeout`.** These
  are the in-tree callers of the old `select` syntax; the migration
  is mechanical but blocking. **Mitigation**: do the migration in the
  same commit that ships the parser change (Phase 2) — same pattern
  as B.8 Phase 6's progress.qz migration. No half-shipped state.
- **Wrap_stack dual-function gap (per feedback memo).** Phase 4b
  touches `mir_ctx_emit_active_wrap_pops` AND
  `mir_ctx_emit_wrap_pops_to_depth`. **Mitigation**: project memory
  `feedback_wrap_stack_drain_dual_function_gap.md` warns explicitly;
  spec one early-exit path in each direction (NODE_RETURN inside arm
  body + break-from-loop-around-select with arm winner). 2 tests cover
  both functions.
- **Stale waker on cancelled select.** If a select itself is cancelled
  via Throws (e.g. outer scope cancel) MID-poll-loop, the `unregister_waker`
  step must run for all selectables. This is exactly the wrap_stack
  drain integration from Phase 4b; without it, a cancelled select
  leaks waker registrations. **Mitigation**: spec covers it explicitly
  (`spec/qspec/select_throw_drain_spec.qz`).

---

## Success criteria

- Old `select` arm-keyword syntax (`recv`/`send`/`await`/`timeout`)
  removed; only `case ... =` and `default =>` remain. In-tree
  consumers (`std/futures.qz:sched_timeout`, examples) migrated.
- `select` over heterogeneous Selectables — channel + future + scope
  cancel + deadline + signal — round-trips through parser/typecheck/MIR/codegen
  and produces the expected runtime behavior.
- New spec `spec/qspec/select_unified_spec.qz` covers: single-arm pass-through,
  multi-arm fairness (Fisher-Yates over 4+ arms), default arm short-circuit
  when nothing ready, scope-cancel arm wins, deadline arm wins, signal arm
  wins (via raise-and-receive-from-self-pipe), I/O-ready arm wins, mutex
  try-lock arm wins, throw-from-complete unwinds via outer Throws, break/return
  out of arm body unregisters losers cleanly.
- Phase 14 fairness preserved end-to-end (no arm class systematically wins).
  Verified: 1000-iter histogram across 4 always-ready arms each at
  ≥ 200 wins (within 1.5σ of equal distribution).
- `with` + `select` interaction (Scoped resource acquired inside arm body)
  works — release fires on every exit path including arm-body throw.
- Cancellation-safety: a losing arm's `Selectable` is not consumed.
  Verified spec: send a sentinel into channel A, race A.recv() vs.
  scope.cancelled(); after scope cancels, A.recv() called outside select
  still gets the sentinel. (The lost-message bug Tokio has cannot
  manifest in this design.)
- Fixpoint clean (gen1 == gen2 byte-identical).
- All existing concurrency, scope, and channel specs green.
- Smokes on `style_demo`, `brainfuck`, and the migrated examples pass.
- `docs/QUARTZ_REFERENCE.md` "Generalized select" section ships with
  worked examples for every Selectable stdlib type.

---

## Calibration notes

Original C.13 estimate (May 1 2026 design session): ~1 quartz-week.
Post-design estimate: ~3.6 quartz-days.

Reduction from substrate paydown:
- B.7 Phase 4e.8 active-wake (`_scope_register_waiter` +
  `sched_wake(frame)` race-safe CAS): ~25% savings on Phase 5 impls
- B.8 Phase 3 trait-impl dispatch in typecheck (`tc_lookup_trait_impl`):
  ~15% savings on Phase 3
- B.8 Phase 4 wrap_stack discipline: directly reusable for Phase 4b
- Existing channel `channel_notify_fd` + select polling loop: ~30%
  of MIR codegen already in shape for the new lowering

Per project memory `feedback_phase_4e_chunked_poll_recipe.md`: the
parallel for C.13 is "ship first impl with hardcoded type, generalize
once recipe proven" — channel impls (recv/send) ship in Phase 5 first
since they exercise the most of the new substrate (waker list +
register/unregister + try_poll/complete asymmetry); the other six
impls follow the recipe.

Per `feedback_design_memo_estimates_oversize.md`: pre-flight survey of
existing helpers before sizing — done in this memo (channel_notify_fd,
_scope_register_waiter, sched_wake, task_self all already exist;
trait dispatch path from B.8 already exists).

Per project memory `feedback_resolver_rewrite_coverage_gap.md` and
`feedback_capture_walker_coverage_gap.md`: the new MIR ops
(`qz_selectable_try_poll` etc.) are intrinsics — they go through the
intrinsic registry (existing path), no AST-walker coverage gap to
worry about. The parser change introduces a new arm shape (case
expr-binding form) but that's a NODE_SELECT_ARM internal change, not
a new top-level NODE; resolver-rewrite + capture-walker passes
already handle NODE_SELECT_ARM via fallthrough on its body slot.
**Verify during Phase 4a**.

---

## Pairing with other tracks

- **B.7 (Scope)**: `scope.cancelled()` is the single most-load-bearing
  Selectable. It's what makes "race work against cancellation" trivial.
  The substrate is shipped; this just exposes it as a Selectable.
- **B.8 (Scoped resources)**: the trait-dispatch path for `with` is
  the same machinery `select` uses for Selectable resolution. `with`
  + `select` compose cleanly — open a Scoped resource inside an arm
  body, throw-safe release fires.
- **C.14 (Actor + Supervisor)**: `actor.recv()` is a Selectable.
  Actors-with-deadline-handling becomes `select { case msg = actor.recv()
  => ...; case _ = deadline_ms(timeout) => ... }`. C.14 ships the
  Selectable impl for actor mailboxes; this memo's Phase 5 covers
  channel-Selectable, which actors are built on.
- **D.10 (sync/ four-shapes reorg)**: `select` lives at
  `std/sync/composition/select.qz`. Selectable trait at
  `std/selectable.qz` (matches `std/scoped.qz`). D.10 is the rename
  pass; this work ships the canonical home, D.10 standardizes the path.
- **D.11 (capstone)**: `http_server.qz` per-connection loop becomes
  `select { case bytes = conn.read(); case _ = scope.cancelled(); case _
  = deadline_ms(KEEPALIVE_MS) => idle_close() }`. Today this is
  hand-rolled select-with-recv-and-timer; the migration becomes a
  one-line cleanup once C.13 ships.

---

## See also

- B.7: `docs/design/SCOPE_UNIFICATION.md`, `docs/design/SCOPE_PHASE_4E_8_ACTIVE_WAKE.md`
- B.8: `docs/design/SCOPED_RESOURCES.md`
- C.14: ROADMAP row C.14 (`docs/ROADMAP.md`)
- D.10: ROADMAP row D.10
- D.11: ROADMAP row D.11, [`docs/SOUL_OF_QUARTZ.md`](../SOUL_OF_QUARTZ.md)
- Existing select: `self-hosted/frontend/parser.qz:4942`,
  `self-hosted/middle/typecheck_concurrency.qz:150`,
  `self-hosted/backend/mir_lower_expr_handlers.qz:4029`
- Wake substrate: `std/sync/scope.qz:_scope_register_waiter`,
  `std/sync/scope.qz:scope_recv` (canonical chunked-poll-with-active-wake template)
- Channel notify substrate: `self-hosted/backend/cg_intrinsic_conc_channel.qz:channel_notify_fd`
