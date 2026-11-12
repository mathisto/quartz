# Module-level `var X = f()` (non-constant initialiser) invisible inside generic-function bodies

> **Filed**: 2026-05-05 during TUI Phase 7 (SIGWINCH wiring).
> **Closed**: 2026-05-06 — REDIAGNOSED as the same bug as
> `GO_CALL_ARG_MODULE_VAR_QZ0403.md`. The non-const-init hypothesis here was
> a red herring; the actual cause was the resolver-rewrite pass having no
> case for NODE_GO. With const-init (`var _winch_handle = 0`) the bug still
> repro'd whenever the consuming driver imported the module under an alias,
> and with non-const-init it compiled cleanly when not aliased. See the
> closed entry on the sister doc for the fix.
> **Impact**: medium — any module-level `var` whose initialiser is a
> function call (instead of a literal) is unreachable from inside any
> generic-function body within the same module. Hits anyone wanting a
> module-level interned handle (atomic, channel, mutex, scope) used
> from generic helpers.

## Reproducer

```be
# in some_module.qz

var _handle = atomic_new(0)            # non-constant initialiser

def use_handle<M>(): Int                # generic
  return atomic_load(_handle)           # error[QZ0403]: Undefined variable: _handle
end
```

vs. the working shape:

```be
var _handle = 0                         # constant initialiser
def init(): Void
  if _handle == 0
    _handle = atomic_new(0)
  end
end

def use_handle<M>(): Int                # generic
  return atomic_load(_handle)           # ok
end
```

## What works

- Non-generic functions in the same module read the non-constant-init
  var fine.
- Generic functions read constant-init module vars fine
  (`_runtime_crashed = 0` at `std/tui/runtime.qz:402`, read from
  `program_run<S, M>` at line 465 — visible).

## What fails

- Generic-function bodies cannot resolve the name when the
  module-level var has a non-constant initialiser.
- The error is `QZ0403: Undefined variable: <name>`, not a type error.

## Hypothesised cause

The resolver builds a module-level name table during a pre-typecheck
pass that processes constant-initialiser `var` declarations into a
visible-names set. Generic-function typecheck happens against this
set. Non-constant-init vars are deferred to a later module-init
codegen phase that doesn't update the visible-names set in time for
generic resolution.

A grep over `tc_register_module_var` / equivalent should find the
exact pass that drops non-constant inits.

## Workaround

Lazy-initialise from a constant-init var:

```be
var _handle = 0
# ... at first use:
if _handle == 0
  _handle = atomic_new(0)
end
```

Used in `std/tui/runtime.qz` (`_winch_handle` for SIGWINCH atomic
flag).

## Sister bug

- `GO_CALL_ARG_MODULE_VAR_QZ0403.md` — `go fn(modvar)` reports the
  module-level var undefined when passed as an arg. Same module,
  different surface; possibly same root cause (resolver visibility
  table inconsistency).

## Confirmation steps

1. Add `var _x = some_func_call()` at module top.
2. Add `def reader<M>(): Int return _x end`.
3. Compile any consumer of `reader`. Expect QZ0403.
4. Replace with `var _x = 0` and observe success.
