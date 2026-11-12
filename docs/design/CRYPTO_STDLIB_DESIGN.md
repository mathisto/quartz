# Crypto Stdlib Design

**Status**: Design — pre-implementation. Forcing function is EPIC NET.1 (WireGuard-on-Unikernel), but the deliverable is language-wide.
**Scope**: Land a credible `std/core/crypto/*` + `std/crypto/*` stack, plus the compiler features that crypto code legitimately needs (wide multiply, secure zeroing, `subtle` helpers). Roadmap the stretch features (`Secret<T>`, `dudect_check`, full `@[constant_time]`).
**Companion**: [`WIREGUARD_UNIKERNEL_DESIGN.md`](WIREGUARD_UNIKERNEL_DESIGN.md) — the consumer that proves it works.

## Why this is language work, not unikernel work

The unikernel is the consumer. The deliverables are stdlib + compiler:

| Deliverable | Tier | Beneficiary |
|---|---|---|
| `@widening_mul` compiler intrinsic | Compiler | Bignum, hash tables, PRNGs, anywhere `u64 × u64 → u128` matters |
| `std/core/crypto/{chacha20,poly1305,blake2s,curve25519,hkdf}` | Stdlib (no allocator) | Every Quartz program |
| `std/core/crypto/{subtle,zeroize}` | Stdlib (no allocator) | Every Quartz program |
| `std/crypto/{noise,rng}` | Stdlib (allocator) | Every Quartz program |
| `std/net/wireguard/*` | Stdlib (allocator) | HTTP servers, CLIs, mobile-style clients, the unikernel |
| `Secret<T>` newtype + tracking (roadmap) | Type system | Future crypto + sensitive-data code |
| `dudect_check` testing helper (roadmap) | Stdlib (testing) | Crypto authors validating constant-time discipline |

Unikernel-specific work is glue (UDP, tun-equivalent, entropy source). ~85/15 split language-to-glue.

## The current state

**Present:**
- LLVM-IR backend with full SIMD intrinsics (`std/simd`, used by `simd_dot_product.qz`)
- FFI to vendored C: working pattern in `std/ffi/socket`, `tools/baremetal/libc_stubs.c`
- Three-tier stdlib scaffolding committed (KERNEL_EPIC SYS.2)
- `volatile_load<T>` / `volatile_store<T>` lowering to LLVM `load volatile` / `store volatile` — load-bearing for `zeroize` (the volatile IR primitive carries the no-DCE guarantee on its own; LLVM cannot eliminate volatile stores before or after inlining)
- Freestanding-target lowering already drops most libc deps
- `extern "C"` def + parser support for vendored C symbols

**Compiler attributes:**
- ✅ `@noinline` — shipped 2026-05-08 alongside `@naked`/`@weak`/`@export`. Bit 262144 in `effect_annotations`; emitted as the inline LLVM `noinline` function-attribute keyword on the `define` directive. Applied to `zeroize` as belt-and-suspenders (volatile IR carries the no-DCE guarantee on its own, but matching the Rust/BoringSSL pattern of pinning the guarantee at both layers is cheap).
- `@section(name)` — for placing crypto state in a named ELF section (not Phase 1 work; relevant when we want side-channel-resistant memory placement).

**Absent:**
- `u64 × u64 → u128` wide multiply. Quartz has no `u128`; codegen has no `__builtin_mul_overflow`-equivalent; hand-rolled software Karatsuba is the alternative for Curve25519's 5×51-bit field arithmetic and is 4-8× slower than hardware MUL+UMULH.
- Constant-time discipline at any level (no `subtle`-helpers stdlib, no type-system tracking, no codegen guarantees)
- Secure zeroing (`mem_zero` is regular memset; LLVM optimizer can DCE it across function boundaries)
- Cryptographic RNG abstraction (`getrandom(2)` shim only; no DRBG; no entropy-pool for the unikernel)
- Any vendored crypto C source in tree

**Won't have without language work:**
- Crypto code that actually delivers the constant-time property end-to-end. (See "Constant-time" below — this is the hardest piece, deliberately bounded.)

## Prior art

