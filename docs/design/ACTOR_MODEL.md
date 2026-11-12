# Actor Model — design + phase breakdown for C.14

**Filed:** 2026-05-10
**Pairs with:** B.7 (Scope), B.8 (Scoped), C.13 (Selectable), D.10 (sync/ taxonomy), D.11 (capstone)
**Status:** Phases 1–6 shipped (C.14.1 through C.14.6 inclusive). C.14.7 (`actor_die()` escalation) tracked as optional follow-up.
**Roadmap row:** C.14 `std/actor.qz` — BEAM-in-a-box stdlib API (Layer 1)

---

## The pitch C.14 has to make credible

> *"For 95% of concurrent code: spawn an actor with the `actor X ... end`
> keyword, send it messages by calling methods, supervise crashes with
> `Supervisor`. Millions of cheap processes, mailbox message passing,
> let-it-crash supervision — like Erlang/OTP, with Go-like terse syntax.
> For the 5% needing finer control, drop to channels / mutex / atomic /
> async. Same scope, same select, same `with`."*

D.4 (launch blog) cannot ship without this paragraph being true. C.14 is
what makes it true.

---

## What already exists at trunk (so we don't reinvent it)

### Language-level `actor` keyword — shipped

```be
actor Counter
  var count: Int = 0
  def increment(): Void
    count += 1
  end
  def get(): Int = count
end

var c = Counter()        # spawn — returns inbox channel handle (Int)
c.increment()            # fire-and-forget message
var n = c.get()          # request-response — blocks on reply channel
var ch = c.get_async()   # async proxy — returns reply channel handle
c.link(c2)               # bidirectional crash-cascade
c.unlink(c2)
c.stop()                 # synchronous shutdown
```

The compiler's `PASS_ACTOR` lowers this to:
- A state struct: `[field_0..field_N-1, inbox_chan, pending_reply, links_vec, monitors_vec]`
- A `Counter$new()` spawn function: allocates state, creates inbox channel, builds a Future-frame for the poll loop, marks `frame[3] = -999` (actor sentinel), and `sched_spawn`s it
- A `Counter$__poll()` recv-loop that pattern-matches on `msg[0]` (method tag) and dispatches
- Synthetic proxies: `Counter$method`, `Counter$method_async`, `Counter$stop`, `Counter$link`, `Counter$unlink`, etc.

### Scheduler-side actor recovery — shipped

The scheduler's worker-thread loop checks `frame[3] == -999` on the
panicking task. If set, it `setjmp/longjmp`s back to the actor's recv
loop, drops the offending reply (caller gets 0 from the reply channel),
and continues. **The actor's state is preserved across handler panics.**

This is **not** Erlang/OTP semantics — it's a per-handler firewall, not
a process-level "let it crash, supervisor restarts." OTP's model is
"the process dies, the supervisor respawns it with fresh state." Quartz
today does "the handler dies, the process keeps its state."

### `supervisor_tree` — partially what we want

`std/concurrency.qz:344` ships `supervisor_tree(strategy, max_restarts,
children: Vec<Fn(): Int>)` with all three Erlang strategies
(`RESTART_ONE_FOR_ONE` / `_ONE_FOR_ALL` / `_REST_FOR_ONE`). **But:**

1. It restarts **goroutine closures**, not actors. The closure has to
   *be* the actor lifecycle (e.g., `() -> { let c = Counter(); c.run() }`).
2. The closures' return-value-or-`-1` is the failure signal; for an
   actor, the failure signal is "inbox closed."
3. There's no intensity/period window — `max_restarts` is total, not
   "within `period_ms`."

`supervisor_tree` is the right starting *implementation*; it's the
wrong starting *API* for actor supervision.

### `awaitable` — already C.13-Selectable for tasks

`std/sync/awaitable.qz` wraps **task frames** (from `go`/`async`/`spawn`)
for `select`. For **channels** (which is what `.method_async()` returns),
`recvable(ch)` from `std/sync/channel.qz` is already the Selectable. So:

```be
var ch = c.get_async()
select
  case v = recvable(ch) => use(v)
  case _ = deadline_ms(100) => timeout()
end
```

works **today**. No new `Awaitable<T>` wrapper is needed in `std/actor.qz`.

---

