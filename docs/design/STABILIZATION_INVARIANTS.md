# Stabilization Invariants

**Status:** OWNER-RATIFIED 2026-07-15

These decisions govern the stabilization program and supersede conflicting
pre-stabilization proposals. They are target semantics until implementation and
the normative reference agree. Quartz is unreleased; replace conflicting
behavior directly rather than adding compatibility layers.

## Product Priority

Correctness, safety, semantic coherence, reproducibility, and documentation truth
come before new language features, package management, ecosystem expansion,
secondary-backend promotion, performance marketing, or public marketing work.
Feature work remains frozen until the stabilization exit gate passes.

## Ratified Language Decisions

1. **Plain structs become value types by default.** Reference semantics must be
   explicit in the type declaration or type used. Representation annotations may
   optimize storage, but must not silently change aliasing semantics.
2. **Unchecked operations require an explicit `unsafe` boundary.** Raw pointers,
   unchecked memory access, unchecked indexing, representation casts, inline
   assembly, and equivalent escape hatches must be lexically reviewable. Safe
   Quartz must have a testable memory-safety claim.
3. **Conditions require `Bool`.** `if`, `elsif`, loops, guards, postfix
   conditions, comprehension filters, and boolean operators reject numeric,
   pointer, nil, collection, and other truthy/falsy coercions. Pattern tests and
   predicates produce `Bool` and continue to narrow types.
4. **Panic is non-recoverable.** `panic` is not sugar for `throw` and cannot be
   intercepted by `Throws`. Recoverable typed failure uses `Result<T, E>` or a
   declared `Throws` effect. The final design must state whether panic aborts
   immediately or performs narrowly defined emergency cleanup; it may not resume.
5. **Return-position `impl Trait` is opaque.** A function returns one hidden
   concrete type implementing the declared trait. Callers can use the trait
   interface but cannot rely on concrete fields or methods. Compilation remains
   static and monomorphized; opacity does not imply allocation or dynamic
   dispatch. Returning multiple concrete types requires an enum or a future
   explicit dynamic-trait facility.
6. **Breadth is frozen until stable.** Package management, marketing, new surface
   features, and promotion of secondary backends remain parked through the final
   stabilization audit.

## Representation Invariant

The goal is not to remove legitimate 64-bit machine integers. Quartz `Int`,
lengths, offsets, tags, and target ABI values may lower to `i64` where correct.
The goal is to remove **semantic existential erasure**:

- typed values transported as untyped `Int`;
- compiler handles indistinguishable from user integers;
- arbitrary effect, channel, task, closure, or module payloads transported as one
  undocumented machine word;
- type or layout information discarded and later reconstructed from names,
  ambient registries, unchecked casts, or side tables;
- ordinary compiler plumbing through `as_int`, `as_type`, or equivalent bridges;
- MIR values whose interpretation depends on an unstated convention.

Every surviving `Int`/`i64` use in a semantic transport path must be classified
as a user integer, target ABI scalar, typed opaque handle, compiler ID, raw unsafe
value, or defect. Typed opaque handles and compiler IDs must become distinct
compiler types rather than conventions encoded in `Int`.

## Stability Exit Gate

Quartz is not stable until all of the following are true:

- no known accepted-program silent miscompile;
- no known memory-safety failure reachable from safe Quartz;
- no high-level semantic value crosses an existential `i64` transport boundary;
- type layout is canonical, context-independent, and shared across modules and
  backends;
- the complete test matrix is reproducible with no unexplained failure, retry, or
  quarantine;
- self-host fixpoint and clean-clone bootstrap are reproducible;
- the public reference, architecture, examples, and README describe executable
  behavior;
- LLVM is explicitly authoritative and every other backend is accurately scoped;
- memory, unsafe, error/effect, and opaque-type semantics are implemented and
  normative.
