# C-ABI: >16B narrow/float-mixed structs use the wrong indirect layout

**Status:** ✅ CLOSED 2026-06-07 — narrow (P3.4-ii-a `21b5e412`) + F32
(P3.4-ii-b) both landed. The whole >16B-indirect C boundary now handles every
scalar field type, both directions, both ABIs, real-run-verified.
**Filed:** 2026-06-07 (during P3.4a)
**Severity:** ABI-wrong codegen for an untested combination (not a crash, not a regression)

## ✅ Narrow resolved (P3.4-ii-a)

A pure-narrow / narrow+wide (no F32) >16B struct's Quartz internal `%struct.Name`
already equals the C layout, so `cg_c_abi_indirect` now returns the true-size
`%struct.Name` (not `[N x i64]`) for it, and the callee sret terminator does a
whole-struct copy. Oracle `struct_large_narrow_*`, both dirs, host arm64 + SysV
(Rosetta).

## ✅ F32 resolved (P3.4-ii-b)

F32 >16B structs need a C-layout `%struct.Name.cabi = {float,…}` named type
(internal `%struct.F6 = {i64×6}` = 48B ≠ C `{float×6}` = 24B) emitted by
`cg_emit_struct_types`, used as the byval/sret type, with a field-by-field
boundary repack (`cg_c_abi_emit_qz_to_c_buf`/`_c_to_qz_buf`, fptrunc/fpext) at
all four sites. Oracle `struct_large_float_*` (F6/FMix6/FW), both dirs, host
arm64 + SysV (Rosetta). IR matches clang's `byval(%struct.F6)`/`sret`.

## Symptom

A struct that crosses an `extern "C"` boundary BY VALUE, is **>16 bytes**
(→ indirect: `byval` param / `sret` return), AND has any **narrow** (sub-8-byte
int) or **F32** field, is mis-lowered:

- **>16B narrow** (e.g. `struct{int32 a,b,c,d,e,f}`, 24B): falls through the
  `cg_c_abi_indirect` gate (`cg_c_abi_field_wide8`-only, even after P3.4a) →
  returns `""` → the legacy opaque-`i64`-pointer path. The C ABI expects an
  indirect `byval(%struct.T)`/`sret(%struct.T)` pointer; passing a bare `i64`
  is ABI-wrong.
- Even if the gate is opened, `cg_c_abi_mem_type(fc)` returns `[fc x i64]`,
  which is `fc*8` bytes — for `6×i32` that's 48B, but the struct is 24B. The
  byval/sret memory type must be the true-size named `%struct.T` (clang:
  `byval(%struct.Narrow24)` = 24B).
- The callee return terminator (`codegen_instr.qz` ~3659) copies the result
  struct into the `%sret` slot **field-by-field as i64** (`getelementptr
  inbounds i64, ptr %sret, i64 N`). Correct for all-i64 structs; for a packed
  narrow/float struct this writes at the wrong (i64-strided) offsets.

This is **pre-existing**: P3.3 only handled >16B all-8-byte-field structs.
>16B narrow/float structs were never handled — they always took the legacy
path. P3.4a-i (narrow ≤16B coerce) did not touch `cg_c_abi_indirect`, so it
neither introduced nor fixed this.

**Update 2026-06-07 (P3.4b landed):** the ≤16B/HFA F32 boundary-repack now
exists — `cg_c_abi_emit_pack`/`cg_c_abi_emit_unpack` (codegen.qz) walk a struct
field-by-field at true C offsets with per-field `fptrunc`/`fpext` for F32. P3.4-ii
fix step 4 ("indirect F32 shares P3.4b's repack machinery") can reuse these
directly — they already take a target buffer and a struct type, independent of
the byval/sret vs coerce framing. What remains for P3.4-ii is the >16B indirect
emit-site surgery (true-C-size named `%struct.T`, packed-layout sret copy) per
the steps below; the F32 field conversion itself is solved.

## Fix (P3.4-ii)

Open `cg_c_abi_indirect` to `cg_c_abi_field_packable` (and F32 once P3.4b lands),
and make the indirect path true-offset:

1. `cg_c_abi_indirect` / `cg_c_abi_mem_type`: emit the named `%struct.T` (true
   C offsets) when the struct uses the packed layout (`mir_prog_struct_has_narrow_fields`
   / has an F32), else keep `[N x i64]` for all-wide (P3.3, byte-identical).
2. Add `cg_c_abi_struct_c_size(prog, type_name)` (mirror `abi_struct_size` over
   `layout_scalar_size`) and replace the `fc*8` literals at the 5 indirect emit
   sites (caller byval copy alloc, sret buffer alloc, callee sig, declare,
   callee return terminator) with the true C size.
3. Callee return terminator: copy via the packed `%struct.T` layout (typed-GEP
   per field, or a whole-struct `load %struct.T`/`store %struct.T`) instead of
   the i64-strided field copy, for narrow/float structs.
4. For F32: the indirect buffer is the C-packed `%struct.T.c` (float, not
   double-bits) — shares P3.4b's boundary-repack machinery.

Fold narrow + float-mixed into one commit (shared emit-site surgery).

## Oracle (when fixed)

`spec/c_abi/struct_large_narrow_*` — e.g. `struct Narrow24{int32 ×6}`,
`struct M{int8 ×3; int64; float}` (24B mixed) — both directions, host arm64
native + SysV clang-diff (+ lovelace native when the `.bashrc` lockout clears).

## Fixpoint safety

Gated on cconv-C + eligible struct; the compiler/std use no `extern "C"`
struct-by-value (verified), so the gate never fires in self-compile ⇒ fixpoint
byte-identical. Same property as all of Phase 3.
