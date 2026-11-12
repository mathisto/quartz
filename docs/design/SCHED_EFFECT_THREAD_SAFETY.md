# Sched Effect — Thread-Safety via Effect-Tagged Foreign Contexts

> **Filed**: 2026-04-30. **Status**: design memo, not yet implemented.
> **Closes**: PSQ-6 (`Vec.size` cross-thread reads zero from poller pthread).
> **Effort**: ~2 quartz-days (Phase 1; Phase 2 deferred).
> **Owner**: next session. See [§ Handoff](#handoff) for the kickoff card.

## TL;DR

PSQ-6 is one instance of a general pattern: *when a function body runs in a
context different from where it was syntactically written, the data discipline
must change*. Rust uses `Send` + `Sync` auto-traits and gates them on
`std::thread::spawn` / `&'static`-lifetime arguments. Quartz can do the same
job more succinctly by reusing the existing **algebraic effect** machinery: a
new `Sched` effect marks foreign-thread callback contexts, and a Sync-bound
check fires on globals/captures inside any function with `can Sched` on its
signature.

Quartz already has:

- **Send/Sync auto-trait propagation** (`6e46491e` / B1, structural in
  `tc_type_is_send` and `tc_type_is_sync` with `g_send_checking` /
  `g_sync_checking` cycle detection).
- **Negative impl** (`impl !Send for X`, `impl !Sync for X`, C3 sprint).
- **Effect rows on functions** (`tc_attach_func_effect_row`).
- **Effect-bound enforcement at function-arg sites** (QZ1406 — exemplar:
  `Fn(...): T @pure` rejects non-`@pure` callees).
- **`tc_check_trait_bound`** with structural fallback to Send/Sync helpers.

What's missing is one new effect declaration, one annotation on a handful of
foreign-thread registration APIs, and one new check that walks any function
body with `can Sched` and validates Sync on every captured/global access.

The check is composable: every future foreign-thread API gets the same
discipline by simply declaring `can Sched` on its callback type.

---

## 1. Problem statement

### 1.1. The PSQ-6 reproducer (HEAD, `std/progress.qz:1856-1907`)

```be
var _g_live_actives: Vec<Live> = vec_new<Live>()

def _live_idle_render(): Void
  # WORKAROUND in tree: cache size in a local because reading
  # `_g_live_actives.size` inside the loop returns 0 from the I/O
  # poller pthread. Without the cache, silent wrong data.
  var sz = _g_live_actives.size
  var i = 0
  while i < sz
    var live: Live = _g_live_actives[i]
    live.tick()
    i += 1
  end
end

def _live_register(live: Live): Void
  _g_live_actives.push(live)         # plain, non-atomic global store
  if _g_live_actives.size == 1
    sched_idle_hook_set(_live_idle_render)  # registers callback on poller pthread
  end
end
```

The bug:

- Main thread does `_g_live_actives.push(live)` — plain non-atomic stores
  through a global ptr.
- I/O poller pthread (separate kernel thread, registered by
  `sched_idle_hook_set`) calls `_live_idle_render()` which reads
  `_g_live_actives.size`.
- ARM64 weakly-ordered memory model: the poller may observe stale
  `size = 0` even when main has already pushed.

The current workaround is a hard-earned convention — every cross-thread
callback in tree manually caches reads to a local. Fragile (one missed
site = silent wrong data) and opaque (no compile-time enforcement, no
diagnostic, the comment in source is the only signal).

### 1.2. The general pattern (audit findings)

Foreign-thread callback registration sites that exist in tree as of 2026-04-30:

| Site | File / line | Foreign thread | Status |
|---|---|---|---|
| `sched_idle_hook_set(fn)` | `cg_intrinsic_conc_sched.qz:506` | I/O poller pthread (slot 35 of `@__qz_sched`) | PSQ-6 sufferer |
| `extern "x86-interrupt" def *_isr` | `tools/baremetal/hello_x86.qz:192-334` (8 ISRs) | IRQ context (whatever stack was current) | Latent (single-core unikernel today) |
| `@panic_handler` | `tools/baremetal/hello_x86.qz:147` | Whatever thread panicked | Run-once, low-risk |

Implicit foreign-thread contexts (NOT in scope for this work — Phase 2):

| Site | File / line | Foreign thread |
|---|---|---|
| `go fn()` keyword | parser-level lower in `mir_lower.qz` | Worker pthread |
| `go_arena(f)`, `go_spawn(f)`, `go_cancellable(f, tok)`, `go_scope(body)`, `go_supervisor(body)`, `go_scope_timeout(ms, body)`, `go_race(tasks)` | `std/concurrency.qz:83-565` | Worker pthread |

Why Phase 1 doesn't cover goroutines:

- Every existing concurrent program in tree spawns goroutines that capture
  globals. Adding the Sync check to all `go` sites simultaneously would
  cascade through `quake build`, `std/progress`, `std/quake`, every actor
  test, etc. — large, multi-day audit before any value lands.
- Goroutines synchronize implicitly through the scheduler's task-frame
  TLS handoff (acquire barrier on each task pickup). This is not
  guaranteed for hot-loop goroutines that never yield, but it covers
  the common case well enough to be safe most of the time.
- Phase 1's foreign-thread callbacks have NO scheduler synchronization
  point, so the bug manifests deterministically on weakly-ordered
  hardware. This is the highest-impact slice.

Phase 2 is filed as a follow-on once Phase 1 ships and we have empirical
data on the Phase 1 diagnostic shape.

---

## 2. Prior art — what the field does

Per Directive 2: research what the world already knows before designing.

### 2.1. Rust — Send + Sync auto-traits + lifetime gating

Rust enforces thread safety entirely at the type level:

- `T: Send` ⟺ ownership of `T` can move across threads.
- `T: Sync` ⟺ `&T` (shared reference) can be used from multiple threads.
- Auto-trait, structural propagation: a struct is `Sync` iff every field is
  `Sync`. `Vec<T>: Sync` if `T: Sync` AND a `Vec` reference is used immutably
  (Rust enforces this through the borrow checker on `&Vec<T>` — you can't
  call `.push` on a shared reference).
- `std::thread::spawn(f)` requires `f: FnOnce() + Send + 'static`. The
  closure captures must all be `Send`, and the closure type itself must
  be `Send`.
- For shared mutable state: `Arc<Mutex<Vec<T>>>` — `Arc` is `Send + Sync`
  if `T: Send + Sync`; `Mutex<T>` is `Send + Sync` if `T: Send`.

What Quartz inherits cleanly: the structural propagation. Already done.

What Quartz does *not* have: a borrow-checker that distinguishes `&T` from
`&mut T` at function-argument boundaries for callback-passed-to-API. Rust
gets the "you can't `.push` on `&Vec<T>`" check from the borrow-checker;
Quartz needs to get equivalent enforcement from the `can Sched` annotation.

### 2.2. OCaml 5 — domain-local by default, `Atomic` for sharing

OCaml 5's multicore design defaults *all* state to domain-local (per-domain
heap). Cross-domain sharing requires explicit `Atomic.t` for primitives or
explicit handoff via `Mutex.protect`. The compiler does not enforce this at
the type level — it's a runtime convention backed by the GC's per-domain
heaps.

