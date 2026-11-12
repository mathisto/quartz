# Random Effect — Design Memo

> **Filed:** 2026-05-01 (start of A.8 session, immediately after A.6
> Profile effect closeout `81d164d1` + `5c56b8fe`).
> **Sequencing:** Phase A.8 of the post-audit roadmap. Promoted to #2
> priority after A.5b closed; #1 (A.2 Phase 2) gated on a separate RSS
> measurement methodology sprint. Substrate for Phase C.2 (crypto
> stdlib) and C.7 (property testing).
> **Recipe inheritance:** mirrors A.3 Cache + A.6 Profile pass-1/pass-2/
> pass-3/pass-4 shape. Cross-reference [`CACHE_EFFECT_PLAN.md`](CACHE_EFFECT_PLAN.md)
> and [`PROFILE_EFFECT_PLAN.md`](PROFILE_EFFECT_PLAN.md) for any plumbing
> detail not redocumented here.

## Motivation

The roadmap row claims "3 independent PRNG sources sharing no entropy."
Audit refines that count:

1. **`qz_rand_int` xoshiro256\*\*** at `codegen_runtime.qz:6697-6792`. Backs
   the `rand_seed` / `rand_range` / `rand_float` intrinsics emitted by
   `cg_intrinsic_misc.qz:561-573`. Hidden global PRNG state — every Quartz
   program that uses these intrinsics reads/writes the same module-level
   xoshiro state regardless of test isolation needs.

2. **`qz_crypto_rand_int`** at `codegen_runtime.qz:6817-6827`. Backs the
   `crypto_rand_int` builtin. Reads from `/dev/urandom` (hosted) or
   `getrandom(2)` (Linux) — different entropy source from xoshiro.

3. **work-stealing victim picker xorshift64** at `codegen_runtime.qz:4865`.
   Embedded in `__qz_sched_steal`'s LLVM IR, never exposed as a Quartz
   callable. **Stays put** — routing the scheduler's per-steal random
   pick through the effect-perform machinery would tank work-stealing
   throughput for zero observable benefit (the scheduler is internally
   deterministic enough; what users want to control is *user-program* RNG).

So the realistic surface is **2 user-facing PRNGs** that should share an
effect: xoshiro256\*\* (deterministic, seedable) and getrandom-backed
(security-grade, unseedable). The "3 sources" framing was inflated; the
audit-inflation pattern continues (sister to the A.1, A.2, A.3-Phase-2,
A.4 examples documented in `feedback_audit_count_inflation.md`).

The single-effect-two-implementations shape mirrors how Rust treats
`rand::thread_rng()` (deterministic but uninspected seed) vs
`rand::rngs::OsRng` (OS entropy) — same `Rng` trait, different impls.
Quartz has the same separation today as separate intrinsics; the
Random effect is the unification surface.

## Scope decisions

### Op shape — 4 ops covering deterministic + crypto

```quartz
effect Random
  ## Seed the deterministic PRNG. Resets state to a splitmix64-derived
  ## fill from `seed`. Test handlers may ignore.
  def rand_seed_op(seed: Int): Void

  ## Uniform i64 from the deterministic PRNG. Default forwards to the
  ## existing `qz_rand_int` runtime helper. Output is implementation-
  ## defined for non-deterministic handlers.
  def rand_int_op(): Int

  ## Uniform Int in [lo, hi). Default uses qz_rand_int with modulo
  ## reduction (the same reduction the `rand_range` intrinsic uses
  ## today). Test handlers may simulate edge cases (always-lo, always-
  ## hi-1, etc).
  def rand_range_op(lo: Int, hi: Int): Int

  ## Cryptographically-secure i64 from the OS RNG. Default forwards to
  ## `qz_crypto_rand_int`. Handlers that override should preserve the
  ## "no inspection / no seeding" contract — security boundary, not a
  ## test-mockable surface (use `rand_int_op` for that).
  def rand_crypto_op(): Int
end
```

**Why these four:**

- `rand_int_op` covers the raw uniform i64 use case (rare in user code,
  common in stdlib internals like `random_shuffle`).
