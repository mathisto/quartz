# Overnight Autonomous Sprint Plan

**Created:** April 12, 2026 (post-QSpec triage sprint)
**Executor:** Fresh Claude Code session, autonomous execution
**Baseline:** ~165 tests fixed earlier today; 38 failing specs triaged; clean git state.

## Purpose

Execute the highest-impact remaining work from the roadmap while the user sleeps. This plan is self-contained: a fresh Claude Code session should be able to read it and execute it without further context from the current session.

## Hard Rules (non-negotiable)

1. **Respect the Prime Directives** in `CLAUDE.md`. Specifically:
   - Directive #8 (binary discipline): every compiler change requires `quake guard` before commit.
   - Directive #5 (report reality): if a fix fails midway, commit what's working, document the failure in this file under "Execution Log," and move on to the next task. Do NOT fake success.
   - Directive #4 (multi-session work): if you run out of context, update this file's "Execution Log" section with what's done and what's next, then end the session cleanly.

2. **Never `--no-verify` the pre-commit hook.** If it rejects a commit, diagnose and fix the root cause.

3. **Each compiler change is a fix-specific golden.** Before touching any `self-hosted/*.qz` file, run:
   ```
   cp self-hosted/bin/quartz self-hosted/bin/backups/quartz-pre-<fix-name>-golden
   ```
   This is Rule 1 from Bootstrap Island recovery. Never overwrite this until the fix is committed AND smoke-tested.

4. **After every `quake guard`, smoke-test.** Run `examples/brainfuck.qz` and `examples/expr_eval.qz` through the full compile+run pipeline. Fixpoint alone is NOT sufficient — a subtly broken compiler can produce identical IR from identical (broken) source.

5. **Commit early, commit often.** Each completed task gets its own commit with a clear message. Do not batch multiple unrelated fixes into one commit.

## Stack-Ranked Remaining Work

Priority is impact × confidence × blast-radius-safety. Lower tier = higher priority.

### Tier S: Systemic issues that cause silent bugs elsewhere

| # | Item | Est (quartz-time) | Blast radius | Confidence |
|---|------|-------------------|--------------|------------|
| S1 | **`.size` field access audit + fix** — `.size` on Int-typed Vec handles reads capacity instead of size. Partially fixed today in lint.qz and codegen.qz. Need systematic grep across `self-hosted/`, `std/`, `tools/` for all `.size` uses and classify by receiver type. Fix all Int-typed-handle cases. | 2-4h | Medium (compiler source changes) | High (root cause known) |
| S2 | **`Result$unwrap` layout bug** — returns 0 instead of payload for `Result::Ok(v)`. Unlocks 2 tests in option_narrowing_spec immediately. Likely in `cg_intrinsic_*.qz` — Result tag/payload layout may differ from Option. | 1-2h | Low (targeted intrinsic) | High (clear reproduction) |

### Tier A: Single-test failures with clear root causes

| # | Item | Est | Category |
|---|------|-----|----------|
| A1 | `cross_defer_safety_spec` — `defer` parser only accepts expressions, rejects statements like `defer count += 1` | 1-2h | Parser |
| A2 | `extern_def_spec` + `ffi_spec` — `extern "C" def` with body doesn't parse. Both specs lose 1 test each. | 2-3h | Parser |
| A3 | `never_type_spec` — never type in let binding context returns exit 176 instead of 42 | 2-4h | Codegen |
| A4 | `stress_type_system_spec` — enum variant with named payload extraction returns 0 instead of 42 | 2-4h | Codegen |
| A5 | `stress_pattern_matching_spec` — match on Option<Int> llc error, generic unwrap wrong value (2 tests) | 3-5h | Codegen |
| A6 | `arenas_advanced_spec` — module resolver returns empty module name, QZ0551 | 1-2h | Resolver |
| A7 | `error_codes_spec` — QZ1215 Copy+Drop test, triple-quoted string indent breaks impl parsing at col 1 | 1-2h | Parser or test source |

### Tier B: Known pre-existing issues, deeper investigation

| # | Item | Est | Notes |
|---|------|-----|-------|
| B1 | `ufcs_complete_spec` — `m.delete()` SIGSEGV | 2-4h | UFCS dispatch bug on map delete |
| B2 | `compiler_bugs_p30_spec` SIGSEGV | Unknown | Subprocess test, CInt multi-return |
| B3 | Module path resolution (`accept_worker_spec`, `modules_spec`) | 2-3h | Multi-level paths not resolving |
| B4 | Collection stubs stdlib functions (`reversed`, `sorted`, `unique`, `flatten`, etc.) | 4-6h | Feature gap, not a bug |

