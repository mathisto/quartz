# Float → String (world-class, pure-Quartz)

**Status:** Design — implementation in progress. Filed 2026-06-02; premise
corrected + algorithm re-chosen (Dragon4 for v1) same day after ground-truthing
the live compiler.
**Closes:** the float-formatting silent miscompile. See the bug:
[`docs/bugs/FLOAT_TO_STRING_SILENT_BITS.md`](../bugs/FLOAT_TO_STRING_SILENT_BITS.md).
**Constraint:** must work **freestanding** (the unikernel has no libc), so this
is pure Quartz — no `sprintf`/`snprintf`/`strtod` FFI.

## What's actually broken (corrected 2026-06-02)

The first draft of this design assumed "no working float→string path exists."
That was wrong. Reproducing on the live compiler showed **two** bugs:

- **Bug A — miscompile:** only `to_str(f)` and `#{f}` print raw IEEE-754 bits
  (`3.5` → `4615063718147915776`). They route through the generic `to_str` /
  the NODE_INTERP_STRING desugar, which have no float arm.
- **Bug B — lossy:** the `f64_to_str` intrinsic (`cg_intrinsic_string.qz:424`)
  emits `sprintf(buf, "%g", x)` — 6 sig figs, **not** shortest-round-trip.
  `pi`→`3.14159`, `0.1+0.2`→`0.3`; `str_to_f64(f64_to_str(x)) != x`. This
  silently corrupts `f.to_s()`, string-concat coercion, and JSON/TOML
  serialization. Also a freestanding gap (`sprintf` is libc).

`f64_to_str` is the **single chokepoint** every working float-print path already
routes through (`F64$to_s`, the `String + Float` coercion at
`typecheck_walk.qz:1322/1334`, `std/json.qz`, `std/toml/stringify.qz`,
`std/crypto/dudect.qz`). The fix is: make that chokepoint correct, link it
everywhere, and route the two stragglers (`to_str(f)`, interp) into it.

## Algorithm: Dragon4 for v1, Dragonbox/Schubfach for speed later

Surveyed the field (Steele & White 1990; Burger & Dybvig 1996; Ryū/Adams 2018;
Schubfach/Giulietti; Dragonbox/Jeon; Lemire 2026; arXiv:2603.06581). The
shortest-round-trip family splits into:

- **Dragon4** (Steele & White "free-format" / Burger & Dybvig) — exact
  rational arithmetic with a **bignum**. Produces the shortest decimal that
  round-trips. The canonical correctness reference every faster algorithm is
  validated against. Slower (bignum ops per conversion), but simplest to make
  *provably* correct, and uses **zero magic constants**.
