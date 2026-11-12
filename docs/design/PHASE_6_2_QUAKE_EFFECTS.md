# Phase 6.2 — Quake build tool, effect-first

> **Epic**: Operation Piezoelectric Effects · `[piezo]` · Phase 6 (user-tool dogfooding)
> **Sibling**: [`PHASE_6_1_HTTP_EFFECTS.md`](PHASE_6_1_HTTP_EFFECTS.md) (the headline migration; ships first)
> **Status**: Design — implementation queued behind 6.1.
> **Filed**: 2026-04-25, on closure of Phase 4D.
> **Estimate**: 1-2 quartz-days, 3 commits.

## Why this memo exists

Phase 5 dogfooded effects on **compiler internals** (Diag, State, Emit, FileIo, Intern). Those are serial-per-phase machinery — exactly one effect frame at a time per pass. Phase 6 dogfoods effects on **user-shaped tools** that ship with Quartz, where the shape is different: subcommand dispatchers, build orchestration, command execution with pluggable backends.

Quake is the smaller of the Phase 6 migrations. It has no concurrent-effect-frame requirement (unlike the HTTP server) and no DSL design space to invent (the existing `task("name", "desc") do ... end` shape is already Sinatra-like and beloved by the user). The migration is a pragmatic ergonomic upgrade, not a novel-shape exploration.

Three real wins on the table:

1. **Free `--dry-run`**: every command goes through one `Exec` effect. Wrap with `with Exec { exec: dry_run } do -> quake_main() end` and you have a dry-run mode in one line. Today: would require parallel code paths in every `sh`/`sh_capture`/`sh_buffered`.
2. **Threaded verbosity without globals**: `_verbose: Int` global is replaced by `Reader<Verbosity>` install at the top of `quake_main`. Per-task verbosity overrides via nested `with Reader<Verbosity>(2) do -> task_action() end`. Tests can install captured verbosity for assertion.
3. **Errors that compose**: `_quake_fail() -> exit(1)` becomes `throw BuildError::CommandFailed(cmd, exit_code)`. `quake test` can collect all failures and exit at the end instead of dying on the first failed spec.

## What's there today (audit)

`tools/quake.qz` (491 LOC launcher) + `std/quake.qz` (794 LOC runtime) = 1,285 LOC total.

| Concern | Current shape | Effect-shape candidate |
|---|---|---|
| Command exec | `sh()`/`sh_capture()`/`sh_buffered()` wrap `system()` + `pipe_open()` directly | `Exec` effect with `exec(cmd: String, opts: ExecOpts): ExecResult` op |
| Verbosity | Global `_verbose: Int` checked inline in `sh()` (line 101-108) | `Reader<Verbosity>` installed at `quake_main` entry; `should_print()` reads it |
| Failure | `fail(msg) -> _quake_fail(msg) -> exit(1)` (line 576-585) | `Throws<BuildError>`; default handler prints + exits, but tests can override |
| File I/O | `glob()`, `read_file()`, `write_file()`, `mkdir()` direct | Already covered by `FileIo` from Phase 5.4; install at `quake_main` entry |
| Logging | `_print_cmd()`, ad-hoc `puts()` in 7-8 sites | `Log` effect (already shipped); install at `quake_main` entry |
| Task dispatch | Recursive walk + memoized `_executed` Vec | Stays as-is; not effects-shaped |

The dispatch / task-dependency / Quakefile-DSL pieces stay. The cross-cutting concerns (verbosity, exec, errors) move to effects.

## DSL impact (or lack thereof)

The user-facing Quakefile syntax is unchanged. Today:

```be
task("test", "Run all tests") do ->
  sh("./self-hosted/bin/quake qspec")
  sh("./self-hosted/bin/quake format_check")
end

task_dep("ci", "Full CI pipeline", vec_of_str("test", "lint")) do ->
  puts("CI passed")
end
```

After Phase 6.2:

```be
task("test", "Run all tests") do ->
  sh("./self-hosted/bin/quake qspec")
  sh("./self-hosted/bin/quake format_check")
end

task_dep("ci", "Full CI pipeline", vec_of_str("test", "lint")) do ->
  puts("CI passed")
end
```

**Identical.** That's the point. The user doesn't write `Exec`, `Reader<Verbosity>`, or `Throws<BuildError>` — those are framework-internal. The user writes `sh(...)` exactly like before, but `sh()`'s implementation is now a one-line `exec(cmd, ExecOpts::default())` call against the `Exec` effect.

What CHANGES for the user is what they can do externally:

```be
# Dry-run the entire build pipeline (showing commands, executing nothing)
with Exec { exec: dry_run_handler } do -> quake_main() end

# Verbose mode programmatically
with Reader<Verbosity>(2) do -> quake_main() end

# Test harness: collect errors instead of exiting
var errors: Vec<BuildError> = vec_new()
with Throws<BuildError> { Throw: e -> errors.push(e) } do -> quake_main() end
```

