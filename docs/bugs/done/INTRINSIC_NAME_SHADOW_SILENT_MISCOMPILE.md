# INTRINSIC_NAME_SHADOW_SILENT_MISCOMPILE

**Status:** ✅ RESOLVED 2026-05-04 — typecheck now hard-errors with QZ0200.

**Filed:** 2026-05-04 (TUI v0.3.2 step 1)
**Severity:** High — silent miscompile, no diagnostic
**Surface:** typecheck (registration-time collision check)
**Trigger frequency:** Every time a user defines a function with a name that collides with an intrinsic (`to_int`, `task_id`, `sched_init`, `go_*`, `async_*`, `sb_*`, etc.).

## Symptom

User defines a function whose name collides with a registered intrinsic
(e.g. `to_int` is registered at `self-hosted/middle/typecheck_builtins.qz:1041`
as a `Fn(F64): Int` fptosi cast). The user's `def` compiles cleanly with
no warning, but every call site ignores the user function and emits the
intrinsic's codegen instead.

Memory file already documents this at `feedback_intrinsic_name_shadow.md`.

## Repro

```qz
def to_int(b: Bool): Int
  if b
    return 1
  end
  return 0
end

def main(): Int
  puts(to_int(true).to_s())   # expected: "1"; actual: "0"
  puts(to_int(false).to_s())  # expected: "0"; actual: "0"
  return 0
end
```

## Observed

- Compiles silently (no warning, no error).
- LLVM IR contains `define i64 @to_int(i64 %p0) { ... ret 1/0 ... }` —
  the user function IS emitted.
- Call sites at `qz_main` emit `fptosi double %v.f to i64` directly,
  bypassing the user function entirely.
- Output: `0\n0` (both calls fptosi-truncate the i64-erased Bool through
  the F64 path → 0).

## Expected

One of:
- (preferred) Compile-time error: "name `to_int` collides with intrinsic;
  rename or use a different name."
- Or: user function wins; warning that an intrinsic was shadowed.

## Hypothesis

`mir_lower_call` (or its callee resolver) checks the call name against
the intrinsic registry FIRST, before checking user-defined functions in
the current MIR namespace. Probably similar shape to the param-name
collision Fn-dispatch bug closed in `2026-05-03` (memory file
`feedback_param_name_collision_dispatch_bug.md`) — the lookup order is
upside-down.

The right fix is probably to add a typecheck-time collision check in
`tc_register_function` or wherever user `def` enters the symbol table:
look up the name in the intrinsic registry and emit a hard diagnostic.

Alternatively, MIR-lower can swap the lookup order so a user-defined
function shadows the intrinsic at call sites. But "intrinsic shadowed
silently" is itself a footgun, so the hard-error path is probably
better.

## Risk if unfixed

Continues being a footgun. Each new stdlib intrinsic added (Sched, Async,
Profile, Random, Exec, etc.) widens the namespace of names a user can
unknowingly collide with. The fix is bounded; the cost of leaving it
grows.

## Resolution

`tc_register_function_signature_named` (`self-hosted/middle/typecheck.qz`)
now checks every user `def NAME` against the intrinsic registry at
registration time and emits a hard error pointing at the def's source
location. Stdlib paths (`/std/`, `/self-hosted/`) are exempted so
existing stdlib defs that intentionally shadow intrinsic names (e.g.
`def str_split` in `std/string.qz`, `def unwrap` in `std/prelude.qz`)
continue to compile.

The path is resolved via `dep_graph::depgraph_path_for_ast_store`
(NOT `tc.current_file`, which is stale during the registration pass).

Regression spec: `spec/qspec/intrinsic_name_shadow_spec.qz` — 5/5 green.

**Side effect** — uncovered three pre-existing dead-code intrinsic
shadows in examples:
  - `examples/style_demo.qz` (`def str_pad_right`) — fixed in same commit.
  - `examples/string_processing.qz` (`def str_reverse`, `def str_repeat`)
    — not in the build pipeline; left for follow-up cleanup.
  - `examples/json_parser.qz` (`def is_digit`) — same.

## Known limitation

The path-prefix check is substring-based (`/std/` or `/self-hosted/`).
If a user's project lives under a directory called `std/` (rare but
possible), their defs would be falsely exempted. The robust alternative
would be a per-module `@allow_intrinsic_shadow` opt-in attribute, but
that's not worth building until someone hits the false-negative.

## Related

- `feedback_intrinsic_name_shadow.md` (memory) — earlier write-up.
- `feedback_param_name_collision_dispatch_bug.md` (memory) — sister bug,
  fixed via mir_lower_call shadow check ordering.
