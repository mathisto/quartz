> Public research edition: retired November 11, 2026. The development state below is retained as dated evidence, not an active roadmap. See [public-edition notes](docs/PUBLIC_EDITION.md).

# Quartz Status

**Current as of:** 2026-07-19
**Branch:** `conductor/diagnostics-quality-epic-2026-07-07`
**Version:** `5.12.21-alpha` (`VERSION`)

Quartz is an unreleased, self-hosted alpha. The self-hosted compiler is the
current implementation and LLVM is the authoritative backend. C, WASM,
freestanding, and cross-target paths are experimental or feature-scoped; no
secondary backend has equivalent release authority.

## Authority

- The [stabilization program](docs/STABILIZATION_PROGRAM.md) owns current
  sequencing; the [owner-ratified invariants](docs/design/STABILIZATION_INVARIANTS.md)
  own target semantics. The feature freeze is active.
- Root [`ref.md`](ref.md) is the compact working-memory entry point and authority
  map. [The Quartz reference](docs/QUARTZ_REFERENCE.md) remains the sole detailed
  reference for executable language behavior; the two files are not competing
  full authorities.
- Historical roadmaps and conductor ledgers are evidence, not current priority
  instructions. The [baseline ledger](docs/conductor/stabilization-baseline-2026-07-15.md)
  and [tooling ledger](docs/conductor/tooling-hardening-2026-07-15.md) contain the
  exact execution record.

## Red Baseline

The authoritative product state is red; neither run below is a green claim.

- **Historical I2 baseline, 899 files (2026-07-15):** `866/899` initially, then
  `869/899` after three serial recoveries, leaving 30 durable failures. The
  recoveries remain instability. Nine quarantined files and 13 pending
  declarations were outside the green count. This is retained as the pre-tooling
  stabilization baseline, not the latest canonical differential.
- **Latest canonical evidence, 903 files (2026-07-16):** no retry, `866/903`
  passed and 33 failed; four registered feature exclusions, nine quarantines,
  14 pending cases, five skipped cases, 10,620 cases, and 14,004 assertions.
  Against the frozen 32 failure identities/classes, the sole added failure was
  `http_dynamic_goroutine_sup_spec` with native SIGSEGV/signal 11. Exact evidence
  and hashes are in the [owner-authorized canonical B5 checkpoint](docs/conductor/tooling-hardening-2026-07-15.md#owner-authorized-canonical-b5-checkpoint---2026-07-16).
- The HTTP supervisor protocol was subsequently repaired and is
  [focused-green](docs/conductor/tooling-hardening-2026-07-15.md#b5-http-supervisor-final-acceptance---2026-07-16).
  **No post-repair canonical 903-file differential has run**, so the canonical
  red evidence is not superseded.

## Current P0/P1 Classes

The classes below are a current high-priority summary, not an exhaustive defect
register. The linked audits and manifests retain the complete known inventory.

- **P0 correctness/safety:** accepted-program wrong code or memory faults remain
  in context-dependent niche layout, generic payload de-erasure, bounded-generic
  operator dispatch, Slice enumerable lowering, and out-of-range string slicing.
- **P0 validation/safety proof:** the complete matrix is not reproducible or
  green; sanitizer coverage, execution of quarantined/pending lanes, and a
  non-mutating release gate remain absent.
- **P1 runtime/reproducibility:** scheduler teardown and forced cancellation do
  not prove unwind, waiter, destructor, FD, or SSL cleanup; external drain/spawn
  ownership is incomplete; emitted SSA names can depend on heap addresses.
- **P1 toolchain/docs:** operational guard trust and clean-clone bootstrap are not
  established, secondary backends are not promoted, and active docs still
  contradict executable and target semantics.
- **P1 semantic conformance:** conditions still permit non-`Bool` truthiness, and
  `panic(msg)` can still be intercepted through a user `Throws` handler. Both
  conflict with the owner-ratified strict-Bool and non-recoverable-panic target.

The detailed defect evidence is the
[correctness reproduction audit](docs/sagas/stabilization-baseline-2026-07-15-research/correctness-reproduction-audit.md),
[validation-lane audit](docs/sagas/stabilization-baseline-2026-07-15-research/validation-lane-audit.md),
and [consolidated manifests](docs/sagas/stabilization-baseline-2026-07-15-research/consolidated-manifests.md).

## Completed And Blocked

- Stabilization R1-R8 and integration items I1-I7/V1 are complete at the scope
  of a **red-baseline documentation and banking handoff**, not a green product or
  executable-tooling acceptance. I1 is banked at `b7cef03d`; its three focused
  specs passed with no orphans. The I2 red baseline and I3-I5 research/current-
  truth work are banked at `7f7705f1`; I3-I6 were accepted after independent
  review and remediation, with I6 banked at `b39d2384`. The tooling handoff is
  banked at `9efa6032`.
- `9efa6032` is the pre-closeout banked boundary. The extensive dirty QSpec,
  guard, HTTP, runtime-adjacent tooling, tests, and fixtures remain intentionally
  unbanked. This closeout commit follows `9efa6032` and contains the I7/V1 truth
  updates; `projects/afterdark/` remains unrelated and outside this work.
- Tooling B0-B4 are complete at their documented scope: exact baseline identity,
  QSpec result/accounting and supervision hardening, and static guard protocol.
  B4 operational guard migration is still parked on external trust and owner
  actions.
- B5 HTTP supervisor acceptance is focused-green, but B5 remains blocked. The
  [guarded runtime fix packet](docs/conductor/b5-guarded-runtime-fix-packet-2026-07-16.md)
  is design-only: runtime edits require explicit owner semantic decisions,
  operational trusted-guard prerequisites, attended ownership, and separate
  authorization for exactly one canonical differential.

## Next Gate

I7 and V1 are closed only as the red-baseline documentation/banking handoff
defined above. The saga required a new final full differential only if compiler
source changed; the banked saga units changed tests and documentation, I1's
focused verification passed, and I2 already captured the required canonical red
baseline. No additional owner/full-suite gate is required to close that narrow
handoff, and no executable acceptance is implied.

The executable gates remain blocked and unauthorized: B5/QSpec needs a separately
authorized canonical differential and must not be called complete; the trusted
guard needs owner-managed attended migration; no post-HTTP-repair canonical
differential has run; and the guarded runtime packet is design-only and not
authorized for implementation. B6-B10 remain parked.
