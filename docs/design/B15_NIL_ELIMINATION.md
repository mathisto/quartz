# B.15 — Nil Elimination: research-first sub-memo

> **Status**: ✅ **COMPLETE 2026-06-13.** Ratified 2026-06-09 (Q1–Q4 + the Q6 bare-`Int` correction — §9). B.15a–c
> (the `nil`-literal wall), N3.1 (de-existentialization + the bare-`Int` wall, §11.7–§11.45), and B.15d / N3.2 (the
> boxed-pointer `None` niche — zero-cost `Option<boxed-T>`, §11.46) are all LANDED. Only the separately-gated
> default-`struct`-layout flip (a different axis — `MEMORY_MODEL_V3.md §6 Phase 4`) remains.
> **Author**: Design session, 2026-06-09
> **Gates**: N3 (the boxed-pointer niche + the default-layout flip — `MEMORY_MODEL_V3.md §14.5`). This memo is the
> "research-first sub-memo before this sub-step" that §14.5 N3 and §14.6 name as the prerequisite.
> **Cross-refs**: `MEMORY_MODEL_V3.md §3.4, §14.5 N3, §14.6`; `docs/design/nil.md` (the *prior* permissive philosophy this reverses);
> ROADMAP B.15.

---

## 0. TL;DR for the ratifier

- **What B.15 is**: make `Option<T>` the *only* way to express "no value." Forbid bare `nil`-as-a-value in non-FFI code.
  `nil` survives only at the C-FFI boundary (where `NULL == 0` is the real ABI sentinel).
- **Why it's a one-way door**: it changes a *language rule* (today `nil` is accepted anywhere as `0`). Once stdlib + tooling
  assume "absence ⇒ `Option`," reverting means re-permitting sentinel-`nil` everywhere. That's the irreversibility — **not** the
  code migration.
