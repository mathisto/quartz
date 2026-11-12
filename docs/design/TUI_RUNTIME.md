# TUI Runtime (std/tui/runtime.qz)

**Status**: Designed 2026-05-03. Not yet implemented.
**Stance**: Bubbletea-shaped runtime, Elm Architecture (Model/Update/View/Cmd) semantics, Quartz-native primitives. Lives in `std/tui/`, marked experimental until v1.
**Driving project**: External — the deckbuilder (separate worktree, `game/deckbuilder` branch). The framework's job is to make that project pleasant to write, and to surface Quartz stdlib gaps along the way.

## What this is

The Elm Architecture, ported. User writes:

- a **Model** — a struct holding application state
- an **Update** function `(FrameMsg<M>, Model) -> (Model, Cmd<M>)` — pure
- a **View** function `Model -> String` — pure

The **runtime** owns the event loop, raw-mode terminal, input goroutine, command execution, and rendering. The user's code never touches a file descriptor.

Quartz makes this surprisingly small because the substrate is already there: `select` is a language keyword with `recv/timeout/default` arms (`spec/qspec/select_timeout_spec.qz`), `structured_scope` gives clean teardown, and `std/terminal.qz` already handles raw mode + key reads + Unicode/color detection. The runtime is plumbing on top of those.

## What this is NOT (v0.1)

Each cut is intentional. Adding any of these later is non-breaking; we are not designing them away, just not paying for them yet.

- **No widgets.** The view is a `String` you compose by hand. Text-input, list, viewport, table — all v0.2.
- **No layout primitives.** Padding, borders, joins — all v0.2 (`std/tui/layout.qz`).
- **No cell-level diffing.** Full redraw on every msg. Iterate later.
- **No mouse.** v0.3+.
- **No alt screen buffer.** v0.3+.
- **No periodic ticks** (`Cmd::Every`). Architectural room reserved in `Cmd<M>` enum and `FrameMsg::Tick` variant; the variant is delivered as a no-op in v0.1 because nothing produces it. v0.2 adds the producer.
- **No delayed one-shots** (`Cmd::After`). Same reservation; v0.2.
- **No external `program.send(msg)`.** Goroutines outside the runtime can't push messages in. v0.2.
- **No SIGWINCH-based resize.** `FrameMsg::Resize` variant exists; nothing produces it in v0.1. v0.2.

## Module layout

```
std/tui/
  runtime.qz   ## FrameMsg, KeyEvent, Cmd, Program, program_run
  keys.qz      ## key matching helpers (constants live in std/terminal)
  layout.qz    ## (v0.2) cleavage — boxes, padding, joins, borders
  widgets.qz   ## (v0.2) text input, list, viewport
```

`layout.qz` carries the working title "cleavage" in its module epigraph (the way crystals split along defined planes). The module name itself stays `layout` for skim-ability; the joke lives in the doc-comment.

Imports use qualified module syntax:

```be
import std/tui/runtime as tui
import std/terminal
```

Inside the importing file, types are written `tui::FrameMsg<MyMsg>`, constructors `tui::Program { ... }`, free functions `tui::program_run(p)`. Sub-package imports do NOT cross-import each other implicitly; users opt in per file.

## API

### `FrameMsg<M>`

Generic over the user's app message type `M`. The runtime delivers one message at a time to the user's `update` function.

```be
enum FrameMsg<M>
  Key(KeyEvent)         # raw input event in raw mode
  Resize(Int, Int)      # cols, rows — reserved, not produced in v0.1
  Tick(Int)             # epoch_ms — reserved, not produced in v0.1
  App(M)                # user-defined message
  Quit                  # runtime-initiated shutdown signal — see contract below
end
```

**Quit semantics.** `FrameMsg::Quit` is delivered to `update` exactly once, after `Cmd::Quit` has been observed in the cmd queue. It exists so user code can run last-chance state writes (saving, telemetry) before the runtime tears down. After `update` returns from a `Quit`, the runtime ignores any returned `Cmd` (cleanup is enforced regardless).

**Ctrl-C is NOT auto-intercepted.** It's delivered as a regular `Key(KeyEvent { code: terminal::KEY_CTRL_C, ... })`. User code is expected to handle it. Idiom:

```be
terminal::KEY_CTRL_C => (s, tui::Cmd::Quit)
```

