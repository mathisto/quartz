# Interpolating `Option<T>` directly prints the heap-box address

**Status**: ✅ FIXED 2026-04-30 — typecheck-time rejection (Option A).
Diagnosed during the WASM real-program audit follow-up. Filed after the
original `LLVM_TO_STR_INT_PATH_RETURNS_ADDRESS.md` was rediagnosed as
actually being this issue.

**Resolution**: New diagnostic `QZ0211` fires at typecheck time when an
interpolation part (or `puts(...)` arg via the auto-coerce) has a static
type whose base kind is `TYPE_OPTION` or `TYPE_RESULT`. The message points
the user at `.unwrap_or(default)`, pattern-matching, and `.is_some?` /
`.is_ok?` predicate forms. Sites:
- `self-hosted/middle/typecheck_walk.qz` — `NODE_INTERP_STRING` part loop.
- `self-hosted/middle/typecheck_expr_handlers.qz` — `puts/eputs` auto-coerce.
Spec: `spec/qspec/option_interp_spec.qz` (7/7 green).

**Affected backends**: LLVM and WASM equally (consistent contract since the
Apr 30 WASM `str_find` fix made WASM also return `Option<Int>` properly).
Diagnostic fires before either backend runs, so both are covered uniformly.

## Summary

`"#{opt}"` where `opt: Option<T>` prints the runtime heap-box pointer instead
of formatting the contents. Both backends now box `Option<T>` as a 16-byte
heap allocation `[i64 tag, i64 payload]`, with the i64 carried in user code
being the box's address. The string-interpolation desugar treats this i64 as
a plain integer and formats it as decimal — yielding a 13-15 digit pointer
value instead of `Some(5)` / `None`.

## Reproducer

```quartz
def main(): Int
  s = "alice,bob"
  opt = s.find(",")           # Option<Int>
  puts("opt = #{opt}")        # Bug: prints "opt = 105553127584496" (or similar)
  return 0
end
```

Expected output (some valid choice):
- `opt = Some(5)` (Display-style auto-format)
- typecheck error: "cannot interpolate Option<Int>; unwrap or match first"

## Workaround

Always unwrap before interpolating:

```quartz
puts("opt = #{opt.unwrap_or(-1)}")
match opt
  Some(v) => puts("found at #{v}")
  None => puts("not found")
end
```

## Where the gap lives

The desugar of `"#{expr}"` parts into `to_str(expr)` happens at typecheck
time without a type check on `expr`. `to_str` is registered as
`(i64) -> String` — there's no overload that handles `Option<T>` specifically,
so the i64 gets formatted as if it were an `Int`.

Two design options:

1. **Typecheck error** (strict) — at the desugar site, check the static type
   of each `#{expr}` part. If it's `Option<T>`, `Result<T,E>`, or any other
   "wrapper" that has no Display impl, emit a diagnostic suggesting the user
   unwrap or pattern-match first.

2. **Auto-format wrapper types** — generate `option_to_s(opt)` / `result_to_s(r)`
   stdlib functions and route through them when the desugar sees a wrapper
   type. Less ceremonious but introduces stringification choices that may not
   match user intent.

Option 1 is more conservative and matches what most strongly-typed languages
do (Rust requires explicit `{:?}` for Debug; Swift requires explicit
`String(describing:)` for Optional<T>).

## Acceptance criteria

- A new spec exercises the failing reproducer and asserts either:
  (a) a specific typecheck diagnostic, OR
  (b) a specific Some/None output format
- `examples/string_processing.qz` already uses `unwrap_or` since the audit
  follow-up; whatever the chosen behaviour is, it should preserve that file's
  current output.

## Related

- `docs/bugs/done/LLVM_TO_STR_INT_PATH_RETURNS_ADDRESS.md` — the original
  misdiagnosis. The pointer-as-text symptom was real; the runtime explanation
  was wrong.
- The Apr 30 WASM `str_find` Option-contract fix — closed the orthogonal bug
  where WASM didn't even return an Option box for `str_find`. Now both
  backends are at the same baseline; this Option-interp gap surfaces uniformly.
