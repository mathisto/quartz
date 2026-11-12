# Phase 4 — Non-determinism and Generators (research synthesis)

> **Epic**: Operation Piezoelectric Effects · `[piezo]` · Phase 4
> **Status**: Research / planning. Kickoff handoff drafts from this document.
> **Drafted**: 2026-04-23, post-Phase-5 closure.

## Goal

Complete the algebraic effects epic's remaining ambition: **multi-shot handlers** (the case where a handler resumes its continuation more than once) and **generators** (the case where the *caller* resumes — iterator-shape control flow).

Phase 1-3 gave us one-shot function-kind ops (kind=1), unwind ops (kind=2, setjmp/longjmp), and CPS-suspending ops (kind=3, async/await). Phase 4 asks: what handlers need that we don't have?

Two canonical shapes:

1. **Consumer-resumed: generators.** A `yield` op suspends the producer and returns control to the consumer. The consumer calls `next()` and the producer resumes. Python, ES6, Rust (nightly), Lua. One-shot at every yield point, but threaded differently from async.
2. **Handler-resumed-many-times: non-determinism.** `choose(a, b)` returns both `a` and `b`; the handler runs the continuation once per choice and collects results. Logic programming, probabilistic programming, backtracking search. Genuinely multi-shot.

These two are the last pillars of "classical" algebraic effects. The rest of the effect system literature builds atop them.

---

## 1. What the big players do

### 1.1 Generators

| Language | Mechanism | Capture model | Multi-shot? |
|---|---|---|---|
| **Python** | `yield` keyword; generator frame is heap-allocated `PyFrameObject`; `next()`/`send()` resumes | one-shot, frame lives on heap | no |
| **JavaScript ES6** | `function*` + `yield`; compiled to a state machine by the engine; `.next()` API | one-shot, internal state machine | no |
| **C# iterators** (`yield return`) | compile-time CPS into `IEnumerable<T>` state machine | one-shot | no |
| **Kotlin** | `Sequence` builder DSL; `sequence { yield() }` uses coroutines | one-shot, suspending coroutine | no |
| **Rust (nightly)** | `Generator` trait + `yield` keyword (async-like); stackless; `Pin` restricts moves across yield | one-shot | no |
| **Lua** | stackful coroutines; `coroutine.create/resume/yield` | coroutine is the frame | symmetric, effectively one-shot |
| **Scheme call/cc** | first-class continuation; stackful | full continuation reification | **multi-shot** |
| **Racket** | delimited continuations (`shift`/`reset`, `prompt`/`control`) | delimited stack segment | **multi-shot** |
| **OCaml 5** | effect handlers; `(continue k v)` ABI | one-shot by design (documented) | **one-shot only** |
| **Koka** | effect handlers + evidence-passing translation | `$poll`-like state machine with heap frame | **multi-shot** |
| **Effekt** | "second-class" capabilities (no closure capture) | one-shot call stack; bidirectional | one-shot; multi-shot is a library |
| **Haskell** | lazy lists; `iterate`, `unfoldr`; or free monads | n/a (lazy thunks do the work) | trivially multi-shot via persistence |
| **Unison** | abilities; runtime continuation cloning | heap-allocated continuation | **multi-shot** |

### 1.2 Multi-shot / non-determinism

| System | Construct | Cost model | Notes |
|---|---|---|---|
| **Scheme `call/cc`** | `(call/cc (lambda (k) ...))` | O(stack) on capture | full continuations; multi-shot trivial; critics argue it's too powerful |
| **Racket `shift/reset`** | delimited control | O(segment) | the textbook multi-shot primitive; Kiselyov / Dybvig work |
| **Haskell `ContT` monad** | explicit CPS monad | zero — pure lambda | always available but requires monad discipline |
| **Koka `Ndet`** | evidence + frame clone | O(frame) per resume | Xie-Leijen 2020 compilation scheme |
| **Eff** (Bauer-Pretnar) | first-class handlers | O(stack copy) per resume | the OG algebraic effects language |
| **Prolog / miniKanren** | SLD resolution / interleaved streams | dedicated runtime | specialized VM, not general-purpose lang feature |
| **Probabilistic PPLs** (Pyro, Church, Anglican) | `sample`/`observe` as effects | often SMC or MCMC | multi-shot underpins all of them |

### 1.3 The one-shot / multi-shot divide

