# P3.C — NODE_AWAIT → perform(Async, await, handle) migration

> **Epic**: Operation Piezoelectric Effects · `[piezo]`
> **Phase**: 3 · Milestone P3.C (first migration cutover)
> **Status**: Design closed. P3.C.0 scaffold landed. P3.C.1–.4 pending impl.
> **Depends on**: P3.0 (kind=3 CPS runtime), P3.A (Async classifier → kind=3), P3.B (default Async handler installed).
> **Unblocks**: P3.D (NODE_GO → Async.spawn), P3.E (io_suspend/yield → Async ops), P3.G (delete NODE_AWAIT special case).

## Goal

Replace the dedicated MIR_AWAIT opcode + `mir_emit_completion_await` pipe-block pattern with `perform(Async, await, future_handle)`. The scheduler-as-handler (installed by P3.B) takes over dispatch. Result: `await` stops being a keyword-privileged AST node and becomes effect-system syntax sugar for a kind=3 `perform`.

Per the compilation memo §6.5: *"Codegen changes are minimal — existing $poll machinery IS the operation-kind lowering. We reframe rather than rewrite."* P3.0c-perform shipped `mir_emit_kind3_perform_suspend` at `mir_lower_gen.qz:299-349`. That function already spills locals, stashes cont_frame in TLS, emits `perform`, returns `POLL_READY`, and creates the resume block. NODE_AWAIT just needs to call it.

## Pipeline today (survey snapshot, 2026-04-21)

Each row is a Piezo-relevant touch point. File paths rooted at repo top.

| Phase | Location | Behavior |
|---|---|---|
| Parser | `frontend/parser.qz:1249` | `await expr` → `NODE_AWAIT(left=handle)`. |
| Typecheck | `middle/typecheck_concurrency.qz:87` (`tc_check_await`) | Unwraps `Task<T>`/`Future<T>` → `T`. No effect-row impact today. |
| MIR lower | `backend/mir_lower.qz:1097-1195` | Branches: lazy-Future compile-time path vs. runtime `mir_emit_completion_await`. |
| Lazy path | `mir_lower.qz:1125-1183` | $poll re-entry using `frame[2]` as poll fn; suspend/resume state labels. |
| Runtime path | `mir_lower_gen.qz:426-474` (`mir_emit_completion_await`) | `completion_watch` → `completion_block(fd)` → `completion_unwatch` → `fd_close`. Sets `uses_scheduler`. |
| Codegen (MIR_AWAIT) | `backend/codegen_instr.qz:2635-2676` | Direct `pthread_join(tid)` + load-result-at-offset-8 for runtime handles. |
| Suspendable | `backend/mir_lower_async_registry.qz:165` | `mir_is_lazy_async_var(name)` classifies handle origin. |

## Target shape

Single routing decision at MIR lower time:

```
NODE_AWAIT(handle)
  if feature_flags::piezo_async_await_enabled()
    mir_emit_kind3_perform_suspend(ctx, "await", "Async", [handle_val])
  else
    existing dispatch (lazy vs. completion-await)
  end
```

The kind=3 perform site already:
- Spills live locals into the $poll frame.
- Writes caller's frame pointer into TLS `@__qz_effect_current_cont_frame`.
- Emits `call @__qz_effect_perform(ptr %eff, ptr %op, i64 %argc, ptr %argv, i64 3, i64 %cont_frame)`.
- Returns `POLL_READY` so the $poll returns to its caller (scheduler).
- Creates a resume block where locals are reloaded and subsequent stmts lower.

The scheduler-as-Async-handler then runs the `await` op body. That body is the only piece that needs new logic (see §Default Async.await handler below).

## Decomposition

### P3.C.0 — scaffold (SHIPPED, `25978823`)

- New `shared/feature_flags.qz` module (getter/setter pair).
- `--piezo-async-await` CLI flag registered in `quartz.qz`.
- Flag dormant: plumbed end-to-end but no reader yet.
- Fixpoint 2233 → 2235 fns (+2: setter + getter).
- Rationale: land the plumbing on its own so P3.C.1 is a pure behavior-change diff, not "new flag + new semantics bundled." Also: `feature_flags.qz` becomes the home for future Phase 3/4 bisection switches (P3.D/E/F will want the same pattern).

