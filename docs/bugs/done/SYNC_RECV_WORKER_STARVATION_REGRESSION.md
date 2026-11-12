---
title: Cross-module suspend-effect not propagated to colorless-dispatch gate — `recv`-wrapper deadlock (REGRESSION of SYNC_RECV_WORKER_STARVATION)
severity: High (every cross-module blocking-channel wrapper called from a goroutine deadlocks — semaphore, and any stdlib/user abstraction over recv)
surfaced: 2026-06-05 (full qspec run: semaphore_spec TIMEOUT >300s; A.44 flaky-cluster triage)
status: ✅ RESOLVED 2026-06-05 (`db62dc66`) — Option 2 (register prefixed name in PASS 0.99b)
regresses: docs/bugs/done/SYNC_RECV_WORKER_STARVATION.md (Cause A/B, closed 2026-04-30 via PASS 0.99b)
---

# Resolution (2026-06-05, `db62dc66`)

Fixed via **candidate (2), dual registration** — NOT the gate-side bare
fallback (1), which was tried first and **over-dispatched**: bare `step`
collided with a suspendable `step`, so `quake$step` got a spurious
`@__Future_quake$step$new` and `opt` rejected the Quakefile IR. Registering
the SPECIFIC prefixed name keeps the gate's match exact.

`mir_propagate_suspend_ast` (`mir_lower_async_registry.qz`) now tracks each
function's original (possibly module-prefixed) `entry.name` alongside its
bare name, and registers BOTH as async-target + EFFECT_SUSPEND leaf. The
colorless gate's exact lookup on the prefixed `resolved_name` now matches
genuinely-suspendable cross-module functions; common bare-name collisions
(`step`) no longer false-positive because only the specific prefixed name
is registered.

Verified: minimal cross-module repro fixed (was 6/6 deadlock); semaphore_spec
PASS (was >300s hang); full 2026-04-30 async sweep green
(concurrency/scheduler/sync_primitives/spawn_await/await_nonasync/
colorblind_async/async_channel/channel_handoff + nested_poll_recv_park);
Quakefile opt-clean (over-dispatch regression check); `quake guard`
fixpoint 2688 fns (+48 vs pre-fix 2640 — the compiler's own cross-module
suspend wrappers now correctly get `$poll`/`$new` variants; self-consistent
gen1==gen2); Rule-2 style_demo + brainfuck smokes green.

**Follow-up still open:** the regression spec `nested_poll_recv_park_spec`
PASSED throughout (even pre-fix) — it does not catch the cross-module-only
case. Add a spec matching the minimal repro shape (imported recv-wrapper,
NO same-file recv-caller) so this cannot recur silently. Tracked in
ROADMAP A.44.

---
# Original filing (root-cause analysis, pre-fix) below
---

# Summary

A goroutine that calls an **imported (cross-module)** function which
blocks on `recv` (directly or transitively) **deadlocks deterministically**.
The canonical victim is `std/sync/exclusion/semaphore` — `semaphore_acquire`
is `recv(sem)`, `semaphore_release` is `send(sem, 1)` — so any
rate-limiting / bounded-concurrency use from `go` tasks hangs.

This is a regression of `SYNC_RECV_WORKER_STARVATION` (closed 2026-04-30).
That fix added **PASS 0.99b** (`mir_propagate_suspend_ast`) so a goroutine
calling a `recv`-wrapper gets the wrapper colorless-dispatched (parks the
task cooperatively) instead of calling its plain body (blocks the worker
thread). The propagation still runs, but its registration and the
colorless-dispatch **lookup now disagree on the function-name form**, so
the gate misses for cross-module callees.

# Minimal reproducer (deterministic, `--no-cache`, single worker)

```
# /tmp/mmod/chanwrap.qz
def cw_acquire(ch: Int): Void
  recv(ch)
end
def cw_release(ch: Int): Void
  send(ch, 1)
end
```
```
# /tmp/mmod/main.qz
import * from chanwrap
def task(ch: Int): Int
  cw_acquire(ch)
  sched_yield()
  cw_release(ch)
  return 0
end
def main(): Int
  var ch = channel_new(1)
  send(ch, 1)
  sched_init(1)
  var h = vec_new()
  var i = 0
  while i < 2
    h.push(go task(ch)); i += 1
  end
  i = 0
  while i < 2
    await h[i]; i += 1
  end
  sched_shutdown(); puts("done"); return 0
end
```
`quartz --no-cache -I /tmp/mmod ... main.qz` → compiles, **deadlocks** 6/6.

Move `cw_acquire`/`cw_release` into `main.qz` (same file) → **passes** 6/6.
The ONLY difference is the module boundary. (`std/sync` semaphore: same
shape, `permits=1 tasks=2 workers=1` already deadlocks.)

# Root cause (IR-proven)

Compare `__Future_task$poll` in the two builds:

| case | `task$poll` calls the wrapper as | result |
|---|---|---|
| same-file (`cw_acquire`) | `@__Future_cw_acquire$new` (colorless-dispatch — parks) | ✅ |
| cross-module (`chanwrap$cw_acquire`) | `@chanwrap$cw_acquire` (plain body — blocks worker) | ⛔ deadlock |

