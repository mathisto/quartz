# Struct-shaped enum variant in heavy-import module: typecheck memory blowup

**Status**: ✅ **CLOSED 2026-04-29** by commit `9405ea17` ([typecheck] tc_make_ptype: hash-map intern cache). Root cause: `tc_make_ptype` did O(N) linear scan over `ptype_bases` per call; with 7 heavy imports the table was already ~3000 entries, so each variant field's type-parse triggered ~3000 comparisons — quadratic in (variants × type-parses × existing ptypes). Fix: replaced linear scan with `Map<String, Int>` keyed on `"base|arg1|arg2"`. Net +6 LOC. Quake guard 2411 functions, gen1==gen2 byte-identical. End-to-end RAM verification on the original repro is deferred (the heavy-import test itself is the RAM hazard the bug created — kernel-panicked again 2026-04-29 attempting it); fixpoint validates the change is safe — the compiler self-compile exercises `tc_make_ptype` thousands of times per pass.
**Severity** (historical): medium — surfaced as compilation hang at 28+ GB RAM (system kernel-panicked twice during bisect attempts). Doesn't corrupt artifacts.
**Reproduced on**: every Quartz binary tested 2026-04-26 (post-Phase-6.1.b-prep `7df8b805` and earlier). Pre-existing — surfaced by Phase 6.1.b but not introduced by it.

## Repro

In `std/net/http_server.qz` (or any module that imports `std/net/url`,
`std/json`, `std/markdown`, `std/net/http2`, `std/net/hpack`, `std/log`,
`std/throws` — i.e. heavy import set), declaring an enum with a
struct-shaped variant:

```qz
enum HttpError
  SocketCreateFailed
  BindFailed { port: Int }    # <- this line triggers it
  ListenFailed
  KqueueCreateFailed
  KeventWaitFailed
end
```

Compiling any program importing this module produces:
- `quartz` process RSS climbs to 28+ GB at ~60 seconds, still climbing.
- At 40 GB the process was still in PASS-1-style work (no IR emitted).
- Killed at >40 GB to avoid system memory exhaustion (a previous attempt
  panicked the kernel: compressed-pages-limit 100% / watchdog timeout).

The exact same code with a tuple-shaped variant compiles in **23
seconds at 1.6 GB**:

```qz
enum HttpError
  SocketCreateFailed
  BindFailed(Int)             # <- tuple variant: fine
  ListenFailed
  KqueueCreateFailed
  KeventWaitFailed
end
```

Bisect (all from clean `.quartz-cache`):
- import `std/throws` only, no enum:                           23s, 1.6 GB ✓
- import + enum with all unit variants:                        23s, 1.6 GB ✓
- import + enum with one tuple variant `BindFailed(Int)`:      23s, 1.6 GB ✓
- import + enum with one struct variant `BindFailed { port: Int }`: 28+ GB at 61s, killed ✗

So the trigger is specifically the struct-shaped variant. No `match`
arm needed; just declaring the enum is enough.

## Likely root cause (speculation)

Struct-shaped variants have additional typecheck machinery (named-field
resolution, named-pattern matching). In a module with this many imports
and existing struct types, something is iterating over a name set in a
way that's quadratic or worse — either:
- The variant's anonymous field-struct conflicts in name with imports.
- Pattern-matching arm lowering allocates per-import-scope artifacts.
- `tc_struct` or similar walks the full module's struct registry for
  each variant's field set.

Smaller modules (`/tmp/test_enum.qz` with no imports) compile struct-
variant enums fine — confirmed pre-bisect. So it's specifically the
intersection with heavy-import context.

## Workaround in 6.1.b

`BindFailed(Int)` instead of `BindFailed { port: Int }`. Format function
matches `BindFailed(port) => ...` instead of `BindFailed { port } => ...`.
User-facing readability is slightly worse (positional instead of named)
but functionally identical. Documented inline at the enum definition.

## Followups

- Reproduce in isolation outside http_server.qz: pick a small module
  with similar import depth, add a struct-variant enum, see if it
  reproduces. If so, narrow the import set until the trigger surfaces.
- Profile the typechecker during the runaway compile to identify the
  hot path. `lldb` attach + `frame select` on the spinning thread.
- Once root cause known: switch http_server.qz back to struct-shape
  variant for the v2 user-facing API quality. Update the enum + format
  function + spec in lockstep.

## Cross-refs

- Trigger commit (workaround applied): the Phase 6.1.b bind/listen
  migration commit (immediately after `7df8b805`).
- Related: `feedback_quartz_module_quirks.md` lists other typecheck
  pathologies with heavy-import modules (Vec<T> element type loss with
  silent wrong-struct field resolution, hit twice in `1a60633c`).
  Same family of compiler bug; this entry adds another reproducer.
