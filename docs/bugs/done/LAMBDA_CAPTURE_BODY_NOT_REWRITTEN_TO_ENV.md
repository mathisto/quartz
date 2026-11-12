# LAMBDA_CAPTURE_BODY_NOT_REWRITTEN_TO_ENV

**Filed**: 2026-05-05 (TUI Phase 4 — toast widget deckbuilder integration)
**Severity**: Medium — closure captures into Cmd thunks unusable
**Status**: CLOSED 2026-05-06

## Closure

Original diagnosis was downstream (codegen failing to rewrite body uses of
captured names to env loads). Real cause was upstream: the MIR capture
walker `mir_collect_captures_walk` in `self-hosted/backend/mir.qz` had
no case for `NODE_ENUM_ACCESS`. Enum payloads live in `children`, not
`left`/`right`, so `-> FrameMsg::App(seq)` walked past the constructor
without descending into the payload, `seq` was never collected, the
closure env was alloc(8) (only fn pointer slot), and the body's
`load i64, ptr %seq` referenced an alloca that never existed.

Fix: add NODE_ENUM_ACCESS case to `mir_collect_captures_walk` (mir.qz)
that descends into payload children. Mirrored the same fix in
`tc_collect_captures_walk` (typecheck_capture.qz) where the parallel
hole would have silently let Send/Sync analysis miss captures inside
enum constructors. Added precautionary cases for NODE_IS_CHECK,
NODE_TYPE_CAST, NODE_YIELD, NODE_DEFER (MIR) and NODE_IS_CHECK,
NODE_TYPE_CAST, NODE_YIELD (TC) — all wrap expressions in `left` and
the same shape would silently swallow captures inside.

Regression spec: `spec/qspec/lambda_capture_body_rewrite_spec.qz`.

Generalizable rule: any AST walker that dispatches on NODE_* kind with
a no-op default has the same coverage-hole hazard as the resolver
prefix-rewrite walker (closed 2026-05-06 for NODE_GO). When extending
or auditing such walkers, an explicit `else` branch that emits a
"unknown kind" diagnostic during dev would catch this category up
front.

## Summary

Lambdas that capture an `Int` local from an enclosing function lift the
capture into the closure environment correctly at the construction site
(the env's slot is populated with the captured value), but the lambda's
**body codegen continues to reference the captured local by its outer
SSA name** instead of loading from the env. The result is an LL with
`%seq` (or whatever the captured local was named) referenced inside
the lambda function but never defined — `llc` rejects with
`error: use of undefined value '%seq'`.

## Repro shape

A lambda built inline that captures a function-local Int and is passed
into `Cmd::After`/`Cmd::Run`/`Cmd::Every` (or any `Fn(): T`-shaped
parameter):

```be
def _expire_cmd(seq: Int, ttl_ms: Int): tui::Cmd<AppMsg>
  var thunk: Fn(): tui::FrameMsg<AppMsg> =
    -> tui::FrameMsg::App(AppMsg::ToastExpired(seq))
  return tui::Cmd::After(ttl_ms, thunk)
end
```

`seq` is the captured Int. The lambda's body wants to construct
`AppMsg::ToastExpired(seq)`. The compiler lifts `seq` into the
closure env at construction (we see `%__env = alloca i64; store
%p0, ptr %__env` in the lambda's prelude), but the body reads
`%v6 = load i64, ptr %seq` — `%seq` only exists in the OUTER
function's frame as `%seq = alloca i64`. The lambda has no `%seq`
in its SSA scope, so `llc` fails.

## Repro that failed in this session

Two callsites in `game/deckbuilder/main.qz` (Phase 4 toast wiring):

1. `_apply_combat_with_toast` — captures `seq` from an `if status_changed`
   block; first attempt failed.
2. After refactoring into a top-level helper `_expire_cmd(seq, ttl_ms)`
   so the captured value is a function parameter (not a block-scoped
   local), the same bug surfaces. Function-parameter capture isn't
   meaningfully different from block-scoped capture from the codegen's
   perspective.

The full LL fragment showing the bug:

```ll
define i64 @__lambda_4(i64 noundef %p0) nounwind "frame-pointer"="all" {
fn_entry:
  %__env = alloca i64
  store i64 %p0, ptr %__env, align 8
  ; ... allocates two pair tuples ...
  %v6 = load i64, ptr %seq, align 8           ; ← %seq undefined
  ; ... uses %v6 to build ToastExpired payload ...
}
```

`%__env` is allocated and populated, but never read. The `load`
should target `%__env` (or some offset into the captured tuple),
not `%seq`.

## Workarounds

1. **Use a top-level zero-capture function as the thunk.** All
   existing Cmd::Run / Cmd::After / Cmd::Every consumers in tree
   (examples/tui/incremental, examples/tui/types_smoke, spec/qz/
   tui_cmd_every_smoke, std/tui/widgets/_minimal_run) use this
   pattern. The thunk takes no args and produces a fixed-shape
   FrameMsg; no captures needed.

   For dynamic data (a sequence number, a parameterised message),
   this means encoding the data in module-level mutable state
   (violates determinism contract) or accepting a fixed-shape
   FrameMsg without the dynamic component.

2. **Drop the captured value's role in the design.** This is what
   the deckbuilder Phase 4 wiring did: `ToastExpired` carries no
   `seq` payload, the AppMsg variant becomes bare, and the
   `_maybe_clear_toast` helper unconditionally clears the toast.
   The race protection (stale Expire from an older toast clearing
   a newer toast) is sacrificed for buildability.

## Where to dig

- The closure-capture lifting pass does the right thing at the
  construction site (alloc of the env tuple + store of captured
  values). Verify that the lambda body's name resolution rewrites
  references to captured names into env-relative loads.
- See `_gen_active leaks into nested lambdas` memory entry —
  `mir_gen_pause_active`/`mir_gen_resume_active` are the
  established hooks for similar lambda-body codegen bugs. The
  capture-rewrite pass for lambda bodies likely needs a similar
  bookkeeping fix.
- `feedback_ast_let_init_left_slot.md` was a prior closure-capture
  bug where the capture-walker missed `var x = init` shapes. That
  fix is in tree (typecheck_capture.qz). This bug is downstream
  in codegen, not capture detection — the env IS populated; the
  body just doesn't load from it.

## Impact

Any TUI consumer that wants to schedule a delayed message keyed
to per-event state (a sequence number, an event id, a snapshot of
some app state at the time of dispatch) hits this. Today's
workaround is to encode that state into the FrameMsg shape itself
and pass through fixed thunks — only viable when the state space
is tiny (which it isn't, for sequence numbers).
