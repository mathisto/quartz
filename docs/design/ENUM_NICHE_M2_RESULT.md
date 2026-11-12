# Enum Niche M2 — Niching Built-in `Result<&T,&E>`

**Status:** 📐 DESIGN RFC — awaiting ratification. No code in this document (READ-ONLY feasibility + architecture pass).
**Roadmap:** B.10 Phase 4 niche workstream. Successor to M1 (`docs/design/ENUM_NICHE_MULTIPAYLOAD.md` + MEMORY_MODEL_V3 §14.9, LANDED-AND-FLIPPED 2026-06-13). M1 niched **user** 2-boxed enums; M2 is the deliberately-deferred increment: niche the **built-in `Result<T,E>`** itself — the highest-value multi-payload case.
**Authored:** 2026-06-13, from a codebase audit of the shipped M1 machinery + the boxed-Option erased-boundary precedent + a Rust/Swift prior-art sweep on niches across generic/erased boundaries.

> **One-paragraph thesis.** M1 proved the layout math: a 2-boxed-pointer enum niches into one word (`payload_ptr | tag`, read masks `& 7` for the tag and `& ~7` for the pointer). Built-in `Result<&T,&E>` is the same shape and would niche identically — **the layout is solved.** What blocks M2 is not representation, it is the **erased boundary**: Quartz does not monomorphize free generic functions, so the std `Result` combinators (`is_ok<T,E>`, `unwrap_ok<T,E>`, `result_map`, …) and the `?`/`try` desugar are compiled ONCE with `T,E` erased and read every `Result` via the hard SPILL layout. A niched `Result` flowing into any of them is `inttoptr`+offset-loaded ⇒ SEGFAULT, and the guard that would catch this (`mir_subject_is_niche_multi` feeding QZ0212) does not exist. The crux finding of this audit: **the M1 spare-mask is a compile-time constant `7` — type-INDEPENDENT** (always the 3 low alignment bits of an 8-aligned boxed pointer; `niche.qz:185-194`, `mir_multi_enum_spare_mask` `mir.qz:7393`). That collapses the problem: an erased body CAN niche-read a `Result` **without knowing the concrete type**, exactly as the erased boxed-`Option` combinators already do via call-site interception. The recommended architecture is therefore **(D) hybrid** — type-independent niche-aware reads at the combinator/try seams (extending the proven Option-interception precedent), a generalized `mir_subject_is_niche_multi` QZ0212 guard for the combinators that *can't* be intercepted, and NO new monomorphization. This is strictly less machinery than the RFC's option B feared.

---

## 0. Where M1 left us (the substrate)

M1 is LIVE (`mir_boxed_niche_multi_payload_live()` → 1, `mir.qz:7186`). A non-colliding USER enum with exactly two single-boxed-payload variants (≤8 variants) niches into one word. Built-in `Option`/`Result` are **explicitly excluded** at two sites:

- `mir_multi_enum_common_spare` (`mir.qz:7291`) returns `none_spare` immediately for `enum_name == "Option"` (line 7294) and `enum_name == "Result"` (line 7295).
- `mir_multi_enum_variant_collides_builtin` (`mir.qz:7252`) forces SPILL for any USER enum whose variant set contains `Ok`/`Err`/`Some`/`None` — the resolved §14.9 bare-variant asymmetry (a bare `Ok` arm resolves to built-in `Result` via `mir_find_enum_by_variant`, while the qualified `Res::Ok` construct niches ⇒ construct/read disagreement ⇒ segfault). M2 must keep this rule (it's orthogonal — it's about *user* enums shadowing built-in variant names) but the built-in `Result` itself becomes niche-eligible.

The M1 read/construct/bind seams are already wired and gated; M2 reuses them verbatim once the `enum_name == "Result"` early-outs are lifted and the three blockers below are cleared.

**The crux constant.** `mir_multi_enum_spare_mask(layout)` (`mir.qz:7393`) computes `(1 << low_zero) - 1` where `low_zero = niche::enum_layout_niche_start(layout)`. For every M1/M2-eligible enum `low_zero == 3` (set in `mir_multi_enum_common_spare` `mir.qz:7328`, gated on `payload_count == 2 and boxed_payloads == 2`), so **the mask is always `7`** and the payload-recover mask is always `~7`. The tag is the variant's declaration index in `[0, V)`. For `Result`: Ok=0 ⇒ word `ptr|0` = `ptr` (free), Err=1 ⇒ word `ptr|1`. **None of this depends on `T` or `E`** — only on the fact that both payloads are 8-aligned heap pointers, which holds for every `Result<boxed, boxed>` instantiation uniformly. This is the property that makes the erased boundary tractable without monomorphization.

