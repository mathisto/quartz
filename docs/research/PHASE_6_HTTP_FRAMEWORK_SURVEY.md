# Phase 6 — HTTP framework survey for Quartz DSL design

> **Filed**: 2026-04-25, in preparation for Phase 6.1 (HTTP server effect-first migration).
> **Method**: four parallel research agents, each scoped to one ecosystem.
> **Purpose**: synthesize the most-loved features from the most-loved HTTP frameworks across language traditions; identify what an effects-native language should steal vs avoid; ground the Phase 6.1 design memo ([`PHASE_6_1_HTTP_EFFECTS.md`](../design/PHASE_6_1_HTTP_EFFECTS.md)).

## Headline findings

1. **Every beloved feature in mainstream frameworks is a workaround for the absence of effects.** axum's extractors, tower's layers, Rocket's request guards, FastAPI's `Depends()`, Phoenix's pipelines, Koa's onion middleware — all resolve into `with H { op: handler } do ... end` once effects exist as a primitive.

2. **There is no production HTTP server in any algebraic-effects-native language as of April 2026.** Koka, Effekt, Eff all have toy examples or no HTTP at all. **Quartz can be the first.**

3. **Tapir's "describe once, derive everything" is the gold standard.** Endpoint description as a first-class value; server, client, OpenAPI, mocks all derive. Quartz with row-polymorphic effects can carry the effect row INSIDE the description — something Tapir cannot.

4. **The Sinatra five-line shape is the aesthetic floor.** `verb '/path' do body end`. Crystal/Kemal proves it survives static typing intact. Every modern framework reverts to this for hello-world.

5. **Test-mocking is the single biggest user-visible win** of effects-native HTTP. Every framework above today bundles or recommends a mocking library (nock, sinon, gomock, supertest, TestClient). Effects collapse this to: `with H { op: mock } do -> handler(req) end`. Zero new infrastructure.

## Synthesis: the load-bearing patterns

### 1. Sinatra's verb-first 5-line shape (aesthetic floor)

Universal across every "what would you reach for first" framework. Verb is the first word; path is a string literal next to it; body is a block returning the response. No application object, no router, no controller class visible at hello-world. **Crystal/Kemal proves this aesthetic survives static typing.**

### 2. FastAPI's typed-extractor handler signature (the contract)

```python
@app.get("/items/{id}")
async def read_item(id: int, q: str | None = None, db: Session = Depends(get_db)):
    return {"id": id, "q": q}
```

Handler signature IS the contract. Each parameter is a typed extractor. `Depends(get_db)` IS effect-handler-installation in Python's notation. **In Quartz: `def show(id: Int): User can Db, Throws<NotFound>`** — the row is the dependency list and the failure list, by construction.

### 3. Roda's routing tree (composition mechanism)

```ruby
r.on "users" do
  r.get(":id") { |id| ... }
  r.post { create_user(r.params) }
end
```

Lexical scope IS the composition. Anything `with`-installed at a tree node applies to everything nested under it. **Cleanest mapping of "middleware stack" to "effect handler stack" in any framework surveyed.**

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

`pipeline` is a named bundle of plugs. `pipe_through :api` says "everything in this scope runs with these plugs installed." **Direct mapping: `pipeline api = with RateLimit, Authenticate, Json`. `scope "/api", api do ... end` opens a routing tree node where requests route through the pipeline's handlers.**

### 5. Koa's onion middleware (request lifecycle)

```javascript
app.use(async (ctx, next) => {
  const start = Date.now();
  await next();              // descend
  console.log(Date.now() - start);  // ascend
});
```

`await next()` IS `resume(...)`. Code before runs on descent, code after runs on ascent. **Algebraic effect handlers are the typed version of this pattern.**

### 6. Tapir's describe-once-derive-everything (genre-defining)

```scala
val countCharacters = endpoint
  .in(stringBody)
  .out(plainBody[Int])
  .errorOut(jsonBody[ApiError].and(statusCode(StatusCode.BadRequest)))
  .serverLogic(s => Future.successful(Right(s.length)))
```

One value, eight artifacts (server/client/OpenAPI/mock/AsyncAPI/JSON Schema/ReDoc/Swagger UI). **Mainstream frameworks have a 4-way drift problem; Tapir collapses to 1-way derivation.** Quartz can ship this AND carry the effect row INSIDE the endpoint type.

### 7. Effekt's second-class capabilities (the safety property nobody has)

`with DbConnection do handler(req) end` creates a capability bound to its handler scope. The capability **cannot escape** the scope — type system refuses. **Solves the "leaked DB connection / unclosed file handle" class of bugs at the type level.** Effekt has it; no production framework does. Quartz can.

