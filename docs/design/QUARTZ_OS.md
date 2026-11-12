# QUARTZ_OS — a multi-program Quartz operating system

> Design memo. Decisions before code. Captures the shape of the
> QOS.0–QOS.7 epic so a future session has something durable to
> resume from.
>
> **Status:** **FAR, FAR STRETCH — not scheduled, not a priority.**
> This doc exists so the design isn't lost, not because work is
> imminent. Other roadmap work (Phase A–E, NET.2–5, the in-flight
> Union/Intersection/Record type system) comes first. Do not start
> QOS.1 without an explicit decision to promote this epic.
>
> **Roadmap row:** `docs/ROADMAP.md` → KERN.10.
>
> **Provenance:** design conversation 2026-05-16. Supersedes nothing;
> extends the KERN epic past the single-program unikernel.

## What this is

Today the unikernel (`tools/baremetal/hello_x86.qz`, ~6,900 LoC) is a
**single-program** system: one Quartz binary, compiled to one ELF,
running ring 0 in one address space, *is* the kernel and the
application both. It serves `mattkelly.io` end to end with zero C and
zero Linux in the request path.

QUARTZ_OS is the next structural step: a **multi-program** system that
loads and runs *other* Quartz binaries as isolated processes,
scheduled and resource-managed by the kernel. The headline:

> Every process in the table — the kernel, the network stack, the
> dashboard, and every program it spawns — is Quartz. Zero C anywhere
> in the machine.

This is **not** the Linux-ABI direction (running unmodified Linux
binaries). That was considered and rejected: the moment you implement
the Linux syscall ABI, the binaries on top are musl + C, and the
demo's purity story dilutes from "the whole stack is the language" to
"the language can host C." QUARTZ_OS keeps the stack pure by only
running Quartz.

## Why this shape (and not the obvious alternative)

The obvious alternative is a conventional Unix-like kernel:
per-process page tables, ring 3, `syscall` traps, `fork`/`exec`,
ambient-authority VFS. That is a large amount of work whose payoff is
*compatibility* — an OS-project goal, not a language-demo goal.

QUARTZ_OS instead exploits a fact the conventional design can't: **we
own the language, the compiler, the binary format, and the syscall
ABI, and the language is memory-safe.** That collapses most of the
hard work, because the OS we need is, in large part, the Quartz
runtime *scaled up and renamed*:

| OS concept | Already built, for the language/unikernel |
|---|---|
| IPC | `std/sync/channel.qz` — a cross-process channel *is* the IPC primitive |
| Process memory lifecycle | `Arena` + `trait Drop` (`std/memory.qz`) — a process is an arena; exit is a drop |
| Process + thread scheduling | KERN.8 M:N work-stealing SMP scheduler |
| Process crash / `kill` | `Throws` effect unwind; `Scope` cancellation cascade |
| Syscall surface | the effects system — a syscall is an effect operation |
| Driver stack | virtio-net, TCP/IP, HTTP, WireGuard — all already Quartz |

The epic is mostly *naming, factoring, and isolation*, not greenfield
kernel construction.

## Research — what the world does

