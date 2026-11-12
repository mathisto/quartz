# F4 alias-safety — design decision memo

> ## ✅ RATIFIED 2026-06-23 (owner): **value-default structs.** Plain `struct`s become value types (Swift/Hylo model — `var b = a` copies). Proceed Option A: value-copy → CoW → resolve residual F4 items → flip. The ~106-setter-site fixpoint audit is accepted as intentional. This is now the canonical plan for B.10 Phase 4 / the F4 flip.

> ## ✅ CLOSED 2026-07-04: **borrow-exclusivity hazard.** Option A dissolved the *assignment-path* alias hole (`var b = a` copies). But item-20 later added **second-class borrows** — `&mut self` / `&self` receivers and `&x` / `&mut x` expressions (`BORROW_RECEIVER_CONVENTION.md`) — which reopened an aliasing/escape hazard the pure copy story did not cover: a borrow could overlap another access in the same call, or escape its call-scope. That hazard is now **caught by a static exclusivity pass** (`middle/exclusivity.qz`, runs in `tc_function`): **QZ0408** rejects a call passing overlapping places where ≥1 is a `&mut` borrow (`f(&mut x, x)`, `f(&mut x, &mut x)`, `recv.set(&mut recv)`), and **QZ0409** rejects a second-class borrow that escapes (stored into a field/element, returned, or captured into an escaping closure). Both are hard errors (`81ad07c8`). Enforcement is **static, base-only**; the projected-place (`&mut p.f`/`&mut a[i]`) lowering and the dynamic `--exclusivity-check` runtime path are the **remaining tail** (in progress / next). This is the "add a check" answer to `BORROW_RECEIVER_CONVENTION.md` §7 Q#2 — Swift's static half of the Law of Exclusivity.

**Date:** 2026-06-23   **Gates:** the F4 flip (`mir_default_struct_value_live` 0→1).
**Question:** when plain `struct`s become stack values, how do we prevent "local `b` aliases local `a`'s stack and outlives it" — without Rust-style lifetimes (Stance 1)?

## The hazard (concrete)
```qz
struct Point { x: Int; y: Int }     # plain struct, F4-eligible
def bug(): ... 
  var a = Point { x: 1, y: 2 }      # post-flip: alloca at fn_entry
  var b = a                          # REFERENCE-PRESERVING flip → b is a POINTER copy into a's alloca
  # ... a's scope ends, slot reused ...
  b.x                                # use-after-scope
```
The flip is **reference-preserving**: `var b = a` copies the pointer, so `b` aliases `a`'s stack slot. Quartz's escape analysis (`mir_compute_escaped_regs`) heap-promotes structs that escape via return/heap/closure, but it does **not** track local-to-local alias-outlives. That's the hole.

**Key fact:** `@value` structs do NOT have this hole — `var b = a` triggers `mir_emit_value_copy` (copy-on-assign), so `b` is independent; there is no pointer to outlive. The hazard exists *only* because the naive F4 flip gives plain structs value-**layout** without value-**semantics**. Layout and semantics are coupled: flipping layout safely requires adopting copy-semantics.

## The three options
| Option | Mechanism | Verdict |
|---|---|---|
| **A. Value-copy + CoW** (Swift/Hylo) | `var b = a` copies (as `@value` already does); recover cost with the already-designed CoW (uniqueness-checked) + move-on-last-use. Alias hole **structurally impossible** — no pointer to outlive. | ✅ **RECOMMENDED** |
| **B. Escape-analysis extension** | Teach `mir_compute_escaped_regs` to detect aliased-then-outlived locals and heap-promote them. | ⚠️ Possible but unsound-by-omission risk; the field uses escape analysis only as a copy-elision *optimization*, never the safety story. |
| **C. Scope-restriction** | Add "non-escaping/non-aliased" as an F4 eligibility exclusion. | ❌ No existing machinery; needs whole-program alias analysis; excludes most structs; defeats the flip. |

