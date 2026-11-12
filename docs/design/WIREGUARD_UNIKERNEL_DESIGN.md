# WireGuard on the Quartz Unikernel

**Status**: Design — pre-implementation. Consumer of [`CRYPTO_STDLIB_DESIGN.md`](CRYPTO_STDLIB_DESIGN.md).
**Scope**: Implement WireGuard (the protocol) in Quartz, in `std/net/wireguard/*`. Land it inside the unikernel at `mattkelly.io` so the demo is "the unikernel runs its own VPN, on its own crypto, on its own TCP/IP stack, in its own self-hosted language."
**Companion**: [`CRYPTO_STDLIB_DESIGN.md`](CRYPTO_STDLIB_DESIGN.md) — the language work this consumes.

## Why this is the right consumer

Three reasons:

1. **WireGuard is unusually small.** The whitepaper is ~12 pages. The protocol pins exactly four crypto primitives (ChaCha20Poly1305, BLAKE2s, Curve25519, HKDF) — no algorithm-agility. The handshake is a fixed Noise variant (IKpsk2). One UDP socket. Compare to TLS, where "implement TLS" means "implement a generation of negotiation, certificates, X.509, ASN.1, dozens of cipher suites, downgrade defenses." WireGuard's scope is the *intersection* of "real protocol" and "knowable in a single human's head."

2. **It exercises exactly the crypto stdlib gaps.** The four primitives WG needs are exactly the four `std/core/crypto/*` ships. The `subtle`-discipline + `zeroize` patterns get exercised in the handshake. The `@widening_mul` intrinsic gets exercised by the Phase-2-future Curve25519 reimplementation.

3. **The demo extends what's already live.** `mattkelly.io` is already served by the unikernel's own TCP/IP stack. WG sits beside HTTP — same UDP/IP layer (once UDP exists), separate port, separate state machine. The user can `wg set` a peer to the unikernel from a laptop and SSH into it, or proxy admin endpoints over WG. The unikernel demo at `mattkelly.io` gains a credible production feature without cannibalizing what's there.

## What WireGuard actually is (one paragraph for readers)

WireGuard is a Layer-3 VPN. Plaintext IP packets enter on a virtual `wg0` interface, get encrypted with ChaCha20-Poly1305 keyed by per-peer session keys, get encapsulated in UDP, get sent to the peer's endpoint. Reverse on receive. Session keys are negotiated by a Noise IKpsk2 handshake (ECDH over Curve25519 with optional pre-shared key); rekey every 2 minutes; sessions die after `REJECT_AFTER_TIME` (180 s). Stateless cookie-reply protects against DoS during handshake floods. No PKI; peers identify each other by raw Curve25519 public keys configured out-of-band. The whole protocol fits in ~4000 lines of Linux kernel C.

## What the unikernel needs

The unikernel today has Ethernet → IPv4 → TCP → HTTP/1.1, a 64-slot per-connection table, a 64-task cooperative scheduler, virtio-net, a PMM, and a LAPIC timer. What's missing for WG:

| Gap | Estimate | Notes |
|---|---|---|
| **UDP layer** in the unikernel IP stack | 1-2 days | Tiny — IPv4 is already there; UDP is a 8-byte header + checksum, no state. Bind a single socket on the WG port. |
| **Crypto stdlib** (Phase 1 of CRYPTO_STDLIB_DESIGN) | covered separately | ~8-9 days, owned by the crypto memo |
| **`std/net/wireguard/*`** — the protocol itself | 6-8 days | Noise IKpsk2 + transport + timers + peer table |
| **tun-equivalent** glue into the unikernel IP stack | 1-2 days | "Decrypted packet from peer X is delivered as if it arrived from a virtual NIC owned by the unikernel" |
| **Entropy source** for the unikernel | 1 day | RDRAND/RDSEED + an HKDF-BLAKE2s pool. Needed for ephemeral ECDH keys + handshake nonces. |
| **Interop testing** | 2 days | wg-quick + boringtun cross-impl tests on a Linux box |

