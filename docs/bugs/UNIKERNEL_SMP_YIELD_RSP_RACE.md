# UNIKERNEL_SMP_YIELD_RSP_RACE — yield_now publishes task before SAVED_RSP is committed

**Status:** ✅ Closed by K8.6 (commits d0a0cd72 / 187e242a / 30b6c71d / 799a09c1 / a738c44a / K8.6.7), 2026-05-09.
**Filed:** 2026-05-09 during K8.8 telemetry work.

## Resolution

K8.6's full sub-phase plan structurally closes both the SAVED_RSP race
described in this doc AND the lost-wakeup hazard sketched in §"Sketch
of the fix":

- **K8.6.3 defer-publish** for `yield_now` + `task_exit` — these
  paths set state but DO NOT publish. `sched_post_switch` (running
  in main's frame on this CPU after `switch_to` commits SAVED_RSP)
  completes the publish. The race window between "visible in queue"
  and "SAVED_RSP committed" no longer exists.
- **K8.6.4 + K8.6.5 park-unlock** for `chan_send` / `chan_recv` /
  `uk_mutex_lock` — each primitive grew an embedded spinlock at a
  fixed offset in its page; block paths hold the lock through
  `switch_to`, and `sched_post_switch` does `wait_push` + `unlock`
  in that order. A waker arriving mid-park is forced to spin on the
  channel/mutex lock until the receiver is on the waitq, so
  `wake_one` cannot miss it. Identical to Go's `gopark(unlockf, lock)`
  shape.

Verification: at -smp 2, the heartbeat task's per-CPU counter at
`/api/soul/stats.json` advances on whichever CPU is currently
running it (no longer freezes on stalls); 30k-task stress spawn
shows both CPUs drain at near-equal rate (CPU0 ~1.25M, CPU1 ~1.16M
heartbeat during stress); HTTP latency under stress 50ms (down from
159ms pre-K8.6.7).

The original race description below remains for reference.

---
**Surfaced by:** K8.8 per-CPU heartbeat counters at `/api/soul/stats.json` showing CPU1's `heartbeat` advancing only a few units per second under sustained load, vs. CPU0 (BSP) climbing in proportion to served HTTP requests.

## Symptom

After the unikernel boots into the HTTP serve loop at `-smp 2` or higher, the per-CPU
scheduler heartbeat on at least one AP stops advancing or advances at a tiny fraction
of the rate the CPU should be handling. Concretely:

```
$ curl /api/soul/stats.json
{"version":1,"ticks":48,"...","cpus":[
  {"id":0,"lapic":0,"heartbeat":71},
  {"id":1,"lapic":1,"heartbeat":160920}
]}

$ sleep 2; curl /api/soul/stats.json
{"version":1,"ticks":74,"...","cpus":[
  {"id":0,"lapic":0,"heartbeat":72},
  {"id":1,"lapic":1,"heartbeat":160923}
]}
```

CPU1 advanced from 160920 → 160923 over 2 seconds. With the heartbeat task yielding
every iteration and IPI wake enabled, AP should be running tens of thousands of
quanta per second. The actual per-second tick rate of ~1.5 means AP is mostly stuck.

HTTP serve still works because the conn goroutine spawns fresh + exits cleanly per
request — its lifetime is too short to hit the race window often enough to break
the request path.

## Root cause

`yield_now` (and the chan_send / chan_recv / uk_mutex_lock block paths and
`task_exit`) all do their queue-publishing BEFORE calling `switch_to`:

```qz
def yield_now(): Void
  var cur = sched_current()
  if cur == 0; return; end
  task_set_state(cur, TASK_STATE_READY)
  ready_push(cur)              # ← (1) publish to ready queue
  set_sched_current(0)
  switch_to(cur + TASK_SAVED_RSP, pcpu_main_rsp_slot())
                                # ← (2) save current RSP into cur.SAVED_RSP
end
```

Step (1) makes the task visible in the ready queue. Step (2) is where
`switch_to`'s asm prologue actually writes the current RSP into
`cur.TASK_SAVED_RSP` (then loads main's RSP and returns to main's stack).

Between (1) and (2) — a window of a few instructions plus a function call — the
task is in `g_ready_ring` with a STALE `SAVED_RSP` from its previous yield. K8.7's
`apic_broadcast_ipi(WAKE_IPI_VECTOR)` after `ready_push` immediately wakes any
sleeping AP. The AP's `sched_pump` body:

```qz
var next = ready_pop()           # ← pops the same task pointer
task_set_state(next, RUNNING)
set_sched_current(next)
switch_to(pcpu_main_rsp_slot(), next + TASK_SAVED_RSP)
                                  # ← loads stale TASK_SAVED_RSP
```

reads `next.TASK_SAVED_RSP` BEFORE the yielding CPU's `switch_to` writes it. The
AP jumps to a stack pointer pointing at the task's previous-yield resume frame —
sometimes valid (resume continues fine, but two CPUs end up running on the same
task stack) and sometimes already overwritten by intervening code, causing a
silent stack corruption that manifests as the task getting stuck or blowing up
later.

At K8.MVP the LAPIC timer cadence (~100 ms) was the only AP wake source, so the
race window almost never fired. K8.7's IPI wake hits the window on every
ready_push and surfaces the bug.

The same race shape exists for:

- `chan_send` (block-on-full) — `wait_push(ch + CHAN_SEND_WAIT, cur)` before switch_to.
- `chan_recv` (block-on-empty) — `wait_push(ch + CHAN_RECV_WAIT, cur)` before switch_to.
- `uk_mutex_lock` (block-on-locked) — `wait_push(m + MTX_WAIT_HEAD, cur)` before switch_to.
- `task_exit` — `task_free(cur)` (returns slot to freelist) before switch_to. A concurrent
  `task_alloc` could grab the slot and `task_init_stack` would write the freshly seeded
  RSP into `TASK_SAVED_RSP` BEFORE the dying task's `switch_to` clobbers it with the
  outgoing RSP — flipping the new task's seeded entry to a garbage location.

## Why it doesn't break HTTP today

- The conn goroutine for each curl is short-lived (spawn → block on chan_recv → wake →
  HTTP response → task_exit). Its time on a CPU is dominated by chan_recv waits, where
  the wait_push is also racy but the wakeup pattern is single-producer-single-consumer
  per channel and the channel state is handled by chan_send's atomic-ish push +
  wake_one. The race window doesn't statistically hit during the few microseconds
  conn actually runs.
- The heartbeat task is the long-running victim — it cycles the same task pointer
  between yield → ready_push → ready_pop indefinitely, hitting the race nearly every
  cycle.

## Sketch of the fix (deferred to K8.6 substrate)

Defer all post-yield publishing to AFTER `switch_to` returns control to MAIN. Add a
new `TASK_PENDING_WAITQ` field at offset 64 (struct grows to 72 bytes):

```qz
def yield_now(): Void
  var cur = sched_current()
  if cur == 0; return; end
  task_set_state(cur, TASK_STATE_READY)   # mark, but DO NOT publish
  set_sched_current(0)
  switch_to(cur + TASK_SAVED_RSP, pcpu_main_rsp_slot())
end

def chan_recv_block(...): Void
  task_set_state(cur, TASK_STATE_BLOCKED)
  volatile_store<U64>(cur + TASK_PENDING_WAITQ, ch + CHAN_RECV_WAIT)
  set_sched_current(0)
  switch_to(cur + TASK_SAVED_RSP, pcpu_main_rsp_slot())
end

def task_exit(): Void
  task_set_state(cur, TASK_STATE_DEAD)    # mark, but DO NOT free yet
  set_sched_current(0)
  switch_to(cur + TASK_SAVED_RSP, pcpu_main_rsp_slot())
end

def sched_pump_step(): Void
  ... pop, RUNNING, switch_to ...
  # SAVED_RSP is now committed.
  sched_post_switch(next)
end

def sched_post_switch(next: Int): Void
  var s = task_state(next)
  if s == TASK_STATE_READY
    ready_push(next)
  elsif s == TASK_STATE_BLOCKED
    var waitq = volatile_load<U64>(next + TASK_PENDING_WAITQ)
    if waitq != 0
      volatile_store<U64>(next + TASK_PENDING_WAITQ, 0)
      wait_push(waitq, next)
    end
  elsif s == TASK_STATE_DEAD
    task_free(next)
  end
end
```

This was implemented and tested during K8.8 work; it fixes the heartbeat advance
problem at -smp 1 but introduces a new lost-wakeup hazard in the chan_recv path:
between the receiver's "is queue empty?" check and the deferred wait_push, a
concurrent chan_send may call wake_one and find the waitq empty (because the
receiver hasn't been published yet). The receiver then ends up parked on the waitq
with a message already in the channel. Fix requires re-checking the channel state
inside sched_post_switch, OR holding a per-channel spinlock through the full
recv-block sequence on one side and the send-with-wake sequence on the other.

The full SMP-correct chan/mutex implementation is the K8.6 deliverable (per-CPU
ready rings + work-stealing + properly-locked synchronization primitives). Filing
this bug doc as the substrate K8.6 must address. Until then, the heartbeat task
is the only concrete victim — HTTP request handling and the demo paths happen
fast enough that the race rarely fires on them.

## Reproduction

```bash
# Build + run at -smp 2
./self-hosted/bin/quake baremetal:build_elf
qemu-system-x86_64 -M microvm,acpi=on -cpu max -m 1G -smp 2 \
  -kernel tmp/baremetal/quartz-unikernel.elf \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:8080-:80 \
  -device virtio-net-device,netdev=net0 \
  -serial stdio -display none

# In another terminal:
curl http://127.0.0.1:8080/api/soul/stats.json | jq '.cpus'
sleep 2
curl http://127.0.0.1:8080/api/soul/stats.json | jq '.cpus'
```

Expected: CPU1's heartbeat advances by tens of thousands per second.
Actual: CPU1's heartbeat advances by ~1-3 per second.

## Related

- `feedback_ap_gdt_must_match_bsp_selectors.md` (K8.MVP) — different SMP correctness
  bug, surfaced same week.
- `docs/design/KERN_8_SMP.md` D6 (single global ready queue + spinlock for K8.MVP),
  K8.6 (per-CPU rings + steal). The K8.6 work is the natural place to lift the
  scheduler's synchronization invariants to SMP-safe primitives, including this
  fix.
