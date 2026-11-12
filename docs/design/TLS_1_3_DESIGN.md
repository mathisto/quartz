# NET.5 — TLS 1.3 with X25519MLKEM768

**Filed:** 2026-05-22
**Status:** Design — implementation pending
**Owner:** NET.5
**Branch (planned):** `net-5-tls`
**Depends on:**
- NET.1 (Curve25519 + ChaCha20-Poly1305 + HKDF + SHA-256/512 substrate)
- NET.2 (Ed25519 sigverify path)
- NET.3 (ML-KEM-768 + SHA-3 + `X25519MLKEM768` hybrid combiner)
- NET.4 (`Secret<T>` + dudect + `@ct` Layer 3 — every key-schedule secret on the
  TLS hot path crosses these gates)

**Unblocks:**
- `curl https://mattkelly.io/` end-to-end against the Quartz unikernel with
  zero Linux in the TLS path
- HTTPS reverse-proxy without nginx/openssl
- HPKE / MLS / Noise-in-TLS once a wire-stable record layer exists
- Subsumes the original KERN.5 stretch (port rustls into the unikernel) — we
  hand-write TLS over our own crypto stack instead

---

## Why TLS 1.3, and why now

NET.1–4 leave us with a complete pure-Quartz crypto stack:

| Primitive | Provided by |
|---|---|
| ChaCha20-Poly1305 (AEAD) | NET.1 (`std/core/crypto/chacha20poly1305.qz`) |
| AES-128/256-GCM | **MISSING** — must ship in NET.5a |
| SHA-256 | implicit in HKDF / NET.2 ARX shape |
| SHA-384 | trivially derived from SHA-512 (NET.2) by output truncation |
| SHA-512 | NET.2 |
| HKDF-Extract / HKDF-Expand | NET.1 (`std/crypto/hkdf.qz`) |
| Ed25519 (sigverify + signing) | NET.2 — CT after NET.4 `_sc_reduce_64` close |
| X25519 (ECDHE) | NET.1 Step 2.16 |
| ML-KEM-768 (KEM) | NET.3 |
| `X25519MLKEM768` combiner | NET.3c (TLS 1.3 wire-form raw-concat, draft-04) |

The only crypto gap is **AES-GCM**, which is sub-quartz-day work as a stretch
within NET.5a. Everything else is wiring: parse `ClientHello` → compute key
schedule → encrypt records → validate certificate.

The strategic shape: post-quantum hybrid TLS is **already deployed
in production** at Cloudflare (default since Q4 2024), Google Chrome (default
since 124, April 2024), AWS KMS/ACM/Secrets Manager (announced 2025), and is
the Go 1.24+ stdlib default. Quartz shipping native TLS-1.3 with
`X25519MLKEM768` puts the language in the same row as Go's `crypto/tls`,
rustls, BoringSSL — the production-language TLS baseline. Combined with the
NET.1–4 substrate, this finishes the original NET.x roadmap's stated goal:
*Quartz authors its own complete HTTPS stack, no FFI in the request path.*

Sequencing rationale (D2 / D4 / D1): NET.5 is the **highest-impact unlock
remaining** in the NET.x track. It activates every NET.1–4 primitive in
production-relevant geometry, hits the public endgame
(`https://mattkelly.io/` served by Quartz), and the substrate cost from here
is sub-week. Going wide on TLS now also surfaces NET.6+ candidates
(HTTP/2 + HTTP/3 over QUIC, QUIC native, ACME for cert issuance) with
concrete shape rather than speculation.

## Prior-art table

Surveyed 2026-05-22 before coding. Columns: **PQ-hybrid** = ships
`X25519MLKEM768` (or its predecessor `x25519Kyber768Draft00`) by default or
behind a feature flag; **State** = how the handshake state machine is
structured; **Cert** = whether the impl includes its own X.509 parser or
delegates.

| Implementation | Lang | LoC | TLS 1.2 | PQ-hybrid | State | Cert | Notable |
|---|---|---:|---|---|---|---|---|
| **Go `crypto/tls`** | Go | ~25k | Yes | Default since 1.24 (`X25519MLKEM768`) | `serverHandshakeStateTLS13` / `clientHandshakeStateTLS13` struct-with-fn-methods | uses `crypto/x509` (separate ~5k LoC) | The reference for "production but readable" — what Filippo and the Go crypto team ship |
| **rustls** | Rust | ~60k (core ~30k) | No (TLS 1.3 + optional 1.2 via feature) | `rustls-post-quantum` crate, feature `prefer-post-quantum` | Explicit-state enum `State<Data>`; transitions via `into_*` functions | `rustls-webpki` (separate) | Type-state-flavored explicit state machine; what AWS, Cloudflare, Linkerd run in production |
| **BoringSSL / AWS-LC TLS** | C | ~50k | Yes (legacy) | Yes — codepoint `0x11EC` since 2024 | `ssl_state*` enum w/ switch; legacy OpenSSL-derived | uses BoringSSL X.509 (~15k) | Production at Google; AWS-LC is **first FIPS-140-3-validated ML-KEM TLS** |
| **picotls (h2o)** | C | ~5k | No (TLS 1.3 only) | No (Kyber draft historically) | `ptls_handshake_state_t` enum w/ switch | Caller-provided callback (no built-in X.509) | The minimalist gold standard for TLS-1.3-only scope; what we should aim closest to |
| **mint** | Go | ~10k | No | No | Explicit `HandshakeState` interface w/ `Next()` returning next state | Caller-provided | Bifurcation/Barnes minimal reference; informed RFC 8446 drafting |
| **miTLS / Project Everest** | F\* → C | proof-heavy | Yes | No (older) | F\*-verified small-step state machine | Verified parser via LowParse | The formal-verification reference; informs our state-correctness invariants |
| **s2n-tls (Amazon)** | C | ~30k | Yes | Yes — `KMSPQ-TLS-1-3-2024-10` policy | Continuation-passing `s2n_handshake_action` table | Internal X.509 ~5k | "Tested, small, secure" Amazon TLS; powers many AWS endpoints |
| **`rustls-webpki`** | Rust | ~6k | n/a | n/a | n/a | Standalone X.509 chain validator | The minimal X.509 reference we mirror for `std/net/tls/x509.qz` |
| **bsaes (Yawning)** | Go | ~800 | n/a | n/a | n/a | n/a | Constant-time portable AES in Go, BearSSL-derived; the model for our scalar-CT AES |
| **BearSSL `aes_ct` / `aes_ct64`** | C | ~600 | n/a | n/a | n/a | n/a | Pornin's 32-bit + 64-bit CT-AES — the canonical fixsliced reference we port from |

**Headline observations driving Quartz design:**

1. **Scope discipline matters enormously.** rustls, Go `crypto/tls`,
   BoringSSL TLS are 25–60k LoC. picotls is ~5k for TLS-1.3-only. We aim
   ≈ 5–7k LoC for full client + server, X25519MLKEM768-first, Ed25519-only
   sigs v1. **Decision: TLS-1.3-only, no 1.2 compat, no PSK resumption v1,
   no 0-RTT v1, no client cert auth (mTLS) v1, no HelloRetryRequest v1.**
2. **State machine via explicit enum + match.** rustls uses the type-state
   pattern (one type per state); Go uses field-bag-plus-fn-methods; picotls
   uses an enum + switch. Quartz lacks Rust's affine moves but has clean
   `enum` + `match` — we shape per picotls / Go, with one `enum HsState`
   driving a `step(state, msg)` transition function and `Secret<T>`-typed
   secrets threaded through. Type-state-ish via per-variant payloads, but
   not Rust-affine. This is what rustls issue #461 evolved toward and is
   the readable shape in non-Rust languages.
3. **Fixsliced AES is the right scalar-portable CT-AES.** Bitsliced
   64-bit-limb (Käsper-Schwabe 2009) wins with SIMD but Quartz codegen is
   scalar — fixslicing (Adomnicai-Peyrin 2020 / BearSSL `aes_ct`) gets
   ~25-30 cycles/byte on scalar i64 limbs vs ~22 c/b bitsliced-w-SIMD, and
   ports cleanly to Quartz's `widening_mul`-flavored intrinsics for GHASH.
   AES-NI x86_64 hardware fast-path is a NET.5a stretch via `@llvm.x86.aes*`
   intrinsics — **filed for v2** so the v1 stays portable to ARM and the
   unikernel-on-qemu64 (no AES-NI) target.
4. **`X25519MLKEM768` first-class, plain X25519 for fallback.** SecP256r1
   is the third named group in the IETF hybrid draft but adds NIST-curve
   work we don't have substrate for (RFC 6090 short Weierstrass + RFC 6979
   ECDSA + secp256r1 field arithmetic ≈ 1500 LoC). Cost/benefit poor in 2026
   when X25519 is universally interop and `X25519MLKEM768` is the PQ-hybrid
   that ships. SecP256r1 + ECDSA filed forward as NET.6.
5. **Ed25519-only sigs v1.** The Web PKI requires RSA-PSS + ECDSA for
   public-CA-issued certs. Quartz NET.5 v1 ships **self-signed Ed25519
   certs** — sufficient for the `https://mattkelly.io/` endpoint
   (the cert is whatever we choose), sufficient for internal services,
   sufficient for testing against `curl --insecure`. RSA + ECDSA file as
   NET.6 once we have the curve substrate for ECDSA (see NET.6 sketch).
   This is what s2n-tls's "limited cipher suites by design" policy does;
   it's defensible.

### What we explicitly take from each prior-art entry

- **Go `crypto/tls` `handshake_messages.go`** — the wire-format codec
  shapes for `ClientHello` / `ServerHello` / `EncryptedExtensions` /
  `Certificate` / `CertificateVerify` / `Finished`. Filippo's prose is the
  cleanest readable reference; we port shape, not bytes.
