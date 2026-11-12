# Unikernel: page fault after ~1h24m uptime (PF at 0xFF…FF88)

**Status:** open — NOT root-caused. Production mitigation in place
(see §"Mitigation" below). Next-session task: collect RIP from the
enhanced PF ISR and disassemble against the ELF to pinpoint the
faulting instruction.

**Filed:** 2026-04-20, immediately after the virtio-ring-wrap fix
(commit `2a066cb2`) surfaced this second failure mode.

## Symptom

Kernel runs normally for 1h24m (14 960 HTTP requests served, all via
`/api/stats.json` + `/health` + baked pages), then:

```
[rx: u=10715 c=76250 len=680]
HTTP: request received (616 bytes)
PF at 0xffffffffffffff88 err=0x0000000000000000
```

No further log output. systemd reports `active (running)` because
QEMU keeps running (`@c("cli; 1: hlt; jmp 1b")` in the ISR never
exits, and QEMU doesn't know the guest halted). CPU pegs at 100% of
one core (HLT spinning).

Error-code `0x00` decodes to **read, supervisor, non-present, data**.
CR2 = `0xFFFFFFFFFFFFFF88` = `-120` as signed i64 = `2^64 - 120`
unsigned. This is deep into the kernel canonical half of the x86_64
address space — unmapped in our identity-paging microvm. So the
kernel dereferenced a pointer that is effectively `0 - 120` (or any
equivalent small-negative computation).

## What IS and ISN'T the story

Ruled out:
- **Stack overflow.** Our 64 KiB stack lives in the low physical half
  (~0x600000); an overflow wouldn't land at `-120`.
- **PMM exhaustion.** `pmm_pages_used` stable at 2 482 / 16 384 across
  the crash. Log didn't print "OOM" (which `pmm_alloc_page` would).
- **The virtio-net 16-bit ring wrap bug** — that's fixed (commit
  `2a066cb2`, docs/bugs/UNIKERNEL_TX_IDX_WRAP_HANG.md). `tx_stalls=0`,
  `c=76250` (passed the 65 536 wrap twice), the wrap isn't involved.
- **Quartz `volatile_load<U32>` sign-extension.** Codegen emits
  `zext`, not `sext` (verified in `cg_intrinsic_memory.qz`), so
  U32 → i64 loads can't produce kernel-half addresses on their own.

Not ruled out (candidate root causes for a future session):

1. **TCP-send chunker arithmetic.** `src_ptr = body_ptr + (sent - hdr_len)`
   at `hello_x86.qz:2232`. No direct path produces `-120`, but if
   `body_ptr` is 0 (dynamic-route response, no asset body) AND a logic
   bug makes the `else` branch fire (shouldn't, `sent < hdr_len` guards
   it), we'd compute `0 + (-hdr_len) = -hdr_len`. For `hdr_len = 120`,
   that's `-120` exactly. **Leading hypothesis.** `/api/stats.json` has
   a header of ~180 bytes and body also ~180 bytes; `/health` has
   `hdr_len = ~120`, body 0. A specific race between `hdr_len` and
   `total_len` computation that produces `sent > hdr_len` when
   `body_ptr = 0` would do it.

2. **If-None-Match parsing** at `asset_if_none_match()`. If `req_len`
   is 0 or very small and `nlen + ETAG_HEX_LEN + 1` exceeds it,
   `limit = req_len - nlen - ETAG_HEX_LEN - 1` could go negative.
   `while i < limit` with a negative (huge unsigned) limit would loop
   very long, reading past buffer bounds. Could PF anywhere.

3. **Something in the recent-records ring** (`recent_record`). Bounded
   by `% RECENT_SLOTS (=64)` and entries are 96 bytes, well within the
   two pages allocated. Probably safe, but worth a closer look with
   RIP evidence in hand.

## Mitigation (shipped)

Rather than chase a production hang we can't reproduce locally, we
added belt-and-suspenders uptime plumbing that makes the bug invisible
to users:

1. **`RuntimeMaxSec=45min`** on `quartz-unikernel.service`. Forces
   systemd to cycle the guest every 45 min — well under the 1h24m
   observed hang threshold. Combined with `Restart=always`, the
   unikernel is never allowed to run long enough to hit the PF in
   production. Browsers see a sub-second reconnect at each cycle.

2. **`quartz-unikernel-healthcheck.timer`** (every 2 min). Curls
   `/health` from the host; on two consecutive failures (covering
   the mid-restart window) it runs `systemctl restart`. This is
   defense-in-depth in case a hang happens within a 45-min cycle
   window, faster than RuntimeMaxSec would catch.

3. **Enhanced `page_fault_isr`** (commit TBD) now prints RIP, CS,
   RFLAGS, RSP, SS in addition to CR2 + error code. Next time the PF
   fires (e.g., during a future long test run that disables the
   RuntimeMaxSec cycle), the log will tell us exactly which
   instruction address did the bad dereference. `addr2line` against
   `tmp/baremetal/quartz-unikernel.elf` will map RIP to a source
   line and we can finish the diagnosis in ten minutes.

## How to reproduce for investigation

The cycle timer prevents natural repro. To trigger the bug
deliberately:

```bash
# On the VPS — disable the cycle timer for a focused diagnostic run:
ssh mattkelly.io 'systemctl edit quartz-unikernel --runtime
# drop a [Service] override with RuntimeMaxSec= (empty, to clear)
# save and exit
systemctl restart quartz-unikernel
'

# From the host — hammer /api/stats.json for ~90 min:
seq 1 1000000 | xargs -P 50 -I{} curl -sk --max-time 8 -o /dev/null \
  https://mattkelly.io/api/stats.json

# When the PF prints, read the full diagnostic:
ssh mattkelly.io 'grep -A3 "PF at" /var/log/quartz-unikernel.log'

# Expect output like:
#   PF at 0xffffffffffffff88 err=0x0000000000000000
#     RIP=0x0000000000123456 CS=0x0000000000000008
#     RFL=0x0000000000010206 RSP=0x...   SS=0x...

# Then on the host (need llvm-addr2line or objdump):
addr2line -e tmp/baremetal/quartz-unikernel.elf 0x123456
# → should name the faulting function + line
```

## Regression lock

When the PF is root-caused and fixed, add a test that runs
2 000 000+ HTTP requests through QEMU in CI (or a scripted local
loop) without a reset, and asserts:
- `tx_stalls = 0`
- process RSS stable
- `/health` responsive throughout
- serial log contains no `PF at` message

## References

- `docs/bugs/UNIKERNEL_TX_IDX_WRAP_HANG.md` — the sibling bug fixed in
  commit `2a066cb2` that this PF exposed (previously masked by the
  10-min virtio-wrap hang).
- `docs/bugs/UNIKERNEL_TX_STALL_209KB.md` — third open issue (TX
  stall at 209 KB asset boundary; DEF-D in KERNEL_EPIC).
