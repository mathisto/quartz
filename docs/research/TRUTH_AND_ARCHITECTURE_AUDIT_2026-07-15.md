# Quartz Truth and Architecture Audit (2026-07-15)

Status: research notes, not normative language documentation.

This register records contradictions and gaps found while orienting to Quartz and
the diagnostics-quality conductor branch. Verify each item against current source
and executable behavior before editing normative docs. Items marked **decision**
need an owner-level language or architecture choice; they are not mechanical doc
fixes.

## P0: Correctness and Safety

| Area | Current evidence | Required action |
|---|---|---|
| Bounded-generic dispatch | `docs/bugs/GENERIC_OPERATOR_TRAIT_DISPATCH_MISSING.md` and ROADMAP R2.4 record that `T: Eq` equality can lower to raw i64 identity comparison; generic trait calls can miscompile or crash. | Fix before making strong trait-safety claims. Monomorphic re-resolution is the researched direction. |
| Niche enum layout | `docs/bugs/NICHE_MULTI_MATCH_CONTEXT_DEPENDENT_GARBAGE.md` records construction/read layout disagreement based on ambient context. | Make layout a canonical type property shared by construction, matching, calls, returns, and serialization. |
| Typed transport ABI | ROADMAP's typed effect/channel payload ABI section records hardwired i64 transport and a value-layout UAF hazard. | Treat typed effect/channel/task payloads as foundational rather than ecosystem polish. |
| Assignment checking | `self-hosted/middle/typecheck_walk.qz` and conductor records show field/index assignment checking is split and weakened by compiler-internal Int handle punning. | Type-check the real RHS once and replace untyped internal handle storage with explicit handle types. |
| Scheduler shutdown | `docs/bugs/GRACEFUL_SHUTDOWN_INTERMITTENT_SIGSEGV.md` records a teardown race. | Validate a lifecycle fix under TSan/stress before claiming concurrency robustness. |
| Slice/string safety | `docs/bugs/STRING_SLICE_RANGE_FAMILY_BUGS.md` records Slice-as-Vec and out-of-range UTF-8 slice crashes. | Fix or clearly mark unsafe/experimental. |
| Unsafe boundary | Raw `CPtr`, `load`, `store`, `as_int`, `as_type`, unchecked indexing, and assembly are not consistently fenced by an explicit unsafe construct. | **Decision:** introduce a lexical unsafe boundary or narrow safety claims to the checked subset. |
| Conditions | `docs/QUARTZ_REFERENCE.md` permits integer/nil truthiness despite a strong static-safety pitch. | **Decision:** require `Bool`, or explicitly defend and specify truthiness as a core design choice. |

## P0: Semantic Coherence

| Area | Contradiction or gap | Required action |
|---|---|---|
| Struct semantics | Plain `struct` is reference-shared; `@value struct` changes allocation, ABI, copying, borrowing, and ownership. ROADMAP R1.3 plans another default flip. | **Decision:** make value versus reference semantics obvious in declaration syntax and settle the default before 1.0. |
| Runtime model | `docs/QUARTZ_REFERENCE.md:10` and `docs/ARCHITECTURE.md:162-169` say values erase to pure i64; value structs, COW, typed returns, records, unions, and niche layouts contradict that as a universal rule. | Replace the existential-runtime slogan with the actual mixed representation model. |
| Error model | `docs/QUARTZ_REFERENCE.md` presents `Result`, catchable `throw`, and catchable `panic`; `docs/EFFECTS.md` presents a four-tier model and says panic is non-catchable. | **Decision:** specify whether panic is recoverable and how `Result`, `Throws`, and panic relate. |
| `try` semantics | The reference defines `try` as Option/Result unwrap-and-return; effects documentation also describes it as a marker for inferred `Throws`. | **Decision:** give `try` one formal meaning or define a principled unification. |
| Effect handler surface | Public examples expose `(op: Int, argc: Int, argv: Int): Int` and manual loads. | Replace ABI-shaped handlers with typed operation clauses; keep raw ABI internal. |
| `impl Trait` | Reference says return-position `impl Trait` exposes the concrete type, unlike the opacity implied by Rust-shaped syntax. | **Decision:** implement opacity or rename/document the feature without Rust's abstraction promise. |
| Union use | Some paths can expose raw representation or garbage when a union/enum payload is used without a sound narrowing/layout decision. | Require narrowing or operations valid for every arm; never leak representation words. |
| Actor failure | Actor panic recovery can use a scalar sentinel, potentially colliding with a valid result. | Encode failure in the reply type. |
| Select semantics | Documentation allows destructive consumption of losing select arms. | **Decision:** make this explicit and preferably opt-in; compare against Go/Rust expectations. |

