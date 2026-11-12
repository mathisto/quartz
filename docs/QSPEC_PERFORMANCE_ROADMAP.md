# QSpec Performance Roadmap

> Multi-session roadmap to take `quake qspec` from a 24-minute death-march
> into a sub-minute "always green" feedback loop. Last touched 2026-05-11
> night — after Phase 5.0f.a (fsc-trap correctness fix) landed.

## Where we are

**Current baseline (804 specs, 8 workers, macOS 10-core):**

| Run kind | Wall time | Pass rate |
|---|---|---|
| Full suite (subprocess, default) | **24m25s** | 718/804 (86 pre-existing fail) |
| `QSPEC_DAEMON=1` full suite (post-5.0f.a) | **~9 min** projected (~5.4s × 804 / 8 workers) | matches subprocess |
| Slowest single spec | 323s (`https_spec`, TIMEOUT) | — |
| Median spec | ~5–10s | — |

**Status check, 2026-05-11 night:**
- ✅ Compiler-side persistent-worker mode shipped: `quartz --persistent-worker --connect-port=N` (`6aae07a4`).
- ✅ Per-request stderr redirection shipped: `qz_redirect_stderr_to_file` / `qz_restore_stderr` intrinsics + `WorkRequest.stderr_path` (`17313e0b`, Phase 5.0c.1).
- ✅ Runner-side TCP pool + dispatch shipped: `Quakefile.qz` daemon mode opt-in via `QSPEC_DAEMON=1`, plus `tools/quake.qz` launcher fix (`-I self-hosted/shared`) and rebuilt `quake` binary (`a9baf284`, Phase 5.0c.2).
- ✅ **Phase 5.0f.a — fsc-trap correctness fix shipped.** `typecheck_registry::tc_registry_reset_intern_ids` was missing `g_send_checking` / `g_sync_checking` from its reset; first compile freed them, second compile's `vec_free` re-fired on the dangling pointer and `abort()`. 8-line addition lands 30/30 green on the standalone 30-distinct-spec single-worker smoke. Daemon mode is now STABLE for arbitrary N. (Branch `qspec-5-0f`.)
- 🔴 **Phase 5.0f.b — speedup is the remaining work.** With correctness shipped, each compile still pays ~5.4s of stdlib parse + typecheck (matches subprocess). Daemon mode parallelism alone projects to ~9 min on full suite (better than 24m, but well above the <5 min target). The frozen-stdlib base is the load-bearing optimization. **5.0f.b is blocked on the AST-cache mutation invariant fix** (see 5.0f.b section below).

**Where the time goes:** the compiler is ~86% of per-spec wall time
(Phase 0 audit, May 2026). Every `_qspec_run_one` spawns a fresh
`quartz` process, parses + typechecks the full stdlib graph, emits IR,
then llc/clang/lli the result. The actual test logic runs in
microseconds; the dominant cost is **804 cold-start compiler
invocations**.

Plus a long tail of structural waste:

- **7 specs hit the 300s timeout** (network/scheduler — buffered_net,
  https, tls, sched_park, backpressure, broadcast_channel,
  macro_hygiene). 35 minutes of wall time burned on hangs.
- **`assert_run_stdout_eq` spawns fresh compiles per assertion** —
  `std/qspec/subprocess.qz` uses `--no-cache` at 5 call sites. The
  91s `phase_6_1e_middleware_effects_spec` outlier is just 5
  recursive cold-start compiles inside a single spec.
- **Disk cache is unsafe for qspec's workload** — see
  `docs/bugs/CACHE_DIR_CROSS_SPEC_IR_CONTAMINATION.md`. Cross-spec IR
  contamination kicks in around spec ~150, cascades to ~660 SIGSEGVs.
  This is why `--no-cache` is currently the only correct option.
- **Live UI lies** — the "0 running" counter is always zero; users
  can't see which specs are currently in flight.

## What "world-class" looks like

Reference points:

