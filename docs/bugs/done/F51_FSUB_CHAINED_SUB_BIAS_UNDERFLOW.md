# `_f51_fsub` chained subtractions underflow the +8p limb bias

> **FIXED 2026-07-07 (commit a0ddd33b).** Landed doc option 1: added
> `_f51_fsub_2x(out, f1, f2)` in `std/core/crypto/curve25519.qz` with a
> doubled 16p per-limb bias (`_BIAS2_LIMB0` / `_BIAS2_LIMBN`), and reverted
> `std/core/crypto/ed25519.qz::_pt_double` to the natural HWCD'08 shape
> `rt = C - (B - A)` via `_f51_fsub_2x(rt, cc, rz)`. ed25519:smoke 29/29,
> crypto:smoke all green; guard fixpoint byte-identical (gate-1-inert —
> crypto is not in the self-host dependency graph).

**Filed:** 2026-05-21 (surfaced during NET.2 Ed25519 implementation)
**Severity:** Medium — silent miscompile at consumer call sites. No crash; the
bug produces wrong arithmetic results that downstream tests catch via KAT
mismatch.
**Status:** Worked around at the NET.2 consumer; **root cause unfixed**. The
fix is a library-level addition to `std/core/crypto/curve25519.qz` — either a
wider-bias `_f51_fsub_2x` for chained subtraction OR a `_f51_weak_reduce`
normalize helper. Until then every donna64-pattern consumer (NET.2 today;
NET.3's ML-KEM polynomial arithmetic is structurally different so it won't
hit this; NET.5's TLS sigverify will be Ed25519-mediated and inherit the
fix-once-fixes-all property) has to discover this trap manually.

## Repro / surface

`std/core/crypto/curve25519.qz`'s `_f51_fsub(out, f1, f2)` adds a per-limb
bias of `8 * p_limb_i` ≈ 2⁵⁴ to keep results non-negative without limb
overflow:

```
out[i] = f1[i] + 8*p_limb[i] - f2[i]
```

This works correctly **only when `f2[i]` is canonical-magnitude** (≤ 2⁵¹,
which is what `_f51_fmul` / `_f51_fsqr` emit after the carry chain).

When `f2` is itself the output of a prior `_f51_fsub` (limbs ≤ 2⁵⁴ ≈ bias),
then `bias - f2[i]` can dip slightly below zero on some limbs, and the
result feeds into `_f51_fmul` as a negative i64 limb. `_f51_fmul`'s carry
chain assumes non-negative limbs (the `(x >> 51) & 8191` carry-extraction
pattern doesn't handle ashr of a negative number safely — same gotcha class
as `feedback_curve25519_ashr_carry_extraction.md`, surfaced one layer up).

NET.2's `_pt_double` first cut wrote the doubling formula's `rt`
coordinate as:

```quartz
_f51_fsub(rz, bb, aa)         # rz = B - A  (one fsub off canonical, OK)
_f51_fsub(rt, cc, rz)         # rt = C - rz  ← f2 = rz is a fsub output (BAD)
```

Symptom: `_pt_double(B)` produced a different projective point than
`_pt_add(B, B)`. Both should yield the same `[2]B` after encoding through
affine `(X/Z, Y/Z)`, but they disagreed at the byte level. RFC 8032 §7.1
TEST 1/2/3/SHA(abc) public-key derivations all failed against the published
vectors.

Fix at the call site: reorder the subtraction so the f2 of every `_f51_fsub`
stays canonical-magnitude:

```quartz
_f51_fadd(t, cc, aa)          # t = C + A  (one fadd, ≤ 2^53)
_f51_fsub(rt, t, bb)          # rt = (C + A) - B  ← f2 = bb canonical, OK
```

After the reorder, all 4 RFC 8032 §7.1 KATs pass and `quake ed25519:smoke`
goes from 3/14 (only the tamper-rejection cases — which trivially passed
because the verify path also returned the wrong answer) to 29/29.

## Why it's a library API issue, not a consumer bug

