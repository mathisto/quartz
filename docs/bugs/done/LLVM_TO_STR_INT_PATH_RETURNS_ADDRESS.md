# LLVM `to_str(int)` returns the wrap-cstr buffer address, not the bytes

**Status**: ✅ MISDIAGNOSED — closed 2026-04-30. The originally-printed pointer
was not from `to_str(int)` at all. The repro inputs were `Option<Int>` values
(returned by `str_find` since v5.26), and `#{opt}` was interpolating the
Option box pointer, not formatting an integer.

The compiler's `to_str(int)` int_path is fine. The `qz_wrap_cstr` /
`__qz_dealloc` chain that the original analysis pointed at is also fine —
nothing in that path was misbehaving for actual ints.

## What was actually happening

```quartz
csv = "alice,bob,charlie"
puts("find(',') = #{csv.find(",")}")
```

`csv.find(",")` returns `Option<Int>`, not `Int`. From
`self-hosted/middle/typecheck_builtins.qz:128`:

```
tc_register_builtin(tc, "str_find", type_constants::TYPE_OPTION)  # v5.26: returns Option<Int>
```

`#{...}` desugars to `to_str(...)`. The Option<Int> value at runtime is a
heap-allocated 16-byte box `[i64 tag, i64 payload]` — its i64 representation
is a pointer to that box. The interp path treats the i64 as an integer (since
`Option` doesn't implement to_str directly) and formats it as decimal — yielding
the box's heap address.

Both backends do this; we simply hadn't tested LLVM and WASM on the same input
because **WASM's `str_find` was actually returning a raw int (`5` or `-1`)**
instead of `Option<Int>`. That's the WASM bug that masked the misdiagnosis —
WASM happened to print the "right" answer for the wrong reason.

## What got fixed

Three things shipped 2026-04-30 closed this misdiagnosis cleanly:

1. **Example fix** — `examples/string_processing.qz` line 69 now uses
   `csv.find(",").unwrap_or(-1)` instead of interpolating the Option directly.
   Both backends now print `find(',') = 5` byte-for-byte.

2. **WASM `str_find` Option contract fix** — the WASM synth body was returning
   a raw int, in violation of the typecheck signature `str_find: TYPE_OPTION`.
   Fixed by adding a `_wasm_synth_str_find` wrapper that boxes the result via
   `option_some(idx)` / `option_none()`, with the search logic moved to a new
   `__wasm_str_find_raw` internal helper. Internal callers (`str_contains`,
   `str_replace`, `str_split`) updated to call the raw variant directly.
   Effect: `match opt { Some(v) => ...; None => ... }` now works on WASM
   (previously read arbitrary memory and trapped at 0xffffffff for the not-found
   case where raw idx was -1).

3. **New filed bug** — [`OPTION_INTERPOLATION_PRINTS_BOX_ADDRESS.md`](OPTION_INTERPOLATION_PRINTS_BOX_ADDRESS.md)
   tracks the deeper issue that interpolating an Option<T> directly should
   either be a typecheck error or auto-format as `Some(...)` / `None`. That's
   a TC-level change requiring type-aware desugar of `#{...}` parts; out of
   scope for the audit follow-up but worth a follow-up session.

## Original Analysis (preserved for context)

The pointer-as-text symptom was real, but the analysis chased the wrong runtime.

```
105553137647712  ← the original printout
```

is the heap address of an `Option::Some(5)` box, not a `qz_wrap_cstr` buffer.
The `__qz_dealloc(%tmp)` hypothesis (UAF on the wrap-cstr return) doesn't fire
because `to_str(int)` was never called — `to_str(option_box_ptr)` was.
