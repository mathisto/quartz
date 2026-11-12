# `is X` doesn't carry Vec-element enum identity into the local binding

**Filed:** 2026-05-06 (follow-up from IS_PREDICATE_CROSS_ENUM_TAG_COLLISION)
**Severity:** Low — silent-correctness regression risk in generic
contexts where the user would otherwise expect `is X` to dispatch
correctly.
**Sister:** `docs/bugs/done/IS_PREDICATE_CROSS_ENUM_TAG_COLLISION.md`
(closed 2026-05-06).

## Summary

After the IS_PREDICATE fix, `var c: Cmd<M> = ...; if c is Quit` works
because the explicit `: Cmd<M>` annotation feeds the enum name into
the binding's `struct_name` slot. But:

```be
var msgs: Vec<FrameMsg<M>> = ...
var msg = msgs[i]            # no annotation; `msg`'s binding doesn't
                              # carry FrameMsg identity
if msg is Quit               # <-- can't validate: tc_scope_lookup
                              # returns "" for msg's struct_name,
                              # falls back to legacy global search
```

The Vec-element-type stored on the Vec ptype isn't propagated to the
`var msg = ...` let-binding's struct_name / type_ann. So a downstream
`is X` predicate against `msg` can't reach the correct enum identity
and falls back to the legacy global registry-wide lookup, which picks
the first enum carrying a variant by that name. In the
`std/tui/runtime.qz` `program_replay` case, that's `Cmd<M>` rather
than `FrameMsg<M>` — wrong tag space.

## Reproducer

```be
enum FrameMsg
  Key(code: Int)
  Quit
end

enum Cmd
  Nope
  Quit
  After(ms: Int, t: Int)
end

def main(): Int
  var msgs: Vec<FrameMsg> = vec_new<FrameMsg>()
  msgs.push(FrameMsg::Quit)
  var msg = msgs[0]
  if msg is Quit
    puts("expected: matched FrameMsg::Quit")
  else
    puts("BUG: didn't match (resolved against Cmd::Quit at tag 1, FrameMsg::Quit is at tag 1 too — depends on order)")
  end
  return 0
end
```

The exact symptom depends on enum-registration order and tag layout —
silent-correctness, not crash.

## Workaround

Annotate the local explicitly:

```be
var msg: FrameMsg<M> = msgs[i]   # now carries identity
if msg is Quit                    # OK
```

Or use a fully-qualified `match` arm.

## Real fix

Extend the `var x = vec[i]` typecheck path to stamp the element-type
struct_name onto the binding, mirroring how generic struct ptype
inits stamp `struct_name`. Likely lives in
`self-hosted/middle/typecheck_walk.qz` near the NODE_LET handler's
`struct_name` derivation block — when the init expression is a
NODE_INDEX whose base has a Vec ptype, lift the element struct_name
from the Vec ptype.

Same shape applies to `Map<K,V>::get`, tuple field access (`pair.0`),
function call returns whose return ann is `Vec<E>` then indexed, and
any other expression that produces an enum value without going
through a NODE_LET annotation.

## Status

- **Closed 2026-05-07.**

## Resolution

`self-hosted/middle/typecheck_walk.qz` NODE_LET handler — added a sister
to the existing IS_PREDICATE_CROSS_ENUM_TAG_COLLISION explicit-annotation
path. The new branch fires when:

1. The binding has no struct_name from the upstream init-shape dispatch
   (which is gated by TYPE_STRUCT and skips TYPE_ENUM by design).
2. The init's resolved type is TYPE_ENUM (or a ptype whose base is).
3. The init AST is a NODE_INDEX whose `str2` slot was stamped by
   `tc_expr_index` with the Vec element struct/enum name.
4. That name resolves to a registered enum.

Then the binding picks up the enum identity, so downstream
`binding is Variant` typechecks against the right variant table and
doesn't fall back to global variant search.

Regression spec at `spec/qspec/is_pred_vec_elem_no_enum_name_spec.qz`
covers three surfaces:
- QZ0231 fires when `is X` names a variant outside the Vec element enum.
- Positive `is Variant` matches when X is in the element enum (no
  annotation needed).
- Cross-enum same-tag siblings (`FrameMsg::ZB` at tag 1 vs `Cmd::Quit`
  at tag 1) no longer silent-match — typecheck rejects with QZ0231
  before MIR-lower's tag-eq check is reached.

The `program_replay` workaround in `std/tui/runtime.qz` can now be
reverted to use bare `is Variant` predicates over Vec<FrameMsg> /
Vec<Cmd> elements without the qualified `match` ceremony.

## Follow-ups

The bug doc's "same shape applies to" list is partially open — covered
by this fix:
- Vec<E>::index — covered.

Not yet covered (file separately if surfaced):
- `Map<K,V>::get(key)` where V is an enum — likely a sister
  NODE_CALL-with-Map-return path; tc_expr_index doesn't run for Map
  fetches (rewritten to `map_fetch` call), so str2 is on the call node,
  not propagated through the existing struct-gated branch.
- Tuple field access (`pair.0`) where the element is an enum — sister
  to the base-kind-collapse-drops-ptype-data feedback memory entry; a
  fix would lift the tuple_elem_type's name onto the let binding when
  init is NODE_FIELD with a numeric index.
- `def f(): Vec<E>; var x = f()[i]` — chained field/index over a call
  return; needs the call-shape branch to also stamp the element name
  for downstream NODE_INDEX consumers.

These three are user-facing only when the consumer uses `is Variant`
without an explicit annotation. Annotating the local
(`var msg: FrameMsg = ...`) is a one-liner workaround.
