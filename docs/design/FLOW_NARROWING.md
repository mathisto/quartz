# Flow-Narrowing (Smart-Casts) — Design & Implementation Plan

**Status:** DESIGN, implementation NOT started.
**Owner decision of record:** `SURFACE_DECISIONS.md` §5 (D14.2) — "ADD flow-narrowing (smart-casts) — NEW, TOP PRIORITY. After `if x.some?` / `if Some(v) = x`, the compiler proves presence inside the branch → no explicit unwrap. Additive; zero safety loss."
**Independence:** Flow-narrowing builds on **current** syntax (`if`, `is`, `.some?`, refutable `=`-bind). It does NOT depend on any other SURF migration (`$`→`::`, `=>`→`->`, `expr!`, `try`-prefix, etc.). It can land first, before the mechanical surface rewrites. Confirmed independent — see §6.4.

---

## 0. The goal, restated

Make `Option`/`Result`/enum safety stop costing ceremony. After a control-flow guard *proves* a value is present (or is a specific variant), the value is usable as the inner `T` **inside the proven region**, with no explicit `.unwrap()` / `!` / re-bind.

```quartz
# Positive guard — narrowed in then-branch
if opt.some?              # or: if opt is Some
  use(opt)               # opt usable as inner T here
end

# Refutable bind — already works today (v is inner T)
if Some(v) = opt
  use(v)
end

# Negative guard + early exit — narrowed AFTER the guard (guard-style)
if opt.none?
  return
end
use(opt)                 # opt narrowed to present from here to end of scope
```

`nil`-for-absence stays banned (QZ0213). This is the Ruby-like "just use it" with ML-grade safety.

---

## 1. Current state (findings, file:line)

### 1.1 Option/Result are ordinary generic enums; niche-represented at runtime
- Declared in the auto-imported prelude: `std/prelude.qz:41-44` (`enum Option<T> { Some(value: T); None }`), `std/prelude.qz:92-95` (`enum Result<T, E> { Ok(value: T); Err(error: E) }`).
- Nominal type ids: `self-hosted/shared/type_constants.qz:49-52` (`TYPE_OPTION = 10`, `TYPE_RESULT = 11`).
- Built-in variant indices hardcoded: `self-hosted/backend/mir.qz:7679-7696` (`Option::Some = 0`, `None = 1`, `Result::Ok = 0`, `Err = 1`).
- **Niche (tag-free) representation:** single-payload `Option<&T>`/`Option<boxed>`/`Option<NonZero>` store the payload inline with a spare bit pattern for `None` (`self-hosted/backend/niche.qz:77-88`, `mir.qz:9019-9032` `mir_option_none_const`). Multi-payload niche (M1 user enums, M2 built-in `Result`) packs `ptr | tag_idx` with a 3-bit spare mask (`mir.qz:8673-8811`). Spilled (non-niche) layout: tag at offset 0, payload at offset 1.
- **Crucial consequence for narrowing:** a narrowed read must produce the *payload*, and the payload-extraction path is layout-dependent (identity for single-niche, mask for multi-niche, load-offset-1 for spill). The existing match-arm machinery already handles all three (§1.4) — narrowing must reuse it, not reinvent it.

### 1.2 Typechecking is purely bottom-up; NO flow-sensitive state today
- Statement dispatcher: `self-hosted/middle/typecheck_walk.qz:2605` (`tc_stmt`).
- If-statement handler: `typecheck_walk.qz:4240-4404`. While: `4408-4454`.
- Scope structure: `self-hosted/middle/typecheck_util.qz:89-152` (`TcScope`). Flat parallel `Vec`s: `binding_names`, `binding_types`, `binding_depths`, `binding_mutables`, `binding_struct_names`, `binding_count`, `current_scope_depth`. **No refinement/narrowing field.**
- Scope push/pop: `tc_enter_scope` (`typecheck_util.qz:1320`) bumps depth; `tc_exit_scope` (`typecheck.qz:630-707`) drops bindings at the current depth by decrementing `binding_count`.
- Identifier type lookup: `typecheck_walk.qz:1162-1250` → `tc_scope_lookup_at` (`typecheck_util.qz:1575-1640`). Returns the binding's **stored** type, never a conditional override. **This is the single hook a narrowed read must consult.**
- Explicit confirmation that conditions don't narrow today: comment at `typecheck_walk.qz:2149` ("are typechecked normally and do not narrow").
- `and` typing fully evaluates both operands, no short-circuit refinement: `typecheck_walk.qz:1283-1284`, `typecheck_helpers.qz:125-132`.