- **`cargo nextest`** (Rust): test-binary isolation, retry-on-flake,
  intelligent partitioning, content-addressed result cache.
- **Bazel test runner**: persistent worker processes (Java compilers,
  protoc, etc.), content-addressable action cache, smart subset
  selection via dep graph.
- **Buck2**: every test invocation is a content-addressed action;
  results cached across runs, across machines.
- **`go test`**: per-package compile cache; tests within a package
  run sequentially by default; explicit `-run REGEX` for targeting.

Common patterns:

1. **Don't pay process-spawn cost per test** — reuse a long-running
   worker.
2. **Don't run the same test twice if nothing changed** — hash inputs,
   cache the pass/fail outcome.
3. **Don't even consider tests outside the dep cone of changed files** —
   trim the candidate set before scheduling.
4. **Always know what's running** — honest live UI, no lying counters.

Quartz already has the substrate for (1) — Phase 5.0a/5.0b shipped the
compiler-side `--persistent-worker` mode. The runner side hasn't
landed. Items (2), (3), and (4) build on (1).

## The phases

### QSPEC.1 — Persistent worker runner (Phase 5.0c) — INFRASTRUCTURE SHIPPED ✅

**Status:** Runner + compiler + launcher all landed. The persistent-worker
TCP pool, request/response framing, per-worker stderr redirection, and
two-phase pool shutdown are all wired and verified for protocol-path
correctness on small subsets. **The speedup itself awaits 5.0f.**

**Shipped on trunk:**
- `6aae07a4` (5.0b) — `quartz --persistent-worker --connect-port=N` compiler-side, length-prefixed JSON over TCP loopback.
- `17313e0b` (5.0c.1) — `qz_redirect_stderr_to_file` + `qz_restore_stderr` intrinsics. `WorkRequest.stderr_path` field. Uses `fopen("w") + fileno + dup2` for portability (raw `open` flag values diverge macOS 1537 vs Linux 577). Fixpoint 2334 fns.
- `a9baf284` (5.0c.2) — Runner-side TCP pool in `Quakefile.qz` (+360 LOC, opt-in `QSPEC_DAEMON=1`). `sched_init(num_workers * 2 + 2)` to avoid `posix_spawn_wait` goroutine starvation. Two-phase pool shutdown (send-shutdown-then-close-all THEN await-all) avoids pairing-induced deadlock from index-paired accept ordering. `tools/quake.qz` launcher gains `-I self-hosted/shared` so Quakefiles can `import * from persistent_worker_protocol`. `quake` binary rebuilt.

**Why this is "shipped infrastructure, not yet a speedup":** see the next phase.

### QSPEC.1.5 / Phase 5.0f.a — fsc-trap correctness fix ✅ SHIPPED

**Status:** ~~LOAD-BEARING~~ → ✅ shipped 2026-05-11 night on `qspec-5-0f` branch.

**The empirical fsc-trap (reproduced + ROOT-CAUSED 2026-05-11):**
- Symptom: 3 compiles per persistent worker OK ~5s each → 4th compile 💥 SIGSEGV/SIGABRT ~340ms in.
- lldb backtrace: `abort → malloc_vreport → ___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED → tc_registry_free_intern_ids+1812 → compile+67624 → do_build+8100 → _pworker_compile+2260`.
- Root cause: `tc_registry_free_intern_ids` (typecheck_registry.qz:73) freed 8 module-level globals; `tc_registry_reset_intern_ids` (same file, line 62) only reset 6 of them. `g_send_checking` and `g_sync_checking` were freed at end of compile-1 then never re-bound — compile-2 pushed to a dangling pointer, compile-2's `vec_free` aborted with "pointer being freed was not allocated".
- The "request 4" threshold is a function of how many sibling `vec_free`s succeed first before macOS malloc's free-list-walk notices the corruption — not anything intrinsic about request count. With my reproducer fixture (`def main(): Int = 0`) the threshold varied 2–4 across runs; sister `qspec-perf` worktree saw 2 at ~60% flake. Same bug.

