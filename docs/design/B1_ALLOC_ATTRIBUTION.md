## Phase B.1 — Compiler memory: allocation-site attribution substrate

> **Filed:** 2026-05-01 (immediately after A.2 P2's empirical-failure
> close at `531a6815`).
> **Sequencing:** Phase B.1 of the post-audit roadmap, promoted to #1
> after A.2 P2's heavy-workload revert excursion produced 0 MB
> measurable savings (−1 MB peak / +15 ms wall — within run-to-run
> noise). The path forward is no longer "find more `ends_with`-shape
> sweeps"; it's instrument-first attribution of which call sites
> actually drive codegen's 1206 MB live → 2447 MB peak gap.
> **Recipe inheritance:** extends the A.6 Profile-effect substrate
> with a 5th op. Cross-reference [`PROFILE_EFFECT_PLAN.md`](PROFILE_EFFECT_PLAN.md)
> for the effect-machinery details (string globals, blessed-relaxation,
> default-handler ABI, two-pass fixpoint discipline).

## Motivation

Heavy-workload baseline (3-run median on `self-hosted/quartz.qz`,
captured at `benchmarks/rss/quartz_qz_head.csv`):

```
phase             rss_mb  peak_mb  wall_ms
compile_start          1        1        0
init                   1        1        0
lex                    2        2        1
parse                  5        5        8
resolve_pass1        163      163      858
resolve_pass2        185      185     1166
resolve              185      185     1168
typecheck            817      817     7129
tc_free              817      817     7130
mir                  974      974    12713
codegen             1205     2447    55296   ← +1242 MB transient peak
compile_done        1205     2447    55296
```

The headline: **codegen alone has a 1242 MB gap between live working
set (1205 MB) and peak RSS (2447 MB)**. That gap is transient
allocations that happen during codegen but are released before
compile_done — IR string buffers, MIR instruction storage, AST
handles retained then freed, intermediate string concatenations.

A.2 P2 hypothesized that prefix-check substring churn was the dominant
contributor. The revert excursion empirically rejected that — peak
moved 1 MB. At 2447 MB scale, MB-class allocations dominate by orders
of magnitude over short-string churn. We don't know which sites
account for the 1242 MB gap. We need attribution before we can
choose the right intervention.

## Scope decisions

### Op shape — `prof_alloc_site(label: String, bytes: Int): Int`

```quartz
effect Profile
  def prof_phase(name: String): Int
  def prof_span_begin(name: String): Int
  def prof_span_end(begin_handle: Int, name: String): Int
  def prof_sample(name: String, value: Int): Int
  def prof_alloc_site(label: String, bytes: Int): Int  # NEW
end
```

**Why a new op vs reusing `prof_sample`:**

`prof_sample(name, value)` is a *point-in-time emit* — the default
handler writes one line per call. For attribution we need
*accumulation* (sum of bytes per label across thousands of calls,
emit top-N at the end). Different semantics, different default
behavior, different gate, different reporter API. A new op is
cleaner than overloading prof_sample with an "accumulate this one"
mode.

**Why kind=1 (function-kind):** matches the other 4 Profile ops.
No continuation capture, no unwind. Handler runs, returns 0,
execution resumes at the perform site.

**Why `bytes: Int` and not separate count + size:** call-count
tracking falls out for free in the default handler (increment a
parallel counter). Callers always pass a byte total per call. If a
site allocates N items of size M, the call should be
`prof_alloc_site("foo", N * M)` — keeping the API surface narrow.

**Why `label: String` and not a numeric site ID:** call-site
labels need to be readable in the top-N report. Stringly-typed
labels match the rest of the Profile API. The marginal cost of
intern + lookup per call is negligible compared to the allocation
itself (sites that are perf-critical enough to bottleneck on
this attribution would not be tracked in the steady state — see
"Production deployment" below).

### Default handler — gate-and-accumulate

Mirrors `prof_phase`'s gate-and-emit structure but with three
differences:

1. **Independent gate flag.** `_profile_alloc_track_enabled`
   defaults to 0. `--memory-stats` and `--progress` do NOT enable
   it — attribution is opt-in via `--alloc-track` (Phase 2 wires
   the CLI flag) or programmatically via
   `profile_set_alloc_track(1)`. Reason: tracking adds map-mutation
   work per call site; even with both human/ndjson off, the
   accumulator path is non-trivial. Users running `--memory-stats`
   for phase boundaries shouldn't pay it.

2. **Persistent accumulator state, not stateless emit.** Default
   handler maintains two parallel `Map<String, Int>`:
   `_profile_alloc_bytes_by_site` and `_profile_alloc_count_by_site`.
   Each `prof_alloc_site(label, bytes)` increments both. No stderr
   output during accumulation — the accumulator is silent.

3. **Explicit reporter, not auto-flush.** The user calls
   `profile_alloc_top_n(N)` to emit a sorted top-N report. Phase 2
   wires this just before `compile_done`'s `prof_phase`. Reason:
   we want the report at a known program point with known program
   state, not interleaved with phase emissions.

```quartz
if op.eq("prof_alloc_site")
  if _profile_alloc_track_enabled == 0
    return 0
  end
  var label = as_string(load(argv, 0))
  var bytes = load(argv, 1)
  _profile_alloc_record(label, bytes)
  return 0
end
```

```quartz
def _profile_alloc_record(label: String, bytes: Int): Void
  var prev_b = _profile_alloc_bytes_by_site.get(label).unwrap_or(0)
  _profile_alloc_bytes_by_site.set(label, prev_b + bytes)
  var prev_c = _profile_alloc_count_by_site.get(label).unwrap_or(0)
  _profile_alloc_count_by_site.set(label, prev_c + 1)
end
```

### Reporter — `profile_alloc_top_n(n)`

```quartz
def profile_alloc_top_n(n: Int): Void
  # Iterate keys, sort by bytes descending, emit first n.
  var keys = _profile_alloc_bytes_by_site.keys()
  # Pair (bytes, label) so sort key is bytes; emit "[prof] alloc-site <label>: <bytes> bytes (<count> calls)"
  ...
end
```

Output format:

```
[prof] alloc-site:report top=N total_bytes=<sum> total_calls=<sum>
[prof] alloc-site <label>: <bytes> bytes (<count> calls)
[prof] alloc-site <label>: <bytes> bytes (<count> calls)
...
```

NDJSON variant emits one event per top-N entry plus a header event.

### Gate orthogonality

Three independent flags, three independent setters:

| Flag | Setter | Default | What it gates |
|---|---|---|---|
| `_profile_human_enabled` | `profile_set_human(on)` | 0 | `[prof]` lines on stderr for phase/sample |
| `_profile_ndjson_enabled` | `profile_set_ndjson(on)` | 0 | NDJSON events on stderr for phase/sample |
| `_profile_alloc_track_enabled` | `profile_set_alloc_track(on)` | 0 | Accumulator path for prof_alloc_site |

The reporter (`profile_alloc_top_n`) emits to stderr unconditionally
when called; it's an explicit-emit API, not a gated one. The
gate controls accumulation, not emission.

### Test handlers — capture/silent/ndjson extension

Three existing factories grow a 5th branch:

- `profile_capture_handler` — appends `"alloc-site #{label} bytes=#{bytes}"` to log.
- `profile_silent_handler` — drops the call, returns 0.
- `profile_ndjson_handler` — emits `{"v":1,"event":"alloc_site","name":"<label>","bytes":<n>}`.

## Plumbing

### File: `std/profile.qz`

- Effect declaration: append `def prof_alloc_site(label: String, bytes: Int): Int`.
- New module-level state: 3 vars (`_profile_alloc_track_enabled`,
  `_profile_alloc_bytes_by_site`, `_profile_alloc_count_by_site`).
- New surface: `profile_set_alloc_track(on)`, `profile_get_alloc_track()`,
  `profile_alloc_reset()`, `profile_alloc_top_n(n)`,
  `profile_alloc_total_bytes()`, `profile_alloc_total_calls()`.
- Default handler: 5th branch.
- 3 test handlers: 5th branch each.

### File: `self-hosted/backend/codegen_runtime.qz`

Add the op-name string global to both branches at lines 547-551
(linkonce_odr) and 595-598 (internal):

```llvm
@__qz_eff_op_prof_alloc_site = linkonce_odr unnamed_addr constant [16 x i8] c"prof_alloc_site\00", align 1
@__qz_eff_op_prof_alloc_site = internal      unnamed_addr constant [16 x i8] c"prof_alloc_site\00", align 1
```

Profile's default is a Quartz function (uses `as_string(op_name).eq(...)`),
so the constant isn't directly referenced by inline-IR dispatch. We
add it for symmetry + IR-readability + future inline-IR fast path.
Length includes nul terminator: `len("prof_alloc_site")=15` + nul = 16.

### What does NOT change

- `mir.qz` / `mir_lower_expr_handlers.qz` — `uses_profile` already
  fires for any op call against the Profile effect; the new op
  inherits.
