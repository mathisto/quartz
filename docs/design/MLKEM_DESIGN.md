# NET.3 — ML-KEM-768 + SHA-3 + Hybrid X25519+ML-KEM

**Filed:** 2026-05-21
**Status:** Design — implementation pending
**Owner:** NET.3
**Depends on:** NET.1 Step 2.16 (native Curve25519 substrate, for hybrid). NET.2 satisfies the SHA-2 dependency but is **not** load-bearing for ML-KEM itself — ML-KEM uses SHA-3 (FIPS 202), not SHA-2.
**Unblocks:** NET.5 (TLS 1.3 with `X25519MLKEM768` codepoint 0x11EC), HPKE-PQ, any post-quantum-secure protocol stack on the Quartz unikernel.

---

## Why ML-KEM-768, and why now

FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism Standard) was finalised August 2024. The hybrid `X25519MLKEM768` cipher suite was assigned IANA codepoint **0x11EC** (4588) in TLS 1.3 in 2024–2025 and is **already deployed in production** by Cloudflare (default for client connections to Cloudflare-fronted sites since Q4 2024), Google Chrome (default since Chrome 124, April 2024 — pre-final draft `X25519Kyber768Draft00`, then switched to FIPS 203 final via `X25519MLKEM768` in late 2024), Apple iMessage (PQ3, Feb 2024 — uses ML-KEM internally), and Signal (PQXDH, Sept 2023 — ML-KEM-768 over the curve25519 spine).

Quartz shipping native ML-KEM puts the language in **rare company** — Go (1.24+, native `crypto/mlkem`), Rust (`RustCrypto/ml-kem`, `libcrux-ml-kem`), C (BoringSSL, AWS-LC, libgcrypt), and Java (Bouncy Castle FIPS 3.0.0) are the production-language baseline. Everyone else (Python/Ruby/JS/etc.) is on C bindings. NET.1 already established that Quartz can ship native crypto at the same level as the C languages; NET.3 extends that to post-quantum primitives — closing the last "we'd have to bind C for that" hole in our crypto story.

The substrate gap vs NET.1/NET.2 is **moderate**: SHA-3 is new (no SHA-2-style ARX substrate transfers — Keccak is bit-level over a 5×5 lane state). ML-KEM brings new arithmetic (Z_q polys over a small prime, NTT, rejection sampling) but no bigint and no field-over-2²⁵⁵−19 work. Hybrid is ~100 LoC of byte-concatenation + HKDF/SHA3 glue.

## Prior-art table

Surveyed 2026-05-21 before coding. Column key: **FIPS-203 final?** distinguishes implementations tracking the August 2024 standard from those still on the Kyber-r3 / IPD drafts (they are **not** interchangeable — see §"IPD→final changes" below). **NTT layout** — `M` = stores coefficients in Montgomery domain (faster mul, requires invariant tracking), `P` = stores plain mod q + Barrett (simpler audit). **Combiner** — built-in TLS-style hybrid KEM in tree, or only the bare KEM primitive.

| Implementation | Lang | License | FIPS 203 final | NTT layout | ACVP-tested | Hybrid X25519+ML-KEM-768 in tree |
|---|---|---|---|---|---|---|
| **Cloudflare CIRCL `kem/mlkem`** | Go | BSD-3 | Yes | M (Montgomery, Barrett+Montgomery mix, `Zetas[i]=ζ^brv(i)·R mod q`) | Yes | Yes — `kem/hybrid` + `kem/xwing` |
| **Go stdlib `crypto/mlkem`** (was `FiloSottile/mlkem768`) | Go | BSD | Yes; **seed-as-key advocate** | P (plain mod q, no Montgomery — readability-first) | Yes | Yes — used by Go `crypto/tls` `X25519MLKEM768` |
| **RustCrypto `ml-kem`** | Rust | MIT/Apache-2 | Yes | P (plain mod q + Barrett-only, `ZETA_POW_BITREV[i]=17^brv(i) mod q`) | Yes | External (`hybrid-array` crate generics; users compose) |
| **`cryspen/libcrux-ml-kem`** | Rust → F* via hax | Apache-2 | Yes | P (portable + AVX2 + Neon SIMD variants) | Yes; **formally verified** (panic-freedom, correctness, secret-independence via F* + hax) | Indirectly via `libcrux-kem` |
| **BoringSSL / AWS-LC** | C / Rust wrapper | ISC / Apache-2 | Yes — **first FIPS-140-3-validated ML-KEM** (AWS-LC FIPS 3.0) | M, vector-NTT (AVX2/NEON) | Yes | Yes — TLS X25519MLKEM768 wired |
| **liboqs / oqs-provider** | C / OpenSSL provider | MIT | Yes (liboqs 0.11.0, 2024-09-26) | M (pq-crystals reference layout) | KAT | Yes — X25519MLKEM768 in OpenSSL 3 provider |
| **pq-crystals/kyber reference** | C | Apache-2/CC0 | Yes (since 2024-09) | M | KAT-only (no ACVP harness in-tree) | No (reference only) |
| **Bouncy Castle FIPS 3.0.0** | Java / C# | MIT-style | Yes | P (Java BigInteger-style) | KAT; ACVP via vendor pipeline | Yes (via JCE) |

