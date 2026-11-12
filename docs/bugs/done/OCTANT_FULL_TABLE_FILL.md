# Fill in the full Unicode 16/17 octant codepoint table — RESOLVED

**Filed:** 2026-05-06 (Phase 6.6 follow-up)
**Resolved:** 2026-05-06 in v0.6.6.1
**Severity:** Low — feature gap, not a defect. v0.6.6.0 ships a working
`Octant` quality tier covering 16 of 256 patterns; the remaining 240
gracefully fall back to `Quadrant` quality, which every modern terminal
renders correctly.
**Phase:** 6.6.1 (focused transcription pass)

## Resolution (2026-05-06, v0.6.6.1)

All 256 patterns now produce correct Unicode 17 codepoints:
- 230 new octant codepoints in U+1CD00..U+1CDE5 (the entire new block).
- 26 reused codepoints split across:
  - 16 quadrant-clean patterns from U+2580..U+259F (Block Elements).
  - 4 single-corner-subpixel codepoints in U+1CEA0..U+1CEAB.
  - 2 single-row patterns at U+1FB82 (top row) and U+2582 (bottom row).
  - 2 three-row patterns at U+1FB85 (top 3) and U+2586 (bottom 3).
  - 2 middle-rows-of-one-column at U+1FBE6 (left) and U+1FBE7 (right).

Source: Bobby-Miller community gist
(https://gist.github.com/Bobby-Miller/d48dabce3179f328b15db4737740fd55)
transcribed and converted from the gist's bit ordering (high-nibble
= left col, low-nibble = right col, top→bottom within each col) to
this module's bit ordering (bit 0 = top-left, row-major down to
bit 7 = bottom-right). One typo in the gist was corrected: pattern
"top 3 rows of cell" (my-pattern 0x3F) was U+2586 (LOWER 3/4) in the
gist; corrected to U+1FB85 (UPPER 3/4) — verified geometrically as
U+2586 is already the correct codepoint for the bottom-3-rows pattern
(my-pattern 0xFC).

Cross-validated against the Unicode "BLOCK OCTANT-DIGITS" naming
convention for representative entries:
- U+1CD00 = BLOCK OCTANT-3 (digit 3 = upper-mid-left only) → my-pattern 0x04 ✓
- U+1CDE5 = BLOCK OCTANT-2345678 (every digit except 1) → my-pattern 0xFE ✓

48-test spec at `spec/qspec/tui_v06_octant_spec.qz` (39 prior + 9 new
for full-table coverage) green; widget specs that consume octants
indirectly all green; `quake guard` PASSED with fixpoint verified.

## Original filing follows for historical context.

## Summary

`std/tui/octant.qz`'s `OctantQuality::Octant` tier is supposed to emit
the full Unicode 16 octant codepoints (U+1CD00..U+1CDE5 plus 16 reused
existing block-characters) for all 256 possible 2×4 sub-pixel patterns.
v0.6.6.0 only covers the 16 reused patterns (space, 4 quadrants, 6
quadrant pairs, 4 quadrant triples, full block) and falls back to
`Quadrant` glyphs for the remaining 240 patterns. The fallback is
visually correct at 2×2 resolution but loses the 2×4 fidelity for
patterns that can't be expressed as quadrant unions.

## What needs to ship

A complete 256-entry pattern → glyph lookup. For each pattern N:

- If N is one of the 16 pre-existing reused patterns → use the existing
  block character (already implemented).
- Otherwise → emit the SMP codepoint at U+1CD00 + offset(N) where
  offset(N) is the count of non-reused patterns smaller than N.

The Unicode 17 chart (`https://www.unicode.org/charts/PDF/U1CC00.pdf`,
pages 1703–1706 in the names list, U+1CD00..U+1CDE5) lists each
"BLOCK OCTANT-N" character with the digits of its set positions
(1=top-left, 2=top-right, 3=upper-middle-left, ..., 8=bottom-right).

Implementation work:

1. Transcribe all 230 entries from the Unicode 17 chart into a 256-entry
   lookup table (10 patterns are not encoded as new octants and need to
   verify which existing characters they reuse — best inspection point
   is the chart pages U+1CEA0..U+1CEAF for "ONE QUARTER"-style fragments
   and U+1CC60..U+1CC8F for various block-element-derived shapes).
2. Replace the `_octant_glyph` body in `std/tui/octant.qz` with the
   full table.
3. Verify each octant pattern's bit ordering matches the Unicode digit
   convention (digit-N corresponds to the (N-1)-th bit, top-left first,
   row-major down to bottom-right).
4. Extend `spec/qspec/tui_v06_octant_spec.qz` to cover representative
   patterns from each Unicode quadrant of the table (single-subpixel,
   diagonal, off-axis triples, etc).
5. Verify the SMP codepoints UTF-8-encode to 4 bytes each in the
   diff-renderer pipeline (already handled — `egc: String` accepts any
   UTF-8 sequence).

## Why deferred to a follow-up

The transcription is tedious (~230 entries) and error-prone if rushed.
Phase 6.6.0 ships a fully-working blitter at three quality tiers
(Quadrant, Half, Ascii) with full coverage; the 16-pattern Octant
partial implementation lets apps opt into the highest tier today and
gain fidelity for free as the table fills in. No app-level API change
is required to consume the full table once it lands.

## Acceptance

- [ ] All 256 patterns produce a correct-looking glyph under
  `OctantQuality::Octant`.
- [ ] Spec coverage: at least one representative non-reused pattern
  from each Unicode page (U+1CD0x, U+1CD2x, ..., U+1CDDx).
- [ ] `quake guard` green; smoke tests green; existing 39-test
  octant spec stays green (no regression).

## Related

- `std/tui/octant.qz` — current partial implementation
- `spec/qspec/tui_v06_octant_spec.qz` — current 39-test spec
- `docs/design/TUI_V06_CELL_ENGINE.md` D6 — design rationale
- Unicode 17 chart — authoritative codepoint reference