- `typecheck_expr_handlers.qz` blessed list — checks the effect
  *name*, not the op name; Profile is already blessed.
- `codegen.qz` caller sites — already pass `uses_profile` through.

## Two-pass fixpoint analysis

Pass 1 (this commit) ships:
- Effect declaration with the new op.
- Default-handler 5th branch (handler dispatches on op-name string,
  doesn't *call* `prof_alloc_site` — gen0-friendly).
- 3 test-handler factories' 5th branches (same — string dispatch).
- Reporter / setters / state.
- Spec coverage.
- IR string global (gen0 emits constants from a literal string list,
  agnostic to which ops the effect declares).

Pass 1 does NOT migrate any compiler-source call site. Compiler
source never calls `prof_alloc_site` until Phase 2.

Gen0 (current binary) compiles gen1's `std/profile.qz` containing the
new declaration: typecheck accepts a 5-op effect just as easily as a
4-op effect; codegen emits per-op string-pool entries for `with`-block
installs (inert if no callsite uses them). gen1 binary is identical
in shape; binary count goes up by 1 reporter + 1 helper +
implicit accessors (~5 new functions).

A second fixpoint pass is NOT needed for Pass 1.

Phase 2 (separate commit) migrates the first compiler-source call
site and wires the reporter + CLI flag.

## Phase 2 plan — instrument-first attribution

Once the substrate ships, Phase 2 instruments suspected hot sites in
codegen. Decision rule for "is this site worth a `prof_alloc_site`
call": is it inside a hot loop (>1k iters per compile) AND
allocates >1 KB per call AND is in the suspected codegen-hotzone?

Likely candidates by code shape:

1. **IR string buffer growth** in `codegen.qz` /
   `codegen_instr.qz` — every `cg_emit_line` call appends to a
   per-module buffer; module count is ~38 for self-compile;
   per-module buffer can run to MB. Instrument
   `cg_emit_line` with a single `prof_alloc_site("ir_buffer:#{module}", strlen)`.

2. **MIR instruction storage** — `mir_instr_new` is called in
   `mir_lower_*.qz`. Per-instruction overhead × ~50k instructions.
   Instrument the allocation site once.

3. **AST handles retained past tc_free** — typecheck-time AST
   rewrites that allocate new nodes (desugaring, generic
   specialization, lambda lifting). Instrument
   `ast_alloc_node` if there's a single chokepoint, else top
   3 callsites.

4. **String-pool growth** — interner adds entries during
   typecheck/codegen. `intern_global().intern(...)` callsites in
   hot loops.

5. **Vec growth in mir/codegen** — `vec_push` reallocs on growth;
   the reallocation site allocates 2x the previous capacity, which
   for large vecs is the hidden peak driver.

Phase 2 picks the top 3-4 candidates, lands instrumentation, runs
a single self-compile with `--alloc-track`, dumps top-20, decides
the next intervention based on attribution data. The intervention
might be:
- Targeted optimization of the top contributor.
- Promotion to Alloc-effect compiler-arena dogfood (the long-game
  lever from `ALLOC_EFFECT_PLAN.md`).
- A fundamentally different data structure (e.g. SoA vs AoS for
  MIR instructions).

The point: we don't choose the intervention before we have the
attribution data.

## CLI integration (Phase 2)

Add `--alloc-track` flag to `quartz.qz`'s argparser:

```quartz
argparser_flag(cli, "", "--alloc-track",
  "Track per-site allocation totals; emit top-20 at compile_done.")
```

Wire to `profile::profile_set_alloc_track(parsed_has(args, "--alloc-track"))`.

Wire `profile::profile_alloc_top_n(20)` immediately before the
`prof_phase("compile_done")` call.

This shape mirrors the `--memory-stats` → `profile_set_human`
plumbing.

## Production deployment

The instrumented sites stay in the binary. Without
`--alloc-track` they pay only the cost of the perform-dispatch
gate check (one `if track == 0 return 0`). Per-call cost when
gate is off: ~10 ns (one TLS-style global read + branch).

For sites called >1M times per compile, that's ~10 ms of overhead
per compile when off. We accept that. Phase 2 will measure.

If the overhead turns out to be material (>1% wall regression),
Phase 2.1 introduces a build-time `#[cfg(profile_alloc)]`-equivalent
to compile out the call entirely in non-profiling builds. Quartz
doesn't have that today; introducing it is its own work item.

## Hazard map

- **Map<String, Int> hashmap_get returns Option<Int>.** Per project
  memory `feedback_str_find_returns_option_int.md`, treating the
  return as bare Int reads the Option-box pointer and SIGSEGVs.
  Use `.unwrap_or(0)` everywhere.
- **`map_new<String, Int>()` resets must reassign, not mutate.** The
  existing `cache_in_memory_reset` pattern reassigns: `_x = map_new(...)`.
  We mirror it.
- **Reentrancy.** Default handler's `_profile_alloc_record` runs
  during `compile()`. If `compile()` is called recursively from a
  spec test, the accumulator persists across the inner call —
  intentional. Tests that need clean state call `profile_alloc_reset()`.
- **Sort key for top-N.** Quartz doesn't have a generic
  `sort_by_key` helper; we'll implement insertion-sort in the
  reporter (top-N is small, ~20 entries; O(n*N) where n is total
  sites is fine).
- **Avoid string interp in hot path.** `prof_alloc_site` callsites
  in hot loops should pass *literal* labels, not interpolated
  ones — interp itself allocates. We call it `"ir_buffer"`, not
  `"ir_buffer:#{module_name}"`. Per-module attribution is achievable
  by lifting the label out of the loop.
- **Don't run RAM-heavy bug repros to verify.** Per project memory
  `feedback_dont_run_ram_heavy_repros.md`: fixpoint + targeted
  qspec is the verification path for the substrate. Phase 2's
  attribution sweep is the first time we run with `--alloc-track`
  on the heavy workload, and it ships its own targeted measurement
  at that point.

## Calibration note

Phase 1 (this commit): single commit, ~1 quartz-day budget.
- `std/profile.qz`: ~80 lines added.
- `codegen_runtime.qz`: 2 lines (one per branch).
- `spec/qspec/profile_effect_alloc_site_spec.qz`: ~120 lines new file.
- Design memo (this file): ~250 lines.
- Roadmap update: ~20 lines.

Phase 2: 1-2 quartz-days. Instrumentation choices, attribution run,
intervention decision.

Phase 3+ (whatever the attribution data dictates): unknown until
data is in.

## Forward references

- `ALLOC_EFFECT_PLAN.md` — the structural lever this Phase
  potentially feeds. If attribution shows IR string buffers
  dominate, codegen-arena dogfood is the natural intervention.
- `CACHE_EFFECT_PLAN.md` / `PROFILE_EFFECT_PLAN.md` — the recipe
  this Phase inherits.

## Phase 2 — instrumentation + attribution run (shipped 2026-05-01)

### What landed

- `--alloc-track` CLI flag in `quartz.qz:1542` argparser; wired to
  `profile::profile_set_alloc_track(parsed_has(args, "--alloc-track"))`
  at the same plumbing point as `--memory-stats` / `--progress`
  (line 1727).
- `profile::profile_alloc_top_n(20)` call inserted right before
  the final `prof_phase("compile_done")` (line 1026), gated on
  `profile_get_alloc_track() == 1` so the reporter only fires when
  the user opted in.
- Four chokepoint instrumentations:
  - `cg_emit_line(out, s)` — `prof_alloc_site("cg_emit_line", str_byte_len(s) + 1)`
  - `cg_emit(out, s)` — `prof_alloc_site("cg_emit", str_byte_len(s))`
  - `cg_emit_int(out, n)` — `prof_alloc_site("cg_emit_int", 16)` (constant estimate)
  - `mir_new_instr(...)` — `prof_alloc_site("mir_new_instr", 88)`
    (constant — sizeof(MirInstr) = 11 fields × 8 bytes; the embedded
    Vec<Int> args field is empty at construction so excluded)
- `import std/profile` added to `codegen_util.qz` and `mir.qz`
  (these modules call `prof_alloc_site` as a bare effect-op
  keyword, which requires the effect declaration in scope; Profile
  is blessed so no `can Profile` cascade is needed).
- Quake guard clean: 2453 functions, fixpoint verified.
- Smoke green: style_demo, brainfuck, profile_effect_alloc_site_spec
  (9/9).

### Attribution data

3-run heavy-workload self-compile of `self-hosted/quartz.qz` with
`--alloc-track --memory-stats`. Captured at
`benchmarks/rss/quartz_qz_alloc_track.txt`:

```
[prof] codegen: 1483 MB (+494), 2727 MB peak (56803ms)
[prof] alloc-site:report top=4 total_bytes=125461878 total_calls=8942810
[prof] alloc-site cg_emit:        51,457,620 bytes  (5,772,743 calls)
[prof] alloc-site mir_new_instr:  36,100,944 bytes    (410,238 calls)
[prof] alloc-site cg_emit_line:   23,203,762 bytes  (1,841,107 calls)
[prof] alloc-site cg_emit_int:    14,699,552 bytes    (918,722 calls)
[prof] compile_done: 1483 MB (+0), 2727 MB peak (56803ms)
```

Instrumentation overhead: peak 2447 → 2727 MB (+280 MB) and live
1205 → 1483 MB (+278 MB). The accumulator's parallel
`Map<String, Int>` (4 entries) doesn't account for that — the
overhead is the perform-effect dispatch cost across 8.9M calls
(arg encoding, handler function call, gate check, accumulator
mutation, return path). Acceptable for one-off attribution runs;
for steady-state opt-out, the gate-off path is ~10ns
(documented in "Production deployment" above).

### Headline finding — IR text volume is NOT the dominant peak

The four instrumented chokepoints account for 125 MB of cumulative
allocation through codegen helpers. The codegen peak gap (peak −
post-codegen-live) is **1244 MB**. **The four chokepoints account
for only ~10% of the peak gap** — the remaining ~1119 MB is
unattributed by these probes.

Cross-check: cg_emit + cg_emit_line + cg_emit_int total 89 MB of
cumulative output volume. The final emitted IR file is 80 MB. The
~1.1× ratio means the StringBuilder backing the IR buffer does NOT
double-grow during emit — final size matches accumulated writes.
**This empirically rejects the "IR-buffer doubling = peak" hypothesis
that motivated cg_emit-* as the Phase 2 candidate set.**

`mir_new_instr` (36 MB at 88 bytes × 410K calls) is mostly charged
during the MIR phase, not codegen — so it contributes to the
typecheck → mir delta (+169 MB) rather than the codegen peak gap.

### Where the unattributed 1119 MB lives — structural answer

`self-hosted/quartz.qz:1010-1019`:

```quartz
var cg_arena = arena_new(65536)
with Alloc.in_arena(cg_arena) do ->
  llvm_ir = codegen::cg_codegen(mir_prog, ...)
  extern_decls = codegen::cg_emit_extern_declarations(...)
end
llvm_ir = arena_promote_string(llvm_ir)
extern_decls = arena_promote_string(extern_decls)
arena_destroy(cg_arena)
```

**Codegen runs inside a single whole-codegen Alloc arena.** Every
allocation made during `cg_codegen` — interpolated emit strings,
intermediate Vec<Int> growth, per-function escape analysis state
(`func.mir_compute_escaped_regs(...)` at `codegen.qz:147`), reg
origins, sanitized name buffers, the StringBuilder's underlying
buffer, etc. — is allocated in `cg_arena`. Nothing is freed until
`arena_destroy(cg_arena)` after both `llvm_ir` and `extern_decls`
have been promoted out.

In this model **peak codegen RSS = sum of all bytes ever allocated
during codegen**, not "max live working set during codegen".
This is precisely why the gap is so large relative to the live
working set — the arena is the explanation.

The 1119 MB of unattributed peak is therefore the sum of:

- Caller-side string interpolation building the inputs to
  `cg_emit_line` callsites that use `"  %v_#{x} = call ..."` form.
  Grep finds 433 interpolated callsites in
  `cg_intrinsic_binary.qz` alone, 104 in `codegen_runtime.qz`,
  and the cg_intrinsic_*.qz files have ~6,000+ total
  `cg_emit_line` callsites (most likely interpolated).
- Per-function escape-analysis Vecs and reg-origins maps.
- Per-instruction codegen-state mutations.
- Sanitized name buffers, debug-metadata nodes,
  string-pool entries.
- StringBuilder's underlying byte buffer (lives in the arena
  too, ~80 MB final size, but its growth allocations stay around
  until arena_destroy because the arena retains everything).

