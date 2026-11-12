# JSON spec failures — float / unicode-escape parsing regressions

**Filed:** 2026-05-07 (discovered while shipping A.12 UFCS bundle 2 — tools/quake + json + colors).
**Severity:** Medium — production json_parse fails on float values and unicode-escaped strings; spec captures the regressions but they're red on `trunk` HEAD without a tracked entry.

## Summary

Multiple json_spec regressions on `trunk` (verified at `62689a6f`, the
HEAD before this bundle started). Failures pre-exist and are NOT
caused by the A.12 UFCS migration in std/json.qz (verified by running
the specs at HEAD via `git stash`).

### json_spec.qz — 10/18 pass, 8 fail

- **parses JSON object** — `assert_eq(json_is_object(v), true)` returns 0
- **parses a float value** — `json_parse("3.14")` returns Null
- **parses a negative float** — `json_parse("-2.5")` returns Null
- **parses scientific notation** — expected 0, got 1
- **parses float in object** — fails downstream of float parse
- **distinguishes integers from floats** — fails on the float side

The float failures suggest `json_parse_float` (lexer/parser path) is
broken or `json_is_float` predicate is mismatched.

The "parses JSON object" failure with a numeric truth check (1 vs 0)
suggests a Bool/Int conflation somewhere in the parse path.

### json_edge_cases_spec.qz — 5/8 pass, 3 fail

- **parses ascii unicode escape** — `A` not yielding `"A"`
- **parses 2-byte unicode escape** — `é` not yielding `é`
- **parses 3-byte unicode escape** — `€` not yielding `€`

`\uXXXX` escape decoding broken in the json lexer's string parser.

### json_float_spec, json_pretty_spec, json_ufcs_spec

Have failures too — not enumerated here, but `green=0` on all three
in the bundle 2 sweep. Likely same root causes (float + unicode escape).

## Likely root causes

Two candidates worth investigating:

1. **Float lexer regression.** `json_parse("3.14")` returning Null
   means the lexer's `Number` token isn't matching `3.14` and
   probably emitting `Number("3")`. or the parser drops the
   fractional part. Either way, the float-vs-int discrimination
   isn't surviving the lexer→parser handoff.

2. **String escape decoder regression.** `\uXXXX` not decoding to
   the correct codepoint suggests either (a) the hex parse fails
   silently and falls through to the literal `A` string, or
   (b) the `str_from_codepoint` builder is producing wrong bytes.

Both could be artifacts of the FIX.2 codepoint-vs-byte change
(commit `4623b454`) — that flip changed string semantics, and json's
lexer was likely written under byte assumptions.

## Verification done in this session

- json_spec 10/18 with my UFCS changes (bundle 2 working tree).
- json_spec 10/18 with `git stash` reverting my changes (HEAD state).
- IDENTICAL pass count → bundle 2 changes are neutral; failures
  pre-exist.

## Suggested next-session approach

1. Run `git log -- std/json.qz` to find the most recent change;
   bisect to find when float / unicode-escape parsing broke.
2. The FIX.2 commit (`4623b454`) is a strong candidate — string
   semantics changed there.
3. Fix the lexer/parser, run json_spec + json_float_spec +
   json_edge_cases_spec to verify.

## Out of scope for this filing

- tools/quake.qz, std/colors.qz, std/concurrency.qz — different
  modules.
- json's UFCS conversions in bundle 2 (`d0f608e8` + this commit) —
  proven neutral on the failures.

## Discoverability

Surfaced 2026-05-07 during A.12 UFCS bundle 2 sizing. Bundle 2
shipped despite these red specs because the failures pre-exist and
this filing tracks the recovery work separately.

## Resolution (2026-05-07)

**Closed via stdlib workaround.** All 8 json_spec, 7 json_float_spec, and
3 json_edge_cases_spec failures were a single root cause: the
`json_parser_get_kind` / `json_parser_get_value` helpers used a
local-var copy of `parser.current` and read fields off the local. The
local-copy lost its `JsonToken` struct type and `t.kind` mis-dispatched
to the prelude `SimpleError$kind` method instead of loading the struct
field. Fix: switch the helpers to chained access (`parser.current.kind`).

NOT a FIX.2 codepoint regression as the bug doc hypothesized — the float
lexer (`str_byte_*` calls) and `\uXXXX` decoder were both correct. The
parse_value dispatch was simply skipping every kind comparison because
the kind value was a heap pointer, leading to "Unexpected token" on the
String/Number/LBracket/LBrace fallthrough.

Underlying compiler bug filed as `STRUCT_FIELD_LOCAL_COPY_METHOD_DISPATCH.md`.

Verification: json_spec 18/18, json_float_spec 7/7, json_edge_cases_spec
8/8, json_pretty_spec 6/6, json_ufcs_spec 4/4 — all green.