- **rustls `tls13/key_schedule.rs`** — the secret-labels machinery
  (`derive_secret(label: "c hs traffic", ...)` ladder). Mechanical
  port; `Secret<T>` annotations free.
- **picotls `picotls.c`** — the enum-+-switch state shape and the choice
  to put cryptography behind a pluggable provider table. We don't need
  pluggable (Quartz has one crypto stack) but the seam matters for
  AES-NI fast-path opt-in (v2).
- **rustls-webpki** — the minimal X.509 parser shape (`Cert` struct +
  per-field parser, no full RFC 5280 chain semantics). We port the same
  minimalist stance: SPKI, issuer, subject, NotBefore/NotAfter, SANs,
  signature, signature-algorithm OID. NO: CRLs, OCSP, name constraints,
  policy constraints, BasicConstraints depth checking beyond `pathLenConstraint`.
- **BearSSL `aes_ct`** — the fixsliced AES reference. Public domain.
  Pornin's commentary matches the algorithm 1:1 with the implementation,
  which is what we want for porting.
- **tls13.xargs.org / Driscoll's "Illustrated TLS 1.3"** — every-byte
  reference handshake for testing. The KAT corpus for NET.5 wire-format
  smoke is "produce/consume the exact bytes from that page."

## Architecture

### Module layout

Eight new files; planned layering (top to bottom on the call graph):

```
spec/qz/tls_smoke.qz             # loopback client+server, ~200 LoC
spec/qz/tls_interop_smoke.qz     # curl/openssl/Go interop, ~300 LoC
spec/qz/tls13_xargs_kat.qz       # byte-by-byte tls13.xargs.org KAT
spec/qz/aes_smoke.qz             # AES + AES-GCM KAT (NIST CAVS + Wycheproof)

std/net/tls13/server.qz          # ServerSession + handshake state machine
std/net/tls13/client.qz          # ClientSession + handshake state machine
std/net/tls13/handshake.qz       # message codec + transcript hash
std/net/tls13/record.qz          # record layer (encrypt/decrypt/seq)
std/net/tls13/key_schedule.qz    # HKDF-Expand-Label + derive_secret ladder
std/net/tls13/alert.qz           # the 24 alert codes + close_notify
std/core/crypto/x509.qz          # minimal DER cert parser + Ed25519 verify glue  [moved 5b.2]
std/core/crypto/asn1.qz          # OID + length + tag DER primitives          [moved 5b.1]

std/core/crypto/aes.qz           # fixsliced CT-AES (128 + 256)
std/core/crypto/aes_gcm.qz       # AES-GCM AEAD + GHASH (Karatsuba 32-bit polymul)
```

Approximate sizing per file (conservative):

| File | LoC |
|---|---:|
| `aes.qz` | ~700 |
| `aes_gcm.qz` | ~400 |
| `asn1.qz` | ~250 |
| `x509.qz` | ~500 |
| `key_schedule.qz` | ~250 |
| `record.qz` | ~400 |
| `handshake.qz` | ~600 |
| `client.qz` | ~600 |
| `server.qz` | ~700 |
| `alert.qz` | ~80 |
| smokes (4 files) | ~1000 |
| **Total** | **~5,500** |

Picotls scope. ~10× under rustls. Achievable.

### State machine

One `enum HsState` drives both client + server with per-side variants. Server
variants and client variants don't overlap — a `match` exhausts the side's
states unambiguously.

```quartz
# Per-side handshake state. Each variant carries the data inherited from
# the prior step. The `Secret<T>` typing is load-bearing on the hot path.
enum HsState
  # ----- client states -----
  ClientStart                                                # before send(ClientHello)
  ClientWaitSh(ch_bytes: Vec<U8>, kex_priv: KexPriv)        # CH sent; awaiting SH
  ClientWaitEe(hs_secret: Secret<HsSecret>, ts: Transcript)  # SH done; key sched live
  ClientWaitCert(ts: Transcript, hs_secret: Secret<HsSecret>)
  ClientWaitCv(ts: Transcript, hs_secret: Secret<HsSecret>, peer_cert: Cert)
  ClientWaitSrvFin(ts: Transcript, hs_secret: Secret<HsSecret>)
  ClientSendFin(ts: Transcript, hs_secret: Secret<HsSecret>)
  ClientConnected(app: AppSecrets)                           # send(Finished); ready

  # ----- server states -----
  ServerStart                                                # awaiting ClientHello
  ServerSendSh(ch: ClientHelloDecoded)
  ServerSendEe(ts: Transcript, hs_secret: Secret<HsSecret>)
  ServerSendCert(ts: Transcript, hs_secret: Secret<HsSecret>)
  ServerSendCv(ts: Transcript, hs_secret: Secret<HsSecret>)
  ServerSendFin(ts: Transcript, hs_secret: Secret<HsSecret>)
  ServerWaitClFin(ts: Transcript, hs_secret: Secret<HsSecret>, app: AppSecrets)
  ServerConnected(app: AppSecrets)
end

# Driver: returns (next_state, bytes_to_send | bytes_for_app, alert?)
def hs_step(state: HsState, input: HsInput): HsStep
```

The per-state payloads thread the transcript hash + key-schedule state
forward; consuming a `ClientWaitSh` produces a `ClientWaitEe` carrying the
post-SH `hs_secret`. The earlier-state payload **is** the precondition for
the later-state transition. This is the "typestate via variant payloads"
idiom — Quartz's expression of what rustls does with affine moves between
distinct types.

D5 / D2 alert: `match` is exhaustive at the typechecker per Quartz's match
semantics, so a missing state branch is a compile-time error. Combined with
`@ct` on the key-schedule helpers (Layer 3), the state machine is
verifiable rather than testable.

### Record layer

RFC 8446 §5. Plain wire format:

```
TLSCiphertext {
  opaque_type   = 23 (application_data on the wire, always)
  legacy_record_version = 0x0303 (TLS 1.2, ignored on receive)
  length        = u16
  encrypted_record  // = TLSInnerPlaintext encrypted under traffic key
}

TLSInnerPlaintext {
  content       = bytes
  content_type  = u8 (real type: handshake=22, alert=21, application_data=23)
  zeros         // padding, length-varying
}
```

The AEAD nonce is `traffic_iv XOR seq_num_BE_padded_to_iv_len`. Sequence
number is reset to 0 on each key change (post-handshake, post-key-update).

`record.qz` ships:

```quartz
struct Record
  type:        U8       # 22, 21, 23 (after decrypt: real inner type)
  data:        Bytes
end

def record_encrypt(out_buf: Int, traffic_key: Secret<TrafficKey>, traffic_iv: Bytes12,
                   seq: U64, inner_type: U8, plaintext: Int, plaintext_len: Int): Int
  # Returns total record length written to out_buf.

def record_decrypt(out_plaintext: Int, out_inner_type: Int,
                   traffic_key: Secret<TrafficKey>, traffic_iv: Bytes12,
                   seq: U64, ciphertext: Int, ciphertext_len: Int): Int
  # Returns plaintext length, or -1 on AEAD failure (caller MUST close_notify
  # with bad_record_mac and abort).
```

The `Secret<TrafficKey>` annotation flows through the AEAD call sites; the
NET.4 Layer 3 `@ct` annotation on the AEAD primitive is a stretch goal once
the helper signatures migrate to `Secret<T>` (filed in NET.4 follow-ups).

### Key schedule

RFC 8446 §7.1 — the secret ladder. Three "extract" steps and many "expand"
derivations:

```
                  0
                  |
                  v
    PSK ->  HKDF-Extract = Early Secret    (PSK omitted in v1 → all zeros)
                  |
                  +-----> Derive-Secret(., "ext binder" | "res binder", "")
                  |       (resumption — out of scope v1)
                  |
                  +-----> Derive-Secret(., "c e traffic", ClientHello)
                  |       (0-RTT — out of scope v1)
                  |
                  +-----> Derive-Secret(., "e exp master", ClientHello)
                  v
              Derive-Secret(., "derived", "")
                  |
                  v
   (EC)DHE -> HKDF-Extract = Handshake Secret
                  |
                  +-----> Derive-Secret(., "c hs traffic", CH..SH)  -> client_handshake_traffic_secret
                  +-----> Derive-Secret(., "s hs traffic", CH..SH)  -> server_handshake_traffic_secret
                  v
              Derive-Secret(., "derived", "")
                  |
                  v
       0    -> HKDF-Extract = Master Secret
                  |
                  +-----> Derive-Secret(., "c ap traffic", CH..server Finished) -> client_application_traffic_secret_0
                  +-----> Derive-Secret(., "s ap traffic", CH..server Finished) -> server_application_traffic_secret_0
                  +-----> Derive-Secret(., "exp master",    CH..server Finished) -> exporter_master_secret
                  +-----> Derive-Secret(., "res master",    CH..Client Finished) -> resumption_master_secret
```

`key_schedule.qz` shape:

```quartz
def hkdf_expand_label(out: Int, out_len: Int, secret: Secret<Int>, secret_len: Int,
                      label: String, context: Int, context_len: Int): Void

def derive_secret(out: Int, secret: Secret<Int>, label: String, transcript: Transcript): Void

# `secret_*` outputs are `Secret<HsSecret>` / `Secret<AppSecret>` typed
def derive_handshake_secrets(out_c: Int, out_s: Int,
                             prev: Secret<EarlySecret>, dhe_shared: Secret<Bytes64>,
                             transcript: Transcript): Secret<HsSecret>
```

Threading `Secret<T>` through means any `if (secret_byte == 0)` shape inside
`derive_*` is a typecheck error. NET.4's Layer 1.

