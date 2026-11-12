# STRICT_NEWTYPES — opt-in strict opaque newtype boundary

**Status**: Active, branch `net-4-secret-t` (commit `e6bcb3de`+).
**Track**: Compiler / type-system epic. Prereq for NET.4 (Secret<T>).
**Prereq**: Generic newtype use-site resolution (already landed this session — `tc_parse_type` final-fallback branch).
**Successor**: NET.4.1 (`Secret<T>` annotations on existing crypto stdlib).

## Motivation

Quartz newtypes today are sub-strict. The v5.25.0 doc claims "strict type
enforcement," and `tc_types_match` does refuse cross-newtype implicit
conversion (`UserId` ↔ `OtherId` is rejected). But three positions leak:

1. **`Int` ↔ `UserId`** — implicit construction at return / let-init and
   implicit unwrap at let / arg / return all work. `var x: Int = userId`
   compiles. `def takes_int(x: Int)` accepts a `UserId` argument.
2. **Container generics** — `Vec<Int>` matches a `Vec<UserId>` parameter.
   Existential erasure at the value level means container element types
   aren't checked at the call boundary.
3. **Branch / index / comparison** — `if userId == 0`, `arr[userId]`,
   `userId < 10` all typecheck. The value flows as `Int` from `tc_expr`.

For NET.4 to give `Secret<T>` actual teeth (rejecting `if secret_byte == 0`
at the compiler level), the boundary must be strict. The fix isn't to
make ALL newtypes strict — five in-tree newtypes (`AstNodeId`, `TypeId`,
`MirReg`, `MirLabel`, `InternId`) deliberately use loose semantics for
arithmetic ergonomics. The fix is to make strictness **opt-in** via a
`@[strict]` attribute on the newtype declaration.

## Prior art surveyed (D2)

| System | Newtype shape | Strictness | What we learn |
|---|---|---|---|
| **Rust** `struct UserId(u64);` | Tuple struct, distinct type | Fully strict; `.0` field access required | Construction via tuple syntax `UserId(42)`. Destruction via `.0`. No implicit either direction. The gold standard. |
| **Haskell** `newtype UserId = UserId Int` | Distinct constructor | Fully strict | Pattern-match unwrap: `let UserId n = uid in ...`. Free arithmetic via `Num` instance derivation. |
| **OCaml** `type user_id = UserId of int` | Variant constructor | Fully strict | Same shape as Haskell. |
| **Zig** `pub const UserId = struct { value: u64 };` | Wrapper struct | Fully strict | Standard struct semantics. |
| **TypeScript** branded types | Intersection with phantom | Typecheck-strict, runtime-erased | The "phantom brand" approach inspires the strict-but-zero-cost stance. |
| **Go** `type UserId int` | Distinct named type | Loose — implicit `int → UserId` allowed | Closest to current Quartz behavior. Universally lamented as ergonomically permissive but semantically weak. |
| **Swift** typealias vs newtype | `typealias` transparent; explicit struct strict | Hybrid by design | The opt-in stance Quartz takes. |

Quartz adopts the **Swift hybrid stance**: default newtypes preserve current
loose behavior (existing in-tree usage continues unchanged); `@[strict]`
newtypes match Rust/Haskell semantics. Migration cost: zero. Optional uptake.

## Design

### Strict semantics

A `newtype @[strict] Name = T` (or `newtype @[strict] Name<T> = T` for the
generic form) is **distinct from `T` in both directions**:

| Operation | Strict | Non-strict (today) |
|---|---|---|
| `var n: Name = t_value` (t_value: T) | **reject** | allow |
| `var t: T = name_value` (name_value: Name) | **reject** | allow |
| `takes_t(name_value)` (param expects T) | **reject** | allow |
| `def f(): Name return t_value end` | **reject** | allow |
| `def f(): T return name_value end` | **reject** | allow |
| `var v: Name = othername_value` (other newtype) | reject (current) | reject (current) |
| `if name_value` (use as condition) | **reject** | allow |
| `arr[name_value]` (use as index) | **reject** | allow |
| `name_value == other_name` (relational) | **reject** | allow |
| `name_value < other_name` | **reject** | allow |
| `x << name_value` (shift right-operand) | **reject** | allow |
| `name1 + name2` (arithmetic) | **allow** (result is Name) | allow |
| `secret_unwrap(name_value)` via crossing intrinsic | **allow** | n/a |

