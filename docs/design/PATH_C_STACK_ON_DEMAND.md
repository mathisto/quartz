# Path C — Stack-on-Demand Scheduling

> **Status (2026-05-31):** C.1+C.2 BUILT + tested — correct but insufficient
> (premise falsified, see §9). Pivoted to **C.5 copying stacks** (§10), the real
> fix. **C.5.1 (ss_alloc/ss_free allocator) BUILT + verified** (SS 12/12 boot
> smoke). **C.5.2 (switch-core copy-in/out) BUILT + GATE GREEN (2026-05-31)** —
> single shared active stack + copy-in/out in the switch path; C.1 pool deleted;
> C-side layout mirrored. Local QEMU/TCG gate at NUM_TASKS=4M / -m 6G: boot +
> SLAB 15/15 + SS 12/12 + sched_demo (alive=0) + chan_demo + mutex_demo
> (counter=2000, the BLOCKED→copy-out→wake→copy-in path) + HTTP 200 ×2 +
> spawn n=1000 (drains to 0) + cascade n=512 (512/512) + cascade n=1000
> (1000/1000) + deadline 8/8 + race 8/8 — **ZERO faults, zero strand**; whole
> run consumed ~316 KB of ss buffers (the copying-stack memory win). Two
> findings during the gate, both resolved (see §9.1, §9.2). NOT yet deployed;
> C.5.3 (cross-task-escape audit + HTTP-under-load soak + throughput curve on
> lovelace KVM) is next. C.1+C.2 substrate backed up at
> `/tmp/hello_x86.c1c2-substrate.qz`.
>
> **⚠ C.5.2 is SINGLE-CPU ONLY.** One shared active stack ⇒ two CPUs cannot both
> run a task. APs are parked (do not `sched_pump`) under C.5.2 — the kernel is
> single-scheduler regardless of `-smp N`. Per-CPU active stacks + migration is
> the SMP phase (§10.4 #4). Do not restore AP pumping until then.
> **Goal:** Decouple task capacity from RAM so the unikernel scales to 10M+
> tasks on the current box, instead of ~1 task per ~4.3 KiB of pre-reserved stack.
> **Baseline:** the 524k→2M→4M brute-force scale-up
> (`docs/handoff/2026-05-31-unikernel-4M-scale-up.md`). Throughput is *sublinear*
> (4× tasks for <4× time) — the scheduler is NOT the bottleneck; per-task stack
> pre-reservation is. That's the signal Path C is the right next move.
> **Supersedes the sketch in** memory `feedback-path-c-stack-on-demand-needed-for-1m`
> (written for the Hostinger VPS; numbers here are re-derived from the real
> lovelace code).

## 1. The problem, measured

At `NUM_TASKS = N`, the unikernel pre-allocates at boot (all from PMM, all in
`uk_sched_init`, `tools/baremetal/hello_x86.qz`):

| Structure | Size | At N=4M | Scales with |
|---|---|---|---|
| **Per-task stacks** | thin: 1 page (4 KiB) × (N−4096); fat: 4 pages × 4096 | **~16 GB** | capacity (N) ← the elephant |
| Task struct pool | `TASK_STRUCT_SIZE`=200 B × N | ~800 MB | capacity (N) |
| Normal ready ring | `NUM_TASKS × 8` B | 32 MB | capacity (N) |
| Hi ready ring | `NUM_TASKS × 8` B | 32 MB | capacity (N) |
| Effect strip pool | 256 warm strips × 16 KiB | 4 MB (fixed) | — |

Measured peak PMM at a full 4M burst: **18.1 GB** — dominated by the 16 GB of
stacks. Linear in N: 8M ≈ 36 GB, 16M ≈ 72 GB → host (124 GB) caps out ~12–14M.

**The stacks are 99%+ waste.** Every slot reserves a stack up front, but a stack
is only *live* while a task is `RUNNING` or `BLOCKED` mid-body. On a single CPU,
exactly **one** task is RUNNING at any instant. Freshly-spawned `READY` tasks
that haven't run yet hold a stack they aren't using; exited tasks' stacks sit
idle until the slot is reused.

The soul demo makes this stark: `spawn?n=4000000` enqueues 4M bodies, each of
which runs a tiny body and exits almost immediately. At any instant ~1 is
RUNNING, ~0 are BLOCKED — yet we've reserved 4M × 4 KiB = 16 GB of stack.

## 2. The insight

A cooperatively-scheduled task needs a stack only between **schedule-in** and
**schedule-out**:
- **READY, never run** (just spawned): needs `entry_fn` + arg, NOT a stack. A
  stack is leased when the scheduler first switches to it.
- **RUNNING**: holds a leased stack (≤ #CPUs concurrently; single-CPU MVP = 1).
- **BLOCKED mid-body** (parked in `chan_recv`/`mutex`/`sched_sleep` with live
  frames): must *retain* its stack — it has a frozen call stack to resume.
- **DEAD/exited**: returns its stack to the pool immediately.

So the live stack count = `RUNNING (≤ NCPU) + BLOCKED-with-frames`. That's
bounded by **concurrency**, not **capacity**. The stack pool can be a few
thousand stacks shared across millions of tasks.

### What this costs at 4M / 16M
| | Today | Path C |
|---|---|---|
| Stacks | N × 4 KiB | `STACK_POOL` × 16 KiB (e.g. 4096 × 16 KiB = 64 MB, fixed) |
| Task structs | N × 200 B | N × 200 B (unchanged) |
| Rings | N × 8 × 2 | N × 8 × 2 (unchanged; see §5) |
| **4M total** | **~18 GB** | **~900 MB** |
| **16M total** | ~72 GB (won't fit) | **~3.5 GB** |

16M becomes tractable on the *current* 48 GB VM. 50M+ on a bigger one.

## 3. Current code touchpoints (verified, `tools/baremetal/hello_x86.qz`)

- **`TASK_STACK_BASE` (slot+16)** — "pre-assigned stack (never changes for slot
  lifetime)." Today set once at boot. Path C: becomes a *lease slot*, 0 when the
  task holds no stack.
- **`uk_sched_init`** (~6862) — the two boot loops that `pmm_alloc_page()` a
  stack per slot (fat then thin). Path C: delete the per-slot stack allocation;
  build a separate **stack freelist** instead.
- **`task_alloc` / `task_alloc_thin`** (7108 / 7181) — pull a struct off the
  freelist. Unchanged except they no longer imply a stack.
- **`go_fn_thin` / `go_fn` / `go_fn_hi`** (8481–8523) — today: `task_alloc` →
  `task_stack_base(t)` → `task_init_stack(stack, entry_fn)` → `set_saved_rsp` →
  `ready_push`. Path C: do NOT init a stack here. Store `entry_fn` in
  `TASK_ENTRY_FN`, mark "needs first-run stack," `ready_push`. Stack init moves
  to first schedule-in.
- **`sched_tick` / `sched_pump` / `switch_to`** (6823 / 8714 / 8627) — the
  switch path. Path C: on switching *to* a task, if it has no stack (`TASK_STACK_BASE==0`),
  lease one and seed it (first-run) or it already holds one (resumed). On
  switching *away* because the task **exited**, return its stack to the pool. On
  switching away because it **blocked**, keep the stack.
- **`task_free`** (7218) — return the struct to the freelist. If the slot still
  holds a leased stack (exited while RUNNING — the normal demo case), return the
  stack to the stack pool here.
- **`TASK_STATE`** (slot+0) — FREE/READY/RUNNING/BLOCKED/DEAD already exist;
  the lease/return decisions key off the RUNNING→{DEAD,BLOCKED} transition,
  which is already where `switch_to(... main_rsp)` happens.

## 4. Design

### 4.1 Stack pool
A fixed pool of `STACK_POOL_SIZE` stacks (start 4096 × 16 KiB = 64 MB; tune).
Intrusive freelist threaded through the first 8 bytes of each free stack (same
pattern as `TASK_NEXT_FREE`). Two operations:
- `stack_lease(): Int` — pop a 16 KiB stack base; `0` if exhausted.
- `stack_return(base: Int): Void` — push back; (optionally re-stamp the canary).

One size class (16 KiB) is simplest and removes the fat/thin split entirely — a
leased stack is always big enough. (The thin/fat distinction existed only to
shrink the *pre-reserved* cost; once stacks are leased on demand, that cost is
gone and we can give every running task a comfortable 16 KiB.)

### 4.2 First-run vs resume
- **First run** (`TASK_STACK_BASE==0`, never executed): `switch_to`-in leases a
  stack, calls `task_init_stack(base, entry_fn)` to seed the initial frame,
  stores base in `TASK_STACK_BASE`, sets `saved_rsp`.
- **Resume** (was BLOCKED, `TASK_STACK_BASE!=0`): stack already held, just
  `switch_to(saved_rsp)`. No lease.
- **Block** (RUNNING→BLOCKED): keep `TASK_STACK_BASE`; the parked frames live on.
- **Exit** (RUNNING→DEAD): `stack_return(TASK_STACK_BASE)`, set it to 0, then
  `task_free`.

### 4.3 Stack exhaustion = back-pressure
If `stack_lease()` returns 0 (more tasks want to run concurrently than the pool
allows), the scheduler leaves the task on the ready ring and moves on — it gets
a stack next time one frees. This is correct cooperative back-pressure: a task
that can't get a stack simply hasn't been scheduled yet. (For the soul demo this
never triggers because bodies exit instantly; for pathological all-block
workloads it bounds memory instead of OOMing — a feature.)

## 5. What Path C does NOT fix (and why that's OK)

- **Ready rings stay `NUM_TASKS`-sized** (8 B/slot × 2 rings = 64 MB at 4M).
  This is intrinsic: `spawn?n=4M` genuinely enqueues 4M READY tasks, so the ring
  must hold them. It's cheap (8 B vs 4 KiB — 512× smaller than the stack win) and
  shrinking it would require bounded-spawn semantics, a different feature. Leave it.
- **Task struct pool stays N × 200 B** (800 MB at 4M). This is the irreducible
  per-task cost and is already small. A future "Path D" could page the struct
  pool, but there's no pressure until ~100M tasks.

## 6. Risks / things to get right

1. **Blocked-task stack retention.** The single sharpest correctness point: a
   task blocked mid-body MUST keep its stack, or resume reads freed memory. The
   lease/return logic keys strictly on the RUNNING→DEAD edge (return) vs
   RUNNING→BLOCKED edge (keep). Both edges already exist in the switch path.
2. **The `task_alloc` zeroing dance.** `task_alloc` already re-zeros ~15 slots
   because freed bytes aren't re-zeroed (see the long comment at 7108, and the
   KERN.SLAB.2 stack-frame-corruption history). `TASK_STACK_BASE` must be added
   to the zeroed set so a reused slot never inherits a stale stack pointer — same
   class of bug as `TASK_ARENA_HEAD`.
3. **Stack reuse hygiene.** A returned stack carries the previous task's frames.
   First-run re-seeds from the top via `task_init_stack`, so stale bytes below
   the seeded frame are unreachable — but the canary at `stack_base+0` should be
   re-stamped on lease to keep the overflow detector honest.
4. **SMP-readiness.** Single-CPU MVP: `stack_lease`/`return` need no lock (one
   scheduler). When K8.8 SMP lands, the stack freelist needs a spinlock (or
   per-CPU stack caches), exactly like the ready rings. Note it; don't build it.
5. **No regression in the throughput curve.** The lease/return adds two freelist
   ops per task lifetime. Must stay off the hot path's critical section; verify
   the 1M/2M/4M curve doesn't regress after the change.

## 7. Phasing

- **C.0** — this doc. ✓
- **C.1** — stack pool: `stack_lease`/`stack_return` + freelist init in
  `uk_sched_init` (replacing the per-slot stack loops). Keep `go_fn*` seeding a
  stack immediately at first (lease at spawn, not at schedule-in) — a smaller,
  testable step that already drops the *thin-pool* pre-reservation. Measure.
- **C.2** — move the lease to schedule-in / return to exit in the switch path;
  add `TASK_STACK_BASE` to the `task_alloc` zero-set; block-retention logic.
  This is the real win. Throwaway-test at 4M, confirm peak PMM drops from ~18 GB
  to <1 GB.
- **C.3** — push capacity: `NUM_TASKS` 8M → 16M, throwaway-test, deploy. Should
  fit the current 48 GB VM comfortably.
- **C.4** — (optional) tune `STACK_POOL_SIZE`; collapse fat/thin split.

## 8. Build/deploy/verify

Same pipeline as the scale-up handoffs (NOT `self-hosted/*.qz`, so no
`quake guard`; `baremetal:build_elf` is the gate):
1. Edit `hello_x86.qz`; clear caches (`rm -rf tmp/qzmod tmp/baremetal/*.ll
   tmp/baremetal/quartz-unikernel.{o,elf} tmp/baremetal/boot_trampoline_x86.o`).
2. `quake baremetal:build_elf`; sha-diff vs live.
3. Throwaway-boot at target `-m` on a spare hostfwd port; spawn full NUM_TASKS;
   confirm peak PMM dropped, capacity correct, 0 real faults (exclude "SLAB 15/15"
   self-test line from the fault grep).
4. Atomic prod swap with `.prev` backup; verify 5 hosts + burst + journal.

**Acceptance test for C.2:** at `NUM_TASKS=4M`, `-m 14G` (the size that was
UNSAFE for brute-force 2M), a full 4M burst completes with peak PMM well under
the 7 GB ceiling and 0 faults. If that passes, Path C is proven — capacity is
decoupled from RAM.

## 9. C.1+C.2 implementation findings (2026-05-31) — premise falsified

C.1+C.2 (shared pool of `STACK_POOL_SIZE`=8192 16-KiB stacks, leased at
schedule-in, returned on DEAD; lease/return + back-pressure) was built and
locally smoke-tested under QEMU/TCG (`NUM_TASKS=4M`, `-m 4G`).

**What worked (verified):**
- The kernel **boots 4M-task capacity in 4 GB** — the per-slot binary needed
  ~18 GB just to boot that. Struct capacity *is* decoupled from RAM.
- The lease/return mechanism is correct: `lease_total − return_total ==
  stacks.alive` exactly, `stacks.alive_max` never exceeds the pool, ~41k
  lease/return cycles, **zero faults**, no canary/stale-pointer trips.

**What this falsified — the §2 premise is wrong for the soul demo:**
The insight in §2 assumed bodies "exit almost immediately ... at any instant ~1
RUNNING, ~0 BLOCKED." But `soul_demo_body` (hello_x86.qz, `SOUL_DEMO_LIFETIME_NS
= 2_000_000_000`) **busy-yields against a 2-second wall-clock deadline**, holding
its leased stack the entire 2 s. A yielding task goes RUNNING→READY→RUNNING and
**retains** its stack. So for this workload **"concurrently stacked" ==
"concurrently alive,"** NOT a small constant. Consequences, both observed:

1. **No win for the soul demo.** Only `STACK_POOL_SIZE` tasks can be alive-with-
   a-stack at once; the rest are READY-without-stack and drain in *waves*.
   Draining 4M would take ~488 waves × 2 s ≈ 16 min.
2. **Stack exhaustion starves HTTP (DoS-grade).** When ready-wanting-stacks
   exceeds the pool, the serve loop busy-spins pop→fail-lease→re-push
   (`exhausted` hit 2.3M) and stops serving — stats curls timed out mid-test.

The lease/return *substrate* (schedule-in/out hooks, spawn-site simplification,
`task_alloc` zeroing, telemetry) is correct and reused by C.5. The pool-of-N +
lease-while-parked *policy* is what C.5 replaces.

### 9.1 C.5.2 finding — APs must not pump (single active stack)
The AP idle loop (`ap_main`) ran `sched_pump()` per K8.MVP. With a single shared
active stack that is unsafe by construction (two CPUs can't share one running
stack), so C.5.2 parks APs instead (`sti; hlt; cli` loop, no pump) and logs
`[ap] CPU parked`. The kernel is single-scheduler regardless of `-smp N`. The
real fix — one active stack per CPU + frame-migration handling — is the SMP
phase (§10.4 #4). When it lands, restore `sched_pump()` in `ap_main`.

### 9.2 C.5.2 finding — cascade demo registration barrier
The cascade demo (`/api/soul/demo/cascade`) used a fixed 10 ms "settle" window
between spawning N bodies and firing the cancel signal, assuming all N capture
their `start_gen` baseline within it. That assumption was calibrated to the old
no-copy scheduler. Copying-stack scheduling adds a per-schedule memcpy, and the
hi-priority self-yielding HTTP handler + 4:1 hi:normal fairness mean only ~1/5
of schedules in the window are normal-ring (cascade-body) first-runs — so above
~165 bodies, the laggards never ran before the signal, read the already-bumped
gen as their baseline, and waited forever for a NEXT bump (permanently stranded,
busy-yielding). This is a latent demo race, not a copy-mechanism bug (the copy
is correct: cascade n≤128, plain spawn n=500, and chan/mutex block paths all
round-trip perfectly). Fixed with a **registration barrier**: each body bumps
`g_demo_cascade_registered` after capturing `start_gen`; the handler waits for
`registered == spawned` (2 s safety cap) before signaling. Robust to any
scheduler speed / fairness ratio. Result: cascade n=512 → 512/512, n=1000 →
1000/1000 (baseline only managed 705/1000 — the race hurt it too). NB: the local
gate runs under QEMU/TCG, which inflates per-schedule cost ~10–100× vs lovelace
KVM; the real per-schedule copy overhead must be measured on hardware in C.5.3.

## 10. C.5 — Copying stacks (the real fix)

The waste was never the lease; it's that a *parked* task keeps a full 16-KiB
running-stack when its live frames are tiny (a parked `soul_demo_body` is ~170 B).
The fix is the classic copy-stack coroutine model (Python greenlet, Lua, the
old Go stack-copy): **a big running-stack is occupied only while RUNNING; on
park, copy the used portion out to a right-sized per-task buffer and free the
running-stack; copy back on resume.** Then a parked task costs ~its live bytes,
and 4M parked tasks ≈ 4M × ~200 B ≈ 0.8 GB (same order as the struct pool) —
this is what actually delivers "millions parked cheaply."

### 10.1 Single shared active stack (the key simplification)
On a single CPU exactly one task is RUNNING, so there is exactly ONE live
running-stack at a time. Make it a **single fixed 16-KiB region** at a constant
address `g_active_stack_base` (per-CPU when SMP lands; MVP = one global). Every
task's frames are always built at this same address.

This is what makes copy-stack correct: the saved frames contain absolute
self-references (saved RBP chain, `&local` borrows). Restoring them to the SAME
virtual address (always `active_top - len`, `active_top` constant) keeps every
absolute pointer valid. A pool of >1 would hand back different bases and break
this — so the MVP is deliberately ONE active stack. (SMP: per-CPU fixed actives
+ pin-or-adjust on migration; deferred.)

A single active stack also **eliminates §9's two failures by construction**:
there is no pool to exhaust → no back-pressure spin, no HTTP starvation, no
wave-draining. Every ready task can always run (copy in, run, copy out).

### 10.2 Per-task saved-stack buffer + allocator
Slot layout (as built in C.5.2 — reuses slot 16, bumps `TASK_STRUCT_SIZE`
200 → 216; the earlier draft here said 200/208/216→224 but the implementation
followed §10.3's "verified against C side" layout):
- `TASK_SAVED_STACK_PTR`  (16, was `TASK_STACK_BASE`) — heap buffer holding the
  parked frames, 0 if none (first-run or freed; non-zero while RUNNING if the
  task has parked at least once and not yet exited).
- `TASK_SAVED_STACK_LEN`  (200) — used bytes currently saved.
- `TASK_SAVED_STACK_CAP`  (208) — allocator size-class of the buffer (grow-only).

Saved buffers need a **size-classed sub-page allocator built in Quartz** — NOT
the C `slab_alloc`: that caps at 512 B (frames can reach 16 KiB) AND auto-tracks
into the per-task *request* arena (`libc_stubs.c:313`), which would drain a
saved buffer at request-end → use-after-free. Build `ss_alloc(len)→ptr` /
`ss_free(ptr, cap)` with classes {192, 1024, 4096, 16384}, freelists backed by
pmm pages, threaded intrusively. Grow-only per task: most tasks reach a stable
max in one alloc (`soul_demo_body` → 192-B class, forever). 4M demo bodies ×
192 B ≈ 0.75 GB.

### 10.3 Switch-path changes (on top of the C.1+C.2 substrate)
- **schedule-in** (`sched_lease_stack_if_needed` → `ensure_active_stack`):
  - *first run* (`TASK_SAVED_STACK_PTR==0` && never run): seed the initial frame
    at `active_top` via `task_init_stack(g_active_stack_base, entry_fn)`; set
    `TASK_SAVED_RSP`.
  - *resume* (`TASK_SAVED_STACK_PTR!=0`): `memcpy(active_top − len, buf, len)`;
    `TASK_SAVED_RSP = active_top − len`. (Keep the buffer; it'll be reused/grown
    on the next park, freed on exit.)
- **schedule-out** (`sched_post_switch`, after `switch_to` returns to main):
  - *READY (yield) / BLOCKED*: `len = active_top − TASK_SAVED_RSP`; ensure
    `cap ≥ len` (`ss_alloc`/grow); `memcpy(buf, TASK_SAVED_RSP, len)`; record len.
    The active stack is now free for the next task.
  - *DEAD*: `ss_free` the buffer (if any). Nothing to "return" — the active
    stack is the single shared region.
- **`task_free`**: `ss_free(TASK_SAVED_STACK_PTR, cap)`; zero the 3 slots.
- **`task_alloc`**: zero the 3 saved-stack slots (stale-pointer defense, same as
  the existing zero-set). `TASK_STACK_BASE` (the C.1 per-task lease slot) is
  removed — there is no per-task running stack anymore.
- The C.1 pool (`stack_lease`/`stack_return`/`STACK_POOL_SIZE`/`g_stack_*`) is
  deleted; replaced by `g_active_stack_base` + the saved-stack allocator.

**Slot layout (verified against C side, libc_stubs.c lines 545-552):**
Reuse slot 16 (`TASK_STACK_BASE` → rename `TASK_SAVED_STACK_PTR`); add
`TASK_SAVED_STACK_LEN`=200, `TASK_SAVED_STACK_CAP`=208; bump `TASK_STRUCT_SIZE`
200 → 216. First-run discriminator is `TASK_SAVED_STACK_PTR==0` (never parked ⟺
never ran), so no separate "on active stack" flag is needed.

**C-side touchpoints (libc_stubs.c) — REQUIRED, the layout is mirrored there:**
1. `#define TASK_STRUCT_SIZE` 200 → 216 (line 548). The corruption guards
   compute `task_hi = task_lo + TASK_STRUCT_SIZE` (line 802); a stale value
   false-halts.
2. `qz_arena_begin` stack-overflow canary check (lines 988-1006) reads
   `*(cur_task + TASK_STACK_BASE)` (slot 16) as the running task's stack base.
   In the copy model slot 16 is the *saved buffer* (0 while running), so this
   must instead read the single active-stack base. Add a bridge:
   Quartz `extern "C" def get_active_stack_base(): Int = g_active_stack_base`
   (mirrors `get_pmm_pool_start` at hello_x86.qz:252); C `extern long
   get_active_stack_base(void);`; canary check reads
   `get_active_stack_base()` (the running task IS on the active stack, so its
   canary at active_base+0 is the right thing to check).
3. The diagnostic dump `qz_task_alloc_dirty_check` (line 850) reads slot 16 as
   `stack_base` for debug output only — harmless (shows 0 for a fresh task);
   update the `// TASK_STACK_BASE` comment to `// TASK_SAVED_STACK_PTR`.
4. `memcpy` is already a linked global (libc_stubs.c:1308); Quartz declares
   `extern "C" def memcpy(dst: Int, src: Int, n: Int): Int` for copy-in/out.

**C.5.1 is built + verified** (SS 12/12 boot smoke, covers all 4 classes incl.
the 16 KiB/4-page refill, LIFO reuse, chunk read/write; zero faults). The
allocator (`ss_alloc`/`ss_free`/`ss_class_*`/`ss_refill`/`ss_smoke`) lives in
hello_x86.qz right after the (to-be-deleted) C.1 `stack_return`.

### 10.4 Costs / risks
1. **A memcpy per schedule boundary.** Demo busy-yield ≈ 170 B each way (trivial);
   a deep HTTP handler yielding mid-`_http_access_log` copies up to ~16 KiB, but
   those yield rarely (only on chan_recv for body/tx). Measure the 1M/2M/4M
   throughput curve — risk #5 from §6 still applies.
2. **Cross-task stack-pointer escape (THE correctness risk).** greenlet's known
   limitation: code that stashes a pointer to a stack object somewhere global
   and reads it after another task ran will see corrupted data (the shared
   active stack was overwritten). MUST audit the kernel for any `&stackvar`
   stored outside its own call chain across a yield. The effect strips, arena/
   slab heads, and wait-lists all use heap/struct pointers (safe); `&`-borrows
   passed down-and-yielded within one task's chain are fine (same-address
   restore). The boot self-test (task_a/task_b via `task_slot`) uses its own
   stacks and never touches the active stack — leave it. Canary at active_base+0
   + hard smoke testing catches gross violations.
