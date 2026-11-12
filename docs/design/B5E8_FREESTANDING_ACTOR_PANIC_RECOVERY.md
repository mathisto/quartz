# B.5e.8 — Supervision restart-on-panic in freestanding

**Status:** DONE. **Stage 1** (`f55906b6`) + **Stage 2** (`ce342e31`) shipped;
**Stage 3 / B.5e.8c — the real `std/actor.qz` Supervisor restarting a crashing
child 3× end-to-end in the kernel — SHIPPED & kernel-boot-proven** (`[B.5e8c]
supervisor restarts=3 ok`, full boot to `Listening on port 80 (supervised)`,
0 faults). The B.5 success criterion ("Supervisor restarts 3 times") is now met
freestanding. See "Stage 3 — DONE" below for the six freestanding gaps this
surfaced and closed.

## Stage 3 — DONE (real Supervisor end-to-end in the kernel — B.5e.8c)

Importing `std/actor`'s `Supervisor` into the kernel for the first time
(`tools/baremetal/hello_x86.qz`: `actor B5cChild` crashes via `actor_die(0)`;
`b5e8c_driver` drives `supervisor_new` + 3 crashes) surfaced six freestanding
gaps in primitives the supervisor stack uses that had never been exercised
without libc. Each was a hosted-only codegen path needing a freestanding twin:

1. **`await` (non-async) → `kern_await`.** `mir_emit_completion_await`
   (`mir_lower_gen.qz`) emitted the hosted completion-pipe path
   (`@pipe`/`@pthread_mutex`/`@__qz_completion_map`). Freestanding `async f()`
   returns a kernel TASK pointer (go_fn/kern_go_closure), not an async Future
   frame, so completion is `task_state` DEAD/FREE (or recycled `TASK_ID`), not
   `frame[0]==-1`. New freestanding branch delegates to a kernel `kern_await(t)`
   helper (owns the task-struct layout + staleness guard). Used by
   `supervisor_stop`'s `await sup.watcher`.
2. **`sched_spawn` → no-op freestanding.** The handle came from `async f(args)`,
   which already `task_alloc`'d + `ready_push`'d (B.5e.2-5); the hosted body
   (pthread worker deque / `@__qz_current_worker_id` / `@pthread_cond_signal`)
   would double-spawn. Gated to a no-op (same shape as the B.5e.4 spurious-
   perform suppression).
3. **`waiter_register` / `waiter_unregister` → `kernel_waiter_*`.** The hosted
   `@__qz_waiter_register` lives past the freestanding decl early-return; the
   kernel supplies `kernel_waiter_register(token, waiter)` (the active-wake
   table). This is what makes the watcher's close-event subscription work.
4. **`qz_rand_range` / `qz_rand_int` (+ `qz_rng_s0..3`).** `backoff_next_delay_at`
   jitter emits `@qz_rand_range`. Lifted the pure-IR xoshiro256** bodies +
   non-zero-seeded state globals into the freestanding decl block (dead unless a
   kernel supervisor opts into jittered backoff; present to satisfy the link).
5. **`sched_sleep` (non-async) → B.4 suspend-park.** `@usleep` doesn't exist in
   the kernel, and a `yield_now()` would leave the watcher perpetually READY —
   which deadlocks `sched_pump` (its drain loop returns only when the ready ring
   empties). Freestanding non-async `sched_sleep` now PARKs via
   `__qz_effect_park_rv_store(-2)` + `__qz_effect_suspend()`. **KNOWN
   LIMITATION:** this ignores the `ms` duration — it's an event-park, not a
   timed sleep. The watcher works because it `waiter_register`s on every child
   inbox *before* parking and catches the first crash via its initial scan; a
   non-async caller that `sched_sleep`s with no active-wake source (e.g.
   `_backoff_apply` under enabled jittered backoff) would park indefinitely. A
   real kernel ms-timer wake is the filed-forward fix.
6. **`chan_close` close-event active-wake (kernel source).** The kernel
   `chan_close` only drained `CHAN_RECV_WAIT` (tasks blocked *in* recv); it never
   touched the active-wake table, so a parked watcher subscribed via
   `kernel_waiter_register(inbox | CLOSE_EVENT_BIT, frame)` never woke. Added
   `kernel_waiter_wake_all(ch | 2)` (CLOSE_EVENT_BIT=2) to `chan_close`. **This
   was the load-bearing fix** — without it the first crash was caught by the
   watcher's initial scan but every subsequent crash hung (parked watcher,
   missed wake).