This is a deliberate choice: confirmable-quit apps ("Save your progress?") need to intercept Ctrl-C. The framework does not assume your app's policy.

### `KeyEvent`

```be
struct KeyEvent
  code: Int           # KEY_UP/KEY_DOWN/... constants from std/terminal, or Unicode codepoint
  modifiers: Int      # bitmask: 1=ctrl, 2=alt, 4=shift (v0.1 fills these from terminal output as best-effort)
end
```

**Modifier honesty:** terminal escape sequences are limited and inconsistent. v0.1 detects what `term_read_key()` already exposes (Ctrl-* and arrow keys); shift/alt detection beyond what's already there is v0.2.

### `Cmd<M>`

A description of effectful work for the runtime to perform. Pure values; never executed inside `update`.

```be
enum Cmd<M>
  None                              # do nothing (return when no effect needed)
  Quit                              # initiate shutdown; runtime delivers FrameMsg::Quit then tears down
  Batch(Vec<Cmd<M>>)                # run all in parallel; results fed back individually as messages
  Run(Fn(): FrameMsg<M>)            # execute closure on goroutine; return value becomes a message
  # Reserved for v0.2:
  # After(Int, Fn(): FrameMsg<M>)
  # Every(Int, Fn(): FrameMsg<M>)
end
```

**`Run` semantics.** The closure runs on a goroutine spawned inside the runtime's `structured_scope`. When it returns, the result is sent into the runtime's msg channel and delivered to `update` like any other message. Closures may block, do IO, sleep — none of that affects `update` latency.

**`Batch` semantics.** Each child cmd is dispatched independently. Order of resulting messages is **not guaranteed** — cmds run concurrently. If you need ordered effects, chain them through `update` (Cmd → message → next Cmd).

**`Quit` ordering.** When the runtime sees a `Cmd::Quit`, it stops accepting new input keys, drains in-flight `Run` cmds with a short grace period, delivers `FrameMsg::Quit` to `update` once, then returns from `program_run`.

### `Program<S, M>`

```be
struct Program<S, M>
  initial:  S
  update:   Fn(FrameMsg<M>, S): (S, Cmd<M>)
  view:     Fn(S): String
  recorder: Fn(FrameMsg<M>): Void          # default: tui::no_recorder — see Replay section
end

def program_new<S, M>(
  initial: S,
  update: Fn(FrameMsg<M>, S): (S, Cmd<M>),
  view:   Fn(S): String
): Program<S, M>                           # recorder defaults to no-op

def program_with_recorder<S, M>(
  p: Program<S, M>,
  recorder: Fn(FrameMsg<M>): Void
): Program<S, M>                           # builder-style; returns a new Program

def program_run<S, M>(p: Program<S, M>): Int

# Reserved for v0.2 — name locked, body unimplemented in v0.1.
# def program_replay<S, M>(p: Program<S, M>, msgs: Iter<FrameMsg<M>>): S
```

`program_run` returns the OS exit code (0 on clean Quit, nonzero on uncaught throw after cleanup).

## Runtime loop semantics

Pseudocode for `program_run`. This is the entire framework — small enough to live in your head.

```be
def program_run<S, M>(p: Program<S, M>): Int
  with Throws { throw: cleanup_then_rethrow } do ->
    structured_scope() do ->
      var msg_ch = channel_new(64)
      term_enter_raw_mode()

      # Input goroutine: pumps raw key events into msg_ch as FrameMsg::Key
      go() do ->
        loop
          var key = term_read_key()
          if key == terminal::KEY_EOF
            send(msg_ch, encode(FrameMsg::Quit))
            break
          end
          send(msg_ch, encode(FrameMsg::Key(KeyEvent { code: key, modifiers: 0 })))
        end
      end

      var state = p.initial
      render(p.view(state))

      var quitting = false
      loop
        var raw = recv(msg_ch)
        var msg = decode<M>(raw)
        p.recorder(msg)                     # ← VCR hook: called once per dispatched msg
        var (next_state, cmd) = p.update(msg, state)
        state = next_state
        render(p.view(state))

        if msg is FrameMsg::Quit
          break
        end

        execute_cmd(cmd, msg_ch, ...)
      end
    end
    term_exit_raw_mode()
    return 0
  end
end
```

**Render strategy (v0.1):** `render(s)` writes `\x1b[H\x1b[2J` (cursor home + clear screen) followed by `s`. Naive, but correct. Flicker is a v0.2 problem solved by diffing or alt-screen.

