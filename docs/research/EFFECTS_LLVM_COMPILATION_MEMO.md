# Operation Piezoelectric Effects — LLVM Compilation Strategy Memo

> **Epic**: Operation Piezoelectric Effects (commit tag `[piezo]`)

**Date**: 2026-04-18
**Status**: Design memo — informs Phase 1 implementation.
**Sources**: Leijen 2017 (type system foundation), Xie & Leijen 2020 (evidence-passing, three-kind ops, benchmarks), paper notes in [`EFFECT_SYSTEMS_NOTES.md`](EFFECT_SYSTEMS_NOTES.md).
**Depends on**: committed design in [`EFFECTS_IMPLEMENTATION_PLAN.md`](EFFECTS_IMPLEMENTATION_PLAN.md) (all 10 decisions closed 2026-04-18).

Phase 0 exit criterion: "Compilation model chosen, with rationale." This memo is the rationale.

This memo translates the abstract evidence-passing design into concrete LLVM IR shape, calling conventions, and phase sequencing. Where the papers target Haskell (GHC runtime with closures, lazy evaluation, type-class dispatch) or JavaScript (trampoline, variadic detection), Quartz targets LLVM IR directly — we re-derive the mechanics.

---

## 1. ABI: evidence as a threaded pointer

### 1.1 Representation

An **evidence context** is a singly-linked list of handler nodes, innermost first:

```c
// Conceptual — actual Quartz-generated LLVM IR
struct EvNode {
  i64   marker;     // unique runtime token for this handler install
  ptr   handler;    // points to effect-specific Handler struct (vtable)
  ptr   tail;       // next node outward, or null for empty context
}
```

A **handler struct** is a vtable of operation function pointers plus optional return-clause slot:

```c
struct ThrowsHandler {
  ptr throw_op;      // (ev: ptr, e: E) -> Never  [value/function/operation kind tag]
  ptr return_clause; // optional; (ev: ptr, v: T) -> T' or null
  // No additional fields for this effect; value-carrying effects add slots.
}
```

Every **function with a non-empty effect row** takes an implicit `__ev: ptr` parameter — the first parameter after `self` (if any). Pure functions take no evidence.

### 1.2 Calling convention

```
def pure_func(x: Int): Int                        → LLVM:  define i64 @pure_func(i64 %x)
def throws_func(x: Int): Int can Throws<E>        → LLVM:  define i64 @throws_func(ptr %__ev, i64 %x)
def method(self: MyType, x: Int): Int can Io      → LLVM:  define i64 @method(ptr %self, ptr %__ev, i64 %x)
def poly<ε>(x: Int): Int can ε                    → LLVM:  define i64 @poly(ptr %__ev, i64 %x)  // same shape as throws_func
```

**Key invariants:**

- Evidence parameter immediately follows `self` (or comes first if no self) in the LLVM signature.
- Polymorphic effect functions ALWAYS receive evidence, even if instantiated with empty row. Trade-off: one extra parameter push for polymorphism. Acceptable — Koka accepts this and hits perf targets.
- Pure functions (empty row, no `can` clause) receive NO evidence parameter. This preserves direct-call perf for the pure subset.
- Call sites must materialize the correct evidence. For functions inheriting the caller's row, pass `%__ev` verbatim. For functions with a subset row, the caller's `%__ev` is still correct because evidence is order-preserving (a function requiring `Throws` in context `[Throws, Io]` just looks up `Throws`, ignores `Io`).

### 1.3 FFI boundaries

Effect rows DO NOT cross `extern "C"` boundaries.

- Calling `extern "C" def libc_fn(...)` from Quartz: libc_fn's signature has no `can`, so it's callable only from empty-row or row-polymorphic contexts. Callers with effects can still call it; evidence simply isn't passed.
- Exposing a Quartz function to C: if the function has any non-empty row, compiler emits a trampoline wrapper that installs default handlers before the call and tears them down after. `#[export_c]` annotation or inferred from `extern "C"` at the Quartz-source level.
- Quartz → Quartz via function-pointer indirection: the pointer type includes the effect row; calling through it threads evidence normally.

