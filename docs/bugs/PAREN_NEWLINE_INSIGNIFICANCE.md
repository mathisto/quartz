# PAREN_NEWLINE_INSIGNIFICANCE

**Filed:** 2026-06-02 (follow-up to MULTILINE_BINARY_OPERATOR_SILENTLY_DROPPED)
**Severity:** Low — ergonomics. A fully-working alternative exists (trailing-operator continuation).
**Status:** Open — deferred by design.

## Want

Make newlines insignificant inside `( )` / `[ ]`, so a binary expression can
be split across lines with the operator **leading** the continuation line
(the style PEP 8 now recommends, and what Python / Haskell allow):

```quartz
var c = (lane(0)
         ^ lane(1)
         ^ lane(2)
         ^ lane(3))
```

Today this is `QZ0103` (the `^` lines are seen at statement-start position).
Only the **trailing**-operator form works without parens:

```quartz
var c = lane(0) ^
        lane(1) ^
        lane(2)
```

## Why deferred

1. **Not a correctness gap.** The silent miscompile is closed (QZ0103); a
   correct, documented multi-line idiom exists (trailing operator).
2. **Leading-operator continuation is only safe inside brackets.** Outside
   parens it re-introduces silent behavior — `foo()` ⏎ `< 3` would silently
   become a discarded comparison. Python's model (continuation only inside
   `()` `[]` `{}`) is the right design precisely because there is no statement
   boundary inside brackets.
3. **The implementation is sprawling.** The expression parser is
   precedence-climbing across ~10 levels (`ps_parse_or` → … → `ps_parse_primary`
   in `self-hosted/frontend/parser.qz`). Each level skips newlines *after* an
   operator (that's why trailing-operator works) but stops at NEWLINE after an
   operand. Supporting leading-operator-in-parens means threading a paren-depth
   flag through every level and skipping newlines before the next-operator
   check when depth > 0. That's a real, risky change to the hottest parser path
   for a pure-ergonomics win — it deserves its own focused session, not a
   stacked rider.

## Design (when pulled in)

Add `paren_depth: Int` to `ParserState`; bump on `(`/`[` and drop on `)`/`]`
within expression parsing. In each precedence-climbing loop, when
`paren_depth > 0`, call `ps_skip_newlines` before the `ps_check(<operator>)`
test. The lexer continues to emit NEWLINE unconditionally (statements outside
brackets keep their boundaries); only the in-bracket expression parser ignores
them. Mirror the existing post-operator `ps_skip_newlines` so both lead/trail
forms work inside parens.

## Pull-in trigger

A real consumer that strongly prefers the vertical leading-operator fold, or a
dedicated parser-ergonomics pass. Add regression arms asserting both
lead/trail forms compute correctly inside parens, and that the bare
(paren-less) leading form still errors QZ0103.