**Backpressure:** msg_ch is bounded (64). If `update` is slow and the input goroutine fills the channel, the input goroutine blocks on send. This is correct — keys queue up; nothing is lost. If we ever need to drop keys under pressure, that's a v0.3 policy decision.

## Crash safety contract

**Non-negotiable.** This is the single most important property of the framework.

If anything inside `program_run` throws, the runtime MUST:

1. Restore terminal state (`term_exit_raw_mode()`, cursor visible, screen sane).
2. Re-throw the original exception so the caller sees the failure.

Implementation: wrap the loop in `with Throws { throw: handler } do ... end`. The handler:

```be
def cleanup_then_rethrow(msg: String): Void
  term_exit_raw_mode()
  term_write("\x1b[?25h")  # cursor visible
  throw msg                # re-raise; caller decides exit code
end
```

This applies to throws from `update`, throws from `view`, throws from any `Run` closure body, and panics from inside the runtime itself. There is no path through `program_run` that leaves raw mode set on exit — verified by qspec coverage of `assert_run_stdout_eq` paths that simulate panics inside update.

**What this does NOT cover:** SIGSEGV from miscompilation, SIGKILL, hard hangs. If your `update` infinite-loops, the terminal is stuck — that's a user-code bug, not a framework contract violation. The "panic key" feature (a watchdog goroutine that force-quits if no msg processed in N ms) is reserved for v0.2.

## Determinism and replay

This is the second non-negotiable contract — and it's load-bearing for debugging real games. The deckbuilder will produce bug reports of the form "ran a deck for 30 minutes, then this happened." Without replay, those reports are useless. With replay, they're a deterministic test case.

The architecture is unusually well-suited to replay: in pure TEA, the entire app state evolution is determined by `(initial_state, [msg_0, msg_1, ...])`. We just have to honor that purity, log the messages, and provide a runner that re-feeds them.

### Purity contract for `update`

**Non-negotiable.** The `update` function MUST be pure:

- No clock reads (`time_*`).
- No randomness (`random_*`).
- No global mutation.
- No I/O.
- No reads of process state, environment, file system, network.

All non-determinism enters the system as messages. If you need the current time, do `Cmd::Run(|| { let now = time_epoch_ms(); FrameMsg::App(NowIs(now)) })` — the time becomes part of the message log and replays exactly. If you need a random number, same shape. If you need to read a file, same shape.

This is partly a TEA-style cleanliness rule and partly a *replay correctness* rule. Violating it doesn't crash anything; it silently breaks replay determinism. We don't statically enforce this in v0.1 — Quartz's effect system could theoretically catch some violations via a `pure` row, but that's a v0.3+ project. For v0.1, the contract is documentation + discipline. If we get bitten, file a debug-mode lint pass.

### The recorder hook

`Program.recorder` is a `Fn(FrameMsg<M>): Void` called once per dispatched message, AFTER decode and BEFORE the user's `update`. Default is `tui::no_recorder`, a no-op.

To record a session to disk:

```be
def my_recorder(msg: tui::FrameMsg<AppMsg>): Void
  var line = json::encode(msg)              # user must implement Encode for FrameMsg<AppMsg>
  file_append("session.jsonl", line + "\n")
end

var p = tui::program_new(initial, update, view)
p = tui::program_with_recorder(p, my_recorder)
return tui::program_run(p)
```

Serialization format is the user's choice. JSON-lines is the default reference shape because `std/json.qz` is in tree, but binary formats, ring buffers, in-memory only, or tee-to-stdout-for-printf-debugging are all valid.

**Recorder runs synchronously on the main loop.** A slow recorder slows the app. If you need async recording, the recorder closure can `go { ... }` itself; just be aware that messages may land out-of-order on disk if you do.

**Recorder sees `FrameMsg::Quit`.** The hook fires for every dispatched message including the synthetic Quit, so a replay log is complete.

### Replay semantics (v0.2 implementation, v0.1 contract)

`program_replay(p, msgs)` runs the same loop as `program_run` but with a critical difference: the message source is the iterator instead of the input goroutine, and **`Cmd::Run` closures DO NOT EXECUTE.** Their *results* are already in the message log; the replay loop just sees those result-messages in sequence.

