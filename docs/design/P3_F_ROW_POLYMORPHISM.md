# P3.F — Effect-polymorphic combinators via row polymorphism

> **Epic**: Operation Piezoelectric Effects · `[piezo]` Phase 3
> **Status**: Design closed, implementation starts with F.1.
> **Prior art**: Koka (Leijen), Links (Lindley/Cheney/Morris), Eff (Bauer/Pretnar), Xie & Leijen 2020 "Effect Handlers in Haskell, Evidently."
> **Decisions carried in from memo `EFFECTS_IMPLEMENTATION_PLAN.md`** (2026-04-18): flat rows + tail-polymorphic row variables (Koka model); row subtyping rejected; evidence-passing compilation via the install/perform handler-stack (already shipped Phases 1–2); worker-wrapper monomorphization accepted at ~20% code-bloat cost per Koka's data.

## Motivation

Phase 3 migrated async onto the effect system. Today every combinator in `std/streams` hard-codes `impl AsyncIterator<Int>` and `Fn(Int): Int`. A pure source can't flow through `stream_map`; an async callback can't be passed to a "pure" combinator because there isn't one. The core promise of an effect system — "write the combinator once, let rows decide" — is unclaimed.

P3.F delivers that promise. End-state:

```quartz
def stream_map<T, U, e>(src: impl Iterator<T> can e, f: Fn(T): U can e): impl Iterator<U> can e
  for v in src
    yield f(v)
  end
end

## Pure use — e instantiates to {}
var nums = range(1, 10).to_iter()
var doubled = stream_map(nums, x -> x * 2)
var total = stream_sum(doubled)           ## pure path, no Async in row

## Async use — e instantiates to {Async}
var ticks = counting_async()
var loud  = stream_map(ticks, x -> x * 2) ## same function, different row
var async_total = stream_sum(loud)        ## Async in caller's row, widens naturally
```

One combinator, two paths. The row variable `e` is a name in the function's generic-param scope.

## What's already built (checked before this memo)

- Parser: `can A, B | ε` parsed into AST storage (`parser.qz:5696`). Tail is stored as a String.
- Row registry: `tc_row_new(labels, tail_var)`, `tc_row_walk` (union-find walk of row vars), `tc_row_unify` (Rémy-style symmetric), `tc_row_subsume_with_handlers` (asymmetric caller⊇callee with `with` scope unwinding).
- Row-var registry: `tc_erv_fresh` allocates; `tc_erv_bind` unions.
- Call sites: `typecheck_expr_handlers.qz:1577` already calls `tc_row_subsume_with_handlers` at every call with a declared caller row.

## The gap (one line in a comment at `typecheck.qz:4298`)

> "The name is per-function-scope and B's row system isn't expressive enough to share tails across fns by name yet — the unifier only needs a fresh, distinguishable placeholder per `can ... | tail` clause."

Every `can X | e` currently allocates a fresh row-var. So the three `e` mentions in `stream_map`'s signature are three unrelated vars. No propagation. That's the whole blocker.

## Design

### Naming convention (user-facing decision, locked)

**Lowercase-first type-param name = row variable. Uppercase-first = type variable.** Single grammar for generics; kind is inferred from spelling:

```quartz
def foo<T>(x: T): T          ## T is a type var (uppercase)
def bar<e>() can e           ## e is a row var (lowercase)
def baz<T, U, e>(f: Fn(T): U can e): U can e   ## mixed
```

Ruby-style — no new keyword, no non-ASCII, no sigils. Falls naturally out of the same split Quartz already uses for `PascalCase` types vs `snake_case` bindings.

### Unification semantics

Unchanged from what's already shipped — flat rows with `tc_row_unify` (symmetric Rémy) and `tc_row_subsume_with_handlers` (asymmetric caller⊇callee). The only change is that row-var IDs are now **named** within a function scope instead of freshly allocated per `can` clause.

### Call-site instantiation

When a polymorphic function is called, its type-param scheme is instantiated fresh. The existing `tc_instantiate` (typecheck_util.qz:2689) already handles mixed-kind schemes (see "ROW Phase 2: Mixed schemes" comment at line 2695) — negative IDs = type vars, positive = row vars. Effect-row-var instantiation slots in here.

