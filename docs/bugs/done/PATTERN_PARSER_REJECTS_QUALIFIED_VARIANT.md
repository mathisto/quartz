# PATTERN_PARSER_REJECTS_QUALIFIED_VARIANT

## Status

**Sub-bug (a) CLOSED 2026-05-04** (commit `8235b4d3`). Pattern parser
consumes `IDENT (:: IDENT)+ (...)?` inside a constructor's argument
list via the `_ps_parse_pattern_arg_binding` helper.

**Sub-bug (b) CLOSED 2026-05-06.** True variant-discriminator dispatch
on nested constructor patterns (`Some(Focus::SaveList)`) now flows end
to end. Three changes:

1. **Parser** (`self-hosted/frontend/parser.qz:5159`): renamed helper
   to `_ps_parse_pattern_arg(ps, bound_names, sub_pats)` taking parallel
   out-parameter Vecs. For each constructor-pattern arg slot, the helper
   pushes the immediate binding name into `bound_names` ("_" for non-
   bindings) AND a sub-pattern AST node into `sub_pats` — `NODE_ENUM_ACCESS`
   for nested constructor patterns, `NODE_IDENT` for bindings, `NODE_WILDCARD`
   for `_`. Both Vecs travel together: `bound_names` drives the binder
   path; `sub_pats` drives Maranget + codegen recursion. Stored via
   `ast_enum_access(s, name, variant_name, bound_names, as_int(sub_pats), ...)`.

2. **Maranget** (`self-hosted/middle/typecheck_match.qz`):
   - `mx_pat_from_ast` for NODE_ENUM_ACCESS recurses on each
     NODE_ENUM_ACCESS sub-pat to produce a discriminating
     `mx_pat_variant`, so distinct inner variants register as distinct
     constructors. NODE_IDENT and NODE_WILDCARD sub-pats stay as
     wildcards (binding only).
   - `mx_is_useful` and `mx_find_witness` recover `col_enum_name` by
     scanning the registry for an enum that holds the seen variant
     names when col_enum_name was empty — required because col_type
     defaulted to TYPE_INT for sub-pats and the existing
     `col_type != subject_type → col_enum_name = ""` reset killed
     enum-aware completeness for the recursive specialization.

3. **Codegen**
   (`self-hosted/backend/mir_lower_expr_handlers.qz:3613` and
   `self-hosted/backend/mir_lower_stmt_handlers.qz:1677` +
   `mir_lower_if_pattern` at line 518): for each NODE_ENUM_ACCESS
   sub-pat at payload position `i`, emit a tag-equality check on
   `load_offset(subject_val, i+1)` (the inner enum value), AND-ed
   into the outer `cmp_val`. This generates one extra `icmp eq` +
   `and i64` per nested pattern dimension. NODE_IDENT and NODE_WILDCARD
   sub-pats are no-ops at the dispatch level (binding still flows
   through `bound_names`).

Regression specs:
- `spec/qspec/pattern_qualified_variant_in_args_spec.qz` (sub-bug a)
- `spec/qspec/nested_qualified_variant_pattern_spec.qz` (sub-bug b —
  statement-context, expression-context, and mixed
  qualified-and-wildcard arms)

**Filed:** 2026-05-04 (TUI v0.3.2 step 6)
**Severity:** Medium — surface friction; combined with sub-bug (b) below, can mask dispatch errors silently.
**Surface:** parser (pattern-arm parsing); typecheck (pattern resolver) for sub-bug (b).
**Trigger frequency:** Every match arm on a nested constructor `Some(Type::Variant)` or similar.

## Symptom

Two related-but-distinct sub-bugs around qualified variants in pattern
position:

### (a) Parser rejects `Type::Variant` inside nested constructor patterns

```
match f                              # f: Option<Focus>
  Some(Focus::NameInput) => ...      # parser error at `::`: "Expected ')'"
  Some(NameInput)        => ...      # parses, but see (b)
end
```

The parser accepts qualified-variant patterns at the *top* of a match
arm (`Focus::NameInput =>`) but not nested inside another constructor
(`Some(Focus::NameInput) =>`).

### (b) Bare PascalCase identifier in nested pattern is treated as a binding pattern, not a variant discriminator

```
match f                              # f: Option<Focus>
  Some(NameInput) => ...             # NameInput is a BINDING (always matches)
  Some(SaveList)  => ...             # unreachable (Maranget warns QZ0108)
  None            => ...
end
```

When pattern (a) is worked around by dropping the qualifier, the
typecheck/match-resolver treats the bare PascalCase identifier as a
fresh binding name (a wildcard that captures the value into the local
`NameInput`) rather than as a variant discriminator. The Maranget
exhaustiveness pass correctly flags subsequent arms as unreachable
(QZ0108), but the result is a match that *always* takes the first arm
regardless of the actual variant — a silent dispatch-correctness bug
if the user assumed (b) was working.