### X.509 / DER

`asn1.qz` ships the minimal DER decoder primitives — `tag`, `length`,
`OID`, `OctetString`, `Integer`, `Sequence`, `Set` — and `x509.qz` extracts
the fields TLS 1.3 actually needs:

```quartz
struct Cert
  raw:           Bytes          # whole encoded cert (needed for transcript)
  spki:          Bytes          # subject public key bits — the Ed25519 32-byte key
  spki_alg:      OidId          # = OID_ED25519 for v1
  not_before:    U64            # unix seconds
  not_after:     U64
  subject_cn:    String
  san_dns:       Vec<String>
  sig_alg:       OidId          # = OID_ED25519
  sig:           Bytes          # 64-byte Ed25519 signature over tbsCertificate
  issuer_raw:    Bytes          # exact bytes of issuer Name (for chain matching)
end

def x509_parse(cert_der: Int, cert_len: Int): Cert  # throws on malformed

def x509_verify_chain(leaf: Cert, intermediates: Vec<Cert>, roots: Vec<Cert>,
                      now_unix: U64, hostname: String): Int
```

**What v1 deliberately does NOT do:**
- RSA / ECDSA signature schemes — Ed25519-only sigs (this is a tight scope
  call; see "Non-goals" below)
- Name constraints, policy constraints, EKU enforcement (we check Basic
  Constraints CA bit + path length only)
- CRL or OCSP — closed-world v1
- Subject Alternative Name iPAddress / URI / RFC822Name — dNSName + IP only
- Wildcard matching beyond RFC 6125 left-most label

If the leaf cert isn't issued by a root in our trust store + signed via
Ed25519 + within validity + SAN-matches the hostname, we abort with
`bad_certificate` or `certificate_expired`.

### AES + AES-GCM

`aes.qz` ships fixsliced AES per BearSSL `aes_ct64`'s shape (Pornin) /
Adomnicai-Peyrin 2020. Eight 64-bit limbs hold an AES state where each
limb's bit-i is the i-th bit of the corresponding byte in 8 parallel AES
states — the "fixslice" representation. Operations:

- `aes_ct_keyschedule(rk: Int, key: Int, key_len: Int): Void` — produces
  expanded round keys (11 for AES-128, 15 for AES-256). CT.
- `aes_ct_encrypt8(out: Int, in: Int, rk: Int, rk_len: Int): Void`
  — encrypts 8 × 16-byte blocks in parallel. The 8-way batching is what
  gets the throughput; for single-block uses, we feed 7 dummy blocks.
- `aes_ct_decrypt8(...)` — symmetric.

GHASH is the polynomial multiplication on GF(2¹²⁸) used by GCM. We ship a
CT scalar version via 32-bit limbs and Karatsuba; ~50 LoC.

`aes_gcm.qz` ships:

```quartz
def aes128_gcm_seal(out: Int, key: Secret<Bytes16>, iv: Bytes12,
                    aad: Int, aad_len: Int, plaintext: Int, plaintext_len: Int): Void

def aes128_gcm_open(out: Int, key: Secret<Bytes16>, iv: Bytes12,
                    aad: Int, aad_len: Int, ciphertext: Int, ciphertext_len: Int): Int
  # Returns 0 on tag match, -1 on tag mismatch (use ct_eq_bytes).
```

Plus `aes256_gcm_*`.

Validation gates: NIST CAVS AES-CTR + AES-GCM KAT vectors; Wycheproof
`aes_gcm_test.json`. dudect smoke on `aes_ct_encrypt8` (timing must not
depend on key bytes or plaintext bytes).

## Phasing

| Phase | What | Estimate (quartz-time) |
|---|---|---:|
| 5.0 | Design memo (this doc) + design-review pass | 0.3 qd |
| 5a.1 | Fixsliced AES (128 + 256) + KAT | 0.5 qd |
| 5a.2 | AES-GCM + GHASH + KAT + Wycheproof | 0.5 qd |
| 5a.3 | dudect smoke on AES + AES-GCM ✅ SHIPPED 2026-05-22 (~0.2 qd actual) | 0.2 qd |
| 5c.0 | SHA-256/384 + HMAC + HKDF over SHA-2 (substrate hole filed during 5c.1 bring-up) ✅ SHIPPED 2026-05-22 (~0.5 qd actual) | 0.5 qd |
| 5b.1 | ASN.1/DER primitives + smoke ✅ SHIPPED 2026-05-22 (~0.3 qd actual) | 0.3 qd |
| 5b.2 | X.509 parser + Ed25519 chain verify + smoke ✅ SHIPPED 2026-05-22 (~0.5 qd actual) | 0.7 qd |
| 5c.1 | TLS 1.3 message codec (CH/SH/EE/Cert/CV/Fin/...) ✅ SHIPPED 2026-05-22 (~0.4 qd actual) | 0.5 qd |
| 5c.2 | Transcript hash + record layer (encrypt/decrypt/seq) ✅ SHIPPED 2026-05-22 (~0.4 qd actual) | 0.5 qd |
| 5c.3 | Key schedule (HKDF-Expand-Label + derive_secret ladder) ✅ SHIPPED 2026-05-22 (~0.3 qd actual) | 0.3 qd |
| 5d.1 | TLS client handshake state machine + alerts | 0.7 qd |
| 5d.2 | TLS server handshake state machine + alerts | 0.7 qd |
| 5e.1 | Loopback `tls_smoke.qz`: Quartz-client ↔ Quartz-server | 0.3 qd |
| 5e.2 | `tls13_xargs_kat.qz`: byte-by-byte against tls13.xargs.org | 0.3 qd |
| 5e.3 | `tls_interop_smoke.qz`: curl / openssl / Go `crypto/tls` | 0.5 qd |
| 5f | Wire into the unikernel; deploy to `mattkelly.io` over HTTPS | 0.5 qd |
| **TOTAL (5a–5f)** | | **~6.8 qd** |

ROADMAP estimate is "1-2 quartz-months." Calibrated ÷4: 5–10 qd. 6.8 lands
mid-range. The estimate accounts for:

- AES + AES-GCM being a known-shape port from BearSSL with public KAT.
- X.509 being the always-underestimated piece — see s2n-tls's `crypto/`
  for the discipline this demands.
- The interop step typically surfacing 2–3 small wire bugs that need
  byte-by-byte chase. Budgeted at 0.5 qd.

## Open design questions

1. **Single state machine vs separate client/server?** Single enum w/ side
   discriminator (current plan) keeps state-transition code in one place;
   separate enums per side keeps each enum half the size. Current decision:
   single enum (`HsState`) — exhaustiveness on a 16-variant enum is fine,
   and the shared `match` lives one place. Reversible if the dispatch
   grows hairy.

2. **Where does AES-NI hardware acceleration land?** The naive answer is
   "an x86_64 AES-NI fast path via `@llvm.x86.aesni.*` intrinsics
   alongside `aes_ct.qz`." But the deployment target is the unikernel on
   qemu64 (no AES-NI by default — caught during NET.1 deploy with
   `feedback_unikernel_qemu_cpu_and_hacl_simd`). Adding `-cpu max` to the
   systemd unit exposes AES-NI. **Decision: ship pure-fixsliced v1.**
   AES-NI as NET.5g stretch.

3. **Self-signed cert provisioning.** For the `https://mattkelly.io/`
   endgame we need an Ed25519 cert in the unikernel's PEM-or-DER store.
   Three options: (a) bake a hardcoded self-signed cert at compile time
   (simplest; cert rotates by re-deploy); (b) generate at unikernel boot
   and write to a tmpfile (CA-style; needs persistence story we don't
   have); (c) ACME with Let's Encrypt (production-shape but Ed25519 isn't
   universally Web-PKI-supported by LE — last status check, EAB-only).
   **Decision: (a) for v1. ACME-Ed25519 filed as NET.7.** The `curl`
   demo runs `--cacert <our-cert>`; for "real" TLS in a browser, the
   cert is `--insecure`-only.

4. **HelloRetryRequest (HRR).** TLS 1.3's mechanism for asking the client
   to retry with a different named group. We DON'T support HRR v1 — if
   the server's first ServerHello can't accept the client's groups, we
   send `handshake_failure` alert. This is safe (no security loss) but
   means **the client MUST offer X25519MLKEM768 + X25519** for our server
   to talk to it. Document this; file HRR as v2. Client-side: we just
   handle a single SH branch.

5. **Cipher suite list.** RFC 8446 §B.4 lists five suites; v1 ships:
   - `TLS_AES_128_GCM_SHA256` (0x1301)
   - `TLS_AES_256_GCM_SHA384` (0x1302)
   - `TLS_CHACHA20_POLY1305_SHA256` (0x1303)
   - skip `TLS_AES_128_CCM_SHA256` (0x1304) — IoT-only, unused in HTTPS
   - skip `TLS_AES_128_CCM_8_SHA256` (0x1305) — same

6. **Where in `Secret<T>` does the AEAD key live?** RFC 8446 has 4 active
   secrets at handshake-end (c_hs_traffic_secret, s_hs_traffic_secret,
   c_ap_traffic_secret_0, s_ap_traffic_secret_0). Each is the input to
   HKDF-Expand-Label to derive (key, iv). Plan: keep the *_secret as
   `Secret<HsSecret>` / `Secret<AppSecret>`, derive (key, iv) per call
   from the secret. Avoids long-lived per-key-and-IV stores.

7. **ALPN.** Not load-bearing for the unikernel HTTP demo but is the
   normal way HTTP/2 negotiates. Plan: parse the client's ALPN extension,
   echo "http/1.1" in EE (Quartz's HTTP/1.1 is what's in tree). HTTP/2
   support is NET.8.

## Non-goals (NET.5 v1)

