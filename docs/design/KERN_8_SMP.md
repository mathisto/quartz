# KERN.8 — SMP / multi-core for the Quartz unikernel

> Design memo. Decisions before code. Locks the path through K8.1–K8.9
> so subsequent sessions don't relitigate.
>
> **Status:** K8.0 (this doc) shipped 2026-05-09. Next: K8.1 ACPI MADT
> parser. Target shape: 2 vCPU SMP MVP with single global ready queue
> + spinlock; per-CPU run queues + work-stealing follow as K8.6.
>
> **Source for naming:** `docs/ROADMAP.md` KERN.8 row + DEF-E-M
> ("blocked on KERN.8") + the Soul-of-Quartz capstone (`docs/SOUL_OF_QUARTZ.md`).

## Why now

The Soul-of-Quartz demo (live at <https://joyofquartz.mattkelly.io>)
shipped SOUL.5 v4 on 2026-05-09 with `NUM_TASKS = 32 768`. Spawn 30k
busy-yielders on the public site → the page locks up briefly because
the HTTP connection-handler queues behind 30k task quanta on a single
vCPU. Tactical fix is priority queues; **architectural fix is
parallelism.** We chose the architectural fix.

This is also the gating dependency for **DEF-E-M** (true M:N, "each M
becomes a CPU core rather than a pthread") — DEF-E-M is "almost free"
once K8.6 (per-CPU ready queues) lands, and DEF-E-M itself is the
substrate that turns the Soul-of-Quartz "5M tasks" headline number
into something we actually deliver.

## Goal

A 2-vCPU MVP boot path on the unikernel, with the cooperative
scheduler running on both CPUs, such that:

1. The HTTP serve loop pinned to BSP keeps responding sub-100 ms even
   while AP runs 30k busy-yielding demo tasks.
2. The Soul page surfaces both CPUs in the dashboard (per-CPU
   heartbeat counters, per-task "running on CPU N" tag).
3. The fixpoint stays clean.
4. The path to N > 2 (auto-detect via ACPI MADT) is straight-line.

Non-goals for this MVP: per-CPU run queues + work-stealing (K8.6, but
not K8.MVP), TLB shootdown (we use one fixed identity map), hot-plug
CPU bringup (CPUs are detected once at boot), preemption (still
cooperative on each CPU; preemption is a post-K8.8 follow-on).

## Research — what the world does

These are the well-trodden paths; we synthesize the simplest correct
combination for Quartz's situation.

### xv6 (MIT teaching OS)

The clearest reference for AP bringup. Six-step pattern:

1. **Detect APs via MP table** (xv6 uses legacy MP tables; we use ACPI
   MADT, see below).
2. **Allocate per-CPU state**: each `cpu` struct has a kernel stack,
   GDT, TSS, scheduler context.
3. **Copy real-mode trampoline** to a low-memory page (typically
   0x7000), patched with the per-AP entry point + page-table root.
4. **INIT-SIPI-SIPI sequence** via LAPIC ICR: send INIT (deassert
   then assert), wait 10 ms, send SIPI with vector = trampoline page
   number, wait 200 µs, send SIPI again (Intel SDM mandates two SIPIs
   for some chipsets; OSDev wiki recommends always two).
5. **AP boots**: trampoline switches real → protected → long mode,
   loads its per-CPU GDT, jumps to the kernel's `mpenter()`.
6. **BSP polls** an `alive` flag the AP sets before idling. Move on
   once all expected APs are up.

The xv6 implementation lives in `mp.c` + `lapic.c` + `entryother.S`.

### Linux (`arch/x86/kernel/smpboot.c`)

Same INIT-SIPI-SIPI sequence, but with much more error handling and
a richer CPU hotplug story. The trampoline is `trampoline_64.S` /
`trampoline_compat.S`. Per-CPU data is GS-base addressed
(`%gs:offset`) — same approach we adopt below.

### Go runtime (M:P:G)

Different layer — Go runs M (OS threads) bound to P (logical
processors), each P with its own G (goroutine) run queue and
work-stealing on idle. We're not rebuilding Go's full model in K8.MVP
(single global run queue is enough), but **K8.6 lifts to per-CPU run
queues + steal**, which mirrors Go's P. The reductions / fairness
machinery Go has on top is post-MVP.

### BEAM (Erlang VM)

Per-scheduler reductions (each reduction = ~2000 instructions of work
before forced preemption). System processes at "max" priority bypass
normal queues. Quartz's cooperative scheduler doesn't have reductions
(yield is explicit), so this maps to "preemption is post-MVP, do
priority queues if needed" — but we explicitly chose architecture
over band-aid, so priority queues are off the table for K8.MVP.

### seL4

Per-CPU kernel objects, formally verified. Out of scope for our MVP —
but seL4's discipline of "no shared mutable kernel state" is
aspirational. K8.MVP gates shared mutable state (one ready queue,
PMM allocator) behind one spinlock each; K8.6 cuts that down further.

## Key design decisions (locked here, not relitigated later)

### D1. ACPI MADT, not legacy MP tables

QEMU `microvm` exposes ACPI tables. The MADT (Multiple APIC
Description Table, signature `APIC`) enumerates LAPIC entries (one
per logical CPU) + IOAPIC entries. We parse the MADT in K8.1.

Rejected alternative: legacy MP Configuration Table. Modern
hypervisors emit it for compatibility but ACPI is the canonical
source; OSDev wiki and every modern reference uses MADT.

### D2. Per-CPU state via GS-base segmentation

x86_64 has dedicated `IA32_KERNEL_GS_BASE` + `IA32_GS_BASE` MSRs.
Each CPU writes its own per-CPU page address into `IA32_GS_BASE` at
init; subsequent code reads `%gs:0`, `%gs:8`, etc., to access
per-CPU fields. This is what Linux / xv6 / FreeBSD all do.

Rejected alternatives:

- **CPU-id array indexed by `lapic_id()`**: requires reading the
  LAPIC ID register on every per-CPU access. Adds 5–10 ns vs. zero-cost
  segment access. xv6 does this (acceptable for teaching code, not
  for us at 32 768 task scale).
- **Per-CPU stack pointer, derived via stack alignment**: brittle if
  stacks grow / shrink, breaks the "kernel stack is just a stack"
  assumption.

### D3. Per-CPU GDT/IDT/TSS/kernel-stack; shared IDT

- **GDT**: per-CPU. Must be per-CPU because the GDT contains the TSS
  descriptor, and TSS must be per-CPU (it holds the kernel stack
  pointer for IST entries).
- **IDT**: shared. Interrupt handlers read CPU-local state via
  GS-base after entry. xv6 has per-CPU IDTs; we don't need that
  granularity yet.
- **TSS**: per-CPU. Holds RSP0 (the stack interrupts switch to) +
  IST entries.
- **Kernel stack**: per-CPU. Sized one PMM page (4 KiB) per CPU at
  K8.MVP; bumps later if needed.

### D4. Memory layout

Existing identity map covers 16 GiB (per memory note `feedback_pvh_probe_pre_uart_lazy_init.md`'s
1 GiB-page extension). All CPUs share this map — no per-CPU page
tables needed for K8.MVP.

Per-CPU pages are PMM-allocated at AP-bringup time. Layout (one page
per CPU, indexed by CPU number 0..N-1):

```
+0      U64    cpu_id            // 0 = BSP, 1+ = APs
+8      U64    lapic_id          // hardware LAPIC ID (may differ from cpu_id)
+16     U64    kernel_stack_top  // RSP for interrupt entry
+24     U64    current_task      // running goroutine ptr (or 0 for idle)
+32     U64    sched_main_rsp    // saved RSP for sched_pump return
+40     U64    heartbeat         // per-CPU goroutine heartbeat counter
+48     U64    idle_ticks        // time spent in HLT (post-K8.6 telemetry)
+56     U64    ipi_pending       // bitmap, post-K8.7
+64     reserved through +127
+128    U8[256] gdt              // per-CPU GDT (8 entries × 8 bytes = 64 bytes; pad to 256)
+384    U8[104]  tss             // per-CPU TSS (104 bytes for 64-bit TSS w/o IO bitmap)
+488    pad to 4096
```

Field offsets settle at K8.2 once the substrate exists; this is
indicative, not contract.

### D5. Spinlocks via `lock cmpxchg`

x86 has `LOCK CMPXCHG` for atomic compare-exchange. A spinlock is a
1-byte field; lock = `loop until CAS(0, 1) succeeds`; unlock = atomic
store of 0. Wrap with interrupt-disable (`cli`) on lock,
interrupt-enable (`sti`) on unlock — but only if interrupts were
enabled before lock. Save the EFLAGS.IF bit at lock time, restore at
unlock.

We add three intrinsics in K8.4:

- `atomic_load_u64(addr)` — `mov` (x86 aligned reads are atomic).
- `atomic_store_u64(addr, val)` — `mov` + memory barrier.
- `atomic_cas_u64(addr, expect, new) -> bool` — `lock cmpxchg`.

Anything more (atomic-add, fetch-or, …) added on demand. x86's TSO
memory model means most data races have weaker hazards than we'd
worry about on AArch64.

### D6. K8.MVP run queue: one global ring + one spinlock

Today we have one global `g_ready_ring`. K8.MVP keeps it global,
gates `ready_push` / `ready_pop` behind one spinlock. Trivially
correct, slow under contention, fine for the MVP.

K8.6 splits to per-CPU ready rings + work-stealing — that's where the
real parallel speedup lives. Doing it K8.MVP-time would force us to
debug SMP correctness AND scheduler-design correctness simultaneously;
worse, it'd hide bugs in either layer.

### D7. K8.MVP HTTP pinned to BSP

The HTTP serve loop is the only ring-0 driver-poll loop on the
unikernel — virtio-net RX, TCP retransmits, accept-loop, scheduler
pump, all on one main thread. Splitting that out is its own design
question (DEF-E-N1 phase 5). For K8.MVP we keep all I/O on the BSP,
spawn user goroutines that can run on any CPU. APs run a pure
scheduler loop: pop task → switch_to → on yield, pop next → repeat.

This keeps the K8.MVP scope tight: SMP scheduler, not SMP I/O. If
the SOUL.5 v4 30k-task starvation goes away (it should, because the
HTTP handler is no longer competing with 30k busy-yielders for the
single CPU), we've shipped the value.

### D8. Cooperative on each CPU; no preemption in K8.MVP

Each CPU runs `sched_pump_step()` in a loop. Tasks yield via
`yield_now()` / block via channel ops / exit via `task_exit()`. Same
as today, just N copies running in parallel.

Preemption (timer-interrupt-driven yield) is a separate epic — it
unblocks "infinite-loop goroutine doesn't lock the CPU forever" but
introduces interrupt-safe scheduler invariants. Post-K8.

### D9. Cross-CPU IPI for wake-up only (K8.7)

When CPU N has nothing in the ready queue, it `hlt`s (one instruction;
LAPIC will wake it on next timer or IPI). When CPU M pushes a task to
the (global K8.MVP / per-CPU K8.6) ready queue and a CPU is idle,
we send an IPI to wake one. Vector chosen at K8.7; handler is
trivial (just acknowledges and returns to scheduler loop).

### D10. Memory model — x86 TSO is enough for K8.MVP

x86 stores are released-on-store with one StoreLoad reorder
exception. Reads are acquired-on-load. So:

- Plain aligned U64 stores are observed in program order by other
  CPUs (modulo the StoreLoad case).
- The StoreLoad case is patched by `mfence` *only at synchronization
  points* (e.g., publishing task-table entries at AP bringup; before
  reading peer-CPU state).
- Compiler reorder is the bigger threat than CPU reorder. Quartz's
  `volatile_load` / `volatile_store` already disable compiler
  reorder for the targeted access; we add `compiler_fence()` as a
  no-op-emit barrier for non-volatile accesses near sync points.

This is the same calculus xv6 / Linux x86 / FreeBSD make. ARM /
AArch64 SMP would need acquire/release fences explicitly; x86 SMP
does not.

## Phase plan

Each phase ships independently (commit + smoke + `quake guard` if
self-hosted touched, which it isn't for K8.1–K8.MVP — kernel-only
work). Phases sized in quartz-days (÷4 calibration).

| Phase | Subject | Sized | Touches |
|---|---|---|---|
| **K8.0** | Design memo (this doc) | 0.25 q-day ✅ shipped 2026-05-09 | `docs/design/KERN_8_SMP.md` |
| **K8.1** | ACPI MADT parser → enumerate APs | 0.5 q-day | new file `tools/baremetal/acpi.qz`; `hello_x86.qz` calls into it post-`apic_init` |
| **K8.2** | Per-CPU state framework + GS-base | 0.5 q-day | `hello_x86.qz` (per-CPU page alloc + `wrmsr IA32_GS_BASE`); helpers `cpu_local_load(off)` / `cpu_local_store(off, v)` |
| **K8.3** | AP trampoline + INIT-SIPI-SIPI | 0.75 q-day → **✅ shipped 2026-05-09 (~0.4 q-day actual)** | new asm `ap_trampoline_x86.s` (240 bytes self-contained, embedded GDT); LAPIC ICR writes from `hello_x86.qz`; AP entry calls Quartz `ap_main()`; verified at -smp 2/4. Quartz DCE drops `ap_main` if its only reference is in `@c` inline asm — workaround: an `ap_main_keepalive_guard()` with a never-taken `if` branch calling `ap_main(0)` keeps the symbol alive past Quartz's call-graph analysis. Filed as a known wart for K8.4+: a real `@used`/`@noinline` attribute would be cleaner. |
| **K8.4** | Atomic intrinsics + spinlock primitive | 0.5 q-day → **✅ shipped 2026-05-09 (~0.3 q-day actual)** | three new intrinsics — `atomic_load_u64` / `atomic_store_u64` / `atomic_cas_u64` — registered in `typecheck_builtins.qz` + `intrinsic_registry.qz`, IR emit in `cg_intrinsic_memory.qz` (LLVM `load atomic` / `store atomic` / `cmpxchg` with seq_cst ordering, lowered by LLVM to `MOV` / `MOV+MFENCE` / `LOCK CMPXCHG` on x86_64). Spinlock primitive in `std/sync.qz` (`spinlock_new` / `_lock` / `_unlock` / `_try_lock` / `_is_locked`). Smoked: atomic_smoke + spinlock_smoke green on host; kernel ELF rebuild + boot at -smp 4 unchanged. Distinct from existing `atomic_*` intrinsics (Atomic\<T\> for hosted refcount); these are raw-u64-address-based for kernel/freestanding. Quake guard verified fixpoint (2149 functions byte-identical, 14M binary). Followup: K8.5 swaps the global `g_ready_ring` push/pop behind a Spinlock; K8.MVP+ revisits the K8.3 plain-RMW `g_ap_alive_count` once parallel bringup motivates atomic_inc. |
| **K8.5** | Convert ready queue to spinlocked global | 0.25 q-day → **✅ shipped 2026-05-09 (~0.15 q-day actual)** | `hello_x86.qz` `ready_push` / `ready_pop` wrapped in `spinlock_lock(g_ready_spinlock)` / `spinlock_unlock`. Spinlock primitive split into `std/sync/spinlock.qz` (separate from `std/sync.qz`) because Semaphore's channel codegen pulls in hosted-only TLS globals (`@__qz_current_frame`) that the freestanding target can't link. -smp 4 + curl smoke green: all 3 APs alive, HTTP 200, no regression on the single-CPU BSP path. |
| **K8.MVP** | sched_pump on AP; AP main loop; smoke | 0.5 q-day → **✅ shipped 2026-05-09 (~0.4 q-day actual)** | `ap_main()` now loads the shared IDT (`idt_load(get_idtr_addr())`), runs `apic_init()` to start its own LAPIC timer, then loops `sched_pump()` + `sti; hlt; cli` so it wakes on each timer tick to drain the global ready queue. The 32 BSP scheduler sites (`g_sched_current` reads/writes + `g_sched_main_rsp_slot` accesses across `yield_now` / `task_exit` / `chan_send` / `chan_recv` / `uk_mutex_lock` / `sched_pump` / `sched_pump_step` / `conn_body` / `sched_demo_body`) collapsed to three helpers: `sched_current()` = `cpu_local_load(PCPU_CURRENT_TASK)`, `set_sched_current(t)` = `cpu_local_store(PCPU_CURRENT_TASK, t)`, `pcpu_main_rsp_slot()` = `pcpu_page_for(cpu_local_load(PCPU_CPU_ID)) + PCPU_SCHED_MAIN_RSP`. Because `switch_to` only saves callee-saved GPRs + RSP and never touches `%gs`, GS-base survives every cooperative switch — each call to `pcpu_main_rsp_slot()` reads `%gs:cpu_id` at the call site, so a yield from CPU N saves into N's slot and a resume on CPU M loads from M's slot. Diagnostic trace `[sched] CPU N running task=K` lives behind `const KERN8_SCHED_TRACE` (set to 0 after smoke green; flip to 1 for any future SMP-correctness investigation). **Trampoline GDT bug found and fixed in the same commit**: AP's tramp GDT had 64-bit code at selector 0x18 while BSP's `idt_install` registers ISR entries with selector 0x08, so the first LAPIC timer fire on the AP loaded a 32-bit code descriptor and triple-faulted (`check_exception old: 0xd new 0xd → Triple fault`, RIP at the `cli` after `hlt`). Fix: reorder AP GDT to match BSP's selector layout (0x08 = 64-bit code, 0x10 = 64-bit data, 0x18 = 32-bit code [trampoline-only], 0x20 = 32-bit data [trampoline-only]) and update the four selector constants in the real → protected → long-mode jumps. Smoke matrix all-green: -smp 1 HTTP 200 in 4.2 ms (no APs); -smp 2 HTTP 200 in 4.4 ms with both CPUs scheduling tasks (50 BSP + 41 160 AP scheduler events under the noisy trace, ratio explained by BSP's serve loop calling `sched_pump_step()` once per turn vs. AP's `sched_pump()` draining); -smp 4 HTTP 200 in 4.3 ms with all 3 APs alive. CPUs 1 + 3 stayed idle in the -smp 4 run because the steady-state workload is one perpetual `uk_heartbeat_body` goroutine and only one AP wins the spinlock race for the single ready task — work distribution lands at K8.6 (per-CPU rings + steal). |
| **K8.7** | Cross-CPU IPI wake-up | 0.5 q-day → **✅ shipped 2026-05-09 (~0.3 q-day actual)** | New IPI vector `APIC_WAKE_IPI_VECTOR = 0x21` with `wake_ipi_isr` (no-op body — just `volatile_store APIC_REG_EOI 0`). The wake itself happens implicitly via `iret` returning the CPU to its `hlt` boundary in `ap_main`'s `sti; hlt; cli` loop, which proceeds into the next `sched_pump()` call. New helper `apic_broadcast_ipi(vector)` writes ICR-low with `APIC_ICR_DEST_ALL_EXCLUDING_SELF` (bits 18-19=11) + `APIC_ICR_DELIVERY_FIXED` (bits 8-10=000) + `APIC_ICR_LEVEL_ASSERT` — dest-shorthand makes ICR-high irrelevant, so a single 32-bit MMIO write triggers the broadcast (cheaper than `apic_send_init/startup`). Pre-wait via `apic_icr_wait_idle()` avoids the lost-IPI race when callers issue back-to-back broadcasts. `ready_push` now observes the 0 → 1 transition while still holding `g_ready_spinlock` (cheap — just `g_ready_count == 1` after the increment), releases the lock, and broadcasts only if `was_empty` — racing pushers on a non-empty queue are already covered by an active consumer. Wake latency drops from ~100 ms (LAPIC timer cadence, the K8.MVP failsafe) to nanoseconds. **Boot-time gating**: `ready_push` only broadcasts when `g_smp_ipi_enabled == 1`, which main flips just before the HTTP serve loop. Reason: the legacy boot demos (`sched_demo`, `chan_demo`, `mutex_demo`) and the asset/wg init paths assume cooperative-single-CPU semantics — `uk_mutex_lock` does a non-atomic load+store TOCTOU, the PMM bump allocator is unsynchronized, and chan_demo's producer/consumer rely on FIFO task ordering. With the wake fast path on, an AP wakes within nanoseconds of every push and shreds those invariants (mutex_demo dropped from `counter=2000` to `counter=210`, chan_demo output reordered, kernel hangs in `wg_init` racing on PMM). K8.6's per-CPU rings + work-stealing is the structural fix; the gate is the right minimal-scope answer for K8.7. Smoke (-smp 2): `mutex_demo: counter=2000`, `chan_demo: done`, HTTP 200 in 4.2 ms. AP-event ratio at -smp 2 with verbose trace = ~30 000 events / 3 s = ~10 000/s, vs ~10/s if timer-only — empirical confirmation IPI is the wake source, not timer. |
| **K8.8** | Telemetry: per-CPU heartbeat + Soul page | 0.25 q-day → **✅ shipped 2026-05-09 (~0.2 q-day actual)** | `sched_trace` renamed to `sched_tick`; bumps `PCPU_HEARTBEAT` (offset +40, reserved at K8.2) on every task entry via `cpu_local_load + 1 + cpu_local_store`. Each CPU writes only its own slot (via `%gs:40`), so there's no cross-CPU race on the counter itself — but a CPU stalled by the K8.7 yield/SAVED_RSP race (filed in `docs/bugs/UNIKERNEL_SMP_YIELD_RSP_RACE.md`) shows up as a heartbeat that stops advancing while siblings keep climbing — exactly the diagnostic value the telemetry should provide. `/api/soul/stats.json` extended with `"cpus":[{"id":N,"lapic":L,"heartbeat":M},...]` after the existing `tasks` object; array length = `g_cpu_count` so `-smp 1` returns one entry, `-smp 2` returns two, etc. Soul page rendering is a Soul-of-Quartz (D.11) capstone follow-up — the telemetry is shipped now so the SMP race surfaces as observable behavior on `/api/soul/stats.json` rather than mysterious "kernel feels slow" symptoms. Smoke: -smp 1 cpus=[CPU0:764445], -smp 2 cpus=[CPU0:71, CPU1:160920], -smp 4 cpus=[CPU0..3]; HTTP 200 in ~4 ms across all configs. |
| **K8.6** | Per-CPU ready queues + work-stealing | 1 q-day → **✅ shipped 2026-05-09 (~0.6 q-day actual)** | `hello_x86.qz` scheduler restructure. Seven sub-phases — K8.6.1 per-CPU ring substrate (ring + spinlock per CPU at PCPU offsets 64-104, allocated in `kern8_pcpu_init` so APs entering pre-`uk_sched_init` find valid empty rings); K8.6.2 work-stealing in `ready_pop` (round-robin from `self+1` % N) + cross-CPU IPI gating (suppress IPI broadcast on self-pushes — heartbeat-style yield-republish was generating ~hundreds of thousands of IPIs/sec, saturating BSP's serve loop) + AP main loop change (was `sched_pump` drain, became `sched_pump_step` to fix livelock; later restored to drain in K8.6.7 once load-aware push made it safe); K8.6.3 defer-publish for `yield_now` + `task_exit` (TASK_STRUCT_SIZE 64→80 with TASK_PENDING_WAITQ + TASK_PENDING_LOCK; new `sched_post_switch` runs after `switch_to` commits SAVED_RSP, completing the publish — closes UNIKERNEL_SMP_YIELD_RSP_RACE structurally for cooperative paths); K8.6.4 per-channel spinlock + park-unlock for `chan_send`/`chan_recv` (CHAN_LOCK at offset 40, header 40→48; embedded spinlock — pmm_zero_page leaves it at 0 = unlocked, no heap allocation; block paths hold lock through switch_to in Go's `gopark(unlockf, lock)` shape, sched_post_switch wait_pushes + unlocks — closes lost-wakeup hazard); K8.6.5 per-mutex spinlock + park-unlock for `uk_mutex_lock` (MTX_GUARD_LOCK at offset 24, header 24→32; same gopark pattern — closes the K8.7-noted TOCTOU on MTX_LOCKED); K8.6.6 retire `g_smp_ipi_enabled` boot-time gate (cooperative paths now SMP-safe; gate's only justification was the bugs K8.6.4+5 closed); K8.6.7 **load-aware push** (new helper `least_loaded_cpu()` with hysteresis ≥2; `ready_push` now publishes to LEAST-loaded CPU — closes the 30k-spawn imbalance where AP would steal one task and run it forever in local; with load-aware push AP's drain loop empties when AP becomes most-loaded and yields to a sibling) + AP `sched_pump` drain restoration. Smoke at -smp 2: cooperative demos (sched_demo / chan_demo / mutex_demo) all green; 30k-task spawn stress at runtime — both CPUs drain at near-equal rate (CPU0 ~1.25M heartbeat, CPU1 ~1.16M heartbeat during stress vs prev 20000:1 ratio); HTTP latency under stress 50ms (vs 159ms pre-K8.6.7, well under 100ms target); spawn-call latency 62ms. **Closes** docs/bugs/UNIKERNEL_SMP_YIELD_RSP_RACE.md. |
| **K8.9** | DEF-E-M follow-up — userland M:N exposition | 0.5 q-day → **✅ shipped 2026-05-09 (~0.3 q-day actual)** | New stdlib module `std/sync/scheduler.qz` (parallel to `std/sync/spinlock.qz`) exposes the K8.6 per-CPU SMP scheduler to user Quartz code: `scheduler_cpu_count` / `scheduler_current_cpu` / `scheduler_current_lapic_id` / `scheduler_cpu_lapic_id` / `scheduler_cpu_heartbeat` / `scheduler_cpu_ready_count` / `scheduler_total_ready`. The kernel calls `scheduler_register_pcpu_pages(g_pcpu_pages, g_cpu_count)` once at boot right after `kern8_pcpu_init`; hosted callers (qspec/tests) leave the registration unset and the API returns single-CPU stubs (returns 1 for cpu_count, 0 elsewhere). Owns the `kern8_gs_load_u64` extern decl (moved out of `hello_x86.qz`) so future `std/net/http_server` (D.11 capstone) consumes the same FFI surface as the unikernel itself. **TASK_LAST_CPU slot** added at task struct offset 49 (1-byte U8, was reserved); `sched_tick` stamps it on every task entry — gives per-task "which CPU last ran me" visibility. `/api/soul/tasks.json` drill-down rows now emit `"cpu": N`; `/api/soul/stats.json` cpus[] array now includes `"ready":N` (per-CPU ring depth) and is now plumbed through `scheduler_*` helpers (kernel dogfoods its own userland API). **SOUL.5 v5 — per-CPU lane visualization** on the soul page: one bar per CPU showing the per-CPU `sched_tick` rate (delta-since-last-poll, normalized against busiest CPU), plus the per-CPU ready depth. Drill-down table gains a CPU column. Phase-status board updated. Smoke at `-smp 2 -m 6G`: pre-stress HTTP latency 2.7 ms; spawn 30k → mid-stress 12-sample latency 78-85 ms (target < 100 ms ✅); both rings perfectly balanced at 15000/15000 mid-stress (load-aware push); post-drain back to 2.5 ms with 30041/30043 cleanup ratio (no leaks); drill-down rows correctly attribute tasks to their last-running CPU. |

**Total K8.MVP (K8.1–K8.MVP):** ~3 q-days. **Through K8.8:** ~4 q-days.
**Through K8.9 inclusive:** ~5.5 q-days = ~1 q-week.

Sequencing rationale:

- K8.1 first (ACPI parsing) because every later phase needs to know
  "how many CPUs are there?" Without MADT we'd hardcode 2; with MADT
  the MVP boots whatever QEMU provisions (`-smp 4` works without
  recompile).
- K8.2 (per-CPU framework) before K8.3 (AP bringup) because the AP
  trampoline needs a per-CPU page address to load into GS-base.
- K8.3 (bringup) before K8.4 (atomics) because we want the AP up and
  spinning in a known-empty loop *before* we change scheduler
  internals — a broken AP that's silently corrupting the ready queue
  is harder to debug than a broken AP that's just halted.
- K8.4 → K8.5 → K8.MVP is the scheduler-correctness sequence.
- K8.7 (IPI wake) before K8.8 (telemetry) because the telemetry
  itself needs to observe "AP woke from HLT".
- K8.6 (per-CPU queues + steal) AFTER K8.MVP works at -smp 2 — split
  scheduler-design problems from SMP-correctness problems.
- K8.9 closes DEF-E-M's userland surface.

## Prerequisites already in tree

✅ BSP LAPIC initialized (`apic_init` at `tools/baremetal/hello_x86.qz:491`).
✅ `wrmsr` / `rdmsr` extern intrinsics; MSR constants for APIC base.
✅ Identity map covering 16 GiB (per `feedback_pvh_probe_pre_uart_lazy_init.md`).
✅ Multiboot2 + PVH boot path; existing trampoline pattern at
`tools/baremetal/boot_trampoline_x86.s` is the structural reference
for the AP trampoline.
✅ PMM page allocator (`pmm_alloc_page` / `pmm_zero_page`).

❌ **Missing — to add along the way:**

- ACPI table walker (RSDT / XSDT → MADT). K8.1.
- `Spinlock` type + `lock` / `unlock` methods. K8.4.
- Atomic CAS / load / store intrinsics in compiler backend. K8.4.
- AP real-mode trampoline page. K8.3.
- LAPIC ICR write path (currently we only write LVT timer / spurious
  / divide / initial). K8.3 + K8.7.
- GS-base helpers + per-CPU access pattern. K8.2.
- Per-CPU GDT + TSS allocation/loading. K8.2.

## Open decisions deferred

These are real choices we don't need to make until the relevant
phase. Listing here so we don't relitigate them up-front.

1. **Per-CPU stack size.** K8.MVP uses 1 PMM page (4 KiB). Bump if a
   `pf_handler` ever needs deeper stack. xv6 uses 4 KiB; Linux uses
   16 KiB on x86_64. Resolve at K8.2 by measuring max-frame-depth
   in our own ISRs.
2. **Idle CPU strategy.** `hlt` (LAPIC interrupts wake) vs `pause`
   spin-loop. `hlt` saves real power; `pause` keeps cache lines
   warm. K8.6 default is `hlt`.
3. **Work-stealing policy** (K8.6). Random victim vs round-robin vs
   most-loaded-victim. Go uses random; Quartz can start with round-
   robin (simpler observability) and switch if benchmarks show
   contention.
4. **TLB shootdown** is not needed for K8.MVP (one identity map; we
   never modify it after boot). When we add per-process page tables
   (post-KERN.8 epic), we'll need cross-CPU TLB invalidation IPIs.
5. **NMI handling on AP**. xv6 routes NMI to a per-CPU stack via TSS
   IST. We follow when an NMI source actually exists (today: none).
6. **CPU hotplug**. QEMU supports it; we don't enumerate it. K8 ships
   "boot-time CPU set is final"; hotplug lands in a separate epic
   when there's a use case.

## Verification path

Each phase's smoke test, in order. None of these need the public VPS
to run; QEMU `-smp 2 -m 6G` locally is the test harness.

| Phase | Smoke |
|---|---|
| K8.1 | Boot serial logs CPU count + each LAPIC ID; matches `-smp N`. |
| K8.2 | `cpu_id()` returns 0 on BSP. Read+write `%gs:0` round-trips. |
| K8.3 | Boot serial logs "AP1 alive" before HTTP listener comes up. AP halts in idle loop. |
| K8.4 | Spinlock contention spec: 2 goroutines from BSP increment a counter under spinlock 1M times each; result == 2M. |
| K8.5 | sched-demo from BSP runs with same output as today. (Single-CPU regression test that the spinlock gating doesn't break the existing path.) |
| K8.MVP | Boot -smp 2; soul_demo_body spawned 4 from BSP; verify task IDs schedule on both CPUs (per-task "running on CPU N" log). |
| K8.7 | AP wake from HLT measured via per-CPU heartbeat counter resuming after BSP push. |
| K8.8 | `/api/soul/stats.json` shows `cpus: [{id:0,heartbeat:X}, {id:1,heartbeat:Y}]` both advancing. |
| K8.6 | Spawn 30k from BSP; both CPUs' ready queues drain at ~equal rate. |
| K8.9 | **✅ verified 2026-05-09.** Soul page Spawn 30k at `-smp 2`: 12-sample HTTP latency 78–85 ms (well under the 100 ms target); rings balance at 15000/15000 mid-stress; 30041/30043 cleanup ratio post-drain; drill-down `cpu` field present and correctly partitioned across CPU 0 and CPU 1. |

## What this unblocks downstream

- **DEF-E-M** (true M:N) ships almost-for-free after K8.6.
- **SOUL.5 v5+** ("Spawn N across M CPUs", per-CPU spawn batches).
- **SOUL.6** structured-concurrency micro-demos that show *real*
  parallelism (race-N, supervisor restart on a different core).
- **D.11 capstone** dogfood — `std/net/http_server.qz` migration to
  the new APIs naturally absorbs SMP awareness.
- **`burn one CPU` demo** — a goroutine pinned to one CPU
  busy-yielding, with the other CPU staying responsive — visible
  proof of parallel scheduling on the dashboard.
- **The 5M-tasks headline number** — the Soul-of-Quartz capstone
  stops being aspirational at NUM_TASKS = 32 768 / single-CPU
  starvation and becomes deliverable at NUM_TASKS = 5 000 000 spread
  across N cores.

## Cross-session handoff protocol

Anyone (human or Claude) picking this up mid-roadmap:

1. **`TaskList`** to see where K8.X lives. Each phase gets one task.
2. **This doc is the design source of truth.** Update it (in place,
   no secondary handoff) when a deferred decision gets made.
3. Phase commits tagged `[kern8]` so they're findable later. Format:
   `[kern8] K8.N v0 — <subject>`.
4. **`quake guard` is mandatory** for K8.4 (compiler intrinsics) and
   any phase that touches `self-hosted/*.qz`. K8.1–K8.3 are
   kernel-source-only; ELF rebuild via `quake baremetal:build_elf` is
   sufficient.
5. **Fix-specific golden binary** (per `quake guard` rules) before
   K8.4 — the atomic-intrinsic work is exactly the kind of thing
   that can produce a self-consistent broken compiler if codegen
   subtly mis-orders.
6. **Local-only testing through K8.8.** Don't push K8.x to the public
   VPS until K8.MVP smoke is green. The public site stays on SOUL.5 v4
   (single-CPU) until we have confidence; the public push is part of
   K8.9 once everything works.

## References (verify against canonical sources before coding)

- **OSDev wiki — Symmetric Multiprocessing**:
  the standard reference for INIT-SIPI-SIPI sequence, ACPI MADT
  parsing, and the gotchas we'll hit. Read this before K8.1 + K8.3.
- **Intel SDM Vol. 3 chapters 8 (multiprocessor) + 10 (APIC)**:
  authoritative on LAPIC register layout, ICR semantics, and the
  STARTUP IPI vector format. The OSDev wiki is the friendly version;
  SDM is the spec.
- **xv6 source** (`mp.c`, `lapic.c`, `entryother.S`): smallest
  educational reference implementation. ~150 lines of real code.
- **ACPI specification §5.2.12 (MADT)**: for K8.1 parsing format.
- **Linux `arch/x86/kernel/smpboot.c`**: production-grade reference;
  consult for error-handling patterns we'll skip in K8.MVP.

## Memory model recap (one-page primer)

x86_64 is total-store-order (TSO) for normal loads/stores:

- Stores are observed in program order by other CPUs.
- Loads cannot be reordered with other loads (load-load order).
- Stores cannot be reordered with other stores (store-store order).
- A *later* load *can* be observed before an *earlier* store
  completes — this is the StoreLoad reorder hole. Patched by `mfence`
  or any `LOCK`-prefixed instruction between the store and the load.

Practical implication for K8: most of our SMP code does not need
explicit fences. We need `mfence` (or use `lock cmpxchg` on whatever
flag is the synchronization point) at:

- AP bringup: BSP publishes per-CPU init data; AP reads it. The SIPI
  itself is a serializing event, so this is implicit.
- Idle wakeup: BSP pushes to ready queue, then sends IPI. The IPI
  send is `mov` to LAPIC ICR (uncached MMIO; serializes naturally).
- Spinlock release-acquire: `lock cmpxchg` for acquire (full barrier);
  plain `mov` for release (TSO covers it).

Compiler reorder is the bigger threat than CPU reorder. Use
`volatile_load` / `volatile_store` for any cross-CPU communicating
field (we already do this for the per-task fields). Add
`compiler_fence()` (no-op emit, but tells LLVM not to reorder) for
non-volatile accesses near publication points. K8.4 introduces this.
