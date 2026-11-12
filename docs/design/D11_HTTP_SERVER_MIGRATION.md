# D.11 — `std/net/http_server.qz` Migration to Actor + Supervisor + Unified Select

> **Status**: Phase 1 design memo. Written 2026-05-23 as the first artifact of
> the D.11 capstone work; the userland migration phases land progressively
> in subsequent sessions, with the freestanding-kernel bridge tracked as a
> separable sub-epic.
>
> **Why this exists**: The Phase A-C concurrency unification work (B.7
> scope tree, B.8 scoped resources, C.13 unified select, C.14 Actor +
> Supervisor, D.10 four-shapes taxonomy under `std/sync/`) shipped through
> 2026-05-11. D.11 is the integration test that proves those designs were
> correct by migrating the most-used userland network primitive — the HTTP
> server — onto them. Per the May 1 2026 design session, D.11 is also the
> last gate before SOUL.7 (deploy to public internet); the unikernel itself
> serves the Soul page, so we want the server-under-the-demo to dogfood the
> primitives the demo showcases.

## Problem

Today `std/net/http_server.qz` is a 4 084-line file with seven entry points
(`http_serve_handler`, `http_serve_async`, `http_serve_tls`, `http_serve`,
`http_serve_concurrent`, `http_serve_opts`, `http_serve_tls_opts`) that
collectively implement an accept-loop + per-connection-goroutine architecture
on the pre-Phase-A-C primitives:

- **Goroutine-per-connection.** `accept()` returns → `set_nonblocking(fd)` →
  `var task = async _handle_connection_keepalive(fd, handler, config)` →
  `sched_spawn(task)`. The per-connection function is a sync while-loop:
  parse request → run handler → write response → repeat until close.
- **Shutdown via global atomic flag.** `_http_shutdown_flag = atomic_new(0)`,
  set by SIGTERM/SIGINT handler, polled at the top of every accept iteration
  and inside the per-connection keepalive loop. Each path independently
  observes the flag; there's no propagation.
- **No supervisor.** A `throw` from inside the user handler propagates up
  to the async wrapper, where the default Throws handler calls `exit()` —
  one crashing request kills the entire server. Workaround today is the
  per-program `with Throws { throw: handler } do ... end` wrapper; users
  who don't know to add it get the brittle default.
- **Per-connection timeouts inlined.** `_async_http_parse_request_timeout`,
  `_async_http_write_response_timeout` each implement their own deadline
  loops calling `io_suspend_timeout(fd, remaining, 1)`. The timeout/read/
  shutdown-signal triple is open-coded; can't compose, can't add a fourth
  arm without editing every site.
- **Resource cleanup ad-hoc.** Sockets `close(fd)` in `try`/`finally`-style
  paths; the function returns 0 normally and there's a `close(fd)` before
  return, but errors don't always trip cleanup. No `with` block guarantee.

The Phase A-C primitives that exist today but aren't used here:

- `scope_with_deadline(ms) do -> body end` — every async helper inside
  this scope inherits the deadline; cancellation cascades through the
  scope tree via `sched_wake_interrupts_sleep` (sub-ms)
- `with TcpStream do -> stream -> body end` — `Scoped` impl auto-closes
  the socket on body exit, including throw-unwind (B.8 Phase 5)
- `select { case _ = recvable(ch) => ... case _ = deadline_ms(t) => ... case _ = cancellable(scope) => ... }` — unified across primitives (C.13)
- `Actor<T>` with typed mailbox + lifecycle hooks (C.14)
- `Supervisor` with one_for_one / one_for_all / rest_for_one + restart-with-backoff (C.14)

D.11 migrates http_server.qz onto these so:
1. Each connection is an `Actor<HttpRequest>` under a `Supervisor`
2. The listener is itself an `Actor<TcpConn>` whose mailbox is the
   accept-stream; supervisor restarts it on listener failures
3. Per-connection scope inherits the listener's deadline + shutdown signal
4. `Scoped` impls for TcpListener/TcpStream/EventLoop guarantee cleanup
5. Unified `select` replaces the open-coded timeout/read/shutdown loops

## Goal

```qz
# What users write after D.11:

http_serve(8080) do |route| ->
  route.get("/hello") do |req| -> ok("world") end
end
```

Sugar around (using the actual primitives that shipped — `scope_with` /
`scope_timeout` / `dynamic_supervisor_*` / `signalable` / `tcp_listener_scoped`;
the surface here is what the implementation will build, not a target syntax):

```qz
def http_serve(port: Int, body: Fn(Routes): Void): Int
  var routes = Routes.new()
  body(routes)
  var listener = tcp_listen(port)
  with tcp_listener_scoped(listener) do l ->
    var dsup = dynamic_supervisor_new(
      -> _conn_actor_spawn(routes),  # spawn_fn closes over routes
      10,    # max_restarts
      60000  # period_ms (10 restarts per 60 s)
    )
    var root = scope_with_cancel(current_scope())
    scope_with(root, -> {
      while scope_is_cancelled(root) == false
        select
          case conn_fd = tcp_acceptable(l) =>
            _conn_route_table_put(routes, dynamic_supervisor_spawn(dsup), conn_fd)
          case _ = signalable(15) =>  # SIGTERM
            scope_cancel(root)  # cascades to every connection actor's `cancellable`
        end
      end
      return 0
    })
    dynamic_supervisor_stop(dsup)
  end
  return 0
end
```

The Connection Actor (defined via the `actor` keyword that desugars to
`Actor<T>` machinery, C.14):

```qz
actor ConnectionActor
  conn_fd: Int
  routes: Routes

  def handle_request(self, req: HttpRequest): Void
    var deadline_scope = scope_timeout(current_scope(), self.routes.config.request_timeout_ms)
    scope_with(deadline_scope, -> {
      var resp = routes_dispatch(self.routes, req)
      _async_http_write_response(self.conn_fd, resp)
      return 0
    })
  end

  def on_terminate(self, reason: String): Void
    close(self.conn_fd)
  end
end
```

The keep-alive loop inside the Connection Actor's body is the unified
`select` (C.13 — `recvable` / `deadline_ms` / `cancellable` are all real
Selectable impls that shipped through C.13 Phases 5 + 6.6):

```qz
select
  case req = http_request_selectable(self.conn_fd, self.routes.config.read_buffer_limit) =>
    self.handle_request(req)
  case _ = deadline_ms(self.routes.config.keepalive_timeout_ms) =>
    return  # idle timeout
  case _ = cancellable(current_scope()) =>
    return  # shutdown cascade fired
end
```

(`http_request_selectable` is a NEW Selectable impl Phase 2 adds — wraps
the existing `_async_http_parse_request_*` flow. Same shape as the
existing `recvable(ch)` impl on channels: try_poll attempts a non-blocking
parse; register_waker arms an io_suspend on the fd.)

Three arms in one expression. Adding a fourth (e.g. backpressure signal)
is one more `case`.

## Prior-art compass

Per D2: research what the world already knows, design accordingly. Here is
how the dominant HTTP servers structure connection lifecycle:

### Erlang/OTP — Cowboy

Cowboy is the closest analogue to where we're going. Architecture:

```
ranch_listener_sup           (listener supervisor)
├── ranch_acceptor_sup       (acceptor pool)
│   └── ranch_acceptor       (one per acceptor thread; calls gen_tcp:accept)
└── ranch_conns_sup          (connection supervisor)
    └── cowboy_clear_h       (per-connection handler process)
        └── cowboy_stream    (per-request stream process for HTTP/2)
```

Each connection is an OTP gen_server process; on accept the acceptor sends
the socket to ranch_conns_sup which spawns under the connection supervisor.
Connection process crashes are isolated; the supervisor restarts policy
controls whether crashed connections restart (default: do not — connection
state is per-client and restart-restart-restart would loop).

The win: per-connection crash isolation, deadline propagation through
process linking (`exit(Pid, kill)` cascades down link tree), graceful
shutdown via shutdown signal that flows through the supervision tree.

### Go — `net/http` + `golang.org/x/sync/errgroup`

Single accept loop in `Server.Serve`:

```go
for {
    rw, err := l.Accept()
    if err != nil { ... }
    c := srv.newConn(rw)
    go c.serve(connCtx)  // one goroutine per connection
}
```

Inside `c.serve(ctx)`:
- HTTP/1 keep-alive: synchronous while-loop in this goroutine
- HTTP/2: spawn one goroutine per stream
- Cancellation via `context.WithCancel(ctx)` passed down; shutdown via
  closing the listener + cancelling root context
- No formal supervisor — goroutines self-recover via `defer recover()`
  in `serverHandler.ServeHTTP`; the default Go behavior is "panic in
  one request crashes only that goroutine"
- Graceful shutdown: `Server.Shutdown(ctx)` closes listener + waits for
  in-flight requests up to the context's deadline

What Go gets right: context propagation through the request handler
covers timeout/cancel/value. What it gets wrong (from a structured-
concurrency perspective): no scope-tree enforcement — handler goroutines
can outlive the connection that spawned them if they leak; no way to
guarantee child goroutines complete before parent returns.

### Rust — Tokio + Hyper + Axum

```rust
let listener = TcpListener::bind(addr).await?;
loop {
    let (stream, _) = listener.accept().await?;
    let io = TokioIo::new(stream);
    tokio::task::spawn(async move {
        if let Err(err) = http1::Builder::new()
            .serve_connection(io, service_fn(hello))
            .await
        { ... }
    });
}
```

