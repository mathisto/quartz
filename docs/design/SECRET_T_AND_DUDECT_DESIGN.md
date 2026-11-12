# NET.4 — `Secret<T>` + dudect + (stretch) ct-verif Design

**Status**: Active, branch `net-4-secret-t` off `net-3-mlkem` head (commit `e6bcb3de`).
**Track**: NET.4 in `docs/ROADMAP.md`.
**Predecessors**: NET.1 (`std/core/crypto/*` substrate), NET.2 (Ed25519 keys), NET.3 (ML-KEM dk seed).
**Successor**: NET.5 (TLS 1.3 — session keys benefit from `Secret<T>`).

## Goal

Three orthogonal layers of constant-time discipline, sized so each independently
ships value:

1. **Source-level taint typing** — `Secret<T>` opaque newtype with typecheck-time
   rejection of branches, array-indexing, comparison, and bit-shift right-operand
   on `Secret`-derived values. Forces the use of `subtle::ct_*` helpers.
2. **Runtime statistical CT validation** — `dudect_check` harness (Reparaz/
   Balasch/Verbauwhede 2017). Welch's t-test over execution-time samples of a
   function called with two classes of secret inputs. Failure threshold `|t| ≥ 5`.
3. **(stretch) Middle-end taint pass** — `@[ct]`-marked functions get a MIR
   pass that rejects branches / variable-time ops on `Secret`-derived values
   transitively, not just at the type-system surface. Catches leaks that
   `secret_unwrap` would otherwise hide.

Layers 1+2 together = what Go's `crypto/...`, Rust's `subtle` + `secrecy` crate,
and BoringSSL via `CT_POISON` deliver. Layer 3 = Jasmin / FaCT territory — what
the research languages do that no production language currently ships.

## Prior art surveyed (D2)

| System | What they do | What we adopt |
|---|---|---|
| **Go `crypto/internal/secretdata`** (2024+) | Filippo Valsorda's `Bytes`/`Scalar` opaque types in ML-KEM and edwards25519 implementations; relies on convention, no compiler enforcement | The opaque-newtype + capability-by-audit-greppability stance |
| **Rust `secrecy` crate** (Tony Arcieri) | `SecretBox<T>` wrapper, `expose_secret()` callsites are greppable, `Drop` zeroizes | The `secret_unwrap` callsite-as-audit-boundary discipline |
| **BoringSSL `CT_POISON`** | MSan-based dynamic taint — instruments at runtime to detect branches on poisoned bytes | Rejected: requires MSan and Linux; runtime cost; our typecheck-time approach catches the same class without instrumentation |
| **HACL\* / F\* proofs** | Full formal CT proofs against an idealized timing model | Rejected: requires F\*; out of scope for a self-hosted language |
| **Jasmin** (Formosa Crypto, 2025.02 release) | Flow-sensitive CT checker, removed `#flex/#strict` annotations — every variable is tracked | Layer 3 mirrors this stance: inside `@[ct]`, everything is flow-sensitively tracked |
| **FaCT** (CT-by-construction DSL, ported to ct-wasm) | Function-level CT contracts; rejects non-CT source | The `@[ct]` annotation shape borrows the contract idea |
| **dudect** (Reparaz et al., DATE 2017) | 300 LoC statistical t-test, no source instrumentation, runs on target hardware | Layer 2 ports the t-test verbatim. The reference (oreparaz/dudect) is plain C; Quartz port follows shape |
| **arxiv 2402.13506** ("Towards Efficient Verification of CT Crypto Implementations", 2024) | IFDS-based lightweight taint analysis is the practical algorithm for compiler-side CT verification | Layer 3 uses IFDS shape — forward dataflow, lattice = `{public, secret}` per SSA value |
| **Serberus** (arxiv 2309.05174, USENIX Sec 2024) | Speculative-CT extension covering Spectre v1/v4 | Out of scope for NET.4 v1; filed forward |
| **Reference impls** of `Secret<T>`-style discipline in Bouffant / Vouvoir / Pailleron | None known | Quartz Layer 1 is genuinely novel for a non-research production language with full compiler support |

The combination of Layer 1 + Layer 2 + Layer 3 (the `@[ct]` stretch) is
**more than Go/Rust/Zig deliver** at the language level, and is approximately
what Jasmin delivers without the research-language ergonomics tax. The Layer 3
"only-inside-marked-functions" scoping mirrors what shipped in Jasmin 2025.02.

