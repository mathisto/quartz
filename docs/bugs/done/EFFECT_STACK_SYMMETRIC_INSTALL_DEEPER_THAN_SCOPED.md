# Tier 4 #26 — Symmetric effect-stack install/uninstall: parked (root cause was wrap-block leak, fixed)

**Status:** PARKED — instrumentation passes on 2026-04-29 revealed the peak was NOT a legitimate-deep-handler chain. Of 256 entries at peak, 248 were leaked `Diag` entries from a wrap-block teardown bug. Real fix shipped via [`DIAG_WRAP_BLOCK_LEAK_248_ENTRIES_AT_PEAK.md`](DIAG_WRAP_BLOCK_LEAK_248_ENTRIES_AT_PEAK.md) — post-fix peak is 134 with final-top-at-exit = 7 (no leak). Cap=256 now has 90% headroom; phantom-counter design is no longer needed for correctness, parked indefinitely. Document kept for instrumentation recipes (Recipes A + B in §"Instrumentation recipe").
**Backed-up binaries:**
- `self-hosted/bin/backups/quartz-pre-effect-stack-symmetric-golden` (pre-symmetric-attempt, fixpoint-verified, useful baseline for next attempt).
- `self-hosted/bin/backups/quartz-pre-instrument-max-top-golden` (pre-instrumentation, byte-identical to the symmetric-rollback golden — both reflect current source HEAD).

## Original scope (from handoff)

Replace `__qz_effect_handle_install`'s asymmetric overflow handling (skip both write AND increment when `top >= 256`) with a symmetric design (cap-gate the writes, increment unconditionally), so that install/uninstall pairs always balance. Add read-side clamps in `__qz_effect_perform`, snapshot-capture, snapshot-apply, and `wb.pretop` to keep all GEPs in `[0, 256)` even when the unbounded `top` exceeds the array cap. Estimated 30-40 LOC. Verification: `quake guard` + targeted qspec.

## What I tried

Five edits matching the handoff:

1. **codegen_runtime.qz:268-289** — install rewrite: cap-gate the do_push writes; move increment+store to a `merge_inc` block reached unconditionally.
2. **codegen_runtime.qz:999** — perform: clamp `%top` via `select i1 (icmp ugt %top_raw, 256), 256, %top_raw` to keep scan-loop GEPs in-bounds.
3. **codegen_runtime.qz:351** — snapshot_capture: same clamp on `%sc.top`.
4. **codegen_runtime.qz:435-441** — snapshot_apply: replace `%sa.pushed = sgt post_top, pre_top` (always-true under symmetric install) with `%sa.fits = ult pre_top, 256` to gate state-slot writes.
5. **codegen_instr.qz:2106-2108** — with-block: clamp `%wb.pretop` to `(256 - entry_count)` so derived `pretop+K` indices stay in `[0,256)` for all K in [0,N).

Each edit on its own and in combinations was tested via `quake guard`.

## What broke

**`quake guard` Gen1→Gen2 fails consistently.**

| Edits applied | Symptom |
| --- | --- |
| Edit 1 only | Gen1 SIGSEGV in `__qz_effect_cstr_eq(NULL, ...)` called from `perform`, while typechecking `tc_expr_call` |
| Edits 1-4 (no `wb.pretop` clamp) | Gen1 SIGSEGV (same) |
| Edits 1-5 (full set) | Gen1 exits 66 with "unhandled effect op called" via `__qz_effect_unhandled` (not the prelude Throws default) |

Critical observation: when I manually edited `tmp/guard_gen1.ll` to revert ONLY the install function back to the OLD (asymmetric) IR, leaving everything else (including the read-side clamps) NEW, the manually-patched Gen1 self-compiles successfully (1.84M lines of valid Gen2 IR output, exit 0). So the install change is the load-bearing breaker — the read-side clamps are a no-op (good) when install stays asymmetric, but turn into actual semantic changes when install is symmetric.

Crash backtrace (SIGSEGV form):

```
__qz_effect_cstr_eq(NULL, "...const_RESOLVE_TAG_EFFECT_DECL+25608")
__qz_effect_perform (offset 140)
typecheck_expr_handlers$tc_expr_call
typecheck_walk$tc_expr
typecheck_walk$tc_stmt × ~6
typecheck_walk$tc_function
compile → do_build → qz_main → main
```

The faulting address is `0x0` — perform read `stack_names[iprev] == 0` and called `cstr_eq(NULL, eff)`. Under Edits 1-5 the clamp prevents this OOB read but exposes a worse semantic: phantom installs at depth ≥256 are unreachable to perform, so user-installed handlers above the cap don't fire and we hit the "unhandled" path instead.