- **Why now / why it's small**: the audit (§3) shows the actual sentinel-`nil` surface is **one stdlib module** (`std/toml/`).
  The compiler itself uses sentinel-`nil` **zero** times. Every retrofit language (Dart, C#, Kotlin) went *gradual* because it
  carried millions of lines and external users; Quartz has neither, so it can make the clean break they couldn't (§4).
- **Why it's co-dependent with the big niche**: `nil == 0` collides with the would-be `None == 0` niche over boxed `T`. The
  general `Option<boxed-T>` zero-cost niche — the headline memory win — is **only sound once B.15 forbids `nil` in non-`Option`
  slots.** They must land together (§6). This is the §14.6 dependency inversion: B.15 makes the niche sound; the niche makes B.15
  free.
- **Status**: ✅ ratified (§9) — strict `None`-only absence, `nil` kept as `CPtr`-null sugar, checked+unsafe FFI bridge, and the
  diagnostic is a bare-`Int` wall (not a `nil`-token check, the soundness-critical refinement). B.15a (port `std/toml`) is next.

---

## 1. The decision being gated

Today (`nil.md`, the January model): `nil`, `false`, and `0` are the *same i64 value* at runtime; `nil` is "accepted anywhere";
a function may `return nil` from a non-`Option` return type with no compile-time signal. This was a deliberate
"systems-language, C-like" choice — and it is exactly Tony Hoare's billion-dollar mistake, imported on purpose.

B.15 reverses the *philosophy* (not the runtime model): absence becomes a typed, checked thing (`Option<T>`), and `nil`-as-value
becomes a compile error outside FFI. The runtime representation is unchanged — `None` is still `0` in the niche cases, `nil` is
still `0` at the `extern` boundary. **B.15 is a type-system rule, not a representation change.** (The representation change is N3's
*default-layout flip*, a separate gate.)

This is pre-launch-worthy precisely because it is a one-way door on the type system: the longer Quartz ships with permissive
`nil`, the more code assumes it, and the migration grows. The audit says that window is still open — barely-used — so the cost of
closing it is near its all-time low.

---

## 2. Prior art — two poles and a retrofit playbook

Two design poles, then the migrations that bridge them (the part Quartz hasn't researched until now).

### 2.1 Born null-safe (the target shape)

- **Rust** — no `null`. Absence is `Option<T>`. The payoff Quartz is chasing: the **null-pointer optimization** is a *guaranteed*
  layout contract — `Option<Box<T>>`, `Option<&T>`, `Option<NonNull<T>>` are the same size as the payload, `None` hiding in the
  null pointer / the `NonZero` niche. `NonNull<T>`/`NonZero` exist precisely to *expose a niche to the optimizer*. Quartz's N1/N2
  (`Bool`, `NonZero`, `&T`) already replicate the small-niche half; the boxed-pointer niche is the big half, and it needs B.15.
- **Swift** — `Optional<T>` (`T?`) from v1; `nil` is `Optional.none`, not a pointer value. Force-unwrap `!` is the explicit escape
  hatch. The one cautionary tale: the *implicitly-unwrapped optional* (`T!`) was a transitional crutch for un-audited
  Objective-C interop and has been steadily walled off — a warning against a permanent "trust me" mode (relevant to how we treat
  FFI; §5).
- **Zig** — optionals `?T`; `null` is only valid for optional types; `orelse` / `if (x) |v|` unwrap. No null for non-optional
  pointers. The cleanest "designed-right-from-day-one" pole.

### 2.2 The retrofit playbook (the new research — how you migrate an *existing* language off pervasive null)

- **Dart sound null safety (2020–2021)** — the most complete real-world migration. Strategy: *incremental, file-by-file*, ordered
  **leaf-libraries-first** (migrate things with no intra-package imports, then their dependents, then the highly-connected core).
  A **mixed-version interop period** ran "unsound" — null could still escape from an un-migrated library at runtime — and only
  *fully* migrated programs got sound guarantees. An automated `dart migrate` tool inferred and inserted `?`/`!`/`required`/`late`,
  with human review before commit. **Lesson that transfers**: leaf-first ordering. **Lesson that does *not* transfer**: the entire
  mixed-version-unsound apparatus exists to keep a giant ecosystem compiling during a months-long migration. Quartz has no
  ecosystem to keep compiling.
- **C# nullable reference types (C# 8, 2019)** — opt-in per-file/region via `#nullable enable`; enforcement is **warnings, not
  errors**, behind a compiler switch, so old code keeps compiling. Explicitly designed so that *"if it can't find new problems with
  old code, it isn't worth its salt"* — i.e. the new warnings on existing code are the *point*. Migration heuristic: **"start at
  the center"** — annotate high-fan-in, low-dependency types (DTOs, domain models) first; one change there clears warnings
  everywhere. Entirely compile-time, **zero runtime cost**. **Lessons that transfer**: compile-time-only; center-out for the
  highest-leverage types. **Lesson that does *not* transfer**: warnings-not-errors is a concession to backward compatibility we
  don't owe anyone.
- **Kotlin (2011–)** — two type universes, `T?` (nullable) vs `T` (non-null), enforced at compile time, with runtime
  intrinsics-checks at the boundary. The decisive idea for us: **platform types** (`T!`). When a value crosses in from
  un-annotated Java, the compiler *cannot* know its nullability, so it declines to enforce and inserts a runtime null-check at the
  point the value enters Kotlin-controlled non-null territory. **This is the model for Quartz's FFI boundary** (§5): the one place
  the compiler genuinely cannot prove non-null is the `extern "C"` edge, and Kotlin shows the principled handling — defer at the
  boundary, check on entry, don't poison the whole type system to accommodate it.

### 2.3 Synthesis — what Quartz takes

| Source | Take | Drop |
|--------|------|------|
| Rust | guaranteed niche layout (the *contract*, not opportunistic); `NonZero`/`&T` as niche donors | — |
| Swift | `Option<T>` + explicit `unwrap` escape hatch | the implicitly-unwrapped "trust me" mode (cf. FFI, §5) |
| Dart | **leaf-first migration ordering** | mixed-version unsound interop; an automated migration tool |
| C# | compile-time-only; **center-out** for high-leverage types | warnings-not-errors; opt-in `#nullable` regions |
| Kotlin | **platform-types model for the FFI boundary** (§5) | a permanent platform-type *category* in the surface language |

The thread: the retrofit languages spent enormous design effort on *gradualness* — opt-in regions, warning modes, mixed-version
interop, migration tooling. **Every one of those mechanisms is a tax paid for backward compatibility and an external ecosystem.**
Quartz owes that tax to no one (§4), so it skips the entire apparatus and keeps only the *destination* (Rust/Swift/Zig's
born-null-safe shape) plus two structural ideas: leaf-first ordering and the platform-types FFI boundary.

---

## 3. Quartz's current `nil` reality (audit, 2026-06-09)

Measured, not estimated. `grep` across `self-hosted/` and `std/`:

**Sentinel-`nil` as a value (the thing B.15 migrates):**
- `self-hosted/` (the entire compiler): **0 sites.** The compiler already expresses absence with `Option`/explicit tags. The
  fixpoint is therefore *trivially* unaffected by the diagnostic — the compiler can't trip a rule it never violates. (Same safety
  property that made N1/N2 fixpoint-trivial.)
- `std/`: **the `std/toml/` module** — but with a sharp correction found during B.15a (2026-06-09). The `grep` counted
  `manifest.qz` (1 `return nil` + ~16 `!= nil` guards) and `parser.qz`/`value.qz`. **`manifest.qz` has never compiled** (no
  importer; bit-rotted against a non-existent generic `TomlResult<T>` API — see `docs/bugs/TOML_MANIFEST_NEVER_COMPILED_BITROT.md`),
  so its `nil` sites are in *dead* code and were never a live concern (QZ0213 only fires on compiled code). The **live** non-FFI
  sentinel surface is exactly `value.qz` + `parser.qz` (table-navigation returning `nil`/bare-`0` "null handle") plus the one real
  external consumer `tools/lint.qz`. **✅ That live surface is ported (B.15a, commit `a85b691f`):** `toml_table_get` /
  `toml_get_path` / `toml_navigate_to_table` → `Option<T>`; both the explicit-`nil` and the bare-`0` (Q6) sentinels eliminated;
  toml_spec 36/36 + stringify + traits green.

**`nil` machinery that is NOT a sentinel-value (stays, or is orthogonal):**
- Lexer/parser: `TOK_NIL`, `NodeNilLit`, `nil`-literal parsing — the literal stays (it lowers to `0`); B.15 governs *where it's
  accepted as a value*, not whether the token exists.
- Operators/predicates: the `??` nil-coalescing operator, the `.nil?` / `is nil` pointer predicates (`typecheck_expr_handlers.qz`)
  — these are *pointer/FFI* idioms ("is this raw pointer null?"), legitimately about `CPtr`, not about typed absence. They stay,
  scoped to pointer types.
- FFI-boundary comments (`std/ffi/socket.qz`, `std/ffi/time.qz`): "returns pointer to dst, `nil` on error" — real C `NULL`
  semantics at the `extern` edge. Stays (§5).
- Truthiness: `0`/`false`/`nil` all falsy (`typecheck_helpers.qz`). Unchanged — a runtime-representation fact, orthogonal to the
  type rule.

**Conclusion**: the migration is *port `std/toml` to `Option`*, plus *add one diagnostic*. The "one-way door" is the language
rule; the labor is a single, self-contained stdlib module with no external consumers.

---

## 4. The Quartz-specific divergence: clean break, not gradual retrofit

The retrofit playbook (§2.2) is uniformly *gradual* — and every gradual mechanism exists for a reason Quartz does not have:

| Retrofit mechanism | Why it exists | Does Quartz have that reason? |
|---|---|---|
| Opt-in `#nullable` regions (C#) | millions of lines can't flip at once | No — one stdlib module is the whole surface |
| Warnings-not-errors (C#) | external code must keep compiling | No — zero external consumers (pre-launch absolutism, CLAUDE.md) |
| Mixed-version unsound interop (Dart) | a package ecosystem must interoperate during migration | No — the repo *is* the entire codebase in the world |
| Automated migration tool (Dart) | too many call sites for humans | No — 5 returns + one module's guards |
| Permanent platform-type category (Kotlin) | un-annotated Java is forever | **Partially** — the FFI boundary is forever, but it's *narrow* (§5) |

So Quartz's B.15 is the migration the retrofit languages *wish* they could have done: **flip the rule, port the one module, ship a
hard error from day one.** No warning phase, no opt-in, no mixed-version period, no tooling. The directive backing is explicit
(global D7 / project "Project Reality Check"): pre-launch, zero users, single codebase ⇒ delete-and-replace, don't deprecate on a
timeline.

The one piece of the retrofit playbook Quartz *keeps* is **leaf-first ordering** within the `std/toml` port (migrate `parser.qz`'s
leaf helpers before `manifest.qz`'s consumers), and **center-out** intuition for *which* type to introduce first (a single
`Option<TomlValue>` / `Option<Table>` at the navigation core clears every guard at once — C#'s "start at the center").

---

## 5. The FFI boundary = Kotlin's platform types

The one place the compiler genuinely cannot prove non-null is the `extern "C"` edge: a C function returning `char*` may return
`NULL`, and that `NULL` is `0`, and it is *correct* for it to be `0`. `CPtr` null is the legitimate ABI sentinel and must stay
representable (`MEMORY_MODEL_V3.md §14.6`: "Never niche `CPtr`").

Kotlin's platform types are the principled handling, and Quartz is *better positioned* than Kotlin because its un-provable
boundary is **narrow and explicitly typed** (`CPtr`), not an open-ended "any value from Java":

- **At the boundary**: a C function's pointer return is `CPtr` (already true). `CPtr` is nullable by nature; `type_niche(CPtr) =
  none` (already true). The `.nil?` / `is nil` / `??` predicates are the *blessed* way to test it (they're pointer predicates —
  §3). No change needed; the boundary already works the way Kotlin's platform types do, minus the ambiguity.
- **Entering Quartz-controlled territory**: to turn a `CPtr` into a typed value, the programmer goes through an explicit
  `cptr_to_option(p): Option<T>` (null ⇒ `None`) — the analog of Kotlin's boundary null-check and Swift's explicit unwrap. This is
  the *only* sanctioned `nil → Option` bridge, and it's where the "platform value enters the non-null world" check lives.
- **What we reject** (the Swift `T!` cautionary tale): a permanent implicit "this FFI pointer is definitely non-null, trust me"
  mode that silently flows `CPtr` into a non-`Option` typed slot. If you want the value, you go through `cptr_to_option` (or the
  explicit-unsafe `cptr_unwrap_unchecked`, the `nonzero_new_unchecked` analog — Rust's `unwrap_unchecked`). No implicit
  laundering.

**The bridge IS the boxed-pointer-niche constructor in FFI clothing.** For a boxed Quartz `T`, `cptr_to_option(p)` is
`if p == 0 → None(=0) else Some(p)(=p)` — which under the boxed-pointer niche (B.15d) is **runtime identity**: the result value
already *is* `p`, and `p == 0` reads back as `None` at read-time, no branch. This is structurally the same lowering as
`nonzero_new` (`mir_lower_call` identity intercept, `ba9996b9`), and `cptr_unwrap_unchecked(p): T` is the `nonzero_get` analog
(bare-pointer identity). So the FFI bridge costs an explicit tag-construct *before* B.15d (Option-over-boxed still spills) and
becomes **zero-cost exactly when B.15d lands** — the bridge and the headline niche are one mechanism. Mirror the N2 surface
exactly: checked `cptr_to_option` + explicit-unsafe `cptr_unwrap_unchecked` (`nonzero_new`/`nonzero_new_unchecked` precedent).

Net: B.15 forbids `nil`-as-value in non-FFI code; the FFI edge keeps `CPtr`-null; the bridge between them is one explicit,
auditable function — the same runtime-identity pattern as the rest of the niche surface. The boundary is designed, not leaked.

---

## 6. Co-dependency with the boxed-pointer niche (the §14.6 inversion)

This is the load-bearing sequencing fact, restated so the ratifier sees why B.15 and the big niche are *one* landing, not two.

The largest niche surface by far is `Option<T>` for **T any heap-boxed type** (struct / enum / String / Vec / closure). In the
i64-existential model every boxed value is a non-null heap pointer, so `0` is its natural `None` niche — the direct analog of
Rust's guaranteed `Option<Box<T>>` NPO. This is the headline memory win: `Option<AnyBoxedThing>` costs **zero** extra bytes, no
tag word, no second allocation.

But it is **unsound today**: `nil` is literally `0` and "accepted anywhere," so a boxed-typed slot can legitimately hold `0` —
which collides with the would-be `None == 0` niche. A `var x: Widget = nil` (legal today) would be indistinguishable from
`None`.

Therefore:

```
B.15 (forbid nil-in-non-Option slots)  ──makes sound──▶  boxed-pointer niche
boxed-pointer niche (Option<T> zero-cost) ──makes free──▶  B.15 (no tag-word tax on mandatory Option)
```

They are mutually enabling. Land them together (N3), behind one fixpoint gate. The small niches (N1/N2: `Bool`, `NonZero`, `&T`)
were sound *without* B.15 because those types are non-null *regardless* of `nil` — which is exactly why they shipped first and why
they *prove the thesis* ("Option can be zero-cost") that motivates paying for B.15.

**Soundness argument for the boxed-pointer niche, post-B.15** (spec this):
- Premise 1: after B.15, the only way a boxed-typed slot holds `0` is via `Option<T> = None` (the diagnostic forbids *any* bare
  `Int` — `nil`/`0`/`k` — in a boxed non-`Option` slot, §7; the FFI bridge §5 routes `CPtr`-null through `Option`). This premise is
  exactly what the §7 bare-`Int` wall establishes — it is the *reason* the wall must be bare-`Int`-wide, not `nil`-token-narrow.
- Premise 2: a live boxed `T` is a heap pointer, always `≠ 0` (the allocator never returns `0`; this is already assumed
  everywhere).
- Therefore: for `Option<boxed T>`, `value == 0 ⇔ None` and `value != 0 ⇔ Some(ptr)` — the same K=1 range-membership discriminant
  N2 already generalized (`e0f366a3`), with `niche_start = 0`. No tag word, no box. ∎

The one new hazard vs. N1/N2: the compiler/std construct `Option<boxed T>` **widely**, so enabling the niche *changes the
compiler's own emitted IR* — the §14.4 *representation rebase*, the genuinely hazardous fixpoint event (not the trivial re-stamp
`Bool`/`NonZero` enjoyed). This is why N3 is gated and supervised, and why it travels with the QZ0212 erased-boundary audit
(§7) extended to boxed-pointer niches.

---

## 7. The `nil`-in-non-FFI diagnostic (QZ02xx)

The compile-time rule B.15 adds. One new diagnostic, mirroring the QZ0201/QZ0212 niche-soundness diagnostics already shipped.

> **🔑 The rule is "no bare `Int` into a boxed slot," NOT "no `nil` token" (soundness-critical correction, 2026-06-09).** In the
> i64-existential model `nil`, `false`, and `0` are the *same value*, so a `nil`-token-only check is trivially evaded by `return 0`
> — and worse, leaves B.15d **unsound**: if `0`-into-a-boxed-slot stays legal, `0` still collides with the `None == 0` niche after
> `nil` is banned. So the actual rule is: **a boxed-type slot accepts only a value of that boxed type; an `Option<T>` slot accepts
> only `None`/`Some(…)`; neither accepts a bare `Int` literal — whether spelled `nil`, `0`, or a variable `k: Int`.** This is
> exactly the NonZero *outbound wall* (`tc_is_simple_primitive` rejecting `Int → NonZero`, the `35fa1ad6` lineage) generalized
> from `NonZero` to all boxed types. Same machinery, wider domain — not new infrastructure. `nil` is then just the most *common*
> trigger, not the rule's subject.

> **🔑🔑 BUILD-TIME REALITY CHECK (2026-06-09, while starting B.15c) — the full bare-`Int` wall is NOT implementable pre-N3.** Two
> hard facts, both confirmed empirically:
> 1. **The existential typechecker cannot distinguish a bare `Int` from an erased boxed value.** `tc_expr` returns `TYPE_INT` for
>    struct/enum/container *values* (the existential model; see `tc_is_simple_primitive`'s own doc comment,
>    `typecheck_helpers.qz:498`). So "reject `Int` → boxed slot" cannot tell a real `Int` from a `Widget` flowing into a `Widget`
>    slot — it would be a false-positive firehose. The NonZero wall works *only* because it is gated to `tc_is_simple_primitive`
>    payloads (the handful of types where `tc_expr` is reliable); it does **not** generalize to all boxed types.
> 2. **The compiler relies pervasively on `Int`→boxed coercion.** `return 0` from a boxed-returning fn and `var w: Widget = 0`
>    **both compile today** (silent existential coercion), and there are **613 `return 0` sites in `self-hosted/` alone** — many
>    the "null-object sentinel" idiom. A bare-`Int` wall would fire on hundreds of the compiler's own sites: the *opposite* of
>    fixpoint-trivial.
>
> **Therefore the bare-`Int` wall (catching `return 0` / `Int`-var → boxed) requires de-existentialization — boxed values getting
> real, non-`i64` types the typechecker can distinguish. That IS the N3 representation flip.** The Q6 correction above stands as
> the *eventual* rule, but it lands **with N3/B.15d**, not as a standalone pre-N3 step. What is doable now is the
> **`nil`-literal-only** subset (below) — and that is enough to deliver B.15's headline ("`nil` is no longer a value").

**Two-stage diagnostic, matching the two-stage soundness:**

- **B.15c (doable now) — the `nil`-LITERAL wall.** Fires when the *syntactic* `nil` literal (`NodeNilLit`) flows into a
  non-`CPtr` boxed-`T` or `Option<T>` slot — `return nil` from `def f(): Widget`, `var x: Widget = nil`, `nil` into an
  `Option<T>` param (Q3-strict: use `None`). **Precise** (`NodeNilLit` is syntactic — no existential-erasure ambiguity, zero false
  positives) and **fixpoint-trivial** (audit 2026-06-09: **0** live `nil`-literal value-uses in `self-hosted/` *and* `std/` ⇒ the
  wall fires zero times in self-compile). Does **not** catch `return 0`/`Int`-var → boxed (stage 2). Delivers the headline rule:
  you cannot use `nil` as a typed value.
- **B.15d/N3 (gated) — the full bare-`Int` wall.** The Q6 generalization (`0`, `Int`-vars). Co-lands with the de-existentialization
  that makes it *possible* and the boxed-pointer niche that makes it *necessary* (the `0 == None` collision). This is why §6's
  soundness proof (premise 1) is an N3-era property, not a pre-N3 one.

- **Allows** (no diagnostic, both stages): `None`/`Some(…)` against an `Option<T>` slot. `nil` against a `CPtr` slot (FFI). The
  `.nil?`/`is nil`/`??` pointer predicates against `CPtr`. **(Ratified Q3: `nil` against an `Option<T>` slot is DISALLOWED — `None`
  is the only typed-absence spelling; see §9.)**
- **Message** (C#'s lesson — make it actionable): *"`nil` is not a value here (type `Widget`). Use `Option<Widget>` and return
  `None`, or — at an FFI boundary — keep the value as `CPtr` and bridge with `cptr_to_option`. (QZ0213)"*
- **Severity**: hard error from day one (§4 — no warning phase). Pre-launch absolutism.
- **Placement**: typecheck, at the assignment/return/arg coercion site where the expected type is known — near the NonZero
  outbound wall (`tc_types_compatible` / `tc_is_simple_primitive`, `35fa1ad6` lineage). For the `nil`-literal wall the trigger is
  the `NodeNilLit` operand, checked against the expected (annotation) type — not a general type-compatibility rule.

---

## 8. Migration plan (phased; the labor, distinct from the rule)

Ordering follows Dart-leaf-first + C#-center-out (§4), scoped to the one module that needs it.

1. **R-pre (this memo)** — research + design. ✅ *(no code)*.
2. **B.15a — port `std/toml` to `Option`. ✅ DONE 2026-06-09 (`a85b691f`).** Live surface = `value.qz` + `parser.qz` + the
   `tools/lint.qz` consumer (manifest.qz was dead/never-compiled — filed, reverted; §3). Both nil + bare-`0` sentinels gone;
   toml_spec 36/36 + stringify + traits green; compiler untouched (no fixpoint involved). Original plan below:
   Center-out: introduce `Option<TomlValue>` / `Option<Table>` at the navigation core
   (`parser.qz` `navigate_*`), then convert the 5 `return nil` → `return None` and every `if x != nil` → `match` / `is Some` /
   `x.is_some()`. Leaf helpers (`parser.qz`) before consumers (`manifest.qz`). This is a *pure stdlib refactor* — compiles and
   passes under today's permissive rule, so it lands and is verified **before** the rule changes (de-risks the flip: the module is
   already clean when the diagnostic turns on). Guard fixpoint trivially unaffected (compiler doesn't import `std/toml` in its own
   build).
3. **B.15b — the FFI bridge** (§5). **✅ DONE 2026-06-09 (`ee254ac6`) — `std/ffi/ptr.qz`** (new module, imported by nobody ⇒
   guard-free): `cptr_to_option(p: CPtr): Option<CPtr>` (forward, NULL→None) + `cptr_from_option(opt): CPtr` (reverse, None→NULL).
   **Design adjustment from the ratified Q2** (grounded at build time): the bridge is `Option<CPtr>`, *not* the generic `Option<T>`
   the memo first sketched — the real FFI idiom keeps pointers as handles (`cptr_to_int(p) == 0` for null), and reinterpreting a C
   pointer as a boxed Quartz `T` is rare/dangerous, not the common path. And `cptr_unwrap_unchecked` collapses into
   `cptr_from_option`: for `Option<CPtr>` there is no separate `NonNull` newtype, so "extract treating absence as NULL" and
   "unchecked unwrap" are the *same* operation (a distinct unsafe primitive earns nothing). `.unwrap()` remains the panic-on-None
   path. `option_cptr_bridge_spec` 6/6. (The socket/time "NULL on error" sites are `extern` decls + C-behavior comments, not
   Quartz wrappers surfacing a nullable `CPtr` — no genuine migration target today; the bridge is ready for new wrappers + the
   B.15c-driven migration.)
4. **B.15c — the `nil`-LITERAL diagnostic** (§7, QZ0213). **✅ DONE 2026-06-09 (`b338b2a4`).** Fires on `NodeNilLit` → non-`CPtr`
   boxed/`Option` slot at the **let** site (`typecheck_walk.qz` ~2620, before the simple-prim cross-check for a uniform diagnostic)
   and the **return** site (~4044, beside the existing String/Int literal return cross-check). Predicate
   `tc_nil_forbidden_type` (`typecheck_helpers.qz`): heap/reference types forbidden, scalars + `CPtr` + handles allowed. Scoped to
   the literal (bare-`Int` is N3-gated — §7). **guard PASSED** (gen1==gen2, 2808 fns — fixpoint-trivial as predicted: 0 live
   `nil`-literal sites). `nil_literal_wall_spec` 8/8 (struct/String/Vec/Option/return-struct reject; Int/CPtr/return-CPtr accept);
   `nil_spec` + sibling niche specs green; Rule-2 smokes green; **zero blast radius** (no existing spec/example used
   `nil`-into-boxed). **Arg-site (`f(nil)` into a boxed param) wired as a follow-up — same `NodeNilLit` + `tc_nil_forbidden_type`
   predicate, in the call-arg loop of `typecheck_expr_handlers.qz` (before the newtype cross-check so QZ0213 wins; skips
   default-mask gap positions). guard PASSED (gen1==gen2, 2808 fns — still 0 live sites); `nil_literal_wall_spec` now 13/13
   (added 5 arg-site cases: struct/String/Option reject, Int/CPtr accept).** All three coercion positions (let/return/arg) now
   covered for the `nil` literal.
5. **B.15d — the full bare-`Int` wall + boxed-pointer niche, co-land with N3.** Only *now* is the big niche sound (§6) AND the full
   wall *possible* (de-existentialization gives boxed values distinguishable types — §7). This is the supervised, fixpoint-gated,
   representation-rebase step. Travels with QZ0212 extended to boxed-pointer niches + a per-construction-site audit that no niche
   `Option<boxed>` crosses an erased generic boundary. **This sub-step is itself the N3 one-way door — separately ratified.**

B.15a–b shipped (reversible, fixpoint-trivial). B.15c (the `nil`-literal wall) is doable now, guard-gated, fixpoint-trivial. The
full bare-`Int` wall and the boxed-pointer niche both fall to B.15d/N3 — coupled by the *same* obstacle (existential erasure: the
wall needs boxed values to have real types; the niche needs `0` to mean only `None`). The clean factoring stands; only the
*boundary* moved: stage 1 (`nil` literal) is pre-N3, stage 2 (bare `Int`) is N3.

---

## 9. Ratified decisions (2026-06-09)

The one-way-door decisions, settled. (Recommendations above were all accepted; the bare-`Int` correction below was raised and
folded in during ratification.)

- **Q1 — Clean break. ✅ RATIFIED.** Hard error from day one, no warning/opt-in phase. Pre-launch + zero users + the one-module
  surface mean the gradual-retrofit apparatus (warnings, opt-in regions, mixed-version interop, migration tooling) is a
  backward-compat tax Quartz doesn't owe (D7, §4).
- **Q2 — FFI bridge: checked + explicit-unsafe escape. ✅ RATIFIED.** `cptr_to_option(p): Option<T>` (the sole sanctioned
  `nil→Option` path, null⇒`None`) **plus** `cptr_unwrap_unchecked(p): T` (explicit-unsafe, asserts non-null). Exact analogs of the
  shipped `nonzero_new` / `nonzero_new_unchecked`. Reject implicit Swift-`T!` laundering. Rationale: refusing the unchecked door
  doesn't add safety — it slows the proven-non-null hot path and pushes experts off the type system into raw `CPtr` ops (strictly
  worse), the `get_unchecked` precedent. Both lower to runtime identity once B.15d lands (§5).
- **Q3 — Strict: `None` only. ✅ RATIFIED.** `nil` is *only* an FFI/`CPtr` literal; typed absence is *always* `None`. The decisive
  argument: `Option<CPtr>` is a meaningful type (no-slot vs. a-pointer-that-is-C-NULL), and lenient `return nil` there is
  irredeemably ambiguous (`None`? or `Some(cptr_null())`?). Strict mode has no such hole. The `std/toml` porting convenience is one
  module, paid once — not worth a permanent second spelling of absence (Rust/Zig precedent).
- **Q4 — Keep the `nil` keyword, scoped to `CPtr` context. ✅ RATIFIED.** `nil`-as-`CPtr`-null is the *correct* FFI primitive (not
  dead code — D7 doesn't bite); `if p.nil?` reads better than `is_null()`/`== cptr_null()`, and the `.nil?`/`is nil`/`??`
  predicate machinery already exists. Precise rule: **`nil` only type-checks against `CPtr`** (Kotlin's platform-type corner —
  the one narrow edge where the compiler defers). Forbidden as a typed-absence value; retiring the keyword would be
  churn-for-purity with negative ROI.
- **Q6 (raised during ratification) — the diagnostic is a bare-`Int` wall, not a `nil`-token check. ✅ FOLDED IN (§7).** Because
  `nil`/`0`/`false` are the same i64, a `nil`-token-only check is evaded by `return 0` and leaves B.15d unsound (`0` still collides
  with the `None==0` niche). The real rule: a boxed-type slot accepts only that boxed type; an `Option<T>` slot only `None`/`Some`;
  neither accepts a bare `Int` (`nil`/`0`/`k`). The NonZero outbound wall, generalized. This is a correctness fix, not a
  preference — it is the premise the §6 soundness proof rests on.

B.15d (co-landing the boxed-pointer niche / N3) is **not** ratified here — it's the separately-gated representation rebase per
§14.6. This ratification blesses the *rule* (B.15a–c) and the *sequencing* (d lands with N3, under its own sign-off).

---

## 10. Effort estimate (quartz-time)

| Sub-step | Traditional | Quartz-time | Risk |
|---|---|---|---|
| B.15a — port `std/toml` to `Option` | 2–3 days | 0.5–1 day | Low (one module, no external consumers) |
| B.15b — FFI bridge | 1 day | ~0.5 day | Low (new fns, additive) |
| B.15c — QZ0213 diagnostic | 2–3 days | 0.5–1 day | Low (rule over existing outbound-wall machinery; compiler has 0 violations) |
| B.15d — co-land boxed-pointer niche (N3) | 1–2 weeks | 3–5 days | **High** (representation rebase, fixpoint-gated, QZ0212-audited — the one-way door) |

a–c ≈ **1.5–2.5 quartz-days**, low-risk, independently shippable. d is the multi-session N3 capstone, separately ratified.

---

## 11. N3 (B.15d) — design/ratification pass (2026-06-09)

The go/no-go for the one-way door. B.15a–c are landed (incl. the full three-position `nil`-literal wall + union-`Nil`
carve-out, `66ae4bc3`). This section decomposes what remains, separates the truly-coupled from the bundled-by-convenience,
quantifies the cost, and states the decisions that need explicit sign-off.

### 11.1 N3 is five components, not one

§14.6 names "N3 = flip the default + B.15" as a single capstone. Pulling it apart, it is actually **five** distinct pieces:

1. **De-existentialization** — boxed values (struct/enum/String/Vec/Map/closure) get real, distinguishable types through
   typecheck/MIR, instead of the uniform `TYPE_INT` they erase to today. *The load-bearing prerequisite for #2 and #4.*
2. **Boxed-pointer niche** — `Option<heap-boxed T>` uses `0 == None` (no tag word, no second box). *The headline memory win:
   "`Option<T>` zero-cost for all heap types," the direct analog of Rust's guaranteed `Option<Box<T>>` NPO.*
3. **Full bare-`Int` wall** — the Q6 rule: `return 0` / `var x: Widget = 0` / `f(0)` into a boxed slot becomes a type error
   (today they compile via existential coercion — **both premises verified 2026-06-09**: `var w: Widget = 0` and `return 0`
   from `def f(): Widget` both compile clean).
4. **Nil default-flip** — the language rule "absence ⇒ `Option`" becomes load-bearing across stdlib + tooling. *This is the
   actual irreversibility* (§1: not the migration — the rule).
5. **Default struct-layout flip** — `struct` defaults to value/inline layout (§6 Phase-4, the B.10 value-types capstone).

### 11.2 The real coupling (and the separability insight)

The genuine hard dependency chain is **#1 → #4 → #3 → #2**:

- The boxed-pointer niche (#2) is sound **only if** `0` in a boxed slot can mean *only* `None` (§6 premise 1). That requires the
  full bare-`Int` wall (#3) — the `nil`-literal wall (shipped) is insufficient because `return 0` evades a token check.
- The full bare-`Int` wall (#3) is **impossible** without de-existentialization (#1): today `tc_expr` returns `TYPE_INT` for a
  `Widget` value (`typecheck_helpers.qz:498` doc; the i64-coercion gate is `tc_types_match` at `typecheck.qz:1979-1983`), so
  "reject `Int` → boxed" cannot tell a real `Widget` from a bare `0` — a false-positive firehose.

**The separability insight (proposed, needs ratification): #5 (default-layout flip) is a DIFFERENT axis and should NOT be
bundled into N3.** A value-layout struct is inline (N words), *not* a heap pointer — so `0` is not its null niche and the
boxed-pointer niche (#2) does not apply to it. The two features are in mild *tension*, not lockstep: #2 benefits exactly the
types that **remain heap-boxed** (String, Vec, Map, Set, closures, enums-with-payload, and any struct not made `@value`). They
share the "give boxed values real types" plumbing (#1) but are independently valuable and independently ratifiable. **Recommend
decoupling: N3 = {#1, #2, #3, #4}; the default-layout flip (#5) stays in the B.10 epic under its own gate.**

### 11.3 The cost driver: migrating the compiler's own `0`-as-boxed-sentinel idiom

De-existentialization's *mechanism* is small and localized (~5–10 core functions: the `tc_is_i64_type` gate, the
`tc_types_match` i64 branch, the arg-loop that skips arg-vs-param checking at `typecheck_expr_handlers.qz:3419`, the uniform
`MIR_TYPE_INT` emission in `mir.qz`, the `codegen_instr` dest-type dispatch). The *consequence* is the cost: turning on the
bare-`Int` wall makes the compiler's **own** null-object-sentinel idiom illegal. Measured 2026-06-09: **758 `return 0` sites in
`self-hosted/`**; the boxed-returning fn surface is in the **high hundreds**. Each `return 0` / `= 0` / `f(0)` that targets a
boxed slot must migrate to either a real value or `Option<T> + None`. **This migration is on the critical path** (the niche's
soundness depends on it) and is the bulk of the 3–5 quartz-day estimate. It is mechanical but must run under the fixpoint-rebase
discipline (§14.4: the bar is "gen1 == gen2 under the new representation," not "byte-identical to the old binary").

### 11.4 What N3 can reuse vs. build new

**Reuse (shipped in N0–N2):** the `type_niche` / `enum_layout` single-source-of-truth query (`backend/niche.qz`); the
range-membership discriminant `mir_get_enum_tag_niche` (already generalized to bottom niches `{0,1}` at 0 by `e0f366a3` — exactly
the boxed-pointer null niche shape); the `MirContext.niche_expected_type` annotation-string carrier; `pending_bind_niche`
identity payload binding; the call-site interception pattern; the QZ0212 erased-boundary diagnostic framework.

**Build new:** extend `type_niche` to return `{0,1}` for heap-boxed types (sound only post-#3); the de-existentialization in
typecheck (#1); QZ0212 extended + a per-construction-site audit that no niche `Option<boxed>` crosses an erased generic boundary
(`f<T>(Option<T>)`, `Vec<Option<T>>`) — the one failure mode that would break self-compile.

### 11.5 Proposed phasing for N3 (it is itself multi-session)

1. **N3.1 — de-existentialize + migrate the compiler off the `0`-sentinel idiom.** Give boxed values real types; flip the
   `Int`→boxed coercion from silent-accept to type-error; migrate all ~hundreds of compiler self-sites to real values / `Option`.
   *No niche yet* — this phase is fixpoint-checkable on its own (output IR unchanged; only the type discipline tightens). The
   bare-`Int` wall (#3) and nil default-flip (#4) land here. Largest phase.
2. **N3.2 — turn on the boxed-pointer niche (#2).** Extend `type_niche`; the representation rebase; QZ0212 audit. The hazardous
   fixpoint event. Headline memory win lands here.
3. **N3.3 — (separate, optional) default struct-layout flip (#5).** Only if ratified to bundle; otherwise stays in B.10.

Each phase is its own golden + guard + Rule-2 smoke + full-suite gate.

### 11.6 Ratified decisions (2026-06-09)

All four signed off by the user 2026-06-09. The one-way door is **open**.

- **D-N3.1 — Decouple #5. ✅ RATIFIED.** N3 = {de-existentialization, boxed-pointer niche, bare-`Int` wall, nil default-flip}. The
  default struct-layout flip (#5) stays in the B.10 value-types epic under its own gate (§12.2).
- **D-N3.2 — Mechanical → `Option`. ✅ RATIFIED.** Sweep every absence-meaning `0`-sentinel to `Option<T>` + `None`; real values
  elsewhere. Most faithful to B.15's intent (accept the larger diff).
- **D-N3.3 — Separate phasing. ✅ RATIFIED.** Land **N3.1** (de-existentialize + migrate; output IR unchanged ⇒ separately
  fixpoint-checkable) as its own ratified commit *before* **N3.2** (the niche rebase). N3.1 de-risks N3.2.
- **D-N3.4 — Go. ✅ RATIFIED — START N3.1 NOW.** Implementation authorized. Multi-session; fix-specific golden
  `quartz-pre-n3-golden` saved; every step golden + guard + Rule-2 smoke + full-suite gated.

### 11.7 N3.1 execution notes (live)

The chicken-and-egg (can't wall a site until boxed values have real types; can't migrate until the wall can flag sites) resolves
by **de-existentializing first, then auditing, then migrating, then flipping the coercion to a hard error** — all inside N3.1, all
with output IR unchanged (runtime representation is untouched; boxed values stay i64 heap pointers — only the typechecker's *view*
sharpens). Order:

1. **De-existentialize the typechecker's view** — make `tc_expr` carry the real boxed type (not `TYPE_INT`) where it currently
   erases. Narrow the `tc_is_i64_type` / `tc_types_match` i64 coercion (`typecheck.qz:1979-1983`, `:2707-2741`) so `Int` no longer
   silently satisfies a boxed slot. *Risk: this is what the current build leans on — expect the compiler's own sites to start
   failing; that failure list IS the audit worklist.*
2. **Audit** — enumerate every compiler/std site relying on `Int`→boxed coercion (the ~hundreds of `0`-sentinels).
3. **Migrate** (mechanical → `Option`) — convert the worklist.
4. **Flip to hard error** — the full bare-`Int` wall (Q6) replaces the shipped `nil`-literal wall's scope.

Each sub-step is its own golden + guard. N3.2 (the niche rebase, the hazardous fixpoint event) is a *separate* later ratified step.

### 11.8 N3.1 audit pass + worklist (2026-06-10)

**Built (step 1):** a default-off, non-failing audit — `QZ0214`, gated on env `QZ_N3_AUDIT` — that warns on a bare int-literal
(`NODE_INT_LIT`) flowing into a boxed slot at all three coercion positions (let / return / arg), reusing the shipped
`tc_nil_forbidden_type` predicate + `tc_union_contains_nil` carve-out. Default-off ⇒ guard fixpoint-trivial (IR unchanged with
the flag unset; warnings never touch codegen). Run with `QZ_N3_AUDIT=1 ./self-hosted/bin/quartz --no-cache -I … quartz.qz`.

**Headline finding:** the int-LITERAL sentinel surface in the whole compiler self-build is **12 sites**, not the hundreds the
§12.3 `758-return-0` figure suggested — because 758 is dominated by *Int*-returning fns (legitimate); the audit filters to
*boxed*-returning slots only. Worklist (step 2):

| # | Site | Kind | Boxed slot | Triage |
|---|------|------|-----------|--------|
| 1 | `std/string_intern.qz:133` | return | `unknown` (InternId) | **real value** (id 0 = ""), NOT absence — likely a scalar-newtype false-positive; keep as a value (do not migrate to Option). |
| 2 | `self-hosted/backend/mir.qz:3720` | return | `Struct` | sentinel (`mir_lookup_function`-family "0 = not found") → `Option` |
| 3 | `self-hosted/backend/mir.qz:3730` | return | `Struct` | sentinel → `Option` |
| 4 | `self-hosted/backend/mir.qz:3781` | return | `Struct` | sentinel → `Option` |
| 5 | `self-hosted/backend/mir.qz:4802` | return | `unknown` | triage |
| 6 | `self-hosted/backend/mir.qz:4821` | return | `unknown` | triage |
| 7 | `self-hosted/backend/mir.qz:4824` | return | `unknown` | triage |
| 8 | `self-hosted/backend/mir_lower_expr_handlers.qz:3355` | let | `ResolverEntry` | sentinel (`suffix_entry: ResolverEntry = 0`) → `Option` |
| 9 | `self-hosted/backend/mir_lower.qz:8099` | arg | `unknown` | triage |
| 10 | `self-hosted/backend/mir_lower.qz:8100` | arg | `unknown` | triage |
| 11 | `self-hosted/middle/typecheck_registry.qz:291` | return | `unknown` | triage |
| 12 | `self-hosted/middle/typecheck_registry.qz:1485` | return | `unknown` | triage |

**Two known audit limitations (by design, for the human-triaged worklist):**
1. **Over-approximates scalar newtypes** — `tc_nil_forbidden_type` forbids the whole newtype range (1000–4999), so a real `return 0`
   of a *scalar*-newtype value (e.g. `InternId` id 0) is flagged though it is a legitimate value, not absence (#1 above). Triage
   separates "absence → `Option`" from "real 0 → keep".
2. **Literal-only** — catches `NODE_INT_LIT` (`return 0`, `x: Widget = 0`, `f(0)`); it does **not** catch the `Int`-*variable*
   case (`k: Int; return k` into boxed). That subset is invisible until de-existentialization gives values real types — it is the
   N3.1-step-1 core, and its size is the remaining unknown. The literal worklist (12) is the *floor*, not the ceiling.

**Implication for the plan:** the literal-level migration (step 3) is small and can land quickly. The genuinely large/risky work
is narrowing the `tc_is_i64_type` coercion (step 4) — which both *enables* enumerating the `Int`-variable subset and *triggers*
migrating it. Step 4 remains the multi-session core; the audit just proved the literal floor is tiny.

### 11.9 N3.1 step-3 migration progress (2026-06-10)

Each migration = its own commit, guard fixpoint + Rule-2 smokes + targeted-spec + full-qspec verified. Golden
`quartz-pre-n3.1-migrate-golden` (pre-all-migrations) saved.

**DONE — genuine absence sentinels migrated to `Option`:**

| Site(s) | Function | Callers | Commit | Verification |
|---------|----------|---------|--------|--------------|
| #12 | `tc_function_ast_info` (typecheck_registry) | 1 | `e83c9dae` | guard 2809 · `named_args_spec` (default-fill branch) |
| #6,#7 | `mir_ctx_get_struct_defaults` (mir) | 1 | `ab4bb0ba` | guard 2809 · `default_fields_spec` 9/9 |
| #5 | `mir_ctx_get_struct_fields` (mir) | 5 | `facaa89a` | guard 2810 · full qspec 836/837 |
| #11 | `tc_lookup_function_params` (typecheck_registry) | 3 | `54b3a4d6` | guard 2810 · `named_args`+`nil_literal_wall` |

Pattern: return type `Vec<Int>` → `Option<Vec<Int>>`; `return X` → `Option::Some(X)`, `return 0` → `Option::None`;
callers `== 0` → `.is_none()`, `!= 0` → `.is_some()`, indexed use via `.unwrap()` (hoisted to one local where the
result is used more than once). Pre-niche `Option` adds a box on these paths; N3.2's boxed-pointer niche removes it —
self-build perf is not a gate (D8 cares about fixpoint, not speed).

**KEPT — scalar-newtype false-positives (audit over-approximation, limitation #1; NOT absence — real values):**

| Site(s) | Expr | Type | Why kept |
|---------|------|------|----------|
| #1 | `return 0` in `intern` (string_intern) | `InternId = Int` newtype | id 0 = `""` is a real interned value |
| #9,#10 | `set_break_target(0)` / `set_continue_target(0)` (mir_lower) | `MirLabel = Int` newtype | label 0 = "no target" is a real scalar sentinel, not a heap absence |

These are bare scalars (`newtype X = Int`), not boxed/heap types; `Option` is the wrong tool. They become visible to
the *full* bare-`Int` wall only in step 4, where the typechecker can distinguish "real 0 of a scalar newtype" from
"absence". Left as-is by design.

**✅ DONE — #2,#3,#4,#8 = the `ResolverEntry` sentinel cluster (commit `cd165fe1`, one coupled commit). N3.1 STEP 3 COMPLETE.**

`mir_lookup_function` (~25 sites/4 files) + `mir_find_arity_match` (4 sites) + the `suffix_entry` local now traffic in
`Option<ResolverEntry>`. guard fixpoint PASSED 2812 fns · style_demo+brainfuck smokes · `arity_overload_spec` +
`named_args_spec` + `ufcs_untyped_global_recv_spec` standalone green · **full qspec 837/837 ALL GREEN**.

🔑 **Typechecker workaround discovered:** inline `opt.unwrap().<field>` chains FAIL on a struct payload
(`QZ0301: Unknown struct 'Struct'` — the concrete type is lost through generic `unwrap`'s return). Fix: bind first —
`var x = opt.unwrap(); x.field`. Compound conditions (`is_some() and unwrap().tag == N`) hoist the tag check into a
guarded bool local. **Step 4 (narrow `tc_is_i64_type` / de-existentialize) removes this need** — it gives `unwrap()`'s
result a concrete type, so these can revert to direct chains. The latent unguarded `orig_entry.ast_store`
(`mir_lower.qz`) is now an explicit `.unwrap()`.

⚠️ **Session footgun (do NOT repeat): `quake format` is DESTRUCTIVE.** It invokes `quartz --format` (an unknown CLI
option — the binary uses the `fmt` subcommand) and overwrites every `.qz` in the repo with CLI help text (1417 files
corrupted in one run). Recovered via `git checkout -- .` (all uncommitted) and replayed the cluster edits. Guard does
NOT require formatting and Quartz is `end`-delimited (not indentation-sensitive), so skip formatting entirely; if ever
needed, use `quartz fmt` (subcommand), never `quake format`.

The original deferral scoping is preserved below for the record. Full scope enumerated 2026-06-10:

- **Coupling (why it is ONE commit, not split):** `mir_lookup_function` (returns `ResolverEntry`, sentinel 0, ~25
  real call sites across `mir_lower.qz`, `mir_lower_stmt_handlers.qz`, `mir_lower_expr_handlers.qz`, `mir.qz`) and
  `mir_find_arity_match` (`ResolverEntry`, 3 sites) **share the `func_entry` variable**: at
  `mir_lower_expr_handlers.qz:2596` and `:3371`, `func_entry = arity_matched`. Site #8 is the
  `suffix_entry: ResolverEntry = 0` local (`mir_lower_expr_handlers.qz:3355`), also assigned into `func_entry`
  (`:3367`). So all three (`mir_lookup_function`, `mir_find_arity_match`, `suffix_entry`) must become
  `Option<ResolverEntry>` together, wrapping at each assignment.
- **Site classification:** ~7 existence-check-only sites (`if lookup(x) != 0`) → `.is_some()`/`.is_none()`
  (stmt_handlers:1511,1515; expr_handlers:850,854,1754; mir_lower:2984/found). ~12 check-then-field-access sites
  (`.ast_store`/`.node_id`/`.tag`/`.name` after the guard) → unwrap after `is_some` (mir_lower:1363,1491,1847,2629;
  stmt_handlers:182,297; expr_handlers:1493,1678,2207,2406; mir.qz:2620,4077,4253).
- **The crux:** `mir_lower_expr_handlers.qz:2465` `func_entry` threads through a ~900-line function (2465→3400) with
  the suffix-search local and the two arity reassignments — migrate this function last and most carefully.
- **Latent issue to fix in passing:** `mir_lower.qz:2196-2197` accesses `orig_entry.ast_store` with NO null guard —
  post-`Option` it must `.unwrap()`, and the migration should confirm/justify the always-`Some` assumption (or add a
  guard).
- **Verification:** the hot path means any behavioral break shows up loudly in full qspec (dispatch/overload/method
  specs). `arity_overload_spec`, `named_args_spec`, method-dispatch specs are good targeted oracles.

**All 12 audit literal sites are now resolved** (9 migrated to `Option` across 7 functions + 1 local; 3 scalar-newtype
FPs kept as values) — **N3.1 step 3 is CLOSED.** Step 4 (narrow `tc_is_i64_type` / de-existentialize → full bare-`Int`
wall + the invisible `Int`-variable subset) is the next, multi-session core; it also removes the inline-`unwrap()`
typechecker workaround above. Then N3.2 (boxed-pointer niche rebase) makes all this pre-niche `Option` boxing free.

### 11.10 N3.1 step-4 blast-radius measurement (2026-06-10) — `QZ0215`

**Built:** `QZ0215`, the *type-based* sibling of the literal `QZ0214` audit — a default-off (`QZ_N3_AUDIT`) WARNING
that fires when an expression whose **resolved type is bare `TYPE_INT`** flows into a boxed/forbidden slot but is
**not** a `NODE_INT_LIT` (that is `QZ0214`) and not `nil` (`QZ0213`). Wired at all three coercion positions
(let / return / arg; the return + arg branches re-walk the value via `tc_expr`, env-gated so the extra walk never runs
in production). Reuses the `tc_nil_forbidden_type` predicate + `tc_union_contains_nil` carve-out. Guard fixpoint-trivial
(flag-off ⇒ IR byte-identical; **2812 fns, gen1==gen2**); Rule-2 smokes (`style_demo`, `brainfuck`) green. Golden
`quartz-pre-n3.1-step4-golden`. This is the analog of step 1's literal audit, extended to size the *invisible*
`Int`-variable subset §11.8-limitation-2 flagged as "the remaining unknown."

**Headline finding (the number that reframes step 4):** running `QZ_N3_AUDIT=1` over the compiler self-build
(`--no-cache`, full `-I` set, `self-hosted/quartz.qz`) emits **9,635 QZ0215 fires across 8,326 distinct source
locations** — versus **13** for `QZ0214` (literals). The Int-variable / erased-value surface is **not** a worklist of a
dozen sites; it is pervasive.

| Position / slot | Fires | Reading |
|---|---|---|
| arg → `param unknown` | 5,449 | struct/handle value into a param the TC can't even *name* (TYPE_UNKNOWN / unnamed struct) |
| arg → `param Struct` | 3,639 | struct value into a generic-`Struct` param |
| arg → `param Enum` | 488 | enum value into a generic-`Enum` param |
| let / return slots | ~60 | the small remainder |

Top files (distinct-location density): `mir_lower.qz` 1,615 · `mir_lower_expr_handlers.qz` 1,428 · `resolver.qz` 878 ·
`macro_expand.qz` 723 · `mir_lower_stmt_handlers.qz` 675 · `typecheck_walk.qz` 580 · `typecheck_expr_handlers.qz` 544 ·
`mir.qz` 498 — i.e. the backend/MIR-lowering + resolver core that traffics in struct values.

**What the fires actually are (sampled, decisive):** overwhelmingly **legitimate struct/enum values that `tc_expr`
erases to `TYPE_INT`**, *not* `0`-sentinels. Concrete examples:
- `quartz.qz:303:49` — `ps_error_count(ps)`: `ps` is a `ParserState` *struct variable*, typed `TYPE_INT` by the
  existential model, passed into a `Struct` param.
- `resolver.qz:111:32` — `ast_get_kind(ast_store, stmt)`: `ast_store` is an `AstStorage` struct erased to `TYPE_INT`.

`ps` and `ast_store` are not absence and not sentinels — they are real boxed values the typechecker has flattened to
`Int`. **Every by-value pass of a struct/enum fires**, which is why the count is ~10k.

**Strategic implication (this is the point of the measurement):** step 4 **cannot** be a mechanical per-site
`→ Option` migration — there is nothing to migrate; the values are already correct, the *types* are wrong. Step 4 is a
**source-level de-existentialization of `tc_expr`** (and of param/return typing): make struct/enum/container expressions
carry their real type instead of `TYPE_INT`, and make `Struct`/`unknown` param slots carry concrete struct ids. Only
*after* values and slots carry real types does the residual set of **true** `0`-sentinels become isolable — and *that*
small residue is what the narrowed `tc_is_i64_type` coercion (the hard bare-`Int` wall) then rejects. The §11.7 order
holds, but §11.8's hope that the variable subset might also be "small" is now refuted: **the de-existentialization is the
large, diffuse, multi-session body of work; the wall flip is the small finish.**

`QZ0215` stays in-tree (default-off, like `QZ0214`) as the **progress meter**: as `tc_expr` handlers are de-existentialized,
the 9,635 count drops monotonically toward the true-sentinel floor. Re-run the audit command above between de-ex commits
to track convergence. The genuine-vs-noise split *within* the 9,635 is itself only cleanly resolvable by de-existentializing
(you cannot distinguish "erased struct" from "real Int sentinel" until values carry real types) — so the count is the
right single North-Star metric, not a hand-triaged table.

**Next-session entry point for step 4** *(superseded by §11.11 — kept for the record; the "fix tc_expr producers" framing
turned out to be wrong, see below)*: start at the *producers* of erased `TYPE_INT`, not the consumers… De-existentialize
those handlers one class at a time.

### 11.11 N3.1 step-4 root-cause + execution design (2026-06-10)

A deeper read (one level past §11.10) corrects the §11.10 framing. The `tc_expr` producers are **not** buggy — they
faithfully report the declared types. The erasure lives in **two coupled places, both more fundamental than "a handler
returns `TYPE_INT`":**

**(1) The source annotates struct-handle returns `: Int`.** `parse_with_target(...): Int` (`parser.qz:9037`) *returns a
`ParserState`* but is **declared** `: Int`. This is pervasive: struct-handle-returning functions across the compiler are
annotated `: Int` because, at runtime, a struct is an i64 heap handle and the type system has never distinguished it from
a real integer. So `var ps = parse_with_target(...)` binds `ps : Int`; passing it to `ps_error_count(ps: ParserState)`
is the QZ0215 fire. The 9,635 fires are **the size of the `:Int`-for-struct-handle idiom across the source**, not a set
of fixable handlers.

**(2) The type system has zero nominal struct/enum identity.** `tc_parse_type` maps *every* struct name to the single
bare constant `TYPE_STRUCT` (=7) (`typecheck.qz:1348`) and every enum to `TYPE_ENUM` (`:1351`). `ParserState`,
`AstStorage`, `Point` are all type id 7. There is no `StructId`-per-struct. (Contrast `NonZero` at `:1345`, which *does*
get its own nominal i64 id **specifically so bare ints/nil cannot be assigned to it** — that is exactly the wall
mechanism, already in-tree, waiting to be generalized to all boxed types.)

**Why the wall is unavoidably coupled to this.** The bare-`Int` wall must reject "Int → boxed slot." But **today struct
handles *are* `Int`-typed** (idiom 1). You cannot wall Int-into-boxed while structs *are* Ints — turning the wall on now
rejects all 9,635 legitimate struct flows. Therefore the wall flip (step-4 finish) is gated on first eliminating the
`:Int`-for-struct idiom — which requires structs to *have a non-Int type to be annotated with* (idiom 2). The §11.7
order ("de-existentialize → … → flip") is right; "de-existentialize" concretely means **give structs/enums real type
identity, then re-annotate the source idiom against it.**

**Two levels (the design fork):**

- **Level 1 — nominal collapse (minimum for soundness).** Keep `TYPE_STRUCT`=7 as the single struct type; just
  re-annotate `: Int` → `: <StructName>` on struct-handle functions (still resolves to 7). Struct→struct flows then match
  `7 == 7` *without* the i64 coercion, so narrowing `tc_is_i64_type` rejects only true bare-`Int` sentinels. **Sound for
  the wall.** But: "any struct matches any struct" (no real safety), and the §11.9 `QZ0301` generic-`unwrap` problem
  (concrete type lost) persists — `unwrap()` still yields bare `Struct`.

- **Level 2 — per-struct/enum nominal identity (the real design).** Introduce a `STRUCT_TYPE_BASE` id range
  (`BASE + struct_idx`), exactly as newtypes/`NonZero` already do. `tc_parse_type` returns the precise id; `tc_type_name`
  decodes it; `tc_types_match` does nominal equality; generic `unwrap`/field access carry the concrete struct type
  (**subsumes the step-3 `QZ0301` workaround** — inline `opt.unwrap().field` works again). This is what every comparison
  language (Rust/Go/Swift/OCaml…) has as table stakes. Larger blast radius: `tc_parse_type`, `tc_type_name`,
  `tc_types_match`, the `TYPE_STRUCT`-base **ptype** encoding for generic structs (`Vec<T>`, `Stream<T>` use
  `TYPE_STRUCT` as their base — `typecheck.qz:1697,4095`), field-access typing, and any codegen that assumes
  `TYPE_STRUCT==7`.

**Recommended sequence (pending ratification of the Level-2 fork):**
1. **4a — representation:** add per-struct/enum nominal TypeIds (Level 2). Pure typechecker-view change, runtime rep
   untouched (still i64 handle), so guard-fixpoint-checkable on its own. *This is the de-existentialization proper.*
2. **4b — re-annotate the idiom** module-by-module: `: Int` → real struct/enum type on struct-handle functions, driven by
   the `QZ0215` meter (watch the count fall toward the true-sentinel floor), guard-fixpoint each module. Doing 4a first
   means re-annotating **once** against real ids rather than twice.
3. **4c — flip the coercion:** narrow `tc_is_i64_type` (`typecheck.qz:1979-1983, 2674-2683`) so bare `Int` no longer
   satisfies a boxed slot. With the idiom gone, the residual fires are true sentinels — convert `QZ0215`/`QZ0214` from
   warn to the hard bare-`Int` wall (`error`). The §11.9 inline-`unwrap` workarounds revert here (Level 2).

**Open decision for the user (a one-way-door-adjacent representation choice):** Level 1 only (minimal, leaves nominal
collapse + keeps the `QZ0301` wart) vs. Level 2 (per-struct identity, the real fix, larger). **Recommendation: Level 2**
— it is the NonZero pattern generalized, it is table stakes in every comparison language, it kills the `QZ0301`
workaround, and doing Level 1 first would re-touch every annotation twice. Estimate (quartz-time): 4a ≈ 1–2 days
(representation + fixpoint), 4b ≈ 3–5 days (re-annotation sweep, module-gated), 4c ≈ 0.5–1 day (the wall flip). Total
≈ 1 week of the multi-session core, then N3.2 (the niche rebase) is unblocked.

### 11.12 N3.1 step-4a — per-struct identity: blast radius + encoding (2026-06-10, Level 2 ratified)

User ratified **Level 2** (per-struct nominal ids). Blast-radius map (`grep TYPE_STRUCT`, 90 refs):

- **82 of 90 are in the typecheck layer** (`typecheck*.qz`); backend has **0 real consumers** (`mir.qz`'s
  `MIR_TYPE_STRUCT=4` is an unrelated MIR-level constant; the rest are doc comments). ⇒ **per-struct ids are
  codegen-invisible** — the change lives entirely in the typechecker's view. Fixpoint-favorable.
- Split: **53 equality tests** (`== TYPE_STRUCT`), **64 producers** (`return/= TYPE_STRUCT`).
- **6 of the 53 are the generic-struct hazard**: `tc_ptype_base(...) == TYPE_STRUCT`
  (`typecheck_walk.qz:904,1010,2332,3134`; `typecheck.qz:1498,2865`) — these test a *ptype's base*, which for a generic
  struct (`Stream<T>`, user `Foo<T>`) is `TYPE_STRUCT`.

**Id-space:** free gap **7000–99999** between `PROTOCOL_BASE=6000` and `PTYPE_BASE=100000`. Take
`STRUCT_TYPE_BASE = 7000`. Note `tc_is_i64_type`'s existing catch-all `t >= NEWTYPE_BASE(1000) and t < PTYPE_BASE` *already*
classifies 7000+ as an i64 handle — so per-struct ids are coercion-consistent for free.

**Encoding decision (minimizes churn):**
- **Bare** struct name → `STRUCT_TYPE_BASE + struct_idx` (the nominal id). Only `tc_parse_type:1348` flips.
- **Generic** struct ptype (`Stream<T>`, `Foo<Int>`) → **keep `TYPE_STRUCT` as the ptype base** (status quo). The 6 hazard
  sites need **no change**. Generic-struct nominal identity is a later refinement, not needed for the wall.

**Why 4a is fixpoint-safe (the key argument):** the **i64 coercion stays active through 4a** (it is only narrowed in 4c).
So `BASE+i` and `BASE+j` still match each other (both i64), and bare `TYPE_STRUCT` still matches any `BASE+idx`. Nominal
ids therefore become *available* (carried through `unwrap`, `tc_type_name`, field access — fixes the §11.9 `QZ0301`
wart) **without rejecting any program that compiles today** ⇒ accepted-set unchanged ⇒ output IR byte-identical ⇒ guard
fixpoint holds. Nominal distinctness only starts *rejecting* in 4c, after the safety net is removed and the source idiom
is gone (4b).

**4a sub-steps:**
- **4a-1 (scaffolding, provably IR-identical):** add `STRUCT_TYPE_BASE` + helpers (`tc_is_struct_type`,
  `tc_struct_type_id`, `tc_struct_idx_from_type`); add the `BASE+idx` arms to `tc_type_name` (decode → `struct_names[idx]`)
  and `tc_types_match`/`…_with_annotations` (nominal eq + bare-`TYPE_STRUCT` wildcard + i64 net); route the **47**
  non-hazard `== TYPE_STRUCT` tests through `tc_is_struct_type`. New arms are unreachable until 4a-2 (nothing produces
  `BASE+idx` yet) ⇒ guard fixpoint-trivial. Leave the 6 ptype-base hazards and the 64 producers as bare `TYPE_STRUCT`.
- **4a-2 (the one live line):** flip `tc_parse_type:1348` → `tc_struct_type_id(idx)`. Now bare struct annotations carry
  real ids; the safety-net argument above makes this guard-fixpoint-clean. *This is the real test of the encoding.*
- Then **4b** (re-annotate `: Int` → struct types, `QZ0215` meter) and **4c** (narrow `tc_is_i64_type`, warn→error).

Golden for 4a: `quartz-pre-n3.1-step4a-golden`.

### 11.13 N3.1 step-4a-2 — the qzmod cross-module hazard (2026-06-10)

Flipping `tc_parse_type` to return `BASE+idx` surfaces a cross-module serialization hazard that bare `TYPE_STRUCT=7`
(module-invariant) did not have: `BASE+idx` encodes a **per-module registration index**, non-portable across the qzmod
module cache.

- **Fixpoint is unaffected.** The guard fixpoint build compiles `quartz.qz` in **one process** (the "Gen0→Gen1" single
  invocation), so all modules share one struct registry — `BASE+idx` is internally consistent. The qzmod cache is only
  used for *separate* compilation (`build:separate`, importing pre-built `.qzmod`).
- **The two remap functions gap exactly on the struct range.** `_qzmod_remap_arg` (ptype args) and
  `_qzmod_inject_remap_blob_id` (func sigs / struct fields / enum payloads) both map `1000..PTYPE_BASE` (which now
  includes `7000+`) to **`-1` (advisory miss)** → graceful source-fallback (correct, but loses caching).
- **Fix (transitional, 1 line each):** map the struct range `[STRUCT_TYPE_BASE, PTYPE_BASE) → TYPE_STRUCT` in both remap
  functions. Cross-module, a struct then ships as the **portable generic-struct wildcard** (`7`) exactly as before the
  flip — the i64 net still matches it, `tc_is_struct_type(7)` is true, and the wall still forbids bare `Int` into a `7`
  slot. Nominal identity is **within-process only** for now; **4a-3** ships struct *names* in sig/arg blobs +
  name-resolves on inject for full cross-module nominal identity. This keeps the flip transparent to qzmod (no emit
  change, no advisory-miss regression).

**Routing insight (de-risks the sweep):** misrouting a ptype-base hazard site through `tc_is_struct_type` is **harmless**
— ptype-base values are always type *constants* (`< 7000`), never `BASE+idx`, so `tc_is_struct_type(base)` ≡
`base == TYPE_STRUCT` there. The real failure mode is the opposite: *under*-routing (leaving a genuine "is this value a
struct" test as `== TYPE_STRUCT`) makes it take the wrong branch for a `BASE+idx` struct → IR diverges → **guard
fixpoint fails = the completeness oracle.** So bias toward routing; the 6 known ptype-base sites are left literal only
for clarity. Sites in `tc_is_i64_type` (`:2716`) need no routing — the `NEWTYPE_BASE..PTYPE_BASE` catch-all already
covers `7000+`.

Golden for 4a-2: `quartz-pre-n3.1-step4a2-golden`.

### 11.14 N3.1 step-4a-2 — LANDED (2026-06-10) + the latent capture-walk bug it exposed

**4a-2 done.** `tc_parse_type` now returns `tc_struct_type_id(idx)` for bare struct names; ~30 `== TYPE_STRUCT` value-type
tests routed through `tc_is_struct_type`; both qzmod remap functions normalize the struct range → `TYPE_STRUCT`;
`tc_nil_forbidden_type` and the `Channel` Send check extended for the 7000+ range. **guard fixpoint PASSED (2815 fns) +
qzmod cache smokes (incl. vec-of-struct dep-invalidation) green.** Per-struct nominal identity is now live.

**A latent pre-existing bug the flip surfaced (the predicted "fixpoint-passes-but-a-spec-breaks" case).** Full qspec was
**832/837**; two specs (`unicode_grapheme_spec`, `iterator_protocol_spec`) crashed with `index out of bounds: index 7028,
size 460` in `tc_collect_captures_walk → ast_get_kind`. Root cause: the closure capture walkers
(`tc_collect_captures_walk` in `typecheck_capture.qz`, and the MIR worklist `mir_collect_captures_walk` in `mir.qz`)
**follow a for-node's `int_val` "step" slot as if it were an `AstNodeId`** — but for `for x in <iterator>` that slot
holds a non-node integer (a *type id*). Pre-flip that was the bare `TYPE_STRUCT(=7)` — a coincidentally in-bounds node
index, so the stray walk was silently harmless. A per-struct nominal id (≥7000) overflows the node array → SIGABRT.
**Fix:** bounds-guard both walkers — skip any `node` not in `[1, ast_node_count)`. Correct (real AstNodeIds are always
`< node_count`; a non-node carries no captures) and fixpoint-neutral (the compiler's own source never hits an
out-of-bounds walk, which is why guard fixpoint passed clean while two specs still crashed). After the guard:
`unicode_grapheme_spec` 13/13, `iterator_protocol_spec` 52/52. **Lesson: guard fixpoint is necessary but not sufficient
for a type-representation change — the full qspec suite is the catch-net for latent "small constant used as index"
assumptions that only break once the constant grows.** This generalizes: any remaining `TYPE_STRUCT==7`-as-small-index
assumption elsewhere would surface the same way; the qspec suite is the oracle for them.

Goldens: `quartz-pre-n3.1-step4a2-golden` (pre-flip). **Next: 4b** — re-annotate the `:Int`-for-struct-handle idiom
module-by-module (the `QZ0215` meter falls as struct values gain real types), then **4c** (narrow `tc_is_i64_type`,
warn→error).

### 11.15 N3.1 step-4b — kickoff analysis (2026-06-10): the meter is noisier than it looks, and the sweep has layering teeth

Baseline `QZ0215` post-4a = **9,678** (≈ the pre-4a 9,635 — 4a re-annotated nothing, as expected). **But the meter must be
read by `param` category, not the total:**

| `param <T>` | fires | meaning |
|---|---|---|
| `unknown` | 5,492 | **scalar-newtype FPs** — `AstNodeId`/`InternId`/`MirLabel` etc. are Int-backed newtypes (1000–1999). `tc_nil_forbidden_type` over-forbids the *whole* newtype range and `tc_type_name` renders a newtype as `"unknown"`, so a legit `root: AstNodeId = <Int>` fires. **NOT a 4b target.** |
| `Struct` | 3,640 | **the real 4b idiom** — an Int value into a genuine struct param (`:Int`-for-struct-handle). |
| `Enum` | 488 | the real idiom, enum flavor. |

**⇒ the 4b progress meter is the `param Struct`+`param Enum` count (≈4,128), not the 9,678 total.** The 5,492
newtype FPs only resolve in **4c**, where `tc_nil_forbidden_type`/the wall must learn to distinguish a *scalar* newtype
(Int-backed, accepts Int — `AstNodeId`) from a *heap* type (audit limitation #1). Re-annotation cannot move them.

**4b is a per-type sweep, and each type has a cascade + layering subtleties — not a bulk rename.** Worked example,
`AstStorage` (the most-threaded handle):
- **Creation already correct:** `ps_get_ast_storage(ps): ast::AstStorage` ✓ and `ast_new_storage(): AstStorage` ✓. So the
  main path (`var ast_storage = ps_get_ast_storage(ps)` in `quartz.qz`) is *already* `AstStorage`-typed — the
  `expand_macros(ast_storage, root)` fires there are the **`root: AstNodeId` newtype FP**, not the struct.
- **51 param sites** annotated `ast_store: Int` / `ast_storage: Int` (resolver, mir_lower, mir, mir_const,
  typecheck_match, typecheck_registry, dep_graph, compiler_types) — flippable to `: ast::AstStorage`; the i64 net keeps it
  fixpoint-clean (annotation-only, runtime rep identical).
- **🔑 One source is BLOCKED by module layering:** `ResolverEntry.ast_store: Int` lives in `compiler_types.qz`, which has
  **no imports**, and `ast.qz` *imports* `compiler_types` — so `compiler_types.qz` cannot name `ast::AstStorage` (cycle).
  Until `ResolverEntry` moves out of `compiler_types` (or `AstStorage` moves in, or a forward-decl mechanism exists), that
  field stays `Int`, and every `f(entry.ast_store)` into an `AstStorage` param keeps firing. **This is a real
  "forced-`Int`-handle" corner** (the same shape as the FFI/`CPtr` boundary) — some `:Int` annotations are load-bearing
  for the module DAG and won't re-annotate without a restructure.

**4b execution recipe (per struct/enum type):** (1) confirm the creation/return sites are already typed (or flip them);
(2) flip the param + field sites `: Int → : <Type>`; (3) note any layering-blocked sources as forced-`Int` corners;
(4) guard-fixpoint (annotation-only ⇒ IR-identical via the i64 net); (5) re-run the audit, watch the
`param Struct`+`param Enum` count fall. Golden `quartz-pre-n3.1-4b-golden` saved. Start with the highest-fire types
(AstStorage, then the MIR context + typecheck-state handles in `mir_lower*`/`resolver`/`macro_expand`). The
layering-blocked corners are the residue 4c's wall must treat as sanctioned Int handles (like `CPtr`), not sentinels.

### 11.16 N3.1 step-4b — increments #5–#7 (2026-06-10): the mir_lower `s`-handle and the codegen `prog`-handle

Three more increments, same recipe, moving from the frontend/macro surface into the backend. The meter is
`param Struct`+`param Enum` (the `param unknown` newtype FPs are 4c's problem).

| # | commit | producer flipped | files | param Struct | net |
|---|---|---|---|---|---|
| #5 | `de1433a1` | `s: Int → s: ast::AstStorage` in `mir_lower.qz` | 1 | 2424 → 2255 | −169 |
| #6 | `ea4a71e4` | `s` across the rest of the mir-lowering cluster | 6 | 2255 → 1428 | −827 |
| #7 | `55b49f14` | `prog: Int → prog: MirProgram` across codegen+intrinsics+opt | 32 | 1428 → 1286 | −142 |
| #8 | `d55606a4` | `instr/func/block: Int → MirInstr/MirFunc/MirBlock` in codegen | 30 | 1286 → 1013 | −273 |
| #9 | `2edc7626` | MirBlock current-block chain (field+getter+create+set, RETURN-type de-ex) | 2 | 1013 → 685 | −328 |
| #10 | `e5ddb609` | `instr/func/block/mir_prog: Int → Mir*` in optimization cluster | 7 | 685 → 629 | −56 |

**#5 + #6 — the `s` AstStorage handle (the mir-lowering twin of #4's `macro_expand` `s`).** `mir_lower*` threads an
`AstStorage` through every lowering fn as a bare `s: Int`, passed into the hundreds of `ast::ast_get_*(s, …)` accessors
(typed `: AstStorage` since #2) — so each fired `QZ0215`. #5 flipped `mir_lower.qz` alone (22 params, `s: Int,` →
`s: ast::AstStorage,`); #6 finished the connected component — `mir_lower_expr_handlers` (17), `mir.qz` (14),
`mir_lower_stmt_handlers` (11), `mir_lower_iter` (9), `mir_lower_gen` (8), `mir_lower_async_registry` (3) = 62 params.
🔑 **The component is why #5 alone only netted −169 of its ~531 in-file fires: flipping one file *relocates* the rest to
its callers (caller passes a still-`Int` `s` into the now-`AstStorage` param). #6 then cleared both its own internal
fires AND the fires #5 relocated to it — hence the −827.** Lesson for connected-handle sweeps: the per-file net
understates the producer's true value; the cluster total is what matters. `mir.qz` needed the `, s: Int,` pattern (not
bare `s: Int,`) to skip the genuinely-Int `args`/`params`/`words` params that merely end in `s`.

**#7 — the `prog` MirProgram handle (first backend-struct producer).** Codegen passes the `MirProgram` as `prog: Int`,
firing on every `prog.mir_get_*()` / `prog.mir_prog_*()` receiver. Flipped **88 params across 32 files** — the whole
codegen + `cg_intrinsic_*` + `mir_opt`/`egraph_opt` surface. 🔑 **Two import conventions, matched per file:**
wildcard-import files (`codegen`, `codegen_instr`, `codegen_separate` — `import * from mir`) use bare `MirProgram`; the
~29 qualified-only files (`import mir`) use `mir::MirProgram` (already valid syntax, e.g. pre-existing in `codegen.qz`).
🔑 **Skipped `codegen_util.qz`:** its only `prog: Int` match is the `current_prog` STRUCT FIELD (a real MirProgram, but
field-category not param — a future "field Struct" pass; field flips change struct-layout annotations, slightly
different risk). The driver `quartz.qz` *rose* 74 → 96 because it still passes an `Int` `prog` local into the now-
`MirProgram` codegen entry points — the next tail (a `quartz.qz` driver increment clears it, same relocate-then-clear
dynamic as #5→#6).

**Mechanics confirmed across all three:** every flip is annotation-only, behavior-neutral via the i64 net (AstStorage /
MirProgram are i64 handles, same rep as Int) — guard fixpoint `gen1==gen2` 2813 fns each, Rule-2 smokes
(style_demo + brainfuck) + targeted qspecs (control_flow, generators, actor, spawn, defer, closures_structs, async_mutex,
map_generic, extern_def) all green. For #6/#7 (multi-file) a plain `quake build` gated the source before the expensive
guard. `sed -i ''` used for #7's 23-file bulk substitution after verifying zero substring false matches (no identifier
ends in `prog` except the excluded `current_prog`). Goldens `quartz-pre-n3.1-4b-incr{5,6,7}-golden` saved before each.

**4b running total: `param Struct` 2936 (incr #4 base) → 629 over increments #4–#10; combined Struct+Enum 2912 → 1117 (−1795 across incr #5–#10 this session).**

🔑 **The param-flip vein is mostly mined — the high-leverage threaded handles (`s`/AstStorage, `prog`/MirProgram,
`instr`/`func`/`block`/Mir*) are done. The remaining ~1013 `param Struct` fires are a DIFFERENT sub-pattern:
return-type + local-variable de-existentialization, not param re-annotation.** Precise sample of `mir_lower.qz`'s
remaining 176 (strip ANSI, then `awk` the source line under each `param Struct` block): the top firing calls are
`mir_block_set_terminator` (37) / `mir_block_get_term_kind` (18) / `mir_block_set_branch` (11) / `mir_ctx_get_block`
(13) — all receiving a **MirBlock handle that is an `Int` LOCAL** (`var b = mir_ctx_get_block(...)` / `mir_new_block(...)`),
because the block-producing functions are annotated `: Int` returns. The fix is to flip those **return annotations**
(`mir_new_block`, `mir_ctx_get_block`, `mir_ctx_current_block`, etc. → `: MirBlock`) so the locals infer the real type
and the hundreds of `mir_block_*(b, …)` consumers stop firing — the same relocate-then-clear cascade as the param
sweeps, but seeded at the producer's *return* instead of its params. Likewise `quartz.qz` 96 (the driver's `prog`/`s`
LOCALS — flip the MIR-program/AST-storage producers it calls, or annotate the locals), `mir_opt.qz` 84,
`mir_lower_expr_handlers.qz` 151 (same MirBlock-local story). **Next session: pick a struct type (start with MirBlock —
highest residue), flip its RETURN-annotation producers + any remaining param sites together, guard, re-measure.** The
~5492 `param unknown` newtype FPs (AstNodeId/InternId/MirReg/MirLabel) remain 4c's job. Re-measure from a fresh audit
(`/tmp/4b_incr8_clean.txt` is the last snapshot).

**Update — incr #9 done (the MirBlock current-block chain).** `MirContext.block` field + `mir_ctx_get_block`/`mir_create_block`
returns + `mir_ctx_set_block`/`mir_switch_to_block` params (the last two were *mislabeled* `MirLabel` — proven `MirBlock`
because consumers do `block.term_kind`/`.mir_block_get_label()`). param Struct 1013 → 685 (−328); as a bonus `param unknown`
fell 5494 → 4838 (the block locals had also been firing into `MirLabel`/`MirReg` newtype params). First **return-type +
struct-field** de-ex (vs the param sweeps #5–#8). Surfaced one HARD `QZ0203`: `_gen_resume_blocks: Vec<Int>` now received
`MirBlock` at 4 push sites → cast via `as_int_generic()` at the `Vec<Int>` boundary (the existing idiom — `mir_create_block`
itself does `blocks.push(as_int_generic(block))`).

**Update — incr #10 done (the opt-pass MIR-handle flip).** Flipped `instr`/`func`/`block`/`caller`/`callee`/`mir_prog` to their nominal types (`mir::MirInstr`, `mir::MirFunc`, `mir::MirBlock`, `mir::MirProgram`) in `egraph_opt.qz`, `mir_opt.qz`, `domtree.qz`, `mir.qz`, `codegen_c.qz`, `mir_lower_gen.qz`, and `quartz.qz`. Surfaced type-inference conflicts on `Map<String, Int>` (`eg_byid_set` and `opt_byid_set` parameter `instr`) and `Vec<Int>` (`mir_gen_add_resume_block` parameter `block`), which were handled via `as_int_generic(...)` cast at the collection boundaries. param Struct 685 → 629 (−56); param Enum remained unchanged (488). Golden `quartz-pre-n3.1-4b-incr10-golden` saved.

🔑 **The clean single-producer vein is mostly mined; ~685 `param Struct` remain. CORRECTED remaining-producer analysis
(by the ACTUAL caret-pointed token, not the outer call name — the earlier per-file "push()/Vec-element" read was an
extraction artifact of counting the outermost call when the fire was on a nested arg):** count fires by the firing
identifier with
```bash
awk '/boxed param `Struct`/{w=1;next} w&&/--> /{w=0;getline;getline s;getline c; col=index(c,"^");bar=index(s,"|");code=substr(s,bar+2);rest=substr(code,col-bar-1);if(match(rest,/^[A-Za-z_][A-Za-z0-9_]*/))print substr(rest,1,RLENGTH)}' /tmp/incr9_noansi.txt | sort | uniq -c | sort -rn
```
→ top tokens: `instr` 130, `ast_store` 82, `entry` 57, `func` 55, `s` 34, `mir_prog` 28, `block` 26, `callee` 25,
`mod_ast_storage` 19, `blk` 18, `state` 16. Two distinct piles:

1. **MIR handles still `:Int` OUTSIDE the codegen cluster #8 swept — the clean, high-leverage next chunk (same proven
   param-flip pattern).** `instr`/`func`/`block`/`blk` live as `:Int` params in the **optimization-pass cluster**:
   `egraph_opt.qz` (func 14, block 7, instr 4), `mir_opt.qz` (instr 4, block 4, func 1), `domtree.qz` (func 2, block 2),
   plus stragglers `mir.qz` (instr 1), `codegen_c.qz` (blk 1), `mir_lower_gen.qz` (block 1). ~9 `instr` params clear ~130
   `instr.mir_instr_*()` callsite fires; same for func/block. **This is increment #10 — extend the MIR-handle flip into the
   opt-pass cluster exactly as #8 did for codegen.** Verify each `func` is MirFunc (check `func.mir_func_*` usage — in an
   e-graph it should be) and watch for the BSD-`sed`-no-`\b` trap (#8's lesson) and substring false-matches
   (`current_func`-style). NOTE `mir_prog` (28) is the SAME as `prog` but spelled `mir_prog` in some files — fold it in
   (it's MirProgram).
2. **The layering-blocked forced-`Int` corner — NOT fixable in 4b, deferred to 4c.** `ast_store` (82) is overwhelmingly
   `var ast_store = entry.ast_store` where `entry: ResolverEntry` and `ResolverEntry.ast_store: Int` is the documented
   module-cycle corner (`compiler_types.qz` can't `import ast`). `entry` (57), `mod_ast_storage` (19), `func_ast_store`,
   `trait_ast_store` are the same family (struct fields holding handles that can't name their type without breaking the
   DAG). These are CPtr-like sanctioned-Int handles the 4c wall must EXEMPT, not de-existentialize. **Do not chase them in
   4b.** This is why `mir_lower.qz`'s residual 115 does NOT shrink with more handle flips — it's mostly this corner.

**Two deliberately-deferred MirBlock follow-ups (from #9's commit body):** (a) `mir_block_set_branch`/`_set_switch`
*target* params (`true_target`/`false_target`/`default_target`: `MirLabel` → `MirBlock`, proven `MirBlock` via codegen
`target.mir_block_get_label()`) — forces a block-PARAM cascade AND converts `unknown` fires to `param Struct` fires on
un-flipped sites, so do it WITH the block-param plumbing in one increment; (b) `mir_block_get_branch_true/false` RETURNS —
a real **cross-backend inconsistency** (`codegen_c` treats the result as a `Vec` INDEX; LLVM/wasm/domtree as a HANDLE)
that needs a design decision, not a mechanical flip.

**Recommended next attack = increment #10: the opt-pass MIR-handle flip** (`egraph_opt`/`mir_opt`/`domtree` +
`mir_prog`/stragglers), the largest CLEAN homogeneous remainder. The `f` (function-value) param in `mir_opt` and the
ResolverEntry-corner family are NOT 4b targets. Re-measure from a fresh audit (`/tmp/4b_incr9_clean.txt` last snapshot).

**Audit invocation (the meter):**
```bash
QZ_N3_AUDIT=1 ./self-hosted/bin/quartz --no-cache \
  -I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend \
  -I self-hosted/shared -I std -I tools self-hosted/quartz.qz > /tmp/x.ll 2> /tmp/audit.txt
# meter = param Struct + param Enum:
grep -oE 'boxed param `[^`]*`' /tmp/audit.txt | sort | uniq -c | sort -rn
# per-file param-Struct breakdown:
awk '/boxed param `Struct`/{w=1;next} w&&/--> /{l=$0;sub(/.*--> /,"",l);sub(/:[0-9]+:[0-9]+ *$/,"",l);c[l]++;w=0} END{for(f in c)print c[f],f}' /tmp/audit.txt | sort -rn
```

### 11.17 N3.1 step-4b — incr #10 done; the clean vein is EXHAUSTED; remainder gated on 4a-3 + 4c (2026-06-10)

**Incr #10 (`e5ddb609`/`ff88ba25`):** the opt-pass MIR-handle flip — `instr`/`func`/`block`/`caller`/`callee`/`mir_prog`
→ `mir::Mir*` across `egraph_opt`/`mir_opt`/`domtree` + stragglers (7 files). **param Struct 685 → 629 (−56)**; Enum
unchanged. (Done by a different model; independently re-verified: fixpoint byte-identical, meter real, forbidden corners
untouched, qspecs green. The modest net is correct — flipping these params relocates fires to the `Vec<Int>`-iteration
callsites, which are the Vec-element category below.)

**🔑 CONCLUSION: step-4b's clean annotation-flip phase is COMPLETE.** Session total `param Struct` 2424 → 629 (−74%)
across incr #5–#10; `param Enum` 488 (untouched). The remaining **629 `param Struct` + 488 `param Enum` are NOT
clean-annotation-only work** — every meter-movable fire routes through one of two DEFERRED prerequisites:

1. **Vec-element cascade → blocked on 4a-3 (cross-module nominal identity in the qzmod cache).** The bulk of the
   remainder is `for instr in instrs` / `func` from `mir_get_functions()` / `block` from `func.blocks` — i.e. iteration
   locals off `Vec<Int>` collections that actually hold handles. Clearing them needs `Vec<Int> → Vec<mir::MirInstr>`
   (etc.) **on the MIR structs that get pickled into the qzmod module cache** (`MirProgram.functions`, `MirFunc.blocks`,
   `MirBlock.instructions`). **This is NOT annotation-only** — a nominal struct id (≥7000, per-module) lands in a
   serialized ptype type-arg position, and the qzmod cross-module remap (`qzmod_load.qz:34` `producer_ptype_idx →
   consumer_type_id`) does not normalize nominal ids nested inside a `Vec<…>` type-arg. **PROVEN by a discarded WIP
   attempt** (preserved `/tmp/gemini_wip_incr11.patch`): it did exactly this cascade (`mir_get_functions(): Vec<MirFunc>`,
   `mir_func_get_blocks(): Vec<MirBlock>`, `mir_block_get_instructions(): Vec<MirInstr>` + the qzmod pool struct), got
   `param Struct` to **383 (−246)**, compiled, **passed fixpoint, passed all specs WITHOUT cache** — but **823 specs
   SEGFAULT under `--cache-ro`** and guard rejects at the cache-ro qzmod smoke (`network_timeout_spec` drops a module
   symbol). The bare nominal flips of #5–#10 survive the cache because 4a-2 ships per-module struct ids as a portable
   wildcard (`struct-range → TYPE_STRUCT`), but that normalization does **not** reach nominal ids embedded in `Vec<T>`
   type-args. **⇒ The Vec-element cascade requires extending the qzmod cross-module type-id normalization to ptype
   type-args first = the 4a-3 sub-project. Do NOT attempt the Vec-element cascade as a 4b annotation increment — it WILL
   crash the warm-cache suite.** Lesson for whoever does 4a-3: change the qzmod serialization in ONE collection at a time,
   bump/verify the cache format, and gate every step on `quake guard` (its cache-ro smoke is the catch-net; plain
   fixpoint + no-cache specs are NOT sufficient — they pass while cache-load segfaults).

2. **Forced-`Int` corner → blocked on 4c.** ~196 fires are the `ResolverEntry.ast_store`/`entry`/`mod_ast_storage`/
   `trait_ast_store`/`func_ast_store`/`actor_ast` family (`var x = entry.ast_store` field reads), un-typeable without
   breaking the `compiler_types.qz` ↔ `ast.qz` module cycle. `param Enum` (488) is the SAME two categories (Vec
   collections like `field_types`/`arg_types`/`concrete_types` indexed → Vec-element; `entry[…]` → corner; + some stdlib).

**Recommended sequencing from here:** (a) **4a-3** (qzmod ptype-type-arg nominal-id normalization) — the gate that
unblocks the entire Vec-element cascade (the largest remaining reduction); hazardous (qzmod/cache), do it as its own
focused effort with per-collection guard verification. Then the Vec-element cascade becomes safe annotation work. (b)
**4c** (the bare-Int wall, warn→error) — must EXEMPT the forced-Int corner + scalar-newtype handles as sanctioned Int.
The clean #5–#10 work needs neither and stands on its own.

### 11.18 N3.1 step-4a-3 — the handoff diagnosis was WRONG: the real blocker is `Vec<RefStruct>` copy-on-read (2026-06-10)

**§11.17's root-cause attribution (qzmod ptype-type-arg nominal-id normalization in the cross-module cache) is REFUTED
by direct reproduction.** Two prior models chased the cache/serialization ghost; the actual mechanism is a
codegen value-semantics mismatch with nothing to do with the qzmod type-id remap.

**How it was found (empirical, not prose).** Applied the discarded WIP (`gemini_wip_incr11`: `MirProgram.functions:
Vec<MirFunc>`, `MirFunc.blocks: Vec<MirBlock>`, `MirBlock.instructions: Vec<MirInstr>`), reproduced the `--cache-ro`
segfault (cache_smoke, ~4s), and walked it down with lldb + source instrumentation:
- Backtrace: `cg_emit_terminator → mir_block_get_label(NULL)` during codegen of a **cache-loaded** body
  (`gen$Stream$next` from `std/gen`, `float$_bn_norm` from `std/fmt/float`). So the crash is in CODEGEN of unpickled
  MIR, not in typecheck/type-injection — already inconsistent with the "type-arg remap" story.
- `mir_bodies.bin` byte-diff (WIP encoder vs golden encoder, same source): **identical offsets**, but the WIP wrote
  block-ref indices `-1, -1` where the golden wrote `1, 2`. So the WIP **encoder** stores wrong block refs.
- Instrumented `_mir_pickle_block_ref`: its identity search `as_int_generic(blocks[i]) == as_int_generic(raw)` **misses
  even when `raw` is literally present in `blocks`** (printed the full element list; `raw` matched element 2, loop still
  returned −1). → the comparison is miscompiled.
- Ground-truth LLVM IR of `qzmod_emit$_mir_pickle_block_ref` (`for_body5`): indexing `blocks: Vec<MirBlock>` emits
  `%v14.copy = alloca i8, i64 56` + `llvm.memcpy(copy, srcptr, 56)` + `ptrtoint copy` — i.e. **`v[i]` returns the address
  of a fresh by-value COPY of the 56-byte struct, not the stored heap handle.** `raw` (a real block pointer) can never
  equal a copy address ⇒ every search misses ⇒ `-1` stored ⇒ unpickle fixup turns `-1` into NULL ⇒ codegen derefs NULL.

**Minimal reproducer (no qzmod, no cache):** `/tmp/vecbig.qz` — a 7-field non-`@value` struct, `vec.push`, then a loop
`as_int_generic(v[i]) == as_int_generic(target)` returns "not found" for an element that IS in the vec. A 1-field struct
does NOT repro (size/field-count gated).

**The actual mechanism — `cg_intrinsic_vec.qz` `vec_get`, wide path (~L1329):** for a non-`@value` struct with
`field_count > 1`, `vec_get` does a "pointer-based deep copy" — load the stored handle, follow it, `memcpy` the fields
into a stack `alloca`, return the copy's address. So **`Vec<NonValueStruct>` has copy-on-read VALUE semantics in
rvalue/scalar context**, which destroys the reference identity every MIR handle relies on (blocks are compared by
pointer and mutated in place). This is also *inconsistent*: the lvalue/field-access path (`MIR_INDEX` in
`codegen_instr.qz`) returns a pointer INTO the original (reference) — verified: `var z = v[0]; z.b = 77` is visible
through `v[0]` again. So `v[i]` for a reference struct is reference-semantic for field access but value-semantic (copy)
for scalar/`as_int_generic` use. The copy is the outlier.

**⇒ The Vec-element cascade is NOT blocked on qzmod serialization. It is blocked on `Vec<RefStruct>` rvalue reads
copying instead of returning the stored handle.**

**The fix (landed, regression-free).** `vec_get` and `vec_get_unchecked` had the deep-copy gated on
`mir_prog_get_struct_field_count(_elem_type) > 1` — which matches ANY multi-field struct, including reference structs.
But that deep-copy serves TWO populations, and conflating them was the bug:
1. **`@value` structs stored BOXED** (mixed scalar+pointer, can't inline-pack under the GC firewall — e.g.
   `Tagged{ id: Int, name: String }`). These have VALUE semantics and MUST be value-copied on read. (`vec_value_packed_spec`
   exercises exactly this.)
2. **Non-`@value` reference structs.** These have REFERENCE identity (compared by pointer, mutated in place); a read
   must return the stored handle, NOT a copy.

The fix changes the gate from the raw struct field count to the **`@value` field count**
(`mir_prog_get_value_field_count`, which is `> 0` only for `@value` structs): `> 1` ⇒ `@value` boxed ⇒ keep the deep
copy; else ⇒ reference/scalar/handle ⇒ `load i64` (return the handle). This is surgical — it changes behavior ONLY for
non-`@value` reference structs, leaving every `@value` path (inline via `_vg_vfc > 1`, boxed via the new
`value_field_count` gate) untouched. The other Vec readers (`MIR_INDEX`, `MIR_INDEX_RAW`, `vec_pop`) already gate on the
`@value` inline count (`cg_vec_inline_field_count`) and were always correct — `vec_get`/`vec_get_unchecked` were the
outliers. **Naively stripping the copy entirely (a first attempt) is WRONG — it breaks `@value`-boxed reads.**

**Pre-existing failures unrelated to this work (verified on pristine HEAD / `quartz-pre-n3.1-4a3-golden`):**
`vec_value_packed_spec`, `arenas_advanced_spec`, `async_rwlock_batch_wake_spec` all FAIL on clean HEAD before any
change here. Do NOT attribute them to the codegen fix or the cascade. The WIP cascade additionally requires updating
`qzmod_emit_spec` + `qzmod_mir_bodies_roundtrip_spec` (they assert the old `Vec<Int>` MIR-collection API).

Validation oracle: guard fixpoint + the full qspec suite (compare the failure SET to pristine HEAD — must be identical)
+ the cache-ro smoke (the WIP cascade replayed on top of the fix passes it). Regression spec:
`spec/qspec/vec_index_spec.qz` "Vec of reference struct preserves identity". Goldens: `quartz-pre-n3.1-4a3-golden`.

### 11.19 N3.1 step-4b — Vec-element cascade LANDED on top of the codegen fix (2026-06-10)

With the §11.18 codegen fix committed (`5361b984`), the Vec-element cascade became safe annotation work and was
landed: `MirProgram.functions: Vec<Int> → Vec<MirFunc>`, `MirFunc.blocks → Vec<MirBlock>`, `MirBlock.instructions →
Vec<MirInstr>` + the matching getters/setters and the qzmod MIR-body pickle (`mir_funcs: Vec<MirFunc>`, the
`_mir_pickle_block`/`_fixup_block_ref` plumbing). `Vec<Int>` boundaries that genuinely hold non-handle ints keep an
`as_int_generic(...)` cast (e.g. `_gen_resume_blocks`, `eg_byid_set`/`opt_byid_set` `Map<String,Int>`).

**QZ0215 `param Struct` 629 → 383 (−246, −39%)**; `param Enum` 488 unchanged. **guard PASSED — fixpoint gen1==gen2
(2814 fns), cache-ro qzmod smoke + warm-cache dep-invalidation green, Rule-2 smokes green.** The 2 qzmod specs were
updated: drop the `as_int_generic(...)` wrapper at `Vec<MirFunc/Block/Instr>.push` sites (push the typed handle), and
push a typed null `as_type<mir::MirFunc>(0)` for the sentinel slot. Full qspec failure set unchanged vs pristine HEAD
(the §11.18 pre-existing failures only). The cascade source originated as a discarded WIP
(`/tmp/gemini_wip_incr11.patch`) — it was correct all along; only the codegen fix was missing.

**Remaining N3.1 step-4 work:** the `param unknown` ~4809 newtype FPs and the `param Enum` 488 + residual `param Struct`
383 (forced-`Int` ResolverEntry corner + remaining Vec/iteration tails) are 4c's job (narrow `tc_is_i64_type`,
warn→error, EXEMPT the forced-`Int` corner + scalar newtypes). `4a-3` as previously scoped (qzmod ptype-type-arg
nominal-id normalization) is NOT needed for the cascade — the cross-module struct-range→`TYPE_STRUCT` wildcard from
4a-2 already carries the `Vec<MirBlock>` element types portably (the cache-ro smoke proves it).

### 11.20 N3.1 step-4c incr #1 — Int-backed newtypes exempted from the wall (2026-06-10)

**The 4,809 `param unknown` "newtype FPs" were a single predicate bug, not a worklist.** Root-caused
the dominant audit category to one line: `tc_nil_forbidden_type` (the `tc_type` predicate that gates the
QZ0213 nil-literal **error** and the QZ0214/0215 audit **warnings**) blanket-returned `1` for the entire
`TYPE_NEWTYPE_BASE..TYPE_FORALL_BASE` range (1000–4999). Every newtype in the codebase is Int-backed
(`AstNodeId`, `MirReg`, `MirLabel`, `InternId`, `TypeId` — all `= Int`), so every `entry.node_id` / handle
arg flowing into an `AstNodeId`-typed param FALSE-fired. The predicate's own contract (line 533: "Int-handle
types → 0") already said these should be exempt; the implementation contradicted it.

**The fix (principled, future-correct).** Newtypes now classify by their **wrapped** type, not by the id
range: resolve `newtype_wrapped_types[idx]` via `tc_parse_type` and recurse (`if wrapped != t`). An Int-backed
newtype → `0` (an i64 index/handle whose representation is unchanged by the value-layout flip — bare-`Int`/`nil`
into it is just an integer, never the billion-dollar mistake). A reference-backed newtype (`newtype Email =
String`) → inherits its wrapped type's wall (`1`). Unions/records/intersections (2000–4999) and ptypes (≥100000)
keep the blanket `1`. Threaded `tc` through `tc_nil_forbidden_type` and its 9 call sites (3 each at the
let / return / call-arg wall positions).

**Meter: QZ0215 5,733 → 910 (−84%)** (`param unknown` 4,809 → 14). **QZ0213 16 → 0** — those 16 were all
`nil`-into-Int-handle false positives; the live error now fires only on genuine reference slots. The change
**cannot alter emitted IR** (the predicate feeds only diagnostics; QZ0213 can only fire *less*), so it is
fixpoint-trivial — **guard PASSED, gen1==gen2 (2814 fns)**, cache-ro qzmod smoke + warm-cache dep-invalidation
green, Rule-2 smokes (style_demo + brainfuck) green. Regression: `nil_literal_wall_spec` +2 cases (Int-backed
newtype accepted; reference-backed newtype rejected), 5 wall/newtype specs green. **Full qspec suite: 630
pass; the only failures are 3 pool-contention flakes (`resolver_go_arg_module_var`/`async_multimodule`/
`tcp_acceptable` — all pass standalone) and 2 pre-existing `@value`-ABI failures (`value_struct_gc_firewall`,
`value_struct_narrow_byval` — verified identical failure on the pristine-HEAD golden via the proper harness;
NOT named in §11.18's list but the same `@value` subprocess-compile family). Zero specs newly fail under 4c-1.**

**Cosmetic gap (filed, not chased):** `tc_type_name` renders a reference-backed newtype param as `unknown` in
the QZ0213 message ("parameter type `unknown`"). Not a behavior bug — the wall fires correctly — but the
diagnostic should name the newtype. Low priority; bundle with the `tc_type_name` newtype case when convenient.

**Remaining N3.1 step-4 (the meter after 4c-1):** **488 `param Enum` + 381 `param Struct`** (+14 residual
`unknown` = records/unions/`Vec`-typed args like `tc_register_record`/`mir_instr_set_args`, + 8 `Vec` + 4
`String`). These split exactly as §11.17 predicted: the **forced-`Int` ResolverEntry corner**
(`entry.ast_store`/`mod_ast_storage`/… — un-typeable without breaking the `compiler_types.qz`↔`ast.qz` module
cycle; 4c must EXEMPT these as sanctioned Int, NOT de-existentialize) and **remaining Vec/iteration tails**
(de-existentialize like 4b). Only once the genuine-fire count is driven near zero does the **warn→error flip**
(the actual "wall") land. Next increment: the forced-`Int` corner exemption (a `tc_type`-level sanctioned-handle
predicate), which should clear most of the corner's share of the 488+381.

**Corner anatomy (characterized 2026-06-11, before starting the cascade — read this first).** The forced-`Int`
corner is NOT one population; it is two, and only one is closable by re-typing a struct:
1. **`ResolverEntry`-struct fields** (`compiler_types.qz:24` — `ast_store: Int`, `node_id: Int`). The clean
   slice: `node_id` → the already-defined `newtype AstNodeId = Int`; `ast_store` → a NEW sanctioned
   `newtype AstStore = Int` (definable in `compiler_types.qz` with NO `ast` import — sidesteps the cycle). A
   newtype read is no longer bare `TYPE_INT`, so 4c-1's wall exemption fires automatically. Loose newtypes
   coerce freely to/from `Int`, so `entry.ast_store → s: AstStorage` params keep working. **But the blast
   radius is large: 184 `.ast_store` + 151 `.node_id` read sites** — a cascade needing per-step `quake build`
   + guard (its cache-ro smoke is the catch-net; `ResolverEntry` is pipeline-resident and may serialize).
   Do it as its own focused increment, NOT a tail-of-session slice.
2. **Positional array-tuples** (`mir_lower.qz:824` `var ast_store = entry[0]` / `entry[1]` = node, and the
   `[as_int(x), types, …]` literals in `mir_lower_expr_handlers.qz`). These are untyped `Vec<Int>`/array
   tuples indexed positionally — `entry[i]` yields bare `Int` no matter what. Re-typing a struct does nothing
   here; closing them needs the tuples promoted to real structs (a bigger refactor) or per-site sanctioned
   casts. This is the harder half of the corner and the `entry[0]`/`entry[1]` Enum+Struct fires come from here.

**Stdlib Enum cluster (separate, ~147 of the 488).** `std/cache.qz` (54), `persistent_worker_protocol.qz`
(58), `profile.qz` (18), `alloc.qz` (17) — enum-as-`Int` in stdlib protocol/serialization paths, independent
of the compiler's AST/MIR handle de-existentialization. Lowest priority for the flip (stdlib, not self-compile
load-bearing), but they DO count against the meter, so they must be sanctioned or de-existentialized before
warn→error can be global. Candidate: a narrower `tc_is_i64_type` flip scoped to compiler modules first, stdlib
later — TBD in the flip design.

### 11.21 N3.1 step-4c incr #2 — ResolverEntry handle fields re-typed; struct-half of the corner closed (2026-06-11)

**Closed the `ResolverEntry`-struct half of the forced-`Int` corner using 4c-1's machinery — no module-cycle
break, no name-based hack.** Added `newtype AstStore = Int` to `compiler_types.qz` (sits beside the existing
`AstNodeId`/`MirReg`/… handle newtypes; names the `ast::AstStorage` handle WITHOUT importing `ast`, so the
`compiler_types.qz`↔`ast.qz` cycle the corner was blamed on is sidestepped entirely). Re-typed
`ResolverEntry.ast_store: Int → AstStore` and `node_id: Int → AstNodeId`. Because a newtype read is no longer
bare `TYPE_INT`, 4c-1's wall exemption fires automatically — and the type **propagates by inference**: every
`var ast_store = entry.ast_store` local across the pipeline becomes `AstStore`, so the downstream
`ast_store → s: ast::AstStorage` param sites stop firing too. Loose newtypes coerce freely to/from `Int`, so
no coercion broke.

**Blast radius was 5 edits, not the feared 335.** The only build breaks were 4 `vec_push` sites pushing a
newtype value into a `Vec<Int>` (newtype Vec-strictness, `tc_elem_type_matches`): `_remark_seen`
(`quartz.qz`), `stores` (`mir_lower_async_registry.qz`), `_alias_primary_stores`/`_alias_primary_nodes`
(`mir_lower.qz`). Each fixed with an `as_int_generic(...)` boundary cast — the same pattern 4b used for
`Vec<Int>` collections that genuinely hold i64 handles. (Those four collections are themselves later
`Vec<AstStore>` de-existentialization candidates; the cast is correct sequencing, not a dodge.) Every other
`.ast_store`/`.node_id` read (184+151 sites) coerced silently — loose-newtype↔Int needs no change.

**Meter: `param Struct` 381 → 180 (−201, −53%); QZ0215 910 → 709.** Cumulative across the session: QZ0215
**5,733 → 709 (−88%)**. **guard PASSED — fixpoint gen1==gen2 (2812 fns), cache-ro qzmod smoke PASSED** (the
decisive test — `ResolverEntry` is pipeline-resident and the field-type change rides the cache portably;
the qzmod-hazard §11.17 feared did NOT materialize for a scalar newtype field), warm-cache dep-invalidation
green, Rule-2 smokes green, resolver/import/newtype/wall specs green. Diagnostic-only + identity casts ⇒ IR
unchanged.

**Remaining after 4c-2:** **488 `param Enum` + 180 `param Struct`** (+14 unknown + 8 Vec + 4 String). The
Struct residue is now the **positional array-tuple half** (`entry[0]`/`entry[1]` — `mir_lower.qz`; needs the
tuples promoted to structs, NOT a field re-type) + the MIR Vec-iteration tails (`blocks`/`block`/
`callee.mir_func_*`/`state.current_prog`). The Enum 488 is unchanged (entry[i] tuples + `field_types[j]`-class
Vec-element + the ~147 stdlib cluster). Next clean increment: the MIR Vec-iteration Struct tails (4b-style),
then the positional-tuple promotion, then the Enum Vec-element cascade — driving toward the warn→error flip.

### 11.22 N3.1 step-4c incr #3 — derive.qz AstStorage params + the strategic reframe: the meter has bottomed out on mechanical work (2026-06-11)

**The clean mechanical slice: derive.qz handle params → `ast::AstStorage`.** `re_parse_top_level(s: Int, …)`
and `expand_derive_annotations(s: Int, …)` declared their ast-storage handle as bare `Int`; re-typed both to
`s: ast::AstStorage` (already imported — derive.qz uses the `ast` API; no new import, the *real* type not the
`AstStore` bridge — `AstStore` stays reserved for `compiler_types.qz` which can't import `ast`). `s` had zero
bare-Int ops (pure handle), zero-ripple build. **`param Struct` 180 → 162** (derive fires 30 → 12; the
residual 12 are `root`/`node` = `AstNodeId`, needing a `compiler_types` import — deferred). guard PASSED
(fixpoint, cache-ro green), Rule-2 + targeted specs green.

**🔑 STRATEGIC REFRAME — the meter has bottomed out on mechanical re-types; the residual is genuine B.15
migration.** Tracing the remaining Struct fires shows they are NOT annotation cleanup:
- **Existential-0 sentinels / nullable-handle lookups.** `var mod_ast = 0` then reassign (`resolver.qz:474`);
  `var callee = cg_find_function(state, name)` where the lookup returns `0` for not-found and the code does
  `if callee != 0` (`codegen_instr.qz:210`). Re-typing the local/return to `MirFunc`/`AstStorage` would make
  the `0`-init / `return 0` **hit the wall itself** — because these genuinely encode "absence," and absence is
  exactly what `Option<T>` is for. **These are not de-existentializable by annotation; they are `Option<T>`
  conversions** (each needs the lookup to return `Option<MirFunc>`, the init to be `None`, and the `!= 0` /
  use sites to narrow/unwrap).
- **Positional array-tuples** (`entry[0]`/`entry[1]`, `ast_cache_result[0]`) — need struct promotion.

**⇒ Sequencing correction for the flip.** The earlier plan ("drive the meter to ~zero, THEN flip warn→error")
is wrong for this residual. You do NOT Option-ify hundreds of sentinel sites *before* the flip — the **flip is
the forcing function**: turning QZ0215 warn→error is what surfaces each genuine sentinel as a compile error to
be converted to `Option<T>` (or explicitly sanctioned). The mechanical re-types (newtype handles 4c-1, struct
fields 4c-2, clean params 4c-3) were the legitimate *pre-flip* cleanup — removing the FALSE positives so the
flip's errors are all REAL. That cleanup is now substantially done (QZ0215 5733 → ~691). **Next phase is the
flip design itself:** stage `tc_is_i64_type` narrowing so bare `Int ↛ {Struct,Enum}` becomes an error, scoped
(compiler modules before stdlib) and with the forced-Int positional-tuple + sanctioned-handle exemptions, and
let it drive the `Option<T>` conversions case-by-case. The remaining 162 Struct + 488 Enum are the *worklist
the flip generates*, not a prerequisite to it.

### 11.23 N3.1 step-4d — the staged flip, Phase 1: always-on wall WARNING (2026-06-11)

**Decision (ratified with the author 2026-06-11): the bare-Int wall flips via the Dart/C#/Kotlin
staged-nullable playbook — always-on warning → drain the worklist → flip warn→error last.** Rejected the
"drive meter to zero THEN flip" and "stage by module" alternatives: the former is impossible (the residual is
genuine sentinels the flip must *force*, per §11.22), the latter adds two-tier diagnostic complexity. Warnings
first keeps every build green and reversible until the final flip.

**Phase 1 (landed).** Replaced the `QZ_N3_AUDIT` env gate on QZ0214 + QZ0215 (all 6 sites: let / return /
call-arg × two codes) with a single control predicate `tc_n3_wall_warn_enabled()` (`typecheck_helpers.qz`),
currently `= true`. The worklist is now **always-on: every build emits 9 QZ0214 + 691 QZ0215 warnings, no env
var, build stays green.** The predicate is the single point of truth for the wall's phase — Phase 3 (warn→error)
is a one-line change here, not a 6-site sweep.

**The re-`tc_expr` was fixpoint-safe.** The return-site (`typecheck_walk.qz:4101`) and call-arg site
(`typecheck_expr_handlers.qz:3827`) re-walk the value/arg with `tc_expr` to get its type — previously env-gated
partly to keep that out of production. Un-gating makes gen2 compile with the re-walk active; **guard fixpoint
gen1==gen2 (2813 fns) held byte-identical**, proving the re-walk is side-effect-free w.r.t. emitted IR (it
returns the already-resolved node type; no double-registration). cache-ro qzmod + dep-invalidation smokes green,
Rule-2 smokes green, diagnostics/compiler-quality/wall specs green. (Cost: the re-walk runs on every non-literal
boxed-param arg in production now; the audit compile time was already acceptable, so no meaningful regression.)

**Phase 2 is now the work:** drain the 700-site worklist (always visible in any build's stderr; `grep QZ0215`).
Priority order = the genuine sentinels first (nullable-handle lookups → `Option<T>`: `cg_find_function`,
`var x = 0`-then-reassign), then positional-tuple promotion, then the stdlib enum cluster. Each conversion drops
the count; when it reaches ~0 (modulo the sanctioned-handle + forced-Int-tuple exemptions), Phase 3 flips
`tc_n3_wall_warn_enabled`'s consumers to `error`. **Track the count as the burn-down metric** (`grep -c QZ0215`
on a plain `--no-cache` self-compile — no env var needed anymore).

### 11.24 N3.1 step-4e/4f — Phase 2 burn-down (autonomous night, 2026-06-11)

**Parallel worklist analysis (5 read-only sub-agents) classified all 495 unique fire sites** into HANDLE
(clean re-type, LOW), SENTINEL (nullable handle → `Option<T>`, MED/HIGH), TUPLE (positional array → struct
promotion, MED/HIGH), STDLIB_ENUM, SANCTIONED (exempt). Full per-cluster tables in `/tmp/night_plan_{A..E}.md`.
Three findings correct the roadmap:

1. **`field_types`/`merged_types` are NOT `Vec<TypeId>` — the §11.21 cascade hypothesis was WRONG.** The
   elements are **interned string type-NAMES** (`tc_parse_type(tc, as_string(field_types[i]))`,
   `typecheck_registry.qz:2186`). The per-element `as_string(...)` reads are SANCTIONED (no change). The real
   de-existentialization is the `Vec<Vec<String>>` getters on `TcRegistry` (`typecheck_util.qz:324-325,349-350`)
   — and `TcRegistry` is read by `tc_emit_qzmod_modules`, so that IS a §11.18-class **serialized-struct element
   cascade (HIGH risk, qzmod cache-ro smoke is the catch-net)**. Kept OUT of unattended work.
2. **The stdlib cluster is ~97% SANCTIONED**, not a worklist. The effect-handler existential ABI
   (`(op_name:Int, argc:Int, argv:Int):Int` + `as_int`/`as_string`/`as_vec`/`as_type`/`as_int_generic` bridges)
   is the language's deliberate i64 transport; it should be **categorically exempt**. ⇒ **Flip-scoping
   decision: the Phase-3 warn→error flip excludes `std/` + `shared/`, and exempts any arg wrapped in an `as_*`
   existential-bridge intrinsic.** This sharpens §11.20's "compiler modules first" into a concrete exemption rule.
3. **New hole filed:** the 16 `persistent_worker_protocol.qz` fires all originate from `try` discarding its
   `JsonValue` payload type (`v = try parsed` lowers to a bare `Int`). Fixing `try`-payload-type preservation in
   lowering would clear them at the source — a separate compiler fix, not a stdlib edit.

**Burn-down executed (LOW-risk HANDLE re-types only, each guard-clean + fixpoint-trivial + Rule-2 + cache-ro):**

| step | change | QZ0215 |
|---|---|---|
| 4e | backend: domtree `dt_build_preds`/`dt_compute_rpo` blocks→`Vec<MirBlock>`, `mir_const_eval_call` caller_store→`AstStorage`, `cg_c_emit_terminator` blocks→`Vec<MirBlock>`, `_cg_emit_cross_module_declares` funcs→`Vec<MirFunc>`, `mir_scan_async_targets` s→`AstStorage` | 691→665 |
| 4f | frontend/middle: `parse_with_state`/`parse_with_target` token arrays Int→`Vec<Int>`, `macro_s`→`AstStorage`, `tc_error_at`/`tc_warning_at` s→`AstStorage` | 665→652 |
| 4f+ | derive `clone_function` src_s/dst_s→`AstStorage`, h→`AstNodeId` (+`import compiler_types`) | 652→640 |

**Session total: QZ0215 5733 → 640 (−89%).** The mechanical HANDLE vein is now essentially mined out —
remaining ~640 are SANCTIONED (`as_string`/effect-ABI, the majority), SENTINEL (`Option<T>` conversions the
warn→error flip must force), and TUPLE (struct promotion). Per-category map for the morning:
- **SENTINEL flagship:** `cg_find_function` (`codegen_util.qz:526`, returns 0-for-none) → `Option<mir::MirFunc>`;
  1 caller (`codegen_instr.qz:210` `if callee != 0`), ~13 `callee.mir_func_*` uses. The first real Phase-2 Option
  conversion; on the heavily-tested call-emission path.
- **TUPLE clusters:** `PendingSpec` queue (`mir_lower_expr_handlers.qz:1524/2587`→`mir_lower.qz:1173`), `prog.struct_defs`
  positional reads (mir.qz, ~59 fires), `DeferEntry`, resolver `ast_cache_result`. Each = one struct-promotion increment.
- **HIGH-risk gated:** the `TcRegistry` `Vec<Vec<String>>` cascade and the qzmod block-ref format (`0`/`-1` on-disk
  sentinels) — both touch serialized state; land with N3 + the cache-ro smoke, never unattended.

### 11.25 N3.1 step-4g + MORNING BRIEFING (autonomous night, 2026-06-11)

**4g — first SENTINEL→`Option` conversion: `cg_find_function` → `Option<mir::MirFunc>`.** The flagship
nullable-handle lookup (`codegen_util.qz`, two `return 0` absence paths) became
`def cg_find_function(...): Option<mir::MirFunc>` (`return Option::None` / `Option::Some(f)`). The sole caller
(`codegen_instr.qz` `cg_emit_call_ops`) destructures **once** into a `MirFunc`-typed `callee` (typed-null
`as_type<mir::MirFunc>(0)` when absent) + a `callee_found` bool, so the 6 `if callee != 0` guards became
`if callee_found` and the ~13 `callee.mir_func_*()` uses are now properly `MirFunc`-typed — no per-block unwrap
churn. **QZ0215 640 → 616.** (Construction syntax note for future Option work: Quartz requires *qualified*
`Option::Some`/`Option::None` for construction; bare `Some`/`None` resolve only in match arms — bare forms
QZ0401/0403 at build.)

**Verification (this conversion changes real IR — `Option<MirFunc>` spills since the boxed-pointer niche is
N3-gated):** guard PASSED — **fixpoint gen1==gen2 byte-identical (2813 fns)**; the compiler self-compiles
through the changed call-emission path millions of times identically. cache-ro qzmod + dep-invalidation green.
Rule-2 smokes green. **No perf regression** — guard self-compile timings identical to the prior step (Gen1→Gen2
30.4s vs 30.2s; Build 162s vs 165s), so the Option spill is negligible at this call site. Full qspec timed out
twice (environmental — the serial-retry tail under 4am machine contention; an earlier identical-suite run did
316s), so the failure set was confirmed by **per-spec forensics instead**: of the timed-out run's extras,
`diamond_import`/`fn_as_struct_field_init`/`value_types` PASS standalone (contention flakes), and `c_spec`'s
`--no-cache` `@qz_main`-undefined llc failure **reproduces byte-identically on the pre-night golden binary**
(pre-existing cache-mode quirk, NOT a regression — see hole below). Genuine failure set = the 7 pre-existing.

### 11.26 `try` payload-type preservation — the morning increment landed (2026-06-11)

**The fix from §11.25 item 2 / the filed hole, executed.** `tc_expr_try`'s regular-unwrap `else` branch
(`typecheck_expr_handlers.qz`) no longer collapses to `TYPE_INT`: it captures `inner_t = tc_expr(expr)` and, when
that is a ptype with base `TYPE_OPTION`/`TYPE_RESULT`, returns `tc_ptype_arg1(tc, inner_t)` (the payload `T`),
mirroring the match-handler extraction at `typecheck_match.qz:699-719`. The `TYPE_INT` fallback is kept only for
the bare-scalar `Result`/`Option` corner (no recorded type args), matching `typecheck_match.qz:656-665`.

**Red→green proof (QZ0215 is the only observable — the bug is silent at runtime):** the audit-warning count from a
full `--no-cache` self-compile dropped **616 → 558 (−58)**, and all **16 distinct `persistent_worker_protocol.qz`
sites (58 emissions) → 0**. The total drop equals exactly the persistent_worker contribution: no site elsewhere
regressed or newly fired. Targeted specs green (`try_keyword`/`try_catch`/`postfix_try`/`option_result`/
`result_helpers`/`result_predicates`/`json`). Rule-2 smokes green. **Fixpoint gen1==gen2 byte-identical** (the
self-compile traverses the changed branch via `persistent_worker_protocol.qz`, a compiler source).

**Two reality notes (D5), both counter-intuitive and worth recording:**
1. **The bug has no runtime or hard-error symptom.** Field reads and even method calls on the mistyped binding
   resolve structurally (UFCS by name; MIR lowering reads the real struct layout), and an explicit `var p: Struct =
   try …` annotation compiles too. So a *runtime* QSpec cannot be red-first here — the added struct-payload spec is
   regression coverage that fills the documented "zero non-Int try-payload coverage" hole, not a red→green oracle.
   The genuine red→green oracle is the QZ0215 count.
2. **QZ0215 only fires for boxed-struct params.** A 2-`Int` `TryPoint` is register-class, so even when `try`
   mistypes it the audit stays silent — which is why naïve synthetic repros (and the spec's runtime asserts) look
   identical before/after. The real fires came from `JsonValue` (boxed) fed into `json_object_get(_: JsonValue)`.
   See the inline-construction hole below for the boxed-payload caveat when authoring future repros.

### 11.27 Phase-3 exemption policy implemented — the `as_*` bridge + std/shared carve-out (2026-06-11)

**§11.24 finding 2, realized in code.** The bare-Int wall now categorically exempts the deliberate i64
transport, so the QZ0215 meter reflects only the genuine SENTINEL/TUPLE remainder the flip must force. Two
helpers in `typecheck_helpers.qz` (next to the phase-control `tc_n3_wall_warn_enabled`):
- **`tc_n3_is_bridge_name(name)`** — true for the five `INTRINSIC_CAT_CONVERSION` bridges (`as_int`,
  `as_int_generic`, `as_string`, `as_type`, `as_vec`). Wired into the **call-arg** QZ0215 guard
  (`typecheck_expr_handlers.qz` `tc_expr_call`): when the callee `func_name` is a bridge, its raw-i64 arguments
  are SANCTIONED reads (e.g. `as_string(field_types[j])` reading an interned name out of a `Vec<Int>`), not
  erased-value sentinels. The let/return sites don't need it — a bridge *result* is `String`/`Vec`, never bare
  `Int`, so QZ0215 never fired there.
- **`tc_n3_file_exempt(tc)`** — true when `tc.current_file` is under `std/` or `shared/`. Wired into all three
  QZ0215 guards (call-arg, let-binding, return). Stdlib is ~97% sanctioned (cluster-E) and the warn→error flip
  excludes it outright.

**Result: QZ0215 558 → 113 (−445, −80%), warnings-only — fixpoint gen1==gen2 byte-identical** (the change adds
`and <exempt>==false` to three `warn(...)` guards; zero IR/behavior impact). QZ0214 (bare int-LITERAL audit, a
distinct worklist) deliberately left untouched — 9 fires, out of scope for this carve-out. The revealed remainder
(~113) is now dominated by REAL work, no longer bridge noise:
- **`codegen_instr.qz` ×27 — the `CodegenState` `current_func`/`current_block`/`current_prog` cluster**
  (`state.current_func.mir_func_get_local_type(…)` etc.). This is exactly briefing item 1, now the single largest
  real cluster and unmasked as such. Still the AUTHOR DECISION (Option<T> fields vs. sanctioned nullable-ambient
  handle).
- `resolver.qz` ×17, `mir.qz` ×14, `mir_lower.qz` ×10 — TUPLE/SENTINEL increments.
- `ast.qz` ×7 — accessors declared `: Vec` (un-parameterized return) e.g. `ast_get_children(…): Vec`; a
  return-type-annotation tightening, not a sentinel.

**Note for the Phase-3 flip:** these exemptions are the flip's exemption set made executable — when the meter
reaches ~0 and `tc_n3_wall_warn_enabled` flips warn→error, the same two predicates keep std/shared + the bridge
ABI green without a per-site sweep. The flip-scoping decision in §11.24 finding 2 is now load-bearing code.

**Follow-on increment (committed `8b82c81c`): `mir_opt.qz opt_byid_get` → `mir::MirInstr`.** First clean post-exemption
HANDLE re-type: the getter mirrored `opt_byid_set`'s `as_int_generic` store by bridging the raw i64 back with
`as_type<mir::MirInstr>` (IR-identical reinterpret), clearing the 4 `opt_binary` fires (`li`/`ri` into
`mir_instr_get_kind`/`_get_int_val`). **QZ0215 113 → 109.**

### 11.28 `CodegenState current_*` — typed-null handle re-type (decision: Path B, 2026-06-11)

**The §11.25-item-1 / §11.27 author decision, made and executed.** `current_func`/`current_block`/`current_prog`
were `Int` fields holding erased `MirFunc`/`MirBlock`/`MirProgram` handles (set at `codegen.qz:742-743`,
`codegen_instr.qz:3990`); the 26 reads used them as the boxed type, firing QZ0215.

**Decision — typed-null handle, NOT `Option<T>`.** The fields are **ambient cursor state** ("where codegen is
now"), not data-optionality. Per-field analysis of the 26 reads + 4 writes:
- `current_func`/`current_block`: their null state is **never observed** — every read runs after the cursor is set
  (inside `cg_begin_function`'s body). The init is a dead placeholder the struct constructor demands.
- `current_prog`: null **is** observed, but at exactly **one boundary** — `cg_find_function` (`codegen_util.qz:527`)
  — which already lifts it into `Option<MirFunc>` for callers (step 4g). The field need not be `Option` for that;
  the boundary check does the lift.

So `Option<T>` was rejected: at 25 of 26 sites it degrades to `.unwrap()` (unchecked-null relocated to a runtime
panic — no safety gained) while paying `Option` spills (N3-gated niche) on the backend's hottest loop. The
principle: **typed-null handle = "nullable, checked at the boundary" (the deliberate corner, à la cancel_token);
`Option` = "the type system forces a check at every read."** You earn `Option` when many callers must branch on
absence; here exactly one does, and it already returns `Option`.

**Implementation (one guard-clean commit):** fields re-typed to `mir::MirBlock`/`MirFunc`/`MirProgram`; inits
`0` → `as_type<mir::T>(0)` (typed-null, established idiom — `codegen_instr.qz:216`); the single sentinel guard
`state.current_prog == 0` → `as_int(state.current_prog) == 0` (handle-null idiom, `mir_lower_expr_handlers.qz:297`).
All writes already assign correct handle types; all reads now correctly typed. **QZ0215 109 → 84 (−25); the entire
`current_*` cluster cleared (codegen_instr 27→5, codegen_util→0), zero leftovers.** Fixpoint gen1==gen2 (2815 fns) —
typed-null `0` is identical bits to the old `Int` `0`, so **zero IR change** on the hot path, exactly as the
decision predicted. **Caveat (the trade):** a typed-null relies on the invariant "no instruction emitted outside a
function-emission context"; today that holds structurally (the one racy path is the guarded `cg_find_function`).
If ever violated, this yields a 0-handle deref (segfault) where `Option` would have given a catchable panic.

The 5 residual `codegen_instr.qz` fires are a **separate** block-target HANDLE cluster (`target.mir_block_get_label()`
on terminator targets), not `current_*` — a future increment.

**Remaining ~79 worklist (post-exemption, real work — the cheap mechanical vein is mined out):**
- ~~`CodegenState current_*`~~ — **DONE (§11.28).**
- ~~Block-target HANDLE cluster (`codegen_instr.qz` ×5)~~ — **DONE (§11.28).** `target`/`then_blk`/`else_blk`/
  `default_target`/`ct` terminator-target locals into `mir_block_get_label()`. NOT a source-getter re-type:
  `mir_block_get_term_data` is polymorphic (value-reg for `TERM_RETURN`), and `mir_block_get_branch_true`/`_false`
  are consumed as *indices* by `codegen_c`/`codegen_wasm`/`domtree`. So bridged at the 5 locals
  (`var t: mir::MirBlock = as_type<mir::MirBlock>(…)`) — contained to `codegen_instr.qz`, IR-identical. **84 → 79.**
- ~~Core MIR emit-API `args: Int` cascade~~ — **DONE (§11.29).** All six params re-typed to `Vec<Int>`; the cascade
  resolved to stripping 41 `as_int(vec)` laundering bridges at the call sites (not the feared broad caller rewrite).
  QZ0215 84→73 net across §11.28+§11.29 (the 6 set_args fires cleared). Fixpoint byte-identical.
- **`mir.qz` `var b: MirBlock = entry[1]/[2]` + `typecheck.qz tc_register_*record(parsed[N])` — TUPLE reads**
  (positional `Vec<Int>` → struct promotion). Self-contained MED increments.
- **`ast.qz` ×7 bare-`: Vec` accessors** (`ast_get_children(…): Vec` etc.) — un-parameterized return on the
  AstStorage existential; part of the AstStorage de-existentialization cascade (§11.20+), also broad.
- **GATED (never unattended):** `typecheck_registry` record/intersection field getters (serialized → qzmod,
  §11.18-class) and qzmod block-ref sentinels (N3). Cache-ro smoke is the catch-net.

### 11.29 Core MIR emit-API `args: Int` → `Vec<Int>` cascade — LANDED (2026-06-11)

**The §11.28-filed "dedicated focused pass" target, executed.** The six emit-API constructors
(`mir_emit_call` / `mir_emit_intrinsic` / `mir_emit_intrinsic_typed` / `mir_emit_perform_op` / `mir_emit_inline_c` /
`mir_emit_call_indirect`, `mir.qz:5271-5870`) each declared `args: Int` while immediately forwarding it to
`mir_instr_set_args(instr, args: Vec<Int>)` — so the param was an erased `Vec<Int>` handle, firing QZ0215 six times
(once per `set_args` call). Re-typed all six params to `Vec<Int>`.

**The cascade was shallower than feared — and the result is a net code cleanup, not just an annotation.** The 354
caller sites split cleanly:
- **313 already pass a `Vec<Int>`** — array literals (`[try_result]`) or `vec_new()`-built locals (`Vec` → `Vec<Int>`
  is existential-compatible). Zero change, zero new fire.
- **41 wrapped their vec local in `as_int(...)`** to launder it into the old `Int` param
  (`mir_emit_intrinsic("atomic_load", as_int(ld_a))`). Re-typing the param relocated the fire to these 41 sites
  (Int → `Vec<Int>`), so the migration is to **strip the `as_int()` bridge** — pass the `Vec<Int>` directly. The
  `as_int` reinterpret was a pure no-op (Vec handle → i64 is identity); removing it is IR-identical and deletes 41
  redundant bridge calls from the hottest MIR-construction path (`mir_lower_expr_handlers.qz` ×34 async mutex/rwlock
  CAS/park lowering, `mir_lower_gen.qz` ×5, `mir_lower.qz` ×2). Mechanical perl strip scoped to emit-API lines.

**Method (two guard-clean builds, the §11.24 measure-then-migrate loop):** (1) re-type 6 params → build → audit
showed QZ0215 79→114 (+35: the 6 `set_args` fires cleared, 41 `as_int` caller fires revealed); (2) strip the 41
`as_int` bridges → build → **QZ0215 73** (79 − 6, exactly the predicted net; the 41 relocated fires gone, the 6
emit-API fires eliminated). No emit-API/`set_args` QZ0215 fire remains.

**Verification:** guard **fixpoint gen1==gen2 byte-identical (2815 fns)** — the compiler self-compiles through every
call/intrinsic emission identically; cache-ro qzmod + warm-cache dep-invalidation smokes green; Rule-2 smokes
(style_demo renders, brainfuck "4 passed, 0 failed") correct; examples golden==current==0 QZ0215. Full qspec **824
passed**; every failure is either a pre-existing `@value`/segfault compile-failure (`arenas_advanced`,
`struct_destructure`, `vec_value_packed`, `stack_alloc_return`, `escape_analysis`, `value_struct_*` — verified
**symmetric on the pre-change golden** by direct compile) or a parallel-contention flake that passes standalone
(`scope_sleep` 7/7, `value_types` 8/8, `compiler_quality`, `import_order`, `wasm_str_find_option`). **Zero
regression.** (Process note: running suspect specs via `quake qspec_file` against a hand-swapped golden binary is
useless — `qspec_file` rebuilds from current source on a stale stamp; to A/B a binary, compile the spec *directly*
with each binary. The swap also drifts the working-tree `bin/quartz` via link non-determinism — re-guard + `git
checkout -- bin/quartz` re-syncs working == staged == stamp before commit.)

### 11.30 resolver.qz AstStorage-handle local re-types — LANDED (2026-06-11)

**The largest post-§11.29 cluster (`resolver.qz ×17`, the single biggest file), cleared.** All 17 fires were the
same shape: three local variables holding `AstStorage`/AST-handle values but **declared `var X = 0`** (bare `Int`,
so each use into an `ast::AstStorage`-typed param fired the bare-Int wall). The key discovery: passing an
**Int-backed newtype** (`AstStore`) into an `ast::AstStorage` param does *not* fire — §11.20's newtype exemption
already covers `all_funcs[fnd].ast_store`-style direct uses. So the fix is just to give each local a non-bare-Int
type matching its data flow:

- **`mod_ast`** (`resolver.qz:474`, module-load core) → `ast::AstStorage`, typed-null init `as_type<ast::AstStorage>(0)`.
  RHS at `:493` is `ps_get_ast_storage(): ast::AstStorage` (clean); the cache-hit RHS `ast_cache_result[0]` (a
  `Vec<Int>` element) bridges `as_type<ast::AstStorage>(…)`; the round-trip store into the `Vec<Int>` module
  registry (`:603`) bridges back `as_int(mod_ast)`.
- **`sample_ast_re`** (`:854`, UFCS re-collect) → `ast::AstStorage`; Int RHS from `_resolve_mod_reg_ast_stores`
  (`vec_new<Int>()`) bridged; the `!= 0` presence check → `as_int(sample_ast_re) != 0` (handle-null idiom, §11.28).
- **`trait_ast_store`** (`:2085`, trait-default-wrapper synthesis) → `AstStore` (newtype), init `as_type<AstStore>(0)`.
  Chosen over the struct because its RHS (`e.ast_store: AstStore`) and downstream `ResolverEntry { ast_store: … }`
  field are *both* `AstStore`, and the ~11 `ast::ast_get_*` uses are newtype-exempt — so only the init needs a bridge,
  everything else is natural.

**QZ0215 73 → 56 (−17); all `resolver.qz` fires cleared, zero leftovers.** One build caught a real hole the
typechecker flagged as `QZ0200` (hard error, not a warning): `_resolve_mod_reg_ast_stores.push(mod_ast)` pushed the
now-`AstStorage` value into a `Vec<Int>` — fixed with `as_int(mod_ast)` (the store half of the `:858` read-back
round-trip). **Fixpoint gen1==gen2 byte-identical (2815 fns)** — `as_type`/`as_int` are no-op reinterprets, so the
locals carry the same i64 handles with sharper types: zero IR change, exactly as a handle-retype should. cache-ro +
dep-invalidation smokes green; Rule-2 smokes correct. Targeted-spec coverage of both clusters (153 tests, all green):
cluster A / module-registry — `import_order` 7/7, `diamond_import` 6/6, `cross_module_types` 8/8, `cross_module_fixes`
14/14, `as_type_module_qualified` 2/2; cluster B / trait-default synthesis — `impl_trait` **47/47** (the 38 KB
default-wrapper spec, the exact `trait_ast_store` path), `abstract_trait` 8/8, `container_trait` 12/12,
`hybrid_ufcs_traits` 10/10, `trait_self` 3/3, `impl_unification` 8/8, `enum_ctor_in_impl` 5/5; plus
`arity_overload`/`generic_ufcs_dispatch`/`binary_methods` for UFCS/overload resolution. Not a broad cascade — these
are *locals*, not params, so nothing propagates to callers (contrast the `ast.qz` accessor de-existentialization,
still broad/deferred). **Verification caveat (D5):** the full parallel `quake qspec` and the serial fallback both
failed to complete this session — the async/scheduler specs (`actor_spec`, …) time out under ordinary machine
contention (the documented qspec worker-starvation hang, `docs/handoff/2026-05-09-qspec-scheduler-mystery.md`), an
environmental issue that cannot touch this compile-time-only resolver change. Verification basis is therefore
fixpoint-byte-identical + IR-identical-by-construction + the 153 targeted trait/module tests, which cover exactly the
two paths edited.

### 11.31 mir_const + mir_lower AstStorage-handle local re-types — LANDED (2026-06-11)

**Two tight clusters batched into one commit** (same clean read-site-bridge idiom as §11.30; the §11.24 "LOW-risk
HANDLE re-types only" pattern). Both clear `ast::AstStorage` handles erased to bare `Int` via a `var X = …[i]`
positional read, passed into `ast::ast_get_*` / `mir_lower_stmt` / `mir_const_eval_body` (`ast::AstStorage` params):

- **`mir_const.qz` ×4** — the single local `fn_store` (`:189`, `var fn_store = fn_stores[fn_idx]` where the param
  `fn_stores: Vec<Int>` is the deliberate i64 transport). Re-typed to `ast::AstStorage` with the read bridged
  `as_type<ast::AstStorage>(fn_stores[fn_idx])`; the 4 uses (`ast_get_right`/`ast_get_left`/`ast_get_str1` +
  `mir_const_eval_body`) become clean. (`mir_const_eval_call`'s `caller_store` was already `AstStorage` from §11.24.)
- **`mir_lower.qz` ×3** — the `DeferEntry` `ast_store` (`var ast_store = entry[0]`, the same `var`-then-positional-read
  shape in three sibling defer-emit fns `emit_deferred`/`emit_deferred_to_depth`/the inline-scope drain). `entry` is a
  positional `Vec<Int>` tuple; `entry[0]` is the store handle. Bridged identically (`replace_all` over the three
  identical lines). The full `DeferEntry`→struct promotion (§11.28 TUPLE list) stays deferred — this is the contained
  handle-retype that clears the fires now, IR-identical.

**QZ0215 56 → 49 (−7); both clusters fully cleared, no new fires.** **Fixpoint gen1==gen2 byte-identical (2815 fns)** —
`as_type` is a no-op reinterpret, zero IR change. cache-ro + dep-invalidation smokes green; Rule-2 smokes correct;
targeted specs green — `const_eval` (the 16 KB const-function-eval spec, the exact `mir_const` path) + `const_generics`
/ `module_const` / `ufcs_constants`, and `defer` / `cross_defer_safety` / `drop` (the mir_lower defer-emit path). The
`node = entry[1]` sibling stays `Int` (consumed as `AstNodeId`, a scalar newtype — wall-exempt). Full-suite verification
still blocked by the async-spec contention hang (§11.30 caveat); basis is fixpoint + IR-identical + the targeted
const/defer coverage.

### 11.32 typecheck-family AstStorage handle/param re-types — LANDED (2026-06-11)

**Three clean sub-fixes across the middle-end, one commit (QZ0215 49 → 43, −6).** The remaining typecheck-family fires
split into "clean handle/param re-types" (done here) and "deep `tc`-erases-to-`Int` existential" (deferred — see below):

- **`typecheck_expr_handlers.qz` ×3** — two read-site handle bridges (the §11.31 idiom). `f_ast_store = fai[0]` (the
  named-args default-fill path: `fai = tc_function_ast_info(...).unwrap()`, a positional tuple) → `ast::AstStorage`,
  clearing the `ast_get_left`/`ast_param_default_value` uses; `eb_func_store = tc.registry.func_ast_stores[eb_fidx]`
  (effect-annotation lookup) → `ast::AstStorage` with `as_int(eb_func_store) != 0` for the null guard.
- **`typecheck_generics.qz` ×1** — `tc_struct_field_annotation(tc, struct_idx, field_names_vec[i])`: the `Vec`-element
  is an interned name-handle (`Int`) into a `String` param → wrapped in `as_string(...)`, the SANCTIONED interned-name
  bridge (§11.27), IR-identical.
- **`typecheck_diag.qz` ×2** — a genuine **param** re-type (not a local): the diagnostic wrappers
  `tc_diag_error_at`/`tc_diag_warn_at` declared `s: Int` but forward to `tc_error_at`/`tc_warning_at` whose `s` is
  `ast::AstStorage`. Re-typed the param `s: ast::AstStorage` (added `import ast`; no cycle — `ast` doesn't import
  `typecheck_diag`). **No caller cascade**: the only two callers (`tc_diag_error_at` at `typecheck_expr_handlers` "no
  method"/"undefined function" diagnostics) already pass an `ast::AstStorage` (`ast_storage`); `tc_diag_warn_at` has no
  callers. `h` left `Int` (forwarded into `h: AstNodeId`, a scalar newtype — wall-exempt either direction).

**Deferred (not clean):** `typecheck_helpers ×5` / `typecheck.qz ×4` / `typecheck_registry ×5` are the harder case where
the firing argument is **`tc` itself** (`TypecheckState`) erasing to `Int` as it flows into `tc_lookup_struct`/sibling
helpers — the genuine de-existentialization of the `TypecheckState` boundary, not a read-site handle bridge. Left for
the de-existentialization pass (the N3.1 step-1 core), where `tc_expr`/param types gain real boxed types.

**Fixpoint gen1==gen2 byte-identical (2815 fns)** — `as_type`/`as_string`/`as_int` are no-op reinterprets + a param
annotation, zero IR change. cache-ro + dep-invalidation smokes green; Rule-2 smokes correct; targeted specs green
(`named_args`/`default_fields` hit the `f_ast_store` default-fill path, `generic_*` the field-name-recovery path,
`qz0200_struct_diagnostic`/`hybrid_ufcs_traits` the diag path). Full-suite still blocked by async-spec contention
(§11.30 caveat); basis is fixpoint + IR-identical + the targeted coverage.

---

### 11.33 First TUPLE-PROMOTION: `loop_stack` `Vec<Int>` tuple → `MirLoopEntry` struct — LANDED (2026-06-11)

**The clean handle-bridge vein is mined out (§11.32); the remaining 43 fires are all genuine tuple-promotions or
boundary de-existentializations. This is the first tuple-promotion — the morning-briefing item-2 class — done on the
smallest, most-contained target to prove the pattern + verification flow before scaling to `struct_defs` (~20 accessor
functions) and `PendingSpec`.**

`MirContext.loop_stack` held positional `Vec<Int>` tuples `[label, break_block, continue_block, scope_depth,
wrap_depth]`. `mir_ctx_find_loop_break`/`find_loop_continue` read `entry[1]`/`entry[2]` (a bare `Int` block-handle) and
coerced it into their `MirBlock` return slot — the two QZ0215 fires (`mir.qz:3053`, `:3068`). Promoted to a named
`struct MirLoopEntry { label: String, break_block: MirBlock, continue_block: MirBlock, scope_depth: Int, wrap_depth:
Int }` (declared beside `MirDropEntry`).

**Fully contained to `mir.qz`** — 5 internal functions (`get_loop_stack` return type, `push_loop` construction, and the
four `find_loop_*` readers, all `entry[N]` → `entry.field`), the `loop_stack: Vec` → `Vec<MirLoopEntry>` field + its
field-table doc row. **Callers unchanged by construction:** every `mir_ctx_push_loop` call site (`mir_lower_iter.qz` ×7,
`mir_lower_stmt_handlers.qz` ×2, `mir_lower.qz`) already passes typed `MirBlock` break/continue args and gets `MirBlock`
back from `find_loop_*` — the tuple was always an internal encoding.

**IR-CHANGING (struct field-access ≠ Vec index)** — so unlike §11.29–11.32 this is *not* fixpoint-trivial by
construction; the verification has to actually catch a representation bug. **Fixpoint gen1==gen2 byte-identical (2815
fns)**; Rule-2 smokes correct (`brainfuck` — loop-heavy — "4 passed", `style_demo` clean); loop-bullseye specs green
(`labeled_loops`, `loop`, `wrap_block_break_continue` — exercises the `scope_depth`/`wrap_depth` readers — and
`unwrap_in_loop`). **QZ0215 43 → 41**, the two `mir.qz` loop_stack fires cleared with zero collateral (full audit
file-diff: only `mir.qz` 5→3; the surviving 909/6029/6777 are unrelated, line-shifted by the struct insertion). Golden
`quartz-pre-loopentry-golden` saved.

**Pattern proven; next tuple-promotions (sequenced):** `struct_defs`/`struct_registry` → `MirStructDef` (8-field tuple
`[name, field_names, field_types, repr_c, packed, is_value, field_defaults, ast_store]`, ~20 reader functions across
`mir.qz` + `codegen_runtime.qz`; **verified NOT qzmod-serialized** — rebuilt per-compile from `mir_collect_structs`, so
not §11.18-class; clears the codegen_runtime + mir struct-def fires, ~7); then `PendingSpec`
(`mir_lower_expr_handlers.qz:2487/2497`) and `DeferEntry`. The harder residual stays the `tc`/`TypecheckState` and
`AstStorage`/`TcRegistry` boundary de-existentializations (the N3.1 step-1 core).

### 11.34 N3.1 step-4 — cluster-A clean sub-families: the `typecheck::TypecheckState` mis-qualifier + record-getter field re-type — LANDED (2026-06-11)

**First bite of the cluster-A "tc/TypecheckState/TcRegistry boundary" (the step-1 core). Two fully-independent,
runtime-identical type-only corrections batched into one increment; both are clean (no `as_*` entanglement, not
qzmod-serialized).**

1. **`typecheck_helpers.qz` hashable family — a genuine wrong-module-qualifier bug, not a compiler limitation.**
   `TypecheckState` is defined in `typecheck_util.qz:416`; the correct qualifier is `typecheck_util::TypecheckState`.
   Four functions (`tc_type_is_hashable`, `tc_hashable_rejection_reason`, `tc_struct_is_hashable`,
   `tc_struct_hashable_rejection`) wrote `typecheck::TypecheckState` — the *wrong* module, which the `typecheck`
   module does not define. The qualified ref failed to resolve and silently erased the `tc` param to bare `Int`
   (the N3 existential wall accepting an unresolved type as `Int` rather than erroring). Every *other* function in
   the file uses unqualified `TypecheckState` (in scope via `import typecheck_util`) and resolves correctly. The
   5 QZ0215 fires (`:702,707,719,724,725`) were `tc` flowing — Int-typed — into the boxed `TypecheckState` params
   of `tc_lookup_struct` / `tc_struct_field_names` / `tc_struct_field_types_vec`. **Fix: drop the bad qualifier →
   unqualified `TypecheckState`** (matching the file-wide convention). De-existentializes `tc` in all four bodies.
   Note: qualified `module::Type` annotations *do* work in general (`ast::AstStorage`, `mir::MirProgram`, 382 sites)
   — the bug was the qualifier naming a module that doesn't define the type, not the qualified form itself.

2. **`typecheck_util.qz` TcRegistry record getters — `Vec` → `Vec<Vec<String>>`.** `record_field_names` /
   `record_field_types` were declared bare `Vec` (handle-erased). They store real `Vec<String>` (pushed from the
   `field_names: Vec<String>` / `field_types: Vec<String>` params of `tc_register_record` /
   `tc_register_open_record` / `tc_register_record_with_ids`) and the getters
   (`tc_record_field_names` / `tc_record_field_types`) return `Vec<String>` — so indexing the bare `Vec` yielded an
   `Int` returned into a `Vec<String>` slot (the 2 fires `typecheck_registry.qz:1999,2005`). **Fix: re-type both
   fields to `Vec<Vec<String>>`** (precedent: `impl_method_names`, `forall_var_names` in the same struct).
   Runtime-identical — the stored handles were already `Vec<String>` handles; this is pure type-recovery, so
   fixpoint-trivial like §11.29-11.32. The only direct field indexers are the two getters; all other access is via
   getters / `push` / `vec_new` / `vec_free`, all compatible. **NOT qzmod-serialized** (the `_tc_emit_qzmod_*`
   path doesn't touch these fields — the morning-briefing §11.18-class caution applies to the *intersection*
   getters' `as_int`/`as_string` push side, deliberately left alone here).

**Left for follow-up increments (cluster A residue):** intersection record getters (`:2567,2578`) — entangled with
sanctioned `as_int(name)`/`as_string(...)` bridges on the `merged_rec_names`/`merged_rec_types` push side (§11.27,
do-not-touch); `tc_all_builtin_names` `builtins.keys` (`:1690`) — a `Map.keys` erasure, separate sub-family;
`tc_parse_record_fields` `[names,types]` `Vec<Int>` 2-tuple feeding `typecheck.qz:1743,1746` — a §11.33-style
tuple-promotion (or struct return).

**Verification:** `quake build` clean (2815 fns); Rule-2 smokes correct (`style_demo` renders, `brainfuck` "4
passed"); targeted specs green (`map_hashable` — exercises `tc_struct_is_hashable` via Map-key hashability,
`record_types`, `intersection_types`, `union_types`, `binary_union`, `binary_union_typecheck`); guard fixpoint
gen1==gen2 byte-identical. **QZ0215 41 → 34**, zero collateral (full audit file-diff: `typecheck_helpers.qz` 5→0,
`typecheck_registry.qz` record getters 1999/2005 cleared; every other fire line-identical). Golden
`quartz-pre-clusterA-tc-golden` saved.

### 11.35 N3.1 step-4 — TUPLE-PROMOTION: `tc_parse_record_fields` `Vec<Int>` `[names,types]` → `struct RecordFields` — LANDED (2026-06-11)

**The second tuple-promotion (after §11.33's `loop_stack`), applied to the record-annotation parser. The §11.34
follow-up target.** `tc_parse_record_fields(annotation): Vec<Int>` built two real `Vec<String>` (`names`, `types`),
then **erased both through `as_int`** into a positional `Vec<Int>` tuple `[names_handle, types_handle]`. Every
caller read `parsed[0]`/`parsed[1]` as bare `Int` and re-bridged each element with `as_string(...)`. The 4 QZ0215
fires (`typecheck.qz:1743:64/:75`, `:1746:57/:68`) were `parsed[0]`/`parsed[1]` flowing — Int-typed — into the
`Vec<String>` params of `tc_register_record` / `tc_register_open_record`.

**Promoted to `struct RecordFields { names: Vec<String>, types: Vec<String> }`** (declared in
`typecheck_registry.qz` beside the parser; structs are globally registered by simple name, so the cross-module
callers in `typecheck.qz`/`typecheck_generics.qz` see it via return-type inference — no qualifier needed). The
function now `return RecordFields { names: names, types: types }` — **the two `as_int` erasures vanish as a
consequence** (exactly like §11.33's loop_stack promotion removed positional `Int` indexing; this is NOT "fixing" a
sanctioned `as_*` bridge in place — the bridge existed *because* the encoding was `Vec<Int>`, and disappears with
the typed encoding). All 5 callers updated: `parsed[0]`/`parsed[1]` → `parsed.names`/`parsed.types`, and the now-
redundant `as_string(field_names[i])` element wrappers dropped (elements are `String` directly).

**Caller inventory (5):** `typecheck.qz:1743/1746` (the firing sites); `typecheck_generics.qz:249`
(`tc_infer_expr_type_annotation` — record field-type lookup during inference); `typecheck_registry.qz` ×3
(record-field-type resolver + the two intersection mergers). **The two intersection mergers keep their own
`Vec<Int>` accumulators** (`merged_names`/`merged_rec_names` with sanctioned `as_int(name)` pushes feeding the
intersection registry fields) — untouched; only their `var name = as_string(field_names[k])` source read became
`var name = field_names[k]` (the parsed side is now typed; the accumulator side stays the deliberate-erasure
corner, §11.27/§11.34-residue).

**IR-CHANGING** (struct field-access ≠ Vec index, like §11.33 — *not* fixpoint-trivial by construction; the
verification genuinely has to catch a representation bug). **Fixpoint gen1==gen2 byte-identical (2815 fns)**;
Rule-2 smokes correct (`brainfuck` "4 passed", `style_demo` clean); targeted specs green (`record_types`,
`intersection_types`, `union_types`, `binary_union`, plus generics field-resolution: `generic_field_access`,
`generic_payload_field_access`, `nested_generics`, `generic_struct_init`, `concrete_generic_at_annot`,
`generic_types`). **QZ0215 34 → 30**, zero collateral (audit file-diff: the 4 `typecheck.qz:1743/1746` fires gone;
the intersection getters only line-shifted `2567→2572`/`2578→2583` from the struct insertion; nothing new). Golden
`quartz-pre-recordfields-golden` saved.

**Cluster-A residue after §11.34+§11.35:** intersection record getters (`:2572,2583`) — sanctioned-`as_int`
entangled (do-not-touch); `tc_all_builtin_names` `builtins.keys` (`:1690`) — `Map.keys` erasure, separate
sub-family. The remaining 30 fires are the AstStorage accessors (cluster B, `ast.qz` ×7), `struct_defs`→
`MirStructDef` (cluster C, the big author-aware tuple-promotion), `PendingSpec`/`DeferEntry` tuples, the block-handle
sentinels (cluster D, likely sanction), and the residual macro_expand/mir_lower sites (cluster E).

### 11.36 Scoping addendum: the 30-fire residue, corrected by code-read (for the next author) — 2026-06-11

**Ground-truth corrections to the handoff's cluster map, found while scoping §11.35's follow-ups. Read before
picking up PendingSpec.**

- **`PendingSpec` is NOT a clean RecordFields-style promotion — it carries a union-encoded-as-handle wart.** The
  `pending_specs` queue (`mir.qz:284 pending_specs: Vec`, drained `mir_lower.qz:1173`, dedup-checked
  `mir.qz:4395 mir_has_pending_spec`, constructed at `mir_lower_expr_handlers.qz:1524` [6-slot] + `:2587` [4-slot])
  is a variable-arity positional tuple `[base_name, arg_types, ast_store, func_handle, (struct_name, type_param_csv)]`.
  The 2 fires (`mir_lower.qz:1218,1220`) are `ast_store`(entry[2]) → `AstStorage` param. **The blocker:** slot `[1]`
  `arg_types` is overloaded — normally a `Vec` handle (`if arg_types > 0 { vec_size(arg_types); arg_types[j] }`),
  but `mir_has_pending_spec`'s `else` branch (`mir.qz:4410-4412`) reads it as a **`String`** ("Legacy: single
  concrete_type stored as string"), discriminated by the `> 0` handle-null check. A typed struct field can't be
  both `Vec` and `String`; promoting PendingSpec requires either (a) first eliminating the legacy String-arg_types
  path (verify it's dead — `arg_types` always a real Vec at the 2 construction sites, so the `else` may be
  unreachable and deletable per D7), or (b) modeling arg_types as a real sum type. **Do (a) first** — if the legacy
  branch is dead, delete it (D7), then the 6-field struct `PendingSpec { base_name: String, arg_types: Vec,
  ast_store: AstStorage, func_handle: Int, struct_name: String, type_params: String }` is clean, with the
  `vec_size(entry)>=6` discriminator → `str_byte_len(entry.struct_name)>0` (morning-briefing item 2) and the
  `arg_types > 0` null-check → `as_int(entry.arg_types) > 0` (handle-null idiom, §11.28). The `as_int` erasures at
  both construction sites vanish into typed field assignments.

- **`ibf_call` (`mir_lower_expr_handlers.qz:2487,2497`) is a SEPARATE tuple from pending_specs — the handoff
  conflated them.** It comes from `mir_lookup_iterator_bounded(ctx, resolved_name)` (the iterator-bounded-function
  registry), shape `[?, ast_store, func_handle, ?, bounds_str]` (`[1]`=ast_store, `[2]`=func_handle, `[4]`=bounds).
  The 2 fires are `ibf_ast_store`(ibf_call[1]) → `ast_get_left`/`ast_get_str2` `AstStorage` params. Its own
  tuple-promotion (find the registry's construction + the lookup return type), independent of PendingSpec.

- **`tc_all_builtin_names` `builtins.keys` (`typecheck_registry.qz:1690`) is a `Map.keys` erasure**, not a tuple.
  `tc.builtins` is a `Map`; `.keys` yields key handles erased into the `Vec<String>` return slot. De-exist requires
  the builtins Map's key type to be tracked as `String` (a Map-key-type sub-family, distinct from every other
  residual fire) — lowest-value single fire, likely defer or fold into a broader Map-key pass.

- **Intersection record getters (`typecheck_registry.qz:2572,2583`) stay sanctioned** — the `merged_rec_names`/
  `merged_rec_types` accumulators are `Vec<Int>` with deliberate `as_int(name)` pushes (§11.27/§11.34). Cleaning
  them means re-typing the accumulators to `Vec<String>` and dropping the `as_int`/`as_string` bridges — a separate
  decision, do-not-touch per the anti-footgun rule unless that bridge family is being retired wholesale.

- **Recommended next increments, in order:** (1) PendingSpec via the dead-legacy-branch-delete path above (2 fires,
  MED); (2) ibf_call tuple (2 fires, MED); (3) cluster B AstStorage accessors (`ast.qz` ×7 — still "design the
  `children`/`extras` re-type first," the heterogeneous-element teeth are real); (4) `struct_defs`→`MirStructDef`
  (cluster C, the big author-aware ~7-fire promotion with the Boxed fixpoint-safety invariant — dedicated session).

### 11.37 N3.1 step-4 — TUPLE-PROMOTION: `pending_specs` `Vec` tuple → `struct PendingSpec` (+ dead-code delete) — LANDED (2026-06-11)

**The §11.36-item-1 target, executed via the dead-legacy-branch path.** The generic-specialization queue
(`MirGenericState.pending_specs`) was a variable-arity positional `Vec` tuple `[base_name, arg_types, ast_store,
func_handle, (struct_name, type_param_csv)]`. The 2 fires (`mir_lower.qz:1218,1220`) were `ast_store`(entry[2]),
bare `Int`, flowing into the `AstStorage` params of `mir_lower_struct_method_spec` / `mir_lower_specialized_function`.

**Step 1 — D7 dead-code delete (the §11.36 union wart, resolved by removal not modeling).** The `arg_types` slot
*looked* like a `Vec`-or-`String` union (`mir_has_pending_spec`'s `else` branch at `mir.qz:4410` read entry[1] as a
"Legacy: single concrete_type stored as string"). But `mir_has_pending_spec` had **zero callers** (verified
repo-wide) — entirely dead. Deleted the whole function (26 lines). That removed the *only* String-read of entry[1];
both live construction sites (`mir_lower_expr_handlers.qz:1524,2587`) always store a `vec_new()` Vec, so `arg_types`
is unconditionally a `Vec`. No union to model.

**Step 2 — promotion.** `struct PendingSpec { base_name: String, arg_types: Vec, ast_store: ast::AstStorage,
func_handle: Int, struct_name: String, type_params: String }`, declared **before `MirGenericState`** (Quartz
resolves struct field-type annotations in definition order — declaring it after the consumer gave
`Vec<error>`/`QZ0200`; `MirLoopEntry` only worked because its `loop_stack` consumer sits later in the file). Field
`pending_specs: Vec` → `Vec<PendingSpec>`; getter `mir_ctx_get_pending_specs` return `Vec` → `Vec<PendingSpec>`.
The arity discriminator `vec_size(entry) >= 6` → `str_byte_len(entry.struct_name) > 0` (sound: `struct_name` is
non-empty exactly at the struct-method construction site `:1524`, where it's `_mir_last_seg` of a non-empty
`struct_qual` gated by a non-empty-`tparams` check; empty `""` at the regular-generic site `:2587`). The `ast_store`
slot becomes typed `AstStorage` — clearing both fires. Construction-site bridges: `:1524` drops `as_int(entry.ast_store)`
→ `entry.ast_store` (already `AstStorage`); `:2587` uses `as_type<ast::AstStorage>(gbf_entry[1])` (sanctioned bridge,
§11.27 — `gbf_entry` is the still-erased bounded-generic registry tuple). Drain `arg_types > 0` null-check →
`as_int(arg_types) > 0` (handle-null idiom, §11.28); `arg_types` elements keep their `as_string` bridges (the
`Vec`-of-interned-string-handles stays a deliberate corner).

**`ibf_call` (`:2487,2497`) untouched** — confirmed a genuinely separate tuple (the iterator-bounded-function
registry from `mir_lookup_iterator_bounded`), its own promotion (§11.36).

**IR-CHANGING** (struct field-access ≠ Vec index; plus a dead-fn delete and a discriminator swap — *not*
fixpoint-trivial; the verification has to catch a routing/repr bug). **Fixpoint gen1==gen2 byte-identical
(2815 fns)**; Rule-2 smokes correct (`brainfuck` "4 passed", `style_demo` clean); **11-spec generics battery green**
including the struct-method spec path that exercises the new discriminator (`vec_struct_generics`,
`generic_value_struct`, `generic_extend`, `generic_struct_init`, `generic_ufcs_dispatch`, `multi_param_generic`,
`nested_generics`, `stress_generics`, `cross_generics_closures`, `map_generic`, `generic_types`). **QZ0215 30 → 28**,
zero collateral (audit diff: only `mir_lower.qz:1218/1220` cleared; all other fires pure line-shift from the struct
insert / dead-fn delete / +1-line comment). Golden `quartz-pre-pendingspec-golden` saved.

**Cluster residue now 28:** `ibf_call` (2, MED — next); `builtins.keys` Map-key (1); intersection getters (2,
sanctioned); AstStorage cluster B (`ast.qz` ×7, design-first); `struct_defs`→`MirStructDef` cluster C (~7,
author-aware); block-handle cluster D (~4, likely sanction); residual cluster E (macro_expand/mir_lower, mixed,
2 EXEMPT).

### 11.38 CORRECTION + scoping: `ibf_call` is the `generic_bounded_funcs` registry — a cluster-C-class promotion, NOT a MED 2-fire tuple — 2026-06-11

**§11.36-item-2 (and the §11.37 "ibf_call next, MED") underestimated this. Code-read correction before the next
author picks it up.** The 2 fires (`mir_lower_expr_handlers.qz:2487,2497`, `ibf_ast_store = ibf_call[1]` → the
`AstStorage` params of `ast_get_left`/`ast_get_str2`) are NOT a small standalone tuple. `ibf_call` comes from
`mir_lookup_iterator_bounded`, which returns an entry from **`MirGenericState.generic_bounded_funcs`** — the *same*
registry `gbf_entry` reads (`mir_lookup_bounded_generic`). Clearing the ibf fires *properly* means promoting that
whole registry; the alternative (an `as_type<ast::AstStorage>(ibf_call[1])` sanctioned bridge, §11.27) only
cosmetically drops the meter 2 without de-existentializing — **rejected as meter-gaming (D5)**.

**Full scope of the `generic_bounded_funcs` → `struct BoundedGenericFunc` promotion (cluster-C class):**
- **Tuple layout (7-slot):** `[name, ast_store, func_handle, type_params, bounds, mangled, iter_tag]` (`mir.qz:281`
  comment; slot 6 = iterator-bounded tag, 0/1).
- **5 construction sites** (`mir_lower.qz:5589→push 5590, 6354→6355, and the 3 at 6426/6477/6513`), each an
  `as_int`/`as_int_generic`-erased Vec literal. Note **ast_store erasure is inconsistent across sites**
  (`as_int_generic(ast_storage)` at 5589 vs bare `ast_store` at 6354) — the promotion unifies this to a typed
  `ast::AstStorage` field.
- **In-place tag mutation:** PASS 0.9.1 (`mir_lower.qz:~6360`) sets `entry[6] = 1` for iterator-bounded fns — must
  become `entry.iter_tag = 1` (struct field mutation; verify the entry is a live reference, not a copy — the
  Vec<RefStruct> copy-on-read hazard from `feedback_vec_refstruct_copy_on_read_not_qzmod.md` applies here, this is
  the #1 risk).
- **2 lookup fns return Int-sentinel** (`mir_lookup_iterator_bounded` / `mir_lookup_bounded_generic`, both
  `return entry`-or-`return 0`), consumed by ~6 `!= 0`/`== 0` call sites (`mir_lower_expr_handlers.qz:2540-2549`,
  `mir_lower.qz:5414,6449,6494,6785`). Promotion makes these `Option<BoundedGenericFunc>` (the §11.37/4g
  SENTINEL→Option pattern) OR keeps a struct-or-null with `as_int(...) != 0` bridges at call sites. **Option is the
  right model** (these are genuine "found / not found" lookups), but threads `is_some`/`unwrap` through 6 sites.
- **~5 entry-read sites:** `mir.qz:3460-3463` (iter lookup: entry[0]/[5]/[6]/.size), `mir.qz:4400-4402` (bounded
  lookup: entry[0]/[5]), `mir_lower_expr_handlers.qz:2575/2587` (gbf_entry[5]/[1]/[2] — promotion lets the §11.37
  `as_type<ast::AstStorage>(gbf_entry[1])` bridge there drop to `gbf_entry.ast_store`), `:2483/2485/2486`
  (ibf_call[4]/[1]/[2]), `mir_lower.qz:5731` (ibf_entry[4]). The `entry.size > 6 and entry[6] == 1` iter
  discriminator → `entry.iter_tag == 1`.
- **Estimate:** one dedicated increment (comparable to `struct_defs`→`MirStructDef`), clears 2 fires directly +
  removes the §11.37 `as_type` bridge; the in-place tag mutation + the 6-call-site Option threading are the teeth.
  Sequence it as its own session like cluster C; do NOT batch with other work.

### 11.39 N3.1 step-4 — REGISTRY PROMOTION: `generic_bounded_funcs` `Vec` → `struct BoundedGenericFunc` (+ SENTINEL→Option lookups) — LANDED (2026-06-11)

**The §11.38 cluster-C target, executed.** The bounded/structural/record/iterator-bounded generic registry
(`MirGenericState.generic_bounded_funcs`) was a variable-arity positional `Vec` tuple `[name, ast_store,
func_handle, type_params, bounds, mangled, iter_tag]`. The 2 fires (`mir_lower_expr_handlers.qz:2487,2497`) were
`ibf_ast_store`(ibf_call[1]) flowing — bare `Int` — into `ast_get_left`/`ast_get_str2`'s `AstStorage` params.

**Promoted to `struct BoundedGenericFunc`** (declared before `MirGenericState`; definition-order matters —
declaring it after the consumer gave `Vec<error>`/`QZ0200`). Field map from the §11.38 read-survey: `base_name`,
`ast_store: ast::AstStorage`, `func_handle: Int`, `type_params: String` (**unread** — kept for parity), `bounds:
String` (canonical; the structural/record construction sites previously pushed an unread empty `Vec<String>` here,
now push `""`), `mangled: String`, `iter_tag: Int`. Field + getter (`mir_ctx_get_generic_bounded_funcs`) re-typed
`Vec` → `Vec<BoundedGenericFunc>`.

**SENTINEL→Option (the 4g pattern).** Both `mir_lookup_iterator_bounded` and `mir_lookup_bounded_generic` returned
an Int entry-or-`0`; now `Option<BoundedGenericFunc>` (`Option::Some(entry)`/`Option::None`, matching
`mir_lookup_function`). ~8 call sites updated: existence checks `!= 0`/`== 0` → `.is_some()`/`.is_none()`
(`mir_lower.qz:5414,6446,6489,6771,6780,6783`); the two reassign+use consumers
(`mir_lower_expr_handlers.qz:2477` ibf, `:2541` gbf, `mir_lower.qz:5728` ibf) → `var e = opt.unwrap()` then
`e.bounds`/`e.ast_store`/`e.func_handle`/`e.mangled`. **The §11.37 `as_type<ast::AstStorage>(gbf_entry[1])` bridge
at the PendingSpec construction site dropped to `gbf_e.ast_store`** (typed) — the predicted cleanup.

**The `entry.iter_tag = 1` in-place tag mutation (PASS 0.9.1)** stays a direct field write on `var entry = gbf[i]`
— sound because `vec_get` returns the stored handle for non-`@value` structs (5361b984 /
[[feedback_vec_refstruct_copy_on_read_not_qzmod]]), so the write goes through the shared backing element. **Verified
correct: iterator-bounded programs compile byte-identical to golden** (below) — proving the tag is set + the
Iterator-param→closure transform applies identically.

**5 construction sites** (`mir_lower.qz:5589,6353,6422,6471,6507`) → `mir::BoundedGenericFunc { ... }` literals;
the `as_int`/`as_int_generic` erasures on every slot dropped to typed field assignments.

**IR-CHANGING.** **Fixpoint gen1==gen2 byte-identical (2815 fns)**; cache-RO qzmod + dep-invalidation smokes PASSED;
Rule-2 smokes correct. **Positive iterator-bounded validation (the iter_tag path fixpoint does NOT cover — the
compiler's own source defines no `<T: Iterator>` fn, and nothing in its import closure pulls in `std/iter`'s 20
iterator-bounded fns):** two standalone programs — `def f<T: Iterator>` consumed via `.next()` AND via `for x in
iter` — each compiled to **byte-identical IR vs the golden** and ran correct (`r=15`, `sum=45`). **QZ0215 28 → 26**,
zero collateral (only `:2487,2497` cleared; rest pure line-shift). Golden `quartz-pre-bgf-golden` saved.

**⚠️ Verification lesson (cost me ~1hr — record for the next author).** Mid-verification, iterator-bounded programs
began segfaulting (139) on the new binary while the golden compiled them — a textbook "my change regressed it"
signal. It was a **false alarm from transient memory corruption**: four leaked `quakefile qspec` launcher processes
(each ~3.8% RAM, orphaned by SIGKILL'd `quake qspec_file` runs whose specs use `assert_run` subprocess compilation —
blocked in this sandbox) had starved the machine, and the arena-allocated compiler crashed *non-deterministically*
under the pressure (Heisenbug: clean under lldb, 139 standalone, then 0×6 after `pkill -9 -f "quakefile qspec"`
freed ~13GB). **Lessons:** (1) `quake qspec_file` on subprocess-compiling specs (`bounded_dispatch`,
`structural_methods`, `iterator_protocol`, `generic_ufcs_dispatch`, `collection_iterators`, `generic_bounded_loop`,
`rpitit_bounded_generic`) leaks launchers here — `pkill -9 -f "quakefile qspec"` between runs, or avoid them. (2) A
crash that differs new-vs-golden under memory pressure is NOT proof of regression — re-test after freeing memory and
**diff the IR** (byte-identical IR = no regression, the gold standard). (3) These specs are environmentally blocked,
NOT pre-existing logic failures; validate iterator-bounded changes with **standalone compile+IR-diff vs golden**, not
qspec_file.

**Cluster residue now 26:** `builtins.keys` Map-key (1); intersection getters (2, sanctioned); AstStorage cluster B
(`ast.qz` ×7, design-first); `struct_defs`→`MirStructDef` cluster C (~7, author-aware, Boxed invariant); block-handle
cluster D (~4, likely sanction); residual cluster E (macro_expand/mir_lower, mixed, 2 EXEMPT).

### 11.40 N3.1 step-4 — REGISTRY PROMOTION: `struct_defs` `Vec` tuple → `struct MirStructDef` (+ synthetic-slot fold) — LANDED (2026-06-11)

**The cluster-C "big author-aware" target, executed.** The struct-definition registry — `MirProgram.struct_defs` and its
build-time twin `MirContext.struct_registry` — was a positional `Vec` tuple `[name, field_names, field_types, repr_c,
packed, is_value, field_defaults, ast_store]` read by ~30 sites across `mir.qz` (×~22 accessor/inline-read functions) +
`codegen_runtime.qz` (×6). The 4 fires were the two `mir_ctx_register_struct` construction sites
(`mir_lower.qz:8963,9049`, `as_int(ast_store)` → the `AstStorage` param) and the two
`mir_struct_def_has_inline_value(sentry/sbentry)` codegen reader-param sites (`codegen_runtime.qz:2139,2165`, the bare
`Int` entry into a `Vec` param).

**Promoted to `struct MirStructDef`** (declared before `MirProgram`/`MirContext` — definition-order discipline, §11.37).
`name: String`, `repr_c`/`packed`/`is_value`: `Int`, `field_defaults: Vec<Int>`, `ast_store: ast::AstStorage` (clears
both construction fires), and the element vecs `field_names`/`field_types` kept **bare `Vec`** for conservative parity —
their interned-string-handle elements keep their `as_string(field_names[j])`/`as_string(field_types[j])` bridges (the
~15 element reads were left untouched; re-typing these two fields to `Vec<String>` is a clean **zero-fire-delta**
follow-on, since the cascade flows through erased return-tuples regardless — see below). Field + getters
(`mir_get_struct_defs`, `mir_ctx_get_struct_registry`) re-typed `Vec` → `Vec<MirStructDef>`.

**Synthetic-slot fold (the variable-arity wart).** Base entries were 8-slot; `mir_synth_value_layout_struct` minted a
**9-slot** entry `[…, base_entry[7], 1]` whose 9th slot is the B.10 §12.9 generic-over-@value inline-value marker,
discriminated everywhere by `vec_size(entry) >= 9` (`mir_struct_has_inline_value`, `mir_struct_def_has_inline_value`).
A real struct can't be variable-arity, so the marker became an **always-present `inline_value: Int` field** (default 0;
synth sets 1) and the `vec_size(entry) >= 9` discriminator collapsed to a direct `entry.inline_value` read — the
§11.37-class discriminator swap, here trivialized to a plain field. `mir_struct_def_has_inline_value` shrank to
`def …(entry: MirStructDef): Int = entry.inline_value`.

**SENTINEL→Option.** `mir_synth_value_layout_struct`'s `base_entry = 0` Int-sentinel (set from the registry, null-checked
`if base_entry == 0`) → `Option<MirStructDef>` (`Option::Some(registry[ri2])` / `.is_none()` / `.unwrap()`) — the §11.39
4g pattern. Both construction sites (`mir_ctx_register_struct`, `mir_synth_value_layout_struct`) build `mir::MirStructDef
{ … }` literals; every `as_int`/`as_string` slot-erasure dropped to a typed field assignment. The
`mir_ctx_get_struct_fields`/`mir_ctx_get_struct_defaults` getters keep returning their **erased `[entry.field_names,
entry.field_types]` / `[defaults, ast_store]` 2-tuples** (deliberate corner — a separate erased tuple, not struct_defs;
see cascade note). The two non-struct registries that happen to share the loop-variable name `entry`
(`spec_param_types` `mir.qz:3285`, `struct_types` `:3978`) were verified untouched.

**IR-CHANGING** (struct field-access ≠ Vec index; codegen-critical — every emitted `%struct.Name` type def, the
@value/@repr(C)/narrow-field layout decisions, the inline-value spec aggregates, and the per-struct `qz_hash_/qz_eq_`
all read this registry). **Guard fixpoint gen1==gen2 byte-identical (2815 fns)**; cache-RO qzmod + warm-cache
dep-invalidation smokes PASSED; Rule-2 smokes correct (`brainfuck` byte-identical IR golden-vs-new, `style_demo`
renders). **Positive IR-diff validation of the `inline_value` synth path that fixpoint does NOT cover** (the compiler's
own source registers no generic-over-@value specialization, so gen1==gen2 never mints an `inline_value == 1` entry): a
standalone `Box<@value Point>` program compiled **byte-identical vs the golden**, emitting the correct
`%struct.Box$Point = type { %struct.Point }` inline aggregate — exercising `mir_struct_def_has_inline_value` +
`cg_struct_def_is_value` + `cg_emit_value_struct_type`, the exact converted codegen path. Plain-struct + @repr(C) probes
also byte-identical. **QZ0215 26 → 22**, zero collateral (the four `:8963/:9049/:2139/:2165` fires cleared;
`codegen_runtime.qz` dropped off the fire list entirely; remaining 22 = ast.qz ×7 + typecheck_registry ×3 +
macro_expand ×3 + mir_lower ×3 + mir_lower_expr_handlers ×3 + mir.qz ×3, all line-shift-only). Golden
`quartz-pre-mirstructdef-golden` saved.

**Two holes filed (D6):**
1. **`mir_ctx_get_struct_fields` field_types-element cascade (`mir.qz:963` — still firing).** `type_needs_drop(ctx, ft)`
   gets `ft` from `struct_info.unwrap()[1]` where `struct_info = mir_ctx_get_struct_fields(...)` returns
   `Option<Vec<Int>>` wrapping the erased `[field_names, field_types]` 2-tuple. The field_types **element** is therefore
   Int-erased *regardless* of the `MirStructDef.field_types` field type — so this fire does NOT clear from the registry
   promotion; it needs `mir_ctx_get_struct_fields` itself promoted to return a typed pair (a `struct StructFields {
   field_names: Vec, field_types: Vec }` or similar). Clean ~2-fire follow-on. The `Vec<String>` re-type of
   `field_names`/`field_types` (above) pairs naturally with it.
2. **Pre-existing @value-byval-return compiler crash on minimal standalone programs (NOT this change).** A standalone
   `def mk(a, b): Point` returning a bare `@value struct` (with `main`) **segfaults the compiler (139) deterministically
   on the pristine `quartz-pre-mirstructdef-golden` exactly as on the new binary** — proven pre-existing, independent of
   the promotion. Surfaced while building the struct IR-diff probe. Real programs with full runtime (`brainfuck`,
   `style_demo`) and the self-build are unaffected; likely tied to the `@__qz_gen_yield_capture` runtime-global elision
   in the minimal-program harness. Filed for a dedicated chase; does not block cluster C.

**Cluster residue now 22:** `builtins.keys` Map-key (1); intersection getters (2, sanctioned); AstStorage cluster B
(`ast.qz` ×7, design-first — now the largest single bucket and the natural next dedicated session); macro_expand cluster
E (3); block-handle/ast_store sites in mir_lower + mir_lower_expr_handlers (6, mostly sanctionable nullable-ambient
block handles); `mir.qz` ×3 (the `mir_ctx_get_struct_fields` cascade #1 above + `mir_create_block`/`mir_is_in_list`
block/list sentinels).

### 11.41 N3.1 step-4 — CLUSTER B: AstStorage existential-Vec accessors → sanctioned `as_vec` read — LANDED (2026-06-12)

**The "design-first" cluster B, executed — and the handoff's "return-type-annotation tightening" framing corrected.**
The 7 `ast.qz` accessors that read a nested-`Vec` handle out of an SoA column — `ast_get_children`/`ast_get_payloads`/
`ast_get_map_values` (from `children: Vec<Int>`), `ast_get_bound_names`/`ast_get_map_keys`/
`ast_get_struct_init_field_names`/`ast_import_get_aliases` (from `extras: Vec<Int>`) — each had body `s.<col>[h]`
declared `: Vec`. The column element is a bare `Int` (an erased nested-`Vec` handle), so the body resolved to
`TYPE_INT` returned into a forbidden-boxed `Vec` slot → QZ0215.

**The annotation-tightening hypothesis was tested and FALSIFIED.** Changing `: Vec` → `: Vec<Int>` does NOT clear the
fire: `tc_nil_forbidden_type` (`typecheck_helpers.qz:619`, `t >= PTYPE_BASE`) forbids *parameterized* `Vec<T>` too —
it just renders as `unknown` in the message instead of `Vec`. (Proof: the pre-existing `ast_import_get_aliases:
Vec<Int>` was firing all along as one of the "`unknown` return" fires.) The fire keys off the **body** type being
`TYPE_INT`, not the annotation. So clearing it requires the body to be non-`Int`-typed.

**Decision — sanctioned `as_vec` bridge, NOT `Option<Vec>` and NOT column de-existentialization.** Per-accessor
analysis against the §11.28 doctrine ("you earn `Option` when *many* callers branch on absence; otherwise the
boundary-checked nullable handle is the deliberate corner"):
- `ast_get_children` has **303 callers, ~0 branching on absence** — every one immediately `.size`/`[i]`s a valid vec.
  It does not earn `Option`; converting it would be a 303-site cascade for zero safety gain.
- The columns `children`/`extras` are **uniform `Vec<Int>` SoA columns that polymorphically hold `Vec<T>` handles of
  varying element type** (`Vec<Int>` for bound_names, `Vec<String>` for struct-init field names — confirmed: the parser
  builds the latter with `vec_new<String>()`, and `tc_struct_init` reads them via `as_string` while pushing raw
  `String`s). They are *genuinely existential* — no single static element type exists — so column re-typing
  (`Vec<Vec<Int>>`) is both impossible (heterogeneous) and broad. The `0` handle is the column's own absence encoding
  (`ast_is_check` stores `extras = 0` for a binding-less `x is Some`; callers check `> 0`/`!= 0` at the boundary) — the
  §11.28 deliberate-corner shape, not an Option candidate.

So the doctrine-correct read is `as_vec(s.<col>[h])` — `as_vec` is purpose-built ("recover a `Vec<T>` from a raw `Int`
handle", `typecheck_builtins.qz:842`) and is a `tc_n3_is_bridge_name` sanctioned conversion. Wrapping the **body only**
(return type stays `: Vec`) makes `ret_val_ty == TYPE_VEC ≠ TYPE_INT` → fire clears, with **zero caller impact** (all
300+/18/7 call sites untouched — they already consumed the bare-`Vec` return).

**IR cost — one fold-away `add i64 _, 0` per accessor.** `as_vec` lowers via `_cg_emit_identity_conversion`
(`cg_intrinsic_core.qz:18`) to `%vN = add i64 %arg, 0` — the same idiom `vec_get` itself already emits, instcombined
away at `-O`. **NOT byte-identical vs the prior golden** (7 extra add-zeros in the compiled compiler), but **fixpoint
gen1==gen2 byte-identical (2815 fns)** — both generations emit the add identically, the gold standard for a
self-consistent change. Cache-RO qzmod + warm-cache dep-invalidation smokes PASSED; Rule-2 smokes ran
(`brainfuck` + `style_demo` execute correctly). **QZ0215 22 → 15**, exactly the 7 cluster-B fires (6 `Vec`-named + the
1 `unknown`-named `ast_import_get_aliases`); zero collateral. Golden `quartz-pre-clusterB-golden` saved.

**Cluster residue now 15:** `builtins.keys` Map-key (1); intersection getters (2, sanctioned); macro_expand cluster E
(3); block-handle/ast_store sites in mir_lower + mir_lower_expr_handlers (6, mostly sanctionable nullable-ambient block
handles); `mir.qz` ×3 (the `mir_ctx_get_struct_fields` field_types-element cascade #1 from §11.40 + `mir_create_block`/
`mir_is_in_list` block/list sentinels). The clean low-cascade vein is now mined out below the registry/tuple tier; the
residual 15 are GATED (typecheck_registry → qzmod), EXEMPT (intersection getters, cluster-E), or the `mir.qz` SENTINEL
trio.

### 11.42 N3.1 step-4 — the mir.qz SENTINEL trio (all 3 cleared) — LANDED (2026-06-12)

**The handoff's named next focus, executed as one cohesive `mir.qz` increment.** Three orthogonal fires, three
mechanisms:

**Fire 1 — `mir_ctx_get_struct_fields` field_types-element cascade (`mir.qz:985`, hole #1 from §11.40).** `type_needs_drop`
read `field_types = struct_info.unwrap()[1]` off the erased `Option<Vec<Int>>` 2-tuple, then `any?(field_types, ft: Int
-> type_needs_drop(ctx, ft))` — the `ft: Int` into `type_name: String` fired. **De-existentialized the return shape:**
promoted `mir_ctx_get_struct_fields` from `Option<Vec<Int>>` (positional `[field_names, field_types]` erased tuple) →
`Option<StructFields>` (new typed 2-field struct), the §11.39/§11.40 registry-promotion class. The 5 tuple consumers
(`type_needs_drop`, `emit_nested_drops` in mir.qz; `_mir_struct_value_field_layout`, `_mir_struct_uniform_value_slot_count`,
the struct-alloc path in mir_lower.qz) swapped `.unwrap()[0]`/`[1]` → `.unwrap().sd_names`/`.sd_types`, dropping their now-
redundant `as_string()` element bridges. The `MirStructDef` writers already supply `Vec<String>`, so `StructFields`'
columns are `Vec<String>` (bare-`Vec` `entry.field_names` assigns cleanly) and `ft` becomes `String` — fire clears at the
source, not via a bridge. The 25-site `MirStructDef.field_names/.field_types → Vec<String>` re-type stays the filed
follow-on (zero-fire-delta; the element reads off the bare `MirStructDef` fields keep their `as_string` bridges
untouched).

**⚠ Compiler bug discovered + worked around — QZ-FIELDNAME-COLLISION (filed, see Holes).** First cut named the struct's
fields `field_names`/`field_types` — and the new binary **segfaulted nondeterministically** (heap-corruption signature:
crashes scaled with compilation volume, masked under lldb, 0/30 on a minimal struct but 10/10 on `style_demo`).
Root-caused via emitted IR: a field access on a **generic `Option::unwrap()` result** resolves the field offset through a
**global field-name→offset table**, not the static type. `field_types` is "owned" by `MirStructDef` at **index 2**
(name@0, field_names@1, field_types@2); `StructFields` placed it at index 1. So `unwrap().field_types` emitted
`getelementptr i64 2`, read past the 16-byte struct, and faulted on the garbage pointer. Construction was correct (explicit
`StructFields {}` literal knows the type → stored at offset 1) — **write@1, read@2.** Minimal repro:
`Big{…field_types@2}` declared before `SF{…field_types@1}`, `Option<SF>::unwrap().field_types` → 139 deterministically.
**Workaround:** named the fields `sd_names`/`sd_types` (globally unique → resolver picks the right offset; verified
`getelementptr i64 1`). The resolver bug is the real fix and is filed.

**Fire 2 — `mir_emit_label` → `mir_create_block` (`mir.qz:6080`, dead code).** `mir_emit_label(ctx, label: Int)` passed
its `Int` into `mir_create_block(ctx, label: String)` (interpolation-tolerant). The function had **zero callers** — D7
delete. Removed it plus its two equally-dead "Short-circuit helper" siblings `mir_emit_phi` and `mir_fresh_label` (also
0-caller). `mir_create_block` now has no Int-passing caller (all sites pass String literals / the String `resume_label`).

**Fire 3 — `mir_is_in_list(name, captures)` (`mir.qz:6828`, capture-list existential).** `mir_collect_captures_walk`'s
`captures: Int` (a raw `Vec`-handle holding `as_int(name)`-erased interned name strings) flowed into
`mir_is_in_list(name, names: Vec<String>)`. **De-existentialized:** `captures: Int → Vec<String>` (uniform interned-string
column, NOT heterogeneous like the §11.41 AstStorage columns, so de-exist over bridge), `vec_push(captures, as_int(name))`
→ `captures.push(name)`, `mir_collect_captures` return `Int → Vec<String>` + `vec_new<String>()`, and the 4 `as_string`
element reads across the 2 consumers (`mir_lower.qz` go-spawn, `mir_lower_expr_handlers.qz` lambda lowering ×3) dropped.
`params: Int` left erased (it feeds the Int-based `scope`/`mir_cap_scope_*` worklist — a deliberate flat-Int structure).

**Validation.** Guard fixpoint **gen1==gen2 byte-identical (2815 fns)**; cache-RO qzmod + warm-cache dep-invalidation
smokes PASSED. Rule-2 smokes: `style_demo` (the reliable crash repro — **0/10 compile crashes** post-fix, runs 64 lines),
`brainfuck`, and full self-source `--no-opt` **3/3 exit 0**. IR confirms the corrected `.sd_types` offset (`i64 1`) and the
add-zero removals (dropped `as_int`/`as_string` bridges) — fixpoint-stable, not byte-identical vs prior golden. **QZ0215
15 → 12**, exactly the 3 `mir.qz` fires; QZ0214 unchanged (9). Golden `quartz-pre-structfields-golden` saved.

**Cluster residue now 12:** `builtins.keys` Map-key (1); intersection getters (2, sanctioned); macro_expand cluster E (3);
block-handle/ast_store sites in mir_lower + mir_lower_expr_handlers (6, mostly sanctionable nullable-ambient block
handles). The `mir.qz` SENTINEL trio is fully cleared. The remaining 12 are all GATED (typecheck_registry → qzmod),
EXEMPT (intersection getters, cluster-E), or the 6 sanctionable block-handle sites.

**Holes filed (D6):**
1. **QZ-FIELDNAME-COLLISION (compiler bug, real fix).** Field-offset resolution for a field access on a **type-erased
   generic result** (`Option::unwrap()`, and presumably any generic `T` return) uses a **global field-name→offset table**
   instead of the static struct type, so two structs sharing a field name at different offsets miscompile — silently, with
   a heap-corruption crash signature. Worked around in §11.42 via unique field names. The real fix: thread the concrete
   struct type through monomorphized generic returns so field access resolves against the actual type. Minimal repro in
   commit message. Affects the whole language, not just B.15 — should be prioritized independently. **Filed as ROADMAP
   A.45** (renumbered from a mis-filed "A.23"). Root-caused 2026-06-12: `mir_subst_return_type_for_call` (mir.qz) can't
   type a bare-`T` generic return (`unwrap(): T`) — it skips substitution when ret_type has no `<`, and only unifies
   params annotated exactly `T` (not the wrapped `Option<T>`/extend-method self). A fallback ambiguity-guard was
   attempted and RULED OUT by measurement (over-fires 32× on the compiler's own forced-Int corner — can't tell
   ambiguous-wrong from ambiguous-consistent without the lost receiver type); the fix must restore the receiver type, not
   guard the fallback. **Until fixed, any new struct whose fields are read via a generic accessor MUST use field names not
   shared with another struct, or share the exact offset.**
2. **`MirStructDef.field_names/.field_types → Vec<String>` re-type (zero-fire-delta, ~25 sites).** Still filed from §11.40;
   drops the `as_string` element bridges on the ~25 direct `MirStructDef` readers across mir.qz/mir_lower.qz/
   codegen_runtime.qz. Independent of the §11.42 return-shape promotion (which already clears the only fire). Mechanical
   but IR-critical (codegen layout reads); each `as_string(field_types[j])` site must be confirmed to source from the
   re-typed field (vs a same-named param/enum_variant_field_types).

### 11.43 A.45 — generic-return inference for bare-`T` returns (the real fix, piece i) — LANDED (2026-06-12)

The §11.42 hole #1 (ROADMAP A.45) is fixed. Root cause confirmed empirically first: the minimal repro
(`struct Big{name; field_names; field_types}` before `struct SF{field_names; field_types}`;
`Option<SF>::unwrap().field_types`) emitted `getelementptr i64 2` against a 16-byte `SF` and read `0` instead of
`22` — a silent wrong value (it faults only when the bad offset walks off a larger allocation). The receiver type
was erased because `o.unwrap()` resolves to the **extend method** `prelude$Option$unwrap` (`def unwrap(): T` on
`extend Option`, `std/prelude.qz:345`): its return is the bare param `T`, its OWN type params (ops slot) are empty
(`T` lives on the enum decl), and it declares zero params (self implicit) — so `mir_subst_return_type_for_call`
bailed at its very first guard and recorded `s`'s type as `T`, which the field-access lowering couldn't resolve →
`mir_find_field_globally` first-match → Big's offset 2.

**The fix (two edits, `mir.qz` + `mir_lower.qz`):**
1. `mir_collect_enums` (`mir_lower.qz`) now registers each enum's declared type params under its bare name via
   `mir_set_struct_type_params` — structs already did this (§A.36); enums didn't, so `mir_get_struct_type_params("Option")`
   returned `""`. Now it returns `<T>`.
2. `mir_subst_return_type_for_call` (`mir.qz`) intercepts a `<`-free return type BEFORE the original generic path
   and routes it to new `mir_bind_bare_param_return`: infer the UFCS receiver's tracked type (`call_args[0]`); if it's
   a concrete generic instance (`Option<SF>`), align the receiver base's declared params (`mir_struct_type_param_names`
   → `[T]`) with its type args (`mir_type_args_of` → `[SF]`) and, when `ret_type` IS one of those param names, return
   the matching concrete (`SF`). Concrete returns (`Int`/`Void`) and unbindable params fall through verbatim.

**Why this shape and not the broad one.** First attempt was a general two-source unifier (structural
`unify(Option<T>, Option<SF>)` over declared params + an always-on receiver-base binding). It fixed the repro but
broke `newtype_spec` and over-fired on the bounded-generic/iterator/record monomorphization that relies on the
existing return-type behavior, and an early version SEGV'd the compiler on `vec_size(0)` for zero-param generics
(`ast_get_left` returns raw `0`, not an `as_vec`-wrapped empty). Discarded. The landed fix keeps the entire
`<`-bearing path **byte-identical** to the original — the only behavioral change is that a `<`-free return now
attempts receiver-binding — so the blast radius is exactly "bare-param return on a concrete generic receiver."

**Validation (rigorous, golden-vs-fixed diff).** Built a 32-spec golden baseline (the "7 pre-existing" figure in the
morning briefing below is stale — current baseline is 32, dominated by the still-incomplete bounded-generic/iterator/
value/tui families). Full qspec on the fix adds **zero** specs beyond baseline: the only specs that ever differed
(`wasm_set_int_keys`, `resolver_go_arg_module_var`, `tcp_acceptable`) produce **byte-identical IR** on golden vs fixed
(`diff -q` clean) and fail as flaky *runtime* SIGSEGVs / network timeouts under suite contention — provably not caused
by a compiler-output change. Repro → `22`; `Result<T,E>` two-param → `99`; style_demo/brainfuck smoke clean; guard
fixpoint PASSED (2816 fns).

**Remaining (filed in ROADMAP A.45):** (ii) the forced-`Int` corner (`ResolverEntry.ast_store` — the 32 sites that
tripped the ruled-out guard; latent, resolve correctly via first-match). (iii) ✅ DONE (`89443acd`) — reverted the
§11.42 `sd_names`/`sd_types` workaround back to natural `field_names`/`field_types`, recreating the exact collision
with `MirStructDef.field_types`@2. This is the real-world acceptance test for piece (i): the compiler self-compiles
guard-clean (fixpoint, 2816 fns) with the collision live, and a nested-`Drop` program (which drives
`type_needs_drop → Option<StructFields>::unwrap().field_types`) prints the correct field + drop order. End-to-end
confirmation that the fix solves the original §11.42 bug, not just the synthetic repro.

---

### 11.44 N3.1 step-4 — the exemption registry + the flip design (2026-06-12, follow-on session)

**Meter at this section: QZ0214 = 0, QZ0215 = 3** (from 9 / 12). The session that wrote the HANDOFF below
corrected its own A.45(ii) conflation (§commit `8e827760`) and then executed the author-chosen "flip + exemptions"
path. Commits: `45b0a44a` (QZ0214 9→6: dead `domtree_idom` delete + `mir_prog_find_function`→`Option`),
`3b1765b6` (the **sanctioned-handle exemption registry**: QZ0214 6→0, QZ0215 12→7), `12e0d811` (erased-column
conversions: QZ0215 7→3).

**The exemption registry (LANDED, `3b1765b6`).** `tc_n3_is_sanctioned_handle_type(tc, t)` (`typecheck_helpers.qz`)
returns true for the compiler's IR/arena **handle structs** whose ZERO is a *structural* sentinel, not a value-niche
collision: `mir$MirBlock` (control-flow block; 0 = unset branch target / labeled-loop miss / no-resume) and
`ast$AstStorage` (AST arena handle; the `compiler_types`↔`ast` cycle's i64 transport). Consulted at the TOP of
`tc_nil_forbidden_type` — whose **entire blast radius is the QZ0213/4/5 wall** (verified: no other caller) — so the
audit AND the post-flip coercion both see it. Keyed on the registry-**mangled** nominal name (`mir$MirBlock` /
`ast$AstStorage` — note the `$`; the bare-name first cut matched nothing). Rationale: the boxed-pointer None-niche
flip is about boxed VALUE types where 0 collides with a payload; an IR control-flow / arena handle has no payload, so
0 stays a legal structural sentinel (the Kotlin platform-type / CPtr-null analog at the IR boundary).

**The 3 remaining QZ0215** are all `typecheck_registry.qz`: the intersection record-field/-type getters
(`2572`/`2583`, returning `Vec<String>` off the untyped `intersection_record_fields`/`_types: Vec` columns) and
`builtins.keys` (`1690`). These need the `Vec<Vec<String>>` column re-type — but `merged_rec_names`/`merged_rec_types`
(`typecheck_registry.qz:2375+`) are themselves `as_int(name)`/`as_string([m])` existential, so the merge logic must be
de-existentialized first. This is the morning-briefing item 3 "TcRegistry `Vec<Vec<String>>` cascade (HIGH,
serialized, never unattended)" — a dedicated next increment, NOT a sanction (these are genuine erased columns).

**THE FLIP — mechanism decided, staging defined, awaiting author go/no-go.**

*Mechanism: warn→error at the audit, NOT narrowing `tc_is_i64_type`.* The HANDOFF below proposed "narrow
`tc_is_i64_type` so bare Int ↛ {Struct,Enum} errors." **RULED OUT by inspection:** `tc_is_i64_type` is the blanket
existential-compatibility predicate inside `tc_types_match` (`typecheck.qz:1987-1988` — `if i64(t1) and i64(t2):
return true`), load-bearing for FFI (`Int`↔`CInt`/`CChar`/`CSize`/`CPtr`), newtype matching, and every i64-handle
coercion. Narrowing it would reject legitimate `Int`↔`CInt` and existential `Struct`↔`Struct` matches compiler-wide —
unacceptable blast radius, and orthogonal to the wall. The QZ0213/4/5 audit already pinpoints exactly the
bare-Int/nil→boxed positions (let-binding, return, call-arg), gated on `tc_nil_forbidden_type` which now carries all
exemptions. **The flip = upgrade those audit `warn()`s to `error()`s.** Zero FFI blast radius; reuses the exemption
gate; detection is already exactly right (it drove the meter to 0/3).

*Staging (Dart/Kotlin/C# leaf-first):*
- **Phase 1 (LIVE):** always-on warning. `tc_n3_wall_warn_enabled() = true`.
- **Phase 2 (DONE this session):** drain. QZ0214 → 0, QZ0215 → 3.
- **Phase 3a — flip QZ0214 → error. ✅ LANDED (`8af63a95`).** `tc_n3_wall_error_enabled()` + `tc_n3_wall_is_error(tc)`
  (flip-on AND `str_contains(current_file, "self-hosted/")`); the 3 QZ0214 audit sites `error()` when in scope, else
  `warn()`. Because QZ0214 = 0 in compiler modules, zero build effect — a pure *ratchet*: no new literal-`0`→boxed
  sentinel (`return 0` / `f(0)` into a heap slot — the most dangerous existential pattern) can be introduced in a
  compiler module. **Validated RED→GREEN:** `return 0` from a struct-returning fn `error`s (exit 1) under
  `self-hosted/`, `warn`s (exit 0) under `/tmp`. Guard PASSED (fixpoint 2819 fns); std/qspec/examples stay on the
  warning (leaf-first). To widen scope later, relax `tc_n3_wall_is_error` (e.g. drop the `self-hosted/` clause once
  std + user surfaces drain).
- **Phase 3b — flip QZ0215 → error. ✅ LANDED.** Drove QZ0215 3 → 0, then flipped warn→error at all 3 audit sites
  (let / return / call-arg in `typecheck_walk.qz` + `typecheck_expr_handlers.qz`), reusing the same
  `tc_n3_wall_is_error(tc)` gate as QZ0214 (error in `self-hosted/`, warn elsewhere). Pure ratchet — count is 0 in
  compiler modules, zero build effect. **Validated RED→GREEN:** an `Int`-var returned into a struct slot `error`s
  (exit 1) under `self-hosted/`, `warn`s (exit 0) under `/tmp`. Guard PASSED (fixpoint 2820 fns). The drive to 0 took
  two pieces — see §11.45.
- **Phase 4 — co-land the boxed-pointer None niche (N3):** with the wall enforced, `0` is reserved as the None niche
  over boxed types (zero-cost `Option<T>` — the payoff).

*Scope:* compiler modules; `std/`+`shared/` stay warn-exempt (`tc_n3_file_exempt`, ~97% effect-ABI transport).
Exemptions in place: sanctioned handles (`MirBlock`/`AstStorage`), the 5 `as_*` bridges, `std/`+`shared/`.

*Completeness caveat (FILED — gates niche soundness):* warn→error enforces the wall at the 3 AUDITED positions
(let/return/call-arg — the dominant coercion surface) but NOT structurally at every `Int`→boxed coercion (struct-field
init, array-element literals). For the niche to be fully SOUND a follow-on must either (a) extend audit coverage to
the remaining positions, or (b) add a **position-scoped** narrowed-coercion predicate used ONLY at assignment
positions (never the global `tc_is_i64_type`). Phase 3a/3b close the common cases and flush remaining sentinels;
structural completeness is the niche's gating prerequisite, tracked here.

---

### 11.45 Phase 3b execution — registry cascade + a paren-elision miscompile uncovered (2026-06-12, follow-on session)

**Meter: QZ0215 3 → 0, then flipped to error.** Two pieces drove the 3 to 0; the second was a genuine compiler bug
the wall audit surfaced, not a wall sanction.

**Piece 1 — TcRegistry `Vec<Vec<String>>` cascade (QZ0215 3 → 1).** The two intersection record getters
(`tc_intersection_record_field_names`/`_field_types`, `typecheck_registry.qz:2566/2577`) returned `[idx]` off the
untyped `intersection_record_fields`/`_types: Vec` columns → element read typed `Int` → coerced into the `Vec<String>`
return → QZ0215. De-existentialized end-to-end: re-typed both columns `Vec` → `Vec<Vec<String>>`
(`typecheck_util.qz:324-325`), init `vec_new<Vec<String>>()` (`typecheck.qz:203-204`), and de-existentialized the
merge builder (`merged_rec_names`/`merged_rec_types`, `typecheck_registry.qz:2375+`): `vec_new<String>()` + push
`name`/`type_str` directly (dropped the `as_int` writes) + read directly (dropped the `as_string` reads at the
dedup/conflict-check and canonical-sig build). Getters now return `Vec<String>` with no coercion — the briefing's
"never-unattended HIGH serialized" item, landed cleanly.

**Piece 2 — paren-elision mistyped builtin-container methods (QZ0215 1 → 0; a real miscompile).** The last fire was
`tc_all_builtin_names` `return builtins.keys` (`typecheck_registry.qz:1690`). Root cause is NOT a wall sentinel:
**paren-less `recv.method` on a builtin receiver was typed `TYPE_INT`.** `m.keys()` and `map_keys(m)` resolve to
`Vec<String>` (they enter `tc_expr_call`'s container UFCS dispatch), but the paren-elided `m.keys` is a bare
`NODE_FIELD_ACCESS` whose B.6 elision (`tc_expr_field_access`) only tried *free-function* UFCS — it never recognized
builtin container methods, so `b6_can_elide` stayed 0 and it fell to the lenient `result = TYPE_INT` / QZ0603 offset-0
sink. **This is a broad latent miscompile**, not Map-specific: paren-less `s.upcase`, `n.to_s`, `sb.to_string`,
`set.members` etc. all mistyped as `Int` and *segfaulted at runtime* (verified `s.upcase` paren-less: rc=139 before,
`HELLO` rc=0 after). Fix: extracted the per-container `match func_name {…}` canonical-intrinsic tables (11 receiver
types: String/Vec/Slice/Map/StringBuilder/Set/Range/Int/F64/TaskGroup/Channel) out of `tc_expr_call`'s inline dispatch
into one shared `tc_container_ufcs_canonical(base_type, method): String` (single source of truth, D7), wired both
`tc_expr_call` (the paren-ful path) and the B.6 non-struct branch (the paren-less gate) to it. Paren-less now elides
iff the method is a recognized builtin method → `recv.m` ≡ `recv.m()` (the B.6 spec intent). Unrecognized methods keep
the lenient QZ0603 path (no regression: paren-ful `m.bogus()` already errored QZ0401, but widening the paren-less form
to error too was out of scope — gated on recognition).

**Verification.** Cold meter QZ0215 0 / QZ0214 0. Guard PASSED (fixpoint 2820 fns). Smoke (style_demo, brainfuck) green;
paren-less scalar/container methods now compile + run. Full qspec main lane: only 2 ✗ (`import_enum_variant_construction`,
`global_var`) — **both pre-existing**, proven by byte-identical IR + identical exit-1 from the pre-session golden
binary. 2 snapshot ✗ (hello, fibonacci) likewise pre-existing (golden-identical IR; snapshots stale since 2026-03-18).

**Filed (D6):** the 2 stale IR snapshots (`spec/snapshots/{hello,fibonacci}.ll`) drifted from ~3 months of unrelated
IR evolution — independent of this work; refresh separately once verified against current fixpoint-clean IR.

---

### 11.46 Phase 4 — the boxed-pointer `None` niche LANDED (B.15d / N3.2 complete, 2026-06-13)

**The payoff. With the bare-`Int` wall enforced (§11.44 Phase 3a/3b), `0` is reserved as the `None` niche over boxed
types — so `Option<T>` is now zero-cost (single word: `None` = null pointer `0`, `Some(p)` = the pointer `p` itself; no
tag word, no heap box). This is the §6 dependency inversion realized and the `MEMORY_MODEL_V3.md §14.5 N3` capstone.**

**Niched payload classes (zero-cost `Option<T>`):**
- non-`@value` user structs;
- builtins **String, Vec, Map, Set, IntMap, Regex, Future, Function/closure** (all confirmed single non-null heap
  pointers; closures keep their `env|1` low-bit tag through the niche).

**Still TAGGED (deliberate deferrals):**
- **Tuple** — DEFERRED (the `(...)`/`Tuple<...>` name-form type-tracking robustness is not yet there; low value).
- **payload-bearing enums** — DEFERRED (overlaps the separate enum-niche workstream; `use_stack` alloca lifetime; the
  QZ0212 erased-boundary risk).

**Permanent carve-outs (never niche, soundness):** `Option<Int>`/`Bool`/narrow-int scalars (every bit pattern incl. `0`
is a valid value), `Option<CPtr>` (FFI null is a legitimate value — §5, "Never niche `CPtr`"), `@value` structs (inline
aggregate, no null inhabitant), the sanctioned IR/arena handles `MirBlock`/`AstStorage` (`0` is a legal *structural*
sentinel — §11.44).

**The structural-completeness wall (the soundness precondition, landed this track).** The bare-`Int` wall is now a HARD
ERROR in compiler modules at all **five** construction positions — let-init, return, call-arg, **struct-field-init,
array-element** (the two §11.44 "completeness caveat" gaps closed) — so no bare `Int`/`nil` can leak into a boxed slot,
making `0` an unambiguous `None` tag. Gate: `tc_n3_wall_structural_is_error` mirrors `tc_n3_wall_is_error`.

**Implementation (`self-hosted/backend/mir.qz`).** Master flag `mir_boxed_niche_enabled() = 1`; per-class gates
(struct / clean-builtins / String / Function); `mir_payload_is_boxed_classify` is the single boxedness classifier; the
niche bridge is `mir_option_is_niche`/`mir_option_none_const`; reads route through
`mir_get_enum_tag_subj`/`mir_subject_is_niche_option`.

**Verification.** Fixpoint gen1==gen2 at ~2839 functions; full `quake guard` (incl. `cache_smoke`) green; full native
qspec **835/843**, the only failures being the pre-existing `@value`-narrow-byval family + `niche_spec` — **all fail
identically against the pre-niche golden ⇒ zero new regressions.**

**Open follow-up holes (filed 2026-06-13 — low impact; reads correct in every case):**
1. **`Map<K, Option<V>>` value-position bare-`None` spills to a tagged box** — the `map_set` intrinsic seam carries the
   KEY type, not the value type. READS work; `Vec`/`Set` are fully covered. Low impact (missed alloc-elision, not a bug).
2. **Un-annotated `var f = option_some(closure); f.unwrap()(...)` is not callable** — the `Fn` payload type isn't
   propagated into `unwrap`'s return type (needs an `Option<Fn(...)>` annotation). **Pre-existing TYPECHECK inference
   gap, representation-independent** (same on the pre-niche golden), not a niche bug.
3. **Niche-typed `var x = Some(v); x = None; read(x)` reads back `Some`** — a var-init-vs-first-reassignment
   store-ordering issue. **Pre-existing, representation-independent.**
4. **`@value` structs with narrow-int fields (U8/I8/I16/I32) returned by value segfault the compiler** — NOT from this
   work; the pre-existing `niche_spec` + `value_struct_*` baseline failures (fails identically on the pre-niche golden).

**The N3/B.15d one-way door is now fully through.** B.15a–c (the `nil`-literal wall) + N3.1 (de-existentialization +
the bare-`Int` wall) + N3.2 (this section, the boxed-pointer niche) are all landed. The only remaining B.10/Phase-4
work is the separately-gated default-`struct`-layout flip (`MEMORY_MODEL_V3.md §6 Phase 4`), which is a different axis
(§11.2 D-N3.1: value-layout structs are inline, not heap pointers, so the boxed-pointer niche doesn't apply to them).

---

## ▶▶ HANDOFF — remaining de-existentialization work (2026-06-12) — ⚠ SUPERSEDED by §11.46

**Historical. Item 4 ("the boxed-pointer niche co-land") LANDED 2026-06-13 (§11.46); items 1–3 were the de-ex work
that fed it. Kept for the record.** It superseded the older MORNING BRIEFING below (that briefing's "7 pre-existing
failing specs" and "616 fires" numbers are stale).

### ⚠ CORRECTION (2026-06-12, follow-on session) — the QZ0214 fires are NOT A.45(ii)

The "A.45 piece (ii) — the forced-`Int` corner" item below **conflated two unrelated things**, verified by
direct inspection of all 9 sites:

- **The 9 QZ0214 fires** (`mir.qz:1437,3146,3159`; `domtree.qz:347,352`; `mir_lower_expr_handlers.qz:2751,2763`;
  `qzmod_load.qz:996,999`) are **null-object struct *returns* / null-block *args*** — `return 0` where the declared
  return is a heap struct (`MirFunc`/`MirBlock`), and `0`/`-1` passed as a `mir::MirBlock` arg. They have **nothing
  to do** with `ResolverEntry.ast_store` or the `compiler_types`↔`ast` module cycle.
- **A.45(ii) proper** (ROADMAP line 38) is the **`.ast_store ×22` field-*read* global-fallback corner** — field
  accesses (`entry.ast_store`, `.kind`, …) through generic-erased receivers that `mir_find_field_globally` resolves
  by first-match-by-name. Those are the 32 sites that tripped the ruled-out §11.42 ambiguity guard. **Latent**
  (resolve correctly today via first-match); the real fix is breaking the module cycle **or** the architectural
  typecheck-annotates-exprs change. This is a separate, heavier, author-facing item — see ROADMAP A.45(ii).

**Progress this session (commit `45b0a44a`, guard-clean, fixpoint 2816 fns):** burned the 9 QZ0214 fires down to
**6** with two clean removals — neither needed the module-cycle decision:
- `domtree_idom` (`domtree.qz`) was **DEAD** (0 callers; only out-of-file `idom` ref is a direct `dt.idom[i]`
  field access). D7 delete → 2 fires.
- `mir_prog_find_function` (`mir.qz`) `return 0` null-object → `Option<MirFunc>` (the 4g pattern); 3 callers
  rethreaded `!= 0` → `is_some()`/`unwrap()`. → 1 fire.

**The remaining 6 QZ0214 are the genuine sanction class** (do NOT hand-convert — §11.22 reframe): the two
`mir_ctx_find_loop_break`/`_continue` returns feed `break_target`/`continue_target` *nullable-ambient block-handle*
locals (`var x = 0; if x == 0 → ambient fallback`); the two `mir_lower_expr_handlers.qz` async-suspend sites pass a
null `resume_target: MirBlock`; the two `_fixup_block_ref` sites are the N3-gated on-disk block-ref encoding (`-1`/`0`
= unset, matches `mir_new_block`'s default branch targets). All six want the **flip's exemption mechanism**
(`tc_n3_*` predicates in `typecheck_helpers.qz`), the same gate the QZ0215 12 need.

**Net meter at `45b0a44a`: QZ0214 = 6, QZ0215 = 12.** The two axes are now both "sanctions + flip-forced sentinels
only" — the mechanical vein is fully mined on both. Next real move is a design decision, not more burn-down: either
A.45(ii)-proper (the `.ast_store` corner / typecheck-annotation rework) or the staged warn→error flip + its
exemption registry. See ROADMAP A.45 + items 1–4 below.

---

### Where the meter stands (measured cold, 2026-06-12 at HEAD `8a2b69be`)

Cold full self-compile (`./self-hosted/bin/quartz --no-cache -I self-hosted/frontend -I self-hosted/middle -I
self-hosted/backend -I self-hosted/shared -I std -I tools self-hosted/quartz.qz 2>&1 | grep -c QZ0215`):

- **QZ0215 = 12** (Int→boxed-Struct/Enum sentinel) — down from 9,635 at the start of N3.1 step-4 (−99.88%).
- **QZ0214 = 9** (the sibling bare-Int audit) — ⚠ **now 6 at `45b0a44a`** (see CORRECTION above); these are
  null-object sentinel returns, NOT the forced-`Int` corner the prose below claims.

> ⚠️ `quake build` (incremental) reports **0** because cached modules don't recompile and so don't re-emit the
> audit. ALWAYS measure with `--no-cache` on `self-hosted/quartz.qz`, not via `quake build`.

### The 12 QZ0215 sites (exact, with classification)

| # | site | class | action |
|---|------|-------|--------|
| 1–3 | `mir_lower_expr_handlers.qz:4804,4834,4843` | select-fairness **block handles** (nullable-ambient `dispatch_block`/`tried` locals) | SANCTION (deliberate corner, like `cancel_token`) — zero IR |
| 4–6 | `mir_lower.qz:3544,7743,8621` | default-value / block-handle / ast_store nullable-ambient | SANCTION or thread the concrete handle type |
| 7–9 | `macro_expand.qz:712,789,1609` | **cluster E** — `_macro_ast_store[idx]` etc. existential-`Vec<AstStorage>` reads | `as_vec` sanctioned read (same shape as §11.41 cluster B) |
| 10 | `typecheck_registry.qz:1690` | `builtins.keys` Map-key family | SANCTION (Map-key is Int by ABI) |
| 11–12 | `typecheck_registry.qz:2572,2583` | intersection **record getters** (`intersection_record_fields[idx]`) | SANCTION (already flagged sanctioned in §11.42) |

**None of these are mechanical re-types left undone.** Per the §11.22 strategic reframe: the meter has bottomed
out: every remaining fire is either a *deliberate sanction* (nullable-ambient handle / Map-key / record getter)
or a *genuine sentinel* that only the flip should force. So "drive the 12 to 0 by hand" is the WRONG framing.

### The actual remaining arc (in priority order)

1. **A.45 piece (ii) — the forced-`Int` corner (the one genuinely-open compiler issue).** `ResolverEntry.ast_store`
   et al. are typed `Int` because `compiler_types.qz` cannot `import ast` (module cycle), so the typechecker can't
   give them a struct type. These are the **9 QZ0214 fires** (`mir.qz:1437,3146,3159`; `domtree.qz:347,352`;
   `mir_lower_expr_handlers.qz:2751,2763`; `qzmod_load.qz:996,999`). They resolve correctly today via first-match,
   so they are **latent, not active bugs** — but they are exactly what made the §11.42 ambiguity-guard impossible
   (the guard couldn't tell them from real collisions). Two paths: (a) break the cycle so `compiler_types` can name
   `ast::AstStorage` / `AstNodeId`; (b) a sanctioned exemption registered in the audit (the `cancel_token` precedent).
   **Highest-impact remaining item** because it's the last thing keeping the global-name-fallback footgun reachable
   for non-`Option`/`Result` accessors. Architecturally cleanest long-term: the typechecker annotates each expr node
   with its resolved type and MIR reads it, instead of `mir_infer_expr_type` re-deriving (a parallel, fallback-laden
   reimplementation — the root enabler of the whole A.45 class).

2. **The staged flip (warn → error) — the forcing function.** Phase 1 (always-on QZ0215/QZ0214 *warning*) is LIVE
   (§11.23, `tc_n3_wall_warn_enabled()`). The plan (ratified, Dart/Kotlin staged-nullable playbook): narrow
   `tc_is_i64_type` so bare `Int ↛ {Struct,Enum}` becomes a hard **error**, scoped compiler-modules-first, WITH the
   forced-`Int` positional-tuple + sanctioned-handle exemptions in place. The flip then surfaces each genuine
   sentinel as a compile error to convert to `Option<T>` case-by-case. **Do (1) first** — the exemptions must exist
   before the flip or it errors on the 9+ legitimate corners. After the flip, sanction the 12 above (each becomes an
   explicit `@sanctioned`/exemption or an `Option<T>` conversion) and the meter genuinely hits 0.

3. **`MirStructDef.field_names/.field_types → Vec<String>` re-type (zero-fire cleanup, ~25 sites).** Filed since
   §11.40. Drops the `as_string(field_types[j])` element bridges on ~25 direct `MirStructDef` readers across
   mir.qz/mir_lower.qz/codegen_runtime.qz. IR-critical (codegen layout reads) — confirm each `as_string` site sources
   from the re-typed field, not a same-named param/enum_variant_field_types. Independent of everything above; safe
   filler work. **Now unblocked**: A.45(i) means you no longer have to avoid natural field names to dodge collisions.

4. **The real goal beyond the meter — B.15 boxed-pointer niche co-land (N3).** De-existentialization exists to make
   the boxed-pointer `None` niche sound (see B15 row in ROADMAP + `MEMORY_MODEL_V3.md §14.6`): because `nil`=`0`
   collides with the would-be `None` niche over boxed types, the flip (forbid `nil`/bare-Int in non-`Option` slots)
   must co-land WITH the niche. The flip (item 2) is the gate; the niche is the payoff (zero-cost `Option<T>`).

### How to work this safely (lessons from the A.45 session)

- **Measure, don't assume.** Build a golden-binary baseline and `diff` failure sets — qspec's current baseline is
  **~32 failing specs** (bounded-generic/iterator/value/tui families, mostly pre-existing segfaults), NOT 7. Many
  "new failures" are flaky concurrency/network specs whose **compiled IR is byte-identical** to golden; verify with
  `diff -q` on the `.ll` before believing a regression.
- **`mir_subst_return_type_for_call` / `mir_infer_expr_type` are SEGV-prone** (raw `ast_get_left` returns `0` for
  zero-param funcs → `vec_size(0)` faults; `ast_get_children` is `as_vec`-wrapped but `ast_get_left` is not). Guard
  every handle deref. Keep changes surgical — the broad two-source unifier over-fired across the whole
  bounded-generic/iterator/record path; the narrow receiver-scoped version added zero regressions.
- **Save a fix-specific golden before touching `self-hosted/*.qz`** (`backups/quartz-pre-<fix>-golden`); the rolling
  `quartz-golden` is overwritten every guard run. Smoke-test non-self programs after guard (a self-consistent broken
  compiler passes fixpoint).

### Concrete next action (recommendation)

Start with **A.45 (ii) the forced-`Int` corner** — it's the highest-impact open item and a prerequisite for the
flip. Decide (a) layering fix vs (b) sanctioned exemption with the author; (b) is cheaper and has precedent
(`cancel_token`), (a) is the architecturally-correct one-way-door. Then design the flip (item 2). The 12 QZ0215
sanctions (item 1-classification above) and the `MirStructDef` re-type (item 3) are good low-risk filler between
the heavier design decisions.

---

## MORNING BRIEFING (for the author)

**Night result: 9 commits, QZ0215 5733 → 616 (−89.3%), every commit guard-clean (fixpoint + cache-ro), failure
set always the 7 pre-existing `@value`/segfault specs.**

| commit | step | what | QZ0215 |
|---|---|---|---|
| 39674af2 | 4c-1 | newtypes classify by wrapped type (Int-handles exempt) | 5733→910 |
| f85fb844 | 4c-2 | `ResolverEntry` handle fields → `AstStore`/`AstNodeId` | →709 (Struct 381→180) |
| 408eefc8 | 4c-3 | derive.qz `s` params → `ast::AstStorage` + reframe | →(Struct→162) |
| 8152daf5 | 4d | **staged-flip Phase 1**: always-on wall WARNING via `tc_n3_wall_warn_enabled()` | 691 |
| e1199461 | 4e | backend handle re-types (domtree/mir_const/codegen_c/codegen_separate/async_reg) | 691→665 |
| c3ee0caf | 4f | frontend/middle handle re-types (parser/macro_expand/typecheck_util/typecheck) | 665→652 |
| 8433fc13 | 4f+ | derive `clone_function` + §11.24 | 652→640 |
| (4g) | 4g | **`cg_find_function` → `Option<MirFunc>`** (first SENTINEL→Option) | 640→616 |

**The mechanical HANDLE vein is mined out.** Remaining ~616 fires need DECISIONS or are EXEMPT, not annotation.
Prioritized attended worklist:

1. **`CodegenState` `current_prog`/`current_block`/`current_func` (~27 fires) — AUTHOR DECISION.** Same
   nullable-ambient-handle shape as `cg_find_function`. Two options: (a) `Option<T>` fields (sound, IR-changing,
   ~27 fires, needs `is_some`/unwrap threading like 4g), or (b) sanction as nullable-ambient-handles (the
   `cancel_token` corner precedent — zero IR, a `tc`-level exemption). Recommend (b): these are "the current X,
   may be unset" ambient state, exactly the deliberate-corner pattern; cheaper and avoids Option spills on the
   per-instruction-emission path. Your call.
2. **Tuple promotions (struct-ify positional `Vec<Int>` tuples):** `PendingSpec` queue
   (`mir_lower_expr_handlers.qz:1524/2587` → drained `mir_lower.qz:1173`; arity discriminator
   `vec_size>=6` → `str_byte_len(struct_name)>0`); `prog.struct_defs` positional reads (~59 fires, mir.qz);
   `DeferEntry`; resolver `ast_cache_result`. Each is one self-contained struct-promotion increment (MED).
3. **`TcRegistry` `Vec<Vec<String>>` cascade (HIGH, serialized).** Correction to §11.21: `field_types` elements
   are interned name-STRINGS, not `TypeId`s; the real de-exist is the record/intersection field getters on
   `TcRegistry` (`typecheck_util.qz:324-325,349-350`), read by `tc_emit_qzmod_modules` → §11.18-class. Cache-ro
   smoke is the catch-net; one focused increment, never unattended.
4. **qzmod block-ref format** (`_mir_pickle_block_ref`/`_fixup_block_ref`, `0`/`-1` on-disk sentinels) — gated
   under N3 (the boxed-pointer niche makes `None==0` the on-disk encoding). Sanctioned until then.
5. **Phase-3 flip exemption policy (when the meter is low enough):** the flip excludes `std/`+`shared/` and
   categorically exempts the effect-handler existential ABI + any `as_int`/`as_string`/`as_vec`/`as_type`/
   `as_int_generic` bridge arg. Stdlib is ~97% sanctioned (cluster-E analysis) — that exemption clears most of it
   without touching stdlib source.

**Holes filed (D6):**
- **`try` drops its payload type — ✅ RESOLVED 2026-06-11 (§11.26).** Fix landed in `tc_expr_try`
  (`typecheck_expr_handlers.qz` regular-unwrap `else`): reads `tc_ptype_arg1` of the inner ptype instead of
  hard-coding `TYPE_INT`. **QZ0215 616 → 558**; all 16 `persistent_worker_protocol.qz` sites (58 emissions) cleared,
  zero collateral (the total drop equals exactly the persistent_worker contribution). Fixpoint gen1==gen2 clean.
  Spec coverage added (`spec/qspec/try_keyword_spec.qz`, function-return struct-payload cases). Original analysis
  below for the record:
  `tc_expr_try`'s regular-unwrap `else` branch (`typecheck_expr_handlers.qz:786`) computes `tc_expr(expr)` then
  **discards it and hard-codes `result = TYPE_INT`**. So `var v = try parsed` binds `v: Int` not the payload —
  source of the 16 `persistent_worker_protocol.qz:223/257` fires (`json_is_object(v)`/`json_object_get(v,…)`).
  **Self-contained (NOT blocked on Result-payload de-exist):** `json_parse(): Result<JsonValue,ParseError>` keeps
  a real ptype (`typecheck.qz:1681`), and `typecheck_match.qz:707` already extracts the payload — `try` just never
  reads it back. **Fix:** capture `inner_t = tc_expr(expr)`; if it's a ptype with base `TYPE_OPTION`/`TYPE_RESULT`,
  return `tc_ptype_arg1(tc, inner_t)`; else keep the `TYPE_INT` fallback (the genuinely-erased bare-scalar corner,
  matching `typecheck_match.qz:656-665`). MIR unaffected (`mir_lower_try` extracts payload structurally). **Risk
  MED but no-op on the tested surface** — all existing `try` specs use Int payloads → hit the unchanged fallback;
  the change only ADDS correctness for struct payloads. **Prereq (TDD invariant): add a struct-payload case to
  `spec/qspec/try_keyword_spec.qz` first** (currently zero non-Int `try`-payload coverage). Then guard + full
  qspec; watch `std/iter.qz`'s ~11 `try` sites for any struct element type. ~13 result-consuming `try` sites total.
  Good early-morning increment (self-compile exercises it since persistent_worker_protocol.qz is a compiler source).
- **`c_spec` fails under `--no-cache`** (`@qz_main` undefined in emitted IR) on golden AND current — a
  pre-existing cache-mode codegen quirk (the suite passes it via `--cache-ro`). Not a B.15 issue; filing so it's
  not misattributed. Repro: `quartz --no-cache … spec/qspec/c_spec.qz | llc` → `use of undefined value '@qz_main'`.
- **NEW (filed 2026-06-11, §11.26): inline `Result::Ok(struct)` / `Option::Some(struct)` constructions don't
  record a payload ptype.** Discovered while building the `try`-payload red→green repro: `var p = try Result::Ok(TryPoint{…})`
  still binds `p : Int` even after the §11.26 fix, because the inline construction's inferred type is a bare
  `TYPE_RESULT`/`TYPE_OPTION` with no recorded type args (so `tc_expr_try`'s ptype branch correctly falls through to
  the Int sentinel). The §11.26 fix only reads back an *existing* ptype; making inline `Ok`/`Some` carry their
  payload type args is a **separate constructor-inference fix** (the inferencer must parameterize the constructed
  Result/Option from its argument's type). Lower urgency: the real-world consumers (`json_parse`-style annotated
  returns) already carry ptypes and are fixed; inline-constructed try operands are rare and runtime-correct anyway
  (structural MIR lowering). Repro: `/tmp/try_probe.qz` (inline form → 4 QZ0215) vs `/tmp/try_fn.qz` (function-return
  form → 0). NOTE: QZ0215 only *fires* for boxed-struct params (e.g. `JsonValue`); small register-class structs like
  a 2-`Int` `TryPoint` never trip the audit even when mistyped — which is why a minimal synthetic repro must use a
  boxed payload + a boxed-param consumer to go red.

Full per-site analysis: `/tmp/night_plan_{A..E}.md` (5 parallel agents, 495 sites classified).

---

## 12. References

- Hoare, "Null References: The Billion Dollar Mistake" (QCon 2009) — the canonical framing.
- Rust: `Option`, `NonNull`/`NonZero`, the null-pointer optimization (guaranteed layout) — doc.rust-lang.org `std::option`,
  `std::ptr::NonNull`.
- Swift: `Optional`, force-unwrap, the implicitly-unwrapped-optional sunset — docs.swift.org.
- Zig: optionals `?T`, `orelse` — ziglang.org `Optionals`.
- Dart sound null safety migration — dart.dev/null-safety, dart.dev/null-safety/migration-guide (leaf-first ordering;
  mixed-version unsound interop; `dart migrate`).
- C# nullable reference types — learn.microsoft.com/dotnet/csharp/nullable-references; devblogs.microsoft.com "Nullable Reference
  Types in C#" (`#nullable enable`, warnings-not-errors rationale, "start at the center").
- Kotlin null safety + platform types — kotlinlang.org/docs/null-safety.html, /docs/java-interop.html (platform types `T!`,
  boundary null-checks).
- Quartz internal: `MEMORY_MODEL_V3.md §3.4, §14.5, §14.6`; `docs/design/nil.md` (the prior permissive model); `niche.qz`;
  niche commits `6c722d48` (N1) / `e0f366a3` + `ba9996b9` + `35fa1ad6` (N2).
