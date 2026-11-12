# Kind=3 `resume(0)` + with-block-in-goroutine breaks mid-routine

**Filed**: 2026-04-28 (during Phase E.1.c — TLS effect stack rollout).
**RESOLVED**: 2026-04-28 (later same day, Phase E.1.c.b). The bug was
an artifact of the body-wrap workaround that E.1.c forced — wrapping
`my_gen()` inside `with Blend {...} do -> return my_gen() end` so the
handler installed on the worker thread. E.1.c.b's spawn-time
effect-stack snapshot makes the wrap unnecessary: install the handler
on the parent (`main`) thread, the snapshot captures it at `go fn()`,
and the worker's poll-dispatch applies it on top of blessed defaults
before each $poll. The kind=3 `resume(0)` interleave then runs without
the body-wrap pattern that triggered the failure.

The previously-it_pending interleave test in
`spec/qspec/generators_p4b3_suspend_spec.qz` now passes under the
canonical pattern:

```be
def my_gen(): Int can Blend
  notify(1)
  pause(2)
  notify(3)
  pause(4)
  return 77
end

def main(): Int
  sched_init(2)
  with Blend { notify: capture_notify, pause: capture_pause } do ->
    var fut = go my_gen()
    var r = await fut
    ...
  end
end
```

Output: `77\npaused:\n2\n4\nnotified:\n1\n3\n` (the originally-expected
sequence). The body-wrap variant (`my_gen_with_handler`) is no longer
required and the whole class of bug it exposed is moot.

If a future use case forces the body-wrap pattern (e.g. per-goroutine
handler isolation different from parent's), the underlying control-flow
issue remains unmapped — but it's no longer blocking. Filing kept for
historical reference.

---

## Original filing

## Symptom

A `can E` routine that interleaves `resume(0)` (synchronous, body
continues) and `__qz_effect_suspend()` (async re-enqueue, next poll)
across multiple ops, run inside a goroutine with the handler installed
in a wrapping function, falls out of the with-block after the first
`resume(0)` instead of continuing the body.

Repro shape (from `spec/qspec/generators_p4b3_suspend_spec.qz`'s
`it_pending` test):

```be
import * from std/gen

effect Blend
  def notify(x: Int): Void
    do_nothing()
    resume(0)
    return 0
  end
  def pause(x: Int): Void
    do_nothing()
    resume(0)
    return 0
  end
end

def do_nothing(): Int = 0

var _collected: Vec<Int> = vec_new<Int>()
var _notified: Vec<Int> = vec_new<Int>()

def capture_pause(op_name: Int, argc: Int, argv: Int): Int
  _collected.push(load(argv, 0))
  return __qz_effect_suspend()
end

def capture_notify(op_name: Int, argc: Int, argv: Int): Int
  _notified.push(load(argv, 0))
  resume(0)
  return 0
end

def my_gen(): Int can Blend
  notify(1)
  pause(2)
  notify(3)
  pause(4)
  return 77
end

def my_gen_with_handler(): Int
  with Blend { notify: capture_notify, pause: capture_pause } do ->
    return my_gen()
  end
end

def main(): Int
  sched_init(2)
  var fut = go my_gen_with_handler()
  var r = await fut
  puts(str_from_int(r))
  ; expected stdout: "77\npaused:\n2\n4\nnotified:\n1\n3\n"
  ; got: "0\npaused:\nnotified:\n1\n"
end
```

After `notify(1)` fires (capture_notify pushes 1 into `_notified`, calls
`resume(0)`, then `return 0`), control should flow back into `my_gen`
and continue with `pause(2)`. Instead, the goroutine returns 0 (the
resume value) immediately, never reaching `pause(2)`.

## What works

- `notify(1)` handler IS invoked correctly — `_notified` ends up with `[1]`.
- The blessed-default Blend handler shadowing the user install is NOT
  the cause; with E.1.c the worker's TLS stack has the user handler
  pushed via `my_gen_with_handler`'s `with` block correctly (perform
  scan finds it, dispatches to `capture_notify`).
- `pause(2)` → `__qz_effect_suspend()` path works in isolation
  (the `it_pending` test's sibling `scheduler-drive` test, which uses
  only suspend, passes 3/3).

## Why E.1.c surfaced this

Pre-E.1.c, this test ran with the handler installed on the main thread
(`with Blend { ... } do go my_gen() end`). Workers saw the install via
the global `_names`/`_handlers` arrays. Although that path was racy
under `sched_init(0)` (the parent bug filed in
`EFFECT_STACK_TOP_GLOBAL_MULTI_WORKER_RACE.md`), in single-worker tests
it worked.

Under E.1.c, handlers must be installed inside the goroutine body. The
canonical rewrite wraps `my_gen()` in another with-block:

```be
def my_gen_with_handler(): Int
  with Blend { ... } do -> return my_gen() end
end
```

The bug manifests cleanly under this shape. The kind=3 resume(0)
control-flow reconstruction inside a `with`-as-function-body wrap
under a goroutine $poll appears to confuse the resume continuation:
after the first resume, the with-block's exit path is taken instead
of the body's next statement.

## Hypotheses (not investigated)

1. **Body-wrap last-statement rule + kind=3 perform.** The body-wrap
   pattern `with E {...} do -> ... end` has documented constraints
   (`feedback_body_wrap_last_stmt`). The kind=3 `resume(0)` re-enters
   the with-block via the captured continuation; the with-block's
   tail-emission shape may be inconsistent with the kind=3 re-entry
   point.

2. **Goroutine $poll state machine + with-block install/uninstall.**
   The async generator's $poll state machine emits install/uninstall
   pairs for nested with-blocks, with state-slot bookkeeping. The
   install for the inner with-block in `my_gen_with_handler` happens
   on each poll entry; the uninstall on poll exit. If the kind=3
   resume's poll re-entry doesn't re-install the with-block before
   running the body's next statement, the handler is missing on the
   second perform — but in this test, the failure happens BEFORE the
   second perform fires (we never reach `pause(2)`).

3. **TLS `__qz_effect_current_install_idx` interaction.** The `resume`
   lowering reads `current_install_idx` to find the matching install's
   continuation frame. If the idx is computed at perform-call time but
   read at resume-call time across a poll boundary, it could resolve
   incorrectly. Need to verify.

4. **`return my_gen()` inside `with E {...} do -> ... end`.** May be
   a body-wrap-last-stmt violation. An alternative `var rv = my_gen();
   rv` shape was tried with the same result; the bare-tail pattern
   isn't the issue.

## Next steps for whoever picks this up

1. Reproduce the standalone (without qspec wrapping) at `/tmp/...`
   with the new compiler; observe trace-level behavior.
2. Compile with `--dump-mir` and check the lowered async-frame layout
   for `my_gen_with_handler` — specifically the install/uninstall
   site and the kind=3 perform routing.
3. Compare against the simpler `my_gen` shape (only suspend, no resume)
   that passes — what's the IR difference around the resume continuation?
4. Look at `mir_lower_expr_handlers.qz`'s kind=3 perform emission and
   `__qz_effect_resume_cont` runtime body for any TLS-vs-frame
   confusions exposed by the goroutine boundary.

## Workaround until fixed

Don't interleave `resume(v)` (kind=3 sync resume) and `__qz_effect_suspend`
(kind=3 async suspend) on different ops within the same `can E` routine
when that routine runs inside a goroutine. Single-mode routines
(all-suspend or all-sync-resume) work.