These are NEW capabilities, not migrations.

## Effect surface

Three effects added (or extended for Quake's use):

```be
# 6.2.a — verbosity
# Reader<Int> already exists from Phase 2; just installed at quake_main entry.

# 6.2.b — pluggable command execution
struct ExecOpts
  capture_stdout: Bool
  capture_stderr: Bool
  ignore_failure: Bool       # don't throw on non-zero
  step_name: String          # for sh_buffered's step-banner UX
end

struct ExecResult
  exit_code: Int
  stdout: String
  stderr: String
end

effect Exec
  def exec(cmd: String, opts: ExecOpts): ExecResult
end

def default_exec_handler(cmd: String, opts: ExecOpts): ExecResult
  # Today's sh()/sh_capture()/sh_buffered() implementations folded into one,
  # branching on opts. Default handler installed by quake_main.
  ...
end

def dry_run_handler(cmd: String, opts: ExecOpts): ExecResult
  log("would exec: " + cmd)
  return ExecResult { exit_code: 0, stdout: "", stderr: "" }
end

# 6.2.c — typed errors
enum BuildError
  CommandFailed { cmd: String, exit_code: Int, stderr: String }
  TaskNotFound { name: String }
  CircularDependency { task: String }
  AssertionFailed { msg: String }
  IOError { path: String, msg: String }
end

# Throws<BuildError> already exists; default handler prints + exits.
```

`sh()`, `sh_capture()`, `sh_buffered()`, `sh_quiet()`, `sh_maybe()` all become thin wrappers over `exec(cmd, opts)` with different `ExecOpts`.

## Phase plan

Three subphases. Each ships independently with `quake guard` fixpoint-byte-identical.

### 6.2.a — Reader<Verbosity> + Log effect installs (~0.5 quartz-day)

**Goal**: replace global `_verbose` with `Reader<Verbosity>`. Replace ad-hoc `puts()` with `log()` call (Log effect already shipped from Phase 5).

**Changes**:
- `std/quake.qz`: delete `_verbose` global. `quake_main()` parses `--verbose` / `--quiet` from argv at entry, opens `with Reader<Verbosity>(level), Log { log: stdout_logger } do -> dispatch_task() end`. ~30 LOC delta.
- All 7-8 `if _verbose >= 1: ...` sites replaced with `if reader_get() >= 1: log(...)`. Mechanical.

**Spec**: `spec/qspec/phase_6_2a_quake_verbosity_spec.qz` — invokes `quake_main()` programmatically with various verbosity levels via `with Reader<Verbosity>` overrides; asserts on captured Log output.

**Verify**: `quake build` + `quake qspec` + `quake format_check` all behave identically. Fixpoint guard byte-identical.

**Risk**: low. Mechanical replacement of one global with one effect; behavior preserved.

### 6.2.b — Exec effect + pluggable executors (~0.5-1 quartz-day)

**Goal**: introduce `Exec` effect; migrate `sh*` family to delegate through it. Ship `dry_run_handler` as a stdlib helper.

**Changes**:
- `std/quake.qz`: add `effect Exec` declaration + `ExecOpts`/`ExecResult` structs + `default_exec_handler` (~80 LOC). Migrate `sh()`/`sh_capture()`/`sh_buffered()`/`sh_quiet()`/`sh_maybe()` to single-line wrappers over `exec(cmd, opts)` (~40 LOC reduction, since shared logic is in the default handler now). Install `with Exec { exec: default_exec_handler } do -> ... end` at `quake_main()` entry.
- New: `dry_run_handler` in `std/quake.qz` — logs intended command via Log effect, returns success.
- `tools/quake.qz`: add `--dry-run` flag at launcher level; if set, install `with Exec { exec: dry_run_handler }` around `quake_main()`. ~10 LOC.

**Spec**: `spec/qspec/phase_6_2b_quake_exec_spec.qz` — runs Quakefile tasks under `with Exec { exec: capture_handler }`, asserts on captured commands. Tests that `--dry-run` doesn't actually execute anything.

**Verify**: Quakefile's `quake test` runs identically (default handler same shape); `quake test --dry-run` prints commands without executing them. Fixpoint guard byte-identical.

**Risk**: medium. The `sh_buffered` handler has subtle semantics (stderr capture to tempfile, step-banner UX) that need to migrate cleanly into the default handler. Mitigation: ship 6.2.b BEFORE 6.2.c so the error-shape work doesn't compound.

### 6.2.c — Throws<BuildError> + collected-error mode (~0.5 quartz-day)

**Goal**: replace `_quake_fail() -> exit(1)` with `throw BuildError::*`. Default handler does what `_quake_fail` did (print + exit). Tests / future "collect mode" can override.

**Changes**:
- `std/quake.qz`: define `enum BuildError` (~15 LOC). Replace ~6 `fail()` / `_quake_fail()` sites with `throw BuildError::*`. Default handler installed at `quake_main()` entry: prints message + exits 1 (semantic preservation).
- New: `quake test --keep-going` flag at launcher level. Installs a custom Throws handler that collects errors into a Vec and prints them all at the end.
- `Quakefile.qz`: nothing changes (the `task` body just calls `sh(...)` and never sees the error path).

**Spec**: `spec/qspec/phase_6_2c_quake_throws_spec.qz` — programmatically invoke a deliberately-failing task under `with Throws<BuildError> { Throw: collect } do -> ... end`, assert errors aggregate.

**Verify**: existing `quake` invocations with default handler exit on first failure exactly as before. New `--keep-going` mode runs to completion. Fixpoint guard byte-identical.

**Risk**: low. The exit-on-failure semantics are unchanged for the default path; new capability is additive.

## Success criteria

Concrete, falsifiable:

- [ ] `quake build` + `quake qspec` + `quake format_check` + `quake guard` produce **byte-identical output** pre- vs post-migration.
- [ ] `quake test --dry-run` runs to completion executing zero subprocess commands.
- [ ] `quake test --keep-going` aggregates errors and exits with non-zero only after running all tasks.
- [ ] `_verbose` global no longer exists in `std/quake.qz`.
- [ ] LOC delta net-negative or within +50 LOC (the `Exec` infra adds ~80 LOC; the `sh*` consolidations save ~40 LOC; the error refactor saves ~30 LOC; net ≈ +10 LOC, well within tolerance).
- [ ] 3 new specs (6.2.a/b/c), each ~6-8 tests, all green.
- [ ] Fixpoint byte-identical at every commit.

## Risks & mitigations

### R1 — `sh_buffered`'s step-banner semantics

Today `sh_buffered(cmd, step_name)` prints a colored "▸ <step_name>" header before the command and a "✓"/"✗" marker after. This is UI, not effect logic. Migration: bake it into the default `Exec` handler when `opts.step_name != ""`. Custom handlers (dry-run, capture) ignore step_name.

### R2 — `system()` interaction with Exec effect kind

`exec` op needs to be a kind=2 effect (synchronous, returns a value). Today `system()` blocks the calling thread. Migration: keep this; don't try to make it async/kind=3 yet (that's Phase 6.2's non-goal — async builds are Tier 5).

### R3 — Reader<Verbosity> default-handler install ordering

`Reader<Verbosity>` install must wrap EVERYTHING after argv parsing. Easy to get wrong if some early init (like `task()` registration in Quakefile loading) happens outside the install. Mitigation: install IMMEDIATELY after argv parse, before Quakefile compile/eval. Spec asserts that `task()` calls during Quakefile load see the installed Reader.

### R4 — The implicit Yield / handler-stack-cap interaction

Phase 5.4 hit the 32-stack-cap bug; Phase 6.2 nests another 3 effects (Reader, Exec, Throws) inside the existing FileIo + Log + Diag stack. Need to verify the 256-cap (set by `a6f174ae`) is still comfortably above this workload. Mitigation: add a stack-depth assertion in the default Log handler that warns if depth approaches 200.

## Non-goals (deferred)

- **Async / parallel builds** (e.g., `quake build:separate` tasks running in parallel). Tier 5; orthogonal to effect migration.
- **Remote executor** (e.g., distributed Bazel-style build). Real future work; the `Exec` effect is the substrate, but the implementation is its own multi-week initiative.
- **Quake Quakefile-language extensions** (DSL changes to `task` syntax). Out of scope.
- **Migrating the launcher (`tools/quake.qz`) too aggressively**. The launcher is mostly argv parsing + content-hash invalidation; effects don't help there.

## Sequencing

| Phase | Status | Goal |
|---|---|---|
| 6.1.a-e | (queued) | HTTP server effect-first migration |
| **6.2.a** | **next after 6.1** | Reader<Verbosity> + Log installs |
| **6.2.b** | (queued) | Exec effect + dry-run handler |
| **6.2.c** | (queued) | Throws<BuildError> + --keep-going |

Phase 6.2 ships AFTER Phase 6.1 because: (a) HTTP is the higher-value migration; (b) Quake's migration would change the very `quake` binary used to build Quartz, so doing it during 6.1 introduces tooling instability; (c) the patterns 6.1 establishes (default-handler-at-entry, capture-handler-for-test) inform 6.2's implementation.

## References

- [`PHASE_6_1_HTTP_EFFECTS.md`](PHASE_6_1_HTTP_EFFECTS.md) — sibling memo for the HTTP migration; same "default handler at entry + scoped overrides" pattern.
- [`EFFECT_MIGRATION_PLAYBOOK.md`](EFFECT_MIGRATION_PLAYBOOK.md) §3.4 — bridge-over-cascade pattern; applicable to Quake's `Exec` migration if `sh*` callers want to stay non-`can`-annotated.
- [`PHASE_5_GENERATORS_RETRO.md`](PHASE_5_GENERATORS_RETRO.md) (if filed) — Phase 5's lessons on default-handler discipline, applied at Quake-level.