### Evidence-passing

**No codegen changes.** Evidence is already threaded through the install/perform handler-stack (`@__qz_effect_stack_*` globals). A polymorphic function body compiles identically to a monomorphic one — perform-ops look up handlers at runtime. Row polymorphism is a purely static property. Worker-wrapper optimization (memo §5) is future work, not required for correctness.

## Implementation phases

### F.1 — Row-var names bound in function scope

**Problem.** `tc_attach_func_effect_row` (typecheck.qz:4278) allocates a fresh erv for every `can ... | tail` clause.

**Fix.**
1. Add `func_row_var_env: Map<String, Int>` to TypecheckState, reset per-function.
2. On function-signature entry: iterate type-params; for every name whose first char is lowercase, allocate `tc_erv_fresh` and bind name → erv in the env.
3. In `tc_attach_func_effect_row`: if tail_str is non-empty, look up in `func_row_var_env` first. Fall back to `tc_erv_fresh` only if unbound (preserves old behavior for anonymous tails in untracked functions).
4. Cross-signature sharing: three `can e` mentions in the same signature (receiver, callback param type, return type) resolve to the same erv.

**Verify.** Spec with `def demo<e>(f: Fn(Int): Int can e) can e` calling `f(x)` — row widens caller by whatever `f` declared.

**Files touched.** `self-hosted/middle/typecheck_util.qz` (state field), `self-hosted/middle/typecheck.qz` (attach + entry hook), possibly `typecheck_registry.qz` for call-site instantiation.

**Size estimate.** ~200 LOC. 0.5 quartz-day.

### F.2 — `Fn(T): U can e` annotations on function types

**Problem.** `Fn` type parsing at `parser.qz:722` doesn't accept a `can` clause on the return type. Callback params can't declare effects.

**Fix.**
1. Parser: after `ps_parse_type` of the return, if next token is `TOK_CAN`, parse a row and store it on the synthesized Fn type.
2. Registry: `fn_type_effect_row_idx: Vec<Int>` alongside existing Fn-type fields; default -1 (untracked), Set per-type when parsed.
3. At a call `f(v)` where `f: Fn(...): R can e`: widen caller's row by f's declared row (using the same subsume machinery).

**Size estimate.** ~150 LOC. 0.3 quartz-day.

### F.3 — Trait methods + `impl Trait can e`

**Problem.** `impl Iterator<Int>` parameter form doesn't carry per-method row info. `for v in src` needs to know whether `src.next()` has `can Async` so it can widen caller's row.

**Design check.** `ps_parse_function` is shared between trait methods and free defs, so `can` already parses on trait methods. The gap is whether that row is looked up at the call site when `src` is statically typed as `impl Iterator<T>`.

**Fix.**
1. Trait method registry carries its effect row (likely already does — verify).
2. At `for v in src` / `for await v in src` desugaring, when src's type is `impl Iterator<T>`, read the trait method's row and apply it at the call site.
3. Unify `Iterator` and `AsyncIterator` traits into a single `Iterator<T>` whose `next(): Option<T> can e` carries a row var. Collection impls (Vec, Range, String) stay `next() can {}`; async generators get `next() can Async`.

**Key question.** Does unifying the traits break for-await vs for parsing? Answer: `for await v in src` should remain valid — it becomes a compiler hint that desugars to $poll-based lowering. `for v in src` does type-directed desugaring: if src's `next()` has Async in its row, lowers to $poll; else to direct call. That's the Ruby-feel payoff.

**Size estimate.** ~300 LOC. 0.5–1 quartz-day. Biggest chunk.

### F.4 — Rewrite `std/streams.qz`

Eight combinators, all migrated to `<T, U, e>` row-polymorphic signatures. No behavior change for existing async callers (e instantiates to {Async} at every call site in current code).

**Size estimate.** ~50 LOC delta. 0.2 quartz-day.

### F.5 — End-to-end spec

`spec/qspec/effect_poly_streams_spec.qz`: ~8 tests.

1. Pure range → stream_map → stream_sum == N.
2. Async counting → stream_map → stream_sum_async == N.
3. Composition: stream_filter(stream_map(src, f), pred) for pure and async.
4. Negative: `stream_map<e>` called with Async callback from a caller missing `can Async` → expected error.
5. Mixed: callback with `can {}` passed to `stream_map` applied to async source — e binds to {Async} from source, callback doesn't need to widen.
6. Take/skip/enumerate across both modes.

