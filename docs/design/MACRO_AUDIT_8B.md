# Macro System Audit — Tier 2 #8b

**Date:** 2026-04-19
**Status:** Research / decision memo. Not a roadmap for implementation in this audit; implementation sprint is Tier 2 #8b-follow-up.

## Question

Roadmap filing Tier 2 #8b: the infrastructure exists (builtin macros, user-defined macros with quote/unquote, variadics, derive). Is it production-grade? Output: gap list + prioritized fixes, or "already world-class, just needs docs" closure. Verdict drives whether Tier 4 #25 stays as an open feature sprint.

## Answer

**Not "already world-class." Infrastructure is feature-complete but below table stakes on hygiene.** User-defined macros can silently capture caller variables because there is no alpha-renaming, no scope-set tracking, and no symbol-based resolution — only direct substitution of quote bodies. This is the same shortcut Clojure took in 1998 and has spent 28 years apologizing for.

The shape of the fix is well-understood (Racket's set-of-scopes or Scala 3's typed-Expr), zero-user world makes it a safe window to retrofit, and the window closes as soon as users start writing macros that depend on capture-by-convention.

### Recommended classification

- **Tier 2 #8b** (this audit) → **CLOSED** by this memo.
- **Tier 2 #8b-followup: Macro hygiene retrofit + documentation + expansion-trace errors** → new Tier 2 entry. Roughly a 2-week sprint.
- **Tier 4 #25 (user-defined macros, Large)** → **DOWNGRADE to "document + polish"** once the hygiene retrofit above ships. The feature exists; what's missing is correctness and docs, not the feature itself.

---

## Gap list (ordered by severity)

### P0 — Ships wrong without this

