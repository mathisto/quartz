# Re-exports (`pub import`) — Tier 3 #14 design memo

**Date:** 2026-04-19
**Status:** Design lock + staged implementation plan. Parser skeleton already shipped; resolver consumption is the outstanding work.

## Question

Roadmap Tier 3 #14: support `pub import foo` so `import json` gives a consumer everything the `json` module's authors want to publish, flattened through its own submodules. What shape should the feature take, and what's the minimum viable version?

## Current state (Apr 19 2026)

Quartz's import surface has 5 forms today (`parser.qz:7030–7110`):

| Form | Meaning |
|---|---|
| `import X` | Module `X` becomes a prefix — call as `X.fn()` or `X$fn()` |
| `import X/Y` | Hierarchical path, short name `Y` as prefix |
| `import * from X` | Wildcard — X's public symbols flatten into caller's scope unprefixed |
| `from X import *` | Alt form of above |
| `from X import a, b` | Selective — named public symbols flatten into caller's scope |

Visibility is file-local and binary — `private` keyword begins a private section; `priv def foo` marks a single item. No `pub` keyword; public is the default. Per-symbol scoping (Rust `pub(crate)`, `pub(super)`) doesn't exist. Private symbols are stored with a double-prefix mangle (`module$$secret`) and never surface to other modules.

**Already shipped for re-exports:**
- Lexer recognizes `pub` as an identifier token.
- `parser.qz:7708–7716` detects `pub import X` and calls `ast_import_set_pub(storage, node, 1)`.
- AST carries the flag; `ast_import_is_pub(s, h)` reads it.

**Not shipped:**
- Resolver never reads `ast_import_is_pub`. A `pub import X` is parsed identically to `import X` once the flag is set — so today, `pub import` does nothing.
- No QSpec coverage for `pub import` semantics (the existing `reexport_spec.qz` tests wildcard transitivity, not `pub import`).
- No grammar for selective or renamed re-exports.

**Three integration points the resolver change must touch** (per `resolver.qz` audit):