### 1.3 There IS already a per-branch snapshot/restore/merge discipline — model the narrowing env on it
The if-handler already snapshots **linear states, move states, and partial-move states** before each branch, restores them between then/else, and merges/checks-agreement after (`typecheck_walk.qz:4282-4313` for refutable-bind, `4329-4360` for `is`-with-bindings, `4366-4403` for plain `if`). Functions: `tc_snapshot_linear_states` / `tc_restore_linear_states` / `tc_snapshot_move_states` / `tc_restore_move_states` / `tc_snapshot_partial_moves` / `tc_restore_partial_moves` / `tc_merge_move_states` / `tc_check_linear_branch_agreement` (all in `typecheck_registry.qz`).
**This is the architectural template.** A narrowing environment is *another* snapshotted-and-restored side table threaded through exactly these same points. We are not inventing a new control-flow framework; we are adding one more channel to an existing one.

### 1.4 The `is` keyword and pattern-bind machinery (the closest existing thing to narrowing)
- `is` lexed: `lexer.qz:1686` (`TOK_IS`). Parsed in equality position → `NODE_IS_CHECK` (`parser.qz:3649-3692`, `ast.qz:1054-1068`, node kind 92). Stores subject (left), variant name (str1), optional `bound_names`.
- `is` in **expression** position typechecks to `TYPE_BOOL`, no narrowing (`typecheck_walk.qz:2502-2550`).
- `is` **with bindings** in if-condition (`if val is Some(x)`) DOES bind payload types into the then-scope: `typecheck_walk.qz:4315-4360` calls `tc_bind_pattern_variables`.
- `is` lowers to a tag comparison `OP_EQ(tag(subject), variant_idx)` (`mir_lower.qz:4697-4709`).
- Match-arm / refutable-bind variable binding: `tc_bind_pattern_variables` (`typecheck_match.qz:102-261`); inner-payload type computed by `tc_resolve_variant_type` (`typecheck_match.qz:33-85`) — looks up the variant's field annotation in the enum registry and substitutes generic args (`Option<String>.Some` → `String`). This is exactly the "given the variant, what is the inner type" computation narrowing needs.
- Refutable bind in if: `parser.qz:3976-3997` (and elsif `4075-4095`) — both `if let v = e` and `if Some(v) = e` parse to the same refutable-bind AST; `if let` desugars to a `Some(v)` pattern. Typecheck: `typecheck_walk.qz:4277-4313` → `tc_bind_if_pattern` (`typecheck_match.qz:357-410`). **`while let` / refutable `while` does not exist** (`parser.qz` while at `4167-4185` takes only a boolean cond).

### 1.5 Predicate methods `.some?` / `.none?` (and `.is_some()` family)
- `.some?` / `.none?` are **compiler-rewritten at field-access typecheck**: `typecheck_expr_handlers.qz:659-691` rewrites `.some?` → `option_is_some(opt)` and `.none?` → `not option_is_some(opt)`, gated on `object_type == TYPE_OPTION`. Trailing-`?` lexed as part of the lowercase identifier (`lexer.qz:1596-1623`).
- `.is_some()`/`.is_none()`/`.is_ok()`/`.is_err()` are real stdlib UFCS methods (`std/prelude.qz:343-389`, `std/option.qz:19-27`, `std/result.qz:20-28`) defined via `self is Some` etc.
- For niche Options these predicates (and `unwrap`) are intercepted in MIR and inlined to scalar compares (`mir_lower_expr_handlers.qz:1690-1751` and `1975-2029`), e.g. `is_some` → `OP_NE(opt, none_const)`.
- **Implication:** the narrowing trigger detector must recognize *all spellings* of "tests presence/variant": `is Some`, `.some?`, `.is_some()`, `.none?`, `.is_none()`, and the Result analogues. Best done by normalizing each to a `(subject, variant, polarity)` triple at the point the condition is analyzed — see §3.

