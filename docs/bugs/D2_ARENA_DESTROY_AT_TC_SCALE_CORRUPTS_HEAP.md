# `arena_destroy(arena)` corrupts libc heap when called after a heavy `Alloc.in_arena` workload

**Filed**: 2026-04-27 during Phase D.2 (TC arena seam) attempt.
**Status**: Latent. D.2 was reverted (different reason — see [Why D.2 doesn't ship](#why-d2-doesnt-ship) below); the bug remains a known issue for any future user of `Alloc.in_arena` at high allocation scales. Pull-in trigger: a real user-level pattern that hits this.

> **Update 2026-04-27 (later same day)**: a *separate* UAF in D.1's codegen-arena
> path masqueraded as this bug while investigating the related Tier 2 #20 entry.
> The cache-save crash at `cache_save_string_pool +296` was NOT this bug — it
> was a use-after-free where `_cg_last_string_pool` (assigned from
> `state.string_pool` inside the `with Alloc.in_arena(cg_arena) do -> cg_codegen
> ... end` wrap) pointed into arena pages that `arena_destroy(cg_arena)` later
> munmap'd. The bug below — fresh `vec_new<String>()` after `arena_destroy`
> returning a bad pointer — is a different shape (no pre-existing arena-resident
> data being read; the corruption is in the *libc heap state itself*) and
> remains latent. Cross-link the cache-save UAF fix: `codegen::cg_promote_last_string_pool()` added as a sibling of `arena_promote_string(llvm_ir)` in `quartz.qz:compile()`. The lesson worth carrying forward: **anything that lives across the wrap boundary needs an explicit promotion step, even if the symptom looks like libc-heap corruption**. When in doubt, look for arena-resident references before believing libc itself is broken.

## Symptom

`arena_destroy(arena)` after a `with Alloc.in_arena(arena) do -> ... end` wrap that contained a heavy workload causes the **next libc malloc** to return an unmapped pointer. The subsequent write SIGSEGVs (`EXC_BAD_ACCESS`, `KERN_INVALID_ADDRESS`).

`arena_destroy` itself does not visibly crash — it walks the chain and returns. The crash manifests on the FIRST `__qz_alloc(N)` call after `arena_destroy` returns.

Crash report excerpt (`~/Library/Logs/DiagnosticReports/quartz-2026-04-27-160813.ips`):
```
EXC_BAD_ACCESS / SIGSEGV (KERN_INVALID_ADDRESS) at 0x0000000106114850
faulting thread:
  PC at compile + 63516 (instruction `stp x9, xzr, [x0]` — 16-byte store)
  x0 = 0x106114850 (the bad address)
  x9 = 64        (Vec header cap=64)
  x12 = 4096     (page size)
  vmRegionInfo: "0x106114850 is not in any region. Bytes after previous region: 14862417"
```

The faulting instruction is the Vec header initialization for `vec_new<String>()` immediately after `arena_destroy`. The address `x0` came from `__qz_alloc(24)` — i.e., libc malloc returned a bad pointer.

## Repro shape (during D.2 attempt)

```be
var tc_arena = arena_new(65536)
with Alloc.in_arena(tc_arena) do ->
  # Heavy TC pipeline: tc_new(), tc_program, body type-check loop, tc_free.
  ...
  0
end
# Wrap exited.
arena_destroy(tc_arena)   # <-- Walks chain, returns, but corrupts libc heap.
var v = vec_new<String>()  # __qz_alloc(24) returns bad pointer → SIGSEGV.
```

Reproduces on any non-trivial source — even `def main(): Int return 42 end` (8K arena allocs / 435 KB used) is enough.

## What we ruled out

The bug is NOT triggered by:
- Many allocations alone (92K Vec.push'es in a single arena succeed; see `/tmp/d2_arena_repro2.qz` from the diagnosis session).
- Vec growth via realloc inside an Alloc.in_arena wrap (1000 Vecs × 1000 elements + vec_free + arena_destroy works in isolation).
- Heavy String allocation + interpolation (1000 interpolated strings inside arena + destroy + post-destroy malloc all succeed).
- Many `vec_free` calls inside the wrap (mimicking tc_free's 30+ vec_free's works in isolation).
- Calling `arena_bytes_used` / `arena_alloc_count` post-wrap before destroy.

Standalone reprose during diagnosis all succeeded — only the full TC wrap inside `compile()` triggered it.

## Working hypotheses

1. **Double-free in the chain walk.** Some chain block's `next` pointer is corrupted to point to a previously-freed block, so `arena_destroy` frees the same header twice → libc free-list corruption → next malloc returns bogus.
2. **Write-past-end.** Some specific allocation pattern (size mix, alignment) lets `arena_alloc` return a pointer that, when written to its claimed size, overlaps an adjacent chain block's header (or libc metadata adjacent to a libc-malloc'd 32-byte chain header). Likely triggers from interaction with libc's small-allocation slab layout.
3. **TLS state leak.** `__qz_alloc_in_handler` or `__qz_effect_current_install_idx` left in a wrong state by some path inside the heavy workload, so subsequent allocations during arena_destroy don't bypass correctly. The crash report shows these globals in the register state, hinting at this.

## Investigation notes

- `arena_bytes_used(arena)` post-wrap returns 4220720 (4.2 MB) for a TC-scale workload.
- `arena_alloc_count(arena)` post-wrap returns 92604 for a TC-scale workload.
- Chain block headers are libc-malloc'd 32 bytes via `__qz_alloc(32)` inside `arena_alloc_handler_e` (in_h flag set → bypass to libc).
- Head block is libc-malloc'd 40 bytes (now 48 bytes post-D.x) via `arena_new` (no user handler at that point → bypass).
- `arena_bytes_used` walks the chain successfully at destroy time, proving the chain structure is INTACT — at least up through reading `cap`/`used`/`next` for each block.
- Skipping arena_destroy: program runs to completion correctly. So the CONTENT of arena memory is correct; only the destroy path is broken.

## Why D.2 doesn't ship

Independently of this bug, **D.2's premise was wrong**. The TC arena's no-free model accumulates the FULL allocation history during TC, while libc's allocator reuses freed memory. The libc fragmentation that the design memo expected to recover (+617 MB at TC end) was actually NOT live working set — it was libc holding pages on free lists. The true live working set during TC is HIGHER than the libc-fragmentation amount (1265 MB live set vs 617 MB libc retention). So routing TC's allocations through an arena INCREASES memory usage rather than decreasing it.

D.2's wrap was reverted. D.x optimization (chain-block-size bump 4 KB → 64 KB + last-fit cache) was retained because it's a clean wall-time win for D.1's `cg_arena` (104s → 62s self-compile, peak 2696 MB → 2449 MB), independent of D.2.

## Pull-in trigger

This bug is dormant unless someone constructs a workload that:
1. Wraps a heavy allocation pattern in `with Alloc.in_arena(ar) do ... end`.
2. Calls `arena_destroy(ar)` after the wrap exits.
3. Subsequently does a libc allocation (almost any work after).

Compiler dogfooding (Phase D, E) was the most plausible source. With D.2 reverted, no current code path hits this. Pull-in trigger: a real user-level pattern that exposes it.

## Next-step plan when pulled in

1. **Bisect by phase.** Wrap progressively smaller portions of the heavy workload to find the minimum slice that triggers. Bisects the WHICH-routine question.
2. **Instrument arena chain.** Add a debug intrinsic that walks the chain and dumps block addresses + caps + nexts. Compare against another walk done by hand. Detect cycles / duplicates / corrupt nexts.
3. **Add a poisoned-page guard.** Allocate a 16-byte canary at the END of each chain block's data buffer. After the wrap, walk the chain checking canaries. Catches write-past-end.
4. **Replace libc free with mmap-style return.** Allocate chain headers via a separate small-arena (mmap'd) instead of libc malloc. Bypasses libc heap entirely. If the bug goes away, hypothesis (2) is confirmed (libc heap interaction).
5. **lldb attach.** Set breakpoint on the SIGSEGV, inspect the chain state at crash time. Look at the bad pointer's origin.

## 2026-04-29 — Follow-up hypothesis from E.5 prep research

A research pass (E.5 Alloc bisect prep agent, Apr 29) advanced an additional hypothesis: **the bug is a missing-promotion pattern, not a chain-walk corruption**.

**Hypothesis:** D.2's TC pipeline allocated `Map<K, V>` and/or `Set<T>` instances inside the arena. There are NO `arena_promote_map` or `arena_promote_set` helpers in `std/alloc.qz` (existing helpers cover String, Vec<value>, Vec<reference>, struct-uniform, struct-mixed only). When a Map/Set is created in arena scope and survives the boundary via a captured reference (closure, module-global, etc.), `arena_destroy(arena)` munmaps its key/value storage while libc still holds the outer Map header — next libc malloc sees a bogus freelist entry that points into munmap'd address space. Symptom matches the SIGSEGV-at-+63516 pattern: libc's malloc returns an unmapped pointer when asked for the next allocation.

**Evidence supporting this framing:**
- `tc_free` (typecheck_util.qz:3136-) does dozens of `vec_free` calls — Maps are NOT explicitly freed there. They rely on the ambient allocator's lifetime.
- TcRegistry contains `Vec<String>` field annotations for every registered type/trait/impl/enum-variant. Those are arena-resident in D.2 but lack a Vec<String> promote (slice 4 covers `Vec<reference-typed>` but only via the `arena_promote_vec_ref` dispatcher at element-kind=2/String; that requires the synthesizer to emit a call, which D.2's wrap doesn't do for arbitrary intermediate Vec<String> data).
- The bug doc's framing — "anything that lives across the wrap boundary needs an explicit promotion step" — explicitly anticipates this class.

**Why E.5 implementation is harder than first sketched:**
The naive "Map<Int, Int>" promote helper hits two design walls:
1. **Quartz Maps have two distinct runtime layouts** — string-key (regular `Map<String, V>` via libc hashmap) and int-key (`Map<Int, V>` via intmap). A single-signature helper cannot handle both.
2. **Reference-typed values are arena-resident.** A `Map<String, Vec<Int>>` allocated in-arena has BOTH the keys AND the value Vecs in arena memory; the helper must recursively promote each value. Same for nested Map and struct values. That implies a runtime descriptor (like `arena_promote_struct_mixed`'s `layout: Vec<Int>`), not a flat helper.

**Recommended next-session approach:**
1. **Confirm hypothesis first.** Construct a minimum repro: heavy `Map<String, String>` allocation inside `with Alloc.in_arena(ar) do ... end`, then `arena_destroy(ar)`, then a libc allocation. Crash → hypothesis confirmed.
2. **If confirmed, ship in two slices.** Slice (a): `arena_promote_map_string_string` and `arena_promote_set_string` — single-shape primitives covering the most common case (string key, string-or-primitive value). ~30 LOC each. Slice (b): runtime-descriptor variant (`arena_promote_map_runtime`) for recursive value types — mirror the slice-3.b struct_mixed pattern.
3. **Wire into synthesizer** (`mir_lower.qz:1131-1259` `_mir_should_auto_arena`) once both string-key and int-key shapes are covered. Add `kind=7` (Map), `kind=8` (Set) classifier branches.

**Status today:** still latent. D.2 reverted. No current code path hits this. The new hypothesis informs the next-session plan; the prior 5 hypotheses (chain corruption, write-past-end, TLS leak, libc-free interaction, lldb attach) remain valid backup paths if the missing-helper hypothesis fails to reproduce.

## 2026-04-29 (later same day) — Synthetic reprose at D.2 scale do NOT trigger

Three synthesised reprose were attempted to confirm the missing-Map/Set-promote hypothesis before committing to slice (a) of E.5. **All three completed cleanly.**

| Repro | Scale | Result |
|---|---|---|
| `/tmp/e5_repro_map.qz` | 200-entry `Map<String, String>` in arena, then destroy + 3 post-destroy libc Vec pushes | ✅ Survived |
| `/tmp/e5_repro_heavy.qz` | 50× `Map<String, String>` × 200 entries + 2000-entry `Vec<String>` + 30 vec_free passes inside arena → **151K allocs / 6 MB used** (1.6× D.2's reported scale), then destroy + 1000-entry post-destroy `Vec<String>` | ✅ Survived |
| `/tmp/e5_repro_captured.qz` | Map handle captured into module-scoped `Int` (type-erased) surviving the wrap boundary, then arena_destroy + fresh `Vec<Int>` of 2000 + fresh `Map<String, Int>` of 200 | ✅ Survived |

This matches the bug doc's existing observation ("Standalone reprose during diagnosis all succeeded — only the full TC wrap inside compile() triggered it"). The April 29 missing-helpers hypothesis was therefore **necessary but not sufficient** as a framing — even with the hypothesised gap present, synthetic Map/Set workloads don't expose it. The bug requires a TC-pipeline-specific allocation pattern that's not captured by "lots of Map<String, String> + arena_destroy."

**Implication for next E.5 session:**

1. **Don't pre-build `arena_promote_map` / `arena_promote_set` helpers without a witness.** Slice (a) of the recommended approach is premature — the helpers might fix the bug, but they might not, and we have no test that would prove it either way.

2. **The minimum viable bisect is reapplying D.2's TC arena wrap and running self-compile.** Then progressively narrow which TC subroutine triggers the corruption. This is the same investigation D.2's original session abandoned (hit the corruption, didn't bisect). Multi-session work, requires a fix-specific binary backup before starting.

3. **Backup hypotheses remain plausible.** The original 5 (chain corruption, write-past-end, TLS leak, libc-free interaction, lldb attach) all still apply. Notable: libc-free interaction (hypothesis #4) is consistent with "synthetic reprose miss because they don't replicate libc's allocation interleaving with TC's specific size mix" — TC mallocs of typecheck-state structs (specific sizes) interspersed with arena chain header mallocs (32 B) might land adjacent free-list entries that overflow into each other only at TC's particular pattern.

4. **Pull-in trigger upgraded.** Don't pull in E.5 just on a roadmap item; pull in only when a user pattern actually crashes OR when D.2's wrap is reapplied as part of a Phase D revival. The latent risk doesn't justify multi-session investigation without a witness.

**Reprose preserved at:** `/tmp/e5_repro_map.qz`, `/tmp/e5_repro_heavy.qz`, `/tmp/e5_repro_captured.qz` (verified 2026-04-29 against `self-hosted/bin/quartz` HEAD at commit `4bb59290`).

## 2026-05-06 scout pass — narrowed analysis (no fix, just narrowing)

A read-only scout pass focused on three questions: (1) what's the leading hypothesis, (2) what's the minimum reproduction, (3) how tractable is a fix.

**Leading hypothesis: write-past-end into the next chain header block (libc slab corruption).**

Reasoning:
- `arena_destroy` doesn't crash itself — it walks the chain successfully and returns. The crash is on the FIRST subsequent libc malloc.
- This means libc's heap state is already corrupt by the time the wrap exits, BEFORE `arena_destroy` is even called. `arena_destroy`'s walk happens to not trip the corruption; the next malloc does.
- Synthetic reprose miss — even 151K allocs / 6 MB Map/Set stress survives — so it's not "many allocations." It's a specific size-and-order interleaving the TC pipeline produces.
- TC's allocation profile mixes typecheck-state structs (varied sizes) with chain-header mallocs (32 B). Libc's small-allocation slab puts consecutive 32-byte mallocs adjacent. If `arena_alloc` writes past its claimed size at a block boundary, it can spill into the next chain header block (which is malloc'd by libc), corrupting libc's metadata for that slot.

**Code surface to audit (~500 LOC in `cg_intrinsic_memory.qz`):**
- Lines 609–618: `arena_alloc` size alignment math (`(size + 15) & -16`) — verify newoff doesn't overflow when off + aligned-size approaches cap
- Lines 740–744: block-boundary check (`icmp sle i64 newoff, cap`) — signed compare; if newoff wraps negative, "fits" check passes incorrectly
- Lines 805–812: chain growth (page-align cap) — addition could wrap if cap is large, but unlikely at TC scale
- Lines 1036–1133: `arena_destroy` walk (already audited; reads `next` and `cap` BEFORE freeing `cur`, so no use-after-free in the walk itself)

**Minimum reproduction:**
- Reapply D.2's TC arena wrap in `quartz.qz:compile()` (one `with Alloc.in_arena(tc_arena) do ->` block around `tc_new` + body type-check + `tc_free`).
- Self-compile any non-trivial program (even `def main(): Int return 42 end` works at 8K allocs / 435 KB).
- Crash manifests on the next `vec_new<String>()` after the wrap.
- Estimated 30 min from clean tree to live crash.

**Existing test coverage gap:** No qspec exercises `arena_destroy` at TC-scale (4+ MB, 90K+ allocs). All current arena specs are sub-megabyte. A scale-stress qspec would not have caught D.2's regression.

**Tractability estimate:**
- 1h: reapply D.2 wrap + trigger crash + add canary footers to detect write-past-end
- 1h: if canaries fire, audit alignment math + boundary checks at the cited line ranges
- 1–2h: if canaries pass, switch to lldb session to inspect heap state at first-bad-malloc
- Total: ~4h if the cause is write-past-end (likely); deeper if libc-interaction (hypothesis 4) and needs mmap-backed chain headers as redesign.

**Recommendation: shelf unless reviving Phase D or a live user pattern hits it.** Real bug, real fix-cost, but currently dormant. Document the reproduction steps for the next pickup.
