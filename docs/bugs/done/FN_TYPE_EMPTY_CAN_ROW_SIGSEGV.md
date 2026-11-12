# `Fn(...): T can` (empty closed row, no label) SIGSEGVs in `tc_parse_type_impl`

> **Filed**: 2026-05-01 during A.5b Phase 1 (Fn-typed local Sched discipline).
> **Status**: ✅ CLOSED 2026-05-02. Fixed at all 6 `_can_idx + 5` call sites
> across `typecheck.qz`, `typecheck_expr_handlers.qz`, and `typecheck_walk.qz`.
> 4-test regression spec at `spec/qspec/fn_empty_can_row_spec.qz`. Fixpoint
> 2459 functions byte-identical. Bug doc was scoped to `Fn(...): T can` but
> `impl Trait can` (e.g. `def f(): impl Iterator<Int> can`) shared the same
> root cause and is also fixed.

## Root cause and fix

`_tc_find_last_can_marker` matches the literal " can" 4-byte sequence and
returns the position of the leading space. The marker correctly accepts both
trailing-space (" can ...") and end-of-annotation (" can\0") cases. Six call
sites then computed the suffix slice as `str_byte_slice(ann, _can_idx + 5,
str_byte_len(ann))` — `+5` was the offset to skip past " can " (5 chars,
including the trailing space). For end-of-annotation matches there is no
trailing space, so `start = _can_idx + 5 > str_byte_len(ann)` produced
`len = end - start = -1`, which `qz_alloc_str(-1)` and `memcpy(buf, src, -1)`
both interpreted as a huge unsigned value → SIGSEGV.

Fix: change `+5` → `+4` at all 6 sites. `str_trim` (called either inline at
the receiving sites or inside `_tc_resolve_fn_can_suffix`) handles any
leading whitespace from the trailing-space case. Empty closed row remains
semantically equivalent to no `can` clause.

Sites fixed:
- `typecheck.qz:1162` (`impl Trait` return type)
- `typecheck.qz:1529` (`Fn(...): T` parameter / local type)
- `typecheck_expr_handlers.qz:1772` (callback Fn-annotation widening)
- `typecheck_walk.qz:889` (Iterator-trait Async detection)
- `typecheck_walk.qz:4332` and `:4531` (impl-trait param row binding)

## Reproducer

```be
def my_render(): Void
  puts("ok")
end

def main(): Int
  var f: Fn(): Void can = my_render
  return 0
end
```

`./self-hosted/bin/quartz` exits with 139 (SIGSEGV). No diagnostic emitted.
The parser at `parser.qz:798-816` accepts the form (the `can` clause's label
and `| tail` are both optional in the grammar), so `let_type_ann` becomes
the literal string `"Fn(): Void can"`. Downstream, `tc_parse_type` →
`tc_parse_type_impl` calls `_platform_memmove` on a probably-out-of-bounds
slice of the empty suffix.

## Crash signal

```
exception: EXC_BAD_ACCESS / SIGSEGV / KERN_INVALID_ADDRESS at 0x00005fffffffffff
frame: typecheck$tc_parse_type_impl + 25808
       → _platform_memmove
```

Crash report at `~/Library/Logs/DiagnosticReports/quartz-2026-05-01-103514.ips`
during the A.5b sprint (commit hash forthcoming).

## Root-cause hypothesis

`_tc_resolve_fn_can_suffix` in `typecheck.qz:1033` accepts an empty suffix
(`""` — bare empty closed row, line 1026 explicitly documents it) and
returns a row with no labels and no tail var. The crash is in
`tc_parse_type_impl`, not `_tc_resolve_fn_can_suffix`, so it's likely upstream
in how the suffix string is sliced from the type annotation. A boundary
case where `pipe_idx == -1` AND `suffix == ""` may produce a negative-length
or out-of-range memmove. Needs lldb to confirm.

## Workaround

User code never writes `Fn(...): T can` with no label. The case is grammatical
but semantically pointless (it's equivalent to no `can` clause at all). The
A.5b QZ1408 check on Fn-typed locals (`typecheck_expr_handlers.qz`) handles
the only realistic shapes the user would write:

- `var f: Fn(): Void = bare`           — no `can`, fires QZ1408 ✓
- `var f: Fn(): Void can Sched = ...`   — explicit Sched, passes ✓
- `var f: Fn(): Void can | r = ...`    — open row tail, passes ✓
- `var f: Fn(): Void can OtherLabel`    — wrong label, fires QZ1408 ✓
- `var f: Fn(): Void can` (this bug)    — SIGSEGV ✗

## Fix direction

Either:
1. Reject the empty-can-row at parse time (`parser.qz:802` should require
   either an IDENT or a `|` after `TOK_CAN` at the Fn-type level).
2. Make `tc_parse_type_impl` robust to the empty suffix (the more general
   fix — any malformed type annotation shouldn't crash the typechecker).

Option 1 is ~5 LOC, option 2 needs lldb to localize. Defer until a real
user complaint surfaces — the workaround (write `can <Label>` or omit
`can` entirely) is trivial.
