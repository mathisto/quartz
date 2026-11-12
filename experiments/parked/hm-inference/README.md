# Parked: HM Type Inference v2 (Phase 3)

These files are an in-progress redesign of the Quartz type inference layer
using Hindley-Milner-style constraint generation and unification. They were
written between (~early March 2026) and (~April 9, 2026) as a "Phase 3" of
the type system work but were never wired into the main compiler pipeline.

The current self-hosted compiler uses the typecheck/typecheck_walk module
chain instead. These files are kept here for reference and as a starting
point if the HM-v2 design is ever picked up again.

## Files

- `types.qz` — type representation (9 KB)
- `infer.qz` — inference engine (56 KB)
- `hir.qz` — HIR desugaring (30 KB)

## Why parked

- Standalone, never integrated with the cross-module module system
- The header comments explicitly say "cross-module integration will be added
  when Quartz's module system supports it properly"
- Active typecheck module is in `self-hosted/middle/typecheck.qz` and works
- Integration would be a multi-day project; not currently the highest-impact
  thing to work on

## To revive

1. Audit the modules against the current type system (much has changed)
2. Wire them into the main pipeline as an alternate or replacement for
   `tc_*` functions in `typecheck.qz`
3. Run the QSpec suite to verify behavioral equivalence
4. Decide whether to deprecate the existing typecheck or run them in parallel