This means side effects happen exactly once — at record time — and replay is pure even though the original session wasn't. Network calls don't re-fire. RNG draws don't re-roll. Clocks don't advance.

Concretely:

| Cmd variant   | At record time      | At replay time                    |
| ------------- | ------------------- | --------------------------------- |
| `None`        | no-op               | no-op                             |
| `Quit`        | initiates teardown  | terminates replay                 |
| `Batch(cs)`   | dispatches all      | dispatches `None`s; results in log |
| `Run(fn)`     | spawns goroutine    | dispatches `None`; result in log  |

Replay is therefore strictly faster than the original session (skips IO, skips sleeps) and strictly deterministic (no fresh non-determinism enters).

**Edge case worth noting:** if a `Run` closure was *in flight* when the original session crashed, its result message is missing from the log. Replay handles this by treating any `Run` whose result didn't appear before the next non-Run message as "dropped" — the replay continues without it. The deckbuilder save format will need to account for this; we'll spec it in v0.2.

### State checkpointing (v0.2)

For long sessions, replaying from start is slow. v0.2 adds:

- `program_snapshot(p, state) -> Bytes` — serialize state at a checkpoint
- `program_replay_from(p, snapshot, msgs)` — start replay from a snapshot

This requires `S` to be serializable. The deckbuilder's state will need to be designed with this in mind from day one — pointer-shaped state (handles to opaque runtime objects) is a serialization hazard. Pure-data state (Vecs, structs of primitives, enums) round-trips cleanly. **This is a design constraint on the game itself**, not on the framework.

## Naming and module conventions

- File names: `snake_case.qz`, no leading underscores on public modules.
- Type names: `PascalCase`. Generic params: single capital letter (`S`, `M`, `T`).
- Variant names: `PascalCase`, unqualified in match arms (`Key(k)` not `FrameMsg::Key(k)`).
- Free functions: `snake_case`, no `tui_` prefix on public symbols (the module path provides the namespace — `tui::program_run`, not `tui::tui_program_run`).
- Internal helpers: leading underscore (`_render`, `_execute_cmd`, `_cleanup`).

## v0.1 dogfood: counter

Lives at `examples/tui/counter/main.qz`. As shipped (commit 3 of v0.1):

```be
import std/tui/runtime as tui
import std/terminal

struct State
  count: Int
end

enum AppMsg
  Inc
  Dec
end

def update(msg: tui::FrameMsg<AppMsg>, s: State): (State, tui::Cmd<AppMsg>)
  match msg
    tui::FrameMsg::Key(k) =>
      if k.code == terminal::KEY_UP()
        return (State { count: s.count + 1 }, tui::Cmd::None)
      end
      if k.code == terminal::KEY_DOWN()
        return (State { count: s.count - 1 }, tui::Cmd::None)
      end
      if k.code == terminal::KEY_CTRL_C()
        return (s, tui::Cmd::Quit)
      end
      return (s, tui::Cmd::None)
    tui::FrameMsg::App(am) =>
      match am
        AppMsg::Inc => return (State { count: s.count + 1 }, tui::Cmd::None)
        AppMsg::Dec => return (State { count: s.count - 1 }, tui::Cmd::None)
      end
    _ => return (s, tui::Cmd::None)
  end
end

def view(s: State): String =
  "Count: #{s.count}\r\n[↑/↓ to change · Ctrl-C to quit]\r\n"

def main(): Int
  return tui::program_run(tui::program_new(State { count: 0 }, update, view))
end
```

Two stylistic differences from the original design sketch — both forced
by current parser limits, both worth filing if they bite a third time:

1. **Function-call patterns don't parse.** The original sketch had
   `terminal::KEY_UP => ...` as a match-arm pattern. Quartz match
   patterns accept literals + variant constructors, not arbitrary
   function calls (`KEY_UP` is `def KEY_UP(): Int = 1000`). Workaround
   above: bind the key code, branch via if-chain.