**Headline observations driving Quartz design:**
1. **Mainstream splits on NTT representation.** Production-FIPS-validated impls lean Montgomery (CIRCL, BoringSSL, liboqs, pq-crystals) — ~10–15% mul speedup. Readability-and-audit-first impls lean plain mod-q + Barrett (RustCrypto, libcrux, Go stdlib). **Decision: plain mod q + Barrett for Quartz NET.3 v1.** Auditability beats a speedup we don't need yet; matches our NET.1 "ship the simpler shape first, add the perf pass later" pattern. Montgomery filed as NET.3 follow-up.
2. **Combiner location splits cleanly along protocol vs primitive.** TLS-layer combiners (BoringSSL, oqs-provider, Go's `crypto/tls`) live inside the TLS state machine. KEM-layer combiners (CIRCL `xwing`, libcrux) live alongside the primitives. **Decision: ship both** — `std/crypto/hybrid.qz` (the TLS 1.3 raw-concat form) and `std/crypto/xwing.qz` (the SHA3-256-wrapped IETF X-Wing draft, for HPKE/standalone). Tiny code; lets NET.5's TLS layer just import the right one.
3. **Seed-as-key vs expanded-key.** FIPS 203 specifies the expanded `dk` form (2400 bytes); the MAL-BIND-K-CT attack (Schmieg/Cremers) showed expanded `dk` can be swapped to make two distinct `(dk, ek)` pairs decapsulate the same ciphertext to the same `K`. Mitigation: ship `dk` as the 64-byte seed `(d, z)` and re-derive expanded form on use. Filippo Valsorda's "Let's All Agree to Use Seeds as ML-KEM Keys" lays out the argument; Go's `crypto/mlkem` adopts it. **Decision: seed-as-key is canonical, expanded `dk` is a derivation, `H(ek)` is re-validated on every load of an expanded `dk`.**

## Architecture

### Module layout

Four new files:

- **`std/core/crypto/sha3.qz`** (~350 LoC) — Pure-Quartz SHA-3 family per FIPS 202.
  - Keccak-f[1600] permutation (24 rounds: θ, ρ, π, χ, ι)
  - SHA-3-256 (`sha3_256`), SHA-3-512 (`sha3_512`) — fixed-output absorb/squeeze
  - SHAKE128 (`shake128`), SHAKE256 (`shake256`) — variable-output XOF with streaming `_new`/`_absorb`/`_finalize`/`_squeeze`
  - Mirrors `sha512.qz` shape (malloc'd state, ptr-buffer I/O via `ffi/socket`)

- **`std/core/crypto/mlkem.qz`** (~1000 LoC) — Pure-Quartz ML-KEM-768 per FIPS 203.
  - Field arithmetic over Z/3329 (15-bit signed limbs in `i32`, Barrett reduction)
  - Polynomial arithmetic in R_q = Z_q[X]/(X²⁵⁶ + 1) (256-coeff polys, NTT-domain operations)
  - NTT / NTT⁻¹ with the precomputed `zeta[]` table (128 entries, ζ = 17)
  - Samplers: `SampleNTT` (rejection from SHAKE128), `SampleCBD_η` (centered binomial from SHAKE256)
  - Compress / Decompress / ByteEncode / ByteDecode for d ∈ {1, 4, 10, 12}
  - K-PKE: `KeyGen / Encrypt / Decrypt`
  - ML-KEM internal: `KeyGen_internal(d, z) / Encaps_internal(ek, m) / Decaps_internal(dk, c)` — derandomised form ACVP tests against
  - ML-KEM top-level: `KeyGen() / Encaps(ek) / Decaps(dk, c)` — randomised form using `rng_new_hw` from `std/crypto/rng.qz`
  - Seed-as-key form `mlkem_keygen_from_seed(d_seed, z_seed)` is the canonical entry point; `mlkem_expand_dk(seed)` materialises the FIPS 203 expanded `dk` on demand

- **`std/crypto/hybrid.qz`** (~80 LoC) — TLS 1.3 `X25519MLKEM768` raw-concat combiner per draft-ietf-tls-ecdhe-mlkem-04.
  - `hybrid_keygen(out_ek_1216: Int, out_dk_64: Int): Void` — seed-form dk (32B mlkem seed `d` ‖ 32B mlkem `z`); but NB the X25519 sk lives separately, see §"Hybrid wire format" below
  - `hybrid_encaps(out_ct_1120: Int, out_ss_64: Int, ek_1216: Int): Void`
  - `hybrid_decaps(out_ss_64: Int, ct_1120: Int, dk_64: Int): Int`
  - Note the reversed concat order from the framework default — see §"Hybrid wire format" below.

- **`std/crypto/xwing.qz`** (~100 LoC, optional v1) — IETF X-Wing draft (`draft-connolly-cfrg-xwing-kem`).
  - Same API shape as hybrid.qz but the shared-secret combiner is `SHA3-256("\.//^\\" ∥ ss_M ∥ ss_X ∥ ct_X ∥ pk_X)` instead of plain concat.
  - For HPKE-class protocols where there's no transcript hash to bind the X25519 share — needed because plain concat is non-committing in the absence of an outer transcript hash.
  - **Filed as NET.3c stretch.** If `std/crypto/hybrid.qz` ships within phase budget, xwing rolls into NET.3 too; otherwise it's a follow-up.

### SHA-3 internals

FIPS 202 §3.2 — Keccak-f[1600] over a 5×5×64-bit state (1600 bits = 200 bytes). 24 rounds; each round runs θ, ρ, π, χ, ι in sequence.

**State layout:** 200 bytes, addressed as 25 little-endian u64 lanes A[x,y] where (x, y) ∈ {0..4}². Lane index = `5·y + x`. We hold this as a single `malloc(200)` and read/write 8 bytes at a time via `_u64_read_le` / `_u64_write_le` (these helpers can be lifted from `sha512.qz` or re-emitted; same byte order, same shape).

**Round function** (one round, index `i_r`):
- **θ:** `C[x] = A[x,0] ⊕ A[x,1] ⊕ A[x,2] ⊕ A[x,3] ⊕ A[x,4]` for x in 0..5. `D[x] = C[x-1] ⊕ ROTL(C[x+1], 1)`. Then `A[x,y] ⊕= D[x]` for all (x,y).
- **ρ:** rotate each lane A[x,y] left by `r[x,y]` (the 25-entry rotation table — see §"FIPS 202 numerics" below).
- **π:** lane permutation `A'[y, (2x+3y) mod 5] = A[x, y]`. Implemented as a 25-element scratch buffer plus a copy.
- **χ:** `A[x,y] = A[x,y] ⊕ ((¬A[x+1,y]) ∧ A[x+2,y])` for all (x,y). Bitwise on whole lanes.
- **ι:** `A[0,0] ⊕= RC[i_r]` (the 24-entry round-constant table).

**Quartz-specific note** (mirrors curve25519/sha512): `ROTL(x, n)` for u64 needs the logical-shift workaround because Quartz `>>` is ashr. Define `_u64_rotl(x, n) = (x << n) | _u64_lsr(x, 64 - n)` where `_u64_lsr(x, n) = (x >> n) & ((1 << (64-n)) - 1)`.

**Sponge construction** (FIPS 202 §4):

Each variant has a (rate r, capacity c) pair (in bits) with r + c = 1600. **Absorb:** XOR `r` bits of input into the first `r` bits of state, then run Keccak-f. **Squeeze:** read first `r` bits of state, run Keccak-f, repeat until output length satisfied.

**Padding** (FIPS 202 Appendix B.2 — pad10*1 combined with domain separator):

After the message bytes are absorbed, one final partial block must be padded to fill `r` bytes:
1. XOR the **domain-separator byte** at the current offset (0x06 for SHA-3-NNN, 0x1F for SHAKE-NNN). This encodes the function-suffix bits + the leading `1` of pad10*1.
2. XOR `0x80` at the **last byte of the rate block** (offset r−1). This is the trailing `1` of pad10*1.
3. Compress (run Keccak-f).

If the domain byte and the trailing 0x80 land on the same byte (i.e., absorbed exactly to the last byte), the XORs combine: `0x06 ⊕ 0x80 = 0x86`, `0x1F ⊕ 0x80 = 0x9F`. The XOR semantics handle this naturally.

#### FIPS 202 numerics (verbatim from §3.2 and the keccak.team specs page)

**24 round constants RC[0..23]** for ι:

| i | RC[i] |
|---|---|
| 0 | `0x0000000000000001` |
| 1 | `0x0000000000008082` |
| 2 | `0x800000000000808A` |
| 3 | `0x8000000080008000` |
| 4 | `0x000000000000808B` |
| 5 | `0x0000000080000001` |
| 6 | `0x8000000080008081` |
| 7 | `0x8000000000008009` |
| 8 | `0x000000000000008A` |
| 9 | `0x0000000000000088` |
| 10 | `0x0000000080008009` |
| 11 | `0x000000008000000A` |
| 12 | `0x000000008000808B` |
| 13 | `0x800000000000008B` |
| 14 | `0x8000000000008089` |
| 15 | `0x8000000000008003` |
| 16 | `0x8000000000008002` |
| 17 | `0x8000000000000080` |
| 18 | `0x000000000000800A` |
| 19 | `0x800000008000000A` |
| 20 | `0x8000000080008081` |
| 21 | `0x8000000000008080` |
| 22 | `0x0000000080000001` |
| 23 | `0x8000000080008008` |

Stored as a lazily-initialised 192-byte LE table (24 × 8) mirroring `sha512.qz`'s `_k_table` pattern.

**ρ rotation offsets `r[x, y]` mod 64** (FIPS 202 §3.2.2 / Table 2):

| y \ x | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| 0 | 0 | 1 | 62 | 28 | 27 |
| 1 | 36 | 44 | 6 | 55 | 20 |
| 2 | 3 | 10 | 43 | 25 | 39 |
| 3 | 41 | 45 | 15 | 21 | 8 |
| 4 | 18 | 2 | 61 | 56 | 14 |

Lane (0,0) is not rotated (r=0). Stored as a 25-entry `Int` table or hard-coded into the ρ unroll.

**Rate / capacity** (FIPS 202 §6, all in bits/bytes):

| Function | rate r (bytes) | capacity c (bytes) | output (bytes) | domain byte |
|---|---|---|---|---|
| SHA3-256 | **136** | 64 | 32 | 0x06 |
| SHA3-512 | **72** | 128 | 64 | 0x06 |
| SHAKE128 | **168** | 32 | XOF | 0x1F |
| SHAKE256 | **136** | 64 | XOF | 0x1F |

### ML-KEM-768 internals

FIPS 203 §8 — Parameter set: `n = 256, q = 3329, k = 3, η₁ = 2, η₂ = 2, d_u = 10, d_v = 4`.

**Sizes** (FIPS 203 §8, Table 3):

| Object | Bytes | Formula |
|---|---|---|
| ek (encapsulation key) | **1184** | 384·k + 32 |
| dk (decapsulation key, expanded) | **2400** | 768·k + 96 |
| dk (seed form) | **64** | 32 (d) + 32 (z) |
| c (ciphertext) | **1088** | 32·(d_u·k + d_v) = 32·(30+4) |
| K (shared secret) | **32** | |

#### Z_q field arithmetic (q = 3329)

Each coefficient is held as a **signed `i32`** in range roughly [−q, q] (the Barrett-reduction natural range; canonical form [0, q−1] is enforced before serialization). Operations:

- `_zq_add(a, b) = a + b` (no reduction; defer to next mul or to a `_zq_reduce` call)
- `_zq_sub(a, b) = a - b`
- `_zq_mul(a, b)` — multiply then Barrett-reduce. For canonical inputs `a, b ∈ [0, q-1]`, compute `t = (a·b·v) >> 26; r = a·b - t·q; if r ≥ q: r -= q;`. **Constant is `v = floor(2²⁶ / q) = 20158`, not 20159.** (Kyber's pq-crystals reference + CIRCL + RustCrypto carry 20159 but pair it with ROUND-Barrett `t = (prod·v + (1<<25)) >> 26` plus a two-sided canonicalisation; we use FLOOR-Barrett with the true floor.) With v=20158, t ≤ floor(prod/q), so r ∈ [0, 2q) and a single conditional subtract canonicalises. The final conditional must be a **masked-select**, not a branch (CT discipline; see §"Constant-time discipline" below) — that rewrite is filed for 3b.3 ahead of the CT audit.
- `_zq_reduce(x)` — standalone modular reduction on a signed intermediate. v1 uses Quartz's `%` operator (C-style truncate-toward-zero) plus a single conditional add when `x < 0`. Called at sampler boundaries, not in the NTT inner loop.

**Quartz-specific gotcha** (preempted from `feedback_curve25519_ashr_carry_extraction.md`): Quartz `>>` on signed `Int` is **arithmetic shift right (ashr)**. Barrett's `(a·b·v) >> 26` step assumes the conventional behaviour for positive `a·b·v` (no sign extension). For ML-KEM, intermediates are bounded `|a·b·v| < 2³¹ · 20159 ≈ 2⁴⁵`, which fits in i64 — but we must verify the >>26 shift doesn't sign-extend into negative territory for any intermediate that goes negative. **Discipline**: keep i32 arithmetic explicit, range-document every intermediate, and any logical-shift use `(x >> n) & ((1 << (32-n)) - 1)` form mirroring SHA-2/curve25519.

#### Polynomial arithmetic in R_q = Z_q[X]/(X²⁵⁶ + 1)

A polynomial is a 256-element array of `i32` coefficients. Stored as `malloc(256 * 4) = 1024 bytes` per poly. Vectors over R_q (used for `t̂`, `ŝ`, `ê`, etc.) are k polys = 3 × 1024 = 3072 bytes.

**NTT** — Forward NTT (Cooley-Tukey decimation-in-time) — FIPS 203 Algorithm 9:

```
def NTT(poly f):
  k = 1   # zeta index
  for len = 128; len >= 2; len /= 2:
    for start = 0; start < 256; start += 2·len:
      zeta = zeta_table[k]; k += 1
      for j = start; j < start + len; j += 1:
        t = (zeta * f[j + len]) mod q
        f[j + len] = (f[j] - t) mod q
        f[j]       = (f[j] + t) mod q
```

**Inverse NTT** — Gentleman-Sande (Algorithm 10):

```
def NTT_inv(poly f):
  k = 127   # zeta index (descending)
  for len = 2; len <= 128; len *= 2:
    for start = 0; start < 256; start += 2·len:
      zeta = zeta_table[k]; k -= 1
      for j = start; j < start + len; j += 1:
        t = f[j]
        f[j]       = (t + f[j + len]) mod q
        f[j + len] = (zeta * (f[j + len] - t)) mod q
  for j in 0..256:  f[j] = (f[j] * 3303) mod q   # 3303 = 128^-1 mod q
```

**Zeta table** — `zeta_table[i] = 17^BitRev7(i) mod q` for i in 0..128. 128 entries × i32 = 512 bytes. Lazily initialised on first use (mirror `sha512.qz`'s `_ensure_k_table`).

**Base case multiply in NTT domain** — `NTT(f) ∘ NTT(g)` is a coefficient-pair multiply with the `γ` companion table where `γ[i] = ζ^(2·BitRev7(i)+1)`. Implementation: 128 calls to `BaseCaseMultiply` (Algorithm 11), each handling a 2-coefficient pair.

#### Samplers

**SampleNTT (Algorithm 7)** — rejection sampler from SHAKE128 stream. Reads 3 bytes at a time, produces two 12-bit candidates:
```
d1 = b0 | ((b1 & 0x0F) << 8)
d2 = (b1 >> 4) | (b2 << 4)
```
Accept each iff `d < q`. Continue until 256 coefficients accepted.

**SampleCBD_η (Algorithm 8)** — centered binomial. For ML-KEM-768, η = 2 everywhere, so input is 64·2 = 128 bytes from PRF. For each of 256 coefficients:
```
a = bit[4i] + bit[4i+1]
b = bit[4i+2] + bit[4i+3]
f[i] = (a − b) mod q    # in {-2, -1, 0, 1, 2}, reduced to canonical [0, q-1]
```

**Public-input rejection note**: SampleNTT runs on `(ρ, i, j)` — all public seeds. Timing leakage about iteration count reveals nothing secret. We **don't** make SampleNTT CT-in-iterations; we make it CT in the inner-byte operations (no shared state leaks). The CCTV "unlucky" vectors exercise ≥575 XOF-byte cases (prob ≈ 2⁻³⁸) — the loop must handle these correctly, not just within hardcoded buffer bounds.

#### Compress / Decompress (FIPS 203 §4.2.1, Eq. 4.7 & 4.8)

```
Compress_d(x)   = round((2^d / q) · x) mod 2^d
                = ((x << d) + (q >> 1)) / q   mod 2^d
Decompress_d(y) = round((q / 2^d) · y)
                = (q · y + (1 << (d-1))) >> d
```

Three concrete cases needed: `d = 1` (message bit ↔ coeff), `d = 4` (the v ciphertext component, dv=4), `d = 10` (the u ciphertext component, du=10), `d = 12` (the full poly serialization in ek/dk).

#### K-PKE algorithms (FIPS 203 §5.2)

**K-PKE.KeyGen(d_seed: 32B) → (ek_PKE: 1184B, dk_PKE: 1152B):**
1. `(ρ, σ) ← G(d_seed ∥ k_byte)` where G = SHA3-512 and `k_byte = 3` (the parameter rank). **NB: the trailing `∥ k_byte` is the IPD→final domain-separator change.** ρ is the 32-byte matrix-A seed, σ is the 32-byte secret-vector seed.
2. Build Â ∈ R_q^{3×3}: for i in 0..3, j in 0..3 — `Â[i,j] ← SampleNTT(SHAKE128(ρ ∥ j_byte ∥ i_byte))`.
3. Sample `s, e ∈ R_q^3 ← CBD_2(PRF(σ, N))` with N counter incrementing 0..6.
4. `ŝ ← NTT(s); ê ← NTT(e); t̂ ← Â ∘ ŝ + ê`.
5. `ek_PKE ← ByteEncode_12(t̂) ∥ ρ` (3 × 384 + 32 = 1184).
6. `dk_PKE ← ByteEncode_12(ŝ)` (3 × 384 = 1152).

**K-PKE.Encrypt(ek_PKE, m: 32B, r_seed: 32B) → c: 1088B:**
1. Parse `t̂, ρ` from ek_PKE.
2. Rebuild Â (transpose) — `Â[i,j] ← SampleNTT(SHAKE128(ρ ∥ i_byte ∥ j_byte))`.
3. Sample `y, e₁ ∈ R_q^3 ← CBD_2(PRF(r_seed, N))`, `e₂ ∈ R_q ← CBD_2(PRF(r_seed, N))`.
4. `ŷ ← NTT(y); u ← NTT⁻¹(Âᵀ ∘ ŷ) + e₁; v ← NTT⁻¹(t̂ᵀ ∘ ŷ) + e₂ + Decompress_1(m)`.
5. `c₁ ← ByteEncode_10(Compress_10(u))`, `c₂ ← ByteEncode_4(Compress_4(v))`.
6. `c ← c₁ ∥ c₂` (3 × 320 + 128 = 1088).

**K-PKE.Decrypt(dk_PKE, c) → m: 32B:**
1. `u' ← Decompress_10(ByteDecode_10(c[0..960]))`.
2. `v' ← Decompress_4(ByteDecode_4(c[960..1088]))`.
3. Parse `ŝ ← ByteDecode_12(dk_PKE)`.
4. `m ← ByteEncode_1(Compress_1(v' − NTT⁻¹(ŝᵀ ∘ NTT(u'))))`.

#### ML-KEM algorithms (FIPS 203 §6 + §7)

**ML-KEM.KeyGen_internal(d: 32B, z: 32B) → (ek: 1184B, dk: 2400B):**
1. `(ek_PKE, dk_PKE) ← K-PKE.KeyGen(d)`.
2. `dk ← dk_PKE ∥ ek_PKE ∥ H(ek_PKE) ∥ z` where H = SHA3-256 (1152 + 1184 + 32 + 32 = 2400).
3. `ek ← ek_PKE`.

**ML-KEM.Encaps_internal(ek, m: 32B) → (K: 32B, c: 1088B):**
1. `(K, r) ← G(m ∥ H(ek))` where G = SHA3-512 split into two 32B halves. **NB: the IPD also re-mixed `H(c)` into K via a KDF call; FIPS 203 final removed that step — K is now the high half of G directly.**
2. `c ← K-PKE.Encrypt(ek, m, r)`.

**ML-KEM.Decaps_internal(dk, c) → K: 32B:**
1. Parse `dk → (dk_PKE, ek_PKE, h, z)` with h = H(ek_PKE).
2. `m' ← K-PKE.Decrypt(dk_PKE, c)`.
3. `(K', r') ← G(m' ∥ h)`.
4. `K̄ ← J(z ∥ c)` where J = SHAKE256(·, 32 bytes).
5. `c' ← K-PKE.Encrypt(ek_PKE, m', r')`.
6. **Implicit rejection (CT branch):** `if c = c' (constant-time compare) return K', else return K̄`. Both branches return — no abort signal.

**Top-level randomised wrappers** (ML-KEM.KeyGen / Encaps — Algorithms 19/20/21) sample 32 random bytes from `rng_new_hw` (or accept user-provided RNG state) and call the `_internal` form. **ACVP tests against the `_internal` form** (it lets test vectors fix the random inputs); top-level is the user-facing API.

#### IPD → FIPS 203 final changes (load-bearing — verify each at coding time)

1. **G in KeyGen takes `d ∥ k_byte`** (parameter-set domain separation; prevents cross-set key confusion). The IPD/Kyber-r3 didn't have this byte.
2. **Encaps does not re-mix `H(c)` into K.** IPD had `K = KDF(K' ∥ H(c))`; final has `K = G(m ∥ H(ek)).high`.
3. **Implicit rejection key is `J(z ∥ c)`** (final). Alternatives discussed on pqc-forum (`J(c ∥ z)`, `J(z ∥ H(c))`) were not adopted.
4. **Matrix-A indexing matches Kyber v3.02** (`(j, i)` order in KeyGen, `(i, j)` order in Encrypt for transpose) — the IPD had swapped the order.
5. **Bit-strings → byte-strings throughout.** No bit-level operations exposed in the prose.
6. **Floating-point arithmetic explicitly forbidden** (FIPS 203 §3.3): all reductions must be integer. CT-mandate.
7. **Derandomised internal API** (Algorithms 16/17/18) added in final, exposed alongside the randomised top-level (Algorithms 19/20/21). ACVP tests the internal layer.

If a coding step produces output disagreeing with ACVP, this list is the first place to look.

### Hybrid wire format (TLS 1.3 X25519MLKEM768)

Per [draft-ietf-tls-ecdhe-mlkem-04](https://datatracker.ietf.org/doc/html/draft-ietf-tls-ecdhe-mlkem-04):

**Codepoint:** `X25519MLKEM768` = IANA TLS Supported Groups value **0x11EC** (4588).

**Concat order — the gotcha:** the framework rule (hybrid-design §3.2) is "shares concatenated in the order the algorithms appear in the NamedGroup name." `X25519MLKEM768` would put X25519 first by that rule, but **§4.1 of the ecdhe-mlkem draft explicitly reverses it** for historical reasons (to put the FIPS-certified ML-KEM piece at the front of the wire). Both client and server use the **reversed** order:

- **Client key_share (1216 bytes):** `mlkem768_ek (1184) ∥ x25519_pubkey (32)`
- **Server key_share (1120 bytes):** `mlkem768_ciphertext (1088) ∥ x25519_pubkey (32)`

**Shared-secret combiner (hybrid-design §3.3):** plain byte concatenation, ML-KEM first matching the share order:
```
K_combined = mlkem_shared_secret (32B) ∥ x25519_shared_secret (32B)    # 64 bytes
```
That 64-byte buffer is fed into the TLS 1.3 key schedule as the (EC)DHE IKM — `HKDF-Extract(salt, IKM=K_combined)`. No extra HKDF wrap, no length prefix, no dual-PRF, no explicit split-prevention construct in the combiner itself. Split-prevention argument: the TLS transcript hash already binds both halves into every derived key — a partial-knowledge attacker gains nothing.

**Non-TLS uses (HPKE-class)** lack a TLS-transcript binding, so plain concat is insufficient. The IETF X-Wing draft (`draft-connolly-cfrg-xwing-kem`) wraps the concat in a domain-separated SHA3-256 to provide standalone binding:
```
SS = SHA3-256("\.//^\\" ∥ ss_M ∥ ss_X ∥ ct_X ∥ pk_X)    # 32B output
```
The ASCII label `"\.//^\\"` (6 bytes) is the X-Wing domain separator. `ct_X` is the X25519 ephemeral public key acting as the "ciphertext" (X25519 is a one-shot DH viewed as a KEM); `pk_X` is the recipient's X25519 public key. **`std/crypto/xwing.qz`** ships this; **`std/crypto/hybrid.qz`** ships the TLS-form plain concat. They're different primitives with different security stories.

### API surface (final)

```quartz
# std/core/crypto/sha3.qz

# One-shot APIs (output buffer caller-owned)
def sha3_256(input: Int, input_len: Int, output_32: Int): Void
def sha3_512(input: Int, input_len: Int, output_64: Int): Void
def shake128(input: Int, input_len: Int, output: Int, output_len: Int): Void
def shake256(input: Int, input_len: Int, output: Int, output_len: Int): Void

# Streaming SHA-3 (fixed-output)
def sha3_256_new(): Int
def sha3_256_update(ctx: Int, input: Int, input_len: Int): Void
def sha3_256_finalize(ctx: Int, output_32: Int): Void

def sha3_512_new(): Int
def sha3_512_update(ctx: Int, input: Int, input_len: Int): Void
def sha3_512_finalize(ctx: Int, output_64: Int): Void

# Streaming SHAKE (XOF — absorb-then-squeeze with squeeze callable repeatedly)
def shake128_new(): Int
def shake128_absorb(ctx: Int, input: Int, input_len: Int): Void
def shake128_finalize_absorb(ctx: Int): Void   # transitions absorb → squeeze
def shake128_squeeze(ctx: Int, output: Int, output_len: Int): Void
def shake128_free(ctx: Int): Void

def shake256_new(): Int
def shake256_absorb(ctx: Int, input: Int, input_len: Int): Void
def shake256_finalize_absorb(ctx: Int): Void
def shake256_squeeze(ctx: Int, output: Int, output_len: Int): Void
def shake256_free(ctx: Int): Void
```

```quartz
# std/core/crypto/mlkem.qz

# Sizes (deliberately exposed as functions, mirror curve25519.qz)
def MLKEM768_EK_BYTES(): Int = 1184
def MLKEM768_DK_BYTES(): Int = 2400
def MLKEM768_DK_SEED_BYTES(): Int = 64       # 32B d + 32B z, canonical "Filippo-form"
def MLKEM768_CT_BYTES(): Int = 1088
def MLKEM768_SS_BYTES(): Int = 32

# Randomised top-level API
def mlkem768_keygen(out_ek: Int, out_dk: Int): Void
def mlkem768_encaps(out_ct: Int, out_ss: Int, ek: Int): Void
def mlkem768_decaps(out_ss: Int, ct: Int, dk: Int): Int     # always 1 (implicit reject)

# Seed-as-key form (canonical for forward compatibility w/ MAL-BIND-K-CT mitigations)
def mlkem768_keygen_from_seed(out_ek: Int, out_dk_seed_64: Int, d: Int, z: Int): Void
def mlkem768_expand_dk(out_dk_2400: Int, dk_seed_64: Int): Void  # re-derive expanded dk

# Internal derandomised API (ACVP-tested)
def mlkem768_keygen_internal(out_ek: Int, out_dk: Int, d: Int, z: Int): Void
def mlkem768_encaps_internal(out_ct: Int, out_ss: Int, ek: Int, m: Int): Void
def mlkem768_decaps_internal(out_ss: Int, ct: Int, dk: Int): Int
```

```quartz
# std/crypto/hybrid.qz (TLS 1.3 X25519MLKEM768)

def HYBRID_X25519MLKEM768_EK_BYTES(): Int = 1216           # 1184 + 32, ML-KEM first
def HYBRID_X25519MLKEM768_DK_SEED_BYTES(): Int = 96        # 64 (mlkem seed) + 32 (x25519 sk)
def HYBRID_X25519MLKEM768_CT_BYTES(): Int = 1120           # 1088 + 32
def HYBRID_X25519MLKEM768_SS_BYTES(): Int = 64             # mlkem_ss ∥ x25519_ss

def hybrid_x25519_mlkem768_keygen(out_ek_1216: Int, out_dk_seed_96: Int): Void
def hybrid_x25519_mlkem768_encaps(out_ct_1120: Int, out_ss_64: Int, ek_1216: Int): Void
def hybrid_x25519_mlkem768_decaps(out_ss_64: Int, ct_1120: Int, dk_seed_96: Int): Int
```

```quartz
# std/crypto/xwing.qz (IETF X-Wing draft, NET.3c stretch)

# Same shape as hybrid; output is 32B from the SHA3-256 wrap.
def XWING_EK_BYTES(): Int = 1216
def XWING_DK_SEED_BYTES(): Int = 96
def XWING_CT_BYTES(): Int = 1120
def XWING_SS_BYTES(): Int = 32

def xwing_keygen(out_ek: Int, out_dk_seed: Int): Void
def xwing_encaps(out_ct: Int, out_ss_32: Int, ek: Int): Void
def xwing_decaps(out_ss_32: Int, ct: Int, dk_seed: Int): Int
```

## Validation gates

**SHA-3** (`spec/qz/sha3_smoke.qz`, new):

FIPS 202 Appendix B / NIST CAVS vectors — at minimum the canonical entries from the NIST Examples doc:
- SHA3-256("") → `a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a`
- SHA3-256("abc") → `3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532`
- SHA3-512("") → `a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26`
- SHA3-512("abc") → `b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0`
- SHAKE128("", 32) → `7f9c2ba4e88f827d616045507605853ed73b8093f6efbc88eb1a6eacfa66ef26`
- SHAKE256("", 64) → `46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762fd75dc4ddd8c0f200cb05019d67b592f6fc821c49479ab48640292eacb3b7c4be`
- Streaming-vs-one-shot equivalence on a 1KB random message (via `rng_new_hw`).

**ML-KEM-768** (`spec/qz/mlkem_smoke.qz`, new):

Two tiers:
1. **Round-trip parity** (always runs): keygen → encaps → decaps; assert `ss_encaps == ss_decaps`. Repeat 100× via `rng_new_hw`. Plus malformed-ciphertext decaps tests (flip a bit in `c`; expect `K̄ = J(z ∥ c_tampered)` ≠ original `K`).
2. **ACVP KAT** (gated on vector files present): parse the JSON files from [`usnistgov/ACVP-Server`](https://github.com/usnistgov/ACVP-Server) at `gen-val/json-files/ML-KEM-keyGen-FIPS203/` and `ML-KEM-encapDecap-FIPS203/`. For each test in the `parameterSet: "ML-KEM-768"` group, run KeyGen_internal / Encaps_internal / Decaps_internal with the given `d, z, m` and compare against the expected `ek, dk, c, k`. Filed as `quake mlkem:acvp` task; vectors not vendored in-tree (large; pulled on demand to `tmp/acvp-mlkem/`).

ACVP-Server publishes ~25 tests per direction per parameter set in the released "json-files" set. For comprehensive coverage we also pull a slice of the [C2SP/CCTV ML-KEM](https://github.com/C2SP/CCTV/tree/main/ML-KEM) corpus:
- `modulus/` — invalid ek with one coefficient ≥ q (tests §7.2 modulus check)
- `unlucky/` — ciphertexts that force SampleNTT to consume >575 XOF bytes
- `strcmp/` — ciphertexts where naive `strcmp` would mis-compare (CT-discipline regression test)
- `accumulated/ML-KEM-768/10K` — deterministic 10k-vector run; expected output `f7db260e1137a742e05fe0db9525012812b004d29040a5b606aad3d134b548d3` (SHA3-256 digest)

The accumulated test is the strongest single sign-off: one number wrong anywhere in the pipeline produces a different SHA3-256.

**Hybrid X25519MLKEM768** (`spec/qz/hybrid_smoke.qz`):
- Round-trip parity (keygen → encaps → decaps, `ss == ss`).
- Cross-impl test vector: a known (mlkem768_sk, x25519_sk, ek, ct, ss) tuple from CIRCL's test suite or [draft-josefsson-mlkem-tls-test-vectors](https://datatracker.ietf.org/doc/draft-josefsson-mlkem-tls-test-vectors/) if/when published. Filed as a stretch; v1 ships round-trip only.

**Smoke tasks** — extend `Quakefile.qz` with:
- `quake sha3:smoke` — mirrors `ed25519:smoke` shape over `spec/qz/sha3_smoke.qz`
- `quake mlkem:smoke` — mirrors `ed25519:smoke` shape over `spec/qz/mlkem_smoke.qz`
- `quake mlkem:acvp` — additionally requires the ACVP JSON files present in `tmp/acvp-mlkem/`; pulls them on first run from GitHub

**Fixpoint + bootstrap** — final ship requires `./self-hosted/bin/quake guard` clean (gen1 == gen2 byte-identical; ~2542 fns expected) and Rule 2 smoke against `style_demo.qz` + `brainfuck.qz`. NET.3 touches stdlib only; no compiler-source change is anticipated. (Caveat: ML-KEM may need a small intrinsic if we hit a gap — e.g. if Quartz lacks an efficient bit-reversal or specific i32 SIMD-style op. None expected per the BLAKE2s / SHA-512 / curve25519 precedent.)

## Constant-time discipline

Following FIPS 203 §3.3 ("Floating-point arithmetic forbidden") and the broader PQC CT discipline:

- **CT required** (private inputs):
  - All ML-KEM internal ops on `dk_PKE / ŝ / m / r` (decaps + the entire signing path equivalent in encaps)
  - The implicit-rejection compare `c == c'` (use `subtle::ct_eq_bytes` — already shipped in NET.1)
  - Z_q field arithmetic (Barrett reduction's final conditional subtract — masked-select, never `if`)
  - Polynomial sub/add (no conditional moves)
  - The implicit-rejection final select between `K'` and `K̄` (use `subtle::ct_select_bytes_32`)
- **VT acceptable** (public inputs):
  - SampleNTT iteration count (input is public seed `(ρ, i, j)`)
  - Compress/Decompress division (`c` and `ek` are public; the operand is also a public-domain coefficient — but we still keep these CT in the inner ops since they share code paths with the v/u-secret path of decaps)
  - ek/c byte parsing (no secret-dependent control flow needed)
- **NOT shipped in NET.3** (filed as NET.4):
  - `Secret<T>` annotations on the private-key surface (NET.4)
  - `dudect_check` empirical CT verification (NET.4)
  - The CT compiler pass that flags secret-dependent branches (NET.4)

Today: by-inspection CT — we hand-audit the hot paths and follow the same discipline as `subtle.qz` / `chacha20.qz` / `curve25519.qz`. The Quartz codebase's existing CT helpers (`ct_select_*`, `ct_eq_*`) cover the surface.

**Barrett reduction CT note** (preempt the canonical bug): the final `if r ≥ q: r -= q` must be a masked-select:
```
mask = -((r - q) >> 31)   # all-ones if r < q (signed shift, r-q negative); 0 if r ≥ q
r = r - (q & ~mask)        # subtract q iff mask is 0
```
Or equivalently, use `subtle::ct_select_i32(r - q, r, r >= q)`. The naked `if` form is the lowest-hanging CT bug in the literature; we don't ship that even as an intermediate.

## Non-goals (NET.3 v1)

- **ML-KEM-512 / ML-KEM-1024 parameter sets.** v1 ships **only ML-KEM-768** (k=3) — the production target. Adding the other two parameter sets is mechanical (different k, η, d_u, d_v constants); filed as a NET.3 follow-up. ML-KEM-768 alone matches Cloudflare's deployment, Apple PQ3, Signal PQXDH, and the only TLS-1.3 codepoint currently assigned for hybrid (X25519MLKEM768).
- **Montgomery-domain NTT.** v1 ships plain mod q + Barrett. Montgomery is ~10–15% faster on the mul step but adds an invariant-tracking burden. Filed as a NET.3 perf follow-up.
- **AVX2 / NEON SIMD NTT.** Pure scalar in v1. The SIMD path is where libcrux / BoringSSL extract their real performance; we don't have SIMD intrinsics shipped for Quartz yet. Filed as a Phase E follow-up.
- **X-Wing hybrid** — `std/crypto/xwing.qz` is a stretch in v1; if `hybrid.qz` ships within phase budget xwing rolls in too, otherwise it's NET.3c follow-up.
- **WireGuard PQ extension** — adding a hybrid ML-KEM lane to `std/crypto/noise.qz` (IKpsk2 variant per the Tunnelcrypt / WG-PQ drafts). No IETF consensus yet; defer until either eli's hyperbouba dogfood pulls a Noise-PQ pattern or we have a concrete deployment story.
- **Secret<T> + dudect harness** — NET.4.
- **The full FIPS 203 ML-KEM API including the randomised `KeyGen()` no-arg form integrated with `Secret<T>` taint propagation** — needs NET.4.

## Sizing

| Phase | Effort (quartz-day) | Outputs |
|---|---|---|
| 3.0 (design) | 0.2 | This memo — done. |
| 3a (SHA-3 family) | 0.5 | `std/core/crypto/sha3.qz` (~350 LoC); `spec/qz/sha3_smoke.qz` with 8+ vectors; `quake sha3:smoke` task. |
| 3b.1 (ML-KEM field + NTT + samplers) | 0.5 | Z_q arithmetic + polynomial NTT/INTT + zeta table + SampleNTT/SampleCBD. Internal correctness via a "round-trip NTT" sanity check. |
| 3b.2 (K-PKE encrypt/decrypt) | 0.4 | Compress/Decompress/Encode/Decode + K-PKE.KeyGen/Encrypt/Decrypt + a K-PKE-only round-trip test. |
| 3b.3 (ML-KEM internal + top-level + 100-round-trip) | 0.4 | `_internal` + randomised wrappers + 100× round-trip + tamper rejection. |
| 3b.4 (ACVP KAT runner) | 0.5 | ACVP JSON parser via existing `std/json.qz`, KAT runner, `quake mlkem:acvp` task. **First-vector-passes is the gate.** |
| 3b.5 (CCTV negative tests) | 0.2 | modulus/unlucky/strcmp from C2SP/CCTV; accumulated 10K hash check. |
| 3c (Hybrid X25519MLKEM768 + smoke) | 0.3 | `std/crypto/hybrid.qz` + `spec/qz/hybrid_smoke.qz` round-trip; reuses `curve25519` + `mlkem`. |
| 3c.opt (X-Wing) | 0.3 | `std/crypto/xwing.qz` + smoke. Stretch — runs only if 3a–3c finished within budget. |
| 3.z (smoke + guard + ROADMAP close-out) | 0.2 | `quake guard` clean; style_demo + brainfuck smoke; ROADMAP NET.3 row → ✅; project memory close-out memo. |

**Total v1 (excluding xwing stretch): ~3.2 quartz-days.** ROADMAP row estimates 1–2 quartz-weeks; this is right-sized within that envelope.

**Calibration:** NET.2 estimate 3–5 quartz-days, actual ~0.5. NET.3 has more code (~1500 LoC vs ~1000) and one entirely new family (SHA-3 vs SHA-2-on-existing-substrate), so ~3× the NET.2 effort, which puts us ~1–1.5 quartz-weeks. Sub-day per phase is the calibration shape we should see; if any phase hits 2+ days, that's a signal to pause and audit.

## Open questions

**Q1: Vendor the ACVP JSON files in-tree or pull on demand?**

The ACVP vector files are ~10–50 MB compressed; pulling on demand keeps the repo lean and dodges a "vendored binary blob" git history sprawl. **Decision: pull on demand** — the `quake mlkem:acvp` task `curl`s the files from `usnistgov/ACVP-Server` master into `tmp/acvp-mlkem/` on first run, caches there, gated by a small SHA-256 manifest in-tree (`spec/acvp-mlkem-manifest.txt`) to detect upstream changes. The C2SP/CCTV vectors are smaller (~1 MB); those we vendor directly under `spec/cctv-mlkem/`.

**Q2: Expanded `dk` (2400 B) vs seed `dk` (64 B) as the canonical API surface?**

Per the prior-art table, mainstream impls (CIRCL, BoringSSL, liboqs) ship expanded `dk`; Go's `crypto/mlkem` ships seed-form; libcrux supports both. The MAL-BIND-K-CT attack class makes expanded-form vulnerable in a narrow but real class of protocols (those using `K` as a commitment). **Decision: seed-form is canonical, expanded is a derivation.** `mlkem768_keygen` and `mlkem768_keygen_from_seed` both expose the seed-form in their out-buffers; `mlkem768_expand_dk` re-derives the expanded form on demand. Decaps internally re-expands from the seed (one-time cost — ~100µs) — if a future profiling pass shows decaps latency matters, we add an expanded-dk-decaps fast-path that re-validates `H(ek)` on every call (preserving the binding property).

**Q3: Cofactored vs cofactorless / `KeyCheck` validation modes?**

ML-KEM doesn't have a cofactor question (it's not an elliptic curve), but FIPS 203 §7.2 / §7.3 specifies input-validation modes — "modulus check" on ek (every coefficient < q) and "hash check" on dk (the H(ek) field matches the recomputed hash). ACVP tests these via the `encapsulationKeyCheck` and `decapsulationKeyCheck` functions. **Decision: ship validation as default-on** — `mlkem768_encaps` rejects ek that fails the modulus check (`return 0` from the function, with the caller's `out_ct` left untouched). `mlkem768_decaps` rejects dk that fails the H(ek) check. Filed as the close-gate behaviour for the `quake mlkem:acvp` `*Check` group runs.

**Q4: What happens when `rng_new_hw` is not available (e.g., the unikernel pre-RDRAND state)?**

NET.1 ships `std/crypto/rng.qz` with a fallback path. For NET.3, the seed-as-key form makes this an explicit caller concern — callers supply `d` and `z` from wherever they trust. The randomised `mlkem768_keygen` uses `rng_new_hw` and inherits whatever guarantees NET.1's rng provides. **No new question here; documented for completeness.**

## Hand-off invariants for future sessions

- This memo is the source of truth until MLKEM_DESIGN ships its close-out section. Updates land in this file.
- The `_f51_*` substrate in `curve25519.qz` is API-stable. The `sha512.qz` / `ed25519.qz` files are API-stable. Do not modify any during NET.3 — additions are fine; in-place changes risk regressing the NET.1+NET.2 KAT corpus.
- All four ACVP KAT directions (KeyGen, Encaps, Decaps, KeyCheck) must pass in the same commit that lands `mlkem768_*`. Partial KATs = partial ship = filed-not-shipped. **The C2SP/CCTV accumulated 10K hash is the strongest single sign-off; that's the close-gate.**
- `quake guard` clean + style_demo/brainfuck smoke is the per-phase close gate. Same as every NET.1/NET.2 phase.
- **Quartz-specific i32-vs-Int discipline**: ML-KEM intermediates are bounded `|x| < 2³¹` but Quartz's `Int` is i64 throughout. Range-document every intermediate in code comments. The Barrett `>> 26` shift's behaviour on non-negative inputs is fine (Quartz `>>` is ashr but ashr matches lsr for non-negatives); negative intermediates need the `(x >> n) & MASK` workaround. **All places where the workaround is needed must be marked with a comment citing `feedback_curve25519_ashr_carry_extraction.md`.**

## References

- [FIPS 203 — Module-Lattice-Based Key-Encapsulation Mechanism Standard](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.203.pdf) (Aug 2024 final)
- [FIPS 202 — SHA-3 Standard](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.202.pdf)
- [draft-ietf-tls-ecdhe-mlkem-04](https://datatracker.ietf.org/doc/html/draft-ietf-tls-ecdhe-mlkem-04) — X25519MLKEM768 codepoint + reversed concat
- [draft-ietf-tls-hybrid-design-16](https://datatracker.ietf.org/doc/html/draft-ietf-tls-hybrid-design-16) — generic hybrid framework
- [draft-connolly-cfrg-xwing-kem](https://datatracker.ietf.org/doc/draft-connolly-cfrg-xwing-kem/) — X-Wing hash-wrapped combiner
- [Filippo Valsorda — "Let's All Agree to Use Seeds as ML-KEM Keys"](https://words.filippo.io/ml-kem-seeds/) — seed-as-key rationale
- [Cloudflare CIRCL `kem/mlkem`](https://github.com/cloudflare/circl/tree/main/kem/mlkem) — Montgomery-domain Go reference
- [RustCrypto `ml-kem`](https://github.com/RustCrypto/KEMs/tree/master/ml-kem) — plain-mod-q Rust reference (closest baseline to our design)
- [`cryspen/libcrux-ml-kem`](https://github.com/cryspen/libcrux/tree/main/libcrux-ml-kem) — F*-verified reference; mirrors our auditability priority
- [`usnistgov/ACVP-Server` ML-KEM-FIPS203 vectors](https://github.com/usnistgov/ACVP-Server/tree/master/gen-val/json-files/ML-KEM-keyGen-FIPS203) — the KAT corpus
- [`C2SP/CCTV ML-KEM`](https://github.com/C2SP/CCTV/tree/main/ML-KEM) — speccheck-equivalent edge cases (modulus, unlucky, strcmp, accumulated)
- [Keccak specs summary](https://keccak.team/keccak_specs_summary.html) — the load-bearing constants table
- [Schmieg / Cremers et al. "Keeping up with the KEMs"](https://groups.google.com/a/list.nist.gov/g/pqc-forum/c/8cNYhg23B9k) — MAL-BIND-K-CT attack class