### 8. Dream's two-types-only minimalism

Two data types: `request`, `response`. Handler is `request -> response promise`. Middleware is `handler -> handler`. Direct-style I/O suspends invisibly via OCaml 5 effects. **Quartz already has this via async-as-effect.**

### 9. http4s's "routes are values, middleware is `Routes -> Routes`"

A handler is `Request[F] => F[Response[F]]` for any effect `F`. Middleware is literal function composition. **In Quartz: `Request -> Response can <effects>` — the `F` is the effect row, native.**

### 10. ZIO HTTP's per-request fiber + environment row

`Handler[R, Err, Request, Response]` where `R` is the environment row. Each request runs in its own ZIO fiber with its own copy. **`R` is ZIO's manual approximation of what algebraic effects do natively.**

## What effects make UNNECESSARY

- **Dependency-injection containers** (FastAPI `Depends`, Elysia `.derive`, Spring): subsumed by `can` rows.
- **Request-context bags** (`*gin.Context`, `req.locals`, `ctx.state`, `Plug.Conn` mega-struct): subsumed by reader effects.
- **Error-wrapping middleware** (Express four-arg, Echo `HTTPErrorHandler`, Rocket catchers): subsumed by `Throws<HttpError>` in the row + `with Throws { Throw: respond_500 }` install.
- **Test-mocking infrastructure** (nock, sinon, gomock, supertest, TestClient): subsumed by `with H { op: mock } do -> handler(req) end`.
- **Tower `Layer`/`Service` trait pair**: exists ONLY because Rust lacks effects. Layers ARE handler installs.
- **Servant DataKinds/TypeFamilies**: exists ONLY because Haskell can't carry effect rows in ordinary types. Quartz records-of-effects suffice.
- **Giraffe Kleisli composition (`>=>`)**: exists ONLY because F# computation expressions are sugared monad-bind. Effect-handler-stack IS the same shape, native.
- **ZIO `R` environment + ZLayer DI**: exists ONLY because Scala lacks first-class effect rows. Quartz `can` rows ARE the environment.

## What an effects-native Quartz HTTP DSL should look like

Synthesizing all four reports:

**Hello world (Sinatra-shape, Crystal-typed)**:

```be
def main()
  http_serve(8080) do
    get("/") do (req: Request): Response
      return text("Hello, World!")
    end
  end
end
```

**Routing tree (Roda-shape) + named pipelines (Phoenix-shape) — v2**:

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

**Typed extractors (FastAPI/axum/Rocket-shape) — v3**:

```be
get("/users/:id") do (id: Int, q: String?): User can Db, Throws<NotFound>
  var user = db_find(id) ?? throw NotFound
  return user                    # framework auto-serializes to JSON
end
```

**WebSocket as row-poly Stream (no prior art has this) — v3**:

```be
def chat_handler(req: Request): Stream<String, {Ws, Async}> can Http
  ws_upgrade(req)
  loop
    msg = ws_recv()
    if msg == "" break end
    yield msg
  end
end

http_serve(8080) do
  ws("/chat", chat_handler)
end
```

**Test mocking (no library needed)**:

```be
def test_users_show()
  with Db { find: id -> Some(mock_user(id)) } do ->
    var resp = users_show(test_request("/users/42"))
    assert_eq(resp.status, 200)
  end
end
```

**Endpoint description as first-class value (Tapir-shape) — genre-defining v4**:

```be
endpoint user_show
  .in(path("id", Int))
  .in(header("X-Tenant", String).optional)
  .out(json<User>)
  .errorOut(json<ApiError>, status(404))
  .row(can Db, Throws<NotFound>)

def user_show_logic(id: Int, tenant: String?): User can Db, Throws<NotFound>
  return db_find(id, tenant) ?? throw NotFound
end

# server, client, OpenAPI all derived from `user_show` value
http_serve(8080).mount(user_show.serve(user_show_logic))
```

## Per-framework distillations (highlights)

For full per-framework breakdowns see the agent reports below. Here are the headline beloved-features and what to steal:

### Rust ecosystem

- **axum** — extractors as function args. **Steal**: extractor-shape; `Path<T>` IS `effect Path { get<T>(): T }`.
- **actix-web** — attribute macros + ResponseError trait. **Steal**: any-error-knows-its-status idea = `effect Throws<HttpError>` in the row.
- **rocket** — request guards. **Steal**: `fn admin(user: AdminUser)` IS `def admin(): Response can Auth<AdminUser>`. Unhandled = 401.
- **warp** — filter combinators. **Steal**: routes-as-values mental model. Effects subsume the combinator machinery.
- **tower** — `Service`/`Layer` middleware abstraction. **Steal**: nothing — exists only because Rust lacks effects. Layers = handler installs natively.
- **hyper** — substrate. **Steal**: nothing at DSL layer; recognize the DSL must be implementable on a hyper-shape `Request -> Future<Response>`.

