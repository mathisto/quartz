# Surface Syntax Cohesion Audit

**Status:** Synthesis for owner review. You PROPOSE nothing here — this doc proposes; you decide.
**Date:** 2026-06-16
**Scope:** Every surface glyph and keyword, audited for split-brain (one concept spelled many ways), arbitrary overload (one glyph doing unrelated jobs with no disambiguation principle), and legacy cruft. SURF.1 (literals: `nil`/`true`/`false`, map `{k: v}`, struct `Type{...}`) is **already decided and is OUT of scope** — it is treated as landed and only relitigated where it leaves a *residual* contradiction the SURF.1 doc did not close.

Grounding: this synthesis is built from six family-level analyses plus direct verification against the live compiler. The per-symbol audit pass produced **zero** outputs, so every load-bearing claim below was re-checked against source. Verified facts are cited `file:line`.

---

## 1. Executive Summary

**Overall verdict: COHERENT SKELETON, THREE CONCENTRATED SPLIT-BRAINS, ONE DOC-VS-REALITY LIE.**

Quartz's surface is *not* a grab-bag. There is a real, defensible underlying system in most families: bracket pair = container category (interior shape picks subtype); word-logical vs symbol-bitwise is a clean intentional split; most sigils carry one concept disambiguated by position. The lexer has been actively *converging* the surface (v5.28 freed `!` for force-unwrap; SURF.1 unified literals). The owner is steering toward "one symbol, one job (modulo position)."

But the incoherence is **concentrated, not diffuse**, and it clusters in five places:

1. **ACCESS/PATH is the worst problem in the entire surface — and it is invisible from the docs because the docs are factually wrong about it.** "Reach into a namespaced thing" is spelled FIVE ways (`.` `$` `::` `/` `.N`), two of which (`$` and `::`) are *literally the same operation* — the parser mangles `::` → `$` (parser.qz:624-626). The reference says "NO `::` syntax / imports use `/`" and "`.` is preferred," but the self-hosted compiler uses `::` **~87,000 times** and `module.func()` essentially never. **The language the compiler is written in is not the language the compiler documents.** This is a directive-6 hole shipping in the public-facing reference.

2. **ERROR HANDLING — three mechanisms, one concept, mid-flight migration left both spellings live.** `try`/`catch`-end, `try`-prefix-propagate, `$try` macro, `Result<T,E>`, `throw`/`with Throws`, and `panic` all address "an operation failed." `try` is overloaded (prefix-propagate vs statement-with-catch, by lookahead), and the parser comment says try-prefix "replaces" `$try` while both remain live. `throw` is simultaneously a reserved-but-unlexed token constant AND a live std function (std/throws.qz:47) — a collision waiting at the effect-wiring milestone.

3. **THE "RESULT-OF" ARROW TRICHOTOMY — `->` vs `=` vs `=>` all mean "RHS is the value produced from the LHS,"** chosen by syntactic host, not by meaning: lambda body `->`, endless-def body `=`, match/select arm body `=>`. A reader learns "arrow = small function from pattern to result" three times with three glyphs.

4. **VISIBILITY — four spellings across two grammars, one of which exists only to reject itself.** `private` (section keyword), `priv` (per-item contextual ident), `pub` (re-export contextual ident), and `public` — a reserved keyword whose *entire purpose* is to emit "public is not a keyword in Quartz" (parser.qz:503, 8371).

5. **`...` AND DOT-COUNT ARE DOUBLE-DUTY ACROSS UNRELATED AXES.** `...` is both inclusive-range (`0...5`) and spread (`[...a]`); `..` is exclusive-range AND destructure-rest gather (`[a, ..rest]`). So dot-count toggles inclusivity in range context but range-vs-spread elsewhere, and gather (`..rest`, two dots) vs spread (`...a`, three dots) are inverse operations spelled with near-identical sigils inside the *same* bracket (REF:926 vs 1872).

Plus a tail of smaller items: redundant boolean spellings (`&&`/`and`, `||`/`or`, `!`/`not` all collapse to the same tokens), the stale `push!`/`sort!` row in STYLE.md:80 contradicting the v5.28 lexer, `let` in a forbidden/undocumented/silently-accepted third state, the map-comprehension hashrocket `{k => v for ...}` surviving SURF.1 (REF:1892-1894), slice-colon `s[a:b]` as a hidden fourth colon job, and `+` doing silent String-coercion against the explicit-erasure ethos.

