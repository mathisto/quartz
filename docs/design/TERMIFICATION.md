# R2.1 Termification — Locked Design

**Status:** LOCKED design (owner defaults ratifiable/vetoable, non-blocking). This is the single canonical reference an implementer reads before touching code for R2.1.
**Date:** 2026-07-04
**Roadmap:** `docs/ROADMAP.md` R2.1 — "the longest-stalled item" on the Road-to-Real epic. Phase 0 (type-level algebra) DONE; the value half is the subject of this doc.
**Sources synthesized:** the three research reports in `docs/sagas/r2-termification-2026-07-04-research/` (`current-state.md`, `external-design.md`, `surface-coupling.md`) plus the saga plan `docs/sagas/r2-termification-2026-07-04.md`.

---

## 1. Summary — the core insight

**A structural union is an anonymous, structurally-typed, auto-widening enum.**

Termification does not build three new runtime type kinds. It **reroutes** the existing structural types (`TYPE_UNION`=50, `TYPE_INTERSECTION`=51, `TYPE_RECORD`=52) through machinery Quartz already ships:

- **enum-tag lowering** — `{i32 tag, [N x i8] payload}`, `N = max(sizeof arm)`
- **the niche pass** — drops the tag word when a spare bit pattern exists (`Option<&T>` is pointer-sized)
- **value-struct decomposition / COW** — small (≤16B) decomposes and register-passes, `>16B` COW-buffers
- **flow-narrowing** — recovers Option/Result/enum payloads from `box+offset` (`if x is Ok` → read `box+8`)

The three types map onto that machinery as follows:

| Type | Termified as | Reuses |
|---|---|---|
| **Union** `A \| B \| C` | anonymous auto-widening enum; `{tag, payload}`; tag = hash(arm type-id) | enum lowering + niche + value-struct + flow-narrow |
| **Record** `{x:Int, y:Int}` | flat-offset structural struct, **no runtime name→offset map** | value-struct layout/COW; nominal-struct field-offset codegen |
| **Intersection** `A & B` | typecheck-only **bound**; the ONE constructible case is record & record → row-merge to a single `TYPE_RECORD` | record machinery (the constructible case) |

The type-level algebra (parse, register, subtype, row-variables) is **already DONE** (`current-state.md` §1–§4). What is entirely **ABSENT** is the value half: no runtime representation, no construction, no destructuring, no narrowing, no cross-module serialization. A union value today is erased to its bare underlying scalar — the compiler literally cannot tell `Int` from `String` inside an `Int | String`. A record value is faked by monomorphizing the function to whatever nominal struct was passed.

**Done looks like:** construct a union value, store/pass/return it, narrow it back to a member with the value intact; structural records exist as standalone values (not just monomorphized params); record-intersection merges to a constructible record; it all survives incremental/cross-module compilation.

---

## 2. Locked design decisions

### 2.1 Union runtime representation

`union U = A | B | C` lowers to the **same MIR/LLVM shape as a synthetic enum** `enum { _A(A), _B(B), _C(C) }`:

```
%U = { i32 tag, [N x i8] payload }   ; N = max(sizeof arm_i), tag before payload, natural align
```

- **Small (≤16B total):** field-decomposed, register-passed — **reuse value-struct rules** (`external-design.md` §6a).
- **`>16B`:** COW-buffered — **reuse value-struct COW**.
- **Tag value = `hash(structural_arm_type_id)`** (OCaml poly-variant trick, `external-design.md` §1c). Hashing the arm type-id — not a dense 0..k per-union index — means widening-site codegen never depends on a globally-consistent arm ordering agreed across every coercion site. The union's type registration stores the `hash → arm_type` map for narrowing.
- **Niche inherited free:** the existing Option/Result niche pass fires unchanged. `String | Nil`, `&T | Nil`, `NonZeroInt | Nil` drop the tag word and stay payload-sized. **No new niche code** — this is the single most important payoff of routing through enum lowering (`external-design.md` §1d, §6a).