- **TLS 1.2 compatibility.** The compatibility-mode field
  `legacy_record_version = 0x0303` is sent (per RFC 8446 §5.1) but we
  reject any negotiation that downgrades to 1.2 with `protocol_version`
  alert.
- **0-RTT / early data.** RFC 8446 §4.2.10. Subtle replay-attack surface,
  not needed for `https://mattkelly.io/`. Filed as NET.6.
- **PSK resumption.** §4.2.11. Adds resumption_master_secret + ticket
  encryption. Not v1.
- **Client cert auth (mTLS).** v1 is server-auth only. mTLS adds
  CertificateRequest / Certificate(client) / CertificateVerify(client)
  flow; filed for NET.6 once needed.
- **HelloRetryRequest.** See OQ #4 above.
- **RSA-PSS / ECDSA / DSA signatures.** Ed25519-only sigs v1. RSA adds
  large-integer arithmetic (~3-4k LoC); ECDSA adds the secp256r1 substrate
  we don't have. Filed NET.6.
- **OCSP stapling / CRL.** Closed-world cert chain v1.
- **Post-handshake authentication / KeyUpdate.** §4.6.2 / §4.6.3. Filed
  NET.6.
- **Renegotiation.** TLS 1.3 doesn't have it. Already a non-issue.
- **DTLS / QUIC.** Out of scope; QUIC is NET.7's universe.
- **Session tickets.** §4.6.1. Not v1.
- **AES-NI fast path.** See OQ #2.
- **HTTP/2 / HTTP/3.** Application layer above; NET.8.
- **ACME / Let's Encrypt cert issuance.** OQ #3; NET.7.

## Validation gates (in increasing strictness)

1. **`crypto:aes-smoke`** — NIST CAVS AES-CTR + AES-GCM KAT. ~50 vectors.
2. **`crypto:aes-wycheproof`** — Wycheproof `aes_gcm_test.json` corpus.
3. **`dudect:smoke` add-entry** — ✅ SHIPPED 5a.3 2026-05-22. Four new
   entries against the leak-floor threshold (max|t| < 5.0): `aes_encrypt_block`
   AES-128 + AES-256 (key-class, keysched+encrypt in window), and
   `aes_gcm_encrypt` (256 B plaintext-class + key-class). All four green on
   three consecutive runs; widest variance was AES-256 key-class
   (0.76–3.43, still 1.5σ under threshold). Pre-existing entries unaffected;
   total smoke now 10/10 entries.
4. **`asn1:smoke`** — round-trip encode/decode of every DER tag we support;
   per-tag malformed-input rejection.
5. **`x509:smoke`** — parse a small corpus of real Ed25519 certs (we'll
   include both `letsencrypt-ed25519-staging` if available + a few
   self-issued); reject the 5–10 mangled-cert vectors from miTLS / liboqs.
6. **`tls:smoke`** — Quartz-client ↔ Quartz-server loopback; AEAD
   round-trip; key-schedule trace matches RFC 8446 Appendix A.1 / A.2.
7. **`tls:xargs-kat`** — byte-by-byte handshake against tls13.xargs.org's
   reference. Every byte sent / received must match.
8. **`tls:interop`** — `curl --tlsv1.3` (BoringSSL) against Quartz server;
   Quartz client against `openssl s_server -tls1_3`; Quartz client against
   Go `crypto/tls` server with `X25519MLKEM768` enabled. Three matrix
   cells; all must succeed.
9. **`tls:deploy`** — production deploy to `mattkelly.io`. `curl
   --cacert <our-cert> https://mattkelly.io/` returns the unikernel's HTTP
   response over a Quartz-authored TLS pipe.

Gates 1–6 are CI-runnable from `quake`. 7–8 require external tools and
land in `tools/test-tls/` shell scripts that invoke `curl` / `openssl` /
`go run`. Gate 9 is a manual deploy verification matching NET.1's pattern.

## Threat model assumed for v1

NET.5 v1's threat model matches RFC 8446 §G:

- **In scope:** confidentiality, integrity, forward secrecy of records;
  protection against passive on-path adversaries; protection against
  active adversaries (downgrade, MITM with bad cert); CT discipline on
  the key-schedule hot path.
- **Out of scope:** traffic analysis, timing side-channels in record
  framing (only the AEAD-key-derivation hot path is `Secret<T>`/`@ct`-
  gated); RSA / ECDSA cert validation; revocation; cross-protocol attacks
  (ALPACA — we ALPN-strict-match and abort on mismatch); QUIC-style
  amplification; resumption replay (no resumption v1).

The post-quantum side: `X25519MLKEM768` per draft-04 — even an adversary
recording today's handshakes who later builds a CRQC can't recover the
session key without breaking both X25519 (now) AND ML-KEM-768 (after
CRQC). This is the "harvest now decrypt later" defense.

## References

- **Spec:** Rescorla. *The Transport Layer Security (TLS) Protocol Version 1.3.* RFC 8446 (2018). https://datatracker.ietf.org/doc/html/rfc8446
- **PQ hybrid:** Kwiatkowski, Stebila, Westerbaan. *Post-quantum hybrid ECDHE-MLKEM Key Agreement for TLSv1.3.* draft-ietf-tls-ecdhe-mlkem-04 (2026). https://datatracker.ietf.org/doc/draft-ietf-tls-ecdhe-mlkem/
- **Production deployments:** Filippo. *Go 1.24 X25519MLKEM768 enabled by default.* https://go.dev/src/crypto/tls/defaults.go ; Cloudflare. *X25519MLKEM768 default for Cloudflare-fronted sites.* Q4 2024 announcement. https://blog.cloudflare.com/pq-2024/ ; AWS. *ML-KEM post-quantum TLS now supported in AWS KMS, ACM, and Secrets Manager.* 2025. https://aws.amazon.com/blogs/security/ml-kem-post-quantum-tls-now-supported-in-aws-kms-acm-and-secrets-manager/
- **Wire reference:** Driscoll. *The Illustrated TLS 1.3 Connection.* https://tls13.xargs.org/
- **State machine pattern:** rustls issue #461 — explicit-state machine refactor discussion. https://github.com/rustls/rustls/issues/461
- **Minimal TLS 1.3:** h2o/picotls. https://github.com/h2o/picotls
- **AES-CT reference:** Pornin. *BearSSL `aes_ct64`.* https://www.bearssl.org/gitweb/?p=BearSSL;a=blob;f=src/symcipher/aes_ct64.c
- **Fixsliced AES:** Adomnicai, Peyrin. *Fixslicing AES-like Ciphers.* CHES 2020. https://eprint.iacr.org/2020/1123
- **AES-GCM CT:** Käsper, Schwabe. *Faster and Timing-Attack Resistant AES-GCM.* CHES 2009. https://cryptojedi.org/papers/aesbs-20090616.pdf
- **X.509 minimal reference:** rustls-webpki. https://github.com/rustls/webpki
- **Verified TLS reference:** miTLS / Project Everest. https://project-everest.github.io/record/
- **Quartz prior memos:**
  - `docs/design/CRYPTO_STDLIB_DESIGN.md` — NET.1 substrate
  - `docs/design/ED25519_DESIGN.md` — NET.2 signing
  - `docs/design/MLKEM_DESIGN.md` — NET.3 KEM + hybrid combiner
  - `docs/design/SECRET_T_AND_DUDECT_DESIGN.md` — NET.4 `Secret<T>` + dudect + Layer 3 `@ct`

## Decision log

