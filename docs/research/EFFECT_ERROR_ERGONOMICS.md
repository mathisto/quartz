# Effect Error Ergonomics — research framing

> **Status**: 📋 RESEARCH — skeleton only. Pull-in deferred until effects substrate stabilizes (post-Phase D, post-Phase 6.x).
> **Filed**: 2026-04-27.
> **Cross-links**: [`EFFECTS_IMPLEMENTATION_PLAN.md`](EFFECTS_IMPLEMENTATION_PLAN.md), [`../design/ALLOC_EFFECT_PLAN.md`](../design/ALLOC_EFFECT_PLAN.md), [`../design/DIAGNOSTICS_EFFECT.md`](../design/DIAGNOSTICS_EFFECT.md).

## 1. What this memo is

A parking spot for an idea worth building toward when the effects substrate stabilizes: **use Quartz's effect-tracking machinery as the engine for diagnostic INTELLIGENCE, not as user-facing VOCABULARY.**

Effects-research languages (Koka, Eff, Frank, Idris) all suffer the same UX problem: their error messages leak row-polymorphism vocabulary directly to users. "Cannot unify `<file_io | r>` with `{}`" is technically correct and humanly useless. The community has tolerated this because effect-row-poly is hard, and clean error messages on top of it are harder.

The proposal: **collapse two problems usually treated separately.**

**Arm 1 — Insulate.** Hide effect-row machinery from default error messages. Users see stories about what they did and what their options are. Power users opt into the row view via `quartz explain QZ____`.

**Arm 2 — Enrich.** Use effect-tracking as a diagnostic SIGNAL across all error classes, not just effect-row mismatches. A compiler that tracks effects + mutability + borrows in one place can correlate them to surface anticipatory diagnostics no other compiler can — race risks, partial-write risks, scope-mismatch risks — *before* they manifest as runtime issues.

The Rust analog is the existence proof: Rust's borrow checker tracks regions, liveness, drop semantics, and exposes none of that vocabulary in default messages. The story is what comes out. The machinery stays internal. Quartz can do the same for effects, plus the extra dimension.

## 2. The unique positioning claim

> First effects-native language where effect errors don't make you cry.

Or, sharper: **first effects-native language where the same machinery that produces row-vomit elsewhere produces a story.**

If we ship this, we beat Koka, Eff, Frank, Idris on UX without sacrificing the row-polymorphism win. That's a real moat — and it compounds with every effect-tracked phase of the compiler (4D row-poly Stream, 6.x stdlib migration, etc.). More tracked context = more enriched messages.

## 3. Concrete shape — to be fleshed out

### 3.1 Hide the noise (Phase E.1)

The cheap, big-impact win. ~1 session.

```
# Bad (Koka-flavored — NEVER ship)
expected: <r> -> int
actual:   <file_io | r> -> int
hint:     cannot unify {} with {file_io}

# Good (Quartz-flavored — what we ship)
error: read_file performs FileIo, but main() doesn't allow that
  --> app.qz:42:5
42 |   read_file("/etc/passwd")
   |   ^^^^^^^^^^^^^^^^^^^^^^^^ here

three options:
  (1) wrap it:    try read_file("/etc/passwd")
  (2) handle:     with FileIo { ... } do ... end
  (3) propagate:  def main(): Int can FileIo
```

`quartz explain QZ____` keeps the row view available for power users and tooling.

### 3.2 Story library (Phase E.2)

