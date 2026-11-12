# Quartz Formatter v2 + Inference Upgrade + Migration Engine (SURF.4) — Design & Implementation Plan

**Status:** DESIGN LOCKED 2026-06-18. Implementation in progress (epic branch `epic/formatter-2026-06-18`).
**Owner ratification:** Decisions D1–D10 below are owner-approved. Inference scope = **Option A** (owner-chosen). Multi-week epic; world-class bar, no shortcuts.
**Supersedes:** the 147-line text-indenter `tools/fmt.qz` and the stubbed `quartz --format`.

---

## 0. Why this exists

The SURF surface-overhaul is half-done. The additive work (flow-narrowing SURF.FLOW, where-clauses SURF.2, doc truth-fixes) landed and is green at 861/861. The remaining SURF work — the surface-breaking migrations (`$`→`::`, `=>`→`->`, dots, `let`-purge, visibility, keyword promotions) — was **parked** because it needs a tool that does not exist: a world-class formatter. The formatter is the keystone:

1. **Canonical pretty-printer** — one true style, enforced in CI (`fmt --check`).
2. **Vehicle for the surface migrations** — each PARK change is a mechanical/type-aware source rewrite applied tree-wide and re-formatted.
3. **Type-ergonomics endgame** — `fmt --annotate`/`--elide` fill/strip inferable type annotations (the formatting analog of flow-narrowing's "zero ceremony where it's safe").

Today there is no real formatter: `tools/fmt.qz` is a text-indenter, `quartz --format` is a stub (`self-hosted/quartz.qz:2142`), and `quake format` once overwrote 1417 files with a help banner (the never-write-broken contract, D6, exists to kill that class).

**Outcome:** `quartz fmt` (canonical, idempotent, comment-faithful, semantics-safe), `quartz fix`/`migrate` (type-aware codemod engine executing the PARK migrations), `fmt --annotate`/`--elide` (type-aware modes on an upgraded inference engine), and `fmt --check` as a CI fixpoint gate alongside `quake guard`.

---

## 1. Prior art (sources; established vs promising)

**Established (adopt):**
- **Strict Lindig `Doc` pretty-printer** (Lindig 2000 "Strictly Pretty" — Prettier's actual engine: `group`/`indent`/`line`/`softline`/`hardline`/`fill`/`ifBreak`/`breakParent` + `fits` probe + up-front break-propagation). A literal Wadler 1998 transliteration is **exponential in a strict language** — we must use the strict reformulation. Oppen 1980 `fill` for comma/prose lists.
- **Lossless syntax tree with first-class trivia** (Roslyn red-green; rust-analyzer `rowan`; Black `blib2to3`; SwiftSyntax). Roslyn rule: *a token owns trailing trivia to end-of-line; trivia after that line belongs to the next token.* vjeux (Prettier): CST "solved elegantly" the comment problem that AST formatting made "the bane of my existence."
- **Semantic safety net before write** (ocamlformat: AST-equality + zero-dropped-comments + idempotence loop → `Unstable`; Black: `assert_stable` + `assert_equivalent`/`ASTSafetyError`). The formatter's `quake guard`.
- **Codemod = suggestion/application separation** (Rust: rustc → `(span, replacement, Applicability)` → `rustfix` dumb byte-splicer → Cargo applies non-overlapping subset/pass, **fixpoint capped at 4**, reverts on failed recompile, refuses dirty tree. Go 1.26 `go fix` on `go/analysis` `SuggestedFix`/`TextEdit`, type-aware, behavior-preservation explicit — excluded `appendclipped` for nil-vs-empty risk).
- **Zero-config one-true-style** (gofmt/Black/zig/Roc/Gleam) — unanimous new-language trend.
- **Reprint-only-what-changed** (recast `.original`, LibCST, OpenRewrite LST) — needs a lossless tree; keeps migration diffs reviewable.

**Promising / adopt-with-care:**
- **Trailing-comma-as-author-signal** (zig: distinct node tags `call`/`call_comma`, bidirectional, width-independent; Black "magic trailing comma"). Layout control with zero config surface → adopt as distinct CST node shapes (D4).
- **rustfmt style editions** (RFC 3338, Rust 1.85): version the style guide, not the code. Future hook, not now.
- **Level-based generalization** (Rémy 1992) — the live checker already implements it (`tv_levels`), enabling sound `--elide`.

**Rejected (with reason):**
- *Dart cost-model solver* — overkill; only pays off at Flutter-grade nesting.
- *Reviving parked HM* (`experiments/parked/hm-inference/`) — no traits, no effects, no cross-module; *less* capable than the live checker. We **extend the live checker** (D9), using parked HM only as a donor reference for param/return inference.
- *Formatting from the AST* — AST is **lossy by construction** (desugars for-in/interpolation/compound-assign; conflates `if let x=e` with `if Some(v)=e`). Cannot round-trip. CST required (D1).

---

## 2. Locked decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Lossless green CST** is the formatter+codemod source of truth. AST stays the semantic tree; CST→AST lowering keeps the pipeline byte-identical. | AST is lossy; CST preserves every surface form + all trivia. |
| D2 | **Red-green incremental (red tree, lazy parent pointers, incremental reparse) DEFERRED to LSP.** | Only unique payoff is editor incrementality; no LSP exists (hard dependency). Green tree is the foundation it layers onto. |
| D3 | **Strict Lindig `Doc` engine**, width target **100** (`STYLE.md`). | World-class line-breaking; matches codified style. |
| D4 | **Trailing-comma-as-author-signal**, encoded as distinct CST node shapes. | Layout control, zero config, idempotence-stable when bidirectional. |
| D5 | **Semantic safety net before any write**: re-parse output → AST-equivalence + zero dropped comments + idempotence convergence (reformat until stable, else error). | Prevents the disaster class; the formatter's `quake guard`. |
| D6 | **Never-write-broken contract**: write only if exit 0 **and** output re-parses to an equivalent tree; atomic write; never write stderr/help. | Roots out the 1417-file footgun. |
| D7 | **Migration engine = separate `quartz fix`/`migrate` verb**; suggestion/application separation; `Applicability` tiers; non-overlapping subset/pass; fixpoint iteration; git-clean precondition; re-format after. `fmt` stays pure. | Conflating format+migrate is how a formatter starts changing meaning. |
| D8 | **Inference scope = Option A**: compiler infers param/return everywhere (incl. public bodies, inferred sigs exported to `.qzmod`); **canon requires public/exported signatures written**, enforced by `fmt --check`. Infer returns freely; keep **public param + return types** in canon. `--elide` strips inferable except public sigs (load-bearing by policy). | Terse internals + stable explicit APIs + separate-compilation-safe; the type-level expression of "zero ceremony where safe." |
| D9 | **Extend the live typechecker**, do not revive parked HM. | Live checker already has unification, occurs-check, level-based generalization, type+effect-row variables, trait resolution, cross-module sigs. |
| D10 | **Zero style config.** Operational flags only (`--check`, `--write`, `--annotate`, `--elide`, stdin, range). Style-edition versioning is a future hook. | New-language consensus; ends bikeshedding. |

---

## 3. Architecture

```
source bytes
  → lexer (full-fidelity: byte offsets + all trivia: comments, blank-line runs, doc-comments)
  → CST parser (lossless green tree; surface forms + trailing-comma node shapes preserved)
      → CST→AST lowering  → [existing pipeline: resolve → typecheck → MIR → codegen]  (UNCHANGED)
      → formatter:  CST → Doc IR (canonical style) → Lindig engine → bytes
                    → safety net (re-parse + AST-equiv + zero-dropped-comments + idempotence loop)
      → migration engine:  analyzers over CST(+types) → (span, replacement, Applicability)
                    → byte-splicer (non-overlapping subset/pass, fixpoint) → re-format
  → typecheck side-table (type-of-node) + bidirectional param/return inference
      → fmt --annotate / --elide (consume type-of-node table)
```

### 3.1 Data model
- **`CstStorage`** — flat handle/index arena mirroring `AstStorage` (`self-hosted/frontend/ast.qz:206`), the proven zero-friction pattern (sparse parallel vecs already used for effect/hygiene metadata). Green nodes immutable, position-independent, structurally shareable — red-green-ready.
- **Trivia model** — leading/trailing trivia attached by Roslyn's EOL rule; comments + blank-line *runs* (collapsed to ≤1 on output) first-class. Distinct node shapes for trailing-comma-present collections/calls/params.
- **Byte offsets** — NEW (absent today; only line/col exist). Per-token start/end byte offset. Required for verbatim span-slicing + the losslessness gate.
- **Type-of-node side-table** — NEW. Populated during typecheck (every expr/binding node → resolved type), exposed post-typecheck for `--annotate`/`--elide`.

### 3.2 Key abstractions
- `Doc` IR + `fits`/`best` engine (pure, unit-testable).
- `cst_to_doc(node, ctx) -> Doc` — canonical style rules, one per construct.
- `Analyzer` — `cst(+types) -> Vec<Edit{span, replacement, applicability}>`.
- `apply_edits(source, edits) -> source'` — dumb byte-splicer; non-overlapping subset; idempotent.
- `format_check(source) -> {ok | diff}`, `format_write(path)` honoring D5/D6.

### 3.3 Error handling
- **Parseable-input-only, never partial output** (gofmt/Prettier/zig): parse error → diagnostic + no output; non-zero exit.
- **Atomic writes** with rollback; write gated on D6.
- **Range/IDE formatting** (later): snap outward to whole statements, reprint only those; excluded from idempotence checks.
- **Migration safety**: refuse on dirty git tree; per-pass recompile + revert on failure; auto-apply only `MachineApplicable`.

### 3.4 Canonical style rules (resolving what `STYLE.md` leaves open)
Codified already: 2-space, width 100, space-around-ops, one blank between top-level defs, leading-dot chains.
- **Call args / collection literals:** all-or-nothing — fit on one line, else one-per-line; **magic trailing comma** forces broken (D4).
- **Match arms:** inline if the arm fits width, else block form.
- **`where`-clause hoist:** hoist bounds/effect-row out of the signature spine when the signature exceeds width (ties the SURF.2 "threshold" to the width budget, not a magic count).
- **Generics/where, lambdas (`{ }` one-liner vs `do…end`), endless-`def`:** follow STYLE.md; canon picks the consistent form where the corpus is inconsistent.

---

## 4. Test plan
- **Doc engine:** unit tests per combinator + `fits` boundaries.
- **Losslessness gate (M1):** `cst_to_source(parse(x)) == x` byte-for-byte over the corpus.
- **Idempotence:** convergence loop + golden `input`/`golden` fixtures invariant under re-run.
- **Safety net:** formatted output re-parses to an AST equivalent to the input's; zero comments dropped.
- **Self-hosting no-op:** after canonicalization, `fmt` over the compiler's own source is a no-op (`fmt --check` gate).
- **Migrations:** before/after fixtures per SURF item; full qspec green after each; behavior-preservation; reverse-round-trip where applicable.
- **Inference:** principality property — eliding any inferable annotation and re-inferring yields the identical resolved type (cross-module + trait + effect cases).
- **annotate/elide fixpoint:** `annotate ∘ elide == identity` both directions over the corpus; CI gate.
- **Every compiler-source phase:** LIVE rail — fix-specific golden → `quake guard` (fixpoint gen1==gen2) → cache-clean smoke (style_demo + brainfuck exit 0) → targeted foreground specs → full qspec (conductor-driven, serial-retry contention).

---

## 5. Tensions (no silent compromises)
1. **Lossless CST vs enriched-AST.** Enriched-AST is ~40% less code (gofmt/rustfmt do it) but the AST is lossy by construction — can't round-trip surface syntax. World-class requires the CST. **Cost accepted:** refactor the ~7K-line parser to emit a CST + CST→AST lowering, gated by "existing AST byte-identical after lowering + full qspec green."
2. **Red-green now vs later.** Build only the **green** tree now; defer red/incremental to LSP (D2) — *justified: no LSP exists*. Green tree designed so red layers on without rework. No compromise on losslessness, only on incrementality (no current consumer).
3. **Option A's two enforcement layers** (compiler permits unannotated public; canon forbids it). Accepted: Quartz already governs by formatter+CI gate, its strongest infra. Alternative (compiler-enforced, Option B) is simpler but ceremony-forward/off-brand.
4. **`--elide` soundness is research-grade** (principality across modules + traits + effect-rows). Riskiest unknown; M5.3 builds a property harness; if a class can't be proven sound it is **not elided** (fail-safe), never shipped unsound.

---

## 6. Phased implementation (ordered, atomic, with deps + complexity)
Complexity in quartz-time (traditional ÷4). ✦ = touches compiler source → LIVE rail + `quake guard`.

### M0 — Design doc (0.5d)
- **0.1** Commit this doc + ROADMAP SURF.4 entry. *(docs-only)*

### M1 — Lossless CST foundation ✦ (4–6d) — deps: M0
- **1.1** Lexer: per-token **byte offsets**; full-fidelity mode emitting all trivia (comments always, blank-line runs, doc-comments). *(`self-hosted/frontend/lexer.qz`)*
- **1.2** `CstStorage` + green node kinds + trivia attachment (Roslyn EOL rule) + trailing-comma node shapes. *(new `self-hosted/frontend/cst.qz`)*
- **1.3** CST parser (refactor `parser.qz` to emit CST) + **CST→AST lowering**. **Gate:** losslessness over corpus + existing AST byte-identical after lowering + full qspec green. *(highest-risk structural step)*

### M2 — Doc engine + canonical printer ✦ (5–7d) — deps: M1
- **2.1** `Doc` IR + strict Lindig engine (`fits`, `propagateBreaks`, Oppen `fill`). Pure, unit-tested. *(new `self-hosted/format/doc.qz`)*
- **2.2** `cst_to_doc` for the full grammar + canonical style rules (§3.4, comment attachment, magic trailing comma). *(new `self-hosted/format/printer.qz`)*
- **2.3** Safety net + idempotence (D5). *(new `self-hosted/format/safety.qz`)*

### M3 — CLI + tree canonicalization ✦ (2–3d) — deps: M2
- **3.1** `quartz fmt` / `--check` / stdin / range; unblock the stubbed `--format` dispatch (`quartz.qz:2142`); **fix the quake footgun** (`Quakefile.qz:220–293`) per D6.
- **3.2** Canonicalize the whole tree (run `fmt`, review, commit), then make `fmt --check` a CI/guard gate. *(supervised; large diff)*

### M4 — Migration engine (codemod) ✦ — deps: M1, M2.3, M3.1
- **4.1** Engine core (D7): `Analyzer` → `(span, replacement, Applicability)`; byte-splicer; non-overlapping subset/pass + fixpoint; git-clean precondition; re-format after; `quartz fix`/`migrate` CLI. (3d)
- **4.2** Auto-safe lexical migrations (`MachineApplicable`), each its own supervised commit: **SURF.7** (`$`→`::`), **SURF.8** (`=>`→`->`), **SURF.11** (dots/slices), **SURF.13** (booleans). (3d)
- **4.3** Review-gated migrations (`MaybeIncorrect`, human sign-off): **SURF.16** (case/default — grep-gated), **SURF.9c** (throw/handle/resume keyword pre-rename), **SURF.15** (`let` purge — reconcile `if let`/`while let` "third state" at `parser.qz:3977`), **SURF.10** (visibility per-item `priv`/`pub`). (5d)

### M5 — Inference upgrade (extend live checker) ✦ — independent of M1–M4; parallelizable. LONG POLE.
- **5.1** Type-of-node side-table populated during typecheck, exposed post-pass. (1d)
- **5.2** Bidirectional **param/return inference** (donor: parked HM); infer public bodies + **export inferred sigs to `.qzmod`**; integrate with traits + effect-rows + level-based generalization. (1.5–2wk)
- **5.3** Principality/soundness harness for elision (§4); fail-safe = don't elide unprovable classes. (3d)

### M6 — Type-aware formatter modes ✦ — deps: M2, M3, M5
- **6.1** `fmt --annotate[=public|all]`; canon enforces public sigs present. (2d)
- **6.2** `fmt --elide` (keep load-bearing + public sigs by policy). (2d)
- **6.3** `annotate ∘ elide == byte-identical` fixpoint harness in CI. (1d)

### Backlog (within-epic, NOT auto-migrations — separate breaking-change designs)
- **SURF.9a/b** (error-model: `$try`/try-catch → `with Throws`) — control-flow transform, own design.
- **SURF.14** (`+` string-coercion removal) — type-aware, breaking; diagnostic-driven, not a rewrite.
- **SURF.12** (type-set-ops keywords) — coupled to R2.1; deferred (hard dependency).

### Dependency DAG
```
M0 → M1 → M2 → M3 → {M4, M6}
M5 (parallel from start) ─────────→ M6
M3.2 (canonicalize) before M4.2/4.3 mass migrations
```

### Gaps / unknowns
- **Byte offsets** absent → M1.1.
- **Tool-import dispatch** stubbed (`quartz.qz:2142` "requires bootstrap compiler fixes for tool imports") → M3.1 must verify/unblock; *depth unknown — investigate first thing in M3.*
- **type-of-node table** + **param/return inference** absent → M5.1/5.2.
- **Principality across modules+traits+effects** → research-grade; M5.3 with fail-safe.
- **`if let`/`while let` "third state"** (`parser.qz:3977`) → reconcile in SURF.15 (M4.3).
- **Magic-trailing-comma idempotence** must be bidirectional/stable → M2 constraint + test.

---

## 7. Execution discipline
Conductor-style across sessions (the SURF.FLOW model): one milestone-step = one subagent = one commit on `epic/formatter-2026-06-18`; conductor drives the full qspec suite after each compiler commit; checkpoint a ledger every iteration (`docs/conductor/formatter-epic-2026-06-18.md`); never push/PR without sign-off. This doc is the durable spec — keep it current as decisions evolve.
