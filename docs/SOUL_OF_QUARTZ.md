# Soul of Quartz

> Multi-session roadmap for rebuilding the public Soul-of-Quartz demo as the
> capstone integration test for the Phase A-C concurrency unification work.
>
> **Status (2026-05-27 evening):** Phase 0-2 complete, SOUL.7 deployed and
> live at `https://mattkelly.io`. Current binding constraint is the
> slab-tier per-conn leak — under organic load the 45-min systemd
> auto-cycle masks it; under burst load (the SOUL.5 spawn-N headline)
> it would OOM before the cycle could save us. Next up: **SLAB.1** (extend
> the per-task arena hook to the slab tier), then **SOUL.5** (kernel-level
> spawn-N benchmark, same "swap to language-level after D.11 Phase 7 B.5"
> pattern that worked for SOUL.6), then **D.11 Phase 7 B.5** (freestanding
> effect-handler runtime so SOUL.5+SOUL.6 can swap from kernel-level
> primitives to language-level `scope_with_deadline` / unified `select` /
> `Supervisor.start_child`). Last touched 2026-05-27.

## Current production state

- **Live**: all 5 endpoints (`/`, `/health`, `/api/stats.json`,
  `/api/recent.json`, `/api/soul/stats.json`) HTTP 200, sub-300ms.
- **Binary**: `b96eb6cd` (multi-page per-page-count buckets, May 26 15:09)
  at `/opt/quartz/quartz-unikernel.elf` on `mattkelly.io`.
- **Systemd policy**: `RuntimeMaxSec=45min` auto-cycle (belt-and-suspenders;
  sub-second user-visible blip; documented in
  `/etc/systemd/system/quartz-unikernel.service` comments). Per
  `journalctl -u quartz-unikernel --since "6h ago"`, last 6h shows 5 clean
  RuntimeMax cycles, no OOM, no FAIL — the cycle is doing what it's there
  to do.
- **Caddy edits in place**: `keepalive 0s` + `keepalive_idle_conns 0`
  (stale upstream pool would 502 after a cycle); `dial_timeout 2s` +
  `lb_try_duration 5s` (qemu hostfwd backlog=1 sometimes drops SYN bursts).
- **PMM under organic load** (~2 conns/min): ~1 page / 4 s growth → ~27 KB/min,
  well inside the 3 GiB budget.
- **Slab leak (the binding constraint)**: 32B class leaks ~96% of allocs,
  128B class leaks ~99%. ~3 KB/conn unrecovered. Documented in
  `feedback_multipage_fragmentation_under_burst.md` "Actual production
  binding constraint" section + closing memo
  `feedback_multipage_bump_no_reclaim.md`. Fix design = Option 3
  (per-class arena hook in `_async_http_write_response_timeout`).

## What this is

The Soul of Quartz page (currently the dynamic-landing alias at
`joyofquartz.mattkelly.io`, soon to be relabeled "Soul of Quartz" everywhere
visible) is a *separate* showcase from the unikernel-landing page at
`unikernel.mattkelly.io`. Both will run on the same underlying unikernel ELF
on the `mattkelly.io` VPS, but they tell different stories:

| Page | Story | Headline number |
|---|---|---|
| **Unikernel** | "Look how minimal." A whole computer, written from scratch in Quartz, in ~7 MB. | 7 MB ELF · 0 lines of C · 0 lines of Linux in the request path |
| **Soul of Quartz** | "Look how much it scales." That same unikernel running 5+ million live tasks at once, with a real-time htop-style dashboard. | 5,000,000 live goroutines · ~512 bytes per task · cancel-cascade in <1 ms |

The current state at `joyofquartz.mattkelly.io` is a placeholder — the host
points at the unikernel landing because the original Soul demo (commits
`aa2c4fdc` "Million-task benchmark", `df7a9a69` "Soul of Erlang live demo",
`710c9c65` "Rename to Soul of Quartz") hasn't been deployed since the
unikernel epic shipped. Rebuilding it is the goal of this roadmap.

## What we're rebuilding (the reference)

Saša Jurić's *The Soul of Erlang and Elixir* (GOTO 2019, accompanying repo
`sasa1977/demo_system` and successor `sasa1977/soul_of_erlang_and_elixir`)
demonstrates BEAM properties through a small set of LiveView dashboards:

1. **Load Control Dashboard** (`/dashboard/load_control`) — synthetic load
   creation; user dials up load and watches the system react in real time.
2. **Processes Dashboard** (`/dashboard/processes`) — running processes,
   sortable by reductions (BEAM's unit of computational work). This is the
   htop-equivalent.
3. **Sum Calculation Page** (`/`) — interactive distributed computation; one
   Connection process per WebSocket spawns child Computation processes per
   unit of work, all monitored.
4. **`mix upgrade`** — hot code reload in production; system updates without
   stopping serving traffic.
5. **`mix add_node`** — spawn additional dev nodes (port 4001, 4002, …) that
   automatically take their share of the synthetic load; kill any node and
   the survivors absorb the work.

The properties he proves: lightweight processes (millions per node),
preemption, fault isolation, supervisor restart trees, hot upgrade,
distribution / load redistribution.

## What Quartz can match (and where we go further)

| Saša's demo | Quartz today (May 2026) | Quartz after Phase A-C |
|---|---|---|
| Lightweight processes (~2.6 KiB / process on BEAM) | ✓ goroutines (~512 bytes / task per `aa2c4fdc`) — already smaller than BEAM | Same primitive, with Actor wrapper |
| Process dashboard sortable by reductions | needs SOUL.4 telemetry | sortable by CPU time / spawn time / channel-msgs / scope-depth |
| Synthetic load demo | possible today via `go fn()` | via Actor + Supervisor + select |
| Cancel a load source / kill a node | scope cancellation cascade exists, ~0ms latency via active-wake | same, with Supervisor restart strategies |
| Hot code reload | **not yet** — separate epic, never planned | still not yet |
| Multi-node distribution | **not yet** — single-machine for now | single-machine for now |
| LiveView reactive dashboard | server-side render + JS poll exists in `http_build_landing` | same, plus Actor-driven push via SSE |

**Where we plan to go further than Saša's demo:**
- **5M tasks vs ~~~~his 1M.** Quartz tasks are smaller; we have more room.
- **Sub-millisecond cancel cascade.** BEAM's per-process kill is reasonably
  fast; Quartz's `sched_wake_interrupts_sleep` (Phase 4e.8 active-wake
  retrofit, May 2026) cancels a sleeping goroutine in <1 ms. We can show this
  visually by spawning 5M sleeping goroutines and watching every single one
  unwind in a single dashboard tick.
- **Deadline propagation.** BEAM doesn't have first-class deadline
  inheritance; Quartz scopes do. Demo: parent scope has 500ms deadline,
  children inherit it automatically, all unwind synchronously at 500ms.
- **Closed loop of self-hosting.** "This page was assembled by a Quartz
  binary running inside a Quartz unikernel, compiled by a Quartz compiler
  written in Quartz" — we already get this for the unikernel landing; the
  Soul page inherits it for free.

## Architecture (target shape)

```
                              ┌──────────────────────────────────┐
   Browser  ──HTTPS──> Caddy ─┤ joyofquartz.mattkelly.io          │
                              └──────────────┬───────────────────┘
                                             │ TCP 8080
                                             ▼
                             ┌──────────────────────────────┐
                             │  Quartz unikernel (QEMU      │
                             │  microvm, -m 6G, -cpu max)   │
                             │                              │
                             │  ┌─ http_route() ───────┐    │
                             │  │ Host:                │    │
                             │  │  unikernel.mk.io →   │    │
                             │  │    http_build_landing│    │
                             │  │  joyofquartz.mk.io → │    │
                             │  │    http_build_soul_  │    │
                             │  │    landing           │    │
                             │  └──────────────────────┘    │
                             │                              │
                             │  ┌─ Soul-of-Quartz subsys ─┐ │
                             │  │                         │ │
                             │  │  Supervisor (D.11)      │ │
                             │  │   ├─ stats_collector    │ │
                             │  │   │   (Actor<Stat>)     │ │
                             │  │   ├─ load_controller    │ │
                             │  │   │   (Actor<LoadCmd>)  │ │
                             │  │   ├─ task_pool          │ │
                             │  │   │   (Supervisor)      │ │
                             │  │   │    └─ N × Actor<W>  │ │
                             │  │   └─ telemetry_pusher   │ │
                             │  │       (SSE push)        │ │
                             │  │                         │ │
                             │  │  /api/soul/stats.json   │ │
                             │  │  /api/soul/spawn?n=N    │ │
                             │  │  /api/soul/cancel       │ │
                             │  │  /api/soul/stream (SSE) │ │
                             │  └─────────────────────────┘ │
                             └──────────────────────────────┘
```

