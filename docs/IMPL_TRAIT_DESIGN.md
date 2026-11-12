# `impl Trait` — Design Document

**Status:** Draft, pending review
**Author:** Claude (sprint plan, Apr 13 2026)
**Scope:** World-class implementation of `impl Trait` return and argument positions for Quartz, including fixing pre-existing miscompile holes, redesigning `Iterable<T>`, and modernizing `std/iter.qz`.

---

## 1. Motivation

`std/iter.qz` today is shaped around a workaround: every combinator takes a `Fn(): Option<Int>` closure, and every call site hand-writes `-> it.next()` because the language couldn't express "some concrete iterator type" in a signature. The handoff doc calls this out explicitly, and `std/traits.qz:133-137` carries a stub `Iterable<T>` trait with a bogus `iter(): Int` abstract method that nothing uses and nothing can use.

The right answer is Rust/Swift-style opaque return types: `def iter(self): impl Iterator<Int>`. The compiler infers a single concrete return type from the function body, callers dispatch through that concrete type statically, and no closures appear anywhere.

A probe pass during planning revealed the feature is **already partially wired in the compiler** — parser, registry, and inference are in place, and simple cases work end-to-end. But two silent-miscompile holes and a symbol-mangling bug block real use. This document specifies how to close those holes and finish the feature to a Rust-class standard.

## 2. Prior art and research

### 2.1 Rust — `impl Trait` in return position ([RFC 1522, 2016](https://rust-lang.github.io/rfcs/1522-conservative-impl-trait.html))

The original conservative proposal. Key properties:

- **Return-position only.** Conservative RFC limited `impl Trait` to function return types. Argument position came later.
- **Single concrete type per function.** The body must produce the same concrete type at every `return`. Multi-return unification is strict — no "any type implementing the trait" union.
- **Partial opacity.** "Both specialization and auto-traits can see through it" — the RFC deliberately chose privacy-via-module-system rather than type-level hiding. This matters: Rust's `impl Trait` isn't a hard abstraction boundary, it's a naming convenience.
- **Monomorphized.** Same codegen as concrete returns. No vtables, no boxing.
- **Exclusions.** The conservative RFC explicitly deferred trait method return types, argument position, recursive functions, and named/referenceable abstract types.

### 2.2 Rust — expanding to argument position ([RFC 1951, 2017](https://rust-lang.github.io/rfcs/1951-expand-impl-trait.html))

The follow-up extending `impl Trait` to function arguments:

> "These two are equivalent: `fn map<U, F: FnOnce(T) -> U>(self, f: F)` and `fn map<U>(self, f: impl FnOnce(T) -> U)`"

- **Argument position = anonymous generic parameter.** Per-call-site monomorphization, identical semantics to a spelled-out `<T: Trait>`. No dynamic dispatch.
- **Explicit turbofish is rejected.** You can't write `drain::<Counter>(...)` for an `impl Trait` argument. This distinguishes it from named generics and is a deliberate learnability trade-off.
- **Auto-traits flow through transparently.** If the argument is `Send`, the caller's context observes `Send`, just like a regular generic parameter.
- **Learnability tension.** Critics argued introducing a third syntax (`<T: Trait>`, `where T: Trait`, `impl Trait`) creates pedagogical burden. Rust shipped it anyway because the ergonomic wins for combinator-heavy code are large.

### 2.3 Rust — return-position `impl Trait` in traits (RPITIT) ([RFC 3425, 2023](https://rust-lang.github.io/rfcs/3425-return-position-impl-trait-in-traits.html))

Rust 1.75 shipped `impl Trait` inside trait method signatures:

```rust
trait Container {
    fn iter(&self) -> impl Iterator<Item = i32>;
}
```

- **Desugars to an anonymous associated type** with generic parameters captured from the trait.
- **Breaks dyn-safety by default.** Traits with RPITIT methods can't be used behind `dyn Trait` because the return type is unnamed. `where Self: Sized` exempts individual methods.
- **Requires matching impl syntax.** Implementors must also use `impl Trait` syntax or provide a concrete type via `#[refine]`.
- **Auto-trait leakage still occurs** when the compiler resolves to a specific impl.

This is the exact shape Quartz needs for `trait Iterable<T> { def iter(self): impl Iterator<T> }`.

### 2.4 Rust — type alias `impl Trait` ([RFC 2515, 2018](https://rust-lang.github.io/rfcs/2515-type_alias_impl_trait.html))

