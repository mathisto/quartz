# CHIP-8 emulator in Quartz → WASM → browser (design + plan)

> **Status:** Spec, Apr 19 2026. No code yet.
> **Branch when implementation starts:** clean fork from `unikernel-site` at `f9a76123`.
> **Companion handoff:** `docs/handoff/next-session-chip8-wasm.md`.

---

## What we're building

A CHIP-8 emulator, written in Quartz, compiled to WebAssembly,
embedded in a page on the Quartz unikernel site. User picks a ROM
from a dropdown (or uploads one), hits Run, and plays PONG / BRIX /
TETRIS in the browser. Every byte of emulation is running Quartz
code produced by our WASM backend. The unikernel serves the ROM
file and the `.wasm` over its own self-hosted TCP stack.

This is a flex demo, not infrastructure. Ship it, use it to pull
visitors into the playground and docs.

## Why CHIP-8

- **Small surface.** 35 opcodes, 4 KiB RAM, 64×32 display,
  16-key keypad. Real (bounded) problem with real constraints,
  not a toy.
- **Exercises what we already have.** Integer arithmetic, bit
  operations, pointer/index manipulation, arrays — all the WASM
  backend can handle today. Doesn't hit the known `.each() { it }`
  bug because the emulator is `for`-loop + indexed-access code.
- **Plays games.** End-state is clickable; visitor gets a visceral
  "this was compiled by a language I've never heard of" moment
  that no amount of technical prose beats.
- **Public-domain ROMs available.** Dozens of free CHIP-8 games
  (PONG, INVADERS, BRIX, TETRIS, MERLIN, BLITZ, TANK, etc.), all
  distributable.

## Non-goals

- Not SUPER-CHIP (128×64 extended). Base CHIP-8 only. Can add
  later if the demo gets traction.
- Not accurate cycle-exact timing. 60 Hz display + ~500 Hz CPU is
  fine for games; pixel-exact timing isn't the point.
- Not assembler / disassembler. We load ROMs, we don't edit them.
- Not integrated with `/api/compile`. The emulator is precompiled
  and baked into the unikernel ELF like the existing demos.
- Not audio-perfect. Square-wave beep when sound timer > 0 is
  enough; don't build a synth.

---

## Architecture — shared-memory export model

The design hinges on one compiler dependency: the WASM backend
needs to emit **named function exports beyond `_start`**, plus
continue to export `memory`. Today it only emits two exports
(`_start` + `memory`). A small compiler change (~50 LOC) adds
`@export` attribute support. See §7.

Once that's in place, the emulator exposes a narrow API surface
to JS:

```
// Quartz side — marked with @export, appear as instance.exports.X
@export def chip8_init(): Int
@export def chip8_load_rom(len: Int): Int
@export def chip8_reset(): Int
@export def chip8_step_frame(): Int       // run ~10 instructions
@export def chip8_tick_timers(): Int       // 60 Hz countdown
@export def chip8_ram_addr(): Int          // returns &g_ram[0]
@export def chip8_display_addr(): Int      // returns &g_display[0]
@export def chip8_keys_addr(): Int         // returns &g_keys[0]
@export def chip8_sound_playing(): Int     // 1 if sound timer > 0
```

JS drives the loop via `requestAnimationFrame`:

```js
const wasm = await WebAssembly.instantiate(bytes, imports);
const exp  = wasm.instance.exports;
const mem  = new Uint8Array(exp.memory.buffer);

exp.chip8_init();
const romView = new Uint8Array(mem.buffer, Number(exp.chip8_ram_addr()) + 0x200);
romView.set(romBytes);
exp.chip8_load_rom(BigInt(romBytes.length));

const displayView = new Uint8Array(mem.buffer, Number(exp.chip8_display_addr()), 64 * 32);
const keysView    = new Uint8Array(mem.buffer, Number(exp.chip8_keys_addr()), 16);

function frame() {
  exp.chip8_step_frame();   // ~10 insns
  exp.chip8_tick_timers();  // 60 Hz
  renderToCanvas(displayView);
  if (exp.chip8_sound_playing()) beep();
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

window.addEventListener('keydown', e => { keysView[keyMap[e.key]] = 1; });
window.addEventListener('keyup',   e => { keysView[keyMap[e.key]] = 0; });
```

