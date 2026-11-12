# Unikernel: TX/RX spin-wait compares 16-bit ring index against 64-bit counter → hang at packet 65 536

**Status:** FIXED 2026-04-20 by commit TBD (same session as this file).
**Severity:** Critical — silently hangs the unikernel ~10 min after boot
under typical request load. Process stays "active" to systemd (QEMU is
still running and burning CPU) while the guest is frozen, so restart
isn't automatic.

## Symptom

Serial log's final line:

```
[tx: stall >10M spins, packet 65536]
```

Then silence. No further RX/TX activity, no further HTTP responses.
systemd-side:

- `systemctl status quartz-unikernel` shows `active (running)`
- `CPU: <wall-time>` — CPU seconds track wall-clock seconds (guest is
  spinning at ~100% of a core)
- Process memory stable at ~96 MB (no leak)
- `/var/log/quartz-unikernel.log` mtime freezes at the stall point

## Root cause

`tools/baremetal/hello_x86.qz` has two spin loops that wait for the
virtio-net device to advance its ring index:

1. **TX drain** (`virtio_net_tx_send`, ~line 880 pre-fix)
   ```qz
   var used = volatile_load<U16>(g_vnet_tx_used_addr + 2)
   while used != g_vnet_tx_posted
     ...
   end
   ```

2. **RX wait** (`virtio_net_rx_wait`, ~line 1107 pre-fix)
   ```qz
   var used_idx = volatile_load<U16>(g_vnet_used_addr + 2)
   while used_idx == g_vnet_rx_consumed
     ...
   end
   ```

Per the virtio-legacy-net spec, both `avail.idx` and `used.idx` are
**16-bit unsigned** counters that wrap naturally at 65 536. Descriptor
ring lookups modulo QSIZE are correct either way — what matters is
that the two sides (guest and device) agree on "what's new" by
comparing the low 16 bits.

`g_vnet_tx_posted` and `g_vnet_rx_consumed` are declared as Quartz
`Int` (i64) and incremented monotonically without wrap. The store
side is fine — `volatile_store<U16>` implicitly truncates. The
**compare side** is broken: the 16-bit loaded `used` is compared
directly against the 64-bit counter.

At packet 65 536:
- TX: `used` (device-side, wrapped) reads 0. `g_vnet_tx_posted` is
  65 536. Condition `0 != 65 536` stays true forever → **infinite spin**.
- RX: `used_idx` reads 0 while `g_vnet_rx_consumed` is 65 536. Condition
  `0 == 65 536` is false → **loop exits on the first iteration**, code
  proceeds to process ring slot 0, which is stale data from the first
  RX frame. Ghost completion, which may or may not cascade into
  visible bugs but definitely isn't right.

The ~10-minute uptime matches: a single browser tab polling
`/api/stats.json` every 500 ms generates ~2 request/s × ~50 TX
segments/response = ~100 TX packets/s. 65 536 ÷ 100 ≈ 10.9 minutes.

## Fix

Mask both counters to 16 bits before compare:

```qz
# TX
var posted_lo = g_vnet_tx_posted & 0xFFFF
while used != posted_lo
  ...
end

# RX
var consumed_lo = g_vnet_rx_consumed & 0xFFFF
while used_idx == consumed_lo
  ...
end
```

Keeping the full i64 counters intact preserves the /api/stats.json
telemetry (monotonic lifetime packet count). Only the comparisons need
to be 16-bit.

## Related

- `docs/bugs/UNIKERNEL_TX_STALL_209KB.md` — separate, pre-existing
  TX-stall bug around the 209 KB asset boundary, tied to SLIRP's
  per-connection receive buffer. Still open as DEF-D (retransmit +
  window honoring). Different failure mode: hits at a specific byte
  offset, not a specific packet count.

## Regression

Deploy-level regression would be: run the unikernel for >12 minutes
with ~200 req/s from the browser (so that tx_posted crosses 65 536)
and confirm it continues serving. Pre-fix: locks up at ~10 min.
Post-fix: no lockup.
