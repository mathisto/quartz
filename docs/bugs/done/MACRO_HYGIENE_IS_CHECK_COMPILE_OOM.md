# `is Variant(bind)` on a user-defined enum hangs the compiler (infinite loop / unbounded memory)

**Filed:** 2026-06-10 (discovered during N3.1 step-4b increment #4 verification)
**Severity:** High — a minimal, legal program hangs the compiler indefinitely; no diagnostic, no progress. Under a memory cap it OOM-kills (rc=137); under a wall-clock cap it times out (rc=124).
**Status:** ✅ FIXED (verified 2026-07-07). The minimal repro now compiles cleanly and quickly (`rc=0`, ~4.4K lines of IR; no hang, no OOM). The `is Variant(bind)` payload-binding path on a user-defined enum no longer loops. Retired to `docs/bugs/done/`.
**NOT caused by:** N3.1 step-4 (per-struct nominal ids) or increment #4 (`fea93dce`, macro_expand AstStorage annotations). Proven by golden A/B — see below.
**Sister bug:** `docs/bugs/done/IS_PREDICATE_CROSS_ENUM_TAG_COLLISION.md` (same `is`-predicate machinery, different manifestation — that one is a silent false-true; this one is a compile hang). Also related to the `is_none_non_option_segfault` memory feedback.

## Minimal repro

```quartz
enum Box
  Wrapped(Int),
  Empty
end

def main(): Int
  var b = Box.Wrapped(42)
  if b is Wrapped(fresh)   # payload-binding `is` on a USER enum
    return fresh + 1
  end
  return 0
end
```

Compile (correct user-program invocation — clean std path only):

```bash
./self-hosted/bin/quartz --no-cache -I std /tmp/box.qz
# hangs forever — no stdout, no stderr, no diagnostic
# timeout 40 → rc=124; no memory cap → grows until OOM-killed (rc=137)
```

The variant names are irrelevant: the same hang occurs with `enum Opt { Some(Int), None }` + `if opt is Some(x)` (the `macro_hygiene_spec` shape, which deliberately reuses the built-in `Some`/`None` names). It is **not** the cross-enum name collision — `Box.Wrapped` hangs identically.

## What does NOT hang (scoping)

- `is Some(payload)` against the **built-in `Option`** compiles fine — this is the path `$unwrap`/`builtin_macros_spec` exercises, which is why that spec passes 25/25.
- (Not yet isolated: predicate-only `if b is Wrapped` with no payload binding; and `match` on the same user enum. Worth checking which of {user-enum, payload-binding, both} is the precise trigger.)

## How it surfaces in the suite

`spec/qspec/macro_hygiene_spec.qz` test *"is-check bound name doesn't collide with caller's binding"* (`mh_is_check_src`) expands a macro to `if unquote(x) is Some(payload)` over `enum Opt { Some(Int), None }`. The qspec subprocess harness (`std/qspec/subprocess.qz`) compiles the snippet with `--no-cache -I <std>` under a per-compile timeout, so the hang is reported as:

```
✗ is-check bound name doesn't collide with caller's binding
  Failed to compile/run: compilation failed:
10 tests, 9 passed, 1 failed
```

The other 73 macro tests (expansion-chain, user-macros, builtin-macros, stress, fragment) pass. So the real macro-hygiene suite is **9/10**, not 10/10.

**Reconciliation note (important for whoever picks this up):** memory records `full qspec 837/837` at N3.1 step-3 (`cd165fe1`) and `832/837` at step-4a-2. This is **consistent** with the bug being pre-existing: the failing `is-check` test was almost certainly among the handful lumped into "recovered contention flakes" without per-spec verification. A single-spec run (`FILE=spec/qspec/macro_hygiene_spec.qz quake qspec_file`) reproduces the failure deterministically — it is not a flake.

## Pre-existing — golden A/B and history bisect

The snippet hangs identically across every archived binary:

| binary | result |
|---|---|
| `quartz-pre-n3-golden` (before ALL N3.1) | rc=124 hang |
| `quartz-pre-n3.1-step4-golden` (before audit/4a) | rc=124 hang |
| `quartz-pre-n3.1-step4a-golden` | rc=124 hang |
| `quartz-pre-n3.1-4b-golden` | rc=124 hang |
| `quartz-pre-n3.1-4b-incr4-golden` (HEAD before incr #4) | rc=124 hang |
| HEAD `fea93dce` (after incr #4) | rc=124 hang |

→ the hang predates N3.1 entirely; the N3.1 type-representation work and increment #4 are exonerated. (The earlier rc=137 OOM was the same runaway with no `timeout` wrapper — it just hit the memory cap before a wall-clock cap.)

## Next steps (for a dedicated session)

1. Determine which pass loops — compile under lldb and interrupt (`process interrupt`) once it's spinning; `bt` will name the pass. Candidates: resolver (is-check bound-name resolution), typecheck (is-check narrowing / niche-Option detection), or MIR lowering of `NodeIsCheck` over a user enum.
2. Narrow the trigger: payload-binding vs predicate-only; user enum vs Option; does `match b { Wrapped(x) => ... }` also hang (isolates `is` from general variant binding)?
3. Once a fix lands, the `macro_hygiene_spec` is-check test should go green — it is the ready-made regression gate.

## A/B methodology caveat (cost me time here)

- The shell is **zsh**: `$VAR` unquoted does **not** word-split. Passing include paths via a variable (`quartz $INC file.qz`) sends the whole string as one bad option → `error: unknown option` → CLI help text on stdout + rc=1 in 0.00s, which *looks* like a fast deterministic failure but is an arg-parse artifact. Always pass `-I` args **explicitly inline** for A/B compiles.
- Compile **user** programs with `-I std` only. The `-I self-hosted/frontend -I middle -I backend -I shared -I tools` set is for compiling `quartz.qz` *itself* (and for the `QZ_N3_AUDIT` meter run); it does not change this bug's outcome (hangs either way) but is the wrong invocation for a user snippet.
