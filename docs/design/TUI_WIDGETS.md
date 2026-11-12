# TUI Widgets (std/tui/widgets/)

**Status**: Shipped 2026-05-04 (v0.3.2). 128 tests green across all four widgets + composite. Six steps committed.
**Stance**: Bubbletea-shaped composition (typed-children, parent-dispatches), Brick-shaped focus (FocusRing as a separate first-class abstraction), Textual-shaped events (typed Event enums, no bubbling), Lipgloss-shaped styling via `std/style`. Lives under `std/tui/widgets/` (one file per widget), marked experimental until v1.
**Driving project**: External — the deckbuilder (`game/deckbuilder` worktree, not yet bootstrapped). The framework's job is to make that project pleasant to write, and to surface stdlib gaps along the way.

---

## What this is

A small, opinionated set of composable TUI widgets. Each widget is a plain struct + module-level free functions (`text_input_new`, `text_input_update`, `text_input_view`, etc.). No `Widget` trait — the parent stores children as named fields (typed children) and dispatches to them explicitly.

Focus across multiple widgets is owned by a separate `FocusRing<Id>` value the parent constructs and manages. Tab cycles focus; the parent looks up `focus_ring_current(ring)` at dispatch time to decide which child receives keys. Each widget exposes `is_focused(w)` as a render-input parameter, not as internal state — focus lives in one place.

User writes:

- a parent **Model** that embeds widget structs as named fields plus a `FocusRing<MyId>`
- a parent **Update** that pattern-matches on `FrameMsg`, looks up the focused widget id, and forwards the message to that child
- a parent **View** that calls each child's `*_view` function and composes the strings via `std/tui/layout`

Widgets are pure value-transformers — their `update` returns `(NewWidget, Cmd<M>, Option<Event>)`. The third slot is a typed event enum reporting "what just happened semantically" (`TextInputEvent::Submitted`, `ListEvent::Highlighted(item)`, etc.) so the parent can react to one-shot signals without fishing through state.

## What this is NOT (v0.3.2)

Each cut is intentional. None are designed away — they're filed for v0.3.3+, when real deckbuilder use surfaces the need.

- ~~**No form composer.**~~ **Shipped in v0.3.3** — see `docs/design/TUI_FORM.md`. `std/tui/widgets/form.qz` ships `Form` + 11-case `Validator` enum + `FormEvent`. Settings example at `examples/tui/widgets/settings/main.qz`.
- **No table widget.** Deckbuilder's "list of cards with detail panel" is List + layout, not Table.
- **No filter built into List.** Consumers compose `TextInput + List` themselves and call `list_set_items(filtered)`. Filter-in-list is bubbles' biggest design wart (mode-switching key dispatch); we explicitly avoid it.
- **No tabs / pagination chrome / title bar / status bar / help line.** All separate widgets in v0.3.3+ if a real consumer wants them. v0.3.2 List ships minimal.
- **No spinner / progress / gauge.** Hand-rolled layout is enough for HP bars; widgetize if a second consumer appears.
- **No toast / notification overlay.** The incremental dogfood's status-message pattern (conditional second panel) covers this; Toast arrives if it shows up across two screens.
- **No multi-line text editor.** `TextInput` is single-line. `TextArea` (multi-line edit, scroll, optional syntax) is a separate v0.4+ effort with its own design memo. Brick's "not a Vim replacement" disclaimer applies.
- **No autocomplete / suggestions.** Bubbles bundles them with TextInput; we keep TextInput minimal and ship `Autocomplete` separately if real demand surfaces.
- **No mouse handling.** Inherited from runtime — v0.4+.

## Module layout

```
std/tui/
  runtime.qz
  layout.qz
  widgets/
    focus.qz        # FocusRing<Id>
    text_input.qz   # TextInput + TextInputEvent + TextInputStyles
    viewport.qz     # Viewport + ViewportEvent (rare; mostly Cmd::None)
    list.qz         # List<Item, Id> + ListEvent + ItemDelegate trait
    form.qz         # Form + FormEvent + Validator enum (v0.3.3+)
```

One file per widget. `focus.qz` ships standalone — it's just data + pure transitions, no rendering.

Imports are per-widget (narrower than an umbrella `std/tui/widgets`):

```be
import std/tui/widgets/text_input as ti
import std/tui/widgets/list as ls
import std/tui/widgets/viewport as vp
import std/tui/widgets/focus as fr
```

A save-screen consumer that uses only TextInput pays parse cost only for `text_input.qz` + `focus.qz`, not for List or Viewport. Phase B's IR-emit DCE additionally drops widget IR not transitively reached.

---

## Driving needs (deckbuilder)

| Screen | Widgets | Notes |
|---|---|---|
| Combat | hand-of-cards (custom; List-shaped but horizontal), combat log (Viewport), HP/energy bars (hand-rolled layout) | Hand-of-cards: see Q6 below. v0.3.2 ships List vertical-only; horizontal experiment lives in deckbuilder. |
| Map | none | ASCII art, custom navigation logic |
| Deck/Discard browser | List + detail panel (layout) | Selected item drives detail panel rendering |
| Save game | TextInput (name) + List (existing saves) + FocusRing | Two-widget screen, classic FocusRing demo |
| Settings | Form (v0.3.3+) | Parked — not v0.3.2 |
| New game / game over | none | Static text + key prompt |

The trio (TextInput, Viewport, List) plus FocusRing covers four of seven screens. Form / detail-panel / overlay patterns emerge in subsequent work.

---

## Quartz-substrate constraints

These are language / runtime properties that constrain the widget API and would surprise a reader coming from bubbletea or ratatui.

### 1. Parent-dispatches, no auto-routing

