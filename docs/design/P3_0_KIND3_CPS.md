# P3.0 — Continuation-Preserving Resume (kind=3) Design Memo

> **Epic**: Operation Piezoelectric Effects · `[piezo]`
> **Milestone**: P3.0 (foundation for Phase 3 async-as-effect migration). Originally named F.3c-real; renamed P3.0 in the Phase 3 kickoff (2026-04-20).
> **Status**: Design closed. Implementation pending across 2-3 sessions.
> **Depends on**: B (rows), C (MIR narrow), D (runtime), E(post) (argc/argv), F.3b (kind=2 setjmp/longjmp), G-extended (static fast path for kind=2). All shipped.
> **Unblocks**: P3.C, P3.D, P3.E, P3.G, P3.H.
> **Related reading**: [`docs/research/EFFECTS_LLVM_COMPILATION_MEMO.md`](../research/EFFECTS_LLVM_COMPILATION_MEMO.md) §2.4, §3, §4.3, §6.5 · [`docs/handoff/piezo-phase-3-kickoff.md`](../handoff/piezo-phase-3-kickoff.md)

---

## Why kind=3 exists

Current kind=2 (shipped in F.3b) gives us **exception-style effect ops**:
`resume(v)` in the handler body is early-return; after the handler returns, the runtime `longjmp`s back to the installing `with`-block, and the with-block evaluates to the handler's final return. The call site's code after `perform(...)` never runs. Good for `Throws`, `Panic`, `ParseError`.

**Kind=3 is continuation-preserving**: `resume(v)` does not return from the handler — it runs the caller's continuation (body of the perform-enclosing function, starting at the instruction after the perform) with `v` as the op's result. The caller's continuation eventually returns back to the handler, which may do cleanup and then return its own final value. That final value is the `with`-block's value.

Operationally: the `with`-block value is **the handler's return**, not the body's return. The body's return value is consumed by the handler (as `resume`'s implicit continuation-return).

This is the semantics `await`, `spawn`, `suspend`, `yield` need for Phase 3. The scheduler-as-handler for Async wants to call `resume(value)` on task completion, and the caller has to pick up at the await site with that value in hand.

## The five open questions (now closed)

### Q1 — Install ABI: share slots with kind=2 or add a new array?

**Closed: share.** Repurpose the existing `@__qz_effect_stack_bufs` slot as an "opaque per-entry state pointer." kind=2 uses it as `jmp_buf*`. kind=3 uses it as a **continuation frame pointer**. kind=0/1 leave it `0`.

Rationale: zero-width runtime change; the stack already has 5 parallel arrays and adding a 6th hurts cache locality more than it helps clarity. The `bufs` slot's name stays; its doc becomes "opaque per-entry state pointer, shape determined by kind."

Install-time ABI does not change. `__qz_effect_handle_install(eff_name, handler_ptr, buf_or_cont_ptr, op_filter)` already takes `buf_or_cont_ptr` as `i64`; callers are MIR_HANDLE_INSTALL sites that already thread this.

### Q2 — Continuation handle layout

**Closed: bare frame pointer.** The existing async frame (see `mir_lower_gen.qz:976`) already lays out:

```
frame[0] = resume state (discriminant: 0=initial, 1=ready, 2=label1, 3=label2, ...)
frame[1] = result slot (the value the caller sees when it completes)
frame[2] = poll_fn pointer (the mangled `<fn_name>$poll`)
frame[3..] = cancel/task_id/park_state/params/locals
```

`resume(v)` in a kind=3 handler compiles to:

```llvm
%poll = load ptr, ptr %cont_frame, i64 2     ; read poll_fn from frame[2]
%rv = call i64 %poll(ptr %cont_frame, i64 %v)   ; run the continuation with v
```

No vtable, no marker field (scoped-resumption guard deferred — see Q5). The frame is self-describing.

For kind=3 perform sites in a caller function, the caller IS that function's $poll frame. We push `%caller_frame` into the install's `bufs` slot at install time, and the handler reads it there.

### Q3 — Who allocates the continuation frame

**Closed: caller's $poll transform allocates at function entry.** Matches existing async semantics. A function that performs ANY kind=3 op (transitively, via effect-row analysis) gets the same $poll state-machine treatment as today's `async def`. Its frame is allocated on entry (heap, matches async today), the poll_fn is materialized, and perform sites become suspension points.