## Survey — what BEAM, Akka, Pony, Java structured-concurrency settled on

### Erlang/OTP `supervisor` (the canonical reference)

- **`child_spec`** carries `id`, `start = {M,F,A}`, `restart =
  permanent | transient | temporary`, `shutdown = brutal_kill | infinity |
  Timeout`, `type = worker | supervisor`.
- **Strategies:** `one_for_one`, `one_for_all`, `rest_for_one`,
  `simple_one_for_one` (dynamic; deprecated in favor of Elixir's
  `DynamicSupervisor` — *don't ship simple_one_for_one as an enum value;
  ship a separate `DynamicSupervisor` type instead*).
- **`intensity` / `period` escalation** — defaults **1 restart per 5
  seconds**. If exceeded, the supervisor *itself* terminates with reason
  `shutdown`, escalating to its parent. **Without this rule, supervision
  trees can't compose.**
- Restart semantics: `permanent` always; `transient` only on abnormal
  exit; `temporary` never. **The new actor gets a fresh mailbox** — old
  messages addressed the old PID and are lost. (Akka's default is to
  preserve mailbox; we should match OTP for the typed-actor model since
  the old method-call replies are addressed to dead channels.)

### Akka Typed `Behaviors.supervise` — the typed-actor reference

```scala
Behaviors.supervise(behaviorFactory).onFailure[Throwable](
  SupervisorStrategy.restart
    .withLimit(maxRetries=5, withinTimeRange=10.seconds)
    .withStashCapacity(100)
)
```

- **Wrap-a-factory, not an-actor.** `supervise(factory)` returns a
  new factory; `spawn` consumes it. *You cannot retro-supervise a
  running actor.* The composition direction is load-bearing.
- **Restart strategies:** `.restart` / `.resume` (ignore + continue) /
  `.stop` / `.restartWithBackoff(min, max, randomFactor)`.
- **Backoff signature** (Akka, verbatim): `restartWithBackoff(minBackoff:
  FiniteDuration, maxBackoff: FiniteDuration, randomFactor: Double)`.
  Exponential doubling capped at `maxBackoff`, plus `randomFactor` jitter.
  Counter resets after uptime > `minBackoff`.
- **PreRestart / PostStop signals.** Hook for resource cleanup before
  state is recreated. Quartz already has `trait Scoped` (B.8); bind
  PreRestart to it.

### Pony — the "no supervisor" contrast case

Pony has no supervisor and no actor restart, because **reference
capabilities + partial functions** prevent recoverable runtime failure.
Constructors and behaviors can't be partial; an actor literally cannot
"crash on a message." A program that compiles can't crash.

Quartz still has `throw`/`panic` available inside actor handlers — so we
**can't take Pony's route**, we need OTP-style supervision. But Pony's
framing is useful: **Supervisor handles the residual failures that
escaped the type system, not "any error anywhere."**

### Java 21 `StructuredTaskScope` — the modern non-actor take

Explicit choice: **no restart strategy in stdlib.** `ShutdownOnFailure`
is "all-or-nothing without restart"; the caller decides whether to
retry. Lesson: **keep restart orthogonal to the spawn/scope primitive.**
Quartz already has B.7 Scope; Supervisor builds on top, doesn't replace.

### Elixir GenStage / Broadway — the "millions of supervised workers" pattern

`ConsumerSupervisor` supports **only `:one_for_one`** because at 5M
children, `one_for_all` would be a denial-of-service primitive. Broadway
explicitly chose backpressure (pull-based demand) over unbounded
mailboxes — the real scale tax is `mailbox memory × N tasks`. **The
Soul-of-Quartz 5M-task headline depends on this discipline; the
supervisor needs to be cheap, but the dominating cost is per-actor
mailbox memory.**

---

## Quartz `std/actor.qz` — the surface we're building toward

### Phase 1 — `Supervisor` static, one_for_one, permanent restart

The smallest viable BEAM-in-a-box piece. Closes SOUL.6's
"supervisor restart" demo. Concrete API:

