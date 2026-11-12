## Unified `Scope` — Cancellation, Deadlines, and Structured Concurrency (B.7)

**Status**: Design — implementation staged across follow-up sessions.
**Scope**: Collapse Quartz's four independent cancellation/deadline mechanisms
into a single `Scope` value that carries cancellation, optional deadlines, and
parent/child structural relationships. Pairs with B.9 (error unification) for
the cancellation transport, with C.13 (generalized `select`) for the wait
side, and with B.8 (`with`-scoped resource acquisition) for the
acquire side.

## The current state

Quartz today has **four** independent cancellation/deadline mechanisms with
overlapping semantics:

| Mechanism | Surface | Carrier | Propagation | Wait integration |
|---|---|---|---|---|
| `go_cancellable(f, tok)` / `go_cancel_on_success(f, tok)` | Explicit `Int` token threaded into spawn calls | `cancel_token_*` intrinsic family (`cancel_token_new` / `_cancel` / `_is_cancelled` / `_with_deadline` / `_free`) | None — caller wires children manually | Polled at suspension points; not selectable |
| `await_with_timeout(fut, ms)` (a.k.a. `async_timeout` / `sched_timeout`) | Per-call deadline | Internal channel + `recv_timeout` or `select` arm | None | Built on the channel/select primitive |
| `select` with `timeout(ms) =>` arm | Per-`select` deadline | Compile-time arm | None — only this `select` | Native to the primitive |
| `go_scope` / `go_supervisor` / `go_scope_timeout` / `scope_cancel_on_failure` / `supervisor_tree` | Block-scoped child lifetime | Module-global `_current_scope_*` ambient state (one level deep — does **not** nest) | Implicit "wait for all children" + manual cancel-on-failure plumbing | None |

Three problems:

1. **Each block primitive carries its own cancellation channel.** Switching
   from "cancel via token" to "cancel via timeout" means a different API.
   Switching from "cancel a single goroutine" to "cancel the entire enclosing
   scope" means a different primitive. There is no shared notion of "the
   dynamic extent of this concurrent work."
2. **The structured-concurrency primitives (`go_scope`, `go_scope_timeout`)
   keep their state in module-global variables (`_current_scope_children`,
   `_current_scope_token`, `_current_scope_strategy`, `_current_scope_active`)
   — saved and restored by hand.** They do not nest correctly across worker
   threads (each worker would clobber the other), and re-entry from a
   different call path observes the wrong "current scope." The save/restore
   discipline is brittle and has zero compile-time enforcement.
3. **Wait composition does not exist.** A user cannot write "wait until
   either this channel sends OR my scope is cancelled OR my deadline expires."
   The only composable form is `select` over channels, and `select`'s
   `timeout` arm is a per-`select` deadline, not a propagated one.

## What we're shipping

A single first-class `Scope` value, carrying cancel state + optional deadline +
parent pointer, propagated through TLS (matching the effect-stack model from
E.1.c.b). Every blocking primitive consults the current scope; cancellation
propagates structurally down the scope tree.