The runtime delivers each `FrameMsg<M>` to the user's top-level `update`. There is no built-in "focused widget receives key events automatically." The parent's `update` does the routing — usually in two lines via `focus_ring_current`:

```be
def update(msg: tui::FrameMsg<AppMsg>, m: Model): (Model, tui::Cmd<AppMsg>)
  match msg
    tui::FrameMsg::Key(k) =>
      # Tab cycles focus, then route to whoever owns it.
      if k.code == terminal::KEY_TAB()
        return (Model { ..@m, focus: fr::focus_ring_next(@focus) }, tui::Cmd::None)
      end
      match fr::focus_ring_current(@focus)
        Some(SaveFocus::NameInput) =>
          var (next, cmd, ev) = ti::text_input_update(@name, msg)
          # ... handle ev (Submitted / Changed) and rebuild model
        Some(SaveFocus::SaveList) =>
          var (next, cmd, ev) = ls::list_update(@saves, msg)
          # ...
        None =>
          return (m, tui::Cmd::None)
      end
    _ => return (m, tui::Cmd::None)
  end
end
```

This matches bubbletea's `Update` convention. The runtime stays free of focus-tracking — bad layering otherwise.

### 2. `Cmd<M>` is generic over the parent's `M`

A widget cannot emit a `Cmd<TextInputMsg>` and expect the runtime to handle it — `Cmd` is parameterized over the parent's app message type. v0.3.2 sidesteps this entirely: **widgets in v0.3.2 do not emit Cmds** (none of TextInput/Viewport/List/FocusRing have any internal asynchronous behavior — no debounced revalidation, no cursor blink, no async data load). Update returns `(Self, Cmd<M>, Option<Event>)` where the `Cmd<M>` slot is always `Cmd::None` in v0.3.2, kept in the signature for forward-compat.

