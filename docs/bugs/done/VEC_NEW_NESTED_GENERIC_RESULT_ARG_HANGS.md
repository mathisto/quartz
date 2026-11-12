# `vec_new<Result<A,B>>()` with a nested-generic type arg hangs the compiler

> **CLOSED-STALE 2026-07-07** — re-reproduced fixed on current binary; see docs/sagas/r24-groundwork-inert-holes-2026-07-07-research/ws2-triage.md (fix `2d6c93bc`: turbofish scanner delegates to `ps_parse_type`).

**Status:** ✅ FIXED `2d6c93bc` (2026-06-14; recorded item 3, deexist-finish run). The hand-rolled
turbofish type-arg scanner in `ps_parse_postfix` (parser.qz ~3161) could only
read a single inner IDENT per type-arg, so a nested 2-arg inner generic
(`Result<A, B>`, `Map<K, V>`) left the inner comma unconsumed — wedging or
parse-erroring at the comma. (By the time of this fix the golden binary no
longer hung; the symptom had already bounded into a cascade of QZ0101 errors
at the inner comma. The underlying defect — cannot parse a nested 2-arg inner
generic — was the same.) **Fix:** the scanner now delegates type-arg
consumption to `ps_parse_type` (which already handles nested 2-arg generics,
tuples, and the `>>`→`>` mutation), guarded by an IDENT-only first-token check
(preserves the comparison-vs-turbofish boundary byte-for-byte) and a
`ps_tf_drop_alias_prefix` pre-check (preserves `alias::Type`→bare-`Type`
semantics; module-qualified `module::Type`→`module$Type` unchanged).
Const-generic INT args stay hand-handled. Regression spec:
`spec/qspec/turbofish_disambig_spec.qz`. Fixpoint (2889 fns) byte-identical;
full qspec 856/856.

**Severity:** Tier-B (non-terminating compile on a legal expression; clean workaround exists).

## Repro

```qz
struct OkPayload
  a: Int
end
struct ErrPayload
  b: Int
end
def res_ok(n: Int): Result<OkPayload, ErrPayload> = Result::Ok(OkPayload { a: n })
def main(): Int
  var v = vec_new<Result<OkPayload, ErrPayload>>()   # ← HANGS (no IR, no error)
  v.push(res_ok(1))
  return 0
end
```

`./self-hosted/bin/quartz prog.qz` never terminates (killed at 70s+, 0 lines of IR, no
diagnostic). CPU-bound, not blocked on I/O.

## Scope (bisected)

- `vec_new<Result<OkPayload, ErrPayload>>()` — **HANGS.**
- `[res_ok(1), res_err(2)]` (vec literal, element type inferred) — **OK** (~64K lines IR).
- `Option<Result<OkPayload, ErrPayload>>` annotation + `Option::Some(res_ok(9))` — **OK.**
- `vec_new<Int>()` / `vec_new<OkPayload>()` (single-level generic arg) — OK (used widely).

So the trigger is specifically an **explicit nested-generic type argument** (`Result<X,Y>`
inside `vec_new<…>`) on the `vec_new` turbofish path. The nested `<…>` likely confuses the
turbofish parser / a type-substitution fixpoint (non-terminating loop) — the leading
suspect is the angle-bracket depth tracking in the `vec_new<…>` generic-arg parse or a
mono/substitution cycle when the element type itself carries two type args.

## Workaround

Use a vec literal so the element type is inferred from the elements
(`var v = [res_ok(1), res_err(2)]`), or build the vec untyped and push. The M2 spec
`spec/qspec/result_niche_spec.qz` (Vec<Result<&A,&B>> element-position case) uses the
literal form for this reason.

## Next step

Bisect the parser/typecheck path for `vec_new<` turbofish with a 2-arg nested generic;
add a depth/iteration guard + a spec. Likely shares a root with any other
`f<Outer<A,B>>()` turbofish call. Confirm whether `vec_new<Map<K,V>>()` (also 2-arg
nested) hangs too — if so the fix is general to nested-generic turbofish, not Result-specific.
