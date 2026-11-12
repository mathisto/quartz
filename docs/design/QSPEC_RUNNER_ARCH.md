# QSpec Runner Architecture — Parallelism + Speedup

> Design memo. Decisions before code.
>
> **Status:** Filed 2026-05-09. Phase 0 ✅ closed (defer cache work).
> Phase 1' ✅ shipped 2026-05-09 — `posix_spawn_wait(cmd: String): Int`
> intrinsic added (typecheck + registry + codegen + runtime helper),
> fixpoint verified. Phase 1'' ✅ closed 2026-05-09 — root cause was
> NOT a scheduler bug. The `mir_lower_async_constructor` "eager pre-poll"
> optimization (`mir_lower_gen.qz:986`) was inlining the body of
> `def s = posix_spawn_wait(...)` into `__Future_s$new`, running it
> on the spawning thread before returning. Two compiler fixes:
> (1) registered `posix_spawn_wait` / `system` / `popen` / `pclose` /
> `sleep_ms` as suspendable leaves so callers skip eager pre-poll;
> (2) fixed `mir_mark_suspendable` to seed `_suspendable_funcs` from
> the leaves Vec directly (not just MIR-function names), then bridge
> `__Future_X$poll → X` for transitively-marked names. Reproducer
> dropped from 8.04s strict-serial to 2.01s fully-parallel.
> **Phase 1 ✅ shipped 2026-05-09 — qspec runner now spawns a worker
> pool of `min(num_cpus, 16)` goroutines** (env override `QSPEC_WORKERS=N`)
> that pull spec files from a bounded MPMC channel and push SpecResult
> structs back through an unbounded result channel. Main thread drives
> Live UI + accumulation; workers don't touch shared state. Cancellation
> via shared atomic flag — first SIGINT-killed spec sets the flag,
> sibling workers exit on next recv. Empirical speedup: string_* subset
> 19 specs **164s → 55.6s (2.95×)** at N=8; alloc subset 27 specs
> **202s → 119s (1.70×)** — alloc is bottlenecked by native-compile
> CPU contention. Pass/fail counts byte-identical to serial baseline.
> All changes confined to `Quakefile.qz` (no compiler-source touch, no
> `quake guard` needed). Phase 2 (LPT scheduling) and Phase 4 (drop
> dead `lli` path) are next; together they should close the
> alloc-style speedup gap.
>
> **Source for shape:** the audit + research the 2026-05-09 session ran
> in parallel; full reports captured in conversation history. The
> 5-paragraph synthesis below is the actionable summary.

## Why now

`quake qspec` takes ~10 minutes for 787 specs serial. A single spec
takes ~6s (compile-dominated). On an 8-core dev machine the entire
suite is bottlenecked by one core. The user observation that prompted
this: "running one individual test sometimes comes back in microseconds
… is there a better way?"

There is. Three patterns from major test runners (Vitest workers,
pytest-xdist worksteal, Pest v4.6 LPT scheduling) consistently deliver
4-8× speedup at our scale with no compiler-side work. Phase 5
(persistent compiler daemon) would unlock a further 3-5× but is
multi-session compiler work; deliberately deferred.

## Cost picture (audit, n=20 sample)

| Step | Per spec | % of suite |
|---|---|---|
| `quartz` compile (with `--no-cache`) | 5.04s | **86%** |
| `llc` codegen | 0.54s | 9% |
| `clang` link | 0.04s | <1% |
| Spec runtime | 0.20s | 3% |
| Runner overhead (UI, cleanup, I/O) | 0.05s | <1% |

**Headline:** the compiler is 86% of wall time. Speedup ceiling at N
cores is ~0.87N. 8 cores → ~7×: 10 min → ~1.4 min. 16 cores → ~14×:
10 min → ~45s.

**Notable surprises from the audit:**
1. The `lli` JIT path is dead — every spec falls back to native
   because `lli` can't resolve our libc-stdlib symbols. The runner
   pays `lli`'s ~100ms cold-start to detect failure, then does the
   slow path anyway. **Phase 4: delete the lli code path.**
