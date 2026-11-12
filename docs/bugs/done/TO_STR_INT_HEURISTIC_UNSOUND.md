# TO_STR_INT_HEURISTIC_UNSOUND

**Status:** CLOSED 2026-05-03 (filed same day, closed same day).
**Severity:** Latent SIGSEGV hazard for any code path that
interpolates an Int via `#{int_var}` where the value happens to land
in a misidentified range. Triggered live in `profile_alloc_top_n`
(closed via `sb_append_int` workaround) and likely lurked elsewhere.

## Closure

Option 1 (compile-time type-specialized interp lowering) shipped. Three
substrate touchpoints, two structural compiler bug-fixes uncovered en route:

1. **`mir_is_int_expr` + `mir_unwrap_to_str_for_int`** in
   `self-hosted/backend/mir_lower.qz` — sister helpers to
   `mir_is_string_expr` / `mir_unwrap_to_str_for_string`. Conservative
   detector: trust only `mir_infer_expr_type == "Int"` (false-negative is
   safe; false-positive would garble output).

2. **NODE_INTERP_STRING desugar update** at the same file's existing
   desugar block — try Int classification first, dispatch through inline
   `sb_append_int` for the multi-part case; fall back to existing
   String-elision-or-`to_str` path.

3. **`to_str(int_expr)` → `str_from_int(int_expr)` rewrite hook** at the
   top of `mir_lower_call` in
   `self-hosted/backend/mir_lower_expr_handlers.qz`. Required because the
   parser (`parser.qz:1205-1207`) bypasses NODE_INTERP_STRING entirely
   for single-part interps like `"#{n}"` — returns the bare `to_str(n)`
   call directly, which never reaches the desugar. The rewrite hook also
   catches user code that explicitly writes `to_str(n)` for a known-Int
   `n`.

### Structural bugs uncovered (and fixed in the same pass):

A. **`struct_types` cross-function leak** — `mir_ctx_get_var_type` does a
   LIFO scan of `ctx.struct_types`, but unlike its siblings
   (`reset_string_vars` / `reset_float_vars` / `reset_vec_elem_types` /
   `reset_map_key_types`) there was no `reset_struct_types`. So a `var p
   = some_progress` in one function would leak into a sibling
   `def f(p: Int)` and `mir_infer_expr_type("p")` would return
   `"Progress"` instead of `"Int"`. Pre-fix this was harmless because
   downstream callers either checked field-existence (a wrong struct
   name returns no field, fall through cleanly) or didn't compare exact
   type names. `mir_is_int_expr`'s exact `== "Int"` check was the first
   in tree to surface the leak. Symptom during this fix: `format_param`
   under qspec import would route through `to_str(p)` instead of
   `sb_append_int(sb, p)` because `p`'s inferred type was poisoned. Fix:
   added `reset_struct_types` to mir.qz and called it at the same 4
   reset sites the others use.

B. **`mir_infer_expr_type` NODE_INDEX vec_elem fallback gap** — when a
   local Vec is tracked as the bare struct name `"Vec"` (no `<T>`
   suffix), generic-element extraction returned `""`, so `v[0]` for
   `v: Vec<Int>` had no inferred type. The vec_elem_types registry has
   the answer but `mir_infer_expr_type` didn't consult it. Fix: added
   the fallback. Mirrors `mir_is_string_expr`'s NODE_INDEX special case
   that consults the same registry.

### Verification

- 11/11 new `spec/qspec/to_str_int_heuristic_spec.qz` regression tests green
  (covers literal, local var, param, intrinsic-return, user-fn-return,
  arithmetic, Vec<Int>[i], single-part, multi-part, mixed string+int,
  loop-emitted shapes).
- 70/70 pre-existing interp tests still green (`string_interpolation`,
  `nested_interpolation`, `parser_interpolation_fix`, `triple_interp`,
  `split_interp`, `option_interp`, `wasm_string_interp`).
- Smoke tests on `style_demo.qz` + `brainfuck.qz` green.
- Self-compile with `--alloc-track` runs to completion and emits all
  39+ alloc-site entries cleanly (was crashing pre-PROFILE_ALLOC fix at
  iter 2 → 3 boundary; the `bytes = 416760` value for `mir_new_instr`
  no longer takes the unsound `@to_str` path).
- Fixpoint clean: 2482 functions byte-identical (gen1 == gen2).

### Float interp residual (NOT addressed)

Float values whose bit patterns satisfy `(val & 15) == 8 && val > 65535`
have the same hazard. Lower-priority: typical IEEE-754 doubles rarely
satisfy the alignment check (lower 4 bits are usually mantissa LSBs that
are non-zero). No `sb_append_float` intrinsic exists today, so a Float
fix would require either:
1. Adding `sb_append_float` + extending the desugar with
   `mir_unwrap_to_str_for_float`.
2. Adding a `to_str(float_expr) → f64_to_str(float_expr)` rewrite hook
   sister to the Int rewrite shipped here.

File when a real-world Float trigger surfaces. The substrate is
half-built (`mir_is_float_expr` already exists).

### Workaround in std/profile.qz

