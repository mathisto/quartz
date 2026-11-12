# For-loop iter/idx not saved/restored across kind=3 yield in `$poll` body

**Status**: FIXED 2026-04-25 in Phase 4.B.9 (slice 2). Six iteration-lowering sites in `mir_lower_iter.qz` now register their synthetic locals via `mir_gen_register_dynamic_local`, joining the two sites that already did. Spec: `for_loop_state_in_poll_spec.qz` — 6/6 green.
**Severity**: major — limits generator/helper expressiveness; collection iteration inside yield-suspending bodies doesn't work.
**Reproduces on**: every Quartz binary with kind=3 yield support BEFORE this fix (verified against `quartz-pre-p4b9b-for-loop-state-golden`).
**Filed under**: pre-existing — not introduced by Phase 4.B.8.

## Repro

```qz
def gen_from_vec(): impl Iterator<Int>
  var v = vec_new<Int>()
  v.push(10)
  v.push(20)
  v.push(30)
  for x in v
    yield x
  end
end

def main(): Int
  for x in gen_from_vec()
    puts(x.to_s())
  end
  return 0
end
```

Expected: `10\n20\n30\n`. Actual: SIGSEGV (exit 139), no output.

A simpler smoke that doesn't crash but exhibits the same bug — `can Yield` helper with for-in:

```qz
def emit_each(items: Vec<Int>): Void can Yield<Int>
  for x in items
    yield x
  end
end

def gen_from_vec(): impl Iterator<Int>
  var v = vec_new<Int>()
  v.push(10); v.push(20); v.push(30)
  emit_each(v)
end
```

Output under colorless lift (Phase 4.B.8): `10\n` only — first element, then iteration stops.

## Root cause

`mir_lower_async_poll` (and `mir_lower_actor_poll`, `mir_lower_async_generator`) collect the function's named locals via `mir_collect_generator_locals` and add them to the frame layout. The for-in desugar synthesizes ANONYMOUS locals `__for_iter_<n>` and `__for_idx_<n>` that hold the iterator handle and current index. These synthetic names ARE allocated as `alloca` inside `$poll`'s function body, but they are NOT in the frame layout — `mir_collect_generator_locals` doesn't see them, so the kind=3 perform site's spill loop misses them.

Each `$poll` invocation re-allocates the synthetic locals at the function-entry alloca block, initializing `__for_idx_<n>` to 0 implicitly (Quartz alloca semantics). On resume into `k3_perform_resume<N>`, the locals dictionary restores user-named vars from the frame, but the for-iter/for-idx allocas point to fresh stack slots with their initial state — the loop restarts at index 0 (or whatever the most recent `poll_start` block initialized them to).

Compounding factor in the direct-generator-with-for-in SIGSEGV: the for-iter alloca holds the Vec pointer. On resume, the alloca slot is fresh — typically zero — so the for-cond block dereferences a NULL Vec header and crashes.

## Architectural fix sketch (HISTORICAL — see "Actual fix" below)

The original sketch anticipated a substantial rewrite of `mir_collect_generator_locals` for ~2-3 quartz-days, via either two-phase collection or late frame-layout finalization with a post-lowering rewrite pass. **This was an over-estimate**: the existing `mir_gen_register_dynamic_local` hook plus the `GEN_FRAME_PADDING = 32` reserve already supported runtime registration of synthetic locals into the frame layout. The two iteration-lowering paths that already used the hook (`lower_custom_iteration` and `_lower_async_gen_iter_impl`) worked correctly across yields; the six paths that forgot to call it were the entire bug surface.

## Actual fix

Six 2-line additions in `self-hosted/backend/mir_lower_iter.qz`, one per iteration-lowering function:

| Function | Synthetic locals registered |
|---|---|
| `lower_vec_iteration` | `__for_iter_N`, `__for_idx_N` |
| `lower_slice_iteration` | `__for_slice_iter_N`, `__for_slice_idx_N` |
| `lower_channel_iteration` | `__for_chan_N` |
| `lower_string_iteration` | `__for_iter_N`, `__for_idx_N` (over `str_chars` Vec) |
| `lower_map_iteration` | `__for_iter_N`, `__for_idx_N` (over `map_keys` Vec) |
| `lower_closure_iteration` | `__cl_iter_N`, `__copt_N` |

Pattern matches what `lower_custom_iteration` already did (lines 610-611 pre-fix):

```qz
var iter_name = ctx.gen_for_temp("__for_iter")
var idx_name = ctx.gen_for_temp("__for_idx")
mir_lower_gen::mir_gen_register_dynamic_local(iter_name)  # NEW
mir_lower_gen::mir_gen_register_dynamic_local(idx_name)   # NEW
```

`mir_gen_register_dynamic_local` is a no-op outside generator context (`_gen_active == 0`), so non-generator iteration paths are unaffected. Inside generators, the spill loops in `mir_emit_async_suspend_point` and the kind=3 `k3_perform_resume<N>` blocks now save/restore the iter/idx slots along with the user-named locals.

## Why this didn't surface before Phase 4.B.8

Pre-4.B.8, the only way a generator body could yield was via a direct `yield v` inside its own body. The legacy `mir_lower_generator` (deleted in 4.B.7.a) emitted a state-machine `$next` that ran one yield-step per call — there was a state machine, but it didn't try to preserve outer-loop state across calls because the loop was inside an `if state == 0` switch arm that ran straight through (yields would unwind via longjmp).

Phase 4.B.7.b unified yields onto kind=3 perform with cooperative re-entry (4.B.8.a). Now a generator's `$poll` actually re-enters at a resume block on subsequent polls, exposing whatever state the resume block doesn't restore. For-loop synthetic locals were the first such state.

## Cap budget

`GEN_FRAME_PADDING = 32` reserved slots per frame. Worst case: 3 nested for-in loops = 6 slots. Headroom for ~16 nested iter+idx pairs before exhausting padding. If a real program ever hits the cap, two options: (a) bump padding to 64; (b) implement true late frame-layout finalization (the original sketch). Both are sub-day fixes. Not worth pre-empting.

## Verification

- `spec/qspec/for_loop_state_in_poll_spec.qz` — 6 tests covering direct generator, helper-from-generator, range (regression guard), nested for-in, partial+break, mixed for-in+State.
- All 6 pass post-fix; 5 previously failed with first-element-only / empty / repeat-first-element / restart-from-zero symptoms.
- Fixpoint preserved at 2333 functions (no codegen change, just additional name registration in MIR-time bookkeeping).
- Generator/p4b spec families: all green except the unrelated pre-existing `GENERATOR_NESTED_WHILE_DOUBLE_YIELD` bug (out-of-scope).

## Adjacent followups

- Generic helpers (`def emit_each<T>(items: Vec<T>): can Yield<T>`) hit a separate typecheck bug (`Undefined variable: x` inside the for-in body); filed in `GENERIC_HELPER_FOR_IN_SCOPE.md`. Independent of this fix.
- A separate compiler crash fires on the exact pattern `def gen(): impl Iterator<Int>; var v = vec_new<Int>(); v.push(...); for x in v; yield x; end` — type-arg-on-call form inside a direct generator. Workaround: use `var v: Vec<Int> = vec_new()` (annotated form). Crash is push-count sensitive: 1, 2, 4 pushes compile; 3 pushes deterministically SIGSEGV the compiler. Wholly separate from for-loop state preservation; filed in `VEC_NEW_TYARG_IN_GEN_BODY_CRASH.md`.