Arithmetic is intentionally NOT rejected — crypto code multiplies, adds,
shifts (by constant amounts) on secret values pervasively. The rejection
targets are uses that observably depend on the secret value's bits
(equality, ordering, position-derived branches).

### Crossing intrinsic

To declare the wrap/unwrap functions inside the strict newtype's author
module, a privileged compiler primitive crosses the boundary without
typecheck:

```quartz
# Compiler-builtin. Identity at runtime; opaque to the strictness checker.
# Audit boundary: callsites are greppable via `__as_strict<` / `__from_strict<`.
def secret_wrap<T>(t: T): Secret<T> = __as_strict<Secret<T>>(t)
def secret_unwrap<T>(s: Secret<T>): T = __from_strict<T>(s)
```

Single source of truth: ALL strict-newtype boundary crossings go through
`__as_strict<NewT>(value)` (from `T` to `NewT`) or `__from_strict<T>(value)`
(from `NewT` to `T`). The intrinsic emits identity IR (`@llvm.identity.i64`
... actually just a no-op SSA rename — same i64 in, same i64 out).

The naming reads at the audit site: `__as_strict` flows INTO the secret
boundary (sealing), `__from_strict` flows OUT (declassifying).

### Ptype-form inheritance

`Secret<T>` declared as `newtype @[strict] Secret<T> = T` produces a
strict bare newtype (`Secret`, type id in 1000..1999). When `Secret<Int>`
appears at a use site, `tc_parse_type` resolves it as a ptype with the
strict newtype as its base. `tc_is_strict_newtype(tc, t)` returns true
for BOTH bare and ptype-form: it walks ptype to its base and checks the
base's strictness flag.

### What we don't change

- Existing newtypes (`AstNodeId`, `TypeId`, `MirReg`, `MirLabel`, `InternId`,
  spec-side `NtUserId` / etc.) get zero strictness. Default behavior unchanged.
  Existing in-tree code continues to compile without modification.
- Type aliases (`type X = Y`) remain transparent.
- `priv` / `pub` newtypes — orthogonal to strictness.
- Trait impls on the wrapped type continue to apply to the wrapper. (Strict
  newtypes can still derive arithmetic.)

## Phasing

| Phase | What | Estimate |
|---|---|---|
| S.0 | This design memo + audit | 0.2 qd (done as part of S.0 task) |
| S.1 | Parser `@[strict]` + registry `is_strict` flag | 0.3 qd |
| S.2 | Rejection at let / arg / return positions | 0.4 qd |
| S.3 | Rejection at branch / index / comparison / shift | 0.3 qd |
| S.4 | `__as_strict` / `__from_strict` crossing intrinsic + specs | 0.3 qd |
| S.5 | Guard + smokes + docs + close-out | 0.3 qd |
| **TOTAL** | | **~1.5–1.8 qd** |

Then NET.4.1 (Secret<T> annotations on crypto stdlib) and NET.4.2 (dudect)
land on top, ~1-1.5 qd combined. Total NET.4 epic completion ~3-3.5 qd from
the start of this session, vs. the ROADMAP's 2-3 quartz-weeks estimate.

## Implementation notes

### Parser

The attribute machinery (`@[...]`) already supports newtype declarations
per the v5.25.0 strict-enforcement claim. Need to verify:

1. `ps_parse_newtype` (parser.qz:7181) — does it currently consume `@[strict]`?
2. If yes: extract the attribute and pass to `ast_newtype` as an extra.
3. If no: extend it. Mirrors the existing `@[noinline]` / `@[ct]` attribute pattern on `def`.

### Registry

`tc.registry.newtype_strict_flags: Vec<Int>` parallel array to `newtype_names`.
Default 0. `tc_register_newtype` accepts an `is_strict: Int` parameter.

### `tc_is_strict_newtype`

