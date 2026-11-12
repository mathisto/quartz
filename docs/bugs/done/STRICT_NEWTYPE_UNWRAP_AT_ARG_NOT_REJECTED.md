# `@strict` newtype: implicit unwrap at function-argument position not rejected

**Filed**: 2026-05-21, during STRICT_NEWTYPES_QZMOD cross-module test work
**Branch**: `net-4-secret-t`
**Severity**: Strict-newtype rejection is incomplete. Crypto-key material wrapped in `@strict newtype Secret<T> = T` (NET.4.1) can leak via call sites whose param type is the wrapped type. Same-process, single-module, and across qzmod cache.

## Reproducer (single-module — independent of NET.4.x scope)

```quartz
@strict
newtype Vault = Int

def vault_seal(v: Int): Vault = as_type<Vault>(v)
def takes_int(n: Int): Int = n

def main(): Int
  var sealed: Vault = vault_seal(42)
  return takes_int(sealed)
end
```

## Observed behavior

Compiles silently. `sealed: Vault` is implicitly downgraded to `Int` at the
`takes_int(sealed)` call site even though `Vault` is `@strict`.

## Expected behavior

`QZ0200` / `QZ0201` type mismatch — strictness should refuse the implicit
`Vault → Int` direction at every position, mirroring the symmetric
`Int → Vault` rejection that already works.

## Root cause

`typecheck_expr_handlers.qz §3631` only enters the strict-aware arg
validator when the **expected** param type is a newtype or strict
newtype:

```quartz
if typecheck::tc_is_newtype(expected_t) or typecheck::tc_is_strict_newtype(tc, expected_t)
  # ... routes through tc_types_match, which rejects on strict ...
end
```

When the expected param is loose (e.g., `Int`) and the actual arg is a
strict newtype, this branch never fires. The general scalar-flow path
then admits the call because `Int` and `Vault` are both i64-compatible
under the existential-erasure scalar layer.

`tc_types_match` itself **does** carry the right symmetric short-circuit
(`typecheck.qz §1822-1834`):

```quartz
if tc_is_strict_newtype(tc, t1)
  return false
end
if tc_is_strict_newtype(tc, t2)
  return false
end
```

— so the gap is purely that this path isn't consulted for general
`(expected=Int, actual=StrictNT)` call-site checks.

## Symmetric positions to audit

Once a fix lands for arg position, the same audit applies to:

- Return position (function returns wrapped type, returns a strict-newtype value).
- Field assignment (struct field has wrapped type, value is strict-newtype).
- `var x: WrappedT = strictNTValue` (let-position-wrong-direction).
- Tuple element / collection element coercions.
- Closure / Fn-typed param coercions.

The strict-newtype short-circuit in `tc_types_match` covers all of these
**if they route through `tc_types_match`**; the arg-validator gap above
is the model for finding the other not-routed paths.

## Suggested fix shape

In `typecheck_expr_handlers.qz` at the arg-validation point, additionally
trigger the validator when **actual** is strict:

```quartz
if typecheck::tc_is_newtype(expected_t)
  or typecheck::tc_is_strict_newtype(tc, expected_t)
  or typecheck::tc_is_strict_newtype(tc, actual_t)   # NEW
  # ...
end
```

— with the same `tc_types_match` walk inside. Then audit the symmetric
positions named above for any other "scalar-flow path bypasses
tc_types_match" cases. Estimate: 0.5 qd including a single-module
spec for each of the symmetric positions.

## Status

Filed. Discovered while wiring STRICT_NEWTYPES_QZMOD cross-module
tests; the failing test was rewritten to use the construction direction
(which works), and this gap is now tracked here.

NET.4.1 will paper over this in audit by funnelling all unwraps through
`secret_unwrap` (the explicit `as_type<Int>(s)` boundary). But the
language-level rejection should be complete — otherwise stray
`takes_int(some_secret)` slips through without surfacing in audit.

## Related

- `docs/design/STRICT_NEWTYPES_DESIGN.md` — §"Position-by-position rejection table"
- `spec/qspec/strict_newtype_spec.qz` — single-module + cross-module coverage
- `docs/design/SECRET_T_AND_DUDECT_DESIGN.md` — NET.4 scope this affects

---

## Closed 2026-05-22 (commit `ac08dabd`)

Fix in `self-hosted/middle/typecheck_expr_handlers.qz` §3631 — added an
`else` branch on the arg-validator that fires when the **actual** arg's
type is strict (closing the asymmetric `Vault → Int` / `Secret<Int> →
Int` direction). Routes through the same `tc_types_match` + QZ0201
diagnostic shape as the expected-side branch.

Validation:
- 3 new specs in `spec/qspec/strict_newtype_spec.qz` (2 single-module + 1 cross-module via qzmod).
- `quake guard` PASSED, fixpoint clean, 2544 functions (unchanged).
- All 7 crypto smokes + dudect:smoke re-verified green with a fresh `.quartz-cache`.
- NET.4.1's wrap/unwrap discipline (164 callsites) holds — no latent leaks surfaced by the strengthened rejection.