---

## 2. The three operation kinds

From Xie & Leijen 2020 §3.3: every effect op is classified at declaration time into one of three kinds. Quartz inherits this taxonomy **because it determines the compilation path**.

### 2.1 `value` kind — constant resumption

```quartz
effect Config
  def debug_mode(): Bool = value(false)        # always resumes with false by default
end
```

Compilation:
- Handler struct slot = just the constant value (stored inline where a fn pointer would be).
- `perform debug_mode` at call site: two loads (evidence → handler; handler → value slot). No call. No continuation capture.
- Cost: O(depth of evidence) for handler lookup, then O(1) for value read.

### 2.2 `function` kind — tail-resumptive

```quartz
effect Log
  def log(msg: String): Void = function(msg -> write_to_stderr(msg))
end
```

The body uses `resume(x)` at exactly the tail position. Most effect ops are this kind.

Compilation:
- Handler struct slot = function pointer to `(ev, args) -> return_type`.
- `perform log(msg)` at call site: evidence → handler → op fnptr → call(ev, msg). Normal return; continuation is implicit (the return address on the native stack).
- **No continuation capture. No CPS. No state machine.** Direct indirect call with vtable lookup.
- Cost: O(depth of evidence) for handler lookup, then one indirect call.
- **This is the fast path** — the 2020 paper's benchmarks show this is competitive with pure code even for deep effect stacks.

### 2.3 `operation` kind — general

```quartz
effect Throws<E>
  def throw(e: E): Never = operation(ev, k, e -> /* discards k, aborts */)
end

effect Async
  def await<T>(fut: Future<T>): T = operation(ev, k, fut -> /* stores k in scheduler, yields */)
end
```

Body may discard the continuation (abort), use it once (single-shot resume), or use it multiple times (multi-shot, only if declared multi-shot — deferred for Ndet).

Compilation:
- Handler struct slot = function pointer to `(ev, k, args) -> result` where `k` is the reified continuation.
- `perform throw(e)` at call site: evidence → handler → op fnptr → call(ev, continuation, e).
- **Continuation reification needed.** We reuse Quartz's existing `$poll` state-machine machinery (the same mechanism that implements `async/await` today).
- Cost: CPS transform for the enclosing function (every call site needs to "know" where to resume); one indirect call for the op itself; heap allocation for captured locals if the continuation outlives the stack frame.

### 2.4 Tail-resumption detection (the >80% perf win)

Detection is a MIR-level syntactic analysis. The op body is classified as:

1. **`value`** if body has form `value(expr)` where `expr` has no effects and doesn't reference `resume`.
2. **`function`** if body has form `function(args -> expr)` where:
   - The function body contains exactly one `resume` call,
   - And that `resume` is in tail position (last expression, or guarded tail of `if`/`match`),
   - And `resume`'s arg is not itself a `perform` (that would chain operations).
3. **`operation`** otherwise. Default fallback.

Users can force `operation` via explicit syntax (`def throw(e) = operation ...`). Auto-detection is for ergonomics; kind is always visible in hover / `quartz doc`.

**Implementation location:** `self-hosted/middle/typecheck.qz` — new pass after effect-row inference, before MIR lowering. Emits a kind tag onto each effect op declaration.

---

## 3. Compiling `operation`-kind ops: CPS transform

For operation-kind effect ops, the caller's code needs to split at the `perform` call — code before becomes "push arg, suspend" and code after becomes "continuation, resumable."

### 3.1 Quartz already has this machinery

Our existing async compilation does exactly this: functions declared `async` are lowered to state machines where each `await` point becomes a suspension point. The state machine struct captures live locals at the suspend; `$poll` drives the machine forward from one suspend to the next.

**Plan: reuse this.** A function containing any `operation`-kind `perform` becomes a state machine in the same way. The `operation` handler is invoked with a pointer to the state machine; invoking `resume` is invoking `$poll` on the state machine with a value.

