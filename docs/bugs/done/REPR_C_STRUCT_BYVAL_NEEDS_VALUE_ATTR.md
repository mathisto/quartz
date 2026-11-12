# `@repr(C)` struct by-value across `extern "C"` silently boxes without `@value` → segfault

**Filed:** 2026-06-07, while building B.11b `@cImport` (MEMORY_MODEL_V3.md §13.6a, P3.6a).
**Severity:** silent ABI-wrong codegen + runtime SIGSEGV (no diagnostic). Footgun for hand-written FFI.
**Status:** ✅ **RESOLVED 2026-06-08** — does not reproduce on the current compiler;
the doc's recommended fix #1 (register `@repr(C)` structs in the MIR struct table)
had already landed. Closed with a regression guard. See Resolution.

## Resolution (2026-06-08)

The MIR struct registration at `mir_lower.qz:8940` is **unconditional** — every
`NodeStructDef` is registered via `mir_ctx_register_struct(..., repr_c, packed,
is_value, ...)` with its real flags, so a plain `@repr(C)` struct lands in the
registry with `repr_c=1, is_value=0`. The C-ABI classifier
(`cg_c_abi_coerce`, `codegen.qz`) reads that registry via
`mir_prog_get_struct_field_count`/`_type` and **does not gate on `is_value`** — it
gates on cconv-C + field-packable. So the classifier fires for `@repr(C)`-only
structs exactly as for `@value @repr(C)`. The original crash was the older
return path that did `inttoptr i64 %ret to %struct.T*` directly on the coerced
return value; the current return-reconstruction codegen boxes the coerced
aggregate (`__qz_alloc` + store) and reads fields through a typed `%struct.T` GEP,
which is layout-correct (incl. the F32 fptrunc/fpext repack) — so it produces
correct results, just heap-boxed (an internal-memory-layout *perf* difference vs
`@value`, not a correctness one).

**Why it was filed OPEN despite being fixed:** no test covered the `@repr(C)`-only
spelling — every `spec/c_abi` struct was `@value @repr(C)`. That gap is the hole.

**Empirical verification (all `--no-cache`, real C link-and-run, host arm64 AAPCS
+ x86_64 SysV via Rosetta):** stripping `@value` from the proven oracle mains
(narrow, wide, large >16B, F32, mixed; both caller and callee directions) keeps
every case green; the doc's exact `{int,int} make_point` repro prints `3`; F32
struct param+return round-trips correctly. The F32 declares confirm the classifier
fires: `declare [2 x float] @make_v2f(i32, i32)`, `v2f_sum4([2 x float])`.

**Regression guard:** `spec/c_abi/reprc_only_main.qz` + `reprc_only_lib.c` (wired
into `run.sh` host + `--rosetta`) — the ONLY oracle case using `@repr(C)` without
`@value`. Narrow-int (Pt) + F32 (V2f), struct params and returns. If the registry
ever stops covering plain `@repr(C)` structs, the classifier falls back to the
boxed-i64 convention and this crashes/garbles. `pt_ret=3,4 pt_sum=7,30 v2f_sum=16
vx=6 vy=10 ALL=1` both ABIs.

> ⚠️ The original investigation chased phantom segfaults caused by a contaminated
> `.quartz-cache` (single-file ABI tests run without `--no-cache` after a build
> repopulated the cache — the `cache-ro-fools-golden-ab-testing` trap). ALWAYS
> `--no-cache` (or `rm -rf .quartz-cache`) for single-file ABI A/B.

---

_Original report (preserved for history):_

## Symptom

A struct that crosses an `extern "C"` boundary **by value** (param or return) only
gets the C-ABI classifier treatment (register/`byval`/`sret` coercion) if it is
declared `@value @repr(C)`. With **`@repr(C)` alone**, the call site silently
falls back to the legacy boxed-`i64`-pointer convention:

```
%v4 = call i64 (i64, i64) @make_point(i64 %v2, i64 %v3)   # WRONG: returns struct value in regs, not a pointer
%loptr = inttoptr i64 %v4 to %struct.Point*               # treats the packed struct VALUE as a pointer
... = getelementptr %struct.Point, %struct.Point* %loptr  # wild pointer → SIGSEGV
```

The struct type is emitted (`%struct.Point = type { i32, i32 }`) and the program
compiles + links cleanly. It segfaults at the first field access of the returned
struct. **No compile-time error**, so a user hand-writing C bindings with the
natural `@repr(C)` attribute hits an unexplained crash.

## Reproduction

```qz
@repr(C) struct Point          # <-- @value MISSING
  x: I32
  y: I32
end
extern "C" def make_point(x: I32, y: I32): Point   # C: struct{int,int} make_point(int,int)
def main(): Int
  var p = make_point(3, 4)
  puts(str_from_int(p.x))      # SIGSEGV
  return 0
end
```

Adding `@value` (`@value @repr(C) struct Point`) fixes it — verified on host arm64
(AAPCS) and x86_64 SysV (Rosetta) by the `spec/c_abi/cimport_*` oracle.

## Root cause

The C-ABI classifier (`cg_c_abi_coerce`, `codegen.qz:356`) reads struct fields via
`prog.mir_prog_get_struct_field_count(type_name)` / `mir_prog_get_struct_field_type`.
That MIR struct registry is populated for `@value` structs but **not** for plain
`@repr(C)` structs (which only reach the type-emitter `cg_emit_struct_types`). So
`cg_c_abi_coerce` returns `""` (→ legacy path) for a non-`@value` `@repr(C)` struct,
even though `@repr(C)` is *semantically* the C-layout marker. The existing
`spec/c_abi` oracle structs are all `@value @repr(C)` (or `@value`), so this gap
was never exercised.

## Fix options

1. **Register `@repr(C)` structs in the MIR struct table** the classifier reads, so
   `@repr(C)` alone (the natural FFI spelling) gets C-ABI treatment. Cleanest;
   matches Rust's `#[repr(C)]` (no second attribute needed). Verify the field-type
   list is populated identically to `@value`.
2. **Emit a typecheck error** (e.g. QZ0xxx) when a non-`@value` struct crosses an
   `extern "C"` boundary by value, telling the user to add `@value`. Safe, but
   keeps the two-attribute requirement.

Recommend **(1)** — a struct explicitly marked `@repr(C)` and passed by value to C
should Just Work. Until then, always write `@value @repr(C)` for FFI structs (this
is what `@cImport` generates).