No custom imports needed — pure memory-sharing. The WASI shim the
playground already ships (`proc_exit`, `fd_write` for `puts`)
is enough.

---

## 1. Emulator state

One big `@value` struct or 7-8 globals. Globals are simpler for
the WASM backend (no struct-field-in-memory marshalling), so plan
on globals for V1.

```qz
var g_ram:     [u8; 4096]   = [0; 4096]      # 4 KiB
var g_v:       [u8; 16]     = [0; 16]        # V0-VF
var g_i:       u16          = 0              # index register
var g_pc:      u16          = 0x200          # program counter
var g_stack:   [u16; 16]    = [0; 16]
var g_sp:      u8           = 0              # stack pointer
var g_display: [u8; 2048]   = [0; 2048]      # 64*32, 0 or 1 per pixel
var g_keys:    [u8; 16]     = [0; 16]        # 0 or 1 per key
var g_delay:   u8           = 0              # delay timer
var g_sound:   u8           = 0              # sound timer
var g_wait_key: i8          = -1             # Fx0A blocking state
```

Fixed-size arrays mean no heap allocation in the hot path — they
become `.bss` globals in WASM linear memory, directly
pointer-addressable by JS. (Verify `[u8; N]` syntax exists; if
Quartz doesn't currently support stack-allocated fixed arrays at
global scope, use `g_ram = pmm_alloc_bytes(4096)`-equivalent or
just have the init function populate them.)

## 2. The font

CHIP-8 programs expect a built-in font (hex digits 0-F as 4x5
pixel sprites) at memory address 0x000. Bake the 80-byte font
table into `chip8_init()`:

```qz
def chip8_init(): Int
  # Standard CHIP-8 font — 16 glyphs * 5 bytes each
  font_data = [
    0xF0, 0x90, 0x90, 0x90, 0xF0,   # 0
    0x20, 0x60, 0x20, 0x20, 0x70,   # 1
    # ... 14 more ...
  ]
  for i in 0..80
    g_ram[i] = font_data[i]
  end
  g_pc = 0x200
  g_sp = 0
  g_i  = 0
  return 0
end
```

## 3. Instruction decode

CHIP-8 instructions are 16 bits, big-endian. Decode pattern:

```qz
def chip8_step(): Int
  op   = (g_ram[g_pc] << 8) | g_ram[g_pc + 1]
  g_pc = g_pc + 2

  nibble = (op >> 12) & 0xF
  x      = (op >> 8)  & 0xF       # Vx index
  y      = (op >> 4)  & 0xF       # Vy index
  n      = op & 0xF
  kk     = op & 0xFF              # 8-bit immediate
  nnn    = op & 0xFFF             # 12-bit address

  match nibble
    0x0 => match op
      0x00E0 => display_clear()
      0x00EE => ret_from_subroutine()
      _ => panic("SYS addr not supported")
    end
    0x1 => g_pc = nnn                          # JP  nnn
    0x2 => call_subroutine(nnn)                # CALL nnn
    0x3 => skip_if(g_v[x] == kk)               # SE  Vx, kk
    0x4 => skip_if(g_v[x] != kk)               # SNE Vx, kk
    0x5 => skip_if(g_v[x] == g_v[y])           # SE  Vx, Vy
    0x6 => g_v[x] = kk                         # LD  Vx, kk
    0x7 => g_v[x] = (g_v[x] + kk) & 0xFF       # ADD Vx, kk  (no carry set)
    0x8 => arith_op(x, y, n)                   # 8xy0..8xyE
    0x9 => skip_if(g_v[x] != g_v[y])           # SNE Vx, Vy
    0xA => g_i = nnn                           # LD  I, nnn
    0xB => g_pc = nnn + g_v[0]                 # JP  V0, nnn
    0xC => g_v[x] = rand_byte() & kk           # RND Vx, kk
    0xD => draw_sprite(g_v[x], g_v[y], n)      # DRW
    0xE => match kk
      0x9E => skip_if(g_keys[g_v[x]] == 1)
      0xA1 => skip_if(g_keys[g_v[x]] == 0)
    end
    0xF => f_op(x, kk)                         # Fx07..Fx65
  end
  return 0
end
```

