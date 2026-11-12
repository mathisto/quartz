# IMPORT_STAR_COLLISION_SILENT_SHADOW

**Severity**: Medium (silent miscompile — wrong output, no diagnostic)
**Filed**: 2026-05-22 (NET.5c.0 SHA-256 bring-up)
**Status**: ✅ RESOLVED 2026-06-01

> **RESOLVED — and the severity was understated.** Re-diagnosed on the live
> binary: this is not merely consumer-scope shadowing. A module's **own
> internal call to its own function** gets silently redirected to the global
> first-wins winner. Minimal repro: `mod_a` and `mod_b` each define `collide`
> (→111 / →222) plus a `use_X` that calls it internally; a consumer wildcard-
> imports both. Pre-fix `mod_b$use_b` compiled to `call @mod_a$collide`
> (output 111/111 instead of 111/222). That is exactly the SHA-256 shape:
> sha256.qz's internal `_compress` wired to sha512.qz's.
>
> **Root cause.** `mir_resolve_func_name` (`self-hosted/backend/mir.qz`) Case
> 4b resolved a bare callee by a **suffix search** over `all_funcs`
> (`ends_with "$collide"`) returning the *first* `$collide` — regardless of
> which module the call site is in. (The `ct_func_alias_*` bare→canonical map
> is the same first-wins shape; both consulted by every bare call site.)
>
> **Fix.**
> 1. *Module-local precedence (Case 4a, the correctness fix):* a bare callee
>    is resolved to `<current-module>$name` first when the current module
>    defines it, before any cross-module suffix match. `mir_resolve_canonical`
>    + `ct_func_alias_lookup_in_module` apply the same precedence on the alias
>    chokepoints (`mir_emit_call` / `mir_emit_func_ref` / `mir_emit_intrinsic`
>    / qualified path in `mir_resolve_func_name`).
> 2. *Ambiguity diagnostic (Path A from below):* a genuinely-ambiguous bare
>    call from outside all candidate modules now warns **QZ0405** (deduped,
>    `--explain QZ0405`). Chosen as a **warning, not a hard error**, to avoid a
>    false-positive build break; the full double self-compile emits **zero**
>    QZ0405, so the codebase is collision-free and escalation to a hard error
>    is a safe follow-up (filed: ESCALATE_QZ0405_TO_ERROR).
>
> **Verification.** Repro flips 111/111 → 111/222 (IR: `use_a`→`mod_a$collide`,
> `use_b`→`mod_b$collide`). QZ0405 fires on the bare ambiguous consumer call.
> Fixpoint gen1==gen2 (2598 fns). Smokes green. New regression
> `spec/qspec/import_star_collision_spec.qz` (3/3) + fixtures. No regression
> across modules/separate_compilation/pub_import/diamond_import/cache_ro×4/
> resolver_local_shadow/open_ufcs/generic_ufcs_dispatch/hybrid_ufcs_traits/
> map_ufcs/option_ufcs/json_ufcs/structs/error_codes (~190 tests). `quake
> guard` pending (PTY-segfaults from Claude Code — run externally before commit).
>
> The stdlib prefix-convention workaround below remains good hygiene, but is no
> longer load-bearing for correctness of module-internal calls.

## Symptom

When two modules export distinct functions / globals with **identical
names**, `import * from` brings both into the consumer's scope. The
resolver silently picks one — the other's body is unreachable. Calls
that the source code intended to dispatch to one module's function
actually run the other's, producing wrong results without any
diagnostic at parse, typecheck, or codegen.

## Reproducer (NET.5c.0)

`std/core/crypto/sha512.qz` defines `_compress`, `_K`, `_Ch`, `_Maj`,
`_BigSigma0`, `_BigSigma1`, `_SmallSigma0`, `_SmallSigma1`, `_IV_0`..`_IV_7`
internally with u64 bodies. `std/core/crypto/sha256.qz` (first draft)
defined the SAME helper names with u32 bodies.

A user file importing both:

```quartz
import * from std/core/crypto/sha256
import * from std/core/crypto/sha384   # transitively pulls sha512
```

… calls `sha256("")` and gets `0x8b...` (u64 bodies interpreting u32
arithmetic) instead of `0xe3...` (the correct SHA-256 of the empty
string). No diagnostic anywhere.

## Sister bugs

This is the same shape as `MULTILINE_BINARY_OPERATOR_SILENTLY_DROPPED`'s
companion-case in NET.5a.2: `aes_gcm.qz` redefined local SWAR mask
helpers identical to `aes.qz`'s — surfaced as `use of undefined value`
after `opt internalize+globaldce`. The aes_gcm case at least produced
a *post*-IR diagnostic (DCE removed the shadowed copy); the SHA-256
case here produces NO diagnostic at all because both bodies are
referenced from somewhere in the program (sha512 from sha384's call
site, sha256 from the consumer).

## Workaround (in stdlib)

Module-prefix every internal helper. After this fix, sha256.qz uses
`_sha256_compress`, `_sha256_K`, `_sha256_Ch`, etc. — no collision
possible against sha512.qz's `_compress`.

This pattern needs to become the default convention for the crypto-
stdlib at minimum, and probably for every stdlib module that exports
non-trivial private helpers via `import *`.

## Proposed compiler-level fix

Two paths, either would close the class:

**A. Diagnose ambiguous import**. When `import *` would bring two
defs with the same name from different modules into the same scope,
the resolver should emit `QZ0xxx AMBIGUOUS_IMPORT` listing both
source files + suggesting either explicit import-by-name (`import
{sha256} from ...`) or `as` rename.

**B. Module-qualified call sites**. Quartz has the `module$fn`
mangling on the codegen side but no surface syntax to disambiguate
at the call site. If `sha512$compress(...)` were a valid call
syntax that bypasses the resolver's shadow rule, callers could
opt into explicit qualification at hot spots.

A is the safer default — it's a hard error rather than a magic
disambiguation tool. B is a power-user feature that could land
later if A's error message frustrates users.

## Cost estimate

Resolver-side AMBIGUOUS_IMPORT diagnostic: ~30 LoC in
`self-hosted/middle/resolver.qz` (probably; depends on where the
shadow rule lives — search for "all_funcs" + RESOLVE_TAG_FUNC). One
QSpec regression covering 2 modules with same-named def + an
`AMBIGUOUS_IMPORT` expected-fail.

Audit pass to find any existing silent shadows in the stdlib: grep
for `def _[a-zA-Z]+` across `std/`, group by name, flag any that
appear in >1 file. Worth doing as a preventive sweep before
shipping NET.5d/5e/5f (which add more stdlib modules to the mix).

## Related

- [`MULTILINE_BINARY_OPERATOR_SILENTLY_DROPPED.md`](MULTILINE_BINARY_OPERATOR_SILENTLY_DROPPED.md) — sister silent-miscompile shape
- NET.5a.2 design memo decision log — SWAR-mask collision case (post-DCE diagnostic)
- NET.5c.0 design memo decision log (this file's filing context)
