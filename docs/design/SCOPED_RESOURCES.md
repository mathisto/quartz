# Scoped Resources (B.8) — design memo

**Status**: Phase 1 design. Phases 2-7 staged below.
**Filed**: 2026-05-08.
**Pairs with**: B.7 (Scope unification), B.9 (Throws / Panic unification), Drop trait (`std/memory.qz`).
**Roadmap link**: `docs/ROADMAP.md` row B.8.

---

## Problem

Quartz today has three independently-designed mechanisms for "release on scope exit":

1. **`trait Drop`** (`std/memory.qz`) — auto-emitted by the compiler at NODE_BLOCK / function exit. LIFO, type-recursive, zero ceremony at the call site. **Does not run on throw unwind.** Used by `Arena`. Signature is fixed: `def drop(self): Void`.
2. **Scope helpers** (`scope_with`, `scope_with_cancel`, etc., `std/sync/scope.qz`) — function-level RAII via closures. Throw-safe (via `with Throws { throw: ... } do ...`). Today's canonical pattern for cancellation-aware regions, including from B.7.
3. **Manual `acquire/release` pairs** (`mutex_lock` / `mutex_unlock` in `std/progress.qz`, `std/sync/scope.qz`; `file_open` / `close_file` in `std/io/file.qz`; `tcp_close`, `tls_close`, …) — the dominant pattern in the rest of stdlib. **Not throw-safe.** A throw between `mutex_lock` and `mutex_unlock` permanently leaks the lock.

The split exists for historical reasons. `Drop`'s `drop(self): Void` can't express *parameterized* release — `mutex_unlock(m, new_value)` writes the protected value back, which `drop` has no slot for. Closures (`scope_with(s, body)`) handle parameterized release fine but inflict the indentation tax of an explicit lambda. Manual pairs avoid both but break in the presence of any `throw`, `panic`, or non-local exit.

After B.7 we have first-class throw-safe scope cancellation, and after Phase 4e.8 we have active wakes that fire on cancel. The cost of *not* unifying scoped resources is now load-bearing: every new stdlib type duplicates manual `acquire/release` patterns, and every consumer of those types is responsible for hand-rolling try/finally equivalents that Quartz doesn't actually have.

---

## Goal

One syntactic pattern — extending the existing `with` block — for "this resource is alive inside this block, released on exit (normal OR via thrown exception)":

```be
# Mutex with bound guard (the protected value comes back via the binding).
with mutex.lock do v ->
  process(v)
end
# implicit: mutex_unlock(mutex, ...) runs on normal exit AND on throw.

# File with bound handle.
with file.open(path, "r") do f ->
  return f.read_all()
end
# implicit: f.close() on exit.

# Scope with timeout — this is the canonical B.7 pattern, repackaged.
with scope.timeout(5_seconds) do s ->
  do_work_on(s)
end
# implicit: scope_cancel(s) on exit.

# Channel with bounded buffer that closes on scope exit.
with channel.scope(buffer: 32) do ch ->
  go producer(ch)
  consume_until_closed(ch)
end
# implicit: channel_close(ch) on exit.

# Resources without a useful bound value can elide the binding.
with mutex.lock_void do ->
  shared_counter += 1
end
```

Result: `try { lock; ...; finally unlock }` patterns vanish from user and stdlib code. Lock-leak bugs get harder to write than to avoid.

---

## Prior-art compass

A full per-language survey lives in the research notes for this memo. Condensed:

