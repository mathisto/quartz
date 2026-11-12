# Phase 4D — Row-polymorphic Stream consolidation

> **Epic**: Operation Piezoelectric Effects · `[piezo]` · Phase 4 followup
> **Status**: Design — implementation queued for next session.
> **Filed**: 2026-04-25, on Phase 4 (Path B, generators-via-effects) closure.
> **Naming**: 4D, not 4c — the original Phase 4c "Effect-polymorphic generators (~1-2 quartz-days)" was actually delivered by Phase 4.B.9.1 (Yield + Throws / Yield + State composition); the work below is a separate followup. The retro frames it as "row-poly Stream consolidation" without a phase letter; calling it 4D keeps the Phase-4 prefix while making clear it's a distinct piece.
> **Predecessors**:
> - [`PHASE_4_GENERATORS_RETRO.md`](PHASE_4_GENERATORS_RETRO.md) §4 (the open-followup that filed this work)
> - [`P3_F_ROW_POLYMORPHISM.md`](P3_F_ROW_POLYMORPHISM.md) (the row-var infrastructure 4D builds on)
> - [`PHASE_4_GENERATORS_VIA_EFFECTS.md`](PHASE_4_GENERATORS_VIA_EFFECTS.md) (Path B design memo)

## Motivation

Phase 4 unified `yield v` lowering: every yield routes through `perform Yield.yield(v)` on the kind=3 `$poll` substrate. Sync `impl Iterator<T>` generators and async `impl AsyncIterator<T>` generators share the same MIR lowering for the body, the same `_gen_active = 2` discriminant, and the same `__Future_<name>$poll` symbol shape. **What still differs** is the consumer side:

| | Sync `impl Iterator<T>` | Async `impl AsyncIterator<T>` |
|---|---|---|
| Constructor function in registry | `_generator_func_names` | `_async_gen_func_names` |
| `for v in src` desugaring | `Stream$next` loop with `with Yield { yield: __qz_gen_yield_capture }` install | `lower_async_gen_iteration` (legacy frame[1] reader, no Yield install) |
| `for await v in src` desugaring | n/a | Same as above (forced) |
| Stream value type | `Stream<T>` | n/a — async generators don't have a value-type wrapper |
| Caller's effect row | clean | widened by `Async` (F.3c special case at `typecheck_walk.qz:3411`) |

The runtime registries (`_async_gen_func_names`, `_generator_func_names`) are the *only* signal distinguishing the two paths. They exist because the type system has no way to express "this generator's `next()` widens caller by `{Async}`" at the value level.

The retro (§4) calls out four cleanup items blocked on this gap:

1. Consolidate `mir_lower_async_generator` into `mir_lower_generator_effect` + `mir_lower_async_poll`.
2. Delete `_async_gen_func_names` registry.
3. Fold F.3c AsyncIterator row-widening into the general for-in rule.
4. Delete QZ0170 + `tc.reserved[0]` + channel 1 of `_tc_p4b_yield_in_scope`.

Plus async-gen + helper-yield interleaving (`def emit_pair(a, b): Void can Yield<Int>` callable from `def my_gen(): impl AsyncIterator<Int>`) which silently mis-interleaves today, depending on the same unification.

End-state: **one** generator lowering, **one** for-in desugaring, **zero** runtime registries. The static type of a generator-returning function carries its effect row; consumers read the row from the type, not from a name lookup.

## What's already built

P3.F shipped row-variable infrastructure for **functions** (Apr 21 2026, commits `a37efbde`…`2001e0f8`):

- `func_row_var_names: Vec<String>` + `func_row_var_ids: Vec<Int>` on TypecheckState — reset per-function in `tc_func_row_var_env_reset` (`typecheck.qz:2827, 4362`).
- `tc_attach_func_effect_row` (`typecheck.qz:4507`) consults the env before falling back to `tc_erv_fresh`.
- `tc_set_func_generalized_ervs` / `tc_set_trait_generalized_ervs` for call-site instantiation (`typecheck.qz:2939, 4501`).
- `tc_row_instantiate_for_call` reads the ORIGINAL tail (not walked — critical for multi-site polymorphism).
- Trait method row storage: `trait_method_effect_rows: Vec<Vec<Int>>` parallel to method names (F.3a).
- `impl Trait<T> can e` parses cleanly in param positions (F.3b).
- F.3c — bare `for v in src` reads the iterator's row from a runtime registry and widens caller by `{Async}` if the iterator is async-typed (`mir_lower_stmt_handlers.qz:1056`, `typecheck_walk.qz:3411`).

Phase 4 confirmed substrate is ready:

- `_gen_active` is **2-valued** post-4.B.7.b (0 or 2). Both sync and async generators set `_gen_active = 2` and route NODE_YIELD through kind=3. The retro's "4-valued" claim is stale source-comment; verified empirically (`mir_lower_gen.qz:42-46` claims 2-value, line 1007 sets 2 in `mir_lower_async_generator`).
- `__Future_<name>$poll` poll-fn shape is identical across sync `impl Iterator`, async `impl AsyncIterator`, and async fn `$poll`.
- Consumer-drive `Stream.next()` (`std/gen.qz:75-87`) installs `with Yield { yield: __qz_gen_yield_capture } do -> step(frame) end`; the same install pattern applies to async iteration consumers if Stream's row matches.

The substrate gap is at the **value-type API**: Stream<T> is a struct, and structs have no row-var support today.

## The gap

`tc_register_struct` (`typecheck.qz:2655`) stores type-parameters as a comma-separated `String`:

```quartz
var type_params_raw = ast::ast_get_str2(ast_storage, node)   # e.g., "<T>"
var type_params = ...strip-angle-brackets...                 # e.g., "T"
typecheck_registry::tc_register_struct(tc, name, ..., type_params, ...)
```

`type_params` is a single `String` — there is no kind information per param (type vs row var). `tc_is_type_param(name, tp_clean)` does a string match against the comma-split list. The struct registry has eight parallel vecs (`struct_field_names`, `struct_field_types`, `struct_type_params`, `struct_field_annotations`, `struct_is_linear`, `struct_field_defaults`) — none carry per-param kind metadata.

To support `struct Stream<T, e>` where `T` is a type var and `e` is a row var:

1. Per-struct row-var env (parallel to function-level `func_row_var_names`).
2. Detection at registration: lowercase-first param names → row vars, uppercase → type vars.
3. Field-type parsing: `Fn(CPtr): Int can e` inside a struct's field annotation must resolve `e` from the struct's row-var env (today this would land in `tc_attach_func_effect_row` against an empty function-level env and fail-silently as a fresh erv).
4. Method-def integration: `def Stream.next<T, e>(self: Stream<T, e>): Option<T> can e` must unify the method's row-var `e` with the struct's row-var slot — this is the call-site instantiation half.
5. Use-site instantiation: `var s: Stream<Int, e>` parses + checks that `e` resolves to a row in the enclosing function's scope.

