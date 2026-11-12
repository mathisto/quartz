# quartzd — Long-lived Compile Daemon for Quartz

> Design memo. Decisions before code.
>
> **Status:** Filed 2026-05-10. Phase 5 of the QSPEC_RUNNER_ARCH sprint.
> The empirical foundation: with `--no-cache` and the worker pool from
> Phase 1, `quake qspec` parallelizes correctly (2.95× on string\_\*) but
> per-spec compile time is unchanged at ~5s, dominated by stdlib
> parse + typecheck + MIR-lower (86% of wall time per the Phase 0
> audit). The Phase 1 followup `--cache-dir` flag (`b790cc1f`) shipped
> as daemon-mode infrastructure but cannot be used directly for
> per-worker caching: the existing dep_graph + manifest machinery
> *thrashes* across different `main()` programs (sequential cache:
> 4.7s → 9.1s → 9.0s → 9.4s → 11.5s vs `--no-cache`: 4.78 → 4.96 →
> 4.80 → 5.04 → 5.13). The architectural answer is a long-lived
> daemon that keeps stdlib parsed-and-typechecked in memory and
> serves N independent compile requests from a worker pool.
>
> **Source for shape:** three parallel research dives surveyed Bazel
> persistent workers, Bloop, scalac fsc, Gradle daemon, sbt server,
> Nailgun, Roslyn / VBCSCompiler, Cling, GHC API, Swift module cache,
> Merlin, rust-analyzer + Salsa, Buck2 + DICE, Pants, Mill, Cargo's
> incremental cache, Bazel's two-layer split, Turborepo. Convergent
> recommendations are baked into the decisions below; full reports
> live in the 2026-05-10 session conversation.

## Why now

The qspec runner's per-spec compile is the next 86% to attack. Phase
1 shipped the worker pool; Phase 1' shipped `posix_spawn_wait`;
Phase 1'' fixed eager-pre-poll; Phase 1.5 (per-worker cache) was
empirically falsified. Without daemon mode, the runner's wall-time
floor is `(stdlib_parse_cost / num_workers) + per_spec_unique_work` —
roughly 100s for 787 specs at 8 workers, plus llc + clang + run.

Daemon mode amortizes `stdlib_parse_cost` to *one* parse per worker
process across all 787 requests. Realistic outcome: full suite
under 60s, possibly under 30s.

## Convergent research findings

Three independent research dives across ~30 prior-art tools agreed
on five points:

1. **Bazel's persistent-worker protocol is the de-facto standard.**
   Length-delimited messages over stdin/stdout. `request_id` field
   for cancellation. Worker is just a child process invoked with a
   `--persistent-worker` flag that loops reading requests. JVM-based
   adapters exist for Java, Scala, Kotlin, Rust, Swift. Adoption =
   ecosystem familiarity for any future quartzd integration.

2. **Per-request isolation, NO shared mutable state across mains.**
   The single most-cited footgun. scalac fsc died because it shared
   one symbol table across compiles → phantom errors that vanished
   on `fsc -reset`. Quartz's `b790cc1f` empirical finding is the same
   disease: the dep_graph manifest growing across requests
   produces cumulative reconciliation cost. The daemon's state must
   be the *immutable, content-addressed* parsed stdlib, NOT the
   per-program state. This is the fsc trap.

3. **Two-layer cache split.** Bazel's analysis cache (in-memory,
   graph-shaped, fragile) vs. execution cache (on-disk,
   content-addressed, durable) want different shapes and lifetimes.
   For quartzd: in-memory parsed/typechecked stdlib in workers +
   on-disk content-addressed module IR cache (the existing
   `.quartz-cache/modules/` machinery, just keyed by content hash
   without the dep_graph layer).

4. **Cancellation from day one, but use the simple model.** Salsa's
   panic-unwind cooperative cancellation (rust-analyzer) is load-
   bearing for editor latency; for batch test runs, process-level
   cancellation is sufficient. SIGTERM the worker, replace from
   pool. Quartz's existing scope-cancellation infrastructure (B.7)
   handles in-worker cleanup naturally.

5. **Aggressive recycle policy.** Quartz cold-start is cheap (no
   Hotspot warmup), so recycling workers every N requests or on
   stdlib-SHA mismatch eliminates the "long-lived daemon
   accumulates state corruption" failure mode that bites Bloop and
   Gradle weekly. This is an asymmetric structural advantage Quartz
   has over JVM-based daemons.