**The shape of the fix:** the type-annotation side is already coherent (its one wart, signature-spine density, has the owner-approved SURF.2 `where` fix queued). The access family needs ONE glyph decision that cascades through everything. Error handling and visibility each need a "pick one, delete the rest" call — trivial under D7 (zero users). The arrow trichotomy and the `...`/dot-count overload are the two genuine taste-calls with no clearly-correct answer.

---

## 2. Ranked Incoherence List (egregious → minor)

Severity key: **EGREGIOUS** = doc-vs-reality lie or a concept with 3+ live spellings; **NOTABLE** = real overload/split with a principled-but-undocumented or arbitrary resolution; **MINOR** = wart, redundancy, or doc sweep.

### EGREGIOUS

| # | Finding | Symbols | Fix direction |
|---|---------|---------|---------------|
| E1 | **Docs actively misdocument `::`.** REF + SURFACE_INVENTORY say "NOT a path separator," "imports use `/`," "Wrong: `import a::b`" — but the compiler uses `module::Type`/`module::func()` **~87,000×** (verified). Doc lies in the public reference. | `::` `.` `$` | Fix docs *now* (directive-6 hole), independent of glyph unification. |
| E2 | **Module access has three spellings, two identical.** `module.member`, `module$member`, `module::member` all reach into a module; parser mangles `::`→`$` (parser.qz:624-626) so `::` and `$` are the *same op*, two glyphs. Dogfood corpus uses `::` (74k) + `$` (25k); `.` essentially absent — opposite the "`.` preferred" doc. | `.` `$` `::` | Pick ONE (recommend `.`); delete the other two from surface; formatter-driven corpus rewrite. |
| E3 | **Error handling: three+ mechanisms, one concept, both spellings live mid-migration.** `try`/`catch`-end, `try`-prefix, `$try` macro, `Result`, `throw`/`with Throws`, `panic`. `try` overloaded by lookahead; parser comment says try-prefix "replaces" `$try` yet both ship. | `try` `catch` `$try` `throw` `panic` `Result` `with Throws` | Keep `Result` + `with Throws`/`throw`/`panic`; pick `try`-prefix as sole propagation; DELETE try/catch-end + `$try` + `catch` token. |
| E4 | **RESULT-OF arrow trichotomy.** `->` (lambda body), `=` (endless-def body), `=>` (match/select arm) all mean "RHS is value produced from LHS," chosen by host not meaning. | `->` `=` `=>` | Taste-call: lock crisp 3-role split & document, OR collapse arms onto `->` and delete `=>`. |
| E5 | **`throw` is a keyword AND a function.** `TOK_THROW` reserved-but-unlexed (lexer.qz:1692) while `def throw(msg)` is a live std function (std/throws.qz:47). Same for `resume`/`handle` (~45 `handle` collision sites flagged). Collision lands at effect-wiring milestone. | `throw` `resume` `handle` | Decide keyword-vs-function NOW, before operation-body lowering; rename `def throw` or drop the token. |

### NOTABLE