`type Foo = impl Trait;` — lets you give a name to an opaque type. Enables `impl Trait` in struct fields, static items, and recursive contexts the return-position form can't express. Stabilized in 2023.

This is orthogonal to our immediate needs but worth flagging as a future extension.

### 2.5 Swift — opaque result types, `some Protocol` ([SE-0244, 2019](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0244-opaque-result-types.md))

Swift's take on the same feature, shipped in Swift 5.1 for SwiftUI's `body: some View` pattern. Core design principles, quoted directly:

> "Unlike an existential, though, clients still have access to the type identity."

> "The underlying concrete type is hidden, and can even change from one version of the library to the next without breaking those clients, because the underlying type identity is never exposed to clients."

Swift's opacity model is **stricter than Rust's**:

1. Different invocations with identical generic arguments yield the *same* opaque type — composable into collections.
2. Different generic arguments produce *different* opaque types — deliberately incompatible, preventing accidental coupling.
3. `as?` runtime casting can inspect the concrete type, but static type equivalence requires identical type origins.
4. Returning an *existential* value (e.g. a variable of protocol type) is a compile error — the function must produce a concrete type.

The key difference from Rust: Swift treats opacity as a hard API boundary, Rust treats it as a convenience. For Quartz, with a single compilation unit and no external library versioning story, Rust's convenience-first model is the right pick.

### 2.6 Haskell — rank-N polymorphism and existential types

The theoretical ancestor. `forall a. Iterator a => a` is the existential encoding; GHC's `ExistentialQuantification` extension expresses it directly. Higher-rank types (`RankNTypes`) generalize the pattern to arbitrary positions in the type signature.

- **Type inference is undecidable for unrestricted higher-rank types.** GHC uses the Odersky-Läufer algorithm, which requires programmer annotation at rank-≥2 positions.
- **Existential packing** — the compiler wraps a concrete type with a "witness" of the class constraint. At use site, the constraint is unpacked and methods dispatch through the witness.
- **No monomorphization by default.** Haskell dispatches through dictionary passing; specialization (`SPECIALIZE` pragma) is an opt-in optimization.

For Quartz this is a theoretical reference point, not an implementation model. Quartz's existing bounded-generic monomorphization is closer to Rust than to Haskell.

### 2.7 Swift SE-0328 — structural opaque result types

Extension to SE-0244 allowing `some Protocol` inside tuples, arrays, and other structural positions:

```swift
func pair() -> (some Sequence, some Sequence) { ... }
```

Not needed for the MVP but worth noting: once `impl Trait` is solid in return position, structural composition is the natural next extension.

### 2.8 Zig — comptime duck typing (the counter-model)

Zig has no traits and no `impl Trait`. Generic functions use `comptime` parameters and structural duck typing — if the passed-in type has the method you need, it compiles, otherwise it errors. This is the extreme "no formal trait system" position and is instructive for what we *don't* want: duck typing pushes error messages to call sites instead of declaration sites, which is worse ergonomics at scale.

### 2.9 What the community wants

Tracking high-level language-design discussion:

- **Rust's 2024 edition** added automatic capture of all in-scope generic parameters for return-position `impl Trait`, fixing a long-standing footgun where users had to manually rewrite to `impl Trait + 'a` to keep lifetimes in scope ([2024 edition notes](https://doc.rust-lang.org/edition-guide/rust-2024/rpit-lifetime-capture.html)). Quartz doesn't have explicit lifetimes yet, so this isn't directly applicable, but it's a signal that capture rules are the single most-requested polish item.
- **RPITIT (traits)** was the #1 requested `impl Trait` feature and shipped in Rust 1.75. Every Iterator combinator library benefits.
- **TAIT (type alias impl Trait)** is the second-most-requested, enabling struct fields and recursive contexts.

For Quartz, this orders the value: (a) close holes in return-position `impl Trait`, (b) RPITIT, (c) TAIT. We do (a) first as the MVP, (b) as stretch, defer (c).

### 2.10 Where Quartz stands today (probe results)

I ran six probe programs against the current compiler (`7d3fb5b2` + the four bug-fix commits from this session's earlier sprint). Results:

| Probe | Shape | Result |
|-------|-------|--------|
| **1** | `def f(): impl Trait` returning a concrete struct; caller binds result and calls method | ✅ Works end-to-end |
| **2** | `impl Trait` return → bounded generic `<T: Trait>` call site | ❌ **Hard error**: mangler bakes `"impl MyIter"` (literal, with space) into the symbol name, LLVM rejects |
| **3** | `impl Trait` arg position, single impl in scope | ✅ Works |
| **4** | `impl Trait` arg position, single impl in scope | ✅ Works |
| **5** | `impl Trait` arg position, **two impls** in scope, both passed in | ❌ **Silent miscompile**: function statically dispatches to the first impl for *both* callers (returns 202 instead of 302, no error) |
| **6** | Inline chain `f().next()` where `f` returns `impl Trait` | ✅ Works |

These are the holes. Probe 5 is the most dangerous — no error, wrong answer — and blocks any realistic use of `impl Trait` in argument position.

## 3. Existing Quartz infrastructure

Substantial scaffolding is already in place. This section enumerates what exists so the plan can build on it without duplicating work.

### 3.1 Parser
- **`parser.qz:444-450`** — `ps_parse_type` recognizes the `impl` keyword in type position and returns `"impl #{trait_type}"` as an annotation string. Multi-arg traits like `impl Iterator<Int>` work because `ps_parse_type` recurses into generic arguments.
- **`token_constants.qz:101`** — `TOK_IMPL = 44`, globally reserved.
- **`ast.qz:1456-1463`** — `ast_function` stores the return type annotation in `str2`, retrieved via `ast_get_str2`.

### 3.2 Registry
- **`typecheck_util.qz:266`** — `TcRegistry.impl_return_concrete_types: Vec<String>`.
- **`typecheck_registry.qz:2604-2609`** — `tc_register_impl_return(func_name, concrete_type, trait_name)`.
- **`typecheck_registry.qz:2613-2629`** — `tc_lookup_impl_return(func_name) → String` (with cross-module suffix fallback, same idiom as other registry lookups).
- **`typecheck_registry.qz:2632-2635`** — `tc_is_impl_return(func_name) → Bool`.
- **`typecheck_util.qz:2686`** — free path already present.
- **`typecheck.qz:203`** — registry field initialized.

### 3.3 Inference
- **`typecheck_walk.qz:2909-2922`** — `tc_infer_impl_concrete_type` walks a function body and infers the concrete return type.
- **`typecheck_walk.qz:2868-2907`** — `tc_collect_impl_returns` recursively scans `NODE_RETURN` under blocks, `if`, `match`, and match arms. First annotation wins; conflicts emit **QZ0161: "impl return type conflict — 'X' vs 'Y' in 'F'"**.
- **`typecheck_walk.qz:3100-3121`** — `tc_function` calls `tc_infer_impl_concrete_type` after body type checking, validates the concrete type implements the declared trait via `tc_lookup_impl`, emits **QZ0162: "'X' does not implement 'Trait'"** on failure, and registers via `tc_register_impl_return`.
- **`typecheck.qz:970-983`** — `tc_parse_type` accepts `"impl Trait"` prefix, resolves the trait name, returns the trait's `TYPE_STRUCT` id if the trait exists, errors **QZ0160** otherwise.

### 3.4 Call-site propagation
- **`typecheck_generics.qz:126-161`** — `tc_infer_expr_type_annotation` for `NODE_CALL` reads the callee's return annotation and, if it starts with `"impl "`, calls `tc_lookup_impl_return` to substitute the concrete type before returning the annotation string.
- **`typecheck_walk.qz:1552`** — same substitution path is used for `NODE_LET` binding type inference.

### 3.5 What's missing (the actual work)

Despite the scaffolding, real cases break because these call sites don't know about `impl Trait`:

1. **Generic function monomorphization** — `typecheck_generics.qz` and downstream mangling read the raw annotation string, producing `@take_three$1$impl MyIter` instead of `@take_three$1$Counter`. (Probe 2.)
2. **Argument-position `impl Trait`** — no implicit-generic-parameter desugaring. Instead, the typechecker treats the arg annotation as literal, calls get dispatched against the first matching impl statically, and two different concrete callers collapse into one monomorphic body. (Probe 5 — silent miscompile.)
3. **Bounded trait bound checking** — `tc_validate_trait_bounds` does not check whether an `impl Trait`–typed argument satisfies the declared bound by resolving through `tc_lookup_impl_return`. (Probe 2 corollary.)
4. **Bounded generic struct fields hang the typechecker.** Pre-existing bug discovered during probe phase — `struct W<C: Counter> { inner: C }` OOMs/hangs. Unbounded fields work, but for the world-class `iter.qz` rewrite we need bounded struct fields to work correctly. Must be fixed before Phase 6.
5. **Opacity is not enforced.** Current `tc_lookup_impl_return` substitutes the concrete type into bindings, so `var x: VecIter = iter(v)` compiles. This leaks the abstraction boundary and prevents refactor-safety. Must be fixed by introducing an opaque-marker annotation path.
6. **`Iterable<T>`** — described here as a `iter(): Int` stub with a bogus default body. (Updated: `std/traits.qz:141-142` now carries the real shape — `trait Iterable<T> { def iter(self): impl Iterator<T> }` — so this problem is resolved.)
7. **`std/iter.qz`** — still closure-based; does not use `impl Iterator<Int>` anywhere.
8. **No tests.** Zero qspec coverage for `impl Trait`. Regressions will land silently.
9. **No documentation.** `QUARTZ_REFERENCE.md` does not mention the feature. Users can't find it.

## 4. Design

### 4.1 Surface syntax

Return position:
```qz
def iter(self): impl Iterator<Int>
  return VecIter { data: @items, index: 0 }
