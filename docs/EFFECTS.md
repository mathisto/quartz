# Algebraic Effects in Quartz

> [!CAUTION]
> **Historical design record, not a current language authority.** This April 2026
> Piezo epic document preserves the design sequence and implementation history.
> It mixes landed, retired, nonconforming, and proposed syntax and semantics,
> including optional/implicit `try`, `if let`, postfix `!`, `?.`, a catchable
> `Panic` effect, pure-function evidence erasure, and the raw word handler ABI.
> Do not use its examples as current Quartz. The sole detailed authority for
> executable behavior is [`docs/QUARTZ_REFERENCE.md`](QUARTZ_REFERENCE.md);
> current defects and target semantics are in [`STATUS.md`](../STATUS.md) and
> [`STABILIZATION_INVARIANTS.md`](design/STABILIZATION_INVARIANTS.md).
>
> **Epic:** Operation Piezoelectric Effects (commit tag: `[piezo]`). Historical
> design and implementation work ran from 2026-04-18 through 2026-04-26.
> **Living plan**: [`docs/research/EFFECTS_IMPLEMENTATION_PLAN.md`](research/EFFECTS_IMPLEMENTATION_PLAN.md)
> **Research notes**: [`docs/research/EFFECT_SYSTEMS_NOTES.md`](research/EFFECT_SYSTEMS_NOTES.md)
> **Implementation strategy**: [`docs/research/EFFECTS_LLVM_COMPILATION_MEMO.md`](research/EFFECTS_LLVM_COMPILATION_MEMO.md)

Named after the **piezoelectric effect** (Curie, 1880) — the physical property by which quartz crystals convert mechanical stress into electric charge. Quartz is the canonical piezoelectric material; quartz oscillators are what make computers tick. This epic makes the programming language Quartz capable of the same transformation: converting user code into observable, catchable, composable effects.

This document records the Piezo design intent and historical implementation
shape at multiple milestones. It is useful for provenance, not as a user guide
or a statement of current shipped behavior.

---

## 1. Philosophy: Invisible by Default, Rich When Wielded

Quartz is **the first systems language with first-class algebraic effects**. But you wouldn't know it from looking at a trivial program:

```quartz
def main()
  puts("hello, world")
end
```

No effect annotations. No ceremony. This program works — and is effect-correct under the type system, which knows `puts` uses `StdIo` and that `main`'s missing annotation means "whatever the prelude's default handler installs." The effect is *there* — it's invisible.

Quartz supports three **engagement levels**, all first-class:

| Level | What you write | Who lives here |
|---|---|---|
| **Invisible** | No `can`. No `try`. No `with`. Code reads as if effects don't exist. | Beginners, quick scripts, systems code that trusts main-defaults |
| **Implicit** | Effects inferred; visible in LSP hover, `quartz doc`, error messages. Code stays clean. | Library authors wanting internal consistency without ceremony |
| **Explicit** | Full `can` rows, `with` handlers, `try` markers, effect-polymorphic combinators, sandboxing. | Sandboxing, async composition, rigorous APIs, advanced code |

### Non-negotiables

- Trivial programs have zero effect ceremony.
- `can` annotations are never **required** for correctness — inference fills them in. They document or constrain.
- Rich features (`with catch`, row polymorphism, `try` markers, effect-polymorphic `map`) are first-class, reachable from any scope — not gated by mode switches or pragmas.
- Writing invisibly never locks you out of wielding. Drop into explicit at any expression boundary.
- Effects are **substrate**, not "advanced mode." The rules about visibility are about noise, not capability.

### How this fits Quartz's broader design pattern

This matches patterns you'll recognize across the language:

- Const by default, `var` to opt in
- Types inferred everywhere; annotate at boundaries
- Types rich at compile time, erased at runtime
- Implicit `it` in blocks, explicit parameters when you want them
- Open UFCS: three levels of method dispatch (impl method → trait method → open UFCS)
- Async colorless — no coloring tax
- Drop/RAII automatic; custom `Drop` for cleanup

Effects extend the pattern to error handling, Io, state, diagnostics, allocator, async — the substrate that makes Quartz's runtime work.

---

## 2. What is an Effect?

*TBD in Phase 1. This section will cover: the intuition ("an effect is a capability a function may exercise"), the contrast with monads, the contrast with exceptions, the formal definition (row-typed effect labels with operations), worked examples.*

