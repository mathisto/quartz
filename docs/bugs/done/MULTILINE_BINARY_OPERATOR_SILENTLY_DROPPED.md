# MULTILINE_BINARY_OPERATOR_SILENTLY_DROPPED

**Filed:** 2026-05-21
**Discovered during:** NET.3a (SHA-3 implementation)
**Severity:** Silent miscompile — code compiles, runs, produces wrong output. No diagnostic.
**Status:** ✅ RESOLVED 2026-06-02

> **RESOLVED.** The silent half was already closed by intervening parser work
> (a leading operator became a generic `QZ0101: Expected expression` rather
> than being silently discarded). This change finishes the job on both ends:
>
> 1. **Precise diagnostic (`QZ0103`).** A binary operator at expression-start
>    position (the leading-operator-continuation mistake) now produces a
>    teaching error — `binary operator '^' cannot start an expression — put the
>    operator at the END of the previous line …` — instead of the generic
>    "Expected expression". `_ps_is_misplaced_binary_op` in
>    `self-hosted/frontend/parser.qz` gates it (infix-only operators; `-`/`&`
>    excluded — they have prefix forms and are consumed earlier). Fires only on
>    the already-error fall-through of `ps_parse_primary`, so no valid program
>    is affected. `--explain QZ0103` added.
> 2. **Canonical multi-line idiom = TRAILING operator** (already worked; now
>    documented). `a ^` ⏎ `b ^` ⏎ `c` — the newline after a binary operator is
>    a continuation. Documented under "Multi-line expressions" in
>    `docs/QUARTZ_REFERENCE.md`.
>
> So the fix shipped is **Path A** from below (reject + diagnose), upgraded
> from a bare error into a fix-it that names the working idiom. **Path B**
> (implicit continuation when a line *starts* with an operator) is NOT shipped:
> outside parens it would re-introduce silent behavior (`foo()` ⏎ `< 3` would
> silently become a discarded comparison — the very class this bug is about),
> and the safe Python-style "newlines insignificant inside `( )`" form is a
> sprawling change across ~10 precedence levels with a fully-working
> alternative (trailing operator). Filed as a tracked enhancement:
> `PAREN_NEWLINE_INSIGNIFICANCE.md`.
>
> **Verification.** Leading-operator repro → QZ0103 (was silent/then generic);
> trailing-operator fold computes correctly; fixpoint gen1==gen2 (2600 fns);
> smokes green; 2 new arms in `spec/qspec/parser_hang_recovery_spec.qz` (11/11);
> no regression across error_codes/parser_stress/arithmetic/operator_overload/
> bitwise/pattern_qualified_variant. `quake guard` pending (run externally).

## Repro

```quartz
def chain(): Int
  var x = 1
  var y = x ^ 2
        ^ 3
        ^ 4
  return y
end

def main(): Int
  puts(to_str(chain()))   # prints "3" instead of the expected "4" (1^2^3^4)
  return 0
end
```

The parser treats the source as:
```quartz
  var y = x ^ 2    # y = 3
  ^ 3              # parsed as a SEPARATE expression — silently discarded
  ^ 4              # ditto
```

No parse error, no warning. The expression `^ 3` (binary `^` with no LHS) ought to be a syntax error, but the parser accepts it as a valid expression statement somehow (likely by treating `^` as an unary prefix or by recovery-eating tokens until newline).

## How it bit NET.3a

The SHA-3 θ step naturally wants to be written as a 5-way XOR fold:

```quartz
var c_val = _get_lane(state, x, 0)
            ^ _get_lane(state, x, 1)
            ^ _get_lane(state, x, 2)
            ^ _get_lane(state, x, 3)
            ^ _get_lane(state, x, 4)
```

The compiler accepted this. The runtime computed `c_val = _get_lane(state, x, 0)` — discarding the other four XOR terms. SHA-3 still produced *some* digest (the bug was deterministic), so the streaming-vs-one-shot equivalence test passed; only the KAT vectors caught it. Diagnosis took ~30 minutes of "this *must* be a rho-rotation bug" rabbit holes before I noticed the multi-line expression.

The fix is to force everything onto one line:
```quartz
var c_val = _get_lane(state, x, 0) ^ _get_lane(state, x, 1) ^ _get_lane(state, x, 2) ^ _get_lane(state, x, 3) ^ _get_lane(state, x, 4)
```

## Root cause (hypothesis)

Two possibilities the parser may be doing:
1. **Statement-terminator on newline + tolerant expression statement.** The expression statement allows any prefix-callable expression; a leading `^` might be matching some expression production that consumes the next token (e.g., `^ _get_lane(...)` is parsed as some prefix-op application that's later discarded).
2. **Implicit-let inference on RHS-only lines.** Unlikely but worth checking.

Either way the symptom is: `^` at the start of a line is silently accepted as a separate statement.

## Fix shape (sized: 0.2–0.5 quartz-days)

Two acceptable fixes:

**A. Disallow binary-only operators at statement start.** Lexer/parser rejects `^`, `&`, `|`, `&&`, `||`, `+`, `-`, `*`, `/`, `%`, `<<`, `>>`, `==`, `!=`, `<`, `>`, `<=`, `>=` at the position where a new statement begins. Diagnostic: `expected expression, found infix operator '^'`. Mirrors what Rust and Swift do.

**B. Implicit line continuation when next line starts with binary operator.** If the lexer sees a newline and the next non-whitespace token is a binary operator, treat the newline as whitespace. This lets the multi-line idiom Just Work. Mirrors what Python does (inside parens) and what some Haskell layout rules do.

Fix B is the more ergonomic — it matches what every other language with whitespace-sensitive syntax does, and the SHA-3 θ formulation is genuinely more readable as a vertical 5-line fold. But A is the smaller, safer change.

**Decision: ship A first** (the silent miscompile is the urgent thing to close), then file B as a separate ergonomics follow-up if the maintainer wants it.

## Validation gate

Regression spec in `spec/qspec/parser_spec.qz` (or wherever parser-error specs live):
- A test case identical to the repro above must produce a parse error containing the substring `expected expression`.
- The existing single-line form `var y = x ^ 2 ^ 3 ^ 4` must continue to compile.

Plus a "did this regress?" smoke: re-run the SHA-3 KATs (`quake sha3:smoke`) with the multi-line form *restored* in `std/core/crypto/sha3.qz`; the build must now fail at parse time. Then re-apply the single-line fix.

## Adjacent considerations

- Same trap likely exists for `&&`, `||`, `==`, etc. — any binary operator the parser would otherwise accept as a unary prefix or recovery-consume. Audit alongside the fix.
- The codebase convention (per `sha512.qz`, `ed25519.qz`) is single-line packed expressions. The fix should not break any existing files; a `grep -rE '^\s+[\^&|+\-*/%<>=!]' std/ self-hosted/` audit will surface any current uses.
- Worth re-running the full `quake qspec` suite after the fix; my hypothesis is that nothing else in the tree triggers this because the codebase has already evolved around the limitation.

## Filed by

NET.3a session, 2026-05-21. SHA-3 implementation; the 5-way XOR fold in θ is the natural recurrence. Cost: ~30 minutes of debugging in the wrong direction (rho/pi/iota indexing) before noticing the multi-line shape. Without filing, the next person writing a Keccak / Poly1305 / multi-byte CRC will hit the same trap.