### Intervention decision

**Promoted Phase 3 candidate: per-function arena dogfood.**

Replace the single whole-codegen arena with a per-function arena
nested inside it. Each `cg_emit_function` enters its own
`with Alloc.in_arena(func_arena)`, builds the function's IR
fragment, the bytes are memcpy'd into the outer-arena
StringBuilder via `cg_emit_line`'s `sb_append`, and the
per-function arena is destroyed before the next function. The
outer arena still holds the StringBuilder + extern decls + final
IR; the per-function arena holds only that one function's
transients.

Expected effect: peak codegen RSS drops from `sum(per-function
allocs)` to `max(per-function alloc)`. With ~2,400 functions and a
1244 MB transient pool, average per-function alloc is ~520 KB.
Peak is dominated by the largest few functions (likely main /
qz_main / a big match expression). Realistic peak post-fix: ~50-150
MB during codegen, down from 1244 MB. **Total peak goal of <1 GB
becomes plausibly reachable in a single architectural change.**

Risk: must keep the `out` StringBuilder + the IR string returned
by `cg_codegen` in the OUTER arena. Anything captured by closure
or stored in CodegenState that outlives a single function must
also be in the outer arena. The `Alloc.in_arena` effect already
provides nested-install semantics (verified in alloc_e1_per_task_arena_spec).

Implementation sketch:

```quartz
# in cg_codegen():
for func_idx in 0..funcs.size
  var func_arena = arena_new(8192)
  with Alloc.in_arena(func_arena) do ->
    cg_emit_function(state, out, prog, funcs[func_idx], func_idx)
    0
  end
  arena_destroy(func_arena)
end
```

`out` was allocated in the outer arena, so `sb_append` calls during
`cg_emit_function` write into the outer-arena StringBuilder. The
strings passed *to* `sb_append` are allocated in the per-function
arena and discarded with it.

### Alternate Phase 3 candidates (not selected)

- **Interpolation-elimination sweep** — convert `cg_emit_line(out, "  %v_#{x} = ...")`
  to multi-call `cg_emit(out, "  %v_"); cg_emit_int(out, x); cg_emit(out, " = ...")`
  chains. Would reduce alloc volume per call but doesn't change the
  arena's "everything stays alive until codegen-end" structure.
  ~1000 mechanical edits. **Strictly subsumed by per-function arena**:
  even if interp strings still allocate, they live in the per-function
  arena and die at function-end. Reserved as a follow-up sweep if
  per-function arena leaves a residual interp-driven peak.
- **Stream IR to disk** — emit to a file descriptor instead of
  building a single in-memory String. Eliminates the in-memory IR
  buffer entirely. Bigger ABI change (`compile()` returns a path
  rather than a String); breaks the cache pipeline's
  `final_ir = "#{llvm_ir}\n#{extern_decls}"` assembly. Defer until
  the per-function arena is shipped and re-measured.
- **Finer-grained Phase 2.5 attribution** — instrument 5-10 more
  sites (string interp helpers, vec_push reallocs, intern lookups,
  per-function escape-analysis allocations) to bisect the
  unattributed 1119 MB further. Defer: the structural answer
  ("everything's in one big arena") is already explanatory and
  actionable. Finer attribution becomes useful again *after* the
  per-function arena ships, to see what residual peak remains.

### Phase 2 calibration

- ~6 small edits across 3 files (cg flag + reporter call + 4
  instrumentation sites + 2 imports).
- Single quake guard pass (~5 min).
- Single heavy-workload run with `--alloc-track` (~57s + 30s
  measurement overhead).
- Captured: `benchmarks/rss/quartz_qz_alloc_track.txt`.
- ~0.25 quartz-day total (less than the ~1-2 quartz-day budget
  the design memo originally allotted).

The headline-finding-from-data path was substantially faster than
the "10 instrumentation sites + speculative ranking" path the
original Phase 2 plan described. Reason: the structural arena
context made the answer reachable from 4 sites alone — once we
knew the chokepoints accounted for only ~10% of the peak gap, the
arena explanation was the obvious structural cause.

## Phase 3 — per-function arena dogfood (EMPIRICALLY FAILED 2026-05-01)

**Outcome: Phase 3 hypothesis rejected. Reverted before commit.**

### What was tried

`_cg_emit_all_functions` helper in `self-hosted/backend/codegen.qz`:
each function ran inside its own `with Alloc.in_arena(fn_arena) do ->
... end` install with a per-function StringBuilder; transients allocated
into `fn_arena`, IR fragment + state deltas (`state.string_pool`,
`loop_metadata_ids`, debug DILocation tables) promoted into the outer
`cg_arena` via `arena_promote_string` / delta-promote pattern;
`fn_arena` destroyed before next function. Pre-grown state.* capacities
(`vec_new_filled<T>(N, fill).truncate(0)`) ensured per-function pushes
didn't relocate state Vec backings into `fn_arena` (slow rebuild path
for the rare relocation case).

### Verification of correctness

- `quake guard` passed (gen1==gen2 byte-identical).
- 2456 → 2458 functions (+3 helpers).
- `style_demo` + `brainfuck` smoke green.
- 14/14 alloc-related qspecs green
  (`alloc_in_arena_b1_spec`, `alloc_e1_per_task_arena_spec`,
  `alloc_e4a_string_return_spec`, `d1_arena_codegen_repro_spec`).