- **2026-05-22** — **5c.3 SHIPPED — NET.5c CLOSED.** Pure-Quartz TLS 1.3
  HKDF-Expand-Label ladder (RFC 8446 §7.1) + Derive-Secret + per-direction
  derive_keys + finished_key derivation. New file `std/net/tls13/key_schedule.qz`
  (~240 LoC); spec `spec/qz/tls_key_schedule_smoke.qz` (~340 LoC, 16
  KAT checks); Quakefile task `tls_key_schedule:smoke`. Stdlib-only diff;
  zero compiler-source change.

  **Surface**:
  - `ks_hash_for_suite(cs)` / `ks_hash_size(cs)` / `ks_key_size(cs)` /
    `ks_iv_size()` — cipher-suite ↔ hash + key-len dispatch.
  - `hkdf_expand_label(hash_id, out, secret, label, context, ctx_len, len)` —
    HkdfLabel struct encoding (`uint16 length || opaque label<7..255>="tls13 "+Label
    || opaque context<0..255>=Context`) wrapped around the existing
    HKDF-Expand. Auto-prepends "tls13 " to the caller's Label.
  - `derive_secret(out, secret, label, t: Transcript)` — convenience wrapper
    that internally calls `transcript_digest` (snapshot-clone, doesn't
    consume) then `hkdf_expand_label` with the digest as Context and
    Hash.length as len.
  - `derive_secret_with_hash(hash_id, out, secret, label, transcript_hash)` —
    same but with pre-computed Transcript-Hash bytes.
  - `ks_extract_early(hash_id, out)` — HKDF-Extract(0, 0) — early secret for
    the no-PSK v1 path.
  - `ks_extract_handshake(hash_id, out, early, dhe_shared, dhe_len)` —
    HKDF-Extract(Derive-Secret(early, "derived", ""), DHE).
  - `ks_extract_master(hash_id, out, handshake)` —
    HKDF-Extract(Derive-Secret(handshake, "derived", ""), 0).
  - `ks_derive_keys(cs, traffic_secret) -> TrafficKeys` — runs
    `HKDF-Expand-Label(ts, "key", "", key_len)` + `HKDF-Expand-Label(ts, "iv",
    "", 12)` and returns a fresh TrafficKeys (seq=0).
  - `ks_derive_finished_key(hash_id, out, traffic_secret)` —
    `HKDF-Expand-Label(ts, "finished", "", Hash.length)`; caller does the
    HMAC over the transcript-hash themselves to produce verify_data.

  **Six labeled derive_secret ladder** (state machine drives these):
  - "c hs traffic" / "s hs traffic" — handshake-phase traffic secrets,
    context = Transcript-Hash(ClientHello..ServerHello)
  - "c ap traffic" / "s ap traffic" — application-phase traffic secrets,
    context = Transcript-Hash(ClientHello..server.Finished)
  - "exp master" — exporter master secret, same context as app traffic
  - "res master" — resumption master secret, context = Transcript-Hash(
    ClientHello..client.Finished)

  All six are reduced to one `derive_secret(out, base_secret, label, t)`
  call from the state machine perspective; the difference between them
  is purely the (base_secret, label, transcript-state) triple.

  **Validation**: `tls_key_schedule:smoke` 16/16 green covering:
  - RFC 8448 §3 byte-for-byte KAT vectors over SHA-256:
    - `early_secret = HKDF-Extract(0, 0)` = `33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a`
    - `SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
    - `Derive-Secret(early, "derived", "")` = `6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba`
  - `derive_secret(.., "derived", t)` matches `hkdf_expand_label(.., "derived",
    Transcript-Hash(t), 32)` directly (proves the convenience wrapper +
    snapshot path).
  - SHA-384 early_secret independent KAT (`7ee8206f5570023e6dc7519eb1073bc4e791ad37b5c382aa10ba18e2357e716971f9362f2c2fe2a76bfd78dfec4ea9b5`).
  - Cipher-suite dispatch: `ks_hash_size(AES-256-GCM)` = 48,
    `ks_hash_size(AES-128-GCM)` = 32, `ks_hash_size(ChaCha20)` = 32.
  - `ks_derive_keys` returns correct `key_len` per suite (16/32/32) +
    `seq` initialised to 0 + deterministic across two calls with same
    traffic_secret.
  - Finished-key + HMAC round-trip: tampering finished_key produces
    differing verify_data; same key + same transcript_hash produce
    deterministic verify_data.

  Sibling regression: `tls_record:smoke` 52/52 + `tls_handshake:smoke`
  103/103 + `sha2:smoke` 23/23 + `ed25519:smoke` 29/29 green.

  **Quartz-specific gotcha caught + fixed during bring-up** (filed for
  future similar work): `match` is a reserved keyword (used for the
  `match expr ... end` pattern-matching construct). Using it as a
  variable name (`var match = 1` for a loop boolean) produces
  20+ cascading parse errors starting with `Expected pattern` /
  `Expected '=>'` at the `;` after the var-decl. Rename to `matches`
  (or any non-keyword identifier) is a one-line fix. The error message
  could be improved upstream (suggest "did you mean to use a different
  identifier? `match` is reserved") — filed as a one-liner DX
  improvement; not a separate bug doc since the fix at use-site is
  obvious once known.

  **Calibration**: phasing budget 0.3 qd; actual ~0.3 qd. Substrate
  accumulation paid off again — the entire key schedule was a thin
  layer over the NET.5c.0 SHA-2/HKDF primitives + the Transcript
  helpers from 5c.2.

  **NET.5c CLOSED** — all four sub-phases (5c.0 SHA-2 substrate + 5c.1
  handshake codec + 5c.2 record + transcript + 5c.3 key schedule)
  shipped. Total: 1.6 qd actual vs 1.6 qd budget (5c.0 discovered scope
  +0.5 qd, but other phases all came in 0.1-0.2 qd under). Substrate
  is now complete for NET.5d (client + server state machines, 1.4 qd
  estimate).

- **2026-05-22** — **5c.2 SHIPPED.** Pure-Quartz TLS 1.3 record layer +
  incremental transcript hash. New file `std/net/tls13/record.qz`
  (~370 LoC including doc header — Transcript struct + transcript_*
  helpers + TrafficKeys struct + record_seal / record_open +
  cipher-suite AEAD dispatch + nonce-IV XOR construction); spec
  `spec/qz/tls_record_smoke.qz` (~430 LoC, 52 KAT checks);
  Quakefile task `tls_record:smoke`. Stdlib-only diff; zero compiler-
  source change. 52/52 green on first run.

  **Transcript hash** (memo-mandated folded into record.qz). Unified
  `Transcript { hash_id, ctx }` over SHA-256 or SHA-384 — the
  `hash_id` discriminator dispatches `transcript_update` /
  `transcript_digest` to the corresponding `sha256_*` / `sha384_*` API.
  Critical lifetime constraint: `sha256_finalize` / `sha384_finalize`
  FREE the underlying ctx (no finalize-without-free variant exists
  upstream). Since the key schedule (NET.5c.3) needs `Transcript-Hash(...)`
  snapshots at multiple HKDF-Expand-Label callsites WITHOUT consuming
  the running hash, `transcript_digest` internally `memcpy`s the ctx
  (112 bytes SHA-256, 208 bytes SHA-384/512) and finalizes the clone.
  The live ctx stays usable for more `transcript_update` calls.
  `transcript_clone` produces an independent transcript; `transcript_free`
  releases the live ctx without finalizing.

  **Record layer** (RFC 8446 §5.2). Wire format = `{ ContentType
  opaque_type=0x17 | ProtocolVersion legacy_record_version=0x0303 |
  uint16 length | encrypted_record payload }`. `encrypted_record` =
  AEAD-Seal(key, nonce, AAD, TLSInnerPlaintext). `TLSInnerPlaintext`
  = `content || real_content_type byte`; v1 emits zero padding bytes
  (AEAD already hides plaintext byte values — padding is a perf knob,
  not a security control). AAD = the 5-byte record header itself.
  Nonce = `static_iv XOR (seq big-endian padded to 12 bytes)` per
  RFC 8446 §5.3. AEAD dispatch via the `cipher_suite` tag on
  `TrafficKeys`: AES-128-GCM-SHA256 (key_len=16), AES-256-GCM-SHA384
  (key_len=32), ChaCha20-Poly1305-SHA256 (key_len=32). The underlying
  AEAD primitives (`aes_gcm_encrypt/decrypt`, `chacha20poly1305_encrypt/decrypt`)
  are NET.1 + NET.5a.2 shipping — no new AEAD code here.

  **One decoder-side ergonomic** worth flagging: `record_open` returns
  the recovered plaintext via two 8-byte LE pointer-writes (one for
  `out_buf` pointer, one for `len`) plus a single byte for the
  recovered `content_type`. The shape is "pass three address-of slots,
  parser writes them" — same pattern as `hs_decode_header`'s
  `body_len_out` (NET.5c.1). Quartz lacks a clean tuple-return idiom,
  and the `Result<T, E>` enum would require allocating two values
  per call. The pointer-write API is honest about the multi-output
  shape without paying allocation per record. Filed as a future
  cleanup: could wrap in a `RecordOpenResult` struct once codegen's
  cross-module struct return story is rock-solid.

  **Validation**: `tls_record:smoke` 52/52 green covering:
  - Transcript SHA-256: 3-update incremental matches one-shot
    SHA-256(m1||m2||m3); `transcript_digest` snapshot does NOT
    consume the running hash (subsequent update + digest matches
    longer concatenation); `transcript_clone` produces an
    independent transcript (mutating clone leaves original
    unchanged + vice versa).
  - Transcript SHA-384: same shape; `transcript_digest_size`
    returns 32 (SHA-256) and 48 (SHA-384) correctly.
  - Per-suite round-trip (AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305):
    seal then open returns identical plaintext + correct content_type;
    wire header bytes byte-exact (`opaque_type=0x17`, version=0x0303,
    length=plaintext+1+16); sequence counter increments on both
    seal and open.
  - Sequence counter: two consecutive seals on identical plaintext
    produce identical wire headers but DIFFERENT ciphertext+tag
    (proves the nonce changed across records).
  - Tamper rejection: ciphertext bit-flip rejects with `RECORD_ERR_BAD_TAG`,
    tag bit-flip rejects, AAD bit-flip rejects; after restoring all
    tampered bytes, open succeeds and recovers original plaintext.
  - Nonce-IV XOR construction: two independent `TrafficKeys` with
    seq=0 produce byte-identical ciphertext on the same plaintext.
  - Max plaintext boundary: 16384-byte plaintext accepted, 16385
    rejected with `RECORD_ERR_TOO_LARGE`.
  Sibling regression: `sha2:smoke` 23/23 + `tls_handshake:smoke`
  103/103 + `ed25519:smoke` 29/29 green.

  **Calibration**: phasing budget 0.5 qd; actual ~0.4 qd. Substrate
  accumulation (sha256/384 + hmac + AEAD primitives + CodecWriter
  from 5c.1 + standard smoke pipeline) put shipping work ~20% under
  budget. Pattern continues — NET.5 phases shipping at roughly
  budget-or-better.

  Unblocks NET.5c.3 (key schedule uses `Transcript` + populates
  `TrafficKeys` via HKDF-Expand-Label).

- **2026-05-22** — **5c.0 SHIPPED.** SHA-256/384 + HMAC + HKDF over
  SHA-2 substrate. **Discovered scope**: memo §"Substrate availability
  table" claimed SHA-256 was "implicit in HKDF / NET.2 ARX shape" and
  HKDF-SHA was inherited from NET.1, but neither was in tree — NET.1
  shipped HKDF-BLAKE2s only (WireGuard's Noise needs that variant);
  NET.2 shipped SHA-512 but not SHA-256. TLS 1.3 binds SHA-256 (and
  HKDF-SHA-256) into TLS_AES_128_GCM_SHA256 + TLS_CHACHA20_POLY1305_SHA256,
  and SHA-384 + HKDF-SHA-384 into TLS_AES_256_GCM_SHA384. Filed the
  hole + filled it before 5c.2 starts.

  New files:
    `std/core/crypto/sha256.qz` (~330 LoC) — FIPS 180-4 §6.2 with u32
       ARX over LE-stored chain state (mirrors sha512.qz layout, smaller
       words, 64 rounds, 64-bit length field, 64-byte block).
    `std/core/crypto/sha384.qz` (~95 LoC) — thin wrapper: `sha384_new`
       calls `sha512_new` then overwrites the 8-u64 chain state with
       SHA-384's IVs (FIPS 180-4 §5.3.4) byte-by-byte; `sha384_update`
       delegates to `sha512_update`; `sha384_finalize` calls
       `sha512_finalize` into a 64-byte scratch then `memcpy`s the
       leftmost 48 to the caller's output.
    `std/core/crypto/hmac.qz` (~115 LoC) — RFC 2104 inner/outer
       ipad=0x36, opad=0x5c shape; specialized for SHA-256 and SHA-384
       (no function-pointer indirection since Quartz idiom prefers
       explicit specializations).
    `std/core/crypto/hkdf.qz` extended with `hkdf_extract_sha256`,
       `hkdf_expand_sha256`, `hkdf_extract_sha384`, `hkdf_expand_sha384`
       (RFC 5869) — same `Secret<T>` PRK discipline as the existing
       BLAKE2s variants.
    `spec/qz/sha2_smoke.qz` (~330 LoC, 23 KAT checks).
    `Quakefile.qz` — new task `sha2:smoke`.

  **Real bug caught + worked around** (filed forward as
  `docs/bugs/IMPORT_STAR_COLLISION_SILENT_SHADOW.md`):
  the first draft of sha256.qz used the same internal helper names as
  sha512.qz (`_compress`, `_K`, `_Ch`, `_Maj`, `_BigSigma0`,
  `_BigSigma1`, `_SmallSigma0`, `_SmallSigma1`, `_IV_0`..`_IV_7`).
  When sha2_smoke imported both `std/core/crypto/sha256` and
  `std/core/crypto/sha384` (which transitively imports `sha512`),
  the resolver's `import *` shadow rule silently picked one body —
  the u64 SHA-512 bodies for everything. `sha256("")` then returned
  `0x8b...` instead of `0xe3...`, with no diagnostic at parse,
  typecheck, or codegen. Diagnosed by minimal-test bisection (single-
  import sha256 works; dual-import breaks). **Fix at source**: rename
  all sha256 internal helpers to `_sha256_*` prefix. The compiler-
  level fix (AMBIGUOUS_IMPORT diagnostic) is filed in the bug doc
  with a ~30 LoC resolver-side patch sketch + a suggested audit
  pass to find any existing silent shadows in stdlib.

  This is the SAME class of bug as the NET.5a.2 SWAR-mask collision
  case (aes_gcm.qz redefining aes.qz helpers — that one surfaced as
  a post-`opt` "use of undefined value" because DCE removed the
  shadowed copy; the SHA-256 case is strictly worse because both
  bodies are reachable, so DCE doesn't reveal the collision — the
  program just silently miscomputes). Both share root cause: the
  resolver should diagnose ambiguous-import-via-`*` rather than
  picking one body and hiding the issue.

  **Validation**: `sha2:smoke` 23/23 green covering FIPS 180-2 §D.1
  + §D.3 SHA-256/384 KAT (empty / "abc" / multi-block including a
  56-byte 2-block forcing case for SHA-256 and a 112-byte case for
  SHA-384), SHA-256 streaming = one-shot equivalence (3 single-byte
  updates of "abc" = one-shot of "abc"), RFC 4231 §4 HMAC-SHA-256
  TC1-4 (covering key < block_size + key > block_size paths) +
  HMAC-SHA-384 TC1-3 + RFC 5869 §A.1 HKDF-SHA-256 TC1-3 (basic /
  long input/output / empty salt+info), HKDF-SHA-384 substrate
  consistency vs direct HMAC for both N=1 and N=2 expand cases.
  Sibling regression: `tls_handshake:smoke` 103/103 + `ed25519:smoke`
  29/29 green.

  **Calibration**: filed as discovered scope so no original ROADMAP
  estimate. Actual ~0.5 qd (single session: design + SHA-256 from
  scratch + SHA-384 wrapper + HMAC + HKDF appends + smoke + collision
  bug diagnosis + workaround + bug doc + Quakefile + memo). The
  collision-debug ate ~0.1 qd (build a dual-import minimal repro,
  isolate to resolver shadow rule, file forward). Pure ARX-substrate
  work (NET.2's SHA-512 was the template) ran fast.

  Unblocks 5c.2 (transcript hash uses SHA-256/384 via streaming API)
  and 5c.3 (HKDF-Expand-Label uses HKDF-SHA-256/384).

- **2026-05-22** — **5c.1 SHIPPED.** Pure-Quartz TLS 1.3 handshake
  message wire codec. Two new files: `std/net/tls13/handshake.qz`
  (~890 LoC including doc header — codec primitives + extension wire
  format + 6 handshake message encoders + 6 decoders) and
  `std/net/tls13/alert.qz` (~75 LoC — RFC 8446 §6 alert codes +
  encode/decode + `alert_is_fatal` predicate). Spec
  `spec/qz/tls_handshake_smoke.qz` (~430 LoC, 103 KAT checks);
  Quakefile task `tls_handshake:smoke` mirroring the `x509:smoke`
  pipeline. Stdlib-only diff; zero compiler-source change.

  **Codec primitives** mirror BoringSSL CBB (Crypto Byte Builder) +
  rustls codec patterns: `CodecWriter` with grow-on-demand backing
  storage + `CodecReader` with sticky-error pattern (same shape as
  `DerReader` from `asn1.qz`). Big-endian u8/u16/u24/u32 + open/close
  length backfill for u8/u16/u24-prefixed vectors. Reader has matching
  open/close that returns a child spanning the value bytes, parent
  advances past the entire vector. `cr_close` verifies fully-consumed
  + propagates child error to parent.

  **Wire shapes covered** (encode + decode, RFC 8446 §4):
  ClientHello (legacy_version + random + session_id + cipher_suites +
  null compression_method + extensions), ServerHello (mirror with
  single cipher_suite + single key_share), EncryptedExtensions
  (ALPN-only for v1), Certificate (request_context + entry list with
  per-entry u24 cert_data + empty per-entry Extensions), CertificateVerify
  ({algorithm, sig<0..2^16-1>}), Finished (raw verify_data of negotiated
  hash length). Extensions: server_name (SNI), supported_versions
  (CH list + SH single), supported_groups, signature_algorithms,
  key_share (CH list + SH single), ALPN.

  **Decoder convention**: every per-message decoder takes the FULL
  handshake message bytes (including the 4-byte `u8 type + u24 length`
  header) so the resulting struct's `raw_ptr`/`raw_len` are exactly
  the bytes the transcript hash needs to consume (NET.5c.2). Decoders
  borrow value spans into the input buffer (`val_ptr` style) for
  every variable-length field except the 32-byte `random` on
  CH+SH — those are allocated copies because they outlive the
  ClientHello-fed-then-freed input buffer used during the handshake.
  `ch_msg_free` / `sh_msg_free` release the random copy.

  **Three design calls diverged from §"Architecture" prose** (recorded
  here):
  1. The codec doesn't ship Result-style structured returns — sticky
     `err` on the reader struct mirrors `DerReader` exactly. The
     state machine (NET.5d) reads err once per receive step and
     transitions to a Fail state.
  2. ClientHello's `legacy_compression_methods<1..2^8-1>` is parsed
     as "first byte must be 0x00, rest skipped" rather than the
     strict "exactly [0]" RFC 8446 §4.1.2 reading. The strict reading
     is correct; the looser reading still rejects any non-zero
     compression which is the security-relevant check. Tightening
     filed as a one-liner follow-up.
  3. EncryptedExtensions decoder extracts ONLY ALPN for v1. The
     server_name echo (RFC 8446 §4.2.11 — server-side allowed
     omission) is intentionally elided on both encode and decode.
     Clients generally don't care; if a future use case needs it,
     extend the EE struct + add a one-arm encode/decode.

  **Validation**: `tls_handshake:smoke` 103/103 green covering wire
  primitives (BE byte order for u8/u16/u24/u32, length open/close
  with prefix bytes and child reader semantics), ClientHello full
  field round-trip (msg type + legacy_version 0x0303 + random
  byte-identical + session_id + cipher_suites count + values
  byte-identical to IANA, supported_versions = [0x0304],
  supported_groups, sig_algs, key_share with X25519 pubkey
  byte-identical, SNI hostname, ALPN), ServerHello mirror, EE with
  ALPN selection + empty-ALPN case, Certificate with 1 and 3 entries
  (each entry's data byte-identical), CertificateVerify, Finished,
  Alert (level + description + is_fatal incl. close_notify-always-
  fatal + warning-user-canceled-not-fatal edge cases), RFC-cited
  constant sanity (cipher suite IDs, named groups including
  X25519MLKEM768=0x11EC, sig schemes, extension types, version
  numbers all byte-identical to IANA registries). `x509:smoke` 43/43
  green (sibling regression). **Calibration**: phasing budget 0.5 qd;
  actual ~0.4 qd (single session: design + handshake.qz + alert.qz +
  comprehensive smoke + Quakefile + memo). Substrate accumulation
  (asn1.qz's sticky-err pattern, Vec<T>, str_from_ptr, smoke pipeline)
  continues compounding effect.

- **2026-05-22** — **Module-layout drift, recorded.** asn1.qz + x509.qz
  shipped at `std/core/crypto/asn1.qz` + `std/core/crypto/x509.qz`,
  NOT at `std/net/tls/{asn1,x509}.qz` as the memo's §"Module layout"
  diagram had them. **Rationale**: neither file is TLS-specific —
  asn1.qz is a general DER decoder useful for PGP / code signing /
  ACME / CRL / OCSP / any future X.509 consumer, and x509.qz is
  similarly general (any RFC 5280 v3 cert consumer can use it). They
  sit alongside sibling crypto-stdlib primitives (`secret.qz`,
  `subtle.qz`, `sha512.qz`, `ed25519.qz`, …) in `std/core/crypto/`,
  which is their natural home. The TLS-specific files (`handshake.qz`,
  `record.qz`, `key_schedule.qz`, `client.qz`, `server.qz`,
  `alert.qz`) land in `std/net/tls13/` — the `tls13` prefix avoids
  collision with the still-live OpenSSL-FFI shim at `std/net/tls.qz`
  (load-bearing for `std/net/http.qz` + `std/net/http_server.qz` +
  5 spec files; we can't D7-delete it until NET.5f deploys and
  migrates http_server). When NET.5f ships, the OpenSSL shim retires
  and the `tls13` directory can be renamed to `tls` cleanly. Layout
  diagram above updated to reflect ship reality.

- **2026-05-22** — **5b.2 SHIPPED.** Pure-Quartz X.509 v3 parser + Ed25519
  chain verifier. New file `std/core/crypto/x509.qz` (~570 LoC); spec
  `spec/qz/x509_smoke.qz` (~580 LoC, 43 KAT checks); Quakefile task
  `x509:smoke` mirroring the `asn1:smoke` pipeline. Stdlib-only diff;
  zero compiler-source change. **Closes NET.5b** (the entire X.509
  substrate phase); next is 5c (TLS wire + record + key schedule).

  **Cert struct contract**: every `_ptr` field borrows from the original
  `der_buf`. The parser allocates ZERO bytes for the cert data itself —
  spans into the DER blob are stored as raw `(ptr, len)` pairs. The
  `subject_cn` String and `san_dns` `Vec<String>` are separately
  allocated and outlive `der_buf` (they go through `str_from_ptr`).
  Lifetime rule documented at the function header: caller frees
  `der_buf` AFTER finishing with the Cert.

  **Verification flow** (`x509_verify_chain`): hostname match (RFC 6125
  SAN dNSName only — CN NOT consulted, matches modern browser
  practice); per-link: validity bounds (inclusive notBefore, exclusive
  notAfter per RFC 5280 §4.1.2.5), issuer lookup by byte-equal
  `subject_raw == issuer_raw` (covers every practically deployed cert
  — mirrors BoringSSL + rustls fast path), Ed25519 sig verify via
  `ed25519_verify(sig, tbs, tbs_len, signer_spki)`, CA bit + path-len
  enforcement on intermediates. Self-signed leaf supported via "leaf
  in root store" pattern (leaf appears in `roots`, `intermediates` is
  empty, chain has length 1).

  **Three decisions diverged from memo prose** (recorded for future
  audit):
  1. SAN-only hostname matching, CN not consulted. Memo's `subject_cn`
     field is still parsed and exposed (some test infra inspects it),
     but `x509_match_hostname` only walks `san_dns`. Certs without SAN
     are rejected outright. Mirrors Chrome / Firefox since the early
     2020s and RFC 6125 §6.4.4 deprecation guidance.
  2. Issuer matching by byte-equal raw Name bytes, not by parsed Name
     equality. Memo said "exact bytes of issuer Name (for chain
     matching)"; we honor it. Saves the work of normalizing DN
     comparisons (RFC 5280 §7.1's "name chaining" allows leniency, but
     no real-world chain exercises it — webpki's `name.rs` uses the
     same simplification).
  3. `BasicConstraints` enforced; `KeyUsage` / `ExtendedKeyUsage` NOT.
     Memo's "we check Basic Constraints CA bit + path length only" is
     honored exactly. The "no EKU" call matters: many production
     intermediates set `keyCertSign` + `cRLSign` in KeyUsage and EKU
     `serverAuth`/`clientAuth`; we ignore both. Acceptable for the v1
     server-cert-only path; NET.6 will add KU+EKU enforcement when
     mTLS lands.

  **Validation**: `x509:smoke` 43/43 green — self-signed parse with
  every Cert field assert (spki bytes byte-identical to derived pub,
  spki/sig algorithm flags, subject_cn, SAN list, is_ca, path_len,
  notBefore + notAfter unix-second values); self-sig verify round-trip
  + tamper-flip rejection + restore round-trip; validity bounds
  (inclusive notBefore, in-range, one-sec-before, exclusive notAfter,
  one-sec-past); hostname matching (exact, case-insensitive, subdomain
  reject, different host, empty, wildcard match, wildcard reject root,
  wildcard reject sub-sub, wildcard reject diff-TLD); 1-level chain
  (self-signed in root store, wrong-hostname-rejects, time-before-
  rejects); 2-level chain (separate root signs leaf, missing-root
  rejects with X509_ERR_CHAIN); negative parse (empty buffer, random
  garbage). `asn1:smoke` 78/78 + `ed25519:smoke` 29/29 green (sibling
  crypto unregressed). **Test approach**: built real Ed25519-signed
  certs in-test (not embedded KAT bytes) — ~250 LoC tiny in-test DER
  builder (`_emit_tlv`, `_sequence`, `_oid_*`, `_utf8_string`,
  `_utctime`, `_spki_ed25519`, `_build_tbs`, `_build_signed_cert`)
  composes the canonical X.509 v3 layout. Reason: end-to-end coverage
  through our own primitives matters more than "matches openssl byte-
  for-byte" at this phase; openssl-interop is NET.5e.3's job.

  **One in-test parser bug noticed during bring-up** (filed as fixed in
  the same patch, not a follow-up): the first draft of `_walk_name_for_cn`
  treated extension-trailing bytes from AttributeTypeAndValue as a
  parse error; the RFC allows arbitrary `value ANY DEFINED BY type`
  bytes after the OID, so we now skip whatever's left in the ATV with
  `der_skip_tlv` before `der_close`. No regression spec — the ATV
  shape is fully exercised by every cert the in-test builder emits.

  **Calibration**: phasing budget 0.7 qd; actual ~0.5 qd (single
  session: design + parser + chain verifier + in-test DER builder +
  smoke + Quakefile wiring + memo update). Substrate accumulation
  (asn1.qz + ed25519.qz + chacha20poly1305-shape `secret_wrap` idiom
  + `str_from_ptr` + `Vec<String>` + standard smoke pipeline) made the
  shipping work ~30% under budget. Mirrors the NET.2/NET.3 pattern of
  estimates getting tighter as the crypto-stdlib surface area grows.

- **2026-05-22** — **5b.1 SHIPPED.** Pure-Quartz DER decoder substrate for
  the X.509 path. New file `std/core/crypto/asn1.qz` (~660 LoC including
  the design-doc header — code only ~440 LoC); spec
  `spec/qz/asn1_smoke.qz` (~370 LoC, 78 KAT checks); Quakefile task
  `asn1:smoke` mirroring the `aes:smoke` pipeline. Stdlib-only diff; zero
  compiler-source change. Three architectural decisions diverged from the
  prose in §"X.509 / DER":
  1. **Error reporting via sticky return code, NOT `throw`.** The memo's
     `x509_parse(...): Cert  # throws on malformed` shape isn't yet
     idiomatic in `std/core/crypto/*` — the existing primitives
     (`aes_gcm_decrypt`, `chacha20poly1305_decrypt`, every key-schedule
     entry) all signal errors via `return 0 - 1` and never raise. The
     `DerReader` struct carries an `err` field; once non-zero it sticks,
     so every downstream parse helper short-circuits and the eventual
     caller checks once. Mirrors mbedTLS `mbedtls_asn1_*` exactly. The
     `throws` framing can be added later as a thin wrapper if the X.509
     diagnostic path needs to bubble across functions; for v1 the sticky
     err is enough.
  2. **`BIT STRING` adjusts `val_ptr`/`val_len` past the unused-bits
     prefix.** The memo didn't specify; I have `der_read_bit_string`
     write the unused-bits count to a caller-supplied `Int*` and shift
     the value span past byte 0, so callers see the payload bytes
     directly (matches the way SubjectPublicKey + sig are consumed). The
     unused-bits-out address is mandatory; if the caller doesn't care
     (every X.509-relevant BIT STRING has unused = 0), they pass a
     scratch byte ptr and ignore the result.
  3. **Time → unix seconds happens inside the reader, not later.** The
     memo modeled `not_before` / `not_after` as `U64` on the `Cert`
     struct without saying who does the YY/YYYYMMDDhhmmssZ → unix-sec
     conversion. Putting it in `der_read_utctime` / `der_read_generalized_time`
     keeps the X.509 layer free of date arithmetic. Uses Howard Hinnant's
     `days_from_civil` proleptic-Gregorian formula (public domain), so
     no libc `timegm` / `mktime` dependency — matters for the unikernel
     target where libc is absent.

  Validation: `asn1:smoke` 78/78 green covering tag + length forms
  (short / long-1 / long-2 / minimal-DER rejection / indefinite-length
  rejection / truncated value / tag mismatch); INTEGER (positive / zero
  / canonical-pad / non-canonical-pad reject / negative reject / u63 max
  / 9-byte overflow / pad+2^63 overflow / 16-byte span); BOOLEAN strict
  0x00/0xFF; NULL; OCTET STRING span; OID + `der_oid_equals`; BIT STRING
  with unused-bits prefix; SEQUENCE / SET / context-specific [0] open +
  close; sticky-err propagation; UTCTime + GeneralizedTime (including
  pre-epoch negative seconds + the 2049 boundary + format rejection).
  `aes:smoke` 13/13 + `style_demo` byte-identical (no regression in
  sibling crypto / hosted programs). **Calibration**: phasing budget
  0.3 qd; actual ~0.3 qd (single-session: design + module + smoke +
  bug-fix iteration on `der_read_integer_u64`'s pad-then-sign check +
  test-vector epoch correction + Quakefile wiring + memo update).
  **One real bug caught and fixed during the bring-up run**: the first
  draft of `der_read_integer_u64` did the sign check on the byte AFTER
  pad-strip, which rejects every canonically-padded high-bit-set value
  (`02 02 00 ff` → 255 was misparsed as "negative"). Fix moves the sign
  check to the ORIGINAL first byte BEFORE pad detection — the whole
  point of the canonical pad is to mark high-bit-set values as
  nevertheless positive, so the post-strip byte is allowed to have its
  high bit set. Filed in this memo (no separate bug doc — the asn1
  source code now documents the invariant inline).

