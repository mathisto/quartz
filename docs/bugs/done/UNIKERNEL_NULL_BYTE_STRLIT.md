# Compiler: large \x00-containing string literal corrupts interner state

**Status:** CLOSED 2026-04-20 by commit `137ced54` — `@strcmp` in
`cg_emit_map_str_key` replaced with a length-aware `@qz_str_eq` runtime
helper. Fixpoint green (gen1 == gen2, 2149 functions). The original
reproducer (`tmp/baremetal/quartz-unikernel-src.qz` with `\xNN`-escaped
chip8.wasm) now typechecks + compiles cleanly. Regression lock:
`spec/qspec/map_null_byte_keys_spec.qz` (5 tests). Hex-encoding
workaround in `bake_assets.qz` reverted in the same commit.

**Filed:** 2026-04-19, unikernel-site branch (commit `3eaf0f91` baseline).
**Reproducer:** `tmp/baremetal/quartz-unikernel-src.qz` (post-bake concat
  of `hello_x86.qz` + `site_assets.qz` containing a 14076-byte chip8.wasm
  body hex-escaped as `\xNN` bytes). Lives on until someone un-bakes it.

## Symptom

`quake baremetal:build_elf` fails with ~30 typecheck errors, led by three
with no source location:

```
error[QZ0200]: Duplicate loop label :
error[QZ0200]: Duplicate loop label :
error[QZ0200]: Duplicate loop label :
error[QZ0401]: Undefined function: push    (line 2584 onward)
error[QZ0200]: Cannot index non-array type ...
```

The empty label after the colon is the first tell — the typecheck's
"Duplicate loop label :#{label}" format string renders an empty
`while_label` despite the guard `str_byte_len(while_label) > 0` having
passed. That points at either a wrong-ID resolve from the interner or a
null-byte truncation during interpolation.

Knock-on effects corrupt type inference (`v.push` → "Undefined function"
because Vec element type is lost) and render the build unusable.

## What IS and ISN'T the trigger

Bisected thoroughly (see commit log / session transcript for
`unikernel-site`):

| Variant | Duplicate errors? |
|---|---|
| `hello_x86.qz` alone (no asset table) | 0 |
| `hello_x86.qz` + `site_assets.qz` head (no binary assets) | 0 |
| `hello_x86.qz` + asset line for `/chip8/chip8.wasm` (14076 bytes) | **4** |
| Same line, final `\x0b` byte removed (14075 bytes) | 0 |
| Same line, +1 extra byte appended (14077 bytes) | 0 |
| Same length, content replaced with `\x41` × 14076 | 0 |
| Same content with `\x00` → `\x20` globally | 0 |
| Same content with `\x00` → `\u{00}` globally | 4 |

So the trigger requires **all three** of:
1. Specific content (14076 bytes of the actual chip8.wasm bytes)
2. Exactly that byte count (not 14075, not 14077)
3. The presence of embedded `\x00` bytes

The 14076-byte exactness rules out "size threshold" — it's some hash or
offset value that's specifically sensitive to this content.

Removing any single byte at any position, or appending any single byte,
breaks the trigger. That pattern fits a hash collision: the specific
FNV-1a value of the 14076-byte string lands in the same interner bucket
as some pre-populated entry, and because probing within that bucket
uses C `strcmp` (null-terminating) instead of a length-aware compare,
the new `\x00…` string gets aliased to the existing entry's ID.

## Suspected root cause

`self-hosted/backend/cg_intrinsic_data.qz` emits hashmap codegen for
`Map<String, V>` that:

1. Hashes via `@qz_str_hash` (length-prefixed FNV-1a — correct, handles
   `\x00`).
2. Compares bucket keys via `@strcmp(ptr, ptr)` — C null-terminating.

If two keys hash to the same bucket (via linear probing) and share a
common prefix up to the first `\x00`, strcmp returns 0 and the map
falsely reports them as equal. For the interner's
`Map<String, Int> lookup`, this aliases the new string's intern-id to
the existing entry's id.

The bug is latent for all normal (no-`\x00`) keys. It surfaces only
when a `\x00`-containing key is interned AND happens to probe into a
slot whose stored key is strcmp-equal (i.e., its stored bytes are
empty-to-C, e.g. starts with `\x00` or is the pre-interned empty
string at id 0).

## Fix — proper

Replace the six `@strcmp` calls in `cg_intrinsic_data.qz` (all within
`cg_emit_map_str_key`) with a length-aware equality helper:

```llvm
define i64 @qz_str_eq(ptr %a, ptr %b) nounwind {
  ; read both length prefixes; mismatch → 0; memcmp → equal
}
```

Declare it once (alongside `qz_str_hash`) in both the hosted and
freestanding runtime-decls paths in `codegen_runtime.qz`.

This is a compiler-source change, so it requires:

- `quake guard` (fixpoint) — mandatory per CLAUDE.md
- Smoke tests (style_demo + brainfuck) — mandatory
- A targeted QSpec for Map<String, V> with `\x00`-containing keys
- Bundled with a regression QSpec for large binary-asset-shaped literals

Estimated cost: 0.5–1 quartz-day (1–4 hours).

Also audit the other two `strcmp` sites in `codegen_runtime.qz`:
- line ~4596 (`ends_with` suffix match — length-known, likely safe)
- line ~7155 (struct field equality — latent for struct-with-String-key
  maps + `\x00` values; should move to `qz_str_eq` for the same reason)

## Fix — workaround (shipped, commit TBD)

Changed `tools/bake_assets.qz` to emit asset bodies as **plain ASCII
hex** (2 chars per byte, no `\x` escapes) and added
`copy_hex_to_pmm(hex: String, byte_len: Int)` to `hello_x86.qz` to
decode at boot. Source is now pure ASCII with no `\x00` bytes, which
sidesteps the interner-collision path entirely.

Side benefit: the escape form was 4 chars per byte (`\xNN`); hex plain
is 2 — asset body source is half the size. `site_assets.qz` drops from
22 MB to ~11 MB for the same asset set.

## Done criteria for the real fix

- [ ] `@qz_str_eq` in runtime decls (hosted + freestanding)
- [ ] All `cg_emit_map_str_key` strcmp sites use it
- [ ] QSpec file `map_null_byte_keys_spec.qz` exercising collisions
- [ ] Regression test: `spec/baremetal/large_null_literal_spec.qz`
      (compile a file containing a 14076-byte `\x00`-containing literal
      with `hello_x86.qz`-shaped surrounding context)
- [ ] Fixpoint green
- [ ] Smoke tests green
- [ ] Then: revert the hex-encoding workaround in `bake_assets.qz`
      (swap `copy_hex_to_pmm` back to `\xNN` + `copy_str_to_pmm`) —
      confirms the compiler fix actually resolves it