**Fix (8 lines):**

```qz
# self-hosted/middle/typecheck_registry.qz:62-79 (after fix)
def tc_registry_reset_intern_ids(): Void
  g_struct_name_ids = vec_new()
  g_enum_name_ids = vec_new()
  g_func_name_ids = vec_new()
  g_trait_name_ids = vec_new()
  g_impl_trait_name_ids = vec_new()
  g_impl_for_type_ids = vec_new()
  g_send_checking = vec_new<String>()     # <-- added 5.0f.a
  g_sync_checking = vec_new<String>()     # <-- added 5.0f.a
end
```

Idea is general: every global freed by `tc_registry_free_intern_ids` must be re-bound here.

**Verification:**
- `spec/qz/persistent_worker_compile_smoke.qz` (5-compile fixture): 5/5 OK, byte-identical IR across requests.
- `spec/qz/persistent_worker_30spec_smoke.qz` (30 distinct alphabetical specs): 30/30 OK, ~5.4s avg per compile.
- Fixpoint preserved (`quake guard` PASS, 2334 functions).
- Canonical smokes (`style_demo`, `brainfuck`): both PASS.

**What this unlocks:**
- Daemon mode is STABLE — full suite runs feasible. Projected wall time ~9 min vs 24m25s subprocess (8-worker parallelism only, no per-spec speedup).
- The "must keep daemon mode opt-in due to crash risk" caveat from 5.0c.2 is gone.

**What this does NOT unlock:**
- The <5 min wall-time target. Each compile still pays the full ~5.4s stdlib parse + typecheck cost. The frozen-stdlib base optimization is needed; see 5.0f.b.

### QSPEC.1.6 / Phase 5.0f.b — Frozen-stdlib base + AST-cache mutation invariant 🔴 LOAD-BEARING FOR SPEEDUP

**Status:** Blocked on an architectural fix to the AST-cache mutation invariant. Discovered while attempting the frozen-base optimization 2026-05-11 night.

**The architectural smell (discovered 2026-05-11):**

`shared/build_cache::cache_save_ast` is called from `resolver.qz:404` *inside* `resolve_load_module`, BEFORE the mutation passes that act on the same AST (`resolve_collect_funcs` line 452, `resolve_desugar_*` lines 448-450, and pass-2 `resolve_rewrite_calls` from `resolve_imports` line 2758). The saved-state-vs-loaded-state asymmetry:

- **Disk cache:** save serializes to .bin files (immutable snapshot). Load deserializes to a fresh in-memory AST with the original str1 values. Mutations don't carry across processes. Also the disk path explicitly skips modules with NODE_FUNCTION (34) / NODE_LAMBDA (19) / NODE_ENUM_ACCESS (39) / NODE_TRAIT_DEF (50) / NODE_IMPL_BLOCK (51) / NODE_EXTEND_BLOCK (52) / NODE_TYPE_ALIAS (64) / NODE_NEWTYPE (65) — practically every stdlib module, so the bug is rarely-if-ever exercised.
- **In-memory cache** (`std/cache::cache_in_memory_handler`): save records the AST *handle*. Subsequent mutation passes continue to mutate that handle's contents. The next compile loads the *post-mutation* AST and re-runs the mutation passes on it.

Non-idempotent mutation sites identified during the attempt:
1. `resolve_collect_funcs`: NODE_GLOBAL_VAR (49) — `resolve_build_name(prefix, base_name)` blindly prefixes; second compile double-prefixes.
2. `resolve_collect_funcs`: NODE_CONST_DECL (69) — same.
3. `resolve_collect_funcs`: NODE_IMPL_BLOCK (51) inherent — `ast_set_left(method, [self_param, ...old_params])` prepends self; second compile appends another self, breaking arity.
4. `resolve_collect_funcs`: NODE_EXTEND_BLOCK (52) — same self-prepend pattern.
5. Typecheck side — at least one issue ("Cannot call 'f': not a function" in `std/progress.qz` line 1090 across cached compiles), suggests stale type-param info in the typecheck registry. Not traced.

