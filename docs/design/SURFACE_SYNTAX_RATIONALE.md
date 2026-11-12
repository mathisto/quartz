# Surface Syntax Rationale — "Less to Write, All Recoverable"

> **Status**: DESIGN / RATIONALE (proposed 2026-06-16). Not yet implemented.
> **Tracking**: ROADMAP epic **SURF**.
> **Audience**: dual-purpose. (1) Internal design record. (2) The public-facing
> "why Quartz looks like this" piece for pre-1.0 feedback readers.
> **Pre-1.0 surface notice**: This deliberately reopens the Mar 19 2026 syntax
> freeze. See "On reopening the freeze" below. Nothing here is a stability
> promise; this is exactly the shape-and-feel pass that must land *before* the
> one public first impression.

---

## Why this document exists

A language's public surface is a near-irreversible commitment. The moment
strangers have code written against Quartz's syntax and semantics, every
observable detail becomes a contract (Hyrum's Law), and we are either
backwards-compatible forever or we become the next Python 2→3. The first
impression — the README, the first Hacker News thread — also happens exactly
once.

So before Quartz is shown for use, the surface has to be *right*, not just
*working*. This document is the rationale for the last round of surface changes
and the inference/tooling that makes an aggressively clean surface safe for a
no-GC systems language.

It is organized around one principle:

> **Types are optional to write, exact to recover.**
> You never hand-maintain a type Quartz can infer — but you can summon every
> one of them into the source on demand, and strip them back out, losslessly.

Everything below is in service of that line.

---

## The problem, in our own code

Today the colon `:` does **five** different jobs:

| # | Role | Example | Colon means |
|---|------|---------|-------------|
| 1 | Param type | `def backoff_next_delay(cfg: BackoffConfig)` | "has type" |
| 2 | Return type | `def actor_die(_reason: Int): Void` | "returns" |
| 3 | Var annotation | `var count: Int = 0` | "has type" |
| 4 | Struct field **decl** | `min_backoff_ms: Int` | "has type" |
| 5 | Struct field **init** | `Point { x: 3, y: 4 }` | "gets value" |

Roles 1–4 are *type ascription*. Role 5 is *value binding* — the opposite
direction, identical glyph. The collision is visible five lines apart in the
stdlib:

```ruby
struct BackoffConfig
  min_backoff_ms: Int            # ':' = "this field HAS TYPE Int"
end

BackoffConfig {
  min_backoff_ms: min_backoff_ms # ':' = "this field GETS VALUE min_backoff_ms"
}
```

And signatures pile annotations onto the spine. Built from only real Quartz
constructs (param types, trait bounds, nested generics, return type, effect row):

```ruby
def merge<K: Hash, V: Show>(a: Map<K, Vec<V>>, b: Map<K, Vec<V>>): Result<Map<K, Vec<V>>, MergeError> can e
```

Five colons, three different meanings, plus `can e` floating off the end. The
reader context-switches the colon's meaning mid-line while tracking `<...>`
nesting depth. That is the "indecipherable" feeling, concretely.

Three changes fix it: a colon rule, `where` clauses, and inference +
materialization. They are one coherent story — *less to write, all recoverable*.

---

## 1. The literal surface — kill the hashrocket, unify on `:`

> **Revised 2026-06-16 — supersedes the earlier `=`-for-struct-init draft.** The
> first draft proposed making `:` types-only and moving struct init to `=`. That
> was the wrong cut. The colon "overload" is a **non-problem**: Python,
> TypeScript, Go, and Swift all use `:` for *both* type ascription and literal
> key/field binding, at scale, with zero confusion — because **context
> disambiguates** (a declaration is never a literal). The real wart was the
> **hashrocket `=>`** on map literals and the struct-vs-map incoherence it
> created. So we keep `:` for binding in every literal and kill the rocket.

**Rule: `:` binds in every literal (struct field, map entry) and ascribes types
in declarations. `=` is statement-level assignment only. The map hashrocket `=>`
is removed.**

```ruby
# Maps — the hashrocket dies
{ name: "Be", "Content-Type": ctype, (get_key()): 99 }   # was {:name => …, "…" => …, get_key() => …}
{ }                                                       # empty map

# Sets — bare elements; the prefix appears ONLY on the empty case
{ 1, 2, 3 }
Set{ }

# Structs — unchanged
Point { x: 3, y: 4 }
```

**Map keys:** bareword = symbol (`name:`), `"string"` = string key, `(expr)` =
computed key. Reads like modern Ruby/JS; no rocket.

**The unified brace rule (one sentence):** a brace literal is `[Type]{ body }` —
colons in the body mean *keyed* (a map, or a struct when a struct type prefixes
it); bare elements mean a *set*; empty `{}` defaults to map, so an empty set is
`Set{}`; `it` / `->` / statements mean a closure.

| | bare | prefixed |
|---|---|---|
| keyed (`:`) | `{k: v}` map | `Point{x: 3}` struct |
| unkeyed | `{1, 2, 3}` set | `Set{1, 2, 3}` set |
| empty | `{}` map | `Set{}` set |
| closure | `{ it*2 }` / `{ x -> e }` | — |

`Set{…}` is **not** a special case — it's the general `[Type]{ body }` rule, where
the prefix names the type and the body shape (colons vs bare elements) says
keyed-vs-unkeyed. The prefix is *required* only for the empty set, the one shape
whose body can't speak for itself.

**Why this beats the `=` cut:** smaller migration (only *maps* change, never a
struct literal), it matches the universal `{}`-is-a-map intuition (Python/JS/Ruby)
for the one-shot first impression, and sets stay terse — the prefix shows up
solely where it earns its keep. The colon "overload" we keep is the exact one
TS/Python ship happily.

**Records vs maps (resolved):** bare `{k: v}` is always a **Map**; structs/records
are **nominal** (`Point{x: 3}`). Anonymous structural records, if ever needed,
come from the expected type (type-directed, TS-style) — no new sigil. This couples
to R2.1 (Union/Record termification): the two must share one literal rule.

**Migration:** mechanical and small — rewrite map literals `{k => v}` → `{k: v}`
across stdlib / specs / examples via the formatter (§3); struct literals untouched.

**Pre-existing wrinkle (inherited, not opened here):** single-element `{ x }`
(set-of-one vs closure-returning-`x`) is an existing brace ambiguity Quartz
already resolves; we keep its current handling unchanged.

Tracked as SURF.1.

---

## 2. `where` clauses — constraints leave the spine

Trait bounds and the effect row move out of the angle brackets and the tail.
The `<>` carries only *names*; constraints live below where the eye can skip
them until needed.

```ruby
# BEFORE
def merge<K: Hash, V: Show>(a: Map<K, Vec<V>>, b: Map<K, Vec<V>>): Result<Map<K, Vec<V>>, MergeError> can e

# AFTER
def merge<K, V>(a: Map<K, Vec<V>>, b: Map<K, Vec<V>>): Result<Map<K, Vec<V>>, MergeError>
  where K: Hash, V: Show, e
```

Rule: a single trivial inline bound stays legal (`<T: Show>` — do not force
ceremony on the common case). `where` is the home for 2+ bounds and for effect
rows. The formatter owns the threshold for when to hoist (gofmt-opinionated).
Tracked as SURF.2.

This is a pure layout decision — low semantic risk, high legibility win on the
worst lines.

---

## 3. Inference + materialization — the keystone

The only real objection to aggressive inference in a no-GC systems language is
*"I can't read the type off the page."* The formatter dissolves it.

### Inference: optional everywhere, deterministic

- **Bidirectional local inference everywhere** — locals, return types, most
  params inferred.
- **Signatures optional, never required.** Write them when you want the
  doc/pin; omit when obvious. One-liners already do this (`def double(x) = x * 2`).
- **Inference is a deterministic, stable contract** — same code + same compiler
  ⇒ same inferred type, always.

The honest tradeoff this normally carries is the **OCaml/Haskell problem**:
optional signatures + inference = errors reported far from their cause (an
unannotated `def` silently absorbs a bad type; the error surfaces three files
away at a call site). The standard mitigation is "just write top-level
signatures anyway" — which defeats the point.

**Our mitigation is the materializer.** On a type error in unannotated code, the
compiler emits the *inferred signature it deduced* — "I inferred
`def f(x: Int): String`; that conflicts here" — and the formatter can pin it
permanently. Inference and materialization are therefore **one feature, not two.**

**Revival, not invention:** an HM-style inference engine already exists, parked
at `experiments/parked/hm-inference/` (`infer.qz` 56 KB, `hir.qz`, `types.qz`),
built Mar–Apr 2026 and shelved only because cross-module integration wasn't
ready and it wasn't top-priority then. Its README lists the revival steps. SURF.3
is that revival: audit against the current type system, wire into the pipeline,
prove behavioral equivalence on the QSpec suite.

### Materialization: `quartz fmt` with a brain

The current `tools/fmt.qz` is a 147-line text-based v1 indenter — no AST, no
type knowledge. Materialization requires upgrading it to an **AST +
typechecker-backed** formatter (SURF.4). Modes, all idempotent:

| Command | Does |
|---|---|
| `quartz fmt` | Canonical layout. **Never touches your type choices.** |
| `quartz fmt --annotate[=public\|all]` | Fill inferable types into source. `=public` does API boundaries only; `=all` does everything. |
| `quartz fmt --elide` | Inverse — strip every annotation inference recovers exactly, leaving only *load-bearing* ones. Minimal source. |
| `quartz fmt --check` | CI gate, gofmt-style. |

**The fixpoint invariant** (fits the gen1==gen2 self-host discipline): for any
file, `annotate` then `elide` returns byte-identical source, both directions.
That is a verifiable property and a natural test target — it slots into the
already-planned DF.25 "round-trip parse/format" property tests.

### Effects ride the same rails

Quartz's `can e` row-polymorphic effects are Koka's design (Daan Leijen, MS
Research — row-typed effect inference). Koka *infers* effects rather than
requiring them. So effects ride the exact same rails: inferred by default,
`where`-listed or materialized on demand (SURF.5). We are on the frontier of
this system, not improvising it.

---

## Relationship to paren elision (already shipped)

Dot-method paren elision shipped as B.6 (2026-05-02) under **Stance 4**:
paren-optional only at dot-access position, never at bareword position
(`p.magnitude`, `5.triple`). This surface pass is consistent with and continues
that direction — fewer obligatory glyphs in ordinary code — and does not
relitigate Stance 4. The formatter's canonical form (§3) is where the
paren-elision and colon/`where` conventions get mechanically enforced.

---

## Prior art (so we cite, not reinvent)

| Lang | Inference | Signatures | Materialize tool |
|---|---|---|---|
| Rust | full local | **required** at fn boundary | rust-analyzer "add explicit type" assist |
| OCaml/Haskell | full global HM | optional (convention: write them) | HLS "add type signature" |
| Swift | local bidirectional | required | — |
| TypeScript | returns + locals | params often needed | codefix "infer from usage" |
| **Quartz (proposed)** | **full local, optional everywhere** | **optional, materializable** | **`quartz fmt --annotate/--elide`, round-trip fixpoint-verified** |

The empty cells are the opening: **nobody ships optional-everywhere + lossless
bidirectional materialization as a first-class, fixpoint-verified tool.** That
is the headline of the public rationale.

---

## On reopening the freeze (honest record)

`docs/ROADMAP.md` records: *"Language syntax frozen (Mar 19, 2026)."* The colon
rule (§1) and `where` clauses (§2) reopen that surface. This is deliberate and
owner-driven: the freeze was a working-stability measure, not a 1.0 commitment,
and the owner's call is that the surface is **not yet at the standard for the
one-shot public release**. Reopening now — pre-1.0, pre-users — is the correct
time and the *only* safe time to do it. Inference and materialization (§3) are
additive and do not break the surface; the colon/`where` changes are the
genuinely surface-affecting ones and must land and re-settle before any public
release. The roadmap freeze line (`docs/ROADMAP.md`) has been updated (SURF.0,
2026-06-17) to reflect a scoped pre-1.0 reopening rather than a blanket thaw:
*frozen Mar 19, 2026 → reopened pre-1.0 for the SURF epic → re-freezes at 1.0*.
Decisions are LOCKED in `docs/design/SURFACE_DECISIONS.md` (2026-06-17).

---

## Decisions captured

1. **Literal surface (SURF.1):** `:` binds in all literals (struct field, map
   entry) + ascribes types in declarations; `=` is assignment only; the map
   hashrocket `=>` is removed (`{k => v}` → `{k: v}`). Sets stay bare `{1,2,3}`
   with `Set{}` for the empty set; `{}` = empty map. Bare `{k:v}` = Map;
   structs/records nominal. Unified rule: `[Type]{body}` — colons = keyed, bare
   elements = set, `{}` = map, `it`/`->` = closure. Couples to R2.1.
2. `where` clauses for 2+ bounds and effect rows; single inline bound stays. (SURF.2)
3. Inference optional everywhere, deterministic; revive parked HM-v2. (SURF.3)
4. Formatter v2: AST+typechecker-backed; `--annotate/--elide/--check`;
   annotate∘elide fixpoint. (SURF.4)
5. Effect inference + materialization on the same rails. (SURF.5)
6. This doc is the public "why Quartz looks like this" piece; polish for the
   three trusted pre-1.0 readers, gather feedback before re-freeze. (SURF.6)

## Open questions for the trusted readers

- (Resolved 2026-06-16: the `=`-for-struct-init idea is dropped; literals keep
  `:` and the map hashrocket is removed instead — see §1. Open to readers: does
  `{ name: "Be" }` (bareword key = symbol) read clearly vs a struct literal
  `Point { x: 3 }` when the type prefix is the only cue?)
- `where K: Hash, V: Show, e` — is folding the effect row into the same `where`
  list intuitive, or should effects get their own clause keyword?
- `--annotate=public` as the recommended pre-release pass on library
  boundaries: default-on for `quartz fmt --check` in library projects, or
  opt-in?
