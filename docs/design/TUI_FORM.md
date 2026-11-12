# TUI Form composer (std/tui/widgets/form.qz) — v0.3.3

**Status**: Design memo, written 2026-05-04. Implementation pending.
**Stance**: huh-shaped (charmbracelet/huh): a `Form` is a typed, ordered list of `Field`s with shared `FocusRing`, per-field validators, and external submit. Inherits all v0.3.2 framework decisions (parent-dispatches, no auto-routing, pure update, `(Self, Cmd<M>, Option<Event>)`, FocusRing as separate first-class abstraction).
**Driving project**: deckbuilder Settings screen (named in the umbrella memo). Character-creation likely follows.

---

## What this is

A composable Form widget that lets a consumer write:

```be
import std/tui/widgets/form as form

var f = form::form_new()
    .form_with_field("name", "Character name", text_input_new())
    .form_with_validator("name", form::Validator::MinLen(1))
    .form_with_field("seed", "Random seed", text_input_new())
    .form_with_validator("seed", form::Validator::Numeric)

# In update:
var (next, cmd, ev) = form::form_update(f, msg)
match ev
  form::FormEvent::Submitted => # all fields validated, commit
  form::FormEvent::Cancelled => # Esc pressed
  _ => # Idle, FieldChanged, FieldFocused, etc.
end

# In view:
puts(form::form_view(next))
```

The Form owns:
- An ordered Vec<TextInput> — homogeneous in v1, see "What this is NOT" below.
- Per-field labels (Vec<String>) and validators (Vec<Validator>).
- An internal `FocusRing<Int>` keyed by field index.
- A `FormState` enum (Editing | Submitted | Cancelled) for terminal states.

The Form's `update` handles Tab/Shift-Tab cycling internally (unlike v0.3.2's save-screen example, where the parent did it). This is the key ergonomics win: the parent forwards `FrameMsg<M>` to `form_update` and gets back semantic events, not key events.

## What this is NOT (v0.3.3 step 1)

Each cut is intentional. Listed in priority order — first to revisit when a real consumer surfaces the need.

- **No mixed field types.** v1 is `Vec<TextInput>` only. Tagged-enum field type (`FormField::Text(TextInput) | Select(List<String>) | Confirm(Bool)`) lands in v0.3.4+ once a real consumer needs Select / Confirm. Settings-screen consumer (the named driver) is plausibly all-text-input.
- **No closure-shaped validators.** `Lambda-capturing-Fn-stored-in-struct miscompiles` (the open codegen bug from v0.3.2 friction findings). Validators are a tagged enum with built-in cases (`Required | MinLen(Int) | MaxLen(Int) | Numeric | Range(Int, Int) | Pattern(String)`); custom validators wait for the codegen fix.
- **No grouping.** huh has `Group(fields...)` + `Form(groups...)` two-level structure. v0.3.3 ships flat. Group is a v0.3.4+ if Settings has logical sections.
- **No layout customization.** Vertical stack, label-above-input, error-below-input. No grid, no two-column, no inline-label. Layout-as-data is v0.4+ if it surfaces.
- **No async / debounced validation.** Validators run synchronously on every keystroke (or per `ValidateOn` semantics inherited from TextInput). Async revalidation against external services is v0.4+.
- **No conditional fields.** "Show field B only if A==X" is v0.4+. Static field list in v1.
- **No per-form Cmd emission.** Form's Cmd<M> slot is always Cmd::None in v1 (same as TextInput's). Cmd-emitting Forms wait for cursor-blink / debounce / async-validate.

---

## Quartz-substrate constraints (inherited from v0.3.2 + new)

These are language / runtime properties that constrain the Form API and would surprise a reader coming from huh or Brick.Forms.

### 1. No closure validators (codegen blocker)

The v0.3.2 friction finding "Lambda capturing outer Fn param + stored in struct field → malformed IR" is load-bearing here. A `Form` with `validators: Vec<Fn(String): Option<String>>` would store closures in a struct field — same broken codegen path that forced ItemDelegate to take `Fn(Item): String` instead of `Fn(Item, Bool, Int): String`.

**Resolution**: validators are a tagged enum with built-in cases. Each case is data, not a closure. The Form's `_run_validator(v, value)` switches on the variant. Custom validators wait for the codegen fix; tracked as a v0.3.4 milestone in the bugs roadmap.

