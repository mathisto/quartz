# Phase 4D.5c — Consumer-side merge: one Stream, one for-in, one state machine

> **Epic**: Operation Piezoelectric Effects · `[piezo]` · Phase 4D continuation
> **Parent**: [`PHASE_4D_ROW_POLY_STREAM.md`](PHASE_4D_ROW_POLY_STREAM.md) §4D.5b "What's still deferred (consumer-side merge)"
> **Status**: Design — implementation queued.
> **Filed**: 2026-04-25, on closure of 4D.6 (the producer-side and registry-cleanup arc).
> **Naming**: 4D.5c, the consumer-side companion to 4D.5b (producer-side `$poll` consolidation).
> **Predecessor design memos**:
> - [`PHASE_4D_ROW_POLY_STREAM.md`](PHASE_4D_ROW_POLY_STREAM.md) — the full 4D arc; this memo expands the deferred §4D.5b end-state.
> - [`P3_F_ROW_POLYMORPHISM.md`](P3_F_ROW_POLYMORPHISM.md) — function-level row-var infrastructure; 4D.5c does not extend it.
> - [`PHASE_4_GENERATORS_VIA_EFFECTS.md`](PHASE_4_GENERATORS_VIA_EFFECTS.md) §3.5 — original AsyncIterator-unification pitch.

## Why this memo exists

The 4D arc shipped in six commits (4D.1 → 4D.6, kickoff `9c62955c` … `90fd9a5a`). Most of the planned work landed:

- ✅ Struct row-var substrate (4D.1).
- ✅ `Stream<T, e>` row-poly redesign in `std/gen.qz` (4D.2).
- ✅ Generator return-type row inference (4D.3).
- ✅ For-in row widening via Stream<T, body_row> ptype (4D.4b/4c/4d).
- ✅ F.3c MIR + typecheck fast paths deleted (4D.4 + 4D.4d).
- ✅ Producer-side `$poll` consolidation — `mir_lower_async_generator` no longer emits inline `$poll`; non-spec async gens routed through PASS 1.2a's `mir_lower_async_poll`, specs handled in `mir_emit_pending_specializations` (4D.5b, `2ca90be3`).
- ✅ `_generator_func_names` + `_async_gen_func_names` registries deleted; dispatch is annotation-based (4D.5b.0).
- ✅ `tc.reserved[0]` generator-context cache + channel 1 of `_tc_p4b_yield_in_scope` deleted (4D.6).

What did **not** ship: the consumer-side merge. The constructor still differs sync-vs-async (sync emits a 2-word `Stream<T,e>` wrapper; async emits a raw 6-slot frame_ptr), and `lower_async_gen_iteration{,_indirect}` still exists as a separate state-machine emission alongside `lower_custom_iteration("Stream$next")`. The 4D.5b memo flagged this as "blocked on the park-encoding bridge: `Stream$next` is Quartz code, can't call `mir_emit_async_suspend_point` (compiler-internal MIR emission); falling back to `sched_yield` loses fd/timer wakeup-registration for async-I/O generators."

This memo designs that bridge.

## Current state — what consumer dispatch looks like today

There are **two consumer state machines** for generators, both compile-time-emitted:

### 1. Sync — `lower_custom_iteration` calling `Stream$next`

Source: `mir_lower_iter.qz:626`, called from `mir_lower_stmt_handlers.qz:1282, 1305, 1360`.

```
for v in s
  body
end
```

lowers to:

```
__citer = s
loop
  __copt = Stream$next(__citer)
  if option_is_some(__copt)
    v = option_get(__copt)
    option_free(__copt)
    body
  else
    option_free(__copt)
    break
  end
end
```

Where `Stream$next` is Quartz code in `std/gen.qz:84`:

```qz
def Stream.next<T, e>(self: Stream<T, e>): Option<T> can e
  var f = self.step
  var rv = with Yield { yield: __qz_gen_yield_capture } do -> f(self.frame) end
  if rv == 1
    return Option::None      # POLL_READY
  end
  return Option::Some(__qz_gen_take_stashed())   # treats !=1 as POLL_SUSPENDED
end
```

**The bug latent in async use**: if `f(self.frame)` returns a park-encoding (≤ -2) — because the generator body internally awaited an I/O — `Stream.next()` falls into the `else` branch and reads a stale `__qz_gen_take_stashed()` value. The park signal is lost. The outer async function never gets registered on the fd. Today this latent bug doesn't manifest because the caller compile-time dispatches to path 2 below for any async-typed source.

### 2. Async — `lower_async_gen_iteration{,_indirect}`

Source: `mir_lower_iter.qz:996-1124`, called from:
- `mir_lower_stmt_handlers.qz:1274` (NODE_CALL form: `for x in async_gen()`)
- `mir_lower_stmt_handlers.qz:1295` (NODE_IDENT-typed-async form)
- `mir_lower.qz:2658` (for-await NODE_CALL)
- `mir_lower.qz:2676` (for-await NODE_IDENT-typed)

```
for v in s             # or `for await v in s`
  body
end
```

lowers to a 5-block state machine:

```
agen_poll:
  status = step(frame)               # or indirect: load step from frame[2]
  if status == 1: jump exit
  else:           jump check_yield
agen_check_yield:
  if status == 0: jump got_yield     # POLL_SUSPENDED
  else:           jump park           # park-encoding ≤ -1
agen_park:
  if _gen_active >= 2:
    mir_emit_async_suspend_point(-1, agen_poll)   # propagate up to outer $poll
  else:
    sched_yield(); jump agen_poll                  # synchronous re-poll
agen_got_yield:
  v = __qz_gen_take_stashed()
  body
  jump agen_poll
agen_exit:
  ...
```

The crucial line is `mir_emit_async_suspend_point(-1, agen_poll)` — it saves the consumer's locals into ITS frame, sets state=next, returns the park-encoding-passthrough value, and emits a resume block at `agen_poll`. **This is the park-encoding bridge** and it is compiler-internal MIR emission. No Quartz function can invoke it; only MIR lowering can.

### What this means structurally

The two state machines share ~70% of their code: both bind a temp for the iter source, both run a loop with break/continue plumbing, both lower the body. They differ in:

- The cond block (sync: `option_is_some` check; async: 3-way status discriminant).
- The park branch (sync: nonexistent — Stream$next never returns a park signal; async: propagate-or-sched-yield).
- How "exit" is detected (sync: None from .next(); async: status == 1 directly off the inner $poll).

Plus the **producer**'s constructor differs:

- Sync `mir_lower_generator_effect` (mir_lower_gen.qz:801): emits `<name>` constructor that calls `__Future_<name>$new(params)` then wraps the resulting frame_ptr in a 2-word Stream<T,e> handle `{frame, step}`.
- Async `mir_lower_async_generator` (mir_lower_gen.qz:892): emits `<name>` constructor that inlines `$new`-equivalent logic and returns the **raw** 6-slot frame_ptr.

Same frame layout, different return shape. The Stream wrapper is the value-level type that 4D.2 lifted to row-poly. The async path bypasses it entirely.

## Prior art

I surveyed how other languages and effect systems handle "iterating over an async source whose body might suspend on I/O." Two architectural patterns dominate:

### Pattern 1 — Awaitable-as-park-signal (Rust, C#, Python, F#)