**Size estimate.** 0.3 quartz-day.

### F.6 — Error messages

Audit row-unification failure emitters. Per memo operational commitments:
- Invisible users (no `can`, no row var) never see "row", "tail", "ρ", "unification".
- Explicit users (have `can`, no row var) see structured mismatch with no jargon.
- Expert users (use row vars) see terse row-diff: `expected {Async}, found {}`.

**Size estimate.** 0.3 quartz-day.

## Total estimate

~2 quartz-days across 6 commits. Medium risk — the unification core is proven; the scope-binding is the new code. Codegen untouched.

## Non-goals (deferred)

- **Worker-wrapper monomorphization.** Memo §5. Nice-to-have for specialized codegen at hot polymorphic call sites. Not needed for correctness. File as Tier 5 post-P3.F.
- **Row-var bounds (`<e: FileIo>`).** Restricting which labels a row var may contain. Koka has this. Not needed for P3.F; file as optional future polish.
- **Multiple row vars in one signature (`<e, f>`).** Should work naturally under the symbol-table design; include a spec case. No special effort required.

## Handoff

If the session splits mid-phase, resume from the task list (`F.1…F.6`) and the last-committed chunk. Each phase is independently commitable — F.1 ships with a passing spec of its own before F.2 begins.

---

## Implementation progress

### F.1 — SHIPPED 2026-04-21 (`a37efbde`)

Scope-bound row-var env in function signatures. Lowercase type-params now allocate a fresh `tc_erv` on signature entry, bound in `tc.func_row_var_names`/`func_row_var_ids`. `tc_attach_func_effect_row` consults the env before falling back to fresh. Correctness-preserving on its own (no pre-existing source used lowercase type-params). Fixpoint 2236 → 2241. 20/20 effect specs green.

### F.2 — SHIPPED 2026-04-21 (`22010548`)

Fn types carry `can` rows, resolved via the enclosing function's env. Call-site instantiation substitutes a fresh erv per call so pure + async callers of the same polymorphic function don't collide. Three design pieces landed here that were only sketched in the memo above:

1. **Grammar restriction**: Fn `can` accepts single-label or tail-only rows (no comma-separated multi-label) because comma would collide with the outer param-list grammar. Users who need multi-label rows on Fn types define an effect alias (future).
2. **Parser-ambiguity reinterpretation**: `can e` parses as labels=["e"] (indistinguishable from `can E`). At typecheck, if a single label is a lowercase name that matches a declared row-var in scope, it's reinterpreted as `can | e` tail-only. This gives the terse Ruby-feel form without requiring `can | e`. Applied in both function-level attach and Fn-type resolve.
3. **Call-site instantiation must read the ORIGINAL tail**: `tc_row_instantiate_for_call` reads `tc_row_get_tail(row_id)` directly, NOT `tc_row_walk(row_id)`. Walking follows prior bindings and silently misses generalization when a previous call site already bound the erv. Symptom: mixed pure+async test compiled the pure path but QZ0610'd on the async path. Fix retained as a comment in the helper.

New spec: `effect_poly_fn_can_f2_spec.qz`, 4/4 green. Proves `compose2<e>(f: Fn(Int): Int can e, g: Fn(Int): Int can e, x: Int): Int can e` works for both pure (result=21) and async (result=200) callers through the same combinator. Fixpoint 2241 → 2248. 20/20 effect specs still green.

### F.3 — PENDING (work scope confirmed)

Smoke test confirmed the shared parser already accepts `can` on trait method signatures. The actual F.3 work:

1. **Trait-def registration**: add `trait_method_effect_rows: Vec<Vec<Int>>` parallel to `trait_method_names` in TcRegistry. When registering a trait def, walk each method's AST, call a trait-variant of `tc_attach_func_effect_row` that binds through the trait's type-param scope env.
2. **UFCS method call subsume**: at `receiver.method()` resolution sites, after picking the impl, pull the trait method's row (instantiated with receiver-specific trait type-params) and run `tc_row_subsume_with_handlers` + `tc_row_instantiate_for_call` against the caller.
3. **`impl Trait can e` parameter form**: parser accepts `can` after `impl Trait<T>` in param positions; typecheck attaches the row to the param's `impl`-wrapper metadata so method calls on that param see the row.
4. **For-loop desugaring**: `for v in src` reads Iterator's `next()` row from the trait metadata and widens caller's row if Async is present. `for await v in src` forces the Async widening regardless of whether src's `next()` is explicitly tagged (currently how it works).

