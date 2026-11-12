## TUI Epic — Audit & Roadmap

**Status**: First draft, 2026-05-05. Written after the deckbuilder
v0.1–v0.4 sprint exposed a class of stdlib gaps. Updated by the
implementer after each phase ships.

The TUI epic is a five-piece library (runtime + layout + widgets) plus
companion modules (style, terminal). The deckbuilder (`game/deckbuilder/`)
is the first multi-screen consumer and serves as the dogfood that
surfaces gaps.

---

### Where we are (2026-05-05)

#### Shipped

| Module | Surface | Tests |
|---|---|---|
| `std/tui/runtime.qz` | `program_new/with_init/with_recorder/run/replay`, `FrameMsg<M>`, `Cmd<M>`, `KeyEvent`, `Program<S, M>` | smoke tests via examples |
| `std/tui/layout.qz` | `border_with`, `border`, `pad/_horizontal/_vertical/_uniform`, `align_left/center/right`, `join_vertical/horizontal`, `truncate`, `visible_width`, `line_count`, `strip_styles`, BORDER_* / ALIGN_* constants | 29 + 12 specs |
| `std/tui/widgets/focus.qz` | `FocusRing<Id>` + 8 transitions | 23 specs |
| `std/tui/widgets/text_input.qz` | `TextInput`, `TextInputEvent`, `TextInputStyles`, `ValidateOn` | 34 specs |
| `std/tui/widgets/viewport.qz` | `Viewport`, `ViewportEvent`, `ViewportStyles` | 30 specs |
| `std/tui/widgets/list.qz` | `List<Item>`, `ListEvent<Item>`, `ListStyles`, `ItemDelegate`, `item_delegate_simple/_card` | 29 specs |
| `std/tui/widgets/form.qz` | `Form`, `FormEvent`, `FormState`, `Validator` (11 cases), `FormStyles` | 49 specs |
| `std/tui/widgets/overlay.qz` | `Overlay`, `overlay_new/with_body/with_position/compose`, POS_* | (no specs yet) |
| `std/tui/widgets/progress.qz` | `ProgressBar`, `ProgressBarStyles`, `progress_bar_new/with_size/with_styles/with_auto_gradient/set/percent/gradient_color/view` | 22 specs |
| `std/tui/widgets/confirm.qz` | `Confirm`, `ConfirmStyles`, `ConfirmEvent`, `confirm_new/with_labels/with_default/with_styles/update/view/overlay` | 24 specs |
| `std/tui/widgets/toast.qz` | `Toast`, `ToastLevel`, `ToastEvent`, `ToastStyles`, `toast_new/with_ttl/with_position/with_styles/with_auto_color/level_color/view/overlay/show_cmd` | 15 specs |
| `std/tui/widgets/status_bar.qz` | `StatusBar`, `StatusSegment`, `StatusBarStyles`, `status_bar_new/with_segments/with_position/with_styles/append`, `status_segment_left/center/right/with_style`, `status_bar_view`, POS_TOP/POS_BOTTOM | 23 specs |
| `std/tui/help.qz` | `KeyBinding`, `KeyMap`, `HelpStyles`, `key_binding`, `keymap_new/with_bindings/append`, `help_body/_with_styles`, `help_modal/_with_styles` | 13 specs |
| `std/style.qz` | `Style.new()`, `.fg/.bg/.bold/.dim/.italic/.underline/.inverse`, `.render`, semantic constructors (`error/success/warning/info/heading/muted`), 16 named colors + RGB/hex/256 | (specs exist) |
| `std/terminal.qz` | `term_get_width/_height` (ioctl TIOCGWINSZ), `term_enter_raw_mode/_exit`, `term_write` (loops on partial), `term_read_key`, `term_is_tty_*`, KEY_* constants | (specs exist) |

#### Driving consumer

`game/deckbuilder/` — Slay-the-Spire-shaped combat → reward → next-fight loop. Single file ~700 LOC. Validates: List+ItemDelegate, FocusRing-less single-list update, screen-as-state pattern, Overlay (used as full-screen modal), List<Card> as a struct field with no Int-handle ceremony.

---

### Findings from the deckbuilder audit (2026-05-05)

The deckbuilder hand-rolled functionality that already exists in stdlib, hand-rolled functionality that should exist in stdlib, and skipped stdlib functionality it should be using. Each of these is a roadmap item below.

#### Hand-rolled — should be in stdlib

1. **Generic `Vec<T>` ops** — `_vec_clone_card`, `_vec_remove_at_card`, `_vec_concat_card`, `_vec_pop_n_card`. Specialized for `Card`. Sister: `vec_string_clone` in `std/tui/widgets/_string_helpers.qz` (specialized for `String`). The pattern of "type-specialized clone helpers" exists because Quartz's generic `Vec<T>` codegen still has edges; the right answer is to fix those edges and ship a single generic family.
2. **Progress bar `hp_bar(cur, max, width)`** — universal TUI primitive (HP, energy, XP, download, loading). Belongs in either `std/tui/layout.qz` or a new `std/tui/widgets/progress.qz`.
3. **Terminal-width clamp `view_inner_width()`** — clamps `term_get_width() - 2` to `[40, 60]`. Every TUI consumer wants this exact pattern: "use the terminal's actual width, but bound it." Belongs in `std/tui/layout.qz` as `clamp_to_terminal_width(min, max)`.

#### Hand-rolled — should NOT be in stdlib

- `show_card(c)` rendering — domain logic. Stays in deckbuilder.
- `Combat`, `Game`, `Card`, `Reward` — domain types. Stay.
- `play_card_at`, `end_turn`, `enemy_intent_for`, `reward_choices_for` — domain logic. Stay.
- `_toggle_help(g)` — Game-rebuild boilerplate. Will be relevant once we have a generic "with-modal" wrapper, but the rebuild itself is per-app.

#### Skipped stdlib — should be used

- **`std/style.qz`** — full color/style API, currently unused by the deckbuilder. HP bars could redden as HP drops, energy could be cyan, the selected hand row already styles itself via List but the pile/status/header lines are monochrome. Real game-feel improvement available with zero new code.
- **`str_join(parts, sep)`** — `std/string.qz:61`. The `show_card` parts-vec-then-manual-join pattern is exactly this.

---

### Missing — stdlib pieces the deckbuilder needs but doesn't exist

These are the gaps the consumer *would* hit if the framework were complete. Some are blockers for the deckbuilder; some are next-app blockers.

1. **`progress` widget** (HP bars / energy bars / download progress)
2. **`confirm` widget** — Y/N modal dialog. "Are you sure you want to quit?" "Discard run progress?". Same Overlay scaffolding, plus state for selection + a Confirmed/Cancelled event.
3. **`toast` widget** — self-dismissing timed overlay for status messages, errors. Cmd::After + Overlay. The status line in the deckbuilder ("» Played Defend...") is currently a permanent row; a toast version would be more game-feel-correct.
4. **`status_bar` widget** — pinned one-row header or footer. Currently the deckbuilder hand-rolls header/footer via plain string concat into the body.
5. **`tabs` widget** — multi-screen with horizontal tab navigation. The screen-as-state pattern handles binary screen flips well (combat / reward); tabs would let the deckbuilder grow a "deck inspector" or "stats" screen without restructuring.
6. **Declarative help registration** — instead of hand-writing `help_body()` text per app, widgets register their keybindings and a generic `help_modal_for(keymap)` builds the overlay. Help stays in sync with actual handlers.
7. **`Overlay` interactive variant** — current `Overlay` is a static value; an interactive overlay carries its own update/event path. Confirm and toast both want this.
8. **String-level overlay compositing** — current `overlay_compose` uses absolute cursor positioning, which proved unreliable on at least one user's terminal. A fallback that merges overlay rows into the base string at column boundaries would always work, at the cost of complexity.
9. **SIGWINCH wiring** — `FrameMsg::Resize` is reserved at `runtime.qz:60` but never delivered. Apps can't react to terminal resize. Today the deckbuilder gets the right size on first render but is frozen at that size for the run.
10. **External `program.send(msg)`** — already filed in TUI_RUNTIME.md as v0.2 work. Goroutines outside the runtime can't push messages in. Not a deckbuilder blocker but blocks any app with a network/file-watch input source.

