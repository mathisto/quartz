# Piezo — `await` keyword as op-filter in `with` block hangs compiler

**Severity**: Medium. Was blocking `with Async { await: my_handler } do ... end` user-override pattern — the intended way to customize scheduler behavior per P3.B's H-delegate design.
**Discovered**: 2026-04-21 while writing the P3.C.4 broader e2e spec.
**Status**: ✅ FIXED 2026-04-21. Commit will update this line with the sha when landed. Regression guard: `spec/qspec/struct_init_keyword_field_spec.qz` (3 tests) + the user-override test at the end of `piezo_async_await_migration_p3c_spec.qz`.

## Fix

Two sites in `self-hosted/frontend/parser.qz` (regular `Point { x: 1 }` and generic `Box<T> { v: 0 }` struct init). Both had the pattern:

```
while ps_check(ps, TOK_RBRACE) == 0
  ps_expect(ps, TOK_IDENT, "Expected field name")
  ...
```

Replaced with a dispatch that accepts `TOK_IDENT` or any reserved-keyword token (via the existing `_ps_is_reserved_ident_token` helper), and falls to an explicit `break` on unexpected tokens — so genuinely malformed input terminates the loop rather than spinning on the same non-advancing error.

## Minimal repro

```quartz
effect MyEff
  def await(h: Int): Int
end

def my_await(op: Int, argc: Int, argv: Int): Int = 999

def main(): Int
  with MyEff { await: my_await } do ->
    puts("inside")
  end
  return 0
end
```

Compile with any recent binary. Hangs indefinitely at 99% CPU, RAM grows unboundedly.

## Not reproducible with non-keyword op name

Rename both the op decl and the filter key from `await` → `xwait`: compiles cleanly in <1 second. Same applies to other reserved keywords (likely `async`, `go`, `spawn`, etc. — untested).

## Hypothesis

`await` lexes as `TOK_AWAIT`. The op-filter map syntax `{ await: handler }` parses `await` in a position where the parser expects an op-name identifier. The reserved-keyword-as-identifier allowance for trait/effect bodies (`ps.in_trait_body == 1` path in `ps_parse_function`) is present at op **declaration** sites but doesn't extend to op-filter **use** sites. Recovery loop on the unexpected token likely fails to advance, consuming CPU on `ps_error` without advancing the position. (Compare `feedback_quartz_parser_conventions.md` — `ps_error` does not advance by default; recovery loops need explicit break.)

## Where to look

- `self-hosted/frontend/parser.qz`: find the op-filter map parser for `with Eff { k: v, k: v }` (parses NODE_WITH's handler narrowing).
- Check what token type it expects as key. Add TOK_AWAIT (and siblings: TOK_ASYNC, TOK_GO, TOK_SPAWN, TOK_YIELD) to the accept list alongside TOK_IDENT. Or better: use `_ps_is_reserved_ident_token` which already exists for this pattern.

## Workaround

Until fixed, user override of `Async.await` isn't usable via surface syntax. The default handler path (P3.C.3 busy-poll-and-resume_cont) works unconditionally. Tests that want to verify override semantics use a non-keyword op name on a non-Async effect.

## P3.C.4 impact

The P3.C.4 e2e spec does NOT include a user-override-of-await test because of this bug. Chained awaits, nested async pyramids, and eager-done fast-path are covered. Add the user-override test in the follow-up commit that fixes this parser hang.

## Follow-up priority

Low-medium. Blocks a design-intended use case (user schedulers) but has a documented workaround. Fix before P3.G's deletion commit — the migration should land with the user-override path validated, not just the default handler.
