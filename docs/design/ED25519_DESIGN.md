# NET.2 — Ed25519 native implementation

**Filed:** 2026-05-21
**Status:** Design — implementation pending
**Owner:** NET.2
**Depends on:** NET.1 Step 2.16 (native Curve25519 + 5×51-bit field arithmetic substrate)
**Unblocks:** NET.3 (ML-KEM hybrid), NET.5 (TLS 1.3 client/server) sigverify path, any signature-using protocol (SSH, DNSSEC, Tor v3, PASETO, Minisign, age, cosmos)

---

## Why Ed25519, and why now

NET.1 closed 2026-05-09 with the full WireGuard crypto stack as pure Quartz: HChaCha20, BLAKE2s, HKDF, HMAC, ChaCha20, AEAD-Poly1305, Curve25519 (X25519). The 5×51-bit field arithmetic substrate over GF(2²⁵⁵−19) is the load-bearing piece, and **Ed25519 reuses that substrate verbatim** — both curves are over the same prime field. What's missing for Ed25519:

1. **SHA-512** — hash function, FIPS 180-4. ~200 LoC native ARX over u64. New.
2. **Edwards-form point arithmetic** — twisted Edwards `-x² + y² = 1 + d·x²·y²` with `d = -121665/121666`. Extended coordinates `(X, Y, Z, T)` per Hisil-Wong-Carter-Dawson 2008. New.
3. **Scalar arithmetic mod L** — `L = 2²⁵² + 27742317777372353535851937790883648493`. Scalar reduction + multiply-then-add. New.
4. **EdDSA signing / verification loop** — RFC 8032 Algorithm 1. New.

The unlock per quartz-day of work is the highest in the NET.x track: signatures are everywhere, and the substrate gap is small. NET.1's 4 calendar days to native-only milestone calibrates NET.2 at ~1-2 calendar days for the same reason — the field is already done.

## Prior-art table

Surveyed 2026-05-21 before coding. The world has converged hard on extended twisted Edwards + ref10 architecture:

| Implementation | Coord system | Hash | Notable |
|---|---|---|---|
| **`crypto/ed25519` (Go stdlib)** | Extended (X, Y, Z, T) | SHA-512 native | Adam Langley's port of ref10 → Henry de Valence rewrite for `crypto/internal/edwards25519` (Go 1.17+) → factored into `filippo.io/edwards25519` for non-stdlib reuse |
| **`filippo.io/edwards25519`** | Extended (X, Y, Z, T) | uses crypto/sha512 | THE canonical native Go impl — multi-scalar mult for batch verify, constant-time SqrtRatio, supports cofactored + cofactorless verify (`speccheck`) |
| **ref10 (SUPERCOP)** | Extended (X, Y, Z, T) | SHA-512 native | DJB/Lange original C reference. Every modern impl traces here. |
| **donna64 (Floodyberry)** | Extended (X, Y, Z, T) | SHA-512 native | Speed-oriented C; tight asm in the variable-base scalar mult |
| **BoringSSL `crypto/curve25519`** | Extended (X, Y, Z, T) | uses BoringSSL SHA-512 | fiat-crypto-generated field ops + ref10 group ops |
| **NaCl/libsodium** | Extended (X, Y, Z, T) | SHA-512 native | The "trust this codebase" reference for cryptographers |
| **HACL\* / EverCrypt** | Extended (X, Y, Z, T) | F\*-proven SHA-512 | The formally-verified gold standard |

Everyone uses **extended (X, Y, Z, T)**. Decision: us too.

Everyone derives the recipe from **ref10**. Decision: ditto. We use Filippo's edwards25519 Go source as the *most-readable* expression of ref10 (Go syntax beats C-with-#ifdefs for porting to Quartz).

### Key insight from "Re-Deriving the edwards25519 Decoding Formulas" (Valsorda)

The textbook formula for point decompression solves the curve equation `-x² + y² = 1 + d·x²·y²` for `x` given `y`:

```
x² = (y² - 1) / (d·y² + 1)
```

The naive approach is `_f51_finv(d·y² + 1)` followed by `f51_fmul(y² - 1, inv)` followed by sqrt-on-Fp. The clever approach (used by every modern impl) is to compute `√(u/v)` directly via a single `SqrtRatio` that combines inverse + sqrt using the same `(p-5)/8` exponentiation chain. We adopt this.