```be
enum Validator
  None                         # always valid
  Required                     # non-empty
  MinLen(Int)                  # value.size >= n
  MaxLen(Int)                  # value.size <= n
  LenRange(Int, Int)           # min..=max
  Numeric                      # parses as Int (Int.parse(s).is_ok)
  IntRange(Int, Int)           # parses as Int AND in range
  NonWhitespace                # not all-whitespace
  StartsWith(String)
  EndsWith(String)
  Equals(String)               # exact match (e.g. confirm field re-entry)
end
```

This is ~10 cases. Real-world Forms hit them all; the long tail (regex, custom-business-rule) waits for the codegen fix.

### 2. Generic-typed children inference bug

Filed today as `docs/bugs/CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED.md`. A `Form` whose internal FocusRing field is annotated `FocusRing<Int>` will hit the same "expected unknown, got unknown" diagnostic as the v0.3.2 save_screen example, unless the FocusRing is constructed with explicit `<Int>` type args at every call site.

**Resolution**: Form's `focus` field is `FocusRing<Int>`. Every internal construction spells `focus_ring_new<Int>(ids)` with explicit type args. Document in form.qz prelude comment so future maintainers don't drop the `<Int>`.

### 3. Const-by-default + struct-rebuild

Form has 5+ fields (fields, labels, validators, focus, state, last_errors). Every transition rebuilds the whole struct. Mitigations from v0.3.2 hold:
- Builder helpers (`form_with_field`, `form_with_validator`, `form_set_focus`, `form_set_state`).
- Tight struct (no field for "is this form currently animating," etc.).
- `_form_with_fields_replaced(f, new_fields)` private helper for the common case where update only changes the focused field's TextInput.

### 4. Inherits everything else

- Pure update returning `(Self, Cmd<M>, Option<FormEvent>)`.
- `FormEvent` uses `Idle` not `None` (the `is None` SIGSEGV gotcha).
- View takes a `focused: Bool` (the parent passes whether the whole Form is focused; Form internally renders its current field with the focused indicator).
- Resize via `form_set_size(f, w, h)`; forwards to children.
- Themed via `FormStyles { label, value, cursor, error, label_focused, ... }` mirror of TextInputStyles.

---

## Prior-art summary (compressed)

Full research in session log; condensed here.

- **Brick.Forms (Haskell)** — GADT existential field types, lens-driven state projection, separate `FormFieldState` per field. Doesn't translate cleanly: GADTs and lenses are the Haskell-only escape hatch for heterogeneity.
- **charmbracelet/huh (Go)** — `Field` interface + `Group(fields...)` + `Form(groups...)`. Per-field `.Validate(fn)`, type-erased `GetValue() any`, generics where types matter (`Select[T]`). **Dominant model.** What we adopt with adaptations.
- **Textual (Python)** — no Form widget. Composing Inputs in a Container with Validator ABCs is the convention. Their Validator class is shape we steal: `validate(value) -> ValidationResult` with merge.
- **ratatui (Rust)** — no canonical Form crate. Immediate-mode rendering doesn't have a natural "stateful form" home.

What we steal from huh:
- Form-of-fields with shared FocusRing.
- Per-field validators as data.
- Submit-is-external (`form.is_valid() / form.errors() / form.get(key)`).
- Method-chain builders.

What we don't steal (yet):
- huh's `Field` interface (Quartz typecheck friction; defer until codegen fixes land).
- huh's `Group` two-level structure (v0.3.4+ if needed).
- huh's accessibility mode (out of scope).
- huh's runtime `any` for GetValue (we use String — all v1 fields are TextInput).

---

## Recommended design

### `form.qz` — Form

