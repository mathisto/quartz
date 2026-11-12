# TUI v0.6 — Open Questions Resolved

> **Status**: Decisions locked, 2026-05-06.
> **Companion**: [`TUI_V06_CELL_ENGINE.md`](TUI_V06_CELL_ENGINE.md) (the design memo this resolves).
> **Purpose**: Each of the six open questions in the v0.6 design memo's "Open questions for next session" section gets one resolution + the rationale that justifies it. Implementation cannot start until these are locked, because they shape the public types and the migration story.

The shape of the v0.6 build hangs on these calls. Picking wrong on Q1 wastes a Phase 6.0 round-trip; picking wrong on Q5 saddles every future widget with two parallel APIs. Resolutions below are picked to keep the memo's commitments (cell-power on par with Notcurses, lighting on par with Brogue, ergonomics on par with Bubble Tea) without paying for power consumers don't need.

---

## Q1. Cell primitive storage layout — packed 16-byte vs unpacked 32-byte

**Decision: ship unpacked. Notcurses-style packed layout deferred to a v0.7 micro-optimization, *iff* benchmarks show plane allocation as a real bottleneck.**

The memo flagged that the design's `Cell` is ~32 bytes (egc String handle + 2 Channel structs + attrs Int) and Notcurses uses a 16-byte packed cell with EGC-pool indirection. For a 200×60 plane that's ~384 KB unpacked vs ~192 KB packed.

**Why unpacked wins for v0.6:**

1. **Cell semantics survive renames.** With unpacked structs, every field is named — `cell.fg.rgb`, `cell.attrs`, `cell.egc`. With a packed Int-bag layout we'd need accessor functions on top of bit-shifting (`cell_fg_rgb(c)`, `cell_set_attr(c, n)`), which in turn require the typed-handle workaround pattern from the Quartz codebase (see `feedback_three_layer_typearg_leak.md`). Net: packed buys one cache line per cell, costs three layers of boilerplate per accessor.
2. **Allocation pressure is bounded.** A typical TUI app touches one or two planes at root size + a handful of widget-sized planes. Even worst-case (a 4K monitor with a 400×120 cell grid), unpacked total = ~1.5 MB. That's not a budget concern on any host the v0.6 framework targets.
3. **The right time to optimize is when we have real workloads.** The memo's deckbuilder is the v0.6 dogfood; if its 80×24 plane (≈60 KB unpacked) ever shows up on a profile, *then* we know whether to pack `Channel` into 28 bits each or pool EGCs. Designing for it pre-emptively bakes complexity into the public API for a problem that may never exist.
4. **Ratatui made the same call.** Ratatui's `Cell` is a `String` + two `Color` enums + a `Modifier` bitset — wider than ours, no packing, ships in production for thousands of apps. Notcurses packs because it's targeting "render every pixel, 60fps, low-memory embedded" — a tighter envelope than v0.6 needs.

**What this means for Phase 6.0:**
- `Cell` is a struct with named fields: `egc: String`, `fg: Channel`, `bg: Channel`, `attrs: Int`.
- `Channel` is a struct: `rgb: Int` (truecolor or palette index — see Q-bonus below), `alpha: AlphaMode`, `default_fg: Bool`, `palette: Bool`.
- No bit-twiddling accessors. Direct field access is the API.

**What we owe future-us:** A v0.7 micro-benchmark milestone that profiles a 200×60 plane's allocation cost on the brogue-tribute sample. If allocation is in the top 3 of any flamegraph, revisit. Filed as a v0.7 follow-up — not a v0.6 blocker.

**Q-bonus — color representation reuse.** `Channel.rgb` is an `Int` using the same encoding as today's `std/style.qz` color values: bit 24 (`_RGB_FLAG = 0x1000000`) marks truecolor; values < 16 are ANSI 16; values 16-255 are 256-palette indices; values ≥ `_RGB_FLAG` carry a packed `(r << 16) | (g << 8) | b`. This is non-negotiable: `theme.base05` is a `Color` (= `Int`) and consumers must be able to write `Style.fg(theme.base05)` and `Channel { rgb: theme.base05, ... }` interchangeably without a converter. The `palette: Bool` flag in `Channel` is overdetermined by the rgb int's representation — keep it as an explicit cache-friendly hint, but treat `_is_rgb(rgb)` as the source of truth at flush time.

