# Bug: block-body implicit return-type inference defaults to Void (originally filed as `can` row regression — diagnosis was wrong)

**Status**: REFRAMED 2026-04-29 — the `can` clause is NOT the trigger; it's a general design limitation. Closing as "by design" with workaround documented.
**Discovered**: 2026-04-22 during Piezo Phase 2 P2.b (Reader<R>) work
**Severity**: cosmetic — adding explicit return type fixes it
**Filed by**: Piezo P2.b session

## Resolution (2026-04-29)

Verified: removing the `can Log` clause entirely produces the **same** QZ0401 error. The trigger is not `can`; it's that block-body `def f() ... 42 end` with no `: T` annotation defaults to `TYPE_VOID` at `self-hosted/middle/typecheck.qz:4542`. Endless-def form `def f() = 42` infers correctly. **This is a general limitation of block-body return-type inference, not a `can`-row regression.**

The convention going forward (already followed in stdlib): always annotate return types on block-body functions. Endless-def form (`def f() = expr`) infers from the RHS.

If implicit block-body return inference becomes a feature request, it would be a non-trivial change touching `tc_register_function_signature_named` plus a body-walk that re-stamps `return_type` when initially `TYPE_VOID`. Not load-bearing — close.

---

(Original report below preserved for context.)

## Repro

```quartz
import std/log

def emit_msg() can Log
  log::info("hi")
  42
end

def main(): Int can Log
  var r = emit_msg()
  puts(r.to_s())
  return 0
end
```

Error:

```
error[QZ0401]: Undefined function: to_s
  --> ...:10:16
10 |   puts(r.to_s())
```

`r` is typechecked as `Void` (or an error), so the UFCS `.to_s()` lookup
fails. Pre-existing — reproduces on `self-hosted/bin/backups/quartz-pre-p2-golden`
with the same input (Log effect only, not State/Reader which are new in P2).

## Workaround

Add an explicit return type annotation:

```quartz
def emit_msg(): Int can Log      # ← explicit `: Int`
  log::info("hi")
  42
end
```

With the explicit type, `r` infers correctly and `r.to_s()` resolves.

## Suspected cause

When the parser + typechecker process a function definition, the presence
of `can <Row>` in the signature appears to short-circuit the normal
"last-expression-of-body is the implicit return" type inference. The
function ends up with `TYPE_VOID` return type in the registry, and
callers propagate that.

## Scope

Affects ALL pre-Piezo effects (Log, Throws, Async, Diag) — not introduced
by P2.a/P2.b. Manifest more often in P2 code because State<S>/Reader<R>
users naturally write small helpers like `def ask_val() can Reader = ask()`
where the explicit return type feels redundant.

Not blocking for P2.b: stdlib `std/reader::local` ships with `: Int can
Reader` explicit, and specs add explicit return types to helpers. Callers
of P2 effects should follow the same convention until this is fixed.

## Fix sketch (for later session)

Likely lives in `self-hosted/middle/typecheck_walk.qz::tc_register_function`
or wherever `tc_fn_return_type_from_body` / equivalent is called. Trace:
(1) parse produces function AST with `can` row attached + empty return
annotation. (2) typecheck registers the function and computes return type
from body. (3) somewhere in that computation, presence of the `can` row
causes an early-return-with-Void. Walk the pre-existing path for a
can-row-less function with implicit return, compare against the can-row
path, find the divergence.

## Tier / priority

Tier 3 ("useful to fix but not blocking"). Filed as standalone bug rather
than adding to EFFECTS_IMPLEMENTATION_PLAN — this is pre-existing, not a
Piezo deliverable.
