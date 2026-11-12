# Quartz Stabilization Program

**Created:** 2026-07-15
**Status:** ACTIVE - feature freeze
**Governing decisions:** `docs/design/STABILIZATION_INVARIANTS.md`
**Initial evidence register:**
`docs/research/TRUTH_AND_ARCHITECTURE_AUDIT_2026-07-15.md`

## Mission

Take Quartz from a broad, impressive alpha with known representation and
correctness holes to a coherent, reproducible systems language whose safety and
behavioral claims are supported by tests and current documentation. This program
is the source of truth for stabilization sequencing. Historical roadmaps and
conductor ledgers remain evidence, not current priority instructions.

## Operating Rules

1. Correctness and safety outrank breadth, performance, ecosystem, and marketing.
2. Fix systemic causes before local symptoms.
3. Parallelize read-only audits; serialize shared compiler and runtime changes.
4. Every behavior change gets a focused regression, full-suite differential,
   fixpoint guard, and non-self-host smoke tests.
5. No phase advances with an unexplained new failure.
6. High-risk layout, ownership, runtime, and optimizer changes are attended.
7. Keep one current status document; archive superseded status rather than
   layering new truth over old truth.
8. Bank coherent work frequently. Do not build another long unpushed branch stack.

## Program Phases

| Phase | Objective | Exit gate |
|---|---|---|
| 0. Bank and baseline | Reconcile the current branch, fix branch-induced test drift, capture the complete failure manifest, and establish a clean integration point. | Clean coherent branch; reproducible full-suite baseline; fixpoint green; every failure owned. |
| 1. Truth and inventory | Audit source, tests, docs, runtime, backends, repository cruft, unsafe surface, and all semantic `Int`/`i64` transport. Establish `STATUS.md` and a short active roadmap. | One current source of truth; every known defect and public claim classified; de-existentialization census complete. |
| 2. Stop silent miscompiles | Fix bounded-generic dispatch, niche-layout disagreement, assignment holes, payload inference/de-erasure tail, nondeterminism, and newly discovered wrong-code cases. | No known accepted-program wrong-code bug; deterministic IR; miscompile corpus and full suite green against baseline. |
| 3. Finish de-existentialization | Replace semantic scalar erasure with typed compiler values, handles, MIR operands, payloads, and module metadata. | No ordinary typed value uses `as_int`/`as_type` transport; no high-level ABI depends on an erased scalar convention. |
| 4. Canonical layout | Give every resolved type one serializable layout descriptor consumed by construction, matching, calls, returns, FFI, modules, and backends. | Layout cannot be re-derived from names or ambient context; cross-module/backend conformance tests pass. |
| 5. Safety and runtime | Establish `unsafe`; fix scheduler teardown, slices/strings, Drop coverage, actor failure typing, select semantics, and sanitizer findings. | Safe corpus has no memory fault; sanitizer and stress lanes are green; no known runtime race. |
| 6. Settle core semantics | Implement value-default structs, strict Bool conditions, non-recoverable panic, coherent Result/Throws behavior, typed effect handlers, and opaque `impl Trait`. | Ratified semantics match compiler, reference, stdlib, and examples; surface semantics frozen. |
| 7. Toolchain and repository | Repair developer tasks, guard behavior, formatter, QSpec semantics, CI matrices, clean-clone bootstrap, artifacts, licensing, and release gates. | One-command authoritative gate; reproducible release; repository contains no unexplained cruft or machine state. |
| 8. Final adversarial audit | Independently attack type soundness, ownership, effects, concurrency, ABI, optimizer, incremental compilation, and docs; fuzz phase boundaries and dogfood substantial programs. | Every finding fixed or explicitly accepted as a documented pre-1.0 limitation; stability exit gate passes. |

## Current Priority

Phase 0/1 research R1-R8 and integration items I1-I6 are complete as uncommitted
work. I7 banking review is next, followed by V1 verification and handoff. Do not
stage or commit before I7, and do not begin later-phase implementation before
the Phase 0/1 inventories, baseline, and banking boundary are reviewed. The
detailed execution record remains
[`docs/conductor/stabilization-baseline-2026-07-15.md`](conductor/stabilization-baseline-2026-07-15.md).

## Deferred Until Stable

- Package manager and registry work.
- Marketing sites, launch copy, and benchmark promotion.
- New syntax or language breadth not required to close a stabilization invariant.
- Promotion of C, WASM, or freestanding backends beyond their verified scope.
- Performance work that does not fix a correctness, determinism, or resource-bound
  defect.
- Compatibility layers for unreleased behavior.

## Program Log

Append only phase-level outcomes here. Detailed execution belongs in bounded saga
ledgers; durable design decisions belong in `docs/design/`.

- 2026-07-15: Program created. Six stabilization decisions owner-ratified.
  Phase 0-1 saga prepared; feature freeze active.
