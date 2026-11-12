# `--cache-dir` cross-spec IR contamination

> **CLOSED-STALE 2026-07-07** — re-reproduced fixed on current binary; see docs/sagas/r24-groundwork-inert-holes-2026-07-07-research/ws2-triage.md (already ✅ in-doc; no cross-spec symbol leakage reproduces; resolved by qzmod-cache-dir + DCE work).

**Status:** ✅ FIXED (resolved 2026-05-21; residual sub-bug fixed `feb836f2` same day). Left in place — referenced by `docs/ROADMAP.md`, `docs/QSPEC_PERFORMANCE_HANDOFF.md`, and `docs/QSPEC_PERFORMANCE_ROADMAP.md`.

**Filed:** 2026-05-11 (discovered while attempting to flip the qspec
runner from `--no-cache` to per-worker `--cache-dir` for a 75×
throughput win — demo of 6 specs worked, full 804-spec run broke at
scale: 105/804 passed, 668 SIGSEGV/exit-137 in the compiler).
**Severity at filing:** High.
**Closed-out:** 2026-05-21 (see "Resolution" below).
**Severity today:** Resolved. The systemic contamination was closed
2026-05-21 (below); the one residual sub-bug (consumer-shadow
resolution under qzmod-injected typecheck) was itself fixed later the
same day in `feb836f2` — see "Residual sub-bug: resolved" below.

## Resolution (2026-05-21)

The catastrophic cross-spec contamination this doc described **no
longer reproduces.** Today's measurement, with the same reproducer
(below) on commit `6f1b290b`:

| Compile | Lines | `define` | `declare` |
|---|---|---|---|
| Solo fresh-cache `fn_ptr_spec.qz` | 64,862 | 538 | 214 |
| Warm cache (6 prior specs) | 65,916 | 538 | 214 |

vs. the original 124,068 / 1,266 with ~544 leaked `__Future_*$new/$poll`
symbols. The systemic leak was closed by intervening work between
2026-05-11 and 2026-05-21:

* The qspec runner switched from "every worker writes to a shared
  cache dir" to "single-threaded prewarm writes once, workers read
  `--cache-ro`" (Quakefile.qz `_qspec_prewarm_cache`, the `cache_ro`
  flag in `build_cache.qz`). No two workers can race a write because
  workers never write.
* The `INC.1` / `INC.2` series replaced the per-compile-keyed
  `cache_op_store(filename, hash, ir)` policy with per-module `.qzmod`
  artefacts. Fragments are now keyed by *module identity*, not by which
  `__main__` happened to produce them.
* DCE-pruning of cached fragments (`INC.2.5`) and per-function fragment
  delimiters (`INC.1.6`) closed the path by which a prior spec's
  `__Future_*$poll` body could surface in a later spec's IR.

The full qspec suite now passes 789/802 under `QSPEC_PREWARM=1` in
~272s (vs the 720s/105-pass collapse the original doc captured). The
`QSPEC_PREWARM=1` flag was flipped to default-ON in the Quakefile
2026-05-21 alongside this doc update. Set `QSPEC_PREWARM=0` to opt out
to the legacy `--no-cache` per-spec path.

Of the 13 remaining failures under prewarm:

* **10 also fail under `--no-cache`** — pre-existing spec or runtime
  bugs unrelated to caching (bench_spec, hm_inference_spec, the TLS
  network suite, etc.). Filed as ROADMAP A.17 backlog.
* **`graceful_shutdown_spec`** — lli SIGSEGVs under both cold and warm
  IR; runs cleanly under native llc+clang. lli-vs-native split, not
  caching.
* **`async_rwlock_batch_wake_spec`** — passes when run solo under
  either mode; only failed in the parallel pool. Parallel-contention,
  not caching.
* **`repl_spec`** — the one genuine prewarm-induced regression. Caused
  by a local `def strip_ansi` colliding with `colors$strip_ansi`
  re-exported via `import * from qspec → import * from colors`. Cold
  resolved the shadow correctly; qzmod-injected typecheck did not.
  **Fixed 2026-05-21 in `feb836f2`** — see "Residual sub-bug: resolved"
  below. The `_strip_ansi` workaround has been reverted to the colliding
  name, so `repl_spec` now actively guards the fix in the cache-ro
  suite.

The IR diff that remains between cold and warm `fn_ptr_spec` (1,054
lines across 132 functions, no duplicate symbols) is two minor
codegen-determinism artefacts — not contamination:

* Loop-metadata IDs renumber across compiles because warm starts the
  counter at the cached pool's tail.
* `__Future_*$poll` dispatch tables (`poll_switch`) can vary their case
  list depending on the order resume blocks are enumerated in
  `mir_lower_gen.qz`. The cached fragment preserves whichever variant
  was emitted first.

Both are byte-divergence without correctness divergence (verified: same
539 defines, same callable behaviour). They're tracked as a separate
note for a future codegen-determinism pass, not under this bug.

## Residual sub-bug: resolved (`feb836f2`, 2026-05-21)

