# `tui_layout_strip_styles_spec.qz` emits `@__lambda_42` undefined-symbol IR

**Filed:** 2026-05-06 (incidentally surfaced during v0.6.7 verification)
**Severity:** Low — single spec file fails to link; broader strip_styles
behavior is exercised by neighboring specs (`tui_truncate_styled_spec`
shares the same code path and is green).
**Repro frequency:** 100% — fails on the pre-v0.6.7 golden binary too,
so this is NOT a v0.6.7 regression.
**Owner:** unassigned

## Symptom

```
$ quartz spec/qspec/tui_layout_strip_styles_spec.qz | llc -filetype=obj
llc: error: use of undefined value '@__lambda_42'
  %v5 = ptrtoint i64 (i64)* @__lambda_42 to i64
```

The compiler emits a `ptrtoint @__lambda_42` reference but never emits
the function definition — LLVM verifier rejects.

## What we know

- Confirmed pre-existing under the v0.6.7-pre golden
  (`self-hosted/bin/backups/quartz-pre-tui-v0.6.7-golden`); also fails
  under the post-6.7 binary identically. No regression introduced by
  Phase 6.7.
- File contains 17 lambda / `do ->` / `fn` shapes; lambda 42 is
  somewhere mid-file. The number suggests this is the body-walker
  losing track of a specific lambda site, possibly under a UFCS or
  pattern-match wrapper that breaks the capture-walker's coverage.
- Sister spec `tui_truncate_styled_spec.qz` covers overlapping
  `strip_styles` / styled-string behavior and is green — production
  coverage is not lost while this is broken.

## What needs to ship

1. Identify which lambda in the spec is `__lambda_42`. Easiest path:
   trim the spec down by binary search until the bad reference
   disappears, then the most-recently-removed lambda is the trigger.
2. Determine whether the lambda body is genuinely lowered to MIR — the
   `__lambda_N` declaration goes into IR (so it must reach the
   declarations pass) but no body is emitted (so it's lost at MIR
   lowering or codegen-instr emission).
3. Likely candidate: a sister gap to the resolver-rewrite /
   capture-walker NODE_* coverage gaps already filed in memory
   (`feedback_resolver_rewrite_coverage_gap`,
   `feedback_capture_walker_coverage_gap`). Some new wrapper kind that
   contains a lambda body slot the body-emission pass doesn't descend
   into.

## Acceptance

- [ ] `quartz spec/qspec/tui_layout_strip_styles_spec.qz | llc` produces
  no undefined-symbol errors.
- [ ] Spec compiles, links, and the test count + assertions match the
  intent of the May 4 commit (`7100c6b4`).
- [ ] If a compiler bug is the cause, regression spec at
  `spec/qspec/<bug-name>_spec.qz` reproduces the trigger in 10 lines or
  fewer and passes after the fix.

## Status

- **Closed 2026-05-07** — by the prior session's
  `LAMBDA_CAPTURE_BODY_NOT_REWRITTEN_TO_ENV` fix (capture-walker
  NODE_ENUM_ACCESS hole, closed 2026-05-06 per
  `feedback_capture_walker_coverage_gap`). The bug doc was filed
  the same day and never got moved to done/ once the sister fix
  landed.

## Verification

`spec/qspec/tui_layout_strip_styles_spec.qz` compiles, links, and
runs cleanly on every binary from `quartz-pre-tui-v0.6.7-golden`
forward — 12 tests, all green. No `__lambda_42` undefined IR. The
sister-fix's NODE_ENUM_ACCESS coverage in the body-emit walker
correctly descended into the lambda site that previously got
declaration-without-body emission.

## Related memory entries

- `feedback_resolver_rewrite_coverage_gap` — sister coverage hole in
  `resolver.qz`'s prefix-rewrite walker.
- `feedback_capture_walker_coverage_gap` — sister coverage hole in
  `mir_collect_captures_walk` / `tc_collect_captures_walk`. The
  resolver / capture / body-emit walkers all dispatch by NODE_* kind
  with no-op default; new wrapper kinds need explicit cases in each.
  Closing this bug retroactively confirms that the body-emit walker
  inherits the same NODE_* case set, so a fix for one fixes the
  others.
