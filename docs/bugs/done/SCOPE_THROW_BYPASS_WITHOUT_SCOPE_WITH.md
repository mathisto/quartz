# SCOPE_THROW_BYPASS_WITHOUT_SCOPE_WITH

**Filed:** 2026-05-03 (during SCOPE_INHERITANCE_SPAWN_THEN_CANCEL_FLAKE closeout)
**Refined:** 2026-05-03 (root-cause investigation produced the actual minimal repro)
**Closed:** 2026-05-03 (fix landed: PASS 0.99b fn-param-call edge — see "Resolution" below)
**Status:** CLOSED
**Severity:** HIGH at filing time

## Resolution (2026-05-03)

Fixed in same-day session. The IR-diff diagnosis was correct: PASS 0.99b's
edge-collection walked NODE_CALL targets as plain identifier names and
relied on global-name lookup to bridge `scope_with`'s `body()` site to
the user's function for suspendability propagation. When the user's fn
happened to match the parameter name `body`, that bridge fired by
accident and scope_with auto-promoted to colorless. Otherwise scope_with
stayed sync and the throw chain broke at the sync/async boundary.

Fix is structural at PASS 0.99b. New helper `mir_extract_param_names`
in `self-hosted/backend/mir_lower_async_registry.qz` extracts the formal
parameter names from each user function's NODE_FUNCTION node.
`mir_ast_collect_callees` now takes the param-name list and, whenever a
NODE_CALL targets an IDENT matching one of them, also pushes the
synthetic edge `__qz_fn_param_call_marker__`. The marker is added to
`mir_is_suspend_leaf_name` so the existing suspend-fixpoint propagates
suspendability to any function that calls through a fn-typed parameter
— exactly the colorless-promotion-need case the over-approximation
covers safely (per the existing comment, mistakenly-marked functions
just get an unused $poll body).

Cost: +15 functions on the fixpoint (2461 → 2476) — the new $poll bodies
generated for higher-order helpers across std (`scope_with`, `with_*`,
`map`, `filter`, `each`-family). Acceptable given the over-approximation
guarantee and the surprising-failure-mode the bug created.

Regression coverage: `spec/qz/scope_throw_bypass_smoke.qz` (the named-fn
shape) plus an inline-lambda exercise verified out-of-tree. Existing
scope qspec suites (scope_with 8/8, scope_substrate 18/18, scope_sleep
7/7, scope_inheritance 5/5, scope_channel 9/9, scope_mutex 4/4,
scope_deadline_timer 6/6, sched_sync 12/12, generators_p4b3_suspend 4/4,
generators_p4b9_effect_composition 7/7, phase_6_1c_handler_throws 5/5)
all green. Fixpoint clean. Style_demo + brainfuck non-self smokes pass.

Sister investigation: the bug doc speculated that "any helper taking a
`Fn(...): T` parameter and called with async-target fns" might be
affected. Confirmed in scope by the same fix. Open follow-up: Fn-typed
LOCALS (`var f = some_fn; f()`) have the same shape but aren't covered
yet — the fix only walks formal parameters. Defer until a real bug
surfaces; same over-approximation extension would close it.

---

## Symptom

When a goroutine `child()` inherits its scope via Phase 4b spawn-time
TLS round-trip (i.e. NOT via an explicit `scope_with(s, body)` inside
the goroutine), and the goroutine installs `with Throws { throw: cap }`
and then calls `scope_sleep_ms(N)` directly (no `scope_with` wrap),
the throw fired by `scope_sleep_ms` on cancel **does not reach the
`cap` handler** — `cap_fired` stays 0 even though `scope_sleep_ms`
exits early via the cancel branch.

The same code wrapped with `scope_with(current_scope(), inner)` (or
any equivalent ambient `scope_with`) DOES route the throw to `cap`.

## Reproduce

Standalone form:

```be
import * from std/sync/scope
import * from std/throws

var s = 0
var cap_fired = 0
var caught_msg = ""

def cap(op_name: Int, argc: Int, argv: Int): Int
  cap_fired += 1
  caught_msg = as_type<String>(load(argv, 0))
  return 0
end

def child(): Int
  # current_scope() == s here (Phase 4b inheritance verified separately)
  with Throws { throw: cap } do ->
    scope_sleep_ms(5_000)   # parent cancels s → wake → throw fires
    0
  end
  # After the with-block: cap_fired == 0, caught_msg == ""
  # (yet scope_sleep_ms exited early, NOT after 5 seconds — so its
  # cancel branch did run and `throw(reason)` was performed.)
  return 0
end

def body(): Int
  var h = go child()
  sched_sleep(50)
  scope_cancel_with(s, "parent-cancel")
  await h
  return 0
end

def main(): Int
  s = scope_with_cancel(scope_root())
  scope_with(s, body)
  return 0
end
```

Workaround that DOES work:

```be
def child_inner(): Int
  scope_sleep_ms(5_000)
  return 0
end

def child(): Int
  with Throws { throw: cap } do ->
    scope_with(s, child_inner)   # explicit scope_with wraps and re-throws
    0
  end
  ...
end
```

## Refined diagnosis (2026-05-03)