| System | Mechanism | Throw-safe | Bound value | Parameterized release | Retrofit-able |
|---|---|---|---|---|---|
| C++ RAII | destructor | yes | no (object IS the resource) | no | no (must own type) |
| Rust `Drop` | trait | yes (panic unwind) | no | no | no (orphan rule) |
| Python `with` | `__enter__` / `__exit__` | yes (exc info passed) | yes (`as x:`) | n/a (object is mutated) | no |
| Java try-with-resources | `AutoCloseable` | yes (suppressed-exc chain) | yes | no (`close()` only) | no |
| C# `using` | `IDisposable` | yes | yes | no | no |
| Common Lisp `WITH-*` | macro over `UNWIND-PROTECT` | yes | yes | yes (any cleanup forms) | yes (user macros) |
| Haskell `bracket` | function | yes (`mask`) | yes | yes | yes |
| Scala `Using.resource` | `Releasable` typeclass | yes (suppressed-exc) | yes | no | **yes** (typeclass, retroactive impl) |
| Go `defer` | runtime stack | yes (panic) | no (invisible) | yes | yes |
| Swift `defer` | runtime stack (block) | yes | no | yes | yes |
| Zig `defer` / `errdefer` | compile-time stack | n/a (error union) | no | yes | yes |
| Koka `with` | effect handler | yes (effect unifies exc) | yes | yes | yes (handler scope) |

Key takeaways:
- **Block syntax beats function syntax.** Python/Java/C#/Koka/Common Lisp converged on a block construct. Scala/Haskell stayed function-level and routinely complain about indentation. Quartz already has `with ... do ... end` — extending it is the right call.
- **Trait-based dispatch (typeclass) beats inheritance.** Scala's `Releasable[A]` typeclass lets you retrofit a third-party type. Java's `AutoCloseable` does not. Quartz traits are typeclass-shaped — define `Scoped` so `impl Scoped for File` lives wherever convenient.
- **Java's suppressed-exception chaining** is the right answer for the double-throw case (body throws + release throws). C# explicitly didn't do this and regrets it.
- **Zig's `errdefer`** captures a real distinction: "release on throw, transfer-ownership on success." Builder patterns need it. Don't conflate with `defer`.
- **Koka's unification** (one `with` for handlers, resources, exceptions, async) is the design north star. Quartz's `with` is already a handler installer; extending it to dispatch on `Scoped` lands at the same destination via a much smaller change.

---

## Design

### The trait

```be
## Scoped resources released on block exit (normal AND via throw).
##
## `with x do r -> body end` desugars to:
##   r = x.acquire()
##   with Throws { throw: |exc| -> x.release_on_throw(r, exc); rethrow exc end } do ->
##     body
##     x.release(r)   # only on normal exit
##   end
trait Scoped<R>
  ## Acquire the resource. Returns the bound value visible inside the block.
  def acquire(self): R

  ## Release on normal exit. Receives the (possibly mutated) bound value.
  def release(self, value: R): Void

  ## Release on exceptional exit. Default = release. Override for
  ## errdefer-style commit-on-success semantics.
  def release_on_throw(self, value: R, exc_msg: String): Void = self.release(value)
end
```

`R` is the type of the bound value. For mutex it's the protected `Int` (or generic `T` once mutex generic-erasure is cleaned up). For file it's the `FileHandle`. For channel it's the channel handle. For scope it's the `Scope` handle.

When the bound value is meaningless (e.g. a counter-style mutex where nothing is read out), the impl returns 0 and the caller writes `do -> ... end` (existing form).

### Parser extension

Today's `ps_parse_handler_block` (parser.qz:5078) only accepts:

```be
with H do body end
with H do -> body end
with H1, H2 do -> body end       # comma-list sugar
```

Extend to accept a single bound parameter:

```be
with H do x -> body end
with H do x: T -> body end       # optional type annotation
```

The trailing-block lambda parser (parser.qz:2700-2720) already handles `do x -> ...`. Lift the same inline `block_params` collection into `ps_parse_handler_block`, between `TOK_DO` and the body-statement loop. Comma-list multi-handler `with H1, H2 do x ->` is rejected (ambiguous: which handler binds `x`?); users write nested `with`s.

The bound parameter rides through to typecheck via a new `ast_with_bound` constructor that adds a single `Int` slot for the bound-param AST node (or -1 if no binding). Existing NODE_WITH consumers ignore the new slot.

### Typecheck dispatch

Today's `tc_with_handler_begin` (typecheck_walk.qz:734) recognizes PascalCase IDENT/STRUCT_INIT/CALL as effect claims. Add a fourth case **before** the PascalCase check:

