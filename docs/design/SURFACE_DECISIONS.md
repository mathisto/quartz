# Surface Decisions — Cohesion Pass (LOCKED 2026-06-17)

**Status:** DESIGN LOCKED, implementation NOT started. These are the owner-ratified outcomes of the surface cohesion audit (`SURFACE_COHESION_AUDIT.md`, 19-item decision queue D1–D19) plus SURF.1 (literals, decided earlier in `SURFACE_SYNTAX_RATIONALE.md` §1). Nothing here is cemented in code yet — the whole surface changes *at once*, after the design is complete, per owner directive ("change everything at once, pre-1.0").

**Guiding principle (carried from the rationale doc):** *one symbol, one job (modulo position); types optional to write, exact to recover; minimal, intentional, unified surface before the one-shot public release.* Pre-1.0 syntax freeze is deliberately reopened for this pass.

---

## 1. Literals (SURF.1 — already decided)
`:` binds in all literals + ascribes types in declarations; `=` is assignment only; **map hashrocket `=>` removed**. Maps `{k: v}` (bareword key = symbol, `"s"` = string, `(expr)` = computed); empty map `{}`. Sets bare `{1,2,3}`; empty set `Set{}`. Structs `Point{x: 3}` nominal. Records nominal; bare `{k:v}` = Map. Detail: `SURFACE_SYNTAX_RATIONALE.md` §1.

## 2. Access / path (D1, D2)
- **D1 — value vs namespace split.** `.` = the single **use-time value access** glyph (field, method, UFCS, paren-elided method, tuple-index `.N`, leading-dot chain). `::` = **namespace/type-level** path (module-qualified types + functions, enum-variant qualification where qualified). **`$` is DELETED from the surface** (it was identical to `::` — parser mangled `::`→`$`). Rationale: preserves the value/namespace cue (valuable as inference makes types implicit), Rust-familiar, *less* migration than collapsing to one glyph (since `::` is already used 74k× in-tree). Migration: formatter-driven rewrite of `$`→`::` (or `.` where value-level).
  - **Sub-decision RESOLVED (2026-06-17): keep `/` for import paths** (`import std/collections`). Imports are file-path-flavored (pointing at where a module lives); the distinct glyph signals the dependency-declaration context vs use-time `::` namespace access. Two glyphs, each fitting its job.
- **D2 — fix the doc-lie NOW (standalone, directive-6).** `QUARTZ_REFERENCE.md` + `SURFACE_INVENTORY.md` claim "NO `::` syntax / imports use `/` / `.` preferred" — false: compiler uses `::` ~87,000× and `.` for modules ~never. Correct the docs immediately, independent of the glyph migration. Shipping the public rationale atop a false reference is worse than admitting the surface is messier than documented.

## 3. Binding & arrows (D5)
- **D5 — collapse the result-of arrow trichotomy.** `->` is THE inputs→result arrow everywhere: **lambda body AND match/select arm body.** **`=>` is DELETED entirely.** `=` is binding/assignment/definition-introduction only. Rationale: one concept (RHS produced from LHS) → one glyph; matches the ML direction (records, inference); `case pat -> body` reads as exactly what it is. Migration: flip every match/select arm `=>`→`->` (stdlib + specs + examples).

## 4. Dots — ranges / spread / slices (D8, D9, D13)
One coherent story, **`..`-family = ranges (incl. slices), `...` = ellipsis:**
- **D8** — `..` exclusive range, `..=` inclusive range (Rust-exact). `...` reserved for ellipsis only.
- **D9** — `...` is the **sole** ellipsis: spread + rest/gather + variadic, position-disambiguated (JS-exact). Kills the `..rest` (gather) vs `...spread` near-collision — both become `...`.
- **D13** — slices ride the range glyphs: `s[a..b]`, `s[a..=b]`. **Colon-slice `s[a:b]` is REMOVED** (kills the hidden 4th colon job). Migration: `0...5`→`0..=5`, `[a, ..rest]`→`[a, ...rest]`, `s[a:b]`→`s[a..b]`.