- `rand_range_op` is the dominant call site shape — `std/fuzz/gen.qz`
  alone calls `rand_range` 22 times. Carrying it as a separate op keeps
  the modulo-reduction logic in one place; handlers don't have to
  rediscover the unbiased-rejection sampling.
- `rand_seed_op` lets test handlers no-op seed calls (deterministic
  capture replay) or honor them (controlled-replay handlers).
- `rand_crypto_op` is the security-distinct entropy source. Sharing the
  effect lets a single `with Random { ... }` override both PRNG kinds
  for hermetic testing while preserving the type-level distinction.

**Why no `rand_float_op`:** the `rand_float` intrinsic is a thin wrapper
over `rand_int` with an i64-to-f64 normalize. Effects don't carry F64
returns yet (handler ABI is `(op_name, argc, argv): Int`); routing
floats would need an as_f64-cast dance. Defer to the `std/random.qz`
public API as a Quartz-level wrapper that calls `rand_int_op` and
normalizes — same as the existing intrinsic shape, but the underlying
PRNG can be overridden via the effect.

**Why not block-scoped `with Random.deterministic do -> body end`:**
same answer as Profile — the handler ABI doesn't support block-scoped
syntax; bracketed seed/restore covers the same use case.

### Default handler — Shape A (inline-IR, always-forward)

This is the FileIo / Alloc shape, not the Cache / Profile / Intern shape.

The default handler unconditionally forwards to the existing runtime
helpers (`qz_rand_int`, `qz_rand_seed`, `qz_crypto_rand_int`). No
module-level state, no flag gate, no Quartz-function wrapper. ~30 lines
of inline LLVM IR at `__qz_default_random_handler`.

**Why inline-IR not Quartz-function:** the body is libc-equivalent —
just a switch on op name and a forward to the existing intrinsic
helpers. Wrapping it in a Quartz function would force every program
using `rand_int_op` to link the wrapper through `@random$random_default_handler`,
adding an indirection for zero benefit. Cache / Profile / Intern need
Quartz functions because their default bodies pull in non-trivial
helpers (build_cache, RSS reads, intern table); Random's default body
is `call i64 @qz_rand_int()` and return.

**Consequence:** **no `uses_random` flag** is needed. The default
handler installs unconditionally in `__qz_effect_install_defaults`,
just like Throws / Log / Async / FileIo / Alloc. Programs that never
write `with Random {...}` and never call any `rand_*_op` simply never
trigger the install path's effect-perform; the install itself is a
single `__qz_effect_handle_install` call (~5 instructions).

This is a **simpler recipe** than Cache / Profile. Phase 1's
"infrastructure" diff is correspondingly smaller.

### Plumbing — no MIR flag, no signature plumbing

Because the default is inline-IR with no link-cost concern:
- **No** `uses_random` field on `MirProgram`.
- **No** signature changes to `cg_emit_effect_runtime` /
  `cg_emit_effect_install_defaults_fn` / `cg_emit_effect_main_prelude`.
- **No** detection in `mir_lower_expr_handlers.qz`.

The only codegen plumbing is:
1. String globals (eff name + 4 op names, both linkonce + internal
   branches in `cg_emit_effect_runtime` — ~10 lines).
2. Inline-IR default handler in `cg_emit_effect_runtime` (~30 lines).
3. Unconditional install in `cg_emit_effect_install_defaults_fn`
   (~2 lines).
4. Blessed-relaxation OR chain in `typecheck_expr_handlers.qz:1664`
   (~1 line — add `or _c3_eff_name.eq("Random")`).

That's it. The two-pass fixpoint discipline still applies (Phase 1 ships
mechanism without consumer migration so gen0 builds before gen1 sees
the new ops), but Phase 1 is a single commit instead of the
mechanism+pass2 pair Cache / Profile used.

### Why three-pass fixpoint discipline still applies

