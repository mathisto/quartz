# Alloc Effect + Arena Dogfooding — Design Memo

> **Status**: 🟢 PHASE A + B + C + D.0 + D.1-substrate + D.1-proper + D.x + E.1.a + **E.1.c SHIPPED 2026-04-28** — multi-worker effect-stack TLS fix. All effect-stack arrays (`__qz_effect_stack_top`, `_names`, `_handlers`, `_op_filters`, `__qz_alloc_blessed_watermark`) flipped to thread-local. `cg_emit_effect_install_defaults` extracted from inline-into-main-prelude into a callable `@__qz_effect_install_defaults` function emitted by `cg_emit_effect_runtime`. Called both from qz_main entry AND from each scheduler worker's `__qz_sched_worker` entry block — every worker now boots with the blessed defaults installed in its own TLS effect stack. Parallel `go_arena` under `sched_init(0)` no longer races; alloc_e1 spec E1.c flipped from `sched_init(1)` to `sched_init(0)` and passes 5/5; 5/5 standalone parallel smoke runs green; fixpoint 2393 functions byte-identical (+1 from the new `__qz_effect_install_defaults`). Bug doc updated to RESOLVED. **Semantic shift introduced**: handlers installed on main thread are no longer visible to spawned goroutines (each worker has its own TLS effect stack starting with only blessed defaults). Matches OCaml 5 effect handlers + multicore fibers, where `with` is dynamic-extent of the calling thread. Two scheduler+effects spec tests rewritten to install handler INSIDE goroutine body via a wrapper function (`my_gen_with_handler` pattern); one nested test (`p4b3_suspend`'s interleave) `it_pending`'d — exposes a pre-existing kind=3 resume(0) + with-block-in-goroutine bug filed cleanly at `docs/bugs/KIND3_RESUME_INTERLEAVE_IN_GOROUTINE.md`. Spec sweep: 73/74 alloc tests green; concurrency_spec 16s green; concurrency_advanced 15/15; async_iterator 27/27 (was 15/27 baseline — the worker-effect-stack TLS fix may have inadvertently resolved earlier scheduler bugs). **Phase E.1.a (earlier same day)** — `go_arena(f)` opt-in stdlib API for per-task arenas. 5 tests at `spec/qspec/alloc_e1_per_task_arena_spec.qz` cover the basic + isolation + parallel + sequential-leak-free + sentinel-passthrough behaviors. Outer `Alloc` tracking handler observes 7 allocations from a 200-Vec.push direct call, only 2 from the same call wrapped in `go_arena` — the bulk of inner allocations land in the per-task arena and free at task end via `arena_destroy`. Implementation: 30-line stdlib-only addition to `std/concurrency.qz` (`go_arena(f)` + `_go_arena_body(f)` helper). NO compiler change required. **E.1.a documented limitations**: (a) tasks must return value-typed data, reference-typed returns dangle after arena_destroy → Phase E.4 (escape mechanism); (b) truly-parallel `go_arena` tasks under `sched_init(0)` race on global `__qz_effect_stack_top` → Phase E.1.c (TLS top + per-worker prelude install); (c) `go fn()` keyword does NOT auto-arena → Phase E.1.b (compiler change to extend frame layout + inject install/uninstall in $poll). **Honest scope readjustment from memo's "1-2 quartz-day" estimate**: full E.1 (auto via keyword + escape + multi-worker safe) is multi-session compiler work. E.1.a ships the capability via opt-in TODAY; the keyword-auto + escape + concurrency fixes phase in across follow-up sessions.
>
> **D.2 ATTEMPTED + REVERTED 2026-04-27** — measurement showed the arena's no-free-back model is a NET LOSS for high-churn workloads like TC (1265 MB live working set in arena vs 617 MB libc retention; libc reuses freed memory, arena doesn't). Design memo's "50-70% recovery factor" (`feedback_rss_deltas_overstate_live_set`) was wrong; the +617 MB libc TC delta is fragmentation, not recoverable working set. D.x optimization (chain-block-size 4 KB → 64 KB + last-fit cache + 48-byte header) was developed during D.2 and KEPT — it's a clean wall-time win for D.1's `cg_arena`: post-D.x self-compile **62s wall (was 104s, -40%)**, peak RSS **2449 MB (was 2696 MB, -247 MB)**. D.1 still ships its -1065 MB post-codegen RSS win. D.2 wrap removed; latent `arena_destroy` corruption bug (filed `docs/bugs/D2_ARENA_DESTROY_AT_TC_SCALE_CORRUPTS_HEAP.md`) doesn't manifest without the wrap. Earlier the same day: A.3.d realloc-coverage shipped, B.2 + B.3 + B.4 + B.5 shipped. `@__qz_realloc(ptr old, i64 old_bytes, i64 new_bytes) -> ptr` wrapper closes the realloc-bypass hole filed in `docs/bugs/ALLOC_REALLOC_BYPASS.md`. Routing strategy: DECOMPOSE on the routing path into `alloc(new) + memcpy(min) + dealloc(old)` via the existing two-op surface — keeps D1 minimal preserved (no third op added to Alloc effect). 13 raw `@realloc` emit sites migrated across `codegen_runtime.qz` (3), `cg_intrinsic_sb.qz` (4), `cg_intrinsic_vec.qz` (3), `cg_intrinsic_conc_task.qz` (2), `cg_intrinsic_regex.qz` (1) — bug doc undercounted as 3. 5-test acceptance spec at `alloc_realloc_a3d_spec.qz` covers Vec.push-routes-through-TestAlloc (the original SIGABRT repro), tracking-handler-observes-decompose, String.concat-through-SB-realloc, deny-refuses-Vec-growth, with_budget-refuses-realloc. Fixpoint 2347 byte-identical (+1 from B.5's 2346 = the new wrapper). **All 12 alloc specs green (72 tests total)**. Phase D realloc-bypass blocker closed.
>
> **Phase A + B summary**: All four call-form sugars landed (`Alloc.in_arena(ar)` B.1, `with TestAlloc do ... end` B.2, `Alloc.deny_all()` B.3, `Alloc.with_budget(N)` B.4). User-facing reference at `docs/ALLOC.md` (B.5) cross-linked from `docs/QUARTZ_REFERENCE.md`. Realloc paths now route (A.3.d). Next: Phase C (compiler dogfood prep — allocation hot-spot inventory) → Phase D (compiler arena dogfood) → Phase E (per-task arenas). Both C and D fully unblocked.
>
> Closures-as-handlers (`with E { op: { x -> ... } }`) is filed as a deferred Phase B followup — it's strictly more general than B.0c's call-form and gets pulled in when a real user pattern needs lexical capture.
>
> **Original Phase A status**: A.0 → A.7 all SHIPPED 2026-04-27. **A.7 — flag flip + delete** removed the `--alloc-routing` plumbing per Prime Directive 7: codegen state field, accessor (`cg_set_alloc_routing`), CLI registration (`argparser_flag` at `quartz.qz:1581`), CLI parses (two `parsed_has` sites), and the parameter cascade through `compile()` → `cg_codegen{,_debug,_separate,_incremental}` → `cg_emit_effect_runtime` are all gone. The `__qz_alloc`/`__qz_dealloc` wrapper bodies always emit the watermark+bypass-flag routing-on shape — there is no off mode. Specs migrated: 48 alloc tests across 7 specs all green; the `_with_flags("--alloc-routing")` assertions converted to plain `assert_*` (alloc_intercept_a3b_spec, alloc_fast_path_a4_spec, alloc_stdlib_handlers_a5_spec, alloc_a6_coverage_spec); test sources that asserted exact byte counts (`_ARENA_BASIC`/`_RESET_REUSE`/`_DEALLOC_NOOP`, `_COUNTER_DEALLOC_NO_DECREMENT`/`_COUNTER_EXACT_LIMIT`, `t1_run` in alloc_effect_decl, `t2_run` in alloc_default_handlers + alloc_blessed_default) updated to capture totals inside the with-block and `puts(...)` outside, so str_from_int/concat allocations route through the blessed default rather than the user handler. Fixpoint 2345 functions byte-identical (-1 from A.6's 2346 = the deleted `cg_set_alloc_routing` setter). Smoke tests on `examples/style_demo.qz` + `examples/brainfuck.qz` clean. Sample of 12 random + generator/effect specs green except the pre-existing nested-while-yield bug. Next: **Phase B** (user-facing handler ergonomics — `Alloc.in_arena(ar)`, `with TestAlloc do ...`, `Alloc.deny_all`, `with_budget(N)`) → **Phase C/D** (compiler arena dogfood).
>
> **Initiative**: Ship the deferred-from-Piezo `Alloc` effect, then dogfood arenas under it across the compiler. Sized as a multi-phase initiative; this memo is the spine.
>
> **Ground truth before reading**: Quartz already has production-grade arenas (mmap-backed, chain-walking growth, RAII via `std/memory.qz`'s `Arena: Drop`, borrow-checker-enforced use-after-invalidate via QZ1401, 13 passing specs). The `Alloc` effect was on the Piezo Phase 2 list, deferred, never shipped. The compiler does NOT dogfood its own arenas today — every internal allocation goes direct to `qz_malloc`. Both gaps are addressable.

---

## Session log

**2026-04-27 (Phase D.2 attempt — REVERTED + Phase D.x SHIPPED)** — D.2 (TC arena seam) was implemented, measured against the design memo's premise, and **reverted** when measurement revealed the premise was wrong. D.x optimization (developed during D.2) was retained as a clean wall-time win for D.1's `cg_arena`.

- **D.2 attempt**: wrapped `tc_new()` through `tc_free()` in `with Alloc.in_arena(tc_arena) do -> ... end` inside `compile()`. Pre-declared `_iface_names` / `_iface_hashes` / `had_tc_errors` as outer vars; deferred `return ""` on TC errors via flag; promoted Vec contents post-wrap (mirroring D.1's `arena_promote_string` pattern).
- **Smoke + spec validation**: wrap shipped a binary that compiled `style_demo` cleanly, ran 240 tests across 28 specs all green, and produced byte-identical IR for small programs. End-of-codegen RSS 42 MB on style_demo (down from 43 MB pre-D.2 — within noise).
- **The kill measurement**: self-compile under D.2 showed `[mem] typecheck: 1445 MB` (vs pre-D.2 baseline 798 MB). The arena's no-free-back model holds the FULL allocation history during TC, while libc's allocator reuses freed memory. The 1265 MB live working set in the arena is FUNDAMENTALLY larger than the 617 MB libc fragmentation the design memo assumed was recoverable. **Per `feedback_rss_deltas_overstate_live_set`, the +617 MB libc retention was fragmentation, not recoverable working set — but the design memo treated 50-70% of it as recoverable, which assumed the live working set was BELOW the fragmentation amount. Measurement shows the opposite.**
- **`arena_destroy` corruption**: independently surfaced — calling `arena_destroy(tc_arena)` after the heavy TC workload SIGSEGVs the next libc malloc with KERN_INVALID_ADDRESS. Walks chain successfully but corrupts libc heap such that subsequent `malloc(24)` returns an unmapped pointer. Filed at `docs/bugs/D2_ARENA_DESTROY_AT_TC_SCALE_CORRUPTS_HEAP.md` with crash report + repro shape + 5-step investigation plan. Bug doesn't manifest in standalone reprose (92K Vec.push'es + arena_destroy + post-malloc all succeed) — only the full TC wrap inside `compile()` triggers it.
- **Decision**: revert D.2 wrap entirely. Pre-D.2 baseline was a calibration error compounded by an `arena_destroy` workaround (leak the arena) that just hid the no-free-back problem. Per Prime Directive 5 (Report reality, not optimism) and 7 (Delete dead code outright). `self-hosted/quartz.qz` reverted to pre-D.2 state. `std/alloc` + `std/memory` imports retained (still used by D.1's cg_arena).
- **D.x optimization SHIPPED**: chain-block-size bump 4 KB → 64 KB + last-fit cache + 48-byte arena header (was 40 bytes). Without the cache, arena_alloc's chain walk is O(N) per allocation, costing O(N²) total under saturating workloads — at compiler scale (~10M allocations × 100K-block chain), 1.6 trillion ops = 27+ minutes pure walking. The cache makes the walk O(1) on monotonic growth (the common case). Self-compile post-D.x: **62s wall (was 104s, -40%)**, peak RSS **2449 MB (was 2696 MB, -247 MB)**. D.1 still ships its -1065 MB post-codegen RSS win; D.x makes the trip there faster.
- **Bootstrap discipline preserved**: D.x arena IR changes require a 2-pass bootstrap (gen1 has old inline arena IR baked in by gen0; gen2 has new). The slow gen1→gen2 step took 33 minutes during the D.x rollout (one-time cost). gen2→gen3 is fast (61s). quake guard from gen2 onward verifies fixpoint cleanly in ~5 min. Fixpoint 2390 byte-identical.
- **What this teaches about D.2 going forward**: the design memo's "TC is +617 MB, arena reclaims 50-70%" framing is wrong for ANY high-churn phase. To recover from libc fragmentation, you'd need an allocator that DOES reuse freed memory (like libc itself, just with less metadata overhead). A pure bump arena makes things worse. Future arena dogfooding work should target phases with low alloc/free churn (codegen ✓ — most allocations live to phase end) rather than high-churn phases (TC ✗ — many alloc/free pairs as scopes open/close). Per-task arenas (Phase E) are still viable because per-task working sets are small + bounded.

**Watch for next session**: D.x is the right place to stop on this initiative. Phase D.2 is permanently retired (premise was wrong). Phase D.3 (per-function arenas — even smaller scope) would face the same churn issue and is also retired. Phase E (per-task arenas) remains viable — sequence after the next big initiative. The `arena_destroy` corruption bug is filed but dormant; pull-in trigger is a future user pattern that exposes it.

**2026-04-27 (Phase D.1 attempt — BLOCKED)** — D.0 (`arena_promote_string` helper) shipped at `65b5a1cd`. Subsequent D.1 implementation attempt (codegen module arena seam) revealed an `Alloc.in_arena` + heavy-codegen runtime bug: with `--debug` and `with Alloc.in_arena(cg_arena) do -> codegen_call(); 0 end`, the emitted IR has corrupted register names and `, !dbg !N` debug suffixes (10-digit ASCII heap-address-like numbers replacing small register IDs and the dbg-prefix literal). Default Alloc handlers around the same codegen call are clean — bug is specific to `arena_alloc_handler_e` under codegen-density allocation traffic.

- **Probes confirmed bug isolation**: install/uninstall alone, arena_new+arena_destroy alone, `arena_new()` before codegen, default Alloc handlers around codegen → all clean. Only `with Alloc.in_arena(ar) do -> heavy_codegen() end` corrupts. Both `do -> body end` and `do body end` forms reproduce → not body-wrap-rule-related. The B.1/B.2/B.3/B.4 alloc specs all pass — bug needs codegen-density to surface (~1.8M lines IR worth of String concat / `Int.to_s()` / sb_append).
- **Filed**: `docs/bugs/D1_ALLOC_IN_ARENA_HEAVY_CODEGEN_CORRUPTION.md` with full repro, probe matrix, four hypotheses, and a six-step debugging plan for the next session. Recommends Option D (write a minimal `spec/qspec/d1_arena_codegen_repro_spec.qz` as TDD-RED before chasing the substrate fix).
- **Roll-back complete**: `self-hosted/quartz.qz` (imports + arena wrap) reverted; `self-hosted/backend/codegen.qz` (`cg_set_last_string_pool` setter) reverted; `std/memory.qz`'s `arena_promote_vec_string` helper reverted (no consumer post-rollback per PD7). `arena_promote_string` (D.0) retained — ships in next D.1 retry. Pre-D.1 binary restored from `self-hosted/bin/backups/quartz-pre-d1-codegen-arena-golden`. Fixpoint 2347 unchanged. Smoke test on `/tmp/d1_smoke.qz` clean.

**Watch for next session**: per the bug doc, a minimal repro spec is the right TDD-RED before chasing the substrate fix. The fix is plausibly in one of: (a) arena_alloc's chain-walk + offset arithmetic under variable-size allocation patterns, (b) effect-stack `__qz_effect_current_install_idx` TLS save/restore around re-entrant performs, (c) sprintf-buffer reuse in `@str_from_int` interacting with arena's no-op dealloc. None confirmed. The bug is interesting because it's a NEW regime — first time the compiler itself wraps its own work in an Alloc handler, so prior B.1-B.4 spec coverage doesn't catch this density.

**2026-04-27 (Phase C — design-only)** — Phase C closed. Allocation hot-spot inventory captured + cross-phase escape map confirmed + Phase D arena seams chosen. No compiler-source changes; pure measurement + reading + planning.

- **C.1 — Hot-spot inventory.** Self-compile baseline (clean cache, post-A.3.d binary, `--memory-stats` only — `tracking_alloc_handler` instrumentation deferred to D.1 itself). Peak RSS 1.92 GB (`maximum resident set size`), peak footprint 1.85 GB, wall 36.7s, IR output 1.8M lines. Per-phase deltas:

  | Phase | RSS End MB | Δ MB | Wall ms | Δ wall % |
  |---|---|---|---|---|
  | init→lex→parse | 4 | +4 | 8 | <1% |
  | resolve | 177 | +173 | 1100 | 3% |
  | typecheck | 794 | +617 | 6315 | 17% |
  | tc_free | 795 | +1 | 5 | 0% |
  | mir | 949 | +154 | 7327 | 20% |
  | codegen | 1922 | +973 | 21916 | 60% |

  Big picture: codegen is the dominant grower (+973 MB, 60% of wall). Typecheck is second (+617 MB, 17% of wall). MIR adds +154 MB. `tc_free` releases 30+ vec_free's but RSS drops 0 MB — the system allocator retains freed pages on free lists. Filed as memory note `feedback_rss_deltas_overstate_live_set.md`: arena-recoverable bytes ≈ 50-70% of phase delta, not 100%.

- **C.2 — Cross-phase escape map.** Read `compile()` orchestration (`self-hosted/quartz.qz:183-1080`):
  - **lex_result**: consumed only by parse → could be freed but is small.
  - **ast_storage + root**: consumed by derive, macro_expand, resolve, typecheck, mir, **AND codegen** (verified — `codegen.qz:806/887/917` reads `entry.ast_store`). Persists for whole compile().
  - **all_funcs**: ResolverEntry vec; same lifetime as AST.
  - **tc**: explicitly freed by `tc_free()` after typecheck (~+1 MB RSS drop — see allocator note above).
  - **mir_prog**: consumed by codegen.
  - **llvm_ir**: returned by compile().

- **C.3 — Arena seam decision.** Original four-phase strawman (parse / typecheck / mir / codegen arenas) refined to two-seam plan based on C.1 data: D.1 (codegen module arena, +973 MB target) → D.2 (typecheck module arena, +617 MB target). Parse/resolve/mir deltas don't justify their own seams at this stage (parse +4 MB; resolve outputs all_funcs which fully escapes; mir is +154 MB but its output IS the durable handoff to codegen). Per-function arenas (D.4/D.5 in original plan) deferred until per-module is measured — finer granularity may not be needed.

- **C.4 — Phase D sub-plan landed.** New section [Phase C findings + Phase D sub-plan](#phase-c-findings--phase-d-sub-plan-2026-04-27) below. Specifies seam locations, escape protocol (final `llvm_ir` String materializes to heap before arena drop), exit criteria (peak RSS < 1.4 GB after D.1 alone; < 1 GB after D.1+D.2), and rollback shape (each seam is a separate commit; revert is `with Alloc.in_arena(...) do ... end` → bare body).

- **Watch for next session (D.1)**: 
  - **String/Vec escape across the codegen arena boundary.** The `cg_codegen` family returns a String (`llvm_ir`) that must outlive the arena. Quartz has no `arena_promote_string` helper today — needs adding (`arena_promote_string(arena, s)` copies via `mem_alloc(s.size+1) + memcpy + null-terminate`). Filed as a Phase D.0 sub-task.
  - **`extern_decls` String** — also returned post-arena (`final_ir = "#{llvm_ir}\n#{extern_decls}"`). Same boundary, same fix.
  - **The two `with Alloc.in_arena(...) do cg_codegen(...) end` body-wrap sites** must follow the body-wrap last-stmt rule (`feedback_body_wrap_last_stmt`). Codegen entry shape is already `var llvm_ir = cg_codegen(...); ...; var final_ir = ...; mem_report; ...; return final_ir` — wrapping the cg_codegen call in a with-block leaves the post-call work outside, which is correct. Mid-body returns inside cg_codegen itself (separate vs incremental vs debug branches) are fine — body-wrap rule is about the OUTER with-block's tail, not nested control flow.
  - **Pre-flight verification** before committing D.1: confirm peak RSS drops by reading `--memory-stats` output post-codegen. If RSS doesn't drop by ≥400 MB, the assumption that allocator-retained pages dominate the +973 MB delta is wrong, and D.1 needs to be reconsidered before D.2.

**2026-04-27 (latest)** — Phase A.3.d shipped (`@__qz_realloc` wrapper + 13-site migration + 5-test acceptance spec). Closes the realloc-bypass hole filed earlier the same day during B.2 spec authoring.

- **A.3.d — `@__qz_realloc(ptr old, i64 old_bytes, i64 new_bytes) -> ptr` wrapper.** Mirrors A.3.c's two-stage fast-path shape (watermark + bypass-flag) plus `alwaysinline`. Bypass path: `call ptr @realloc(ptr %old, i64 %new_bytes)` ignoring old_bytes — identical perf to pre-A.3.d for the no-user-handler case. Routing path: DECOMPOSE rather than extend the Alloc effect with a third op — `alloc(new_bytes) + memcpy(min(old, new)) + dealloc(old)` via the existing two-op surface. Edge cases handled in the wrapper: `old==NULL → alloc(new_bytes), skip memcpy + dealloc` (matches libc's `realloc(NULL, N) ≡ malloc(N)`); `new_bytes==0 → dealloc(old), return NULL` (matches libc's `realloc(p, 0) ≡ free(p)`).

- **Routing-strategy decision (A.3.d.2)**: chose decompose over adding a `realloc(ptr, new_size): ptr` op to the Alloc effect. Reasons: (1) keeps D1 minimal preserved — every existing stdlib handler (arena/counter/deny/tracking) works transparently without a `realloc` op; (2) mirrors how `Throws`/`State` shipped (single canonical op, derive the rest); (3) trade-off (arena handlers lose "last-alloc-in-arena bump-extend") is filable as a perf followup if it matters in practice. Bypass path keeps libc's in-place-grow optimization on the no-user-handler hot path.

- **Migrated 13 emit sites (bug doc undercounted as 3)**: `codegen_runtime.qz` × 3 (qz_vec_push + qz_vec_insert + qz_vec_push_runtime), `cg_intrinsic_sb.qz` × 4 (StringBuilder grow paths — 3 use byte-counted `cap`, 1 uses `data.new = realloc(data, cap)` shape), `cg_intrinsic_vec.qz` × 3 (vec_shrink_to_fit + width-aware grow + vec_resize), `cg_intrinsic_conc_task.qz` × 2 (task_group results array + frames array — sharing one `oldbytes = mul cap, 8` for both growth calls), `cg_intrinsic_regex.qz` × 1. Each migrated site emits `oldbytes = mul cap, ew` (or equivalent — element width is 8 in most paths, runtime ew in the width-aware grow site, raw `cap` in SB) immediately before the wrapper call.

- **5-test acceptance spec at `spec/qspec/alloc_realloc_a3d_spec.qz`**:
  - **D1**: Vec.push past initial cap (64 pushes from cap=8) inside `with TestAlloc do ... end` — round-trip values + arena bytes-used confirms the grow allocations land in the test arena. The original SIGABRT repro from the bug doc, now passes.
  - **D2**: tracking handler observes alloc+dealloc decomposition. After 64 pushes the counters are alloc=5 (vec_new's hdr + initial data + 3 grows: 8→16→32→64) and dealloc=3 (one per grow's old-buffer dealloc). Each grow proves one alloc-new + one dealloc-old fired through the handler — i.e. the wrapper decomposed, not bypassed.
  - **D3**: String.concat in a 50-iter loop drives StringBuilder realloc through the tracking handler — strlen > 100, alloc count > 10.
  - **D4**: `with Alloc.deny_all() do ...` + Vec.push past cap → `Throws` "allocation denied" → exit 66 (asserted via `assert_run_panics`). Sandboxing extends to dynamic-container growth, not just user `alloc(N)`.
  - **D5**: `with Alloc.with_budget(80) do ...` + Vec.push past cap → `Throws` "budget exceeded" → exit 66. Realloc charged at full new_bytes; first cap-doubling exceeds the 80B budget.

- **B.2 spec workaround reverted in comment.** `_MULTI_ALLOC_ROUTES` test in `alloc_test_alloc_b2_spec.qz` no longer needs to "avoid Vec.push because of the realloc-bypass hole" — the comment now points to the A.3.d coverage spec for Vec.push routing tests.

- **Body-wrap last-stmt rule kicked in twice during D4/D5 spec authoring.** `with Alloc.deny_all() do -> ...while loop... end` (no trailing bare expression) generates `%push` references to undefined SSA values — same shape as the documented [feedback_body_wrap_last_stmt] rule. Adding `puts("should_not_print")` after the while loop fixes both. Lock-in: `with E { ... } do -> ... end` body-wraps with internal control flow as the last statement still need a bare expression at the tail. Pattern matches the existing B.4 `_VEC_PUSH_INTERCEPTED` spec which shipped the same trailing-puts shape.

- **Cache pollution surfaced during ad-hoc test runs.** Running specs sequentially without `--no-cache` produced sporadic `index out of bounds: index 0, size 0` SIGSEGVs after a few successful spec compiles. Documented in [feedback_quartz_cache_pollution]. Fixed by passing `--no-cache` (which is what `quake qspec` does internally). All 11 prior alloc specs + new alloc_realloc_a3d_spec all green with `--no-cache`.

- **Fixpoint preserved at 2347 functions** (+1 from B.5's 2346 = the new `@__qz_realloc` wrapper). Smoke tests on `examples/style_demo.qz` + `examples/brainfuck.qz` clean.

**Watch for next session (Phase C+):**
- Phase C unblocked. Use `tracking_alloc_handler` (A.5) + the now-universal routing (A.3.c + A.3.d) to instrument each compiler phase. Output: per-phase allocation count + bytes. From there decide arena seams (per-phase / per-function / per-pass).
- Phase D fully unblocked — realloc bypass closed. Vec/String operations route correctly under per-phase arena handlers.
- Open arena-handler perf followup: when a real Phase D / Phase E user pattern would benefit from in-place arena bump-extend on realloc, add a `realloc(ptr, new_size): ptr` op to the Alloc effect with a default that decomposes. Until then, the decompose-everywhere approach is correct and simpler.

**2026-04-27 (earlier)** — Phase B.2 + B.3 + B.4 + B.5 shipped (TestAlloc, deny_all, with_budget call-form sugars + B.5 docs). Closes Phase B.

- **B.3 — `Alloc.deny_all()`.** Zero-arg method-dispatch entry in `_mir_method_dispatch_entries`. Reuses A.5's stateless `deny_alloc_handler` (throws via `Throws`) and `deny_dealloc_handler` (forwards to `mem_free` so caller can free pre-sandbox memory) — no `_e` suffix variant needed because the deny handler doesn't read state. Pattern: `with Alloc.deny_all() do untrusted_plugin() end`. With no user `with Throws` outer frame, the runtime-blessed Throws default writes the message to stderr and exits 66. With outer `with Throws { throw: rec }`, control unwinds to the user handler. 5-test acceptance spec at `spec/qspec/alloc_deny_all_b3_spec.qz` covers: basic deny → exit 66, outer Throws catches + execution recovers, sequential independent deny scopes, pre-deny arena allocation survives the inner deny refusal, Vec push inside deny → universal coverage routes to denial. Two test patterns originally drafted (sequential alloc-after-recovery, nested arena-then-deny with post-deny continuation) had to be rewritten to avoid bumping into the filed "stack-top mis-restore on cross-scope longjmp" bug — leaked deny entries on the effect stack cause subsequent allocations to re-trip deny → my_throws fires twice. Documented inline in the spec; awaits the per-install teardown substrate before that pattern can ship.

- **B.4 — `Alloc.with_budget(N)`.** Same shape as in_arena but env is the budget (initial remaining bytes). Env-aware `budget_alloc_handler_e` / `budget_dealloc_handler_e` in `std/alloc.qz`: alloc reads remaining via `__qz_effect_state_get()`, checks `size > remaining` → throws via `Throws`, else `__qz_effect_state_set(remaining - size)` + forward to `mem_alloc(size)`. Single-slot pattern — the per-install state IS the remaining-budget counter, decremented in place via state_set. The originally-planned heap-alloc'd 2-slot (budget + used) struct was UNNECESSARY — single-slot remaining gives the same "throw when over budget" semantics with cleaner code and no install-time alloc/free pair. **Required exposing `__qz_effect_state_set(v)` as `extern "C"` in `std/alloc.qz`** alongside the existing `__qz_effect_state_get()` import; the runtime symbol already existed (codegen_runtime.qz line 1076). Method-dispatch entry added to `_mir_method_dispatch_entries`. 5-test acceptance spec at `spec/qspec/alloc_with_budget_b4_spec.qz` covers: under-budget multi-alloc, over-budget throws via Throws, sequential isolation (each scope's remaining independent), nested (inner trips first, outer slot unaffected), Vec push intercepted via internal allocations.

- **B.2 — `with TestAlloc do body end`.** Bare-IDENT alias for an Alloc install backed by a singleton test arena. Three coordinated changes:
  1. **`typecheck_walk.qz`**: extended `tc_with_handler_begin`'s effect-claim resolution. When the bare-IDENT name is `TestAlloc` (no `$`-method suffix), `lookup_name` is rewritten to `Alloc` so the typecheck claim succeeds against the existing Alloc effect declaration. Body code with `can Alloc` rows is satisfied without a separate effect decl. The rewrite is gated on `dollar_idx < 0` so a hypothetical `TestAlloc.method` form would still fail QZ0613 cleanly. ~5 LOC.
  2. **`mir_lower.qz` NODE_WITH NODE_IDENT branch**: when the bare IDENT name is `TestAlloc`, redirect: set `nw_eff_name = "Alloc"`, push `(alloc, arena_alloc_handler_e)` + `(dealloc, arena_dealloc_handler_e)` entries, set `nw_init_state_reg` to a call of `test_alloc_arena_acquire()` (resolved via `mir_resolve_func_name`, called via `ctx.mir_emit_call`). Other bare-IDENT names fall through to the existing null-filter/null-handler path. ~14 LOC.
  3. **`std/alloc.qz`**: new module-global `_test_alloc_arena_handle: Int = 0`. Function `test_alloc_arena_acquire()` lazy-creates an 8 KB arena on first call (`arena_new(8192)`), resets on every subsequent call (`arena_reset(handle)`), returns the handle. Companion `test_alloc_arena_peek()` reads without resetting (for spec assertions on bytes-used after a TestAlloc block exits).
  
  The reset-on-acquire semantics give clean isolation between sequential `with TestAlloc` blocks without a per-install teardown hook (no leak — the singleton is reused indefinitely). **Limitation**: nested `with TestAlloc` blocks share the singleton; the inner reset wipes outer's allocations. Test framework integration (one `with TestAlloc` per `it` block) avoids this naturally. Per-scope arena lifecycles need a per-install teardown substrate — filed as a Phase B followup. 5-test acceptance spec at `spec/qspec/alloc_test_alloc_b2_spec.qz`: basic alloc round-trip, sequential isolation via reset, multi-alloc routing (avoids Vec.push because of the realloc-bypass hole — see below), large-allocation arena growth, TestAlloc claim satisfies a `can Alloc`-rowed helper.

- **Pre-existing bug surfaced + filed: `qz_vec_push_impl` calls `@realloc` directly, bypassing the `__qz_alloc` wrapper.** Drafting the B.2 Vec-push spec test triggered SIGABRT when the Vec grew past initial capacity. Diagnosis: A.3.c's wrapper sweep migrated ~178 raw `@malloc`/`@free` sites but missed three `@realloc` sites in `codegen_runtime.qz` (lines 6482, 6609, 7070). When a Vec is initialized inside `with Alloc.in_arena(ar)`, its first push gets a libc-malloc'd buffer (because realloc(NULL, N) ≡ malloc(N) — the wrapper isn't on the path), but if a SECOND push triggers growth via `realloc(libc_ptr, 2N)`, it stays libc. If the FIRST buffer was arena-allocated (via wrapper → arena_alloc) and a subsequent push tries `realloc(arena_ptr, 2N)`, libc realloc walks malloc metadata that the arena pointer doesn't have → SIGABRT. Filed as `docs/bugs/ALLOC_REALLOC_BYPASS.md` with full repro, fix shape (mirror A.3.c — emit `@__qz_realloc(old, new_bytes)` wrapper, migrate the three sites, extend Alloc effect with optional `realloc` op or transparently compose alloc+memcpy+dealloc in handlers without one). Half-quartz-day work; not blocking Phase C but does block portions of Phase D where compiler Vecs would route through phase arenas.

- **B.5 — Documentation.** New `docs/ALLOC.md` as the canonical user-facing reference — covers the effect declaration, runtime routing pipeline (wrapper → watermark fast-path → bypass flag → perform), handler ABI, four call-form sugars (B.1–B.4 + TestAlloc), default handler library shape, refusal semantics (D5 lock-in), reentrancy guarantees (Phase A.6 + B.0a fixes), composition with other effects, what does NOT route through Alloc (realloc paths, stack allocations, FFI), performance numbers (Phase A.4: ~3.6% overhead for blessed-default routing, zero for direct-malloc fast-path), and current status of Phases C–F. New entry in `docs/QUARTZ_REFERENCE.md`'s Memory section under "Alloc Effect" subsection — short user-facing snapshot of the four sugars with cross-link to `ALLOC.md`. The reference doc's Basic subsection updated to fix a stale `free(ptr)` reference (correct op is `dealloc(ptr)`).

- **Verification**: `quake build` succeeds at 2346 functions (zero net change vs B.0c+B.1's 2346 — the B.2 mir_lower+typecheck additions and B.3+B.4 registry entries are pure inline code, no new top-level functions). All 11 alloc specs green: 3+3+3+5+5+3+5+18+5+5+12 = 67 tests total. Effect/generator regression sample (effect_decl, effect_handler_narrow, effect_default_handlers_d4, effect_h_delegate_fallthrough, effect_resumable_f, effect_state_p2a, generator, generators_p4b8/p4b9, phase_6_1c) all green except the pre-existing nested-while-yield bug already filed at `docs/bugs/GENERATOR_NESTED_WHILE_DOUBLE_YIELD.md`. (Note: full `quake guard` not run yet — debug build is sufficient for code verification but the fixpoint stamp won't be current until guard runs at commit time.)

- **Phase B is structurally complete.** All four canonical call-form sugars ship with 5-test acceptance specs. The substrate (B.0a runtime-hardening + B.0c per-install env slot via `__qz_effect_stack_state_slots`) handles per-install state cleanly. Closures-as-handlers stays filed as a deferred Phase B followup with a clean pull-in trigger. Per-install teardown hooks (needed for proper TestAlloc per-scope arena lifecycle and full deny/budget recovery composition) are filed as Phase B followup #2 — not blocking Phase C/D.

**Watch for next session (Phase C+):**
- Phase C (compiler dogfood prep) is unblocked. Use `tracking_alloc_handler` (A.5) to instrument each compiler phase. Output: per-phase allocation count + bytes. From there decide arena seams (per-phase / per-function / per-pass).
- The realloc-bypass hole (filed today) blocks Vec-heavy compiler workloads from full Alloc routing. Phase D may want to fix this first OR work around it by tracking Vec growth allocations separately. Recommend fixing in a Phase A.3.d sub-phase before Phase D.
- Phase B followup #1 (closures-as-handlers): pull-in trigger is a real user pattern needing lexical capture beyond call-form sugars. Phase B's current sugars may suffice for compiler dogfood.
- Phase B followup #2 (per-install teardown): pull-in trigger is wanting per-scope arena lifecycle for TestAlloc, or wanting deny_all to reliably restore pre-deny state across cross-scope longjmps. Substrate work would extend MIR_HANDLE_INSTALL/UNINSTALL with optional teardown function name + arg.
- The A.5 module-global state pattern (`alloc_set_arena`, `alloc_set_budget`, `alloc_reset_tracking`, etc.) STILL EXISTS alongside the B.1–B.4 env-aware handlers — both APIs coexist. Future cleanup: deprecate-and-remove the module-global API once user code migrates. Filing as a smaller Phase B.6 cleanup.

**2026-04-27 (earlier)** — Phase B.0c + B.1 shipped (Alloc.in_arena call-form sugar + 5-test acceptance spec).

- **Substrate scope discovered.** B.0b as originally scoped (add a per-install env slot) was REDUNDANT — `__qz_effect_stack_state_slots[256]` already existed for State/Reader, with `__qz_effect_state_get()` / `__qz_effect_state_set()` runtime helpers. The substrate gap was wire-up: extending NODE_WITH lowering's call-form path to accept `EffectName.method(arg)` shape, install N entries (one per op of the effect), and write the call's arg into state_slots[pretop+i] for each entry. B.0b task closed as superseded; B.0c carried the actual work.

- **B.0c — call-form surface.** Three coordinated changes:
  1. **`typecheck_walk.qz` `tc_with_handler_begin`**: split the handler IDENT name on `$` (parser squashes `EffectName.method` into a single qualified ident named `EffectName$method`); use the prefix as the effect lookup key, keep the suffix as the method-dispatch key. Effect_id push uses the prefix; QZ0613 error message references the prefix when lookup fails. ~15 LOC.
  2. **`mir_lower.qz` NODE_WITH NODE_CALL branch**: same `$`-split recognition. When method_name is non-empty, dispatch through a new `_mir_method_dispatch_entries(ctx, eff, method, entries)` helper that pushes per-op (filter, handler) pairs. Bare effect-name call-form (existing `State(v)` shape) preserved. Plus a NODE_FIELD_ACCESS branch for the zero-arg case (`with Alloc.deny_all do ... end` without parens — hooks not yet wired but the AST recognition is in place). ~50 LOC including the dispatch helper.
  3. **`codegen_instr.qz` MIR_HANDLE_INSTALL emission**: extend the init-state write loop. Pre-B.0c, init state was written ONLY to `state_slots[pretop+0]`. Post-B.0c, when `_hi_has_init==1`, write to ALL `state_slots[pretop+0..N-1]`. Each per-op handler resolves env via `__qz_effect_state_get()` which reads `state_slots[current_install_idx]`; fan-out makes every entry's handler see the same env. Single-entry call-forms (State(v), Reader(v)) collapse to writing slot[pretop+0] only — same behavior as before. ~30 LOC.

- **Method-dispatch registry**: `_mir_method_dispatch_entries(ctx, eff, method, entries)` — currently registers `(Alloc, in_arena) → [(alloc, arena_alloc_handler_e), (dealloc, arena_dealloc_handler_e)]`. Handler names resolved via `mir_resolve_func_name(ctx, ...)` so the mangled stdlib symbols link correctly. Adding new sugars (B.2-B.4) extends this registry; the rest of the substrate is in place.

- **B.1 — `Alloc.in_arena(arena)`.** Three pieces:
  1. **`std/alloc.qz`** adds env-aware handlers `arena_alloc_handler_e` and `arena_dealloc_handler_e`. The alloc handler reads `__qz_effect_state_get()` (declared as `extern "C"`) to get the arena handle, then calls `arena_alloc(handle, size)`. Dealloc is a no-op (arena memory frees in bulk). The `_e` suffix distinguishes from the A.5 module-global handlers; both APIs coexist.
  2. **Method registry** entry for `(Alloc, in_arena)` (in `_mir_method_dispatch_entries`).
  3. **`spec/qspec/alloc_in_arena_b1_spec.qz`** — 5-test acceptance spec covering: basic install (alloc routes to arena), nesting independence (inner arena observes inner alloc, outer recovers after — the headline B.0c property), sequential isolation (3 sequential `with Alloc.in_arena(ar_x)` blocks each have independent state), arena_reset between scopes, and Vec-push routing through the arena under post-A.7 universal coverage.

- **Verification**: `quake guard` passed (fixpoint 2346 functions, +1 from B.0a's 2345 = the new `_mir_method_dispatch_entries` helper). All 7 prior alloc specs (48 tests) remain green. New `alloc_in_arena_b1_spec` 5/5 green on first run. Sample of effect specs (`effect_state_p2a`, `effect_handler_narrow`, `effect_resumable_f`, `effect_h_delegate_fallthrough`) all green — the call-form lowering changes preserve State(v) and other existing call-form effect surfaces.

- **Carry-over for next session (B.2-B.4 sugar)**: each new sugar adds one entry to `_mir_method_dispatch_entries` + the matching env-aware handlers in `std/alloc.qz`.
  - **B.3 (deny_all)**: zero-arg form. Test the NODE_FIELD_ACCESS branch in mir_lower (currently wired but not exercised by B.1). May require parser/typecheck adjustment if `Alloc.deny_all` (no parens) doesn't reach mir_lower's NODE_FIELD_ACCESS branch as expected. Handler is stateless (`deny_alloc_handler` already exists in std/alloc.qz from A.5; just needs registry entry, no `_e` suffix variant needed).
  - **B.4 (with_budget(N))**: same shape as in_arena but env is the budget. Handler reads env (the budget), maintains per-call used counter — but used counter needs ANOTHER per-install slot (state_slots writes only env). Either (a) pack budget+used into a heap-alloc'd struct stored in state_slots[i], or (b) use state_slots for budget AND another scratch slot for used. Strawman (a): allocate a 2-slot counter struct via mem_alloc at install time, store ptr in state_slots, free at uninstall. Heap-allocation per `with_budget` block; acceptable for a budget-tracking sugar.
  - **B.2 (TestAlloc)**: distinct effect (no `Alloc.method` shape). Registers as a top-level effect that internally installs Alloc handlers. Body wraps `with Alloc.in_arena(test_arena) do body end` plus auto-creates the arena. The `with TestAlloc do body end` form is bare-IDENT; mir_lower already handles it but the registry entry for the bare IDENT path needs adding.

- **Watch for**:
  - The NODE_FIELD_ACCESS branch in mir_lower's NODE_WITH lowering is untested by B.1 (which uses the NODE_CALL path). Adding B.3 will exercise it. If parser produces a different shape for zero-arg `Alloc.deny_all`, that branch may need adjustment.
  - The `_mir_method_dispatch_entries` registry currently hardcodes the (eff, method) → handler-list mapping in compiler source. As more sugars land, the hardcoded list grows. Future cleanup: move the registry to a stdlib-side mechanism (effect-decl extension that lists method dispatchers), keeping the compiler's role to "look up by name" rather than "know all sugars." Out of scope for B.

**2026-04-27 (later)** — Phase B.0a shipped (bypass-flag longjmp safety).

- **B.0a — Per-with-block bypass-flag save/restore.** Two-edit fix in `codegen_instr.qz`'s `MIR_HANDLE_INSTALL` emission: (a) before the `setjmp` call, snapshot `@__qz_alloc_in_handler` into a per-with-block SSA value `%wb.in_h_save.<dest>` (defined in the install block so it dominates both `wb.body` and `wb.catch`); (b) at the very top of `wb.catch.<dest>`, store the snapshot back to `@__qz_alloc_in_handler`. Restoring to the saved value rather than zeroing preserves the invariant when the with-block is nested inside an outer handler body — in that case `in_h` was already 1 before the with-block opened, and 1 must be restored on catch. The body path is unchanged: `__qz_effect_perform`'s do_call already restores `in_h` inline after each handler returns normally; the wb.catch save/restore covers exactly the case that inline restore cannot reach (handler-thrown longjmp out of perform).

- **Why at the with-block layer, not inside `__qz_effect_perform`.** The handler's `throw(...)` longjmps to a buf belonging to the user's `with Throws { throw: rec } do ... end` install — that buf was set up in user code at a setjmp inside the with-block wrapper, NOT inside perform. Wrapping the handler call in a perform-internal `setjmp` would not catch the throw because the longjmp target is a different buf. The clean fix is to pin cleanup at the LANDING ZONE (every with-block's catch) rather than at the SOURCE (perform's do_call). Side benefit: the same wb.catch restore covers cleanup for any future TLS state that perform sets around the handler call (`@__qz_effect_current_install_idx` / `@__qz_effect_current_kind` / `@__qz_effect_current_cont_frame`) — extending the save/restore list at the with-block layer is local and uniform.

- **D2 regression flipped + doc-comments updated.** `spec/qspec/alloc_a6_coverage_spec.qz` test 11 retitled from `REGRESSION — bypass-flag leaks across handler-thrown longjmp` to `bypass-flag preserved across handler-thrown longjmp (B.0a)`; assertion flipped from `bypass_flag_leak_present` to `bypass_flag_leak_fixed`. The doc comment on the `_BYPASS_FLAG_LEAK_REGRESSION` test source rewrote to describe the fix instead of the bug. `std/alloc.qz`'s "Known limitation" doc-comment rewrote to describe B.0a's wb.catch save/restore mechanism. `codegen_runtime.qz` line 825's restore comment now points readers to the with-block layer for the longjmp-out case.

- **Verification**: `quake guard` passed twice (once with the `codegen_instr.qz` change alone, once after the comment-only edits to `codegen_runtime.qz` / `std/alloc.qz`); fixpoint 2345 functions byte-identical at both. All 7 alloc specs (48 tests) green. Smoke tests on `examples/style_demo.qz` + `examples/brainfuck.qz` clean. Sample of non-alloc effect/generator specs (`effect_decl`, `effect_handler_narrow`, `effect_default_handlers_d4`, `effect_h_delegate_fallthrough`, `effect_resumable_f`, `effect_state_p2a`, `phase_6_1c_handler_throws`, `generators_p4b8_modular_helpers`, `generators_p4b9_effect_composition`, `generator`) all green except the pre-existing nested-while-yield bug already filed at `docs/bugs/GENERATOR_NESTED_WHILE_DOUBLE_YIELD.md` (1 of 23 generator tests fails identically pre-vs-post).

- **Closures-as-handlers filed.** New entry under Phase B followups capturing the deferred design: `with Alloc { alloc: { size -> arena_alloc(captured_arena, size) } } do ... end`. Strictly more general than B.0c's call-form. Pull-in trigger documented (real user need for lexical capture beyond call-form sugars). Locked in here so future sessions don't re-derive the option space ad hoc.

- **Watch for next session (B.0b)**: the install ABI change touches every install call site — D.4 prelude defaults (~6 sites in `codegen_runtime.qz`'s `cg_emit_effect_main_prelude`), the MIR_HANDLE_INSTALL emission in `codegen_instr.qz` (one site), and the runtime entry in `codegen_runtime.qz` (one signature). Adding the 5th array `__qz_effect_stack_envs[256]` is mechanical (parallel to existing 4 arrays). The fixpoint risk is the install signature change: every binary built before the change emits 4-arg install calls and won't link against a 5-arg function. Bootstrap-safe path: emit the new install function with a different mangled name (`__qz_effect_handle_install_v2` or similar) for one commit, migrate all callers, then drop the old name in a follow-up commit. Mirrors the `mem_alloc`/`alloc` dual-register playbook from Phase A.0.

**2026-04-27 (latest)** — Phase A.7 shipped, flag plumbing deleted, Phase A complete.

- **A.7 — Flag flip + delete.** Per Prime Directive 7 (no flag-gate after stable), `--alloc-routing` is GONE — not flipped to default-on, deleted outright. Touched: `quartz.qz` (argparser_flag at line 1581 deleted, two `parsed_has` reads deleted, `compile()` parameter dropped, four codegen-entry-point call sites updated), `codegen.qz` (`cg_codegen` + `cg_codegen_debug` parameter dropped, `cg_set_alloc_routing` calls removed), `codegen_separate.qz` (`cg_codegen_separate` + `cg_codegen_incremental` parameter dropped, two `cg_emit_effect_runtime` arg lists updated), `codegen_runtime.qz` (`cg_emit_effect_runtime` parameter dropped, the if/else around the wrapper body collapsed to always emit the routing-on watermark+bypass shape — comment block trimmed accordingly), `codegen_util.qz` (`alloc_routing` field on `CodegenState` removed, init in `cg_new_state` removed, `cg_set_alloc_routing` setter deleted), `cg_intrinsic_memory.qz` (comment trim), `codegen_instr.qz` (G.2 fast-path comment trim). No replacement, no shim, no flag-default-on transitional state. Quakefile.qz had no explicit `--alloc-routing` pass to drop (the flag was off by default and only set in spec-test invocations).

- **Spec migration.** Of the 7 alloc specs, 4 used `_with_flags("--alloc-routing")` assertions (alloc_intercept_a3b_spec, alloc_fast_path_a4_spec, alloc_stdlib_handlers_a5_spec, alloc_a6_coverage_spec) — converted those to plain `assert_*` and dropped routing-off-mode tests in alloc_intercept_a3b_spec (the off-mode no longer exists). 8 test sources had `puts(...)` INSIDE a `with Alloc {...}` block while asserting exact handler call counts or byte totals — those were green pre-A.7 only because routing-off let internal stdlib allocations from str_from_int/concat skip the user handler. Post-A.7 every allocation routes; fixed by capturing totals into module-level vars inside the with-block and moving `puts(...)` outside, so format-string allocations route through the blessed default. Affected: `_ARENA_BASIC`, `_ARENA_RESET_REUSE`, `_ARENA_DEALLOC_NOOP`, `_COUNTER_DEALLOC_NO_DECREMENT`, `_COUNTER_EXACT_LIMIT` (alloc_stdlib_handlers_a5_spec); `t1_run` (alloc_effect_decl); `t2_run` (alloc_default_handlers, alloc_blessed_default).

- **Verification**: `quake guard` passed, fixpoint 2345 functions byte-identical (-1 from A.6's 2346 — exactly the deleted `cg_set_alloc_routing`). All 7 alloc specs green: 3+3+3+5+4+18+12 = 48 tests. Smoke tests on `examples/style_demo.qz` + `examples/brainfuck.qz` clean. Sample of 12 random specs from `spec/qspec/*.qz` green. Generator/effect sample (effect_resumable_f, async_channel, generator, generators_p4a/p4b5/p4b8/p4b9) all green except the pre-existing nested-while-yield runtime bug already filed in `docs/bugs/GENERATOR_NESTED_WHILE_DOUBLE_YIELD.md`.

- **Phase A complete (A.0 → A.7).** The `Alloc` effect is now the only allocation path in the language. The `__qz_alloc`/`__qz_dealloc` wrappers always emit the watermark+bypass-flag shape; a user `with Alloc { alloc, dealloc } do body end` block sees every allocation in `body` (user-visible `alloc(N)`, plus internal Vec/String/Map/closure-env allocations). The static fast-path (G.2) inlines a direct handler call when only one Alloc handler is in scope, with the bypass-flag save/restore. The blessed default forwards to malloc/free with zero overhead via the watermark check. The stdlib handler library (arena/counter/deny/tracking) is the substrate that Phase B's ergonomic sugar (`with Alloc.deny_all do untrusted() end`, `with TestAlloc do ...`, `Alloc.in_arena(ar)`, `with_budget(N)`) sits on top of.

- **Watch for next session**: bypass-flag-leak across handler-thrown longjmp (D2 regression test in alloc_a6_coverage_spec locks in CURRENT broken behavior — flip the assertion when the runtime fix lands) and stack-top mis-restore across nested with-blocks where longjmp crosses scope. Both filed in A.5/A.6 session logs. Phase B is the natural place to fold in the runtime fix because Phase B's per-call closure ergonomics will lean harder on robust longjmp semantics.

**2026-04-27 (later)** — Phase A.6 shipped + latent A.4 bug fixed.

- **A.6 — Spec coverage expansion.** New `spec/qspec/alloc_a6_coverage_spec.qz`, 12 tests across four groups. (A) Multi-level nesting / handler stack discipline: 3-deep nest innermost-wins, outer-after-inner reverts, 3-fold sequential install isolation. (B) Recursion-bypass stress under `--alloc-routing=on`: handler builds Vec<Int> internally, handler calls `puts()` with str interpolation, handler invokes 3-deep helper chain that allocates at every level. (C) Edge cases: `alloc(0)` propagation, `dealloc(NULL)` ptr=0 observation, counter handler with single-request-larger-than-budget. (D) D5 composition + bypass-flag-leak regression: outer Throws catches deny-throw and resumes after with-block, regression test locks in the CURRENT (broken) behavior of bypass-flag leaking across handler-thrown longjmp (flip assertion when fix lands), control test confirming bypass restores correctly when no throw fires.

- **Compiler bug surfaced + fixed (the headline outcome of A.6).** Group B's first three tests failed against the pre-A.6 compiler — a handler that internally allocated invoked itself recursively under routing=on (e.g., `puts_handler` fired 5× per outer `alloc()` call instead of 1×). Tracing the IR showed the user's `alloc(N)` call lowering to a STATIC FAST-PATH direct call (`call i64 @<handler>(...)`) rather than going through `__qz_effect_perform`. The static fast-path was added in A.4 (G.2 optimization in `codegen_instr.qz`) — but it was authored when `__qz_effect_perform` didn't yet have the bypass-flag handling that A.3.b added later. The fast-path replicates the `@__qz_effect_current_install_idx` store but missed the `@__qz_alloc_in_handler` save/store. Result: when the user's handler invocation is statically resolvable (single-handler with-Alloc, alloc directly in the with-block body — most cases), the fast-path fires, in_h stays at 0, and any internal allocation inside the handler routes back through perform → re-enters the same handler → recursion. The dynamic path (when the alloc is in a function called from the with-block body) was unaffected because perform always set in_h. Fix in `codegen_instr.qz` mirrors `__qz_effect_perform`'s pattern at lines 839-850; gated on `_po_eff == "Alloc"` so non-Alloc effects pay zero overhead; ~10 LOC. Same reasoning didn't extend to the `_po_static_unwind` branch because Alloc ops are kind=1 (continuation-style); kind=2 unwind is a Throws-shape that doesn't apply.

- **Verification**: fixpoint 2346 byte-identical post-fix; all 6 prior alloc specs (effect_decl, default_handlers, blessed_default, intercept_a3b, fast_path_a4, stdlib_handlers_a5 — total 34 tests) re-verified green; new alloc_a6_coverage_spec 12/12 green; smoke tests on `examples/style_demo.qz` + `examples/brainfuck.qz` clean. Sample of non-Alloc effect specs (`effect_decl_spec`, `effect_handler_narrow_spec`, `effect_default_handlers_d4_spec`, `effect_h_delegate_fallthrough_spec`) pass — confirms the gating on `_po_eff == "Alloc"` keeps non-Alloc effects untouched. Stack-leak after handler-thrown longjmp (the deeper, related bug surfaced during D2 trace analysis: with-Alloc{deny}'s wb.done never runs when longjmp targets outer with-Throws's setjmp, leaving the deny entry on the effect stack while outer Throws gets popped instead) was NOT fixed in A.6 — it interacts with the bypass-flag-leak in subtle ways and is a separate runtime hardening pass. Documented in the regression test's comment.

- **Filed for runtime hardening**: Two known limitations remain after A.6, both in `__qz_effect_perform` interaction with longjmp. (1) Bypass-flag-leak across handler-thrown longjmp — `@__qz_alloc_in_handler` restore on line 850 is skipped when handler longjmps out via throw. Strawman fix: setjmp/cleanup block in `do_call:` body. (2) Stack-top mis-restore across nested with-blocks where longjmp crosses scope — inner with-Alloc's uninstall never runs (longjmp targets outer setjmp), but outer with-Throws's wb.done decrements top by N (its own pop_count), so inner's entry stays on the stack while outer's is popped. Both filed in roadmap entry A.6 + bug list; the design memo's Phase B handler-ergonomics work is the natural place to fold in the runtime fix because Phase B will lean on robust longjmp semantics.

**2026-04-27** — Phase A.5 shipped (single commit, std/alloc.qz + spec only).

- **A.5 — Stdlib handler library + D5 lock-in.** Added four handler families to `std/alloc.qz` (arena, counter, deny, tracking) plus their state setters and getters. Each handler conforms to the perform-ABI shape `def h(op_name: Int, argc: Int, argv: Int): Int`; state lives in module-level globals (`_alloc_arena_handle`, `_alloc_counter_budget`, `_alloc_counter_used`, `_alloc_tracking_*`) accessed via `alloc_set_arena(handle)`, `alloc_set_budget(bytes)`, `alloc_reset_tracking()`, `alloc_get_used()`, etc. Handlers use byte-count semantics throughout per A.3.c. Compiler binary unchanged — A.5 is purely additive to stdlib + a new spec file.

- **D5 lock-in — handlers throw via `Throws` on refusal.** `counter_alloc_handler` throws `"Alloc: budget exceeded — limit=NB used=MB requested=KB"` when the next request would push past the budget; `deny_alloc_handler` throws `"Alloc: allocation denied (sandbox)"` on every alloc. With no user `with Throws` frame, the runtime-blessed default Throws handler writes the message to stderr and exits 66. With user `with Throws { throw: rec } do ... end` outer frame, control unwinds to the user handler — the standard composition pattern. `import std/throws` added to `std/alloc.qz` so `throw` resolves; `Throws` is in the runtime-blessed prelude default set so handler bodies don't need a `can Throws` annotation.

- **Spec coverage**: new `spec/qspec/alloc_stdlib_handlers_a5_spec.qz` — 18 tests across 5 sections (3 arena + 5 counter + 3 deny + 4 tracking + 3 composition). Composition covers (a) user `with Throws` catches deny-throw (D5 happy path), (b) nested `with Alloc` — innermost handler wins, (c) sequential scopes have independent state. Deny + tracking specs include `--alloc-routing=on` variants asserting `Vec.push` / `vec_new<T>()` internal allocations get observed by the user handler. All 18/18 green; pre-existing 16 alloc tests across `alloc_{effect_decl,default_handlers,blessed_default,intercept_a3b,fast_path_a4}_spec.qz` re-verified green. Smoke tests on `examples/style_demo.qz` + `examples/brainfuck.qz` clean. Fixpoint stamp valid (no self-hosted/ changes).

- **Known limitation — bypass-flag leak across handler-thrown longjmp** (filed in `std/alloc.qz` doc-comment + roadmap entry). When a refusal `throw(...)` longjmps out from inside an Alloc handler (counter-over-budget or deny), `__qz_effect_perform`'s post-handler restore of `@__qz_alloc_in_handler` is skipped — the flag stays at 1. Programs that recover from the throw via an outer `with Throws { throw: rec }` and then continue allocating will see subsequent allocations bypass the user's Alloc handler (they fall through to direct `@malloc`). This does NOT affect the dominant "throw and exit" use case (deterministic process termination via the runtime default). Fix: setjmp/cleanup block in `__qz_effect_perform`'s `do_call:` body. Filed for Phase A.6 / Phase B runtime hardening pass.

**Key gotchas surfaced this session**:

1. **`arena` is a reserved keyword that gets silently miscompiled in std/* identifiers.** First version of `alloc_set_arena` had a parameter `arena: Int` — the parser reserves `TOK_ARENA` for an `arena` scope form and emits QZ0530 on direct top-level compile. But via the import chain, the diagnostic is suppressed and codegen emits `%v0 = add i64 0, 0` for the RHS — the param value silently drops, and `alloc_get_arena()` always returned 0. Fixed by renaming param to `handle`. Filed as memory file `feedback_arena_reserved_keyword.md` — the QZ0530-via-import suppression is itself a latent compiler bug worth filing under `docs/bugs/` next time it surfaces. Avoid as param/local names: `arena`, `pool`, `state`, `effect`, `with`, `is`, `as`, `match`, `fn`, `mut` (RHS-as-zero is the symptom).

2. **Triple-quote spec-string interpolation gotcha (4th time hit in alloc work)**. Initial `_ARENA_BASIC` snippet had `puts(\"sum=#{sum}\")` inside a `"""..."""` block — Quartz interpolates these at SPEC compile-time, not subprocess runtime, so compilation failed with QZ0403 "Undefined variable: p1/p2/p3/ar/sum". Already in memory file (`feedback_quartz_module_quirks.md`); fix: build runtime output via `str_from_int(...) + ...` concat. The memory note is now load-bearing — every alloc-spec author runs into this.

3. **`.quartz-cache/` pollution between alloc-spec runs.** Running `alloc_default_handlers_spec.qz` followed by `alloc_blessed_default_spec.qz` without clearing the cache produces "Undefined symbols: _main" linker errors. Already in memory file (`feedback_quartz_cache_pollution.md`). Pattern: `rm -rf .quartz-cache` before each spec invocation when running multiple specs in sequence.

**A.5 is structurally done.** Stdlib handler library is the substrate Phase B's `Alloc.in_arena(arena)` ergonomic sugar will sit on top of. The D5 throw-on-refusal pattern is locked in across counter + deny handlers. Roadmap A.6 (spec coverage expansion — install/uninstall, isolation, recursion-bypass, throw-on-deny in user code) is the natural follow-on; once A.6 + A.7 (flag flip) ship, Phase B handler ergonomics is unblocked.

Next session entry: **Phase A.6 (spec coverage expansion)**. Target ~15-20 new tests covering install/uninstall ordering, multi-handler isolation, recursion-bypass under custom handlers, edge cases (zero-byte alloc, very large alloc, dealloc of null-equivalent). Then **A.7 — Flag flip**: change `--alloc-routing` default to ON, delete the flag entirely (Prime Directive 7). Headline number from A.4 still applies — alloc-heavy code 3.6% overhead, push-heavy 0%, real-world workloads 3-4% peak.

---

**2026-04-26 (continuation 4)** — Phase A.4 shipped (single commit, codegen + pipeline + spec).

- **A.4 — Static fast-path optimization for the Alloc-effect wrapper.** Three coordinated changes; fixpoint preserved at 2346 functions byte-identical:
  1. **`codegen_runtime.qz` wrappers**: `@__qz_alloc` and `@__qz_dealloc` definitions now declare the `alwaysinline` function attribute. Without this, even the trivial routing=off body (`call @malloc; ret`) stayed as an out-of-line call because the build pipeline uses `llc` (not `clang -O1+`), and the AlwaysInliner pass is part of `opt`/`clang`'s IR-level optimization, not `llc`'s codegen-level passes.
  2. **`codegen_runtime.qz` blessed-handler watermark**: New `@__qz_alloc_blessed_watermark` global (linkonce_odr / internal, default 0). `cg_emit_effect_main_prelude` writes the value of `__qz_effect_stack_top` immediately AFTER the blessed-default install sequence. The wrapper checks `top <= bw` to detect "no user `with Alloc {...}` is on top of the blessed defaults" and short-circuits to direct `@malloc`. Reordering matters: the watermark check goes FIRST (cheap, no TLS), and only on miss do we touch the `__qz_alloc_in_handler` TLS flag (rare slow path). Stage-1 catches the common case at ~2 cycles after inlining.
  3. **Build pipelines (`Quakefile.qz` + `tools/quake.qz`)**: Inserted `opt --passes=always-inline` between quartz IR emission and `llc` for every build mode — debug build, release build, guard's gen1 build, user-program builds via `compile_quakefile`. Release mode chains `mergefunc` after for monomorph dedup. Multi-path opt lookup mirrors the existing llc lookup (PATH first, then Homebrew + Linux LLVM bin dirs).

- **A.4 verification**: Inspected the rebuilt gen1 binary directly — `@__qz_alloc` exists as a linkonce_odr symbol with **0 callers**; `bl 0x<malloc-stub>` direct calls dominate (7569 direct mallocs, 4042 direct frees). The wrapper folded at every site. Vec-push tight-loop benchmark (50 outer × 200000 inner = 10M push ops) shows **zero regression**: 28ms median for both pre-A.4 (golden) and post-A.4 routing=off+inlined. Alloc-heavy benchmark (1M iters × 2 mallocs/iter = 2M total): routing=off 28ms, routing=on (with watermark fast-path) 29ms — **3.6% overhead** for routing=on with no user handler installed (just the inline `top <= bw` check + branch). Acceptable for the contextual capability.

- **A.4 spec**: New `spec/qspec/alloc_fast_path_a4_spec.qz` — 4 tests locking in (a) wrapper definitions declare `alwaysinline`, (b) watermark global declared + initialized in main prelude, (c) routing=on wrapper body checks watermark before TLS bypass-flag, (d) end-to-end behavior — handler fires INSIDE `with Alloc {...}` block, bypassed OUTSIDE the block via watermark fast-path. All 4/4 green. Existing 6 alloc_intercept_a3b tests + 3 alloc_blessed_default tests + 3 alloc_default_handlers tests + 3 alloc_effect_decl tests still green. Smoke tests on `examples/style_demo.qz` + `examples/brainfuck.qz` clean.

**Key gotchas surfaced this session**:

1. **`llc` does not run the inliner pass**. I tested this empirically before changing the pipeline — `llc -filetype=obj` on a tiny IR with `linkonce_odr alwaysinline` definitions does NOT inline the wrapper. Only `opt --passes=always-inline` (or `opt -O1+` / `clang -O1+`) honors the attribute. So the `alwaysinline` attribute alone is insufficient — the pipeline must include an `opt` step. Mac and Linux both ship `opt` alongside `llc` in standard LLVM installs, so this isn't a new dependency.

2. **TLS load ordering matters for hot-path overhead**. Initial wrapper layout did the TLS load (`__qz_alloc_in_handler`) AND the global load (`__qz_effect_stack_top`/`@__qz_alloc_blessed_watermark`) up front, then OR'd the conditions. Even though the inlined check is cheap, the TLS load is more expensive on macOS than the regular global load. Reordering to "stage 1: watermark check (no TLS); stage 2 (only on miss): TLS bypass check" shaved ~1ms off the alloc-heavy benchmark — `or i1` in the slow path cuts roughly the same number of cycles, but the TLS load is hidden behind a less-taken branch. Nets to a measurable win.

3. **Triple-quote spec-string interpolation gotcha (re-encountered)**. My initial `_SCOPE_SRC` had `puts(\"inside=#{inside_calls}\")` inside a `"""..."""` block — Quartz interpolates these at SPEC compile-time, not subprocess runtime, so the spec failed with "Undefined variable: inside_calls". Already in memory file (`feedback_quartz_module_quirks.md`); fix: emit two literal sentinel `puts` lines instead of a single interpolated one. This is the third time this pattern has bitten in the alloc work alone.

4. **`QUARTZ_COMPILER` env var inheritance for QSpec**. Running spec files via the bare `quartz spec/qspec/foo_spec.qz | llc | clang | run` pattern fails on the `assert_*_with_flags` tests with "QUARTZ_COMPILER not set" because the spec runner subprocess-invokes the compiler. Set `export QUARTZ_COMPILER=$(pwd)/self-hosted/bin/quartz` before the spec invocation. Already in memory file.

5. **`__qz_gen_yield_capture` undefined references in stripped-down test programs**. A bench program that doesn't `import * from std/gen` references the symbol via `cg_emit_effect_main_prelude`'s install line but lacks the definition. Workaround: add `import * from std/gen` to the test program. (Or alternatively, audit the prelude install to skip the Yield handler when std/gen isn't imported — out of scope for A.4.)

**A.4 is structurally done.** Wrappers fold at every call site (verified by binary inspection — 0 wrapper callers, 7569 direct mallocs); routing=on with no user handler short-circuits via the watermark check at ~3.6% overhead vs routing=off; routing=on with user handler still routes correctly through perform. The `--alloc-routing` flag flip in **A.7** is now feasible — the worst-case "user paid the routing flag but installed no handler" scenario costs ~3.6% on alloc-heavy code, ~0% on push-heavy code. Real-world workloads dominated by malloc → ~3-4% peak overhead; everything else effectively zero.

Next session entry: **Phase A.5 (stdlib handlers — arena/counter/deny/tracking + D5 lock-in)**. Each handler is a one-liner per the design memo's D3 — `arena_alloc_handler` forwards to `arena_alloc(arena, size)`; `counter_alloc_handler` tracks total bytes + throws via `Throws<AllocError>` on over-budget; `deny_alloc_handler` always throws; `tracking_alloc_handler` writes to a stats sink. D5 (failure mode) gets locked in here — recommendation still `Throws<AllocError>` over null-return. Spec coverage at ~15-20 tests for the handler library. Sized 4-6 hours = single quartz-day session.

---

**2026-04-26 (continuation 3)** — Phase A.3.c shipped (7 commits, full per-file migration sweep + bootstrap stress test).

- **A.3.c.1 — Wrapper + byte-semantics flip** (commit `2c984648`). Emit `@__qz_alloc(i64 bytes) -> ptr` and `@__qz_dealloc(ptr) -> void` runtime wrappers in `codegen_runtime.qz`. Always emitted as `linkonce_odr`; body shape depends on `--alloc-routing`:
  - off (default): `entry: %p = call ptr @malloc(i64 %bytes); ret ptr %p`. LLVM inlines to direct malloc — zero overhead preserved.
  - on: bypass-flag check on `@__qz_alloc_in_handler`, then either direct `@malloc`/`@free` (in-handler bypass — avoids infinite recursion) or `__qz_effect_perform(Alloc, alloc/dealloc, ...)`.
  - `mem_alloc`/`mem_free` codegen in `cg_intrinsic_memory.qz` collapsed from 50+ inline-branch lines to a single wrapper call. Wrapper owns the routing decision now.
  - `cg_emit_effect_runtime` gained an `alloc_routing` parameter; threaded from `state.alloc_routing` at four call sites.
  - **Byte semantics flip**: `mem_alloc(N)` now allocates N BYTES (was N slots × 8). Audit of every existing `mem_alloc` call site (~30 across `std/*` and `self-hosted/shared/repl.qz`) revealed they were ALL passing byte counts (`KEVENT_SIZE()`, `NET_BUF_SIZE()`, `16` for sockaddr_in, `8` for struct winsize, etc.) — pre-A.3.c was silently 8×-over-allocating in every case. Switching to bytes is a correctness fix, not just a stylistic preference. User-visible `alloc(size)` effect op also flipped to bytes; runtime `__qz_default_alloc_handler` dropped its `mul size, 8`. Three pre-existing alloc specs converted slot→byte counts (`alloc(2)` → `alloc(16)`, `alloc(1)` → `alloc(8)`, `alloc(3)` → `alloc(24)`). Fixpoint preserved at 2346 functions (was 2344 — the +2 are the wrappers themselves).
- **A.3.c.2 — Eliminated as standalone** (handled inside A.3.c.1 — `mem_alloc`/`mem_free` codegen migrated to wrapper as part of the wrapper-introduction commit; no need for separate phase).
- **A.3.c.3 — Small intrinsic files** (commit `1debe3e5`). Mechanical sweep across `cg_intrinsic_set.qz` (5 sites), `cg_intrinsic_string.qz` (5 sites), `cg_intrinsic_sb.qz` (6 sites), `cg_intrinsic_io.qz` (2 sites). Replace `call ptr @malloc(...)` → `call ptr @__qz_alloc(...)` and `call void @free(ptr ...)` → `call void @__qz_dealloc(ptr ...)`. Fixpoint 2346 byte-identical.
- **A.3.c.4 — Medium intrinsic files** (commit `953fe7aa`). Same pattern across `cg_intrinsic_regex.qz` (13), `cg_intrinsic_collection.qz` (5), `cg_intrinsic_intmap.qz` (12), `cg_intrinsic_data.qz` (14), `cg_intrinsic_vec.qz` (13) — ~57 sites. Fixpoint preserved.
- **A.3.c.5 — Concurrency files + MIR_ALLOC** (commit `469db5b5`). Six concurrency-intrinsic files (~62 sites): `cg_intrinsic_conc_async.qz` (12), `cg_intrinsic_conc_channel.qz` (13 — 3 used `noalias` attribute not picked up by A.3.c.3's regex; updated regex), `cg_intrinsic_conc_channel_try.qz` (8), `cg_intrinsic_conc_sched.qz` (3), `cg_intrinsic_conc_sync.qz` (11), `cg_intrinsic_conc_task.qz` (12). PLUS `codegen_instr.qz` MIR_ALLOC + MIR_ALLOC_STACK (3 sites) — biggest single-file blast radius so far because MIR_ALLOC handles every `Foo { ... }` struct heap allocation. Off-path stays zero-cost (wrapper inlines), on-path catches every struct-heap-alloc through the user's installed Alloc handler.
- **A.3.c.6 — Memory + binary** (commit `cb0fb381`). `cg_intrinsic_memory.qz` arena/pool sites (24, excluding `mem_alloc`/`mem_free` already wrappered in A.3.c.1) + `cg_intrinsic_binary.qz` (27). The arena/pool migration enables nested-arena composition: a `with Alloc.in_arena(outer) do ...` block that creates an inner arena now allocates the inner arena's storage from outer — emerges from the substrate without any arena-specific plumbing.
- **A.3.c.7 — Runtime hot-path** (commit `434f66ff`). The big one — 61 sites in `codegen_runtime.qz`, the file defining every runtime helper compiled binaries link against (qz_vec_new, qz_str_concat, sb_*, qz_map_*, channel/mutex/cond/timer/scheduler/io_uring/poll-table/work-queue/JSON/sprintf/backtrace). Used global sed + targeted reverts to preserve the 6 sites inside the default Alloc handler body and inside the wrapper bodies themselves (otherwise infinite recursion). With this commit landed, the per-file migration sweep is COMPLETE — every codegen `@malloc`/`@free` emit site now flows through the wrapper.
- **A.3.c.8 — Universal coverage spec + bootstrap stress test** (commit forthcoming with this session log update). Extended `spec/qspec/alloc_intercept_a3b_spec.qz` with a 6th test that runs Vec/String operations under `--alloc-routing=on` with a tracking handler installed; asserts the handler counted `>1` allocations — proving coverage extends beyond `mem_alloc`/`mem_free` into stdlib-internal helpers. Bootstrap stress test (manual, not committed): used the regular compiler binary to compile `self-hosted/quartz.qz` with `--alloc-routing=on`, linked the result into a 6.4MB binary, then THAT binary self-hosted to the same byte count, reports `quartz 5.12.21-alpha` correctly. Proves end-to-end that compiling with all internal allocations routed through the Alloc effect (default handler servicing them via @malloc) produces a working compiler.

**Key gotchas surfaced this session**:

1. **`noalias ptr @malloc` attribute variant**. Initial regex `s|call ptr @malloc(|call ptr @__qz_alloc(|g` missed sites that emit `call noalias ptr @malloc(...)` (cg_intrinsic_conc_channel.qz, codegen_instr.qz). Updated regex to handle both forms.

2. **codegen_runtime.qz internal-helper preservation**. The default Alloc handler body and the wrapper bodies themselves MUST call `@malloc`/`@free` directly — routing them via `@__qz_alloc` would either bypass-back-to-malloc (the wrapper's direct branch fires under bypass-flag, which `__qz_effect_perform` sets around handler invocation) OR infinite-recurse via perform when not bypassing. Used global-sed-then-targeted-revert to preserve the 6 sites that must stay direct.

3. **Byte-semantics safety audit**. Before flipping `mem_alloc(N)` from slots to bytes, audited all ~30 existing call sites in `std/*` and `self-hosted/`. Every one passed byte-counts. The pre-A.3.c slot semantics over-allocated 8× silently — switching to bytes finally lets `terminal.qz term_read_byte` allocate exactly 1 byte (not 8), and `kevent` buffers fit exactly. Three alloc specs needed updating (`alloc(N)` storing at slot 0 → `alloc(N*8)` to keep the i64 store fitting) but no behavior regression.

4. **Triple-quote spec-string interpolation gotcha** (already in memory file `feedback_quartz_module_quirks.md` from Phase 4D.4d). My initial coverage-test source had `puts(\"covered_few:#{alloc_calls}\")` in a `"""..."""` snippet — interpolated at SPEC compile-time, not at the subprocess's runtime. Fixed by dropping the variable embedding and using literal-only strings. Re-confirmed the lesson; no new memo needed.

5. **CLI-flag stdlib-path resolution**. The compiler binary auto-detects stdlib relative to its install location. `/tmp/stress/quartz_routing` (built outside the repo) couldn't find `std/gen` etc. without explicit `-I .` (project root). Added to bootstrap-stress-test invocation. Already known but worth restating.

**A.3.c is structurally done.** The headline claim from the design memo's intro ("dogfooding compiler arenas is *one `with Alloc` block away*") is now accurate. Phase D (compiler arena dogfood — wrap `compile()` entry in `with Alloc.in_arena(a) do ... end`) and Phase E (per-task arenas in scheduler) are unblocked.

Next session entry: **Phase A.4 (static fast-path optimization)**. Ensure that when no `with Alloc` block is lexically active and no `can Alloc` row is in scope, codegen emits the wrapper call AND LLVM inlines it back to a direct `@malloc`. Mirror the G-extended fast-path used by the kind=1 effect machinery. Verify zero overhead via benchmarks (`vec_push` tight loop, expect <2% regression vs pre-A.3.c baseline). After A.4 lands, the `--alloc-routing` flag can flip default-on (Phase A.7).

---

**2026-04-26 (continuation 2)** — Phase A.3.b shipped + codegen-layer codename cleanup + Phase A.3.c filed.

- **A.3.b — `mem_alloc`/`mem_free` codegen routing through the Alloc effect.** Three changes, fixpoint preserved at 2344 functions byte-identical:
  1. **`codegen_util.qz`**: New `alloc_routing: Int` field in `CodegenState` (mirrors `race_mode`/`stack_alloc`/`overflow_check`) + `cg_set_alloc_routing` setter.
  2. **`codegen_runtime.qz`**: Declare `@__qz_alloc_in_handler` (linkonce_odr/internal `thread_local global i64 0`) — TLS bypass-during-handler flag. In `__qz_effect_perform` at `do_call:`, save current flag, conditionally set to 1 via `cstr_eq` against `@__qz_eff_name_alloc` + `select`, call handler, restore. Non-Alloc effects pay one TLS load + select + store (~2ns) — negligible against the existing 10-100ns scan cost.
  3. **`cg_intrinsic_memory.qz`**: When `state.alloc_routing == 1`, both `mem_alloc` and `mem_free` emit a runtime branch on `@__qz_alloc_in_handler`: bypass=1 → direct `@malloc`/`@free`, bypass=0 → `__qz_effect_perform(@__qz_eff_name_alloc, @__qz_eff_op_{alloc,dealloc}, 1, &args, 1)`. The result phi'd from both branches.
  4. **`quartz.qz`**: Registered `--alloc-routing` flag in `argparser_flag` (must be in the registry, not just `parsed_has`, or the strict parser rejects the flag at help-text validation). Plumbed through `compile()` and the four codegen entry points (`cg_codegen`, `cg_codegen_debug`, `cg_codegen_separate`, `cg_codegen_incremental`).
  5. **`spec/qspec/alloc_intercept_a3b_spec.qz`**: 5-test acceptance spec — IR-shape (off path keeps `@malloc`, on path emits `@__qz_eff_name_alloc` + `@__qz_alloc_in_handler`), end-to-end behavior (off bypasses user handler, on intercepts), and reentrancy (handler that calls `mem_alloc` itself doesn't infinite-recurse). All 5/5 green. The spec uses the existing `assert_*_with_flags` qspec helpers in `std/qspec/subprocess.qz`. Smoke tests on `examples/style_demo.qz` + `examples/brainfuck.qz` clean.

- **Codename cleanup in codegen layer.** Per user feedback during A.3.b implementation, scrubbed "Piezo" / "Piezoelectric Effects" project-codename references from the codegen layer (`self-hosted/backend/`), preserving historical milestone tags as descriptive prefixes:
  - `; piezo: perform_op effect=...` → `; effect: perform_op effect=...` (3 IR breadcrumbs in `codegen_instr.qz` — these were emitted into compiled binaries' .ll output, the most user-visible offense).
  - `; === Piezoelectric Effects runtime (Milestone D.1) ===` → `; === Effects runtime (Milestone D.1) ===` (IR section header).
  - `; piezo D.4 / P3.B: ...` → `; effect runtime D.4 / P3.B: ...` (IR comment in main prelude).
  - Source-comment milestone tags `Piezo F.3b` / `Piezo P3.0a` / `Piezo G.1` etc → `Effects F.3b` / `Effects P3.0a` / `Effects G.1` (preserves the milestone identifier, drops the codename).
  - Section headers `## Operation Piezoelectric Effects, Phase X, Milestone Y` → `## Effects-system Phase X.Y` style.
  - Files touched: `codegen_ctx.qz`, `codegen_instr.qz`, `codegen_runtime.qz`, `codegen_separate.qz`, `codegen.qz`, `mir.qz`, `mir_lower.qz`, `mir_lower_expr_handlers.qz`, `mir_lower_gen.qz`. Pure cosmetic — no behavior change. Pre-existing `Piezo` / `Piezoelectric Effects` references in spec headers (`## Operation Piezoelectric Effects, Phase X, Milestone Y` in ~70 spec files), test function names (`piezo_decl_double`, etc.), and spec file names (`piezo_async_*_spec.qz`) were intentionally left as historical project-epic codename usage — those don't escape into compiled binaries or user-facing surfaces.

- **A.3.c filing (the surprise).** During A.3.b spec authoring, discovered that `vec_new<Int>().push(7)` in a test program does NOT trigger A.3.b's routing — `vec_new` lowers to `qz_vec_new()` runtime function (in `codegen_runtime.qz`) which hardcodes `call ptr @malloc(i64 32)`, completely bypassing the `mem_alloc` intrinsic. Audit revealed **~178 raw `@malloc(...)` emit sites across 18 codegen files** in `self-hosted/backend/`:

  | File | `@malloc` emit sites |
  |---|---|
  | `codegen_runtime.qz` | 61 (inside emitted runtime fns: `qz_vec_new`, `qz_str_concat`, `qz_sb_*`, `qz_map_*`, etc.) |
  | `cg_intrinsic_binary.qz` | 27 (Binary DSL allocator) |
  | `cg_intrinsic_memory.qz` | 15 (one of which — `mem_alloc` — is what A.3.b actually intercepts; arenas/pools bypass) |
  | `cg_intrinsic_vec.qz` | 11 (Vec growth) |
  | `cg_intrinsic_data.qz` | 9 (data structures) |
  | `cg_intrinsic_intmap.qz` | 8 (IntMap) |
  | `cg_intrinsic_conc_*` (4 files) | ~24 (channels, sync, tasks, async) |
  | 9 other intrinsic files | ~24 (regex, sb, set, string, io, sched) |
  | **TOTAL** | **~178 sites** |

  A.3.b catches ONE of those 178 sites. The design memo's headline insight — "dogfooding compiler arenas is *one `with Alloc` block away*" — is structurally false on this substrate. Wrapping `compile()` in `with Alloc.in_arena(a) do ... end` would catch <1% of actual allocation traffic.

  Fix is mechanical: emit a single `@__qz_alloc(i64 bytes) -> ptr` runtime wrapper that does the bypass-flag check + perform-or-malloc decision once, then migrate every codegen `cg_emit_line(out, ".x = call ptr @malloc(i64 N)")` literal to `call ptr @__qz_alloc(i64 N)`. ~1-2 quartz-days for the migration; fixpoint-safe by tautology because the off-path emits direct malloc identically to today. Phase D (compiler arena dogfood) and Phase E (per-task arenas) both depend on A.3.c — neither can deliver the promised behavior without it. See "A.3.c design lock-in" below for the implementation checklist.

**A.3.c design lock-in (deferred to next session)**:

1. **Wrapper signature**: `i64 (i64 bytes) -> i64 ptr_as_i64`. Single byte-count argument (not slot count) so call sites that already compute `mul i64 N, 8` can pass the byte total directly. Returns pointer-as-i64 for compatibility with the existing `inttoptr` chain at every call site.

   ```llvm
   define linkonce_odr ptr @__qz_alloc(i64 %bytes) nounwind {
   entry:
     %in_h = load i64, ptr @__qz_alloc_in_handler, align 8
     %bypass = icmp ne i64 %in_h, 0
     br i1 %bypass, label %direct, label %via_eff
   direct:
     %dptr = call ptr @malloc(i64 %bytes)
     ret ptr %dptr
   via_eff:
     %argv = alloca i64, i64 1, align 8
     store i64 %bytes, ptr %argv, align 8
     %epi = call i64 @__qz_effect_perform(ptr @__qz_eff_name_alloc, ptr @__qz_eff_op_alloc, i64 1, ptr %argv, i64 1)
     %eptr = inttoptr i64 %epi to ptr
     ret ptr %eptr
   via_eff_off:
     ; A.3.c-OFF path: when alloc_routing is 0 at codegen time, emit a
     ; trivial wrapper that's identical to a direct @malloc call (lets
     ; LLVM inline it away). Or skip wrapper entirely — emit raw
     ; @malloc as today and only emit @__qz_alloc declaration when ON.
     ret ptr null
   end
   ```

   When `--alloc-routing=off`, the wrapper is unnecessary; A.3.c migration leaves the existing `@malloc` calls in place. When `--alloc-routing=on`, the wrapper is emitted and ALL the migrated sites pick up the routing for free.

   **Important wrinkle**: the `mem_alloc` intrinsic uses slot-count semantics (multiplies by 8), but `qz_vec_new` etc. emit byte-count `@malloc(i64 32)` literals. The wrapper takes BYTES; existing call sites already in byte form are clean migrations; `mem_alloc`'s codegen will need to keep its `mul i64 N, 8` and pass the result. Cleaner to unify by deleting the slot-vs-bytes split too, but that's scope creep — leave for A.3.c followup if needed.

2. **The default Alloc handler signature mismatch**: today's `@__qz_default_alloc_handler` (in `codegen_runtime.qz`) reads argv[0] as a SLOT count and multiplies by 8. With the byte-based wrapper, argv[0] is bytes — so we need to either (a) pass slot-count from the wrapper's perform call (just do `udiv %bytes, 8` or pass the original `mem_alloc` slot count when known) or (b) flip the default handler to byte semantics and migrate user handlers (`std/alloc.qz` `default_alloc_handler` etc.) along with it. Option (b) is cleaner; option (a) preserves existing user-handler API.

   Recommendation: option (b) (byte semantics throughout). User handlers see bytes natively. The slot-count interpretation was a Quartz-internal quirk; byte-count matches every other allocator API on the planet. Migration cost: ~3 lines in `std/alloc.qz` + update specs.

3. **Migration ordering**: per-file commits, each fixpoint-checked. Suggested order (smallest blast-radius first):
   - `cg_intrinsic_set.qz` (3 sites — easy warmup)
   - `cg_intrinsic_string.qz` (3 sites)
   - `cg_intrinsic_sb.qz` (3 sites)
   - `cg_intrinsic_io.qz` (1 site)
   - `cg_intrinsic_regex.qz` (7 sites)
   - `cg_intrinsic_collection.qz` (5 sites)
   - `cg_intrinsic_conc_*` (channels, sync, tasks, async — 4 files, ~24 sites total)
   - `cg_intrinsic_intmap.qz` (8 sites)
   - `cg_intrinsic_data.qz` (9 sites)
   - `cg_intrinsic_vec.qz` (11 sites)
   - `cg_intrinsic_memory.qz` (14 non-`mem_alloc` sites — arenas, pools)
   - `cg_intrinsic_binary.qz` (27 sites)
   - `codegen_runtime.qz` (61 sites — the hot path; do this last, with extra smoke testing because it touches every Vec/String/Map operation)

4. **Bootstrap concern**: `--alloc-routing=off` (default) still emits direct `@malloc`. The wrapper is conditionally emitted only when ON, OR it's emitted always but with body equivalent to a direct call when OFF (LLVM inlining optimizes away the wrapper). Compiler binary builds with the flag off → no behavioral change → fixpoint preserved. When `--alloc-routing=on` (manual experiment, eventually Phase D dogfood), every Vec/String/Map/closure/channel/task allocation routes through Alloc — this is the dogfood substrate.

5. **Phase scope**: 1-2 quartz-days. The migration itself is mechanical sed-style work; the design call (slot vs byte semantics, wrapper inlining) is the only judgment call.

**2026-04-26 (continuation)** — Phase A.2 stdlib defaults + Phase A.3.a runtime-blessed prelude install shipped.

- **A.2 — Stdlib default handlers** (1 commit, `332cfa64`). Added `default_alloc_handler` and `default_dealloc_handler` to `std/alloc.qz`. They forward to `mem_alloc` / `mem_free` and follow the FileIo per-op convention (`fio_default_read` etc.). User-callable; composable into custom handler chains. Compiler binary unchanged — additive stdlib-only change. 3-test spec at `spec/qspec/alloc_default_handlers_spec.qz` locks the API: passthrough, custom-composition (mixed install), loop stress. All 3/3 green; A.1 specs unaffected.

- **A.3.a — Runtime-blessed prelude install** (1 commit, `9b6b8afe`). Two source changes + a new spec, behind `quake guard` (fixpoint preserved at 2343 functions byte-identical):
  1. **`codegen_runtime.qz`**: Emit `@__qz_eff_name_alloc`, `@__qz_eff_op_alloc`, `@__qz_eff_op_dealloc` string globals (linkonce_odr + internal flavors). Emit `@__qz_default_alloc_handler` inline LLVM IR — dispatches on op name, calls `@malloc(size * 8)` for the alloc branch and `@free(ptr)` for the dealloc branch. Install in `cg_emit_effect_main_prelude` (op_filter=null catches both ops).
  2. **`typecheck_expr_handlers.qz`**: Add `Alloc` to the blessed-relaxation OR check (line 1639). Bare `alloc(N)` / `dealloc(p)` calls now bypass the `can Alloc` requirement, just like `Throws/Log/FileIo/Intern`.
  3. **`spec/qspec/alloc_blessed_default_spec.qz`**: New 3-test spec — module-level alloc/dealloc works without with-block; user `with Alloc { alloc: h, dealloc: h2 } do body end` overrides; post-with calls fall back to the prelude default. All 3/3 green. Smoke tests on `examples/style_demo.qz` + `examples/brainfuck.qz` clean against the new binary.

  **User-visible effect**: the explicit-install ceremony documented in A.2 (`with Alloc { alloc: default_alloc_handler, dealloc: default_dealloc_handler } do ... end`) is no longer needed for the default-allocator case. Bare `alloc(N)` / `dealloc(p)` now Just Works at module level. Custom handlers via `with Alloc` still compose on top via the standard handler-stack top-down scan.

  **Bootstrap safety**: the compiler source itself never calls user-visible `alloc()` or `dealloc()` (it uses the `mem_alloc` / `mem_free` intrinsics directly), so the new typecheck rule never fires during self-compile. The runtime install runs at every compiled binary's `qz_main` entry but adds only one `@__qz_effect_handle_install` call — negligible startup cost.

  **Not yet shipped**: internal `mem_alloc` / `mem_free` calls (in `vec_new`, `Vec.push`, `String.concat`, etc.) still bypass the Alloc effect entirely — they emit direct `@malloc` / `@free`. That's Phase A.3.b's codegen-routing work, gated behind `--alloc-routing`.

**A.3.b design lock-in (deferred to next session)**: After substantial design exploration this session, we converged on the following architecture for A.3.b:

1. **Routing mechanism**: per design memo D2, the choice is between (A) TLS function pointer + per-install trampoline synthesis vs (B) effect-perform per allocation. Recommendation: **B** for A.3.b/A.4, with A as a future optimization if benchmarks demand it. Rationale: (a) reuses existing `__qz_effect_perform` machinery; (b) no per-install trampoline-synthesis complexity; (c) Phase A.4's static fast-path already gives zero-overhead for default-program code. The handler-stack scan cost (~10-100ns per alloc when in `with Alloc` block) is acceptable for the contextual capability — sandboxing/test-isolation/per-task-arena workloads have already opted in to handler routing.

2. **Bypass-during-handler (D4)**: handler-recursion is a CORRECTNESS issue, not a perf optimization, because handlers that allocate during normal work (e.g., `puts("alloc:#{size}")` for tracing) would infinite-recurse. Design: TLS flag `@__qz_alloc_in_handler` (i64, default 0). In `cg_intrinsic_memory.qz`'s `mem_alloc` codegen (when `--alloc-routing` is set): branch on `in_handler` — when 1, emit direct `@malloc`; when 0, emit `__qz_effect_perform` for Alloc/alloc. Same shape for `mem_free`. The flag set/restore is generic — added inside `__qz_effect_perform`'s scan loop, conditionally on effect-name == "Alloc". This is a small special-case in the generic perform code, ~6 lines.

3. **--alloc-routing CLI flag**: new flag in `quartz.qz` argv parser. Threaded through `compile()` to codegen state (alongside `race_mode`, `stack_alloc`, `overflow_check`). Default off — A.3.b ships gated. A.7 flips the default and deletes the flag (per project Directive 7 — no flag-gate after stable).

4. **Bootstrap concern**: when `--alloc-routing` is OFF (the default), `mem_alloc` / `mem_free` codegen emits direct `@malloc` / `@free` as today — no behavioral change. Compiler builds itself with the flag off; A.3.b commits stay byte-identical-fixpoint-clean. When the flag is ON (manual experiment / Phase D dogfood), every Vec/String/closure-env allocation routes through Alloc — this is the dogfood substrate. Bootstrap binary stays on the off path; gen1 == gen2 still holds.

5. **Phase scope**: A.3.b is sized at 4-6 hours per the original memo, but the bypass-during-handler logic adds ~1 hour. Realistic estimate: 5-7 quartz-hours = 1-1.5 quartz-days = single session.

**2026-04-26** — Phase A.0 substrate prep + Phase A.1 declaration shipped.

- **A.0 — Builtin namespace cleanup** (3 commits, unplanned but mandatory). The original A.1 plan called for `effect Alloc { def alloc; def dealloc }`, which collides with the existing `alloc`/`free` low-level memory builtins (102+ call sites in stdlib + self-hosted + spec). Per the intrinsic-name-shadow trap (memory file `feedback_intrinsic_name_shadow.md`), declaring an effect op shadowing a registered builtin SIGSEGVs the compiler the moment any caller invokes it. Resolved with three-commit dual-register-then-rename-then-cleanup pattern that preserved the bootstrap chain at every step:
  - `23cf72e0` — A.0a — dual-register `mem_alloc`/`mem_free` alongside `alloc`/`free` in `typecheck_builtins.qz`, `intrinsic_registry.qz`, `cg_intrinsic_memory.qz`, `codegen_c.qz`. Binary now knows both names.
  - `d4a953c6` — A.0b — mass-rename 104 alloc + 84 free call sites + 16 internal `mir_emit_intrinsic("free", ...)` strings. Three parallel sub-agents handled std/, self-hosted/, spec/qspec/+tools/ on disjoint scopes. Excluded: `extern "C" def free/alloc` libc bindings (5 sites), `def free()` impl methods on collection types (6 sites), WASM-target internal synth naming, LLVM/C codegen string emissions (`@free`, `free((void*)...)`).
  - `189574c4` — A.0c — drop legacy `alloc`/`free` registrations + simplify dispatch branches. Old names now correctly error `QZ0401: Undefined function`.

  Each of the 3 commits passed `quake guard` (fixpoint 2342 functions byte-identical) and smoke tests against `examples/style_demo.qz` and `examples/brainfuck.qz`. The `alloc`/`free` namespace is now reserved for the effect.

- **A.1 — Effect declaration** (1 commit, `9cf96bbb`). Created `std/alloc.qz` with the minimal `effect Alloc { def alloc(size: Int): CPtr; def dealloc(ptr: CPtr): Void }` shape per D1. Both ops kind=1 (continuation) — no `= resume(0)` body markers because allocation has no unwind/abort semantics. Created `spec/qspec/alloc_effect_decl_spec.qz` with 3 tests locking in: handler intercepts alloc with size arg, round-trips through handler-allocated memory, dealloc handler fires once per call. All 3/3 green. Fixpoint preserved (the compiler doesn't import `std/alloc`; addition is purely additive). NOT auto-imported via prelude — users explicitly `import std/alloc`.

**Key gotchas surfaced this session**:

1. **Intrinsic-name shadow trap on effect ops.** Effect-op declarations are `def`s at module scope. They collide with same-named registered builtins identically to free-function shadowing. Pre-flight check: `grep "tc_register_builtin.*\"<name>\"" self-hosted/middle/typecheck_builtins.qz` before declaring any effect op. Already in memory file but worth restating: this is the ONLY trap that requires substrate work BEFORE the effect file exists.

2. **Bootstrap-chain ordering for builtin renames.** Single-atomic rename of a builtin doesn't bootstrap — current binary doesn't know the new name when typechecking the new source. The dual-register-then-migrate-then-cleanup three-commit pattern is mandatory whenever a builtin name needs renaming. Document this as the canonical playbook.

3. **`describe`/`it` qspec API shape.** Current API is `describe("...") do ->` and `it("...") do ->` (no ctx parameter). The CLAUDE.md example shows the older `describe do ctx ->` / `it(ctx, "...") do ->` shape — outdated.

**Open D5 (failure mode) status**: still deferred. The effect signature is `CPtr` regardless of refusal semantics. Will be locked in at Phase A.5 (counter handler) when handler-side semantics actually matter.

---

## Summary

Three coupled goals, sequenced:

1. **Ship the `Alloc` effect** so user code can swap allocators (test isolation, sandboxing, deterministic builds, per-task arenas, resource budgets).
2. **Dogfood arenas in the compiler** by installing arena-backed Alloc handlers at phase boundaries, so the compiler runs on its own arenas without rewriting any allocation site.
3. **Beef up arenas where dogfooding exposes gaps** (we'll discover them; document only the speculative list now).

The Trojan-horse insight: **(2) is mostly free once (1) lands.** Installing an arena-backed Alloc handler at the entry of `compile()` is one `with` block. No allocation-site rewriting needed. The static fast-path the Piezo runtime already ships keeps zero-overhead behavior when the default handler is installed.

---

## Why this is the right next move

- **Closes the Piezo loop.** `Alloc` was on the v6.0 blessed effect set; deferring it left an obvious capability gap.
- **Capability-unlocking, not optimization.** Test isolation, sandboxing, per-task arenas, deterministic addresses — none of these are achievable without an Alloc effect.
- **Builds directly on freshly-shipped Piezo machinery.** kind=1 op dispatch, default handlers, install/uninstall, G-extended fast path all exist. Adding one more effect is a stdlib change + small runtime hook, not a new substrate.
- **Compiler dogfood becomes one-line install instead of multi-week rewrite.** Phase 4 of the compiler memory plan (item 19/20 in ROADMAP) called for per-phase arenas with bespoke borrow-checker integration. Dogfooding through Alloc sidesteps that work.
- **Surfaces real user wins.** "Quartz lets you sandbox a function call's memory" is a concrete differentiator — Rust's allocator API is unergonomic, Go has no story, Zig has explicit allocator parameters everywhere. An effect-based Alloc with default-malloc handler is *invisible by default, powerful when wielded*. Aligns with the design philosophy.

---

## Goals

- **G1**: User-facing `effect Alloc { alloc, dealloc }` declared in `std/alloc.qz`, installable via `with Alloc { alloc: my_h, dealloc: my_h2 } do body end`.
- **G2**: Default handler is malloc/free; **zero overhead** when no custom handler is installed (static fast-path, codegen emits direct `@malloc`/`@free`).
- **G3**: Stdlib handler library: arena-backed, counter-budget, deny-all, tracking, deterministic, pool-backed.
- **G4**: Compiler installs an arena-backed Alloc handler at `compile()` entry, transparently dogfooding arenas through the entire compile pipeline. RSS measurement before/after to quantify.
- **G5**: A user can write `with TestAlloc do test_fn() end` and get automatic memory cleanup at scope exit. Deterministic, leak-impossible test isolation.
- **G6**: Per-task arenas land in the scheduler — every `go` task gets a per-task arena that frees when the task ends. Erlang/BEAM-style structured memory for free.

## Non-goals

- **NG1**: Rewriting individual compiler allocation sites. The point of (2) is that we DON'T do this. If we end up needing per-site rewrites, that's a sign the Alloc effect's pervasiveness is wrong — go fix the substrate.
- **NG2**: Multi-shot alloc handlers (deferred with the rest of `Ndet`).
- **NG3**: Changing the user-facing arena API. `std/memory.qz` and `arena_*` intrinsics stay as-is. Alloc is the *handler interface*; arenas are the *handler implementation*.
- **NG4**: Alloc-aware borrow checker work. Current borrow checker already enforces arena-use-after-invalidate via QZ1401; Alloc handlers just route allocations to existing arena machinery, which keeps existing safety guarantees.
- **NG5**: Custom allocators for embedded targets / kernel build (separate concern; Alloc effect is the right substrate later, but kernel allocator design lives in the kernel epic).

---

## Open design decisions (to close before Phase A.1)

### D1: Effect signature

Three candidate shapes:

```qz
# Minimal — just alloc/dealloc
effect Alloc {
  def alloc(size: Int): CPtr
  def dealloc(ptr: CPtr): Void
}

# Aligned — let the handler decide alignment
effect Alloc {
  def alloc(size: Int, align: Int): CPtr
  def dealloc(ptr: CPtr): Void
}

# Full — alloc/dealloc/realloc/zeroed
effect Alloc {
  def alloc(size: Int): CPtr
  def dealloc(ptr: CPtr): Void
  def realloc(ptr: CPtr, new_size: Int): CPtr
  def alloc_zeroed(size: Int): CPtr
}
```

**Recommendation**: minimal. Quartz always 8-byte-aligns; `realloc` and `alloc_zeroed` can be derived (handler implements internally if it wants). Keeps the surface small, mirrors how `Throws` / `State` shipped (single canonical op, derive the rest). Add ops later if a real handler needs them.

### D2: Dispatch mechanism — pervasive TLS pointer vs. per-callsite effect perform

**The core implementation question.** Two flavors:

**Option A — TLS function pointer** (recommended)
- Runtime maintains a TLS slot `__qz_alloc_fn`. Default value: `&qz_malloc`.
- Every emitted `qz_malloc(size)` becomes `((alloc_fn_t)__qz_alloc_fn)(size)` — one indirect call.
- Install pushes old pointer, swaps to new; uninstall restores.
- Cost: one TLS load + one indirect call per allocation. ~1-2 ns.
- Pro: every `Vec.push` / `String.concat` / closure-env malloc respects the current handler — real containment.
- Con: indirect call has minor cost. Modern allocators are themselves TLS-based (jemalloc/mimalloc), so this is one extra TLS load relative to direct.

**Option B — Effect runtime perform at every alloc site**
- Every `qz_malloc(size)` becomes `__qz_effect_perform(Alloc, alloc, [size])`.
- Cost: handler-stack scan (~10-100 ns/alloc in Piezo benchmarks).
- Pro: uses existing effect machinery, no new runtime hook.
- Con: ~10× slower than A. Allocation-heavy workloads would feel it.

**Option C — Surface-only Alloc**
- Only user-typed `@heap X`, `@scratch X` route through Alloc.
- Stdlib internals (`Vec.push`'s grow, `String.concat`) stay direct.
- Pro: zero runtime cost, additive, easy.
- Con: kills the dogfood story. Sandboxing leaks because `Vec.push` allocates outside the handler. Compiler dogfood (G4) doesn't work — most compiler allocs are stdlib-internal.

**Recommendation: A** with the static fast-path optimization Piezo already ships:
- When codegen sees that no `with Alloc` is lexically active AND the function isn't bounded by `can Alloc`, emit direct `@qz_malloc(size)` (no TLS load).
- Otherwise emit the TLS-indirect call.
- For the compiler dogfood case (G4), the entire compile body is wrapped in `with Alloc`, so all interior allocs go indirect. Ergonomic and correct.

This means: **default-program performance is unchanged**, custom-handler performance pays one indirection per allocation (acceptable for the capability unlock).

### D3: Bridge to existing arena machinery

`std/memory.qz` already has `Arena: Drop` with `Allocator` trait. Alloc handlers should be one-liners:

```qz
def arena_alloc_handler(arena: Arena): Fn(Int): CPtr can {} =
  size -> arena_alloc(arena.handle, size)

# Dealloc is no-op for arena (memory frees with arena drop)
def arena_dealloc_handler: Fn(CPtr): Void can {} =
  ptr -> ()
```

Boilerplate-free composition — `with Alloc(arena_alloc_handler(my_arena), arena_dealloc_handler) do ... end`. We may want sugar: `with Alloc.in_arena(my_arena) do ... end`.

### D4: Reentrancy — handler-allocates-during-alloc

A handler that itself allocates while servicing an alloc op recurses. Three options:

- **Forbid**: detect recursion at runtime, panic. Hostile to handler authors.
- **Bypass**: while inside a handler, install reverts to default temporarily. Subtle but correct.
- **Allow**: trust handler authors to manage. Simplest; handlers that recurse get what they deserve.

Most-similar prior art: Rust's `Allocator` trait forbids recursion implicitly (no handler-stack to recurse through); Koka effect handlers handle it via continuation discipline (we're single-shot, doesn't apply).

**Recommendation: Bypass.** While the runtime is inside `__qz_alloc_fn`, the TLS slot temporarily reverts to `&qz_malloc`. Handler can allocate freely; doesn't recurse. One-line save/restore. Document the rule.

### D5: Failure mode — handler returns null / refuses

What does the runtime do when the handler returns 0/null (deny-all sandbox, over-budget, OOM)?

- Panic with a typed error (`AllocFailed`)?
- Throw via existing `Throws<AllocError>`?
- Return null and let the caller deal (matches malloc convention)?

**Recommendation**: Throw via `Throws<AllocError>`. Three reasons: (a) `Throws` is already shipped and ergonomic, (b) callers can install `with Throws { throw: graceful_handler }` to recover, (c) matches user mental model — refused allocations are exceptional, not a return-code dance. This couples Alloc to Throws, which is fine because Throws is ubiquitous; the relationship is `effect Alloc { ... } can Throws<AllocError>`.

### D6: Surface vs pervasive boundary, revisited

If we go with Option A (TLS pointer) + static fast-path, the boundary becomes:

- **Default**: every `qz_malloc` site goes direct (zero overhead). No Alloc semantics — pre-Alloc behavior preserved.
- **`with Alloc { ... } do body end`** lexically: every `qz_malloc` site in `body`'s static call graph routes through the TLS pointer.
- **`can Alloc` annotated function**: same — body uses TLS-indirect.

Effectively: pay-as-you-go. Programs that don't use Alloc see zero cost.

---

## Recommended path

Going with the recommendations from D1-D6:

- Minimal effect signature (D1).
- TLS-pointer dispatch with static fast-path (D2-A).
- Stdlib handlers wrap existing arena/pool intrinsics (D3).
- Reentrancy via bypass-during-handler (D4).
- Failure throws `Throws<AllocError>` (D5).
- Pay-as-you-go boundary (D6).

This keeps the substrate small, aligns with Piezo's existing machinery, and unlocks every user-facing capability the user wanted in this discussion.

---

## Phased mini-roadmap

Effort estimates in quartz-time. Pull-in/defer markers reflect dependencies.

### Phase A — `Alloc` effect foundation (~1-2 quartz-days)

Ship the substrate. No compiler dogfood yet — just user-facing capability.

| # | Item | Effort | Notes |
|---|---|---|---|
| A.0a | Dual-register `mem_alloc`/`mem_free` builtins | 30 min | ✅ **DONE 2026-04-26 (`23cf72e0`)** — Substrate prep that surfaced when the original A.1 plan hit the intrinsic-name-shadow trap. See "Session log" above. |
| A.0b | Mass-rename 104+ `alloc(`/`free(` call sites + 16 MIR-emission strings | 30 min (3 parallel agents) | ✅ **DONE 2026-04-26 (`d4a953c6`)** — std/, self-hosted/, spec/qspec/ + tools/. |
| A.0c | Drop legacy `alloc`/`free` builtin registrations | 15 min | ✅ **DONE 2026-04-26 (`189574c4`)** — Old names now QZ0401 errors, namespace freed for the effect. |
| A.1 | `effect Alloc { alloc, dealloc }` declaration in `std/alloc.qz` | 1-2 hours | ✅ **DONE 2026-04-26 (`9cf96bbb`)** — Minimal D1 shape, both ops kind=1, 3 declaration-lock specs all green. NOT auto-imported via prelude (explicit `import std/alloc`). |
| A.2 | Stdlib default handler functions in `std/alloc.qz` | 1-2 hours | ✅ **DONE 2026-04-26 (`332cfa64`)** — `default_alloc_handler` / `default_dealloc_handler` forward to `mem_alloc`/`mem_free`. Per-op convention (mirrors FileIo's `fio_default_*`). 3-test spec at `spec/qspec/alloc_default_handlers_spec.qz` — passthrough, custom-composition, loop stress. Compiler binary unchanged. |
| A.3.a | Runtime-blessed prelude install + typecheck blessed-relaxation | 1-2 hours | ✅ **DONE 2026-04-26 (`9b6b8afe`)** — Inline LLVM IR `@__qz_default_alloc_handler` emitted in `codegen_runtime.qz`, installed in `cg_emit_effect_main_prelude`. `Alloc` added to the blessed set in `typecheck_expr_handlers.qz`. Bare `alloc(N)` / `dealloc(p)` now Just Works at module level. 3-test spec at `spec/qspec/alloc_blessed_default_spec.qz`. Fixpoint preserved at 2343 functions. |
| A.3.b | `mem_alloc`/`mem_free` codegen routing through Alloc when `--alloc-routing` is set | 4-6 hours | ✅ **DONE 2026-04-26** — Effect-perform-per-alloc routing in `cg_intrinsic_memory.qz`. Bypass-during-handler TLS flag (`@__qz_alloc_in_handler`) set/restored in `__qz_effect_perform` `do_call:`. New `--alloc-routing` CLI flag plumbed through `compile()` → `cg_codegen{,_debug,_separate,_incremental}`. Default off — flag-gated. 5-test spec at `spec/qspec/alloc_intercept_a3b_spec.qz`. Fixpoint preserved at 2344 functions. |
| A.3.c | Unify allocation primitive — single `__qz_alloc(bytes)` runtime wrapper | 1-2 quartz-days | ✅ **DONE 2026-04-26** — Seven-commit sweep (`2c984648` → `434f66ff`). `@__qz_alloc(i64 bytes) -> ptr` and `@__qz_dealloc(ptr) -> void` wrappers always emitted as `linkonce_odr`; body shape conditional on `--alloc-routing` (off = direct `call @malloc; ret`, on = bypass-check + via_eff routing). Migrated ~178 raw `@malloc`/`@free` emit sites across 18 codegen files (set/string/sb/io/regex/collection/intmap/data/vec/conc_*/memory/binary/codegen_instr.qz/codegen_runtime.qz). Plus byte-semantics flip: `mem_alloc(N)` now allocates N bytes (was N slots × 8) — every existing call site already passed byte counts; pre-A.3.c was silently 8×-over-allocating. Fixpoint preserved at 2346 functions (was 2344, +2 wrappers). 6-test acceptance spec covering off/on routing + reentrancy + Vec/String coverage. Bootstrap stress test: routing-on-built compiler self-hosts to a working 6.4MB binary. Phase D/E unblocked. |
| A.4 | Static fast-path optimization | 2-4 hours | ✅ **DONE 2026-04-26** — Wrappers `alwaysinline`; build pipeline runs `opt --passes=always-inline` at every mode (debug, release, guard, user binaries). Routing-on path adds a stage-1 `top <= bw` watermark check (no TLS) before the stage-2 `__qz_alloc_in_handler` flag (rare slow path). Wrapper folds at every site (0 callers in gen1; 7569 direct mallocs). Vec-push tight-loop benchmark zero regression vs golden. Alloc-heavy benchmark 3.6% overhead at routing=on with no user handler — acceptable for the contextual capability. 4-test spec at `spec/qspec/alloc_fast_path_a4_spec.qz`. Fixpoint 2346. |
| A.5 | Stdlib handlers — `arena_alloc_handler`, `counter_alloc_handler`, `deny_alloc_handler`, `tracking_alloc_handler` | 4-6 hours | ✅ **DONE 2026-04-27** — Four handler families in `std/alloc.qz` with module-global state + `alloc_set_*` setters. **D5 lock-in**: counter + deny handlers throw via `Throws` on refusal — composes with runtime-blessed default (process exit 66) and user `with Throws` recovery frames. 18-test acceptance spec at `spec/qspec/alloc_stdlib_handlers_a5_spec.qz` (3 arena + 5 counter + 3 deny + 4 tracking + 3 composition). Compiler binary unchanged. Known limitation: bypass-flag leak across handler-thrown longjmp — filed for runtime fix. |
| A.6 | Spec coverage — install/uninstall, nested handlers, isolation, recursion-bypass, throw-on-deny | 4-6 hours | ✅ **DONE 2026-04-27** — 12 new tests at `spec/qspec/alloc_a6_coverage_spec.qz` across (A) multi-level nesting / handler stack discipline (3-deep nest innermost wins, outer-after-inner reverts, 3-fold sequential install isolation), (B) recursion-bypass stress under routing=on (handler builds Vec<Int>, handler does `puts()` with str_concat, 3-deep helper chain that allocates), (C) edge cases (alloc(0) → handler observes size=0; dealloc(NULL) → handler observes ptr=0; counter handler with single-request-larger-than-budget throws), (D) D5 throw-on-deny composition (outer Throws catches deny; bypass-flag-leak regression locks in current broken behavior; control test confirming bypass restores correctly when no throw fires). **Compiler bug surfaced + fixed**: A.4's static fast-path (`codegen_instr.qz` G.2) skipped `@__qz_alloc_in_handler` save/store around the direct handler call. Effect: any Alloc handler invoked via the fast-path that itself allocated (Vec push, str_concat, etc.) infinite-recursed under routing=on because the wrapper saw in_h=0 → via_eff → re-entered the same handler. Fix mirrors `__qz_effect_perform`'s pattern at lines 839-850; gated on `_po_eff == "Alloc"`; ~10 LOC. Fixpoint 2346 byte-identical. All 6 prior alloc specs + 12 new A.6 tests + style_demo/brainfuck smoke tests pass. |
| A.7 | Flag flip — delete `--alloc-routing` once stable | 1 hour | ✅ **DONE 2026-04-27** — Flag deleted outright per Prime Directive 7 (no flag-default-on transitional state). `argparser_flag` registration + two `parsed_has` reads + `compile()` parameter cascade through `cg_codegen{,_debug,_separate,_incremental}` → `cg_emit_effect_runtime` all removed. `CodegenState.alloc_routing` field + `cg_set_alloc_routing` setter deleted. Wrapper body in `cg_emit_effect_runtime` collapsed to always emit the watermark+bypass-flag routing-on shape. 4 specs migrated off `_with_flags("--alloc-routing")` → plain `assert_*`; 8 test sources updated to capture totals inside the with-block and `puts(...)` outside (so str_from_int/concat allocations route through the blessed default rather than perturbing user-handler counts). Fixpoint 2345 byte-identical (-1 from A.6's 2346 = the deleted setter). All 7 alloc specs green (48 tests). Smoke tests on style_demo + brainfuck clean. |
| A.3.d | Realloc-path coverage — `@__qz_realloc` wrapper for the 13 raw `@realloc` sites A.3.c missed | half quartz-day | ✅ **DONE 2026-04-27** — `@__qz_realloc(ptr old, i64 old_bytes, i64 new_bytes) -> ptr` wrapper emitted in `codegen_runtime.qz` right after `@__qz_alloc`/`@__qz_dealloc` with the same two-stage fast-path shape (watermark + bypass-flag) plus an `alwaysinline` attribute. **Routing strategy**: DECOMPOSE rather than extend the Alloc effect with a third op — when a user handler is in scope, route as `alloc(new_bytes) + memcpy(min(old, new)) + dealloc(old)` via the existing two-op surface. Keeps D1 minimal preserved; every existing stdlib handler (arena/counter/deny/tracking) works transparently without a `realloc` op. Trade-off: arena handlers lose the "last-alloc-in-arena bump-extend" optimization (filed as a perf followup if it matters). Edge cases handled in wrapper: `realloc(NULL, N) → alloc(N)` (skip memcpy + dealloc), `realloc(p, 0) → dealloc(p), return NULL`. Migrated 13 emit sites (bug doc undercounted as 3): `codegen_runtime.qz` × 3 (qz_vec_push + insert + push_runtime), `cg_intrinsic_sb.qz` × 4 (StringBuilder grow paths), `cg_intrinsic_vec.qz` × 3 (shrink_to_fit + width-aware grow + resize), `cg_intrinsic_conc_task.qz` × 2 (task_group results + frames), `cg_intrinsic_regex.qz` × 1. Each migrated site emits `oldbytes = mul cap, ew` (or equivalent — element width is 8 in most paths, runtime ew in the width-aware grow site, raw `cap` in SB where cap is byte-counted) before the wrapper call. Fixpoint 2347 byte-identical (+1 from B.5's 2346 = the new wrapper). 5-test acceptance spec at `spec/qspec/alloc_realloc_a3d_spec.qz`: D1 Vec.push past initial cap routes through TestAlloc arena (the original SIGABRT repro from the bug doc), D2 tracking handler observes alloc+dealloc decomposition (5 allocs + 3 deallocs for 64 pushes from cap=8), D3 String.concat through SB realloc routes through handler, D4 deny_all refuses Vec growth, D5 with_budget refuses Vec growth past budget. Phase D realloc-bypass blocker closed. Bug doc moved to ✅ FIXED at `docs/bugs/ALLOC_REALLOC_BYPASS.md`. |

**Exit criterion**: user can write `with Alloc(my_handler) do code end` and observe handler controls every allocation in `code`. Default-handler programs run with zero RSS/time delta vs pre-Alloc.

**Risks**: TLS-pointer dispatch at every alloc may surface unexpected hot-path costs. Mitigation: static fast-path covers the common case; benchmarks before flag-delete.

### Phase B — User-facing handler library + ergonomics (~2 quartz-days)

Build out the capability surface so the *user wins* aren't just demos. Sub-divides
into a substrate slice (B.0) that closes the runtime-hardening + per-install-state
gaps and a sugar slice (B.1-B.4) that sits on top.

| # | Item | Effort | Notes |
|---|---|---|---|
| B.0a | Bypass-flag longjmp safety — per-with-block `@__qz_alloc_in_handler` save/restore | 1-2 hours | ✅ **DONE 2026-04-27** — Each with-block snapshots `@__qz_alloc_in_handler` before its `setjmp` and restores from the snapshot at `wb.catch`. Covers the case where an Alloc handler `throw(...)` longjmps out of `__qz_effect_perform` past the inline post-handler restore. Restoring to the saved value (not zero) preserves the invariant when the with-block is nested inside an outer handler body. ~10 LOC in `codegen_instr.qz` + comment refresh in `codegen_runtime.qz`/`std/alloc.qz`. The D2 regression test in `alloc_a6_coverage_spec` flipped from `bypass_flag_leak_present` to `bypass_flag_leak_fixed`. Fixpoint preserved at 2345. All 7 alloc specs (48 tests) green; non-Alloc effect/generator specs sample green except the pre-existing nested-while-yield bug. |
| B.0b | Per-install env slot | — | ✅ **DONE** — subsumed by `state_slots[]` unification. The original design called for a parallel `__qz_effect_stack_envs[256]` array; the implementation chose to reuse the existing `@__qz_effect_stack_state_slots` array (already TLS, already 256-cap, already wired through `__qz_effect_state_get/set`). `mir_emit_handle_install`'s `init_state_reg` parameter (`mir.qz:4091`) IS the env-threading mechanism — when ≥0, codegen emits `state_slots[pretop+i] = init_state_reg` for each install entry (`codegen_instr.qz:2209-2253`, fan-out across multi-entry installs). No new symbol, no migration. State-and-env-as-the-same-slot was the right call: the two concepts are isomorphic at the runtime level (per-install i64 cell). |
| B.0c | Call-form surface for env (`with Alloc.in_arena(arena) do ... end`) | — | ✅ **DONE 2026-04-27** — Method-dispatch via `_mir_method_dispatch_entries(ctx, eff_name, method_name, entries)` in `mir_lower.qz:864-915`. Recognizes `Alloc.in_arena` / `Alloc.deny_all` / `Alloc.with_budget`; pushes (op_filter, handler) pairs per op. The call's first arg becomes `nw_init_state_reg`, threaded through `mir_emit_handle_install` to populate state_slots. Env-aware handlers (`arena_alloc_handler_e`, `budget_alloc_handler_e`) read via `__qz_effect_state_get()`. |
| B.1 | `Alloc.in_arena(arena)` sugar — arena-backed Alloc install | 2-3 hours | ✅ **DONE 2026-04-27** — `with Alloc.in_arena(my_arena) do ... end`. Stdlib helper that builds the call-form on top of B.0c. Env-aware `arena_alloc_handler_e` reads arena from env via `__qz_effect_state_get()` and forwards to `arena_alloc`; dealloc is no-op (arena bulk-frees). 5-test spec at `alloc_in_arena_b1_spec.qz`. |
| B.2 | `with TestAlloc do test_body() end` — test isolation handler | 2-3 hours | ✅ **DONE 2026-04-27** — Bare-IDENT alias for an Alloc install backed by a singleton test arena. `tc_with_handler_begin` rewrites `TestAlloc` → `Alloc` lookup at typecheck; mir_lower's bare-IDENT branch redirects to Alloc with arena handlers + env=`test_alloc_arena_acquire()` (singleton, lazy-init, reset on each acquire). 5-test spec at `alloc_test_alloc_b2_spec.qz`. Limitation: nested TestAlloc shares the singleton — per-scope arena lifecycle awaits per-install teardown substrate. |
| B.3 | `with Alloc.deny_all do untrusted() end` — sandbox handler | 1-2 hours | ✅ **DONE 2026-04-27** — Method-dispatch entry reuses A.5's stateless `deny_alloc_handler` / `deny_dealloc_handler`. Every alloc throws via `Throws` ("Alloc: allocation denied (sandbox)"); dealloc forwards to mem_free so caller can free pre-sandbox memory. 5-test spec at `alloc_deny_all_b3_spec.qz` (some test patterns rewritten to avoid the filed cross-scope longjmp bug). |
| B.4 | `with Alloc.with_budget(N) do ... end` — counter-tracked handler | 2-3 hours | ✅ **DONE 2026-04-27** — Single-slot remaining-budget pattern. Env-aware `budget_alloc_handler_e` reads remaining via `state_get()`, throws if `size > remaining`, else `state_set(remaining - size)` + forward to `mem_alloc`. The originally-planned 2-slot heap-alloc'd state struct was unnecessary — single-slot remaining gives equivalent semantics with no install-time alloc/free. 5-test spec at `alloc_with_budget_b4_spec.qz`. |
| B.5 | Documentation in `docs/QUARTZ_REFERENCE.md` and new `docs/ALLOC.md` | 2-3 hours | ✅ **DONE 2026-04-27** — New `docs/ALLOC.md` covers full surface: effect decl, runtime routing pipeline, handler ABI, four call-form sugars, refusal semantics, reentrancy, composition, what does NOT route (realloc, stack, FFI), performance numbers. New "Alloc Effect" subsection in `docs/QUARTZ_REFERENCE.md` Memory section with short user-facing snapshot + cross-link to ALLOC.md. Reference's Basic subsection updated `free(ptr)` → `dealloc(ptr)`. |

**Exit criterion**: each handler in B.1-B.4 has a 5-test acceptance spec covering nesting, sequential isolation, and recovery composition. `docs/ALLOC.md` is the canonical reference.

**Phase B followups** (filed, deferred until needed):
- **Closures as handlers** — `with Alloc { alloc: { size -> arena_alloc(captured_arena, size) } } do ... end`. Strictly more general than B.0c's call-form — `with E { op: closure }` would extract `(fn_ptr, env_ptr)` from the closure expression and thread both through `MIR_HANDLE_INSTALL` (env in B.0b's slot, fn_ptr in the existing handler slot). The handler ABI gains an env parameter (via the standard Quartz closure-call convention). Pull-in trigger: a real user pattern needing lexical capture beyond what call-form sugars provide (e.g., test fixtures with mid-test state, multi-effect handlers that share captured locals). Substrate cost is moderate — closures are already i128-shaped at runtime; the install-side change is reading both halves and the perform-side change is honoring the env parameter when set. Documented to lock in the design call before someone reaches for it ad hoc.
- **Stack-top mis-restore on cross-scope longjmp** — when inner with-Alloc's `wb.done` never runs because longjmp targets outer with-Throws's setjmp, but outer's `wb.done` decrements `top` by N (its own pop count), inner's entry stays on the stack while outer's gets popped. Likely fix: each with-block stashes its install index in setjmp scratch and the catch path restores `__qz_effect_stack_top` to that index, instead of relying on uninstall counter arithmetic. Independent of B.0a (which only restores the bypass flag, not the stack pointer). Not blocking Phase B sugar.

### Phase C — Compiler dogfood prep (design-only; ~half a quartz-day) ✅ DONE 2026-04-27

Decide the seams BEFORE writing code.

| # | Item | Effort | Notes |
|---|---|---|---|
| C.1 | Allocation hot-spot inventory in compiler | 2-3 hours | ✅ **DONE 2026-04-27** — Self-compile baseline captured via `--memory-stats`. Peak 1.92 GB / 1.85 GB footprint, wall 36.7s, IR 1.8M lines. Codegen +973 MB / typecheck +617 MB dominate. `tracking_alloc_handler` instrumentation deferred — RSS deltas alone were sufficient for seam-selection. |
| C.2 | Decide arena seams (per-phase vs per-function vs per-pass) | Discussion | ✅ **DONE 2026-04-27** — Two seams chosen: D.1 codegen-module arena, D.2 typecheck-module arena. Per-function arenas deferred until per-module measured. Parse/resolve/mir don't justify own seams (deltas too small or output too large). |
| C.3 | Decide which seams keep heap allocation (cross-phase data) | Discussion | ✅ **DONE 2026-04-27** — Confirmed by reading `compile()`: AST + all_funcs + mir_prog + llvm_ir all escape (heap). TC scratch (the +617 freed by `tc_free`) is the recoverable typecheck arena bytes. Codegen scratch (intermediate StringBuilders, mangled-name caches, intrinsic registry scratch) is the recoverable codegen arena bytes. |

**Exit criterion**: ✅ MET — Phase D sub-plan landed in next subsection.

### Phase C findings + Phase D sub-plan (2026-04-27)

**One-page Phase D sub-plan as required by C exit criterion.**

#### Baseline (clean cache, post-A.3.d, --memory-stats only)

| Phase | RSS End MB | Δ MB | Wall ms |
|---|---|---|---|
| init→lex→parse | 4 | +4 | 8 |
| resolve | 177 | +173 | 1100 |
| typecheck | 794 | +617 | 6315 |
| tc_free | 795 | +1 | 5 |
| mir | 949 | +154 | 7327 |
| codegen | 1922 | +973 | 21916 |

Peak RSS 1.92 GB. Peak footprint 1.85 GB (matches the design memo's original "1.86 GB" target). Wall 36.7s. Codegen dominates (+973 MB, 60% of wall). Typecheck second (+617 MB, 17%).

#### Cross-phase escape map (must heap-allocate; arena cannot hold)

- **AST nodes** (ast_storage + root): live for whole compile() — read by codegen too (verified `codegen.qz:806/887/917`).
- **ResolverEntry vec** (`all_funcs`): same lifetime as AST.
- **MIR program** (`mir_prog`): produced by mir, consumed by codegen.
- **Final LLVM IR string** (`llvm_ir` + `extern_decls`): returned by compile().
- **Global string-pool entries** (`intern_global()`): cross-phase invariant.
- **TC interface hashes** (computed from `tc` BEFORE `tc_free` runs): used post-tc_free for incremental cache.
- **Diagnostic buffers**: emitted post-error.

#### Arena-bound (per-phase scratch; arena recoverable)

- **Codegen**: per-function StringBuilder accumulators, mangled-name cache strings, intrinsic-registry lookup scratch, debug-info table builders, type-string formatting buffers, fragment Vec<String>'s before final concat. **Estimated arena recovery: 500-700 MB** of the +973 MB codegen delta (50-70% factor from `feedback_rss_deltas_overstate_live_set`).
- **Typecheck**: TcScope binding tables (the 30+ vecs `tc_free` already releases — see typecheck_util.qz:3138-3192), TcSafety borrow-tracking arrays, walk-state stacks, generic substitution Maps, type-error formatting buffers, mangled-name resolution scratch. **Estimated arena recovery: 400-500 MB** of the +617 MB typecheck delta.

Combined recovery target: **900-1200 MB** → peak RSS drops from 1.92 GB to ~750 MB-1.05 GB.

#### Phase D phasing (revised from original strawman)

| # | Seam | Location | Escape protocol | Effort | Order |
|---|---|---|---|---|---|
| D.0 | `arena_promote_string(a, s)` helper | `std/memory.qz` | New stdlib function: `mem_alloc(s.size+1) + memcpy(s.bytes, s.size+1)` then return as `String`. ~10 LOC. | 30 min | First |
| D.1 | Codegen module arena | `compile()` wraps `cg_codegen` (and `cg_codegen_debug`/`cg_codegen_separate`/`cg_codegen_incremental`) in `with Alloc.in_arena(cg_arena) do ... end`. Final `llvm_ir` and `extern_decls` go through `arena_promote_string` before the arena drops. | One String boundary copy of ~50 MB — far cheaper than the +973 MB savings. | 1 quartz-day | Second |
| D.2 | Typecheck module arena | `compile()` wraps the typecheck function-loop in `with Alloc.in_arena(tc_arena) do ... end`. TC interface hashes (computed BEFORE tc_free) materialize via `arena_promote_string` — they're already explicitly captured in `_iface_hashes` Vec. | TC interface hashes, diagnostic buffers, warnings list — all promoted. | 1-2 quartz-days | Third |
| D.3 | Benchmark + measure | `quake build` self-compile w/ `--memory-stats` before/after each seam. | — | half-day | Last |

Per-function arenas (D.2-finer-granularity, D.3-codegen-finer-granularity in the original plan) **deferred**. Pull-in trigger: D.1+D.2 don't hit the <1 GB target.

#### Exit criteria

- **D.1 alone**: peak RSS ≤ 1.4 GB (down from 1.92), wall within ±5% of 36.7s baseline.
- **D.1 + D.2**: peak RSS < 1 GB, wall < 32s.
- **Failure mode**: if D.1 doesn't hit ≥400 MB peak-RSS reduction, the "allocator-retained pages dominate codegen delta" hypothesis is wrong — pause and instrument with `tracking_alloc_handler` to get net live bytes before continuing.

#### Rollback shape

Each seam is one self-contained commit. Revert = remove `with Alloc.in_arena(arena) do ... end` wrapper and the matching `arena_promote_string` calls at the boundary. No other code touched. Fixpoint preserved at every commit boundary because Alloc is post-A.7 universal — wrapping is purely a runtime-handler swap, not a code-shape change.

#### Risks (refined from original Phase D risks)

| Risk | Probability | Mitigation |
|---|---|---|
| Forgotten escape — some Vec/String inside cg_codegen needs to outlive the arena but isn't promoted | Medium | Run smoke tests (style_demo, brainfuck) after D.1. Verify final IR roundtrips. Fixpoint catches IR-level differences. |
| `arena_promote_string` allocates inside the arena scope (recursion) | Low | Implementation must call `mem_alloc` directly with a `with Alloc do ... end` to install default handler temporarily, OR call `__qz_alloc_in_handler`-aware `mem_alloc_heap` if we add one. Document the escape pattern. |
| RSS reduction is smaller than expected (allocator-retained pages aren't dominant) | Medium | Instrument with `tracking_alloc_handler` to get live-bytes measurement before going to D.2. The 50-70% recovery factor is an estimate. |
| Wall-time regression from arena chain-walking on hot paths | Low | Arenas already production-grade (mmap-backed, growth chains). Per-allocation overhead ~equal to malloc. Worst case: tune arena initial block size. |

**Substrate prerequisites verified**: `Alloc.in_arena(arena)` (B.1, `9b6b8afe`+`a0b47117`), `arena_alloc_handler_e` env-aware handler (B.1), realloc routing (A.3.d, `4e2fe23f`). Phase D needs only `arena_promote_string` (D.0) before D.1 can ship.

### Phase D — Compiler arena dogfood (~2-3 quartz-days, multi-session)

Install Alloc handlers at compiler phase boundaries. No allocation-site rewrites. **Refined post-C** to two module-scoped seams; per-function granularity deferred.

| # | Item | Effort | Notes |
|---|---|---|---|
| D.0 | `arena_promote_string(a, s)` stdlib helper | 30 min | ✅ **DONE 2026-04-27** (`65b5a1cd`) — `def arena_promote_string(s: String): String = str_byte_slice(s, 0, str_byte_len(s))`. Smoke-tested. Substrate prep for D.1+. Retained even after D.1 rollback. |
| D.0.b | `arena_promote_vec_string(v)` helper | 30 min | DRAFTED + reverted — no consumer post-D.1-blocker per PD7. Re-add when D.1 retry lands. |
| D.1 | Codegen module arena | 1 quartz-day | 🔴 **BLOCKED 2026-04-27** — `Alloc.in_arena` + heavy-codegen produces corrupt IR under `--debug`. Filed `docs/bugs/D1_ALLOC_IN_ARENA_HEAVY_CODEGEN_CORRUPTION.md`. Roll-back complete; pre-D.1 binary restored. **Next**: write minimal repro spec as TDD-RED, then chase the substrate fix per the bug doc's six-step debugging plan. |
| D.2 | Typecheck module arena | 1-2 quartz-days | Sequenced after D.1 unblocks. Wrap the typecheck function-loop with `with Alloc.in_arena(tc_arena) do ... end`. Promote interface hashes (already captured in `_iface_hashes` pre-tc_free). **Target: -400 to -500 MB on the typecheck +617 MB delta.** |
| D.3 | Benchmark + measure | half-day | Self-compile RSS + wall before/after each seam. Target: peak RSS < 1 GB, wall < 32s. |

**Exit criteria**: D.1 alone → peak RSS ≤ 1.4 GB, wall within ±5% of 36.7s. D.1 + D.2 → peak RSS < 1 GB, wall < 32s.

**Failure mode**: if D.1 doesn't hit ≥400 MB peak-RSS reduction, the "allocator-retained pages dominate codegen delta" hypothesis is wrong — pause and instrument with `tracking_alloc_handler` to get net live-bytes measurement before continuing to D.2.

**Risk**: arena-bound Strings/Vecs that need to outlive the arena via paths other than the explicit `arena_promote_string` site. Mitigation: each seam is one commit; smoke-test (style_demo + brainfuck) and fixpoint verify after D.1 before going to D.2. **Per-function arenas deferred**: pull-in trigger is "D.1+D.2 don't hit <1 GB target".

### Phase E — Per-task arenas in scheduler (multi-session, sequenced after K.1)

The Erlang/BEAM-style structured-memory win. **Original "1-2 quartz-day" estimate was wrong** — auto-via-keyword + escape semantics + multi-worker safety are independent compiler-level concerns that don't fit in one slice. Sub-phased now after E.1.a's investigation:

| # | Item | Effort | Status | Notes |
|---|---|---|---|---|
| **E.1.a** | **Opt-in `go_arena(f)` stdlib API** | **0.5 quartz-day** | ✅ **SHIPPED 2026-04-28** | `go_arena(f)` wraps `f`'s body in `with Alloc.in_arena(arena_new(8192)) do -> f() end`. Pure stdlib (~30 LOC in `std/concurrency.qz`). 5-test spec at `spec/qspec/alloc_e1_per_task_arena_spec.qz` (basic + isolation + parallel + 50-sequential leak-free + sentinel passthrough). |
| E.1.b | Auto-arena via `go` keyword | 0.5 quartz-day | ✅ **SHIPPED 2026-04-28** | MIR-level AST synthesis at the NODE_GO branch: when `go fn(args)` targets a top-level user function with a value-typed return (Int/Bool/Void/Float/Char/CPtr/Symbol + sized-width variants), compiler rewrites to `go (-> { var ar = arena_new(8192); var r = with Alloc.in_arena(ar) do -> fn(args) end; arena_destroy(ar); r })` — existing go-lambda machinery handles capture collection, $poll/$new generation, and E.1.c.b snapshot inheritance. Conservative gate: skips reference-typed returns (would dangle after arena_destroy until E.4 escape mechanism), lambda forms (`go (-> body)()` — avoids double-wrap with `go_arena`'s internal `go (-> _go_arena_body(f))`), unknown callees (extern/intrinsic/local fn-typed bindings), and programs that don't import std/alloc (suffix-search for `arena_alloc_handler_e` in resolver — without it, codegen would emit dangling `@arena_alloc_handler_e` link refs). Three new helpers in `mir_lower.qz`: `_mir_is_value_typed_annotation` / `_mir_should_auto_arena` / `_mir_synthesize_arena_wrap`. New 4-test spec `alloc_e1b_keyword_auto_arena_spec.qz` covers absorbed-vs-direct count, String-return survives-await regression, lambda-form skip, parallel sched_init(0). Fixpoint 2399 (was 2396, +3 helpers). The original "2-3 quartz-days" estimate assumed a frame-layout extension + $poll prologue/epilogue injection; AST-level synthesis turned out to be ~10x simpler because the existing go-lambda lowering machinery already handles every concern (captures, frame, suspend/resume across yields). |
| E.1.c | Multi-worker effect-stack TLS fix | 1-2 quartz-days | ✅ **SHIPPED 2026-04-28** | All effect-stack arrays + watermark TLS; per-worker `__qz_effect_install_defaults` at `__qz_sched_worker` entry. Bug `docs/bugs/EFFECT_STACK_TOP_GLOBAL_MULTI_WORKER_RACE.md` RESOLVED. Semantic shift: handlers installed on main not visible to goroutines (followed up by E.1.c.b). |
| E.1.c.b | Spawn-time effect-stack snapshot for handler inheritance | 0.5-1 quartz-day | ✅ **SHIPPED 2026-04-28** | Default `__qz_default_async_handler` `do_spawn_call` block now calls `__qz_effect_snapshot_capture()` (copies user entries above blessed_watermark into a heap buffer: name+handler+filter+state_slot per entry, buf=0 since cross-thread longjmp is UB) and `__qz_task_snapshot_register(frame, snap)` to insert into the new `@__qz_task_snapshots` side-table (4-i64 layout: array + count + capacity=256 + mutex_ptr; init'd alongside completion_map in `__qz_sched_init`). Worker's `__qz_sched_worker` $poll dispatch site calls `__qz_task_snapshot_lookup(frame)` (zero-count fast-path skip), then `__qz_effect_snapshot_apply(snap)` which returns the count of pushes; after poll_fn returns, worker subtracts that count from TLS top — drops snapshot pushes while preserving body's in-flight `with`-block installs across yield/suspend boundaries. Task completion (both `task_done` and `panic_caught` paths) calls `__qz_task_snapshot_take(frame)` + `__qz_effect_snapshot_free(snap)`. New 5-test spec `alloc_e1cb_handler_inheritance_spec.qz` covers basic + multi-worker + sequential + no-parent-install regression + 100-iter lifetime. The previously-it_pending kind=3 interleave test in `generators_p4b3_suspend_spec.qz` was the body-wrap workaround's bug, not a kind=3 control-flow issue — under E.1.c.b's canonical pattern (handler on main, goroutine inherits via snapshot) the test passes; bug doc `docs/bugs/KIND3_RESUME_INTERLEAVE_IN_GOROUTINE.md` updated to RESOLVED-as-artifact. **Limitation**: custom user `Async.spawn` handlers don't get inheritance unless they explicitly call `__qz_task_snapshot_register(frame, __qz_effect_snapshot_capture())`; in practice the default handler covers the `go fn()` keyword path. **Critical correctness fix during implementation**: first-cut restored TLS top to a saved pre-poll value, which erased any leaked-across-yield with-block install (broke `generators_p4b4a` 1/3 with `777\n10\n` instead of `777\n10\n20\n30\n` — body's wrap-block install was popped after first yield). Fix: `apply` returns push count, worker restores via `top -= count`, preserving body's installs. Fixpoint 2396. |
| E.4 | Cross-task escape mechanism | 2-3 quartz-days | ⏸ Pending — design call locked 2026-04-28 | **Design memo**: [`docs/design/E4_CROSS_TASK_ESCAPE.md`](E4_CROSS_TASK_ESCAPE.md) — the original "promote-fn OR copy-on-await runtime hook" disjunction is closed: **per-type promote-fn at task-end** is the right approach, on the strength of (a) Quartz already has all needed type info at codegen time, (b) self-hosted compiler can emit the deep-copy walker as plain Quartz IR with no runtime ABI changes, (c) cost model matches Erlang's `copy.c:copy_struct` which scales to BEAM-class workloads. Sub-phases sized: E.4.a — promote-fn registry + emission (~1 quartz-day); E.4.b — extend `_mir_synthesize_arena_wrap` to call promote on reference-typed returns (~0.5-1); E.4.c — spec coverage (~0.5). Six open design questions filed in the memo (cycle handling, closure captures, generic returns, watermark optimisation, cache discoverability, E.1.c.b apply-count interaction); resolve before E.4.a emission work starts. Channels-need-promotion is a separate axis filed as deferred to Phase F (the "large-value tier" Erlang-shaped backstop). |
| E.5 | `arena_destroy` corruption fix | 1-2 quartz-days | ⏸ Pending | Investigate and fix the latent corruption filed at `docs/bugs/D2_ARENA_DESTROY_AT_TC_SCALE_CORRUPTS_HEAP.md`. E.1.a sidesteps by keeping per-task workloads bounded; heavy-allocating tasks (>50K allocs) can still hit it. |
| E.6 | Extend wrap to all `go_*` spawn variants | 0.25 quartz-day | ✅ **SHIPPED 2026-04-28** | Pure stdlib change — `go_spawn(f)` / `go_cancellable(f, tok)` / `go_cancel_on_success(f, tok)` / `_go_race_run(f, ch)` (the racer body inside `_go_race_racer`) now route through `_go_arena_body(f)` (the helper `go_arena(f)` already uses, E.1.a). Each spawned task body runs inside its own per-task arena; outer Alloc trackers see only the arena's bulk chain blocks, not individual mallocs. Type signatures `Fn(): Int` enforce a value-typed return at all call sites — no E.4 escape required. The plan's "probably folds into E.1.b's MIR-lowering change" framing turned out wrong: these primitives all take `Fn(): Int` *parameters*, so the compiler-level `_mir_should_auto_arena` gate (which requires `mir_lookup_function` to resolve a top-level NODE_IDENT callee) would never fire on them. The wrap had to live at the function-execution level (where `_go_arena_body` lives) regardless of MIR-vs-stdlib placement. New 5-test spec at `spec/qspec/alloc_e6_spawn_variants_spec.qz` (5/5 green) covers absorbed-vs-direct counts for go_spawn / go_cancellable / go_race + go_scope correctness regression + sentinel-passthrough. **Latent bug discovered during E.6 spec authoring + RESOLVED same day** (pre-existing, not caused by E.6): `__Future_<fn>$poll` codegen placed `wb.result_slot.NN` alloca inside an inner basic block when the function had two sequential `with E {...}` blocks and a callee used await. Filed at `docs/bugs/POLL_BODY_WB_RESULT_SLOT_DOMINANCE.md`; fixed by hoisting `wb.jmpbuf.<dest>` and `wb.result_slot.<dest>` allocas to `fn_entry` alongside the existing `MIR_CONST_INT` / `MIR_ALLOC_STACK` hoists. `fn_entry` dominates every block including async-resume re-entry paths via `poll_switch`. The originally reduced go_race correctness test was promoted back to absorbed-vs-direct + serves as the regression test. Total diff: 4 lines + doc-comment additions in `std/concurrency.qz` (E.6 stdlib) + ~30 lines in `self-hosted/backend/codegen.qz` (new MIR_HANDLE_INSTALL hoist) + ~10 lines removed from `self-hosted/backend/codegen_instr.qz` (inline alloca emission). Fixpoint 2399 (unchanged from E.1.b — the new hoist pass is a function-count-neutral change). |
| E.7 | Worker-local arena pool — perf optimization | 0.5 quartz-day | ✅ **SHIPPED 2026-04-29** in two commits — `c8389215` E.7.a (substrate: `__qz_arena_pool_take` / `__qz_arena_pool_give` intrinsics + `@__qz_arena_pool_handles[64]` / `@__qz_arena_pool_count` TLS storage in `codegen_runtime.qz`; emission inline in `cg_intrinsic_memory.qz`) and `ef58bd95` E.7.b (`arena_acquire(size)` / `arena_release(handle)` stdlib helpers in `std/alloc.qz` over the intrinsics; `_go_arena_body` and `_mir_synthesize_arena_wrap` swap `arena_new`/`arena_destroy` → `arena_acquire`/`arena_release`). Two-commit split is the standard bootstrap pattern for new intrinsics: E.7.a registers + emits the new builtins so the binary at HEAD recognises them, then E.7.b adds source code that calls them. Per-worker isolation via TLS storage matches the effect-stack TLS arrays from E.1.c. Pool cap=64 bounds pooled-chain-pages RSS at `worker_count × 64 × max_arena_size`. New 4-test spec at `spec/qspec/alloc_e7_arena_pool_spec.qz` (LIFO reuse, reset-on-acquire clears alloc_count, 50 sequential `go_arena` regression, 65-cycle fill+overflow). All 23 `alloc_*` specs green; fixpoint 2420 → 2422. |

**Exit criterion (full Phase E)**: `go fn()` (keyword) gives Erlang-style per-task structured memory by default, all `go_*` spawn variants share the same wrap, parallel tasks under multi-worker scheduler don't crash, reference-typed returns survive task end, arena allocation/destruction is amortized via per-worker pooling, RSS stays bounded under 1000s of tasks each allocating 1 MB. **E.1.a's exit criterion** (achieved): opt-in API delivers per-task arena semantics for value-typed-return tasks; outer Alloc handler tracking proves bulk of inner allocations are absorbed by the per-task arena. **E.6's exit criterion** (achieved 2026-04-28): every `go_*` stdlib spawn variant (`go_spawn`, `go_cancellable`, `go_cancel_on_success`, `go_race`) wraps its task body via `_go_arena_body(f)`, mirroring the keyword path's behavior — structured-concurrency users now get per-task arenas without writing `go_arena(f)` themselves. **E.7's exit criterion** (achieved 2026-04-29): per-task arena allocation amortizes via per-worker TLS LIFO pool (cap=64); `_go_arena_body` and the keyword-path synthesizer route through `arena_acquire` / `arena_release` instead of `arena_new` / `arena_destroy`; pool overflow gracefully falls back to the syscall pair. Phase E shipped: E.1.a, E.1.b, E.1.c, E.1.c.b, E.4.a (slices 1-4), E.4.b, E.6, E.7. Pending: E.4.a slice 5+ (Vec-of-Vec / closure / generic returns — pull-in trigger required), E.5 (`arena_destroy` corruption fix at heavy alloc scale, latent — pull-in trigger required).

### Phase F — Beef up arenas where dogfooding exposes gaps (TBD)

Speculative list, document gaps as they emerge in Phases D/E:

- **Resizable arena blocks**: today every block is 4 KB; large allocations chain inefficiently. Add 64 KB / 1 MB block sizes selectable at create.
- **Arena-backed `String` builder type**: today `String + String` malloc-allocates; arena-backed builder would be a major codegen perf win.
- **`Vec` with explicit allocator**: `Vec.with_alloc(alloc_fn)` for cases where Alloc effect installation is too coarse.
- **Multi-arena handler**: e.g., "small allocs go to fast-path arena, large allocs to per-MB arena" — typical jemalloc-style sizing.

Each is a separate filing; document scope when it surfaces.

---

## Effects-system interactions

The `Alloc` effect interacts with the rest of the Piezo lineup in three ways worth noting:

1. **`Alloc` `can Throws<AllocError>`**: per D5, refused allocations throw. This means handlers that allocate need both effects in their row. The cascade-vs-blessed-relaxation playbook from Phase 6.2 applies — try cascading `can Alloc, Throws<AllocError>` through helpers before relaxing.
2. **`State<S>` handlers may allocate**: today's `State<S>` handler stores its state via direct malloc. Once Alloc lands, State handlers route through the current Alloc — so `with Alloc.in_arena(a) do with State(s) do work() end end` puts State storage in `a`. Good behavior; emerges naturally.
3. **`go`/`spawn` future frames**: the scheduler allocates per-task frames via `qz_malloc`. Phase E migrates this to per-task arenas. Until then, `go` tasks inherit the parent's Alloc handler.

The Piezo retrospective ([`PHASE_4_GENERATORS_RETRO.md`](PHASE_4_GENERATORS_RETRO.md), [`EFFECT_MIGRATION_PLAYBOOK.md`](EFFECT_MIGRATION_PLAYBOOK.md)) captures the discipline that applies here: 3-pass bootstrap, bridge-over-cascade, body-wrap last-stmt gotchas.

---

## Risks

| Risk | Probability | Severity | Mitigation |
|---|---|---|---|
| TLS-pointer dispatch hot-path overhead surfaces in benchmarks | Medium | High | Static fast-path in A.4. Benchmark before flag-delete. Worst case: keep `--alloc-routing` opt-in until measured zero. |
| Reentrancy bypass logic has edge case (e.g., handler calls a function that allocates that calls handler again) | Medium | Medium | D4's bypass is one thread-local depth counter. Prior art: Linux kernel's `irq_count`. |
| Compiler dogfood (Phase D) regresses fixpoint or compile correctness | Medium | High | Each seam is a separate commit. Fixpoint check after every seam. Per-phase arenas can be reverted independently. |
| Custom handlers expose latent compiler bugs (UFCS hash sensitivity, etc.) | Low | Medium | Phase A spec coverage is broad; Phase B handlers stress real workloads. Bugs found here go to bug tracker, don't block Alloc. |
| Per-task arenas (Phase E) break existing concurrency semantics | Medium | High | Phase E is sequenced after D for a reason — needs the surface to be stable first. Channel-passing must explicitly bypass the per-task arena (heap-allocate). Borrow checker enforces. |
| User confusion: "why doesn't my Vec.push respect my Alloc handler?" | Low | Medium | Phase A.4 static fast-path means user code DOES route through Alloc when wrapped in `with Alloc`. Document the boundary clearly in Phase B.5. |

---

## Pull-in / defer triggers

- **Phase A** is the foundation; pull in next session.
- **Phase B** depends on Phase A; either same session or follow-up.
- **Phase C** is design-only and quick; can interleave with Phase B.
- **Phase D** requires A + B + C complete. Multi-session; each seam is its own commit.
- **Phase E** requires D complete. Has independent value (Erlang-style structured memory) but depends on D's substrate.
- **Phase F** is reactive — file gaps as they emerge in D/E.

**Deferral signal**: if Phase A's hot-path benchmark shows >5% overhead with the static fast-path, pause and redesign D2. If we can't get to "default-program zero overhead," the boundary needs to shift toward Option C (surface-only) and the dogfood story changes.

**Pull-in accelerator**: if a real user need for sandboxing/test-isolation/determinism surfaces during Phase A or B, prioritize the matching Phase B.* item. The capability unlocks are the point.

---

## Comparable prior art

- **Rust's `Allocator` trait + nightly `allocator_api`**: per-collection allocator parameter. Ergonomically painful; every `Vec<T, A>` pollutes with the allocator type. Quartz Alloc-as-effect avoids this.
- **Zig's `std.mem.Allocator`**: every function takes an allocator parameter. Mandatory propagation; cannot be swapped contextually. Quartz's `with Alloc` block is contextual swap without parameter pollution.
- **Erlang/BEAM per-process heaps**: each process has its own heap; GC is per-process, not stop-the-world. Phase E inherits this design.
- **Koka's `:alloc` effect**: closest match. Koka has an alloc effect; it's experimental and not heavily dogfooded. Quartz beating Koka to a production-grade implementation continues the Phase 6 framing of "first effects-native language to ship X."
- **Carp's `:setjmp_alloc` for region-based allocation**: research-language territory; demonstrates the design works in pure ML-derivative.

---

## Decision log (this session)

- 2026-04-26 — Initiative scoped after the user pushed back on a misclaim that "Quartz has no arenas." Confirmed via thorough explorer audit: arenas exist (8 intrinsics + 6 pools + 5 arena-pools + RAII wrapper + borrow-checker safety + 13 specs); the `Alloc` effect was deferred from Piezo Phase 2 and never shipped; the compiler does not dogfood its own arenas.
- 2026-04-26 — Trojan-horse insight: dogfooding compiler arenas is one `with Alloc` block away once Alloc ships, NOT a multi-week per-site rewrite. Reframes Phase 4 of the compiler memory roadmap entirely.
- 2026-04-26 — D2 Option A (TLS pointer + static fast-path) recommended over Option B (effect-perform per alloc) for hot-path ergonomics; Option C (surface-only) rejected because it kills the dogfood story.
- 2026-04-26 — D5 — failure throws `Throws<AllocError>` rather than returning null; couples Alloc to Throws (acceptable, Throws is ubiquitous).

---

## Next-session entry point

When next session starts on this initiative:

1. **Phases A.0 / A.1 / A.2 / A.3.a-d / A.4 / A.5 / A.6 / A.7, B.0a / B.0b / B.0c / B.1 / B.2 / B.3 / B.4 / B.5, C, D.0 / D.1, E.1.a / E.1.b / E.1.c / E.1.c.b / E.4.a (slices 1, 2, 3.a, 3.b, 4) / E.4.b / E.6 are ALL DONE.** B.0b's design ("parallel `__qz_effect_stack_envs[256]` array") was subsumed by reusing the existing `state_slots[]` infrastructure — `mir_emit_handle_install`'s `init_state_reg` parameter threads env through MIR; codegen fan-outs across multi-entry installs (`codegen_instr.qz:2209-2253`); env-aware handlers read via `__qz_effect_state_get()`. The implementation chose unification because state and env are isomorphic at the runtime level (per-install i64 cell). D.2 was attempted + reverted — high-churn TC needs a reusing allocator, not a bump arena.
2. **Pending Phase E sub-phases (pull-in trigger required, not blocking):**
   - **E.4.a slice 5+** — Vec-of-Vec / closure / generic returns. Currently rejected by the auto-arena gate; users get libc-heap fallback. Pull-in trigger: a goroutine workload that returns one of these shapes and would benefit from per-task arena absorption.
   - **E.5** — `arena_destroy` corruption at heavy alloc scale (`docs/bugs/D2_ARENA_DESTROY_AT_TC_SCALE_CORRUPTS_HEAP.md`). Latent; pull-in trigger is a real user pattern that exposes it. April 29's missing-Map/Set-promote hypothesis was refuted by three synthetic reprose at TC scale all surviving. Per-task arena workloads are bounded enough that E.7's pool reuse doesn't expose this — pooled arenas live longer than per-task originals but stay within head-block + few chain-pages.
3. **Phase F** is reactive — file gaps as they emerge (resizable arena blocks, arena-backed String builder, Vec.with_alloc, multi-arena dispatch handler).
4. **Closures-as-handlers** remains deferred. Pull-in trigger: real user pattern needing lexical capture beyond what call-form sugars (`Alloc.in_arena` etc.) provide.

**Watch for** (Phase B carry-over from B.0a):
- B.0a fixed the bypass-flag-leak across handler-thrown longjmp via wb.catch save/restore. The stack-top mis-restore (separate runtime hardening) is still open; filed as a Phase B followup. Not blocking sugar work.
- The A.5 module-global state pattern still needs replacement (B.0b's per-install env slot). A `with Alloc.deny_all do ... end` form that internally does `alloc_set_<state>(x); with Alloc { ... } do body end` still has the SHARED-state problem when nested. Don't ship sugar over the module-global pattern; sequence it after B.0b/c.
- The `arena` reserved-keyword gotcha and triple-quote spec-string interpolation gotcha are both in memory files (`feedback_arena_reserved_keyword.md`, `feedback_quartz_module_quirks.md`) — re-read before authoring new specs to save the debug cycles.
- A.6 fixed the static fast-path bypass-flag wiring at `codegen_instr.qz` G.2 path only. The `_po_static_unwind` branch was NOT touched because Alloc ops are kind=1 (continuation-style) and kind=2 unwind shape doesn't apply to Alloc. If someone later adds a kind=2 Alloc op (unlikely; would be a design mistake — D5 says throw via Throws, not unwind via Alloc itself), the unwind branch would also need the fix.
- The post-A.7 spec pattern: when asserting exact handler-call-count or byte totals, capture inside the with-block and `puts(...)` outside. Inside-the-with-block puts perturb counters because format-string allocations now route through the user handler too. This is the new normal — internalize it for any new alloc/handler spec authoring.

**Watch for** (Phase A.5 carry-over from A.4):
- The watermark check assumes `__qz_alloc_blessed_watermark` is captured ONCE at main prelude and never mutated. If A.5's stdlib handlers introduce a "default install another blessed handler at startup" pattern, the watermark capture site needs to move AFTER the new install. Currently the capture is at the END of `cg_emit_effect_main_prelude` — anything blessed-installed before that line is included in the watermark; anything after is "user-equivalent" from the wrapper's perspective.
- The `__qz_gen_yield_capture` undefined-reference issue surfaces when a user program doesn't `import * from std/gen` but the prelude install line still references the symbol. Fix during A.5 if Yield handler comes up; otherwise document the workaround (explicit `import * from std/gen`).
- Effect-row inference around handlers that allocate. A `tracking_alloc_handler` that `puts("size=#{n}")` allocates (puts → str_concat). The bypass-flag mechanism prevents infinite recursion, but row inference sees the puts call as `can FileIo`. The handler signature already pulls in FileIo via blessed-relaxation, so this is fine — but worth double-checking under spec.

---

## Open questions for the next user discussion

These need a call before Phase A.1:

1. **D5 confirm**: `Throws<AllocError>` for refusal, or null-return + caller-checks? (Recommendation: Throws.)
2. **Default-handler perf budget**: how much overhead is acceptable when no custom handler is installed? 0% is the goal; willing to flag-gate Alloc indefinitely if we can't hit it.
3. **Should `Vec`/`Map`/`String` get explicit `with_alloc` constructors as well as the implicit-via-effect mechanism?** Both surfaces have value (effect = contextual; explicit = local override).
4. **Phase E (per-task arenas) scope**: ship with `go` only, or also extend to `task_group`/structured concurrency primitives? (Recommendation: go-only first; extend after.)