---

## Q2. EGC pool vs inline — v0.6 or defer to v0.7

**Decision: defer to v0.7 (or possibly never). Ship `egc: String` inline.**

Notcurses' "25-bit pool index OR inline 7-bit ASCII" is an extension of Q1's packing argument, with one extra wrinkle: the EGC pool is a per-render-context arena that gets reused across cells. The win is that "▀" (one extended grapheme cluster, ~3 UTF-8 bytes) costs 25 bits in the cell instead of one heap-allocated String per cell.

**Why defer:**

1. **Ratatui shipped without it.** Same calculus as Q1 — Quartz's targets aren't tight enough to need pool indirection for v0.6.
2. **Quartz strings are ref-counted handles, not copies.** A Cell holding `egc: " "` (the dominant case) holds an Int handle into the shared string interner. The actual byte cost is closer to 8 bytes per cell for the egc field, not the ~24 bytes a naive analysis suggests. The packing savings shrink correspondingly.
3. **The pool's API friction cost is real.** Pool-indirection means cells aren't self-describing — to read `cell.egc` you need the pool the cell was minted from, which means every API that touches cells has to thread the pool through, which means widgets thread it too. Notcurses tolerates this because its API surface is small and uniform; the v0.6 widget API (form, list, viewport, status_bar, tabs, toast, …) would have to change.
4. **The "inline 7-bit ASCII" leg is a micro-optimization for the 95% case.** Most cells are ASCII letters, digits, punctuation, or space. A future v0.7 optimization could split `Cell` into two flavors (`AsciiCell` 16B vs `EgcCell` with pool ref), but for v0.6 the shipping shape — `egc: String` — is simpler and lets the rendering pipeline degrade gracefully for non-ASCII without special cases.

**What this means for Phase 6.0:** `Cell.egc` is `String`. Empty cells use `egc: " "` (single space — what every terminal renders as a blank). Multi-codepoint clusters (combining marks, ZWJ sequences, flags) are stored verbatim and emitted verbatim at flush time. The renderer handles wide-character measurement via `std/tui/layout.qz::visible_width` (already codepoint-aware).

---

## Q3. Coordinate system for planes — pixels vs cells, or unified

**Decision: unified cell coordinates. Octants scaled internally inside `OctantBlitter`.**

The memo recommended this answer ("unified cell coordinates with octants conceptually scaled internally"). Locking it in.

**Why unified cell coordinates:**

1. **Plane composition is a cell operation.** `plane_blit(src, dst, sx, sy, sw, sh, dx, dy, blend)` is talking about cells — a cell is the indivisible unit the terminal can draw. There's no useful sub-cell semantic at the composition layer (terminals don't have sub-cell mouse hits, focus, cursors, or attribute boundaries).
2. **Octant blitter is a producer of cell content, not a coordinate system.** `OctantBlitter` accepts a `4w × 2h` pixel grid (the *source* coordinate system, internal to the blitter) and produces a `w × h` cell region downsampled to one octant character per output cell. The pixel grid is private. The output is cells.
3. **Two coord systems break composition.** If `Plane` had an internal pixel mode, every operation would need a "what are the units?" parameter and every error case would say "you blit a cell-mode plane onto a pixel-mode plane, what did you expect?" Notcurses doesn't do this; neither should Quartz.

**What this means for Phase 6.0:**
- `Plane`'s `w`, `h`, `rel_x`, `rel_y`, `cells` are all in cells.
- `plane_putc(p, x, y, cell)`, `plane_blit(...)`, `plane_merge_down(...)` — all cell coordinates.
- `OctantBlitter` (Phase 6.6) takes pixel-grid input and emits to a plane region in cells: `octant_blit_to_plane(blitter, plane, dst_x, dst_y)` where `dst_x, dst_y` are cells and the blitter's `pixel_w / 4`, `pixel_h / 2` define the cell footprint.

---

## Q4. Theme hot-reload via runtime extension — yes/no

**Decision: no for v0.6. Theme hot-reload is **not** wired into the runtime.**

The memo asked: should `program` watch a theme file via SIGWINCH-style runtime extension and auto-reload?

**Why no:**

