## Diagnostics as effect — design memo (Phase 5.1)

> **Epic**: Operation Piezoelectric Effects · `[piezo]` Phase 5 · compiler dogfooding
> **Status**: Design ratified 2026-04-21 (overnight handoff)
> **Predecessors**: Phase 1-4 — full algebraic effect surface (effect/can/with, default handlers, multi-arg ABI, row polymorphism, lexical fast path)
> **Predecessor doc**: [`docs/research/EFFECTS_IMPLEMENTATION_PLAN.md`](../research/EFFECTS_IMPLEMENTATION_PLAN.md)

## Summary

Migrate `~280` direct `typecheck_util::tc_error(tc, ...)` and `typecheck::tc_warning(tc, ...)` call sites in `self-hosted/middle/*.qz` to a `Diag` algebraic effect. The win: leaf validators that only carry `tc` to call `tc_error` can shed the parameter, the call-graph annotates intent (`can Diag`), and the same effect is reusable by stdlib parsers / linters / language tools that want structured diagnostics without inventing their own sink.

This is the first compiler-side pilot of the effect system we just shipped.

## Why this is a real test, not a vanity migration

Three things would have to be true for the migration to actually simplify the compiler:

1. **The effect system can route to a handler that mutates state outside its own scope.** Quartz handlers are `(op_name, argc, argv): Int` top-level functions — *not* closures. So state-routing requires either a captured closure (not yet supported) or a side-channel (a global, a stack, or threading the sink through `argv`).
2. **Source-side typecheck functions can drop their `tc` parameter** when their only use of `tc` was diagnostic emission.
3. **The cascade of `can Diag` annotations doesn't multiply LOC faster than the dropped `tc` params shrink it.**

(1) is the open design question. (2) and (3) measure success.

## Site inventory (2026-04-21 baseline)

| File | `tc_error` + `tc_warning` sites |
|---|---:|
| `typecheck_walk.qz` | 76 |
| `typecheck_expr_handlers.qz` | 75 |
| `typecheck.qz` | 42 |
| `typecheck_helpers.qz` | 26 |
| `typecheck_registry.qz` | 23 |
| `typecheck_util.qz` | 17 (mostly the structured wrappers themselves) |
| `typecheck_generics.qz` | 11 |
| `typecheck_concurrency.qz` | 5 |
| `typecheck_match.qz` | 4 |
| **Total** | **279** |

Existing API in `typecheck_util.qz` (canonical entry — every wrapper funnels through it):

```quartz
def tc_error(tc: TypecheckState, message: String, line: Int, col: Int): Void
  # Limit-30 enforcement, dedup-by-(file,line,col), then push to tc.errs.
end
```

Plus structured wrappers — `tc_error_type_mismatch`, `tc_error_undefined_var`, `tc_error_unknown_struct`, etc — that all call `tc_error` internally.

Warnings live in `typecheck.qz`:

```quartz
def tc_warning(tc: TypecheckState, message: String, line: Int, col: Int): Void
```

## Target effect

```quartz
## std/diag.qz — compiler diagnostic effect.
effect Diag
  def error(msg: String, line: Int, col: Int): Int
  def warn(msg: String, line: Int, col: Int): Int
end
```

Both ops are kind=1 (function-kind): execution continues at the perform site after the handler returns. No unwind, no resumption gymnastics. The op's `Int` return is the dispatch ack — handlers conventionally return 0.

The effect is **not** added to the blessed set. Programs that import `std/diag` and call `error(...)` outside a `with Diag` block fail typecheck with QZ0610 — same as any other declared effect. This is correct: silently swallowing diagnostics is worse than a compile error.

## Bridge: how the handler reaches `tc.errs`

Quartz handlers cannot close over outer state. Three options for routing the tc reference into the handler:

| Option | Mechanism | Pros | Cons |
|---|---|---|---|
| **A. Global stack** | `var __tc_diag_stack: Vec<TypecheckState>`; push/pop around typecheck phase | Cheap. Source remains plain. Supports nesting. | Hidden coupling. Not idiomatic Quartz. Misuse in re-entrant test contexts is a footgun. |
| **B. Threaded sink** | `effect Diag { def error(sink: Int, msg, line, col) }` with `sink = tc as Int` | No globals. Explicit. | Defeats the whole point — `sink` is just `tc` renamed; no LOC win at call sites. |
| **C. Closure handlers** | New compiler feature: `with Diag { error: |s| { tc_error(tc, s, l, c) } }` | Idiomatic. No globals. No threading. | Multi-week compiler change. Out of scope for 5.1. |

