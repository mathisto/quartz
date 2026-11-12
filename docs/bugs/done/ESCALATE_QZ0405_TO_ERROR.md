# ESCALATE_QZ0405_TO_ERROR

**Filed:** 2026-06-01 (follow-up to IMPORT_STAR_COLLISION_SILENT_SHADOW)
**Severity:** Low — polish. The silent-miscompile class is already closed.
**Status:** FIXED 2026-07-07 (commit 073d1fa6).

## Resolution

`mir_warn_ambiguous_import` renamed to `mir_error_ambiguous_import` and routed
through `diagnostic::diag_emit(DIAG_ERROR)` (QZ0405) with a fix-it note
(qualified import / `as` rename). The error increments the driver's error
count so compilation fails at the post-MIR gate (`quartz.qz` —
`if diag_error_count() > 0 return ""`). Verified inert: full `--no-cache`
self-compile emits zero QZ0405, guard fixpoint byte-identical (3296 fns).
Regression arm in `spec/qspec/import_star_collision_spec.qz` now asserts the
ambiguous consumer FAILS to compile (exit != 0) — 3/3 green.

## Context

`IMPORT_STAR_COLLISION_SILENT_SHADOW` (closed 2026-06-01) introduced **QZ0405**
as a *warning* on a genuinely-ambiguous bare call from outside all candidate
modules (two+ wildcard imports define the same name). It was shipped as a
warning rather than a hard error to guarantee no false-positive build break
while the change landed.

## Evidence that escalation is safe

The full double self-compile (fixpoint, 2598 functions — entire compiler +
stdlib) emits **zero** QZ0405. The codebase is collision-free under the
diagnostic, so promoting QZ0405 to a hard parse/lower error would not break any
current build.

## Proposed change

In `mir_warn_ambiguous_import` (`self-hosted/backend/mir.qz`), route through the
error path instead of `eputs("warning[...]")`, so an ambiguous bare call fails
compilation with a fix-it (qualified import / `as` rename). The bug doc's
original Path A wanted this; the only reason it isn't already an error is the
land-safely-first sequencing.

## Pull-in trigger

Do this opportunistically alongside the next resolver/diagnostics pass, or when
a real consumer hits QZ0405 and would prefer a hard stop. Add a regression arm
to `spec/qspec/import_star_collision_spec.qz` asserting the ambiguous-consumer
source now fails to compile (exit != 0) once escalated.