2. ~~**`\r\n` instead of `\n` in the view.** Raw mode disables ICRNL —
   bare `\n` does line-feed without carriage-return, leaving each
   subsequent line indented by the column where the previous line
   ended. `\r\n` resets the cursor to column 0.~~ **Wrong diagnosis.**
   ICRNL is the *input*-side flag (translates received `\r` to `\n`);
   it has nothing to do with output rendering. The actual mechanism
   that translates output `\n` to `\r\n` is OPOST/ONLCR, which
   `term_enter_raw_mode` does NOT disable. So bare `\n` in views
   works correctly — the terminal handles the translation. v0.3
   accordingly: views and `std/tui/layout` use bare `\n` as the
   canonical line separator. (A v0.3 attempt to add an explicit
   `_normalize_to_crlf` translation in `_render` produced doubled
   `\r\r\n` after ONLCR re-translation; harmless on most terminals
   but interacted poorly with at least one (Ghostty), where the
   incremental dogfood would render nothing and appear hung.
   Reverted in commit a follow-up. The proper architectural fix is
   to disable OPOST in `term_enter_raw_mode` to match cfmakeraw
   semantics; filed as v0.4 cleanup.)

If writing this counter feels bad, the design is wrong and we revise the doc before shipping `runtime.qz`.

## Predicted friction findings (live checklist)

These are the dogfood findings we expect to hit. Each gets logged here as we encounter it; the goal is to fix them in the language/stdlib (per Prime Directive 1) rather than work around them in the framework.

- [x] **Generic enum with closure-typed variant.** `Cmd<M>::Run(Fn(): FrameMsg<M>)` — verifies that codegen handles parametric enums whose variants carry function values. ✅ Working — exercised by `examples/tui/types_smoke.qz` (commit `15c7265f`) and `spec/qspec/tui_runtime_spec.qz` (commit 3 of v0.1). Run thunk extracts and invokes cleanly.
- [x] **Nested generic enum pattern matching.** ✅ Working — `examples/tui/counter/main.qz` does `match msg { FrameMsg::App(am) => match am { Inc => ... Dec => ... } }`. Outer match needs a `_ =>` catch-all (still tracked separately as the Maranget-on-generic-enum bug); inner non-generic match is exhaustive without one.
- [x] **Tuple return from `Fn`-typed parameter.** ✅ Working with caveat. Direct destructuring `var (a, b) = update_fn(msg, state)` fails when `update_fn` is a Fn-typed local — bound names don't materialize. Workaround: bind to a pair var and access `pair.0` / `pair.1`. Filed as memory entry `feedback_fn_typed_field_call_friction.md`. Filing-worthy if it bites a third time.
- [x] **Module-aliasing import** (`import std/tui/runtime as tui`). ✅ Verified working — `spec/qspec/modules_spec.qz:95,213` exercise this with `import alias_mod as am` / `import calcmod as c`.
- [ ] **Long-running `select` loop under M:N scheduler.** Existing qspecs for `select` are short-lived; a 30-minute counter session is a different stress pattern. Watch for goroutine leaks, channel growth, scheduler starvation. **Status:** Not yet stress-tested. v0.2 incremental dogfood will exercise long sessions; if leaks surface, file then.
- [x] **Crash-safe raw mode restoration.** ✅ Verified end-to-end — `examples/tui/_minimal_run/main.qz` panic key (`b`) throws from inside update; observed exit 66, "boom from update" on stderr, terminal sane on shell return. The `with Throws` handler can NOT re-throw inside its own frame (infinite loop on re-entry); commit `9eedf4fc` uses a capture-and-rethrow-after-with-block shape — handler stores the message into module state and returns 0, kind=2 unwind exits the with-block cleanly, post-with-block code calls `throw(captured_msg)` which bubbles to the runtime-blessed default Throws handler.
- [x] **`structured_scope` teardown semantics.** ✅ Closed in v0.2 — `term_read_key_cancellable(scope)` joins the B.7 Phase 4e chunked-poll family in `std/terminal.qz`, observing `scope_is_cancelled` between `io_suspend_timeout` waits. `program_run` owns a `scope_with_cancel` runtime scope, wraps the pump in `scope_with(s, ...)` so scope-cancel throws unwind cleanly via Throws. Cmd::Run / Cmd::After / Cmd::Every goroutines also run under the runtime scope and use `scope_sleep_ms` / `scope_send` so they observe cancellation. Verified: standalone smoke `spec/qz/term_read_key_cancel_smoke.qz` measures cancel→throw latency at ~47ms (well under the 50ms chunk floor + scheduler round-trip). Bug doc closed: `docs/bugs/done/TUI_INPUT_PUMP_BLOCKS_PAST_LOOP_EXIT.md`.
- [ ] **Purity violation in `update`.** Currently doc-only contract; a debug-mode lint pass that flags `time_*` / `random_*` / global-mutation calls inside any `update`-typed function would catch silent replay-determinism breakage. File when (if) we get bitten. **Status:** Not exercised — counter dogfood is trivially pure.

