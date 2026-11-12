# Auto-arena `arena_destroy` bypassed when goroutine body panics

## Status

**FIXED 2026-04-28 (Phase E.4.b)** — `_go_arena_body` and the compiler-side
synthesizer both now nest `with Throws { throw: __qz_arena_panic_rec }`
INSIDE `with Alloc.in_arena(ar)`. The Throws's `wb.catch` runs cleanly
(one entry popped), control resumes in the outer Alloc body, Alloc's
`wb.done` pops its 2 entries cleanly. No effect-stack leak. Lambda then
returns the `-1` panic sentinel that `panic_caught` already used pre-fix
(cross-stack longjmp into the parent's setjmp would abort, so we
deliberately do not re-throw upward). Spec at
`spec/qspec/alloc_e4b_panic_path_arena_cleanup_spec.qz`.

**Side effect:** during the fix, found that `mir_lower_stmt`'s NODE_WITH
branch was missing the `$`-split + method-dispatch logic that
`mir_lower_expr`'s NODE_WITH branch had since B.0c. Statement-context
`with Alloc.in_arena(ar) do ... end` would silently fall through to a
default null handler — Alloc.alloc routing broke. Now ported. Any
existing user code that used `with E.method(...) do ... end` in
statement position was silently miscompiled; this fixes that too.

**Identified during E.4.a slice 3.a authoring** (2026-04-28). Pre-existing in
E.1.a's `_go_arena_body` (`std/concurrency.qz`) since 2026-04-28. E.4.a
slices 1/2/3.a inherited the same shape via `_mir_synthesize_arena_wrap` in
`mir_lower.qz`.

## Symptom

The synthesized goroutine body has the shape:

```be
go (-> {
  var ar = arena_new(8192)
  var r = with Alloc.in_arena(ar) do orig_call end   # <-- if this panics:
  var p = arena_promote_<T>(r)                       # never runs
  arena_destroy(ar)                                  # never runs — ARENA LEAKS
  return p
})()
```

When `orig_call` panics, the panic propagates through `with Alloc.in_arena`
(effect handlers unwind) and reaches the goroutine's outer `$poll` jmpbuf,
which routes to `panic_caught` in `mir_lower.qz` (~line 4177). The
`panic_caught` block stores `-1` in the result slot, takes + frees the
effect snapshot, and returns to the scheduler.

**`arena_destroy(ar)` is never called.** The arena's bulk-allocated chain
blocks (8 KB minimum, plus growth) leak for the lifetime of the process —
or until the process's blessed Alloc handler frees them via libc on exit.

## Reachability

This affects every goroutine that:
1. Imports `std/alloc` (the auto-arena gate's reachability prerequisite).
2. Calls `go fn()` where `fn` returns a value-typed, String, Vec<8B>, or
   uniform-value-struct (auto-arena fires).
3. Panics inside `fn` (or any function `fn` calls).

Any unhandled error inside an auto-arena'd goroutine leaks the per-task
arena. In a long-running scheduler with frequent panics, this is a
linear-in-panics RSS leak.

E.1.a's opt-in `go_arena(f)` has the same shape via
`std/concurrency.qz:_go_arena_body`:
```be
def _go_arena_body(f: Fn(): Int): Int
  var ar = arena_new(8192)
  var r = with Alloc.in_arena(ar) do -> f() end
  arena_destroy(ar)         # also bypassed on f() panic
  return r
end
```

## Why the slices 1-3.a tests didn't catch this

None of the spec tests have a goroutine that panics. All test bodies
either complete normally or use `qspec_main`'s assertion path (which
counts test failure but doesn't panic the goroutine).

## Possible fixes

1. **Synthesize a `Throws` handler in the goroutine body** that catches
   panics, runs `arena_destroy(ar)`, then re-throws. Quartz has Throws,
   so this should be expressible:
   ```be
   var ar = arena_new(8192)
   var r = -1
   var caught = false
   with Throws { throw: rec } do ->
     r = with Alloc.in_arena(ar) do orig_call end
   end
   if caught
     arena_destroy(ar)
     throw(...)   # re-raise
   end
   var p = arena_promote_<T>(r)
   arena_destroy(ar)
   return p
   ```
   The `rec` handler would set `caught = true` and capture the error.

2. **Defer-style cleanup** via a synthesized `defer arena_destroy(ar)`
   if/when Quartz adds `defer`. Currently no `defer` keyword.

3. **Panic-aware arena_destroy in `panic_caught`**: thread arena handles
   into the goroutine frame's metadata, then `panic_caught` runs the
   destroy as part of its cleanup pass before scheduler return. This
   couples auto-arena to the panic-caught codegen — invasive but maybe
   the right architecture for E.4.b's Q6 work too (the snapshot-take
   already lives there).

(3) is the most architecturally aligned with E.4.b's other work
(promote-before-snapshot-teardown for ref-typed errors per Q6 of the
design memo addendum).

## Pull-in trigger

- E.4.b is being implemented (it should bundle this fix).
- A production workload reports unbounded RSS growth correlated with
  goroutine panics.
- Slice 3.b / slice 4 work touches the synthesizer (any change to
  `_mir_synthesize_arena_wrap` should consider this).

## Related

- `docs/design/E4_CROSS_TASK_ESCAPE.md` Q6 — panic-path promote
  ordering (separate concern; shares the panic_caught entry point).
- `docs/bugs/NARROW_VEC_GOROUTINE_RETURN_CORRUPTION.md` — independent
  pre-existing async-return issue.
