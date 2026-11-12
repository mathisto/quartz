# Unikernel virtio-net RX ring stall (Apr 19 2026)

**Severity:** HIGH (full service hang on production VPS)
**Status:** Observed, not yet diagnosed. Workaround: `systemctl restart quartz-unikernel`.
**First observed:** Apr 19 2026, mattkelly.io VPS, after ~some-hours of serving real traffic
since the Apr 18 deploy.

## Symptoms

- Host `ping` to VPS responds normally.
- `nc -zv 195.35.36.247 8080` — TCP handshake succeeds (QEMU hostfwd accepts on :8080,
  forwards to guest :80).
- `curl http://195.35.36.247:8080/` — connection opens, then 0 bytes of data received,
  request times out.
- `connections_served` counter at last-known-good was 16,371 (from a curl just before
  the hang was noticed; stats.json was unreachable by the time the hang was confirmed).

## Pre-restart kernel log signature

```
[rx: u=16444 c=8816895 len=68]
[rx: u=16444 c=8816896 len=64]
[rx: u=16444 c=8816897 len=679]
[rx: u=16444 c=8816898 len=64]
...
```

`u` (virtio-net `used.idx`) stops advancing. The `c` counter (a local RX-loop
counter) keeps incrementing because the device is still delivering frames into the
ring — but the guest-visible `used.idx` is stuck, so `virtio_net_rx_wait` never
returns. The final log line before we restarted was `TCP: SYN from 10.0.2.2:42610`
— meaning one frame DID get through near the end, but then the ring wedged.

The `u=16444` value is suspicious: 16444 × (some descriptor size) likely corresponds
to a wrap-around boundary in the virtio ring (rings are typically 256 entries;
16444 mod 256 = 60, not a clean boundary, so the numerical coincidence is probably
misleading — but the fact that `u` froze at a specific value across thousands of
arriving frames is the smoking gun).

## NOT the 16-slot TCP-table theory

Initial hypothesis was "all 16 per-connection TCP slots leaked" (based on handoff
doc calling out no TIME_WAIT, no retransmits). This is almost certainly wrong:

- If TCP slots had leaked, we'd still see `u` advancing — the virtio device would
  happily deliver frames, the kernel would parse them, and `tcp_find_slot` would
  return 0 (unknown peer), `tcp_handle_frame` would drop them.
- Actual log shows `u` itself stuck, meaning the problem is BELOW TCP — at the
  virtio-net driver layer, not the TCP slot layer.

## Likely root causes (ranked)

1. **Descriptor-ring wrap bug.** `virtio_net_rx_post()` posts descriptors back to
   `avail.idx` on each completion. If the avail/used indices drift (e.g., off-by-one
   over hours of traffic), the device runs out of posted descriptors. The driver
   then polls `used.idx` forever waiting for a completion that can't arrive because
   the device has nothing to deliver into. Existing comment in `hello_x86.qz` near
   `virtio_net_rx_post` already flags a similar concern ("naïvely re-posting every
   iteration inflates avail.idx far past used.idx").
2. **Avail-ring corruption from a non-DMA write.** The current driver re-uses
   `g_vnet_rx_buf` — a single 4 KiB page — for every RX. If a DMA write ever
   straddles the buffer (it shouldn't — MTU is 1500) we'd clobber the ring
   metadata. Low probability.
3. **Host-side QEMU TCG + virtio-mmio quirk** that only triggers after a specific
   number of cycles or interrupts. Observed only on the Ubuntu 5.15 VPS; reproduces
   may be host-specific.

## Repro strategy (not yet attempted)

- Let the unikernel run under local `qemu-system-x86_64 -M microvm` for N hours
  with a traffic generator (e.g., `wrk -t2 -c4 -d24h http://127.0.0.1:8093/`).
- Log `u` and `avail.idx` every 1000 frames to watch the gap grow.
- When a hang reproduces, diff `used` / `avail` / descriptor table to find the
  exact off-by-one.

## Real fix

DEF-B (IOAPIC + IRQ-driven RX) in `docs/handoff/kern4-to-joy-demo-handoff.md`.
The current polling loop is fundamentally fragile because `used.idx` is the only
signal the driver looks at — if that stalls for ANY reason, the kernel wedges.
An IRQ-driven RX path would:

- Hang a `hlt` on the idle task instead of polling.
- Use virtio-mmio's `InterruptStatus` register to distinguish "RX completion"
  from "config change" interrupts.
- Re-post descriptors defensively on every ISR, not just on loop iteration.

This moves the bug into a region where it can at least be isolated to a specific
interrupt path rather than hiding inside a monotonic-counter polling loop.

## Workaround (live)

`ssh mattkelly.io systemctl restart quartz-unikernel` — takes under 2 seconds,
ELF reloads from `/opt/quartz/quartz-unikernel.elf`. Unikernel state is cleared
on restart (stats counters go to 0, PMM pool re-initialized). No user-visible
data is lost because the unikernel is stateless.

Consider adding a systemd `Restart=on-failure` + `WatchdogSec` for automatic
recovery — but the current driver won't crash, it just hangs, so the watchdog
needs to be external (HTTP health check from Caddy or a cron).