### 1.6 Mutability & reassignment (soundness hook points)
- Mutability recorded at bind: `typecheck_util.qz:1425` (`binding_mutables[binding_count] = is_mutable`); read via `tc_scope_lookup_mutable` (`typecheck_util.qz:1771-1792`).
- Assignment handler: `typecheck_walk.qz:3852-3879` (`NODE_ASSIGN`). Rejects const reassignment with **QZ0106** "Cannot assign to immutable variable" (`typecheck_util.qz:1018-1020`). **This is the invalidation hook** — when a `var` is reassigned, any narrowing on it must be dropped here.
- A `var` reassignment does **not** change the binding's recorded type (binding type is set once at `typecheck_util.qz:1423`, only refined for bare `Channel`/`Vec`/`Map` first-use inference). So narrowing must be a *separate* side table, never a mutation of `binding_types`.
- Closure capture (`typecheck_capture.qz:19-337`) collects captured names as `Vec<String>` but does **not** track mutability or reassignment-through-closure. There is **no reaching-definitions / assignment-set analysis anywhere.** Soundness must therefore be enforced *conservatively and syntactically*, not via dataflow (see §4).

---

## 2. Prior art synthesis & chosen model

| Language | Model | Mutation handling | Lesson |
|---|---|---|---|
| **TypeScript** | In-place narrowing of the original binding via control-flow analysis; type guards (`typeof`, `in`, discriminant, user-defined `x is T`). | Narrowing **resets on reassignment**; `let` re-widens to declared type, `const` stays narrowed; closures re-widen captured `let`. | The reset-on-reassign rule is the soundness keystone. `const` narrows more aggressively than `let` — exactly Quartz's const-default advantage. |
| **Kotlin** | In-place smart-cast. | Only smart-casts `val` (local immutable) and stable expressions; **refuses** to smart-cast `var`, custom getters, `open` properties, or anything capturable/mutable-between-check-and-use ("smart cast impossible"). | The famous limitation IS the sound design. Refusing to narrow what you can't prove stable is correct, not a bug. Given Quartz has no reaching-defs, Kotlin's conservatism is the safe default. |
| **Swift** | Binding-based: `if let x = opt` / `guard let x = opt else { return }` introduce a *new* non-optional binding; the original is untouched. | N/A — original stays optional; new binding is immutable. | `guard let` early-exit is the ergonomic win for the negative-guard case. Quartz already has the bind form (`if Some(v) = e`); the gap is in-place + guard-style. |
| **Ceylon** | Flow typing (`if (is T x)`) — pioneered mainstream flow-typing. | Narrows immutable refs. | Validates in-place flow-typing as a first-class, sound feature when restricted to stable refs. |
| **Rust** | `if let` / `let-else` binding only; no in-place narrowing of the scrutinee. | Move/borrow checker makes the scrutinee question moot. | Confirms binding-form is sufficient for safety; in-place is purely ergonomic. |

### Chosen model for Quartz: **in-place narrowing of `const` bindings, restricted Kotlin/TypeScript style; binding-form unchanged**

1. **In-place, for `const` bindings.** After a guard proves `opt` present, `opt` itself reads as the inner `T` inside the proven region. Quartz is **const-by-default** — the overwhelmingly common case (`opt = something`) is immutable and narrows freely and soundly. This is the maximal-ergonomics, zero-extra-syntax path and it leans directly into Quartz's defining property.
2. **`var` bindings: narrow, but invalidate on any reassignment in the narrowed region** (TypeScript `let` rule), with a **v1 conservative fallback**: if the implementation risk of tracking invalidation precisely is too high for Phase 2, *refuse to narrow `var` at all in v1* (Kotlin rule) and emit a friendly "bind it (`if Some(v) = x`) or it's a `var`; narrowing only applies to immutable bindings" note. The phased plan below narrows `const` first (Phase 1) and adds `var`-with-invalidation in Phase 2, so the conservative fallback is the natural intermediate state, never a dead end.
3. **Refutable-bind form (`if Some(v) = x`) is the explicit escape hatch and stays exactly as-is.** It already works (§1.4); narrowing is purely additive sugar over the same payload-extraction machinery. When narrowing can't apply (e.g. a `var` that's reassigned, or a non-stable receiver), the bind form is always available and is what the diagnostic points to.
4. **A narrowed `opt` reads AS the inner `T` directly** (no fresh binding name). At lowering, the compiler inserts the same payload-extract the match arm would (§5). The declared type of `opt` is unchanged outside the region; only the *refinement table* says "within this region, `opt` is `Some`, inner type `T`."