---

### Compiler-side friction (re-recorded from sprint)

These are bugs/gaps in the compiler that the deckbuilder routinely hits. Each is an existing bug doc; included here so the TUI roadmap is honest about its substrate.

| ID | Symptom | Workaround in deckbuilder |
|---|---|---|
| `feedback_chained_field_access_generic_erases.md` | `c.hand.items[idx]` erases element type | Explicit annotations on intermediate locals |
| `EXHAUSTIVENESS_CHECK_SEGV_ON_QUALIFIED_VARIANT_PATTERN` | Compiler SIGSEGV on `match { module::Type::NoArgVariant => ... }` | Use bare variant or `is` keyword |
| `PATTERN_PARSER_REJECTS_QUALIFIED_VARIANT` (sub-bug b) | Bare PascalCase in nested pattern is treated as binding | Use `match outer { ::Variant => ... }` or `is` |
| `feedback_empty_match_arm_types_as_int.md` | `None => # comment` types as Int | Explicit no-op (`vec_push(parts, "")`) |
| `feedback_intrinsic_name_shadow.md` | User defs colliding with intrinsics now hard-error (CLOSED) | n/a |

A "compiler-bug-fix sprint" alongside the TUI consolidation would reduce per-app friction across all future consumers. Out of scope for this roadmap but tracked.

---

### Prioritized work plan

Ordering rationale: foundation (unblocks all downstream) → visual quality wins (cheap, high-impact) → framework primitives (more apps benefit) → wiring (correctness) → polish (reach).