## 5. Error handling & optionals (D3, D4, D14)
- **D3 — one error model (Rust-shaped).** Keep `Result<T,E>` (value-level errors) + `with Throws`/`throw`/`panic` (unwinding) + **`try`-prefix as the SOLE propagation operator.** **DELETE:** `try`/`catch`-end statement form, the `$try` macro, the `catch` token.
- **D4 — `throw`/`resume`/`handle` → real keywords** (decide before operation-body lowering). Forces renaming `def throw` in `std/throws.qz:47` + ~45 `handle`-site renames now, rather than discovering the `def throw` collision at effect-wiring time.
- **D14 — keep `Option`, kill the *ceremony* not the safety.** Three parts:
  1. **Keep `Option`/`Result`.** No pervasive `nil` (Quartz already enforces this: `return nil` where `Option` expected → QZ0213). We do not reintroduce the billion-dollar mistake.
  2. **ADD flow-narrowing (smart-casts) — NEW, TOP PRIORITY.** After `if x.some?` / `if Some(v) = x`, the compiler proves presence inside the branch → no explicit unwrap. This is the real ergonomic fix (Ruby-like "just use it" *without* Ruby's nil-unsafety). Additive; zero safety loss.
  3. **Collapse the 3 force-unwrap spellings to ONE: terse `expr!`.** `$unwrap` dies with `$` (D1); the `.unwrap()` method form is removed. `!` is the terse, danger-flagged force-unwrap (Some → value, None → trap). Rare in practice (propagation = `try`, common case = narrowing), so rarity discourages overuse; the bang flags danger when it does appear. No better use exists for `!` (`not` is word-only per D10, macros are `$`).

## 6. Visibility (D6)
- **Per-item `priv`/`pub` as REAL keywords** (delete the `private` section model). **Private by default; opt into `pub` to declare your interface.** Rationale: the public surface is near-irreversible (Hyrum's Law — the whole reason for this pass); public-by-default would leak implementation into the forever-contract by inaction. Private-by-default makes exposure a deliberate act = your API is exactly what you typed `pub` on. **Delete the self-rejecting `public` keyword stub** (`parser.qz:503/8371`) regardless.

## 7. Type set-ops (D7)
- **Move union/intersection types to KEYWORDS** while codegen is still incomplete (cheap now, expensive later). Frees `&`/`|` to be **bitwise-only at the value level** and removes the type-position overload (`&` currently means borrow AND intersection). Couples to R2.1 (Union/Record termification) — design together.

## 8. Sigils (D11, D14, D18)
- **D11 — keep `@field` self-shorthand** (`@field` ≡ `self.field`), narrated as the "definition-adjacency sigil." Matches the paren-elision terseness stance. `@` also = decl attributes; the two are position-disambiguated.
- **D14/N7 — bless the `?`/`!` asymmetry as law:** a trailing glyph is *either* part of an identifier *or* a postfix operator, never both. **`?` = predicate name-char** (`.some?`, `.empty?`). **`!` = postfix force-unwrap operator only.** (The old `!`-mutation convention `push!`/`sort!` is already gone — see verb-pairs below.)
- **D18 — backtick `` ` `` RESERVED, unused.** NOT shell-command interpolation (injection footgun, effect-invisible, platform-coupling, scarce-glyph spend). Shell-out stays an explicit, effect-tracked stdlib API (`run(...) -> Result`). Reserve the backtick for a possible future use (raw identifiers / raw strings), decided later.

## 9. Operators (D10, D17)
- **D10 — boolean ops are word-only: `and` / `or` / `not`.** Remove `&&`/`||` lexings; frees `&`/`|` for bitwise, `!` for force-unwrap only. The word-logical vs symbol-bitwise category split is the permanent stance.
- **D17 — `+` is numeric-add or same-type `String + String` concat only.** **Remove silent cross-type coercion** (`"x" + 3.0`); make it a type error with a friendly message: *"use `#{...}` interpolation or `to_str(...)`."* (Interpolation desugars to the same `str_concat`/`to_str` machinery — `ARCHITECTURE.md:196` — so the paths are identical at IR level.) Rationale: silent coercion contradicts the explicit-erasure ethos (`as_type`).

## 10. Keyword cleanup (D15, D16)
- **D15 — purge `let` entirely.** Delete `TOK_LET` (`lexer.qz:1641`), remove `if let`/`while let` parser paths (`parser.qz:3977/4076`) — they migrate to the refutable-bind `=` (`if Some(v) = expr`). Ends the forbidden/undocumented/silently-accepted limbo.
- **D16 — promote `case`/`default` to real keywords** (uniform with `when`), pending a stdlib grep first (`default` is a common variable name — confirm no collisions before promoting).

## 11. Tuples (D19)
- **1-tuples are UNSUPPORTED, documented.** `()` = unit, `(x)` = grouping, tuples start at 2 (`(a, b)`). No `(x,)` syntax, no `Tuple.new` (tuples are structural, not nominal). For a named single-field aggregate, use a struct/`@value`. (1-tuples essentially never arise in hand-written code; spend zero syntax on them.)

## 12. Naming convention (confirmed, already documented)
- **Mutation vs copy is a verb pair, not a sigil** (`COLLECTIONS_STYLE.md:97`): imperative verb mutates in place (`v.sort()` → Void), past-participle returns a new copy (`v.sorted()` → Vec). Realistic set: `sort`/`sorted`, `reverse`/`reversed`, plausibly `shuffle`/`shuffled`, `dedup`/`deduped`. Applies ONLY where an op has both a sensible in-place and copy form; pure-only (`map`) and mutate-only (`push`) ops stay bare. Do not over-apply.

## 13. Auto-fixes (not owner-discretion — do regardless)
- **N10** — fold map-comprehension `{k => v for ...}` → `{k: v for ...}` into the SURF.1 hashrocket removal (last surviving `{}` hashrocket; `REF:1892-1894`).
- **M1** — delete the stale `push!`/`sort!` row (`STYLE.md:80`) contradicting the v5.28 lexer + the verb-pair convention.
- **M9/M10/H** — write the bracket-family invariant into the rationale: "a bracket pair names a container category; interior shape selects the subtype; `<>` is the documented type-level pseudo-bracket exception."

## 14. Deferred (roadmapped, revisit)
- **D18 loop labels** — `:outer` (current symbol-colon) vs `'outer` (apostrophe, Rust-style; apostrophe is the front-runner, needs char-literal-vs-label lexer disambiguation like Rust). **Defer** until we observe whether SURF.1 bareword-keys actually crowd the colon-symbol space.

---

## Implementation sequencing (when design is complete)
Surface-affecting changes land together ("change everything at once"). Rough dependency order: docs-lie fix (D2) → flow-narrowing (D14, top priority, additive) → the formatter-driven mechanical migrations (D1 `$`→`::`, D5 `=>`→`->`, D8/D9/D13 dots, D17 coercion, D15 let-purge) → keyword promotions (D4, D6, D7, D10, D16) → cleanups (N10, M1). All gated through `quake guard`; SURF.1↔R2.1 and D7↔R2.1 designed together. Trusted-reader feedback (SURF.6) before the surface re-locks.