This is why **Phase 3 (async-as-effect migration) is less work than it looks**: async is already operation-kind-flavored; we just reframe it through the effect system rather than as a special-cased keyword.

### 3.2 When does a function need the state-machine lowering?

A function needs operation-kind treatment if ANY `perform` in its body (transitively, including through called functions) hits an operation-kind op. Effect-row inference gives us this for free: if a function's row contains any effect whose ops include an operation-kind, the function's codegen lowers to a state machine.

**Practical consequence:** most Quartz functions will be `function`-kind and compile to direct calls. Only functions that throw, await, yield to unbounded generators, or panic hit the state-machine path. Those are already the "slow" functions in Quartz's runtime.

### 3.3 Avoiding the "everything is a state machine" failure mode

Koka's 2017 paper highlighted this failure mode: applying CPS to everything tanks performance. Evidence-passing + per-kind dispatch avoids this because function-kind ops don't trigger CPS. A Quartz function that only uses `Log` and `Clock` (both function-kind) compiles to ordinary LLVM code with extra evidence parameter.

---

## 4. Handler installation

### 4.1 Source form

```quartz
result = with catch (e: ParseError) -> default_result do ->
  risky_parse(input)
end
```

Desugars to:

```quartz
# Allocate new evidence node on stack
# Invoke body with extended evidence
# After body returns, unwind evidence (implicit via stack discipline)
```

### 4.2 LLVM IR

```llvm
; %outer_ev is the caller's evidence (may be null for main)
%marker = call i64 @__qz_fresh_marker()
%handler = alloca %ParseErrorHandler
store ptr @parse_error_catch_op, ptr %handler, ... ; fill in vtable
%new_ev = alloca %EvNode
store i64 %marker, ptr %new_ev, ...
store ptr %handler, ptr %new_ev, ...
store ptr %outer_ev, ptr %new_ev, ...
%result = call ptr @risky_parse(ptr %new_ev, ptr %input)
; (on normal return, %new_ev goes out of scope — stack unwinds)
```

**Allocation strategy:** stack allocation for handlers is the common case. Only if the handler is captured into a closure or returned from its scope do we heap-promote. Escape analysis in the MIR layer handles this (same mechanism Quartz uses for other stack-allocatable values).

### 4.3 `resume` semantics

For function-kind ops: `resume(x)` is implicit — the op's return value IS the resumption. No `resume` keyword in the source clause body:

```quartz
effect Log
  def log(msg: String): Void = function(msg ->
    write_to_stderr(msg)   # void return; no explicit resume
  )
end
```

For operation-kind ops: `resume(x)` explicitly invokes the continuation with a value. Compiled as `$poll(continuation, x)`:

```quartz
effect Async
  def await<T>(fut: Future<T>): T = operation(ev, k, fut ->
    if fut.is_ready then
      resume(k, fut.value)         # resume with the ready value
    else
      scheduler_park(fut, k)       # store k; yield up
    end
  )
end
```

### 4.4 Scoped-resumption enforcement (`guard`)

