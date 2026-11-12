# Actor method with a `for` loop returns a partial count under qspec inline-poll

**Status:** OPEN — pre-existing, low priority. NOT a B.5e.7 regression.
**Filed:** 2026-06-03 (during B.5e.7 freestanding-actor verification).

## Symptom

`spec/qspec/actor_spec.qz` test *"loop inside actor method body: add_range(50)
= 50"* fails: expected 50, got **16**. This is the only failing test in
`actor_spec` (20/21).

```qz
actor Counter
  var count: Int = 0
  def add_range(n: Int): Void
    for i in 0..n
      count += 1
    end
  end
  def get_count(): Int = count
end
# inside an it(...) lambda:
var c = Counter(); c.add_range(50); assert_eq(c.get_count(), 50)  # gets 16
```

## It is NOT a regression and NOT a real-runtime bug

- **Standalone (real spawn) is correct.** The same actor in a plain `def
  main()` returns the right value for every input tested (5→5, 10→10, 16→16,
  20→20, 50→50). A real goroutine/worker-spawned actor runs the loop to
  completion.
- **Byte-identical lowering.** The hosted actor `$poll` IR is byte-identical
  between the pre-B.5e.7 golden compiler and the current one (only the benign
  `@__qz_gen_yield_capture` define differs), so B.5e.7 did not change this
  path. The failure reproduces identically on the golden binary.

## Root cause (hypothesis)

`actor_spec` calls actors **directly inside `describe`/`it` lambda bodies**.
Per the project caveat (CLAUDE.md "Spec authoring caveat for `go fn()` inside
qspec lambdas"), an async target inside a qspec lambda desugars to an inline
`Future$new` + `$poll` polled on the calling thread, NOT a real worker spawn.
For an actor whose message handler contains a **suspend point inside a loop**
(`for ... count += 1`, where the loop crosses the generator state machine), the
inline poll appears to advance the message-loop generator only a bounded number
of steps (16 here) before returning, rather than draining the handler to
completion the way a real scheduler-run goroutine does. Fire-and-forget and
single-shot request-response handlers (no loop) work because they complete in
one poll step; the loop is what exposes the partial-advance.

The actor_spec header already notes this context is special ("Actor calls work
directly inside describe/it closures — the effect graph filtering prevents
spurious async `$poll` generation"); the loop-in-handler case is the corner
that filtering doesn't fully cover.

## Fix options (when prioritized)

1. Move the loop-in-method assertion to a standalone smoke in `spec/qz/`
   (real `def main()` spawn), mirroring the `go fn()`-in-qspec workaround — the
   cleanest honest fix, since the qspec inline-poll context can't represent a
   real multi-step actor handler.
2. Make the qspec inline-poll path drive the actor `$poll` generator to
   completion (loop until `$poll` reports done) instead of a single step.

Option 1 is preferred: the inline-poll context is a qspec-authoring limitation,
not something the actor runtime should bend to.
