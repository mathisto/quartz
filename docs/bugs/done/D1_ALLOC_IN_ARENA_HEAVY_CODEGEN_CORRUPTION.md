# `with Alloc.in_arena(arena) do -> heavy_codegen() end` corrupts emitted IR

**Status**: 🟢 RESOLVED — root cause identified, fix landed, fixpoint preserved.
**Filed**: 2026-04-27 during D.1 implementation attempt.
**Resolved**: 2026-04-27 same-day chase via D1.5 user-level repro.
**Discovered by**: First attempt to wrap `cg_codegen_debug` in compile() with `with Alloc.in_arena(cg_arena) do -> ... end`.

## Resolution summary

**Root cause**: The `@to_str` runtime function (called by interpolation desugar's `to_str(expr)` wrapper at `parser.qz:1178-1182`) uses an alignment-based heuristic to distinguish String pointers from Int values:

```llvm
%low4 = and i64 %val, 15
%is_aligned = icmp eq i64 %val, 8     ; (val & 15) == 8
br i1 %is_aligned, label %check_range, label %int_path
```

This invariant relies on libc malloc returning 16-byte-aligned pointers and `qz_alloc_str` adding 8 (for the length prefix), yielding `(data_ptr & 15) == 8`. The arena allocator at `cg_intrinsic_memory.qz:584-589` rounded sizes to **8-byte multiples** (`add 7; and -8`), producing 8-byte-aligned-but-not-16-byte-aligned data pointers. After `qz_alloc_str`'s +8, those data pointers landed at `(val & 15) == 0` — the heuristic FAILED → `to_str` fell through to `int_path` → ran `sprintf("%lld", val)` → printed the **pointer address** as decimal instead of the String content.

**Fix**: Round arena allocations to 16-byte multiples. One-line change in `cg_intrinsic_memory.qz`:

```diff
-    codegen_util::cg_emit_line(out, ", 7")
+    codegen_util::cg_emit_line(out, ", 15")
...
-    codegen_util::cg_emit_line(out, ".size.aligned, -8")
+    codegen_util::cg_emit_line(out, ".size.aligned, -16")
```

This restores the libc-malloc alignment invariant for arena-routed allocations, so `qz_alloc_str`'s +8 yields `(val & 15) == 8` consistently, regardless of routing mode.

**Why user-level density specs (D1.1–D1.4) didn't catch it**: They built Strings via `sb_append` directly. The interpolation desugar's `to_str(...)` wrapper is the load-bearing ingredient — `"...#{expr}..."` always wraps `expr` in `to_str(expr)` even when the parser knows it's already a String, because the wrapper is unconditional at parse time. **D1.5 (`interpolation inside +=`) is the test that reproduces the bug at user level.**

**Fixpoint**: 2347 functions byte-identical (gen1 == gen2). All 12 alloc specs pass; B.1 + A.5 byte-count assertions updated for 16-byte alignment.

**Cost**: Average ~4 wasted bytes per arena allocation (size `(s+15)&-16` instead of `(s+7)&-8`). At Phase C's 1.92 GB self-compile peak, this is well below the noise floor; the alignment overhead is dwarfed by the RSS reduction Phase D delivers.

**Phase D.1 unblocked**: Next session can ship the proper compile() arena wrap (with `arena_promote_string` for `llvm_ir`/`extern_decls` escape + `arena_destroy`).

---


## TL;DR

When `Alloc.in_arena(arena)` is installed around a heavy codegen pass (~1.8M lines of IR worth of String concat / `Int.to_s()` / sb_append), the generated IR is silently corrupted: register names and `, !dbg !N` debug suffixes get truncated and replaced with what look like 10-digit ASCII representations of heap pointer addresses.

The bug is **specific to in_arena handlers + heavy codegen + --debug**. None of the existing alloc specs (B.1 in_arena, B.2 TestAlloc, A.5 stdlib handlers) reproduce because they don't generate codegen-density allocation traffic inside the arena.

## Reproduction

Restore the pre-D.1 golden, edit `self-hosted/quartz.qz` to wrap the `--debug` codegen path:

```qz
elsif debug_mode == 1
  var cg_arena = arena_new()
  with Alloc.in_arena(cg_arena) do ->
    llvm_ir = codegen::cg_codegen_debug(mir_prog, filename, target, all_funcs, overflow_check, stack_alloc, race_mode)
    0
  end
end
```

Plus `import * from std/alloc` and `import * from std/memory` at the top.

Build with golden gen0 (do not build with a previously-broken gen1 — corruption propagates):
```bash
cp self-hosted/bin/backups/quartz-pre-d1-codegen-arena-golden self-hosted/bin/quartz
./self-hosted/bin/quake build
./self-hosted/bin/quartz --debug --no-cache /tmp/d1_smoke.qz > /tmp/out.ll
llc -filetype=obj /tmp/out.ll -o /tmp/out.o
```

`/tmp/d1_smoke.qz` is just `def main(): Int = 0` — even a trivial program reproduces.

llc fails with:
```
llc: /tmp/out.ll:2736:52: error: expected instruction opcode
  %v6.cres = call i64 %v6.cfn(i64 %v6.env, i64 %v4)4355337280
                                                   ^
```

The trailing `4355337280` is an ASCII representation of an i64 ≈ 0x101D7E480 — a typical macOS heap pointer address.

## What's corrupted

`grep -c '%v[0-9]\{6,\}'` on the output shows ~32 corrupt register names. Examples:

```
%v6.cres = call i64 %v6.cfn(i64 %v6.env, i64 %v4)4355337280     ← dbg_suffix lost ", !dbg !"
%v6.pres = call i64 %v6.pfn(i64 %v4355338224)4355337280         ← arg.to_s() produces giant number
%v4344696288.cres = call i64 %v4344696288.cfn(...)              ← dest.to_s() produces giant number
```

Two distinct symptoms:
1. **Register name corruption**: `arg.to_s()` and `dest.to_s()` (both Int → String via `@str_from_int` runtime call) return Strings whose bytes are 10-digit decimal numbers in the macOS heap range.
2. **Debug-suffix prefix loss**: `dbg_suffix = ", !dbg !#{loc_id.to_s()}"` produces a String containing only the digit suffix, missing the `, !dbg !` literal prefix. (Some lines have correct `, !dbg !53`; others have just `4355337280`. Inconsistent.)

The 10-digit numbers form a clustered series within ~4 KB of each other (e.g., `4344611856`, `4344612496`, `4344728816`, `4344795120`) — consistent with sequential arena allocations within one or two arena blocks.

## What I've verified via narrowing probes

All probes built from the **clean pre-D.1 golden** (rebuilt fresh — corruption propagates through self-hosting if a tainted gen1 builds gen2):

| Probe | Setup | Result |
|---|---|---|
| Imports + `cg_set_last_string_pool` setter, no with-block | Clean gen1 + clean test output | ✓ no corruption |
| `arena_new()` before codegen, no with-block, no destroy | ✓ no corruption | the call alone is fine |
| `with Alloc.in_arena(ar) do -> 0 end` (empty body) before codegen + `arena_destroy(ar)` | ✓ no corruption | install/uninstall + destroy alone are fine |
| `with Alloc { alloc: default_alloc_handler, dealloc: default_dealloc_handler } do -> codegen(); 0 end` | ✓ no corruption | with-block + DEFAULT handlers around codegen are fine |
| `with Alloc.in_arena(ar) do -> codegen(); 0 end`, no destroy, no promotes | ✗ **corrupt** | bug surfaces here |
| `with Alloc.in_arena(ar) do codegen() end` (no-arrow form) | ✗ **corrupt** | not body-wrap-rule-related |

**Conclusion**: the bug surfaces ONLY when `arena_alloc_handler_e` / `arena_dealloc_handler_e` are installed AND a heavy codegen pass runs INSIDE the with-block AND `--debug` is set.

The default Alloc handlers (which just forward to `mem_alloc`/`mem_free`) work correctly under identical heavy-codegen load. So the install/uninstall machinery, the effect-stack discipline, the with-block lowering, and codegen itself are all fine in isolation. The bug is in the **arena-handler / codegen-allocation-density interaction**.

## Hypotheses (none confirmed)

1. **`arena_alloc` allocation-overlap under high frequency.** arena_alloc bumps an offset within the current 4 KB block. If the offset arithmetic has an off-by-one with specific size patterns produced by codegen (Strings of variable length, all going through `qz_alloc_str` which adds 9 bytes), two consecutive String buffers might overlap. The first String's bytes get overwritten by the second's allocation header. B.1 specs allocate uniform sizes; codegen allocates wildly varying sizes.

2. **Effect-stack pressure.** Codegen does many internal `with Emit { ... } do -> ... end` installs, plus per-function or per-block sub-effects. With my outer Alloc install on top of the prelude defaults plus codegen's internal installs, the depth could climb to dozens. The `__qz_effect_stack_state_slots[256]` cap (post-`a6f174ae`) shouldn't overflow at that depth, but maybe an intermediate index off-by-one corrupts state_slots.

3. **TLS interaction with codegen's nested effect-perform calls.** `__qz_effect_current_install_idx` is TLS, set by `__qz_effect_perform` before each handler dispatch. If a re-entrant perform (e.g., Alloc handler runs Alloc internally for arena chain growth) clobbers the TLS without restore, state_get returns the wrong slot value → `arena_alloc(handle=0, size=N)` → bogus pointer.

4. **Sprintf buffer reuse.** `@str_from_int` does `tmp = __qz_alloc(32); sprintf(tmp, "%lld", n); buf = qz_wrap_cstr(tmp); dealloc(tmp)`. In arena mode, dealloc is a no-op, so the 32-byte tmp lingers. If a SUBSEQUENT `__qz_alloc(N)` happens to return a pointer into that 32-byte region (which would only happen with an arena bug), sprintf-buffer reuse could explain digit-shaped bytes appearing in seemingly-unrelated Strings.

The first two are most plausible. (4) requires an actual arena bug; (3) requires a TLS-clobber path that B.0a's per-with-block save/restore was supposed to close.

## Next-session debugging plan

1. **Reproduce with smaller workload**. Cut codegen down to a single function emit, see if ANY corruption appears. If yes, narrow to a single intrinsic call. If no, the bug is density-dependent.

2. **Trace arena_alloc returns**. Instrument arena_alloc handler (in std/alloc.qz) with stderr prints of (handle, size, returned_ptr) for the first 1000 calls. Look for non-monotonic pointers (would indicate aliasing).

3. **Check for arena chain-growth path.** Add a stderr print in arena_alloc IR (at `arena_alloc_chain_<d>:` label) so we know when block growth happens. If chain growth correlates with corruption, the bug is in chain-walking.

4. **Force arena to use giant initial blocks**. Modify `arena_new()` (or use `arena_new(1048576)` if arg is honored) to allocate a 1 MB block. If corruption disappears, the chain-growth path is suspect.

5. **Try with `--no-opt` only, no `--debug`**. The bug only reproduces with `--debug`. The debug path adds DILocation + dbg_suffix logic. Maybe debug-info specific runtime allocations are the culprit. Test without `--debug` to isolate.

6. **TLS save/restore audit.** Walk every `__qz_effect_current_install_idx` write site in `codegen_runtime.qz` and confirm save/restore is symmetric. The B.0a per-with-block save/restore was for the BYPASS-FLAG TLS — extending the same shape to install_idx might be the missing piece.

## Workaround / scope-down options for D.1

**Option A**: Skip arena dogfood entirely. Defer Phase D until the bug is fixed. RSS stays at 1.92 GB — Phase D's value isn't recoverable.

**Option B**: Use a custom non-arena Alloc handler that batches small allocations differently. E.g., a "bump arena" written in pure Quartz (not via the `arena_*` intrinsics) that uses raw `mem_alloc(huge_block)` + manual offset bumping. Sidesteps arena_alloc's intrinsic. Effort: ~half-day.

**Option C**: Wrap a SUBSET of codegen — specifically, only the parts that don't go through the corruption path. Probably impossible without finding the exact corruption trigger first.

**Option D** (followup of 2026-04-27, in tree at `spec/qspec/d1_arena_codegen_repro_spec.qz`): User-level density spec covers four shapes — sb_append + `str_from_int` (100 iters), codegen-shaped IR text with register/dbg interleave (200 iters), plain `+` concat (50 iters), and nested `with Throws` adding effect-stack pressure (100 iters). **All four tests pass under fixpoint 2347.** Significance: B.1's `Alloc.in_arena` mappings extend cleanly to user-level density patterns matching codegen's shape — the substrate bug is NOT reachable via "heavy String + SB + concat traffic in an arena" alone. The bug needs the compiler-internal regime: codegen's specific allocation sequence + effect-stack depth (many nested `with Emit { ... }` installs the user can't reach) + ~1.8M-line volume. This narrows the hypothesis space:

