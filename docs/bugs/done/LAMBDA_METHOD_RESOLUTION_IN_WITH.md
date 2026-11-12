# Lambda-method resolution fails inside wide `with` blocks

## Status

**Unreproducible as of 2026-04-23 (commit `f400f1c2`).** The exact
patterns that failed during P5.3.d.2 now build clean on the
P5.3.d.3-post-hygiene compiler. Memo retained because no targeted fix
was identified — one of the intervening commits (out-param drops,
shadow fix, dead-file deletion, or a fixpoint-byte-identical change
earlier in the sequence) implicitly resolved it, but the mechanism is
unknown. If the symptom resurfaces, the original diagnosis below is
still the best starting point.

**Original status**: Open. Surfaced 2026-04-23 during Phase 5.3 ·
P5.3.d.2 (Emit cascade step 2). Tracked in handoff
`docs/handoff/piezo-phase-5-3-step-2-cascade-handoff.md` §7.

## Symptom

Inside a wide ambient `with E { ... } do -> ... end`, `local.method()`
calls where `local` is declared **inside** the body fail to resolve as
method calls during codegen. The emitted IR loads the method name as a
closure variable:

```llvm
%to_string = load i64, ptr %to_string, align 8
```

`llc` rejects this with `use of undefined value '%to_string'` — the
capture slot for a phantom "closure variable named `to_string`" is never
populated.

The equivalent call placed *outside* the `with` wrap resolves
correctly. Calls on outer-scope (captured) locals appear unaffected —
only locals declared fresh inside the `do -> ... end` body trip the
bug.

## Where it was hit

`self-hosted/backend/codegen_separate.qz` during the P5.3.d.2 cascade
sweep. Three dispatch branches in `cg_codegen_separate` each allocate a
fresh `var func_buf = sb_new()` per MIR function, call
`codegen::cg_emit_function(state, func_buf, prog, ...)`, then extract
with `func_buf.to_string()`.

The planned wide install was:

```qz
with Emit {
  emit: codegen_ctx::cg_ctx_emit_handler,
  emit_line: codegen_ctx::cg_ctx_emit_line_handler,
  emit_int: codegen_ctx::cg_ctx_emit_int_handler
} do ->
  for i in 0..func_count
    var func = funcs[i]
    var func_buf = sb_new()
    codegen_ctx::cg_ctx_set(func_buf)
    codegen::cg_emit_function(state, func_buf, prog, func, i)
    var func_ir = func_buf.to_string()        # <-- phantom closure load
    sb_append(out, func_ir)
  end
end
```

`func_buf.to_string()` emitted `load i64, ptr %to_string, align 8` and
`llc` rejected.

## Resolution (2026-04-23, commit `f400f1c2`)

Tier A investigation under the P5.3.d.3 handoff reduced from the
production shape:

1. Widened the changed-module branch's install (`cg_codegen_incremental`
   in `codegen_separate.qz:127`) to include `var func_buf = sb_new()`
   + `func_ir = func_buf.to_string()` + `sb_free(func_buf)` all inside
   the `with Emit { ... } do ->` body. **Built clean.** Fixpoint
   byte-identical. separate_compilation_spec 6/6 green.
2. Same shape applied to the `__qz_module_init` branch
   (`codegen_separate.qz:538`). **Built clean.**

Whatever was broken at P5.3.d.2 shipping time (commit `76ebac8a`) is
no longer broken at P5.3.d.3+ (commit `f400f1c2`). No targeted fix
was made. One of the intervening commits — mechanical leaf
out-param drops, the `has_original_init` shadow fix, the
`codegen_main.qz` deletion, or a fixpoint byte-identical change
before that — implicitly repaired it. The mechanism is unknown.

The widenings ship as real improvements in `f400f1c2`.

## Previous workaround (retained for context)

Per-call minimal wraps — the `with` scope was shrunk to cover *only* the
`cg_emit_function` call, and every method-bearing line was moved
outside:

```qz
for i in 0..func_count
  var func_buf = sb_new()
  codegen_ctx::cg_ctx_set(func_buf)
  with Emit { ... } do ->
    codegen::cg_emit_function(state, func_buf, prog, func, i)
  end
  var func_ir = func_buf.to_string()          # outside wrap → resolves
  sb_append(out, func_ir)
end
```

This **was** what shipped at `codegen_separate.qz:137, 544, 568` until
`f400f1c2` widened the first two. `cg_codegen_debug` never carried a
narrow wrap — it used a wide ambient install (cg_codegen.qz:1155)
from the P5.3.d.1 cascade onward.