Patching the 4 resolver sites (idempotency guards via `resolve_has_prefix` / first-param-is-self checks) advanced the failure mode forward by one stage but didn't reach 30/30. The remaining typecheck-side issue makes (A) whack-a-mole; we backed out and chose the structural fix.

**The world-class fix options:**

| Option | Scope | Memory | Risk |
|---|---|---|---|
| (A) Patch every non-idempotent mutation in collect + desugar + tc registry | ~150-200 LOC across files | low | high (latent sites keep appearing) |
| (B) Move cache_save_ast to AFTER all pass-1 + pass-2 mutations; gate mutation passes with a `processed` set | ~50-100 LOC | low | medium |
| (C) Deep-copy AST at cache_save_ast time (`ast_clone()`) so the snapshot is immutable from the consumer's view | ~100-150 LOC | 2× per cached module | medium |
| (D) Lift parse out of resolve_load_module entirely; ParserService produces immutable ASTs; downstream passes consume them and emit derived data without mutating the AST | 300-500 LOC | low | high (touches multiple phases) |

**Decision deferred** to the next session with measured wall-time data on the post-5.0f.a daemon-mode baseline. The trade-off between (B) and (C) is unclear without that data — if 9 min projected drops faster than expected once daemon mode is exercised at scale, the speedup gap may be small enough that (D)'s scope isn't justified.

**Acceptance for 5.0f.b:**
- `QSPEC_DAEMON=1 quake qspec` (full suite, 804): wall time **under 5 minutes**.
- Pass/fail count unchanged from baseline (718/804).
- Daemon mode flipped to default ON in `Quakefile.qz`.
- AST mutation invariant ("cached AST is read-only from the consumer's view") established and documented; ALL mutation sites either inside an idempotency guard, or moved before the cache save, or operating on a deep-copied clone.

**Three load-bearing gotchas inherited from 5.0c.2 (don't re-trip):**
1. **`sched_init(N)` deadlock from blocked goroutines.** Quartz's goroutine scheduler binds goroutines to pthreads; `posix_spawn_wait`-holding goroutines never yield. Daemon-mode spawn fans out N goroutines that all park on `posix_spawn_wait` → if `N >= sched_init_pool_size`, the scheduler starves and nothing else runs. Fix already in trunk: `sched_init(num_workers * 2 + 2)` in daemon mode. Filed: `feedback_sched_init_long_blocked_goroutine_starvation.md`.
2. **Two-phase pool shutdown.** `accept[i]` and `spawn_handles[i]` are paired by index, but accept ordering is non-deterministic vs spawn ordering. A single-loop `send_shutdown(streams[i]); await(handles[i])` deadlocks. Must drain ALL streams (send-shutdown + close), THEN await ALL handles.
3. **`tools/quake.qz` `-I` extension is project-conditional.** The launcher only adds `-I project_dir/self-hosted/shared` when that directory exists, so Quartz-repo Quakefiles can `import * from persistent_worker_protocol` without per-task `-I` plumbing while leaving other quake-using projects unaffected. Don't generalize — the path is intentionally Quartz-specific.

**One additional gotcha discovered in 5.0f.a's frozen-base attempt:**
4. **`std/cache::cache_in_memory_handler` and `cache_disabled_handler` had wrong miss sentinels.** Both returned `as_int(vec_new())` (size-0 Vec) on `cache_op_load_ast` miss; resolver indexes `[0]` unconditionally and crashes with "index out of bounds". Correct sentinel is `[0, 0]` (mirror `build_cache::cache_load_ast`). Latent bug — the handlers were unused before the frozen-base attempt. Both miss-sentinel fixes were reverted with the rest of the speculative changes; **re-land them as part of 5.0f.b** so the handlers are usable when the broader frozen-base wiring lands. Site: `std/cache.qz` line ~199 (in_memory) and line ~232 (disabled).

### QSPEC.2 — Sub-compile reuse

**Goal:** route the `assert_run_stdout_eq` / `assert_compile_error` /
fuzz-oracle sub-compiles through the same persistent worker pool, so
specs that exercise compile-error paths don't pay 5× the cold-start
cost.

**Why:** `phase_6_1e_middleware_effects_spec` is the canary — it
takes 91s today, almost entirely because of 5 nested `assert_run_*`
calls each spawning a fresh `quartz` process. Same pattern in
`fuzz/oracle.qz`, `intern_effect_p55a_spec`, etc.

**Surface area:**
- `std/qspec/subprocess.qz`: 5 `--no-cache` call sites
- `std/fuzz/oracle.qz`: 6 `--no-cache` call sites
- Both currently shell out via `sh_capture` / `posix_spawn_wait`

**Path:** introduce a `qspec_subprocess::compile_via_worker(source,
flags)` helper that pings the runner's listener (via an env-passed
port) and gets compiled IR + diagnostics back. Fall back to
`--no-cache` shell-out if no worker port is set (so subprocess specs
still work outside the qspec runner — e.g., manual `quartz` calls).

