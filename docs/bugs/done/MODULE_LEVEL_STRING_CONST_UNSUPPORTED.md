# Module-level string `const` unsupported (const-eval is integer-only)

**Status:** ✅ FIXED 2026-06-08. Module-level `const`s of **any** non-integer type
(string AND float — the float case was broken too, contrary to the original
filing) now compile and work. The fix was far smaller than the "correct fix
(sequencing)" below estimated — no tagged const-value representation was needed;
the string and float codegen paths already existed (string → `gstr_inits`,
float/expr → runtime-init global, the same lowering a module-level `var` uses).
Two real defects were in the way:

1. **stdout corruption** — `mir_const_eval_full` (and the dead simple
   `mir_const_eval`) `puts`-ed `unsupported node kind` to **stdout** when an init
   wasn't integer-foldable. stdout is the IR channel, so this corrupted the `.ll`.
   But an unevaluable-as-integer init is NOT an error — it's a clean fall-back to
   the string/runtime-init path. Removed both `puts` (silent return 0).
2. **PASS 0.8 indexing bug** (the deeper one, exposed once floats compiled) — the
   const ctx-registration pushed string/evaluable const names into the SAME
   `global_names` vector that PASS 1.5 pairs 1:1 with `global_init_nodes`, but
   WITHOUT a matching init-node. A string const before a runtime-init (float)
   const therefore shifted the index and stored the float's init expr into the
   string's global (observed: `const S="x"` before `const F=0.5` left `F` at 0).
   Fixed by deferring those init-node-less ctx pushes to after the loop — the
   same discipline PASS 0.8b already uses for global-var aliases.

**Closed by:** `self-hosted/backend/mir_const.qz` (remove stdout puts) +
`self-hosted/backend/mir_lower.qz` PASS 0.8 (defer const ctx-registration). Spec
`spec/qspec/module_const_spec.qz` (6 tests). Guard fixpoint byte-identical.

**Severity (historical):** medium (language gap; also blocked string `#define` translation in `@cImport`)

## Symptom

A module-level `const` bound to a string literal fails to compile. The compiler
prints `const_eval_full: unsupported node kind` to **stdout** (corrupting the
emitted `.ll`) and exits 0, so the downstream `llc` fails with
`expected top-level entity` rather than a clean diagnostic.

```quartz
const VERSION = "1.0"     # const_eval_full: unsupported node kind
def main(): Int
  return 0
end
```

Reproduces whether or not the const is used. Integer/hex/float module consts
(`const X = 64`, `const X = 0x10`, `const X = 3.14`, `const X = OTHER + 1`) all
work — only non-integer (string) values fail.

## Root cause

The module-const folding pass (`mir_lower.qz:6199`, PASS that builds
`const_names_prog` / `const_values_prog`) eagerly folds **every** module const to
an `Int` via `mir_const::mir_const_eval_full` (`mir_const.qz:228`), whose return
type is `Int` and whose backing store (`const_values: Vec<Int>`) is
integer-only. A string-literal initializer reaches the evaluator's
unsupported-node branch (`mir_const.qz:155`), which `puts` the error to stdout
and yields a garbage value.

This is an integer-const subsystem, not a value-const subsystem.

## Correct fix (sequencing)

Module-level non-integer consts need a tagged const-value representation
threaded through the const subsystem and codegen:

1. Give the const store a value kind (int / string / float-bits) instead of a
   bare `Vec<Int>` — or special-case string-literal inits.
2. For a string const, lower it as a global string constant (the same mechanism
   used for string literals inside function bodies) and bind the const name to
   that global, **bypassing** the integer `const_eval_full` path.
3. Emit a proper diagnostic (to stderr, with a source span) for genuinely
   unevaluable const inits, instead of `puts`-to-stdout + exit 0.

Step 3 is independently worth doing — the stdout corruption + exit-0 is a
latent footgun for any const-eval failure, not just strings.

## Current mitigation

`@cImport` (`cimport_gen.qz cimport_classify_macro_value`) does **not** emit
string `#define`s — they are surfaced as `# cimport: skipped macro NAME` comments
(D5: never emit a binding that won't compile). Integer/hex/float `#define`s are
translated. Once module string consts land, drop the string skip in
`cimport_classify_macro_value` and re-add the string-literal branch.
