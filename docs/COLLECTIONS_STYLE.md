# Quartz Collection API Style Guide

**Status:** normative
**Authority:** this document is the source of truth for collection method
naming. Compiler dispatch tables and the linter enforce it. When this guide
disagrees with code, the code is the bug.

This guide exists because Quartz had silently accumulated three names for
the same operation across collection types ("delete" / "remove" / "del"),
documentation that didn't match code, and feature promises with no
implementation. Future contributors — human or AI — point here to settle
naming questions instead of inventing a new convention every session.

## Core principles

1. **Same operation = same name across all collections that support it.**
   The price of a third name is one corrupted mental model per user.
2. **One canonical name per operation.** No aliases. Pre-launch, zero users,
   zero compat layers (Prime Directive 7).
3. **Convention over configuration.** A new contributor reading this doc
   should be able to predict the right method name without grepping.
4. **The compiler enforces the rules.** The UFCS dispatch table in
   `self-hosted/middle/typecheck_expr_handlers.qz` is the only path to a
   collection method call. If a name is not in the table, it is not a method.
5. **The linter enforces user-side compliance.** `tools/lint.qz` warns and
   auto-fixes stale verbs, doc-promised but unimplemented forms, and any
   pattern that violates this guide.

## The grand naming table

| Operation | Vec | Map | Set | String | StringBuilder | Range | Option | Result | Channel |
|-----------|-----|-----|-----|--------|---------------|-------|--------|--------|---------|
| Cardinality | `.size()` | `.size()` | `.size()` | `.size()` | `.size()` | `.size()` | — | — | `.size()` |
| Empty predicate | `.empty?()` | `.empty?()` | `.empty?()` | `.empty?()` | `.empty?()` | `.empty?()` | `.none?()` | `.err?()` | `.empty?()` |
| Get value (safe) | `.get(idx)` → Option | `.get(key)` → Option | — | `.char_at(idx)` → Option | — | — | `.unwrap()` | `.unwrap()` | `.recv()` |
| Index access | `v[idx]` | `m[key]` | — | `s[idx]` (codepoint) | — | — | — | — | — |
| Membership (key/element) | `.has(elem)` | `.has(key)` | `.has(elem)` | — (use `contains`) | — | `.has(x)` | — | — | — |
| Sub-pattern contains | `.contains(elem)` | — | — | `.contains(substr)` | — | — | — | — | — |
| Add (back) | `.push(elem)` | — | — | (concat) | `.append(s)` | — | — | — | `.send(v)` |
| Add (key) | — | `.set(k,v)` | — | — | — | — | — | — | — |
| Add (unordered) | — | — | `.add(elem)` | — | — | — | — | — | — |
| Remove (back) | `.pop()` → Option | — | — | — | — | — | — | — | — |
| Remove (front) | `.shift()` → Option | — | — | — | — | — | — | — | — |
| **Remove by index/key/elem** | `.delete(idx)` | `.delete(key)` | `.delete(elem)` | — | — | — | — | — | — |
| Clear | `.clear()` | `.clear()` | `.clear()` | — | `.clear()` | — | — | — | `.close()` |
| Free (explicit) | `.free()` | `.free()` | `.free()` | — | `.free()` | — | — | — | `.free()` |
| Iterate (Void) | `.each(f)` | `.each(f)` | `.each(f)` | `.each(f)` | — | `.each(f)` | — | — | — |
| Map (transform) | `.map(f)` | `.map(f)` | `.map(f)` | `.map(f)` | — | `.map(f)` | `.map(f)` | `.map(f)` | — |
| Filter | `.filter(p)` | — | `.filter(p)` | — | — | `.filter(p)` | — | — | — |
| Find | `.find(p)` → Option | — | — | `.find(s)` → Option | — | — | — | — | — |
| Sort (mutate) | `.sort()` Void | — | — | — | — | — | — | — | — |
| Sort (copy) | `.sorted()` → Vec | — | — | — | — | — | — | — | — |
| Reverse (mutate) | `.reverse()` Void | — | — | — | — | — | — | — | — |
| Reverse (copy) | `.reversed()` → Vec | — | — | `.reversed()` → String | — | — | — | — | — |

## Hard rules

### 1. `.delete()` is the One True Verb for removal-by-index/key/element

```quartz
v.delete(0)          # Vec: remove element at index 0
m.delete("key")      # Map: remove entry by key
s.delete(42)         # Set: remove element
```

`.remove()`, `.del()`, and `delete_at()` do not exist as methods. `vec_remove`
intrinsic does not exist. The lint warns and auto-fixes any stale call.

### 2. `.size()` for cardinality, never `.len()` / `.length()` / `.count()`

```quartz
v.size()             # Vec / Array / String / Map / Set / StringBuilder / Range / Channel
```

`.len()` was removed in early Apr 2026. The linter warns and auto-fixes
`vec_len(`, `.len()`, `.length()`.

`.count(p)` is reserved for "count elements matching predicate `p`" — it takes
a closure, returns an Int. Different operation; different signature.

### 3. `.empty?()` is the canonical empty-check; the `?` suffix is the predicate sigil

```quartz
v.empty?()           # Vec / Map / Set / String / StringBuilder / Range / Channel
opt.none?()          # Option (semantically distinct from "empty")
opt.some?()          # Option
res.ok?()            # Result
res.err?()           # Result
ch.digit?()          # Char
ch.alpha?()          # Char
```