| Concept | Today | Unified |
|---|---|---|
| "Cancel this work" | `cancel_token_cancel(tok)` (manual token threading) | `scope.cancel()` (descendants auto-cancelled) |
| "Cancel after N ms" | `cancel_token_with_deadline(ms)` OR `await_with_timeout(fut, ms)` OR `select { ... timeout(ms) => ... }` | `with scope.timeout(ms) do -> body end` (block-scoped, descendants inherit, exit auto-cancels) |
| "Wait for cancellation" | None — only checked at suspension points | `select { case _ = scope.cancelled() => ...; case msg = ch.recv() => ... }` (composes with C.13's generalized `select`) |
| "Spawn child whose lifetime matches this scope" | `go_cancellable(f, tok)` (manual token + explicit cleanup) | `go fn()` inside scope body — child inherits scope, dies with it |
| "Supervised scope (siblings independent on failure)" | `go_supervisor` / `supervisor_tree` (module-global state) | `with scope.supervised() do -> body end` (proper nesting) |

### API surface (`std/sync/scope.qz`)

```be
struct Scope { _: Int }   # opaque handle

## Get the current scope. Always returns a valid scope (root if none nested).
def current_scope(): Scope
## Get the root scope. Lives forever, cannot be cancelled.
def root_scope(): Scope

## Create a child scope.
##   timeout — child cancels at parent_remaining_ms or `ms`, whichever is sooner.
##   deadline — child cancels at absolute_ns or parent_deadline, whichever is sooner.
##   with_cancel — caller-controlled cancel; returns scope + cancel function.
def Scope.timeout(self, ms: Int): Scope
def Scope.deadline(self, absolute_ns: Int): Scope
def Scope.with_cancel(self): (Scope, Fn(): Void)
def Scope.supervised(self): Scope   # children independent on failure

## Inspection.
def Scope.is_cancelled(self): Bool
def Scope.cancelled_at(self): Option<Int>          # ns since epoch, for diagnostics
def Scope.deadline_remaining_ms(self): Option<Int>  # None = no deadline
def Scope.cancel_reason(self): Option<String>       # "cancelled" / "deadline_exceeded" / user-supplied

## Cooperative checkpoint — throws "cancelled" / "deadline_exceeded" if cancelled.
def Scope.check(self): Void

## Selectable — returns a Selectable that fires once when this scope cancels.
##   (depends on C.13 — until C.13 ships, B.7 ships scope.wait_cancelled() instead,
##    a blocking primitive that suspends the current task until cancellation.)
def Scope.cancelled(self): Selectable

## Manual cancel (descendants auto-cancelled).
def Scope.cancel(self): Void
def Scope.cancel_with(self, reason: String): Void
```

### `with`-block sugar

```be
# Block-scoped scope: created on entry, cancelled on exit (normal OR throw).
with scope.timeout(5_seconds) do ->
  result = expensive_call()        # consults scope; returns or throws on cancel
end

# Equivalent expansion — what the desugar emits.
var s = current_scope().timeout(5_seconds)
__qz_scope_push(s)
with Throws { throw: __qz_scope_rethrow_unless_cancel } do ->
  result = expensive_call()
end
__qz_scope_pop()
s.cancel()                         # idempotent — fires once, drops timer if armed
```

`with scope.X do ... end` is the canonical entry point. Standalone
`current_scope().timeout(ms)` is allowed but loses the auto-cancel-on-exit
guarantee — discouraged in style guidance.

### Spawn semantics

Goroutines inherit the spawn-time `current_scope` (matching E.1.c.b's
effect-snapshot pattern). Each spawned task's `current_scope` is fixed at
spawn time and propagates to its own children.

```be
with scope.timeout(5_seconds) do ->
  go fn()       # fn runs under the same 5s deadline
  go gn()       # gn runs under the same 5s deadline
end             # exit cancels scope; both fn and gn observe cancellation
```

### Decision tree (commit to docs)

When writing concurrent code, ask:

1. **Do I need "wait for child work, propagate cancel"?** → `with scope.X do
   -> ... end` block (timeout/deadline/with_cancel/supervised) and
   `go fn()` inside. The block is the unit of cancellation.

2. **Do I need a manual checkpoint inside a long-running CPU-bound function
   that doesn't suspend?** → `current_scope().check()` at loop iterations or
   batch boundaries. Throws on cancel; caller handles via `with Throws`.

3. **Do I need to compose "wait on channel OR cancellation OR deadline"?** →
   `select` with `case _ = current_scope().cancelled() => ...` arms (depends
   on C.13).

4. **Do I need supervisor-tree restart strategies?** → `with scope.supervised()`
   block + `supervised(max_restarts, body)` higher-level wrapper. Restart logic
   lives outside the scope; the scope itself only handles cancellation.

5. **Do I need OS-thread cancellation semantics?** → Not supported. Quartz's
   M:N scheduler cancels at suspension points and at explicit `check()` calls.
   Truly preemptive cancellation requires signal-based stack unwinding which
   we explicitly reject (per the existing cooperative-cancellation stance).

## Prior art

| System | Cancellation model | What we take | What we reject |
|---|---|---|---|
| **Go `context.Context`** | Tree of contexts, explicit `ctx` parameter threading; `ctx.Done()` returns a channel; `WithCancel`/`WithTimeout`/`WithDeadline`/`WithValue` constructors | Tree-of-contexts model; deadline auto-derives from parent; explicit `Done()` for `select` integration | Explicit `ctx` parameter threading (infectious, often skipped); `WithValue` (ad-hoc key-value bag, criticized in Go community); manual cleanup via `defer cancel()` |
| **Trio (Python) nursery + cancel scope** | `async with trio.open_nursery()` makes a structural block; `move_on_after(seconds)` and `fail_after(seconds)` for deadlines; `CancelScope` is independent of nursery; cancellation happens at every `await` checkpoint | Structural impossible-to-leak block (`with scope.X do ... end`); checkpoint-based cancellation; cancel scopes nest correctly; explicit `scope.cancel()` distinct from "scope finished naturally" | Decoupling cancel scope from the nursery (Quartz keeps them unified — the scope IS the nursery); checkpoint at every `await` (Quartz checks at primitive entry + explicit `check()`, not blanket) |
| **Kotlin `coroutineScope` / `supervisorScope` / `withTimeout`** | `Job` hierarchy = cancellation tree; child failure cancels siblings (coroutineScope) or doesn't (supervisorScope); `withTimeout(ms) { body }` block-level deadline; `CancellationException` thrown at suspension points; `isActive` for cooperative checks | Block-level deadline syntax (`with scope.timeout(ms) do ... end` mirrors `withTimeout`); supervised vs unsupervised distinction; throw-based cancellation propagation (pairs with B.9) | `CoroutineContext` as a multi-element bag (Job + Dispatcher + Name + ExceptionHandler) — Quartz's TLS already carries dispatcher/effect-stack separately; `ExceptionHandler` (Quartz uses Throws for this) |
| **Erlang link/monitor + supervision tree** | Bidirectional `link(Pid)` (mutually-linked processes die together); `monitor(process, Pid)` for unidirectional notification; one_for_one / one_for_all / rest_for_one restart strategies | Supervisor restart strategies (already partially in `supervisor_tree`); link for "die together" semantic in actor pairs; "let it crash" philosophy | No deadline primitive; cancellation = sending exit signal, not a structural property of work scope; pure message-passing, no shared cancel flag |
| **Swift `withTaskGroup` / `Task.checkCancellation()`** | `withTaskGroup(of: T) { group in ... }` structured group; `group.cancelAll()` propagates; `Task.checkCancellation()` throws `CancellationError`; `Task.isCancelled` for soft check | Group-level `cancelAll` semantic; `Task.checkCancellation()` model (= our `scope.check()`); throw-based propagation | `Task.detached` (always-leaks form) — Quartz prohibits this entirely; per-Task cancellation handle (Quartz's handle is the scope, not the task) |
| **Tokio `CancellationToken` + `tokio::time::timeout`** | Explicit token, manually wired; `timeout(duration, future)` per-future deadline; `tokio::select!` for waiting on multiple futures including cancellation | Per-future timeout combinator (we get this for free as `with scope.timeout do -> await fut end`) | Explicit token threading (matches Go's downside); separate timeout from token (we unify them) |
| **Rust async-std `JoinSet` + ad-hoc** | `JoinSet` collects spawned tasks; `abort_all()` cancels them; no first-class scope; structured-concurrency RFC pending | The "open RFC" status is itself signal — async Rust hasn't settled this, so taking the Trio/Kotlin design point is the safer bet | The "ad-hoc" status — we ship a single canonical primitive |

### Synthesis

Quartz's design takes Trio's structural impossible-to-leak guarantee, Kotlin's
`withTimeout { ... }` block syntax, Go's tree-of-contexts deadline derivation,
Swift's `Task.checkCancellation()` checkpoint model, and Erlang's restart
strategies for the supervisor layer — and ties them together with **Quartz's
existing effect-stack TLS pattern + Throws-based unwinding**. The result is
the first cancellation primitive that:

- Has Trio's structural guarantees (no leaked work),
- Has Go's deadline derivation,
- Has Kotlin's `withTimeout` ergonomics,
- Composes with `select` like Go's `<-ctx.Done()` does,
- Routes cancellation through the same Throws mechanism as B.9's panic/throw
  unification (one transport, two surfaces),
- Does **not** require explicit parameter threading (TLS propagation, not
  `can Scope` row-cascade — see Open Question 1).

## Implementation staging

Five phases. Each phase is independently verifiable; later phases can be
deferred without rolling back earlier ones. The total estimate is
**~5-7 quartz-days** (down from the row's "1-2 quartz-weeks" because the
substrate — TLS effect-stack discipline, M:N suspend/resume, structured
concurrency primitives — is already built).

### Phase 1 — Design memo ✅ (this document)

Captures rationale, prior art, API surface, decision tree, and the
sub-phase plan. **Done.**

### Phase 2 — `Scope` substrate (no integration)

`std/sync/scope.qz` ships:

- `Scope` struct (handle to a runtime scope-node).
- Runtime scope-node layout (`__qz_scope_*` allocator + tree manipulation):
  parent pointer, child list, atomic cancel flag, deadline (i64 ns absolute,
  -1 = no deadline), cancel-reason string slot.
- Constructors: `root_scope()`, `Scope.timeout(self, ms)`,
  `Scope.deadline(self, ns)`, `Scope.with_cancel(self)`,
  `Scope.supervised(self)`.
- Inspection: `Scope.is_cancelled`, `Scope.cancelled_at`,
  `Scope.deadline_remaining_ms`, `Scope.cancel_reason`.
- Mutation: `Scope.cancel(self)`, `Scope.cancel_with(self, reason)`.
- Tree propagation: cancelling a parent walks the child list, cancels each.

**No TLS integration yet, no spawn integration, no primitive integration.**
Just the substrate. Spec covers create/cancel/deadline/parent-derives-min-deadline/
descendant-cancellation.

**Estimate: ~1 quartz-day.** Substantial code (likely ~300 LOC stdlib + intrinsics
for the atomic flag and the deadline timer registration), but bounded scope.

### Phase 3 — TLS scope + `with scope.X do ... end` desugar

- TLS pointer `@__qz_current_scope` (default = root).
- `current_scope()` reads it; `__qz_scope_push(s)` / `__qz_scope_pop()` for the
  desugar.
- Parser recognizes `with <expr_returning_scope> do -> body end` and emits the
  push/pop bracket plus auto-`s.cancel()` on exit (idempotent — second cancel
  drops the deadline timer if armed but is otherwise a no-op).
- `Scope.check(self)` — explicit cooperative checkpoint, throws via the unified
  Throws mechanism (`throw "cancelled"` or `throw "deadline_exceeded"`,
  matching B.9's panic-as-throw shape).

**Estimate: ~1 quartz-day.** Parser change is small (mirrors existing `with E
do ... end` parse path). Most work is in the runtime scope-stack management
+ Throws integration on `check()`.

### Phase 4 — Spawn inheritance + primitive integration

- `go fn()` / `go fn(args)` snapshots `current_scope()` at spawn time,
  registers it on the task frame (slot reuse from E.1.c.b's effect-snapshot
  approach — same mutex-protected map, different table).
- Worker `$poll` dispatch loads the task's scope into TLS at poll entry,
  restores at poll exit (mirrors snapshot apply/drop).
- Primitives consult `current_scope()`:
  - `recv(ch)` / `send(ch)`: register a waker on scope; on scope cancel, wake
    immediately and return cancellation result (or throw, see Open Question 3).
  - `mutex_lock(m)` / `rwlock_read(rw)` / `rwlock_write(rw)`: same — register
    waker, wake on cancel.
  - `await fut`: same — wake on cancel.
  - `sleep(ms)`: clamp to scope's deadline_remaining_ms; cancel = early wake.
  - `io_suspend(fd)`: cancel = early wake.
- Deadline timer: `__qz_sched_register_deadline(scope, ns)` registers a timer
  callback that fires `scope.cancel_with("deadline_exceeded")`. Existing
  `__qz_deadline_thread` in the runtime is the substrate.

**Estimate: ~2 quartz-days.** Most invasive phase — touches every blocking
primitive in the codegen runtime. Primitive-by-primitive migration with
regression tests at each step.

### Phase 5 — Existing-primitive migration + dead code deletion

Migrate all four legacy mechanisms to thin Scope wrappers, then delete the
internals (no compat shims — Stance 5):

- `go_cancellable(f, tok)` → `with current_scope().with_cancel() do | s,
  cancel | -> if tok wired -> spawn cancel hook on tok-fire to call
  cancel(); go _go_arena_body(f) end`. Then deprecate `cancel_token_*` API
  in the same commit as proving the Scope substrate covers it.
- `await_with_timeout(fut, ms)` / `async_timeout(f, ms)` /
  `sched_timeout(f, ms)` → `with scope.timeout(ms) do -> await fut end`
  with the cancellation result wrapped as `Option<T>`.
- `go_scope`, `go_scope_timeout`, `go_supervisor`, `scope_cancel_on_failure`
  → thin wrappers around `with scope.timeout(ms) do -> body end` /
  `with scope.supervised() do -> body end` that preserve current return
  type (Vec<Int> for supervisor; -1/-2 sentinels for scope variants —
  candidate for migration to Result<T, E> per B.9).
- Module-global `_current_scope_*` ambient state in `std/concurrency.qz` —
  **deleted entirely**. The scope tree replaces it.
- `select`-with-`timeout(ms)`-arm — surface stays, lowering changes to
  materialize a transient scope and use its cancellation as the wakeup signal.

**Estimate: ~1 quartz-day.** Mostly mechanical once the substrate exists.
The `_current_scope_*` deletion is the cleanup payoff.

### Phase 6 — Documentation

- `docs/QUARTZ_REFERENCE.md` "Concurrency" section gains a "Scope and
  Cancellation" subsection that leads with the two-paragraph mental model +
  decision tree.
- `docs/STYLE.md` adds "Cancellation" guidance: prefer `with scope.X do ... end`
  over manual token threading; always wire long CPU-bound loops with
  `current_scope().check()`.
- `docs/design/SCOPE_UNIFICATION.md` — this memo, retained as the rationale.
- `CLAUDE.md` anti-hallucination table updated to note the deprecation of
  `cancel_token_*` (now thin wrappers) and the unified scope mental model.

**Estimate: ~0.5 quartz-day.** Pattern matches B.9 Phase 5.

## What B.7 explicitly does NOT do

- **It does not introduce `can Scope` row-propagation through function
  signatures.** Scope is propagated through TLS (matching the effect-stack
  pattern). Adding it to the row would tax every signature that "might cancel"
  — i.e., almost every function — for no checking benefit (see Open Question 1).
- **It does not introduce signal-based preemptive cancellation.** Quartz's
  M:N scheduler cancels at suspension points and at explicit `check()` calls.
  Long CPU-bound loops without checkpoints are uncancellable by design;
  callers are expected to add `current_scope().check()` at appropriate
  granularity.
- **It does not introduce per-CPU work-stealing scope-affinity.** All workers
  see the same scope tree; no per-CPU view. Deferred to a future P-phase if
  contention measurement shows the scope tree's atomic operations to be a
  hotspot (which seems unlikely — cancellation is rare relative to scheduler
  ticks).
- **It does not unify with `Throws` as a single mechanism — it _composes_ with
  it.** Cancellation transport rides `throw "cancelled"` / `throw
  "deadline_exceeded"` (B.9's unified throw), but `Scope` itself is a separate
  abstraction with its own state. They rhyme structurally; collapsing them
  further would conflate "this is a bug" (panic) with "this work is no longer
  needed" (cancel) — the intent is genuinely different.
- **It does not change `Result<T, E>`.** Result remains the value-level error
  mechanism. Cancellation surfaces via the control-flow-level mechanism
  (Throws), as it should.
- **It does not introduce structured concurrency for OS-thread `spawn`.** The
  scope tree only governs the M:N scheduler's goroutines. `spawn` (raw
  `pthread_create`) is the explicit "I am taking responsibility for this
  thread's lifetime" escape hatch and intentionally bypasses scope semantics.
  Most users should not use `spawn` directly.
- **It does not deprecate `task_group`** (the lower-level `task_group |g| ...
  end` + `taskgroup_collect(g)` pattern). `task_group` becomes the explicit
  primitive that the structured-concurrency wrappers (`scope_supervised`,
  etc.) build on. User code can still drop down to it for fine control.

## Open questions (resolve before Phase 2 ships)

### 1. TLS propagation vs `can Scope` row-cascade

**Decision: TLS propagation, not row-cascade.**

The case for `can Scope` would be compile-time enforcement that any function
calling a blocking primitive declares cancellation propagation. Theoretical
benefit: the type system tells you which functions are cancel-aware.

The case against — and the reason we reject it — is that **almost every
function in real code transitively calls something that blocks.** A row with
that universality is just noise: every signature wears `can Scope`, the
annotation carries no information, and the cascade-tax discourages writing
the right thing. Sister to the Async/Throws blessed-relaxation pattern (which
exists exactly because the alternative was infectious annotations).

TLS propagation is also strictly more flexible: a non-blocking pure function
can opportunistically `current_scope().check()` without changing its
signature, and a wrapper that injects a different scope (test mocking, scope
isolation for an actor pool) can do so without rewriting every callee.

The downside is that "this function ignores cancellation" is not visible in
the type system — but the design point is that **all functions check
cancellation by virtue of the primitives they call doing so**. A function
that never blocks and never calls `check()` is correctly uncancellable.

### 2. Default behavior on uncancelled scope at exit

When a `with scope.timeout(5_seconds) do -> body end` block completes
naturally (body returns, no cancellation, no deadline fired), should the
exit-cancel be observable to in-flight children? Two options:

(a) **Block exit cancels the scope.** Any spawned-into-scope work that's
still running at block exit gets cancelled. This is Trio's nursery
semantic and the structural-concurrency norm.

(b) **Block exit waits for spawned children.** Like `go_scope` today —
block exit awaits all children before returning.

**Recommendation: (b), with explicit `with scope.timeout_cancel_on_exit do
... end` for (a).** The principle of least astonishment is that a
`with`-block's body is the unit of work, not a fire-and-forget zone.
Migrating from `go_scope` to `with scope.timeout` should keep the
"all-children-awaited" semantic as the default. Users who want the
fire-and-forget cancel-on-exit pattern can opt in.

This is equivalent to Kotlin's `coroutineScope { ... }` semantic (waits
for children) vs `launch { withTimeout { ... } }` (concurrent timeout)
distinction. We model the former with the default, the latter with an
explicit variant.

### 3. Cancellation as throw vs as result value

When `recv(ch)` is woken by scope cancellation, does it:

(a) **Throw `"cancelled"`** — pairs with B.9's unified Throws transport;
caller writes `with Throws { throw: cancel_recover } do -> recv(ch) end` to
recover.

(b) **Return a sentinel** — `recv(ch)` returns -1 (channel-closed sentinel)
or a distinguished `cancelled` value; caller checks return.

**Recommendation: (a), with the option to (b) via a wrapper.** Throw-based
cancellation matches Kotlin / Trio / Swift, composes with structured
exception flow, and doesn't require every blocking primitive to pick a new
sentinel value. The wrapper pattern (`Result<T, CancelError>`) is fine for
primitives that genuinely want to recover locally, but the default should
be "cancellation unwinds to the nearest Throws handler."

This pairs B.7 directly with B.9: the unified throw mechanism IS the
cancellation transport. A user who installs `with Throws { throw: handler }`
catches **both** application throws and scope cancellations, which is
correct — both are "exceptional control flow that the local function
doesn't claim to handle."

The risk: a user writing `recv(ch)` in a hot loop without expecting it to
throw will be surprised. The mitigation: documentation, lint rule, and the
structural fact that every `recv(ch)` in production code should already be
under a `with Throws` somewhere up the stack (because all `await fut` and
all `recv(ch)` could already throw via Throws today — B.7 doesn't change
the surface, only adds a new throw reason).

### 4. Selectable for `scope.cancelled()` — depends on C.13

C.13 (generalized `select`) defines a `Selectable` trait. Until C.13 ships,
B.7 ships a degraded form: `scope.wait_cancelled()` is a blocking primitive
that suspends until cancellation, intended for the "I need to wait on
cancellation specifically" case. When C.13 ships, the same scope-cancellation
machinery is wrapped as a `Selectable` and the `wait_cancelled()` API
becomes a thin wrapper.

**Sequencing**: B.7 ships before C.13. C.13's design memo (Phase 1 of C.13)
will lock in the Selectable trait shape, after which B.7 Phase 4 retrofits
`scope.cancelled(): Selectable` against the trait.

### 5. Snapshot scope vs reference scope at spawn time

When `go fn()` snapshots the current scope, does the spawned task hold a
**reference** to the scope (so cancelling that scope cancels the task) or
a **snapshot** (so the task runs as if under that scope at spawn time, but
later mutations don't affect it)?

**Decision: reference, with parent-pointer chain for descendant
cancellation.** The structural intent is "this task's lifetime is bounded
by this scope." A snapshot would let tasks outlive their scopes, defeating
the whole point.

The mechanism: each task frame carries a Scope handle (reference into the
scope-node table). Worker `$poll` dispatch loads it into TLS at poll entry.
Cancelling the scope walks descendants — including any tasks that snapshotted
into it — and wakes them.

The tradeoff: a long-lived background task spawned inside a short-lived
`with scope.timeout` block dies when the block exits. Users who want a
detached background task spawn it inside `root_scope()` explicitly:
`with root_scope() do -> go background_work() end`. This is a feature, not
a limitation — making detachment explicit prevents the most common
structured-concurrency leak.

## Out of scope for B.7

- **Per-scope memory accounting / quotas.** Could be a future M-phase but
  not part of B.7. Per-task arenas (Phase E) already give per-goroutine
  memory isolation, which covers most of the motivating use cases.
- **Scope-scoped logging context** (the moral equivalent of Go's
  `context.WithValue`). We explicitly reject this as a Scope feature; if
  users want scoped logging context, they install a custom Log handler
  via the existing Log effect.
- **Deadline propagation across IPC / network boundaries** (the OpenTelemetry
  W3C context-propagation pattern). Not a runtime concern; an HTTP client
  library can serialize the current scope's deadline into a header and the
  server can reconstruct on receive — that's a stdlib convention, not a
  runtime feature.
- **Stack trace capture on cancel.** Sister to B.9's stack-trace OOS.
  Adding it would be a separate runtime feature.

## Calibration

Original row sized at "M-L (~1-2 quartz-weeks)". Honest re-estimate after
this design pass:

| Phase | Estimate | Notes |
|-------|----------|-------|
| 1 (this memo) | ~0.3 quartz-day | Done. |
| 2 (scope substrate, no integration) | ~1 quartz-day | Self-contained; bounded scope; spec-driven. |
| 3 (TLS + with-block desugar + check()) | ~1 quartz-day | Parser change is a one-liner mirror; runtime is the substantial part. |
| 4 (spawn inheritance + primitive integration) | ~2 quartz-days | Most invasive — touches recv/send/await/mutex/sleep in codegen runtime. Migration is per-primitive with regression tests at each step. |
| 5 (legacy-primitive migration + dead-code deletion) | ~1 quartz-day | Mostly mechanical; the deletion is the payoff. |
| 6 (docs) | ~0.5 quartz-day | Pattern matches B.9 Phase 5. |
| **Total** | **~5-7 quartz-days** | Down from 1-2 quartz-weeks because the substrate (effect-snapshot inheritance, M:N suspend/resume, `with` blocks, structured concurrency primitives) is already built. |

Sister to B.9's calibration: when the substrate exists, the user-facing
unification is mostly migration work, not architectural work. The exception
here is Phase 4 — primitive integration is genuinely invasive because it
touches every blocking primitive in the runtime. That's the load-bearing
phase; the others are scaffolding around it.

The dependency on C.13 for `scope.cancelled(): Selectable` is the only
sequencing constraint. Phases 2-3 can ship independently; Phases 4-5 can
ship before C.13 with `wait_cancelled()` as the blocking-primitive form;
the Selectable wrapper retrofits when C.13 ships.

## Pairings

B.7 is the keystone of the Layer 2 concurrency unification (per Stance 2):

- **B.7 (Scope)** = the cancellation/deadline carrier.
- **B.8 (`with`-scoped resources)** = the acquire-side unifier. Resources
  acquired inside a scope are released on scope exit (normal OR cancellation).
- **C.13 (generalized `select`)** = the wait-side unifier. `select` over any
  Selectable, including `scope.cancelled()`, channel send/recv, future
  poll, mutex try-lock, signal subscription, deadline.
- **B.9 (error unification)** = the cancellation transport. `throw
  "cancelled"` and `throw "deadline_exceeded"` ride the same Throws
  mechanism as user throws, caught by the same `with Throws { throw: ... }`
  blocks.

Ship order: B.9 (done through Phase 2) → B.7 → C.13 → B.8. Each builds on
the last.

## What would be lost if we don't ship B.7

The status quo works — Quartz programs can already cancel work via
`cancel_token_*`, time-bound it via `await_with_timeout`, structure it via
`go_scope`. The cost of NOT shipping B.7 is:

1. **The launch pitch is weaker.** "We have four cancellation mechanisms,
   pick the right one for your situation" is a worse story than "we have
   one, here's the mental model." The single-primitive story is exactly
   what differentiates Quartz's concurrency from C++/Java/Go-style toolkits
   (where the equivalent is several disjoint libraries) and from Python's
   asyncio (which still hasn't fully sorted this out).
2. **The structured-concurrency primitives stay buggy at the corners.**
   `_current_scope_*` module-global state means `go_scope` nested inside
   `go_scope` doesn't work correctly — the inner block clobbers the outer
   block's state. There are no tests for this because the API doesn't
   visibly support nesting; users who try it discover the bug. B.7 fixes
   the architecture, not the bug.
3. **Each future blocking primitive has to invent its own deadline
   mechanism.** Channel send timeouts, mutex acquisition timeouts, file I/O
   timeouts, network connection timeouts — without a unified scope, every
   one needs its own per-call deadline parameter. With B.7, every one
   inherits the scope's deadline for free.
4. **Cancellation does not compose with `select`.** Today users cannot
   write "wait for either this channel or my cancellation" without
   manually polling the cancel token. C.13's generalized select assumes
   B.7 (or something like it) for the cancellation Selectable.

Pre-launch is the time to do this. Post-launch the migration is much harder
because every published Quartz program is using `cancel_token_*` directly.