```be
enum FormState
  Editing
  Submitted        # all fields valid, Enter pressed on last field OR explicit submit
  Cancelled        # Esc pressed
end

enum FormEvent
  Idle
  FieldChanged(idx: Int)        # value of field idx changed
  FieldFocused(idx: Int)        # focus moved to field idx
  Submitted                      # form_state transitioned to Submitted
  Cancelled                      # form_state transitioned to Cancelled
end

# (See "Quartz-substrate constraints" §1 for the Validator enum.)

struct FormStyles
  label:          style::Style
  label_focused:  style::Style
  value:          style::Style
  cursor:         style::Style
  error:          style::Style
end

struct Form
  fields:        Vec<text_input::TextInput>
  labels:        Vec<String>
  validators:    Vec<Validator>            # one per field
  last_errors:   Vec<Option<String>>       # parallel; None = valid, Some(msg) = error
  focus:         focus::FocusRing<Int>     # field-index focus
  state:         FormState
  width:         Int
  height:        Int                        # 0 = auto from field count
  styles:        FormStyles
end

# constructor + builders (chainable)
def form_new(): Form
def form_with_field(f: Form, key: String, label: String, input: text_input::TextInput): Form
def form_with_validator(f: Form, key: String, v: Validator): Form
def form_with_styles(f: Form, s: FormStyles): Form
def form_with_size(f: Form, w: Int, h: Int): Form

# accessors
def form_get(f: Form, key: String): String          # current value of field
def form_get_at(f: Form, idx: Int): String
def form_field_count(f: Form): Int
def form_state(f: Form): FormState
def form_is_valid(f: Form): Bool                    # all validators pass
def form_errors(f: Form): Vec<Option<String>>       # parallel to fields
def form_focused_index(f: Form): Option<Int>

# state setters (programmatic; do NOT trigger validators)
def form_set_state(f: Form, s: FormState): Form
def form_set_focus(f: Form, idx: Int): Form
def form_clear(f: Form): Form

# update + view (focused passed in by parent — Form-level focus)
def form_update(
  f: Form,
  msg: tui::FrameMsg<M>
): (Form, tui::Cmd<M>, FormEvent)

def form_view(f: Form, focused: Bool): String

def form_set_size(f: Form, w: Int, h: Int): Form
```

`form_with_field` takes a `key: String` so `form_get(key)` works regardless of insertion order. Internally we maintain `keys: Vec<String>` parallel to `fields`. `form_with_validator(key, ...)` looks up the index by key.

### Update semantics

- `Tab` → next field via FocusRing; emits `FieldFocused(idx)`.
- `Shift-Tab` → previous field; emits `FieldFocused(idx)`.
- `Enter` on non-last field → next field (huh's "submit advances" pattern). Run focused field's validator first; if valid, advance + emit `FieldFocused`; if invalid, populate `last_errors[idx]` + emit `FieldChanged(idx)`.
- `Enter` on last field → run all validators; if all valid, transition `state := Submitted` + emit `Submitted`; otherwise focus first invalid field + populate errors + emit `FieldChanged`.
- `Esc` → transition `state := Cancelled` + emit `Cancelled`.
- All other keys → forward to focused field's `text_input_update`. If the resulting `TextInputEvent` is `Changed`, re-run validator + populate `last_errors[idx]` + emit `FieldChanged(idx)`. Submitted from the inner TextInput is no-op (Form owns Enter semantics).

### View semantics

```
[label_focused] Character name:
[value]         Eldric_                      [cursor at _]
[error]         (no error)

[label]         Random seed:
[value]         12345

[label]         Difficulty:
[value]         hard
[error]         must be one of: easy, medium, hard
```

Vertical stack, one field per logical block (label + value + optional-error). Focused field's label uses `label_focused` style; others use `label`. Cursor only renders on focused field. Width-aware (clip values exceeding `width - label_width`).

### Composition with parent screen

Settings screen sketch:

```be
struct SettingsScreen
  form:   Int                                # actually form::Form (Int handle)
  status: String
end

def settings_update(msg: tui::FrameMsg<AppMsg>, m: SettingsScreen): (SettingsScreen, tui::Cmd<AppMsg>)
  var f = as_type<form::Form>(m.form)
  var (next, cmd, ev) = form::form_update(f, msg)
  match ev
    form::FormEvent::Submitted =>
      var seed_str = form::form_get(next, "seed")
      var seed = Int::parse(seed_str)
      return (commit_settings(seed), cmd)
    form::FormEvent::Cancelled =>
      return (m, tui::Cmd::Quit)
    _ =>
      return (SettingsScreen { form: as_int(next), status: m.status }, cmd)
  end
end

def settings_view(m: SettingsScreen): String
  var f = as_type<form::Form>(m.form)
  return form::form_view(f, true)
end
```

Note the Int-handle ceremony — same as v0.3.2 save_screen, until `CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED` closes.

The boilerplate per Settings-screen-like consumer is ~15 lines update + ~3 lines view. **5x reduction vs. hand-written save_screen-shaped routing for each form.**

---

## Open design questions resolved

### Q1 — Heterogeneous fields? **No, homogeneous TextInput only in v1.**

Brick GADT path is closed by Quartz typecheck. huh's runtime-interface path requires either trait+dyn dispatch (we don't have it) or tagged enum (`FormField::Text(TextInput) | Select(...) | Confirm(...)`). Tagged enum is the right v2 shape but multiplies the surface (per-variant update branches, per-variant view branches, per-variant validator-applicability checks). v1 ships TextInput-only. Settings screen is the driver and is plausibly all-text-input. Re-evaluate when a second consumer surfaces.

