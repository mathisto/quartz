# Bug Report: U.9.10 Compiler Hang on Trait-Bounded Generics

> **Status**: LIKELY FIXED — unable to reproduce on current trunk (1c17291)
> **Filed**: Feb 26, 2026
> **Severity**: BLOCKER (when reproducible)
> **Roadmap ref**: U.9 row — "compiler hang blocks negative constraint test"

---

## Description

The roadmap U.9 row mentions a compiler hang that blocks adding a negative
constraint test for intersection types. When a generic function with
multi-trait bounds is called with a type that does NOT satisfy all bounds,
the compiler was reported to hang instead of producing an error.

## Reproduction Attempts

6 patterns were tested against current trunk with `timeout 10`:

| # | Pattern | Result |
|---|---------|--------|
| 1 | Negative trait constraint (type missing one trait) | ✅ Correct error: QZ0200 |
| 2 | Recursive generic with trait bound | ✅ Compiled successfully |
| 3 | Intersection type as direct param annotation | ✅ Compiled successfully |
| 4 | Structural dispatch on trait-bounded generic | ✅ Arity error (expected) |
| 5 | Recursive generic calling itself | ✅ Arity error (expected) |
| 6 | Chained generic calls crossing trait bounds | ✅ Arity error (expected) |

**None caused a hang.** All completed within 1 second.

## Root Cause Hypothesis

The hang was most likely fixed by **F.2 — Generic Type Gaps** which lists
"monomorphization loop guard" as one of its 6 fixes. The F.2 phase landed
before U.9, so the fix predates the hang report in the roadmap.

## Recommendation

1. **Update roadmap U.9 row**: Remove "compiler hang blocks negative constraint test"
2. **Add the negative constraint test** to `intersection_types_spec.qz`:
   ```quartz
   it("negative multi-trait constraint produces error") do ->
     assert_compile_error("...", "QZ0200")
   end
   ```
3. **Close this bug** unless someone can provide a specific reproduction case

## Files

Reproducer files saved at `/tmp/hang_repro_{1..6}.qz` for reference.