### `arena_bytes_used` diagnostic — fn_arena IS doing real work

A diagnostic `eputs("[fn_arena] fn=N bytes_used=KB ...")` printed for
every function whose `arena_bytes_used` exceeded 1 MB. Confirmed:

- 50+ functions allocated 1-13 MB each in their per-function arena
  (largest: `fn=1353` with 12 858 KB used, IR fragment 2 332 KB
  ≈ 5.5x ratio of allocations to IR-bytes — matches expected
  interpolation-to-emit ratio).
- Cumulative bytes routed through fn_arena across all functions:
  ≈ 430 MB.
- Each `fn_arena` correctly destroyed via `arena_destroy` after its
  function's emit completed; data buffers `munmap`'d (chain block
  headers leaked in libc heap, but at 32 B × ~30 chains × 2453 functions
  ≈ 2.3 MB total — trivial).

### RSS measurement (3-run median, `--alloc-track` OFF)

```
phase             base_peak   cur_peak   d_peak     base_wall   cur_wall   d_wall
codegen                2447       2415      -32         55296      57695    +2399
compile_done           2447       2415      -32         55296      57695    +2399
```

Captured: `benchmarks/rss/quartz_qz_b1_phase3_FAILED.csv`.

**Peak dropped only 32 MB** (1.3 % of 2447 MB baseline) vs. the
1000+ MB reduction the Phase 3 design predicted.
**Wall regressed +2.4 s** (+4 %).
**Post-codegen current went UP +277 MB** (1205 → 1482 MB).

### Root cause of Phase 3 design failure

The Phase 2 finding interpreted the 1244 MB transient gap as
"per-function emit transients all retained in cg_arena until end."
The empirical result invalidates that interpretation: per-function
arena reclaims ~430 MB cumulative across all functions but **peak**
only drops 32 MB, meaning **the maximum simultaneous live memory
during codegen is NOT dominated by per-function emit transients**.

Reasoning by elimination:

- Pre-codegen baseline: 975 MB live (resolve + typecheck + mir).
- Patched codegen peak: 2415 MB.
- Codegen working set at peak: 2415 − 975 = 1440 MB.
- Of that, max fn_arena observed: ≈ 13 MB.
- Therefore: cg_arena holds ≈ 1428 MB at peak.

The 1428 MB in cg_arena at peak is NOT attributable to chokepoint
allocations (~125 MB cumulative through `cg_emit*`/`mir_new_instr`)
and NOT attributable to per-function fn_arena traffic (now reclaimed).
**The unattributed mass lives elsewhere in cg_arena** — most likely
in:

1. **Master `out` StringBuilder grow leaks**. Each `__qz_realloc`
   under an installed `Alloc` handler decomposes into
   alloc(new) + memcpy + dealloc(old); the dealloc no-op leaks the
   OLD buffer in cg_arena. Master `out` grows from 64 KB → 80 MB
   via doublings, leaking ~160 MB of old buffers cumulatively.
2. **Post-loop emits running OUTSIDE fn_arena**:
   `cg_emit_module_init`, `cg_emit_string_constants` (17 655 strings
   × ~9 sb_append calls = 159 K small allocations),
   `cg_emit_struct_hash_eq_functions` (per-struct hash + eq), panic
   helpers, main wrapper, race detector, loop metadata. All emit
   into master `out` and allocate intermediate strings in cg_arena.
3. **Pre-loop emits**: runtime decls, struct types, global vars,
   const decls, extern info collection, func_ref pre-scan.

These categories were OUT OF SCOPE for the Phase 3 design, which
focused on `cg_emit_function`'s call tree. The fix-locality assumption
was wrong.

### Secondary regression: +277 MB post-codegen current

After `arena_destroy(cg_arena)`, ~277 MB more memory survived than
in baseline. Suspected sources, in order of likelihood:

- Per-iteration `arena_promote_string(fn_str)` creates a fresh String
  in cg_arena; that promote is later memcpy'd into master `out`'s
  buffer, but the fresh String reference itself is orphaned in
  cg_arena. Cumulative: ~80 MB (size of full IR).
- The above OLD master-out grow leaks (~160 MB) compound with the
  fn_str orphans. Both die with cg_arena, so this shouldn't survive
  `arena_destroy(cg_arena)` … unless the actual growth is happening
  in libc heap (e.g., chain block headers do leak via libc) and macOS
  malloc retains fragmented pages.
- macOS libc malloc never returns pages to OS, so any heap growth
  from chain-block-header-allocation traffic remains resident even
  after `__qz_dealloc` no-ops them.

The +277 MB live regression alone disqualifies Phase 3 from shipping
even with its small peak win.

### Phase 4 (revised) — pursue the actual peak driver

Two intervention paths, ranked by confidence:

**Path A: master-out grow-leak elimination.** If the master `out`
StringBuilder grew without leaking old buffers, the ~160 MB
realloc-leak overhead disappears. Possible approaches:

1. Pre-grow `out` to 128 MB before the for-loop (single allocation,
   no doublings, no leaks). Cost: ~128 MB always-allocated regardless
   of program size.
2. Stream IR to a file descriptor instead of building a single
   in-memory String. Bigger ABI change (`compile()` returns a path
   rather than a String); breaks cache pipeline's
   `final_ir = "#{llvm_ir}\n#{extern_decls}"` concatenation.
3. Switch master `out`'s grow path off the Alloc effect — allocate
   the buffer directly via mmap so growths actually free the old
   buffer.

**Path B: instrument post-loop emits with fine-grained
`prof_alloc_site` markers.** Phase 2.5 deferred attribution becomes
the right move now: add `prof_alloc_site` to
`cg_emit_string_constants`, `cg_emit_struct_hash_eq_functions`,
`cg_emit_effect_runtime`, and per-call-site interpolation helpers
to localize the 1100 MB unattributed mass before designing a
structural fix.

**Recommendation:** Path B first (re-attribute), then Path A or new
intervention based on findings.

### Lesson — chokepoint attribution was a partial signal

Phase 2's "structural arena explanation" (the 4 chokepoints
attribute 10 % so the arena IS the residual) wasn't wrong — peak
DOES live in the arena. But the *intervention* implication
("destroy the arena per-function") assumed the arena content was
dominated by per-function transients. That was the leap.

Per-function arena is a sound design **for transient pools that
truly are dominated by the per-iteration work** (the canonical case
in research literature). For `cg_codegen`, the per-iteration work
is a minority of the peak.

Memory entry filed: `feedback_per_function_arena_peak_failure.md`
(2026-05-01). When chokepoint attribution covers <50 % of a phase's
peak gap, per-function arena is an *insufficient* intervention —
verify what fills the peak via finer attribution before designing
the structural fix.

## Phase 4 Path B — re-attribution via per-phase bookends (shipped 2026-05-01)

### What landed

Sixteen `prof_alloc_site` bookend chokepoints around the post-loop
and pre-loop emit functions in `cg_codegen` and `cg_codegen_debug`,
plus one inside `cg_emit_extern_declarations`. Each bookend captures
`sb_size(out)` before and after a phase and records the IR-text
delta with a literal label:

| Label | Where | Captures |
|---|---|---|
| `phase_binary_layout_manifest` | cg_codegen pre-loop | binary {} / packed-struct manifest |
| `phase_runtime_decls` | cg_codegen + debug pre-loop | LLVM target/runtime declares |
| `phase_struct_types` | cg_codegen + debug pre-loop | narrow-field struct types |
| `phase_global_vars` | cg_codegen + debug pre-loop | global var declarations |
| `phase_const_decls` | cg_codegen + debug pre-loop | const declarations |
| `phase_function_loop` | cg_codegen + debug for-loop | the entire `cg_emit_function` for-loop's IR text |
| `phase_module_init` | cg_codegen + debug post-loop | module init function |
| `phase_string_constants` | cg_codegen + debug post-loop | global string constants pool |
| `phase_str_hash_helper` | cg_codegen + debug post-loop | FNV-1a string hash helper |
| `phase_effect_runtime` | cg_codegen + debug post-loop | effect-dispatch runtime (D.1) |
| `phase_struct_hash_eq` | cg_codegen + debug post-loop | per-struct hash/eq functions |
| `phase_custom_map` | cg_codegen + debug post-loop | custom-key map runtime |
| `phase_panic_helpers` | cg_codegen + debug post-loop | overflow/bounds/map_key/async_lock_drain/backtrace helpers |
| `phase_main_wrapper` | cg_codegen + debug post-loop | main entry point wrapper |
| `phase_race_detector` | cg_codegen + debug post-loop | race detector runtime (gated) |
| `phase_loop_metadata` | cg_codegen + debug post-loop | loop vectorization metadata |
| `phase_debug_metadata` | cg_codegen_debug only | DWARF debug metadata |
| `phase_extern_decls` | cg_emit_extern_declarations exit | FFI declarations |