---

## 3. Syntax

The forms below are shipped and spec-covered (§3.2–§3.5). Effect declarations
(§3.1) use the committed syntax.

### 3.1 Effect declarations

```quartz
effect Throws<E>
  def throw(e: E): Never
end

effect Log
  def log(msg: String): Void
end
```

### 3.2 Effect rows on function signatures ✅ shipped

```quartz
def read_config(path: String): Config can FileIo, Throws<ConfigError>
def greet(name: String): Void can StdIo
def pure_fn(x: Int): Int    # no row = pure (empty effect row)
```

Row polymorphism with tail variables:

```quartz
def map<T, U, ε>(items: Vec<T>, f: Fn(T) can ε: U): Vec<U> can ε
# map has the same effects as f, whatever f's effects are
```

### 3.3 Handler installation ✅ shipped

A handler is installed with `with <Effect> { <op>: handler } do -> ... end`.
The `Throws` effect is the canonical catch handler — its `throw` op receives
the thrown value:

```quartz
result = with Throws { throw: recover } do ->
  read_config(path)
end

def recover(op: Int, argc: Int, argv: Int): Int
  # inspect the thrown value, return a fallback
  return as_int(default_config())
end
```

Multiple handlers install on one site via a comma list — `with H1, H2 do ...
end` desugars to nested `with` blocks (see §7.3). For the effect-to-`Result`
shorthand that catches throws without a hand-written handler, use `reify` (§3.5).

### 3.4 The `try` prefix keyword (optional) ✅ shipped

```quartz
# These are equivalent; `try` is an explicit propagation marker.
value = parse_int(s)         # implicit propagation via row inference
value = try parse_int(s)     # explicit — reader sees the propagation point
```

### 3.5 The `reify` block (effect → Result conversion) ✅ shipped

```quartz
res: Result<Int, ParseError> = reify { parse_int(input) }
# reify catches any throws and wraps as Err; returns Ok on normal exit
```

---

## 4. The Blessed Effect Set (v6.0)

Quartz v6.0 ships 14 atomic effects + 1 row alias as first-class stdlib effects:

### 4.1 Phase 1 effects (shipped with v6.0 alpha)

| Effect | Role | Default handler |
|---|---|---|
| `Throws<E>` | Control-flow errors | Uncaught throw → reach main → panic |
| `Panic` | Unrecoverable errors | Print trace + flush + exit 101 |
| `Log` | Structured logging | Write to stderr (with severity levels) |
| `FileIo` | Disk I/O | Call through to filesystem syscalls |
| `NetIo` | Network | Call through to socket syscalls |
| `ProcIo` | Process spawn | Call through to `fork`/`exec` |
| `StdIo` | stdin/stdout/stderr | Line-buf TTY, block-buf pipe, flush on panic |
| `Clock` | Time queries, sleep | Call through to `gettimeofday` / `nanosleep` |
| `Random` | RNG | Call through to `getrandom` / `arc4random` |
| `Env` | Environment variables | Call through to `getenv`/`setenv` |

### 4.2 Phase 2 effects (shipped 2026-04-22)

| Effect | Role | Default handler |
|---|---|---|
| `State<S>` | Mutable threaded state | `__qz_default_state_handler` — reads/writes per-install evidence slot |
| `Reader<R>` | Config / dependency injection | `__qz_default_reader_handler` — reads per-install evidence slot |
| `Alloc` | Allocator (arena-swap, sandbox, test harness) | Not shipped — Phase 2 post-scope |

See §7 and §8 below for `State<S>` / `Reader<R>` usage.

### 4.3 Phase 3 effects

| Effect | Role |
|---|---|
| `Async` | Async/await/go/channels (migrated from special-cased MIR lowering) |

### 4.4 Deferred / not blessed

- `Ndet` — multi-shot non-determinism / backtracking. Deferred indefinitely. Single-shot compilation path is exclusive.
- `Yield<T>` — generators as effect. Deferred. Generators remain compile-time state-machine lowering.
- `Debug` / `Trace` — subsumed under `Log` with severity levels.
- `Exit` — use `Panic` or `Throws<ExitRequested>`.

### 4.5 Row alias

```quartz
Io = { FileIo, NetIo, ProcIo, StdIo, Clock, Random, Env }
```

