# Struct field-access on local-copied struct mis-dispatches as method call

**Filed:** 2026-05-07. Surfaced while diagnosing JSON_SPEC_PARSE_REGRESSIONS.
**Severity:** High — silently produces wrong runtime values; was the entire root cause of the json regression family.
**CLOSED:** 2026-05-08. Fix in `self-hosted/middle/typecheck_walk.qz` NODE_LET Region 1: added `init_kind == NODE_FIELD_ACCESS` case that propagates struct identity via `tc_infer_expr_type_annotation` (which already chains correctly through field access). Without it, `var t = h.current` left `struct_name=""` on the binding, so `t.kind` later took B.6's empty-struct-name branch in `tc_expr_field_access` and elided to method dispatch — finding `kind` as a free function via the auto-imported trait `Error` (`std/error.qz:23`) and rewriting to `kind(t)`, which `tc_expr_call` resolved to `SimpleError$kind`. Repro: any `var x = expr.field` where the field's struct has a method-named field that collides with an in-scope free function. json was the most-touched victim. Fixpoint clean (2146 functions byte-identical), Rule 2 smokes pass, json/method-call/UFCS specs green.

## Summary

When a struct field is read through a local-var copy of another struct's field, and the inner field's type is a unit-only enum (`JsonTokenKind` in the live case), the typecheck/codegen path resolves `t.kind` as a *method call* to an unrelated trait/enum (`SimpleError$kind`) instead of as a struct field load. Direct chained access (`p.current.kind`) works correctly.

## Live repro (the path that broke json)

`std/json.qz` had the helper:

```qz
def json_parser_get_kind(parser: JsonParser): Int
  var token = parser.current
  return token.kind
end
```

`parser.current` is a `JsonToken`; `JsonToken.kind` is `JsonTokenKind` (a unit-only enum). At runtime this returns garbage (a heap pointer like `4374170344`), not the discriminant.

The fix in `std/json.qz` was to switch to chained access: `return parser.current.kind`. That works.

## Codegen evidence

The IR for the broken pattern emits a method-dispatch call instead of a struct GEP+load:

```
%v0 = load i64, ptr %p, align 8
%loptr_1 = inttoptr i64 %v0 to ptr
%logep_1 = getelementptr inbounds i64, ptr %loptr_1, i64 1
%v1 = load i64, ptr %logep_1, align 8     ; loads parser.current correctly
store i64 %v1, ptr %t, align 8
%v2 = load i64, ptr %t, align 8
...
%v4 = tail call i64 @SimpleError$kind(i64 %v2)   ; <-- WRONG: dispatches to SimpleError method
ret i64 %v4
```

`SimpleError` is a prelude type that has a `kind()` method. The local var `t` lost its `JsonToken` struct type during typecheck, and the method-resolution fallback found `SimpleError$kind` as a global with matching name.

## Hypothesis on the typecheck bug

`var t = parser.current` should bind `t: JsonToken`. Either:

1. The var-binding stamp drops the struct name (similar shape to the
   "three-layer type-arg leak" memo from 2026-05-05), or
2. The `.kind` resolver for a struct-typed local with a unit-only-enum
   field falls through field-resolution to method-resolution.

Annotating the local explicitly (`var t: JsonToken = parser.current`) does *not* fix it — same wrong dispatch — which suggests the failure is in `.kind` resolution, not in the var binding. The resolver finds a free function / impl method named `kind` somewhere in scope and dispatches to it before checking struct fields.

## Why json was the trigger

`SimpleError` is a prelude type. Any module that imports the prelude AND has a struct with a `kind` field will hit this if it copies the struct to a local first. json was just the most-touched victim.

## Suggested fix

In `typecheck_expr_handlers.qz`'s field-access resolver: for a receiver typed as `TYPE_STRUCT`, exhaust struct-field lookup BEFORE falling through to UFCS/method dispatch. Today it appears the order is reversed (method dispatch wins, struct field is the fallback) — or the local-var's struct name is lost so field lookup doesn't even attempt.

## Out of scope

- The json fix (`std/json.qz`) is in tree as a separate commit — workaround,
  not the underlying compiler fix.
- Minimal repro outside `std/json.qz` failed to compile due to an unrelated
  codegen bug (`use of undefined value '@.str.56'` in struct-literal emission
  with unit-only enum constructor). Worth filing if it reproduces in another
  surface, but did not block diagnosing this bug.

## Discoverability

Surfaced 2026-05-07 while investigating JSON_SPEC_PARSE_REGRESSIONS. The original `json_parser_get_value` / `json_parser_get_kind` helpers had a comment "workaround for nested field access type issue" — the workaround pattern itself is now broken. The comment lineage suggests an older version of the same dispatch-order bug existed and was patched at the call sites instead of in the resolver.
