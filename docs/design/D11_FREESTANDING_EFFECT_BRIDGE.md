# D.11 Phase 7 — Freestanding-Kernel Effect Bridge

> **Status**: Phase B.0 design memo. Written 2026-05-24 immediately after
> D.11 userland (Phases 0–6) shipped. The userland migration is complete
> and production-ready (h1.1 + h2, supervised goroutines, graceful
> shutdown, ALPN dispatch). The bridge sub-epic (B.1–B.6) is what lets
> the **unikernel** consume the migrated `std/net/http_server` and the
> kernel-side SOUL.6 demos swap from mocked primitives to the real
> `scope_with_deadline` / unified `select` / `Supervisor.start_child`
> language-level surface.
>
> **Why this exists**: Freestanding-target codegen
> (`self-hosted/backend/codegen_runtime.qz:2729+`) currently emits no-op
> stubs for the effect-handler runtime. `with E {...}` blocks compile
> and link, but the install/uninstall is a `ret void`, `__qz_effect_perform`
> is a `ret i64 0`, `setjmp` returns 0, `longjmp` is `unreachable`, and
> `__qz_effect_suspend` returns `POLL_READY` unconditionally. So `throw`
> from kernel code is UB and `await`/`select`/scope cancellation degrade
> to no-ops. SOUL.6 ships on hand-rolled kernel-level primitives
> (`g_demo_cascade_gen`, `g_demo_deadline_target_ns`, generation-counter
> polling) because the language-level surface doesn't work in the kernel
> *yet*. The bridge makes it work.

## Status of B.0 (this doc)

✅ Lands as `docs/design/D11_FREESTANDING_EFFECT_BRIDGE.md`. Defines the
shape; B.1–B.6 implement against it.

## Problem

```
                  Hosted (today)                  │  Freestanding (today)
─────────────────────────────────────────────────┼────────────────────────────────────
@__qz_effect_handle_install    push (name, h, jb)│  ret void
@__qz_effect_handle_uninstall  pop, decrement top│  ret void
@__qz_effect_perform           scan stack, kind 0│  ret i64 0
                               1/2/3 dispatch    │
@__qz_effect_suspend           sched_park sentinel│ ret i64 1  (POLL_READY)
@__qz_gen_stash / take         TLS slot R/W      │  ret void / ret i64 0
@setjmp / @longjmp             declare libc      │  ret i32 0 / unreachable
@__qz_current_scope_handle     TLS i64 0 (lazy)  │  not declared at all
@__qz_scoped_ctx_*             TLS push/pop arr  │  empty no-op stubs
```

The freestanding stubs were written to make freestanding IR *link* — not
to make any of the language's structured-concurrency features actually
*run*. They were a deliberate placeholder, called out in the comment at
`codegen_runtime.qz:2740-2773`:

> *"No-op stubs are sufficient because `@__qz_effect_perform` (also
> stubbed) is never called at runtime in kernel builds — the inline
> body-wrap bookkeeping with `@__qz_effect_stack_top` /
> `__qz_effect_stack_results` / `__qz_alloc_in_handler` then just exercises
> zero-initialized slots (correct fallthrough for a no-handler-installed
> program)."*

This was correct for "kernel code that doesn't drive `with`" — which is
the kernel today (zero occurrences of `throw` or `with` in
`tools/baremetal/hello_x86.qz` per `grep -cE '^[[:space:]]*throw\b'`).
SOUL.6 demonstrates concurrency *shapes* using hand-rolled flags; the
demos work because they bypass the effect runtime entirely.

But the userland Phase 2c `http_serve_supervised` we just shipped uses:

- `scope_with_cancel(current_scope())` — root scope with manual cancel
- `with TcpListenerGuard do l -> body end` — Scoped resource
- `select { case _ = tcp_acceptable(l) => …; case _ = signalable(15) => … }` — unified select with a SIGTERM `Selectable`
- `dynamic_supervisor_*` — restart-policy supervisor over per-connection goroutines
- `with Throws { throw: handler } do -> body end` — process-wide unwind capture
- `http_dynamic_goroutine_sup` — `sched_wake_interrupts_sleep` for sub-ms cancel

For the unikernel to USE this code (Phase 8), all six of those primitives
need to work end-to-end in the freestanding target. That's what the
bridge ships.

## Goal

```qz
# What SOUL.6 demo bodies become after Phase 8:

def soul_demo_deadline_body(): Void
  scope_check(current_scope())      # throws if cancelled — caught by parent's `with Throws`
  scope_sleep_ms(SOUL_DEMO_LIFETIME_NS / 1_000_000)
  task_exit()
end

def soul_demo_cascade_body(): Void
  select
    case _ = cancellable(current_scope()) =>
      return
    case _ = deadline_ms(SOUL_DEMO_LIFETIME_NS / 1_000_000) =>
      return
  end
end

def soul_demo_restart_body(supervisor: Int): Void
  dynamic_supervisor_spawn(supervisor, -> {
    # child body — may throw; supervisor catches + restarts
    ...
  })
end
```

And:

```qz
# What tools/baremetal/hello_x86.qz becomes after Phase 8:

def kernel_main(): Void
  uk_sched_init()
  scope_with(scope_root(), -> {
    var root = scope_with_cancel(current_scope())
    scope_with(root, -> {
      http_serve(80) do |route| ->
        route.get("/", build_soul_landing)
        route.get("/api/soul/stats.json", build_soul_stats)
        # ... ~700 LoC of hand-rolled http_route / tcp_* / http_build_*
        #     plumbing deletes in favor of one route table.
      end
    })
  })
end
```

The hand-rolled HTTP plumbing (~700 LoC) in `hello_x86.qz` collapses; the
SOUL.6 demos swap one-line; the http server demo and the structured-
concurrency demos all run on the same primitives the public page is
explaining.

## Prior-art compass

Per D2: what does the world already know about effect-handler / coroutine
runtimes on freestanding targets?

### Embassy (Rust, async on no_std)

Embassy is the closest analogue to our shape. Tokio-style `async fn` on
Cortex-M / Cortex-A / RP2040 / nRF / STM32 / ESP32 — no_std, no_alloc
(or `alloc` optional), no setjmp. Architecture:

```
embassy_executor::Executor::run(spawner -> {
    spawner.spawn(my_task());
})
```

`Executor` owns a fixed pool of `TaskRef` (per-pool static storage; no
heap), polls via a Waker chain, parks the CPU with `WFI` (wait-for-
interrupt) when the run-queue drains. Async functions are state machines
generated by the compiler; suspension points are state-machine yields,
not stack switches. So no setjmp/longjmp — the state machine carries
the continuation.

What Embassy gets right that's directly relevant:
- Per-task storage is statically partitioned at boot. No dynamic alloc
  for the run-queue itself.
- WFI on idle — the executor parks the *CPU*, not just the task, when
  there's nothing ready.
- Interrupt handlers re-arm Wakers; the executor re-polls the woken
  tasks on the next outer-loop iteration.