`can Io` in a signature is sugar for the row above. Use when precise capability isn't needed; reach for atomic labels when it is (sandboxing, security audit).

---

## 5. Error Handling — the Four Tiers

Quartz has exactly four tiers for "this could fail":

| Tier | Semantics | Catchable? | Typed? | Canonical form |
|---|---|---|---|---|
| **Assertion** | "I proved this; crash if wrong" | No (panic) | No | `x!` (postfix `!`) |
| **Control flow (effect)** | "Failure is a legit outcome for my caller" | Yes (`with catch`) | `can Throws<E>` | `try x`, `throw(e)` |
| **Error as data** | "I want the error *value* to store/pass/serialize" | N/A (just data) | Return type | `Result<T, E>` |
| **Panic** | "Unrecoverable (OOM, invariant violated)" | No | No | `panic(msg)` |

### 5.1 Intent-to-form mapping

| Intent | Form |
|---|---|
| Test ("is it Some?") | `x.some?` / `x.ok?` |
| Narrow ("if Some, give value") | `x is Some(v)`, `if let Some(v) = x` |
| Destructure ("do different things per variant") | `match` / `if let` |
| Assert ("I'm sure; crash if wrong") | `x!` |
| Propagate ("failure is my caller's problem") | `try x` (optional; implicit also works) |
| Default ("use this if absent") | `x ?? default`, `x.unwrap_or(d)` |
| Chain ("short-circuit to None") | `a?.b?.c` |
| Transform ("lift operation inside") | `x.map(f)`, `x.flat_map(f)` |
| Reify (effect → Result) | `reify { expr }` |

### 5.2 Deleted / retired forms

- `$try(x)` macro — **replaced by `try` prefix keyword**. One form for propagation.

### 5.3 Why `!` isn't effect-typed

`!` is an **assertion**. Writing `opt!` means "I've established this is Some; if I'm wrong, that's a bug, and bugs should crash loud, not become catchable control flow." Matching Rust's `.unwrap()`. Three distinct intents keep three distinct syntactic forms.

---

## 6. Handler Semantics

*TBD in Phase 1. This section will cover:*

