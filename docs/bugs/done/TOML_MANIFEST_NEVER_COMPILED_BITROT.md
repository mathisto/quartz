# `std/toml/manifest.qz` is never-compiled, bit-rotted dead code

> **Status**: ✅ RESOLVED 2026-06-09 by **deletion** (user-ratified, option B below). `git rm std/toml/manifest.qz`; the now-orphaned
> `TomlTable` alias in `value.qz` (added solely for manifest's callsites) was removed with it. toml_spec 36/36 + stringify + traits
> stay green. Closed same day it was filed; kept for the record of *why* a shipped stdlib module never compiled.
> **Decision taken**: delete (D7 pre-launch absolutism).

## Discovery

While porting `std/toml` off sentinel-`nil` (B.15a), a smoke test that `import`s `std/toml/manifest` revealed that
**`manifest.qz` has never been type-checked.** Nothing compiles it:

- No spec imports it (`grep` of `spec/` — only `undefined_type_param_spec.qz` *names* it in a comment; the umbrella
  `std/toml.qz` imports value/lexer/parser/stringify, **not** manifest).
- `quake` does not read `quartz.toml` through it (the build system has its own config path).
- The two `grep` hits outside the module are a comment in `self-hosted/middle/typecheck.qz` and the doc-comment example.

So it is dead code, and being dead, its compile errors were never surfaced.

## The compile errors (all pre-existing, independent of B.15)

1. **`toml_err` is undefined.** `manifest.qz` calls `toml_err(msg, line, col)` (≥4 sites: 688, 695, 700, 703 at HEAD).
   The only definitions in `value.qz` are `toml_ok` and `toml_err_result`. `toml_err` does not exist.
2. **`TomlResult` is non-generic, but manifest uses `TomlResult<Manifest>`.** `value.qz` defines `enum TomlResult` whose
   `Ok` holds a `TomlValue` (not a type parameter); `toml_ok(value: TomlValue): TomlResult`. But `manifest.qz` declares
   `manifest_load(...): TomlResult<Manifest>`, `manifest_from_toml(...): TomlResult<Manifest>`, and calls `toml_ok(manifest)`
   (a `Manifest`, not a `TomlValue`). It was written against a *generic* `TomlResult<T>` API that does not exist. This is the
   load-bearing rot: fixing it requires either making `TomlResult` generic or introducing a `ManifestResult<T>`.
3. **Void/Int `match` arm mismatches (QZ0202).** Pre-existing functions (e.g. `parse_string_array` ~line 423, `parse_dependency`
   ~486) use `match x { <Void-arm> ; _ => () }` where the live arm is `Void` (e.g. `result.push(s)`) and `_ => ()` types as
   `Int` (empty-tuple in the existential model). The two don't unify. This pattern is rejected wherever the sibling arm is
   `Void`. (Note: this same pattern is *fine* when every arm is `return`-terminated — `Never` unifies with anything — which is
   why `value.qz`'s `toml_get_string/int/bool` compile.)

## Relationship to B.15

The B.15 audit (`docs/design/B15_NIL_ELIMINATION.md §3`) counted `manifest.qz`'s `nil` sites as part of the toml surface. That
was correct as a `grep`, but **misleading: those `nil` sentinels live in code that never compiles**, so they were never a live
B.15 concern. The QZ0213 diagnostic (B.15c) only fires on *compiled* code, so dead `manifest.qz` cannot trip it.

**Corrected B.15a scope**: the live, compiled toml nil surface is exactly `value.qz` + `parser.qz` (+ the one real external
consumer, `tools/lint.qz`). That surface is ported and verified green (toml_spec 36/36, toml_stringify_spec, stdlib_traits_spec,
lint.qz compiles). `manifest.qz` was reverted to HEAD and is tracked here instead — committing a half-ported file that still
doesn't compile (for reasons unrelated to nil) would violate D8.

## Decision needed (§4)

`manifest.qz` is a `quartz.toml` package-manifest parser — plausibly intended future `quake` infrastructure, but currently dead
and bit-rotted. Two valid outcomes (D7):

- **(A) Resurrect**: make `TomlResult` generic (or add `ManifestResult<T>`), define/rename `toml_err` → `toml_err_result`-shaped,
  fix the Void/Int match arms (give the no-op arms a `Void`-typed body or restructure), complete the `nil`→`Option` port
  (the edits were drafted this session and reverted — they're a head-start), then wire it into `quake`'s manifest reading and add
  a `manifest_spec`. This is a self-contained sub-project (~1–2 quartz-days, dominated by the generic-Result redesign), **not**
  part of B.15a.
- **(B) Delete**: `git rm std/toml/manifest.qz`. Pre-launch absolutism (D7): dead, never-compiled, no consumers. The
  `quake`-reads-`quartz.toml` need can be rebuilt cleanly atop the now-`Option`-clean `value.qz`/`parser.qz` when actually
  wired up.

Recommendation: **(B) delete**, unless `quake` manifest-reading is imminently on the roadmap — in which case **(A)** as its own
tracked item. Either way it is out of B.15a's scope. Flagged for ratification.

## Repro

```
import * from toml/manifest
def main(): Int = 0
```
`quartz --no-cache -I … std -I tools <that>.qz` → QZ0401 (`toml_err` undefined), QZ0202 (Void/Int match arms), QZ0107
(non-exhaustive match), plus `TomlResult<Manifest>` arity errors.
