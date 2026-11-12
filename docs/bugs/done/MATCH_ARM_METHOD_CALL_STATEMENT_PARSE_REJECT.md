# Method-call-as-statement inside match arm body fails to parse

**Filed:** 2026-05-07 (discovered during A.12 UFCS migration of
`examples/tui/widgets/list/main.qz`).
**Closed:** 2026-05-07 (same day). Root cause: a stale arm-boundary
heuristic at `parse_match_arm`'s extra-stmt loop treated `IDENT.` as
the start of a new arm pattern. The heuristic was added in commit
`e8d3a656` (Feb 17 2026) to guard a legacy `module.Type` qualified-
pattern syntax — that pattern syntax had zero usages anywhere in
the codebase as of HEAD `9e75e5aa`. Removed both the dead pattern-
parser branch (parser.qz:5437-5443 in the pre-fix file) and the
boundary heuristic that referenced it (parser.qz:4811). Method-call
statements at the arm body's direct indent now parse exactly like
free-fn statements.

**Severity:** Medium — blocked UFCS migration of any match arm body
that called a Void-returning method as a non-final statement. Free-
fn form (`vec_push(v, x)`) parsed fine; method form (`v.push(x)`)
did not. Diverged from the directive that UFCS dispatch is a
syntactic sugar over the free-fn form.

## Summary

When a match arm body contains a method-call **statement** (i.e.,
the result of the call is discarded, not bound or returned) followed
by another statement, the parser emits `QZ0101: Expected '=>'` at
the start of the next statement. The free-function form of the same
call parses cleanly.

## Reproducer

```qz
def main(): Int
  var v: Vec<Int> = vec_new()
  match 1
    1 =>
      var x = 5
      v.push(x)         # ← this line
      return x
    _ => return 0
  end
end
```

Compile error:

```
error[QZ0101]: Expected '=>'
 --> /tmp/repro.qz:7:7
 |
7|       return x
 |       ^
```

The parser, while still consuming the arm body, expects to see the
`=>` separator of the next match arm at the position of `return`.
Replacing `v.push(x)` with `vec_push(v, x)` parses cleanly.

## Bug shape (verified 2026-05-07)

Each variant tested at HEAD `0941e9c5`:

| Construct                                                       | Parses |
|------------------------------------------------------------------|--------|
| `arm => stmts; vec_push(v, x); return ...`                       | ✓      |
| `arm => stmts; v.push(x); return ...` (method-call as stmt)      | ✗      |
| `arm => stmts; var y = x.to_s(); return ...` (method-call bound) | ✓      |
| `arm => method_call()` (only stmt — also-final position)         | ✗      |
| `arm => if c; v.push(x); end; return ...` (nested in `if`)       | ✓      |
| `arm => while c; v.push(x); end; return ...` (nested in `while`) | ✓      |

So the trigger is specifically: **method call result discarded as
a non-binding, non-final statement at the arm body's direct indent
level**. Nested blocks (`if`/`while`/`for`/`do`) inside the arm body
parse method-call-stmts cleanly — those use the generic statement
parser. Whether the method is `.push`, `.to_s()`, or any other
zero-arg / one-arg method makes no difference — the
receiver-followed-by-`.method(args)` shape *at the arm body's
direct indent* is what the parser misreads.

**Scope refinement (2026-05-07 bundle 7):** The nested-block-safe
case was confirmed by migrating `examples/tui/widgets/text_input/
main.qz`'s two `new_history.push(...)` sites — one inside `while`
inside `if`, the other inside `if` — both inside a
`tui::FrameMsg::Key(k) =>` arm body. Both compile + link clean.
Practical consequence: a trap-density file is one where the
`vec_push` sites are at the arm body's immediate indent (post `=>`,
before any nested control-flow), not its nested-block bodies. The
arm-body-only restriction makes the trap less broad than a naïve
"any vec_push inside any match" scan would suggest.

## Root cause hypothesis (untested)

Match arm body parsing reads statements until it sees a new arm
pattern (terminated by `=>`). The lookahead probably uses the
free-fn-call shape `IDENT(...)` to recognize statements, but the
post-call-paren `.method(...)` continuation isn't handled when the
result is discarded — the parser walks off the end of the inner
expression and starts looking for the next arm pattern at the wrong
position.