## Layer 1 — `Secret<T>` opaque newtype

### Surface

```quartz
import * from std/core/crypto/secret

# Wrap and unwrap — opaque from the type system's POV.
def secret_wrap<T>(t: T): Secret<T>
def secret_unwrap<T>(s: Secret<T>): T

# The only allowed comparison.
def secret_ct_eq<T>(a: Secret<T>, b: Secret<T>, len: Int): Int

# Secure zeroize that takes ownership.
def secret_zeroize<T>(s: Secret<T>, len: Int): Void
```

`Secret<T>` is a generic opaque newtype. Its uses today (across the existing
seven crypto primitives + ML-KEM + Ed25519):

| Type | Wraps |
|---|---|
| `Secret<Bytes32>` | curve25519 + ed25519 private scalars; HKDF PRK; WireGuard ck/T |
| `Secret<Bytes64>` | ML-KEM-768 64-byte seed-as-key dk |
| `Secret<Bytes16>` | Poly1305 one-time keys (transient) |
| `Secret<Int>` | bit-by-bit scrutinees in Curve25519 cswap (theoretical; arguable) |

### Capability boundary

`secret_wrap` and `secret_unwrap` are **callable from anywhere**. The capability
gate is the audit-greppability convention, not the language — `git grep
secret_unwrap` enumerates every place secret material crosses back into
clear-text. This matches `secrecy::expose_secret()`, `secretdata.Bytes.Bytes()`,
and `OPENSSL_secure_buf`'s practice.

### Rejections (where the compiler stops bad code)

Inside the typechecker, predicate `tc_type_is_secret_derived(tc, t)` walks
through ptype generics looking for the `Secret` newtype base. If it returns
true, four sites raise an error:

1. **`if`/`while`/`match`-scrutinee/`select`-arm condition** — at
   `tc_check_condition` (typecheck_helpers.qz:357).
2. **Array index** — at `tc_expr_index` (typecheck_expr_handlers.qz:411).
3. **Comparison operators** (`==`, `!=`, `<`, `>`, `<=`, `>=`) — at
   `tc_check_binary` (typecheck_walk.qz:1349).
4. **Bit-shift right-operand** (`<<`, `>>` — variable-shift on Intel and AMD
   is data-dependent below `BSR/BSF` granularity) — at `tc_check_binary`.

Each error message points at `docs/QUARTZ_REFERENCE.md#secret-t` and suggests
the canonical `subtle::ct_*` replacement.

### Propagation semantics

The existing newtype machinery already gives us:
- Cross-newtype assignment is a type error (since v5.25.0). Passing
  `Secret<Int>` where `Int` is expected is rejected.
- Operators between a newtype and its underlying behave as the underlying.

This is fine for the rejection layer. We are NOT trying to make `Secret<Int> +
Secret<Int> = Secret<Int>` (arithmetic preserves taint) work in Layer 1 — the
rejection layer catches the class of bug we care about (`if secret_byte != 0`),
and arithmetic on secret values is exactly what crypto code does. The Layer 3
stretch handles arithmetic-flow taint via MIR pass; Layer 1 doesn't.

### NET.4.0 compiler prereq

`Secret<T>` requires working generic newtypes. The parser accepts `newtype
Foo<T> = T` (parser.qz:7178) but the typechecker raises QZ0200 "Unknown type
'Secret<Int>'" at use sites. NET.4.0 is the compiler change that fixes this:

- Generic-newtype ptype interning via the existing `tc_make_ptype` machinery
  with the newtype base id (range 1000+).
- `tc_parse_type` branch that handles `Newtype<...>` at use sites and emits
  a ptype id.
- Type-error reporting threaded through.

Sized 1-2 quartz-days. Becomes a free compiler-feature win for any future
generic newtype use (`Tagged<T, Tag>`, `Validated<T>`, etc.).

## Layer 2 — `dudect_check` harness

Direct port of the Reparaz 2017 reference (oreparaz/dudect, 300 LoC C).

### API

