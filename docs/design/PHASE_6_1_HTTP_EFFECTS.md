# Phase 6.1 — HTTP server effect-first

> **Epic**: Operation Piezoelectric Effects · `[piezo]` · Phase 6 (user-tool dogfooding)
> **Sibling**: [`PHASE_6_2_QUAKE_EFFECTS.md`](PHASE_6_2_QUAKE_EFFECTS.md) (Quake migration; ships after this)
> **Status**: Design — implementation queued for next session.
> **Filed**: 2026-04-25, on closure of Phase 4D.
> **Estimate**: 3-5 quartz-days, 5 commits, multi-session.
> **Risk**: medium (concurrent-effect-frame isolation is the load-bearing unknown).

## Why this memo exists

Phase 5 dogfooded effects on **compiler internals** — serial-per-phase machinery (Diag, State<TcCtx>, Emit, FileIo, Intern). Exactly one effect frame at a time per compilation pass. Phase 6 dogfoods on **user-shaped tools**, where the shape is different: an HTTP server runs N concurrent request handlers, each in its own scheduler fiber, each potentially with its own `with`-installed effect frame.

This is the load-bearing test that compiler-internals didn't run. **If 1,000 concurrent requests can each install their own `with Log`-frame without cross-talk, we have proof that the kind=3 effect substrate Phase 3 built supports per-fiber isolation.** That capability is the prerequisite for any future user-facing concurrency story (request-scoped tracing, tenant-scoped DB connections, per-request feature flags).

The HTTP server is also where Quartz's effect system pays off most visibly to users. Every beloved feature in the most-loved HTTP frameworks across Rust / Go / JS / Ruby / Python / Elixir / OCaml / Scala / F# / Haskell **resolves into one of three effect primitives**:

- **Extractors** (axum's `Path<T>`, FastAPI's typed args, Rocket's request guards) → effect operations
- **Middleware** (tower layers, Phoenix Plug pipelines, Koa onion) → handler-installation stacks
- **DI containers** (FastAPI `Depends`, Elysia `.derive`, Rails' `before_action`) → lexical effect scope

> *"Every beloved feature in these frameworks is a workaround for the absence of effects."* — Phase 6 research synthesis, 2026-04-25.

Quartz already has effects. The HTTP server should ship the DSL where this is visible.

## Prior-art synthesis

A four-agent parallel survey (filed in this session — see `docs/research/PHASE_6_HTTP_FRAMEWORK_SURVEY.md` for raw findings) covered:

- **Rust/Zig**: axum, actix-web, rocket, warp, tower, hyper, zap, http.zig
- **Go/JS/TS**: net/http, gin, echo, fiber, chi, huma, Express, Fastify, Koa, Hono, Elysia
- **Ruby/Python/Elixir**: Sinatra, Roda, Hanami, Rails, Kemal, Lucky, FastAPI, Starlette, Litestar, Flask, aiohttp, Plug, Phoenix
- **Functional/effect-native**: Servant, http4s, Tapir, ZIO HTTP, Dream, Opium, Riot, Giraffe, Falco

Five load-bearing patterns emerged. Quartz's HTTP DSL steals from each.

### 1. Sinatra's verb-first 5-line shape (the aesthetic floor)

```ruby
get '/' do
  'Hello world'
end
```

Three load-bearing aesthetic choices: (a) the verb is the first word; (b) the path is a string literal next to it; (c) the body is a block returning the response. **Crystal/Kemal proves this survives static typing intact.** Quartz preserves this literally.

### 2. FastAPI's typed-extractor handler signature (the contract)

```python
@app.get("/items/{id}")
async def read_item(id: int, q: str | None = None, db: Session = Depends(get_db)):
    return {"id": id, "q": q}
```

The handler signature is the contract. `id: int` parses the URL segment; `q: str | None` declares an optional query param; `db: Session = Depends(get_db)` IS effect-handler-installation in Python's notation. **In Quartz, the same shape is `def show(id: Int): User can Db, Throws<NotFound>` — the row is the dependency list and the failure list, by construction.**

### 3. Roda's routing tree (the composition mechanism)

```ruby
route do |r|
  r.on "users" do
    r.get(":id") { |id| "User #{id}" }
    r.post { create_user(r.params) }
  end
end
```

Lexical scope IS the composition. Anything `with`-installed at a tree node applies to everything nested under it. **This is the cleanest mapping of "middleware stack" to "effect handler stack" in any framework surveyed.**

### 4. Phoenix's named pipelines (reusable handler stacks)

```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug :rate_limit
  plug :authenticate
end

scope "/api" do
  pipe_through :api
  get "/users/:id", UserController, :show
end
```

A pipeline is a named bundle of plugs (handler installs). `pipe_through :api` says "everything in this scope runs with these handlers installed." **Direct mapping: `pipeline api = with RateLimit, Authenticate, Json`. `scope "/api", api do ... end` opens a routing tree node where requests route through the pipeline's handlers.**

### 5. Koa's onion middleware (the request lifecycle)

```javascript
app.use(async (ctx, next) => {
  const start = Date.now();
  await next();              // descend into the rest of the stack
  console.log(Date.now() - start);  // run on the way back out
});
```

`await next()` is the resume point — code before runs on descent, code after runs on ascent. **This is shockingly close to algebraic-effect handlers**: `await next()` IS `resume(...)`. `with Tracing { trace: my_trace } do -> handler() end` — Quartz's effect-handler shape is the typed version.

### What effects make UNNECESSARY

- **Dependency-injection containers** (FastAPI `Depends`, Elysia `.derive`, Spring): subsumed by `can` rows.
- **Request-context bags** (`*gin.Context`, `req.locals`, `ctx.state`): subsumed by reader effects.
- **Error-wrapping middleware** (Express four-arg, Echo `HTTPErrorHandler`, Rocket catchers): subsumed by `Throws<HttpError>` in the row + `with Throws { Throw: respond_500 }` install.
- **Test-mocking infrastructure** (nock, sinon, gomock, supertest): subsumed by `with H { op: mock } do -> handler(req) end`. **This is the single biggest win.**
- **Tower `Layer`/`Service` trait pair**: exists ONLY because Rust lacks effects. With effects, layers ARE handler installs.

### What functional/effect-native frameworks teach (gold-standard prior art)

The Phase 6 research uncovered four load-bearing patterns from this lineage:

**Tapir (Scala) — describe once, derive everything**:

```scala
val countCharacters: ServerEndpoint[Any, Future] =
  endpoint
    .in(stringBody)
    .out(plainBody[Int])
    .errorOut(jsonBody[ApiError].and(statusCode(StatusCode.BadRequest)))
    .serverLogic(s => Future.successful(Right(s.length)))
```

The endpoint **description is a first-class value** typed by inputs/errors/outputs. The same value compiles to: server (Akka, http4s, Netty, ZIO HTTP), client (sttp), OpenAPI doc, AsyncAPI doc, JSON Schema, ReDoc/Swagger UI, ZIO HTTP endpoint, and Lambda handler. **One value, eight artifacts.**

**Mainstream frameworks have a 4-way drift problem**: route code, OpenAPI yaml, client SDK, integration tests — four documents that fall out of sync. Tapir collapses this to a 1-way derivation. Quartz can ship this AND do something Tapir can't: **carry the effect row inside the endpoint type itself**. `Endpoint<In, Out, Err, eff>` where `eff` is the literal row.

**http4s (Scala) — routes are values, middleware is `Routes -> Routes`**:

```scala
val helloService = HttpRoutes.of[IO] {
  case GET -> Root / "hello" / name => Ok(s"Hello, $name.")
}
val withLogging: HttpRoutes[IO] => HttpRoutes[IO] = ... // pure function
```

A handler is `Request[F] => F[Response[F]]` for any effect `F`. Middleware is **literal function composition**. Quartz's effect-native form: `Request -> Response can <effects>`. The `F` in http4s is what an effect row gives you natively, with no `Kleisli[OptionT, ...]` bookkeeping for the user.

**Dream (OCaml) — two-types-only minimalism + direct-style I/O via effects**:

```ocaml
let () =
  Dream.run @@ Dream.logger @@ Dream.router [
    Dream.get "/" (fun _ -> Dream.html "Good morning, world!");
    Dream.get "/hello/:name" (fun req ->
      Dream.html ("Hello, " ^ Dream.param req "name"));
  ]
```

Two data types: `request` and `response`. A handler is just a function. Middleware is `handler -> handler`. Possibly the cleanest API in the entire survey. **Direct-style I/O suspends invisibly via OCaml 5 effects** — no `await`, no `Lwt.bind`. Quartz already has this via async-as-effect; the syntax confirms the design direction.

**Effekt — second-class capabilities (the safety property nobody else has)**:

A `with DbConnection do handler(req) end` install creates a capability bound to its handler scope. The `DbConnection` capability **cannot escape** the scope — the type system refuses to let it leak. This solves the "leaked DB connection / unclosed file handle" class of bugs at the type level. Effekt is research-grade; no production framework has this. Quartz can.

**ZIO HTTP — per-request fiber with own effect environment**:

```scala
val routes = Routes(
  Method.GET / "hello" / string("name") -> handler { (name: String, _: Request) =>
    Response.text(s"Hello $name!")
  }
)
```

`Handler[R, Err, Request, Response]` — `R` is the environment row, `Err` is the typed error. Each request runs in its own ZIO fiber with its own environment. **`R` is ZIO's manual approximation of what an effect row gives Quartz for free.**

### The opportunity nobody has shipped

> **There is no production HTTP server in any algebraic-effects-native language as of April 2026.**

Koka has the substrate (row-polymorphic effects, evidence passing) but no server library. Effekt has the substrate + second-class capabilities but only research case studies. Eff is research-grade with no industrial users. **Whoever ships the first effects-native HTTP framework with Tapir-quality describe-once-derive-everything gets to define the genre.**

The Quartz combination — row-polymorphic effects + algebraic effects + row-polymorphic Stream — is **the first time these primitives have coexisted in a production-shaped language**. Quartz HTTP can be:

- Direct-style handlers, no `do`-comprehensions (Haskell can't; OCaml-multicore can but lacks rows).
- Endpoint effect rows in the description (Tapir can't; Servant can't).
- Per-request handler stack via `with` install, native (ZIO HTTP works hard to achieve this; Quartz gets it free).
- Row-polymorphic `Stream<T, e>` for WebSockets and SSE (no other framework has this).
- Middleware as effect handlers, not Kleisli arrows (no `>=>`, no `andThen`).
- Capability scoping for resource leaks (Effekt's idea, never shipped in production).

This is not "another HTTP framework." It's the first time these properties can be combined.

## The hypothesis

Three load-bearing claims to prove via Phase 6.1:

### H1 — Per-request effect-frame isolation works under concurrent load

Each request runs in a scheduler fiber. A `with Log { log: capture_for_this_request } do -> handler(req) end` install around a single handler MUST NOT leak into a sibling handler running on another worker. Today's `with` install pushes onto a process-wide effect-stack array (`__qz_effect_stack_*`); we need to verify the per-fiber view is isolated.

**Verification**: a 1,000-fiber spec with per-fiber Log captures shows zero cross-talk in captured output, regardless of scheduler timing.

### H2 — Middleware-as-effect-stack reads better than middleware-as-function-composition

Today: `with_logging(with_cors(with_static(handler)))` — function-wrap nesting.
After: `with Log, Cors, Static do -> handler(req) end` — handler-install stack.

The latter should be more readable, type-checked (each effect contributes a row entry), test-mockable (override one handler, leave the rest), and composable across libraries (a third-party middleware doesn't need to know what other effects you've installed — just declares its own).

**Verification**: Existing middleware files (`with_logging`, `with_cors`, `with_static`) net-negative LOC after migration. A subjective readability check (re-readable by the author after a week) passes.

### H3 — `State<ResponseBuilder>` models the response-builder pattern cleanly

Today's `req.context: Map<String, String>` is mutate-as-you-go, untyped. After migration, request-scoped state flows through `State<ResponseBuilder>` (or similar), typed and composable.

**Verification**: One existing handler (the `with_cors` middleware) migrates to use State; assertions confirm the State is per-request and doesn't leak.

## DSL design

### v1 (what Phase 6.1 ships)

The DSL stays close to today's surface but pivots routing onto an effect-driven block DSL.

**Hello world**:

```be
import * from std/net/http

def main()
  http_serve(8080) do
    get("/", -> empty_req -> text("Hello, World!"))
  end
end
```

Five lines (counting imports). Verb-first inside a `do` block. The `do` block is itself a function with `can HttpRoute` in its row; `http_serve` opens a `with HttpRoute { register: collect_into_router } do -> body end` install before running its main loop.

Concretely, `get` is a one-line effect performer:

```be
def get(pattern: String, handler: Fn(Request): Response): Void can HttpRoute
  perform HttpRoute.register("GET", pattern, handler)
end
```

`HttpRoute` is the effect:

```be
effect HttpRoute
  def register(method: String, pattern: String, handler: Fn(Request): Response): Void
end
```

`http_serve` installs it:

```be
def http_serve(port: Int, body: Fn(): Void can HttpRoute): Int
  var router = router_new()
  with HttpRoute { register: (m, p, h) -> router_add(router, m, p, h) } do ->
    body()
  end
  return http_serve_inner(port, router_handler(router))
end
```

**Multi-line handler with explicit Request**:

```be
http_serve(8080) do
  get("/users/:id") do (req: Request): Response
    var id_str = req.params.get("id") ?? return bad_request("missing id")
    var id = parse_int(id_str)
    var user = db_find(id) ?? return not_found()
    return json(user)
  end
end
```

This is Sinatra-shaped + Crystal-typed. The handler is `Fn(Request): Response`, callable directly in tests.

**Middleware via per-request `with` installs (per-request, not per-registration)**:

```be
def with_logging(inner: Fn(Request): Response): Fn(Request): Response
  return req -> with Log { log: stdout } do -> inner(req) end
end

http_serve(8080) do
  get("/", with_logging(-> req -> text("Hello")))
end
```

Verbose. This is the "v1 floor" — the same shape as today's `with_logging`, just using effects internally. **v2 will replace this with named pipelines** (see below).

**Test mocking — the killer demo**:

```be
def test_users_show()
  with Db { find: id -> Some(mock_user(id)) },
       Throws<NotFound> { Throw: e -> assert_fail("unexpected throw") } do ->
    var resp = users_show(test_request("/users/42"))
    assert_eq(resp.status, 200)
  end
end
```

No `TestClient`. No mocking library. No DI rewiring. Effects ARE dependency injection.

**Errors via `Throws<HttpError>`**:

```be
enum HttpError
  NotFound
  BadRequest { msg: String }
  Unauthorized
  Forbidden
  Internal { msg: String }
end

def users_show(req: Request): Response can Db, Throws<HttpError>
  var id = parse_path_int(req, "id")?    # throws BadRequest
  var user = db_find(id) ?? throw HttpError::NotFound
  return json(user)
end

# Framework's default Throws<HttpError> handler converts to status codes:
def default_http_error_handler(e: HttpError): Response
  match e
    NotFound => not_found()
    BadRequest { msg } => bad_request(msg)
    Unauthorized => unauthorized()
    Forbidden => forbidden()
    Internal { msg } => server_error(msg)
  end
end
```

The handler can throw; the framework's installed `Throws` handler converts to a typed Response. Handlers don't have to return `Result<Response, _>` — they `throw` directly and let the row + handler do the conversion.

### v2 (filed as Phase 6.1.f / followon — named pipelines)

Phoenix-derived. Reusable middleware stacks named once, applied via `pipe_through`:

```be
def main()
  http_serve(8080) do
    pipeline browser = with Log, Cors { origin: "*" }, Sessions
    pipeline api     = with Log, RateLimit { limit: 100 }, Json

    scope "/", browser do
      get("/", -> req -> text("Hello"))
    end

    scope "/api", api do
      get("/users/:id", users_show)
      post("/users", users_create)
    end
  end
end
```

`pipeline` is a value-typed bundle of effect handlers. `scope path, pipeline do ... end` opens a routing tree node where each registered route runs INSIDE the pipeline's `with` stack at request time. **This is the load-bearing payoff vs Phoenix: the pipeline's effects are visible in each handler's `can` row at compile time, not runtime.**

### v3 (filed as Phase 6.1.g / further followon — typed extractors)

FastAPI-style macro that derives Request extraction from handler signature:

```be
get("/users/:id") do (id: Int, q: String?): User can Db
  var user = db_find(id)?
  return user                  # framework auto-serializes to json
end
```

The macro:
- Parses path-pattern parameters from the path string (`:id`)
- Maps block-param types to extraction strategy (`Int` parses URL segment; `String?` reads optional query)
- Wraps the block as `Fn(Request): Response`

This is a polish layer that runs ON TOP of v1 / v2. Lucky-style compile-time route validation (typo `:id` in path vs `:idd` in handler → compile error) lives here.

### WebSocket via row-polymorphic Stream (the Phase 4D payoff)

WebSockets are streams of messages. Phase 4D shipped row-polymorphic Stream<T, e>. Therefore:

```be
effect Ws
  def send(msg: String): Void
  def recv(): String
end

def chat_handler(req: Request): Stream<String, {Async, Ws}> can Http, Async
  ws_upgrade(req)
  loop
    var msg = ws_recv()
    if msg == ""
      break
    end
    ws_send("echo: " + msg)
    yield msg                  # yields each received message into the stream
  end
end

http_serve(8080) do
  ws("/chat", chat_handler)    # registers a WebSocket-upgrade route
end
```

`for await msg in chat_handler(req) ... end` iterates received messages. **This reuses the Phase 4D row-poly Stream infrastructure with zero new compiler work.** The `Ws` effect's `send` / `recv` ops dispatch to a per-connection handler installed by `ws_upgrade()`.

Phoenix Channels are the prior art: `handle_in(event, payload, state) -> state` is exactly a state-effect handler. Quartz's version is more general because the Stream type carries the row.

## Effect surface — Phase 6.1 ships

```be
# 6.1.a — request lifecycle effects
effect Log
  def log(msg: String): Void
end

effect Throws<HttpError>
  def Throw(e: HttpError): Void
end

# 6.1.b — routing
effect HttpRoute
  def register(method: String, pattern: String, handler: Fn(Request): Response): Void
end

# 6.1.d — response-builder state (filed; explicit if not shipped)
effect ResponseBuilder
  def set_header(key: String, val: String): Void
  def set_status(code: Int): Void
  def append_body(chunk: String): Void
end

# 6.1.e — WebSocket (deferred to 6.1.f or as a separate phase if it bloats)
effect Ws
  def send(msg: String): Void
  def recv(): String
end
```

Each comes with a default handler installed at server-startup scope. Custom handlers shadow per-scope.

## Phase plan

Five subphases. Each ships independently with passing tests + `quake guard` fixpoint-byte-identical.

| # | Subphase | Goal | LOC | Risk |
|---|----------|------|-----|------|
| **6.1.a** | `Log` effect throughout | Replace 14 hardcoded `puts()` sites with `log()` calls; install default `with Log` at server startup. Per-request scope so test handlers can capture. | ~150 | low |
| **6.1.b** | `Throws<HttpError>` for bind/listen/TLS init + handler errors | Replace exit-on-puts patterns at bind/listen/TLS init with typed `throw`. Add HttpError enum + default handler. Migrate handler-side errors. Caller can catch and retry. | ~250 | low |
| **6.1.c** | **Per-request effect frames (concurrency test)** | Wrap the handler invocation site (~http_server.qz line 1557 in the kqueue dispatch) with a fresh effect frame per fiber. Spec: spawn 1000 concurrent requests, each with a different `with Log` install, assert no cross-talk. **THIS IS THE LOAD-BEARING TEST.** | ~100 + spec | **medium** |
| **6.1.d** | `HttpRoute` effect + block DSL | Introduce `HttpRoute` effect; `http_serve(port) do ... end` opens the `with HttpRoute` install; user-facing `get`/`post`/`put`/`delete`/`patch` perform `HttpRoute.register`. Migrate one example app. The existing `router_new()`/`router_get()` API remains as a lower-level building block. | ~180 | low-med |
| **6.1.e** | Middleware-as-effect-stack docs + idiom | Migrate `with_logging`, `with_cors`, `with_static` to use `with` installs internally. Write `examples/http_effects.qz` showing the canonical hello-world. Update `docs/EFFECTS.md` with the HTTP-shape section. | ~150 (mostly migration) | low |

### Filed for follow-on phases (NOT in 6.1 scope)

- **6.1.f** — Named pipelines (`pipeline api = with RateLimit, Authenticate`; `scope "/api", api do ... end`). ~200 LOC + spec. (Phoenix-derived.)
- **6.1.g** — Typed-extractor macro (`get("/users/:id") do (id: Int): User can Db`). Macro work + Lucky-style compile-time route validation. ~300 LOC, multi-session. (FastAPI/axum/Rocket-derived.)
- **6.1.h** — WebSocket-as-Stream (`Stream<WsMessage, {Ws, Async}>`). ~250 LOC + spec; Phase 4D payoff demo. (Phoenix Channels-derived, but rows-typed.)
- **6.1.i** — `State<ResponseBuilder>` for cookie/header/status mutation in handlers. ~150 LOC.
- **6.1.j** — **First-class `Endpoint<In, Out, Err, eff>`** describe-once-derive-everything (Tapir-style). Server, client, OpenAPI doc, mock all derive from one value. **The genre-defining feature.** Multi-session research-grade work; ~500 LOC + macro support. **This is the load-bearing v3 followon — the feature nobody has shipped in any effects-native language.**
- **6.1.k** — Effekt-style **second-class capabilities** for request-scoped resources (DB connections, file handles) that cannot leak past their handler scope. Type-system change; multi-session; resolves a class of resource-leak bugs at the type level. Filed for Phase 7 or later.

## Success criteria

Concrete, falsifiable. Each must pass before declaring 6.1 shipped:

- [ ] **Concurrent isolation (H1)**: a 1,000-fiber spec with per-fiber Log captures shows zero cross-talk. ([`spec/qspec/phase_6_1c_concurrent_effect_frames_spec.qz`](../../spec/qspec/phase_6_1c_concurrent_effect_frames_spec.qz))
- [ ] **Mock-ability**: an existing handler test rewritten with `with Db { find: -> mock } do -> handler(req) end` asserts on output without mocking globals.
- [ ] **DSL hello-world** ≤ 5 lines (counting imports).
- [ ] **Wrap-deletion perf neutral**: same Phase-5 measurement (< 0.1% wall delta) on a synthetic 10K-request benchmark. Established baseline pre-6.1.a; final measurement at 6.1.e close.
- [ ] **LOC reduction**: middleware files net negative (the `Fn(Req): Resp -> Fn(Req): Resp` boilerplate goes; effect installs replace it). Aggregate ~80 LOC removed across `with_logging`/`with_cors`/`with_static`.
- [ ] **No regressions**: existing http_server specs (find under `spec/qspec/http_*`), iterator_protocol, and the broader qspec sweep all stay green.
- [ ] **Fixpoint byte-identical** at every commit.

## Risks & mitigations

### R1 — Per-request effect frame allocation cost (load-bearing perf)

Today, an HTTP request runs in a fiber with stack-managed locals. Adding a `with Log` install around each handler invocation adds an evidence-slot push/pop. **Need to measure on a `bench_http` baseline before declaring perf-neutral.**

**Mitigation**: ship 6.1.a first with NO per-request frame change (just replace `puts()` with `log()`). Measure baseline. THEN ship 6.1.c (per-request frames) and re-measure. If the delta exceeds 5% of P99 latency, investigate evidence-slot pooling (preallocate a pool of effect-stack slots per worker; reuse instead of grow).

### R2 — TLS handshake error reporting via Throws

The TLS error paths today do `puts() + return -1`. Migrating to Throws means the caller handles the exception — fine, but the caller is currently inside an FFI-heavy state machine (lines 1783-1842). The unwind path must interact cleanly with the OpenSSL state machine.

**Mitigation**: 6.1.b ships TLS error migration as its own commit, separate from bind/listen migration. Spec asserts that catching a TLS error produces no resource leaks (sock_close, SSL_free called on the unwind path).

### R3 — Middleware ordering equivalence

Effect installs are nested-stack ordered (inner overrides outer). Current middleware composition is also nested but via function wrapping. Need to check the orderings actually compose the same way; might surface a subtle bug in either direction.

**Mitigation**: 6.1.e ships a compatibility spec that runs `with Log do -> with Cors do -> handler() end end` and asserts the captured output matches `with_logging(with_cors(handler))(req)`. Any divergence is investigated.

### R4 — `do` block typecheck inference + `can HttpRoute` row

`http_serve(port) do ... end` — the `do` block must be typechecked as `Fn(): Void can HttpRoute`. Today's lambda inference may or may not handle this cleanly (the body block contains effect performs but the block param has no annotation). Need to verify against Phase 4 + Phase 5 patterns.

**Mitigation**: 6.1.d ships a minimal smoke spec that verifies the block-DSL compiles. If inference fails, fall back to explicit `Fn(): Void can HttpRoute` annotation in the user-facing example (uglier but works); file the inference improvement as a Phase 6 followup.

### R5 — Interaction with pre-existing scheduler bugs

Memory flags `GO_SCHED_BLOCKING_MUTEX_HANG` (sync `mutex_lock` with M:N scheduler hangs under 3+ contending tasks) and `PIEZO_KIND3_CONCURRENT_PIPE_FLAKE` (~15% flake rate on async_io_spec concurrent-pipe tests). The 1,000-fiber concurrency spec for 6.1.c will exercise the scheduler hard.

**Mitigation**: 6.1.c spec uses `async_mutex_lock` (not `sync_mutex_lock`) and avoids raw pipes (uses channels with notify-fds). If flakes surface that ARE NOT pre-existing, they're filed as bugs for the scheduler track, not 6.1 regressions.

### R6 — Stack-cap regression

Phase 5.4 hit the 32-stack-cap bug; cap was raised to 256 in `a6f174ae`. Phase 6.1's per-request effect frames + middleware stacks could nest deep under load. Need to verify 256 is still comfortable.

**Mitigation**: 6.1.c spec includes a stack-depth measurement asserting that under the 1,000-fiber workload, the max effect-stack-depth observed stays below 100 (50% safety margin). If exceeded, raise cap (or migrate to the always-increment-top + bounds-checked-reads design filed as followup in `feedback_effect_stack_asymmetry.md`).

## Non-goals (deferred)

- **Auto-OpenAPI generation** (FastAPI / Tapir / Huma feature). Filed; depends on type-driven extractor macro (6.1.g).
- **HTTP/3 / WebTransport**. Tier 5; unrelated to effect migration.
- **Streaming response bodies** (Server-Sent Events, chunked transfer). Filed; achievable via row-poly Stream after 6.1.h ships.
- **Hot reload / dev server**. Out of scope; not effect-related.
- **Multipart/form-data parsing**. Filed; orthogonal to effect surface.
- **Compile-time route validation** (Lucky-style). Filed as 6.1.g.
- **Phoenix Channels equivalent (named pub/sub topics)**. Filed; achievable via `Stream<Msg, {Ws, PubSub}>` after 6.1.h.

## Sequencing into the broader epic

The Piezo epic state post-6.1:

| Phase | Status | Notes |
|---|---|---|
| 1 — surface syntax + typecheck rows | ✅ SHIPPED 2026-04-18 → 19 | |
| 2 — State / Reader | ✅ SHIPPED 2026-04-22 | |
| 3 — Async-as-effect | ✅ SHIPPED 2026-04-20 → 22 | |
| 4 — Generators (Path B) + 4D row-poly Stream | ✅ SHIPPED 2026-04-23 → 25 | |
| 5 — Compiler dogfooding | ✅ SHIPPED 2026-04-22 → 23 | LOC audit + Intern customization queued for next session |
| **6.1** — **HTTP server** | **next session (this memo)** | 3-5 quartz-days, 5 commits, multi-session |
| 6.2 — Quake | queued | 1-2 quartz-days, 3 commits |
| 6.3 — REPL | deferred | revisit only on concrete trigger (web playground / REPL test harness) |
| 4b — Multi-shot / Ndet | deferred indefinitely | concrete-user-need trigger |
| 4D.5d — Stream.next inlining | deferred | concrete-user-need trigger |

## Handoff

If the session splits mid-phase, resume from the subphase list (6.1.a → 6.1.e). Each subphase ships independently with a passing spec and `quake guard` fixpoint-byte-identical.

**Start of next session**: Phase 5 cleanup (LOC audit + Intern customization, ~1 quartz-day) THEN 6.1.a. Or skip the cleanup and go straight to 6.1.a — the cleanup is sequencing-correct but not blocking.

**End of next session (target)**: 6.1.a + 6.1.b shipped, fixpoint byte-identical, basic Log + HttpError migration green. Hands off to a third session for 6.1.c (the load-bearing concurrency test), 6.1.d (block DSL), 6.1.e (middleware migration + docs).

## References

- [`PHASE_6_2_QUAKE_EFFECTS.md`](PHASE_6_2_QUAKE_EFFECTS.md) — sibling Phase 6 memo for Quake migration; same default-handler-at-entry pattern.
- [`EFFECT_MIGRATION_PLAYBOOK.md`](EFFECT_MIGRATION_PLAYBOOK.md) — Phase 5 playbook, three-pass bootstrap discipline applies here.
- [`PHASE_4D_ROW_POLY_STREAM.md`](PHASE_4D_ROW_POLY_STREAM.md) — Stream<T, e> infrastructure; substrate for WebSocket-as-Stream (6.1.h).
- [`P3_F_ROW_POLYMORPHISM.md`](P3_F_ROW_POLYMORPHISM.md) — function-level row polymorphism; the substrate for `def handler(): Response can Db, Throws<HttpError>`.
- `docs/research/PHASE_6_HTTP_FRAMEWORK_SURVEY.md` — raw findings from the four-agent parallel survey (filed alongside this memo).
- `docs/handoff/piezo-phase-6-kickoff.md` — next-session handoff brief (kickoff for Phase 5 cleanup + Phase 6.1.a).

External:
- Sinatra: <https://sinatrarb.com/>
- FastAPI Dependencies: <https://fastapi.tiangolo.com/tutorial/dependencies/>
- Phoenix Routing & Channels: <https://hexdocs.pm/phoenix/routing.html>
- axum extractors: <https://docs.rs/axum/latest/axum/extract/>
- Hono type-accumulating routing: <https://hono.dev/>
- Roda routing tree: <https://roda.jeremyevans.net/>
- Xie & Leijen, *Generalized Evidence Passing for Effect Handlers* (ICFP 2021) — the substrate Quartz's effect runtime is built on.
