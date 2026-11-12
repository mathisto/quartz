# Error Handling Unification (B.9)

**Status**: Design — implementation staged across follow-up sessions.
**Scope**: Collapse Quartz's three error mechanisms into two by unifying
`panic(msg)` with the `Throws` effect.

## The current state

Quartz today has **three** error-handling mechanisms with overlapping
semantics:

| Mechanism | Surface | Runtime | Recovery |
|-----------|---------|---------|----------|
| `Result<T, E>` | enum return value | none — pure value | pattern match |
| `panic(msg)` | intrinsic call | inline IR: stderr + per-thread jmpbuf check + `longjmp` or `exit(1)` | `panic_caught(fn)` (per-thread jmpbuf install) |
| `Throws` effect | `throw(msg)` op | `__qz_effect_perform("Throws", "throw", ...)` → handler chain → default writes stderr + `exit(66)` | `with Throws { throw: h } do -> body end` |

Two of these — `panic` and `Throws` — are doing **the same thing** through
parallel machinery. Both unwind the stack. Both can be caught. Both have
default handlers that print the message and exit. The split exists because
Rust separates them (panic = bug, Result = expected error, no third). Quartz
isn't Rust; we have effects, and `Throws` already covers everything `panic`
covers — plus more (composable handlers, structured catch via `with`,
spawn-time inheritance via E.1.c.b snapshot).

`panic_caught` is then a third API surface that exists *only* because panic
isn't an effect — once panic *is* an effect (or routes through one),
`panic_caught(fn)` collapses to `with Throws { throw: rec } do -> fn() end`.

## What we're shipping

Two error-handling mechanisms, with a clear decision tree:

| Mechanism | Use when | Mental model |
|-----------|----------|--------------|
| `Result<T, E>` | The caller probably has a meaningful local response (parse error, file-not-found, validation failure). | **Value-level error.** The error is part of the function's interface. |
| `throw(msg)` (catchable via `with Throws`) | Exceptional condition; recovery (if any) is far up the stack. Subsumes `panic`. | **Control-flow-level error.** The error is part of the function's *unwinding* contract. |

`panic(msg)` becomes thin sugar for `throw("panic: " + msg)` — same runtime
mechanism, distinguished only by the prefix the default handler emits and by
caller intent (panic = "this is a bug"; throw = "this is an exception"). Both
travel through `Throws`. Both are catchable via `with Throws`.

## Decision tree (commit to docs)

When writing a function that can fail, ask in order:

1. **Will most callers want to handle this locally?** → `Result<T, E>`. The
   classic cases: parsing, validation, missing-key lookup, file I/O,
   network operations. Failure is part of the API.

2. **Is this exceptional — not part of the API contract — but recovery is
   plausible at *some* layer up the stack?** → `throw(msg)`. The classic
   cases: out-of-memory, unexpected IO state, contract violations in
   library code that a top-level handler can recover from. The caller
   chain doesn't carry the failure in its types; the runtime stack
   carries it via setjmp/longjmp.

3. **Is this a bug — an invariant the language or program should never
   violate?** → `panic(msg)` (sugar for `throw "panic: " + msg`). The
   classic cases: array bounds, integer overflow, unreachable code,
   assertion failures, cache-internal-state corruption. Default handler
   exits with stderr message; programs that need to catch it for
   logging/cleanup install `with Throws { throw: rec }`.

The decision between (2) and (3) is **intent-driven**, not
mechanism-driven — the runtime machinery is the same, but the prefix and
semantics communicate to readers whether the call site expects this to
happen "rarely" or "never."

## Prior art