## Why this is harder than scoped

The handoff (and `feedback_effect_stack_asymmetry.md`) treats the cap as 7.7× headroom over the observed self-compile maximum of 33 entries, so symmetric install was framed as defensive correctness work for a regime that doesn't currently exercise. The crash data contradicts that: **self-compile under NEW symmetric install depends on phantom-install handling for correctness**, which implies one of:

1. Self-compile actually does exceed 256 nesting depth (the "max=33" measurement is stale or was wrong), OR
2. My edits introduced a subtle bug that breaks behavior in the [0,256) range as well.

I could not distinguish these two without instrumenting the install function to record the actual max top reached during self-compile, and that instrumentation requires another full guard cycle (~5 minutes per attempt) plus careful printf-style emission into the runtime IR.

## Designs considered but not finished

### Naive symmetric (what I tried — broken)
Always-increment, cap-gate writes, read-side clamps. **Problem:** at >cap depth, perform's clamped scan never sees the phantom installs, so user `with E { } do ... end` blocks at deep nesting fail to handle their own performs. Worse than the OLD asymmetric design for the >cap regime.

### Phantom counter design (sketched, not built)
Add a TLS counter `@__qz_effect_phantom_count`. Install: if `top < 256`, write+increment top as today; else, increment phantom_count. Uninstall: if phantom_count > 0, decrement it; else decrement top.

**Pro:** push count == pop count without growing top above cap. Read sites (perform, snapshot capture, with-block pretop) stay raw — no clamps needed.

**Cons:**
- Requires a parallel change to `__qz_effect_handle_uninstall` (currently a 4-line decrement).
- `snapshot_apply` returns `delta = end_top - start_top` consumed by worker $poll's `top -= apply_count` restore (memory: `feedback_e1cb_apply_count_vs_save_top.md`). Under phantom counter, real_pushes != snap.count when overflow occurs in the snapshot — caller's restore needs to drain both top AND phantom_count.
- `wb.pretop` capture still has the OOB-derived-GEP problem at pretop=256. Edit 5's clamp is still needed to clamp pretop down.
- Snapshot apply's state-slot write should still gate on `pre_top < 256`.

### Bump cap to 1024
~50 literal occurrences of `256` / `[256 x i64]` across `codegen_runtime.qz` and `codegen_instr.qz`. Sidesteps the symmetric-install design question entirely if max depth is in [33, 1024). Doesn't fix the asymmetry; just gives more headroom.

## Concrete next steps for next session

1. ~~**Instrument first.**~~ **DONE 2026-04-29.** Two passes:
   - **Pass A** (max-top tracker): max top = 257 (cap+1).
   - **Pass B** (full-stack dump at peak): of the 256 entries, slots 0-6 are prelude defaults (blessed_watermark=7), slot 7 is `State`, **slots 8-255 are `Diag` × 248**. Pattern: 248 zombie Diag handlers shadowed top-down by the live one at slot 255.

2. **Decision pivot.** The peak is NOT a legitimate-deep-handler chain. It is a Diag wrap-block teardown leak. Filed as new root cause in `DIAG_WRAP_BLOCK_LEAK_248_ENTRIES_AT_PEAK.md`. **Phantom counter is the WRONG fix** — it would paper over a real lifecycle bug that could resurface for any other effect that leaks at scale.

3. **Subordinated:** Phantom counter design (sketched below) is parked. Once the Diag leak is fixed and re-measurement shows a sane peak (probably <50, matching the older "install never sees >40" comment in codegen_runtime.qz:482), re-decide whether the cap=256 design is sufficient or whether symmetric+phantom is still worth doing for defensive correctness. Likely outcome: cap=256 is sufficient post-leak-fix; symmetric+phantom is filed as a low-priority hardening item.

4. **Don't forget the static-fast-path stores in codegen_instr.qz:1937-1939, 1995-1997.** Reusable for a future symmetric-design attempt. They write `%wb.pretop` into `@__qz_effect_current_install_idx`. State-accessor reads of that idx at codegen_runtime.qz:1206/1316/1326/1351/1357/1373 derive their GEPs from it. Under any design where pretop can exceed cap, those reads OOB — Edit 5 (with-block pretop clamp) handles it indirectly by clamping pretop at the source.

## Instrumentation recipe (verified working)

Two recipes — both purely additive (write-only globals; never read by non-instrumentation code; fixpoint-safe). Verified 2026-04-29 on darwin.

### Recipe A: max-top printout

If you need just the max-top number, four edits get you a single number in `tmp/guard_gen2.err`.