**Phase 1 total: ~12-18 quartz-days = 2-3 quartz-weeks.** The crypto stdlib work is sequenced in parallel — the WG protocol layer can start as soon as the FFI shims (CRYPTO Step 1.2) land.

## Phase 1 sequencing

```
Day 1-2:    UDP layer in unikernel (CRYPTO Step 1.2 starts in parallel)
Day 3-4:    CRYPTO Steps 1.1-1.4 land — std/core/crypto/* + @widening_mul
Day 5:      CRYPTO Steps 1.5-1.7 — RNG + Noise + Wycheproof tests
Day 6-7:    std/net/wireguard/{peer,session,handshake}.qz — Noise IKpsk2 driver
Day 8-10:   std/net/wireguard/{transport,timers}.qz — encrypt/decrypt + state machines
Day 11-12:  std/net/wireguard/device.qz + tun-equivalent glue
Day 13-14:  Entropy source for the unikernel; wire to RNG
Day 15-16:  Interop tests against wg-quick + boringtun
Day 17-18:  Polish, docs, deploy to mattkelly.io
```

The critical-path dependency is CRYPTO Step 1.6 (Noise) → WG handshake driver. Everything else fans out.

## Noise IKpsk2 — the tricky part

WireGuard uses the Noise Protocol Framework's `Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s` pattern. We don't implement Noise generally; we implement *this one variant*. That keeps `std/crypto/noise.qz` to ~400 LoC instead of the ~2000 a full Noise library would need.

The pattern (annotated):

```
<- s          (peer's static public key — known a priori, not on the wire)
...
-> e, es, s, ss, psk    (initiator → responder: handshake initiation packet)
<- e, ee, se, psk       (responder → initiator: handshake response packet)
```

What that decodes to:

**Initiator sends `MSG_INITIATION` (148 bytes):**
1. Generate ephemeral keypair `(e_priv, e_pub)`.
2. `c, h := init_chaining(...)` — chaining key `c`, hash state `h` initialized from a constant string.
3. `h := MIX_HASH(h, e_pub)`.
4. `c, k := KDF2(c, DH(e_priv, peer_s_pub))` — derive new chaining key + symmetric key from the ECDH.
5. AEAD-encrypt initiator's static pubkey `s_pub` under `k`; mix into `h`.
6. `c, k := KDF2(c, DH(s_priv, peer_s_pub))`.
7. AEAD-encrypt timestamp under `k`; mix into `h`.
8. Append a MAC1 (BLAKE2s keyed by `MAC1_KEY || peer_s_pub` over the message so far) and MAC2 (cookie-based, zero in the no-cookie case).
9. Send.

