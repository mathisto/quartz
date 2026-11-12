# B.9 Phase 3 Blocker — task brief mischaracterizes the actual scope

**Date:** 2026-05-07
**Filer:** Claude (autonomous session)
**Status:** STOPPED — work not started, no source touched, no binary backup taken
**Scope reassessment needed:** Yes, before next attempt

## TL;DR

The session brief said:

> "migrate the 9 `panic_caught(...)` call sites in compiler+stdlib to
> `with Throws { throw: panic_recover_handler } do -> fn() end`, then
> delete `panic_caught` from stdlib + remove `@__qz_panic_jmpbuf_get` /
> `@__qz_panic_jmpbuf_set` from `self-hosted/backend/codegen_runtime.qz`
> in the same commit."

**Two of the three premises are factually wrong:**

1. **There is no `panic_caught(...)` function in the stdlib.** No call sites exist. `grep -rn 'panic_caught' self-hosted/ std/` returns 11 hits — all are comments, doc-comments, or one IR basic-block label (`panic_caught:` emitted by `codegen_runtime.qz:4729`). There is nothing to "migrate" in the mechanical sense the brief implies.
2. **The `@__qz_panic_jmpbuf_get` / `@__qz_panic_jmpbuf_set` removal directly contradicts the design memo.** Per `docs/design/ERROR_HANDLING_UNIFICATION.md` §"What B.9 explicitly does NOT do" (lines 230-237), `bounds_panic` / `overflow_panic` / `map_key_panic` (the compiler-emitted noreturn helpers called at every array index, arithmetic op, missing map lookup) **stay as direct abort/longjmp paths** and explicitly do NOT migrate to Throws. These three helpers depend on `__qz_panic_jmpbuf_get`+`longjmp` (codegen_runtime.qz:1711, 1742, 1773, 1803) to escape from a panicking goroutine into the worker loop's jmpbuf. Removing the jmpbuf machinery breaks them.

The actual Phase 3 work — migrating the **scheduler's per-task panic capture** (the IR at `codegen_runtime.qz:4444-4796`, not a stdlib function) to `with Throws` — is a meaningful piece of work, but it's not what the brief described, and it is **not compatible with deleting the jmpbuf machinery in the same commit** because the bounds/overflow/map_key helpers still need it.

## Evidence

### 1. No `panic_caught` function exists

```
$ grep -rn "def panic_caught\|priv panic_caught\|fn panic_caught" /path/to/quartz/
(no results)

$ grep -rn "panic_caught" /path/to/quartz/ 2>/dev/null \
  | grep -v 'docs/\|backups\|\.bak\|done/\|\.fixpoint'
spec/qspec/panic_as_throws_spec.qz:10:##      the legacy abort path (preserves panic_caught/jmpbuf compatibility).
spec/qspec/alloc_e4b_panic_path_arena_cleanup_spec.qz:16:## `panic_caught` used pre-fix — so `await fut` semantics are unchanged
std/concurrency.qz:127:## `panic_caught` already uses for goroutines whose body panics
self-hosted/backend/cg_intrinsic_system.qz:365:    # `panic_caught` per-thread jmpbuf compatibility — the scheduler's
self-hosted/backend/codegen_runtime.qz:3371:  # Called from task_done and panic_caught under the scheduler mutex (already held).
self-hosted/backend/codegen_runtime.qz:3430:  # Called from task_done and panic_caught when a task completes.
self-hosted/backend/codegen_runtime.qz:4450:  codegen_util::cg_emit_line(out, "  br i1 %panicked, label %panic_caught, label %do_poll")
self-hosted/backend/codegen_runtime.qz:4729:  codegen_util::cg_emit_line(out, "panic_caught:")
self-hosted/backend/mir_lower.qz:1416:##      `-1` panic sentinel that `panic_caught` already uses pre-fix.
self-hosted/backend/mir_lower.qz:1513:  # Return -1 (panic sentinel) — matches `panic_caught`'s pre-fix
self-hosted/backend/mir_lower.qz:5764:  # The worker loop's panic_caught handler checks this to restart actors on panic
```

Every one of these is either:
- A comment explaining the **historical concept**
- A doc-comment cross-referencing the mechanism
- An IR basic-block label name (`panic_caught:`) emitted into the worker loop's IR

There are zero `panic_caught(<args>)` call sites. There is no stdlib function named `panic_caught`. The phrase "9 sites" in the brief appears to be apocryphal; the design memo §"Phase 3" itself only names **one concrete site** (`std/concurrency.qz:102` — and even that line number is now stale; the relevant file no longer matches).

### 2. The jmpbuf is structurally entangled with helpers Phase 3 must NOT touch

Per `docs/design/ERROR_HANDLING_UNIFICATION.md:230-237`:

> **It does not change bounds_panic / overflow_panic / map_key_panic.**
> These compiler-emitted noreturn helpers (called at every array index,
> arithmetic op, missing map lookup) stay as direct abort/longjmp paths
> for performance. They're not user-callable; they're internal codegen
> outputs at safety-check sites. Migrating them through Throws would
> add perform-call overhead at every bounds check — unacceptable. They
> remain a separate "fatal abort" path, semantically distinct from
> user-level panic.

