# Operation Piezoelectric Effects — Per-Paper Research Notes

> **Epic**: Operation Piezoelectric Effects (commit tag `[piezo]`)

Living notes from the papers consumed during Phase 0 research for the Quartz algebraic effect system. Each entry captures: what the paper contributes, what applies to Quartz, what doesn't, and what implementation details to retain.

---

## Leijen 2017 — "Type Directed Compilation of Row-Typed Algebraic Effects" (POPL 2017)

**Read**: 2026-04-18. Daan Leijen, Microsoft Research. 14 pages. [PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/12/algeff.pdf).

### What the paper contributes

1. **Type system foundation** for row-polymorphic algebraic effects, building on Leijen's earlier scoped-labels work [25].
2. **Sound HM-style inference** with row types — extensible effect rows using scoped labels (labels may repeat; no subtyping; equivalence modulo ordering).
3. **Direct operational semantics** (§4) using syntactic evaluation contexts. Avoids the categorical / free-monad framing of earlier algebraic-effects work; easier to reason about for compilation.
4. **Type-directed selective CPS translation** (§5) — the compilation scheme. Only effectful functions get CPS-translated; pure functions stay direct. Reduces the set of CPS-translated functions by >80% in Koka core library.
5. **Polymorphic duplication technique** (§5.3.2) — functions polymorphic over an effect variable (e.g. `map`, `fold`, `filter`) get compiled TWICE (CPS version + plain version) with a runtime wrapper dispatching between them. ~20% code-size growth in practice.
6. **Runtime handler stack** as a trampoline (§5.4) — operations return to a handler loop; proper tail calls preserved.

### What applies to Quartz

- **Row polymorphism with scoped labels** — our committed model (flat equality + tail polymorphism + Model B duplicates) is exactly this paper's design.
- **OPEN / CLOSE inference rules** (§3.2) — load-bearing for our "invisible by default" promise. OPEN allows a closed (no tail variable) function to match a caller with more effects; CLOSE re-closes to simplify inferred types. Without these, most functions would be effect-annotated in printed types, breaking the invisible level.
- **Direct operational semantics style** — we should use syntactic evaluation contexts for our soundness proof, not continuation-style.
- **`handle_l` primitive shape** (§4) — the reduction rule `handle{h}(X_op[op(v)]) → e[x↦v, resume↦λy. handle{h}(X_op[y])]` is the canonical shape our runtime needs to implement. `resume` binds to the continuation (the evaluation context up to the innermost matching handler).
- **Tail-resumption optimization** (§4.1) — if an operation clause ends with `resume(e)` and `resume` doesn't appear in `e`, the compiler can elide the continuation capture and just call directly. Huge perf win; applies to us.

### What does NOT apply to Quartz

- **JavaScript/JVM/.NET target assumptions** — the paper targets runtimes with GC, closures, variadic dispatch, trampoline loops. Quartz targets LLVM IR, which has none of these natively. We re-derive the implementation.
- **Full CPS translation** — the paper's compilation is CPS-based with a trampoline. We're committing to evidence-passing (2020 paper), which is a different strategy. The 2017 paper is NOT the compilation-model validation for us.
- **Monadic framing background** — the paper spends time motivating algebraic effects as free monads; we don't need that framing, we can treat effects directly.

### Important gotchas for an implementer

- **Polymorphic effect variables force duplication.** Any function that's polymorphic in some effect row (our `Vec.map`, `Vec.filter`, `Vec.fold` all qualify) has to be compiled in two forms, with a wrapper dispatching based on whether a continuation argument is present. In our LLVM IR world, the dispatch probably becomes a function-pointer table or a wrapped-thunk pattern. Budget ~20% code-size growth.
- **OPEN/CLOSE rules are subtle.** "At every occurrence of such let-bound variable the OPEN rule can always be applied (possibly surrounded by INST/GEN) to lead to the original most general type." Translation: the inference engine has to apply these rules aggressively to simplify output types. Failure to apply them = every function prints with an effect row.
- **Tail-resumption detection requires syntactic analysis** of the operation clause body. If `resume` appears syntactically in tail position and not elsewhere, elide the continuation. Our MIR lowering can do this easily; must not miss the optimization.
- **Handler stack must maintain invariants across operation dispatch.** In the trampoline model, control returns to the handler loop repeatedly. Our evidence-passing model (2020) avoids this — evidence is threaded at call sites — but we still need *some* discipline for nested / shadowed handlers.

