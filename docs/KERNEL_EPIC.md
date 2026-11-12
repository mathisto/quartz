# KERNEL EPIC — Bare-Metal Systems Infrastructure and Unikernel

Living document for the systems-language infrastructure buildout and unikernel initiative.

- **Status**: Pre-implementation / Planning complete
- **Last updated**: 2026-04-18
- **Companion**: [`docs/research/EFFECTS_IMPLEMENTATION_PLAN.md`](research/EFFECTS_IMPLEMENTATION_PLAN.md)
- **Related planning artifact**: `~/.claude/plans/alright-i-ve-put-us-composed-crown.md`

## Context

Quartz is currently a capable userspace systems language — self-hosted, LLVM backend, async/await, memory model V2, binary DSL. The HTTP/2 server at `mattkelly.io` proves production-grade cross-platform ELF deployment. The next dogfooding initiative is to write a **unikernel**: the kernel and the Quartz web server linked as one bare-metal binary, booting on QEMU and eventually on the user's VPS with no Linux underneath.

The unikernel is the forcing function. The real deliverable is the **infrastructure buildout**: the set of capabilities every world-class systems language (Rust, Zig, C) ships for kernel / embedded / driver work. Once built, the unikernel becomes tractable and hypervisor / RTOS / embedded work becomes downstream. Per Prime Directive 1 (pick highest-impact), this is the correct next dogfooding initiative after HTTP/2 deployment.

**Critical coordination with the effects track:** the parallel algebraic-effects initiative (`docs/research/EFFECTS_IMPLEMENTATION_PLAN.md`, ~5-8 quartz-weeks) migrates async from special-case `$poll` lowering to a general `Async` effect in its Phase 3 and deletes the old machinery. This plan coordinates with that one:

- The kernel scheduler becomes an `Async` effect handler — not a port of the pthread M:N scheduler. The scheduler work waits for effects Phase 3.
- The allocator becomes an `Alloc` effect (Koka's `alloc⟨h⟩` model) — not Zig-style explicit allocator params. The stdlib allocator API waits for effects Phase 2.
- Adding `Alloc` to the initial effect set is raised as an input to effects Phase 0.

## Starting Reality (verified by audit, April 2026)

Quartz is further along than it looks. **PRESENT:**

- Atomics with all 5 orderings (relaxed, acquire, release, acq_rel, seq_cst) — `self-hosted/backend/cg_intrinsic_conc_task.qz:241-479`
- `volatile_load<T>` / `volatile_store<T>` with typed U8/U16/U32/U64 variants — verified by `spec/qspec/volatile_spec.qz`
- `@[section(...)]` attribute parsing — `self-hosted/frontend/parser.qz:7429-7656`
- Inline asm via `@c("...")` — verified working in `tools/baremetal/hello.qz:34`
- `@[naked]` functions — `self-hosted/frontend/parser.qz:7554-7556`
- `@[repr(C)]`, `@[packed]` — `self-hosted/frontend/parser.qz:7538-7553`
- `extern "C"` function **definitions** (export side) — `self-hosted/frontend/parser.qz:5878-5907`
- Freestanding targets: `aarch64-unknown-none`, `x86_64-unknown-none-elf` — verified by `spec/qspec/freestanding_spec.qz`
- Bare-metal hello world that compiles and boots on QEMU aarch64-virt — `tools/baremetal/hello.qz` + `tools/baremetal/aarch64-virt.ld`

**ABSENT (Tier 1 gaps to fill):**

- Atomic RMW ops: `and`, `or`, `xor`, `min`, `max` (have add/sub/xchg/cas)
- Custom calling conventions — only `"C"` today; need `"x86-interrupt"`, `"sysv64"`, `"aarch64-interrupt"`
- Target knobs: `-mno-red-zone`, `-mno-sse`, `-fno-pic`, `-fno-stack-protector`
- Weak + alias symbols (`@[weak]`, `@[alias("sym")]`)
- Custom TLS (non-pthread; x86 FS/GS, ARM TPIDR)
- `@[panic_handler]` attribute hook — today `panic()` calls `@abort` hardcoded at `self-hosted/backend/cg_intrinsic_system.qz:382,428`
- Field-level `@[align(N)]` on struct fields
- Quake linker-script passthrough (`-T script.ld`)

**Libc dependencies today** (from `nm self-hosted/bin/quartz | grep ' U '`): ~50 symbols. Allocator (`@malloc` hardwired at `cg_intrinsic_memory.qz:34`), threading (pthread), I/O (printf/fopen family), timers (clock_gettime, usleep), I/O multiplexing (epoll on Linux, kqueue on macOS). Freestanding-target mode already suppresses most of these.

## Committed Design Decisions

1. **Allocator = `Alloc` effect**, not explicit param. Handler-as-allocator: kernel installs bump for boot, slab for runtime, per-task arena inside tasks. Raise "add `Alloc` to initial effect set" as an **input to effects Phase 0** decision log. Do NOT build Zig-style params as an interim.
2. **Interrupt calling convention = type-level** (`extern "x86-interrupt" def ...`). Compiler emits `iret` and correct register save. Rejects calling an interrupt handler as a normal function at type-check time. Prior art: Rust's `extern "x86-interrupt"`, Zig's `callconv(.Interrupt)`. Avoid C-style attribute-only approach.
3. **Stdlib split = three-tier** (`std/core/` / `std/alloc/` / `std/std/`). Industry standard (Rust's core/alloc/std), adopted by every no_std project. `core` = no allocator, no OS. `alloc` = needs `Alloc` effect handler. `std` = needs OS. MirageOS / IncludeOS retrospectives cite wishing they'd done this earlier.

## Epics

Epics marked **[P]** are effects-independent and start immediately in parallel with effects Phases 0-2. Epics marked **[B]** block on effects progress.

### EPIC SYS.1 — Bare-Metal Completeness [P]

Fill the Tier 1 ABSENT list. Each item is a small, independent contribution.

**Files to touch:**

- Atomic RMW completeness: `self-hosted/backend/cg_intrinsic_conc_task.qz` (add and/or/xor/min/max via `atomicrmw`), `self-hosted/middle/typecheck_builtins.qz` (register signatures)
- Custom CC: `self-hosted/frontend/parser.qz:5815` (accept strings beyond `"C"`), `self-hosted/backend/codegen*.qz` (emit `x86_intrcc`, `aarch64_vector_pcs`, etc. into LLVM function attributes)
- Target knobs: `tools/quake.qz` + codegen command assembly (pass through to `llc`)
- Weak/alias: parser attribute + codegen `@[weak]` → LLVM `weak` linkage, `@[alias("sym")]` → LLVM alias
- Custom TLS: `cg_intrinsic_system.qz` + runtime — intrinsics for `read_fs_base` / `write_gs_base` (x86_64) and `read_tpidr_el1` (aarch64)
- `@[panic_handler]`: parser + `cg_intrinsic_system.qz:382,428` — replace hardcoded `@abort` with call through registered handler symbol
- Field-level `@[align(N)]`: parser + mir struct layout
- Quake linker-script: add `linker_script: "path.ld"` option to Quake build tasks

**Exit criteria:**

- New QSpec specs for each new attribute / intrinsic
- Fixpoint (gen1 == gen2) holds through every change
- `tools/baremetal/hello.qz` still boots on QEMU
- `spec/qspec/freestanding_spec.qz` expanded to cover new capabilities

**Estimate:** ~1 quartz-week (~7-10 sessions).

### EPIC SYS.2 — Stdlib Three-Tier Scaffolding [P]

Reorganize `std/` into `std/core/`, `std/alloc/`, `std/std/`. Move modules that don't allocate to `core`. Leave allocator-API modules in `alloc` with `TODO: lift to Alloc effect` stubs — API shape waits for effects Phase 2.

**Files to touch:** entire `std/` tree. Module manifest / resolver to understand three-tier.

**Exit criteria:**

- Every existing `import std/...` still resolves
- `std/core/*` compiles with a freestanding target and zero libc references (verify via `nm`)
- QSpec green end-to-end

**Estimate:** ~2-3 quartz-days. Mechanical.

### EPIC SYS.3 — Coordinate Alloc-as-Effect with Effects Phase 0

Write a 1-page design note for the effects track arguing `Alloc` belongs in the initial effect set. Cite Koka's `alloc⟨h⟩`. Show the kernel heterogeneous-allocator use case. Submit as an input to the effects Phase 0 decision log.

**Files to touch:** `docs/research/EFFECT_SYSTEMS_NOTES.md` (add section) or new `docs/research/ALLOC_AS_EFFECT.md`.

**Exit criteria:** proposal landed in the effects decision log; Phase 0 explicitly accepts or rejects.

**Estimate:** ~0.5 quartz-day.

### EPIC SYS.4 — `Alloc` Effect Implementation + Stdlib API Shape [B]

**Blocks on:** effects Phase 1 (Throws pilot proves machinery) + Phase 2 (State/Reader proves multi-effect composition). If `Alloc` is accepted into the initial set, implement as part of Phase 2. Otherwise slot as Phase 2.5 or Phase 3.

Rewrite `std/alloc/` collections (Vec, HashMap, String, etc.) to carry `can Alloc` in their effect rows. Default prelude handler installs a libc-backed allocator. Kernel code installs a bump/slab handler.

**Estimate:** ~3-5 quartz-days once unblocked.

### EPIC SYS.5 — x86_64-unknown-none Parity with aarch64-virt [P] — **DONE (2026-04-18)**

Shipped in three slices this session:

1. **Infrastructure twin** (`13f2d372`): `x86_64-multiboot.ld` +
   `smoke_x86.s` (Multiboot2 header stub) + `baremetal:verify_x86_64`
   Quake task. Asm-level pipeline proven.

2. **Freestanding Quartz-source compile chain** (`33361b36` +
   `b86991a3` + `21bd3af7`): fuel_check freestanding skip, panic helper
   stubs, link-time libc externs (malloc/realloc/free/memcpy/memset/
   qsort), hoisted sort + reverse runtime helpers, freestanding-no-
   handler panic path. End-to-end pipeline: Quartz source → aarch64
   ELF verified by `baremetal:verify_hello_aarch64`.

3. **x86_64 twin** (`063c8961`): `baremetal:verify_hello_x86_64` runs
   the identical pipeline for x86_64-unknown-none-elf. Quartz source →
   x86_64 ELF end-to-end, kernel knobs applied (-mattr=-sse,-mmx,-avx
   -relocation-model=static).

**Exit criteria met:**

- ✅ Freestanding spec extended with x86_64 assertions (17/17 green).
- ✅ Five baremetal Quake tasks green end-to-end.
- ⚠️ `qemu-system-x86_64 -kernel hello_x86.elf` not yet exercised —
  requires the 32→64 long-mode trampoline + `.multiboot` header
  injection into the Quartz-source pipeline. Both are KERN.1 territory
  (actual kernel boot code, not language infrastructure). The language
  surface and full build pipeline are done.

Libc-stub artefact: `tools/baremetal/libc_stubs.c` — do-nothing
implementations of malloc/realloc/free/memcpy/memset/qsort so the
verify tasks can link without pulling in real libc. Real kernels
substitute their own bump/slab allocator + compiler-rt mem helpers +
sort implementation.

### EPIC KERN.1 — Unikernel Synchronous Parts [B] — **~85% DONE (2026-04-18)**

**Blocks on:** SYS.1, SYS.5. Effects-independent at this phase (synchronous I/O only).

Deliverables (original plan vs. actual):

- ✅ **GDT + IDT setup (x86_64).** Boot-trampoline GDT; Quartz-side IDT
  with `idt_set_entry` / `idt_zero` / `idt_install`. aarch64 vector
  table NOT done (only x86_64 has a live kernel so far).
- ✅ **Interrupt handlers.** `breakpoint_isr` (#BP), `divide_error_isr`
  (#DE), `page_fault_isr` (#PF with CR2 + error code), `timer_isr`
  (IRQ0), `serial_rx_isr` (IRQ4). 2-arg x86_intrcc signature
  proven end-to-end.
- ✅ **Timer driver.** PIT @ 100 Hz — PIC remap + PIT init + timer
  ISR drives `g_tick_count`. **APIC / LAPIC not done** — swap is
  ~100 LoC once we map the APIC MMIO page; `wrmsr` / `rdmsr`
  intrinsics already shipped for the enable path.
- ✅ **Serial / UART driver.** COM1 16550 TX + RX. TX via
  `uart_putc` / `uart_put_str`; RX via IRQ4 into `serial_rx_isr`
  with FIFO drain loop. Host-to-guest bytes echo under
  `-serial stdio`.
- ✅ **Physical memory manager (bump).** 1 MiB `.bss` pool,
  `pmm_alloc_page` / `pmm_zero_page`. Backs `libc_stubs.c`'s real
  malloc / realloc / memcpy so Quartz stdlib `Vec<T>` / `Map<K,V>`
  / String interpolation all work inside the kernel. Buddy / slab
  upgrade left for later phases.
- 🟡 **Paging setup.** First 16 MiB identity-mapped via 8 × 2 MiB
  huge PDEs in the boot trampoline — enough for current kernel.
  **Higher-half kernel mapping NOT done** — still a single
  kernel-address-space layout at low linear addresses. Good
  enough for unikernel; higher-half is a cleanup when we need
  per-process spaces (not required for KERN.3).

Bonus items that weren't originally in KERN.1 but landed here:

- **Toy cooperative scheduler.** Two-task phase alternation driven
  by timer. Pre-stages KERN.2. Replaces the planned "blinks a
  counter" demo with something meatier.
- **`libc-free `to_str` + string interpolation**. Makes kernel
  diagnostic I/O readable (`"Tick #{n}"` instead of seven
  `uart_putc()` calls).
- **`wrmsr` / `rdmsr` intrinsics** (listed under SYS.1 but shipped
  here because KERN.1 motivated them).

**What's left under KERN.1:**

1. **APIC + LAPIC timer** (~100 LoC, bounded). Replaces PIT. Needs
   a 4 KiB MMIO mapping for the APIC base page (0xFEE00000) — our
   current 16 MiB identity map doesn't cover it.
2. **Multiboot2 memory-map consumption** (~50 LoC). Walk the
   start_info tag chain, resize PMM to real RAM (128+ MiB under
   QEMU default instead of our fixed 1 MiB pool).
3. **Real context-switching scheduler** (~80 LoC incl. ~30 LoC asm).
   Upgrade from dispatcher-in-a-loop to per-task stack + saved RSP
   + `switch_to(from, to)` asm helper.
4. **aarch64 parity** (if we care). aarch64 hello.qz boots but has
   no IDT / exception / timer work — currently just `hlt`. Unblocked
   by everything the x86_64 side shipped; pure porting.
5. **More CPU exception handlers** (1-31). Mechanical data entry.

Items 1 + 2 + 3 are the useful "finish KERN.1 cleanly" set.
Items 4 + 5 are nice-to-haves for tier completeness.

**Exit criteria status:**

- ✅ Boots on QEMU x86_64 (`baremetal:qemu_boot_x86_64` gates on
  six sequential markers).
- ✅ Timer ISR fires and drives a counter + scheduler.
- ✅ Serial console readable and writable (bidirectional).
- ✅ Page tables valid — no fault on in-map access. #PF handler
  proves unmapped access is caught cleanly.
- ✅ Kernel-side asserts run (PMM + VEC + MAP smoke tests
  round-trip through real RAM + stdlib data structures).

**Estimate remaining:** ~2-3 quartz-days for items 1-3 above to
declare KERN.1 fully done.

### EPIC KERN.2 — Kernel Scheduler as `Async` Effect Handler [B]

**Blocks on:** KERN.1 + effects Phase 3 (async-as-effect migration complete).

Once effects Phase 3 ships, the existing M:N pthread scheduler is gone, replaced by an `Async` effect. Write a kernel-side `Async` handler that:

- Stores tasks in kernel ready-queues (per-CPU)
- Uses timer interrupts for preemption (or cooperative yields for co-op mode)
- Wakes tasks on I/O interrupts from the virtio drivers (KERN.3)

No threads. Single-address-space kernel with effect-handler-driven scheduling.

**Estimate:** ~1-2 quartz-weeks (rides on effects Phase 3's work).

### EPIC KERN.3 — Virtio Drivers + Web Server Port [B]

**Blocks on:** KERN.2 + SYS.4 (Alloc effect ready for use in collections).

Deliverables:

- virtio-net driver (ring descriptors, MMIO, IRQ handling)
- virtio-blk driver (optional — unikernel might not need block storage)
- Port `std/net/*.qz` socket layer to use a kernel TCP/IP stack (write a minimal stack OR pull in a smoltcp-equivalent written in Quartz)
- Port the existing web server binary to run inside the unikernel

Web server source changes = zero (colorless async via effects means same source runs in userspace and kernel).

**Estimate:** ~2-4 quartz-weeks. The TCP/IP stack is the long pole.

### EPIC KERN.4 — VPS Deploy

Boot the unikernel image on the user's VPS (hardware virt — most VPS providers support KVM). Replace the current Linux-hosted web server with the bare-metal one. Serve real traffic.

**Exit criteria:** `curl https://mattkelly.io/` served by a unikernel written entirely in Quartz, on the VPS, with no Linux underneath.

**Estimate:** ~2-3 quartz-days once KERN.3 works in QEMU.

### EPIC NET.1 — Crypto Stdlib + WireGuard on the Unikernel [P]

**Status:** Design complete. Implementation pre-Phase-1.
**Design memos:** [`design/CRYPTO_STDLIB_DESIGN.md`](design/CRYPTO_STDLIB_DESIGN.md) (the language work) + [`design/WIREGUARD_UNIKERNEL_DESIGN.md`](design/WIREGUARD_UNIKERNEL_DESIGN.md) (the consumer).

The unikernel is the forcing function; the deliverable is a credible Quartz crypto stdlib (~85% of the work) plus the WireGuard protocol (~15% unikernel glue). When this lands, `mattkelly.io` runs a VPN endpoint authored entirely in Quartz: own TCP/IP, own crypto, own VPN protocol, own self-hosted compiler.

**Why it's the right next dogfood after KERN.4:**
- Quartz has no crypto stdlib. Every serious systems language fills this gap early. The WireGuard protocol is unusually small (12-page spec, 4 pinned primitives, 1 fixed Noise variant) so the scope is bounded in a way "implement TLS" never is.
- Exercises exactly the language gaps a crypto stdlib needs: wide multiply intrinsic, secure zeroing, constant-time helpers, freestanding-friendly FFI.
- Extends the existing live demo without cannibalizing it — WG sits beside HTTP on a separate UDP port.

**Language deliverables (covered by CRYPTO_STDLIB_DESIGN.md):**
- `@widening_mul` + `@carrying_add` + `@borrowing_sub` compiler intrinsics — payback well beyond crypto (bignum, hash tables, PRNGs, decimal printing)
- `std/core/crypto/{chacha20poly1305,blake2s,curve25519,hkdf,subtle,zeroize}.qz` — Phase 1 as HACL\* FFI shims; Phase 2 reimplements primitive-by-primitive in pure Quartz
- `std/crypto/{noise,rng}.qz` — Noise IKpsk2 driver + DRBG
- Roadmapped: `Secret<T>` newtype + type-system tracking; `dudect_check` testing helper; `@[constant_time]` deferred (LLVM optimizer doesn't preserve constant-time semantics — cannot honestly ship without a Quartz-controlled lowering pass)

**Unikernel deliverables (covered by WIREGUARD_UNIKERNEL_DESIGN.md):**
- UDP layer in the unikernel IP stack (~1-2 days; tiny on top of existing IPv4)
- `std/net/wireguard/*` — peer table, handshake driver, transport, timers, device glue
- tun-equivalent integration: WG packets enter the existing IP route table (Option A — matches Linux WG model)
- Entropy source: RDRAND/RDSEED hardware intrinsics + HKDF-BLAKE2s DRBG
- Cross-implementation interop tests: wg-quick + boringtun

**Files to touch:**
- Compiler: `self-hosted/middle/typecheck_builtins.qz`, `self-hosted/backend/mir.qz`, `self-hosted/backend/codegen_intrinsics.qz`, new `self-hosted/backend/cg_intrinsic_arith.qz`
- Stdlib: `vendor/hacl-c/` (new), `std/core/crypto/*` (new), `std/crypto/*` (new), `std/net/wireguard/*` (new)
- Unikernel: `tools/baremetal/hello_x86.qz` (UDP + WG glue + RDRAND wrappers)
- Tests: `spec/qspec/widening_mul_spec.qz`, `spec/qspec/wg_*_spec.qz`, `spec/qz/wg_interop.qz`

**Forcing-function relationship to other epics:**
- **KERN.1 follow-up:** WG's per-session timers (rekey, keepalive, REJECT_AFTER_TIME) are the forcing function for proper LAPIC-driven `(wake_tick, callback)` timer subsystem. The toy serve-loop pump is enough for HTTP; not for WG.
- **SYS.2 dependency:** Three-tier stdlib scaffolding (`std/core/`) must be in place — primitives go in `std/core/crypto/*` because they don't allocate.
- **Independent of KERN.2 / KERN.3:** Effects-Phase-3 `Async` migration is not blocking. WG can ship on the existing scheduler.

**Exit criteria:**
- `quake guard` fixpoint holds through every commit
- Wycheproof vectors green for all four primitives
- WireGuard interop tests pass against `wg-quick` and `boringtun` (initiator + responder; idle + bulk; rekey; replay)
- A peer configured on a laptop can `wg-quick up`, ping the unikernel's WG IP, and receive responses
- `/api/stats.json` exposes `wg_peers`, `wg_handshakes_completed`, `wg_packets_encrypted`, `wg_packets_decrypted`
- Demo: SSH (or a chosen admin endpoint) reachable on the unikernel only via WG

**Estimate:** ~2-3 quartz-weeks for Phase 1 (working WG demo with HACL\* underneath). Phase 2 (replace HACL\* primitives with pure Quartz, one at a time) is its own ~1 quartz-month arc spread across separate sessions, no deadline.

**Phase 1 sequencing summary:**

| Days | Work |
|---|---|
| 1-2 | UDP layer in unikernel; CRYPTO Step 1.1 (license review + vendor HACL\* C) in parallel |
| 3-4 | CRYPTO Steps 1.2-1.4 — `std/core/crypto/*` shims + `@widening_mul` intrinsic |
| 5 | CRYPTO Steps 1.5-1.6 — RNG + Noise IKpsk2 stdlib (Step 1.7 Wycheproof loader deferred to Phase 2 entry — HACL\* is upstream-validated) |
| 6-7 | `std/net/wireguard/{peer,session,handshake}.qz` — WG handshake driver |
| 8-10 | `std/net/wireguard/{transport,timers}.qz` — encrypt/decrypt + state machines |
| 11-12 | `std/net/wireguard/device.qz` + tun-equivalent glue into unikernel IP stack |
| 13-14 | Entropy source: RDRAND/RDSEED intrinsics + DRBG wiring |
| 15-16 | wg-quick + boringtun cross-impl interop tests |
| 17-18 | Polish, docs, deploy to mattkelly.io |

## Verification (end-to-end)

**Per-EPIC:**

- SYS.1: new QSpec specs green, fixpoint holds, `tools/baremetal/hello.qz` still boots
- SYS.2: every `import std/...` still resolves; `std/core` links with zero libc symbols (`nm ... | grep ' U '` empty or whitelisted)
- SYS.5: `qemu-system-x86_64 -kernel ...` prints to serial and halts cleanly
- KERN.1: timer interrupts fire; serial console usable; no page faults during boot
- KERN.2: `Async` handler drives a toy cooperative-multitasking demo in the kernel
- KERN.3: HTTP request served from inside QEMU (via virtio-net + `qemu -nic user,hostfwd=tcp::8080-:80`)
- KERN.4: `curl https://mattkelly.io/` served by the unikernel on the VPS
- NET.1: Wycheproof vectors green; wg-quick + boringtun interop pass; laptop can ping unikernel over WG; `/api/stats.json` exposes WG telemetry

**Cross-cutting:**

- Every epic exits only after `quake guard` passes (fixpoint mandatory)
- Existing full QSpec suite stays green throughout
- Smoke tests (`brainfuck.qz`, `style_demo.qz`) pass at every epic boundary

## Coordination with Effects Plan

| This plan | Effects plan | Coupling |
|---|---|---|
| SYS.3 | Phase 0 decision log | Input: "add `Alloc` to initial effect set" |
| SYS.4 | Phase 2 (State/Reader) | Blocks on Phase 2 landing |
| KERN.2 | Phase 3 (Async migration) | Kernel scheduler = `Async` handler |
| all | Phase 5 (compiler dogfooding) | Unrelated; runs after |

**Shared risk:** if effects Phase 3 fails its kill criteria (async migration > 2x LOC or > 10% perf regression), the effect-handler-as-scheduler plan falls back to porting the existing M:N scheduler to bare metal. KERN.2 estimate doubles. Not load-bearing on this plan's overall viability — just a timeline hit.

## Estimation Summary (quartz-time)

| Epic | Estimate | Starts |
|---|---|---|
| SYS.1 Bare-metal completeness | ~1 week | now |
| SYS.2 Stdlib three-tier scaffolding | ~2-3 days | now |
| SYS.3 Alloc-as-effect proposal | ~0.5 day | now |
| SYS.5 x86_64 bare-metal parity | ~2-3 days | after SYS.1 |
| SYS.4 Alloc effect impl | ~3-5 days | after effects Phase 2 |
| KERN.1 Unikernel synchronous parts | ~1.5-2 weeks | after SYS.1 + SYS.5 |
| KERN.2 Scheduler as `Async` handler | ~1-2 weeks | after KERN.1 + effects Phase 3 |
| KERN.3 Virtio + web server port | ~2-4 weeks | after KERN.2 + SYS.4 |
| KERN.4 VPS deploy | ~2-3 days | after KERN.3 |
| NET.1 Crypto stdlib + WireGuard (Phase 1) | ~2-3 weeks | after SYS.2 — independent of KERN.2/3 |
| NET.1 Phase 2 (pure-Quartz primitives) | ~1 quartz-month | sequenced over time, post-Phase-1 |
| **Total wall-clock (Phase 1 only, parallel)** | **~6-10 quartz-weeks** | — |

Because effects Phase 3 is load-bearing upstream and itself costs ~7-10 days, the unikernel timeline is roughly bounded by the effects timeline rather than additive to it. Parallel execution is the critical sequencing win.

## Prior Art Referenced

- **Rust `no_std` ecosystem** — `core` / `alloc` / `std` split; `#[panic_handler]`; `extern "x86-interrupt"`; `#[naked]`; target JSON specs. Canonical reference.
- **Blog OS** (Philipp Oppermann, *Writing an OS in Rust*) — step-by-step unikernel build; our phase structure mirrors it.
- **HermitCore / RustyHermit** — Rust unikernel, closest spiritual peer. Retrospective: bolt-on allocator was painful; `Alloc` from day one avoids that.
- **Zig `freestanding` target** — `callconv(.Naked)`, `callconv(.Interrupt)`, `@cImport`. Cleaner CC model than Rust.
- **IncludeOS (C++)** and **MirageOS (OCaml)** — unikernel prior art with runtime concerns analogous to our effects story.
- **Redox OS / Hubris (Oxide) / Theseus (MIT)** — Rust kernels with different ownership / isolation models.
- **seL4** — capability-based design. Not adopting now; note for future formal-verification work.
- **Koka** — `alloc⟨h⟩` effect pattern drives the `Alloc`-as-effect decision.

## Decision Log

- **2026-04-17** — Allocator model chosen as `Alloc` effect (Koka `alloc⟨h⟩`), not Zig-style explicit params. Reason: aligns with effects track, handler swap = arena swap is the right abstraction for heterogeneous kernel memory.
- **2026-04-17** — Interrupt calling convention syntax chosen as type-level (`extern "x86-interrupt"`), not attribute (`@[callconv(interrupt)]`). Reason: type safety — rejects calling an interrupt handler as a normal function at type-check time. Prior art: Rust / Zig.
- **2026-04-17** — Stdlib split chosen as three-tier `core` / `alloc` / `std` (Rust model). Reason: industry standard; MirageOS and IncludeOS retrospectives cite wishing they'd done this earlier.
- **2026-04-17** — Kernel scheduler deferred to post-effects-Phase-3 instead of port-pthread-now. Reason: effects migration deletes `$poll` machinery anyway; re-porting first would be wasted work.
- **2026-05-08** — NET.1 (Crypto stdlib + WireGuard) added as parallel-track epic, hybrid HACL\*-then-pure-Quartz path. Reason: Quartz has no crypto stdlib; WireGuard is the smallest credible forcing function (12-page spec, fixed primitives, fixed Noise variant); 85/15 split favors language work over unikernel glue. Detailed memo: [`design/CRYPTO_STDLIB_DESIGN.md`](design/CRYPTO_STDLIB_DESIGN.md) + [`design/WIREGUARD_UNIKERNEL_DESIGN.md`](design/WIREGUARD_UNIKERNEL_DESIGN.md).
- **2026-05-08** — `@[constant_time]` deferred indefinitely. Reason: LLVM optimizer doesn't preserve constant-time semantics; static rejection of bad source patterns without backend control would be a half-truth. `subtle` helpers + `Secret<T>` (roadmap) + `dudect_check` (roadmap) is what production crypto actually relies on. Revisit when Quartz has a controlled-lowering pass for marked functions.
- **2026-05-08** — Step 1.7 (Wycheproof loader) deferred to **Phase 2 entry gate**. Reason: HACL\* is upstream Wycheproof-validated; running the same vectors against the same code we're shimming is a tautology with negligible incremental safety. The loader becomes load-bearing the moment Phase 2 starts replacing primitives with native Quartz — at which point we can no longer trust ourselves and Wycheproof is the acceptance test that gates each primitive swap. Sequenced as Phase 2's first step rather than Phase 1's last step. WG layer (Step 2) starts immediately on Step 1.6 + UDP, both of which are green.

## Discoveries During Implementation

- **2026-04-18 — KERN.1 lands in a single session (fifteen commits).** Starting from the PVH boot skeleton (`3dc17881` prints "Hi"), the kernel went end-to-end to preemption + allocation + scheduler + serial RX + page-fault detection in one sitting. Committed sequence: `c4e53893` (x86_intrcc codegen fix — ret void + byval frame param, required by LLVM's x86_intrcc validator), `37c95240` (IDT skeleton + `breakpoint_isr`), `67b2dcf5` (#DE + iret roundtrip), `5f530add` (wrmsr/rdmsr intrinsics), `10c5c1dc` (PIC remap + PIT @100 Hz + timer_isr — preemption), `9fc06cde` (PMM bump allocator + boot paging expanded 2 MiB → 16 MiB), `a3ac92e1` (Vec<T> in kernel via real malloc/realloc backed by PMM), `026fe319` (Map<K,V> in kernel), `8cb5238e` (libc-free `qz_alloc_str` + `to_str` → string interpolation in kernel), `b139d3a9` (toy two-task cooperative scheduler), `1e7f8215` (serial RX via IRQ4 — kernel interactive), `a374961b` (#PF handler with CR2 + error code, 2-arg x86_intrcc signature proven). Two interesting discoveries along the way: (a) `x86_intrcc` functions reliably need `ret void`, NOT `ret i64 0` — any trailing `@c(...)` whose inline-asm i64 output is still live would otherwise produce the wrong terminator; the fix hoisted the void-return check above the value-vs-void branch in codegen_instr.qz. (b) BSS beyond the boot identity map silently triple-faults without any diagnostic — the 1 MiB PMM pool pushed `.bss` past 2 MiB and QEMU reset at the first load/store; fix was expanding the boot paging to 16 MiB (8 × 2 MiB huge PDEs). Future paging work: add a #PF handler EARLY so the failure mode is a legible "PF at 0x..." instead of reset-to-0xFFF0.

- **2026-04-18 — QEMU `-kernel` boot unblocked via PVH ELF note (SYS.5 RESOLVED).** Initial discovery: QEMU's `-kernel` Multiboot1 path rejects ELFCLASS64 with `Cannot load x86-64 image, give a 32bit one`. Resolution: drop the Multiboot1 header, add a PVH ELF note (`XEN_ELFNOTE_PHYS32_ENTRY`, type 0x12, owner "Xen", descriptor = 32-bit physical entry point) in a `.note.Xen` section. Co-exists with the Multiboot2 header so GRUB still boots via MB2 and QEMU `-kernel` boots via PVH. MB1 is gone — QEMU's loader tries MB1 first and rejects before reaching PVH when MB1 is present; GRUB prefers MB2 anyway. Verified end-to-end: `baremetal:qemu_boot_x86_64` builds the Quartz→ELF image and boots it under `qemu-system-x86_64 -kernel` successfully on QEMU 10.2. Kernel output (serial writes via port-I/O) is still TODO — needs long-mode transition + UART initialization, both KERN.1 work — but the language-surface and loader-mechanics layer is fully closed.

- **2026-04-18 — Fuel-check instrumentation emits unresolved `@__qz_fuel_refill` calls for freestanding targets (SYS.5).** Empirical: compiling `tools/baremetal/hello.qz` (aarch64 freestanding + `@panic_handler`) produces IR that LLC rejects with `use of undefined value '@__qz_fuel_refill'`. Root cause: `mir_emit_fuel_check` (`self-hosted/backend/mir_lower.qz:771`) instruments every loop back-edge and function-call site with an intrinsic that lowers to `call void @__qz_fuel_refill()` and loads/stores of `@__qz_sched_fuel`. Those symbols are defined by `cg_emit_runtime_decls` in `codegen_runtime.qz:796-802`, which early-returns for freestanding targets (line 295-297), so they're never emitted — but the instrumentation still references them. Fix: add a third skip case to `mir_emit_fuel_check` for freestanding targets (BEAM-style reduction counting is userspace-scheduler machinery; kernels preempt via timer interrupts, not fuel). Plumbing: set a module-level `_mir_is_freestanding` flag in `mir_lower.qz` from `do_build` when `target` is freestanding, same pattern as `_mir_alloc_arena_target`. Unblocks one specific LLC error; further libc refs (`malloc`/`free`/`memcpy`/`memset`/`qsort`/`abort`/`backtrace`/`longjmp`/`write` + runtime helpers `__qz_module_init`/`__qz_panic_jmpbuf_get`) remain in the prelude path and need the internal-linkage-prelude + dead-code-elimination pass noted in the next-up item.

- **2026-04-18 — SYS.5 infrastructure landed; hello_x86.qz is a skeleton blocked on full freestanding-link story (SYS.5).** `tools/baremetal/x86_64-multiboot.ld` + `tools/baremetal/smoke_x86.s` + `quake baremetal:verify_x86_64` now exist and pass — they prove the Quake `assemble` + `link_baremetal` primitives plumb a Multiboot2 header through correctly (header magic `0xe85250d6` little-endian, 24-byte layout, end-tag present, entry at 0x100020 past header). `tools/baremetal/hello_x86.qz` ships alongside as a Quartz skeleton mirroring `hello.qz`'s shape, but like hello.qz it does not reach an ELF today — same blockers (fuel_check instrumentation, libc-dependent prelude paths, `__qz_module_init`, `__qz_panic_jmpbuf_get`). Actually booting in QEMU is KERN.1 territory once the 32→64 long-mode trampoline is written; x86_64 Quartz port-I/O intrinsics (`outb`/`inb`) for legacy COM1 UART at 0x3F8 are not yet added (current skeleton uses MMIO via `volatile_store<U8>` at a placeholder address, consistent with hello.qz's PL011 MMIO approach). SYS.5 per the epic list is split cleanly: the infrastructure twin is done now; the full Quartz-source boot waits on the prelude-internal-linkage + fuel-check-freestanding-skip pass.

- **2026-04-17 — UFCS method alias collision on atomic RMW intrinsics (SYS.1).** When adding `.and` / `.or` / `.min` / `.max` as UFCS method aliases for the new atomic ops: `.and` and `.or` collide with lexer keywords `TOK_AND` / `TOK_OR` and can't be method names; `.min` and `.max` shadow existing Array builtins registered at `self-hosted/middle/typecheck_builtins.qz:782-783`. Only `.xor` got a method alias cleanly — the other four stay plain free-function calls (`atomic_and(ptr, val, ord)` etc.). Free-function form works for all five; no functional loss, ergonomic wart only. Affects any future intrinsic whose name overlaps a reserved keyword or a prior builtin method. Not a blocker for kernel work — atomic_and/or/min/max all work from free-function form. Fix when convenient: either rename the colliding Array builtins or teach typecheck to disambiguate by arity/signature when resolving UFCS.

- **2026-04-17 — Prelude panic path references undefined globals in freestanding targets (SYS.1).** `tools/baremetal/hello.qz` does not reach an ELF today: `llc` rejects the freestanding IR with `use of undefined value '@.newline'`. Root cause: `cg_emit_runtime_decls` (`self-hosted/backend/codegen_runtime.qz:289-297`) early-returns for freestanding targets, suppressing the declarations of `@.panic.prefix` and `@.newline`, but the auto-emitted prelude functions `unwrap` / `unwrap_ok` / `unwrap_err` unconditionally reference those globals via `cg_intrinsic_system.qz:328,353`. Even if the globals were emitted, the link would still fail: the panic path also calls `@write(i32 2, ...)`, `@strlen`, `@longjmp`, `@exit` — all libc. The real fix is SYS.1 item 6 (`@[panic_handler]` hook) plus marking prelude functions with `internal` linkage so LLVM `globaldce` can prune them when unused. Until then, freestanding Quartz source cannot link as ELF. Workaround for the SYS.1 item 2 verification task: use hand-written assembly at `tools/baremetal/smoke.s` as the link-step smoke target — it exercises the Quake linker-script plumbing without pulling in the Quartz prelude. Ship the plumbing now; unblock full-source freestanding builds with SYS.1 item 6.

## Next Step on Approval

KERN.1 is ~85% done as of `1b59f2f9`. Three pieces finish it
cleanly, in any order:

1. **Context-switching scheduler** (~80 LoC, 1 session). Upgrade the
   cooperative dispatcher to per-task state (saved RSP + stack
   page). Pre-stages KERN.2 cleanly so the `Async` handler lands
   on top of real tasks rather than retrofitting them.
2. **APIC + LAPIC timer** (~100 LoC, 1 session). Modern IRQ
   delivery. Needs a 4 KiB MMIO mapping for 0xFEE00000 (expand
   boot paging or patch the map at runtime). Retires PIC / PIT
   and sets up for SMP later.
3. **Multiboot2 memory-map consumption** (~50 LoC, 1 short
   session). Walk the start_info tag chain, resize the PMM pool
   to the actual RAM range the bootloader reports (128+ MiB under
   QEMU default vs. our fixed 1 MiB). The gate to a real PMM.

Then KERN.2 / KERN.3 / KERN.4 per the epic list. See
`docs/handoff/interactive-kernel-milestone.md` for the full
current-state snapshot.
