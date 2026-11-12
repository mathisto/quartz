# WASM str_reverse synth is byte-level, not codepoint-aware

**Status**: ✅ RESOLVED 2026-04-30 — same-day follow-up commit. Synth body rewritten to walk by codepoint (Option 1 from the original analysis).
**First observed**: 2026-04-30 while adding the str_reverse synth body.
**Symptom**: ASCII inputs work; multibyte UTF-8 sequences scramble.

## Resolution

`_wasm_synth_str_reverse` rewritten in `wasm_runtime.qz` to mirror LLVM's
`qz_str_reverse_utf8` algorithm: walk source forward, at each position
inspect the byte's UTF-8 prefix to determine codepoint width (1, 2, 3,
or 4 bytes), then `memory.copy` that span to a destination offset that
walks backwards from `blen`. End result: codepoint-level reversal with
the constituent bytes of each multi-byte sequence preserved in their
original order.

Six locals (was three): adds `di` (destination offset, decreasing),
`byte` (current source byte for prefix inspection), and `step`
(codepoint width). The width-classification select is encoded as three
nested `if/else` blocks producing an i64 result on the value stack —
the WASM equivalent of LLVM's three-way `select`.

Verification:
- `examples/string_processing.qz` — Quartz runtime → unchanged
- New spec test in `wasm_string_interp_spec.qz` exercises "héllo",
  "café", "日本語", "a日b" — all match LLVM byte-for-byte
- ASCII regression case (`"abcdef"` → `"fedcba"`) still passes

12/12 wasm_string_interp tests green.

## Summary

The LLVM backend routes user-level `str_reverse(s)` to
`qz_str_reverse_utf8` (codepoint-aware), see `cg_intrinsic_string.qz:620`.
The WASM synth body added in `bc1dd8c2` is byte-level — it mirrors the
simpler `qz_str_reverse` and copies bytes from `src[len-1-i]` →
`dst[i]`. For ASCII inputs the two are equivalent; for any input
containing 2/3/4-byte UTF-8 sequences the byte-level form scrambles
the sequence ordering, producing invalid UTF-8 output.

## Reproducer

```quartz
def main(): Int
  puts(str_reverse("héllo"))  # 'é' is 0xC3 0xA9
  return 0
end
```

Expected (codepoint-level): `olléh`
LLVM output: `olléh`
WASM output: `oll<garbage>` — the 'é' bytes get reversed into invalid
sequences and the trailing byte attaches to a different codepoint.

## Cause

`_wasm_synth_str_reverse` in `wasm_runtime.qz`:

```
# *(dst + i) = *(s + len - 1 - i)
```

This works at the byte level. UTF-8 codepoint-level reversal requires
walking the source forward, identifying each codepoint span (1/2/3/4
bytes), then writing those spans in reverse order to the destination.

## Fix

Two options:

1. **Two-pass codepoint walk.** Pass 1 walks `s` forward, pushing
   codepoint start byte-offsets into a Vec<Int>. Pass 2 reads spans
   from the offset vec in reverse and copies each span to dst. Adds
   ~40 lines to the synth body; needs vec_new + vec_push + vec_get
   cascaded (already present for HOFs).

2. **Codegen call to a runtime helper.** Add a UTF-8 codepoint-level
   reverse to the WASM synth set as `__wasm_str_reverse_utf8` and
   route str_reverse through it. Cleaner factoring; same total code.

## Workaround

For ASCII-only data, the current synth is correct. For non-ASCII,
compile to LLVM (which routes through the codepoint-aware path) or
implement reversal manually using `str_codepoint_at` /
`str_from_codepoint`.

## Acceptance criteria

- A new wasm_str_reverse spec includes a multibyte UTF-8 case
  (`"héllo"` or similar) and asserts the codepoint-level result.
- LLVM behaviour unchanged.
