# TUI_INPUT_PUMP_BLOCKS_PAST_LOOP_EXIT

**Status:** CLOSED 2026-05-04 in TUI v0.2. Filed 2026-05-03 alongside
TUI v0.1 commit 2/3.
**Resolution:** Option A from the design space below —
`term_read_key_cancellable(scope)` shipped in `std/terminal.qz`,
`program_run` wraps the whole loop in a per-call `scope_with_cancel`
runtime scope. Pump and all `Cmd::Run` / `Cmd::After` / `Cmd::Every`
goroutines run under that scope and use `scope_*` blocking helpers
(`scope_sleep_ms`, `scope_send`, `term_read_key_cancellable`) so they
observe cancel via the chunked-poll family. Teardown calls
`scope_cancel(s)`; all goroutines unwind via Throws within ~50ms of
teardown. Verified end-to-end:
- `spec/qz/term_read_key_cancel_smoke.qz` — cancel→throw latency ~47ms
  (pipe-as-stdin, scope cancel during parked read).
- `spec/qz/tui_cmd_every_smoke.qz` — Cmd::Every fires 5 ticks (200ms
  minimum) and program_run returns within bounded time of Cmd::Quit.
- `examples/tui/incremental/` — cookie-clicker dogfood; ↑/↓ + Ctrl-C +
  passive ticking all clean.
**Severity:** Was: v0.1 functional but not embeddable. Now: closed.

## Problem

`std/tui/runtime.qz`'s `_pump_keys` goroutine reads keys via
`term_read_key()`, which is built on `read(0, ...)` — a blocking POSIX
syscall. Cooperative cancellation can't interrupt it. After
`program_run` returns:

1. The pump goroutine is parked in `read(0, ...)`.
2. There is no scope membership: v0.1 uses plain `go _pump_keys(msg_ch)`
   so the pump is NOT registered in `_current_scope_children`. Any
   `structured_scope` wrapping `program_run` would not try to await it,
   but the pump remains scheduled.
3. The next keypress (or stdin EOF) wakes the pump, which then tries to
   `send(msg_ch, ...)` on a channel whose receiver no longer exists. If
   the channel is full or the receiver freed it, this is undefined
   behavior or a silent drop. v0.1 specifically does not free `msg_ch`
   in `program_run`'s teardown — the leak is acknowledged but bounded.

Same shape applies to `Cmd::Run` thunks: each runs on its own plain `go`
goroutine and may outlive `program_run`. `_run_thunk` sends to the same
`msg_ch` after thunk completion. v0.1 punts both on the same mechanism.

## Why this is OK for v0.1

- TUI apps in v0.1 are full-process: `main()` calls `program_run` and
  returns its result. Process exit follows immediately, OS reaps all
  threads and goroutines, `msg_ch` is never accessed after teardown.
- Cmd::Run is unused in the dogfood (counter doesn't need it) so the
  Run-leak axis isn't exercised.
- The crash-safety contract (`with Throws` restoring raw mode + cursor)
  is independent of pump cleanup and is verified end-to-end.

## Why this is NOT OK for v0.2

The v0.2 dogfood is `examples/tui/incremental/` — an idle-game with
periodic ticks (`Cmd::Every`) that runs for hours. Long-session leak
sensitivity is real. The deckbuilder beyond that is a multi-screen app
where one TUI session may end and another begin within the same process
(menu → game → menu → game). Process-exit reaping is no longer a
sufficient cleanup mechanism.

## Design space

Three mechanisms that look viable, ordered by my prior on which lands:

### Option A — Scope-aware terminal helper

Add a new stdlib helper to `std/terminal.qz`:

```be
def term_read_key_cancellable(scope: Int): Int
```

Sets stdin to non-blocking (`O_NONBLOCK`), polls in a loop using
`io_suspend(0)` for event-driven wakeup, with a `scope_is_cancelled(scope)`
check between polls. Returns `KEY_EOF` (or a new `KEY_CANCELLED` sentinel)
when the scope cancels.

Then v0.2's `program_run` can wrap the pump in `structured_scope` and
`scope_cancel(s)` on teardown, the cancel propagates via the scope tree
to the pump's `io_suspend`, the pump exits cleanly, structured_scope's
`await` completes, teardown is bounded.

**Cost:** ~50 lines of stdlib code. New `O_NONBLOCK` toggle on stdin
(must save/restore in `term_enter_raw_mode` / `term_exit_raw_mode`).
Behavioral change for existing `term_read_key` callers if we make it
cancel-aware by default — better to add the new function and leave the
existing one for synchronous callers (REPLs, etc.).

**Sequencing:** Lands in `std/terminal.qz` first. `program_run` migrates
to it in the same commit.

### Option B — Self-pipe trick

The pump goroutine selects on either `read(0, ...)` (via `io_suspend(0)`
on non-blocking stdin) or `read(cancel_pipe_read_end)`. On teardown,
program_run writes one byte to `cancel_pipe_write_end`; the select
wakes, the pump observes the cancel side, exits.

Same `O_NONBLOCK` requirement on stdin. Same end-to-end story; differs
in the cancellation channel mechanism. Slightly more boilerplate but
matches Go/Bubbletea idioms exactly.

### Option C — pthread_cancel + signal

OS-level interrupt of the pump's `read(0, ...)` syscall via
`pthread_cancel` or sending SIGUSR1 to a specific thread. Effective but
foreign to Quartz's M:N scheduler model and introduces signal-handler
complexity. Listed for completeness; would only consider if A+B both
prove problematic.

## Acceptance for v0.2

- `program_run` returns within bounded time (< 50ms) of `Cmd::Quit` or
  EOF, including cancellation of in-flight `Cmd::Run` goroutines via a
  shared scope.
- A test harness that calls `program_run` 100 times in a single
  process, with synthesized stdin pipes, observes no goroutine leaks
  (verified via `sched_task_count()`).
- The v0.1 friction-list item "structured_scope teardown when main
  loop returns" gets checked off in `docs/design/TUI_RUNTIME.md`.

## Cross-references

- Design memo: `docs/design/TUI_RUNTIME.md` — predicted-friction
  checklist items 1, 3, 4 all collapse to this single fix.
- Substrate: `std/sync/scope.qz` (scope_with_cancel, scope_cancel,
  scope_is_cancelled), `std/concurrency.qz` (structured_scope).
- Existing scope-aware blocking helpers: `scope_sleep_ms`, `scope_recv`,
  `scope_send`, `scope_lock`, `scope_rwlock_read`, `scope_rwlock_write`
  (B.7 Phase 4e). The new terminal helper would join this family.
