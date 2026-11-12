# Generic struct definition + use site hangs the typechecker

> **RESOLVED 2026-06-01 — and the title/diagnosis below were WRONG.**
>
> **Generics are a red herring.** The real trigger is the **brace-delimited
> struct *body*** — `struct X { ... }` — generic or not. Bisection on the
> fixed-today binary:
>
> | Form | Result |
> |---|---|
> | `struct Box<T>` ⏎ `inner: T` ⏎ `end` (generic, end-form) | ✅ compiles |
> | `struct Box { inner: Int }` (**non**-generic, **braced**) | ❌ hung — 3.2 GB RSS, no diagnostic |
>
> The NET.4 author hit it via `Secret<T> { inner: T }` (braced + generic),
> blamed the `<T>`, and wrote the mono-struct workaround in `end`-form
> (which works) — cementing the wrong root cause. End-delimited generic
> structs have always worked (`Tabs<T>`, `List<Item>`, `Program<S,M>` etc.
> are all over `std/tui/`).
>
> **Root cause.** `ps_parse_struct` (`self-hosted/frontend/parser.qz`) only
> handled the `end`-delimited body. On a `{`, `ps_expect_newline_or_end` and
> then the field `while`-loop ran with a non-advancing cursor (`ps_expect`
> does not advance on mismatch), so the loop never reached `end`/EOF and the
> field vec grew without bound → OOM. Same class as `BOUNDED-STRUCT-FIELD-HANG`
> and the PSQ-9 reserved-keyword OOM, both noted in that file.
>
> **Fix.** Brace-delimited struct *bodies* are not valid Quartz (the canonical
> form is `end`-delimited; `{ }` is for struct *literals*). `ps_parse_struct`
> now detects the stray `{` and emits **QZ0102** with a fix-it message, then
> recovers via `_ps_skip_balanced_braces` (guaranteed forward progress).
> `--explain QZ0102` added. Four incidental braced-definition doc errors in
> `QUARTZ_REFERENCE.md` corrected to `end`-form.
>
> **Verification.** Both repros: 3 GB hang → exit 1 in <1 s with QZ0102.
> End-form generic still compiles. Fixpoint gen1==gen2 (2593 fns). Smokes
> (style_demo/brainfuck) green. Regression: 4 cases in
> `spec/qspec/parser_hang_recovery_spec.qz` (9/9). No regression across
> structs/struct_multiline/generic_struct_init/vec_struct_generics/error_codes
> (85 tests). `quake guard` pending (PTY-segfaults from Claude Code — run
> externally before commit).

**Filed**: 2026-05-21, during NET.4.0 design probing
**Branch**: `net-4-secret-t`
**Severity**: Blocks any code that defines a generic struct and uses it (e.g., `Secret<T>` as a wrapper struct)

## Reproducer

```quartz
struct Secret<T> {
  inner: T
}

def secret_wrap_int(t: Int): Secret<Int>
  return Secret<Int> { inner: t }
end

def secret_unwrap_int(s: Secret<Int>): Int
  return s.inner
end

def main(): Int
  s: Secret<Int> = secret_wrap_int(42)
  v: Int = secret_unwrap_int(s)
  return v
end
```

## Observed behavior

Compiler hangs. Five repeated invocations in this session each ran 1–10 minutes,
consuming 2–7 GB of RAM before being killed. No diagnostic output. No stack
overflow exception.

```
$ ./self-hosted/bin/quartz repro.qz
# CPU pegged at 100%, RSS climbs 100 MB/s, no output, no termination
```

## Expected behavior

Either:
- Typecheck succeeds and codegens the generic struct.
- Typecheck reports a "feature not yet supported" diagnostic (QZ0xxx).

Crucially: should not hang.

## Suspected location

Generic struct dispatch in `self-hosted/middle/typecheck.qz` or
`self-hosted/middle/typecheck_walk.qz`. The hang is consistent with an
infinite loop in struct-field type resolution where `T` (a type parameter)
is repeatedly looked up against a registry that never resolves it.

## Workaround

Avoid generic structs. Use per-instantiation mono structs:
- `struct SecretBytes32 { inner: Bytes32 }`
- `struct SecretBytes64 { inner: Bytes64 }`
- etc.

This is the workaround NET.4 v1 takes for `Secret<T>` until this bug is fixed.

## Related

- `newtype Secret<T> = T` does NOT hang — it reports `QZ0200: Unknown type 'Secret<Int>'` at the use site (recoverable typecheck error). Generic newtypes are partially supported in the parser (parser.qz:7178+7192) but not in `tc_parse_type`.
- See `docs/design/SECRET_T_AND_DUDECT_DESIGN.md` for the NET.4 work blocked by these gaps.

## Closes

Filed; awaiting fix. NET.4 v1 ships around it via mono-struct wrappers.
