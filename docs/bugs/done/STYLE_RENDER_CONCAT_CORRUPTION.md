# STYLE_RENDER_CONCAT_CORRUPTION

## Status

**CLOSED 2026-05-06** — fixed by adding suffix-search fallback in
`mir_infer_expr_type`'s NODE_CALL case (mir.qz:3275-3322), mirroring
the same fallback already present in `mir_lower_call`
(mir_lower_expr_handlers.qz:2914-2939). Filed 2026-05-05 during TUI
roadmap Phase 1.3 (deckbuilder Style integration). Original analysis
below preserved for reference.

## Root cause

Typecheck rewrites `Style.success().render("AAA")` to a NODE_CALL
whose callee is the string-mangled `Style$render` (from
typecheck_expr_handlers.qz:2807 — `tc_mangle(struct, method)`). The
actual function registered for codegen is the fully-prefixed
`style$Style$render`. `mir_lower_call` already handles this gap via a
suffix-search fallback when `mir_lookup_function` returns 0
(mir_lower_expr_handlers.qz:2914-2939), so the call IR emits
correctly. But `mir_infer_expr_type` (used by `mir_is_string_expr`
and `var let_init` string-var tracking) did NOT have the same
fallback — exact-match lookup of `Style$render` failed, the call's
return type came back empty, and the binary `+` operator's
string-detection heuristic returned 0 for both sides. The MIR
lowering then dispatched `OP_ADD` as a raw integer add (`add i64`)
instead of `qz_str_concat`, dereferencing the string-literal data
pointers as integers.

With colors disabled (`term_color_depth() == 0`), `render` returns
its `text` arg directly — a string-literal `qz_val` whose `s - 8`
byte is the literal length prefix; the bug manifested as a
length-zero result. With colors enabled (TTY), `render` allocates a
new heap buffer, and the `s - 8` lookup hit unmapped memory →
SIGSEGV.

The two sites had drifted: the codegen path was patched at some
point with the suffix-search fallback, but the type-inference path
that drives the binary-`+` detection heuristic was not updated to
match. Closing one half of a structural pair without the other left
a latent miscompilation for any user code holding a cross-module
method-call result in a `var` and operating on it polymorphically.

## Fix

mir.qz `mir_infer_expr_type` NODE_CALL — added ~15 lines of
suffix-search fallback when exact `mir_lookup_function` misses.
mir_lower.qz `mir_is_string_expr` — removed `return 0` early-exit on
NODE_CALL fall-through so the universal `mir_infer_expr_type`
fallback at line 796 is reached. Regression spec at
`spec/qspec/style_render_concat_spec.qz` (5 tests).

## Symptom

Two `Style.PRESET().render(...)` calls (where `PRESET` is a
zero-arg method on the `Style` namespace — `success`, `muted`,
`error`, `warning`, `info`, `heading`) whose results are then
immediately string-concatenated produce a SEGV at the concat call.

A weaker variant of the same bug occurs when the two calls are
separated by an intervening side-effecting call (e.g.
`eputs(...)`) — no SEGV but the concat returns a zero-length
string (data is silently lost).

## Minimal repro

```qz
import style

def main(): Int
  var s1 = Style.success().render("AAA")
  var s2 = Style.muted().render("BBB")
  var s3 = s1 + s2
  eputs("len=" + str_byte_len(s3).to_s() + "\n")
  return 0
end
```

```
$ ./quartz repro.qz | llc -filetype=obj -o /tmp/r.o
$ clang /tmp/r.o -o /tmp/r -lm -lpthread
$ /tmp/r ; echo $?
139    ← SIGSEGV
```

## Variants observed