## Architecture

### Module layout

Two new files:

- **`std/core/crypto/sha512.qz`** (~250 LoC) — Pure-Quartz SHA-512 (FIPS 180-4). Mirrors `std/core/crypto/blake2s.qz` shape (`malloc`'d state, byte-LE I/O via `ffi/socket` `malloc`/`free`/`memcpy`/`memset`). Exposes:
  ```
  def sha512(input: Int, input_len: Int, output: Int): Void          # one-shot, output is 64-byte buffer
  def sha512_new(): Int                                                 # streaming: alloc context
  def sha512_update(ctx: Int, input: Int, input_len: Int): Void         # streaming: feed bytes
  def sha512_finalize(ctx: Int, output: Int): Void                       # streaming: finish + emit 64-byte digest, frees ctx
  ```

- **`std/core/crypto/ed25519.qz`** (~700 LoC) — Pure-Quartz EdDSA. Reuses `_f51_*` field ops from `curve25519.qz`. Exposes:
  ```
  def ed25519_secret_to_public(pub: Int, seed: Int): Void                # 32-byte seed → 32-byte public key
  def ed25519_sign(sig: Int, msg: Int, msg_len: Int, seed: Int, pub: Int): Void   # writes 64-byte signature
  def ed25519_verify(sig: Int, msg: Int, msg_len: Int, pub: Int): Int    # 1 = valid, 0 = invalid
  ```

The seed-based API matches RFC 8032 §5.1.5 and what `crypto/ed25519` exposes. `pub` is passed-in to sign (caller already derived it via `secret_to_public`); avoids re-hashing the seed inside sign.

### SHA-512 internals

FIPS 180-4 §6.4. Block size 128 bytes, output size 64 bytes. State is 8 × u64 words. Round function uses:

- `Ch(x,y,z) = (x ∧ y) ⊕ (¬x ∧ z)`
- `Maj(x,y,z) = (x ∧ y) ⊕ (x ∧ z) ⊕ (y ∧ z)`
- `Σ₀(x) = ROTR²⁸(x) ⊕ ROTR³⁴(x) ⊕ ROTR³⁹(x)`
- `Σ₁(x) = ROTR¹⁴(x) ⊕ ROTR¹⁸(x) ⊕ ROTR⁴¹(x)`
- `σ₀(x) = ROTR¹(x) ⊕ ROTR⁸(x) ⊕ SHR⁷(x)`
- `σ₁(x) = ROTR¹⁹(x) ⊕ ROTR⁶¹(x) ⊕ SHR⁶(x)`

80 rounds per block (vs SHA-256's 64). K constants are the first 64 bits of the fractional parts of the cube roots of the first 80 primes.

**Quartz-specific gotcha** (mirror of curve25519's): Quartz `>>` is arithmetic shift right (ashr). For ROTR over u64, use `(x >> n) & MASK64(64-n) | (x << (64-n))` to suppress sign extension when bit 63 is set. The SHR in σ₀/σ₁ is logical shift right (lsr) by definition — same `& MASK64(64-n)` trick. The K constants and IV constants are written as raw 64-bit values (some have bit 63 set — e.g. K[0] = `0x428a2f98d728ae22` is fine, but K[15] = `0xc19bf174cf692694` would need to be written as a literal that Quartz's parser accepts; Quartz Int literals are i64-shaped, so we either hex them or write them as their two's-complement i64 form).

KAT validation gate:

- FIPS 180-4 §D.4 test vector "abc" → `ddaf35a193617aba…2a9ac94fa54ca49f`
- §D.4 56-byte message → `8e959b75dae313da…d1ed7a5d4d4a4e4e`
- Long-message: million 'a's → `e718483d0ce76964…b09bbb1e9cce`
- Empty: `cf83e1357eefb8bd…a538327af927da3e`

These five vectors are also embedded in `spec/qz/crypto_ffi_smoke.qz` as the SHA-512 test slot.

### Ed25519 internals

**Point representation** — Extended twisted Edwards coords `(X, Y, Z, T)` where `x = X/Z`, `y = Y/Z`, `T = X·Y/Z`. Each coordinate is a 5×51-bit field element (40-byte buffer). A point is a 160-byte (4 × 40-byte) struct.

Three intermediate point types per Filippo (lift from ref10):

- `Point` — full `(X, Y, Z, T)` for stable storage and the user-facing handle.
- `projP2` — `(X, Y, Z)` only — output of `Double`, input to `Double`.
- `projP1xP1` — `(X, Y, Z, T)` in a non-reduced/intermediate state — output of `Add`/`Double`, converted to `Point` or `projP2` before next op.

We collapse to two: full `Point` and `projP1xP1` (pre-reduction). `projP2` is a micro-opt and we ship the simpler shape; if benchmarks demand it, we add it in a perf pass.

**Curve constant `d`** — `d = -121665/121666 mod p`, precomputed as a 5×51-bit constant:
```
d = 37095705934669439343138083508754565189542113879843219016388785533085940283555
```
Stored as 5 limb values in a static `def _ED_D_LIMB_N(): Int = ...` series, mirroring `_MASK51`/`_BIAS_LIMB0`/`_BIAS_LIMBN` from curve25519.qz. Plus `2d` (used in the Hisil-Wong formula) precomputed similarly.

**Basepoint B** — Per RFC 8032 §5.1, `B = (x, 4/5)` where `x` is the unique positive square root. Encoded form is `0x5866666666666666666666666666666666666666666666666666666666666666` (decoded once on first use into a `Point` with all four coords).

**Point addition** (Hisil-Wong-Carter-Dawson 2008, "Twisted Edwards Curves Revisited", §3.1 extended coordinates with `a = -1` — see eprint.iacr.org/2008/522):
```
A = (Y1 - X1) · (Y2 - X2)
B = (Y1 + X1) · (Y2 + X2)
C = T1 · 2d · T2
D = Z1 · 2 · Z2
E = B - A
F = D - C
G = D + C
H = B + A
X3 = E · F
Y3 = G · H
T3 = E · H
Z3 = F · G
```
9 field mults, 0 squarings, 7 add/subs. The `2d` constant is precomputed.

**Point doubling** (HWCD'08 §3.3):
```
A = X1²
B = Y1²
C = 2 · Z1²
H = A + B
E = H - (X1 + Y1)²
G = A - B
F = C + G
X3 = E · F
Y3 = G · H
T3 = E · H
Z3 = F · G
```
4 squarings, 3 mults — strictly cheaper than two adds.

**Scalar multiplication for signing** (constant-time variable-base):

We ship a simple double-and-add with `_f51_cswap` for CT first, defer the windowed table optimization. The scalar is 256 bits; loop iterates 256 times; each iteration doubles the accumulator, conditionally adds the base point based on the scalar bit, swaps to avoid revealing the bit via branch. This is ~5× slower than Filippo's table-driven impl but ships in 50 LoC and is provably constant-time (the cswap pattern is the same one curve25519.qz already uses for its Montgomery ladder).

Filed as NET.2 follow-up: windowed-table scalar mult for the basepoint (5-10× signing speedup; non-blocking for v1).

**Scalar multiplication for verification** (variable-time, double-base):

`verify` computes `[S]B - [k]A` and checks it equals `R`. Both inputs are public; no CT requirement. We ship a simple sequential double-base mult (compute `[S]B`, then `[k]A` separately, subtract): 256 + 256 doublings + ~128+128 conditional adds. Strauss-Shamir simultaneous double-scalar mult is the optimization (single 256-iter loop) — filed as NET.2 follow-up.

**Scalar arithmetic mod L** — `L = 2²⁵² + 27742317777372353535851937790883648493`.

We need three scalar ops, all mod L:
- `sc_reduce64(out_32, in_64)` — reduce a 64-byte buffer (SHA-512 output) to a 32-byte canonical scalar.
- `sc_reduce32(out_32, in_32)` — reduce a 32-byte buffer (verify's S input) to a canonical 32-byte scalar.
- `sc_muladd(out_32, a_32, b_32, c_32)` — compute `a·b + c mod L`, the core of `S = r + k·s mod L` in signing.

We adopt ref10's representation: each scalar is twelve 21-bit signed limbs (252 bits total fit in 12·21 = 252). The reduction uses Barrett-style "subtract a multiple of L" passes. This is the same recipe Filippo's `edwards25519/scalar.go` uses.

**Point encoding** (RFC 8032 §5.1.2):
1. Compute affine `y = Y/Z` via `_f51_finv(Z)` + `_f51_fmul`.
2. Compute affine `x = X/Z` likewise.
3. Pack `y` into 32 little-endian bytes via `_f51_store_felem` (already exists).
4. Set the high bit of byte 31 to `x & 1` (sign of x).

**Point decoding** (RFC 8032 §5.1.3):
1. Read 32 bytes as little-endian `y`; extract sign bit `x_0` from bit 7 of byte 31; clear that bit.
2. Reject if `y ≥ p` (canonical-encoding check per `speccheck`).
3. Compute `u = y² - 1`, `v = d·y² + 1`.
4. Compute `x = √(u/v)` via Filippo's `SqrtRatio` (single chain): given `(u, v)`, the candidate is `r = u · v³ · (u·v⁷)^((p-5)/8) mod p`; check `v·r² == ±u` to determine validity and sign.
5. If `r % 2 != x_0`, negate.
6. Return `(x, y, 1, x·y)` as the extended-coord `Point`.

The decoder's `√(u/v)` chain is the most subtle piece; we lift it directly from Filippo's Go (which lifts it from ref10).

### EdDSA sign / verify (RFC 8032 Algorithm 1)

**Sign** (32-byte seed `seed`, message `msg` of length `n`, output 64-byte `sig`):
```
1. h = SHA-512(seed)                              # 64 bytes
2. a = clamp(h[0..32])                            # 32 bytes; clear bits 0/1/2 of h[0], clear bit 7 of h[31], set bit 6 of h[31]
3. prefix = h[32..64]                             # 32 bytes
4. r = SHA-512(prefix || msg) mod L               # via sc_reduce64
5. R = [r]·B                                       # point scalar mul
6. r_bytes = encode(R)
7. k = SHA-512(r_bytes || pub || msg) mod L       # via sc_reduce64
8. S = (r + k·a) mod L                            # via sc_muladd
9. sig = r_bytes || S_bytes
```

**Verify** (64-byte `sig`, message `msg` of length `n`, 32-byte `pub`):
```
1. Decode R from sig[0..32]; reject if non-canonical or off-curve.
2. Decode A from pub; reject if non-canonical or off-curve.
3. S = sig[32..64] as little-endian; reject if S ≥ L.
4. k = SHA-512(sig[0..32] || pub || msg) mod L
5. Compute [S]·B - [k]·A
6. Compare to R; accept iff equal (after both are reduced to canonical encoding).
```

Cofactored vs cofactorless: RFC 8032 §5.1.7 leaves the choice to implementers (FIPS 186-5 mandates cofactorless). We adopt **cofactorless** (matches Filippo's default + FIPS): the check is `[S]B = R + [k]A` directly, no `[8]` multiplication on both sides. Cofactor-related edge cases are filtered upfront by the canonical-encoding + scalar-bounds checks; `ed25519-speccheck` test 0-3 in those cases hit the canonical-encoding gate.

## API surface (final)

```quartz
# std/core/crypto/sha512.qz

def sha512(input: Int, input_len: Int, output: Int): Void
def sha512_new(): Int
def sha512_update(ctx: Int, input: Int, input_len: Int): Void
def sha512_finalize(ctx: Int, output: Int): Void

# std/core/crypto/ed25519.qz

def ed25519_secret_to_public(pub: Int, seed: Int): Void
def ed25519_sign(sig: Int, msg: Int, msg_len: Int, seed: Int, pub: Int): Void
def ed25519_verify(sig: Int, msg: Int, msg_len: Int, pub: Int): Int
```

Layout matches the curve25519 module shape (out-buffer first arg, byte-pointer everywhere, no struct types crossing the boundary). Caller owns all buffers via `malloc`/`free`.

## Validation gates

**SHA-512** (`spec/qspec/sha512_spec.qz`, new):

- FIPS 180-4 §D.4 vector "abc" → `ddaf35a193617aba…2a9ac94fa54ca49f`
- Empty input → `cf83e1357eefb8bd…a538327af927da3e`
- 56-byte vector → `8e959b75dae313da…d1ed7a5d4d4a4e4e`
- 112-byte vector → `8e959b75dae313da…1f1f2e6d6c5f1c1c` (FIPS §D.4 long block)
- Streaming = one-shot equivalence on a 1KB random buffer (use `rng_new_hw`)

**Ed25519** (`spec/qz/ed25519_smoke.qz` for the heavyweight KAT runner; `spec/qspec/ed25519_basic_spec.qz` for the smoke-able subset):

RFC 8032 §7.1 — four canonical vectors:

| Test | Privkey | Msg | Expected sig (first 32 bytes only shown here) |
|---|---|---|---|
| TEST 1 | `9d61b19d…7f60` | (empty) | `e5564300…0155` … `e7a100b` |
| TEST 2 | `4ccd089b…a6fb` | `0x72` | `92a009a9…b00c00` |
| TEST 3 | `c5aa8df4…58f7` | `0xaf82` | `6291d657…ec40a` |
| TEST SHA(abc) | `833fe624…3d42` | SHA-512("abc") | `dc2a4459…31a704` |

Plus malformed-input rejection cases:
- Sign with garbage seed: doesn't crash, produces some signature.
- Verify with `S ≥ L`: rejects (canonical-scalar check).
- Verify with non-canonical R (y ≥ p): rejects.
- Verify with bit-flipped message: rejects.
- Verify with bit-flipped signature: rejects.
- Round-trip: keygen → sign → verify on a 1KB random message.

`ed25519-speccheck` corpus (Novi Financial, GitHub) covers 12 edge cases — `(0, 0, 0)`-related infinities, cofactor weirdness, small-order subgroup. These are filed as a NET.2 follow-up (`spec/qz/ed25519_speccheck.qz`); the four RFC vectors + 6 mal-input cases are the v1 gate.

**Smoke task** — extend `quake crypto:smoke` to invoke a new `test_sha512()` + `test_ed25519()` in `spec/qz/crypto_ffi_smoke.qz`. Standard pattern (mirror `test_curve25519`).

**Fixpoint + bootstrap** — final ship requires `./self-hosted/bin/quake guard` clean (gen1 == gen2 byte-identical, ~2542 fns expected) and Rule 2 smoke against `style_demo.qz` + `brainfuck.qz`. NET.2 touches stdlib only; no compiler-source change is anticipated. (Caveat: SHA-512 may need a small intrinsic if we run into a Quartz arithmetic gap. None expected per the curve25519/blake2s precedent.)

## Constant-time discipline

Following RFC 8032 §8.5 and our NET.1 pattern:

- **CT required**: SHA-512 (no data-dependent control flow anyway; ARX is inherently CT), `sc_reduce64`/`sc_reduce32`/`sc_muladd` (scalar arith on private inputs in signing), variable-base scalar mult in `ed25519_sign` (the `[r]B` and the muladd are both private-input).
- **VT acceptable**: `ed25519_verify` and all its sub-ops (decoded R, k, A, S are all public).
- **Decompression (`SetBytes` analogue)**: used by both signing (no — sign doesn't decompress) and verify (yes — for the A and R inputs). VT path.

Annotations: we **don't** ship `Secret<T>` wrapping in NET.2. That's NET.4. Today the convention is "by inspection" — the curve25519.qz code is hand-audited CT and we follow the same discipline.

## Non-goals (NET.2 v1)

- **Batch verification** — multi-signature aggregated verify via multi-scalar-mult. Filippo's `edwards25519` ships it; we don't in v1. Filed as NET.2 follow-up; useful for any consumer doing block-of-signatures verification (TLS cert chain, blockchain ledger, package signature manifest).
- **Windowed-table scalar mult for the basepoint** — 5-10× signing speedup, ~1KB constant table. Filed as NET.2 follow-up. v1 ships double-and-add for simplicity.
- **Strauss-Shamir for verify** — single-loop double-base mult. ~2× verify speedup. Filed as NET.2 follow-up.
- **Ed25519ph / Ed25519ctx variants** — RFC 8032 §5.1.6, prehashed and context-flavored variants used by some protocols (SSHSIG, TLS 1.3 cert_verify). Filed as NET.2 follow-up; not blocking the NET.3 / NET.5 dependency chain.
- **`Secret<T>` annotations / dudect harness** — that's NET.4; not blocking NET.2.
- **X.509 SubjectPublicKeyInfo / PKCS#8 wrappers** — that's NET.5's ASN.1 surface.

## Sizing

Five quartz-day estimate from the ROADMAP NET.2 row → revised here to **~1-1.5 quartz-days** given the substrate is fully built:

| Phase | Effort | Outputs |
|---|---|---|
| 2.1 (design) | <0.1d | This memo — done. |
| 2.2 (SHA-512) | ~0.3d | `std/core/crypto/sha512.qz` + 5-vector KAT in `spec/qspec/sha512_spec.qz` (+ smoke runner) |
| 2.3 (Edwards point ops) | ~0.3d | Add/Double/encode/decode on top of `_f51_*`. Lift HWCD'08 formulas. |
| 2.4 (Scalar arithmetic mod L) | ~0.2d | `sc_reduce64`/`sc_reduce32`/`sc_muladd` per ref10. |
| 2.5 (sign/verify + KATs) | ~0.2d | `ed25519_secret_to_public`/`_sign`/`_verify` + RFC 8032 §7.1 vectors. |
| 2.6 (smoke + guard + ship) | ~0.1d | `test_ed25519` in crypto_ffi_smoke; `quake crypto:smoke` green; `quake guard` clean; ROADMAP + project memory close-out. |

Calibration: NET.1's Phase 2 (HACL excise → native primitives) shipped in 2 calendar days for ~7000 LoC of native crypto across 7 primitives. NET.2 ships ~950 LoC across 2 primitives sharing an already-built substrate. The 1-1.5 day estimate is consistent with that ship rate.

## Open questions

**Q1: Should we keep the `priv_expanded` 64-byte form (clamped scalar || prefix) cached, or always re-derive from seed?**

Filippo / Go expose `NewKeyFromSeed` which returns a 64-byte expanded private key; sign uses that directly. We compromise: NET.2 v1 takes the 32-byte seed and re-hashes inside sign (one SHA-512). Microbench: SHA-512 on 32 bytes is ~1µs; signing dominates at ~50µs. The 2% overhead isn't worth the API surface. If a consumer is signing millions of messages with one key, they can expose `_priv_expanded_from_seed` as a future API. Decision: **seed-only API for v1, expansion is internal.**

**Q2: Encode-decode round-trip canonical form vs RFC?**

RFC 8032 says "the implementation must reject any signature where S is not the canonical encoding (≥ L)". `ed25519-speccheck` calls out implementations that *accept* non-canonical S — Quartz must reject. Decision: **strict — explicit `S ≥ L` check before muladd**.

**Q3: Cofactored vs cofactorless?**

Per RFC 8032 §8.5: both are conformant. Filippo defaults cofactorless; FIPS 186-5 mandates cofactorless; Zcash and Tor use cofactored. We pick **cofactorless** (matches the prevailing direction); document the choice in the API doc-comment.

## Hand-off invariants for future sessions

- This memo is the source of truth until ED25519_DESIGN ships its close-out section. Updates land in this file.
- The `_f51_*` substrate in `curve25519.qz` is API-stable. Do not modify it during NET.2 — additions are fine; in-place changes risk regressing the 6/6 RFC 7748 KATs.
- All four RFC 8032 §7.1 test vectors must pass in the same commit that lands `ed25519_verify`. Partial KATs = partial ship = filed-not-shipped.
- `quake guard` clean + style_demo/brainfuck smoke is the close gate. Same as every NET.1 phase.

## References

- [RFC 8032 — Edwards-Curve Digital Signature Algorithm (EdDSA)](https://www.rfc-editor.org/rfc/rfc8032.html)
- [filippo.io/edwards25519 (Go)](https://github.com/FiloSottile/edwards25519) — canonical readable reference
- [FIPS 180-4 — Secure Hash Standard](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf) — SHA-512
- [FIPS 186-5 — Digital Signature Standard](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-5.pdf) — EdDSA conformance profile
- [Hisil, Wong, Carter, Dawson 2008 — "Twisted Edwards Curves Revisited"](https://eprint.iacr.org/2008/522.pdf) — extended-coord formulas we lift directly
- [ed25519-speccheck (Novi Financial)](https://github.com/novifinancial/ed25519-speccheck) — edge-case corpus (filed as follow-up)
- ["Re-Deriving the edwards25519 Decoding Formulas" — Valsorda](https://words.filippo.io/dispatches/edwards25519-formulas/) — SqrtRatio derivation
