# CONCRETE_GENERIC_AT_NON_GENERIC_STRUCT_FIELD

## Status

**CLOSED 2026-05-04** (struct-init field check) — first layer of fix.
**Deeper layer CLOSED 2026-05-05** (`4c6ecb7c`) — when the Generic<Concrete>
field is initialised from a generic call's inferred return, three additional
sites had to thread the type-arg through: var-binding scope ann, user-enum
ptype name stamp, and match-arm pattern binding's struct identity recovery.
See `feedback_three_layer_typearg_leak.md` and the regression spec at
`spec/qspec/generic_payload_field_access_spec.qz` for full coverage of the
sub-shapes.

Root cause was NOT what the original hypothesis below suggested —
`tc_parse_type` resolves `List<Card>` and `ls::List<Card>` to the same
ptype already. The real issue: `tc_infer_expr_type_annotation` for a generic
call whose own inference failed was returning the raw `ret_ann` with
type-param names still in it (`ItemDelegate<Item>`). When that string flowed
into the OUTER call's unifier as an arg's annotation, the outer
unifier saw `pa_name="ItemDelegate<Item>"` vs
`arg_ann="ItemDelegate<Item>"`, matched bases via the wrapped-base
recursion, and bound `Item := "Item"` (the literal string), silently
clobbering a correct binding from another arg.

Cards example concretely:
`list_new<Item>(items: Vec<Item>, delegate: ItemDelegate<Item>)`.
- arg 1 (`make_cards()`) returns `Vec<Card>` → unifier binds
  `Item := Card`. ✓
- arg 2 (`item_delegate_card(show_card, 3)`) is itself a generic call
  whose own inference failed. Pre-fix, that inner call returned
  literal `"ItemDelegate<Item>"`. The outer unifier matched bases
  (`ItemDelegate` vs `ItemDelegate`) and recursed:
  `unify("Item", "Item")` → bare match → `Item := "Item"` overwrites
  `Item := Card`.
- Substituted return: `List<Item>` (literal). Parsed to a ptype
  carrying `Item` as inner — different ptype from State's
  `List<Card>` field. `tc_types_match` rejected.

Fix: `tc_infer_expr_type_annotation` (typecheck_generics.qz:222) now
returns `""` instead of the raw `ret_ann` when a generic call's
inference fails. Empty arg_ann short-circuits the outer unifier
(`return if str_byte_len(arg_ann) == 0`), so the leak doesn't
clobber sibling-arg bindings.

Regression coverage: `examples/tui/widgets/cards/main.qz` now stores
`cards: List<Card>` directly — no Int-handle ceremony, no
`as_type<List<Card>>(s.cards)` recovery on field reads. Binary
runs end-to-end (TUI displays card list, navigation works).
21 generic + TUI specs all green; fixpoint verified at 2143 funcs.

Filed 2026-05-04. Sister sub-bug discovered while dogfooding the
closed `done/INFER_TYPE_PARAM_MAPPING_WRAPPED_PARAMS.md` fix in
`examples/tui/widgets/cards/main.qz`.

## Symptom

A non-generic struct with a field annotated `Generic<Concrete>` rejects
struct-init when the value flowing into the field comes from a generic
function call whose return type is `Generic<T>`. Both sides resolve to
real ptype IDs, but they don't unify and `tc_types_match` returns false.
Diagnostic surfaces as the family's familiar
`QZ0200: expected unknown, got unknown`.

## Repro

```qz
import std/tui/widgets/list as ls

struct Card
  name: String
end

struct State
  cards: List<Card>     # also fails as `ls::List<Card>`
end

def main(): Int
  var v = vec_new<Card>()
  vec_push(v, Card { name: "Strike" })
  var cards = ls::list_new(v, ls::item_delegate_card(c -> c.name, 1))
  var s = State { cards: cards }   # ← QZ0200 here
  return 0
end
```

Workaround: keep the `Int`-handle ceremony — `cards: Int` field, store
via `as_int(cards)`, recover via `as_type<ls::List<Card>>(s.cards)` at
read sites. This is the existing v0.3.x widget pattern; the cards
example documents it inline.

## Severity

Medium. Blocks the v0.3.x widget consumer dogfood: every example that
holds a generic widget value in a non-generic State struct field hits
this. It's the second of two layers needed to drop the Int-handle
ceremony entirely (the first layer — call-site type-arg inference for
wrapped params — closed in
`done/INFER_TYPE_PARAM_MAPPING_WRAPPED_PARAMS.md`).

## Hypothesis

`cards`'s annotation after the call chain is `List<Card>` (bare,
unqualified — `list_new` is defined in `std/tui/widgets/list` so its
return uses the bare base name). The State field annotation is
`List<Card>` or `ls::List<Card>` (depending on what the user writes).
Both parse to ptype IDs via `tc_parse_type`. The mismatch suggests one
of:

1. `tc_parse_type("ls::List<Card>")` and `tc_parse_type("List<Card>")`
   yield different ptype IDs (registry treats `List` and `ls::List` as
   distinct, even when the alias resolves to the same struct). The fix
   would be in the resolver/parser path that interns these.
2. `cards`'s actual_type carries some erased / wrong-type-args inner
   that doesn't match the parsed field annotation. Trace the actual_type
   computation in `tc_check_struct_init_fields` (typecheck_generics.qz
   ~line 894) — what TypeId does `cards` carry when it reaches the
   field check?

The closed wrapped-param-inference fix (2026-05-04) and the closed
explicit-args fix (`done/CONCRETE_GENERIC_AT_TYPE_ANNOTATION_REJECTED`)
both work for *generic*-struct field cases (struct that itself has type
params). This sub-bug is specifically about a *non-generic* struct
holding a generic-typed field.

## Direct downstream surface

- `examples/tui/widgets/cards/main.qz` — currently keeps `cards: Int`
  with `as_int`/`as_type` ceremony for this reason; documents the
  workaround inline.
- Same shape will surface in any v0.3.x form/composer/list consumer that
  wants a non-generic State struct holding widget values.

## Related

- `done/INFER_TYPE_PARAM_MAPPING_WRAPPED_PARAMS.md` — closed fix that
  unblocked the call-site type-arg inference layer. Discovering this
  sub-bug came from trying to consume that fix.
- `done/CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED.md` — closed sister
  for *generic* struct field annotations on the inference path.
- `done/CONCRETE_GENERIC_AT_TYPE_ANNOTATION_REJECTED.md` — closed
  predecessor for the explicit-args path.
- `QZ0200_DIAG_FORMATS_STRUCT_PTYPES_AS_UNKNOWN.md` — orthogonal but
  consistently co-occurs (the "expected unknown, got unknown" message
  that makes diagnosing this family painful).

## Discoverability

`tc_substitute_field_type` (typecheck_generics.qz:53) is also
wrapped-blind in the same way the closed
`tc_infer_type_param_mapping` was — the bare-only matcher only fires
when the field annotation is exactly a type-param name. This may or
may not be load-bearing here (the current case has no parent type
args to substitute), but worth checking when the fix lands.