| Language | Error model | Notes |
|---|---|---|
| **Rust** | Three: `Result<T, E>`, `panic!()` with optional recovery via `catch_unwind`, no checked-exception equivalent | Deliberate separation — panic is "abort by default, hidden recovery for FFI/test boundaries." Quartz **rejects** this — Rust has no effect system, so unifying via effects isn't an option. |
| **Koka** | One: `exn` effect (effectful exception type) | Quartz's model is closest to this: throw is an effect, default handler aborts, user handlers compose. The difference is Quartz's blessed-relaxation pattern (no `can Throws` propagation needed). |
| **OCaml** | Two: `Result.t` value-level + native exceptions (mutable-state, longjmp-style) | OCaml's exceptions predate effects; modern OCaml 5 effects subsume them but the legacy split persists. Quartz starts greenfield. |
| **Go** | Two: error value + `panic`/`recover` | Same shape as proposed Quartz: value-level for expected errors, panic for bugs. Recovery via `defer recover()`. Quartz's `with Throws` is the structural-extent analog of Go's `defer recover()`. |
| **Python** | One: exceptions (no value-level error type in stdlib idiom) | Too far in the other direction — every API failure is an exception, masking the "is this in the API contract?" question. Quartz keeps `Result<T, E>` for that case. |
| **Erlang** | Two: tagged tuples (`{ok, V}` / `{error, R}`) for expected, `error/throw/exit` for exceptional | Closest analog to the proposed Quartz model. Erlang's three-way split (error/throw/exit) is finer-grained than we need; Quartz collapses to one mechanism with intent expressed via the prefix. |

## Implementation staging

The unification ships in three phases. Each phase is independently
verifiable; later phases can be deferred without rolling back earlier ones.

### Phase 2 — `panic` intrinsic routes through `Throws.throw` perform ✅ SHIPPED 2026-05-02

**Reframed mid-implementation.** The original plan (always-perform, change
default handler exit code 66 → 1) ran into a hard constraint: the
scheduler's per-task panic capture (`panic_caught` machinery in worker
$poll dispatch) depends on the per-thread jmpbuf path. Always-performing
panic would route through the blessed Throws default and exit the process,
crashing the scheduler instead of capturing a single panicking task.
Phase 3 (panic_caught migration) is the prerequisite for the always-perform
design.

**Phase 2 ships an additive enhancement instead.** The panic intrinsic now:

1. Loads the effect-stack top + blessed watermark.
2. If `top > watermark`, scans the effect stack for a non-blessed
   `Throws` handler (entries above the watermark match by C-string equality
   on the effect name).
3. **On match**: builds `"panic: " + msg` via runtime `str_concat`,
   allocates a 1-slot argv on the stack, performs
   `__qz_effect_perform(@__qz_eff_name_throws, @__qz_eff_op_throw,
   i64 1, ptr %argv, i64 2)` (kind=2 = unwind). Handler receives the
   prefixed message; its return value becomes the with-block's value;
   execution resumes after the with-block.
4. **On no match (or empty stack above watermark)**: branches to the
   legacy abort path — existing IR (stderr write + jmpbuf check +
   longjmp/exit). `panic_caught` and the scheduler's per-task panic
   capture continue to work unchanged.

This is a **strict additive enhancement**: panic gains the
catch-via-`with Throws` capability without disturbing any existing
behavior. The legacy path is still the fallback for everything that
isn't an explicit user `with Throws` install. Phases 3-5 progressively
migrate the scheduler + panic_caught users to `with Throws`, after
which the legacy path can be removed and the default handler exit code
unified.

New globals (`codegen_runtime.qz`):
- `@__qz_eff_op_throw` — C string `"throw\0"` (op-name pointer for perform)
- `@__qz_panic_prefix_str` — qz string for `"panic: "` (length 7,
  `<{ i64 7, [8 x i8] }>` layout to match the standard qz string format
  consumed by `str_concat`)

The IR cost per panic call site grew from ~18 instructions (inline
write + jmpbuf check + longjmp/exit) to ~32 (effect-stack scan + the
existing legacy path on the no-match side). Hot-path neutral because
panic is rare by definition.

**Risks ruled out:**
- Per-thread jmpbuf compatibility: legacy path preserved, no scheduler
  regression.