The bare `is_empty()` form is acceptable in *trait method definitions* where
`?` is not parseable inside a `def` header. Everywhere else, the `?` form is
canonical.

### 4. Mutation vs copy is a verb pair, not a sigil

```quartz
v.sort()             # mutates in place, returns Void
sorted = v.sorted()  # returns a new Vec, leaves v unchanged

v.reverse()          # mutates in place, returns Void
rev = v.reversed()   # returns a new Vec
```

Hard rule: mutating form is the bare verb (`sort`, `reverse`, `clear`,
`delete`, `push`, `pop`); copying form is the `-ed` adjective form
(`sorted`, `reversed`).

There is **no `!` mutation suffix**. Ruby's `!` convention was considered
and rejected: it's subtle, easy to miss, and the verb pair is more
discoverable. Any documentation or example that mentions `v.clear!` or
`v.sort!` is a doc bug — file it.

### 5. `.has()` for keyed/element membership; `.contains()` for sub-pattern

```quartz
m.has("key")         # Map: does this key exist?
s.has(42)            # Set: does this element exist?
r.has(5)             # Range: is this value in the range?

s.contains("foo")    # String: does this substring appear anywhere?
v.contains(42)       # Vec: is this element anywhere in the sequence?
```

The Vec/String overlap on `contains` is intentional and matches Rust's
precedent. Both are O(n) sub-pattern searches over a sequence, and "contains"
reads naturally in both contexts. This is the only documented exception to
the "same op = same name" rule.

### 6. `pop` / `shift` are stack/queue verbs, not delete verbs

```quartz
maybe_last  = v.pop()    # Vec: remove + return last element, returns Option
maybe_first = v.shift()  # Vec: remove + return first element, returns Option
```

Different from `.delete(idx)` because (a) the position is implicit in the
verb, and (b) the return value matters — `pop` and `shift` need to
communicate "was there anything to take?" via Option.

### 7. Documented exceptions, with reasons

- **`set` for Map** (`m.set(k, v)`). Yes, it collides with `Set` the type
  name. The collision is acceptable because the contexts disambiguate
  (you call `.set()` on a value, you reference `Set` as a type) and the
  alternatives (`put`, `insert`, `assoc`) are uglier or longer. Do not
  "fix" this collision.
- **`add` for Set** (`s.add(elem)`). Set is unordered, so `push` (back)
  and `set` (key-value) feel wrong. `add` matches mathematical set
  semantics. Documented.
- **`recv` / `send` / `close` for Channel.** Channels are pipes, not
  collections. They use the channel verb family.

## How the rules are enforced

### Compiler

`self-hosted/middle/typecheck_expr_handlers.qz` contains UFCS dispatch
tables for each collection type (lines 1636-1762 as of Apr 13 2026). These
tables are the *only* path from `receiver.method()` syntax to an intrinsic
call. If a name is not in the table, the compiler errors with a "did you
mean: <canonical name>?" hint.

When you add a new collection method, you must:
1. Add the canonical name (and *only* the canonical name) to the dispatch
   table.
2. Verify it matches this style guide. If your new method doesn't fit any
   existing rule, add a new rule here first and get it approved before
   adding the method.

### Linter

`tools/lint.qz` enforces user-side compliance. The lint warnings (with
`--fix` auto-rewrite) cover:

- `.remove(`, `.del(` on any collection → suggest `.delete(`
- `.len()`, `.length()` → suggest `.size()`
- `is_empty()` outside trait method bodies → suggest `.empty?()`
- `vec_remove(` direct call → suggest `vec_delete(` (or UFCS form)
- Any reference to `v.clear!` or other `!`-suffix mutators → unimplemented,
  suggest the verb-pair form
- Direct calls to `intmap_*` or `hashmap_*` (the implementation intrinsics)
  → suggest the unified `map_*` form

### Snapshot test

`spec/snapshots/ufcs_dispatch.txt` is a frozen dump of the dispatch table.
Any change to the typecheck_expr_handlers.qz dispatch entries breaks the
snapshot, forcing the contributor to re-run the snapshot generator and
confirm they're following this guide.

## When you find drift

If you find a method, intrinsic, doc example, or stdlib wrapper that
violates this guide:

1. **Fix it.** Pre-launch, zero users — Prime Directive 7. No deprecation
   period. Delete the wrong thing and add the right thing in the same
   commit.
2. **OR file it.** Add an entry to `docs/ROADMAP.md` under "API drift" if
   the fix has a hard dependency on something that doesn't exist yet.
3. **Never ignore it.** Silent discovery is a Prime Directive 6 violation.

## Out of scope for this guide

The following are real concerns but live in other docs:

- String two-tier API (codepoints vs bytes) → `docs/QUARTZ_REFERENCE.md`
  String section
- Iterator protocol and `Iterable`/`Container` traits → `docs/INTRINSICS.md`
  and `std/traits.qz`
- FFI type validation → `docs/API_GUIDELINES.md`
- Channel send/recv semantics → `docs/QUARTZ_REFERENCE.md` Concurrency
  section

## Cross-references

- `docs/QUARTZ_REFERENCE.md` — language reference, all syntax, all examples
- `docs/INTRINSICS.md` — list of all intrinsics with signatures
- `docs/STYLE.md` — broader code style guide (formatting, naming, layout)
- `self-hosted/middle/typecheck_expr_handlers.qz` — UFCS dispatch tables
- `self-hosted/backend/intrinsic_registry.qz` — canonical intrinsic names
- `tools/lint.qz` — lint rule implementations