None of these exist today. F.1 covers the function-level analogues; the struct-level lift is fresh code.

## Design

### Three options surveyed

#### Option A — Struct-level row-var (recommended)

Add row-var support to struct generics, mirroring F.1's function-level model. `Stream<T, e>` carries a phantom row variable; method `def Stream.next<T, e>(self: Stream<T, e>): Option<T> can e` propagates it.

**Pros**:
- Single Stream<T, e> type covers sync (`e = {}`) and async (`e = {Async}`).
- Future row-poly value types (Channel, Receiver, Reader<W>, etc.) get the lift for free.
- Deletes both runtime registries.
- Folds F.3c special case into the general for-in rule.
- Matches Koka, Effekt, Frank treatment of effect-typed values.

**Cons**:
- Genuine new typecheck infrastructure (~250-400 LOC).
- Struct-method row-var unification is a new code path to verify.

#### Option B — Separate `AsyncStream<T>`

Two structs:

```quartz
struct Stream<T> ... end
def Stream.next(self: Stream<T>): Option<T>

struct AsyncStream<T> ... end
def AsyncStream.next(self: AsyncStream<T>): Option<T> can Async
```

**Pros**:
- No struct-row-var lift required — uses existing infrastructure.
- Smallest code delta.

**Cons**:
- Two value types, two `.next()` methods, two for-in desugarings.
- Doesn't fold F.3c special case — instead replaces "is in registry?" with "is the static type AsyncStream?" Marginal cleanup.
- Stream combinators (`stream_map`, `stream_filter`) need dual versions OR both Stream and AsyncStream impl a unified Iterator<T, e> trait — at which point Option A's infrastructure is needed anyway, just gated behind the trait.
- Doesn't generalize to other future row-poly value types (Channel<T, e> for synchronous-vs-async channels, Reader<W, e> for blocking-vs-async file reads).

Rejected: shifts the code-elimination win without cementing the foundation.

#### Option C — Runtime-tracked row inference

The compiler stores, at the typechecker, which generator-fn produced a Stream value, and looks up its row at every `.next()` call site. No type-level row var.

**Pros**:
- No syntax change. Stream stays `Stream<T>`.

**Cons**:
- Loses information at any value-flow boundary (assignment, return, vec push). The moment a Stream is stored in a `Vec<Stream<T>>` the compiler can't know the originating fn anymore.
- Fragile — adding new combinators means teaching them to thread the inference manually.
- No analog in any researched effect system; novel-and-complicated is the wrong direction per PD2.

Rejected: not a real design, just a hidden form of Option A's information without the type-level guarantee.

### Recommendation: Option A

Per PD1 (highest-impact) and PD2 (design the full correct solution): Option A is the load-bearing investment. It costs ~3-5 quartz-days vs Option B's ~1-2, but it cements struct-level row-var infrastructure that future row-poly value types will need (Channel, Reader, etc. — see §7). Option B trades infrastructure debt for a marginal short-term win and doesn't actually fold F.3c.

### Naming convention (extends F.1)

F.1 locked: lowercase-first generic name = row var, uppercase = type var. Same rule applies to struct generics:

```quartz
struct Stream<T, e>      # T type var, e row var
struct Channel<T, e>     # same
struct Box<T>            # only type var
struct Reader<W, e>      # W is a Writable bound, e is row
```

No new sigil, no new keyword.

### Stream.next call resolution

```quartz
struct Stream<T, e>
  frame: CPtr
  step: Fn(CPtr): Int       # NB: Fn type doesn't need `can e` because step's
                            # effects are already discharged by the kind=3 dispatch
                            # at the install site. The struct-level e is for the
                            # method body's effect declaration.
end

def Stream.next<T, e>(self: Stream<T, e>): Option<T> can e
  var f = self.step
  var rv = with Yield { yield: __qz_gen_yield_capture } do -> f(self.frame) end
  if rv == 1
    return Option::None
  end
  return Option::Some(__qz_gen_take_stashed())
end
```

A pure caller binds `e = {}`; the method body widens caller by `{}` (no-op). An async caller binds `e = {Async}`; the method body widens caller by `{Async}`. Same body, same kind=3 dispatch, no runtime registry.

The `step` field's function type (`Fn(CPtr): Int`) does **not** need a `can e` annotation because the step function is the kind=3 `$poll` body itself — its effects are dispatched through the kind=3 install/perform machinery, not propagated through the function-pointer call. This is the same reason `Fn(CPtr): Int` works today for both sync and async generators.

### Generator-function return-type row inference

Today: `def gen(): impl Iterator<Int>` returns `Stream<Int>`. Async: `def gen(): impl AsyncIterator<Int>` returns... actually returns the async-gen frame directly (no value-type wrapper).

Post-4D: `def gen(): impl Iterator<Int>` infers return type `Stream<Int, {}>`. `def gen(): impl Iterator<Int> can Async` infers return type `Stream<Int, {Async}>`. The row in the return type comes from the function body's inferred row (same machinery that already drives `tc_attach_func_effect_row`).

`impl AsyncIterator<T>` retires as a surface form — it becomes `impl Iterator<T> can Async`, parsed equivalently by F.3b's `impl Trait can e` grammar. The two surface forms can coexist for one fixpoint cycle for migration cleanliness, then `impl AsyncIterator<T>` is deleted entirely.

### For-in desugaring (single rule)

```quartz
for v in src
  body
end
```

Desugars to (pseudocode):

```quartz
var __s = src   # __s : Stream<T, e> for some e inferred at this site
loop
  match __s.next()
    Some(v) => body
    None => break
  end
end
```

Caller's effect row widens by `e` exactly once (at the `__s.next()` call). No special case for async. F.3c's runtime registry consult deletes; the static type of `__s` carries the row.

`for await v in src` keeps parsing for source-compat but desugars identically. Optionally retire it post-migration; not load-bearing for 4D.

### Generator lowering consolidation

`mir_lower_async_generator` and `mir_lower_generator_effect` differ in:

- Frame layout: async has 6 reserved slots (state, result, poll_fn, cancel_token, task_id, park_state), sync has 3 (state, result, poll_fn). Consolidation keeps the wider 6-slot layout — costs 24 bytes per frame on sync generators, simplifies lowering. Acceptable given Phase 4.B.9 already wires `mir_gen_register_dynamic_local` + `GEN_FRAME_PADDING = 32` for both paths.
- Registry append: `_async_gen_func_names.push(name)` vs `_generator_func_names.push(name)`. Both get deleted in 4D.6; intermediate state pushes to one unified registry that's also deleted at the end.
- `_gen_active = 2` set by both — already unified post-4.B.7.b.

