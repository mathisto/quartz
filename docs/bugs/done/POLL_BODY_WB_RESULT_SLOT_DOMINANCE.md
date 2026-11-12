# `__Future_<fn>$poll` codegen places `wb.result_slot.NN` alloca inside an inner basic block, breaking SSA dominance under sequential `with` blocks

**Filed**: 2026-04-28 during Phase E.6 spec authoring.
**Status**: ✅ **RESOLVED 2026-04-28** — `wb.jmpbuf.<dest>` and
`wb.result_slot.<dest>` allocas are now hoisted to `fn_entry` alongside
the existing `MIR_CONST_INT` / `MIR_ALLOC_STACK` hoists in
`codegen.qz`. `fn_entry` dominates every block, including async-resume
re-entry paths via `poll_switch` that bypass the block where inline
emission would otherwise place the alloca. The reinstated absorbed-vs-direct
go_race test in `spec/qspec/alloc_e6_spawn_variants_spec.qz` doubles
as a regression test. Original filing kept below for historical context.

---

## Symptom

When a function `f`:
1. Is auto-emitted as `__Future_f$poll` (because it transitively calls
   an `await`-using function or otherwise gets the lazy-async treatment)
2. Has two sequential top-level `with E {...} do -> ... end` blocks
3. The second block's body calls into machinery that interacts with
   the poll's frame layout (e.g., `go_race(tasks)` whose internal
   `await handles[ri]` loop)

…the `$poll`'s LLVM IR places the SECOND `wb.result_slot.NN` alloca
inside the FIRST `with` block's `wb.body.M` basic block. The store and
load of that slot happen later in `wb.body.NN` and `wb.done.NN` (the
second block), which are reachable from BOTH the first block's
`wb.catch.M` AND `wb.body.M`. The catch path never executes the
alloca → SSA dominance violation.

`llc` rejects the IR with:

```
Instruction does not dominate all uses!
  %wb.result_slot.NN = alloca i64, align 8
  store i64 %vXX, ptr %wb.result_slot.NN, align 8
Instruction does not dominate all uses!
  %wb.result_slot.NN = alloca i64, align 8
  %vYY = load i64, ptr %wb.result_slot.NN, align 8
llc: error: '...': input module cannot be verified
```

The non-`$poll` (sync) version of the same function compiles cleanly —
only the `$poll` variant is broken.

## Minimal repro

```be
import concurrency
import std/alloc

def fast_racer(): Int
  var v = vec_new<Int>()
  for i in 0..500
    v.push(i)
  end
  return 1
end

def slow_racer(): Int
  var v = vec_new<Int>()
  for i in 0..500
    v.push(i)
  end
  return 2
end

def main(): Int
  sched_init(1)

  alloc_reset_tracking()
  with Alloc { alloc: tracking_alloc_handler, dealloc: tracking_dealloc_handler } do ->
    fast_racer()
    slow_racer()
    0
  end
  var direct = alloc_tracking_alloc_count()

  alloc_reset_tracking()
  with Alloc { alloc: tracking_alloc_handler, dealloc: tracking_dealloc_handler } do ->
    var tasks = vec_new()
    tasks.push(fast_racer)
    tasks.push(slow_racer)
    var winner = go_race(tasks)
    0
  end
  var via_race = alloc_tracking_alloc_count()

  puts(str_from_int(direct))
  puts(str_from_int(via_race))
  sched_shutdown()
  return 0
end
```

Compile + llc:

```
$ ./self-hosted/bin/quartz --no-cache repro.qz > repro.ll 2>/dev/null
$ llc -filetype=obj repro.ll -o /dev/null
Instruction does not dominate all uses!
  %wb.result_slot.15 = alloca i64, align 8
  ...
```

## Why is `__Future_main$poll` even generated?

`main` doesn't call `await` directly. But it calls `go_race(tasks)`, and
`go_race`'s body uses `await handles[ri]` in a loop. The compiler's
async-promotion path appears to lift main into a `$poll` variant
because of the transitive await reachability through `go_race`. The
sync `qz_main` is also generated (and is correct); only the `$poll`
variant has the misplaced alloca.

The "lift to $poll for any function whose call graph reaches await"
behavior is itself worth confirming — if main is never actually
polled, the entire `__Future_main$poll` could be dead code.

## Root cause hypothesis

The codegen path for `wb.result_slot.NN` allocates the slot at the
emission point of the `with E { ... }` install (inside the wb.body of
the previous `with` block, since that's where the first `with`'s body
emits its tail). LLVM's SSA verifier requires alloca to be in a basic
block that dominates all uses; the standard idiom is to put allocas
in the function's entry block (`fn_entry` here).

Quick fix: lift all `wb.result_slot.NN` (and likely `wb.jmpbuf.NN`)
allocas to the enclosing `$poll`'s `fn_entry` block. The non-`$poll`
sync variant of the same function presumably uses a different emission
path that already does this lifting, which is why `qz_main` compiles
cleanly.

Likely the emission site is in `codegen_instr.qz` or the with-block
lowering in `mir_lower_expr_handlers.qz`; under the sync path, allocas
are emitted at function-entry; under the async/$poll path, they're
emitted inline at the IR cursor (which is inside the first wb.body
when the second `with` is reached).

## Workarounds

- **Single `with` block per function for code that needs `$poll`
  generation**: rewrite to combine the two `with E {...}` blocks into
  one, accumulating both halves' work inside a single body. Avoids the
  alloca-position bug.
- **Force sync compilation**: keep the await-using function in a
  callee, never put two `with` blocks at top level of the caller.
- **Spec authoring**: when testing primitives whose internals use
  `await`, structure tests with a single `with E {...}` block, or
  put the second block inside a separate test program.

## Pull-in trigger

User pattern that needs both:
- Two sequential `with` blocks for measurement (e.g., direct vs
  via-X), AND
- The second block calls a function whose `await` lifts the caller
  into `$poll`.

Phase E.6 spec authoring hit this for the `go_race` absorbed-vs-direct
test. Worked around by replacing that test with a correctness check
(go_race returns a valid winner). The absorbed-vs-direct measurement
is still covered by E6.a (`go_spawn`) and E6.b (`go_cancellable`),
neither of which lifts main into `$poll`.

## Next-step plan when pulled in

1. **Verify the lift trigger.** Does `main` calling ANY await-using
   function force `$poll` generation? Or only certain shapes? Audit
   the async-promotion logic in `mir_lower_async_registry.qz` and
   adjacent.
2. **Audit `wb.result_slot.NN` emission site.** Find where it's
   alloca'd in codegen. Compare sync-path vs $poll-path emission.
3. **Move allocas to fn_entry.** Standard LLVM idiom. The `wb.jmpbuf.NN`
   should similarly be at fn_entry; check.
4. **Verify the dead-code suspicion.** If `__Future_main$poll` is
   never actually polled (main isn't a Future), consider gating
   `$poll` generation more precisely so we don't emit broken code for
   functions that don't need it.

## Cross-link

- `feedback_body_wrap_last_stmt.md` — body-wrap codegen quirks (related
  but distinct: that memo covers function-body wraps, this bug is
  about sequential top-level wraps).
- `feedback_with_block_method_resolution.md` — UNREPRODUCIBLE post-
  P5.3.d.3 (related family of with-block IR bugs).