**Acceptance:**
- `phase_6_1e_middleware_effects_spec`: 91s → under 5s.
- No spec exceeds 30s under steady state (other than the QSPEC.3
  timeout-fix targets).

### QSPEC.3 — Eliminate the 300s tail

**Goal:** no spec exceeds 60 seconds. Audit the 7 timeouts; either
fix the hang or split the spec into bounded smaller cases.

**Current tail (each at 300s timeout):**
- `https_spec` — TLS connection setup, likely networking hang
- `buffered_net_spec` — buffered I/O patterns
- `tls_spec` — TLS handshake
- `sched_park_spec` — scheduler park/wake interactions
- `backpressure_spec` — channel backpressure
- `broadcast_channel_spec` — known pre-existing hang under qspec
  lambda (per `feedback_broadcast_channel_spec_pre_existing_hang.md`)
- `macro_hygiene_spec` — likely fixed-point or expansion loop

**Approach per-spec:**
1. Reproduce in isolation (single-spec `quake qspec_file`).
2. If genuinely slow (real protocol delay), split into a smaller
   smoke + a separate `slow_spec` opt-in subset.
3. If hanging on a known issue (broadcast_channel — async wake), file
   under `docs/bugs/` if not already, skip with `it_pending`, attach
   the smoke to `spec/qz/` outside the qspec runner.

**Acceptance:**
- Default `quake qspec` has NO spec >60s.
- Audited specs are either: fixed, skipped (with rationale), or
  split into bounded + opt-in slow variants.

### QSPEC.4 — Honest progress UI

**Goal:** at any moment during a run, the user can answer "what is
currently executing?" without reading thousands of lines of stderr.

**Current state lies:**
- "X running" counter is always 0 (bars are only added to Live on
  completion, never in a true running state).
- No per-worker view — N workers grinding for 5s each look identical
  to one worker hung for 35s.
- Slowest list shows up only AFTER the suite finishes.

**Path:** restructure the qspec runner's Live integration so that:
- Each worker has a dedicated row showing the current spec + elapsed.
- The global header shows accurate `done/failed/running/queued`
  counts.
- A rolling "Top 5 slowest in-flight" panel updates every second.

**Acceptance:**
- Mid-run snapshot tells you which specs are executing on which
  workers, with elapsed time per spec.
- Ctrl+C produces a clean summary (already mostly works after
  `7829e705`, but verify under the new UI).

### QSPEC.5 — Content-addressed result cache

**Goal:** unchanged specs don't re-run. Second `quake qspec` in a
row should be near-instant.

**Design:**