**`self-hosted/backend/codegen_runtime.qz`**
- After `linkage_alloc_bw` declaration in **both** the linkonce branch (≈ line 188) and the else branch (≈ line 206), add: `@__qz_effect_max_top = (linkonce_odr|internal) thread_local global i64 0, align 8`
- In `__qz_effect_handle_install` entry block (≈ line 270), after `%top = load i64, ptr @__qz_effect_stack_top, align 8` and before the `%fits = icmp slt` line, add a 5-instruction max-bump:
  ```
  %inst.tp1 = add i64 %top, 1
  %inst.mt_old = load i64, ptr @__qz_effect_max_top, align 8
  %inst.mt_need = icmp sgt i64 %inst.tp1, %inst.mt_old
  %inst.mt_new = select i1 %inst.mt_need, i64 %inst.tp1, i64 %inst.mt_old
  store i64 %inst.mt_new, ptr @__qz_effect_max_top, align 8
  ```

**`self-hosted/backend/codegen.qz`**
- In **both** `cg_codegen` (≈ line 1137) AND `cg_codegen_debug` (≈ line 1284) main wrappers, after `%result = call i64 @qz_main()` and before the `%result32 = trunc` line, add:
  ```
  %mt.val = load i64, ptr @__qz_effect_max_top, align 8
  call void @eprint_int(i64 %mt.val)
  ```
  `@eprint_int` is unconditionally emitted by `cg_emit_runtime_decls` and writes `%ld\n` to stderr.

**Capture protocol:** `quake guard` deletes `tmp/guard_gen2.err` on success. To intercept it, run guard in the background and copy `tmp/guard_gen2.err` to a stable path while guard is still running:
```
./self-hosted/bin/quake guard 2>&1 &
GPID=$!
( while kill -0 $GPID 2>/dev/null; do
    [ -s tmp/guard_gen2.err ] && cp tmp/guard_gen2.err /tmp/saved_gen2.err
    sleep 1
  done ) &
WPID=$!
wait $GPID; kill $WPID
grep -E '^[0-9]+$' /tmp/saved_gen2.err
```
The single numeric line at the end is the max top.

### Recipe B: full-stack dump at peak

Adds a `__qz_effect_dump_at_peak(i64 %top)` helper that fires once when `top >= 256`, prints `=== EFFECT STACK DUMP at peak ===` + `top=N blessed=N` + `[i] <name>` per slot to stderr. Hardcoded macOS (`@__stderrp`) — diagnostic-only.

In addition to Recipe A's edits, add to the linkonce branch (and mirror to the else branch):
```
@__qz_effect_peak_dumped = ... thread_local global i64 0, align 8
@__qz_effect_dump_item_fmt = ... unnamed_addr constant [10 x i8] c"[%ld] %s\0A\00", align 1
@__qz_effect_dump_hdr = ... unnamed_addr constant [34 x i8] c"=== EFFECT STACK DUMP at peak ===\0A", align 1
@__qz_effect_dump_meta_fmt = ... unnamed_addr constant [21 x i8] c"top=%ld blessed=%ld\0A\00", align 1
```

In install entry, after the max-top bump, add:
```
call void @__qz_effect_dump_at_peak(i64 %top)
```

Insert helper definition between `__qz_effect_handle_install` and `__qz_effect_handle_uninstall`. The body:
```
entry → check threshold (top >= 256) → check_flag (peak_dumped == 0) → do_dump
  do_dump: store flag, write header (@write fd=2, len=34), fprintf meta line
  loop_check / loop_body / loop_print / loop_continue → fprintf "[i] %s\n" per non-null slot
  d_ret: ret void
```

See git history of this session for the verified IR (rolled back; not committed). Capture protocol same as Recipe A.

**Important:** the helper hardcodes `@__stderrp` for `cg_emit_effect_runtime` doesn't take `target` as a parameter. To run on Linux, either thread `target` through the function signature OR refactor to use `@write` exclusively (skipping fprintf, which would also remove the format-string complexity but lose the `[i]` decoration in the per-slot output).

## Verification baseline (proven working pre-edit)

`backups/quartz-pre-effect-stack-symmetric-golden` (sha-256 not pinned but file present) compiles self successfully (exit 0, ~1.8M LL lines), passes fixpoint with the matching pre-edit source. Tested via `quake guard` after the rollback.

## Memory note

`feedback_effect_stack_asymmetry.md` should be updated to reflect that symmetric install was attempted and rolled back; the FileIo/Intern wrap-deletion bug is still resolved by the cap=256 expansion (Apr 23) but the underlying asymmetry remains as latent risk for any future regression that increases nesting depth.