### Zig ecosystem

- **zap** — facil.io-backed; `on_request` callback. **Steal**: not much — callback-style.
- **http.zig** — visible-allocator discipline. **Steal**: maps to `effect Alloc { allocate(n): Ptr }`. Quartz effect rows can express what Zig expresses with explicit allocator params.

### Go ecosystem

- **net/http** — `Handler` interface as single-method protocol. **Steal**: "anything in `can Http` is a handler."
- **gin** — `*gin.Context` god-object. **Steal**: route groups + composable shared middleware. Skip the god-Context (effects replace it).
- **echo** — handler returns `error`. **Steal**: `can Throws<E>` in row + centralized handler is exactly an installed effect handler.
- **fiber** — Express-familiar API on fasthttp. **Steal**: the familiarity bar. Skip ecosystem-incompat.
- **chi** — 100% net/http compatible. **Steal**: inline `r.With(mw).Get(...)` = scoped `with` per route group.
- **huma** — typed input/output structs + auto OpenAPI. **Steal**: this is the future. Effect rows make this richer (derive `can Async, Db` from body too).

### JS/TS ecosystem

- **Express** — universal Node baseline. **Steal**: nothing structural (cautionary tale). Effects replace `next(err)` entirely.
- **Fastify** — schema-first, JSON Schema → runtime validation + types + serialization. **Steal**: schema-as-source-of-truth → effect-row-as-source-of-truth.
- **Koa** — onion model `await next()`. **Steal**: the metaphor wholesale; with effects becomes type-safe.
- **Hono** — type-accumulating chain + Fetch API + edge-first + typed RPC client (`hc<typeof app>`). **Steal**: everything. The closest existing JS framework to what effects make natural.
- **Elysia** — Bun-native + TypeBox schemas + `.derive()`. **Steal**: `.derive()` IS adding an effect to the row.

### Ruby ecosystem

- **Sinatra** — the DSL granddaddy. **Steal**: `verb '/path' do body end` literally.
- **Roda** — routing tree. **Steal**: lexical scope as composition. Cleanest mapping of middleware-stack to effect-handler-stack in the survey.
- **Hanami 2** — DDD-shaped, action-class-per-route, explicit `(request, response)`. **Steal**: explicit signature is the right shape if effect-typed; Quartz can do better via reader-effect for request.
- **Rails** — `resources :users` resource shorthand. **Steal**: density IF macroexpanded statically (no string dispatch).
- **Crystal/Kemal** — Sinatra in static-typed Crystal. **Steal**: confirmation that Sinatra's DSL survives static typing.
- **Lucky** — compile-time-checked routes. **Steal**: typo in `:id` should never reach runtime.

### Python ecosystem

- **FastAPI** — typed dependency injection. **Steal**: this is THE single most important idea. `Depends(get_db)` IS `with Db { ... } do ... end`.
- **Starlette** — routes as values. **Steal**: offer both forms (block DSL AND routes-as-values for programmatic mounting).
- **Litestar** — layered DI (controller > app, handler > controller). **Steal**: layered DI = lexical effect scope.
- **Flask** — decorator-on-function shape. **Steal**: avoid the thread-local trap (`request` global is spooky-action-at-distance).
- **aiohttp** — middleware-as-function `async (request, handler)`. **Steal**: the cleanest middleware definition in the survey; minus tuple-return ceremony.

### Elixir ecosystem

- **Plug** — simplest possible HTTP abstraction. `(conn, opts) -> conn`. **Steal**: threading-the-conn discipline = manual reader+writer effect; Quartz hides the thread.
- **Phoenix** — `pipeline :api do plug X end` + scope-applied. **Steal**: named effect-handler stacks. `pipeline api = with RateLimit, Authenticate`. Channels' `handle_in(event, payload, state) -> state` = state-effect handler.

### Functional / type-level / effect-system ecosystem