Pass 1 ships declaration + relaxation + default handler + plumbing,
**no consumer migration in compiler source**. Compiler / stdlib source
still calls `rand_range` / `qz_rand_int` directly. Pass 2 migrates
exactly one consumer site to validate the effect dispatches end-to-end.
Pass 3 migrates the remaining sites. Pass 4 ships test handlers.

Without the split, gen0 (which doesn't know `rand_int_op`) would reject
Pass 2's call as an unbound op and self-compile fails. Same dance as
Cache (`e56200ac` Pass 1, `f67ac8ee` Pass 2) and Profile (`0c16b381`
Pass 1, `11da4797` Pass 2).

## Recipe — Pass 1 (mechanism, no consumer migration)

### File: `std/random.qz` — extend in place

Today's `std/random.qz` is 60 lines of helpers (`random_bool`,
`random_shuffle`, `random_choice`, `random_sample`). Add:

```quartz
import math

effect Random
  def rand_seed_op(seed: Int): Void
  def rand_int_op(): Int
  def rand_range_op(lo: Int, hi: Int): Int
  def rand_crypto_op(): Int
end

# Existing helpers below remain unchanged. They continue to call
# `rand_seed` / `rand_range` intrinsics directly — Pass 3 migrates them
# to the effect ops.
```

Keep helpers calling the intrinsics for now. Pass 3 migrates them.

### File: `self-hosted/backend/codegen_runtime.qz`

**String globals** — two-branch edits at the existing globals sections
(lines 533-543 / 577-584 patterns):

```llvm
@__qz_eff_name_random = linkonce_odr unnamed_addr constant [7 x i8] c"Random\00", align 1
@__qz_eff_op_rand_seed_op = linkonce_odr unnamed_addr constant [14 x i8] c"rand_seed_op\00", align 1
@__qz_eff_op_rand_int_op = linkonce_odr unnamed_addr constant [13 x i8] c"rand_int_op\00", align 1
@__qz_eff_op_rand_range_op = linkonce_odr unnamed_addr constant [15 x i8] c"rand_range_op\00", align 1
@__qz_eff_op_rand_crypto_op = linkonce_odr unnamed_addr constant [16 x i8] c"rand_crypto_op\00", align 1
```

(plus internal-linkage variants in the `else` branch).

Lengths: `Random\0` = 7, `rand_seed_op\0` = 13, `rand_int_op\0` = 12,
`rand_range_op\0` = 14, `rand_crypto_op\0` = 15. **Recheck on
implementation** — off-by-one is the most common review miss.

**Inline-IR default handler** at `cg_emit_effect_runtime` (after the
existing FileIo / Alloc default handlers, before the `cg_emit_effect_install_defaults_fn`
call at line 1433):

```llvm
define [linkonce_odr] i64 @__qz_default_random_handler(ptr %op, i64 %argc, ptr %argv) nounwind {
entry:
  %is_seed = call i1 @__qz_effect_cstr_eq(ptr %op, ptr @__qz_eff_op_rand_seed_op)
  br i1 %is_seed, label %do_seed, label %check_int
do_seed:
  %seed_slot = getelementptr inbounds i64, ptr %argv, i64 0
  %seed = load i64, ptr %seed_slot, align 8
  call void @qz_rand_seed(i64 %seed)
  ret i64 0
check_int:
  %is_int = call i1 @__qz_effect_cstr_eq(ptr %op, ptr @__qz_eff_op_rand_int_op)
  br i1 %is_int, label %do_int, label %check_range
do_int:
  %r_int = call i64 @qz_rand_int()
  ret i64 %r_int
check_range:
  %is_range = call i1 @__qz_effect_cstr_eq(ptr %op, ptr @__qz_eff_op_rand_range_op)
  br i1 %is_range, label %do_range, label %check_crypto
do_range:
  %lo_slot = getelementptr inbounds i64, ptr %argv, i64 0
  %hi_slot = getelementptr inbounds i64, ptr %argv, i64 1
  %lo = load i64, ptr %lo_slot, align 8
  %hi = load i64, ptr %hi_slot, align 8
  %span = sub i64 %hi, %lo
  %r_raw = call i64 @qz_rand_int()
  %r_abs = and i64 %r_raw, 9223372036854775807   ; mask sign bit
  %r_mod = srem i64 %r_abs, %span
  %r_out = add i64 %lo, %r_mod
  ret i64 %r_out
check_crypto:
  %is_crypto = call i1 @__qz_effect_cstr_eq(ptr %op, ptr @__qz_eff_op_rand_crypto_op)
  br i1 %is_crypto, label %do_crypto, label %do_stub
do_crypto:
  %r_cr = call i64 @qz_crypto_rand_int()
  ret i64 %r_cr
do_stub:
  ret i64 0
}
```