## P1: Public Documentation Truth

| Claim | Conflicting evidence | Mechanical update |
|---|---|---|
| `ref.md` is authoritative | `AGENTS.md` requires it, but it does not exist. `docs/QUARTZ_REFERENCE.md` says to read it first. | Update `AGENTS.md` to the real path or restore a short root `ref.md`. Prefer one canonical file. |
| "No runtime" | `README.md:34,209`; compiler emits a substantial scheduler/effects/allocation/concurrency runtime. | Say "no VM or garbage collector" and describe the runtime honestly. |
| Generator "zero allocation" | `README.md:209`; reference says generator construction allocates a state struct. | Remove zero-allocation claim or document the exact optimized cases. |
| Types inferred | README examples omit parameter/return types; reference Big Rule 2 says signatures require annotations; SURF inference remains planned/partial. | Make examples compile today or label proposed syntax. |
| Full DWARF and variable inspection | `README.md:289,320`; `docs/ARCHITECTURE.md:53-60` says line-table only, no typed locals. | Advertise source lines/backtraces only. |
| Formatter shipped | README and several guides advertise `quake format`; `docs/design/FORMATTER.md` says no real formatter and Quake tasks are fail-safe disabled after destructive output. | Mark formatter v2 as in progress and remove working-command claims until restored. |
| H-M inference | `README.md:327` claims H-M inference; reference requires explicit signatures and SURF.3/.4 describe incomplete inference. | State the actual local/bidirectional inference subset. |
| Test/function/compiler-time counts | README, architecture, roadmap, and reference carry different counts and old compile times. | Generate or centrally maintain these values; avoid hand-copying volatile metrics. |
| MIT license | README badge/text says MIT; no root `LICENSE` is tracked. | Add the intended license file or remove the claim. |
| Typed channels | README uses inferred `channel_new(64)` while ROADMAP says channel transport is hardwired i64 and typed payload ABI is missing. | Distinguish typechecked facade from runtime transport limitations. |
| Rust-style safety | README makes the comparison while borrowing docs list major expressiveness limits and raw escape hatches are unfenced. | Narrow the claim until safe-code guarantees are demonstrated. |
| C backend status | Some design docs say unimplemented while substantial code exists; backend remains experimental. | Use "experimental, fail-loud on unsupported paths." |
| Active OOM blocker | Older sagas/ROADMAP say full QSpec OOMs this Mac; `DECISIONS.md` records the harness fix and five flat full-suite runs. | Update current roadmap/status; preserve old ledgers as historical snapshots. |
| Diagnostics epic status | `docs/conductor/diagnostics-quality-epic-2026-07-07.md` still says #7 remains; later `diag-quality-finish` artifacts say complete. | Mark old ledger superseded and point to the final ledger. |
| Diagnostics quality percentage | ROADMAP reports approximately 88%, but no rubric defines the denominator. | Replace vanity percentage with an explicit remaining-gap list or scored rubric. |

## P1: Tooling and Validation

