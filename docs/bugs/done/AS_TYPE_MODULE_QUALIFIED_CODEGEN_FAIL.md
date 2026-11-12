# AS_TYPE_MODULE_QUALIFIED_CODEGEN_FAIL

## Status

**CLOSED 2026-05-04.** Root cause was the parser, not codegen: the
typed-call type-arg parser at `parser.qz:3040` consumed only a single
IDENT, so `<m::T>` failed the typed-call shape entirely and the
expression re-parsed as `(callee < m::T) > (handle)`. The lowercase-LHS
alias-resolver at line 1895 then dropped `m`, leaving a bare PascalCase
`Widget` ident that reached codegen and tripped the QZ9501 fallback.

Fix: parser type-arg now consumes `IDENT (:: IDENT)+` and applies the
same alias-vs-module discrimination as `parser.qz:1895` —
`alias::Type` drops the alias (types live globally as bare names);
`module::Type` concatenates with `$` (module-mangled).

Regression spec: `spec/qspec/as_type_module_qualified_spec.qz`.

**Filed:** 2026-05-04 (TUI v0.3.2 step 6)
**Severity:** Medium — bounded internal compiler error (QZ9501), but blocks the documented workaround for `CONCRETE_GENERIC_AT_TYPE_ANNOTATION_REJECTED` when child widgets are imported under a module alias.
**Surface:** typecheck or codegen — the module-qualified type identifier reaches codegen unresolved.
**Trigger frequency:** Every parent widget that imports child widgets under a module alias and uses `as_type<alias::Type>(handle)` to recover from the `Int`-handle workaround.

## Symptom

`as_type<m::T>(val)` (with `m::T` a module-qualified type identifier
from an aliased import) reaches codegen with the qualifier still
attached, but the resolver only registered the unprefixed `T`. The
compiler bails with QZ9501 "internal compiler error: identifier 'T'
reached codegen unresolved":

```
[QZ9501] internal compiler error: identifier 'Widget' reached codegen unresolved at :9:30
  PascalCase identifiers in expression position must resolve to
  a function, global, or enum variant. This is a resolver hole.
  Please file an issue with a minimal reproducer.
```

The same call with the unqualified `as_type<T>(val)` form works (see
`examples/tui/widgets/save_screen/main.qz:85,109,130` which uses
`as_type<TextInput>(...)` after `import std/tui/widgets/text_input as ti`).

## Repro

```qz
# wlib/widget.qz
struct Widget
  v: Int
end

def widget_new(): Widget = Widget { v: 42 }
```

```qz
# main.qz
import wlib/widget as w

def main(): Int
  var handle: Int = as_int(w::widget_new())
  var t: w::Widget = as_type<w::Widget>(handle)        # codegen-fails with QZ9501
  puts(t.v.to_s())
  return 0
end
```

## Observed

Diagnostic at runtime of the compiler:
```
[QZ9501] internal compiler error: identifier 'Widget' reached codegen unresolved at :9:30
```

The error is emitted by codegen's PascalCase-identifier-in-expression-position
fallback path (probably `cg_emit_expr` or sibling for NODE_IDENT), which
is the right place to error if the resolver should have populated this —
but the resolver dropped the module qualifier when registering the
struct, so the codegen can never find it.

## Expected

`as_type<w::Widget>(handle)` should be equivalent to `as_type<Widget>(handle)`
after module-qualifier stripping in typecheck (since both refer to the
same struct). At minimum, the diagnostic should be a typecheck error
("module-qualified type identifier in `as_type` argument not yet
supported; use unqualified form") rather than a QZ9501 ICE.

## Hypothesis

Two possible locations:

1. **Typecheck side**: `as_type` argument elaboration is special-cased
   in `typecheck_walk.qz` around line 2378 ("# Check for as_type<T>(val)
   — the type_arg IS the struct name"). The handler probably reads the
   raw identifier text without normalizing module-qualified `m::T` to
   the canonical short name. Fix here: strip `m::` prefix before
   looking up the struct.

2. **Codegen side**: the PascalCase-identifier resolver doesn't try
   the unqualified form when the qualified form fails. Fix here: add
   a `::` strip + retry path before emitting QZ9501.

The typecheck-side fix is probably correct; codegen shouldn't have to
know about module aliases.

## Workaround

Drop the `m::` prefix:

```qz
import std/tui/widgets/text_input as ti
# ... import brings TextInput into scope unqualified.
var t: TextInput = as_type<TextInput>(handle)        # works
```

Documented in `examples/tui/widgets/save_screen/main.qz` and Q11 of the
TUI v0.3.2 design memo.

## Risk if unfixed

Every parent widget that imports children under aliases needs to spell
out the unqualified type at every `as_type` call site, breaking the
otherwise-clean `m::Type` discipline that the alias was supposed to
preserve. Cosmetic but high-frequency, and the QZ9501 ICE message
("Please file an issue") suggests the compiler thinks this is a hole;
the fix should be small.

## Related

- `CONCRETE_GENERIC_AT_TYPE_ANNOTATION_REJECTED.md` — the underlying
  reason `as_type<T>(handle)` is needed in the first place (typed
  child fields rejected, fall back to `Int` handles).
- `PATTERN_PARSER_REJECTS_QUALIFIED_VARIANT.md` — sister bug on the
  pattern-side asymmetry (qualified `Type::Variant` rejected in nested
  patterns).