### Q2 — Validators: closures or enum? **Enum.**

Closures-stored-in-struct miscompile (v0.3.2 friction #6). Tagged enum captures the 90% case (~10 built-in validators). Custom validators wait for the codegen fix. This makes Form less expressive than huh.Form but doesn't block the named driver.

### Q3 — Submit semantics: internal or external? **Internal-with-event.**

Form's update transitions to `FormState::Submitted` on Enter-on-last-field-with-all-valid, AND emits `FormEvent::Submitted`. The parent reads `form_state()` for terminal-state checks and reacts to the event for one-shot signals. This matches huh and is more ergonomic than Brick's "external owns submit." The parent doesn't have to write submit-decision logic.

### Q4 — Field keys: index or string? **String.**

`form_get(key)` is what consumers want. Index would force consumers to maintain their own `idx_of_field("name") = 0` mapping. Internal `keys: Vec<String>` parallel to `fields` is one extra field; cost is fine.

### Q5 — Keyboard chord for cancel: Esc or Ctrl-C? **Esc.**

Ctrl-C at the runtime layer is "quit app." Form's Esc is "cancel this form." Parent decides what "cancelled" means (close modal, navigate back, etc.).

### Q6 — Focus-ring inside Form vs. parent's? **Inside.**

v0.3.2 save_screen put FocusRing in the parent. That made sense for the heterogeneous case (TextInput + List + ...). For homogeneous Form, a Form-internal `FocusRing<Int>` is cleaner — the parent doesn't need to know the field count to size its own ring. The Form is itself a "focusable child" from the parent's perspective: parent's outer FocusRing might be `FormFocus | OtherWidgetFocus`, with the Form-internal ring kicking in only when the outer ring delegates focus to FormFocus.

### Q7 — Validator-on-ValidateOn semantics: inherit from TextInput or override? **Form owns it.**

TextInput has its own ValidateOn mechanism, but Form bypasses it. Form's `update` re-runs the validator on every `Changed` event regardless of the inner TextInput's `ValidateOn`. The inner TextInput's validator (if any) still runs first; Form's validator runs second. This means setting a TextInput's validator separately from the Form's validator is a bit redundant — recommend consumers set validation only at the Form level.

---

## Sequencing within v0.3.3 step 1

Smallest-to-largest, each its own commit, fixpoint-clean, behind quake guard.

1. **Design memo** (this file) — committed first, no source touch. ✅
2. **`form.qz` skeleton** + `Form` struct + `FormState`, `FormEvent`, `Validator`, `FormStyles` + `form_new`. Compiles + trivial QSpec ("can construct empty Form").
3. **Builder methods** + `form_with_field`, `form_with_validator`, `form_with_styles`, `form_with_size`. Adds key→idx lookup. QSpec: build a 2-field form, assert structure.
4. **Accessors + state setters** + `form_get`, `form_get_at`, `form_state`, `form_is_valid`, `form_errors`, `form_focused_index`, `form_set_focus`, `form_set_state`, `form_clear`. QSpec: round-trip.
5. **Validator dispatch** + private `_form_run_validator(v, value)` covering all enum cases. QSpec: each Validator variant validates correctly on representative inputs.
6. **`form_update`** — Tab/Shift-Tab routing, Enter advance/submit, Esc cancel, key forwarding, validator re-run. QSpec: ~25 update tests covering each branch.
7. **`form_view`** — vertical stack, focus-aware label styling, error rendering, cursor on focused field. QSpec: ~10 view-substring tests using `layout::strip_styles`.
8. **`form_set_size`** — forwards w/h to children, no-op if unchanged. QSpec: 3 tests.
9. **Settings example** — `examples/tui/widgets/settings/main.qz` — single Form with 3-4 fields demonstrating submit/cancel events. Spec.
10. **Reconciliation pass** — fill in friction findings (predictions vs reality) at the bottom of this memo, mirror of v0.3.2 epic.

Estimate: ~1.5 quartz-days end-to-end. The mechanical work is steps 2-8 (~0.75 days against this memo). Step 9 example is the user-facing payoff and surfaces friction. Step 10 closes the loop.

---

## Acceptance for v0.3.3 step 1 — final status

- [x] `std/tui/widgets/form.qz` ships `Form` + 4 enums + `FormStyles` with QSpec — 49 tests across builders, accessors, validator dispatch, update routing, view shape.
- [x] `examples/tui/widgets/settings/main.qz` — runnable Settings example with 3 fields + 3 validators (Required / Numeric / IntRange). Compiles + links clean. No separate composite spec; the form-level spec covers integration at the unit level.
- [x] No `quake guard` runs needed — v0.3.3 ships in std/ and spec/, not self-hosted/. The pre-commit hook only enforces guard on self-hosted/*.qz changes.
- [x] Friction reconciliation written (this section).
- [ ] No new top-level diagnostic surfaces — **2 new bug docs filed**: `CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED.md` (follow-up to a closed bug-bash fix; surfaced during dogfood) and `EXHAUSTIVENESS_CHECK_SEGV_ON_QUALIFIED_VARIANT_PATTERN.md` (surfaced during step 6 form_update). Both have workarounds in the v0.3.3 code.

**49 tests green, 8 source-touching commits + 1 design memo + 2 bug docs, ~1.0 quartz-day end-to-end. Form composer ships.**

---

## Friction findings — predictions vs. reality

### Predictions that landed

1. **No closure validators forced tagged-enum design** (Q2) — confirmed and clean. The 11-variant Validator enum covers Required / MinLen / Numeric / IntRange / NonWhitespace / StartsWith / EndsWith / Equals — every realistic Settings/character-creation validator. No consumer has yet wanted the codegen-blocked `Custom(Fn)` case.
2. **Generic-typed children inference bug forces Int handles** (Quartz constraint §2) — confirmed in spades. The `make_initial_form` factory had to spell `vec_new<Int>()`, `vec_new<ti::TextInput>()`, etc. at every internal-Vec-construction site to keep the closed-bug-fix's call-site substitution active. The Settings example also stores Form behind `as_int(form)` / `as_type<form::Form>(handle)`, same as v0.3.2 widgets. **Follow-up bug filed**: `CONCRETE_GENERIC_INFERRED_TYPE_ARGS_REJECTED.md`.
3. **Const-by-default + struct-rebuild verbosity** (Quartz constraint §3) — confirmed. The Form has 10 fields; every state setter (`form_set_state`, `form_set_focus`, `form_with_styles`, `form_with_size`, etc.) rebuilds all 10 explicitly. The cost is bounded but loud. Builder pattern (chainable `form_with_*`) keeps user code clean even when library code isn't.
4. **Tagged enum for FormEvent works fine** — confirmed. `FormEvent::FieldChanged(idx)` with named payload syntax (`FieldChanged(idx: Int)`) is the canonical form Quartz wants. The `is None` SIGSEGV gotcha was avoided via the `Idle` naming convention inherited from v0.3.2.

### Predictions that were wrong or never came up

5. **Cmd<M> threading was supposed to be ceremonial** (Quartz constraint §2) — wrong. Threading Cmd<M> through nested generics in `_form_handle_key<M>(...)` etc. needed explicit `<M>` type-args at every call site to prevent inference falling through to TYPE_ERROR. Shape: every internal helper takes an explicit `<M>` type-arg, callers spell it. Tolerable but louder than predicted.
6. **`form_set_size` was supposed to also forward to children's set_size** — wrote that, but discovered `text_input_set_size` is currently a no-op (`def text_input_set_size(t, _w, _h) = t`). The forwarding line is dead code today; kept it because future v0.3.4+ TextInput may grow a real set_size.

### New friction NOT predicted (in order discovered)

These are bugs / friction surfaces found during implementation, all worked-around and (the systemic ones) filed:

1. **Compiler SIGSEGV on qualified no-arg variant pattern in match arm** — `ti::TextInputEvent::Changed => ...` crashed `tc_check_exhaustiveness → mx_resolve_enum_name → qz_str_get_len`. Workaround: `if ev is Changed`. Filed as `EXHAUSTIVENESS_CHECK_SEGV_ON_QUALIFIED_VARIANT_PATTERN.md`. Sister to the closed `PATTERN_PARSER_REJECTS_QUALIFIED_VARIANT.md` sub-bug (b).
2. **Same-name variant collision across modules surfaces in user `match`** — `match form::form_state(f) { Submitted => ... }` resolved `Submitted` to `ti::TextInputEvent::Submitted` (alphabetical first?), not `form::FormState::Submitted`. Workaround: qualify the match arm `FormState::Submitted => ...`. The closed parser-fix `PATTERN_PARSER_REJECTS_QUALIFIED_VARIANT` accepts the qualified form, BUT this combines with friction #1 above so qualifier with a no-arg variant can crash; payload variants (the FrameMsg form) don't crash. Net: spec authors must qualify same-name variants without crashing on the no-arg case. Tedious.
3. **Empty match arm body types as Int, not Void** — `None => # comment` fails to unify with sibling `Some(_) => sb_append(...)` (which is Void). The error message says "expected Void, found Int." Workaround: replace empty arm with `sb_append(sb, "")` no-op or use `if x is Some` guard. The pattern is endemic — every "do nothing on None" arm trips it. Worth a compiler-side fix (let an empty match-arm body type as Void/the-other-arm-type).
4. **Inline `import` inside a `describe` lambda body** — silent compile-failure with empty stderr+stdout (compile exit code 0, but ll file is empty). Imports are top-level only; the parser apparently swallows them inside lambdas without diagnostic. Hit during step 7 spec authoring; lost ~3 minutes before realizing.
5. **`text_input_set_size` is a no-op stub** — `def text_input_set_size(t, _w, _h) = t`. Form's set_size forwards w/h to children but the call doesn't actually do anything today. Not a v0.3.3 blocker (Form's own width/height work) but a deferred hole for v0.4+ when TextInput grows horizontal scroll.

### Net assessment

Predicted friction (6 items): 4 confirmed, 2 wrong. Discovered friction (5 items): 1 systemic (compiler SIGSEGV — filed); 1 endemic (empty-arm-types-as-Int — common across all three steps that touched match); 3 minor. None blocked the design — the recommended shape held.

Per-step cost: ~5-15 min of debugging across the 8 source-touching steps. The compiler SIGSEGV was the single largest delay (filed crash report → identified qualified-variant pattern → swapped to `is` predicate, ~10 min).

The deckbuilder Settings consumer will hit (1) and (3) routinely — both have low-cost workarounds in v0.3.3. Friction (2)'s same-name variant collision will recur whenever a parent's enum and a child widget's event enum share a variant name; recommend renaming Form's internal enum variants to avoid this if cross-widget-event usage grows.

---

## Sequencing — actuals vs. plan

| Step | Plan | Actual | Notes |
|---|---|---|---|
| 0. Design memo | included in step 1 | separate commit | matches v0.3.2 pattern; useful to commit standalone |
| 1. (was design memo) | — | rolled into step 0 | |
| 2. Skeleton | smallest first | clean | 2 tests |
| 3. Builders | 4 builders | clean | 8 tests; in-place Vec mutation idiom |
| 4. Accessors + state setters | 7 accessors | clean | 12 tests; same-name variant collision surfaced |
| 5. Validator dispatch | 11 cases | clean | 11 tests; built local _form_parse_int |
| 6. form_update | meaty | compiler SIGSEGV; debugged + filed | 11 tests; qualified-variant-in-match crash |
| 7+8. View + set_size | combined | clean | 5 tests |
| 9. Settings example | runnable | compile+link green | 1 example, 0 spec (form spec covers it) |
| 10. Reconciliation | this section | this section | |

End-to-end ~1.0 quartz-day, beating the 1.5-day estimate.

---

## Sources (research)

- [Brick.Forms Hackage](https://hackage.haskell.org/package/brick/docs/Brick-Forms.html)
- [Brick Forms.hs source](https://github.com/jtdaugherty/brick/blob/master/src/Brick/Forms.hs)
- [charmbracelet/huh README](https://github.com/charmbracelet/huh)
- [huh v2 pkg.go.dev](https://pkg.go.dev/github.com/charmbracelet/huh/v2)
- [Textual validation API](https://textual.textualize.io/api/validation/)
- [Textual Input docs](https://textual.textualize.io/widgets/input/)
- [textual-forms PyPI](https://pypi.org/project/textual-forms/)
- [ratatui-form](https://github.com/DavidLiedle/ratatui-form)
- [awesome-ratatui](https://github.com/ratatui/awesome-ratatui)