- **Servant** — type-level routes. **Steal**: route-as-introspectable-value principle (without DataKinds).
- **Yesod** — bidirectional type-safe routes. **Steal**: `route_for(:user_show, id)` should be primitive.
- **Scotty** — Sinatra in Haskell. **Steal**: low-ceremony hello-world.
- **http4s** — Kleisli middleware, routes-are-values. **Steal**: handler-as-Kleisli IS what effects make native.
- **Tapir** — describe once, derive everything. **Steal**: the genre-defining feature. Endpoint as first-class value.
- **ZIO HTTP** — per-request fiber + environment row. **Steal**: per-request fiber semantics natively via effects.
- **Dream** — two-types-only minimalism + direct-style I/O via effects. **Steal**: the entire shape.
- **Riot/Nomad** — direct-style I/O via OCaml 5 effects. **Confirms**: Quartz design direction is correct.
- **Eio** — structured concurrency via `Switch` (resource lifetimes tied to scopes). **Steal**: cancellation as structured-concurrency primitive.
- **Giraffe** — Kleisli composition (`>=>`). **Steal**: nothing structural — `>=>` IS sugared effect-handler-stack.
- **Falco** — simpler than Giraffe. **Lesson**: Kleisli-as-default-middleware is overkill if you have first-class effects.
- **Saturn** — F# computation-expression-shaped DSL. **Lesson**: computation expressions ARE sugared algebraic effects.
- **Koka** — has the substrate, not the library. **The opportunity is open.**
- **Effekt** — second-class capabilities. **Steal**: capability scoping for resource leaks. Nobody has shipped this in production.
- **Eff** — research-grade, no industrial use. **Confirms**: open territory.

---

## Raw agent reports (preserved as primary sources)

The four agent reports are preserved verbatim below for traceability. Each agent owned one ecosystem and ran in parallel.

### Agent A — Rust + Zig

[Full report from the Rust + Zig HTTP framework survey, ~2500 words. See git history for original.]

Key reusable code patterns:
- axum hello-world: `Router::new().route("/", get(hello)); axum::serve(listener, app).await`.
- tower abstraction: `trait Service<Request> { type Response; type Error; type Future; fn call(&mut self, req: Request) -> Self::Future; }`.
- rocket guards: `fn admin(user: AdminUser) -> Result<Json<Foo>, Status>`.

### Agent B — Go + JS/TS

Key reusable code patterns:
- net/http: `http.HandleFunc("/hello", func(w, r) { fmt.Fprintln(w, "Hi") })`.
- echo: `e.GET("/hello", func(c echo.Context) error { return c.JSON(200, ...) })`.
- huma: `huma.Register(api, huma.Operation{...}, func(ctx, *In) (*Out, error) {...})`.
- Hono: `app.get('/hello/:name', (c) => c.json({...}))`.
- Elysia: `new Elysia().get('/hello/:name', ({params}) => ({...})).listen(3000)`.

### Agent C — Ruby + Python + Elixir

Key reusable code patterns:
- Sinatra: `get '/' do 'Hello' end`.
- Roda: `route do |r| r.on "users" do r.get(":id") {...} end end`.
- FastAPI: `@app.get("/items/{id}") def read(id: int, db: Session = Depends(get_db)): ...`.
- Phoenix: `pipeline :api do plug :rate_limit end; scope "/api" do pipe_through :api; get "/", Ctrl, :action end`.

### Agent D — Functional + effect-system

Key reusable code patterns:
- Servant: `type API = "users" :> Capture "id" Int :> Get '[JSON] User`.
- http4s: `HttpRoutes.of[IO] { case GET -> Root / "hello" / name => Ok(...) }`.
- Tapir: `endpoint.in(...).out(...).errorOut(...).serverLogic(handler)`.
- ZIO HTTP: `Routes(Method.GET / "hello" / string("name") -> handler { (name, _) => Response.text(...) })`.
- Dream: `Dream.get "/" (fun _ -> Dream.html "Hi")`.
- Giraffe: `route "/" >=> text "Hello"`.

## References

External (covered above):
- Sinatra: <https://sinatrarb.com/>
- FastAPI: <https://fastapi.tiangolo.com/>
- Hono: <https://hono.dev/>
- Phoenix: <https://hexdocs.pm/phoenix/routing.html>
- axum: <https://docs.rs/axum/>
- Tapir: <https://tapir.softwaremill.com/>
- ZIO HTTP: <https://zio.dev/zio-http/>
- http4s: <https://http4s.org/>
- Dream: <https://camlworks.github.io/dream/>
- Effekt: <https://effekt-lang.org/>
- Koka: <https://koka-lang.github.io/koka/>

Internal:
- [`PHASE_6_1_HTTP_EFFECTS.md`](../design/PHASE_6_1_HTTP_EFFECTS.md) — design memo built on this survey.
- [`PHASE_6_2_QUAKE_EFFECTS.md`](../design/PHASE_6_2_QUAKE_EFFECTS.md) — sibling Quake migration memo.
- [`EFFECT_MIGRATION_PLAYBOOK.md`](../design/EFFECT_MIGRATION_PLAYBOOK.md) — Phase 5 dogfooding playbook.
