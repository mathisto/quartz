# Niche enum nested in a constructor sub-pattern reads RAW SPILL (not niche-aware)

**Status:** ✅ FIXED. Nested niche sub-pattern reads now route through
`mir_get_enum_tag_nested` (niche-aware), so a constructor sub-pattern binding an
inner niche enum reads the packed layout instead of raw SPILL. Regression spec
`spec/qspec/niche_nested_subpattern_spec.qz` green (37/37).
**Severity (historical):** would corrupt / SEGFAULT if hit, but the trigger shape was not in any
spec/std/compiler path at filing. Pre-existing for ALL niche layouts (Option + M1 user
enums + M2 built-in `Result`), NOT introduced by any one flip.
**Filed:** 2026-06-14 (at the M2 `Result<&A,&B>` flip — §14.10.Q7). Originally noted
as hazard #3 in MEMORY_MODEL_V3.md §14.10.Q4/Q5/Q6.

## Mechanism

A `match` on an OUTER enum whose arm binds an INNER niche enum via a *constructor
sub-pattern* lowers the inner read non-niche-aware:

```qz
match outer
  Wrap(Ok(x)) => ...   # the inner `Ok(x)` is read via the raw SPILL layout
end
```

The inner-enum read is lowered through:
- `mir_lower_stmt_handlers.qz:814` and `:2034`
- `mir_lower_expr_handlers.qz:4553`

each of which does `mir_get_enum_tag(inner_enum, mir_emit_load_offset(subject, spi+1))`
— a TAGGED-BOX load (tag at word 0, payload at word 1). It does NOT consult
`mir_subject_is_niche_multi` / `mir_subject_is_niche_option`. If the inner enum is
niche-laid-out (one word: `payload_ptr | tag`), this load reads the packed word AS a
box pointer and dereferences garbage.

The top-level read paths (direct `match r / Ok(x) => …`, `?`, `try`, hot combinators)
ARE niche-aware (`mir_subject_is_niche_multi` gates them). Only the *nested
constructor sub-pattern* position is missed.

## Why it is currently safe (no live trigger)

- The compiler/std construct ZERO niche-eligible built-in `Result` and no niche enum
  nested in a constructor sub-pattern (verified at the M1/M2 flips via fixpoint +
  full-qspec green).
- No spec nests a niche enum (Option/M1/M2) inside another enum's constructor arm with
  a boxed inner payload. `result_niche_spec`'s nested case is
  `Option<Result<…>>` read via `unwrap(o)` then a SEPARATE `match` — that goes through
  the niche-aware top-level path, NOT a constructor sub-pattern, so it does not trigger
  this.

## Fix shape

Thread niche-awareness into the constructor sub-pattern lowering at the three sites
above: before the `mir_get_enum_tag(inner, load_offset(subject, spi+1))`, check
`mir_subject_is_niche_*` on the inner enum's static type and, when niche, read the
single packed word (`tag = v & spare_mask`, `payload = v & ~spare_mask`) instead of the
two-word box. Mirror exactly how the top-level match arm already does it
(`mir_lower_expr_handlers.qz:1816/1851`). Add a spec that nests a boxed-payload niche
enum (e.g. `Wrap(Ok(struct))`) in a constructor sub-pattern and round-trips the inner
payload — it will fail today, pass after the fix.

## Verification

1. Author the nesting spec (currently absent) — it should reproduce the corruption.
2. Fix the three sub-pattern read sites to be niche-aware.
3. `quake guard` (fixpoint) + full qspec green + the new spec green.
