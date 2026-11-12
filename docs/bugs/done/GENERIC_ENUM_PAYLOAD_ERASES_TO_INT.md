# GENERIC_ENUM_PAYLOAD_ERASES_TO_INT

## Status

**CLOSED 2026-05-04.** Three orthogonal bugs co-occurred — the bug
doc's hypothesis (match-arm pattern resolver not consulting scrutinee
type args) was wrong; the resolver was already correct. The actual
chain of failures:

1. `tc_substitute_annotation` only handled the `Base<...>` shape, so
   it mis-sliced tuple types like `(Int, Ev<T>)` (the trailing `)` was
   left inside the inner slice). Fixed: added a tuple branch that
   peels the outer parens before substituting elements.

2. `tc_make_tuple_type` interned by `(arity, 0)` alone — any two
   N-tuples shared a TypeId, so the second N-tuple silently kept the
   first's element-types vector. Fixed: linear scan to dedupe by
   element-types content; on miss, allocate a fresh ptype slot keyed
   by `(base, arity, slot_index+1)` so each distinct tuple shape gets
   a unique TypeId.

3. `tc_expr_field_access` collapsed the object's ptype to its base
   kind (TYPE_TUPLE) before the tuple-positional-access branch
   checked `>= PTYPE_BASE`. The check failed and `pair.0` / `pair.1`
   always returned TYPE_INT, regardless of the per-element types
   stored on the ptype. Fixed: keep the uncollapsed `object_type_full`
   and use it for the elem-type lookup.

`tc_types_match` was also taught to recurse into TYPE_TUPLE element
types so the annotation's ptype tuple (with concrete-typed elements)
compares equal to the body-constructor's ptype tuple (whose enum
constructor calls return bare TYPE_ENUM).

Regression spec: `spec/qspec/generic_enum_payload_spec.qz` covers the
direct generic-fn call, the tuple-wrapped generic-fn call, and the
inline-annotated tuple — all three previously failed with "got Int"
at `vec_push(v, item)`.

**Filed:** 2026-05-04 (TUI v0.3.2 step 5)
**Severity:** Medium — typecheck-only (runtime is fine via i64-erasure), but forces `as_String(...)` coercion at every match arm body
**Surface:** typecheck (cross-module generic enum monomorphization)
**Trigger frequency:** Every match-on-generic-enum across module boundary that wants to use the payload as anything but Int.

## Symptom

When a generic enum `Ev<T>` is constructed in module A (with `T`
instantiated to a concrete type like `String`) and matched in module
B, the destructured payload variable in the match arm is typed as
`Int` instead of the concrete type. Runtime is correct (i64-erasure
makes `String` and `Int` interchangeable at the bit level), so simple
echo cases like `puts(item)` print correctly — but any context that
*requires* the concrete type (passing to `vec_push` on a typed Vec,
calling string methods on the local) fails typecheck.

## Repro

```qz
# evlib/ev.qz
enum Ev<T>
  Idle
  Selected(item: T)
end

def make_pair<Item>(x: Item): (Int, Ev<Item>)
  return (1, Ev::Selected(x))
end
```

```qz
# main.qz
import * from evlib/ev

def main(): Int
  var pair = make_pair<String>("hello")
  var ev = pair.1
  var v = vec_new<String>()
  match ev
    Idle           => puts("idle")
    Selected(item) =>
      vec_push(v, item)             # FAILS: item typed as Int
      puts(v[0])
  end
  return 0
end
```

Diagnostic:
```
error[QZ0200]: vec_push: expected element type String (from Vec<String>), got Int
  --> 14:7
14 |       vec_push(v, item)
   |       ^
```

## Observed

- Within a *single compilation unit* (no module boundary), the payload
  type is preserved correctly — see `/tmp/qz-bugbash/10_enum_payload_erasure.qz`,
  where `puts(item)` after `Selected(item)` works because the typecheck
  has full visibility of `Ev<String>`.
- Across a module boundary, `make_pair<String>` returns `(Int, Ev<Item>)`
  where `Item` is the function's type parameter. The caller resolves
  the call as `(Int, Ev<String>)` for the function-call return type, but
  the enum's payload `T` doesn't substitute through the match arm
  pattern.

## Expected

`Selected(item)` in a match on `ev: Ev<String>` should bind `item:
String`, regardless of whether `ev`'s producer was in the same compilation
unit.

## Hypothesis

The match-arm pattern resolver looks up the variant's declared payload
type from the enum's *unsubstituted* template (where `T` is a type
parameter), then maps the unresolved `T` to its erased-runtime type
(`Int`) instead of substituting from the scrutinee's instantiated type
arguments.

Likely location: `typecheck_match.qz` (pattern destructure logic).
Specifically, where the variant's payload type is propagated into the
destructure binding. The substitution map from generic params → concrete
args is probably available on the scrutinee's type (`Ev<String>` carries
the args), but the destructure binder isn't consulting it.

## Workaround

Coerce after destructure:

```qz
Selected(item) =>
  var s_item = as_string(item)        # coerce Int → String at the i64-erasure boundary
  vec_push(v, s_item)
  puts(v[0])
```

In `examples/tui/widgets/list/main.qz:108-117` this shows up as
`var s_card = as_string(card)` immediately after `Selected(card) =>`.

## Discoverability

- `examples/tui/widgets/list/main.qz:108-117` documents the workaround
  in a comment.
- v0.3.2 step 5 commit message lists this as friction surface #5.

## Risk if unfixed

Every match arm on a generic-enum payload (e.g. ListEvent<Item>::Selected,
Future events, Result<T, E>) needs an inelegant `as_X(local)` coercion.
Stylistically out of place; deckbuilder will hit it constantly.

## Related

- `feedback_quartz_module_quirks.md` (memory) — Vec<T> element type loss,
  same generic-substitution-across-boundary family.
- `done/CONCRETE_GENERIC_AT_TYPE_ANNOTATION_REJECTED.md` (CLOSED 2026-05-04)
  — sister generic-resolver bug; root cause turned out to be call-site
  return-type substitution, not the annotation resolver. Same family.
