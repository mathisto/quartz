# Generic helper with for-in body: `Undefined variable: x` at typecheck

**Status**: FIXED 2026-04-25 in Phase 4.B.9 (slice 3). For-in iter binding now applies the same `TYPE_ERROR → TYPE_INT` fallback that `tc_function` already used for parameter binding (lines 3992-3997). Spec: `generic_helper_for_in_spec.qz` — 6/6 green.
**Severity**: minor — concrete-typed helpers compose with generators today; generics over element type didn't.
**Reproduces on**: every Quartz binary BEFORE this fix (verified against `quartz-pre-genfor-fallback-golden`).
**Filed under**: pre-existing — not introduced by Phase 4.B.8.

## Repro

```qz
def emit_each<T>(items: Vec<T>): Void can Yield<T>
  for x in items
    yield x
  end
end

def main(): Int = 0
```

Output:
```
error[QZ0403]: Undefined variable: x
 --> /tmp/p4b9_rowpoly.qz:3:11
3 |     yield x
                ^
```

The for-in's `x` binding is lost inside the loop body when the function has a type parameter (`<T>`) and the iterated collection is `Vec<T>`. Concrete-typed version (`def emit_each(items: Vec<Int>): Void can Yield<Int>`) typechecks clean.

## Likely root cause

For-in scope handling in typecheck doesn't see through unresolved generic params. When `items: Vec<T>` enters the for-in, the typechecker can't resolve the element type without monomorphization, so `x`'s scope binding fails or is silently dropped. Expected behavior: bind `x: T` (the element type from the Vec) and let monomorphization resolve `T` at the call site.

## Workaround

Concrete element type works:

```qz
def emit_each_int(items: Vec<Int>): Void can Yield<Int>
  for x in items
    yield x
  end
end
```

Or use index-based loop with `items.size` and `items[i]` (also avoids the for-loop-state-preservation bug for $poll bodies; see `FOR_LOOP_STATE_NOT_PRESERVED_IN_POLL.md`).

## Followups

- Investigate whether for-in's typecheck handles `Vec<T>` element binding correctly when `T` is an unresolved type param.
- Likely related to other generic + for-in patterns; not generator-specific.
