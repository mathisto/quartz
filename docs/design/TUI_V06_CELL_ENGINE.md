# TUI v0.6 — World-Class Cell Engine + Lighting

> **Status**: Design — implementation queued for multi-session arc.
> **Filed**: 2026-05-06.
> **Scope**: ~12 quartz-days across 9 phases.
> **Companion designs**: `TUI_ROADMAP.md` (v0.1-v0.5 history), `TUI_RUNTIME.md` (TEA contract), `TUI_WIDGETS.md` (widget design), `TUI_FORM.md` (form composition).

## Why this exists

TUI v0.5 shipped all 11 phases by 2026-05-05, including the deckbuilder dogfood and the program_replay infrastructure. The framework has Bubble-Tea-grade ergonomics for the TEA pattern + widget composition, but lacks two things that prevent it from being world-class:

1. **Cell-level primitives.** The current `Style` API is a fluent string-decorator (Lipgloss-shaped). It does not expose a cell primitive, plane/layer composition, alpha blending, or named blend modes. This caps the framework at "render styled text" — fine for forms, dashboards, list-driven UIs; insufficient for roguelikes, dense info displays, or anything wanting per-cell control.
2. **A first-class lighting model.** Brogue's reputation for stunning visuals comes from a per-cell additive RGB light buffer with sqrt-falloff point lights. Most TUI libraries bolt lighting on as an afterthought (or omit it entirely). If Quartz makes lighting first-class — co-equal with style — roguelike authors and dense-display authors will pick Quartz over the alternatives.

This memo synthesizes prior art across the field and proposes the v0.6 design that closes both gaps. The combination — Bubble Tea ergonomics + Notcurses cell power + libtcod blend modes + Brogue lighting + Base16 theming — is the differentiator. No single existing framework has all of these.

## Prior-art research summary

