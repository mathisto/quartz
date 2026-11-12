# QZ0200_DIAG_FORMATS_STRUCT_PTYPES_AS_UNKNOWN

## Status

**CLOSED 2026-05-06.** Filed 2026-05-04 alongside the close of
`done/CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED.md`.

### Resolution

Two-part fix:

1. **Stamp the outer struct name on user-defined struct ptypes.**
   `tc_parse_type` at the user-struct branch (`typecheck.qz:1637`) now
   calls `tc_ptype_set_name(ptype_id, base_name)` after creating the
   ptype — analogous to the existing `tc_synth_stream_ptype` precedent
   that also stores its struct identity in `ptype_name`.

2. **Render the cached struct name in `tc_type_name_full`.**
   For TYPE_STRUCT ptypes with a non-empty `ptype_name`, the formatter
   now produces `Box<Inner>` instead of `Struct<unknown>`. For TYPE_ENUM
   ptypes, a best-effort `Enum<Inner>` is rendered using the existing
   `ptype_name` slot (which by long-standing convention stores the inner
   element name on enum ptypes — a deeper fix to encode the outer enum
   name is left as a follow-up since it would touch match-arm name
   resolution).

3. **Switched diagnostic emit sites from `tc_type_name` →
   `tc_type_name_full`** at the QZ0200 paths the bug doc names:
   field-init (`typecheck_generics.qz:932`), let-bind / assignment /
   return (`typecheck_helpers.qz:281,313,340`), assignment-walk
   (`typecheck_walk.qz:3151`), lambda-return-type
   (`typecheck_expr_handlers.qz:3325`), QZ1407 protocol mismatch
   (`typecheck_expr_handlers.qz:3908`).

### Regression spec

`spec/qspec/qz0200_struct_diagnostic_spec.qz` (3 cases). Verified:
golden binary fails 3/3, rebuilt binary passes 3/3.

### Follow-ups

- TYPE_ENUM ptypes still render as `Enum<InnerName>` because the
  ptype_name slot stores the inner element name (see
  `typecheck.qz:1646-1652` comment). The outer enum identity isn't
  stored anywhere on the ptype today; encoding it would either repurpose
  the ptype_name slot (breaking `mx_resolve_enum_name` consumers) or
  require a parallel ptype field. File as separate enhancement if
  enum-side QZ0200 surfaces become a problem.
- Several QZ0200 paths still call `tc_type_name` directly — but only
  the narrow primitive-mismatch ones (e.g.
  `typecheck_expr_handlers.qz:237/241`,
  `typecheck_walk.qz:3462/3466`). Those render INT/STRING/BOOL only and
  aren't affected by the bug. Left untouched to keep this change small.

## Symptom

QZ0200 mismatches that involve `TYPE_STRUCT`-shaped ptypes (or generic
instantiations of them) format both sides as the literal string
`unknown`, producing diagnostics like:

```
error[QZ0200]: Field ring: expected unknown, got unknown
error[QZ0200]: Return type mismatch: expected unknown but got unknown
```

The user has no way to tell from the message what the two types
actually are, what the struct name is, or which side has the wrong
type-arg. They can only see that *something* didn't match.

## Severity

Medium-low. Doesn't block any code from compiling or running — the
typecheck is still correct. But the diagnostic is actively misleading:
"expected unknown, got unknown" reads like the typecheck has *no
information* about either side, when in fact it has full information
about both and is just failing to render them.

## Cause

The diagnostic formatter for type names handles primitive `TYPE_INT`,
`TYPE_STRING`, `TYPE_BOOL`, etc., and renders the literal name, but
falls back to the string `"unknown"` for `TYPE_STRUCT` ptypes (and
likely `TYPE_ENUM`, `TYPE_TUPLE`, others). The struct-name lookup
exists (used elsewhere — e.g. struct-field-access errors print the
struct name correctly) but isn't wired into the QZ0200
field-init / return-type / var-annotation mismatch paths.

When BOTH sides of a mismatch are struct ptypes (the common case for
generic-instantiation mismatches), both render as `unknown`,
producing the "expected unknown, got unknown" tautology.

## Repro

Pre the close of `CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED`, the
following file produced the canonical bad-message:

```qz
import std/tui/widgets/focus as fr

enum FocusId
  A
  B
end

struct M
  ring: fr::FocusRing<FocusId>
end

def main(): Int
  var ids = vec_new()
  vec_push(ids, FocusId::A)
  var ring = fr::focus_ring_with_initial(ids, FocusId::A)
  var m = M { ring: ring }       # ← QZ0200: expected unknown, got unknown
  return 0
end
```

That specific repro now compiles, but any future QZ0200 between two
struct-shaped ptypes will produce the same useless message.

## Fix shape

Update the QZ0200 formatter to, for `TYPE_STRUCT` and similar
container-kind ptypes:

1. Look up the struct name from the ptype's outer `arg1`.
2. Recursively format any inner type args (`arg2`).
3. Print as `StructName<InnerType, ...>`.

`TYPE_ERROR` inner args (the dominant pre-fix case) should print as a
distinguished marker (e.g. `<unresolved>`) rather than the same
`"unknown"` string the outer fallback uses, so a reader can tell which
side carries the unresolved type-param.

Likely location: search for the diagnostic emit site that formats both
sides of QZ0200 and the helper(s) that format a single TypeId.

## Related

- `done/CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED.md` — closed; the
  bug whose user-visible artifact was the canonical bad-message
  example. The fix removes the mismatch in the inference-only path,
  but the formatter itself is unchanged.
- `done/CONCRETE_GENERIC_AT_TYPE_ANNOTATION_REJECTED.md` — closed; same
  family of bad-message at the explicit-args path.