The body lowering is structurally identical post-4.B.7.b. The merge is mostly mechanical (move async-specific frame-init code into `mir_lower_generator_effect`, gate on whether the function's row contains Async).

## Implementation phases

### 4D.1 — Struct row-var infrastructure (~1 quartz-day)

**Goal**: `struct Foo<T, e>` parses and registers correctly; `e` is a row var, `T` is a type var, distinguishable at every consult site.

**Changes**:
- `typecheck_registry.qz`: add `struct_row_var_names: Vec<String>` and `struct_row_var_ids: Vec<Int>` parallel to `struct_type_params`. Per-struct, not per-call.
- `tc_register_struct_def` (`typecheck.qz:2655`): split `type_params` string by comma; for each name, lowercase-first → allocate fresh `tc_erv_fresh`, append to row-var vecs; uppercase-first → append to type-var portion. Store both kinds.
- `tc_struct_row_var_env_reset(struct_idx)` helper that loads the struct's row-var env into `tc.func_row_var_*` for the duration of struct-method body checks.
- `tc_check_struct_field_types`: when parsing a field annotation that contains `can <name>`, consult both function-level AND struct-level row-var envs.
- `tc_struct_type_param_kind(struct_idx, param_index): Int` returning 0 (type) or 1 (row).

**Verify**: trivial spec `struct Foo<T, e>` declaration + retrieval of param kinds. No method impls yet — just the registration shape.

**Risk**: struct registration runs in Phase 4.0 of `compile()` (lines ~510-660), BEFORE the State install at line 682. Per the P5.2.f Option Z lesson (`feedback_state_cascade_runtime_fail`), can't add `can State` without widening the install. For 4D.1 we don't need can State — but watch for the same pitfall if later phases want to thread anything through registration.

**LOC estimate**: ~150 LOC.

### 4D.2 — Stream<T, e> redesign (~0.5 quartz-day)

**Goal**: `std/gen.qz` declares Stream with row-var; `Stream.next` is row-polymorphic.

**Changes**:
- `std/gen.qz`: change `struct Stream<T>` to `struct Stream<T, e>`; change `def Stream.next(self: Stream<Int>): Option<Int>` to `def Stream.next<T, e>(self: Stream<T, e>): Option<T> can e`. The body is unchanged (the kind=3 install pattern works for both rows).
- Existing `Stream<Int>` usages: now write `Stream<Int, {}>` for explicit pure or rely on inference. Probably no changes needed in user code if inference covers it.

**Verify**: spec — pure generator + Stream.next round-trips Some/None; async generator → Stream<Int, {Async}>; pure caller of pure Stream.next sees no row widening; async caller of async Stream.next sees `can Async` widening.

**Risk**: `__qz_gen_yield_capture` is a free function, not a method — no row-var threading needed. The `with Yield { ... }` install is identical for both rows.

**LOC estimate**: ~30 LOC source + ~80 LOC spec.

### 4D.3 — Generator-function return-type row inference (~0.5 quartz-day)

**Goal**: `def gen(): impl Iterator<Int>` infers `Stream<Int, {}>`; `def gen(): impl Iterator<Int> can Async` infers `Stream<Int, {Async}>`.

**Changes**:
- `tc_function`: when the return type is `impl Iterator<T>`, after the body row is finalized, synthesize the return type as `Stream<T, function_body_row>`. The body row has already been computed by `tc_attach_func_effect_row` at signature time; this just builds the concrete Stream<T, row> type for the constructor's return.
- `mir_lower_generator_effect` (and `mir_lower_async_generator` in the transition): emit the constructor returning `Stream<T, e>` (semantically — runtime ABI is unchanged, just an i64).
- Keep `impl AsyncIterator<T>` as a parser alias for `impl Iterator<T> can Async` for one fixpoint cycle, then delete.

**Verify**: spec — `def my_gen(): impl Iterator<Int>` and `def my_async_gen(): impl Iterator<Int> can Async` both compile, both consumable via `for v in src`, both widen caller correctly.

**LOC estimate**: ~80 LOC.

### 4D.4 — Fold F.3c into general for-in rule (~0.5 quartz-day) — PARTIALLY SHIPPED `01e6203f`

**Goal**: `for v in src` desugars uniformly. F.3c's runtime-registry consult deletes.

**What shipped (`01e6203f`)**:
- `mir_lower_stmt_handlers.qz:1056-1086`: F.3c MIR fast-path block DELETED. The fast-path's two early-exits (NODE_CALL of async gen, NODE_IDENT typed `impl AsyncIterator<`) were duplicated inside the regular collection-iteration branch (~1286, ~1308). Falling through produces identical lowering. Pure dedup, zero IR difference.

**What's deferred to a follow-on phase (Phase 4D.4d)**:
- `typecheck_walk.qz:3411`: F.3c typecheck row-widen-on-async-iterator KEPT. For-in's typecheck currently widens caller's row by reading the iter source's annotation string ("impl AsyncIterator<"). To delete cleanly, for-in needs to also detect `Stream<T, body_row>` static types on the iter source (NODE_IDENT and NODE_CALL cases). 4D.4c added the detection for `.next()` UFCS calls, but for-in doesn't desugar to `.next()` at typecheck time — needs a parallel check inside `tc_stmt`'s NODE_FOR handler. Also requires parameter Stream<T, e> coverage (today only var bindings pick up the synthesized ptype; parameter types parse via tc_parse_type which returns bare TYPE_STRUCT for "Stream<T, e>" annotations).
- `for await v in src` deprecation warning: not in scope; for-await still parses and works identically. Retire when usage drops to zero.

**Verify (shipped)**: 19-spec generator/iterator/effect sweep, 17/19 pass — 2 pre-existing failures (async_iterator subprocess timeout, generator nested-while-yield bug per retro §4) preserved unchanged. effect_poly_for_in_f3c_spec.qz green throughout.

**Risk-discharged (shipped scope)**: no consumer code paths affected. The runtime registries `_async_gen_func_names` and `_generator_func_names` are still live (consulted at 1286-1322 and 184/193); their deletion arrives with 4D.5's consolidation.

**LOC delivered**: ~30 LOC delta (deletions + clarifying comment).

### 4D.4b — Stream<T, body_row> ptype synthesis (substrate) — SHIPPED `77f84be0`

**Goal**: `tc_function` upgrades a generator function's registered return type from the bare TYPE_STRUCT sentinel that `impl Trait<...>` annotations parse to (typecheck.qz:1177) into a synthesized `Stream<T, body_row>` ptype carrying the body's effect row.

**What shipped (`77f84be0`)**:
- Three new helpers: `tc_synth_stream_ptype(elem_type, body_row)` + `tc_is_stream_ptype(t)` + `tc_stream_ptype_row(t)` in typecheck.qz; `tc_set_func_return_type(func_idx, type_id)` in typecheck_registry.qz.
- Encoding: TYPE_STRUCT ptype with arg1=T, arg2=body_row+1 (so arg2=0 means "no row" / untracked). The "Stream" name is set via `tc_ptype_set_name`; existing struct ptype interning at typecheck.qz:1625 uses arg2=0 unchanged. The base kind stays TYPE_STRUCT under tc_base_kind, so existing UFCS dispatch (typecheck_expr_handlers.qz:2578-2632) is unaffected.
- Synthesis fires at tc_function (typecheck_walk.qz:~4198) for any `impl Iterator<T>`/`impl AsyncIterator<T>` return. body_row source order: (1) function-level `can` clause via tc_get_func_effect_row (rare — see 4D.4c note below); (2) the `can` suffix on impl_trait_name itself (the row-poly form `def gen(): impl Iterator<T> can Async`); (3) implicit Async for the explicit `impl AsyncIterator<T>` form (is_async_generator true via the syntactic prefix check at typecheck_walk.qz:4051) — async generators conceptually perform Async even though their author didn't declare it on the trait.

**Spec**: `phase_4d4b_stream_ptype_synth_spec.qz` — 5 regression-guard tests proving sync impl Iterator, explicit impl AsyncIterator, row-poly `impl Iterator<T> can Async`, and generator-from-generator composition all continue to work post-synthesis.

**Verify**: fixpoint 2341 byte-identical (gen1==gen2). 21-spec generator/iterator/effect sweep: 19 pass, 2 fail (both pre-existing per retro §4).

**LOC delivered**: ~105 LOC.

### 4D.4c — Stream<T, body_row> receiver-row propagation — SHIPPED `71dda7f4`

**Goal**: When a UFCS method is called on a `var s` whose static type is a synthesized `Stream<T, body_row>` ptype, widen the caller's effect row by body_row directly. This is the type-driven analog of F.3c's syntactic AsyncIterator-prefix scan at typecheck_walk.qz:3411.

**What shipped (`71dda7f4`)**:
- `typecheck_expr_handlers.qz:tc_expr_call`: at the call-site row check, if the call is UFCS, the receiver is NODE_IDENT, the receiver's bound type is `tc_is_stream_ptype`, and `tc_stream_ptype_row >= 0`, subsume the receiver's body_row directly into the caller's effect row via `tc_row_subsume_with_handlers`. On failure, emit QZ0610 with the missing labels.
- Bug fix: 4D.3's row-poly detection had a latent bug. `def gen(): impl Iterator<T> can Async`'s `can` clause is consumed by `ps_parse_type` at parser.qz:622-638 as part of the impl-Trait return-type annotation string, NOT as a function-level `can` clause. Result: `tc_attach_func_effect_row` never fires for that form, leaving the function's effect row at -1. The 4D.3 row-based async-generator detection at typecheck_walk.qz:4070-4083 read tc_get_func_effect_row and silently failed (the row-poly form "compiled cleanly" only because the code path silently no-op'd). Both 4D.3 detection and 4D.4b synthesis now parse the can suffix from impl_trait_name directly.

