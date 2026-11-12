# Wrap-block leak on break / continue from inside `with E {...} do -> ... end`

**Status:** ✅ RESOLVED 2026-04-29.
**Resolved by:** loop_wrap_depth tracking + new MIR_HANDLE_UNINSTALL_DONE_ONLY opcode. NODE_BREAK / NODE_CONTINUE drain wrap-stack entries opened inside the loop body via `mir_ctx_emit_wrap_pops_to_depth(loop_entry_wrap_depth)` before `TERM_JUMP`. All 11 loop-entry sites (8 in mir_lower_iter.qz, 1 in mir_lower.qz for_await, 2 in mir_lower_stmt_handlers.qz) save / set / restore `loop_wrap_depth`; labelled break/continue lookup via new `mir_ctx_find_loop_wrap_depth(label)` mirrors `mir_ctx_find_loop_scope_depth` against an extended 5-element loop_stack entry.

**Bonus fix (latent bug exposed during verification):** the original Diag-leak fix's post-body-terminated guard (`ec90e98f`) skipped MIR_HANDLE_UNINSTALL when every body path terminated, but `wb.catch.NN`'s `br label %wb.done.NN` (emitted by MIR_HANDLE_INSTALL for the longjmp-resume path) still required `wb.done.NN` to be defined for valid IR. Self-compile didn't exercise it; Quakefile.qz did (via `def foo() = with E do -> ...; return 0 end ; return 0 end` shape). Pre-fix repro: llc rejected with `use of undefined value '%wb.done.0'`. New MIR_HANDLE_UNINSTALL_DONE_ONLY opcode emits ONLY the `wb.done.NN: load + uninstall × pop` block (skips body-fall-through prefix to avoid the original double-pop). NODE_WITH lowering switches to a fresh MIR block in the post-body-terminated case so the new opcode emits cleanly. Codegen handler emits a bridge `br label %wb.done.NN` before the label so two consecutive labels never collide.

**Verification:**
- `quake guard` passes (2420 functions, fixpoint verified, +5 from pre-fix 2415).
- 4-test regression spec at `spec/qspec/wrap_block_break_continue_spec.qz` (for + break, while + continue, labelled break across nested loops, plain break-no-wrap regression guard).
- Smoke tests: style_demo, brainfuck, Quakefile.qz (was the latent-bug witness — now compiles cleanly).
- Sweep: diag_effect, diagnostics, effect_handler_narrow, cross_defer_safety, range_step, safety_adversarial — all green.
- Original Diag latent-bug repro now llc-clean.

**Component (resolved):** `self-hosted/backend/mir_lower.qz` (NODE_BREAK / NODE_CONTINUE drain emit + post-body-terminated switch), `self-hosted/backend/mir_lower_iter.qz` + `mir_lower_stmt_handlers.qz` (loop-entry save/set/restore), `self-hosted/backend/mir.qz` (loop_wrap_depth field + helpers + DONE_ONLY emitter), `self-hosted/backend/codegen_instr.qz` (DONE_ONLY codegen handler).

---

> Original filing (kept for design rationale):

**Status:** OPEN — followup from the Diag wrap-block leak fix (`ec90e98f`, 2026-04-29). The return-path leak is closed; the analogous break/continue paths still leak.
**Priority:** LOW — not exercised by self-compile, no current spec failure points at it. Filed per Prime Directive 6 ("Holes get filled or filed") so the next session that hits it in user code has the design ready.
**Component:** `self-hosted/backend/mir_lower.qz` (NODE_BREAK / NODE_CONTINUE branches at lines 3682-3745) + `self-hosted/backend/mir.qz` (wrap-stack helpers around line 3882-3912).

## Symptom (predicted, not observed)

```be
with Diag {emit: my_handler} do ->
  for x in items
    if x.bad?
      break              # ← runtime effect-stack leaks one Diag entry per break
    end
    process(x)
  end
end
```

Each break/continue out of a loop nested inside a `with E {...} do -> body end` skips the runtime `__qz_effect_handle_uninstall` for E. The leak grows linearly with the number of break/continue executions across all wrap-block-enclosing loops in a program. At sufficient scale it pushes the effect-stack toward cap=256 (the bound the Diag leak hit pre-fix).

## Why the return-path fix doesn't cover this

