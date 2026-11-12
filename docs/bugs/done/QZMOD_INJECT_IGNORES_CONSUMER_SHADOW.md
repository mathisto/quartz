# qzmod inject ignores consumer-side function shadow

**Filed:** 2026-05-21 (discovered while flipping `QSPEC_PREWARM=1` as the
qspec default — `repl_spec` was the single prewarm-induced regression).
**Severity:** Medium — surfaces as a duplicate-`define` llc error, only
when a consumer module defines a function with the same name as one a
qzmod-injected `import * from X` would re-export.

## Summary

When the producer's `import * from X` glob brings a function `F` into a
consumer's namespace as unprefixed `F`, *and* the consumer module itself
defines `def F(...)`, the two are emitted as two separate `@F` symbols
under qzmod cache injection. The cold path (no qzmod, fresh resolve)
collapses the conflict cleanly — the local wins and the imported `F`
is DCE'd before codegen.

## Reproducer

```
cd /path/to/quartz
git show 6f1b290b:spec/qspec/repl_spec.qz | head -40    # pre-rename
./self-hosted/bin/quartz --no-cache <flags...> repl_spec.qz | grep -c '@strip_ansi'
# 1

./self-hosted/bin/quartz --cache-dir .quartz-cache-qspec --cache-ro \
   <flags...> repl_spec.qz | grep -c '@strip_ansi'
# 2 — llc: error: invalid redefinition of function 'strip_ansi'
```

The setup:

* `std/colors.qz` defines `def strip_ansi(s: String): String`.
* `std/qspec.qz` does `import * from colors` (and several others).
* `spec/qspec/repl_spec.qz` does `import * from qspec` AND its own
  `def strip_ansi(s: String): String` (a standalone reimplementation
  for testing — the comment at the top of the spec explains why the
  real repl module can't be imported).

Cold path: the resolver sees both `colors$strip_ansi` (re-exported as
`strip_ansi`) and `__main__$strip_ansi` (the spec's local). The local
shadows the imported one; codegen emits only one `@strip_ansi`.

Warm (qzmod-injected) path: the producer (`_qspec_prewarm.qz`) compiles
with `import * from qspec → import * from colors`, registers
`colors$strip_ansi` as unprefixed `strip_ansi` in its `.qzmod`. The
consumer's qzmod inject pre-populates the typecheck with that
unprefixed `strip_ansi`. The consumer's own `def strip_ansi` is then
treated as an *addition* rather than a *shadow*; codegen emits both,
llc rejects the duplicate.

## Why the cold path works

The cold-path resolver builds the function table fresh on every
compile. When it encounters two definitions of `strip_ansi` (one from
`import * from colors`, one from the local `def`), the local-wins
shadow rule fires and the imported entry is dropped before MIR. Only
one MIR function, one `@strip_ansi`.

The warm path receives the typecheck registry pre-baked from the
`.qzmod` artefact and never re-runs the shadow-resolution step on
qzmod-injected entries.

## Why it only bit `repl_spec`

`repl_spec` is the only spec in the suite (as of 2026-05-21) whose
local `def F` exactly matches a re-exported function name. An audit of
all 72 `colors`-exported names against `def F` in `spec/qspec/*.qz`
caught only `strip_ansi`. The closest near-misses (`style_spec`'s
`style_check_empty`, `cross_module_fixes_spec`'s `reset_globals`) use
prefixed names that don't collide.

The workaround for `repl_spec` was to rename the local to `_strip_ansi`
(commit landed alongside the prewarm-default flip). That's the
*shape* of the bug, not the *fix*: the next spec that hits the same
pattern will surface it again.

## Likely fix surface

Inside `_qzmod_inject_decode_func_sig` (or wherever consumer-side
registration happens after qzmod inject), the registration of an
imported `F` should defer to a later check: if the consumer's own
parse tree contains `def F(...)`, drop the injected entry and let the
local definition register fresh. The cold path already does this via
the resolver's shadowing rule — the warm path needs the same gate.

Alternative: enforce that the producer's `.qzmod` stores re-exports
with their *original* module prefix (`colors$strip_ansi`) regardless of
the `import * from` glob's namespace-flattening. The consumer's
`import * from qspec` would then resolve `strip_ansi` to the prefixed
entry, and a local `def strip_ansi` would be unambiguous. This is a
larger change because the existing `import * from` semantics carry
through both producer and consumer compile units.

## Workaround until fixed

Specs (and other consumer modules) MUST NOT shadow a function name that
is re-exported through a `import * from X` glob in the dependency
graph. Rename the local. Pre-launch absolutism (Quartz CLAUDE.md
"Project Reality Check") applies — there are no users blocking the
rename.

## Sister issues

* `feedback_qzmod_encoder_skips_derived_base_types.md` — related qzmod
  encoder gap (types, not functions). The shape is the same: producer
  ships an incomplete view of the registry, consumer's recovery path
  doesn't compensate.
* `CACHE_DIR_CROSS_SPEC_IR_CONTAMINATION.md` — original parent bug.
  Filed 2026-05-11 when the leak was catastrophic; the shadow-bug
  surfaced as a small residual after the major contamination paths
  were closed.

## Files touched while investigating

* `spec/qspec/repl_spec.qz` — local `strip_ansi` renamed to
  `_strip_ansi` (workaround). The function is unchanged otherwise.