1. **`resolve_load_module` / `resolve_collect_funcs` (≈ lines 408–434, 1011–1035)** — where imports become entries in the symbol table. Today it filters private items out when the import is a wildcard. For `pub import`, it must additionally register the imported module's public symbols **under the current module's prefix**, so that downstream consumers of the current module see them.
2. **`resolve_rewrite_node` (line 2056+)** — UFCS rewrite. Dot-calls `M.fn()` get rewritten to `M$fn()`. Re-exported names under prefix `M$` must resolve to their *original* AST nodes (the defining module's), not a newly-minted alias — otherwise codegen duplicates or drops the function.
3. **Conflict detection** — when `M` re-exports `foo` from both `A` and `B`, or re-exports `foo` while also defining its own `foo`, the resolver must emit a hard error at the re-export site.

## Decision

**Ship V1: whole-module re-export only.** Syntax: `pub import X`. Semantics: every public symbol of `X` becomes a public symbol of the importing module, callable as `M.fn()` where M is the importing module. Private symbols of `X` are *not* re-exported. Conflicts are hard errors.

Selective re-export (`pub from X import a, b`) and rename (`pub from X import a as b`) are explicitly deferred to a followup. The V1 form covers the core use case from the roadmap filing ("`import json` gives you everything"). Selective/rename are refinements of V1, not prerequisites — deferring is a clean sequencing decision, not a shortcut.

### Syntax

```quartz
# re-export.qz
pub import std/json/parser       # re-exports all of json/parser's public surface
pub import std/json/writer       # combined with the above, all of both
import std/internal/helpers      # regular import — not re-exported
```

### Semantics

**(1) Re-export scope.** Only *public* symbols of the imported module are re-exported. Private items stay private. This matches the existing privacy model (private names are never visible across module boundaries at all; `pub import` doesn't launder them).

**(2) Prefix.** The re-exported symbols land in the importing module's namespace under the *importing module's* prefix. If module `M` does `pub import N` and `N` defines `parse`, then a consumer `C` that does `import M` can call `M.parse()` (which resolves to `M$parse`), and that call executes `N`'s `parse` body. The function's identity is preserved — there is only one code object, shared between `N$parse` and `M$parse` in the symbol table, pointing at the same AST.

**(3) Transitivity.** Full. If `A` does `pub import B`, and `B` does `pub import C`, then consumers of `A` see `C`'s public symbols as `A.symbol()`. This falls out naturally from (2) — when `A` collects `B`'s public symbols, it collects `C`'s re-exports through `B` because they are, by that point, part of `B`'s public surface.

**(4) Conflicts.** Hard compile-time error with both source paths in the diagnostic:

- Re-exporting `foo` from two modules: `pub import X` + `pub import Y` where both expose `foo` → error QZ0560 (new): `name 'foo' re-exported from both 'X' and 'Y'`.
- Re-exporting `foo` while also defining a local `foo`: error QZ0561 (new): `re-export of 'foo' from 'X' conflicts with local definition`.
- Regular imports of the same name from two modules are already fine today (they resolve via prefix); re-exports are different because the prefix becomes `M$`, so two re-exports of `foo` both want to register `M$foo`.

**(5) No globs.** `pub import * from X` is *not* a form. The wildcard `import * from X` already exists but means "flatten into caller's scope unprefixed" — not "re-export." If a future use case demands glob re-export, it can be added with ambiguity-as-error semantics. Skipping it in V1 avoids the Rust glob-reexport problem that needed multiple lints to paper over.

### What it looks like to a user

**Before (today):**
```quartz
# std/json.qz
import * from std/json/parser
import * from std/json/writer
# parse and stringify are available to us here, but NOT to importers of std/json
```

```quartz
# consumer.qz
import std/json
var ast = json.parse(src)        # ERROR — parse is not part of json's public surface
```

**After V1:**
```quartz
# std/json.qz
pub import std/json/parser
pub import std/json/writer
# parse and stringify are now re-exported under json$
```

```quartz
# consumer.qz
import std/json
var ast = json.parse(src)        # works — resolves to std/json/parser$parse
var out = json.stringify(ast)    # works — resolves to std/json/writer$stringify
```

## Implementation plan

**Phase 1: resolver consumption (~150 lines, 1 session).**
- In `resolve_collect_funcs`, check `ast_import_is_pub` on each import node. When true, for each public symbol in the imported module, also register it under the *current* module's prefix, pointing at the same AST node. The existing `collect` logic already skips privates on wildcard imports — reuse that filter.
- Add conflict detection: when a name is already registered under the current prefix, compare origin. Same AST → idempotent, fine. Different AST → QZ0560/QZ0561.

**Phase 2: transitivity + UFCS rewrite check (~50 lines).**
- Verify `resolve_rewrite_node` routes `M.fn()` through the re-export entry correctly. The existing rewrite machinery looks up `M$fn` in the symbol table; as long as Phase 1 registers `M$fn → same-ast-as-N$fn`, this should Just Work. Test adversarially.

**Phase 3: QSpec coverage (~1 file, 8–10 tests).**
- `spec/qspec/pub_import_spec.qz`:
  - Basic re-export: module `A` does `pub import B`, consumer calls `A.fn_from_b()`.
  - Transitivity: `A pub imports B`, `B pub imports C`, consumer gets `C`'s symbols via `A`.
  - Privacy preservation: `B` has private `secret`, `A pub imports B`, consumer calling `A.secret()` fails.
  - Conflict: two `pub import`s of the same name → QZ0560.
  - Conflict: re-export vs local definition → QZ0561.
  - Mixed: `pub import B` + regular `import C` — only B's symbols re-exported.
  - Call-site identity: `A.fn()` and `B.fn()` hit the same function body (assert via side effect).
  - Regression: `pub import` of a module that itself has no public functions is not an error.

**Phase 4: documentation (~30 minutes).**
- Section in `docs/QUARTZ_REFERENCE.md`: "Re-exports — `pub import`."
- Update `docs/ARCHITECTURE.md` if the module pipeline section describes import handling.

**Phase 5: cleanup (~10 minutes).**
- Grep the stdlib for `import * from` inside barrel-style modules (e.g., `std/json.qz`) that are candidates to convert to `pub import`. Non-binding — just a sweep for ergonomic wins.

**Total**: ~1 quartz-day for Phase 1+2+3. Phase 4–5 are minutes, trailing.

## What was considered and rejected

- **Selective re-export `pub from X import a, b`** — would require parser changes (today's `from X import …` form doesn't accept a `pub` prefix). Deferred to a followup; V1 doesn't need it to close the roadmap item's stated goal.
- **Rename re-export `pub from X import a as b`** — same reason as selective; adds parser grammar work. Defer.
- **Visibility-restricted re-export** (Rust `pub(crate)`, `pub(super)`) — Quartz has no crate/package boundary yet. N/A until there is one.
- **Glob re-export `pub import * from X`** — footgun per prior-art survey (Rust, TS, Python all have silent-ambiguity or last-write-wins issues). Skip unless demand appears.
- **Namespace re-export** (TS `export * as ns`) — Quartz's existing `import X` already provides namespaced access; no gap to fill.

## References

- **Current state**: exploration of `self-hosted/resolver.qz`, `self-hosted/frontend/parser.qz`, `self-hosted/frontend/ast.qz`, `std/json.qz`, and QSpec fixture set. Parser skeleton at `parser.qz:7708–7716`; AST flag at `ast.qz:1978–1982`. Resolver integration points at `resolver.qz:408–434`, `resolver.qz:1011–1035`, `resolver.qz:2056+`.
- **Prior art** (session transcript): 6 languages surveyed (Rust `pub use`, TS `export … from`, Python `__all__`, OCaml `include`/`module M = N`, Elixir `defdelegate`, Go type aliases). Recommendation: "Rust-style minus globs, plus stricter ambiguity." Quartz V1 follows this but trades Rust's selective syntax for the stdlib "whole-module re-export" pattern, which matches the roadmap's stated use case (`import json` gives you everything) at much lower implementation cost. Selective is a V2 conversation.
- **Roadmap filing**: Tier 3 #14 `Re-exports (pub import) — Medium`.

## Verdict

**Ship V1 (`pub import X` only) as a single resolver sprint.** The parser skeleton is already in place and the integration shape is clean. V1 closes the roadmap item's goal ("`import json` gives you everything") and defers selective/rename as a cleanly-separable followup if demand appears. No design-lock-in risk: V2 selective re-export is a superset of V1's semantics.