---

## 1. The three blockers (file:line precision + current mechanism)

### Blocker #1 — no erased-boundary guard for multi-payload (`mir_subject_is_niche_multi` does not exist)

- **Current mechanism (Option only):** QZ0212 lives at `mir_lower_expr_handlers.qz:1753-1813`. It scans call args with `mir::mir_subject_is_niche_option(ctx, s, arg)` (`mir.qz:7971`), and for any niche-Option arg whose param annotation starts with `"Option<"` but whose payload type differs from the arg's concrete payload (`n_dg_ppay != n_dg_apay`, line 1798), it hard-errors and `exit(1)`. This catches `f<T>(o: Option<T>)` called with a niche `Option<&Foo>`.
- **The gap:** there is NO `mir_subject_is_niche_multi`. `grep` confirms only `mir_subject_is_niche_option` exists (`mir.qz:7971`). A niched `Result<&A,&B>` flowing into an erased `def f<A,B>(r: Result<A,B>)` is an **uncaught false-accept** — the erased body spill-reads (`inttoptr` + `load_offset 0`) the niche word and crashes. MEMORY_MODEL_V3 §14.9 (`mir.qz:6739` BLOCKER note region) names this as the load-bearing reason `Result` stays excluded.

### Blocker #2 — `mir_lower_try` hardcodes the spill layout for `Result`

- **Current mechanism:** `mir_lower_try` (`mir_lower_expr_handlers.qz:352`). The `?` path (NodeTryExpr) already has an *Option* niche branch — `try_niche = mir::mir_subject_is_niche_option(ctx, s, inner)` (line 457). When `try_niche == 1` it does the range-test discriminant (`OP_NE expr_val, none_const`, line 466) and identity payload (line 487). But when `try_niche == 0` (i.e. for **every Result**), it falls to the hardcoded spill path: `load_tag = mir_emit_load_offset(expr_val, 0)` (line 468), `cmp = OP_EQ(load_tag, 0)`, and the Ok payload is `mir_emit_load_offset(expr_val, 1)` (line 489). The `try/catch` form (NODE_TRY_CATCH, lines 357-440) is **purely spill** — `tag = load_offset(body_val, 0)` (line 375), `ok_payload = load_offset(body_val, 1)` (line 385), `err_payload = load_offset(body_val, 1)` (line 394), with the literal comment `# Result layout: [tag:i64@0, payload:i64@1]` (line 356). If `Result` niches, every `?` and every `try/catch` over a niched `Result` reads garbage.

### Blocker #3 — erased generic `Result` combinators read via spill (the central fork)

- **Current mechanism:** `std/prelude.qz:98-189` defines `is_ok<T,E>` (98), `is_err<T,E>` (106), `unwrap_ok<T,E>` (115), `unwrap_err<T,E>` (124), `unwrap_or_ok<T,E>` (132), `ok<T,E>` (140), `err<T,E>` (148), `result_map<T,E,U>` (160), `result_map_err<T,E,F>` (168), `result_and_then<T,E,U>` (176), `result_or<T,E>` (184); `std/result.qz:20` (`is_ok`), `:28` (`is_err`). Every body is `match res / Result::Ok(...) / Result::Err(...)` over a `Result<T,E>` with **type-variable payloads**.
- **Why erased:** these are **unbounded** generics (`<T,E>`, no trait bounds) that do not UFCS-call their params (they `match`). They therefore do NOT register in PASS 0.9 (bounded-generic monomorphization, `mir_lower.qz:6436` — requires `str_byte_len(bounds) > 0`, line 6451) nor PASS 0.95 (structural/UFCS monomorphization, `mir_lower.qz:6488`). They are lowered ONCE in PASS 1 with `T,E` erased, reading the discriminant via `mir_get_enum_tag` (spill `load_offset 0`) since the subject's static payload is a type variable ⇒ `mir_option_subject_payload`/`mir_multi_enum_layout` see no concrete type ⇒ spill. **One body serves all instantiations.** A niched `Result` flowing into any of them spill-reads ⇒ SEGFAULT.

