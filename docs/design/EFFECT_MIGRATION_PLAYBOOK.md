# Effect Migration Playbook

> **Epic**: Operation Piezoelectric Effects · `[piezo]` · Phase 5 retrospective
> **Status**: Distilled from five dogfood migrations (Phases 5.1-5.5), 2026-04-21 through 2026-04-23
> **Audience**: anyone migrating a new capability in the Quartz compiler (or a large Quartz program) to an algebraic effect
> **See also**: [`docs/EFFECTS.md`](../EFFECTS.md) (historical Piezo design and provenance), [`docs/QUARTZ_REFERENCE.md`](../QUARTZ_REFERENCE.md) (current user-facing executable semantics), [`docs/design/DIAGNOSTICS_EFFECT.md`](DIAGNOSTICS_EFFECT.md) (P5.1 design memo), the five `project_piezo_phase_5_*.md` memory files

## Purpose

This is a procedure, not a history. Five Phase-5 migrations converged on the same shape; this doc is that shape, written so the sixth migration (and beyond) can follow the recipe instead of rediscovering it.

The recipe has three parts:

1. **The three-pass bootstrap** — how to migrate without breaking the compiler mid-flight.
2. **The bridge-over-cascade pattern** — how to drop a pass-lifetime parameter without a `can E` cascade.
3. **The incident ledger** — five sharp edges that caught us, each now a one-line rule.

---

## 1. The three-pass bootstrap

The self-hosted Quartz compiler is the thing migrating the thing. If any intermediate state produces a compiler that can't compile itself, fixpoint breaks and recovery is expensive. So every Phase-5 migration split into three passes, ordered by risk.

### Pass 1 — Typecheck-only propagation

Add the effect declaration. Add it to the D.4 blessed-relaxation list if the effect is a default-of-the-world (filesystem, stdout, interning) rather than a sandbox gate (Throws, user-exposed capabilities).

Migrate the first small slice (3–5 callsites) by **wrapping** them at the callsite:

```quartz
var x = with FileIo { fio_read: file_io::fio_default_read } do ->
  fio_read(path)
end
```

The wrap *adds* a new effect-install on the stack and routes the op through it. Nothing else in the compiler has changed; the wrap's handler calls the same libc-backed default that unwrapped code would have called.

**Ship this pass when**: `quake guard` passes, smoke tests pass, no callsite behavior has changed. Functions called *by* the wrapped site do not yet know about the effect.

**Check before you ship**: the first wrap's return-shape. Body-wraps whose do-block's last statement is `return X` violate SSA dominance at the merge block. Last statement must be a **bare expression** ([`feedback_body_wrap_last_stmt.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/feedback_body_wrap_last_stmt.md)). Mid-body `return`s are fine.

### Pass 2a — Install the default handler in the main prelude

Add an inline-LLVM handler to `codegen_runtime.qz::cg_emit_effect_runtime` and install it in `cg_emit_effect_main_prelude` alongside Throws/Log/Async. Dispatch on op name in the handler body; call libc or a Quartz intrinsic directly (no symbols from the stdlib — they may not be linked).

At this point, unwrapped `fio_read(...)` / `log::info(...)` / `intern(...)` callsites already dispatch correctly. The per-callsite wraps in Pass 1 are redundant (they install a second handler above the prelude one) but harmless.

**Ship this pass when**: `quake guard` still passes, cache-enabled `quartz --no-opt self-hosted/quartz.qz` on the compiler exits 0. This is the critical test — fixpoint uses `--no-cache` and does not exercise the cache-store/cache-load paths where effect-stack state gets touched at different depths.

### Pass 2b — Delete the wraps

Once every callsite is covered by Pass 2a's prelude install, the per-callsite wraps add zero behavior. Delete them. Each wrap reduces to its body expression or statement. LOC win typically 3:1.

**Ship this pass when**: cache-enabled self-compile still passes on cold (empty cache) *and* warm (populated cache) paths. The warm path is where stack-depth asymmetries surface.

**Gotcha**: do not use `replace_all` on helper renames — it will rewrite the effect-op call *inside* the helper's body-wrap, creating infinite self-recursion. Fixpoint builds clean; SIGSEGV on any subsequent compile, no crash report ([`feedback_replace_all_helper_body.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/feedback_replace_all_helper_body.md)).

### Why three passes and not one

Collapsing 2a+2b is the obvious shortcut. It works when the effect is fresh (nothing was migrated yet). It fails when migration is already in flight: Pass 2a's prelude install interacts with the per-callsite wraps' install/uninstall counts, and a half-migrated compiler can produce a self-consistent broken binary that still passes fixpoint.