A workaround in `std/profile.qz`'s `profile_alloc_top_n` reporter
was required: the naive `eputs("…#{label}…")` per-iter form crashes
at the 3rd iteration when the report has >4 entries, with a heisenbug
shape — adding more eputs between indexed-`Vec<String>` reads
makes it disappear. The reporter was reshaped to build the whole
output via `sb_append` then emit once. Filed at
`docs/bugs/PROFILE_ALLOC_TOP_N_VEC_STRING_HEISENBUG.md`.

A second fix in `self-hosted/quartz.qz`: the `profile_alloc_top_n`
call was moved INSIDE the `with Alloc.in_arena(cg_arena) do -> ... end`
install. Phase 1's design assumed the accumulator's
`Map<String, Int>` could be safely read after `arena_destroy(cg_arena)`,
which holds when the map's bucket array never grew (Phase 2's 4-key
case). Phase 4's 17-key case forces map growth → buckets allocated
in cg_arena → dangle after destroy. Reading inside the install is safe.

### RSS overhead (instrumentation OFF)

3-run heavy-workload self-compile of `self-hosted/quartz.qz`
without `--alloc-track` (`benchmarks/rss/quartz_qz_b1_phase4.csv`):

```
phase           base_peak  cur_peak  d_peak  base_wall  cur_wall  d_wall
codegen              2447      2453      +6      55296     56332   +1036
compile_done         2447      2453      +6      55296     56332   +1036
```

+6 MB peak (0.25%) / +1.0s wall (1.9%). Near run-to-run noise — the
gate-off path is one global read + branch per chokepoint.

### Attribution data — heavy workload

Single-run heavy-workload self-compile with `--alloc-track --memory-stats`
(captured `benchmarks/rss/quartz_qz_alloc_track_phase4.txt`,
total_bytes=205,405,807 across 8,949,725 calls):

| Rank | Label | Bytes | Calls | Notes |
|---:|---|---:|---:|---|
| 1 | `phase_function_loop` | 77,033,726 | 1 | **96% of all IR text** — the entire `cg_emit_function` for-loop |
| 2 | `cg_emit` | 51,496,338 | 5,776,519 | Phase 2 chokepoint — fires inside phase_function_loop almost entirely |
| 3 | `mir_new_instr` | 36,130,336 | 410,572 | Phase 2 chokepoint — fires during MIR phase, NOT codegen |
| 4 | `cg_emit_line` | 23,217,978 | 1,842,265 | Phase 2 chokepoint — fires inside phase_function_loop |
| 5 | `cg_emit_int` | 14,725,632 | 920,352 | Phase 2 chokepoint — fires inside phase_function_loop |
| 6 | `phase_string_constants` | 2,346,977 | 1 | 17,655 strings × ~133 bytes/IR-line |
| 7 | `phase_loop_metadata` | 265,860 | 1 | LLVM loop vectorize.enable annotations |
| 8 | `phase_runtime_decls` | 84,597 | 1 | small |
| 9 | `phase_global_vars` | 30,945 | 1 | small |
| 10 | `phase_effect_runtime` | 30,890 | 1 | small (effect dispatch tables) |
| 11 | `phase_const_decls` | 23,732 | 1 | small |
| 12 | `phase_custom_map` | 8,228 | 1 | tiny |
| 13 | `phase_struct_hash_eq` | 6,984 | 1 | tiny |
| 14 | `phase_panic_helpers` | 2,580 | 1 | tiny |
| 15 | `phase_str_hash_helper` | 574 | 1 | tiny |
| 16 | `phase_main_wrapper` | 397 | 1 | tiny |
| 17 | `phase_extern_decls` | 33 | 1 | minimal — no extern decls in self-compile |
| 18-20 | `phase_struct_types` / `phase_race_detector` / `phase_binary_layout_manifest` | 0 | 1 | zero IR text emitted |

(`phase_module_init` not in top-20 — emitted near-zero bytes too.)

### Headline

**The IR-text emission distribution is overwhelmingly dominated by
the per-function loop**: 77 MB of the 80 MB total IR file (96.4%)
comes from `cg_emit_function`'s for-loop. Post-loop emits
cumulatively contribute 2.9 MB (3.4%); pre-loop emits 0.1 MB (0.1%).

This is a *very different finding* from Phase 3's design assumption.
Phase 3 had assumed that wrapping `cg_emit_function` in a per-function
arena would drop peak by ~1000 MB. Phase 3 verified
`arena_bytes_used` of ~430 MB cumulative through fn_arena across the
loop, but peak only dropped 32 MB. Reasoning then: "the unattributed
1100 MB lives somewhere outside the loop." Phase 4 Path B refutes
that hypothesis: post-loop emits emit only 2.9 MB of IR text, and
their intermediate-allocation overhead is bounded by a similar ratio
to the chokepoint data (cumulative ~5–6× IR-text in
`cg_emit_function` per Phase 2 → Phase 3 attribution gap). At most
~15-20 MB of cg_arena content lives in post-loop emits.

### Where is the 1100 MB unattributed peak, then?

By elimination + the data we now have:

- Per-function loop emits 77 MB of IR text and ~430 MB of arena
  intermediates (Phase 3 fn_arena measurement). **Total cg_arena
  content from per-function loop: ~507 MB**.
- Post-loop emits emit 2.9 MB of IR text + ~15-20 MB of intermediates.
  **Total cg_arena content from post-loop: ~20 MB**.
- Pre-loop emits emit 0.14 MB of IR text + tiny intermediates.
  **Total cg_arena content from pre-loop: <1 MB**.
- **Sum: ~528 MB cumulative cg_arena work attributable to emits.**
- **Codegen peak transient gap: ~1244 MB** (2447 baseline − 1206 post-codegen-live − ~3 MB outside cg_arena).
- **Unattributed gap: ~716 MB.**

Where could the missing ~716 MB live?

1. **Master `out` StringBuilder grow leaks**. Each `__qz_realloc`
   under the Alloc default decomposes into `alloc_new + memcpy +
   dealloc_old(no-op)`. Master `out` doublings: 64 KB → 128 KB →
   256 KB → … → 64 MB → ~80 MB final size (~11–12 doublings).
   Cumulative leaked old buffers in cg_arena ≈ 64+128+…+64 MB +
   80 MB partial ≈ **~135 MB**.
2. **State Vec growths inside `cg_emit_function`'s call tree**.
   `state.string_pool` grows to 17,655 entries (~140 KB metadata
   + the strings themselves ~3 MB). `state.local_vars` per-function.
   `loop_metadata_ids`, `dilocation_*`, etc. Cumulative leaks ~50 MB.
3. **Per-call interpolation strings within `cg_emit_function`'s
   call tree** that are NOT chokepointed. Phase 2's 4 chokepoints
   capture cg_emit/_line/_int — but the *interp string operand*
   that's passed into them is constructed before the call, allocated
   in cg_arena, and never released. Volume = 89 MB Phase-2-attributed
   IR text bytes × O(1.5x) interp overhead ≈ **~130 MB**.
4. **Vec/Map allocations inside MIR-phase output that leaks into
   codegen**. mir_new_instr is 36 MB (Phase 2 attributed). MIR has
   its own Vec/Map structures that may be retained in cg_arena's
   parent allocator. Unclear without mapping.
5. **Operand argument boxing for effect calls**. Every `cg_emit*`
   call goes through the Emit effect's perform-dispatch, which
   allocates an `args` array. With 8.5M perform calls, even 16-byte
   args arrays = ~136 MB.

Items 1, 3, 5 alone could account for 400+ MB. Combined with items
2, 4 plus other small contributors we haven't enumerated, plausibly
the full ~716 MB.

### Phase 5 plan — pursue master-out grow-leaks first

The Phase 4 data points to **operand-encoding overhead in the
Emit effect's perform dispatch + master-out grow-leaks** as the
two largest single fixes. Phase 5 candidates ranked by confidence:

**Phase 5.A: Pre-grown master `out` buffer.** Allocate `out`'s
underlying buffer at 128 MB upfront before the for-loop instead of
doubling from 64 KB. Eliminates ~135 MB of cumulative grow-leaks at
the cost of ~128 MB always-allocated regardless of program size
(net win for any program emitting >1 MB IR — i.e. essentially all).
Implementation: change `var out = sb_new()` to
`var out = sb_new_with_capacity(128 * 1024 * 1024)` (or whatever
the StringBuilder API offers). One-line change. Risk: low —
StringBuilder must already support pre-growth.

**Phase 5.B: Effect-perform args-array reuse.** The Emit effect's
perform dispatch allocates a fresh args Vec per call. With 8.5M
calls, this is ~136 MB. If the perform dispatch can take a
stack-allocated args array (via SIMD-style fixed-size args[2] for
2-arg perform), the alloc disappears. Requires changes to MIR
lowering of perform_op + the effect runtime. Higher risk, likely
1-2 quartz-day work. Defer to Phase 5.C unless Phase 5.A doesn't
deliver enough.

