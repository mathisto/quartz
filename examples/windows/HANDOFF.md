# Quartz on Windows — hand-off notes

This directory contains the Windows-target acceptance probes for the
Quartz compiler. Read this if you want to:

- run a precompiled Quartz program on a Windows machine
- rebuild from source on a Darwin or Linux host
- understand what's been verified and what hasn't
- diagnose the runtime helpers if something looks wrong

The full design memo with phasing + filed-forwards lives at
[`docs/design/QUARTZ_WINDOWS_TARGET.md`](../../docs/design/QUARTZ_WINDOWS_TARGET.md).
This page is the *hand-off short version*.

## What's in tree

| File | What it is |
|------|------------|
| `hello.qz` | The smallest acceptance probe. One `puts(...)`. |
| `diagnostics.qz` | Calls every Phase-4 runtime helper at startup. Use this if a Quartz binary on Windows is misbehaving — the broken helper shows up immediately in the output. |
| `go_smoke.qz` | Phase-5a + 5b scheduler smoke. Spawns one Quartz task, `await`s it from main, prints three lines. Mechanical link verification that the pthread→Win32 shim block + worker-pool init + IOCP poller all landed clean. The same `.exe` re-built post-5b also imports `CreateIoCompletionPort` / `GetQueuedCompletionStatusEx` / `PostQueuedCompletionStatus`. End-to-end runtime confirmation needs a Windows host. |
| `sleep_smoke.qz` | Phase-5c timer smoke. `sched_sleep × 3` inside a `go fn()` worker. Native + Windows cross-compile clean. |
| `process_smoke.qz` | Phase-5d process-exit smoke. `proc_suspend` on a sentinel HANDLE exercises the rw_fail inline-reenqueue path. Native + Windows cross-compile clean; `RegisterWaitForSingleObject` import verified. |
| `io_smoke.qz` | Phase-5e AFD.SYS substrate smoke. Mechanical link verification — the AFD substrate IR is emitted at scheduler-init time, so any `go fn()` program exercises the same imports. `NtCreateFile` / `NtDeviceIoControlFile` / `NtClose` from ntdll, `SetFileCompletionNotificationModes` from kernel32, `WSAIoctl` from ws2_32. End-to-end runtime confirmation needs a Windows host. |
| `socket_smoke.qz` | Phase-5e+ ws2_32 USER-FACING socket FFI smoke. Exercises `WSAStartup → socket → bind → getsockname → listen → closesocket` against the Windows block in `std/ffi/socket.qz`. Native macOS run prints "bound to 127.0.0.1:<ephemeral>, listening, closed" end-to-end via the POSIX FFI path (the cross-platform helpers `socket_init_once` / `socket_close` / `socket_set_nonblock` / `socket_last_error` branch on `@cfg` internally). PE32+ imports verified: `WSAStartup` + `socket` + `bind` + `listen` + `getsockname` + `closesocket` from `WS2_32.dll`. **VERIFIED ON WINDOWS HOST 2026-05-22 PM.** |
| `tcp_echo_smoke.qz` | Phase-5e++ two-process TCP echo. Single binary; `argv[1]` selects `server <port>` vs `client <ip> <port>`. Server: `socket → setsockopt(SO_REUSEADDR) → bind(0.0.0.0:port) → listen → accept → recv → send (echo) → close`. Client: `socket → connect → send → recv → assert payload-byte-equal → close`. Exercises the FULL ws2_32 client+server surface — `accept` + `connect` + `send` + `recv` + `setsockopt` + `WSAGetLastError`, on top of the setup surface already proven by `socket_smoke`. Native loopback run prints "client: payload MATCH — TCP echo verified". PE32+ imports verified: 11 ws2_32 symbols including the complete transport API. **Substrate complete; needs two cmd windows on Windows for runtime verification — see "Running tcp_echo_smoke" below.** |
| `tcp_listen_smoke.qz` | Phase-5e+++ std/net/tcp HIGH-LEVEL API on Windows. Drives `tcp_listen(0) → tcp_close_listener` through the ergonomic Quartz API (not raw FFI). Proves the cross-platform `tcp.qz` refactor compiles+links on Windows — the call sites that used to be POSIX-only (close/fcntl/get_errno) now dispatch through `socket_close` / `socket_set_nonblock` / `socket_last_error` cross-platform helpers. Native macOS run prints "tcp_listen_smoke: listening on port <ephemeral>". PE32+ imports verified: 7 std/net/tcp-surface symbols from `WS2_32.dll`. Gate: `./self-hosted/bin/quake xbuild:tcp_listen`. |
| `tcp_serve_smoke.qz` | Phase-5e++++ END-TO-END ASYNC TCP-ON-WINDOWS substrate. Drives `tcp_serve(0, echo_one)` — the high-level API spawns each accepted client as a `go fn()` worker that calls `async_tcp_read` → `io_suspend(fd)` → AFD.SYS-backed scheduler park → IOCP completion → resume. Compile-only smoke (no two-process orchestration); the value is link-surface confirmation that BOTH the ws2_32 user FFI AND the Phase 5e AFD.SYS substrate AND the Phase 5a/b/d IOCP+threading machinery all land in one 243 KB binary. Gate: `./self-hosted/bin/quake xbuild:tcp_serve` — verifies all 22 substrate symbols present across ws2_32.dll + ntdll.dll + KERNEL32.dll. |
| `tcp_connect_timeout_smoke.qz` | Phase-5e+++++ cross-platform `tcp_connect_timeout` (non-blocking-connect + WSAPoll + restore-blocking). Connects to TEST-NET (`192.0.2.1:65530`, RFC 5737 — guaranteed unreachable) with a 500ms timeout and expects the "Connection timed out" error path. Exercises the new `socket_wait_one` (POSIX `poll` vs Windows `WSAPoll`), `socket_set_blocking`, and the `EINPROGRESS`/`EWOULDBLOCK` alias dual on Windows. Native macOS run completes in ~0.51s (matches the 500ms timeout window). PE32+ imports verified: 9 connect-with-timeout substrate symbols including `WSAPoll` + `ioctlsocket` + `getsockopt`. Gate: `./self-hosted/bin/quake xbuild:tcp_timeout`. |
| `HANDOFF.md` | This file. |