When `resume` is invoked:
1. Compare current evidence's marker tail against the marker captured with `k`.
2. If match (continuation's context is still above current context): safe, proceed.
3. If mismatch (continuation captured under a different evidence stack): runtime abort with `QZ9502: Unscoped resumption — handler torn down before continuation invoked`.

This prevents the Peter Landin hazard ("you can enter a room once, yet leave it twice" — referenced in Xie-Leijen 2020 §2.4) — a resume captured under handler A cannot be invoked under handler B even if A and B catch the same effect.

---

## 5. Polymorphic effect functions

`def map<T, U, ε>(items: Vec<T>, f: Fn(T) can ε: U): Vec<U> can ε` inherits f's effect row.

### 5.1 Single compilation, evidence threaded

We compile ONE version of `map` that takes evidence as a regular parameter. When called with a concrete effect row (e.g., `can Throws<E>`), the caller passes its own evidence; `map` threads it to `f`'s invocation. No monomorphization per effect row.

**Why not monomorphize per row?** Would blow up code size exponentially — `N` generic functions × `M` concrete effect rows × `K` concrete type params = NxMxK compiled copies. Koka's experience: ~20% code growth is acceptable; 100%+ is not.

### 5.2 When monomorphization DOES happen

- **Concrete effect row + generic type**: `Vec<Int>.map(f: Fn(Int): Int)` with f pure — no effect row, no evidence, monomorphized as usual for `T=Int, U=Int, ε=∅`.
- **Single-use at a concrete row**: the compiler MAY specialize if it helps inlining, but it's not required.
- **Trait method dispatch**: methods are already monomorphized per concrete type; effects add another dimension but evidence is always threaded, so no additional copies needed.

### 5.3 LLVM-specific optimization

`map` with evidence-threaded design compiles to calls of form:

```llvm
call i64 %f(ptr %__ev, i64 %arg)
```

LLVM can inline through function pointers when they're constant at the call site (which happens for any non-higher-order use). For higher-order uses (the actual reason we have `map`), the indirect call through `%f` is unavoidable — but that cost exists today for any function-pointer call.

**Net cost estimate:** ~5% overhead for polymorphic-effect higher-order functions vs. direct calls. Within noise for most workloads.

---

## 6. Interaction with existing Quartz features

### 6.1 Generics

Extend `TcRegistry` to store effect-row parameters alongside type parameters. Inference unifies both; monomorphization happens on type params only (effect params use evidence threading).

### 6.2 Traits and trait methods

Trait methods can declare effect rows:

```quartz
trait Parse
  def parse(s: String): Self can Throws<ParseError>
end
```

Impl blocks must honor the trait's row (or have a weaker row, narrower is allowed — a parser that doesn't throw is fine). Trait method dispatch: same vtable mechanism we have today, plus evidence threading.

**Auto-satisfaction + effects:** an inherent method with row `can Throws<E>` auto-satisfies a trait method requiring `can Throws<E>`. Same row, same discipline.

### 6.3 Move semantics / borrow checker

Open question for Phase 1 design:
- What's the ownership of `x` in `throw(x)`? Default: moved. Handlers receive owned values.
- What's the ownership of a captured continuation? The continuation owns its captured frame; `resume(x)` consumes the continuation (single-shot). Multi-shot would require cloning, deferred with Ndet.
- Evidence pointer is borrowed — never consumed by `perform`. Always `&ev` at the call site.

### 6.4 Drop / RAII

Handler installation maps naturally to RAII. The `with handler do -> body end` block:
1. Allocates handler + evidence node on stack.
2. Runs body.
3. On scope exit (normal return OR unwinding from a panic): handler's Drop (if declared) fires.

This gives us "cleanup handlers" for free — effects can observe when their scope ends, not just when their operations are invoked.

### 6.5 Async (Phase 3 migration)

Current state: `async def`/`await` compile via `$poll` state machines. `go do -> end` spawns; channels/select are explicit.

Phase 3 migration:
- `Async` becomes an effect with ops `await`, `spawn`, `suspend`, `yield`.
- Ops are operation-kind (reify continuation).
- The scheduler IS the handler. `with sched_handler do -> program() end` is what `sched_run` becomes.
- `go do -> end` desugars to spawning an effect-aware task.
- **Codegen changes are minimal** — existing $poll machinery IS the operation-kind lowering. We reframe rather than rewrite.
- **User-visible changes**: user code stays invisible (no `can Async` needed for main thanks to prelude default handler). Advanced users can install custom schedulers via `with my_scheduler do -> ...`.

### 6.6 Panic

`Panic` is an effect with one op `panic(msg, trace)` — operation-kind (never resumes). Default handler (installed in prelude): print + flush + exit(101). Custom handlers catch panics before they reach main — useful for test harnesses, crash reporters, debugger hooks.