The lesson Quartz can adopt: making "this needs synchronization" *visible*
at the API surface. OCaml does it via `Atomic.t` types; Quartz does it via
`can Sched` on the callback type.

### 2.3. Pony — reference capabilities

Pony's `iso`/`val`/`ref`/`box`/`tag`/`trn` capability system tracks
"can this reference be sent to another actor?" at the type level. Send-only
references are `iso` or `val`; mutable shared references don't compile.

Powerful but heavy. Quartz's existing Send/Sync auto-traits are the
"Rust-compatible" subset of this. Pony-style is filed as a Tier 5 moonshot.

### 2.4. Koka — effect-typed shared state

Koka has `read<h>` and `alloc<h>` effects parameterized by a heap handle
`h`. Cross-handle access requires explicit `with` blocks. Closer to Quartz's
`Alloc` effect than to Send/Sync.

The lesson Quartz can adopt: **the `can E` annotation IS the access
discipline marker.** Koka does this at the heap-region level; Quartz can
do it at the thread-context level.

### 2.5. Go — race detector + convention

Go has no compile-time enforcement. The race detector (`go run -race`)
catches violations dynamically, with substantial runtime cost (~5-10×
slowdown). Convention dictates `sync.Mutex` for shared state.

This is what Quartz has *today*. The handoff comments in `std/progress.qz`
(lines 1859-1862, 1865-1870) are the convention. The poller-thread bug is
exactly the kind of thing Go's race detector catches. We can do better with
compile-time enforcement.

### 2.6. Synthesis

The composable answer is:

> The function annotation marks **the context the body runs in**. The check
> at each access site uses **structural Send/Sync**. The two systems compose:
> the annotation is the trigger, Send/Sync is the verifier. Both already
> exist in Quartz; Phase 1 just wires them together.

This is the Rust-style discipline expressed through Quartz's effect system
rather than Quartz's borrow checker. Cleaner because `can E` is already
how Quartz expresses "this body has constrained context" everywhere else
(Async, Throws, FileIo, …).

---

## 3. Proposed model

### 3.1. New effect: `Sched`

```be
# Built-in, declared in std/sched.qz (or std/prelude.qz). No user-facing ops.
# The presence of `can Sched` on a function signature marks it as
# "this body runs in foreign-thread context — every read of a captured
# variable, global, or argument must be Sync."
effect Sched end
```

