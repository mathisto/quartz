# `go fn(modvar)` — module-level var passed as `go`-call arg fails name resolution

> **Filed**: 2026-05-05 during TUI Phase 7 (SIGWINCH wiring).
> **Closed**: 2026-05-06. Root cause: `resolve_rewrite_node` in `self-hosted/resolver.qz`
> had no dispatch case for `NODE_GO` (kind=85) or `NODE_ASYNC_CALL` (kind=84),
> so the prefix-rewrite pass never recursed into a `go fn(...)` arg list.
> When the consuming driver pulled the module in under an `import M as A`
> alias, `_modvar` was registered as `A$_modvar` while the bare ident inside
> the go-arg stayed `_modvar`. Lookup failed at typecheck. The "state-dependence"
> in the original filing was an artifact of `tui_help_spec.qz` not actually
> importing `std/tui/runtime` (so the bug never executed), while `tui_tabs_spec.qz`
> did. Fix added cases for NODE_GO + NODE_ASYNC_CALL plus precautionary cases
> for NODE_AWAIT, NODE_YIELD, NODE_TUPLE_LITERAL, NODE_WITH (all of which had
> the same kind of latent hole — none had user-visible repros today). Regression
> spec at `spec/qspec/resolver_go_arg_module_var_spec.qz` (3 tests). Workaround
> (`var winch = _winch_handle; go fn(winch)`) removed from `std/tui/runtime.qz`
> in the same commit. Sister doc `MODULE_VAR_NONCONST_INIT_INVISIBLE.md`
> rediagnosed as the same bug — non-const init was a red herring; the var-init
> form was irrelevant.
> **Impact**: medium — any goroutine spawn that wants to share a
> module-level handle (atomic flag, channel, scope) needs to bind to a
> local first. Adds one line of ceremony per spawn site.

## Reproducer

```be
# in some_module.qz
var _flag = 0

def worker(f: Int): Int
  return atomic_load(f)
end

def caller(): Int
  if _flag == 0
    _flag = atomic_new(0)
  end
  go worker(_flag)                     # error[QZ0403]: Undefined variable: _flag
  return 0
end
```

Despite `_flag` being trivially visible at the same lexical position
in the function body — the line above (`if _flag == 0`) reads it
without complaint — the moment it appears as an argument to a `go`
call, the resolver claims it's undefined.

## What works

- `var local = _flag; go worker(local)` — routing through a local.
- `_flag` referenced anywhere ELSE in the same function (assignment,
  comparison, ordinary call argument) — fine.
- `go worker(local_var)` — fine when `local_var` is a regular local.

## Hypothesised cause

The bug is **state-dependent** — same source compiles cleanly when
consumed via some import paths, fails QZ0403 via others. Specifically:

- `tui_help_spec.qz` (imports overlay, layout, help) — compiles fine
  *with* the direct `go _poll_resize(msg_ch, s, _winch_handle)` form.
- `tui_tabs_spec.qz` (imports tabs which uses runtime types) — fails
  QZ0403 on the same source.

Both go through the same NODE_GO walker and NODE_IDENT resolver. The
fact that one consumer compiles and another doesn't suggests:

1. Module-init ordering across the dep graph differs between consumers.
2. The resolver's `tc.scope.binding_names` table at the point where
   `_winch_handle` is looked up has different contents depending on
   what's been parsed first.
3. There may be a scope-set / hygiene-table interaction (the new
   `tc_scope_lookup_at` per Flatt POPL 2016) that produces the
   inconsistency.

A grep for `parse_go` / `tc_go_stmt` / `mir_lower_go` plus inspection
of `tc_scope_lookup_at` (`typecheck_util.qz:1549`) is where the
inconsistent scope walk likely lives. The `--no-cache` flag does NOT
fix this, so it's not a separate-compilation cache artifact.

The Phase 7 work confirmed the workaround (route through a local) is
deterministic across both compile paths.

## Workaround

Bind to a local before the `go` call:

```be
var arg = _flag
go worker(arg)
```

Used in `std/tui/runtime.qz` `program_run` for `_winch_handle` →
`_poll_resize` spawn.

## Sister bug

- `MODULE_VAR_NONCONST_INIT_INVISIBLE.md` — module-level vars with
  non-constant initialisers invisible to generic-function bodies.
  Different surface; possibly the same resolver-visibility-table
  inconsistency at the root.

## Confirmation steps

1. Add a module-level `var _x = 0`.
2. In a function, write `go worker(_x)`.
3. Expect QZ0403 on `_x`.
4. Replace with `var l = _x; go worker(l)` and observe success.
