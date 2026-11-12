# Phase 4 — Generators via Effects (Path B)

> **Epic**: Operation Piezoelectric Effects · `[piezo]` · Phase 4
> **Status**: Design. **Phase 4 closed 2026-04-25** — see [`PHASE_4_GENERATORS_RETRO.md`](PHASE_4_GENERATORS_RETRO.md). Supersedes [`docs/handoff/done/piezo-phase-4-kickoff.md`](../handoff/done/piezo-phase-4-kickoff.md) (which assumed greenfield build).
> **Drafted**: 2026-04-24, post-4a.1.
> **Predecessor**: [`docs/research/PHASE_4_NONDET_GENERATORS_RESEARCH.md`](../research/PHASE_4_NONDET_GENERATORS_RESEARCH.md) (unchanged; references in §1 still correct).
> **Playbook**: [`EFFECT_MIGRATION_PLAYBOOK.md`](EFFECT_MIGRATION_PLAYBOOK.md) (three-pass bootstrap + incident ledger apply).

## 1. Why B

The academic and practical consensus in languages with algebraic effects is unanimous: generators are *not* a runtime carve-out, they are an application of the effect system.

- **Koka** (Leijen 2020, JFP): `effect yield<a> { fun yield(x: a): () }`. Generators compile through the same evidence-passing machinery as every other effect.
- **OCaml 5** (Dolan-White-Sivaramakrishnan 2021): deliberately *didn't* add generators as a built-in — they provide effect handlers and users build generators on top with `effect Yield : 'a -> unit`.
- **Effekt, Frank, Unison, Eff**: all route generators through the effect system.
- **Python / Rust / ES6 / C#**: special-case generators only because they lack a general mechanism. Quartz has the general mechanism.

Having a bespoke state-machine generator (`mir_lower_gen.qz`, 1745 LOC) *alongside* a kind=3 `$poll` effect machine is a category error: two implementations of "suspend this function and resume it later." The effect system's one-line claim — *universal foundation for non-local control flow* — is false if generators opt out. Phase 4 Path B makes the claim true at the foundation.

**Concrete new capabilities unlocked by B** (none of which are available on the state-machine path without per-feature extensions):

1. **Modular yield helpers**: `def emit_pair(a, b): Void can Yield<Int> { yield a; yield b }` callable from a generator body.
2. **Effect composition**: generators compose with Throws, State, Reader, user-defined effects via row polymorphism instead of ad-hoc state-machine flags.
3. **Multi-shot** (Phase 4b, when scheduled): extends naturally from kind=3 under frame-clone discipline. Under the state-machine path it's a rewrite per feature.
4. **Cleaner `for-in` story**: one desugar rule (synthesize `with Yield { ... } do -> ... end`) instead of separate Vec/Map/Range/String/AsyncIterator cases.

## 2. Current state (what already exists)

Good news — the migration is more mechanical than it first appears because the kind=3 infrastructure *is already in the same file* as the generator state machine, and they already share primitives.

**Shared infrastructure** (stays):

- `mir_lower_gen.qz::mir_emit_kind3_perform_suspend(ctx, op_name, eff_name, args)` — the kind=3 perform lowering. Already used by Async's await/spawn/suspend/yield. This is the entry point NODE_YIELD will route to.
- `@__qz_effect_current_cont_frame` TLS slot — identifies the continuation frame across perform/resume.
- `@__qz_effect_park_rv` TLS slot — carries POLL_READY / POLL_SUSPENDED / park-encoding between poll invocations.
- `__qz_effect_resume_cont` runtime helper — re-enters a continuation's `$poll` on handler `resume(v)`.
- $poll state-machine discipline: `frame[0]`=state discriminant, `frame[1]`=result slot, `frame[2]`=poll_fn pointer, `frame[3..]`=locals.
- Effect-stack runtime (`__qz_effect_stack_*` arrays, 256-cap), install/perform/uninstall ABI. Handles both `with E { op: h } do ->` installs and the D.4 blessed-relaxation prelude defaults.

**Separate infrastructure** (gets deleted at end of migration):

- `mir_lower_gen.qz::mir_lower_generator` (line 787+, ~500 LOC) — the "$next state machine" for generators. Emits a constructor + `$next` step function with its own frame layout, resume labels, and yield-counter discipline.
- `_gen_active` module-global + `_gen_frame_var` / `_gen_local_names` / `_gen_local_offsets` / `_gen_yield_counter` / `_gen_resume_blocks` — duplicates what `mir_emit_kind3_perform_suspend`'s existing context provides.
- `_generator_func_names` / `_async_gen_func_names` registries — replaced by the general `_suspendable_funcs` registry already used for async.
- NODE_YIELD's two typecheck paths (`typecheck_walk.qz:1795` and `:3122`) — collapse to one that checks `can Yield<T>` in the current function's effect row.
- QZ0170 ("yield can only be used inside a generator function") — replaced by standard `QZ0611` effect-op-not-handled when yield isn't in the caller's row.
- `for-in`'s AsyncIterator special case (F.3c, typecheck_walk.qz:3344) — generalizes to "iterator synthesizes `with Yield do ->`" for all generator shapes.

**Surface syntax** (unchanged — this is the whole point):

```quartz
def three_values(): impl Iterator<Int>
  yield 1
  yield 2
  yield 3
