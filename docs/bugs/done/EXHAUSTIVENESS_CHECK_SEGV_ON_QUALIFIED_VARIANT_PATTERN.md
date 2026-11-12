# EXHAUSTIVENESS_CHECK_SEGV_ON_QUALIFIED_VARIANT_PATTERN

## Status

**CLOSED 2026-05-06.** Root cause was unrelated to qualified-variant
patterns — the qualifier was incidental. The actual trigger is a
tuple-destructured enum identifier used as a `match` subject. Two
callsites in `typecheck_walk.qz` (NODE_LET_DESTRUCTURE arms, lines 2971
and 2977) called `tc_scope_bind` with only 4 of 5 args. The omitted
5th arg (struct_name) left `binding_struct_names[i]` holding
uninitialized memory; later, `mx_resolve_enum_name` reads that slot
via `tc_scope_lookup_struct_name` and feeds it to `str_byte_len` →
SIGSEGV. Bare-variant arms crashed too (verified). Fix: pass `""`
as the 5th arg at both callsites. Regression spec at
`spec/qspec/qualified_variant_no_arg_pattern_spec.qz`.

Filed 2026-05-04 during TUI v0.3.3 step 6 (Form update).

## Symptom

A `match` arm with a fully-qualified `module::Type::Variant` pattern
where `Type` is the same as the scrutinee's type (i.e. the qualifier
is redundant because the scrutinee already constrains the variant
namespace) crashes the compiler at exhaustiveness-check time.

Trigger:

```qz
match ev                          # ev: ti::TextInputEvent
  ti::TextInputEvent::Changed =>  # qualified pattern → SIGSEGV
    ...
  _ => ...
end
```

Workaround used in form.qz:

```qz
if ev is Changed                  # is keyword + bare variant name
  ...
end
```

Bare-variant pattern (`Changed => ...`) probably also works but wasn't
tried — the `is` form was the first thing reached for and it compiled.

## Crash trace

From `~/Library/Logs/DiagnosticReports/quartz-2026-05-04-204313.ips`:

```
qz_str_get_len                                  imageOffset 2788
typecheck_match$mx_resolve_enum_name            imageOffset 11344216 +372
typecheck_match$tc_check_exhaustiveness         imageOffset 11428104 +252
typecheck_expr_handlers$tc_expr_match           imageOffset 11549184 +40244
typecheck_walk$tc_expr                          imageOffset 11973148 +26404
typecheck_walk$tc_stmt                          imageOffset 12224880 +163668
```

Data abort, byte read translation fault. Strongly suggests
`mx_resolve_enum_name` is calling `qz_str_get_len` on a NULL or unmapped
pointer — likely the variant-pattern's qualified name string is in a
state the resolver doesn't expect.

## Hypothesis

The closed bug `done/PATTERN_PARSER_REJECTS_QUALIFIED_VARIANT.md`
(commit `8235b4d3`) accepted `IDENT(::IDENT)+` as a pattern — sub-bug
(a) — by degrading to a wildcard `_` for binding purposes. Sub-bug (b)
— actual variant-discriminator dispatch — was left open with the
note "nested patterns are treated identically to the unqualified
workaround."

The exhaustiveness checker is downstream of the parser. If the parser
stores a qualified-variant pattern with a non-canonical name string
(e.g. an empty/null string from the wildcard-degradation path, or a
raw `module::Type::Variant` string the resolver isn't prepared to
look up), `mx_resolve_enum_name` would crash trying to resolve it.

The list.qz uses `tui::FrameMsg::Key(k)` as a match arm and works —
that's `module::Type::Variant(binding)` with a constructor arg. The
arg may keep the resolver on a different code path.

The form.qz site that crashed was `ti::TextInputEvent::Changed` — a
**no-arg** qualified variant. That's the differentiating shape.

## Repro (minimal — not actually run, hypothesised)

```qz
import std/tui/widgets/text_input as ti

def f(ev: ti::TextInputEvent): Int
  match ev
    ti::TextInputEvent::Changed => return 1
    _                            => return 0
  end
end
```

If this repros standalone, the bug is "qualified no-arg variant
pattern" specifically. If it doesn't, there's an additional trigger
condition (cross-module visibility, generic context, etc.) worth
narrowing.

## Severity

Medium — the workaround (`is Variant` predicate or bare variant name)
is short and cheap. But the symptom is a compiler SIGSEGV with no
diagnostic. v0.3.3 spec authors will hit it; future stdlib widgets
probably will too.

## Discoverability

- v0.3.3 step 6 commit message will note the workaround inline.
- This doc.

## Risk if unfixed

Form composer's update routing matches on inner widget events; the
qualified-pattern shape is the natural one to write. Future Form
extensions (Select / Confirm field types via tagged enum) will multiply
the matches. Each one risks a SIGSEGV without diagnostic.

## Related

- `done/PATTERN_PARSER_REJECTS_QUALIFIED_VARIANT.md` — closed parser
  fix; this is the runtime/typecheck-time follow-up that wasn't
  caught by sub-bug (a)'s coverage.
- `feedback_quartz_module_quirks.md` — same family of cross-module
  resolution friction.
