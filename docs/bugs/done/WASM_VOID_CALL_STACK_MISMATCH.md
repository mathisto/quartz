# WASM backend: calling user `Void` functions produces invalid WASM

**Filed:** 2026-04-19, during Phase 3 of the CHIP-8 demo (`unikernel-site` branch).
**Severity:** Blocks any WASM program that calls user-defined `Void`-returning
functions. LLVM backend unaffected.

## Repro

Any program where one user function with `: Void` return type is called
from another function (Int or Void) triggers this. No Vec / while / closure
needed — the failure is in the call-site code generation for a void callee.

```qz
var g_counter = 0

def _inc(): Void
  g_counter = g_counter + 1
end

def main(): Int
  _inc()
  return g_counter
end
```

```bash
/tmp/wasm-build/quartz_wasm --backend wasm --no-cache /tmp/repro.qz -o /tmp/repro.wasm
wasmtime /tmp/repro.wasm
#   WebAssembly translation error
#   Invalid input WebAssembly code at offset 218:
#       type mismatch: expected i64 but nothing on stack
```

## Workaround

Change `: Void` to `: Int` and `return 0`. End-to-end behavior is
identical; only the function signature changes. Callers that ignored the
return value still ignore it.

```qz
def _inc(): Int
  g_counter = g_counter + 1
  return 0
end
```

Works on both LLVM and WASM backends.

## Root cause (hypothesis)

`codegen_wasm.qz::_wasm_emit_instr` for `MIR_CALL` likely always emits
code assuming the callee returns one i64, pushing a placeholder onto the
stack for the caller to consume. When the callee's WASM signature is
`() -> ()` (no result, which is how Void functions lower — see
`_wasm_mark_void_func` at codegen_wasm.qz:1756), the callee's return
doesn't push, and the next instruction in the caller expects an i64 it
never got.

Likely fix: in the `MIR_CALL` codegen path, look up the callee's
void-ness via `wasm_runtime::_wasm_is_void_func(name)` and suppress the
result-consumer instructions (or emit an `i64.const 0` placeholder) when
the callee returns void.

The same handler works on LLVM because LLVM `void` calls don't produce
a value, and the caller's IR simply doesn't reference one — LLVM type
system enforces this at the IR level. WASM has a looser type discipline
and the validator catches the imbalance later.

## Impact on CHIP-8 demo

Forced a local workaround: every `def _xxx(): Void` helper in
`examples/chip8/chip8.qz` was rewritten to `def _xxx(): Int` with
`return 0` at the tail. 11 helpers touched. No behavior change.

Once this is fixed in the compiler, the workaround can be reverted or
the decision left as-is (Int-returning helpers are harmless).

## Validation target

A green `wasmtime --invoke chip8_init /tmp/chip8.wasm` on a build of
`examples/chip8/chip8.qz` with Void helpers restored.

Spec: `spec/qspec/wasm_void_call_spec.qz` should be added once the
compiler fix lands — a 3-test spec asserting Void↔Int, Void↔Void, and
Int↔Void call edges all produce valid WASM that wasmtime can
instantiate.
