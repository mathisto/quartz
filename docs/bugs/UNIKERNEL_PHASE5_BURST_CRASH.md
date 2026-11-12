# Unikernel phase-5 burst-crash — silent triple-fault after concurrent batches

**Severity:** blocker for DEF-E-N1 phase 6 (unblocks concurrent goroutines under real production load, not just small batches).
**Introduced by:** DEF-E-N1 phase 5 (per-connection goroutines + async RX).
**Commits to inspect:** the phase-5 landing commit on `unikernel-site` after the docs handoff `23a8a9d2`.

## Symptom

With the phase-5 unikernel:

- Single-request HTTP: works (`quake baremetal:qemu_http` passes).
- 200+ sequential requests from the same client: work, connections_served climbs, heartbeat keeps counting.
- 8-way and 16-way parallel request batches: **all 16 return 200 OK** with correct byte counts, and `conn_goroutine_spawn_total` increments correctly.
- Running a second 16-way batch after the first: kernel dies silently.
- QEMU exits with code 0 (looks like a clean shutdown, but nothing in the kernel issues one).

After a successful burst of N concurrent requests, the kernel survives long enough to complete every one of them (every peer sees a full 200 response and FIN), but dies **shortly after** the last FIN is exchanged — before the next client request lands.

## What we know

- `page_fault_isr` does not fire. Neither do the phase-5-added handlers for `#GP`, `#DF`, `#UD`, `#SS`, `#DE`. If the kernel were hitting any of those exceptions, we'd see the diagnostic dump in the serial log.
- Serial output ends cleanly on `HTTP: peer FIN -> CLOSED`. No garbled bytes, no "PF at…", no "#GP…", no "#UD…".
- QEMU's exit code is 0, not 1. With `-no-reboot`, a triple fault on modern QEMU normally produces exit 1; exit 0 usually indicates ACPI shutdown (which nothing in our kernel issues) or a system-reset-style VMM signal.
- 4 KiB per-task stack was plainly too small (the landing-page builder has enough string-literal call-frame overhead that goroutines blow that easily). Bumping to 2 pages (8 KiB) resolved immediate crashes for single-request + sequential flows, and let 8/16-way single bursts complete. But a second burst still crashes. Bumping further to 4 pages (16 KiB) also crashes on second burst, so it isn't a simple stack overflow.
- The kernel's retransmit pass (`tcp_retransmit_pass`) still walks all 64 slots every serve-loop iteration. Nothing in its logic changed, but the new slot layout (192 B vs 128 B) means addresses changed — we checked `CONN_SLOT_SIZE` is referenced everywhere via `conn_slot_addr(i)` (no hardcoded 128 remains).

## Suspects, in priority order

1. **Goroutine task-exit vs. reuse race in the same serve-loop turn.**
   The connection goroutine calls `tcp_free_slot` → `task_exit` → `switch_to(cur+TASK_SAVED_RSP, g_sched_main_rsp_slot)`. The freed task slot lands on the task freelist between those two calls. If main's next action is a fresh SYN that `go_fn`'s and gets back the just-freed slot, and then `task_init_stack` seeds the stack while the dying `switch_to` is still mid-flight on that same page, the seeded-rsp and the still-running switch_to RSP could stomp each other. This is the leading hypothesis. A fix would be to queue "zombie" tasks for reaping one full scheduler cycle later, or to make `task_exit` reserve its exit via a dedicated per-task hand-off page instead of switching back to main from the about-to-be-reused stack.

2. **Timer ISR on a blocked goroutine's stack.**
   The APIC timer fires at 100 Hz. When a connection goroutine is blocked in `chan_recv` (stack is full of its own suspended call frames), the timer interrupt lands on that same stack. If the blocked-goroutine path has a subtle saved-register misalignment, the interrupt entry sequence's SS/RSP pair could diverge from what x86-interrupt's epilogue restores. Worth checking if `@c("sti")` is enabled before `uk_sched_init()`.

3. **Channel wait-list LIFO asymmetry.**
   `wait_push` / `wait_pop` is LIFO; multiple senders or receivers waking up in reverse order could expose a previously-hidden ordering bug. Phase-5 is the first scenario where the same channel sees real waiter churn (goroutine blocks, main wakes, goroutine runs, goroutine blocks again, …).

4. **Virtio RX re-post race.**
   Main calls `virtio_net_rx_post()` immediately after `tcp_handle_frame` returns, which for phase-5 means immediately after copying into the slot's rx-scratch + `chan_try_send`. The RX ring should be stable w.r.t. the goroutine using its copy. But verify the ordering on real hardware-ish timing: QEMU legacy virtio-net is known to need the 1-µs pacing that `uart_put_str` accidentally provides.

## Reproducer

```bash
pkill -f qemu-system-x86_64 2>/dev/null
./self-hosted/bin/quake baremetal:build_elf
(qemu-system-x86_64 -M microvm -kernel tmp/baremetal/quartz-unikernel.elf \
   -netdev user,id=net0,hostfwd=tcp::9090-:80 \
   -device virtio-net-device,netdev=net0 \
   -serial file:/tmp/uk-serial.log -display none -no-reboot) &
sleep 3
for i in $(seq 1 16); do curl -sS -m 8 -o /dev/null http://127.0.0.1:9090/ -w "#$i:%{http_code} " & done
wait
echo
for i in $(seq 1 16); do curl -sS -m 8 -o /dev/null http://127.0.0.1:9090/ -w "#$i:%{http_code} " & done
wait    # → second batch never connects; QEMU gone
tail -20 /tmp/uk-serial.log   # → last line is "HTTP: peer FIN -> CLOSED"
```

## Next-session plan

1. Reproduce with `-d int,cpu_reset -D /tmp/uk-int.log` to capture QEMU's own interrupt/reset trace. That will tell us whether it's a real triple fault or a synthetic shutdown.
2. If triple fault: register a #DF handler with a dedicated IST stack (x86_64 requires this — #DF on the broken stack triple-faults the handler itself). Our current `double_fault_isr` runs on the current RSP, which is exactly the wrong thing when the #DF was caused by a stack problem.
3. If not triple fault: grep QEMU source for exit-0 paths invoked from microvm + virtio.
4. If the task-exit-vs-reuse hypothesis holds, switch to a "zombie reap" scheme: `task_exit` moves the slot to a zombie list; `task_alloc` reaps one zombie per call (or deferred reap on `yield_now`). This lets the dying task's `switch_to` finish on its own stack before the slot is reused.
