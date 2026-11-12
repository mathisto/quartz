# `def f<K, V>(m: Map<K, V>)` crashes compiler with "unhandled effect op called"

**Status**: ✅ **FIXED 2026-04-29 (commit `d66b2f38`).** Defaultise TYPE_ERROR to TYPE_INT for both K and V at `self-hosted/middle/typecheck.qz:1441-1464` — mirrors the Phase 4.B.9 slice 3 for-in iter-binding fallback. Existential erasure makes runtime values i64 regardless. Regression locked in `spec/qspec/map_generic_spec.qz` "Map<K, V> with generic type-params on the function" describe block (compile-only + execute paths). 19/19 tests green; fixpoint 2411 byte-identical.

**Original** (pre-existing, surfaced 2026-04-25 while writing the generic-helper-for-in regression spec).
**Severity**: minor — narrow, workaroundable, blocks generic Map utilities.
**Reproduces on**: every Quartz binary (verified pre- and post-`genfor-fallback` fix).
**Workaround (no longer needed post-fix)**: use a concrete-typed param (`Map<String, Int>`) or a `Vec<K>` keys-extracted variant.

## Repro

```qz
def use_map<K, V>(m: Map<K, V>): Int
  return 0
end
def main(): Int = 0
```

`./self-hosted/bin/quartz --no-cache repro.qz` →
```
unhandled effect op called
```

(no further diagnostic; compiler exits non-zero before emitting any IR.)

## What does NOT trigger

- Concrete `Map<String, Int>` parameter — fine.
- Generic `Vec<T>` parameter — fine (post-`genfor-fallback` fix at least; was buggy in for-in scope before).
- Single-generic `Map<K, Int>` — needs verification, but the `tc_parse_type` path that handles two-arg ptypes is likely the culprit.

## Likely root cause

`tc_parse_type("Map<K, V>")` probably calls `tc_extract_element_type` and then recursively parses the comma-separated args. For each generic type arg (`K`, `V`), `tc_parse_type("K")` returns `TYPE_ERROR` (generic params have no scope binding for free functions; see lines 3992-3997 of `tc_function`). The Map ptype constructor likely doesn't handle two TYPE_ERROR arms gracefully and lets an effect op escape an internal handler — hence "unhandled effect op called" at the runtime, not a clean QZ-coded diagnostic.

The Vec<T> path was not affected by this same shape because Vec's element-type parser handles a single TYPE_ERROR arg cleanly (returns `tc_make_ptype(TYPE_VEC, TYPE_ERROR, 0)` — a valid ptype with TYPE_ERROR carried as arg1; downstream readers tolerate this).

## Followup

Investigate `tc_parse_type` for `Map<K, V>` — specifically the two-arg case, where K or V may be TYPE_ERROR. The fix is likely the same shape as Phase 4.B.9 slice 3's for-in fix: defaultise unresolvable generic param types to TYPE_INT before calling the ptype constructor, OR teach the Map ptype path to tolerate TYPE_ERROR component types by replacing them at construction time.

Once fixed, the `loop_keys<K, V>(m: Map<K, V>); for k in m; ...` pattern should also work (the for-in MAP branch in `tc_for_in` already extracts arg1 — it would benefit from the same TYPE_ERROR → TYPE_INT fallback, but that fallback is now applied uniformly to all element types via the patch at the bind site).