## Locked design decisions

### D1. Process model: qspec runner IS the daemon

**Revised 2026-05-10 (post-survey):** the original design called for
a separate `quartzd` binary listening on a Unix domain socket. After
surveying std/, I found std/json.qz is solid but no AF_UNIX wrapper
exists yet — building one is its own ~200 LOC mini-project. More
importantly, **the per-suite lifecycle (D6) means there's only ever
one client**, the qspec runner itself. So there's no multi-client
benefit to the daemon-as-separate-process shape; we get all the wins
of daemon mode by having the runner directly spawn its worker pool
and talk to them over pipes — Bazel's exact pattern, sans socket.

The qspec runner spawns `min(num_cpus, 16)` worker subprocesses via
`posix_spawn`, each running `quartz --persistent-worker`. Each
worker has stdin (request channel) and stdout (response channel)
pipes connected to the runner. Workers pre-parse the stdlib at
startup so the first real request gets warm-cache speed.

Rejected: in-process workers (one daemon, threads do compiles).
Quartz's current compiler isn't reentrant — module-level state in
`build_cache`, `dep_graph`, the resolver. Subprocess isolation
sidesteps reentrancy entirely; cost is one fork+pre-parse per
worker instead of zero.

A standalone `quartzd` binary with UDS support remains the
target for Phase 5.4+ (multi-client / LSP / cross-invocation
amortization), but is unnecessary for the qspec speedup that's the
immediate goal.

### D2. IPC: TCP loopback + length-prefixed JSON

**Revised again 2026-05-10 (post-FFI survey):** stdin/stdout pipes
to a child process require bidirectional fork+pipe+dup2 FFI that
Quartz currently lacks. We could build it (~80 LOC of intrinsic +
runtime helper across `typecheck_builtins.qz`,
`intrinsic_registry.qz`, `cg_intrinsic_io.qz`), but TCP loopback
sidesteps the need entirely and uses well-tested primitives we
already have in `std/net/tcp.qz`.