1. **It's not a v0.6 core capability.** Theme support is the value prop. Theme *file watching* is a polish-tier ergonomic win that costs runtime API surface (a new FrameMsg variant, a new Cmd, a new background goroutine) and forces every consumer to think about reload semantics — even consumers that never need it.
2. **Consumers can do it themselves trivially.** A theme is a value: `Theme.load_yaml(path)` returns one. Any app that wants live reload can spawn a goroutine that polls the file's mtime, calls `theme_load_yaml` on change, and pushes a `Msg::ThemeChanged(t)` via `Sender<M>` (shipped in v0.5 Phase 11). The runtime doesn't need to know.
3. **YAGNI bias is correct here.** Of the v0.6 dogfood consumers (deckbuilder, brogue-tribute), neither needs theme hot-reload. Roguelikes don't theme-switch mid-run; the deckbuilder loads once at boot. We'd be designing for a hypothetical config-editor consumer that doesn't exist yet.
4. **If consumers do build it, the pattern teaches us how the canonical API should look.** Better to see two real implementations of "watch + reload" before we bake one into stdlib than to bake the wrong one and pay migration cost.

**What this means for the v0.6 runtime API:** Zero new surface. `program.set_theme(Theme)` is the only new method we'll add (Phase 6.0). Hot-reload, if it ever lands, is a **v0.7+** layer on top using existing primitives.

**Filed as v0.7 candidate:** `theme_watch(path, sender)` helper in `std/tui/theme.qz` that spawns a goroutine + emits `ThemeChanged` messages via a passed-in `Sender<M>`. Pure stdlib, no runtime change.

---

## Q5. Style→Theme migration path — mass v0.6.0 or incremental v0.6.x

**Decision: incremental over v0.6.x patch releases. Add `theme: Theme` as a new (optional, default-Catppuccin) field on the existing `*Styles` structs; migrate widget defaults to use semantic accessors as each phase ships.**

This is the highest-leverage call in the doc — pick wrong and we either (a) ship a v0.6.0 that breaks every existing widget consumer or (b) ship two parallel theming systems for a release cycle and pay the migration tax forever.

**Why incremental:**

1. **The v0.5 widget API surface is large and consumer-shaped.** Every widget exports a `<Widget>Styles` struct with explicit `Style` fields (`ProgressBarStyles { fill, empty, border }`, `ConfirmStyles { ... }`, etc). Mass-migrating all of these to `theme_*` accessors in a single v0.6.0 release means rewriting every test, every example, and the deckbuilder dogfood in one shot. That's a flag-day migration with no fallback.
2. **Quartz's "no compat shims" rule cuts in our favor here, not against.** The rule is: don't ship two parallel APIs *forever*. It does not forbid incremental migration *across the v0.6.x patch line*, because v0.6.x is a single release vector — every patch is the only version that exists at that moment. As long as the migration completes before v0.7.0, there is never a "compat shim" sitting in tree; there's only the current best version.
3. **Per-widget incremental migration matches how widgets actually evolve.** The widget API changes shape every v0.x as we discover new patterns. Rolling theme-default migration into the regular per-widget cadence amortizes the cost across the work that's already happening.
4. **Default-to-Catppuccin-Mocha gives every consumer a beautiful starting point.** Users who never touch the theme system get a curated palette out of the box. Users who care about theming get the semantic accessors as a layer on top.

**What this means concretely:**

**Phase 6.0 (this session)** — ship the foundation:
- `Theme` struct + `ThemeVariant` enum + 16 base slots + Base24 extension slot in `std/tui/theme.qz`.
- Semantic accessors: `theme_bg`, `theme_fg`, `theme_dim`, `theme_selection_bg`, `theme_status_bar_bg`, `theme_status_bar_fg`, `theme_error`, `theme_warning`, `theme_info`, `theme_success`, `theme_special`, `theme_accent(t, slot)`.
- A bundled `theme_catppuccin_mocha()` constructor returning the full Theme value with every slot pre-populated. (Other bundled themes deferred to Phase 6.8 alongside the YAML loader.)
- No widget changes yet. Widgets continue to use raw `Style` values.

**Phases 6.1-6.8** — foundation block + lighting + FOV + octants + Tier-A reimpl: no widget migration. The widgets already work.

**Phase 6.8 (themes ship)** — bundle the remaining 7-11 themes. Widgets remain unchanged.