This was confirmed in `examples/tui/widgets/save_screen/main.qz:84-129`:
the file declares two arms `Some(NameInput) => ...` and
`Some(SaveList) => ...` but only the first is ever entered. (Per the
v0.3.2 step 6 commit message, dispatch was assumed to be correct via
`focus_ring_is_focused(s.focus, SaveFocus::NameInput)` calls in the
*view*, not via the match — so the user-visible behaviour appeared
correct even though the match arms were degenerate.)

## Repro for (a) — Parser rejection

```qz
enum Focus
  NameInput
  SaveList
end

def main(): Int
  var f: Option<Focus> = Some(Focus::NameInput)
  match f
    Some(Focus::NameInput) => puts("name")    # parser error
    Some(Focus::SaveList)  => puts("save")
    None                   => puts("none")
  end
  return 0
end
```

Diagnostic:
```
error[QZ0101]: Expected ')'
  --> 9:15
9 |     Some(Focus::NameInput) => puts("name")
  |               ^
```

## Repro for (b) — Silent dispatch failure

```qz
enum Focus
  NameInput
  SaveList
end

def show(f: Focus): Void
  match f
    NameInput => puts("name")
    SaveList  => puts("save")
  end
end

def main(): Int
  show(Focus::NameInput)        # prints "name" — correct
  show(Focus::SaveList)         # prints "name" — WRONG; should print "save"
  return 0
end
```

(Note: this top-level match form may not exhibit (b) — the bug is
specifically when the qualified pattern appears *nested in another
constructor*. The save_screen scenario is `Some(NameInput)` inside
`Option<Focus>`. A complete repro of the silent-dispatch case is in
`/tmp/qz-bugbash/13_unqual_baseline.qz`'s nested-Some form, which the
Maranget pass correctly flags QZ0108 — verify with `--no-cache`.)

## Observed

- Direct-match qualified pattern `match f { Type::Variant => ... }`
  works at the top of arms.
- Nested-match qualified pattern `match f { Some(Type::Variant) => ... }`
  is parser-rejected.
- Nested-match unqualified pattern `match f { Some(Variant) => ... }`
  binds `Variant` as a fresh local name; subsequent arms are flagged
  QZ0108 unreachable.

## Expected

`Some(Type::Variant)` should parse; the typecheck pattern resolver
should treat bare PascalCase identifiers in nested patterns as variant
discriminators (resolved against the inner enum's variant table) when
the inner enum is determinable from context, and as fresh bindings
otherwise.

## Hypothesis

### (a)

The pattern parser handler for nested constructor patterns reuses the
*expression* parser for argument positions, but expression parsing
expects `Type::Variant` to be resolvable as a value (which it is — it's
a constructor call), and the pattern-side `::` is being misread by the
expression-parse fallthrough as a malformed expression. Likely fix:
change the nested-pattern argument parser to invoke the pattern parser
recursively, not the expression parser.

### (b)

The pattern resolver in `typecheck_match.qz` checks bare identifiers
against the *outer* match scrutinee's enum-variant set, but doesn't
recurse into the inner constructor's payload type to look up variant
names there. When the outer is `Option<Focus>` and the inner is
`Some(NameInput)`, the resolver checks `NameInput` against `Option`'s
variants (Some/None), doesn't find it, and falls back to "fresh
binding."

## Workaround

For (a): drop the qualifier — `Some(NameInput)` instead of
`Some(SaveFocus::NameInput)`. Then per (b), accept that the dispatch is
degenerate and rely on out-of-band checks (e.g. `focus_ring_is_focused`
in the view).

OR: nest match expressions — outer match dispatches `Some(x)` /
`None`, inner match dispatches `x` against variants of the payload
type.

## Discoverability

- `examples/tui/widgets/save_screen/main.qz:84-129` — uses bare
  `Some(NameInput)` form; relies on out-of-band dispatch.
- v0.3.2 step 6 commit message lists this as one of the friction
  surfaces.
- Q7 of the TUI v0.3.2 design memo mentions the unqualified-only
  constraint without explaining the nested-binding asymmetry.

## Risk if unfixed

Sub-bug (a) is a parser surface friction. Sub-bug (b) is a silent
dispatch-correctness hazard — code that *looks* like a match-on-variant
is actually a match-on-anything-and-bind. Deckbuilder code that
dispatches via `match Some(focus_id)` is at risk of subtle "all arms
equivalent" bugs.

## Related

- `done/AS_TYPE_MODULE_QUALIFIED_CODEGEN_FAIL.md` — sister asymmetry on
  module qualifiers (`m::Type` in `as_type` arg); CLOSED 2026-05-04.
- `feedback_quartz_module_quirks.md` (memory) — `Vec<T>` element type
  loss with silent wrong-struct field resolution; same family of
  silent-resolver-fallback bugs.