## Phase plan

Tasks are tracked in the harness task list (`TaskList` to view). Roadmap
entries also exist in `docs/ROADMAP.md` under the same IDs.

### Active priorities (2026-05-27)

Ranked, smallest-credible-units-first:

| Rank | Item | Sized | Why now |
|---|---|---|---|
| **1** | **SLAB.1** — extend per-task arena to slab tier | 1-2 qd | The actual binding constraint for scale-up. Today the 45-min systemd cycle masks it under organic load; SOUL.5 burst load will OOM before that. See "Current production state" above + `feedback_multipage_fragmentation_under_burst.md` Option 3. Removes the cycle's load-bearing role and clears the way for SOUL.5 to run cleanly. |
| **2** | **SOUL.5** — spawn-N kernel-level demo (1k → 5M) | 1-2 qd | Headline. Same "kernel-level first, swap to language-level later" pattern that worked for SOUL.6. Adds `/api/soul/spawn?n=N` + Soul-page buttons + a `cancel_all` button that visualizes the active-wake cascade. Sized for kernel-level primitives; the C.14 (Actor + Supervisor) framing folds in post-D.11 Phase 7 B.5. |
| **3** | **D.11 Phase 7 B.5** — freestanding effect-handler runtime | 2-3 qd | Path A+C from `feedback_stdlib_codegen_intrinsics_hosted_only.md` (committed survey memo `b9a837ce`). Unblocks the language-level swap for SOUL.5 + SOUL.6 demos. Not user-visible immediately, but converts the demos from "kernel-level workarounds" to honest C.13/C.14 dogfood. |
| **4** | **C.14** — `Actor<T>` + Supervisor stdlib | 2-3 qw | The big one. Required for the dashboard's "supervised Actor mailbox" framing. Long horizon; can spread across sessions. Not blocking SOUL.5's spawn-N numbers. |

### Phase 0 — research & rename (unblocked, do now)

| Task | Sized | Notes |
|---|---|---|
| **SOUL.0** Research Saša Jurić's talk + capture demos | ~0.25 quartz-day | Done in this doc; expand if needed when designing SOUL.4-6. |
| **SOUL.1** Rename "Joy of Quartz" → "Soul of Quartz" everywhere visible | ~0.25 quartz-day | Edit `tools/baremetal/hello_x86.qz` nav link, `site/src/components/Header.astro` nav link. Subdomain stays `joyofquartz.mattkelly.io` (DNS, expensive to change) but the displayed label is "Soul of Quartz". Other unikernel-page label stays "Unikernel". |
| **SOUL.2** Dynamic memory probing (Multiboot2 mmap) | ~0.5 quartz-day | Replace static `.skip 0x4000000` (64 MiB) in `boot_trampoline_x86.s` with dynamic mmap parsing. Boot detects whatever QEMU `-m` allocates. Bump VPS systemd unit to `-m 6G`. Add "Detected RAM" card to dashboard. |

### Phase 1 — Phase A-C polish (prerequisites for the maximalist demo)

These are the four roadmap items the May 1 2026 design session filed as
preconditions for D.11 (the capstone). The Soul of Quartz demo *is* the
integration test that proves these designs were correct, so they ship first.