The original framing of "scope_sleep_ms throws don't reach cap WITHOUT
scope_with wrap" was incorrect. The actual trigger is more surprising:

**The body function passed to `scope_with(s, body)` MUST be named `body`
for the throw chain to work.** Any other name (e.g. `body_c`, `the_fn`,
or even an inline lambda) breaks the throw-to-cap propagation.

Minimal reproducer (works ↔ fails by single-character rename):

```be
import * from std/sync/scope
import * from std/throws

var cap_fired = 0
var caught_msg = ""
var s = 0

def cap(op_name: Int, argc: Int, argv: Int): Int
  cap_fired += 1
  caught_msg = as_type<String>(load(argv, 0))
  return 0
end

def child_inner(): Int
  scope_sleep_ms(5_000)
  return 0
end

def child_with_scope_with(): Int
  with Throws { throw: cap } do ->
    scope_with(s, child_inner)
    0
  end
  return 0
end

def body(): Int                              # <-- named "body" → WORKS
  var h = go child_with_scope_with()
  sched_sleep(50)
  scope_cancel_with(s, "parent-cancel")
  await h
  return 0
end

def main(): Int
  s = scope_with_cancel(scope_root())
  scope_with(s, body)                        # <-- happens to match param name
  puts("cap_fired=#{str_from_int(cap_fired)}, caught_msg='#{caught_msg}'")
  return 0
end
```

Renaming `body` → `body_c` (everywhere — declaration AND call site)
silently flips `cap_fired` from 1 to 0. Renaming `body` → `the_fn`,
or replacing the named function with an inline lambda
`scope_with(s, () -> { ... })`, also produces the failure.

This points STRONGLY at a name-resolution bug in `mir_lower_call`'s
shadow-check path — sister to the `feedback_handoff_diagnosis_verify`
incident on 2026-05-02 (CAN_E_TINY_PROGRAM_SIGSEGV closed `9c063c7e`),
where `mir_lower_call` was looking up function names globally before
checking lexical scope, causing a top-level `def f` to shadow a
`f: Fn(...)` parameter.

`scope_with`'s parameter is named `body: Fn(): Int`. When the user's
function happens to be named `body`, scope_with's `body()` call site
inside std/sync/scope.qz appears to resolve correctly (whether via
parameter or via global lookup of the user's `def body` — both reach
the same target). When the user's function is named anything else
(e.g. `body_c`), the parameter binding works but the dispatch path
through scope_with's `body()` invocation may take a different code
path that loses the effect-stack continuation.

**This is a pre-existing compiler bug surfaced by the B.7 Phase 4 work,
NOT a new regression.** The flaky qspec test SCOPE_INHERITANCE
inadvertently dodged it because its body function was named
`si_spawn_then_cancel_body` and `scope_with`'s implementation may
inline-poll differently in qspec context.

**Investigation next steps**:
1. Diff the LLVM IR between `body` and `body_c` versions — locate
   the actual call instruction emitted for `body()` inside scope_with.
2. Check `mir_lower_call` shadow-check logic at the post-CAN_E fix
   site for parameter-name matching — the fix may only cover `var`
   bindings, missing parameter shadows.
3. Sister test: does the bug repro for ANY effect-bearing call
   through a `Fn(): Int` parameter, or only for scope_with's body?

**Investigation update 2026-05-03 PM** — IR diff between the two
versions is ~750 lines different. The KEY finding:

