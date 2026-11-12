# Profile Effect — Design Memo

> **Filed:** 2026-05-01 (start of A.6 session, immediately after A.3
> Cache effect closeout `14b47ee6`).
> **Sequencing:** Phase A.6 of the post-audit roadmap. Promoted to
> #1 priority after A.3 fully closed and A.4 audit demoted (no
> mechanical wins). Substrate for Phase C.8 statistical bench.
> **Recipe inheritance:** mirrors A.3 Cache's pass-1/pass-2/pass-3
> shape. Cross-reference [`CACHE_EFFECT_PLAN.md`](CACHE_EFFECT_PLAN.md)
> for any plumbing detail not redocumented here.

## Motivation

Three signals converged on this work item:

1. **`--memory-stats` and `--progress` are two ad-hoc flags doing the
   same job.** Both gate per-phase output; both write to stderr at the
   same call sites; both share `g_mem_start_ms` as their wall-time
   anchor. The only difference is the output format (human-readable
   `[mem]` lines vs. NDJSON events). The current shape has 4 Quartz
   functions (`mem_report`, `progress_event`, `progress_start_event`,
   `progress_done_event`), 5 module-globals (`g_memory_stats`,
   `g_mem_prev_rss`, `g_mem_start_ms`, `g_progress_events`,
   `g_progress_file`), and 14 phase-boundary call sites with a 2:1 ratio
   of mem-then-progress in `compile()`.

2. **Wall-time-regressed-N-to-M is hand-tracked across roadmap entries.**
   Where We Are entries routinely cite "wall regressed 18.3s → 32s,
   acceptable trade" by hand. That's a measurement that should fall out
   of CI tooling, not a commit-message detail. The bench framework
   (Phase C.8) needs span-and-sample primitives; if Profile ships first,
   C.8 collapses to a default handler that aggregates spans.

3. **Test handler ergonomics.** Today there is no way to mock the phase
   timing surface for a spec test. Tests that want to assert "this
   compile path took N phases" must parse stderr — brittle, output-format
   dependent. With a Profile effect, `with Profile { prof_phase: my_capture }
   do -> compile(...) end` exposes the phase sequence as test data.

## Scope decisions

### Op shape — 4 ops covering point events + bracketed spans + samples

```quartz
effect Profile
  ## Mark a phase boundary (point event). Default emits one line if
  ## either human-readable or NDJSON profiling is active.
  def prof_phase(name: String): Int

  ## Begin a named span. Returns a handle (timestamp ns) used by end.
  ## Default emits start event only when NDJSON is active; human format
  ## defers all output until matching prof_span_end.
  def prof_span_begin(name: String): Int

  ## End a span. begin_handle from prof_span_begin. Returns elapsed ns.
  def prof_span_end(begin_handle: Int, name: String): Int

  ## Record a key/value sample (counter or gauge). value is interpreted
  ## by the handler. Default emits one line if either format is active.
  def prof_sample(name: String, value: Int): Int
end
```

**Why these four:**

- `prof_phase` directly replaces the union of `mem_report(name)` +
  `progress_event(name)` — 14 call sites collapse to 14 single calls.
- `prof_span_begin` / `prof_span_end` are the bench-framework primitive.
  C.8 ships a `bench_default_handler` that aggregates spans into
  mean/median/p95/p99 distributions over warmup-trimmed runs.
- `prof_sample` covers counters (function counts, allocation totals)
  and gauges (current RSS, queue depths). Decouples the value from
  string-formatting at the call site.

**Why not block-scoped `with Profile.span("foo") do -> body end`:**
the effect-handler ABI is `(op_name, argc, argv): Int`. Block-scoped
syntax would require parser-level recognition (NODE_WITH variant
inspecting the effect path) — out of scope for an effect migration.
Bracketed `prof_span_begin/end` covers the same use case with
`var h = prof_span_begin("foo"); ...; prof_span_end(h, "foo")`.

### Default handler — Quartz function, no-op unless explicitly enabled

The Cache default forwards every op to the underlying impl
unconditionally. Profile cannot — every Quartz program that imports a
module that imports `std/profile` would start emitting NDJSON to
stderr by default. That's a behavior change for every user.

**Decision:** default handler reads two module-level globals:
`_profile_human_enabled` and `_profile_ndjson_enabled`. Both default
to 0 (no-op). The `--memory-stats` and `--progress` CLI flags become
direct setters via `profile_set_human(1)` / `profile_set_ndjson(1)`,
called from `parse_args`. Without flags: zero overhead (the handler
returns immediately on the gate check). With flags: matches existing
output exactly.

