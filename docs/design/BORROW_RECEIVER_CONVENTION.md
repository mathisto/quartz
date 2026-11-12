# Borrow / mutable-ref receiver convention for value-struct mutating methods

> **Status (2026-07-02):** ✅ **COMPLETE (Phases 1–7 LANDED).** Phases 1 + 2
> (`d32ea287`, `2eb5fc92`), Phase 4 (`f74c0a02`), Phase 5 (`c4b10ded`), Phase 6
> (`908d7742`), **Phase 7** (`0611c6f9` surface + owner-Q#5 consolidation, `7ee4d23b`
> QZ0407 enforcement + migration, branch `conductor/value-semantics-s26-2026-07-02`).
> The borrow-receiver convention is now the sole, unified mutating-value-self ABI across
> both size regimes, with transitive self-mutation and own-on-insert container-key
> lifetime covered, an **explicit enforced `&mut self` / `&self` receiver surface**, and
> the two detection predicates **consolidated** onto one hoisted verdict (owner-Q#5).
> **Update (2026-07-04):** the **alias/exclusivity checking** that this receiver surface
> was landed as the anchor for has now **LANDED** — a new middle pass
> `middle/exclusivity.qz` runs in `tc_function` right after the QZ0407 block and emits
> **QZ0408** (static exclusivity conflict) and **QZ0409** (non-escape violation) as
> **hard errors** (flipped to hard-error `81ad07c8`). Static, base-only enforcement is
> done; the projected-place (`&mut p.f`/`&mut a[i]`) lowering and the dynamic
> `--exclusivity-check` runtime path are the remaining forward-looking tail (in
> progress / next). See §7 Q#2 and the "Law of Exclusivity" note below.
> This memo is the design of record for **item-20** ("mutable-ref / borrow receiver
> convention"). It is DESIGN-ONLY; no code is changed by this document.

**Epic:** B.10 / F4 value-default structs (LANDED — `mir_default_struct_value_live()`
returns 1). **Related memos:** `F4_ALIAS_SAFETY.md` (the value-copy+CoW decision
this convention is the copy-elision counterpart to), `MEMORY_MODEL_V3.md`,
`cow-reconciliation.md`.

---

## 1. Problem

Under the F4 flip, plain `struct`s are value types with **by-value-move** receiver
ABI. A method that mutates `self` (`self.field = ...`, or an iterator advancing
`self.cursor`) cannot persist the mutation, because by-value-move means the callee
operates on a *copy* the caller never reads back. The failure splits by struct
size, and each regime fails for a different low-level reason:

### 1a. ≤16B (flat, non-CoW) value struct — register decomposition

A ≤16B value struct is **register-decomposed**: its fields are exploded into scalar
arguments (`mir_func_should_decompose_value_params` /
`mir_func_param_is_decomposed`, `mir.qz:2899`/`2932`) and the callee rebuilds a
local `self` from those scalars. Any `self.field = ...` mutates that callee-local
reconstruction, which is discarded on return.

```qz
struct Point { x: Int; y: Int }          # 16B, decomposed
def bump(self): Void = self.x = self.x + 1   # mutates a throwaway
def main(): Int
  var p = Point { x: 1, y: 2 }
  p.bump(); p.bump()
  return p.x                             # WANT 3, GOT 1 (mutation lost)
end
```

### 1b. >16B (CoW-layout) value struct — droppable-param release + make-unique fork

A >16B value struct uses the copy-on-write layout `[rc@word0, fields...]`. Under
by-value-move, three things conspired to destroy the mutation:

1. **Call-site retain** — the receiver arg was value-copied, emitting `cow_rc_inc`.
2. **Callee release** — the by-value `self` param was registered *droppable*
   (`push_droppable`, `mir_lower.qz:6240`/`6825`; `type_needs_drop`), so the callee
   emitted a scope-exit `cow_release` (rc-dec + free-at-zero) on `self`.
3. **Make-unique fork** — because the retain pushed rc to 2, the first
   `self.field = ...` triggered `mir_emit_cow_make_unique` (`mir_lower_stmt_handlers.qz:1394`),
   forking a private copy; the write landed on the fork, which the callee then freed.

Net: `c.bump()×3` printed 0, and the for-in CoW-iterator analog hung / summed 0 /
infinite-looped. Crucially, a *naive* fix ("just add the missing call-site retain")
makes it **worse**: rc==2 at the mutation → make-unique forks → the callee advances
the fork → the fork is freed at callee exit → the caller's buffer never advances →
infinite loop. The three effects are coupled and must be resolved *together*.

Both regimes have the same root: **a mutating value-self receiver needs to be a
borrow of the caller's slot, not a moved-in copy.** This is item-20.

---

## 2. Prior art

Design Directive 2: every lifetime-free value-semantics language that solves this
converges on the same shape — **the mutating receiver is a pointer to the caller's
storage, exclusive (no aliasing), and neither copied in nor dropped by the callee.**
The differences are in *how much of that is checked* and *how the small-vs-large
split is handled*.

### Rust — `&mut self`
`&mut self` is an **exclusive** mutable borrow, passed as a pointer. Exclusivity is
enforced statically by the borrow checker (one `&mut` at a time). At the ABI/LLVM
level `&mut` carries `noalias` (`dereferenceable`), letting the optimizer assume no
other access touches the pointee — the same guarantee our convention wants, arrived
at by type system rather than by inference. Rust does **not** register-decompose the
receiver away: `&mut self` is always the pointer, uniformly across sizes. *Borrow:
the "pointer to caller slot, callee does not drop it" ABI, and the noalias/exclusive
framing. Don't borrow: a full lifetime/borrow-checker layer — Quartz is Stance-1
(no lifetimes), matching Hylo.* ([rust-lang/rust#31681](https://github.com/rust-lang/rust/issues/31681),
[rust noalias story](https://medium.com/@trivajay259/why-rust-doesnt-always-restrict-your-mut-the-real-story-behind-noalias-fa8f5e623fef))

### Swift — `mutating func` / `inout`
`mutating func` is **sugar for an `inout self`**. `inout` is formally
**copy-in/copy-out** (copy arg in, mutate the local, copy back on return) but the
optimizer routinely lowers it to **in-place mutation through a pointer** when it can
prove exclusivity. Exclusivity is the **Law of Exclusivity** (SE-0176): a variable
being mutated through `inout`/`mutating self` cannot be accessed under another name
for the duration — enforced statically where possible, with dynamic checks for the
escaping/global residue. For CoW value types Swift pairs this with
`isUniquelyReferenced` (unique ⇒ mutate in place, else copy). *Borrow: `mutating` ≡
`inout self` — our convention is exactly "inout self" specialized to CoW; the
uniqueness check IS our make-unique, and skipping it for a known-exclusive borrow is
what P2 does. Don't borrow: the copy-in/copy-out *semantics* as the model — we go
straight to in-place (the optimizer's happy path) because our borrow is exclusive
and non-escaping by construction.* ([Swift exclusivity](https://www.infoq.com/news/2019/02/swift-5-exclusive-memory-access/),
[inout params](https://medium.com/@mail2devcrew/understanding-in-out-parameters-in-swift-00382154dac8))

### Hylo / Val — `inout` / `set` / mutable projections (closest to Quartz)
Hylo is the model F4 explicitly committed to: **mutable value semantics, no
first-class references**. Its four parameter conventions are `let` (immutable
borrow), `inout` (mutable exclusive borrow), `sink` (consuming/owned), `set`
(initialize). `inout` "behaves almost exactly like Swift's": the argument must be
**unique and mutable**, marked `&` at the call site; the callee may do anything
(even temporarily invalidate) *as long as it puts a value back before returning*.
Mutable access to a field is a **`inout` subscript / mutable projection** — a
"view into the storage" that provably **cannot be stored/escape**. Because there
are no first-class references, alias-outlives is impossible *by construction* — no
lifetimes needed. *Borrow: `inout self` as the exact semantic (exclusive mutable
projection of the caller's storage, put-back-before-return); the "projection can't
escape" property is what makes our transitive-self and struct-key phases sound.
This is the destination.* ([Hylo functions/methods](https://docs.hylo-lang.org/language-tour/functions-and-methods),
[val-for-swift-users](https://github.com/hylo-lang/Documentation/blob/main/val-for-swift-users.md))

### Mojo — `inout` (now `mut`) / `borrowed` / `owned`
Same convention triad. Notably Mojo **does not enforce exclusivity for
register-passable trivial types** (Int/Bool) "as they're always passed by copy" —
i.e. it explicitly carves the small-scalar case out of the exclusive-borrow
machinery. This directly validates Quartz's size-split instinct, but in reverse:
Mojo keeps *small* things copy-by-value and reserves the borrow ABI for *memory-only*
types. Quartz's ≤16B decompose regime is the analogue — except a *mutating* small
receiver still needs the pointer (see §4). ([Mojo ownership](https://docs.modular.com/mojo/manual/values/ownership/))

### Synthesis — what Quartz adopts
- The **ABI**: mutating value-self = pointer to caller's slot; callee does **not**
  drop it; mutations write back through the borrow. (Rust `&mut self` / Hylo `inout`.)
- The **CoW interaction**: an exclusive borrow means rc is effectively 1 from the
  borrow's viewpoint → **skip make-unique**, mutate in place. (Swift uniqueness.)
- The **exclusivity story**: Quartz is Stance-1 (no lifetimes). We get exclusivity
  the Hylo way — the receiver borrow is a non-escapable projection created and
  consumed within the single call, so no aliasing window exists that a checker would
  need to police. We rely on **construction**, not a borrow checker, exactly as
  `F4_ALIAS_SAFETY.md` decided for the assignment path.
- The **small/large split**: keep it (Mojo confirms it's principled), but note that
  *mutation* forces the pointer even for ≤16B — decomposition is a read-only
  optimization and must be suppressed for a mutating receiver (§4, §1a).

---

## 3. What is already built (Phases 1 + 2)

The two shipped phases already implement the convention for the two size regimes as
**separate, size-gated point-fixes**. The convention (§4) is their generalization.
Everything below is **gate-0-inert**: keyed on value-layout / CoW-layout predicates
that are false for plain structs at `mir_default_struct_value_live() == 0`, so
flip=0 self-compile is byte-identical (verified: fixpoint 3173 → 3176 fns, byte-clean).

### Shared markers
- **`mutates_self_field`** (`mir.qz:178`, getter/setter `mir.qz:3047`/`3049`) — a
  MirFunc bit set during lowering (`mir_lower.qz:6274`/`6873`) via
  `mir_body_assigns_self_field` when the body directly stores to `self.<field>`.
  Serialized as **qzmod flag bit 5** (`qzmod_emit.qz:1329` = `×32`, loaded
  `qzmod_load.qz:936`) so cached method bodies retain the marker across modules.
  **Direct-assignment only** — a method that mutates self *via a callee* is not
  detected (the transitive gap, §5).

### Phase 1 — ≤16B non-CoW (`d32ea287`)
The loss was **call-site**, not decompose: the callee already loads/stores through
its param-0 pointer once decompose is suppressed. Two hooks:

- **Callee side — decompose suppression.**
  `mir_func_param0_is_mut_value_receiver` (`mir.qz:2889`) returns 1 iff param0 is
  named `self`, `mutates_self_field == 1`, and param0's type is value-layout
  (`mir_prog_is_value_layout_type`). When 1, `mir_func_param_is_decomposed`
  (`mir.qz:2934`) and `mir_func_should_decompose_value_params` (`mir.qz:2915`)
  exclude param0 → it stays a single construct-buffer pointer, mutated in place.
- **Call site — copy elision.** `mir_callee_is_mut_value_receiver`
  (`mir_lower_expr_handlers.qz:57`) recomputes the same verdict from the callee AST
  (the call lowers before the callee). The subtle bug it fixes: the verdict was
  originally computed against the *unmangled* `func_name` (`bump`) before receiver-
  type dispatch resolved `p.bump()` → `Point$bump`, so `mir_lookup_function` missed
  and the elision never fired. The fix adds a **receiver-type-mangled fallback**:
  recover the receiver's tracked var-type, strip generics, `mangle(Type$func)`,
  re-run the predicate. When 1, the receiver arg passes the caller's live slot
  pointer instead of `mir_emit_value_copy` (`mir_lower_expr_handlers.qz:3735`).

Spec: `value_mut_receiver_spec.qz` (probe flips 1→3).

### Phase 2 — >16B CoW (`2eb5fc92`)
Extends the same idea to CoW receivers via **three coordinated skips**, all gated on
"param0 = borrowed mutating value-self AND CoW-layout". Retain-skip and release-skip
move **together** so rc stays balanced (exactly one `atomicrmw sub` + one
`__qz_dealloc`; no leak, no double-free):

1. **Retain-skip.** `mir_callee_is_mut_value_receiver` no longer bails on CoW
   (`mir_lower_expr_handlers.qz:66-71`), so the P1 call-site elision passes the
   caller's live buffer pointer; the value-copy's only remaining effect on a CoW arg
   (the `cow_rc_inc`) is skipped along with the word-copy.
2. **Release-skip.** New `mir_func_node_is_borrowed_cow_self_receiver`
   (`mir_lower.qz:5714`) + `MirContext.borrowed_self_receiver` flag, set in **both**
   lowering paths (`mir_lower_function` `mir_lower.qz:6167`, and
   `..._with_name` `mir_lower.qz:6702`). It skips `push_droppable` for param0
   (`mir_lower.qz:6238`/`6823`) → no scope-exit `cow_release` on self. Flag cleared
   at function exit (`mir_lower.qz:6297`/`6969`).
3. **Make-unique-skip.** Field-assign carve-out (`mir_lower_stmt_handlers.qz:1378-1391`):
   when `borrowed_self_receiver == 1` and the receiver is the `self` IDENT, store in
   place with the +1 word shift (`mir_ctx_set_cow_field_shift`), bypassing
   `mir_emit_cow_make_unique`.

Also present: a **read-only non-self CoW-param borrow** generalization
(`mir_lower.qz:5735+`, conservative escape analysis) — a non-self CoW param proven
to be read-only (its bare name appears only as the object of a field access) is also
borrowed (no caller-retain / no callee-release). This is the `let`-convention
sibling of the `inout` self borrow, already partially built.

Spec: `value_mut_receiver_spec.qz` 7/7 (direct repro 0→3; `.step()`-loop CoW
iterator → 10, terminates).

### The narrow `$next` special-case (folded — Phase 4 ✅ DONE `f74c0a02`)
Predating both phases, `mir_func_param_is_next_receiver` (`mir.qz:2863`) excluded
param0 of any `*$next`-suffixed function from decomposition. This was the original
14A iterator fix and was a **strict subset** of
`mir_func_param0_is_mut_value_receiver` for `$next` methods that store `self.cursor`
directly. **Phase 4 (`f74c0a02`) folded it into the single unified borrowed-mutating-
value-self path**: `mir_func_param_is_next_receiver` was **DELETED** and the dead
decompose OR-in reconciled (removed) — see §5.

---

## 4. The convention

**A mutating value-self receiver is a *borrow*: `self` is passed as a pointer to the
caller's slot; the callee neither copies it in nor drops it; mutations write back
through the borrow in place.** This is `inout self` (Hylo) / `&mut self` (Rust) /
`mutating func` (Swift), unified across both size regimes. Phases 1 and 2 are the
two size-specialized realizations; the convention is the single rule they share.

### 4.1 When it fires (detection)
A method receiver is a **borrowed mutating value-self** iff ALL of:
1. param0 is named `self`;
2. param0's declared type is **value-layout** (`mir_is_value_layout_type` /
   `mir_prog_is_value_layout_type`) — **this is the gate-0-inert guard**: false for
   plain structs at flip=0, so the entire convention is dead code and self-compile
   is byte-identical;
3. the body **mutates self** — `mutates_self_field == 1` today (direct
   `self.field = ...`), extended to transitive mutation in a later phase (§5).

The CoW-vs-flat split (>16B vs ≤16B) is derived from `mir_value_is_cow_layout`, not
a separate detection axis — it only selects *which* skips apply (make-unique/release
exist only for CoW; decompose-suppression exists only for flat). A future
consolidation should express detection **once** (a single
`mir_func_receiver_is_borrowed_mut_self(func_or_node, prog/ctx)`) and let the layout
predicate fan out to the regime-specific emissions — collapsing today's parallel
`mir_func_param0_is_mut_value_receiver` (MirFunc) and
`mir_func_node_is_borrowed_cow_self_receiver` (AST) into one source of truth
computed at both sites.

### 4.2 The ABI, per regime
| Regime | Receiver passing | Callee treatment | Write-back |
|---|---|---|---|
| **≤16B flat** | caller's slot pointer (decompose suppressed) | loads/stores through param0 pointer | in place, automatic |
| **>16B CoW** | caller's buffer pointer, **no retain** | **no droppable / no `cow_release`**; **no make-unique** on `self.field` | store in place with +1 word shift |

Both cases: the receiver is a **single pointer**, never a copy, never dropped by the
callee. This is the Hylo "the callee may mutate freely but must leave a valid value
before returning" contract — trivially satisfied because we never *invalidate* the
buffer (no release, no fork).

### 4.3 Retain / release balance (CoW)
The invariant is: **retain-skip and release-skip are one atomic decision.** Skipping
the caller-retain *without* skipping the callee-release double-frees; skipping the
release *without* skipping the retain leaks. They are two faces of "this is a borrow,
not a move" and must never be gated independently. From the borrow's viewpoint the
buffer's rc is unchanged across the call — the caller still owns exactly one
reference before and after. Make-unique is skipped because an exclusive borrow, by
definition, sees rc==1 (no other live reference the fork would protect).

### 4.4 Read-only vs mutating receiver
`mutates_self_field == 0` ⇒ the receiver is a **`let`-borrow** (read-only): today it
takes the ordinary value-copy path for flat structs and the read-only-CoW borrow
(§3, `mir_lower.qz:5735+`) for CoW args. A read-only receiver must **never** get the
mutating skips — it does not mutate, so make-unique/release-skip would be both
unnecessary and (for a receiver that escapes via return of `self`) unsound. The
`mutates_self_field` bit is precisely the `inout` vs `let` discriminator; keep it
load-bearing.

### 4.5 Exclusivity (Stance-1, no lifetimes)
The borrow is exclusive by **construction**, not by a checker: it is created at the
call site (address-of the caller's slot), consumed within the single call, and never
stored or returned by the callee (the receiver name is a projection, not a value that
can escape — Hylo's property). There is no window in which a second name aliases the
mutated slot, so there is nothing for an exclusivity checker to police. This is the
same soundness argument `F4_ALIAS_SAFETY.md` makes for the assignment path
(alias-outlives is impossible because there is no escaping reference), applied to the
receiver path. **If** a later phase lets a borrowed projection flow further (nested
`o.q.a = ...`, transitive self-mutation), exclusivity must be re-argued at each
extension — see §5 / §7.

### 4.6 Gate-0 byte-identity (the backstop)
Every predicate in the convention short-circuits to 0 when
`mir_default_struct_value_live() == 0` (value-layout is false for plain structs), so
at flip=0 the entire convention is dead code and self-compile is byte-identical. This
is the non-negotiable invariant for every future phase: **any new hook must be
value-layout-gated so flip=0 fixpoint stays byte-clean.**

---

## 5. Remaining phases / implementation plan

Sequenced; dependencies and one-way-door status noted.

### Phase 4 — fold `$next` + reconcile decompose OR-in — ✅ DONE (`f74c0a02`)
**Outcome:** folded the 14A `$next` receiver exclusion into the single unified
`mir_func_param0_is_mut_value_receiver` borrowed-mutating-value-self path; **DELETED**
`mir_func_param_is_next_receiver`; reconciled (removed) the dead decompose OR-in.
Fixpoint **3235** (−1 = deleted predicate). Specs: `value_mut_receiver` 10/10,
`custom_iterator` 13/13, `iterator_protocol` 52/52. The D7-verify below was
performed — no indirect-advance `$next` was orphaned.

- **Delete `mir_func_param_is_next_receiver`** (`mir.qz:2863`) now that
  `mir_func_param0_is_mut_value_receiver` covers the general mutating receiver. The
  `$next` predicate is a strict subset **for direct-store advances**. Before
  deleting, **verify** (per D7) that no `$next` advance lowers to a non-direct-store
  form that the general `mutates_self_field` detection misses — grep the stdlib
  iterators (`std/**/*.qz` `def *$next`) and confirm each stores `self.<field>`
  directly. If any advance is indirect, that case must first be covered by the
  transitive detection below; otherwise deleting the OR-in silently breaks it.
- **Reconcile the decompose OR-in** (`mir.qz:2915`/`2933`): the two predicates are
  OR'd; once `$next` is folded, the OR collapses to the single mutating-receiver
  predicate. Confirm the collapsed form is byte-identical at gate-0 and behavior-
  identical on the iterator specs before removing the dead disjunct.
- **Dependency:** none (both hooks already built). **One-way-door:** no — pure
  cleanup, reversible via git; but must be D7-verified (dead vs load-bearing) before
  removal, or it regresses an untested indirect-advance iterator.

### Phase 5 — transitive self-mutation — ✅ DONE (`c4b10ded`, already-worked / spec-only)
**Outcome:** `mir_body_assigns_self_field` **already** flags `mutates_self_field` on a
direct `self.field=` **OR** a self-rooted UFCS call (`mir_receiver_is_self_rooted`) —
i.e. the design's own endorsed over-approximation was already implemented. Verified
across ≤16B, >16B CoW, A→B→C→D transitive chains, nested-in-loop/if, and the free-fn
self-method form. Lock-in spec `value_transitive_mut_spec.qz` 7/7. Commit `c4b10ded`
is the lock-in spec; no compiler change was needed. **Optional refinement:** the
detection is an over-approximation (any self-rooted call marks the method mutating); a
real call-graph fixpoint would only ever **NARROW** it (a perf refinement, not a
correctness fix), so it is left as future work.

Today `mutates_self_field` is **direct-`self.field=` only**. A method that mutates
self *only by calling another mutator* (`def advance(self): Void = self.step()`,
where `step` is itself a borrowed mutating receiver) is not detected → its `self`
gets moved-in/dropped → same loss.

- **Design:** extend `mir_body_assigns_self_field` to also set `mutates_self_field`
  when the body calls a method **on `self`** whose receiver is itself a borrowed
  mutating value-self. This is a fixpoint over the call graph (mutual recursion
  possible), so compute it as a marker-propagation pass: a method is
  mutating-through-callee if it passes `self` (or a projection of self) as the
  mutating receiver of another mutating method. The callee's marker must be visible —
  it already is via the qzmod bit-5 serialization, so cross-module works if the
  propagation runs after callee markers are loaded.
- **Exclusivity re-argument (§4.5):** passing `self` transitively as another
  mutating receiver is still a projection that doesn't escape — sound. But if the
  inner call *returns* something derived from `self`'s buffer, that must be checked.
- **Dependency:** Phase 4 (clean single-predicate detection) makes this tractable.
  **One-way-door:** the detection is inference — over-detection (marking a non-
  mutating method mutating) forces a needless borrow (correctness-preserving, mild
  perf cost); under-detection loses mutations (a correctness bug caught only at
  gate-1). Bias toward over-detection.

### Phase 6 — struct-key pointer lifetime in maps — ✅ DONE (`908d7742`, fixed a REAL bug)
**Outcome:** flat (≤16B) struct map keys **DANGLED** when the map outlived its key
allocas — the map stored the raw caller-frame alloca pointer. **Fixed via own-on-insert:**
`_cg_emit_map_custom_key` now heap-copies a flat struct key into map-owned storage
(`_emit_own_key_copy`: `__qz_alloc` + memcpy). CoW (>16B) keys were already heap-owned
and pass through unchanged. Fixpoint **3236**. Spec: `struct_key_map_iteration` 18/18.
**RESIDUAL:** a flat owned key leaks on explicit `delete()` / redundant re-`set()` — the
same non-deep-free parity as String keys today. A per-key free hook is future work only
if map-lifecycle deep-free is added.

R1b (`8adc2ac1`) routes struct-keyed maps to `qz_map_custom_*`; stored keys are
**caller alloca pointers**. A map that **outlives** its key allocas holds dangling
pointers — the same value-struct-in-container lifetime concern the borrow convention
addresses for receivers, now for containers.

- **Design:** a value struct **stored into a container** is not a borrow — it must be
  **owned** (copied/moved into the container's storage), the `sink` convention, not
  `inout`. The fix is to ensure map insertion **copies the key by value** (CoW retain
  or deep copy) into map-owned storage rather than storing the caller's alloca
  pointer. This is orthogonal to the receiver convention but shares the root
  principle: **borrow for transient projections (receivers), own for escaping storage
  (containers).** Verify current `qz_map_custom_*` insertion path: if it stores the
  raw key pointer, that is the bug; the fix is value-copy-on-insert.
- **Dependency:** the `mir_emit_value_copy` / CoW machinery (already built).
  **One-way-door:** no — additive (copy where today we alias).

### Phase 7 — explicit, enforced `&mut self` / `&self` surface — ✅ DONE (`0611c6f9`, `7ee4d23b`)
**Outcome:** the `&mut self` ABI is now an **explicit, enforced surface convention**, not
inference-only. Authors write `def m(&mut self, ...)` / `def m(&self, ...)`; a method that
directly mutates `self` **must** declare `&mut self` (Rust/Swift-`mutating`-style) or it is
a hard error (QZ0407). The Phases 1–6 ABI was **not rebuilt** — explicit `&mut self` sets
the same already-inferred `mutates_self_field` flag, so lowering is unchanged (brainfuck IR
byte-identical). Landed on branch `conductor/value-semantics-s26-2026-07-02`. Fixpoint 3256.

- **Explicit receiver surface (`0611c6f9`).** The CST-lower `cl_lower_param` prefix-scan
  strips a leading `&`/`mut` on the receiver and binds the param name `self`. A
  receiver-borrow marker (**0** = bare `self`, **1** = `&self`, **2** = `&mut self`) is
  stored on the `NODE_PARAM` `rights` slot via `ast_param_set_receiver_borrow` /
  `ast_param_receiver_borrow`. `&mut self` sets the **same** `mutates_self_field` flag
  inference already computes — explicit is the **surface**, inferred is the **mechanism**.
  `&self` and bare `self` set no flag. (This retires the former QZ0403 "malformed receiver"
  near-miss: `&mut self` now parses to a well-formed `self` binding, not `FIELD_ACCESS(self, "")`.)
- **owner-Q#5 predicate consolidation (`0611c6f9`).** The two former recompute sites
  `mir_func_param0_is_mut_value_receiver` and `mir_func_node_is_borrowed_cow_self_receiver`
  now read **ONE** hoisted `mir_body_assigns_self_field` verdict per lowering path via the
  shared helper `mir_receiver_is_borrowed_mut_self` — the single-source-of-truth
  consolidation §4.1 / §7 Q#5 proposed. (Q#5 is now resolved; see §7.)
- **QZ0407 enforcement (`7ee4d23b`).** A method whose receiver is `self` — explicit **or**
  the injected implicit-self receiver of an `extend`/`impl` method — that **directly**
  mutates self (`self.field = …`, or the `@field = …` shorthand, which lowers to
  `self.field =`) **without** declaring `&mut self` is a **hard error (QZ0407)**, emitted in
  typecheck (`tc_function`, the anchor for future alias/exclusivity checking), mirroring the
  QZ0406 precedent. **Implicit-self `extend`/`impl` methods are NOT exempt** — they receive
  an injected `self` receiver, so QZ0407 fires on them too. Enforcement is **DIRECT-ONLY**:
  it uses `tc_body_assigns_self_field_directly` (a copy of `mir_body_assigns_self_field` with
  the transitive UFCS-call arm removed), so a method that mutates self only **transitively**
  (a forwarder `first()` → `self.peek()`) is **not** flagged — the transitive bit still
  drives the ABI conservatively (Phase 5), but only **direct** field stores require the
  annotation. Negative repro: `spec/qz/qz0407_negative.qz`.
- **Full first-party migration (`11e9dd53`, `7ee4d23b`).** Every direct self-field mutator
  across `std/**` and `spec/**` now declares `&mut self` — std collections
  (deque / linked_list / queue / priority_queue / stack / sorted_map iterators), std/iter
  cursors, toml lexer/parser, unicode, bytes_reader, io/buffered, io/file,
  sync/composition/scope, progress (`Progress` + `Live`), plus spec structs (incl. the
  implicit-self `custom_index_spec` `Box.set`, migrated by adding an explicit `&mut self`).
  Self-hosted compiler: **0** direct self-mutators (its state is ctx-passing, not
  self-mutation), so no compiler-source method needed migration. Brainfuck IR byte-identical
  (annotation sets an already-inferred flag → lowering unchanged).

**Anchor — LANDED (2026-07-04):** QZ0407's `tc_function` typecheck site was landed as
the hook for **alias/exclusivity checking** (the Law of Exclusivity, Rust-style `&mut`
aliasing rules), and that checking has now attached. A new middle pass
`middle/exclusivity.qz` runs in `tc_function` immediately after the QZ0407 block and
enforces, as **hard errors** (flipped hard-error `81ad07c8`):

- **QZ0408 — static exclusivity conflict:** a call that passes overlapping places (same
  base / projection-prefix) where at least one is a `&mut` borrow — e.g.
  `f(&mut x, x)`, `f(&mut x, &mut x)`, `recv.set(&mut recv)`. *"Take one borrow, finish,
  then the other."*
- **QZ0409 — non-escape violation:** a second-class borrow (`&x` / `&mut x`) that
  escapes — (a) stored into a field / array element, (b) returned, or (c) captured into
  an escaping closure. *"Keep the borrow call-scoped or pass by value."*

`&funcname` function-references are correctly **exempt** — they are first-class values,
not second-class borrows; the checker distinguishes them via
`excl_func_ref_is_data_borrow` (`&mut` is always a data borrow; `&name` is a data
borrow iff `name` resolves to a local binding, else it is a funcref value).

The model is **static, base-only**. The **remaining tail** (in progress / next) is the
projected-place `&mut p.f` / `&mut a[i]` lowering and the dynamic `--exclusivity-check`
runtime path — not yet done. Phase 7 delivered the enforced receiver convention; this
pass delivers the aliasing analysis on top of it (see §7 Q#2).

---

## 6. One-way-door risks & test strategy

### Risks
- **Retain/release imbalance (CoW)** — the single highest risk. Any future edit that
  touches one of {call-site retain-skip, callee release-skip} without the other
  double-frees or leaks. **Invariant to encode:** these two are one decision; ideally
  gate both off the *same* predicate call so they cannot drift.
- **Exclusivity violation via a new escape path** — if a later phase lets a borrowed
  `self` projection be stored/returned, the "exclusive by construction" argument
  (§4.5) breaks and we get alias-outlives. Every phase that widens what a borrow can
  reach must re-argue non-escape.
- **Under-detection of mutation** — a mutation the marker misses (indirect advance,
  transitive) loses writes at gate-1 only. Bias detection toward over-inclusion.
- **Decompose OR-in removal** (Phase 4) breaking an untested indirect-advance `$next`.

### Test strategy (OOM-constrained — targeted only)
The owner's machine OOMs on full `quake qspec` and cold-rebuild loops (see MEMORY.md:
`quake_qspec_full_suite_oom`, `formatter_cold_rebuild_loop_oom_panic`). Therefore:

- **Value-at-gate-0 oracle** (`value_at_gate0_oracle_for_f4_flip.md`) — mark repro
  structs `@value` to exercise value-layout codegen **without** a throwaway flip=1
  build (no Bootstrap-Island/OOM risk). This is the primary regression tool for
  each phase. Caveat (`value_at_gate0_oracle_consumer_caveat.md`): some consumers
  need the real flip=1 dance or a full-suite sweep — note which per phase.
- **Gate-0 byte-identity is the backstop** — every phase must keep flip=0 self-compile
  byte-identical (all hooks value-layout-gated). `rm -rf .quartz-cache && quake guard`
  (cold) detects cache-masked drift (`cold_parse_scan_detects_cache_masked_drift.md`).
- **Targeted specs only** — extend `value_mut_receiver_spec.qz` per phase; run via
  `FILE=… quake qspec_file` **one at a time**, `pkill -9 -f "quakefile qspec"` after
  (`qspec_test_binary_orphan_loop_inner_compile.md`). Never the full suite.
- **A/B IR diff, not binary SHA** — compare `.ll` guard diffs with `--no-cache`
  (`quartz_cache_poisons_ab_binary_compare.md`); binary SHAs are LC_UUID noise
  (`f4_gate1_wall_cleared_flip_owner_ready.md`).
- **Smoke non-self programs** after guard (`examples/style_demo.qz`, `brainfuck.qz`) —
  a self-consistent broken compiler passes fixpoint but fails smoke.
- **Guard + fixpoint** mandatory before any commit (hook-enforced). Fixpoint fn count
  is a drift canary (3176 at P2).

---

## 7. Open questions for owner (irreversible ABI decisions)

1. **`&mut self` mandatory or inferred?** *(RESOLVED — Phase 7, `7ee4d23b`: MANDATORY for
   direct self-mutation.)* Rust/Swift require `mutating`/`&mut self` to be *declared*; a
   `self.field=` in a plain-`self` method is a compile error. Quartz now enforces the same
   via **QZ0407**: a method that **directly** stores `self.field` must declare `&mut self`.
   The inferred `mutates_self_field` mechanism still drives the ABI (and still covers
   *transitive* mutation conservatively — transitive mutators are NOT required to annotate),
   so "mandatory" applies to the direct-store surface only.
2. **Exclusivity enforcement — construction-only, or add a check?** *(RESOLVED —
   2026-07-04: ADD A CHECK.)* §4.5 argued non-escape by construction (Stance-1, no
   lifetimes) was sufficient, but item-20's second-class borrows (`&mut self` / `&self`
   receivers, `&x` / `&mut x` expressions) reopened the aliasing/escape hazard under the
   F4 value-default. We now enforce Swift's static half: the middle pass
   `middle/exclusivity.qz` emits **QZ0408** (overlapping-place `&mut` conflict) and
   **QZ0409** (borrow escapes via store / return / escaping-closure capture) as hard
   errors. Static base-only enforcement is done; projected-place lowering + a dynamic
   `--exclusivity-check` path are the remaining tail.
3. **Container storage convention (`sink`).** Phase 6 asserts "own, don't borrow" for
   values stored in maps/vecs. Confirm the general rule: **any value struct that
   escapes into a container is copied/moved (owned), never aliased.** This is a
   cross-cutting ABI commitment (affects vec, map, struct-field, closure capture),
   partially already true via `mir_emit_value_copy` — ratify it as the policy so
   future container code follows it.
4. **Read-only receiver: value-copy or always-borrow?** Today a `let`-receiver
   (`mutates_self_field==0`) value-copies for flat structs. Should read-only flat
   receivers *also* borrow (skip the copy) as a perf win, like the read-only CoW
   borrow already does? This is a copy-elision optimization with the same non-escape
   precondition — worth doing, but it widens the borrow surface (see Q2).
5. **Where does detection live (single source of truth)?** *(RESOLVED — Phase 7,
   `0611c6f9`.)* The two former recompute sites (`mir_func_param0_is_mut_value_receiver`,
   `mir_func_node_is_borrowed_cow_self_receiver`) now read **one** hoisted
   `mir_body_assigns_self_field` verdict per lowering path via the shared helper
   `mir_receiver_is_borrowed_mut_self` — the consolidation §4.1 proposed. Behavior-preserving
   (gate-0 byte-identical); the two predicates no longer independently recompute the verdict.

---

## Sources
- Rust `&mut self` / noalias: [rust-lang/rust#31681](https://github.com/rust-lang/rust/issues/31681), [noalias story](https://medium.com/@trivajay259/why-rust-doesnt-always-restrict-your-mut-the-real-story-behind-noalias-fa8f5e623fef)
- Swift exclusivity / inout: [Swift 5 exclusive access (InfoQ)](https://www.infoq.com/news/2019/02/swift-5-exclusive-memory-access/), [in-out parameters](https://medium.com/@mail2devcrew/understanding-in-out-parameters-in-swift-00382154dac8)
- Hylo/Val conventions: [functions and methods](https://docs.hylo-lang.org/language-tour/functions-and-methods), [val-for-swift-users](https://github.com/hylo-lang/Documentation/blob/main/val-for-swift-users.md)
- Mojo ownership: [Mojo ownership manual](https://docs.modular.com/mojo/manual/values/ownership/)