## What the world does (lifetime-free value-semantics languages)
Unanimous: **make `=` a copy, make references second-class & non-escaping, recover cost with CoW/move.** Escape analysis is *only* an optimization, never the safety mechanism.
- **Swift** — value types copy on assign; CoW via `isUniquelyReferenced` (unique ⇒ mutate in place, else copy); `inout` = copy-in/copy-out (call-scoped, can't escape); Law of Exclusivity (SE-0176, static+dynamic); `borrowing`/`consuming` (SE-0377) to elide copies. No lifetimes.
- **Hylo** (the model Quartz explicitly committed to) — "mutable value semantics"; **no first-class references at all** → alias-outlives impossible by construction; `let`/`inout`/`sink`/`set` conventions replace references; `yield`-projections give "view into a field" ergonomics that provably can't be stored. No lifetimes.
- **Koka/Perceus** — RC value semantics; refcount==1 ⇒ reuse-in-place (FBIP), else copy (the RC twin of Swift's uniqueness check); borrowed params skip dup/drop. A would-be escaping ref just keeps RC≥1 → can't dangle. No lifetimes.
- **Zig** — the anti-model: passes by value-or-ref at compiler discretion (RLS), documents the UB; doesn't give the property and *manufactures* aliasing bugs. Do not adopt.

Citations: Swift CoW/exclusivity/SE-0377; Hylo language tour + "Memory Safety without Lifetime Parameters" (safecpp.org) + "Borrow checking Hylo" (SPLASH 2023); Perceus (PLDI 2021), FP² (ICFP 2023); Zig #287/#12251/#5725. (Full URLs in the conductor research log.)

## Why A fits Quartz specifically
1. **Machinery exists.** `mir_emit_value_copy` is live with 5 call sites, gated on `mir_ctx_is_value_struct`. Extending to plain structs = widen those guards. CoW is already designed (`cow-reconciliation.md`) keyed on the shared `mir_is_value_layout_type` predicate — build once, F4 inherits it.
2. **Stance 1 (no lifetimes)** rules out scope/lifetime tagging. A needs none — it's pure semantics.
3. **Quartz already committed to "Hylo's design point"** (ROADMAP Stance 1). Option A *is* that design point.
4. **B and C aren't how anyone gets soundness** — betting safety on escape analysis (B) is a novel riskier path the field implicitly rejected; C is Hylo's borrow path misapplied to the assignment path.

## The real decision (yours)
Option A means **plain structs become value types** (Swift-style): after the flip, `var b = a` copies, so `b.x = 5` no longer mutates `a`. That is:
- ✅ The expected model for a systems language (C/Zig/Swift/Go all have value-default structs); consistent with Quartz's stated Hylo commitment; unlocks the layout/perf/FFI wins the F4 epic is *for*.
- ⚠️ A **semantic change** to plain structs (today they're reference-shared heap handles), and it requires the **~106-setter-site fixpoint audit** (the compiler's own code relies on plain-struct reference-sharing in ~106 places — those must be confirmed correct, or restructured, under copy semantics).

**The alternative** is to NOT flip F4: keep plain structs as reference types and leave value types opt-in via `@value`. That's the status quo — value types work today, just annotation-gated.

## Recommended sequencing (if A)
1. **Extend value-copy to plain structs** (widen the `mir_emit_value_copy` guards) — behind the existing `mir_value_semantics_live` discipline; eager copy first (correct, maybe slow).
2. **Build CoW** (uniqueness-checked, à la Swift/Koka) on the shared layout predicate — makes the copy cheap for `@value` AND plain.
3. **Resolve the residual F4 items** (return-ABI threading, landmines, firewall policy, GC scan_map).
4. **Flip F4** (gen2==gen3 bootstrap) — plain structs inherit copy+CoW for free.
5. Later: move-on-last-use + borrow/`inout` conventions + projections for copy-elision ergonomics (optimization, not safety).

The alias hole is not a separate hard problem — it dissolves the moment plain-struct assignment is a copy. The decision is really **"are Quartz's default structs value types?"** — and the prior art + Quartz's own stances say yes.