- **2026-05-22** — Design memo filed. NET.4 closed same session; the
  CT-clean Ed25519 sigverify path + dudect-gated key schedule were the
  remaining substrate gaps. Phasing settled at 6.8 qd (~3 calendar days
  of focused work or ~5 spread across other commitments); v1 scope is
  TLS-1.3-only, server cert auth, Ed25519-only sigs, X25519MLKEM768 +
  X25519, no resumption/0-RTT/HRR/mTLS. Endgame =
  `curl https://mattkelly.io/` against the unikernel.

- **2026-05-22** — **5a.3 SHIPPED.** dudect coverage of the AES + AES-GCM
  surface, completing the NET.5a substrate phase. Four new entries added
  to `spec/qz/dudect_smoke.qz` (which is the same harness `quake
  dudect:smoke` runs — no new spec file, the closed-world list grows in
  place per the NET.4.2 convention): `aes_encrypt_block` AES-128
  key-class, `aes_encrypt_block` AES-256 key-class, `aes_gcm_encrypt`
  256 B plaintext-class, `aes_gcm_encrypt` 256 B key-class. All time the
  full keysched + encrypt path (or full AEAD) inside a single
  `time_mono_ns()` window, so a leak anywhere in `_aes_keysched_words`
  SubWord, the bitsliced sbox / mix-columns, GCTR XOR-with-keystream, or
  GHASH `_bmul64` / `_ghash_mul_inplace` would show up as a per-class
  timing skew. **Why the entry split**: the raw-block tests cover the
  cipher itself against secret key bits (the highest-stakes input — TLS
  uses one fixed key per connection and many records); the GCM
  plaintext-class entry covers attacker-controlled bytes through GCTR +
  GHASH; the GCM key-class entry covers the GHASH multiplier path
  separately, since H = AES_E(K, 0) is key-derived and `_bmul64` is the
  one place where the CT property leans on integer multiply being CT on
  the host CPU (LLVM emits IMUL/MADD — true on x86_64 + ARM64 since
  ~2010; the entry makes the contract explicit and would surface a
  regression if a future port targets a CPU where it isn't true).
  **Sample budget**: N=10000 per entry (matches the `_sc_reduce_64`
  budget; ~50ms wall per AES, ~300ms per GCM, total ~700ms added to
  smoke wall). **Validation**: `quake dudect:smoke` 10/10 green on three
  consecutive runs; max|t| across the four new entries: AES-128
  key-class 1.45→1.72, AES-256 key-class 0.76→3.43 (widest, expected
  for the heaviest single-call test), GCM plaintext-class 1.19→1.74,
  GCM key-class 1.12→1.49. All well under the 5.0 leak floor. Stdlib +
  spec + Quakefile only — zero compiler-source touched; no fixpoint
  change. **Calibration**: phasing budget 0.2 qd; actual ~0.2 qd
  (single-session: extend spec + run 3× + housekeeping + commit).

- **2026-05-22** — **5a.2 SHIPPED.** Pure-Quartz AES-GCM (AES-128 + AES-256)
  via constant-time scalar GHASH + CTR-mode keystream. New file
  `std/core/crypto/aes_gcm.qz` (~430 LoC); spec `spec/qz/aes_gcm_smoke.qz`
  (~320 LoC); Quakefile task `aes_gcm:smoke` mirroring the
  `aes:smoke`/`sha3:smoke` pipeline. Stdlib-only diff; zero compiler-source
  change. Validation: `quake aes_gcm:smoke` 40/40 — McGrew-Viega Test
  Cases 1-4 (AES-128) + 7-10 (AES-256) — the canonical NIST SP 800-38D
  Appendix B vectors that NIST CAVP, BoringSSL `aead_test`, Go
  `crypto/cipher/gcm_test.go`, and Project Wycheproof all share — plus
  AEAD tamper rejection across (tag, AAD, ciphertext) bit-flips, plus
  unsupported-key-length (24 = AES-192, 15, 0) API sanity. **GHASH design**:
  clean-room port of BearSSL `ghash_ctmul64` (Pornin, MIT) — `bmul64` does
  a 64-bit GF(2) polynomial multiply via the 4-way mask-and-integer-multiply
  trick (bits partitioned by mod-4 lane position; integer products of
  same-lane masked subwords give the polynomial bits for that lane via
  Hassan-Schwabe 2009); Karatsuba combines three subproducts for the
  low half, the bit-reversal identity `polymul_hi = rev64(bmul64(rev,
  rev)) >> 1` recovers the high half. CT iff integer multiply is CT —
  LLVM emits IMUL/MADD; CT on every production CPU since ~2010. **GCTR**:
  v1 ships one-block-per-`aes_encrypt_block` call (which internally
  zero-pads 3 of 4 bitsliced lanes — wastes 3/4 of the kernel). A 4-way
  batched CTR keystream that fills all four lanes is the obvious perf
  win and is filed forward as a NET.5a.2 follow-up; correctness-first
  for v1. **Memo deltas worth recording**: (1) `in` is a reserved keyword
  in Quartz, so the public encrypt/decrypt signatures use `input` /
  `input_len` (chacha20poly1305 convention); (2) re-defining the SWAR
  mask helpers (`_M55`, `_M0F`, `_M_1111`, …) locally collides with
  aes.qz's identical definitions and surfaces as a `use of undefined
  value` after internalize+DCE drops one of two same-content
  definitions — fix is to import them via `import * from .../aes`
  (aes.qz's helpers are conventionally-private but `*`-import exposes
  them); (3) the GHASH irreducible polynomial high bits (0xE1 …) ended
  up inlined via the 4-XOR shift cascade rather than as a named
  `_R_HI` constant — the constant was dead, removed (D7). **IV scope**:
  TLS-1.3-only 12-byte IV path (NIST SP 800-38D §8.2 deterministic
  profile / RFC 8446 §5.3). Non-12-byte IVs require a GHASH-based
  IV-to-J0 derivation (SP 800-38D §7.1 step 2.b) — filed forward as v2.
  **Calibration**: phasing budget 0.5 qd; actual ~0.5 qd including a
  TC2 tag-vector transcription error (`...bdb1` written, canonical is
  `...bddf` — caught by my own KAT against `python -c "from
  cryptography.hazmat... AESGCM"`) and a brief tour through the
  pre-existing qzmod stale-cache trap
  (`feedback_qzmod_artifact_location_and_stale_cache_trap`). All other
  crypto smokes green (`aes`, `crypto`, `ed25519`, `sha3`, `mlkem`,
  `hybrid`, `wg`, `dudect`) with clean cache. Guard PASS, fixpoint
  byte-identical, 2564 functions unchanged.

- **2026-05-22** — **5a.1 SHIPPED.** Pure-Quartz bitsliced CT-AES-128/256
  in `std/core/crypto/aes.qz` (~700 LoC), clean-room port of BearSSL
  `aes_ct64` (Pornin, MIT) per the prior-art table choice. Encrypt-only
  surface — decrypt explicitly skipped per D7 since TLS 1.3 cipher-
  suites only need AES via CTR-mode keystream (AES-GCM, NET.5a.2).
  Validation: `quake aes:smoke` 13/13 — FIPS 197 Appendix B + C
  (canonical NIST single-block) + NIST AESAVS ECBVar{Txt,Key}{128,256}
  COUNT=0 + API key-length rejection sanity. Stdlib-only diff; zero
  compiler-source change. **Memo-vs-impl divergence**: the design-memo
  pseudocode named the kernel `aes_ct_encrypt8` and claimed 8 parallel
  blocks; actual BearSSL `aes_ct64` is 4 parallel blocks per call
  (8 lanes × 64 bits = 512 bits = 4 × 128-bit blocks). The shipped
  internal API is `_aes_bitslice_encrypt` (no `4` or `8` in the name);
  the public surface is `aes_encrypt_block` (single block, 3 zero blocks
  filled). NET.5a.2's CTR-mode keystream path will batch 4 blocks
  natively to amortize the per-call setup. **Bug surfaced + filed-twice**:
  the known `MULTILINE_BINARY_OPERATOR_SILENTLY_DROPPED` parser bug
  (filed during NET.3a) silently dropped 6/7 OR-terms in `_aes_shift_rows`
  and 3/4 in `_aes_compress_skey`; the smoke output was
  high-entropy-then-low-nibble-garbage, took ~25 minutes to localise
  (full pipeline dumped at each stage against a BearSSL C oracle). Both
  sites now have explicit "NOTE: single-line per …MULTILINE…" comments.
  **Calibration**: phasing budget 0.5 qd; actual ~0.4 qd including the
  parser-bug rediscovery hour.