When v0.3.3+ widgets need to emit cmds (e.g. List's "filter debounce" if we ever add one), we'll thread a `lift: Fn(WidgetMsg): M` parameter through then. v0.3.2 doesn't pay that ceremony.

### 3. Const-by-default forces struct-rebuild on update

Quartz has no struct-spread (`...s`). Every `update` call rebuilds the struct field by field. Mitigations:

- Keep widget structs **tight** — under 10 fields each. TextInput targets 8.
- Provide small `*_with_*` builder helpers (e.g. `text_input_with_value(t, v)`) for common one-field changes.
- Where a widget has many fields, group related fields into a substruct (e.g. `TextInputStyles { prompt, cursor, placeholder, value }` is one field on `TextInput`, rebuilt as a unit).

### 4. No Widget trait

We considered a `trait Widget<M>` for polymorphism. **Rejected.** Reasons:

- Quartz's existential type model erases generics at runtime — trait-dyn buys very little vs typed children.
- Typed children give the parent `update` exhaustive matching and direct access to widget-specific methods (`text_input_value(t)`) without downcasts.
- v0.3.2 has no consumer that benefits from polymorphism. Form (v0.3.3+) is the first; we'll introduce a trait then if it's the right answer, or stick with typed children.

This is a deliberate non-abstraction. Widgets share a *naming convention* — `*_new`, `*_update`, `*_view`, `*_set_size`, and the `(Self, Cmd<M>, Option<Event>)` return shape — but no trait enforces it. The convention is short enough to keep in your head.

### 5. Styling via `std/style.qz` + semantic Theme map

Existing module provides Lipgloss-shaped chainable `Style` with `Style.new().bold().fg(Red).render(s)`. Auto color-degradation built in.

We layer two concepts:

- **Per-widget `*Styles` struct** (Bubbles shape) — concrete `Style` values for each themable slot. E.g.:
  ```be
  struct TextInputStyles
    prompt:      style::Style
    value:       style::Style
    placeholder: style::Style
    cursor:      style::Style
  end
  ```
  Default constructor returns sensible-default styles (`text_input_styles_default()`).

- **Semantic `Theme` attribute map** (Brick shape) — a value the *app* constructs once with semantic colors:
  ```be
  struct Theme
    primary:     Int   # accent color
    accent:      Int
    error:       Int
    surface:     Int
    surface_alt: Int
    text:        Int
    text_muted:  Int
  end
  ```
  Apps build their `*Styles` structs by referencing the Theme's slots. Theme-swap at runtime is just rebuilding the `*Styles` structs from a different Theme.

This gives runtime theme-swap (Brick's superpower) without inventing a CSS engine. We do *not* adopt Textual's CSS cascade — too much surface, too many edge cases.

### 6. wcwidth-aware width

`std/unicode/width::unicode_width(cp)` (shipped v0.3.1) is canonical. Widget rendering that needs alignment consults it via `std/tui/layout::visible_width(s)`. Wide chars and emoji align correctly without per-widget effort.

### 7. Resize protocol

The runtime doesn't ship SIGWINCH handling yet (v0.3+ on the runtime roadmap). When it does, the protocol is:

- Runtime emits `FrameMsg::Resize(cols, rows)` to the user's `update`.
- Parent forwards by calling `widget_set_size(child, w, h)` for each child sized to fill an area.
- Viewport invalidates its wrap cache; List recomputes visible-rows; TextInput re-clamps cursor if width shrank below cursor pos.

Until SIGWINCH ships, the parent calls `*_set_size` once at startup with the terminal dimensions (`term_size()` from `std/terminal`). All widgets handle "size unchanged" calls efficiently (no-op when w/h match).

---

## Prior-art summary

(Distilled from the research subagent's report; full sources at end.)

### Bubbletea + Bubbles (Go) — closest reference, dominant influence

Bubbletea's runtime contract is what Quartz already ships. Bubbles widgets are themselves `tea.Model`s — same shape as user models, composed by the parent embedding them as named fields and forwarding messages explicitly. There is no auto-routing. We adopt this composition discipline directly.

What Bubbles gets right and we copy:
- **Typed-children composition.** Parent embeds children as named fields; parent's update forwards messages explicitly.
- **`ItemDelegate` separation in List** — rendering decoupled from list data. We borrow this verbatim.
- **Per-widget `Style` field defaults** — easy to override field-by-field.
- **`Validate` as a function field** — first-class validation, not a separate concept.
- **Dual-index selection** — filtered position vs master-list position, both exposed.

What Bubbles gets wrong and we improve:
- **`Focus()` returns `Cmd`** — getter-shaped name with a side effect (cursor blink command) that has to be threaded back through Init/Update. We make `text_input_focus(t)` a pure state setter; cursor blink is not in v0.3.2.
- **List is a kitchen sink** — paginator, help, filter, status bar, title all baked into one model. We ship List minimal; those concerns are separate composable widgets in v0.3.3+.
- **Viewport `SetContent(string)` whole-blob only** — the combat log is the canonical streaming case, and `SetContent(big_string)` per frame is the wrong shape. We ship `viewport_append_line` / `append_lines` from day one.
- **No focus story** — every widget has its own `focused` bool, every parent's `Update` becomes a tangle of "if focus == X forward to X." We adopt FocusRing.
- **Validators run on every `SetValue` including programmatic restores** — surprises users restoring from save. We separate `text_input_set_value` (validates) from `text_input_set_value_unchecked` (skips, for restore).

### Ratatui (Rust) — different paradigm, two ideas worth borrowing

Ratatui is immediate-mode: widgets are transient builders rebuilt every frame from current state, persistent state lives in user-owned structs (`ListState`, `ScrollbarState`). Doesn't ship a text input or a focus story.

What we borrow:
- **State struct shape** — `ListState { selected: Option<Int>, offset: Int }` is the minimal correct selection+scroll memo. Don't re-derive offset on every render; store it. This maps cleanly to TEA's "state is in the model."
- **Builder-style `with_*` chaining** — readable for one-field-at-a-time configuration. We ship `text_input_with_prompt`, `list_with_delegate`, etc.

What we don't inherit: ratatui's lack of input/focus widgets isn't a gap to copy — we ship those.

### Textual (Python) — reactive declarative, two ideas worth borrowing

Textual has CSS-like styling, reactive attributes with watchers, message-bubbling event tree. Different paradigm; mostly incompatible with TEA. But two concepts are gold:

- **Typed message classes** (`Input.Submitted`, `Input.Changed`, `Input.Blurred`) carrying contextual data. Concrete types beat opaque dispatch. We adopt this as the `*Event` enums returned in the third slot of `update`.
- **Two messages per interaction** in lists: `Highlighted` (cursor moved, no commit) distinct from `Selected` (Enter pressed, commit). You almost always want both — preview pane on highlight, commit on select. We adopt.

We skip: full CSS cascade (too much surface), reactive attributes (need a runtime our pure update doesn't have), bubbling with `stop()` (assumes tree-walking dispatcher we don't have).

### Brick (Haskell) — two killer ideas

Brick is FRP-flavored, Haskell-native, less mainstream. Two ideas are exceptional:

- **FocusRing** — first-class focus-cycle abstraction, separate from widget state. `FocusRing<Id>` is a value the parent owns; `focus_ring_current(ring)` answers "who's focused?", `focus_ring_next/prev` rotates. Widgets render with an explicit `focused: Bool` parameter — they don't know if they're focused; the caller asserts it. **This is the cleanest focus story in any TUI library.** We adopt verbatim, adapted to Quartz.
- **Attribute map for theming** — semantic names (`"button.focused"`) map to colors with hierarchical fallback. We adopt as our `Theme` struct (less general than Brick's runtime-loadable map but covers the same use case).

We skip: Brick's lens-based `zoom` for nested updates is Haskell-idiomatic, doesn't translate; manual struct rebuild is the realistic equivalent.

---

## Recommended design

### `focus.qz` — FocusRing<Id>

```be
## A FocusRing owns the focus cycle for a parent's children. The parent
## constructs one with the list of focusable child ids, asks
## `focus_ring_current(ring)` at dispatch time to decide who gets keys,
## and rotates with `focus_ring_next` / `focus_ring_prev` (typically
## bound to Tab / Shift-Tab in the parent's update).
##
## `Id` is whatever enum the parent uses to label its children — one
## variant per focusable widget. The ring is a thin wrapper around a
## Vec<Id> + a current-index Option.
struct FocusRing<Id>
  ids:     Vec<Id>
  current: Option<Int>   # index into ids, or None if no focus
end

def focus_ring_new<Id>(ids: Vec<Id>): FocusRing<Id>
def focus_ring_with_initial<Id>(ids: Vec<Id>, initial: Id): FocusRing<Id>
def focus_ring_current<Id>(r: FocusRing<Id>): Option<Id>
def focus_ring_next<Id>(r: FocusRing<Id>): FocusRing<Id>
def focus_ring_prev<Id>(r: FocusRing<Id>): FocusRing<Id>
def focus_ring_set<Id>(r: FocusRing<Id>, id: Id): FocusRing<Id>  # jump to specific id
def focus_ring_clear<Id>(r: FocusRing<Id>): FocusRing<Id>
def focus_ring_is_focused<Id>(r: FocusRing<Id>, id: Id): Bool
```

`Id` requires `Eq` so we can compare for `set` and `is_focused`. Bounded generic.

### `text_input.qz` — TextInput

```be
enum TextInputEvent
  None         # no semantic event (the common case)
  Changed      # value changed via keypress
  Submitted    # Enter pressed (only if validation passed when ValidateOn::OnSubmit)
  Blurred      # widget lost focus this update (rare; usually parent-driven)
end

enum ValidateOn
  Never
  OnChange       # default — validate after each character edit
  OnSubmit       # validate only when Enter pressed
  OnBlur         # validate on focus loss
end

struct TextInputStyles
  prompt:      style::Style
  value:       style::Style
  placeholder: style::Style
  cursor:      style::Style
end

struct TextInput
  value:           String
  cursor:          Int                        # codepoint index into value
  prompt:          String                     # rendered before value
  placeholder:     String                     # rendered when value empty + unfocused
  max_length:      Int                        # 0 = unlimited
  validator:       Fn(String): Result<(), String>   # default: always Ok
  validate_on:     ValidateOn
  last_error:      Option<String>             # populated after validation runs
  styles:          TextInputStyles
end

# constructor + builders
def text_input_new(): TextInput
def text_input_with_prompt(t: TextInput, p: String): TextInput
def text_input_with_placeholder(t: TextInput, ph: String): TextInput
def text_input_with_max_length(t: TextInput, n: Int): TextInput
def text_input_with_validator(t: TextInput, v: Fn(String): Result<(), String>): TextInput
def text_input_with_validate_on(t: TextInput, when: ValidateOn): TextInput
def text_input_with_styles(t: TextInput, s: TextInputStyles): TextInput

# accessors
def text_input_value(t: TextInput): String
def text_input_last_error(t: TextInput): Option<String>

# state setters (programmatic; do NOT validate)
def text_input_set_value_unchecked(t: TextInput, v: String): TextInput
def text_input_clear(t: TextInput): TextInput

# update + view (focused passed in by parent — widget doesn't know)
def text_input_update(
  t: TextInput,
  msg: tui::FrameMsg<M>
): (TextInput, tui::Cmd<M>, TextInputEvent)

def text_input_view(t: TextInput, focused: Bool): String

# resize
def text_input_set_size(t: TextInput, w: Int, h: Int): TextInput   # h ignored (single-line)
```

Edit semantics:
- Printable codepoint → insert at cursor, advance cursor.
- Backspace → delete codepoint before cursor, retract cursor.
- Delete → delete codepoint at cursor.
- Left/Right → move cursor one codepoint.
- Home/End → cursor to start/end.
- Ctrl-W → delete word before cursor (whitespace-bounded).
- Ctrl-U → delete to start.
- Enter → emit `Submitted` event after running validator (if `ValidateOn::OnSubmit`); validator failure populates `last_error` and emits `Changed` instead.
- Other keys → no-op (parent decides what to do with Tab, Esc, Ctrl-C — they don't reach here unless the parent forwarded them).

Cursor rendering: at cursor position, the codepoint is rendered with `styles.cursor` (typically a reverse-video block); rest with `styles.value`. Single-line, no scrolling within input — exceeds-width content is clipped at the right edge for v0.3.2 (horizontal scroll within input is v0.3.3+ if it surfaces).

### `viewport.qz` — Viewport

```be
enum ViewportEvent
  None
  Scrolled       # offset changed this update (rare consumers care; parent's view re-renders anyway)
end

struct ViewportStyles
  text:       style::Style    # base text style
  scrollbar:  style::Style    # scrollbar track + thumb
end

struct Viewport
  lines:        Vec<String>   # one entry per logical line (post-\n split)
  width:        Int
  height:       Int
  y_offset:     Int           # top visible line index
  soft_wrap:    Bool          # if true, lines longer than width are wrapped at render time
  follow_tail:  Bool          # if true, append* operations auto-scroll to bottom
  show_scrollbar: Bool        # right-edge column shows scroll position
  styles:       ViewportStyles
end

# constructor + builders
def viewport_new(): Viewport
def viewport_with_size(v: Viewport, w: Int, h: Int): Viewport
def viewport_with_soft_wrap(v: Viewport, on: Bool): Viewport
def viewport_with_follow_tail(v: Viewport, on: Bool): Viewport
def viewport_with_scrollbar(v: Viewport, on: Bool): Viewport
def viewport_with_styles(v: Viewport, s: ViewportStyles): Viewport

# content management
def viewport_set_content(v: Viewport, s: String): Viewport            # split on \n
def viewport_set_content_lines(v: Viewport, lines: Vec<String>): Viewport
def viewport_append_line(v: Viewport, line: String): Viewport
def viewport_append_lines(v: Viewport, lines: Vec<String>): Viewport
def viewport_clear(v: Viewport): Viewport

# scroll commands (also wired to keys in update)
def viewport_scroll_up(v: Viewport, n: Int): Viewport
def viewport_scroll_down(v: Viewport, n: Int): Viewport
def viewport_page_up(v: Viewport): Viewport
def viewport_page_down(v: Viewport): Viewport
def viewport_goto_top(v: Viewport): Viewport
def viewport_goto_bottom(v: Viewport): Viewport
def viewport_ensure_visible(v: Viewport, line_idx: Int): Viewport

# accessors
def viewport_at_top(v: Viewport): Bool
def viewport_at_bottom(v: Viewport): Bool
def viewport_scroll_percent(v: Viewport): Int   # 0..100

# update + view
def viewport_update(
  v: Viewport,
  msg: tui::FrameMsg<M>
): (Viewport, tui::Cmd<M>, ViewportEvent)

def viewport_view(v: Viewport, focused: Bool): String

def viewport_set_size(v: Viewport, w: Int, h: Int): Viewport   # invalidates wrap cache
```

Implementation notes:
- `lines: Vec<String>` not blob (Bubbles' design lesson).
- Soft-wrap: when `soft_wrap == true`, render-time computes wrapped lines lazily and caches in a private field invalidated by `set_*` / `append_*` / `set_size`. v0.3.2 ships with a naive recompute-on-every-render; cache is a future optimization if combat log perf surfaces.
- `follow_tail`: idiomatic combat log: `viewport_with_follow_tail(true)`. Manual scroll-up disengages tail-following until user pages back to bottom (`at_bottom == true` re-engages).
- Scrollbar: rendered in the rightmost column when `show_scrollbar == true` and content overflows. Single-character thumb showing scroll percent.

### `list.qz` — List<Item, Id>

```be
enum ListEvent<Item>
  None
  Highlighted(item: Item)   # cursor moved
  Selected(item: Item)      # Enter pressed on highlighted item
end

struct ListStyles
  cursor:        style::Style    # selected-row indicator
  cursor_text:   style::Style    # selected-row text
  text:          style::Style    # unselected-row text
  scrollbar:     style::Style
end

# ItemDelegate is the rendering policy — a value the consumer constructs
# to teach List how to render their item type. Mirrors Bubbles' delegate.
struct ItemDelegate<Item>
  render:  Fn(Item, Bool, Int): String   # item, is_selected, width → rendered row
  height:  Int                            # rows per item (1 for single-line; >1 for card-style)
end

def item_delegate_simple<Item>(
  show: Fn(Item): String
): ItemDelegate<Item>
# default: 1-line render that wraps `show(item)` in cursor styles when selected

struct List<Item>
  items:           Vec<Item>
  delegate:        ItemDelegate<Item>
  selected:        Option<Int>    # index into items
  offset:          Int            # top visible item index
  width:           Int
  height:          Int
  show_scrollbar:  Bool
  wrap_around:     Bool           # cursor wraps from last to first on Down past end
  styles:          ListStyles
end

# constructor + builders
def list_new<Item>(items: Vec<Item>, delegate: ItemDelegate<Item>): List<Item>
def list_with_size<Item>(l: List<Item>, w: Int, h: Int): List<Item>
def list_with_scrollbar<Item>(l: List<Item>, on: Bool): List<Item>
def list_with_wrap_around<Item>(l: List<Item>, on: Bool): List<Item>
def list_with_styles<Item>(l: List<Item>, s: ListStyles): List<Item>

# items management
def list_set_items<Item>(l: List<Item>, items: Vec<Item>): List<Item>
# clamps selected/offset to new range; preserves selection if possible by
# index (consumers wanting stable-by-id selection across set_items
# compose by re-finding the previously-selected item's new index and
# calling list_set_selected)

# accessors
def list_selected_index<Item>(l: List<Item>): Option<Int>
def list_selected_item<Item>(l: List<Item>): Option<Item>
def list_size<Item>(l: List<Item>): Int

# state setters
def list_set_selected<Item>(l: List<Item>, idx: Int): List<Item>
def list_select_first<Item>(l: List<Item>): List<Item>
def list_select_last<Item>(l: List<Item>): List<Item>
def list_select_next<Item>(l: List<Item>): List<Item>
def list_select_prev<Item>(l: List<Item>): List<Item>

# update + view
def list_update<Item>(
  l: List<Item>,
  msg: tui::FrameMsg<M>
): (List<Item>, tui::Cmd<M>, ListEvent<Item>)

def list_view<Item>(l: List<Item>, focused: Bool): String

def list_set_size<Item>(l: List<Item>, w: Int, h: Int): List<Item>
```

Selection semantics:
- `selected: Option<Int>`. Empty list → `None`. Non-empty default → `Some(0)`.
- Up/Down moves cursor. Home/End jumps to first/last. PgUp/PgDn moves by visible page height.
- Enter emits `Selected(item)`; cursor movement emits `Highlighted(item)`.
- Items setter clamps `selected` to `[0, items.size - 1]`.
- For filter use case (consumer-composed with `TextInput`): consumer maintains `master_items: Vec<Card>`, computes `filtered: Vec<Card>` from filter input, calls `list_set_items(filtered)`. Consumer is responsible for re-finding `selected_item`'s new index in the filtered Vec if they want selection-stability across filters.

### Composition example — Save Game screen sketch

```be
import std/tui/runtime as tui
import std/tui/widgets/text_input as ti
import std/tui/widgets/list as ls
import std/tui/widgets/focus as fr
import std/tui/layout as ly

enum SaveFocus
  NameInput
  SaveList
end

struct SaveScreen
  name:  ti::TextInput
  saves: ls::List<String>
  focus: fr::FocusRing<SaveFocus>
end

def save_screen_new(existing: Vec<String>): SaveScreen
  var ids = vec_new()
  vec_push(ids, SaveFocus::NameInput)
  vec_push(ids, SaveFocus::SaveList)
  return SaveScreen {
    name:  ti::text_input_with_prompt(ti::text_input_new(), "Save name: "),
    saves: ls::list_new(existing, ls::item_delegate_simple(s -> s)),
    focus: fr::focus_ring_with_initial(ids, SaveFocus::NameInput)
  }
end

def save_update(msg: tui::FrameMsg<AppMsg>, m: SaveScreen): (SaveScreen, tui::Cmd<AppMsg>)
  match msg
    tui::FrameMsg::Key(k) =>
      if k.code == terminal::KEY_TAB()
        return (SaveScreen { ..@m, focus: fr::focus_ring_next(@focus) }, tui::Cmd::None)
      end
      match fr::focus_ring_current(@focus)
        Some(SaveFocus::NameInput) =>
          var (next_input, cmd, ev) = ti::text_input_update(@name, msg)
          # On Enter (Submitted), commit save with current name
          if ev is Submitted
            return (m, tui::Cmd::Run(commit_save_thunk(ti::text_input_value(next_input))))
          end
          return (SaveScreen { ..@m, name: next_input }, cmd)
        Some(SaveFocus::SaveList) =>
          var (next_list, cmd, ev) = ls::list_update(@saves, msg)
          # On selection, prefill name with the chosen save
          match ev
            ls::ListEvent::Selected(name) =>
              var prefilled = ti::text_input_set_value_unchecked(@m.name, name)
              return (SaveScreen { name: prefilled, saves: next_list, focus: @m.focus }, cmd)
            _ =>
              return (SaveScreen { ..@m, saves: next_list }, cmd)
          end
        None => return (m, tui::Cmd::None)
      end
    _ => return (m, tui::Cmd::None)
  end
end

def save_view(m: SaveScreen): String
  var name_focused = fr::focus_ring_is_focused(@m.focus, SaveFocus::NameInput)
  var list_focused = fr::focus_ring_is_focused(@m.focus, SaveFocus::SaveList)
  return ly::join_vertical(vec_of(
    ti::text_input_view(@m.name, name_focused),
    "",
    ls::list_view(@m.saves, list_focused),
    "",
    "[Tab cycle · Enter confirm · Ctrl-C cancel]"
  ))
end
```

The boilerplate per screen is ~30 lines of update + ~12 lines of view. Adding a third widget adds one match-arm + one focus-aware view call. Linear cost.

---

## Open design questions resolved

These are the post-research answers to the open questions in the prior draft.

### Q1 — Trait or no trait? **No trait in v0.3.2.**

Typed children + naming convention. Revisit when Form arrives in v0.3.3+; trait may be the right answer then, may not be. We have time.

### Q2 — Selection model in List? **Index-based, with `selected_item()` accessor; consumer-managed stability.**

Internal state is `selected: Option<Int>`. Consumer wanting "stable selection across filter" composes by reading `selected_item()`, computing the new filtered Vec, and calling `list_set_selected(idx_of_item_in_new_vec)`. The library doesn't track item identity — the consumer knows what makes their items unique.

### Q3 — Viewport content-set: copy or stream? **Both, from day one.**

`set_content(s)`, `set_content_lines(lines)`, `append_line(line)`, `append_lines(ls)`, `clear()`. The combat log is canonical streaming; bake it in.

### Q4 — TextInput validation? **`ValidateOn` enum, default `OnChange`.**

`Fn(String): Option<String>` validator field (None = valid; Some(msg) = error) with `ValidateOn::{Never, OnChange, OnSubmit, OnBlur}`. Default `OnChange` matches Textual's `validate_on=["changed"]` cheap-validator default. Cheap validators (length checks) want `OnChange`; expensive ones (filename uniqueness) opt into `OnSubmit`. Validation result populates `last_error: Option<String>`.

(Originally specced as `Fn(String): Result<Void, String>`; switched to `Option<String>` mid-implementation. `Void` doesn't have a value-level constructor in Quartz, and `Option` is the cleaner shape — None for valid, Some for error message.)

### Q5 — Focus model? **FocusRing<Id>, separate first-class abstraction.**

Brick's design verbatim. Per-widget `focused: Bool` is a *render-input parameter*, not internal state. Single source of truth for "who's focused" is the parent's `FocusRing`.

### Q6 — Hand-of-cards: List variant or its own widget? **Decided in deckbuilder, not now.**

v0.3.2 ships List vertical-only. The deckbuilder's combat-screen experiment will determine whether horizontal-orientation belongs as a List parameter or as a separate `Carousel` widget. Premature to choose.

### Q7 — Widget messages: opaque or typed? **Typed `*Event` enums, returned as third slot of `update`. Variant named `Idle`, NOT `None`.**

`update(self, msg) → (Self, Cmd<M>, Event)` where Event is a per-widget enum with an `Idle` variant for "no semantic event."

Originally spelled the no-event variant `None` to match Option's idiom. **`is None` SIGSEGVs at runtime** when applied to a non-Option enum — the `is` keyword's compilation conflates `Option::None` with any None-named variant in any enum and dereferences a wild pointer. Renamed all three event enums (TextInputEvent, ViewportEvent, ListEvent) to use `Idle` instead. Filed in memory.

### Q8 — Test surface? **Pure-update tests + narrow view-substring tests + style-strip helper.**

QSpec coverage per widget: ~20 update tests driving message sequences and asserting state. View tests use `ly::strip_styles(s)` to drop ANSI escapes for plain-text comparison, then assert substring presence (cursor position, selection highlight, etc.). Add `ly::strip_styles` to layout module if missing (probably is — file as v0.3.2 sub-deliverable).

### Q9 (NEW) — How does the parent rebuild a struct with one child changed?

Quartz has no struct-spread today. Until we add it (separate language design memo), the idiom is full-rebuild. The save-screen example above uses a hypothetical `SaveScreen { ..@m, name: next_input }` syntax — **that doesn't exist in Quartz**. Real code is:

```be
return (SaveScreen { name: next_input, saves: m.saves, focus: m.focus }, cmd)
```

This grows linearly with field count. Mitigations in this design:
- Parent screens stay narrow (~5 fields).
- Helper builders for one-field updates if the friction surfaces.

**Followup filed**: struct-spread / functional update syntax (`Foo { ..base, x: y }`) is a real ergonomic want — file in language ROADMAP separately. Out of scope for v0.3.2.

### Q10 (POST-IMPLEMENTATION) — Why does ItemDelegate take `Fn(Item): String` instead of `Fn(Item, Bool, Int): String`?

The original design took the bubbletea-shaped delegate signature: `render(item, is_selected, width)` so the delegate could do its own selection-aware rendering. Implementation tripped a Quartz codegen bug:

> Lambdas that capture an outer Fn parameter and end up stored in a struct field produce malformed LLVM IR ("Instruction does not dominate all uses!").

The factory `item_delegate_simple<Item>(show: Fn(Item): String)` constructs a 3-arg-shaped closure that wraps `show` — that wrap-and-store-in-struct path is exactly the broken codegen path.

**Resolution**: the delegate stores a plain `show: Fn(Item): String`. List applies cursor styling and gutter above the delegate output, so selection-aware rendering doesn't need delegate cooperation in the simple case. Card-style multi-row delegates with custom rendering (height>1, is_selected branching, width-aware truncation) are filed for v0.3.3+ pending the underlying codegen fix.

### Q11 (POST-IMPLEMENTATION) — Why are widget fields in parent State structs typed `Int` instead of the actual widget type?

Three independent Quartz typecheck rejections forced the workaround:

1. **Concrete-instantiation as field type**: `struct State { input: TextInput, ... }` works. `struct State { saves: List<String>, ... }` fails with "Field saves: expected unknown, got unknown" — concrete instantiation of a generic struct as a field type in a non-generic outer struct doesn't resolve.
2. **Generic-typed fields without instantiation**: `struct State { focus: FocusRing<SaveFocus>, ... }` same failure mode.
3. **Generic struct return-type annotation**: `def make_state(): State` works. `def make_focus_ring(): FocusRing<SaveFocus>` fails with "Return type mismatch: expected unknown but got unknown."

**Workaround pattern** used in the save-screen demo: store widget references as `Int` (the runtime handle), recover via `as_type<TextInput>(handle)` at use sites, wrap with `as_int(widget)` when constructing a new State. Each transition costs one extra line; tolerable for v0.3.2 but accelerates the case for fixing the underlying typecheck bugs.

**Workaround footnote**: `as_type<ti::TextInput>(...)` (with module prefix) fails codegen ("identifier reached codegen unresolved"); use unprefixed `as_type<TextInput>(...)`.

---

## Friction findings — predictions vs. reality

### Predictions that landed

1. **Struct-rebuild verbosity** — confirmed. Save-screen at 4 fields (input + saves + focus + status) plus the as_int/as_type widget-handle dance puts each return arm at ~6 lines of construction. Deckbuilder combat screens with 6+ children will be loud. Struct-spread is now a real want, not just nice-to-have. Escalate to language ROADMAP.
2. **Generic Vec<Id> in FocusRing** — confirmed and resolved. Bounded generic `<Id: Eq>` plus `==` operator on enum values works (verified standalone). Watch out: `xs[i].op_eq(target)` UFCS-through-trait-bound segfaulted in early test; `xs[i] == target` worked. Operator-vs-method dispatch through trait bounds may have a compiler-side discrepancy.
6. **`list_set_items` clamping** — confirmed and tested. Two QSpec cases (clamps to size-1 on shrink, clears selection on empty).
7. **`viewport_set_size` invalidating wrap cache** — currently no cache (recompute every render), so the prediction was moot. Added to v0.3.3 list when caching arrives.

### Predictions that were wrong or never came up

3. **`ItemDelegate` field is `Fn(Item, Bool, Int): String`** — wrong shape, codegen bug forced redesign. See Q10 above. Now `Fn(Item): String`.
4. **Wide-char alignment in cursor rendering** — surfaced once, handled cleanly. wcwidth shipped in v0.3.1 (clip_to_width consumes it).
5. **View tests via substring matching after style-strip flaky** — actually robust. `ly::strip_styles` returns clean text; substring assertions held. The predicted gotcha didn't materialize.

### New friction NOT predicted (by surface count, in order discovered)

These are bugs / friction surfaces found during implementation, all filed in commit messages and (the load-bearing ones) in the memory system:

1. **`to_int` intrinsic name shadow** — defining a user-level `def to_int(b: Bool): Int` silently miscompiles to the intrinsic's body (F64→Int via fptosi) with no warning. Cost ~30 min of disbelief debugging in step 1. Memory: `feedback_intrinsic_name_shadow.md`.
2. **`when` is a Quartz keyword (TOK_WHEN)** — using it as a parameter name produces "expected at least 9 fields but got 7" downstream of the parse error. Renamed to `mode`.
3. **Same-named import paths not deduped** — `import std/style` from one module and `import style` (transitively) from another emits `style$Style$*` functions twice → LLC redefinition. Workaround: match the path the transitively-imported stdlib uses (`import style`, not `import std/style`).
4. **`is None` on a non-Option enum SIGSEGVs** — variant named `None` in a custom enum, applying `is None` crashes at runtime. Renamed all event enum None variants to `Idle`. Memory: `feedback_is_none_non_option_segfault.md`.
5. **KEY_* sentinel range is 1000-1099** — `code >= 1000` rejects all CJK. Tightened to `1000..1099` matching std/terminal's reserved range.
6. **Lambda capturing outer Fn param + stored in struct field → malformed IR** — "Instruction does not dominate all uses!" Forced ItemDelegate signature redesign (Q10).
7. **Chained method calls on struct-field paths of generic-erased structs SIGSEGV** — `l.styles.cursor.render(s)` where l is `List<Item>`. Workaround: extract the field to a local first. Applied throughout list.qz; viewport.qz wasn't affected because Viewport isn't generic.
8. **Generic struct return-type annotation rejected** — `def f(): List<String>` fails typecheck. Drop the annotation; inferred return works.
9. **Concrete generic instantiation as non-generic struct field rejected** — `struct State { x: List<String>, ... }` fails. Use `Int` handle + `as_type<T>` recovery.
10. **Generic enum variant payload erases to Int** — `match ev { Selected(card) => ... }` infers `card: Int` even when the list was `List<String>`. Coerce via `as_string(card)` (or `as_type<T>` for non-string types).
11. **`as_type<ti::TextInput>` fails codegen** — "identifier reached codegen unresolved." Use unprefixed `as_type<TextInput>`.
12. **`sb_append_char(sb, byte)` re-encodes** — appends as codepoint, not byte; corrupts UTF-8 byte streams. Use `sb_append_byte` for byte-level pass-through.
13. **Pattern matches with module-qualified variants** — `match opt { Some(SaveFocus::NameInput) => ... }` fails to parse; drop the qualifier (`Some(NameInput)`) and let scrutinee disambiguate.

### Net assessment

Predicted friction (7 items): 4 confirmed, 3 wrong/moot. Discovered friction (13 items): all bounded, all worked-around, all filed. None blocked the design — the recommended shape held. Net per-step cost: 30-90 min of debugging across 6 steps.

The deckbuilder will re-encounter (1), (8), (9), (10), (11), (13) routinely. The other items are lower-frequency. Worth a coordinated compiler-bug-fix sprint at some point.

---

## Acceptance for v0.3.2 — final status

- [x] `std/tui/widgets/focus.qz` ships `FocusRing<Id>` with QSpec — 23 tests across new/with_initial/current/next/prev/set/clear/is_focused/size, single-element edge, round-trip. `6970a3d8`.
- [x] `std/tui/widgets/text_input.qz` ships `TextInput` + `TextInputEvent` + `TextInputStyles` + `ValidateOn` with QSpec — 34 tests across edit semantics, cursor movement, all four ValidateOn modes, max_length, set_value_unchecked clearing last_error, view rendering across (focused × empty × value × cursor-position), Tab as no-op. `ed4ee070`.
- [x] `std/tui/widgets/viewport.qz` ships `Viewport` + `ViewportEvent` + `ViewportStyles` with QSpec — 30 tests across content management, follow_tail, scroll clamping, scroll_percent, update event routing, view shape, soft wrap. `c09387f0`.
- [x] `std/tui/widgets/list.qz` ships `List<Item>` + `ListEvent<Item>` + `ListStyles` + `ItemDelegate` with QSpec — 29 tests across construction, items management (set_items clamping), accessors, state setters (select_first/last/next/prev, wrap_around), update event routing, view shape, selection-driven scroll. `5871dc50`.
- [x] `std/tui/layout.qz` adds `strip_styles(s) → String` — 12 tests covering passthrough, SGR stripping (simple/multi-arg/24-bit), cursor positioning, mixed text + escapes, defensive lone-ESC. `7100c6b4`.
- [x] One example per widget under `examples/tui/widgets/<name>/main.qz`: text_input (echo-with-history demo), viewport (combat-log streaming demo), list (50-card faux-deckbuilder browser).
- [x] Composite example: `examples/tui/widgets/save_screen/main.qz` — TextInput + List + FocusRing wired end-to-end (Tab cycles focus, Enter on input saves, Enter on list prefills input). 9-test composite spec validates focus rotation + cross-widget event routing. `78f0cf88`.
- [x] `quake guard` fixpoint clean — every step verified through 2137 functions. Six guard runs, all passed.
- [x] Compile time for a single-widget consumer — text-input demo cold compile measured in step 3 example build (<1s on the test machine). Layout-only consumer from v0.3.1's measurements is 0.5s; widget consumers in the same neighborhood.
- [x] Friction findings reconciled (above) — 7 predictions, 4 confirmed, 3 wrong, plus 13 newly-discovered compiler footguns all worked-around and filed.

**128 tests green, 6 commits, fixpoint clean throughout. Trio + FocusRing compose. The framework holds.**

## Sequencing within v0.3.2

Smallest-to-largest, each step its own commit, fixpoint-clean, behind quake guard.

1. **`focus.qz`** + QSpec. Smallest, no rendering. Validates the generic-bound design.
2. **`layout.qz` adds `strip_styles`** + QSpec. Tiny, unblocks all subsequent view tests.
3. **`text_input.qz`** + QSpec + example. Single-widget; forces the styles + validator design.
4. **`viewport.qz`** + QSpec + example. Adds scroll-state pattern.
5. **`list.qz`** + QSpec + example. Most complex; surfaces ItemDelegate ergonomics.
6. **Composite save-screen example** + QSpec for the composite (replay-determinism, focus cycling).
7. **Memo reconciliation pass** — fill in the "Predicted friction findings" section with reality.

Estimate: ~3 quartz-days end-to-end (research + design done; implementation is mechanical against this memo).

---

## Sources (research)

- [Bubbletea](https://github.com/charmbracelet/bubbletea)
- [Bubbles textinput](https://github.com/charmbracelet/bubbles/blob/master/textinput/textinput.go)
- [Bubbles viewport](https://github.com/charmbracelet/bubbles/blob/master/viewport/viewport.go)
- [Bubbles list](https://github.com/charmbracelet/bubbles/blob/master/list/list.go)
- [Ratatui widget concepts](https://ratatui.rs/concepts/widgets/)
- [Ratatui ListState](https://docs.rs/ratatui/latest/ratatui/widgets/struct.ListState.html)
- [tui-textarea](https://github.com/rhysd/tui-textarea)
- [Textual widget guide](https://textual.textualize.io/guide/widgets/)
- [Textual Input widget](https://textual.textualize.io/widgets/input/)
- [Textual ListView](https://textual.textualize.io/widgets/list_view/)
- [Textual events guide](https://textual.textualize.io/guide/events/)
- [Brick guide](https://github.com/jtdaugherty/brick/blob/master/docs/guide.rst)
- [Brick.Focus](https://hackage-content.haskell.org/package/brick-2.12/docs/Brick-Focus.html)
- [Brick.Widgets.Edit](https://hackage-content.haskell.org/package/brick-2.12/docs/Brick-Widgets-Edit.html)