The empirical cost of ignoring this: the FileIo wrap-deletion debug sprint (2026-04-22 to 2026-04-23, ~two sessions), which ended up being a latent stack-cap bug unmasked by Pass 2b. See §3.

---

## 2. Bridge-over-cascade

The promise of algebraic effects is that a leaf function can stop threading a context object through its signature — the effect handler's scope threads it for you. The Quartz reality is that `can E` annotations still have to propagate up the call graph unless the call is within a `with E {...} do ... end` block, and that cascade hits two walls:

1. **LOC**: ~280 typecheck callsites in Phase 5.1's Diag pilot meant ~280 function signatures grew a `can Diag`. The LOC "savings" from dropping the `tc` param got cancelled by the cascade.
2. **Runtime bug**: cascading `can State` through typecheck triggered a runtime `unhandled effect op called` at a dynamic callsite that the static `can` analysis said was covered. Filed in [`docs/bugs/STATE_CASCADE_TC_PARSE_TYPE_RUNTIME_FAIL.md`](../bugs/STATE_CASCADE_TC_PARSE_TYPE_RUNTIME_FAIL.md). Never fully root-caused; bridge pivot sidestepped it.

**The pattern**: don't cascade. Set a single-slot module-global (the "bridge") once, near `compile()` entry, inside the outermost `with E { ... } do ->` wrap. Leaves read the slot directly — no `can E` on their signatures, no wrap at their site.

```quartz
# typecheck_ctx.qz
var _tc_ctx_slot: TypecheckState = null_state()

def tc_ctx_set(tc: TypecheckState): Void
  _tc_ctx_slot = tc
end

def tc_ctx_get(): TypecheckState = _tc_ctx_slot

# typecheck.qz — inside the outermost body-wrap
def typecheck(root: Int, ...): Int
  var tc = tc_new(...)
  var result = with State { get: _tc_ctx_handler } do ->
    tc_ctx_set(tc)
    tc_program(root)   # leaf; reads tc via tc_ctx_get() — no `can State`, no `tc` param
    0
  end
  tc_ctx_set(null_state())
  return result
end
```

**When bridge is right**: the parameter is a *pass-lifetime* context — valid for the entire compile, set once, read many. TypecheckState, MirProgram, codegen state. The effect is there for testability (handler override) and for the conceptual "this leaf may diagnose," not for data flow.

**When cascade is right**: the parameter would be shadow-scoped anyway. Per-function allocators, per-scope arenas, anything that naturally pushes/pops. Here the cascade expresses real structure.

**Decision rule**: if the parameter's lifetime equals `compile()`'s lifetime, use a bridge. Otherwise cascade. Full writeup: [`feedback_bridge_over_cascade_pattern.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/feedback_bridge_over_cascade_pattern.md).

---

## 3. Incident ledger

Five sharp edges, each paid for once, each now a rule.

### 3.1 Effect-stack install/uninstall asymmetry

`__qz_effect_handle_install` silently no-ops at cap (was 32 slots). `__qz_effect_handle_uninstall` unconditionally decrements. At the boundary, each overflow-install's later uninstall pops a legitimately-installed entry from below. Over many overflow incidents during self-compilation, the stack drained the prelude defaults and surfaced as `unhandled effect op called` at depths that had nothing to do with the overflow site.

**Fix**: cap raised 32→256 in `a6f174ae` (7.7× headroom over the max observed depth of 33).

**Rule**: verify cache-enabled self-compile on both cold and warm paths before shipping a wrap-deletion pass. Do not trust `quake guard` — it runs `--no-cache`.

**Truly-symmetric design (Tier 4)**: always increment `stack_top` on install; clamp reads in perform/state-accessors to `[0, CAP)`. Filed in [`FILEIO_WRAP_DELETION_UNHANDLED_FIO_WRITE.md`](../bugs/FILEIO_WRAP_DELETION_UNHANDLED_FIO_WRITE.md) §Remaining followup.

### 3.2 Body-wrap shadows outer customization

Per-callsite body-wraps that hardcode the default handler defeat outer `with E { op: mock } do -> compile() end` overrides. The innermost install wins the top-down scan. This is **fine** for dogfooding effects that have no user customization story (State<TcCtx>, Diag, Emit). It is **wrong** for effects whose whole point is customization — test sandboxing for FileIo, mock interning for Intern.

**Rule**: if the effect has a user-customization story, use the prelude-install-plus-blessed-relaxation pattern (no per-callsite wraps). If it's pure dogfooding, per-callsite wraps are fine.

**When in doubt**: ask "would a test want to substitute this?" If yes, the wrap shadows that ability. Remove the wrap.

Full writeup: [`feedback_bodywrap_shadows_outer_customization.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/feedback_bodywrap_shadows_outer_customization.md).

