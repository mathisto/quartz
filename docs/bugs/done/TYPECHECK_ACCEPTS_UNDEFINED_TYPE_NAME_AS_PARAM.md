# Typecheck silently accepts undefined type names in parameter position

> **CLOSED-STALE 2026-07-07** — re-reproduced fixed on current binary; see docs/sagas/r24-groundwork-inert-holes-2026-07-07-research/ws2-triage.md (QZ0220 hard-error, fixed 2026-05-21 — SHA not pinned).

**Filed:** 2026-05-07 (discovered while shipping MAP_GET Path A —
`std/toml/value.qz` narrowing).
**Status:** ✅ FIXED 2026-05-21. QZ0220 now fires on a `def f(x: SomeName)`
or `def f(): SomeName` callsite whose annotation is a simple
`[A-Z][A-Za-z0-9_]*` identifier that doesn't resolve to a known type
(builtin / struct / enum / type alias / newtype / protocol / trait
type-param / generic tp-var of the enclosing function or impl).

## Resolution (2026-05-21)

Both paths from the original report shipped together (commit landed on
trunk alongside this doc update):

* **Path A — diagnostic.** New error code `QZ0220` emitted from
  `tc_register_function_signature_named` for parameter types and return
  types. The check uses the existing TYPE_ERROR sentinel produced by
  `tc_parse_type` and gates on a "simple type-name shape" predicate
  (`_tc_looks_like_simple_type_name`) so complex annotations (generics,
  Fn-types, borrows, tuples, records, module-qualified, lowercase tp-vars,
  bare `T`) don't false-positive. Existing tp-var fallback to TYPE_INT
  fires first and suppresses the diagnostic for legitimate
  `def f<T>(x: T)` shapes.
* **Path B — `TomlTable` alias.** `type TomlTable = Map<String, TomlValue>`
  added to `std/toml/value.qz` so the 8 original sites in
  `std/toml/manifest.qz` resolve cleanly.

Two adjacent fixes also landed because Path A surfaced them:

* **Missing built-in type-name resolutions.** `tc_parse_type` did not
  recognize the bare names `StringBuilder`, `Set`, `Range`, `IntMap`,
  `HashMap`, `Mutex`, `Arena`, `Pool`, `ArenaPool`, `Task`, `TaskGroup`,
  `Future` as annotations — they all existed as runtime types with
  `TYPE_<kind>` constants but had no `if annotation == "Name" → TYPE_NAME`
  handler. Annotations using them fell through to TYPE_ERROR and
  existentially erased. Eleven new handlers added after the `AtomicInt`
  line. Quakefile.qz's `StringBuilder` parameter types now resolve
  correctly.
* **Pre-existing `StringBuffer` typo in parser.qz.** `ps_parse_struct_destr_fields`
  and `ps_parse_vec_destr_elems` had parameter type `StringBuffer`
  (does not exist) instead of `StringBuilder`. Silent erasure made the
  code work at runtime; QZ0220 surfaced the typos.

Regression spec: `spec/qspec/undefined_type_param_spec.qz` — five cases
covering (1) undefined param-position, (2) undefined return-position,
(3) tp-var false-positive guard, (4) StringBuilder primitive
resolution, (5) `type Alias = ...` resolution.

Fixpoint verified via `quake guard` (2540 functions, gen1 ≡ gen2).
Rule 2 smoke: style_demo + brainfuck green on the new binary.

## Known follow-ups

`std/toml/manifest.qz` (969 LOC, orphaned — no module imports it)
contains pre-existing bugs that the new diagnostic exposes IF someone
imports it: 10 QZ0202 match-arm type mismatches and 4 QZ0401
"undefined function `toml_err`" calls. These were always there; before
QZ0220 the `TomlTable` errors short-circuited resolution and masked
them. Since nothing imports `manifest.qz` today, the dormant errors
don't gate the build or the suite. Filed for future cleanup as
`docs/bugs/done/TOML_MANIFEST_PRE_EXISTING_BUGS.md` — now MOOT: the
whole file `std/toml/manifest.qz` was deleted (`cef12588`, D7 pre-launch
absolutism applied).

## Original report (2026-05-07)

`std/toml/manifest.qz` references `TomlTable` as a parameter type at
8 sites:

```qz
def parse_package_section(table: TomlTable): PackageInfo
def parse_dependencies_section(table: TomlTable): Vec<Dependency>
def parse_features_section(table: TomlTable): Vec<Feature>
def parse_bin_target(table: TomlTable): BinTarget
def parse_lib_section(table: TomlTable, pkg_name: String): LibTarget
def parse_example_target(table: TomlTable): ExampleTarget
def parse_profile_section(table: TomlTable, name: String): Profile
def manifest_from_toml(doc: TomlTable): TomlResult<Manifest>
```

`TomlTable` is **never defined anywhere in the codebase** — not as a
struct, enum, type alias, or imported symbol. Repo-wide grep
(`grep -rn "TomlTable" --include="*.qz"`) returns only the 8 use
sites; no decl.

The typecheck accepts it silently. The Quartz compiler builds clean
with this code today; manifest_load() runs without runtime crashes.
The implied behavior is existential erasure — undefined names in
parameter position degrade to `Int` (the universal handle width).

## Original reproducer

Trivial — no `import` of TomlTable needed:

```qz
def takes_tbl(table: TomlTable): Int
  return 0
end

def main(): Int
  return takes_tbl(42)
end
```

Today this errors:

```
error[QZ0220]: undefined type name 'TomlTable' in parameter position.
The compiler doesn't know this type — check for a typo, a missing
`import`, or a missing `type` / `struct` / `enum` definition.
 --> repro.qz:1:20
 |
1 | def takes_tbl(table: TomlTable): Int
 |                    ^
```

## Why it mattered

1. **Silent acceptance broke the typed-handle precedent.** `std/toml/value.qz`
   was narrowed to return `Map<String, TomlValue>` (commit `1a7d75e6`). The
   intent: typed handles flow through the API. But manifest.qz silently
   stripped the type at every parameter boundary because `TomlTable`
   erased. If a future reader assumes `TomlTable == Map<String, TomlValue>`
   based on the file's surroundings, that assumption is now actually
   enforced by the type system via the new alias.

2. **Latent bug if `TomlTable` is later defined.** If someone added
   `type TomlTable = Map<String, TomlValue>` to `std/toml/value.qz`
   thinking it was a no-op cleanup, the existing manifest.qz callers
   would suddenly start enforcing the typed-handle contract. Internal
   callers that pass bare `Int` (from `toml_table_get` returning Int,
   etc.) would fail typecheck. Sequencing matters. This is now
   moot — Path B added the alias as part of the fix; the typecheck
   contract is now active.

3. **Auditing for the broken-name pattern is no longer optional.** The
   diagnostic IS the audit. Every future `def foo(x: SomeName)` whose
   name doesn't resolve produces a hard error at the site.