**Phase 5.C: Interpolation-elimination sweep on the hot path.**
Convert ~6,000 interpolated `cg_emit_line(out, "  %v_#{x} = ...")`
sites in `cg_intrinsic_*.qz` to multi-call `cg_emit(out, "  %v_");
cg_emit_int(out, x); cg_emit(out, " = ...")` chains. ~130 MB savings.
Mechanical but tedious. Defer unless 5.A/5.B don't close enough
of the gap.

### Phase 4 calibration

- 4 small file edits (codegen.qz +93 lines net for 17 bookends,
  std/profile.qz reporter rewrite, quartz.qz top_n move to inside
  arena, codegen_runtime.qz unchanged).
- 1 bug doc filed.
- 1 fixpoint pass (~3 minutes).
- 3-run heavy-workload measurement (~3 minutes).
- 1-run heavy-workload `--alloc-track` capture (~57 sec).
- ~0.5 quartz-day total (within budget; debug session for the
  heisenbug ate the bulk).

### Lesson — IR-text-emit volume is NOT a proxy for arena content

Phase 4 Path B's per-phase IR-text deltas localized 96% of IR-text
to the per-function loop. But the corresponding arena content at
peak is dominated by **interpolation intermediates + StringBuilder
grow-leaks + effect-perform args boxing** — none of which show up
in `sb_size(out)` deltas. The bookend tells you "this phase emitted
N bytes to master out"; it doesn't tell you "this phase allocated
M bytes total in the arena." The cumulative chokepoints (cg_emit_*,
mir_new_instr) attribute 89 MB of through-out byte volume, but the
arena content at peak is ~1.2 GB. The interp/perform/grow-leak axis
needs different instrumentation (sample heap deltas at phase
boundaries) — filed implicitly as Phase 5 instrumentation when
needed.

## Phase 5.A — pre-grown master `out` buffer (shipped 2026-05-02)

### What landed (two-pass)

**Pass 1** (`f04af0df`): `sb_new_with_capacity(cap: Int): StringBuilder`
intrinsic substrate. Three-file touchpoint per the post-2026 registry-
consolidated intrinsic-add pattern (mir.qz no longer needs a separate
recognition step — `intrinsic_registry::is_intrinsic` is the single
source of truth):

- `self-hosted/middle/typecheck_builtins.qz`: register name with
  `TYPE_STRINGBUILDER` return.
- `self-hosted/backend/intrinsic_registry.qz`: register with
  `INTRINSIC_CAT_SB`.
- `self-hosted/backend/cg_intrinsic_sb.qz`: emit handler clones
  `sb_new`'s structure but reads cap from `args[0]`, floors via
  `select` on a runtime `icmp slt cap_arg, 64` (matches sb_new's
  default minimum buffer), allocates the data buffer at the
  runtime-determined cap.
- `spec/qspec/sb_new_with_capacity_spec.qz`: 5 cases — small cap,
  cap < 64 floor, cap == 0, MB-class cap, behavioral parity with
  sb_new. All green.

The design memo's "one-line change" assumption was wrong; no
`sb_new_with_capacity` API existed prior to this phase.

**Pass 2** (this commit): two-call-site change in
`self-hosted/backend/codegen.qz`:

```quartz
def cg_codegen(...): String
  var out = sb_new_with_capacity(134217728)  # was sb_new()
  defer sb_free(out)
  ...

def cg_codegen_debug(...): String
  var out = sb_new_with_capacity(134217728)  # was sb_new()
  defer sb_free(out)
  ...
```

`cg_emit_extern_declarations` (a third sb_new callsite at
codegen.qz:850) was deliberately NOT changed: Phase 4 measured it
emitting only 33 bytes in self-compile. Pre-growing it would just
waste memory.

### RSS measurement (3-run median, instrumentation OFF)

Heavy-workload self-compile of `self-hosted/quartz.qz` against the
Phase 4 baseline (`benchmarks/rss/quartz_qz_b1_phase4.csv`),
captured at `benchmarks/rss/quartz_qz_b1_phase5a.csv`:

```
phase           base_peak  cur_peak  d_peak  base_wall  cur_wall  d_wall
codegen              2453      2330    -123      56332     56806    +474
compile_done         2453      2330    -123      56332     56806    +474
```

**-123 MB peak (-5.0% of 2453 MB baseline) / +474 ms wall (+0.84%,
within run-to-run noise). Live RSS at compile_done unchanged at
1208 MB.** No regressions on earlier phases (lex/parse/resolve/
typecheck/mir all within ±1 MB / ~ -100 ms — all noise).

This is the largest measured peak win in the post-A.2 era. For
context:

- Phase 3 per-function arena: -32 MB peak / +2.4s wall / +277 MB
  live regression — reverted.
- A.2 P2 Slice<Byte> sweep: -1 MB peak / +15 ms wall — reverted.
- Phase 5.A pre-grow: -123 MB peak / +0.5s wall / 0 live regression
  — **shipped**.

### Calibration

- Pass 1: 3 file edits (typecheck_builtins.qz +1, intrinsic_registry.qz +1,
  cg_intrinsic_sb.qz +67) + spec (60 lines) + 1 quake guard.
- Pass 2: 2 file edits (codegen.qz, two callsites with rationale comments)
  + 1 quake guard + 3-run measurement.
- ~0.4 quartz-day total. The "one-line change" estimate from the
  Phase 5.A sketch was off by ~6× (substrate add not budgeted), but
  the empirical-measurement step matched the prediction (135 MB
  predicted, 123 MB achieved, 91% of target).

### Headline finding

The Phase 5 candidate-list ranking by confidence held empirically:
master-out grow-leaks WERE the largest single contributor to the
unattributed cg_arena content. Pre-grow eliminated ~123 MB of the
~716 MB Phase-4 unattributed peak gap (~17%). Remaining unattributed
peak: **~593 MB**.

The remaining mass per the Phase 4 enumeration:
- ~136 MB effect-perform args-array boxing (Phase 5.B)
- ~130 MB interpolation strings on the hot path (Phase 5.C)
- ~50 MB state Vec growths inside cg_emit_function's call tree
- ~80 MB MIR leak into codegen (`mir_new_instr` allocations)
- ~200 MB other (state Vecs, scope state, debug metadata, sanitized
  name buffers, etc.)

Phase 5.B (effect-perform args boxing) and Phase 5.C
(interp-elimination sweep) remain queued. Both target similar mass
(~130 MB each); 5.B is more architecturally invasive (MIR lowering +
runtime ABI), 5.C is mechanical-but-tedious (~6,000 callsite edits).

### Lesson — substrate cost dominates "one-line change" estimates

The Phase 5.A design memo budgeted "one-line change" for the callsite
swap. Actual cost: 3-file intrinsic substrate + spec + two-pass
fixpoint = ~0.4 quartz-day. The substrate add was orders of magnitude
larger than the swap itself.

