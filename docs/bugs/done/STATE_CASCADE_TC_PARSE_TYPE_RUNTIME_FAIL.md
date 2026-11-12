# `can State` cascade through tc_parse_type_impl → runtime unhandled-op

**Discovered**: 2026-04-23 during Piezo Phase 5.2.f Step 2b.
**Status**: ✅ **CLOSED 2026-04-29 — superseded by bridge-over-cascade pattern.** The bug requires the `can State` cascade through `tc_parse_type_impl` to fire. P5.2.f Steps 3-4 (commits `46cda4b9` and `07554b3e`) sidestepped the cascade entirely by using the `typecheck_ctx` bridge instead. Verified at HEAD: nested can-State recursion through Fn-typed parsing under `with State → with Diag` compiles and runs cleanly. Per `feedback_bridge_over_cascade_pattern.md` this is the expected pivot — pass-lifetime params drop from leaf signatures via a single-slot bridge instead of cascading. The bug remains LATENT only if the bridge is reverted and the cascade re-attempted; not a current failure mode.
**Reproducer**: the self-hosted compiler binary compiling
`Quakefile.qz` (not a minimal user program — attempted minimal
repros all pass cleanly).

## Setup

Step 2a shipped `7a7b923d` + `2e87704a`: the `with State(as_int(tc))`
install in `compile()` now wraps both Phase 4.0 registration
(line 524-695) and the Tier 2 incremental `tc_function` callsite
(line 916-922). Compiler is clean.

Step 2b attempted: strip `tc_enter_scope`'s body-wrap, add
`can State` to its signature, cascade `can State` up through callers.

## Cascade shape (build-time QZ0610 chase)

Four functions needed `can State` added to build clean:

- `tc_enter_scope(tc: TypecheckState): Void can State` (leaf)
- `tc_parse_type_impl(tc: TypecheckState, annotation: String): Int can Diag, State`
- `tc_function(tc: TypecheckState, ast_storage, func): Void can Diag, State`
- `tc_program(tc: TypecheckState, ast_storage, program): Bool can Diag, State`

Build passes with 2316 fns, fixpoint byte-identical.

Adding `can State` to `tc_parse_type` (the wrapper) cascades further
to 5 more call sites across `typecheck.qz` + `typecheck_registry.qz`
— not pursued in this investigation.

## Runtime failure

Running `./self-hosted/bin/quartz Quakefile.qz` with the cascaded
binary:

```
[mem] resolve_pass1: 13 MB, 13 modules
[mem] resolve_pass2: 13 MB
unhandled effect op called
```

`./self-hosted/bin/quartz /tmp/trivial.qz` (a one-line fn) **passes**.
The unhandled-op only triggers on non-trivial input.

## Traced localization (eputs-in-source bisection)

1. `with State(as_int(tc)) do ->` opens cleanly.
2. `with Diag { ... } do -> tc_program(...) end` nested install opens
   cleanly.
3. `tc_program` enters with State accessible — a probe `get()` at the
   top of `tc_program` returns without unhandled-op.
4. tc_program Phase 1-1.9 (struct/enum/trait/impl registration) all
   complete.
5. Phase 2 starts. `each(items, item -> { tc_register_function_signature(...) })`.
6. First ~9 annotations parsed successfully (including the first
   `Fn(Task, Int): String`).
7. On `Fn(String): Void`: the Fn branch of tc_parse_type_impl
   completes — all tracers fire through `DEBUG: before tc_make_ptype
   return for Fn`.
8. Immediately after that trace line: `unhandled effect op called`.

So:
- The forall path at `typecheck.qz:1138` **never fires** during this
  compile. (Hypothesis 5 from prior version of this memo disproven.)
- The failure is in the continuation AFTER
  `return tc_make_ptype(tc, TYPE_FUNCTION, fn_id, 0)` — either
  inside `tc_make_ptype` itself, or in the return unwind /
  caller-context continuation.

## What doesn't reproduce

A minimal repro with `with State → with Diag → probe() can Diag,
State` **passes**.

A minimal repro with `each(vec, x -> { can-State-fn() })` wrapped in
`with State` **passes** — lambda + State + dynamic dispatch across
lambda boundary works in isolation.

## Current hypotheses