If the handler expression typechecks as a value with type `T`, and `T` has a registered `impl Scoped for T`:
1. Look up `Scoped::acquire(T)`'s return type `R`.
2. If the user wrote `do r ->`, bind `r: R` in the body's scope.
3. If the user wrote `do ->` (no binding), allow but don't introduce a name.
4. Mark this NODE_WITH as a "scoped resource install" via a new `tc_with_kind` slot (effect / scoped / unknown).
5. Skip the PascalCase / effect-decl path.

Type-error path: if the handler is lowercase but doesn't impl `Scoped`, emit QZ0614 ("'X' is not a Scoped resource and not an effect handler — `with` requires one or the other") with the same hint pattern as QZ0613.

### MIR lowering

Today's NODE_WITH lowering (mir_lower.qz:2982) emits `MIR_HANDLE_INSTALL ... body ... MIR_HANDLE_UNINSTALL`. The Scoped variant emits a different sequence:

```
%r = call Scoped::acquire(%self)             ; bind to user's `r` if named
                                              ; install Throws-with-release handler
push throws-frame {
  throw: |exc| -> {
    call Scoped::release_on_throw(%self, %r, exc)
    re-throw exc                              ; chains as suppressed if release threw
  }
}
... body ...                                  ; whatever NODE_BLOCK lowers to
pop throws-frame
call Scoped::release(%self, %r)               ; only reached on normal exit
```

The `re-throw exc` is the existing `__qz_effect_perform` machinery (panic-as-throws Phase 2 already lands a Throws.throw via `cg_intrinsic_system`). The chain-as-suppressed semantic is currently absent; depending on Phase 4 estimate, ship initial release as "release-throw masks body-throw" with a TODO toward Java-suppressed-chain.