Rationale vs alternatives: pure binding-form (Swift/Rust) leaves the ceremony D14 wants to kill ("just use it"); pure in-place for everything (naive) is unsound for `var`. The const-default of Quartz lets us take TypeScript's most aggressive, *sound* slice (const narrows freely) as the common case and treat `var` as the carefully-guarded minority — which is precisely the Kotlin posture, but with a larger sound region because Quartz defaults to immutable.

---

## 3. Design — the narrowing environment, triggers, lowering

### 3.1 The refinement environment
A new side table, snapshotted/restored/merged through the **same** plumbing as linear/move states (§1.3). Conceptually: `binding_name → Refinement`, where a `Refinement` records `{ enum_name, variant_idx, inner_type, inner_struct_name }` (and polarity is already resolved — a refinement only ever asserts "is this variant").

Implementation shape (matching the existing flat-`Vec` + snapshot convention rather than a real map):
- Add parallel `Vec`s to `TcScope` (or a dedicated `TcNarrow` sub-struct held on `TypecheckState`): `narrow_names: Vec<String>`, `narrow_variant_idx: Vec<Int>`, `narrow_inner_type: Vec<Int>`, `narrow_inner_struct: Vec<String>`, `narrow_depth: Vec<Int>`, `narrow_count: Vec<Int>`.
- `tc_snapshot_narrow(tc) / tc_restore_narrow(tc, snap)` mirroring the linear-state snapshot/restore exactly (it's just the count + a copy of the active slice).
- A merge at branch join is a **set intersection**: a binding stays narrowed after an if/else only if narrowed (to the same variant) on *both* paths. The negative-guard early-exit case is handled by recognizing that the then-branch *diverges* (see §3.3), so its absence-of-narrowing doesn't poison the post-guard region.

Lookup integration: `tc_scope_lookup_at` (`typecheck_util.qz:1575`) — or better, the identifier handler at `typecheck_walk.qz:1178` — consults the narrow table FIRST; if a refinement for `name` is active at the current depth, it returns the refined inner type instead of the declared `Option<T>`/`Result<T,E>`. Keep the consult in one place so every read site (call args, field access, `+`, etc.) sees the narrowed type uniformly.

### 3.2 Triggers — every guard form that narrows
Normalize each guard condition to zero or more `(subject_path, variant, polarity)` facts, then apply them per-branch:

| Surface form | Fact in then-branch | Fact in else-branch |
|---|---|---|
| `if x is Some` / `if x is Ok` / `if x is Variant` | `x : variant` | none (could be any other variant) |
| `if x.some?` / `if x.is_some()` | `x : Some` | `x : None` (binary enum → else is provable!) |
| `if x.none?` / `if x.is_none()` | `x : None` | `x : Some` |
| `if x.ok?` / `if x.is_ok()` | `x : Ok` | `x : Err` |
| `if x.err?` / `if x.is_err()` | `x : Err` | `x : Ok` |
| `if Some(v) = x` (refutable bind) | `v : T` (existing) **and** `x : Some` (new, additive) | none |
| `if cond_a and cond_b` | union of facts from `cond_a`, `cond_b` (both must hold) | none (De Morgan: `not(a and b)` proves nothing about either) |
| `not <guard>` / `if !pred` | swap polarity of the inner guard | swap |
| `match x { Some(v) -> ... }` arm | `x : Some`, `v : T` | per-arm |

**Negative-guard / guard-style** (the `if x.none? then return end; use(x)` case): when an if-statement's then-branch **definitely diverges** (ends in `return`, `throw`/`panic`, `break`/`continue`, or an exhaustive divergent match), the else-fact (`x : Some`) is injected into the *enclosing* scope's narrow table for the statements *after* the if — because control only reaches them when the guard was false. Divergence detection: a small `stmt_diverges(node)` predicate. This is exactly Swift `guard let ... else { return }` semantics, achieved without new syntax.

Binary-enum else-narrowing (Option two-variant, Result two-variant) is sound and high-value: `if x.some? ... else <here x is None>`. For 3+-variant user enums, `is Variant` narrows only the then-branch (else could be any of the remaining variants) unless the match/if-chain is exhaustive.

### 3.3 Soundness rule (the load-bearing part)
Reintroducing a null-deref class here would defeat the entire point of D14. Rules, conservative by construction (we have **no** reaching-defs to lean on):

1. **Only narrow stable subjects.** v1 stable = a bare local **identifier** binding. Do **not** narrow field paths (`a.b.opt`), index expressions, or call results — those can change between check and use with no syntactic signal. (TypeScript narrows some property paths; we defer that — it needs alias/purity reasoning we don't have.)
2. **`const` bindings narrow freely** — immutable, cannot be reassigned (enforced by QZ0106), so the proof at the guard holds at every use in the region. This is the bulk of real code.
3. **`var` bindings:**
   - **v1 (Phase 1):** do not narrow `var`. Diagnostic points to the bind form.
   - **Phase 2:** narrow `var`, but **invalidate** the refinement on ANY reassignment of that name within the narrowed region. Hook: the `NODE_ASSIGN` handler at `typecheck_walk.qz:3852` — after a successful assign to a narrowed name, drop its entry from the active narrow table. Also invalidate on compound-assign and on passing `&mut x`/`&x`-mutable borrow.
   - **Closure barrier:** if a narrowed `var` is **captured by any lambda** in the narrowed region, invalidate it (a closure could reassign it later / be called re-entrantly). `typecheck_capture.qz` already collects capture names; check the narrow table against the capture set when a lambda is typechecked. Conservative and cheap.
4. **No cross-function narrowing.** Refinements are function-local and die at function boundaries (they live on the scope stack, which is per-function).
5. **Fail safe:** if any condition for sound narrowing is unmet, simply *don't narrow* — the user gets today's behavior (must `!`/bind/`unwrap`). Narrowing never makes a previously-accepted program fail to compile (additive); it only ever *removes* required ceremony.

### 3.4 Lowering
Narrowing is a typecheck-phase concept; by MIR the access is already typed as the inner `T`. Two viable lowerings — recommend **(A)**:

- **(A) Desugar narrowed reads to the existing payload-extract (recommended).** When the typechecker records a refinement, it also marks the relevant identifier read nodes (or emits a synthetic unwrap node) so MIR lowering routes them through the **same** payload-extraction the match arm uses: `mir_set_pending_inline_for_enum` + `mir_ctx_apply_pending_bind` (`mir.qz:9557-9747`), which already handles single-niche (identity), multi-niche (mask), and spill (load-offset-1) layouts. Zero new codegen; correctness inherited from the battle-tested match path. The refinement carries enough to pick the layout (enum + variant + concrete inner type).
- **(B) Treat the narrowed identifier as an implicit refutable bind.** Synthesize, at desugar/typecheck, a hidden binding equivalent to `Some(__narrow_x) = x` at the guard and rewrite reads of `x` in the region to `__narrow_x`. Cleaner semantically but touches more of the pipeline and changes name resolution. Defer unless (A) hits a wall.

Either way: **the unwrap is inserted by the compiler at a point control-flow has proven safe**, so there is no runtime `None`-trap on a narrowed read.

---

## 4. Interactions & risks

- **Fixpoint stability (critical).** The compiler self-compiles; narrowing changes typecheck output, which must be deterministic. The narrow table must be ordered/iterated deterministically (use the same flat-`Vec` insertion-order discipline as the existing snapshot tables — no hash-map iteration-order nondeterminism). Every phase ships through `quake guard` (gen1==gen2 byte-identical) and the post-guard smoke tests (CLAUDE.md). Because narrowing only *removes* ceremony, the compiler's own source can adopt it incrementally without forcing a flag-day.
- **Niche / value-repr.** Narrowed reads must extract the payload per the subject's actual layout. Reusing `mir_ctx_apply_pending_bind` (§3.4-A) inherits niche/spill correctness for free. Watch the **QZ0212 erased-boundary guard** (`mir_lower_expr_handlers.qz:1753-1813`): narrowing produces an inner `T` value; if that value is then passed into an erased generic that reads via SPILL, the existing guard already covers it — narrowing must not bypass it.
- **De-existentialization work.** Narrowing computes the concrete inner type from the registry/generic-substitution path (`tc_resolve_variant_type`), which is the same machinery the value-types/de-erase work is hardening. No conflict; narrowing benefits from more-precise inner types.
- **Independence from other SURF changes (confirmed).** Narrowing reads/uses *current* syntax. `expr!` (force-unwrap collapse), `try`-prefix, `$`→`::`, `=>`→`->` are all orthogonal. The only soft coupling: once narrowing exists, `!`/`unwrap` become rare (the D14 thesis) — but narrowing does not require those changes to have landed.
- **Exhaustiveness interplay (Phase 4).** Match exhaustiveness checking (`typecheck_match.qz`) and if/elsif-chain narrowing should agree: an `if x.some? ... else ...` that covers both Option variants is morally exhaustive. Low priority; polish.

---

## 5. Phased plan

Each phase is independently shippable, guard-clean, and TDD'd. Smallest-useful-first.

### Phase 1 — `const` then-branch narrowing for Option presence (MVP)
**Scope:** `if x.some?` / `if x is Some` / `if x.is_some()` narrows a **`const`** `x` to inner `T` in the **then-branch only**. No `var`, no else, no guard-style, Option only.
**Files:**
- `typecheck_util.qz` — add `narrow_*` Vecs to `TcScope` (or a `TcNarrow` on `TypecheckState`); add `tc_narrow_add` / `tc_narrow_lookup` / `tc_narrow_clear_at_depth`.
- `typecheck_registry.qz` — add `tc_snapshot_narrow` / `tc_restore_narrow` (clone the linear-state snapshot pattern).
- `typecheck_walk.qz` — in the plain-`if` arm (`~4362`), detect a presence-guard on a bare const identifier, push a refinement, enter scope, walk then-branch, pop. Make the identifier handler (`~1178`) consult the narrow table before returning the declared type. Add a `condition→fact` normalizer recognizing `is Some`, `.some?`, `.is_some()`.
- `mir_lower*.qz` — ensure a narrowed read lowers through `mir_ctx_apply_pending_bind` (§3.4-A); likely a node-tag or synthetic-unwrap emitted at typecheck so MIR knows to extract.
**Tests (`spec/qspec/flow_narrow_spec.qz`):** positive — `if opt.some? use(opt as Int) end`; all three spellings; nested then-blocks; narrowing does NOT leak past `end` (read after the if still requires unwrap). Negative/soundness — narrowing a `var` is NOT applied in Phase 1 (must still unwrap); a non-presence condition does not narrow.
**Risk:** MEDIUM — first flow-sensitive state in the typechecker + the MIR read-lowering wiring. Fixpoint is the gate.
**Phase-1 entry point:** see §6.

### Phase 2 — else-narrowing, guard-style early-exit, refutable-bind integration, `var` invalidation
**Scope:** binary-enum else-narrowing (`else` ⇒ `None`); negative-guard `if x.none? return end; use(x)` via divergence detection; additive `x : Some` fact from `if Some(v) = x`; **`var` narrowing with invalidate-on-reassign + closure barrier**.
**Files:** `typecheck_walk.qz` (else-branch fact injection; `stmt_diverges` predicate; post-if scope-level fact injection; `NODE_ASSIGN` invalidation hook at `~3852`), `typecheck_match.qz` (emit subject-fact alongside refutable-bind payload binding in `tc_bind_if_pattern`), `typecheck_capture.qz` (invalidate narrowed `var` on capture).
**Tests:** else-branch narrows to `None`/`Err`; `none?`+return narrows after; `if Some(v)=x` also narrows `x`; **soundness:** reassigning a narrowed `var` between check and use must NOT stay narrowed (compile error if used as inner T after reassign); capturing a narrowed `var` in a lambda drops narrowing; reassign-in-loop case.
**Risk:** HIGH — `var` soundness + divergence detection are where a hole would reintroduce null-deref. Heavy negative-test investment required.

### Phase 3 — Result, multi-variant enums, `and`-chains, nested
**Scope:** `is Ok`/`is Err`/`.ok?`/`.err?`; arbitrary user-enum `is Variant`; `if a.some? and b.some?` narrows both; nested guards.
**Files:** generalize the normalizer + fact application in `typecheck_walk.qz` / `typecheck_match.qz` from Option-only to any enum via the registry; `and`-chain fact union in the binary handler (`~1283`).
**Tests:** Result narrowing both arms; 3-variant enum then-only narrowing; `and`-chain double-narrow; nested `if a.some? if b.some? ... `; Result niche-M2 payload extraction correctness (IR-level).
**Risk:** MEDIUM — mostly generalization; niche-M2 Result payload extraction is the sharp edge (validate by IR-diff per the cache/no-cache memory rules).

### Phase 4 — polish & exhaustiveness interplay
**Scope:** diagnostics ("`x` is narrowed here; reassigning drops it"), if/elsif-chain exhaustiveness agreement, `while x.some?` loop-condition narrowing (bounded), doc/reference updates.
**Files:** `typecheck_match.qz` (exhaustiveness), error explanations under `self-hosted/error/`, `docs/QUARTZ_REFERENCE.md`, `docs/ROADMAP.md`.
**Risk:** LOW.

---

## 6. Recommended Phase-1 entry point (smallest first change)

**Goal of the first commit:** `if opt.some?` narrows a `const opt: Option<Int>` so `use(opt)` typechecks with `opt: Int` inside the then-branch — and crucially, fixpoint holds.

1. **Add the narrow side-table + snapshot/restore** (`typecheck_util.qz` near the `TcScope` struct at `:89`, and `typecheck_registry.qz` next to `tc_snapshot_linear_states`). Mirror the existing snapshot functions exactly so it threads through the if-handler's existing snapshot points with no new control-flow framework.
2. **Add a `condition → (subject_name, variant_idx, inner_type)` normalizer** that handles exactly `x.some?` (already rewritten to `option_is_some(x)` at `typecheck_expr_handlers.qz:659`), `x.is_some()`, and `x is Some` — only when `x` is a bare `NODE_IDENT` bound to a `const` of `TYPE_OPTION`. Reuse `tc_resolve_variant_type` (`typecheck_match.qz:33`) to compute the inner type.
3. **In the plain-`if` arm** (`typecheck_walk.qz:4362`), before walking `then_node`: snapshot narrow, push the refinement if the normalizer produced one, walk then-branch, restore narrow. (The linear/move snapshots around it are already there — slot the narrow snapshot in alongside.)
4. **In the identifier handler** (`typecheck_walk.qz:1178`), consult the narrow table first; return the refined inner type if present.
5. **Wire the narrowed read through `mir_ctx_apply_pending_bind`** for payload extraction (`mir.qz:9668`) — start with the spill + single-niche layouts; multi-niche Result is Phase 3.
6. **Gate:** `quake guard` (fixpoint) + smoke tests + the new `flow_narrow_spec.qz`. The very first assertion to make pass: a single `it("narrows const Option in then-branch")`.

The single smallest change that yields a green test: steps 1–4 with lowering deferred by writing the Phase-1 test against typecheck acceptance (does it type?) before wiring MIR — but since Quartz tests run end-to-end, do 1–5 together for the first runnable spec.

---

## 7. Open design questions for the owner

1. **`var` in v1 — refuse, or narrow-with-invalidation?** Recommendation: refuse in Phase 1 (Kotlin posture), add invalidation in Phase 2. Confirm the conservative Phase-1 cut is acceptable (const-only covers the vast majority given const-default).
2. **Lowering strategy A vs B** (§3.4): reuse match payload-extract (A, recommended) vs synthetic implicit-bind rewrite (B). A is less invasive; confirm no objection to marking narrowed read-nodes for MIR.
3. **Field-path narrowing** (`a.b.opt.some?`) — deferred to post-v1 (needs alias/purity reasoning we lack). Confirm bare-identifier-only is acceptable for v1.
4. **Else-narrowing for binary enums** (`if x.some? else <x is None>`) — high value, included in Phase 2. Confirm it's wanted (some languages omit it).
5. **`while x.some?` loop-condition narrowing** — Phase 4, low priority. Worth it, or drop (refutable `while Some(v) = x` would be the cleaner path but doesn't exist yet — `while let` was removed)?
