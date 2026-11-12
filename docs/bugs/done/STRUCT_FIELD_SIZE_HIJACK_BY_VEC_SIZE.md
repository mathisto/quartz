# `struct.size` field access miscompiled as `vec_size(struct)` after `await fut`

## Status

**Identified during E.4.a slice 3.b spec authoring** (2026-04-29). Pre-existing
typechecker quirk — surfaces only when:
1. A struct has a field literally named `size`.
2. The struct is bound to a variable via `await fut` (or any path that
   loses static type info — Future<T> unwrap is the typical case).
3. The user accesses `var.size`.

**RESOLVED 2026-04-29 via option C** (same fix as the sister bug
[NARROW_VEC_GOROUTINE_RETURN_CORRUPTION](NARROW_VEC_GOROUTINE_RETURN_CORRUPTION.md)).
Typecheck-side side-channel in `typecheck_walk.qz` NODE_LET handler
walks through NODE_AWAIT → NODE_GO → NODE_CALL → callee, looks up the
return annotation, sets the binding's `struct_name` to the user struct
name. With struct_name populated, `tc_resolve_expr_struct_name(p)`
now returns "Pair" instead of empty, so the typechecker calls
`tc_check_field_access("Pair", "size")` (which returns the correct
field type at the correct slot) instead of falling through to the
TYPE_INT-receiver vec_size rewrite at lines 1213-1224. Regression
covered by `spec/qspec/narrow_vec_goroutine_return_spec.qz`.

## Original diagnosis (kept for reference)

Both bugs stem from `typecheck_walk.qz:1972` returning bare `TYPE_INT` for `NODE_GO`.

## Symptom

```be
struct Pair
  first: String
  second: String
  size: Int
end

def make_pair(): Pair
  return Pair { first: "a", second: "b", size: 7 }
end

def main(): Int
  sched_init(1)
  var fut = go make_pair()
  var p = await fut
  puts("size=" + str_from_int(p.size))   # prints a heap pointer, NOT 7
  sched_shutdown()
  return 0
end
```

Direct call works:
```be
def main(): Int
  var p = make_pair()
  puts("size=" + str_from_int(p.size))   # prints 7  ← correct
  return 0
end
```

## Root cause

`await fut` returns `Int` at the typechecker level (Quartz's existential
type model — Future<T> is type-erased to Int). The user's
`var p = await fut` gives `p: Int`. Then `p.size` lowers as if `p` were a
`Vec<T>`, emitting the canonical vec_size IR pattern:

```ir
%v.hdr = inttoptr i64 %p to ptr
%v.size.ptr = getelementptr inbounds i64, ptr %v.hdr, i64 1
%v.size = load i64, ptr %v.size.ptr, align 8
```

Slot 1 of a `Pair { first, second, size }` heap block is `second`
(a String pointer) — hence the heap-pointer print.

For `p.first` and `p.second`, the typechecker correctly emits standard
struct-field GEPs (`%loptr_N` / `%logep_N` pattern reading the field's
slot index from the registry). Only `.size` is hijacked, because the
UFCS dispatch table / builtin-method shortcut treats `.size` specially
for Int-typed receivers.

## Workaround

Don't name struct fields `size`. Use `count`, `length`, `len`, `n`, etc.
Slice 3.b's spec uses `count` to dodge the collision.

## Reachability

Affects ANY user struct with a `size` field returned through `await`, a
generic container, or any erased-type boundary. Slice 3.b's auto-arena
synthesizer hits it because awaited goroutine results lose the precise
return type during typecheck.

## Possible fixes

1. **Typechecker preference**: when accessing `.field` on a value whose
   ANNOTATION is `Int`, but the EXPRESSION's inferred type is a
   registered struct (recoverable from the return-type annotation of the
   producing call), prefer struct-field access over the Int-receiver
   UFCS shortcut. Requires threading "this Int actually represents a
   Pair" info through the type lattice — non-trivial.
2. **Reserve `size`**: declare `size` a reserved field name across all
   structs and refuse it at struct-decl time. Heavy-handed; would
   break legitimate user code.
3. **Stricter UFCS**: limit `.size` shortcut to a closed set of types
   (Vec, String, Map). Other type-erased Int receivers fall through to
   field-access. Cleanest fix; minor semantic change.

## Related

- `feedback_quartz_module_quirks.md` — method/free fn collisions.
- E.4.a slice 3.b's spec at
  `spec/qspec/alloc_e4a_struct_mixed_return_spec.qz` documents the
  workaround.