Panic UNWINDS through intermediate handlers (their Drop firings run), but is NOT caught by `with catch` unless the catch explicitly targets `Panic`. Practical effect: `with catch (e: ParseError) -> ... do -> code end` does NOT swallow a panic from inside `code`.

---

## 7. Phase 1 implementation milestones

### 7.1 Milestone A — Lexer + parser (~1 quartz-day)

- Add `TOK_CAN`, `TOK_EFFECT`, `TOK_WITH`, `TOK_HANDLE`, `TOK_TRY`, `TOK_REIFY`, `TOK_THROW`, `TOK_RESUME` tokens.
- `ps_parse_effect_decl` — parses `effect Name<T> ... end`.
- Extend `ps_parse_function` to handle `can Row` suffix.
- `ps_parse_handler_block` — parses `with ... do -> body end`.
- `ps_parse_try` — parses `try expr` (prefix operator).
- `ps_parse_reify` — parses `reify { expr }`.
- Delete `$try` macro handling (replaced by `try` keyword).

### 7.2 Milestone B — Type system: rows + inference (~2 quartz-days)

- `TcRegistry.rows` — new parallel Vecs storing row structure (label list + optional tail variable).
- `tc_row_unify` — Rémy-style unification, allows duplicates (Model B).
- `tc_row_substitute`, `tc_row_occurs_check`.
- Extend fn type representation with optional effect row.
- OPEN / CLOSE rules in inference (the load-bearing simplification).
- Call-site propagation: callee's row ⊆ caller's row.
- Effect-op call adds op's label to caller's row.
- Handler installation removes op's label from body's row.

### 7.3 Milestone C — MIR: effect primitives + kind classification (~1 quartz-day)

- New MIR opcodes: `MIR_PERFORM`, `MIR_INSTALL_HANDLER`, `MIR_RESUME`, `MIR_REIFY_BEGIN`, `MIR_REIFY_END`.
- Tail-resumption detection pass (§2.4) — classifies each op declaration as value/function/operation.
- Lower `try expr` to implicit `perform` of `throw` on None/Err branches.
- Integrate with existing async lowering — `operation`-kind ops reuse `$poll` state-machine lowering.

### 7.4 Milestone D — Codegen: evidence threading + handler structs (~1.5 quartz-days)

- Emit evidence parameter on functions with non-empty rows.
- Emit handler struct types (one per `effect Name ... end`).
- `cg_emit_perform` — compile perform-op call (lookup + indirect call).
- `cg_emit_install_handler` — allocate handler + evidence node, extend ev chain.
- `cg_emit_resume` — for function-kind, just return; for operation-kind, invoke captured `$poll`.
- `cg_emit_reify` — install a handler that catches-and-wraps.
- Default handler stack initialization in main entry point.

### 7.5 Milestone E — Stdlib pilots (~0.5 + 0.5 quartz-days)

- **E1**: `std/log` migration. Simple `Log` effect with `info`/`warn`/`error` ops (function-kind). Default handler writes to stderr. Tests: log messages reach stderr; custom handler can capture.
- **E2**: `std/parse` migration. `Throws<ParseError>` effect. `parse_int`, `parse_float`, `parse_bool` ops. Tests: uncaught throws reach main (panic); `with catch` handles; inference propagates through call chains.

### 7.6 Milestone F — Error messages (~1 quartz-day, parallel to A-E)

All 6 commitments per quality bar + engagement-level detection. Test: concrete error cases from §5.5 of the plan produce messages matching the spec exactly.

### 7.7 Milestone G — Fixpoint + smoke tests (~0.5 quartz-day)

- `quake guard` passes after all changes.
- Fixpoint: gen1 == gen2 byte-identical.
- Smoke tests (brainfuck.qz, expr_eval.qz, style_demo.qz) pass unchanged.
- Existing QSpec suite (all 523 files) passes. New specs for effects mechanism: `effect_basics_spec.qz`, `throws_handler_spec.qz`, `effect_row_inference_spec.qz`.

### 7.8 Milestone H — Docs (~0.5 quartz-day)

