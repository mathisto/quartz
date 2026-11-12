# PROFILE_ALLOC_TOP_N_VEC_STRING_HEISENBUG

**Status:** ROOT CAUSE IDENTIFIED 2026-05-03. Workaround in
`std/profile.qz` is now the structurally-correct fix (sb_append +
type-specialized `sb_append_int`). Substrate fix shipped: NODE_INDEX
elision in `mir_is_string_expr` for Vec<String>. Underlying bug —
`to_str`'s String-vs-Int heuristic is **unsound for any Int satisfying
`(val & 15) == 8 && val > 65535`** — remains as a follow-up under a
new ID (TO_STR_INT_HEURISTIC_UNSOUND).
**Filed:** 2026-05-01 during B.1 Phase 4 Path B.

## Root cause (identified 2026-05-03)

The `@to_str` runtime helper at `codegen_runtime.qz:6969` uses an
alignment + range heuristic to decide whether a value is a String
pointer or an Int:

```llvm
%low4 = and i64 %val, 15
%is_aligned = icmp eq i64 %low4, 8           ; aligned to 8 mod 16?
br i1 %is_aligned, label %check_range, label %int_path
check_range:
  %is_negative = icmp slt i64 %val, 0
  br ... ; reject negatives
check_min:
  %above_min = icmp ugt i64 %val, 65535       ; > 64KB?
  br i1 %above_min, label %check_str, label %int_path
check_str:
  %ptr = inttoptr i64 %val to ptr
  %raw = getelementptr i8, ptr %ptr, i64 -8
  %len = load i64, ptr %raw                   ; <-- CRASH if [val-8] unmapped
```

The heuristic assumes that an Int value would not satisfy *both* the
alignment check and the > 64KB range check. This is **wrong**: any Int
≡ 8 (mod 16) and > 65535 takes the `check_str` branch and dereferences
`[val - 8]`. If that address is unmapped, SIGSEGV.

In `profile_alloc_top_n` at heavy-workload scale, the recorded `bytes`
total for `mir_new_instr` happens to land at **416760** (= 0x65BF8).
- `416760 & 15 == 8` ✓
- `416760 > 65535` ✓
- `[416760 - 8] = [416752]` is **unmapped** → SIGSEGV.

This is not a Vec relocation, not a stale SSA cache, not an arena bug.
It is a fundamental unsoundness in `@to_str`'s tagging heuristic.

## Why the Vec<String> framing was misleading

The original framing assumed the bug was about `labels[i]`'s String
pointer going stale. Investigation 2026-05-03 ruled that out:

1. The IR for `vec_get` loads `data_ptr` fresh each iteration — no
   cached SSA pointer (rules out hypothesis 2).
2. The labels Vec holds rodata-stable string-literal pointers from
   `prof_alloc_site("phase_X", ...)` callsites — those don't go stale
   in a bump arena (rules out hypothesis 1 in this configuration).
3. A V2 form using `sb_append(sb, label)` directly (no interp, no
   to_str) emits all 38 entries cleanly on the same workload — proving
   `labels[i]` returns valid String pointers.
4. Re-running with the elision fix applied (`mir_unwrap_to_str_for_string`
   strips `to_str(label)` because `mir_ctx_get_vec_elem_type(labels) ==
   "String"`) **still** crashes — because the Int interpolations
   `to_str(bytes)` and `to_str(count)` remain and one of them satisfies
   the heuristic.
5. Crash trace pin: `profile$profile_alloc_top_n + 19108 → to_str + 56`,
   x19 = 0x65BF8 (= 416760), fault at 0x65BF0. The value is bytes for
   the iter-2 entry, not a Vec read.

## Substrate fix shipped 2026-05-03 (separate concern)

`mir_is_string_expr` for `NODE_INDEX` only checked
`mir_ctx_is_string_var(base)` — which is intentionally false for
`labels: Vec<String>` (Vec handles are integer pointers, not Strings).
But `vec_new<String>()` already records the element type via
`mir_ctx_mark_vec_elem_type`. Extended NODE_INDEX detection to consult
that tracking:

```diff
  if kind == node_constants::NODE_INDEX
    var base_node = ast::ast_get_left(s, node)
    if ast::ast_get_kind(s, base_node) == node_constants::NODE_IDENT
      var base_name = ast::ast_get_str1(s, base_node)
+     var elem_t = ctx.mir_ctx_get_vec_elem_type(base_name)
+     return 1 if elem_t == "String"
      return ctx.mir_ctx_is_string_var(base_name)
    end
    return 0
  end
```

This makes `eputs("...#{labels[i]}...")` emit `sb_append(sb, label)`
directly instead of `sb_append(sb, to_str(label))`. Doesn't fix this
bug (the Int interpolations were the actual trigger) but it eliminates
a redundant runtime call and reduces arena pressure in the same spot
where the heisenbug would otherwise be more likely to manifest.

## Workaround (the structurally-correct fix in `std/profile.qz`)

```quartz
var report = sb_new()
defer sb_free(report)
var idx = 0
while idx < emit_count
  var label = labels[order[idx]]      # OK: String type tracked, elision works
  var bytes = byte_totals[order[idx]] # Int
  var count = counts[order[idx]]      # Int
  sb_append(report, "[prof] alloc-site ")
  sb_append(report, label)            # direct sb_append, no to_str
  sb_append(report, ": ")
  sb_append_int(report, bytes)        # type-specialized — bypasses to_str heuristic
  sb_append(report, " bytes (")
  sb_append_int(report, count)
  sb_append(report, " calls)\n")
  ...
  idx = idx + 1
end
eputs(report.to_string())
```

The key is `sb_append_int` for known-Int values. The compile-time type
information lets us skip `to_str` entirely, which is the only way to
avoid the unsound heuristic without changing `to_str` itself.

## Follow-up filed: TO_STR_INT_HEURISTIC_UNSOUND

The unsound `(val & 15) == 8 && val > 65535` heuristic in `@to_str` is
a latent crash hazard for any code path that interpolates an Int via
`#{int_var}` where the value happens to fall in a misidentified range.
Realistic risk classes: byte counts, file offsets, hash codes, time
values in nanoseconds, IDs from external systems, etc.

Two paths to address:

1. **Compile-time type-specialized interp lowering**: extend
   `NODE_INTERP_STRING` desugar in `mir_lower.qz:3163` to dispatch each
   `#{x}` part to the type-specific append (`sb_append_int` for Int,
   `sb_append_float` for F32/F64, `sb_append` for String) instead of
   wrapping in `to_str`. Requires `mir_is_int_expr` helper symmetric
   to `mir_is_string_expr` / `mir_is_float_expr`. Most disciplined fix.

2. **Tighten `to_str`'s heuristic**: e.g. additionally require the
   pointer to land in a "real heap" address range (≥ 0x100000000 on
   macOS arm64). Fragile across platforms and break legitimate
   `to_str(0x100000008)` test cases — not recommended.

## Reproduction

Use a compiler binary built after B.1 Phase 4 Path B that contains the
`phase_*` chokepoints, then revert the `std/profile.qz`
`profile_alloc_top_n` workaround to the per-iter `eputs("...#{int}...")`
form (where the int interpolation is what trips it). Compile any
non-trivial program with `--alloc-track`; the compiler self-compile
crashes reliably at iter 2 → 3 boundary. (style_demo doesn't crash —
its `mir_new_instr` total falls in a benign range.)