Drop and Scoped coexist cleanly: if the bound value `r` itself implements Drop, the existing droppable-stack machinery still emits `Type$drop` for `r` at the end of body. Scoped's release runs *outside* that — it's the resource container's cleanup, not the bound value's. (For `with mutex.lock do v -> ... end`, `mutex.release(v)` runs after the body's drop walk finishes.)

### The Throws / Drop interaction (B.9 follow-on)

The current `panic_as_throws` Phase 2 ships throws via `__qz_effect_perform` + `unreachable`. **Drop does not run on the unreachable path** — the LIFO drop stack is walked at NODE_RETURN, never on throw. Scoped's throw-safety relies on its own throws-frame handler running release_on_throw before re-throw, so this *works* for Scoped resources without fixing Drop.

Filing the Drop-on-throw gap as a separate follow-up: B.9 Phase 3+ unifies panic_caught into with-Throws, and at that point the throws-frame teardown should walk the drop stack. **This memo does not block on that fix.**

### Stdlib impls

Phase 5 ships `impl Scoped` for the following stdlib types. The list comes from the audit:

| Type | acquire | release | Bound value | Notes |
|---|---|---|---|---|
| `Mutex<T>` | `mutex_lock(m)` | `mutex_unlock(m, v)` | `T` | Closes 13 manual sites in `std/progress.qz`. |
| `RwLock<T>` | `rwlock_write(rw)` / `_read(rw)` | `rwlock_*_unlock(rw, v)` | `T` | Two impls — `WriteGuard`, `ReadGuard` — distinguished by method on `RwLock`. |
| `FileHandle` | `file_open(path, mode)` | `close_file(h)` | `FileHandle` | `std/io/file.qz` — closes the manual `if h != 0; close_file(h); end` pattern. |
| `Channel<T>` | factory returning open channel | `channel_close(ch)` | channel handle | Convenience for "channel scoped to this block." |
| `Scope` | factory (`scope_timeout(parent, ms)`) | `scope_cancel(s)` | scope handle | Replaces hand-written `scope_with(scope_with_cancel(...), body)` pattern for the common case. |
| `TcpStream` / `TcpListener` | `tcp_connect` / `tcp_listen` | `tcp_close` / `tcp_close_listener` | stream/listener handle | Closes manual close-on-exit code in `std/net/http.qz`, `examples/`. |
| `TlsStream` | tls_connect / tls_accept | `tls_close` | stream handle | Same shape. |
| `UdpSocket` | `udp_bind` / `udp_connect` | `udp_close` | socket handle | Same shape. |
| `EventLoop` | constructor | `event_loop_close` | loop handle | Same shape. |
| `Arena` | constructor | (already Drop) | — | Already covered by Drop; do NOT add Scoped impl. Drop handles ownership-tracked release; Scoped is for non-owned block leases. |

Naming convention: where the existing constructor returns a handle directly (`mutex_new`, `tcp_connect`), wrap in a new factory or method that returns an `impl Scoped` value. For example: `mutex.lock` is a method on `Mutex<T>` returning a one-shot `MutexLockGuard<T>` whose `Scoped::acquire` actually grabs the lock. This separates "create a mutex" (`mutex_new`) from "this is a lock acquisition" (`mutex.lock`).

The guard objects are always tiny structs (one field — the underlying handle). Codegen erases them to `Int` per existential-types policy.

### Decision tree (for users)

```
Need a resource alive only inside a block?
├─ Yes → with mutex.lock do v -> ... end          # Scoped trait
└─ No, the resource owns itself for its full lifetime
   ├─ Owned by one binding, released when binding dies → Drop trait
   └─ Multiple owners, dynamic lifetime → Rc<T> (future) or manual
```

```
Resource has parameterized release (write-back semantics)?
├─ Yes → Scoped (mutex_unlock takes value back)
└─ No → either trait works; prefer Drop for "always-on" cleanup, Scoped for block-scoped lease
```

```
Need to release on error but commit on success?
└─ Override Scoped::release_on_throw to release; let release(v) be a no-op transfer.
   (errdefer-style, builder pattern.)
```

### Non-goals

- **No checked exceptions / typed error hierarchy.** `release_on_throw` receives the throw message as `String`, same as the rest of the Throws transport. Rich error types are a separate axis.
- **No "release in arbitrary order" / `ScopeStack` dynamic LIFO.** A `Vec<ScopedBox>` helper covers the dynamic-resource case; doesn't need language support.
- **No `defer` keyword.** `with cleanup_scope(fn) do -> rest_of_body() end` is the same thing in fewer language features. If a `defer` keyword does land later, define it as macro-sugar over `with` (Common Lisp `WITH-*` strategy).
- **No retroactive Drop-on-throw fix in B.8.** That belongs to B.9 (panic_caught migration). Scoped works around the gap by installing its own throws-frame.
- **No comma-list `with H1, H2 do x ->` ambiguity.** Comma-list is single-bind only via nesting: `with H1 do -> with H2 do x -> ... end end`. The existing comma-list sugar (`with H1, H2 do -> ...`) keeps working for the no-bind form.
- **No automatic Scoped derivation from Drop.** Drop and Scoped have different signatures and semantics. A user who wants both writes both impls. (Most types want only one.)

### Open questions

1. **Generic erasure and the bound-value type.** `Mutex<T>` today is `Int`-erased; the protected value is read/written as `Int`. The `R` type-parameter on `Scoped<R>` works at the type-checker level but does it propagate cleanly through `with mutex.lock do v -> ... end` to give `v: T`? Likely needs a `tc_make_scoped_acquire_type` helper that resolves the impl's `acquire` return type with `Mutex<T>`'s `T` substituted in, mirroring `tc_make_iter_elem_type` for the for-in loop. **Decision needed during Phase 3.**

2. **Suppressed-exception chaining vs. masking.** Java attaches release-throw as suppressed; C# loses it. Quartz today has neither — Throws.throw takes a single message. Phase 4 ships with masking semantics (release-throw replaces body-throw); a follow-up extends Throws.throw to carry a suppressed-chain Vec<String>. Defer the follow-up; ship masking first.

3. **Async resources (`AsyncScoped`?)** Python distinguishes `with` from `async with` for resources whose acquire/release suspend. Quartz's effect-row tracking already handles "this fn suspends" via `can Async`; an `AsyncScoped` trait whose `acquire`/`release` carry `can Async` is the natural extension, but no current stdlib resource needs it. **Defer; file when first user surfaces.**

4. **`scope.with` integration with B.7.** B.7's `scope_with(s, body)` is *almost* a Scoped impl already — it acquires (push s onto current_scope), releases (cancel s + restore), and is throw-safe. Phase 5 ships `impl Scoped for Scope` whose `acquire` returns `s` and whose `release`/`release_on_throw` calls `scope_cancel(s)` + restore. The legacy `scope_with(s, body)` function stays as a non-deprecated alternative for callers who want closure form. **Compatibility decision: `scope_with` is NOT deprecated by B.8. Both forms ship.**

5. **`with` block expression-vs-statement.** Today NODE_WITH lowers in both expression and statement positions (mir_lower.qz:2982 + 3554). The Scoped variant must work in both. Body-block's last expression is the `with`-expression's value, exactly like today's effect-handler `with` (verified — see `tc_expr` NODE_WITH and `mir_lower_expr` NODE_WITH). **No new design work needed.**

---

## Phase plan

| Phase | Work | Estimate | Notes |
|---|---|---|---|
| 1 | Design memo (this) | done | shipped 2026-05-08 |
| 2 | Parser: extend `ps_parse_handler_block` to accept `do x -> ...` and `do x: T -> ...` bindings; extend `ast_with` to carry an optional bound-param AST handle | ~0.3d | shipped 2026-05-08 (`7afec064`) |
| 3 | Typecheck: register `Scoped` trait in `std/`; extend `tc_with_handler_begin` with Scoped-impl lookup branch; substitute generic args for bound-value type; new diagnostic QZ0614 | ~0.5d | shipped 2026-05-08 (`c9cfe02d`) |
| 4a | MIR lower: emit acquire / body / release for Scoped NODE_WITH on **normal-exit** paths only. Wrap-stack extended with `kind=1` (Scoped) entries so NODE_RETURN / break / continue inside the body emit a balancing `<Struct>$release(self, v)` call. First Scoped impl shipped — `MutexGuard` in `std/sync/mutex.qz` — exercising the path end-to-end. | ~0.7d | shipped 2026-05-09 |
| 4b | Throw-safety: wrap each Scoped body in a generated `Throws { throw: __qz_scoped_throw_handler }` install. The dispatcher pops its own ctx + decrements `effect_stack_top` to skip past its own Throws frame, calls `<Struct>$release_on_throw(self, v, msg)`, then re-performs `Throws.throw` so the next outer frame catches. Adds a TLS Scoped-ctx stack to `codegen_runtime.qz` (hosted + freestanding stub). | ~1d | next |
| 5 | Stdlib: ship the rest of the `impl Scoped` matrix — `RwLock<T>`, `FileHandle`, `Channel<T>`, `Scope`, `TcpStream`, `TcpListener`, `TlsStream`, `UdpSocket`, `EventLoop` | ~0.5d | partially shipped (Mutex landed in 4a); remainder follows 4b so impls can drop release_on_throw if default suffices |
| 6 | Migrate stdlib consumers: replace 13 manual `mutex_lock`/`unlock` pairs in `std/progress.qz` with `with`-blocks; same in `std/sync/scope.qz`; same in `std/io/file.qz` `file_append` etc. | ~0.3d | Catch leak bugs in passing |
| 7 | Docs: `QUARTZ_REFERENCE.md` "Scoped resources" section (decision tree, every stdlib type with `impl Scoped`); `STYLE.md` recommends `with X do x -> ... end` over manual lock/unlock; `CLAUDE.md` anti-hallucination notes the new shape; doc-comment headers on `std/sync/scope.qz` reframed | ~0.3d | Mandatory before close |

**Total**: ~2.4-3.0 quartz-days. Original B.8 estimate was 3-5 days — the design phase reveals existing substrate covers ~40% of the work (parser block-params already tokenize, NODE_WITH already lowers, throws-frame already runs cleanup). Calibration aligns with B.7 Phase 6 (estimated 0.5d, shipped 0.3d) and B.6 (estimated 2-3d, shipped 0.3d): the typecheck-only insertion point is the right design.

**Calibration update (2026-05-09):** Phase 4 was actually larger than the 0.5-1d original sizing once the throw-safety story was fully traced through `__qz_effect_perform`. Splitting Phase 4 into 4a (normal-exit, ~0.7d shipped) + 4b (throw-safety retrofit, ~1d) matches the precedent in `feedback_phase_4e_chunked_poll_recipe`: ship the smaller correct piece first, then retrofit the throwing-safety layer. 4a unblocks Phase 5/6/7 design work because all the stdlib impls' acquire/release shapes can be validated against 4a immediately; only `release_on_throw` validation has to wait for 4b.

**Parallelism**: Phases 2-4a are sequential. Phase 5 can start after Phase 4a is green (it already is — first impl shipped in the 4a commit) but the bulk waits on 4b so impls can decide whether to override `release_on_throw`. Phase 6 unblocked by Phase 5. Phase 7 final.

---

## Risks / dependencies

- **Generic-substitution in bound-value type** (Open question #1) is the only real risk. If `tc_make_scoped_acquire_type` turns out to be more complex than `tc_make_iter_elem_type`, Phase 3 grows. Mitigation: ship Mutex with a hardcoded `Int` bound value first, generalize in a follow-up. The `R` type-param is invisible at the IR level (existential erasure), so the worst-case is "user sees `Int` instead of `T` in the binding" — incorrect but not unsafe.
- **NODE_WITH dual lowering paths** (mir_lower.qz:2982 expression + 3554 statement) means the Scoped lowering must be added in both places. Symmetric with current effect-handler logic; verify both walkers see the new `tc_with_kind` slot correctly. Mitigation: a single `mir_lower_with_scoped` helper called from both sites.
- **Throws-frame interaction with the scheduler's panic_caught** (B.9 territory). If a Scoped release_on_throw throws *and* runs inside a goroutine whose top-level frame is wired to panic_caught, the suppressed-exception case is currently a process abort (legacy panic path). Acceptable — release-on-throw is rare, double-throw inside it is rarer. Filed as a B.8 follow-up after Phase 4, not a launch blocker.
- **Migration churn** (Phase 6) in `std/progress.qz` could destabilize the progress-bar code that runs through every benchmark and the bootstrap pipeline. Mitigation: ship migration in a separate commit from the trait/codegen work, keep manual-lock paths working until the migration is verified.

---

## Success criteria

- All 13 manual `mutex_lock`/`unlock` pairs in `std/progress.qz` replaced with `with mutex.lock do v -> ... end`.
- New spec `spec/qspec/scoped_resources_spec.qz` covers: normal-exit release, throw-exit release, nested `with`, generic bound-value type substitution, Drop+Scoped coexistence, scope_cancel inside body still releases.
- `with mutex.lock do v -> ... end` round-trip-formats identically.
- Fixpoint clean (gen1 == gen2 byte-identical).
- All existing concurrency, scope, and file specs green.
- Smoke tests on `style_demo.qz`, `brainfuck.qz`, and a new lock-stress smoke pass.
- `docs/QUARTZ_REFERENCE.md` "Scoped resources" section ships with worked examples for every stdlib type.

---

## Calibration notes

Original B.8 estimate: 3-5 quartz-days (filed May 1).
Post-design estimate: 2.4-3.0 quartz-days.
Reduction is due to substrate already shipped: NODE_WITH parser/typecheck/MIR machinery (Piezoelectric Effects), `trait Drop` proving the type-recursive scope-exit walker, B.7's Throws-frame machinery proving the throw-safe RAII pattern.

Per project memory `feedback_design_memo_estimates_oversize.md`: pre-flight survey of existing helpers before sizing — done in this memo. Per `feedback_phase_4e_chunked_poll_recipe.md`: the parallel for B.8 is "ship first impl with hardcoded type, generalize once recipe proven" — Mutex first, then RwLock, then the rest.
