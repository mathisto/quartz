# QZ0603 — Incremental compilation loses struct type info for `.size`

## Status

**Warning surface CLOSED 2026-05-03.** The QZ0603 warning was firing spuriously
on cached free-function bodies because MIR-lower's incremental-mode gate
(`_mir_should_lower`) used a name-prefix-only heuristic: it extracted the
module name from the function's `$`-prefix, defaulting to `__main__` when
no `$` was present. Free functions in the function registry are stored
under their bare name (no `$` prefix — the registry mangles to
`progress$progress_register_column` in some flows but the registry entry
keyed on lookup is `progress_register_column`), so MIR's gate defaulted to
`__main__`, which is always in the recompile set during incremental builds
→ `should_lower=1` → suppress=0 → warning fires even though typecheck
correctly skipped the cached module's bodies. TC's gate at
`quartz.qz:813-851` did the same name-prefix extraction as a FALLBACK but
correctly used `dep_graph::depgraph_name_for_ast_store(ast_store)` as its
PRIMARY path, which handles both free functions (bare names) and impl
methods (`Progress$spinner_only` whose prefix is the struct name, not the
module name).

Fix: extend `_mir_should_lower` to take `(ast_store: Int, func_name: String)`
and use the dep-graph primary path; the prefix heuristic stays as a
fallback for the rare entry-without-ast_store case. After fix, warm-cache
compiles of the previously-affected spec list (effect_handler_narrow,
effect_integration, effect_multi_arg_e, std_log_d7,
effect_milestone_c_integration, effect_milestone_d_integration,
std_parse_j2, plus any other spec sequence) emit zero QZ0603. Fixpoint
clean (2476 functions byte-identical), smokes pass.

**Downstream codegen bug also CLOSED 2026-05-03 (commit 26d827b7).** See
[`INCREMENTAL_VEC_PUSH_UNDEFINED_VALUE.md`](INCREMENTAL_VEC_PUSH_UNDEFINED_VALUE.md).
MIR-lower's `mir_lower_call` now applies a UFCS rewrite fallback for
un-rewritten cached-module ASTs (`is_ufcs == 1` flag, type via
`mir_infer_expr_type` extended for global vars + parameters + NODE_BINARY
arithmetic + StringBuilder/Int return-type tracking). 5-spec warm-cache
sequence emits zero `%push`/`%to_s`/`%append_char` undef loads.

The `--no-cache` / `rm -rf .quartz-cache` workaround is no longer needed.

## Mitigation (historical)

Pre-2026-05-03: delete `.quartz-cache/` before running QSpec suites that
use `assert_compile_*` from qspec/subprocess, or pass `--no-cache` to
subprocess_compile. No longer required.

## Symptom

Compiling certain specs produces QZ0603 warnings:
```
warning[QZ0603]: cannot resolve struct type for field access '.size', using offset 0
```
Followed by runtime `index out of bounds: index 0, size 0` when the compiled code executes.

## Reproduction

1. Fresh cache: `rm -rf .quartz-cache`
2. First compile of a simple qspec+subprocess spec: **zero warnings**
3. Second compile of a spec that uses `assert_compile_error("""...""")`: **QZ0603 fires 7× per site**

Minimal repro:
```quartz
# /tmp/narrow4.qz
import * from qspec
import * from qspec/subprocess

def main(): Int
  describe("test") do ->
    it("QZ0611 fires") do ->
      assert_compile_error("""
effect Foo
  def bar(x: Int): Void = operation
end

def main(): Int
  bar(42)
  return 0
end
""", "QZ0611")
    end
  end
  return qspec_main()
end
```

Behavior:
- First compile (fresh cache): OK
- Second compile: 7× QZ0603 warnings
- `--no-cache` on second compile: OK

## Diagnosis

The warning suppression mechanism (`mir_lower_set_suppress_warnings` in `self-hosted/backend/mir_lower.qz:74`) is meant to silence QZ0603 for cached modules that don't have str2 type annotations. The check:

```quartz
mir_lower_set_suppress_warnings(1 - _mir_should_lower(final_name))
```

`_mir_should_lower` returns 1 if the module is in the recompile set, 0 otherwise. So:
- Module in recompile set (fresh lower): suppress=0 → emit warnings (correct)
- Module cached (reused fragment): suppress=1 → silence warnings (correct)

The bug is likely one of:
1. The recompile set isn't being populated correctly for partial-cache scenarios.
2. The warning check fires BEFORE the suppress flag is set per-function.
3. The `_mir_infer_expr_type` call path (mir_lower.qz:1765) doesn't consult the cache for type info on field receivers.

Affected specs (as of 2026-04-22):
- effect_handler_narrow_spec
- effect_integration_spec
- effect_multi_arg_e_spec
- effect_milestone_c_integration_spec
- effect_milestone_d_integration_spec
- std_log_d7_spec
- std_parse_j2_spec
- Many others using `assert_compile_*` with triple-string bodies

## Not a Phase 5.1 regression

Confirmed same QZ0603 warnings fire on `quartz-pre-5.1.2-golden` for specs that don't have the `std/terminal` module-resolution issue. Phase 5.1 did not touch `mir_infer_expr_type` or the warning suppression mechanism.

## Unblocks if fixed

- ~8+ effect integration specs currently failing
- Confidence in incremental compilation correctness
- Could be gating std/parse / std/log dogfooding

## Suggested investigation path

1. Add tracing to `mir_lower.qz:1818` to log which function + which module is firing QZ0603.
2. Check if those functions are in the recompile set.
3. If yes: warning is correct (code genuinely loses type info).
4. If no: `mir_lower_set_suppress_warnings(1)` should have silenced it — check ordering/scope.
5. If the recompile set is wrongly populated: investigate `mir_lower_set_recompile()` callers.

## Workaround

Add `--no-cache` when running specs that trip this. QSpec subprocess runner could hard-code this.