**Verify** the existing `qz_rand_int` / `qz_rand_seed` / `qz_crypto_rand_int`
emission paths haven't been gated behind a flag — if they have, lift
the gate to "always emit if Random effect is potentially live" (which
it always is post-Pass-1).

**Install** at `cg_emit_effect_install_defaults_fn` (after the
unconditional FileIo / Alloc installs at lines 1494-1499, before the
gated Intern install at 1505):

```quartz
codegen_util::cg_emit_line(out, "  %eff_random_ptr = ptrtoint ptr @__qz_default_random_handler to i64")
codegen_util::cg_emit_line(out, "  call void @__qz_effect_handle_install(ptr @__qz_eff_name_random, i64 %eff_random_ptr, i64 0, ptr null)")
```

**No** `uses_random` parameter; **no** signature plumbing.

### File: `self-hosted/middle/typecheck_expr_handlers.qz`

Add `Random` to the blessed-relaxation OR chain at line 1664:

```quartz
... or _c3_eff_name.eq("Profile") or _c3_eff_name.eq("Random")
```

### Verification

1. `./self-hosted/bin/quake guard` — fixpoint must hold. Function count
   bumps by 0 (no new Quartz functions emitted by Pass 1 — handler is
   inline IR).
2. `./self-hosted/bin/quartz examples/style_demo.qz | …` smoke.
3. Existing FileIo / Cache / Profile specs still green.
4. New `spec/qspec/random_effect_pass1_spec.qz` proves the effect
   declares + relaxation works (a `rand_range_op(0, 100)` call
   typechecks without `can Random` row, and at runtime returns a value
   in [0, 100)).

### Commit shape

Single commit `[a8/random] Phase 1: Random effect mechanism`.
Approximate diff:
- `std/random.qz`: ~10 lines (effect declaration only)
- `codegen_runtime.qz`: ~50 lines (string globals × 2 branches + inline-IR
  default handler + 2-line install)
- `typecheck_expr_handlers.qz`: ~1 line
- `spec/qspec/random_effect_pass1_spec.qz`: ~80 lines

Smaller than Cache (~150 lines Phase 1) and Profile (~280 lines Phase 1)
because no `uses_random` plumbing. The recipe-inheritance saving is
real: the third instance of an effect ships in a single mechanism
commit.

## Recipe — Pass 2 (single-consumer migration)

### File: `self-hosted/backend/mir_lower_expr_handlers.qz` (line 4025)

The single Vec.shuffle lowering site emits `mir_emit_intrinsic("rand_range", ...)`.
Migrate it to dispatch through the Random effect:

```quartz
# Before:
var j = ctx.mir_emit_intrinsic("rand_range", [zero_const, k_plus_1])

# After (pass 2):
var j = mir_lower::mir_lower_expr(ctx, s, ast::ast_make_call_path(
  storage, "rand_range_op", [zero_const_ast_node, k_plus_1_ast_node]))
```

**On reflection — this site is wrong for Pass 2.** It lowers an MIR
intrinsic emission, not a user-call. Migrating it would require
rebuilding AST handles to call back into the `tc_expr` → `mir_lower`
path from inside `mir_lower`, which is a layering inversion.

**Better Pass 2 candidate**: `std/fuzz/gen.qz` line 115's
`rand_range(0, env.local_vars.size)`. Migrate that single line to
`rand_range_op(0, env.local_vars.size)` and add `import * from std/random`
+ a `can Random` annotation on `_fz_pick_local_var` (or wrap callsites
in the blessed-relaxation chain — already wired).