```be
import * from actor

# Spawn-factory closure returns a fresh actor inbox.
def spawn_counter(): Int = Counter()

# Static supervisor over a fixed set of children, all permanent-restart,
# one_for_one. intensity = max_restarts per period_ms. On escalation,
# the supervisor stops all children and the watcher exits (signaling
# escalation to the caller via supervisor_alive() == 0).
var sup = supervisor_new(
  vec_of(spawn_counter, spawn_counter, spawn_counter),
  max_restarts: 5,
  period_ms: 10000,
)

# Get the latest inbox for child i. Refreshed across restarts.
# Blocks (yields) briefly during the restart gap if i's slot is closed.
var c = supervisor_child(sup, 0)
c.crash()                # actor crash → supervisor respawns
sleep_ms(10)
var c2 = supervisor_child(sup, 0)   # new fresh inbox after restart
assert_eq(c2.get(), 0)              # OTP semantics: fresh state

# Synchronous shutdown: cancel watcher, stop all children, return.
supervisor_stop(sup)
```

**Data model:**

```be
struct SupervisorChild
  spawn_fn: Fn(): Int      # closure that spawns the actor
  inbox: Int                # current inbox (refreshed on restart)
end

struct Supervisor
  children: Vec<SupervisorChild>
  max_restarts: Int
  period_ms: Int
  restart_count: Int        # restarts within current window
  window_start_ms: Int      # rolling window anchor
  done: Int                 # 1 = shutdown requested
  watcher: Int              # task handle for the watcher goroutine
  escalated: Int            # 1 = max_restarts exceeded; watcher exited
end
```

**Watcher loop:**

```be
def _supervisor_watcher(sup: Supervisor): Int
  while sup.done == 0 and sup.escalated == 0
    var i = 0
    while i < sup.children.size
      var child = sup.children[i]
      if channel_closed(child.inbox) == 1
        # Inbox closed = crash or explicit stop. Either way, respawn.
        if _supervisor_count_restart(sup) == 0
          sup.escalated = 1
          _supervisor_stop_all(sup)
          return -1
        end
        sup.children[i].inbox = child.spawn_fn()
      end
      i = i + 1
    end
    sched_yield()
  end
  return 0
end
```

**Tradeoff: polling vs. side-table waker.** Phase 1 uses `sched_yield`
polling for simplicity. C.13's `__qz_waiters` side-table is the
correct active-wake mechanism (channel_closed → wake watcher); deferred
to Phase 2 because it requires a new waiter-kind tag for "channel
*close* event" vs. "channel recv-readiness". For SOUL.6 (a single
demo button, a handful of supervised actors), sched_yield-cadence is
fine.

**Why this minimum is enough:**

1. **SOUL.6's supervisor-restart demo works** — explicit `.stop()` on a
   supervised actor triggers respawn; the user sees the cascade.
2. **The pitch paragraph becomes true** — "spawn with `actor`, supervise
   with `Supervisor`" is now a real workflow.
3. **It composes with B.7 Scope** — supervisor's watcher task runs
   under `current_scope()`; scope cancel cascades into `supervisor_stop`.
4. **It composes with C.13 Select** — actor method-async returns a
   channel that's already `recvable()`-Selectable. No new wrapper.

### Phase 2 — restart strategies + intensity/period docs

- Port `one_for_all` and `rest_for_one` from `supervisor_tree`,
  adapted for inbox-close detection.
- Document the intensity/period defaults (1 / 5s, matching Erlang).
- Add `supervisor_with_intensity(spawns, strategy, max_restarts,
  period_ms)` as the strategy-explicit constructor.
- Active-wake retrofit: register watcher on `__qz_waiters` for each
  child inbox; replace sched_yield polling with sched_wake. New
  waiter-kind tag for "channel close event" — `handle | 2` (recv = `handle`,
  send = `handle | 1` per C.13.6; close = `handle | 2`).

### Phase 3 — DynamicSupervisor (the "millions of supervised workers" path)

Soul-of-Quartz 5M-task headline can't ship without this. Surface:

```be
var dsup = dynamic_supervisor_new(spawn_worker, max_restarts: 1,
                                  period_ms: 5000)

# Spawn N supervised workers dynamically.
for i in 0..5000000
  dynamic_supervisor_spawn(dsup)
end

# Get current child count, restart counts, etc. for telemetry.
var n = dynamic_supervisor_alive(dsup)
```

Same restart machinery, only_one_for_one (per Elixir/Broadway), but
spawn-on-demand.

#### Scale prerequisite — hashmap waiter table (LOCKED 2026-05-10)