| Language / project | Approach | What we take |
|---|---|---|
| **Go** `crypto/...` + `golang.org/x/crypto` | Pure-Go, audited, constant-time discipline; `crypto/subtle` for ct-helpers | The `subtle` API shape — `ConstantTimeByteEq`, `ConstantTimeSelect`, `ConstantTimeLess`. Adopt verbatim. |
| **Rust** stdlib + RustCrypto + dalek + ring | Stdlib is empty; ecosystem fragmented; `dalek-cryptography/curve25519-dalek` is the dominant Curve25519 impl | The `dalek` field-element representation (5×51-bit limbs over `u64`) is the right model. The "stdlib has no crypto" call is **rejected** for Quartz — fragmenting crypto across community libs is exactly the trap a small language can't survive. |
| **Zig** `std.crypto` | Pure Zig, audited, constant-time, no FFI, no deps | The single-language stdlib stance. Closest peer to what Quartz should ship. We adopt the *destination* but bootstrap differently. |
| **Swift** `CryptoKit` / `Swift Crypto` | Wraps BoringSSL on Linux/Windows, CryptoKit (closed) on Apple | Swift's pragmatism — wrap audited C until the native impl is mature. Validates the (c) hybrid path below. |
| **OCaml** `mirage-crypto` (used by MirageOS) | Pure-OCaml; primary unikernel crypto stack; closest precedent for what NET.1 builds | Read their experience report. They had to rewrite Curve25519 three times for performance + constant-time. Plan for that. |
| **HACL\*** (Project Everest, F\* → C) | Formally verified primitives, extracted to plain C, freestanding-friendly | **Phase 1 vendor.** Used by Linux kernel WireGuard, Mozilla NSS, mainline crypto. Extracted C is the artifact we vendor; F\* source is not in our build pipeline. |
| **fiat-crypto** (Coq → C) | Formally verified field arithmetic | Reference for Phase 2 Curve25519 reimplementation. Their generated C for the 64-bit Curve25519 field is the model. |
| **Wycheproof** (Google) | Cross-language crypto test vectors | Mandatory test corpus. Every primitive checked against Wycheproof before declaring shipped. |
| **Jasmin** / **FaCT** / **Vale** (research) | Crypto-DSL with end-to-end constant-time guarantees | Reference for the "what would a serious `@[constant_time]` look like" question. Not Phase 1, not Phase 2. |
| **dudect** (Reparaz, Balasch, Verbauwhede 2017) | Statistical timing-leak detector (no source instrumentation needed) | Phase 2+ testing helper. The pragmatic stand-in for full static constant-time analysis. |

## Decision tree (commit to docs)

When adding a new crypto primitive or sensitive-data helper, ask in order:

1. **Is there a HACL\* primitive that covers it?** → Phase 1 vendor. Write `std/core/crypto/<name>.qz` as a thin FFI shim. Must include Wycheproof tests + a `pure-quartz-todo.md` note explaining what would be needed for a Phase 2 native impl.

2. **Is the operation field arithmetic over a prime?** → Use `@widening_mul` + the `subtle` helpers; model field-element layout after `dalek`'s 5×51-bit limbs (Curve25519) or fiat-crypto's verified output.

3. **Is the data secret?** → Hold it in a buffer that gets `zeroize`'d on drop. (When `Secret<T>` lands, additionally type-tag it.)

4. **Does the function compare secret values?** → Route through `subtle.ct_eq` / `ct_select` / `ct_less`. Never use `==`, `if`, or array-index-by-secret. Add a `dudect_check` test when that helper lands.

