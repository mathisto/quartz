## `impl AsyncIterator<T>` loses generic parameter when stored in `var`

### Status

**FIXED 2026-04-21.** Both the typecheck half (trait-bound check on
opaque `impl Trait<T>`) and the runtime half (for-await dispatch on a
`_impl_N` desugared param) are landed. Stream composition via
`std/streams` now works end-to-end through the Piezo async machinery.

### Typecheck fix (landed)

Root cause: async generators with `def f(): impl AsyncIterator<T>` don't
register a concrete impl-return type. `tc_infer_impl_concrete_type` at
`typecheck_walk.qz:3893` returns empty for generators (they use `yield`,
not `return`), so `tc_register_impl_return` at line 3919 is skipped.

Consequence: `var nums = f()` binds `nums` with the LITERAL string
`"impl AsyncIterator<Int>"` as its type annotation. The var-let path at
`typecheck_walk.qz:2127` strips generic args via `__char_index(ret_ann,
'<')`, producing `struct_name = "impl AsyncIterator"` (generic lost).

When `nums` is then passed to a function with an implicit `impl Trait<T>`
parameter (desugared by `resolver.qz::resolve_desugar_impl_trait_args`
into `<_impl_0: AsyncIterator<Int>>`), `tc_validate_trait_bounds`
compares `"impl AsyncIterator"` against the bound
`"AsyncIterator<Int>"` via `tc_check_trait_bound`. No registered impl
matches → QZ0200 fires.

Fix (committed): `tc_check_trait_bound` now recognizes opaque `impl Trait<T>`
concrete types and matches them against the trait bound via three cases:

1. Exact match after stripping `impl ` prefix (both carry generics).
2. Base-name match after stripping generics from the stripped opaque
   (concrete carries generics, bound does not).
3. Base-name match after stripping generics from the bound (concrete is
   the post-var-let stripped form, bound carries generics).

This is semantically correct: `impl Trait<T>` annotations are a promise
that the value implements that trait. Matching the promise against the
bound trait is trivially satisfied when the trait names agree.

Regression sweep: 17/18 impl/trait/iterator specs fully green post-fix.
async_iterator_spec (14/27) matches pre-fix baseline identically — the
13 failures are the pre-existing
`docs/bugs/ASYNC_ITER_UTF8_OUTPUT_TRUNCATION.md` bug.

### Runtime fix (landed)

Root cause of the runtime hang: `for await v in src` dispatch in
`mir_lower.qz` routes to `lower_async_gen_iteration_indirect` (which
uses the frame[2] poll function) only when `src`'s registered var-type
annotation starts with `"impl AsyncIterator<"`. For generator functions
with parameters written as `impl AsyncIterator<T>`, the resolver's
`resolve_desugar_impl_trait_args` rewrites the param annotation to a
synthetic `_impl_N` name BEFORE MIR lowering sees it. Consequence: the
for-await dispatch falls through to the channel recv path
(`try_recv_or_closed` on `src` treating it as a channel), which hangs
forever because `src` is a generator frame pointer, not a channel.

Fix: `mir_lower_generator` and `mir_lower_async_generator` now recognize
synthetic `_impl_N` param annotations. A new helper
`_mlg_bound_trait_for(bounds, tp_name)` scans the function's type-param-
bounds string to find the declared bound trait. For a param with type
`_impl_0` and bound `_impl_0:AsyncIterator<Int>`, the helper returns
`AsyncIterator<Int>`. The generator then calls `mir_ctx_mark_struct_var`
to register the param as `"impl AsyncIterator<Int>"`, restoring the
form that the for-await dispatch check expects.

After the fix, this composition works end-to-end:

```quartz
import * from streams

def counting(): impl AsyncIterator<Int>
  var i = 1
  while i <= 5
    yield i
    i = i + 1
  end
end

def main(): Int
  sched_init(1)
  var nums = counting()
  var doubled = stream_map(nums, x -> x * 2)
  var total = 0
  for await v in doubled
    total = total + v
  end
  sched_shutdown()
  puts("total=" + total.to_s())  # prints "total=30" (2+4+6+8+10)
  return 0
end
```

### Files changed

- `self-hosted/middle/typecheck_registry.qz::tc_check_trait_bound` —
  added opaque `impl Trait<T>` match block (typecheck half, commit
  `c53d4d9f`).
- `self-hosted/backend/mir_lower_gen.qz` — new helper
  `_mlg_bound_trait_for` + extensions to `mir_lower_generator` and
  `mir_lower_async_generator` param-marking to handle synthetic
  `_impl_N` annotations (runtime half).

### Pre-existing side diagnostic

`MANGLER BUG: specialization component contains whitespace` is still
printed to stderr when the monomorphizer sees `impl AsyncIterator<Int>`
as a specialization component. The mangler flattens the whitespace and
continues (symbol ends up as `stream_map$2$implAsyncIterator$Int`), so
codegen succeeds. The warning itself is harmless; suppressing it
cleanly would require passing a pre-flattened form to the mangler's
symbol-safety check.
