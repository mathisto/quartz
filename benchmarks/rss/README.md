# RSS measurement snapshots

CSV snapshots emitted by `tools/measure_rss.qz`. Filed 2026-05-01 as the
substrate for Phase A.2 P2 (Slice<Byte> sweep) gating decisions and Phase
B.1 (compiler memory <1 GB) hot-path attribution.

## Schema

`name,rss_mb,peak_mb,wall_ms,samples` — one row per phase, all numbers
medians across `samples` runs.

## Files

- `style_demo_pre_a2_p1.csv` — `quartz-pre-a2-slice-prefix-golden` (saved
  2026-05-01 00:23, source state at commit `307cbdcb`) compiling
  `examples/style_demo.qz`. 3 runs. Light-workload baseline; small
  signal floor.
- `style_demo_head.csv` — current `self-hosted/bin/quartz` compiling
  `examples/style_demo.qz`. Refresh with `quake bench_rss`. Light
  workload.
- `quartz_qz_head.csv` — current binary compiling `self-hosted/quartz.qz`
  (full self-host, ~2446 functions, peak 2447 MB at codegen, ~55s wall
  median). The heavy-workload reference. Refresh by running
  `tools/measure_rss.qz --binary self-hosted/bin/quartz --workload
  self-hosted/quartz.qz --runs 3 --include-flags <full-include-set>
  --emit-csv benchmarks/rss/quartz_qz_head.csv`.
- `quartz_qz_pre_a2_p1.csv` — captured 2026-05-01 from a worktree binary
  built with `7ce448d6`+`c2caee4e` reverse-applied to working tree
  (`git apply -R`, no commit), then `quake build`. Same workload as
  `quartz_qz_head.csv`. **Empirical record** for A.2 P2's gating
  decision: the −1 MB peak / +15 ms wall delta vs HEAD shows A.2 P1's
  prefix-check migration produced no measurable RSS savings at heavy-
  workload scale, closing the gating question against P2.
- `quartz_qz_alloc_track.txt` — captured 2026-05-01 from `--alloc-track
  --memory-stats` heavy-workload run with B.1 Phase 2 instrumentation
  (4 chokepoints: `cg_emit_line` / `cg_emit` / `cg_emit_int` /
  `mir_new_instr`). **Empirical record** for B.1 Phase 2's
  attribution decision: the 4 chokepoints attribute 125 MB / 1244 MB
  codegen peak gap (10%); cumulative emit volume (89 MB) ≈ final IR
  size (80 MB) → StringBuilder doesn't double-grow → "IR-buffer
  doubling = peak" hypothesis empirically rejected. The structural
  explanation is that codegen runs inside a single whole-codegen
  Alloc arena (`quartz.qz:1010-1019`) so peak = sum of all codegen
  allocs. Selected Phase 3 intervention: per-function arena dogfood
  (see `docs/design/B1_ALLOC_ATTRIBUTION.md` Phase 2 section). Note:
  with `--alloc-track` ON, peak inflates by ~280 MB (perform-effect
  dispatch overhead × 8.9M calls) — re-measure post-Phase-3 with
  flag OFF for apples-to-apples comparison vs `quartz_qz_head.csv`.
- `quartz_qz_alloc_track_phase4.txt` — captured 2026-05-01 from B.1
  Phase 4 Path B's per-phase IR-text bookend instrumentation. 17
  bookends + 4 chokepoints attribute ~30% of peak gap; per-phase
  IR-text deltas localize 96% of IR text to `phase_function_loop`
  but reveal nothing about non-IR-text arena allocators (interp
  intermediates, slice tails, etc.). Motivated Phase 5.D's switch
  from sb_size-delta to arena_bytes_used-delta bookends.
- `quartz_qz_b1_phase4.csv` — Phase 4 Path B instrumentation OFF
  (3-run median): 2453 MB peak / 56332 ms wall. The OFF baseline
  Phase 5.A measured against (-123 MB peak via pre-grown master out).
- `quartz_qz_b1_phase5a.csv` — Phase 5.A's 3-run median (2026-05-02
  00:05): 2330 MB peak / 56806 ms wall. Pre-grown master out
  intrinsic + 128 MB upfront alloc.
- `quartz_qz_alloc_track_phase5d.txt` — Phase 5.D arena bookend
  capture (2026-05-02 01:26). Headline: `arena_extern_decls = 1.38 GB`,
  attributing ~96% of the prior unattributed peak gap to a single
  call to `cg_emit_extern_declarations`. Post-fix re-capture (in same
  file): `arena_extern_decls = 1488 bytes` — 99.99989% drop.
- `quartz_qz_b1_phase5d.csv` — Phase 5.D bookends + slice-quadratic
  fix instrumentation OFF (3-run median, 2026-05-02 01:24): 1293 MB
  peak / 63024 ms wall.