### 3.3 Body-wrap last-statement gotcha

`with E {...} do -> ...body... end` as a function-body wrap MUST end with a bare expression, never `return X`. `return` as the last statement sets the merge block's TERM_RETURN before `handle_uninstall`'s direct text emission — SSA dominance violations + spurious QZ0603 warnings. Mid-body `return`s are fine (deep elif branches, early-exit paths).

**Rule**: last statement of a body-wrap is a bare expression. If the function needs to return that value, the body-wrap's value is the return value.

Full writeup: [`feedback_body_wrap_last_stmt.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/feedback_body_wrap_last_stmt.md).

### 3.4 Cache pollution across binaries

`.quartz-cache/` populated by compiler v1 then reused by v2 produces QZ0603 + runtime `index out of bounds: index 0, size 0` on qspec/subprocess-using specs. All "pre-existing effect spec failures" flagged in earlier handoffs turned out to be cache-scope, not code-scope.

**Rule**: `rm -rf .quartz-cache` before cross-binary runs. Especially during migration, especially when running previous-golden binaries.

Full writeup: [`feedback_quartz_cache_pollution.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/feedback_quartz_cache_pollution.md).

### 3.5 `replace_all` catches helper bodies

Bulk `replace_all foo(x) → _new_foo(x)` also rewrites the effect-op call INSIDE `_new_foo`'s body-wrap, creating infinite self-recursion. Fixpoint builds clean (the recursion is dead in `@qz_main`'s immediate call graph); SIGSEGV on any subsequent compile, with no crash report.

**Rule**: after a bulk rename that touches a helper, inspect the helper's own body. If the helper's body contains a call to its old name (typical: the helper *was* the body-wrap of the old name), that call is now a self-call.