### Translation table for Quartz nomenclature

| Paper term | Quartz term |
|---|---|
| `handle{ops}(e)` | `with handler do -> e end` |
| `op(x) → e` clause | `catch (x: T) -> e` or similar |
| `resume(v)` | continuation value passed to op handler |
| `return x → e` | handler return clause (terminal value transformation) |
| `〈l₁, ..., lₙ | μ〉` row type | `can L₁, ..., Lₙ \| ε` in source |
| `open` rule (type simplification) | Internal; we do NOT surface this syntactically |

### Quartz-specific open questions surfaced by this paper

1. **How does evidence-passing (our committed model) handle polymorphic effect functions?** The 2017 paper's selective-CPS handles it via worker-wrapper. Evidence-passing (2020) has its own answer; need to read that paper to understand.
2. **What happens when `resume` is captured into a closure and escapes the handler scope?** Multi-shot edge case; we've deferred Ndet, so low priority, but the design needs to say *something* (probably "undefined behavior" or "runtime error if the handler is torn down before the continuation is invoked").
3. **How does effect polymorphism interact with Quartz's generic monomorphization?** Our generics are compile-time monomorphized. Effect rows add another axis of polymorphism. Do we monomorphize over effect rows too? (Probably yes; otherwise we can't specialize `Vec.map` for `can Throws<ParseError>` vs `can Io`.)
4. **How does the handler stack interact with our async scheduler?** The scheduler parks tasks; effect handlers also "park" control. Phase 3's `Async` migration has to unify these.

### What to carry into the next paper (Xie & Leijen 2020)

When we read the 2020 paper, look for:
- Explicit description of the evidence-passing ABI (how is evidence represented? struct-of-function-pointers? record of closures?)
- How polymorphic effect functions are compiled under evidence-passing
- Performance comparison vs CPS / direct / fibers
- Interactions with effect polymorphism in generic functions
- Multi-shot cost analysis (we expect a cliff here — this paper should quantify it)
- Any LLVM-adjacent implementation advice (likely none — Haskell target)

### Citations worth following from the reference list

- [35] Plotkin & Pretnar — original algebraic effect handlers paper (foundational)
- [20, 21] Kiselyov et al. — extensible effects in Haskell (monad-based alternative)
- [30] Lindley, McBride, McLaughlin — "Do Be Do Be Do" (POPL 2017, same conference) — relates effects to Hoare-style reasoning
- [47] Thielecke — "Using a Continuation Twice" — multi-shot hazards
- [40] Rompf et al. — Scala delimited continuations via type-directed selective CPS (the technique origin for this paper)

---

## Xie & Leijen 2020 — "Effect Handlers in Haskell, Evidently" (Haskell 2020)