The consumer-shadow sub-bug (previously tracked at the now-deleted
`docs/bugs/QZMOD_INJECT_IGNORES_CONSUMER_SHADOW.md`) was fixed in
`feb836f2` — "mir: qzmod body load honors resolver's local-wins shadow
rule" (`mir_lower.qz`). Before the fix, the MIR loader for cached
(qzmod-injected) bodies ignored the resolver's local-wins shadow
decision; now a consumer-local `def` that shadows a re-exported
wildcard import resolves to the local definition under qzmod-injected
(`--cache-ro`) typecheck, matching cold-compile behaviour. (This doc's
"Resolution (2026-05-21)" section was written earlier the same day,
before the residual was closed, and listed it as still-open; corrected
here.)

Re-confirmed 2026-06-04 with the original `repl_spec` collision (local
`strip_ansi`
vs. `colors$strip_ansi`, where `colors` is fully warmed in the cache
via `import * from qspec → import * from colors`):

| Compile | `@strip_ansi` (local) | `@colors$strip_ansi` (re-export) | run |
|---|---|---|---|
| Cold (`--no-cache`) | 7 | 0 | ✅ green |
| Warm (`--cache-ro`) | 7 | 0 | ✅ green |

Repro: prewarm `spec/qspec/_qspec_prewarm.qz` into a `--cache-dir`,
then `--cache-ro`-compile `spec/qspec/repl_spec.qz`; grep the IR for
`@*strip_ansi*`. The `_strip_ansi` workaround was reverted to the
colliding `strip_ansi` name, so `repl_spec` guards this in the suite.

## Original report (2026-05-11)

When the same `--cache-dir` is reused across compiles of **different
spec files** (different `__main__`, overlapping stdlib imports), the
compiler emits IR that contains symbol definitions **from previously-
cached specs as well as the current spec.** The contamination is
deterministic and scales with the number of previously-compiled specs.

Measured (single-process sequential compiles, fresh cache → 6 prior
specs → fn_ptr_spec):

| Compile state | IR lines | `define`/`declare` symbols |
|---|---|---|
| Fresh cache, fn_ptr_spec alone | 61,065 | 722 |
| Warm cache (after 6 prior specs) | **124,068** | **1,266** |

The extra 544 symbols are the leaked `__Future_*$new` / `__Future_*$poll`
/ async-helper definitions from prior specs' code. `llc` rejects the
contaminated IR (duplicate symbols, undefined `@qz_main`, etc.); a
parallel qspec runner sees this as "compile error (exit 139)" because
the chain crashes downstream of the contaminated emit.

## Reproducer (preserved for reference; numbers are 2026-05-11)

```bash
mkdir -p /tmp/cache_repro
for s in option_result_spec option_interp_spec scope_channel_spec memory_spec slices_spec variables_spec; do
  ./self-hosted/bin/quartz --cache-dir /tmp/cache_repro \
    -I std -I . -I self-hosted/shared -I self-hosted/frontend \
    -I self-hosted/middle -I self-hosted/backend -I spec/qspec/fixtures \
    "spec/qspec/${s}.qz" > /dev/null
done

# Now compile a 7th spec on the warmed cache:
./self-hosted/bin/quartz --cache-dir /tmp/cache_repro \
  -I std -I . -I self-hosted/shared -I self-hosted/frontend \
  -I self-hosted/middle -I self-hosted/backend -I spec/qspec/fixtures \
  spec/qspec/fn_ptr_spec.qz > /tmp/warm.ll

# Compare against a fresh-cache solo compile:
mkdir -p /tmp/cache_solo
./self-hosted/bin/quartz --cache-dir /tmp/cache_solo \
  -I std -I . -I self-hosted/shared -I self-hosted/frontend \
  -I self-hosted/middle -I self-hosted/backend -I spec/qspec/fixtures \
  spec/qspec/fn_ptr_spec.qz > /tmp/solo.ll

wc -l /tmp/solo.ll /tmp/warm.ll
```

Today: both files have 538/538 defines and 214/214 declares (down from
the original 722/1,266). Run still useful for tracking the residual
1k-line drift if a regression appears.

## What was wrong (historical, since fixed)

The original two-line summary:

* `cache_op_store(filename, cache_key, final_ir)` at
  `self-hosted/quartz.qz:1089` stored the **whole program IR** for the
  current `__main__` keyed by source filename. On subsequent compiles
  with a different filename, the prior entry persisted in the manifest
  and some path during codegen-merge included cached entries by *path
  glob* rather than by current dep-graph membership.
* `cache_get_dir() + "/modules/<frag>.ll"` per-async-helper fragments
  stayed in the dir indefinitely and were re-included on later compiles
  even when the new spec didn't generate them.

Both paths are gone. Fragments are now keyed by module short-name (not
by `__main__`), the manifest stores per-module hashes (not per-program
IR), and DCE prunes both fresh emission and cached-fragment loads.

## Runtime symptom in qspec runner (historical, no longer reproduces)

```
QSpec (lli): 105/804 files passed (720.37s)
Failures:
  …  (~660 specs SIGSEGV)
```

vs today:

```
qspec: pre-warmed .qzmod cache in 403ms — specs compile --cache-ro
QSpec (lli): 789/802 files passed (272.75s)
```

## Sister/related issues

* Consumer-shadow sub-bug (formerly its own doc) — **fixed 2026-05-21
  in `feb836f2`**, see "Residual sub-bug: resolved" above. Doc file
  removed in that commit.
* `feedback_quakefile_treated_as_compiler_source.md` — separate, but
  same project-cache surface; not implicated here.