| # | Finding | Symbols | Fix direction |
|---|---------|---------|---------------|
| N1 | **Visibility: four spellings, two grammars, one self-rejecting stub.** `private` (section kw), `priv` (per-item ident), `pub` (re-export ident), `public` (reserved word that only emits "public is not a keyword," parser.qz:503/8371). CLAUDE.md calls `priv` a keyword — it isn't. | `private` `priv` `pub` `public` | Pick ONE model (recommend per-item `priv`/`pub` as real keywords); delete the `public` stub regardless. |
| N2 | **`...` double-duty across unrelated axes.** Inclusive-range (`0...5`) vs spread (`[...a]`/`{...base}`/variadic `args...`). `..` is exclusive-range AND destructure-rest. Dot-count means inclusivity in one context, range-vs-spread in another. | `..` `...` | Adopt Rust `..`/`..=` for ranges, reserve `...` for spread/rest only. |
| N3 | **Gather-vs-spread dot-count near-collision inside `[]`.** `[a, ..rest]` (two dots, gather) vs `[...a]` (three dots, spread) — inverse ops, near-identical sigils, same bracket (REF:926 vs 1872). | `..rest` `...spread` | Unify on `...` for both (JS-exact), disambiguate by position; OR keep distinct on purpose (dot-count telegraphs direction). |
| N4 | **`&` triple-overloaded.** Bitwise-and, borrow (`&x`/`&mut x`, parser.qz:705/3412), intersection-type (`Eq & Ord`, QZ0150/QZ0151). In type position `&` means BOTH borrow and intersection. | `&` `&mut` | Decide type-composition story: keep `&`/`|` with published positional table, OR move union/intersection to keywords while still codegen-incomplete. |
| N5 | **`|` (pipe) five-way overloaded.** Bitwise-or, union type, pattern or-arm, task_group binding delimiters (parser.qz:765/932/1406/3595). | `|` | Same decision as N4; tie together as one "type-set-ops glyph policy." |
| N6 | **`@` two unrelated concepts on one token.** Decl-attribute (`@value`, `@derive`) vs expression self-field shorthand (`@field` ≡ `self.field`). Compile-time metadata vs runtime field access — share nothing. | `@` | Document as "definition-adjacency sigil," OR retire `@field` for explicit `self.field` (Rust/Swift) making `@` attribute-only. |
| N7 | **`?`/`!` asymmetric collision resolution, undocumented.** `?` kept as ident-suffix (predicates `.some?`), killed as operator. `!` did the opposite (v5.28: killed ident-suffix, kept force-unwrap operator). Two opposite resolutions of the identical problem. Defensible, reads as a bug. | `?` `!` | Document the rule: "a glyph is EITHER a trailing-ident char OR a postfix op, never both." Bless the asymmetry. |
| N8 | **Variant construction vs matching disagree on qualification.** Construction qualified (`Option::Some(42)`), match arms + `is` REQUIRE unqualified (`Some(v)`, `val is Some`). Same variant, two spellings by context. | `::` `is` match-arms | Pick one direction (recommend unqualified-everywhere with type-directed disambiguation). |
| N9 | **`::` lone namespace-reach glyph the idiom routes around.** `::` is the only place `::` is legal, yet it's the *discouraged* form in the two contexts variants appear most (match prefers unqualified, `is` requires it). Near-vestigial. | `::` | Fold into the access-glyph decision (E2); retiring it tightens the access cluster. |
| N10 | **Map-comprehension hashrocket survives SURF.1.** SURF.1 removes `=>` from map *literals* (`{k: v}`) but never mentions map *comprehensions*; `{k => v for ...}` still ships (REF:1892-1894). Post-SURF.1 the same `{}` reads keyed-binding two contradictory ways by whether `for` appears. | `=>` `{}` | One-line SURF.1 extension: `{k: v for ...}`. Recommend yes, not owner discretion — it's a contradiction SURF.1 will otherwise ship. |
| N11 | **Slice-colon is a hidden fourth colon job.** `s[a:b]`/`s[:b]`/`s[a:]` use `:` as a range separator inside `[]` — neither ascription nor binding (the two jobs the colon rationale covers). Quartz already HAS a range glyph (`..`). | `:` `[]` `..` | Taste-call: keep Python-familiar `s[a:b]`, OR switch to `s[a..b]` (one range notion, kills hidden colon). Weakest unification — flagged as close. |
| N12 | **Pattern-binding `=` is refutable test-and-bind.** `if Some(v) = expr` makes `=` mean refutable test-and-bind — the opposite of irrefutable assignment. Rust uses `if let` precisely to flag this. | `=` | Affirm bare `=` is intentional (context-disambiguates philosophy), OR add a marker. Owner affirmation, lean keep. |

### MINOR