- `quartz_qz_b1_phase5e.csv` — Phase 5.E master_out outside arena +
  sb scan path OFF (3-run median, 2026-05-02 02:25): **1217 MB peak /
  57120 ms wall**. Apples-to-apples vs Phase 5.D in the same session
  (same machine state): **-76 MB peak (-5.9%) / -5904 ms wall (-9.4%)**.
  The wall delta is real — the eliminated `out.to_string()` in-arena
  copy + redundant `arena_promote_string(llvm_ir)` together represented
  ~80 MB of memcpy work that no longer happens. **The headline
  shipping snapshot.**
- `quartz_qz_phase5a_drift_baseline.csv` — Phase 5.A binary
  re-measured at the same machine state as Phase 5.D (2026-05-02
  01:30): 2611 MB peak / 61935 ms wall. Captures macro drift
  between the original Phase 5.A snapshot (00:05, 2330 MB) and the
  post-Phase-5.D measurement (01:24, 1293 MB) — the Phase 5.A
  binary itself drifted +281 MB across the session. Apples-to-apples
  Phase 5.D win vs this drift-baseline: **-1318 MB peak (-50.5%) /
  +1.1s wall**.
- `quartz_qz_phase5d_drift_baseline.csv` — Fresh Phase 5.D-equivalent
  binary (built from `git apply -R 9cf67891 ...`-reverted source via
  `quake build`, then captured against Phase-5.D-state source) at the
  same machine state as Phase 5.E (2026-05-02 02:39): **1292 MB peak
  / 63389 ms wall**. Drift between the original Phase 5.D snapshot
  (01:24, 1293 MB) and this drift-baseline (02:39, 1292 MB) is just
  -1 MB peak / +365 ms wall — within run-to-run noise. Apples-to-
  apples Phase 5.E win vs this drift-baseline: **-75 MB peak (-5.8%)
  / -6269 ms wall (-9.9%)**, confirming the Phase 5.E commit message's
  -76 MB / -5904 ms numbers were solid (drift wasn't masking a smaller
  real win).

## Heavy-workload measurement recipe (canonical)

For "did this perf optimization actually move heavy-workload peak?"
questions, the apples-to-apples sprint is ~30 min:

```bash
# 1. Worktree
git worktree add .claude/worktrees/<name> -b <name>
cd .claude/worktrees/<name>

# 2. Reverse-apply target commit(s) to working tree (skips pre-commit hook)
git show <commit> -- 'self-hosted/middle/*.qz' | git apply -R --reject
git show <other-commit> -- 'self-hosted/backend/*.qz' | git apply -R --reject

# 3. Build (use `quake build`, NOT `quake guard` — we throw this binary away)
./self-hosted/bin/quake build
cp self-hosted/bin/quartz /tmp/quartz-<label>

# 4. Exit worktree, measure both binaries from main
cd ../../..
/tmp/_quake_measure_rss --binary /tmp/quartz-<label> \
  --workload self-hosted/quartz.qz --runs 3 \
  --include-flags "<full-include-set>" \
  --emit-csv benchmarks/rss/quartz_qz_<label>.csv
/tmp/_quake_measure_rss --binary self-hosted/bin/quartz \
  --workload self-hosted/quartz.qz --runs 3 \
  --include-flags "<full-include-set>" \
  --emit-csv benchmarks/rss/quartz_qz_head.csv

# 5. Compare CSVs side-by-side (codegen peak_mb is the headline)
```

## Why `style_demo` is light

The pre-A.2 binary cannot compile current `self-hosted/quartz.qz` (the
prelude's `import * from std/gen` doesn't resolve through that older
binary's resolver). `examples/style_demo.qz` is the largest workload
that pre-A.2-source binaries can compile cleanly with `-I std -I .`.
But it exercises hot paths only ~5× per compile vs ~2400× on full
self-host — so style_demo measures the bytecode pipeline correctness
of the harness, not the actual perf gradient. Use the heavy-workload
recipe above for any optimization decision, not the style_demo CSVs.

## Refreshing

```bash
# Build the tool + run on style_demo + diff against the A.2 P1 baseline
./self-hosted/bin/quake bench_rss_diff

# Capture a new HEAD snapshot
./self-hosted/bin/quake bench_rss

# Manual run with custom workload + include flags
/tmp/_quake_measure_rss \
  --binary self-hosted/bin/quartz \
  --workload self-hosted/quartz.qz \
  --runs 3 \
  --include-flags "-I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend -I self-hosted/error -I self-hosted/shared -I tools -I std" \
  --emit-csv benchmarks/rss/quartz_qz_head.csv
```
