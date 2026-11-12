# Multi-Payload Enum Niche Layout — the Swift-Parity Endpoint of the Enum-Niche Initiative

**Status:** 📐 DESIGN RFC — awaiting ratification. No code in this document.
**Roadmap:** B.10 Phase 4, the niche workstream's terminal increment — successor to N0/N1/N2 (scalar/borrow/NonZero niches) and N3.1/N3.2 (boxed-pointer `None` niche, LANDED 2026-06-13). See `docs/design/MEMORY_MODEL_V3.md` §14.5/§14.6/§14.7/§14.7.1/§14.7.2 for the current state.
**Authored:** 2026-06-13, from a Rust/Swift/Zig prior-art sweep + a codebase audit of the shipped single-payload niche machinery (`niche.qz`, `mir.qz`, `mir_lower.qz`).
**Scope:** enums with **≥2 payload-carrying variants** (`Result<&T,&E>`, `enum Tree { Leaf(Int), Node(Box,Box) }`, `enum Expr { Lit(Int), Add(Expr,Expr) }`). Single-payload `Option<P>` is DONE; this is the remaining gap.

> **One-paragraph thesis.** Quartz is pointer-heavy by representation: in the i64-existential model every struct / Vec / String / Map / Set / closure / Tuple is a single non-null heap-pointer word, and the dataless-enum / single-payload-`Option` niche machinery (`mir_option_is_niche`, `mir_get_enum_tag_niche`, `mir_option_none_const`) already threads end-to-end. A *multi-payload* enum whose payloads are all boxed pointers therefore has an enormous shared niche surface — the low alignment bits **and** the entire range `[1, ALIGN)` of every payload word are simultaneously invalid in all variants — so the discriminant for a small number of variants can be packed into those spare values for **zero** extra bytes, exactly as Swift packs a tag into common spare bits. Where no common spare bits exist (the information-theoretic floor: `enum E { A(Int), B(Int) }` — two full-width Ints share no invalid pattern), the layout falls back to today's explicit tag word, which is **correct, not a failure** — Rust and Swift both tag that case too. The first increment is the two-boxed-pointer-payload enum (`Result<&T,&E>`-shaped); everything else stages behind it.

---

## 0. Where we are (the substrate this builds on)

The shipped niche machinery (`self-hosted/backend/niche.qz`, and the bridge in `mir.qz`):

- **`niche.qz` is string-pure** — `type_niche(name)` → `[start, count]`, `enum_layout(payload_cnt, dataless_cnt, payload_type)` → `[kind, niche_start, dataless_used]`. It is the **single source of truth** for the niche-vs-spill verdict (`niche.qz:129`). It is deliberately ctx-free so it round-trips through qzmod without a struct type. **It only knows single-payload shapes today** (`payload_variant_count == 1` gate at `niche.qz:130`).
- **The boxed classifier IS ctx-aware** — `mir_payload_is_boxed_classify` (`mir.qz:7009`) is where "is this payload-type a non-null heap pointer whose `0` is a free inhabitant?" is decided, consulting the struct registry / builtin tables. Per-class LIVE gates (`mir_boxed_niche_struct_live`/`_string_live`/`_function_live`/`_builtin_live`/`_dataless_enum_live`/`_tuple_live`, `mir.qz:6769-6790` and around) stage the rollout. The master flag `mir_boxed_niche_enabled()` (`mir.qz:6769`) is now **1** (N3 landed).
- **`mir_option_is_niche(ctx, P)`** (`mir.qz:7115`) = `enum_layout_kind(...) == NICHE` **OR** `mir_payload_is_boxed(ctx, P)`. **`mir_option_none_const(ctx, P)`** (`mir.qz:7125`) = `K` for dataless-enum (top niche), `0` for boxed (bottom/null niche), else the scalar niche start.
- **Read seam:** `mir_get_enum_tag_niche` (`mir.qz:7435`) for `Option` emits `OP_EQ(enum_val, none_const)` — a K=1 range-membership test that yields the tag directly (`None`=1/`Some`=0). `mir_get_enum_tag_subj` (`mir.qz:7460`) is the AST-aware drop-in. **Payload-bind seam:** `mir_set_pending_inline_for_enum` (`mir.qz:7469`) + `mir_ctx_apply_pending_bind` (`mir.qz:7508`) — under niche the `Some` binding is an **identity bind** (`payload_val = pending_base`, `mir.qz:7542`), no load from offset 1.
- **Construct seam:** `mir_lower.qz` NODE_ENUM_ACCESS (`mir_lower.qz:3781`). Under niche, `Some(x)` returns `mir_lower_expr(payloads[0])` (identity) and `None` returns `mir_emit_const_int(none_const)` (`mir_lower.qz:3825-3831`); SPILL falls through to the legacy 1+N-word alloc.
- **Erased-boundary guard:** QZ0212 (`mir_lower_expr_handlers.qz:1753-1813`) — a niche `Option<concrete>` arg whose param is typed `Option<T>` (erased) is a hard compile error, because the single erased body reads via the boxed (spill) layout.