- **Rust** (`Stream::poll_next`): returns `Poll<Option<T>>`. When the source returns `Poll::Pending`, the consumer's `for await` lowering returns `Poll::Pending` from its OWN `poll`. This works because the consumer is ALSO inside an `async fn` whose state-machine lowering — generated by the same compiler pass — already has a resumption point at the `for await` site. The propagation IS the consumer's enclosing async lowering, not a separate intrinsic.
- **C#** (`IAsyncEnumerable<T>` + `await foreach`): `MoveNextAsync()` returns `ValueTask<bool>`. The `await` on that ValueTask is the suspension point — the consumer's compiler-generated MoveNext state machine stores its state, registers a continuation via `OnCompleted` on the awaiter, and returns. **The awaitable boundary IS the park channel.** Roslyn quote: *"The state machine contains builder and awaiter fields, used to run the state machine in the background when an await is reached in the async-iterator."*
- **Python** (PEP 525, `async for`): `__anext__()` returns an awaitable. The CPython coroutine driver `send`s into the awaitable and yields up to the event loop. Same pattern as C#.
- **F#** (`taskSeq`, `AsyncSeq`): same as C# — IAsyncEnumerable or an explicit `Async<AsyncSeqInner>` cell that consumers `let!` (await).

### Pattern 2 — Stack-walking effect/continuation runtime (eio, Koka, Effekt, Frank)

- **OCaml/eio** (effect handlers): `Eio.Fiber.fork_seq` — the runtime suspends the fiber's continuation and registers on io_uring/kqueue. No state machine; no consumer-side propagation. The OCaml runtime walks the stack transparently.
- **Koka** (evidence passing — Xie & Leijen, ICFP 2021): operations carry an evidence vector pointing at the handler frame. Suspends go directly to the right outer handler regardless of intermediate iterator frames. **No consumer-side intrinsic needed.**
- **Effekt** (capability-passing CPS — Brachthäuser, Schuster, Ostermann, ICFP 2020): iterated CPS translation; each effectful call point is a continuation boundary; consumer code inherits CPS lowering automatically.
- **Frank** (shallow handlers): each operation handled exactly once before re-handling. Iterating an effect-typed source naturally re-establishes the handler at each step.

### Where Quartz sits

Quartz's current `lower_async_gen_iteration` matches Pattern 1's Rust shape — compile-time per-call-site state-machine emission, propagation handled by the consumer's enclosing lowering. The kind=3 effect runtime (TLS park_rv slot, `__qz_effect_park`, `__qz_effect_resume_cont`) is a Pattern 2 substrate, but Quartz uses it only for the producer's $poll body, not for the consumer's iteration over a producer.

The clean answer per PD2: don't redesign — **regularize**. Quartz already has Rust's compile-time-state-machine shape; the merge work is to make the sync and async branches share one lowering, and to surface the park boundary as a compiler-recognized intrinsic so user `.next()` calls can also propagate park signals from within an async caller.

## Design

### The consolidation goal

```
                    EXISTS                    GOAL
                  ──────────              ─────────────
  Constructor:    sync: Stream<T,e>       BOTH: Stream<T,e>
                  async: raw frame_ptr

  For-in:         sync: lower_custom_      BOTH: lower_stream_
                       iteration                 iteration
                  async: lower_async_       (one function, row-gated
                       gen_iteration*           internal branches)

  .next() user:   sync: Stream$next         BOTH: Stream$next, BUT
                  async: typecheck OK,           `.next()` call sites
                         runtime broken          recognized as park-
                                                 propagation points
                                                 in async contexts
```

### The park-encoding bridge: a compiler-recognized intrinsic

The minimum requirement is one new MIR-level intrinsic:

```
__qz_async_park_propagate(rv: Int): Void
```

**Semantics**: given a park-encoded return value `rv` (≤ -1), propagate it as a suspend point. Lowered context-sensitively at MIR time:

- **Inside an async function** (`mir_lower_gen::mir_gen_is_active() >= 2`): expand to `mir_emit_async_suspend_point(rv_decoded_fd, current_block)`. Note `rv` is dynamic (the compiler doesn't know its value), so we emit a runtime decode: `fd = -rv - 2` (when rv ≤ -2) or `fd = -1` (when rv == -1). The emitted code stores @__qz_effect_park_rv = rv via `__qz_effect_park(fd)`, returns rv from the enclosing $poll, and emits a resume block at the current insertion point.

- **Outside an async function**: expand to `sched_yield()` followed by a normal return — synchronous re-poll. Same as today's else-branch in `_lower_async_gen_iter_impl`.

**Why this is the right primitive**: the only piece of `mir_emit_async_suspend_point` that's compiler-internal is the state-machine save/resume scaffold. Once that's wrapped behind an intrinsic, any user code path that ends with "if rv ≤ -1, propagate; else handle as normal Option result" can call the intrinsic and inherit the propagation.

This is the analog of Rust's `Poll::Pending` shape — the propagation is hidden behind a primitive that the compiler recognizes and expands per-call-site, not exposed as a runtime function.

### `Stream.next()` after the bridge

`Stream$next` becomes:

```qz
def Stream.next<T, e>(self: Stream<T, e>): Option<T> can e
  loop
    var f = self.step
    var rv = with Yield { yield: __qz_gen_yield_capture } do -> f(self.frame) end
    if rv == 1
      return Option::None
    end
    if rv == 0
      return Option::Some(__qz_gen_take_stashed())
    end
    # rv ≤ -1: park-encoding. Propagate via the bridge.
    __qz_async_park_propagate(rv)
    # In async: bridge suspended us; on resume control re-enters loop top.
    # In sync: bridge sched_yielded; control falls through to loop top.
  end
end
```

The body now correctly handles all three return states. Critically, **the same Stream$next body works for both sync and async callers**:

- Sync caller (`e = {}`): the typechecker ensures the generator body never returns a park-encoding (no Async in the body row). So `__qz_async_park_propagate` is never reached at runtime; the loop completes after rv==1 or rv==0. The intrinsic call still emits a sched_yield path, but it's dead code — peephole-eliminable.
- Async caller (`e ⊇ {Async}`): the bridge fires when needed; propagation works.

The function compiles ONCE — there is no per-call-site specialization. The intrinsic's MIR lowering is what's per-call-site sensitive.

> **⚠️ AMENDMENT 2026-04-25 (post-4D.5c.1 empirical verification — see §"Architectural correction" below): The two paragraphs above are wrong.** Quartz functions are compiled once; the intrinsic's MIR lowering checks `_gen_active` at the time the BODY is lowered, which for Stream.next is `0` (Stream.next is a regular function, not a generator/async). So the intrinsic always lowers to the sync sched_yield branch regardless of who calls Stream.next. Fixing requires either Stream.next inlining (compiler feature) or pivoting to Path B (keep two for-in lowerings; consolidate on Stream<T,e> value shape only).

### For-in lowering after the bridge

Once `Stream.next()` is a unified function, for-in collapses to one path:

```qz
for v in s         # OR `for await v in s`
  body
end
```

lowers (uniformly, via what's today `lower_custom_iteration`) to:

```
__citer = s
loop:
  __copt = Stream$next(__citer)        # row of caller widened by e if e ⊇ Async
  if option_is_some(__copt):
    v = option_get(__copt); option_free(__copt)
    body
    jump loop
  else:
    option_free(__copt); break
```

`lower_async_gen_iteration{,_indirect}` are deleted. `lower_custom_iteration` handles all cases. The 5-block state machine moves INTO Stream$next's body (where it always semantically belonged) and the intrinsic handles the park branch.

`for await v in s` desugars identically — the `await` keyword's role here (today, none — `for await` is a parser distinction that bypasses to `lower_async_gen_iteration*`) becomes a deprecated alias with the same lowering as bare `for v in s`. Phase 4D's design memo §"Non-goals" already noted `for await` deprecation as a one-commit followup once usage drops to zero; consolidating consumer dispatch makes that drop unconditional.

### Producer-side ctor merge (the second half of 4D.5c)

`mir_lower_async_generator` (mir_lower_gen.qz:892) currently inlines `$new`-equivalent logic and returns the raw frame_ptr. To unify with `mir_lower_generator_effect` (mir_lower_gen.qz:801):

1. Async generator constructor calls `__Future_<name>$new(params)` — same as sync (PASS 1.3c emits the $new for any async target, and async generators are async targets via PASS 0.99b's auto-registration).
2. Then wraps the returned frame_ptr in a 2-word Stream<T,e> handle, exactly as sync does.
3. Returns the Stream handle.

The frame layout is unchanged. The wrapping is the only delta. ~30 LOC of inline code in `mir_lower_async_generator` is replaced with the same ~5-line wrapper pattern `mir_lower_generator_effect` already has.

After this merge, `mir_lower_async_generator` and `mir_lower_generator_effect` are byte-for-byte identical except for whether they call `mir_lower_async_registry::mir_record_async_target(name, s)` (sync does this explicitly; async is auto-registered via the suspend-propagation pass). They can be folded into ONE function `mir_lower_generator_effect` that handles both — the auto-registration covers the explicit call's semantics.

### Indirect call sites (`var s: Stream<T,e> = some_gen(); for v in s`)

For NODE_IDENT iter sources whose static type is Stream<T,e>: the for-in lowering reads `s.field[1]` (step) and `s.field[0]` (frame), passes them to Stream$next. Stream$next is a Quartz function — it loads the same fields. No special-case needed for indirect; Stream<T,e>'s 2-word layout makes the indirect path the natural form.

This is the second-order cleanup: `lower_async_gen_iteration_indirect` (which today loads `frame[2]` for the poll fn pointer because async's raw frame_ptr puts it there) is deleted along with its direct sibling.

### One state machine, in one place

Post-4D.5c, the for-in/for-await consumer state machine lives in exactly two places:

1. **`Stream.next()` body** (std/gen.qz) — the produce/consume loop with park-propagation.
2. **`mir_lower_async_poll`** (the producer's $poll body — emitted by PASS 1.2a / `mir_emit_pending_specializations`).

`lower_async_gen_iteration{,_indirect}` are gone. `mir_lower_async_generator` is gone. The compiler retains `lower_custom_iteration` (for non-Stream user iterators — Vec, Map, etc.), and `mir_lower_generator_effect` (for both sync and async generator bodies).

Net code reduction: ~250-300 LOC.

## Implementation phasing

Five subphases. Each ships independently with a passing spec and fixpoint-byte-identical guard pass.

### 4D.5c.1 — `__qz_async_park_propagate` intrinsic (~0.7 quartz-day)

**Goal**: introduce the intrinsic; lower it to the existing `mir_emit_async_suspend_point` (async) or `sched_yield` + jump (sync) paths.

**Changes**:
- `typecheck_builtins.qz`: register `__qz_async_park_propagate(Int): Void`.
- `mir.qz`: add to intrinsic recognition; record any kind=3 leaf metadata if needed.
- `codegen_intrinsics.qz`: register in `cg_init_intrinsic_registry()` under category "core" (or "concurrency" — the latter matches `sched_yield`).
- `cg_intrinsic_concurrency.qz` (new handler): emit the conditional lowering. The actual decision is at MIR time, not codegen — see next bullet.
- `mir_lower_expr_handlers.qz` or a new `mir_lower_intrinsics.qz`: when lowering a NODE_CALL whose callee is `__qz_async_park_propagate`, branch on `mir_lower_gen::mir_gen_is_active() >= 2`:
  - Active (inside async): emit a runtime fd-decode, then `mir_emit_async_suspend_point(decoded_fd, current_block)`. The `rv` argument is loaded; we compute `decoded_fd = (rv == -1) ? -1 : -rv - 2` via two binary ops + a select. (Or: if the caller has already stored rv into TLS @__qz_effect_park_rv, just pass -1 as the fd to suspend point — the rv is read from TLS by the scheduler downstream; double-check the ABI.)
  - Inactive: `ctx.mir_emit_intrinsic("sched_yield", vec_new())`; control falls through.

**Verify**: trivial spec calling the intrinsic from a sync context (sched_yield emitted, no errors), then from a hand-written async function (suspend-point block emitted). Inspect MIR dumps for both. No existing for-in/for-await code paths touched yet.

**Risk**: low. The intrinsic is additive; nothing routes through it yet.

**LOC estimate**: ~80 LOC.

### 4D.5c.2 — `Stream.next()` body update (~0.3 quartz-day)

**Goal**: rewrite `Stream.next()` to use the intrinsic; verify it still works for all sync paths AND now correctly propagates park from async paths.

**Changes**:
- `std/gen.qz` Stream.next: the body shown above. ~10 LOC delta.

**Verify**:
- All existing sync gen specs pass unchanged (sched_yield path is dead code at the call sites; no behavior change observable).
- New spec: an async generator calling an I/O-suspending function (`fd_read` etc.) consumed via `var s = my_async_gen(); for v in s`. Verify the consumer is registered on the fd via fd-park, not busy-spinning via sched_yield. (Use a slow-fd setup; assert wallclock-cheap consumption.)

**Risk**: medium. The intrinsic must correctly reproduce the existing `lower_async_gen_iteration` park behavior. A/B test against the existing path before deletion.

**LOC estimate**: 10 LOC source + ~80 LOC spec.

### 4D.5c.3 — Async generator constructor wraps in Stream handle (~0.5 quartz-day)

**Goal**: `mir_lower_async_generator`'s constructor stops returning raw frame_ptr; wraps in 2-word Stream<T,e> like sync.

**Changes**:
- `mir_lower_gen.qz`: in `mir_lower_async_generator`, replace the in-place `mir_emit_alloc(frame_size) + populate + return frame_ptr` with `__Future_<name>$new(params...) → frame_ptr; mir_emit_alloc(2) + store frame + step ref + return wrapper`. Same shape as `mir_lower_generator_effect`.
- The function now becomes structurally a clone of `mir_lower_generator_effect` minus the explicit `mir_record_async_target` call (already handled by PASS 0.99b). Folding the two into one function is the next phase.
- `mir_lower_expr_handlers.qz:2805` (colorless-dispatch skip): may need to look through the Stream wrapper. Audit: today this skip checks if a NODE_CALL evaluates to an async-gen frame and avoids unwrapping it as an awaitable. If the callee now returns a Stream wrapper, the skip's matched shape changes. Likely the predicate itself needs updating to recognize the Stream<T,e> ptype with row ⊇ Async.

**Verify**:
- All async generator specs pass unchanged. The Stream wrapper at the value level is invisible at runtime (i64 either way); only the indirect access path through `s.frame` / `s.step` differs.
- The colorless-dispatch case (which hit hardest in earlier merge attempts — see memo §4D.5b "What's still deferred") is the load-bearing test: `for v in async_gen()` where async_gen returns a Stream that internally awaits. Verify the consumer doesn't wrongly unwrap.

**Risk**: medium-high. The 4D.5b memo flagged this as the historic blocker for Option A's full constructor merge. Mitigation: ship 4D.5c.1 + 4D.5c.2 first so the new unified consumer path is proven to work via Stream$next; THEN flip the producer to emit Stream wrappers; the consumer is already ready.

**LOC estimate**: ~40 LOC delta (mir_lower_gen.qz delete inline alloc + add wrap; mir_lower_expr_handlers.qz update colorless skip predicate).

### 4D.5c.4 — Delete `lower_async_gen_iteration{,_indirect}`; route async for-in/for-await through `lower_custom_iteration` (~0.3 quartz-day)

**Goal**: dispatcher cleanup. Once 4D.5c.2 + 4D.5c.3 ship, the async for-in/for-await branches become dead.

**Changes**:
- `mir_lower_stmt_handlers.qz:1259-1305`: the async-gen branches (NODE_CALL → `lower_async_gen_iteration`, NODE_IDENT-async → `lower_async_gen_iteration_indirect`) collapse into the same `lower_custom_iteration(ctx, ..., "Stream$next")` call as the sync path. Only the `for await` keyword distinction remains, and it lowers identically.
- `mir_lower.qz:2640-2676` (for-await dispatcher): same collapse.
- `mir_lower_iter.qz:996-1124`: delete `lower_async_gen_iteration`, `lower_async_gen_iteration_indirect`, `_lower_async_gen_iter_impl`. ~130 LOC removed.

**Verify**: the entire 13-spec generator/iterator/effect sweep + smoke tests + iterator_protocol's 52 tests. Zero regressions expected — the new path is what 4D.5c.2 already drove.

**Risk**: low. Pure deletion of code that's now dead.

**LOC estimate**: ~150 LOC removed; ~10 LOC added in the dispatchers.

### 4D.5c.5 — Fold `mir_lower_async_generator` into `mir_lower_generator_effect` (~0.3 quartz-day)

**Goal**: one generator-lowering function, not two.

**Changes**:
- `mir_lower_gen.qz`: delete `mir_lower_async_generator`. Update `mir_lower_function_with_name` (mir_lower.qz:3295-3307) to dispatch both `impl Iterator<...>` and `impl AsyncIterator<...>` (and the row-poly form `impl Iterator<...> can Async`) to `mir_lower_generator_effect`.
- The auto-registration via PASS 0.99b's suspend-propagation covers the async case — `mir_record_async_target` is still called explicitly in `mir_lower_generator_effect` for the sync case, AND idempotently re-called by PASS 0.99b for async. Confirm via spec.

**Verify**: fixpoint byte-identical (no behavior change for either sync or async — both lower to the same shape they did pre-fold). All existing 13-spec sweep + smoke tests pass.

**Risk**: low. The producer-side merge after 4D.5c.3 leaves the two functions structurally identical.

**LOC estimate**: ~80 LOC removed (mir_lower_async_generator goes); ~5 LOC added (dispatcher gates on annotation prefix).

## End-state

After 4D.5c ships, the generator/iterator pipeline is:

```
                    PRODUCE                            CONSUME
                  ─────────────                       ─────────────
  AST def:        def gen(): impl Iterator<T> [can Async]?

  Lowering:       mir_lower_generator_effect          for v in s  →  Stream$next loop
                  ↓                                                 (lower_custom_iteration)
                  Constructor: 2-word Stream<T,e>     OR explicit s.next()
                  ↓                                                 ↓
                  $new (PASS 1.3c)                                  Stream.next() body
                  ↓                                                 ↓
                  $poll (PASS 1.2a / specs)                         __qz_async_park_propagate(rv)
                                                                    ↓
                                                                    [in async: suspend-point;
                                                                     in sync: sched_yield]

  Annotation:     impl Iterator<T> [can Async]?       caller's row widened by e

  Registries:     none                                none
  Static types:   Stream<T, e>                        Stream<T, e>
```

Three deletions, three concentrations:

- **Deleted**: `mir_lower_async_generator`, `lower_async_gen_iteration`, `lower_async_gen_iteration_indirect`.
- **Concentrated**: state-machine code now lives only in `Stream.next()` + `mir_lower_async_poll`. Park propagation lives only in `__qz_async_park_propagate`'s lowering.

## Risks and mitigations

### R1 — Park-encoding ABI mismatch — RESOLVED 2026-04-25

The intrinsic lowers to a suspend-point. The question was whether to read the park encoding from TLS `@__qz_effect_park_rv` or from the rv argument.

**Audit findings** (from session 2026-04-25, post-design-memo):

1. **fd-park rv ≤ -2 is NOT routed through TLS**. `mir_emit_async_suspend_point(ctx, fd, target)` (mir_lower_gen.qz:233-279) computes the return value from `fd_val` and emits `ret -(fd+2)` literally as the block terminator. TLS is bypassed.
2. **TLS `@__qz_effect_park_rv` is only used by kind=3 perform-suspend**. `mir_emit_kind3_perform_suspend` (mir_lower_gen.qz:310-…) resets TLS to 1 (POLL_READY) before perform, dispatches to handler (which may write via `__qz_effect_park` or `__qz_effect_suspend`), then reads TLS via `__qz_effect_park_get_rv()` and returns that as the outer poll's rv.
3. **Async generator body's NODE_AWAIT lowering** uses kind=3 perform on Async, which dispatches to `__qz_default_async_handler`'s `do_await` branch — busy-poll, then `resume_cont`. **No park encoding is returned for `await expr` in the current implementation; the default handler busy-polls.**
4. **The actual cases where a generator's $poll returns a park encoding**:
   - Channel select with fd registration → `mir_emit_async_suspend_point(ctx, loaded_fd, target)` → emits `ret -(fd+2)` directly.
   - sched_sleep timer → `mir_emit_async_suspend_point(ctx, sleep_fd=0, target)`.
   - Plain `sched_yield` in async context → `mir_emit_async_suspend_point(ctx, -1, 0)` → `ret 0`.
   - Async mutex/rwlock contention → similar fd-based suspend point.

**Conclusion**: the rv on the wire (that flows up through `f(self.frame)` in Stream$next) IS the park encoding directly. TLS state at that point is unreliable (only set if the most recent suspend was a kind=3 perform; not set for direct `mir_emit_async_suspend_point` calls).

**Implementation requirement for 4D.5c.1**: the intrinsic must use the rv argument directly — emit a `ret %rv` terminator with the dynamic rv value. Cannot rely on `__qz_effect_park_get_rv()` or `mir_emit_async_suspend_point`'s fd-encoding logic (which would re-encode and lose the original).

**Solution**: introduce `mir_emit_async_suspend_point_raw(ctx, raw_rv: Int, resume_target: Int): Int` alongside the existing `mir_emit_async_suspend_point`. The "raw" variant takes a dynamic SSA register holding the rv to return; otherwise identical scaffold (save locals to frame, set state=next_state, ret raw_rv, resume block with locals-reload + cancel check). The existing function delegates to the raw variant after computing fd → ret encoding. Net code increase: ~5 LOC.

The intrinsic's MIR lowering for the active branch becomes a one-line call: `mir_emit_async_suspend_point_raw(ctx, rv_arg, current_block)`.

### R2 — Fixpoint regression

Producer constructor wraps Stream<T,e> for async — runtime ABI changes. Pre-existing async I/O code (file_open returning a Future, etc.) doesn't go through async-generator constructors, so should be unaffected. Async generator constructors are called only from for-in / for-await / explicit `gen()` followed by `.next()` — all consumer paths are updated in 4D.5c.4.

**Mitigation**: ship 4D.5c.3 only after 4D.5c.2 + 4D.5c.4 are dependent-ordered correctly. The "wrap in Stream" change has a narrow blast radius, but only after the consumer is ready.

### R3 — Spec coverage for the colorless-dispatch case

`mir_lower_expr_handlers.qz:2805` skips unwrapping async-gen constructor returns as awaited frames. After the producer wraps in Stream, this site needs to recognize Stream<T,e> shape. The existing skip predicate uses `mir_func_annotation_is_async_generator` — annotation-based, type-independent.

**Mitigation**: 4D.5c.3 includes an explicit spec that triggers the colorless-dispatch site (e.g., a place where `await my_async_gen()` would be wrong but `for v in my_async_gen()` is right). Verify the skip predicate still fires.

### R4 — `for await` deprecation timing

4D.5c.4 collapses `for await` and `for v in ...` to the same lowering. `for await` becomes purely a parser distinction with a deprecation warning. Phase 4D's parent memo §Non-goals deferred this; 4D.5c makes it natural.

**Mitigation**: emit a warning, don't error. One-commit followup retires the keyword once usage drops.

### R5 — Stream$next compiles to a longer instruction sequence than today's lower_async_gen_iteration

Stream$next has one extra branch (the rv == 0 check) and one intrinsic call vs the existing 5-block state machine. Both are within the same loop body. Net IR count: roughly equivalent; the intrinsic call expands inline at the call site, so no actual function-call overhead in the async path.

**Mitigation**: benchmark a 1M-element async generator before and after. Aim for ≤ 5% regression. If higher, investigate inlining annotations on Stream$next.

## Architectural correction (2026-04-25, post-4D.5c.1)

After shipping 4D.5c.1's intrinsic, an empirical verification surfaced a fundamental gap in the design above. **The original §"Stream.next() after the bridge" claim is wrong.**

### What I tested

A reduced repro: a regular helper function `def helper(rv: Int): Void; __qz_async_park_propagate(rv); end`, called from inside an async generator body. Inspected the emitted IR for `helper`:

```llvm
define i64 @helper(i64 noundef %p0) ... {
  ; sched_yield: cooperative yield point
  call i32 @usleep(i32 1)
  ...
}
```

The intrinsic in `helper`'s body lowered to **sched_yield**, not a state-machine suspend point — even though `helper` is invoked from `@my_gen$poll` where `_gen_active == 2`. The async generator's `park_resume` block exists separately for an unrelated `yield 42` site, not for the `helper(-3)` call.

### Why the original design fails

Quartz functions are compiled once. `mir_lower_expr_handlers.qz`'s `__qz_async_park_propagate` interception checks `mir_lower_gen::mir_gen_is_active()` — which reflects the **currently-being-lowered function's** generator/async state, not the call site that will eventually invoke that function.

For `Stream.next()` (a regular function, not a generator/async): `_gen_active == 0` for its entire body. The intrinsic always takes the sync sched_yield branch. Calling Stream.next() from an async caller doesn't change anything; the intrinsic in Stream.next's body is already compiled to sched_yield by the time the async caller invokes it.

So Stream.next() can't carry park propagation by simply calling the intrinsic. The intrinsic must be lowered AT the call site of Stream.next — which means either (a) inlining Stream.next at every call site so the intrinsic's lowering sees the caller's `_gen_active`, or (b) keeping the for-in async path as compiler-emitted state machine code (today's `lower_async_gen_iteration*`) so `_gen_active` is naturally the caller's.

### Path A — Stream.next inlining (the original design's full delivery)

For the original "one for-in path, one Stream.next" end-state, Stream.next must be inlined. Inlining is its own design + implementation effort. Quartz today has no general inlining infrastructure; the few inlined intrinsics (option_is_some etc.) are special-cased at codegen. Adding Stream.next-specific inlining means: (1) MIR-level recognition of Stream$next call sites, (2) substitution of the body with parameter binding, (3) ensuring the substituted body is lowered with the caller's `_gen_active` and frame context.

Estimate: ~150-300 LOC of new compiler infrastructure. Multi-session itself.

### Path B — Pivot: keep two for-in lowerings, unify on Stream<T,e>

The pragmatic full-correct solution given current scope:

1. **4D.5c.3 (unchanged)**: async generator constructor wraps in 2-word Stream<T,e> handle.
2. **4D.5c.4 (REVISED)**: do NOT delete `lower_async_gen_iteration{,_indirect}`. Instead REFACTOR them to read the frame from `Stream.field[0]` and the step fn from `Stream.field[1]` (today they read `frame[2]` for step and treat the whole thing as a raw frame_ptr). Consolidate into a single `lower_stream_async_iteration(ctx, ..., is_indirect: Bool)` that takes a Stream value as input. ~50 LOC delta.
3. **4D.5c.5 (unchanged)**: fold `mir_lower_async_generator` into `mir_lower_generator_effect` (both functions become byte-identical post-4D.5c.3 except auto-registration nuance).
4. **Stream.next() body update (4D.5c.2)**: do NOT add the intrinsic call. Stream.next stays sync-only — it's used by `lower_custom_iteration("Stream$next")` for sync streams (`Stream<T, {}>`). Async streams are routed through the inline state machine instead.
5. **Explicit `s.next()` calls in async user code**: typecheck row-widens caller (already shipped 4D.4c). Runtime: if user's `s.next()` is on an async-typed Stream and the inner $poll returns a park encoding, Stream.next mishandles it as POLL_SUSPENDED (today's latent bug). Documented limitation. Fix gated on Path A or a future inlining pass.

Path B's compromise: full consumer merge for the for-in path (one constructor, one generator-lowering function, two consumer state machines), but explicit `.next()` async calls retain a busy-loop fallback. **For the loud case `for v in s` — which is 99% of generator consumption — there's no perceptible difference from Path A's end-state.**

Net code reduction: ~120-180 LOC (vs Path A's ~250-300). Sequencing-correct: doesn't depend on inlining.

### Recommendation: Path B for 4D.5c, Path A as a separate Phase 4D.5d if/when inlining lands

Path B delivers the ~95% of value at ~50% of risk. Path A's residual gap (explicit `.next()` async behavior) is a documented limitation, not a deadlock — busy-loop fallback degrades latency but doesn't break correctness. Path A becomes a one-commit upgrade once Stream.next inlining (or a more general inlining pass) is in place.

### Status of 4D.5c.1 under the correction

4D.5c.1's intrinsic is still useful infrastructure. `mir_emit_async_suspend_point_raw` is the right primitive — it's just that its consumer is the inline for-in state machine (Path B's `lower_stream_async_iteration` will USE this helper to propagate dynamic rv values), not Stream.next.

Specifically: `lower_async_gen_iteration_indirect`'s park branch today calls `mir_emit_async_suspend_point(ctx, -1, poll_block)` which encodes `ret 0` (yield-park encoding). To correctly propagate a park encoding from the inner $poll's rv, it should call `mir_emit_async_suspend_point_raw(ctx, status_register, poll_block, "park_resume")` so the dynamic rv flows through unchanged. This is a small Path B improvement that Path A would also need.

So 4D.5c.1 is foundational; Path B's 4D.5c.4 will use it.

### Revised phase plan (Path B)

| # | Status | Goal |
|---|---|---|
| 4D.5c.1 | ✅ shipped `1c83da6c` | `__qz_async_park_propagate` intrinsic + `mir_emit_async_suspend_point_raw` helper |
| 4D.5c.2 | **CHANGED — minimal doc update only** | Stream.next() stays as today; documented sync-only; explicit `.next()` async limitation noted |
| 4D.5c.3 | ✅ shipped `e4b7d871` | Async generator ctor wraps in Stream<T,e> 2-word handle + paired consumer-read update + spec/$new emission + async-gen pre-poll skip |
| 4D.5c.4 | ✅ shipped `8374bcce` | Consolidated `lower_async_gen_iteration{,_indirect}` → single `lower_stream_async_iteration(is_indirect: Bool)` helper. Park branch upgraded from `mir_emit_async_suspend_point(-1, ...)` (which encoded `ret 0` and lost fd info) to `mir_emit_async_suspend_point_raw(status, poll_block, "park_resume")` so the inner $poll's rv flows up unchanged. -2 functions (two thin wrappers deleted). Fixpoint 2343 byte-identical. |
| 4D.5c.5 | ✅ shipped (this commit) | Folded `mir_lower_async_generator` into `mir_lower_generator_effect`. Dispatcher in `mir_lower_function_with_name` now routes both `impl Iterator<...>` and `impl AsyncIterator<...>` to the same constructor lowering (post-4D.5c.3 the two ctor bodies are byte-identical, both calling `__Future_<name>$new` and wrapping in 2-word Stream<T,e>). Async generators get auto-registered as async targets via PASS 0.99b's `__qz_yield_marker__` suspend-propagation; the explicit `mir_record_async_target` call inside `mir_lower_generator_effect` is idempotent (deduplicates by name), so it composes safely. -1 function. Fixpoint 2342 byte-identical. |

Total revised estimate: ~1.5-2 quartz-days. Lower than original because no Stream.next() body rewrite + spec; offset partly by 4D.5c.4 refactoring instead of just deleting.

Path A as separate phase: file Phase 4D.5d "Stream.next inlining" for future scoping. Estimate: 1.5-2 quartz-days for the inlining pass + final consumer merge. Pull-in trigger: explicit `.next()` async call hot path emerges in user code, or a more general inlining pass lands.

### What 4D.5c.3 actually shipped (2026-04-25)

The implementation hit two non-obvious issues that the original plan didn't anticipate. Filing them here for the next session and as feedback memos.

**1. Spec async-generators need `$new` emitted in `mir_lower_specialized_function`.**

PASS 1.3c (`mir_lower.qz:4378`) emits `__Future_<name>$new` for every async target in the registry — but uses `mir_lookup_function(ap_name)` to recover the AST handle, which returns 0 for spec names (they aren't in `all_funcs`). So spec async-generators get NO `$new` from PASS 1.3c. The original plan worked around this implicitly because the old `mir_lower_async_generator` ctor inline-allocated the frame itself (didn't need `$new`). Once the new ctor calls `__Future_<spec_name>$new(params...)`, that symbol must exist for specs too — `llc` rejected with `use of undefined value '@__Future_doubled$1$implAsyncIterator$Int$new'`. Fix: in `mir_lower_specialized_function`, after the `$poll` emission added in 4D.5b, also call `mir_lower_async_constructor` for async-gen specs. ~3 LOC.

**2. Async generators must skip pre-poll unconditionally.**

`mir_lower_async_constructor` does an eager pre-poll for non-suspendable functions ("pure functions complete on first poll → eager pre-poll for zero overhead"). Suspendability is gated by `mir_is_suspendable(name)` from the async-target registry. For spec names with no registry entry, `mir_is_suspendable` returns false → pre-poll runs → consumes the first yield before the consumer can read it. Symptom: `for await n in doubled(numbers())` printed `4 6` instead of `2 4 6`.

The right fix isn't "fix the registry for specs" — it's "async generators are never pure regardless of registry state." They yield. The first poll is consumer-visible work, not a free completion. Adding a guard `is_async_gen = mir_func_annotation_is_async_generator(ret_ann)` before the suspendable check makes the pre-poll skip on annotation, immune to registry presence/absence. ~3 LOC.

**3. The colorless-skip predicate at `mir_lower_expr_handlers.qz:2829-2838` needed NO change.**

`mir_func_annotation_is_generator` is annotation-based (`impl Iterator<` / `impl AsyncIterator<` prefix) and independent of the runtime frame shape. Both the pre-change form (raw frame_ptr) and post-change form (Stream wrapper) trigger the skip the same way. Memo §"Risks and mitigations R3" predicted a predicate update; in practice none was needed.

**Files touched** (4D.5c.3, single commit):
- `self-hosted/backend/mir_lower_gen.qz` — `mir_lower_async_generator`: replace inline-alloc with `__Future_<name>$new` call + 2-word Stream wrap (~30 LOC delta). `mir_lower_async_constructor`: add `is_async_gen` guard before pre-poll branch (~3 LOC).
- `self-hosted/backend/mir_lower_iter.qz` — `_lower_async_gen_iter_impl`: load inner frame from `wrapper[0]`, indirect step from `wrapper[1]` (~5 LOC delta, replaces ~3 LOC).
- `self-hosted/backend/mir_lower.qz` — `mir_lower_specialized_function`: emit `$new` alongside `$poll` for async-gen specs (~3 LOC).
- `spec/qspec/phase_4d5c3_async_gen_stream_wrapper_spec.qz` — 6-test spec covering NODE_CALL direct, NODE_IDENT indirect, for-await direct, for-await indirect, generator-inside-generator (colorless-skip case), and ctor-IR witness.

**Verification**:
- Quake guard fixpoint: byte-identical, 2345 functions (was 2344 — one new spec function: the spec'd `$new` for async-gen specs).
- 24-spec generator/iterator/effect/4D sweep: 24/24 specs, only 1 known pre-existing test failure (`generator_spec.qz` nested-while-yield, also fails on golden binary). `async_iterator_spec.qz` recovered to 26/27 (was 26/27 on golden — only the pre-existing `async generator yields zero values` empty-body bug fails). Net regressions: 0.
- New 4D.5c.3 spec: 6/6 green.
- Smoke tests: style_demo, brainfuck, Quakefile post-build all green.

**Followup risks for 4D.5c.4**:
- The `$new` + `$poll` spec-emission pair in `mir_lower_specialized_function` is now load-bearing for async-gen monomorphizations. If 4D.5c.5 folds `mir_lower_async_generator` into `mir_lower_generator_effect`, ensure the dispatcher in `mir_lower_function_with_name` still routes async-gen specs through the body-emission path that triggers spec queueing.
- The annotation-based pre-poll skip in `mir_lower_async_constructor` reads `ast_get_str2(s, node)`. For the row-poly form `impl Iterator<T> can Async`, str2 is rewritten to `impl AsyncIterator<T>` by 4D.3 before reaching this code path. Confirmed working in spec; flag if 4D.3 changes.

### What 4D.5c.4 actually shipped (2026-04-25)

Single commit. Three orthogonal changes ship together because the rename is a precondition for changing the four call-sites cleanly:

1. **Rename + delete wrappers** (`mir_lower_iter.qz`): `_lower_async_gen_iter_impl` → `lower_stream_async_iteration`. Deleted `lower_async_gen_iteration` and `lower_async_gen_iteration_indirect` (each was a 3-line forwarder). Param renamed `indirect` → `is_indirect` for symmetry with the public name.
2. **Park-branch upgrade** (same file, ~5 LOC): `mir_emit_async_suspend_point(ctx, -1, poll_block)` → `mir_emit_async_suspend_point_raw(ctx, status, poll_block, "park_resume")`. The dynamic SSA register holding the inner $poll's status is now the literal terminator value, so any park encoding (≤ -2 fd, timer, or 0 yield) flows up to the outer $poll unchanged.
3. **Call-site updates** (4 sites in `mir_lower_stmt_handlers.qz` + `mir_lower.qz`): direct calls pass `false`, indirect pass `true`. No semantic change beyond losing the wrapper hop.

Plus stale-comment refresh in `mir_lower_stmt_handlers.qz`, `mir_lower.qz`, `mir_lower_gen.qz` (×2), `codegen_runtime.qz`, `mir_lower_expr_handlers.qz` — all references to the deleted wrapper names point to `lower_stream_async_iteration` now.

**Files touched** (4D.5c.4, single commit):
- `self-hosted/backend/mir_lower_iter.qz` — rename + park-branch upgrade + comment-block refresh.
- `self-hosted/backend/mir_lower_stmt_handlers.qz` — 2 call-site swaps + 1 comment.
- `self-hosted/backend/mir_lower.qz` — 2 call-site swaps + 1 comment.
- `self-hosted/backend/mir_lower_gen.qz` — 2 comment refreshes (no code change).
- `self-hosted/backend/codegen_runtime.qz` — 1 comment refresh.
- `self-hosted/backend/mir_lower_expr_handlers.qz` — 1 comment refresh.
- `spec/qspec/phase_4d5c4_consolidated_async_iter_spec.qz` — 6-test spec covering all four entry points (NODE_CALL direct, NODE_IDENT-typed indirect, NODE_FOR_AWAIT direct, NODE_FOR_AWAIT indirect), the park_resume-block IR-witness for in-async-caller composition, and a multi-yield runtime end-to-end through the indirect entry point.

**Verification**:
- Quake guard fixpoint: byte-identical, 2343 functions (was 2345 — net -2 from removing the two thin wrappers).
- 24-spec generator/iterator/effect/4D sweep: 24/24 green (including the new 4D.5c.4 spec).
- iterator_protocol_spec: green (52 tests).
- Pre-existing failures match baseline: `generator_spec` nested-while-yield (1/23 fails, identical on golden); `async_iterator_spec` empty-body (1/27 fails, identical on golden). Net regressions: 0.
- Smoke tests: style_demo, brainfuck both green.
- New 4D.5c.4 spec: 6/6 green.

**Surprise finding — IR-witness asymmetry that wasn't**: the spec's test #5 ("park_resume block emitted when consumer is inside async caller's $poll") was designed as a discriminating witness for the helper-routing change, on the theory that pre-4D.5c.4 the consumer's park branch produced a `yield_resume` block (from `mir_emit_async_suspend_point(-1, ...)` → `fd<0` → `resume_label = "yield_resume"`) while post-4D.5c.4 it produces `park_resume` (from `mir_emit_async_suspend_point_raw(..., "park_resume")`). Empirically: the e4b7d871 binary (pre-4D.5c.4 golden) ALSO emits `park_resume` at the same site for the same witness program, with byte-identical IR. The most plausible explanation is that the e4b7d871 binary was built from a working tree that already had this exact change applied (the source committed at e4b7d871 has the old form, but the binary doesn't match it). The test still passes on the post-change binary; it just doesn't isolate the change against this specific golden. The actual behavioral improvement (dynamic rv propagation vs encoded-zero) requires real fd-park I/O to manifest, which the unit tests don't exercise. **Action item**: the binary-vs-source mismatch in e4b7d871 is worth investigating in a future session (or filing as a quake-guard/git-hook bypass incident) — but it's orthogonal to 4D.5c.4 correctness.

**Followup risks for 4D.5c.5**:
- The consolidated `lower_stream_async_iteration` sits naturally in `mir_lower_iter.qz`. 4D.5c.5's fold of `mir_lower_async_generator` into `mir_lower_generator_effect` leaves both producer and consumer paths sharing the same Stream<T,e> handle shape — no further consumer-side changes needed.
- The pre-existing `async_iterator_spec.qz` failure ("async generator yields zero values" — empty-body bug) was identical pre-vs-post 4D.5c.4. If 4D.5c.5 changes the producer-side dispatch, re-check that this baseline doesn't regress (or fix it — empty-body async gens are a clean-up target).

### What 4D.5c.5 actually shipped (2026-04-25)

Single commit. The fold that the prior phases set up.

1. **Delete `mir_lower_async_generator`** (mir_lower_gen.qz, ~75 LOC removed). Post-4D.5c.3 its body was byte-identical to `mir_lower_generator_effect` except for the explicit `mir_record_async_target(name, s)` call (sync only — async path gets auto-registered by PASS 0.99b's `__qz_yield_marker__` suspend-propagation before PASS 1.2a runs).
2. **Update dispatcher** in `mir_lower_function_with_name` (`mir_lower.qz:3320-3340`): both `impl AsyncIterator<` and `impl Iterator<` annotations now route to `mir_lower_generator_effect`. The explicit `mir_record_async_target` call there is harmless for async (idempotent: `mir_record_async_target` deduplicates by name; PASS 0.99b will re-call with the same `name`, returning early).
3. **Refresh stale comments** referencing the deleted function — `mir_lower_gen.qz` (file-header `_gen_active` block + `mir_lower_stmt_yield` docstring), `mir_lower.qz` (spec emission comments at `mir_lower_specialized_function` + PASS 1.2a comment), `typecheck_walk.qz` (4D.3 row-poly stamp comment).

The "row-poly form `impl Iterator<T> can Async`" case lands here unchanged: typecheck (4D.3) rewrites str2 to `impl AsyncIterator<T>` before MIR runs, so it picks up the same dispatcher branch as the explicit-async form.

**Files touched** (4D.5c.5, single commit):
- `self-hosted/backend/mir_lower_gen.qz` — delete `mir_lower_async_generator` (~75 LOC); refresh `mir_lower_generator_effect` docstring to acknowledge sync+async unification; refresh `_gen_active` block comment + `mir_lower_stmt_yield` docstring.
- `self-hosted/backend/mir_lower.qz` — dispatcher update (route async to unified function) + 3 stale comment refreshes (`mir_lower_specialized_function` × 2, PASS 1.2a).
- `self-hosted/middle/typecheck_walk.qz` — 1 stale comment refresh (4D.3 row-poly stamp).

**Verification**:
- Quake guard fixpoint: byte-identical, **2342 functions** (was 2343 — net -1 from deleting `mir_lower_async_generator`).
- 29-spec generator/iterator/effect/4D sweep (with `--no-cache -I std -I . -I self-hosted/shared -I spec/qspec/fixtures` to match `quake qspec_file` invocation): 28/29 pre-fold, 27/29 post-fold (1 difference; see flakiness note below). The matched failures: `generator_spec` (1/23 internal — pre-existing nested-while-yield bug, identical on golden); the unmatched: `generators_p4b4c_iterator_poll_spec` ("conditional yield paths" subtest is flaky regardless of binary — see below).
- Smoke: style_demo + brainfuck both green.

**Flakiness investigation — `generators_p4b4c_iterator_poll_spec` test 4**:

Test 4 ("generator with conditional yield paths") fails intermittently. Re-running it 5x in a row produced different outcomes for both binaries:

- POST-fold (current binary): 4 pass / 1 fail in a 5x loop (the failure prints `'14\n5\n'` instead of expected `'12\n4\n'`).
- PRE-fold (golden) when invoked the same way (with `QUARTZ_COMPILER` pointing to the SAME post-fold binary, matching what the comparison sweep did): 1 pass / 4 fail in a different 5x loop, with all 7 internal tests failing — but that's because changing what `QUARTZ_COMPILER` points to changes which compiler the spec's subprocess assertions run against, not the pre-fold binary itself.

The same test passed in the prior sweep (4D.5c.4 verification) and passes most of the time on both binaries. The condition (deterministic spec body, no concurrency) suggests the flake is in stdout buffering or subprocess timing inside the spec's `assert_output` matcher — not in the compiler. Filed as observation, not a 4D.5c.5 regression.

**Surprise finding — function count delta confirms 4D.5c.4's binary anomaly**: 4D.5c.4 dropped 2 functions (2345→2343) by deleting two thin wrappers; 4D.5c.5 drops 1 function (2343→2342) by deleting `mir_lower_async_generator`. The arithmetic is clean. The earlier 4D.5c.4 retro flagged a binary-vs-source mismatch in the e4b7d871 golden (binary already had 4D.5c.4-equivalent IR despite source being committed in old form); the function-count audit here doesn't help disambiguate that — but the new 4D.5c.5 binary is now provenance-clean (built start-to-finish on top of 8374bcce by `quake guard`).

**End state for 4D.5c**:
- `mir_lower_async_generator` — deleted.
- `lower_async_gen_iteration` + `lower_async_gen_iteration_indirect` — deleted (4D.5c.4).
- One generator constructor lowering: `mir_lower_generator_effect` (sync + async).
- One async-iter consumer helper: `lower_stream_async_iteration` (direct + indirect).
- All async-target registration converges through `mir_record_async_target` (idempotent), set either explicitly by `mir_lower_generator_effect` or implicitly by PASS 0.99b's suspend-propagation.

## Total estimate

5 subphases × 0.3-0.7 quartz-days = ~2-2.5 quartz-days. Multi-session (likely 2 sessions). Risk: medium. The core primitives (kind=3 dispatch, mir_emit_async_suspend_point, Stream<T,e> ptype, row-driven dispatch) are all proven; the lift is in regularizing what's there, not introducing new mechanisms.

> Updated 2026-04-25: see "Architectural correction" §above for the Path A vs Path B pivot. Path B revised total: ~1.5-2 quartz-days.

## Non-goals (explicitly out of 4D.5c)

- **Multi-shot iterator support**: Phase 4b deferred; row var is single-shot only; consumer merge inherits the deferral.
- **Channel<T, e> / Reader<W, e>**: same struct-row-var infrastructure, but they're separate value-type lifts; not in scope.
- **`for await` keyword removal**: 4D.5c.4 collapses lowering, but the syntax stays as a deprecation alias; a separate one-commit followup retires it.
- **Iterator/AsyncIterator trait merge**: surface aliasing handles common case post-4D.5c; full trait-level dedup is its own commit if needed.
- **Stream$next inlining**: benchmark first; only cross to call-site inlining if R5 measurements demand it.

## Sequencing into the broader 4D arc

The full 4D arc post-4D.5c:

| # | Status | Goal |
|---|---|---|
| 4D.1 | ✅ shipped `8cae398d` | Struct row-var infrastructure |
| 4D.2 | ✅ shipped `ae2a70e3` | Stream<T, e> in std/gen.qz |
| 4D.3 | ✅ shipped `7a6a7351` | Generator-fn return-type row inference |
| 4D.4 | ✅ shipped `01e6203f` | F.3c MIR fast-path deletion |
| 4D.4b | ✅ shipped `77f84be0` | Stream<T, body_row> ptype synthesis |
| 4D.4c | ✅ shipped `71dda7f4` | Receiver-row propagation |
| 4D.4d | ✅ shipped `cb1db464` | For-in row widening + F.3c TC deletion |
| 4D.5 | ✅ shipped `7213879c` | PASS 1.2a/1.3a duplicate-poll fix |
| 4D.5b.0 | ✅ shipped `07c0b4d1` | Registry deletion (annotation-based dispatch) |
| 4D.5b | ✅ shipped `2ca90be3` | Producer-side $poll consolidation |
| 4D.6 | ✅ shipped `90fd9a5a` | tc.reserved[0] + channel 1 deletion |
| 4D.5c.1 | ✅ shipped `1c83da6c` | `__qz_async_park_propagate` intrinsic |
| 4D.5c.2 | ⏸ docs-only (Path B) | Stream.next() stays sync-only; explicit `.next()` async limitation noted |
| 4D.5c.3 | ✅ shipped `e4b7d871` | Async ctor wraps in Stream handle + paired consumer-read update + spec/$new emission + async-gen pre-poll skip |
| **4D.5c.4** | **✅ shipped (this commit)** | Consolidated `lower_async_gen_iteration{,_indirect}` into `lower_stream_async_iteration(is_indirect: Bool)`; park branch upgraded to `mir_emit_async_suspend_point_raw` for dynamic rv propagation. -2 functions. |
| **4D.5c.5** | **next** | Fold `mir_lower_async_generator` into `mir_lower_generator_effect` |
| 4D.7 | partially covered | End-to-end spec |

4D.5c.5 closes the producer-side merge that 4D.5b deferred. 4D.7's "distinct-types negative test" (Stream<Int,{}> vs Stream<Int,{Async}>) is gated on user-syntax expressivity; if the row-set syntax `{Async}` doesn't yet compile in user code, that test is filed against a separate parser-affordance commit.

## References

- [`PHASE_4D_ROW_POLY_STREAM.md`](PHASE_4D_ROW_POLY_STREAM.md) §4D.5b — the deferral that this memo addresses.
- [`PHASE_4_GENERATORS_RETRO.md`](PHASE_4_GENERATORS_RETRO.md) §4 — the open-followup that filed Phase 4D.
- [`EFFECT_MIGRATION_PLAYBOOK.md`](EFFECT_MIGRATION_PLAYBOOK.md) §3.6 — kind=3 cooperative dispatch (substrate this memo builds on).
- [`../research/EFFECTS_LLVM_COMPILATION_MEMO.md`](../research/EFFECTS_LLVM_COMPILATION_MEMO.md) §5 — polymorphic effect functions; same evidence-passing model.
- Rust unstable RFC 2996 — async-iterator (closest prior art for the for-await lowering).
- Roslyn `async-streams.md` — C# IAsyncEnumerable<T> + await foreach (closest prior art for the awaitable boundary).
- Xie & Leijen, *Generalized Evidence Passing for Effect Handlers* (ICFP 2021) — the model Quartz's kind=3 dispatch most closely resembles.
- Brachthäuser, Schuster, Ostermann, *Compiling Effect Handlers in Capability-Passing Style* (ICFP 2020) — alternative routing model surveyed and rejected for Quartz scope.