Full writeup: [`feedback_replace_all_helper_body.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/feedback_replace_all_helper_body.md).

### 3.6 Kind=3 perform unwinds outer state-machine frames

The default kind=3 dispatch (pre-4.B.8.a) longjmps to the matched handler's setjmp buf whenever the handler returns without resuming, even when the handler explicitly suspended (set `__qz_effect_park_rv` to 0 via `__qz_effect_suspend` or to a park encoding via `__qz_effect_park`). The longjmp tears down every C stack frame between the perform site and the install site, including any intermediate `$poll` state machines mid-poll. The intermediate frames' `state[0]` survives on the heap, but variables bound at the kind=3 perform site (specifically: any state set BEFORE the perform call by an enclosing `$poll`) get clobbered, and the post-perform code that interprets `__qz_effect_park_rv` never runs.

This was invisible while every yield happened in the body of the same `$poll` whose constructor installed the consumer-drive setjmp (Stream.next's pattern). It surfaced the moment a generator delegated to a `can Yield` helper: my_gen$poll → emit_pair → kind=3 perform Yield → unwind to Stream.next; my_gen$poll's frame state never advances past the helper-call statement, so the next consumer drive re-enters at the top of the body, calls emit_pair again, infinite loop.

**Fix**: 4.B.8.a (`465ab0fc`) splits the kind=3 dispatch on `(resumed, park_rv)`. `resumed=0 AND park_rv == 1` (handler aborted with no action) keeps the legacy unwind — that's the intentional with-block early-exit semantics. `resumed=0 AND park_rv != 1` (handler explicitly suspended) returns the handler's value normally and lets the perform caller's post-perform read `park_rv` and propagate POLL_SUSPENDED up through the `$poll` chain cooperatively.

**Rule**: when a kind=3 handler must propagate state across multiple frames, design it to set `park_rv` (via `__qz_effect_suspend()` or `__qz_effect_park(fd)`) rather than rely on its bare return value reaching the install site. The unwind path is reserved for "handler abort" semantics; the cooperative path is the right model for suspension.

Full writeup: [`project_piezo_phase_4_b8.md`](../../.claude/projects/-Users-mathisto-projects-quartz/memory/project_piezo_phase_4_b8.md).

---

## 4. Checklist for a new effect migration

Copy this checklist into the migration's handoff doc.

### Pass 1 — typecheck-only

- [ ] Effect declaration in `std/<effect>.qz`, with ops.
- [ ] Decide: blessed-relaxation (capability gate, user-facing) or closed-world (dogfooding only)?
- [ ] If blessed: add to `tc_is_blessed_effect` allow-list in `typecheck_expr_handlers.qz`.
- [ ] First slice (3-5 callsites) wrapped at site with the default handler.
- [ ] Last-statement rule (§3.3) satisfied at every wrap.
- [ ] `quake guard` passes.
- [ ] Cold + warm cache-enabled self-compile passes (`rm -rf .quartz-cache && quartz --no-opt ...` twice).

### Pass 2a — prelude install

- [ ] Inline-LLVM handler in `cg_emit_effect_runtime` dispatching on op name.
- [ ] Installed in `cg_emit_effect_main_prelude` alongside existing defaults.
- [ ] Gated on `uses_scheduler` / equivalent if the effect has runtime dependencies (e.g. `Async.spawn` needs `__qz_sched_init`).
- [ ] Flag-gated if the migration is speculative (`--piezo-<effect>`).
- [ ] `quake guard` passes.
- [ ] Cold + warm self-compile passes.

### Pass 2b — wrap deletion

- [ ] All wrapped callsites now have the Pass-2a default covering them.
- [ ] Decide: keep wraps (dogfooding, no customization story) or drop them (user-customizable capability).
- [ ] If dropping: identify and delete per-site. Any "snapshot globals for with-block" aliasing that the wraps forced can also be removed.
- [ ] Avoid `replace_all` on helper renames (§3.5).
- [ ] `quake guard` passes (fixpoint should stay byte-identical — wraps lower to the same IR as the prelude-dispatch path).
- [ ] Cold + warm self-compile passes.
- [ ] Smoke tests (`style_demo.qz` + `brainfuck.qz`) pass.

### Handoff

- [ ] Memory entry updated in `MEMORY.md` + the phase's `project_*.md` file.
- [ ] Handoff doc in `docs/handoff/` for next session.
- [ ] Bug memos updated with resolution status.

---

## 5. Estimation

Historical calibration for Phase 5 migrations (one quartz-day = ¼ traditional day per CLAUDE.md):

| Migration | Callsites | Sessions | Quartz-days |
|-----------|-----------|----------|-------------|
| P5.1 Diagnostics | 279 | 2 | 2 |
| P5.2 State<TcCtx> | 6 leaves + Tier 2 | 2 | 1.5 |
| P5.3 Emit | Full backbone cascade + leaves | 3 | 3 |
| P5.4 FileIo | 55 flat-op callsites | 3 (incl. stack-bug debug) | 3 |
| P5.5 Intern | 17 + 1 | 1 | 1 |
| Total | — | 11 | ~10.5 |

Rule of thumb: **1 quartz-day per 50 callsites** (mechanical) + **1–2 sessions for the first-time pattern** (install ABI, blessed-relaxation, cascade bug surface). Subsequent migrations are faster than the first.

Stack-cap or ABI bugs, if they surface, add 1–2 sessions. Budget for one; celebrate if you don't need it.

---

## 6. Measured perf impact

### 6.1 Wrap-deletion overhead (Phase 5.4.g)

Setup: self-compile of `self-hosted/quartz.qz`, `--no-opt --no-cache`, 3 runs per binary, fresh `.quartz-cache` between runs. macOS ARM64, `/usr/bin/time`.

| Binary | Wall (real) | User | Notes |
|--------|-------------|------|-------|
| `quartz-pre-p54-bulk-cleanup-golden` | 13.34 / 13.34 / 13.35 s | 13.08 s median | Body-wraps intact, prelude install (Pass 2a) active. |
| HEAD (`55cb2cc8`) | 13.34 / 13.34 / 13.34 s | 13.07 s median | Wraps deleted (Pass 2b). |

Delta: **< 0.01 s (< 0.1 %)** — below measurement floor.

**Why no delta**: with the D.4 blessed-relaxation + prelude-install pattern, both wrapped and unwrapped callsites dispatch through `__qz_effect_perform`. Deleting the wrap removes an extra install/uninstall pair but leaves the same call target at the perform site, so LLVM generates effectively the same IR.

### 6.2 Pre-Phase-5 vs post-Phase-5

Not measured in this session. The pre-5.1.2 golden does not understand the Phase 5 source tree (uses `std/intern`, effect syntax in stdlib that predate-5.1.2 binaries reject). A clean measurement would require checking out the pre-5.1.2 source, compiling it with the pre-5.1.2 binary, and comparing against a modern self-compile — a separate exercise.

Filed as Tier 4: "Phase-5 end-to-end perf audit" (§6 of ROADMAP).

### 6.3 Implication

The per-call overhead of `__qz_effect_perform` is absorbed into every Phase-5 effect op regardless of whether the callsite is wrapped. If it shows up as a hotspot in a future profile, the mitigation is **effect-op inlining at codegen** (skip perform when the op is provably bound to a known default), not body-wrap reintroduction. Filed as Tier 4.

## 7. LOC audit (Phase 5 close-out, 2026-04-25)

Measured: 20 migrated + new-infra compiler source files, comparing `7b92d918~1` (pre-Phase-5.1) to `cda7a3cc` (Phase 5.6 closeout).

| Effect | Files | Pre | Post | Δ |
|--------|-------|-----|------|---|
| 5.1 Diag (existing files) | typecheck, typecheck_helpers, typecheck_match, typecheck_concurrency, typecheck_walk, diagnostic | 11,752 | 12,340 | **+588** |
| 5.1 Diag (new bridge) | typecheck_diag.qz | 0 | 128 | +128 |
| 5.2 State (new bridge) | typecheck_ctx.qz | 0 | 83 | +83 |
| 5.3 Emit (existing files) | codegen, codegen_util, codegen_separate, codegen_intrinsics, cg_intrinsic_sb, typecheck_expr_handlers | 8,842 | 8,866 | **+24** |
| 5.3 Emit (new bridge) | codegen_ctx.qz | 0 | 90 | +90 |
| 5.4 FileIo | resolver, quartz, build_cache, dep_graph | 5,885 | 5,990 | **+105** |
| 5.5 Intern | typecheck_registry | 4,889 | 5,016 | **+127** |
| **Total** | **20 files** | **31,368** | **32,513** | **+1,145 (+3.65 %)** |

**Target was −10–15 %. Result: +3.65 %. Target NOT met.**

### What the raw LOC misses

The reduction story didn't materialize at the source-line level, but per-callsite complexity did fall:
- Threading `tc:` through every diagnostic-emitting function disappeared (5.1, 5.2).
- `out: Int` parameters dropped from 9 leaf codegen helpers (5.3.d.3, −263 caller edits across 10 files).
- `string_intern::intern_id(tc.interner, X)` → bare `intern(X)` (5.5).

Net: callsite ergonomics improved (fewer parameters, less plumbing) at the cost of installing 3 bridge files and ~1,150 lines of effect-machinery routing in the migrated source. The structural trade is **legible callsites at the cost of one-time infra**.

### Why the target was missed

1. **5.1 Diag never got Pass 2b.** ~26 surviving `with Diag { error: …, warn: … } do -> error(…) end` body-wraps in `typecheck_walk.qz` (12) and `typecheck_expr_handlers.qz` (14). Each is 5 lines for what was a 1-line `tc_error(tc, …)` call before. Wrap-deletion à la 5.4.g/5.5.c.2b would recover ~130 LOC. Filed as Tier 4: §7.1 below.
2. **3 new bridge files (+301 LOC) are permanent infra.** typecheck_ctx, typecheck_diag, codegen_ctx are not optimisable further without first-class state passing, which is a Phase 7+ concern.
3. **The 10–15 % target was probably calibrated against languages without Quartz's evidence-passing overhead.** Effect-routed Quartz code is not strictly shorter than direct calls — it trades parameter density for handler-table indirection. The win is teaching, isolation, and substitution, not byte count. Re-baseline in the next epic.

### 7.1 Tier-4 follow-up: Phase 5.1.x — Diag Pass 2b

Mechanical work, ~0.5 quartz-day:
1. Verify `Diag` is on the D.4 blessed-relaxation list (it was in 5.1's design; confirm via grep on `typecheck_expr_handlers.qz`).
2. Confirm prelude install in `cg_emit_effect_main_prelude` already covers Diag (yes, since 5.1 shipped before Pass 2 patterns existed — but the install is keyed on `uses_diag` flag, which needs MIR-side flagging if not already present).
3. Delete the 26 body-wraps in `typecheck_walk.qz` + `typecheck_expr_handlers.qz`. Bare `error(...)` / `warn(...)` calls dispatch through the prelude install.
4. `quake guard` fixpoint byte-identical, smoke green, sweep diag-related QSpecs.

Estimated savings: ~130 LOC. Not 10–15 %, but the right thing to do anyway.