**Responder receives, validates, sends `MSG_RESPONSE` (92 bytes):**
1. Recompute MAC1; reject mismatched.
2. Re-derive `c, h, k` by mirroring the initiator's steps using its own private keys.
3. AEAD-decrypt initiator's static pubkey; look up peer.
4. AEAD-decrypt timestamp; reject if older than last-known timestamp from this peer (replay defense).
5. Generate ephemeral keypair.
6. Mix in the four remaining DH operations (`ee`, `se`, plus PSK).
7. AEAD-encrypt empty payload under final `k`; mix into `h`.
8. Append MACs. Send.
9. `c, k_send, k_recv := KDF3(c)` — derive transport keys (we'll send under `k_send`, receive under `k_recv`).

**Initiator receives `MSG_RESPONSE`:** mirrors the responder's derivation, ends up with the same `(c, k_send, k_recv)` (with send/recv swapped). Both sides are now in transport mode.

**Implementation notes:**

- The Noise primitive `MIX_HASH(h, data) = h := BLAKE2s(h || data)` is a 1-line helper.
- `KDF{1,2,3}(key, input)` is HKDF-BLAKE2s expand to {1, 2, 3} 32-byte outputs.
- AEAD encrypt/decrypt is ChaCha20Poly1305 with a counter nonce derived from the chaining state.
- The 5-DH-operation handshake is fully constant-time only if the X25519 implementation underneath is. HACL\* is. Phase 2's pure-Quartz X25519 has to be (this is what the constant-time discipline is *for*).
- We pin `Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s` and don't expose Noise's pattern-string parser. If we ever need IKpsk1 or another pattern, we add it as a sibling driver, not as a generic interpreter. (Closes a class of pattern-confusion bugs that have hit production Noise libraries.)

## Transport packets

Once the handshake yields `(k_send, k_recv)`:

```
data packet on the wire:
  | type (1 byte = 4) | reserved (3 bytes) | receiver_index (4 bytes) |
  | counter (8 bytes) | encrypted_payload_with_tag (variable) |
```

- `receiver_index` is the per-session index the *receiver* assigned during handshake (lookup key into the peer/session table).
- `counter` is a per-direction monotonic counter, used as the ChaCha20Poly1305 nonce. Receiver maintains a sliding-window replay defense (RFC 6479 anti-replay window, 2048-bit window typical).
- Encrypted payload is the inner IP packet, padded to 16-byte multiple, then AEAD-encrypted.

`std/net/wireguard/transport.qz` is the encrypt-on-send / decrypt-on-receive + replay-window code. ~250 LoC.

## Timer state machine

Per session, four timers:

| Timer | Fires after | Action |
|---|---|---|
| **REKEY_AFTER_TIME** | 120 s after handshake completion (initiator only) | Initiate new handshake |
| **REKEY_AFTER_MESSAGES** | 2^60 messages or sooner | Initiate new handshake |
| **REJECT_AFTER_TIME** | 180 s after handshake completion | Drop session; refuse to encrypt/decrypt under it |
| **KEEPALIVE_TIMEOUT** | 10 s of no recv from peer (responder only) | Send a keepalive (zero-payload data packet) |

Plus per-handshake:
| Timer | Fires after | Action |
|---|---|---|
| **REKEY_TIMEOUT** | 5 s with no response to MSG_INITIATION | Resend MSG_INITIATION |
| **REKEY_ATTEMPT_TIME** | 90 s of failed rekey attempts | Give up; drop peer |

`std/net/wireguard/timers.qz` is the state-machine driver. Hooks into the unikernel's LAPIC tick (1-second granularity is plenty — WG timers are all multi-second). On userspace it would hook into a `tokio::time`-equivalent; we'll write it generic over a `Clock` trait so both work.

**This is a forcing function for `KERNEL_EPIC` Phase K.2 (timer subsystem).** The toy LAPIC tick the unikernel has today is enough for cooperative serve-loop pumping; WG needs proper "fire callback at deadline X" semantics. K.2's priority queue of `(wake_tick, task_id)` is exactly what we need. NET.1 either lands K.2 or motivates it.

## tun-equivalent: integrating with the unikernel IP stack

On Linux, WG runs as a kernel module that exposes a `wg0` interface; userspace IP routing decides what goes through it. The unikernel doesn't have userspace; it doesn't have a routing table; it has *one* IP layer that the HTTP server consumes. Two integration shapes:

**Option A — WG packets enter the existing IP stack.** Decrypted plaintext IP packet from peer X is delivered as if it arrived on a separate virtual NIC. The unikernel's IP layer handles it the same as a virtio-net frame. Outbound: a route-by-destination decision (e.g., "10.66.0.0/16 → wg, everything else → virtio-net") encrypts and sends out the WG socket.

**Option B — WG runs as an alternate listener entirely.** WG packets arrive, get decrypted, and the inner content is routed by callback to a WG-only handler (e.g., admin HTTP endpoint), never touching the main IP stack.

**Recommendation: Option A.** It's the WireGuard-on-Linux model and matches user expectations ("WG is just another network interface"). The route-decision code is ~30 LoC. Lets the user `ssh root@10.66.0.1` to the unikernel from a laptop on the WG network and have the SSH server (when it exists — KERN.future) bind to all interfaces transparently.

`std/net/wireguard/device.qz` owns the peer table + the `wg_send_packet(plaintext_ip_packet)` / `wg_receive_udp_packet(udp_payload)` entry points. The unikernel-specific glue is in `tools/baremetal/hello_x86.qz` (or wherever the IP-stack route table lives).

## Entropy source for the unikernel

WG needs randomness for ephemeral ECDH keys + handshake nonces. The unikernel has no `/dev/urandom`. Path:

1. **Hardware RNG.** `RDRAND` (Ivy Bridge+) and `RDSEED` (Broadwell+) are both cpuid-detectable x86 instructions. Wrap as Quartz intrinsics in `cg_intrinsic_arith.qz` (or sister file). Returns 64 bits per call.
2. **DRBG over HKDF-BLAKE2s.** Seed from RDSEED on boot (or RDRAND if RDSEED unavailable; log a warning). Pull-rate: HKDF-expand the seed for each consumer call, ratchet the seed forward periodically. Pattern is well-known; ~100 LoC in `std/crypto/rng.qz`.
3. **Failure mode.** No RDRAND/RDSEED → refuse to boot WG (better than booting with a constant key). The unikernel without WG still works for HTTP.

The Linux kernel uses `arch_get_random_seed_long` + `add_input_randomness` — same shape, much more elaborate pool. Ours is the minimum that's defensible for a single-machine VPN endpoint.

## Interop testing

WG interop is the acceptance test. Two cross-implementations:

1. **`wg-quick` from `wireguard-tools`** (the canonical Linux CLI). Set up a peer on a Linux box, configure the unikernel as the other end, exchange traffic. Validates handshake, transport, rekey, keepalive.
2. **`boringtun`** (Cloudflare's userspace WG in Rust). Different implementation, catches things the canonical implementation might paper over.

Test matrix:
- Unikernel as initiator vs responder (both)
- IPv4 transport (IPv6 deferred — unikernel doesn't have it yet)
- Idle (keepalive only)
- Bulk transfer (saturate the WG tunnel; validate transport correctness under load)
- Rekey (force by waiting 2 minutes or by messages-counter)
- Replay (replay an old packet; receiver should drop)
- Multiple peers (2-4 peers configured; routes by `receiver_index`)

Test driver: a Quake task `quake net1:wg_interop` that brings up a `netns`-isolated wg-quick instance, runs the unikernel under QEMU with WG configured, drives traffic, asserts on packet captures.

## Files to touch

**Stdlib (covered by CRYPTO_STDLIB_DESIGN.md Phase 1):**
- `std/core/crypto/{chacha20poly1305,blake2s,curve25519,hkdf,subtle,zeroize}.qz`
- `std/crypto/{noise,rng}.qz`

**Stdlib (this memo):**
- `std/net/wireguard/peer.qz` — `PeerKey`, `PSK`, endpoint, allowed-IPs
- `std/net/wireguard/session.qz` — active session keys + counters
- `std/net/wireguard/handshake.qz` — Noise IKpsk2 driver
- `std/net/wireguard/transport.qz` — encrypt/decrypt + replay window
- `std/net/wireguard/timers.qz` — rekey/keepalive/REJECT_AFTER state machines
- `std/net/wireguard/device.qz` — peer table + top-level send/receive entry points

**Unikernel (this memo):**
- `tools/baremetal/hello_x86.qz` — UDP layer, route table for "10.66/16 → wg", entropy source, RDRAND intrinsic wrappers
- `tools/baremetal/libc_stubs.c` — RDRAND/RDSEED stubs if they need C glue (probably they don't)

**Tests:**
- `spec/qspec/{wg_handshake,wg_transport,wg_replay_window}_spec.qz` — pure-Quartz unit tests
- `spec/qz/wg_interop.qz` — orchestrates the wg-quick / boringtun cross-impl tests
- Quake task `net1:wg_interop`

## Phase 2 (after Phase 1 ships) — optional improvements

- **Cookie reply handshake** for DoS resistance under load. Phase 1 ships without it (mattkelly.io isn't a high-value target). ~150 LoC + a cookie state machine; defer.
- **IPv6 support** when the unikernel grows IPv6 support generally. Independent track.
- **Multi-CPU tunnels** when SMP lands (KERN.8). One peer's session can pin to one CPU; multiple peers across CPUs gives ~linear scaling.
- **Userspace `std/net/wireguard/*` consumer demo** — a Linux-running Quartz program that does WG to the unikernel, proving the protocol code is platform-portable not unikernel-specific. Lightweight; ships any time after Phase 1.

## Risk register

| Risk | Mitigation |
|---|---|
| Noise IKpsk2 implementation has a subtle protocol bug | Vector-test against wg-quick + boringtun. The handshake is small enough to step through manually with known test vectors from the WG paper Appendix B. |
| Transport replay window has an off-by-one | RFC 6479 reference implementation is well-known; port pattern; test with deliberately-replayed packets |
| Crypto FFI shim leaks Quartz-side memory or copies secrets unnecessarily | `subtle` discipline + `zeroize` after use; explicit code review pass before deploy |
| RDRAND broken on the unikernel's actual VPS CPU | Verify on the production CPU before committing. Fall back to RDSEED. If neither, refuse to boot WG. |
| Phase 1 timeline blows up because Noise is harder than estimated | Sequence WG handshake driver *after* CRYPTO Step 1.6 — Noise as a stdlib primitive is the dependency we have to land first. If Noise takes longer, NET.1 stretches; doesn't compromise. |
| MirageOS-style "we found a side channel during deploy testing" | This is precisely why HACL\* underneath. Phase 2 reimplementations land when Wycheproof + dudect green; the demo is never blocked on a partial Quartz crypto rewrite. |

## Decision log

- **2026-05-08** — WireGuard chosen over alternative VPN protocols (OpenVPN, IPsec, etc.). Reason: smallest spec, fixed crypto, no algorithm-agility, exactly matches the crypto stdlib being built, fixed Noise variant fits in `~400 LoC`.
- **2026-05-08** — Noise IKpsk2 hardcoded; no generic Noise pattern parser. Reason: closes pattern-confusion bug class; reduces `std/crypto/noise.qz` to ~400 LoC instead of ~2000.
- **2026-05-08** — Option A (WG enters main IP stack) chosen for tun-equivalent. Reason: matches user expectations from Linux WG; lets the unikernel transparently expose services on the WG network.
- **2026-05-08** — Cookie reply DoS defense deferred to Phase 2. Reason: `mattkelly.io` isn't a high-value target; +150 LoC for a feature with no current threat model.
- **2026-05-08** — IPv6 deferred. Reason: unikernel doesn't have IPv6 generally; track separately.
- **2026-05-08** — Entropy from RDRAND/RDSEED + HKDF-BLAKE2s DRBG. Reason: simplest defensible design for single-machine endpoint; matches Linux's `arch_get_random_seed_long` shape.

## Out of scope

- **Quartz-native cookie-reply handshake** (DoS defense) — Phase 2.
- **WG configuration parsing** (`wg-quick` config file format) — out of scope for the demo. Hardcode peer keys in the unikernel boot config; user adjusts source + recompiles to add peers. (Acceptable for a demo; would be addressed if WG-on-the-unikernel ever became a real product.)
- **WG over IPv6 transport** — separate epic.
- **`wg show`-equivalent admin UI** — peer state is exposed via the existing `/api/stats.json` endpoint extended with `wg_peers`, `wg_handshakes`, etc. No separate UI binary.
- **Cross-OS WG userspace demo** — nice-to-have post-Phase-1; not a Phase 1 deliverable.
- **TLS termination inside the unikernel** — separate KERN.5 stretch goal.

## References

- WireGuard whitepaper — Donenfeld 2017 — `https://www.wireguard.com/papers/wireguard.pdf`
- Noise Protocol Framework spec — `https://noiseprotocol.org/noise.html`
- Noise IKpsk2 pattern — Section 7.5, "Interactive handshake patterns (fundamental)"
- RFC 6479 — IPsec Anti-Replay Algorithm without Bit Shifting
- WireGuard reference implementation (Linux kernel) — `drivers/net/wireguard/` in upstream Linux
- boringtun — `https://github.com/cloudflare/boringtun`
- mirage-crypto — `https://github.com/mirage/mirage-crypto` (closest unikernel WG precedent)
- [`CRYPTO_STDLIB_DESIGN.md`](CRYPTO_STDLIB_DESIGN.md) — the language work this consumes
- [`../KERNEL_EPIC.md`](../KERNEL_EPIC.md) — parent epic structure
