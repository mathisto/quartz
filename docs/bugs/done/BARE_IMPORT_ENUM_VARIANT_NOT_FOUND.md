# Bare `import x` doesn't expose enum variants for cross-module construction

**Date filed:** 2026-05-08
**Filer:** Claude (paperclips-tui dogfood session)
**Status:** **CLOSED 2026-05-08** — same-day fix (parser-side disambiguation, see closure footer below).
**Severity:** Mid — silent, unhelpful diagnostic, affects every multi-file program with a shared enum
**Discovered while:** building `examples/tui/paperclips/` (Universal Paperclips reimagining)

## TL;DR

Bare `import x` gets the file basename as a namespace for **types and functions** but **not for enum-variant construction**. The variant access `x::EnumType::Variant` fails resolution with "undefined variable: x$EnumType$Variant" even though:

- `x::EnumType` resolves fine in type annotations
- `x::some_function()` resolves fine in expression position
- The same exact code with `import x as x` (explicit self-alias) works

The asymmetry is undocumented. Match-arm patterns also work (probably because they resolve the type from the scrutinee, not via the resolver).

## Repro

Two files in the same directory:

```qz
# model.qz
enum AppMsg
  Tick
  Quit
end

struct State
  ticks: Int
end

def state_initial(): State = State { ticks: 0 }
```

```qz
# main.qz
import model

def main(): Int
  var s: model::State = model::state_initial()       # ✅ works (type + function)
  var msg: model::AppMsg = model::AppMsg::Tick       # ❌ "undefined variable: model$AppMsg$Tick"
  return 0
end
```

Compile:
```
quartz -I . main.qz
```

## Workaround

Self-alias the import:

```qz
import model as model
```

After this single change, `model::AppMsg::Tick` resolves cleanly. No other source change required.

## Why this matters

Multi-file Quartz programs with shared enums are a *normal* shape — split state from UI, scene from view, message types from reducers. Universal Paperclips (TUI dogfood) hits this immediately: the `AppMsg` enum (Tick / MakeClip / BuyWire / PriceUp / PriceDown / RequestSave / ClearStatus) lives in `model.qz` and is constructed in `main.qz`'s thunks (`tick_thunk()` returns `tui::FrameMsg::App(model::AppMsg::Tick)`).

Without the workaround, the diagnostic ("undefined variable: model$AppMsg$Tick") points at the **constructor expression**, not at the import statement, and gives no hint that aliasing is needed. A first-time author is likely to:

1. Triple-check the variant spelling in `model.qz` (correct)
2. Check the import path (correct)
3. Suspect a circular-import or build-cache issue
4. Eventually discover by accident that other widget specs use `import x as x`

That's a 30-minute mystery for a 1-character fix.

## Symptoms checklist

If the fix lands, these all become uniform:

| Surface | Bare `import x` | `import x as x` |
|---|---|---|
| `x::Type` in annotation | ✅ | ✅ |
| `x::function()` call | ✅ | ✅ |
| `x::Type { fields }` struct literal | ✅ | ✅ |
| `x::EnumType::Variant` construction | ❌ "undefined" | ✅ |
| `x::EnumType::Variant(payload)` ctor | ❌ "undefined" | ✅ |
| `x::EnumType::Variant => ...` match arm | ✅ | ✅ |

The match-arm column working is what makes this *especially* confusing: the same `x::EnumType::Variant` text resolves in pattern position but not in expression position.

## Suspected root cause (unverified)

Quartz mangles `x::Y::Z` to `x$Y$Z` for symbol lookup. For functions / types defined in `x.qz`, the resolver registers symbols under both the file-basename namespace (`x$function_name`) and the `as`-aliased namespace if any. Enum variants are emitted as global constants (nullary) or constructors (with payload); their symbols may only be registered under the *aliased* namespace, not the bare file-basename one.

