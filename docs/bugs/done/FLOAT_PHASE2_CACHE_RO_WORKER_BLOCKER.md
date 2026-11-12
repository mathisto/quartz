# qzmod cache ignored `--cache-dir` → cross-compile contamination dropped wildcard modules — RESOLVED

> **CLOSED-STALE 2026-07-07** — re-reproduced fixed on current binary; see docs/sagas/r24-groundwork-inert-holes-2026-07-07-research/ws2-triage.md (already ✅ in-doc; `f64_to_str` now pure-Quartz lib fn removed from `intrinsic_registry.qz`, `cache_smoke` guard task landed, follow-on compiler fixes present).

**Status:** ✅ FIXED (resolved 2026-06-02). Left in place — referenced by `docs/ROADMAP.md`.

**Filed:** 2026-06-02 (as a float Phase 2 blocker). **Resolved:** 2026-06-02.
**Severity:** High — blocked float→string Phase 2, and was the real root of the
long-filed cache-ro "shape 4 / DCE incompleteness / prefix-mangling" dangling-symbol
class (`feedback_cache_ro_cached_fragment_dce_incompleteness`,
`feedback_cache_ro_prefix_mangling_inconsistency`, `ab42cc67_overclaim`).

**Outcome:** Float Phase 2 landed AND the real cache contamination bug is fixed. The
terminal/socket dangling-symbol failures across ~800 specs are gone (a full cache-ro +
`llc` sweep went from 824 dangling to 2, and those 2 — plus all other residual failures
— are **pre-existing on golden**, i.e. zero regressions).

---

## Root cause: `qzmod_cache_root` hardcoded `.quartz-cache`, ignoring `--cache-dir`

`--cache-dir` redirects the build_cache (Tier-0/1/2 IR fragments, `whole_program.ll`,
`dep_graph.txt`). But the **qzmod cache** (cached per-module MIR bodies + type info,
the artifact the resolver/typecheck actually consume) is rooted by
`qzmod_format::qzmod_cache_root`, which returned `<project_root>/.quartz-cache`
**unconditionally** — it never saw `--cache-dir`. So qzmod always lived in
`.quartz-cache/<compiler_hash>/<module>/`, regardless of the flag.

Consequence: every compile shares one qzmod cache keyed only by compiler hash. After a
`quake build` populates `.quartz-cache` with the **compiler's own** modules' qzmod, a
later spec compile — even with `--cache-dir /tmp/x` or `.quartz-cache-qspec` — reads
qzmod entries out of that shared `.quartz-cache`. Stale/foreign entries cause
wildcard-imported modules (`terminal`, `socket` — and `time`, see residual below) to be
loaded incompletely, so their functions are absent from the program's MIR. Codegen then
emits calls (e.g. `@terminal$KEY_DELETE`, from a `terminal` async Future `$poll` body)
to definitions that were never compiled → `llc: use of undefined value`.

**Why it looked non-deterministic / "flaky":** the outcome is fully determined by
`.quartz-cache`'s contents at compile time. It looked random because intervening
`quake build` / `quake fixpoint` runs repopulate or clear `.quartz-cache` between test
runs — so the *same binary + same input* flipped good↔bad depending on whether
`.quartz-cache` was clean. `rm -rf .quartz-cache` → reliably good; `.quartz-cache`
present (post-build) → reliably bad. This is what produced three earlier wrong
diagnoses: persistent-worker (handoff — not on the default `qspec` path; daemon is
opt-in via `QSPEC_DAEMON=1`), "bootstrap convergence transient," and
"alias-unaware/full-surface codegen reachability" (both mine — addressed symptoms, not
the root; reverted).

`--no-cache` was always clean because it bypasses qzmod entirely.

## The fix

Thread the active `--cache-dir` to qzmod so its cache root matches build_cache:

- `qzmod_format.qz`: new process-global `_g_qzmod_active_cache_dir` + setter
  `qzmod_active_cache_dir_set`. `qzmod_cache_root` now returns that dir when set,
  falling back to the historical `<project_root>/.quartz-cache` only when unset.
- `quartz.qz` `compile()`: `qzmod_active_cache_dir_set(build_cache::cache_get_dir())`
  alongside the existing `qzmod_active_flags_set` (cache_get_dir() is `""` under
  `--no-cache`, where qzmod is unused; else the active `--cache-dir`).

`quake build` uses the default `.quartz-cache`, so the fix is a no-op there
(fixpoint/guard unaffected). It only isolates non-default `--cache-dir` invocations —
which is exactly the per-worker isolation the `--cache-dir` flag's help text promises.