**Read**: 2026-04-18. Ningning Xie, Daan Leijen, Microsoft Research. 14 pages. [PDF](https://www.microsoft.com/en-us/research/wp-content/uploads/2020/07/effev.pdf).

### What the paper contributes

1. **First Haskell library implementation of evidence-passing semantics** — the companion/validation to the formal `F^v` calculus in Xie et al. 2020.
2. **Three-kind operation taxonomy** — `value` (always resumes with constant), `function` (tail-resumptive, evaluates in-place), `operation` (general, captures continuation). This is the core perf story.
3. **Evidence ABI definition** — threaded `Context` parameter carrying a heterogeneous list of `(Marker, Handler)` pairs, where Marker is a unique runtime token and Handler is a datatype with function-pointer fields per op.
4. **Multi-prompt delimited control as the underlying primitive** (`Ctl` monad with `Pure`/`Yield`), used to implement the slow-path `operation` constructor.
5. **Scoped-resumption enforcement** via a runtime `guard` check — resumptions can only be invoked under the same evidence context they were captured in. Lost expressiveness ("unscoped resumptions") is argued to be minimal in practice.
6. **Concrete performance data** against MTL, Extensible Effects (EE), Fused Effects (FE), and pure baselines on 6 benchmarks. Evidence-passing is competitive or better than alternatives for deep stacks and multi-effect composition.

### What applies to Quartz (major)

- **Our committed compilation model is this paper's library, adapted to LLVM IR.** The paper IS the validation we were seeking for Phase 0.
- **Three-kind operation classification is load-bearing.** Quartz must distinguish `value`/`function`/`operation` at the effect declaration level (or detect it automatically from the op body). Without this distinction, EVERY op pays the slow-path cost.
- **Tail-resumption detection as a static analysis**: scan operation-clause body; if `resume` appears only in tail position exactly once AND the body reduces to `return resume(expr)`, classify as `function`. This is the >80% cost reduction the 2017 paper quantified.
- **Evidence context shape**: singly-linked list of `(marker, handler)` nodes threaded as a parameter. We can allocate these on the stack for handler-install scopes (like lexical variables), or on the heap if continuations escape (rare; only for `operation` kind with resume-reification).
- **Scoped resumption enforcement** is exactly the "re-throw safety" we need. Quartz's `guard` check: when invoking a captured `resume`, compare the current evidence context pointer with the one captured alongside. If different → runtime abort with a teaching-grade error.
- **Deep effect stacks run in constant time** for tail-resumptive ops. This matters for Phase 5 compiler dogfooding, where typecheck/codegen will compose many effects (Diagnostics + Reader<TcCtx> + State<Emit> + Fs).

### What applies to Quartz (minor but important)

- **`function`-style ops can be fully inlined by the compiler** when the handler is statically known (GHC does it; LLVM will also do it for direct function-pointer calls that trivially constant-fold).
- **Value-kind ops are trivial** (`Reader{ ask = value "world" }` is just a field load). Perfect for things like `Env.default_for(key)`.
- **`mask` for local state isolation** (§5.7) — removes top handler from effect context for a sub-computation. Quartz: rarely needed in user code; useful internally for stdlib primitives like `Local<S>`.
- **Handler return clauses** (`handlerRet`) — run after the action completes normally, transform its value. We'd implement this as an optional "return continuation" field on the handler struct.

### What does NOT apply to Quartz

- **Haskell's `unsafeCoerce` for marker type-equality proofs** — not needed. Quartz markers are bare `i64`s; type-safety comes from the typechecker's evidence-type tracking, not runtime witnesses.
- **The `Eff` monad wrapper** (`newtype Eff e a = Eff (Context e → Ctl a)`) — Haskell-specific. Our "effectful computation" is a function that takes an extra `ev: ptr` parameter directly, no monad.
- **GHC-specific optimization assumptions** (inlining through type classes, INLINE pragmas, etc.) — we re-derive these manually in the MIR→LLVM pipeline.
- **`forall e1 ans1. h e1 ans1 → Op a b e1 ans1` rank-2 polymorphism** — the paper's type-level gymnastics for polymorphic handler shapes. We don't need rank-2 in the source language; the typechecker handles it internally via fresh type-variable generation.

### Important gotchas for an implementer

- **The `operation` slow-path's continuation reification.** When an op is `operation`-kind and actually captures the continuation, that continuation needs to represent "everything from the `perform` call up to the innermost handler of this effect." In LLVM this is a function pointer + a heap-allocated frame of captured locals. Our existing `$poll` machinery for async does EXACTLY this — async is the canonical `operation`-kind effect. **Phase 3 (async-as-effect migration) therefore REUSES the existing state-machine lowering rather than replacing it.**
- **Marker uniqueness.** Two handlers for the same effect must have distinct markers; otherwise scoped-resumption check fails. Use a global atomic counter; one `i64` per handler install. Overflow never happens in practice (2^63 installs on a 1 GHz counter = 292 years of continuous handler installation).
- **Evidence parameter ordering.** Convention: evidence is the FIRST implicit parameter (like `self` in impl methods). Easier for calling-convention discipline, trait-method dispatch, and FFI wrapping.
- **Polymorphic effect functions must always thread evidence.** `def map<T, U, ε>(v: Vec<T>, f: Fn(T) can ε: U): Vec<U> can ε` has `ε` as an abstract evidence context. The callee doesn't know which effects; it just threads the pointer. Concrete callers monomorphize or pass evidence unchanged.
- **FFI boundaries do not cross evidence.** `extern "C"` functions are effect-free by construction. Quartz effectful functions callable from C: generate a wrapper that installs default handlers before calling, tears them down after.
- **Handler installation is stack-discipline.** The evidence parameter grows at `with` scope entry and shrinks at scope exit. Respecting this enables stack allocation of the evidence node (no heap allocation for handler install in the common case).

### Quartz-specific open questions surfaced / closed

1. **How to detect tail-resumption automatically?** Static analysis over the operation clause body. Closed: a simple MIR pass. See LLVM compilation memo.
2. **Where is evidence threaded?** Closed: first implicit parameter on any function with a non-empty effect row.
3. **How does multi-shot work?** Slow path via reified continuations. We defer Ndet, so this exists but is not optimized. `guard` runtime check prevents unscoped resumptions.
4. **How do polymorphic effect functions compile?** Closed: one compiled version, threads evidence unconditionally. ~20% code size overhead per Koka precedent. Not per-row monomorphization (unlike type params).
5. **What about async ($poll integration)?** Closed: the existing `$poll` state machines ARE the `operation`-kind CPS lowering. Phase 3 reframes them as `Async` effect operations; underlying codegen barely changes.
6. **What's the perf floor?** Closed: tail-resumptive ops are competitive with direct calls (paper benchmarks). General operations cost the CPS transform for their enclosing region only.

### Citations worth following

- **Xie et al. 2020** (reference [Xie et al. 2020] in the paper) — the formal `F^v` calculus. The foundational theory. Worth skimming for the type rules and evidence translation proof.
- **Leijen 2018** (First Class Dynamic Effect Handlers) — for polymorphic heap and dynamic effect handler extension; relevant if we ever do Phase 4+.
- **Biernacki et al. 2017** (Handle with Care) — relational interpretation of effect handlers; foundational for reasoning about handler composition.
- **Dyvbig et al. 2007** (Monadic Framework for Delimited Continuations) — the deep dive on multi-prompt control, our slow path's underlying primitive.
- **Kammar et al. 2013** (Handlers in Action) — HIA library; earlier approach with useful contrast on handler composition.

### Performance notes from §6 benchmarks

Library performance vs Haskell alternatives (their EV implementation):

| Benchmark | EV relative perf | Interpretation for Quartz |
|---|---|---|
| Simple counter (heavy state) | 5.5x slower than Pure | Pure = direct `STRef`; EV goes through evidence. Worst case is state-only workloads. |
| Counter5 (realistic state mix) | 1.5x faster than alternatives | More typical workload; evidence-passing wins. |
| Error effect | Within 1% of Pure | Abort-like effects are nearly free. |
| Deep layer stack (3+ effects) | O(1) regardless of depth | Critical for Phase 5 compiler dogfooding. |
| Pythagorean triples (multi-shot heavy) | 2.6-4x slower than Pure | Multi-shot has real cost; confirms our Ndet deferral was correct. |

Translation to Quartz expectations: **our effect ops will be within a few percent of direct-call perf for the common case (Throws, Log, Io, Clock, Random, Env, State, Reader).** Async / Panic pay the CPS cost but that cost already exists in our $poll machinery. Deep effect composition scales.

## Template for future paper entries

When adding notes for a new paper, follow this structure:

```markdown
## [Author] [Year] — "[Title]" ([Venue])

**Read**: [Date]. [Author]. [N] pages. [Link].

### What the paper contributes

Enumerated list of the paper's novel contributions.

### What applies to Quartz

Specific pieces we'll use. Call out which committed design decision each validates or informs.

### What does NOT apply to Quartz

Honest gaps — target environment, language assumptions, orthogonal concerns.

### Important gotchas for an implementer

Subtle points that would bite us if we skipped them.

### Quartz-specific open questions surfaced by this paper

Design questions the paper makes visible without answering.

### Citations worth following

References we should pursue (with one-line "why" each).
```
