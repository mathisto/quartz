# Incremental cache: cached `__main__.ll` contains `%push` undefined-value loads

## Status

**CLOSED 2026-05-03.** MIR-lower's `mir_lower_call` now applies a UFCS
rewrite fallback for `is_ufcs == 1` calls when typecheck's body-walk was
skipped (the asymmetry between TC at quartz.qz:813 — gated on recompile
set — and MIR at mir_lower.qz:5212 — "always lowers all functions"). The
fallback consults `mir_infer_expr_type(args[0])` to resolve the receiver
type and applies the canonical method rewrite via the new
`mir_ufcs_canonical(recv_type, method)` helper in mir.qz. Coverage
extended to global vars (PASS 0.6 captures NODE_LET str2 annotations into
the global registry, with parallel global_types vector kept in sync
through PASS 0.8 const-decl pushes), function parameters (new
`mir_ctx_lookup_param_type` helper exposes primitive Int/Bool/F64 annotations
that `mir_ctx_mark_struct_var` deliberately skips), and arithmetic
NODE_BINARY (Int OP Int → Int propagation in mir_infer_expr_type). Common
Int-returning intrinsics (`str_byte_at`, `str_byte_len`, `vec_size`,
`map_has`, `time_mono_ns`, `time_mono_ms`, `__map_get_raw`, `str_size`)
now return "Int" from `mir_intrinsic_return_type` instead of "" so derived
locals (`var c = str_byte_at(s, i); c.to_s()`) get tracked.
`sb_new`/`sb_new_with_capacity` now return "StringBuilder" so
`var sb = sb_new(); sb.append_char(c)` resolves to `sb_append_char`.

Original framing below kept for reference.

Filed 2026-05-03 alongside the QZ0603 warning closure (see
[`QZ0603_INCREMENTAL_FIELD_ACCESS.md`](QZ0603_INCREMENTAL_FIELD_ACCESS.md)).
The original QZ0603 doc described the runtime symptom as `index out of
bounds: index 0, size 0`; the failure mode at file time was an llc-level
`use of undefined value '%push'` IR rejection. Either the bug shape
changed since 2026-04-22 (more likely, given intervening MIR-lower work)
or the original framing missed this layer.

## Symptom

After a warm-cache compile of certain QSpec suites (specs that use
`assert_compile_*` from qspec/subprocess and that pull in `std/progress`
transitively), `llc` rejects the emitted IR with:

```
llc: error: <spec>.ll:<line>:23: error: use of undefined value '%push'
  %v2 = load i64, ptr %push, align 8
                      ^
```

The faulting line lives in `_spin_register` (and similar
`_spin_frames_registry.push(frames)` patterns) inside the cached
`__main__.ll` fragment. Affected functions all share the shape:

```quartz
var _spin_frames_registry: Vec<Vec<String>> = vec_new()

def _spin_register(frames: Vec<String>, interval_ms: Int): Int
  _spin_frames_registry.push(frames)
  ...
end
```

## Reproduction

```bash
rm -rf .quartz-cache
for spec in actor_spec effect_handler_narrow_spec effect_integration_spec; do
  ./self-hosted/bin/quartz \
    -I self-hosted/frontend -I self-hosted/middle \
    -I self-hosted/backend -I self-hosted/shared -I std -I tools \
    spec/qspec/${spec}.qz > /tmp/${spec}.ll 2> /tmp/${spec}.err
done
llc -filetype=obj /tmp/effect_integration_spec.ll -o /tmp/eis.o
# → llc: error: ... use of undefined value '%push'
```

The third compile in the sequence is the one that fails (cache populated
by compiles 1+2, third compile pulls cached fragments).

The same recipe also reproduces at HEAD before the QZ0603 fix, so this
issue is independent.

## What the cache contains

```bash
grep -c '%push' .quartz-cache/modules/__main__.ll
# → ~80 hits across _spin_register and similar functions
```

The cached `__main__.ll` was emitted by an earlier compile when the
function's body was MIR-lowered with a missing receiver-type for
`_spin_frames_registry`. Without a known receiver type, MIR-lower's UFCS
dispatch for `.push` falls through to the field-access path, treating
`push` as a local variable to load → `%push` undefined.

## Suspected mechanism

`_spin_frames_registry` is a top-level global typed `Vec<Vec<String>>`.
For MIR-lower to dispatch `_spin_frames_registry.push(...)` to
`vec_push(...)`, `mir_infer_expr_type` must return `Vec<...>` for the
receiver IDENT. For a global var, that means either:

1. The type annotation is propagated to the IDENT node's `str2` slot
   during typecheck (typically by `tc_expr` at NODE_IDENT), AND
2. MIR-lower's `_mir_infer_expr_type` for NODE_IDENT consults the
   annotation (currently it only consults `mir_ctx_get_var_type`, which
   tracks per-function locals + parameters — not module-level globals).

In incremental mode where the cache stores module-level LL fragments,
the cached fragment for `progress` was emitted when one of these layers
failed for `_spin_frames_registry`. Subsequent warm-cache compiles re-use
the bad fragment.

## Investigation path

1. Confirm whether the bug is in
   (a) `mir_infer_expr_type`'s NODE_IDENT path missing global-var type
       lookup, or
   (b) typecheck's IDENT walk failing to set `str2` for global var
       references in some context.
2. If (a): extend `mir_infer_expr_type` to consult a global-vars type
   table (populated during PASS 0 / module-globals walk).
3. If (b): trace why typecheck doesn't annotate the IDENT node — possibly
   related to the `current_file` plumbing during incremental TC, or to
   the global-vars walk being gated on recompile_set.
4. Once the fresh emit is correct, invalidate cached fragments that
   contain `%push` and verify warm-cache sequence stays clean.

## Why filed-not-fixed

Diagnosis from the QZ0603 closure session was scope-bounded to the
warning surface; this codegen issue is a deeper investigation into
incremental-cache fragment poisoning that needs its own session. The
`--no-cache` workaround documented in QZ0603_INCREMENTAL_FIELD_ACCESS.md
is sufficient for QSpec runs in the meantime.

## Cross-references

- [`QZ0603_INCREMENTAL_FIELD_ACCESS.md`](QZ0603_INCREMENTAL_FIELD_ACCESS.md)
  — sister bug, warning surface closed 2026-05-03.
- `feedback_quartz_cache_pollution.md` (memory) — broader incremental-cache
  cross-binary pollution pattern; this is a within-single-binary
  cross-spec variant.