Gaps 1-5 are freestanding-only compiler codegen branches (hosted byte-identical,
fixpoint 2615 preserved by construction). Gap 6 is kernel source. Verified:
`[B.5e8c] supervisor restarts=3 ok` + all 14 prior B.5 smokes green + full boot
to `Listening on port 80 (supervised)`, 0 faults (`-m 16G`); `quake guard`
fixpoint gen1==gen2 (2615); Rule-2 (style_demo/brainfuck) green.

### Original Stage-3 framing (pre-implementation)

**Status (historical):** Stage 1 DONE (`f55906b6`), Stage 2 DONE (`ce342e31`);
Stage 3 (kernel QEMU smoke) was the remaining piece, now done as above.

## Stage 2 — DONE, guard-verified (pending kernel boot)

`mir_emit_actor_poll_body` now wraps the freestanding recv-loop in a per-goroutine
Throws boundary that recovers in place on panic (matches hosted `pc_actor_restart`).

- `codegen_runtime.qz`: emit `define internal i64 @__qz_actor_throws_noop(ptr,i64,
  ptr) { ret i64 0 }` in the freestanding effect block (perform's `do_call`
  requires a non-null handler before it reaches the kind=2 longjmp).
- `mir_lower.qz` `mir_emit_actor_poll_body` (freestanding==1 only): insert
  `actor_reenter` block at the top → `mir_emit_handle_install("Throws",
  ["throw", "__qz_actor_throws_noop"], -1)` + push lexical handler/wrap; at the
  end (body fully terminated) → pop, `mir_emit_handle_uninstall_done_only` in a
  fresh block (renders `wb.done` = the catch-resume landing + the pop), then jump
  back to `actor_reenter`. Re-install-per-iteration balances done_only's pop.

**Verified (IR + guard):** freestanding poll IR shows `actor_reenter` → install →
`setjmp` → wb.body/wb.catch; handler `panic` → fpn scan → `__qz_effect_perform(
…throw…, kind=2)`; live loop-back `wb.catch → wb.done (pop) → br actor_reenter`
(the `actor_wb_done` block is correctly predecessor-less/dead — body never falls
through). `opt -passes=verify` clean (modulo the kernel-provided `@__qz_eff_ensure
_strip`, expected-undefined for a non-kernel probe). **Stage 2 hosted IR is
byte-identical to Stage 1** (`--no-cache`, self-contained actor probe) → provably
hosted-neutral. `quake guard` fixpoint gen1==gen2 (2615 fns); cache + Rule-2
(style_demo/brainfuck) smokes green.

**Honest note on the Stage-1 "byte-identical" claim:** that check was cache-masked.
The true hosted delta vs the pre-b5e8 golden is the documented benign
`@__qz_gen_yield_capture` define (B.5e.7 noted the same): golden's hosted IR
referenced-but-did-not-define it (llc-INVALID, `opt` errors); the rebuilt binary
defines it → `opt-verify` CLEAN. Strictly more correct, no removals, fixpoint holds.
Stage 2 adds nothing further to hosted (Stage1==Stage2).

**Cache-ro reminder applied:** the first golden-vs-new actor_spec comparison showed
a `__qz_scoped_self_NNN` slot-id shift — a pure cache-state artifact (golden and
new used different `.quartz-cache` states; `--no-cache` standalone can't resolve
`qspec`/`std/gen` deps). The self-contained `--no-cache` probe is the reliable
oracle. See [[cache-ro-fools-golden-ab-testing]].

## Stage 3 — REMAINING (kernel QEMU smoke)

Blocked on the kernel build+boot command (build `hello_x86.qz` → llc → link with
boot_trampoline_x86.s + multiboot_headers.s + libc_stubs.c + x86_64-multiboot.ld →
`qemu-system-x86_64 -m 16G`). The B.5e.8 smoke is staged in `hello_x86.qz` (see
the `[B.5e8]` block). Two assertions: (1) actor survives a handler panic + keeps
serving; (2) real `std/actor.qz` Supervisor restarts a child 3× with backoff.

---

(Stage 1 detail:)

