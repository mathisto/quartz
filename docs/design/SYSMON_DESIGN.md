# VIGIL — System Monitor — Design & Requirements

> **Status**: Filed 2026-05-07. Updated 2026-05-07 (Phase 1 ground-truth pass — corrected widget gap-list, see §7).
> **Name**: VIGIL (committed).
> **Companion**: builds on the v0.6 cell engine, theme system, `program_run_raw`, octant blitters, and SIGIL's runic visual language.

The brief: build the best terminal system monitor that exists. Not "another htop alternative" — the best. Synthesize what htop, btop, glances, atop, bottom, nvtop, nmon, and the next-gen tools do well, fix what they do badly, and add what nobody has shipped yet but everybody wants.

This doc is the requirements baseline. It captures (1) what the incumbents do, (2) what their users love and complain about, (3) what we should build, (4) how it fits into our existing engine, and (5) phased delivery.

---

## 1. Survey: the landscape

### htop — the classic
The reference. Process viewer with F-key shortcuts, colored bars, tree view, simple to use. Loved for: muscle memory, immediate readability, mature process management (kill, renice, strace integration). Missing or weak: per-process network bandwidth, per-process IOPS, GPU monitoring, custom themes, historical replay, container awareness, nice graph widgets.

### btop / btop++ — the "modern" leader
The community's current darling. Aristocratos' C++ rewrite of bashtop. Loved for: beautiful visual design, vim keymaps, full mouse support, GPU monitoring (multi-GPU, NVIDIA + AMD, even A100/H100/H200), configurable layout presets, theme files compatible across the bashtop/bpytop/btop family, on-the-fly UI configuration, signal sending. Recent versions added GPU power consumption and per-GPU process attribution. Missing or weak: persistent historical logging (within-session only), no replay mode, container view is basic, no eBPF or syscall-level visibility, limited filtering DSL.

