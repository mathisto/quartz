# INFER_TYPE_PARAM_MAPPING_WRAPPED_PARAMS

## Status

**CLOSED 2026-05-04** (call-site param unification — first layer).
**Deeper consumers CLOSED 2026-05-05** (`4c6ecb7c`) — once wrapped-param
inference was correctly binding tp-vars at the call, three downstream
leaks still erased the binding before it reached match-arm payload
field access. Full chain documented at
`feedback_three_layer_typearg_leak.md`; regression coverage at
`spec/qspec/generic_payload_field_access_spec.qz` (5 shapes including
the cards example's exact 3-tuple return at position [2]).

`tc_infer_type_param_mapping` (typecheck_generics.qz:414) now recursively
unifies a parameter annotation against an argument's inferred annotation
via a new `tc_unify_param_ann` helper. Wrapped (`Vec<T>`), nested
(`Vec<HashMap<K, V>>`), and multi-param (`HashMap<K, V>`) shapes all
bind their type params correctly. Four load-bearing pieces:

1. **Recursive unification** — bare-T case binds directly; wrapped
   case strips the outer `Base<...>` and recurses on each comma-split
   inner pair using the depth-aware `tc_extract_nth_type_arg`.
2. **Depth-aware param-annotation splitter** — the outer comma-split
   in `tc_infer_type_param_mapping` now tracks `<>` depth so
   `HashMap<K, V>,Int` doesn't get sliced as `["HashMap<K", " V>",
   "Int"]`.
3. **Module-qualifier-tolerant base match** —
   `tc_strip_module_qualifier` strips `a::b::` and `a$b$` prefixes so
   cross-module use sites (`List<Item>` callee vs `ls::List<String>`
   caller) unify.
4. **User-annotation respect** — at NODE_LET handling
   (typecheck_walk.qz ~line 2611), when the user wrote
   `var msg: tui::FrameMsg<SpecMsg> = ...`, the literal annotation now
   overrides init-derived `type_ann` if the latter lost the type args.
   Generalization of the existing `Fn(...)` carve-out at line 2602.

Regression spec: `spec/qspec/wrapped_param_inference_spec.qz` covers
five shapes (Vec<T>+String, Vec<T>+Int, HashMap<K, V>, nested
Vec<HashMap<K, V>>, mixed bare+wrapped in same fn). The downstream
`spec/qspec/tui_list_spec.qz` regression closes in the same stroke
(29/29 green) — `feed_key`/`feed_event` previously failed at
`return triple.0` / `triple.2` because `list_update<I, M>(l: List<I>,
msg: FrameMsg<M>)` couldn't bind I or M from the cross-module call.

Sister sub-bug filed:
`CONCRETE_GENERIC_AT_NON_GENERIC_STRUCT_FIELD.md` — non-generic struct
holding a `Generic<Concrete>`-annotated field still fails struct-init
when the value comes from a wrapped-param-inference call (blocks the
cards example dogfood; Int-handle ceremony stays until that closes).

Originally filed 2026-05-04 alongside v0.3.3 step 2 (Card-style
multi-row List delegate). Follow-up to closed
`done/CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED.md`.

## Symptom

`tc_infer_type_param_mapping` (typecheck_generics.qz:338) only matches
when a function's param annotation is *exactly* a type-param name
(`def f<T>(x: T)` works; `def f<T>(xs: Vec<T>)` does not). For the
wrapped-param shape, no concrete type arg is recovered, the call's
return TypeId stays at `TYPE_ERROR` for the inner generic arg, and any
consumer annotating `Generic<Concrete>` against the call result hits
`QZ0200: expected unknown, got unknown`.

The closed sister bug closed the inference path for *bare* type-param
params. Wrapped params (`Vec<T>`, `List<Item>`, `FrameMsg<M>`,
`HashMap<K, V>`) are the next, broader layer of the same bug.

## Repro

```qz
struct GBox<T>
  v: Vec<T>
end

def gbox_unwrap<T>(b: GBox<T>): GBox<T> = b

struct State
  box: GBox<String>
end