The current multi-payload representation is the SPILL layout: a heap box `[tag, payload_0, payload_1, …]`, tag at word 0, payloads at words 1..N. `Result<&T,&E>` is **two words minimum** (tag + payload), often three with the box header.

---

## 1. Prior art (what the world already does)

### 1.1 Swift — the model we adopt

Swift's `docs/ABI/TypeLayout.rst` (canonical) describes a two-level algorithm:

**Single-payload** (one data case, ≥1 no-data cases): the data case is represented in the payload type's own bits; no-data cases consume the payload type's **extra inhabitants** (bit patterns of the right size/align that aren't valid values), assigned in ascending numeric order to no-data cases in declaration order. Only if extra inhabitants run out is a separate tag bit added. *(This is exactly Quartz's shipped single-payload niche.)*

**Multi-payload** (≥2 data cases): "The ABI will first try to find common **spare bits** — bits in the data types' binary representations which are either fixed-zero or ignored by valid values of **all** of the data types. The tag will be scattered into these spare bits as much as possible." If there aren't enough common spare bits to hold the tag, "additional bits are added to the representation to contain the tag." Tag values are assigned to data cases in declaration order; no-data cases are collected under a common tag and assigned values in the data area in declaration order. Swift's current implementation only mines spare bits of **primitive integer types** (e.g. the high bits of an `i21`).

Takeaways for Quartz:
- The discriminant lives in bits that are spare *across every payload simultaneously* — not in one chosen variant's niche (that's the single-payload trick).
- "Extra inhabitants" (whole invalid values, e.g. `0` for a non-null pointer) and "spare bits" (per-bit fixed-zero/ignored, e.g. the low alignment bits of an aligned pointer) are **two harvesting mechanisms** for the same purpose. A pointer gives us *both*.
- The fallback is a real, expected outcome, not a defeat.