Every reference Ed25519 implementation (ref10, donna64, Filippo's
`edwards25519`, BoringSSL, NaCl) uses the natural HWCD'08 formula `rt = C -
(B - A)`. Implementations whose field library reduces after every op (ref10
with its 25/26-bit signed limbs; Filippo's field.Element with explicit
weak-reduce) can chain subtractions freely. Quartz's `_f51_*` follows the
donna64 representation where limbs accumulate; the chained-sub case is the
one ergonomic gap.

The fix is one of:

1. **`_f51_fsub_2x(out, f1, f2)` — wider-bias variant** (~5 LoC). Add 16p
   instead of 8p; that brings the minimum result from `bias - f2_max` ≈
   `2⁵⁴ - 2⁵⁴` ≈ 0 to `2*bias - f2_max` ≈ `2⁵⁵ - 2⁵⁴` ≈ 2⁵⁴ — safely
   positive. Consumers documentation says: "use this when f2 is the result
   of a prior fsub or another non-canonical operation." Trade-off: the
   resulting limbs are larger (≤ 2⁵⁶ instead of ≤ 2⁵⁵), which costs one bit
   of headroom into the next `_f51_fmul` — still well within fmul's safe
   range.

2. **`_f51_weak_reduce(io)` — in-place normalize** (~30 LoC). Single carry
   chain pass that brings any-limb-magnitude input back to canonical
   (≤ 2⁵¹). Slower than option 1 (touches every limb), but produces
   canonical output that's safe for any downstream consumer including
   `_f51_fmul`. Equivalent to `_f51_fmul1(io, io, 1)` but optimised for
   the multiply-by-1 case.

3. **Documentation only** — leave the library as-is; document the chained-
   sub trap inline in `curve25519.qz` and in `docs/STYLE.md`'s crypto
   section. Cheap; relies on every future donna64-style port consumer
   reading the docstring before writing code.

Recommendation: **option 1** (the `_f51_fsub_2x` helper). It's the smallest
ergonomic addition; the cost is one extra limb-bit which the existing
`_f51_fmul` happily absorbs; future ports can use the natural HWCD'08
formula without contortion. Filed at this severity (medium) because the
work isn't blocking — NET.2 shipped via the call-site reorder — but
discovering it cost a debug cycle.

## Sister gotchas to audit when fixing

- `_f51_fmul`'s carry chain at the `((x >> 51) & 8191) | (s1_hi << 13)`
  pattern (~6 sites in `curve25519.qz`). Same ashr-vs-lsr issue if any
  intermediate `s_i` ever sits above 2⁶³. Currently safe because limbs are
  bounded ≤ 2⁵⁸-ish, but if a wider-input precondition were ever relaxed,
  this would need re-audit. Sister memo:
  `feedback_curve25519_ashr_carry_extraction.md`.
- `_f51_pow_p_minus_5_div_8` (added in NET.2's `ed25519.qz`): a 254-square
  + 11-multiply chain on a felem. Squaring outputs are canonical, so this
  is safe today. Audit when adding more pow-chains.

## Worked-around call sites (consumers to update once the helper lands)

- `std/core/crypto/ed25519.qz::_pt_double` — the `rt = (C + A) - B` reorder.
  When `_f51_fsub_2x` ships, this can revert to the natural `rt = C - rz`
  shape and read like the textbook HWCD'08 formula.

## Validation when fixing

- Existing `quake ed25519:smoke` covers the path; the reorder workaround
  produces identical output to the natural formula, so the fix doesn't
  invalidate the test corpus.
- Fixpoint via `quake guard` must stay clean (curve25519.qz is in the
  compiler's self-host dependency graph; any change rebuilds the binary).
- Sister `quake crypto:smoke` exercises curve25519 + chacha20 +
  poly1305 + blake2s + hkdf + noise — would catch any regression in
  curve25519's existing fsub-consuming paths.

## References

- [HWCD'08 — Twisted Edwards Curves Revisited](https://eprint.iacr.org/2008/522.pdf) §3.3 dbl-2008-hwcd
- [filippo.io/edwards25519 field.Element](https://github.com/FiloSottile/edwards25519/blob/main/field/fe.go) — Go reference for the "weak reduce" approach
- `feedback_curve25519_ashr_carry_extraction.md` — sibling gotcha class.
- `docs/design/ED25519_DESIGN.md` — surfaces this gotcha in §"Quartz-specific gotcha (worth filing forward)".