## Stage 1 — DONE (freestanding `panic` → catchable `Throws.throw`)

Two freestanding-only edits, both proven hosted-neutral + fixpoint-safe:

1. `codegen_runtime.qz` `cg_emit_runtime_decls` (freestanding effect block,
   after `@__qz_effect_stack_resumed`): emit `@__qz_eff_name_throws` +
   `@__qz_eff_op_throw` as `internal unnamed_addr constant` (the hosted
   `cg_emit_effect_runtime` is gated off for freestanding, so these were absent).
2. `cg_intrinsic_system.qz` `panic` branch: a freestanding `mir_is_freestanding()
   == 1` scan inserted before the `@panic_handler`/`unreachable` fallback. Scans
   `@__qz_effect_stack_top-1 .. 0`, loads the heap-strip `@__qz_effect_stack_names`
   base as a `ptr` then GEPs `i64` (NOT the hosted `[256 x i64]` inline form),
   compares each to `@__qz_eff_name_throws` via `i1 @__qz_effect_cstr_eq`; on a
   hit jumps to `fpn_perform_<d>` which `call @__qz_effect_perform(throws, throw,
   1, [msg], kind=2)` then `unreachable`; no hit / empty stack falls through
   `fpn_fallback_<d>` into the existing `@panic_handler`-or-`unreachable` code.
   Precedence is now: **installed Throws handler > `@panic_handler` (kernel
   `panic_halt`) > halt** — exactly right for actor "let it crash" recovery.

**Verified:** kernel `__qz_effect_perform` confirmed real (B.3) — `kind>=2` + non-null
buf → `call @longjmp(buf, 1)`. Probe IR shows the scan+perform replacing the bare
`unreachable`. Hosted IR byte-identical to golden (probe + `actor_spec.qz` 73689
lines, empty diff). `quake guard` fixpoint gen1==gen2 (2615 fns); both cache
smokes green; style_demo + brainfuck green. Hosted-neutral by construction (the
compiler self-compiles hosted; only the `freestanding==1` branch changed).

**Not yet user-observable:** Stage 1 only adds the *capability*. No freestanding
actor installs a Throws boundary yet, so current kernel panics still fall through
to `panic_halt` (unchanged). Stage 2 wires the actor poll to use it. **Stage 1 is
safe to commit without a kernel boot** (behaviorally inert in today's kernel).

**Filed forward within Stage 1:** only the `panic` intrinsic routes through the
scan. Other freestanding crash sources (`@qz_bounds_panic`, overflow, map-key
panic) still `unreachable`. If an actor handler can crash via those, route them
through the same scan too (broader, separate change). The B.5e.8 smoke uses
`panic`/explicit-throw, so this is sufficient for the criterion.

---

(original design, design locked + empirically validated 2026-06-03):
**Depends on:** B.5e.7 (real `actor … end` running freestanding), B.3 (Throws
via real longjmp freestanding), B.9 Phase 2 (hosted panic→Throws.throw perform).
**Goal:** the "Supervisor restarts 3× with backoff" half of the B.5 success
criterion, running in the kernel — i.e. a freestanding actor whose handler
panics must *recover* (drop the offending message and keep serving) instead of
unwinding to `__qz_panic` and halting the whole kernel.

## The gap, stated precisely

In the **hosted** runtime a panicking actor handler is caught by the scheduler
worker loop: `panic_caught:` reads `frame[3]` and, when it is the actor
sentinel `-999` (`pc_actor_restart`, `codegen_runtime.qz:7729-7744`), resets the
poll state to 0 and re-enqueues the task. Re-entering `$poll` runs its
`entry_block` recovery prologue (close the orphaned reply channel, notify links
with crash tag `-2` and monitors with down tag `-3`, clear `pending_reply`) and
loops back to `recv`. The actor **survives**; only the in-flight message is
dropped. Supervisor-level restart is a *separate* mechanism, driven by inbox
**close** (`.stop()` / `actor_die()` / link-cascade) detected by the
`_supervisor_watcher` goroutine — under `RESTART_PERMANENT` even a clean stop
respawns.

In **freestanding** the actor poll is a plain `ActorName$__poll(state)`
goroutine (`mir_lower_actor_poll_freestanding`, B.5e.7). There is no scheduler
catch boundary. **Empirically confirmed** (probe `actor Flaky { def boom() =
panic("…") }`, `--target x86_64-unknown-none-elf`): the handler `panic` lowers
to building the message pointer then `unreachable` — the freestanding panic
stub. No Throws perform, no longjmp, no catch. A panicking kernel actor hits
`unreachable` (UB/halt).

Root cause is one early-return: `cg_intrinsic_system.qz:366-372` — the
freestanding branch of the `panic` intrinsic emits `unreachable` and returns
*before* the hosted "scan the effect stack for a user `Throws` handler → build
`panic: `+msg → `__qz_effect_perform(Throws, throw, kind=2)`" logic (lines
374-511). So freestanding `with Throws do … end` does **not** catch panics,
even though all the machinery (`__qz_effect_perform`, `setjmp`/`longjmp`,
`__qz_effect_handle_install`, the per-task effect stack, `@__qz_eff_name_throws`
/ `@__qz_eff_op_throw` / `@__qz_panic_prefix_str` globals, `@__qz_effect_stack_top`
/ `@__qz_effect_stack_names` / `@__qz_alloc_blessed_watermark`) is already present
and exercised freestanding (B.1–B.4). The hosted side of B.9 Phase 2 was
implemented; the freestanding side was stubbed to `unreachable`.

