# String/slice range family — 3 residual bugs (filed 2026-07-07, chunk-9)

**Status:** OPEN. Filed from the chunk-9 round-2 miscompile hunt (`docs/sagas/diagnostics-quality-epic-2026-07-07-research/miscompile-hunt-r2.md`) + the WS3 string-range fix (`32b55874`, which fixed the *routing* miscompile but surfaced these adjacent residuals).
**Context:** The silent miscompile where `s[a..b]` returned `0` instead of the substring is FIXED (`32b55874` — added the `TYPE_RANGE` arm + `str_slice` MIR dispatch). These three are separate, and two are NOT gate-1-inert → attended-only.

## Bug 1 — `Slice<T>` enumerable-intrinsic SIGSEGV (attended-only)
`sum(slice)` / `slice.map()` and other header-unpacking enumerable intrinsics **SIGSEGV** on a `Slice<T>`. Root: `cg_emit_vec_unpack` (`self-hosted/backend/cg_intrinsic_collection.qz:~982`) assumes a **32-byte Vec header**, but `Slice<T>` has a **24-byte header** → reads past the struct / mis-offsets the data ptr → crash.
- `Slice<T>` is a proper distinct type; `sub[i]`, for-in over a slice, and manual index loops all work correctly — ONLY the header-unpack enumerable intrinsics crash.
- **NOT inert:** `cg_emit_vec_unpack` is on the hot path for real `Vec` enumerable intrinsics (used pervasively, incl. by the compiler). Fixing it (branch on the header size / pass the actual header width) touches live codegen → needs full-suite validation. Attended-only.
- Fix direction: teach `cg_emit_vec_unpack` (or its callers) the container's real header width instead of hardcoding 32, OR normalize `Slice<T>` to a Vec-shaped view at the intrinsic boundary.

## Bug 2 — `qz_str_slice_utf8` out-of-range end not clamped (attended-only)
`s[3..10]` on a length-5 string **SIGSEGVs** — and so does the explicit `s.slice(3, 10)`. Root: `qz_str_slice_utf8` (`self-hosted/backend/codegen_runtime.qz:~13399`) does not clamp `cp_end` to the codepoint count. When `cp_end` exceeds the string length the scan never sets `byte_end`; `end_at_end` (`ci == cp_end`) is false at loop end, so `byte_end` stays 0 → negative `slice_len` → bad `memcpy`.
- Shared by `str_slice` / `.slice()` / the new range-index path (all route through this runtime fn).
- **NOT inert:** `qz_str_slice_utf8` is embedded runtime used by any string-slice consumer. Fixing (clamp `cp_start`/`cp_end` to `[0, cp_count]`) changes emitted runtime IR broadly → needs full-suite validation. Attended-only.
- Fix direction: clamp `cp_start = min(cp_start, cp_count)` and `cp_end = min(cp_end, cp_count)` (and `cp_end = max(cp_end, cp_start)`) at the top of the slice, returning `""` for an empty/degenerate range.

## Bug 3 — `s[a..=b]` inclusive range in index position fails to parse (CST parser gap)
Inclusive-range subscript `s[a..=b]` emits `QZ0101: CST parse error`. Root: `cps_parse_index_body` (CST parser) doesn't emit the inclusive-range discriminant (disc 28) that the non-subscript `..=` path does. Exclusive `s[a..b]` parses fine.
- The MIR range-index lowering already handles `OP_RANGE_INCLUSIVE` defensively (`end+1`), so closing the parser gap would light up inclusive subscripts end-to-end.
- Likely inert-ish (parser-only, on an already-erroring input) but touches the hot CST index-parse path → validate carefully; grouped here with its family.

## Also flagged (truth-in-docs liabilities, chunk-9 hunt) — documented forms that don't work
These are documented/example forms that emit loud parse/type errors (NOT miscompiles) — either fix the feature or correct the docs (D6):
1. `..=` in bracket/subscript position (see Bug 3).
2. Multi-clause comprehension `for x for y` — parse error.
3. Nested var-bound lambda from the docs' own "nested closures work" example — errors.
4. Bare-literal push into `Vec<Vec<Int>>` — type error on the literal.
Details + repros in `docs/sagas/diagnostics-quality-epic-2026-07-07-research/miscompile-hunt-r2.md`.