What's *different* from Quartz: Embassy uses generator-style `async fn`
state machines (Rust's stackless coroutines). Quartz goroutines have
real stacks — 8 KiB each, allocated from the PMM bump. So our bridge
needs setjmp/longjmp for unwind across those stack frames; Embassy
doesn't because there are no frames to unwind across.

### Tock OS (Rust, no_std kernel)

Tock is a Rust-based embedded OS using grant regions for per-task state.
No async runtime in the kernel — uses synchronous callbacks. Not a
direct analogue, but useful for the per-task storage shape: Tock's
`grant<T>` lazily allocates `T` per process, indexed by process ID,
zero-cost when unused. Our per-task effect stack is the same idea —
declared in `Task` struct, zero-initialized at task_alloc, only the
inner workings touch it.

### seL4 (capability-based microkernel, C)

seL4 has no concept of effects or async — every blocking primitive is a
synchronous IPC call across capabilities. Not relevant for the bridge
shape, but relevant for the *boundary*: seL4 separates userspace from
kernel by capability passing. Our boundary is the freestanding-vs-hosted
codegen branch — both kernel and userspace are written in Quartz, and
the only thing that switches is which @__qz_* runtime functions get
emitted.

### Theseus (Rust, single-address-space + no setjmp)

Theseus avoids setjmp/longjmp entirely by structuring all task termination
through `Result`-typed return values: every task body returns
`Result<(), TaskError>` and a fault is caught by the task harness, not
by unwind. This is conceptually elegant — but Quartz's `throw` is already
in tree as a runtime feature, and `Result<T, E>` is the value-level
mechanism alongside it (per the "two error-handling mechanisms" project
delta in CLAUDE.md). We can't drop `throw` for the kernel; the bridge
must support it.

### Erlang/OTP (BEAM emulator, ships its own)

BEAM is a full VM with green-thread scheduling, `try/catch` via internal
state, message-passing as the only inter-process channel. Not relevant
because BEAM is the *whole emulator*; we're building a runtime *inside*
a freestanding compile target.

But the BEAM analogy *is* relevant for the SOUL.6 vs SOUL.7 framing:
the Soul page pitches "compiler in Quartz, unikernel in Quartz, HTTP
server in Quartz, crypto in Quartz, scheduler in Quartz" — same closed
loop BEAM ships, except BEAM ships an interpreter and Quartz ships
native code. After Phase 8 the loop closes: the demos on the page use
the *same* primitives the page is describing.

### Synthesis — what Quartz takes

| Source | What Quartz adopts |
|---|---|
| **Embassy** | Per-task storage statically partitioned at boot (Task struct grows; no `kmalloc` per `with`-block). Idle = `hlt` (our equivalent of WFI), interrupt-driven wake. |
| **Tock grants** | Per-task effect stack indexed by task pointer; lazily zero-initialized; zero overhead when unused. |
| **Theseus return-paths** | `throw` from a goroutine body unwinds to that goroutine's `__qz_sched_worker`-equivalent frame, not across goroutines — bridge-side `setjmp` saves at goroutine entry, `longjmp` to that buf returns the task to BLOCKED→DEAD with reason recorded. |
| **Newlib/picolibc** | Hand-rolled `setjmp`/`longjmp` in `libc_stubs.c` — x86_64 inline asm (~20 lines). |

### Where Quartz can go further

- **Same scope tree across hosted and freestanding.** A `scope_with_cancel(s)`
  call in `std/net/http_server.qz` works *identically* whether the binary
  is `tools/prod_server` (hosted, Linux/macOS) or the unikernel
  (freestanding, x86_64-none-elf). The `@__qz_current_scope_handle`
  symbol is a `thread_local global` in hosted (one copy per pthread);
  in freestanding it's a process-global whose value is save/restored
  to/from a per-task Task slot at every context switch. User IR is
  byte-identical between targets.

- **Goroutine == BEAM process == Quartz task.** One uniform abstraction.
  Userland kqueue/epoll goroutines + kernel-substrate goroutines share
  the same `Task` struct, the same `go_fn(entry)` spawn, the same
  `yield_now` / `task_exit`. Effects + scope + supervisor inherit
  through the same machinery.

- **No special "RTOS mode" for the kernel.** The language doesn't
  branch between "userland mode" and "kernel mode" the way Rust splits
  std vs core. There's one `Scope`, one `Supervisor`, one `select`,
  one `with`. The bridge is *implementation*, not *interface*.

## Architecture (target shape)

```
                            tools/baremetal/hello_x86.qz
                                       │
                                       │   scope_with(s, body) / with Throws {…} / select / Supervisor.start_child
                                       │
                                       ▼
                            std/sync/composition/scope.qz   (unchanged)
                            std/sync/composition/select.qz  (unchanged)
                            std/actor.qz                    (unchanged)
                            std/net/http_server.qz          (unchanged — what we just shipped)
                                       │
                                       │   @__qz_effect_handle_install
                                       │   @__qz_effect_perform
                                       │   @__qz_effect_suspend
                                       │   @setjmp / @longjmp
                                       │   @__qz_current_scope_handle (load/store)
                                       ▼
                            ┌────────────────────────────────────────────────┐
                            │  FREESTANDING EFFECT RUNTIME                   │
                            │  (cg_emit_freestanding_runtime)                │
                            │                                                │
                            │  Globals                                       │
                            │  ━━━━━━━                                       │
                            │  Scalars (process-global; values save/restored │
                            │   on switch via Task slots):                   │
                            │     @__qz_effect_stack_top       (i64)         │
                            │     @__qz_current_scope_handle   (i64)         │
                            │     @__qz_scoped_ctx_top         (i64)         │
                            │     @__qz_alloc_in_handler       (i64)         │
                            │                                                │
                            │  Array bases (process-global; pointer values   │
                            │   save/restored on switch; runtime functions   │
                            │   deref once at entry):                        │
                            │     @__qz_effect_stack_names     (ptr)         │
                            │     @__qz_effect_stack_handlers  (ptr)         │
                            │     @__qz_effect_stack_bufs      (ptr)         │
                            │     @__qz_effect_stack_op_filters (ptr)        │
                            │     @__qz_effect_stack_results   (ptr)         │
                            │     @__qz_effect_stack_state_slots (ptr)       │
                            │     @__qz_effect_stack_resumed   (ptr)         │
                            │                                                │
                            │  Per-task Task struct slots (saved)            │
                            │  ━━━━━━━━━━━━━━━━━━━━━━━━━                     │
                            │   80   TASK_EFFECT_STACK_TOP      (i64)        │
                            │   88   TASK_EFFECT_STACK_NAMES    (ptr)        │
                            │   96   TASK_EFFECT_STACK_HANDLERS (ptr)        │
                            │  104   TASK_EFFECT_STACK_BUFS     (ptr)        │
                            │  112   TASK_EFFECT_STACK_FILTERS  (ptr)        │
                            │  120   TASK_EFFECT_STACK_RESULTS  (ptr)        │
                            │  128   TASK_EFFECT_STACK_STATES   (ptr)        │
                            │  136   TASK_EFFECT_STACK_RESUMED  (ptr)        │
                            │  144   TASK_CURRENT_SCOPE         (i64)        │
                            │  152   TASK_SCOPED_CTX_TOP        (i64)        │
                            │  160   TASK_ALLOC_IN_HANDLER      (i64)        │
                            │  168   TASK_EFFECT_SNAPSHOT       (i64)        │
                            │   (sized to 192 → 3 cache lines.)              │
                            │                                                │
                            │  Per-task storage strip                        │
                            │  ━━━━━━━━━━━━━━━━━━━━━━                        │
                            │   7 arrays × 256 × 8 B = 14 KiB                │
                            │     ⇒ 4 PMM pages (16 KiB) per active task     │
                            │   Lazy-allocated from g_effect_stack_pool      │
                            │   on first install; freed back on task_free    │
                            │                                                │
                            │  Save/restore at switch boundary               │
                            │  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                │
                            │   yield_now / sched_post_switch each:          │
                            │     4 scalar globals → 4 task slots            │
                            │     7 ptr globals → 7 task slots               │
                            │     11 LD + 11 ST per switch (~32 cycles)      │
                            │                                                │
                            │  setjmp/longjmp                                │
                            │  ━━━━━━━━━━━━━━━━                              │
                            │  libc_stubs.c inline asm  (B.2)                │
                            │     ~20 lines x86_64                           │
                            │                                                │
                            │  Suspend/Resume                                │
                            │  ━━━━━━━━━━━━━━━━                              │
                            │  __qz_effect_suspend()  (B.4)                  │
                            │     → set TASK_STATE_BLOCKED                   │
                            │     → wait_push on appropriate waitq           │
                            │     → switch_to(main)                          │
                            │  __qz_sched_wake(t)  (B.4)                     │
                            │     → ready_push(t)                            │
                            │                                                │
                            │  Selectable impls                              │
                            │  ━━━━━━━━━━━━━━━━━━                            │
                            │  recvable / sendable / cancellable             │
                            │  deadline_ms / awaitable                       │
                            │  signalable (no-op in kernel)                  │
                            │  TcpAcceptable (after B.6)                     │
                            └────────────────────────────────────────────────┘
                                       │
                                       ▼
                            Kernel substrate (already in tree)
                            ──────────────────────────────────
                            tools/baremetal/hello_x86.qz
                              uk_sched_init / go_fn / yield_now / task_exit
                              wait_push / wait_pop / wake_one_locked
                              spinlock_new / lock / unlock
                              per-CPU page via kern8_gs_load/store_u64
                              pmm_alloc_page / pmm_zero_page
                              uk_time_mono_ns (TSC-derived)
                            libc_stubs.c
                              malloc / free / realloc (slab + bump)
                              memcpy / memset
                              kern8_gs_load_u64 / store_u64
                              setjmp / longjmp                       ← B.2 ADDS
```

### Why per-task allocation, not per-CPU TLS

The hosted runtime puts the effect stack arrays in `thread_local global`
TLS (`linkonce_odr thread_local global [256 x i64]`). Each pthread worker
has its own copy; effects installed on one thread can't leak to another.
That's the right model when threads are the unit of concurrency.

In the unikernel, threads-as-pthreads don't exist. Per-CPU storage via
GS-base does exist (used by the scheduler for ready rings, current task,
heartbeat) — but each CPU runs *many* tasks (in fact one CPU multiplexes
the entire 32K-task pool when SMP is off). Putting the effect stack
per-CPU would mean every yield must save+restore the entire effect stack
(~16 KiB of arrays) for state to survive context switch. That's
prohibitive.

### Access strategy — corrected after audit (2026-05-24)

The initial sketch had the compiler emit *every* effect-stack access
through `__qz_current_task() + TASK_EFFECT_STACK_NAMES gep`. After
auditing user-IR emit sites (`grep` across
`self-hosted/backend/cg_intrinsic_*.qz` + `codegen_instr.qz`) the picture
is more nuanced:

| Symbol | User-IR direct emit sites |
|---|---|
| `@__qz_current_scope_handle` | 3 — `cg_intrinsic_conc_sched.qz:739/1954/1964` (current_scope load + scope_with set/restore) |
| `@__qz_effect_stack_top` | 2 — `cg_intrinsic_system.qz:382` (panic-vs-longjmp decide), `codegen_instr.qz:2178` (with-block top read) |
| `@__qz_alloc_in_handler` | 4 — `codegen_instr.qz:2023/2024/2046` + `2335/2372` (alloc-bypass save/restore around with-blocks) |
| `@__qz_scoped_ctx_top` | 1+ (mir_lower.qz:1960) |
| `@__qz_effect_stack_names` / `handlers` / `bufs` / `op_filters` / `results` / `state_slots` / `resumed` | **zero** — all accesses live inside `__qz_effect_*` runtime function bodies |

So the freestanding strategy splits cleanly:

**Scalar globals (`top`, `current_scope`, `scoped_ctx_top`, `alloc_in_handler`)**
— stay as process-global symbols in freestanding (same as today's stub
emit). The scheduler **save/restores VALUES** to/from per-task Task slots
on every context switch. Cost: ~4 load + 4 store per `switch_to` boundary
(yield_now / sched_pump_step / sched_post_switch). User-IR emit at the
9 access sites is **unchanged** — the freestanding-vs-hosted difference
is purely in *backing storage organization*, not in *how user code accesses
the symbols*.

**Array globals (`names`/`handlers`/`bufs`/`op_filters`/`results`/
`state_slots`/`resumed`)** — change emit from `[256 x i64] zeroinitializer`
to `ptr null`. Each runtime function dereferences once at function entry
(`%base = load ptr, ptr @__qz_effect_stack_names, align 8`) and then GEPs
through `%base` instead of through the global symbol. Per-task strip
(16 KiB) backs the pointer; scheduler swaps the *pointer values* on
context switch (7 ptr LD/ST per switch — same cycle cost as save/restore
in option A). The `cg_emit_effect_runtime` refactor noted as a B.1 risk
in the original memo IS necessary: the runtime function bodies emit
differently in the two backing-storage modes (`gep [256 × i64] @sym` vs
`gep i64 %base`). Parameterize the helper over an "access strategy" enum;
hosted gets the TLS-array strategy, freestanding gets the
ptr-deref strategy.

### Why save/restore VALUES on switch, not GEP-through-current-task at every site

Originally I proposed compiler-side rewriting of every emit site to GEP
through `__qz_current_task()`. The actual emit sites are concentrated
(9 scalar + ~20 inside runtime functions) and uniform in shape, so the
save/restore-on-switch approach has the same correctness but better
properties:

1. **Less codegen churn.** Save/restore lives in 3 kernel-side Quartz
   functions (`yield_now`, `sched_post_switch`, `go_fn` resume prologue).
   The compiler is unchanged in scalar emit; only the freestanding
   runtime-function emit branches.
2. **Hosted-freestanding parity preserved.** User IR is byte-identical
   between targets for scope_with/with-block emit. Hosted target keeps
   using TLS; freestanding target keeps using globals — the abstraction
   above the storage is uniform.
3. **The few non-runtime-function direct user-IR accesses
   (`@__qz_current_scope_handle` etc.) need ZERO rewriting** — they read
   the same global, whose value at the moment of read is "this task's
   current value" because we restored it on resume.

Cost is small: ~8 LD/ST in yield_now + ~8 LD/ST in sched_post_switch =
~32 cycles per context switch on a 1 GHz CPU. At ~10 K context switches
/ second under the SOUL.5 v5 workload, that's ~0.32 ms/sec scheduler
overhead — negligible against the existing switch_to cost
(~50–100 cycles register save/restore + jmp).

### Goroutine spawn / first-task semantics

When a fresh task is allocated via `task_alloc()`, all 4 scalar slots
zero-init and all 7 array-base pointer slots zero-init. First call to
`@__qz_effect_handle_install` on that task triggers a `pmm_alloc_page`-
backed 16 KiB strip allocation via the dedicated effect-stack pool
(intrusive freelist; freed strips reused first). Subsequent installs
on that task reuse the strip.

`task_free()` returns the strip to the pool's freelist. PMM bump never
reclaims, so multi-page strips are pinned to the pool's lifetime budget
(bounded by max concurrent tasks-with-installed-effects).

### Memory budget at NUM_TASKS = 32768

**Task struct**: 192 B per task × 32 768 = 6 MiB (was 80 B × 32 768 =
2.5 MiB; +3.5 MiB total).

**Per-task strip** (lazy, only allocated on first install):
7 arrays × 256 slots × 8 B = 14 KiB ⇒ 4 pages = 16 KiB per task.

Total strip at worst case: 32 768 × 16 KiB = 512 MiB.

That's prohibitive for the 6 GiB VPS budget after subtracting the existing
PMM consumers (256 MiB stacks + 2 MiB pool + 256 KiB ring + …). Two
mitigations:

**Mitigation A (B.1): lazy allocate.** `task_alloc()` zeros only the
*scalar* slots (TOP, BASE, SCOPE, CTX_TOP, CTX_BASE — 40 B); the array
pages are not allocated until the first `__qz_effect_handle_install` on
that task. `task_free()` frees them. SOUL.6 demo bodies that never
install a handler pay zero. Userland goroutines that install ~4 handlers
deep (Throws + Log + Async + scope) pay ~4 active entries' worth of one
shared 16 KiB pool — but the *arrays* are sized 256 because the install
overflow-skip path at cap=256 is the same defensive ceiling as hosted.

**Mitigation B (B.1): shared pool.** All tasks share a single 16 KiB
"effect stack page" each, allocated lazily from a separate `pmm_alloc_page`
strip — not via the slab/bump dispatcher (the 16 KiB doesn't fit any
slab class, would route to multi-page bump, which never reclaims; a
separate ring keeps lifetimes bounded by task lifetime).

Both stack lazily — the path is "first install on this task" → "allocate
my 4 pages from the dedicated effect-stack pool". `task_free` returns
the page-strip to the pool's freelist (pool is intrusive; freed strips
are reused before fresh `pmm_alloc_page`).