Each sub-group (`arith_op`, `f_op`, `draw_sprite`, etc.) is a
small helper function. `rand_byte()` maps to a PRNG (linear
congruential is fine — CHIP-8 doesn't need cryptographic random).

The `0xD` (draw sprite) op is the biggest single piece because
it has to XOR pixels into the display buffer and set VF on
collision. It's about 25 lines.

## 4. Step-frame vs step-one

JS calls `chip8_step_frame()` once per `requestAnimationFrame`
tick (roughly 60 Hz). That function runs N instructions before
returning, where N is tuned so the emulator runs at the
"authentic" 500-700 Hz:

```qz
const CYCLES_PER_FRAME = 10

def chip8_step_frame(): Int
  var i = 0
  while i < CYCLES_PER_FRAME
    chip8_step()
    i = i + 1
    # Some opcodes (Fx0A — wait for key) block the whole frame
    if g_wait_key >= 0
      break
    end
  end
  return 0
end
```

`chip8_tick_timers()` is called once per frame too — decrements
`g_delay` and `g_sound` if > 0. Simple.

## 5. Display

The display buffer is 64 × 32 = 2048 bytes, one byte per pixel
(0 or 1). Draw sprite opcode (`Dxyn`) reads `n` bytes starting at
memory[I], XORs each bit into the display at (Vx, Vy), wraps at
screen edges, and sets VF to 1 if any pixel was erased.

JS renders the buffer to a `<canvas>` element each frame:

```js
function renderToCanvas(buf) {
  const img = ctx.createImageData(64, 32);
  for (let i = 0; i < 2048; i++) {
    const c = buf[i] ? 255 : 0;
    img.data[i * 4 + 0] = c;
    img.data[i * 4 + 1] = c;
    img.data[i * 4 + 2] = c;
    img.data[i * 4 + 3] = 255;
  }
  ctx.putImageData(img, 0, 0);
  // Canvas CSS scales 64×32 up to 640×320 via `image-rendering: pixelated`
}
```

Total per-frame cost: one 2-KiB read from WASM memory + one
ImageData write. Trivial.

## 6. Keypad

CHIP-8 has 16 keys arranged:

```
1 2 3 C
4 5 6 D
7 8 9 E
A 0 B F
```

Map to keyboard as the standard COSMAC VIP layout:

```
1 2 3 4      ->  1 2 3 C
Q W E R      ->  4 5 6 D
A S D F      ->  7 8 9 E
Z X C V      ->  A 0 B F
```

JS writes 0 or 1 into `keysView[i]` on keyup/keydown. The WASM
side reads `g_keys[x]` directly via the shared memory.

The one subtle case: `Fx0A` "wait for key press." The emulator
has to *block* until a key is pressed, then store the key index
in Vx. Handle via a `g_wait_key` flag that makes
`chip8_step_frame` return early (§4) until JS presses something:

```qz
# In f_op for Fx0A:
var pressed = -1
for i in 0..16
  if g_keys[i] == 1
    pressed = i
    break
  end
end
if pressed >= 0
  g_v[x] = pressed
  g_wait_key = -1
else
  g_wait_key = x    # block next frame on this Vx
  g_pc = g_pc - 2   # rewind so we re-execute this op next frame
end
```

## 7. Compiler dependency — `@export` attribute

**This is the only compiler change required.** Everything else
is pure Quartz-in-the-current-backend.

Current state: `codegen_wasm.qz` hardcodes two exports (§`_wasm_build_export_section`).

Proposed: add `@export` attribute to the parser's attribute
dispatch (sibling of `@weak`, `@panic_handler`). Collect all
`@export`-tagged functions during resolve. Extend
`_wasm_build_export_section` to walk that list and emit one
WASM export per entry.

Small, contained change. Estimate 30–50 LOC + a spec
(`spec/qspec/wasm_export_attr_spec.qz`). Fixpoint must hold.

Spec idea:

```qz
@export def answer(): Int = 42
@export def greet(n: Int): Int = n + 1
def main(): Int = 0

# After compile with --backend wasm:
#   wasm-objdump should show 4 exports: memory, _start, answer, greet
```

## 8. ROM loader

Two delivery paths, both in scope:

### 8a. Pre-baked ROMs

Bake 4-6 public-domain ROMs into the unikernel under
`/chip8/roms/<name>.ch8`. Reuse the existing
`tools/bake_assets.qz` pipeline — `.ch8` files get MIME
`application/octet-stream`.

Curated starter set:
- `PONG.ch8` (classic)
- `BRIX.ch8` (breakout)
- `INVADERS.ch8` (obvious)
- `TETRIS.ch8` (probably the flashiest)
- `MERLIN.ch8` (simon-says, short + colorful)
- `MAZE.ch8` (smallest known — good "did it load at all" test)

Source: https://github.com/kripod/chip8-roms (MIT-licensed
collection) — copy a handful into `site/public/chip8/roms/` and
the bake pipeline picks them up automatically.