Source: [Swift ABI TypeLayout.rst](https://github.com/swiftlang/swift/blob/main/docs/ABI/TypeLayout.rst); background [The Swift Runtime: Enums](https://belkadan.com/blog/2020/10/Swift-Runtime-Enums/); [Multi-payload enum optimizations (Swift Forums)](https://forums.swift.org/t/multi-payload-enum-optimizations/65506).

### 1.2 Rust — niche-filling, and why it mostly *doesn't* for multi-payload

Rust's niche-filling (the mechanism behind guaranteed `Option<Box<T>>` = one word, `Option<&T>` = one word): the compiler picks the dataful variant with the **largest niche** — an unused value-range in one of its fields (`NonZero` excludes 0; `&T`/`Box<T>` exclude null; `bool` excludes 2..255) — and stores the *other* variants' discriminants in that niche. The niche-filled layout competes against a plain tagged layout; the smaller wins (RFC: the variant chosen is "the one whose niche has enough available values for the number of remaining variants").

For **multi-payload**, classic rustc gave up: "if we find more than one dataful variant, then `dataful_variant` will be set to `None`, so we will not be able to perform niche optimization" — because a niche reserved inside variant A's field-bytes can collide with variant B's data in those same bytes. PR #94075 relaxed this: niche-fill multi-payload *is* attempted when the other variants provably fit entirely **before or after** the niche location. But it remains **best-effort and not guaranteed** by the language — only single-field NPO-style cases are contractual. RFC 2363 (arbitrary enum discriminants) is orthogonal: it controls the *discriminant value*, not whether a tag is materialized; `#[repr(...)]` *forces* a tag.

Hard floor confirmed by the Rust issue tracker: `enum E { A(i64), B(i64) }` and `enum { One(Enum), Two(Enum,Enum) }` (rust#93739, rust#148566) cannot niche — full-width integers / multiple same-type payloads share no spare pattern. There is recent RFC work (alignment-niches / size-niches for `&T`, moulins RFC 3204) to *widen* reference niches precisely so multi-payload reference enums pack better — direct corroboration of our pointer-heavy thesis.

Sources: [RFC 2363](https://rust-lang.github.io/rfcs/2363-arbitrary-enum-discriminant.html); [Niche optimizations in Rust (0xAtticus)](https://www.0xatticus.com/posts/understanding_rust_niche/); [unsafe-code-guidelines #10](https://github.com/rust-lang/unsafe-code-guidelines/issues/10); [rust#93739](https://github.com/rust-lang/rust/issues/93739); [RFC 3204 references-alignment-niches](https://github.com/moulins/rfcs/blob/master/text/3204-references-alignment-niches.md).

### 1.3 Zig — the control case

Zig's tagged unions (`union(enum)`) carry an explicit tag enum; the layout for `.auto` unions is unspecified, `extern` follows the C ABI, `packed` has well-defined bit layout. Zig does **not** do automatic niche/tag-into-spare-bits packing for `.auto` tagged unions — the tag is a separate field (issue #1922 is an open request for more control over exactly this). The relevant Zig lesson is the *padding* observation: a tag stored inline with the union pays up to 7 bytes of padding per value; a struct-of-arrays (tag array separate from payload array) eliminates it. Quartz is unaffected (single-word existential), but it confirms the cost we are eliminating.

Sources: [Zig issue #1922 (tagged-union layout control)](https://github.com/ziglang/zig/issues/1922); [zig.guide unions](https://zig.guide/language-basics/unions/).

### 1.4 Synthesis — the Quartz-specific opportunity

Quartz is more niche-friendly for multi-payload than Rust or Swift, because of representation uniformity:

- **Every boxed payload is the *same shape* — one 8-byte non-null aligned heap pointer.** Swift/Rust must reconcile differently-shaped payloads; Quartz's payloads are bit-for-bit interchangeable words.
- A heap pointer aligned to 8 bytes has **3 guaranteed low spare bits** (it's `& 7 == 0`) and the entire value `0` (null) plus the non-canonical high-address range as extra inhabitants. On the dev arm64-apple target, allocations from `__qz_alloc` are ≥8-aligned, so the low-3-bits-zero invariant holds for *all* boxed payload classes simultaneously — they are **common spare bits** in the exact Swift sense.
- 3 spare low bits encode **8 tag values** at zero byte cost; the null inhabitant adds dataless-variant capacity on top. An enum with ≤8 payload variants whose payloads are all boxed pointers niches into a single word.

This is the design's center of gravity: **the common-low-bit niche over uniformly-boxed payloads.** The scalar/Int multi-payload case is the floor that always tags.

---

## 2. The layout algorithm

Given an enum with payload-bearing variants `P_1..P_m` (m ≥ 2) and dataless variants `D_1..D_K` (K ≥ 0):

### 2.1 Common-spare-bits scan (the core)

Compute, for each payload variant `P_i`, the spare-bit descriptor of its payload word. For a multi-field payload variant (`Node(Box,Box)`), the payload is itself boxed today (a heap allocation pointer — see §2.4), so the variant's representation word is a single boxed pointer regardless of arity. The per-payload spare descriptor is:

```
SpareDesc {
  low_zero_bits:   Int   # count of guaranteed-zero low bits (alignment): boxed ptr ⇒ 3 (8-align)
  extra_inhabitants: [run...]  # whole invalid values, e.g. {0,1} for null + reserved (bottom niche)
}
```

This is computed by **extending `niche.qz`** with a `type_spare_bits(name) → low_zero_bits` query that mirrors `type_niche`, plus reusing `mir_payload_is_boxed_classify` (ctx-aware) to confirm boxed-ness. The classifier already knows the boxed classes (`mir.qz:7009`); `low_zero_bits = 3` for every class it returns 1 for, `0` otherwise (scalars).

**The common spare = the intersection** across all `P_i` (and the dataless variants, which carry no payload and impose no constraint):

```
common_low_zero = min over i of SpareDesc(P_i).low_zero_bits
common_extra    = intersection over i of SpareDesc(P_i).extra_inhabitants
```

For a uniformly-boxed multi-payload enum: `common_low_zero = 3` (8 tag slots) and `common_extra ⊇ {0}` (null). For a mixed `{Box, Int}` enum: `common_low_zero = min(3, 0) = 0`, `common_extra = ∅` ⇒ **no common spare** ⇒ SPILL.

### 2.2 Tag-encoding assignment

Let `V = m + K` total variants. If `2^common_low_zero ≥ V` (the common low spare bits alone can name every variant):

- **Encoding:** the niche word for a value of variant `i` is `payload_ptr_i | tag_i`, where `tag_i ∈ [0, V)` is the variant's declaration index packed into the low `common_low_zero` bits. The payload pointer's low bits are known-zero, so OR-ing the tag in is lossless and masking it out recovers the pointer.
- **Dataless variants** carry no payload; their representation is just the tag in an otherwise-zero word: `0 | tag_i = tag_i`. (These coincide with the small integers `[0, V)` — distinguished from a real boxed payload because a real payload's high bits are a heap address, never zero. But we never need that distinction at read time: the tag bits alone select the variant; payload-binding only runs for payload variants, which mask-and-deref.)
- **Tag 0 caveat:** assigning tag 0 to a payload variant means that variant's word == its raw pointer (the natural representation, free). Assigning tag 0 to a dataless variant means its word == `0` (the null niche — exactly today's boxed `None`). The encoding is **declaration-order** to match Swift and to keep `Result` (Ok=0, Err=1) intuitive: Ok's payload word is `ptr|0` = `ptr`, Err's is `ptr|1`.

If `2^common_low_zero < V` but `common_low_zero > 0`, we still pack as many tag bits as fit into the spare low bits and spill the **remaining** high tag bits into common extra-inhabitant capacity / a partial tag — **DEFERRED past v1** (Swift does scatter, but it adds real complexity; Quartz v1 requires the spare bits to hold the *whole* tag, else SPILL). This is the honest v1 ceiling.

### 2.3 The explicit tag-word FALLBACK (information-theoretic floor)

When `common_low_zero == 0` and `common_extra` cannot host the tag (i.e. no common spare bits exist), the enum **SPILLs** to today's representation: a heap box `[tag, payload_0, …, payload_{n-1}]`, byte-identical to the current layout. This fires for:

- `enum E { A(Int), B(Int) }` — two full-width i64 payloads, every bit pattern valid in both ⇒ no spare bit, **MUST tag**. This is correct: information-theoretically, `A(x)` and `B(x)` for the same `x` are indistinguishable without an extra bit somewhere. Matches Rust `enum { A(i64), B(i64) }` = 16 bytes.
- Mixed boxed/scalar (`{ Box, Int }`) — the scalar payload has no spare bit, so the intersection is empty.
- Any payload class `mir_payload_is_boxed_classify` returns 0 for (CPtr — FFI-null is legitimate; `@value` structs — inline aggregate, no spare word; sanctioned IR/arena handles — `0` is structural).

The router lives in `niche.qz`, generalizing `enum_layout` (which today gates on `payload_variant_count == 1`, `niche.qz:130`) to a new `enum_layout_multi(payload_variant_count, dataless_variant_count, common_low_zero, common_extra_count)`. **The ctx-dependent inputs** (which payloads are boxed, hence `common_low_zero`) are computed in `mir.qz` (a new `mir_multi_enum_common_spare(ctx, enum_name) → [low_zero, extra_count]`) and *passed into* the pure router — preserving `niche.qz`'s string-purity, exactly as N3's dataless-enum scaffold kept the variant-count query in `mir.qz` (`mir_payload_dataless_enum_variant_count`, `mir.qz`) rather than polluting `niche.qz`.

### 2.4 Recursive / multi-field payloads

`Node(Box,Box)` and `Add(Expr,Expr)` carry ≥2 fields. Two sub-cases:

- **Already boxed:** in today's representation a multi-field payload variant is stored as a sub-allocation (a pointer to `[field0, field1]`), so the variant's *representation word is still a single boxed pointer* — it niches identically to a single-field boxed variant. This is the common case and is in-scope.
- **Inline `@value` payload** (`mir_set_pending_inline_for_enum`, `mir.qz:7469`): the payload words live inline in the enum box. These are NOT niche-eligible (no single spare word) and SPILL — already the behavior, unchanged.
- **Self-recursive** (`Expr { Add(Expr,Expr) }`): the back-edge must already be indirected (boxed) to bound size (MEMORY_MODEL_V3 §6 Phase 2 "recursive `@value` → force indirection"). The indirection pointer is the niche-eligible word.

---

## 3. Construct & read seams (what changes)

### 3.1 Construct — `mir_lower.qz` NODE_ENUM_ACCESS (`mir_lower.qz:3781`)

Today the niche branch (`mir_lower.qz:3823-3832`) handles only `Option`/`Some`/`None`. Generalize:

1. After resolving `enum_name`, `variant_name`, `tag_idx` (`mir_lower.qz:3796-3799`), query `mir_multi_enum_layout(ctx, enum_name)` → `[kind, low_zero, V]`.
2. If `kind == NICHE_MULTI`:
   - **Payload variant:** lower the payload to a register `p` (as today via the box path for multi-field, or identity for single boxed field), then emit `niche_word = OP_OR(p, const(tag_idx))`. Because `p`'s low `low_zero` bits are known-zero (boxed, 8-aligned), this is lossless. Return `niche_word`. **No tag-word box** — one word, zero alloc.
   - **Dataless variant:** return `mir_emit_const_int(tag_idx)` (the tag in an otherwise-zero word; for tag 0 this is `0`, the null niche, matching today's boxed `None`).
3. Else fall through to the existing SPILL alloc path (byte-identical).

The payload-type recovery uses the same SoT (`mir_option_construction_payload` / the multi-variant analog) the read sites use, so construct and read **cannot disagree** — the §14.4 discipline that prevented every prior asymmetry.

### 3.2 Read tag — `mir_get_enum_tag_niche` (`mir.qz:7435`)

Today: `Option` only, `OP_EQ(val, none_const)`. Generalize to any niche-multi enum:

```
tag = OP_AND(enum_val, const((1 << low_zero) - 1))    # mask out the payload pointer, keep tag bits
```

`tag` is then the variant's declaration index directly — usable in the existing match-dispatch jump table exactly as `mir_get_enum_tag` (the spill tag-load) produces it. This is the single load-bearing change: **the read masks the low tag bits to get the discriminant, and masks them OFF to get the payload pointer** (see §3.3). For the K=1 `Option` case this stays the cheaper `OP_EQ` (a 1-bit special case of the mask), so no regression to the shipped path.

### 3.3 Payload-bind — `mir_set_pending_inline_for_enum` + `mir_ctx_apply_pending_bind` (`mir.qz:7469`, `mir.qz:7508`)

Today the niche bind is identity (`payload_val = pending_base`, `mir.qz:7542`) — correct for single-payload `Option` where the whole word IS the payload. For multi-payload, the payload pointer has tag bits OR-ed into its low bits, so the bind must **mask them out**:

```
payload_ptr = OP_AND(pending_base, const(~((1 << low_zero) - 1)))   # clear low tag bits
```

Then, for a single-field boxed payload the masked pointer IS the payload value (identity-after-mask); for a multi-field payload it's the sub-allocation pointer to deref field-by-field (same as the spill path's post-load pointer). Add a `pending_bind_niche_mask` parallel to the existing `pending_bind_niche` flag vector (`mir.qz:7505`) carrying `low_zero` per binding, so `apply_pending_bind` knows whether to mask. The dataless-variant arms bind nothing (no payload) — unchanged.

### 3.4 `is`/`some?`/match-subject sites

All route through `mir_get_enum_tag_subj` (`mir.qz:7460`) → `mir_get_enum_tag_niche`, so the §3.2 mask change covers them. The match jump-table dispatch is unchanged: it already switches on the integer tag, which the mask now produces.

---

## 4. Async-suspend / generator save-set soundness

The §7-landmine (MEMORY_MODEL_V3 line ~177): *a value-alloca pointer live across a `$poll` suspend, saved to the heap frame, goes dangling on resume — spill the VALUE, not the pointer.* Multi-payload niche changes the risk surface in a specific, **benign** way, but it must be reasoned through:

- **The niche-multi value is a single i64 word** (`payload_ptr | tag`). It is NOT an alloca, NOT a pointer-to-stack — it is a scalar register holding a self-contained niche-packed word. `mir_collect_generator_locals` (`mir_lower_gen.qz:671`) collects locals by name and the save-set spills the local's **value slot**. Since the niche word IS the value (no indirection through a stack alloca), spilling the slot spills the full niche-packed word — **exactly the value, not a pointer-to-it.** This is the SAME soundness posture as the shipped single-payload niche (an `Option<Bool>` scalar 0/1/2, an `Option<boxed-T>` pointer-or-0), which already survives suspend.
- **The hazard to avoid:** if any future optimization were to materialize a niche-multi value via a stack alloca holding the *unpacked* pointer + a separate tag local (decomposed), and only the alloca pointer were saved, resume would read a dangling decomposition. **v1 forbids this:** the niche-multi value is always a single SSA i64 value, never a decomposed alloca pair. The mask/OR happens at construct and at bind, producing fresh SSA values that the save-set captures by value. Document this as an invariant: *a niche-multi enum local is represented as exactly one i64 SSA value; it is never lowered to a (pointer-alloca, tag-alloca) pair.*
- **Verification:** the async round-trip spec (§6) constructs a niche-multi enum, suspends across a `$poll`, resumes, and asserts the variant + payload survive — the direct test that the save-set captured the packed word. This mirrors `value_struct_poll_spec.qz` and the POLL_BODY frame-spill regression locks (`docs/bugs/done/POLL_BODY_*`).

---

## 5. The QZ0212 erased-boundary plan

Generic functions are NOT monomorphized (A.36 monomorphizes structs, not free functions); one erased body reads `Option<T>`/`enum<T>` for every instantiation via the **boxed (spill) layout**. A niche value flowing into such a body is `inttoptr`-ed and dereferenced ⇒ SEGFAULT. QZ0212 (`mir_lower_expr_handlers.qz:1753`) catches this today for niche `Option`: a niche-`Option<concrete>` arg whose param is typed `Option<T>` (payload is a type variable, not the concrete) is a hard error.

Multi-payload extends the same hazard and the same guard:

1. **Detection generalizes.** Today `mir_subject_is_niche_option` (`mir.qz:7449`) gates QZ0212. Add `mir_subject_is_niche_multi(ctx, s, node)` — true when the arg is a niche-multi enum value. The QZ0212 scan (`mir_lower_expr_handlers.qz:1768-1813`) must check **both** Option-niche and multi-niche args.
2. **The param-payload mismatch test generalizes.** For `Option` the check is `param_payload != arg_payload` (`mir_lower_expr_handlers.qz:1798`). For a multi-payload enum `E<A,B>`, the check is: any type argument of the param's `E<…>` annotation that is a **type variable** (erased) while the arg's corresponding type argument is **concrete-and-niche-eligible** ⇒ ERROR. (A fully-concrete param `E<&T,&E>` matching a concrete arg is SAFE — the body niche-reads correctly because both construct and read agree on the concrete layout… but only if the body itself is monomorphic. A generic body over `E<X,Y>` is the erased hazard.)
3. **What the audit framework must check (the flip gate, mirroring N3.2's 6-asymmetry chase):** before flipping the multi-payload gate live, audit every construction site of a niche-eligible multi-payload enum in `self-hosted/` + `std/` and prove none reaches an erased body. The compiler's own `Result<T,E>` usage is the highest-risk surface (errors thread through generic helpers). The per-class LIVE gate (§7) keeps this OFF until the audit is green, exactly as `mir_boxed_niche_struct_live` etc. staged N3.
4. **Diagnostic message** must name the multi-payload variant set and the offending type variable, with the same "match before the call / pass the unwrapped value / give a concrete parameter" hint shape as the Option QZ0212 message (`mir_lower_expr_handlers.qz:1801-1803`).

**Soundness floor:** QZ0212 must be *conservative* — false-error is acceptable (it only forbids a niche from crossing an erasure; the user can annotate concretely or unwrap), false-accept is a SEGFAULT. The N3 history (`mir.qz:6739` BLOCKER notes) shows the asymmetry chase is the real cost; the gate-OFF-until-audited discipline is the mitigation.

---

## 6. Staging

### Phase M0 — pure router, zero codegen change (the keystone, fixpoint-trivial)
- Extend `niche.qz` with `type_spare_bits(name)` and `enum_layout_multi(...)` (pure, string + int inputs). Add `mir_multi_enum_common_spare(ctx, enum_name)` + `mir_multi_enum_layout(ctx, enum_name)` in `mir.qz` (ctx-aware, feeds the pure router). **NOT wired into any construct/read site.** Unit-spec only. Master multi-gate `mir_multi_niche_live()` returns 0. **Acceptance:** zero IR diff, gen1==gen2, full qspec green. (The N0 pattern, `niche.qz:1-29`.)

### Phase M1 — the two-boxed-pointer case, gate-OFF scaffold then supervised flip (smallest first increment)
Target: **`Result<A,B>`-shaped enums where both payloads are boxed pointers of the same 8-alignment** (and any 2-variant boxed enum). `common_low_zero = 3` (≥ 1 bit needed for 2 variants). This is the minimal case: exactly the shape with the largest real-world payoff (`Result<Vec<T>, String>`, `Result<struct, struct>`), reusing the already-proven boxed classifier verbatim.
- Wire construct (§3.1), read-tag (§3.2), payload-bind-mask (§3.3) behind `mir_multi_niche_live()`.
- Per-class LIVE gate `mir_multi_niche_result_2box_live()` defaulting 0 (mirror `mir_boxed_niche_struct_live`).
- Flip supervised: chase QZ0212 asymmetries on the compiler's own `Result` usage (§5.3); verify guard fixpoint + Rule-2 smokes + the M1 specs.

### Phase M2 — N-variant boxed (≤8 variants, all boxed payloads)
`enum Tree { Leaf(Box), Node(Box) }`, `enum Json { Str(String), Arr(Vec), Obj(Map), … }` — up to 8 payload+dataless variants pack into 3 spare bits. Same mechanism, wider tag. Gate `mir_multi_niche_nbox_live()`.

### Phase M3 — boxed + dataless mix
`enum E { A(Box), B(Box), Nothing }` — dataless variants take tag slots / the null inhabitant. Already covered by the §2.2 encoding (dataless = tag in zero word); a thin extension.

### Deferred (named, not silently dropped)
- **Scattered partial tag** (tag wider than common spare bits, Swift-style high-bit scatter) — §2.2; complexity not justified for v1.
- **>8 boxed variants** — needs a 4th spare bit (boxed ptrs only guarantee 3 low zero bits at 8-align; 16-align would give 4) or a partial scatter ⇒ SPILL for now.
- **Reference-niche widening** (Rust RFC 3204 style — mining the non-canonical high-address range for extra tag capacity) — a future capacity boost, filed.

---

## 7. Spec coverage required (TDD — no feature without specs)

Mirroring the shipped niche specs (`spec/qspec/niche_spec.qz`, `option_nonzero_niche_spec.qz`, `option_boxed_struct_niche_spec.qz`, `map_option_value_niche_spec.qz`):

1. **`spec/qspec/enum_multipayload_niche_spec.qz`** (unit, pure router) — `enum_layout_multi` verdicts: 2-boxed ⇒ NICHE_MULTI(low_zero=3); `{Box,Int}` ⇒ SPILL; `{Int,Int}` ⇒ SPILL; 9-boxed-variant ⇒ SPILL (>8); boxed+dataless ⇒ NICHE_MULTI.
2. **Round-trip correctness** — construct each variant of `Result<Vec,String>`, match it back, assert the right arm fires and the payload is intact (`Ok(v).unwrap() == v`, `Err(s)` carries `s`). Include all V variants.
3. **Alloc-free oracle** — the construction site of a niche-multi `Result` emits **no `__qz_alloc` / no `alloca`** (the niche-on check; same oracle as `option_nonzero_niche_spec`). Verify via IR inspection / a no-alloc assertion harness.
4. **`Some(None) ≠ None` nesting analog** — `Ok(Err(x)) ≠ Err(Ok(x))` and nested `Result<Result<…>,…>`: the inner niche packs into the outer's payload pointer without tag-bit collision. (Innermost-only niching, §2 — outer SPILLs if it can't host both.)
5. **`Vec<Result<A,B>>`** — element-position niche threading (the analog of the shipped `Vec<Option<T>>` element-niche, MEMORY_MODEL_V3 §14.7 item — `vec_get`/`vec_push` carry the element type so stored niche-multi values construct and read consistently). Assert push/get round-trip + no per-element box.
6. **Tag-fallback case** — `enum E { A(Int), B(Int) }` constructs/reads via SPILL, byte-identical to today; assert correctness (this is the honest floor — it MUST still work, just tagged).
7. **QZ0212 negative-compile** — `spec/qz/enum_multipayload_qz0212.qz` (standalone, expect compile failure): a niche-multi `Result<Vec,String>` passed to `def f<A,B>(r: Result<A,B>)` must error with QZ0212, not crash. (Compile-error spec form, mirrors `nonzero_compile_error_spec`.)
8. **Async-suspend round-trip** — `spec/qz/enum_multipayload_poll_smoke.qz` (standalone `def main`, real worker spawn per the CLAUDE.md qspec caveat): construct a niche-multi enum, suspend across `sched_yield`, resume, assert variant+payload survive (the §4 save-set test).

All phases: guard fixpoint (gen1==gen2), Rule-2 smokes (style_demo + brainfuck), the phase's specs green, **zero new qspec regressions.**

---

## 8. Go / no-go honesty

| Sub-case | Verdict | Reasoning |
|---|---|---|
| 2 boxed-pointer payloads (`Result<&T,&E>`, `Result<Vec,String>`) | **GO (M1)** | 3 common spare bits, mechanism is a thin generalization of the shipped boxed-`Option` niche; highest payoff. |
| ≤8 boxed variants | **GO (M2)** | Same mechanism, wider tag in the same 3 bits. |
| boxed + dataless mix | **GO (M3)** | Dataless = tag-in-zero-word, already encoded. |
| Mixed boxed + scalar (`{Box,Int}`) | **NO-GO — SPILL** | Scalar has no spare bit ⇒ empty intersection. Correct, tagged. |
| Two scalar payloads (`{A(Int),B(Int)}`) | **NO-GO — SPILL (information-theoretic floor)** | Full-width Ints share no invalid pattern. This is **correct, not a failure** — Rust & Swift tag it too. |
| >8 boxed variants | **NO-GO v1 — SPILL** | Only 3 guaranteed spare bits at 8-align; needs scatter or 16-align (deferred). |
| `@value`-inline payloads | **NO-GO — SPILL** | Inline aggregate, no single spare word; already SPILLs. |
| Compiler's own `Result` across erased generics | **RISK — gated** | The N3.2 asymmetry chase recurs; mitigated by gate-OFF-until-audited + QZ0212. The real cost center. |

**The honest ceiling:** primitive-payload multi-payload enums **always tag**. There is no representation trick that beats information theory; claiming otherwise would be a soundness hole. The win is concentrated exactly where Quartz's representation is uniform — boxed payloads — and that win is large (the eliminated tag word + box header for the dominant `Result<heap, heap>` and recursive-tree shapes).

**Primary risk** is not the layout math (it's a clean generalization of shipped code) — it is the **erased-boundary asymmetry chase** the N3.2 history documents (`mir.qz:6739` BLOCKER). The staging (gate-OFF scaffold → audit → supervised flip) is the entire mitigation, and it is proven by the six prior boxed-class flips.

---

## RATIFICATION QUESTIONS

The human must approve these before any M1 (phase-2) code begins:

1. **Spare-bit source.** Ratify that v1 mines **only the 3 guaranteed low alignment bits** of 8-aligned boxed pointers (plus the null inhabitant) — NOT the non-canonical high-address range, NOT scattered partial tags. (Conservative; deferring the wider sources to a named follow-up.) Yes/adjust?

2. **8-variant ceiling.** Ratify that a niche-multi enum is capped at **≤8 total variants** in v1 (3 spare bits), spilling above that, rather than reaching for 16-alignment or scatter. Yes/adjust?

3. **Declaration-order tag encoding.** Ratify tag = declaration index packed into the low bits (Ok=0 ⇒ `ptr|0`=`ptr`, Err=1 ⇒ `ptr|1`), matching Swift's declaration-order assignment and keeping `Result` Ok cheap. Yes/adjust?

4. **`niche.qz` purity boundary.** Ratify that the ctx-dependent spare-bit computation lives in `mir.qz` (`mir_multi_enum_common_spare`) and feeds the pure `niche.qz` router — preserving qzmod round-trip purity, per the N3 dataless-enum precedent. Yes/adjust?

5. **First increment = 2-boxed `Result`.** Ratify M1's scope as exactly two-boxed-pointer-payload enums before N-variant/dataless-mix. Yes/adjust?

6. **QZ0212 conservatism.** Ratify that the erased-boundary guard is conservative (false-error acceptable, false-accept forbidden) and that the multi-payload gate stays OFF until the compiler-self `Result`-usage audit is green. Yes/adjust?

7. **Niche-multi representation invariant.** Ratify the §4 invariant — *a niche-multi enum local is exactly one i64 SSA value, never a (pointer-alloca, tag-alloca) decomposition* — as a hard rule the save-set soundness depends on. Yes/adjust?

8. **The floor is a feature.** Acknowledge that primitive-payload multi-payload enums (`{Int,Int}`) tagging is the correct, ratified behavior — not a gap to close later. Yes?
