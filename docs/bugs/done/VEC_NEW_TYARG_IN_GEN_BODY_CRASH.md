# `var v = vec_new<Int>()` inside `impl Iterator` body crashes compiler

**Status**: ✅ **CLOSED 2026-04-30**. Root cause: `mir_collect_generator_locals` (mir_lower_gen.qz lines 687-718) walked NODE_FOR's `extra` slot as if it held an AST handle, but `typecheck_walk.qz:3673` mutates that slot post-typecheck via `ast_set_extra(node, iter_type)` — `iter_type` is a **ptype id**, not an AST handle. When the ptype id numerically collided with a parent AST handle (n=3 push-count specifically), `mir_collect_generator_locals(s, extra)` re-entered the parent block → unbounded recursion → stack overflow → SIGSEGV.

Diagnostic that cracked it: depth-counted `eputs` trace showed the cycle `body=24 (NODE_BLOCK fn body) → body=3 (NODE_LET) → 8/13/18 (NODE_EXPR_STMT × 3) → body=23 (NODE_FOR) → body=19 (left/IDENT) → body=22 (right/BLOCK) → body=21 (NODE_YIELD) → body=24 again` — the wrap-around from 21 to 24 was NODE_FOR's `extra` slot at runtime, which post-typecheck held an i64 that happened to equal AST handle 24 only at exactly n=3.

Fix: split the `WHILE/IF/FOR` walk in `mir_lower_gen.qz` so NODE_FOR's `extra` is no longer descended (`if kind != NODE_FOR` gate around the extra walk). NODE_WHILE and NODE_IF still walk their `extra` slot — those remain AST handles (else-branch / loop-condition).

Fixpoint clean at 2425 functions (count-neutral). 16 generator/iterator specs / 152 tests green post-fix (generator_spec, generators_p4a/p4b2/p4b3/p4b4a-c/p4b5/p4b8/p4b9, iterable_trait, custom_iterator, collection_iterators, cross_iter_match, async_iterator, codepoint_iter). Smoke tests (style_demo, brainfuck, expr_eval) green.

Project pattern note (in case this resurfaces): AST slots that started life as Int-or-AST-handle dual-use are a known footgun. `typecheck_walk` and friends sometimes store ptype ids, intern ids, or other compiler-internal i64s into AST extra slots after the AST is constructed. Walkers in `mir_lower` must check whether the typecheck-mutation sites have repurposed any slot before descending into it. Adjacent shape: `MirInstr.operand1/operand2` field aliasing (filed in `feedback_mir_instr_field_aliasing.md`).

**Severity**: was minor + workaroundable. Now fixed; workaround note retained for archive value.
**Reproduces on (pre-fix)**: every Quartz binary that ran typecheck before mir lowering (verified pre- and post-`p4b9b-for-loop-state` fix).
**Workaround (no longer needed)**: bug doc claimed `var v: Vec<Int> = vec_new()` (annotated binding form) compiled cleanly, but at HEAD the annotated form ALSO crashed — the doc was stale on that detail. Real "workaround" was n != 3 push count.

## Repro

```qz
def gen_from_vec(): impl Iterator<Int>
  var v = vec_new<Int>()
  v.push(10)
  v.push(20)
  v.push(30)
  for x in v
    yield x
  end
end

def main(): Int
  for x in gen_from_vec()
    puts(x.to_s())
  end
  return 0
end
```

`./self-hosted/bin/quartz --no-cache repro.qz` → `EXIT=139` (SIGSEGV in compiler).

## Push-count sensitivity (the weird part)

The crash is deterministically tied to *exactly* `v.push(...) × 3` invocations:

| Push count | Compiler exit |
|---|---|
| 1 | 0 ✓ |
| 2 | 0 ✓ |
| 3 | 139 ✗ |
| 4 | 0 ✓ |

This non-monotonic pattern strongly suggests the crash is in some optimization pass or analysis whose behavior depends on a count or table size that hits a specific buggy index at exactly 3 elements. Likely candidates: dead-store elimination / SSA renaming inside the inferred-type-arg path, or a closure-capture index off-by-one for the implicit `<Int>` generic specialization.

## What does NOT trigger

- `var v: Vec<Int> = vec_new()` (annotated binding) — compiles at any push count.
- Vec passed as a parameter (`def gen(v: Vec<Int>): impl Iterator<Int>; for x in v ...`) — compiles cleanly.
- For-in over the same Vec WITHOUT a yield in the body — compiles cleanly.
- Same source outside an `impl Iterator` body (e.g., in `main`) — compiles cleanly.

So the trigger is the *intersection* of: type-arg-on-call form (`vec_new<Int>()`), inside an `impl Iterator` direct generator body, with for-in + yield reachable from the binding.

## Why this didn't surface before

The pre-Phase-4.B-effects path `mir_lower_generator` (deleted 4.B.7.a) used a different lowering shape that may have masked whatever the inferred type-arg path is doing wrong. Or the bug is older and just rarely hit because the intersection is narrow — most generator authors either pass Vecs as parameters or use the annotated binding form.

## Root cause investigation (deferred)

Suggested approach for whoever picks this up:

1. Run lldb against the compiler with `repro.qz` and `bt` at the SIGSEGV.
2. The crash is push-count-3 specific; bisect by changing the count to confirm the trigger.
3. Likely lives in either `mir_lower_generator_effect` (the impl-Iterator $poll builder) or in the typecheck pass that resolves `vec_new<Int>()`'s call-site type args.
4. Compare the `--dump-mir` output for n=2 (works) and n=3 (crashes) to localize where the divergence appears.

Not blocking any user-facing functionality — the workarounds (annotation or parameter) cover all real use cases. Filed for completeness per CLAUDE.md Prime Directive 6 (holes get filled or filed).
