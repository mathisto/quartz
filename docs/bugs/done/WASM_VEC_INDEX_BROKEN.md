# WASM backend: `Vec<Int>` indexed reads return internal header fields

**Status:** CLOSED 2026-04-19 by commit `447f06b1` + `0badc5e8`.
`MIR_INDEX` on WASM now walks `header[2]` for the data pointer; `_start`
calls `__qz_module_init` so module-level Vec globals get their data_ptr
populated before first use. `chip8_self_test` returns 67 (0x43) on the
live WASM; 16 ROMs play correctly in-browser at https://chip8.mattkelly.io/.

**Filed:** 2026-04-19, during Phase 3 of the CHIP-8 demo (`unikernel-site` branch).
**Severity:** Blocks any WASM program that reads Vec elements by index.
LLVM backend unaffected. Blocks the CHIP-8 emulator from running on WASM
in its current form (g_ram, g_v, g_stack, g_display, g_keys all `Vec<Int>`).

## Repro

```qz
var g_v = vec_new<Int>()

@export def probe_0(): Int
  g_v.push(10)
  g_v.push(99)
  return g_v[0]
end

@export def probe_1(): Int
  g_v.push(10)
  g_v.push(99)
  return g_v[1]
end

@export def probe_size(): Int
  g_v.push(10)
  g_v.push(99)
  return g_v.size
end

def main(): Int = 0
```

```bash
wasmtime --invoke probe_0    repro.wasm   # → 0    (expected 10)
wasmtime --invoke probe_1    repro.wasm   # → 2    (expected 99)  ← == size!
wasmtime --invoke probe_size repro.wasm   # → 2    (correct)
```

Adding a third push and reading `v[2]` returned `1024` — looks like a
data-buffer pointer or capacity, not the stored value.

## Hypothesis

Vec layout in the LLVM backend is something like
`struct { i64 data_ptr; i64 size; i64 capacity; }`. Indexed access
`g_v[i]` compiles to `load i64 (data_ptr + i*8)` on LLVM.

On WASM, it looks like the codegen is doing `load i64 (g_v + i*8)` —
reading straight off the Vec header *handle*, not through the data
pointer. That makes:

- `v[0]` → reads `data_ptr` (but returns 0 — possibly because
  `vec_new<Int>()`'s initial allocation is lazy / null)
- `v[1]` → reads `size` (2 when two pushes happened ✓)
- `v[2]` → reads `capacity` (or whatever's at offset 16)

So the bug is in `cg_intrinsic_collection.qz::cg_vec_index` (or its
WASM peer) — the pointer dereference is one level too shallow.

`.push()` probably goes through a proper `vec_push` intrinsic path
that respects the data pointer, so writes actually land in the backing
buffer. Just the *read* path is broken.

`.size` works because size IS at the header offset the codegen is
reading — the codegen is accidentally returning header fields for
every index.

## Impact on CHIP-8 demo

Every `g_ram[addr]`, `g_v[idx]`, `g_display[offset]` read returns garbage
(actually: Vec header fields) on WASM. The emulator instantiates, but
every `chip8_step` reads 0 for its opcode, falls into nibble==0 dispatch
with op==0, and does nothing visible.

Phase 3 (compile + wasmtime drive) therefore PROVES the @export wiring is
correct — all 15 entry points show up in `wasm-objdump`, instantiation
succeeds, zero-arg entries like `chip8_init` return 0 as expected — but
can't progress to "the emulator steps through a ROM" until Vec indexing
is fixed.

Phase 3 LLVM harness is unaffected: `examples/chip8/test_chip8.qz` still
passes 40/40 under `self-hosted/bin/quartz` + `llc` + `clang`.

## Workaround options (for the demo specifically, in rough order of
effort)

1. **Fix the backend bug.** Codegen change in `cg_vec_index` for the
   WASM path so indexed loads go through the data pointer. Estimated
   modest (< 50 LoC) once the exact slot is identified. Preferred.

2. **Swap Vec for raw intrinsic memory.** Replace `g_ram = vec_new<Int>()`
   with a raw `g_ram_ptr = alloc(4096)` + `load(g_ram_ptr, offset)` /
   `store(g_ram_ptr, offset, val)`. Works on both backends, but
   forfeits the ergonomic Vec API and duplicates accessor logic.

3. **Build a `Bytes` type with explicit pointer discipline.** Longer
   term, worth it independently. Out of scope for the demo.

(1) is the cleanest. Probably 0.5–1 quartz-hour, Rule-1 backup + guard
discipline applied.

## Also blocking on the same path

`docs/bugs/WASM_VOID_CALL_STACK_MISMATCH.md` — user `Void` functions
produce invalid WASM when called. Workaround (return Int 0) already
applied to `examples/chip8/chip8.qz`. These two bugs probably share a
cause (the same "callee returns something for the caller to consume"
assumption that's too aggressive for Void + too aggressive for indexed
Vec reads).

## Validation target

A green `wasmtime --invoke chip8_self_test /tmp/chip8.wasm` returning
`0x43` (67) on a build of the unmodified emulator.
