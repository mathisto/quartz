# FLOAT_TO_STRING_SILENT_BITS

> **CLOSED-STALE 2026-07-07** — re-reproduced fixed on current binary; see docs/sagas/r24-groundwork-inert-holes-2026-07-07-research/ws2-triage.md (fix `52c5d18d`: Dragon4 formatter in `std/fmt/float.qz`, removed from `intrinsic_registry.qz`).

**Filed:** 2026-06-02 (audit-driven hole-hunt, after the QZ0102/QZ0405/QZ0103 sweep)
**Severity:** High — silent miscompile of a core feature. No diagnostic.
**Status:** ✅ FIXED `52c5d18d` (2026-06-02). Dragon4 shortest-round-trip
formatter shipped in `std/fmt/float.qz`, wired via `std/prelude.qz`; `to_str(F64)`
and `#{float}` now print the decimal value. See
[`docs/design/FLOAT_TO_STRING.md`](../design/FLOAT_TO_STRING.md).

## Symptom

`to_str(F64)` and `#{float}` string interpolation print the raw IEEE-754 bit
pattern instead of the decimal value:

```quartz
var f: F64 = 3.5
puts(to_str(f))        # prints 4615063718147915776  (= 0x400C000000000000)
puts("v = #{f}")       # prints v = 4615063718147915776
```

Any program that prints a non-integer float gets garbage. No error at parse,
typecheck, or codegen.

## Scope (CORRECTED 2026-06-02 after ground-truthing)

The original framing ("no working float→string path anywhere") was **wrong** —
written before discovering the `f64_to_str` intrinsic. Reproduced on the live
compiler (`/tmp/ftest.qz`), there are in fact **two distinct bugs**:

**Bug A — silent miscompile (raw bits).** Only `to_str(F64)` and `#{f}`
interpolation print the IEEE-754 bit pattern. These route through the *generic*
`to_str` and the NODE_INTERP_STRING desugar, neither of which has a float arm.

| Surface | Output | Status |
|---|---|---|
| `to_str(f)` | `4615063718147915776` | **BROKEN** (raw bits) |
| `#{f}` interp | `4615063718147915776` | **BROKEN** (raw bits) |
| `f.to_s()` | `3.5` | works (→ `f64_to_str`) |
| `"x " + f` | `3.5` | works (typecheck coerces → `f64_to_str`, `typecheck_walk.qz:1322`) |
| `f64_to_str(f)` | `3.5` | works |

So a working path **does** exist — the `f64_to_str` intrinsic
(`intrinsic_registry.qz:485`, codegen `cg_intrinsic_string.qz:424`). It is the
single chokepoint everything-that-works already routes through (`F64$to_s`,
string-concat coercion, `std/json.qz`, `std/toml/stringify.qz`,
`std/crypto/dudect.qz`). Bug A is just two routing sites that *don't* reach it.

**Bug B — lossy, NOT round-trip-correct.** `f64_to_str`'s codegen emits
`sprintf(buf, "%g", x)` (`@.fmt.f64 = "%g"`, `codegen_runtime.qz:10378`). `%g`
defaults to **6 significant figures**, so it is *not* shortest-round-trip:

```
f64_to_str(3.141592653589793) → "3.14159"        (lost 10 digits)
f64_to_str(0.1 + 0.2)         → "0.3"             (should round-trip to 0.30000000000000004)
str_to_f64(f64_to_str(pi)) != pi                  (round-trip FAILS)
```

This silently corrupts **every** working float-print path above, including JSON
and TOML serialization of computed floats. Higher-impact than Bug A, and
invisible because no spec asserts round-trip on a non-round number.

**Bug B is also a freestanding gap:** `sprintf` is libc; the unikernel has none.

- `float_to_str` (distinct name) appears only as a dangling alloc-record name
  (`mir_lower_async_registry.qz:952`), no implementation — a red herring.
- Known-but-untracked: the TO_STR_INT_HEURISTIC work (done 2026-05-03) noted
  "Float interp residual filed-as-followup (no `sb_append_float` intrinsic
  exists)" — but it was never filed as an open item, so it sat silent.

## Why the test suite missed it

Same signature as the other hole-hunt finds (braced struct, leading-operator
fold, import-* collision): the stdlib and specs happen never to print a float,
so nothing exercised the path.

## Fix (architecture corrected 2026-06-02)

One pure-Quartz shortest-round-trip formatter, made the **single chokepoint**,
fixing both bugs at once:

1. Implement the formatter in pure Quartz (no libc → freestanding-safe) in
   `std/fmt/float.qz`. Substrate confirmed: `widening_mul_hi`/`widening_mul_lo`
   give source-callable 64×64→128 (used already in `std/core/crypto/ed25519.qz`);
   an F64 is stored as its i64 bit pattern (`cg_intrinsic_core.qz:37`) so decode
   is integer bit-ops; `str_to_f64` is the round-trip oracle.
2. **Replace** the `f64_to_str` implementation with it (kills Bug B + the libc
   dependency). `f64_to_str` stays the public name everyone already calls, so
   `to_s`, string-concat coercion, JSON, TOML all inherit the correct path.
3. **Link** it everywhere via `import * from std/fmt/float` in `std/prelude.qz`
   — same mechanism the prelude already uses for `std/gen` so the compiler can
   inject `Stream$next` references. A compiler-injected float-format call then
   always resolves.
4. **Route** `to_str(f)` and the NODE_INTERP_STRING float arm to it (fixes
   Bug A), mirroring the `str_from_int` / `sb_append_int` hooks at
   `mir_lower.qz:3748`.

Algorithm choice and phasing in `docs/design/FLOAT_TO_STRING.md`. NB: the tables
for the shortest-decimal family (Ryū/Dragonbox) cannot be safely hand-
transcribed (~1236 magic constants = exactly this silent-miscompile class), so a
small bignum is required regardless — which reshapes the v1 algorithm tradeoff.