end

for x in three_values()
  puts(x.to_s())
end
```

The 23 tests in `spec/qspec/generator_spec.qz` and all AsyncIterator specs keep passing verbatim.

## 3. Target architecture

### 3.1 Semantic model

A function whose return-type annotation starts with `impl Iterator<T>` or `impl AsyncIterator<T>` is a **generator**. At typecheck:

- Its effect row is implicitly extended with `Yield<T>` (labelled just `"Yield"` in the row — the `<T>` erases at the row level, matching `State<S>` / `Reader<R>` / `Throws<E>` convention).
- For `impl AsyncIterator<T>`: row also includes `Async`.
- `yield v` inside the body is resolved as `perform Yield.yield(v)` — a kind=3 op.

At MIR lowering:

- Generator functions undergo the same `$poll` transform as async functions (the existing `_suspendable_funcs` path). No separate `mir_lower_generator` entry.
- `NODE_YIELD` lowers to `mir_emit_kind3_perform_suspend(ctx, "yield", "Yield", [v])`. The rest of the state-machine suspension (state label, local spill, %self write) is the same mechanism async has used since P3.0c.

At consumer sites:

- `var stream = gen()` — calling a generator function allocates its $poll frame and returns a `Stream<T>` handle. No body execution yet.
- `stream.next()` — invokes the handle's internal `with Yield { yield: capture } do -> poll_fn(frame, 0) end`. First `yield` in the body triggers capture, which stashes v into the Stream's outgoing slot, sets `@__qz_effect_park_rv = POLL_SUSPENDED`, and returns 0 to the handler. The outer `poll_fn` sees the park value and returns POLL_SUSPENDED to `.next()`, which reads the outgoing slot and returns `Some(v)`. Subsequent `.next()` calls re-enter `poll_fn` at the post-yield state label.
- `for x in gen() { body }` — desugars to `{ var _g = gen(); loop { match _g.next() { Some(x) => body; None => break } } }`.

### 3.2 Consumer-drive kind=3 — the one ABI extension

Today's kind=3 is **handler-driven**: the handler calls `resume(v)` to re-enter the caller's $poll. For generators, the handler does NOT call resume — it stashes the yielded value and returns, which today causes a kind=2-style unwind (caller frame is dropped).

Generators need a third handler outcome: **suspend without unwind**. The caller's frame must park at post-yield state so subsequent polls resume there. The existing P3.E-runtime mechanism (`__qz_effect_park_rv` TLS) already has the protocol — we just name the new sentinel:

| Handler action | TLS `park_rv` value | Outer $poll return |
|---|---|---|
| Calls `resume(v)` synchronously | POLL_READY (1) | Body's final value (existing P3.0c) |
| Calls `__qz_effect_park(fd)` | `-(fd+2)` | Park-on-fd (existing P3.E-runtime) |
| Returns without resume | (default POLL_READY) | Handler's return value (kind=2 unwind, existing F.3b) |
| **Generator yield** (new) | **POLL_SUSPENDED (0)** | **POLL_SUSPENDED, caller re-enters via next poll** |

The Stream `.next()` handler for yield is essentially:
```llvm
; Pseudo-LLVM for the yield handler Stream.next() installs
%v = load i64, ptr %argv, i64 0
store i64 %v, ptr %stream_outgoing_slot
store i64 0, ptr @__qz_effect_park_rv  ; POLL_SUSPENDED
ret i64 0
```

And the outer $poll's post-perform epilogue:
```llvm
%pv = load i64, ptr @__qz_effect_park_rv
; POLL_READY (1) → body continues post-perform (fall-through to resume block)
; POLL_SUSPENDED (0) → ret i64 0, caller re-polls at same state next time  ; NEW
; Negative (park encoding) → ret %pv, scheduler parks
```

**This is not a new TLS slot, not a new array, not a new handler ABI.** It's a reinterpretation of the existing `park_rv` sentinel: `0` = "suspend, re-enter from same state." Today no path uses 0 as a positive value; we're filling a reserved sentinel slot.

### 3.3 `Stream<T>` shape

```quartz
struct Stream<T>
  priv frame: CPtr      # heap-allocated $poll frame
  priv poll_fn: CPtr    # generator's poll_fn (frame[2] mirror)
  priv outgoing: Int    # most recent yielded value (written by install'd handler)
  priv done: Int        # 1 once poll returns POLL_READY