### Friction NOT predicted but surfaced during commit 2

These weren't on the list pre-implementation; they came up writing `program_run` and are filed for the next session:

- [x] **Fn-typed struct field calls misparse as UFCS.** `p.view(x)` where `view: Fn(S): String` is a struct field looks up a free function `view` — undefined. Workaround: extract to a typed local (`var view_fn: Fn(S): String = p.view; view_fn(x)`). Pattern: every `p.field_fn(args)` site needs the extra binding. Filed in memory; resolver fix is a candidate for a future polish session.
- [x] **`is` keyword rejects module-qualified variant patterns.** `if msg is FrameMsg::Quit` is a parse error. Workaround: drop the qualifier (`if msg is Quit`), the LHS expression's type disambiguates. Sibling to memory entry above.
- [x] **Generic-enum payload extraction loses Vec element type.** `match cmd { Cmd::Batch(cs) => cs.size }` reads offset 0 of the enum payload box, not the Vec's `.size` field — observable as a wrong (large, alloc-block-shaped) integer. Workaround: use `vec_size(cs)` (intrinsic, operates on raw handle). Same root cause as the existing "Vec<T> element type loss" memory entry, exposed via a new surface.

When a friction point gets fixed in Quartz, replace the unchecked box with a checked one and a one-line note pointing to the fixing commit.

## v0.2 — shipped May 4 2026

What landed in v0.2:

1. [x] **`Cmd::After(ms, fn)` + `Cmd::Every(ms, fn)`.** Both spawned as scope-aware goroutines (use `scope_sleep_ms` + `scope_send` so they unwind on `program_run` teardown within ~50ms). After-thunk fires once at `ms` then exits; Every-thunk fires every `ms` until cancel.
2. [x] **`program_replay(p, msgs)` runner.** Body shipped in `std/tui/runtime.qz`. Iterates `msgs` through `update`, terminates on `FrameMsg::Quit` or `Cmd::Quit`, skips Cmd::Run/After/Every side effects (their results are already in the message log). Verified deterministic via `spec/qspec/tui_runtime_spec.qz` ("replay determinism" describe block).
3. [x] **`Program.init` field.** Bootstrap Cmd dispatched once at startup so Cmd::Every can fire from t=0. Mirrors Bubbletea's `Model.Init() tea.Cmd`. Defaults to `Cmd::None` — zero overhead when unused. Builder: `program_with_init(p, cmd)`.
4. [x] **Scope-aware teardown.** Single biggest correctness improvement — closes `docs/bugs/done/TUI_INPUT_PUMP_BLOCKS_PAST_LOOP_EXIT.md`. `term_read_key_cancellable(scope)` lives in `std/terminal.qz`. `program_run` runs the whole loop under a per-call `scope_with_cancel` scope; teardown cancels the scope and pump + Cmd::Run/After/Every goroutines all unwind within ~50ms (chunked-poll) with no leaks across the boundary.
5. [x] **Incremental dogfood** (`examples/tui/incremental/`). Cookie-clicker idle game exercising `Cmd::Every` (init-bootstrapped Tick), `Cmd::After` (transient status-message auto-clear), and the scope-aware teardown path under Ctrl-C. Keys-only by design — no widgets, no layout pulls.

What deferred to v0.3+:

6. **External `program.send(msg)`.** Lets goroutines outside the runtime push messages in. Needed for any data source that isn't keyboard or `Run` cmd (network, file watcher, etc.). Skipped in v0.2 because the incremental dogfood doesn't need it; deckbuilder will pull it in.
7. **`program_snapshot` / `program_replay_from`.** State checkpointing for long-session replay. Requires `S` to be serializable. Not needed for the incremental dogfood; deckbuilder will pull it in.
8. **`std/tui/layout.qz` ("cleavage").** Boxes, padding, borders, horizontal/vertical joins, alignment. Lipgloss-shaped. The deckbuilder needs this the moment we render two cards side-by-side.
9. **`std/tui/widgets.qz`.** Text input, single-select list, viewport (scrollable region). Deckbuilder is the dogfood: viewport (combat log), list (deck/discard browsers), text input (save naming). Incremental dogfood deliberately does NOT need widgets — it's keys-only.
10. **`SIGWINCH` → `FrameMsg::Resize` producer.** Honest resize handling.
11. **`Program::with_panic_key(code)`.** Watchdog goroutine for force-quit when `update` doesn't respond. Power-user feature.

