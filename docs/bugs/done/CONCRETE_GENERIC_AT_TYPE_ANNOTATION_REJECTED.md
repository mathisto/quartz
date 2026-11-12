# CONCRETE_GENERIC_AT_TYPE_ANNOTATION_REJECTED

## Status

**CLOSED 2026-05-04.** Root cause was at the call site, not the
annotation resolver. `tc_parse_type` only recognises
`tc.scope.trait_type_params` as type-param names, not function-level
type params, so when a generic function `def make_g<T>(): G<T>` had
its return type registered, the inner `T` inside `G<T>` resolved to
`TYPE_ERROR`. The outer ptype `(TYPE_STRUCT, TYPE_ERROR, 0)` was then
stable across reads — but a consumer annotating `G<String>` got
`(TYPE_STRUCT, TYPE_STRING, 0)`, and `tc_types_match` rejected the
mismatch under the existing TYPE_STRUCT-with-different-arg1 branch
(typecheck.qz:1763).

Fix: at the call site for a generic function with explicit type args
(`make_g<String>()`), substitute the function's type params with the
call's concrete args in the registered return annotation and re-parse
to a TypeId. The call's return type now matches the consumer's
annotated type at return-type and struct-field positions.

Regression spec: `spec/qspec/concrete_generic_at_annot_spec.qz` covers
return-type annotation, struct field annotation, and the unchanged
inferred-return form.

**Inference-only call sites still fail** (out of scope for this fix —
filed as follow-up). If a generic function is invoked without explicit
type args (`focus_ring_with_initial(ids, A)`, relying on inference),
the return TypeId carries `T = TYPE_ERROR` and any consumer annotating
a `Generic<Concrete>` field in front of that value sees the same
"expected unknown, got unknown" QZ0200 mismatch. **Workaround at
consumer sites:** spell the call with explicit type args
(`focus_ring_with_initial<FocusId>(ids, A)`). Verified 2026-05-04 in
`/tmp/dogfood/scratch.qz` — adding `<FocusId>` flips the same code from
QZ0200 to clean. Real fix would propagate inferred T into the same
substitution path. Tracking: needs separate bug doc when v0.3.3+
consumers hit the friction.

**Filed:** 2026-05-04 (TUI v0.3.2 steps 5-6)
**Severity:** Medium — high-frequency footgun, forces `Int` handle workaround at every parent struct that wants typed children
**Surface:** typecheck (type-annotation resolver)
**Trigger frequency:** Every parent struct that holds a generic-instantiation field, every function that returns a generic instantiation.

## Symptom

A type *annotation* of the form `Generic<Concrete>` (e.g. `List<String>`,
`G<Int>`, `FocusRing<SaveFocus>`) at any of the following positions is
rejected by typecheck with the diagnostic "expected unknown, got
unknown":

1. **Function return-type annotation:** `def f(): G<String> ...`
2. **Struct field type:** `struct State { items: G<String> }`
3. **Var type annotation:** likely (not separately verified).

The same generic instantiation works at *expression* positions
(constructor literal, function call type-arg). Inferred return types
also work — only the explicit annotation form fails.

This forces consumers to drop annotations entirely (when type inference
suffices) or to fall back to the underlying `Int` handle type
(documented workaround in v0.3.2 at
`examples/tui/widgets/list/main.qz:16-25` and
`examples/tui/widgets/save_screen/main.qz:38-42`).

## Repro #1 — Return-type annotation

```qz
struct G<T>
  v: Vec<T>
end

def make_g<T>(): G<T>
  return G<T> { v: vec_new<T>() }
end

def make_annot(): G<String>          # FAILS
  return make_g<String>()
end

def make_inferred()                  # works — same body, no annotation
  return make_g<String>()
end

def main(): Int
  var a = make_annot()
  var b = make_inferred()
  puts(a.v.size.to_s())
  puts(b.v.size.to_s())
  return 0
end
```

Diagnostic:
```
error[QZ0200]: Return type mismatch: expected unknown but got unknown
  --> 13:10
13 |   return make_g<String>()
   |          ^
```

## Repro #2 — Struct field type

```qz
struct G<T>
  v: Vec<T>
end

def make_g<T>(): G<T>
  return G<T> { v: vec_new<T>() }
end

struct State
  cards: G<String>           # FAILS
  status: String
end

def main(): Int
  var s = State { cards: make_g<String>(), status: "ok" }
  puts(s.status)
  return 0
end
```

Diagnostic:
```
error[QZ0200]: Field cards: expected unknown, got unknown
  --> 19:11
19 |   var s = State { cards: make_g<String>(), status: "ok" }
   |           ^
```

## Observed

- Both diagnostics resolve both sides of the type comparison to
  "unknown" — meaning the type-annotation resolver returns an empty/
  unset placeholder for `G<String>`.
- Inferred-return and runtime-handle (`Int`) workarounds compile
  cleanly.

## Expected

Concrete generic instantiations at type-annotation positions should
resolve identically to the same form at expression positions.

## Hypothesis

Quartz's type-name resolver has a pipeline split between expression-
position type elaboration (which handles `Generic<T>(args)` correctly)
and annotation-position resolution (which probably calls a different
helper that doesn't recognize the `<T>` suffix on generic structs and
falls through to "unknown").

Likely location: somewhere in `self-hosted/middle/typecheck.qz` or
`typecheck_walk.qz`'s annotation-elaboration helpers, looking for a
helper that returns `""` (empty string for "unknown") when given a
`Generic<Concrete>` annotation. The typecheck_helpers/typecheck_generics
modules are also good places to check.

Sibling: NODE_LET stores its init in `lefts` not `rights` —
`feedback_ast_let_init_left_slot.md`. Tells us that AST slot-confusion
or similar parser/typecheck mismatches are a recurring pattern.

## Discoverability

- `examples/tui/widgets/list/main.qz:16-25` documents this in a comment
  next to the `cards: Int` workaround.
- `examples/tui/widgets/save_screen/main.qz:38-42` same.
- Q11 of the TUI v0.3.2 design memo discusses the workaround in detail.

## Risk if unfixed

Every parent widget in TUI v0.3.3+ inherits this workaround. The
deckbuilder will hit it on every screen with typed children. Each
workaround costs ~6 lines of `var t: TextInput = as_type<TextInput>(handle)`
ceremony per access (sister `as_type<alias::Type>` form once blocked
this same path; closed 2026-05-04, see
`done/AS_TYPE_MODULE_QUALIFIED_CODEGEN_FAIL.md`).

## Related

- `done/AS_TYPE_MODULE_QUALIFIED_CODEGEN_FAIL.md` (CLOSED 2026-05-04) —
  the `as_type<alias::Type>(handle)` form is now supported.
- `GENERIC_ENUM_PAYLOAD_ERASES_TO_INT.md` — separate generic-erasure
  bug, possibly shares root cause.
- `feedback_quartz_module_quirks.md` (memory) — `Vec<T>` element type
  loss with silent wrong-struct field resolution; same family.
