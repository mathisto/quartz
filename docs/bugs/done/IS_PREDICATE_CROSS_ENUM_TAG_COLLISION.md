# `is X` predicate collides across enums with identical-tag variants

**Filed:** 2026-05-06 (TUI Phase 10 alternate / deckbuilder replay specs)
**Severity:** Medium — silent correctness bug; works correctly when consumed enums lack same-named variants.
**Sister bug:** `is_none_non_option_segfault` (memory feedback) — same axis, opposite manifestation (SEGV vs. silent false-true).

## Summary

The `is Variant` predicate dispatches by **variant tag value** without
checking that the operand's static type actually carries that variant.
When two enums in scope have a same-named variant at *different* tag
positions, `is` against the *wrong* enum's variant matches whenever
the operand's actual variant happens to share the tag value of the
named variant in the *other* enum.

Discovered when `program_replay` (`std/tui/runtime.qz`) terminated the
replay loop after one message, regardless of input. Root cause:

```be
var cmd: Cmd<M> = pair.1
if cmd is Quit   # intended: check Cmd::Quit (tag 1)
  done = 1
end
```

`Cmd<M>`'s variant order:
```
None=0  Quit=1  Batch=2  Run=3  After=4  Every=5
```

`FrameMsg<M>`'s variant order (also in scope, same module):
```
Key=0  Resize=1  Tick=2  App=3  Quit=4
```

The bare `is Quit` resolved to `FrameMsg::Quit`'s tag (4) — and
**`Cmd::After` is also at tag 4**. Replay loops returning a
`Cmd::After(_, _)` (which the deckbuilder does for toast lifecycle)
were treated as `is Quit == true` and the loop terminated.

## Reproducer

```be
import std/tui/runtime as tui

def main(): Int
  var ev: tui::KeyEvent = tui::KeyEvent { code: 0, modifiers: 0 }
  var fm: tui::FrameMsg<Int> = tui::FrameMsg::Key(ev)
  # No-op thunk just to construct After:
  var thunk: Fn(): tui::FrameMsg<Int> = -> tui::FrameMsg::Quit
  var cmd: tui::Cmd<Int> = tui::Cmd::After(100, thunk)

  if cmd is Quit
    puts("BUG: After matched as Quit (FrameMsg::Quit's tag = Cmd::After's tag = 4)")
  end
  return 0
end
```

Prints "BUG: ...".

## Workaround

Use explicit `match` arms with the fully-qualified variant. The
fix landed at the use site in `program_replay`:

```be
match cmd
  Cmd::Quit => done = 1
  _ => done = done   # no-op (empty arm body types as Int per existing quirk)
end
```

## Root cause (hypothesis)

`is X` lowers to a tag-equality check against the lexically-resolved
constant `X`. The resolver picks the first `Quit` it finds in scope —
in this case `FrameMsg::Quit` (declared first in `runtime.qz`). The
predicate body just compares `tag(cmd) == tag(FrameMsg::Quit)` =
`tag(cmd) == 4`. No type-level guard that the variant `X` actually
belongs to the enum of the operand's type.

## Real fix (compiler change)

`is X` should require `X` to be a variant of the operand's static
enum type. If the resolver finds a same-named variant in a different
enum, that's a type error, not a silent wrong-enum dispatch. Could be
implemented at typecheck time:

1. When typing `expr is Name`, compute `type(expr)` (must be an enum
   type after generic erasure resolves).
2. Look up `Name` in that enum's variant table. If absent, error
   ("`Name` is not a variant of `<enum>`"). Suggest the qualified form
   if `Name` exists in another enum in scope.
3. Lower with the variant tag value from the enum's own table.

The `is_none_non_option_segfault` quirk is the same axis with
different damage — there `Some/None` from `Option` was matched against
a user enum that had a `None` variant at a different tag, causing a
SEGV during payload extraction. Both fall out the moment the predicate
becomes type-aware.

## Status

- **Closed 2026-05-06**. Sister bug `is_none_non_option_segfault`
  (memory feedback) closed by the same fix.

## Resolution

Two-layer fix:

1. **Typecheck** (`self-hosted/middle/typecheck_walk.qz` NODE_IS_CHECK
   branch + let-handler addition near `tc_scope_bind_full_with_display`):
   when the subject is a NODE_IDENT whose binding carries an enum
   identity (struct_name on generic-enum bindings, type_ann fallback on
   bare-enum bindings now captured by the let-handler), look up the
   enum and verify the named variant lives in it. Mismatches emit
   **QZ0231** with a suggestion to use `match` for cross-enum dispatch.

2. **MIR-lower** (`self-hosted/backend/mir.qz` `mir_resolve_is_enum`):
   all three NODE_IS_CHECK lowering sites (`mir_lower.qz` expression +
   is-with-bindings, plus `mir_lower_stmt_handlers.qz` is-with-bindings
   statement) now resolve the enum from the subject's static type via
   `mir_infer_expr_type` + `mir_resolve_enum_name`, falling back to the
   legacy global variant search only when the subject's type is unknown
   (Int-erased generics, untyped params).

Regression spec at `spec/qspec/is_predicate_cross_enum_spec.qz` covers
both surfaces (A: `is None` on user enum; B: cross-enum same-named
variant tag collision) plus the QZ0231 typecheck path.

The `program_replay` workaround in `std/tui/runtime.qz` was reverted
to use `is Quit` directly, since `cmd: Cmd<M>` and `msg: FrameMsg<M>`
both carry their enum identity into the typecheck/MIR-lower paths.