def main(): Int
  var b = GBox<String> { v: vec_new<String>() }
  var u = gbox_unwrap(b)            # inference; param is GBox<T>, NOT bare T
  var s = State { box: u }          # ← QZ0200: expected unknown, got unknown
  return 0
end
```

Workaround (until fix lands): explicit type args at the call site
(`gbox_unwrap<String>(b)`), or `Int`-handle ceremony with
`as_type<GBox<String>>(...)` recovery at use sites.

## Severity

Medium-high. Every v0.3.x widget consumer that wants to drop the
`Int`-handle ceremony hits this. `examples/tui/widgets/cards/main.qz`
(v0.3.3 step 2) currently keeps the Int-handle workaround for this
reason, even though the closed sister bug landed the same day.

## Direct downstream surface — `tui_list_spec.qz` regression

The existing `spec/qspec/tui_list_spec.qz` helpers `feed_key` and
`feed_event` (lines 24-34) fail QZ0200 at `return triple.0` and
`return triple.2` since commit `38714497` (Generic enum payload
preserves type-arg through tuple boundary). The breakage was hidden
by `.quartz-cache` pollution until 2026-05-04.

`triple = ls::list_update(l, msg)` has params `(List<Item>,
FrameMsg<M>)` — both wrapped. Inference returns `""`, so the call's
return TypeId carries `TYPE_ERROR` for `Item`. After 38714497,
`tc_expr_field_access` for tuples uses the full ptype (preserving the
`TYPE_ERROR` inner), so `triple.0` returns `ptype(STRUCT, List,
TYPE_ERROR)`. The function's annotated return `ls::List<String>`
resolves to `ptype(STRUCT, List, TYPE_STRING)` and the mismatch
surfaces as QZ0200.

Pre-38714497 the tuple-elem path probably collapsed to bare
`TYPE_ERROR`, which `tc_types_match` short-circuits to `true` —
hiding the bug. 38714497's fix is correct in isolation but exposes
this case.

Closing this wrapped-param inference bug closes the list_spec
regression in the same stroke (Item resolves to String at the call,
TypeIds match).

## Hypothesis / fix shape

Extend `tc_infer_type_param_mapping` (typecheck_generics.qz:338) to
recursively unify wrapped param annotations against the corresponding
arg's inferred annotation:

```
unify(pa_name, arg_ann):
  if pa_name in tp_names:
    tp_concrete[idx_of(pa_name)] = arg_ann
    return
  if pa_name has shape Base<P1, ..., Pk>:
    if arg_ann has shape Base<A1, ..., Ak>:
      for i in 0..k: unify(Pi, Ai)
```

Edge cases: nested generics (`Vec<HashMap<K, V>>`), tuple-shaped
params, `impl Trait` params, type-param bounds (`<T: Eq>`).

Likely 30-60 lines of additional matching logic in
`tc_infer_type_param_mapping`. Existing depth-aware comma splitting
in `tc_extract_nth_type_arg` is the right utility for parsing the
inner args.

## Discoverability

- v0.3.3 cards example (`examples/tui/widgets/cards/main.qz`)
  documents the Int-handle workaround inline.
- v0.3.2 list example (`examples/tui/widgets/list/main.qz`) does the
  same for the same reason.
- `feedback_quartz_cache_pollution.md` — pattern-recognition: when
  spec failures appear/disappear across binary swaps, check
  `.quartz-cache` first.

## Related

- `done/CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED.md` — closed
  sister fix for bare type-param params. This bug is the wrapped
  generalization.
- `done/CONCRETE_GENERIC_AT_TYPE_ANNOTATION_REJECTED.md` — closed
  predecessor (explicit type args path).
- `done/GENERIC_ENUM_PAYLOAD_ERASES_TO_INT.md` — same family;
  enum-payload erasure across the match-arm boundary.
- `QZ0200_DIAG_FORMATS_STRUCT_PTYPES_AS_UNKNOWN.md` — orthogonal but
  consistently co-occurring (the "expected unknown, got unknown"
  message that makes diagnosing this family painful).