Verified: terminal/socket reliably present — 10/10 identical prewarm+spec cycles **with
`.quartz-cache` present** (the previously-100%-bad trigger) and absent; full-suite
cache-ro+llc sweep 824→2 dangling (both residual + all other failures identical on
golden); float specs + abstract_trait/colors/option_result pass end-to-end via cache-ro;
fixpoint (2609) green across 3 generations; smoke green.

---

## Residual `@time$time_epoch_ms` — RESOLVED 2026-06-02 (distinct root cause)

**Fixed.** The `time` residual was NOT another `--cache-dir` contamination path — it was
a genuine codegen-emission miss in the cached-MIR injection pass, distinct from the
qzmod-dir bug above.

**Root cause (empirical):** `mir_lower.qz` PASS 0.999 (INC.1.3) merges each `.qzmod`
hit's cached MIR bodies onto `prog.functions`, but skips any body whose mangled name
(`time$time_epoch_ms`) collides with an `all_funcs` entry from a DIFFERENT `ast_store`
("shadowed_by_local"). That guard exists to avoid double-defining a function the
consumer locally `def`s over a wildcard import. But the dep-graph allocates a SEPARATE
`ast_store` per import-path alias, and a single source can be reached by two alias nodes
(`std/time` imported directly by the spec AND transitively via `progress`). Both alias
nodes register `time`'s module-qualified funcs into `all_funcs` under distinct
ast_stores. The shadow check saw the OTHER alias's entry, declared a (false) shadow, and
skipped the cached body — and PASS 1 ALSO skipped it (its ast_store's content_hash is in
`loaded_hashes`). So `time$time_epoch_ms` was emitted by NEITHER path → the call
dangled. `terminal`/`socket` were unaffected because they have a single import-path
alias; `time`'s dual-alias reachability is what tripped it.

**Empirical proof:** traced the shadow loop — the shadowing `all_funcs` entry's
ast_store maps (via `depgraph_name_for_ast_store`) to node `std/time`, content_hash
`5df2f97fa01f29f1`, IDENTICAL to the hit's content_hash. Same source, not a shadow.
no-cache emits 4 reachable `time$*` defines (llc clean); cache-ro emitted 0 (all 36
`SHADOWED`), with the calls retained → `llc: use of undefined value`.

**Fix:** `mir_lower.qz` — new helper `_mir_ast_store_content_hash(ast_store)`; the shadow
check now treats a different-ast_store entry as a shadow ONLY when its source
content_hash DIFFERS from the hit's (a genuine local shadow is a different source AND
always a bare name; a module-`$`-qualified cached body can never be bare-shadowed).
Same-source aliases load normally. Verified: both `https_spec` and `network_timeout_spec`
flip from dangling-on-golden to llc-clean (4 `time$*` defines each, matching no-cache);
full cache-ro+llc sweep 823 ok / 1 fail, the 1 (`random_effect_handlers_spec`) failing
IDENTICALLY on golden ("Instruction does not dominate all uses" — a separate pre-existing
SSA bug, not a dropped symbol); fixpoint 2610 ×2 byte-identical; smoke green.

## Other pre-existing residuals (unrelated, filed forward)

- `arenas_spec` / `arenas_advanced_spec` (QZ1401 arena borrow-check),
  `bool_narrowing_spec` (QZ0220 undefined type `Float`), `random_effect_handlers_spec`
  (`opt`/llc "Instruction does not dominate all uses" SSA reject) — all pre-existing on
  golden, unrelated to this work.

## Guard cache-mode blind spot — CLOSED 2026-06-02