5. **Is the operation algorithm-agility (e.g., "AEAD" generic)?** → Live in `std/crypto/`, not `std/core/crypto/`. Compose pinned primitives by name — no runtime dispatch over algorithm IDs (closes a major class of crypto-misuse footguns; matches Noise's "no negotiation" stance).

## Stdlib shape

```
std/core/crypto/                # No allocator. Pure functions on caller-owned buffers.
  chacha20.qz                   # ChaCha20 stream cipher (RFC 8439)
  poly1305.qz                   # Poly1305 MAC (RFC 8439)
  chacha20poly1305.qz           # AEAD construction (RFC 8439)
  blake2s.qz                    # BLAKE2s hash (RFC 7693)
  curve25519.qz                 # X25519 scalar multiplication (RFC 7748)
  hkdf.qz                       # HKDF-BLAKE2s (RFC 5869)
  subtle.qz                     # ct_eq, ct_select, ct_less, ct_copy_if
  zeroize.qz                    # secure-zero (volatile-store + noinline)

std/crypto/                     # May allocate. Higher-level constructions.
  noise.qz                      # Noise Protocol Framework — IKpsk2 only to start
  rng.qz                        # Entropy source + DRBG (HKDF-based, seeded from getrandom)

std/core/crypto/testing/        # Phase 2+
  wycheproof.qz                 # Vector loader + assert helpers
  dudect.qz                     # Statistical timing-leak check

std/net/wireguard/              # The protocol, on top of UDP and the above.
  peer.qz                       # PeerKey, PSK, endpoint, allowed-IPs
  session.qz                    # Active session keys + counters
  handshake.qz                  # Noise IKpsk2 handshake driver
  transport.qz                  # Encrypt/decrypt data packets
  timers.qz                     # Rekey, keepalive, REJECT_AFTER_TIME state machines
  device.qz                     # Top-level peer table + tun glue
```

Tier placement rule: anything that doesn't allocate goes in `std/core/`. Crypto primitives operate on caller-owned buffers and are allocator-free; protocol code (Noise, WG) needs key tables and goes in `std/`.

Naming: `chacha20poly1305` (one identifier, no hyphen, no underscore) matches RFC text and the HACL\* C symbols. Module names follow.

## Implementation source — the (c) hybrid path

**Phase 1 (HACL\* bootstrap):**
- Vendor HACL\* generated C into `vendor/hacl-c/`. Specifically: `Hacl_Chacha20Poly1305_32`, `Hacl_Hash_Blake2s_32`, `Hacl_Curve25519_64`, `Hacl_HKDF_Blake2s_32`. (Choose `_32` over vector-128 for portability; Phase 2's pure-Quartz impl can add SIMD later.) Curve25519 picks `_64` (uses `__int128`, freestanding-clean on LLVM) for 4-8× speedup over `_51`.
- Write `std/core/crypto/<name>.qz` as `extern "C" def hacl_*` declarations + thin idiomatic Quartz wrappers.
- Quake adds a `vendor:hacl-rebuild` task (rare — only when bumping HACL\* version) and a `vendor:hacl-verify` task that diffs the vendored C against an upstream-tagged blob.
- License: HACL\* is Apache-2.0 / MIT-dual. Verify Quartz license compatibility before vendoring (TODO before Phase 1 starts).

**Phase 2 (pure Quartz, primitive-by-primitive):**
Each primitive is its own milestone. Order, easiest → hardest:
1. **BLAKE2s** — pure SIMD-friendly ARX, ~300 LoC, no field arithmetic. First because it's the warm-up.
2. **ChaCha20** — same shape as BLAKE2s; SIMD lanes dogfood `std/simd`. ~250 LoC.
3. **Poly1305** — modular reduction over `2^130 - 5`. Needs `@widening_mul`. ~200 LoC.
4. **ChaCha20Poly1305** — composition of (2) and (3); RFC 8439 §2.8 encode-and-MAC ordering. ~50 LoC.
5. **HKDF-BLAKE2s** — HMAC-BLAKE2s + extract/expand. ~150 LoC.
6. **Curve25519** — 5×51-bit field arithmetic, scalar mult ladder, `subtle`-driven bit selection. ~600 LoC. Hardest. Last.

Each replacement gates on:
- Wycheproof vectors green
- WireGuard interop tests green (cross-implementation: `wg-quick`, `boringtun`)
- `dudect_check` green (when that helper lands — until then, manual code review against `dalek`'s patterns)
- Performance within 4× of the HACL\* baseline (not parity — pragmatism)

Phase 2 happens over multiple sessions, on the language-maturation timescale. No deadline pressure; a primitive replacement either lands clean or stays HACL\* until next session. The hybrid is the deliberate steady state during Phase 2.

**Why not pure Quartz from day one:** the unikernel demo needs working WG in 2-3 quartz-weeks, not 6-10. Phase 2's value is the language-maturation arc, which is uncoupled from getting WG live.

**Why not permanent FFI:** the pitch "the unikernel runs WG written entirely in Quartz" is the actual demo. Permanent FFI to HACL\* dilutes that to "the unikernel runs WG written in Quartz wrapping someone else's correct crypto." Phase 2 closes that gap.

## Constant-time discipline

**Initial stance: `subtle` helpers only.** Shipped `std/core/crypto/subtle.qz` 2026-05-08:

```be
ct_eq_byte(a, b)              -> 0xFF if low bytes equal, 0 otherwise
ct_eq_u32(a, b)               -> 0xFFFFFFFF if low 32 equal, 0 otherwise
ct_eq_int(a, b)               -> -1 (all 64 ones) if equal, 0 otherwise
ct_select_byte(mask, a, b)    -> a if mask is 0xFF, b if 0
ct_select_u32(mask, a, b)     -> a if mask is 0xFFFFFFFF, b if 0
ct_select_int(mask, a, b)     -> a if mask is -1, b if 0
ct_less_u32(a, b)             -> 0xFFFFFFFF if a < b unsigned 32-bit, else 0
ct_eq_bytes(a_ptr, b_ptr, len) -> 1 if buffers equal, 0 otherwise (constant-time over len)
ct_copy_if_byte(mask, dst, src, len) -> branchless conditional copy
```

Signatures take `Int` rather than typed `U8`/`U32` because Quartz's runtime integer is uniformly `Int`; width semantics are documented per-helper. Result-as-mask form (rather than 0/1) so callers can compose multiple comparisons with `&` / `|`. Correctness is on the human author + reviewer. Matches Rust / Go's stance. Closes 90% of practical timing-leak risks if used disciplined.

**What we deliberately defer:**

- **`Secret<T>` newtype + type-system tracking** (roadmap, post-NET.1). Wraps a value of type `T` and "infects" through expressions that touch it. Compiler rejects `if secret_val { ... }`, `arr[secret_idx]`, comparison operators on `Secret<T>`. Forces use of `subtle` helpers. Real type-system work; pays back across the future crypto stdlib (and beyond — credentials, session tokens, anything sensitive). Estimate: ~1 quartz-week for the type-system part, ~2-3 quartz-days for migrating Phase 2 code to use it. Slot when convenient.

- **`dudect_check` testing helper** (roadmap, slot with `Secret<T>` or earlier). Statistical timing-leak detector based on Reparaz/Balasch/Verbauwhede 2017. Calls a function with two distinct secret inputs N times each, runs Welch's t-test on the timing distributions, asserts no leak detectable above threshold. Doesn't *prove* constant-time — *measures* it. This is what production crypto actually relies on (BoringSSL, OpenSSL, dalek all use timing tests, not static proofs). Estimate: ~2-3 quartz-days for the testing helper.

- **Full `@[constant_time]` function attribute** (deferred indefinitely). Static rejection of branches/indexing on tainted values inside marked functions. **Why deferred:** the static analysis is tractable (taint-track Secret-flowing values through MIR, reject branches/indexing/variable-time ops, ~1-2 quartz-weeks). The hard part is that **LLVM doesn't preserve constant-time semantics through optimization.** An `-O3` pass can lower a conditional-move into a branch on hot-cold heuristic; can fold constant-time selects into something that isn't. Jasmin sidesteps this by being its own backend. Without backend control or post-codegen verification, `@[constant_time]` is a half-truth: "rejects bad source patterns, but the optimizer can introduce timing leaks anyway." Worth shipping only if (a) we add a Quartz-controlled lowering pass that bypasses the LLVM optimizer for marked functions, or (b) we adopt a "compile crypto with `-O0` + verify with `dudect_check`" discipline that makes the half-truth honest. Revisit when one of those is on the table.

The practical 2026 stance is: `subtle` helpers + `Secret<T>` + `dudect_check` is what serious modern crypto stdlibs ship. `@[constant_time]` is research.

## Wide-multiply intrinsic

**Ship six intrinsics during Phase 1**, split because Quartz's existing intrinsic surface returns a single `i64` per call (no tuple-return shape — see decision log 2026-05-08):

```be
# All six implicitly take/return Int (Quartz's only integer width).
# Semantics are unsigned wraparound u64; users supply 0/1 for carry/borrow.
# Called bare (no @ sigil), like other intrinsics: e.g. `widening_mul_lo(a, b)`.
widening_mul_lo(a, b)         -> Int       # low  64 bits of u64 × u64
widening_mul_hi(a, b)         -> Int       # high 64 bits of u64 × u64
carrying_add_sum(a, b, c)     -> Int       # (a + b + c) mod 2^64
carrying_add_carry(a, b, c)   -> Int       # 0 or 1 — overflow flag of (a + b + c)
borrowing_sub_diff(a, b, c)   -> Int       # (a − b − c) mod 2^64
borrowing_sub_borrow(a, b, c) -> Int       # 0 or 1 — borrow flag of (a − b − c)
```

Codegen lowering:
- `widening_mul_{lo,hi}`: zero-extend both operands to `i128`, `mul i128`, then `trunc` (for `_lo`) or `lshr 64 + trunc` (for `_hi`). LLVM `X86ISelLowering` peepholes both halves of one operand-pair into a single `mulq` (low+high in `RAX:RDX`); aarch64 to `mul + umulh`. No software fallback needed — every target Quartz cares about has hardware widening multiply.
- `carrying_add_*` / `borrowing_sub_*`: chained `@llvm.uadd.with.overflow.i64` / `@llvm.usub.with.overflow.i64` (two-step: `(a, b)` then `(sum, c)`); flag is `or` of the two intermediate carry bits, zext to i64. Maps to `adcq` / `sbbq` chain on x86, `adcs` / `sbcs` on aarch64.

When user code calls both halves of the same operand triple in a basic block (the typical bignum-limb pattern), LLVM CSE folds the redundant chain. The split-API surface produces the same final asm as a tuple-API surface would.

A future "tuple-returning intrinsics" feature in MIR (~1-2 quartz-days, separate work item) could collapse the API to `@widening_mul`, `@carrying_add`, `@borrowing_sub` returning `(Int, Int)` if the call-site verbosity becomes a real ergonomic problem. Phase 2's pure-Quartz primitives are the consumers that will tell us whether it's worth doing.

**Beneficiaries beyond crypto:**
- Bignum arbitrary-precision arithmetic (`std/bigint`, future)
- Hash table double-hashing / fastrange (`std/map.qz` could shave a `%` per lookup)
- PRNG / hash function design (xoshiro, wyhash, ahash)
- Decimal-printing fast paths (Grisu, Ryu — a `Float → String` upgrade)

**Files to touch (3 sites, fold into `cg_intrinsic_math.qz`):**
- `self-hosted/middle/typecheck_builtins.qz` — register six intrinsic return types
- `self-hosted/backend/intrinsic_registry.qz` — register six names under `INTRINSIC_CAT_MATH` (single source of truth: this is mir + codegen recognition since the registry refactor; no separate `mir.qz` step needed)
- `self-hosted/backend/cg_intrinsic_math.qz` — emit the LLVM IR (six handlers; `widening_mul_{lo,hi}` use `mul i128`; carry/borrow use `@llvm.{u,s}{add,sub}.with.overflow.i64`)
- `self-hosted/backend/codegen_runtime.qz` — declare `@llvm.uadd.with.overflow.i64` and `@llvm.usub.with.overflow.i64` next to the existing `sadd/ssub/smul` declarations (two sites: hosted at line ~6823, freestanding at line ~10359)
- `spec/qspec/widening_mul_spec.qz` (new) — test edge cases (zero, max, mid-overflow, multi-limb chain sanity)

Estimate: 1-2 quartz-days (mostly mechanical; pattern-match on existing intrinsics like `popcount`, `rotl`, and `rdmsr`).

## Secure zeroing

`std/core/crypto/zeroize.qz` (shipped 2026-05-08):

```be
def zeroize(ptr: Int, len: Int): Void
  var i = 0
  while i < len
    volatile_store<U8>(ptr + i, 0)
    i += 1
  end
end
```

`volatile_store<U8>` lowers to `store volatile i8`. LLVM cannot eliminate volatile stores, before or after inlining — the no-DCE guarantee is at the IR level. Pattern is industry-standard (Rust `zeroize` crate, BoringSSL `OPENSSL_cleanse`); those impls also use `noinline` as belt-and-suspenders against C's weaker `volatile` semantics. We don't need `@noinline` for correctness because Quartz lowers directly to LLVM IR (not C); add it later if optimizer behavior ever drifts. See "Compiler attributes that would be belt-and-suspenders but are not yet present" above.

API takes raw `(ptr, len)` rather than a `Bytes` or `Vec<Int>` wrapper because:
1. Crypto state typically lives in `malloc`-allocated buffers passed to `extern "C"` HACL\* primitives — raw pointer is the natural shape.
2. Wrapping `Vec<Int>` would require either a `vec_data_ptr` builtin (compiler work) or non-volatile element-wise stores (DCE-able, defeats the whole point).
3. Higher-level wrappers can compose on top later when the consumer story is concrete.

Also add `Drop` integration when Quartz's drop story is finalized — secret-bearing types should `zeroize` on drop automatically. (Not a Phase 1 blocker; users call `zeroize(ptr, len)` manually until then.)

## Phased plan

### Phase 1 — HACL\* bootstrap + WireGuard demo (companion: NET.1)

| Step | Work | Quartz-days | Status |
|------|------|-------------|--------|
| 1.1 | License review + vendor `Hacl_*` C sources into `vendor/hacl-c/` | 0.5 | ✅ shipped 2026-05-08 |
| 1.2 | `std/core/crypto/{chacha20poly1305,blake2s,curve25519,hkdf}.qz` FFI shims | 2 | ✅ shipped 2026-05-08 |
| 1.3 | `std/core/crypto/{subtle,zeroize}.qz` | 0.5 | ✅ shipped 2026-05-08 |
| 1.4 | `widening_mul_*` + `carrying_add_*` + `borrowing_sub_*` compiler intrinsics | 1-2 | ✅ shipped 2026-05-08 (`21648462`) |
| 1.5 | `std/crypto/rng.qz` — DRBG over HKDF-BLAKE2s, seeded from `getentropy(3)` | 1 | ✅ shipped 2026-05-08 |
| 1.6 | `std/crypto/noise.qz` — Noise IKpsk2 only | 2 | ✅ shipped 2026-05-08 |
| 1.7 | Wycheproof test corpus loader + per-primitive specs | 1 | ⏭️ unblocked |

**Step 1.1 details:** vendored HACL\* commit `504c2987452f87fe44bce9b9f12e19d6e051761f`
(2026-04-10) into `vendor/hacl-c/`. 5.2 MB total: full `dist/portable-gcc-compatible/`
(222 files), `dist/karamel/include/` (11 files), `dist/karamel/krmllib/` (`__int128`
polyfill needed by Curve25519_64). License: Apache-2.0. Author-stub `config.h`
configures scalar-only build (`HACL_CAN_COMPILE_UINT128` on, intrinsics/SIMD
off — fast paths can be re-enabled later via target-specific overrides).
`quake vendor:hacl-verify` task confirms structure + parses 7 WG primitives
under `clang -fsyntax-only` to catch vendor-tree damage. See
`vendor/hacl-c/README.md` for the snapshot-update procedure.

**Step 1.6 details:** `std/crypto/noise.qz` (~530 LoC including doc comments;
~400 LoC of actual code) implements the IKpsk2 driver as 6 top-level entry
points (`noise_create_initiation`, `noise_consume_initiation`, `noise_create_response`,
`noise_consume_response`, `noise_split`, `noise_wg_mac1`) plus internal MIX_HASH /
MIX_KEY / KDF2 / KDF3 helpers. State is a single 160-byte malloc'd buffer.
`quake crypto:smoke` exercises a full handshake end-to-end (matching swapped
transport keys), an AEAD round-trip under transport keys, MAC1 self-consistency,
and two negative paths (tampered msg.static rejection, PSK-mismatch detection
via msg.empty AEAD failure). All 14 smoke checks green on first run.

**Phase 1 total: ~8-9 quartz-days. Steps 1.1–1.6 shipped 2026-05-08;** only
Step 1.7 (Wycheproof loader) remains. Crypto stdlib is functionally complete
for WireGuard; NET.1 picks up `std/net/wireguard/*` + the unikernel glue from here.

### Phase 2 — Pure-Quartz primitive replacement (slot over time)

Each primitive is its own milestone. ~1-3 quartz-days each. Total: ~1 quartz-month, sequenced across sessions, no deadline. See "Implementation source" above for ordering.

### Phase 3 — `Secret<T>` + `dudect_check` (stretch, post-NET.1)

| Step | Work | Quartz-days |
|------|------|-------------|
| 3.1 | `Secret<T>` type-system tracking (typecheck rejects branches/indexing on Secret values) | 5-7 |
| 3.2 | `std/core/crypto/testing/dudect.qz` | 2-3 |
| 3.3 | Migrate Phase 2 primitives to `Secret<T>` + add `dudect_check` tests | 2-3 |

## Risk register

| Risk | Mitigation |
|---|---|
| HACL\* generated C uses constructs LLVM lowering can't follow | Verify by compiling each primitive in isolation before vendoring; fall back to `_51` Curve25519 (no `__int128`) if `_64` breaks |
| HACL\* license incompatible with Quartz's | License review is Step 1.1; bail to BoringSSL or libsodium if blocked |
| `__int128` codegen broken in some Quartz target (freestanding, aarch64) | Phase 1 only needs FFI to C — `__int128` is C's problem there. Phase 2 Curve25519 uses 5×51-bit limbs over native `u64`; no Quartz `i128` ever. |
| `@widening_mul` lowering produces poor codegen on aarch64 | Pattern-check generated asm against `mul + umulh`; if missed, hand-write inline-asm path in `cg_intrinsic_arith.qz` |
| Constant-time guarantees lost to LLVM optimization | Acknowledged limitation. `subtle` + `dudect_check` is honest; don't ship `@[constant_time]` until backend story exists. |
| MirageOS-style "Curve25519 rewritten three times" experience | Plan for it. Phase 2 Curve25519 is sequenced last; we'll have HACL\* working underneath the entire time, so partial / wrong / slow attempts don't break the demo. |

## Decision log

- **2026-05-08** — Hybrid path (Phase 1 HACL\* + Phase 2 pure-Quartz one-at-a-time) chosen over pure-Quartz-from-day-one or permanent-FFI. Reason: balances time-to-demo (Phase 1 ships in ~8-9 quartz-days) against the language-maturation deliverable (Phase 2 is the actual exercise).
- **2026-05-08** — `subtle` helpers chosen as initial constant-time stance; `Secret<T>` + `dudect_check` roadmapped; full `@[constant_time]` deferred. Reason: `@[constant_time]` cannot deliver its guarantee under LLVM optimization without a Quartz-controlled lowering pass; shipping it now would be a half-truth. `subtle` matches Rust/Go's stance and is what production crypto actually relies on.
- **2026-05-08** — `@widening_mul` chosen as compiler intrinsic over inline-asm-in-stdlib. Reason: pays back well beyond crypto (bignum, hash tables, PRNGs); matches Rust `widening_mul` and Zig `@mulWithOverflow`; `1-2 quartz-days` of compiler work makes the capability portable.
- **2026-05-08** — Six split intrinsics shipped instead of three tuple-returning ones (`_lo`/`_hi`, `_sum`/`_carry`, `_diff`/`_borrow`). Reason: Quartz's existing intrinsic surface returns a single `i64` per call; tuple-return-from-intrinsic requires real MIR + typecheck + lowering work (~1-2 quartz-days) which is its own work item, not Step 1.4. LLVM CSE folds the redundant operand chains when both halves of the same call are present in a basic block, so split intrinsics produce identical asm to a tuple intrinsic. Revisit when Phase 2 pure-Quartz primitives report on whether call-site verbosity is painful enough to motivate the larger MIR refactor.
- **2026-05-08** — Tier placement: primitives in `std/core/crypto/*` (no allocator), protocol code in `std/crypto/*` (allocator OK). Reason: matches the three-tier scaffolding from KERNEL_EPIC SYS.2; primitives operate on caller-owned buffers and don't need an allocator.
- **2026-05-08** — `chacha20poly1305` (one identifier, no separator) chosen as module name. Reason: matches RFC 8439 text and HACL\* C symbol. Stdlib follows external-spec naming where it exists.
- **2026-05-08** — Algorithm-agility (e.g., generic AEAD trait) deliberately *not* shipped. Reason: closes a major class of crypto-misuse footguns. Matches Noise Protocol Framework's "no negotiation" stance. Composable primitives by name, not by runtime dispatch.
- **2026-05-08 (Step 1.3)** — `subtle.qz` ships scalar primitives that take `Int` (not typed `U8`/`U32`) and return all-ones-or-zero masks (not 0/1). Reason: (a) Quartz's runtime integer is uniformly `Int`, so `U8`/`U32` would only carry intent — width is documented per-helper; (b) mask-returning form composes cleanly through bitwise AND/OR/XOR, which Phase 2 Curve25519/Poly1305 will rely on; (c) the canonical `((x - 1) >> width) & mask` and `((a | -a) >> 63) & 1` tricks fall out naturally because Quartz's `>>` is logical (`lshr`).
- **2026-05-08 (Step 1.3)** — `zeroize` takes `(ptr: Int, len: Int)` rather than wrapping `Bytes` or `Vec<Int>`. Reason: crypto state lives in `malloc`-allocated buffers passed to `extern "C"` HACL\* primitives; raw pointer is the natural shape. Wrapping `Vec<Int>` would require either a `vec_data_ptr` builtin or non-volatile element-wise stores (DCE-able). Higher-level wrappers compose on top later.
- **2026-05-08 (Step 1.3)** — `@noinline` compiler attribute filed as a follow-up rather than a prerequisite for `zeroize`. Reason: `volatile_store<U8>` lowers to `store volatile i8`; LLVM's IR-level volatile semantics are strictly stronger than C's, and the optimizer cannot eliminate volatile stores before or after inlining. Rust/BoringSSL use `noinline` as belt-and-suspenders against C's weaker volatile; Quartz lowers directly to LLVM IR, so the belt is already buckled. Add `@noinline` opportunistically. *(Followed up same-day — `@noinline` shipped in `5989fddb`.)*
- **2026-05-08 (Step 1.1)** — Vendor full `dist/portable-gcc-compatible/` (5.2 MB) rather than narrowing to the 7-primitive WG subset. Reason: `Hacl_HMAC` is a generic dispatcher whose `.c` file references SHA-1/2/3/MD5/Blake2b headers; isolating only Blake2s would require patching upstream. Vendor-and-link-GC (`-ffunction-sections -Wl,--gc-sections`) drops unused code at link time with zero runtime overhead. Trade-off: 5.2 MB on disk, but defensibly future-proof for primitives we'll add later (Ed25519 for signatures, SHA-256 for misc).
- **2026-05-08 (Step 1.1)** — Author Quartz-side `config.h` rather than running upstream's `configure` script. Reason: the configure script depends on bash + a working CC + feature-detection runs that don't fit Quartz's build model. Our minimal config (`HACL_CAN_COMPILE_UINT128` on, all SIMD/intrinsics/asm off) compiles everywhere clang/gcc are available and lets Phase 2 pure-Quartz re-implementations replace HACL\* one-at-a-time without stranding us on platform-specific fast paths. Re-enable SIMD per-target later via overrides if perf demands it.
- **2026-05-08 (Step 1.2)** — Switched to `Hacl_Curve25519_51` (5×51-bit limbs in pure C) instead of `Hacl_Curve25519_64` despite the design memo's original `_64` choice. Reason: `_64`'s fast paths use `add_scalar_e` / `fadd_e` / `cswap2_e` extern symbols on non-x86 hosts (or with `HACL_CAN_COMPILE_INLINE_ASM` off); those symbols come from Vale-extracted ASM files we haven't vendored. On aarch64 the link fails. `_51` compiles + links + runs correctly on every platform our toolchain supports (verified on darwin-arm64). Cost: ~4× slower than `_64` would be on x86 with inline asm; irrelevant for handshake throughput where we measure in handshakes/second, not bytes/second. Phase 2's pure-Quartz replacement will target the `_51` field-element layout anyway, so this is closer to the eventual destination.
- **2026-05-08 (Step 1.2)** — Crypto FFI smoke tests live in `spec/qz/crypto_ffi_smoke.qz` and run via `quake crypto:smoke`, not `quake qspec`. Reason: qspec doesn't currently support per-spec extra link libraries; the HACL\* `.o` archive needs to be linked with each crypto-using binary. Filed as follow-up: extend qspec with a per-file `link_libs` parameter, fold `crypto:smoke` into the regular suite once that lands.
- **2026-05-08 (Step 1.5)** — Used `getentropy(3)` instead of the original memo's `getrandom(2)` for the OS entropy source. Reason: `getentropy` is the BSD-portable API available on macOS 10.12+, glibc 2.25+, FreeBSD 12+, and OpenBSD; `getrandom(2)` is Linux-specific. No platform-specific `@cfg` shims needed. Cost: 256-byte per-call cap (we loop), versus `getrandom`'s no-cap on Linux. Trivial cost; reuses standard libc.
- **2026-05-08 (Step 1.5)** — DRBG construction: 32-byte PRK state. `rng_fill(N)` calls HKDF-Expand(PRK, info=∅, len=N+32), returns the first N bytes as output, replaces PRK with the trailing 32 bytes. Per-call rekey gives forward secrecy: leaking PRK at time T does not reveal output generated before T. No counter needed — the PRK chain provides domain separation between calls. Initial PRK derived via HKDF-Extract(salt=∅, ikm=getentropy(64)). For `rng_fill(N>8128)` we loop in 8128-byte chunks because RFC 5869 §2.3 caps Expand at 255 × 32 = 8160 bytes (we reserve 32 for rekey). Forward secrecy is the load-bearing security property; matches the design space of NIST SP 800-90A's HMAC_DRBG without the formal certification.
- **2026-05-08 (Step 1.6)** — `std/crypto/noise.qz` writes/reads the message *body* (msg_α only — 116 bytes initiation, 60 bytes response) and exposes `noise_wg_mac1` as a courtesy. The 16-byte mac1 + 16-byte mac2 cookie trailer is left for the WG layer (`std/net/wireguard`) to append. Reason: mac1/mac2 are WG-specific cookie machinery and are not part of the Noise spec proper; cookie state (rotating responder secret, 120-second window) is timer-driven and lives at the protocol layer where peer tables live. The MAC1 helper sits beside Noise rather than in the WG layer because its key derivation (`Hash(LABEL_MAC1 || peer_static_pub)`) is cheap and tightly bound to the message format — exposing it here keeps the smoke test self-contained.
- **2026-05-08 (Step 1.6)** — KDF{1,2,3} are implemented as direct calls to existing `hkdf_extract_blake2s` + `hkdf_expand_blake2s` rather than a hand-rolled HMAC chain. Reason: WG's τ-chain (`τ0 = HMAC(k, x)`, `τ1 = HMAC(τ0, 0x1)`, `τi = HMAC(τ0, τi-1 ‖ i)`) is *byte-identical* to HKDF when info is empty. T(1) = HMAC(PRK, info ‖ 0x1) collapses to HMAC(PRK, 0x1) when info is empty, matching τ1. Output of HKDF-Expand for L=N×32 is τ1 ‖ τ2 ‖ … ‖ τN, which is exactly KDFn's tuple-output sliced into 32-byte chunks. Saves a few hundred lines of HMAC plumbing and reuses the audited HACL\* HKDF implementation.
- **2026-05-08 (Step 1.6)** — HandshakeState is a single 160-byte malloc'd buffer with fixed offsets (`buf[0..32)` chain_key, `buf[32..64)` hash, `buf[64..96)` ephemeral priv, `buf[96..128)` ephemeral pub, `buf[128..160)` peer ephemeral pub) wrapped in a one-field `struct HandshakeState { buf: Int }`. Reason: matches the `Rng { prk: Int }` pattern in `std/crypto/rng.qz`; one allocation per handshake; `noise_handshake_destroy` zeroes the entire region in one `zeroize` call. Trades a struct-of-fields representation for fewer allocations + simpler destruction semantics. Per-handshake malloc churn is dominated by transient KDF / DH scratch buffers; the state buffer itself is one alloc.
- **2026-05-08 (Step 1.6)** — Errors reported as `Int` returns (`0` success, `0 - 1` failure) — matches `chacha20poly1305_decrypt`'s convention. Reason: avoids `Result<T, E>` ceremony for what is uniformly a "drop the packet silently" condition (per WG paper §5.1 "silence is a virtue"). Failure modes — AEAD tag mismatch, ECDH all-zero output — are uniformly recoverable at the WG layer by ignoring the message; richer error type provides no additional caller capability and adds allocation overhead.
- **2026-05-08 (Step 1.6)** — PSK is always a 32-byte buffer; "no PSK" mode is a buffer of 32 zero bytes (per WG paper §5.4: `Q := 0^32` when PSK is not in use). Reason: keeps the API uniform — no Optional / nullable parameter — and matches the spec's algebraic treatment exactly (mixing zeros into KDF3 is a well-defined no-op-equivalent vs mixing the actual PSK). Caller's responsibility to memset 32 zero bytes if they don't have a PSK; avoids special-case branching inside the driver.

## Out of scope

- **TLS** — too big; not the right forcing function for crypto stdlib bootstrap. Quartz-native TLS is its own multi-month epic if/when it comes.
- **Post-quantum primitives** (Kyber, Dilithium) — Zig ships these; Quartz can later. Not blocking.
- **AES** — WireGuard doesn't need it. AES-NI / aarch64-crypto-extensions ISA support is the right vehicle when AES becomes necessary (e.g., for TLS).
- **RSA / ECDSA** — same logic; WireGuard doesn't need them. X25519 + Ed25519 cover the practical curve-crypto surface for now.
- **Hardware security module (HSM) / TPM integration** — far future.
- **Side-channel-resistant cache eviction / Spectre mitigations** — out of scope for stdlib; falls under target-feature flags if ever needed.

## References

- RFC 8439 — ChaCha20-Poly1305 AEAD
- RFC 7693 — BLAKE2
- RFC 7748 — Elliptic Curves for Security (X25519)
- RFC 5869 — HKDF
- WireGuard whitepaper (Donenfeld 2017) — `https://www.wireguard.com/papers/wireguard.pdf`
- Noise Protocol Framework — `https://noiseprotocol.org/noise.html`
- HACL\* — `https://github.com/hacl-star/hacl-star`
- fiat-crypto — `https://github.com/mit-plv/fiat-crypto`
- curve25519-dalek — `https://github.com/dalek-cryptography/curve25519-dalek`
- mirage-crypto — `https://github.com/mirage/mirage-crypto`
- Reparaz, Balasch, Verbauwhede 2017 — *dude, is my code constant time?* (DATE 2017)
- Wycheproof — `https://github.com/google/wycheproof`
