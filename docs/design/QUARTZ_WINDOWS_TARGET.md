# Quartz on Windows — design memo

**Status:** Phase 1 ✅ + Phase 3 ✅ + Phase 4 polish ✅ + Phase 5a/5b/5c/5d/5e/5f ✅ + ws2_32 user FFI ✅ shipped 2026-05-22. **The Quartz Windows target is closed for the in-tree milestone, including the ws2_32 user-facing socket FFI substrate that the original close-out filed forward.** Every Phase-5 sub-phase + the ws2_32 follow-on landed in a single calendar day; the remaining work (running on an actual Windows host, debugger-symbol polish, TUI host) is filed-forward as separate epics. Closing the ws2_32 epic surfaced and fixed a parser bug (`cfg_os_from_target` matched `gnu` before `windows`, so `*-pc-windows-gnu` was misclassified as Linux); see "Parser fix — `cfg_os_from_target` ordering" below for the post-mortem.
**Original date:** 2026-05-22 (memo + Phase 1 + Phase 3 same day).
**Trigger:** eli (`~eli_oat/h`) asked if Quartz can target Windows so the
hyperbouba port (`examples/hyperbouba/`) builds and runs there. The user has a
Windows machine on standby.

This memo answers the question "what would it take?" by inventorying every
Quartz toolchain + runtime touchpoint that currently assumes Darwin or Linux,
proposes phasing, and lands on a thin-slice MVP scope.

## Status at 2026-05-22 PM

| Phase | Status | Commit | Notes |
|-------|--------|--------|-------|
| 1 — Windows IR emission | ✅ shipped | `7452e867` | hello.exe (262 KB → 259 KB after Phase 4) cross-compiles from Darwin |
| 2 — stub-or-degrade async | ✅ folded into Phase 1 | `7452e867` | `go fn()` traps; pure-compute paths run |
| 3 — hyperdrive.exe | ✅ shipped | `2247757b` | 1.3 MB PE32+; one missed `eputs` stderr emit site fixed (pre-existing Linux latent bug too) |
| 4 — runtime polish | ✅ shipped | this commit | five runtime helpers + DX (xbuild:windows + `make windows`) |
| 5a/b/c/d/e/f — IOCP scheduler | ✅ shipped | `4c091778`–`957484a8` | pthread→Win32 + IOCP core + timer heap + proc-exit + AFD.SYS + acceptance gate. See §"Phase 5 — IOCP scheduler" below. |
| ws2_32 user FFI | ✅ shipped | this commit | `std/ffi/socket.qz` Windows block — full surface (WSAStartup, socket-family, closesocket, ioctlsocket, WSAPoll, WSAGetLastError) + four cross-platform `socket_*` helpers + `socket_smoke.exe` (~219 KB) + `xbuild:ws2` gate. Surfaced and fixed a parser bug (cfg_os_from_target ordering); see §"Parser fix" below. |

**Phase 4 runtime helpers landed:**

- `qz_file_size` + `qz_file_mtime` via `GetFileAttributesEx` →
  `WIN32_FILE_ATTRIBUTE_DATA` (was: `-1` stub).
  FILETIME→Unix-epoch conversion subtracts `116444736000000000` (100ns ticks
  between 1601-01-01 and 1970-01-01) and divides by `10000000`. Unblocks
  hyperbouba `--dev` live reload.
- `__qz_time_mono_ns` via `QueryPerformanceCounter` +
  `QueryPerformanceFrequency` (was: mingw-w64 `clock_gettime` shim).
  Overflow-safe `(c/f)*1e9 + (c%f)*1e9/f` split. Drops the runtime
  `libwinpthread.dll` dependency for pure-compute Windows binaries — `hello.exe`
  now imports only `bcrypt.dll`, `KERNEL32.dll`, and the UCRT forwards.
- `qz_crypto_rand_int` via `BCryptGenRandom` with
  `BCRYPT_USE_SYSTEM_PREFERRED_RNG` (flag = 2) (was: `@abort` trap). Traps
  on non-zero `NTSTATUS` to surface a broken crypto layer loudly rather
  than degrade silently. Adds `-lbcrypt` to the Windows link.
- `__qz_mem_peak_rss` via `K32GetProcessMemoryInfo` (kernel32-exported
  variant; avoids `-lpsapi`) reading `PeakWorkingSetSize` at offset 8 of
  `PROCESS_MEMORY_COUNTERS` (was: `ret 0` stub).
- `qz_print_backtrace` via `RtlCaptureStackBackTrace` + `fprintf("  0x%llx\\n")`
  loop to `__acrt_iob_func(2)` stderr (was: no-op stub). Addresses only —
  symbolicate externally with `addr2line` / `llvm-symbolizer`.

**DX shipped:**

- `quake xbuild:windows` — one-line Quartz→llc→zig-cc pipeline that produces
  `tmp/xbuild-windows/hello.exe` and verifies PE32+ x86-64 + prints
  resolved DLL imports.
- `make windows` in `examples/hyperbouba/Makefile` — shortcut for
  `make TARGET=x86_64-pc-windows-gnu`. Adds `-lbcrypt` to the Windows
  link flags.

## Original phasing memo (preserved for context)

## Goals (in priority order)

1. **Build `hyperdrive.exe` from a Darwin host** — the windowed hyperbouba
   runtime, running on Windows. Concrete demo: `make hyperdrive.exe` on Mac,
   copy to the Windows machine, run, see the framebuffer.
2. **Generalise to a Windows subset of Quartz** — any pure-compute Quartz
   program (no `go fn()`, no async I/O, no HTTP server) compiles for Windows.
3. **(Eventual)** Full Quartz-on-Windows parity — scheduler, async I/O,
   threading, stdlib. This is **not** in scope for the first deliverable.

The thin slice is the unlock. Once a single `.exe` ships, every subsequent
Windows touchpoint is incremental.

## Prior art (D2: how does the world solve this?)

| Toolchain | Cross from non-Windows host | Mechanism |
|-----------|-----------------------------|-----------|
| Rust | `cargo build --target x86_64-pc-windows-gnu` | `lld-link` + `mingw-w64` libs OR `cargo-zigbuild` (zig cc) |
| Go | `GOOS=windows GOARCH=amd64 go build` | Native cross-compiler, statically linked |
| Zig | `zig build -Dtarget=x86_64-windows-gnu` | Self-hosted cross-compiler, ships libc headers |
| Swift | Swift SDK for Windows | Cross-SDK with WinSDK + WinUCRT bindled |
| OCaml | flexdll + cygwin/mingw | Historically painful; ocaml-windows project ongoing |

**zig cc** is the dominant pattern for "compile C-and-friends to Windows from
a non-Windows host" — it bundles libc headers and `lld-link`, and it's already
the upstream hyperbouba C side's chosen cross-compiler (`c/hyperdrive/Makefile`
lines 32-44: `CC = zig cc -target $(TARGET)`, with explicit Windows branch
emitting `-lopengl32 -lgdi32`).

This is the leverage. Quartz emits LLVM IR text → `llc` lowers to a PE/COFF
`.obj` → `zig cc -target x86_64-windows-gnu prog.obj -o prog.exe -l...`
produces a Windows binary. **The linker problem is solved.** The remaining
work is on the Quartz side: emit the right triple, emit the right runtime
declarations, branch any platform-specific intrinsic.

## Inventory: what needs to change

Survey done 2026-05-22 against trunk @ `0cbe2f4e`. Every citation is
`file:line`. POSIX = already-portable; Darwin-only = blocker; Win-equivalent =
maps cleanly to a documented Windows API.

### 1. Target triple + datalayout — clean fix

`self-hosted/backend/codegen_runtime.qz:1987-2014` defines
`cg_emit_target_info(out, target)` with 7 hardcoded branches:
`x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-apple-macosx`,
`x86_64-apple-macosx`, `wasm32-wasi`, `aarch64-unknown-none`,
`x86_64-unknown-none-elf`, defaulting to aarch64-apple-macosx.

**Missing for Windows:**
- `x86_64-pc-windows-msvc` (PE/COFF, MSVC ABI)
- `x86_64-pc-windows-gnu` (PE/COFF, GNU ABI — what zig cc emits by default)
- `aarch64-pc-windows-msvc` (Windows on ARM)