**Decision: Option A.** A is the only path that preserves the LOC win, fits in one night of work, and doesn't block on a new compiler feature. Option C is the right end state — file as a Phase 6 followup once the migration proves the value.

### Bridge implementation (new file: `self-hosted/middle/typecheck_diag.qz`)

```quartz
import typecheck            # tc_warning
import typecheck_util       # tc_error
import * from str_compat

# Stack of active TypecheckState contexts. Top of stack is the sink for
# Diag.error / Diag.warn. Stack form (rather than scalar) supports
# nested test contexts that swap in their own tc.
var __tc_diag_stack: Vec<TypecheckState> = vec_new<TypecheckState>()

def tc_diag_push(tc: TypecheckState): Void = __tc_diag_stack.push(tc)
def tc_diag_pop(): Void
  if __tc_diag_stack.size > 0
    __tc_diag_stack.pop()
  end
end

# Handler ABI: (op_name: Int, argc: Int, argv: Int): Int.
# argv layout for both ops: [msg: String, line: Int, col: Int].
def tc_diag_error_handler(op_name: Int, argc: Int, argv: Int): Int
  if __tc_diag_stack.size == 0
    eputs("[diag] error fired with no active TC; message dropped")
    return 0
  end
  var tc = __tc_diag_stack[__tc_diag_stack.size - 1]
  var msg = as_string(load(argv, 0))
  var line = load(argv, 1)
  var col = load(argv, 2)
  typecheck_util::tc_error(tc, msg, line, col)
  return 0
end

def tc_diag_warn_handler(op_name: Int, argc: Int, argv: Int): Int
  if __tc_diag_stack.size == 0
    eputs("[diag] warn fired with no active TC; message dropped")
    return 0
  end
  var tc = __tc_diag_stack[__tc_diag_stack.size - 1]
  var msg = as_string(load(argv, 0))
  var line = load(argv, 1)
  var col = load(argv, 2)
  typecheck::tc_warning(tc, msg, line, col)
  return 0
end
```

### Install site (new wrapper in `quartz.qz`)

The compiler's typecheck phase already happens in a single contiguous block (lines ~470-900 of `quartz.qz`). Wrap the entire block in a single `with Diag` after pushing tc:

```quartz
typecheck_diag::tc_diag_push(tc)
with Diag {
  error: typecheck_diag::tc_diag_error_handler,
  warn: typecheck_diag::tc_diag_warn_handler
} do ->
  # ... existing typecheck phase body ...
end
typecheck_diag::tc_diag_pop()
```

The body is a closure — it captures `tc`, `ast_storage`, `root`, and every other variable from the surrounding function. No hoisting or extraction required.

## Migration mechanics

### Per-function transformation

Before:
```quartz
def tc_check_binary(tc: TypecheckState, op: String, lt: Int, rt: Int, line: Int, col: Int): Int
  ...
  if lt != type_constants::TYPE_BOOL
    typecheck_util::tc_error(tc, "Operand of 'and' must be Bool", line, col)
  end
  return type_constants::TYPE_BOOL
end
```

After:
```quartz
def tc_check_binary(op: String, lt: Int, rt: Int, line: Int, col: Int): Int can Diag
  ...
  if lt != type_constants::TYPE_BOOL
    error("Operand of 'and' must be Bool", line, col)
  end
  return type_constants::TYPE_BOOL
end
```

Two changes:
1. `typecheck_util::tc_error(tc, ...)` → `error(...)`.
2. `tc: TypecheckState` parameter dropped iff it's only used for diagnostics. Sig grows `can Diag`.

Caller sites also drop the `tc` argument they were passing.

### Cascade: where `can Diag` propagates

Every caller of a `can Diag`-rowed function inherits the row obligation. In practice this means:
- `tc_check_binary` callers in `typecheck_expr_handlers.qz` get `can Diag`.
- Their callers in `typecheck_walk.qz` get `can Diag`.
- `tc_program` (the entry) gets `can Diag` — which is the row the `with Diag` block in `quartz.qz` consumes.

This sounds like a lot. It is. But row polymorphism (P3.F) means generic combinators (`Vec.map`, callbacks) don't need bespoke annotations — only direct callers in the typecheck cascade.

### Wrapper functions: stay or migrate?