**Spec**: `phase_4d4c_stream_receiver_row_spec.qz` — 5 behavior tests covering sync gen / row-poly `can Async` / row-poly `can Throws` (fails with QZ0610) / explicit AsyncIterator / sync gen with `can Throws` caller (no widening).

**What's deferred to a follow-on phase**:
- Chained NODE_CALL receivers (`my_async_gen().next()`) — only NODE_IDENT handled; chained needs recursive tc_expr to read the type.
- QZ0610 error message label naming: `tc.interner` vs `intern_global()` mismatch garbles label names ("missing my_async" instead of "missing Async"). Pre-existing bug — same applies to all B.7 row checks (typecheck_expr_handlers.qz:1505). Filed for separate cleanup.

**Verify**: fixpoint 2341 byte-identical. 4D.4b spec 5/5 + 4D.4c spec 5/5 (10 tests). 6-spec regression check (phase_4d2, phase_4d3, effect_poly_for_in_f3c, effect_poly_stream_f4, generators_p4b5_for_in, iterator_protocol) all green. Smoke tests (style_demo + brainfuck) green.

**LOC delivered**: ~125 LOC.

### 4D.4d — For-in row widening via Stream<T, body_row> + F.3c deletion — SHIPPED

**Goal**: Replace F.3c's NODE_IDENT-only annotation-string scan at `typecheck_walk.qz:3411` with a type-driven check that fires for ALL iter source kinds (NODE_IDENT, NODE_CALL, etc.). Once wired, F.3c is empirically dead and gets deleted in the same commit.

**What shipped**:
- `typecheck_walk.qz` NODE_FOR handler: the F.3c block (32 LOC, lines 3411-3442) DELETED. Replaced by a type-driven check that runs after `tc_expr` resolves the iter source's static type. When `tc_is_stream_ptype` is true and `tc_stream_ptype_row >= 0`, subsume body_row into caller_row via `tc_row_subsume_with_handlers`; on failure, emit QZ0610 with the missing-labels detail. Mirrors 4D.4c's call-site widening. ~25 LOC added; net delta -7 LOC.
- F.3c was already dead in practice. Empirical audit before deletion: zero call-site uses of `def f(s: impl AsyncIterator<T>)` or `var s: impl AsyncIterator<T>` in `spec/`, `std/`, `examples/`, or `self-hosted/`. The annotation-string scan was a theoretical fallback that never fired in the current tree. Comparison run: pre-4D.4d golden vs post-deletion, both compile the same fixtures with identical diagnostics.
- Coverage upgrade vs F.3c: F.3c silently widened the row via the no-error `tc_row_subsume` (return value discarded — caller never saw QZ0610 even when the subsumption failed). The new path uses `tc_row_subsume_with_handlers` and emits QZ0610 with missing-labels detail on failure. Strictly stronger.

**Spec**: `phase_4d4d_for_in_stream_row_spec.qz` — 7 behavior tests: sync gen for-in / NODE_IDENT row-poly with `can Async` (pass) / NODE_IDENT row-poly with `can Throws` (QZ0610) / NODE_CALL row-poly with `can Async` (pass — F.3c-missed case) / NODE_CALL row-poly with `can Throws` (QZ0610) / explicit `impl AsyncIterator<T>` for-in / sync gen from `can Throws` (no widening).

