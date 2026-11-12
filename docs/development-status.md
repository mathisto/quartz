> Public research edition: retired November 11, 2026. The development state below is retained as dated evidence, not an active roadmap. See [public-edition notes](PUBLIC_EDITION.md).

# Quartz

Quartz is an unreleased, self-hosted systems-language alpha that compiles through
LLVM. The project is under an active feature freeze while correctness, safety,
semantic coherence, reproducibility, and documentation are stabilized.

**Version:** `5.12.21-alpha`

**Backend authority:** LLVM

**Validation:** red; see [`STATUS.md`](STATUS.md)

```quartz
def fizzbuzz(n: Int): String when n % 15 == 0 = "FizzBuzz"
def fizzbuzz(n: Int): String when n % 3 == 0 = "Fizz"
def fizzbuzz(n: Int): String when n % 5 == 0 = "Buzz"
def fizzbuzz(n: Int): String = n.to_s()

def main(): Int
  for i in 1..101
    puts(fizzbuzz(i))
  end
  return 0
end
```

## Current Scope

- The compiler, Quake build tool, QSpec framework, and standard library are
  primarily written in Quartz. The retired C bootstrap is not part of normal
  development and is not contained in this repository.
- Quartz emits native code through LLVM and includes an emitted/linked runtime
  for allocation, effects, scheduling, concurrency, I/O, panic, and related
  services. There is no VM or tracing garbage collector; "no runtime" would be
  inaccurate.
- Runtime representation is mixed and type-directed, not universally `i64`.
  Native floats, pointers, value-layout aggregates, decomposed calls/returns,
  copy-on-write buffers, records, unions, and niche layouts coexist with
  legitimate scalar/handle words and remaining erased transport defects.
- Plain eligible structs use value semantics. Some layouts, including
  `@repr(C)`, recursive, and firewall-mixed structs, are excluded from the
  default value-layout path.
- LLVM is authoritative. C, WASM, freestanding, and cross-target paths are
  experimental or feature-scoped and do not have equivalent release authority.

## Safety Status

Quartz implements static mutability, borrow/exclusivity, move, Drop, Send/Sync,
and bounds checks in portions of the language. It does **not** yet provide the
stabilization target's lexical `unsafe` boundary, and known safe-looking programs
can still miscompile or fault. Raw pointers, unchecked access, representation
casts, inline assembly, runtime teardown, and several layout paths remain active
stabilization work. Do not treat the current alpha as memory-safe.

The owner-ratified target semantics are recorded in
[`docs/design/STABILIZATION_INVARIANTS.md`](docs/design/STABILIZATION_INVARIANTS.md).
They are not all implemented yet.

## Toolchain Status

```bash
./self-hosted/bin/quake --list
./self-hosted/bin/quake build
./self-hosted/bin/quake fixpoint
./self-hosted/bin/quartz run examples/hello.qz
```

QSpec's canonical baseline is currently red and includes normal, excluded,
quarantined, pending, and skipped categories. Use [`STATUS.md`](STATUS.md) for
the exact dated baseline and the stabilization ledger for authorization before
heavy runs.

The formatter is **not shipped**. `quake format` and `quake format_check`
intentionally fail closed; the default and aggregate `test` tasks also fail
through their `format_check` dependency. They do not currently format source.

The new guard protocol is implemented as unbanked B4 tooling, but its trusted
first migration, externally pinned reproduction, and owner branch-protection
setup are not operational. See [`docs/QUARTZ_GUARD.md`](docs/QUARTZ_GUARD.md).

## Debugging

Quartz emits line-table-level DWARF. Source-line/function breakpoints, stepping,
and file/line backtraces are supported. Typed local-variable and struct-field
inspection is not yet emitted.

## Documentation

| Document | Authority |
|---|---|
| [`ref.md`](ref.md) | Compact working memory and authority map; read first |
| [`docs/QUARTZ_REFERENCE.md`](docs/QUARTZ_REFERENCE.md) | Sole detailed reference for executable syntax and behavior |
| [`STATUS.md`](STATUS.md) | Current version, validation baseline, defects, and next gate |
| [`docs/STABILIZATION_PROGRAM.md`](docs/STABILIZATION_PROGRAM.md) | Current stabilization sequencing |
| [`docs/design/STABILIZATION_INVARIANTS.md`](docs/design/STABILIZATION_INVARIANTS.md) | Ratified target semantics |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Compiler pipeline and implementation architecture |
| [`docs/INTRINSICS.md`](docs/INTRINSICS.md) | Built-in functions and intrinsics |

Historical roadmaps, design proposals, sagas, and conductor ledgers remain
evidence. They do not override the current authority chain above.

## License

The repository does not currently contain a root license file. Licensing must be
confirmed before release.