```quartz
def tc_is_strict_newtype(tc: TypecheckState, t: TypeId): Bool
  # Bare newtype range
  if tc_is_newtype(t)
    var idx = t - type_constants::TYPE_NEWTYPE_BASE
    return tc.registry.newtype_strict_flags[idx] == 1
  end
  # Ptype-form: check base
  if tc_is_ptype(t)
    var base = tc_ptype_base(tc, t)
    if tc_is_newtype(base)
      var idx2 = base - type_constants::TYPE_NEWTYPE_BASE
      return tc.registry.newtype_strict_flags[idx2] == 1
    end
  end
  return false
end
```

### Rejection sites (5 + 1)

1. **let-position** (`typecheck_walk.qz:2572`): if annotated or init is strict
   newtype, require exact id match. Implicit construction (init: T, annotated:
   StrictNewT) becomes a rejection.
2. **arg-passing** (`tc_check_call` arg-vs-param check): if param is strict
   newtype and arg type doesn't match, reject — even if arg type's wrapped
   matches. Symmetric: if arg is strict newtype and param is wrapped, reject.
3. **return-position** (`tc_check_return` or equivalent): same as above between
   actual return and declared return type.
4. **condition** (`tc_check_condition`, typecheck_helpers.qz:357): if cond type
   is strict newtype, reject. Suggest `unwrap` + manual ct-helper.
5. **index** (`tc_expr_index`, typecheck_expr_handlers.qz:411): if index type
   is strict newtype, reject. Suggest explicit unwrap.
6. **comparison + shift** (`tc_check_binary`, typecheck_walk.qz:1349): for
   relational ops (==/!=/</>/<=/>=) or right-operand of `<<`/`>>`, reject
   when operand is strict newtype.

### Crossing intrinsic registration

Follow the 4-step builtin registration pattern from CLAUDE.md:
1. `typecheck_builtins.qz` — `tc_register_builtin(tc, "__as_strict", TYPE_*)` and
   `__from_strict`. Both polymorphic in their type arg.
2. `intrinsic_registry.qz` — `_r("__as_strict", INTRINSIC_CAT_*)` and `__from_strict`.
3. `cg_intrinsic_*.qz` — IR-emit handler. Both are identity at the IR level
   (just rename the SSA value to the target type's slot).
4. Skip step 4 (no `@llvm.*` involvement).

### Spec coverage

`spec/qspec/strict_newtype_spec.qz` — exhaustive rejection coverage:
- 6 sites × strict-newtype rejection
- Sanity: existing `InternId` / `AstNodeId` semantics unchanged
- Crossing intrinsic works inside author module
- Ptype-form inheritance: `newtype @[strict] Box<T> = T` ⇒ `Box<Int>` is strict

## Open decisions

1. **Should `@[strict]` apply transitively to ptype-form?** Plan: yes. `Box<T>`
   strict ⇒ `Box<Int>` strict. Inheritance via base id.
2. **Should arithmetic on strict newtypes be allowed?** Plan: yes (see decision
   table above). Crypto code requires it.
3. **Should the crossing intrinsic be greppable as `__as_strict` / `__from_strict`,
   or as `@[transmute]`-tagged functions?** Plan: builtins (`__as_strict`) —
   simpler, single source of truth, audit-greppable. The `@[transmute]` decorator
   adds parser surface for no real win.
4. **Should existing newtypes (`InternId` / `AstNodeId`) be migrated to
   `@[strict]` later, with a compat path?** Plan: defer. The loose semantics
   are arguably correct for these (they're identity-like, not security-like).
   If we want to migrate later, do it as its own epic; this design doesn't
   require it.

## Decision log

- **2026-05-21** — STRICT_NEWTYPES filed as compiler-prereq for NET.4.1+ after
  probes showed Quartz newtypes have weaker strictness than the v5.25.0 doc
  claims. Approach: opt-in `@[strict]` attribute, zero-migration default,
  Rust/Haskell-style semantics for opt-in cases. NET.4.0 (use-site resolution)
  already landed earlier this session.

## References

- Quartz `docs/design/SECRET_T_AND_DUDECT_DESIGN.md` — what this unblocks
- Quartz `docs/QUARTZ_REFERENCE.md` § "Newtypes" (current state, sub-strict)
- Rust Reference § "Newtype pattern" — gold standard
- Swift Evolution SE-0030 "Property Behaviors" — the hybrid stance
- Haskell `newtype` semantics (Marlow et al., Haskell 2010)