**What's deferred to a follow-on phase**:
- Parameter Stream<T, e> coverage. Today only var bindings + call results pick up the synthesized Stream ptype; param types annotated `s: Stream<T, e>` or `s: impl AsyncIterator<T>` parse via `tc_parse_type` which returns bare TYPE_STRUCT. F.3c's annotation-string scan would have caught these in theory, but the empirical audit above confirmed zero such usages today. When the first user writes `def consumer(s: impl AsyncIterator<Int>) can Throws` and forgets to declare `can Async`, they'll get a silent typecheck pass (which 4D.5b/4D.6 will catch at runtime). Resolving cleanly needs `tc_parse_type` to recognize `Stream<T, e>` and `impl AsyncIterator<T>` annotations and synthesize the same ptype encoding as 4D.4b. ~50-80 LOC; filed as a 4D.4d follow-on.
  - **2026-04-25 audit (pre-4D.5b.0)**: re-verified zero live consumers for the `for v in src` (NODE_FOR) form. The 12 `: impl AsyncIterator<Int>` parameter bindings in `std/streams.qz` all use `for await v in src` (NODE_FOR_AWAIT — separate typecheck path that doesn't widen by Async at all today). So the param-coverage build has no caller in the tree until either (a) `for await` is retired (non-load-bearing per design memo §4D.4) or (b) a user writes `def f(src: impl AsyncIterator<Int>) ; for v in src ...` directly. Per PD3 (no code with no consumer), this slice was sequenced AFTER the registry deletions of 4D.5b.0 rather than before.
- Chained NODE_CALL receivers in `.next()` chains (`my_async_gen().next()`) — still only NODE_IDENT covered at 4D.4c. The for-in side handles NODE_CALL natively because `tc_expr(range_node)` resolves the chain to the Stream ptype regardless; the `.next()` path needs recursive type lookup. Filed.

**Verify**: fixpoint 2341 byte-identical (gen1==gen2). New spec 7/7 + all four 4D.4 specs 22/22 (4D.4b 5/5 + 4D.4c 5/5 + 4D.4d 7/7). 12-spec regression sweep all green: phase_4d2 (4/4), phase_4d3 (5/5), phase_4d4b (5/5), phase_4d4c (5/5), phase_4d4d (7/7), effect_poly_for_in_f3c (3/3), effect_poly_stream_f4 (5/5), generators_p4b5_for_in (9/9), iterator_protocol (52/52), generators_p4b8_modular_helpers (11/11), generators_p4b9_effect_composition (7/7), for_loop_state_in_poll (6/6) = 119/119. Smoke (style_demo + brainfuck) green.

**LOC delivered**: ~150 LOC (spec) + ~25 LOC added in NODE_FOR handler − ~32 LOC F.3c deletion = net +143 LOC including the new spec, +18 LOC excluding spec; structural delta in compiler source is -7 LOC.

### 4D.5 — Consolidate generator lowerings (~1 quartz-day) — PARTIALLY SHIPPED `7213879c`

**Goal**: `mir_lower_async_generator` retires. Sync + async share `mir_lower_generator_effect` with row-gated frame init.

**What shipped (`7213879c`)**:
- The duplicate-poll bug source is removed at the dispatch level. PASS 1.2a / PASS 1.3a in `mir_lower.qz:4209, 4322` now skip async generators when iterating async-target names. Async generators emit `__Future_<name>$poll` inline (via `mir_lower_async_generator`) and are auto-registered as async targets by PASS 0.99b's suspend propagation; pre-skip, PASS 1.2a's call to `mir_lower_async_poll` for the same name produced a second definition that llc rejected with "invalid redefinition of function".
- Three previously-broken specs unblock: `effect_poly_for_in_f3c_spec.qz`, `effect_poly_stream_f4_spec.qz`, `generators_p4b5_for_in_spec.qz`.

**What's deferred to a follow-on phase (Phase 4D.5b)**:
- True structural consolidation of `mir_lower_async_generator` into `mir_lower_generator_effect` is BLOCKED on Stream<T, body_row> ptype synthesis (kickoff memo §4D.3 "Stream<T, body_row> ptype synthesis EXPLICITLY DEFERRED"). Per the kickoff handoff: "4D.5's lowering needs to read the row from the function's registered return type. That's where Stream<T, body_row> synthesis lands: 4D.5 reads `tc_get_func_effect_row(func_idx)` to pick the frame layout + emit the right constructor." Without synthesis, async-gen constructors must continue returning a frame_ptr (not a Stream<T> handle), which means F.3c's MIR routes (`lower_async_gen_iteration{,_indirect}`) cannot be subsumed under `lower_custom_iteration("Stream$next")`. Empirical evidence at attempt time: changing the constructor return shape broke the for-await indirect path, the colorless-dispatch skip at `mir_lower_expr_handlers.qz:2805`, and specialized `stream_*<e>` callers (PASS 1.2a's lookup-by-name fails for monomorphized spec_names, so inline emission was the only emission for those call sites).
- `_async_gen_func_names` registry deletion (was the lookup engine for the F.3c MIR fast paths): kept live for the colorless-dispatch skip and for the new PASS 1.2a/1.3a skip introduced this commit.

**Verify (shipped)**: fixpoint 2337 byte-identical at gen1==gen2; 19-spec sweep 17/19 pass (was 14/19 baseline). Smoke test (style_demo + brainfuck) green.

**Risk-discharged (shipped scope)**: specialized async generators were the chief concern — their inline emission is the only emission since PASS 1.2a's lookup-by-name fails for monomorphized spec_names, so the new skip cannot strand them. Empirically verified.

**LOC delivered**: ~17 LOC delta (PASS 1.2a + PASS 1.3a `continue` + descriptive comments).

### 4D.5b.0 — Delete `_generator_func_names` / `_async_gen_func_names` runtime registries — SHIPPED

**Goal**: Remove the two name-registries (`_generator_func_names`, `_async_gen_func_names`) that downstream MIR code consulted as the source of truth for "is this function a generator?" / "is this an async generator?". The annotation-based dispatch in `mir_lower_function_with_name` (mir_lower.qz:3295-3307) already distinguished the same shapes via str2 prefix-check — moving the four direct-call dispatch sites and one colorless-skip site to the same source eliminates the parallel cache. Distinct from the structural consolidation tracked under 4D.5b proper (the merge of `mir_lower_async_generator` into `mir_lower_generator_effect`); this slice deletes the cache without touching the lowering shape.