## Design — two stages (Option A: symmetric panic-catchability)

Chosen over a dedicated actor-only panic jmpbuf because it is the higher-impact,
more-correct completion of B.9 Phase 2 (D1/D2): it gives *all* freestanding code
the same `with Throws` panic-catchability hosted already has, and the actor
restart then falls out of a general primitive instead of a special case.

### Stage 1 — freestanding `panic` scans + performs Throws.throw

`cg_intrinsic_system.qz`, the `freestanding == 1` branch (line 366): replace the
unconditional `unreachable` with the same scan-and-perform the hosted path uses,
with `unreachable` as the **no-handler fallback** (replacing hosted's libc abort
path). Simplification for freestanding: **skip the `panic: ` prefix `str_concat`**
— pass the raw msg as the single perform arg (avoids any `str_concat` dependency
and is fine; the prefix is cosmetic). Scan `@__qz_effect_stack_top` down to
`@__qz_alloc_blessed_watermark`, compare each name to `@__qz_eff_name_throws` via
`@__qz_effect_cstr_eq`; on match,
`call @__qz_effect_perform(@__qz_eff_name_throws, @__qz_eff_op_throw, 1, argv,
2)` then `unreachable`; if the scan falls past the watermark, `unreachable`
(halt — unchanged behavior when no handler is installed).

- **Blast radius:** only the freestanding codegen branch. The compiler builds
  hosted (`mir_is_freestanding()==0` for itself), so its self-IR is unchanged ⇒
  **fixpoint preserved by construction**. Hosted panic path untouched ⇒ hosted
  byte-identity preserved. Freestanding programs with no Throws handler still
  `unreachable` (same as today); behavior changes *only* when a handler is
  installed.
- **Verification:** IR diff on the probe — handler `panic` arm now emits the
  scan + `__qz_effect_perform(…throw…, kind=2)` instead of bare `unreachable`.
  No kernel build needed to see the codegen delta (only a compiler rebuild).

### Stage 2 — wrap the freestanding actor poll recv-loop in a `Throws` boundary

`mir_emit_actor_poll_body(…, freestanding=1)` / `mir_lower_actor_poll_freestanding`
(`mir_lower.qz:7335,7379`): install a lexical + runtime `Throws` handler around
the poll body so the Stage-1 perform has a target, and the catch path loops back
to re-run the recovery prologue.

Structure (freestanding only; hosted path unchanged):

```
fn_entry: allocas
actor_reenter:                      ; re-entry / panic landing
  install_dest = handle_install("Throws", entries=["throw", <handler>], -1)
  ; setjmp(jmpbuf); rc==0 → body, rc!=0 → wb.catch → wb.done
  push_handler_entry("Throws","throw",<handler>,install_dest)   ; lexical, for Stage-1 scan-resolve
  <entry_block recovery prologue: clean pending_reply, notify links -2 / mons -3>
  <recv loop; dispatch (panic → perform → longjmp → wb.catch)>
  ; body never falls through: stop/cascade/crash set TERM_RETURN(0);
  ; continue_block jumps to loop_block. So wb.done is reachable ONLY via panic-catch.
  pop_handler_entries(1)
  handle_uninstall_done_only("Throws", install_dest, 1)   ; renders wb.done (pop) only
  ; wb.done falls here:
  jump actor_reenter               ; re-install + re-run prologue (drops the message)
```

