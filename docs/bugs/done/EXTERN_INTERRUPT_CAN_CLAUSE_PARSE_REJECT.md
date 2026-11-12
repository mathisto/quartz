# `extern "x86-interrupt" def f(...): T can E` rejected by parser

> **Filed**: 2026-04-30 during Phase E of the Sched-effect work
> (`docs/handoff/sched-effect-thread-safety-kickoff.md`).
> **Status**: CLOSED 2026-05-06 — parser threads `ps_parse_can_row`
> after the return-type parse on the with-body extern path; the
> resulting row is attached to the NODE_FUNCTION via
> `ast_func_set_can_row`, so existing `tc_attach_func_effect_row`
> picks it up unchanged. Bodyless extern decls reject `can` clauses
> explicitly (no body to constrain). Regression spec at
> `spec/qspec/extern_interrupt_can_clause_spec.qz`.
> **Impact**: low — the I/O poller pthread (PSQ-6 root cause) is
> annotated via `sched_idle_hook_set` and `_live_idle_render`. ISRs
> can now be annotated; `tools/baremetal/hello_x86.qz` re-annotation
> is the next step when KERN.8 SMP work surfaces a need.

## Reproducer

```be
extern "x86-interrupt" def my_isr(frame: Int): Void can Sched
  ...
end
```

```
error[QZ0101]: Expected newline
    --> file.qz:N:M
    | 
N | extern "x86-interrupt" def my_isr(frame: Int): Void can Sched
    |                                                ^
```

The design memo (`docs/design/SCHED_EFFECT_THREAD_SAFETY.md` §3.2)
claimed *"The parser already accepts `can E` on `extern` defs (B.4
row-poly work)"*. That claim was wrong — the parser path for
`extern "<conv>" def ...` consumes `: ReturnType` and then expects
a newline, not a `can` keyword.

## What works

- `@panic_handler def f(msg: String): Void can Sched` (regular
  def with attribute) — accepted. Verified during Phase E.
- `def f(): Int can Sched` (regular def) — accepted, exercised by
  Phase B's `_live_idle_render` annotation in `std/progress.qz`.

## Fix sketch

The parser's extern-def branch (search `parser.qz` for
`"x86-interrupt"` / `extern "C"` handling) needs to thread a
`ps_parse_optional_can_clause` after the return-type parse, mirroring
the regular-def path. Wire the resulting row through to
`tc_attach_func_effect_row` via the already-existing AST slots
(`ast_func_get_can_label_csv` etc.) — extern def ASTs go through
the same row-attach pipeline today.

Estimated effort: 30-60 LOC parser change + verify with
`tools/baremetal/hello_x86.qz` ISR re-annotation.

## When to pick this up

When the unikernel SMP work (KERN.8) makes interrupt-context Sync
discipline relevant in practice. Until then the ISRs in
`tools/baremetal/hello_x86.qz` rely on the convention that they
don't allocate or touch shared state outside Atomic/lock-free
primitives — the current bodies satisfy that informally.