The `sb_append_int` workaround in `std/profile.qz` is now redundant —
the substrate fix handles `#{int}` shapes correctly. The workaround
stays in place because (a) it's correct, (b) it's slightly more
efficient (skips one AST walk + intrinsic-redispatch), and (c) reverting
it is out-of-scope for this fix per "a bug fix doesn't need surrounding
cleanup."

---

# Original problem statement (preserved for context)


## Problem

The `@to_str` runtime helper at
`self-hosted/backend/codegen_runtime.qz:6969` distinguishes String
pointers from Int values via:

```llvm
%low4 = and i64 %val, 15
%is_aligned = icmp eq i64 %low4, 8
br i1 %is_aligned, label %check_range, label %int_path
check_range: ...
check_min:
  %above_min = icmp ugt i64 %val, 65535
  br i1 %above_min, label %check_str, label %int_path
check_str:
  %ptr = inttoptr i64 %val to ptr
  %raw = getelementptr i8, ptr %ptr, i64 -8
  %len = load i64, ptr %raw    ; <-- DEREF of bogus pointer for misclassified Int
```

**Any Int value satisfying `(val & 15) == 8 && val > 65535` will be
mis-classified as a String pointer.** The dereference at `[val - 8]`
then either crashes (unmapped page, SIGSEGV) or returns garbage that
fails the subsequent length / null-terminator checks and falls through
to `int_path`. SIGSEGV is the dominant failure mode because most Int
values in the misclassified range don't sit on top of a mapped page
8 bytes below them.

Documented confirmed trigger:
- `profile_alloc_top_n` interpolating `bytes = 416760` (= 0x65BF8) for
  the `mir_new_instr` entry in self-compile `--alloc-track` runs.
- 416760 ≡ 8 mod 16 ✓, 416760 > 65535 ✓, [416760 − 8] unmapped → SIGSEGV.

## Risk surface

Realistic Int interpolation contexts that could hit this:
- Byte counts / offsets (file size, allocation totals, RSS)
- Hash codes
- Nanosecond timestamps (less likely — they're typically in the
  10¹⁵ range, well above misidentified range, but always & 15 == 0
  due to typical timer granularity, so the alignment check fails)
- IDs from external systems (random Int → 1/16 chance of alignment hit)
- Indexed loop counters multiplied by a power of 2 size
- Vec capacities, Map sizes, etc.

Roughly **1/16 of all Int values that land above 65535** will trigger,
weighted by how often the value's `[val-8]` happens to be unmapped.

## Recommended fixes (ordered by preference)

### Option 1 — Compile-time type-specialized interp lowering (preferred)

Extend `NODE_INTERP_STRING` desugar in
`self-hosted/backend/mir_lower.qz:3163` to dispatch each `#{x}` part to
a type-specific `sb_append_*`:
- Known Int → `sb_append_int(sb, x)`
- Known F32/F64 → `sb_append_float(sb, x)`
- Known String → `sb_append(sb, x)` (already covered by elision after
  the 2026-05-03 NODE_INDEX fix in `mir_is_string_expr`)
- Unknown → keep `sb_append(sb, to_str(x))` (acknowledge residual risk)

Requires:
- A `mir_is_int_expr` helper symmetric to the existing
  `mir_is_string_expr` / `mir_is_float_expr`. Should consult vec elem
  type tracking, var type annotations, NODE_INT_LIT, arithmetic
  results, and intrinsic return types.
- Confirm `sb_append_int` exists (it does — `intrinsic_registry.qz:375`).

Estimated scope: ~50 LOC + qspec. Closes the bug class wherever the
type info exists at compile time. Residual `to_str` calls only remain
for genuinely-untyped values (e.g. erased generic parameters), where
the burden of avoiding the heuristic falls on the caller.

### Option 2 — Tighten the heuristic

E.g. additionally require `val >= 0x100000000` (4 GB) to take the
String path. This rejects `bytes = 416760`. But:
- Platform-dependent (heap base differs across macOS arm64, Linux
  x86_64, freestanding, etc.).
- Brittle: legitimate small malloc'd Strings on platforms without ASLR
  could fall below the threshold.
- Doesn't actually fix the bug, only shifts the misidentified range.

Not recommended unless Option 1 hits a roadblock.

### Option 3 — Tagged value representation

Reserve the low bit (or equivalent) for a Type tag, using a NaN-boxing
scheme or pointer tagging. Soundest fix; major redesign with
ABI-breaking implications across the entire compiler. Requires its
own multi-phase project. Not appropriate as a follow-up to this bug.

## Audit before fixing

Before sizing Option 1, grep the actual interp surface for
realistic Int hazards. Project memory `feedback_audit_count_inflation.md`
applies — count actual vulnerable callsites, not all `to_str` calls.

```bash
# Rough audit start: every interp string that includes an int_var.
grep -rE '#\{[a-z_]+(_count|_bytes|_size|_id|_ms|_ns|_idx|_offset)' \
  self-hosted/ std/ tools/ examples/
```

Filter for cases where the int could plausibly hit the misidentified
range (val > 65535).