- Handler installation and the `with ... do ... end` block
- How handlers form a stack; scoped (duplicate) labels allowed per our Model B commitment
- Handler pipelining and composition
- `resume` semantics (invoke the continuation with a value, or don't)
- Tail-resumption optimization (when an operation clause ends with `resume(e)` and `resume` doesn't appear in `e`)
- Handler return clauses
- Nested handlers and label shadowing
- Interaction with `panic` (unwinds past `catch` handlers; can be intercepted via the `Panic` default-handler swap)

---

## 7. Examples

*TBD in Phase 1. Target: 10–15 curated examples in `examples/effects/` covering:*

- Hello-world with zero ceremony (invisible level)
- Throws basics — parse with error propagation
- Catch handler with default value
- Testing with swapped `Random` / `Clock` handlers
- Sandbox with denied `NetIo`
- Effect-polymorphic `map`
- Composing multiple effects in one handler
- `reify` for effect-to-Result conversion
- The `Env` audit handler (security-software use case)
- Reader+State for CLI config — shipped: [`examples/cli_effects.qz`](../examples/cli_effects.qz)

### 7.1 State<S> — mutable threaded state

```quartz
import std/state

def increment() can State
  set(get() + 1)
end

def main(): Int
  with State(10) do ->
    increment()
    increment()
    increment()
    puts(get().to_s())   # → 13
  end
  return 0
end
```

Nested `with State` gets independent slots — inner writes don't leak to
the outer scope:

```quartz
with State(1) do ->
  with State(2) do ->
    set(99)            # writes inner slot only
  end
  get()                # → 1  (outer unchanged)
end
```

Helpers that perform `get/set` declare `can State` on their signature:

```quartz
def step(): Int can State
  set(get() + 1)
  return get()
end
```

`can State` is the row label; the type parameter `S` erases at runtime
(everything is `i64`-sized, pointers included). User overrides use the
struct-init form: `with State { get: my_get, set: my_set } do ... end`.

### 7.2 Reader<R> — ambient values

```quartz
import std/reader

def greet() can Reader = "hello, world " + as_string(ask())

def main(): Int
  with Reader(42) do ->
    puts(greet())       # → "hello, world 42"
  end
  return 0
end
```

`local(f, body)` shadows the ambient for `body` only; outer value
restored on return:

```quartz
with Reader(10) do ->
  var inside = local(x -> x + 1, () -> ask())   # → 11
  var outside = ask()                            # → 10
  inside + outside                               # → 21
end
```

### 7.3 Composing effects — comma-list `with`

Multiple effects install on one site:

```quartz
import std/state
import std/reader
import std/log

def my_log(op: Int, argc: Int, argv: Int): Int
  puts(as_string(load(argv, 0)))
  return 0
end

def process(): Int can State, Reader, Log
  log::info("start")
  set(get() + ask())
  return get()
end

def main(): Int
  var r = with Log { emit: my_log }, Reader(100), State(5) do ->
    process()
  end
  puts(r.to_s())   # → 105
  return 0
end
```

`with H1, H2, H3 do body end` is syntactic sugar for the nested form
`with H1 do with H2 do with H3 do body end end end` — the parser
desugars at parse time. Left-to-right list order = outer-to-inner
install order.

### 7.4 CLI pilot

[`examples/cli_effects.qz`](../examples/cli_effects.qz) is the
shipped pilot: a small argv-processing CLI driven by `State<Int>` cursor
+ `Reader<Int>` verbosity + `Log` routing. Demonstrates the DX win —
helpers like `advance_cursor`, `consume_int`, `has_more` pull from the
State frame without any parameter threading.

Run:
```
./cli_effects sum 10 20 30              # → "total: 60"
./cli_effects --verbose sum 1 2 3       # → log trace + "total: 6"
./cli_effects --silent sum 5 5          # → "total: 10" (logs gated)
```

### 7.5 State<T> for struct pointers (compiler-dogfood shape)

`State<S>` stores an `i64` in its evidence slot. Quartz's existential type
model means every struct value is already `i64`-sized at runtime (all
pointers are `i64`), so `State<T>` works transparently for pointer
payloads — you just need `as_int` at install and `as_type<T>` at
recovery:

```quartz
struct Ctx
  depth: Int
end

def bump_depth(c: Ctx): Void
  with State(as_int(c)) do ->
    var c2 = as_type<Ctx>(get())
    c2.depth = c2.depth + 1
  end
end
```

This is exactly the body-wrap pattern the compiler uses in Phase 5.2 to
dogfood `State<TcCtx>` on its own typecheck state. Three pairs migrated:
`tc_enter_scope/tc_exit_scope` (depth counter), `tc_handler_effect_push/
pop` (effect-label stack), `tc_tv_enter_level/tc_tv_exit_level` (let-
binding level). The body-wrap keeps the outer signature free of `can
State`, so the ~30 callers of each migrated helper needed no edits.

**When to reach for this pattern:**

- The leaf helper mutates a struct payload that's already accessible via
  an explicit `tc`/`ctx` parameter, and you want to dogfood State
  without a massive `can State` cascade through the call chain.
- Coupled with a single-slot bridge (see
  `self-hosted/middle/typecheck_ctx.qz`) when you need other call sites
  to read the same ambient value without taking it as a parameter —
  exactly analogous to Phase 5.1's `typecheck_diag.qz` slot for `Diag`.

**Body-wrap last-stmt gotcha**: inside the `with State(...) do -> … end`
function-body wrap, the last statement MUST be a bare expression, not
`return X` — otherwise the merge block's TERM_RETURN fires before the
handler uninstall's cleanup, violating SSA dominance. For `Bool`-return
helpers use `return with State(...) do -> … bare_expr end` (the `return`
is outside the wrap, the body ends with a bare expression); see
`tc_handler_effect_contains` at
`self-hosted/middle/typecheck_util.qz:1846`.

### 7.6 HTTP server middleware as effect stack

Phase 6.1 (April 2026) dogfoods the effect substrate on a user-shaped
tool: `std/net/http_server.qz`. The shape that landed:

- **Logging** — `with_logging(handler)` calls `log::raw(">> #{method}
  #{path}")` and `log::raw("<< #{status}")` around the wrapped
  handler. `log::raw` performs through the `Log` effect; an outer
  `with Log { emit: capture } do -> http_serve(...) end` install
  intercepts every access-log line.
- **Static files** — `with_static(prefix, dir)(handler)` serves files
  from `dir` via the `FileIo` effect (`fio_read` / `fio_exists`). An
  outer `with FileIo { fio_read: fixture, fio_exists: predicate } do
  -> http_serve(...) end` install lets a test serve the entire HTTP
  surface from in-memory fixtures, with no real filesystem and no
  port binding.
- **Errors** — handler-side errors flow through the `Throws` effect
  via the per-request `_invoke_handler_safely` wrap installed in
  `http_serve*`. An outer `with Throws { throw: cap }` install around
  the boot path observes init failures (bind / listen / TLS); the
  framework's per-request install converts handler-side `throw(...)`
  to a 500 Response without crashing the server.
- **Routing** — `http_serve(port) do -> route_get(...) end` opens a
  fresh `with HttpRoute { register: collect_into_router }` install,
  invokes the body to gather routes, then forwards to
  `http_serve_supervised(http_server_config(port), dispatcher)`. An
  outer install captures routes for testing without binding.

The result: testing an HTTP handler does not need a separate
`TestClient`, mocking library, or DI container. Effects ARE
dependency injection. See [`examples/http_effects.qz`](../examples/http_effects.qz)
for a canonical demo + the `_demo_unit_test` pattern.

### 7.7 Actors and effects (C.14)

`actor X ... end` spawns a green-thread task, which means actors
participate in **two automatic inheritance mechanisms** at spawn time:
the effect-stack snapshot and the current scope. Both are transparent
— no actor-specific syntax — but knowing they exist matters when
you're reasoning about handler visibility, sandboxing, or
cancellation cascades across actor boundaries. See
[Actors (C.14)](QUARTZ_REFERENCE.md#actors-c14) in the language
reference for the Layer 1 actor + supervisor surface; this section
covers how that surface interacts with effects.

#### Effect-stack snapshot inheritance (E.1.c.b)

When task A spawns task B (`go fn()`, `async fn()`, `sched_spawn`, or
the language-level `actor X ... end` spawn), the compiler emits a
call to `__qz_effect_snapshot_capture()` at the spawn site. This
walks task A's TLS effect stack from the blessed-defaults floor up
to the current top, allocates a buffer, and copies the
`(marker, handler_ptr)` entries. B's `$poll` prologue calls
`__qz_effect_snapshot_apply(snap)` to push those entries onto the
worker thread's effect stack before B's body runs. On B's
completion or panic, `__qz_effect_snapshot_free(snap)` releases the
buffer.

What this means for actors:

```quartz
import * from std/log
import * from actor

actor Echo
  def speak(msg: String): Void
    log::info("echo: " + msg)        # uses ambient Log handler
  end
end

def capture(op: Int, argc: Int, argv: Int): Int
  # ... append-to-log impl ...
  return 0
end

with Log { emit: capture } do ->
  var e = Echo()              # snapshot taken here — Log handler captured
  e.speak("hi")               # → routed to `capture`, NOT the default stderr handler
end                           # outer handler uninstalls; future Echo()s would
                              # see the default Log handler instead
```

Each handler dispatch inside an actor method routes through the
snapshot inherited at spawn time, not whatever the spawning task's
stack happens to look like *now*. The actor is captured at the
moment of spawn — later `with` installs on the spawning task don't
retroactively change what the running actor sees.

Implications:

- **Sandboxing is per-actor.** Spawn an actor under a `with NetIo {
  ... } do -> ... end` denial handler and that actor's net-I/O
  attempts route through the denial — even if the spawning task
  later uninstalls the handler.
- **`Log` / `Diag` capture transparently follows actors.** Test
  harnesses that install a capture handler before spawning an actor
  see the actor's emitted log lines without any actor-specific
  wiring.
- **`State<S>` / `Reader<R>` slots inherit by snapshot.** The actor
  reads from the slot installed by the spawning task. Writes from
  inside the actor are scoped to the snapshot's evidence slot — they
  don't propagate back to the spawning task's slot. (The two tasks
  share the value at spawn time; after that they diverge. This is
  the right semantics for actors — message-passing isolation — but
  it's worth knowing.)
- **`Throws<E>` snapshots like any other.** An uncaught throw inside
  an actor handler unwinds against the snapshot stack. If the
  spawning task had installed a `with Throws { throw: cap }`
  handler, the actor's throw is observable there. The actor's
  per-handler firewall (`frame[3] == -999` sentinel) catches panics
  *before* they reach the snapshot stack — so a panic in `def
  speak(msg)` drops the reply and continues; an explicit `throw(e)`
  propagates to the snapshot's `Throws` handler.

#### Scope propagation across actor boundaries (B.7 Phase 4)

The `@__qz_current_scope_handle` TLS slot is captured at spawn time
alongside the effect snapshot. An actor spawned under a scope runs
its `$poll` body with that scope as the current scope, and the six
scope-aware blocking primitives (`scope_sleep_ms`, `scope_recv`,
`scope_send`, `scope_lock`, `scope_rwlock_read`,
`scope_rwlock_write`) automatically honor the parent's cancel.

```quartz
import * from std/sync/scope
import * from actor

actor LongPoller
  def wait(): Void
    scope_sleep_ms(10000)        # honors the parent scope's cancel
  end
end

with scope_with(scope_with_cancel(current_scope())) do ->
  var p = LongPoller()
  p.wait()                       # the actor's wait inherits this scope
  # ... if anything calls scope_cancel(current_scope()) here, the
  # actor's wait unwinds via Throws ("scope cancelled")
end
```

Implications:

- **Cancel cascades transparently.** `scope_cancel(parent)` on the
  spawning task's scope wakes any scope-aware blocking primitive
  inside the spawned actor's currently-executing handler. The actor
  observes via the Throws unwind path — the same mechanism as
  scope-aware blocking outside actors.
- **Deadlines propagate.** A `scope_with_deadline` on the spawning
  task installs a deadline that the actor's blocking primitives
  observe. There's no separate "actor deadline" surface — it's the
  same scope mechanism.
- **`Supervisor` watcher inherits the supervisor's parent scope.**
  The watcher goroutine spawned by `supervisor_new` runs under the
  scope active at construction time. Cancelling that scope unwinds
  the watcher, which then cascades the cancel into
  `supervisor_stop`. No extra wiring needed — B.7 + C.14 compose by
  construction.

#### What this does NOT do

- **It does NOT make the actor's mailbox throw-aware.** An actor
  blocked in its auto-generated recv loop (waiting for a method
  call) is NOT cancelled by scope cancel. The recv inside the
  poll loop is a raw `recv`, not `scope_recv`. To stop an idle
  actor, send `.stop()` (which the supervisor's
  `supervisor_stop` and `dynamic_supervisor_stop` both do).
- **It does NOT preserve writes back to the spawning task's
  `State<S>` slot.** The snapshot copies the evidence pointer at
  capture; writes from inside the actor land in the slot at that
  pointer, which is the spawning task's slot at capture time. If
  the spawning task uninstalls and re-installs `State<S>` between
  capture and the actor's write, the actor writes into a now-stale
  slot. This is rare in practice (most `State<S>` installs wrap a
  scope that outlives any actor spawned inside it), but worth
  knowing.

---

## 8. Main and the Default Handler Stack (§8.5)

Every Quartz program with a `main()` entry point has a **prelude-installed default handler stack**. Trivial programs never see it; the machinery is transparent.

Default handlers, composed outermost-to-innermost:

1. `Panic` → print structured message + trace + flush stdout/stderr + `exit(101)`
2. `Throws<_>` → any uncaught throw reaches main and converts to a panic with a "tried to throw, nobody handled it" message + the throw's value + stack trace + suggested remediation (`with catch` or row propagation)
3. `Log` → write to stderr with severity levels
4. `StdIo` → line-buffered for TTY, block-buffered for pipe, auto-flush via `Panic` handler
5. `FileIo`, `NetIo`, `ProcIo`, `Clock`, `Random`, `Env` → pass-through to syscalls

Custom handlers installed via `with ... do ... end` are **strictly additive overrides** — they shadow the defaults within their dynamic scope. On scope exit, the default handler is restored.

### Why this matters

This is the mechanism that makes "invisible level" work. Without default handlers, every `main()` would need explicit ceremony for every effect the program uses. With them, `def main(); puts("hi"); end` is a complete, correct program.

---

## 9. Error Messages

*TBD in Phase 1. Full reference with sample messages for every error category.*

Phase 1 quality bar (committed):

1. Point at offending source location (file:line:col, carets).
2. Plain-English description first, row-syntax second.
3. Always suggest a concrete compilable fix.
4. Grade by engagement level — invisible users never see "row," "label," "unification" vocabulary.
5. Never leak implementation vocabulary.
6. Runtime uncaught-throw formats with trace + remediation hint.

See `EFFECTS_IMPLEMENTATION_PLAN.md` § "Error messages (quality bar)" for the full spec and engagement-level detection heuristic.

---

## 10. Compilation Model (implementer reference)

Committed: **evidence-passing** (Xie & Leijen 2020 style). Full details in [`docs/research/EFFECTS_LLVM_COMPILATION_MEMO.md`](research/EFFECTS_LLVM_COMPILATION_MEMO.md).

**Evidence** is a threaded parameter: a singly-linked list of `(marker, handler_ptr)` nodes carried as an extra parameter on every function with a non-empty effect row. Pure functions take no evidence parameter and keep direct-call performance.

**Three operation kinds** determine the compilation path for each effect op:

| Kind | When | Compilation | Perf |
|---|---|---|---|
| `value` | Op always resumes with a constant | Handler field lookup | O(1) |
| `function` | Op is tail-resumptive | Direct indirect call through handler vtable | O(depth) lookup + 1 indirect call |
| `operation` | Op is general (may abort, resume, or deferred multi-shot) | Reifies continuation via existing `$poll` state machine machinery | CPS cost, existing async overhead |

**>90% of Quartz effect ops are `function`-kind** (Log, StdIo, FileIo, NetIo, ProcIo, Clock, Random, Env, State.get/set, Reader.ask, Alloc.alloc). Slow-path `operation` kind is only: Throws.throw (aborts, free), Async.{await, spawn, suspend} (Phase 3, reuses existing `$poll` machinery), Panic.panic (aborts, free), and deferred Ndet.

**Key implementation notes:**
- Single-shot is a direct call; no CPS for function-kind ops.
- Polymorphic effect functions (`Vec.map`, `Vec.fold`) thread evidence as a regular parameter — one compiled version, not per-row monomorphization.
- Multi-shot handlers exist as a slow path but are not optimized. Ndet is deferred indefinitely.
- Phase 3 (async-as-effect migration) is reframing, not rewriting — the existing `$poll` state-machine lowering IS the operation-kind CPS transform.
- Scoped-resumption enforcement via runtime `guard` check: a captured continuation cannot be invoked under a different evidence context.

**Performance floor** (from Xie-Leijen 2020 §6 benchmarks, translating their Haskell perf to our LLVM target):
- Function-kind op: within a few percent of direct call.
- Deep effect stacks: constant-time.
- Abort-like effects (Throws, Panic): within 1% of pure.

Details re-derived for LLVM IR in Phase 1. Paper notes in `EFFECT_SYSTEMS_NOTES.md`; full compilation strategy in `EFFECTS_LLVM_COMPILATION_MEMO.md`.

---

## 11. Migration Guide (for existing Quartz code)

*TBD in Phase 1 exit. Covers how to:*

- Migrate `$try(x)` macro uses to `try x` keyword (mechanical rewrite).
- Rewrite functions that return `Result<T, E>` into `T can Throws<E>` (idiom shift — keep Result at FFI boundaries, use Throws internally).
- Install a custom `Log` handler for an app (replaces `puts` usage).
- Install test-time `Clock` / `Random` handlers.
- Convert a cooperative `Reader<Config>` pattern to an effect-based one.

---

## 12. References

- **Leijen 2017** — "Type Directed Compilation of Row-Typed Algebraic Effects." POPL 2017. Type-system foundation (rows, scoped labels, OPEN/CLOSE rules, inference). [PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/12/algeff.pdf)
- **Xie & Leijen 2020** — "Effect Handlers in Haskell, Evidently." Haskell 2020. *The* evidence-passing paper — our compilation-model reference.
- **Leijen 2014** — "Koka: Programming with Row Polymorphic Effect Types." MSFP 2014. Earlier Koka type system, monadic semantics.
- **Plotkin & Pretnar 2009** — Algebraic effect handlers, original paper. Foundational.
- **Brachthäuser et al.** — Effekt. Capability-passing contrast.
- **OCaml 5 Effects RFC** — Fiber-based compilation contrast.