| Task | Sized | Notes |
|---|---|---|
| **B.8** `with`-scoped resource acquisition consistency | ~1-2 quartz-weeks | **CLOSED 2026-05-10.** Unified acquire/release pairs under `with R(...) do v -> body end`. Phases 1-7 shipped 2026-05-08–10: parser, typecheck dispatch, MIR-lower normal-exit release + first Mutex impl, throw-safety via TLS Scoped-ctx + generic `__qz_scoped_throw_handler`, full stdlib impl matrix (Mutex, RwLock, File with `"w"`-mode rollback asymmetry, Channel, Scope, TcpStream, TcpListener, EventLoop), write-back semantics (bound `v` is implicitly `var`; TLS stack stores slot address so reassignments flow through release), consumer migration (`std/progress.qz` 4 functions + `std/sync/scope.qz` 5 sites), docs sweep (QUARTZ_REFERENCE.md "Scoped Resources" section, STYLE.md guidance, CLAUDE.md anti-hallucination note, stdlib module headers). UDP deferred — `std/net/udp.qz` is dormant-broken at compile + runtime layers; rewrite gates the wrapper. Specs: `scoped_resources` (9), `scoped_rwlock` (8), `scoped_channel` (5), `scoped_scope` (6), `scoped_dispatch` (3), `scoped_file` (5), `scoped_tcp` (5), `scoped_event_loop` (4), `scoped_writeback` (6). Full design in `docs/design/SCOPED_RESOURCES.md`. |
| **C.13** Generalized `select` across primitive boundaries | ~3.6 quartz-days post-design | **Phases 1-5 cheap impls + Phase 7 docs shipped 2026-05-10** (commits `bfe05506`, `fe3db7dc`, `4b7f9a2d`, `821748d8`, `aa9bc548`). Design memo + uniform `case <pat> = <Selectable> => body` arm syntax + parser op_kind=5 fall-through + typecheck `Selectable` impl lookup + MIR-lower try_poll/option_is_some/complete dispatch + 5/8 stdlib impls (`recvable`, `sendable` in `std/sync/channel.qz`; `cancellable`, `deadline_ms` in `std/sync/scope.qz`; `awaitable` in `std/sync/awaitable.qz`) + reference docs sweep (QUARTZ_REFERENCE.md "Select — multiplex over Selectables" section, STYLE.md guidance, CLAUDE.md anti-hallucination paragraph). Specs: `select_unified_recv_spec` (5), `select_unified_send_spec` (6), `select_unified_deadline_scope_spec` (10), `select_unified_future_spec` (6) — 27/27 green. **Remaining**: Phase 4b active-wake retrofit (~1.0qd amortized across all impls per B.7 4e.8 playbook), Phase 5 hard impls (Signal / IoReady / MutexTry, ~0.6qd), Phase 6 consumer migration (~0.3qd). Required for the "race N, first wins" demo. Full design in `docs/design/SELECT_UNIFICATION.md`. |
| **C.14** `Actor<T>` with mailbox + Supervisor | ~2-3 quartz-weeks | The headline BEAM-equivalent. `Actor<T>` = goroutine + typed mailbox + lifecycle hooks; `Supervisor` = restart strategy on top of `supervisor_tree`. The Soul demo's task workers, dashboard collectors, and load controllers all use this. |
| **D.10** Four-shapes taxonomy under `std/sync/` | ~3-5 quartz-days | Reorganize: Communication / Synchronization / Atomicity / Composition. |

### Phase 2 — Soul page implementation

Most of these are unblocked by Phase 0; the SOUL.5 row's "blocks on C.14"
framing has been REVISED — per the SOUL.6 precedent, kernel-level
primitives ship first, then swap to language-level after D.11 Phase 7 B.5
lands the freestanding effect-handler runtime.