| Pattern | Result |
|---|---|
| `Style.PRESET().render(x) + Style.PRESET().render(y)` | **SEGV** |
| Same with `eputs("between\n")` between renders | concat returns empty (no SEGV) |
| `Style.new().chain().render(x) + Style.new().chain().render(y)` | concat returns empty (no SEGV) |
| `Style.new().render(x) + Style.new().render(y)` | concat returns garbage (corrupted length, garbage data) |
| `var sty1 = Style.PRESET(); var s1 = sty1.render(x); ...; var s2 = sty2.render(y); s1 + s2` | **still SEGV** (preset hoisted to var doesn't help) |
| `s1 + literal + s2` where s1, s2 are render results | **works correctly** ← workaround for two renders |
| `Vec push s1 / push lit / push s2; join_vertical` | works (view_combat shape) |
| Two plain-function-pass-through calls (no Style at all) | works correctly |
| User-defined struct with same 3-Int field shape and same render method body | works correctly |
| Importing std/style but defining MyStyle with own .render | works correctly |
| `s_a.render(a) + "" + s_b.render(b) + "" + s_c.render(c) + "" + s_d.render(d)` (4 renders, literals between each) | concat returns empty (TTY only — non-TTY works) — 2026-05-05 progress widget Phase 2 |
| Same 4-render shape via `sb_append`, one append per render | concat returns empty (TTY only — non-TTY works) — 2026-05-05 progress widget Phase 2 |
| `"[" + s.render(x) + plain + "]"` (single render between literals) | **works correctly** in TTY (deckbuilder hp_bar pre-Phase-2 + post-Phase-2) |

The trigger axis is specifically **two `Style.<X>().render(...)` results concatenated *directly* with `+`**. Inserting any non-render-result expression between them avoids the SEGV. Stacking the parts into a Vec and joining via `join_vertical` also avoids it (which is why view_combat ran fine for hundreds of frames — its multi-render concats always have literal pieces between).

The bug is specific to **the actual std/style.qz `Style` type**. A user-defined struct with the same field shape and render-method body does NOT trigger the bug. So the issue is some property of how `std/style.qz` is compiled, registered, or resolved — possibly an interaction between `extend Style`'s methods and the receiver-flow when the resulting String is used in a binary `+` operator with another such result.

## Live trigger site

`game/deckbuilder/main.qz::view_reward` — pre-Phase-1.3 plain-text
header was simple concatenation; Phase 1.3 added two
`Style.X().render(...)` calls whose results were concatenated:

```qz
var headline = Style.success().render("*** VICTORY ***")
var meta = Style.muted().render("    Fights won: ...")
var header = headline + meta    # ← SEGV
```

User-visible: SEGV on the killing-blow screen transition (Combat ->
RewardScreen), AFTER the runtime had successfully transitioned
state and entered the view dispatch.

## Workaround

Render only ONE of the two pieces; leave the other plain. Or push
each as a separate Vec entry and let `join_horizontal` (or vec
concatenation that doesn't go through `qz_str_concat`) join them.

The "literal between two renders" form (`s1 + literal + s2`)
**only generalises to 2 renders** — three or more renders separated
by literals still corrupts in TTY (verified 2026-05-05 in the
progress widget Phase 2 dogfood). For ≥2 styled regions in the
same output string, the Vec-push-then-join shape is the only known
working pattern; the single-render-with-plain-context shape is
also safe.

Phase 1.3's view_reward / view_defeat uses the "render one, leave
one plain" workaround. Phase 2's progress widget renders only the
fill region (gradient) and leaves brackets / track plain — the
struct still has `empty: Style` and `border: Style` slots reserved
for once the bug is fixed.

## Hypothesis

Style.render returns its `text` argument unchanged when
`term_color_depth() == 0` (piped/non-TTY). The returned qz_val is
the address of a string literal's data field
(`@.str.N` private constant: `<{ i64 length, [N x i8] data }>`,
qz_val pointer = data). The concat call reads `*(i64*)(s - 8)` to
get the length — for string-literal-backed qz_val, this reads the
constant's i64 length prefix.

Two consecutive such calls + immediate concat may have a
codegen-level register/stack overlap that clobbers one of the
arg pointers between the renders and the concat. The fact that
inserting `eputs` between the renders changes the symptom (SEGV →
silent zero-length) supports the "register pressure" theory: the
intervening call forces a spill, which avoids the misallocated-
register collision but reveals a different layout bug.

The fact that "plain function pass-through" works fine and the
ARENA-prefixed warnings appear on stderr during build (multiple
QZ0108 warnings on `std/string.qz`) suggests this might interact
with arena-allocation tracking on the value-coming-back-out-of-
render path.

## Repro paths

- `/tmp/style_concat_bug.qz` — minimal 6-line repro (in this session
  only; not checked in — recreate from the snippet above).
- `game/deckbuilder/main.qz::view_reward` post-Phase-1.3 (with
  workaround applied) — original failing version landed in commit
  for Phase 1.3 then was workaround'd in the same session.

## Reach

Likely affects any consumer doing `Style.X().render(...) +
Style.Y().render(...)` directly. The deckbuilder's
`view_combat` happened to use a Vec-push-then-join pattern instead,
which is why combat ran fine for hundreds of frames. As more TUI
apps adopt `std/style`, this is going to surface again — the
current workaround is a styling-quality regression (less color in
victory/defeat headers).

## Priority

**MEDIUM-HIGH.** Not a multi-session blocker (workaround is a
two-line refactor at each call site), but it forces every Style
consumer to internalize an unintuitive call-shape rule. Worth
fixing before more TUI widgets ship in Phases 2+ or it becomes a
recurring stub.
