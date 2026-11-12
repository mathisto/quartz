# The `Alloc` Effect

> **Status**: Phase A + Phase B (B.0a, B.0c, B.1–B.5) complete as of 2026-04-27. Universal allocation routing, four call-form handler sugars, runtime-blessed default, fixpoint stable.

## What it is

`Alloc` is an algebraic effect declared in `std/alloc.qz`:

```quartz
effect Alloc
  def alloc(size: Int): CPtr
  def dealloc(ptr: CPtr): Void
end
```

Every allocation in the language flows through it. The compiler emits a `@__qz_alloc(i64 bytes) -> ptr` runtime wrapper at every malloc site (~178 codegen-layer sites unified in Phase A.3.c), so a `with Alloc { ... } do body end` block sees every allocation in `body`'s dynamic extent — user-visible `alloc(N)`, plus internal Vec/String/Map/closure-env/struct-heap-init allocations.

By default, programs run with a runtime-blessed handler that forwards `alloc`/`dealloc` to `malloc`/`free`. The blessed install at the start of `@main` puts a watermark on the effect stack; the wrapper short-circuits to direct `@malloc` whenever no user handler is installed on top of the watermark, preserving zero overhead for default-handler programs.

## Why an effect

Three reasons the substrate is an effect rather than a thread-local pointer or a global hook:

1. **Composability.** `Alloc` composes with `Throws` (deny/budget refusals throw), `State` (handler-internal accounting), `Reader` (handler reads ambient context). The effect runtime already handles install/uninstall + handler stack discipline; reusing it means no parallel mechanism.
2. **Lexical scoping.** `with Alloc { ... } do body end` makes the handler's extent explicit and structurally enforced. No "did somebody forget to reset the global pointer" failure mode.
3. **Per-install state.** The B.0c substrate (`__qz_effect_stack_state_slots[256]` + `__qz_effect_state_get/set`) gives each install its own state slot, so nested or sequential blocks have independent state. This is what makes `Alloc.in_arena(ar1) do ... with Alloc.in_arena(ar2) do ... end ... end` work without a separate "active arena" global.

## How it routes

```
user alloc(N) call
  ↓
@__qz_alloc(i64 N)              ; alwaysinline wrapper (always emitted)
  ↓
[stage 1]  top <= __qz_alloc_blessed_watermark?  → direct @malloc       ; default-program fast-path
  ↓ no
[stage 2]  __qz_alloc_in_handler == 1?  → direct @malloc                ; reentrancy bypass
  ↓ no
__qz_effect_perform("Alloc", "alloc", 1, [N])
  ↓
top-down scan of __qz_effect_stack_*[]  → find user handler entry
  ↓
call handler_fn(op_name, argc=1, argv=[N])
  ↓
handler returns ptr
  ↓
perform returns ptr to wrapper
  ↓
wrapper returns ptr to user
```