**One-shot is easier and faster:** the runtime can move values out of the continuation frame (because it won't be re-entered). Stack-based implementation works. No cloning. No GC integration required.

**Multi-shot is the harder, more expressive case:** the continuation frame must be re-enterable, which means locals can't be moved out or mutated in place. Either (a) restrict types that cross the perform site, (b) clone the frame, or (c) run on a green thread that can be forked.

**OCaml 5's decision** (from Dolan-White-Sivaramakrishnan 2021, "Retrofitting effect handlers onto OCaml"): "We chose one-shot to avoid... complex stack-copying machinery... in exchange for a runtime that can fit alongside C." They explicitly cite the incompatibility with value-semantic ML primitives. This is the closest-precedent case to Quartz.

**Koka's decision** (Xie-Leijen 2020, "Effect Handlers, Evidently", JFP): go multi-shot, compile via evidence-passing. Each effect operation is passed an evidence record containing a pointer to the handler's frame. The continuation is a heap object; the handler can invoke it arbitrarily many times. Koka has a reference-counted GC; cloning is cheap because values are persistent.

**Quartz is closer to OCaml than to Koka** — we have move semantics, we have Drop types, we don't have a GC. But we have one advantage OCaml 5 doesn't: we already have the `$poll` state-machine machinery for kind=3, and it's structured enough that cloning a single `$poll` frame is feasible without general stack-copying.

---

## 2. Primary research

Key papers / references, with what each contributes to our specific decision:

### 2.1 Algebraic effects canon

- **Plotkin & Pretnar 2009, "Handlers of algebraic effects"** — foundational. Defines handler semantics via continuation delimiters. Our kind=2 is the simplest case.
- **Bauer & Pretnar 2015, "Programming with algebraic effects and handlers"** — first practical language (Eff). Multi-shot by construction. Slow but semantically clean.
- **Kammar, Lindley & Oury 2013, "Handlers in action"** — the compilation handbook. CPS translation preserves semantics. Gives us the proof obligation for any efficient compilation.
- **Hillerström & Lindley 2016, "Liberating effects with rows and handlers"** — row polymorphism story (Links). We adopted this in Phase 1.

### 2.2 Efficient compilation

- **Xie & Leijen 2020, "Effect handlers, evidently" (JFP)** — evidence-passing translation. Each op call receives its handler's evidence pointer explicitly. Skips the dynamic handler scan. Quartz's Phase 2 State<S> uses this shape. For multi-shot, evidence includes continuation info.
- **Leijen 2017, "Structured asynchrony with algebraic effects"** — Koka's async story. Relevant because we've already done Phase 3 differently; comparing approaches informs the generator design.
- **Leijen 2021, "Generalized evidence passing for effect handlers"** — extends evidence-passing to general multi-shot. Available on arxiv.

### 2.3 Alternative foundations

- **Brachthäuser, Schuster & Ostermann 2020, "Effects as capabilities"** (Effekt) — trades multi-shot for explicit capability threading. Each handler is a lexically-scoped value that cannot escape. Interesting alternative: we could add a "second-class" discipline to restrict where handlers live. Probably too restrictive for dogfooding, though.
- **Lindley, McBride & McLaughlin 2017, "Do be do be do"** (Frank) — bidirectional effect typing; polymorphic handler inference without row variables. A different path. Phase 3.F's effect-polymorphic combinators touch this space.
- **Forster, Kammar, Lindley & Pretnar 2019, "On the expressive power of user-defined effects"** — formal result: effect handlers + multi-shot = delimited continuations = monadic reflection. They're all equi-expressive. Tells us: if we want delimited control, effect handlers can give it to us.

### 2.4 Delimited continuations — the underlying math

- **Danvy & Filinski 1990, "Abstracting control"** — shift/reset primitives. Still the textbook intro.
- **Felleisen 1988, "The theory and practice of first-class prompts"** — the prompt calculus.
- **Shan 2007, "A static simulation of dynamic delimited control"** — shows delimited control can be statically typed into CPS. Practical.
- **Kiselyov 2012, "Delimited control in OCaml, abstractly and concretely"** — the practical implementation story that OCaml 5 essentially inherits.
- **Dolan, White & Sivaramakrishnan 2021, "Retrofitting effect handlers onto OCaml"** — the pragmatic "one-shot is enough for us" decision. Close to Quartz's trade-off space.

### 2.5 Generator-specific

- **PEP 255** (Python generators, 2001). The dominant model. `yield` preserves frame state on heap; `next()` resumes. `send()` and `throw()` add bidirectional communication.
- **PEP 342** (enhanced generators, coroutines). The `send()` → `receive()` flow that makes generators bidirectional. We should match this.
- **C# iterators design notes** (Hejlsberg et al., early 2000s) — pure compile-time state machine. No heap frame between yields; everything lives in an object allocated at generator entry.
- **Rust RFC 2033** (generator syntax) — still unstable. The `Pin` discipline is the interesting constraint.
- **Lindley 2008 (stream fusion), Coutts-Leshchinskiy-Stewart 2007** — hylomorphism fusion for streams. If we hit perf issues with generators, fusion is the escape hatch.

### 2.6 The untried / less-mainstream

Candidates that aren't yet mainstream but have promising properties:

- **Segmented stacks for continuation frames** (Go's original approach, since retired; Cilk's "cactus stack"). Each green thread gets a small stack; growth triggers allocation. Multi-shot = snapshot the segment tree. Relevant if we ever need stackful multi-shot.
- **Ref-counted frame cloning** (Koka's approach). If our GC/alloc story ever supports cheap reference counting, multi-shot clone becomes O(1) for immutable data plus RC bumps.
- **One-shot-with-explicit-reify** — default is one-shot; `reify(k)` is a compiler intrinsic that turns the continuation into a first-class clonable object. Forces the programmer to opt in. Haven't seen this named in literature but it's the obvious conservative hybrid.
- **Typed-clone restriction** — extend the type system with a `Clone` marker; body of multi-shot handler may only mention `Clone` types at the perform site. This is a linearity-via-restriction approach. Closest published work: Effekt's second-class discipline.

---

## 3. The Quartz constraint map

Before designing, list the non-negotiables and the knobs.

### 3.1 Non-negotiables

- **Move semantics / Drop types.** We have them; we keep them. Any multi-shot story must route around them.
- **No general-purpose GC.** Reference counting for specific types is possible (already in Arc); full tracing GC isn't on the roadmap.
- **LLVM IR as the only backend.** No runtime stack manipulation beyond setjmp/longjmp.
- **Existing `$poll` state-machine.** Kind=3 async already reifies state into a heap frame; generators can piggyback.
- **Existing evidence-passing** for State<S> (Phase 2). Generalizable to continuations.
- **Fixpoint discipline.** Every change to effect machinery must keep the compiler self-hosting.

### 3.2 Knobs

- **Kind=4 (new) for generators** vs reusing kind=3. If we do 4a with kind=3, the consumer-side API becomes uniform with async; if we make it a separate kind, we can optimize differently.
- **Multi-shot via frame clone** vs **via fiber** vs **via CPS transform**. Three implementation strategies, different costs.
- **Typechecker restriction** on multi-shot bodies — how tight? No Drop? No mutation? Copy-only?
- **Shallow vs deep handlers.** We have deep (handler stack scan). Multi-shot usually wants shallow (handler runs once, re-installs itself). Do we add shallow as a new semantics or shoehorn?
- **`yield` keyword** vs **effect-op `yield()` only**. We have the syntactic room for either.
- **`for x in gen():` integration.** Do generators integrate with existing for-in? They should, but the lowering needs thought.

---

## 4. Three proposed paths (pick one, maybe after adjustment)

### Path A — **Ship generators first, defer multi-shot.** (Conservative)

- **4a only.** Yield<T> + generator syntax. Reuse kind=3 $poll frames. One-shot semantics. Ship `Stream<T>` / `Iterator` integration in stdlib.
- **4b filed as "future research," not executed.** If concrete Ndet-like use cases emerge (probabilistic programming, backtracking parser combinators), pull it back in. Until then, the complexity isn't justified.
- **4c done if 4a motivates it** — likely does, for stream combinators.

**Estimate**: 4-7 quartz-days total. Low risk.

**Trade-off**: Quartz explicitly opts out of multi-shot, like OCaml 5. We lose `Ndet`, list monad, classical backtracking. We gain simplicity. Most users never notice.

### Path B — **Full Phase 4: generators + multi-shot via frame clone.** (Ambitious)

- 4a as above.
- **4b via evidence-passing + shallow frame clone.** `effect Ndet { choose @multishot }`. Typechecker rejects Drop types at multi-shot perform sites. Runtime primitive `@__qz_eff_clone_frame` shallow-copies the $poll state-machine struct. Handler can call `resume(v)` multiple times; each call allocates a fresh frame clone.
- 4c on top.

**Estimate**: 8-12 quartz-days.

**Trade-off**: Quartz is one of few systems languages with working multi-shot. But the restriction ("no Drop types in multi-shot bodies") is real — `String`, `Vec<Int>`, anything with an owned allocation is forbidden at perform sites. This might be workable for Ndet specifically (the classical example operates over `Int`) but annoying in general.

### Path C — **Phase 4 as "staged 4a → reassess 4b"** (Pragmatic)

- Ship 4a + 4c as a complete milestone. Full kick criteria, handoff, fixpoint.
- Open Phase 4b as a separate "stretch" planning doc after 4a ships. Reassess based on:
  - User demand for multi-shot (observed via blog posts, issue filings, our own use).
  - Whether 4a's `$poll`-clone precedent makes 4b cheap or expensive (we'll know after building 4a).
  - Whether the Drop-type restriction is genuinely limiting in practice.

**Estimate**: 4-7 quartz-days for 4a+4c; 4b decided later.

**Trade-off**: Lose ambition temporarily, gain information. Arguably the correct "research project" approach. Matches how Phase 5 actually happened (dogfooding was pulled forward ahead of Phase 4 because it was ready).

---

## 5. Decision points for the user

Before finalizing the kickoff handoff, the following decisions are load-bearing. Each has a recommended default; accept or redirect.

### 5.1 Path A / B / C?

**Recommended: Path C.** Ships value fast, preserves optionality, matches how we've successfully shipped previous Piezo phases.

### 5.2 Kind=3 reuse or new kind=4 for generators?

**Recommended: reuse kind=3 with a "consumer-drive" flag.** The async/await CPS frame already does suspend-resume. Generators are the same mechanism with resume driven by `next()` rather than the scheduler. This saves implementing a second state-machine path and lets `for await x in gen()` and `for x in gen()` share infrastructure.

### 5.3 `yield` keyword or effect-op only?

**Recommended: both.** Declare `effect Yield<T> { yield(v: T): Void }` in `std/iter.qz` (or similar). Add sugar: `yield v` is syntactic shorthand for `perform Yield.yield(v)`. The keyword is discoverable; the effect is principled; they're the same thing underneath.

### 5.4 Generator return type — `Stream<T>` or `Iterator<T>` or new `Gen<T>`?

**Recommended: `Stream<T>`** since we already have some stream infrastructure (P3.F will touch `std/streams`). One primitive, integrated with async. Implement as a struct wrapping the generator frame pointer + a `next(): Option<T>` method.

### 5.5 `for x in gen():` integration?

**Recommended: yes, mandatory.** A generator that can't be iterated by `for-in` is useless. Desugar `for x in gen()` into `while let Some(x) = gen.next()`. This probably requires extending the for-in lowering to recognize `Stream<T>` (or an Iterator trait).

### 5.6 Bidirectional generators (`send(v)`)?

**Recommended: defer.** Python's `send()` is rarely used in practice; it complicates the ABI. Phase 4a ships generate-only. Bidirectional can be Phase 4d if ever needed.

### 5.7 If Path B or C: typechecker restriction for multi-shot bodies?

**Recommended (if/when we do 4b): "no Drop types at perform sites."** Match Rust's Generator/Pin restriction. The typechecker walks the body between `with Ndet { ... } do -> ... end` installs and any `perform(Ndet.choose, ...)` and rejects any in-scope Drop-typed binding that crosses the perform. Implementation: extend the existing move-analysis pass.

### 5.8 Default handler for `Yield<T>`?

**Recommended: no default (unlike StdIo/FileIo).** `Yield<T>` outside a consumer is a type error, not a runtime panic. Matches `Throws` (no default unless you actually want silent-swallow). Forces `for x in gen():` or equivalent to be in scope.

### 5.9 Naming: `Ndet` vs `Choice` vs `Nondeterminism`?

**Recommended: `Ndet` with op `choose`.** Standard in the Eff / Koka literature. Short and unambiguous.

### 5.10 Stretch: add `effect Yield<T, R>` with sendable value?

**Defer.** Bidirectional generators are 5.6; no need to bake the shape in now.

---

## 6. Milestone breakdown (assuming Path C)

If Path C is selected, here is the milestone tracker draft for the kickoff.

### Phase 4a — Yield<T> + generators (core)

| # | Milestone | Deliverable | Est. |
|---|---|---|---|
| 4a.1 | `effect Yield<T>` in `std/iter.qz` + QSpec for default (no handler = type error) | Effect decl, 3-test acceptance spec | 0.5 day |
| 4a.2 | `yield v` keyword desugar | Lexer/parser change; `yield` → `perform Yield.yield(v)` | 0.5 day |
| 4a.3 | Generator fn detection + $poll frame allocation | typecheck marks a function as generator if it performs `Yield.yield`; MIR_LOWER wraps body in $poll state machine with consumer-resume variant | 1 day |
| 4a.4 | `Stream<T>` struct + `next(): Option<T>` runtime API | new `std/stream.qz`; bridges to the $poll frame | 1 day |
| 4a.5 | `for x in gen():` integration | extend for-in desugar to recognize `Stream<T>` | 0.5 day |
| 4a.6 | stdlib combinators (map, filter, take, collect) | `std/iter.qz` or `std/stream.qz` | 0.5 day |
| 4a.7 | Acceptance spec + benchmark | 10+ tests; end-to-end examples | 0.5 day |

**Phase 4a total**: ~4.5 quartz-days. Fixpoint checked at every commit.

### Phase 4c — Effect-polymorphic generators

| # | Milestone | Deliverable | Est. |
|---|---|---|---|
| 4c.1 | Effect-polymorphic Yield | `def stream_over<ε>(xs: Vec<T>) can Yield<T>, ε` type-checks + runs | 0.5 day |
| 4c.2 | Compose generator with outer `Throws` / `Async` | integration specs | 0.5 day |
| 4c.3 | Stream combinators accept `ε` | `map` / `filter` are generic over outer effect row | 0.5 day |

**Phase 4c total**: ~1.5 quartz-days.

### Phase 4b — Multi-shot (separate decision after 4a)

Deferred; will be planned in a dedicated research pass once 4a proves the machinery.

### Phase 4d — Bidirectional generators

Deferred indefinitely. Only revive if there's actual user demand.

---

## 7. Risks

1. **$poll frame not trivially re-entrant from consumer.** We built kind=3 for scheduler-driven resume. Consumer-driven resume (generator `next()`) may require small ABI tweaks. Risk: small, surface in 4a.3 or 4a.4.
2. **for-in integration conflicts with existing Vec/Map/Range lowering.** Adding `Stream<T>` as a fourth iterable may require the for-in desugar to dispatch on trait, not hardcode. Risk: medium, addressable by adding an `Iterable` trait.
3. **Effect-polymorphic Yield hits row-inference issue.** 4c might uncover that row-level inference can't handle `Yield<T>, ε` elegantly. Risk: medium, likely surfaces when combining with `Throws`. P3.F will pre-test this space.
4. **Generator allocation overhead.** Each `Stream<T>` allocates a frame. Tight loops might notice. Risk: small — iterator fusion is available as an optimization pass if needed.

## 8. Kill criteria

- Generator call overhead > 3× equivalent plain loop → redesign the frame allocation.
- for-in integration requires reworking > 500 LOC of lowering → reconsider whether `Stream<T>` should be the protocol.
- Type inference cannot handle effect-polymorphic generators cleanly → reconsider row representation.
- Multi-shot (4b), if attempted: frame-clone ABI requires GC integration → defer indefinitely.
- Multi-shot (4b), if attempted: typechecker restriction blocks `String` / `Vec<Int>` in Ndet bodies → redesign the restriction.

---

## 9. Handoff sketch

Once the user locks in answers to §5.1-5.8, the kickoff doc is straightforward: it cites this research doc, names the milestones from §6, sets the fixpoint checkpoints, and points at the first commit's scope (4a.1 + 4a.2: `effect Yield<T>` declaration + `yield` keyword).

Predecessor for the kickoff: `docs/handoff/done/piezo-phase-5-6-handoff.md`.

Next file to create: `docs/handoff/piezo-phase-4-kickoff.md` (written after user decisions are in).