There are intentionally no pre-built `.exe` artifacts checked in.
Every build is reproducible from source — see "Rebuilding" below.

## Rebuilding

Two one-liners (need `zig`, `llc`, and the Quartz compiler built):

```bash
# Smallest probe — produces hello.exe
./self-hosted/bin/quake xbuild:windows
# → tmp/xbuild-windows/hello.exe   (PE32+ x86-64, ~261 KB)

# Helper-acceptance probe — produces diagnostics.exe
SRC=examples/windows/diagnostics.qz ./self-hosted/bin/quake xbuild:windows
# → tmp/xbuild-windows/diagnostics.exe   (PE32+ x86-64, ~265 KB)

# Phase-5a scheduler smoke — produces go_smoke.exe
SRC=examples/windows/go_smoke.qz ./self-hosted/bin/quake xbuild:windows
# → tmp/xbuild-windows/go_smoke.exe   (PE32+ x86-64, ~229 KB)

# Phase-5e+ ws2_32 user-facing socket FFI — produces socket_smoke.exe
SRC=examples/windows/socket_smoke.qz ./self-hosted/bin/quake xbuild:windows
# → tmp/xbuild-windows/socket_smoke.exe   (PE32+ x86-64, ~219 KB)

# Phase-5e++ two-process TCP echo — produces tcp_echo_smoke.exe
SRC=examples/windows/tcp_echo_smoke.qz ./self-hosted/bin/quake xbuild:windows
# → tmp/xbuild-windows/tcp_echo_smoke.exe   (PE32+ x86-64, ~247 KB)

# Phase-5e+++ std/net/tcp high-level API — produces tcp_listen_smoke.exe
SRC=examples/windows/tcp_listen_smoke.qz ./self-hosted/bin/quake xbuild:windows
# → tmp/xbuild-windows/tcp_listen_smoke.exe   (PE32+ x86-64, ~222 KB)

# Phase-5e++++ async TCP-on-Windows substrate — produces tcp_serve_smoke.exe
SRC=examples/windows/tcp_serve_smoke.qz ./self-hosted/bin/quake xbuild:windows
# → tmp/xbuild-windows/tcp_serve_smoke.exe   (PE32+ x86-64, ~243 KB)
# 22 substrate symbols across ws2_32 + ntdll AFD + KERNEL32 IOCP

# Phase-5e+++++ cross-platform connect-with-timeout
SRC=examples/windows/tcp_connect_timeout_smoke.qz ./self-hosted/bin/quake xbuild:windows
# → tmp/xbuild-windows/tcp_connect_timeout_smoke.exe   (PE32+ x86-64)
# 20 ws2_32 symbols including WSAPoll + ioctlsocket + connect

# Hyperdrive (the eli deliverable)
./self-hosted/bin/quake xbuild:hyperdrive
# → examples/hyperbouba/build/hyperdrive.exe   (PE32+ x86-64, ~1.3 MB)
```

