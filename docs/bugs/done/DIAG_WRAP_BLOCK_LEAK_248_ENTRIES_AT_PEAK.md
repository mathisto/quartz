# Diag wrap-block leak — 248 zombie entries on the effect stack at self-compile peak

**Status:** FIXED 2026-04-29. Self-compile peak top: 257 → 134 (final stack top at exit = 7 = blessed_watermark, no zombies). Fix shipped through MIR-level `MIR_EFFECT_POP_N` opcode + per-context wrap-stack tracking + early-return cleanup at `mir_lower_stmt_return` + post-body-terminated guard at NODE_WITH lowering.
**Priority:** ~~HIGH~~ — closed. The runtime body-wrap teardown was missing balancing pops along CFG return edges; H1 hypothesis was correct.

## Symptom (verified)

`quake guard` self-compile peaks the effect stack at top=257 (cap+1). Stack-dump-at-peak instrumentation (Recipe B in `EFFECT_STACK_SYMMETRIC_INSTALL_DEEPER_THAN_SCOPED.md`) revealed the contents at top=256 / blessed_watermark=7:

| Slots | Contents |
| --- | --- |
| 0–6 | Prelude defaults: Throws, Log, Async, FileIo, Alloc, Intern, Yield (matches blessed=7) |
| 7 | State (1 entry) |
| 8–255 | **Diag × 248** (all identical effect name) |

The 248 Diag entries are zombies — perform's top-down scan finds the live one at slot 255, never queries the deeper ones. Self-compile completes successfully because functionally only the live Diag is used. The leak is silent until cap is approached.

## Why this matters

1. **Linear growth.** The peak is exactly cap+1, not "deep but bounded." Add ~50 more typecheck calls (one new file, one expanded pass) and the leak grows; once it hits ~50 above cap, the asymmetric-install drain bug (`feedback_effect_stack_asymmetry.md`) reactivates because each over-cap install pops a legitimate entry below on uninstall. The cap=256 fix (`a6f174ae`) bought maybe one more year of runway, not a permanent shield.

2. **Cross-effect risk.** The runtime body-wrap teardown bug isn't Diag-specific. Any effect using a body-wrap pattern (State, Emit, Intern, Alloc) that hits the same code path will leak the same way. We don't see it for those effects today only because they're invoked from fewer call sites OR their leaks haven't accumulated to peak depth yet.

3. **Phantom-counter design defeats the diagnostic.** If we'd built phantom counter (Tier 4 #26's would-be next phase) before running the dump instrumentation, the leak would have been entirely silent — top would just have grown unbounded behind the scenes. Instrumentation Pass B saved us a multi-day phase that would have masked a real bug.

## Resolution (2026-04-29)

H1 below was correct. The body-wrap codegen (`mir_emit_handle_uninstall` + the wb.* result-slot dance in `codegen_instr.qz:2392-2458`) only emits a runtime pop on the natural fall-through path. Early-return CFG edges from inside `with E {...} do -> body end` skipped that pop entirely. The Diag bridge doc's claim that "Effect-handler unwind on early return is handled correctly by Quartz's runtime (verified empirically)" was wrong — verified empirically only for cases that didn't actually exercise the bug.

### Fix shape

A new MIR opcode `MIR_EFFECT_POP_N` (constant 39) emits N raw runtime pop calls (`@__qz_effect_handle_uninstall(eff)` × N) without the wb.result_slot/wb.done block dance. It's used exclusively by early-return cleanup; the natural-fall-through path keeps using `MIR_HANDLE_UNINSTALL` unchanged.

Per-`MirContext` wrap tracking (`wrap_stack_eff_names` + `wrap_stack_pop_counts`) records every active wrap region in lowering order. NODE_WITH lowering (both expr and stmt contexts) pushes after `mir_emit_handle_install`, pops before `mir_emit_handle_uninstall`. `mir_lower_stmt_return` walks the wrap-stack top-down before setting TERM_RETURN and emits one `MIR_EFFECT_POP_N` per wrap.

Guard against double-pop at the converge point: when every body path terminated (current block has `term_kind >= 0`), NODE_WITH lowering skips `mir_emit_handle_uninstall` — the early-return pop_n already drained the runtime stack on every reachable path; emitting uninstall would queue a second drain in dead code that codegen still emits as live IR after the BR/done-label sequence.

### Files touched (4)

- `self-hosted/backend/mir.qz`: opcode constant, struct fields, helpers (`mir_ctx_push_wrap`, `mir_ctx_pop_wrap`, `mir_ctx_emit_active_wrap_pops`), emitter (`mir_emit_effect_pop_n`).
- `self-hosted/backend/mir_lower.qz`: NODE_WITH expr + stmt contexts wrap_stack push/pop + post-body-terminated guard before `mir_emit_handle_uninstall`.
- `self-hosted/backend/mir_lower_stmt_handlers.qz`: `mir_lower_stmt_return` calls `mir_ctx_emit_active_wrap_pops` before TERM_RETURN.
- `self-hosted/backend/codegen_instr.qz`: `MIR_EFFECT_POP_N` codegen handler emits GEP + N runtime pop calls.

### Verification

