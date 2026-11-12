# Niche-multi enum `match` / field round-trip returns garbage (context-dependent)

**Status:** PARTIALLY FIXED — discovered 2026-06-18 during SURF.FLOW Phase 3. PRE-EXISTING (reproduced on the Phase-2 golden binary `quartz-pre-flow-p3-golden`), independent of flow-narrowing.
- **Symptom 2** (built-in `Result<String,String>` M2 is_ok/match narrowing) → ✅ **FIXED**. The M2 gate `mir_multi_niche_result_live()` (`self-hosted/backend/mir.qz` ~:9547) now returns `1`; standalone + qspec-harness both green.
- **Symptom 1** (M1 user-enum `match` tag-read → context-dependent garbage in imported-module / qspec-harness contexts; standalone correct) → **still OPEN, ATTENDED-ONLY** (see below).

**Severity:** Tier-A correctness. A `match` of a niche-multi enum silently returns the wrong/zero value in some compilation contexts — no crash, no diagnostic.

## Symptom 1 — M1 user enum `match` is layout-inconsistent across compilation contexts — ⚠️ STILL OPEN (ATTENDED-ONLY)

A 2-boxed-payload user enum (`enum Pair { Left(box: Box); Right(box: Box) }`, M1-niche-eligible) constructs with the NICHE packing (`payload_ptr | tag`), but a plain `match e { Left(bx) => box_v(bx) }`:

- in a **standalone** program → lowers the match as NICHE (`& 7` tag, `& ~7` payload) → **correct** (returns 21).
- in the **qspec harness** (same function, `import * from qspec`) → lowers the match as **SPILL** (`load tag@0`, `getelementptr i64 1` payload) → **wrong** (returns 0).

Construction is niche in both; the `match` lowering disagrees with construction in the qspec context. Minimal repro (returns 0 under qspec, 21 standalone):

```quartz
import * from qspec
struct Box { v: Int }
def box_v(b: Box): Int = b.v
enum Pair { Left(box: Box); Right(box: Box) }
def basic(): Int
  e: Pair = Pair::Left(Box { v: 21 })
  match e
    Left(bx)  => return box_v(bx)
    Right(bx) => return -1
  end
end
def main(): Int
  describe("x") do -> it("m") do -> assert_eq(basic(), 21) end end
  return qspec_main()
end
```

Reproduces identically on `self-hosted/bin/backups/quartz-pre-flow-p3-golden`. The same shape also fails through a struct field (`PairBox { p: e }; match b.p`) and a return slot (`def f(): Pair; ...; match f()`).

Likely cause: `mir_multi_enum_is_niche` / `mir_multi_enum_layout` / `mir_multi_enum_variant_collides_builtin` (or the M1 eligibility budget) classify `Pair` differently depending on the full set of enums registered in the module (the qspec harness registers many more enums than the standalone), so the construction-side and match-side niche decisions desync. This is the "M1 construct/read must agree" hazard (mir.qz §14.9) recurring across compilation contexts.

**Classification: Tier-A silent miscompile.** The construct side packs niches
unconditionally, but the read side decides SPILL when the larger-enum-registry
context is in play — a construct/read desync (the §14.9 "construct and read must
agree" hazard).

**Fix locus:** `mir_multi_enum_common_spare` / `mir_subject_is_niche_multi` /
`mir_multi_enum_is_niche` in `self-hosted/backend/mir.qz` (~:10005 / :10130 /
:10242) plus the tag-read call sites `mir_get_enum_tag_subj`
(`self-hosted/backend/mir_lower_stmt_handlers.qz` ~:1743). **Fix direction:** make
the niche verdict key ONLY on the enum's own declaration, so construct and read
agree identically regardless of the ambient module enum set.

**Why ATTENDED-ONLY (not unattended):** this is the HOT shared niche classifier
used across the whole `match` / `is` / narrowing surface. Any change re-emits the
compiler's own IR (NOT gate-1-inert), and confident validation needs broad qspec
coverage (the `niche_*` / `flow_narrow_*` family) which the full `quake qspec`
suite would provide — but that suite OOMs this Mac. So the fix must be done in an
attended session with a serial spec sweep, NOT unattended.

## Symptom 2 — built-in niche-multi `Result<String,String>` (M2) is_ok/match — ✅ FIXED

**Resolution:** the M2 gate `mir_multi_niche_result_live()` (`self-hosted/backend/mir.qz` ~:9547) now returns `1`. `Result<String,String>` (both args boxed ⇒ M2-niche) `is Ok`/`match` narrows correctly; standalone + qspec-harness both green. Original report below (kept for history).


`Result<String,String>` (both args boxed ⇒ M2-niche, gate `mir_multi_niche_result_live()==1`):

```quartz
r: Result<String, String> = Result::Ok("payload")
r is Ok           # → FALSE (wrong; r is Ok)
match r { Ok(v) => v; Err(e) => "ERR" }   # → "(null)" (wrong)
```

Reproduces on golden. `Result<Int,String>` (scalar Ok payload ⇒ SPILL) is correct. The M2 read seam (`mir_get_enum_tag_subj` `& 7` mask + `apply_pending_bind` `& ~7`) is not firing for a top-level `Result<&,&>` `is`/match, OR construction is not niche-packing it. ROADMAP.md line 454 claims "M2 LANDED-AND-FLIPPED ... result_niche_spec 28/28" — but `result_niche_spec` may only exercise `Result<&A,&B>` where A/B are structs/specific types; `Result<String,String>` is regressing. Needs investigation: does the 28/28 spec cover `Result<String,String>` specifically?

## Impact on SURF.FLOW Phase 3

Phase 3 narrowing is CORRECT and SOUND on top of this:
- M1 user-enum narrowing extraction (`mir_emit_narrowed_read` mask path) agrees with construction, so narrowed reads of `Pair` return the right payload even in qspec (verified: `user_binary_then`=7, `user_binary_else`=9 via Right/tag-1). The pin round-trips the wide word (verified via re-narrow, not via the broken `match`).
- M2 niche Result narrowing is INERT (the `is Ok` guard is pre-existing-false ⇒ then-branch dead) and SOUND (pin protects whole flow). It is generalized in the classifier + `mir_emit_narrowed_read` (`& ~7` mask) and will light up automatically once Symptom 2 is fixed.
- `spec/qspec/flow_narrow_p3_spec.qz` PARKS the 3 niche-Result assertions as `it_pending` and verifies M1 user-enum soundness via re-narrow instead of `match`.

## Next steps

Symptom-2 items (3, 4) are DONE. Only Symptom-1 remains, and it is ATTENDED-ONLY (see the Symptom-1 section for the rationale).

1. (Symptom-1, attended) Determine why `mir_multi_enum_is_niche`/layout for `Pair` flips between standalone and qspec — diff the registered-enum set and the eligibility predicate inputs.
2. (Symptom-1, attended) Make construction and ALL read sites (match, is, field, return) use ONE niche decision, keyed only on the enum's own declaration (not the ambient module set).
3. ✅ DONE — Symptom-2 `Result<String,String>` `is`/match fixed (`mir_multi_niche_result_live()==1`).
4. ✅ DONE (this run) — the 3 `it_pending` niche-Result cases in `flow_narrow_p3_spec.qz` are being un-parked.