Future-Claude calibration: when a roadmap entry assumes "API X exists,
just call it," verify the API actually exists before sizing the work.
The "Adding Intrinsics" gotcha in CLAUDE.md notes 4-area touchpoints;
the post-2026 registry-consolidated pattern is 3-area (intrinsic_registry
subsumes mir.qz's recognition role) — but still much more than "one
line."

### Phase 5.B / 5.C status

Both queued in the candidate list above. Recommendation: instrument-
first re-attribution before committing to either. Phase 4 Path B's
chokepoint+bookend pattern attributed only ~30% of the peak gap (89 MB
chokepoints + ~3 MB bookends out of ~1244 MB). Without finer
instrumentation, ranking 5.B vs 5.C by expected impact is guesswork.
Phase 5.D (deferred) — sample-heap-delta instrumentation at phase
boundaries — would localize the remaining ~593 MB before designing the
next intervention. Pattern reuse: prof_alloc_site shape extends
naturally to a "checkpoint heap RSS" probe.

## Phase 5.D — arena-bytes bookends + dominant-allocator fix (shipped 2026-05-02)

### What landed

**Substrate (instrumentation):**

Phase 5.D paired every `phase_<X>` IR-text bookend in `cg_codegen` /
`cg_codegen_debug` / `cg_emit_extern_declarations` with a parallel
`arena_<X>` bookend that records `arena_bytes_used(arena_handle) -
pre_arena` per phase. The arena delta subsumes IR text + interp
intermediates + master-out grow leaks + state Vec growths — every
allocation routed through the cg_arena `Alloc.in_arena` handler.

Plumbing:
- `extern "C" def __qz_effect_state_get(): Int` declared in
  `self-hosted/backend/codegen.qz` near the top.
- `var arena_handle = __qz_effect_state_get()` captured once at the
  top of each function (gated on `profile_get_alloc_track() == 1` so
  OFF-mode arena_handle is 0; `arena_bytes_used(0)` returns 0 via the
  chain-walk's null-head termination).
- 33 new `arena_<X>` `prof_alloc_site` calls across the 17 cg_codegen
  phase boundaries + 17 cg_codegen_debug boundaries +
  cg_emit_extern_declarations.
- `profile_alloc_top_n(20)` bumped to `profile_alloc_top_n(60)` in
  `quartz.qz` to fit the 50+ entries in the report.

**Headline finding (single-run heavy workload, --alloc-track ON):**

```
[prof] alloc-site arena_extern_decls: 1380232624 bytes (1 calls)   ← 1.38 GB
[prof] alloc-site phase_function_loop: 77181073 bytes  (1 calls)
[prof] alloc-site arena_function_loop: 72217184 bytes  (1 calls)
[prof] alloc-site cg_emit:        51604105 bytes (5,787,348 calls)
[prof] alloc-site mir_new_instr:  36181024 bytes   (411,148 calls)
[prof] alloc-site cg_emit_line:   23252250 bytes (1,845,442 calls)
[prof] alloc-site cg_emit_int:    14757552 bytes   (922,347 calls)
[prof] alloc-site arena_string_constants: 13925984 bytes (1 calls)
... (all other arena_X < 320 KB) ...
```

**`arena_extern_decls = 1.38 GB`** — single function call attributing
**~96% of the ~1.4 GB Phase 4 unattributed peak gap**. Vastly more
concentrated than Phase 4's enumerated candidates predicted. The
prior Phase-4 candidate ranking (5.B effect-perform args ~136 MB,
5.C interp-elimination ~130 MB, etc., totaling ~600 MB across 5+
items) was completely wrong about the locality.

**Root cause:**

`cg_emit_extern_declarations` (codegen.qz:860) loops over ~200 extern
function entries. For each name, it scanned `existing_ir` (~80 MB
master IR text) for `"@name("` to skip already-declared symbols. The
scan was implemented as:

```quartz
while search_start < str_byte_len(existing_ir)
  var tail = str_byte_slice(existing_ir, search_start, str_byte_len(existing_ir))
  var rel_pos = __str_index(tail, check_key)
  break if rel_pos < 0
  ...
end
```

Each iteration allocated a fresh String tail (size ≈ 80 MB - search_start)
into cg_arena. Across ~200 names × dominant ~7 MB average per-iter slice
= 1.38 GB cumulative. Allocations stayed live until `arena_destroy(cg_arena)`.

**The fix:**

Added two allocation-free helpers to `self-hosted/shared/str_compat.qz`:

```quartz
def __str_index_from(s: String, sub: String, start: Int): Int    # search from offset
def __str_starts_with_at(s: String, prefix: String, at: Int): Int  # check prefix at offset
```

Rewrote the cg_emit_extern_declarations search loop to use them in
place of `str_byte_slice + __str_index` and `str_byte_slice +
str_starts_with`. Zero new allocations during the search.

### RSS measurement (3-run median, instrumentation OFF)

Heavy-workload self-compile of `self-hosted/quartz.qz` against the
Phase 5.A baseline rebuilt in this session. Macro drift between
the original Phase 5.A measurement (00:05) and the post-Phase-5.D
measurement (01:30) inflated raw peaks by ~280 MB (page residency,
kernel scheduler state — same /tmp/quartz-phase5a-rebuild binary
showed 2330 MB → 2611 MB across the session). Apples-to-apples
requires re-baselining at the same machine state.

Captured: `benchmarks/rss/quartz_qz_b1_phase5d.csv` (Phase 5.D + fix)
vs `benchmarks/rss/quartz_qz_phase5a_drift_baseline.csv` (Phase 5.A
binary re-measured at the same machine state).

```
phase           base_peak  cur_peak  d_peak  base_wall  cur_wall  d_wall
codegen              2611      1293   -1318      61935     63024   +1089
compile_done         2611      1293   -1318      61935     63024   +1089
```

**-1318 MB peak (-50.5% of 2611 MB baseline) / +1089 ms wall (+1.8%,
within run-to-run noise).** Live RSS at compile_done unchanged at
1209 MB.

For comparison vs the original Phase 5.A snapshot (now superseded by
the drift-baseline above for fair attribution):

| Phase            | OFF peak (MB) | OFF wall (ms) |
|---|---|---|
| Phase 4 (original)         | 2453 | 56332 |
| Phase 5.A (original)       | 2330 | 56806 |
| Phase 5.A (drift-baseline) | 2611 | 61935 |
| **Phase 5.D + fix**        | **1293** | **63024** |

Vs Phase 5.A original snapshot: -1037 MB peak (the conservative
measurement). Vs drift-baseline: -1318 MB peak (the apples-to-apples
measurement). Both confirm a transformative win.

### --alloc-track ON verification (post-fix)

```
[prof] alloc-site arena_extern_decls: 1488 bytes (1 calls)   ← was 1.38 GB
[prof] alloc-site phase_extern_decls: 33 bytes (1 calls)
[prof] codegen: 1532 MB (+496), 1615 MB peak (63653ms)
[prof] compile_done: 1532 MB (+0), 1615 MB peak (63653ms)
```

`arena_extern_decls` dropped from 1,380,232,624 bytes to 1,488 bytes
(99.99989% reduction). The remaining 1488 bytes is overhead from the
`var emitted = map_new()` allocation + the small `out` StringBuilder
chain that holds the 33-byte result.

ON-mode codegen peak: 2933 MB (Phase 5.D bookends, no fix) → 1615 MB
(Phase 5.D bookends + fix). -1318 MB on the ON-mode peak too.

### Bookend OFF-mode cost — investigation deferred

During investigation, the bookends alone (without the fix) showed a
+279 MB / +5031 ms regression vs Phase 5.A in OFF mode. Mechanism
remained unclear after gating arena_handle to 0 — gating eliminated
the per-call chain walks (which terminate immediately on null head),
yet the regression persisted. Hypotheses considered but not
verified: I-cache pressure from larger cg_codegen function code,
perform-effect dispatch arg-buffer allocation accumulation,
something about TLS access patterns under macOS arena pressure.

The fix shipping in this same Phase 5.D commit overshadows the
bookend regression: net wall change is +1.1s vs the drift-baseline,
which is within noise. The bookends remain in place because their
attribution capability is the ENTIRE point of Phase 5.D — re-running
`--alloc-track` on any future regression hypothesis is one CLI flag
away. If a future phase shows the bookends materially block other
optimizations, gating the per-bookend prof_alloc_site calls
themselves (not just the arena_handle capture) is the next step.

### Calibration

- Substrate: `extern "C" def __qz_effect_state_get(): Int` + 33
  arena bookends + 2 helpers (`__str_index_from`,
  `__str_starts_with_at`).
- Fix: rewrote cg_emit_extern_declarations search loop to use the
  helpers (~30 line changes net).
- Total file edits: 4 (codegen.qz, str_compat.qz, quartz.qz top-N
  bump, B1_ALLOC_ATTRIBUTION.md).
- Two `quake guard` passes (one for bookends, one for the fix +
  helpers — second pass was needed because the helpers introduced
  new functions that needed gen0→gen1→gen2 verification).
- Heavy-workload measurements: 1 ON capture + 2 OFF runs
  (post-bookends + post-fix) + 1 drift-baseline re-measure.
- ~1 quartz-day total. The substrate-vs-attribution split was
  expensive (substrate revealed an unexpected OFF-mode regression
  that ate diagnostic time), but the fix itself was cheap once the
  attribution data was in hand.

### Lesson — bookends are a high-resolution attribution lens

Phase 4 Path B's IR-text bookends localized 96% of IR text to the
function loop but TOLD US NOTHING about the 1.38 GB allocator hiding
in `cg_emit_extern_declarations` (which produces only 33 bytes of
IR text). The arena bookends — same shape, different metric — found
it in a single ON-mode run. The next time a "where is the peak"
attribution question arises, default to **arena bookends, not IR
text bookends**. The arena delta is the strict superset.

The Phase 5 candidate ranking from the design memo's enumeration
(5.B perform args, 5.C interp elimination, etc.) was COMPLETELY wrong
about which intervention mattered. None of those candidates would
have moved peak by anywhere near 1.3 GB. Without instrumentation-
first attribution, the Phase 5 effort would have spent days on
mechanical sweeps with marginal effect. **Instrument before
intervene** is the operational mantra.

### Phase 5.B / 5.C / 5.E status post-5.D

With the dominant 1.38 GB allocator gone, the remaining ~600 MB peak
gap (Phase 5.D's 1209 MB live → ~1293 MB peak baseline minus the
post-codegen working set) is dominated by:

1. **`arena_function_loop` = 72 MB** — interp intermediates inside
   the per-function loop. Phase 5.B (effect-perform args boxing —
   ~136 MB Phase 4 prediction) and Phase 5.C (interp-elimination
   sweep — ~130 MB) collectively target this. Now that the dominant
   allocator is gone, these become the largest remaining levers.
2. **`arena_string_constants` = 14 MB** — interp overhead inside
   the string constants pool emit. ~6× IR-text-to-arena ratio.
3. **`arena_loop_metadata` / `arena_struct_hash_eq` / etc.** — all
   <100 KB. Negligible.

**Recommendation for next phase:** Phase 5.B (perform-args reuse)
remains the highest-confidence intervention — it targets the dominant
remaining allocator (function loop's arena work) AND has a clear
mechanism (eliminate per-perform-call args buffer allocation). Phase
5.C is mechanical-but-tedious; defer until after 5.B's effect is
measured. Sub-1 GB peak is now plausible after one more intervention.

## Phase 5.E — master_out outside arena + sb scan path (shipped 2026-05-02)

### Phase 5.B premise was invalid — pivoted

The post-Phase-5.D recommendation pointed to "Phase 5.B (perform-args reuse) ~136 MB."
Reading the actual codegen at `codegen_instr.qz:1898` and `codegen_runtime.qz:1000`
revealed that **all `__qz_effect_perform` argv arrays are already
`alloca`-allocated on the stack**, not heap. The original Phase 4
enumeration ("8.5M perform calls × 16-byte args ≈ 136 MB") modeled a
heap-allocation path that does not exist. There is no perform-args
boxing to eliminate; that work was already done as part of Milestone E
(the comment at codegen_instr.qz:1889 calls it out: "Stack-alloca a
fresh `[argc x i64]` per perform call (not hoisted to fn entry — each
perform captures its own args)").

Pivoted Phase 5.B → **Phase 5.E**: target the next-most-concentrated
allocator visible in the post-5D arena bookend report, which is
**`out.to_string()` at the end of `cg_codegen` + `arena_promote_string`**
in quartz.qz. That path doubles ~80 MB of IR text twice (in-arena copy
inside `with Alloc.in_arena`, then heap copy via `arena_promote_string`
after the with-block exits). The doubling is invisible to the existing
arena bookends because the in-arena to_string runs AFTER the last
bookend (`arena_loop_metadata`) and is captured only by the final
`arena_bytes_used` total, which the bookend report doesn't sum.

### What landed

**Substrate (one new intrinsic + three Quartz helpers):**

- `self-hosted/middle/typecheck_builtins.qz`: register `sb_byte_at`
  with `TYPE_INT` return.
- `self-hosted/backend/intrinsic_registry.qz`: register with
  `INTRINSIC_CAT_SB`.
- `self-hosted/backend/cg_intrinsic_sb.qz`: emit handler reads sb's
  data buffer at offset `idx`, zero-extends i8 → i64. No bounds check
  (caller respects `sb_size`).
- `self-hosted/shared/str_compat.qz`: three new Quartz helpers backed
  by `sb_byte_at` — `__sb_index_from(sb, sub, start)`,
  `__sb_starts_with_at(sb, prefix, at)`, `__sb_contains(sb, sub)` —
  mirroring the existing `__str_index_from` / `__str_starts_with_at`
  / `str_contains` semantics but reading from a StringBuilder.
- `spec/qspec/sb_byte_at_spec.qz`: 15 cases covering the intrinsic +
  all three helpers. Green.

**Refactor:**

- `cg_codegen` and `cg_codegen_debug` signatures changed: `out: Int`
  (StringBuilder handle) is now the FIRST parameter; return type
  changed from `String` to `Void`. The internal
  `var out = sb_new_with_capacity(134217728); defer sb_free(out)`
  allocation + `return out.to_string()` lines are deleted. Caller
  manages master_out's lifecycle.
- `cg_emit_extern_declarations` signature: `existing_ir: String` →
  `existing_ir_sb: Int`. The post-5D fix's slice-quadratic
  workaround (`__str_index_from`, `__str_starts_with_at`) is
  swapped for the new `__sb_index_from` / `__sb_starts_with_at`
  / `sb_byte_at`. The extern-var loop's `str_contains(existing_ir,
  at_name)` is swapped for `__sb_contains(existing_ir_sb, at_name)`.
- `quartz.qz`: in both debug-mode and default codegen branches,
  `var master_out = sb_new_with_capacity(134217728)` is now
  allocated BEFORE `var cg_arena = arena_new(...)` so its 128 MB
  pre-grown buffer lives on the default heap rather than entering
  cg_arena. After `with Alloc.in_arena(cg_arena) do -> ... end`
  exits, `llvm_ir = master_out.to_string()` runs on the default
  heap, so the resulting String is allocated outside the arena.
  The redundant `arena_promote_string(llvm_ir)` is removed (was
  copying llvm_ir from arena to heap — now llvm_ir is already on
  heap). `extern_decls = arena_promote_string(extern_decls)`
  remains because cg_emit_extern_declarations's local sb still
  allocates inside the arena.
- `bootstrap.qz`: matches the new `cg_codegen` / `cg_codegen_debug`
  / `cg_emit_extern_declarations` signatures.
- Incremental path: introduces a small temporary `sb_new()` +
  `sb_append(llvm_ir)` to feed the existing String into the new
  StringBuilder-typed `cg_emit_extern_declarations`. Adds one
  ~80 MB transient copy in incremental mode (no impact on heavy
  workload's peak; incremental mode runs `cg_codegen_incremental`
  which is its own codepath).

**Why this works peak-wise:**

Pre-Phase-5.E peak path during heavy workload:
- master_out's 128 MB pre-grown chunk is allocated INSIDE
  `with Alloc.in_arena` → goes to cg_arena.
- IR text fills ~80 MB of that chunk (touched pages).
- `out.to_string()` at the end of cg_codegen allocates an 80 MB
  String IN cg_arena (the in-arena copy).
- After with-block exits: `arena_promote_string(llvm_ir)` copies
  the 80 MB String to the default heap (the heap copy).
- Peak moment: pre-existing MIR (~977 MB) + arena content (master_out
  128 MB chunk + in-arena to_string 80 MB + 86 MB other bookend
  deltas = 294 MB) + heap promote copy (80 MB). ≈ 1293 MB measured.

Post-Phase-5.E peak path:
- master_out's 128 MB chunk on default heap (touched ~80 MB).
- IR text fills ~80 MB on heap.
- `cg_emit_extern_declarations` scans master_out's buffer directly
  via sb_byte_at + helpers — no String materialization, no in-arena
  copy.
- After with-block exits: `master_out.to_string()` allocates 80 MB
  on default heap (single, non-doubled allocation).
- Peak moment: pre-existing (~977 MB) + master_out heap (~80 MB
  touched) + arena content (just bookend deltas, ~86 MB) + heap
  to_string (80 MB). ≈ ~1223 MB predicted.

**Measured savings: -76 MB peak / -5904 ms wall** (3-run heavy-workload
median, captured at `benchmarks/rss/quartz_qz_b1_phase5e.csv`,
2026-05-02 02:25, same session as the Phase 5.D 5d csv so machine
state is apples-to-apples):

```
phase           5d_peak  5e_peak  d_peak  5d_wall  5e_wall  d_wall
codegen            1293     1217     -76    63024    57120   -5904
compile_done       1293     1217     -76    63024    57120   -5904
```

Wall improved by 9.4% — slightly larger than the peak win in
percentage terms. The cause: eliminating the `out.to_string()`
in-arena memcpy (80 MB) + the `arena_promote_string(llvm_ir)`
heap-copy memcpy (80 MB) together represents ~160 MB of memcpy
that no longer happens. The peak savings (-76 MB) reflects the
overlap window where both copies were briefly co-resident.

### Calibration

- Two-pass fixpoint required: pass 1 ships substrate (intrinsic
  registry + builtin + handler), pass 2 ships the helpers + caller
  refactor. Pass 2's str_compat helpers reference `sb_byte_at`,
  which gen0 binary doesn't recognize, so the helpers cannot be in
  the same source state as the substrate.
- 6 file edits + 1 new spec file: `typecheck_builtins.qz`,
  `intrinsic_registry.qz`, `cg_intrinsic_sb.qz`, `str_compat.qz`,
  `codegen.qz` (signature + extern_decls scan rewrite),
  `quartz.qz` (master_out outside arena), `bootstrap.qz`,
  `sb_byte_at_spec.qz`.
- Total wall-clock: ~1 quartz-day (mostly research time
  determining that Phase 5.B's premise was invalid; the actual
  refactor was ~30 min once the path was clear).

### Lesson — verify the premise before sizing the work

Phase 5.B was queued with high confidence ("highest-confidence
intervention") based on the Phase 4 candidate enumeration. But
the enumeration was a hypothesis, not a measurement. Reading
the actual MIR_PERFORM_OP lowering revealed the args boxing was
already on stack via alloca — the work to "eliminate" it was a
no-op. **Before sizing a phase, grep the actual codegen for the
mechanism it claims to fix.** Phase 5.D's "instrument before
intervene" applies here too: the design memo's mental model can
become stale, and the codegen is the source of truth.
