# Post-v0.6 Roadmap — TUI framework + brogue-tribute + SIGIL

> **Status**: Filed 2026-05-07. Companion to `TUI_V06_CELL_ENGINE.md` (v0.6 cell engine arc, 11/11 phases shipped) and `BROGUE_TRIBUTE.md` notes embedded in commit history (`212f1503` → `c9e091cf`).
>
> **Origin**: Captured at the end of the May 6-7, 2026 session that shipped TUI v0.6.8 (theme YAML loader), v0.6.9 (brogue-tribute initial demo), and brogue-tribute v0.2 → v0.8 (BSP procgen → BFS-pathfinding monsters → items). One session, ten commits, ~3500 LOC of game/stdlib/spec code, zero touches to `self-hosted/*.qz`.

The session that produced this doc was a mile-marker. The compiler disappeared — stayed completely out of the way for ten commits — and the work was purely stdlib + game code. v0.6 cell engine + brogue-tribute together exercised every async / concurrency / rendering / lighting / FOV / octant / theme surface end-to-end and surfaced concrete architectural patterns that should live in stdlib + concrete language gaps that should land in the compiler.

This doc captures four threads of follow-up:

- **A. brogue-tribute polish** — kill counter, victory condition, monster variety, animation effects (~1-2 quartz-days)
- **B. Framework follow-ups** — patterns from brogue-tribute that should be promoted to stdlib (~2-3 quartz-days)
- **C. Compiler + language lessons** — gaps surfaced by the session that should land as language features (~1-2 quartz-days, mostly one big win)
- **D. SIGIL — runic deckbuilder** — the showcase demo that combines deckbuilder turn-based combat with brogue-tribute real-time lighting on rendered ASCII card art (~3-5 quartz-days)

---

## A. brogue-tribute polish (game-facing)

### A.1 Kill counter + victory condition

`world.kills_total: Int` — increments on every monster death across all floors. `world.kills_floor: Int` — resets per floor. Status bar shows `Kills N`. Victory condition: reach floor 5 OR kill 30 monsters total — whichever first. Triggers a "YOU WIN" overlay with the same Dark-Souls-homage frame as `YOU DIED`, shows final stats: kills, floors, gold, weapon bonus, total turns.

**Estimate**: 0.3 quartz-days. State is trivial; the new render path is a sibling of the existing `build_gameover_plane`.

**Bonus**: `world.turns: Int` counter — increments on every player action (move / attack / wait / open). Shown in the victory screen for "speed" runs.

### A.2 Death debris + hit flash animation

When a monster dies, spawn 4-6 short-lived particle Cells at the death position with random offsets and a `frame_to_die` field. They render as `*` `'` `,` glyphs in red, fading from `theme.base08` (red) → `theme.base09` (orange) → `theme.base02` (dim) over 6 ticks (~750ms). Adds proper "thwack" feedback to combat.

When the player or a monster takes damage, render a one-frame red overlay on their cell (CELL_ATTR_REVERSE plus a red `Channel.color`). Simple but visceral — Brogue does this and it's why combat feels good there.

**Architectural note**: Particle Cells live in a parallel-array `particle_xs / particle_ys / particle_glyphs / particle_die_frame` Vec set. Tick-driven cleanup: every tick, evict any whose `die_frame == w.frame`. Pattern matches the monsters / items design — same shape, same removal semantics.

**Estimate**: 0.5 quartz-days.

### A.3 Monster variety

Three monster archetypes with distinct stats:

- **`r` Rat** — HP 4, dmg 1, fast (acts every 2 ticks instead of 4). Glyph color `theme.base09` (orange).
- **`g` Goblin** — HP 8, dmg 3, normal speed. Glyph color `theme.base08` (red).
- **`o` Orc** — HP 14, dmg 4, slow (acts every 8 ticks). Bold. Glyph color `theme.base0E` (mauve).

Spawn distribution scales with floor depth: floor 1 = mostly rats; floor 5 = mix of all three with some orcs. Implementation: each monster carries a `kind: Int` field; lookup tables for HP / dmg / speed / glyph / color drive rendering and combat.

**Estimate**: 0.5 quartz-days. The combat + AI logic generalizes cleanly — `MONSTER_DMG()` becomes `monster_dmg(kind)`, etc.