```
cache key = SHA256(
  compiler_binary_hash         # self-hosted/bin/quartz
  spec_source_hash             # spec file content
  dep_file_hashes              # transitive deps via --emit-deps
  compiler_flags               # --no-opt, --debug, target, etc.
)

cache entry = {
  outcome: PASS | FAIL | SKIPPED,
  reason: String,
  captured_output: String,
  file_time_ms: Int,
  recorded_at: timestamp,
}
```

Stored under `.quartz-cache/qspec-results/<key>.json`. Runner looks
up before dispatching; only cache misses run.

**Why this works:** Quartz is deterministic — same compiler binary +
same inputs → same output IR → same test outcome. Flake-prone tests
(timing/scheduler-sensitive) skip the cache via an explicit marker
(see Phase 4 of `project_qspec_runner_parallel.md`).

**Caveats:**
- Cache invalidation on compiler binary change is mandatory — gates
  on `self-hosted/.fixpoint` `binary_hash`. (Trivial.)
- Result-capturing must include stderr (for assert_compile_error specs).
- Be paranoid about false-positive cache hits — first implementation
  must include a `--no-cache-results` escape and a sanity sample
  (run 5% randomly even on hit, compare).

**Acceptance:**
- Cold run: same as QSPEC.1 baseline (~5 min).
- Warm run (no source changes): **under 30 seconds** — just cache
  lookups + the flake-marked specs that opt out.

### QSPEC.6 — Smart subset selection

**Goal:** editing one stdlib file runs only the specs whose dep cone
touches it.

**Substrate:** `quartz --emit-deps PATH` already exists. The persistent
worker's first request per spec records the dep graph.

**Path:** build a `spec → {dep files}` index. On `quake qspec
--changed`, intersect the changed-files set with each spec's deps;
run only specs in the affected set. Auto-mode triggers if `git diff
--name-only HEAD` is non-empty.

**Acceptance:**
- Edit `std/sync/mutex.qz`: only mutex-touching specs run (~10
  specs, completes in <5s on warm worker pool).
- Edit nothing: equivalent to QSPEC.5 warm-run (~30s).
- Edit `std/prelude.qz`: full suite (because everything imports it).

### QSPEC.7 — Watch mode

**Goal:** edit-to-feedback loop measured in seconds, not minutes.

**Design:**
- `quake qspec --watch` runs once cold, then waits.
- Filesystem watcher (kqueue/inotify via std) detects source changes.
- On change: QSPEC.6 subset selection → QSPEC.5 cache lookup → QSPEC.1
  persistent worker dispatch. Surgical re-run.

**Acceptance:**
- Edit any spec file: PASS/FAIL within 2 seconds of save.
- Edit a stdlib file: scoped re-run completes within 5 seconds.

## Sequencing

```
5.0c (✅) → 5.0f.a (✅) → 5.0f.b (🔴 next) ──┬─► QSPEC.2
                                            │
                                            ├─► QSPEC.5 ──► QSPEC.6 ──► QSPEC.7
                                            │
                                            ├─► (parallel) QSPEC.3
                                            │
                                            └─► (parallel) QSPEC.4
```

5.0c shipped the runner+protocol scaffolding. 5.0f.a (just landed) made
daemon mode STABLE — correctness gate complete. **5.0f.b is the
load-bearing fix that turns daemon mode from "stable but
subprocess-equivalent per-spec cost" into an actual speedup.** QSPEC.3
and QSPEC.4 are independent and can land in any order. The .5 → .6 → .7
chain has hard dependencies.

## Out of scope

- **Fixing the disk cache** (`CACHE_DIR_CROSS_SPEC_IR_CONTAMINATION`).
  Persistent worker sidesteps the disk-cache entirely by keeping state
  in-memory across requests. The compiler-side cache bug remains
  filed but doesn't block this roadmap.
- **WASM-backend specs** — they have their own perf surface (separate
  toolchain). Audit deferred.

## How to start

A separate worktree is mandatory — main trunk has unrelated work in
flight. See the handoff prompt in this directory for the boot
sequence and acceptance gates per phase.