- **Singularity** (Microsoft Research, ~2004–2010, Sing#/C#) — the
  direct ancestor. Software-Isolated Processes: every process runs
  ring 0 in **one address space**, isolated by language safety + a
  verifying compiler, not the MMU. Typed channels over an "exchange
  heap" with linear ownership. Each process ships a manifest the
  kernel verifies. Context switch and IPC ~10× cheaper than
  hardware-isolated OSes. Never shipped publicly.
- **Midori** — the productized Singularity successor. Cancelled
  before release; ideas leaked into .NET (spans, async).
- **Theseus OS** (Rust, ~2020) — "intralingual" isolation: cells
  isolated by the type system, no MMU walls. Live evolution, fault
  recovery.
- **seL4 / Fuchsia's Zircon** — the capability model: no ambient
  authority, processes hold *handles*; channels are the IPC. Zircon
  is the modern, shipping reference for capabilities-done-right.
- **MirageOS** — the opposite corner: one app per unikernel, no
  multi-program. That is what Quartz has *today*.

**Quartz's position:** Singularity's software-isolation thesis was
never shipped publicly and Midori was cancelled. QUARTZ_OS can ship
it — in a self-hosted language, on the public internet, as the
language's own demo. "The OS Microsoft Research prototyped and
shelved, serving a marketing site."

## The four design pillars

### Pillar 1 — SASOS-pure isolation, hybrid-ready

v1 runs **only compiler-certified pure Quartz processes**: no FFI, no
`CPtr`, no raw `unsafe`. All processes run ring 0 in the single
address space. Isolation is provided by Quartz's memory safety, not
the MMU.

- Context switch = a scheduler hop. No page-table swap, no TLB flush,
  no ring transition.
- The compiler emits a **purity attestation** in the binary (a note
  section / manifest). The loader refuses anything that fails it.
- **The TCB is the compiler.** A miscompile is an isolation hole.
  For a language demo this is the *point* ("trust the language"),
  but it must be stated openly, never hidden.

**Hybrid-ready:** the design reserves a second isolation tier —
MMU-backed, ring 3, per-process page tables — for *untrusted* /
FFI-using processes. v1 does **not** build it; it only ensures the
loader and capability layer don't have to change when it lands
(post-v1, see KERN.10 follow-ons). A process that uses FFI is simply
rejected by v1's loader rather than mis-isolated.

### Pillar 2 — Capabilities, not ambient authority

A process starts life holding only the *handles* its parent grants
it: a console write-handle, a channel endpoint, a directory handle.
There is no global namespace it can reach without a capability. This
is the Zircon/seL4 model. It pairs naturally with channels-as-IPC and
is strictly *less* work than a Unix ambient-authority VFS.

Each process has a **capability table**; kernel API calls take a
capability index and the kernel checks it. This is also the seam the
future MMU tier needs — a hardware-isolated process traps, the trap
handler indexes the same table.

### Pillar 3 — Syscalls are effect operations

The Quartz-native answer to "what is a syscall." A process doing I/O
runs under `with Console do … end`, `with FileSystem do … end`,
`with Net do … end`. The **kernel installs the root handlers**. A
syscall is an effect-op dispatch; the capability is the handler
instance.

This reuses the existing `Throws` / `Scope` / `Selectable` effect
machinery — no new mechanism — and makes the kernel boundary
*statically visible* in a process's type signature. A process that
can't do I/O literally doesn't carry the effect.

### Pillar 4 — A third compile target: `x86_64-quartz-os`

The compiler has `hosted` (libc) and `freestanding` (unikernel).
QUARTZ_OS adds a third target. A `quartz-os` binary links a thin
**libos shim** instead of libc or the freestanding runtime. The shim
routes:

- `alloc` → kernel heap (the process's arena)
- `go fn()` → kernel scheduler (no per-binary scheduler shipped)
- I/O → capability calls via the effect handlers

The binary ships **no scheduler and no allocator of its own** — it
borrows the kernel's. Built as ELF PIE so the loader can place it
anywhere in the single address space. This target is the leverage
point: once it exists, every Quartz program is a candidate process
for free.

## Goal (v1)

Boot → `init` (first Quartz process) → a **process-monitor dashboard**
process, reachable over HTTP at the existing demo subdomain. The
dashboard shows a live process table; the browser can spawn and kill
pure Quartz processes; each spawn loads an ELF into a fresh arena with
a fresh capability set, each kill cancels the process's root scope and
drops its arena. Fixpoint stays clean throughout.

The dashboard capstone was chosen over an interactive shell because it
builds directly on the KERN.8 / SOUL telemetry already in tree and
needs **no TTY/termios work** — htop-of-goroutines becomes
htop-of-processes.

## Non-goals (v1)

- **MMU isolation.** Pure-SASOS only; FFI processes are rejected, not
  isolated. The hardware tier is a post-v1 follow-on.
- **Linux ABI / running non-Quartz binaries.** Explicitly rejected
  (see "What this is").
- **Interactive shell / TTY / termios.** The dashboard capstone
  removes this from the v1 path; a shell is a post-v1 nicety.
- **Persistent storage.** v1 uses a RAM tmpfs populated from an
  embedded cpio initramfs. virtio-blk + a real FS is post-v1.
- **Drivers as processes.** Drivers stay in-kernel for v1
  (Singularity ran them as SIPs — a post-v1 option).

## Phase breakdown

Quartz-time estimates per `CLAUDE.md` D9 (traditional ÷ 4;
calibration: KERN.8 epic = ~5.5 quartz-days).

| Phase | Scope | Quartz-time |
|---|---|---|
| QOS.0 | This memo + the `x86_64-quartz-os` target triple spec, libos ABI, capability/effect syscall surface | 3–5 q-days |
| QOS.1 | Buddy frame allocator replacing the bump PMM; per-process arena heap with free-on-exit | 1–1.5 q-weeks |
| QOS.2 | Process struct + capability table + ELF PIE loader; scheduler becomes process-aware (goroutines tagged by owning process) | 1.5–2 q-weeks |
| QOS.3 | `x86_64-quartz-os` target + libos shim. **Milestone: a pure Quartz binary prints via a console capability and exits cleanly, arena reclaimed** | 1.5–2 q-weeks |
| QOS.4 | Cross-process channels — move-semantics message transfer; the linear-ownership / exchange-heap story (+ any compiler `Send` work) | 1.5–2 q-weeks |
| QOS.5 | VFS + RAM tmpfs + cpio initramfs unpack; `/bin`, `/dev` | 1.5–2 q-weeks |
| QOS.6 | `init` (first process) + timer preemption (no runaway process can wedge the box) | 1–1.5 q-weeks |
| QOS.7 | Capstone: process-monitor dashboard — process table, spawn/kill over HTTP, htop-of-processes; built on KERN.8/SOUL telemetry | 1–2 q-weeks |

**v1 total (QOS.0–QOS.7): ~9.5–13 quartz-weeks.** Comparable raw size
to a Linux-ABI kernel, but every phase *compounds* the
language-purity story rather than diluting it, and there is no opaque
external-ABI debugging tax — both sides of every boundary are ours.

**Post-v1 (not estimated):** MMU-isolation tier for FFI/untrusted
processes; virtio-blk + persistent FS; drivers-as-processes;
interactive shell + TTY.

## Risks

1. **The compiler is the TCB.** SASOS means a miscompile is a
   security hole. Acceptable and on-thesis for a demo; the MMU tier
   is the answer when it stops being acceptable. State it openly.
2. **`Send` / linear ownership for IPC may be real compiler work.**
   `Send`/`Sync` trait *registrations* exist, but "move a message
   across a process boundary and statically forbid the sender from
   touching it after" is a stronger property. **QOS.4 is the phase
   most likely to overrun** — budget for type-system work there.
3. **Preemption was deferred twice already** (KERN.8 non-goals). A
   multi-program OS needs it for real — one buggy process cannot be
   allowed to hang the machine. Small (the LAPIC timer exists) but no
   longer optional; lives in QOS.6.
4. **Per-process heap reclamation must actually free.** The bump PMM
   never frees — fine for a one-program unikernel, fatal here. QOS.1
   is load-bearing for everything after it; an arena that leaks on
   process exit defeats the whole model.

## What to read first when this resumes

- `tools/baremetal/hello_x86.qz` — the current single-program kernel.
- `docs/design/KERN_8_SMP.md` — the scheduler this epic extends.
- `std/sync/channel.qz`, `std/memory.qz` (`Arena`/`Drop`) — the IPC
  and process-lifecycle primitives, already built.
- `docs/SOUL_OF_QUARTZ.md` — the telemetry the QOS.7 capstone builds on.
