> Public research edition: retired November 11, 2026. The development state below is retained as dated evidence, not an active roadmap. See [public-edition notes](docs/PUBLIC_EDITION.md).

# Quartz Working Reference

Read this file first when working in Quartz. It is the compact agent working
memory and authority map, not a second full language specification.

- [`docs/QUARTZ_REFERENCE.md`](docs/QUARTZ_REFERENCE.md) is the **sole detailed
  reference for currently executable syntax and behavior**.
- [`docs/design/STABILIZATION_INVARIANTS.md`](docs/design/STABILIZATION_INVARIANTS.md)
  owns ratified target semantics where the implementation is not yet conforming.
- [`STATUS.md`](STATUS.md) owns the current version, validation baseline, known
  defects, backend scope, and next gate.
- [`docs/STABILIZATION_PROGRAM.md`](docs/STABILIZATION_PROGRAM.md) owns current
  sequencing. Historical roadmaps and conductor ledgers are evidence only.

If this file conflicts with the detailed reference about executable behavior,
fix this file and follow the detailed reference. If executable behavior conflicts
with a stabilization invariant, record the implementation as nonconforming; do
not describe the target as shipped.

## Current Reality

- Version: `5.12.21-alpha`, from [`VERSION`](VERSION).
- Product state: unreleased self-hosted alpha; LLVM is authoritative.
- The self-hosted compiler is the current implementation. The retired C
  bootstrap is not the normal development path and is not in this repository.
- Runtime representation is mixed and type-directed. Legitimate `i64` scalars
  and handles coexist with native floats, pointers, value-layout aggregates,
  decomposed calls/returns, COW buffers, records, unions, and niche layouts.
  High-level effect/channel/task transport still contains erased one-word paths;
  never summarize Quartz as "pure i64 at runtime."
- Plain eligible structs currently use value semantics; `@repr(C)`, recursive,
  firewall-mixed, and other excluded layouts are not evidence of a universal
  stack-only representation. Representation must not be confused with aliasing
  semantics.
- No lexical `unsafe` boundary exists yet. Raw pointers, unchecked access,
  representation casts, and inline assembly are therefore not fenced as the
  stabilization target requires. Do not claim safe Quartz is memory-safe today.
- `quake format` and `quake format_check` intentionally fail closed because the
  formatter is not shipped. Consequently the default task and aggregate `test`
  task also fail through `format_check`.
- The canonical QSpec baseline is red. Use [`STATUS.md`](STATUS.md#red-baseline)
  for exact dated counts; do not copy volatile totals into agent instructions.
- Guard protocol code exists, but trusted migration and the external protected
  reproduction check are not operational. Treat the B4 implementation as
  unbanked tooling, not an established repository gate.

## Syntax Core

```quartz
# Bindings are immutable by default; `var` opts into reassignment.
x = 5
var y: Int = 10
y = 20

def add(a: Int, b: Int): Int = a + b

struct Point
  x: Int
  y: Int
end

p = Point { x: 3, y: 4 }

match Option::Some(42)
  Some(v) => puts(v)
  None => puts("none")
end
```

Key spellings:

| Do not invent | Quartz |
|---|---|
| `let x = 5` | `x = 5` |
| `mut x` | `var x` |
| `fn f()` | `def f()` |
| `def f() -> Int` | `def f(): Int` |
| `import a::b` | `import a/b` |
| Rust closure `\|x\| x + 1` | `x -> x + 1` |
| postfix `expr?` propagation | `try expr` |
| `$try(expr)` | `try expr` (`$try` is retired) |
| `*p` dereference | typed pointer/FFI intrinsics such as `ptr_read<T>(p)` |

`&x` and `&mut x` are valid borrow expressions. `::` is valid for type and
namespace paths such as `Option::Some`; `/` remains the import path separator.
Inside `extend` and trait implementations, use `self.field` or `@field`.

## Working Commands

```bash
./self-hosted/bin/quake --list
./self-hosted/bin/quake build
FILE=spec/qspec/example_spec.qz ./self-hosted/bin/quake qspec_file
./self-hosted/bin/quake fixpoint
```

Follow the stabilization ledger's current authorization and resource rules
before any heavy validation. Do not run QSpec merely to validate documentation.

## Maintenance

After a language change, update the detailed reference first, then this compact
working reference if its syntax core or current-reality notes changed. Update
`STATUS.md` for current state and the stabilization roadmap for sequencing; do
not turn historical ledgers into current authority.