end
```

Argument position (sugar for `<T: Trait>`):
```qz
def drain(src: impl Iterator<Int>): Int
  ...
end
# equivalent to
def drain<T: Iterator<Int>>(src: T): Int
  ...
end
```

Trait method position (stretch goal):
```qz
trait Iterable<T>
  def iter(self): impl Iterator<T>
end
```

No changes to existing trait or generic syntax.

### 4.2 Semantics

#### 4.2.1 Return position

1. **Inference is mandatory.** The function body must unambiguously determine a single concrete return type. All `return` expressions must produce the same concrete type (QZ0161 on conflict, already emitted).
2. **Trait satisfaction is mandatory.** The inferred concrete type must have an `impl Trait for ConcreteType` block in scope (QZ0162, already emitted).
3. **Opacity is mandatory.** Callers see an opaque-type identity, not the concrete type. This is the Rust/Swift world-class model and is shipping in the MVP. Specifically:

   - Each `impl Trait`–returning function has a unique **opaque type identity** derived from its fully-qualified name: `impl Trait@module$funcname`. Two calls to the same function yield the same opaque identity (and are therefore type-compatible); calls to different functions yield distinct identities.
   - For generic `impl Trait` functions (e.g. `def iter<T>(src: Vec<T>): impl Iterator<T>`), opaque identity parameterizes over the generic args by substitution, just like any other generic type reference. `iter<Int>` and `iter<String>` produce distinct opaque identities the same way `Vec<Int>` and `Vec<String>` are distinct types.
   - Callers **cannot write the concrete type in a source-level annotation**. `var x: VecIter = iter(v)` is a type error (QZ0167 below) because the declared annotation `VecIter` does not match the opaque identity `impl Iterator<Int>@iter<Int>`. The user must write `var x = iter(v)` and let inference do its job.
   - Callers **can still call methods** on an opaque-typed value. UFCS dispatch resolves the opaque identity through a new `tc_lookup_impl_return_concrete(func_name)` helper to find the underlying concrete type, then dispatches to `ConcreteType$method` normally. Method dispatch is unchanged at the codegen layer — only the annotation-propagation path differs.
   - Opacity is one-way. The compiler can always see through an opaque identity (for monomorphization, method dispatch, Send/Sync checks). The *source language* cannot. This matches Rust's "partial opacity" model exactly.

   The implementation surface is small: `tc_lookup_impl_return` keeps its current behavior but gains a sibling `tc_lookup_impl_return_opaque` that returns the opaque marker string; `tc_infer_expr_type_annotation` for NODE_CALL calls the opaque sibling; `tc_types_match` gains an opaque-identity branch that treats `impl X@F` and `impl X@G` as distinct even when the underlying concretes match, and rejects assignment to explicit-concrete annotations.

4. **No inline cycle.** If a function returning `impl Trait` recursively calls itself, inference diverges. We detect and emit **QZ0163: "recursive impl Trait inference requires explicit intermediate type"**.

5. **Refactor-safety property.** Because callers see the opaque identity, changing the concrete return type of a function (e.g. `stack.iter()` switching from `StackIter` to `IndexedStackIter`) is a non-breaking change. No caller can depend on the concrete type because no caller can name it. This is the entire point of opacity and is one of the strongest API-stability guarantees Rust/Swift provide.

#### 4.2.2 Argument position

Argument-position `impl Trait` desugars at parse time to an implicit generic parameter. That is:

```qz
def drain(src: impl Iterator<Int>): Int
```

becomes, during resolver's `resolve_collect_funcs` phase:

```qz
def drain<_T0: Iterator<Int>>(src: _T0): Int
```

where `_T0` is a compiler-generated, unreferenceable type parameter name. Rule: the desugared parameter name is `_impl_N` where N is the position index of the `impl Trait` occurrence in the signature.

This means **per-call-site monomorphization goes through the existing generic pipeline** (`tc_infer_type_param_mapping`, `tc_substitute_annotation`, the existing trait-bound validator). We don't need a parallel mechanism. The probe-5 silent miscompile disappears because two different callers now instantiate two different monomorphized copies of `drain`.

**Why not dynamic dispatch / vtable?** Because Quartz's entire runtime type model is "everything is i64, methods dispatch by static name lookup at compile time." Adding vtables would require a second runtime representation (fat pointers), a new dispatch path, and new codegen rules. Monomorphization is the honest Quartz answer.

**Why not treat it as the annotation-level placeholder it is today?** Because that's the probe-5 silent miscompile. There is no correct non-monomorphizing implementation.

#### 4.2.3 Trait method position (stretch)

Same model as Rust RPITIT. A trait method declared as `def iter(self): impl Iterator<T>` requires every `impl` of that trait to provide a method whose concrete return type satisfies `Iterator<T>`. The impl-time concrete type is known statically (because impl blocks name the `Self` type), so monomorphization through trait impls works identically to direct calls.

Enforced restriction: traits with `impl Trait` return types in any method are **not usable as trait objects**. Quartz has no `dyn Trait` today so this is moot, but we emit a forward-compatible error if anyone tries `Vec<Box<dyn Iterable>>` in the future.

### 4.3 Data model changes

Minimal. The existing `impl_return_*` vectors cover the feature. Two additions:

1. **`func_impl_arg_positions: Vec<Vec<Int>>`** — per-function, the indices of parameters that started life as `impl Trait` (to drive implicit-generic desugaring in the resolver).
2. **`func_synthesized_type_params: Vec<Vec<String>>`** — per-function, the implicit generic parameter names generated from argument-position `impl Trait`. Appended to existing `func_type_params`.

Both are populated at resolve time, before typecheck. They let the typechecker and monomorphizer treat `impl Trait` argument positions as real generic parameters without special-casing.

### 4.4 Algorithm changes

#### Resolver (`self-hosted/resolver.qz`)

New pass, call it `resolve_desugar_impl_trait_args`, inserted **before** `resolve_desugar_multiclause`. For each `NODE_FUNCTION`:

1. Walk parameter list. For each param whose annotation starts with `"impl "`:
   a. Generate a synthetic type-param name `_impl_N`.
   b. Rewrite the parameter annotation to `_impl_N`.
   c. Append `_impl_N: TraitName` to the function's type-param bounds string.
2. No change for return-position `impl Trait` — that's already handled by the existing infer-from-body path.

This is a ~60-line addition. It's a source-to-source transform on the AST, with no effect on hand-written generic functions that already work.

#### Typechecker (`self-hosted/middle/typecheck_*.qz`)

Three targeted fixes:

1. **`tc_infer_type_param_mapping` (typecheck_generics.qz:274)** — when inferring the concrete type for a synthetic `_implN` param from the argument expression, if the argument is a call expression whose callee returns `impl Trait`, resolve through `tc_lookup_impl_return` before recording the mapping. This is the probe-2 fix.
2. **`tc_substitute_annotation` (typecheck_generics.qz:349)** — when substituting `_implN` out of a downstream annotation, the substitution target is the concrete type (already in the mapping), not the literal string `impl Trait`. Verify this is already the case; if not, fix.
3. **`tc_validate_trait_bounds` (typecheck_registry.qz:1041)** — when the argument expression is `impl Trait`–typed at the source level, resolve to concrete before checking the bound. Accept the bound as satisfied if the concrete type has the required `impl` block.

#### Mangler

The function-symbol mangler assembles names like `@take_three$1$Counter` from the function name plus type param substitutions. The bug in probe 2 is that when the substitution map contains the unresolved string `"impl MyIter"`, the mangler appends it literally. Fix: mangler resolves `impl Trait` prefixes through `tc_lookup_impl_return` before emitting symbol components. Belt-and-suspenders: also assert that no symbol component contains whitespace, to catch analogous bugs loudly rather than silently.

Location to confirm during implementation: the mangler is under `self-hosted/shared/string_intern.qz` (function `mangle`) and wrappers in `typecheck_generics.qz`. The fix may belong in the mapping computation, not the mangler itself.

#### Codegen

No change. The typechecker propagates concrete types via `ast_set_str2` on CALL nodes. MIR and LLVM codegen already dispatch through those annotations. Monomorphization already generates per-call-site symbols for generic functions. The fixes above feed the correct concrete types into existing pipelines.

### 4.5 `Iterable<T>` redesign

`std/traits.qz:133-137` becomes:

```qz
## Types implementing Iterable<T> can produce a fresh iterator over T values.
## The iterator type is opaque at the trait level but concrete at each impl site,
## enabling method dispatch through the concrete type without runtime boxing.
trait Iterable<T>
  def iter(self): impl Iterator<T>