This is **gate-and-emit**, not blessed-relaxation's
gate-via-import — the effect machinery is always available to
user-written `with Profile { ... }` overrides; the *default
behavior* is gated on flags, which the default handler reads itself.

### Plumbing — `uses_profile` mirrors `uses_cache`

`@profile$profile_default_handler` is a Quartz function that pulls in
its own helpers (RSS reads, time reads, NDJSON formatting). Programs
that never call any `prof_*` op shouldn't pay the link cost. Same
recipe as Cache:

- `MirProgram.uses_profile: Int` field + `mir_set_uses_profile()`
  setter.
- Detection in `mir_lower_expr_handlers.qz`: when an op call's
  effect name is `Profile`, set the flag.
- `cg_emit_effect_runtime` / `cg_emit_effect_install_defaults_fn` /
  `cg_emit_effect_main_prelude` signatures grow a `uses_profile`
  parameter; install conditional on it; same shape as Cache's
  Pass 1 install at `codegen_runtime.qz:1500`.

### Why three-pass fixpoint discipline still applies

Pass 1 ships declaration + relaxation + default handler + plumbing,
**no consumer migration in compiler source**. Compiler source still
calls `mem_report` and `progress_event` directly. Pass 2 migrates
exactly one consumer site to validate the effect dispatches end-to-end.
Pass 3 migrates the remaining sites + retires the old surface.