| Task | Blocks on | Sized |
|---|---|---|
| **SOUL.3** Page split: extract `http_build_soul_landing` from `http_build_landing` | SOUL.1 | ~0.5 quartz-day | **✅ DONE.** Live at `https://joyofquartz.mattkelly.io`. |
| **SOUL.4** Scheduler-telemetry plumbing (`/api/soul/stats.json` + counters) | — | ~1 quartz-day | **✅ DONE.** Schema includes `version, ticks, connections_*, pmm_*, slab_classes[], multipage{}, goroutines_alive, detected_ram_bytes` and a `tx_*` block. Probed live. |
| **SOUL.5** Spawn-N-tasks demo (1k → 10k → 100k → 1M → 5M) | ~~C.14~~ → **SLAB.1** (real prod blocker) | ~1-2 quartz-days | **Active priority #2** (post-SLAB.1). Per SOUL.6 precedent, kernel-level first (`/api/soul/spawn?n=N` + cancel-all button visualizing active-wake cascade). Swap to language-level after D.11 Phase 7 B.5 ships C.14's freestanding substrate. |
| **SOUL.6** Structured-concurrency micro-demos (deadline / cancel cascade / select race / supervisor restart) | C.13, C.14 | ~1 quartz-day | **✅ DONE 2026-05-23 (Path A — kernel-level primitives).** All four shipped in two commits: Demo 1 (deadline) `50c6eec1`; Demos 2/3/4 (cascade/race/restart) plus one PRNG-positivity fix in the follow-up commit. Measured (QEMU microvm `-m 6G`, 1 CPU): deadline 8/8 unwind, spread ~30 μs / max drift ~45 μs past 200 ms target. Cascade 1000/1000 unwind, last task in 2.1 ms, 461/1000 under 1 ms, 1000/1000 under 10 ms (cooperative pump cost — D.11's `sched_wake_interrupts_sleep` will collapse this to near-zero). Race: deterministic winner is the racer with the lowest seeded finish time, losers correctly observe the winner flag and unwind. Restart: 4 attempts with 20/40/80 ms exponential backoff = 150 ms total, succeeds on attempt 4. Endpoints `/api/soul/demo/{deadline,cascade,race,restart}` + four cards in a 2×2 grid on the Soul page. **Honest framing on the page**: today uses kernel-level primitives (`uk_time_mono_ns`, `g_*_cancel_gen`, hand-rolled supervisor loop); D.11 bridges freestanding kernel through the C.13/C.14 stdlib substrate and the demo bodies swap one-line to `scope_with_deadline` / unified `select` / `Supervisor.start_child` with identical behavior. **Filed forward** as part of this work: SOUL.6's "~1qd" estimate in this doc predated the realization that freestanding-target codegen stubs out the effect-handler runtime (`codegen_runtime.qz:2729`), so the language-level primitives don't yet run in the kernel — bridging that is part of D.11. Also surfaced + fixed a Bootstrap-Island regression in `std/ffi/socket.qz` (`socket_last_error` cfg gate asymmetric with `get_errno`; broke the freestanding unikernel build since `20da7f5a`); single-gate fix in commit `e768e282`. Wider audit of `not:windows`-gated socket helpers filed as follow-on. |
| **D.11** Capstone — dogfood `http_server.qz` onto the new APIs | B.8, C.13, C.14, D.10 | ~2-3 quartz-weeks | **✅ DONE 2026-05-25 (Phases 1–9 shipped).** Userland (Phases 1–6) migrated `std/net/http_server.qz` onto Phase A-C primitives — Connection trait + DynamicSupervisor + tcp_acceptable Selectable + Scoped listener/stream wraps. Freestanding-effect bridge (Phase 7 B.0–B.5) added per-task effect-stack via TASK_STRUCT_SIZE growth + setjmp/longjmp in libc_stubs + kernel-side `@__qz_effect_perform` + `@__qz_effect_suspend` + KAwait/KRecvable Selectable impls. Kernel migration (Phase 8a–8c) added the fd-emulation layer, swapped `http_server.qz` to freestanding `@cfg` branches, then collapsed onto a single supervised path serving the canonical port 80 — `kernel_router_handler` dispatching the 14 kernel routes through `http_serve_supervised(http_server_config(80), kernel_router_handler)`. Phase 8c.2 deleted the legacy hand-rolled HTTP path (`http_build_response` dispatcher, raw-bytes request matchers, raw-bytes asset lookup) — net `-805` LoC from `hello_x86.qz`. `baremetal:qemu_http` dual-curl gate green; 14-route probe green; Soul page demos (SOUL.6) still pass through the now-supervised path unchanged. **SOUL.7 deploy unblocked.** |

### Phase 2.5 — production scale-up (new, 2026-05-27)

Bridges deploy-with-the-cycle-as-safety-net to scale-up-actually-works.
Single item; sized for one session.

| Task | Sized | Notes |
|---|---|---|
| **SLAB.1** Extend per-task arena to slab tier | 1-2 qd | **Active priority #1.** Today (post-SOUL.7 deploy) the per-conn slab leak is masked by the 45-min systemd cycle: 32B class leaks ~96% / 128B leaks ~99%, ~3 KB/conn unrecovered, ~75 in_use/min growth under organic load. Mirrors the Phase 8b.2.c.7 per-task arena for multipage (`3e9427fb`) but for slab. **Design** — Option 3 from `feedback_multipage_fragmentation_under_burst.md`: per-slab-class arena-style hook in `_async_http_write_response_timeout`, single chokepoint per request. The arena marker mechanism that worked for multipage (bit 0 of the 16-byte chunk header's size field) doesn't transfer directly to slab (chunks have no 16-byte header) — pick one of: parallel side-table indexed by chunk address, tag bit in the slab page header, or per-task linked list. **Verification gate**: 1000-curl burst against `/api/soul/stats.json` shows steady-state slab `in_use` counts across all classes (32B/64B/128B/256B/512B). **Deploy gate**: drop `RuntimeMaxSec` from 45min → 24h (or remove entirely) once 24h soak proves no growth; keep `Restart=always` as the watchdog. |

### Phase 3 — deploy & verify

| Task | Blocks on | Sized |
|---|---|---|
| **SOUL.7** Deploy to `mattkelly.io` VPS, verify 5M-task headline against the public internet | SOUL.3-6, D.11 | ~0.5 quartz-day | **✅ DEPLOYED 2026-05-25 (attempt 2).** Post-D.11 unikernel binary (`http_serve_supervised(http_server_config(80), kernel_router_handler)`) live on `mattkelly.io`. Attempt 1 same day failed at boot: slab_alloc's hard-coded `cb >= 0x80000000ULL` upper-bound check tripped at the first refill because qemu microvm `-m 6G` lays out a split RAM region where pvh_probe_ram sometimes picks the high (>= 4 GiB) bank. The boot trampoline identity-maps 16 GiB (`boot_trampoline_x86.s`) so the page itself is dereferenceable — the guard was just wrong. Fix: slab guard now reads live `get_pmm_pool_start()/end()` so it tracks whichever region pvh_probe_ram picked; `baremetal:qemu_http` gate + 14-route probe both bumped from `-m 1G` to `-m 6G` to exercise the high-bank path on every build. Attempt 2 deploy + all 5 public endpoints (`/`, `/api/stats.json`, `/api/recent.json`, `/api/soul/stats.json`, `/health`) green over HTTPS. 5M-task spawn-headline verification is a separate experiment to run from the live site once stable. |

## Page section sketch (for SOUL.3)

The Soul page rendered at `joyofquartz.mattkelly.io`:

1. **Hero.** "5,000,000 lightweight tasks in 6 GiB. Watch them spawn, work,
   and unwind, live, on a unikernel built from scratch in Quartz."
2. **The htop view.** Table sortable by CPU time / spawn-time / channel-msgs
   / scope-depth. Updates via SSE push from a `telemetry_pusher` Actor; falls
   back to JSON poll if the browser doesn't speak SSE. Shows the top 200
   tasks by selected metric, plus aggregate stats above.
3. **The headline buttons.** "Spawn 1k", "Spawn 10k", "Spawn 100k", "Spawn
   1M", "Spawn 5M". Each fires a POST to `/api/soul/spawn?n=N` that fans out
   N supervised Actors. A "Cancel all" button POSTs to `/api/soul/cancel`
   which cancels the parent scope; we visualize the active-wake cascade
   draining the count back to baseline in a single tick.
4. **The structured-concurrency demos.** Smaller, scripted: deadline
   propagation, cancel cascade, supervisor restart, select race. Each is a
   "click to run" button with a small inline visualization (a tree diagram
   that animates as scopes unwind, or a horizontal time strip showing which
   goroutine won the race).
5. **The closing.** A pair of paragraphs: "What you just saw was N supervised
   Actors, each with a mailbox, all rooted in a scope tree, running on a
   single QEMU vCPU. The same Actor abstraction is what `std/net/http_server`
   uses; the same scope tree is what cancels your fetch when you close the
   tab. Quartz at scale."

## Telemetry — what the htop view shows

For each task in the table:
- PID-equivalent (goroutine id, monotonic from boot)
- Parent scope id (so the table is roll-up-able by scope)
- Type — goroutine / Actor / system task
- State — running / ready / sleeping / blocked-on-recv / blocked-on-send / blocked-on-mutex
- CPU time (cumulative ns)
- Spawn time (boot-relative)
- Heap allocated (bytes)
- Channel-msgs sent / received
- Mailbox depth (Actors only)
- Last running-on cpu (when SMP lands)

Aggregate counters (top of dashboard):
- Total tasks: live / since boot
- Memory: detected / used (the SOUL.2 card)
- Per-state counts (running / ready / sleeping / blocked) as a stacked bar
- Spawn rate (tasks/sec, last 1s window)
- Completion rate (tasks/sec, last 1s window)
- Average task lifetime
- Cancel-cascade max latency (P99 over the last batch)

## Open decisions deferred

These are real choices we don't need to make until the relevant phase:

1. **SSE vs WebSocket for the live dashboard push.** SSE is one-way and
   simpler to implement against the existing HTTP server; WebSocket is
   bidirectional but heavier. SSE is probably right for v1; the cancel
   button doesn't need full-duplex.
2. **Per-task heap accounting cost.** Today the alloc effect tracks per-task
   arenas but doesn't expose per-task byte counts cheaply. SOUL.4 has to
   decide whether to add a fast counter (cost: one atomic increment per
   alloc on the hot path) or to scrape the arena lazily.
3. **Cardinality limit for the htop table.** At 5M tasks we cannot send all
   rows to the browser. Top-N (N=200?) sorted by the user's chosen metric is
   the obvious answer, but we should think about whether there's a more
   honest alternative (e.g., a stratified sample plus a per-state aggregate).
4. **Whether Supervisor restart strategies (one_for_one / one_for_all /
   rest_for_one) ship in C.14 or split into a follow-on.** The minimal
   Supervisor that just restarts crashed children one_for_one is enough for
   SOUL.6's crash-isolation demo; the full strategy zoo can wait.
5. **Whether to expose a "burn one CPU" demo for SMP visualization.** Blocked
   on KERN.8 (true M:N scheduling); meaningful only after SMP lands. File
   under "post-D.11 stretch."

## Why this is sequenced this way

1. **SOUL.0/1/2 first** because they're cheap, unblocked, and de-risk the
   rest. The memory probe in particular is a one-time correctness fix that
   should not block on design work.
2. **Phase A-C polish in the middle** because the Soul demo *is* the
   integration test for those designs. If we shipped the demo with current
   primitives we'd ship it twice — once with goroutines + raw scopes, again
   with Actors + Supervisors after C.14 lands. The capstone framing means we
   ship it once, the right way.
3. **D.11 (http_server migration) shipped before SOUL.7 deploy** because the
   unikernel itself runs `http_server.qz` to serve the Soul page; the
   integration test isn't credible if the server underneath the demo is
   still on the old primitives.
4. **SOUL.7 last** because it's the production reveal — only worth doing
   when everything underneath it is green.

## Files this roadmap will touch

Listed for next-session orientation. Not exhaustive; new files may emerge.

- `tools/baremetal/hello_x86.qz` — nav rename, host routing split, soul page
  builder, soul API endpoints
- `tools/baremetal/boot_trampoline_x86.s` — SOUL.2 memory probing
- `tools/baremetal/x86_64-multiboot.ld` — possibly, if the linker script
  needs updating for the new memory layout
- `site/src/components/Header.astro` — nav rename (Astro side)
- VPS systemd unit `/etc/systemd/system/quartz-unikernel.service` — `-m 6G`
- `std/sync/` — D.10 reorganization, B.8/C.13/C.14 new files
- `std/concurrency.qz` — Actor + Supervisor surface
- `std/net/http_server.qz` — D.11 migration
- `docs/ROADMAP.md` — SOUL.x entries
- `docs/SOUL_OF_QUARTZ.md` — this doc (lives at the top level so it's
  discoverable; pairs with `docs/JOY_OF_QUARTZ.md` reference in D.11 entry,
  which we're now subsuming)

## Cross-session handoff protocol

Anyone (human or Claude) picking this up mid-roadmap:

1. `TaskList` shows where we are. SOUL.x and B.8/C.13/C.14/D.10/D.11 are the
   trackable IDs.
2. This doc is the design source of truth. Update it (don't append a
   secondary handoff) when decisions get made.
3. Phase A-C (B.8, C.13, C.14, D.10) work happens in regular feature commits
   tagged `[soul-prereq]` so it's findable later.
4. Phase 0/2 work is tagged `[soul]`.
5. Capstone work (D.11) is tagged `[soul-capstone]`.
6. Per `quake guard` rules: any compiler-source change goes through the
   guard pipeline; this roadmap doesn't touch the compiler in Phase 0/2 but
   D.11 might if Actor primitives need codegen support.