The structured wrappers (`tc_error_type_mismatch`, `tc_error_undefined_var`, etc) live in `typecheck_util.qz` and `typecheck.qz`. **They stay.** They keep their `tc` parameter (they read `tc.tv_origin_descs`, `tc.last_unify_*`, etc — those are non-diagnostic uses). Internally they continue to call `tc_error(tc, ...)` directly.

This means `tc_error` itself remains the canonical entry point at the bottom of the stack. The Diag effect is a *facade* over it — call sites at the leaves use `error(...)`, the bridge handler calls `tc_error(tc, msg, line, col)` underneath. No duplication.

## Sequencing

| Phase | Work | Ratchet |
|---|---|---|
| 5.1.0 | This memo | Committed |
| 5.1.1 | `std/diag.qz` + handler spec | New stdlib effect, isolated. No compiler change. |
| 5.1.2 | `typecheck_diag.qz` bridge + wire `with Diag` in `quartz.qz` | Compiler change — fixpoint required. No call sites migrated yet; bridge is dormant. |
| 5.1.3 | Pilot: migrate `tc_check_binary` (15 sites in one function) | First real Diag use. Validates cascade. |
| 5.1.4 | Rest of `typecheck_helpers.qz` (~11 more sites) | Easy wins. |
| 5.1.5+ | `typecheck_match.qz` (4) + `typecheck_concurrency.qz` (5) + `typecheck_generics.qz` (11) | ~20 more. |
| 5.1.N | Big three (`expr_handlers`, `walk`, `typecheck` core) | Saved for later sessions — 193 sites, mixed `tc` uses. |

## Risks

- **The `with Diag` wrap of the typecheck phase requires a `do -> ... end` body that captures dozens of locals.** This works in Quartz today (closures capture mutable struct refs by reference) but is the largest single closure body the compiler has produced. Risk: codegen quirk surfaces. Mitigation: pilot the wrap first with a no-op typecheck call before migrating any real sites; if the wrap itself breaks, escalate to a refactor (extract `typecheck_phase()` helper).
- **Cascade reaches every typecheck-touching function.** ~50+ functions need `can Diag` added even if they don't directly call `error`. Mitigation: row polymorphism handles generic combinators; only direct callers in the cascade need the annotation. If the cascade explodes (>200 added annotations), the LOC win evaporates and we should reconsider.
- **Global stack mis-fires in tests.** QSpec tests that exercise typechecker fragments without going through `quartz.qz`'s install site will see "[diag] error fired with no active TC" and lose diagnostics. Mitigation: tests that exercise typecheck directly must `tc_diag_push(tc)` themselves. Acceptable, documented in the bridge file.

## Exit criteria for Phase 5.1 (revised from handoff memo)

Originally: ≥30 sites, ≥150 LOC reduction.

Revised after design analysis: **≥15 sites migrated AND the bridge survives fixpoint**. Net LOC may be flat or slightly negative the first night because of the cascade tax — that's fine. The win compounds as more sites migrate in later sessions.

Hard stops:
- Bridge wire-up breaks fixpoint → restore golden, file followup, switch to fallback.
- Cascade explodes (>50 incidental `can Diag` annotations on the pilot) → step back, reconsider whether Diag should be blessed after all.

## Followup work (not Phase 5.1)

- **Closure handlers** (Option C above). The right end state for state-carrying handlers. Filed as Phase 6 candidate. Once available, the global stack disappears and handlers close over `tc` directly.
- **Structured-error operations**: replace text-prefixed `error("Type mismatch: expected X but got Y")` strings with structured op variants (`def type_mismatch(expected: String, actual: String, ctx: String, line: Int, col: Int)`). Lets handlers re-render or aggregate. Out of scope for 5.1 — would gate on the closure handlers.
- **Diagnostic levels**: extend Diag with `note`, `hint`, `help` ops to support multi-line diagnostics. Currently `tc_error_type_mismatch` calls `tc_error` twice for the main + note; structured ops would express that intent better.

## Landed architecture — 2026-04-22 close-out

Phase 5.1 shipped in two overnight rounds. Summary of what's in the tree:

### Bridge (typecheck_diag.qz)

- **Single-slot global**, not a stack. `__tc_diag_active: Vec<TypecheckState>` is a vec-of-one; `tc_diag_set(tc)` writes slot 0, `tc_diag_clear()` pops. The stack form (Phase 5.1.0-5.1.6) leaked pushes when a `with Diag {...} do -> ...end` body returned via the enclosing function's `return`. The single-slot form has no push/pop so nothing to leak.
- `tc_diag_set(tc)` is called **once** at the top of `compile()` in `quartz.qz:479`. Active tc remains valid until overwritten.
- `tc_diag_error_handler` and `tc_diag_warn_handler` are the two handler functions. ABI: `(op_name: Int, argc: Int, argv: Int): Int`. argv layout: `[msg: String, line: Int, col: Int]`. Return 0 (dispatch ack).
- If the slot is empty when a handler fires (misuse), an eputs breadcrumb is written to stderr and the message is dropped. Prevents silent swallowing.