- Fill in `docs/EFFECTS.md` §§ 2, 6, 7, 9, 11.
- 10-15 examples in `examples/effects/`.
- Update `docs/QUARTZ_REFERENCE.md` syntax section.
- Update CLAUDE.md with effect idioms.

**Total estimate:** 8 quartz-days across 10-14 sessions. Matches the plan's 5-7 quartz-days estimate with ~30% buffer for integration discovery.

---

## 8. Performance targets + kill criteria

### 8.1 Targets

- Function-kind effect op: ≤ 3 extra instructions vs. direct call (1 load for evidence, 1 load for handler, 1 indirect call).
- Operation-kind effect op: reuses existing `$poll` overhead (no new cost).
- Polymorphic effect function: ≤ 5% slower than same function with concrete effect row.
- Deep effect stack (5+ handlers): constant-time lookup (hot path cache) — target O(depth) but depth-3 case within 2x of depth-1.
- Self-compile with all effects instrumented: within 10% of current 18.3s wall time.

### 8.2 Kill criteria

From the plan, restated with specifics:

- Self-compile > 2x current wall time → redesign evidence lookup (hot cache, shallow-handler fast path).
- Effect row inference adds > 2 GB peak RSS to typecheck → reconsider row representation.
- Error messages can't hit the quality bar without reinventing the type system → fall back to Phase 1-lite (Throws only, no full effect system) and revisit in a future major release.
- Polymorphic functions cost > 20% vs. direct — check polymorphic-function code size growth; if it's worse than Koka's 20%, investigate.

---

## 9. What we're NOT doing in Phase 1

Deliberately out of scope:

- **Multi-shot handlers.** Operation-kind ops may `resume` zero or one times. `resume(k); resume(k)` is a runtime abort. Deferred with Ndet (indefinitely).
- **Effect-polymorphic trait bounds.** `def foo<T: Eq can Throws>(a: T)` — worth having eventually but adds complexity. Phase 2 or later.
- **First-class handlers as values.** Pass a handler as a function parameter? Nice but complex. Later.
- **Dynamic effect extension.** Runtime-registered effects. No.
- **Alloc effect.** Phase 2 (needs State + Reader machinery first).
- **Compiler dogfooding (Phase 5).** Big payoff, but Phase 1 must prove machinery first.

These omissions are **explicit** — not forgotten. Phase 1 exits with them intact as future work, not silent gaps.

---

## 10. Open design questions (to resolve during Phase 1)

1. **Exact MIR opcode shape for `MIR_PERFORM`** — arg order, calling-convention discipline. Resolve when codegen phase starts.
2. **Handler-struct layout for effects with generic type params** (`Throws<E>` where E varies). LLVM IR has no generics; we probably generate one handler-struct type per concrete E and monomorphize. Confirm during Milestone B.
3. **`reify { }` block's desugar** — exactly what prelude-defined handler does it install? Is it syntactic sugar for `with catch (e: E) -> Err(e), return v -> Ok(v) do -> body end`, or a distinguished codegen form? Prefer the desugar for orthogonality.
4. **Scoped-resumption guard overhead** — one extra load + comparison per resume. Measurable? Bench before committing to always-on.
5. **Stack vs heap allocation for handler structs when the handler captures closures.** Escape analysis should handle; verify during implementation.

---

## 11. Conclusion

Evidence-passing (Xie-Leijen 2020 style) maps cleanly to LLVM IR via:
- Evidence as a threaded pointer parameter.
- Three-kind operation taxonomy that puts the common case on the fast path (direct indirect call).
- Reuse of existing `$poll` state-machine lowering for the operation-kind slow path.
- Stack-discipline handler installation with escape-analysis heap-promote as backup.

**Bottom line: this is implementable in Phase 1 as planned, with no redesign of existing subsystems.** Async ($poll state machines) stays; the borrow checker interacts cleanly; generics extend naturally; FFI boundaries are well-defined; error messages are achievable within our quality bar.

Phase 0 is complete. Phase 1 begins when you want it to.