| # | Finding | Symbols | Fix direction |
|---|---------|---------|---------------|
| M1 | **STYLE.md:80 stale `push!`/`sort!` row** contradicts v5.28 lexer (lexer.qz:1620-1622) and COLLECTIONS_STYLE.md:114. Three docs, three stories about `!`. | `!` | Required sweep: delete the row, replace with verb-pair rule (`sort`/`sorted`) + force-unwrap meaning. Not a taste-call. |
| M2 | **`let` in a forbidden/undocumented/silently-accepted third state.** `TOK_LET` live (lexer.qz:1641); CLAUDE.md says "no `let` keyword"; parser accepts `if let`/`while let` (parser.qz:3977/4076). | `let` | Full removal (replace if-let with `if var`), OR reinstate as documented pattern-binding keyword. Pick one truth. |
| M3 | **Redundant boolean spellings.** `&&`/`and`→TOK_AND, `||`/`or`→TOK_OR, `!`/`not` both negate. Two surface spellings per op, identical post-lex. | `&&` `and` `||` `or` `!` `not` | Pick one (recommend word-forms; frees `&`/`|` for bitwise, `!` for force-unwrap only). |
| M4 | **`+` silent String-coercion.** `+` is add, String concat, AND float→String concat-coercion (REF:5325), one-directional/asymmetric. Contradicts explicit-erasure ethos (`as_type`, `as_int_generic`). | `+` | Make symmetric+explicit via `to_str`, OR String-only-both-sides + mandatory interpolation (more honest). |
| M5 | **`case`/`default` contextual idents, `when` a real keyword.** Arm-introducers inconsistent: `case`/`default` lexed TOK_IDENT (shadowable), sibling `when` is TOK_WHEN (not). | `case` `default` `when` | Promote `case`/`default` to keywords (grep stdlib first — `default` is a common name), OR demote `when`. |
| M6 | **1-tuple inexpressible, undocumented.** `(x)` is always grouping; no `(x,)` documented. | `()` | Document `(x,)` convention OR explicitly declare 1-tuples unsupported. |
| M7 | **Bareword map-key / `:sym` / `:outer` overlap.** SURF.1 makes `name:` a symbol key; coexists with `:ok` symbol literal and `:outer` loop label (a compile-time control target, not a runtime symbol). | `:` `:sym` | Document the three colon-symbol forms, OR adopt Rust tick `'outer` for labels. Defer until SURF.1 crowding observed. |
| M8 | **`#{` flips meaning on lexer string-mode.** `#`=comment, `##`=doc, `#{`=interpolation-open inside strings / comment-start outside. Meaning depends on invisible lexer state. | `#` `##` `#{` | Document only; no human misreads it. Position/mode-resolved by design. |
| M9 | **`<>` is a pseudo-bracket.** Reuses `TOK_LT`/`TOK_GT`, recovered only in type position; forces `a<b>c` / `f<T>(x)` ambiguity class. Coherent among its 3 jobs but doesn't join the bracket-pair-as-container principle. | `<>` | Document as the explicit type-level exception to the bracket-family invariant. |
| M10 | **No stated bracket-family invariant.** `()/[]/{}` are coherent-by-accident: bracket = container category, interior shape = subtype — but the rule is nowhere written, and the three pairs encode "which subtype" via three different mechanisms (token-prefix `{}`, interior-token `[]`, surrounding-context `()`). | `()` `[]` `{}` | Write the invariant (with its exceptions) into the rationale. Doc-only. |

---

## 3. Cross-Cutting Unification Themes

### Theme A — "Reach into a namespaced thing" is spelled 5 ways
`.` `$` `::` `/` `.N`. Two (`$`/`::`) are identical (parser mangle). The conceptual axis is ONE: namespacing.
**Unified scheme:** `/` stays as the file-path-flavored *import* separator (import time). At *use* time, collapse to a single glyph. Recommendation: `.` everywhere for value-level access (fields, methods, module functions, tuple-index `.N`); if the owner wants a term/type distinction, reserve `::` for type-level paths (module-qualified types + enum variants) and delete `$`. Either way `$` dies — it earns no distinct job.

### Theme B — "Produce a value from inputs" is spelled 3 ways
`->` (lambda), `=` (endless-def body), `=>` (match/select arm).
**Unified scheme (deepest):** `->` is THE inputs→result arrow everywhere (lambda + arms, à la Haskell/OCaml/Koka); `=>` deleted entirely; `=` reserved for binding/assignment/definition-introduction only. **Unified scheme (minimal):** lock three crisp non-overlapping roles — `=` introduces a binding/definition, `->` is the lambda arrow, `=>` is the arm arrow — and document the law. Both are coherent; shipping the un-narrated trichotomy is not.

### Theme C — "Failure of an operation" is spelled 3+ ways
`try`/`catch`, `try`-prefix, `$try`, `Result`, `throw`/`with Throws`, `panic`.
**Unified scheme (Rust model, already cited by ERROR_HANDLING_UNIFICATION):** `Result<T,E>` for value-level errors; `with Throws`/`throw`/`panic` for unwinding; `try`-prefix as the *sole* propagation operator. Delete try/catch-end, `$try`, and the `catch` token.

### Theme D — "Visibility" is spelled 4 ways
`private` `priv` `pub` `public`.
**Unified scheme:** one model. Recommend per-item `priv`/`pub` promoted to real keywords (matches Rust/Swift, composes with re-export); delete the `private` section model. Delete the self-rejecting `public` stub regardless of which model wins.