- **Eliminated**: Hypothesis 1 (arena_alloc offset arithmetic with variable-size patterns) — the spec drives variable-size patterns, all clean.
- **Eliminated**: Hypothesis 4 (sprintf buffer reuse via `@str_from_int`) — the spec drives heavy `str_from_int`, all clean.
- **Still live**: Hypothesis 2 (effect-stack pressure from codegen's internal Emit installs nested under outer Alloc) — user-spec nesting was 2 levels deep; codegen nests dozens.
- **Still live**: Hypothesis 3 (TLS interaction with re-entrant performs in arena handler) — possible but harder to surface at user level.
- **New live hypothesis**: dbg-mode-only codegen path. Bug only reproduces with `--debug`. The dbg-suffix construction (`dbg_suffix = ", !dbg !#{loc_id.to_s()}"`) runs hundreds of thousands of times under `--debug` and not at all without it. If the issue is pressure-driven, the dbg-suffix's allocation density is the natural amplifier. Step 5 of next-session plan (re-stage D.1, compile WITHOUT `--debug`) directly tests this.

Spec retained as regression coverage for B.1's user-level surface.

## Cross-links

- `docs/design/ALLOC_EFFECT_PLAN.md` — Phase D plan, now blocked at D.1.
- `feedback_rss_deltas_overstate_live_set.md` — measurement methodology Phase C used.
- B.0a fix (`2bdc3832`) — bypass-flag save/restore precedent.
- `feedback_static_fastpath_tls_discipline.md` — pattern for TLS save/restore around handler calls.
- `feedback_effect_stack_asymmetry.md` — prior effect-stack bug.

## State at resolution (2026-04-27)

- D.0 (`arena_promote_string` helper) shipped at `65b5a1cd`. Retained for D.1 proper.
- Substrate fix landed in same session this bug was filed (16-byte alignment in `cg_intrinsic_memory.qz`).
- D1.5 user-level repro spec (`spec/qspec/d1_arena_codegen_repro_spec.qz`) goes from RED to GREEN with the fix and stays in tree as regression coverage.
- Two existing specs needed byte-count updates for 16-byte alignment: `alloc_in_arena_b1_spec.qz` (B1.2 nesting + B1.3 sequential) and `alloc_stdlib_handlers_a5_spec.qz` (`_ARENA_BASIC`).
- Fix-binary preserved at `self-hosted/bin/backups/quartz-d1-arena-16align-fix`.
- Fixpoint 2347 byte-identical at the fix commit.