Each phase is intended to be a single self-contained commit (or small commit chain) with regression specs. Estimates in quartz-days (traditional ÷ 4 per Prime Directive #9).

---

#### Phase 1 — Foundation *(SHIPPED 2026-05-05, ~0.5 quartz-days actual vs 1.5 estimated)*

**Goal**: extract reusable substrate. Every other phase consumes this.

Phase 1 shipped end-to-end in a single session. Two findings against the original plan:

1. **`vec_clone` and `vec_slice` already exist as polymorphic intrinsics** in the compiler (registered in `intrinsic_registry.qz`, handled in `cg_intrinsic_vec.qz`). The roadmap proposed adding them at user-level — the audit missed that the substrate was further along than visible from the deckbuilder hand-rolls. Net result: only three new user-level wrappers needed.
2. **The `tc_infer_type_param_mapping is bare-only` feedback memo was stale** — wrapped-param inference (`Vec<T>`, `HashMap<K,V>`, nested) is fixed via `tc_unify_param_ann` recursive unification at `typecheck_generics.qz:386`, with regression spec at `spec/qspec/wrapped_param_inference_spec.qz`. Memo updated.

**1.1 Generic `Vec<T>` ops in `std/vec.qz`** *(SHIPPED — 0.25 days actual)*

Three immutable-interface wrappers landed in `std/vec.qz` (existing intrinsics absorb the other two):

```be
def vec_remove_at<T>(src: Vec<T>, idx: Int): Vec<T>             # clone + delete
def vec_concat<T>(a: Vec<T>, b: Vec<T>): Vec<T>                 # clone + extend
def vec_pop_n_from_end<T>(src: Vec<T>, n: Int): (Vec<T>, Vec<T>)
# Already polymorphic intrinsics — exposed directly:
#   vec_clone(v) — replaces _vec_clone_card / vec_string_clone
#   vec_slice(v, start, len)
```

- Regression spec at `spec/qspec/vec_immutable_helpers_spec.qz` (21 cases against `Vec<Int>`, `Vec<String>`, `Vec<UserStruct>`). All green.
- Deckbuilder's `_vec_clone_card`, `_vec_remove_at_card`, `_vec_concat_card`, `_vec_pop_n_card` deleted; all 7 callsites migrated.
- `std/tui/widgets/_string_helpers.qz::vec_string_clone` deleted; both viewport callsites migrated to `vec_clone`.

**1.2 `clamp_to_terminal_width` in `std/tui/layout.qz`** *(SHIPPED — 0.1 days actual)*

```be
def clamp_to_terminal_width(min: Int, max: Int): Int
```

Reads `terminal::term_get_width()`, subtracts 2 for the border, clamps to `[min, max]`. Spec at `spec/qspec/clamp_to_terminal_width_spec.qz` (4 cases: narrower-than-min, wider-than-max, in-range, min==max). Deckbuilder's hand-rolled `view_inner_width()` is now a one-line wrapper.

**1.3 Style integration into deckbuilder** *(SHIPPED — visual confirmed, with workaround for compiler bug)*

The deckbuilder now consumes `std/style.qz`:

- HP bar fill colors red <25%, yellow <50%, green ≥50% (semantic gradient, applies to player and enemy bars equally).
- Block stat: cyan + bold.
- Energy stat: yellow + bold.
- Combat header / "[?] help" / pile line: `Style.muted()`.
- Status `»` line: dispatches on a new `status_kind: Int` field (STATUS_INFO/SUCCESS/WARNING/ERROR), styled via `Style.success/warning/error/new` at view time. Set at six call sites (initial state, energy-blocked play, successful play, defeat hit, surviving hit warning, surviving hit error).
- Card cost `(N)` renders bold via `Style.new().bold()`.
- Reward / defeat headlines: `Style.success()` / `Style.error()` (with the workaround below — only one styled piece per concat).

User confirmed Combat-screen rendering on a real terminal (HP gradient, energy-yellow, block-cyan, semantic status colors, muted header, bold cost) — all green visually. **Victory→Reward transition SEGV** surfaced a compiler bug filed at `docs/bugs/STYLE_RENDER_CONCAT_CORRUPTION.md`: two `Style.X().render(...)` results directly concatenated with `+` SEGV (or silently corrupt the result with an intervening write). Workaround applied to `view_reward` and `view_defeat`: render only one of the two header pieces; leave the other plain. All 263 specs (existing + 25 new) pass.

**Workaround removed 2026-05-06** (compiler bug closed at `b0417878` — `STYLE_RENDER_CONCAT_CORRUPTION`). `view_reward` now styles both headline (`Style.success()`) and meta (`Style.muted()`); `view_defeat` styles both headline (`Style.error()`) and "[?] help" hint (`Style.muted()`).

**1.4 `str_join` adoption** *(SHIPPED — 0.05 days actual)*

- `show_card`'s parts-vec-then-loop-concat replaced with `str_join(parts, " · ")`.
- `std/tui/layout.qz::_lines_to_string` consolidated onto `str_join(lines, "\n")` — was previously a hand-rolled StringBuilder loop.
- Other apparent join sites (per-row content building in list/viewport) inspected and skipped; they compute content per iteration rather than pre-building a Vec, so `str_join` would force an extra allocation.

---

#### Phase 2 — Progress bar widget *(SHIPPED 2026-05-05, ~0.4 quartz-days actual vs 0.5 estimated)*

**Goal**: extract `hp_bar` into a real reusable widget.

Phase 2 shipped end-to-end in a single session. Three deltas vs the original plan:

1. **Struct renamed `Progress` → `ProgressBar`** to avoid colliding with `std/progress.qz`'s pre-existing `Progress` struct (the long-running task progress reporter — Quartz struct names share a global namespace). Functions correspondingly become `progress_bar_*`. `ProgressStyles` → `ProgressBarStyles` for the same reason. The roadmap's original sketch missed the collision.
2. **Added `auto_gradient: Bool` field on `ProgressBar`** (default `true`) to drive the semantic gradient explicitly rather than detecting "user customized fill style" via reading `Style` internal fields. The `progress_bar_with_auto_gradient` builder toggles it; `progress_bar_with_styles` preserves it (so apps customising track / border colours still get the gradient). `progress_bar_gradient_color(percent)` is exposed publicly for testing and consumers wanting to colour-match labels to the bar.
3. **Single-render rendering path due to STYLE_RENDER_CONCAT_CORRUPTION.** The intended four-render shape (border + fill + empty + border) was implemented and proven to work in non-TTY (qspec) but corrupted to empty bar bytes in real-TTY runs — both `+`-concat with `""` literals between renders AND `sb_append` paths failed. Verified live in the deckbuilder Phase 2 dogfood. The shipped widget renders ONLY the fill region (preserving the auto-gradient); brackets and track render as plain UTF-8. `styles.empty` and `styles.border` slots stay in `ProgressBarStyles` for forward-compat once the compiler bug is fixed. The bug doc's "two renders + literal between works" entry was insufficient guidance for ≥3 renders; updating the bug doc with the new datapoint is filed below.

**2.1 `std/tui/widgets/progress.qz`**

```be
struct ProgressBar
  current:       Int
  max:           Int
  width:         Int          # cells (excludes brackets)
  auto_gradient: Bool
  styles:        ProgressBarStyles
end

struct ProgressBarStyles
  fill:   Style                # ignored when auto_gradient = true
  empty:  Style                # reserved (see delta 3 above)
  border: Style                # reserved (see delta 3 above)
end

def progress_bar_new(current: Int, max: Int): ProgressBar
def progress_bar_with_size(p: ProgressBar, width: Int): ProgressBar
def progress_bar_with_styles(p: ProgressBar, s: ProgressBarStyles): ProgressBar
def progress_bar_with_auto_gradient(p: ProgressBar, on: Bool): ProgressBar
def progress_bar_set(p: ProgressBar, current: Int): ProgressBar
def progress_bar_percent(p: ProgressBar): Int
def progress_bar_gradient_color(percent: Int): Int
def progress_bar_view(p: ProgressBar): String
```

Renders as `[████░░░░░░] 50/100` (or styled equivalent). Default behaviour: green fill ≥50%, yellow [25%, 50%), red <25% — semantic gradient applied automatically.

**Acceptance shipped**: 22 specs (constructors / builders, view boundary cases — 0/max, max/max, current > max, current < 0, max == 0, max < 0, width == 0, width < 0, percent accessor, gradient thresholds). All green. Spec at `spec/qspec/tui_progress_spec.qz`.

**Deckbuilder migration**: `hp_bar(cur, max, width)` now wraps `progress_bar_view` and trims the widget's count suffix (the combat view formats its own `cur/max` next to the bar). Live-confirmed via expect-driven session: bar renders cleanly across full HP (50/50 green) → mid HP (21/50 yellow) → low HP (4/50 red); bottom border integrity preserved across all 9 frames.

**Filed**: STYLE_RENDER_CONCAT_CORRUPTION extends to ≥3-render chains via `sb_append` AND `+` with literal separators. Bug doc currently says "literal between works" for 2 renders; the data shipped here shows that doesn't generalise. Update to the bug doc covers the new data point. Until fixed, multi-region styled widgets must keep to a single render call per output string.

**Workaround removed 2026-05-06** (compiler bug closed at `b0417878` — `STYLE_RENDER_CONCAT_CORRUPTION`). `progress_bar_view` now renders the four-region composite (`s_border.render("[") + s_fill.render(fill_str) + s_empty.render(track_str) + s_border.render("] ")`) — `styles.empty` and `styles.border` are wired through and respected on every render.

---

#### Phase 3 — Confirm dialog *(SHIPPED 2026-05-05, ~0.4 quartz-days actual vs 0.75 estimated)*

**Goal**: extract `Overlay` into an interactive variant. Validates that the Overlay shape composes with a widget-shaped state interior.

Phase 3 shipped end-to-end in a single session. Two deltas vs the plan:

1. **Added `confirm_with_default(c, default_yes: Bool)` builder** — separate from `confirm_with_labels`. The default-No path is the right call for destructive operations (delete / quit / discard); having a one-call switch is cleaner than `confirm_with_labels(...).selected = false`. Deckbuilder uses it for the quit dialog so a stray Enter doesn't end the run.
2. **Single-render button row due to STYLE_RENDER_CONCAT_CORRUPTION** — same constraint as Phase 2. Only the SELECTED button is rendered with `styles.button_selected`; the unselected button renders plain. The `styles.button` slot stays in `ConfirmStyles` for forward-compat once the compiler bug is fixed. Visual still works because the selection contrast (inverse video on the active button vs plain bracket-text for the inactive) is more important than colouring both buttons.

**3.1 `std/tui/widgets/confirm.qz`**

```be
struct Confirm
  prompt:    String
  yes_label: String     # default "Yes"
  no_label:  String     # default "No"
  selected:  Bool       # which button is highlighted (true = Yes)
  styles:    ConfirmStyles
end

struct ConfirmStyles
  prompt:          Style
  button:          Style                 # reserved (see delta 2)
  button_selected: Style                 # default Style.new().inverse().bold()
end

enum ConfirmEvent
  Idle
  Confirmed
  Cancelled
end

def confirm_new(prompt: String): Confirm
def confirm_with_labels(c: Confirm, yes: String, no: String): Confirm
def confirm_with_default(c: Confirm, default_yes: Bool): Confirm
def confirm_with_styles(c: Confirm, s: ConfirmStyles): Confirm
def confirm_update<M>(c: Confirm, msg: tui::FrameMsg<M>): (Confirm, tui::Cmd<M>, ConfirmEvent)
def confirm_view(c: Confirm): String
def confirm_overlay(c: Confirm): ov::Overlay   # centred POS + BORDER_ROUNDED
```

Keys: ←/→ or h/l toggle selection, Enter commits the current selection, Esc cancels, Y/y hotkey commits Yes (force-selecting if needed), N/n hotkey commits No.

**Acceptance shipped**: 24 specs (constructors / builders, key dispatch event emission, key dispatch state changes, view shape, overlay sizing). All green. Spec at `spec/qspec/tui_confirm_spec.qz`.

**Deckbuilder migration**: bare `q → Cmd::Quit` now opens a "Quit run? Progress will be lost." overlay with No selected by default. Confirmed → Cmd::Quit; Cancelled → dismiss back to combat. Ctrl-C bypasses the dialog (emergency exit). Confirm has hard modal priority — when visible, it eats every key except Ctrl-C. Live-confirmed via two expect-driven sessions: q→Esc→q→l→Enter exits cleanly through Yes-path; q→Enter cancels (default No) and q→y exits cleanly through Y-hotkey path. Inverse-SGR codes verified per selection: `\x1b[1;7m[ No ]\x1b[0m` when No active, `\x1b[1;7m[ Yes ]\x1b[0m` when Yes active.

**Workaround removed 2026-05-06** (compiler bug closed at `b0417878` — `STYLE_RENDER_CONCAT_CORRUPTION`). `_confirm_button_row` now renders both buttons through their respective styles — selected button via `styles.button_selected`, unselected button via `styles.button` (default plain).

---

#### Phase 4 — Toast (timed self-dismissing overlay) *(SHIPPED 2026-05-05, ~0.5 quartz-days actual vs 0.75 estimated)*

**Goal**: validate that `Overlay` + `Cmd::After` compose into a self-managing widget. Pattern shared by status messages, error popups, achievement notifications.

Phase 4 shipped end-to-end in a single session. Three deltas vs the plan:

1. **Added `position`, `auto_color`, `with_position`, `with_auto_color`, `level_color`** beyond the original sketch. The position field defaults to `POS_BOTTOM_RIGHT` — the right anchor for transient status messages — with `with_position` to override (e.g. `POS_CENTER` for important alerts). The `auto_color` flag (default `true`) drives the level→colour mapping at render time; mirroring `ProgressBar`'s `auto_gradient` shape lets apps override styles wholesale via `with_styles` while retaining the level semantics. The original sketch had `styles: ToastStyles` plain with no level-driven default.
2. **Single-render rendering path due to STYLE_RENDER_CONCAT_CORRUPTION** — same as Phase 2/3. The whole message is rendered through one `Style.render` call per output line; `\n`-split messages render each line with the same style and rejoin via `join_vertical`. No icon prefix or composite styling.
3. **Filed compiler bug `LAMBDA_CAPTURE_BODY_NOT_REWRITTEN_TO_ENV.md`.** The original deckbuilder integration plan used a sequence-numbered `ToastExpired(seq: Int)` so stale expirations from older toasts couldn't stomp newer ones. Building the closure that captures `seq` produced LL with `%seq` referenced in the lambda body but never defined — `llc` rejected. The closure-capture lifting populates the env at construction but the body codegen continues to reference the captured local by SSA name. Workaround: drop the seq, use a top-level zero-capture thunk, accept that a fast back-to-back toast can see the older expire stomp a newer toast a few hundred ms early. Acceptable for the deckbuilder; revisit when the capture bug closes. Bug doc captures the LL, the failed workaround attempts, and where to dig.

**4.1 `std/tui/widgets/toast.qz`**

```be
struct Toast
  message:    String
  level:      ToastLevel
  ttl_ms:     Int
  position:   Int                # POS_*
  auto_color: Bool
  styles:     ToastStyles
end

struct ToastStyles
  body: Style                    # ignored when auto_color = true
end

enum ToastLevel
  Info | Success | Warning | Error
end

enum ToastEvent
  Idle | Expired
end

def toast_new(message: String, level: ToastLevel): Toast      # ttl 2500, pos BOTTOM_RIGHT, auto_color true
def toast_with_ttl(t: Toast, ttl_ms: Int): Toast
def toast_with_position(t: Toast, position: Int): Toast
def toast_with_styles(t: Toast, s: ToastStyles): Toast
def toast_with_auto_color(t: Toast, on: Bool): Toast
def toast_level_color(level: ToastLevel): Int
def toast_view(t: Toast): String                              # padded styled body
def toast_overlay(t: Toast): ov::Overlay                      # rounded border at toast.position
def toast_show_cmd<M>(t: Toast, on_expire: Fn(): tui::FrameMsg<M>): tui::Cmd<M>
```

Default level → colour: Info → plain (`COLOR_NONE`), Success → green+bold, Warning → yellow+bold, Error → red+bold. Apps wanting a fixed colour disable auto_color and supply `styles.body` via `with_styles`.

**Acceptance shipped**: 15 specs at `spec/qspec/tui_toast_spec.qz`. All green. Coverage: constructor defaults, all five builders, level→colour for all four variants, view text shape (single-line padded, multi-line preserved), overlay sizing + position propagation, `show_cmd` Cmd::After construction with the toast's ttl.

**Deckbuilder migration**: combat status row removed entirely. Status text now flashes as a transient bottom-right toast on every action that changes `Combat.status`. Status delta detection happens in `_apply_combat_with_toast` / `_apply_screen_combat_with_toast` (combat update + Victory/Defeat transitions both fire toasts on status change). Level mapping: `STATUS_SUCCESS` → Success (green), `STATUS_WARNING` → Warning (yellow), `STATUS_ERROR` → Error (red), `STATUS_INFO` → plain. TTL 2200ms — long enough to read, short enough to clear before the next action in normal play. Z-order: base view → toast overlay → quit_confirm overlay (centred modal wins on top, but the toast at bottom-right doesn't usually overlap). Live-confirmed via expect-driven sessions: toast appears on Enter (play card) with green Success colour, persists ~2.2s, clears via `ToastExpired` AppMsg. Frame-by-frame analysis: post-action frame has toast overlay at `\x1b[10;28H`; post-expiry frames are clean.

**Filed**: `docs/bugs/LAMBDA_CAPTURE_BODY_NOT_REWRITTEN_TO_ENV.md` — captures the seq-capture closure bug. Until fixed, Cmd::After/Cmd::Run/Cmd::Every thunks must be top-level zero-capture functions. The substrate-pattern memo to write up: any TUI epic phase wanting per-event state in a delayed message has to encode that state into the FrameMsg shape itself (the thunk produces a fixed-shape value), or use a top-level mutable (violates determinism), or live without it (this phase's choice).

**Workarounds removed 2026-05-06**:
- STYLE_RENDER_CONCAT (compiler bug closed at `b0417878`): `toast_view` now renders the level icon (ℹ / ✓ / ⚠ / ✗) styled with the level colour separately from the message body — `Style.X.render(icon) + " " + Style.X.render(message)`. Multi-line messages indent continuation rows by three spaces so message text aligns with line 0's body column. `toast_level_icon` exposed as a sibling of `toast_level_color`.
- LAMBDA_CAPTURE (compiler bug closed at `e94e65eb`): deckbuilder restored the seq-numbered design — `AppMsg::ToastExpired(seq: Int)`, `Game.toast_seq: Int` bumped on every fresh toast, `_clear_toast` only clears when the expiring thunk's seq matches the current seq. A stale expire from a replaced toast no longer stomps a fresher one.

---

#### Phase 5 — Status bar widget *(SHIPPED 2026-05-05, ~0.3 quartz-days actual vs 0.5 estimated)*

**Goal**: extract the "pinned one-row header/footer" pattern. Deckbuilder hand-rolls this today.

Phase 5 shipped end-to-end in a single session. Three deltas vs the original sketch:

1. **Added `StatusSegment` constructors `status_segment_left/center/right`** alongside `status_segment_with_style`. Building a segment from struct-literal syntax is verbose at every callsite (`StatusSegment { content: "x", style: Style.new(), align: ly::ALIGN_LEFT() }` × 3 segments is half the code of the bar build). The constructors absorb the alignment selection AND default the style — callers chain `with_style` only when they want a non-plain style. Mirrors the `confirm_new` / `toast_new` ergonomic shape across the rest of the widget family.
2. **Added `status_bar_append`** for incremental construction. The original sketch was `with_segments(b, vec)`-only, requiring callers to pre-build a Vec. `append` is right for the loop-and-build pattern (see deckbuilder migration below) and saves the per-build vec_new + 3× vec_push ceremony at every consumer site.
3. **Render path is `str_join` over a Vec of pre-rendered styled segments interleaved with literal-space spacers** — sidesteps STYLE_RENDER_CONCAT_CORRUPTION while supporting multiple styled segments per bar. This is the FIRST widget that renders multiple Style.render results into a single horizontal output line; the existing dodge (toast, progress, confirm) was "render only one piece." `str_join` with a Vec of pre-rendered fragments has the property that the LL produced by the compiler doesn't ever emit a `Style.render(a) + Style.render(b)` shape — every `+` in str_join's loop has at least one operand that's not a freshly-rendered string. Confirmed via the deckbuilder migration below: 3-muted-segment header renders cleanly with no SEGV.

**5.1 `std/tui/widgets/status_bar.qz`**

```be
struct StatusBar
  segments: Vec<StatusSegment>
  position: Int         # POS_TOP | POS_BOTTOM
  styles:   StatusBarStyles
end

struct StatusSegment
  content: String
  style:   Style
  align:   Int          # ALIGN_LEFT | ALIGN_CENTER | ALIGN_RIGHT
end

struct StatusBarStyles
  body: Style                                  # reserved for fill colour
end

def POS_TOP():    Int = 0
def POS_BOTTOM(): Int = 1

def status_segment_left(content: String): StatusSegment
def status_segment_center(content: String): StatusSegment
def status_segment_right(content: String): StatusSegment
def status_segment_with_style(s: StatusSegment, style: Style): StatusSegment

def status_bar_new(): StatusBar
def status_bar_with_segments(b: StatusBar, segs: Vec<StatusSegment>): StatusBar
def status_bar_with_position(b: StatusBar, position: Int): StatusBar
def status_bar_with_styles(b: StatusBar, s: StatusBarStyles): StatusBar
def status_bar_append(b: StatusBar, seg: StatusSegment): StatusBar
def status_bar_view(b: StatusBar, term_width: Int): String
```

Layout rules (term_width = TW): lefts pack at column 0, rights pack at column TW, centers center within TW. If lefts/rights encroach on the centre, the centre shifts but maintains at least 1-cell separation. Multi-segment same-alignment groups separate by a single space. Overflow truncates at the right edge.

**Acceptance shipped**: 23 specs at `spec/qspec/tui_status_bar_spec.qz`. All green. Coverage: position constants distinct, segment constructors set the right align, builder mutators replace the right slot, view padding (empty bar / zero-width / left-only / right-only / center-only / multi-same-align), three-pane layout, overflow truncation, styled-render strip-styles round-trip, and the canonical 60-cell deckbuilder header shape.

**Deckbuilder migration**: combat header replaces the four-spaces-separated `muted.render(...)` concat with three `status_segment_with_style(..., muted)` segments + `status_bar_view(bar, view_inner_width())`. Live-confirmed visually: `Combat — Turn 1        Fights won: 0                [?] help` renders within the 60-cell border at exact spec-predicted columns (15 + 8 + 13 + 16 + 8 = 60). No SEGV from the 3-render concat — the str_join + interleaved-spacer path holds. Reward / Defeat headers stay one-piece (single Style.render + plain meta line) for now; their two-style content shape is not the natural fit for `status_bar` (the content isn't a strip of segments — it's a styled headline + plain meta). Keeping them out of scope.

---

#### Phase 6 — Declarative help *(SHIPPED 2026-05-05, ~0.4 quartz-days actual vs 0.75 estimated)*

**Goal**: stop hand-writing the help modal. Widgets register keys; a generic builder produces the help overlay.

Phase 6 shipped end-to-end in a single session. Three deltas vs the original sketch:

1. **Added `keymap_append` and `key_binding` constructors** alongside the original `keymap_with_bindings`. The original sketch was vec-then-replace only; `keymap_append` is right for the loop-and-build pattern (deckbuilder builds three maps from chained appends — see migration below). Saves the per-keymap vec_new + N× vec_push ceremony at every consumer site, mirrors `status_bar_append` from Phase 5.
2. **Added `HelpStyles` (title / group / dismiss) + `_with_styles` API variants.** The original sketch had no style customisation. `HelpStyles` follows the per-element-Style precedent from `ConfirmStyles`/`ToastStyles`. Default values target the same heading / muted aesthetic the rest of the TUI uses (`Style.heading()` for title and group, `Style.muted()` for the dismiss hint).
3. **One-render-per-line discipline.** Title, group headings, and dismiss hint each get exactly one `Style.render` call — push to a Vec, `join_vertical` at the bottom. Binding rows are plain so they don't compete with the section headers. No two render results land in the same `+` expression; sidesteps STYLE_RENDER_CONCAT_CORRUPTION on every line of the modal.

**6.1 `std/tui/help.qz`**

```be
struct KeyBinding
  key:    String        # display label, e.g. "↑↓"
  action: String        # description, e.g. "navigate hand"
end

struct KeyMap
  group:    String                 # e.g. "Combat", "Reward", "Anywhere"
  bindings: Vec<KeyBinding>
end

struct HelpStyles
  title:    Style                  # the "KEYS" banner
  group:    Style                  # group titles
  dismiss:  Style                  # the "[? to dismiss]" footer
end

def key_binding(key: String, action: String): KeyBinding
def keymap_new(group: String): KeyMap
def keymap_with_bindings(km: KeyMap, b: Vec<KeyBinding>): KeyMap
def keymap_append(km: KeyMap, key: String, action: String): KeyMap
def help_styles_default(): HelpStyles

def help_body(maps: Vec<KeyMap>): String
def help_body_with_styles(maps: Vec<KeyMap>, s: HelpStyles): String
def help_modal(maps: Vec<KeyMap>): ov::Overlay
def help_modal_with_styles(maps: Vec<KeyMap>, s: HelpStyles): ov::Overlay
```

Layout: `KEYS` banner, blank line, then per-group block (group title + each binding indented as `  KEY    ACTION` with the key column auto-padded to the widest key across all groups), groups separated by blank lines, finishing with the dismiss hint. The action column lines up across groups regardless of key length.

The full-screen replacement vs Overlay-compose decision stays at the parent's discretion — `help_modal` returns an Overlay; the parent decides whether to compose (centred floating modal) or extract `o.content` directly (full-screen).

**Acceptance shipped**: 13 specs at `spec/qspec/tui_help_spec.qz`. All green. Coverage: constructors (key_binding, keymap_new), builders (keymap_with_bindings, keymap_append), body content (title banner, dismiss hint, every group title, every key/action label, action-column alignment, default-styles invariant), modal/overlay (POS_CENTER anchor, non-zero size, content includes group titles).

**Deckbuilder migration**: `help_body()` (hand-written 7-line vec_push chain) replaced with `help_overlay()` — three keymaps (Combat: ↑↓/Enter/E, Reward: ↑↓/Enter/S, Anywhere: ?/Q) fed to `hp::help_modal`. View switched from full-screen replacement to `overlay_compose(base, help_overlay())` — help is now a centred floating modal that interrupts every other surface (Z-order: base → toast → quit_confirm → **help**). Live-confirmed via expect-driven session: `?` opens the modal at column 18, three group headings render in cyan bold (`Style.heading()`), action column aligns at column 11 across all 8 bindings (5-cell `Enter` is the longest key), dismiss hint renders muted at row 19. `?` again dismisses cleanly.

---

#### Phase 7 — SIGWINCH wiring *(SHIPPED 2026-05-05, ~0.5 quartz-days actual vs 1.0 estimated)*

**Goal**: deliver `FrameMsg::Resize(cols, rows)` when the terminal is resized.

Phase 7 shipped end-to-end in a single session. Five deltas vs the original plan:

1. **Per-signum signal_on_flag table.** The existing `signal_on_flag(signum, flag)` intrinsic stored the flag pointer in a single global, so installing two signals with different flags would clobber each other. The codegen now keeps a 32-slot `(signum, flag_ptr)` table; the trampoline scans for the matching signum on delivery, atomic-stores 1 to the per-signum flag. Same-flag-on-multiple-signums (the http_server `SIGTERM`+`SIGINT` shutdown pattern) preserved — both signums occupy distinct table slots that point at the same flag. Implemented in `self-hosted/backend/codegen_runtime.qz`. Regression spec at `spec/qspec/signal_on_flag_table_spec.qz` (6 cases: single→its-flag, signal-doesn't-touch-other, distinct-routing, shared-flag pattern, re-install redirects, uninstalled-leaves-untouched). All green.

2. **EINTR safety on stdin reads + tty writes.** Pre-Phase-7, `_term_read_byte_nb` mapped `errno=EINTR` to `-2` (EOF), and `term_write` bailed on EINTR. SIGWINCH delivery during a read or write would have looked like a fake EOF / aborted frame. Fix: treat EINTR identically to EAGAIN — non-blocking read returns "no data right now", write retries. New `EINTR(): Int = 4` constant lives in `std/ffi/socket.qz` next to `EAGAIN()`/`EWOULDBLOCK()`.

3. **Resize poller architecture.** Goroutine spawned at `program_run` startup; on each `_RESIZE_POLL_MS` (100ms) cycle, atomic-clears the resize flag and emits `FrameMsg::Resize(term_get_width(), term_get_height())` if the flag was set. Wraps in `scope_with(scope_with_cancel(runtime_scope))` like the other goroutines so it unwinds within one chunk on teardown via `scope_sleep_ms` cancel. Burst of resize events collapses into one Resize per poll cycle — semantic match for "consumers want the latest dimensions, not a count of events."

4. **Module-level var lazy init.** The atomic flag handle (`_winch_handle`) is declared `var _winch_handle = 0` at module level and lazy-initialised with `atomic_new(0)` on first `program_run` call. Module-level `var X = atomic_new(0)` (non-constant initialiser) is invisible inside generic-function bodies — the compiler resolver only exposes module-level vars with constant initialisers to generic typecheck. Sister: `go func(modvar)` — passing a module-level var directly as an argument to `go` hits a name-resolution bug; routing through a local `var winch = _winch_handle` sidesteps it. Both filed for follow-up at `docs/bugs/MODULE_VAR_NONCONST_INIT_INVISIBLE.md` and `docs/bugs/GO_CALL_ARG_MODULE_VAR_QZ0403.md` (to be created).

5. **Acceptance — what's covered.** The compiler change has 6/6 qspec coverage. The runtime wiring is verified by all 9 existing TUI specs continuing to pass on the rebuilt binary. End-to-end SIGWINCH-fires-Resize is verified by smoke test (`raise(28)` → flag set within 50ms). Live integration via deckbuilder — consumers of `view_inner_width()` (which queries `term_get_width()` per frame) get automatic reflow without code changes; the deckbuilder pattern-matches the existing `_ => return (s, Cmd::None)` fallthrough and renders against the new width on the next frame. **Apps wanting Resize-aware state** can pattern-match `tui::FrameMsg::Resize(cols, rows)` in their update.

**Filed for follow-up**:
- `docs/bugs/MODULE_VAR_NONCONST_INIT_INVISIBLE.md` — module-level `var X = f()` (non-constant init) invisible inside generic-function bodies.
- `docs/bugs/GO_CALL_ARG_MODULE_VAR_QZ0403.md` — `go fn(modvar)` reports `_resize_flag` undefined when `modvar` is a module-level binding.
- `docs/bugs/SEPARATE_COMPILATION_LOOP_METADATA_DUP.md` — pre-existing latent: `state.loop_metadata_ids` accumulates duplicates from the cached-fragment header parser; surfaced under the new SSA numbering as `Metadata id is already used !N` in `tui_confirm_spec` only. Workaround: `--no-cache` on that file.

---

#### Phase 8 — String-level overlay compositing fallback *(SHIPPED 2026-05-05, ~0.4 quartz-days actual vs 1.5 estimated)*

**Goal**: a "always works" compositing path for terminals where cursor-position absolute-positioning compositing is unreliable.

Phase 8 shipped end-to-end in a single session. Three deltas vs the original sketch:

1. **`overlay_compose_safe` defaults to the new string-level path** (the brief left this open). Apps wanting the legacy fast path call `overlay_compose` directly. The "safe" naming is deliberate — string-level merge produces a single coherent buffer with no terminal-state assumptions, working anywhere a write to stdout works. Existing direct `overlay_compose` callers (deckbuilder, help modal) unchanged — explicit choice.

2. **ANSI-aware splice via three-helper decomposition.** `_overlay_take_prefix(line, target_col)` walks codepoints + SGR escapes to grab visible cells up to the splice point (padding with spaces on short lines). `_overlay_skip_for_suffix(line, skip_cols)` walks past the splice region while collecting any active SGR codes seen, then prepends `\x1b[0m` + the collected codes to the suffix so base styling resumes after the overlay region. `_overlay_splice_row` combines prefix + overlay + suffix. Conservative: only emits the reset+replay when SGR was actually present in the skipped region — plain ASCII bases don't get SGR-cluttered output.

3. **Overflow handling.** When `_overlay_origin` clamps a too-large overlay to (1,1), the overlay can extend past the base's row count. Output extends to `max(base_h, overlay_origin_row + overlay.height)`, with overflow rows emitted standalone (no base content to splice with). Empty-base case special-cased: `str_split("", "\n")` returns one empty line; treating that as a row would pollute the output with a blank line, so empty base + non-empty overlay produces an output that is just the overlay positioned via `_overlay_origin`'s clamp.

**8.1 `std/tui/widgets/overlay.qz`** (+187 LOC; total file 359 LOC)

```be
def overlay_compose_string(base: String, o: Overlay): String
def overlay_compose_safe(base: String, o: Overlay): String
```

**Acceptance shipped**: 19 specs at `spec/qspec/tui_overlay_compose_string_spec.qz`. All green. Coverage includes: 5 anchor positions (CENTER/TOP_LEFT/TOP_RIGHT/BOTTOM_LEFT/BOTTOM_RIGHT), ANSI styling preservation in the base, overlay narrower/wider/taller/equal-to-base, empty base, zero-size overlay, line_count + visible_width invariants, `overlay_compose_safe` parity at two distinct positions, multibyte codepoint alignment, jagged base padding, overlay-internal SGR passthrough.

Render path is plain string concatenation via byte-builders (`sb_*`) and `str_join`; no `Style.render` calls in the new path, so no STYLE_RENDER_CONCAT_CORRUPTION exposure.

---

#### Phase 9 — Tabs widget *(SHIPPED 2026-05-05, ~0.4 quartz-days actual vs 1.0 estimated)*

**Goal**: multi-screen with persistent horizontal navigation.

Phase 9 shipped end-to-end in a single session. Three deltas vs the original sketch:

1. **Two-space spacer between segments, not a styled vertical bar.** The original sketch left the separator open; under STYLE_RENDER_CONCAT_CORRUPTION discipline a styled bar between two styled tab segments would have wedged a render result between two other render results, requiring the workaround pattern with no visual payoff. Plain `"  "` works because the active tab's `inverse()` styling already dominates as a divider against plain inactive segments. The `separator: Style` field stays in `TabsStyles` for forward-compat once the corruption bug closes.

   **Workaround removed 2026-05-06** (compiler bug closed at `b0417878` — `STYLE_RENDER_CONCAT_CORRUPTION`). `tabs_view` now renders a styled vertical-bar separator (` │ ` muted by default) between segments via `s_separator.render(" │ ")`.

2. **`tabs_active_item` returns `TabItem<T>` directly, not `Option`.** Brief specifies caller checks `items.size > 0`. Internally, the field-access on the generic-erased Vec is routed through a typed local `var items: Vec<TabItem<T>> = t.items` to dodge the chained-field-access generic-erasure trap (`feedback_chained_field_access_generic_erases.md`). The view path uses a `_tabs_item_label<T>(items, i)` helper for the same reason — passing the typed Vec through a function boundary preserves the inner type for field access.

3. **`_tabs_set_active` is the single Activated/Idle decision point.** All key handlers (←/→, h/l, 1-9) feed into it; same-index updates emit `Idle`, distinct-index updates emit `Activated(new_idx)`. Avoids spurious events on no-op key dispatches.

**9.1 `std/tui/widgets/tabs.qz`** (236 LOC)

```be
struct Tabs<T>
  items:    Vec<TabItem<T>>
  active:   Int
  styles:   TabsStyles
end

struct TabItem<T>
  label:   String
  payload: T
end

struct TabsStyles
  active:    Style                 # default Style.new().bold().inverse()
  inactive:  Style                 # default Style.new()
  separator: Style                 # default Style.muted() — reserved
end

enum TabsEvent
  Idle
  Activated(idx: Int)
end

def tab_item<T>(label: String, payload: T): TabItem<T>
def tabs_styles_default(): TabsStyles
def tabs_new<T>(items: Vec<TabItem<T>>): Tabs<T>
def tabs_with_active<T>(t: Tabs<T>, idx: Int): Tabs<T>
def tabs_with_styles<T>(t: Tabs<T>, s: TabsStyles): Tabs<T>
def tabs_append<T>(t: Tabs<T>, label: String, payload: T): Tabs<T>
def tabs_active_item<T>(t: Tabs<T>): TabItem<T>
def tabs_active_index<T>(t: Tabs<T>): Int
def tabs_update<T, M>(t: Tabs<T>, msg: tui::FrameMsg<M>): (Tabs<T>, tui::Cmd<M>, TabsEvent)
def tabs_view<T>(t: Tabs<T>): String
```

Keys handled by `tabs_update`: KEY_LEFT or 'h' cycles to previous (wraps to last from index 0); KEY_RIGHT or 'l' cycles to next (wraps to 0 from last); '1'..'9' jumps to that index when valid. Unrecognised keys → no-op + Idle. Empty tabs → no-op for all keys.

**Acceptance shipped**: 28 specs at `spec/qspec/tui_tabs_spec.qz`. All green. Coverage: constructors / builders (7), accessors (2), key dispatch (11 — covers ←/→, h/l, '1'..'9', wrap behaviour, out-of-range jumps, unrecognised keys, empty tabs), event emission semantics (2), and view rendering (3).

---

#### Phase 10 — Polish & Reach *(SHIPPED 2026-05-05, ~0.6 quartz-days actual vs 1.5 estimated, four items)*

Four self-contained polish items shipped together:

**10.1 Public `wrap_line` in `std/tui/layout.qz`** *(11 specs)*

Greedy word-wrap that splits on whitespace, hard-cuts words longer than `width`, and is ANSI-aware: codepoint walker tracks visible width while copying SGR escapes through verbatim. When a styled span ends a wrap segment without an explicit reset, `\x1b[0m` is appended to the segment so the terminal's colour state doesn't bleed into the next line. Tail-walk best-effort tracking — doesn't carry SGR state forward across segments (acceptable for v0.4; an SGR-stack walker can be retrofitted without API change).

```be
def wrap_line(s: String, width: Int): Vec<String>
```

Existing widget-internal `_string_helpers::wrap_line_into` left as-is; consumers can migrate as appetite arises.

**10.2 Style-aware `truncate`** *(7 specs)*

`ly::truncate` previously cut by visible width but left open SGR state lingering — a styled line cut mid-style would leak colour into anything written after. New `_truncate_walk` tracks any non-reset SGR seen during the walk; `_csi_is_sgr_reset` recognises `\x1b[0m` / `\x1b[m` / `\x1b[0;0m` / etc. as reset sequences. If a non-reset SGR was seen and the cut happens before a corresponding reset, an explicit `\x1b[0m` is appended. Plain ASCII inputs unchanged.

Spec at `spec/qspec/tui_truncate_styled_spec.qz`.

**10.3 Spinner widget at `std/tui/widgets/spinner.qz`** *(18 specs)*

For `Cmd::Run` background-task feedback. Three frame cycles supplied:

```be
def spinner_braille(): Vec<String>          # 10-frame braille rotation
def spinner_dots():    Vec<String>          # 6-frame `.  ` `.. ` `...` cycle
def spinner_line():    Vec<String>          # 4-frame `|/-\` cycle
```

Plus the value type:

```be
struct Spinner
  frames: Vec<String>
  index:  Int
  label:  String                      # optional trailing text
  styles: SpinnerStyles
end

struct SpinnerStyles
  frame: Style                        # default Style.new()
  label: Style                        # default Style.muted()
end

def spinner_new(label: String): Spinner
def spinner_with_frames(s: Spinner, frames: Vec<String>): Spinner
def spinner_with_styles(s: Spinner, styles: SpinnerStyles): Spinner
def spinner_with_label(s: Spinner, label: String): Spinner
def spinner_tick(s: Spinner): Spinner   # advance frame, wraps to 0
def spinner_view(s: Spinner): String    # `{frame} {label}` or `{frame}`
```

Render path: `frame_styled + " " + label_styled` — works because the literal `" "` separates the two render calls (sidesteps STYLE_RENDER_CONCAT_CORRUPTION). Reference: see `std/tui/widgets/status_bar.qz` for the multi-render pattern.

**10.4 Overlay `dim_base` flag** *(10 specs)*

Optional darkening of the underlying base view when an overlay is composed. Adds one field to `Overlay`:

```be
struct Overlay
  ...existing fields...
  dim_base: Bool                # default false
end

def overlay_with_dim_base(o: Overlay, dim: Bool): Overlay
```

When `dim_base` is true, both `overlay_compose` and `overlay_compose_string` wrap the base content's lines in `\x1b[2m...\x1b[0m` per line before splicing. Plain bases dim cleanly. Already-styled lines may have inconsistent appearance — the dim SGR composes with existing colours per terminal semantics, which varies. Accepted as a v0.4 limitation; better resolution awaits SGR-stack-aware compositing in a future polish phase.

**Replay test infrastructure** (Phase 10 alternate item from the original sketch) **SHIPPED 2026-05-06 at `6f4441c6`** at `spec/qspec/deckbuilder_replay_spec.qz` — 10 replay specs covering combat→Victory→Reward, combat→Defeat (7×end-turn), reward selection (Enter adds card to deck, 's' skips), quit-confirm and help modal openers, replay determinism (2× same log → same final state), and Quit termination. Uncovered + fixed a pre-existing `is Quit` cross-enum tag-collision bug in `program_replay` itself (the `is` predicate matched `Cmd::After` whenever `FrameMsg::Quit` and `Cmd::After` shared a tag value); workaround applied at the use site, root cause filed at `docs/bugs/IS_PREDICATE_CROSS_ENUM_TAG_COLLISION.md`.

**Acceptance shipped**: 46 new specs across the four items; full TUI suite (now ~430+ tests) green with no regressions.

---

---

#### Phase 11 — External `program.send(msg)` via Sender<M> *(SHIPPED 2026-05-05, ~0.2 quartz-days actual vs 0.5 estimated)*

**Goal**: close the last v0.2 runtime gap from the original "Missing"
list — let goroutines outside the runtime push messages into a
running program. Unlocks network-driven, file-watcher-driven, IPC,
and any app with a non-stdin input source.

Not in the original 10-phase plan, but the natural completion item
once Phase 7 (SIGWINCH) shipped — both are runtime-extension
features and the design space overlaps.

**11.1 New types in `std/tui/runtime.qz`**

```be
struct Sender<M>
  ch: Int                                # runtime msg_ch handle
end

def sender_send<M>(s: Sender<M>, msg: FrameMsg<M>): Int
  scope_send(s.ch, msg)
  return 0
end

def program_run_with_sender<S, M>(
  p: Program<S, M>,
  on_ready: Fn(Sender<M>): Void
): Int
```

`program_run_with_sender` is the new primary entry point;
`program_run` is now a thin alias that supplies a no-op `on_ready`.
The `on_ready` callback fires once after the runtime has its msg_ch
but before the main event loop starts blocking — a one-shot to
stash the Sender, spawn external producer goroutines, etc.

**11.2 Lifetime semantics**

The Sender is alive only for the duration of `program_run_with_sender`.
On clean Quit (or panic), the runtime scope cancels and any
goroutines using the Sender unwind via Throws — `sender_send`'s
`scope_send` is the cancel-observation point. External-sender
goroutines must wrap in `with Throws { throw: handler } do -> ... end`
to absorb the unwind cleanly. The runtime's own goroutines
(`_pump_keys`, `_run_thunk`, `_run_after`, `_run_every`) all use
this pattern — mirror it.

**Acceptance shipped**: 5 specs at `spec/qspec/tui_sender_spec.qz`.
All green. Coverage: Sender struct holds the channel handle,
sender_send round-trips App-payload messages, Quit variant,
payload-integer preservation, and multi-send FIFO ordering. The
end-to-end "external goroutine pushes into a running program"
verification is deferred to dogfood — any consumer using
`program_run_with_sender` exercises the full path. No need for a
TTY-requiring spec.

**Migration**: existing `program_run(p)` callers are unchanged —
the new alias has identical semantics. New consumers wanting an
external feed call `program_run_with_sender(p, on_ready)`.

---

### Total estimate

~9–10 quartz-days for all 10 phases (plus Phase 11 as a small
extension). By the calibration data (3-7 days for major multi-phase
features), this is on the upper end of "single feature" sized.
Phases are independent enough to interleave with other work.

The **deckbuilder** keeps growing as a parallel track: difficulty scaling, save/load, run length, multiple enemy types, relics. But each deckbuilder addition first checks the stdlib for what it needs; if missing, the gap is added to this roadmap before being hand-rolled.

---

#### Phase 12 — Sparkline + mouse parsing *(SHIPPED 2026-05-07, VIGIL prerequisites)*

Two engine-level adds driven by the VIGIL system-monitor app:

- **`std/tui/widgets/spark.qz`** — octant-blitter-backed sparkline widget. Rolling buffer (`spark_push`/`spark_clear`/`spark_size`/`spark_min`/`spark_max`/`spark_percentile`), capacity-aware right-aligned rendering, auto-scale + fixed-range modes, quality fallback (Octant → Quadrant → Half → Ascii) for terminals lacking Unicode 17 octant glyphs. `spark_with_width`/`spark_with_height` for layout-time resize without buffer rebuild. 15 specs green at `spec/qspec/spark_widget_spec.qz`.

- **SGR mouse parsing in `std/terminal.qz` + `FrameMsg::Mouse(MouseEvent)` in `std/tui/runtime.qz`** — `MouseKind` (Press/Release/Drag/ScrollUp/ScrollDown), `MouseButton` (Left/Middle/Right/NoButton), modifier bits, `term_enable_mouse`/`term_disable_mouse` (DECSET 1006+1002), defensive disable on `term_exit_raw_mode`. Existing widgets ready to consume — `viewport.qz:24` had been waiting for this. 12 specs green at `spec/qspec/term_mouse_spec.qz`.

#### Phase 13 — Two latent platform bugs surfaced by VIGIL *(FIXED 2026-05-07)*

VIGIL was the first heavy consumer of the TUI stack outside SIGIL/brogue (which use `program_run_raw` + cell engine direct). It exercised paths nobody else had:

- **`program_run` was missing alt-screen entry.** Fixed in `233aac69`. The runtime.qz docstring at line 585 already claimed `program_run` "sets up raw mode, alt screen, cursor hide" — the alt-screen part was missing in the implementation. SIGIL/brogue use `program_run_raw` which entered alt-screen correctly. Symptom: VIGIL multi-byte UTF-8 (em-dash, octant sparklines, block-element bars, ellipsis) decoded as Latin-1 in Ghostty. Reason: some terminals maintain separate charset state per screen buffer; alt-screen enters UTF-8 by default while main-screen inherits whatever charset the shell was using.

- **`std/tui/cell.qz::style_to_cells` byte-iterated instead of codepoint-walking.** Fixed in `708fd508`. The Tier-A bridge from `Style.render` to the cell engine called `sb.append_char(byte)` per byte — treating each UTF-8 continuation byte as an independent codepoint and re-encoding it. ASCII was byte-perfect (byte == codepoint), but every multi-byte glyph through `Style.render` got Latin-1-mojibake'd. The bug comment even acknowledged it as a "v0.7 task." Walks UTF-8 lead-byte structure now (`_utf8_lead_byte_len`), slices the original bytes into per-codepoint egcs via `str_byte_slice`. SIGIL/brogue dodged the bug because they emit cells through the cell engine directly, not via `Style.render`.

Both bugs were latent and would have surfaced eventually under any non-ASCII TUI workload. Catching them via "build a real app and use it" stress test was the right Prime Directive 1 move.

---

### VIGIL — system monitor sibling *(parallel track, see [`SYSMON_DESIGN.md`](SYSMON_DESIGN.md))*

Built 2026-05-07 over a single ~5-hour session. Status: **Phase 1 + 1.5 + 2 SHIPPED, polish round complete.** Lives at `examples/vigil/main.qz` with [README](../../examples/vigil/README.md). Composes the runtime + spark + mouse parsing additions above with a new `std/sys/proc.qz` system info module.

Shipped:
- 4-pane layout (CPU + MEM + DISK + NET) with octant sparklines
- Process list with sort cycle (M/P/N), kill confirm, vim navigation, mouse hit-testing
- PSI chip in CPU/MEM headers (Linux `/proc/pressure/*`, hidden on macOS)
- OOM event log panel (`journalctl -k` / `dmesg` parser)
- Anomaly hint chip (rolling p50/p95 baseline)
- Three responsive layout breakpoints — 4-across boxed tiles ≥ 240 cols, 2x2 ≥ 120, 1-wide stacked < 120
- 49 parser/widget specs across `spark` / `proc` / `mouse decoder`

**Phase 3 candidates (deferred — back-burner)**: replay log (atop's killer feature with modern UX, biggest moat), container view (Docker socket + cgroup attribution), GPU panel (NVML on Linux, `powermetrics` on macOS), network flow visualization (DNS-resolved connections), energy/power per-cgroup (RAPL), eBPF probe integration, theme YAML loading. Each is a real ~1-2 quartz-day project, not a quick win. Pull-in trigger: a specific user-facing reason (Eli wants Docker monitoring, etc).

The TUI epic is in a strong state. Further work happens opportunistically when an app surfaces a gap, or when one of the Phase 3 VIGIL candidates pulls a prerequisite back to centre stage.

---

### Cross-reference: prior memos

- [`TUI_RUNTIME.md`](TUI_RUNTIME.md) — runtime design, `FrameMsg`/`Cmd` semantics, replay-determinism contract.
- [`TUI_WIDGETS.md`](TUI_WIDGETS.md) — v0.3.2 widget design (focus, text_input, viewport, list).
- [`TUI_FORM.md`](TUI_FORM.md) — v0.3.3 form design.
- [`SYSMON_DESIGN.md`](SYSMON_DESIGN.md) — VIGIL system monitor design + phasing.
- This file — v0.4+ consolidation + roadmap.