`quake guard` / `quake fixpoint` verified `gen1.ll == gen2.ll` built `--no-opt
--no-cache` only — they never exercised the qzmod/cache-enabled path, so a qzmod
contamination regression would pass guard. **Hardened:** added `cache_ro_smoke_run()` /
`cache_ro_smoke()` to `Quakefile.qz` and a standalone `quake cache_smoke` task. The step
prewarms a tiny targeted cache (just the qspec framework's transitive module set),
`--cache-ro`-compiles `network_timeout_spec` + `https_spec` (which exercise the
`std/time` dual-alias path plus tcp/tls/socket wildcard modules), and `llc
-filetype=obj`'s each — any dropped module symbol fails here. Wired into BOTH the
`fixpoint` task (post-fixpoint) and the `guard` task (final gate, restores+re-stages the
golden binary on failure). **Verified it catches contamination:** reverting the
mir_lower fix and rebuilding made `quake cache_smoke` exit 1 with the exact
`llc: use of undefined value '@time$time_epoch_ms'` (clean abort, not a crash); restoring
the fix makes it pass.

## Filed forward (new): `fail()` / `BuildError::AssertionFailed` throw segfaults

Discovered while wiring the smoke step: in the compiled `Quakefile` runtime,
`fail(msg)` → `fail_typed(BuildError::AssertionFailed(msg))` → `throw(...)` SEGFAULTs
(exit 139) instead of unwinding to the installed Throws handler — even with no prior
`Exec` op and no Live UI. `sh("false")` → `fail_typed(BuildError::CommandFailed(...))`
unwinds cleanly (exit 1, "✗ FAILED: …"). Reproduces on the golden (e6444d2b) binary too,
so it is PRE-EXISTING and orthogonal to this work. Both code paths call `throw` via
`fail_typed`; the only difference is the `BuildError` variant, so the bug is in
constructing/throwing/string-rendering the `AssertionFailed(String)` variant (vs the
`CommandFailed(String, Int)` variant that works). Workaround in the smoke step: abort via
`fail_typed(BuildError::CommandFailed(...))`. Needs its own investigation (likely a
single-field enum-variant boxing or `_build_error_to_string` issue in the throw path).

### RESOLVED 2026-06-03 — match-arm binding did not shadow same-named method

Root cause was NOT enum boxing and NOT the throw path. It was a name-resolution
bug in `_build_error_to_string`'s `match`: `mir_ctx_apply_pending_bind`
(`self-hosted/backend/mir.qz`) emitted a `STORE_VAR` for each enum-pattern payload
binding but never registered the name via `mir_ctx_bind_var`. So in the arm body,
`mir_ctx_lookup_var(name)` missed and the `NODE_IDENT` lowering fell through to the
function registry. For `AssertionFailed(msg) => msg`, the bareword `msg` resolved to
the free method `progress$Col$msg` and emitted `ptrtoint @progress$Col$msg`; for
`CommandFailed(cmd, code)` the interpolated `code` resolved to `error$IoError$code`.
The arm returned a FUNCTION POINTER where the `String` field was expected; the Quake
Throws handler (`_quake_throws_print_and_exit`) then ran `memmove`/`strlen` over that
bogus address → SEGFAULT. `CommandFailed` only "worked" because its garbage func-ptr
got `str_from_int`-formatted (wrong number, no deref) instead of stringified directly.

NOT BuildError-specific: this affects ANY enum-pattern binding whose name collides
with a free function/method in scope, across match-expr, match-stmt, `if PAT = expr`,
and `if x is V(field)` (all route through `mir_ctx_apply_pending_bind`). The `name`
on its own evaluated to a function value silently.

FIX: `mir_ctx_apply_pending_bind` now `mir_ctx_alloc_slot` + `mir_ctx_bind_var`s each
non-wildcard payload name before the `STORE_VAR`, mirroring the struct/vec destructure
paths. Pattern bindings now shadow same-named functions, as scoping requires.
Regression: `spec/qspec/match_binding_shadows_method_spec.qz` (2/2; FAILs 2/2 on the
pre-fix golden). Verified: `quake build:wasm` now unwinds to `✗ FAILED: Usage: …`
(exit 1) instead of 139. Fixpoint 2612 fns. The `CommandFailed`-instead-of-`fail()`
workarounds in `Quakefile.qz` are now unnecessary and can be reverted to `fail()`.

---

## The float Phase 2 edits that landed (for reference)

1. `std/prelude.qz`: `import * from std/fmt/float`.
2. `intrinsic_registry.qz`: removed `_r("f64_to_str", …)`.
3. `cg_intrinsic_string.qz`: removed the `f64_to_str` sprintf block.
4. `typecheck_builtins.qz`: removed `tc_register_builtin(tc, "f64_to_str", …)`.
5. `typecheck_expr_handlers.qz` (~3275): `to_str(f64/f32) → f64_to_str` routing.
6. `mir.qz`/`mir_lower.qz`: removed the two `f64_to_str` known-builtin String flags
   (`F64.to_s → f64_to_str` map at `mir.qz:3282` retained).
7. `codegen_runtime.qz`: removed the now-dead `@.fmt.f64` `%g` const.

Plus the cache fix: `qzmod_format.qz` (`qzmod_active_cache_dir_set` + `qzmod_cache_root`
honoring it) and `quartz.qz` (set it in `compile()`).

### Pre-existing dead `F64$to_s` landmine (filed, NOT fixed)

`F64$to_s` (`intrinsic_registry.qz:180`, `cg_intrinsic_core.qz:233`,
`typecheck_builtins.qz:707`) emits a bare `@f64_to_str` that never existed; unreachable
(`.to_s()` routes to `f64_to_str`→`@float$f64_to_str`). Dead before this change too. C
runtime `qz_f64_to_str` now unreferenced. D7 delete pass.

Algorithm context: `docs/design/FLOAT_TO_STRING.md`. Cross-session state:
`~/.claude/projects/-Users-mathisto-projects-quartz/memory/project_float_to_string_dragon4.md`.