end
```

No default body, no stub. Every collection under `std/collections/` adds an explicit `impl Iterable<Int> for Collection end` — auto-satisfied by the existing inherent `iter()` returning the concrete `CollectionIter` struct.

Bounded generics over `Iterable<T>` become possible for the first time:

```qz
def sum_all<C: Iterable<Int>>(collection: C): Int
  var it = collection.iter()
  var total = 0
  while true
    match it.next()
      Some(v) => total = total + v
      None => return total
    end
  end
  return total
end
```

### 4.6 `std/iter.qz` modernization

Replace the closure-based adapter model with `impl Iterator<Int>` throughout:

```qz
struct MapIter<I: Iterator<Int>>
  source: I
  f: Fn(Int): Int
end

impl Iterator<Int> for MapIter<I>
  def next(self): Option<Int>
    var v = $try(self.source.next())
    var f: Fn(Int): Int = self.f
    return Option::Some(f(v))
  end
end

def iter_map<I: Iterator<Int>>(src: I, f: Fn(Int): Int): impl Iterator<Int>
  return MapIter { source: src, f: f }
end
```

**Prerequisite: bounded generic struct fields must work.** Probe results during planning revealed a pre-existing compiler hang/OOM when declaring `struct W<C: Counter> { inner: C }` — the typechecker goes into an infinite loop processing the bound on a field-typed generic parameter. Same symptom for `impl<T: Counter> Counter for W<T>`. Unbounded generic fields (`struct W<T> { inner: T }`) work fine, including UFCS dispatch via `self.inner.method()` at monomorphization sites.

The fallback — unbounded struct + bounded function-level `<I: Iterator<Int>>` on constructors — *would* let us ship `iter.qz` without fixing the hang. Prime Directive 6 says no holes left behind, and Prime Directive 1 says take the harder path. Since the correct form of the feature is `struct MapIter<I: Iterator<Int>>` and we're going to need it eventually, we bundle the bound-hang fix into this sprint as a dedicated phase before the `iter.qz` rewrite. That way `iter.qz` ships with the correct spelling on day one and we don't accumulate debt we'll have to pay later.

All terminal ops (`iter_collect`, `iter_sum`, `iter_fold`, `iter_any`, `iter_all`, `iter_find`, etc.) take `I: Iterator<Int>` directly. The `Fn(): Option<Int>` closure type vanishes from the public API.

Adapter list to modernize: `map`, `filter`, `take`, `skip`, `take_while`, `enumerate`, `zip`, `chain`, `flat_map`, `scan`. Terminal list: `collect`, `sum`, `count`, `fold`, `any`, `all`, `find`, `for_each`, `min`, `max`.

### 4.7 Error model

Existing:
- **QZ0160**: impl Trait on an unknown trait name.
- **QZ0161**: impl Trait return type conflict between return statements.
- **QZ0162**: concrete type does not implement declared trait.

New (to be added):
- **QZ0163**: recursive impl Trait inference — requires explicit intermediate type.
- **QZ0164**: impl Trait in argument position to a variadic or extern function (both illegal, flagged explicitly).
- **QZ0165**: concrete type ambiguous — no return statements in body to infer from (e.g. `def f(): impl Iterator<Int> = panic("todo")` — no return to infer from).
- **QZ0166**: trait with `impl Trait` return method used in a dyn-trait–like position (forward-compat placeholder; Quartz has no `dyn Trait` today but reserves the error code).
- **QZ0167**: opaque type cannot be assigned to an explicit concrete annotation. E.g. `var x: VecIter = iter(v)` where `iter` returns `impl Iterator<Int>`. Help message: "opaque types cannot be named explicitly — drop the annotation (`var x = iter(v)`)".
- **QZ0168**: opaque types from different origins compared or unified. E.g. `if cond then make_a() else make_b() end` where `make_a` and `make_b` both return `impl Iterator<Int>` but are different functions — their opaque identities differ and cannot unify. Help message: "two functions returning `impl Trait` produce incompatible opaque types even when the concrete types match — extract a shared type alias or hoist the shared concrete type".

Each error includes a hint suggesting the explicit-generic rewrite where applicable.

### 4.8 Test plan

One comprehensive qspec file, `spec/qspec/impl_trait_spec.qz`, with ≥20 test cases covering:

1. **Simple return** — function returning `impl Trait`, caller uses result directly.
2. **Multi-return unification** — single concrete type, passes.
3. **Multi-return conflict** — two different concrete types, QZ0161.
4. **Trait satisfaction** — concrete type implements trait, passes.
5. **Trait violation** — concrete type does not implement trait, QZ0162.
6. **Inline chain** — `f().method()` where `f` returns `impl Trait`.
7. **Let binding** — store `f()` in var, call method later.
8. **Argument position, single impl** — probe-4 equivalent.
9. **Argument position, multiple impls** — probe-5 equivalent, MUST return correct values.
10. **Argument position, desugar verification** — via --dump-ast or equivalent, confirm implicit generic param was synthesized.
11. **Bounded generic composition** — `fn sum<T: Iterator<Int>>(src: T)` called with `make_counter()`, probe-2 equivalent, MUST NOT error.
12. **Cross-module** — `impl Trait` return in one file, called from another.
13. **Generic impl Trait** — `def iter<T>(): impl Iterator<T>` where `T` is a type param.
14. **Trait method (RPITIT)** — stretch; omit if not in MVP.
15. **`Iterable<T>` bounded generic** — `sum_all(collection: C)` where `C: Iterable<Int>`.
16. **Each `std/collections/` type** — explicit round-trip through `Iterable<T>`.
17. **Each `std/iter.qz` adapter** — map, filter, take, skip, zip, chain, flat_map, scan.
18. **Each `std/iter.qz` terminal** — collect, sum, count, fold, any, all, find, min, max.
19. **Closure-free combinator chain** — `vec_iter(v).map(f).filter(p).collect()`-equivalent.
20. **Recursive impl Trait detection** — QZ0163.
21. **Empty body** — QZ0165.
22. **Trait bound propagation** — `impl Trait` arg passed through one generic to another.

Plus negative tests for each error code.

### 4.9 Backward compatibility

None required. Quartz is pre-release. The `std/iter.qz` rewrite is a breaking change at the source level, but no external users exist. Internal callers get rewritten in the same commit that lands the rewrite.

The stub `Iterable<T>` trait in `std/traits.qz` currently has zero impls in the tree (verified via grep). Replacing it is purely additive for every consumer.

## 5. Tensions and tradeoffs

Explicit list of every design choice with a real tension, and how we're resolving it:

1. **Opacity vs transparency — shipping opaque.** World-class: Rust/Swift opaque semantics. We ship opaque in the MVP. The original draft of this design deferred opacity citing "no versioned library story," but that framing was too narrow — opacity also protects *intra-project* refactoring, which is relevant from day one. Cost: ~2-4h on top of a transparent-only MVP. See §4.2.1 for the implementation sketch.

2. **Auto-trait leakage (Send/Sync).** World-class: `impl Iterator<Int>` implicitly also satisfies `Send` if the concrete type is `Send`, and bounded-generic call sites with `T: Send` accept it. We will implement this. Quartz's `Send`/`Sync` checker (`middle/typecheck_concurrency.qz`) already works on concrete types — the fix is to make the bound validator resolve `impl Trait` to concrete before the Send check. Bundled into Phase 3.

3. **Bounded generic struct fields.** Pre-existing compiler hang/OOM discovered during probe phase: `struct W<C: Counter> { inner: C }` and `impl<T: Counter> ... for W<T>` both hang the typechecker. Unbounded generic fields work fine. The fallback is to use unbounded-struct + bounded-function form in `std/iter.qz`, but that's a silent compromise. Per Prime Directive 6, we bundle the hang fix into this sprint as a dedicated phase before the `iter.qz` rewrite. `iter.qz` ships with the correct `struct MapIter<I: Iterator<Int>>` form on day one.

4. **Type-alias `impl Trait` (TAIT).** World-class: named opaque types (`type Foo = impl Iterator<Int>`). Not in MVP. Required when users want to store `impl Trait` values in long-lived contexts (struct fields of non-generic structs, statics, globals). For the iterator combinator story we can get away without it, because adapter structs are already generic over the upstream type. Filed as `IMPL-TRAIT-TAIT` in the roadmap for a follow-up sprint.

5. **Structural opaque return types.** `def pair(): (impl Iterator<Int>, impl Iterator<Int>)` — Swift's SE-0328. Not in MVP — tuples of opaque types require the type system to track structural positions of opaque identity, which is a separable piece of work. Filed as `IMPL-TRAIT-STRUCTURAL`.

6. **Recursive `impl Trait`.** `def f(): impl Iterator<Int> = if cond then f() else concrete end` — fundamentally requires forward type declaration. We emit QZ0163 telling the user to name the intermediate type explicitly. This is what Rust did until TAIT landed, and is the well-researched answer.

7. **`std/iter.qz` rewrite scope.** World-class: modernize every adapter *and* every terminal, delete the closure-based API entirely. We will. The scope is ~500 lines and meets the bar.

8. **Symbol mangling robustness.** World-class: mangler rejects whitespace and special characters in components at assembly time with an assertion, so future bugs fail loudly. We will add this assertion as part of the Phase 1 fix.

9. **Opacity comparison semantics.** When two calls to different opaque-returning functions need to unify (e.g. in a match-arm result or a ternary), Rust emits a type error; Swift emits a type error. We follow Rust/Swift and emit QZ0168. The alternative (auto-unifying on underlying concrete type) would leak opacity. This is the strict answer.

## 6. Non-goals

Explicitly out of scope for this sprint:

- `dyn Trait` runtime dispatch. Quartz doesn't have it, and `impl Trait` doesn't need it.
- `async fn` returning `impl Future`. Quartz already has a separate async mechanism via state machines.
- Lifetime capture rules. Quartz has no explicit lifetimes.
- `where` clause changes. Existing bounded-generic syntax is sufficient.
- Renaming existing traits. `Iterator<T>` and `AsyncIterator<T>` stay as-is.

## 7. Implementation plan — see PHASES section in handoff doc

The atomic, commit-sized phases live in [`docs/handoff/impl-trait-sprint.md`](handoff/impl-trait-sprint.md) so they can be updated independently of the design as the sprint progresses.

## 8. References

Primary sources:

- **[Rust RFC 1522: Conservative impl Trait](https://rust-lang.github.io/rfcs/1522-conservative-impl-trait.html)** — original return-position design
- **[Rust RFC 1951: Expand impl Trait](https://rust-lang.github.io/rfcs/1951-expand-impl-trait.html)** — argument position, implicit generics
- **[Rust RFC 3425: Return-position impl Trait in Traits](https://rust-lang.github.io/rfcs/3425-return-position-impl-trait-in-traits.html)** — trait method return types (RPITIT)
- **[Rust RFC 2515: Type alias impl Trait](https://rust-lang.github.io/rfcs/2515-type_alias_impl_trait.html)** — TAIT, struct fields, recursive contexts
- **[Rust Reference: impl Trait types](https://doc.rust-lang.org/reference/types/impl-trait.html)** — normative spec
- **[rustc Dev Guide: Opaque type inference](https://rustc-dev-guide.rust-lang.org/opaque-types-impl-trait-inference.html)** — implementation notes, hidden type registration, backwards-compat hacks
- **[Swift SE-0244: Opaque Result Types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0244-opaque-result-types.md)** — `some Protocol`, opacity as API boundary
- **[Swift SE-0328: Structural Opaque Result Types](https://github.com/apple/swift-evolution/blob/main/proposals/0328-structural-opaque-result-types.md)** — composition in tuples/arrays

Secondary and conceptual:

- **[Varkor: A new perspective on impl Trait](https://varkor.github.io/blog/2018/07/04/a-new-perspective-on-impl-trait.html)** — the type-inference framing that shaped rustc's implementation
- **[LWN: Existential types in Rust](https://lwn.net/Articles/970186/)** — accessible overview of the stabilization timeline
- **[Haskell Wiki: Rank-N types](https://wiki.haskell.org/Rank-N_types)** — theoretical foundation
- **[GHC User Guide: Arbitrary-rank polymorphism](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/rank_polymorphism.html)** — the Odersky-Läufer algorithm reference

Internal Quartz documents:

- [`docs/HANDOFF_COMPILER_HOLES.md`](HANDOFF_COMPILER_HOLES.md) — last session's handoff, mentions Iterable as a design discussion item
- [`docs/QUARTZ_REFERENCE.md`](QUARTZ_REFERENCE.md) — language spec (will be updated with `impl Trait` section after sprint completes)
- [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) — compiler pipeline reference