### P3.C.1 — typecheck row propagation (SHIPPED, `d3b090d8`)

- `typecheck_walk.qz` NODE_AWAIT case gained a flag-guarded block that calls `tc_row_subsume(caller_row, {Async})` after `tc_check_await`.
- Widens open-tailed rows; idempotent on rows already containing Async; tolerates closed non-Async rows (same relaxation as blessed effects Throws/Log).
- Observable today: zero. `tc_dump_effect_rows` reads stored-row labels (not walked) so tail-var widenings don't surface. Becomes observable at P3.C.2 when MIR lowering routes through perform.
- No new functions; 2235 fns unchanged.

### P3.C.1 — typecheck propagation

When flag on, `tc_check_await` records `Async` into the containing function's effect row.

Work:
- Extend `tc_check_await(tc, task_type, line, col)` signature (or supplement with `tc_check_await_ctx(tc, task_type, func_node, line, col)` if we need the function node to write onto).
- Add `Async` to the caller's `can` labels via existing `tc_row_extend` / equivalent.
- Stamp `can Async` if the user's annotation didn't already include it (error path: if user wrote `can` without `Async` AND awaits anyway, emit a new QZ code).

Guard: `if feature_flags::piezo_async_await_enabled() == 0 return` preserves today's no-row-impact behavior when flag off.

### P3.C.2 — MIR lower routing (pending; LAND WITH P3.C.3)

When flag on AND inside a $poll-lowered function (`mir_gen_is_active() >= 2`), `mir_lower.qz:1097-1195`'s NODE_AWAIT case delegates to `mir_emit_kind3_perform_suspend` instead of the existing lazy/completion branches.

**Critical constraint**: `mir_emit_kind3_perform_suspend` (defined at `mir_lower_gen.qz:299-349`) requires the caller to be inside a $poll state machine. It reads `_gen_async_func_name`, `_gen_frame_var`, `_gen_local_names`, `_gen_local_offsets`. Outside $poll these are empty/invalid. So the routing must check `mir_gen_is_active() >= 2` and fall back to the existing path when false.

Work:
- `import feature_flags` in `mir_lower.qz`.
- Early in the NODE_AWAIT case (after `handle_val = ctx.mir_lower_expr(handle)`), if flag on AND `mir_gen_is_active() >= 2`:
  - `var args = vec_new(); args.push(handle_val);`
  - `return mir_lower_gen::mir_emit_kind3_perform_suspend(ctx, "await", "Async", args)`.
- Else: existing dispatch unchanged.

Gotcha 1: the existing `is_known_lazy` path's direct-poll optimisation (`frame[2]` call instead of runtime `perform`) is discarded for flag-on $poll paths. Perf cost: one extra indirect call per await (the runtime `__qz_effect_perform` dispatch). G-extended fast path does NOT fire for kind=3 — static resolution of kind=3 handlers is explicitly out of scope per P3.0c-perform handoff. Accept the perf hit; measure at P3.H.

Gotcha 2: `suspendable-leaf` registration that today fires from `mir_emit_completion_await` needs to still fire. `mir_emit_kind3_perform_suspend` line 302 covers this.

Gotcha 3: outside-$poll awaits (current `mir_emit_completion_await` path) — LEAVE AS-IS for P3.C.2. Migrating those requires a different model (no caller $poll to reuse for kind=3); defer to post-P3.C (maybe never, if P3.G decides the outside-$poll path always gets wrapped in one).

**P3.C.2 alone is NOT shippable independent of P3.C.3** — the default `await` handler is a stub returning 0. Flag-on programs would compile and run but produce wrong results. Bundle P3.C.2+P3.C.3 into a single commit.

### P3.C.3 — default Async.await handler body

`__qz_default_async_handler` currently has `await/spawn/suspend` as stub `return 0`. P3.C.3 replaces the `await` branch with the real poll+wake logic.