Surveyed 2026-05-06. Compressed findings; full citations in [References](#references).

### Cell primitive comparison

| Framework | Char | FG | BG | Attrs | Alpha/blend | Z-order |
|---|---|---|---|---|---|---|
| Notcurses (C) | EGC | 24-bit + palette + default | 24-bit + palette + default | bold/italic/under/strike + EAW | **2-bit alpha per channel** (OPAQUE/BLEND/TRANS/HIGHCONTRAST) | **First-class plane DAG**, total z-order, family reparenting |
| Ratatui (Rust) | grapheme String | RGB/256/16 | RGB/256/16 | Modifier bitset | None — last-writer-wins | Implicit by render order |
| Lipgloss v2 (Go) | grapheme | 24-bit adaptive | 24-bit adaptive | bold/italic/under/strike/blink/reverse | None directly; `Layer`/`Canvas` provide composition | Explicit `.Z(n)` |
| Textual (Py) | grapheme via Rich Segment | 24-bit | 24-bit | Rich Style | Per-style alpha/tint | DOM tree compositor |
| tcell v3 (Go) | UTF-8 cluster | RGB/256/16 | RGB/256/16 | bold/italic/under/strike/dim/reverse/blink/url | None | None — substrate |
| libtcod (C/Py) | codepoint | RGB | RGB | None (color is the attribute) | **Photoshop-grade blend mode enum**: NONE/SET/MULT/SCREEN/LIGHTEN/DARKEN/ADD/ADDALPHA/BURN/DODGE/OVERLAY/ALPHA | Console layering via blit |
| Brogue (CE) | char | RGB | RGB | bright/dark pair, IS_IN_SHADOW | **Additive RGB lighting** + radial fade | None — tile map |

**Notcurses + libtcod together** are the gold standard for cell power. **Brogue** is the gold standard for lighting. **Bubble Tea + Lipgloss + Textual** are the gold standard for ergonomics. Quartz's v0.6 combines all three.

### Brogue's lighting — the math is simpler than people guess

Per-cell state is **three signed integers** `tmap[i][j].light[R/G/B]`. Each frame:
1. Reset every cell's `light[]` to a **tinted ambient** (the "miner's light color" — typically a soft warm-yellow tint, not zero).
2. For each light source, run shadowcasting from the source for visibility, then for each visible cell at distance `d`: compute `lightMultiplier = 100 - (100 - fadeToPercent) * sqrt(d) / radius` — **square-root falloff**, not inverse-square. This is the visual key.
3. **Add** the source's color contribution scaled by `lightMultiplier / 100` to each `light[k]` slot.
4. Render: `cell.fg = clamp(tile.color + light, 0, 100)` (additive RGB).
5. **Shadow bookkeeping**: cells start `IS_IN_SHADOW`; non-magical lights clear the flag, but the player's miner's-light intentionally does *not* — the player can still be silhouetted in their own light. This is what makes Brogue's visuals atmospheric instead of flat-lit.

The orange spillover from a torch into a blue-tinted cavern that everybody screenshots is just: base color (cool blue) + light contribution (warm orange) = warm-to-cool gradient. No shaders. No GPU.

### FOV — Symmetric Shadowcasting (Albert Ford, 2019) is the modern default

Recursive shadowcasting (Björn Bergström, 2001) is the workhorse of 20 years but is asymmetric (A can see B but not vice versa). Albert Ford's 2019 reformulation — same shape, but origins are points and walls are inscribed diamonds, with rational arithmetic to avoid float artifacts — gives perfect symmetry and satisfies all six Milazzo properties (symmetry, expansive walls, expanding pillar shadows, no blind corners, no float artifacts, fast). **Ship Symmetric Shadowcasting as the default; expose the visit callback so consumers plug it into the light accumulator.**

### Anti-patterns to avoid

- `stdscr` global state (curses). Always pass screen/buffer values.
- Raw `printf`-style draw without diffing. Damage tracking is mandatory.
- Color-as-int-enum (16 ANSI colors). Truecolor is the canonical type; downgrade at flush time.
- `Tile = (char, fg, bg)` with no separate light buffer. Dooms you to never-Brogue.
- One global "current style" that draw calls read implicitly. Always pass style explicitly.
- Compositing in screen coordinates instead of layer coordinates. Notcurses' parent-relative coordinates are why reparenting is cheap.

### Surprising findings worth carrying

- libtcod shipped Photoshop-style blend modes 15+ years ago and almost no modern TUI library copied them. **Clear gap to fill.**
- Notcurses' alpha is 2 bits, not 8 — a fixed enum (OPAQUE/BLEND/TRANS/HIGHCONTRAST). Don't over-design 8-bit alpha; the eye can't perceive that many cell-blend gradations.
- **Unicode 16 (Sept 2024) added octants** — 4×2 sub-cell mosaics. Modern terminals (Ghostty, Kitty, WezTerm, Windows Terminal, Cascadia Code) all support them. Octants give effectively **8× spatial resolution** while preserving cell semantics (mouse hit-testing, focus, cursor) — the best we'll get without Sixel/Kitty graphics.
- Truecolor in 2026 is universal in modern terminals. Target truecolor first; downgrade-to-256 / -16 at flush time.
- DEC mode 2026 (synchronized output) is supported by Ghostty/Kitty/WezTerm and gives tear-free frames for free.

## Decisions

### D1. Cell primitive — adopt Notcurses' shape

```be
struct Channel
  rgb: Int           # 24-bit packed RGB
  alpha: AlphaMode   # 2-bit enum
  default_fg: Bool   # use terminal default color
  palette: Bool      # interpret rgb as 256-color index
end

enum AlphaMode
  Opaque        # this channel covers; nothing below shows
  Blend         # average with what's below
  Transparent   # show whatever's below
  HighContrast  # auto-pick fg for legibility against bg below
end

struct Cell
  egc: String        # extended grapheme cluster (multi-codepoint)
  fg: Channel
  bg: Channel
  attrs: Int         # bitset: bold | italic | under | strike | reverse | dim | blink
end
```

Why 2-bit alpha (not 8-bit): terminals can't actually do 256 levels of cell blending. Notcurses' fixed enum maps cleanly to the four cases that come up in practice. Don't over-design.

### D2. Composition — two tiers

**Tier A (today's API, kept as-is):** `Style.bold().fg(...).render(s)` returns String. Linear composition via concat. 80% of consumers want this. Bubble Tea / Lipgloss-shaped.

**Tier B (new):** `Plane` — a 2D buffer with parent-relative coordinates, total z-order, and `merge_down` for caching:

```be
struct Plane
  parent: Option<PlaneId>
  rel_x: Int
  rel_y: Int
  z: Int
  cells: Vec<Cell>     # row-major, w*h
  w: Int
  h: Int
end

def plane_create(parent, rel_x, rel_y, w, h, z): Plane
def plane_putc(p, x, y, cell): Plane
def plane_blit(src, dst, sx, sy, sw, sh, dx, dy, blend: BlendMode): Plane
def plane_merge_down(top, bottom): Plane
def plane_reparent(p, new_parent): Plane
```

Tier A is implemented on top of Tier B (a single 1×N plane composes to the same result). Consumers who never need Tier B never see it.

### D3. Blend modes — copy libtcod's enum, modernize naming

libtcod shipped Photoshop-grade blend modes 15+ years ago; almost no modern TUI library copied them. This is the single biggest gap in the field.

```be
enum BlendMode
  None         # last-writer-wins (default, ratatui-equivalent)
  Alpha(pct)   # standard alpha blend at percentage 0-100
  Add          # additive RGB — for lighting
  Multiply     # multiplicative — for darkening / dimming
  Screen       # inverse-multiply — for brightening overlays
  Lighten      # max(top, bot) per channel
  Darken       # min(top, bot) per channel
  Overlay      # multiply if dark, screen if light
  Burn         # contrast-darken
  Dodge        # contrast-brighten
end
```

Use cases:
- `Add` for light spillover (Brogue)
- `Multiply` for dimming overlays (the deferred SGR-stack-aware dim becomes a one-liner)
- `Alpha(50)` for ghosting / fade transitions
- `Screen` for HUD overlays that brighten without obscuring
- `Overlay` for damage flashes
- `Lighten`/`Darken` for soft contrast adjustments

### D4. Lighting — first-class, Brogue-shaped

```be
struct Light
  origin: (Int, Int)        # world coords
  color: (Int, Int, Int)    # RGB additive contribution at full intensity
  radius: Int               # cells
  fade_to_pct: Int          # intensity at radius edge (0-100)
  flags: Int                # bitset: MAINTAIN_SHADOWS | MAGICAL | FLICKER
  flicker_pct: Int          # 0-30, per-frame jitter for fire
end

struct LightBuffer
  width: Int
  height: Int
  light: Vec<Int>           # 3 ints per cell: r, g, b — additive accumulation
  shadow_flags: Vec<Bool>   # per-cell IS_IN_SHADOW
end

def light_buffer_new(w, h, ambient: (Int,Int,Int)): LightBuffer
def light_buffer_paint<S>(
  buf: LightBuffer,
  light: Light,
  state: S,
  blocks_light: Fn(S, Int, Int): Bool
): LightBuffer
def light_buffer_apply(buf: LightBuffer, plane: Plane): Plane    # tile.color + light, clamped
```

`light_buffer_paint` does the Brogue math: shadowcast from origin, for each visible cell compute `multiplier = 100 - (100 - fade_to_pct) * sqrt(distance) / radius`, add `color * multiplier / 100` to the cell's `light[]`. Optional flicker jitters the multiplier ±`flicker_pct` percent per frame.

Pluggable falloff (sqrt default; linear, inverse-square, custom callable supported).

### D5. FOV — Symmetric Shadowcasting (Albert Ford 2019)

One canonical implementation in `std/tui/fov.qz`:

```be
def fov_for_each_visible<S>(
  state: S,
  origin: (Int, Int),
  radius: Int,
  blocks_light: Fn(S, Int, Int): Bool,
  visit: Fn(S, Int, Int, Int): Void   # x, y, distance
): Void
```

Composes with `light_buffer_paint` — caller's job is to wire them via the `blocks_light` predicate.

### D6. Sub-cell resolution — Unicode 16 octants

Octants give 8× spatial resolution per cell while preserving cell semantics. Ship an `OctantBlitter` that takes a 4w × 2h pixel grid and downsamples to one octant cell per output cell. For roguelikes, dashboards, and dense info displays this is genuinely game-changing.

```be
struct OctantBlitter
  pixels: Vec<Bool>      # 4w × 2h grid
  pixel_w: Int
  pixel_h: Int
end

def octant_blit_to_plane(b: OctantBlitter, p: Plane, dst_x: Int, dst_y: Int): Plane
```

Capability probe via terminfo at runtime; downgrade to half-blocks (▀▄) for terminals without Unicode 16, falling further to ASCII at the bottom.

### D7. Damage/diff renderer + DEC 2026 synchronized output

Every modern TUI library converged on the same algorithm: render to a back buffer, diff against the front buffer, emit only the changed cells with cursor-move minimization. Ratatui, Bubble Tea Cursed Renderer, Textual compositor — same shape, three implementations. **No frame ever re-emits unchanged cells.**

Wrap each frame in DEC 2026 begin/end markers (`\x1b[?2026h` / `\x1b[?2026l`) for tear-free frames on Ghostty/Kitty/WezTerm. Terminals that don't recognize the markers ignore them — fully backward-compatible.

This **subsumes** the v0.5 deferral "cell-level diffing." It's mandatory in v0.6.

### D8. Theme system — Base16/Base24 with semantic accessors

Base16 (Chris Kempson 2012, now governed by [tinted-theming](https://github.com/tinted-theming/schemes)) is the de facto community theme standard. 200+ schemes in YAML; broader ecosystem (Catppuccin, Gruvbox, Dracula, Nord, Tokyo Night, Solarized, Rosé Pine, Everforest, Kanagawa, …) ports universally.

```be
struct Theme
  name: String
  author: String
  variant: ThemeVariant   # Light | Dark
  # 16 Base16 slots — 8 neutrals (00-07: bg→fg gradient) + 8 accents (08-0F)
  base00: Color  # default bg
  base01: Color  # lighter bg / status bar
  base02: Color  # selection
  base03: Color  # comments / disabled / dim
  base04: Color  # dark fg / status bar fg
  base05: Color  # default fg
  base06: Color  # light fg
  base07: Color  # lightest fg
  base08: Color  # red — variables / errors
  base09: Color  # orange — integers / constants
  base0A: Color  # yellow — classes / types
  base0B: Color  # green — strings / success
  base0C: Color  # cyan — regex / escape / special
  base0D: Color  # blue — functions / methods
  base0E: Color  # purple — keywords / storage
  base0F: Color  # brown — deprecated / embedded
  # Optional Base24 extension
  base10_17: Option<(Color, Color, Color, Color, Color, Color, Color, Color)>
end

enum ThemeVariant
  Light
  Dark
end
```

**Semantic accessors** (the key ergonomic move — widgets don't memorize Base16 slot semantics):

```be
def theme_bg(t)             = t.base00
def theme_fg(t)             = t.base05
def theme_dim(t)            = t.base03
def theme_selection_bg(t)   = t.base02
def theme_status_bar_bg(t)  = t.base01
def theme_status_bar_fg(t)  = t.base04
def theme_error(t)          = t.base08
def theme_warning(t)        = t.base09
def theme_info(t)           = t.base0D
def theme_success(t)        = t.base0B
def theme_special(t)        = t.base0E
def theme_accent(t, slot)   = ...   # for slot in {Red, Orange, Yellow, Green, Cyan, Blue, Purple, Brown}
```

Now `Style.bg(theme.bg).fg(theme.error)` is widget code, and switching themes is a config swap with zero widget changes.

**Loader:**
```be
def theme_load_yaml(path: String): Result<Theme, ThemeError>
def theme_from_string(yaml: String): Result<Theme, ThemeError>
```

Ship a targeted Base16-YAML parser (~80 LOC; flat key-value with hex string values; doesn't need full YAML compliance). The decision on a full YAML parser is tracked in `ROADMAP.md` Tier 4 #40.

**Bundled themes** (curated 8-12 in `std/tui/themes/`):
- Catppuccin Mocha + Latte (Dark + Light) — modern default
- Gruvbox Dark Hard + Light Hard — classic warm palette
- Tokyo Night — modern "every editor" pick
- Nord — cool-blue popular choice
- Dracula — purple/pink canonical
- Solarized Dark + Light — photometric/research-grounded
- Rosé Pine Moon — stylish dark-mode favourite
- Everforest Dark — earthy, low-contrast option

The other 200+ schemes from tinted-theming/schemes work via `theme_load_yaml`. Document "drop a YAML file in `~/.config/yourapp/themes/`" as a first-class extensibility story.

## Phase order

| Phase | Scope | Quartz-days |
|---|---|---|
| **6.0** *(SHIPPED 2026-05-06, commit `783c7536`, ~0.3 quartz-days actual vs 1.2 estimated)* | Cell primitive (`Cell`, `Channel`, alpha/attrs) + `Theme` struct + semantic accessors | 1.2 |
| **6.1** *(SHIPPED 2026-05-06, ~0.3 quartz-days actual vs 1.5 estimated)* | Plane DAG (Tier B) — coordinates, z-order, merge_down, reparent | 1.5 |
| **6.2** *(SHIPPED 2026-05-06, ~0.5 quartz-days actual vs 1.0 estimated)* | Blend modes — all 9 modes, `plane_blit` accepts `BlendMode` | 1 |
| **6.3** *(SHIPPED 2026-05-06, ~0.4 quartz-days actual vs 1.5 estimated)* | Damage/diff renderer + DEC 2026 synchronized output | 1.5 |
| **6.4** *(SHIPPED 2026-05-06, ~0.4 quartz-days actual vs 1.0 estimated)* | Light buffer + `paint` primitive (Brogue math, sqrt falloff, ambient tint, shadow flags) | 1 |
| **6.5** *(SHIPPED 2026-05-06, ~0.4 quartz-days actual vs 0.5 estimated)* | Symmetric shadowcasting FOV (Albert Ford 2019) — published as `std/tui/fov.qz`; `light_buffer_paint` refactored to consume it | 0.5 |
| **6.6** *(SHIPPED 2026-05-06, ~0.4 quartz-days actual vs 1.0 estimated)* | Octant blitter — `OctantBlitter` 2×4 pixel grid + 4-tier `OctantQuality` (Octant / Quadrant / Half / Ascii) + `octant_blit_to_plane`. Full Octant table filed as `OCTANT_FULL_TABLE_FILL.md` (Phase 6.6.1) | 1 |
| **6.6.1** *(SHIPPED 2026-05-06, ~0.6 quartz-days actual vs 0.5 estimated)* | Octant full-table fill — all 256 patterns now emit correct Unicode 17 codepoints (230 new at U+1CD00..U+1CDE5 + 26 reused). Resolved at `docs/bugs/done/OCTANT_FULL_TABLE_FILL.md`. | 0.5 |
| **6.7** *(SHIPPED 2026-05-06, ~0.4 quartz-days actual vs 0.5 estimated)* | Tier A (`Style.render`) reimplemented on top of Tier B — `Vec<Cell>` + `cells_render_inline` + `plane_render_inline` | 0.5 |
| **6.8** *(SHIPPED 2026-05-06, ~0.5 quartz-days actual vs 1.5 estimated)* | Base16/Base24 YAML loader + 11 bundled themes (Catppuccin Mocha+Latte, Gruvbox Dark/Light Hard, Tokyo Night Dark, Nord, Dracula, Solarized Dark/Light, Rosé Pine Moon, Everforest Dark) | 1.5 |
| **6.9** *(SHIPPED 2026-05-06, ~0.6 quartz-days actual vs 2 estimated)* | Sample roguelike (`game/brogue-tribute/main.qz`) — single-screen dungeon stress-testing every v0.6 surface end-to-end (cells + plane DAG + blend + diff renderer + light + FOV + full octants + Tier-A-on-Tier-B + theme cycle) | 2 |

**Total: ~12.5 quartz-days** (added Phase 6.6.1 octant full-table fill — must-ship before v0.6 release; the partial 16-of-256 coverage in 6.6.0 is correct-looking but not world-class until the full table lands). Calendar terms with project calibration: ~2-3 weeks of focused work split across multi-session arcs.

### Foundation block ships first

**Phases 6.0 + 6.1 + 6.2 + 6.3 = the foundation** (~5 quartz-days). After this block, every existing v0.5 widget continues to work (Tier A surface unchanged), but the new powers are available to consumers who want them. Phases 6.4-6.9 are independent and can be ordered however.

## What this folds into / closes

The v0.6 design subsumes three of four v0.5 deferrals:

| v0.5 deferral | v0.6 status |
|---|---|
| Cell-level diffing | **Subsumed** by D7 — damage renderer is non-negotiable |
| SGR-stack-aware dim compositing | **Subsumed** by D3 — `BlendMode::Multiply` is a strict superset |
| Soft-wrap caching in viewport | Still relevant as v0.6.x polish — viewport-internal optimization, not v0.6 core |
| `text_input_set_size` real impl | Still blocked on horizontal scroll feature work |

## Sister design — deckbuilder v0.4 balance pass

The deckbuilder is the dogfood driver for v0.6 (and was for v0.1-v0.5). Its current build is honestly described in its own comments as "meta-loop validation, not balance tuning." Six concrete changes, in shipping order, each a single PR:

1. **v0.4.1 — HP carries across fights.** Drop hard-coded `player_hp: 50`. Take from prior combat. **Single biggest change** — converts "infinite tries" into "a run." ~30 LOC.
2. **v0.4.2 — Enemy scaling.** Linear: `enemy_hp = 30 + 10 * fights_won`, intent damage scales similarly. Quadratic later if needed.
3. **v0.4.3 — Status effects.** `Vulnerable` (incoming damage +50%) and `Weak` (outgoing damage -25%). One card each. Transforms tactical depth — *when* you play matters, not just *which*.
4. **v0.4.4 — Enemy variety (3 archetypes).** Striker / Shielder / Buffer. Pick by `fights_won % 3` or seeded PRNG.
5. **v0.4.5 — Reward branching.** Heal vs Card pick vs Skip-for-energy. Risk/reward decisions per fight.
6. **v0.4.6 — Boss every 5 fights.** Multi-stage telegraph. The "moment" that makes a run feel earned.

**Total: ~3-5 quartz-days for the whole balance pass.** Each PR shippable solo.

The deckbuilder v0.4 work is independent of v0.6 and can ship in parallel — no shared files. But v0.4.6 is when you'll *want* v0.6.4 lighting (boss-room atmospheric flicker). Co-sequence accordingly.

## Open questions for next session

Things to resolve before implementation starts:

1. **Cell primitive storage layout.** `cells: Vec<Cell>` is correct semantically but `Cell` is ~32 bytes in this design (egc + 2 channels + attrs). For a 200×60 plane that's 384 KB per plane. Is that acceptable? Notcurses uses a packed 16-byte cell with EGC pool indirection — should we follow? Decision should happen pre-6.0.
2. **EGC pool vs inline.** Notcurses' "25-bit pool index OR inline 7-bit ASCII" is a memory optimization. Worth it for v0.6 or defer to v0.7?
3. **Coordinate system for planes.** Pixels vs cells. Octant blitter wants pixel coordinates; plane composition wants cell coordinates. Two coordinate systems, or unified? (Recommendation: unified cell coordinates with octants conceptually scaled internally.)
4. **Theme hot-reload.** `theme_load_yaml` returns a Theme value; consumers refresh by calling `program.set_theme(...)`. Should `program` watch the theme file via the existing SIGWINCH-style runtime extension and auto-reload? Yes/no decision affects runtime API.
5. **Style→Theme migration path.** Existing widgets use raw RGB. Do we mass-migrate to `theme_*` accessors as part of v0.6.0, or migrate incrementally over v0.6.x patch releases?
6. **`docs/design/DECKBUILDER_V04_BALANCE.md`** — should the deckbuilder difficulty plan get its own design doc, or stay an appendix here? Recommendation: own doc once v0.4.1 starts; for now it lives here as the dogfood driver context.

## Implementation kickoff checklist

v0.6.0 Phase 6.0 status (2026-05-06):

- [x] Read this doc end-to-end + the four cross-references in the header
- [x] Resolve the six open questions above
- [x] Save fix-specific golden binary (`quartz-pre-tui-v06-golden`)
- [x] Create `docs/design/TUI_V06_OPEN_QUESTIONS.md` resolving each open question with rationale
- [x] Phase 6.0 — `Cell` + `Channel` + `Theme` struct + semantic accessors shipped at `783c7536`. 48/48 spec green.
- [x] Phase 6.1 — Plane DAG (Tier B) shipped: `Plane` struct + per-cell ops (`getc`/`putc`/`fill`) + DAG metadata builders (`with_pos`/`with_z`/`with_parent`) + `plane_merge_down` with last-writer-wins + transparent-skip. 27/27 spec green at `spec/qspec/tui_v06_plane_spec.qz`.
- [x] Phase 6.2 — Blend modes shipped: `BlendMode` enum (10 variants — `None`, `Alpha(pct)`, `Add`, `Multiply`, `Screen`, `Lighten`, `Darken`, `Overlay`, `Burn`, `Dodge`), `bl::blend_colors(top, bottom, mode)` per-channel math, `pl::plane_merge_down_with(top, bottom, mode)`, `pl::plane_blit(src, dst, sx, sy, sw, sh, dx, dy, mode)` for sub-rect copy. Non-truecolor inputs fall back to last-writer-wins (v0.7 will lift via ANSI16/256 → RGB expansion). 34/34 spec green at `spec/qspec/tui_v06_blend_spec.qz`.
- [x] Phase 6.3 — Damage/diff renderer + DEC 2026 sync shipped: `Renderer` struct (front + back planes), `renderer_new`/`resize`/`with_back`/`swap`, `renderer_diff(r, sync)` producing ANSI escape string of cell-level differences with cursor-move minimization + SGR state machine, optional DEC 2026 begin/end markers. Subsumes v0.5 deferral "cell-level diffing." Truecolor SGR only in v0.6.3 (color-depth degradation is a v0.6.x polish). 19/19 spec green at `spec/qspec/tui_v06_render_spec.qz`.
- [x] Phase 6.4 — Light buffer + Brogue-shaped lighting shipped: `Light` struct (origin, color RGB, radius, fade_to_pct, flags, flicker_pct), `LightBuffer` struct (per-cell additive RGB accumulation + shadow_flags), `light_buffer_paint(buf, light, frame, blocks_light)` doing the Brogue math (LOS gate + linear sqrt-falloff multiplier, `±flicker_pct` deterministic per-frame jitter when `LIGHT_FLAG_FLICKER` is set), `light_buffer_apply(buf, plane)` additively blending buffer RGB onto plane cells (default-color → black baseline, truecolor → additive blend with clamp, palette/ANSI16 → unchanged, v0.7 polish). Convenience constructors `light_torch` / `light_miners` / `light_torch_flicker`. 34/34 spec green at `spec/qspec/tui_v06_light_spec.qz`.
- [x] Phase 6.5 — Symmetric shadowcasting FOV shipped: `std/tui/fov.qz::fov_for_each_visible(origin_x, origin_y, radius, blocks_light, visit)` implementing Albert Ford's 2019 algorithm. 4-quadrant scan, integer rational slopes (cross-product comparisons, no floats), inclusive-start / exclusive-end wedges so each diagonal cell is owned by exactly one quadrant. Origin always visited at distance 0; cells past Euclidean radius filtered. `light_buffer_paint` refactored to consume the new walker — public API unchanged, all 34 light specs still green under the new visibility set. 15/15 spec green at `spec/qspec/tui_v06_fov_spec.qz` including the A-sees-B-iff-B-sees-A symmetry property. `fov_int_sqrt` exposed publicly for reuse.
- [x] Phase 6.6 — Octant blitter shipped: `std/tui/octant.qz` exports `OctantBlitter` (pixel_w × pixel_h `Vec<Bool>` grid), `OctantQuality` enum (Octant / Quadrant / Half / Ascii), constructors, set/get/fill ops, derived cell dimensions, and `octant_blit_to_plane(b, plane, dst_x, dst_y, quality, fg, bg)`. Output cells: `pixel_w/2 × pixel_h/4` regardless of quality; quality only affects glyph choice. Glyphs emit existing BMP block-characters for Quadrant/Half/Ascii (full coverage) and the 16 known pre-existing 2×4 patterns for Octant; 240 remaining Octant patterns gracefully fall back to Quadrant. Full Unicode 17 codepoint table for the remaining 240 patterns filed as `docs/bugs/OCTANT_FULL_TABLE_FILL.md` (Phase 6.6.1 — focused transcription pass against the U+1CD00..U+1CDE5 chart). Geometry note: the design memo's "4w × 2h pixel grid" was a slip; actual Unicode octant cells are 2 cols × 4 rows. 39/39 spec green at `spec/qspec/tui_v06_octant_spec.qz`.
- [x] Phase 6.6.1 — Octant full-table fill shipped: all 256 patterns now emit correct Unicode 17 codepoints. 230 new codepoints at U+1CD00..U+1CDE5 (the entire new BLOCK OCTANT block from Unicode 16, Sept 2024) + 26 reused codepoints (16 quadrant-clean from U+2580..U+259F, 4 single-corner-subpixels at U+1CEA0..U+1CEAB, 2 single-row at U+1FB82/U+2582, 2 three-row at U+1FB85/U+2586, 2 middle-rows-of-one-column at U+1FBE6/U+1FBE7). Source: Bobby-Miller community gist transcribed + converted to the module's bit ordering + one gist typo corrected (top-3-rows pattern was U+2586 in the gist; corrected to U+1FB85, verified geometrically). New `octant_codepoint(pat)` and `codepoint_to_utf8(cp)` helpers exposed publicly so spec coverage can verify entries directly. 48 tests green at `spec/qspec/tui_v06_octant_spec.qz` (39 prior + 9 new for full-table coverage). Resolved at `docs/bugs/done/OCTANT_FULL_TABLE_FILL.md`.
- [x] Phase 6.7 — Tier A reimplemented on Tier B shipped: `cl::cells_render_inline(cells, depth)` is now the canonical SGR-byte emitter for the v0.6 stack (combined-format, color-depth-degraded — the path Tier A's `Style.render` and any future "Plane → String" use case route through). Color encoding helpers (`RGB_FLAG`, `color_is_rgb`, `color_r/g/b`), degradation helpers (`rgb_to_ansi256`, `rgb_to_ansi16`, `ansi256_to_ansi16`), and inline emission helpers all moved from `std/style.qz` into `std/tui/cell.qz` — cell becomes the canonical owner. `cl::style_to_cells(text, fg, bg, attrs)` is the Tier-A → Tier-B bridge. `pl::plane_render_inline(plane, depth)` adds row iteration on top (single-row → cells_render_inline; multi-row → rows joined by `\n`, each row's SGR state closed independently). `Style._style_render` collapsed from ~250 LOC to a 5-line `style_to_cells` + `cells_render_inline` call; `std/style.qz` shrank from 650 → 301 LOC (the duplicated emission engine in style.qz is gone). **Output is byte-identical** to pre-6.7 — every existing combined-SGR test (`\x1b[1;3;4;31m...\x1b[0m`) stays green; `style_spec.qz` 35/35 + `style_render_concat_spec.qz` 5/5 + 6 widget specs (confirm/spinner/toast/status_bar/tabs/progress/truncate_styled = 138 tests) all green under the new emitter. New 35-test spec at `spec/qspec/tui_v06_phase67_spec.qz` covers the bridge + emitter directly. Render.qz's diff-renderer was deliberately left untouched (different requirements: cursor positioning, truecolor-only, per-cell SGR transitions); that consolidation is a v0.6.x polish.

Phase 6.0 surface change made during 6.2: `Channel.rgb` field renamed to `Channel.color`. Reason: UFCS paren-elision misroutes `chan.rgb` to the 4-arg free function `std/colors::rgb` even with explicit type annotations on the local. Per project policy (no compat shims, pre-launch), the field was renamed in the same commit that shipped 6.2; `Channel.color` is also semantically more honest (the field can be a truecolor RGB int, an ANSI 16 index, or a 256-palette index).

## FOUNDATION BLOCK COMPLETE (Phases 6.0 + 6.1 + 6.2 + 6.3)

After 6.3, the v0.6 foundation block ships end-to-end:

```
                       ┌─────────────────────────┐
                       │       App / Widget      │
                       └────────────┬────────────┘
   Tier A (existing)                │
   Style.fg(...).render(s) ─────────┤
                                    │
   Tier B (new in v0.6)             ▼
   plane_create + putc / fill ──→ Plane (Phase 6.1)
   plane_merge_down_with ────────→ Plane (Phase 6.2 — BlendMode)
   plane_blit ──────────────────→ Plane (Phase 6.2 — sub-rect)
                                    │
                                    ▼
                            Renderer.back (Phase 6.3)
                                    │
                              renderer_diff ─→ ANSI escape string
                                    │           (cursor-move + SGR
                                    │            state minimization,
                                    │            optional DEC 2026)
                                    ▼
                              renderer_swap → next frame
```

Total foundation actual: **~1.5 quartz-days vs 5.0 estimated** (4 phases). Apps can now opt into cell-level rendering end-to-end. Existing v0.5 widgets are unchanged and continue to work.

## Phase 6.4 shipped — lighting layered on the foundation

Phase 6.4 adds Brogue-shaped lighting on top of the foundation block: per-cell additive RGB accumulation with sqrt-falloff radial paint, LOS gating via a caller-supplied `blocks_light` predicate, ambient tint, shadow flags, optional deterministic per-frame flicker, and `light_buffer_apply` to additively blend the buffer onto a `Plane`. With this commit, the lighting half of the v0.6 pipeline is end-to-end:

```
   plane_create + putc / fill ──→ Plane                      (Phase 6.1)
                ⊕                                              (Phase 6.2 blend)
   light_buffer_new ──→ paint ──→ LightBuffer                 (Phase 6.4 paint)
                ⊕
   light_buffer_apply(buf, plane) ──→ Plane (lit)             (Phase 6.4 apply)
                │
                ▼
        Renderer.back ──→ diff ──→ ANSI                      (Phase 6.3)
```

Estimated 1 quartz-day; actual ~0.4 (single session, 162-test green run including 34 new + 128 prior v0.6 + smoke). Bresenham LOS is the v0.6.4 private LOS implementation; Phase 6.5 replaces it with symmetric shadowcasting and publishes the FOV walker as `std/tui/fov.qz::fov_for_each_visible` — `light_buffer_paint`'s public API does not change.

## Phase 6.5 shipped — symmetric shadowcasting FOV

Phase 6.5 promotes the visibility predicate from a private Bresenham line walk to a public symmetric-shadowcasting walker, published as `std/tui/fov.qz::fov_for_each_visible`. The defining property of Albert Ford's 2019 algorithm — A sees B iff B sees A — is now load-bearing for both lighting and any future gameplay-layer FOV consumer (the brogue-tribute sample's monster vision, deckbuilder line-of-sight effects, etc).

Key shape:

```be
def fov_for_each_visible(
  origin_x: Int, origin_y: Int, radius: Int,
  blocks_light: Fn(Int, Int): Bool,
  visit: Fn(Int, Int, Int): Void   # x, y, distance
): Void
```

- 4-quadrant scan from origin, recursive narrowing of slope wedges per wall/floor transition.
- Integer rational arithmetic (no floats); `(num, den)` pairs compared via cross-products. `_round_ties_up` / `_round_ties_down` hand-written to handle negative numerators correctly under Quartz's truncate-toward-zero integer division.
- Inclusive-start, exclusive-end slope wedge ensures each diagonal cell is visited exactly once (NE owned by EAST, SE by SOUTH, SW by WEST, NW by NORTH).
- Origin always visited at `distance=0`. Cells past Euclidean radius walked-but-not-visited (preserves wall tracking for shadowcasting while filtering caller-visible cells).

`light_buffer_paint` was refactored to call `fov_for_each_visible` with a contribute closure instead of the previous bounding-box + Bresenham walk. Public `paint` API unchanged. Spec coverage stayed green through the refactor — every assertion in the 34-test light spec held under symmetric shadowcasting (Bresenham and Ford's algorithm agree on the test cases used; differences would surface at edge cases like asymmetric corner gaps).

Estimated 0.5 quartz-day; actual ~0.4. 15 new specs at `spec/qspec/tui_v06_fov_spec.qz` covering the algorithm proper plus the symmetry property (A sees B iff B sees A — verified by running FOV from every visible cell back to origin).

After Phase 6.5, v0.6 has shipped: foundation block (6.0-6.3) + lighting (6.4) + FOV (6.5). 177 v0.6 tests green across 6 specs. Phase 6.6 followed in the same session.

## Phase 6.6 shipped — sub-cell pixel blitter

Phase 6.6 ships `std/tui/octant.qz` — a sub-cell pixel grid with four quality tiers for emitting block-character glyphs at increasing resolution. Apps build a `pixel_w × pixel_h` boolean grid via `octant_set` / `octant_fill`, then call `octant_blit_to_plane(b, plane, dst_x, dst_y, quality, fg, bg)` to render one cell per (2 cols × 4 rows) of pixels. The `OctantQuality` enum picks the glyph table:

- `Octant` — full 2×4 sub-cell resolution (Unicode 16; 16 patterns covered + Quadrant fallback in v0.6.6.0; Phase 6.6.1 fills in the remaining 240 from the U+1CD00..U+1CDE5 chart).
- `Quadrant` — 2×2 sub-cell resolution (16 BMP block characters at U+2580/U+2584/U+258C/U+2590/U+2588/U+2596–U+259F + space). Universal terminal support.
- `Half` — 1×2 sub-cell (full / upper-half / lower-half / space). Maximum compatibility.
- `Ascii` — 1×1 (`#` for any-on, space for empty). For test golden output and degraded terminals.

Output cell footprint is identical across qualities: `pixel_w / 2 × pixel_h / 4`. Quality only changes the glyph chosen per cell, so apps can degrade fidelity without rewriting layout.

Geometry rectification: the v0.6 design memo sketched "4w × 2h pixels per cell" but the actual Unicode 16 octant block lays out cells as 2 columns × 4 rows of subpixels (matching how a monospace cell is roughly 2× taller than wide). v0.6.6 follows the Unicode geometry; the bit-ordering convention matches the Unicode standard's digit-N → (N-1)-th bit, top-left first, row-major.

Estimated 1 quartz-day; actual ~0.4. 39 specs at `spec/qspec/tui_v06_octant_spec.qz` cover construction, set/get/fill round-trips, OOB defensives, derived cell dimensions, the full Quadrant 16-entry glyph table, the full Half 4-entry table, Ascii, the 16 known reused Octant patterns + non-reused Quadrant fallback, and `octant_blit_to_plane` composition (cell footprint, fg/bg application, OOB clipping, dst-offset placement).

After Phase 6.6, v0.6 has shipped 7/11 phases: foundation (6.0–6.3), lighting (6.4), FOV (6.5), octants partial (6.6). 216 v0.6 tests green across 7 specs. Next session resumes at **Phase 6.7 — Tier A reimplemented on top of Tier B** (smallest remaining phase at 0.5 quartz-days estimated; collapses today's `Style.render(s)` pipeline into a single 1×N plane that flows through the Phase 6.3 renderer). After 6.7: Phase 6.8 (Base16/Base24 YAML loader + bundle 8–12 themes) and Phase 6.9 (sample roguelike / brogue-tribute proof). Parallel tracks before v0.6 release: **Phase 6.6.1 — octant full-table fill** (must-ship; transcribes the remaining 240 of 256 octant codepoints from U+1CD00..U+1CDE5 — promotes the partial Octant quality tier from "16 patterns + Quadrant fallback" to "world-class subpixel fidelity") and the deckbuilder v0.4 balance pass. Both can land independent of the 6.7→6.9 critical path.

## Phase 6.7 shipped — Tier A on Tier B

Phase 6.7 collapses the duplicated SGR-byte-emission engine in `std/style.qz` onto the v0.6 cell engine's canonical emitter. Concretely:

- `std/tui/cell.qz` gains `cells_render_inline(cells, depth) → String`, the canonical "render Vec<Cell> to inline ANSI" function. Combined-SGR format (matches `Style.render`'s pre-6.7 byte output exactly), full color-depth degradation (RGB → 256 → 16), per-cell-style transition emission (reset + new prefix). `cell_render_inline(c, depth)` is the single-cell convenience.
- `std/tui/cell.qz` gains the canonical color-encoding API: `RGB_FLAG()`, `color_is_rgb`, `color_r`, `color_g`, `color_b`, plus the three degradation helpers (`rgb_to_ansi256`, `rgb_to_ansi16`, `ansi256_to_ansi16`). All moved out of `std/style.qz`'s private namespace so the rest of the v0.6 stack reaches for one canonical owner.
- `std/tui/cell.qz` gains `style_to_cells(text, fg, bg, attrs) → Vec<Cell>` — the Tier-A → Tier-B bridge. One cell per input byte; all cells share the same (fg, bg, attrs).
- `std/tui/plane.qz` gains `plane_render_inline(plane, depth) → String`. Single-row planes route directly through `cells_render_inline`; multi-row planes emit each row inline + join with `\n`, with SGR state closed before each newline so rows don't bleed style into terminal scrollback.
- `std/style.qz`'s `_style_render` body collapses to:
  ```be
  if s.is_empty()
    return text
  end
  var cells = cl::style_to_cells(text, s._fg, s._bg, s._attrs)
  return cl::cells_render_inline(cells, depth)
  ```
  Every emission helper (`_emit_sgr`, `_emit_fg{,_rgb,_indexed,_basic}`, `_emit_bg{,_rgb,_indexed,_basic}`, `_RGB_FLAG`, `_is_rgb`, `_rgb_r/g/b`, `_rgb_to_ansi256`, `_rgb_to_ansi16`, `_ansi256_to_ansi16`, `_min3`) is gone — no compat shims, no aliases. `std/style.qz` shrank from 650 → 301 LOC.

**Byte-identity:** The new path produces exactly the same bytes as the pre-6.7 `_style_render` for every input. `style_spec.qz` (35 tests, all combined-SGR + degradation assertions) and `style_render_concat_spec.qz` (5 tests) stay green under the new emitter. 6 widget specs that consume Style indirectly (confirm, spinner, toast, status_bar, tabs, progress, truncate_styled = 138 tests) also stay green. New 35-test `spec/qspec/tui_v06_phase67_spec.qz` covers the cell-engine surface directly: empty/uniform/heterogeneous cell-style runs, `style_to_cells` correctness, `plane_render_inline` row-stitching, color-encoding round-trips, degradation helpers, all four depths (0/16/256/16777216).

**Render.qz left untouched.** The Phase 6.3 diff renderer has different output requirements: cursor positioning is mandatory, truecolor-only is fine, per-cell SGR transitions are emitted as separate `\x1b[...m` sequences (not combined). Consolidating render.qz onto the cell.qz emitter is a v0.6.x polish task — it would shave the duplicated `_emit_attrs`/`_emit_fg`/`_emit_bg` helpers but requires a different SGR-state machine because the diff path tracks (front, back) cell pairs, not a single cell stream.

Estimated 0.5 quartz-day; actual ~0.4. Now 8/11 phases shipped (foundation + lighting + FOV + octants-partial + Tier-A-on-B). 251 v0.6-related tests green across 8 specs.

## Phase 6.7+ next steps

After 6.6.1 + 6.7, the v0.6 critical path is two remaining phases:

| Phase | Why it matters next | Estimate |
|---|---|---|
| **6.8** | Base16/Base24 YAML loader + bundle 8–12 themes. Without this, theme switching is "edit Style code in the widget" rather than "swap a YAML file" — the differentiator from Lipgloss/Ratatui. | 1.5 quartz-days |
| **6.9** | Brogue-tribute sample roguelike. Stress-tests every v0.6 surface (cells + lighting + FOV + full octants + theme + diff renderer) end-to-end and produces the canonical demo for the framework's "look at this" page. | 2 quartz-days |

**v0.6 release blocked on:** both of these. Once they land, v0.6 ships and the deckbuilder v0.4 balance pass becomes the next focus.

## Phase 6.6.1 shipped — octant full-table fill

Phase 6.6.1 closes the v0.6.6.0 partial-coverage gap: the `OctantQuality::Octant` tier now emits the correct Unicode 17 codepoint for every one of the 256 possible 2×4 sub-cell patterns. Before 6.6.1, only 16 quadrant-clean patterns hit their Unicode codepoint and the remaining 240 fell back to `Quadrant` quality (visually correct at 2×2 resolution but losing the 2×4 fidelity that the new Unicode 16 block was designed for). After 6.6.1, the visceral fidelity payoff for roguelikes, dashboards, and dense info displays is real — every pattern gets its own glyph.

The table maps 256 patterns to:
- **230 new octant codepoints** in U+1CD00..U+1CDE5 (the entire BLOCK OCTANT block from Unicode 16, Sept 2024).
- **26 reused codepoints** from earlier blocks:
  - 16 quadrant-clean patterns at U+2580..U+259F (Block Elements, Unicode 1.1).
  - 4 single-corner-subpixel patterns at U+1CEA0..U+1CEAB (Symbols for Legacy Computing Supplement).
  - 2 single-row patterns: U+1FB82 (UPPER 1/4) for the top row, U+2582 (LOWER 1/4) for the bottom row.
  - 2 three-row patterns: U+1FB85 (UPPER 3/4) for top 3 rows, U+2586 (LOWER 3/4) for bottom 3 rows.
  - 2 middle-rows-of-one-column patterns at U+1FBE6 (left col mid 2) and U+1FBE7 (right col mid 2).

Implementation shape:
- `octant_codepoint(pat: Int) → Int` is the public lookup. Dispatches via 16 nibble-keyed helper functions (`_oct_cp_h0` … `_oct_cp_hF`) — mechanical 256-entry table that's easy to verify line-by-line against the source.
- `codepoint_to_utf8(cp: Int) → String` is the public UTF-8 encoder. One-liner: hand the codepoint to `StringBuilder.append_char` and trust the runtime.
- `_octant_glyph(pat)` collapses to `codepoint_to_utf8(octant_codepoint(pat))` — replaces the v0.6.6.0 16-pattern if-chain with table-driven full coverage.

Source provenance: Bobby-Miller community gist (https://gist.github.com/Bobby-Miller/d48dabce3179f328b15db4737740fd55), transcribed and converted from the gist's bit ordering (high-nibble = left col top→bottom, low-nibble = right col top→bottom) to this module's bit ordering (bit 0 = top-left, row-major down to bit 7 = bottom-right). One gist typo corrected: the top-3-rows pattern (my-pattern 0x3F) was U+2586 (LOWER 3/4) in the gist; the geometrically-correct codepoint is U+1FB85 (UPPER 3/4) — the bottom-3-rows pattern (my-pattern 0xFC) is the one that legitimately uses U+2586. Cross-validated against the Unicode "BLOCK OCTANT-DIGITS" naming convention for the boundary entries (U+1CD00 = OCTANT-3, U+1CDE5 = OCTANT-2345678).

A gotcha worth recording: an earlier draft of `codepoint_to_utf8` hand-rolled the 4-byte UTF-8 encoding and called `StringBuilder.append_char` once per byte. That double-encoded every high-bit byte because `append_char` takes a *codepoint*, not a byte — so 0xE2 (the first byte of ▘'s UTF-8 encoding) got re-emitted as the 2-byte UTF-8 sequence for U+00E2 = "â". Once the codepoint is built, just hand it to `append_char` whole.

Estimated 0.5 quartz-day; actual ~0.6 (the typo discovery + bit-ordering conversion + double-encoding bug ate the 0.1 overage). 48 tests green at `spec/qspec/tui_v06_octant_spec.qz` (39 prior + 9 new for full-table coverage including bit-ordering invariants, codepoint-range counts, UTF-8 byte-length round-trips). All 7 v0.6 widget specs that consume octants indirectly stay green.

After 6.6.1 + 6.7, v0.6 has shipped 9/11 phases. Remaining: **6.8** (Base16/Base24 YAML loader + bundled themes) and **6.9** (brogue-tribute sample roguelike). v0.6 release blocked on both.

## Phase 6.8 shipped — Base16/Base24 YAML loader + 11 bundled themes

Phase 6.8 closes the theming loop opened in Phase 6.0: `std/tui/theme.qz` now ships a targeted Base16/Base24 YAML loader (`theme_from_string` + `theme_load_yaml` returning `Result<Theme, ParseError>`) plus eleven bundled curated themes. Theme switching is now a one-line file load instead of "edit Style code in the widget" — the differentiator from Lipgloss/Ratatui that the original v0.6 design called out.

Bundled themes (all hex values verified against `github.com/tinted-theming/schemes/base16`):

- **Catppuccin Mocha** (Dark) — shipped Phase 6.0, the default.
- **Catppuccin Latte** (Light) — light-mode Catppuccin companion.
- **Gruvbox Dark Hard** + **Gruvbox Light Hard** — classic warm palette in both modes.
- **Tokyo Night Dark** — modern editor-canon dark scheme.
- **Nord** — cool-blue arctic by arcticicestudio.
- **Dracula** — purple/pink canonical (clach04 Base16 port).
- **Solarized Dark** + **Solarized Light** — Ethan Schoonover's photometric scheme in both modes.
- **Rosé Pine Moon** — stylish dark-mode favourite.
- **Everforest Dark** — earthy, low-contrast option by Sainnhe Park.

That's eleven curated bundles covering the eight schemes the design memo enumerated, with two paired light/dark companions (Catppuccin and Solarized add their light variants; Gruvbox already shipped both). Consumers wanting one of the other 200+ schemes from `tinted-theming/schemes` drop the YAML in `~/.config/<app>/themes/` and call `theme_load_yaml(path)` — the parser accepts both spec-0.10 (flat top-level `baseXX:` keys) and spec-0.11 (nested under `palette:` block) layouts.

YAML parser shape (~150 LOC, file-private helpers):

- `_theme_strip_yaml_comment` — strips end-of-line `#` comments while respecting `"..."` and `'...'` quote contexts (so `"#1e1e2e"` is not mis-detected as a comment).
- `_theme_strip_quotes` — strips surrounding `"..."` or `'...'`; pass-through if unquoted.
- `_theme_base_slot_index` — parses `baseXX` keys; returns 0..15 for `base00`..`base0F`, 16..23 for `base10`..`base17`, -1 otherwise.
- `_theme_is_valid_hex` — verifies every byte is `[0-9a-fA-F]` after the optional `#` prefix is stripped.

Acceptance behaviour:

- All 16 `base00..base0F` slots are mandatory — missing any returns `Err`.
- Base24 extension (`base10..base17`) is opt-in; partial sets (some but not all 8) are rejected as `Err` to keep the type honest. None set → `base10_17 = None`. All 8 set → `base10_17 = Some(Base24Ext{...})`.
- Unknown top-level keys (`system`, `slug`, `description`, future scheme metadata) are silently ignored, so newer scheme spec versions don't break old Quartz builds.
- Hex values can be `"#1e1e2e"`, `"1e1e2e"`, or unquoted `1e1e2e` — the parser handles all three.

Non-goals: the parser is not a full YAML parser. It does not handle multi-line strings, anchors/aliases, sequence syntax, or numeric/bool type coercion. Base16 schemes don't need any of those, and the targeted parser is ~150 LOC vs ~1500 LOC for a full YAML implementation. A general YAML parser is tracked in `ROADMAP.md` Tier 4 #40.

Estimated 1.5 quartz-days; actual ~0.5. The 3× under-estimate came from existing infrastructure (`style::hex_color`, `str_byte_find`, `Result` + `ParseError` already in `std/error`, `read_file` + `file_exists` as builtins) covering most of the implementation surface — the only new code was YAML-specific tokenization and the eleven theme constructors.

20 new tests at `spec/qspec/tui_v06_theme_spec.qz`: bundled-theme verification (one test per new theme covering name + variant + 3-6 representative slot hex matches), parser round-trip (canonical Catppuccin Mocha YAML produces the same Theme as the bundled constructor; every base slot equality-checked), spec-0.10 vs spec-0.11 layout acceptance, comment + quote handling, Base24 extension acceptance + partial-set rejection, missing-slot rejection, bad-hex rejection, semantic-accessor parity. All 9 v0.6 specs (216 prior + 20 new = 236 v0.6 tests) green.

After Phase 6.8, v0.6 has shipped 10/11 phases. Only **6.9** (brogue-tribute sample roguelike) remains before v0.6 release. The `theme_watch(path, sender)` v0.7 follow-up filed in `TUI_V06_OPEN_QUESTIONS.md` Q4 is unblocked — consumers wanting hot-reload can now build it on top of `theme_load_yaml`.

## Phase 6.9 shipped — brogue-tribute sample roguelike

Phase 6.9 closes v0.6 with `game/brogue-tribute/main.qz` — a single-screen 80×24 dungeon room that exercises every v0.6 surface end-to-end. The demo is the canonical "look at this" page for the framework: roguelike authors and dense-display authors can grep one file to see the entire v0.6 stack composed together.

Surfaces touched by the ~470-LOC implementation:

- **Cells + Channels** (Phase 6.0) — every dungeon glyph is a `Cell` with `Channel` fg/bg + alpha + attrs. Player `@` carries `CELL_ATTR_BOLD`; brazier `!` is bold + accent-coloured; cells outside FOV but previously visited render `CELL_ATTR_DIM`.
- **Plane DAG** (Phase 6.1) — five planes (title 80×1, dungeon 80×21, minimap 8×4, status 80×1, hint 80×1) all render independently and `plane_blit` onto an 80×24 root.
- **Blend modes** (Phase 6.2) — `BlendMode::None` for opaque overlays in the demo; the underlying `_apply_channel` exercises the additive RGB blend that lights cells.
- **Diff renderer** (Phase 6.3) — `renderer_with_back` + `renderer_diff` with DEC 2026 sync wraps. Player movement re-emits ~3 cells per frame instead of the whole screen; second diff against unchanged back is provably ≤16 bytes (verified in `spec/qspec/tui_v06_brogue_smoke_spec.qz`).
- **Light buffer** (Phase 6.4) — `light_buffer_new` with cool-blue ambient `(30,30,60)` + `light_miners` at the player + `light_torch_flicker` at the brazier. Light buffer applied to the dungeon plane via `light_buffer_apply` BEFORE the dungeon flows into the root.
- **FOV** (Phase 6.5) — `fov_for_each_visible` drives both the player's per-frame visibility computation (`world_compute_fov`) and the light buffer's per-light walks (delegated internally by `light_buffer_paint`). `visited` accumulates monotonically across frames; verified in the smoke spec via "move + re-walk preserves prior visits."
- **Octants** (Phase 6.6 + 6.6.1) — top-right minimap is a 16×16 `OctantBlitter` rasterising the dungeon walls, downsampled via the full Unicode 17 octant table to an 8×4 cell area at `OctantQuality::Octant`.
- **Tier A on Tier B** (Phase 6.7) — title / status / hint planes write ASCII rows of `Cell` values via the same Vec<Cell> pipeline that `Style.render` uses internally now.
- **Themes** (Phase 6.8) — `T` cycles through all 11 bundled Base16 themes in a stable order (Catppuccin Mocha → Latte → Gruvbox Dark → Light → Tokyo Night → Nord → Dracula → Solarized Dark → Light → Rosé Pine Moon → Everforest → wrap). Status bar shows the current theme name and the live torch state.

Game logic deliberately minimal: walls + player + brazier + FOV + lighting + theme cycle + torch toggle. No combat, no inventory, no monsters, no level generation. The point is "stress-test the framework," not "ship a complete roguelike." Roguelike authors who want a working game start from this scaffold, replace `world_init` with their own dungeon generator, and inherit the rendering pipeline.

Build pipeline: `quartz game/brogue-tribute/main.qz | llc -filetype=obj | clang ... -o game/brogue-tribute/bin/brogue-tribute`. The `bin/` directory is `.gitignore`d alongside `game/deckbuilder/bin/` — binaries are per-machine artifacts.

12 smoke tests at `spec/qspec/tui_v06_brogue_smoke_spec.qz`: world init / wall predicates / OOB-as-wall, FOV self-cell + radius bound + visited-monotonicity, light buffer ambient + miner's-light contribution + far-cell ambient parity, octant minimap dimensions + non-empty glyphs, diff renderer first-frame non-empty + second-frame near-empty, theme cycle distinct-palette invariant. Live binary verified via piped key sequence (`jjlllllllTTTFq`) — 14 frames, clean exit, ~168KB of cumulative diff output across the run.

Estimated 2 quartz-days; actual ~0.6. Came in 3× under because every v0.6 surface was already shipped and tested through Phase 6.0–6.8 — the brogue-tribute is composition, not new code. The only real implementation work was the `World` struct + state transitions + plane composition order; everything else slotted into existing primitives.

After Phase 6.9, **v0.6 has shipped 11/11 phases**. The cell engine, lighting model, FOV walker, octant fidelity, theme system, and the canonical demo are all in tree. v0.6 is ready to release. Next focus shifts to v0.7 follow-ups: theme hot-reload (`theme_watch`), incremental Tier-A→Tier-B widget migration, and the full YAML parser audit (ROADMAP Tier 4 #40).

## Post-v0.6 — brogue-tribute case study + v0.7 roadmap

After v0.6 shipped, the May 6-7 2026 session continued by evolving brogue-tribute through eight versions (v0.2 → v0.8): BSP procgen, animated tick goroutine + monsters + bump combat, proper FOV with lighting masked to current vision, FOV-aware octant minimap, doors + per-biome floor colors, BFS-pathfinding monster AI, items + persistent run progression. Ten total commits across the session, ~3500 LOC of game/stdlib/spec code, **zero touches to `self-hosted/*.qz`** — the compiler stayed completely out of the way.

That session crystallized concrete v0.7 follow-ups: stdlib promotions (public `octant_pattern_at`, two-blitter `octant_blit_layered` helper, BFS grid-walker module, `program_run_raw` for non-TEA apps), one big language-feature ask (struct update syntax — most-impacted compiler change available right now), brogue-tribute polish (kill counter, victory condition, monster variety, animation effects), and **SIGIL** — the runic deckbuilder showcase that fuses brogue-tribute's real-time lighting with the deckbuilder's turn-based combat to exercise every v0.6 surface in service of a polished demo.

Full plan with sequencing, estimates, and acceptance criteria: [`POST_V06_ROADMAP.md`](POST_V06_ROADMAP.md).

## References

### Frameworks
- [Notcurses dankwiki overview](https://nick-black.com/dankwiki/index.php/Notcurses) — the cell-power gold standard
- [notcurses_plane(3)](https://notcurses.com/notcurses_plane.3.html) — plane DAG semantics
- [notcurses_render(3)](https://notcurses.com/notcurses_render.3.html) — composition algorithm
- [Lipgloss v2 release blog](https://charm.land/blog/v2/) + [beta 2 — Layer/Canvas](https://charm.land/blog/lipgloss-v2-beta-2/)
- [Ratatui rendering under the hood](https://ratatui.rs/concepts/rendering/under-the-hood/) — diff algorithm
- [Textual reactivity guide](https://textual.textualize.io/guide/reactivity/) + [animation](https://textual.textualize.io/guide/animation/)
- [tcell GitHub](https://github.com/gdamore/tcell) — termbox successor
- [python-tcod console docs](https://python-tcod.readthedocs.io/en/latest/tcod/console.html) — blend mode enum source

### Roguelike engines
- [BrogueCE Light.c](https://github.com/tmewett/BrogueCE/blob/master/src/brogue/Light.c) — the lighting math
- [Cogmind color customization](https://www.gridsagegames.com/blog/2018/01/color-customization/) — filter chains
- [ROT.js homepage](https://ondras.github.io/rot.js/)
- [gridbugs roguelike-lighting demo](https://www.gridbugs.org/roguelike-lighting-demo/)

### FOV
- [Symmetric Shadowcasting — Albert Ford](https://www.albertford.com/shadowcasting/) — the modern default
- [Recursive Shadowcasting — RogueBasin](https://www.roguebasin.com/index.php/FOV_using_recursive_shadowcasting)
- [Comparative FOV study — RogueBasin](https://www.roguebasin.com/index.php/Comparative_study_of_field_of_view_algorithms_for_2D_grid_based_worlds)

### Terminal / Unicode
- [Truecolor support gist](https://gist.github.com/kurahaupo/6ce0eaefe5e730841f03cb82b061daa2)
- [Terminal compatibility matrix](https://tmuxai.dev/terminal-compatibility/)
- [Terminal graphics protocols (Kitty/Sixel/iTerm2)](https://akmatori.com/blog/terminal-graphics-protocols)
- [Unicode 16 octants — Ghostty discussion](https://github.com/ghostty-org/ghostty/discussions/4108)

### Theming
- [tinted-theming/schemes](https://github.com/tinted-theming/schemes) — 200+ Base16 themes
- [Base16 spec](https://github.com/chriskempson/base16) — original
- [Base24 spec](https://github.com/Base24/base24) — extension