**What shipped**:
- New helpers in `mir.qz`: `mir_func_annotation_is_async_generator(ann: String): Bool` (str2 starts with `"impl AsyncIterator<"`) and `mir_func_annotation_is_generator(ann: String): Bool` (also covers `"impl Iterator<"`). Plus `mir_func_lookup_annotation(ctx, name): String` for by-name lookup against the resolver's input list, and `mir_emitted_func_exists(prog, name): Bool` for queries against the emitted MIR output list.
- Sites swapped to annotation-based dispatch (4 sites): `mir_lower_stmt_handlers.qz:1259-1281` (for-in NODE_CALL `for x in gen()`), `mir_lower.qz:2640` (for-await NODE_CALL `for await x in gen()`), `mir_lower_expr_handlers.qz:2805` (colorless-dispatch skip — don't unwrap generator constructors as awaited frames). Each consults `ctx.mir_infer_expr_type(s, iter_node)` (which already substituted type-args for the call) and runs the prefix predicate.
- Sites swapped to emitted-list query (2 sites — PASS 1.2a/1.3a): `mir_lower.qz:4220, 4337`. The original 4D.5 skip was annotation-detecting "this is an async generator, its $poll was already emitted inline". The annotation predicate is the wrong semantic here because std/streams.qz functions like `stream_enumerate` are declared async generators yet are bounded-generic — their `impl AsyncIterator<Int>` parameter desugars to a synthetic type-param with bounds, so PASS 1's main loop SKIPS them at line 4109-4117, `mir_lower_async_generator` never runs for them, and PASS 1.2a's `mir_lower_async_poll` legitimately handles their `$poll` emission. The fix consults the emitted output list (`mir_emitted_func_exists(prog, "__Future_<name>$poll")`) — true semantic answer, regardless of which path emitted it.
- Deleted: `_generator_func_names` and `_async_gen_func_names` vec declarations + their pushes in `mir_lower_generator_effect` (line 826) and `mir_lower_async_generator` (line 899). Old wrapper functions `mir_gen_is_generator_function(name)` / `mir_gen_is_async_generator_function(name)` deleted. Replaced with referent comments pointing at the new helpers.

**Subtlety found during implementation**: pre-existing `mir_lookup_function(ctx, name)` scans the resolver's INPUT list (`all_funcs`), not the emitted MIR output. For PASS 1.2a/1.3a's "did this $poll already get emitted" question, the input list is the wrong list — the emitted poll function is in `prog.functions`, not `all_funcs`. Required adding `mir_emitted_func_exists(prog, name)` for the output-list query (linear scan of ~2342 emitted funcs once per async target — fine for compile-time).

**Verify**: fixpoint 2343 byte-identical at gen1==gen2 (`quake guard` PASSED). 11-spec regression sweep all green: phase_4d3 (5/5), phase_4d4b (5/5), phase_4d4c (5/5), phase_4d4d (7/7), effect_poly_for_in_f3c (3/3), effect_poly_stream_f4 (5/5), generators_p4b5_for_in (9/9), iterator_protocol (52/52), generators_p4b8_modular_helpers (11/11), generators_p4b9_effect_composition (7/7), for_loop_state_in_poll (6/6) = 115/115. Smoke (style_demo + brainfuck) green. Pre-existing `phase_4d2_stream_row_var` (`@qz_main` undefined at llc) preserved unchanged — also fails on the pre-4D.5b.0 golden binary, not a regression.

**Risk-discharged (shipped scope)**: All 6 dispatch sites covered. Annotation-based check is correct semantic for sites 1-3+6 (they ask "is this declared as a generator?"); emitted-list check is correct for sites 4-5 (they ask "is the $poll already in the output?"). Both checks are direct semantics; neither requires a parallel cache.

**LOC delivered**: net +44 LOC (helpers in mir.qz + comments) − ~40 LOC (registry decls + pushes + 2 helper functions + their consult patterns) ≈ +4 LOC structural delta.

**What's still deferred under 4D.5b proper**: True structural consolidation — merging `mir_lower_async_generator` into `mir_lower_generator_effect` with row-gated frame init — remains future work per the existing 4D.5 deferred-section. This slice removes the registries that 4D.5b would have had to delete anyway as part of consolidation; it does NOT yet collapse the two lowering paths.

### 4D.5b — Producer-side `$poll` consolidation — SHIPPED `2ca90be3`

**Goal**: `mir_lower_async_generator` no longer emits `$poll` body inline. Consolidate $poll body emission into the same `mir_lower_async_poll` path that async functions and sync `impl Iterator` $polls use (the state machine has been structurally identical post-4.B.7.b unification of NODE_YIELD kind=3). Two emission paths cover the two function shapes:

- Non-spec async gens: PASS 0.99b's suspend-propagation registers them via the `__qz_yield_marker__` synthetic edge → PASS 1.2a iterates the async-target list → `mir_lower_async_poll` emits `$poll`.
- Specialized async gens: `mir_emit_pending_specializations` calls `mir_lower_async_poll` directly after `mir_lower_function_with_name`, while spec context (param_types, current_module_prefix) is still active. PASS 1.2a's `mir_lookup_function` lookup-by-name fails for spec names (they aren't in `all_funcs`), so the spec path is the only emitter for them.

**What shipped**:
- `mir_lower_gen.qz`: deleted the inline `$poll` emission from `mir_lower_async_generator` (~130 LOC of state setup, dispatch chain, body lowering, done block, `_gen_clear`, param marking — all of which `mir_lower_async_poll` already does). Also deleted the `all_names`/`all_offsets` build-up that was only used by the inline $poll.
- `mir_lower.qz`: spec-side `$poll` emission added in `mir_lower_specialized_function` (~10 LOC) right after `mir_lower_function_with_name` returns. PASS 1.2a/1.3a `mir_emitted_func_exists` skips deleted (the 4D.5/4D.5b.0 hacks are no longer needed since there is no longer a duplicate to skip).
- `mir.qz`: `mir_emitted_func_exists` helper deleted (no remaining consumers).

**Subtleties found during implementation**:
1. The inline `$poll`'s end-of-body block stored `option_none` to frame[1]; `mir_lower_async_poll` stores `0` instead. Consumer (`lower_async_gen_iteration`) never reads frame[1] on POLL_READY=1 (it just exits), so this is observably equivalent.
2. Constructor's poll-fn-pointer storage at frame[2] (`__Future_<name>$poll`) still works because PASS 1.2a/1.3a (or `mir_emit_pending_specializations` for specs) emit a function with exactly that name later in the compilation. The constructor pre-references it via `mir_emit_func_ref`; LLVM resolves the symbol at link time.

**Verify**: fixpoint 2342 byte-identical at gen1==gen2 (`quake guard` PASSED). 12-spec regression sweep all green: phase_4d2 (4/4), phase_4d3 (5/5), phase_4d4b (5/5), phase_4d4c (5/5), phase_4d4d (7/7), effect_poly_for_in_f3c (3/3), effect_poly_stream_f4 (5/5), generators_p4b5_for_in (9/9), iterator_protocol (52/52), generators_p4b8_modular_helpers (11/11), generators_p4b9_effect_composition (7/7), for_loop_state_in_poll (6/6) = 119/119. Smoke (style_demo + brainfuck) green.