In the WORKING version (user's fn named `body`), scope_with is
**auto-promoted to colorless** by PASS 0.99b. The IR shows
`%__colorless_frame_scope_with = alloca i64` and
`%v6 = call i64 @__Future_scope_with$new(i64 %v4, i64 %v5)` —
scope_with becomes a Future + $poll, called via the standard
async dispatch path (closure-or-plain branching).

In the FAILING version (user's fn named `the_fn`), this is
**absent** — scope_with stays a plain synchronous function. Its
parameter `body` is called via plain indirect dispatch
(`%v8.pfn = inttoptr i64 %v7 to i64 (i64)*` then plain call).

The trigger is in PASS 0.99b's auto-promotion heuristic, NOT in
mir_lower_call's shadow check. PASS 0.99b decides whether
scope_with needs colorless promotion by inspecting its call graph;
when scope_with's `body()` call site resolves to the user's
`def body` directly (because both names match `body`, which lets
the static-resolution step succeed), PASS 0.99b can see that the
user's body calls async stuff (`go fn()`, `await`, `scope_cancel_with`)
and concludes scope_with itself needs to be colorless.

When the user's fn has a different name, scope_with's `body()`
parameter dispatch is purely indirect — PASS 0.99b can't see
through the parameter to determine if the called fn is async,
so conservatively does NOT promote scope_with. scope_with runs
synchronously inline, the user's body's `await` and effect
machinery operate in a context that lacks the colorless
async-frame setup, and the throw-perform's continuation chain
is broken at the synchronous/async boundary.

This is a fundamental gap in PASS 0.99b's promotion heuristic:
**a function that takes a `Fn(...): T` parameter should be
treated as POTENTIALLY async if any caller passes an
async-target function**. Today the heuristic looks at the
direct call graph from the function's body, missing the
indirect-through-parameter case.

**Proper fix**: extend PASS 0.99b to mark a function as
"colorless if any caller passes an async-target fn through a
fn-typed parameter." Or alternatively, mark the function as
colorless when its body contains `body()` calls on a fn-typed
parameter and ANY known caller passes an async target. Either
way, this is a deep typecheck/MIR pass change touching the
auto-promotion infrastructure.

**Workaround for now**: name the user-body fn passed to
scope_with as `body` (matching the parameter name) so the
static-resolution path fires and auto-promotion works.
Document this in `docs/QUARTZ_REFERENCE.md` Scope section.

## Diagnosis trail

`scope_with(s, body)` installs its own internal `with Throws { throw: _sw_catch }`,
so the actual control flow when wrapped is: `scope_sleep_ms` throws →
`_sw_catch` (top of effect stack) catches → records panicked + msg →
returns -1 (longjmp) → `scope_with` runs cleanup (restore prev scope,
cancel s) → re-throws via `throw(captured_msg)` → THIS time the
perform finds `cap` (top of stack now that `_sw_catch` was popped) →
`cap` fires.

Without `scope_with`, the perform inside `scope_sleep_ms` should find
`cap` directly at the top of the effect stack (no `_sw_catch` between
them). But it doesn't — `cap` is silently bypassed and execution
continues past the with-block as if the throw never fired.

Possibilities not yet investigated (left for the deep-dive session):

1. **Module-boundary perform resolution.** `scope_sleep_ms` lives in
   `std/sync/scope.qz`; `cap` is installed in user code. The Throws
   op-name lookup may match against a different effect declaration
   (e.g. a re-export shadow).
2. **Snapshot inheritance interaction.** The goroutine's effect-stack
   snapshot from Phase 4b/E.1.c.b may include a watermark or filter
   that suppresses kind=2 (longjmp) handlers above the snapshot
   boundary, leaving only blessed defaults visible. Note the
   `codegen_runtime.qz` comment around line 358-363 explicitly drops
   parent-installed jmp_buf addresses from snapshots — but child
   installs cap AFTER the snapshot is applied, so cap's jmp_buf
   should be valid.
3. **Goroutine task panic_caught path.** The worker $poll dispatch
   wraps each poll in a per-task panic_caught region (jmp_buf at
   the worker's task frame). If `scope_sleep_ms`'s throw longjmps
   to the WORKER's panic_caught instead of `cap`, the throw would
   be caught at the wrong layer — the worker would treat it as an
   unhandled panic, but the test's behavior (silent continuation
   past the with-block, with recheck still observing cancel) is
   inconsistent with that hypothesis.
4. **Effect-stack TLS save/restore around scope_sleep_ms's
   sched_sleep.** During sched_sleep the worker's TLS state may be
   saved/restored across yield boundaries; if cap's stack frame
   pointer becomes stale after a yield, the re-emerged perform
   couldn't find a valid handler.

The most-likely cause given the workaround is (2) or (4) — the
`scope_with` wrap shadows whatever stale state breaks the direct
path. Bisecting will require either runtime tracing of the effect
stack across `scope_sleep_ms`'s sched_sleep boundary, or examining
the generated IR for `scope_sleep_ms` and child's with-block.

## Production impact

**Workaround is well-defined**: every spec/qspec test that uses a
scope-aware blocking primitive already follows the pattern
`with Throws { throw: handler } do -> scope_with(s, body); 0 end`.
The pattern works deterministically. Documented in
`docs/QUARTZ_REFERENCE.md` "Scope and Cancellation" section as the
canonical form (Phase 6).

**Surprising-failure-mode** is the actual hazard: a user writing
`with Throws { throw: cap } do -> scope_sleep_ms(N); 0 end` inside
a goroutine that inherits a scope via spawn-time TLS will see the
sleep exit early on cancel but no Throws handler will fire. If the
user expects to recover via cap, they'll silently lose error
information. This is the hazard worth fixing.

## Fix space

1. **Document the requirement** (cheapest): explicitly state in
   `docs/QUARTZ_REFERENCE.md` Scope section that scope-aware
   blocking primitives must be invoked under `scope_with(s, body)`,
   not just under inherited `current_scope()`. Caveat to Phase 4b
   inheritance.
2. **Make scope-aware primitives self-wrap** (medium): each helper
   in `std/sync/scope.qz` (`scope_sleep_ms`, `scope_recv`,
   `scope_send`, `scope_lock`, `scope_rwlock_read`, `scope_rwlock_write`)
   could wrap its body in an internal `scope_with(current_scope(), inner)`
   to ensure the throw bridge is in place. Cost: each call now does
   an extra push/pop, and `scope_cancel(current_scope())` would fire
   on every call (idempotent — but spurious work).
3. **Fix the root cause** (deep): once diagnosed, the throw-perform
   should find `cap` directly without needing the wrap. Estimated
   1-3 quartz-days investigation + fix.

Recommended path: (1) document immediately as part of the closeout,
(3) when a real-user bug surfaces. (2) is wrong because it changes
the semantics of `scope_cancel(s)` for inherited scopes.