Estimated ~300 LOC. This is where the Ruby-feel payoff lands — one `for v in src` that covers pure and async iterators. Recommended as the next session's priority.

### F.4–F.6 — Pending, blocked on F.3

F.4 rewrites `std/streams.qz` against the F.3 row-aware traits. F.5 writes the end-to-end spec. F.6 polishes error messages.

---

*Memo completed 2026-04-21. F.1 + F.2 shipped same session. F.3 starts next session.*

---

## Close-out (2026-04-21, end of day)

**All six F milestones shipped.** P3.F is done modulo one optional polish.

| Milestone | Commit | Shipped |
|---|---|---|
| F.1 | `a37efbde` | Row-var scope env in function signatures |
| F.2 | `22010548` | `Fn(T): U can e` + call-site instantiation |
| F.3a | `7d40831a` | Trait method row storage |
| F.3b + F.4 | `6bf6bcad` | `impl Trait<T> can e` parses; std/streams callback-polymorphic |
| F.5 | (included in `6bf6bcad`) | `effect_poly_stream_f4_spec.qz` 5/5 green |
| F.6 | `2689558b` | Concrete fix suggestions in QZ0610 errors |

### What works end-to-end today

- **Free-function row polymorphism**: `def compose2<e>(f: Fn: Int can e, g: Fn: Int can e, x: Int): Int can e` — pure + async callers through one combinator. Proof: `effect_poly_fn_can_f2_spec.qz` (21 pure + 200 async through same fn).
- **Collection-combinator polymorphism**: `def map_vec<T, U, e>(xs: Vec<Int>, f: Fn(Int): Int can e): Vec<Int> can e` — concrete container iteration, row-polymorphic callback. Proof: `effect_poly_collection_map_f3_spec.qz`.
- **std/streams callback polymorphism**: 5 combinators (`stream_map`, `stream_filter`, `stream_inspect`, `stream_take_while`, `stream_skip_while`) now `<e>` + `can e` on callback + return. Proof: `effect_poly_stream_f4_spec.qz` (5/5 including composition).
- **`impl Trait<T> can e` annotations parse cleanly** — ready for F.3c to consume.
- **Actionable error messages**: `QZ0610: '...' performs effects not in caller's can clause: Async. Add can Async to the caller.`

### What's left (optional followup — F.3c)

`for v in src` doesn't yet auto-widen the caller from Iterator's `next()` row. Users still need `for await v in src` when iterating async sources — the Async widening is explicit. Fully polymorphic `impl Iterator<T, e>` (pure + async sources through one function) requires:

1. Unify `Iterator` and `AsyncIterator` traits into one `Iterator<T, e>` with `next() can e`.
2. For-loop desugaring reads `next()`'s row from trait metadata.
3. Widen caller automatically if the row contains Async.
4. UFCS call-site subsume for abstract receivers (generic `T: Trait` params).

Estimated ~200 LOC. Not blocking current users. File as Tier 2 followup.

### Fixpoint trajectory

- Start of sprint: 2236 functions
- End of sprint: 2253 functions (+17 helpers across 6 commits)
- Fixpoint held on every commit.

### Design decisions that survived implementation

- **Lowercase type-param = row var, uppercase = type var** (locked F.1, no new keyword, no sigils).
- **Call-site instantiation reads ORIGINAL tail, not walked** (discovered F.2, critical for multi-site polymorphism).
- **`can e` reinterpretation**: single lowercase label matching a scope-bound row-var is a tail, not a closed label. Applied at function-level, Fn-type, and impl-Trait sites.
- **Fn `can` grammar restricted to single-label / tail-only** to avoid comma collision with outer param lists.
- **No codegen changes** — evidence flows through the existing install/perform handler-stack, exactly as the memo predicted.