Per-connection Tokio task; cancellation by dropping the task handle
(Tokio's `JoinHandle` drop cancels the task). Composition via
`tokio::select!` for timeout/cancel/read multiplexing — direct ancestor
of Quartz's unified select.

Tower middleware layer composition is Tokio's answer to Quartz's effects:
every middleware is a `Service` that wraps another `Service`. The
composition is type-level (each layer changes the type), which is
expressive but also famously hard to debug (deep type errors). Quartz's
effect handlers compose at runtime through the install stack; type
signatures stay simple.

Graceful shutdown via `tokio::sync::watch::channel` — main task signals,
all connection tasks watch the channel and exit cleanly.

### OCaml 5 — Eio (the post-multicore HTTP stack)

```ocaml
Switch.run @@ fun sw ->
  Net.listen ~sw socket ~backlog:128 (fun ~sw client_sock _addr ->
    Fiber.fork ~sw (fun () ->
      handle_connection client_sock
    )
  )
```

Switches are scopes. The outer `Switch.run` waits until every fiber forked
inside it completes; `Fiber.fork ~sw (fun () -> ...)` registers the new
fiber against switch `sw`. Cancellation propagates through the switch tree;
closing the switch cancels all fibers. Effect handlers (`Eio.Switch`,
`Eio.Cancel`) implement the propagation.

What Eio gets right that's directly relevant: switches/scopes are
*structural* — they enforce parent-outlives-child statically through the
nesting. Quartz's `with scope_root() do _ -> ... end` is the same shape.

### Python — Trio / Anyio

```python
async with trio.open_nursery() as nursery:
    async with trio.open_tcp_listeners(8080) as listeners:
        for listener in listeners:
            nursery.start_soon(serve_one_listener, listener)

async def serve_one_listener(listener):
    async with trio.open_nursery() as conn_nursery:
        async for conn in listener.serve():
            conn_nursery.start_soon(handle_connection, conn)
```

Nurseries = scopes. The outer nursery waits for all child tasks; cancel
propagates downward. Per-listener and per-connection nurseries make the
tree explicit. Cancel scopes (`trio.move_on_after(timeout)`) compose with
nurseries. This is *the* reference implementation for structured
concurrency in network servers.

### Zig — `std.http.Server`

Zig's stdlib HTTP server is currently single-threaded — accept loop +
sync handler. The community libraries (zhttp, zap) use thread pools.
Zig's not yet a leader in this space; not a primary reference.

### Caddy

Caddy is a Go server but interesting for its module composition story:
each "module" (HTTP handlers, TLS, middleware) is plug-in registered at
boot. Architecturally still goroutine-per-connection. Worth borrowing
the module-registration pattern for D.11's middleware chain composition.

### Synthesis — what Quartz takes

| Source | What Quartz adopts |
|---|---|
| **Cowboy** | Per-connection supervisor with restart strategy (one_for_one). Listener supervisor for accept-loop fault isolation. |
| **Tokio hyper** | `tokio::select!` shape → C.13's unified `select` for request-read / timeout / shutdown multiplexing. |
| **Eio / Trio** | Switch / nursery = scope tree; `Fiber.fork ~sw` = `Supervisor.start_child` under a scope. Closing the scope cancels all children. |
| **Go net/http** | Single accept loop, goroutine-per-connection as the *default* simple path. `Server.Shutdown(ctx)` deadline-bounded drain. |
| **Caddy** | Module-registration for middleware composition (`with_cors`, `with_logging`, etc. chain through a registered list). |

### Where Quartz can go further

- **Sub-ms cancel cascade.** `sched_wake_interrupts_sleep` (B.7 Phase 4e.8)
  interrupts a sleeping connection actor immediately on scope cancel; we
  don't wait for the next poll cycle. Cowboy/Tokio rely on cooperative
  yield → "kill" can take tens of ms at scale.
- **First-class deadline propagation through the scope tree.** A
  per-listener deadline auto-inherits to per-connection scopes which
  auto-inherit to per-request scopes. No `WithDeadline(ctx, ...)` chain
  to thread through; no `move_on_after` to remember.
- **Unified select across primitives.** Request-read (a Selectable on the
  socket) + timeout (a Selectable on a deadline) + shutdown-signal (a
  Selectable on the supervisor's cancel channel) all compose in one
  `select` expression. No middleware layers, no context-with-cancel
  bookkeeping.
- **Closed loop of self-hosting.** "This HTTP server is Quartz code,
  spawning Quartz Actors, supervised by a Quartz Supervisor, all running
  on a Quartz scheduler inside a Quartz kernel." The Soul page becomes
  the demonstration; D.11 is what makes the demonstration honest.

## Architecture (target shape)

```
                              http_serve(port) do |route| -> ... end
                              ╲
                               ╲
                                ╲
                            ┌───▼──────────────────────────────────────────┐
                            │  HttpServer (root scope; SIGTERM cancels)    │
                            │                                               │
                            │    ┌──────────────────────────────────────┐  │
                            │    │  ListenerSupervisor (one_for_one)    │  │
                            │    │     restart_strategy: one_for_one    │  │
                            │    │     max_restarts: 10 / 60s           │  │
                            │    │                                       │  │
                            │    │   ┌───────────────────────────────┐  │  │
                            │    │   │ ListenerActor                 │  │  │
                            │    │   │   loop:                       │  │  │
                            │    │   │     select                    │  │  │
                            │    │   │       case c = listener       │  │  │
                            │    │   │              .accept_select() │  │  │
                            │    │   │            => conn_sup        │  │  │
                            │    │   │              .start_child(c)  │  │  │
                            │    │   │       case _ = cancellable(   │  │  │
                            │    │   │              current_scope()) │  │  │
                            │    │   │            => return          │  │  │
                            │    │   │     end                       │  │  │
                            │    │   └───────────────────────────────┘  │  │
                            │    └──────────────────────────────────────┘  │
                            │                                               │
                            │    ┌──────────────────────────────────────┐  │
                            │    │  ConnectionSupervisor (one_for_one)  │  │
                            │    │     restart_strategy: temporary      │  │
                            │    │     max_restarts: 0 (don't restart   │  │
                            │    │       — connection state is dead)    │  │
                            │    │                                       │  │
                            │    │   ┌──────────┐  ┌──────────┐  ┌──┐   │  │
                            │    │   │ Conn 0   │  │ Conn 1   │  │..│   │  │
                            │    │   │ Actor    │  │ Actor    │  │  │   │  │
                            │    │   │ (scope   │  │ (scope   │  │  │   │  │
                            │    │   │  inherits│  │  inherits│  │  │   │  │
                            │    │   │  parent  │  │  parent  │  │  │   │  │
                            │    │   │  deadline│  │  deadline│  │  │   │  │
                            │    │   │  +cancel)│  │  +cancel)│  │  │   │  │
                            │    │   └──────────┘  └──────────┘  └──┘   │  │
                            │    └──────────────────────────────────────┘  │
                            └───────────────────────────────────────────────┘

Cancel cascade: SIGTERM → root scope cancel → ListenerActor select
fires `cancellable` arm → ConnectionSupervisor cancel → all connection
actors' `cancellable` arms fire simultaneously (sub-ms via active-wake).
```

### API surface

```qz
## High-level — route-based DSL (existing `http_serve` upgraded).
def http_serve(port: Int, body: Fn(Routes): Void can HttpRoute): Int

## Mid-level — explicit handler function.
def http_serve_with(config: HttpServerConfig, handler: Fn(Request): Response): Int

## Low-level — Actor/Supervisor surface for users who want full control.
## Caller supplies a spawn function that, when called, allocates a
## ConnectionActor inbox bound to a freshly-accepted fd + the routes
## table; dynamic_supervisor_spawn drives it.
def http_serve_actors(config: HttpServerConfig, conn_spawn_fn: Fn(Int, Routes): Int): Int

## TLS variants — same three tiers.
def https_serve(port: Int, tls: HttpsTlsConfig, body: Fn(Routes): Void can HttpRoute): Int
def https_serve_with(config: HttpServerConfig, tls: HttpsTlsConfig, handler: Fn(Request): Response): Int
def https_serve_actors(config: HttpServerConfig, tls: HttpsTlsConfig, conn_spawn_fn: Fn(Int, Int, Routes): Int): Int
                                                                                       # (fd, ssl_ptr, routes)

## Connection actor (the `actor` keyword desugars to Actor<T> machinery
## per C.14; the trait surface here is what the high-level entry points
## consume).
actor DefaultConnectionActor
  conn_fd: Int
  handler: Fn(Request): Response

  def handle_request(self, req: Request): Void
  def on_keepalive_timeout(self): Void = ()
  def on_terminate(self, reason: String): Void
end

## Wraps a Fn(Request): Response in a default connection actor.
def default_connection_actor_spawn(handler: Fn(Request): Response): Fn(Int, Routes): Int
```

Note on method-syntax sugar: The pseudocode above writes `self.handle_request(req)`
and `routes_dispatch(routes, req)` rather than `routes.dispatch(req)` because
UFCS-method-dispatch on user types is already in tree (`.dispatch(...)` works
when `routes_dispatch` exists). Paren-optional zero-arg method calls
(`scope.is_cancelled` ≡ `scope.is_cancelled()`) are the v5.28+ design
[`docs/design/DOT_METHOD_PAREN_ELISION.md`](DOT_METHOD_PAREN_ELISION.md); D.11
shouldn't take a dependency on it.

### Migration of existing entry points

All seven existing entry points stay (no breaking change yet — Quartz is
pre-launch, but D.11 ships in pieces, and breaking everyone's HTTP server
in one commit is overkill). Each existing entry point is rewritten to be
a thin shim over `http_serve_actors`:

```qz
# After D.11 Phase 3:

def http_serve_handler(port: Int, handler: Fn(Request): Response): Int =
  http_serve_actors(http_server_config(port), default_connection_actor(handler))

def http_serve_concurrent(port: Int, handler: Fn(Request): Response): Int =
  http_serve_actors(http_server_config(port), default_connection_actor(handler))

def http_serve_opts(config: HttpServerConfig, handler: Fn(Request): Response): Int =
  http_serve_actors(config, default_connection_actor(handler))
```

After all consumers migrate to one of the three new entry points, the
old names get removed in a separate commit. Per CLAUDE.md "delete dead
code outright" + project D7 absolutism.

## Phase plan

Sequenced for ship-as-we-go: each phase is independently committable +
validated. Estimates are quartz-day per the project's D9 calibration.

### Phase 0 — Design memo (this document) ✅

Establishes the shape. Lands as `docs/design/D11_HTTP_SERVER_MIGRATION.md`.

### Phase 1 — `ConnectionHandler` trait + default impl

~0.5 quartz-day. New `std/net/http_connection_handler.qz` module.

**Design refinement made during Phase 1 implementation**: shipped as
a `trait ConnectionHandler` rather than the `actor ConnectionActor`
the original memo outlined. Rationale:

1. HTTP connections aren't message-reactive — they're "spawn task,
   parse request loop, exit on close." That's a goroutine pattern,
   not a mailbox-driven one.
2. C.14 `actor` blocks on inbox; an HTTP connection blocks on socket
   read. Different blocking surface; forcing one into the other
   either creates a "driver goroutine" relaying socket reads to actor
   messages (extra plumbing) or makes the actor's only message a
   long-running `serve_loop()` (defeats the actor pattern).
3. `DynamicSupervisor`'s doc comment is explicit: "homogeneous
   population by construction (one spawn_fn)" — for message-processing
   workers, not for per-connection lifecycles.
4. The D.11 dogfooding goal is still met: trait + `extend` (C.14ish
   surface for the type, even though the C.14 actor *keyword* isn't
   used), unified `select` (C.13) in the keep-alive loop, scope tree
   (B.7), `Scoped` resources (B.8 for TcpListener / TcpStream).
5. The supervisor analog will be a custom dynamic-goroutine-supervisor
   built in Phase 2 (`http_dynamic_goroutine_sup`) modeled on
   `DynamicSupervisor`'s active-wake pattern but specialized for
   goroutines instead of actor inboxes. This is the cleanest path
   without changing C.14's `DynamicSupervisor` surface.

Phase 1 deliverables:

- `trait ConnectionHandler` with 4 methods: `on_open(self, conn_fd: Int)`,
  `handle_request(self, req: Request) → Response`,
  `on_keepalive_timeout(self)`, `on_terminate(self, reason: String)`
- `struct DefaultConnectionHandler` wrapping a `Fn(Request): Response`
- `extend DefaultConnectionHandler with ConnectionHandler` — handle_request
  delegates to the function; on_open / on_keepalive_timeout / on_terminate
  are no-ops
- `def default_connection_handler(handler: Fn(Request): Response): DefaultConnectionHandler`
- Spec: `spec/qspec/http_connection_handler_spec.qz` — trait dispatch,
  default-impl behavior, no-op lifecycle hooks

Renaming in subsequent phases: the entry point originally called
`http_serve_actors` becomes `http_serve_supervised` to match the
supervised-goroutine model. The new name is more accurate and stays
distinct from the C.14 `Actor<T>` machinery.

### Phase 2 — `http_serve_actors` core path (no TLS)

~1.5 quartz-day.

- New top-level entry point that wires the architecture above
- Uses existing `TcpListener` Scoped impl (B.8 Phase 5) for the listener
- Uses existing `TcpStream` Scoped impl for per-connection sockets
- Uses `Supervisor.new` + `sup.start_child` (C.14) for the connection
  supervisor
- Uses unified `select` (C.13) for the keep-alive loop's request-read /
  timeout / shutdown triple
- Spec: `spec/qspec/http_serve_actors_spec.qz` — accept N connections,
  handle one request each, shutdown cleanly

### Phase 3a — Shim the non-TLS entry points ✅ shipped 2026-05-24

Phase 3 split into 3a (non-TLS shims) and 3b (route DSL audit) /
Phase 6 (legacy body deletion + TLS-path shims when Phase 4 lands).

**3a shipped** ([d.11 phase 3a]): `http_serve_handler`,
`http_serve_async`, `http_serve_concurrent`, and `http_serve_opts` all
become 1-line shims through `http_serve_supervised`. ~280 LoC of
legacy kqueue/blocking-accept bodies replaced. Callers gain keep-alive,
supervisor-restart on handler crash, graceful shutdown via SIGTERM/
SIGINT, and cross-platform support (the previous `http_serve_handler`
and `http_serve_async` were `@cfg(os: "macos")` kqueue-only).

**The route DSL `http_serve(port, body)` auto-routes** — it lowers
through `http_serve_handler` already, so the shim picks it up.

**TLS path stays on legacy bodies**: `http_serve_tls` and
`http_serve_tls_opts` are unchanged in 3a, since the supervised path
doesn't yet support TLS (Phase 4 work). The legacy
`_handle_connection_async` / `_handle_connection_keepalive` helpers
therefore stay alive until Phase 4 + Phase 6 delete them together.

**Verification**: cleaned `.quartz-cache` then compiled 5 consumers
(examples/http_effects.qz, tools/prod_server.qz, tools/h2_test_server.qz,
examples/qz-http/main.qz, spec/qz/http_serve_supervised_smoke.qz) —
all 5 pass `llc` cleanly with no errors. End-to-end: supervised smoke
binary serves 3 curl requests with `ok-from-supervised` body + clean
SIGTERM exit 0.

**Known caveat — file forward**: under shimmed entry points, the
`.qzmod` / INC cache exhibits cross-compile pollution
(`[[feedback-resolver-dedup-phase2c-limitations]]` Bug 9): compiling
two different consumers sequentially without `--no-cache` can make the
second consumer's IR contain references to functions from the first
consumer's source. Workaround: `--no-cache` on consumer compiles or
`rm -rf .quartz-cache` between compiles. PRE-shim trunk does not
exhibit this — the bug is specifically an interaction between the
shim's collapsed call graph and the cache invalidation logic.

### Phase 3b — Delete legacy helpers ✅ shipped 2026-05-24

**Shipped**: with all 7 entry points now shims (Phase 3a + Phase 4), the
internal helpers behind them were orphaned. Single-commit deletion sweep
in `std/net/http_server.qz`:

- `_handle_connection_async` + `_handle_connection_keepalive` (the per-
  conn bodies the deleted async/opts kqueue loops invoked)
- `_async_http_parse_request` + `_async_http_write_response` (no-timeout
  variants only `_handle_connection_async` called; the `_timeout`
  variants the supervised path uses stayed)
- `_http_decode_fd` (the kqueue ev-loop's fd-from-status decoder)
- `kqueue` + `kevent` externs (no caller after the helpers above died)
- macOS kqueue constants (`EVFILT_READ/WRITE`, `EV_ADD/DELETE/ENABLE/EOF`,
  `KEVENT_SIZE`, `MAX_EVENTS`)
- `kevent_set` / `kevent_get_ident` / `kevent_get_filter` / `kq_add_read`
  / `kq_add_readwrite` / `kq_remove` (kqueue helper layer)
- `ptr_write_i16/i32/i64` + `ptr_read_i16/i32/i64` (only kevent_*
  reached for these; the canonical versions live in `std/ffi/event.qz`
  and are unaffected)
- `tls_read_bytes` / `tls_read_line_raw` / `tls_write_str` /
  `http_parse_request_tls` / `_tls_write_response` (the blocking-SSL
  TLS-helper layer from the deleted kqueue TLS body; supervised TLS
  uses `_async_tls_*` exclusively)
- `HttpError::KqueueCreateFailed` + `HttpError::KeventWaitFailed` enum
  variants + their format arms

Net: `std/net/http_server.qz` 4011 → 3644 lines (-367). Two qspec spec
arms updated to drop assertions on the deleted enum variants
(`phase_6_1b_http_throws_spec.qz` + `phase_6_1b_tls_throws_spec.qz`).

**Verification**: 7 consumers (`spec/qz/http_serve_supervised_smoke.qz`,
`examples/http_effects.qz`, `tools/prod_server.qz`,
`tools/h2_test_server.qz`, `examples/qz-http/main.qz`, `tools/doc.qz`,
`spec/qz/accept_worker_smoke.qz`) compile + llc clean. Five spec files
(`phase_6_1a/b/c/d`, including both `_b_*`) build + run green.
End-to-end smoke against `spec/qz/https_serve_supervised_smoke.qz`:
5 trials × (3 `curl --http1.1` + 3 `curl --http2`) =
**15/15 h1.1 + 15/15 h2 + 5/5 clean SIGTERM**.

**Open follow-up**: Phase 6 entry-point name deletion (`http_serve_handler`,
`http_serve_async`, `http_serve_tls`, `http_serve_concurrent`,
`http_serve_opts`, `http_serve_tls_opts`) is next — Phase 3b leaves them
as 1-line shims; Phase 6 flips the 4 in-tree consumers off them and
deletes the names entirely (D7 absolutism, pre-launch project).

### Phase 4 — TLS variant (`https_serve_supervised`) ✅ shipped 2026-05-24

**Renaming**: shipped as `https_serve_supervised` rather than the original
`https_serve_actors`, matching the same rename the plain-HTTP path took
in Phase 2 (`http_serve_supervised`, supervised-goroutine model, not
C.14 `Actor<T>` machinery).

**4 shipped** ([d.11 phase 4]): `https_serve_supervised(config, tls_config, handler)`
mirrors the `http_serve_supervised` shape with TLS init/teardown
around it. Per-connection body delegates to the existing
`_tls_accept_and_dispatch` helper — which already does the async TLS
handshake (via `_async_tls_accept`), reads ALPN, and dispatches to
either `_h2_handle_connection` (h2 path) or
`_handle_tls_connection_with_ssl` (HTTP/1.1 keepalive). The supervised
wrapper just spawns this dispatch under `http_dyn_gsup` so per-conn
goroutines are tracked + drained on shutdown. ~217 LoC added, ~302 LoC
deleted (net -85).

**Both TLS entry points shimmed**: `http_serve_tls(port, cert, key, h)`
and `http_serve_tls_opts(config, tls, h)` both become 1-line shims
through `https_serve_supervised`. The macOS-only kqueue body of the
original `http_serve_tls` (~170 LoC) is deleted; the function gains
cross-platform support, keep-alive, ALPN+h2, supervisor-restart,
and graceful shutdown as side effects. `_handle_tls_connection_keepalive`
(orphaned helper from a prior refactor, never called even pre-Phase-4)
deleted in the same commit per D7.

**tls_recvable/tls_sendable Selectables filed forward**: the design
memo's original Phase 4 surface called for new TLS Selectable impls so
the per-conn loop could use unified `select`. Shipped instead as the
existing poll-based dispatch (same surface choice as Phase 2c for plain
HTTP — `http_request_selectable` was deferred there for the same
reason). When `http_request_selectable` lands as a unified
cross-poll-buffer Selectable, `tls_recvable`/`tls_sendable` ship at the
same time as a single phase. The cross-poll-buffer state machinery
(SSL_pending + io_suspend interlock) is the gating mechanism.

**Verification**:
- `quake guard` PASS — fixpoint verified at 2695 functions
- 6 consumers pass `llc` clean: `examples/http_effects.qz`,
  `tools/prod_server.qz`, `tools/h2_test_server.qz`,
  `examples/qz-http/main.qz`, `spec/qz/http_serve_supervised_smoke.qz`,
  `spec/qz/https_serve_supervised_smoke.qz` (new)
- End-to-end h1.1 smoke (`spec/qz/https_serve_supervised_smoke.qz`):
  3 sequential `curl --insecure --http1.1` requests return 200 with
  body `ok-from-https-supervised`; SIGTERM → exit 0 with
  "Shutting down gracefully (HTTPS supervised)..." logged

**h2 closeout (2026-05-24, follow-up to Phase 4)**: the pre-existing
`_h2_handle_connection` crash filed forward at Phase 4 ship time is
**CLOSED**. Four bugs across four commits on top of the Phase 4
baseline:

| Bug | Commit | Mechanism |
|-----|--------|-----------|
| A | `d271f5e7` | `_h2s_*` accessors used byte offsets {0..56} where Quartz `store`/`load` are i64-slot-strided — `malloc(64)` stomp on adjacent heap |
| B | `0fced22b` | `map_get` returns `Option<T>`; 8 sites in `_h2_handle_connection` fed the Option box as a raw `H2Stream` ptr. Replaced with `map_fetch` |
| C | `180b1ba4` | Same class as A on a different chunk — `_h2_read_frame_into` + 5 `_h2f_*` accessors wrote/read bytes {0,8,16,24,32} into `malloc(40)` as slot indices → 216-byte overrun per frame read |
| D | `749b8950` | Process-wide `signal(SIGPIPE, SIG_IGN)` at both supervised entry points (Quartz runtime never installed SIGPIPE; same default as Go/nginx/Apache/Node/Python) |

End-to-end verification: 10 trials × 5 `curl --http2` requests against
`https_serve_supervised` = **50/50 HTTP/2 200** with correct bodies,
**10/10 clean SIGTERM exit 0**. h1.1 path unchanged (10/10 200 + clean).
Phase 4's `https_serve_supervised` is now production-ready for BOTH
h1.1 and h2 — `_tls_accept_and_dispatch` dispatches by ALPN, both
branches green. SOUL.7 deploy can ship with h2 (was previously
gated to h1.1-only).

See `[[feedback-h2-handle-connection-crash-pre-phase4]]` for the full
bug-by-bug analysis + the same-bug-class observation (Bugs A and C are
the same stdlib-author error mode: `store(p, byte_off, ...)` written
from C-pointer-arithmetic muscle memory, where the codegen actually
strides by i64 slots).

### Phase 5 — Routes DSL polish

~0.5 quartz-day.

- `http_serve(port) do |route| -> ... end` becomes the recommended
  high-level entry; rewritten over `http_serve_actors`
- `with_cors` / `with_logging` / `with_compression` middleware chain
  factored as `ConnectionActor` decorators
- Spec: existing `phase_6_1f_cors_config_spec` / `http_routes_spec`
  stay green

### Phase 6 — Migrate hosted-target consumers + dead code deletion ✅ shipped 2026-05-24

**Shipped**: 4 in-tree consumers flipped + 6 shim entry-point names
deleted in a single commit:

  Consumers flipped:
  - `examples/http_effects.qz` line 80: `http_serve_handler(8080, h)`
    → `http_serve_supervised(http_server_config(8080), h)`
  - `tools/prod_server.qz` line 24: `http_serve_opts(config, ...)`
    → `http_serve_supervised(config, ...)`
  - `spec/qz/accept_worker_smoke.qz` line 10: `http_serve_opts(...)`
    → `http_serve_supervised(...)`
  - `tools/h2_test_server.qz` line 11: `http_serve_tls_opts(config, tls)`
    → `https_serve_supervised(config, tls)`

  Entry-point shims deleted:
  - `http_serve_handler` + Phase 3a "Server Core" banner
  - `http_serve_async` + Phase 3a narrative comment
  - `http_serve_tls` + Phase 4 "Serve HTTPS" shim banner
  - `http_serve_concurrent` + "Concurrent HTTP Server" banner
  - `http_serve_opts` + "Production HTTP Server" banner
    (renamed to "Shutdown coordination")
  - `http_serve_tls_opts` + "Production HTTPS Server" banner
    (renamed to "HTTPS Substrate")

  Kept: `http_serve(port) do -> ... end` (route DSL — recommended
  high-level form), pivoted to forward directly to
  `http_serve_supervised(http_server_config(port), router_handler(router))`
  instead of through the deleted `http_serve_handler` shim. The
  `@cfg(os: "macos")` gate (vestigial from the kqueue era) was
  dropped, making the route DSL cross-platform along with the rest of
  the server.

  Plus: docstring + ghost-trace cleanup across `std/net/http_server.qz`,
  `std/net/tls.qz`, `docs/EFFECTS.md`, and `spec/qspec/phase_6_1*`
  (4 spec files) — removed references to the deleted names so the live
  documentation describes the live API. The historical narration of
  "legacy http_serve_opts" / "previous kqueue body" was removed (D7);
  commit message preserves it for archaeology.

Net: `std/net/http_server.qz` 3644 → 3554 lines (-90). Combined with
Phase 3b: 4011 → 3554 lines total (-457 across Phase 3b + Phase 6).

**Surviving server entry-point surface**:

| Entry point | Shape | Purpose |
|---|---|---|
| `http_serve(port, body)` | route DSL | recommended for new code |
| `http_serve_supervised(config, handler)` | config + single dispatcher | dispatcher-shape callers |
| `https_serve_supervised(config, tls, handler)` | TLS counterpart | ALPN h2/h1.1 dispatch |
| `http_server_config(port)` | config factory | |
| `http_server_shutdown()` | shutdown signal | thread-safe, from any task |

**Verification**: 7 consumers (`spec/qz/http_serve_supervised_smoke.qz`,
`examples/http_effects.qz`, `tools/prod_server.qz`, `tools/h2_test_server.qz`,
`examples/qz-http/main.qz`, `tools/doc.qz`, `spec/qz/accept_worker_smoke.qz`)
compile + llc clean. Four qspec arms run green
(`phase_6_1a_http_log_migration_spec`, `phase_6_1b_http_throws_spec`,
`phase_6_1c_concurrent_effect_frames_spec`,
`phase_6_1d_http_route_dsl_spec`). End-to-end against
`spec/qz/https_serve_supervised_smoke.qz`:
**5 trials × (3 curl --http1.1 + 3 curl --http2) = 15/15 h1.1 + 15/15 h2 + 5/5 clean SIGTERM**.

**`docs/QUARTZ_REFERENCE.md`**: no HTTP server section exists yet (the
language reference is the surface-syntax spec). When the HTTP-server
chapter is written, it will describe only the 5 surviving entry points.

### Phase 7 — Freestanding-kernel bridge (sub-epic; see below)

The userland migration (Phases 1–6) is independently shippable. The
freestanding-kernel bridge is what lets the unikernel itself USE the
migrated `std/net/http_server` to serve the Soul page. This is the
larger sub-epic; see "Freestanding-bridge sub-epic" below.

Estimated 1–2 quartz-weeks for the bridge alone. The unikernel's
current hand-rolled HTTP path in `tools/baremetal/hello_x86.qz` keeps
working through this phase; the bridge enables but does not require the
kernel-side migration.

### Phase 8 — Unikernel migrates to `std/net/http_server` (split into 8a/8b/8c, 2026-05-24)

**Re-shape rationale**: B.6 (kernel TcpStream/Listener Scoped impls) was
originally framed as a separable ~0.5 qd phase in the bridge memo. That
framing assumed `tcp_close(fd)` existed in the kernel — it doesn't. Kernel
TCP is packet-level slot-based: `tcp_send(slot, ...)`, `tcp_accept_syn`,
`tcp_free_slot(slot)`. No fd, no `tcp_listen`, no `tcp_accept` returning
fd. Consequently B.6 is not separable from Phase 8 — it's a ~10-line
subroutine inside the kernel fd-emulation layer Phase 8a builds.

### Phase 8a — Kernel fd-emulation layer (`@cfg` freestanding branch in `std/net/tcp.qz` + `std/ffi/socket.qz`)

~2–3 quartz-days. Absorbs B.6.

**Goal**: Make `std/net/tcp.qz` callable from freestanding code by
providing `@cfg`-aware bodies for every POSIX socket call that
`http_serve_supervised` / `https_serve_supervised` reach. fd ≡ slot ptr.

Surface to provide (each as a `@cfg(target: …freestanding…)` body
alongside the existing POSIX one):

| Userland call | Kernel mapping |
|---|---|
| `tcp_listen(port) -> ListenResult` | Register port in a kernel listening-table; return `TcpListener { fd: <table-slot ptr>, port }` |
| `tcp_listener_set_nonblocking(l) -> Int` | No-op (kernel TCP is always non-blocking) |
| `tcp_acceptable(l_fd) -> Selectable<Int>` | Wrap the kernel listening-slot's accept-queue; on poll, return next ESTABLISHED slot ptr; on no-pending, register waker via the K8.6 BLOCKED state (B.4 bridge) |
| `tcp_stream(fd, host, port)` | Construct `TcpStream` with fd = slot ptr |
| `async_tcp_read(fd, buf, max)` | Drain `conn_rx_chan(slot)` + parse TCP payload into buf; suspend via B.4 bridge when chan empty |
| `async_tcp_write(fd, buf, len)` | Chunk through `tcp_send(slot, snd_nxt, conn_rcv_nxt(slot), TCP_FLAG_ACK \| TCP_FLAG_PSH, buf, chunk)`; suspend when peer window full |
| `socket::socket_set_nonblock(fd)` | No-op |
| `tcp_close(stream)` | `tcp_free_slot(slot)` after sending FIN |
| `tcp_close_listener(listener)` | Unregister port from listening-table |
| `signal_on_flag(sig, flag)` | No-op; kernel maps shutdown to `scope_cancel(root)` from `uart_shutdown` path (per bridge memo Q5) |

**B.6's Scoped impls** ship as part of this phase — the existing
`extend TcpStreamGuard with Scoped` / `extend TcpListenerGuard with
Scoped` in `std/net/tcp.qz` already call `tcp_close(stream)` /
`tcp_close_listener(listener)`. Once those have freestanding bodies,
the Scoped impls just work.

**Implementation choice**: `@cfg` branches in `std/net/tcp.qz` +
`std/ffi/socket.qz` (mirror the existing `@cfg(os: ...)` pattern, with a
new `@cfg(target_env: "freestanding")` or equivalent gate). NOT a new
`std/net/tcp_kernel.qz` file — that would duplicate the public surface
and force consumers to choose which to import. The bridge memo's "or a
@cfg branch in std/net/tcp.qz" alternative is the right choice now that
the surface is bigger than 1–2 fns.

**Smoke** (success criterion): kernel boots, runs `def main() { var l =
tcp_listen(80); with tcp_listener_scoped(l) do _ -> { var s =
tcp_accept(l); with tcp_stream_scoped(s) do _ -> { var req =
async_tcp_read(s.fd, buf, 1024); async_tcp_write(s.fd, "HTTP/1.1 200 OK\\r\\n\\r\\nhi", 22) } end } end }` and a `curl` from the host returns
"hi" + clean teardown verified via subsequent `curl` succeeding (port
freed).

**Per-step plan** (added 2026-05-24 after the merge-from-B.6 re-eval):

| Step | Description | Sized | Status |
|---|---|---|---|
| 8a.1 | `@cfg(os: "unknown")` typecheck-only stubs in `std/ffi/socket.qz` for SOL_SOCKET / SO_REUSEADDR / SO_RCVTIMEO / SO_SNDTIMEO / EINPROGRESS / EWOULDBLOCK / EAGAIN / socket_last_error. Makes `std/net/tcp.qz` typecheck for `--target x86_64-unknown-none-elf`. No runtime semantics — bodies in tcp.qz still call POSIX externs that won't link freestanding, but typecheck is unblocked so subsequent steps can add real `@cfg` branches. | ~0.5 qd | ✅ `77e6b4e0` |
| 8a.2 | Kernel listening-table data structure + `tcp_listen` / `tcp_close_listener` `@cfg` branches. Side-table indexed by port → `TcpListener { fd: <table-slot ptr>, port }`. `tcp_listen(80)` registers; `tcp_close_listener(l)` unregisters. Slot ptr serves as fd. | ~0.5–1 qd | ✅ `b024adff` |
| 8a.3 | `conn_body` → `kern_tcp_conn_pump` rename + listening-entry growth (accept_chan + userland_mode) + multi-port dispatch in `tcp_handle_ipv4` + `SLOT_USERLAND_MODE` + payload-rx slot plumbing + ESTAB-data branch fork + `kern_tcp_accept` + `tcp_accept` `@cfg(os: "unknown")` body + scoped impls work transitively. Designed 2026-05-24 PM, see sub-section below. **Wait semantics: kernel-internal accept channel, NOT B.4 — channel recv IS the kernel's wait primitive.** | ~0.5–1 qd | ✅ `1f663877` |
| 8a.4 | `async_tcp_read` `@cfg(os: "unknown")` (drain payload-rx ring via cap=1 signal channel) + `async_tcp_write` `@cfg(os: "unknown")` (piggyback on existing SLOT_RESP_* / tcp_try_push retransmit machinery + new SLOT_TX_DONE_CHAN). `tcp_close` `@cfg(os: "unknown")` (kern_tcp_close sends FIN). Replaces `@cfg(not: os: "wasi")` with `@cfg(not: os: "unknown")` (live targets: macos/linux/windows; wasi never had a real impl). **Designed 2026-05-24 PM. Implementation surfaced + fixed two latent kernel bugs en route:** (a) `tcp_find_slot` was matching only (peer_ip, src_port) — curl reusing ephemeral source ports across different host-side hostfwd targets routes both connections to the same slot. Added `SLOT_LOCAL_PORT` (set from listening entry's PORT field) + 6-tuple match. (b) `tcp_send` hardcoded src-port to `TCP_LISTEN_PORT == 80` — multi-port outgoing replies stamped wrong src; peer wouldn't ACK SYN+ACK from port 80 when it had connected to port 5559. Both close on the same fix: store the local port on the slot at accept time. | ~0.5–1 qd | ✅ `6e967c23` |
| 8a.5 | `tcp_acceptable` Selectable `@cfg` branch. Freestanding `_tcp_acceptable_try_poll` calls new `kern_tcp_try_accept` (peek accept_chan via `chan_count` under CHAN_LOCK, then `chan_recv` on hit; 0 sentinel on empty/closed). `_tcp_acceptable_register_waker` / `_unregister_waker` forward to `kernel_waiter_register` / `_unregister` (B.5c side-table) keyed on the accept channel ptr — `tcp_accept_syn`'s `chan_send` already calls `kernel_waiter_wake_all(accept_chan)`, so registered select-arms wake without polling. Plus `tcp_listener_set_nonblocking` / `socket::socket_set_nonblock` / `socket_set_blocking` no-op `@cfg(os: "unknown")` bodies (kernel TCP is always non-blocking). Plus `signal_on_flag` codegen-side gate on `cg_is_freestanding(state.target_triple)` that suppresses the `@qz_signal_on_flag` call (the runtime helper isn't emitted in freestanding builds; kernel routes shutdown via `uart_shutdown` → `scope_cancel(root)`). | ~0.5–1 qd | ✅ `2c532f23` |
| 8a — total | | **~2.5–4 qd** (revised down after 3+4 design) | |

8a.1 unblocks typecheck only. 8a.2–8a.5 progressively add runtime
semantics, ending with a freestanding-runnable smoke that proves the
fd-emulation layer works before Phase 8b plugs in `http_serve_supervised`.

#### Phase 8a steps 3+4 — conn_body refactor design (added 2026-05-24 PM)

After step 2 shipped, the prior session flagged that steps 3+4 are
coupled by the kernel's connection lifecycle: today `tcp_accept_syn`
auto-spawns a single per-connection goroutine (`conn_body`) that does
**both** TCP-state work and inline HTTP work. Userland
`http_serve_supervised` expects a different shape: `tcp_accept(l)`
returns an fd, then the caller (`http_dyn_gsup_spawn_one`) spawns a
goroutine that drives the connection via `async_tcp_read` /
`async_tcp_write`.

This sub-section answers the four open questions from the handoff so
steps 3 and 4 can be coded against a fixed design.

##### Q1 — Unified `conn_body` (with HTTP-mode off switch), or formal split into a kernel-side TCP pump + a userland-side HTTP goroutine?

**Choice: formal split, gated by a per-slot `SLOT_USERLAND_MODE` flag during the 8a→8c transition.**

Phase 8c will delete `http_build_response` and the hand-rolled HTTP
plumbing from `hello_x86.qz`, so after 8c there is no inline HTTP work
for `conn_body` to do — the HTTP work must live elsewhere. The "elsewhere"
is the goroutine that `http_dyn_gsup_spawn_one` spawns from
`http_serve_supervised` after `tcp_accept` returns.

The TCP state machine itself (SYN_RCVD completion, ESTAB ACK tracking,
data sequencing, FIN exchange, LAST_ACK, retransmission tick) **stays in
the kernel**. It is literally the TCP stack — userland doesn't see TCP
headers. `conn_body` is renamed `kern_tcp_conn_pump` and keeps everything
the existing state machine does *except* the inline HTTP call in the
ESTAB-data branch.

During 8a step 3+4 (before 8b lands), the kernel's hand-rolled
HTTP demo at `tools/baremetal/hello_x86.qz` is still the live HTTP
server. We can't yank the inline-HTTP path from `conn_process_frame`
yet — that breaks the kernel demo. So the slot mode flag is the
load-bearing mechanism:

- `SLOT_USERLAND_MODE == 0` (default): legacy inline HTTP path. ESTAB-data
  branch calls `http_build_response` + `tcp_arm_response` +
  `tcp_try_push`. **Unchanged from today.**
- `SLOT_USERLAND_MODE == 1`: userland path. ESTAB-data branch deposits
  payload bytes into the slot's payload-rx ring and signals the userland
  goroutine via the payload-rx signal channel.

The mode is set at `tcp_accept_syn` time, looked up from the matching
listening-table entry. A port registered via `kern_tcp_listen` (i.e.,
the freestanding `tcp_listen` body called from userland code) has
`userland_mode = 1` on its listening entry; the hardcoded
`TCP_LISTEN_PORT == 80` path uses `userland_mode = 0` until Phase 8b
flips the demo over.

After Phase 8c, the legacy path is deleted, the mode flag becomes
trivially-always-1, and the flag itself can be removed. The hack is
*temporary by design* — it's the 8a/8b/8c sequencing in code form.

##### Q2 — New per-conn payload channel for rx, or reuse `conn_rx_chan`?

**Choice: new payload-rx channel + new payload-rx ring buffer. `conn_rx_chan` stays as-is.**

`conn_rx_chan` carries Ethernet-frame-length tokens; the payload sits
in `SLOT_RX_SCRATCH` (4 × 1500 B raw frame ring). The TCP state machine
in `conn_process_frame` parses headers out of each frame and extracts
payload. **The HTTP goroutine doesn't want Ethernet frames — it wants
TCP payload bytes.** Reusing `conn_rx_chan` would force the HTTP
goroutine to redo IP+TCP header parsing, which inverts the layering.

New slot fields (extends the existing 192-byte conn slot — current high
watermark is offset 106, leaving 86 bytes free):

| Offset | Width | Name | Owner | Description |
|---|---|---|---|---|
| 112 | U64 | `SLOT_PAYLOAD_RX_CHAN` | shared | cap=1 signal channel; "data available" notification |
| 120 | U64 | `SLOT_PAYLOAD_RX_SCRATCH` | shared | ring buffer ptr (one 4 KiB PMM page) |
| 128 | U32 | `SLOT_PAYLOAD_RX_WRITE_OFF` | TCP pump | monotonic write cursor |
| 132 | U32 | `SLOT_PAYLOAD_RX_READ_OFF` | userland | monotonic read cursor |
| 136 | U8 | `SLOT_USERLAND_MODE` | TCP pump | 0 = legacy inline HTTP, 1 = userland |

Reader/writer protocol: cursors are monotonic U32; available bytes =
`write_off - read_off`. Wraparound into the 4 KiB ring is via
`off mod 4096`. The 1-cap signal channel is idempotent: TCP pump does
`chan_try_send(payload_rx_chan, 1)` after each write; userland does
`chan_recv` to block-until-available, then drains as many bytes as
possible. If userland's `max_bytes` doesn't exhaust the ring, the
next `async_tcp_read` call gets the leftover without needing a putback.

##### Q3 — `tcp_accept` blocking semantics: kernel-internal channel or B.4 suspend/wake?

**Choice: kernel-internal accept channel per listening-table entry.**

`chan_recv` IS the suspend/wake primitive in the kernel — a `chan_recv`
on an empty channel parks the goroutine via the K8.6 sleep path, and a
matched `chan_send` wakes it via the active-wake side-table. B.4
suspend/wake is for non-channel waits (timers, signal flags). The
accept queue is channel-shaped: producer = `tcp_accept_syn` (in main's
dispatcher), consumer = `tcp_accept` (in the listener's owning
goroutine). Use the channel.

Listening-table entry grows from 16 → 32 bytes:

| Offset | Width | Name | Description |
|---|---|---|---|
| 0 | U64 | `KERN_LISTEN_ENTRY_ACTIVE` | (existing) 1 = listener live |
| 8 | U64 | `KERN_LISTEN_ENTRY_PORT` | (existing) listening port |
| 16 | U64 | `KERN_LISTEN_ENTRY_ACCEPT_CHAN` | accept-queue chan ptr (cap = CONN_SLOTS = 64) |
| 24 | U8 | `KERN_LISTEN_ENTRY_USERLAND_MODE` | 1 = freestanding-stdlib registered this port |

Capacity = CONN_SLOTS is load-bearing: a SYN can only be accepted when a
conn slot allocates (gated by `tcp_find_free_slot`), so the accept
channel can never be more backed up than the slot table itself.
`chan_try_send` from `tcp_accept_syn` therefore cannot fail in practice;
we use `chan_try_send` (not blocking `chan_send`) because main's
dispatcher runs in main's stack and must not block on the scheduler.

**Multi-port dispatch**: step 3 also replaces the `TCP_LISTEN_PORT == 80`
hardcode in `tcp_handle_ipv4` with `kern_tcp_listen_lookup(dst_port)`.
The lookup was added in step 2 with no caller; step 3 wires it in. After
the swap, a SYN for any registered port (kernel-hardcoded or userland-
registered) finds its listening entry; `userland_mode` on that entry
flows into the new conn slot.

##### Q4 — Steps 3 and 4 — one commit or two?

**Choice: two commits.** Same step boundary as the doc has today.

- **Step 3 commit**: conn_body → kern_tcp_conn_pump rename + listening-
  entry growth (accept_chan, userland_mode) + multi-port dispatch swap
  in tcp_handle_ipv4 + `SLOT_USERLAND_MODE` + payload-rx slot fields
  (channel + ring + cursors, but only the *plumbing* — read path lands
  in step 4) + ESTAB-data branch fork (legacy vs payload-ring deposit) +
  `kern_tcp_accept` symbol + `tcp_accept` `@cfg(os: "unknown")` body in
  `std/net/tcp.qz` + extern decl + IR-emission tests.

  **Smoke for step 3**: standalone smoke compiled into `qemu_http`:
  ```
  def smoke_8a3(): Void
    match tcp_listen(80)
      Ok(l) =>
        uart_put_str("[8a.3] tcp_listen ok slot=")
        uart_put_uint(l.fd)
        match tcp_accept(l)
          Ok(s) =>
            uart_put_str(" tcp_accept ok slot=")
            uart_put_uint(s.fd)
            tcp_close_listener(l)
          ...
  ```
  Trigger from host: `curl http://localhost:5559/ &` then verify both
  log lines appear in UART output. Step 3 doesn't yet read or write
  payload; the SYN_RCVD → ESTAB transition firing the accept channel is
  what we're proving.

- **Step 4 commit**: `async_tcp_read` `@cfg(os: "unknown")` body (drains
  the payload-rx ring via the cap=1 signal channel) + `async_tcp_write`
  `@cfg(os: "unknown")` body (piggybacks on the existing
  `tcp_arm_response` / `tcp_try_push` machinery: user buffer → `SLOT_RESP_BODY_PTR` direct ref,
  `SLOT_RESP_BODY_LEN` = user len, `SLOT_RESP_HDR_LEN` = 0,
  `conn_set_resp_active(slot, 1)`, then chan_recv on a new
  `SLOT_TX_DONE_CHAN` signaled from the ACK branch when snd_una catches
  up). Replaces the existing `@cfg(not: os: "wasi")` gate on the userland
  bodies with an explicit OS list (`os: ["macos", "linux", "windows"]`)
  + a parallel `@cfg(os: "unknown")` branch.

  **Smoke for step 4**: extends step 3's smoke to read one HTTP request
  + write a 22-byte `HTTP/1.1 200 OK\r\n\r\nhi` response. Host-side
  `curl http://localhost:5559/` returns `hi`; subsequent `curl` also
  succeeds (slot freed). This is the exact smoke described at the top
  of the Phase 8a section.

**Why not one combined commit?** Step 3 is the architectural change
(refactor + listening-entry growth + multi-port dispatch + mode flag).
Step 4 is purely I/O wiring on top. If step 4 finds a problem with the
payload-rx ring shape, we want to be able to amend just the I/O without
re-touching the TCP-pump refactor.

**Updated step sizing**: steps 3+4 combined now sized at **1.5–2 qd**
(down from "step 3 ~0.5–1 qd + step 4 ~1–2 qd = ~1.5–3 qd" pre-design).
The refactor is cleaner than feared because the SLOT_RESP_* machinery
is reusable for async_tcp_write without rewriting retransmits.

#### Filed forward from steps 3+4

- **Step 3 leaves the legacy inline-HTTP path live.** `SLOT_USERLAND_MODE == 0`
  preserves bug-for-bug existing behavior on port 80 until Phase 8b
  flips it. No mid-flight migration risk.
- **Per-slot tx-done channel allocation.** Step 4 introduces a new
  `SLOT_TX_DONE_CHAN` cap=1 channel per slot. Lazy-alloc on first
  userland-mode write (mirroring `SLOT_RX_CHAN`'s lazy-alloc in
  `tcp_accept_syn`).
- **`tcp_acceptable` Selectable (step 5).** Still pending. The accept-
  channel infrastructure landed in step 3 IS the substrate for
  `tcp_acceptable` — step 5 wraps it as a Selectable with
  `register_waker` integration.

### Phase 8b — `http_serve_supervised` consumed in kernel (smoke + golden)

~1.5–2.5 quartz-days (revised up after 8b.1 recon: the freestanding
typecheck unblock is the easy part; making the kernel actually LINK
against http_server.qz requires libc_stubs.c additions for the
residual dead-code-emitted symbols — 8b.2).

`tools/baremetal/hello_x86.qz` adds a goroutine that calls
`http_serve_supervised(http_server_config(80), |req| ->
{ build_soul_landing(req) })`. Verify the existing Soul page + SOUL.6
demo endpoints return identical bytes to the current hand-rolled path
(byte-for-byte golden if feasible, or curl-roundtrip parity). At this
point the kernel HTTP serves through `std/net/http_server.qz` — the
dogfooding goal of D.11 is met.

**Per-step plan** (added 2026-05-25 AM after step 8b.1 ship):

| Step | Description | Sized | Status |
|---|---|---|---|
| 8b.1 | `@cfg(os: "unknown")` branches for the http_server.qz hot path: `_http_get_errno` / `_http_EAGAIN` stubs, `set_nonblocking` no-op, `_async_http_recv` / `_async_http_send` (+ `_timeout` variants) delegating to `async_tcp_read` / `async_tcp_write`, `tcp_write_str` (used by `_http_send_503` on the load-shed branch), `_http_ignore_sigpipe` no-op, and a new `_http_close_fd` shim wrapping `close(fd)` / `kern_tcp_close(fd)` (6 call sites). Plus compiler-side gate making `sched_yield` lower to `call void @yield_now()` (not `@usleep`) in freestanding. http_server.qz now typechecks for `--target x86_64-unknown-none-elf`. | ~0.5–1 qd | ✅ `c7c6f6fb` |
| 8b.2 | `str_from_int` intrinsic gate: under freestanding, lower to `call i64 @qz_int_to_str(i64 %n)` (the pure-IR i64→decimal helper already emitted by `cg_emit_int_to_str_helper` in the freestanding branch of `cg_emit_runtime_decls`). Hosted keeps the existing `@sprintf` + `@.fmt.int.noln` + `@qz_wrap_cstr` chain. Closes the str_from_int reachability path through `http_error_format` and `_async_http_write_response_timeout` (status line + Content-Length). | ~0.5 qd | ✅ `2d916839` |
| 8b.2.b — partial | Two compiler-side closures of the freestanding-emit hole that ship together as one commit (no architectural blocker required to ship): (i) gate the six print-class intrinsics (`puts` / `eputs` / `print` / `eprint` / `print_int` / `eprint_int`) in `cg_intrinsic_io.qz` to emit no-op IR under freestanding — closes the `@.fmt.sn` / `@fprintf` / `@__stderrp` / `@stderr` reachability path through every stdlib diagnostic print (surfaced first by `std/net/hpack.qz`'s `eputs("[hpack] invalid index ...")` and `std/net/http_server.qz`'s h2-diag eputs). (ii) emit the four kind=3 continuation helpers (`@__qz_effect_get_cont_frame` / `@__qz_effect_set_cont_frame` / `@__qz_effect_get_resume_val` / `@__qz_effect_park_reset` / `@__qz_effect_park_get_rv` + `@__qz_effect_resume_cont` defensive stub) plus their two TLS-equivalent globals (`@__qz_effect_current_cont_frame`, `@__qz_effect_current_resume_val`) in the freestanding effect-runtime block — mirrors hosted shape at `codegen_runtime.qz:1431-1446` / `1529-1541`. Plus new helper `cg_state_is_freestanding(state)` in `codegen_util.qz` (mirrors `cg_is_freestanding(target)` for intrinsic emitters that have a `CodegenState` not a target string). 14 new regression specs added in `freestanding_spec.qz`. | ~0.5 qd | ✅ `5ea8fe79` |
| 8b.2.b — chunk B (Path B, partial) | User-chosen Path B (stdlib @cfg fork, recommended over Path A compiler-gate extension): closes ~5 LLC-bailout classes that surfaced when http_server.qz is imported into the freestanding kernel compile. (i) **@cfg-fork `http_dyn_gsup_new` / `http_dyn_gsup_spawn_one` / `http_dyn_gsup_stop`**: freestanding shape never reaches `async f()` or `await t` — runs `body` synchronously in the calling task. **0 `__Future_*$poll` wrappers in freestanding (was 2), IR shrinks ~840 lines.** Concurrency tradeoff: kernel `http_serve_supervised` blocks listener per-connection; concurrent-per-conn is future work (~2-3 qd via kernel-side `go_closure` primitive or compiler-level `async f()` lowering gate). (ii) **@cfg(not: os: "unknown") stub on `_h2_handle_connection`**: hosted body references `@__qz_sched` (36-i64 hosted scheduler array); h2-in-kernel is NET.5 future work. **IR shrinks ~7,500 lines (h2 transitive helpers dead-code-out).** (iii) **@cfg(not: os: "unknown") on `with_static` + 3 static-file-serving helpers**: hosted path uses `@qz_path_join` (helpers_2 hosted-only) + FileIo intrinsics; kernel has no filesystem. **IR shrinks ~7,500 more lines.** (iv) **@__qz_time_mono_ns runtime helper**: freestanding emit shims to `@uk_time_mono_ns` directly (kernel's RDTSC-derived ns-since-boot, already preserved as a top-level def). (v) **Pure-IR @atoll for `str_to_int`**: freestanding emit defines a minimal LLVM-IR body (whitespace/sign/digits). Load-bearing on Content-Length parsing. (vi) **Libc C-string extern declarations** (memcmp/strlen/strcmp/strstr/strncpy/strcpy) in the freestanding decl block + matching C implementations in `tools/baremetal/libc_stubs.c` (~60 LoC, trivial). | ~0.5 qd | ✅ `81597473` |
| 8b.2.b — chunk C (kernel-link unblock — LLC + link both green) | Closes the kernel-link path for `import * from std/net/http_server` end-to-end. **Sizing-revision empirical reality**: the handoff anticipated 14 helpers to lift (~2-3 qd of mechanical work); only **4** were actually reached. The remaining 10 helpers on the queue (`@qz_str_split_impl`, `@qz_vec_index_of`, `@qz_vec_remove`, `@str_starts_with`, `@str_ends_with`, `@str_trim`, `@str_replace`, `@qz_vec_new`, `@qz_vec_push`, `@qz_vec_contains`, `@qz_str_join`, `@qz_vec_reverse`) **are not currently called from any live freestanding code path**; filed forward to whenever they become reachable. Two changes: (i) **4 helpers_2 lifts** into the freestanding emit (verbatim copies; deps already available): `@qz_str_hash` (FNV-1a, pure IR), `@qz_str_eq` (length-aware string equality via @memcmp — replaces @strcmp for `Map<String, V>` bucket comparison), `@qz_wrap_cstr` (@strlen + @qz_alloc_str + @memcpy), `@qz_str_from_codepoint` (UTF-8 codepoint encoder via the above + @__qz_alloc/@__qz_dealloc). Clears LLC end-to-end. (ii) **`Quakefile.qz` `-function-sections` + `--gc-sections`** for `baremetal:build_elf` + `baremetal:qemu_http`. Per the existing comment on chunk B's `_h2_handle_connection` `@cfg(os: "unknown")` stub (`http_server.qz:3164-3168`): the drop-via-gc-sections behavior was the design intent but the build pipeline wasn't passing the flag. This commit enables it. With both flags, ld.lld traces reachability from `_start` and drops every function only reachable through the TLS subgraph (`_async_tls_*`, `_tls_accept_and_dispatch`, `_https_supervised_per_conn_loop`, `https_serve_supervised`, h2 modules) — ~13 OpenSSL externs (SSL_*, ERR_clear_error, plus POSIX `poll` via `io_suspend_timeout`) cleanly dead-code-out. Closure dispatch preserved (Quartz emits explicit address-take symbol refs that `--gc-sections` honors). Verification: quake guard PASS 2698 fns; `baremetal:qemu_http` (unmodified hello_x86.qz) green — `--gc-sections` doesn't regress; probe (concat + `import * from std/net/http_server`) full pipeline produces a 7.4M ELF identical in size to the unmodified kernel's. | ~0.5 qd | ✅ `71da7dd1` |
| 8b.3 | `hello_x86.qz` wiring: `import * from std/net/http_server` + `import * from std/log` + `soul_landing_handler(req: Request): Response` (allocates 32 KiB scratch, calls existing `http_build_soul_landing(buf)`, slices body past `\r\n\r\n` via `cstr_to_string` → `@qz_wrap_cstr`, returns `html_response(body)`) + `kernel_log_emit(op_name, argc, argv)` Log handler routing to UART (low-level argv-decode shape — the freestanding effect-perform bridge ABI, per `std/log.qz:24-27`) + `supervised_server_body()` wrapping the call in `with Log { emit: kernel_log_emit } do -> http_serve_supervised(http_server_config(5560), soul_landing_handler) end` + `go_fn(supervised_server_body)` in `main`. **Plus 7 freestanding gates** in `self-hosted/backend/cg_intrinsic_conc_sched.qz` (chunk C didn't reach these because the probe only called `http_server_config`, not `http_serve_supervised`): `task_self` → `call i64 @sched_current()` (was `load ptr @__qz_current_frame`), `sched_init` → no-op (kernel scheduler already running), `sched_set_max_tasks` → no-op (kernel NUM_TASKS fixed at boot), `sched_shutdown` → no-op (kernel scheduler runs forever), `mutex_new` → alloc 72-byte handle with `@__qz_alloc` skipping `@pthread_mutex_init`, `mutex_lock` → value-load from offset 64 skipping `@pthread_mutex_lock`, `mutex_unlock` → value-store at offset 64 skipping `@pthread_mutex_unlock` + `@__qz_waiter_notify_all`. Same 72-byte mutex layout preserved (value-at-offset-64) so consumers' GEPs work unchanged; single-threaded Get/Put semantics safe under sync-per-conn execution. Coexists with the legacy hand-rolled HTTP path on TCP_LISTEN_PORT (80). | ~0.5 qd | ✅ `f5cb9271` |
| 8b.4 | Dual-port curl parity smoke in `baremetal:qemu_http`. Boots kernel with dual hostfwd (8094→80, 8095→5560), curls both, verifies: legacy :80 → 200 OK + `Server: Quartz-unikernel` + `<!doctype html>` (unchanged); supervised :5560 → 200 OK + `Server: Quartz/1.0` (stdlib serializer emit, not the legacy literal) + `<!doctype html>` + contains "Soul of Quartz" (handler dispatched to `http_build_soul_landing` correctly); serial log contains `[8b.3] spawning supervised server on :5560` (spawn fired) + `[INFO] Listening on port` (the low-level Log handler's argv decode lands correctly, not just the operation tag). Differing `Server:` headers are intentional — parity verifies the supervised path dogfoods the stdlib serializer, NOT byte-identical wire output. Body parity beyond shape: `-H 'Host: joyofquartz.example.com'` on port 80 forces the legacy Soul branch, matches supervised body byte-for-byte modulo live-counter shifts (1,312 byte differences over 38,073 from g_tick_count / g_task_alive / etc. snapshots at different request times — same `http_build_soul_landing` builder, sampled at slightly different times). | ~0.3 qd | ✅ `10a38fb5` |
| 8b — total (CLOSED end-to-end) | | **~3-4 qd shipped** (revised down further from the 5-7 qd projection after chunk C's empirical reachability surprise). Phase 8b cumulative: 8b.1 + 8b.2 + 8b.2.b-A + 8b.2.b-B + 8b.2.b-C + 8b.3 + 8b.4 = **CLOSED**. The kernel now dogfoods `std/net/http_server.qz::http_serve_supervised` on port 5560 in production, alongside the legacy inline path on port 80 (kept alive for the parity smoke; Phase 8c deletes it). | |

### Phase 8c.0 — Stdlib Response multi-region body extension

~0.5 quartz-day.

`std/net/http_server.qz::Response` originally carried its body as a
single `String`. The kernel's legacy HTTP path serves CSS/JS/icon
assets directly from PMM-resident bytes via
`conn_set_resp_body_ptr(slot, ptr)` — zero copy. Migrating those
routes onto `http_serve_supervised` (Phase 8c.1) without first
extending `Response` would force one ~16 KB copy of the landing-page
assets per request through a Quartz String. So 8c.0 is the stdlib
prerequisite for 8c.1.

Shape: two additive fields on the struct,

```quartz
struct Response
  status: Int
  body: String
  content_type: String
  extra_header_keys: Vec<String>
  extra_header_vals: Vec<String>
  body_ptr: Int          # 0 = use body; nonzero = raw bytes
  body_len: Int          # bytes at body_ptr
end
```

When `body_ptr != 0` the writer emits headers via the existing String
send and the body via a second raw-bytes send — TCP coalesces or
splits at its own boundaries. New constructor `bytes_response(ct,
ptr, len): Response` builds a zero-copy body directly. New helper
`tcp_write_bytes(fd, ptr, len): Int` parallels `tcp_write_str` for
the freestanding-aware raw-bytes path (hosted loops `socket_send`;
freestanding routes through `async_tcp_write` so the kernel's tcp
push + tx-done channel machinery handles the blocking write).

The four writer paths are all updated symmetrically: the synchronous
`http_write_response` (hosted), the async `_async_http_write_response_timeout`
(supervised h1.1, both hosted and freestanding kernel), the async TLS
`_async_tls_write_response_timeout`, and the two h2 sites (which use
`h2_bytes_from_ptr` instead of `h2_string_to_bytes` when body_ptr is
set, so h2's DATA-frame framing emits the right body bytes). The
access-log Content-Length derive is also updated. `_http_handle_head`
zeros body_ptr/body_len when stripping the body — same semantics as
the existing "body strip drops Content-Length" behavior.

Per D7 absolutism: 16 existing `Response { ... }` literal sites in
`std/net/http_server.qz` + 2 in `tools/doc.qz` + 2 in
`spec/qspec/http_connection_handler_spec.qz` all get explicit
`body_ptr: 0, body_len: 0` (Quartz struct literal field-init is
positional-by-name, no field-default mechanism in surface syntax).

Spec coverage: `spec/qspec/response_constructors_spec.qz` gains 7
new tests for bytes_response — status / content_type / body_len
field shape, that the String body stays empty, that body_ptr matches
the input pointer identity, and that text_response/html_response
leave body_ptr at 0.

### Phase 8c.1 — Port 80 supervised migration

~1 quartz-day. **Substrate blocker CLOSED 2026-05-25** — root cause was
NOT in the supervised serving path; it was in the kernel's PMM bridge.

Wire the legacy `:80` route surface (12+ routes incl. `/`, host-aware
Soul branch, `/api/stats.json`, `/api/soul/*`, `/api/recent.json`,
`/health`, static assets w/ 304 conditional GET) through
`http_serve_supervised(http_server_config(80), kernel_router_handler)`.
The router builds a `Response` per route — assets via `bytes_response`
(zero-copy thanks to 8c.0), everything else via `text_response` /
`json_response` / `html_response` with a per-request scratch String.

**Substrate blocker — CLOSED 2026-05-25.** Original symptom: freestanding
`_http_supervised_per_conn_loop` survived the first connection then
`#GP`'d inside `slab_alloc` on the second. Original suspect list (per-
conn / dyn_gsup / scoped) was wrong. **Actual root cause**: the kernel's
PMM bump cursor `g_pmm_next` was being silently reset to 0 by Quartz
`__qz_module_init` AFTER several complex initializers had already
lazy-initialized it and handed out pages — so the next allocation
returned a physical page already given to another slab class. Two
classes' chunk freelists then aliased the same page; writes through
one class's chunks corrupted the other's freelist next-pointers.
`slab_alloc`'s eventual deref of a corrupted next-pointer was the
visible crash. The "2nd supervised request" trigger was coincidental
— the corruption existed from boot, but the single-curl smoke
finished too fast to surface it.

Fix shipped in three places:
- **`tools/baremetal/libc_stubs.c`** — moved `pmm_next_cursor` to a
  C-side `static long` + `pmm_alloc_page` to a strong C definition.
  Added a defensive page-magic guard in `slab_alloc` (catches future
  corruption + halts cleanly with diagnostic instead of #GP). Added
  UART `dbg_*` helpers for boot-time diagnostics that don't depend on
  Quartz-side runtime state.
- **`tools/baremetal/hello_x86.qz`** — removed `var g_pmm_next = 0`
  and the Quartz `def pmm_alloc_page` body. Replaced with `extern "C"`
  declarations of `pmm_alloc_page` + `get_pmm_next_value` (used by
  `pmm_used_bytes`). Made `pmm_init` call `pvh_probe_ram` so
  `--gc-sections` keeps the symbol live (the C-side lazy-init
  reference doesn't keep it visible across the language boundary).
- **`Quakefile.qz` `baremetal:qemu_http`** — extended dual-port
  parity smoke to issue TWO supervised curls per kernel boot + assert
  both return 200 OK with identical Soul-of-Quartz body. Single-curl
  smokes can't see this bug class; the dual-curl gate is the
  regression-prevention.

Slab boot smoke now passes `SLAB 15/15` (was `12/15` — the 3 prior
failures were the same root cause). Compiler-side observation filed as
a separate concern: Quartz `__qz_module_init` emits trivial-literal
stores AFTER function-calling initializers, which can silently undo a
lazy-init pattern. See the project-memory entry
[[feedback-qz-module-init-trivial-store-ordering]] for compiler-side
fix candidates.

The router code itself (~300 LoC exploration commit reverted during
the recon) is design-validated. Phase 8c.1 proper re-lands as a
mechanical replay against the now-fixed substrate.

Coexistence: 8b's `:5560` supervised path stayed alive for the smoke
window; 8c.2 collapsed it back to the canonical `:80`.

### Phase 8c.2 — Delete hand-rolled HTTP code ✅ SHIPPED 2026-05-25

Per D7 absolutism (pre-launch, zero users), deleted the hand-rolled
HTTP machinery in `hello_x86.qz`. Net diff: **+228 / -805 LoC** across
`tools/baremetal/hello_x86.qz` (-805) and `Quakefile.qz` (-99 / +99).
Single commit; no compiler-source touched (no `quake guard` required).

Functions deleted (every legacy raw-bytes path):
- `http_build_response` — 14-route dispatcher
- `http_request_matches` / `http_request_path_with_query_matches` /
  `http_request_query_n` / `http_request_host_starts_with` — raw-bytes
  request parsers
- `asset_lookup` / `asset_request_matches` — raw-bytes asset lookup
- `asset_if_none_match` — raw-bytes If-None-Match comparator
- `http_build_304` / `http_build_asset` — legacy response builders
- `tcp_arm_response` — orphaned arming helper (only the deleted
  ESTAB-data branch called it)

Slot/listening-entry collapse:
- `SLOT_USERLAND_MODE` constant + `conn_userland_mode` / `conn_set_userland_mode`
  helpers — gone; the 2-byte hole at offset 136-137 is documented and
  preserved to avoid shifting downstream slot offsets
- `KERN_LISTEN_ENTRY_USERLAND_MODE` field on listening entries — gone;
  bytes 24-31 of the 32-byte entry are now reserved
- `_kern_tcp_listen_internal(port, mode)` inlined into `kern_tcp_listen(port)`
  (the public extern-C symbol load-bearing for std/net/tcp's freestanding
  body)

Path flips:
- `supervised_server_body` now binds `TCP_LISTEN_PORT` (80) instead of
  5560 — the canonical HTTP port is once again the only port. Boot's
  legacy `_kern_tcp_listen_internal(TCP_LISTEN_PORT, 0)` registration
  deleted; supervised's `tcp_listen(80)` body is the only registrant.
- `kernel_router_handler` split into wrapper + `_kernel_router_dispatch`
  so the wrapper can call `recent_record(path, status)` after dispatch.
  Without this, `/api/recent.json` would silently stop populating —
  the legacy ESTAB-data branch was the previous recording site.

Behavior collapses (every userland-mode-gated branch becomes unconditional):
- `tcp_accept_syn`: always allocates accept-chan + pushes slot ptr
- `conn_process_frame` ESTAB-data branch: always pumps to payload-rx
  ring (no inline `http_build_response` fork)
- `tcp_try_push` FIN phase: no auto-FIN — userland owns close via
  explicit `tcp_close`
- `tcp_free_slot`: always closes payload-rx + tx-done channels

Quakefile `baremetal:qemu_http`: single-hostfwd (`tcp::8094-:80`),
single supervised path verified twice (multi-request PMM-cursor
regression gate preserved). Server header check: `Server: Quartz/1.0`
(was: legacy path checked `Server: Quartz-unikernel`, supervised checked
`Server: Quartz/1.0`).

Probe script `tmp/baremetal/probe_router_14_routes.sh`: hostfwd
`tcp::8096-:80` (was `:5560`). All 14 routes green:
`r1_root_default_host` 200/14738B + `r1b_root_joyofquartz_host` 200/38075B
+ JSON endpoints + demo endpoints + `r11_recent` 200/558B (recording
works) + `r13_asset_200` 200/749B with ETag + `r13b_asset_304` 304/0B +
`r14_404` 404/1539B.

### Phase 9 — Migration sign-off + SOUL.7 deploy unblock ✅ SHIPPED 2026-05-25

`docs/SOUL_OF_QUARTZ.md` D.11 row marked done. SOUL.7 deploy now
unblocked: the production unikernel binary served from `mattkelly.io`
is the same supervised-`http_serve_supervised`-on-port-80 shape that
end-to-end qemu acceptance proves green. The pre-D.11 deploy flow
(rsync trunk-current ELF, systemd restart) needs no changes.

**Total estimate**: 6 quartz-days (Phases 1–6, userland, ✅ shipped) +
~6 quartz-days (Phase 7, freestanding effect bridge, ✅ shipped; B.5e
filed forward) + ~4 quartz-days (Phases 8a/8b/8c.0/8c.1/8c.2,
✅ shipped) + 0.5 qd (Phase 9, ✅ shipped). Total project: ~16.5 qd
**all shipped**. D.11 capstone CLOSED 2026-05-25.

## Freestanding-bridge sub-epic

This is the bigger architectural work — what's needed for
`scope_with_deadline` / unified `select` / `Throws` / `Supervisor` /
`with`-blocks to actually RUN inside the freestanding unikernel.

### Current state of the freestanding runtime

`self-hosted/backend/codegen_runtime.qz:2729+` emits no-op stubs for the
effect-handler runtime on freestanding targets:

```llvm
define void @__qz_effect_handle_install(...) { ret void }
define void @__qz_effect_handle_uninstall(...) { ret void }
define i64 @__qz_effect_perform(...) { ret i64 0 }
define i64 @__qz_effect_suspend(...) { ret i64 1 }  ; POLL_READY sentinel
define i64 @__qz_effect_argv_load(...) { ret i64 0 }
define void @__qz_gen_stash(...) { ret void }
define i64 @__qz_gen_take_stashed(...) { ret i64 0 }
```

`setjmp` returns 0; `longjmp` is `unreachable`. So `with E {...}` blocks
compile but never install; `throw` would invoke `longjmp` → UB.

### What the bridge needs

The userland implementation in `cg_emit_effect_runtime` (hosted) uses:

1. **TLS arrays for the effect stack** — `__qz_effect_stack_top`,
   `__qz_effect_stack_names`, `__qz_effect_stack_handlers`,
   `__qz_effect_stack_op_filters`, `__qz_effect_stack_state_slots`,
   `__qz_effect_stack_bufs`, `__qz_effect_stack_results`
2. **`setjmp` / `longjmp`** for the `Throws` effect (kind=2 handlers)
3. **A scheduler with park/wake** so `__qz_effect_suspend` actually
   suspends and a registered waker resumes

The kernel has:
1. **K8 per-CPU pages** that can host per-task TLS via the `gs:` segment.
   Each Task struct already has slots for state/SAVED_RSP/etc.; growing
   it to include effect-stack arrays is the natural fit.
2. **No setjmp/longjmp in libc_stubs.c** — needs adding. x86_64 setjmp
   is ~20 lines of inline assembly saving rsp/rbp/r12-r15/return-addr;
   longjmp restores and rets. Already implemented in many freestanding
   stdlibs (newlib, picolibc); easy to port.
3. **K8 scheduler has park/wake via sched_wake_interrupts_sleep**
   (Phase 4e.8 active-wake). The interface is already there; needs
   wiring through the freestanding `@__qz_effect_suspend` and the
   userland-equivalent waker registration machinery.

### Bridge phase plan

See [`D11_FREESTANDING_EFFECT_BRIDGE.md`](D11_FREESTANDING_EFFECT_BRIDGE.md)
for the full B.0 design (shipped 2026-05-24). Phases B.1–B.6 cover
per-task effect stack, setjmp/longjmp in libc_stubs.c, real
`@__qz_effect_perform`, kernel park/wake via the existing K8.6 BLOCKED
state model, Selectable/Actor/Supervisor smokes in kernel context, and
TcpStream/TcpListener Scoped impls. Summary:

| Phase | Description | Sized |
|---|---|---|
| **B.0** | ✅ Design memo for the bridge ([`D11_FREESTANDING_EFFECT_BRIDGE.md`](D11_FREESTANDING_EFFECT_BRIDGE.md)) | 0.5 qd shipped |
| **B.1** | Per-task effect stack in `Task` struct + bump TASK_SIZE; freestanding `@__qz_effect_handle_install/uninstall` use it | ~1 qd |
| **B.2** | setjmp/longjmp in `libc_stubs.c` (x86_64 inline asm) + freestanding codegen branch declares them; verify throw + with-Throws unwind via a single-thread kernel smoke | ~1 qd |
| **B.3** | `@__qz_effect_suspend` wires into K8 task park; freestanding equivalent of `__qz_completion_notify` (the user-facing waker) routes to sched_wake | ~1.5 qd |
| **B.4** | `Selectable` impls (RecvSelectable / SendSelectable / DeadlineSelectable / ScopeCancelSelectable) verified end-to-end in a kernel smoke | ~1 qd |
| **B.5** | `Actor<T>` + `Supervisor` smoke in kernel context — spawn one Actor, send messages, observe handle/terminate; spawn Supervisor with one_for_one restart, kill child, verify restart | ~1 qd |
| **B.6** | ⚠️ MERGED INTO PHASE 8a (2026-05-24) — no kernel `tcp_close(fd)` to wrap; needs the full fd-emulation adapter. Scoped impls ship as 10 LoC inside Phase 8a. | — |

Total bridge: ~6 quartz-days SHIPPED (B.0–B.5 partial; B.5e Actor +
Supervisor filed forward, B.6 absorbed into Phase 8a). Validates the
bridge incrementally so we don't ship a 1500-line patch all at once.

### Why the bridge is separable from userland D.11

The userland migration (Phases 1–6) ships on existing hosted targets
where the runtime already exists. Userland consumers benefit immediately.
The bridge sub-epic is its own track that the unikernel needs to consume
the migrated `std/net/http_server`. Splitting prevents the kernel
work from blocking userland's progress — and gives the bridge its own
focused design pass.

## Decision tree (for the runtime — published to QUARTZ_REFERENCE.md)

```
Want to serve HTTP?
├── Want the simplest form, route-based DSL?
│   └── Use `http_serve(port) do |route| -> ... end`
├── Want a single handler function?
│   └── Use `http_serve_with(config, handler)`
└── Want full Actor control (lifecycle hooks, custom keepalive, …)?
    └── Use `http_serve_actors(config, conn_factory)`

TLS variants follow the same three-tier shape with `https_serve_*`.
```

## Open questions

1. **Should the listener supervisor restart-on-crash?** Cowboy says yes
   (ranch_listener_sup); the listener crashing is recoverable and a
   restart picks up the next connection. Decision: **yes**, with
   max_restarts default 10/60s — protects against permanent failures.

2. **Should the connection supervisor restart-on-crash?** Cowboy says no
   (default temporary children). A connection crash usually means the
   peer disconnected or sent a malformed request; restarting wouldn't
   help. Decision: **no by default**, but `ConnectionRestartStrategy`
   knob in config lets users opt in to "restart-on-handler-throw" if
   they want a specific resilience profile.

3. **Where does middleware chain composition live?** Two options:
   - (a) `ConnectionActor` decorator chain — each middleware wraps the
     inner actor's `handle_request`; type-safe but verbose.
   - (b) `Fn(Request, NextHandler): Response` — Caddy / Tower model;
     simpler signature, type-erased at the boundary.
   Decision: **(b)** for the high-level path, **(a)** for the
   actor-control path. Lets simple users compose middleware in the
   route DSL and complex users hand-roll actor chains.

4. **Graceful shutdown deadline.** When SIGTERM fires, root scope cancels.
   Connection actors see the cancel arm of their select and exit. But
   what about in-flight responses? Two options:
   - (a) Hard cancel — interrupt mid-response.
   - (b) Drain — give actors up to `shutdown_timeout_ms` to finish their
     current request before hard-cancelling.
   Decision: **(b)**. The cancellable() arm in each connection's select
   only fires after the per-request scope completes; the per-request
   scope's deadline is `min(request_timeout_ms, shutdown_remaining_ms)`.

5. **Per-request scope vs per-connection scope.** Should each request
   get its own child scope of the connection scope? **Yes** — deadlines
   per request need their own scope so a slow request doesn't leak
   deadline-pressure to subsequent requests on the same keepalive
   connection.

6. **Backwards compatibility for the old entry points.** Per D7 + project
   pre-launch absolutism, delete them once consumers migrate. Don't keep
   `http_serve_handler` as a compat shim past Phase 6.

7. **Migration of the unikernel's hand-rolled `tcp_*` machinery.** The
   freestanding-bridge sub-epic gives us `std/net/tcp.qz` working in the
   kernel. Should the kernel keep its hand-rolled virtio-net / TCP
   reassembly / connection table, or migrate to the userland stack? The
   userland stack ASSUMES kqueue/epoll/io_uring — none of which the
   unikernel has. Decision: **kernel keeps its hand-rolled TCP**, but
   `std/net/tcp.qz` grows a `@cfg` freestanding branch that exposes a
   POSIX-shaped surface (`tcp_listen` / `tcp_accept` / `async_tcp_read` /
   `async_tcp_write` / `tcp_close`) mapped onto the kernel's slot-based
   primitives (fd ≡ slot ptr). This is Phase 8a. The original "wraps
   the per-connection fd in a TcpStream Scoped wrapper" framing was
   based on a wrong premise: the kernel has no fd to wrap and no
   `tcp_close(fd)` to call. The full fd-emulation adapter is required
   before any Scoped impl can have meaning.

## Risks / dependencies

- **`Supervisor.start_child` semantics under the K8 scheduler.** The
  userland Supervisor (C.14) was tested against the userland M:N
  scheduler. Behavior under the K8 per-CPU rings is unverified. Bridge
  Phase B.5 includes a smoke test for this; if there's divergence,
  surface in the bridge work and fix.

- **TLS in freestanding.** OpenSSL isn't available freestanding. The
  unikernel already has `std/net/tls13/*` for the WireGuard handshake
  (NET.5 surface); whether that's enough for HTTPS server use is open.
  Decision: **Phase 4 (TLS) ships userland-only first; freestanding-TLS
  is its own follow-on after Phase 8.**

- **Migration churn for existing consumers.** Four `import std/net/http_server`
  sites in the tree (`tools/prod_server.qz`, `tools/h2_test_server.qz`,
  `tools/doc.qz`, `examples/qz-http/main.qz`, `examples/http_effects.qz`).
  Phase 3's shim approach means they all keep working through Phase 6;
  no flag-day.

- **Behavior parity for the four `_handle_connection_*` variants.**
  Existing entry points differ in subtle ways (sync vs async, keepalive
  vs single-shot, TLS vs plain). Phase 2's `http_serve_actors` must
  cover the union. Spec coverage in Phase 2 enumerates each variant's
  observable behavior; the migration is the spec showing identical
  outputs.

- **Wrap-stack interaction with `Scoped` impls.** The TcpListener Scoped
  impl + the listener scope's cancel both want to close the socket on
  exit. B.8 Phase 4b's wrap_stack discipline handles this for normal
  exit; throw-unwind goes through release_on_throw. Verify in Phase 2.

## Success criteria

- Phase 2 lands → `http_serve_actors(config, default_connection_actor(h))`
  serves N connections, handles M requests each, exits cleanly on SIGTERM
- Phase 3 lands → all existing http server specs green
- Phase 6 lands → all consumers migrated; old entry points deleted
- Phase 7 (bridge) lands → kernel smoke tests for setjmp/throw, suspend/wake,
  Selectable poll-loop, Actor/Supervisor all green
- Phase 8a lands → kernel `tcp_listen` / `tcp_accept` / `async_tcp_read` /
  `async_tcp_write` / `tcp_close` work in a smoke-only test that doesn't
  yet involve `http_serve_supervised`
- Phase 8b lands → unikernel boots, serves `/` via
  `http_serve_supervised(http_server_config(80), |req| -> build_soul_landing(req))`
- Phase 8c lands → ~700 LoC of hand-rolled HTTP routing in `hello_x86.qz`
  deleted; demo bodies swap to language-level concurrency primitives
- Phase 9 → docs updated; SOUL.7 deploy ready

## Pairing with other tracks

- **SOUL.5 scaling push** (32k → 1M task pool) is unblocked of D.11 — can
  proceed in parallel. The freestanding bridge (Phase 7) is what lets the
  5M-task demo use *real* `scope_cancel` for cancel-cascade (with active
  wake), so SOUL.5 v6+ benefits from Phase 7 landing.
- **SOUL.6 micro-demos** (shipped 2026-05-23) stay on kernel-level
  primitives until Phase 8 lands; demo bodies swap one-line at that point.
- **NET.5 TLS in unikernel** crosses paths with Phase 4 (TLS in userland)
  + the freestanding-TLS follow-on. Sequence: Phase 4 first (userland TLS
  through the new actor model), then NET.5 stylized for the kernel.

## Calibration notes

The Phase A-C designs that D.11 integrates were estimated at varying
costs; actual numbers are well-documented:
- B.8 Phase 1–7: 1–2 quartz-weeks estimate, actual ~3 quartz-days
  (B.8 row in SOUL_OF_QUARTZ.md). 5× faster than estimate.
- C.13 Phase 1–7: 3.6 quartz-days estimate, actual ~2 calendar days
  through May 10–11 (CSV C.13 row). On-estimate.
- C.14 epic: 2–3 quartz-week estimate, actual ~3 quartz-days from
  `efb5c568` (C.14.1) to `0c751a36` (C.14.7). 7× faster.
- D.10 Phase 1–6: 3–5 quartz-day estimate, actual ~1 calendar day on
  May 11. 3× faster.

Pattern: the Phase A-C estimates were padded vs project velocity. D.11's
2–3 quartz-week estimate may similarly compress, especially since the
userland portion (Phases 1–6) reuses mechanisms the integrating epics
just shipped. Realistic project: 1.5–2 quartz-weeks total for D.11
including the bridge.

## See also

- [`SCOPE_UNIFICATION.md`](SCOPE_UNIFICATION.md) — B.7 scope tree design
- [`SCOPED_RESOURCES.md`](SCOPED_RESOURCES.md) — B.8 `Scoped` trait + impl matrix
- [`SELECT_UNIFICATION.md`](SELECT_UNIFICATION.md) — C.13 unified select design
- [`ACTOR_MODEL.md`](ACTOR_MODEL.md) — C.14 Actor + Supervisor design
- [`SOUL_OF_QUARTZ.md`](../SOUL_OF_QUARTZ.md) — Soul demo roadmap; D.11 is the integration test
- [`KERN_8_SMP.md`](KERN_8_SMP.md) — kernel SMP scheduler that the bridge integrates against