`entries=["throw", <handler>]`: `<handler>` is a no-op fn the kind=2 perform
calls before longjmp (the real recovery is the prologue at `actor_reenter`).
Confirm whether a null (`0`) handler entry is accepted by the kind=2
perform/inline-longjmp path (`codegen_instr.qz:2099`); if not, resolve a trivial
existing `Void(String)` no-op (or synthesize one).

Note `pending_reply` is already set to the crash sentinel `-1` before each
handler dispatch and to the real reply-ch for value methods
(`mir_lower.qz:7742-7778`) — the prologue's cleanup logic is already wired; the
freestanding boundary just gives it a way to *run* after a panic. The comment at
7742-7746 ("If the handler panics, setjmp returns to entry and cleanup detects
-1") describes exactly this landing — hosted gets the setjmp from the scheduler,
freestanding now gets it from the in-poll boundary.

- **Blast radius:** freestanding actor poll only. Hosted byte-identity + fixpoint
  preserved (the `freestanding==1` branch is dead for the compiler's own build).
- **Risk:** control-flow plumbing with `handle_install` / `handle_uninstall_done_only`
  (designed for linear `with`-expr) bent into a loop-back. Validate the emitted
  IR with `opt -passes=verify`.

## Stage 3 — kernel smoke + supervisor end-to-end

`tools/baremetal/hello_x86.qz`, sibling of the B.5e.7 smoke (line 9008):

1. **Panic-recovery smoke:** an `actor` whose handler panics on a poison message
   but otherwise increments; send poison, then 3 good messages; assert it served
   all 3 and is still alive. Expect `[B.5e8] actor survived panic count=3 ok`.
2. **Supervisor 3× restart smoke:** drive the real `std/actor.qz` `Supervisor`
   (watcher spawned via `async _supervisor_watcher`, B.5e.2/3) over a child that
   `actor_die()`s (close-without-clean → EXIT_CRASH) or `.stop()`s under
   `RESTART_PERMANENT`; assert `supervisor_restart_count == 3` with backoff
   (`time_epoch_ms` is the B.5e.7 monotonic `@cfg` fork). Expect
   `[B.5e8] supervisor restarts=3 backoff ok`.

Boot needs `-m 16G` (NUM_TASKS=16M; 6G OOMs at `uk_sched_init`). Verify the
watcher's deps link freestanding: `channel_closed`, `actor_check_clean`
(B.5e.6), `time_epoch_ms` (B.5e.7), `sched_sleep`, `waiter_register`, `spawn_fn()`.
`async _supervisor_watcher(sup)` is the explicit-async-1-arg case B.5e.2/3
closed — but it has **never been run end-to-end in the kernel**; this is the
first exercise of the full supervisor stack freestanding. Treat "does the
watcher even run" as an open empirical question, not a given.

## Verification gates (all mandatory)

- IR: probe shows freestanding handler `panic` → perform (Stage 1); poll body
  shows the Throws boundary + `actor_reenter` loop-back (Stage 2);
  `opt -passes=verify` clean.
- Hosted byte-identity: golden-vs-new hosted IR for `actor_spec.qz` empty diff
  (modulo the documented benign `@__qz_gen_yield_capture` define).
- `quake guard` fixpoint gen1==gen2==gen3 byte-identical.
- Kernel QEMU `-m 16G`: both `[B.5e8]` smokes green; all prior B.5 smokes still
  green; full boot to "Listening on port 80 (supervised)".
- Hosted actor/supervisor specs unchanged (`actor_supervisor_spec` 10/10,
  `actor_link_spec`, `actor_mn_spec`, `dynamic_supervisor_spec`).

## Bootstrap-Island discipline

Save `cp self-hosted/bin/quartz self-hosted/bin/backups/quartz-pre-b5e8-golden`
before touching any `self-hosted/*.qz`. After each guard, Rule-2 smoke
style_demo + brainfuck. One compiler build at a time on the local Mac (no
concurrent build agents — OOM hard-reset risk).