Without the split, gen0 (which doesn't know `prof_phase`) would reject
Pass 2's call as "missing `can Profile` row" and self-compile fails.
This is the same dance Cache used (`e56200ac` Pass 1, `f67ac8ee`
Pass 2). Reference comments at `typecheck_expr_handlers.qz` lines
1633–1645.

## Recipe — Pass 1 (mechanism, no consumer migration)

### File: `std/profile.qz` — new

Mirror `std/cache.qz`'s structure: docstring with usage examples,
effect declaration, default handler, configuration setters.

```quartz
import * from std/io  # for eputs

effect Profile
  def prof_phase(name: String): Int
  def prof_span_begin(name: String): Int
  def prof_span_end(begin_handle: Int, name: String): Int
  def prof_sample(name: String, value: Int): Int
end

# Defaults: zero output. Setters control whether the default handler
# emits anything.
var _profile_human_enabled = 0
var _profile_ndjson_enabled = 0
var _profile_start_ns = 0
var _profile_prev_rss = 0

def profile_set_human(on: Int): Void
  _profile_human_enabled = on
  if on == 1 and _profile_start_ns == 0
    _profile_start_ns = time_mono_ns()
  end
end

def profile_set_ndjson(on: Int): Void
  _profile_ndjson_enabled = on
  if on == 1 and _profile_start_ns == 0
    _profile_start_ns = time_mono_ns()
  end
end

def profile_default_handler(op_name: Int, argc: Int, argv: Int): Int
  # Fast-path: both formats disabled = no-op for prof_phase / prof_sample.
  # Spans always return values regardless of output gate.
  var op = as_string(op_name)
  if op.eq("prof_span_begin")
    return time_mono_ns()
  end
  if op.eq("prof_span_end")
    var begin = load(argv, 0)
    return time_mono_ns() - begin
  end
  if _profile_human_enabled == 0 and _profile_ndjson_enabled == 0
    return 0
  end
  # ... format dispatch on op name × format gate ...
  return 0
end
```

### File: `self-hosted/backend/mir.qz`

Add `uses_profile: Int` field to MirProgram (next to `uses_cache`),
init to 0 in `mir_program_new`, add `mir_get_uses_profile` /
`mir_set_uses_profile` accessors.

### File: `self-hosted/backend/mir_lower_expr_handlers.qz`

In the op-call lowering path, after the `if _op_effect_name.eq("Cache")`
clause, add:

```quartz
if _op_effect_name.eq("Profile")
  mir::mir_set_uses_profile(ctx.mir_ctx_get_program())
end
```

### File: `self-hosted/backend/codegen_runtime.qz`

**Two-branch edits** (linkonce + internal) at the existing string-globals
sections:

```llvm
@__qz_eff_name_profile = linkonce_odr unnamed_addr constant [8 x i8] c"Profile\00"
@__qz_eff_op_prof_phase = linkonce_odr ... c"prof_phase\00"
@__qz_eff_op_prof_span_begin = ... c"prof_span_begin\00"
@__qz_eff_op_prof_span_end = ... c"prof_span_end\00"
@__qz_eff_op_prof_sample = ... c"prof_sample\00"
```

**One install at `cg_emit_effect_install_defaults_fn`** mirroring
Cache's `if uses_cache == 1` block — uses the
`@profile$profile_default_handler` mangled symbol.

**Plumbing** — add `uses_profile: Int` to:
- `cg_emit_effect_runtime` signature line 72
- `cg_emit_effect_install_defaults_fn` signature line 1461
- `cg_emit_effect_main_prelude` signature line 1447
- 4 caller sites in codegen.qz lines 1094, 1136, 1235, 1277.

### File: `self-hosted/middle/typecheck_expr_handlers.qz`

Add `Profile` to the blessed-relaxation OR chain at line 1648:

```quartz
... or _c3_eff_name.eq("Cache") or _c3_eff_name.eq("Profile")
```

### Verification

1. `./self-hosted/bin/quake guard` — fixpoint must hold. Function count
   bumps by ~5 (`profile_default_handler`, `profile_set_human`,
   `profile_set_ndjson`, plus implicit accessors).
2. `./self-hosted/bin/quartz examples/style_demo.qz | …` smoke.
3. Existing FileIo specs / Cache specs / file_io_effect_p54a still green.
4. New `spec/qspec/profile_effect_pass1_spec.qz` proves the effect
   declares + relaxation works (a `prof_phase("foo")` call typechecks
   without `can Profile` row, and at runtime the default handler
   returns 0 because both gates are off).

### Commit shape

Single commit `[a6/profile] Phase 1: Profile effect mechanism (pass 1
infrastructure)`. Approximate diff:
- `std/profile.qz`: ~150 lines new (handler + setters + helpers)
- `codegen_runtime.qz`: ~30 lines (string globals × 2 branches +
  install + signature plumbing)
- `typecheck_expr_handlers.qz`: ~3 lines
- `mir.qz`: ~10 lines (field + accessors)
- `mir_lower_expr_handlers.qz`: ~3 lines
- `codegen.qz`: 4 caller sites updated
- `spec/qspec/profile_effect_pass1_spec.qz`: ~80 lines

## Recipe — Pass 2 (single-consumer migration)

### File: `self-hosted/quartz.qz`

Migrate ONE site — the `mem_report("init")` + `progress_event("init")`
pair at lines 256-257. Replace the pair with:

```quartz
prof_phase("init")
```

Add `import * from std/profile` to the imports (top of file).

Leave the other 6 phase pairs as-is for Phase 3.

### Verification

1. `./self-hosted/bin/quake guard` — fixpoint stamp updates,
   `uses_profile` flag fires.
2. Smoke as above.
3. New `spec/qspec/profile_effect_pass2_spec.qz` — installs a custom
   handler that captures every `prof_phase` call into a Vec, asserts
   the captured phase name matches.

### Commit shape

Single commit `[a6/profile] Phase 1: migrate mem_report("init")
callsite to prof_phase (pass 2 consumer)`.

## Recipe — Pass 3 (remaining sites + flag fold-in)

Remaining work after Pass 2 lands:

1. **Migrate 6 remaining `mem_report` calls** + **7 `progress_event`
   calls** to `prof_phase`. Each pair collapses 1:1 since both used the
   same phase name. Net: 13 deletions + 6-7 additions.
2. **Migrate `progress_start_event(file)`** → `prof_phase("start:#{file}")`
   or add a 5th op `prof_event(name, payload)` for arbitrary string
   payloads. Decision deferred to Phase 3 implementation — if
   `progress_start_event` / `progress_done_event` are the only callers,
   inline them via `prof_phase` with a synthesized name.
3. **Wire flags to setters**: at `quartz.qz:1779`, replace
   `g_memory_stats = parsed_has(args, "--memory-stats")` with
   `profile::profile_set_human(parsed_has(args, "--memory-stats"))`.
   Same for `--progress` → `profile_set_ndjson`.
4. **Delete** `mem_report`, `progress_event`, `progress_start_event`,
   `progress_done_event` Quartz functions and the 4 module-globals
   they used (`g_memory_stats`, `g_mem_prev_rss`, `g_mem_start_ms`,
   `g_progress_events`, `g_progress_file`). The default handler owns
   the equivalent state in `std/profile.qz`.

Estimated diff: -150 lines / +20 lines net in `quartz.qz`.

## Recipe — Pass 4 (test handlers)

Mirror Cache's Phase 3 shape — 3 factories in `std/profile.qz`:

1. **`profile_capture_handler`** — appends each `(op, name, value/handle)`
   tuple to a module-level `Vec<String>` log. Read via
   `profile_capture_log()`, reset via `profile_capture_reset()`.
2. **`profile_silent_handler`** — drops everything; returns 0 for ops,
   monotonic timestamps for span begin/end. Used to suppress profile
   output during test runs that import production code.
3. **`profile_ndjson_handler`** — always emits NDJSON to stderr
   regardless of `_profile_ndjson_enabled` global. Useful for spec
   tests that want to validate the NDJSON shape.

Spec coverage: 4 ops × 3 handlers ~= 12 tests at
`profile_effect_handlers_spec.qz`.

## Hazard map

- **Mangled-symbol guess.** Quartz mangles `def profile_default_handler`
  in `std/profile.qz` as `@profile$profile_default_handler`. Verify via
  `grep "@profile\$profile_default_handler" /tmp/main.ll` after the
  first build. The inline-IR install site references this exact symbol.
- **Span begin/end ABI.** `prof_span_begin` returns the begin timestamp
  (i64 nanoseconds). `prof_span_end` reads `argv[0]` as the begin
  handle. The handler MUST always return a real timestamp — not 0 — even
  when both gates are off, so the bench framework can compute durations
  even with default-noop emit. This is the one op that's not gate-able.
- **Reentrancy.** The default handler may be invoked from inside
  `compile()`, which is itself invoked from spec test bodies that may
  override the handler. The per-`with`-block install/uninstall
  discipline handles this naturally; no special care needed.
- **`as_string(op_name)` decoding.** Same convention as Cache —
  `op_name` is a String i64 handle, not a raw Int. The handler ABI is
  `(op_name: Int, argc: Int, argv: Int): Int`.
- **Don't run RAM-heavy bug repros.** Project memory
  `feedback_dont_run_ram_heavy_repros.md` — fixpoint + targeted spec
  is the verification path, not full self-compile-with-profile-enabled.
- **Cache pollution across binaries.** `feedback_quartz_cache_pollution.md`
  — `rm -rf .quartz-cache` before running specs that exercise the new
  effect against the previous golden binary.
- **Two-pass fixpoint regression.** If Pass 1 ships and gen1 build
  fails (gen0 doesn't know `prof_phase` yet), the relaxation alone
  isn't enough — the OP NAMES need to be recognized as effect ops by
  the typechecker. Mirror Cache's recognition path at
  `mir_lower_expr_handlers.qz:1508`.

## Calibration note

The audit row claimed "~2-3 quartz-days" for A.6. Realistic sizing
based on Cache's actual day:
- **Phase 1 (mechanism + 1-op consumer = 1 commit-pair)**: ~3-4 hours
  real / 0.75 quartz-days. Cache shipped this in 2 commits.
- **Phase 2 (5 remaining ops)**: 1 quartz-day. Cache shipped this in
  3 commits.
- **Phase 3 (test handlers + spec)**: 0.5 quartz-day. Cache shipped
  this in 1 commit.
- **A.6-specific delta**: Profile has fewer ops than Cache (4 vs 6) and
  fewer call sites (~14 vs ~5 cache callsites — but cache had heavy
  pre-existing helpers; Profile collapses 14 sites to 14 calls). The
  flag fold-in (`--memory-stats` / `--progress` setters) is ~10 lines.
- **Total realistic**: 1.5-2 quartz-days. Audit row's 2-3 is correct
  upper bound.

## Bench-framework substrate (forward reference)

When C.8 ships, its default handler is approximately:

```quartz
def bench_default_handler(op_name: Int, argc: Int, argv: Int): Int
  var op = as_string(op_name)
  if op.eq("prof_span_begin")
    return time_mono_ns()
  end
  if op.eq("prof_span_end")
    var begin = load(argv, 0)
    var name = as_string(load(argv, 1))
    var elapsed = time_mono_ns() - begin
    bench_aggregate_record(name, elapsed)  # mean/median/p95/p99
    return elapsed
  end
  return 0
end
```

That handler swaps in for `profile_default_handler` via a
`with Profile { prof_span_begin: bench_default_handler, prof_span_end:
bench_default_handler } do -> { warmup × 100; measured × 1000 } end`
test wrapper. Variance reporting falls out of `bench_aggregate_record`'s
distribution math. CI can take JSON output by binding
`profile_set_ndjson(1)` + the ndjson handler.

This is **why Profile ships first**: C.8 is otherwise its own large
substrate-plus-aggregator project. Profile gives it the substrate for
free.
