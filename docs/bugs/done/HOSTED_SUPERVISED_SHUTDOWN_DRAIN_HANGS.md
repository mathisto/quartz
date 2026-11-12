# Hosted supervised HTTP server: graceful-shutdown drain hangs + busy_ns telemetry garbage

> **CLOSED-STALE 2026-07-07** — re-reproduced fixed on current binary; see docs/sagas/r24-groundwork-inert-holes-2026-07-07-research/ws2-triage.md. Part A (bounded-drain deadline in `std/net/http_dynamic_goroutine_sup.qz`) and Part B (busy_ns stride `mul i64 …, 12` at `cg_intrinsic_conc_sched.qz:3052`) both landed with regression smokes. Remaining prod-only follow-ups (multi-worker validation, idle-connection `shutdown(2)` exit) are unreproducible on macOS — SHA not pinned.

**Filed**: 2026-06-04, while fixing the multi-worker mutex SIGSEGV (commit
`40033381`). Both are SEPARATE from that crash (which is fixed) and were
surfaced by load-testing the fixed `site/server.qz` on the prod box
(VM100, 16 cores).

## A. `http_dyn_gsup_stop` graceful drain hangs → `systemctl restart` wedges — FIXED (bounded drain)

**Status: FIXED 2026-06-04** by a bounded drain deadline in
`http_dyn_gsup_stop` (std/net/http_dynamic_goroutine_sup.qz). The
unbounded-await wedge can no longer occur. The prompt-idle-exit and prod
multi-worker validation pieces remain open — see "Follow-ups" below.

### Symptom
`systemctl restart quartz-site` never completes the stop phase. The old
process keeps the `:9090` listen socket; the new process can't bind, so
`restart` silently leaves the OLD binary serving (confirmed by md5 of
`/proc/<pid>/exe`). Recovery requires `systemctl kill -s SIGKILL` + manual
`kill -9`. Reproduced every restart during the mutex-fix deploy.

### Root cause (confirmed)
`http_serve_supervised` (std/net/http_server.qz) on SIGTERM flips
`_http_shutdown_flag`, exits the listener loop, then calls
`http_dyn_gsup_stop(sup)`. The original `stop()` did an **unconditional
`await` on every in-flight per-connection goroutine** (then the watcher),
with no deadline. An idle keep-alive connection is parked inside
`_async_http_parse_request_timeout` waiting for the next request; it only
re-checks `_http_shutdown_flag` at the *top* of its loop, i.e. after the
parked read returns. If that read has no deadline — or under the
production M:N scheduler the parked goroutine never observes the flag in
time — the task never reaches `done`, so `await t2` blocks forever and
`stop()` never returns. The listen socket is therefore never released.
(The supervised path uses the atomic-flag shutdown poll, not the
scope-cascade path — blocked by
[[feedback-resolver-wildcard-qualified-dedup]] — so there is no per-conn
scope to cancel; the old doc comment's "cancel scopes before stop()"
precondition could not be satisfied on this path.)

### Fix (implemented)
**Bounded drain deadline** in `http_dyn_gsup_stop`, mirroring Go's
`http.Server.Shutdown(ctx)` and nginx's `worker_shutdown_timeout`: drain
in-flight work for at most `drain_timeout_ms`, then stop waiting and let
the caller `sched_shutdown()` + exit. `stop()` can no longer hang
regardless of whether individual connections cooperate.

- New `HttpDynamicGoroutineSup.drain_timeout_ms` field (default
  `_hdgs_default_drain_ms()` = 5000ms; 0 = unbounded/legacy) + setter
  `http_dyn_gsup_set_drain_timeout`.
- `stop()` replaced the unconditional `await` with a poll-with-deadline
  loop (5ms quantum via `_hdgs_drain_poll_ms()`); on the all-done fast
  path it never sleeps.
- `http_serve_supervised` / `https_serve_supervised` set the deadline from
  the (previously dormant, unused) `HttpServerConfig.shutdown_timeout_ms`
  field (default 5000ms) right after `http_dyn_gsup_new()`.