The transform trigger changes from "function has `async def`" to "function's effect row contains any label whose ops include a kind=3 op." This is the classifier's output feeding the $poll transform. The `_suspendable_funcs` fixed-point registry (`mir_lower_async_registry.qz`) generalizes: any kind=3 perform marks the caller suspendable; propagate transitively.

### Q4 — Resume with void return

**Closed: `resume()` is sugar for `resume(0)`.** Op's declared return type is always `Int` at runtime (everything's i64). When an op returns void conceptually (`yield(): Int` returns the discarded 0; `suspend(fd): Int` returns 0 on wake), `resume()` without an argument passes 0 to the continuation.

Parser sugar: `TOK_RESUME` with no `TOK_LPAREN` following emits the 0-arg form; current parser's `resume(v)` already works. No surface-syntax change.

### Q5 — Scoped-resumption guard

**Closed: deferred, filed as P3 followup.** Rationale: each continuation captures no marker today; detecting `resume` invoked outside its installing scope requires a marker field in each stack entry (new `@__qz_effect_stack_markers` array) plus compare-on-resume. This is pure defense-in-depth against a hazard (Peter Landin's "enter once, leave twice") that user code has to work hard to trigger. Phase 3 ships without it; the memo §4.4 scoped guard lands as a post-P3 cleanup.

Followup filing (ROADMAP / memory): `P3.G-followup-marker-guard` — runtime marker array + perform-site allocation + resume-site check. ~0.5 quartz-day, zero-observable-behavior change for correct programs.

## Data flow

```
caller: def my_op_call(x: Int): Int can Async
  var a = await(fut)    ← kind=3 perform, suspension point
  return a + x
end

install: with Async { await: sched_await } do ->
  my_op_call(7)
end do ->

handler: def sched_await(op: Int, argc: Int, argv: Int): Int
  var fut = argv[0]
  if fut.is_ready
    resume(fut.value)    ← delivers result back into my_op_call's $poll
  else
    register_io(fut.fd, @__qz_resume_from_poller)   ← defers resume
  end
  return 0               ← handler final (with-block value)
end
```

Runtime trace:

1. `my_op_call(7)` enters. Caller is a $poll-ified function (classifier said so). Its frame is allocated; frame[5] stores `x = 7`; resume state = 0 (initial).
2. $poll runs `my_op_call$poll(frame, 0)`. Executes until the `await` at state 0. Saves state → 2 (post-await label). Returns its own frame pointer as the continuation handle to the perform site.
3. Perform site: looks up installed handler for `(Async, await)`. Finds sched_await. Pushes caller's frame into the stack entry's `bufs` slot.  Calls `sched_await(op="await", argc=1, argv=[fut])` (E(post) ABI).
4. sched_await inspects fut. Suppose ready. Calls `resume(fut.value)` — which compiles to `load poll_fn from frame[2]; call poll_fn(frame, fut.value)`.
5. poll_fn re-entry: state=2, arg=fut.value. Executes `a = fut.value; return a + x` — which means writing the return value to frame[1] and the resume state to 1 (ready). Returns to caller of poll (sched_await).
6. Back in sched_await after resume: does cleanup (none here), returns 0.
7. The with-block evaluates to 0 (handler's final return). My_op_call returns to its caller the value stored in frame[1]? Or does the handler's return override it?

**Critical decision at step 7**: per memo §6.5, with-block evaluates to handler's final return. That's `0` here. But `my_op_call` is called outside the with-block (it's the BODY of the with-block). So `my_op_call(7)` returns `a + x = fut.value + 7` — that's what the with-block receives as "body result". Then the handler's return overrides the with-block value.

Wait, that's Koka's semantics: handler's return value replaces the body's return value. Useful for error-as-data ("handler reformats the body's result") and less obvious for async await.

For await: we want `await(fut)` to yield `fut.value` **to the caller**, and the with-block's value = whatever the body produces. So:

- Body: `my_op_call(7)` returns `fut.value + 7 = N`.
- With-block value: `N` (body's return), NOT handler's `0`.

That's kind=1 semantics (function-kind): handler runs, handler's return is the op's result; when body completes, its return becomes the with-block's value. Caller continues between the perform and the body-end as normal LLVM control flow.

So… do we actually need kind=3 for await? Can kind=1 (function-kind, tail-resumptive direct call) work?

**It can — IF the handler can suspend the caller from within its body** without the caller's frame being lost. Kind=1 today does synchronous direct call: `%rv = call i64 %handler(op, argc, argv); return %rv` to the perform site. That works for `Log::emit` (handler writes stderr and returns). It does NOT work for `Async::await` where the handler wants the caller to park until I/O fires.

Resolution: **kind=3 is not about the with-block's final value overriding the body's return.** Kind=3 is about *the handler being able to invoke the continuation zero, one, or many times, at non-tail-call positions.* Specifically:

- **Zero resumes** (abort): same as kind=2 unwind behavior. Handler's return becomes the with-block value; the caller's suspension state is dropped.
- **One resume** (single-shot, the async case): handler calls `resume(v)`; caller runs to completion (or next kind=3 perform); when caller returns, its return value is stashed and control returns to the handler at the point after `resume(...)`. Handler continues, eventually returns. With-block value = body's return (the last stashed value), not handler's. (This diverges from Koka — our semantic choice for Phase 3.)
- **Multi-shot** (deferred): handler calls resume multiple times; out of scope for Phase 3, kill-criterion filed.

The "handler's return becomes with-block value" only applies when handler never resumes (the abort path — equivalent to kind=2). When handler does resume, body's final value wins.

Concrete compiled flow for the resume case:

1-4. Same as above.
5. poll_fn re-entry resumes my_op_call. my_op_call completes. Its frame[1] holds `fut.value + 7`; frame[0] state = 1 (ready). poll_fn returns 1 (ready discriminant).
6. Back in sched_await: after the `resume(fut.value)` call, the next line runs (`return 0`). sched_await returns 0.
7. The runtime checks: did the handler invoke resume during its body? If yes, **with-block value = what the body stored in caller's-frame-at-the-time-of-the-with-block** (for async, the task's result; for the parsed example, `fut.value + 7`). If no, **with-block value = handler's return**.

This needs a "did handler resume?" flag — I'll track it per perform site in the install's frame.

The cleanest tracking: the install's result slot (`@__qz_effect_stack_results[entry]`) is initialized to `0` and written by resume when it runs. Reading it at with-block teardown tells us "did resume happen? what did the body return?"

Actually simpler: resume writes body's return to the result slot. If resume never ran, the result slot stays whatever (initialized to zero). The with-block then picks max(result slot, handler return) by kind — kind=3 uses result slot if resume ran, else handler return.

I'll formalize this with a "resumed" flag:

Add `@__qz_effect_stack_resumed` (new array, or repurpose since kind=2 doesn't need it). Default 0; `resume(v)` sets it to 1 **and stores v into the result slot**. With-block teardown:
- If resumed == 1: with-block value = result slot (= body's final return, stored by the body's poll completion path).
- If resumed == 0: with-block value = handler's return.

Body storing its final return into the result slot: when the continuation-frame's poll_fn completes, it writes `result = frame[1]` AND sets `resumed = 1` AND stores `frame[1]` into the install's `@__qz_effect_stack_results[entry]`. 

Actually the cleanest is: the resume call itself writes the result slot at invocation time (with `v`), and the POLL COMPLETION writes over it with the body's final return. resume happens first (handler calls it); body runs; body completes and writes the result slot with its final value. Then handler continues, returns; with-block sees the result slot.

This is getting complex. Let me simplify:

**Simpler model**: at `resume(v)`:
1. Caller's poll_fn is invoked with v. poll_fn runs the continuation.
2. Poll_fn's return value IS the body's final result (the resume-to-completion value).
3. Write that value to the install's result slot.
4. Set resumed=1.
5. Return from resume(v) call to the handler.

Handler continues. Handler returns its own value.

With-block teardown:
- resumed == 0: handler never called resume → with-block value = handler's return.
- resumed == 1: → with-block value = result slot (body's final result via poll_fn).

Implementation: `resume(v)` is compiled to:
```llvm
; Compute continuation frame + poll_fn
%cont = ... load from nearest-enclosing install's bufs slot ...
%poll = load ptr, ptr %cont, i64 2
%body_rv = call i64 %poll(ptr %cont, i64 %v)
; Store into install's result slot
store i64 %body_rv, ptr %install_result_slot
; Mark resumed
store i64 1, ptr %install_resumed_slot
; Return to handler (the call continues)
```

The "nearest-enclosing install" is the innermost kind=3 install on the effect stack. Could be tracked via the same TOP-1 read we use for perform's match loop, or via a handler-scoped parameter.

Actually — the handler is passed `op, argc, argv`. To identify WHICH install invoked it (so resume knows where to write), we need either:
(a) A per-handler hidden parameter that carries the install-entry index.
(b) Scan the effect stack at resume-site to find the install whose handler == current PC... no, that's fragile.

Option (a): extend handler ABI to `(op, argc, argv, install_idx)`. Clean semantically but forces migration of every user handler across ~30 effect specs.

Option (b): **thread-local `@__qz_effect_current_install_idx`**. Runtime `__qz_effect_perform` stores `%iprev` into TLS before calling the handler; `resume(v)` reads TLS to find its install entry. No handler-ABI change, no spec migration.

**Closed: option (b) — TLS.** Matches existing TLS patterns in the codebase (`@__qz_current_frame`, `@__qz_io_pending_*`, `@__qz_sched_park_pending` — all thread-local per-worker scheduler state). Zero handler-ABI change; existing `(op, argc, argv)` specs stay green.

TLS store/load shape:

```llvm
; In __qz_effect_perform's `hit:` block, immediately before the handler call:
store i64 %iprev, ptr @__qz_effect_current_install_idx, align 8
%rv = call i64 %h_ptr(ptr %op, i64 %argc, ptr %argv)
; ... existing kind-dispatch logic follows unchanged

; In MIR_RESUME codegen (P3.0c):
%idx = load i64, ptr @__qz_effect_current_install_idx, align 8
%cont_slot = getelementptr inbounds [32 x i64], ptr @__qz_effect_stack_bufs, i64 0, i64 %idx
%cont_i64 = load i64, ptr %cont_slot, align 8
%cont = inttoptr i64 %cont_i64 to ptr
%poll = load ptr, ptr %cont, i64 2
%rv = call i64 %poll(ptr %cont, i64 %v)
```

Handler invoking another handler (nested perform) is a non-goal in Phase 3, so a single TLS slot is sufficient. If nested handler dispatch ever becomes a requirement, we save/restore the TLS around each perform call. File that under post-P3 enhancements if it comes up.

Static fast paths (G-MVP, G-extended) already dispatch only kind<2 and kind=2-unwind — neither can call `resume`. No TLS store needed at those sites. When a future optimization pass adds a static fast path for kind=3, it'll need to emit the TLS store at the static site.

## Closed summary

| Q | Answer |
|---|---|
| Q1 install ABI | Repurpose `bufs` slot as opaque per-kind state pointer. No new array. |
| Q2 continuation layout | Bare frame ptr; `poll_fn` at `frame[2]`; `resume(v)` = `frame[2](frame, v)`. |
| Q3 frame allocation | Caller's $poll transform allocates at function entry. Transform trigger = classifier "any kind=3 op in transitive row". Generalizes `_suspendable_funcs` registry. |
| Q4 void resume | `resume()` == `resume(0)`. No syntax change. |
| Q5 scoped guard | Deferred. Post-P3 followup; ~0.5 quartz-day. |
| Q6 (new) resume semantics | resumed flag per install. With-block = body's return if resumed, handler's return if not. |
| Q7 (new) handler ABI | No ABI change. Use TLS `@__qz_effect_current_install_idx` instead; runtime stores `%iprev` there before the handler call, `resume(v)` reads it. Zero spec migration. |

## Implementation phasing

P3.0 lands across three sessions:

### P3.0a — Runtime TLS slot + `resumed` flag array (~0.25 session)

Scope collapsed once TLS replaced ABI widening:

- Declare `@__qz_effect_current_install_idx = thread_local global i64 -1, align 8`.
- Add `@__qz_effect_stack_resumed` parallel i64-×-32 array (all zero at init).
- In `__qz_effect_perform`'s `hit:` block: emit `store i64 %iprev, ptr @__qz_effect_current_install_idx` immediately before the `%rv = call i64 %h_ptr(...)` line.
- Reset `@__qz_effect_stack_resumed[%iprev]` to 0 before the handler is called, so a stale "resumed" flag from a previous perform at this slot doesn't leak across invocations.
- (No handler ABI changes, no spec migration.)
- Verify: full effect-spec regression green. Fixpoint holds.

Deliverables: ~50 LOC codegen_runtime.qz change; zero specs migrated.

### P3.0b — Classifier tag + $poll trigger generalization (~0.5-1 session)

- Add kind=3 to the classifier's output. When? Options:
  - (a) Classifier sees `= resume(...)` body + a user declaration hint like `= operation(args -> ...)` vs `= resume(args)` → hard to disambiguate.
  - (b) Effect ops declared with `operation` keyword in body: `def await(h: Int): Int = operation resume(...)`. Parser extension.
  - (c) Auto-detect: if op body has `resume(v)` that isn't in tail position, kind=3; else kind=2. (Relies on syntactic analysis — memo §2.4 detection.)
- Commit to (c) — matches memo §2.4 automation; user writes the body naturally.
- Update `tc_body_has_resume_call` to also detect "is the resume at tail position?" If yes, kind=2; if no, kind=3.
- Generalize `_suspendable_funcs`: any function calling a kind=3 op becomes suspendable. Today's async marker (`uses_scheduler`) stays orthogonal.
- Verify: old specs (Throws, ParseError) still classify as kind=2. No false upgrades.

### P3.0c — MIR perform → kind=3 state-machine suspension + codegen + resume intrinsic (~1 session)

- MIR_PERFORM_OP for a kind=3 op in a suspendable function lowers to:
  1. Store current frame state → frame[0] = post-perform label index.
  2. Write arg to install's op args staging.
  3. Call `__qz_effect_perform(eff, op, argc, argv, kind=3, cont_frame=<caller_frame>)` — note: also pass cont_frame as 6th arg or stash at install time.
  4. On return (handler finished without resume): unwind; with-block teardown picks handler's return.
  5. If resume was invoked: poll_fn re-entered at the post-perform label; state machine continues.
- Add `resume(v)` Quartz-level: expands to MIR primitive `MIR_RESUME(cont_frame, v)`. The handler body's MIR carries the install_idx (passed as hidden param); `MIR_RESUME` loads `bufs[install_idx]` for the frame, loads `frame[2]` for poll_fn, calls `poll_fn(frame, v)`, stores result to `results[install_idx]`, stores 1 to `resumed[install_idx]`.
- Write full P3.0 acceptance spec: at minimum one test per transition (no-resume = unwind-like; single-resume with body return; nested kind=3 perform inside body).
- Fixpoint + full effect-spec regression.

## Scope estimate

- P3.0a: 200-400 LOC change (ABI widening + 4-slot array + existing-handler migration). ~0.5-1 session.
- P3.0b: 100-200 LOC change (classifier extension + _suspendable generalization). ~0.5-1 session.
- P3.0c: 400-800 LOC change (MIR lowering + codegen intrinsics + spec). ~1 session.

**Total**: ~700-1400 LOC, 2-3 sessions. Within Phase 3's 4000 LOC kill ceiling.

## Kill criteria (P3.0-specific)

- **Classifier mis-classifies existing ops** (kind=2 → kind=3 upgrade on a body that used to abort). → Halt, review classifier heuristic; worst case revert to explicit `= operation(...)` keyword per memo §3.2.
- **ABI widening breaks fixpoint** for a body-only reason (no real semantic change but bytes differ across self-compile iterations). → Standard fixpoint debug; probably a codegen cache artifact.
- **`resume(v)` in handler can't find the continuation frame** (install_idx propagation broken). → Verify handler ABI is actually widened; check cg_emit_perform is passing the right value.
- **Body of kind=3 perform re-runs from the top on resume** (state save/restore bug). → $poll frame discriminant isn't being updated correctly. Standard async-dev debug.

## What's NOT in P3.0

- Multi-shot resume (Ndet). Still deferred; kill-criterion.
- Scoped-resumption marker guard (Q5). Followup.
- Migration of NODE_AWAIT / NODE_GO to use kind=3 — that's P3.C / P3.D, not this.

## Handoff

Next session re-enters at P3.0a: start by widening the handler ABI in codegen_runtime.qz. Existing specs will regress until handlers are migrated — standard "ABI widening + migrate all callers" drill that E(post) did for the D.5b → E ABI.

The closed design in this memo is the contract: if implementation needs to diverge (e.g., "actually the install_idx pass-through is easier as a TLS slot"), update this memo in-place before cutting code.

---

**Memo closes at 2026-04-20 (Phase 3 opening session, post-P3.B).** Design only — no impl in this commit. Next session starts P3.0a with ABI widening.