Rationale for the name `Sched`:

- **Not `Async`.** `Async` already means "this body can suspend/await/yield."
  An idle hook's body is *synchronous* — it runs to completion on the poller
  thread before returning. Conflating these would force every `async fn` to
  carry foreign-thread discipline, which is wrong (most async code runs on a
  worker thread that synchronizes through the scheduler's task framework).
- **Not `Worker` or `Thread`.** Too generic; doesn't communicate that the
  effect is about being callback-from-the-scheduler. The user should read
  `can Sched` and think "ah, the scheduler invokes this on its own thread."
- **Not `ForeignThread`.** Verbose, and "foreign" has multiple meanings in
  systems contexts (FFI vs cross-thread).
- **`Sched`** matches the existing intrinsic prefix (`sched_idle_hook_set`,
  `sched_yield`, `sched_init`) so it's discoverable from the API.

Open question: should ISRs (`extern "x86-interrupt"`) and `@panic_handler`
also use `Sched`, or a separate `Interrupt` effect? Argument for unified
`Sched`: same Sync discipline, one diagnostic to teach. Argument for split:
ISRs run with interrupts disabled (different rule set — no allocation, no
syscalls). **Decision: unified `Sched` for now**, file a follow-on
(`Interrupt` as a sub-effect of `Sched` or a separate effect with stricter
rules) if the unikernel SMP work surfaces a need. ISRs are a small enough
audit that adding `can Sched` to the existing 8 ISR signatures is trivial
and gets us the no-allocation discipline almost for free (allocation
intrinsics will bypass the runtime's effect-handler-stack discipline, which
is a separate check we should add but not in this memo's scope).

### 3.2. Builtin annotations

`std/concurrency.qz` (or wherever `sched_idle_hook_set` is declared in
stdlib):

```be
# The callback runs on the I/O poller pthread. `can Sched` triggers
# the Sync-bound check on its body's captures and globals.
def sched_idle_hook_set(f: Fn(): Void can Sched): Void = intrinsic
def sched_idle_hook_clear(): Void = intrinsic
```

The TC builtin registration in `typecheck_builtins.qz:256` needs to
record the parameter's effect annotation so `tc_expr_call`'s arg-bound
check (already there for `@pure`) can reject callbacks that don't
declare `can Sched`.

For `extern "x86-interrupt"` ISRs:

```be
@[interrupt(13)]
extern "x86-interrupt" def general_protection_isr(frame: Int, err: Int): Void can Sched
  ...
end
```

The parser already accepts `can E` on `extern` defs (B.4 row-poly work).
For `@panic_handler`:

```be
@panic_handler
def my_panic(msg: String): Void can Sched
  ...
end
```

### 3.3. Sync check inside `can Sched` bodies

For any function whose effect row contains `Sched`, walk the body and at
each NODE_IDENT resolution that lands on a *non-parameter* binding (i.e. a
captured local, a module global, or a global var declared elsewhere),
fire `tc_type_is_sync(tc, type_id, struct_name)`. If 0, emit:

> **QZ1408**: `<name>: <type>` is read inside a function with `can Sched`
> (foreign-thread context) but is not `Sync`. Wrap in `Mutex<T>` and
> access via `.lock()`, use `Atomic<T>` for primitive slots, or move to
> per-thread state via `@thread_local`.
>
> Note: parameters and `var`s declared inside the function body are
> stack-local and exempt from this check.

The check fires at:

- NODE_IDENT references to module globals or captures
- NODE_FIELD_ACCESS where the receiver is a captured/global variable
- NODE_INDEX where the array is a captured/global variable
- NODE_CALL where the receiver of a method call (UFCS or impl) is a
  captured/global variable AND the method is not on a Sync-by-construction
  type (Mutex, RwLock, Channel, Atomic*, primitives)

Method calls on Sync wrappers (e.g. `mutex.lock()`, `atomic.load()`) are
the **escape hatch** — calling those returns the inner value, which is
fresh stack-local and can be used freely inside the body.

### 3.4. Composition properties

- **Effect-row propagation.** A helper `def fmt_live(l: Live)` called from
  inside a `can Sched` function must itself declare `can Sched` (or use
  a row-var) — same row check that fires for `can Throws`. The helper is
  then walked under the Sync rule too.
- **Send/Sync structural recursion.** Already handles "Vec of struct of
  Vec" — if any nested field is `!Sync`, the whole struct is `!Sync`.
  The new code is one new trigger, not new propagation.
- **Mutex<T> escape hatch.** `Mutex<T>: Sync` if `T: Send` (already in
  `tc_type_is_sync`). User wraps `var _g_live_actives: Mutex<Vec<Live>>`;
  inside `can Sched` body, `lock()` returns the inner `Vec<Live>` (a
  fresh local), which is exempt from the rule.
- **TLS escape hatch.** `@thread_local var x: Vec<T>` — TLS storage,
  per-thread data is by definition not shared, so the check passes
  unconditionally for `@thread_local` bindings.
- **Future foreign-thread APIs.** Adding a new `signal_handler_set(f)`,
  `timer_callback_set(ms, f)`, etc. only requires declaring the parameter
  as `Fn(...): T can Sched` — discipline cascades automatically.

---

## 4. What's `Sync` / `!Sync` in stdlib

Existing `tc_type_is_sync` (`typecheck_registry.qz:3418`) classifies:

**Sync (safe to share):**

- Primitives: `Int`, `Bool`, `String` (immutable), `F64`, `F32`, `Symbol`,
  `Void`, sized-width integer aliases (I8/I16/I32/U8/U16/U32), `Range`
- Concurrency types: `Atomic<T>`, `Mutex<T>`, `Channel<T>`
- Functions (`Fn`): immutable function pointers
- `Option<T>`, `Result<T, E>`: existential — assumed Sync (the TODO line
  in source is "wrapped type Sync — assume yes")
- Structs: walked structurally; Sync iff every field is Sync

**`!Sync` (NOT safe to share):**

- `Vec<T>`, `Map<K, V>`, `Set<T>`, `StringBuilder`: mutable containers,
  not thread-safe
- `CPtr`, `Ptr`: raw pointers with unknown semantics

**Note on String.** `String` is `Sync` because Quartz strings are
immutable (no `String.append_in_place`). However, `StringBuilder` is
`!Sync` — that's the right cut.

**Things to add or audit during implementation:**

- `RwLock<T>`: should be Sync if T: Send. Probably already in tree under
  `tc_type_is_sync` — audit during implementation.
- `Slice<T>` (Tier 4 #24): should be Sync iff `T: Sync`, since Slice is
  a view (no exclusive ownership).
- `Atomic*` family (`AtomicInt`, `AtomicPtr`, etc.): all Sync.
- `@thread_local` bindings: not a type-level concern (any `T` can be
  TLS), so the Sync check should be **skipped** when the binding is
  marked `@thread_local`. Lookup via the existing scope tracker.

**Open question:** should `Option<Vec<T>>` be `!Sync` (because `Vec<T>`
inside is `!Sync`)? Currently `tc_type_is_sync` returns 1 for any
`TYPE_OPTION` regardless of inner type ("existential model — assume yes").
This is permissive. For PSQ-6 the practical impact is nil (no test case
captures `Option<Vec<T>>` in a `can Sched` body), but it's a latent hole.
**Decision:** fix during Phase 1 implementation — make `Option<T>` and
`Result<T, E>` walk their inner type(s) like struct fields. ~10 LOC, no
regression risk.

---

## 5. Diagnostic design

### 5.1. Code allocation

QZ14xx is the effect/concurrency range. In use: QZ1401-1407, QZ1410-1412.
Free: QZ1408, QZ1409, QZ1413+.

- **QZ1408**: Sync violation in `can Sched` context (Phase 1).
- **QZ1409**: Reserved for Phase 2 — Send violation across goroutine spawn.

### 5.2. Message text

Primary error:

```
error[QZ1408]: cannot read `_g_live_actives` from `can Sched` context
   ┌─ std/progress.qz:1862:12
   │
1862 │   var sz = _g_live_actives.size
   │            ^^^^^^^^^^^^^^^^ this read happens on the I/O poller pthread
   │
note: `_g_live_actives: Vec<Live>` is not Sync
   ┌─ std/progress.qz:1856:5
   │
1856 │ var _g_live_actives: Vec<Live> = vec_new<Live>()
   │     ^^^^^^^^^^^^^^^^ defined here; `Vec<T>` is `!Sync`
   │
note: `Vec<T>` is `!Sync` because mutation (push/pop/index assignment)
      is not thread-safe. Reading from a foreign-thread context can
      observe torn or stale data on weakly-ordered hardware (e.g. ARM64).
   │
help: pick one of these:
   │
   │  (1) wrap the global in `Mutex<T>` and acquire the lock:
   │      var _g_live_actives: Mutex<Vec<Live>> = mutex_new(vec_new<Live>())
   │      ...
   │      var sz = _g_live_actives.lock().size
   │
   │  (2) use a thread-safe primitive type:
   │      var _g_live_actives: Atomic<Int> = atomic_new(0)
   │
   │  (3) move to per-thread storage if no cross-thread sharing is needed:
   │      @thread_local var _g_live_actives: Vec<Live> = vec_new<Live>()
   │
help: this function runs on a foreign thread because it was passed to:
   ┌─ std/progress.qz:1880:5
   │
1880 │     sched_idle_hook_set(_live_idle_render)
   │     ^^^^^^^^^^^^^^^^^^^^ registers callback on I/O poller pthread
```

Three notes / hints make this readable. The "registers callback on" hint
is generated from the registration site that passed the callback (we
need to track the registration site during typecheck — see
implementation note in §6).

### 5.3. `--explain QZ1408` body

Goes in `self-hosted/error/explain.qz` next to QZ1407. Same shape as
the other `--explain` entries: example, fix, rationale.

---

## 6. Implementation phases

### Phase A — Design memo (this document) ✅

**Done in this doc**: model decision, effect name, diagnostic shape,
audit findings, dogfood plan. ~0.3 quartz-day spent.

### Phase B — Builtin annotations

- File: `self-hosted/middle/typecheck_builtins.qz`
- Extend `tc_register_builtin_with_arity` calls for `sched_idle_hook_set` /
  `sched_idle_hook_clear` to record the callback parameter's effect row
  (`Sched`) somewhere TC can read at call sites. This is parallel to how
  `@pure` is read via `ast_func_get_effect_annotation` (an Int sentinel).
- For `Sched`, we need a parser-level mechanism to attach `can Sched` to
  builtin signatures. Two options:
  - **B.1 (lighter):** add `tc_register_builtin_with_callback_effect(name, ret, "Sched")`
    and check that string at the call-site in `tc_expr_call`. ~30 LOC.
  - **B.2 (heavier):** parse builtins from a stdlib `.qz` file with full
    type signatures including effect rows. Larger refactor. **Don't do
    in this memo's scope.**
- File `self-hosted/middle/typecheck_concurrency.qz` (or a new `typecheck_sync.qz`)
  for the helper `tc_check_sched_callback_arg`. Mirrors `QZ1406`'s
  shape at lines 3245-3280 of `typecheck_expr_handlers.qz`.
- Effort: ~0.3 quartz-day.

### Phase C — Sync-bound check inside `can Sched` bodies

This is the load-bearing piece.

- **C.1** (new helper, ~50 LOC): `tc_func_has_sched_effect(tc, func_idx)`
  reads the function's effect row (already in registry via
  `tc_set_func_effect_row`) and returns 1 if `Sched` is in the row's
  label set, else 0.

- **C.2** (typecheck walk extension, ~80 LOC): in `tc_function`
  (`typecheck_walk.qz:4149`), set a TLS / state flag
  `tc.in_sched_context: Bool` before walking the body. Restore on exit.
  Helpers called from within the body that themselves don't declare
  `can Sched` will fail the existing row check at QZ140x range — but
  importantly, the row check fires at the call site *of the helper*,
  NOT inside the helper's own body, so the user only needs annotation
  on the entry function.

- **C.3** (NODE_IDENT check, ~60 LOC): in `tc_expr` (`typecheck_walk.qz:944`)
  at the NODE_IDENT branch (line 983-onwards), AFTER scope lookup
  resolves the binding, if `tc.in_sched_context == 1` AND the binding
  is a global (or capture from outer scope), AND the binding is not
  marked `@thread_local`, AND `tc_type_is_sync(tc, result, struct_name) == 0`,
  then `error("QZ1408: ...")`.

- **C.4** (NODE_FIELD_ACCESS / NODE_INDEX / method calls, ~40 LOC):
  similar checks at the receiver-resolution sites. The receiver type
  IS the relevant Sync property — calling `.size` on a `Vec<T>` global
  is a `!Sync` read, but calling `.size` on a `Mutex<Vec<T>>.lock()` is
  fine because the receiver is a fresh local.

- **C.5** (`Option<T>` / `Result<T, E>` recursion fix, ~10 LOC): make
  these structurally walk inner types in `tc_type_is_sync`.

- **C.6** (`@thread_local` opt-out, ~30 LOC): parser already has
  `@[thread_local]` (used for `__qz_effect_stack_top` etc. — it lowers
  to LLVM's `thread_local` global modifier). Extend the user-facing
  attribute to user-declared globals, and have the Sync check skip
  bindings marked TLS.

- Effort: ~0.7 quartz-day.

### Phase D — Tests + dogfood

- New regression spec at `spec/qspec/sched_sync_spec.qz` (~6 tests):
  - **D.1** Positive: `Mutex<Vec<Live>>` global, `lock()` inside
    `can Sched` body — compiles + runs cleanly.
  - **D.2** Positive: `Atomic<Int>` global, `atomic_load` inside
    `can Sched` body — compiles + runs cleanly.
  - **D.3** Positive: `@thread_local var x: Vec<T>` — compiles cleanly.
  - **D.4** Negative: bare `Vec<T>` global read inside `can Sched` —
    QZ1408 fires with the expected message text.
  - **D.5** Negative: nested helper called from `can Sched` body without
    `can Sched` annotation — QZ140x row-check fires (existing behavior;
    confirms cascade works).
  - **D.6** Edge: read-only String literal global (immutable, Sync) —
    no diagnostic.
  - **D.7** Edge (Phase 1 acceptance): `_live_idle_render` rewritten
    to use `Mutex<Vec<Live>>` builds clean; the workaround comment in
    the existing source can be deleted.

- **Dogfood site:** `std/progress.qz:1856-1907` rewritten to use
  `Mutex<Vec<Live>>` (or whatever the right shape is — possibly
  `RwLock<Vec<Live>>` since reads dominate). Removes the cached-size
  workaround. This is the headline win that closes PSQ-6 visibly.

- Effort: ~0.5 quartz-day.

### Phase E — Close-out

- Move `docs/bugs/PROGRESS_SPRINT_QUIRKS.md` to `done/` (only PSQ-6 is
  open; once it lands, the whole file moves).
- File `~/.claude/projects/.../memory/feedback_can_sched_thread_safety.md`
  capturing the lesson.
- Update ROADMAP: PSQ-6 closed in Tier 2 / open-bugs section.
- Audit and annotate remaining foreign-thread sites:
  - 8 `extern "x86-interrupt"` ISRs in `tools/baremetal/hello_x86.qz`
    get `can Sched` annotation. (No global state in current ISRs;
    they're effectively pure modulo the panic-style log writes which
    target a TLS-style scratch — confirm during implementation.)
  - `@panic_handler` annotation inside `tools/baremetal/hello_x86.qz`
    gets `can Sched`. Same audit caveat.

- Effort: ~0.2 quartz-day.

**Total: ~2 quartz-days**, multi-session OK per Directive 4.

---

## 7. Audit — sites that benefit immediately

After Phase 1 lands:

| Site | Action | Win |
|---|---|---|
| `std/progress.qz:_live_idle_render` | Rewrite with `Mutex<Vec<Live>>` | PSQ-6 closes; workaround comment deleted |
| `std/progress.qz:_live_register` / `_unregister` | Rewrite mutators to acquire the same lock | Symmetric, mandatory for correctness |
| 8 `extern "x86-interrupt"` ISRs | Add `can Sched` annotation | Future-proofs against accidental global mutation when KERN.8 SMP ships |
| `@panic_handler` | Add `can Sched` annotation | Same |
| `sched_idle_hook_set` builtin signature | Mark callback param as `can Sched` | All future callers get checked |

After Phase 2 (deferred, follow-on session) lands:

| Site | Action | Win |
|---|---|---|
| `go fn()` / `go_arena(f)` / etc. | Mark callbacks as `can Sched` (or a different effect, e.g. `Worker` if scheduler synchronization is enough) | Audit all goroutine bodies; cascade Sync discipline |
| Future signal handler API | New `signal_handler_set(f: Fn(): Void can Sched)` | Trivially correct by construction |
| Future timer callback API | New `timer_set(ms: Int, f: Fn(): Void can Sched)` | Same |
| Future M:N worker hooks (KERN.8) | All hook params declared `can Sched` | Same |
| Future FFI C callback registration | Same | Same |

---

## 8. Future extensions

### 8.1. Phase 2 — Goroutine Send check (A.5c — SHIPPED 2026-05-02)

The original framing pictured a `Worker` effect annotation cascade
across ~50+ goroutine sites. Pre-flight survey for A.5c found the
substrate already richer than the memo's author realized: `tc_type_is_send`
exists at `typecheck_registry.qz:3211` (full structural impl, sister
to `tc_type_is_sync`); `tc_check_spawn_safety` already fires QZ1301
on lambda captures; `tc_error_go_closure` already fires QZ1302 on
closure-variable callees. The Worker effect was unnecessary — the
checks fire **structurally** at NODE_GO, no annotation propagation
needed.

What A.5c actually shipped:

1. **Phase 1 — capture walker NODE_LET slot bug fix** (`typecheck_capture.qz:126`).
   The walker read NODE_LET's init handle from `ast_get_right`, but
   `ast_let` (`ast.qz:1337`) stores it in `lefts`. Pre-fix, QZ1301
   silently passed for `var q = captured_thing` — the most common
   capture shape. Post-fix, all bound captures get checked.

2. **Phase 2 — QZ1409 direct-arg Send check** (`typecheck_concurrency.qz`
   `tc_check_go_args_send`). For `go fn(args)` with a named top-level
   callee, walks each identifier-typed arg and checks `tc_type_is_send`.
   Arg expressions whose result crosses the worker boundary at spawn
   are now type-checked.

3. **Phase 3 follow-up — globals Sync check inside goroutine body**
   (NOT shipped under A.5c — different axis). When a `go (-> body)()`
   body reads a non-Sync global, today only QZ1301 fires (and only on
   captures that reach the global through a closure). A goroutine body
   accessing a global at depth 0 directly should fire QZ1408 like the
   `can Sched` body-walk does. Possible mechanism: set
   `tc.in_sched_min_depth = 1` at goroutine-lambda body walk so only
   depth-0 (global) reads trigger the Sync check, captures already
   covered by QZ1301. Estimated ~20 LOC; tracked here for a future
   sprint, not blocking A.5c.

Test suite: `spec/qspec/goroutine_send_spec.qz` (8 tests covering
QZ1409 / QZ1301 / QZ1302 cohesion).

### 8.2. Phase 3 — `@thread_local` user-facing attribute (small)

Currently `@[thread_local]` is parser-recognized but compiler-internal
(used for `__qz_effect_stack_top` etc.). Phase 1 promotes it to a
user-facing attribute on global `var` declarations. ~30 LOC parser +
codegen, gated on Phase 1's diagnostic firing.

### 8.3. Moonshot — effect-handler-as-cross-thread-bridge (Tier 5)

Instead of just using `Sched` as a context marker, define ops on it:

```be
effect Sched
  def read<T>(slot: SharedSlot<T>): T
  def write<T>(slot: SharedSlot<T>, value: T): Void
end
```

Then every shared-state access from a `can Sched` body becomes a
`perform Sched.read(slot)` → handler runs the lock acquisition →
returns a fresh local. The handler IS the synchronization mechanism,
pluggable per `with` block (Mutex strategy, RCU strategy, snapshot
strategy, ...).

Pros: most expressive, fully composable concurrency strategies.
Cons: every shared read becomes a `perform` (verbose), and the
typechecker would need to disallow direct globals access entirely
from `can Sched` bodies (which is the current proposal anyway,
just with `lock()` as the escape hatch instead of perform).

File at Tier 5 alongside refinement types and GPU compute — a
research-language feature. Don't build until a real use case
demands the pluggability (e.g. a workload that wants to swap
Mutex for RCU based on read/write ratio at runtime).

---

## 9. Open questions

1. **Should `Option<T>` / `Result<T, E>` recursively check inner type
   for Sync?** Current code returns 1 unconditionally. **Decision: yes,
   fix in Phase C.5.** ~10 LOC, no regression risk (nothing in tree
   currently relies on `Option<Vec<T>>` being Sync — empirically unused
   shape).

2. **Should `Sched` and ISR contexts share an effect, or split?**
   ISRs have stricter rules (no allocation, no syscalls, no panics).
   **Decision: unified `Sched` for now**, file `Interrupt` as a
   sub-effect for KERN.8 SMP work. Adding `can Sched` to existing 8
   ISR signatures is trivial today; sharpening to `can Interrupt`
   later is purely additive.

3. **Should goroutines (`go fn()`) be Phase 1 or Phase 2?**
   **Decision: Phase 2.** Phase 1 covers the deterministic-failure
   case (PSQ-6); Phase 2 needs broader audit and gets a separate
   sprint. The `Sched` effect's name is reserved for foreign-thread
   callbacks; goroutines get `Worker` (or `Async`-extended) in
   Phase 2.

4. **Method calls on `&Mutex<T>`:** `mutex.lock()` returns a fresh
   local — can users be relied upon to not hold the locked value
   across yields/awaits inside a `can Sched` body? **Initial answer:
   yes, by convention.** A future hardening could borrow-check the
   `lock()` return as a non-`Send` `MutexGuard<T>` (Rust style), but
   that's a Tier 5 feature. For now, the diagnostic + the established
   "release the lock before yielding" stdlib pattern are sufficient.

5. **What about `@thread_local` on ISR-only data?** Linux/x86 user-space
   `thread_local` requires a TLS register (FS/GS), which freestanding
   kernels initialize manually. SYS.1 already shipped FS/GS / TPIDR
   support. **Decision: works as-is** — `@thread_local` user-facing
   attribute lowers to LLVM `thread_local`, freestanding programs
   that initialize the TLS register correctly use it transparently.

---

## 10. Handoff

### 10.1. What lands first

The next session picks up Phase B. Concretely:

1. Read this memo top-to-bottom.
2. **Phase B (≈0.3d)**:
   - Add `Sched` effect declaration to `std/sched.qz` (new file or
     `std/concurrency.qz`).
   - Modify `typecheck_builtins.qz:256-257` registration of
     `sched_idle_hook_set` / `sched_idle_hook_clear` to record the
     callback parameter's effect row.
   - Add helper `tc_check_sched_callback_arg(tc, func_name, arg, ...)`
     mirroring the QZ1406 shape at
     `typecheck_expr_handlers.qz:3245-3280`. Diagnostic stub —
     returning the right error happens in C.3.
   - Verify with a tiny repro: `def f(): Void = puts("foo")` (no
     `can Sched`) passed to `sched_idle_hook_set` — expect a new
     QZ1408 candidate diagnostic at the call site.
3. **Phase C (≈0.7d)**:
   - Implement C.1 (`tc_func_has_sched_effect`).
   - Implement C.2 (TLS flag in `tc_function`).
   - Implement C.3 (NODE_IDENT site check, the load-bearing piece).
   - Implement C.4 (field/index/method-call site checks).
   - Implement C.5 (Option/Result inner-type recursion in
     `tc_type_is_sync`).
   - Implement C.6 (`@thread_local` opt-out).
4. **Phase D (≈0.5d)**:
   - Author 7 tests in `spec/qspec/sched_sync_spec.qz`.
   - Rewrite `std/progress.qz:1856-1907` to use `Mutex<Vec<Live>>` (or
     `RwLock` if we add one — quick check during implementation).
     Delete the cached-size workaround.
   - Verify PSQ-6 reproducer: poller-thread reads `_g_live_actives.size`
     correctly without the workaround.
5. **Phase E (≈0.2d)**:
   - Annotate the 8 ISRs and `@panic_handler` with `can Sched`.
   - Move `PROGRESS_SPRINT_QUIRKS.md` to `done/` (PSQ-6 was the only
     open item).
   - File `feedback_can_sched_thread_safety.md`.
   - Update ROADMAP: this work closes PSQ-6 in Tier 2; mention as
     "Effects-as-thread-context type discipline shipped" in Apr 2026
     activity log.

### 10.2. What stays open

- **Phase 2** (goroutine Send check, QZ1409): file as new Tier 2 row
  after Phase 1 ships, gated on real-user signal that hot-loop
  goroutines are surfacing PSQ-6-shaped silent-wrong-data. ~3-5
  quartz-days estimated.
- **Phase 3** (`@thread_local` user-facing): only build if Phase 1's
  D.3 test surfaces a real need beyond the existing compiler-internal
  use.
- **Tier 5 moonshot** (handler-as-cross-thread-bridge): file in
  ROADMAP Tier 5; build only when a real workload needs pluggable
  concurrency strategies.

### 10.3. Verification at end-of-Phase-1

`quake guard` clean, fixpoint byte-identical. New 7-test spec passes.
PSQ-6 deterministically closes — test that demonstrates the bug
reproducer (poller thread reading uncached `.size` from main-thread
mutated `Vec`) now requires a `Mutex<Vec<T>>` in the source and
compiles cleanly with `lock()` access; bare `Vec<T>` global read
inside `can Sched` body fires QZ1408 with the message text in §5.2.

Smoke regression: `std/progress` Live UI from `quake build`'s
8-phase compile bar still animates correctly post-rewrite. (Live
under TTY mode — don't lose the FPS.)

### 10.4. Risk register

- **Effect-row plumbing for builtins.** `tc_register_builtin_with_arity`
  doesn't currently take a callback effect string. The Phase B add is
  small (~30 LOC) but touches the builtin registration shape used
  everywhere — be deliberate.
- **`Option<T>` / `Result<T, E>` Sync recursion** could surface latent
  bugs elsewhere in tree (existing code that relied on the permissive
  "always Sync" behavior). Run full qspec post-C.5 and flag anything
  that newly fails QZ1408 — likely they're real bugs, not regressions,
  but worth flagging for review.
- **Diagnostic message rendering.** The proposed message in §5.2 has 3
  notes + 2 hints. Quartz's diagnostic renderer may not currently
  support that depth — check during Phase D, fall back to a simpler
  shape if the renderer chokes.
- **Capture detection.** The "is this binding a capture vs a
  parameter vs a stack-local" check needs to walk the scope hierarchy.
  Quartz's resolver already tracks scope (`_ufcs_current_params`) but
  doesn't expose a "this name is from outer scope, not this scope"
  predicate. Phase C.3 may need to add one — small, but a discovery,
  not a known piece of work.

---

## 11. Reference

- PSQ-6 in `docs/bugs/PROGRESS_SPRINT_QUIRKS.md` — current status
- `self-hosted/middle/typecheck_registry.qz:3211-3600` — Send/Sync
  structural helpers
- `self-hosted/middle/typecheck_expr_handlers.qz:3245-3280` — QZ1406
  exemplar
- `self-hosted/middle/typecheck.qz:4602` — `tc_attach_func_effect_row`
- `std/progress.qz:1856-1907` — PSQ-6 reproducer + workaround
- `feedback_quartz_module_quirks.md` (project memory) — quirk #6
  catalogues the workaround pattern
- Rust: [Send & Sync — Rustonomicon](https://doc.rust-lang.org/nomicon/send-and-sync.html)
- OCaml 5: [Multicore OCaml manual — domains, atomics, mutex](https://v2.ocaml.org/manual/parallelism.html)
- Pony: [Pony reference capabilities](https://tutorial.ponylang.io/reference-capabilities/)
- Koka: [Koka effect handlers reference](https://koka-lang.github.io/koka/doc/book.html#sec-handlers)