**Phase 6.9+ (deckbuilder dogfood + brogue-tribute)** — each app surfaces specific accessors that make sense (e.g., `theme_status_bar_bg` becomes the deckbuilder header background). Per-widget defaults migrate as the gap is observed.

**v0.7.0 milestone** — every `*Styles` default constructor uses `theme_*` accessors against the runtime's active theme. By this point the migration is structurally complete.

**No compat shims at any point.** Every widget either uses raw colors (today) or theme accessors (after migration); never both. The "incremental" axis is across widgets, not within a single widget's API.

---

## Q6. `docs/design/DECKBUILDER_V04_BALANCE.md` — split or appendix

**Decision: split into its own design doc once v0.4.1 starts.** Until then, the balance plan lives as the "Sister design" appendix in `TUI_V06_CELL_ENGINE.md`.

**Why split eventually:**

1. **The deckbuilder is the dogfood, but it's a separate track.** v0.6 is a TUI framework arc. Deckbuilder v0.4 is a game-design balance arc. They share calendar slots and the v0.4.6 / v0.6.4 co-sequencing is real, but neither depends on the other's internals.
2. **The current six-bullet plan is small enough to live inline.** The whole "Sister design" section is six paragraphs. Promoting it to its own doc *now* would create a near-empty file and another cross-reference to maintain.
3. **As soon as we ship v0.4.1, the plan grows.** Each shipped phase adds an "actual vs estimated" callout, lessons learned, and follow-up filings. By v0.4.3 the plan needs its own structure (status table, per-phase tradeoffs, calibration data) and inline residence in the v0.6 memo becomes friction.

**Trigger to split:** the moment v0.4.1's first commit lands. At that point:
- Create `docs/design/DECKBUILDER_V04_BALANCE.md` with the six-bullet plan as the kickoff section.
- Remove the "Sister design" section from `TUI_V06_CELL_ENGINE.md`; replace with a one-line cross-reference in the same place.
- Per-phase status updates land in the new doc going forward.

**What this means for Phase 6.0:** Nothing. The deckbuilder track is parallel-shippable; this resolution affects only doc layout, not implementation order.

---

## Implementation kickoff checklist (resolved)

The original memo's checklist with each item now decided:

- [x] Read this doc end-to-end + the four cross-references in the header
- [x] Resolve the six open questions above *(this doc)*
- [ ] Save fix-specific golden binary (`quartz-pre-tui-v06-golden`) — **next step**
- [ ] Phase 6.0 — `Cell` + `Channel` + `Theme` struct first; then accessors; spec at `spec/qspec/tui_v06_cell_primitive_spec.qz`
- [ ] Quake guard + smoke (style_demo + brainfuck) + commit

## Phase 6.0 acceptance criteria

Specifically what "Phase 6.0 ships" means:

1. `std/tui/cell.qz` exports: `Cell` struct, `Channel` struct, `AlphaMode` enum (4 variants: `Opaque`, `Blend`, `Transparent`, `HighContrast`), attribute-bitset constants (`CELL_ATTR_BOLD`, `_DIM`, `_ITALIC`, `_UNDER`, `_STRIKE`, `_REVERSE`, `_BLINK`), and constructors: `cell_blank()`, `cell_char(egc)`, `channel_default()`, `channel_rgb(rgb)`, `channel_palette(idx)`.
2. `std/tui/theme.qz` exports: `Theme` struct (16 base slots `base00`-`base0F`, `name`, `author`, `variant: ThemeVariant`, `base10_17: Option<Tuple>`), `ThemeVariant` enum (`Light`, `Dark`), all twelve semantic accessors from the memo, `theme_catppuccin_mocha()` constructor.
3. `spec/qspec/tui_v06_cell_primitive_spec.qz` covers: cell construction, channel construction across all three color paths (default / rgb / palette), alpha mode round-trip, attribute bitset operations, theme accessor identity (every accessor returns the documented base slot), Catppuccin Mocha values match the canonical YAML in `tinted-theming/schemes`.
4. `quake guard` passes. Fixpoint stamp current. Smoke tests (`style_demo` + `brainfuck`) pass after the rebuild.
5. No widget code changes. The Phase 6.0 foundation is purely additive — every existing v0.5 widget continues to work unchanged.