---

## 2. How the existing niches survive the erased boundary (the precedent that decides the fork)

The KEY question the task posed: *can a niche read be made WITHOUT knowing the concrete enum type at the read site?* The answer, from auditing the shipped boxed-`Option` path, is **yes for both Option and multi-payload `Result` — the mask is type-independent — and the shipped code already exploits this in two ways:**

### 2.1 Call-site interception (the primary mechanism — combinators NEVER enter the erased body)

The shipped boxed-`Option` niche does **not** let a niche Option enter the erased `is_some<T>`/`unwrap<T>`/`unwrap_or<T>` bodies. Instead, `mir_lower_expr_handlers.qz:1690-1751` **intercepts the call at the call site**: when `mir_subject_is_niche_option(ctx, s, arg)` is true, it replaces the call with inline niche-aware MIR —
- `unwrap_or` (lines 1700-1709): `OP_NE(opt, none_const) ? opt : default` — a pure select.
- `is_some`/`is_none`/`unwrap`/`option_get` (lines 1720-1748): range-test / identity, matching `func_name` against both the bare intrinsic (`option_is_some`) and the prelude UFCS wrapper (`str_ends_with(func_name, "$is_some")`).

The erased body is **never called** for a niche receiver. The intercept works precisely because the niche read needs only `mir_option_none_const(ctx, pt)` — for boxed Option that's the constant `0` (`mir.qz:7623`), type-independent.

### 2.2 QZ0212 catches the residue (combinators that CAN'T be intercepted)

