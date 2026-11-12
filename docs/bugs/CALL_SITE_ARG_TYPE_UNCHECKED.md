# Call-site argument types unchecked for user functions (silent soundness hole)

**Status:** ✅ FIXED 2026-07-07 (`98bbbc77`, conductor run `argtype-soundness-2026-07-07`, owner-attended). Positive-flag QZ0201 check (String↔numeric + Int↔Float; permits type-vars/erased-generics/newtypes/handle-punning/Bool↔Int) at user-function call sites. Prerequisite pun-cleanup landed first: `JsonValue::Float`→F64 (`ed4f1f2f`), `TomlValue::Float`→F64, and String-`assert_eq` sites → `assert_eq_str`. The check surfaced + fixed FOUR real bugs (effect-op struct-return field-type loss; `.chars()` Vec<String>-vs-Vec<Int> SIGSEGV-class mismatch; erased-generic false-positives; toml Float pun). Guard fixpoint 3296; zero net new corpus rejections; type_errors_spec 23/23. **Note (minor, filed):** the QZ0201 message appends "Int and Float need an explicit conversion" even for String↔Int cases — cosmetic, harmless; polish when convenient. **Filed sibling:** the generic-dispatch limitation that blocked the polymorphic-`assert_eq` route → `docs/bugs/GENERIC_OPERATOR_TRAIT_DISPATCH_MISSING.md` (ROADMAP R2.4). **Validation caveat:** behavior-changing (not gate-1-inert — str_chars/effect-op fixes alter valid codegen); validated via guard + broad direct-compile corpus sweep + targeted specs; a full `quake qspec` run (owner-run; OOMs unattended) is the recommended final sign-off.

---
_Original filing (2026-07-06) below, for history._
**Severity:** Medium-High — silent miscompile-adjacent. No crash, no diagnostic; wrong-typed args flow into codegen.

## Symptom (confirmed on HEAD)
User-function call sites validate ARITY but not ARGUMENT TYPES:

```qz
def add(a: Int, b: Int): Int
  return a + b
end
def main(): Int
  return add("hello", 3)   # compiles, exit 0, full IR emitted — NO error
end
```

`add(3.5, 3)` (float→Int) is likewise silently accepted. The two genuinely-broken classes are **String ↔ numeric** and **Int ↔ Float**, where the runtime representations actually differ (heap-ptr-as-int, float-bits-as-int).

## Site
`self-hosted/middle/typecheck_expr_handlers.qz`, the call handler around the arity block (~:3738-4560). It checks arg count but never unifies each declared param type against each argument's inferred type (only a few builtins like `puts`/`f2s` are special-cased). Param types available via `tc_lookup_function_params` (`typecheck_registry.qz`).

## Why the naive fix is UNSOUND (why it's parked, not shipped)
A per-argument strict type check was implemented and run through `quake guard`. The compiler's OWN source (a known-valid program, the most authoritative corpus member) produced **30 QZ0201 false-rejections** at self-compile, in 3 legitimate-coercion classes the **i64-everywhere model deliberately allows**:
1. `newtype AstNodeId = Int` — passing a plain `Int` into a newtype-of-Int param (and vice-versa). Pervasive idiom (e.g. `quartz.qz:351` `expand_macros(ast_storage, root)`).
2. `newtype AstStore = Int` flowing into an `Int` param (e.g. `quartz.qz:717`).
3. `AstStore` (newtype=Int) ↔ `AstStorage` (struct) — two names for the same i64 AST-arena handle, punned throughout (e.g. `quartz.qz:719/721/724`).

Even a *tight* comparator (`tc_elem_type_matches`, which treats newtypes as opaque) rejects these. The i64 model treats all i64 handles as interconvertible, so a general "distinct nominal type ⇒ error" check is wrong. Reverted per the conductor park protocol — shipping it would reject valid code across the corpus (and cannot be validated unattended: full `quake qspec` OOMs this Mac).

## Plan (attended)
1. **Newtype transparency:** before flagging, unwrap `newtype X = T` on BOTH the arg and param types and re-check (mirror `tc_types_match` newtype handling ~`typecheck.qz:2035-2049`). Fixes classes 1 & 2.
2. **Handle-punning:** the i64 model allows any-i64-handle ↔ any-i64-handle. Do NOT flag nominal-vs-nominal or handle-vs-handle mismatches.
3. **Narrow the check to the TRUE miscompile classes only:** reject (a) `TYPE_STRING` vs the int/float groups, and (b) int-group vs float-group. Leave all handle/newtype/struct punning permissive.
4. **Validate ATTENDED:** owner runs the full ~870-spec `quake qspec` + the example corpus (the narrowed check may still surface `Int`-literal-into-`F64`-param sites relying on implicit widening — decide whether to allow that coercion or require an explicit cast).

## Repro artifacts
- Hole: `/tmp/argtype_hole.qz` above (exit 0 on HEAD).
- Baseline corpus reject list (pre-change, unrelated): 32 files (`examples/*.qz` + `spec/qz/*.qz`, negatives excluded).