| # | Gap | Evidence | Status in prior art |
|---|-----|----------|---------------------|
| **H1** | User-defined macros are **not hygienic**. A macro body that binds `var tmp = 0` and a caller scope that binds `var tmp = 5` collide silently. `gensym()` is used by builtins (`$unwrap`, `$debug`) only — not by user macro expansion. | `macro_expand.qz:109-112` (gensym is a helper; search shows it's called only from builtin expansion sites). No alpha-renaming pass in the expander. | Racket (full, scope-sets), Scala 3 (full, via typed Expr), Elixir (full, via (name, context) pairs), Rust (mixed-site by default), Clojure (partial via `#` auto-gensym — and widely regretted). Quartz currently sits below Clojure. |
| **D1** | **No user-facing macro documentation.** `docs/MACROS.md` does not exist. `docs/QUARTZ_REFERENCE.md` mentions `$try`/`$unwrap` only. `docs/design/MACRO_DESIGN.md` still says "User-defined macros are missing" — the design doc contradicts the implementation. Users must read QSpec files to learn the feature. | `ls docs/ \| grep -i macro` returns nothing user-facing; `MACRO_DESIGN.md:14`. | Rustdoc treats `macro_rules!` first-class (`# Examples`, doctests, canonical example `println!`). Elixir `@doc` plus ExDoc macro badge. Scaladoc inline-def macros with inlined-shape convention. Racket Scribble has a dedicated `defform`. |

### P1 — Demonstrably poor UX

| # | Gap | Evidence | Prior art |
|---|-----|----------|-----------|
| **E1** | **Expansion-failure errors are orphaned.** When a macro expansion produces code that later fails type-check, the diagnostic cites the synthetic expansion location, not the macro definition or the call site. No "note: in macro X expanded at" chain. | No expansion-context propagation in macro_expand.qz beyond call-site line/col. No test in spec/qspec/ that verifies an expansion-failure error carries the macro-def breadcrumb. | Rust's `note: in this expansion of macro X!` is the floor. Scala 3 `report.error(msg, pos)`. Elixir injects `__CALLER__` into every macro by default. |
| **T1** | **Hygiene tests are passive.** Existing tests verify identifiers are preserved across quote/unquote. None test the *negative*: that a macro-introduced `tmp` does not capture a caller's `tmp`, or that one does (documenting the current behavior). No failure scenarios written down. | `mp_hygiene_preserve_src` and `mp_hygiene_per_expansion_src` in `macro_parsing_spec.qz` — both happy-path. | Racket: hygiene is invariant by construction. Elixir has explicit `quote(context: ...)` tests. Rust has `#[macro_export]` cross-crate tests. Quartz has the shape of tests but no adversarial cases. |

### P2 — Differentiators (nice-to-have, defer)

| # | Gap | Evidence | Prior art |
|---|-----|----------|-----------|
| **P1** | **No pattern matching on argument AST shape.** Fragment specifiers (`ident`, `expr`, `block`, `tt`, `type`) validate shape at call site, but a macro body cannot destructure its arguments: cannot extract the callee from a call-expr argument, cannot match "if the third arg is a block, …", etc. Ellipsis for variadics exists — that's the only compositional pattern. | `macro_expand.qz:596-609` fragment check is binary accept/reject. No `case` or `match_ast` over node kind in expander body. | Racket `syntax-parse` is gold standard (syntax classes, ellipsis, head/tail, `#:with` side-conditions). Rust fragment specifiers are the floor (what Quartz has). Elixir's uniform 3-tuple AST + `match` is the simplest viable form. |
| **P2** | **Pattern-derived error messages** (Racket's killer feature). On mismatch, `#:description "let-binding"` auto-generates "expected let-binding at this position." Quartz can't currently do this because it has no pattern language beyond fragment tags. Requires P1 first. | N/A — depends on P1. | Racket `syntax-parse` only. Nobody else has copied it as of 2026; implementing it would be a differentiator. |
| **P3** | **`$try` is no longer a macro.** It's now the `try` prefix keyword (Piezo epic Milestone A, `86e0f906`). The audit turned this up as a dangling comment in `macro_expand.qz:530-533` — the macro dispatch still references it. Dead code, harmless, but should be removed. | `macro_expand.qz:530-533` + QZ0503 points callers at the new keyword form. | N/A — cleanup. |

---

## Detailed findings

### Hygiene (H1) — deep dive

The expander has two expansion paths:

1. **Builtin macros** (`$unwrap`, `$assert`, `$debug`): use `gensym()` to produce fresh identifier names like `__macro_N_subj`. Correct by construction; tests in `builtin_macros_spec.qz` and `debug_macro_spec.qz` verify single-evaluation semantics.

2. **User-defined macros** (both quote/unquote and string-template): substitute parameters into the body via `unquote_substitute` (quote variant, `macro_expand.qz:668-956`) or `substitute_params` (string variant, `:1152-1190`). Neither pass renames locals introduced *by the macro body*. A `var tmp = 0` in the body expands to literal `var tmp = 0` at every call site; if the caller already has `tmp`, the macro's `tmp` shadows it for the rest of the expansion, and the caller's `tmp` is invisible to unquoted references that appear later in the body (or vice versa, depending on whether the expansion nests inside the caller's scope).

**Empirical consequence**: the macro `with_lock(f)` that expands to `lock.enter(); f; lock.exit()` will use whatever `lock` is in the caller's scope. Which is what the author probably wanted, but for the *wrong* reason — not because hygiene is opt-out there, but because the language has no hygiene at all. A renaming pass would need an explicit "unhygienic reference" escape hatch to preserve that use case (Elixir's `Macro.var(:foo, nil)`; Scheme's `datum->syntax`).

**Retrofit shape.** Two options:

- **Scope-sets (Racket, POPL 2016).** Every identifier carries a set of scopes stamped during parsing and expansion. Binding resolution picks the binder whose scope set is the largest subset of the use-site's scope set. Full hygiene falls out; opt-out is explicit scope manipulation. Implementation is well-documented and has been replicated in Pyret, Rhombus, Chez Scheme, and others. Medium-size: expander needs a scope-tracking wrapper around AST nodes; resolver needs to consult scope sets during name lookup.
- **Typed-Expr (Scala 3).** Quotes carry types; identifier references are by symbol, not by name. Gets hygiene for free, adds compile-time checking of generated code before expansion. Large: requires typechecking the quoted body at macro-definition time. Higher payoff if combined with P1 (pattern matching on AST).

**Recommendation.** Scope-sets. It's the minimum additional machinery that gets Quartz to table stakes. Typed-Expr is a Tier 4+ conversation — worth keeping on the list but not the next move.

### Documentation (D1) — deep dive

Three documents reference macros:
- `docs/QUARTZ_REFERENCE.md`: mentions `$try`, `$unwrap` as builtins. Nothing about the `macro` keyword, fragment specifiers, variadics, `@derive`, or hygiene.
- `docs/design/MACRO_DESIGN.md`: a design document from when user macros were aspirational. Line 14: "What's Missing: User-defined macros. Only the 4 built-in macros exist." This is **false** as of today — user macros have been implemented and shipped. The doc is both aspirational and stale.
- No `docs/MACROS.md`.

**What to write.** `docs/MACROS.md`, audience = user who has written Quartz for a week and wants to write a first macro. Structure modelled on Rust's `macro_rules!` reference: grammar, fragment specifiers, variadics, quote/unquote, string templates, a hygiene warning (pre-retrofit) or a hygiene explainer (post-retrofit), built-in macros reference, `@derive`, known limitations. Length target: 500–800 lines. Time cost: ~1 quartz-day.

Also: delete `MACRO_DESIGN.md` or rewrite its opening to match reality. Deleting is cleaner — Directive 7.

### Error quality (E1) — deep dive

All error sites in `macro_expand.qz` cite the *call site* (the `macro_call` AST node's line/col). None cite the *macro definition site*, and no error carries a chained expansion trace. When a macro expansion produces code that fails downstream (in typecheck or later MIR lowering), the error is raised against the synthetic expansion location — the user sees an error about code they didn't write, with no breadcrumb back to the macro body.

Rust's `note: in this expansion of macro X!` chain is the floor here, not a differentiator. Getting it right means every generated AST node carries a "span stack": original source span + for-each-enclosing-expansion (macro name + definition span + call-site span). The error pipeline renders the chain when a node from expanded code is involved.

This is invasive (touches every AST allocation in the expander) but not large — maybe 2-3 days. It pairs naturally with the hygiene retrofit because scope-sets and span-stacks both want metadata attached to every AST node anyway.

### Test coverage (T1) — deep dive

7 spec files, 100+ tests. Coverage across happy paths is good:
- `macro_parsing_spec.qz` — macro defs, calls, quote/unquote, composition, variadic, error cases
- `user_macros_spec.qz` — basic quote/unquote, return context, multiple macros
- `macro_fragment_spec.qz` — ident, expr, tt fragments
- `builtin_macros_spec.qz` — all four builtins
- `debug_macro_spec.qz` — `$debug` thoroughly including single-eval
- `derive_spec.qz` — all 5 traits + coexistence with manual impls
- `stress_macros_spec.qz` — adversarial nested / variadic / builtins

**Gaps:**
- No hygiene negative tests (documenting capture behavior one way or the other)
- No deep-nesting stress test approaching the 64-level recursion limit (`macro_expand.qz:520`)
- No cross-module macro test (probably not supported — but no test documenting the limitation)
- No test for malformed `${}` in string templates
- No test of `$try`-is-now-a-keyword (the old builtin is still referenced; QZ0503 should have a dedicated regression spec)

---

## Implementation plan (Tier 2 #8b-followup)

Proposed as one cohesive sprint because H1 + E1 both need AST-node metadata attached; doing them together is cheaper than doing them apart.

**Phase 1 — Instrumentation (~1 day).** Extend AST node metadata to carry `{source_span, expansion_span?}` (a nullable stack of (macro_name, def_span, call_span) triples for nodes born inside an expansion). No behavior change; just plumbing.

**Phase 2 — Expansion trace errors (~2 days).** Teach the diagnostic pipeline to render the expansion span stack. When an error cites a node with a non-empty expansion stack, emit `note: in expansion of macro X (defined at Y:L:C)` per level. Add QSpec tests that verify the breadcrumb is present on a typecheck-after-expansion failure.

**Phase 3 — Scope-set hygiene (~1 week).** Implement scope sets for user-defined macros. Reference: [Flatt, POPL 2016, "Binding as Sets of Scopes"](https://users.cs.utah.edu/plt/scope-sets/). Build:
- Scope-set type in the AST
- Stamp call-site + definition scopes during expansion
- Scope-set-aware identifier resolution in the resolver
- `datum->syntax`-equivalent escape hatch (explicit unhygienic reference)
- Negative test suite: caller-scope `tmp` does not collide with macro-body `tmp` unless escape hatch used

**Phase 4 — Documentation (~1 day).** Write `docs/MACROS.md`. Delete `docs/design/MACRO_DESIGN.md` (its content is now wrong; its design is now the code; its successor is `MACROS.md`). Add a "Macros" section to `docs/QUARTZ_REFERENCE.md` cross-linking.

**Phase 5 — Cleanup (~0.5 day).** Delete the $try macro dispatch block in `macro_expand.qz:530-533`. Ensure QZ0503 message is accurate (it should redirect to the `try` keyword). Add QZ0503 regression spec.

**Total**: ~2 quartz-weeks. Milestones are independent enough to ship one at a time; Phase 1 unblocks 2 and 3 so do it first.

## What to do with Tier 4 #25

Downgrade once 8b-followup lands. The current Tier 4 #25 entry is sized "Large" and reads like "design + implement user-defined macros from scratch, study Rust/Elixir/Zig first." That description is obsolete — the feature exists. The residual work is hygiene (covered by 8b-followup Phase 3), docs (Phase 4), and error quality (Phase 2). After those ship, Tier 4 #25 should be closed with a note pointing at 8b-followup.

Pattern matching on AST (P1 above, syntax-parse-style) could re-open as a fresh Tier 4 item — it's a genuine feature, not a polish item — but it is not load-bearing for a 1.0 release.

## References

- **Audit inputs**: deep read of `self-hosted/frontend/macro_expand.qz`, `self-hosted/frontend/derive.qz`, parser macro productions, and 7 QSpec files; see section "Detailed findings" for file:line citations.
- **Prior-art survey**: 6 languages (Racket, Rust, Elixir, Scala 3, Zig, Clojure) compared across hygiene / pattern matching / errors / docs / lessons. Raw survey retained in session transcript; key citations:
  - [Binding as Sets of Scopes (Flatt, POPL 2016)](https://users.cs.utah.edu/plt/scope-sets/)
  - [Racket syntax-parse](https://docs.racket-lang.org/syntax/stxparse.html)
  - [Rust proc_macro::Span](https://doc.rust-lang.org/proc_macro/struct.Span.html)
  - [Elixir Macro module](https://hexdocs.pm/elixir/Macro.html)
  - [Scala 3 Macros reference](https://docs.scala-lang.org/scala3/reference/metaprogramming/macros.html)
  - [jank blog: Clojure error reporting (2025)](https://jank-lang.org/blog/2025-03-28-error-reporting/) — the cautionary tale

## Verdict

**Tier 2 #8b: CLOSED.** The macro system is not world-class, nor is it a disaster — it's "complete except for hygiene and docs," which in the 2026 macro-system landscape is close enough to ship *if* hygiene is added before users start writing macros in earnest. That window is open now (zero users) and closes as soon as anyone relies on the current capture-by-accident semantics.

The followup sprint is the right next move. Ship hygiene + errors + docs as one piece, mark Tier 4 #25 as "covered by 8b-followup," and the macro system stops being a liability.