**Surprise — phase_4d2 incidentally fixed**: the 4D.5b.0 baseline flagged `phase_4d2_stream_row_poly_spec.qz` as the lone known-failure (`@qz_main undefined at llc`). Post-merge it compiles + runs + passes 4/4. Plausible mechanism: the spec was hitting a duplicate-poll path that the inline-vs-PASS-1.2a skip didn't cover for that spec's specific generator shape; with single-emission-path consolidation, the duplicate disappears at source.

**LOC delivered**: net -144 LOC structural delta across `mir.qz` (-18), `mir_lower.qz` (-29), `mir_lower_gen.qz` (-137).

**What's still deferred (consumer-side merge)**: This shipped slice is the producer-side merge. The constructor still differs sync-vs-async (sync emits a 2-word `Stream<T>` wrapper; async emits a raw 6-slot frame_ptr). Folding `lower_async_gen_iteration` through `lower_custom_iteration("Stream$next")` and routing for-await via Stream$next requires solving the park-encoding bridge: Stream$next is Quartz code, can't call `mir_emit_async_suspend_point` (compiler-internal MIR emission); falling back to `sched_yield` loses fd/timer wakeup-registration for async-I/O generators. Multi-session design work to do correctly. Tracked as the design memo's Option A end-state.

**Design queued**: see [`PHASE_4D_5C_CONSUMER_MERGE.md`](PHASE_4D_5C_CONSUMER_MERGE.md) — five-subphase plan (4D.5c.1 …4D.5c.5) introducing a `__qz_async_park_propagate(rv)` MIR intrinsic, regularizing Stream.next() to handle all three rv states (POLL_READY / POLL_SUSPENDED / park-encoding), wrapping the async-generator constructor in a Stream<T,e> handle, then deleting `lower_async_gen_iteration{,_indirect}` and folding `mir_lower_async_generator` into `mir_lower_generator_effect`. ~2-2.5 quartz-days, multi-session, medium risk. Filed 2026-04-25.

### 4D.6 — Delete remaining registries — SHIPPED

**Goal**: zero runtime registries for generator dispatch.

**Status**: COMPLETE.

**What shipped**:
- `_generator_func_names` and `_async_gen_func_names` deleted in 4D.5b.0.
- `mir_gen_is_generator_function` / `mir_gen_is_async_generator_function` (and their internal consults at `mir_lower_gen.qz:184, 193`) deleted in 4D.5b.0.
- `tc.reserved[0]` field + writes + reads + channel 1 of `_tc_p4b_yield_in_scope` deleted in 4D.6 commit. Replaced by `_tc_current_func_is_generator(tc): Int` (`typecheck_walk.qz`) which queries the current function's return-type annotation directly via the new `tc_get_func_return_annotation(tc, idx)` helper in `typecheck_registry.qz`. Returns 0 (not in generator) / 1 (sync `impl Iterator<T>`) / 2 (async `impl AsyncIterator<T>` OR row-poly `impl Iterator<T> can Async`). Applied at the three reader sites (QZ0172, `_in_gen` for return-skip, `_tc_p4b_yield_in_scope`'s channel 1).
- QZ0170 stays — its diagnostic message still applies via channels 2+3 (handler-effect stack contains `Yield`, or function declares `can Yield`). The implicit Yield push at tc_function body entry covers the same set of generator-body positions that channel 1 used to cover.

**Verify (4D.6 portion)**: fixpoint 2344 byte-identical (gen1==gen2, `quake guard` PASSED — was 2342; net +2 functions for the two new helpers). 13-spec sweep all green: phase_4d2 (4/4), phase_4d3 (5/5), phase_4d4b (5/5), phase_4d4c (5/5), phase_4d4d (7/7), phase_4d5b (8/8), effect_poly_for_in_f3c (3/3), effect_poly_stream_f4 (5/5), generators_p4b5_for_in (9/9), iterator_protocol (52/52), generators_p4b8_modular_helpers (11/11), generators_p4b9_effect_composition (7/7), for_loop_state_in_poll (6/6) = 127/127. QZ0170 (yield outside generator) and QZ0172 (return-with-value in generator) still fire correctly on regression tests; behavior matches pre-4D.6 binary on both correct-program and error-program inputs.

**LOC delivered**: ~30 LOC in cleanup, ~50 LOC in new helpers + comments. Removed `tc.reserved` field declaration + init + free + 5 read/write sites; added `_tc_current_func_is_generator` (~35 LOC) + `tc_get_func_return_annotation` (~6 LOC).

### 4D.7 — End-to-end spec — ✅ SHIPPED 2026-04-25

`spec/qspec/phase_4d7_end_to_end_spec.qz` — 8 tests pinning down the cross-arc invariants no individual phase spec captures alone. Each test exercises the full row-polymorphic Stream pipeline (typecheck + MIR + runtime) on a different consumer/producer/composition shape; the value is in the integration story, not in re-asserting phase-level behaviors that already have dedicated specs.

**Tests shipped**:

1. **Multi-consumer parity (sync)** — pure generator drives identical sums through `s.next()` and `for v in s` (Stream<T, {}>).
2. **Multi-consumer parity (async)** — async generator drives identical sums through `for v in s` and `for await v in s` from a `can Async` caller (Stream<T, {Async}>). `.next()` from inside an async caller is a documented Path-B limitation pending Stream.next inlining (Phase 4D.5d if it ever ships); not exercised here.
3. **Regularization parity (sync)** — sync generator-from-generator wraps cleanly with row `{}`.
4. **Regularization parity (async)** — async generator-from-generator wraps cleanly with row `{Async}`.
5. **Mixed-mode helper interleaving** — async generator body yielding via a sync `can Yield<Int>` helper interleaves correctly. The case `PHASE_4_GENERATORS_RETRO.md` §4 originally flagged as broken pre-4D.5b. (4D.5b's spec covers the all-async-helper variant; this test pins down the sync-helper-from-async-gen direction.)
6. **Row-poly enforcement (negative)** — `for v in async_gen()` from a caller with explicit `can Throws` (no `Async`) is rejected with QZ0610. Confirms `Stream<Int, {}>` and `Stream<Int, {Async}>` are distinct typecheck-side. *Note*: a caller with no `can` annotation has its row inferred bottom-up and silently picks up Async — that's correct row-poly behavior, not a type-distinction violation; the negative case requires an explicit incompatible row.
7. **F.3c-missed NODE_CALL form parity** — bare `for v in async_gen()` and `for await v in async_gen()` from a `can Async` caller produce identical output. The 4D.4d type-driven path replaced F.3c's NODE_IDENT-only annotation-string scan; both consumer keywords now route through the same lowering.
8. **Row-poly surface-form parity** — `def gen(): impl Iterator<T> can Async` (4D.3 row-poly form) and `def gen(): impl AsyncIterator<T>` (legacy async surface) produce equivalent runtime behavior. 4D.3's tc_function rewrites str2 to the legacy form before MIR runs, so both routes through the same dispatcher branch in `mir_lower_function_with_name`.

**Out-of-band invariants** (verified outside the unit-spec layer; documented in the spec's preamble):

- `_async_gen_func_names` + `_generator_func_names` registries deleted (4D.5b.0 `07c0b4d1`) — grep on `self-hosted/backend/*.qz`: zero occurrences.
- `tc.reserved[0]` generator-context cache deleted (4D.6 `90fd9a5a`) — grep on `self-hosted/middle/*.qz`: zero occurrences.
- `mir_lower_async_generator` + `lower_async_gen_iteration{,_indirect}` deleted (4D.5c.4 + 4D.5c.5) — grep + net function-count delta in fixpoint (2342 functions post-4D.5c.5).
- F.3c MIR fast-path + typecheck fallback deleted (4D.4 `01e6203f` + 4D.4d `cb1db464`) — grep on `typecheck_walk.qz`: no `impl AsyncIterator<` annotation-string scan in the for-in handler.
- Fixpoint byte-identical at every 4D commit — verified by `quake guard` at each commit; no commit in the arc skipped guard.
- Memory equivalence (alloc rate of 6-slot frame): no change. The 4D arc lifted Stream<T> to Stream<T, e> at the type level only — frame layout unchanged. No benchmark run because no allocation site was touched.

**Verify (shipped)**:
- `phase_4d7_end_to_end_spec.qz`: 8/8 green.
- Full 4D-arc + adjacent regression sweep: 23/23 green (phase_4d1 through phase_4d5c4 + effect_poly_for_in_f3c + effect_poly_stream_f4 + generators_p4b2…p4b9 + iterator_protocol + for_loop_state_in_poll). No regressions.
- No compiler source touched (spec-only commit); fixpoint stamp + binary unchanged.

**Departures from the original 10-bullet list**:

- Bullets 5, 8, 9, 10 lifted to "out-of-band invariants" (registry-deleted grep, fixpoint byte-identical, alloc-rate benchmark, memory equivalence) — not unit-spec testable; documented in the spec's preamble.
- Bullet 7 (combinator chain `stream_map`) skipped: `std/gen.qz` ships no `stream_map` combinator. The spirit (a wrapper generator works regardless of underlying gen's row) is captured by the regularization-parity tests #3 and #4 (manual generator-from-generator composition).
- Bullet 3 (`for await` deprecation alias warning) reframed as parity test #7: the 4D.5c.4 keyword-collapse landed without an actual deprecation warning emission, and parity is the load-bearing assertion.

## Total estimate

~3.5-4.5 quartz-days across 7 commits. **Multi-session** — likely 2-3 sessions. Risk: medium-low. The core unification primitives (kind=3, row-var infra, F.3 trait/impl row support) are all proven; the lift is into a parallel infrastructure (struct generics) that is mechanically similar.

## Non-goals (deferred)

- **Channel<T, e> / Reader<W, e>**: same struct-row-var infrastructure can lift other value types. Filed as Tier 5 candidates; not blocking.
- **Worker-wrapper monomorphization**: P3.F deferred this (memo §5); 4D inherits the deferral.
- **Multi-shot interaction**: 4D's row var is single-shot only. Phase 4b (multi-shot) deferral is unaffected.
- **`for await` keyword retirement**: 4D's spec keeps it as an alias with deprecation warning. Full removal is a one-commit followup once usage drops to zero in the tree.
- **`Iterator` / `AsyncIterator` trait merge**: surface aliasing handles the common case; full trait-level deduplication is a follow-on if `AsyncIterator` ever held methods Iterator didn't.

## Stale-doc cleanup (file alongside 4D.1) — RESOLVED 2026-04-25

Discovered during the 4D audit:

1. ~~**Phase 4 retro §"What surprised us · `_gen_active` is a four-valued discriminant"** is wrong post-4.B.7.b.~~ — fixed: section now annotated with a 2026-04-25 update noting the post-4.B.7.b 2-value reality; the four-value model is preserved as historical record of the migration's biggest near-miss.
2. ~~**`feedback_gen_active_kind3_routing.md`** memory entry references the four-value model and the `>= 2` → `== 2` tightening.~~ — fixed: "stale references that survive" section flipped to "all fixed 2026-04-25" with strikethroughs.
3. **`mir_lower_gen.qz:42-46`** comment is correct (says 2-value); good. (No fix needed.)
4. ~~**`mir_lower_gen.qz:230`** doc-comment said `## REQUIRES: _gen_active == 2 or 3`~~ — fixed to `== 2` with a 4.B.7.b cross-reference (this was a fourth stale ref discovered while fixing item 2).

## Handoff

If the session splits mid-phase, resume from the phase list (`4D.1…4D.7`). Each phase ships independently with a passing spec. 4D.1 is the foundation — without it the rest can't begin. 4D.4 → 4D.5 → 4D.6 are the deletion arc; sequence them in that order so registries delete after their consumers do.

**Start of next session**: 4D.1, struct row-var infrastructure. The audit in §What's already built confirms all P3.F prerequisites are in place; no detour needed.

**End of next session (target)**: 4D.1 + 4D.2 shipped, fixpoint byte-identical at each commit. Hands off to a third session for 4D.3-4D.7.

## References

- [`PHASE_4_GENERATORS_RETRO.md`](PHASE_4_GENERATORS_RETRO.md) §4 — the open-followup that filed this work.
- [`P3_F_ROW_POLYMORPHISM.md`](P3_F_ROW_POLYMORPHISM.md) — the row-var infrastructure 4D builds on (function-level analog of what 4D adds at struct-level).
- [`PHASE_4_GENERATORS_VIA_EFFECTS.md`](PHASE_4_GENERATORS_VIA_EFFECTS.md) — Path B design memo; §3.5 "AsyncIterator unification" is the original pitch for this work.
- [`EFFECT_MIGRATION_PLAYBOOK.md`](EFFECT_MIGRATION_PLAYBOOK.md) §3.6 — kind=3 cooperative dispatch (the substrate 4D inherits).
- [`../research/EFFECTS_LLVM_COMPILATION_MEMO.md`](../research/EFFECTS_LLVM_COMPILATION_MEMO.md) §5 — polymorphic effect functions; same evidence-passing model applies to row-poly value types.