`cg_codegen`'s wider install (`codegen.qz:1015`) does **not** trip the
bug because its loop body calls `cg_emit_function(state, out, ...)` —
where `out` is an outer-scope capture — and never creates a fresh
sb-like local that needs `.to_string()` called on it inside the wrap.
That's the observable invariant: "new locals with method calls inside
`with`" is the hazard; "captured outer vars with method calls inside
`with`" appears fine.

## Attempted minimal reproductions (all compiled clean)

Six standalone repros failed to trigger the bug:

1. `with Emit { ... } do -> var sb = sb_new(); sb.append("x"); sb.to_string(); ...`
2. `with Emit { ... } do -> var sb = sb_new(); produces_emit(); sb.to_string(); ...`
3. Same as (2) with effect-producing fn call interleaved.
4. `for i in 0..3` wrapped inside the `with`.
5. Outer-sb captured, method called inside the `with`.
6. Combo: outer `var out = sb_new()` + inner `var func_buf = sb_new()` +
   `produces_emit()` + `func_buf.to_string()` inside a `for` inside a
   `with`.

All compiled and `llc`-assembled clean. So the trigger is more subtle
than "new sb local + method call inside `with` body." Candidate
distinguishing factors not yet ruled out:

- Something about `cg_emit_function`'s effect row (`can Emit`)
  propagating through the call, interacting with capture analysis.
- `codegen_ctx::cg_ctx_set(func_buf)` as an intermediate — threading a
  pointer to a codegen-state register, possibly breaking the typechecker's
  tracking of `func_buf`'s type.
- The `out` (outer buf) captured + `func_buf` (inner buf) both active,
  both being appended to.
- Scale of the closure (binding count, captured-var count).

## Hypothesis

Closure capture analysis inside `with`-block desugaring drops the
method-resolution pass for locals declared *inside* the lambda body
under some combination of effect-row propagation and
multi-buf-in-scope. The fix likely lives in either
`mir_lower_lambda` or `tc_expr_call`'s method-resolution pass — when
the call-site context is a `with`-block body (a lambda), method lookup
defaults to treating the identifier as a free variable and emits a
closure-env load.

## Recommended investigation path

1. Build a mirror of the production `cg_codegen_separate` pattern
   (including `cg_ctx_set` + `codegen::cg_emit_function(state, buf, ...)` +
   an effect-producing body fn) in a tiny standalone file, iteratively
   reducing from the real site until the bug disappears — the last
   removed piece is the trigger.
2. Compare AST dumps for the working (narrow) vs broken (wide) form of
   the same loop: `./self-hosted/bin/quartz --dump-ast ...`.
3. Compare MIR dumps: `--dump-mir` — the `load i64, ptr %to_string`
   has to appear somewhere in the lowering; find the handler that
   emitted it.
4. Probable fix site: `typecheck_expr_handlers.qz::tc_expr_call` —
   method-call resolution likely short-circuits to
   closure-capture-by-name when it fails its first-choice lookup
   inside a lambda body.

## Why it was worth fixing (now no longer blocking)

Blocked Option Z ("complete" Emit cascade) — two `cg_codegen` variants
couldn't use wide ambient installs because the method calls their
inner loops depend on tripped this bug. Would also have limited
scope-widening opportunities in Phase 5.2 (State effect) and
Phase 5.4+ once those land.

With the widenings in `f400f1c2`, the Emit cascade has achieved Option Z
(all `cg_codegen` variants use wide ambient installs). Phase 5.2
Option Z and Phase 5.4 onward should not encounter this specific
blocker — they should sanity-check with a wide probe first, but there
is no known reason the shape will fail.

## Related

- `docs/bugs/PHASE-5-1-TC-EXPR-BODY-WRAP.md` — different symptom
  (QZ0603 + llc segfault on very large body-wrapped fn), but similar
  flavor: closure-body type-inference / capture interaction loses
  track of something.
- P5.3.d.2 handoff:
  `docs/handoff/piezo-phase-5-3-step-2-cascade-handoff.md` §3, §7 #1.
- Production callsites that had to use the workaround:
  `self-hosted/backend/codegen_separate.qz:137, 544, 568`;
  `self-hosted/backend/codegen_incremental.qz` changed-module branch;
  `self-hosted/backend/codegen_debug.qz` (via `_cg_emit_function_with_linkage`).
