# Generic `@strict` newtype call-site binding fails — `T` doesn't bind

**Filed**: 2026-05-21, during NET.4.1 entry-point probing
**Branch**: `net-4-secret-t`
**Severity**: Forces NET.4.1 to ship monomorphic `secret_wrap_int` /
`secret_unwrap_int` / `secret_wrap_ptr` / `secret_unwrap_ptr` helpers
instead of the design memo's polymorphic `secret_wrap<T>` /
`secret_unwrap<T>`. Same audit-greppability story, more functions to
maintain. Filed forward; can be deferred until a generic crypto-stdlib
shape is genuinely needed.

## Reproducer

```quartz
@strict
newtype Secret<T> = T

def secret_wrap<T>(t: T): Secret<T> = as_type<Secret<T>>(t)
def secret_unwrap<T>(s: Secret<T>): T = as_type<T>(s)

def main(): Int
  var s: Secret<Int> = secret_wrap<Int>(42)
  var v: Int = secret_unwrap<Int>(s)   # ← QZ0201
  return v
end
```

Also fails with type-arg inference:

```quartz
var s: Secret<Int> = secret_wrap(42)
var v: Int = secret_unwrap(s)          # ← QZ0201
```

## Observed behavior

```
error[QZ0201]: Type mismatch: expected 'Secret', got 'unknown<Int>'
  --> probe.qz:10:35
   |
10 |   var v: Int = secret_unwrap<Int>(s)
   |                                   ^
```

The error fires inside `typecheck_expr_handlers.qz §3631`'s strict
arg-validator: the param type is `Secret<T>` (a ptype with an unbound
`T`), the arg's actual type is `Secret<Int>` (a fully-bound ptype).
`tc_types_match` rejects because the bare `Secret` newtype id and
`Secret<Int>` ptype id are different IDs.

The same shape works for non-`@strict` generic newtypes (loose mode
defaults to type-erased existential flow, so the bare `Secret` id
matches `Secret<Int>` via `tc_is_ptype` fallthrough at
`typecheck.qz §1895-1901`).

## Suspected root cause

`tc_types_match`'s strict short-circuit (typecheck.qz §1829-1834) fires
on either operand being a strict newtype. For `(expected=Secret<T>,
actual=Secret<Int>)`, both are strict (per ptype-form handling in
`tc_is_strict_newtype`). The short-circuit returns false without first
trying to *bind* T to Int.

In other words: the strict short-circuit happens before
generic-parameter substitution. Generic strict newtypes need the same
substitution machinery the ordinary ptype path already has — most
likely a special-case where, when both sides are strict ptypes off the
same newtype base, recurse into per-arg matching to bind type params.

## Suggested fix shape

In `typecheck.qz` around the strict short-circuit:

```quartz
# STRICT_NEWTYPES — short-circuit, but first allow generic binding
# when both sides are ptype-form strict newtypes off the same base.
if tc_is_strict_newtype(tc, t1) and tc_is_strict_newtype(tc, t2)
  if tc_is_ptype(t1) and tc_is_ptype(t2)
    var b1 = tc_ptype_base(tc, t1)
    var b2 = tc_ptype_base(tc, t2)
    if b1 == b2
      # Recurse into args — covers Secret<T> vs Secret<Int>.
      return tc_ptype_args_match(tc, t1, t2)
    end
  end
  return t1 == t2  # bare-newtype vs bare-newtype: identity only
end
# Asymmetric (one side strict, other not) → reject as before.
if tc_is_strict_newtype(tc, t1)
  return false
end
if tc_is_strict_newtype(tc, t2)
  return false
end
```

Estimate: ~0.5-1 qd for the binding fix + a few spec tests
(`spec/qspec/strict_newtype_spec.qz` extension covering
`secret_wrap<T>` / `secret_unwrap<T>` round-trip).

## Workaround in flight (NET.4.1)

`std/core/crypto/secret.qz` ships **monomorphic** wrappers:

```quartz
def secret_wrap_int(t: Int): Secret<Int> = as_type<Secret<Int>>(t)
def secret_unwrap_int(s: Secret<Int>): Int = as_type<Int>(s)
def secret_wrap_ptr(t: Int): Secret<Int> = as_type<Secret<Int>>(t)
def secret_unwrap_ptr(s: Secret<Int>): Int = as_type<Int>(s)
# ... per-type for any Secret<U> that crypto code touches.
```

The audit-greppability story is unchanged: `git grep secret_unwrap_`
finds every declassification site, monomorphic or polymorphic.

## Related

- `docs/design/STRICT_NEWTYPES_DESIGN.md` — §"Generic newtypes"
  (the design assumed binding worked).
- `docs/design/SECRET_T_AND_DUDECT_DESIGN.md` — §"Layer 1 — `Secret<T>`
  opaque newtype" — design API uses `secret_wrap<T>` / `secret_unwrap<T>`;
  this bug forces v1 to ship monomorphic.
- `docs/bugs/STRICT_NEWTYPE_UNWRAP_AT_ARG_NOT_REJECTED.md` —
  independent gap; both want similar fix-up to `tc_types_match`-routed
  arg-validation.

## Status

Filed. Workaround live in NET.4.1. Fix can land as part of NET.4 v2
(alongside the unwrap-at-arg fix and the `@[ct]` MIR pass).

---

## Closed 2026-05-22

Fix in `self-hosted/middle/typecheck.qz` — replaced the two unconditional
strict short-circuits in `tc_types_match` with a structured block that
allows same-base bare↔ptype matching (binds T) and same-base ptype↔ptype
matching with **exact-id** inner-arg equality (NOT via recursive
`tc_types_match`, which would admit `Secret<String>` against `Secret<Int>`
via the `tc_is_i64_type` existential-erasure path). TYPE_ERROR tolerated
on inner-arg sides for generic-T inference paths.

Mirrored at the let-position cross-check in `typecheck_walk.qz` —
replaced the raw identity check `init_type != annotated_type` with
`tc_types_match(...) == false` so generic binding flows uniformly at
both arg and let positions.

Workaround retired: `std/core/crypto/secret.qz` collapsed from 4
monomorphic helpers (`secret_wrap_int` / `secret_wrap_ptr` /
`secret_unwrap_int` / `secret_unwrap_ptr`) to 2 polymorphic helpers
(`secret_wrap<T>` / `secret_unwrap<T>`). All 164 callsites mechanically
renamed (157 wrap + 27 unwrap → ~184 polymorphic-call lines across 16
files in `std/` + `spec/`).

Validation:
- 4 new specs in `spec/qspec/strict_newtype_spec.qz` (2 positive
  binding + 2 same-base-different-args rejection, including the
  `Secret<String>` vs `Secret<Int>` regression caught and fixed
  in-flight by re-routing via exact-id rather than the loose
  recursive match).
- `quake guard` PASSED, fixpoint clean, 2544 functions (unchanged).
- All 9 crypto smokes (crypto/ed25519/sha3/mlkem/mlkem:acvp/hybrid/wg/dudect:smoke/dudect:canary) green with fresh `.quartz-cache`.

Open follow-up: the diagnostic text in some positions prints strict
newtype names as `unknown<...>` rather than the registered name. This
is a `tc_type_name_full` polish issue, independent of correctness. Filed
forward.