### bottom (btm) — the Rust contender
Cross-platform (Linux/macOS/Windows), low-overhead, vim-keys, customizable widget placement via config, battery + thermal monitoring, network graphs over time. Loved for: cross-platform parity (the only one that's genuinely good on macOS + Windows), config-driven layouts, fast on low-end hardware. Missing: smaller community than btop, fewer themes, no remote / web mode.

### glances — the swiss army knife
Python-based, cross-platform, plugin-driven. Unique features: built-in web UI mode (`-w` flag exposes responsive HTML), client/server remote monitoring, XML-RPC + RESTful JSON API, exports to InfluxDB / CSV / Prometheus / Graphite / ElasticSearch. Container awareness via Docker plugin. Loved for: API access, web mode, plugin extensibility, dense view of 15+ metric categories. Weak: visual polish (looks like a 2010 admin panel), TUI ergonomics (less keyboard-friendly than htop/btop), Python startup latency.

### atop — the time machine
Killer feature: **historical replay**. Atop logs system state to disk every N seconds (default 10 minutes) and you can replay any window with `atop -r logfile -b HH:MM`. Process accounting catches short-lived processes that other tools miss entirely. With `netatop` kernel module, per-process network I/O works. Loved for: postmortem debugging — "the server was slow at 3am, what was running?" Weak: visual presentation is dated; learning curve is steep; the netatop module isn't packaged everywhere.

### nmon — the data exporter
Originally IBM AIX, now Linux. Toggle panels via single keys. Capture mode dumps everything to CSV for spreadsheet analysis. Loved for: data density, CSV export, AIX heritage giving it deep system internals access. Weak: no real-time graphs, dated UX.

### nvtop — the GPU monitor
htop-shaped UI for GPUs. Multi-vendor: NVIDIA, AMD, Apple Silicon (M-series limited), Intel Arc, Huawei Ascend, Qualcomm Adreno, Tenstorrent, Rockchip, MetaX, Enflame, Broadcom VideoCore. Per-process GPU memory and compute attribution. Loved for: filling the GPU-monitoring gap with a familiar UI. Weak: separate tool; no integration with system-level CPU/memory monitoring.

### nvitop — the GPU power user
Python-based, NVIDIA-focused. Goes deeper than nvtop on NVIDIA: process tree, kill/freeze/resume, programmable filters. Loved for: depth. Weak: NVIDIA-only, Python overhead.

### kubetui / dtop / tori / cmonitor — the container natives
- **kubetui** — TUI for Kubernetes resource exploration (pods, services, nodes, configmaps, logs).
- **dtop** — Rust TUI for Docker across multiple hosts.
- **tori** — agent-based multi-server Docker + host monitoring with alerting.
- **cmonitor** — cgroup-aware container performance collector, exports to Influx/Prometheus/Grafana.

Loved for: seeing into containers natively. Weak: each is a separate tool; user has to context-switch between system monitor, container monitor, GPU monitor.

### s-tui — the thermal specialist
CPU stress + thermal/frequency/power graphs. Useful for thermal debugging. Niche.

### ktop — recent show-HN
Themed monitor with charts and OOM tracking (HN, late 2025). The OOM tracking is interesting — most tools don't surface kernel OOM-kill events prominently.

---

## 2. What users actually love (cross-tool patterns)

Synthesized from blog reviews, Reddit threads, GitHub issues, and HN comments:

1. **Visual polish without sacrificing density.** btop set the bar. Soft palettes, rounded boxes, color-coded sections, smooth gauge animations. Users who tried btop rarely go back.
2. **Vim keys.** `j/k` to navigate, `dd` to kill, `/` to search. btop, bottom, and nvtop all do this. Users complain when a tool *doesn't*.
3. **Mouse support.** Click headers to sort. Click cells to inspect. btop made mouse-driven TUI legitimate; everybody else is catching up.
4. **Theme files.** btop's theme format spread to bpytop and bashtop. People share themes. The Catppuccin community alone has theme repos for ~150 tools.
5. **Configurable layouts.** Toggle panes. Save presets (btop's `P` key cycles preset 1..9). Resize via config.
6. **Per-process detail panel.** Drill into a PID and see open files, threads, memory map, signals, stack trace. htop sort of does this; nobody does it well in one panel.
7. **Tree view of processes.** With expand/collapse. htop has it; btop has it; users want this everywhere.
8. **Sortable, filterable process list.** Multi-column sort, search by name/user/cmdline.
9. **Signal sending.** kill / SIGSTOP / SIGCONT / SIGUSR1 from the UI, picker on the right.
10. **GPU integration.** nvtop showed there's appetite. Users want one tool that does CPU + GPU + memory + disk + net, not four.

---

## 3. What users complain about (the gap-list)

These are recurring asks across forums, issue trackers, and review articles:

- **Per-process network bandwidth** — htop doesn't have it. btop has it as system-aggregate but per-process is hard. atop+netatop has it but the kernel module isn't always installable.
- **Per-process disk IOPS** — same story. Most tools show aggregate disk; per-process requires `iotop` (separate tool, root-required).
- **Container-aware everything** — show containers as first-class entities, attribute resources to them, drill into their processes. cmonitor + dtop are partial; nothing is unified.
- **Cgroup pressure metrics (PSI)** — Linux 4.20+ exposes `/proc/pressure/{cpu,memory,io}` showing how much wall-clock time tasks are stalled waiting for that resource. **Almost no terminal monitor surfaces this.** It's the single best signal for "is this machine under load" and it's barely visible anywhere.
- **eBPF / hot-path attribution** — `bcc` / `bpftrace` exist but require separate invocation. Nobody integrates "click a process → show its hot syscalls" into a TUI.
- **OOM-kill event log** — when the kernel OOM-killer fires, the only signal is `dmesg`. Surfacing recent OOM-kills with what they killed and why would be huge.
- **Historical replay** — atop is the only tool that does this and its UX is dated.
- **Persistent baseline / anomaly detection** — "this is unusual for this machine" is something nobody surfaces. Even a simple p50/p95 vs current would be useful.
- **Energy / power** — laptop battery yes, but per-process / per-container energy attribution (Intel RAPL, Apple powermetrics) is a frontier nobody has filled with a clean TUI.
- **Network flow visualization** — connections list yes, but a live "what is this machine talking to" view (DNS-resolved, geo-tagged, flow-volume-bar) is rare. `nethogs` does per-process bytes/sec; nothing combines that with connection topology.
- **Multi-host overview** — glances has client/server but it's clunky. A clean "fleet view" of N hosts in a single TUI is missing.
- **Mobile / web mode that's actually good** — glances has it, but it looks dated. A clean responsive web view on the same backend would be a real win.

---

## 4. Feature matrix

| Feature | htop | btop | bottom | glances | atop | nvtop | **us** |
|---|---|---|---|---|---|---|---|
| Process list + tree | ✅ | ✅ | ✅ | ✅ | ✅ | – | ✅ |
| CPU per-core graph | – | ✅ | ✅ | ✅ | – | – | ✅ |
| Memory bars | ✅ | ✅ | ✅ | ✅ | ✅ | – | ✅ |
| Disk I/O graphs | – | ✅ | ✅ | ✅ | ✅ | – | ✅ |
| Network I/O graphs | – | ✅ | ✅ | ✅ | ✅ | – | ✅ |
| GPU (multi-vendor) | – | ✅ | partial | – | – | ✅ | ✅ |
| Per-proc CPU/MEM | ✅ | ✅ | ✅ | ✅ | ✅ | – | ✅ |
| **Per-proc net** | – | – | – | partial | netatop | – | ✅ |
| **Per-proc IO** | – | – | – | partial | ✅ | – | ✅ |
| Tree view | ✅ | ✅ | – | – | – | – | ✅ |
| Search/filter | ✅ | ✅ | ✅ | – | – | – | ✅ |
| Multi-col sort | partial | ✅ | ✅ | partial | ✅ | – | ✅ |
| Signal send | ✅ | ✅ | ✅ | – | – | ✅ | ✅ |
| Mouse | – | ✅ | – | – | – | – | ✅ |
| Themes | – | ✅ | partial | – | – | – | ✅ (theme YAML) |
| **Cgroup PSI** | – | – | – | – | – | – | ✅ |
| **OOM event log** | – | – | – | – | partial | – | ✅ |
| **eBPF probes** | – | – | – | – | – | – | 🟡 (deferred) |
| **Energy/power** | – | partial | – | – | – | partial | ✅ |
| **Container view** | – | basic | – | partial | – | – | ✅ |
| **Net flow viz** | – | – | – | – | – | – | ✅ |
| Historical replay | – | – | – | – | ✅ | – | ✅ |
| Anomaly hint | – | – | – | – | – | – | ✅ |
| Remote / multi-host | – | – | – | ✅ | – | – | 🟡 (Phase 3+) |
| Web/API export | – | – | – | ✅ | – | – | 🟡 (Phase 3+) |

✅ = will ship. 🟡 = filed, later phase. – = not in tool.

We aim to be the only row in the matrix with PSI, OOM events, network flow viz, and per-process I/O + net all in one tool, with a visual polish that holds its own next to btop.

---

## 5. Requirements

### MUST (Phase 1 — alpha)

#### Data layer
- Process list with: PID, parent PID, user, command, CPU%, RSS, virtual memory, threads, state, start time, nice value.
- System totals: CPU per-core (user/system/nice/iowait/steal/idle breakdown), memory (used/buff/cache/avail/swap), disk (per-volume read/write rate + IOPS + queue depth), network (per-interface RX/TX rate + packets + errors).
- Per-process I/O via `/proc/PID/io` (Linux): read_bytes, write_bytes, syscall counts.
- Per-process network: best-effort via `/proc/net/tcp[6]` + `/proc/PID/fd` socket inode mapping. Document the limit (only counts kernel-attributed bytes; doesn't capture XDP/AF_XDP).
- Cgroup v2 walk: list all cgroups, current memory/CPU usage, and **PSI (`pressure.stall.info`) for cpu/memory/io** with `some` and `full` fractions.
- OOM event log: tail `/dev/kmsg` (or `journalctl -k` fallback) for `Killed process` lines, parse killer/victim/RSS/score, surface in a "Recent kernel events" panel.
- macOS parity for everything reasonably possible: `host_processor_info`, `mach_host_self`, `proc_pidinfo`, `sysctl kern.proc.all`, `IOServiceGetMatchingServices` for I/O. Container/PSI features marked Linux-only with a "not available on this platform" placeholder.

#### UI layer
- 4-pane default layout: CPU (top-left), MEM/swap (top-right), Disk + Net stacked (middle), Process list (bottom). All toggleable; layout presets cycled with `P`.
- Per-core CPU sparklines (octant-rendered for sub-cell smoothness). 60-second window, configurable.
- Memory bar: stacked used/buff/cache/avail with the same theme accent breakdown as btop.
- Process list: sortable columns (header click + keyboard `<` `>`), search via `/`, filter via `\\`, signal-send via `K` or right-click context menu.
- Tree view toggle (`t`).
- Detail panel (`Enter` or right-click): expand selected process to show open files, memory maps, threads, recent syscalls (best-effort via `lsof`, `pmap`, `/proc/PID/status`), and the **process's own PSI** if cgroup-attributable.
- Help overlay (`?`) listing all keybindings, like brogue-tribute v0.12's.
- Vim keys: `hjkl` for navigation, `dd` to kill, `/` to search, `:` for command mode (planned), `gg` `G` for top/bottom of process list.
- Mouse: click column headers to sort, click rows to select, scroll to scroll. (Requires TUI engine mouse support — tracked as Phase 1 prerequisite.)

#### Visual layer
- Theme YAML compatible with our existing TUI theme loader. Ship 5 themes at minimum: Catppuccin Mocha (default), Catppuccin Latte, Gruvbox Dark, Tokyo Night, Solarized Dark.
- Use octant blitter sparklines for the per-core CPU graphs and net/disk throughput charts. Sub-cell vertical resolution = sparklines that genuinely look smooth in a 1-cell-tall row. **This is an aesthetic differentiator nobody else has** — most monitors use Unicode block characters at 1/8 cell granularity; ours use octant 2×4 = 1/8 cells too but with full Unicode 17 fidelity.
- Light buffer / glow on the process under cursor (subtle; matches SIGIL's "active card" glow pattern).
- Diff renderer (already shipped) means only the changed cells re-render per tick — even at 4Hz refresh on a busy machine, the bandwidth is trivial.

### SHOULD (Phase 2 — beta)

- **Historical replay**: log every sample to a binary file (~1KB per sample × 1Hz × 24h ≈ 86MB/day). Open with `vigil --replay file --at HH:MM` to scrub a time window with `←/→`. atop's killer feature, our UX.
- **Container-first view**: detect Docker / podman / containerd / cri-o, list containers as top-level entities with their own resource attribution, drill in to see contained processes. Same view-model as the system process list, just scoped.
- **Anomaly hint**: rolling p50/p95 per-resource over the past hour. If current value > p95, highlight the cell with a subtle pulsing accent. ("This CPU usage is unusually high for this machine.") Not full anomaly detection — just a frame of reference.
- **Network flow visualization**: dedicated panel toggleable on `n`. Live list of active connections with: local socket, remote host (DNS-resolved, async), bytes/sec rate, process owner. Optional geo-IP via local MaxMind DB if available.
- **Energy / power**:
  - Laptop battery state (existing `/sys/class/power_supply` / `IOPMUSBManagementClient` on macOS).
  - Per-CPU package power via Intel RAPL (`/sys/class/powercap/intel-rapl/`) or Apple `powermetrics`.
  - Stretch: per-cgroup energy attribution via `kepler` if installed.
- **Mouse-resizable panes** — drag pane borders to resize.
- **Custom dashboards**: save N pane layouts under named profiles. Switch with `1`..`9`. Persists in config file.
- **eBPF integration (optional, Linux only)**: ship a small set of bpftrace scripts behind an `--ebpf` flag. "Top syscalls per process this second", "block I/O latency histogram", "TCP retransmits live". Don't make it required; degrade gracefully when bcc/bpftrace aren't installed.

### MAY (Phase 3 — stretch)

- **Remote / multi-host mode**: client-server, one binary serves over a Unix socket or TCP, another connects with `vigil connect host:port`. Multi-host fleet view tiles N hosts as compact summaries; expand any tile to drill in.
- **Web UI mode**: like glances `-w` but built on top of the same data layer as the TUI. Modern responsive HTML; same theme system feeds CSS.
- **Prometheus / OTLP exporter**: serve `/metrics` so this thing can also be your sidecar exporter on edge boxes.
- **Workload comparison view**: "what changed between 5 minutes ago and now?" Diff two snapshots side-by-side.
- **Alerting**: "if memory pressure full > 30% for 5 minutes, write a marker to the replay log" — gives postmortem debugging breadcrumbs.

---

## 6. What makes us better than btop

btop is the best-in-class incumbent. To be meaningfully better, we need each of these:

1. **Cgroup PSI is front and center.** No other terminal monitor does this. PSI is the single best load-pressure signal Linux exposes and it's invisible everywhere. We surface it in the CPU/MEM/Disk panels as a small color-coded chip ("CPU pressure: some 12% / full 4%").
2. **Octant-blitter sparklines.** Sub-cell precision charts. Visually smoother than block-character sparklines. We already have the engine. Nobody else does.
3. **OOM event log as a first-class panel.** Most users only learn about OOM-kills via grep in dmesg. We surface them.
4. **Per-process I/O + per-process network without a kernel module.** We use what's in `/proc` natively (best-effort, document the limits). atop+netatop is more accurate but requires kernel modules; ours works on stock kernels.
5. **Container-first view from day one.** btop's container view feels bolted-on. Ours is a first-class top-level entity in the data model.
6. **Theme parity with existing tools.** btop themes import directly. Catppuccin / Gruvbox / Tokyo Night themes work day-1.
7. **Replay** (Phase 2). atop has it; nobody else; ours has a modern UX.
8. **The TUI engine is ours.** We can do effects nobody else can. Glow on the focused process, smooth gauge animations driven by our pulse modulator, theme-aware coloring of unusual values. None of this is critical, all of it makes the tool feel alive.

---

## 7. Architecture (how it fits the engine)

### Process model

One main thread runs the TUI loop via `program_run_raw(tick_ms: 250, body)`. 4Hz refresh — fast enough to feel live, slow enough to not waste CPU monitoring CPU.

A **sampler goroutine** runs at the same cadence (or higher, e.g. 10Hz, if we want a smooth graph at 4Hz render). It reads `/proc`, builds an immutable `Snapshot` struct, and pushes it on a channel. The main thread receives the latest snapshot each tick.

```be
go fn() do ->
  with Throws { throw: cancel_handler } do ->
    while true
      var snap = sampler_take_snapshot()
      scope_send(snap_ch, snap)
      scope_sleep_ms(SAMPLE_INTERVAL_MS())
    end
  end
end
```

The DNS resolver for the network flow view runs on its own goroutine (async resolution shouldn't block the UI). Container engine probing (Docker socket, etc.) likewise.

### Data model

```be
struct Snapshot
  timestamp_ns:     Int
  cpu_per_core:     Vec<CpuStat>
  cpu_aggregate:    CpuStat
  memory:           MemStat
  swap:             SwapStat
  disks:            Vec<DiskStat>
  nics:             Vec<NetStat>
  gpus:             Vec<GpuStat>
  cgroups:          Vec<CgroupStat>     # Linux only
  pressure:         PressureStat        # /proc/pressure
  processes:        Vec<ProcStat>
  containers:       Vec<ContainerStat>
  oom_events:       Vec<OomEvent>       # rolling window
  power:            PowerStat
end
```

All fields use C.1 struct update syntax for transitions. State updates are pure functions of `(Game, Msg) → Game` shaped exactly like SIGIL — proven pattern.

### View model

Mirrors SIGIL's `build_root_plane` pattern: a top-level composer that walks the panel tree, builds each panel's plane, blits onto a root plane with the `bl::BlendMode` for the panel type. The diff renderer compares prior frame to current and emits only changed cells.

Panes:
- `cpu_panel` (per-core sparklines + aggregate)
- `mem_panel` (used/buff/cache bar + swap bar)
- `disk_panel` (per-volume sparklines + IOPS/queue)
- `net_panel` (per-NIC sparklines + RX/TX numbers)
- `gpu_panel` (per-GPU memory bar + utilization sparkline)
- `process_panel` (the workhorse — sortable list)
- `flow_panel` (Phase 2 — network flows)
- `container_panel` (Phase 2 — containers as top-level)
- `events_panel` (recent OOM kills, kernel warnings)
- `pressure_panel` (cgroup PSI breakdown)
- `power_panel` (battery / RAPL / per-cgroup energy)
- `detail_panel` (drill-in for selected process / container / GPU / NIC)

Layouts are described declaratively (which panes, where, what size) and stored in the config file. Preset 0 is "all panes default sizes"; presets 1-9 are user-saved.

### What's already in `std/tui/`

Ground-truth survey before we plan: the engine has shipped more than the original requirements pass assumed. What VIGIL composes:

| Need | Status | Module |
|---|---|---|
| Generic scrollable list w/ selection + search | ✅ shipped | `std/tui/widgets/list.qz` |
| Single-line text input + validation | ✅ shipped | `std/tui/widgets/text_input.qz` |
| Modal overlay (z-stacked) | ✅ shipped | `std/tui/widgets/overlay.qz` |
| Confirmation dialog (e.g. kill confirm) | ✅ shipped | `std/tui/widgets/confirm.qz` |
| Tabs / status bar / toast / progress / spinner | ✅ shipped | `std/tui/widgets/{tabs,status_bar,toast,progress,spinner}.qz` |
| Viewport / focus / form | ✅ shipped | `std/tui/widgets/{viewport,focus,form}.qz` |
| Help modal | ✅ shipped | `std/tui/help.qz` |
| Octant sub-cell pixel blitter | ✅ shipped | `std/tui/octant.qz` |
| Theme system | ✅ shipped | `std/tui/theme.qz` |
| Light buffer / glow | ✅ shipped | `std/tui/light.qz` |
| Diff renderer | ✅ shipped | `std/tui/render.qz` |
| Non-TEA runtime (sampler-driven main loop) | ✅ shipped | `std/tui/runtime.qz::program_run_raw` |
| **Sparkline widget (octant-backed)** | ⛔ gap | `std/tui/widgets/spark.qz` |
| **Mouse event parsing in runtime** | ⛔ gap | `std/tui/runtime.qz` (FrameMsg::Mouse + DECSET 1006) |
| **System info reader** | ⛔ gap | `std/sys/proc.qz` |

VIGIL ships two engine-level primitives (sparkline + mouse) and one new module (`std/sys/proc.qz`); the rest is composition. Spark + mouse pay back well beyond VIGIL — every dashboard, every list-with-mouse, every chart wants these.

### Reading /proc / sysctl

A new `std/sys/proc.qz` module wraps the syscalls / file reads. On Linux, /proc is text files we can read with existing `std/io`. On macOS, we use `sysctl` + `proc_pidinfo` + `host_processor_info` via FFI. Both wrapped behind a single `Snapshot` builder.

Stretch: `std/sys/cgroup.qz` for cgroup v1 + v2 traversal with PSI parsing.

---

## 8. Phasing

Each phase is a discrete, ship-able milestone. Estimates in quartz-time.

### Phase 1 — alpha (~2 quartz-days, revised)
- **Engine prereq**: mouse event parsing in `std/tui/runtime.qz` (FrameMsg::Mouse + DECSET 1006/1002).
- **New widget**: `std/tui/widgets/spark.qz` (octant-backed sparkline). Other widgets compose from already-shipped primitives.
- **New module**: `std/sys/proc.qz` reader (Linux /proc + macOS sysctl subset).
- Default 4-pane layout: CPU + MEM + Disk/Net + Process.
- Process list (composed atop existing `widgets/list.qz`): sort, search via `widgets/text_input.qz`, signal-send via `widgets/confirm.qz`, tree view, kill confirmation.
- Cgroup PSI display in CPU/MEM/Disk panels (Linux only — graceful "not available" on macOS).
- 5 themes shipped.
- Help overlay (existing `std/tui/help.qz`).
- Estimate revised down from ~3 to ~2 quartz-days because list/input/modal/confirm/help/viewport/status-bar/tabs/etc are already in `std/tui/widgets/`.

### Phase 2 — beta (~3 quartz-days)
- GPU panel (NVIDIA via nvidia-smi parsing or NVML FFI; AMD via /sys; Apple Silicon via `powermetrics` and `IOService`).
- Container panel (Docker socket, podman, containerd; cgroup-driven attribution as fallback).
- Network flow panel.
- Energy / power panel.
- Anomaly hint (rolling p50/p95).
- Custom layouts (save / load N profiles).
- Mouse pane resize.
- Replay log (binary format, scrub UI).

### Phase 3 — stretch (~5 quartz-days)
- eBPF probe integration (Linux).
- Remote / multi-host fleet view.
- Web UI mode with shared theme.
- Prometheus / OTLP exporter.
- Workload comparison view.

Total: ~11 quartz-days for everything. With the project's calibration (Prime Directive 9 — divide traditional estimates by 4), that's a 2-3 calendar-week sprint. Phase 1 alone is the playable demo; that's where the showcase is.

---

## 9. Open questions

1. **macOS GPU integration scope.** Apple Silicon doesn't expose per-process GPU usage cleanly. We can show overall GPU utilization via `powermetrics`, but per-process GPU attribution requires private APIs. Decide: silently skip per-process GPU on macOS (likely), or invest in an Endpoint Security framework hack (unlikely).

2. **Replay storage format.** Plain binary records vs. SQLite vs. a custom log file with framing. Argues for SQLite: queryable, durable, well-trodden. Argues against: dependency. Default plan: custom binary log with append-only framing; offer SQLite export as Phase 3 addon.

3. **Container detection latency.** Docker socket polling has latency; Docker events stream is immediate. Stream is harder. Default: 1s polling for Phase 2; events stream as Phase 3 polish.

4. **eBPF licensing / kernel headers.** bcc requires kernel headers; not always installed. CO-RE (libbpf) is portable but harder to ship. Phase 3 decision: ship bpftrace-script integration first (calls out to `bpftrace` if installed); CO-RE later.

5. **What's the right refresh rate?** btop defaults to 2s (0.5Hz) for low impact. atop is 10s. nvtop is 0.5s. Our default? 4Hz feels live but burns CPU. Default 2Hz with a `--rate` flag and an interactive `+/-` toggle (1Hz / 2Hz / 4Hz / 10Hz).

6. **The name.** Working name is **VIGIL** — pairs with SIGIL's runic theme (vigil = a watch / observation, vigil → augury → divination). Alternatives: AUGUR (clearer "scrying" semantics), LUMEN (light / illumination), PULSE (vital signs). Want a 5-letter or shorter one-word name that the user types as the binary.

---

## 10. Naming

**VIGIL** — committed. Short, classic, pairs with SIGIL aesthetically (same letter count, both end in -IL, both sound like quiet rituals), no namespace conflicts, binary name `vigil` unambiguous.

Alternates considered (AUGUR, LUMEN, PULSE, SPECTRE) are documented in the doc's filed history and not under active reconsideration — VIGIL is the name.

---

## 11. Why this is worth doing

The terminal system monitor space is mature. htop is 25 years old. btop has been the leader for ~5. What's left to do?

Three things, all of which we can hit:

1. **Surface the metrics that exist but are invisible.** PSI, OOM events, cgroup attribution, per-process I/O. The kernel emits them; nobody is rendering them well. Pure synthesis play.
2. **Visual polish that matches modern game-engine quality.** We have the only TUI engine in this space with an octant blitter, a light buffer, and a theme-aware diff renderer. No system monitor has ever had this level of cell-engine sophistication. The aesthetic delta is a real moat.
3. **A unified view.** htop + nvtop + nethogs + iotop + atop + ctop is six tools. We can be one. Containers, GPUs, energy, network flows, replay — all unified.

The result: a tool that's strictly more capable than btop on Linux, comparable on macOS, with a visual language that feels closer to a game UI than an admin tool. The kind of thing that ends up in dotfiles within a year.

That's the bar.

---

## 12. Next steps

1. ~~User picks the name~~ — VIGIL committed.
2. Build `std/tui/widgets/spark.qz` (octant-backed sparkline). Validates the chart pattern; immediately useful.
3. Build `std/sys/proc.qz` (Linux /proc + macOS sysctl subset). Data layer foundation.
4. Wire mouse parsing into `std/tui/runtime.qz` (FrameMsg::Mouse + DECSET 1006/1002 enable/disable).
5. Wire the default 4-pane VIGIL layout in `examples/vigil/main.qz`.
6. Iterate on the visual polish until it feels alive.
7. Ship Phase 1 alpha; gather feedback; proceed to Phase 2.

(`list`, `text_input`, `overlay`, `confirm`, `help`, `tabs`, `status_bar` already in tree — see §7.)