1. **Evidence-slot write-back on return**. Functions declaring
   `can State` may emit per-call prologue/epilogue that
   reads/writes `@__qz_effect_current_install_idx` or
   `@__qz_effect_stack_state_slots`. A specific sequence of nested
   can-State returns (including recursion: tc_parse_type_impl
   recurses via tc_parse_type) could corrupt the TLS slot indices.
   Since we see failure AFTER a successful return from the inner
   Fn-parse path, this is the most plausible remaining hypothesis.

2. **Lambda MIR `handler_stack` save+clear+restore interacting with
   install-idx**. `mir_lower_lambda` at
   `backend/mir_lower_expr_handlers.qz:458` saves+clears the
   compile-time handler stack so lambda bodies use dynamic
   dispatch. The comment claims this is fine because "the runtime
   handler stack is populated per thread at run time" — but State's
   evidence-slot lookup reads `state_slots[current_install_idx]`.
   If `current_install_idx` is a compile-time constant baked into
   the lambda (vs. looked up at runtime), the lambda body's `get()`
   would read from the wrong slot.

3. **`tc_make_ptype` or `tc_registry::tc_register_fn_type` performs
   a State op transitively**. Not yet inspected. Would explain why
   failure is deterministic in the Fn-parse path.

## Investigation path for next session

- **Instrument `__qz_effect_state_get` helper**
  (`backend/codegen_runtime.qz` ~line 672) to dump
  `current_install_idx` and `state_slots[0..top]` every time it
  fires. Rerun Quakefile compile with cascade. The last-successful
  state + the first failing state will pinpoint whether the slot
  itself is wrong or the idx is wrong.

- **Compile with `--dump-ir`** and inspect the LLVM IR emitted for
  tc_parse_type_impl's Fn branch. Look for `state_slots` loads/stores
  tied to a specific install_idx. Compare to a known-good function
  (e.g., `tc_enter_scope`'s body).

- **Bisect the symptom by removing one `can State` at a time**.
  E.g., keep tc_enter_scope body-wrapped BUT add `can State` to
  tc_parse_type_impl only (with a local body-wrap around the
  tc_enter_scope callsite). If this works, the cascade mechanics
  are fine and the issue is specifically in tc_enter_scope's
  codegen.

- **Check tc_make_ptype implementation** for State-relevant code
  paths. Line ~1576 is the last traced callsite before unhandled-op.

## Workaround for Step 2b

**Keep the body-wrap in tc_parse_type_impl's `forall` case**:

```qz
def tc_parse_type_impl(tc: TypecheckState, annotation: String): Int can Diag
  ...
  if str_byte_slice(annotation, 0, 7) == "forall "
    ...
    with State(as_int(tc)) do ->
      typecheck_util::tc_enter_scope(tc)  # can State satisfied by local wrap
      for fa_i in 0..var_names.size ... end
      var body_type = tc_parse_type(tc, body_str)
      tc_exit_scope(tc)
      # bare expr as last stmt (body-wrap last-stmt gotcha)
      tc_register_forall(tc, var_names, var_ids, body_type)
    end  # with State close — last-stmt value is return value
  end
  ...
end
```

This local body-wrap installs State for just the forall path. Per
memory note `feedback_body_wrap_last_stmt.md`: body-wrap last stmt
must be a bare expression (`tc_register_forall(...)` call), not
`return X`. The `with State` block's value becomes the branch's
result; the outer `if` can return it.

If this workaround holds for other callers of tc_enter_scope in
tc_function / tc_program, Steps 3-4 can proceed with the mix:
tc_enter_scope gets `can State` signature, but any caller that
can't trivially cascade uses a per-callsite body-wrap.

This partially defeats the point of Option Z (drop `tc` from every
signature), but it preserves the leaf-level improvement
(tc_enter_scope no longer body-wraps its own body — it trusts
its caller's install).

## Status for P5.2.f

- **Step 2a shipped** (`2e87704a`: Tier 2 tc_function callsite
  pre-wrapped).
- **Step 2b blocked** on this bug. Cascade investigated and
  reverted; codebase is at Step 2a's commit.
- **Steps 3 and 4 deferred** until root cause is isolated OR the
  workaround path is validated.

## Files touched during investigation (all reverted)

- `self-hosted/middle/typecheck_util.qz` — tc_enter_scope signature
- `self-hosted/middle/typecheck.qz` — tc_parse_type_impl signature
- `self-hosted/middle/typecheck_walk.qz` — tc_function, tc_program
  signatures
- `self-hosted/quartz.qz` — various `eputs` tracers

Working tree clean at Step 2a's commit (`2e87704a`); only Step 2a
persists.