2. `--no-cache` is in every compile invocation. This re-parses
   stdlib + qspec module ASTs from scratch 787 times. Phase 0
   investigation found this is intentional — the `.quartz-cache/`
   manifest tracks per-build state and would be corrupted by
   cross-spec sharing. Re-enabling cache requires either a compiler
   `--cache-dir` flag (touches self-hosted, multi-session) or a
   per-spec `cd` dance (fragile, races under workers). **Phase 0
   verdict: defer cache work. Worker-pool win is independent.**

## Research summary — what world-class test runners do

Full survey in conversation history; one-paragraph distillation:

- **Bun's** "single process" advantage doesn't apply — they have no
  separate compile step. Apples-to-apples we're closer to `cargo test`
  integration tests (one binary per file, link-heavy).
- **Go test's** two-knob model (`-p` for package compiles, `-parallel`
  for intra-binary) is the most-beloved pattern for separately-compiled
  language test runners.
- **pytest-xdist's `worksteal`** + **Pest v4.6's time-LPT** beat
  hash-mod-N sharding for varied test costs (which qspec has — generics-
  heavy specs vs one-line `assert_eq` specs).
- **Persistent JIT pool** (LLVM ORC) is the long-term answer if we
  build Phase 5. Prior art exists (GHCi, Cling) but no test runner
  does this pattern. High risk, high reward — defer.