A bound result (`var y = ...method(...)`) parses fine because the
binding-statement parse path is separate.

## Workaround

Either:
- Bind the result: `var _ = v.push(x)` — preserves UFCS form.
- Keep the free-fn form: `vec_push(v, x)` — drops the migration
  for that one site.

Both are workarounds, not fixes. The bug is in the parser.

## Pre-flight scope (verified 2026-05-07)

Triggered live during `examples/tui/widgets/list/main.qz` migration
(commit `0941e9c5`'s sequel) at one site:

```qz
match ev
  Selected(card) =>
    var new_played = _clone_played(s.played)
    new_played.push(card)        # ← parser rejects
    return (State { ... }, ...)
  ...
end
```

That single site reverted to `vec_push(new_played, card)` to ship
the rest of the bundle. Repo-wide scan for the pattern (`grep -A 3
'=>' --include="*.qz"`) is impractical without a real AST query;
expect more sites in dogfood-heavy directories (`examples/tui/`,
`std/tui/`, `tools/`).

## Suggested fix paths

**Path A — fix parser**: extend the match-arm body parser to
recognize method-call-as-statement post the inner call's closing
paren. Likely a one-token lookahead in `parse_match_arm_body` (or
equivalent) — after consuming an expression statement, peek for `.`
or whatever continuation token would extend it.

**Path B — diagnose**: emit a clearer error message pointing at the
method-call form so the migration knows to use the workaround. Less
valuable than fixing it.

## Discoverability

Surfaced 2026-05-07 during A.12 UFCS bundle 5 (`examples/tui/widgets/
list/main.qz`). Reproduces deterministically at HEAD with the four
test cases above.

## Resolution (2026-05-07)

Took **Path A**, but with a smaller scope than originally framed.
The hypothesis section was right that match-arm body parsing was
the culprit; what it missed was that the `IDENT.` boundary check
was a deliberate addition (commit `e8d3a656`, Feb 17 2026) to
support a `module.Type { ... }` legacy pattern syntax. Confirming
that legacy syntax has zero usages anywhere in the codebase let
both pieces come out together:

```diff
--- a/self-hosted/frontend/parser.qz
+++ b/self-hosted/frontend/parser.qz
@@ -4808,9 +4808,15 @@ def ps_parse_match_arm(ps: ParserState): Int
         if peek_type == token_constants::TOK_DOUBLE_COLON or peek_type == token_constants::TOK_FAT_ARROW or peek_type == token_constants::TOK_LT
           break
         end
-        if peek_type == token_constants::TOK_DOT or peek_type == token_constants::TOK_IF
+        # `IDENT.` is a method-call/field-access continuation, NOT
+        # a new arm boundary. The legacy `module.Type` pattern
+        # syntax that this check used to guard has been removed
+        # (zero usages repo-wide; modern form is `module::Type`).
+        # `IDENT if` is an arm guard (`n if n > 5 =>`), still real.
+        if peek_type == token_constants::TOK_IF
           break
         end
@@ -5435,12 +5441,6 @@ def ps_parse_pattern(ps: ParserState): Int
   if ps_current_type(ps) == token_constants::TOK_IDENT
     var name = ps_current_lexeme(ps)
     ps_advance(ps)
-
-    # Check for module.Type qualified pattern
-    if ps_check(ps, token_constants::TOK_DOT)
-      var module_name = name
-      ...
-    end
```

Verification:
- All 4 bug-doc test cases now produce expected outcomes (cases
  1, 2, 3 parse cleanly; case 4 reaches typecheck).
- 6 pattern/match qspec files green: stress_pattern_matching,
  match_guard, match_guards, or_pattern, pattern_binding,
  match_exhaustiveness, nested_qualified_variant_pattern.
- 3 previously-deferred A.12 sites re-migrated and binary-built
  clean: `cards/main.qz:80`, `settings/main.qz:82-86`,
  `list/main.qz:109`.
- `quake guard` fixpoint (gen1 == gen2) at 2146 functions.
- Rule 2 smokes (style_demo + brainfuck) green.

The fix is structural — the bug went away because the dead-syntax
support that caused it was removed entirely, not patched around.