### Verification
- Deterministic regression test: `spec/qz/http_dyn_gsup_smoke.qz` Test 6 —
  pushes a fabricated child whose state slot never reaches `done` (-1) and
  asserts `stop()` returns within ~the 300ms deadline (not 0ms, not
  forever). Pre-fix this hung. (Tested this way because the local hosted
  build inline-polls `async` bodies to their first *direct* suspend point,
  so a `spawn_one`'d body always completes before `stop()` and a real
  parked-goroutine test would pass vacuously — see the test's comment.)
- End-to-end: `spec/qz/http_serve_supervised_smoke.qz` on :18737 — GET/POST
  return 200; SIGTERM → clean exit in ~130ms, no SIGKILL needed.
- `http_dynamic_goroutine_sup_spec.qz` 6/6, `http_dyn_gsup_smoke.qz` 6/6.
- std-only change (no `self-hosted/*.qz`); compiler binary + fixpoint
  unaffected.

### Follow-ups (open)
- **Prod multi-worker validation.** The local macOS hosted build runs
  `async` bodies inline (no real concurrent worker execution), so the
  *original* hang is not reproducible here and the bounded-drain return
  was validated deterministically + end-to-end on the happy path, NOT
  against a genuinely-parked production connection. Re-run the
  SIGTERM-restart cycle on the prod box (VM100, 16 cores) under load to
  confirm the deadline fires and `systemctl restart` rebinds cleanly.
- **Prompt idle-connection exit.** A bounded drain cuts connections still
  parked at the deadline rather than draining them cleanly. To let idle
  keep-alives exit *promptly* on shutdown (so drain finishes fast and
  cleanly instead of always hitting the deadline), track each
  per-connection fd in the sup and `shutdown(2)` them on `stop()` — this
  interrupts the parked reads, the way Go closes idle connections on
  `Shutdown`. Requires care around the per-conn `tcp_stream_scoped`
  double-close.
- Interim ops belt-and-suspenders: `quartz-site.service` may still set a
  short `TimeoutStopSec=` + `KillMode=mixed`. (Service file is the user's
  deploy lane.)

## B. `busy_ns` telemetry returns pointer-like garbage for some worker slots — FIXED

**Status: FIXED 2026-06-04** (stride mismatch in `sched_worker_busy_ns`).

`/load/metrics`'s `busy_ns` array (one entry per worker via
`sched_worker_busy_ns(i)`) intermittently contained huge values that look
like leaked pointers, e.g.:
```
"busy_ns":[177825152,1,256,5,139760450407280,14,171028288,6,256,4,139759980645232,26,...]
```
Reasonable per-worker busy figures (~1.7e8 ns) interleaved with `1`,
`256`, and ~1.4e14 values (≈ heap addresses).

### Root cause (confirmed)
NOT "past the live worker count" — a **stride mismatch**. The per-worker
data array is allocated with a 12-i64 stride (`nw * 96` bytes;
codegen_runtime.qz ~5340), busy_ns at slot [8], and every accessor —
the busy_ns *writer* (~7608) and the shutdown *snapshot* (~9973) — uses
`mul %wid, 12`. But the *live read* in `sched_worker_busy_ns`
(cg_intrinsic_conc_sched.qz ~3045) used a stale stride of **10**, so for
every `wid>0` it read off the wrong slot:
`wd[1*10+8]=worker_id(1)`, `wd[2*10+8]=cap(256)`,
`wd[4*10+8]=queue buffer pointer`, … The read realigns to a real busy_ns
slot every 6 reads (LCM(10,12)/10), producing the periodic garbage
pattern above. Reproduced deterministically on macOS: 8 workers →
`[0, 1, 256, 0, 4940944896, 16, 0, 6]`. Two stale layout comments
(codegen_runtime.qz "8 i64 slots = 64 bytes per worker") had drifted from
the real 12-slot layout and enabled the divergence.

### Fix (implemented)
- `sched_worker_busy_ns` live read: `mul %wid, 10` → `mul %wid, 12`
  (cg_intrinsic_conc_sched.qz), with a comment pinning it to the
  allocation/writer stride.
- Corrected the stale 8-slot layout doc in codegen_runtime.qz to the
  authoritative 12-slot layout (incl. busy_ns at [8]).
- The snapshot path (post-`sched_shutdown`) was already correct — it
  reads `wd[wid*12+8]` and packs densely, and the intrinsic reads the
  dense snapshot with stride 1.

### Verification
- `spec/qspec/diagnostics_spec.qz` — new test "sched_worker_busy_ns reads
  the correct per-worker slot (no stride garbage)": 8 workers, rejects the
  cap sentinel (256) and pointer values (>1e9). Fails on the old stride,
  passes on the fix.
- Before/after probe: idle workers now all read 0 (was the garbage
  pattern above). scheduler_spec 4/4, concurrency_spec 57/57.
- `quake guard` fixpoint 2640 fns; style_demo + brainfuck smokes clean.

## C. Demo wedge at extreme N + concurrent HTTP flood (known, recurred)

Setting `/load/set?n=20000` AND simultaneously flooding the server with
~100-way concurrent asset requests saturates all 16 cores with priority-2
`load_task` goroutines and starves the HTTP listener — `/load/stop` never
gets processed, so `g_load_running` stays 1 and the demo never drains
(process pegged ~1030% CPU, all endpoints `000` until restart). This is
the previously-filed [[feedback-supervised-vs-demo-task-starvation]] case.
At n ≤ 5000 the server stays fully responsive (15/15 HTTP OK) and drains
cleanly after stop. Mitigations: cap the demo's max N far below 5,000,000
(currently `load_set` clamps to 5_000_000 — absurd for a 16-core box), or
give per-conn HTTP handlers a strictly higher priority lane than demo
tasks. Demo behavior lives in `site/server.qz` (user's deploy lane).
