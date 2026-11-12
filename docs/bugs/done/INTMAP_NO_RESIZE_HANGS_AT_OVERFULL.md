# `intmap_set` has no resize and no probe-loop bound — hangs at overfull

**Filed**: 2026-04-27 during the `intmap_get_sentinel` codegen work (`bee41c14`).
**Status**: ✅ **RESOLVED** (verified 2026-04-29). The resize logic
described in the original "Fix shape" section was implemented at some
point between filing and audit; `cg_intrinsic_intmap.qz`'s `intmap_set`
now has the `imr_resize_<d>` block (size >= 3*cap/4 → double + rehash)
mirroring `hashmap_set`. The 32-insert repro at the top of this doc
runs to completion; `m.size = 32`, no hang.

## Symptom

```be
def main(): Int
  var m = map_new<Int, Int>()
  var i = 0
  while i < 32             # <-- 17th insert hangs forever
    m.set(i, i * 10)
    i = i + 1
  end
  return 0
end
```

Compiles cleanly. Runtime: spins at 100% CPU forever in `intmap_set`'s probe loop.

## Why

`cg_intrinsic_intmap.qz`:
- `intmap_new` allocates a fixed-cap=16 table (line 44).
- `intmap_set` linearly probes `idx = (idx+1) % cap` looking for an empty slot or matching key (lines 207-223).
- **No grow path**: the probe never gives up and never reallocates.
- **No probe-count guard** like the one `intmap_get` / `intmap_get_sentinel` / `intmap_fetch` use (`maxed = cnt >= cap`).

When the table fills (16 occupied slots, no matching key): every slot is non-empty and no key matches. The "empty or match" condition can never be satisfied, so the loop runs forever.

## Why it's been latent

Compiler-internal callsites of `__map_get_raw` use `Map<String, Int>` (`builtins`, `hashcons`, etc.), which routes through the hashmap path — and `__hashmap_get_sentinel` / `hashmap_set` both have proper resize and probe bounds.

`map_new<Int, Int>()` user-side usage with > 16 entries is rare today, but no reason it should be. The fix is straightforward; this is a discoverable footgun rather than a tricky bug.

## Fix shape (when pulled in)

Two pieces, both uncontroversial:

1. **Resize on load-factor threshold in `intmap_set`** — when `size >= (cap * 7 / 8)` after an insert, allocate a new table at `cap * 2`, rehash every used slot, swap the buffers atomically. Mirrors how `hashmap_set` handles growth (see `cg_intrinsic_data.qz`'s `hashmap_set` resize path for the canonical shape).

2. **Probe-count guard in `intmap_set`** — same `maxed = cnt >= cap` check the get-side intrinsics already have, so even without resize the loop terminates. Belt-and-suspenders defensive.

Once both ship, re-add a `intmap_set_overflow_spec.qz` test that inserts >16 keys (with the existing `map_get_raw_spec.qz`'s probe test broadened from 8 to 32) to lock in regression.

Estimated scope: ~150 lines of codegen for the resize path (mirror hashmap_set), ~10 lines for the probe guard. Both fit in one quake-day.

## Pull-in trigger

- Any user pattern that lands `map_new<Int, Int>()` with > 16 entries.
- Re-enabling the string_intern dedup cache (per the cache-pattern miscompile entry's "Next steps") — that uses `Map<String, Int>` so won't hit this directly, but if the dedup pattern spreads to Int-keyed mangle ID lookups it would.
- Any new compiler-internal cache that uses Int keys and grows.