Design sketch (pseudo-LLVM):
```llvm
do_await:
  ; argv[0] = handle (i64-encoded ptr to Task/Future frame)
  %h0_ptr = getelementptr inbounds i64, ptr %argv, i64 0
  %h  = load i64, ptr %h0_ptr
  ; Poll the future: call frame[2] (poll fn)
  %res = call i64 @__qz_async_poll_handle(i64 %h)
  %done = icmp eq i64 %res, POLL_READY
  br i1 %done, label %await_ready, label %await_park
await_ready:
  %rv = call i64 @__qz_async_load_result(i64 %h)
  ; kind=3: call resume(rv) to deliver back into caller's $poll
  %_  = call i64 @__qz_effect_resume_cont(i64 %rv)
  ret i64 %rv
await_park:
  ; handle not ready. The kind=3 semantics: if we return without resume,
  ; resumed[i] stays 0 and the with-block sees handler's return as the
  ; result — which is wrong for async (we want the caller parked, not
  ; aborted).
  ; Option A: call into scheduler to register (handle -> cont_frame) wake.
  ; When future fires, scheduler calls resume_cont(result_val).
  ; Handler returns "suspended" sentinel; $poll epilogue treats it
  ; differently from "aborted". Needs a new resumed-state tri-value:
  ;   0 = aborted (handler return wins)
  ;   1 = resumed (body return wins)
  ;   2 = parked-for-wake (no with-block value yet; $poll return is
  ;       POLL_READY so scheduler re-enqueues us on wake)
  ; See memo §3.2 and P3.0 §Q6 — this extension needs a memo update.
  ; For P3.C.3 we prototype this; may reveal a cleaner model.
  ...
```

**Open design question for P3.C.3**: the "park-for-wake" semantics don't exist in today's kind=3 model. Either:

- **(a) Extend kind=3** with a third resumed-state value (parked). Minor runtime change.
- **(b) Inside the await handler, call `resume_cont` with a sentinel and have the caller's $poll re-enter into a re-poll loop**. Cleanest but requires the handler to know the sentinel protocol.
- **(c) Wrap today's `mir_emit_completion_await` pipe-block inside the handler body**. The handler blocks the worker thread (already the case for today's non-lazy path). Simplest migration, worst perf; matches existing behavior bit-for-bit. Recommended first cut.

Option (c) is the **safe P3.C.3 baseline** — it swaps the codegen path without changing semantics. Perf optimization (a or b) becomes a post-migration follow-up.

### P3.C.4 — end-to-end spec

New `spec/qspec/async_await_migration_p3c_spec.qz`:
- Test 1: `--piezo-async-await` flag off → existing behavior (regression guard).
- Test 2: flag on + simple `go f(); await h` → result returned correctly.
- Test 3: flag on + chained awaits → still correct.
- Test 4: flag on + user-override handler `with Async { await: my_await } do ... end` → override fires.
- Test 5: flag on + explicit `can Async` annotation required if caller has any `can` clause.

All tests must continue to pass with flag OFF (existing specs) and flag ON. P3.G later deletes the branch and the flag.

## Kill criteria

Trip any → halt + redesign memo:

- **Perf regression > 10%** on scheduler benches (1M-spawn, HTTP throughput). Per Phase 3 kill criteria.
- **Correctness regression** in async_io_spec, go_lambda_spec, future_spec, task_spec with flag ON → option (c) has a bug; investigate before proceeding.
- **Fixpoint cascade** > 1 session → halt.
- **The park-for-wake model doesn't cleanly fit kind=3** → redesign before going further. This is the most likely trip wire.

## Rollback plan

Each P3.C.N commit is flag-gated; defaults OFF. Reverting is "remove the new else branch and delete the flag reader" plus removing the CLI flag registration — no compat shim, no user-visible change. If the whole migration gets scrapped, P3.C.0's `feature_flags.qz` stays (it's a neutral infrastructure piece).

## Post-P3.C

P3.D mirrors this shape for NODE_GO → `perform(Async, spawn, closure_handle)`. P3.E does the same for `io_suspend` and `sched_yield`. P3.G deletes NODE_AWAIT/NODE_GO from the dedicated paths + drops `MIR_AWAIT`/`MIR_SPAWN` opcodes once all three have moved.

## References

- `docs/research/EFFECTS_LLVM_COMPILATION_MEMO.md` §§2.4, 3, 6.5
- `docs/design/P3_0_KIND3_CPS.md`
- `docs/handoff/piezo-phase-3-kickoff.md`
- `docs/handoff/done/piezo-milestone-d-handoff.md`
