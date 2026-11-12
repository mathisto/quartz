# Narrow-element Vec<T> goroutine return corrupts elements

## Status

**RESOLVED 2026-04-29 via option C** — typecheck-side side-channel in
`self-hosted/middle/typecheck_walk.qz` NODE_LET handler. The fix walks
through NODE_AWAIT → NODE_GO/NODE_ASYNC_CALL → NODE_CALL → callee
NODE_IDENT, looks up the inner function's return annotation via
`tc_lookup_function_return_annotation`, and propagates struct_name
(for user structs) and type_ann (for both user structs and builtin
containers like `Vec<Bool>`) onto the binding. Also handles the
indirect form `var v = await fut` by inheriting from `fut`'s binding,
and the direct `var fut = go f()` form by reading the inner CALL's
return annotation directly. The recovered annotation is back-stamped
to the LET AST node's str2 so MIR-level handlers
(`mir_ctx_mark_vec_elem_type`, `mir_ctx_mark_struct_var`) pick it up
without their own NODE_AWAIT handler. Runtime type stays TYPE_INT —
only the side-channel binding metadata changes. Codegen unchanged.

Sister bug [STRUCT_FIELD_SIZE_HIJACK_BY_VEC_SIZE](STRUCT_FIELD_SIZE_HIJACK_BY_VEC_SIZE.md)
closed by the same fix.

Regression spec: `spec/qspec/narrow_vec_goroutine_return_spec.qz`
(5 cases including 5-element narrow Vec, struct field with
non-shadowed name `total`, struct field literally named `size`,
direct `await go f()` form).

## Original diagnosis (kept for reference)

Root cause was confirmed at `self-hosted/middle/typecheck_walk.qz:1972` where `NODE_GO` returns bare `TYPE_INT` instead of `Future<T>`. The single-site change `result = tc_make_ptype(tc, TYPE_FUTURE, inner_type, 0)` does fix the awaiter codegen (verified through fixpoint pass) but **breaks every user program importing `std/concurrency`**: the canonical `sched_map` pattern at `std/concurrency.qz:417-437` bundles `var tasks = vec_new<Int>(); ... tasks.push(task)` where `task` is now `Future<Int>` ≠ `Int` → QZ0200 typecheck error. Fixpoint masks this because the compiler doesn't import std/concurrency itself.

**Next-session approaches** (all viable; option C recommended):

- **Option A — future-typed stdlib annotations**: rewrite `std/concurrency.qz` to use `Vec<Future<Int>>` for handle-bundling helpers (sched_map, go_scope, async_map, etc.). Larger sweep but architecturally clean. Risk: many sites; may cascade further into user code that did `Vec<Int>` containing handles.
- **Option B — implicit Future<T>→Int coercion at call/arg sites**: existential erasure makes runtime always i64, so `Future<T>` at any i64 expected position is safe. Add the coercion in `tc_check_arg_types` / `tc_check_let`. Smaller compiler change; adds permissiveness to the type system.
- **Option C — side-channel via LET annotation (RECOMMENDED)**: don't change `NODE_GO`/`NODE_ASYNC_CALL`'s type id. Instead, in the LET handler at `typecheck_walk.qz:2270+`, when `init_kind == NODE_AWAIT`, walk to the awaited future's source `NODE_GO` / `NODE_ASYNC_CALL`, read the inner call's return annotation (function's return type from registry), and propagate it via `type_ann` / `struct_name` / `vec_elem_type` fields on the LET binding. Codegen for `v[i]` and `p.field` already reads these fields — no codegen changes needed. Most surgical. Doesn't perturb the existential erasure model anywhere outside the LET binding.

**Latent. Pre-existing — not introduced by Phase E.4.a.** Discovered 2026-04-28
during E.4.a slice 2 spec authoring. Diagnosis updated 2026-04-29.

## Symptom

A goroutine returning a `Vec<Bool>` (or any narrow-element Vec — `Vec<I8>` /
`Vec<U8>` / `Vec<I16>` / `Vec<U16>` / `Vec<I32>` / `Vec<U32>` / `Vec<F32>`)
produces corrupted element values at the awaiter, even when E.4.a's
auto-arena gate has been verified to skip (kind=0 fall-through to libc
heap path).

### Minimal repro

```be
import * from std/concurrency
import * from std/alloc

def make_bool_vec(): Vec<Bool>
  var v = vec_new<Bool>()
  v.push(true)
  v.push(false)
  v.push(true)
  return v
end

def main(): Int
  sched_init(1)
  var fut = go make_bool_vec()
  var v = await fut
  # Direct call: produces [T, F, T] correctly.
  # Through goroutine: produces [T, F, F] — slot 2 corrupted.
  for i in 0..v.size
    if v[i]
      puts("[" + str_from_int(i) + "]=T")
    else
      puts("[" + str_from_int(i) + "]=F")
    end
  end
  sched_shutdown()
  return 0
end
```

Direct call (`var v = make_bool_vec()`): prints `[0]=T [1]=F [2]=T`.
Through goroutine + await: prints `[0]=T [1]=F [2]=F`.

## Diagnosis sketch

`Vec<Bool>` uses 1-byte element stride per
`shared/elem_width.qz:elem_byte_width` ("Bool" → 1). The Vec data buffer
is a 1-byte-stride array. Vec header carries `elem_width` at slot [3] of
the 32-byte header.

The async return path (`Async.spawn` future → `await` await-result) shuttles
the Vec POINTER as an i64 across the boundary. The pointer itself is
correct. The data buffer reached at slot [2] (`data_ptr`) is correct.

But somewhere in the async machinery, the 3rd byte (`data[2]`) gets
overwritten to 0 (false). Hypothesis: the async-frame return-slot or the
poll-result-store path performs an i64 store/load on a pointer that
overlaps with the narrow data buffer's tail. Confirmed by:

- Skipping E.4 entirely (gate kind=0 for `Vec<Bool>`): bug still present.
- Direct call (no goroutine): correct.

## Why E.4.a slice 2 doesn't address it

Slice 2's promote helper `arena_promote_vec_value(v: Vec<Int>): Vec<Int>` is
hardcoded to 8-byte stride via its `Vec<Int>` signature. It cannot be used
for narrow-element Vecs without producing further corruption (8-byte read
on 1-byte storage).

Slice 2 explicitly rejects narrow-element Vecs in the gate via
`_mir_is_8byte_value_typed_annotation` (in `mir_lower.qz`). They fall
through to the libc-heap-fallback path — same path as before E.4.a, which
is where this latent bug lives.

Width-aware promote is part of slice 2.b / slice 4 (per-element promote).
Once that ships, this bug must be either fixed or worked around because
the auto-arena gate will start firing on narrow-Vec returns and the
promote helper itself will need a width-aware copy.

## Pull-in trigger

- A user reports goroutine-returning a narrow-element Vec produces wrong
  values.
- Slice 4 (Vec<reference-typed>) lands and the gate accepts narrow-element
  Vecs as part of a width-aware path.
- Phase E.4.b panic-path work brushes against the async-frame return-slot
  layout.

## Investigation hints

1. Compile a narrow-Vec goroutine return with `--dump-ir` and inspect the
   `__Future_<fn>$poll` body's `wb.result_slot.NN` store/load.
2. Check `mir_lower_async_registry.qz` and `mir_lower_async_*` for any
   place that assumes 8-byte result slots for Vec returns.
3. Compare against the Vec<Int> success path: if the result slot is
   uniform i64 (pointer to header), the corruption must happen at element
   read in the awaiter's frame — possibly `v[i]` lowering.