At 5M children each registered on the close-event waker key, the current
`@__qz_waiters` table (linear array of 256 (target_key, waiter_frame)
pairs, statically-sized; `codegen_runtime.qz` lines 3190 + 3519-3532)
is wrong on three independent dimensions:

1. **Static cap=256.** At 5M children we'd silently drop ~99.995% of
   registrations. The cap is the original Phase-5 throughput-bounded
   sizing for a handful of selects per program; never sized for actor
   supervision.
2. **O(N) register / unregister / notify_all.** Linear scan over the
   whole table for every operation. Even if we resized the cap, every
   close-event notify_all would walk 5M entries to find one match.
3. **Single global mutex.** Every register/unregister/notify across
   the whole program serializes on one pthread_mutex. At 5M children
   the supervision tree's lifecycle ops contend with every other
   waiter op.

**Decision (2026-05-10):** rewrite as a hashmap. Take the right
primitive, not the cheap one. Per-class waiter-key alternative
(`@dsup | 3` notified by every child's close) was considered and
**rejected** — it'd require a back-link field on every actor frame
to its supervisor, adds a notify per close to every actor, and the
hashmap is the cleaner long-term answer that unblocks scale across
all waiter consumers (task / mutex / channel / close-event), not
just dynamic supervision.

**Shape:**

- Separate chaining hashmap. Bucket array of head pointers; each
  bucket cell stores `(target_key, waiter_frame, next_ptr)` triple
  (24 bytes per entry).
- Initial bucket count = 256 power-of-two. Grow with rehash at load
  > 0.75. Shrink lazily on unregister (never reclaim unless
  explicitly compacted — irrelevant for the supervisor workload
  where N stabilizes).
- Hash function: target_key mixed with a Splitmix64-style scramble
  (target_key is a pointer with low-bits patterns from malloc
  alignment — direct modulo would bias every bucket toward the same
  alignment class).
- Lock granularity: striped mutexes, NSTRIPES = 64 (or NWORKERS *
  4). Each bucket maps to `stripe = bucket_idx % NSTRIPES`. Grow
  acquires all stripes in order.
- Operations:
  - `register(target, waiter)`: hash → bucket → lock stripe → walk
    chain for dedup → prepend new cell → unlock. O(1) avg.
  - `unregister(target, waiter)`: hash → bucket → lock stripe →
    walk chain → unlink → unlock. O(1) avg.
  - `notify_all(target)`: hash → bucket → lock stripe → walk chain
    collecting waiter_frames into a stack buffer → unlock → fire
    `sched_wake` on each (out-of-lock). O(matches), not O(total).

**Migration path** (gen0 → gen1 → gen2 bootstrap discipline):

1. Land hashmap impl in `codegen_runtime.qz` as a NEW function set
   (`__qz_waiter_register_hm`, `__qz_waiter_unregister_hm`,
   `__qz_waiter_notify_all_hm`). Old `_register` / `_unregister` /
   `_notify_all` stay alive.
2. Flip the codegen sites (intrinsic emit paths in
   `cg_intrinsic_conc_sched.qz` and `cg_intrinsic_conc_channel.qz`)
   to call the `_hm` variants.
3. Quake guard with binary built using NEW codegen calling NEW
   runtime. Fixpoint should be byte-identical except for IR
   call-site names.
4. Delete the old array-based `_register` / `_unregister` /
   `_notify_all` definitions. Rename `_hm` → no-suffix. Stamp
   fixpoint again.

**Verification load test:** spawn 100K actors under a single
supervisor, kill 50K, time the watcher's observation latency. With
the array table this would be a 100ms+ pause (200K notify_all walks
× 100K-entry table). With the hashmap it's O(matches) = ~50us.

#### Phase 3 stdlib surface (after hashmap prerequisite ships)

`std/actor.qz` gains:

```be
struct DynamicSupervisor
  spawn_fn: Fn(): Int       # closure that spawns one child
  children: Vec<Int>        # current inboxes (grows on spawn)
  max_restarts: Int
  period_ms: Int
  restart_count: Int
  window_start_ms: Int
  done: Int
  escalated: Int
  watcher: Int
  children_lock: Int        # pthread_mutex for children Vec
end
```

The watcher loop is structurally identical to `_supervisor_watcher`
except it walks `children` under `children_lock` (Vec grows on spawn,
shrinks via swap-remove on terminal death under
SUPERVISOR_PERMANENT-equivalent semantics — actually for Phase 3 we
keep the slot and reuse it on respawn).

Telemetry hooks (SOUL.4): `dynamic_supervisor_alive(dsup) -> Int`
(child count), `dynamic_supervisor_iter(dsup, f: Fn(Int): Void) ->
Void` (walk current children, used by `/api/soul/stats.json` to
report per-child mailbox depth).

### Phase 4 — restart types + PreRestart hook

- `Permanent` (Phase 1 default), `Transient` (only restart on crash, not
  on clean stop), `Temporary` (never restart). Requires distinguishing
  "inbox closed due to crash" from "inbox closed due to clean `.stop()`"
  — needs a small protocol change in the actor poll loop (close with
  a "reason" tag stored in a sidecar table).
- `PreRestart` signal: a method the actor can opt into; called by the
  supervisor before respawn so `Scoped` resources can be released.

### Phase 5 — restart with backoff

Akka's `(min_backoff, max_backoff, random_factor)` shape. Exponential
doubling, jitter, counter resets after stable uptime. Needed for
crash-loop containment when intensity escalation isn't appropriate.

### Phase 6 — docs sweep + decision tree (shipped C.14.6, 2026-05-11)

- `docs/QUARTZ_REFERENCE.md` "Actors (C.14)" section added under
  `## Concurrency` — decision tree (actor X vs go+channels vs
  Supervisor), keyword surface, `Supervisor` / `DynamicSupervisor`
  surface, restart-type matrix, backoff semantics, PreRestart hook,
  surface summary table.
- `docs/EFFECTS.md` §7.7 "Actors and effects" added — covers
  effect-stack snapshot inheritance (E.1.c.b) and scope propagation
  (B.7 Phase 4) across actor boundaries. Documents the "captured at
  spawn, not at dispatch" semantics + the four implications
  (sandboxing per-actor, Log/Diag capture, State<S>/Reader<R>
  inheritance, Throws snapshot) and the two non-features (idle
  mailbox not throw-aware, State<S> write-back doesn't propagate
  back to the spawning task's slot).

---

## Open design decisions

### D1. Mailbox semantics on restart — fresh or preserved?

**Decision: fresh.** OTP-style. The old PID is dead; messages
addressed to its inbox are addressed to a closed channel, which is
already how Quartz's existing language-level `actor` stop semantics
work. Akka preserves the mailbox by default, but Akka's typed-actor
model has explicit `ActorRef` indirection that survives restart; we
don't.

If a caller wants delivery guarantees across actor restart, that's a
separate `at_least_once` overlay (out of scope for C.14).

### D2. Per-actor crash vs. per-handler crash — keep current behavior?

**Decision: keep current behavior for Phase 1.** The scheduler-side
per-handler recovery (drop reply, preserve state, continue) is useful
for non-critical methods and is already proven (`actor_spec.qz:197`).
Supervisor watches for inbox close, which is the coarse failure event
(`.stop()`, link-cascade-stop). Phase 4 adds opt-in `actor_die(self)`
for "this handler was so bad I want the supervisor to restart me"; this
is the Erlang `exit(self(), abnormal)` equivalent.

### D3. Should `Supervisor` integrate with B.7 Scope?

**Decision: yes, implicitly.** The watcher task runs under
`current_scope()` (via `go_spawn` which captures scope). When the parent
scope cancels, the watcher observes via the standard scope-aware
blocking primitive substrate and shuts down all children. No new API
needed; B.7's machinery does the work.

### D4. Why not unify with `supervisor_tree`?

`supervisor_tree` operates on `Vec<Fn(): Int>` where each closure is a
goroutine body. Adapting it to actor inboxes (poll for close, respawn
fresh) is a different control flow than its current "await each task,
restart-on-`-1`" model. **Phase 2 may share the strategy
implementation** (the one_for_all / rest_for_one bookkeeping is
identical), but the API stays separate. Don't expose
`supervisor_tree`'s `Vec<Fn(): Int>` shape to users who think in actors.

### D5. Naming — `Supervisor` vs `ActorSupervisor` vs `supervise()`?

**Decision: `Supervisor` (struct), `supervisor_new()` (constructor).**
Standalone names because the module is `std/actor` — calling it
`actor::Supervisor` and `actor::supervisor_new` already disambiguates
from `supervisor_tree` (which stays in `std/concurrency.qz` as the raw
primitive).

---

## Sequencing — what ships first, what gates the rest

```
Phase 1 (this work)
  ├─ docs/design/ACTOR_MODEL.md  ← this doc
  ├─ std/actor.qz
  │   ├─ struct SupervisorChild, struct Supervisor
  │   ├─ supervisor_new, supervisor_child, supervisor_stop
  │   └─ _supervisor_watcher (private), _supervisor_count_restart (private)
  └─ spec/qspec/actor_supervisor_spec.qz
       ├─ supervisor restarts on .stop()
       ├─ supervisor restarts on link-cascade close
       ├─ supervisor preserves child indexing across restarts
       ├─ supervisor escalates on max_restarts exceeded
       └─ supervisor_stop is idempotent + cascades

Phase 2 (next session)
  ├─ one_for_all, rest_for_one strategies
  ├─ intensity/period explicit constructor
  └─ active-wake retrofit (channel-close waker, kind=2)

Phase 3 (Soul-blocking)
  └─ DynamicSupervisor

Phase 4 (semantic refinement)
  ├─ restart types (Permanent | Transient | Temporary)
  └─ PreRestart hook (bind to trait Scoped)

Phase 5 (failure containment)
  └─ restart_with_backoff (Akka signature)

Phase 6 (docs)
  ├─ docs/QUARTZ_REFERENCE.md "Actors" section
  └─ docs/EFFECTS.md "Actors and effects"
```

Phase 1 unblocks SOUL.6. Phase 3 unblocks SOUL.5 (5M-task headline).
Phase 4+5 unblock the launch-blog pitch about "complete BEAM
supervision." Phase 6 is the close.

---

## What this design does NOT include (and why)

- **`Actor<S>` orthogonal stdlib type with runtime-polymorphic
  behavior closures.** The roadmap row mentioned this as one option;
  we're not building it. The language-level `actor X ... end` keyword
  is the spawn primitive and we're not shipping two ways to spawn
  actors — the user-facing API would be confused and the compile-time
  Send-validation story would have to be duplicated. **Decision in
  this session, 2026-05-10.**
- **`actor.become(new_behavior)` for state-machine transitions.** Not
  in Phase 1-5. Erlang/OTP `gen_statem` is the analog; Akka has
  `Behaviors.receive(...)` returning the next behavior. Quartz's typed
  actors can do this via explicit state-machine encoding in the actor's
  field (`var state: PhaseEnum`); a method like `def transition(to:
  PhaseEnum): Void = @state = to` is the user-level workaround. Real
  `become` requires the actor's method dispatch table to be runtime-
  swappable, which is a much bigger codegen change. **File for
  post-launch consideration; not blocking the pitch.**
- **Mailbox-as-Selectable on the actor's inbox.** Users don't recv
  directly from the mailbox in the typed-method-dispatch model; the
  poll loop is auto-generated. A user-facing `select case msg =
  recvable(actor_self.mailbox) => ...` would have to break out of the
  typed dispatch model. Not in scope.
- **Per-actor priority / fairness.** Erlang has `process_flag(priority,
  high)`. Not in scope; scheduler-level decision deferred to KERN.8
  follow-on.

---

## References

- [Erlang Supervisor Behaviour](https://www.erlang.org/doc/system/sup_princ.html)
- [Erlang stdlib supervisor module](https://www.erlang.org/doc/apps/stdlib/supervisor.html)
- [Akka Typed Fault Tolerance](https://doc.akka.io/libraries/akka-core/current/typed/fault-tolerance.html)
- [Pony Tutorial — Errors](https://tutorial.ponylang.io/expressions/errors.html)
- [Java 21 StructuredTaskScope.ShutdownOnFailure](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/StructuredTaskScope.ShutdownOnFailure.html)
- [Elixir DynamicSupervisor](https://hexdocs.pm/elixir/DynamicSupervisor.html)
- [Elixir GenStage ConsumerSupervisor](https://hexdocs.pm/gen_stage/ConsumerSupervisor.html)