Catalog of common effect-error patterns with hand-crafted stories + fix recipes. Each story has:
- A pattern matcher (effect-row shape, hole shape).
- A user-facing message + fix-recipe template.
- A canonical example.
- Stability marker (story → row-vomit fallback if pattern doesn't match perfectly).

Drives consistency across error classes. Each new effect added to the stdlib gets one story entry.

### 3.3 Anticipatory diagnostics (Phase E.3 — the moat work)

Use cross-cutting info (effects + mutability + borrows + concurrency) to flag *likely* bugs before they manifest. Examples Quartz can surface that nobody else can:

- **Race risk**: `var x` (mutable) + captured by `go` block + `Async` effect on scope → "three signals → race risk; prefer immutable or Atomic<Int>".
- **Partial-write risk**: Net read + FileIo write without sequencing → "if read partially fails, file is in half-written state".
- **Scope-mismatch risk**: FileIo (process-global) + State<Counter> (per-call) interleaved → "Are you sure you want to reset State each call?"

These aren't error messages. They're *correlations* the compiler can see because it tracks everything in one place, and which no human reviewer could spot consistently. **This is the real moat.**

### 3.4 Tooling integration

- LSP: stories surface as inline hints, `quartz explain` rendering as hover.
- `quartz fmt` could auto-fix some of the simple recipes (when a fix is a one-liner like adding `try`).
- `quartz check --strict` could promote story-level hints to errors for CI.

## 4. Costs to be honest about

- **Engineering**: Rust's error message work was thousands of engineer-hours. Each story is hand-crafted. We pay this if we want the moat.
- **Maintenance**: Without discipline, the catalog rots. Need a "story stays current with the effect" invariant — tested via spec.
- **False precision**: A wrong hint sends users down wrong paths. Vague-and-correct beats specific-and-wrong. Stories must have confidence levels.
- **i18n**: Hand-crafted English-only is fine for v1; revisit when there's demand.

## 5. Sequencing

| Phase | Scope | Effort | Trigger |
|---|---|---|---|
| E.0 | This memo | done | filed 2026-04-27 |
| E.1 | Hide row noise from default messages; preserve via `--explain` | 1 session | post-Phase D, post-Phase 6.x |
| E.2 | Story library — top-20 effect-error patterns | 1 session per chunk | post-E.1 |
| E.3 | Anticipatory diagnostics — race/partial-write/scope correlations | open-ended; ship as catches accumulate | post-E.2 |

E.1 alone is probably the biggest single-session UX upgrade in Quartz's history. E.3 is the moat work and pays dividends for years.

## 6. Pull-in triggers

Pull this in when *all* of:

1. Phase D arena dogfood is shipped + stable (so the substrate that generates effect-tracked code is stable).
2. Phase 6.x stdlib migration is shipped (so the effects in scope are the ones we actually want stories for).
3. There's appetite for a UX-focused phase between feature work — this is polish, not capability.

Pull in *earlier* if:

- A real user starts asking about effect-row error messages (not yet a real audience).
- We want a marketing/positioning piece and need a concrete claim ("first effects-native language with..."). 

## 7. Open questions

- Does `quartz explain` need a richer DSL (templates, examples, "did you mean") or is the current `QZ____` → markdown lookup enough?
- Where do "stories" live? Inline in the typecheck pass? Separate registry? Stdlib module?
- Do we want a story SPEC format that's testable, so a story can't drift from the actual error condition it claims to describe?
- How does this interact with the `Diag` effect? Does the story emitter become an effect handler swap?
- What's the right confidence-level model — "story matches", "story partially matches", "fall back to row view"?

## 8. Survey targets

When we flesh this out, survey what works and what doesn't in:

- **Rust**: borrow-checker errors, "did you mean", `--explain`, `cargo fix`. The gold standard.
- **Elm**: type-error friendliness, visual pointers, hidden type machinery.
- **Roc**: pure-effects descendant of Elm; how do they handle effect errors?
- **Koka**: what the row-vomit baseline looks like; what to NOT ship.
- **Idris 2**: ongoing work on totality + effect error messages.
- **OCaml**: type-error principle of "first error wins" vs "all errors at once".
- **Haskell GHC**: `-fdefer-type-errors`, "Did you mean", typed-hole interaction.

The goal of the survey isn't to copy any one of them; it's to understand which moves actually translate to UX wins for an effects-tracked language.
