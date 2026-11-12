# Phase 5 — Legacy primitive migration: design call before mechanics

**Status:** filed 2026-05-03, after Phases 4a-c + 4d + 4e.1-5 ship and the
4e.6/4e.7 deferred-shape memo lands. Captures the semantic reframe that needs
to happen before the original SCOPE_UNIFICATION.md Phase 5 ("~1 quartz-day,
mostly mechanical") can be executed.

## The reframe

The original [`SCOPE_UNIFICATION.md`](SCOPE_UNIFICATION.md) Phase 5 sized
the legacy migration at "~1 quartz-day, mostly mechanical" with an explicit
goal of:

> deprecate `cancel_token_*` API in the same commit as proving the Scope
> substrate covers it.

**That framing is wrong.** Cancel tokens and scope inheritance are not
redundant carriers of the same concept; they are two distinct primitives
with different identity semantics. Migrating the structured-concurrency
wrappers (`go_scope`, `go_scope_timeout`, `go_supervisor`) to call into
`std/sync/scope.qz` is mechanical. Migrating `go_cancellable(f, tok)` away
from cancel tokens is a deletion that costs real expressivity.

## The semantic gap

`Scope` is **structural**: cancellation propagates parent → child along
the scope tree. The only code that can cancel a goroutine is code holding
a reference to one of its enclosing scopes (or its own scope handle).

`CancelToken` is a **first-class capability**: a value you can pass around.
Any code holding the token can cancel any goroutine spawned with that token.
At the runtime level it is literally an `Atomic<i64>` flag (see
`cg_intrinsic_conc_task.qz:1407`, `cancel_token_new` = aligned-i64-on-heap).

These compose differently:

```
Scope tree:                    Cancel token:
                                                    ┌──> child A ──┐
   parent                       caller ── tok ──────┼──> child B ──┼── any holder
   ├── child A   (cancel  ─>    ▲         ▲         └──> child C ──┘   can cancel
   ├── child B    walks tree)   │         │              all children
   └── child C                  unrelated thread
                                may also hold tok
```

The cancel token is what `supervisor_tree` (std/concurrency.qz:312) uses
to implement REST_FOR_ONE / ONE_FOR_ALL restart strategies — when child N
fails, sibling cancellation across the peer set is expressed by writing
to the shared token. **Cancellation here is peer-to-peer, not
parent-to-child.** Expressing this with scope alone requires giving each
child its own scope and stashing the scope handles in a sibling-visible
vec — which is a reference-bag, just spelled differently. The cancel-token
primitive is a more direct expression of the underlying capability.

The same gap surfaces in `scope_cancel_on_failure` (line 202): the body
explicitly receives a token and threads it into `go_cancellable` calls
because the cancellation pattern is "any peer's failure cancels all the
others." That's not a parent-controlled cascade.

## What that means for Phase 5

Three buckets:

### Bucket 1 — pure thin wrappers (mechanical, ~0.3 quartz-day)

These primitives use the module-global `_current_scope_*` ambient state
in `std/concurrency.qz` (lines 218-221). Phase 4a-c shipped a real
TLS-backed scope tree; the four module-globals are now dead-state
backstops, retained only because their callers haven't been migrated.

| Legacy | Replacement | Notes |
|---|---|---|
| `go_scope(body)` (line 460) | `s = scope_with_cancel(current_scope()); scope_with(s, body)` | go_spawn'd children inherit `s` via Phase 4a-c TLS bridge automatically. |
| `go_supervisor(body)` (line 467) | `s = scope_supervised(current_scope()); scope_with(s, body)` | Same pattern. Returns Vec<Int> by collecting child handles inside body — preserve via a wrapper that captures children. |
| `go_scope_timeout(ms, body)` (line 475) | `s = scope_timeout(current_scope(), ms); scope_with(s, body)` | Phase 4d's deadline timer fires proactively; chunked-poll wakes on cancel within ~50ms (Phase 4e.1-5). |
| `structured_scope(body)` (line 235) | Inlined into `go_scope` rewrite. | Internal helper; not user-facing, delete. |
| `structured_supervisor(body)` (line 269) | Inlined into `go_supervisor` rewrite. | Same. |
| `scope_with_timeout(ms, body: Fn(Int): Int)` (line 182) | Token-receiving body — strictly a `scope_cancel_on_failure` variant with deadline. Move to Bucket 2 (semantic gap). | See below. |

The four `_current_scope_*` module-globals get **deleted entirely**. The
TLS-backed scope tree replaces them.

**Spec migration**: `spec/qspec/go_scope_spec.qz`,
`spec/qspec/supervision_spec.qz`, and `spec/qspec/cancel_propagation_spec.qz`
exercise these wrappers. The wrappers preserve their existing return-type
contracts (Int sentinels, Vec<Int> for supervisor), so spec assertions
should pass without rewrite. Verify, don't assume.

### Bucket 2 — capability-preserving (~0 work, retain + document)

These primitives use cancel tokens for peer-to-peer or
externally-cancellable patterns. They are **not legacy aliases** for
scope-tree functionality and should remain after Phase 5:

| Primitive | Why it stays |
|---|---|
| `go_cancellable(f, tok)` (line 139) | Caller-supplied cancel identity. Already inherits spawn-time scope (Phase 4a-c) — strictly more capable than scope-only spawning. Body responds to BOTH tok-fire AND scope-cancel. |
| `go_cancel_on_success(f, tok)` (line 445) | Race-helper primitive: first task to succeed cancels the rest. Uses `frame[3] = -tok` as the cancel-on-success sentinel; scheduler-internal contract. |
| `cancel_token_new` / `cancel_token_cancel` / `cancel_token_is_cancelled` / `cancel_token_with_deadline` / `cancel_token_free` | Atomic-i64 capability primitive. Direct intrinsics, ~30 lines of LLVM IR each. Removing them to replace with scope-handle-passing would be strictly less ergonomic at the supervisor-tree / mapreduce-with-early-return / racing-with-shared-cancel patterns. |
| `supervisor_tree(strategy, max_restarts, children)` (line 312) | OTP-style restart strategies. Peer-to-peer cancel via shared token vec; the natural expression of REST_FOR_ONE / ONE_FOR_ALL. |
| `scope_cancel_on_failure(body: Fn(Int): Int)` (line 202) | Body receives a token explicitly. Peer-to-peer cancel-on-first-failure. The token-shape is the body's contract; a scope-only rewrite would change the user-visible signature. |
| `scope_with_timeout(ms, body: Fn(Int): Int)` (line 182) | Deadline-bounded variant of `scope_cancel_on_failure`. Same justification. |
| `async_timeout(f, ms)` / `sched_timeout(f, ms)` (`std/futures.qz:103/119`) | Channel + select-timeout — neither uses cancel tokens nor scope. Unchanged. |

**Documentation requirement** (Phase 6): the decision tree picks up a
second axis.

```
Axis 1: who can cancel?
  - just the enclosing block / parent task ────> Scope (structural)
  - any holder of a passable identity ─────────> CancelToken (capability)

Axis 2: how is the cancel-target named?
  - implicit (current_scope, TLS-propagated) ──> with scope.X do ... end
  - explicit (passed as argument) ─────────────> tok = cancel_token_new(); ...

Most code lives at (structural, ambient). The (capability, explicit)
corner is the supervisor_tree / mapreduce-with-early-return / race shape.
```

### Bucket 3 — adjacent cleanup (~0.1 quartz-day)

- `tools/lint.qz:1500-1538` (QZ7206 "bare go outside structured concurrency
  scope") nudges users toward `go_scope` / `go_supervisor` / `structured_scope`
  / `structured_supervisor`. Update to suggest `with scope_with(...) do ...`
  as the canonical form, while still accepting the legacy wrappers as valid
  (since they exist after Phase 5 as thin wrappers).
- `std/sync/scope.qz` line-22 doc comment ("legacy-primitive migration
  ... → thin wrappers") is stale — predates this memo's reframe. Update
  to note the two-axis model.
- `std/concurrency.qz` doc-comment header (lines 22-24) mentions "scope:
  All children must complete; child panic propagates to parent" as if it's
  the canonical primitive — reframe as "for the legacy wrapper API; the
  canonical entry point is `with scope_with(scope_with_cancel(current_scope()))
  do ... end`."

## Corrected sizing

| Bucket | Effort |
|---|---|
| 1 — thin wrappers + module-global deletion + spec verification | ~0.3 quartz-day |
| 2 — retain + document | 0 day (lifts into Phase 6 docs) |
| 3 — adjacent cleanup (lint + doc-comment) | ~0.1 quartz-day |
| **Total** | **~0.4 quartz-day** |

The original memo's "~1 quartz-day mostly mechanical" estimate inflated
because it lumped Bucket 2 deletion into the migration. With the reframe,
half the line items in the original Phase 5 are non-goals. Net shrink.

## Recommendation

1. **Ship Bucket 1 + Bucket 3 as Phase 5.** Wrappers + lint + doc-comments.
   No `cancel_token_*` deletion. No `go_cancellable` deletion.
2. **Lift Bucket 2 into Phase 6 docs.** The decision tree gets the second
   axis, and `docs/QUARTZ_REFERENCE.md`'s concurrency section gains a
   "Capability-style cancellation" subsection.
3. **Sequencing after Phase 5**: Phase 4e.8 (active-wake — see
   [`SCOPE_PHASE_4E_AWAIT_IO_DEFERRED.md`](SCOPE_PHASE_4E_AWAIT_IO_DEFERRED.md)),
   then Phase 6 (docs).

## Calibration note

The Phase 4e.6/4e.7 deferred-shape memo
([`SCOPE_PHASE_4E_AWAIT_IO_DEFERRED.md`](SCOPE_PHASE_4E_AWAIT_IO_DEFERRED.md))
already noted that "the chunked-poll-first recipe doesn't fit await /
io_suspend." The same pattern surfaces here: **the unification recipe
doesn't fit cancel tokens.** Some primitives are not redundant carriers
of a unified concept; they are genuinely independent, and the design pull
toward "unify everything" needs a counterweight in deliberation.

The B.7 memo's prior-art table (Go context.Context, Trio nurseries,
Kotlin coroutineScope, Tokio CancellationToken) shows the same pattern
in the canonical references: Tokio keeps `CancellationToken` as a
first-class type alongside its task scopes; Go's context.Context bundles
both behaviors into one type but exposes the cancel function as a
returned closure (`ctx, cancel := context.WithCancel(parent)`) — the
capability part of the API is preserved, just under a unified name.
Quartz's two-type split (Scope + CancelToken) is honest about the
underlying difference; collapsing them would be cosmetic, not structural.

## Open question — should `go_cancellable` accept either a Scope or a Token?

If the scope tree's "cancel via parent-cascade" and the token's "cancel
via passable flag" are both legitimate primitives, an obvious sugar would
be a `go_cancellable_with(f, cancel_source)` that takes either type via
a sum-type or trait. Deferred — wait for a real-user need to surface the
shape. Today the two patterns are clear enough that explicit
`go_cancellable(f, tok)` and `go fn()` (scope-inheriting) suffice.

---

Filed at start of B.7 Phase 5 deliberation, 2026-05-03. Next session:
ship Bucket 1 + Bucket 3 (~0.4 quartz-day), then Phase 4e.8, then Phase 6.