Open question for v0.3 sequencing: do we ship layout before widgets or vice versa? Widgets need layout to be useful; layout is testable in isolation. Probably layout-first. The order is driven by the deckbuilder's needs once we get there.

## v0.3+ roadmap

- Cell-level diff renderer.
- Alt screen buffer support.
- Mouse events.
- Drop-policy under input pressure.
- Deeper modifier-key detection (kitty keyboard protocol where available).

## Why not effect-based Cmd dispatch

Considered: making `Cmd` an effect (`can Dispatch`) so `update` can call `dispatch(cmd)` inline rather than returning `(state, Cmd)`.

Rejected because pure `update` is testable in a way effectful `update` isn't. The whole point of TEA is that the function from message to next-state is total, pure, and inspectable. Cmd-as-value preserves that. Effects still happen — inside `Run` closure bodies — which is conceptually "this is work the runtime should do later," exactly the right level for effect handlers to attach.

Reconsider in v0.3 if testing pain on real games is low and we feel constrained. Not before.

## Why not Elm-style declarative subscriptions

Considered: a `subscriptions: Model -> Sub<M>` function that the runtime queries each frame, with the runtime managing worker lifecycles.

Rejected because the bubbletea-style alternative (goroutines + `program.send(msg)`, both already supported by Quartz primitives) is strictly simpler to implement, doesn't sacrifice any expressiveness, and matches how Quartz code already manages concurrency (`go { ... }` + channels under a scope). Elm-style subs are an abstraction over an FRP-shaped runtime; we don't have that runtime and shouldn't pretend we do. The benefit doesn't pay for the complexity.

## Open design questions for review

Locked but worth flagging before code:

1. **Should `FrameMsg::Quit` be observable to user code, or purely internal?** Currently spec'd as observable (delivered to `update` exactly once). This costs ~5 lines and lets apps run save-on-quit. Alternative is internal-only, simpler. I'm going with observable; one save-state escape hatch is worth the surface.
2. **Channel size for `msg_ch`.** Spec'd at 64. Probably fine for any keyboard-driven app. If we ever stream from network into the runtime, may need tuning.
3. **`Run` closure's relationship to scope.** Currently spec'd as "spawned inside runtime's `structured_scope`" — meaning if the runtime tears down, in-flight `Run`s get cancelled via the scope. This requires `Run` closures to be cancellation-aware (use scope-aware blocking helpers, not raw blocking primitives). Document this in the runtime.qz module docstring.

## Acceptance for v0.1

Considered shippable when:

- [x] `runtime.qz` compiles, passes `quake guard` fixpoint. ✅ Commits `15c7265f` (data types) and `9eedf4fc` (program_run). 2482 functions, byte-identical.
- [x] `examples/tui/counter/main.qz` runs, increments/decrements correctly, quits cleanly on Ctrl-C. ✅ Commit 3 of v0.1 — verified with `\x1b[A`/`\x1b[B`/`\x03` byte sequences.
- [x] Deliberate panic inside `update` (e.g., `if s.count == 5 throw "boom"`) restores terminal state on crash, prints the throw message to stderr. ✅ Commit 2 — `examples/tui/_minimal_run/main.qz` `b` key throws; verified exit 66, message on stderr, terminal sane.
- [x] Qspec coverage for: pure `update` functions, `Cmd` enum construction, `FrameMsg` pattern exhaustiveness. ✅ `spec/qspec/tui_runtime_spec.qz` — 16 tests, all green.
- [x] Recorder hook fires once per dispatched message, including synthetic `Quit`. ✅ `examples/tui/counter_recorder/main.qz` — `printf 'q' | counter_recorder` prints `recorded:2` (Key q + synthetic Quit). `printf 'aaaq' | counter_recorder` prints `recorded:5`.
- [x] `program_with_recorder` returns a new `Program` with the hook attached; default recorder is a no-op. ✅ Tested in `tui_runtime_spec.qz`.
- [x] All v0.1 friction findings (above) either resolved or filed. ✅ See checklist above — open items are scope-aware teardown (v0.2, filed) and long-session stress (v0.2 incremental dogfood will exercise).