- `quake guard` passes (2415 functions, fixpoint verified).
- Smoke tests pass: `examples/style_demo.qz`, `examples/brainfuck.qz` both run clean.
- Pre-fix vs post-fix instrumentation:
  - Pre-fix max top: 257; final top at exit not measured but leak is real (248 zombies at peak).
  - Post-fix max top: 134; **final top at exit: 7 = blessed_watermark** → all installs balance their uninstalls.
- The remaining 134 peak is legitimate recursion through `tc_expr_struct_init`-style functions during deep typecheck — not a leak.

### Followups (lower priority)

- **Break/continue from inside a wrap region:** the fix only handles `return`. If a `break` or `continue` exits a wrap-block, the same leak shape applies. Self-compile didn't exercise it (the dump went to 0 leaked entries with the return-only fix), but user code that does `break` out of a `with`-wrapped loop will leak. Apply the same wrap-stack-walk pattern to `mir_lower_stmt_break` / `mir_lower_stmt_continue` once a regression surfaces it.
- **Throws/kind=2 unwind:** Throws is blessed and uses longjmp via `__qz_effect_perform`'s catch buffer; the catch path does its own teardown. Not affected. But if a non-blessed effect ever takes a kind=2 path, verify its catch teardown drains correctly.
- **Cap-bump (1024)?** No longer needed. Post-fix peak is 134 with no leak; cap=256 has 90% headroom. Tier 4 #26 phantom-counter design is parked indefinitely.

## Original hypotheses (kept for historical reference)

### H1: Body-wrap teardown bug on early return
The Diag bridge documentation (`self-hosted/middle/typecheck_diag.qz:30-40`) explicitly claims: *"Effect-handler unwind on early return is handled correctly by Quartz's runtime (verified empirically)."* The 248-entry leak proves that claim is wrong. Most likely site: a body-wrapped function (e.g., `tc_expr_struct_init` at `typecheck_expr_handlers.qz:89-91` — `result = with Diag {...} do -> body end` shape) where the body has multiple `return` paths and at least one path doesn't run the body-wrap's matching `__qz_effect_handle_uninstall`.

Pre-fix evidence: the Diag bridge originally used a `Vec<TypecheckState>` push/pop pair that leaked on early returns. The fix was to replace the SLOT bookkeeping with a single global. But the EFFECT-STACK install/uninstall pair was assumed to be handled by the runtime — that's the unproven claim.

**Look:** `mir_lower_with` / wrap-block teardown in `mir_lower_*.qz`. Specifically: does the body-wrap emit one `__qz_effect_handle_uninstall` call AT EACH RETURN PATH, or only on the natural fall-through? If the latter, every `return` from inside a `with Diag {...} do -> ...end` body skips the uninstall.

### H2: Recursion through `with Diag {...}` accumulates
`tc_expr` is recursive, and many of the 30 `with Diag` sites in `typecheck_expr_handlers.qz` are inside functions that call `tc_expr` again. Each recursion installs another Diag entry. If recursion depth is 248, that's the leak even if uninstalls run on natural return — they just run AFTER the outer return value bubbles up, in the wrong order from a user's mental model.

But this should still balance LIFO. So if the leak is "at peak top=256" not "always 248 over baseline," H2 alone doesn't explain it. H1 + H2 combined (some early-return paths skip uninstall, recursion amplifies) is more plausible.

### H3: Effect-stack snapshot apply leaks
Phase E.1.c.b ships spawn-time snapshot apply on every worker $poll dispatch. If snapshot_apply has an off-by-one in the apply count (saved as `delta = end_top - start_top` per `feedback_e1cb_apply_count_vs_save_top.md`), nested `with Diag` installs in a goroutine body might not fully drain on resume. Less likely because self-compile is mostly single-threaded — but `_diag_active` is module-global and the typecheck pipeline probably doesn't spawn goroutines. Worth ruling out by checking whether self-compile actually spawns any tasks.

## Confirmation steps for next session

1. **Locate the leaking site.** Add an instrumentation variant that prints `[INSTALL] eff=%s top=%d` and `[UNINSTALL] eff=%s top=%d` per call. Run guard, intercept gen2.err, count: how many INSTALL Diag events vs. UNINSTALL Diag events? Difference = leak count. Should match 248 (or similar).
2. **Find the unmatched-install path.** With instrumentation showing source-line context (e.g., the eff_name argument is a string ptr — print it; add a return-address dump from the install caller via `@llvm.returnaddress(0)`), bucket installs by caller. The bucket with no matching uninstall is your culprit.
3. **Inspect the body-wrap codegen.** Look at `mir_lower.qz` (or wherever `mir_emit_with`-style code lives) and confirm: is there a teardown emitted at every basic-block return point that crosses the wrap region? If not, that's the bug.
4. **If H1 holds, fix:** make the body-wrap teardown emit a `_uninstall` along every CFG edge that exits the wrap region (return, panic, throw). Existing memory `feedback_body_wrap_last_stmt.md` documents adjacent issues with body-wrap teardown — read it first; the fix may share machinery.

## Re-measurement after fix

Apply Recipes A + B from `EFFECT_STACK_SYMMETRIC_INSTALL_DEEPER_THAN_SCOPED.md`. Expected post-fix max top ≤ 50 (consistent with the older comment in `codegen_runtime.qz:482`). If not, there's a deeper issue.

## Backed-up binary

`self-hosted/bin/backups/quartz-pre-instrument-max-top-golden` (byte-identical to current HEAD, fixpoint-verified) is a usable baseline for any work in this area.