The connect-back pattern: the runner opens a TCP listener on
`127.0.0.1:0` (kernel-assigned port), spawns N workers via the
existing `go { posix_spawn_wait("quartz --persistent-worker
--connect-port=$PORT") }` pattern (each spawn wrapped in a
goroutine so the main thread isn't blocked), each worker
connects back to the listener. Runner gets one
`TcpStream` per worker. Bidirectional binary frames are then
trivial — `tcp_write(stream, encoded_request)` from runner,
`tcp_read(stream, n)` from worker, and vice versa.

Cost vs pipes: ~10µs of TCP loopback per request (negligible at
our 5s/spec scale). No new compiler/FFI work. The `--connect-port`
flag is the only new CLI surface.

Wire format on the socket:
```
[uint32 LE length][JSON payload]
```

Payload schemas (loose JSON, not formal protobuf — keeps the
implementation under 200 LOC of Quartz):

```json
// Request from qspec runner (or any client) to daemon
{
  "request_id": <int>,         // monotonic per-client; "0" reserved
  "kind": "compile" | "cancel" | "ping" | "shutdown",
  "argv": ["spec/qspec/foo_spec.qz", "-I", "std", ...],
  "cwd": "/path/to/quartz",
  "env": {"PATH": "...", ...}, // subset; not full env
  "stdin": ""                  // unused for v0; future REPL hook
}

// Response from daemon to client
{
  "request_id": <int>,
  "status": "ok" | "error" | "cancelled",
  "exit_code": 0,
  "stdout_path": "/tmp/quartzd-r123.out",  // or inline if small
  "stderr_path": "/tmp/quartzd-r123.err",
  "ir_path": "/tmp/quartzd-r123.ll",       // empty if non-IR command
  "duration_ms": 1234
}
```

Rejected: protobuf (Quartz lacks a generator; hand-rolling proto
schema for 4 message types is more code than the JSON path).
Rejected: stdin/stdout pipes per Bazel's exact protocol — sockets
are cleaner for the multi-client `quake qspec` shape (workers
register once, daemon dispatches; with stdio we'd need one
worker-per-client handshake).

### D3. Worker model: round-robin dispatch with backpressure channel

Daemon owns:
- `worker_pool: Vec<WorkerHandle>` — N pre-spawned workers
- `dispatch_ch: Channel` — unbounded; main loop sends `(request, response_promise)` tuples
- `recycle_ch: Channel` — workers signal "I'm done with N requests, recycle me"

Each worker handle wraps:
- pid + stdin pipe (for sending requests) + stdout pipe (for responses)
- request counter (for recycle threshold)
- in-flight request_id (or 0 if idle)

Dispatch: round-robin across idle workers. If all busy, queue on
`dispatch_ch`. Worker sends `WorkerResponse` back via stdout pipe;
daemon reads, matches `request_id`, fulfills the client's response.

Recycle: every 100 requests OR on stdlib SHA mismatch (computed
from `find self-hosted -name '*.qz' | xargs cat | sha256`). Daemon
SIGTERMs the worker, awaits exit, spawns replacement, the new
worker pre-parses stdlib before becoming dispatch-eligible.

### D4. Cancellation: WorkRequest with `kind=cancel`

Client sends `{request_id: 123, kind: "cancel"}`. Daemon looks up
in-flight worker for request 123, sends `kind=cancel` over the
worker's stdin. Worker's compile loop checks the cancel flag (or
catches a thrown cancellation via the existing scope mechanism)
and returns `{status: "cancelled"}` promptly. If the worker doesn't
respond within 2s, daemon SIGTERMs it and spawns a replacement.

For qspec specifically: the SIGINT path stays the same — the
spec subprocess (which now runs INSIDE the worker, not as a child
of the qspec runner) inherits the worker's process group. SIGINT
to the worker pgroup kills the subprocess, worker observes the
non-zero exit + sig 2, returns `{status: "cancelled"}`, qspec
runner sees CANCELLED and broadcasts via the existing
`atomic_cas` flag.

### D5. Per-request isolation: no shared mutable state

This is load-bearing — the fsc-trap insurance. Each compile
request gets:
- Fresh `build_cache` state (cache_open with a per-request
  `cache_dir` derived from `request_id` — `/tmp/quartzd-r123-cache/`)
- Fresh `dep_graph` (created per-request; not shared)
- Fresh resolver state (already per-compile in current architecture)

The ONE thing shared across requests in a worker is the parsed-
typechecked stdlib AST. We achieve this by:
1. Worker pre-parses stdlib once at startup; freezes the resulting
   `AstStorage` + typecheck context as immutable
2. Each compile request copies-on-read from this frozen state
3. User code's modifications to typecheck/MIR state happen in a
   fresh layer that wraps the frozen base

This requires a small refactor in `self-hosted/quartz.qz` to
separate "parse stdlib" from "parse user main + dependencies",
and to make the typecheck context cheaply re-baseable. ~150 LOC.

Tradeoff: per-request `dep_graph` means we lose the small wins of
cross-request module-IR caching for stdlib. But the win that
matters is "stdlib not re-parsed 787 times" — and that comes from
the pre-parsed shared base, not from disk-cached IR.

### D6. Lifecycle: per-suite daemon (not per-user)

`quake qspec` starts a daemon as its first step, points its workers
at it, and stops the daemon as its last step. NOT a long-lived
per-user daemon — that creates Gradle-style daemon-proliferation
footguns.

Lifecycle:
1. `quake qspec` starts → check if `~/.quartz/run/quartzd.sock`
   exists and is responsive (`ping` request)
2. If not: `posix_spawn` the daemon, wait for socket to be
   listening (poll up to 3s)
3. Send `compile` requests for each spec
4. After all results received: send `shutdown` request
5. Daemon SIGTERMs workers, removes socket, exits

Rejected: a long-lived persistent daemon (Bloop / sbt server
shape). For qspec the suite-scoped lifecycle is simpler and
sidesteps "stale daemon" debugging entirely. A long-lived shape
is a future option once the per-suite version is proven.

### D7. Per-suite warmup: yes, accept the cost

Worker startup + stdlib pre-parse is ~5s per worker. With 8
workers parallel, that's 5s wall time before the first compile
request runs. For a 787-spec suite that previously took 600s
serial, paying 5s warmup to amortize stdlib across all 787
requests is trivially worth it. We don't try to overlap warmup
with first request — workers are not dispatch-eligible until
their pre-parse completes.

## Phase plan

| Phase | Subject | Sized | Touches |
|---|---|---|---|
| **5.0a** | Wire format + protocol skeleton | 0.5 q-day | new `self-hosted/shared/persistent_worker_protocol.qz` (~120 LOC) — ✅ shipped `56184da5` |
| **5.0b** | `quartz --persistent-worker --connect-port=N` mode | 0.5 q-day | `self-hosted/quartz.qz` (~120 LOC; add 2 CLI flags, TCP-connect-back, request loop, dispatch to existing compile path) — ✅ shipped `6aae07a4` |
| **5.0c.1** | Worker-side `req.stderr_path` + `qz_redirect_stderr_to_file` intrinsic pair | 0.5 q-day | ~120 LOC across 5 files (typecheck_builtins + intrinsic_registry + cg_intrinsic_io + codegen_runtime + protocol module + _pworker_compile) — ✅ shipped `17313e0b` |
| **5.0c.2** | qspec runner: TCP listener + worker pool + dispatch | 1 q-day | `Quakefile.qz` (~330 LOC: pool start/shutdown, binary-safe TCP I/O, _pw_compile, _qspec_run_one swap, QSPEC_DAEMON=1 branch) + `tools/quake.qz` (`-I self-hosted/shared` for shared protocol module) — **infrastructure-only ship; see fsc-trap finding below** |
| **5.0e** | Smoke + measure | 0.25 q-day | full-suite run, compare wall time vs Phase 1 |
| **5.0f** | Stdlib pre-parse + frozen-base sharing | 1 q-day | `self-hosted/quartz.qz` refactor; new `parse_stdlib_freeze()` API — **blocks daemon-mode utility** |
| **5.1** | Cancellation wiring | 0.5 q-day | client `cancel` request → daemon → worker scope_cancel |
| **5.2** | Recycle policy + stdlib-SHA invalidation | 0.25 q-day | daemon-side; recycle counter + stdlib hash check |

### Empirical fsc-trap finding (2026-05-11, post-Phase-5.0c.2)

The risk D5 flagged is empirically reproducible at **request 4** per worker:

- 3 compiles per persistent worker: ✅ ~5s each (string_iteration/coerce/methods compile cleanly)
- 4th compile: 💥 SIGSEGV/SIGABRT, ~340ms in (worker dies before do_build emits any stderr)
- Reproduces regardless of spec ordering or whether the 1st/2nd/3rd request was a compile-error vs success — it's request-count-driven, not content-driven

Implication: Phase 5.0f is **load-bearing for any speedup**. A K=3 worker-recycle hack (measured ~50 LOC) is technically viable but provides NO speedup vs serial Phase 1: 5s worker-warmup amortized over 3 specs = 1.7s/spec overhead, vs serial's ~50ms fork+exec. Recycle is stability theater, not optimization.

Phase 5.0c.2 ships the runner-side TCP plumbing as prerequisite infrastructure — QSPEC_DAEMON=1 works for subsets ≤ `num_workers * 3` specs (useful for protocol-path validation) but is intentionally NOT promoted as a speedup. Once 5.0f lands the frozen-stdlib base + per-request isolation, the same runner code unlocks the projected 600s → 60s improvement without further Quakefile changes.

### What 5.0f needs (concrete handoff)

1. Refactor `self-hosted/quartz.qz` so stdlib parse + typecheck produces an **immutable frozen base** (AstStorage + typecheck context) that all per-request compiles read but never mutate.
2. Each `_pworker_compile` invocation forks a **fresh layer** wrapping the frozen base for the per-program state (user-main parse, dep graph, codegen state). The fresh layer is dropped at end of request — no state carries into the next compile.
3. ~150 LOC per 5.0f estimate. Files: `self-hosted/quartz.qz` (parse_stdlib_freeze entry point + state-reset between requests), possibly `frontend/parser.qz` (frozen-base lookup), `middle/typecheck.qz` (frozen-base inheritance).
4. Smoke verification: extend `/tmp/pw_compile_smoke.qz`-style test (compile 30 different specs in one worker, all green).

**Total Phase 5.0:** ~3.75 q-days. **Realistic outcome:** 600s
serial → 60s wall on 8-core dev box (if stdlib parse is 60% of
per-spec time as the cost-picture audit suggests). Worst-case
outcome (stdlib parse is only 30% of per-spec time): 600s → 120s.
Either way, big.

**Phase 5.1 + 5.2 add hardening and the cancellation path
qspec needs before it can replace `--no-cache` mode.** Targeted
delivery: full Phase 5 in a 4-5 q-day sprint.

## Verification path

| Phase | Smoke |
|---|---|
| 5.0a | `qspec/qspec/persistent_worker_protocol_spec.qz` exercises encode/decode round-trip. |
| 5.0b | Manual: `echo '{...compile request...}' \| ./self-hosted/bin/quartz --persistent-worker` returns valid response. |
| 5.0c | `./tools/quartzd &` + a tiny `python` client opens the socket, sends `ping`, gets `pong`. |
| 5.0d | `quake qspec` with daemon mode produces same pass/fail counts as `--no-cache` Phase 1 baseline. |
| 5.0e | Wall time: `quake qspec` < 90s on 10-core dev box (was ~200s post-Phase-1, ~600s pre-Phase-1). |
| 5.0f | After stdlib pre-parse: `quake qspec` < 60s. |
| 5.1 | Single Ctrl+C cancels the suite cleanly; daemon shuts down workers gracefully. |
| 5.2 | Edit a stdlib file mid-run → daemon detects SHA mismatch, recycles workers, no stale-cache contamination. |

## Open decisions deferred

1. **Long-lived per-user daemon.** Once 5.0 is proven, a
   `quartzd --keep-alive` mode that survives across `quake qspec`
   runs would amortize warmup cost too. Defer until per-suite
   version is solid.
2. **LSP server.** Editor integration via LSP is a separate,
   bigger project. The wire protocol here is intentionally not
   LSP-shaped — for editor work we'd build a `quartz-lsp` binary
   on top of the same daemon-internal compile API.
3. **Multi-version daemon pool.** If we ever ship `quartzc`-style
   tooling that needs multiple Quartz binary versions
   side-by-side, daemons keyed on `(quartz binary SHA)` per
   Gradle's pattern. Not needed now.
4. **Remote daemon / distributed compile.** Bazel-RBE shape. For
   single-developer use, irrelevant. Worth flagging as a possible
   future direction once Quartz adoption demands it.

## What this unblocks downstream

- **Sub-minute `quake qspec`** changes the TDD loop from
  "minutes-scale, run on commit" to "seconds-scale, run on every
  meaningful change."
- **`quake test --watch`** becomes feasible — the daemon is the
  natural place to listen for filesystem events and re-run
  affected specs incrementally.
- **Quartz LSP** has a working in-process compile API to build on
  (Phase 5.1 surfaces it; LSP server consumes it).
- **Bootstrap acceleration** — `quake build` and `quake guard`
  could invoke the daemon for module compilation, halving fixpoint
  build time. Currently 130s for two gen builds → could drop to
  ~30s.

## References (verify against canonical sources before implementing)

- [Bazel Persistent Workers](https://bazel.build/remote/persistent) +
  [worker_protocol.proto](https://github.com/bazelbuild/bazel/blob/master/src/main/protobuf/worker_protocol.proto) —
  the wire-protocol design we're cribbing
- [Bloop architecture](https://scalacenter.github.io/bloop/docs/what-is-bloop) —
  the per-project isolation pattern (D5)
- [scala/bug#4204](https://github.com/scala/bug/issues/4204) — the
  fsc-trap (D5's load-bearing rationale)
- [Roslyn Compiler Server doc](https://github.com/dotnet/roslyn/blob/main/docs/compilers/Compiler%20Server.md) +
  [analyzer-handle leak #2324](https://github.com/dotnet/roslyn/issues/2324) —
  the analyzer-DLL trap we're avoiding
- [rust-analyzer architecture](https://rust-analyzer.github.io/book/contributing/architecture.html) +
  [Salsa](https://github.com/salsa-rs/salsa) — the demand-driven
  query model deferred to Phase 5.3+
- [GHC recompilation-avoidance wiki](https://gitlab.haskell.org/ghc/ghc/-/wikis/commentary/compiler/recompilation-avoidance) —
  the ABI-fingerprint scheme deferred to Phase 5.3+
- [Buck2 DICE](https://buck2.build/docs/insights_and_knowledge/modern_dice/) —
  the unified-graph alternative we considered + deferred
- Full research transcripts: 2026-05-10 conversation history