### 8b. User upload

`<input type="file" accept=".ch8,.c8">` on the page. JS reads the
bytes with FileReader, writes them into WASM memory at
`ram_addr + 0x200`, calls `chip8_load_rom(len)`. One ~15-line
handler.

## 9. Page integration

New Astro page: `site/src/pages/chip8.astro`. Layout:

- Top: title + short "what is this" paragraph + link back to
  playground.
- Main: 640×320 canvas (10× scale of 64×32).
- Below canvas: ROM picker dropdown (lists pre-baked ROMs) +
  file input for uploads + Run / Pause / Reset buttons.
- Below controls: keypad diagram showing the keyboard-to-CHIP-8
  mapping.
- Inline JS handles load, WASM instantiate, animation loop,
  input, audio.

Link from the existing playground page ("Want more? Play CHIP-8
in the same WASM backend →"), and from the main landing
(add to the telemetry-block links).

## 10. Audio

CHIP-8 has a single sound output: "buzz while sound timer > 0."
Simplest implementation: Web Audio square-wave oscillator, toggle
on/off based on `exp.chip8_sound_playing()` return.

```js
const audioCtx = new AudioContext();
let osc = null;
function beepOn()  { if (osc) return; osc = audioCtx.createOscillator(); osc.frequency.value = 440; osc.connect(audioCtx.destination); osc.start(); }
function beepOff() { if (!osc) return; osc.stop(); osc.disconnect(); osc = null; }
// in frame():
if (exp.chip8_sound_playing())  beepOn();
else                            beepOff();
```

20 lines of JS. Done.

---

## 11. File plan

```
self-hosted/
  # No changes to compiler SOURCE except...
  backend/
    codegen_wasm.qz          # +40 LOC: @export attr handling
  frontend/
    parser.qz                # +5 LOC: register "export" attribute name

spec/qspec/
  wasm_export_attr_spec.qz   # new — verifies @export shows up in wasm binary

examples/chip8/
  chip8.qz                   # the emulator — ~400 LOC
  test_chip8.qz              # native LLVM-backend harness for emulator correctness

site/
  public/chip8/roms/         # pre-baked ROM files
    PONG.ch8
    BRIX.ch8
    INVADERS.ch8
    TETRIS.ch8
    MERLIN.ch8
    MAZE.ch8
  src/pages/chip8.astro      # the page — canvas + JS loop + ROM picker

tools/bake_assets.qz         # +3 LOC: .ch8 MIME type (application/octet-stream)

docs/
  CHIP8_WASM_DEMO.md         # this file (ship it with the spec, keep current)
  handoff/
    next-session-chip8-wasm.md   # ← the actual handoff that drives implementation
```

---

## 12. Phased plan

Five phases, each ideally one quartz-hour-ish. Single PR per
phase into `unikernel-site`.

### Phase 1 — Compiler: `@export` attribute

Add the attribute, wire it through the parser + resolver, have
codegen_wasm emit all tagged functions. `quake guard` + smoke
tests. Cherry-pickable onto trunk separately.

**Blocking for:** all subsequent phases.
**Estimate:** 0.5 quartz-hours.

### Phase 2 — Emulator core (LLVM-backend first)

Write `examples/chip8/chip8.qz` with all the emulation logic.
Test via the LLVM backend (run against a known ROM, assert the
first N instructions produce the expected CPU state). Don't
worry about WASM yet.

**Why LLVM first:** fast iteration (<1s rebuild + test) vs WASM
(~60s to rebuild the compiler + compile + run wasmtime). Catch
logic bugs before they get obscured by WASM-specific bugs.

**Blocking for:** Phase 3.
**Estimate:** 2–3 quartz-hours (includes the fiddly ops:
draw_sprite collision, BCD, stack ops).

### Phase 3 — WASM adaptation

Add `@export` annotations to the public entry points. Compile
with `--backend wasm`. Run in `wasmtime` via a tiny JS-like
harness that calls the exports by name and reads memory. Verify
a ROM produces the expected display output after N frames.

**Surfaces that can go wrong here:**
- WASM local-OOB on trailing blocks (filed, not fixed) — but
  the emulator is all `for` / indexed access, should dodge it.
- `#{string_var}` pointer bug — emulator doesn't print strings,
  dodge.
- Missing runtime fns (`.sum`, `.fold`) — emulator only uses
  `.size`, `.get`, `.set` on bytes.

**Blocking for:** Phase 4.
**Estimate:** 1–2 quartz-hours.

### Phase 4 — Browser integration

Build `site/src/pages/chip8.astro` with canvas + ROM picker +
keyboard mapper + audio. Test locally with a pre-baked ROM
served from the Astro dev server. Get PONG playing end-to-end.

**Blocking for:** Phase 5.
**Estimate:** 1–2 quartz-hours. JS, not Quartz.

### Phase 5 — Bake + deploy

Download 6 public-domain ROMs into `site/public/chip8/roms/`.
Bake into unikernel. Build ELF. scp + restart. Smoke-test over
HTTPS — each ROM loads and runs.

Link from the landing page and playground.

**Estimate:** 0.5 quartz-hours.

**Total: ~5–8 quartz-hours spanning 3–5 context sessions.**

---

## 13. Open questions (resolve at Phase 1 start)

1. **Fixed-size array globals.** Does `var g_ram: [u8; 4096] = [0; 4096]` compile on both LLVM and WASM backends? If not, plan B is `g_ram = pmm_alloc_bytes(4096)` at init + never free. Check in the Phase 2 kickoff; answer changes a few dozen lines.

2. **Little-endian vs big-endian shifts.** CHIP-8 instructions are big-endian (`op = ram[pc] << 8 | ram[pc+1]`). Just use explicit shifts — works on any architecture. No endianness assumptions in the emulator.

3. **Canvas scaling via CSS or manual.** CSS `image-rendering: pixelated` + transform works in all modern browsers. Manual pixel replication in the ImageData loop is an alternative but wastes CPU. Start with CSS.

4. **Instructions-per-frame tuning.** CHIP-8 games assume ~500 Hz CPU; at 60 fps that's ~8–10 insns/frame. Some games (blocky ones like TETRIS) need more (15–20). Make it a slider in the UI or hardcode 10 and see what feels right.

5. **`@export` name mangling.** Will the Quartz function name `chip8_step_frame` appear as `chip8_step_frame` in the WASM export table, or does codegen add a `$`-prefix / module path? Check by producing a minimal test case at Phase 1 end and inspecting with `wasm-objdump`.

6. **WASI imports when there's no `puts`.** If the emulator doesn't call `puts`, does the backend still emit the `fd_write` / `proc_exit` imports? If yes, we can stub them in JS (already done for playground). If no, even simpler JS-side.

---

## 14. Rough JS/HTML size budget

- Page HTML: ~100 lines
- Inline CSS (dark theme matching site): ~50 lines
- Inline JS (load+loop+input+audio): ~150 lines

Total page ~300 lines Astro/HTML. Under the TX ceiling the
unikernel can serve in one shot.

## 15. Beyond V1 (punt list)

- SUPER-CHIP / XO-CHIP extended instructions (128×64 display,
  more colors).
- Save-state / load-state.
- "Step instruction" debugger UI showing registers + disassembly.
- Record gameplay to GIF.
- Multiplayer via WebRTC (link two browsers playing PONG head-to-head).
- Mobile touch controls.

None of these block the V1 ship. File as issues when the demo
goes live.
