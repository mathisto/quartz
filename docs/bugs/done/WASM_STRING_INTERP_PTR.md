# WASM backend: String-typed `#{expr}` emits the pointer, not the text

**First seen:** Apr 19, 2026 during the playground-WASM sprint that
baked seven pre-compiled demos into the unikernel.

## Symptom

Compile this Quartz source with `--backend wasm` and run it:

```qz
def main(): Int
  var name = "Quartz"
  puts("Hello, #{name}!")
  return 0
end
```

Expected output:

```
Hello, Quartz!
```

Actual output (wasmtime ≥ 20):

```
Hello, 1032!
```

The integer printed in place of the string is the heap address of
the interned `"Quartz"` bytes in the WASM module's linear memory.

## What works and what doesn't

Integer interpolation is fine. The bug is specifically `#{expr}` where
`expr` has type `String`:

| Expression | Works on WASM? |
|---|---|
| `puts("total = #{n}")` (n: Int)    | ✅ |
| `puts("p = (#{p.x}, #{p.y})")`     | ✅ (Int fields) |
| `puts("fib(#{i}) = #{fib(i)}")`    | ✅ |
| `puts("Hello, #{name}!")` (name: String) | ❌ prints pointer |
| `puts("got #{some_string()}")`     | ❌ prints pointer |

LLVM and C backends handle the String case correctly; only WASM is
affected.

## Likely cause

The interpolation desugar rewrites `"Hello, #{name}!"` into
`"Hello, " + to_s(name) + "!"`. For Int, `to_s` emits the digit
conversion we see working. For String, `to_s` should pass the string
through as-is (`impl ToStr for String => self`).

The WASM backend appears to either:
  * skip the `to_s` call entirely on String operands (treats the
    pointer as if it were an already-formatted Int), or
  * call `to_s<Int>` instead of `to_s<String>` because the generic
    dispatch on String falls through to the catch-all that formats
    the raw 64-bit value.

Needs a look at `codegen_wasm.qz`'s interpolation lowering path and
the `to_s` overload resolution in the WASM-specific desugar.

## Workaround (used in /playground demos)

For the WASM playground demos, concatenate manually with `+` or
split into multiple `puts()` calls:

```qz
# instead of:  puts("Hello, #{name}!")
puts("Hello, " + name + "!")

# or:
puts("Hello, Quartz!")   # if the value is a literal anyway
```

## Repro

```bash
cat > /tmp/repro.qz <<'EOF'
def main(): Int
  var name = "Quartz"
  puts("Hello, #{name}!")
  return 0
end
EOF

# Working LLVM backend:
./self-hosted/bin/quartz /tmp/repro.qz | llc -filetype=obj -o /tmp/r.o
clang /tmp/r.o -o /tmp/r -lm -lpthread && /tmp/r
# → Hello, Quartz!

# Broken WASM backend (requires compiler built with --feature wasm):
/tmp/quartz_wasm --backend wasm /tmp/repro.qz -o /tmp/r.wasm
wasmtime /tmp/r.wasm
# → Hello, 1032!  (or some other small integer — the pointer value)
```

## Fix location (best guess)

`self-hosted/backend/codegen_wasm.qz` interpolation lowering.
Cross-check against `codegen.qz` (LLVM backend) which handles the
same path correctly — the divergence is where the fix lives.

## Priority

P2. The demos-in-browser path works around it by not interpolating
String variables. Correctness fix should land before we advertise
the WASM backend as feature-complete, since every Quartz user
eventually writes `puts("Hello, #{name}!")` and expects it to work.
