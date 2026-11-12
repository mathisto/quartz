# Exec Effect — Phase A.7 Dogfood Plan

> **Filed:** 2026-05-02 (start of A.7 session, after B.1 close-out
> `e09cbff6` deprioritized B.1 to stretch and promoted A.7 to #1).
> **Sequencing:** Phase A.7 of the post-audit roadmap. Inherits from
> A.3 Cache + A.6 Profile + A.8 Random recipe lineage.
> **Substrate locked in for:** C.8 (any future "remote-executor /
> Bazel-style" build orchestration), launcher migration if/when
> sequencing allows, in-process toolchain testing without subprocess
> shell-out.
> **Recipe inheritance:** mirrors the Quake migration's existing
> Phase 6.2.b commit (`PHASE_6_2_QUAKE_EFFECTS.md`); A.7 is its
> consumer-side completion, not a new effect introduction.

## What's already shipped (the framing-correction)

The handoff prompt and the audit roadmap row characterized A.7 as
"zero Exec callsites." That's wrong. `std/quake.qz` already
declares the effect, ships two handlers, and routes every `sh*`
wrapper through it:

```be
effect Exec
  def exec(cmd: String, opts: ExecOpts): ExecResult   # kind=1
end

def default_exec_handler(...)  # libc system + pipe + tempfile branches
def dry_run_handler(...)        # logs cmd + returns success

def sh(cmd: String): Int can Exec        = exec(cmd, opts).exit_code-or-throw
def sh_maybe(cmd: String): Int can Exec  = exec(cmd, opts).exit_code
def sh_capture(cmd: String): String can Exec
def sh_buffered(cmd: String, step: String): Int can Exec
def sh_quiet(cmd: String): Int can Exec
```

`quake_main()` (`std/quake.qz:847-859`) installs the Exec frame
inside Reader/Log/Throws:

```be
with Reader(verbosity) do ->
  with Log { emit: _quake_log_stdout } do ->
    with Throws { throw: _quake_throws_print_and_exit } do ->
      if dry_run
        with Exec { exec: dry_run_handler } do -> _quake_dispatch(...) end
      else
        with Exec { exec: default_exec_handler } do -> _quake_dispatch(...) end
      end
    end
  end
end
```

So every Quakefile task body runs inside the Exec install. `sh*`
calls are dispatch-routed correctly today; no plumbing change is
needed.

## The actual gap

`grep -n 'system(' Quakefile.qz tools/quake.qz` returns **49 raw
`system()` callsites** that bypass the Exec dispatch entirely:

- `Quakefile.qz` — **40 sites**
- `tools/quake.qz` — **9 sites**

For comparison, `Quakefile.qz` already calls the `sh*` family **230
times**. The migration is finishing what 6.2.b started: the legacy
`system()` calls that pre-date the migration or were added without
threading through the wrappers.

Each raw call is a hole in:

1. **Dry-run preview.** A `quake --dry-run rss_bench` invocation
   would still fork the `measure_rss` subprocess at line 367 because
   the call goes straight to libc.
2. **Test isolation.** A test fixture installing
   `with Exec { exec: capture_handler } do -> ... end` cannot
   intercept the raw `system()` calls — they short-circuit the
   handler stack.
3. **Recording / replaying for spec coverage.** The same.
4. **Future remote-executor substrate (C.8).** Every raw call is a
   site that would need re-migration when the executor lands.

## Audit-count reality check

The 49-callsite framing in the handoff held up under verification.
That's notable — sister-effect migrations all had 2-6× inflated
counts (A.1: 41 → 19 actual; A.2: 513 → 54; A.3: 30 → 5 mechanical
sites; per `feedback_audit_count_inflation.md`).

Why no inflation here: `system(` is a precise grep pattern. The
audit-inflation hazard surfaces when the row counts a fuzzy concept
("call sites", "use sites") that resolves to many syntactic shapes;
`system(` is one syntactic shape, one match per call. No category
errors.

**Effort prediction:** at the per-callsite level, ~80% of the
sites are pure mechanical (`system(cmd) → sh_maybe(cmd)` 1:1) and
~20% have decisions to make (preserve custom failure-message text
vs adopt `BuildError::CommandFailed`'s default; keep file-redirect
in the cmd string vs lift to `sh_capture`; etc).

## Scope decisions

### tools/quake.qz — DEFER

The 9 launcher-side `system()` calls in `tools/quake.qz` are
**explicitly out of scope** per `PHASE_6_2_QUAKE_EFFECTS.md`'s
"Non-goals" section: *"Migrating the launcher (`tools/quake.qz`)
too aggressively."*

Three reasons reinforce that:

1. **No active Exec install.** `tools/quake.qz`'s `main()` does NOT
   call `quake_main()` — it discovers + compiles + execs the
   Quakefile binary. The 9 `system()` sites run before any Exec
   frame is on the stack. Migrating them would require the launcher
   to also install `default_exec_handler` around its compile pipeline
   (and around `Reader` + `Log` to satisfy the handler's row).
2. **Bootstrap dependency cost.** The launcher binary today imports
   only `colors` + `content_hash`. Adding `import * from quake`
   pulls in `default_exec_handler`, `_execute_task`, the BuildError
   enum, the Throws scaffolding, and ~700 LOC of unrelated
   task-dispatch surface. The launcher binary doubles in size for
   migration value that lives in toolchain testability — a
   not-now-but-useful capability.
3. **Recursive sequencing.** The launcher compiles `Quakefile.qz`
   using `system()` calls to `quartz`/`opt`/`llc`/`clang`. Migrating
   those to dispatch through `Exec` while we ALSO migrate
   `Quakefile.qz` itself adds simultaneous variables. Land Quakefile
   first; revisit launcher migration only if a concrete user (a test
   harness, the C.8 executor) needs it.

**Filed as `EXEC_LAUNCHER_MIGRATION` follow-up** (Phase 6.2.d, queued
behind A.7 close-out with the audit-corrected smaller scope:
specifically, "thread the toolchain pipeline through Exec to support
launcher-level `--dry-run` and capture-handler-driven launcher
testing"). Not a Tier-S blocker; ships when a downstream consumer
needs it.

### Quakefile.qz — full sweep, phased

40 sites cluster into 6 cohesive groups. Migrate in order of
clearest semantic mapping first to validate the pattern early:

| Phase | Group | Sites | Pattern |
|------:|-------|------:|---------|
| 1 | Snapshot/smoke checks | 4 | `system → sh_maybe` + preserve custom fail message |
| 2 | Bench/RSS tasks | 8 | `system → sh_maybe` + preserve custom fail message |
| 3 | Fuzz tasks (mixed) | 12 | `system → sh_maybe` (some ignore rc, some fail) |
| 4 | REPL + site:dev (long-running) | 2 | `system → sh_maybe`; rc captured for caller |
| 5 | QSpec runner internals | 14 | `system → sh_maybe`; preserve raw wait-status semantics |
| 6 | Test handlers + spec | n/a | New `exec_*_handler` factories + qspec |

Each phase ships in its own commit. Fixpoint clean between every
commit (none of these touch self-hosted compiler source — pure
Quakefile-side dogfood, so guard runs are mechanical).

## Migration rules

These apply across all phases and document the per-call decision
tree:

### Rule 1 — `system(cmd) → if rc != 0 fail("...")` becomes `sh_maybe`

Preserve the custom failure message:

```be
# Before
var result = system(cmd)
if result != 0
  fail("measure_rss failed")
end

# After
var result = sh_maybe(cmd)
if result != 0
  fail("measure_rss failed")
end
```

`sh(cmd)` would auto-throw with `BuildError::CommandFailed(cmd, rc)`.
That's the _ideal_ shape, but the existing custom messages
("measure_rss failed", "Fuzzer found issues — see /tmp/fuzz_crashes/")
carry context the auto-throw lacks. Keep `sh_maybe` + manual `fail`
for now; a follow-up can audit which messages are valuable enough
to preserve and which can switch to `sh()`.

### Rule 2 — `system(cmd)` ignoring rc becomes `sh_maybe(cmd)` with discarded result

`sh_maybe` is the correct primitive — it explicitly tolerates
non-zero exits:

```be
# Before
system("llc -filetype=obj #{fuzz_ll} -o /tmp/_quake_fuzz.o 2>/dev/null")

# After
var _r = sh_maybe("llc -filetype=obj #{fuzz_ll} -o /tmp/_quake_fuzz.o 2>/dev/null")
```

Alternatively, suppress the `_r` binding via a discard pattern when
that's idiomatic. Either form satisfies `can Exec` propagation.

### Rule 3 — Cleanup `rm -f` calls become `sh_maybe`

The QSpec runner has cleanup calls (`rm -f /tmp/_qspec_sub_…`,
`rm -f /tmp/qspec_…`) that should never abort the run on failure.
`sh_maybe` is correct.

### Rule 4 — File-redirect-in-cmd-string stays as-is

The QSpec runner captures stdout via shell redirect:

```be
"#{lli} #{ir_path} > #{out_path} 2>&1"
"timeout #{timeout_str} #{bin_path} > #{out_path} 2>&1"
```

These do NOT migrate to `sh_capture`. Rationale: the runner needs
the redirect-to-file isolation (separate process file fd), and the
contract is "subprocess writes to `out_path`, runner reads back from
`out_path` after the fact." `sh_capture` would route stdout through
a pipe in the runner's address space, breaking that contract.

`sh_maybe(cmd)` honors the shell redirect because
`default_exec_handler` calls `system(cmd)` directly when neither
`capture_stdout` nor `step_name` is set (`std/quake.qz:215-217`).

### Rule 5 — Raw wait-status return values keep working

`default_exec_handler:215` returns `system(cmd)`'s raw wait-status
(not the decoded exit code) in `ExecResult.exit_code`. The QSpec
runner's `result / 256` and `band(result, 127)` decoding logic
(lines 2314-2315, 2374-2375, 2478-2479) reads that raw value. So
`sh_maybe(cmd)` is byte-equivalent to `system(cmd)` for downstream
math. No behavior change.

This is _slightly_ misleading naming (`ExecResult.exit_code` is
actually the raw wait-status), but changing it is out of scope for
A.7; document and move on.

## Phase 1 — Snapshot/smoke checks (4 sites)

**Goal:** validate the `system → sh_maybe` pattern on the simplest
cohesive group.

**Sites:**
- `Quakefile.qz:606` — `ufcs:check`
- `Quakefile.qz:613` — `ufcs:update`
- `Quakefile.qz:620` — `smoke`
- `Quakefile.qz:627` — `smoke:update`

All four are identical shape: `var rc = system("./tools/...")
+ if rc != 0 fail("...")`. Migrate per Rule 1.

**Verify:**
- `quake guard` clean (no compiler source touched, but stamp must
  refresh because `Quakefile.qz` content changed and the launcher
  cache hashes it).
- Manual smoke: `quake ufcs:check` runs identically (passes when the
  snapshot matches; fails with the custom message when it doesn't).
- `quake smoke` runs identically.

**Commit:** `[a7/exec] Phase 1: migrate ufcs/smoke task system() → sh_maybe`

## Phase 2 — Bench/RSS tasks (8 sites)

**Sites:**
- `Quakefile.qz:367` — `bench_rss`
- `Quakefile.qz:377` — `bench_rss_diff`
- `Quakefile.qz:390, 396` — `sched_bench`
- `Quakefile.qz:407, 413` — `sched_bench_quick`
- `Quakefile.qz:424, 430` — `sched_bench_precise`

All identical shape per Rule 1. Mechanical sweep.

**Verify:** `quake guard` + manual `quake bench_rss` (creates
`benchmarks/rss/style_demo_head.csv`).

**Commit:** `[a7/exec] Phase 2: migrate bench/RSS task system() → sh_maybe`

## Phase 3 — Fuzz tasks (12 sites)

**Sites:**
- `Quakefile.qz:639, 645, 649, 658` — `fuzz`
- `Quakefile.qz:669, 675, 676, 683` — `fuzz_long`
- `Quakefile.qz:694, 700, 701, 711` — `fuzz_differential`

Mixed: 4 are "with-error-check" (Rule 1), 8 are
"ignore-rc-or-discard" (Rule 2). Note that lines 675/676/700/701
ignore the rc entirely today — preserve that semantic via
`var _r = sh_maybe(...)` so explicit `can Exec` propagation reads
clearly.

**Verify:** `quake guard` + manual `quake fuzz` (with
`QUARTZ_COMPILER` set; runs 100 fuzz programs).

**Commit:** `[a7/exec] Phase 3: migrate fuzz task system() → sh_maybe`

## Phase 4 — REPL + site:dev (2 sites)

**Sites:**
- `Quakefile.qz:771` — `repl` task
- `Quakefile.qz:789` — `site:dev` task

Both are "long-running interactive" — caller invokes the binary and
returns the exit code without further action. `sh_maybe` is
appropriate.

**Verify:** `quake guard` only (interactive tasks not amenable to
automated verification within this phase; defer integration testing
to ship-time manual smoke).

**Commit:** `[a7/exec] Phase 4: migrate repl/site:dev task system() → sh_maybe`

## Phase 5 — QSpec runner internals (14 sites)

This is the largest cohesive group and the most subtle (raw
wait-status arithmetic, redirect-to-file isolation, timeout-wrapper
shell composition).

**Sites:**
- `Quakefile.qz:2303` — per-file cleanup (Rule 3)
- `Quakefile.qz:2310, 2312` — compile invocation (timeout vs no-timeout)
- `Quakefile.qz:2369, 2371` — lli execution (Rule 4 redirect)
- `Quakefile.qz:2407` — llc invocation
- `Quakefile.qz:2460` — link invocation
- `Quakefile.qz:2472, 2474` — native binary execution (Rule 4 redirect)
- `Quakefile.qz:2599` — session cleanup (Rule 3)
- `Quakefile.qz:2758` — single-file compile (run_qspec_file)
- `Quakefile.qz:2788` — single-file lli run
- `Quakefile.qz:2805` — single-file link
- `Quakefile.qz:2817` — single-file native run

All migrate to `sh_maybe` per Rules 1-5. The wait-status decoding at
lines 2314-2315, 2374-2375, 2478-2479 stays as-is (Rule 5).

**Verify:** `quake guard` + `quake qspec` smoke (run a small subset
to catch any wait-status-decoding regression — full suite is too
slow per `CLAUDE.md`).

**Commit:** `[a7/exec] Phase 5: migrate qspec runner system() → sh_maybe`

## Phase 6 — Test handler factories + spec

Mirror Cache's Phase 3 / Random's Phase 4 / Profile's Phase 4 shape.
Three factories in `std/quake.qz`:

### `exec_recording_handler`

Appends every `(cmd, opts)` tuple to a module-level Vec. Readable
via `exec_recording_log()`, resettable via `exec_recording_reset()`.
Returns `ExecResult { exit_code: 0, stdout: "", stderr: "" }` —
records but does NOT execute.

```be
var _exec_recording_log = vec_new<String>()

def exec_recording_handler(op_name: Int, argc: Int, argv: Int): Int
  var cmd = as_string(load(argv, 0))
  _exec_recording_log.push(cmd)
  var r = ExecResult { exit_code: 0, stdout: "", stderr: "" }
  return as_int(r)
end

def exec_recording_log(): Vec<String> = _exec_recording_log
def exec_recording_reset(): Void = _exec_recording_log = vec_new<String>()
```

The spec at `phase_6_2b_quake_exec_spec.qz:130-165` already proves
the recording-shape works (defines `cap_exec` inline). The factory
lifts it from per-test boilerplate to stdlib.

### `exec_replaying_handler`

Looks up `cmd` in a pre-seeded `Map<String, ExecResult>` and returns
the canned result. Missing-key behavior: **fail loudly** by emitting
a Throws::CommandFailed with a clear "no replay registered for: {cmd}"
message. Spec tests get a clear signal when the test setup didn't
register a command they ended up triggering.

```be
var _exec_replay_map: Map<String, Int> = map_new<String, Int>()  # cmd → as_int(ExecResult)

def exec_replaying_handler(op_name: Int, argc: Int, argv: Int): Int can Throws
  var cmd = as_string(load(argv, 0))
  match _exec_replay_map.get(cmd)
    Some(r_int) => return r_int
    None => fail("no replay registered for: #{cmd}")
  end
  return 0
end

def exec_replaying_register(cmd: String, exit_code: Int, stdout: String, stderr: String): Void
  var r = ExecResult { exit_code: exit_code, stdout: stdout, stderr: stderr }
  _exec_replay_map.set(cmd, as_int(r))
end

def exec_replaying_reset(): Void = _exec_replay_map = map_new<String, Int>()
```

### `exec_dry_run_handler` already exists

`std/quake.qz:227-232` ships `dry_run_handler`. Don't add another;
factory set is two new + one existing.

### Spec

New file `spec/qspec/exec_effect_handlers_spec.qz`. Coverage:

- `exec_recording_handler` with each of `sh`, `sh_maybe`, `sh_capture`,
  `sh_buffered`, `sh_quiet` — assert the recorded log matches.
- `exec_replaying_handler` with pre-seeded results — assert the
  returned value matches the registration; assert the
  no-replay-registered case fails as expected.
- Reset functions actually reset.
- `exec_recording_handler` + `exec_replaying_handler` composability:
  install replaying outermost, recording innermost — assert
  recording sees the cmd, replaying serves the response.

~10-12 tests total, ~150-200 LOC.

**Verify:** `quake guard` + targeted `quake qspec_file FILE=spec/qspec/exec_effect_handlers_spec.qz`.

**Commit:** `[a7/exec] Phase 6: exec recording/replaying test handler factories + spec`

## Hazard map

### H1 — `default_exec_handler`'s `can Reader, Log` row propagating into Quakefile

Quakefile bodies don't carry `can Reader, Log` rows; they rely on
the install at `quake_main()`. The blessed-relaxation chain at
`typecheck_expr_handlers.qz:1664` covers `Reader`(?) — verify on
implementation. If a relaxation gap surfaces, we add `Exec` to the
relaxation chain as a follow-up, but that's a separate question
from this phase's scope and likely unnecessary because tasks
already cleanly call `sh*` today.

### H2 — `sh_maybe` returns raw wait-status, not decoded exit

Documented in Rule 5 above. Verified at `std/quake.qz:215-217`:
`default_exec_handler` populates `ExecResult.exit_code` with the
raw `system(cmd)` return. Downstream `/256` and `band(127)`
arithmetic stays valid.

### H3 — `quake guard` mid-migration churn

Migrating Quakefile.qz changes its content hash. The launcher
cache (`tools/quake.qz`) recompiles the Quakefile on each
content-drift. Expect a recompile per phase, ~few seconds. No
guard-relevant churn (no self-hosted source touched).

### H4 — `colors_disable()` interaction with default_exec_handler

`default_exec_handler:170` reads `ask()` for verbosity and routes
through `log::raw`. The handler's behavior is identical to today's
`sh*` family because all 230 existing `sh*` calls already exercise
that path. No new risk.

### H5 — Audit-count miscategorization at the per-callsite level

The 49-callsite count is correct, but the per-phase split assumes
the categorization above is stable. If a Phase 5 callsite turns out
to need `sh_capture` instead of `sh_maybe` (e.g., the runner is
secretly reading a pipe, not a redirect file), Rule 4 saves us — but
verify each phase against actual source before committing.

### H6 — `feedback_dont_run_ram_heavy_repros.md`

A.7 doesn't run heavy compiles or memory-bound workloads as part of
verification. Smoke targets are small (`quake ufcs:check`,
`quake smoke`, `quake bench_rss` on the lightweight RSS workload).
No RAM hazard.

### H7 — `feedback_quartz_cache_pollution.md`

`rm -rf .quartz-cache` between Quakefile-content-changing commits
if the launcher cache misbehaves. Default behavior is content-hash
based and should self-correct, but the rule applies if anomalies
surface.

### H8 — `feedback_audit_count_inflation.md` — verified clean

49-callsite framing held under verification (vs. inflated counts in
A.1, A.2, A.3-Phase-2, A.4, A.6). Notable because `system(` is a
precise pattern, not a fuzzy concept. No re-categorization needed.

## Calibration note

Audit row claims **3-5 quartz-days**. Recipe-three calibration
(per `feedback_third_effect_cheapest.md`) suggests **~1 quartz-day**
for the Random analog. Exec is even cheaper as a recipe-fourth
because:

1. Effect already declared (Phase 6.2.b shipped).
2. Default handler + dry-run handler already shipped.
3. quake_main() install already wired.
4. No `uses_exec` flag, no signature plumbing, no compiler-source
   migration risk.

Realistic sizing:

- **Phase 1 (snapshot/smoke):** ~15 min / 0.05 quartz-day. 4 sites.
- **Phase 2 (bench/RSS):** ~30 min / 0.1 quartz-day. 8 sites.
- **Phase 3 (fuzz):** ~30 min / 0.1 quartz-day. 12 sites.
- **Phase 4 (REPL/site):** ~10 min / 0.05 quartz-day. 2 sites.
- **Phase 5 (qspec runner):** ~1 hour / 0.25 quartz-day. 14 sites,
  raw-wait-status verification.
- **Phase 6 (handler factories + spec):** ~1.5 hours / 0.5 quartz-day.
  Mirror existing recipe.

**Total realistic: ~1-1.25 quartz-days.** Audit row's 3-5 is
upper-bound for a more aggressive launcher-included scope (filed
as deferred follow-up).

## Definition of done

- `grep -c 'system(' Quakefile.qz` returns **0**.
- `grep -c 'system(' tools/quake.qz` returns **9** (deferred per
  scope decision; documented above).
- New spec at `spec/qspec/exec_effect_handlers_spec.qz` covering
  recording + replaying handlers across the `sh*` surface. All
  green.
- `quake guard` passes between every phase.
- Manual smoke on the most-affected tasks: `quake ufcs:check`,
  `quake smoke`, `quake bench_rss`, `quake fuzz`,
  `quake qspec_file FILE=…` all behave identically pre- vs
  post-migration.
- Roadmap row A.7 marked ✅ SHIPPED with one-line summary +
  detail block matching the A.3 / A.6 / A.8 format.
- Filed `EXEC_LAUNCHER_MIGRATION` follow-up entry with the deferred
  `tools/quake.qz` scope.

## What this unlocks (forward reference)

- **Test isolation for Quakefile authors.** Future contributors can
  spec-test their tasks under `with Exec { exec: exec_recording_handler }
  do -> task_action() end` and assert on the recorded command list
  without forking subprocesses.
- **C.8 substrate.** The remote-executor / Bazel-style build
  orchestration phase (queued as a stretch tier) inherits a
  fully-Exec-routed Quakefile — no per-task migration needed.
- **`quake --dry-run` correctness for the whole repo.** Today,
  `quake --dry-run bench_rss` would fork `measure_rss` despite the
  flag; post-A.7, it logs the cmd and exits success.