Rejected alternative: **erase-to-Object / universal boxed header** (Ceylon's JVM trick). Not available — Quartz has no universal boxed header on scalars, so it would box every `Int` (`external-design.md` §1a).

### 2.2 Record runtime representation

A record term is **a struct with structural (row-based) typing and zero-cost flat field-offset layout** — *not* a runtime name→offset map (`external-design.md` §4, §6d).

- Fields in a canonical (sorted-by-name) order, each at a fixed byte offset. **Field access = fixed-offset load** — matches OCaml records and Quartz's existing nominal structs, so it inherits value-layout decomposition/COW.
- Width/depth subtyping is a **compile-time** assignability check; the reader only ever accesses fields it statically knows.
- Adopt **Leijen scoped labels** (duplicate labels allowed, no `lacks` predicate) to keep the typechecker simple — the row-variable machinery is already registered (`current-state.md` §2, `typecheck_util.qz:564-572`; row unification `typecheck_util.qz:2782`).

This **replaces** today's monomorphize-to-nominal-struct fake at `mir_lower.qz:7622-7649`.

### 2.3 Intersection

`A & B` is a **typecheck-only bound** for nominal/trait/mixed arms — no distinct runtime value. The value is stored as whatever concrete type it actually is; the intersection is only a static obligation (`external-design.md` §5, `surface-coupling.md` Decision 3).

The **one constructible case is record & record**: `{a:Int} & {b:Int} == {a:Int, b:Int}` (row-merge; conflicting-label types → hard error, TS's `never`). This merge **already happens at registration** and returns a real `TYPE_RECORD` id (`typecheck_registry.qz:2581-2607`); the job is proving it produces a constructible record term end-to-end. No intersection value ever carries a tag or a box.

### 2.4 Machinery reuse map (cite before reinventing)

| Concern | Existing machinery | Location |
|---|---|---|
| Tagged `{tag,payload}` layout | enum lowering | (enum codegen; same shape §2.1) |
| Tag drop on spare bit pattern | niche pass (Option/Result) | codegen niche pass — fires unchanged on union shape |
| ≤16B decompose / >16B COW | value-struct rules | value-layout decomposition/COW |
| Payload recovery from `box+offset` | flow-narrowing | `if x is Ok` → `box+8` (Option/Result/enum) |
| Union registration + member split | `tc_register_union` / `tc_union_members` | `typecheck_registry.qz:2130-2152`, `:2724/:2737` |
| Record registration + interning | `tc_register_record` (+ open, +ids) | `typecheck_registry.qz:2266-2292`, `:2298`, `:2322` |
| Row-variable unification (open/closed width) | `tc_rv_unify_records` | `typecheck_util.qz:2782` (fresh via `tc_rv_fresh`; func-scoped `tc_func_row_var_bind` `:2730`) |
| Record & record merge → record id | `tc_register_intersection` | `typecheck_registry.qz:2525-2607` |
| Union subtyping (both directions) | `tc_is_subtype` | `typecheck.qz:2341-2360` |
| Intersection subtyping | `tc_is_subtype` | `typecheck.qz:2363-2382` |
| Match exhaustiveness (arm enumeration) | union-member pseudo-ctors | `typecheck_match.qz:843-849` |
| LUB/GLB of branches/arms | `tc_type_join` / `tc_type_meet` | `typecheck.qz:2393`, `:2477` |

---

## 3. The widening problem (the core lowering challenge)

This is the crux of the whole feature. In TS/Flow a value of type `A` **is** a value of `A | B` with no ceremony — assignment, return, argument passing silently widen, because JS values are self-describing (every value carries `typeof`/prototype). A *tagged* runtime rep makes that widening **not free**: it is an actual **tag-and-box operation** that must be inserted at the exact point a value of arm type `A` crosses into a `U`-typed slot.

**Quartz's chosen middle path:** *implicit* like TS at the surface (subtyping-driven, no wrap ceremony — no `|` ever in value position), but *compiled* like Rust underneath (a real tag write). The typechecker's assignability check is the bridge — it is the single oracle that decides where an invisible `Some`-equivalent tag write is inserted (`external-design.md` §2).

### 3.1 Where widening is inserted

The typechecker already computes assignability (`is A assignable to T?`) at every coercion site (`tc_is_subtype` `typecheck.qz:2326`). A widening is required precisely when **source type = one arm (a proper subtype of the union) AND target type = the union**. The sites, all already visited by the typechecker:

| Coercion site | Example | Widen when |
|---|---|---|
| `let`/`var` with declared type | `x: A\|B = a` | RHS is arm `A`, decl is `A\|B` |
| assignment | `x = a` where `x: A\|B` | RHS arm, LHS union |
| `return` | `def f(): A\|B ... return a` | returned arm, decl return union |
| argument pass | `f(a)` where `f(p: A\|B)` | arg arm, param union |
| field / element store | `rec.u = a`, `vec.push(a)` where slot is `A\|B` | stored arm, slot union |
| union → wider union | `y: A\|B\|C = x` where `x: A\|B` | re-tag / already-tagged passthrough |

### 3.2 What "widen" emits at MIR

Add a **coercion-insertion pass** (or extend the existing type-directed coercion machinery — Quartz already inserts value/box coercions) so that whenever assignability succeeds via *arm-of-union widening*, a `mir_widen_to_union(value, hash(arm_id), U)` node is threaded in. It lowers to:

- allocate/materialize the union's `{tag, payload}` cell,
- `store tag = hash(arm_type_id)`,
- `store payload = value` — memcpy for `>16B` per COW rules, or field-decompose into the payload slots for small.

**Niche-eligible arms → no-op / trivial bit write.** Widening a `&T` into `&T | Nil` is the identity — the same as constructing `Some(ref)` today. The existing niche pass makes the widen degenerate to nothing.

This mirrors exactly where Rust/Ceylon insert their tag writes; TS's freedom to skip it is *only* because JS is dynamically tagged already. What changes concretely: union annotations are today explicitly **SKIPPED** in MIR (`mir_lower.qz:6894`, gated by `mir_is_union_annotation` at `mir.qz:3653`); that erasure is what termification undoes.

### 3.3 Record layout-changing subtyping — the same coercion, for records

Width/depth subtyping over records is a compile-time check, but it has one real hazard: with flat offsets, the offset of a field can depend on the sizes of earlier fields (`external-design.md` §4, "offset-stability subtlety"). If `{x,y,z}` is passed where `{x,y}` is expected and the shared prefix does not land at identical offsets, the read is wrong.

**Resolution (recommended):** reader-side accessor keyed on the *static* record type — the reader computes offsets from the type it is accessing through. Where the physical value's layout is **not** offset-compatible for the accessed fields (interleaved widening), insert a **reprojecting copy** at the subtyping coercion site that reprojects the wide record into the narrow record's exact layout. This is the record analogue of §3.2 union widening: **subtyping that changes physical layout materializes a copy; subtyping that preserves it is free.** The common case (monomorphic access, prefix-compatible subtyping) stays zero-cost.

---

## 4. Narrowing

Narrowing **reuses the existing flow-narrowing infra verbatim** (`external-design.md` §3, `surface-coupling.md` Decision 2c). Where TS narrows by reading structure the runtime already carries, Quartz narrows by *proving the tag then reading `payload` at the arm's offset* — byte-for-byte the same MIR shape Quartz already emits when `if x is Ok` recovers `box+8`.

### 4.1 The mechanism

Extend flow-narrowing with `narrow_union_arm(binding, arm_type)` that:

1. **resolves `arm_type` structurally** to an arm-id within the binding's union type (the new work — structural, not nominal, resolution),
2. inserts the **tag-equality guard** (`tag == hash(arm)`),
3. marks the binding as the arm type **in-branch**,
4. makes payload reads lower to `payload@offset` / niche-read / (later) discriminant-field-read.

Surface forms that drive it — all already locked, **no new surface**:

- `if x is Int` — arm is a primitive/nominal type; prove tag, read payload as that arm.
- `match x { Int => …, String => … }` — arm dispatch; each arm proves its tag.
- predicate methods (`.some?`, `.ok?`) already do exactly this for Option/Result — extend to structural arm predicates.

### 4.2 Exhaustiveness

Reuse enum match exhaustiveness over the arm set, with `never`-style exhaustiveness on the remaining arms (`default: const _:never = x`). Match already enumerates union members as pseudo-constructors for completeness (`typecheck_match.qz:843-849`) — that is completeness checking today; narrowing adds the payload binding it currently lacks.

### 4.3 The destructure-before-check pitfall — already dodged

TS loses refinement if you destructure a discriminated union before checking the discriminant. Quartz's narrowing is **binding-keyed** (it already handles `if Some(v) = x`), so the same rule is already enforced: narrow the binding, then read. No new machinery needed to avoid the pitfall.

### 4.4 Discriminant-field-as-tag (stretch, D2)

When *all* arms are records sharing a literal-typed field (`kind`), the union can use that field's value directly as the tag — a second flavor of niche optimization, no separate tag word. Makes record-arm unions as cheap as hand-rolled tagged structs. This is a **follow-on optimization** (stretch item D2), not required for the core narrowing to work.

---

## 5. Surface & one-way doors

**Under the recommended defaults, R2.1 introduces ZERO new public surface syntax.** It reuses already-locked forms: existing type-level `|`/`&`/`{}` annotations, type-directed construction (SURF.1), existing `match`/`is`/flow-narrow destructuring. Because it locks no new surface, **there is no new one-way door in this saga** (`surface-coupling.md` summary; saga "Owner Decisions").

### 5.1 The locked defaults

1. **Union construction = ceremony-free / type-directed.** TS-style: produce a member, the compiler inserts the tag from the target type. **No value-level `|`.** `x: T1 | T2 = <member>`. This is the *only* construction model that never places `|` in value-expression position, and therefore the only one that cannot contradict **SURF.13** (`&`/`|` bitwise-only at the value level). Rejected: explicit wrap-call (verbose); value-level `x | String` (**contradicts SURF.13** — must be flagged, never shipped). (`surface-coupling.md` Decision 2a.)

2. **Record construction = type-directed, no new sigil.** A record value comes from the *expected type* — a nominal struct literal `Point{x:1,y:2}`, or bidirectional inference where an anonymous record type is expected. **Bare `{k:v}` stays a Map** per SURF.1. SURF.1 already pre-committed to exactly this: "Anonymous structural records, if ever needed, come from the expected type (type-directed, TS-style) — no new sigil" (`SURFACE_SYNTAX_RATIONALE.md:136`). A dedicated bare `{x:1}` record term is *byte-identical* to a Map literal and is therefore unavailable. Documented fallback only if a genuinely anonymous record value proves necessary: a keyword-prefixed `[Type]{body}` form inside the locked bracket grammar — **never a new sigil** (a new sigil violates SURF.1). (`surface-coupling.md` Decision 1.)

3. **Intersection = constraint-only + record-merge; no `&`-value operator.** A value that satisfies all conjuncts is accepted where the intersection is expected — pure typechecker behavior, invisible surface. Any record-merge operation routes through the already-locked spread `...` family, never a `&`-value operator (which would collide with SURF.12/13's bitwise-only `&`). (`surface-coupling.md` Decision 3.)

### 5.2 SURF.1 reconciliation (records vs. maps)

SURF.1 (LOCKED 2026-06-17) assigns bare `{k: v}` to **Map** and makes structs/records **nominal** (`Point{x:3}`). The unified rule is `[Type]{body}`: colons ⇒ keyed (map, or struct if a struct type prefixes). R2.1's records-are-type-directed default is fully inside that rule — it adds no observable surface, keeps `{k:v}` unambiguously Map, and gives unions and records **one shared construction story** (which the SURF.1↔R2.1 "design together" coupling `SURFACE_DECISIONS.md:70` explicitly requires).

### 5.3 SURF.12 is DEFERRED and explicitly out of R2.1's scope

SURF.12/D7 (LOCKED) moves the union/intersection **type-level** connector to a **keyword**, freeing `&`/`|` to be bitwise-only at the value level. **R2.1 does NOT do this.** R2.1 keeps `|`/`&` in *type-annotation* position (as `QUARTZ_REFERENCE.md:5137-5180` already shows) and termifies values under that existing type syntax. Moving the type-level connector to a keyword is SURF.12's job — a later, formatter-driven mechanical rewrite.

The **only genuine one-way door** — naming the union-type keyword — is owned by SURF.12 and is out of scope here. This means R2.1 ships with type-level `|` still present, which SURF.12 will later rewrite. That is **deliberate sequencing, not a contradiction to ship silently** (saga "Owner Decisions" #4; `surface-coupling.md` Decision 2b).

### 5.4 Destructuring is reversible / already locked

Union destructuring rides the *existing, locked* flow-narrowing + `match`/`is` surface — zero new surface. Match **or-patterns** (`1 | 2 | 3`) legitimately keep `|` at the **pattern** level, which does not collide with SURF.13 (patterns are not value expressions). Recommend restating SURF.13 precisely as "`&`/`|` bitwise-only at the value-**expression** level" so or-patterns stay unambiguously legal. The internal tag representation (i64 tag layout, niche packing) is a pure implementation choice, freely changeable. (`surface-coupling.md` Decision 2c/2d, Decision 4.)

---

## 6. Current-state seam map

The exact `file:line` seams that termification changes, pulled from `current-state.md`.

| Seam | What it does today | What termification does | Location |
|---|---|---|---|
| **Union MIR erasure** | `mir_is_union_annotation` scans for top-level `\|` and gates `mir_ctx_mark_struct_var` **off** — a union param is treated as its bare underlying scalar; no tag, no boxing | Stop erasing; synthesize the `{tag,payload}` shape and emit `mir_widen_to_union` at coercion sites | `mir_lower.qz:6894` (also `mir_lower_expr_handlers.qz:834`); predicate `mir.qz:3653` |
| **Record monomorphization** | PASS 0.97 registers any `{`-typed-param function as a bounded generic so field access resolves against the *concrete struct* passed at the callsite — the record type has no independent representation | Replace with a standalone flat-offset structural layout for the value case | `mir_lower.qz:7622-7649` (record params not marked nominal at `mir_lower.qz:6896`) |
| **Permissive record subtyping** | concrete-vs-record and record-vs-concrete both just `return true` — width subtyping is unchecked at this layer, deferred to MIR monomorphization | Tighten to real width/depth checks once records own their layout (MIR can no longer reconcile fields via monomorphization); reprojecting copy on layout-changing subtyping | `typecheck.qz:2058`, `:2062` (structural match at `:2050-2054`) |
| **qzmod advisory-miss** | the whole `TYPE_UNION_BASE..PTYPE_BASE` band (union/record/intersection/forall/protocol) is an "advisory-miss" and returns `-1`/unmappable — these types are module-local | Make the `TYPE_UNION_BASE..TYPE_RECORD_BASE` band remappable so termified values survive incremental/cross-module compilation | `qzmod_remap.qz:322-323` (contract at `:278-286`; newtype path `:300-312`) |
| **Interning caps** | each based range is a hard 1000-slot ceiling; record membership predicate hard-codes it (`type_id >= BASE and < BASE+1000`); interning is linear scan | Grow the ceilings + linear-scan interning if value-use mints many instances | `type_constants.qz:162-168`; predicate `typecheck_registry.qz:2193`; interning scans `typecheck_registry.qz:2143-2147`, `:2276-2280` |

Supporting registration/state seams (unchanged in contract, load-bearing to read first): union storage `typecheck_util.qz:347-348`; record storage `typecheck_util.qz:375-380`; intersection storage `typecheck_util.qz:349-350`; row-variable system `typecheck_util.qz:564-572`.

**Note:** the many `mir_lower.qz` "union" hits at 9921-9978 and `cl_bin_parse_union` (`cst_lower.qz:5795`) are the `binary{}` memory-layout discriminated-union feature (Phase 2 Track B) — **unrelated** to type-level `A | B`. Do not touch them.

---

## 7. Implementation phasing

The A0→E2 roadmap from the saga plan's Stack-Ranked Work table. **Ordering rationale:** records unlock the record-arm discriminated-union optimization that union narrowing depends on; but the **union vertical slice (Phase B) is the highest-value, most-tractable de-risking milestone and lands first** — unions must be constructible + tagged before they can be narrowed, and the union slice is the most self-contained proof the whole design works. Each item = one guarded commit with an acceptance gate.

| # | Item | Est (qd) | Blast radius | Conf. |
|---|------|----------|--------------|-------|
| **A0** | Consolidated design doc `docs/design/TERMIFICATION.md` (this file) | 0.25 | docs only | high |
| **B1** | Union runtime rep: arm-set → anonymous-enum `{tag,payload}` (tag = hash(arm type-id)); stop erasing union annotations; emit `mir_widen_to_union` at LET/binding coercion sites | 1–1.5 | `mir_lower.qz`, `mir.qz`, codegen | med |
| **B2** | Union narrowing: `if x is T` / `match` proves the tag + recovers `payload@offset`; arm-set exhaustiveness. **First end-to-end runtime win.** | 1–1.5 | `typecheck_walk.qz`, `typecheck_match.qz`, `mir_lower.qz` | med |
| **B3** | Union widening at remaining coercion sites: return, arg-pass, field/element store, union→wider-union | 0.5–1 | typecheck coercion + `mir_lower` | med |
| **B4** | Niche inheritance: verify `T \| Nil` / `&T \| Nil` drop the tag word (reuse niche pass); runtime round-trip | 0.5 | codegen niche pass (verify, likely no change) | med-high |
| **C1** | Structural record standalone flat-offset layout + type-directed construction (replace monomorphize-to-nominal fake for the value case) | 1–1.5 | `mir_lower.qz:7622-7649`, codegen | med-low |
| **C2** | Record field access + tighten width/depth subtyping (replace permissive `return true` at `typecheck.qz:2058/2062`; reprojecting-copy on layout-changing subtyping); scoped labels | 1 | `typecheck.qz`, `typecheck_util.qz` | med |
| **C3** | Records in heterogeneous storage / return position (`Vec<{x:Int}>`, record return) — the thing monomorphization cannot do | 0.5–1 | `mir_lower`, codegen | med-low |
| **D1** | Intersection record&record → constructible merged record end-to-end (merge already at registration); keep nominal/trait `&` bound-only | 0.5 | `typecheck_registry` (verify), `mir` | med |
| **D2** | Discriminant-field-as-tag optimization for all-record-arm unions — **STRETCH** | 1 | codegen niche variant | low |
| **D3** | qzmod cross-module serialization: make `TYPE_UNION_BASE..TYPE_RECORD_BASE` remappable (`qzmod_remap.qz:322` advisory-miss → real remap) | 0.5–1 | `qzmod_remap.qz`, `qzmod_emit.qz`, `qzmod_format.qz` | med |
| **D4** | Interning-cap review: grow the hard 1000-slot ceilings + linear-scan interning | 0.25 | `type_constants.qz`, `typecheck_registry.qz` | high |
| **E1** | Error-rendering polish: arm-mismatch / non-exhaustive-union / width-subtype diagnostics (Phase 0 display names done) | 0.5 | typecheck diagnostics | high |
| **E2** | Docs: `QUARTZ_REFERENCE.md` (mark constructible, examples), `ROADMAP.md` R2.1 status, remove "codegen not yet implemented" caveats | 0.25 | docs only | high |

**Why the phase order (summary):** records (P1/C-tier) are self-contained and unlock the record-arm discriminated-union optimization that union narrowing (D2) depends on; unions (Phase B) cannot narrow before they can be constructed and tagged, so B1 (rep + construct) precedes B2 (narrow); intersection (D1) leans on record terms for its only constructible case. Each phase reuses far more than it builds — the whole feature is "reroute structural typing through the enum + value-struct + flow-narrow machinery that already ships." The **Phase B union slice is the de-risk milestone; land it first.**

---

## 8. Open questions / deferred

1. **SURF.12 union-type keyword naming — OWNER, DEFERRED.** SURF.12 mandates moving the type-level `|`/`&` connector to a keyword but does not name it. That name is a public one-way door. It is **owned by SURF.12 and out of R2.1's scope.** R2.1 ships type-level `|` unchanged; SURF.12 later rewrites it mechanically. Do not default the keyword silently; do not treat retaining type-level `|` as a permanent decision (`surface-coupling.md` Decision 2b).

2. **Discriminant-field-as-tag optimization (stretch D2).** When all arms are records sharing a literal-typed discriminant field, use that field's value as the tag — no separate tag word. A follow-on optimization, not required for core narrowing. Depends on records (C-tier) landing first (`external-design.md` §3, §6a).

3. **Interning-cap growth trigger (D4).** Each based range is a hard 1000-slot ceiling (`type_constants.qz:162-168`), and interning is linear scan (`typecheck_registry.qz:2143-2147`, `:2276-2280`). Widespread record/union *value* use will mint many more instances than annotation-only use did. Open question: at what instance count does the linear scan / 1000-slot ceiling need to grow, and to what data structure (hash-indexed interning?). Deferred until value-use volume is measurable.

4. **Anonymous-record-value spelling fallback.** SURF.1 says anon records come from the expected type "if ever needed." If a genuinely anonymous record value (no nominal struct in scope) proves necessary in practice, the fallback is a keyword-prefixed `[Type]{body}` form — never a new sigil. That would become a real one-way door and must be owner-ratified before any codegen locks the spelling (`surface-coupling.md` Decision 1).

---

## Sources

- `docs/sagas/r2-termification-2026-07-04-research/current-state.md` — capability matrix + file:line seams.
- `docs/sagas/r2-termification-2026-07-04-research/external-design.md` — recommended runtime design + LLVM lowering + comparative evidence (TS/Ceylon/Flow/OCaml/Haskell/Rust).
- `docs/sagas/r2-termification-2026-07-04-research/surface-coupling.md` — one-way-door analysis + SURF.1/12/13 reconciliation.
- `docs/sagas/r2-termification-2026-07-04.md` — saga plan (core design, owner decisions, stack-ranked work).
- `docs/design/SURFACE_DECISIONS.md`, `docs/design/SURFACE_SYNTAX_RATIONALE.md`, `docs/QUARTZ_REFERENCE.md:5137-5180`, `docs/ROADMAP.md` R2.1 — locked surface constraints.