- Default handler exit code change: not in Phase 2, deferred to
  post-Phase-3 unification.
- Missing globals: `@__qz_alloc_blessed_watermark`,
  `@__qz_effect_stack_top`, `@__qz_effect_stack_names`,
  `@__qz_effect_cstr_eq`, `@str_concat`,
  `@__qz_effect_perform` all already declared (used by other code paths).

**Validation:**
- New spec: `spec/qspec/panic_as_throws_spec.qz` (3/3 green) — panic
  caught via with-Throws + prefixed message + after-with continuation.
- All 6 existing throws/panic specs green
  (`alloc_e4b_panic_path_arena_cleanup`, `panic_handler`,
  `phase_6_1b_http_throws`, `phase_6_1b_tls_throws`,
  `phase_6_1c_handler_throws`, `phase_6_2c_quake_throws`).
- `alloc_e4b_panic_path_arena_cleanup` specifically exercises the
  scheduler's panic_caught path with 50 sequential panicking goroutines
  — verified the legacy path still works.
- `quake guard` fixpoint clean (2459 functions).
- Smoke tests: `style_demo`, `brainfuck`, the new spec, and the B.6 spec
  all green against the rebuilt binary.

### Phase 3 — `panic_caught(fn)` deprecated then removed

Migrate the 9 `panic_caught(...)` sites in compiler + stdlib to:

```be
with Throws { throw: panic_recover_handler } do ->
  fn()
end
```

`panic_recover_handler` matches on the `"panic: "` prefix and returns the
recovery sentinel (1 today, or a richer Result depending on call site).

Sites identified:
- `std/concurrency.qz:102` — goroutine panic capture via scheduler
- 8 more via `grep -n "panic_caught"` in compiler source

After all sites migrate, delete `panic_caught` from the stdlib + remove
`@__qz_panic_jmpbuf_get` / `@__qz_panic_jmpbuf_set` from
codegen_runtime.qz. Pre-launch (Stance 5: no compat shims), the deletion is
single-commit with the last migration.

### Phase 4 — Stdlib `panic()` call-site audit

Walk the 11 + 31 = 42 `panic(...)` sites in `std/` and `self-hosted/`.
For each, decide:

- **Stay as panic** (the default — most sites): the call represents a
  contract violation or invariant the function's API doesn't promise to
  surface as a value (e.g., array bounds, type-checker internal state
  corruption, unreachable code paths reached).
- **Migrate to `Result<T, E>`**: the call represents a recoverable failure
  the caller probably wants to handle locally. Likely candidates:
  parser errors that today abort but should surface as a parse-failure
  value, file-not-found in places where the caller can fall back, etc.

This is per-site judgment work, not mechanical. Estimate: ~0.5 quartz-day
total, mostly review with a few rewrites. Each migration adds a `Result`
return type plus `unwrap_or` / `match` at call sites.

### Phase 5 — Documentation ✅ SHIPPED 2026-05-02

- `docs/QUARTZ_REFERENCE.md` "Error Handling" section rewritten to lead
  with the two-mechanism framing + decision tree. New "Throw and Panic"
  subsection covers `with Throws` catch (including a worked example),
  the unwind contract, and the intent-driven choice between throw and
  panic at the call site. Existing Result/Try-Catch/Sentinel/LookupResult
  subsections retained.
- `CLAUDE.md` anti-hallucination table extended with a one-paragraph note
  describing the two-mechanism model + the panic-as-sugar relationship.
- `docs/STYLE.md` gains a new "Error Handling" section between Control
  Flow and Collections, restating the decision tree as style guidance
  (right + wrong patterns, when to wrap top-level entry points in
  `with Throws`).

## What B.9 explicitly does NOT do

- **It does not introduce checked exceptions.** `throw` is allowed
  anywhere without `can Throws` propagation because Throws is blessed
  (default handler installed at main prelude). This is the same status
  Throws has today; B.9 doesn't change it.