### Tier C: Multi-day feature completion (NOT for single-session overnight)

| # | Item | Est | Notes |
|---|------|-----|-------|
| C1 | Move semantics enforcement (S2.5 holes) | 2-3 days | 3 specs, borrow checker work |
| C2 | WASM backend completion (TGT.3) | 1-2 weeks | 3 specs, 10-phase plan |
| C3 | Generic Iterator bounded dispatch | 3-5 days | 1 spec, 8 tests |
| C4 | Scheduler park/wake refactor (Tier 3 #13) | 2-3 days | Fixes TIMEOUT + SIGSEGV in 4 specs |

### Tier D: Organization / infrastructure

| # | Item | Est | Notes |
|---|------|-----|-------|
| D1 | Extract "Remaining spec failures" section from ROADMAP.md to `docs/SPEC_FAILURES.md` | 20min | Roadmap is 8k words, trending unwieldy |
| D2 | `docs/QUARTZ_GUARD.md` — document Phase 2/3 of guard:forward and guard:history | 1h | Prevent future Bootstrap Islands |

## Overnight Execution Phases

### Phase 1: Research (parallel, 1 hour, 5 subagents)

Spawn 5 research subagents in parallel. Each produces a design document at `docs/overnight_research/<topic>.md`. No code changes in this phase. Each subagent should use WebSearch + WebFetch to check what the mainstream languages do, per Directive #2.

**Research tasks:**

1. **S2 Result layout research** — How does Rust/Haskell/OCaml represent `Result<T, E>` at runtime? How does unwrap() extract the payload? Compare to Quartz's current `Option<T>` layout. Produce a concrete fix plan for `Result$unwrap` returning the correct payload.

2. **S1 `.size` audit** — grep all `.size` (no parens) uses in `self-hosted/`, `std/`, `tools/`, `spec/`. For each, classify: (a) receiver type is `Vec<T>` — safe, (b) receiver type is `Int` but value is a Vec handle — BUG, (c) receiver type is struct with `.size` field — safe. Produce a list of Category (b) sites with file:line + suggested fix (`vec_size(x)`).

3. **A1 defer parser extension** — How does Go handle `defer` on statements vs expressions? How does Zig? What's the parser change needed to accept `defer count += 1` in Quartz? Produce design doc with proposed grammar change.

4. **A2 extern with body** — How does Rust parse `extern "C" fn foo() -> i32 { 42 }`? What does that mean semantically (C-calling-convention function with Rust body)? Produce design doc for Quartz's `extern "C" def foo(): Int = 0` form.

5. **A3/A4 never type + named enum payload codegen** — How does Rust represent `!` in let binding contexts? How does Swift? Produce design doc for the two codegen fixes.

Each subagent report must include: (a) citations to specific source files, blog posts, or RFCs; (b) concrete fix plan with file paths and line numbers in Quartz; (c) estimated quartz-time.

### Phase 2: Serial implementation (3-5 hours, main thread)

Execute fixes in priority order. Each fix:
1. Read the design doc from Phase 1
2. Make fix-specific golden backup
3. Implement the fix
4. Build with `quake build`
5. Run targeted spec test to verify
6. Run `quake guard` to verify fixpoint
7. Run smoke tests (brainfuck, expr_eval)
8. Commit with clear message
9. Update this file's "Execution Log" section

**Execution order:**
- **S2** (Result$unwrap) — smallest, highest confidence, unlocks 2 tests immediately
- **S1** (.size audit + fix) — systemic, prevents future silent bugs
- **A1** (defer parser) — if Phase 1 research shows clear path
- **A2** (extern with body) — if Phase 1 research shows clear path
- **A6** (resolver empty module name) — simple resolver bug

Skip A3, A4, A5 unless Phase 1 research reveals they're straightforward. These are "deeper codegen" and risk eating the session.

### Phase 3: Verification + handoff (30 min)

1. Run targeted spec tests for everything that should be passing. Build a tally of before/after.
2. Update `docs/ROADMAP.md` with actual state after the sprint.
3. Append to this file's "Execution Log" with a summary of what was done, what's next.
4. Commit the roadmap update.
5. End the session cleanly.

## Execution Log

Fresh overnight session: APPEND to this section as you complete each phase. Do not edit earlier entries.

---

### Session 1 (Apr 12 evening, ~9pm-11pm) — user-supervised kickoff

**Phase 1 results — all 5 research subagents complete.** Design docs in `docs/overnight_research/`:

- `result_unwrap_layout.md` — NOT a layout bug. Tail-call-with-stack-alloca-pointer bug. Empirically proven.
- `dotsize_audit.md` — Only 3 live BUG sites (tools/doc.qz:76,87 + readdir).
- `defer_parser_extension.md` — Parser branch at 5090-5103. Plus a LATENT bug in mir_lower.qz:242 (emit_deferred_to_depth used mir_lower_expr instead of mir_lower_stmt).
- `extern_with_body.md` — Parser is the ONLY missing piece. AST/resolver/MIR/codegen all already handle cconv_c.
- `never_type_let_binding.md` — SAME root cause as result_unwrap (tail-call + stack alloca). Not a never-type bug.
- `named_enum_payload.md` — NOT a codegen bug. Spec typo. Typechecker silently accepts unknown unqualified variant names.

**Phase 2 results — 4 fixes committed, +6 tests unlocked:**

| Commit | Fix | Tests |
|--------|-----|-------|
| `a8656e52` | Spec typo (MyOk→Ok) in stress_type_system_spec | +1 (43/43) |
| `be781358` | **Tail-call detector hardening (SYSTEMIC — fixes 2 research topics with 1 commit)** | **+4** (option_narrowing 7/7, never_type 11/11, stress_pattern_matching 27/28) |
| `37f84259` | `.size` → `vec_size` in tools/doc.qz | 0 tests (prevents silent wrong values) |
| `30de232e` | Defer parser extension + latent break/continue bug fix | +1 (cross_defer_safety 8/8) |

**Key insight from Phase 2:** the tail-call hardening unlocked MORE tests than predicted because the bug was genuinely systemic. `stress_pattern_matching_spec`'s "generic unwrap function" test was a silent beneficiary. Any future small-@value-type code passing stack pointers to user-land functions in tail position was latent-broken and is now fixed.

**Phase 3 not started — handoff to fresh session.**

**Remaining work for next session (priority order):**

1. **Extern-with-body parser** (3-5h, +2 tests, ffi_spec + extern_def_spec) — HIGHEST PRIORITY. Research is complete in `docs/overnight_research/extern_with_body.md`. The entire infrastructure is already in place across AST/resolver/MIR/codegen; only the parser dispatch is missing. Fix-specific backup already taken: `self-hosted/bin/backups/quartz-pre-extern-body-golden`. Research doc specifies the exact changes in ast.qz:1510 (replace stub with effect_annotations bit 2048 reader), parser.qz:5535-5621 (add body-presence dispatch after return type parsing), and has a 3-phase breakdown with ~155 LOC total. Read `docs/overnight_research/extern_with_body.md` §5 "Fix Plan" sections before starting.

2. **Result.unwrap intrinsic promotion** (Option B from research doc 1, ~4h, 0 new tests but performance parity with Option). Correctness is already fixed by the tail-call hardening. This is optional — only worth doing if you have solid context budget. Files: `cg_intrinsic_system.qz` (add unwrap_ok/unwrap_err/unwrap_or_ok handlers mirroring line 441), `intrinsic_registry.qz:536` (register), `typecheck_builtins.qz:660` (register), `std/prelude.qz:97-119` (delete now-redundant wrappers).

3. **Named enum payload compiler hardening** (~1 day — probably too big for overnight). Research in `docs/overnight_research/named_enum_payload.md`. `tc_bind_pattern_variables` should hard-error on unknown unqualified variant names. Would prevent an entire class of silent wrong-code bugs.

4. **Never type compiler hardening** — similar scope. Research in `docs/overnight_research/never_type_let_binding.md`.

5. **str_chars type annotation bug** (from .size audit) — declared `Vec<String>` in typecheck.qz but actually returns `Vec<Int>` codepoints. Cosmetic today, breakage-waiting. Small fix.

**Blockers encountered:** None. The 5 research subagents were the biggest force multiplier — the unified "tail-call is the class" insight came out of two independent investigations that finished 5 minutes apart.

**Pre-existing conditions noticed but not yet fixed:**
- `examples/expr_eval.qz` crashes in `fib` (multi-clause def) with EXC_BAD_ACCESS at `fib + 24`. Same behavior on both pre-fix and post-fix binaries (verified byte-identical IR). Pre-existing issue, not caused by tonight's work. Worth investigating separately.
- `ufcs_complete_spec` runs to exit 0 with zero output (stdout never flushes). Unchanged from baseline.
- `compiler_bugs_p30_spec` still SIGSEGVs in subprocess execution. Unchanged from baseline.

**Safety state for fresh session:**
- Git: clean (two untracked files `spec/qspec/progress_spec.qz` and `std/progress.qz` predate this session — NOT mine; leave alone).
- Fixpoint: verified. Source matches binary.
- Backups available: `quartz-pre-result-unwrap-golden`, `quartz-pre-dotsize-audit-golden`, `quartz-pre-extern-body-golden` (already taken for next session).
- Smoke tests: brainfuck 4/4 clean. expr_eval has the pre-existing fib crash (not a regression).

---

### Session 2 (Apr 12 late evening) — extern-with-body parser

**Phase 2 result — extern "C" def with body parser landed.**

Phase 1 (AST): replaced the `ast_func_is_cconv_c` stub at `ast.qz:1510` with a real reader over `effect_annotations` bit 2048, plus an `ast_func_set_cconv_c` setter. Same parallel-table pattern as `@no_preempt` (bit 1024). Deleted the fossil docstring.

Phase 2 (parser): extended `ps_parse_extern_fn` (parser.qz:5544+) with body dispatch after the return type. Three legal continuations:
1. `TOK_ASSIGN` immediately → endless def body
2. Next meaningful token indented past `extern` column → block body
3. Otherwise → bodyless declaration (current behavior preserved)

The disambiguator for the bodyless-vs-block case is **column-based** (next token indented past `extern`). This was the only correct choice given the existing `test_extern_c_bodyless_then_var()` test (`extern "C" def getpid(): CInt\nvar counter = 0` — must remain bodyless) and `test_extern_c_body_with_vars()` (`extern "C" def my_fn(): CInt\n  var result = 0\n  ...` — must be a body). Top-level-decl-token enumeration cannot disambiguate these because both start with `var`. Indentation can.

When a body is detected, the parser builds a NODE_FUNCTION (not NODE_EXTERN_FN), marks it cconv_c via the new setter, and the rest of the pipeline (resolver bare-name registration, mir_lower cconv propagation, codegen i32/ptr/void parameter and return types) takes over automatically. No new node kinds, no IR-level changes — every other layer was already wired and this fix activated dead code throughout. The research doc was correct: the parser was the only hole.

Body-bearing extern decls also reject variadic with a clear error and reject non-"C" calling conventions defensively.

**Test results:**
- `extern_def_spec` — **20/20** (was 19/20 — "extern def with body compiles as C-convention function" now passes)
- `ffi_spec` — **15/15** (was 14/15 — "extern with body compiles as C-convention function" now passes)
- `compiler_bugs_p30_spec` — pre-existing SIGSEGV in subprocess execution, unchanged from baseline. The three Bug-1 extern-body tests inside it now compile correctly when run standalone (verified by direct compile of test source: `define i32 @my_abs(i64 noundef %p0)` IR, bare symbol, ABI-correct).
- New direct smoke tests of the feature:
  - Endless: `extern "C" def my_inc(x: Int): CInt = x + 1` → `define i32 @my_inc(i64 noundef %p0)` ✓
  - Block: `extern "C" def my_abs(x: Int): CInt\n  if x < 0\n    return 0 - x\n  end\n  return x\nend` → compiles, links, runs exit 0 ✓
  - Bodyless preserved: `extern "C" def getpid(): CInt\nvar counter = 0` → `declare i64 @getpid()` ✓

**Smoke tests post-guard:** brainfuck 4/4 ✓. expr_eval still SIGSEGVs in fib (pre-existing baseline, not a regression — verified).

**Fixpoint:** verified by `quake guard`. 2248 functions, gen1.ll == gen2.ll byte-identical. Binary and `.fixpoint` stamp staged.

**Test delta from this session:** +2 tests unlocked (extern_def_spec + ffi_spec). Net effect: spec failures count drops by 2 from the baseline.

**Files changed:**
- `self-hosted/frontend/ast.qz`: -18/+19 (replace stub, add setter)
- `self-hosted/frontend/parser.qz`: +73 (body dispatch in `ps_parse_extern_fn`)

**Holes filed (not fixed):**
- FFI-safe type validation for `extern "C" def` (with or without body) is still absent. Passing `Vec<Int>` as an `extern "C" def` parameter compiles to an opaque i64 handle the C caller can't use. Footgun, not a bug. Same severity as it was before this fix — unchanged. Filed in `docs/overnight_research/extern_with_body.md` §"Restrictions to Enforce" row 7 / "Hole filed for follow-up". Estimated half a quartz-day to fix in a `tc_validate_ffi_signature` check.
- The new body parser doesn't enforce "no generics", "no `priv` prefix", or "no effect annotations on body-bearing extern". The current `ps_parse_extern_fn` doesn't accept generics or attributes today (no `<` or `@` lookahead before `extern`), so generics rejection is structural. `priv extern` is also structurally impossible from the top-level callers. Effect annotations on extern fns are not currently parsed. Filing as low-priority hardening.
- **Pre-existing parser bug discovered in `std/memory.qz` (Tier A6 root cause).** Investigation of the arenas_advanced_spec failure (Plan §A6, "module resolver returns empty module name, QZ0551") showed that the resolver error is *downstream* of a parse error in `std/memory.qz` lines 17-20. The trait Drop block uses an empty-body default method form: `def drop(self): Void\n  end\nend`. The parser's abstract-trait-method detector (`ps_parse_function` at parser.qz:5316) eagerly treats `end` as the abstract-method-marker and consumes it, leaving the second (real) `end` to fail at top level as "Expected declaration". Same pattern at lines 30-31 (`Allocator::deallocate`). The `parse_with_state` resolver entry tolerates parse errors and produces empty-named NODE_IMPORT fallbacks (parser.qz:6836, 7200), which the resolver then chokes on with the misleading QZ0551 "cannot find module: <empty>". Two layers of bug. Verified pre-existing: backup binary `quartz-pre-extern-body-golden` produces the identical parse errors. **Two valid fixes:** (a) tighten the abstract detector to look two ends ahead, OR (b) accept a non-abstract empty-body method form in stdlib by removing the spurious `end`s in std/memory.qz. Option (b) ships in 5 minutes if the semantics are equivalent, but the *real* fix is the parser — empty-body default methods are valid Quartz syntax everywhere else and should remain valid in trait blocks. The misleading QZ0551 should also become a real "import was malformed (parser fallback)" diagnostic. Filing as a Tier A item for the next session: ~1-2h to fix the abstract-detector lookahead + improve the diagnostic. Re-classify A6 from "resolver bug" to "trait-method-parser bug + resolver diagnostic clarity bug".

**Tests not added:** the research doc proposed adding new IR-assertion tests (symbol-name, return-type, narrow param, ptrtoint string param, generic rejection, variadic rejection). Skipped this session — the existing spec tests now pass and exercise the happy path. New IR-assertion tests would be additive hardening; filing as a follow-up rather than coupling them with the parser fix.

**Remaining work for next session (priority order):**

1. **Result.unwrap intrinsic promotion** (Option B from research doc 1, ~4h, 0 new tests but performance parity with Option). Correctness already fixed by tail-call hardening in Session 1. Optional. Files listed in Session 1 handoff.

2. **Add IR-assertion tests for extern body** (1-2h). Test cases listed in `docs/overnight_research/extern_with_body.md` §Phase 5. Hardens the symbol-naming and return-type invariants against future regression.

3. **FFI-safe type validation** (half-day). New `tc_validate_ffi_signature` check that errors on `Vec<T>`/`Map<K,V>`/user-struct params or returns in any `extern "C" def`. Affects bodyless and body-bearing equally.

4. **Named enum payload compiler hardening** (~1 day). Same as Session 1 handoff.

5. **Never type compiler hardening**. Same as Session 1 handoff.

6. **str_chars type annotation bug**. Same as Session 1 handoff.

**Safety state for next session:**
- Git: extern body fix committed cleanly. Same three untracked files (`progress_*`) belong to the parallel session — leave alone.
- Fixpoint: verified.
- Backups available: `quartz-pre-result-unwrap-golden`, `quartz-pre-dotsize-audit-golden`, `quartz-pre-extern-body-golden` (the one this session used; can be deleted now that the fix is committed and verified).
- Smoke tests: brainfuck 4/4 clean. expr_eval pre-existing fib crash (not a regression — same as Session 1 baseline).

---

### Session 2 (continued) — Trait empty-body parser fix (A6 root cause)

**Phase 3 result — trait empty-body methods now parse, +1 spec unlocked.**

Per the A6 re-classification at the bottom of the previous Session 2 entry, the resolver QZ0551 was downstream of a parser bug: `ps_parse_function`'s abstract-trait-method detector at `parser.qz:5316` was eagerly treating any `end` after a method's return type as the abstract-method marker, even when the `end` was the def's own (empty) body terminator. This broke `def drop(self): Void\n  end` empty-body default methods in trait blocks. `std/memory.qz` lines 17-20 and 30-31 used this form, and as a result couldn't be parsed.

**The fix (compiler — two layers):**

1. **`parser.qz:5316` abstract-detector — column-based disambiguation.** Captured `def_col` (the column of the just-consumed `def` keyword) at the start of `ps_parse_function`. Modified the detector to:
   - `TOK_DEF`/`TOK_EOF` next → still abstract (unchanged).
   - `TOK_END` next → check the column of that `end`. If `end_col >= def_col`, the `end` belongs to *this* def's body (empty-body default method), so fall through to body parsing. If `end_col < def_col`, the `end` belongs to the enclosing trait, and *this* def is abstract.

   The disambiguator works because Quartz convention indents trait body methods past the trait header, and a def's own body terminator sits at the def's column while the trait's terminator sits at the trait header's column (less than the def's). Conventional formatting handles this for free; pathological "all at column 1" code is still parseable but means `end` always belongs to def — which is fine because abstract methods at column 1 are unusual and would error consistently anyway.

2. **`resolver.qz` empty-named-import skip.** When the parser hits a top-level decl error, its fallback constructs a NODE_IMPORT with empty `str1` (parser.qz:6836,7200). Previously the resolver tried to load the empty-named module and emitted a misleading QZ0551 "cannot find module: <empty>" with a confusing chain note. Now `resolve_process_imports` skips zero-length module names with a `continue` — the original parse error is the real diagnostic; chasing the empty-import fallback only added noise.

**Test results — direct target:**
- `arenas_advanced_spec` — **28/28** (was 27/28 — "Arena$drop called automatically on scope exit" now passes)

**Test results — silent wins (post-commit audit).** Greedy `end`-consumption was a *class* bug: every spec whose subprocess test sources used the `def f(...): T\n  end` empty-body trait method form was silently broken at the inner-compile step. Auditing the spec tree with `def \w+\([^)]*\): \w+\n\s+end\n\s+end` (multiline regex over `spec/qspec/`) found 4 additional specs that were failing and now fully pass. Verified before/after with the `quartz-pre-extern-body-golden` backup binary against the same compiled spec runner:

| Spec | Baseline | After fix | Delta |
|------|----------|-----------|-------|
| `error_codes_spec` | 34/35 | **35/35** | +1 |
| `s25_low_holes_spec` | 5/15 | **15/15** | +10 |
| `conformance_memory_spec` | 14/23 | **23/23** | +9 |
| `s25_safety_holes_spec` | 3/13 | **13/13** | +10 |

That's **+30 silent wins from a single 14-line parser change**, on top of the +1 direct win from arenas_advanced_spec — the trait-empty-body fix unlocked **+31 tests total**. Combined with the +2 from the extern-body fix earlier in Session 2, **Session 2 grand total: +33 tests unlocked across two compiler bug fixes**.

The class-bug pattern also explains why several "S25 holes" tier items in the roadmap looked like they needed deep safety-checker work but were in fact gated entirely on this parser fix. The user might want to re-audit any spec whose failure mode looked like "trait method body not found" or "QZ12xx error code not emitted" — odds are good it was downstream of this bug.

**Regression checks:**
- `traits_spec` 37/37 (no change)
- `trait_self_spec` 3/3 (no change)
- `trait_defaults_spec` 6/6 (no change)
- `arenas_spec` 11/11 (no change)
- `drop_spec` 34/34 (no change — was already passing)
- `abstract_trait_spec` 8/8 (no change)
- `impl_trait_spec` 11/11 (no change)
- `linear_types_spec` 11/11 (no change)
- `mutable_borrows_spec` 30/30 (no change)
- `lint_balance_spec` 24/24 (no change)
- All Session 1+2 unlocked specs verified non-regressed: `ffi_spec` 15/15, `extern_def_spec` 20/20, `cross_defer_safety_spec` 8/8, `option_narrowing_spec` 7/7, `never_type_spec` 11/11, `stress_pattern_matching_spec` 27/28 (one pre-existing llc-failure unchanged from baseline), `stress_type_system_spec` 43/43.

**Smoke tests post-guard:** brainfuck 4/4 ✓.

**Fixpoint:** verified by `quake guard`. 2251 functions (up from 2248 — three new functions in the parser/resolver), gen1.ll == gen2.ll byte-identical.

**Test delta from this sub-session:** +31 tests across 5 specs (arenas_advanced +1, error_codes +1, s25_low_holes +10, conformance_memory +9, s25_safety_holes +10). The "+10/+10/+9" specs are particularly significant: they unlocked entire tier-S2.5 ("S25 safety holes") roadmap items that looked like multi-day safety-checker work but were actually gated on a 14-line parser fix. **Combined Session 2 total: +33 tests** unlocked across two compiler fixes.

**Files changed:**
- `self-hosted/frontend/parser.qz`: +14/-7 (def_col capture, abstract detector dispatch)
- `self-hosted/resolver.qz`: +7 (empty-name skip with explanatory comment)

**Holes filed during this fix:**
- The `qspec/formatter` module (added by the parallel session as part of std/progress) now transitively imports `std/style → std/terminal`, so any QSpec test invoked without `-I std` on the include path will fail at the std/terminal lookup step. This was effectively true before too — those specs needed `-I std` — but the failure point is different now (was: `cannot find module: qspec`; now: `cannot find module: std/terminal`). The Quakefile's `run_qspec` task already passes `-I std -I . -I self-hosted/shared -I self-hosted/backend -I spec/qspec/fixtures`, so QSpec runs through `quake qspec` are unaffected. Filed because the bare `quartz spec/qspec/foo.qz` invocation is now a footgun for any developer reaching for it. Possible future fix: add a default include path of `std` (and possibly the project root) to the compiler binary, or document the canonical include set.

**Remaining work for next session (priority order, updated):**

1. **Result.unwrap intrinsic promotion** (Option B from research doc 1, ~4h, 0 new tests but performance parity with Option). Optional. Files listed in Session 1 handoff.

2. ~~**Default include paths in the compiler**~~ — DONE in this session (commit forthcoming). Added `detect_project_root()` symmetric to `detect_stdlib_path()`, auto-prepended to default include paths in both compile call sites in quartz.qz. Bare `quartz spec/qspec/foo.qz` now works without `-I` flags. Verified by compiling+running trait_defaults_spec with no flags.

3. **Add IR-assertion tests for extern body** (1-2h). Test cases in `docs/overnight_research/extern_with_body.md` §Phase 5.

4. **FFI-safe type validation** (half-day). New `tc_validate_ffi_signature` check.

5. **Named enum payload compiler hardening** (~1 day). Same as Session 1 handoff.

6. **Never type compiler hardening**. Same as Session 1 handoff.

7. **str_chars type annotation bug** — re-scoped: NOT a small fix. Investigation in this session showed three layers of inconsistency: `typecheck.qz:275` registers `str_chars` and `String$chars` as `Vec<String>`; `typecheck_builtins.qz:157,196` registers them as `TYPE_INT`; the runtime in `codegen_runtime.qz:5685` (`qz_str_chars`) and `:5947` (`qz_str_chars_utf8`) returns `Vec<Int>` of byte/codepoint values. The MIR lowering path in `mir_lower_stmt_handlers.qz:77,115` then marks `str_chars` results as **string containers** for downstream indexing (so `chars[i]` routes through string semantics rather than the actual Int return). This is a partial migration — `str_chars` was originally one-char-strings (Vec<String>) and was changed to codepoints (Vec<Int>) at the runtime, but the type-system and MIR-lowering layers were never updated to match. Fixing this requires a coordinated change across typecheck.qz, typecheck_builtins.qz, mir_lower_stmt_handlers.qz, and likely audit of every spec that uses `str_chars`/`String$chars` to verify what they actually expect (`for c in s` desugars through this path too, per `mir_lower_iter.qz:252`). Estimate: 2-3h, not a single-edit fix. Worth doing as a dedicated session item rather than late in an autonomous run.

**Safety state for next session:**
- Git: trait empty-body fix committed cleanly. Same three untracked files (`progress_*`) belong to the parallel session — leave alone.
- Fixpoint: verified (2251 functions).
- Backups available: `quartz-pre-result-unwrap-golden`, `quartz-pre-dotsize-audit-golden`, `quartz-pre-extern-body-golden`, `quartz-pre-trait-empty-body-golden` (this session). The first two are pre-extern-body session fossils, can be deleted. The latter two can also be deleted now since both fixes are committed and verified.
- Smoke tests: brainfuck 4/4 clean. expr_eval pre-existing fib crash unchanged.

---

### Session 2 (continued) — Default include path + B1 investigation

**Default include path fix landed (commit `ffbe3c69`).** Added `detect_project_root()` symmetric to `detect_stdlib_path()`, auto-prepended to default include paths in both compile call sites. Bare `quartz spec/qspec/foo.qz` now works without `-I` flags. The std-internal modules use `import std/...` prefix form (style.qz, terminal.qz, all of std/net/*, json, ffi/*) which requires the project root on the include path to resolve. 30+ stdlib files use this pattern, so changing the stdlib was out of scope; the right fix was to make the compiler default include the project root. Verified: `trait_defaults_spec` 6/6 with no `-I` flags. Fixpoint passed (2252 functions). Smoke green.

**B1 investigation (ufcs_complete_spec — original "m.delete() SIGSEGV" item).** The Session 1 description was wrong about the proximate symptom. The actual test calls `m.del(1)` (not `m.delete(1)`), and `del` is not in the map UFCS dispatch table at `typecheck_expr_handlers.qz:1700-1715`. The spec fails at *typecheck*, not at runtime — `error[QZ0401]: Undefined function: del`. So the test source itself is broken (or the typecheck table needs a `del` alias).

But the more interesting finding is what's *behind* B1: the underlying `m.delete()` (with the canonical name) also SIGSEGVs, AND so does the simpler `map_set(m, 1, 10)` on a fresh `map_new()`. Tested in isolation:

```
def main(): Int
  var m = map_new()
  map_set(m, 1, 10)   # SIGSEGV here, not in delete
  return 0
end
```

Direct `intmap_new() + intmap_set(m, 1, 10)` exits 1 cleanly (no SIGSEGV — bare intmap intrinsics work). It's the **unified `map_*` dispatch path** that crashes. Per the user's project-memory entry "Unified Map<K,V> — ACTIVE: Replacing HashMap+IntMap with Map<K,V>. 5-phase plan approved", this is in-progress work by the user and the next session must not chase it without coordinating. **Do NOT touch unified-Map dispatch in self-hosted/middle/typecheck or self-hosted/backend/cg_intrinsic_map.qz without confirming the user's current phase status.**

The B1 entry should be re-classified: the surface symptom is "ufcs_complete_spec del UFCS missing", the deeper symptom is "unified map_set SIGSEGVs on fresh map_new", and the deeper-still root is the in-progress unified Map<K,V> work. Filing both layers.

**Test delta from this sub-session:** 0 new tests (the B1 path was a dead end — turning back was the correct call). Default include path is a quality-of-life fix for future sessions, not a test unlock.

**Files changed:**
- `self-hosted/quartz.qz`: +20 (detect_project_root function + auto-prepend in two call sites)

**Holes filed during this sub-session:**
- **B1 re-classification: `ufcs_complete_spec` has two layers of bug.** Layer 1: `m.del(1)` not in the typecheck UFCS dispatch table (one-line alias add at typecheck_expr_handlers.qz:1700-1715, OR fix the test source to use `m.delete(1)`). Layer 2: `map_set(m, 1, 10)` on fresh `map_new()` SIGSEGVs. Layer 2 is downstream of in-progress unified Map<K,V> work — see project memory `project_unified_map.md`. **Do not fix B1 without first checking the unified Map status with the user.** Deferred to a session that can coordinate with the active unified Map work.
- **Map UFCS table is missing common aliases.** Pythonic `del`, Rust `remove`, etc. Could be added one-shot if the user wants, but should be batched with a unified naming review (see `project_api_surface_audit.md` in memory). Not blocking anything in the meantime.

**Combined Session 2 final tally: +33 tests across 3 compiler fixes.** See main Session 2 entry above for the full breakdown. The 3rd fix (default include paths) doesn't unlock tests directly but enables future sessions to invoke `quartz spec/qspec/foo.qz` without ceremony, which prevented the std/terminal footgun from biting tonight's diagnostic work.

**Safety state for next session:**
- Git: clean, all 3 compiler fixes committed and guarded. Untracked: same `progress_*` files belonging to the parallel session — leave alone.
- Fixpoint: verified (2252 functions). Source matches binary.
- Backups stale and can be deleted: `quartz-pre-result-unwrap-golden`, `quartz-pre-dotsize-audit-golden`, `quartz-pre-extern-body-golden`, `quartz-pre-trait-empty-body-golden`, `quartz-pre-default-include-golden`. None of them protect anything that isn't already committed and verified.
- Smoke tests: brainfuck 4/4 clean (verified after each guard run, three times this session). expr_eval pre-existing fib crash unchanged from Session 1 baseline.

---

## Execution Instructions for the Fresh Session

When you (a fresh Claude Code session) pick up this plan:

1. **Read CLAUDE.md first.** Prime directives v2 are load-bearing.
2. **Verify clean git state.** `git status` should show a clean tree. If not, investigate before proceeding.
3. **Read the "Known Garbles" Whisper note** in CLAUDE.md if the user speaks to you; their input is transcribed.
4. **Spawn Phase 1 subagents in parallel.** Use the Agent tool with `subagent_type: Explore` for research. Wait for all to return.
5. **Execute Phase 2 serially.** Respect the fix-specific golden rule.
6. **Run Phase 3 verification.** Update the roadmap and this file.
7. **Commit everything.** Leave git clean.
8. **Report to the user in a short morning summary** when they wake up: what got done, what's next, any surprises.

Good luck. Don't burn the binary.