If the gen.qz function is itself called from inside compile() through
the test harness (it isn't — gen.qz is a fuzz tool not loaded by the
self-host build), Pass 2 is even simpler. Verify by `grep -r "fuzz/gen"
self-hosted/`.

### Verification

1. `./self-hosted/bin/quake guard` — fixpoint stamp updates.
2. Smoke as above + `examples/fuzz_demo.qz` if present.
3. New `spec/qspec/random_effect_pass2_spec.qz` — installs a custom
   handler that returns a fixed value for `rand_range_op`, asserts the
   migrated callsite returns that value.

### Commit shape

Single commit `[a8/random] Phase 2: migrate first consumer to rand_range_op`.

## Recipe — Pass 3 (remaining sites + `std/random.qz` migration)

Remaining work after Pass 2 lands:

1. **Migrate the remaining `rand_range` calls in `std/fuzz/gen.qz`**
   (~21 sites). Each is a 1:1 substitution.
2. **Migrate `std/random.qz` helpers** (`random_bool`, `random_choice`,
   `random_shuffle`, `random_sample`) to call `rand_range_op` instead
   of `rand_range`. Net: 4 sites.
3. **Migrate `mir_lower_expr_handlers.qz:4025`** if a clean lowering
   path through the effect exists by Pass 3. If not, leave it
   intrinsic-direct and document why (it's a compiler-internal MIR
   emission, not a user-Quartz call).
4. **Migrate spec/qspec/fuzz_spec.qz `rand_seed(...)`** calls to
   `rand_seed_op(...)` for spec-level dogfood.
5. **Decision: retire the intrinsics?** No. The intrinsics
   (`rand_seed`, `rand_int`, `rand_range`, `rand_float`,
   `crypto_rand_int`) stay as the runtime symbols backing the default
   handler. Keep them as compiler-emitted runtime calls; the effect
   dispatches *through* them. This is exactly the FileIo shape — `read`
   /  `write` syscalls aren't retired; the effect *wraps* them.

Estimated diff: ~30 line changes across `std/random.qz` + `std/fuzz/gen.qz`
+ `spec/qspec/fuzz_spec.qz`.

## Recipe — Pass 4 (test handlers)

Mirror Cache's Phase 3 / Profile's Phase 4 shape — 3 factories in
`std/random.qz`:

1. **`random_seeded_handler`** — owns module-level seeded xoshiro state
   independent of the global `qz_rand_int` state. Reset via
   `random_seeded_reset(seed: Int)` for cross-test isolation. Used to
   produce deterministic reproducible streams without polluting global
   PRNG state.

2. **`random_constant_handler`** — returns a fixed value for every op
   regardless of args. Configure via `random_constant_set(v: Int)`. Used
   to simulate worst-case bias in algorithms that depend on PRNG
   uniformity (test that `random_shuffle` doesn't crash when the PRNG
   always returns 0, etc).

3. **`random_capture_handler`** — appends `(op, args)` tuples to a
   module-level `Vec<String>` log AND forwards to the default
   `qz_rand_int` etc. Read via `random_capture_log()`, reset via
   `random_capture_reset()`. Useful for asserting "the test exercised
   these PRNG-dependent code paths."

Spec coverage: 4 ops × 3 handlers = 12 tests at
`random_effect_handlers_spec.qz`.

## Hazard map

- **F64 / Int handler-ABI mismatch.** `rand_float` returns F64 but the
  handler ABI is `(op_name, argc, argv): Int`. Don't add a
  `rand_float_op` to the effect; route F64 through a Quartz wrapper that
  calls `rand_int_op` and normalizes. If a future ABI extension
  introduces F64 returns, revisit.