Worst case at 32 768 tasks all installing effects simultaneously: 512 MiB.
SOUL.6 demo bodies install zero: 0 MiB. Userland-style supervised
goroutines with ~4 effects on the stack: same 512 MiB because the array
*size* is 256 regardless of *occupancy*. The cap=256 ceiling matches
the hosted invariant in `codegen_runtime.qz:317` ("256 7× headroom over
self-compile max"). For Phase 8's SOUL deployment with 5M concurrent
goroutines, this gets revisited — see Risks.

### Goroutine boundary for the effect stack

Hosted: spawn-time snapshot (`__qz_effect_snapshot_capture/apply`) copies
parent's user-installed entries onto the worker's blessed defaults at
$poll dispatch. See `codegen_runtime.qz:362-499`.

Freestanding: same shape, simpler implementation. `go_fn(entry)` captures
the parent's effect stack into a snapshot buffer (heap), stores the
pointer in `task.SNAPSHOT` (new slot). The seeded stack-init for the
goroutine prepends a "snapshot apply" prologue that copies the snapshot
into the new task's effect stack before running `entry_fn`. On
`task_exit`, the snapshot is freed.

Cross-thread `longjmp` is UB in hosted (snapshot stores `buf=0` for
inherited entries); freestanding preserves this rule. A goroutine that
inherits a parent's `Throws` handler and throws will degrade to the
*default* throws-handler in the new task (typically `__qz_panic` →
panic message + halt), not unwind to the parent's frame.

## Phase plan (B.1–B.6)

Sequenced for ship-as-we-go. Each phase is independently committable +
smoke-verifiable. Estimates per project D9 calibration.

### B.1 — Per-task effect stack via save/restore + per-task strip

~1 quartz-day. Split into two commits for reviewability:

**B.1.a — Kernel-side Task struct + save/restore + strip pool**
(`tools/baremetal/hello_x86.qz` only; no compiler-source touch):

```qz
const TASK_STRUCT_SIZE                = 192   # 80 → 192 (3 cache lines)
const TASK_EFFECT_STACK_TOP           = 80    # i64: saved value of @__qz_effect_stack_top
const TASK_EFFECT_STACK_NAMES         = 88    # ptr: saved value of @__qz_effect_stack_names
const TASK_EFFECT_STACK_HANDLERS      = 96    # ptr
const TASK_EFFECT_STACK_BUFS          = 104   # ptr
const TASK_EFFECT_STACK_OP_FILTERS    = 112   # ptr
const TASK_EFFECT_STACK_RESULTS       = 120   # ptr
const TASK_EFFECT_STACK_STATE_SLOTS   = 128   # ptr
const TASK_EFFECT_STACK_RESUMED       = 136   # ptr
const TASK_CURRENT_SCOPE              = 144   # i64: saved value of @__qz_current_scope_handle
const TASK_SCOPED_CTX_TOP             = 152   # i64
const TASK_ALLOC_IN_HANDLER           = 160   # i64
const TASK_EFFECT_SNAPSHOT            = 168   # i64 (B.x — spawn-snapshot inheritance, not B.1)
# 176..191: reserved (padding to 192 = 3 × 64 B cache lines)
```

Add `g_effect_stack_pool` — intrusive freelist of 16 KiB strips (4 PMM
pages each). Initialized lazily on first install; pre-warm 256 strips
at `uk_sched_init` to avoid PMM hits during demo bursts.

New functions:
- `def task_effect_strip_alloc(t: Int): Int` — returns existing strip
  ptr if `task.TASK_EFFECT_STACK_NAMES != 0`, otherwise pulls 4
  contiguous pages from `g_effect_stack_pool` (or `pmm_alloc_page` ×4
  fallback), writes the 7 base pointers into the task's slots, returns
  the names base.
- `def task_effect_strip_free(t: Int): Void` — if `task.TASK_EFFECT_STACK_NAMES != 0`,
  push it back to `g_effect_stack_pool`'s freelist; zero the 7 base
  slots in the task.
- Modify `task_alloc` to zero the 11 new slots (TOP through ALLOC_IN_HANDLER).
- Modify `task_free` to call `task_effect_strip_free` first.
- Modify `yield_now` to save the 4 scalar globals + 7 ptr globals to
  current task's slots BEFORE `switch_to`.
- Modify `sched_post_switch` (or `sched_pump`/`sched_pump_step`) to load
  the 11 saved values from the resuming task's slots into the globals
  AFTER `switch_to` returns and BEFORE running task-side code.

The 4 scalar globals + 7 ptr globals are declared by the freestanding
codegen path (B.1.b). For B.1.a we forward-declare them in the kernel
Quartz as `extern var` (or use `volatile_load<U64>` against linker-
resolved symbol names) so the kernel-side save/restore code compiles
against the right symbol names.

**B.1.b — Codegen refactor + freestanding install/uninstall**
(`self-hosted/backend/codegen_runtime.qz`):

1. Refactor `cg_emit_effect_runtime` to a `cg_emit_effect_runtime_inner`
   parameterized by an access-strategy enum (`STRATEGY_TLS_ARRAY` for
   hosted, `STRATEGY_PTR_DEREF` for freestanding). The hosted path
   calls `_inner(STRATEGY_TLS_ARRAY)` from the existing call site;
   freestanding calls `_inner(STRATEGY_PTR_DEREF)` from a new call
   site replacing the no-op stubs. The two strategies differ only in
   how array base addresses are obtained:
   - TLS_ARRAY: `getelementptr inbounds [256 x i64], ptr @sym, i64 0, i64 %top`
   - PTR_DEREF: `%base = load ptr, ptr @sym, align 8` once at function
     entry; subsequent `getelementptr i64, ptr %base, i64 %top`
2. Freestanding emit of the 7 array-base globals as `ptr null`
   (replacing the current `[256 x i64] zeroinit` of `__qz_effect_stack_results`
   and the missing-from-stub others).
3. Freestanding emit of the 4 scalar globals as `i64 0` (already done
   for top, alloc_in_handler, current_scope_handle; add scoped_ctx_top).
4. Replace freestanding `@__qz_effect_handle_install` /
   `@__qz_effect_handle_uninstall` stubs with bodies emitted from
   `_inner(STRATEGY_PTR_DEREF)`.
5. Other runtime functions stay as stubs through B.1
   (`__qz_effect_perform` becomes real in B.3,
   `__qz_effect_suspend` in B.4).

**Deliverables**:
- `tools/baremetal/hello_x86.qz` — B.1.a (kernel-side Task slots,
  pool, save/restore wiring)
- `self-hosted/backend/codegen_runtime.qz` — B.1.b (codegen refactor +
  freestanding install/uninstall real)
- `spec/qz/freestanding_effect_install_smoke.qz` — install Throws +
  Log on a kernel-style main, verify `volatile_load<U64>` of
  `@__qz_effect_stack_top` reads 2 after both installs; uninstall both,
  verify reads 0
- `quake guard` PASS — fixpoint verified; compiler-source touched in
  B.1.b requires guard

**Smoke**: kernel boots, hands-on serial UART shows `[B.1] install OK`
after install + uninstall round-trip + post-uninstall top=0.

**Concurrency note**: under -smp N>1, the 4 scalar globals + 7 ptr
globals are still process-shared between CPUs. Two CPUs running
different tasks concurrently each install/uninstall against the same
globals — race. The save/restore at `yield_now` boundary correctly
isolates *sequential* task interleaving on one CPU but not *parallel*
execution on two CPUs. This is acceptable through B.6 because: (a)
SOUL.6 demos all drive effects from the main task on CPU 0; (b)
spawned demo goroutines do not install handlers in their body, only
yield/exit. The SMP race becomes a gate at Phase 8 when the migrated
http_server spawns per-connection goroutines that DO install handlers.
Mitigation filed forward as **B.1.1 — per-CPU effect-stack frontstore**:
move the 4 scalars + 7 ptr globals into the per-CPU page (via GS-base),
so each CPU has its own working set; save/restore between CPU page
slot and Task slot on context switch instead of between globals and
Task slot.

### B.2 — setjmp/longjmp in libc_stubs.c

~1 quartz-day.

Add to `tools/baremetal/libc_stubs.c`:

```c
// x86_64 SysV jmp_buf layout: rbx, rbp, r12, r13, r14, r15, rsp, rip
// (8 × 8 bytes = 64 B; the jmp_buf array is sized 200 bytes in hosted
// glibc but we only need 8 slots — kernel code uses our @setjmp/@longjmp,
// not glibc's.)
typedef struct __qz_jmp_buf { uint64_t slots[8]; } __qz_jmp_buf;

__attribute__((returns_twice, nothrow))
int setjmp(__qz_jmp_buf *env) {
  __asm__ volatile(
    "movq %%rbx, 0(%0)\n"
    "movq %%rbp, 8(%0)\n"
    "movq %%r12, 16(%0)\n"
    "movq %%r13, 24(%0)\n"
    "movq %%r14, 32(%0)\n"
    "movq %%r15, 40(%0)\n"
    "leaq 8(%%rsp), %%rax\n"     // saved rsp = caller's rsp (after the return addr)
    "movq %%rax, 48(%0)\n"
    "movq (%%rsp), %%rax\n"       // return address = caller's rip
    "movq %%rax, 56(%0)\n"
    :: "r"(env) : "rax", "memory"
  );
  return 0;
}

__attribute__((noreturn, nothrow))
void longjmp(__qz_jmp_buf *env, int val) {
  if (val == 0) val = 1;  // longjmp(env, 0) is UB; coerce to 1 per glibc convention
  __asm__ volatile(
    "movq 0(%0), %%rbx\n"
    "movq 8(%0), %%rbp\n"
    "movq 16(%0), %%r12\n"
    "movq 24(%0), %%r13\n"
    "movq 32(%0), %%r14\n"
    "movq 40(%0), %%r15\n"
    "movq 48(%0), %%rsp\n"
    "movq %1, %%rax\n"           // return value into rax
    "jmp *56(%0)\n"               // jump to saved rip
    :: "r"(env), "r"((uint64_t)val) : "memory"
  );
  __builtin_unreachable();
}
```

Reference: identical shape to musl's `src/setjmp/x86_64/setjmp.s` and
`longjmp.s` — verified against musl 1.2.5 source 2026-05-24.

Remove the no-op `@setjmp` / `@longjmp` stubs at
`codegen_runtime.qz:2848-2853`; freestanding branch now declares them as
externs (same as hosted does at line 2592).

**Deliverables**:
- `tools/baremetal/libc_stubs.c` — setjmp/longjmp + struct decl
- `self-hosted/backend/codegen_runtime.qz` — remove the `define i32 @setjmp`
  / `define void @longjmp` stubs from freestanding emit; add
  `declare i32 @setjmp(ptr) returns_twice nounwind` + `declare void
  @longjmp(ptr, i32) noreturn nounwind` in their place
- `spec/qz/freestanding_setjmp_smoke.qz` — round-trip: alloc jmpbuf,
  setjmp returns 0 → longjmp(env, 7) → setjmp returns 7. UART print
  "B.2 setjmp ok"

**Smoke**: kernel boots, `[B.2] setjmp round-trip 7 ok` on UART.

### B.3 — `@__qz_effect_perform` and Throws via real longjmp

~1.5 quartz-days.

Now that B.1 has per-task arrays and B.2 has real setjmp/longjmp, we
replace the no-op `@__qz_effect_perform` stub with the same kind 0/1/2/3
dispatch that hosted does — lifted from `cg_emit_effect_runtime`
(`codegen_runtime.qz:1169+`).

Key adaptations from hosted:
- The TLS array accesses become per-task GEPs (`task.EFFECT_STACK_NAMES`
  base + idx*8 offset).
- The walk-from-top scan stays the same — it's index-based, not
  address-based.
- The longjmp-to-bufs[slot] now actually unwinds (real setjmp/longjmp
  from B.2).
- The Alloc bypass flag (`@__qz_alloc_in_handler`) stays a per-thread
  global. Kernel is single-core or per-CPU; treat as global through
  K8 (it's only consulted during alloc handler dispatch).

This unlocks `throw(reason)` from kernel code. The kernel main's
implicit `with Throws { throw: __qz_default_throws_handler }` wrapper
(emitted by `cg_emit_install_defaults` per `codegen_runtime.qz:1714`)
calls `__qz_panic` + halt by default — same shape as the hosted default
but with `__qz_panic` already emitted as a `print + cli + hlt` stub by
the freestanding panic-stubs path (`codegen_runtime.qz:1792`).

User-installed `with Throws { throw: my_handler } do -> body end` now
catches throws in body and dispatches to my_handler.

**Deliverables**:
- `self-hosted/backend/codegen_runtime.qz` — replace freestanding
  `@__qz_effect_perform` stub with full kind 0/1/2/3 dispatch; replace
  `@__qz_effect_handle_install` stub (already done in B.1) — verify
  bufs slot writes the jmpbuf ptr threaded through from the install
  site's `setjmp` call
- `spec/qz/freestanding_throws_smoke.qz` — throw inside `with Throws {
  throw: h } do -> ... end`, verify handler runs + body returns; then
  no-handler throw, verify __qz_panic fires + halt logs

**Smoke**: kernel boots, `[B.3] throws caught 7 ok` on UART. Second
boot with `-D NO_HANDLER`: `[B.3] panic: unhandled throw 'oops'` on
UART + halt.

### B.4 — `@__qz_effect_suspend` + kernel park/wake bridge

~1.5 quartz-days.

The hosted `__qz_effect_suspend()` consults `@__qz_effect_park_rv` (TLS
sentinel set by a kind=3 handler that called `__qz_effect_park(fd)`),
returning either POLL_READY (1) or the negative encoding `-(fd+2)` that
tells the scheduler to register a parker.

Freestanding adapts to the kernel's BLOCKED state model:

```qz
def __qz_effect_suspend(): Int
  var cur = sched_current()
  if cur == 0
    return 1   # called from main — degrade to POLL_READY
  end
  var park_rv = task_park_rv(cur)
  if park_rv == 1
    return 1   # POLL_READY — no park requested
  end
  # Negative sentinel encoding — caller (suspended task) wants park on fd/timer/scope
  # Caller has already wait_pushed itself onto the appropriate waiter list.
  task_set_state(cur, TASK_STATE_BLOCKED)
  set_sched_current(0)
  switch_to(cur + TASK_SAVED_RSP, pcpu_main_rsp_slot())
  # When we resume here, someone called sched_wake_interrupts_sleep on us;
  # we're back to READY. Return POLL_READY.
  task_set_park_rv(cur, 1)
  return 1
end
```

Plus the wake side. The kernel's `wait_pop` + ring `ready_push` are
already in tree; expose them via:

```qz
def __qz_sched_wake(t: Int): Void
  task_set_state(t, TASK_STATE_READY)
  ready_push(t)
end
```

And the active-wake from B.7 Phase 4e.8 (`sched_wake_interrupts_sleep`):

```qz
# Walk a scope's waiters_vec; for each parked task, wake it.
# Goroutines pending sched_sleep observe their park_rv flipped and
# return POLL_READY; their sched_sleep returns immediately.
def sched_wake_interrupts_sleep(scope: Int): Void
  var waiters = scope_get_waiters(scope)
  if waiters == 0
    return
  end
  var i = 0
  while i < vec_len(waiters)
    var t = vec_get(waiters, i)
    __qz_sched_wake(t)
    i = i + 1
  end
end
```

**Selectable impls** — `recvable` / `sendable` / `cancellable` /
`deadline_ms` / `awaitable` — each calls `__qz_effect_suspend` in their
register_waker path, and the producing side (channel send / scope
cancel / deadline timer / future complete) calls `__qz_sched_wake` on
the registered task. Same `Selectable` trait dispatch (per-poll
`try_poll` + `register_waker` + `complete`) as hosted; the only changed
piece is the underlying park/wake mechanism — TLS sentinel + pthread
condvar (hosted) becomes per-task `park_rv` field + `wait_push` (freestanding).

**Deliverables**:
- `tools/baremetal/hello_x86.qz` — `__qz_effect_suspend`, `__qz_sched_wake`,
  `sched_wake_interrupts_sleep`. New `TASK_PARK_RV = 128` (struct grows
  again, see B.1 size choice).
- `self-hosted/backend/codegen_runtime.qz` — remove the
  `define i64 @__qz_effect_suspend() ret i64 1` stub from freestanding;
  declare `@__qz_effect_suspend` as an extern resolved at link by the
  kernel-side `def __qz_effect_suspend()` Quartz function (same pattern
  as `pmm_alloc_page` already uses).
- `spec/qz/freestanding_park_wake_smoke.qz` — two goroutines: A parks on
  scope cancel; main thread calls scope_cancel(s); A wakes; A records
  TSC delta. Assert delta < 1 ms.

**Smoke**: kernel boots, `[B.4] park→wake latency 0.4 ms ok` on UART.

### B.5 — Selectable + Actor + Supervisor in kernel context

~1 quartz-day.

Verify the existing `Selectable` impls (in `std/sync/channel.qz`,
`std/sync/composition/scope.qz`, `std/sync/awaitable.qz`) work in the
kernel target now that B.4 is in place.

- `recvable(ch)` — channel recv. Channel send already wakes via
  `wait_pop` + `__qz_sched_wake` (B.4 wired this).
- `sendable(ch, v)` — channel send (buffered chan with full buffer).
- `cancellable(scope)` — fires when scope cancelled; chains via the
  waiters_vec mechanism B.4 set up.
- `deadline_ms(ms)` — fires at wall-clock deadline. Uses
  `uk_time_mono_ns` already in tree, plus a TSC-derived park-with-timeout
  variant of `__qz_effect_suspend` (B.5 adds `task.PARK_DEADLINE` field).
- `awaitable(task)` — fires when a task completes. Wakes from
  `sched_post_switch` on the DEAD branch.
- `signalable(SIGTERM=15)` — degenerates to "never fires" in kernel
  (no SIGTERM signal in freestanding); B.5 explicitly notes this.
  Userland code that uses `signalable` in the http_serve_supervised
  shutdown path keeps working in userland; kernel deployment of
  `http_serve` in Phase 8 cancels via `scope_cancel(root)` from
  the boot shutdown path.

Smoke for `Actor<T>` + `Supervisor`: spawn one Actor + send 3 messages
+ observe handle (Actor's `handle` method runs 3×). Spawn one
`DynamicSupervisor` + start_child a flaky body that throws every other
poll; observe restart count.

**Deliverables**:
- `tools/baremetal/hello_x86.qz` — call `actor_smoke()` + `supervisor_smoke()`
  from kernel main behind an `KERN8_BRIDGE_SMOKE` env flag
- `spec/qz/freestanding_actor_supervisor_smoke.qz` — same surface, just
  asserts UART output

**Smoke**: kernel boots, `[B.5] actor 3 msgs ok / supervisor 3 restarts ok`
on UART.

#### B.5 Reconnaissance (2026-05-24, post-B.4)

The "Verify the existing impls work" framing above was optimistic. A
recon pass after B.4 shipped found that *all* stdlib Selectable / Actor /
Channel impls bake hosted-only assumptions into their codegen-emitted
bodies that the freestanding kernel can't satisfy without architectural
work. Three independent gaps:

1. **Channel intrinsic emits raw `pthread_*` in freestanding.**
   `cg_intrinsic_channel.qz` (or equivalent) lowers `channel_new(n)` /
   `send(ch, v)` / `recv(ch)` to direct calls of `pthread_mutex_init`,
   `pthread_cond_wait`, `pthread_cond_signal`, etc. — same emit for
   hosted and freestanding. Verified by compiling
   `def main(): Int = channel_new(8); send(ch, 42); recv(ch)` against
   `--target x86_64-unknown-none-elf`: 28 `pthread_*` callsites in the
   resulting IR. The kernel has no pthread runtime — these will fail at
   link.

2. **Stdlib `awaitable(task)` assumes hosted task-frame layout.**
   `std/sync/composition/awaitable.qz:53-58` uses
   `load(@task_handle, 0) == -1` (slot 0 = state) and
   `load(@task_handle, 1)` (slot 1 = result). That's the hosted heap-
   allocated 16-byte task frame; the kernel's task is a 192-byte pool
   slot with TASK_STATE at offset 0 (U8, READY/RUNNING/BLOCKED/DEAD —
   not -1), TASK_SAVED_RSP at 8, etc. The shape and the encoding both
   differ.

3. **`waiter_register` / `waiter_unregister` side-table is hosted-only.**
   `awaitable`'s `register_waker` calls `waiter_register(@task_handle,
   frame)` which writes into a hosted `@__qz_waiters` global walked by
   `task_done` / `panic_caught`. Neither the global nor the walkers exist
   on the kernel side; the kernel's wake mechanism is `__qz_sched_wake`
   (B.4) reading TASK_PARK_RV.

By transitive dependency, this blocks Actor (which IS a goroutine plus
an inbox channel), Supervisor (which spawns Actors), and Selectable
arms for `recvable` / `sendable` / `cancellable` (all channel-backed).
Only `signalable` works in the kernel — and only because the design
memo already specified it degenerates to "never fires."

Three paths forward, each with material cost. Pick one before resuming:

**Path A — `@cfg`-aware channel codegen.** Modify the channel intrinsic
emit to pick between hosted (`pthread_*`) and freestanding (kernel's
`chan_send` / `chan_recv` / `spinlock_lock` / `wait_push` / `wait_pop`)
based on target. Same shape on the Quartz surface; the implementation
forks at the IR layer. **Cost**: ~1-2 quartz-days. Cleanest per D1
(highest-impact change). Awaitable still needs a separate fix (path A
doesn't address gap #2/#3) — likely a parallel `@cfg`-aware emit in the
Selectable impl, or a kernel-side `extend KernelTask with Selectable<Int>`.

**Path B — pthread-shim layer in kernel.** Implement `pthread_mutex_*`
and `pthread_cond_*` symbols in `libc_stubs.c` (or a new
`pthread_kernel.c`) that wrap the kernel's spinlock + waitq primitives.
The stdlib channel codegen is unchanged. **Cost**: ~0.5 quartz-day, but
violates D7 ("Delete dead code outright") + project reality check
("no shims") — the kernel doesn't need pthread, this would be a
compatibility shim purely for stdlib codegen. Discouraged.

**Path C — Kernel-side parallel impls.** Add `extend KernelChannel with
Selectable<Int>`, `extend KernelTask with Selectable<Int>`,
`extend KernelScope with Selectable<Int>` in baremetal-only files
(`tools/baremetal/kernel_selectable.qz` or similar). Stdlib is
untouched; kernel-side impls use kernel primitives directly. **Cost**:
~1 quartz-day. Sidesteps the channel-intrinsic question entirely
(kernel never uses `channel_new` — it uses `chan_alloc` etc.). Trade-off:
two Selectable implementations to keep in sync for any future trait
refactor.

**Recommendation**: Path A for channels (compiler-driven correctness)
+ Path C for awaitable/cancellable (no equivalent codegen intrinsic to
fork). Both land together as B.5 sub-phases. Estimated bridge work
revised from 1 qd to 2-3 qd for full B.5; possible to scope-down to
**B.5a awaitable-only** (Path C, ~0.5 qd) to ship a small Selectable
smoke without channels, then file the channel work as B.5b/c.

Pending user direction.

#### B.5 Status (2026-05-24, post-implementation)

User approved A + C combined. Shipped in four commits:

- **B.5a + B.5b** (`12dd67f6`) — KAwait + KRecvable + KSendable.
  Quartz Selectable<Int> trait dispatch over kernel-owned wrapper
  structs. KAwait closes the slot-recycle race via TASK_ID capture
  at register-time. UART smokes green.
- **B.5c** (`c0c0f3a8`) — Kernel waiter side-table (256 entries,
  spinlock-protected). sched_post_switch DEAD branch + chan_send +
  chan_recv hooks call kernel_waiter_wake_all. register_waker /
  unregister_waker on all three wrappers go through the table.
  Active-wake measured at single-task latency in B.5c smoke.
- **B.5d** (`THIS COMMIT`) — Path A channel codegen fork. The
  intrinsic `cg_emit_conc_channel` now branches on target_triple via
  a new `cg_freestanding_channel_emit` helper that lowers
  channel_new/send/recv/channel_close/channel_closed/channel_size/
  channel_capacity/channel_is_empty/channel_is_full to direct
  @chan_new/@chan_send/@chan_recv/etc. calls (the kernel's bare
  surface). Hosted path unchanged.

#### B.5d.1 — wrapper-synthesis blocker (filed forward)

B.5d's compiler fork is verified at IR level (9 new tests in
freestanding_spec.qz). End-to-end kernel link of stdlib channels was
attempted and DEFERRED on the following blocker:

  PASS 1.3 in `mir_lower.qz` auto-registers every Quartz function
  with EFFECT_SUSPEND as an async target and synthesizes
  `__Future_<name>$poll`. The wrapper's body references hosted
  runtime: `@__qz_current_frame`, `@__qz_sched_park_pending`,
  `@__qz_sched_fuel`, `@pthread_mutex_lock/unlock`,
  `@pthread_cond_signal`, `@__qz_waiter_notify_all`, plus ~30 more
  from racedet/panic/pidfd/timer/completion subsystems. All are dead
  code in kernel context — the kernel uses go_fn + seeded stacks,
  never the Future-poll machinery — but the linker still resolves
  the bodies. Importing `std/sync/communication/channel` into the
  kernel synthesizes `__Future_*$poll` for every Channel-touching
  function in stdlib (~30 wrappers); each pulls in dozens of dead
  symbol references.

  B.5d ships a partial mitigation in `codegen_runtime.qz` —
  freestanding-emit stub block for the 7 most-frequent dead-code
  symbols (3 globals, 4 functions trapping via `cli; hlt`). That's
  not enough on its own (243 undefineds remain in a kernel that
  imports the full channel module); the proper fix is to gate PASS
  1.3 on `cg_is_freestanding == 0`. Cost estimate: ~0.5 qd
  (threading the target through to mir_lower, identifying the gate
  site, regression specs).

  Until B.5d.1 lands, freestanding kernel code should call the
  bare kernel chan_* primitives (chan_new / chan_send / chan_recv)
  directly. The B.5d fork ensures that ANY stdlib call site using
  channel_new/send/recv WILL emit correct kernel-redirected IR
  when the target is freestanding — the compiler-side correctness
  is in place; only the wrapper-suppression piece blocks consumption.

#### B.5d.1 — wrapper-synthesis gate (SHIPPED 2026-05-24, `cef98bd0`)

Gate threaded through `qzmod_format::qzmod_active_target()` (set at
compile() entry from the existing `qzmod_active_flags_set` call).
Two gate sites:

- `mir_lower.qz` PASS 1.3 auto-register loop — wrapped in
  `if _skip_pass13 == 0`.
- `mir_lower_async_registry.qz` `mir_mark_suspendable` (PASS 1.2b
  consumer) — same target check around `mir_record_async_target`.
  `mir_record_effect_leaf` still fires so the EFFECT_SUSPEND
  bitset stays consistent for diagnostics.

Single-site gate was insufficient — PASS 1.2b's `mir_mark_suspendable`
registers first, then PASS 1.3's "if not already registered" finds
them and skips, but PASS 1.3a still synthesizes `$poll` bodies for
the PASS-1.2b-registered set. Both gates close the loop.

Result on a stdlib-channel-importing freestanding compile:
0 `__Future_*$poll` wrappers (was 14). Hosted unchanged at 15.
End-to-end kernel smoke: `[B.5d1] stdlib chan recvd=3 sum=63 ok`.

#### B.5e — Actor + Supervisor smokes (FILED FORWARD 2026-05-24)

Recon after B.5d.1 showed the stdlib Actor + Supervisor surface
needs more freestanding work than the channel surface did. Three
distinct blockers, none of which the wrapper-suppression gate
addresses:

1. **Actor runtime intrinsics.** `cg_intrinsic_conc_channel.qz` emits
   `@__qz_actor_check_clean`, `@__qz_actor_mark_clean`,
   `@__qz_current_actor_inbox` (TLS), and a few more. These are
   hosted-runtime symbols with no kernel equivalent. The intrinsics
   need a freestanding fork similar to B.5d's `cg_freestanding_channel_emit`,
   redirecting to kernel-side helpers (TBD: per-task TASK_INBOX slot
   for actor identity, kernel-side check-clean side-table mirroring
   the hosted one).

2. **Explicit `async fn()` lowering.** Stdlib `_supervisor_watcher`
   uses `var task = async _supervisor_watcher(sup)` — an EXPLICIT
   async-wrap site, not the PASS 1.2b/1.3 auto-registration that
   B.5d.1 gates. The lowering at `mir_lower.qz:2207` produces a
   `__Future_X$poll` wrapper unconditionally; gating it would silently
   break user code that uses `async fn()` in freestanding. Need a
   different lowering for freestanding — likely fall back to
   `go_fn(name)` (which kernel implements) instead of synthesizing
   a Future. Affects both user code (rare in kernel) and stdlib's
   internal Supervisor usage (common).

3. **C.14.7 actor identity (TLS).** `@__qz_current_actor_inbox` is a
   hosted TLS global; in kernel SMP context it needs a per-CPU page
   slot or per-task field. Tightly coupled to (1).

Combined scope: ~1-2 quartz-days for proper Path A on the actor
intrinsics + (2) explicit-async fallback + (3) actor identity. The
B.5 design memo's original "~0.5 qd Actor smoke" estimate assumed
Path C-only with kernel-side parallel impls; under the Path A +
Path C combined approach the user authorized, the actor work is
the larger of the two remaining pieces.

**Pragmatic alternative**: skip stdlib Actor in kernel entirely.
Phase 8 (unikernel migration of `http_server.qz`) doesn't strictly
need Actor — `http_serve(80) do |route| -> ... end` is a request
loop, not an Actor pattern. If Actor isn't on Phase 8's critical
path, B.5e can defer until SOUL.6 / SOUL.7 surface a concrete need.
Filed in roadmap.

#### B.5e.2 — explicit-async freestanding lowering (SHIPPED 2026-06-02)

Blocker #2 above (explicit `async fn()` / `go fn()` surface synthesizes
a hosted `__Future_<name>$new`/`$poll` wrapper whose `$poll` body pulls
hosted-only runtime: `@__qz_current_frame`, `@pthread_*`,
`@__qz_waiter_notify_all`, completion/timer/racedet symbols) is now
closed for the **zero-arg** case — the common shape in kernel-importable
stdlib (`async _supervisor_watcher` is 1-arg; see ARG residual below).

Implementation: `mir_lower.qz` NODE_ASYNC_CALL lazy path. When
`_mir_is_freestanding == 1` (the reliable flag set in `quartz.qz:1295`
from the `--target` suffix, independent of qzmod) and the async target
is a named zero-arg function, lower to a real kernel spawn:

```
%ref = ptrtoint @<fn> to i64
%task = call i64 @go_fn(i64 %ref)      ; kernel task_alloc + seeded stack + ready_push
```

instead of `call @__Future_<fn>$new()`. The returned handle is a kernel
task pointer, directly consumable by `kernel_awaitable` (B.5a). The
`mir_record_async_target` call (which drives `$new`/`$poll` synthesis)
is **not** invoked on this path, so no hosted wrapper is generated. The
hosted path is byte-for-byte unchanged (`mir_record_async_target` still
fires when `_mir_is_freestanding == 0`).

`go fn()` (NODE_GO) re-enters this code after rewriting NODE_GO →
NODE_ASYNC_CALL, so the same redirect governs `go fn()`. The current
kernel uses neither surface form (it calls `go_fn(...)` directly), so
the kernel IR is **byte-identical** before/after this change — the fix
unblocks *future* stdlib imports, it does not alter today's kernel.

**Verification:**
- Freestanding single-file IR (`async work()`): `call i64 @go_fn(i64 %ref)`
  emitted; **0** `call @__Future_work$new`. Was 1 `$new` call before.
- Hosted IR (`async work()`): unchanged — `call @__Future_work$new()`
  at the same site; **0** `@go_fn`.
- Kernel b5test IR diff (pre vs post change): **0 lines** — no kernel
  impact.
- Kernel QEMU boot (post change, NUM_TASKS shrunk to 16384, -m 1G):
  all four B.5 smokes green — `[B.5a] awaitable pre_pending=1
  post_done=1`, `[B.5b] kchannel recvd=3 sum=42`, `[B.5c] kwait woke=1`,
  `[B.5d1] stdlib chan recvd=3 sum=63 ok`.
- Fixpoint: gen1 == gen2, 2609 functions.
- Hosted regression: `async_combinators` 6/6, `async_mutex` 8/8,
  `scheduler` 4/4, `go_scope` 7/7, `resolver_go_arg_module_var` 3/3.

#### B.5e.3 — arg-passing async/go freestanding lowering (SHIPPED 2026-06-03)

`go_fn`'s ABI is a zero-arg entry pointer and cannot forward call args, so
B.5e.2 left `async fn(a, b)` / `go fn(a, b)` falling through to the hosted
`$new`/`$poll` path. B.5e.3 closes the arg case via the kernel's
closure-capture entry `kern_go_closure(closure)` (the same one the
supervised HTTP per-conn loop uses via `http_dyn_gsup_spawn_one`).

**Implementation** (`mir_lower.qz` `_mir_fs_spawn_closure_with_args`, called
from the NODE_ASYNC_CALL freestanding arg branch). For freestanding
`async fn(args)`:

1. Evaluate the call args in the CALLER's MIR context.
2. Synthesize a zero-user-param thunk `__fs_async_thunk_N(__env)` that
   loads each arg back from `env[i+1]` and tail-calls the real target.
   (Single-arg dispatch: `__qz_invoke_closure` calls `entry(env)`, so all
   args MUST be captured into the env, not passed positionally.)
3. Build the closure env in the caller: `alloc(N+1)`,
   `env[0]=thunk_fn_ptr`, `env[1..N]=arg_vals`, tag with `env|1` (low bit
   set per the Quartz closure ABI in codegen_runtime `@__qz_poll_closure`
   / libc_stubs.c `__qz_invoke_closure`).
4. Spawn via `kern_go_closure(tagged)`. Returns the kernel task handle
   (same shape `go_fn` returns), consumable by `kernel_awaitable` (B.5a).

`mir_record_async_target` is NOT called on this path — no hosted
`$new`/`$poll` wrapper is generated. This mirrors `mir_lower_lambda`'s
closure-env emission but builds it directly in MIR (no AST lambda node).

**Verification (all empirical):**
- Single-file freestanding IR of `async work(41)` + `async work2(10,20)`:
  **0** `call @__Future_*$new`, **2** `call @kern_go_closure`, 2
  `__fs_async_thunk_*` defs (`thunk_0` loads env[1]→`work(arg)`; `thunk_1`
  loads env[1],env[2]→`work2(a,b)`). Before B.5e.3: 2 `$new` calls, 0
  `kern_go_closure`, hosted `@__qz_alloc`/`@__qz_current_frame`/
  `@__qz_task_id_counter` in the synthesized `$new`.
- **Kernel QEMU boot** (NUM_TASKS shrunk to 16384, -m 1G; `async`-surface
  smoke `b5e3_one_worker(7)` 1-arg + `b5e3_two_worker(10,4)` 2-arg, bodies
  send arg-derived values to a channel main recvs):
  `[B.5e3] argpass one=107 two=40 recvd=2 ok` — 1-arg capture (7+100=107)
  and 2-arg capture (10*4=40, slot-order-correct) both proven. All prior
  B.5 smokes still green (`[B.5a]`/`[B.5b]`/`[B.5c]`/`[B.5d1]`).
- Hosted async-fn lowering byte-identical (`__Future_work$new/$poll`,
  `__Future_work2` md5-identical golden↔new). Real hosted `async
  compute(7)`+`await` compiles/links/runs → 49. Fixpoint gen1==gen2 (2612
  fns; +2 over the 2610 base for the new helper + the freestanding-flag
  accessors). async_combinators 6/6, async_mutex 8/8, scheduler 4/4,
  go_scope 7/7, resolver_go_arg_module_var 3/3.

The consumer (`std/actor.qz` `var task = async _supervisor_watcher(sup)`)
now lowers without a hosted wrapper in freestanding.

#### Single-file gate inconsistency — FIXED (2026-06-03, part of B.5e.3)

The B.5d.1 PASS 1.2b registration gate (`mir_propagate_suspend_ast`) and
the PASS 1.3 auto-registry gate keyed on
`qzmod_format::qzmod_active_target()`, which is only populated on the
multi-module qzmod/cache path — NOT on the single-file `--no-cache`
kernel build. Surfacing as load-bearing under B.5e.3: the kernel smoke's
`async`-target functions (`b5e3_one_worker`) got auto-registered, and the
PASS 1.2a / 1.3c `$poll`/`$new` synthesis loops (which were NOT gated at
all) emitted orphan `__Future_<fn>$poll` definitions referencing
hosted-only globals (`@__qz_sched`, `@__qz_waiter_notify_all`) — an
**llc-level "use of undefined value" error**, not gc-droppable dead code.

Fix:
- Mirror the unconditional `_mir_is_freestanding` flag into
  `mir_lower_async_registry` (`mir_async_set_freestanding`, set from
  `quartz.qz` alongside `mir_set_freestanding`) and key the PASS 1.2b
  registration gate on it instead of `qzmod_active_target()`.
- Gate the PASS 1.2a (`$poll`) and PASS 1.3c (`$new`) synthesis loops on
  `_mir_is_freestanding == 0` (PASS 1.3a was already gated by
  `auto_registered > 0`, now 0 in freestanding). The async-target
  registry is still populated (QZ0210 needs it); only synthesis is
  skipped.

Result: kernel IR has **0** `__Future_*$poll`/`$new` defs; ELF links
clean with `--gc-sections` (298 KB). Hosted path unaffected (the gates are
no-ops when `_mir_is_freestanding == 0`); only observed hosted delta is a
single `__qz_gen_yield_capture` define now emitted for a *trivial
no-import* program (the golden's IR referenced it without defining it —
llc-invalid; the new IR is strictly more correct). Async-fn lowering and
all async regression specs unchanged.

#### B.5e.4 — `go`-surface freestanding spawn (SHIPPED 2026-06-03)

B.5e.2/3 closed the `async fn(...)` surface but left a latent bug on the
`go fn(...)` surface. The NODE_GO named-call path (`mir_lower.qz`) rewrites
NODE_GO → NODE_ASYNC_CALL, lowers it (which in freestanding now spawns via
`go_fn` / `kern_go_closure` and returns the kernel task handle — B.5e.2/3),
and THEN emits `perform(Async, spawn, frame)` at kind=1 to route the
scheduler enqueue through the hosted Async effect handler. In freestanding
the task is ALREADY spawned + ready_push'd by `go_fn`/`kern_go_closure`, and
there is no kernel Async/spawn handler — so the trailing
`@__qz_effect_perform(Async, spawn, frame)` re-dispatched an already-running
task through a nonexistent handler. This was never caught because "the
current kernel uses neither surface form" (B.5e.2) — only the `async`
surface was exercised in the b5e3 boot smoke.

Fix: in the NODE_GO named path, gate the perform on `_mir_is_freestanding
== 0`; in freestanding `return frame` directly (the already-spawned kernel
handle, same shape `async fn()` yields). The statement-form NODE_GO
delegates to the expression path, so it is covered too. Lambda-`go`
(`go do ... end`) still synthesizes a hosted `$new`/`$poll` wrapper in
freestanding — separate from the named-call residual, filed with the Actor
intrinsics.

**Verification:**
- Freestanding IR (`go worker()` + `go work(10)`): `call @go_fn` +
  `call @kern_go_closure`, **0** `effect=Async op=spawn` performs (was 2).
- Hosted IR: 2 Async/spawn performs, 0 `go_fn`/`kern_go_closure` — behavior
  preserved (only the benign `__qz_gen_yield_capture` define delta from the
  rebuild, llc-valid > the golden's llc-invalid dangling ref).
- **Kernel QEMU boot** (default NUM_TASKS=16M, `-m 16G`): new `[B.5e3-go]`
  smoke (`go b5e3_one_worker(8)` 1-arg + `go b5e3_two_worker(6,7)` 2-arg) →
  `[B.5e3-go] argpass one=108 two=42 recvd=2 ok` (108=8+100, 42=6*7,
  slot-order-correct). All prior B.5 smokes green; HTTP server still starts.
- Fixpoint gen1==gen2 (2612 fns). guard + cache-ro smoke green.

#### B.5e.5 — `go do ... end` lambda-surface freestanding spawn (SHIPPED 2026-06-03)

B.5e.2/3/4 closed the **named** `go fn(args)` surface in freestanding, but
the **lambda** surface `go do ... end` still fell through to the hosted
`$new`/`$poll` Future state machine plus `perform(Async, spawn, frame)`.
In the kernel there is no Async/spawn effect handler, and the synthesized
`__Future_*$poll` references hosted-only symbols — so a kernel go-lambda was
miscompiled in exactly the way the named path was before B.5e.4. (Latent,
never caught: the kernel boot smoke only exercised `async` and named `go`.)

Fix: gate the `go_is_lambda` path (`mir_lower.qz`) on `_mir_is_freestanding`.
The freestanding branch spawns the lambda body as a real kernel goroutine
via a new `_mir_fs_spawn_lambda` helper — a sibling of
`_mir_fs_spawn_closure_with_args` (B.5e.3) whose synthesized thunk body IS
the lambda body (captures restored from `env[i+1]`) rather than a
named-function call. Captures are evaluated in the caller, threaded through
the tagged closure env (`[thunk_ptr, cap0, cap1, ...] | 1`), and the body
runs straight-line on the goroutine's own kernel stack, parking on blocking
ops via the B.4 suspend/wake bridge. No hosted wrapper, no Async/spawn
perform; returns the `kern_go_closure` task handle directly (same shape the
named path yields, consumable by `kernel_awaitable`).

**Verification:**
- Freestanding IR (capturing `go do -> x+y end` + no-capture `go do -> 99
  end`): 2 `kern_go_closure` + 2 `__fs_lambda_thunk` defs, **0**
  `__Future_*$new`/`$poll`, **0** `effect=Async op=spawn` performs. Golden
  emitted 0 / 8 / 2 (the bug). Thunk_0 reads `env[1]→x`, `env[2]→y`, returns
  `x+y`; the no-capture thunk allocs 1 slot.
- Hosted IR byte-identical to golden except the documented benign
  `__qz_gen_yield_capture` rebuild delta; `colorblind_async_spec` 13/13 and
  `alloc_e6_spawn_variants_spec` 5/5 (hosted go-lambda path untouched).
- **Kernel QEMU boot** (default NUM_TASKS=16M, `-m 16G`): new
  `[B.5e5-lambda]` smoke (single-capture `c1+200` and two-capture `c2*c3`
  go-lambdas writing into a channel) → `[B.5e5-lambda] capture one=209
  two=56 recvd=2 ok`. Prior `[B.5e3]` / `[B.5e3-go]` smokes still ok; full
  boot + HTTP serve (200, 14187 bytes).
- Fixpoint gen1==gen2 (2613 fns); guard + both cache smokes green;
  style_demo + brainfuck smoke green.

With B.5e.5 the **entire `go`/`async` spawn surface** — named zero-arg,
named arg-passing, and lambda (capturing + non-capturing) — lowers to real
kernel goroutines in freestanding. The remaining B.5e filed-forward item is
the Actor + Supervisor *intrinsics* (`18a2ef26`), not a spawn-surface gap.

#### B.5e.6 — Actor + Supervisor runtime intrinsics freestanding fork (SHIPPED 2026-06-03)

Closes B.5e blockers **#1 (Actor runtime intrinsics)** and **#3 (actor identity
TLS)** above. (Blocker #2, explicit-`async` lowering, was already closed by
B.5e.2–.5.) The four actor intrinsics emitted hosted-only symbols with no
kernel analog: `actor_mark_clean` / `actor_check_clean` →
`@__qz_actor_mark_clean` / `@__qz_actor_check_clean` (a pthread-mutex
clean-mark side-table), and `actor_self_inbox` / `__actor_set_self_inbox` →
the `@__qz_current_actor_inbox` TLS global. A kernel has neither pthreads nor
TLS, so any stdlib Actor compiled freestanding hit undefined symbols at link.

Fork (three sites, all additive — hosted path byte-unchanged):

1. **Codegen** (`cg_intrinsic_conc_channel.qz::cg_freestanding_channel_emit`):
   four new branches, siblings of the B.5d `chan_*` redirects, emitting
   `call @actor_mark_clean_kernel` / `@actor_check_clean_kernel` /
   `@actor_self_inbox_kernel` / `@actor_set_self_inbox_kernel`. Reached via
   the existing `cg_is_freestanding` gate before the hosted emit at ~2629.

2. **Actor identity → per-task slot** (`hello_x86.qz`): `TASK_STRUCT_SIZE`
   216→224, new `TASK_ACTOR_INBOX=216` (mirrored `#define` in
   `libc_stubs.c`). `actor_self_inbox_kernel` / `actor_set_self_inbox_kernel`
   read/write `sched_current()+TASK_ACTOR_INBOX` — pure task memory, so no
   context-switch save/restore (unlike the effect-stack slots); zeroed in
   `task_init` like `TASK_ARENA_HEAD`. This replaces the hosted TLS with the
   kernel's natural "current actor = current task" identity. Cost: +8 B/task
   = +128 MB at NUM_TASKS=16M, a lazy `.bss`/PMM reservation (only spawned
   slots commit pages).

3. **Clean-mark → inbox-keyed side-table** (`hello_x86.qz`): an
   `ACTOR_CLEAN_TABLE_CAP=256` slot table on one lazy PMM page with an
   embedded spinlock, mirroring `_kern_listen_table_init` and the hosted
   mark/check-consume semantics exactly (idempotent mark, silent-drop on full
   → supervisor sees CRASH; check removes on hit so recycled inbox handles
   can't inherit a stale mark). The table is inbox-keyed, not per-task,
   because the supervisor checks by inbox VALUE *after* the actor task has
   died and freed its slot.

   A DCE caveat surfaced and was fixed: the helpers are reached only through
   the codegen intrinsic redirect — an edge the Quartz reachability pass
   can't see (it operates on the intrinsic name, not the emitted symbol) — so
   3 of 4 were pruned and llc errored `use of undefined value`. (chan_*/
   kern_tcp_* avoid this only because they have direct kernel/stdlib callers.)
   Fixed with `_actor_kernel_dce_anchor()`, a side-effect-free reachability
   anchor called unconditionally from kmain that directly references all four
   — a permanent keep that survives the eventual `std/actor.qz` integration
   (which also reaches the helpers only via intrinsics).

**Verification:**
- IR (single file): freestanding emits the three surface-callable redirects
  (`@actor_mark_clean_kernel` / `@actor_check_clean_kernel` /
  `@actor_self_inbox_kernel`), **0** hosted `@__qz_actor_*`; hosted emits the
  original `@__qz_actor_*` + TLS load, **0** kernel symbols. For
  `actor_spec.qz`, golden-vs-new hosted IR is **byte-identical** (72898 lines,
  empty diff) — the change is provably hosted-neutral.
- **Kernel QEMU boot** (NUM_TASKS=16M, `-m 16G`): new `[B.5e] actor
  self_ok=1 w1=46561 w2=46562 mark=1 consume=1 miss=1 ok` — two workers read
  distinct per-task inboxes (0xB5E1/0xB5E2 ⇒ slot is the running task's, no
  cross-task clobber); mark→check returns 1, second check 0 (consume),
  unmarked check 0 (miss). All four kernel helper `define`s emitted (DCE
  anchor). Prior `[B.5a/b/c/d1/e3/e3-go/e5-lambda]` smokes all still ok; full
  boot to `[INFO] Listening on port 80 (supervised)` + `tcp_accept blocking`,
  no fault/panic (the +8 B struct growth is benign).
- Guard fixpoint gen1==gen2 (2613 fns); cache-ro + vec-of-struct smokes green;
  style_demo + brainfuck green; `actor_supervisor_spec` + `dynamic_supervisor_spec`
  green (hosted runtime unchanged).

**Scope honesty — what this does NOT yet do.** This closes the *intrinsic*
blockers: the four actor intrinsics now *link and run* freestanding. It does
**not** yet run the full `std/actor.qz` Actor + Supervisor stack in the kernel
(the B.5 success criterion "Actor receives 3 messages; Supervisor restarts 3×
with backoff"). The `[B.5e]` smoke drives the four intrinsics + side-table +
per-task slot directly, not a real `actor ... end` poll loop. Pulling
`std/actor.qz` into the kernel is the remaining **B.5e.7** step.

**B.5e.7 — exact blockers (probed 2026-06-03, post-B.5e.6).** A minimal real
actor (`actor Counter ... end`; spawn; 3 sends; `get`; `stop`) compiled
`--target x86_64-unknown-none-elf` confirms the B.5e.6 substrate already
carries real actors — **0** hosted `@__qz_actor_*`, **5** `@actor_*_kernel`
redirects, **0** `Async/spawn` performs. Two well-defined gaps remain before it
links:
1. **Actor `$poll` Future synthesis is not freestanding-forked.** The
   `actor ... end` keyword lowers its message loop to a hosted
   `@__Future_<Actor>$new`/`$poll` (4 refs), whose bodies pull ~40 hosted-only
   `@pthread_*` / `@__qz_current_frame` / `@__qz_waiter_notify_all` symbols.
   This is the actor-loop analog of the B.5e.2–.5 `go`/`async` spawn fork:
   needs a freestanding lowering of the actor poll-loop spawn (likely in the
   actor-desugar → `mir_lower` path, reusing `kern_go_closure` + the B.4
   suspend/wake bridge instead of the hosted Future state machine). This is
   the larger piece.
2. **`time_epoch_ms` / `gettimeofday` dependency** (6 reachable refs). The
   supervisor backoff (and `std/actor.qz`'s `import * from time`) reaches the
   POSIX `ffi/time` `gettimeofday` binding, which has no kernel symbol (the
   known pre-existing dangling-`@time$time_epoch_ms` residual). Freestanding
   needs a kernel TSC-backed `time_epoch_ms` or a `@cfg(os: "unknown")` gate
   on the backoff-timing calls.

Neither blocks the substrate; both are filed forward as B.5e.7. The runtime
the actor stack needs (the four intrinsics, per-task identity, clean-mark
table, channel/sched/waiter bridges) is now in place.

#### B.5e.7 — real `actor ... end` running freestanding (SHIPPED 2026-06-03)

Both blockers above closed. A real language-level actor now **links and runs**
in the kernel: the `[B.5e7] real actor count=3 ok` smoke spawns `actor Counter`,
fires 3 increments, does a request-response `get_count`, and synchronously
stops it — the B.5 "Actor receives N messages" criterion on the actual surface.

**Blocker #1 — actor `$poll` freestanding fork (the larger piece).** The actor
message loop no longer lowers to the hosted `@__Future_<Actor>$poll` generator
state machine in freestanding. Instead it runs as a real kernel goroutine,
exactly mirroring the B.5e.2–.5 spawn fork:
- `mir_lower.qz`: the 524-line recv-loop body was extracted verbatim into a
  shared `mir_emit_actor_poll_body(..., freestanding)` — emitted by BOTH the
  hosted generator `$poll` (freestanding=0) and a new
  `mir_lower_actor_poll_freestanding` wrapper (freestanding=1) that emits a
  PLAIN `ActorName$__poll(__actor_state)` function (`_gen_active=0`). Only the
  3 termination sites diverge (hosted writes the async frame `self[0]=-1;
  return 1`; freestanding just `return 0`). Loop vars are plain stack slots —
  the goroutine has its own real stack, so they persist across the blocking
  `recv` with no save/restore, and `recv`/`send` lower to the B.5d kernel
  channel redirects (parking via the B.4 suspend/wake bridge).
- `mir_lower_actor_spawn`: the freestanding branch spawns the poll fn via
  `_mir_fs_spawn_closure_with_args(poll_name, [state])` (the B.5e.3 kernel
  goroutine primitive) instead of `__Future_…$new` + `sched_spawn`. The
  `frame[3]=-999` hosted supervision sentinel is dropped (no kernel frame).
- Two new kernel channel ops the actor stop/drain paths need (no other kernel
  caller, so anchored in `_actor_kernel_dce_anchor` past `--gc-sections`):
  `chan_try_recv` (← `try_recv`) and `chan_try_recv_or_closed`
  (← `try_recv_or_closed`, the stop-proxy's cascade-safe poll), both in
  `hello_x86.qz` with the hosted Option-ptr `[tag, value]` contract; redirects
  in `cg_freestanding_channel_emit`. And `@qz_vec_remove` (the `vec_delete`
  helper, reached by the link/monitor-remove arms) is now emitted in the
  freestanding runtime block of `cg_emit_runtime_decls` (it previously lived
  only past the freestanding early-return in `cg_emit_runtime_helpers_2`).

**Blocker #2 — `time_epoch_ms` freestanding.** `@cfg`-forked in `std/time.qz`:
`@cfg(os: "unknown")` returns `time_mono_ns() / 1_000_000` (the kernel TSC
bridge → `uk_time_mono_ns`); `@cfg(not: os: "unknown")` keeps the POSIX
`gettimeofday`. Monotonic is *more* correct for the supervisor backoff, which
only computes deltas (`now - last_restart_ts_ms`).

**Hosted neutrality.** The hosted actor lowering is byte-identical to golden
(the only delta is the documented benign `@__qz_gen_yield_capture` define,
which makes previously-llc-invalid IR valid — strictly more correct, 0 lines
removed). guard fixpoint gen1==gen2==gen3 (2615 fns). Hosted actor/supervisor
specs unchanged (`actor_supervisor_spec` 10/10, `actor_link_spec` 10/10,
`actor_mn_spec` 7/7, `actor_spec` 20/21 — the 1 failure is a PRE-EXISTING
loop-inside-actor-method bug, `add_range(50)→16`, with byte-identical lowering
on golden; filed forward, NOT a B.5e.7 regression).

#### B.5e.8 — freestanding actor panic-recovery hook (SHIPPED 2026-06-03)

The kernel had no equivalent of the hosted worker-loop's `frame[3]==-999`
panic-caught restart, so a panicking freestanding actor handler hit the
freestanding `panic` stub (`unreachable`) and halted the CPU. B.5e.8 closes that
in two stages (full design: `docs/design/B5E8_FREESTANDING_ACTOR_PANIC_RECOVERY.md`):

- **B.5e.8a (`f55906b6`)** — freestanding `panic` now scans the per-task effect
  stack for an installed `Throws` handler and performs `Throws.throw` (kind=2)
  into it (`__qz_effect_perform` longjmps to the handler's setjmp buf), instead
  of the bare `unreachable`. Completes the freestanding side of B.9 Phase 2
  (hosted-only before). Precedence: installed Throws handler > `@panic_handler`
  (kernel `panic_halt`) > halt. Hosted-neutral; fixpoint-safe.
- **B.5e.8b** — `mir_emit_actor_poll_body` (freestanding) wraps the recv loop in
  a per-goroutine Throws boundary (`mir_emit_handle_install` + `handle_uninstall
  _done_only`, no-op handler `@__qz_actor_throws_noop` + its own jmpbuf). On a
  handler panic, the longjmp lands back at the poll's recovery prologue (clean
  orphaned reply, notify links `-2`/monitors `-3`) and loops back to recv —
  **recover-in-place, matching hosted `pc_actor_restart`**. The actor drops the
  in-flight message and keeps serving.

**Kernel-boot-proven:** new `[B.5e8]` smoke (`actor Recoverable` whose `poison()`
handler `panic`s, between `bump()` calls) → `[B.5e8] actor survived panic
count=3 ok` (boot `-m 16G`; 6G OOMs at the 16M-task PMM pool). All prior B.5
smokes green; full boot to "Listening on port 80 (supervised)"; no fault. Guard
fixpoint gen1==gen2 (2615 fns); hosted byte-identical (Stage 2 == Stage 1; the
only delta vs the pre-b5e8 golden is the documented benign `@__qz_gen_yield
_capture` define from B.5e.8a, which fixes a dangling ref — strictly more valid).

#### B.5e.8c — real `std/actor.qz` Supervisor restart-on-crash end-to-end (SHIPPED 2026-06-03)

The *full* "Supervisor restarts 3×" half of the B.5 criterion now runs in the
kernel. `tools/baremetal/hello_x86.qz` gained `actor B5cChild` (crashes via
`actor_die(0)`) + `b5e8c_driver` (drives `supervisor_new` over it, crashes it
3×). Kernel-boot-proven: `[B.5e8c] supervisor restarts=3 ok`, all 14 prior B.5
smokes green, **full boot to `Listening on port 80 (supervised)` with 0 faults**
(`-m 16G`). Importing `std/actor` into the kernel for the first time surfaced six
freestanding gaps — each a hosted-only codegen path that needed a freestanding
twin (full detail: `docs/design/B5E8_FREESTANDING_ACTOR_PANIC_RECOVERY.md`
"Stage 3 — DONE"):

1. **`await` (non-async) → `kern_await`** (`mir_lower_gen.qz`): freestanding
   `async f()` returns a kernel TASK pointer, not an async frame, so completion
   is `task_state` DEAD/FREE, not `frame[0]==-1`. Delegates to a new kernel
   `kern_await(t)` helper (used by `supervisor_stop`'s `await sup.watcher`).
2. **`sched_spawn` → no-op** (`cg_intrinsic_conc_sched.qz`): the `async f(args)`
   handle was already `task_alloc`'d + `ready_push`'d (B.5e.2-5); the hosted
   pthread-deque body would double-spawn.
3. **`waiter_register`/`waiter_unregister` → `kernel_waiter_*`**: route to the
   kernel active-wake table (the close-event subscription the watcher needs).
4. **`qz_rand_range`/`qz_rand_int`** (`codegen_runtime.qz`): lifted the pure-IR
   xoshiro256** bodies + state globals into the freestanding decl block (backoff
   jitter; dead unless opted in, present to link).
5. **`sched_sleep` (non-async) → B.4 suspend-park**: `@usleep` is absent and a
   `yield_now` would deadlock `sched_pump` (perpetually-READY watcher). Parks via
   `__qz_effect_suspend`. **KNOWN LIMITATION:** event-park, not timed — ignores
   the `ms`; fine for the watcher (active-wake + initial scan), but a non-async
   `sched_sleep` with no wake source parks forever (filed: kernel ms-timer wake).
6. **`chan_close` close-event wake** (kernel source): added
   `kernel_waiter_wake_all(ch | 2)` (CLOSE_EVENT_BIT=2) — `chan_close` only drained
   `CHAN_RECV_WAIT` before, so a parked watcher never woke on a child crash. **The
   load-bearing fix** (first crash caught by initial scan; subsequent crashes hung
   without it).

Gaps 1-5 are freestanding-only compiler branches → hosted byte-identical,
fixpoint 2615 preserved by construction. Note: a *bare panic* still recovers in
place (B.5e.8a/b) and does NOT reach the supervisor — matching hosted; supervisor
restart is inbox-close-driven (`actor_die`/`stop`), exercised here.

**Filed forward from B.5e.8c:** (a) a real kernel ms-timer so non-async
`sched_sleep` is a true timed sleep (today's event-park breaks jittered backoff
under load); (b) active-park `kern_await` (register_waker + B.5c DEAD-branch wake)
to drop its busy-yield; (c) `supervisor_set_backoff` end-to-end in the kernel
(needs (a)).

### B.6 — TcpStream + TcpListener Scoped impls in kernel — **MERGED INTO PHASE 8a (2026-05-24)**

**Status**: ⚠️ **Re-evaluated 2026-05-24. Original framing was wrong.
Absorbed into Phase 8a (kernel fd-emulation layer). See D11_HTTP_SERVER_MIGRATION.md
Phase 8a for the new shape.**

**What the original framing got wrong.** The memo said
"on `release`, call the kernel's `tcp_close(fd)` (already in tree)".
**There is no `tcp_close(fd)` in the kernel** — kernel TCP is packet-level
slot-based (`tcp_*` machinery in `hello_x86.qz`, ~2 200 LoC: `tcp_send(slot,
seq, ack, flags, buf, len)`, `tcp_accept_syn`, `tcp_free_slot(slot)`, slot-
lookup via `tcp_find_slot(ip0..ip3, port)`). There is no fd, no
`tcp_listen`, no `tcp_accept` returning fd, no `tcp_read`/`tcp_write` on
fd. "Listening" is implicit: `tcp_handle_ipv4` checks `dst_port == 80`.

The userland `with tcp_listener_scoped(listener) do l_fd -> body end`
requires `listener` to exist FIRST, which requires a freestanding
`tcp_listen() -> ListenResult<TcpListener>`. The Scoped impl's `release`
needs a freestanding-meaningful `tcp_close_listener`. Both require the
fd-emulation layer that the original memo deferred to Phase 8.

Consequently: **B.6 is not separable from Phase 8.** It's a ~10-line
subroutine inside the bigger work of building an fd↔slot adapter layer
in the kernel. The original ~0.5 qd estimate was based on the
"already in tree" premise; that premise is false.

**New shape**: B.6's deliverables move into **Phase 8a** (kernel
fd-emulation) in D11_HTTP_SERVER_MIGRATION.md. The Scoped impls become
a ~10-line piece inside Phase 8a's `@cfg` branches in `std/net/tcp.qz`,
once `tcp_listen` / `tcp_accept` / `tcp_close` exist in freestanding.

**Re-evaluation rationale**: the user (matt) flagged this after Phase
2d Bug 4 fix put the `with tcp_listener_scoped` wrappers into production
use in `http_serve_supervised` / `https_serve_supervised` (commits
`5126d115` + `0faa9bf1`). With the wrappers load-bearing in userland,
the next question was "what does it take for the kernel to consume the
same wrapper-using code?" — and the answer is the full fd-emulation
layer, not just a Scoped release body.

## Total estimate

| Phase | Description | Sized |
|---|---|---|
| **B.0** | This memo | ✅ 0.5 qd shipped (`acc477df` + `6088f0bc`) |
| **B.1** | Per-task effect stack | ✅ shipped (B.1.a `b9cd73b0` + B.1.b `8e6707fb`) |
| **B.2** | setjmp/longjmp in libc_stubs.c | ✅ shipped (`506575e8`) |
| **B.3** | `@__qz_effect_perform` + Throws via real longjmp | ✅ shipped (`2463ee4e`) |
| **B.4** | `@__qz_effect_suspend` + park/wake bridge | ✅ shipped (`a568847d`) |
| **B.5** | Selectable / Actor / Supervisor smokes | partial — B.5a-d.1 shipped (`12dd67f6` / `c0c0f3a8` / `8bbb4e96` / `cef98bd0`); **B.5e.2 explicit-async zero-arg freestanding lowering → `go_fn` shipped 2026-06-02**; **B.5e.3 arg-passing async/go → `kern_go_closure` + single-file synthesis-gate fix shipped 2026-06-03**; **B.5e.4 `go`-surface freestanding spawn (drop spurious perform after kernel spawn) shipped 2026-06-03, kernel-boot-proven `[B.5e3-go] ... ok`**; **B.5e.5 `go do ... end` lambda-surface freestanding spawn via `_mir_fs_spawn_lambda` shipped 2026-06-03, kernel-boot-proven `[B.5e5-lambda] ... ok` — entire spawn surface now lowers to real kernel goroutines**; **B.5e.6 four Actor+Supervisor runtime intrinsics freestanding fork shipped 2026-06-03 (`92dd00ad`)**; **B.5e.7 real `actor ... end` running freestanding shipped 2026-06-03 — `$poll` Future fork (`mir_emit_actor_poll_body`/`mir_lower_actor_poll_freestanding`) + `kern_go_closure` spawn + kernel `chan_try_recv`/`chan_try_recv_or_closed`/`qz_vec_remove` + `time_epoch_ms` `@cfg` fork; kernel-boot-proven `[B.5e7] real actor count=3 ok`**; **B.5e.8a/b actor panic-recovery hook shipped 2026-06-03 (`f55906b6`/`ce342e31`), kernel-boot-proven `[B.5e8] actor survived panic count=3 ok`**; **B.5e.8c real `std/actor.qz` Supervisor restart-on-crash end-to-end shipped 2026-06-03 — six freestanding gaps closed (`await`→`kern_await`, `sched_spawn` no-op, `waiter_*`→`kernel_waiter_*`, freestanding `qz_rand_*`, `sched_sleep`→suspend-park, `chan_close` close-event active-wake); kernel-boot-proven `[B.5e8c] supervisor restarts=3 ok` + full boot to `Listening on port 80 (supervised)` — B.5 success criterion now fully met freestanding** |
| **B.6** | TcpStream / TcpListener Scoped impls | ⚠️ MERGED INTO PHASE 8a — see D11_HTTP_SERVER_MIGRATION.md |
| **Bridge total** | | **~6 quartz-days shipped; full `go`/`async` spawn surface done in freestanding (B.5e.5); only B.5e Actor + Supervisor intrinsics filed forward** |

After Phase 8a ships, Phase 8b consumes `http_serve_supervised` end-to-end
in the kernel; Phase 8c deletes the hand-rolled HTTP code; Phase 9
closes out docs + SOUL.7 deploy. Bridge sub-epic is otherwise complete.

## Open questions

1. **Per-task TASK_STRUCT_SIZE growth.** Original sketch assumed 5 new
   u64s (80 → 128). The corrected save/restore-on-switch strategy
   needs 12 slots (4 scalars + 7 ptr-bases + snapshot reserve) =
   11 × 8 = 88 B → 80 + 88 = 168 B → round to **192 B (3 cache lines)**.
   B.4 adds park_rv inside the existing 176..191 reserved range. B.5
   adds park_deadline in the same range (still 192). If subsequent
   phases push past 192, grow to 256 in one step.

2. **Effect stack array size at scale.** 256 slots × 8 B × 7 arrays =
   14 KiB per task. At 5M tasks (SOUL.5 v6+ stretch) this is 70 GiB —
   prohibitive. **Decision: ship B.1 with cap=256 (hosted parity), file
   forward "compact array layout for high-task-count workloads" as a
   B.x.1 stretch phase**. Compaction options: u8 stack-index + u32
   table-id (4 B/entry instead of 8) gets us to ~3 KiB/task; u8+u8
   gets us to 1.5 KiB/task. Pick at the time, with measurements.

3. **Cross-CPU effect-stack visibility.** A goroutine spawned via
   `go fn()` may migrate between CPUs at every yield. Hosted's
   spawn-snapshot mechanism captures the parent's stack at spawn time
   and applies it at $poll. Freestanding goroutines have *no $poll* —
   they run on real seeded stacks, with `switch_to` saving/restoring
   `rsp`. **Decision: store the snapshot pointer in `task.SNAPSHOT`
   slot at `go_fn` time; the seeded stack-init prepends an "apply
   snapshot" prologue that copies once before the first instruction
   of the user-provided entry_fn**. Document in B.1.

4. **Deadline timer mechanism.** Hosted uses `pthread_cond_timedwait`
   for park-with-deadline. Freestanding doesn't have condvars (kernel
   timer interrupts would work but aren't yet wired into the scheduler).
   **Decision: B.5 implements deadline via the existing kernel-side
   `uk_time_mono_ns` poll inside `sched_pump` — every loop iteration
   checks `task.PARK_DEADLINE` of BLOCKED tasks; expired ones wake**.
   This is the same model SOUL.6 deadline demo uses today; B.5 just
   moves the deadline storage from `g_demo_deadline_target_ns` (process-
   global) to `task.PARK_DEADLINE` (per-task). Real timer-interrupt
   wake is a Phase B.x.2 follow-on if measurements justify it.

5. **Kernel-side signal handling.** Userland's `signalable(SIGTERM)`
   has no freestanding analog. **Decision: kernel's `__qz_sigsignalable_*`
   path always returns `try_poll → false / register_waker → no-op`**,
   making the SIGTERM arm of any select effectively dead in the kernel.
   The userland code in `http_serve_supervised` that uses
   `signalable(SIGTERM)` for graceful shutdown gets equivalent behavior
   in the kernel via `scope_cancel(root)` from the kernel's shutdown
   path (`uart_shutdown` or `__qz_panic`).

6. **Per-task effect-stack page pool.** Allocating 16 KiB strips lazily
   from `pmm_alloc_page` and returning them to a freelist works, but
   the PMM bump can't reclaim — strips that were freed back to the
   intrusive freelist *are* reused, but the underlying PMM pages stay
   pinned. **Decision: ship that** — the strip is bounded by max
   concurrent tasks-with-effects-installed (≤ 32 768), so total page
   commitment caps at 512 MiB regardless of churn. Fine for the unikernel
   workload.

## Risks

- **Effect-stack page-pool warmup pressure.** First task to install a
  handler post-boot needs 4 PMM pages. If many tasks install in a tight
  loop pre-warmup, PMM is consumed faster than expected. **Mitigation**:
  warm the pool with 256 strips at `uk_sched_init` boot — 4 MiB upfront,
  serves 256 simultaneous handler-using tasks without further PMM hits.

- **setjmp/longjmp + goroutine stack.** Goroutines have their own
  8 KiB stacks (`TASK_STACK_PAGES = 2`); `longjmp` restores `rsp` to a
  saved value, which must be a value valid within *that goroutine's*
  stack. If `setjmp` was called in goroutine A's frame and `longjmp`
  fires from goroutine B's frame (i.e., the handler ran on a different
  worker after a context switch), the restored `rsp` points into A's
  stack while CPU is running on B's stack — corruption. **Decision**:
  same UB rule as hosted (`buf=0` for inherited entries). Kernel
  goroutines that call `with Throws` install a *fresh* Throws handler
  per goroutine; cross-goroutine throw doesn't unwind. Phase B.3 spec
  smokes this UB rule explicitly.

- **OBSOLETED by access-strategy correction (2026-05-24).** The original
  "every access goes through `kern8_gs_load_u64` → `__qz_current_task()`"
  risk no longer applies. Corrected strategy keeps user-IR scalar
  accesses unchanged (process-global symbols); only runtime functions
  do an extra `load ptr, ptr @sym` once at entry to resolve array bases.
  Save/restore on context switch is the per-task isolation mechanism,
  not gep-through-current-task. See "Access strategy" + "Why save/restore
  VALUES on switch" sections above.

- **K8 SMP per-CPU readiness.** B.4 assumes `sched_current()` returns
  the correctly-running task even when GS-base is mid-swap. The K8.2
  per-CPU page setup happens before any goroutine spawns, and GS is set
  before any task is on a CPU's ring. Should be safe. **Mitigation**:
  B.4 smoke runs under `-smp 2` to catch any race in the bridge layer.

- **Quartz codegen branch sprawl.** `cg_emit_effect_runtime` is already
  ~1 700 LoC of inline IR emit. Adding freestanding equivalents that
  differ on per-task vs TLS array access could double it. **Mitigation**:
  refactor `cg_emit_effect_runtime` into a `cg_emit_effect_runtime_inner`
  helper parameterized by the array-access strategy (TLS gep vs per-task
  gep), then the freestanding branch calls `_inner` with the per-task
  strategy. ~50 LoC of refactoring; no semantic change to hosted.

## Success criteria

- B.1 lands → kernel boots, install/uninstall round-trip works per-task
- B.2 lands → setjmp/longjmp round-trip in libc_stubs.c works
- B.3 lands → `throw inside with Throws { throw: h } do ... end` catches;
  unhandled throw panics + halts
- B.4 lands → goroutine A parks on `scope_cancel`; scope_cancel from main
  wakes A within < 1 ms (matches hosted's sub-ms cancel cascade)
- B.5 lands → Actor receives 3 messages; Supervisor restarts 3 times
  with backoff; deadline_ms / awaitable / cancellable all observable
- ~~B.6 lands → TcpListener Scoped impl closes fd on body exit~~ MERGED
  INTO PHASE 8a (see D11_HTTP_SERVER_MIGRATION.md). B.6's deliverable
  is a 10-line piece inside the fd-emulation layer; can't be smoked in
  isolation because there's nothing to listen-on / accept without the
  full adapter.
- B.1–B.5 smokes green ⇒ Phase 7 effect bridge ✅; Phase 8a unblocks
  the userland-stdlib-in-kernel consumption.

## Pairing with other tracks

- **SOUL.5 scaling push** (32 K → 1 M → 5 M tasks) can proceed in parallel
  with the bridge work. At 5 M tasks the per-task effect-stack page-pool
  needs compaction (Open Question 2); B.x.1 follow-on phase handles that.
- **SOUL.6 micro-demos** stay on kernel-level primitives through B.6;
  Phase 8 swaps demo bodies one-line to the language-level surface.
- **NET.5 TLS in unikernel** is independent of the bridge — the unikernel
  already has WireGuard via `std/net/wireguard/*`; HTTPS in the kernel
  would need a TLS stack which the kernel doesn't have today. Deferred
  past Phase 9.

## See also

- [`D11_HTTP_SERVER_MIGRATION.md`](D11_HTTP_SERVER_MIGRATION.md) — the
  parent design memo this is sub-epic Phase 7 of. Userland Phases 0–6
  shipped 2026-05-23–24 ([d.11 phase 0] `e7ef6dac` through [d.11 phase 6]
  `ac1c7bfb`); freestanding bridge is the remaining ~7 qd before Phase 8.
- [`SCOPE_UNIFICATION.md`](SCOPE_UNIFICATION.md) — B.7 scope tree design;
  the kernel-side `current_scope_load/store` lower to per-task slot via
  this bridge.
- [`SCOPED_RESOURCES.md`](SCOPED_RESOURCES.md) — B.8 `Scoped` trait + impl
  matrix; B.6 adds TcpListener/TcpStream kernel-side Scoped impls.
- [`SELECT_UNIFICATION.md`](SELECT_UNIFICATION.md) — C.13 unified `select`;
  every `Selectable` impl works in the kernel after B.4 (suspend/wake)
  + B.5 (impl-level verification).
- [`ACTOR_MODEL.md`](ACTOR_MODEL.md) — C.14 Actor + Supervisor; B.5
  verifies both work in the kernel context.
- [`KERN_8_SMP.md`](KERN_8_SMP.md) — per-CPU page layout + GS-base
  conventions. B.1.1 (filed forward — SMP race fix) moves the
  process-global effect-stack scalars + ptr-bases into per-CPU page
  slots via GS-base. B.1 itself does not yet need this.
- [`SOUL_OF_QUARTZ.md`](../SOUL_OF_QUARTZ.md) — bridges to Phase 8
  unikernel migration, which is what makes the Soul page's "structured
  concurrency" demos run on the *actual* language-level surface the page
  is explaining.