- **Ryū / Schubfach / Dragonbox** — fast, fixed-width integer arithmetic, but
  driven by large precomputed 128-bit power-of-5 split tables (~1236 constants
  for Ryū's full table).

The first draft chose Ryū because it advertised "no bignum, fixed-size ops."
But its tables **cannot be safely hand-transcribed** — 1236 magic constants is
exactly the silent-miscompile class this whole effort exists to kill, and we
have no way to verify a transcription short of the very round-trip oracle we'd
be building. The only transcription-safe way to get those tables is to
**compute them at init via a bignum** — which means a bignum is required *no
matter which algorithm we pick*. That erases Ryū's sole v1 advantage.

So for v1 the rational choice is **Dragon4**: if we're building a bignum anyway,
use the algorithm that is bignum-native, constant-free, and provably correct.
Speed is explicitly *not* the v1 bar (correctness + shortest + round-trip is).
The fast-but-table-driven cores are the documented follow-up — see "Future"
below and ROADMAP Tier 5 #31. (Decision: AskUserQuestion 2026-06-02.)

References:
- Steele & White, "How to Print Floating-Point Numbers Accurately", PLDI 1990.
- Burger & Dybvig, "Printing Floating-Point Numbers Quickly and Accurately",
  PLDI 1996 (the Dragon4 formulation followed here).
- Ulf Adams, "Ryū", PLDI 2018 — https://dl.acm.org/doi/10.1145/3192366.3192369
- Daniel Lemire, "Converting floats to strings quickly", 2026.
- "Converting Binary FP to Shortest Decimal Strings: An Experimental Review",
  arXiv:2603.06581.

## Dragon4 sketch (the formulation we implement)

Decode `f` (sign, IEEE mantissa `m`, exponent `e`). Represent the value and the
half-ulp boundaries as exact rationals over a shared denominator, scaled to
integers held in a bignum:

- For `e >= 0`: `R = m·2^(e+1)`, `S = 2`, `M+ = 2^e`, `M- = 2^e`.
- For `e < 0`: `R = m·2`, `S = 2^(1-e)`, `M+ = 1`, `M- = 1`.
- Boundary asymmetry: when `m` is the smallest normal mantissa (`m == 2^52`,
  i.e. a power of two and not the smallest exponent), the lower gap is half the
  upper — scale `R,S,M+` by 2 and set `M- = 1` relative to that. (Burger-Dybvig
  "unequal gaps" case.)
- Scale by the estimated decimal exponent `k ≈ ceil(log10(value))` so the first
  generated digit is in `[1,9]`: multiply `S` (or `R,M+,M-`) by `10^|k|`.
- Generate-loop: repeatedly `d = (R·10) / S; R = (R·10) mod S`, tracking
  `M+ ·10`, `M- ·10`. Stop when `R < M-` (low) or `R + M+ > S` (high); the two
  termination tests are what guarantee *shortest*. Final-digit rounding picks
  between `d` and `d+1` by which boundary was crossed (with round-to-even on a
  tie). Emit digits + decimal exponent.

`acceptBounds` (round-to-even on exact midpoints) follows from `(m & 1) == 0`.
This is the standard Burger-Dybvig algorithm; correctness is gated by the
oracle below, not by trusting the sketch.

## Bignum substrate (pure Quartz)

A minimal unsigned bignum (`Vec<Int>` of 64-bit limbs, little-endian) supporting
exactly what Dragon4 needs: `mul_small` (×10, ×2, ×5), `shl_bits` (·2^n),
`add`, `cmp`, and `divmod_small`-style `(R·10)/S` via a `mul`+`cmp`+`sub` long
division step, plus `pow10`/`pow2` builders. 64×64→128 partial products use the
**source-callable** `widening_mul_hi`/`widening_mul_lo` intrinsics (already used
in `std/core/crypto/ed25519.qz:302+`). Pure integer ops → freestanding-safe.

## Surface + formatting policy

The public name stays **`f64_to_str(f: F64): String`** (the existing chokepoint
— reusing it means `to_s`, coercion, JSON, TOML all inherit the fix for free).
Implementation moves to pure Quartz in `std/fmt/float.qz`.

Output policy (match Rust `{}` / Go `strconv.FormatFloat(f,'g',-1,64)` —
shortest, decimal unless the exponent is extreme):
- `0.0` → `"0"`, `-0.0` → `"-0"`.
- inf/-inf → `"inf"`/`"-inf"`; nan → `"nan"`.
- Integer-valued in range → `"42"` (no forced `.0`; matches Go `%g`, Rust `{}`).
- Otherwise shortest digits placed with a decimal point; switch to scientific
  (`d.ddde±XX`) when the decimal exponent is < -4 or ≥ 21 (the `%g` threshold).

> **Behavior change to flag:** today `f64_to_str` gives `%g` output (`3.14159`,
> `0.3`). After this change it gives shortest-round-trip (`3.141592653589793`,
> `0.30000000000000004`). JSON/TOML snapshots that bake in the old lossy strings
> will need updating — that's a *correctness* improvement, not a regression.

## Plumbing (single chokepoint)

1. `std/fmt/float.qz`: pure-Quartz `f64_to_str` (Dragon4) + the bignum it needs.
2. `std/prelude.qz`: add `import * from std/fmt/float` so a compiler-injected
   call always links — the same trick the prelude already uses for `std/gen`
   (`Stream$next`). Watch the import cycle (prelude ⇄ float); the resolver's
   loaded-set de-dups it the same way it does for `std/gen`.
3. **Remove** the `f64_to_str` intrinsic so the name resolves to the stdlib
   function everywhere (D7 — delete the sprintf path, don't shim it):
   - `backend/intrinsic_registry.qz:485` `_r("f64_to_str", …)`
   - `backend/cg_intrinsic_string.qz:424` the sprintf codegen block
   - `middle/typecheck_builtins.qz:171` `tc_register_builtin("f64_to_str", …)`
   - the `@.fmt.f64` constant (`codegen_runtime.qz:10378`) if now unused
   - `mir_is_string_call` (`mir_lower.qz:946`) keeps listing `f64_to_str` — a
     normal stdlib String-returning call still wants String classification.
4. `mir_lower.qz`: extend the `to_str(...)` rewrite + the NODE_INTERP_STRING
   desugar (the `mir_unwrap_to_str_for_int` sites at `:3748`) with a float arm
   via a new `mir_unwrap_to_str_for_float` + `mir_is_float_expr` (`:1075`,
   already exists), emitting a normal call to `f64_to_str`.

## Implementation phases (TDD — invariant 5)

- **Phase 0 — bignum + scaffold, standalone.** `std/fmt/float.qz` with the
  bignum ops and `f64_to_str` decode + `0`/`-0`/inf/nan + integer-valued fast
  path. Verify with a **standalone `def main()` smoke program** (compile →
  `llc` → `clang` → run), *not* qspec — the round-trip oracle is the gate and
  the full suite can't be run from Claude Code. Do **not** wire into the
  compiler yet; the old `f64_to_str` intrinsic stays live so the build is green.
- **Phase 1 — Dragon4 core.** The scale setup + generate-loop. Oracle over a
  large structured + random sample (small ints, fractions, subnormals,
  near-powers-of-two, 1e±300, `Math.PI`, random bit patterns):
  (a) **round-trip:** `str_to_f64(f64_to_str(x)) == x` bit-for-bit;
  (b) **minimality:** rounding the output to one fewer significant digit and
  re-parsing must **not** reproduce `x` (proves *shortest*, which round-trip
  alone does not).
- **Phase 2 — formatting + wire-in.** Fixed-vs-scientific selection; then
  prelude import, remove the intrinsic, add the `to_str`/interp float arms.
  Update JSON/TOML snapshots to the round-trip strings. `quake guard` +
  fixpoint + smoke (`style_demo`, `brainfuck`) + relevant qspec files.
- **Phase 3 — freestanding check.** Compile a float-printing program to
  `x86_64-unknown-none-elf`; confirm no `@sprintf`/libc references survive
  (Dragon4 is pure integer ops → none should).

## Future: faster algorithm (Ryū → Dragonbox / Schubfach)

Dragon4 is the correct, constant-free v1. Once it's locked behind the round-trip
+ minimality oracle, the digit-generation core can be swapped — first to **Ryū**
(its tables now *computed* at init by the Phase-0 bignum, so still no
transcription), and ultimately to **Dragonbox** (Jeon) or **Schubfach**
(Giulietti), the current speed leaders. All produce the same shortest
round-trip output, so the swap sits behind the same `f64_to_str` API and the
same oracle — pure perf, zero behavior change. Pull-in trigger: a profile shows
float formatting hot (e.g. JSON serialization of large numeric payloads).
Tracked in ROADMAP Tier 5 #31.

Dragonbox — https://github.com/jk-jeon/dragonbox ; Schubfach —
https://github.com/c4f7fcce9cb06515/Schubfach ; Ryū — https://github.com/ulfjack/ryu

## Risks

- **Dragon4 generate-loop edge cases.** The two termination tests + final-digit
  rounding (including the unequal-gaps power-of-two case and round-to-even on
  exact midpoints) are the bug surface. Mitigate: gate on the round-trip +
  minimality oracle over an exhaustive sample *before* wiring in.
- **Bignum correctness.** `divmod`/long-division step is the trickiest bignum
  op. Unit-test the bignum ops directly in the standalone harness before
  Dragon4 sits on top.
- **Prelude import cycle** (prelude ⇄ std/fmt/float). Mirror exactly how
  `std/gen` is handled; verify a clean-cache compile of `std/fmt/float.qz`
  itself doesn't deadlock the resolver.
- **`-0.0` / signed zero** flows through the sign bit; covered by special-case
  tests.
</content>
</invoke>