### Theme E — Dots (`..` / `...`) straddle range and ellipsis
Inclusivity toggle in range context, range-vs-spread elsewhere, gather-vs-spread within `[]`.
**Unified scheme:** `..` = exclusive range, `..=` = inclusive range (Rust-exact), `...` = the sole ellipsis (spread + rest + variadic), with gather/spread both `...` disambiguated by position. Result: `..`-family = ranges, `...` = ellipsis. One axis per glyph.

### Theme F — Type-set-ops glyphs (`|` / `&`) overload bitwise + borrow
`|`: bitor + union + pattern-or + task_group delimiter. `&`: bitand + borrow + intersection.
**Unified scheme:** decide once whether set-theoretic type composition lives on `|`/`&` (with a published positional-disambiguation table) or on keywords. Must decide before union/intersection codegen lands — cheap now, expensive later.

### Theme G — Boolean ops have word + symbol spellings
`and`/`&&`, `or`/`||`, `not`/`!`.
**Unified scheme:** keep word-forms only; remove `&&`/`||` lexings (frees `&`/`|` purely for bitwise); keep `!` as force-unwrap only (frees negation entirely to `not`). The word-vs-symbol logical/bitwise *category* split is good and intentional — publish it as a permanent stance.

### Theme H — Brackets are coherent-by-accident
**Unified scheme:** state the invariant — "a bracket pair names a container category; interior shape selects the subtype; `<>` is the documented type-level pseudo-bracket exception" — and make the formatter (SURF.4) always render the struct type-prefix and never on maps, so the SURF.1 struct/map cue is mechanically enforced, not eyeballed.

---

## 4. Proposed Unified Surface (target end-state)

What each symbol/family SHOULD mean so nothing is split-brained. This is the destination; §6 sequences the decisions to reach it.

**Access / path**
- `/` — import-path separator (import time only). Unchanged.
- `.` — the single use-time access glyph: field, method, UFCS, paren-elided method, module-qualified function, tuple-index `.N`, leading-dot chain. (If owner picks the term/type split: `.` for value-level, `::` for type-level paths + variants, and `$` deleted.)
- `$` — **deleted from surface** (or kept *only* as macro-prefix if module access moves off it; macro-prefix is position-disambiguated and fine).
- `::` — **deleted from module access** (retire or specialize to type-level only).

**Binding / arrows**
- `=` — binding/assignment/definition-introduction ONLY: `x = 5`, `var`, destructure, default-arg, `type A = Int`, `newtype`, endless-def body `def f() = expr`, refutable pattern-bind `if Some(v) = expr` (affirmed intentional).
- `->` — lambda arrow (and, in the deep-unify end-state, arm arrow too).
- `=>` — match/select arm arrow ONLY (or deleted in the deep-unify end-state). **Removed from map comprehensions** (`{k: v for ...}`).
- `:` — ascription in declarations + binding in literals (SURF.1). **Slice reverts to `..`** if owner picks N11-clean.
- `..` / `..=` — exclusive / inclusive range. `...` — spread/rest/variadic only.

**Sigils**
- `@` — definition-adjacency: decl attributes; `@field` self-shorthand kept-and-narrated (or retired for `self.field`).
- `?` — trailing-ident char (predicate methods). `!` — postfix force-unwrap operator ONLY. Asymmetry documented as law.
- `#`/`##`/`#{` — comment / doc / interpolation; mode-resolved, documented.
- `:sym` symbol literal; loop labels documented (or moved to tick).

**Operators**
- Arithmetic/comparison/shift — unchanged (clean).
- Boolean — `and`/`or`/`not` word-forms only.
- `&`/`|` — bitwise only at value level; type-composition policy per Theme F.
- `+` — symmetric-explicit or String-only (per M4).

**Keywords**
- Error: `Result`, `with Throws`/`throw`/`panic`, `try`-prefix. (`catch`, `$try` deleted.)
- Visibility: one model, real keywords, no `public` stub.
- `throw`/`resume`/`handle` — keyword-vs-function decided before wiring.
- `case`/`default`/`when` — uniformly keyword or uniformly contextual.
- `let` — fully removed OR documented as the pattern-binding keyword. No third state.

**Type annotation** (already coherent) — `:` ascription, `<>` names-only, SURF.2 `where` for multi-bound + effect rows.

---

## 5. Dead / Legacy Cleanup List