- **It does not introduce a typed error hierarchy.** Throws.throw still
  takes a `String` message. A future B.X could promote it to a structured
  error type (enum, struct), but that's an independent design call.
  Today, the "PanicError(msg)" framing in the original B.9 row is
  realized as the `"panic: " + msg` string prefix — same information,
  cheaper representation, matches the existing Throws.throw signature.
- **It does not change `Result<T, E>`.** Result is unaffected. The two
  mechanisms continue to serve different purposes (value vs control flow).
- **It does not deprecate `panic` as a keyword/intrinsic.** `panic("msg")`
  remains a valid call form — it's just sugar for the throw underneath.
  Calling code doesn't change.
- **It does not change bounds_panic / overflow_panic / map_key_panic.**
  These compiler-emitted noreturn helpers (called at every array index,
  arithmetic op, missing map lookup) stay as direct abort/longjmp paths
  for performance. They're not user-callable; they're internal codegen
  outputs at safety-check sites. Migrating them through Throws would
  add perform-call overhead at every bounds check — unacceptable. They
  remain a separate "fatal abort" path, semantically distinct from
  user-level panic.

## Open questions (resolve before Phase 2 ships)

1. **Default handler exit code**: today panic exits 1, Throws default
   exits 66. After unification, both go through Throws default. Pick
   one. **Recommendation: keep Throws's 66** — semantically meaningful
   (66 = "command unavailable" in BSD sysexits, close to "fatal failure"
   intent), preserves existing Throws contract. Programs expecting "exit
   code 1 on panic" need to install a handler. Pre-launch acceptable.

2. **Prefix on panic messages**: today panic prepends red `"panic: "` to
   stderr; Throws default doesn't add a prefix. After unification, the
   prefix lives in the message string itself — every `panic(msg)` becomes
   `throw("panic: " + msg)`. The default handler emits whatever message
   it gets. Slight redundancy: `throw("panic: explicit")` from a user is
   indistinguishable from `panic("explicit")` after unification. That's
   intentional — they ARE the same thing.

3. **Panic from inside a Throws handler**: today nesting is undefined
   behavior (or aborts). After unification, panic-inside-handler is a
   re-throw — handled by the next outer Throws on the stack, or the
   default. This is the existing Throws semantic; nothing new.

## Out of scope for B.9

- **Typed error hierarchies** (Java-style `Throwable` tree) — would
  require Throws.throw to take a structured type instead of `String`.
  Filed as a future B.X if user need surfaces.
- **Stack trace capture on throw** — currently neither panic nor throw
  captures a backtrace. Adding it would be a separate runtime feature.
- **`finally` semantics** — Quartz uses `defer` for cleanup. `with`
  block teardown handles the same case for resource release. No new
  syntax needed.
- **Effect-typed alternatives to Throws** (e.g., per-error-class effects
  like `IoError`, `ParseError`) — interesting future direction but
  requires the typed-error-hierarchy decision first.

## Calibration

Original row sized at ~1-2 quartz-weeks. Honest re-estimate after this
design pass:

| Phase | Estimate | Notes |
|-------|----------|-------|
| 1 (this memo) | 0.1 quartz-day | Done. |
| 2 (panic intrinsic → Throws.throw) | ~0.5 quartz-day | Single codegen edit, new spec, fixpoint + smoke. Bounded. |
| 3 (panic_caught migration) | ~0.5 quartz-day | 9 sites, mechanical conversion. |
| 4 (panic call-site audit) | ~0.5 quartz-day | 42 sites, mostly stay-as-panic, a few migrate to Result. |
| 5 (docs) | ~0.3 quartz-day | Reference + CLAUDE.md + STYLE.md updates. |
| **Total** | **~2 quartz-days** | Down from "1-2 quartz-weeks" because the design pass collapsed several open questions and the mechanism (Throws blessed-relaxation) was already built. |

Sister to Operation Piezoelectric Effects calibration: when the substrate
exists, the user-facing unification is mostly migration work, not
architectural work.
