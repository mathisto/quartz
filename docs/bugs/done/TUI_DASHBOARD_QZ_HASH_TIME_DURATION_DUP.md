# Dashboard example IR has duplicate `qz_hash_time$Duration`

**Filed**: 2026-05-07 (during VIGIL Phase 1 mouse-parsing work).
**Severity**: Build failure for `examples/tui/dashboard/main.qz` under `--no-cache`. Predates the mouse work; not blocking Phase 1.

## Symptom

```
$ ./self-hosted/bin/quartz --no-cache -I std examples/tui/dashboard/main.qz > /tmp/dash.ll
$ llc -filetype=obj /tmp/dash.ll -o /tmp/dash.o
llc: error: llc: /tmp/dash.ll:79246:12: error: invalid redefinition of function 'qz_hash_time$Duration'
define i64 @qz_hash_time$Duration(i64 %key) nounwind {
```

LLVM IR contains two `define i64 @qz_hash_time$Duration(...)` blocks. llc rejects the redefinition.

## Reproduction

1. `rm -rf .quartz-cache`
2. `./self-hosted/bin/quartz --no-cache -I std examples/tui/dashboard/main.qz > /tmp/d.ll`
3. `llc -filetype=obj /tmp/d.ll -o /tmp/d.o` → fails with "invalid redefinition"

Reproduces with **and** without the mouse-parsing changes. The dashboard's import graph (`tabs`, `status_bar`, `overlay`, `help`, `layout`, `terminal`, `time`, `style`) appears to pull `std/time::Duration`'s hash impl twice.

## What's NOT affected

- `spec/qspec/spark_widget_spec.qz` — clean
- `spec/qspec/sys_proc_parser_spec.qz` — clean
- `spec/qspec/term_mouse_spec.qz` — clean
- `/tmp/mouse_demo.qz` (mouse smoke importing runtime + terminal only) — clean

## Hypothesis

Hash-impl emission for `Duration` is happening once in the user-side codegen path AND once in a stdlib re-emit path (e.g. through both `std/time` direct and a transitive import via a widget). The dedupe gate that protects most struct hash impls is missing or misfiring for `Duration`.

Probably lives in `self-hosted/backend/codegen.qz` (struct hash impl emission) or `self-hosted/backend/codegen_separate.qz` (incremental boundary).

## Status

- **Closed 2026-05-07.**

## Resolution

Pure dedupe miss. The two `qz_hash_time$Duration` blocks were
byte-identical — same FNV-1a body for the same single-field
`Duration { nanos: Int }` struct.

Root cause: the dashboard imports `std/time` directly (`import time`)
AND transitively via `std/tui/runtime` (`import time` inside that
module). The dep-graph produces two ast_stores for the same source
file (`std/time.qz`), and `mir_collect_structs` runs once per ast_store
without checking whether a given struct name was already registered.
Downstream `cg_emit_struct_hash_eq_functions` iterates the registry
blindly and emits `qz_hash_<name>` / `qz_eq_<name>` twice → llc
rejects with "invalid redefinition".

Fix at `self-hosted/backend/mir.qz` `mir_ctx_register_struct`: skip
registration when a struct with the same name is already in the
registry. Two registrations of the same name from the same source
file are guaranteed byte-identical (same parser output); silently
skipping is correct. If two different sources ever register
conflicting fields under the same name, that's a separate bug
(typecheck rejects QZ0xxx duplicate-struct-def at the source layer
before MIR-lower runs).

The dashboard example builds clean under `--no-cache` post-fix; one
`define i64 @qz_hash_time$Duration` block survives, llc + clang both
succeed.

## Sister gap (deeper root cause, not closed by this fix)

The dual-ast-store-per-source-file behavior of the dep-graph is the
underlying bug. Multiple modules importing the same source via
different path forms (`time` vs. `std/time`) should canonicalize to
one ast_store. The dedupe-at-registration fix above is a defensive
patch; the root cause work would live in `self-hosted/dep_graph.qz`
(canonical path resolution) and is out of scope for this closure.

The same axis is likely behind `MAP_GET_INT_KEY_TYPE_OVERRIDES_RECEIVER_LAYOUT`'s
sister `@.str.15` undefined-IR bug — the parameterized-Map binding's
struct-hash-impl emission may also depend on dual-namespace paths.

## Related

- `feedback_cache_namespace_dual.md` — dep-graph keys are import
  paths; cache fragments use short names. The mismatch surfaces here
  as ast_store proliferation.