Removable now (D7: zero users, pre-launch absolutism — delete, don't deprecate):

1. **`$try` macro** — superseded by `try`-prefix (parser.qz comment already says "replaces"). Both live today.
2. **`try`/`catch`-end statement form** + **`catch` token** — superseded by `with Throws`.
3. **`public` keyword stub** — exists only to emit "public is not a keyword" (parser.qz:503, 8371). Pure dead weight; delete regardless of visibility decision.
4. **`let` keyword's third state** — `TOK_LET` (lexer.qz:1641) is forbidden-by-docs, accepted-by-parser (3977/4076). Pick removal or reinstatement; the limbo is the only unacceptable state.
5. **STYLE.md:80 `push!`/`clear!`/`sort!` row** — contradicts v5.28 lexer (lexer.qz:1620-1622). Stale doc; delete (M1).
6. **`$` module-access glyph** — 100% redundant with `::` (parser mangle). Delete from surface under any access unification (E2).
7. **`::` for module access** — redundant alias; retire or specialize (E2/N9).
8. **`&&` / `||` lexings** (lexer.qz ~1007-1026) — redundant with `and`/`or` (M3), if word-forms win.
9. **Map-comprehension `=>`** (REF:1892-1894) — last surviving `{}` hashrocket; fold into SURF.1 (N10).
10. **False `::`/`.` documentation** in REF + SURFACE_INVENTORY — not code, but a lie that must be swept (E1).
11. **`throw`/`resume`/`handle` reserved-but-unlexed token constants** (lexer.qz:1692-1699) — resolve into real keywords or delete the constants; don't leave half-wired (E5).

---

## 6. OWNER DECISION QUEUE

Ordered by leverage and dependency. SURF.1 (literals) excluded — already decided. Each: question / options / recommendation. We walk these together.

1. **Module-access glyph count.** How many glyphs reach into a module at use-time? Options: (a) collapse to one `.` [cleanest first impression, ~100k-site formatter-driven rewrite of compiler source — every commit through `quake guard`]; (b) specialize to two — `.` value-level / `::` type-level — and delete `$` [gives a real term/type cue, same rewrite cost, harder to teach]; (c) keep three [status quo, ships a doc lie]. **Recommend (a).** This is the load-bearing call — everything in the access family hangs off it.

2. **Fix the false `::`/`.` docs — now or bundled?** Options: (a) fix immediately as a standalone directive-6 sweep; (b) bundle into the glyph-unification commit. The docs are wrong today either way. **Recommend (a)** — shipping the public rationale on top of a false reference is worse than admitting the surface is messier than documented.

3. **Error-handling end-state.** Confirm `try`-prefix as the sole propagation operator and authorize deleting try/catch-end + `$try` + the `catch` token, keeping `Result` + `with Throws`/`throw`/`panic`. Options: (a) Rust model as described; (b) keep try/catch-end too. **Recommend (a)** — ERROR_HANDLING_UNIFICATION already points here; this just pulls the trigger.

4. **`throw`/`resume`/`handle`: keyword or function?** Must decide before the operation-body-lowering milestone. Options: (a) keywords [reserves three common idents, forces ~45 `handle`-site rename + rename `def throw` in std/throws.qz:47 now]; (b) functions/operations [keeps `def throw`, hybrid keyword-install + function-operation surface]. **Recommend (a)** — decide deliberately rather than discover the `def throw` collision at wiring time.

5. **RESULT-OF arrow policy (headline taste-call).** Options: (a) lock crisp three-role split (`=` binding, `->` lambda, `=>` arm) and document the law [zero migration, three glyphs for related ideas]; (b) collapse match/select arms onto `->`, delete `=>` entirely [one arrow inputs→result everywhere, Haskell/Koka taste; flips every arm in stdlib+specs+examples, diverges from Rust `=>` muscle memory]. **Recommend (b) if optimizing for one-shot elegance, (a) if optimizing for stability + Rust familiarity.** Genuine taste-call.

6. **Visibility model.** Options: (a) per-item `priv`/`pub` promoted to real keywords, delete `private` section model [granular, Rust/Swift, composes with re-export]; (b) keep `private` section model, delete `priv`/`pub`. **Recommend (a).** Either way: **delete the `public` stub** — confirm.

7. **Type-set-ops glyph policy (`|`/`&`).** Cannot defer past union/intersection codegen. Options: (a) keep `|`/`&` for union/intersection + publish a positional-disambiguation table [zero migration, permanent overload — `&` means borrow AND intersection in type position]; (b) move union/intersection to keywords while codegen-incomplete [cleaner, real surface break, cheap now]. **Recommend (b)** while it's still cheap.

8. **Range / spread dots.** Options: (a) `..`/`..=` ranges, `...` spread-only (Rust-exact) [clean axis split, migrates every `0...5`→`0..=5`]; (b) status-quo `..`/`...` + mandate three-dots for all ellipsis [smaller, keeps `...` straddling two axes]. **Recommend (a)** for internal coherence. Tie to decision 9.

9. **Gather vs spread dot-count.** Options: (a) unify on `...` for both, position-disambiguated (JS-exact) [removes the `..rest`/`...spread` near-collision]; (b) keep distinct on purpose (dot-count telegraphs gather-vs-spread direction). **Recommend (a)** — confirmed lexer emits `..` for rest (REF:926) vs `...` for spread (REF:1872); the near-collision is real.

10. **Boolean operator spelling.** Options: (a) word-only `and`/`or`/`not` [frees `&`/`|` for bitwise, `!` for force-unwrap]; (b) symbol-only `&&`/`||`/`!` [C-family familiarity]. **Recommend (a)** — note `!` is already overloaded (negation + force-unwrap); word-only resolves it. Shipping both (status quo) is the only wrong answer.

11. **`@field` self-shorthand.** Options: (a) keep + narrate as "definition-adjacency sigil" [terse, matches paren-elision "fewer glyphs" value]; (b) retire for explicit `self.field`, making `@` attribute-only [Rust/Swift, single-concept sigil, touches every extend block]. **Recommend (a)** — your prior paren-elision stance argues for terseness.

12. **Variant qualification direction.** Construction qualified (`Option::Some`) vs match/`is` unqualified (`Some`). Options: (a) unqualified-everywhere [terse, needs type-directed disambiguation for same-named variants]; (b) qualified-everywhere [unambiguous, verbose, reintroduces `::` in expression position]. **Recommend (a).** Sub-decision: authorize type-directed resolution for same-named variants if (a).

13. **Slice glyph.** Options: (a) keep Python-familiar `s[a:b]` [familiarity, but a hidden 4th colon job + a glyph already spelled `..`]; (b) switch to `s[a..b]`/`s[a...b]` [one range notion everywhere, kills the hidden colon, costs Python muscle memory]. **Lean (b) for coherence, but this is the closest call** — public-first-impression argument cuts toward (a).

14. **`?`/`!` asymmetry.** Bless the v5.28 resolution ("`?` is the ident-suffix, `!` is the operator") and document it as law, or reverse to symmetry. **Recommend bless + document** — the lexer already committed; you only ratify.

15. **`let` fate.** Options: (a) full removal (replace `if let`→`if var`); (b) reinstate as the documented pattern-binding keyword. **Recommend (a)** — makes the existing docs true with least churn. Either fixes the limbo.

16. **`case`/`default` consistency with `when`.** Options: (a) promote `case`/`default` to real keywords [predictable; grep stdlib first — `default` is a common variable name]; (b) demote `when` [harder, `when` is load-bearing in where-clauses]. **Recommend (a)** pending the grep.

17. **`+` String-coercion.** Options: (a) symmetric + explicit via `to_str`; (b) String-only-both-sides + mandatory interpolation [more honest re explicit-erasure ethos]. **Recommend (b)** — interpolation exists; silent coercion contradicts the `as_type` ethos.

18. **Loop labels.** Options: (a) keep `:outer` symbol-colon syntax + document the three colon-symbol forms; (b) adopt Rust tick `'outer` to separate compile-time control targets from runtime symbols. **Recommend defer** until SURF.1 bareword-key crowding is observed, not assumed.

19. **1-tuple policy.** Options: (a) document `(x,)`; (b) declare 1-tuples unsupported. **Recommend (b)** — defensible and cheaper given structs/`@value` exist for the named case.

**Not owner discretion (do these regardless):**
- **N10 / decision-adjacent:** fold map-comprehension `{k => v for ...}` → `{k: v for ...}` into the SURF.1 hashrocket removal. It's a contradiction SURF.1 will otherwise ship (REF:1892-1894).
- **M1:** delete STYLE.md:80's stale `push!`/`sort!` row.
- **M10/M9/H:** write the bracket-family invariant (with `<>` exception) into the rationale.