For combinators the call-site interception does NOT cover (`option_map`, `option_and_then`, and any user `f<T>(o: Option<T>)`), QZ0212 (§1 blocker #1) hard-errors when a niche Option would cross into an erased `Option<T>` param. So the invariant holds: a niche Option either (a) is intercepted at a known combinator call site, or (b) is QZ0212-rejected before it can reach a spill-reading erased body. There is no third path.

### 2.3 Does this generalize to multi-payload? YES — because the mask is type-independent

For multi-payload `Result`, the read is `tag = OP_AND(val, 7)` and `payload = OP_AND(val, ~7)` (`mir_get_enum_tag_niche` `mir.qz:7961-7965`; bind-mask `mir.qz:8067`). **Neither operand depends on `T` or `E`** — `7` is `(1<<3)-1` for every boxed instantiation. So an erased body that knew "this `Result` is niched" could read it correctly with the constant mask, exactly as the Option interception reads with the constant `none_const=0`. The runtime does NOT need the concrete type to recover the tag or the payload pointer; it needs only the boolean "is this argument a niche-multi `Result`?", which is a **static property of the call site** (the arg's concrete type annotation), not of the erased body.

**Crux answer to the task's KEY QUESTION:** the multi-payload spare_mask is *always the same 3 low bits* (`& 7` / `& ~7`), hence type-INDEPENDENT, NOT varying with payload alignment — every niche-eligible payload is an 8-aligned heap pointer by construction (`mir_multi_variant_is_single_boxed` `mir.qz:7208` requires `mir_payload_is_boxed`, which excludes scalars/CPtr/@value). This collapses option D into "the right answer."

---

## 3. Architecture decision

### Option (A) — niche-aware reads through the erased boundary at runtime

*Make the erased combinator body itself check "is this a niched Result?" at runtime and branch.* **Rejected as stated.** The erased body has no static knowledge of its instantiation's payload types, and there is no runtime type tag on a Quartz `Result` value to consult — the whole point of the niche is that the word is `ptr|tag` with no separate type descriptor (no Swift-style value-witness table; §6). A pure-runtime "am I niched?" check inside the body is impossible without materializing per-instantiation metadata, which is option B in disguise. **However, A's *spirit* — type-independent niche reads — is correct and is realized by (D) at the call site, where the static type IS known.**

### Option (B) — monomorphize the Result combinators

*Give each `Result<concrete,concrete>` instantiation its own combinator body that sees the niche layout.* **Feasible but rejected as the primary mechanism (over-engineered for M2).**
- **Precedent exists, partially:** Quartz already monomorphizes (1) generic *struct* methods (A.36, `mir_lower.qz:1090`), (2) generic-over-`@value` structs (B.10 §12.9, `mir_lower.qz:3402` — synthesizes `Box$P` with inline layout), (3) *bounded* generic free functions (PASS 0.9, `mir_lower.qz:6436`), (4) structurally-constrained/UFCS free functions (PASS 0.95, `mir_lower.qz:6488`). So the machinery to specialize a free function per-instantiation is NOT new.
- **Blast radius:** the Result combinators are *unbounded, non-UFCS* generics — none of the existing triggers fire. Adding "monomorphize when an arg is a niche-multi enum" is a NEW trigger class. Risk: combinatorial body duplication (`result_map<T,E,U>` × every distinct `(T,E,U)` niche instantiation), self-compile-time growth (D8/MEMORY_MODEL_V3 §1.5's MLton-avoidance concern), and a new specialization cascade to debug. The N3.2 history shows the asymmetry chase is already the cost center; B multiplies the surface.
- **When B *would* be needed:** if the niche read were type-DEPENDENT (different mask per instantiation), the erased body genuinely couldn't read it and B would be forced. But §2.3 shows the mask is `7` for all — so B buys nothing the type-independent intercept doesn't already give, at much higher cost. **B is the wrong tool because the mask is constant.**

### Option (C) — QZ0212-reject niched Result everywhere it meets a combinator

*Forbid a niched `Result` from reaching any erased combinator; force the user to match it directly.* **Rejected as primary — too ergonomically destructive.** `is_ok`/`is_err`/`unwrap_ok`/`result_map`/`?`/`try` are the *entire* `Result` API. If niching `Result` made all of them compile-errors on the niched path, niching `Result` would make `Result` unusable — a net negative. C is, however, the correct **fallback** for the long-tail combinators not worth intercepting (`result_map`, `result_map_err`, `result_and_then`, `ok`, `err` — the ones taking closures or returning new Results), exactly as QZ0212 backstops the un-intercepted Option combinators (§2.2).

### Option (D) — HYBRID (RECOMMENDED): type-independent interception + generalized QZ0212 backstop, NO monomorphization

Grounded in the §2.3 finding that the spare-mask is the compile-time constant `7`:

1. **Construct/read/bind:** lift the `enum_name == "Result"` early-outs in `mir_multi_enum_common_spare` (`mir.qz:7294-7295`) so built-in `Result<&A,&B>` becomes M1-classified and niches through the **already-shipped** M1 construct (`mir_lower.qz` NODE_ENUM_ACCESS niche branch), read-tag (`mir_get_enum_tag_niche` `mir.qz:7961`, `& 7`), and bind-mask (`mir.qz:8046-8074`, `& ~7`) seams. Zero new layout code — the M1 seams are payload-type-agnostic.
2. **`?`/`try` (blocker #2):** extend `mir_lower_try` to consult a new `mir_subject_is_niche_multi` for the Result subject, mirroring the existing `try_niche` Option branch. The niche read is `tag = OP_AND(expr_val, 7)`, `Ok ⇔ tag == 0`, `Ok payload = OP_AND(expr_val, ~7)`, `Err early-return = expr_val` (the whole niche word). Type-independent — no concrete `T,E` needed.
3. **Hot combinators (blocker #3, primary):** call-site-intercept the high-traffic, non-closure `Result` combinators — `is_ok`/`is_err`/`unwrap_ok`/`unwrap_err`/`unwrap_or_ok`/`result_or` (and their `$`-suffixed prelude UFCS wrappers) — exactly as the Option `is_some`/`unwrap`/`unwrap_or` block (`mir_lower_expr_handlers.qz:1690-1751`) does. When the receiver arg is a niche-multi Result: `is_ok` → `OP_EQ(OP_AND(v,7), 0)`; `unwrap_ok` → `OP_AND(v, ~7)`; `unwrap_or_ok(v,d)` → `OP_AND(v,7)==0 ? OP_AND(v,~7) : d`; `is_err` → `OP_NE(OP_AND(v,7),0)`; `unwrap_err` → `OP_AND(v,~7)`. The erased body is never entered.
4. **Cold combinators (blocker #3, backstop):** for `result_map`/`result_map_err`/`result_and_then`/`ok`/`err` (closure-taking or Result-returning — interception is messier and lower-value), **generalize QZ0212 with `mir_subject_is_niche_multi`** (§5) so a niched Result into these erased bodies is a clean compile-error with a "match it directly / use the intercepted combinator" hint. This is option C scoped to exactly the combinators where interception isn't worth it.

**Recommendation: (D).** It is the minimum machinery that clears all three blockers, reuses the proven M1 seams and the proven Option-interception pattern verbatim, introduces NO new monomorphization (avoiding the self-compile-time and cascade-debugging cost), and is sound by the same call-site-intercept-or-QZ0212-reject invariant that already holds for boxed Option. The decision hinges entirely on the §2.3 crux: **because the mask is `7` for every instantiation, the read is type-independent, so the call site (which knows the concrete type) can emit the read inline and the erased body never needs to.**

---

## 4. The construct/read/try/combinator seam changes

| Seam | File:line | Change |
|---|---|---|
| Classifier early-out | `mir.qz:7294-7295` | Remove `return none_spare if enum_name == "Option"/"Result"` for `Result` (keep `Option` out — it has its single-payload path). Gate behind a new `mir_multi_niche_result_live()` defaulting **0** (scaffold-inert, per N3 discipline). |
| Construct | `mir_lower.qz` NODE_ENUM_ACCESS niche branch | No change — already type-agnostic; fires once `Result` classifies as NICHE_MULTI. `Ok(x)` → `OP_OR(x, 0)` = identity, `Err(x)` → `OP_OR(x, 1)`. |
| Read tag | `mir_get_enum_tag_niche` `mir.qz:7961-7965` | No change — already masks `& spare_mask`. |
| Bind mask | `mir_set_pending_inline_for_enum` `mir.qz:8046-8074` | Lift the `enum_name != "Result"` guard (line 8054) so a niche Result payload binding masks `& ~7`. |
| `?` / `try` | `mir_lower_expr_handlers.qz:457,468,489` + `:375,385,394` | Replace `mir_subject_is_niche_option` with a combined `is_niche_option \|\| is_niche_multi` check; for the multi case use `tag = AND(v,7)`, `payload = AND(v,~7)`. NODE_TRY_CATCH (357-440) needs the same niche branch added (currently pure-spill). |
| Hot combinators | `mir_lower_expr_handlers.qz` (new block ~after 1751) | New interception block mirroring the Option block, matching `is_ok`/`is_err`/`unwrap_ok`/`unwrap_err`/`unwrap_or_ok`/`result_or` + `$`-suffix wrappers, gated on `mir_subject_is_niche_multi(arg0)`. |
| Cold combinators | QZ0212 `mir_lower_expr_handlers.qz:1753-1813` | Generalize to also scan niche-multi args (§5). |

---

## 5. The QZ0212-multi erased-boundary design

`mir_subject_is_niche_multi(ctx, s, subject_node) → Int` (NEW, in `mir.qz` beside `mir_subject_is_niche_option` at 7971) returns 1 iff the subject's **concrete static type** is a niche-multi enum:

1. Recover the subject's concrete enum type from its annotation/var-type (the same `mir_*_subject_payload`/`mir_ctx_get_var_type` plumbing the Option path uses). For a niche `Result` this is `Result<&A,&B>` with both args concrete-and-boxed.
2. Return `mir_multi_enum_is_niche(ctx, concrete_enum_name)` (`mir.qz:7385`) — which already returns 1 only for gated, eligible niche-multi enums. (For `Result` this requires both type args resolve to boxed types; a `Result<Int,String>` is NOT niche-multi, classifies SPILL, returns 0 — correctly not flagged.)

**QZ0212 scan generalization** (`mir_lower_expr_handlers.qz:1768-1813`):
- The `n_dg_any_niche` pre-scan (1771-1775) ORs in `mir_subject_is_niche_multi(arg)` alongside the Option check.
- The per-param mismatch test (1791-1808): for a niche-multi arg whose param annotation starts with `"Result<"`, ERROR iff any type argument of the param's `Result<…>` is a **type variable** (erased) — i.e. the param is `Result<T,E>` (generic body) not `Result<&A,&B>` (concrete, would read correctly only if the body is itself monomorphic, which for the std combinators it is NOT). Conservative rule: a `Result<…>` param with ANY non-concrete type arg, fed a niche-multi arg, errors.
- Diagnostic mirrors the Option message shape (1801-1803): name the variant set (`Ok`/`Err`), the offending type variable, and hint "match the Result directly, or use is_ok/unwrap_ok (intercepted), or give a concrete `Result<&A,&B>` parameter."

**Soundness floor (ratified posture, unchanged from M1 §5):** QZ0212-multi must be CONSERVATIVE — false-error is acceptable (forbids a niche crossing an erasure; user matches directly or uses an intercepted combinator), false-accept is a SEGFAULT. Gate `mir_multi_niche_result_live()` stays **0** until the compiler-self `Result`-usage audit (every construction site of a niche `Result` in `self-hosted/` + `std/` proven to either be intercepted or QZ0212-caught) is green — the same gate-OFF-until-audited discipline that landed M1.

---

## 6. Prior art (how Rust/Swift handle niches across erased boundaries)

- **Rust — monomorphizes, so it's a non-issue.** Each `Result<i32, String>` is a distinct monomorphic type; the niche layout (`Option<Box<T>>` = one word, niche-filling per RFC) is computed per-instantiation at compile time, and every `match`/`?`/combinator body is a per-instantiation copy that sees that concrete layout. There is no erased body and no erased boundary. Rust pays for this in compile time and code size (the MLton-extreme MEMORY_MODEL_V3 §1.5 deliberately avoids). [Monomorphization (Rust book ch10)](https://doc.rust-lang.org/book/ch10-01-syntax.html), [Monomorphization (Wikipedia)](https://en.wikipedia.org/wiki/Monomorphization).
- **Swift — value-witness tables (the erased-model answer Quartz does NOT have).** Swift compiles generic bodies ONCE (erased, like Quartz), but each concrete type carries a runtime **value-witness table** with `getEnumTag`/`getEnumTagSinglePayload`/`destructiveInjectEnumTag` witnesses; the erased body calls the witness, which knows the concrete enum's extra-inhabitant/spare-bit layout. So Swift's erased body *can* niche-read — through a runtime indirection Quartz lacks. [The Swift Runtime: Enums](https://belkadan.com/blog/2020/10/Swift-Runtime-Enums/), [Multi-payload enum optimizations (Swift Forums)](https://forums.swift.org/t/multi-payload-enum-optimizations/65506), [Remove extra-inhabitant value-witness functions (apple/swift#21204)](https://github.com/apple/swift/pull/21204).
- **What Quartz's non-monomorphized model implies.** Quartz has neither Rust's per-instantiation bodies nor Swift's value-witness indirection. The §2.3 finding is what rescues it: **because the multi-payload mask is a compile-time constant `7`, Quartz does not NEED either** — the niche read is type-independent, so it can be emitted at the call site (where the concrete type is statically known) and the erased body is bypassed (intercept) or forbidden (QZ0212). This is a Quartz-specific shortcut available *only* because representation uniformity makes the spare bits constant; it would not work for Swift/Rust whose differently-shaped payloads give per-type masks. The win is real and the mechanism is sound, but it is narrower than a general value-witness scheme — it covers exactly the constant-mask boxed case (which is the whole M1/M2 scope).

---

## 7. Staged plan (smallest first) + spec coverage (TDD)

### Phase M2.0 — `mir_subject_is_niche_multi` + QZ0212-multi, gate-OFF (keystone, fixpoint-trivial)
- Add `mir_subject_is_niche_multi` (`mir.qz`) + `mir_multi_niche_result_live()` returning **0**. Generalize the QZ0212 scan to call it. With the gate 0, `Result` still SPILLs (the `enum_name == "Result"` early-out stays until M2.1), so this is pure dead-code addition.
- **Spec:** `spec/qspec/result_niche_classify_spec.qz` (unit) — `mir_subject_is_niche_multi` returns 1 for a niche-multi user enum, 0 for `Result` (still gated off), 0 for spill enums.
- **Acceptance:** zero IR diff vs golden, gen1==gen2, full qspec green.

### Phase M2.1 — lift the `Result` early-out + wire `?`/`try`/hot-combinator intercepts, gate-OFF scaffold
- Lift `mir.qz:7295` behind `mir_multi_niche_result_live()`. Add the `?`/`try`/`try-catch` niche branches (§4) and the hot-combinator interception block (§4 step 3). All gated ⇒ inert at gate 0; prove IR byte-identical vs golden for `style_demo`, `brainfuck`, and a `Result<Vec,String>` program (the M1 inertness-proof method, MEMORY_MODEL_V3 §14.9 "Inertness PROVEN").
- **Spec:** `spec/qspec/result_niche_runtime_spec.qz` — construct `Ok(v)`/`Err(s)` of `Result<Vec<Int>,String>`, round-trip through `match`, `?`, `is_ok`/`is_err`/`unwrap_ok`/`unwrap_err`/`unwrap_or_ok`; assert correct arm + payload intact. (Differential oracle: same spec passes under both gate states.)
- **Spec:** alloc-free oracle — the `Ok`/`Err` construction site emits NO `__qz_alloc`/`alloca [2 x i64]` (the niche-on check; same oracle as `option_boxed_struct_niche_spec`).

### Phase M2.2 — compiler-self `Result` audit + supervised flip (the one-way gate)
- Audit every niche-eligible `Result` construction in `self-hosted/` + `std/` (the §5 flip gate). For each, prove it is either (a) intercepted (hot combinator / `?` / direct `match`) or (b) QZ0212-caught (cold combinator). The cold combinators (`result_map`/`result_and_then`/`ok`/`err`) are the risk surface — confirm the compiler's own error-threading doesn't route a niche Result through them, or convert those sites.
- Flip `mir_multi_niche_result_live()` → 1 throwaway; verify guard fixpoint gen1==gen2, Rule-2 smokes (style_demo + brainfuck), full qspec green, zero regressions. Commit the gate at 1 only after the audit is green.
- **Spec:** `spec/qz/result_niche_qz0212.qz` (standalone, expect compile failure) — a niche `Result<Vec,String>` passed to `def f<A,B>(r: Result<A,B>)` errors with QZ0212-multi, not a crash.
- **Spec:** `spec/qz/result_niche_poll_smoke.qz` (standalone `def main`, real worker spawn per the CLAUDE.md qspec caveat) — construct a niche Result, suspend across `sched_yield`, resume, assert variant + payload survive (the single-i64-SSA-value save-set invariant, RFC §4 / ratification Q7).
- **Spec:** `Vec<Result<Vec,String>>` element-position round-trip (the shipped `Vec<Option<T>>` element-niche analog) — push/get round-trip, no per-element box.

### Phase M2.3 (deferred, named) — cold-combinator interception
If the audit finds the cold combinators (`result_map` etc.) are load-bearing on the niche path and QZ0212-rejecting them is too ergonomically costly, intercept them too (closure-aware) OR introduce the option-B selective monomorphization ONLY for them. Filed, not v1.

---

## 8. Does built-in `Option` niching ride along?

**No — it stays separate, and that is correct.** Built-in `Option<boxed-T>` ALREADY niches today via the **single-payload** path (`mir_option_is_niche`/`mir_option_none_const`, gate `mir_boxed_niche_enabled()` = 1) — it is NOT on the spill path the task's framing implies for "built-in Option (currently spill)". The single-payload Option niche (none_const = 0 for boxed, `mir.qz:7623`) is a *different mechanism* from the multi-payload `payload|tag` packing, and it shipped in N3.1/N3.2. The `mir_multi_enum_common_spare` early-out keeps `enum_name == "Option"` OUT of the multi-payload classifier (`mir.qz:7294`) precisely because Option has its own, better, dedicated single-niche path — routing it through multi-payload would be a regression (it would need a tag bit it doesn't need). **M2 lifts only the `Result` early-out; the `Option` early-out is permanent and correct.** (If the task's premise is that some specific built-in `Option` *instantiation* is on spill, that is a separate gap to file, not part of M2 — M2 is `Result`-only.)

---

## 9. Go / no-go + RATIFICATION QUESTIONS

### Go / no-go honesty

| Sub-case | Verdict | Reasoning |
|---|---|---|
| `Result<&T,&E>` / `Result<Vec,String>` / `Result<struct,struct>` niche | **GO (M2.1-M2.2)** | Same layout as M1; mask is the constant `7`; reads type-independent; reuses shipped seams. |
| `?` / `try` / `try-catch` over niche Result | **GO** | Type-independent niche branch, mirrors the Option `try_niche` path. |
| `is_ok`/`is_err`/`unwrap_ok`/`unwrap_err`/`unwrap_or_ok`/`result_or` | **GO (intercept)** | Non-closure, hot — call-site interception, erased body bypassed. |
| `result_map`/`result_map_err`/`result_and_then`/`ok`/`err` (cold/closure) | **GUARDED — QZ0212-multi reject** | Erased bodies; conservative compile-error on niche arg; intercept deferred to M2.3. |
| `Result<Int,String>` / `Result<Int,Int>` (any scalar payload) | **NO-GO — SPILL (correct)** | Scalar has no spare bit; `common_low_zero = 0`; tagged box, byte-identical to today. The information-theoretic floor (RFC §8). |
| Built-in `Option` via multi-payload path | **NO-GO (permanent)** | Has its dedicated single-payload niche; §8. |
| Compiler-self `Result` across cold erased combinators | **RISK — gated** | The N3.2 asymmetry chase recurs; gate-OFF-until-audited is the mitigation. |

**Explicit verdict: GO for M2 under architecture (D)**, contingent on the M2.2 compiler-self audit proving no niche `Result` reaches a non-intercepted, non-QZ0212-guarded erased combinator. The layout is solved (M1); the only real cost is the audit/asymmetry chase, which the staging contains. **No new monomorphization is required** — the §2.3 type-independent-mask finding is what makes B unnecessary.

### RATIFICATION QUESTIONS (the human must approve before M2 code)

1. **Architecture = (D) hybrid.** Ratify: type-independent call-site interception for hot `Result` combinators + `?`/`try` + generalized QZ0212-multi backstop for cold combinators, with **NO new monomorphization** of the Result combinators. Grounded in: the multi-payload spare-mask is the compile-time constant `7`, hence the niche read is type-independent and the erased body can be bypassed at the call site. Yes/adjust?

2. **Hot/cold combinator split.** Ratify the intercept set = {`is_ok`, `is_err`, `unwrap_ok`, `unwrap_err`, `unwrap_or_ok`, `result_or`} (+ `$`-suffix UFCS wrappers) and the QZ0212-reject set = {`result_map`, `result_map_err`, `result_and_then`, `ok`, `err`}. Is QZ0212-rejecting the closure-taking combinators on the niche path an acceptable v1 ergonomic cost (user matches directly), with full interception deferred to M2.3? Yes/adjust?

3. **`?`/`try-catch` niche-awareness.** Ratify extending both NodeTryExpr AND NODE_TRY_CATCH in `mir_lower_try` with the type-independent multi-niche read (`tag=AND(v,7)`, `payload=AND(v,~7)`). Yes/adjust?

4. **QZ0212-multi conservatism.** Ratify the guard is conservative (false-error acceptable, false-accept forbidden) and that `mir_multi_niche_result_live()` stays 0 until the compiler-self `Result`-usage audit is green — the M1 gate-OFF-until-audited discipline. Yes/adjust?

5. **Single-SSA-value invariant carries to `Result`.** Ratify RFC §4's invariant for built-in `Result`: a niche `Result` local is exactly one i64 SSA value (`ptr|tag`), never a (pointer-alloca, tag-alloca) decomposition — the save-set/`$poll` soundness depends on it. Yes/adjust?

6. **`Option` stays on its own path.** Ratify that M2 lifts ONLY the `Result` early-out in `mir_multi_enum_common_spare` (`mir.qz:7295`); the `Option` early-out (line 7294) is permanent — built-in Option keeps its dedicated single-payload niche, not the multi-payload packing. Yes/adjust?

7. **Audit-cost acknowledgment.** Acknowledge that the load-bearing cost of M2 is the compiler-self `Result`-usage audit (the N3.2 asymmetry chase), NOT the layout math, and that this is normal multi-session work (D4) gated by the supervised flip. Yes?

8. **Scalar-payload `Result` floor is correct.** Acknowledge `Result<Int,String>` etc. SPILLing (no common spare bit) is the ratified, correct behavior — not a gap to close. Yes?