Likely fix locus: `self-hosted/resolver.qz` — when registering enum variants from an imported module, register them under the file-basename namespace too (matching the existing behavior for functions and types).

Alternative: make `import x` emit an implicit `as x` clause at parse time. Cheaper if the resolver path is hard to change.

## What this is NOT

- Not a missing-import error — bare `import x` is what every existing example uses
- Not specific to `model.qz` as a name — same shape with any file (renamed `state.qz` → `model.qz` in the original repro to rule out collision with `std/state.qz`; bug persists)
- Not a generic-enum thing — `AppMsg` is non-generic, has 7 nullary variants
- Not match-arm related — match arms work fine; only construction fails
- Not order-of-imports related — tried `-I` reordering, no effect

## Verification artifact

`examples/tui/paperclips/main.qz` is the live program demonstrating the workaround. All files in `examples/tui/paperclips/` use `import X as X` shape.

After fix, the workaround can be reverted (single `sed` over the dir) and the program should compile + run identically.

## Lesson, if there is one

Resolver registration paths benefit from a **uniform "register under all namespaces this symbol is reachable from"** discipline. The current asymmetry (some symbol classes register only under aliased names) is a footgun that bites every consumer differently. Sister memo: the resolver's prefix-rewrite walker had a similar coverage gap (`feedback_resolver_rewrite_coverage_gap.md`) that needed each new AST kind enumerated explicitly with no fallthrough default.

## Closure (2026-05-08)

**Root cause:** parser, not resolver. The "suspected resolver registration asymmetry" framing was wrong — variants aren't registered as global identifiers under *any* namespace; they only exist inside `NODE_ENUM_ACCESS` and are resolved via the typecheck registry's enum-name + variant-name pair. The actual asymmetry was at the parser's `::` disambiguator (`parser.qz:1935`): bare `import x` did not push the file basename to `ps.import_aliases`, so the alias-drop branch never fired for bare-imported modules. `x::Enum::Variant` then went through the `module_path::function`-style mangle and emerged as a single ident `x$Enum$Variant`, which is registered nowhere.

**Fix (`self-hosted/frontend/parser.qz`, two edits):**

1. `ps_parse_import` now pushes the file basename to `ps.import_aliases` for bare imports too, mirroring the explicit-alias path. Hierarchical imports (`import a/b/c`) push only the last segment.
2. The disambiguation rule at `ps_parse_ident_expr` was tightened to require the **3-segment** shape `module::Type::Variant` (peek-after-`Type` is `::`). 2-segment shapes (`module::Type`, `module::CONST`, `module::function()`) keep the `$`-mangle behavior so scope-bound globals (registered as `prefix$name` with no suffix-fallback in `tc_scope_lookup`) and already-prefix-registered functions/types resolve via exact match. Without this tightening, `config::SETTING` (global var via bare import) regresses — `diamond_import_spec` caught it before commit.

**Side-effect win:** the same fix unifies bare and explicit-alias paths, so the latent shape `import x as e; e::SETTING` (uppercase global through alias, previously broken) also works now.

**Verification:**
- Symptom matrix from this doc: all 6 surfaces uniform ✓
- New regression spec `spec/qspec/import_enum_variant_construction_spec.qz` (6 tests) ✓
- Sister `import_alias_enum_variant_spec` (5 tests, no regression) ✓
- `diamond_import_spec` (6 tests, including the global-via-bare-import case) ✓
- 7 other cross-module specs: all clean
- `quake guard` fixpoint at 2149 functions ✓
- Smoke tests `style_demo.qz` + `brainfuck.qz` ✓
- **Paperclips Phase 1A** (commit 050feb96 source) with bare imports compiles + links clean ✓

**Calibration:** memo predicted resolver fix; actual fix was the parser. Pre-flight grep on `import_aliases` would have surfaced the parser-side path immediately. Sister to `feedback_handoff_diagnosis_verify.md` — bug-doc diagnoses are starting points, not ground truth.