The static fast-path (Phase A.4 `codegen_instr.qz`'s G.2 path) inlines a direct call to the resolved handler at compile time when the handler is statically determinable (one Alloc handler in lexical scope, alloc directly inside the with-block body). This skips the runtime scan entirely and is what makes overhead negligible for the most common call shape.

## Handler ABI

```quartz
def my_alloc(op_name: Int, argc: Int, argv: Int): Int
  var size = load(argv, 0)
  # ... custom strategy ...
  return mem_alloc(size)  # or arena_alloc, or @malloc, or throw, ...
end

def my_dealloc(op_name: Int, argc: Int, argv: Int): Int
  var ptr = load(argv, 0)
  mem_free(ptr)
  return 0  # return value ignored for Void ops
end
```

Decode arguments with `load(argv, 0)` (slot 0 is the size for alloc, ptr for dealloc).

## Install forms

### Explicit handler record

```quartz
with Alloc { alloc: my_alloc, dealloc: my_dealloc } do ->
  work()
end
```

Per-op install: each field becomes one stack entry with `op_filter=field_name`. Unmatched ops fall through to outer handlers (H-delegate).

### Call-form sugars (Phase B)

Four canonical patterns ship with `std/alloc.qz`. Each is a method-dispatch sugar that expands to an explicit handler-record install with env threaded through `state_slots` for per-install isolation.

#### `with Alloc.in_arena(arena) do body end` (B.1)

Routes all allocations to a user-provided arena. Dealloc is a no-op (arena memory frees in bulk via `arena_reset`/`arena_destroy`).

```quartz
import std/alloc
import std/memory

def main(): Int
  var ar = arena_new(16384)
  with Alloc.in_arena(ar) do ->
    var p = alloc(64)
    var v = vec_new<Int>()
    v.push(1)  # Vec struct goes in arena (storage growth bypasses — see ALLOC_REALLOC_BYPASS.md)
  end
  arena_destroy(ar)
  return 0
end
```

Nested in_arena blocks have independent state — each install reads its own arena handle from its slot via `__qz_effect_state_get()`.

#### `with Alloc.deny_all() do body end` (B.3)

Refuses every allocation by throwing via `Throws`. Body code that allocates terminates the program with exit 66 (runtime-blessed Throws default writes the message to stderr). To recover gracefully, wrap with `with Throws { throw: rec } do ... end`.

```quartz
def my_throws(op_name: Int, argc: Int, argv: Int): Int
  puts("caught: alloc denied")
  return 0
end

def main(): Int
  with Throws { throw: my_throws } do ->
    with Alloc.deny_all() do ->
      var p = alloc(8)  # throws → "caught: alloc denied"
    end
  end
  return 0
end
```

The `dealloc` handler is permissive (forwards to `mem_free`) so callers may still free pre-sandbox memory.

#### `with Alloc.with_budget(N) do body end` (B.4)

Caps total allocations at N bytes. Each `alloc(size)` checks `state_get() >= size` and either decrements via `state_set(remaining - size)` or throws via `Throws`. Dealloc is a no-op for budget purposes (cumulative-allocation semantics, not live-bytes).

```quartz
def main(): Int
  with Alloc.with_budget(1024) do ->
    var p = alloc(512)
    var q = alloc(400)
    var r = alloc(200)  # throws — would push past 1024
  end
  return 0
end
```

Sequential `with_budget` scopes have independent counters (per-install state slots). Nested scopes also independent — inner trips on its own remaining without affecting outer's slot.

#### `with TestAlloc do body end` (B.2)

Bare-IDENT alias for an Alloc install backed by a singleton test arena. At install time, `test_alloc_arena_acquire()` lazy-creates the arena on first call and resets it on every subsequent call — sequential blocks each see a fresh arena, no leak between scopes.

```quartz
import std/alloc

def main(): Int
  with TestAlloc do ->
    var v = setup_complex_state()
    assert_invariant(v)
  end
  # arena reset at next acquire — no manual cleanup needed
  return 0
end
```

`TestAlloc` claims the `Alloc` effect through a typecheck alias rule (`tc_with_handler_begin` maps the bare IDENT "TestAlloc" to "Alloc" lookup), so body code with `can Alloc` rows is satisfied without a separate effect declaration.

**Limitation**: nested `with TestAlloc` blocks share the singleton; the inner reset wipes outer's allocations. Test framework integration (one `with TestAlloc` per `it` block) doesn't hit this. Per-scope arena lifecycles need a per-install teardown substrate (filed as a Phase B followup) before nesting works.

## Default handlers (`std/alloc.qz`)

Phase A.5 ships four module-level handler families that compose with the explicit-record install form. State lives in module globals accessed via `alloc_set_*` setters; the B.0c env-aware variants (`*_e` suffix) read state from the per-install slot instead.

| Family | alloc | dealloc | State |
|---|---|---|---|
| arena | `arena_alloc_handler` (module) / `arena_alloc_handler_e` (env) | no-op | arena handle |
| counter | `counter_alloc_handler` | `counter_dealloc_handler` (forwards) | budget + used (module) |
| deny | `deny_alloc_handler` (throws) | `deny_dealloc_handler` (forwards) | none |
| tracking | `tracking_alloc_handler` | `tracking_dealloc_handler` | counters (module) |
| budget | — | — | env-aware `budget_*_handler_e` (Phase B.4) |

The B.1–B.4 call-form sugars route through the env-aware handlers (`_e` suffix) so they don't share module-global state and compose cleanly under nesting.

## Refusal semantics (D5 lock-in)

Handlers that need to refuse an allocation throw via `Throws` from `std/throws`:

```quartz
throw("Alloc: budget exceeded — remaining=64B requested=128B")
```

Three reasons over null-return:
- `Throws` is in the runtime-blessed prelude default-handler set, so refusal becomes a clean process termination with diagnostic by default.
- Callers can install `with Throws { throw: rec }` for recovery — composes cleanly.
- Every-caller-checks-null is brittle and contradicts the existential type model.

## Reentrancy

A handler that itself allocates (e.g., a tracking handler that grows a Vec to record allocations, or a refusal handler that allocates a string for the message) will recurse without protection. The runtime sets `__qz_alloc_in_handler = 1` (TLS) around each handler invocation; the wrapper's stage-2 check observes this and bypasses to direct `@malloc`. Both `__qz_effect_perform`'s do_call and the static fast-path's direct-call branch maintain this invariant (Phase A.6 fix).

The bypass flag is also restored at every with-block's `wb.catch` (Phase B.0a) so a handler-thrown longjmp doesn't leak the bypass state into the caller's recovery path.

## Composition with other effects

`Alloc` and `Throws` are both in the runtime-blessed prelude default set, so functions that allocate and/or throw don't need explicit `can Alloc` or `can Throws` annotations — body code's allocation and throw-on-refusal are blessed-relaxed. Cascading `can Alloc` through helper signatures is supported but rarely needed because of this relaxation.

`State` and `Reader` handlers may allocate; under a custom `with Alloc { ... } do ... end`, their internal allocations route through the user handler. This is good behavior — emerges from the substrate without `Alloc`-aware `State`/`Reader` plumbing.

`go`/`spawn` task frames inherit the parent's `Alloc` handler **by default**. The keyword `go fn()` does not yet auto-install a per-task arena (filed as Phase E.1.b — compiler change to extend the async frame layout + inject install/uninstall in $poll).

**Phase E.1.a** ships the per-task arena as an opt-in stdlib API:

```be
import concurrency

def task_body(): Int
  var v = vec_new<Int>()
  for i in 0..1000
    v.push(i * 7)
  end
  return v[999]
end

def main(): Int
  sched_init(0)
  var t = go_arena(task_body)   # per-task arena auto-installed
  var r = await t
  sched_shutdown()
  return r
end
```

`go_arena(f)` wraps `f`'s body in `with Alloc.in_arena(arena_new(8192)) do -> f() end` and `arena_destroy`-s the arena when `f` returns. Allocations made inside the task body land in the per-task arena and free in bulk at task end — bounded RSS under task churn (Erlang/BEAM-style structured memory).

**E.1.a limitations** (each filed as a follow-up sub-phase):

- Tasks must return value-typed data (`Int`, `Bool`). Reference-typed returns (String, Vec) live in the per-task arena and dangle after `arena_destroy` — Phase E.4 (escape mechanism).
- Truly-parallel `go_arena` tasks under multi-worker scheduler (`sched_init(0)`) race on the global `__qz_effect_stack_top` → SIGSEGV. Workaround: `sched_init(1)`. Filed as Phase E.1.c — TLS top + per-worker prelude install.
- Heavy-allocating tasks (>50K allocs) can trigger the latent `arena_destroy` corruption bug in `docs/bugs/D2_ARENA_DESTROY_AT_TC_SCALE_CORRUPTS_HEAP.md` — Phase E.5.

## What does NOT route through Alloc

Two known gaps as of 2026-04-27 (post A.3.d):

1. **Stack allocations**: `@value` structs, `alloca`'d locals, and stack-allocated tuples never touch `Alloc`. By design — stack memory is bounded by scope and free.
2. **Code outside compiled binaries**: FFI calls into native libraries that allocate via libc directly bypass Alloc. Wrap the FFI in a Quartz function that explicitly forwards via the Alloc surface if you need observation.

(`@realloc` paths were a third gap until A.3.d — `qz_vec_push_impl`, StringBuilder grow, task_group resize, regex grow, vec_resize all called `@realloc` directly. Closed by emitting `@__qz_realloc(ptr, i64 old_bytes, i64 new_bytes)` and decomposing on the routing path into `alloc(new) + memcpy(min) + dealloc(old)` via the existing two-op surface.)

## Performance

Phase A.4 measurements (alloc-heavy benchmark, 2M malloc/free pairs):

| Configuration | Wall (ms) | Overhead |
|---|---|---|
| Direct `@malloc`/`@free` (pre-Alloc baseline) | 28 | — |
| Alloc-wrapped, no user handler (blessed default + watermark fast-path) | 29 | ~3.6% |
| Alloc-wrapped, user handler installed | varies | dominated by the handler |

The Vec-push tight-loop benchmark (10M push ops) shows zero regression vs pre-Alloc — the wrapper inlines and the watermark check folds away.

## Status of related work

- **Phase A** (substrate): A.0–A.7 + A.3.d done. Universal routing in place INCLUDING realloc paths. Default-handler programs effectively zero-overhead.
- **Phase B** (handler library): B.0a, B.0c, B.1–B.5 done. Closures-as-handlers and per-install teardown substrate filed as deferred followups.
- **Phase C** (compiler dogfood prep): Not started. Allocation hot-spot inventory pending.
- **Phase D** (compiler arena dogfood): Sequenced after C. Realloc bypass closed (A.3.d) — no longer a blocker.
- **Phase E.1.a** (per-task arenas, opt-in): Shipped 2026-04-28. `go_arena(f)` stdlib API; 5-test spec at `spec/qspec/alloc_e1_per_task_arena_spec.qz`.
- **Phase E.1.b** (auto-arena via `go` keyword): Pending — compiler change.
- **Phase E.1.c** (multi-worker effect-stack TLS fix): Pending — move the global `__qz_effect_stack_top` to TLS + per-worker prelude install (see E.1.a limitations above).
- **Phase E.4** (cross-task escape mechanism): Pending — auto-promote reference-typed returns at await boundary.
- **Phase E.5** (arena_destroy corruption fix): Pending — `docs/bugs/D2_ARENA_DESTROY_AT_TC_SCALE_CORRUPTS_HEAP.md`.
- **Phase E.6** (extend wrap to all `go_*` spawn variants): Pending — `go_spawn`/`go_cancellable`/`go_cancel_on_success`/`go_race` would fold into E.1.b's MIR-lowering change.
- **Phase E.7** (worker-local arena pool — perf): Pending — amortize mmap+munmap under high task churn via per-worker pool with `arena_reset` reuse.
- **Phase F** (arena gaps): Reactive — file as encountered.

See `docs/design/ALLOC_EFFECT_PLAN.md` for the full design memo + multi-phase roadmap.

## See also

- `std/alloc.qz` — effect declaration + module-level handler library + env-aware handler functions
- `std/memory.qz` — Arena, Pool, Allocator trait — substrate that Alloc handlers compose over
- `docs/design/ALLOC_EFFECT_PLAN.md` — full design memo (D1–D6 decision log, phase roadmap, prior-art comparison)
- `docs/bugs/ALLOC_REALLOC_BYPASS.md` — historical bug, closed by Phase A.3.d
- `spec/qspec/alloc_*_spec.qz` — 12 spec files, 72 acceptance tests covering all phases (includes `alloc_realloc_a3d_spec.qz` for realloc-path coverage)