LLVM data layouts for each are documented and stable. This is a **mechanical
6-line patch**: 3 new branches in `cg_emit_target_info`, 2 new branches in
`get_host_target()` at `self-hosted/quartz.qz:1460-1472`, and a Windows
`cfg_get_os()` stub at `self-hosted/frontend/parser.qz:8020-8029` (the
shape's already there, just unfilled).

### 2. Runtime extern declarations — branch and stub

`self-hosted/backend/codegen_runtime.qz:11119-11327` is
`cg_emit_runtime_declares` — ~361 LLVM `declare` statements. Three categories:

**(a) Portable libc (lines 11128-11196).** `puts`, `printf`, `sprintf`,
`fopen`, `fclose`, `fread`, `fwrite`, `fseek`, `malloc`, `free`, `mmap`,
`munmap`, `memcpy`, `memset`, `qsort`, `strlen`, `strcmp`, `strdup`, `getenv`,
`stat`, `remove`, `rename`, `opendir`, `readdir`, `closedir`. **All
available** in MSVCRT / UCRT on Windows. ✓

**(b) POSIX-only — needs Windows equivalent or stub (lines 11218-11265).**

| Symbol | Windows equivalent | Effort |
|--------|--------------------|--------|
| `pipe`, `dup`, `dup2` | `CreatePipe`, `DuplicateHandle` | shim or skip |
| `fcntl` | (no direct equivalent — POSIX-only) | stub for v1 |
| `popen` / `pclose` | `_popen` / `_pclose` (MSVCRT, underscored) | trivial |
| `pthread_*` (create, join, mutex, cond, rwlock) | `CreateThread`, `CreateMutex`, `CreateEvent`, `SRWLOCK`, `CONDITION_VARIABLE` | non-trivial (see §4) |
| `clock_gettime` | `QueryPerformanceCounter` + `QueryPerformanceFrequency` | helper rewrite |
| `nanosleep` | `Sleep` (ms-resolution) or `WaitableTimer` | helper rewrite |
| `setjmp` / `longjmp` | `_setjmp` / `longjmp` (MSVC has them) or SEH | drop-in mostly |
| `signal` | `signal` (MSVC has subset) | drop-in subset |
| `sysconf` | `GetSystemInfo` for page size etc. | stub |

**(c) Platform-aware (line 11200-11204).** `@stderr` (Linux) vs `@__stderrp`
(Darwin/BSD). Windows: `__iob_func()[2]` on UCRT, or `stderr` macro. Needs a
third branch.

### 3. Scheduler + async I/O — the real blocker

`self-hosted/backend/codegen_runtime.qz:6815-7288` (and the parallel
freestanding block at ~10350) emits ~400 lines of LLVM IR that constitute the
event loop:
- macOS: `kqueue` + `kevent` (lines 6842-7288)
- Linux: `epoll_create1`, `epoll_ctl`, `epoll_wait` (else branch)
- Timer registration, process monitoring, socket multiplexing

**Windows equivalent: IOCP** (I/O Completion Ports — `CreateIoCompletionPort`,
`GetQueuedCompletionStatus`, overlapped I/O). Semantically different from
kqueue/epoll: completion-based vs readiness-based. A faithful port is
several days of careful work plus testing.

**The thin slice escape hatch:** the hyperdrive windowed runtime does not
actually need this. The `--frames N` headless mode is pure compute (no
sockets, no async file I/O, no `go fn()` after init). The windowed runtime
uses TIGR's blocking `tigrUpdate` for the present, runs a single-threaded
frame loop, and only touches the scheduler if user code does. **For the v1
MVP we can ship Windows with the scheduler stubbed out — any program that
calls into it gets a runtime panic. That's an explicit subset.**

`std/net/http_server.qz` is kqueue-only (`Line 3`: "kqueue event-loop
server"). Windows v1 excludes it.

### 4. Threading — pthread_create vs CreateThread

`self-hosted/backend/cg_intrinsic_conc_sched.qz:2000-2010` calls
`pthread_create` with the standard 4-arg signature. Windows's `CreateThread`
has 6 args and returns `HANDLE` (opaque pointer) not `int`. Same shape, more
args.

**v1 strategy:** stub. If `go fn()` is called on Windows v1, panic at startup
("threading not supported on Windows yet"). Phase-2 work.

### 5. File metadata — stat struct offsets

`self-hosted/backend/codegen_runtime.qz:9178-9223` reads `stat()` buffer
fields by hardcoded byte offset (`st_size` at 48 on Linux, 96 on macOS arm64).
Windows uses an entirely different API (`GetFileAttributesEx` →
`WIN32_FILE_ATTRIBUTE_DATA` with `ftLastWriteTime`, `nFileSizeHigh`,
`nFileSizeLow`).

**v1:** rewrite `qz_file_size` / `qz_file_mtime` to branch on target and call
the Windows API when target is Windows. ~30 LoC.

### 6. Monotonic clock

`__qz_time_mono_ns()` at `codegen_runtime.qz:2902-2923` uses
`clock_gettime(CLOCK_MONOTONIC)` with different constants on Darwin (6) vs
Linux (1). Windows: `QueryPerformanceCounter` + `QueryPerformanceFrequency`,
~15 LoC of LLVM IR.

### 7. Memory RSS

`mem_peak_rss()` at `codegen_runtime.qz:2928-3040` uses
`mach_task_basic_info` on Darwin, `/proc/self/statm` on Linux. Windows:
`GetProcessMemoryInfo` from `psapi.dll`. Used by dudect smoke + scheduler
load reporting; non-essential for v1 — can return 0.

### 8. Quakefile build pipeline

`Quakefile.qz:3430-3447` defines `_linker()` and `_maybe_codesign()` with
`@cfg(os: "macos")` and `@cfg(os: "linux")` branches. Windows needs:

```
@cfg(os: "windows")
def _linker(): String = "lld-link"  # or "clang"; both work

@cfg(os: "windows")
def _maybe_codesign(path: String): Void = return   # no-op
```

Three lines.

### 9. Hyperbouba's own Makefile

`examples/hyperbouba/Makefile:36-44` branches Darwin vs else (Linux). No
Windows branch. The upstream hyperbouba C-side Makefile already shows the
shape: `-lopengl32 -lgdi32` for TIGR on Windows, `-lwinmm` or `-ldsound` for
miniaudio. Adding a Windows branch is ~10 lines once the Quartz side can
emit Windows-targeted IR.

### 10. TIGR + miniaudio — the C shims

Both vendored libraries ALREADY have Windows backends:
- `tigr.c:37`: `#include <windows.h>` — full Win32 GDI backend
- `miniaudio.h`: WASAPI, DirectSound, WinMM backends all present

**No C-side porting work needed** — both libraries are self-contained and
cross-platform. zig cc with `-target x86_64-windows-gnu` compiles them
straight through.

## Two paths

### Path A — thin-slice MVP (recommended)

Ship the smallest Quartz subset that produces `hyperdrive.exe`. Document
limitations. Phase further work behind that win.

**Subset boundary:**
- ✅ Pure compute, file I/O (synchronous), stdout/stderr, malloc, libc strings
- ✅ TIGR-style windowed apps (single-threaded frame loop, blocking present)
- ✅ Cross-compile from Darwin via `zig cc -target x86_64-windows-gnu`
- ❌ `go fn()` — panic at startup if any task spawned
- ❌ Async I/O / HTTP server / WireGuard — runtime stub
- ❌ pthread mutex etc. — runtime stub

**Phase 1 — Windows IR emission (1 day, ~2 quartz-days estimate)**

Quartz can produce Windows-targetable LLVM IR. Programs that don't call
into scheduler/threading/IOCP can be cross-compiled.

- Add Windows target triple + datalayout entries to `cg_emit_target_info`
- Add Windows host stub to `get_host_target()` + `cfg_get_os()`
- Add Windows linker entry to `Quakefile.qz`
- Branch `__qz_time_mono_ns`, `qz_file_size`, `qz_file_mtime` for Windows
- Branch `@stderr` / `@__stderrp` for Windows (`__iob_func` or UCRT
  equivalent)

Acceptance: a hello-world `.qz` compiles to `hello.exe` on Darwin via
`quartz --target x86_64-pc-windows-gnu hello.qz > hello.ll && llc hello.ll -filetype=obj -o hello.obj && zig cc -target x86_64-windows-gnu hello.obj -o hello.exe`.

**Phase 2 — Stub-or-degrade everything async (1 day)**

Programs that don't use `go fn()` / scheduler / async I/O compile and run.
Programs that do compile but panic-at-startup with a clear message.

- `cg_emit_runtime_declares` branches: emit Windows-equivalent declarations
  where they map cleanly (`_popen`, `_pclose`, `_setjmp`, `signal`); emit
  empty stubs otherwise (define-as-trap-fn)
- Scheduler init: panic if called under Windows runtime
- pthread externs: stub as `@unreachable` traps

Acceptance: a Quartz program with `go fn()` compiles for Windows and the
trap fires at task spawn with the expected message; a program without
`go fn()` runs cleanly.

**Phase 3 — Hyperdrive.exe (1-2 quartz-days)**

Cross-compile the hyperbouba windowed runtime. C side already supports
Windows; Quartz side gets a Makefile Windows branch.

- `examples/hyperbouba/Makefile` Windows branch (`-lopengl32 -lgdi32` for
  TIGR, `-lole32 -lwinmm` for miniaudio with WASAPI)
- Drive via `make TARGET=x86_64-windows-gnu`
- Acceptance: produce `hyperdrive.exe`, transfer to Windows machine, launch,
  see TIGR window with `examples/hello.hb`'s output.

**Phase 4 — Iterate (further work, not in scope for this memo)**

Real IOCP scheduler, pthread → CreateThread, Windows HTTP server, dudect on
Windows, mlkem on Windows, etc. Each item incremental.

**Total Path A scope: ~5 quartz-days for `hyperdrive.exe` running.**

### Path B — complete Windows runtime first

Build a real IOCP scheduler, full threading port, every stdlib touchpoint,
test matrix on Windows, then ship.

**Total scope:** 3-4 quartz-weeks. Higher confidence, larger commitment,
no demo until the end.

**Recommendation: Path A.** The user's stated goal is `hyperdrive.exe` on
their Windows machine. Path A delivers that fast, documents the subset
honestly, and the Phase 4 backlog is real but not blocking.

## Decision points (need answers before Phase 1)

1. **Default Windows ABI: msvc or gnu?** zig cc defaults to `gnu` (uses
   mingw-w64 internally). MSVC ABI matters if linking against MSVC-built
   DLLs. For self-contained binaries the choice is mostly invisible. We can
   add both; pick one as Quakefile default. Recommendation: `gnu` (matches
   zig cc default, matches upstream hyperbouba C side).

2. **Architecture: x86_64 only, or aarch64 too?** ARM64 Windows exists
   (Snapdragon X laptops) but the user's machine is likely x86_64. Ship
   x86_64 v1; aarch64 is one extra `cg_emit_target_info` branch.

3. **Linker: lld-link, zig cc, or clang?** All three work. zig cc is what
   the upstream hyperbouba C-side uses, and it bundles the headers + import
   libs (`kernel32`, `user32`, `gdi32`, `opengl32`, `winmm`, `ole32`). For
   consistency: use zig cc as the cross-link driver.

4. **CRT: UCRT or MSVCRT?** UCRT is Microsoft's official modern C runtime
   shipped with Windows 10+. MSVCRT is legacy. zig cc defaults to mingw-w64
   which uses UCRT on recent Windows. Use UCRT.

5. **Does the Phase-2 trap-on-async strategy break any qspec tests?**
   We don't run qspec on Windows v1. Phase 4 work problem.

## Open questions / risks

- **Is `clock_gettime`'s constant `CLOCK_MONOTONIC` portable to mingw-w64's
  pthread shim?** mingw-w64 has a `clock_gettime` shim. If yes, we get to
  reuse the macOS code path with the Linux constant value (1). If no, we
  need a fully separate Windows time path.
- **Does `llc` reliably emit PE/COFF when given `-mtriple=x86_64-pc-windows-gnu`
  via the IR's `target triple` directive?** It does (this is standard
  LLVM functionality), but our datalayout string needs to exactly match the
  target — wrong datalayout produces wrong code silently.
- **Does the Quartz IR use any backend optimisation passes that assume
  System V or AAPCS calling conventions?** Need to audit
  `self-hosted/backend/cg_intrinsic_*.qz` for explicit calling conventions
  in declares — if any say `ccc` (System V), they're fine; if `aapcs`, that
  needs branching. Spot check during Phase 1.
- **Quake guard fixpoint on Windows.** Not in scope for v1 (we don't
  bootstrap Quartz on Windows; we cross-compile from Darwin). But: a guard
  run that touches `cg_emit_runtime_declares` needs the existing host
  fixpoint to stay clean — Windows branches must be no-ops on macOS/Linux
  builds. Verify gen1==gen2 after Phase 1.

## Filed-forward (post-Phase-4-polish)

The Phase 4 polish wave (2026-05-22 PM) closed five of the originally-filed
items (file_size/file_mtime, time_mono_ns drops libwinpthread, crypto_rand_int,
mem_peak_rss, print_backtrace). What's left:

- **IOCP scheduler** — `go fn()` working on Windows. Current state: pthread
  externs trap on first task spawn. A faithful port replaces the
  kqueue/epoll event loop with `CreateIoCompletionPort` +
  `GetQueuedCompletionStatus` + overlapped I/O. Several days of careful
  work; deferred until eli (or another consumer) needs Windows async.
- **HTTP server Windows path** — `std/net/http_server.qz` is kqueue-only.
  Blocked by IOCP scheduler.
- ~~**TUI host on Windows**~~ — ✅ shipped 2026-05-23 as the TUI Windows
  backend; see §"TUI Windows backend (shipped 2026-05-23 / TUI.W)"
  below for the full memo. `std/terminal.qz` Win32-console branches
  ride the VT-input + VT-output console modes so the existing ANSI
  escape parser + emitter "just work"; the `xbuild:terminal` gate
  verifies the seven kernel32 console symbols import cleanly.
- **dbghelp symbolicated backtrace** — `SymInitialize` + `SymFromAddr` with
  the variable-length `SYMBOL_INFO`. The current Phase 4 backtrace prints
  addresses only; symbolication is offline. Worth the link-surface cost
  only when in-binary symbols become the difference between a debuggable
  and undebuggable crash.
- **dudect on Windows** — pure compute, ports cleanly now that mem_peak_rss
  has a real Windows path. Untested in this wave (no Windows host
  available in CI).
- **`-ffunction-sections` + `--gc-sections` at link time** — would drop
  `-lbcrypt` from the link when `qz_crypto_rand_int` is unreferenced.
  Tiny win (bcrypt.dll is universal); deferred.
- **Quartz native bootstrap on Windows** — self-hosting on Windows itself.
  Out of scope for any reasonable horizon.

## Calibration

This memo follows the project memory pattern: estimate in quartz-days,
acknowledge prior calibration runs (NET.2 1-2 weeks → 0.5 quartz-day,
NET.3 1-2 weeks → 1 quartz-day, NET.5a 1.2 quartz-day → 1.1 actual).

Path A estimate: 5 quartz-days for `hyperdrive.exe` running on Windows.

**Actual: ~0.7 quartz-day total** (one session). Phase 1 ~0.3 + Phase 3 ~0.2
+ Phase 4 polish ~0.2. The leverage was real — `zig cc` + mingw-w64 already
solve the C-side cross-link; tigr.c + miniaudio.h already have Windows
backends; and most "POSIX" calls actually resolve through mingw-w64 import
libs (clock_gettime, pthread_*, dup/dup2/close, opendir, stat). The
mechanical inventory in the original memo (§1-6, ~30 symbols) over-counted
by roughly 4× — only seven runtime helpers needed Windows IR branches, and
five of them landed in the Phase 4 polish wave.

## Phase 5 — IOCP scheduler (Windows `go fn()`)

**Goal:** make `go fn()` work on Windows. Today the scheduler is the only
Windows trap-on-startup — any program that spawns a task aborts immediately.
Closing this unlocks the HTTP server, async file I/O, all the std/sync
primitives that exercise the worker pool, and the dudect smoke harness.

The kqueue/epoll path won't transplant — Windows has no readiness-based fd
multiplexing in the POSIX shape. The port lands an alternate event-loop
backend that exposes the same internal API (`__qz_sched_register_io`,
`__qz_sched_register_proc`, `__qz_sched_register_timer`, `__qz_sched_wake`,
the `io_map[fd] = task_ptr` invariant) over Windows primitives.

### Prior art (D2)

| Project | Backend | Notes |
|---------|---------|-------|
| Go runtime | Direct overlapped I/O via IOCP | Skips readiness entirely. Each `WSARecv`/`WSASend` posts a completion when bytes are in the buffer. `src/runtime/netpoll_windows.go`. |
| Rust mio (0.7+) | AFD.SYS poll IOCTL via IOCP | `\Device\Afd` + `IOCTL_AFD_POLL=0x00012024` delivers a readiness completion the user code then services with a normal nonblocking `recv`. mio's `src/sys/windows/{selector,afd}.rs`. |
| libuv | Same as mio (since ~2011) | `\Device\Afd` for sockets; threadpool for everything else (`src/win/poll.c`, `src/win/process.c`). |
| wepoll | epoll API directly atop AFD.SYS | The open-source documentation of `\Device\Afd`. |
| Zig std | Native Win32 threading | `kernel32.CreateThread`, no winpthreads, even with `link_libc`. |

The dominant pattern in 2026 is **AFD.SYS readiness via IOCP** — mio, libuv,
and wepoll all converged here. Go is the outlier (and pays for it by
rewriting every I/O site to use overlapped semantics). The Quartz scheduler
already thinks in `task waiting on readable fd`; mio's pattern preserves
that shape, Go's would require touching every read/write site in stdlib.

### Architectural decisions

**(A) Completion vs readiness — AFD.SYS poll IOCTL via IOCP** ([mio
selector.rs](https://github.com/tokio-rs/mio/blob/master/src/sys/windows/selector.rs)).
Quartz's `io_map[fd] = task` invariant transplants directly: the AFD poll
delivers "fd X is readable" via IOCP completion, the wake side does a
normal nonblocking `recv()` on the socket. Per-socket `SockState` carries
the pinned `IO_STATUS_BLOCK` + `AFD_POLL_INFO` + task pointer for the
lifetime of the pending poll. The `\Device\Afd` interface is undocumented
but has shipped since NT 4 — depended on by Node.js (via libuv), tokio,
Python's selectors, every Rust async runtime in production.

**(B) Cross-thread wakeup — packed completion key** ([Go
`packNetpollKey`](https://github.com/golang/go/blob/master/src/runtime/netpoll_windows.go)).
`PostQueuedCompletionStatus(iocp, 0, MAGIC_WAKE_KEY, NULL)` from any thread
posts a completion. To distinguish wake-source from I/O completion, pack
a 2-bit discriminant `IocpKeyKind { Io=0, Wake=1, Timer=2, Process=3 }`
into the low bits of a `Task*` (8-byte aligned, so 2 bits free). Reserves
key=0 as "invalid" to avoid collision with the default association path.

**(C) Timers — software min-heap + GQCSEx timeout** (libuv pattern, [`src/timer.c`](https://github.com/libuv/libuv/blob/v1.x/src/timer.c)).
Each loop iteration: `next_expiry_ms = timer_heap.peek_or(INFINITE)`, pass
as `GetQueuedCompletionStatusEx` timeout. After return, drain expired
timers. ~15ms resolution out of the box (Windows scheduler quantum); we
don't call `timeBeginPeriod` because of its global power-consumption
side-effect. v2 upgrade path: layer Go's
`NtAssociateWaitCompletionPacket` + `CreateWaitableTimerEx` with
`CREATE_WAITABLE_TIMER_HIGH_RESOLUTION` for sub-ms accuracy on the single
nearest-expiry timer — same heap structure, kernel timer is just an
early-wake mechanism. Defer until a customer asks for it.

**(D) Process exit — `RegisterWaitForSingleObject` + IOCP repost** (libuv pattern,
[`src/win/process.c`](https://github.com/libuv/libuv/blob/v1.x/src/win/process.c)).
`RegisterWaitForSingleObject(&wh, hProcess, callback, ctx, INFINITE,
WT_EXECUTEINWAITTHREAD | WT_EXECUTEONLYONCE)`. The callback runs on a
threadpool thread and posts a completion to our IOCP. Cleaner than Go's
goroutine-per-process pattern and matches the kqueue `EVFILT_PROC` shape
one-for-one.

**(E) Threading — native Win32, not mingw winpthreads.** Every serious
runtime avoids winpthreads under contention:
- Documented hangs at 100% CPU on `std::thread` ([Mozilla bug 1349912](https://bugzilla.mozilla.org/show_bug.cgi?id=1349912))
- Heavyweight cond-var emulation per the mingw-w64 mailing list
- Pre-2024 versions broken on >64-CPU hosts (Windows processor groups)
- TLS-cleanup races when mixing with raw Win32 threads
- `pthread_cancel` semantics undefined

For a scheduler running thousands of goroutines through the
sched_park/sched_wake hot path, the contention overhead is exactly where
winpthreads hurts. The native equivalents are 1-pointer structures with
direct kernel-mode entry: `SRWLOCK` for mutexes (matches `pthread_mutex_t`
behaviorally — non-reentrant, fair on Windows 8+), `CONDITION_VARIABLE`
for condvars (`SleepConditionVariableSRW` + `WakeConditionVariable` +
`WakeAllConditionVariable`), `CreateThread` for `pthread_create` (returns
HANDLE not `int`; signature matches but with two extra args).

**Implementation shape:** rather than branch every call site, emit a
single set of pthread→Win32 shim definitions when target is Windows.
Existing `call i32 @pthread_mutex_lock(ptr %m)` sites resolve to a Quartz-
defined `pthread_mutex_lock` that wraps `AcquireSRWLockExclusive`. No
winpthreads linked. The pthread_t / pthread_mutex_t / pthread_cond_t
storage already allocates 64 bytes per object (`__qz_alloc(64)`); we use
the first 8 bytes for the actual Windows primitive. Wasted space, but
binary-compatible and avoids changing every allocation site.

**(F) MVP scope — what ships in each sub-phase.**

| Sub-phase | Cost | Acceptance |
|-----------|------|------------|
| **5a** threading externs + sched init (skeleton IOCP) | ✅ 0.5 qd | `4c091778` — `examples/windows/go_smoke.qz` — spawn 1 task, await, print "ok" — cross-compiles, links, passes mechanical inspection. No I/O. |
| **5b** IOCP event loop core | ✅ 0.3 qd | `c3f695d8` — sched_park + sched_wake from another thread succeed under Windows linkage. Replaced pipe-wakeup with PostQueuedCompletionStatus. |
| **5d** Windows process exit | ✅ 0.2 qd | `examples/windows/process_smoke.qz` — proc_suspend on a bogus HANDLE exercises the rw_fail inline-reenqueue fast-path; cross-compile clean with RegisterWaitForSingleObject KERNEL32 import; native proc_suspend_spec 3/3 green confirms POSIX path survived the register_proc refactor. |
| **5c** Windows timers (software heap) | ✅ 0.3 qd | `examples/windows/sleep_smoke.qz` — sched_sleep × 3 from a `go fn()` worker, native + Windows cross-compile clean. ~15 ms accuracy via scheduler quantum. |
| **5d** process-exit | ✅ 0.2 qd | `examples/windows/process_smoke.qz` — `proc_suspend(sentinel)` from a `go fn()` worker exercises the rw_fail inline-reenqueue fast-path. RegisterWaitForSingleObject + IOCP repost via `__qz_proc_exit_callback` threadpool thunk. `proc_suspend_spec` 3/3 native green confirms POSIX path survives the register_proc refactor. |
| **5e** sockets via AFD.SYS readiness | ✅ shipped | `examples/windows/io_smoke.qz` — cross-compile clean with `NtCreateFile`/`NtDeviceIoControlFile`/`NtClose` (ntdll), `SetFileCompletionNotificationModes` (kernel32), `WSAIoctl` (ws2_32). 5b/5c/5d smokes regression-clean. |
| **5f** acceptance + handoff polish | ✅ shipped | `quake xbuild:phase5` task added (cross-compiles go_smoke and verifies the 11-import Phase-5 canonical set in a single command); HANDOFF.md updated with 5c/5d/5e probes; design memo closeout (this entry). |

**Total estimate: 3.4–5.3 quartz-days.** Wider error bars than Phase 1-4
because 5e (AFD.SYS) hits novel territory — mio took multiple releases to
get the lifetime + cancellation rules right.

### What 5a unlocks specifically

Phase 5a is the foundation: every threading primitive resolves natively
on Windows, the scheduler init runs without trapping, the worker thread
pool spawns. With 5a alone, a pure-compute Quartz program that uses `go
fn() + await` compiles, links, and (on a Windows host) runs correctly.
Pure-compute means no I/O, no sleep, no scope deadlines — those are 5b/5c.

Three risks specific to 5a:

1. **`pthread_t` vs `HANDLE` ABI mismatch.** Quartz currently stores
   thread IDs as `i64` and calls `pthread_join(i64, ptr)`. On Windows
   `WaitForSingleObject` takes `HANDLE` (which is a `void*`, same width
   as `i64` on x86_64 but conceptually pointer-shaped). The shim packs/
   unpacks via `inttoptr` and works fine. Aarch64 Windows: same.

2. **`pthread_mutex_destroy` vs SRWLock no-destroy.** `SRWLOCK` doesn't
   need destruction — it's a single pointer, freed with its containing
   allocation. The destroy shim is a no-op `ret i32 0`. Same for
   `pthread_cond_destroy` on `CONDITION_VARIABLE`.

3. **`pthread_cond_timedwait` semantics.** POSIX takes an absolute deadline
   via `timespec`; Win32 `SleepConditionVariableSRW` takes a relative
   `DWORD` ms. The shim converts via `time_mono_ns()` − arg → ms,
   clamps to `INFINITE` if negative or > 49 days. Spurious wakeups are
   already handled correctly by the caller (existing `while`-loop guards).

### Skipped in 5a (deferred to 5b–5f)

- I/O poller thread spawn — the `pthread_create(@__qz_sched_io_poller, ...)`
  call in init is skipped under Windows. The poller is fed by IOCP
  completions in 5b, not by kevent/epoll_wait. Until 5b lands, the
  Windows scheduler has no I/O poller at all — pure compute only.
- `pipe()` + `fcntl()` shutdown-signal pipe — replaced by
  `PostQueuedCompletionStatus` cross-thread wake in 5b. Skipped in 5a.
- `kqueue() / epoll_create1()` — replaced by `CreateIoCompletionPort` in
  5b. Skipped in 5a (slot is zeroed; nothing reads it without an I/O
  poller running).
- `signal(SIGUSR1)` — skipped on Windows; Windows has no POSIX signals.
  Phase-out plan: task-dump triggered via `SetConsoleCtrlHandler` on
  Ctrl+Break, or a separate IPC mechanism. Not on critical path.
- `pthread_setname_np` — skipped in 5a; revisit in 5f if debugger
  visibility matters. `SetThreadDescription` is the Win10+ equivalent.

### Phase 5f — what landed (2026-05-22)

Phase 5f closes out Phase 5 with the acceptance-polish layer and the
handoff documentation. Two changes:

1. **`quake xbuild:phase5` task** (Quakefile.qz, near `xbuild:windows`).
   Cross-compiles `examples/windows/go_smoke.qz` via the standard
   pipeline, then inspects the resulting `.exe` for the canonical
   11-import Phase-5 set:
   - 5a (3): `CreateThread`, `WaitForSingleObject` (5a also pulls in
     SRWLock + CONDITION_VARIABLE but those don't appear as named
     imports — they resolve to `kernel32.dll!Acquire/Release/Initialize…`
     which lld-link bundles)
   - 5b (3): `CreateIoCompletionPort`, `GetQueuedCompletionStatusEx`,
     `PostQueuedCompletionStatus`
   - 5c (0): software timer heap is pure-Quartz — no new imports
   - 5d (1): `RegisterWaitForSingleObject`
   - 5e (5): `NtCreateFile`, `NtDeviceIoControlFile`, `NtClose`,
     `SetFileCompletionNotificationModes`, `WSAIoctl`

   If any expected import is absent, the task fails with a list of the
   missing symbols pointing at the sub-phase that regressed. A single
   `./self-hosted/bin/quake xbuild:phase5` is now the acceptance gate
   for the entire scheduler substrate.

2. **HANDOFF.md** — every sub-phase added a probe to the table; 5f
   adds the `sleep_smoke.qz`/`process_smoke.qz`/`io_smoke.qz` rows,
   the link-flags note (`-lbcrypt -lntdll -lws2_32`), and the
   per-phase calibration entries.

**What 5f doesn't do:**

- **`SetThreadDescription`** (Win10+, kernel32). The pthread_setname_np
  shim is still a no-op. SetThreadDescription takes a UTF-16 string;
  pthread_setname_np passes UTF-8. Wiring up via MultiByteToWideChar
  is a debugger-niceness win — workers appear as "qz-sched-N" in
  Visual Studio / WinDbg call stacks. Filed-forward 0.2 qd.
- **`SetConsoleCtrlHandler` for Ctrl+Break task-dump.** POSIX has
  SIGUSR1 → dump_requested = 1. Windows has no POSIX signals; the
  equivalent is `SetConsoleCtrlHandler(Handler, TRUE)` which fires
  on Ctrl+Break. The handler would set `@__qz_dump_requested = 1`
  and the worker loop drains it on the next tick. Filed-forward 0.2 qd.

Both are quality-of-life polish, not blockers — debugger visibility
and operator ergonomics improvements that nobody hits until they're
actively debugging a Windows runtime issue.

**Calibration:** trivially short — adding a quake task + flipping
documentation marks. No `self-hosted/*.qz` source changes (no fixpoint
perturbation; guard accepts without rebuild).

### Phase 5e — what landed (2026-05-22)

Phase 5e lit up `__qz_sched_register_io` on Windows via the AFD.SYS poll IOCTL
through IOCP, mirroring mio's [`src/sys/windows/{afd,selector}.rs`](https://github.com/tokio-rs/mio/tree/master/src/sys/windows)
and wepoll's [`wepoll.c`](https://github.com/piscisaureus/wepoll). The Windows
socket-readiness substrate is now in place; any Quartz program that calls
`tcp_connect`/`tcp_accept`/`socket_send`/`socket_recv` and parks the task via
`sched_park(fd)` lights up the AFD poll IOCTL on Windows the same way it lights
up `kevent EVFILT_READ` on macOS or `epoll_ctl EPOLLIN` on Linux. The MAGIC
KERNEL32+NTDLL imports (`NtCreateFile`, `NtDeviceIoControlFile`,
`SetFileCompletionNotificationModes`, `WSAIoctl`) are populated; the IOCP
poller's `ev_io:` branch dispatches the new AFD completion shape.

Five coordinated changes in `self-hosted/backend/codegen_runtime.qz`:

1. **NTDLL + ws2_32 externs + AFD device open in `__qz_sched_init`.**
   `cg_emit_windows_thread_shims` now declares `NtCreateFile` (11 args),
   `NtDeviceIoControlFile` (10 args), `NtCancelIoFileEx` (3 args),
   `SetFileCompletionNotificationModes` (kernel32, perf flag — skips event
   signal when only IOCP completion is needed), and `WSAIoctl` (ws2_32, for
   `SIO_BASE_HANDLE = 0x48000022` LSP unwrap). On Windows targets, sched_init
   now also opens `\Device\Afd\Quartz` via `NtCreateFile` with
   `DesiredAccess=SYNCHRONIZE (0x00100000)`, `ShareAccess=FILE_SHARE_READ |
   FILE_SHARE_WRITE (0x3)`, `CreateDisposition=FILE_OPEN (0x1)`, then
   associates the resulting AFD HANDLE with the IOCP via
   `CreateIoCompletionPort(afd, iocp, 0, 0)` (key=0 — AFD completions arrive
   with key=0, AND `lpOverlapped` = the per-poll SockState block pointer, so
   key-based dispatch isn't used for AFD), then calls
   `SetFileCompletionNotificationModes(afd, FILE_SKIP_SET_EVENT_ON_HANDLE = 2)`
   per [wepoll's documented optimization](https://github.com/piscisaureus/wepoll/blob/master/wepoll.c).
   The AFD HANDLE is stored in `@__qz_sched` slot 33 (formerly free).
   The 36-bytes-of-UTF-16-LE for `\Device\Afd\Quartz` is emitted as a private
   constant; a private constant `OBJECT_ATTRIBUTES`-shaped struct (48 bytes)
   pinned to the UNICODE_STRING gets passed as the second NtCreateFile arg.

2. **`__qz_sched_register_io` Windows branch** — replaces the
   `epoll_ctl(epfd, ..., -1)` stub completely. Allocates a 72-byte SockState
   block: `IOSB` at offset 0 (NTSTATUS Status i32 at 0, ULONG_PTR Information
   i64 at 8); `AFD_POLL_INFO` at offset 16 (LARGE_INTEGER timeout i64 at 16,
   NumberOfHandles u32 at 24, Exclusive u32 at 28, plus inline
   `AFD_POLL_HANDLE_INFO` at offset 32: Handle ptr at 32, Events u32 at 40,
   Status i32 at 44); task pointer at offset 48; user_events at offset 56;
   reserved at offset 60. Unwraps the user-supplied socket via
   `WSAIoctl(SIO_BASE_HANDLE)` to defeat LSPs (Komodia-family fallback to
   `SIO_BSP_HANDLE_POLL`/`SIO_BSP_HANDLE_SELECT`/`SIO_BSP_HANDLE` is
   filed-forward; for a development runtime, treat WSAIoctl failure as fatal).
   Fills AFD_POLL_INFO: timeout=INT64_MAX (let the 5c timer heap own deadlines),
   NumberOfHandles=1, Exclusive=0, handle=base_socket, events = `(POLL_RECEIVE
   | POLL_ACCEPT) | (POLL_LOCAL_CLOSE | POLL_ABORT | POLL_CONNECT_FAIL)` for
   register_io's read-direction default (matches the kqueue/epoll EVFILT_READ /
   EPOLLIN one-shot semantics). The 5b/5c+ `io_map[fd]` invariant still holds
   for non-Windows targets; on Windows the `io_map` write at the top is
   skipped — the SockState pointer IS the per-task handle, returned to ev_io
   via OVERLAPPED_ENTRY.lpOverlapped (mio's `Arc::into_raw`+`from_raw`
   pattern). `iosb.Status` is written to `STATUS_PENDING (0x103)` before the
   call. `NtDeviceIoControlFile(afd, NULL, NULL, sock_state_block, &iosb,
   IOCTL_AFD_POLL=0x00012024, &poll_info, 32, &poll_info, 32)` submits the
   poll; expected return is `STATUS_PENDING (0x103)`. `STATUS_SUCCESS (0)`
   means the kernel completed inline (data already pending) — for v1 we
   still let the IOCP completion arrive and process there, matching mio's
   model. Negative returns surface as immediate-failure inline reenqueue,
   matching the POSIX `kev_imm` fast-path one-for-one.

3. **`__qz_sched_register_io_ex` Windows branch** — same body shape as
   register_io's branch but with `events_mask=4` (POLLOUT) mapped to
   `AFD_POLL_SEND` instead of receive/accept, and a timeout_ms argument
   routed through the existing 5c `__qz_timer_heap` (push deadline_ns =
   now+ms·1e6 with task; the heap's drain on next poller iteration handles
   the wake even if the fd never becomes ready). Two side-table writes —
   `task_timer_set(task, task)` for the timer-claim race, no `io_map` write
   since the SockState is the IOCP-side identity. This mirrors the
   POSIX timerfd/EVFILT_TIMER mechanism: timer fires → task wakes early →
   AFD poll completion arrives later → ev_io's "task not parked" no-op
   branch frees the SockState.

4. **IOCP poller `ev_io:` dispatch on Windows** — replaces the 5b stub
   (`%ev.io.task = and i64 %ev.key, -4`) with the AFD completion decision
   tree from [mio selector.rs:199-239](https://github.com/tokio-rs/mio/blob/master/src/sys/windows/selector.rs):
   load `lpOverlapped` from `OVERLAPPED_ENTRY` offset 8 — this IS the
   SockState block pointer. Read `iosb.Status` (offset 0, i32 NTSTATUS):
   - `STATUS_CANCELLED (0xC0000120)` → drop, free block, no reenqueue
     (sched_wake cancellation in the IOCP path is filed-forward; today the
     CAS protocol races cleanly and the orphaned completion just frees its
     own block).
   - Negative other → surface as POLL_CONNECT_FAIL (matches mio's "generic
     kernel error" treatment), reenqueue task, free block.
   - Otherwise → read `poll_info.NumberOfHandles` (offset 16+8=24); if <1,
     spurious wake, free block, no reenqueue. Otherwise read
     `poll_info.handles[0].events` (offset 16+16+8=40), reenqueue task,
     free block. (Edge-trigger user_evts masking from mio is filed-forward —
     the existing Quartz contract is one-shot anyway, so the next register_io
     call gets a fresh mask.)
5. **No new `@__qz_sched` slots beyond slot 33.** Cleanup branched: Windows
   runs `NtClose(afd)` before `CloseHandle(iocp)` in __qz_sched_shutdown
   (NtClose on the AFD HANDLE is the documented release; closing the IOCP
   after frees the IOCP-side hashtable entry. CloseHandle on AFD also works
   per mio, but NtClose pairs symbolically with NtCreateFile).

Acceptance: `examples/windows/io_smoke.qz` — a minimal cross-compile +
mechanical link probe. The smoke does NOT do a TCP echo (would require
`CreateProcessA`-style binding to ws2_32's accept/connect from Quartz,
filed-forward to a stdlib epic) — it instead exercises the failure-path
inline branch: `register_io(invalid_fd=-1, task)` returns immediately via
the `STATUS_INVALID_HANDLE` (`0xC0000008`) inline branch, and the smoke
verifies `await` returns within 1 second. Cross-compile clean: ~232 KB
PE32+ x86-64; KERNEL32 imports include `CreateThread`, `WaitForSingleObject`,
`CreateIoCompletionPort`, `GetQueuedCompletionStatusEx`,
`PostQueuedCompletionStatus`, `RegisterWaitForSingleObject`, plus the new
`SetFileCompletionNotificationModes`; NTDLL imports include `NtCreateFile`,
`NtDeviceIoControlFile`, `NtCancelIoFileEx`, `NtClose`; ws2_32 imports
include `WSAIoctl`. Zero libwinpthread / kqueue / epoll / timerfd / pidfd
imports. Native `tcp_spec` and the existing POSIX socket suite green
confirms the POSIX path survives the AFD-flavored Windows branch.

**What 5e doesn't do:**

- End-to-end TCP echo on a Windows host — needs `WSAStartup`, full ws2_32
  socket/bind/listen/accept/connect FFI in stdlib (~0.5 quartz-day,
  filed-forward to a stdlib epic). The current smoke is a thin-slice path
  acceptance, not a runtime acceptance — same Darwin-host constraint as
  5a/5b/5c/5d.
- Per-socket sharded AFD groups (POLL_GROUP__MAX_GROUP_SIZE=32 in mio +
  wepoll). v1 uses one global AFD handle. For >32 sockets per IOCP this
  can become a cancellation-latency bottleneck under load; filed forward
  as 0.3 qd.
- `NtCancelIoFileEx`-based cancellation. The IO is one-shot anyway; if the
  task is sched_wake'd while a poll is pending, the SockState block stays
  alive until the kernel naturally posts a completion (LOCAL_CLOSE,
  CONNECT_FAIL, or natural readiness). The ev_io branch then sees a
  not-parked task and frees the block. Bounded leak; filed-forward 0.3 qd.
- Komodia-family LSP fallback (`SIO_BSP_HANDLE`/`SIO_BSP_HANDLE_SELECT`/
  `SIO_BSP_HANDLE_POLL`). For developer hosts with broken antivirus.
  Filed-forward 0.2 qd.
- Edge-trigger `user_evts` mask-and-resubmit. Quartz's one-shot contract
  doesn't need it; if a port to a stdlib that holds a persistent
  registration ever lands (HTTP/2 keep-alive socket pool, e.g.), revisit.
- `STATUS_SUCCESS` (inline completion) optimization. mio processes inline
  to avoid the IOCP round-trip; v1 lets every completion route through
  the IOCP, simpler invariant. Filed forward as a perf-only opt.

**Calibration:** estimated under the original 1.5-2.5 qd projection.
The reason for the under-shoot has two parts: (1) the D2 research nailed
every struct offset, NTSTATUS code, and IOCTL value before any IR was
emitted, so the implementation was transcription, not discovery; (2) the
5b/5c/5d substrate had already built every piece this phase needed —
the IOCP HANDLE was sitting in slot 11 with `ev_io:` dispatch wired (5b),
the timer heap was ready to absorb register_io_ex timeouts (5c), and
the threadpool-completion callback pattern from 5d prefigured the
"post-from-anywhere, dispatch-via-OVERLAPPED" shape. The mio/wepoll AFD
pattern is ~200 lines of straight-line LLVM: NtCreateFile open,
NtDeviceIoControlFile submit, decision-tree dispatch. The one bump:
initial sched_init/shutdown emission added conditional branches that
broke a downstream phi predecessor (`%si = phi i64 [ 0, %nw_done ]`
caught by llc's IR verifier), fixed by inlining as a linear chain —
NtCreateFile failure leaves slot 33 zero and subsequent
CreateIoCompletionPort/SetFileCompletionNotificationModes on a null
HANDLE silently fail, which is the right behavior for v1.

### Filed forward from 5e

- **`NtCancelIoFileEx` cancel branch in `sched_wake`** (~0.3 qd) — **SHIPPED
  2026-05-23** as Phase 5e+. Closed the bounded SockState leak from
  cancel-on-wake scenarios (scope cancellation, deadline cancellation,
  any sched_wake on a task currently parked on an AFD poll). New
  `@__qz_task_iosocks` side-table mirrors `@__qz_task_timers` (256-pair
  capacity, mutex-protected, init at sched_init alongside the timer
  table). Two new helpers `__qz_task_iosock_set` / `__qz_task_iosock_take`
  with the same upsert / linear-scan-and-remove shape as the timer pair.
  `register_io` and `register_io_ex` now `__qz_task_iosock_set` after a
  successful `NtDeviceIoControlFile(IOCTL_AFD_POLL)` submit; the IOCP
  poller's `ev_io_wake` now `__qz_task_iosock_take`s and re-enqueues
  ONLY if it won the race (`sched_wake` losing the race causes a SKIP,
  preventing double-enqueue); and `sched_wake` itself gained two new
  Windows-only branches — `wk_io_check` / `wk_io_cancel` (no-timer path
  takes iosock and calls `NtCancelIoFileEx`) AND `wk_tc_io_cancel` (the
  timer-cancel path ALSO takes iosock + cancels, for the
  `register_io_ex` case where both timer + iosock are set on the same
  task — fixes a pre-existing double-enqueue race). Quake guard PASS
  at 2580 functions (+6 from 2574 — 2 new helpers + the extra IR for
  the new basic blocks). `NtCancelIoFileEx` now appears in every
  Windows go-fn binary's import table (verified via `xbuild:phase5` —
  the canonical Phase-5 import set is now 12 not 11; `xbuild:tcp_serve`
  is 23 not 22). The 5e-original FAQ entry below is preserved for
  context, but the leak is closed.
- **End-to-end TCP smoke** (~0.5 qd) — **ws2_32 user FFI SUBSTRATE SHIPPED
  2026-05-22 PM** as a follow-on commit (see §"ws2_32 user FFI" below).
  `std/ffi/socket.qz` Windows block landed with the full surface
  (WSAStartup, socket, bind, listen, accept, connect, send, recv, shutdown,
  setsockopt, getsockopt, getsockname, closesocket, ioctlsocket, WSAPoll,
  WSAGetLastError) plus four cross-platform helpers — `socket_init_once`,
  `socket_close`, `socket_set_nonblock`, `socket_last_error` — that branch
  on `@cfg` internally. `examples/windows/socket_smoke.qz` exercises
  `WSAStartup → socket → bind → getsockname → listen → closesocket` end-to-
  end; native macOS path green; `socket_smoke.exe` (~219 KB) imports
  WSAStartup + socket + bind + listen + getsockname + closesocket by name
  from WS2_32.dll. Gate: `./self-hosted/bin/quake xbuild:ws2`. What's still
  filed forward: actually running this on a real Windows host (just
  observation, no Quartz-side work); a paired client + server program that
  exercises accept/connect/send/recv (sized ~0.3 qd; only takes off the
  shelf the existing FFI).
- **`NtCancelIoFileEx` cancel branch in sched_wake** (~0.3 qd) — symmetrically
  mirror the 5c timer-cancel branch. Required when a workload has many
  cancel-on-failure or scope-deadline cancellations of pending I/O; today
  the bounded SockState leak is acceptable.
- **AFD handle sharding** (~0.3 qd) — mio/wepoll converged on 32 sockets per
  AFD handle. For >32 concurrent socket polls per IOCP, cancellation
  latency degrades; partition the registration set across a `Vec<HANDLE>`
  and rotate.
- **Edge-trigger `user_evts` mask** (~0.2 qd) — mio simulates EPOLLET by
  clearing fired bits from a per-socket `user_evts` mask; Quartz's one-shot
  contract makes this unnecessary today, but persistent registrations
  (HTTP/2 keep-alive, websocket) would need it.
- **`STATUS_SUCCESS` inline-completion fast-path** (~0.2 qd) — mio detects
  this and avoids the IOCP round-trip; for already-readable sockets at
  registration time, v1 still pays one IOCP wait. Pure perf optimization.
- **Komodia-family LSP fallback** (~0.2 qd) — `SIO_BSP_HANDLE_POLL` →
  `SIO_BSP_HANDLE_SELECT` → `SIO_BSP_HANDLE` chain. For dev hosts with
  broken antivirus. v1 traps with WSAIoctl failure.

### Phase 5d — what landed (2026-05-22)

Phase 5d lit up `proc_suspend` on Windows via `RegisterWaitForSingleObject`
+ IOCP repost, mirroring libuv's `src/win/process.c` pattern. Four
coordinated edits in `self-hosted/backend/codegen_runtime.qz`:

1. **`RegisterWaitForSingleObject` extern + `__qz_proc_exit_callback`
   thunk** appended to `cg_emit_windows_thread_shims`. The thunk is a
   small WAITORTIMERCALLBACK that runs on a Win32 threadpool thread
   (NOT a Quartz worker, NOT the IOCP poller) when a registered process
   HANDLE becomes signaled. It loads the IOCP HANDLE from `@__qz_sched`
   slot 11, encodes the completion key as `task | 3` (kind=Process),
   and posts via `PostQueuedCompletionStatus` — the IOCP-side dispatch
   in step 4 below then handles the actual re-enqueue. `BOOLEAN
   timer_or_wait_fired` is ignored (always FALSE for INFINITE waits).

2. **Windows branch of `__qz_sched_register_proc`** prepended before the
   macOS/Linux branches. The i64 `pid` argument is reinterpreted as a
   `HANDLE` on Windows — caller (typically a Quartz wrapper around
   `CreateProcessA`) must pass `pi.hProcess` directly, NOT a Windows
   DWORD pid. Rationale: libuv/mio both store the HANDLE for exactly
   this reason — Windows recycles PIDs faster than POSIX and
   OpenProcess-by-pid is racy. The branch allocas a PHANDLE slot for
   the wait-handle out-parameter (discarded; cancellation is filed-
   forward), inttoptr's the HANDLE, and calls
   `RegisterWaitForSingleObject(&wh, hProcess, &__qz_proc_exit_callback,
   task_ptr, INFINITE, WT_EXECUTEONLYONCE=8)`. On FALSE return (bad
   HANDLE or system resource exhaustion) we re-enqueue inline,
   matching the POSIX `kevent_imm` and `pidfd_fail_reenq` fast-paths
   one-for-one. On TRUE return the threadpool will eventually fire
   the callback (immediately if the HANDLE is already signaled).

3. **IOCP poller `ev_proc:` dispatch** — replaced the 5b no-op stub
   (`br label %ev_next`) with the same shape as `ev_io:`: strip kind
   bits via `and key, -4`, then `__qz_sched_reenqueue(task)`. The
   poller now lights up kind=Process completions identically to
   kind=Io; the only thing that differs is which path posted the
   completion (Win32 threadpool here, AFD.SYS in 5e).

4. **No new IOCP externs.** `PostQueuedCompletionStatus` was already
   declared in 5b; the callback thunk reuses it. `__qz_sched_reenqueue`
   is the existing scheduler entry. The only KERNEL32 addition in 5d
   is `RegisterWaitForSingleObject` (verified in import inspection).

Acceptance: `examples/windows/process_smoke.qz` — `go fn()` spawns a
worker that calls `proc_suspend(2147483646)` (an intentionally invalid
HANDLE value, sentinel chosen to be far from any kernel-allocated
handle); main `await`s and asserts elapsed < 1000 ms (the rw_fail
fast-path is inline so the awaited result returns near-immediately).
Cross-compile clean: 229 KB PE32+ x86-64; KERNEL32 imports include
`RegisterWaitForSingleObject` plus the 5b IOCP triad and 5a/5c
primitives. Zero libwinpthread / kqueue / epoll / timerfd / pidfd
imports. Native `proc_suspend_spec` 3/3 green confirms the POSIX
register_proc path survives the Windows branch refactor (the kqueue
EVFILT_PROC + Linux pidfd_open IR is byte-identical pre/post-5d on
non-Windows targets — verified via guard fixpoint at 2574 functions,
unchanged from 5c).

**What 5d doesn't do:** spawn a real child process via CreateProcessA,
monitor its HANDLE through to natural exit, and verify the threadpool
callback → IOCP repost path runs in production. The thin-slice
acceptance here is the rw_fail fast-path — sufficient to verify codegen
+ link shape on the Darwin host. End-to-end "spawn cmd.exe /c exit 0
and wait for natural exit" needs a Windows host to run, same constraint
as 5a/5b/5c. A future `spawn_smoke.qz` adding CreateProcessA FFI is
sized 0.2-0.5 qd, filed-forward — runtime correctness depends on the
Windows host anyway.

**Calibration:** ~0.2 quartz-day (estimate was 0.3 qd). Came in under
because the 5b/5c substrate had already paid the cost of: (a) packed
completion-key dispatch in the IOCP poller (the `ev_proc:` slot was
literally a `br label %ev_next` waiting for content); (b) the
__qz_sched_register_proc function existing as a Windows-vs-POSIX
dispatch point (the macOS/Linux paths are already mutually-branched
via str_contains target gating); (c) PostQueuedCompletionStatus extern
+ packed-key encoding. The callback thunk + RegisterWaitForSingleObject
declare + Windows branch IR is ~50 lines of LLVM, straight-line, no
mutex / no atomic / no state machine.

### Filed forward from 5d

- **Cancellation via `UnregisterWaitEx`.** v1 discards the
  PHANDLE that `RegisterWaitForSingleObject` writes — we never call
  `UnregisterWaitEx` to deregister a pending wait. A sched_wake on a
  proc-suspended task is the same uncovered corner as 5c before its
  cancel branch landed: the task gets re-enqueued by the wake (CAS
  protocol), but the threadpool wait continues until the HANDLE
  naturally signals (then PostQueuedCompletionStatus posts a
  completion key for a task already running). The poller's reenqueue
  on a not-parked task is a no-op (the CAS sees `state != PARKED`),
  so this is benign — just a wasted completion. If a workload ever
  spawns + cancels many process waits, store the PHANDLE in a
  task-keyed side-table and `UnregisterWaitEx(wh, NULL)` on cancel.
  Sized 0.3 qd.
- **`CreateProcessA` FFI in stdlib.** No portable spawn-and-wait
  primitive exists in std today. A Quartz wrapper would: allocate
  STARTUPINFOA (104 bytes), allocate PROCESS_INFORMATION (24 bytes),
  call CreateProcessA, read `pi.hProcess` for proc_suspend, CloseHandle
  on hProcess + hThread when done. Sized 0.5 qd; depends on whether
  the user-facing API is HANDLE-shaped (Windows-only) or pid-shaped
  (portable wrapper with platform-specific resolution). Filed-forward
  to a future stdlib epic; not on 5d critical path.
- **`__qz_proc_exit_callback` runs on a Win32 threadpool thread.**
  The thunk currently does the minimum (load IOCP HANDLE, encode key,
  PostQueuedCompletionStatus). If any future logic needs to run there
  it must restrict itself to thread-safe Win32 calls — Quartz globals
  like `__qz_alloc`, the effect stack, or per-task TLS are NOT safe
  to touch from this context. v1 keeps the thunk minimal precisely
  so this trap stays out of reach.
- **`RegisterWaitForSingleObject` with `WT_EXECUTEONLYONCE` but not
  `WT_EXECUTEINWAITTHREAD`.** Flags = 8. The default execution context
  is a threadpool worker thread, not the wait thread itself. mio + libuv
  both use the default; `WT_EXECUTEINWAITTHREAD` (flag 1) would run
  the callback on the wait thread for slightly lower latency but
  forbids any blocking call. Our callback is non-blocking
  (PostQueuedCompletionStatus is a few-hundred-ns kernel transition),
  so we could switch to `9` (`WT_EXECUTEINWAITTHREAD | WT_EXECUTEONLYONCE`)
  for a marginal win. Deferred until a benchmark shows the cost.

### Phase 5c — what landed (2026-05-22)

Phase 5c lit up `sched_sleep` on Windows via a software min-heap, mirroring
libuv's `src/timer.c` strategy. Five coordinated changes in
`self-hosted/backend/codegen_runtime.qz`:

1. **`@__qz_timer_heap` global** — 5 i64 slots
   (`entries_ptr / count / capacity / mutex_ptr / reserved`). Allocated
   unconditionally for IR uniformity (16 KB array + 64 B mutex; negligible
   vs the 512 KB `io_map` already in place) but only initialised on
   Windows; POSIX targets leave it zeroed.

2. **Four heap helpers** emitted on every target so the IR links uniformly:
   - `__qz_timer_heap_push(deadline_ns, task) -> i64` — sift-up under
     mutex; returns 1 on success, 0 if at capacity (silent drop, matching
     POSIX silent-drop on `tfd >= 65536` and kqueue-ident wraparound).
   - `__qz_timer_heap_cancel(task) -> i64` — linear scan, tombstone the
     entry's task field (deadline stays so heap order is preserved),
     return 1 if claimed / 0 if loser (poller already popped).
   - `__qz_timer_heap_drain_one(now_ns) -> i64` — peek root; if expired,
     pop (swap-with-last + sift-down) and return task; tombstones are
     popped silently and the loop continues. Returns 0 when heap is empty
     or root is in the future. Single lock acquisition per call.
   - `__qz_timer_heap_next_expiry_ms(now_ns) -> i32` — DWORD timeout for
     `GetQueuedCompletionStatusEx`: `-1` (INFINITE) if empty, `0` if root
     is already past, else `ceil((deadline-now)/1e6)` clamped to
     `INT32_MAX-1` (reserves `0xFFFFFFFF` for the INFINITE signal).

3. **`__qz_sched_register_timer` Windows branch** — `now + ms*1e6 =
   deadline_ns`, `__qz_timer_heap_push`, `__qz_task_timer_set(task, task)`
   (sentinel; the heap is task-keyed so the side-table value is
   presence-only), then `__qz_sched_wake_poller()` so the IOCP poller
   re-computes its next-expiry timeout. macOS / Linux branches unchanged.

4. **IOCP poller drain step** — top of each `poll_loop` iteration calls
   `__qz_time_mono_ns` then loops `__qz_timer_heap_drain_one`; each
   non-zero return clears the side-table via `__qz_task_timer_take` and
   `__qz_sched_reenqueue`s the task. After draining,
   `__qz_timer_heap_next_expiry_ms` feeds `GQCSEx`'s wait timeout
   (replacing the hardcoded `i32 1`). The `ev_loop` PHI predecessor moved
   from `%ih_skip` to `%tm_drain_done`.

5. **`__qz_sched_wake` timer-cancel Windows branch** — calls
   `__qz_timer_heap_cancel(task)` in place of the POSIX
   `xchg io_map[ident]→0`. Winner falls through to `wk_reenqueue`; loser
   falls through to `wk_retry` (CAS protocol — identical semantics to the
   POSIX xchg-loser branch). Single-claim is serialised through
   `heap.mutex` rather than the atomic xchg, but the resulting state
   machine is identical from `sched_wake`'s perspective.

**Acceptance gate met:** `examples/windows/sleep_smoke.qz` — `go fn()`
spawns a worker that runs `sched_sleep(10)` three times consecutively;
main `await`s and asserts elapsed ≥ 28 ms. Native Darwin run (POSIX
kqueue/timerfd path) prints the six expected lines and shows
`elapsed ok (>= 28 ms)`. Cross-compiled `tmp/xbuild-windows/sleep_smoke.exe`
is a 227 KB PE32+ x86-64 console binary; KERNEL32 imports include the
5b IOCP triad (`CreateIoCompletionPort`,
`GetQueuedCompletionStatusEx`, `PostQueuedCompletionStatus`) plus 5a
threading (`CreateThread`, `WaitForSingleObject`) and 5b QPC; zero
`kqueue` / `epoll` / `timerfd` / `libwinpthread` imports.

Quake guard PASS at 2574 functions (+4 vs 5b's 2570 — the four new
heap helpers). `go_smoke.qz` native re-run prints the original three
lines (POSIX scheduler path survives the wake/register-timer refactor).

**What 5c doesn't do:** register a single socket / file with IOCP.
`__qz_sched_register_io` still resolves to the `epoll_ctl` `ret i32 -1`
stub on Windows, so anything that calls `sched_park` on a real fd still
fails to register. Phase 5e replaces that with AFD.SYS-flavored IR;
until then the acceptance corpus stays compute-only + timers.

**Calibration:** ~0.3 quartz-day (estimate was 0.3-0.5 qd). Came in at
the low end because the IOCP poller body from 5b was already structured
to receive any deadline through the GQCSEx timeout parameter — the
drain integration was three new basic blocks plus one PHI predecessor
swap, not a structural rewrite. The heap-helpers IR is ~270 lines of
LLVM but is straight-line code; no new externs needed (the existing
`pthread_mutex_*` shims serve the heap mutex, and `__qz_time_mono_ns`
was already QPC-backed in 5a).

### Filed forward from 5c

- **Capacity 1024 hard ceiling.** The heap is sized for a SOUL.5-style
  htop demo (5M tasks scheduled across multiple workers) — the maximum
  concurrent `sched_sleep`d tasks at any instant is ~hundreds in
  practice. If a workload ever pushes 1024 concurrent sleeps, `push`
  silently fails (matching POSIX silent-failure on resource exhaustion);
  caller observes a sleep that never wakes. Grow-on-overflow is a
  one-day filed-forward.
- **15 ms scheduler quantum, not high-resolution timers.** Per (C) in
  this memo, we don't call `timeBeginPeriod` because of its global
  power-consumption side effect. V2 upgrade path is
  `NtAssociateWaitCompletionPacket` + `CreateWaitableTimerEx
  CREATE_WAITABLE_TIMER_HIGH_RESOLUTION` on only the nearest-expiry
  timer (Go runtime's approach). Same heap structure; the kernel-timer
  hop is just an early-wake mechanism.
- **Linear-scan cancel is O(N) in heap size.** N ≤ 1024 by construction
  and concurrent sleeps are typically dozens; cancel-on-wake latency is
  the existing B.7 Phase 4e.8 path. If a workload ever bottlenecks on
  cancel-walker linear scans, the libuv approach is a parallel
  task→heap-index side-table — but maintaining it across sift-up /
  sift-down adds ~3× the per-operation work, and our workload doesn't
  yet warrant it.
- **No `__qz_sched_io_poller` cleanup of the heap on shutdown.** The
  whole `@__qz_sched` allocation block is leaked at shutdown anyway
  (process is exiting); we don't free the entries array, the mutex, or
  the io_map. If we ever add re-init support (one process running
  `__qz_sched_init` twice), all of these allocations would need
  matching `__qz_free` calls — filed forward as a broader scheduler
  re-init epic, not a 5c-specific item.

### Phase 5b — what landed (2026-05-22)

Phase 5b lit up the IOCP event loop core in three coordinated changes:

1. **`CreateIoCompletionPort` in `__qz_sched_init`** — slot 11 (formerly
   the kqueue/epoll fd as i64) is repurposed on Windows to hold the IOCP
   HANDLE as i64 via `ptrtoint`. `CreateIoCompletionPort((HANDLE)-1, NULL,
   0, 1)` creates a fresh port with one concurrent thread (the poller).

2. **Windows-flavored `__qz_sched_io_poller` body** — separate IR from
   the kqueue/epoll body. Allocates `OVERLAPPED_ENTRY[64]` (2048 bytes,
   same per-loop budget), calls `GetQueuedCompletionStatusEx(iocp, buf,
   64, &removed, 1ms, FALSE)`, then dispatches each entry on the low
   2 bits of the completion key:
   - **kind=Io (0)** — payload = `Task*` (8-byte aligned, kind bits clear).
     Strip via `and key, -4` then `__qz_sched_reenqueue`. Phase 5e
     populates via AFD.SYS poll completions; unexercised in 5b.
   - **kind=Wake (1)** — no payload. Drained as a no-op; the next
     `check_shutdown` block observes `@__qz_signal_shutdown`.
   - **kind=Timer (2)** — Phase 5c. No-op stub for 5b.
   - **kind=Process (3)** — Phase 5d. No-op stub for 5b.

   Loop tail observes `@__qz_signal_shutdown`; exits cleanly on set.

3. **`__qz_sched_wake_poller()` unifier** — single Quartz internal
   function that hides the per-backend wakeup mechanism from callers.
   POSIX body writes one byte to slot 15 (`io_pipe_w`). Windows body
   calls `PostQueuedCompletionStatus(iocp, 0, key=1, NULL)`. Both
   call sites in the scheduler (`__qz_sched_register_io_ex` and
   `__qz_sched_shutdown`) now invoke this helper instead of inlining
   the per-platform call. Net effect: shutdown latency on Windows is
   bounded by the 1ms GQCSEx timeout, same as the POSIX 1ms epoll/kevent
   wait — no behavioral regression.

Cleanup branched too: Windows runs `CloseHandle(iocp)` instead of
`close(epfd) + close(pipe_r) + close(pipe_w)`.

Acceptance gate met: `examples/windows/go_smoke.qz` → 228 KB
`go_smoke.exe`, links clean with `CreateIoCompletionPort` /
`GetQueuedCompletionStatusEx` / `PostQueuedCompletionStatus`
imported from KERNEL32; zero libwinpthread / kqueue / epoll
imports. Quake guard PASS at 2570 functions (one new vs 5a's 2569
— `__qz_sched_wake_poller`). The same `go_smoke.qz` run natively
on Darwin prints `worker: started / worker: done / main: joined`,
validating that the POSIX path survives the wake-poller refactor.
End-to-end runtime confirmation on a Windows host: same constraint
as 5a (Darwin can verify imports + magic bytes + structural link
correctness; can't execute the .exe).

What 5b doesn't do: register a single socket / file with IOCP. The
`__qz_sched_register_io` IR still calls `epoll_ctl` on Windows
(stubbed `ret i32 -1` in cg_emit_runtime_decls), so any program
that awaits a real fd silently fails to register. Phase 5e replaces
`__qz_sched_register_io` with AFD.SYS-flavored IR; until then the
acceptance corpus stays pure-compute.

### References

- Go runtime: [`src/runtime/netpoll_windows.go`](https://github.com/golang/go/blob/master/src/runtime/netpoll_windows.go), [`src/runtime/os_windows.go`](https://github.com/golang/go/blob/master/src/runtime/os_windows.go)
- Rust mio: [`src/sys/windows/selector.rs`](https://github.com/tokio-rs/mio/blob/master/src/sys/windows/selector.rs), [`src/sys/windows/afd.rs`](https://github.com/tokio-rs/mio/blob/master/src/sys/windows/afd.rs), [`src/sys/windows/waker.rs`](https://github.com/tokio-rs/mio/blob/master/src/sys/windows/waker.rs)
- libuv: [`src/win/core.c`](https://github.com/libuv/libuv/blob/v1.x/src/win/core.c), [`src/win/poll.c`](https://github.com/libuv/libuv/blob/v1.x/src/win/poll.c), [`src/win/process.c`](https://github.com/libuv/libuv/blob/v1.x/src/win/process.c), [`src/timer.c`](https://github.com/libuv/libuv/blob/v1.x/src/timer.c)
- Zig std: [`lib/std/Thread.zig`](https://github.com/ziglang/zig/blob/master/lib/std/Thread.zig)
- wepoll (open-source AFD.SYS documentation): [piscisaureus/wepoll](https://github.com/piscisaureus/wepoll)
- Len Holgate, ["Adventures with \Device\Afd"](https://lenholgate.com/blog/2023/04/adventures-with-afd.html)

## Next steps if approved

(Historical — all completed 2026-05-22. Phases 1, 3, and 4 polish all
landed same-day; eli's `hyperdrive.exe` artifact ships at
`examples/hyperbouba/build/hyperdrive.exe` (1.3 MB) via `make windows`,
and `quake xbuild:windows` produces a verifiable PE32+ hello.exe one-liner
from any Darwin or Linux host.)

## Reproducing the cross-build (for eli or anyone else)

```bash
# Pre-flight
brew install zig    # or: apt install zig / https://ziglang.org/download/
brew install llvm   # for llc

# One-line acceptance — the smallest probe
./self-hosted/bin/quake xbuild:windows
# → tmp/xbuild-windows/hello.exe (PE32+ x86-64, ~261 KB)

# Phase-4 helper diagnostics probe — calls every Windows-specific
# runtime helper at startup so a broken helper surfaces immediately
# rather than at the first usage point
SRC=examples/windows/diagnostics.qz ./self-hosted/bin/quake xbuild:windows
# → tmp/xbuild-windows/diagnostics.exe (PE32+ x86-64, ~265 KB)

# Hyperbouba windowed runtime
cd examples/hyperbouba && make windows
# → build/hyperdrive.exe (PE32+ x86-64, ~1.3 MB)

# Run on Windows
copy hyperdrive.exe to Windows
./hyperdrive.exe examples/hello.hb      # TIGR window + audio
```

## Tier 0 cache target-fingerprint (bug fix shipped 2026-05-22 PM)

The Tier 0 quick-check (`self-hosted/quartz.qz`, the early-return path
at the top of `compile()`) pre-fix verified source-file hashes only —
the cache key did NOT include the target triple. Running with
`--target=x86_64-pc-windows-gnu` after a native compile silently
returned the cached native IR. Discovered while building the Phase 4
diagnostics probe.

Fix: `module_paths.txt` now prepends a `__config__|<target>|<debug>|<noopt>|<overflow>|<version>`
sentinel as line 0. The reader bails to cache MISS when the sentinel
doesn't match the current invocation, forcing a clean recompile for
each distinct configuration. Same cache directory, different cache
entries. No measurable cost (one extra string compare per invocation).

## Parser fix — `cfg_os_from_target` ordering (shipped 2026-05-22 PM)

Surfaced while landing the ws2_32 user FFI: a new `@cfg(os: "windows")
def WSADATA_SIZE(): Int = 512` declaration was silently being SKIPPED
on a `--target=x86_64-pc-windows-gnu` cross-compile. Symptom: my new
Windows constants were missing from the IR and the user-side calls
emitted `use of undefined value '@WSADATA_SIZE'`.

Root cause: `cfg_os_from_target` in `self-hosted/frontend/parser.qz`
maps a target triple to an `os: ...` string for `@cfg` evaluation. The
pre-fix function checked substrings in this order:

```
"macos" → macos
"darwin" → macos
"apple" → macos
"linux" → linux
"gnu" → linux     # ← catches `*-pc-windows-gnu` too
"musl" → linux
"wasi" → wasi
"wasm" → wasi
"windows" → windows   # ← never reached for mingw-w64 triples
"freebsd" → freebsd
```

mingw-w64 triples (`x86_64-pc-windows-gnu`, `aarch64-pc-windows-gnu`)
contain BOTH `windows` and `gnu` substrings — `gnu` is the ABI flavor,
not the OS. The `gnu` check fired first and returned `linux`, so every
`@cfg(os: "windows")` evaluated to false on a Windows-gnu cross-compile
and every `@cfg(os: "linux")` evaluated to true. The bug was dormant
because the pre-ws2_32-FFI Windows codepaths (Phases 1-5f) all live in
`self-hosted/backend/codegen_runtime.qz` and use a separate
`cg_is_windows(target)` helper that correctly checks the `windows`
substring. User-code `@cfg(os: "windows")` had effectively never been
exercised — std/ffi/socket.qz's new Windows block was the first
consumer.

Fix: reorder the unambiguous-OS checks (windows / linux / wasi / freebsd)
ABOVE the ambiguous-ABI fallbacks (gnu / musl). Five-line shuffle in
`cfg_os_from_target`, plus a comment block explaining why order
matters. Quake guard PASS at 2574 functions, fixpoint byte-identical
(scheduler IR is target-independent at the codegen level so the parser
fix doesn't perturb it).

Lesson filed forward: when adding new target detection helpers,
unambiguous tokens (os names) go first; ambiguous-ABI fallbacks
(gnu / musl) go last. Any future host detection that does substring
matching against target triples should check the same way.

## ws2_32 user FFI (shipped 2026-05-22 PM)

The follow-on to Phase 5e that turns the AFD.SYS scheduler substrate
into something a user can actually write a TCP server against. Closes
the "End-to-end TCP smoke" filed-forward from §"Filed forward from 5e".

**What landed:** A Windows block at the bottom of `std/ffi/socket.qz`
(~200 lines, all `@cfg(os: "windows")`-tagged) covering:

- **Constants** — `AF_INET6=23`, `SOL_SOCKET=0xFFFF`, `SO_REUSEADDR=4`,
  `SO_KEEPALIVE=8`, `SO_RCVTIMEO=0x1006`, `SO_SNDTIMEO=0x1005`,
  `SO_ERROR=0x1007`, `FIONBIO=0x8004667E`, `WSA_MAKEWORD_2_2=514`,
  `WSADATA_SIZE=512` (over-allocated for safety vs the real ~404 bytes),
  Winsock error codes WSAEINTR + WSAEACCES + WSAEFAULT + WSAEINVAL +
  WSAEMFILE + WSAEWOULDBLOCK + WSAEINPROGRESS + WSAEALREADY + WSAENOTSOCK
  + WSAEMSGSIZE + WSAEADDRINUSE + WSAEADDRNOTAVAIL + WSAENETUNREACH +
  WSAECONNABORTED + WSAECONNRESET + WSAEISCONN + WSAENOTCONN +
  WSAESHUTDOWN + WSAETIMEDOUT + WSAECONNREFUSED + WSAEHOSTUNREACH, plus
  POSIX-name aliases `EAGAIN`/`EWOULDBLOCK`/`EINPROGRESS`/`EINTR`
  re-bound to their Winsock equivalents so consumer code that uses the
  POSIX-name constants stays shape-portable.
- **Externs** — `WSAStartup`, `WSACleanup`, `WSAGetLastError`,
  `socket`/`bind`/`listen`/`accept`/`connect`/`send`/`recv`/`shutdown`/
  `setsockopt`/`getsockopt`/`getsockname` with Windows ABI (first arg is
  SOCKET = i64 on x64), `closesocket`, `ioctlsocket`, `WSAPoll`.
- **Cross-platform helpers** (NOT `@cfg`-gated externally; branch
  internally) — `socket_init_once()` (lazy WSAStartup on Windows, no-op
  on POSIX), `socket_close(fd)` (`close` on POSIX, `closesocket` on
  Windows), `socket_set_nonblock(fd)` (`fcntl(F_SETFL, O_NONBLOCK)` on
  POSIX, `ioctlsocket(FIONBIO, &one)` on Windows), `socket_last_error()`
  (`errno` on POSIX, `WSAGetLastError()` on Windows).
- **WSAStartup guard** — A 4-byte int slot held in a module-level `var`,
  lazily malloc'd on first read. Idempotent: the second caller sees
  flag != 0 and returns 0 immediately. Concurrent first-callers race on
  the same flag; worst case is two WSAStartups (idempotent, no harm).
  `WSACleanup` is intentionally not called — process exit reclaims the
  refcount, and most Quartz Windows programs are short-lived enough
  that it doesn't matter.

**Same-file delta:** the POSIX externs that DIFFER on Windows (socket,
bind, listen, accept, connect, sendto, recvfrom, shutdown, setsockopt,
getsockname, getsockopt, poll, fcntl, pipe — all 14 of them) got tagged
`@cfg(not: os: "windows")` to prevent name collision with the Windows
variants on a cross-compile. The shared-on-all-OS externs (close, read,
write, malloc, free, memset, memcpy, strlen, strerror, inet_pton,
inet_ntop, getaddrinfo, freeaddrinfo, gai_strerror) stay un-tagged —
mingw-w64 + ws2_32 provide them with matching signatures.

**Smoke probe:** `examples/windows/socket_smoke.qz` exercises the full
client-of-server-side flow: `socket_init_once → socket(AF_INET,
SOCK_STREAM, 0) → bind(127.0.0.1:0) → getsockname → listen(1) →
socket_close`. Native macOS run (POSIX path) prints all eight expected
status lines and gets a real ephemeral port from the kernel.

**Cross-compile:** `tmp/xbuild-windows/socket_smoke.exe` is a 219 KB
PE32+ x86-64 console binary. `llvm-objdump -p` confirms six expected
ws2_32.dll imports by name: `WSAStartup`, `socket`, `bind`, `listen`,
`getsockname`, `closesocket`. `ioctlsocket`, `WSAPoll`,
`WSAGetLastError`, `send`, `recv`, `accept`, `connect`, `shutdown`,
`setsockopt`, `getsockopt`, `WSACleanup` are declared in the IR but
not imported by `socket_smoke.exe` because the smoke doesn't call
them — linker dead-strip. A consumer that uses them gets them resolved
automatically via the same `@cfg(os: "windows")` declarations.

**Acceptance gate:** `./self-hosted/bin/quake xbuild:ws2` — sibling of
`xbuild:phase5`. Compiles `socket_smoke.qz` for Windows, runs
`llvm-objdump -p` against the resulting `.exe`, and asserts the six
core ws2_32 symbols are present. If anything regresses, the failing
symbol is named in the output.

**Runtime verification on Windows host (2026-05-22 PM):**
`socket_smoke.exe` ran clean on a real Windows machine — the FIRST
end-to-end runtime confirmation across the entire Phase 5 + ws2_32
stack since the Windows target was opened. Every prior Phase-5 sub-
phase had the "needs a Windows host to verify" constraint; this run
clears it for the ws2_32 layer. Observed transcript:

```
C:\tmp>socket_smoke.exe
socket_smoke: starting
socket_smoke: WSAStartup ok
socket_smoke: socket ok (s >= 0)
socket_smoke: bind ok
socket_smoke: getsockname ok (port=9655)
socket_smoke: listen ok
socket_smoke: closesocket ok
socket_smoke: WSACleanup ok
socket_smoke: done
```

What's transitively confirmed by this single run:

- **PE32+ load + link** works end-to-end on a real Windows machine
  (not just llvm-objdump magic-byte + import-table inspection from
  Darwin). The DLL resolution path through bcrypt + ntdll + WS2_32
  + the UCRT api-ms-win-crt-* forwards is operational.
- **Phase 4 runtime helpers** all functional under the Windows ABI:
  `puts` resolves through UCRT and writes to stdout; `mem_alloc` /
  `qz_free` round-trip without leaking; `printf`-backed `#{...}`
  interpolation formats the integer port correctly; `ptr_read_byte`
  / `ptr_write_byte` work on malloc'd memory; the BCryptGenRandom-
  seeded math.rand init (called at any program startup) doesn't trap;
  the QueryPerformanceCounter time substrate (used by anything that
  reads time, also called at startup) doesn't trap.
- **ws2_32 ABI** is correct end-to-end across all six core calls:
  - `socket()` returning SOCKET (i64) doesn't truncate the high bits
    on the return path
  - The 16-byte sockaddr_in layout (u16 family + u16 port BE + u32
    addr BE + 8-byte zero) is byte-compatible with the Windows
    kernel's expectations
  - `getsockname()`'s network-byte-order read produces a sensible
    ephemeral port (9655 in this run — Windows kernel-assigned, in
    the standard 1024-65535 range)
  - `bind()`, `listen()`, `closesocket()` all return 0 / non-negative
    on success
- **Cross-platform helpers** (`socket_init_once`, `socket_close`)
  dispatch correctly to their Windows variants under `@cfg`. The
  lazy WSAStartup guard fires on first call and the i32 flag
  bookkeeping survives module-level mutable state.
- **The parser-fix from earlier this session** — `@cfg(os: "windows")`
  evaluating correctly on a `--target=x86_64-pc-windows-gnu` cross-
  compile — is transitively confirmed: without it the Windows
  externs would have been excluded entirely and the binary would
  have either failed to link or trapped on the first WSAStartup call.

What's STILL un-runtime-verified (substrate is wired; just hasn't
been driven from a probe on a Windows host yet):

- **Phase 5a/b/c/d/e scheduler substrate** — `go fn()`, sched_sleep,
  proc_suspend, sched_park on a socket. `socket_smoke.qz` deliberately
  stays single-process and synchronous; it exercises the user FFI but
  not the IOCP poller. `go_smoke.exe` / `sleep_smoke.exe` /
  `process_smoke.exe` / `io_smoke.exe` are all cross-compiled and
  ready to copy.
- **Hyperdrive windowed runtime** — TIGR framebuffer, miniaudio
  WASAPI, `ReadConsoleInput`-equivalent input. `hyperdrive.exe` is
  cross-compiled and ready.
- **Two-process TCP echo** — bind → listen → accept on one side,
  connect → send → recv on the other. Sized ~0.3-0.5 qd as a
  `tcp_echo_smoke.qz` that drives the full Phase 5e + ws2_32 stack
  together (the AFD.SYS scheduler park/wake on a SOCKET fd via
  `accept()` is the most-load-bearing un-exercised path).

**Calibration:** ~0.4 quartz-day actual vs ~0.5 estimate. Came in
under because the underlying parser fix (cfg_os_from_target) was a
five-line change once diagnosed; everything else was straight stdlib
authoring with no scheduler / IR-emit surface touched. Most of the
elapsed time went into the Quartz-side ABI design (CInt vs Int for
SOCKET, cross-platform helper shape, where to put the WSAStartup
guard) and verifying that `@cfg(not: os: "windows")` on a per-extern
basis works without same-module collisions.

**Filed forward from ws2_32 user FFI:**

- **Cross-platform tcp.qz refactor** (~0.5-1 qd) — `std/net/tcp.qz`
  is currently POSIX-only at the call-site level (`fcntl`, `close`,
  `get_errno`). A pass converting each call to its `socket_*` helper
  equivalent would make `tcp_listen`/`tcp_connect`/`tcp_accept` work
  on Windows out of the box. Mostly mechanical; the API stays the
  same. Sized once we have a Windows host to verify against.
- **`getaddrinfo` Windows Addrinfo struct** (~0.2 qd) — Windows's
  `addrinfo` layout matches the macOS field order (`ai_canonname`
  BEFORE `ai_addr`) but with `ai_addrlen` as `size_t` (i64) rather
  than `u32`. The existing `@cfg(os: "macos") struct Addrinfo` won't
  round-trip on Windows because of the trailing-byte mismatch. Add a
  Windows variant.
- **`pollfd` Windows layout** (~0.1 qd) — `WSAPOLLFD` is 16 bytes
  (SOCKET fd at offset 0, events i16 at 8, revents i16 at 10, pad to
  16) not 8. Add a `WSAPOLLFD_SIZE=16` constant (already done) plus
  Windows variants of `pollfd_new` / `pollfd_revents` that respect
  the new layout. Currently both helpers are tagged out on Windows.
- **Cross-platform `pipe`** — Windows uses `CreatePipe(HANDLE*,
  HANDLE*, SECURITY_ATTRIBUTES*, DWORD)` from kernel32 with a
  different shape. A `socket_pipe()` cross-platform helper is the
  natural slot. Sized 0.2 qd.
- **Two-process TCP smoke** (~0.3 qd) — a `tcp_echo_smoke.qz` that
  spawns a paired client + server (each in a `go fn()` worker), has
  the server `accept` and `send` a known string, has the client
  `connect` + `recv` + assert. Needs the ws2_32 + AFD substrate +
  cross-platform tcp.qz refactor all together. Realistic shape once
  a Windows host is in the loop.

## TUI Windows backend (shipped 2026-05-23 / TUI.W)

The follow-on that closes the third filed-forward from the Phase-4-polish
list. `std/terminal.qz` now compiles and links on Windows via a
Win32-console backend, unblocking the TUI consumer stack (paperclips-tui,
hyperdrive-tui, future) on a Windows target.

**What landed:**

- **`std/ffi/termios.qz` Windows block (~190 lines, all
  `@cfg(os: "windows")`-tagged):**
  - Constants — `STD_INPUT_HANDLE = -10`, `STD_OUTPUT_HANDLE = -11`,
    `STD_ERROR_HANDLE = -12`, input-mode flags
    (`ENABLE_LINE_INPUT = 0x2`, `ENABLE_ECHO_INPUT = 0x4`,
    `ENABLE_PROCESSED_INPUT = 0x1`, `ENABLE_WINDOW_INPUT = 0x8`,
    `ENABLE_MOUSE_INPUT = 0x10`, `ENABLE_QUICK_EDIT_MODE = 0x40`,
    `ENABLE_EXTENDED_FLAGS = 0x80`,
    `ENABLE_VIRTUAL_TERMINAL_INPUT = 0x200`), output-mode flags
    (`ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x4`,
    `DISABLE_NEWLINE_AUTO_RETURN = 0x8`), INPUT_RECORD event-type
    discriminator (`KEY_EVENT_TYPE = 1`, `MOUSE_EVENT_TYPE = 2`,
    `WINDOW_BUFFER_SIZE_EVENT_TYPE = 4`, `MENU_EVENT_TYPE = 8`,
    `FOCUS_EVENT_TYPE = 0x10`), struct sizes
    (`CONSOLE_SCREEN_BUFFER_INFO_SIZE = 24`,
    `INPUT_RECORD_SIZE = 20`), srWindow field offsets within
    CONSOLE_SCREEN_BUFFER_INFO.
  - Externs — `GetStdHandle`, `GetConsoleMode`, `SetConsoleMode`,
    `GetConsoleScreenBufferInfo`, `PeekConsoleInputW`,
    `ReadConsoleInputW`, `Sleep`. All from kernel32.dll (implicitly
    linked by zig cc / mingw-w64; no `-lkernel32` needed).
  - Two helpers — `_winconsole_read_u32_le` (for the lpMode and
    lpNumberOfEventsRead out-params), `_winconsole_read_i16_le`
    (for the srWindow rect fields, signed 16-bit).
- **`std/terminal.qz` `@cfg`-gated branches** — every function that
  touched POSIX termios + ioctl + fcntl now has a parallel
  `@cfg(os: "windows")` impl:
  - `term_enter_raw_mode` — `GetConsoleMode` snapshot of stdin
    + stdout, then `SetConsoleMode` clears
    `ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT
    | ENABLE_QUICK_EDIT_MODE` and sets
    `ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_EXTENDED_FLAGS` on
    stdin; sets
    `ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN`
    on stdout. The VT-input bit translates KEY_EVENTs to the same
    ANSI escape sequences the POSIX path emits, so the existing
    `_term_decode_esc_sequence_nb` parser runs unchanged. Failure
    of either `GetConsoleMode` rolls back the half-applied stdin
    flip so the console isn't left half-modified.
  - `term_exit_raw_mode` — `SetConsoleMode` restores the captured
    DWORDs. No fcntl restore (console handles aren't fcntl-able).
  - `term_get_width` / `term_get_height` —
    `GetConsoleScreenBufferInfo` reads the srWindow rect (visible
    viewport), not dwSize (the larger scrollback buffer). Returns
    `srWindow.Right - srWindow.Left + 1` /
    `srWindow.Bottom - srWindow.Top + 1`. Fallback to 80×24 on any
    failure path (matches the POSIX ioctl fallback shape).
  - `_term_ensure_stdin_nonblocking` — Windows no-op (returns 1).
    Console handles can't be flipped to O_NONBLOCK; the peek-then-read
    path in `_term_read_byte_nb` provides the equivalent semantics.
  - `_term_read_byte_nb` — `PeekConsoleInputW` checks the input queue
    without consuming. If queue is empty → return -1 (EAGAIN
    equivalent). If a KEY_EVENT is at the head, call `read(0)` which
    completes immediately with one VT-translated byte. For any other
    event type (mouse / focus / buffer-resize / menu — events that
    wouldn't translate to VT bytes), `ReadConsoleInputW` drains one
    record so it doesn't sit at the head blocking subsequent peeks,
    then return -1 (the outer loop re-peeks on the next chunk).
  - `_term_wait_input` — POSIX uses `io_suspend_timeout(0, ms, 1)`
    (kqueue / epoll on fd 0). Windows console handles aren't
    AFD-registerable (AFD is socket-only), so the Windows variant uses
    `sched_sleep(ms)` — pure timer-only wait, no early wake on byte
    arrival. Latency to first byte: bounded by the chunk size
    (50ms by default, matching the rest of the B.7 Phase 4e family).
  - `_term_write_handle_neg` — the POSIX retry classifier (sleep on
    EAGAIN / EWOULDBLOCK / EINTR, retry the same chunk) is a no-op
    on Windows: console handle writes either succeed or fatally error;
    no PTY-output-queue analog to drain. Avoids consulting errno
    on Windows (where `_errno` would have to be declared separately).
  - `_term_sleep_us` — POSIX `usleep`; Windows `Sleep((us+999)/1000)`
    (round up to ≥1 ms) to avoid pulling libwinpthread in via
    mingw-w64's `usleep` shim (Phase 4 explicitly dropped that
    dependency for pure-compute Windows binaries).
- **Self-contained extern declarations** —
  the `import std/ffi/socket` was removed from `std/terminal.qz` and
  the symbols it needed (`read`, `write`, `memcpy`, plus POSIX-only
  `fcntl`, `F_GETFL`, `F_SETFL`, `O_NONBLOCK`, `EAGAIN`, `EWOULDBLOCK`,
  `EINTR`, `get_errno`, `__error` / `__errno_location`) are now
  declared locally with appropriate `@cfg` gating. This sidesteps a
  name-resolution conflict on Windows where `std/ffi/socket`'s
  `extern "C" def send(s, buf, len, flags)` (ws2_32) shadowed the
  channel-send intrinsic `send(ch, val)` that
  `std/sync/composition/scope.qz` reaches for inside `scope_send`.
  Filed forward as a compiler-level finding: intrinsic builtins
  should win name resolution over user externs (or the FFI extern
  should map to a non-colliding Quartz-level name).
- **`examples/windows/terminal_smoke.qz`** — exercises the public
  surface (`term_is_tty`, `term_get_width`, `term_get_height`,
  `term_color_depth`, `term_supports_unicode`, `term_enter_raw_mode`
  + `term_exit_raw_mode` when stdin is a TTY). Compile + link only
  in CI; interactive verification under a real Windows Terminal is
  filed-forward for the eventual Windows-host pass.
- **`quake xbuild:terminal` gate** — drives the cross-compile and
  inspects `terminal_smoke.exe`'s imports for the seven kernel32
  console symbols (`GetStdHandle`, `GetConsoleMode`, `SetConsoleMode`,
  `GetConsoleScreenBufferInfo`, `PeekConsoleInputW`,
  `ReadConsoleInputW`, `Sleep`). Joins the
  `xbuild:phase5` / `xbuild:ws2` / `xbuild:tcp_*` Windows-acceptance
  family.

**Native POSIX verification (Darwin):** `terminal_smoke` builds clean
through the standard `quartz → llc → clang` pipeline and runs against
redirected stdin printing the expected status lines (`tty=0`,
`width=80 height=24`, `color_depth=0`, `unicode=1`, `done` — no
raw-mode entry because non-TTY). `spec/qz/term_read_key_cancel_smoke.qz`
runs green with cancel-to-throw latency ~49 ms (well under the
200 ms bound).

**Cross-compile verification (Darwin → Windows):** `xbuild:terminal`
green; the produced `terminal_smoke.exe` (~239 KB) imports
bcrypt.dll + ntdll.dll + WS2_32.dll + KERNEL32.dll + UCRT forwards,
with the seven kernel32 console symbols all resolved.

**Runtime verification on a Windows host:** filed-forward — TTY
behavior (raw-mode entry, VT input translation, srWindow rect)
needs an actual Windows console session to exercise. The link
surface gate ensures the FFI is well-formed; runtime correctness
follows the same "compile-clean → run on host" pattern as the
Phase 5 sub-phases (which all eventually confirmed on the
2026-05-22 PM Windows-host pass).

**Filed forward:**

- **Compiler-level intrinsic-vs-extern priority** — the name-resolution
  collision between the channel-send intrinsic and the ws2_32 `send`
  extern surfaced this milestone. The right fix is for typechecker
  to prefer intrinsic builtins over user externs when names collide,
  or for the FFI declaration to support an `@link_name("send")`-style
  alias so the Quartz-level name can be `ws2_send_raw` without
  breaking the link. Both std/sync/composition/scope.qz and
  std/net/http_server.qz rely on bare `send(ch, val)` and would
  break on Windows if either pulled in std/ffi/socket transitively.
  Sized ~0.3 qd for a parser-side resolution-order tweak. Until then
  the workaround is "don't import std/ffi/socket into modules that
  also touch the channel-send intrinsic."
- **`tcp_listen`/`tcp_echo` Windows cross-compile cache-staleness** —
  during this work an unrelated regression surfaced: tcp_listen_smoke
  and tcp_echo_smoke fail to lower to PE/COFF with `@socket$AF_INET`
  undefined, even on the pre-TUI-Windows-backend HEAD. The mismatch
  is a namespacing-prefix bug between callsite (`socket$AF_INET`) and
  definition (`AF_INET` unqualified) in the IR, triggered by tcp.qz's
  bare `import std/ffi/socket` shape. Existed before this milestone
  and is independent of it; verifying that took a `git stash` round-
  trip. Sized ~0.3 qd to track down. The other gates (xbuild:phase5,
  xbuild:ws2, xbuild:tcp_serve, xbuild:tcp_timeout, xbuild:terminal)
  remain green.
- **Cancellable read on Windows v2** — `term_read_key_cancellable` on
  Windows is correct but latency-bounded by `sched_sleep(chunk_ms)`
  (50 ms default) rather than the ~ms-grain epoll/kqueue wake that
  POSIX gets. Closing this gap requires either (a) a dedicated
  stdin-reader goroutine that does blocking `_read` and forwards
  bytes via a channel, or (b) `WaitForSingleObjectEx` integration
  with the scheduler's I/O substrate. Approach (a) is the libuv /
  crossterm pattern; sized ~0.5 qd.
- **Interactive smoke** — `examples/windows/terminal_smoke.qz` is
  non-interactive by design (must finish under redirected stdin so
  CI can run it). A paired `terminal_smoke_interactive.exe` that
  reads a keystroke and dumps the parsed code would exercise the
  VT-input translation end-to-end. Sized ~0.1 qd; deferred until
  the Windows-host pass.
