# Phase 5.1 — tc_expr body-wrap codegen blocker

## Status

**CLOSED — never an active bug at HEAD; doc was filed against a stale snapshot.**
Discovered 2026-04-22 during overnight Phase 5.1 session; verified closed
2026-04-30 against trunk:

- `976a552d` (5.1.C, 2026-04-22 00:51) shipped the body-wrap on `tc_expr` and
  proved the QZ0603/llc-fail hypothesis below was wrong. The actual root cause
  was a single missed discipline: `return result` at the very end of a
  body-wrapped function terminates the merge block before
  `MIR_HANDLE_UNINSTALL` can emit its `store + br wb.done` sequence, producing
  IR that crosses block boundaries. Fix in that commit: drop the trailing
  `return` so the with-block's last expression is the implicit return value.
  Mid-body `return`s in deep elif branches are unaffected.
- This doc was timestamped 02:07 the same day, then never updated when the
  body-wrap successfully shipped. As of HEAD, `tc_expr` (line 953-956),
  `tc_stmt` (line 2102), and `tc_program` (via the outer `can Diag` cascade)
  are all body-wrapped. Fixpoint stamp is byte-identical against current
  source.
- The "closure capture interacts badly with type inference for method calls on
  `Vec<T>`" hypothesis below was wrong: `with E {...} do -> body end` parses
  as a NODE_WITH whose body is a NODE_BLOCK in the same scope/MirContext as
  the surrounding function — there is no closure boundary to lose type
  tracking across.

The lesson here lives in project memory as
[`feedback_body_wrap_last_stmt.md`](../../../../.claude/projects/-Users-mathisto-projects-quartz/memory/feedback_body_wrap_last_stmt.md):
"`with E {...} do -> ...body... end` as a function-body wrap MUST end with a
bare expression, NEVER `return X` OR a compound stmt … sets merge block's
terminator before handle_uninstall's direct text emission crosses block
boundaries → SSA dominance violations OR `use of undefined value '%push'` llc
error."

The original doc text follows for archival reference.

---

## Original symptom (archived; obsolete)

Body-wrapping `tc_expr` (typecheck_walk.qz:789-1919) in
`with Diag {...} do -> ... end` and migrating its 28 internal `tc_error`
sites to bare `error(...)` calls produces an LLVM IR that **llc rejects**
during assembly:

```
warning[QZ0603]: cannot resolve struct type for field access '.pop', using offset 0
warning[QZ0603]: cannot resolve struct type for field access '.free', using offset 0
... many similar QZ0603 warnings ...

llc: assembly fails with stack overflow / segfault / IR-parse error
```

The same exact transformation applied to **`tc_stmt`** (much larger body,
35 sites, also full of complex expressions) **works perfectly** —
`5.1.N.3` (`f24a3b7a`).

## Reproduction

1. Start from a clean Phase 5.1 state where `std/diag.qz`'s `Diag.error`
   and `Diag.warn` ops both return `Void` (5.1.B.2 onward).

2. Body-wrap tc_expr with the same pattern that worked for tc_stmt:

```diff
 def tc_expr(tc, ast_storage, node): Int
   if node < 0
     return type_constants::TYPE_ERROR
   end
+  with Diag {
+    error: typecheck_diag::tc_diag_error_handler,
+    warn: typecheck_diag::tc_diag_warn_handler
+  } do ->
   var node_kind = ...
   ...all 1130 lines of original tc_expr body...
   return result
+  end
+  return type_constants::TYPE_ERROR  # unreachable
 end
```

3. Mass-replace `typecheck_util::tc_error(tc, ` → `error(` inside the
   wrapped body (28 sites).

4. `quake build` — IR generation succeeds, `llc` fails.

## Hypothesis

Closure capture interacts badly with type inference for method calls on
`Vec<T>` and similar generic struct fields when the closure body is
**very large with many local `var` declarations**. The compiler's
struct-type resolver (the path that emits QZ0603) loses track of which
locals are which type, defaults to offset 0, produces wrong member
accesses, and the resulting IR is malformed enough that llc rejects it.

`tc_stmt` doesn't trip this because:
- Its body is statement-style (Void) — the closure value isn't escaping.
- Its locals are mostly used in single branches before exit.
- Maybe its closure capture set is smaller (fewer outer-scope variables
  referenced).

`tc_expr` trips it because:
- The body is expression-style (Int return) — closure return value flows.
- It has the most complex local variable dependencies in the codebase.
- Many `var x = ...; var y = ...; var z = vec_new(); z.push(x); ...`
  patterns inside the closure body.

## Workarounds for Phase 5.1 progression

1. **Migrate tc_expr's 28 sites with per-callsite wraps** (28 wraps,
   ~140 lines of repetitive boilerplate). Tedious but functional.

2. **Migrate tc_expr's 28 sites WITHOUT body-wrap, by adding `can Diag`
   to tc_expr's signature.** Cascades to ~15 functions in
   typecheck_expr_handlers.qz that call tc_expr. Each gets `can Diag`.
   Then no per-site wrap needed; the outer `with Diag` at quartz.qz:638
   covers the whole transitive call graph. This is the original Phase 5.1
   plan before 5.1.B made body-wrap viable.

3. **Investigate the underlying QZ0603 issue.** It might be a
   pre-existing closure-capture bug exacerbated by tc_expr's size, OR a
   genuine missing feature in the closure capture for `Vec.method()`
   calls inside large `do->` bodies. Fix would unlock body-wrap for any
   function shape.

## Recommended fix path

Investigate (3) — the QZ0603 cascade has been seen elsewhere (the same
warnings are emitted on `effect_func_row_spec`, `effect_decl_spec`,
`effect_inference_spec` compile-side, all of which segfault — see
session notes in `docs/handoff/phase-5-1-diagnostics-effect-overnight.md`
"Honest caveats" section). It looks like a single underlying bug in the
typechecker's closure-body type inference. Fix that bug, body-wrap
becomes universally safe.

## Related

- `5.1.N.3` (`f24a3b7a`) — tc_stmt body-wrap that worked. Compare with
  the failing tc_expr attempt to isolate what's different.
- `docs/design/DIAGNOSTICS_EFFECT.md` — Phase 5.1 design memo.
- `docs/handoff/phase-5-1-diagnostics-effect-overnight.md` — overnight
  session close-out.