The wrapper IS coroutine-lowered in both cases (`__Future_chanwrap$cw_acquire$poll`
exists), but `task$poll` calls the **plain** variant, not the `$poll` one.

The colorless-dispatch gate at `self-hosted/backend/mir_lower_expr_handlers.qz:3281-3290`:

```
if mir_lower_gen::mir_gen_is_active() >= 2
  if mir_lower_async_registry::mir_has_effect(resolved_name, 2)        # EFFECT_SUSPEND
    if mir_lower_async_registry::mir_is_async_target(resolved_name)
      if not <generator>
        return ctx.mir_emit_colorless_call(resolved_name, args)
```

`resolved_name` for a cross-module callee is the **module-prefixed**
`"chanwrap$cw_acquire"`. But PASS 0.99b
(`mir_lower_async_registry.qz:563 mir_propagate_suspend_ast`) keys its
entire call-graph and `susp` set on **bare** names
(`bare = mir_strip_module_prefix(entry.name)`, line 584) and registers
suspendable functions under the **bare** name:

```
mir_record_async_target(nm, stores[i])   # line 676 — nm is bare
mir_record_effect_leaf(nm, 2)            # line 678 — bare
```

Both lookups are exact-match, no prefix stripping:
* `mir_is_async_target` (line 247) — linear `== name` scan.
* `mir_has_effect` → `mir_get_function_effects(name)` — exact map lookup.

So the gate asks `mir_has_effect("chanwrap$cw_acquire", 2)` /
`mir_is_async_target("chanwrap$cw_acquire")`, both registered only as
`"cw_acquire"` → **miss** → falls through to the plain `mir_emit_call`
at line 3294 → blocking `recv` on the worker → deadlock.

The propagation fixpoint itself is correct (it marks both `cw_acquire`
and `task` suspendable under bare names); the break is purely the
**bare-registration vs. prefixed-lookup mismatch** at the gate. Same
mangled-vs-bare-name class as A.44(2) (async-generator `$poll` symbol).

# Candidate fixes (in increasing blast radius)

1. **Gate-site fallback (smallest):** at `mir_lower_expr_handlers.qz:3282-3283`,
   if the exact `resolved_name` check fails, retry with
   `mir_strip_module_prefix(resolved_name)`. Blast radius = the colorless
   gate only. Risk: a prefixed fn sharing a bare name with a suspendable
   one would over-dispatch — low, but verify against the compiler's own
   heavy async usage via fixpoint.
2. **Dual registration:** in `mir_propagate_suspend_ast`, register both
   the bare name and the original prefixed `entry.name` as async-target +
   effect-leaf.
3. **Strip inside the registries:** make `mir_is_async_target` /
   `mir_get_function_effects` strip the prefix on lookup-miss.

Prefer (1) or (2); both keep the bare-keyed propagation intact and only
reconcile the boundary. Whichever lands MUST hold fixpoint (the compiler
uses channels/async heavily — a wrong over/under-dispatch mis-lowers its
own code) and pass the full async sweep (see below).

# Why the regression spec misses it

`spec/qspec/nested_poll_recv_park_spec.qz` (the 2026-04-30 lock-in spec)
**passes standalone** even though `semaphore_spec` (same std/sync 6/2/4
pattern) **hangs standalone**. The trigger differs by something subtle in
that file's compilation (it also defines same-file `my_acquire`/`wrap_task`
that call `recv`/the wrapper). Adding a *dead* same-file `recv`-caller to
the minimal repro does NOT unblock it, so it is not simply "a main-module
recv-caller seeds propagation." The exact divergence between the two
specs is unresolved (needs compiler instrumentation: dump the
`resolved_name` form + the `susp`/`_async_func_names` keys at the gate
for each). **When fixing: also harden `nested_poll_recv_park_spec` (or
add a dedicated cross-module-only spec with NO same-file recv-caller —
exactly the minimal repro shape) so the regression cannot recur silently.**

# Verification checklist for the fix

* Minimal repro (`/tmp/mmod`, cross-module wrapper, no same-file
  recv-caller) — must complete, not deadlock.
* `semaphore_spec` standalone — `quake qspec_file` must finish < a few s,
  rate-limiting `max <= 2`.
* `nested_poll_recv_park_spec` — still 3/3.
* Full async sweep (the 2026-04-30 set): concurrency_spec, scheduler_spec,
  sync_primitives_spec, spawn_await_spec, await_nonasync_spec,
  colorblind_async_spec, async_channel_spec, channel_handoff_spec.
* `quake guard` fixpoint (function-count-neutral expected) + Rule-2 smokes
  (style_demo, brainfuck).

# Scope note

`semaphore_spec` is currently NOT in the slow-lane quarantine
(`Quakefile.qz:5628 _qspec_quarantined_names`), so this deadlock gates
every `quake qspec` run (300s timeout ×). Until the compiler fix lands,
quarantining `semaphore_spec` would unblock the main lane — but the real
fix is the gate name-match above, not hiding the spec.