**Anti-patterns found and avoided:**
- Hash-name sharding (gtest's pain at scale)
- Reading raw CPU count without cgroup awareness (Jest's "31 workers
  on a 2-CPU CI container" issue #11633)
- Thundering-herd cold-start on initial worker fan-out

## Design decisions (locked here, not relitigated later)

### D1. Worker pool model: N goroutines pulling from a shared work channel

Quartz already has the substrate: `go fn()`, `channel_new(cap)`,
`send(ch, val)`, `recv(ch)`. The pool size sets the max number of
in-flight `system()` calls (one per worker pthread).

Rejected: process-per-spec like `cargo nextest`. Each qspec spec is
*already* its own subprocess (it's a `main()` program); the process
boundary is free. The leverage is in *what feeds the pool*, not *more
processes*.

### D2. Worker count default: `min(num_cpus, 16)`

Matches Vitest/Mocha/pytest-xdist consensus. The 16 cap prevents
pathological spawning on huge machines. CGroup-aware on Linux:
prefer `nproc` (which respects cgroup limits in modern coreutils)
over `sysctl hw.ncpu`. Allow `QSPEC_WORKERS=N` env var override.

Rejected: `num_cpus - 1` (Mocha/Jest pattern, leaves a CPU for the
parent reporter). Quartz's reporter (Live UI) is cheap relative to
compile work; saturating wins more than reporter-CPU-starvation costs.

### D3. Work-stealing via shared MPMC channel, not pre-sharded queues

Workers pull when free; the slower worker picks fewer items, the
faster worker picks more. Naturally load-balanced. Implementation:
one `work_ch = channel_new(N)` (bounded for backpressure), one
`result_ch = channel_new(total_files)` (unbounded enough to absorb
all results without blocking workers).

Rejected: pre-shard `total_files / N` items per worker. Causes
long-pole worker waiting while others idle (gtest's hash-shard pain).

### D4. Per-spec result aggregation via channel + struct

Workers don't directly mutate shared `passed`/`failed_*`/etc.
Instead they construct a `SpecResult` struct and `send` it to the
result channel. Main thread receives, accumulates, updates Live UI.

```quartz
struct SpecResult
  name: String
  outcome: Int           # 0=passed, 1=skipped, 2=failed, 3=cancelled
  reason: String         # populated when failed
  captured: String       # populated when failed
  file_time_ms: Int
end
```

This avoids the Send/Sync analysis Quartz would otherwise require for
direct shared-Vec mutation, and matches Vitest/Jest's IPC-result
pattern.

### D5. Cancellation via shared atomic flag

`cancel_flag = atomic_new(0)`. Workers check `atomic_load(cancel_flag)
== 1` at the recv boundary. When any worker detects SIGINT in its
current spec (per-site `exit==130 || sig==2` check), it sets the
flag. Other workers stop pulling new work after their current spec
finishes.

This preserves the SIGINT-cancellation semantics shipped in `f17832b3`
without requiring a runner-level signal handler (which can't fire
during `system()` due to libc's SIG_IGN behavior).

### D6. Live UI: workers write directly (Live is already mutex-protected)

`std/progress.qz`'s `Live` struct uses `_render_mtx` (line 1903) and
`_g_live_actives_mtx` (line 1920). Workers can call `live.add(bar)`,
`live.tick()`, `live.log(msg)` concurrently without coordination.

Live's `max_active(N)` becomes `max_active(num_workers)` so the UI
shows N concurrent rows.

### D7. Time-balanced scheduling via persisted runtime history (Phase 2)

After each suite run, persist `spec/.qspec_runtimes.json`:
```json
{"spec_name": runtime_ms, ...}
```

On next run, sort `spec_files` descending by last observed time,
fall back to filesystem order on first-run / unknown specs. Long-pole
specs go first; short specs fill in tail. With work-stealing this is
the LPT (Longest Processing Time) bin-packing heuristic — within
~4/3 of optimal for any number of bins.

`.qspec_runtimes.json` is gitignored (per-developer machine
characteristics).

### D8. Per-worker isolation (Phase 3)

Set `QSPEC_WORKER_ID=N` for each spec invocation. Per-worker temp
file naming: `/tmp/qspec_${session}_${worker}_${name}.*` (already
mostly per-spec via session_id; tighten to include worker_id for
cleanup safety). Mirror RSpec's `TEST_ENV_NUMBER` pattern.

Specs that bind to fixed ports: documented escape hatch via
`QSPEC_PORT_BASE` env var; specs read `QSPEC_PORT_BASE +
QSPEC_WORKER_ID * 100` to allocate per-worker port ranges.

### D9. Serial retry pass for failed specs (contention hardening, 2026-06-05)

**Problem.** The N-worker pool oversubscribes the host toolchain. Each
worker's `_qspec_run_one` spawns nested processes (compile → `lli` or
`llc`+link+run), and multi-file specs (those using `qspec/subprocess`)
fork their OWN compiler+linker children per embedded program. With
N=16, peak process count is several times the core count. Under that
load a normally-sub-second spec can spuriously hit the run **TIMEOUT**,
or a transient `clang`/`llc`/link/spawn can fail (`exit 1`, `link
error`, even `SIGSEGV` from a scheduler race that only manifests under
extreme load). The failing set **rotates run-to-run** — the signature
of contention, not a code bug. Empirically (2026-06-05) three full
runs failed 4–8 specs each, every one passing when re-run standalone.

**Decision.** After the parallel pass aggregates results, re-run every
FAILED spec **serially** — one process at a time, on the main thread,
`worker_handle=0` (fresh compiler; the daemon pool is already shut
down) — before declaring it real. A spec that passes serially was a
contention victim (move it to the pass column, log it as `recovered`);
one that still fails after `QSPEC_RETRY` attempts (default 2) is a
genuine bug (keep failed, dump its capture, exit 1). This automates the
manual "standalone-triage each failure" step that was previously done
by hand every session.

**Why a clean-environment retry, not blind re-attempts.** Bazel
`--flaky_test_attempts` / pytest-rerunfailures / Jest `retryTimes` all
re-run under the *same* load, so a contention failure can recur. Running
the retry in a contention-free single-process environment is the
*definitive* discriminator: contention cannot reproduce there, so a
serial pass is strong evidence the parallel failure was a false negative,
and a serial fail is strong evidence it's real.

**Transparency (no silent caps).** Recovered specs are listed explicitly
in the summary (`N spec(s) recovered on serial retry (parallel-pool
contention, not code bugs)`) so a spec that recovers *every* run — a
genuine load-only race like a scheduler bug — stays visible for
investigation rather than being silently masked.

**Clean-room compile + bounded cost.** The retry compiles with
`--no-cache` (not the suite's `--cache-ro`), so it's immune to
`.quartz-cache-qspec` cross-spec contamination too — both contention
sources eliminated, matching the manual `quartz --no-cache` triage. It
also runs with a tighter timeout (default 60 s vs the suite's 300 s):
contention victims finish in 1–3 s and the slowest legit native spec is
~14 s, so 60 s confirms a pass with margin while capping a genuine hang
at 60 s. And it **stops early on a TIMEOUT** — a hang won't un-hang on a
re-run in the same clean room, so a second full-budget attempt is pure
waste (this matters: a deterministic-hang spec like
`scoped_async_yield_resume` at `llc -O0` would otherwise burn
`max_attempts × timeout`). Transient link/spawn/exit failures still get
the extra attempt.

**Knobs.** `QSPEC_NO_RETRY=1` disables (CI may want raw parallel
results); `QSPEC_RETRY=N` sets max serial attempts (default 2);
`QSPEC_RETRY_TIMEOUT=S` sets the per-retry run timeout (default 60).
Skipped on Ctrl+C. Cost is bounded: only the small rotating failure set
is re-run, ~1–3 s each (a hang at most one reduced-timeout budget), and
only when the parallel pass actually failed — the all-green happy path
pays nothing.

**Note — the suite's `llc -O0` vs the oracle's `-O2`.** `_qspec_run_one`
assembles native specs at `llc -O0` (3× faster), while `quake
qspec_file` and the smoke tests use default `llc` (`-O2`). A spec can
therefore fail the suite but pass the oracle: `scoped_async_yield_resume`
**deterministically hangs at -O0, passes at -O2** — a real -O0-sensitive
concurrency bug (filed), not a runner artifact. The retry faithfully
reproduces the suite's `-O0` path, so it correctly keeps such a spec
failed rather than masking it. Whether the suite *should* match
production codegen (`-O2`) is an open question — `-O0` is currently
earning its keep by surfacing real latent races.

**Follow-up (deferred).** A proactive contention *reduction* — e.g. a
separate smaller pool (or serial lane) for `qspec/subprocess` heavy
specs, which fork their own toolchain children — would cut the number
of retries needed. Orthogonal to correctness; the retry already makes
the suite reliable. `graceful_shutdown_spec`'s under-load `SIGSEGV`
(passes standalone every time) is a candidate real load-only scheduler
race worth a dedicated look.

## Phase plan

| Phase | Subject | Sized | Touches |
|---|---|---|---|
| **0** | Investigate `--no-cache` necessity | 0.25 q-day ✅ closed 2026-05-09 (defer) | Investigation only |
| **1'** | `posix_spawn_wait` intrinsic + runtime helper | 0.25 q-day ✅ shipped 2026-05-09 | typecheck_builtins, intrinsic_registry, cg_intrinsic_system, codegen_runtime |
| **1''** | Eager pre-poll skip for blocking-syscall callers | 0.25 q-day ✅ closed 2026-05-09 | `mir_lower_async_registry.qz`, `mir_lower_gen.qz` |
| **1** | Worker pool + result aggregation | 0.5 q-day ✅ shipped 2026-05-09 | `Quakefile.qz` (extracted `_qspec_run_one`, added `SpecCtx`/`SpecResult` structs, `_qspec_worker`/`_qspec_dispatch` goroutines, atomic cancel flag) |
| **2** | Time-balanced scheduling | 0.25 q-day | `Quakefile.qz` + new `spec/.qspec_runtimes.json` (gitignored) |
| **3** | Per-worker isolation | 0.25 q-day | `Quakefile.qz` (env var + temp path tightening) |
| **4** | Drop dead `lli` code path | 0.1 q-day | `Quakefile.qz` (~50 line deletion) |
| **5** | Compiler daemon mode (DEFERRED) | 3-5 q-days, multi-session | `self-hosted/quartz.qz`, new `quartzd` binary |
| **6** | Serial retry pass (contention hardening) | 0.25 q-day ✅ shipped 2026-06-05 | `Quakefile.qz` (`_qspec_retry_failed` + `RetryOutcome` struct, reconcile in `run_qspec`); see D9 |

**Total Phase 1-4:** ~1.1 q-days. **Realistic outcome:** 10 min →
1.5 min on 8-core dev box. **Through Phase 5:** ~6 q-days, 10 min →
30s.

**Sequencing rationale:**
- **Phase 1 first** (largest single win, ~5-7×). Phases 2-4 add 10-20%
  on top.
- **Phase 4 last** so the lli-removal cleanup happens after we've
  validated the parallel runner works without it.
- **Phase 5 deferred** — empirical data from Phase 1-4 should drive
  whether the compiler-daemon investment is worth it. If post-Phase-4
  wall time is already 1.5 min, Phase 5 has marginal user value.

## Verification path

| Phase | Smoke |
|---|---|
| 1 | `quake qspec` wall time < 2 min on 8-core dev box. Same pass/fail counts as serial run (verify with QSPEC_PATTERN subset). Single Ctrl+C still cancels suite cleanly. |
| 2 | Two consecutive `quake qspec` runs: second run smaller wall-time variance (long-pole specs scheduled first). `.qspec_runtimes.json` written. |
| 3 | Specs that bind to fixed ports work under workers (e.g., http_server_spec uses `QSPEC_PORT_BASE` correctly; no port collision under parallel run). |
| 4 | `quake qspec` wall time same or slightly faster than Phase 3. `lli` code path removed; binary smaller. |

## Open decisions deferred

1. **`QSPEC_WORKERS=1` vs Phase 5's process-pool.** If/when Phase 5
   ships, the daemon would amortize compiler init across many specs
   per worker. Single-worker mode might want different scheduling
   (just sequential) — defer until Phase 5 lands.
2. **Failure isolation across workers.** A worker that segfaults
   shouldn't crash the runner. Quartz's goroutine isolation should
   handle this naturally (each goroutine is a task, not the host
   thread), but verify in Phase 1 testing.
3. **CI tuning.** GitHub Actions runners have 2-4 cores; cgroup-aware
   detection should pick the right N. Verify Phase 1 doesn't
   regress CI wall time.
4. **Non-determinism in failure ordering.** Parallel runs will
   complete specs in non-deterministic order. The "Slowest files"
   ranking and failure summary should be deterministic across
   re-runs (sort by name, not by completion order).

## What this unblocks downstream

- **Faster TDD loop.** A 1.5-min full suite is fundamentally different
  from a 10-min suite — it changes from "run once at end of feature"
  to "run after every meaningful change."
- **Real `quake test --watch` (future).** Watch mode is only useful
  if the suite returns in seconds-to-low-minutes.
- **Phase 5 case-study.** If Phase 1-4 shipping doesn't get us under
  1 minute, Phase 5 has a clear motivating gap. If it does, Phase 5
  becomes optional polish.

## References (verify against canonical sources before implementing)

- [pytest-xdist worksteal distribution](https://pytest-xdist.readthedocs.io/en/stable/distribution.html) —
  the canonical work-stealing test-runner pattern
- [Pest v4.6 time-based sharding (LPT algorithm)](https://laravel-news.com/time-based-sharding-in-pest-v4-6-0) —
  the time-balanced scheduling pattern we're adopting
- [Vitest pool config](https://vitest.dev/config/pool) — worker-pool
  defaults (matches our D2)
- [Jest workers issue #11633](https://github.com/jestjs/jest/issues/11633) —
  the "31 workers on 2-CPU container" gotcha that drives D2's
  cgroup awareness
- [LLVM ORC docs](https://llvm.org/docs/ORCv2.html) — Phase 5
  (deferred) substrate
- The full survey + audit transcripts live in the 2026-05-09 session
  conversation; if accessible, read those for the long-form rationale
  behind D1-D8.