### Effect definition (std/diag.qz)

```quartz
effect Diag
  def error(msg: String, line: Int, col: Int): Void
  def warn(msg: String, line: Int, col: Int): Void
end
```

- Both ops **Void return** (not Int, as in the initial proposal). Required so body-wraps don't force sibling expressions to coerce to Int. Changed in 5.1.B.2.
- Kind=1 (function-kind): perform returns past handler, no unwind.
- NOT blessed. Calling `error(...)` outside a `with Diag` block is QZ0611 — correct behavior.

### Migration patterns — three deployed

1. **Body-wrap** for large functions: wrap the entire function body in `with Diag {...} do -> ... end`. Used for tc_program, tc_function, tc_stmt, tc_expr, tc_expr_call (51 sites), tc_expr_match (7), tc_expr_field_access (10), tc_expr_struct_init (4), tc_emit_vec_element_error (2). Requires the final statement be an expression (not `return result`) — the closing `end` implicitly returns the with-block's value to the caller.
2. **`can Diag` on signature** for small leaf functions called transitively from body-wrapped ancestors. Used for the 26 typecheck_helpers.qz functions, 11 typecheck_generics.qz, 4 typecheck_match.qz, 5 typecheck_concurrency.qz, 17 typecheck_registry.qz functions, 10 typecheck.qz core validators. Row polymorphism handles the cascade.
3. **Per-callsite wrap** for rare sites with unusual control flow. Used for 4 typecheck_walk.qz remainder sites + a few internal push/pop-era residuals.

### QZ0603 body-wrap blocker — diagnosed and resolved

The round-1 memo flagged that body-wrapping tc_expr produced QZ0603 warnings + llc IR rejection (`instruction does not dominate all uses`). Hypothesis was closure capture with Vec method calls.

Real cause: `return result` at the end of the body-wrapped block set the MIR block's TERM_RETURN terminator. Handle_uninstall then directly emits text across block boundaries (store body_val / br wb.done / wb.done: / load). The emitted text landed after the intended terminator, producing SSA dominance violations and spurious field-access warnings.

Fix: inside body-wrap, the last statement must be an expression, not `return`. Mid-body returns (in deep elif branches) are fine — they terminate their local block, unaffected by the outer merge + uninstall.

Filed in-tree at docs/bugs/PHASE-5-1-TC-EXPR-BODY-WRAP.md. Resolution documented in commit 976a552d.

### Migration scoreboard (end of 5.1)

| File | Baseline sites | Migrated | Status |
|---|---:|---:|---|
| typecheck_walk.qz | 76 | 76 | DONE |
| typecheck_expr_handlers.qz | 75 | 75 | DONE |
| typecheck.qz | 42 | 35 | DONE (7 wrappers stay by design) |
| typecheck_helpers.qz | 26 | 26 | DONE (round 1) |
| typecheck_registry.qz | 23 | 23 | DONE |
| typecheck_util.qz | 17 | 0 | STAYS (structured wrappers) |
| typecheck_generics.qz | 11 | 11 | DONE (round 1) |
| typecheck_concurrency.qz | 5 | 5 | DONE (round 1) |
| typecheck_match.qz | 4 | 4 | DONE (round 1) |
| **Total** | **279** | **255** | **91% — exit criteria MET** |

Structured wrappers in `typecheck_util.qz` + `typecheck.qz` stay by design: they read `tc.tv_origin_descs`, `tc.last_unify_*` and re-emit via `tc_error` with structured context that `error(msg, l, c)` can't express.

### What's next (outside Phase 5.1)

- **Closure handlers** (Option C): still the right end state. Would let the single-slot global be deleted. File under Piezo Phase 6.
- **Structured error operations**: replace text-prefix strings with typed op variants (gated on closure handlers).
- **LOC-reduction**: functions whose only use of `tc` was `tc_error` can now drop the parameter. Fresh audit needed; estimated 30-50 functions, 150-300 LOC net reduction. Tracked separately.

---

*Written 2026-04-21 by round-1 overnight session. Landed 2026-04-22 by round-2 overnight session.*