The three helpers explicitly call `__qz_panic_jmpbuf_get` (`codegen_runtime.qz:1711, 1742, 1773, 1803`). Their `do_longjmp` blocks call `@longjmp(ptr %jb, i32 1)`. The longjmp lands at the worker loop's `setjmp` site (`codegen_runtime.qz:4448`). Removing the jmpbuf accessors removes the machinery these helpers use to escape a panicking goroutine.

**Possible resolutions, all out of scope for "same commit"**:
- **(A)** Migrate bounds/overflow/map_key to Throws too (contradicts the design memo's explicit performance carve-out — would add a perform-call to every bounds check).
- **(B)** Replace the worker's setjmp path with a Throws-handler path AND have bounds/overflow/map_key route through a different mechanism (a private jmpbuf only those three helpers use, never user-visible). Plausible but is a larger architectural change than "remove jmpbuf in same commit."
- **(C)** Keep the jmpbuf machinery, migrate only the user-facing `panic` intrinsic abort path to Throws (which Phase 2 already partially did via the additive enhancement). The jmpbuf path remains for compiler-emitted helpers.

The brief explicitly directs option (A) ("remove `@__qz_panic_jmpbuf_get` / `@__qz_panic_jmpbuf_set` ... in the same commit"), but option (A) is exactly what the design memo says NOT to do.

### 3. The actual scheduler migration is a non-trivial IR rewrite

Even setting aside the jmpbuf-removal contradiction, migrating the worker loop's panic capture to `with Throws` is structurally large:

The current panic_caught flow at `codegen_runtime.qz:4729-4796` runs **after longjmp from the user task**, on the worker thread, and performs:

- Actor-restart check (`frame[3] == -999`) — reset state to 0, re-enqueue, continue
- Non-actor: store `state = -1`, store `result = -1`
- Cancel-on-failure: trigger cancel-token store if `frame[3] > 0`
- Atomic active_tasks decrement; condvar broadcast if last
- Trace PANIC event
- Notify completion watchers
- Task-local cleanup
- Effect-stack snapshot take + free
- Scope side-table take

These all run **on the worker thread, between user tasks**. Migrating to a `with Throws { throw: rec }` install around `pfn(i64 %task.i)` means:

- The Throws handler runs from inside the user task's effect-perform.
- The handler must either (a) carry the panic flag back via the with-block's value and have post-with cleanup do all of the above, or (b) be invasive enough to do all the cleanup itself before returning.
- Effect-stack interactions are subtle: the panicking task may itself have unmatched `with` installs above the worker's wrap — the worker's cleanup currently ignores this and resets via `__qz_effect_snapshot_take`. A Throws-based unwind must NOT re-enter user handlers further up the stack.
- `panic_caught` currently runs WITHOUT user effect handlers in scope (longjmp jumps over them). A Throws-based equivalent runs WITH the worker's Throws handler being the topmost — but user handlers below it on the stack are still there, and the unwind logic (kind=2) is supposed to pop them. Behavior under nested user `with Throws` inside a goroutine body is the open question.

This is **architectural** work, not migration. It interacts with E.1.c.b snapshots, B.7 scope side-table, actor-restart semantics, and cancel-token store ordering. Sizing: 1-2 quartz-days minimum, not the 0.5 quartz-day the design memo estimated for Phase 3.

### 4. Memo's calibration was based on a wrong premise

The design memo §Calibration estimated Phase 3 at "~0.5 quartz-day, 9 sites, mechanical conversion." That estimate was based on the (incorrect) premise that there were 9 mechanical `panic_caught(fn)` calls to convert. The actual work — rewriting the scheduler's IR-level setjmp/longjmp dispatch to a Throws-based mechanism while preserving every existing semantic (actor restart, cancel-on-failure, snapshot/scope cleanup, condvar broadcast, trace events) — is structurally much larger and the memo doesn't account for it.

## What I did

- Loaded `CLAUDE.md`, `docs/design/ERROR_HANDLING_UNIFICATION.md`, the relevant sections of `codegen_runtime.qz` and `cg_intrinsic_system.qz`.
- Searched for `panic_caught` definitions and call sites — found none of the form the brief implied.
- Inventoried the actual jmpbuf consumers: `codegen_runtime.qz:1711, 1742, 1773, 1803` (bounds/overflow/map_key/async_lock_drain helpers), `codegen_runtime.qz:2788` (frame jmpbuf), `codegen_runtime.qz:4447, 4541, 4731` (worker scheduler loop), `cg_intrinsic_system.qz:538` (panic intrinsic legacy path).
- Compared the brief's directives against the design memo's explicit Phase 3 description and Phase 4-out-of-scope carve-out.
- **Did NOT** touch any source.
- **Did NOT** take a fix-specific binary backup (per CLAUDE.md "save fix-specific binary backup BEFORE touching `self-hosted/*.qz`" — I haven't touched anything).
- **Did NOT** run any specs.

## Recommendation for next session

Pick one path before resuming Phase 3 work:

### Path 1 — Reframe the brief, keep the jmpbuf

Phase 3 (revised): **migrate the scheduler's panic-capture IR** at `codegen_runtime.qz:4444-4796` to install a worker-level `with Throws` around `pfn(...)`. Keep `__qz_panic_jmpbuf_get/set` for the bounds/overflow/map_key helpers; they continue to longjmp (but now into the Throws handler's setjmp slot, which the with-block install creates anyway). Estimate: 1-2 quartz-days. This matches the design memo's actual intent.

**Open questions to resolve in design before code:**
- Where does the recovery sentinel land? The handler returns to the with-block's value-position, but the worker IR currently treats the panic-side branch as a control-flow target with its own basic block. Need to map "with-block returned panic-sentinel" back to the panic_caught block's existing cleanup.
- How does actor-restart interact with the Throws handler? Restart needs to skip task_done cleanup; the handler currently has no way to express "don't unwind past me, restart instead." Possibly: handler returns sentinel `-2` for restart, `-1` for normal panic, and the worker post-with branches.
- Effect-snapshot ordering: the worker installs the Throws handler AFTER `__qz_effect_snapshot_apply` pushes the task's snapshot. On unwind, kind=2 pops down to the matching install — does it pop the snapshot's pushes too? The current panic_caught path explicitly skips this (the snapshot is taken+freed in `td_loop` after the longjmp). Need to verify Throws unwind respects the snapshot boundary.

### Path 2 — Skip the scheduler migration; clean up Phase 2 instead

The Phase 2 panic intrinsic's "scan effect stack for non-blessed Throws" branch (`cg_intrinsic_system.qz:361-498`) is shipped and working. The scheduler's per-task jmpbuf path is also working. There is no concrete user-visible bug forcing the scheduler migration NOW.

If the priority is "delete the jmpbuf machinery to simplify the runtime," that's a much larger architectural plan (option B above) that requires designing a private jmpbuf for compiler-emitted helpers. File as a separate roadmap item, not Phase 3.

If the priority is "ship a clean two-mechanism error model," **that's already achieved**: `panic` routes through Throws when a user handler is installed, falls back to abort otherwise. The scheduler's jmpbuf path is implementation detail, not user surface. Phase 3 may be unnecessary.

### Path 3 — Confirm the brief was correct and I'm wrong

If the user has a different mental model of "Phase 3" than what the design memo describes — e.g., if there's a `panic_caught` stdlib function the user expects me to create or that exists in a branch I'm not seeing — please clarify. I checked the trunk branch with `git status` clean.

## Holes filed (Prime Directive 6)

- **B.9 Phase 3 scope clarification** — the design memo's "9 sites, mechanical conversion" estimate doesn't match the codebase. Either the memo is stale (no `panic_caught` function ever existed; it's always been an IR label) or the implementation diverged from the memo's premise. Recommend updating the memo to describe the actual scheduler-IR-migration scope.
- **Phase 4 / bounds_panic carve-out vs. jmpbuf removal** — Phase 4 keeps bounds/overflow/map_key on the abort+longjmp path; if jmpbuf removal is a roadmap goal, it needs its own design memo addressing how those helpers escape a panicking goroutine without setjmp/longjmp.
- **Worker-loop architectural docs** — the IR at `codegen_runtime.qz:4444-4796` is dense, undocumented at the level needed to migrate it, and interacts with E.1.c.b snapshots, B.7 scope side-table, actor restart, and cancel tokens. Before any future migration of this region, write an architectural memo describing the invariants the worker loop maintains.

## Files of interest (absolute paths)

- `/path/to/quartz/docs/design/ERROR_HANDLING_UNIFICATION.md` — the canonical design
- `/path/to/quartz/self-hosted/backend/codegen_runtime.qz:1711-1813` — bounds/overflow/map_key/async_lock_drain helpers (longjmp consumers)
- `/path/to/quartz/self-hosted/backend/codegen_runtime.qz:2434-2488` — `__qz_panic_jmpbuf_get`/`set` definitions (pthread-key + WASI variants)
- `/path/to/quartz/self-hosted/backend/codegen_runtime.qz:4444-4796` — worker scheduler poll loop (setjmp + panic_caught dispatch)
- `/path/to/quartz/self-hosted/backend/cg_intrinsic_system.qz:324-567` — panic intrinsic (Phase 2 effect-stack scan + legacy longjmp path)
- `/path/to/quartz/std/alloc.qz:640-673` — `__qz_arena_panic_rec` reference handler (the canonical pattern Phase 3's `panic_recover_handler` would imitate)
- `/path/to/quartz/std/concurrency.qz:108-151` — `_go_arena_body` (the closest thing to a real call site of "wrap user fn in with-Throws + return panic sentinel"; this is the pattern the scheduler migration would generalize)

## Status of the workspace

- `git status`: clean (matching the start-of-conversation snapshot)
- `self-hosted/bin/quartz`: untouched, fixpoint stamp still valid from the prior commit
- No backup files written
- No specs run
- This blocker memo is the only file created
