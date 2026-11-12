# Unikernel TX stalls at exactly 209 KB (Apr 19 2026)

**Severity:** HIGH (large static assets can't be served)
**Status:** CLOSED Apr 20 2026 by `95b8e777` — TCP window tracking +
retransmits now honor the peer's advertised receive buffer and replay
any segments lost to the Linux rmem squeeze. `tools/bake_assets.qz`
tx_ceiling removed in the same commit; all 265 site/dist assets are
now baked into `site_assets.qz` (6.8 MB). Local QEMU smoke test
confirms byte-exact delivery of the 420 KB
`/docs/archive/roadmap-v5260` doc (3/3 fetches, SHA-256 match). The
true fix validation is the VPS — production repro used to stall
deterministically at 209 160 bytes; with window gating we now pause at
the zero-window ACK, wait for curl to drain the socket buffer, and
resume.
**Workaround (historical):** bake_assets.qz filtered responses >
200 KB. Removed in `95b8e777`.

## Repro

```
$ curl -sS -m 30 http://195.35.36.247:8080/docs/quartz_reference -o /tmp/out
curl: (28) Operation timed out after 30002 milliseconds with 209160
      out of 228126 bytes received
```

Always stalls at exactly 209160 bytes received, every attempt. Smaller
docs on the same unikernel work fine:

- `/docs/patterns` (77 KB) → 200 OK in 305 ms
- `/docs/spec/grammar` (35 KB) → 200 OK in 218 ms
- `/docs/quartz_reference` (228 KB) → stalls at 209160 bytes

Numerology: 209160 / 1400 (our `max_seg`) = 149.4 TCP segments. The
response is multi-segmented by `tcp_handle_frame`'s chunking loop,
which calls `tcp_send` → `virtio_net_tx_send` once per 1400-byte
chunk. 149 ≈ 148 segments × 1400 + 160-byte headers.

## NOT reproduced locally

`qemu-system-x86_64 -M microvm -netdev user,id=net0,hostfwd=tcp::8093-:80`
on macOS dev host with the IDENTICAL ELF serves /docs/quartz_reference
cleanly — md5 matches source byte-exact, ~400 ms. So it's either:

1. Host-specific: Ubuntu 5.15 + TCG vs macOS + TCG
2. Load-specific: the VPS has been running for a few minutes serving
   real traffic (curls from our probes), local test was a fresh boot
   per-probe. But we also couldn't repro even on a fresh VPS boot.
3. SLIRP-specific: SLIRP's TCP reassembly on Linux may have a default
   per-connection receive-buffer cap around 200 KB, after which it
   drops segments. Our kernel has no retransmits, so dropped segments
   mean a permanent stall.

## Root cause (confirmed Apr 19 late-session)

**Peer-side TCP receive-buffer saturation.** The Linux kernel on the
VPS has `net.core.rmem_default = 212992` bytes (default), which
caps the per-connection socket receive buffer at ~208 KB. Once the
client (curl) process can't read fast enough — which in our case is
"at all" because the connection is blocked by the first missing
byte — the buffer fills. Since **our TCP has no retransmits and
doesn't honor the peer's advertised window**, every segment beyond
`rmem_default` is dropped on arrival by the Linux stack and never
recovered.

Evidence:

1. With `max_seg = 1400`: stall at 209160 bytes ≈ 149 segments.
2. With `max_seg = 1200`: stall at 207360 bytes ≈ 172 segments.
   Segment count changed but **byte count stayed within ~2 KB** —
   rules out queue-depth or segment-count bugs.
3. `tx_stalls` counter (added to `/api/stats.json`) stayed at `0`
   during the stall — meaning `virtio_net_tx_send` itself never
   hit its 10M-spin timeout. The guest's virtio layer is fine;
   the bottleneck is downstream.
4. Kernel log shows `"HTTP: response sent, FIN -> FIN_SENT"` for
   every stalled request — guest believes it sent the whole thing.

Initial theory (below) about `virtio_net_tx_send` fake-complete was
wrong for THIS bug, but the fake-complete WAS a genuine silent-
corruption issue (next call would overwrite desc[0] while device was
still DMAing), so the fix landed anyway — the fake-complete is gone,
the function now spins indefinitely with a `g_tx_stalls` counter.

## Why local tests don't repro

macOS's SLIRP (QEMU builtin) uses a different TCP stack than Linux's
(the guest talks SLIRP regardless of host, but SLIRP hands off to
the host's socket layer for the WAN side). macOS's default
`net.inet.tcp.recvspace` is 131072 on some releases but practically
unbounded on modern macOS — curl reads fast enough that the
connection-level receive buffer never fills past the ~200 KB
hazard zone. Linux's `rmem_default = 212992` is the hard ceiling
we hit under SLIRP → host-TCP.

## Real fixes (in order of doing-it-right)

1. **Observe first.** Add a TX-stall counter: bump a global whenever
   `virtio_net_tx_send` hits the spin timeout. Expose in
   `/api/stats.json` as `tx_timeouts`. Reproduce on the VPS, confirm
   the counter increments at the moment of stall.
2. **Correct the timeout behavior.** Fake-completing on spin-timeout
   is wrong. Either (a) don't cap the spin, or (b) `return -1` and
   have the caller retransmit. (b) requires retransmit logic we don't
   have, so (a) for now — accept that a broken device hangs the
   kernel.
3. **Bigger TX queue.** `VIRTIO_NET_QSIZE = 8` is uncomfortably small.
   Bump to 64 or 256. Legal per virtio spec; negotiated at
   `VIRTIO_REG_QUEUE_NUM_MAX`.
4. **Implement TCP receive-window honoring + retransmits.** The real
   fix. Tracks peer's advertised window, slows down / queues when
   window shrinks, retransmits segments the peer ACKs out of order.
   This is a 500-line TCP overhaul, not a Phase 2 item.
5. **SLIRP → raw tap/macvtap.** SLIRP is the VPS bottleneck. With a
   tap device the unikernel sees real 10 GbE and the 209 KB limit
   probably disappears. Requires root + systemd-networkd configuration
   on the VPS.

## Workaround landed in Phase 2 (historical)

`tools/bake_assets.qz` filtered out any source file > 200 000 bytes and
emitted a `# SKIPPED:` note in the generated file header. At the time
this only affected `docs/quartz_reference/index.html` (228 KB).

## Fix landed Apr 20 2026 (`95b8e777`)

The real fix — TCP window tracking + retransmits — landed as a single
commit. See `docs/handoff/unikernel-tcp-window-retransmit.md` for the
design; short version:

1. Per-slot 4 MiB upfront response scratch + per-slot retry metadata
   (peer_win, resp_start_seq, last_tx_tick, etc.) in a 128-byte conn
   slot (grown from 64 B). Scratch is kernel-lifetime and reused
   across connections on a slot.
2. `tcp_try_push` emits segments gated on
   `peer_win - (snd_nxt - snd_una)` — the window's current room.
   Called on every inbound ACK (both snd_una-advancing and
   window-update-only) and on arm-response. Zero-window fires a single
   bare ACK so inbound data is still acknowledged while we're paused.
3. `tcp_retransmit_pass` runs each serve-loop tick; any slot with
   `(snd_nxt - snd_una) > 0` and `last_tx_tick + RTO_TICKS < g_tick_count`
   replays from `snd_una`. RTO is 1 tick ≈ 1 s.
4. `/api/stats.json` exposes `tx_retransmits` and `tx_bytes_pending`
   for live observability.

`tools/bake_assets.qz` had its `tx_ceiling` removed in the same
commit. `baremetal:bake_assets` now emits all 265 assets (6.8 MB).