| Gap | Evidence | Required action |
|---|---|---|
| Default/test task failure | Quake's default and aggregate test tasks include disabled `format_check`. | Make the default developer path useful; do not intentionally fail the umbrella task. |
| Guard mutates Git index | `quake guard` stages compiler binary/fixpoint artifacts. | Separate validation from staging. |
| Fixpoint provenance | Source hash can include ignored/untracked self-hosted files. | Hash a tracked manifest or explicit compiler-input set. |
| Quarantined specs | Normal suite excludes several actor/network/TLS/macro specs. | Add visible CI lanes and never imply the main count is a fully gating corpus. |
| Recovered parallel failures | Serial retry can turn load-sensitive races green. | Track recoveries separately and fail/warn for concurrency families. |
| `build:separate` fan-out | Memory investigation records unbounded `llc` process spawning. | Add CPU/RAM-aware worker limiting. |
| QSpec hooks | `before`/`after` behavior is not conventional per runner inspection. | Either implement per-test hooks or document the current registration semantics. |
| CI breadth | Fuzz, sanitizers, slow/quarantined specs, C ABI, WASM, formatter safety, and egraph are not all release gates. | Define required PR, nightly, and release matrices. |
| Release task | Build automation can commit/tag without a comprehensive release gate. | Validate first; keep VCS mutation explicit and separate. |

## P1: Project and Roadmap Structure

| Gap | Consequence | Recommended change |
|---|---|---|
| ROADMAP is an append-only historical database | Current priorities, completed narratives, corrections, and stale claims coexist in a very large file. | Split into `STATUS.md` (current truth), a short prioritized roadmap, and archived dated execution records. |
| `DECISIONS.md` is append-only session state | New readers must infer which top block supersedes which lower block. | Keep durable architectural decisions in ADRs; keep session summaries in dated handoffs. |
| 97-commit unpushed conductor stack | Increases integration, review, bisect, and recovery risk. | Bank coherent epics sooner; avoid continuing unrelated work on a completed epic branch. |
| Known red expectation drift | `DECISIONS.md:21` records stale A3 arity assertions left after the behavior change. | Fix before integration; a completed epic should not knowingly leave branch-induced reds. |
| Historical binaries in Git | Large, host-specific repository history. | Keep a minimal bootstrap seed; move historical/release binaries to artifacts or LFS. |
| Multiple experimental backends | Runtime semantics drift among LLVM, C, and WASM. | Define LLVM as authoritative and require cross-backend conformance before promoting others. |

## Architectural Direction to Reevaluate

1. **Canonical type/layout descriptor:** representation must be decided once per
   resolved type and serialized across modules. Niche, value/COW, union, record,
   FFI, call, return, and backend decisions should consume that descriptor rather
   than re-derive layout from strings and ambient registries.
2. **Typed compiler IR and internal handles:** reduce overloaded `Int` storage,
   type-name strings, and `as_int`/`as_type` recovery. These shortcuts now block
   stricter user-level type checking and create representation drift.
3. **Runtime as testable modules:** move large string-emitted LLVM runtime pieces
   toward separately compiled, versioned runtime modules so sanitizers and unit
   tests can exercise scheduler/effects/allocation independently.
4. **One memory model:** settle value/reference declaration semantics before
   expanding surface features. Representation attributes should not silently
   change the programmer's aliasing model.
5. **One error/effect model:** define `Result`, `Throws`, panic, `try`, cleanup,
   and resumptions together, then make the syntax reflect that model.
6. **Safe/unsafe boundary:** make unchecked operations visibly reviewable and
   test the claim that safe Quartz cannot cause memory corruption.

## Suggested Sequencing

1. Fix branch-induced red arity expectations and integrate/bank the current stack.
2. Reproduce and close known silent miscompiles and runtime crashes before adding
   language breadth.
3. Write the canonical layout and typed-transport architecture before the plain
   struct default-value flip.
4. Resolve memory and error/effect owner decisions before the surface re-freezes.
5. Perform a truth-in-docs pass from executable examples and generated metrics.
6. Resume formatter/surface migrations only after the semantic foundation and
   validation gates are stable.