```quartz
# Welch's t-test over `samples` runs each of class A and class B.
# Returns the t-value (positive or negative).
def dudect_t_value(
  fn: Fn(Bytes): Void,
  class_a_gen: Fn(Int): Bytes,
  class_b_gen: Fn(Int): Bytes,
  samples: Int,
): Float

# Asserts |t| < 5 (Reparaz et al. § 4). Test fails with the t-value if not.
def dudect_assert_ct(
  name: String,
  fn: Fn(Bytes): Void,
  class_a_gen: Fn(Int): Bytes,
  class_b_gen: Fn(Int): Bytes,
  samples: Int,
): Void
```

### Implementation outline

- Sample timing via `time_monotonic_ns` (already in stdlib). If resolution
  proves insufficient on x86_64, swap for an inline `rdtsc` intrinsic.
- Welch's t-test formula:
  - `t = (μ_a − μ_b) / sqrt(σ²_a/n_a + σ²_b/n_b)`
- Standard Knuth/Welford online variance for streaming μ and σ²: avoid
  pre-allocating an N-element timing array, which itself becomes a memory
  workload that confounds measurement.
- **Cropping**: Reparaz drops the top 5% of samples per class to defang OS
  preemption outliers. We follow.

### Threshold

- `|t| < 5` → CT (Reparaz § 4 "the threshold is set to 5 based on practical
  experience").
- `|t| ≥ 5` → leak signal. The asserts fail.
- A canary test (`spec/qz/dudect_canary.qz`) compares a deliberately-leaky
  early-exit `ct_eq_bytes` against the proper version — the leaky one must
  produce `|t| ≥ 100` (Reparaz § 4: "values of 100 or more constitute
  overwhelming evidence").

## Layer 3 — `@[ct]` MIR pass (stretch)

Optional. Sized after layers 1+2 are in.

```quartz
@[ct]
def f51_cswap(swap: Int, a: F51, b: F51): Void
  ...
```

Inside an `@[ct]`-annotated function, the typechecker emits a "ct-marked"
flag on the function. A new pass `self-hosted/middle/ct_taint.qz` runs after
MIR lowering. Algorithm:

- **Lattice**: `public ⊑ secret`.
- **Forward dataflow** over MIR SSA values.
- **Sources**: every parameter typed `Secret<T>`; every value produced by
  `secret_wrap` or by an op consuming a `secret` value.
- **Sinks**: `MIR_INDEX` source operand; condition operand of `MIR_BR` (when
  the SSA pre-codegen lowers branches); `MIR_BINARY` comparison ops; shift
  amount operand of `MIR_SHL/SHR`.
- **`secret_unwrap` is not a sanitizer**. Inside `@[ct]`, the result of
  `secret_unwrap` remains tainted; the value is only declassified at the
  function boundary. Outside `@[ct]`, the typecheck-time rejection (Layer 1)
  is the only check.

The pass emits compile-time errors with the MIR-position file:line of the
sink. Marker function `@[ct_declassify]` (or just calling out of the `@[ct]`
function) declassifies — necessary for e.g. ML-KEM's `H(ek)` step where the
secret-derived `H` is genuinely public.

Reference: arxiv 2402.13506 § 3 IFDS construction. Sized ~1-2 quartz-days.

## Phasing

| Phase | What | Estimate (quartz-time) |
|---|---|---|
| 4.0 | Generic newtype compiler support | 1-2 qd |
| 4.1 | `Secret<T>` typecheck rejection at 4 sites | 1 qd |
| 4.2 | `std/core/crypto/secret.qz` API | 0.2 qd |
| 4.3 | Annotate existing crypto stdlib + smokes still green | 0.5-1 qd |
| 4.4 | `std/crypto/dudect.qz` harness | 0.5 qd |
| 4.5 | dudect tests for canonical primitives + canary | 0.3 qd |
| 4.6 | (stretch) `@[ct]` MIR pass | 1-2 qd |
| **TOTAL v1 (4.0–4.5)** | | **3.5–4.7 qd** |
| **TOTAL v2 (incl. 4.6)** | | **4.5–6.7 qd** |

ROADMAP estimate was 2-3 quartz-weeks → 10-15 qd traditional → 2.5-4 qd
calibrated. Layer 1 is heavier than the original ROADMAP framing assumed
(because the 4.0 generic-newtype compiler gap was discovered during this
session's design pass, not before), so the calibrated estimate sits at the
high end of that range.

## Open design questions

1. **Should arithmetic preserve taint at Layer 1?** I.e. should
   `Secret<Int> + Int` yield `Secret<Int>`? Current plan: no, that's a Layer 3
   property. Layer 1 catches `if secret == 0`, which is the bulk of the value.
   Decision is reversible.

2. **Should `secret_unwrap` be capability-gated or audit-only?** Current plan:
   audit-only (matches Go/Rust). Reasoning: language-level capability gating
   adds complexity (`pub(crypto)` visibility or similar) without practical
   security; the `git grep` audit boundary is what serious crypto stdlibs
   actually use.

3. **Bit-shift rejection on the right operand — is this overreach?** Variable
   shifts on x86 are 1-cycle but their amount drives a μop-fusion path that
   has been shown leaky in some studies. ARM mov-shifted-reg has similar
   issues. Most CT crypto code uses constant shifts. Decision: reject; the
   crypto stdlib already uses constant shifts everywhere, and the rare
   genuine-variable-shift case can `secret_unwrap` explicitly.

4. **Where does the rejection error point users?** Current plan: point at a
   new section `## Secret<T> and constant-time crypto` in QUARTZ_REFERENCE.md
   that lists the four prohibited positions + the `subtle::ct_*` replacement
   helpers.

## Non-goals (NET.4 v1)

- **No `@[constant_time]` function attribute that the LLVM optimizer is
  guaranteed to preserve.** The crypto memo explains why — LLVM doesn't
  preserve CT through optimization passes, and a guarantee we can't enforce
  is a half-truth. Layer 3's `@[ct]` is a source-level rejection contract,
  not a backend-preservation guarantee.
- **No Spectre-style speculative-CT extension.** Serberus (arxiv 2309.05174)
  is the canonical reference; filed forward.
- **No automated migration of existing crypto code via taint inference.**
  Layer 1's retroactive annotations in NET.4.3 are explicit hand-work.

## Found-and-filed during 4.0 design pass

- **NET.4.0 itself** — generic newtype ptype interning gap; parser accepts
  but typechecker rejects. Was not on the ROADMAP before this session.

## Decision log

- **2026-05-21** — NET.4 reshaped from 3-phase (Secret<T> + dudect + ct-verif)
  to 7-phase (4.0–4.6) after compiler-prereq discovery. ROADMAP estimate
  unchanged (2-3 quartz-weeks); calibrated estimate 3.5-6.7 qd matches the
  ÷4 ratio. NET.4.6 (the MIR pass) is stretch and may ship in NET.4 v2.

- **2026-05-21 (later)** — Second reshape after deeper probing. The 4.0 fix
  (generic newtype use-site resolution, 15 LOC) landed but is necessary-
  not-sufficient: Quartz's value-level existential erasure means
  `Secret<Int>` flows as `Int` through let-bindings, arg-passing, return,
  branches, and comparisons. Even `Vec<UserId>` accepting a `Vec<Int>` works.
  The v5.25.0-claimed strictness is partial (cross-newtype-vs-newtype only).
  Plan now factors out a **STRICT_NEWTYPES** compiler epic
  (`docs/design/STRICT_NEWTYPES_DESIGN.md`) as a prereq — opt-in `@[strict]`
  newtype attribute that rejects implicit conversion at all positions.
  Sized 1.5–1.8 qd. After STRICT, NET.4.1 (Secret<T> annotation pass) and
  NET.4.2 (dudect harness) ship cleanly. NET.4 v1 phasing becomes:
  STRICT.0–5 → NET.4.1 (annotation pass + secret.qz) → NET.4.2 (dudect) →
  NET.4.6 (stretch). Total ~3-3.5 qd from session start.

- **2026-05-22 (NET.4.2 ship)** — dudect harness landed (`std/crypto/dudect.qz`,
  ~430 LoC including doc). Two design calls diverged from the §"Layer 2"
  sketch above; both deliberate and worth recording.

  1. **102-test fanout, not the simplified "top 5% crop" the original
     outline cited.** Close reading of `oreparaz/dudect`'s `dudect.h`
     shows the reference algorithm runs 1 uncropped + 100 exponentially-
     spaced cropped (`1 − 0.5^(i/10)` for `i ∈ 1..100`, concentrating
     thresholds near p99.9) + 1 second-order test on `(x − μ_uncropped)²`
     in parallel and reports `max |t|` across all 102. The exponential
     schedule covers tail densities that any single-cutoff misses; the
     second-order test catches variance leaks that mean-difference
     misses. The "top 5% crop" wording in the original outline was a
     simplification — we ported the canonical algorithm. Decision was
     reversible if the canonical fanout turned out too costly; at
     N=30K the full 102-test sweep runs in ~5 ms — costless.

  2. **Stats-only API (caller drives the measurement loop), not the
     `dudect_t_value(fn, gen_a, gen_b, samples)` callback API the
     outline named.** Three drivers: (a) avoids cross-module `Fn` value
     passing, which is currently miscompiled in some shapes (HB-DOG.12);
     (b) more flexible for callers — input shape is whatever the test
     needs; (c) matches Reparaz's separation (input prep is caller's,
     harness does t-tests). The public surface is `dudect_new` /
     `dudect_push(ctx, ns, class)` / `dudect_compute_max_t(ctx)` /
     `dudect_assert_ct(name, ctx, threshold)` plus the inverse
     `dudect_assert_leak` for the canary, plus a small `dudect_rng_*`
     xorshift64 PRNG for deterministic input generation. Threshold
     constants are `dudect_t_threshold_leak()` (5.0) and
     `dudect_t_threshold_overwhelming()` (100.0), wrapped as zero-arg
     defs because module-level `var X: F64 = ...` doesn't propagate
     across the qzmod import boundary (QZ0403 at the call site —
     surfaced during this session's probe).

  **Time source** — shipped on `time_mono_ns()` (`clock_gettime(CLOCK_
  MONOTONIC)`, ~20-50 ns syscall overhead). The §"Time source" trigger
  for filing an `@rdtsc` intrinsic was NOT hit: real-primitive smoke
  on 32-byte comparisons sits at the noise floor (canary at len=32
  produced max|t|≈14, in the "likely leak" band) but real-primitive
  workloads (ML-KEM 1184-byte comparison, batched 256/64/128-call
  windows on smaller targets) push the per-window cost well clear of
  syscall noise. The canary uses len=4096 deliberately to give the
  leak a fair shot at the ≥100 "overwhelming" threshold; max|t|=6354
  on commit-time verification. If a future real-primitive test ever
  needs finer resolution, the 30-LoC `@rdtsc` intrinsic is a clean
  v2 add per the "Adding a New Builtin" recipe in CLAUDE.md.

  **What shipped:** `std/crypto/dudect.qz` (~430 LoC), `spec/qz/
  dudect_canary_smoke.qz` (canary — 2/2 green: leaky |t|=6354.39
  detected ≥100, honest ct_eq_bytes |t|=1.07 < 5), `spec/qz/
  dudect_smoke.qz` (real-primitive — 4/4 green: ct_eq_bytes at 1184B
  + 16B×256, ct_select_int×128, curve25519 _f51_cswap×64; all max|t|
  ≤ 2.9), Quakefile tasks `dudect:canary` + `dudect:smoke`. Total
  wall ~1.2 s for canary + smoke combined. Stdlib-only diff; zero
  self-hosted/*.qz touched. `quake guard` PASS (2544 fns unchanged).

  **What's NOT shipped (filed forward):**
   - Streaming windowed compute (Reparaz re-feeds fresh batches into
     the running t-tests "forever"). Our v1 batches at the caller-
     defined N and computes once at the end — sufficient for canary
     + regression-gate use, not for the "leave-it-running" deployment
     pattern. Sized ~0.3 qd if a consumer ever needs it.
   - `rdtsc` intrinsic — see "Time source" above. Sized ~30 LoC.
   - CT rewrite of Ed25519 `_sc_reduce_64` itself (Barrett or
     12×21-bit ref10 reduction). The dudect coverage now in
     `dudect:audit` is the EMPIRICAL gate; the rewrite is the
     long-term fix. Sized ~0.5-1 qd.
   - Layer 3 (`@[ct]` MIR pass) — still stretch. Layers 1+2 together
     give the language-level claim; Layer 3 is research-language
     territory and the calibration of cost vs. value is still open.

- **2026-05-22 (NET.4.2 extensions — dudect coverage broadens).**
  Two filed-forward dudect targets shipped same session as the harness.

  1. **ML-KEM `mlkem768_decaps` valid-vs-tampered** lands in
     `spec/qz/dudect_smoke.qz` alongside the existing 4 primitives.
     Two classes: (0) original ciphertext (K-true branch), (1)
     ciphertext with one bit flipped at offset CT_BYTES/2 (FO
     implicit-reject K̄ branch). N=2000 (each decaps is ~2 ms; total
     wall ~6 s for this leg). Result: max|t|=3.17 at threshold 5 —
     PASS. Empirically confirms the FO implicit-reject path's
     `subtle::ct_eq_bytes(c, c_reencap)` step is constant-time,
     closing the gate the MAL-BIND-K-CT (Cremers/Schmieg) analysis
     pointed at.

  2. **Ed25519 `_sc_reduce_64` known-leak audit** lands in NEW
     `spec/qz/dudect_audit_smoke.qz` (separate file because it uses
     the INVERSE assertion — `dudect_assert_leak` — and conflating
     "audit" with "guard" semantics in one runner muddies the gate).
     New Quakefile task `dudect:audit` wraps it. Two classes:
     in_64 = all 0x00 vs all 0xFF, driving the
     `_bn_cmp(x, l64, 64) >= 0` borrow branch through opposite
     populations. N=10000. Result: max|t|=1052.4 (≥ 5 floor, ≥ 100
     "overwhelming" Reparaz gate) — PASS. The audit pattern is
     deliberately closed-world: any new primitive added here lands
     with a citation to a design memo / commit explaining the
     ship-with-known-leak tradeoff. Today's list = 1 entry. If a
     primitive on the list ever produces max|t| < 5, EITHER CT got
     accidentally fixed (uplift to `dudect_smoke.qz`) OR the harness
     regressed.

  **Two design invariants encoded by the split**:
   - `dudect:smoke` PASSING = "every entry stays CT" (assertion
     direction: |t| < 5). Regression gate for future stdlib refactors.
   - `dudect:audit` PASSING = "every entry stays detectably leaky"
     (assertion direction: |t| ≥ 5). The audit invariant. Both gates
     together close the "is the harness sound + are the primitives
     classified correctly?" question.

  **Not yet shipped (still filed forward)**:
   - CT rewrite of `_sc_reduce_64` itself — Barrett or ref10
     12×21-bit. Moves the entry from `dudect:audit` to `dudect:smoke`.
     ~0.5-1 qd.

- **2026-05-22 (NET.4 Layer 3 — `@ct` MIR taint pass shipped).**
  IFDS-style forward dataflow over MIR SSA values lands in new file
  `self-hosted/middle/ct_taint.qz` (~470 LoC); wired between
  `mir_lower` and `mir_optimize` in `quartz.qz`. Surface: `@ct`
  attribute on `def` declarations (parser + `ast_func_set_ct` /
  `ast_func_is_ct` + `mir_func_set_ct` / `mir_func_is_ct` side-table).
  Four diagnostic codes:
  - `QZ0700` — branch on Secret-derived condition (`TERM_BRANCH` /
    `TERM_SWITCH` term_data tainted).
  - `QZ0701` — array index by Secret-derived value
    (`MIR_INDEX` / `MIR_INDEX_RAW` operand2;
    `MIR_INDEX_STORE` / `MIR_INDEX_STORE_RAW` args[0]).
  - `QZ0702` — comparison with a Secret-derived operand
    (`MIR_BINARY` with op ∈ [OP_EQ, OP_GE], either operand).
  - `QZ0703` — variable shift by Secret-derived amount
    (`MIR_BINARY` with op ∈ {OP_SHL, OP_SHR}, RHS).

  **Three design calls diverged from the §"Layer 3" outline; all
  recorded here**:

  1. **Spelling is bare `@ct`, not `@[ct]`.** The memo's
     bracketed shorthand was a design-doc convention; existing
     Quartz attributes (`@strict`, `@naked`, `@noinline`, etc.)
     are bare. The parser slots `@ct` into the existing attribute
     loop alongside them. Cosmetic.

  2. **Sources: only `Secret<T>`-typed params (strict reading of
     the memo bullet), NOT every parameter unconditionally.** The
     memo's example `@[ct] def f51_cswap(swap: Int, a: F51, b: F51)`
     suggested a Jasmin-style "every param tracked" stance, but
     adopting it would taint legitimately-public params like
     `len: Int` in `ct_eq_bytes(a, b, len)` — `while i < len`
     would emit a false-positive QZ0702. Strict reading shipped;
     the Jasmin variant is filed forward as a v2 mode.

  3. **`secret_unwrap` is NOT a sanitizer inside `@ct`** — matches
     the memo's "boundary-only declassification" wording. Implemented
     by treating ALL MIR_CALL/MIR_INTRINSIC with any tainted argument
     as producing a tainted return, with no exception for the
     `secret_unwrap` callee name. Tested empirically by the
     `bad_branch` spec — `var n = secret_unwrap(s); if (n & 1) == 1`
     emits QZ0700 as designed.

  **Algorithm:**
   - Per-function pass (no-op when `mir_func_is_ct(func) == 0`).
   - Seed: every param whose `param_type_names[i]` starts with
     `"Secret<"` is added to `taint_vars`.
   - Fixpoint: iterate over every block, propagate via 8 MIR opcode
     handlers (`MIR_LOAD_VAR`, `MIR_STORE_VAR`, `MIR_CALL` /
     `MIR_INTRINSIC` / `MIR_CALL_INDIRECT`, `MIR_BINARY`,
     `MIR_UNARY`, `MIR_INDEX` / `MIR_INDEX_RAW`, `MIR_PHI`,
     `MIR_FIELD_ACCESS` / `MIR_LOAD_OFFSET` / `MIR_LOAD`,
     `MIR_SELECT`). `secret_wrap` callees independently introduce
     taint (output tainted regardless of arg taint). Converges in
     a small number of iterations for non-pathological loops.
   - Report: single linear pass after fixpoint. Each sink reported
     exactly once at its source location via `diag::diag_emit`.
     Driver bails if `diag_error_count() > 0` after the pass.

  **Validation:** new `spec/qspec/ct_taint_spec.qz` ships 10 tests
  (3 parser positive/negative + 3 positive @ct paths + 4 sink
  rejections) — all green. `strict_newtype_spec.qz` 25/25 still
  green (no Layer 1 regression). guard PASS, fixpoint clean,
  2564 fns (up 20 from baseline 2544).

  **Limitations of v1 (documented in QUARTZ_REFERENCE.md):**
   - SSA-level taint only. Byte-level taint through `memcpy` /
     pointer writes is NOT tracked. Functions whose secret data
     flows through fresh `malloc` + `memcpy` (e.g.
     `x25519_scalarmult`'s scratch buffer) are not validated
     end-to-end by Layer 3 — `dudect:smoke` remains the empirical
     gate for those.
   - `Secret<T>`-typed-params-only seeding (decision #2 above).
     For helpers like `ct_eq_byte` / `ct_select_int` whose API
     uses loose `Int` parameters, `@ct` would be decorative —
     they're not annotated in this commit. Either widen the seed
     to "all params if @ct" (Jasmin mode), or migrate helper
     signatures to `Secret<Int>` (caller refactor) before annotation.

  **Filed forward:**
   - Jasmin-style "all params in @ct are secret" mode — needs
     a sub-attribute (e.g. `@ct(strict)`) to opt in, since the
     default behaviour change would break helpers with public
     `len` / counter params. ~0.5 qd if scoped to additive opt-in.
   - Memory taint tracking via alias analysis or shadow-memory
     taint table. Reference arxiv 2402.13506 §4 (forward-flow over
     pointer ranges). Sized 2-3 qd.
   - Apply `@ct` to high-value primitives once helper signatures
     migrate to `Secret<T>` — `_f51_cswap`, `ct_eq_bytes`,
     `ct_select_int`, `mlkem768_decaps` FO reject path. ~1 qd
     contingent on the signature migration.

- **2026-05-22 (CT rewrite of `_sc_reduce_64` — last NET.4
  filed-forward closes).** TweetNaCl-style byte-limb `modL` port
  replaces the original shift-and-subtract long-division.
  `std/core/crypto/ed25519.qz` diff: −90 LoC dead `_bn_*` helpers
  (`_bn_sub`, `_bn_shr1`, `_bn_shl` — only consumer was the old
  reduce) + ~80 LoC new `_sc_reduce_64`. Net stdlib delta ≈ −10 LoC.

  **Algorithm:** TweetNaCl `modL` (Bernstein/van Gastel/Schwabe,
  public domain). 64 i64 limbs (one per input byte), three passes:
   1. Fold x[63..32] back into x[0..31] using
      `x[j] += carry − 16·x[i]·L[j−(i−32)]` over a 20-wide
      window with byte-level carry propagation.
   2. Subtract `(x[31] >> 4)·L` byte-by-byte (partial reduction).
   3. Final canonical subtract via `carry·L` (multiplication keeps
      the conditional subtract data-flow-independent).
  Then a byte-level carry chain packs the low 32 i64 limbs to the
  output bytes. All loop bounds are public constants; no branch
  inside the function depends on input bytes.

  **Why TweetNaCl `modL` over ref10 12×21-bit:**
   - Cleaner per-LoC: byte-level limbs avoid the cross-byte bit
     slicing that ref10 needs for 21-bit limbs.
   - Same CT guarantees (loop bounds public, no conditional sub).
   - Vetted by the cryptography community for over a decade,
     same as ref10 — both ship in production stacks.
   - Quartz already has `_read_u64_le` / `_write_u64_le` bit-pattern
     helpers that work for signed `Int` (two's-complement); no
     new primitives needed.
  ref10's 21-bit windowing wins on raw throughput when SIMD-able,
  but Quartz codegen is scalar and the byte-limb version matches
  scalar perf in benchmarks.

  **Validation gates closed:**
   - `quake ed25519:smoke` — 29/29 (RFC 8032 §7.1 KAT TEST 1/2/3/
     SHA(abc), pubkey-derive + sign + verify-self + verify-rfc +
     tamper-msg + tamper-sig + non-canonical-S rejection).
   - `quake dudect:smoke` — promoted entry
     `ed25519 _sc_reduce_64`: max|t| = 0.75 at N=10000, threshold 5.
     Was max|t| ≈ 1052 under the shift-and-subtract version (per the
     prior `dudect:audit` run). Three orders of magnitude below the
     leak floor.
   - `quake guard` — fixpoint clean, 2564 fns (delta from baseline
     is zero — the rewrite is a wash on function count).
   - All eight other crypto smokes (`crypto`, `sha3`, `mlkem`,
     `mlkem:acvp`, `hybrid`, `wg`, `dudect:canary`, plus rule-2
     `style_demo` + `brainfuck`) re-verified green.
   - `ct_taint_spec` 10/10 + `strict_newtype_spec` 25/25 — Layer 3
     and STRICT_NEWTYPES unregressed.

  **Retired infrastructure:** `spec/qz/dudect_audit_smoke.qz` and
  the `dudect:audit` Quakefile task were deleted in the same
  commit. The audit list is now empty — the harness's
  `dudect_assert_leak` inverse-assertion is preserved (still used
  by `dudect:canary`'s leaky-early-exit canary), but no shipped
  primitive currently lands in the "known-leak audit" category.
  The pattern can be re-instantiated from this commit if a future
  primitive ships with an intentional CT defect. Per Quartz D7
  ("Delete dead code outright"), zero-entry scaffolding is removed
  rather than kept as cargo.

  **All NET.4 filed-forward items now closed or rolled into the
  v2 backlog.** What remains (`@ct(strict)` Jasmin-mode, memory-
  taint via alias analysis, applying `@ct` to canonical CT
  helpers after signature migration) is genuinely Layer 3 v2 /
  Layer 4 work, not NET.4 scope.

## References

- Reparaz, Balasch, Verbauwhede 2017. *Dude, is my code constant time?* DATE 2017. https://eprint.iacr.org/2016/1123
- Sun, Ji, Liu, et al. 2024. *Towards Efficient Verification of CT Cryptographic Implementations.* https://arxiv.org/abs/2402.13506
- Formosa Crypto. *Jasmin 2025.02.0 release notes.* https://formosa-crypto.org/news/
- Valsorda. *Let's All Agree to Use Seeds as ML-KEM Keys.* https://words.filippo.io/seeds-as-mlkem-keys/
- Arcieri. *secrecy crate.* https://crates.io/crates/secrecy
- BoringSSL. *Constant-time discipline via CT_POISON.* (in-tree comments)
- Quartz `docs/design/CRYPTO_STDLIB_DESIGN.md` § "Constant-time discipline"
- Quartz `docs/design/ED25519_DESIGN.md` § "Non-goals (NET.2 v1)" — files NET.4