- **Modulo bias in `rand_range_op` default.** The simple `(rand_int %
  span) + lo` reduction is biased for spans not dividing 2^63. The
  existing `rand_range` intrinsic uses the same biased shape, so Pass 1
  matches behavior. **Filed as separate follow-up** — replace with
  rejection-sampling unbiased reduction (Lemire 2019, "Fast Random
  Integer Generation in an Interval") in a dedicated commit. Don't bundle
  with the effect plumbing.

- **Mangled-symbol guess for inline IR.** Random's default handler is
  inline IR (`@__qz_default_random_handler`), NOT a Quartz function
  (`@random$...`). No mangle worry; just verify the symbol name in
  `/tmp/main.ll` after the first build.

- **Reentrancy.** A user-installed handler may itself call `rand_int_op`
  (e.g., a tracing handler that forwards). The per-with-block
  install/uninstall discipline handles this — the next perform's scan
  starts from the install above the user's handler, finding the default.
  No special care needed.

- **Cross-thread PRNG state.** `qz_rand_int`'s xoshiro state is module-
  global, not TLS. Multi-threaded programs share PRNG state across
  worker threads (race on the state vector). This is a **pre-existing
  bug in the intrinsic**, surfaced more prominently by the effect (now
  every worker thread's `rand_int_op` install reads the same shared
  state). **Filed as separate follow-up** — make `qz_rand_state` TLS
  in `codegen_runtime.qz:6221`. Don't bundle with the effect plumbing.

- **Don't run RAM-heavy bug repros.** Project memory
  `feedback_dont_run_ram_heavy_repros.md` — fixpoint + targeted spec is
  the verification path. Random's spec doesn't allocate heavy state.

- **Cache pollution across binaries.** `feedback_quartz_cache_pollution.md`
  — `rm -rf .quartz-cache` before running specs that exercise the new
  effect against the previous golden binary.

- **arena reserved keyword.** `feedback_arena_reserved_keyword.md` —
  `arena` is silently miscompiled as a parameter name. Random's ops
  don't use it; flag if any future shape reaches for it.

- **Audit-inflation reality check.** Roadmap row claimed "3 PRNG
  sources." Audit shows 2 user-facing + 1 runtime-internal. Sixth
  audit-inflation instance this sprint (after A.1, A.2, A.3-Phase-2,
  A.4, A.6).

## Calibration note

The audit row claimed "~1-2 quartz-days" for A.8. Realistic sizing:

- **Phase 1 (mechanism)**: ~1.5-2 hours real / 0.5 quartz-day. Smaller
  than Cache / Profile Phase 1 because no `uses_random` plumbing. Single
  commit.
- **Phase 2 (single-consumer migration)**: ~30 min / 0.1 quartz-day. One
  callsite flip + spec.
- **Phase 3 (remaining sites)**: ~1 hour / 0.25 quartz-day. ~25
  callsite flips across `std/fuzz/gen.qz` + `std/random.qz` helpers.
- **Phase 4 (test handlers)**: ~1.5 hours / 0.5 quartz-day. Mirror
  Cache's Phase 3.
- **Total realistic**: 1-1.25 quartz-days. Audit row's 1-2 is correct
  upper bound; Random benefits from being the third effect on this
  recipe.

## Substrate consumers (forward reference)

- **Phase C.2 crypto stdlib** uses `rand_crypto_op` for nonce
  generation, key generation, and ECDH ephemeral private keys. The
  effect lets `std/crypto/aead.qz` document "I require a CSPRNG" via a
  `can Random` annotation on its public API; test code can substitute a
  controlled-stream handler for known-answer-test (KAT) verification of
  crypto primitives without touching `/dev/urandom`.

- **Phase C.7 property-based testing (`std/qspec/property.qz`)** uses
  `rand_int_op` / `rand_range_op` as the primitive generator backbone.
  The effect lets `for_all` shrink failures by re-running with a
  re-seeded handler — same generator stream up to the point of failure,
  then divergence to explore neighboring inputs. The capture handler is
  the basis for the "saved counterexample" feature.

This is **why Random ships now**: both downstream phases (C.2 + C.7)
can ship without re-architecting their PRNG surface, and the recipe
inheritance from Cache + Profile makes Random the cheapest effect of
the three to ship.