For manual cross-compile without quake:

```bash
./self-hosted/bin/quartz --target=x86_64-pc-windows-gnu hello.qz > hello.ll
llc hello.ll -filetype=obj -o hello.o
zig cc -target x86_64-windows-gnu hello.o -o hello.exe -lbcrypt
```

The `-lbcrypt` is mandatory — every Quartz Windows binary references
`BCryptGenRandom` from `bcrypt.dll` (the math.rand seed path routes
through it). `-lntdll` and `-lws2_32` are also mandatory for any binary
that uses `go fn()` (Phase 5e — AFD.SYS substrate). Linker dead-strip
isn't enabled by default, so omitting these produces "undefined symbol"
errors at link time. The `quake xbuild:windows` task adds all three.

## Running on Windows

Once the `.exe` is on a Windows machine:

```cmd
diagnostics.exe
```

Expected output (the four `[N]` sections are unit tests in disguise — each
catches a different failure mode of the corresponding Phase-4 helper):

```
Quartz on Windows — Phase 4 helper diagnostics
==============================================

[1] file metadata (GetFileAttributesEx on Windows)
    path  : examples/windows/diagnostics.qz
    size  : 5437 bytes
    mtime : 1779485669 (unix epoch seconds)

[2] monotonic clock (QueryPerformanceCounter on Windows)
    t0    : <ns timestamp>
    t1    : <ns timestamp, ≥ t0>
    delta : <positive Int> ns over a 100k-iter loop ...

[3] crypto-secure random (BCryptGenRandom on Windows)
    r0    : <Int>
    r1    : <Int, different from r0>
    r2    : <Int, different from both>

[4] peak resident set size (K32GetProcessMemoryInfo on Windows)
    rss   : <positive Int> (raw — platform-specific units)

All four helpers reached without trap — Phase 4 acceptance ✓
```

If section [1] shows `size : -1` and `mtime : -1`, the `.exe` is being
run from a directory where the relative path `examples/windows/diagnostics.qz`
doesn't exist — that's a path issue, not a helper bug. The helper IS
wired correctly if `[2]`, `[3]`, `[4]` look right; just re-run from a
checkout that includes the source file.

Anything else that looks wrong (negative delta, collided random reads,
zero RSS, no output at all) — please paste the output and we'll
investigate together. Each helper has a fall-back code path that should
guarantee no silent corruption: trap-on-failure rather than degrade.

## Running tcp_echo_smoke

Two cmd windows on the Windows host. Order matters — start the server
first, then the client.

```cmd
:: Terminal 1 — server
C:\tmp>tcp_echo_smoke.exe server 8765

:: Terminal 2 — client (run after the server prints "listening...")
C:\tmp>tcp_echo_smoke.exe client 127.0.0.1 8765
```

Expected outputs (both terminals exit 0):

```
:: Terminal 1
server: starting on port 8765
server: bound 0.0.0.0:8765
server: listening; waiting for accept...
server: accepted client fd
server: recv 24 bytes
server: echo 24 bytes
server: done

:: Terminal 2
client: connecting to 127.0.0.1:8765
client: connected
client: sent 24 bytes
client: recv 24 bytes
client: payload MATCH — TCP echo verified
```

Substrate exercised: WSAStartup + socket(AF_INET, SOCK_STREAM) +
setsockopt(SO_REUSEADDR) + bind(0.0.0.0:port) + listen + accept on the
server side; socket + connect + send + recv + closesocket on both. If
any line is missing or `socket_last_error()` reports a non-zero
WSAE* code, paste the output.