end

def Stream.next(self: Stream<Int>): Option<Int>
  if self.done == 1
    return None
  end
  with Yield { yield: _yield_capture_for(self) } do ->
    var rv = invoke_poll(self.frame, 0)
    if rv == POLL_READY
      self.done = 1
      return None
    end
    return Some(self.outgoing)
  end
end
```

`_yield_capture_for(self)` is a compiler-synthesized handler bound to the Stream instance. Under the hood it's the inline-LLVM stub above. The `with Yield { ... } do ->` is what makes the effect declaration in `std/gen.qz` load-bearing — `.next()` is the sole install site.

**Implementation reality**: `Stream<T>` is trivially a two-word struct (frame ptr + poll_fn ptr are the two actual fields; `outgoing` / `done` live in the frame itself at known offsets). The typechecker-side struct is a thin wrapper; codegen elides it.

### 3.4 `for-in` desugar — one rule

Today (`typecheck_walk.qz:3344-3375`) has a hardcoded check for `impl AsyncIterator<` that widens caller's row with `Async`. This becomes ONE general rule:

- If the iterator source's type is `impl Iterator<T>`: synthesize `with Yield { yield: into_stream } do -> loop body end`. Consumer doesn't widen its row (Yield is handled locally).
- If it's `impl AsyncIterator<T>`: same, plus widen caller's row with `Async` (because polling an async iterator suspends). Existing F.3c logic, now threaded through the same desugar.
- Vec/Map/Range/String iteration: unchanged (they already have dedicated `mir_lower_iter.qz` paths).

### 3.5 AsyncIterator unification

`AsyncIterator<T>` = `Iterator<T> + Async`. In effect-row terms: a function returning `impl AsyncIterator<T>` has `can Yield<T>, Async` on its row. The for-in handler still does `with Yield do ->`, but the body runs under `can Async`, so any nested `await` / `suspend` just works. No separate `NODE_FOR_AWAIT` needed — `for x in async_src` vs `for await x in async_src` collapse to the same desugar (the row on the source determines the caller's widening).

F.3c's spec (`effect_poly_for_in_f3c_spec.qz`) stays green; the implementation path is the general rule, not a special case.

## 4. Migration plan

Adapted from the Phase 5 three-pass playbook. Each phase commits independently, fixpoint-green, smoke-tests pass, relevant spec runs green.

Golden backups per Rule 1: save `quartz-pre-p4b-<phase>-golden` before each MIR/codegen milestone.

### 4.B.1 — Design commit (this memo)

Just this memo + kickoff-doc scope-reset. No code.

### 4.B.2 — Typechecker: `impl Iterator<T>` / `impl AsyncIterator<T>` → `can Yield` on function's row

- Extend `tc_attach_func_effect_row` (typecheck.qz:4507): after the existing `can` clause handling, inspect return-type ann. If it starts with `impl Iterator<` or `impl AsyncIterator<`, add `Yield` to the row labels (creating the row if none existed). `impl AsyncIterator<` also adds `Async`.
- Delete `tc.reserved[0]` generator-scope flag; replace `QZ0170` with the standard QZ0611 path (yield op not in row → same error users get for unhandled Log/Throws).
- Spec: `generators_p4b_typecheck_spec.qz` — verify `--dump-effect-rows` on `def three_values(): impl Iterator<Int>` shows `Yield` in labels. Verify `def emit_pair(a, b): Void can Yield<Int>` typechecks (modular helper signatures). Verify QZ0611 fires for `yield` outside any `can Yield` / `with Yield` scope.
- Existing `generator_spec.qz` may need a `can Yield<Int>` addition to any test that currently calls `yield` from a non-`impl Iterator` function — audit required. If none, unchanged.
- Fixpoint + smoke. No MIR changes yet — NODE_YIELD still routes to old path.

Flag gate: **none needed**, because the old MIR path consumes NODE_YIELD regardless of typecheck row.

### 4.B.3 — MIR: route NODE_YIELD through `mir_emit_kind3_perform_suspend`

**Flag-gated**: add `--piezo-gen-b` flag. Default off.

- When flag on, `mir_lower.qz:2449` routes `NODE_YIELD` to `mir_emit_kind3_perform_suspend(ctx, "yield", "Yield", [v])`.
- Generator functions (return type `impl Iterator<T>`) enter the existing async `$poll` transform instead of `mir_lower_generator`. The `_suspendable_funcs` registry generalizes — any function with `Yield` in its row becomes $poll-ified.
- Kind=3 handler ABI needs the POLL_SUSPENDED sentinel path added to the outer-$poll epilogue (§3.2). This is a `mir_emit_kind3_perform_suspend` change: after `park_rv = __qz_effect_park_get_rv()`, branch on `park_rv == 0` → ret 0 (suspend), else existing ret path.
- Save `quartz-pre-p4b3-golden` before starting.
- Acceptance: hand-written test — generator body that yields through `perform Yield.yield(v)`, installed handler captures values into a vec, consumer calls `.next()` multiple times and sees each yield. Does NOT go through the `impl Iterator<T>` surface yet.
- Fixpoint + smoke. Both old (flag off) and new (flag on) paths green on `generator_spec.qz`.

### 4.B.4 — `Stream<T>` struct + `.next()` in std/gen.qz

- `std/gen.qz` adds `struct Stream<T>` + `Stream.next(self): Option<Int>` + compiler-synthesized `_yield_capture` handler.
- The generator function's constructor now allocates + returns a `Stream<T>` instead of a bare frame pointer.
- Flag-gated. Off path unchanged.
- Spec: `generators_p4b_stream_spec.qz` — `var s = gen(); s.next() == Some(1); s.next() == Some(2); s.next() == None`.

### 4.B.5 — `for-in` desugar unification

- Extend the for-in desugar (`mir_lower_stmt_handlers.qz` + typecheck side) to synthesize `with Yield { yield: into_outgoing_slot } do -> loop body end` when source is `impl Iterator<T>`. AsyncIterator inherits the existing Async widening but through the same desugar.
- Flag-gated.
- Acceptance: every existing `for x in gen()` test in `generator_spec.qz` passes under `--piezo-gen-b`.

### 4.B.6 — Flag flip (make B the default)

- Remove `--piezo-gen-b` gate from all four prior phases. The effect path becomes the sole path.
- Golden: `quartz-pre-p4b6-flag-flip-golden`.
- Fixpoint + cache-enabled self-compile (cold + warm) + smoke + full `quake qspec` sweep. Any regression blocks.

### 4.B.7 — Delete `mir_lower_generator` and dead scaffolding

Only after 4.B.6 is green.

- Delete `mir_lower_generator`, `_gen_active`/`_gen_frame_var`/`_gen_local_names`/etc module-globals (the ones not shared with kind=3).
- Delete `_generator_func_names` / `_async_gen_func_names` registries (replaced by `_suspendable_funcs`).
- Delete the two NODE_YIELD typecheck paths in favor of a single effect-op resolution.
- Delete `QZ0170`.
- Delete the F.3c hardcoded `impl AsyncIterator<` special case (folded into general rule at 4.B.5).
- Net LOC: estimated -800 to -1200 (the mir_lower_gen generator-specific scaffolding, minus the handful of lines added to route through kind=3).
- Fixpoint + smoke + full qspec.

### 4.B.8 — Modular yield helpers (the new capability)

- Acceptance spec: `generators_p4b_modular_helpers_spec.qz` — `def emit_pair(a, b): Void can Yield<Int>` callable from `def my_gen(): impl Iterator<Int>`, each helper call yields multiple values observed by the consumer's `.next()`.
- This is the "free" feature B buys us. It's where the investment returns capability users didn't have.

### 4.B.9 — Effect composition tests

- Generator + Throws: `def parse_tokens(src): impl Iterator<Token> can Throws` — yields tokens; throws on invalid input. Caller catches via `with Throws`.
- Generator + State: `def enumerate<T>(it: impl Iterator<T>): impl Iterator<(Int, T)> can State` — stateful index counter via State<Int>.
- Row-polymorphic combinator: `def map<ε, A, B>(src: impl Iterator<A>, f: Fn(A): B can ε): impl Iterator<B> can ε` — sync analog of existing async `stream_map`.
- Spec: `generators_p4b_effect_composition_spec.qz`.

### 4.B.10 — Retrospective

- `docs/design/PHASE_4_GENERATORS_RETRO.md`: what we built, what surprised us, what we'd do differently. Sized one page, one session.
- Archive `piezo-phase-4-kickoff.md` + this memo + the research doc under `docs/handoff/done/`.
- File Phase 4b (multi-shot / Ndet) as a separate research pass per the original kickoff.

## 5. Risks + kill criteria

1. **POLL_SUSPENDED sentinel collision.** If any existing `park_rv == 0` path fires today for a non-suspend reason, the new semantics break it. Mitigation: exhaustive grep of `__qz_effect_park_rv` reads before 4.B.3. Kill if conflict found; redesign sentinel encoding.
2. **Generator $poll re-entry from consumer.** Today's kind=3 assumes scheduler-driven resume — the scheduler invokes `poll_fn(frame, 0)` itself. Consumer-driven `.next()` does the same call, but the `@__qz_effect_current_cont_frame` TLS discipline may need verification that it's not clobbered across consumer-thread reentries. Surface in 4.B.3. Mitigation: audit + possibly add consumer-drive save/restore pair.
3. **AsyncIterator parity regression.** `effect_poly_for_in_f3c_spec.qz` is load-bearing for the effects-epic story. Any regression there is a Phase-4 kill criterion. Mitigation: spec run at every commit, not just fixpoint.
4. **`for-in` desugar interaction with Vec/Map/Range.** The non-generator iteration paths must not be disturbed. Mitigation: `collection_iterators_spec.qz`, `cross_iter_match_spec.qz`, `codepoint_iter_spec.qz` all regression-checked.
5. **Multi-op effect handler scope.** `Stream.next()` installs a `with Yield { yield: h }` — nested generators (generator calling generator) need H-delegate semantics (P3.H shipped Apr 20). Already in place; just needs verification.
6. **LOC / timeline.** Estimated 2-3 quartz-weeks (~10 commits, 2-3 sessions per large phase). If any phase exceeds 2 sessions of debug, pause + reassess scope. Kill criterion: if 4.B.3 or 4.B.5 requires > 800 LOC of new MIR beyond routing, reconsider whether the existing infrastructure was as shareable as this memo claims.

## 6. Discipline (non-negotiable)

From the Phase 5 playbook + Bootstrap Island incident + CLAUDE.md:

- **Golden backups per attempt**: `quartz-pre-p4b<N>-golden` before every MIR/codegen milestone. NEVER overwrite.
- **`quake guard` before every commit**: fixpoint verified, binary + stamp staged. No `--no-verify`.
- **Rule 2 smoke tests** (`style_demo.qz` + `brainfuck.qz`) after every rebuild. Fixpoint alone is insufficient.
- **Cache-enabled self-compile** (cold + warm, `rm -rf .quartz-cache` between) after any MIR/codegen change — especially 4.B.3, 4.B.5, 4.B.6.
- **Full `quake qspec` run** at 4.B.6 (flag flip) and 4.B.7 (deletion). Targeted specs elsewhere.
- **Incident-ledger awareness** (EFFECT_MIGRATION_PLAYBOOK.md §3): body-wrap last-stmt rule; cache pollution across binaries; `replace_all` helper-body hazard; effect-stack cap (256, we're nowhere near); shadow customization.

## 7. What this memo does NOT decide

- Phase 4b (multi-shot / Ndet): still deferred. After 4.B.10, a separate research pass evaluates pull-in timing based on observed kind=3 invariants.
- Bidirectional generators (`send(v)` per PEP 342): deferred per original kickoff §5.6.
- Stream fusion optimization (Coutts-Leshchinskiy-Stewart 2007): filed under "if benchmarks show >3× overhead vs plain loop, implement." Not blocking.
- Concrete `Stream<T>` public API surface (combinators beyond `.next()` — `.map`, `.filter`, `.take`, etc.): kickoff §4a.6 listed these. Implementing them post-4.B.7 is trivial under the effect model; surface decisions (naming, fluent vs free functions) deferred to 4.B.9.

## 8. References

- Leijen 2017/2020 — *Structured asynchrony with algebraic effects* / *Effect handlers, evidently* (JFP).
- Dolan, White, Sivaramakrishnan 2021 — *Retrofitting effect handlers onto OCaml*.
- Brachthäuser, Schuster, Ostermann 2020 — *Effects as capabilities* (Effekt).
- Lindley, McBride, McLaughlin 2017 — *Do be do be do* (Frank).
- Coutts, Leshchinskiy, Stewart 2007 — *Stream fusion: from lists to streams to nothing at all*.
- `docs/research/PHASE_4_NONDET_GENERATORS_RESEARCH.md` — upstream research synthesis.
- `docs/design/P3_0_KIND3_CPS.md` — the kind=3 continuation model this migration builds on.
- `docs/design/EFFECT_MIGRATION_PLAYBOOK.md` — discipline + incident ledger.