The return-path fix (`ec90e98f`) emits `MIR_EFFECT_POP_N` for **every** active wrap before `TERM_RETURN`. For break/continue that's wrong: the loop's *enclosing* wraps must stay live (we're not exiting the function, just the loop), only wraps **inside** the loop body need draining.

Concrete case where return-style "drain all" would over-pop:

```be
with Outer {...} do ->
  for x in items
    with Inner {...} do ->
      if cond
        break    # must pop Inner, must NOT pop Outer
      end
    end
  end
end
```

A naive `mir_ctx_emit_active_wrap_pops()` call here would emit pops for both Outer and Inner; the natural fall-through after the loop would then double-pop Outer.

## Existing precedent in the same file: drops + defers already handle this

Both NODE_BREAK and NODE_CONTINUE in `mir_lower.qz:3706-3711, 3735-3740` already track loop-scope-relative depth:

```be
var target_defer_depth = ctx.mir_ctx_get_loop_defer_depth()
emit_deferred_to_depth(ctx, target_defer_depth)
if target_scope_depth >= 0
  emit_drops_for_scope(ctx, target_scope_depth + 1)
end
```

The fix mirrors this pattern for the wrap-stack: record the wrap-stack depth at loop entry, drain only down to that depth on break/continue.

## Fix shape (concrete)

### 1. New per-loop watermark

In `MirContext` (mir.qz, near the existing `loop_defer_depths` / `loop_scope_depths` vectors), add:

```be
loop_wrap_depths: Vec<Int>     # parallel to the existing loop stack
```

Push/pop in lockstep with the existing loop scope tracking — wherever `loop_defer_depths` is pushed/popped, push/pop the current `wrap_stack_eff_names.size`.

### 2. New helper in mir.qz

Adjacent to `mir_ctx_emit_active_wrap_pops`:

```be
## Drain wrap-stack entries from current depth down to a target depth (exclusive).
## Used by break/continue lowering: target_depth = wrap-stack size at loop entry.
def mir_ctx_emit_wrap_pops_to_depth(ctx: MirContext, target_depth: Int): Void
  var _i = ctx.wrap_stack_eff_names.size - 1
  while _i >= target_depth
    var _eff = ctx.wrap_stack_eff_names[_i]
    var _n = ctx.wrap_stack_pop_counts[_i]
    mir_emit_effect_pop_n(ctx, _eff, _n)
    _i -= 1
  end
end
```

Plus a getter `mir_ctx_get_loop_wrap_depth()` that mirrors `mir_ctx_get_loop_defer_depth`.

### 3. Wire into NODE_BREAK / NODE_CONTINUE

In `mir_lower.qz:3706-3711` and `mir_lower.qz:3735-3740`, after the existing defer/drop emission, before the `mir_block_set_terminator(...)`:

```be
var target_wrap_depth = ctx.mir_ctx_get_loop_wrap_depth()
ctx.mir_ctx_emit_wrap_pops_to_depth(target_wrap_depth)
```

Like return's fix, this MUST emit before TERM_JUMP and MUST NOT pop the wrap-stack itself (the natural fall-through path is the one that pops via `mir_ctx_pop_wrap`; break/continue is an alternate exit).

### 4. Push/pop loop watermark at loop boundaries

In `mir_lower.qz` wherever loop-scope depth is pushed (search for `loop_scope_depths.push` / equivalent for-loop entry sites), push the current wrap-stack size; pop on loop exit.

## Subtleties

- **Labelled break.** When `break label` jumps past intermediate loops, the watermark must be the wrap-depth at the *labelled* loop's entry, not the immediate loop. The existing `mir_ctx_find_loop_scope_depth(label)` shows the lookup pattern; mirror it for `mir_ctx_find_loop_wrap_depth(label)`.
- **Post-body-terminated guard already handles dead-code IR.** No NODE_WITH lowering change needed: the existing guard added in `ec90e98f` (mir_lower.qz) skips `mir_emit_handle_uninstall` when every body path terminated. break/continue counts as termination for that check.
- **Async / generator yield boundaries.** A `break` from inside a generator body that's also inside a wrap-block would need the same drain. Likely already covered by this fix (generator yield doesn't traverse break/continue paths), but verify by reading `mir_lower_gen.qz` for any generator-internal break handling.
- **Throws + cross-scope longjmp.** Already documented in the Diag fix doc (Throws is blessed, kind=2 longjmp catch teardown is separate path). Not affected.

## Verification plan

1. **Targeted spec.** New `spec/qspec/wrap_block_break_continue_spec.qz`:
   - `for` + `break` from inside `with E { } do -> body end` — assert effect stack final-top equals `blessed_watermark` (no leak).
   - `while` + `continue` analogue.
   - Labelled break across two nested loops both inside a wrap.
   - Inner `with` inside loop with break — assert outer wrap survives, inner is drained once.
2. **Self-compile.** `quake guard` — pass (function-count likely +2 for the new helper + getter).
3. **Smoke.** style_demo + brainfuck + Quakefile.qz (none currently exercise the path; pure regression guard).
4. **Optional: max-top instrumentation.** Apply Recipe A from `EFFECT_STACK_SYMMETRIC_INSTALL_DEEPER_THAN_SCOPED.md` to a synthetic stress program (10K-iter loop with break inside `with Diag`) — pre-fix should grow toward cap=256, post-fix should stay at `blessed_watermark + 1` peak.

## Estimate

~30-50 LOC. Quartz-time: ~0.5 day if done in one pass. The existing return-path fix (`ec90e98f`) is the template — same wrap-stack data structure, new `to_depth` variant of the drain helper, two watermark push/pop sites at loop boundaries, two callsites in break/continue lowering.

## Why deferred

- **No witness.** Self-compile completes without exercising the leak path (the compiler doesn't break/continue out of `with E {...}` blocks). No current QSpec test breaks.
- **Correctness scope is bounded.** Cap=256 with post-Diag-fix peak=134 has 90% headroom. A leak would need to grow ≥120 entries to start losing handlers, which requires a hot loop with break inside a wrap-block executed at scale.
- **Design has subtlety.** Watermark tracking + labelled break + interaction with droppable scope depth all need to compose correctly; rushing the fix without a regression test risks introducing a different leak (drain-too-much over-pops; drain-too-little leaks). Better to file with the design sketch and wait for either a witness in user code or a spec test that exercises the path.

## Reference

- Diag-leak fix that established the wrap-stack pattern: commit `ec90e98f`, archived doc `done/DIAG_WRAP_BLOCK_LEAK_248_ENTRIES_AT_PEAK.md`.
- Loop-scope-relative bookkeeping precedent: `emit_deferred_to_depth` + `emit_drops_for_scope` in `mir_lower.qz:3706-3711`.
- Memory entry: `feedback_effect_stack_asymmetry.md` — update to mention this followup once landed.
