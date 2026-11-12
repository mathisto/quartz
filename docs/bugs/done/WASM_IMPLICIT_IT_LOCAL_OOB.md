# WASM backend: `.each() { it }` / `.filter() { it }` on Vec emits invalid WASM

**First seen:** Apr 19, 2026, updating playground demos to the
idiomatic implicit-`it` form prescribed by STYLE.md's cheat sheet.

## Symptom

Any trailing-block call on a `Vec<T>` that uses implicit `it`
compiles to bytes, but `wasmtime` rejects the module at
instantiation/compile with "unknown local N: local index out of
bounds".

Minimal repro:

```qz
def main(): Int
  scores = [95, 87, 92, 78, 100]
  scores.each() { puts("  #{it}") }
  return 0
end
```

Produces a 1600-byte `.wasm` file. `wasmtime` rejects it:

```
Error: failed to compile: wasm[0]::function[4]
  Caused by:
    WebAssembly translation error
    Invalid input WebAssembly code at offset 396:
      unknown local 13: local index out of bounds
```

Same failure with `.filter() { it >= 90 }`, `.map() { it * 2 }`.
The LLVM and C backends handle these correctly — only WASM is
affected.

## What works and what doesn't

| Form | Works on WASM? |
|---|---|
| `for s in scores` / `for x in items`             | ✅ |
| `scores.size()`, `scores.get(i)`                 | ✅ |
| `.sum()` / `.fold()` / `.reduce()` on Vec        | ❌ (emits extern import to undefined `env::sum` etc.) |
| `.each() { it ... }` on Vec                      | ❌ (local-OOB) |
| `.filter() { it ... }` on Vec                    | ❌ (local-OOB) |
| `.map() { it ... }` on Vec                       | ❌ (local-OOB) |
| `.each() { x -> ... }` with explicit param on Vec | untested (likely same bug) |
| Closures declared and invoked manually (see `closures` demo) | ✅ |

So the WASM bug is scoped to **`Vec<T>` higher-order methods that
take a trailing block.** Non-Vec closures work. `for` loops work.
Explicit-index iteration works. `sum`/`fold`/`reduce` are missing
from the WASM runtime entirely (separate issue — see below).

## Likely cause

The trailing-block expansion for `.each() { it ... }` on Vec
generates MIR that references a local by slot number that the
WASM function-header's local count doesn't cover. `local N` where
N is beyond the declared locals in the function's entry preamble.

Cross-check against `codegen.qz` (LLVM) — it must be lowering the
same MIR to register slots correctly. The WASM lowering in
`codegen_wasm.qz` likely has a stale local-count that doesn't get
bumped when the trailing block introduces new slots.

## Related: missing Vec reductions in the WASM runtime

`.sum()` on `Vec<Int>` on WASM emits a call to a symbol
`env::sum` that the WASM runtime never defines. Same for `.fold`,
`.reduce`, possibly more. These need to be added to
`wasm_runtime.qz` (which is already 300 KiB, so there's
established room).

This is separate from the local-OOB bug above but shares a root
cause: the WASM backend is behind on Vec-method support.

## Workaround (used in `collections.qz` demo)

Rewrite idiomatic Vec-method chains as `for` loops with
accumulators:

```qz
# Idiomatic but breaks on WASM:
total = scores.sum()
scores.each() { puts("  #{it}") }

# WASM-safe and still reasonable Quartz:
var total = 0
for s in scores
  total += s
end
for s in scores
  puts("  #{s}")
end
```

The user-facing cost: the playground's `collections.qz` demo
can't show off `.each() { it }` / `.filter() { it }` / `.map() { it }`
— the very idioms the STYLE.md cheat sheet now prescribes. Once
this bug is fixed, the demo should be rewritten to match the
prescribed idiom.

## Repro

```bash
cat > /tmp/wasm-repro.qz <<'EOF'
def main(): Int
  v = [1, 2, 3]
  v.each() { puts("#{it}") }
  return 0
end
EOF

# LLVM backend (works):
./self-hosted/bin/quartz /tmp/wasm-repro.qz | llc -filetype=obj -o /tmp/r.o
clang /tmp/r.o -o /tmp/r -lm -lpthread && /tmp/r

# WASM backend (broken, requires --feature wasm compiler):
/tmp/quartz_wasm --backend wasm /tmp/wasm-repro.qz -o /tmp/r.wasm
wasmtime /tmp/r.wasm
# → Invalid input WebAssembly code ... unknown local N: local index out of bounds
```

## Fix location (best guess)

`self-hosted/backend/codegen_wasm.qz` — the local-declaration
emitter for functions that contain trailing-block expansions.
Cross-reference `mir_lower_iter.qz` for how Vec-iteration blocks
get lowered to MIR locals, then confirm `codegen_wasm.qz` reads
the same local count.

Separately, `wasm_runtime.qz` needs `.sum`, `.fold`, `.reduce`,
and probably other Vec reductions added.

## Priority

P1 for the playground — every modern Quartz demo hits this the
moment it reaches for `.filter` / `.map` / `.each`, which the
cheat sheet now says is the default form. Ranked P1 instead of
P0 only because the `for` loop workaround preserves the demos
and the cheat sheet's other idioms.