### A.4 Boss rooms

Every Nth floor (probably 5), one of the rooms is generated larger and seeded with a single boss monster instead of the normal sprinkle. Boss stats: HP 30, dmg 5, normal speed. Special glyph `B` in mauve+bold. Dropping the boss is the victory condition for that floor (no stairs render until the boss is dead).

**Estimate**: 1 quartz-day. Requires room-tagging during BSP carve and conditional stairs gating.

### A.5 Polish odds and ends

- ~~Theme name back on the status bar (or in title — currently dropped). Maybe rotate display: HP/Atk/Gold on row 22, Floor/Theme/Torch/Lit on row 23, ditch the hint (move to overlay on `?` keypress).~~ **Shipped v0.12.** Status bar now two rows; theme name on row 23.
- ~~`?` key opens a help overlay listing all controls (`hjkl` + `>` + `T` + `F` + `+/-` + `q`).~~ **Shipped v0.12.** `build_help_plane` overlay; gates `world_tick` and `world_handle_key`; any-key dismisses.

#### A.5 stretch — per-floor minimap memory persistence (deferred)

Currently `world_init_floor` re-blanks the `visited` Bool vec on every descent — minimap memory dies with the floor. Make it persist across descents so the player can see floors they've explored.

Two implementation paths:

- **Per-floor `Vec<Vec<Bool>>` memory map**: `world.visited_by_floor: Vec<Vec<Bool>>` indexed by floor number minus 1. On descend: snapshot the current `visited` into `visited_by_floor[floor-1]`, then either restore from `visited_by_floor[next_floor-1]` if revisiting (not currently possible — descent is one-way) or fresh-blank for a new floor. The `Vec<Vec<Bool>>` allocation is tiny (5 floors × ~1700 bools).
- **Atlas overlay**: a new `?`-style overlay (e.g. on `m`) showing all visited floors as octant thumbnails arranged horizontally. Reuses `build_minimap_plane` per floor. Needs the `Vec<Vec<Bool>>` memory above.

Estimate: 0.3 quartz-days. Trivial state extension; the render path mirrors `build_minimap_plane`. Skipped in v0.12 because the descent path is one-way today and the value-add is low until a return-to-previous-floor mechanic exists.

---

## B. Framework follow-ups (stdlib-facing)

These are patterns that emerged during brogue-tribute development. Each one was implemented locally because the stdlib didn't have it; each one is generally useful enough to promote.

### B.1 World-builder pattern *(blocked on C.1; see below)*

The `World` struct in brogue-tribute grew to 30+ fields. Every state-transition function (`world_move`, `world_with_theme`, `world_open_door`, `world_pickup_item`, `world_step_monsters`) rebuilds the entire literal — typically 25-30 lines of `field: w.field,` boilerplate per function. `world_with` exists as a partial helper but it can't cover field combinations the helper signature doesn't anticipate.

Two paths forward:

- **B.1a — Stdlib helper**: a generic `record_with<S>(s: S, mutations: ...): S` taking some kind of record-update payload. Hard in Quartz today because the type system doesn't have a "row-polymorphic update" primitive — `mutations` would need to be a struct of `Option<T>` per field, which is more boilerplate than the current literal.

- **B.1b — Language feature** (recommended): struct update syntax. `World { ...w, hp: 5, gold: w.gold + 10 }` as a parser-level desugar to a full literal that copies missing fields from `w`. Equivalent to Rust's `..base`, OCaml's `{ r with ... }`, Elm's `{ r | ... }`. This is the fix.

