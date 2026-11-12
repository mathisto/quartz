# CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED

## Status

**CLOSED 2026-05-04.** Inference-only call sites now substitute the
function's type params with concrete args inferred from argument types,
mirroring the explicit-args path. `tc_expr_call` (after the existing
`_ci_call_type_arg` lookup) falls back to
`tc_infer_type_param_mapping(tc, ast_storage, _ci_func_tp,
_ci_param_anns, _ci_args_vec)` and substitutes via
`tc_substitute_annotation` when the call carries no explicit type args.
A new `NODE_ENUM_ACCESS` handler in `tc_infer_expr_type_annotation`
returns the enum's base name (e.g. `FocusId::A` → `"FocusId"`) so the
mapper can match a no-payload enum-variant arg against a type-param-
shaped param annotation (`initial: Id`).

Regression spec: `spec/qspec/concrete_generic_inferred_spec.qz` covers
struct-field, var, and return-type annotation positions on the
inference-only call path. The repro from this doc (FocusRing field with
inference-only construction) now compiles clean.

Filed 2026-05-04, follow-up to closed
`done/CONCRETE_GENERIC_AT_TYPE_ANNOTATION_REJECTED.md`.

The closed bug fixed `Generic<Concrete>` annotations at consumer sites
(struct field, return type) when the value flowing into the annotated
position came from a generic function call with **explicit type args**
(`focus_ring_with_initial<FocusId>(ids, A)`). The fix substitutes the
function's type params with the call's concrete args in the registered
return annotation. Closed regression spec verifies the explicit-args
path.

**Inference-only call sites still fail** with the same diagnostic. If
the same generic function is invoked without explicit type args
(`focus_ring_with_initial(ids, A)`), inference resolves the local
binding's type, but the return TypeId in the global registry stays at
`(STRUCT, TYPE_ERROR, 0)`. The consumer's `Generic<Concrete>` field
annotation resolves to `(STRUCT, TYPE_FOCUSID, 0)`. `tc_types_match`
rejects.

**Severity:** Medium — every Quartz user expects type inference to be
the default mode and explicit type args to be the opt-in. Today the
defaults are inverted: explicit type args work, inference doesn't, on
this specific cross-module / annotated-field path.

**Surface:** typecheck (call-site type-arg substitution).

**Trigger frequency:** Every parent struct that holds a generic-
instantiation field whose value comes from an inference-only call.
Every place a v0.3.3+ consumer wants to drop the Int-handle workaround.

## Repro

```qz
import * from prelude
import * from std/traits
import std/tui/widgets/focus as fr

enum FocusId
  A
  B
end

extend FocusId with Eq
  def op_eq(self, other: Self): Bool
    match self
      A => return other is A
      B => return other is B
    end
  end
end

struct M
  ring: fr::FocusRing<FocusId>      # both `fr::FocusRing<FocusId>`
end                                  # and bare `FocusRing<FocusId>` fail

def main(): Int
  var ids = vec_new()
  vec_push(ids, FocusId::A)
  vec_push(ids, FocusId::B)
  # NO explicit type args — fails
  var ring = fr::focus_ring_with_initial(ids, FocusId::A)
  var m = M { ring: ring }
  return 0
end
```

Diagnostic:
```
error[QZ0200]: Field ring: expected unknown, got unknown
  --> 27:11
27 |   var m = M { ring: ring }
   |           ^
```

Workaround: spell the call with explicit type args.
```qz
var ring = fr::focus_ring_with_initial<FocusId>(ids, FocusId::A)  # works
```

## Hypothesis

The closed fix lives at the call-site path that already had the
concrete type args available. Type-arg inference happens elsewhere in
typecheck, and the inference path doesn't loop back to the same
return-TypeId substitution. The real fix is to invoke the same
substitution after inference resolves T.

Likely location: `self-hosted/middle/typecheck_generics.qz` —
wherever inferred type args are bound, run the same return-type
substitution as the explicit-args path.

## Discoverability

- v0.3.2 widget examples (`examples/tui/widgets/save_screen/main.qz`,
  `examples/tui/widgets/list/main.qz`) document the Int-handle
  workaround for the broader class.
- TUI v0.3.2 design memo Q11 — three failure modes of generic-typed
  fields, of which this is the one not yet covered.
- v0.3.3 Form composer will hit this on every focusable child.

## Risk if unfixed

Form composer (v0.3.3 step 1) will either inherit the Int-handle
ceremony or require every consumer to spell explicit type args at
every generic-function call. The latter scales linearly with depth of
generic nesting and is louder than the current Int handle workaround.