3. **Inlining hazard avoided by construction:** the copy-out/in run on *main's*
   stack (in `sched_post_switch` / schedule-in), copying the *active* stack —
   never copying the stack they themselves run on. (greenlet must mark its
   save/restore noinline; we don't have that problem.)
4. **SMP:** one active stack per CPU + migration handling. Deferred; noted.

### 10.5 Phasing
- **C.5.1** — `ss_alloc`/`ss_free` size-classed allocator + a standalone smoke
  (alloc/free/grow across classes, freelist integrity). Testable in isolation.
- **C.5.2** ✓ (2026-05-31) — single active stack + copy-in/out in the switch
  path; C.1 pool deleted; slot 16 → `TASK_SAVED_STACK_PTR` + LEN(200)/CAP(208),
  `TASK_STRUCT_SIZE` 200→216 (Quartz + C mirror); `task_free`/`task_alloc`
  wiring; APs parked (§9.1); cascade barrier (§9.2). Gate GREEN: boot, SLAB
  15/15, SS 12/12, `sched_demo`, `chan_demo`, `mutex_demo` (counter=2000),
  HTTP 200×2, `spawn`, `cascade` (512/512, 1000/1000), `deadline` 8/8, `race`
  8/8 — 0 faults, 0 strand.
- **C.5.3** — cross-task-pointer-escape audit + HTTP-under-load soak + throughput
  curve. **Local (TCG) portion done 2026-05-31; KVM portion pending (see §11).**
- **C.5.4** — big-scale validation: spawn 1M→4M, confirm peak PMM tracks
  `struct_pool + saved_buffers` (not waves, not exhaustion), drain completes,
  HTTP stays responsive throughout. Run on lovelace (KVM) — TCG is too slow.
- **C.6** ✓ (2026-05-31) — `NUM_TASKS` 4M→16M (`SOUL_GRID_BUCKET` 1024→4096 to
  keep the grid byte-count fixed); KVM-validated (clean boot at 16M,
  `max_capacity=16777216`, 4M spawn drains fully in ~69s, 0 faults); **deployed
  to prod** (atomic swap of `/opt/quartz/quartz-unikernel.elf`, `.prev-pre-c52-16m`
  backup). Public `soulofquartz.mattkelly.io` serves 200 at 16M; a live 1M-task
  burst kept GET / responsive throughout; **prod RSS dropped ~17.7 GB → ~4 GB
  while 4×-ing capacity.** Still single-CPU.
- **C.5.5 — SMP copying stacks.** Light up all cores. **C.5.5.1/.2/.3 done; KVM
  pure-spawn green; C.5.5.5 deploy ATTEMPTED + FAILED + rolled back — BLOCKED on
  the effect runtime being process-global (not SMP-safe). Fix = C.5.5.6 (§12.7)
  before any SMP deploy. Full detail in §12, esp. §12.6/12.7.** Implemented pin-on-first-run: one active stack PER CPU
  (`PCPU_ACTIVE_STACK_BASE`), a task pins to the CPU it first parks on
  (`TASK_HOME_CPU`) and never migrates (no work-stealing), so it always resumes
  at the same VA (same-address-restore holds per-CPU); unpinned tasks distribute
  to the least-loaded online CPU. Hi ring (HTTP) stays BSP-only. Three new
  allocator locks (pmm/ss/taskpool, ordered TASKPOOL→SS→PMM) make the shared
  allocators SMP-safe; the hot park/resume path stays lock-free (memcpy to the
  task's own buffer). APs gated until after boot demos (`g_ap_sched_enabled`),
  then pump. (Fuller alt for free migration: same-VA-per-CPU via per-CPU page
  tables — deferred.) See §12 + §9.1.

Sources for the copy-stack model: [python-greenlet](https://deepwiki.com/python-greenlet/greenlet),
[greenlet docs](https://greenlet.readthedocs.io/).

## 11. C.5.3 progress (2026-05-31) — local portion done, KVM portion pending

### 11.1 Cross-task stack-pointer-escape audit — DONE for the kernel
The escape risk (§10.4 #2): a pointer to task A's stack stored where task B reads
it while A is parked — B then dereferences A's address, which on the shared
active stack now holds whoever is running. Within-task `&`-borrows passed down
one call chain and yielded are SAFE: copy-in restores the frame to the SAME
virtual address, so the borrow stays valid (this is the whole point of the
single fixed active stack). Only CROSS-task stack-pointer sharing breaks.

Audited every cross-task sharing mechanism in the kernel (`hello_x86.qz`):
- **Channels** — payloads are values/slot-indices/lengths (`chan_send(ch, 1)`,
  `chan_try_send(accept_ch, slot)`, `chan_send(demo, i*100)`). No stack pointers.
- **Waiter side-table** (`kernel_waiter_register`/`_wake_all`) — stores task
  struct pointers (pool memory); `__qz_sched_wake(w)` treats `w` as a task ptr.
- **`PENDING_WAITQ`/`PENDING_LOCK`** — task struct ptrs + spinlock addrs (heap).
- **Effect/throws `jmp_buf`** — lives in the per-task effect strip (heap); read
  only by the owning task when running, and the saved RSP + frame are restored
  to the same address on resume. Safe by the core invariant.
- **Address-of-local scan** — no `&local` borrow stored into any global/heap
  structure anywhere in the kernel (it passes raw PMM/pool addresses, not
  borrows of stack variables).

Conclusion: **the kernel has no cross-task stack-pointer escape.** Backed
empirically — `chan_demo`, `mutex_demo`, the B.5a/b/c/d1 await/channel/wake
smokes, and HTTP-under-concurrency all return correct results with zero faults.

NOT exhaustively line-audited: the full `std/net/http_server` + scoped-resource
subgraph the supervised path pulls in. Those use Quartz `&` borrows, but only
down their own call chains (safe by same-address restore); the KVM
high-concurrency soak (§11.3) is the better instrument to surface any residual.

### 11.2 HTTP-under-load soak (TCG) — correct-when-served, no regression
Concurrent curls (GET / + JSON endpoints) against the supervised server while a
background `spawn` churns demo tasks on the shared active stack. Findings:
- Every serviced response was correct (200 + valid body), **zero faults** — the
  effect-using HTTP path round-trips correctly across yields under churn.
- Under heavy demo load the server became connection-refused (CPU starvation:
  the serve loop can't get wall-clock for accept/RX). **This is NOT a copying-
  stack regression** — the C.1+C.2 baseline binary, run under the identical
  spawn-800 + concurrent-curl load, behaves IDENTICALLY (both 5/30 served,
  25/30 refused, 0 faults). It is the pre-existing demo-vs-HTTP fairness tension
  (`SCHED_FAIRNESS_QUANTUM`), amplified ~10–100× by QEMU/TCG software emulation.
- §9's SPECIFIC failure (C.1 pool-exhaustion busy-spin, `exhausted` climbing) is
  gone by construction — there is no pool.

### 11.3 KVM validation (lovelace, 2026-05-31) — DONE, all green
Ran on the `quartz-unikernel` VM (16 vCPU, 47 GiB, nested `/dev/kvm`) as a
throwaway boot (`-M microvm -accel kvm -cpu max -m 14G`, spare hostfwd port,
prod service untouched). KVM is ~75× faster than the local TCG gate (boot
heartbeat 372K vs ~5K in the same wall-time) — which is exactly why these
numbers had to come from hardware.

**Throughput curve (park rate = Δcopy_total ÷ wall-time):**
| N spawned | park rate | per-task ss | peak parked | qemu RSS | faults |
|---|---|---|---|---|---|
| 200k | 575K/s | 195 B | 121k | 1005 MB | 0 |
| 1M | 597K/s | 195 B | 200k | 1019 MB | 0 |
| 2M | 596K/s | 195 B | 1.0M | 1167 MB | 0 |
| 4M | — | 195 B | 1.2M+ (climbing) | ~1.2 GB | 0 |

**Park rate is flat (~596K/s) across N — copying stacks do NOT degrade with
scale.** Per-task saved-buffer cost is **195 B** (the common-case demo park is
the 192-B class-0 buffer; `copy_max_len=1368` is a rare outlier — the deep HTTP
handler frame — not the bulk). The design's §10.2 projection (~192 B/task) is
confirmed. For reference, the old per-slot brute-force needed ~18 GB to hold 4M;
copying stacks held 4M in **~1.2 GB** (struct pool 864 MB + ss ~195–400 MB +
rings 64 MB) — ~11× reduction, well under the §8 7-GB acceptance ceiling.

**4M scale test:** spawn 4,000,000 → all 4M alive concurrently; saved buffers
climbed 0→1.2M as tasks took their first park; **full 4M drain completed in 58 s,
alive_thin→0, zero faults.**

**KVM HTTP soak:** 64 sequential GET / during a 300k-task churn → **64/64 = 200,
zero refused, zero faults.** The TCG connection-refused starvation (§11.2)
**vanished on real hardware** — it was a software-emulation artifact. §9's
starvation is gone in practice.

**Verdict:** C.5.2 meets the §8 acceptance test (4M burst, peak PMM ≪ 7 GB, 0
faults) and is validated for deploy. Remaining before prod: **C.6** — bump
`NUM_TASKS` (8M→16M now tractable) + atomic prod swap with `.prev` backup +
5-host/burst/journal verify. The prod VM has 47 GiB; at 195 B/task + 216 B/slot
+ 16 B/slot rings ≈ ~430 B/task, 16M ≈ ~7 GB — comfortable. NB still SINGLE-CPU
(APs parked, §9.1); the prod QEMU must not rely on guest SMP for scheduling.

(C.1 baseline throughput comparison was not re-run on KVM — the local TCG A/B
already showed C.5.2 == baseline for HTTP-under-load; the ~596K/s park rate vs
the historically-noted ~680K/s heartbeat baseline implies ~10–15% per-schedule
copy overhead, modest and worth a dedicated A/B if it ever matters.)

## 12. C.5.5 — SMP copying stacks (2026-05-31) — C.5.5.1/.2/.3 done, TCG-green

The epic that lights up all cores. Implemented in three independently-smoked
sub-phases (kernel-only; `tools/baremetal/*`, no `quake guard`). **All three are
TCG-green at `-smp 1/2/4`; KVM validation (C.5.5.4) is still pending and is the
real correctness gate** — TCG serializes memory far more than real hardware and
does not reproduce x86-TSO weak-ordering races, so TCG-green is necessary but
NOT sufficient. Do not deploy (C.5.5.5) before C.5.5.4 is green on lovelace.

### 12.1 The design that shipped — pin-on-first-run, no migration
Per §10.5, copying stacks need one active stack PER CPU (a parked task's saved
frames carry absolute addresses into a specific CPU's active-stack VA, so it
must always resume there). The chosen model is **pin-on-first-run**:

- **Per-CPU active stacks** (`PCPU_ACTIVE_STACK_BASE`, offset 112). One 16-KiB
  canary-stamped stack per CPU, allocated in `kern8_pcpu_init`. `g_active_stack_base`
  (single global) is gone; `active_stack_base()`/`active_stack_top()` read
  `%gs:PCPU_ACTIVE_STACK_BASE`. C-side `qz_arena_begin` canary check reads the
  running CPU's base via `kern8_gs_load_u64(112)` (the old set-once
  `g_active_stack_base_c` + `qz_set_active_stack_base` are deleted).
- **Pinning** (`TASK_HOME_CPU`, byte 51, sentinel 255 = unpinned; no
  `TASK_STRUCT_SIZE` bump). A task pins to the CPU it first PARKS on
  (`sched_park_active_stack` stamps `cpu_local_load(PCPU_CPU_ID)`). `ready_push`
  routes a pinned task back to its home ring; an unpinned (never-parked) task
  distributes to the least-loaded ONLINE CPU (`PCPU_SCHED_ONLINE`, offset 120).
- **NO work-stealing.** `ready_pop` drains only the calling CPU's own ring (a
  CPU-bound parked task cannot run elsewhere). Load is balanced purely at
  push-time. The K8.6 round-robin stealer is removed under copying stacks; the
  migration-capable alternative (per-CPU page tables mapping every active stack
  to one shared VA) is deferred.
- **Hi ring = BSP only.** The global hi ring (HTTP supervised listener +
  per-conn handlers) is consumed only by CPU 0 (`ready_pop` guards
  `self_cpu == 0`), so hi-tier tasks always run on BSP — frames bind to BSP's
  VA, matching KERN.8 D7 (HTTP pinned to BSP).
- **Boot gating** (`g_ap_sched_enabled`). APs spin-wait (hlt) in `ap_main` until
  `main` flips the gate AFTER the cooperative boot demos (which run single-CPU
  on BSP). Then each AP marks itself online and pumps. So boot stays single-CPU;
  parallelism begins at the serve loop.

### 12.2 SMP-safety — the allocator locks (THE correctness work)
The hot per-schedule path (park/resume of an already-parked task) is essentially
LOCK-FREE: it's a memcpy to/from the task's OWN saved buffer (touched only by its
home CPU, since it never migrates). Only spawn/exit-rate operations touch shared
state, so three ordered locks suffice (acquire order **TASKPOOL → SS → PMM**,
the only nest being `ss_alloc → ss_refill → pmm_alloc_page`):

- `g_pmm_lock` — `pmm_alloc_page` bump cursor (BSP HTTP refills + AP ss_refills).
- `g_ss_lock` — `ss_alloc`/`ss_free` freelists.
- `g_taskpool_lock` — `task_alloc`/`task_alloc_thin`/`task_free` freelists +
  `g_task_alive*`/counters. `task_free` does its cleanup (arena drain, strip
  free, `ss_free`) in SEPARATE critical sections so the taskpool lock stays a
  leaf.

All created in `kern8_pcpu_init` (single-threaded, before any AP online); the
`!= 0` guard makes early-boot allocation lock-free. Already-locked structures
reused as-is: per-CPU ready rings, hi ring, channels/mutexes (K8.6.4/5), effect
strip pool (`g_effect_stack_pool_lock`). Audited: every serve-time normal body
(`soul_demo_body` + all SOUL.6 bodies) is malloc/effect-free — only global R/W,
already-SMP-safe spinlocks, rdtsc, and yield — so distributing ALL normal tasks
to APs is safe without a per-task eligibility flag.

### 12.3 TCG results (local, `-m 12G` — the 16M pool needs ≫ the 6G gate)
- **`-smp 1`**: byte-behavior identical to C.6 baseline; demos correct, HTTP
  200×2, counter=2000, 0 faults.
- **`-smp 2`**: spawn 3000 → rings split **1501/1499**; both CPU heartbeats
  advance in parallel; drain to alive_thin=0, exit==spawn, ready→1, no strand;
  GET / stays 200; **0 faults, 0 canary trips** (per-CPU same-address-restore
  holds under real concurrency). All SOUL.6 demos pass (deadline 8/8, race 8/8,
  restart attempt-4, cascade 256/256).
- **`-smp 4`**: spawn 8000 → rings **2001/2000/1999/1998**; all 4 cores online +
  pumping; `/api/soul/cancel` cascade → all 8000 drain (alive_thin→0); HTTP 200
  before+after; **0 faults, 0 canary trips.**

### 12.4 Known holes (filed, not fixed)
- **Park-rate telemetry undercounts under SMP.** `g_ss_copy_total` /
  `g_ss_copy_max_len` are RMW'd unlocked on every park (kept off the hot path
  deliberately — locking them would serialize the lock-free park). Concurrent
  parks lose increments → the `/api/soul/stats.json` park-rate slightly
  undercounts at `-smp N>1`. Telemetry only, no correctness impact. Proper fix:
  per-CPU copy counters summed at read (like `PCPU_HEARTBEAT`).
- **Migration-capable scheduling not built.** No work-stealing means an uneven
  workload (not the uniform soul demo) can leave a CPU idle while another is
  backed up. The fix (per-CPU page tables → one shared active-stack VA → free
  migration) is a separate epic; pin-on-first-run + spawn-distribution is the
  correct MVP for the uniform-body soul workload.

### 12.5 C.5.5.4 KVM validation (2026-05-31) — DONE, GREEN on prod hardware
Ran on the prod host itself (`192.0.2.10`, 16 vCPU, 47 GiB, nested `/dev/kvm`;
the public `soulofquartz.mattkelly.io` is this VM via Cloudflare tunnel — the
running PID is prod, C.6 single-CPU on `:8080`, untouched). Throwaway `-smp`
KVM guests on spare ports, `-m 14G`, the C.5.5.3 ELF (`/root/c55-test.elf`).

- **`-smp 8`, spawn 1M**: 8 CPUs detected, 7 APs online; rings split
  **125001/124999×7** (near-perfect); all 8 heartbeats advance in parallel; **1M
  drain in ~3s** (alive 1,000,005→5, alive_thin→0, exit≈spawn, no strand); GET /
  = 200 before+after; **0 faults, 0 canary trips.**
- **`-smp 12`, spawn 4M**: 12 CPUs, 11 APs online; spawned 4M (peak concurrent
  ~1.5M — early tasks expire mid-spawn at the 2 s lifetime); ready per-CPU
  119K–164K across 12 rings; **full 4M drain in ~4s** (exit_total→4,000,026, no
  strand) vs §11.3's 58 s single-CPU; GET / = 200; **0 faults, 0 canary trips**;
  guest RSS 5.33 GB (16M struct pool 3.46 GB + 12 rings 1.5 GB + ss).

**Verdict (NARROW):** the copying-stack/scheduler core — per-CPU active stacks,
pin-on-first-run, the three allocator locks — holds under genuine 8/12-core
parallelism for the PURE-DEMO-SPAWN workload (no effects). **This is NOT
sufficient for deploy** — see §12.6: the validation did not exercise the effect
runtime under concurrency, and that is exactly what broke in prod.

### 12.6 C.5.5.5 deploy ATTEMPTED 2026-05-31 — FAILED, ROLLED BACK. Blocker: effect runtime is not SMP-safe.
Deployed at `-smp 12` (ELF + unit swapped, `.prev-pre-c55` backups). Boot was
clean (12 CPUs online, HTTP 200, 16M capacity); a 500k burst drained fine. A
**2M burst with the supervised HTTP server running concurrently** wedged the
guest — `GET /` and the public URL hung. Serial showed:
`[EFFECT-RESTORE-WILD-NAMES] task=… v_names=0x129718 …` — a `.rodata` pointer in
a task's `TASK_EFFECT_STACK_NAMES` (slot 88). **Rolled back to C.6 single-CPU**
(restore `.prev-pre-c55` ELF + `.service.prev-pre-c55`, daemon-reload, restart);
prod healthy, public 200, 1 CPU. Total prod impact: a brief wedged window during
the 2M burst, fully recovered on rollback.

**Root cause — process-global effect stack (THE C.5.5 deploy blocker).** The
effect runtime keeps the "current effect stack" in PROCESS-GLOBAL symbols
(`@__qz_effect_stack_names`/`_handlers`/… — see `__qz_effect_save_to_task` /
`__qz_effect_restore_from_task`, whose doc says "refreshes the process-global
@__qz_effect_stack_* ptr-base symbols from the task's slots"). The scheduler
calls `__qz_effect_restore_from_task` on EVERY schedule-in on EVERY CPU. Under
SMP, while BSP runs an effect-using HTTP handler (globals point at its strip), an
AP scheduling a demo body writes that demo's (zero) effect state into the SAME
globals → clobbers BSP's live effect state mid-handler → a name `.rodata` ptr
bleeds into a task slot on the next save. Works under cooperative single-CPU
(one task owns the globals at a time); breaks the instant two CPUs run
concurrently. **Pure-demo-spawn validation (§12.5) never caught it because demo
bodies don't install effects — only the concurrent HTTP-effect path triggers
it.** Correction: §12.5's "green/ready" was premature; pure-spawn ≠ realistic
mixed load.

**Why TCG + KVM-spawn both missed it:** neither ran sustained HTTP-effect
traffic concurrently with multi-core demo scheduling. The re-validation gate
MUST include: spawn N across cores WHILE hammering `GET /` + JSON endpoints
(which install Log/Throws effects) for the whole drain.

### 12.7 The fix (C.5.5.6, prerequisite for any SMP deploy)
Two candidates:
- **(A, narrow) Confine the effect globals to BSP.** Effect-USING tasks are all
  hi-priority HTTP → BSP-only already (§12.1). Gate every effect save/restore
  CALL SITE (sched_pump / sched_pump_step / yield_now / task_exit /
  `__qz_effect_suspend`) on `cpu_local_load(PCPU_CPU_ID) == 0` — APs NEVER touch
  the process-globals, BSP is the sole reader/writer (single-threaded with
  itself) → no cross-CPU race. (Do NOT gate on `TASK_EFFECT_STACK_NAMES == 0`:
  an HTTP task on its FIRST run also has NAMES==0 and still needs its restore to
  reset the globals to a clean slate — that gate would make it inherit the prior
  task's effect state. BSP-only is the correct discriminator.) Correct ONLY while
  no normal/AP task installs an effect (true for the soul demo today — fragile;
  add a loud guard: if an AP ever schedules a task with NAMES!=0, halt with a
  diagnostic rather than silently corrupt). Needs the §12.6 mixed-load gate.
- **(B, general) Per-CPU effect stack.** Make the `@__qz_effect_stack_*` symbols
  per-CPU (GS-relative, like `PCPU_CURRENT_TASK`), so each CPU has its own
  current-effect-stack. Correct for ANY task on ANY core; the real fix. Larger —
  the symbols are compiler-emitted and referenced throughout effect codegen
  (`codegen_runtime.qz` + the install/perform/uninstall lowering), so it's a
  compiler/runtime change, plausibly its own epic.

Recommendation: (A) to unblock the soul-demo deploy soon (with the mixed-load
gate + a guard/assert that no AP task has a strip), (B) as the durable fix before
SMP is a general language guarantee. **Do NOT enable `-smp N` in prod until one
lands and passes the §12.6 mixed-load re-validation.** The committed kernel work
(.1/.2/.3) is correct and safe at `-smp 1` (prod's config) — no revert needed.

### 12.8 C.5.5.6 fix (A) IMPLEMENTED + validated A/B (2026-05-31)
Fix (A) shipped: every effect save/restore site is gated on `eff_on_bsp()`
(`cpu_current_id() == 0`). APs never read or write the process-global
`@__qz_effect_stack_*` symbols; BSP is the sole owner (single-threaded with
itself). Sites gated: `yield_now`, `__qz_effect_suspend` (saves);
`sched_pump`, `sched_pump_step` (restores). `task_exit` has no save/restore —
nothing to gate. Two loud guards back the invariant:
- `__qz_eff_ensure_strip` halts (`[EFFECT-AP-INSTALL]`) if an effect install
  ever reaches an AP (an AP task installing an effect = invariant violated at
  source).
- `eff_guard_no_ap_strip` halts (`[EFFECT-AP-STRIP]`) if an AP is about to
  schedule a task whose strip is live (`NAMES != 0`) — silently skipping its
  restore would corrupt BSP's globals.
At `-smp 1` (prod) `eff_on_bsp()` is always true → byte-identical to C.6.

**A/B validation on prod hardware (192.0.2.10, nested KVM, throwaway guests
on spare ports; prod `:8080` untouched, public 200 throughout).** The §12.6
mixed-load gate — spawn N across 12 cores WHILE hammering `GET /` +
`/api/stats.json` + `/api/soul/stats.json` (effect-using BSP path):

| ELF | smp / load | Result |
|---|---|---|
| C.5.5.3 (pre-fix) | -smp 12, 1.56M peak + HTTP | ❌ `[EFFECT-RESTORE-WILD-NAMES]` (exact §12.6 prod signature, `v_names=0x129718`) |
| C.5.5.6 fix (A) | -smp 12, 42k peak / 602k churned + 1046 HTTP | ✅ 1046/1046 × 200, 0 faults, drained, ss alloc≈free |
| C.5.5.6 fix (A) | -smp 12, 1.0M+ peak + HTTP | ⚠️ one-off `#UD`/`#PF` wild-RSP (see below) |
| C.5.5.6 fix (A) + ss-guard | -smp 12, 1.2M+ peak + HTTP ×5 | ✅ all clean, survived |
| C.5.5.6 fix (A) no-guard | -smp 12, 1.2M+ peak + HTTP ×5 | ✅ all clean, survived |
| C.5.5.6 fix (A) | -smp 1 (prod cfg), 50k + HTTP | ✅ clean, 200s |
| C.5.5.6 fix (A) | -smp 4 TCG (local), 800k + 1052 HTTP | ✅ clean, no guard fires |

**Verdict: the effect-runtime SMP blocker (§12.6) is FIXED.** The bug reproduces
on the pre-fix ELF under the gate and is absent on the fixed ELF across 12+ runs.
Neither new guard ever fired (no AP task installs/carries an effect — the soul
demo invariant holds).

**Two secondary findings (NOT the effect bug, NOT caused by fix A):**

1. **Unchecked `ss_alloc` in `sched_park_active_stack` — PRE-EXISTING latent
   hole, now guarded.** The park path called `ss_alloc(len)` then
   `memcpy(buf, rsp, len)` with no null check; on ss-pool exhaustion `buf == 0`
   → memcpy to null → silent corruption. Same path runs single-CPU under C.6,
   so this is in prod's deployed kernel too (untriggered — prod hasn't sustained
   the concurrency). Fixed: `buf == 0` now halts with `[SS-OOM]` + diagnostic
   rather than corrupt. (The guard never fired in testing — see #2 — but the
   check is correct: a copying-stack park cannot back out, so loud-halt is the
   only safe response to a real OOM here.)

2. **Intermittent `#UD`/`#PF` wild-RSP at extreme concurrency — OPEN, filed.**
   Observed ONCE in 11+ fixed-kernel extreme runs (peak ~1.0M concurrent on 12
   cores). Two interleaved fault dumps (UART is not SMP-safe) with wild RSP
   (e.g. `0x0103000003080308`). **Not OOM** — guest RSS was ~6 GB of 14 GB at
   1.2M concurrent (16M struct pool 3.46 GB + rings + ~few-hundred-MB ss), and
   the `[SS-OOM]` guard never fired across the 1.2M+ runs. **Not the effect bug**
   (no `EFFECT-RESTORE-WILD-NAMES`). **Not fix (A)** — the BSP-gate touches only
   effect-slot writes, never RSP/stack. Did NOT recur in 10 subsequent extreme
   runs (5 guarded + 5 unguarded, all 1.2M+ peak, all clean). Most likely a rare
   pre-existing copying-stack SMP race in the C.5.5 scheduler (frame copy-in/out
   on per-CPU active stacks) that manifests only at pathological concurrency far
   beyond realistic prod traffic. Repro is ~1-in-11 — hard. Sized 1-2 qd to
   root-cause (HW watchpoint on a sentinel, per-park RSP validator).

**Reachability / deploy gating.** `/api/soul/spawn?n=N` bounds `N` only by total
THIN-pool capacity (~16.7M), not by a per-request cap — so any caller can drive
concurrent toward the pool max in one request (this is how the §12.6 prod wedge
and these tests reached 1M+). So finding #2 IS reachable on an SMP deploy via the
uncovered spawn endpoint. **Recommendation: do NOT autonomously redeploy `-smp N`
to prod yet.** The effect blocker is fixed, but before enabling SMP in prod,
EITHER (a) root-cause finding #2, OR (b) cap the spawn endpoint's per-request N
(product trade-off — the demo's whole point is massive concurrency, so this is
the user's call) to keep concurrency below the regime where #2 appears, then
redeploy with the mixed-load watch. The committed C.5.5.6 kernel work is correct
and safe at `-smp 1` (prod's config) — no revert needed.