If we ship B.1b in the compiler, every state-transition function in brogue-tribute shrinks from 25-line literal to 1-3 lines, and the friction disappears across the entire stdlib. Consumer impact: any module with a struct of N>10 fields that does immutable updates (the runtime's `Program`, the deckbuilder's `Game`, the resolver's `Resolver`, etc.).

**Estimate**: 1 quartz-day for the parser + desugar + typecheck. Filed in detail under section C below.

### B.2 Public `octant_pattern_at` + two-blitter idiom

Today's `mini_pattern_at` in `game/brogue-tribute/main.qz` is a local replica of `std/tui/octant.qz`'s file-private `_pattern_at`. Promote it to public: `octant_pattern_at(b: OctantBlitter, cx: Int, cy: Int): Int`.

Then add a stdlib helper for the per-cell-color minimap pattern:

```be
def octant_blit_layered(
  blitters: Vec<OctantBlitter>,
  layout_blitter_idx: Int,                  # which blitter's pattern drives the glyph
  fg_picker: Fn(Int, Int, Vec<Int>): Int,   # cx, cy, per-blitter patterns → fg color
  bg: cl::Channel,
  plane: pl::Plane,
  dst_x: Int, dst_y: Int,
  quality: oct::OctantQuality
): pl::Plane
```

`fg_picker` receives the patterns from each input blitter at this cell and returns the fg color to use. The minimap's "blue if any FOV-pixel, dim grey otherwise" logic becomes a one-liner picker. Player-cell override stays a plane_putc afterward.

**Estimate**: 0.5 quartz-days.

### B.3 BFS grid-walker → `std/algo/grid_bfs.qz`

`bfs_step` in brogue-tribute is a textbook BFS over a 2D walkable grid. Every roguelike, dungeon-crawler, or grid-puzzle game in this language will need it. Promote to stdlib:

```be
# Single-step BFS — return the direction (0=W, 1=E, 2=N, 3=S, -1=no path)
# from (sx, sy) to (tx, ty), with `is_blocked` predicating walkability.
def bfs_step(
  width: Int, height: Int,
  sx: Int, sy: Int, tx: Int, ty: Int,
  is_blocked: Fn(Int, Int): Bool
): Int

# Full path BFS — return the cell-by-cell path as Vec<(x, y)>.
def bfs_path(...): Vec<(Int, Int)>

# A* variant for weighted grids.
def astar_step(...): Int
```

**Estimate**: 0.5 quartz-days for BFS variants. A* is +0.5 day if/when needed.

### B.4 Raw runtime variant for non-TEA apps

The `std/tui/runtime.qz` `program_run` is TEA-shaped: `view: Fn(S): String`. brogue-tribute can't use it cleanly because we want the diff renderer's per-cell incremental output, not full-frame strings. The hand-rolled main loop replicates ~80 LOC of input-pump + tick-pump + scope cleanup that the runtime already implements.

Ship `program_run_raw` as a sibling of `program_run`:

- Sets up scope, raw mode, alt-screen, hides cursor.
- Spawns input-pump goroutine (sends `BMsg::Key` / `BMsg::Quit` on a user-supplied channel).
- Optionally spawns tick-pump goroutine (period configurable).
- Hands control back to the user — they own the main loop, the renderer, the world model.
- On exit (clean or panic), restores terminal state, cancels scope, ensures goroutines unwind.

The user supplies a callback signature like `Fn(msg_ch: Int, scope: Int): Int` — gets the channel + scope, returns when ready to tear down. brogue-tribute's main loop becomes:

```be
program_run_raw(tick_ms: 125) do msg_ch, scope ->
  var world = world_init()
  var renderer = rd::renderer_new(80, 24)
  ...main loop using recv(msg_ch)...
end
```

vs today's hand-rolled scaffold.

**Estimate**: 0.5 quartz-days. The hard work is already in `runtime.qz` — `program_run_raw` is mostly extraction.

### B.5 Particle / entity parallel-array helper

Every roguelike entity (monsters, items, particles, projectiles, ...) is a parallel-array Vec set in brogue-tribute today. The pattern is:

- `kind_ids: Vec<Int>` (which type)
- `xs / ys: Vec<Int>` (position)
- `data_<n>: Vec<Int>` (per-type bag of HP / value / damage / etc)
- `alive: Vec<Bool>` or hp == 0 sentinel

A stdlib helper `EntityArrays` could wrap the spawn / despawn / iterate / find-at-position primitives. Premature now; revisit after 2-3 more game projects use the same shape and the friction is calibrated.

**Estimate**: filed only. Don't build until pattern is calibrated across multiple consumers.

---

## C. Compiler + language lessons

These are gaps in the language itself surfaced by the session. Each one would have made every commit faster.

### C.1 Struct update syntax — *the big one* — **✅ SHIPPED 2026-05-07**

**Status**: shipped. Parser + typecheck-time desugar. `Struct { ...base, k: v }` expands so unprovided fields auto-copy from `base`. Multiple spreads rejected at parse time; unknown override fields rejected by the existing field-name validation. Spec coverage: `spec/qspec/struct_update_spec.qz` (9/9 green — clone, partial override, full override, generic struct, 12-field rebuild, multi-spread reject, unknown-field reject, Vec-typed field, nested struct spread). Runtime impact: zero (pure source-level rewrite to existing IR). Storage: parser stashes spread base in struct_init AST's `lefts` slot until typecheck desugar; cleared after expansion. Capture/liveness/resolver walkers updated to descend `lefts` for STRUCT_INIT before desugar runs.

```be
# Today (every World-modifying function):
return World {
  walls:        w.walls,
  player_x:     px,
  player_y:     py,
  stairs_x:     w.stairs_x,
  stairs_y:     w.stairs_y,
  brazier_xs:   w.brazier_xs,
  brazier_ys:   w.brazier_ys,
  ...28 more fields...
}

# Proposed:
return World { ...w, player_x: px, player_y: py }
```

Parser-level desugar: `Struct { ...base, key: val, ...}` expands to `Struct { key1: base.key1, key2: base.key2, ..., key: val, ...}` for every field of the struct's type, with explicit overrides taking precedence. Type checker enforces that `base` matches the constructor's struct type and that all fields are accounted for (either from base or override).

**Conventions to look at**: Rust's `..base`, OCaml's `{ r with ... }`, Elm's `{ r | ... }`, Haskell record-update syntax. The `..base` placement (Rust) reads cleanest in Quartz's existing brace-syntax style.

**Estimate**: 1-2 quartz-days. Parser change + desugar pass + typecheck integration. No runtime impact (pure source-level rewrite to existing IR).

**Acceptance**:
- Parses `Struct { ...base, k: v, ... }` and `Struct { ...base }` (no overrides — pure clone, useful for lifetime / handoff scenarios).
- Errors on `Struct { ...base, ...other }` (multiple spreads — ambiguous merge order).
- Errors on `Struct { ...base, k: v }` where `k` isn't a field of the struct.
- Auto-spreads correctly through any struct, generic or not.
- spec coverage: at least one large struct rebuild (the `Program` runtime struct?), the brogue-tribute `World`, and a small generic case.
- After landing: brogue-tribute `world_with` collapses from 25-line helper to 1-line `World { ...w, ...overrides }`. Same for every other state-transition function.

**Filing**: should be promoted to a `docs/bugs/` entry or directly to `docs/ROADMAP.md` Tier 0 (compiler features).

### C.2 `go` keyword leniency

Compiler rejects `var go = ...` because `go` is reserved (used for goroutine spawn). Burned us once this session — `var go = build_gameover_plane(t)` had to become `var gp = ...`.

Two options:

- **C.2a**: keep `go` reserved, error message becomes more helpful — "`go` is reserved as the goroutine spawn keyword; rename your local."
- **C.2b**: contextually un-reserve `go` when used as an identifier (var/param/field name) and reserve only at statement-position. The lexer already does this for some keywords; same rule for `go`.

**Recommendation**: C.2b. Other languages (Go, Rust) do this for soft keywords. Low-priority polish — single-char rename works around it.

**Estimate**: 0.2 quartz-days.

### C.3 Tuple destructuring on `Fn`-typed local returns

Per the `feedback_fn_typed_field_call_friction.md` memory: `var (a, b) = update_fn(x)` fails on Fn-typed-local returns; workaround is `pair.0 / pair.1`. Surfaced again this session in any function returning a tuple where the return is then destructured via Fn local. Persistent friction; fix eventually.

**Estimate**: filed only. Tracking the existing memory; promote when patterns-of-friction calibration warrants compiler work.

### C.4 (Shipped 2026-05-05, commit `910925ba`) Vec splice operation

Already in tree at `std/vec.qz:55-61` as `vec_remove_at<T>(src, idx): Vec<T>`. OOB-no-op (clamps `idx<0` and `idx>=size`); UFCS sugar `v.remove_at(i)` works automatically. Spec coverage at `spec/qspec/vec_immutable_helpers_spec.qz` (7 `vec_remove_at` it-blocks alongside sister helpers `vec_concat`, `vec_pop_n_from_end`).

Follow-up: brogue-tribute's `world_remove_item` (main.qz) hasn't been migrated to use the helper — clone-minus-one while loop still in place. Trivial cleanup; defer to whichever brogue-tribute touch-up commit lands next.

### C.5 Lessons that DIDN'T surface (worth saying)

These are language features I expected to fight and didn't:

- **Concurrency**: `go fn()` + `scope_with(scope_with_cancel(parent))` + `scope_send / scope_recv / scope_sleep_ms` — the entire async story worked the first time we tried in brogue-tribute. The runtime's pump-keys + tick-pump pattern transferred wholesale. Unification of Throws + scope cancellation + channel send semantics meant cleanup was always correct. **This is the most impressive part of the language right now.**
- **Effects**: `with Throws { throw: handler } do -> ... end` for absorbing scope-cancel throws. Just worked. No surprises.
- **First-class functions / lambdas**: `Fn(Int, Int): Bool` capture-passing for FOV blocker / lighting blocker / BFS-step picker callbacks. Every closure captured cleanly; no leaks; no reference confusion.
- **Generic Vec<T>**: parallel arrays of `Vec<Int>`, `Vec<Bool>` worked everywhere. No type-erasure friction this session.
- **String interpolation + StringBuilder**: combat log messages + status bar formatting via `sb_new()` + `.append()` was fast and clear.
- **Pattern matching + `is`**: `match msg { Quit => ... }` and `if x is Some` for enum dispatch were transparent.

What this means: the **80% of the language is ready for production use**. C.1 is the marginal improvement that would push the remaining friction off the cliff for record-heavy apps.

---

## D. SIGIL — runic deckbuilder showcase

> **The vision**: the deckbuilder + brogue-tribute fusion. A single demo that exercises every v0.6 feature simultaneously, in service of a polished playable game.

### D.1 Concept

A turn-based deckbuilder set in a brogue-tribute-style dark dungeon. The combat encounter shows:

- **Top region (rows 0-15)**: dungeon-style ambient — a small room rendered at brogue-tribute resolution, with the player `@` and 1-3 enemies. Animated brazier flicker. Dim memory tiles around the lit combat zone. Theme-aware.
- **Bottom region (rows 16-23)**: card hand + status. 5 cards rendered as 14×7 cell ASCII art panels, side-by-side, with a selection cursor.
- Each card has a **rune** rendered at sub-cell resolution via `OctantBlitter` — a unique sigil per spell type, ~6×6 pixels in the card's centre.
- The currently-selected card has a **dynamic glow effect**: a `light_buffer_paint` call positions a small magical light at the card's rune position, with a colour matching the spell's element (red for fire, blue for ice, green for poison, mauve for arcane). The glow pulsates via frame-driven sin or saw modulation.
- Idle cards (not selected) get a faint dim glow — barely present until you cycle to them. Hovering reveals the card.

### D.2 What this exercises

Every v0.6 feature:

- **Cell engine** — every card is a Plane composited onto a root.
- **Plane DAG** — the dungeon plane, the card-hand plane, the status plane all stack via `plane_blit`.
- **Blend modes** — the rune glow is `BlendMode::Add` or `BlendMode::Screen` over the card art.
- **Diff renderer** — only the active card's glow re-renders per frame; the rest of the screen is static. ~2KB diff/frame easily.
- **Light buffer** — magical glow on the runes; dungeon lighting in the combat scene.
- **FOV** — could be used as a "spotlight" effect on the active card (everything else dims).
- **Octants** — sub-cell rune rendering; possibly card border decoration too.
- **Tier-A on Tier-B** — card title text rendered as inline cells.
- **Themes** — the 11 bundled themes drive the entire palette; spell colours pick from the theme accents (`base08-base0F`).
- **Animation** — runes pulsate, brazier flickers, card-flip transitions when discarded.
- **Concurrency** — tick goroutine drives all the animation; input goroutine handles card selection / play.

This is the demo. This is what shows up on the language's landing page.

### D.3 Game design (rough)

Reuse the deckbuilder skeleton at `game/deckbuilder/main.qz`:

- **Player turn**: pick a card from the hand, play it, energy is consumed, effect resolves. Cards include attack, block, heal, AOE, status.
- **Enemy turn**: enemy follows a fixed pattern (telegraphed in their intent line above their sprite).
- **Multi-combat**: win → next encounter (next floor of dungeon, fresh card hand). Lose → game over.
- **Card progression**: pick 1 of 3 cards as a reward after each win (the deckbuilder v0.3 reward screen pattern).

Cards represented as a struct:

```be
struct Card
  name:        String
  cost:        Int
  damage:      Int
  block:       Int
  heal:        Int
  rune_pixels: Vec<Bool>     # 6×6 boolean grid for the rune sigil
  glow_color:  Int           # base0X palette index for the glow
end
```

### D.4 Implementation phases

- **D.4.1** — Static card rendering: 5 cards in a row at the bottom of the screen, ASCII art borders, card-name + cost + effect text. Selection cursor. ~1 quartz-day.
- **D.4.2** — Combat scene: small dungeon room above the card hand, player + 1 enemy, hp bars. Hook into existing combat math from deckbuilder. ~1 quartz-day.
- **D.4.3** — Rune rendering: octant blitter inside each card. Static patterns first (one rune per card type). ~0.5 quartz-days.
- **D.4.4** — Dynamic glow: `light_buffer_paint` over the active card's rune, colour-matched to the spell. Pulsate via frame-driven hash. ~0.5 quartz-days.
- **D.4.5** — Polish: card-flip discard animation, on-hit screen flash, deck/discard pile counters, victory/defeat overlays consistent with brogue-tribute's Dark-Souls homage. ~1 quartz-day.

**Total**: ~4 quartz-days. The demo of demos.

### D.5 Open questions

- Card art layout: 14×7 cells × 5 cards = 70 cell columns, fits in 80-wide. Tight but workable.
- Rune art: should runes be theme-customised (different rune shape per theme) or universal (same rune across all themes, only the glow color shifts)? Lean universal — keeps the feature minimal.
- Animation cadence: 8Hz tick like brogue-tribute, or higher (16Hz) for smoother glow modulation? Probably 8Hz; the human visual system smooths out at that cadence anyway.
- Soundtrack hook? — the language has audio intrinsics in the bareground roadmap; could play ambient pad + click sounds. Defer.

---

## Sequencing recommendation

Suggested order if working through this end-to-end:

1. **C.1 — struct update syntax** *(compiler)* — biggest leverage. Ships once, every other roadmap item gets faster. Should land first.
2. **A.1 + A.2 — kill counter + death debris** *(brogue-tribute)* — small, high-juice, makes the existing demo feel finished.
3. **B.4 — `program_run_raw`** *(framework)* — extract from runtime; makes future apps cleaner.
4. **A.3 — monster variety** *(brogue-tribute)* — replayability + visual variety.
5. **B.2 + B.3 — public octant helpers + BFS module** *(framework)* — stdlib promotes from brogue-tribute.
6. **D — SIGIL** *(showcase)* — once the framework lessons land, build the runic deckbuilder. This is the demo on the landing page.
7. **A.4 — boss rooms** *(brogue-tribute)* — final polish before declaring brogue-tribute "done."

Total estimated effort: ~10-12 quartz-days. With the project's calibration (Prime Directive 9), that's a ~3-4 calendar-week sprint. Single sessions can pick any thread above and run it independently — none of these block each other except C.1, which speeds everything up but isn't a hard dependency.

---

## Closing note

What this session demonstrated, beyond shipping ten commits: **Quartz is at the maturity where the compiler stays out of the way and the work is "what game / app / system do we want to build."** The async story, the cell engine, the lighting math, the FOV walker, the diff renderer, the theme system — every layer is solid enough to disappear when you're working above it.

That's what the next phase of language work needs to preserve. Don't ship features that demand fragility; ship features (like C.1) that compress the consumer-facing friction further. The hard work — the safety system, memory model, scheduler, scope discipline, FFI, type system — has paid off. Now the leverage is in the parts of the language that touch every consumer file: record syntax, error-message quality, stdlib idioms.

The brogue-tribute is the proof. SIGIL is the showcase. Both are what this language can do.