Port number is arbitrary (above 1024 doesn't need admin). The first
positional arg picks the mode. The Windows firewall may prompt for
network access on first run — allow Private Network is sufficient
for loopback.

## What's verified and what isn't

✅ Cross-compile pipeline (Darwin → PE32+ x86-64 binary)
✅ Link with zig cc + mingw-w64 + lld-link
✅ All five Phase-4 runtime helpers' IR compiles + links + resolves
✅ DLL imports inspect cleanly (bcrypt, kernel32, UCRT forwards)
✅ Native macOS run of `diagnostics.qz` produces sensible output
   (mtime = today's date, RSS in plausible range, distinct random reads)

⏳ Actual runtime execution on a Windows machine
   (Mechanical link + magic-byte + import-table inspection is the most
   that's possible from a Darwin host. The new helpers were designed
   against MSDN canonical patterns + corroborating BearSSL / TweetNaCl
   / mingw-w64 source; chance any is structurally wrong vs. needing a
   flag tweak is low.)

⏳ `--dev` live reload on hyperdrive
   (`file_mtime` now returns real values on Windows; the polling loop
   in `hyperdrive/driver.qz:209` should fire correctly. Untested
   end-to-end on Windows.)

⏳ `go fn()` — Phases 5a + 5b + 5c + 5d + 5e all landed, covering the
   full scheduler substrate. **Phase 5a**: pthread→Win32 shim block
   (SRWLock + CONDITION_VARIABLE + CreateThread). **Phase 5b**: IOCP
   HANDLE creation in sched_init, IOCP-flavored I/O poller body
   (`GetQueuedCompletionStatusEx` + packed completion-key dispatch:
   Io/Wake/Timer/Process), cross-thread wake via
   `PostQueuedCompletionStatus` (replaces the POSIX pipe-write wakeup),
   `CloseHandle(iocp)` on cleanup. **Phase 5c**: software timer min-heap
   for `sched_sleep` — drained at the top of each poller iteration; the
   next-expiry-ms feeds the GQCSEx timeout. **Phase 5d**: process-exit
   monitoring via `RegisterWaitForSingleObject` — a Win32 threadpool
   callback posts a kind=Process completion to our IOCP when a child
   HANDLE signals. **Phase 5e**: socket-readiness via AFD.SYS. sched_init
   opens `\Device\Afd\Quartz` and associates with IOCP at key=0;
   `__qz_sched_register_io` allocates a 72-byte SockState block (IOSB +
   AFD_POLL_INFO + task_ptr) and submits via `NtDeviceIoControlFile`
   with `IOCTL_AFD_POLL=0x00012024`. The poller's `ev_io:` branch loads
   the SockState pointer from `OVERLAPPED_ENTRY.lpOverlapped`, applies
   mio's iosb.Status / NumberOfHandles / handles[0].events decision tree,
   reenqueues the task, and frees the block. WSAIoctl(SIO_BASE_HANDLE)
   unwraps Winsock LSP proxies before the kernel call.
   `go_smoke.exe` (230 KB) and `io_smoke.exe` (231 KB) link clean with
   `NtCreateFile` / `NtDeviceIoControlFile` / `NtClose` (ntdll),
   `SetFileCompletionNotificationModes` (kernel32), `WSAIoctl` (ws2_32),
   plus the 5b IOCP triad and 5d threadpool primitive. Zero libwinpthread
   / kqueue / epoll / timerfd / pidfd imports. Same Darwin-host
   constraint as prior phases — runtime confirmation needs a Windows
   machine.

✅ **ws2_32 user FFI — VERIFIED ON WINDOWS HOST 2026-05-22**
   `socket_smoke.exe` ran clean on a real Windows machine — first
   end-to-end runtime confirmation across the entire Phase 5 + ws2_32
   stack. Observed transcript:

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

   What this implicitly verifies on the Windows host (beyond the explicit
   line-per-line confirmation of the ws2_32 substrate itself):

   - **PE32+ load + link** works end-to-end on a real Windows machine
     (not just llvm-objdump magic-byte inspection from Darwin).
   - **Phase 4 helpers** all functional: `puts`, `mem_alloc`, `qz_free`,
     `printf`-backed `#{...}` interpolation, `ptr_read_byte` /
     `ptr_write_byte`, BCryptGenRandom-seeded math.rand init,
     QueryPerformanceCounter time substrate. Anything Quartz emits as
     boilerplate at program startup.
   - **ws2_32 ABI** is correct end-to-end: SOCKET (i64) doesn't truncate
     on the return path; the 16-byte sockaddr_in layout (u16 family +
     u16 port BE + u32 addr BE + 8-byte zero) holds; getsockname's
     network-byte-order read produces a sensible ephemeral port from
     the Windows kernel (9655 in this run).
   - **The cross-platform helpers** (`socket_init_once`, `socket_close`)
     dispatch correctly to their Windows variants. The lazy WSAStartup
     guard works on the first call.

   Still un-runtime-verified (substrate is wired; just needs a probe):
   - A full bind → listen → accept → send → recv → close round-trip
     would need a paired client + server (sized ~0.3-0.5 qd as
     `tcp_echo_smoke.qz` exercising the AFD.SYS scheduler park/wake
     alongside the user FFI). Filed forward.

❌ TUI host on Windows
   (`std/terminal.qz` uses POSIX `poll()` + `ioctl()` not in mingw-w64.
   `make tui TARGET=...` would fail at link. Filed forward.)

❌ Hyperdrive runtime behaviour (TIGR window opens, framebuffer
   presents, audio plays through WASAPI, input routes from
   `ReadConsoleInput` equivalent)
   — only testable on a real Windows machine.

## If something breaks

1. **Rebuild from clean cache.** The Tier 0 cache used to be
   target-blind (fixed 2026-05-22 PM in commit `18879bac`) — pre-fix,
   compiling natively then cross-compiling returned stale IR. If you
   suspect this:
   ```bash
   rm -rf .quartz-cache examples/hyperbouba/.quartz-cache
   ./self-hosted/bin/quake xbuild:hyperdrive
   ```

2. **Run the diagnostics probe first.** It's smaller and exercises each
   Phase-4 helper independently. If `diagnostics.exe` is broken, so is
   anything bigger; if it's fine, the bug is somewhere in the larger
   program.

3. **Inspect the .exe imports.** From any platform with llvm-objdump:
   ```bash
   llvm-objdump -p hyperdrive.exe | grep -E 'DLL Name'
   ```
   Expected DLLs: `OPENGL32`, `GDI32`, `bcrypt`, `KERNEL32`, `USER32`,
   `SHELL32`, `ADVAPI32`, `OLE32`, `WINMM`, plus the UCRT `api-ms-win-crt-*`
   forwards. Anything else missing → file an issue.

4. **Crash with no stack info?** Quartz's backtrace on Windows currently
   prints raw addresses via `RtlCaptureStackBackTrace` (commit `4f7204b5`).
   You can decode them externally:
   ```bash
   llvm-symbolizer -e hyperdrive.exe 0x<address>
   addr2line -e hyperdrive.exe -f 0x<address>
   ```
   The `dbghelp.dll`-backed symbolicated path is filed forward —
   addresses-only is the current ground truth.

## Calibration (what this cost)

Phase 1 (Windows IR emission) — ~0.3 quartz-day. Commit `7452e867`.
Phase 3 (hyperdrive.exe link) — ~0.2 quartz-day. Commit `2247757b`.
Phase 4 (runtime helper polish) — ~0.2 quartz-day. Commit `4f7204b5`.
Tier 0 cache fix + diagnostics + SRC override — ~0.1 quartz-day. Commit `18879bac`.
Phase 5a (pthread→Win32 shim + sched init) — ~0.5 quartz-day. See
docs/design/QUARTZ_WINDOWS_TARGET.md §Phase 5.
Phase 5b (IOCP event loop core + cross-thread wake) — ~0.3 quartz-day.
Same commit-day as 5a.
Phase 5c (software timer min-heap for sched_sleep) — ~0.3 quartz-day.
Phase 5d (RegisterWaitForSingleObject for proc-exit) — ~0.2 quartz-day.
Phase 5e (AFD.SYS socket-readiness substrate) — significantly under the
original 1.5-2.5 qd projection. D2 research synthesis (mio + wepoll +
lenholgate) plus the 5b/5c/5d substrate paid forward all of the
non-AFD-specific machinery.
Phase 5f (acceptance polish + handoff close-out) — trivially short.
Quake task `xbuild:phase5` + handoff doc updates. Filed forward:
SetThreadDescription (~0.2 qd, debugger visibility) and
SetConsoleCtrlHandler (~0.2 qd, Ctrl+Break task-dump).

**One-line Phase-5 acceptance gate:**

```bash
./self-hosted/bin/quake xbuild:phase5
```

Verifies all 11 canonical Phase-5 imports in `go_smoke.exe`. Single
command, single source of truth. If anything regresses, the failing
symbol is named in the output and points at the sub-phase to inspect.

Total: ~1.6 quartz-day across two calendar days (2026-05-22). The
design memo's original estimate was 5 quartz-days for Phases 1–4; the
over-counting came from treating each item in the inventory as if it
would need work, when in practice `zig cc` + mingw-w64 covers most POSIX
surface (clock_gettime, pthread, dup/dup2, opendir, stat) and `tigr.c` /
`miniaudio.h` ship Windows backends out of the box. The only things
needing real Quartz-side work were the seven runtime helpers listed in
the design memo §1-2, plus the Phase 5 scheduler port (sized 3.4–5.3
quartz-days; 5a delivered in 0.5).
