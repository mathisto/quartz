# Generator nested-while-loops yields each value twice

**Status**: ✅ **RESOLVED 2026-04-30** — `spec/qspec/generator_spec.qz`'s `it("nested while loops with yield")` is green at HEAD, with the canonical-output assertion `"0:0\n0:1\n1:0\n1:1\n"`. 2-deep and 3-deep variants both correct (3-deep `3*3*2=18` count verified). Likely closed by Phase 4.B.9 slice 2 (`573887ae` — for-loop state preservation across yield) and/or the 4.B.7 routing unification series; the legacy 4-value `_gen_active` model the original bug repro'd on no longer exists (per `feedback_gen_active_kind3_routing.md`, only kind=0 and kind=2 are live today). Original report kept below for reference.

**Failing spec**: `spec/qspec/generator_spec.qz` — `it("nested while loops with yield")`.
**First observed**: 2026-04-24, during 4.B.6 verification sweep.

## Summary

A generator with nested `while` loops + `yield` in the inner body emits each yielded value twice (or once with an extra trailing duplicate). Reproduces on **both** code paths:

- Legacy state-machine path (`mir_lower_generator` / `__GenState_*$next`).
- Path B kind=3 effect path (`mir_lower_generator_effect` / `Stream$next`).

Same bad output on both, so the regression sits in the for-in dispatch / option-extraction layer, not the generator-suspension primitive.

## Repro

```quartz
def nested_while_gen(): impl Iterator<Int>
  var i = 0
  while i < 2
    var j = 0
    while j < 2
      yield i * 10 + j
      j += 1
    end
    i = i + 1
  end
end

def main(): Int
  for x in nested_while_gen()
    var row = x / 10
    var col = x - row * 10
    puts("#{row}:#{col}")
  end
  return 0
end
```

Expected output:
```
0:0
0:1
1:0
1:1
```

Actual output (both paths):
```
0:0
0:1
0:1
1:0
1:0
1:1
1:1
```

(7 lines, with duplicates on every value except the first — pattern suggests the for-in loop is calling `.next()` twice per iteration, or `option_get` is firing twice.)

## Why it matters

Single-while generators are fine. The bug only triggers with nested while + yield. None of the iterator-protocol or other generator specs catch it because they all use single-while or for-in over ranges. This is a sharp edge case worth fixing before any users write nested-loop generators.

## What's NOT the bug

- Not introduced by 4.B.6 flag flip. Reproduces on the pre-flip golden binary with both `--piezo-gen-b` ON and OFF.
- Not a regression in `mir_lower_generator_effect`. Same bad output on the flag-OFF legacy state-machine path.

## Investigation hint

Both code paths share `mir_lower_iter::lower_custom_iteration` for the for-in dispatch (just with different `next_func` names: `__GenState_*$next` vs `Stream$next`). The shared loop body does `option_is_some` → `option_get` → free → lower body → jump back. The duplicate-output pattern suggests one of:

1. `option_get` allocating + the iterator advancing twice on a single `option_is_some` true result.
2. The body being lowered into both the entry and resume blocks.
3. A scope leak where the inner loop's resume target is the outer loop's resume target.

Compare the IR of `nested_while_gen` against a simpler `for i in 0..3 yield i end` generator and look for duplicated body or duplicated `option_get` calls.

## Filing per Prime Directive 6

This was discovered during 4.B.6 verification. Filed here rather than fixed inline because:
- It's pre-existing (not introduced by 4.B.6).
- A correct fix likely lives in `mir_lower_iter::lower_custom_iteration` or upstream in how nested `_gen_resume_blocks` are managed — a non-trivial change orthogonal to the flag-flip scope.
- Fixing it requires reproducing on the legacy path first to localize the shared bug; that's its own session.
