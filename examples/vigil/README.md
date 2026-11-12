# VIGIL

`htop`/`btop`-shape system monitor in [Quartz](../../).

```sh
./self-hosted/bin/quartz -I std examples/vigil/main.qz > /tmp/vigil.ll
/opt/homebrew/opt/llvm/bin/llc -filetype=obj /tmp/vigil.ll -o /tmp/vigil.o
clang /tmp/vigil.o -o /tmp/vigil -lm -lpthread
/tmp/vigil
```

## Stack tour for a programming-languages reader

**Quartz** is the language. Self-hosted (gen1 == gen2 byte-identical, true fixpoint), compiles to LLVM IR. Existential generics — `Spark<T>`, `Program<S, M>`, `FrameMsg<M>` are compile-time-checked but vanish at runtime; every value is `i64`. Pattern matching with exhaustiveness, `is` keyword for variant tests, struct update syntax `Struct { ...base, k: v }` for immutable transitions, const-by-default with explicit `var` to opt into mutation. Type inference at function bodies, annotations only at API boundaries.

**Concurrency — the fun part.** `go fn()` spawns a green-threaded goroutine on Quartz's scheduler. VIGIL pumps for stdin input / 2s clock tick / SIGWINCH / sampler harvesting all run as goroutines emitting messages into a single bounded MPSC channel that the main `update(msg, state) → (state, cmd)` loop consumes. Every blocking primitive is **scope-aware**: `scope_recv`, `scope_sleep_ms`, `term_read_key_cancellable` carry a cancellation deadline through the syscall and unwind via a checked `Throws` effect when the parent scope is cancelled. Press `q` and the root runtime scope cancels — within ~50ms every goroutine has cooperatively unwound through Throws and exited. No threads to join, no FDs to leak. `scope_with_cancel(parent)` builds the tree; child scopes inherit deadlines and cancel the parent on first-to-finish unless wrapped to opt out.

**Effects.** Algebraic, type-checked, zero runtime cost. `def foo() can Throws` declares an effect at the type level, `with Throws { throw: handler } do ... end` installs one. Same machinery powers the build system's Reader/Writer/Log effects. Lowered to direct calls — handlers compose statically.

**TUI runtime.** Bubbletea-shaped — `program_new(initial, update, view)` then `program_run`. View is pure `state → string`. `Cmd<M>` is the effect type for the loop: `Cmd::Run(thunk)` runs on a goroutine, `Cmd::Every(ms, thunk)` is a recurring tick (used here for the 2s sample tick), `Cmd::Quit` requests teardown. The runtime owns alt-screen, raw mode, mouse parsing (SGR encoding), SIGWINCH handling, and the scope-cancel discipline. Apps are pure values + an effect description.

**Cell engine.** Sparklines render through a sub-cell **octant blitter** — Unicode 17's new 2×4 octant block from Sept 2024 (`U+1CD00..U+1CDE5`), 8 sub-pixels per terminal cell. The MEM bar uses BMP block elements. The same theme-aware engine + diff renderer + light buffer powers SIGIL (Quartz's roguelike sibling). All multi-byte UTF-8 ships through `style_to_cells` which walks codepoint boundaries.

**Data layer.** `std/sys/proc.qz` reads `/proc/{stat,meminfo,loadavg,pressure/{cpu,memory,io},net/dev,diskstats}` on Linux; shells `top -l 1`, `vm_stat`, `sysctl`, `iostat`, `netstat -ib` on macOS. Pure parsers (unit-tested against fixture strings — 34 specs green) plus a platform-dispatched `proc_take_snapshot(prev)` returning a `Snapshot` value with cumulative counters for delta-based rate computation. Linux-only metrics (PSI, OOM events) auto-suppress on macOS.

**Layout.** Three responsive breakpoints based on terminal cols: ≥240 → 4-across boxed tiles, ≥120 → 2x2, <120 → dense single column. Box borders are rounded `U+256D/E/F/0` and the layout dispatcher picks per-render based on `term_get_width()` updated on SIGWINCH.

## Keys

| Key            | Action                                  |
| -------------- | --------------------------------------- |
| `q` / `Ctrl-C` | quit                                    |
| `?`            | toggle help overlay                     |
| `j` / `↓`      | next process                            |
| `k` / `↑`      | previous process                        |
| `Ctrl-F`       | page down                               |
| `Ctrl-B`       | page up                                 |
| `g`            | top of list                             |
| `G`            | bottom of list                          |
| `M`            | sort by memory / RSS (default)          |
| `P`            | sort by CPU%                            |
| `N`            | sort by name                            |
| `K`            | kill highlighted process (`y` confirms) |

Click any process row to jump the cursor; scroll wheel navigates. Mouse uses SGR encoding (DECSET 1006) — works in Terminal.app, iTerm2, Ghostty, kitty, alacritty, GNOME Terminal, Konsole.

## Distinctive features (vs `btop`)

- **PSI chip** in CPU/MEM panel headers — Linux 4.20+ `/proc/pressure/{cpu,memory}` `some`/`full` averages. The single best load-pressure signal Linux exposes; almost no terminal monitor surfaces it. Hidden on platforms without PSI.
- **OOM event log** — kernel `Killed process` lines from `journalctl -k` / `dmesg`, parsed for victim PID/name/RSS. Renders as a "recent kernel kills" panel only when events exist.
- **Anomaly hint** — rolling p50/p95 baseline per panel; surfaces an `↑ p50/p95 N/M` chip when current sample exceeds p95 of the recent window.
- **Sub-cell sparklines** via Unicode 17 octants — visibly smoother than block-character sparklines elsewhere.
- **Responsive layout** — three breakpoints. Resizes live on SIGWINCH.

## Phase 1 / 1.5 / 2 (shipped)

| Tier  | Items                                                                                                  |
| ----- | ------------------------------------------------------------------------------------------------------ |
| 1     | CPU + MEM + DISK + NET dense layout, process list, vim keys, help overlay, SGR mouse parsing in stdlib |
| 1.5   | PSI chip, sort cycle, kill confirm                                                                     |
| 2     | OOM event log, mouse hit-testing, anomaly hint, responsive boxed-tile layout                           |

## Phase 3 candidates

GPU panel (NVML/`powermetrics`), container view (Docker/podman socket), network flow visualization (DNS-resolved connections), energy/power per-cgroup attribution (RAPL), replay log (atop's killer feature with modern UX), eBPF probe integration (Linux), theme YAML loading.

## Design + roadmap

[`docs/design/SYSMON_DESIGN.md`](../../docs/design/SYSMON_DESIGN.md) — full requirements, feature matrix vs incumbents, architecture, phasing.
