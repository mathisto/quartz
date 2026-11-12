# Doc soft-notes — 2026-07-07 (SURF.7b doc-truth pass)

Low-priority follow-ups surfaced by the doc-truth scout (item 1c) during the
SURF.7b stat-refresh. Neither is a doc bug requiring an edit today; both are
"verify / consider hardening" notes.

## SN-1 — Verify REF:~530 bare-typed-arrow claim (INCONCLUSIVE)

`docs/QUARTZ_REFERENCE.md:~530` claims a bare typed-arrow lambda at statement
level (`x: Int -> expr`) mis-parses as a var declaration. Repro
`x: Int -> x + 1` as a bare statement **COMPILED without error**, contradicting
the "rejects/mis-parses" implication. Could still be parsing as
var-decl-then-lambda-body and type-checking benignly.

Blocked: could not capture `--dump-ast` — the `--dump-ast` + `-I` flag combo
emits CLI help text instead of the AST dump (a flag-parsing interaction).
Needs a clean AST-shape dump to decide "doc stale" vs "doc right, compiles
benignly." Do NOT edit the doc on current evidence.

## SN-2 — Lambda named-args silently dropped (minor wart, REF:~354)

`docs/QUARTZ_REFERENCE.md:~354` correctly states named arguments are "Not
supported for builtins or lambda calls" — the doc is truthful. The wart: for a
lambda `f = (a, b) -> a - b`, the call `f(b:3, a:10)` did NOT error; the names
were **silently ignored and applied positionally** (ran as `3 - 10`, exit
249 = -7). Consider hardening to a type/parse error rather than silently
dropping the names. Low priority; not a doc fix.
