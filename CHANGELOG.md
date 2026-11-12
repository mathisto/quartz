# Changelog

All notable changes to Quartz are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] — v5.25.0-alpha

### Added
- **Union Types**: `Int | String` union type syntax with `|` operator
- **Intersection Types**: Type `&` syntax for trait-bound intersections
- **Record Types**: Anonymous structural types `{ x: Int, y: String }` with row polymorphism
- **Row Variables**: Implicit row variable inference from field access on untyped params
- **Width Subtyping**: Structs with extra fields satisfy narrower record types
- Monomorphized codegen for record field access (GEP offset specialization)
- Union exhaustiveness checking in match expressions
- Union linearity propagation (move semantics)
- `JsonPrimitive` union type alias in stdlib

### Changed
- 3,274 integration tests, 0 failures, 0 pending

---

## [5.20.0] — 2026-02-14

Table Stakes Implementation (21/21 features) and Literal Syntax enhancements.

### Added
- **`loop` keyword** — infinite loop construct
- **`usize` type alias** — platform-width unsigned integer
- **Raw strings** `r"..."` — no escape processing
- **`vec_sort` / `vec_sort_by`** — in-place sorting with comparison functions
- **Path manipulation** — `path_join`, `path_dirname`, `path_basename`, `path_ext`
- **Filesystem ops** — `file_read`, `file_write`, `file_exists`, `dir_list`
- **Thread-local storage** — `@thread_local` attribute for module-level vars
- **Multi-line strings** `"""..."""` — triple-quote syntax with interpolation
- **Buffered I/O** — `BufferedReader`, `BufferedWriter` for efficient stream access
- **Argparse stdlib** — declarative command-line argument parsing
- **UTF-8 awareness** — `str_chars`, `str_char_at`, `str_byte_len` vs `str_len`
- **Visibility** (`priv`) — Ruby-style `priv` keyword for private definitions
- **Integer overflow detection** — compile-time and runtime overflow checking
- **`@x` sigil** — shorthand for `self.x` in extend blocks
- **Stack traces on panic** — human-readable backtraces with function names
- **Re-exports** (`pub import`) — re-export imported symbols from a module
- **Tuples** — anonymous product types `(Int, String)` with `.0`, `.1` access
- **Operator overloading** — constrained to fixed operator set via extend blocks
- **Slices** `Slice<T>` — borrowing views into contiguous memory
- **User macros** — hygienic, pattern-based macro system (`$macro` declarations)
- **Negative indexing** — `a[-n]` desugars to `a[a.size - n]`
- **Char literals** — `'a'` resolves to integer char code
- **Set comprehensions** — `{expr for x in iter}` desugars to `set_new` + `set_add`
- **Range objects** — `Range` type with `start`, `end`, `step` fields
- **Index trait** — `Indexable` trait for custom `[]` operator
- **Binary data type** (`Bytes`) — byte buffers with `ByteReader` cursor
- **Byte literal syntax** `b"..."` — raw byte strings
- **String interpolation** `"#{expr}"` — desugars to `str_concat`/`to_str` chain

---

## [5.15.0] — 2026-02-12

Networking, optimization, and global variable support.

### Added
- **Cross-module global variables** — `var` declarations at module level for shared mutable state
- **Custom iterators** — `for x in struct` via `$next` method returning `Option`
- **Structured concurrency** — scope-bound task groups with cooperative cancellation (9 tests)
- **Linear types** — move semantics, borrows, and `Drop` trait for resource safety (11 tests)
- **Multi-target compilation** — C backend (~165 intrinsics), WASI target, `@cfg` target threading (57+6+4 tests)
- **TcpListener** — TCP server with `tcp_accept`, `tcp_read_all`, `tcp_write_all`
- **Non-blocking I/O** — kqueue-based event loop for network operations
- **`format()` intrinsic** — string interpolation support
- **E-graph MIR optimizer** — acyclic e-graph with hashcons CSE, replaces naive optimizer

### Changed
- MIR optimizer: added constant folding, CSE, copy propagation, dead code elimination
- MIR optimizer: added tail call optimization (`tail call` when call dest matches return value)
- MIR optimizer: added function inlining (single-block, ≤8 instrs, all clonable kinds)
- MIR optimizer: added strength reduction (`x * 2^n → x << n`)
- LLVM hints: `noundef` on all function params for register allocation

---

## [5.10.0] — 2026-02-10

Concurrency, SIMD, and benchmark optimization sprint.

### Added
- **`select` statement** — multiplexed channel recv with pattern matching
- **`try_recv` / `try_send`** — non-blocking channel operations returning `Option<T>`
- **Blocking channel operations** — channels block until data available
- **`Task<T>` type** — generic structured concurrency handle
- **Sized storage** — narrow params, locals, and struct fields (I8/I16/I32 in registers)
- **F32x4 / F64x2 / I32x4 SIMD** — first-class SIMD vector types
- **SIMD intrinsics** — FMA, min/max/abs, shuffle for vector types
- **LLVM auto-vectorization metadata** — loop vectorization hints in IR output
- **`StringBuilder`** — efficient string building for concat-heavy code
- **`vec_get_unchecked` / `vec_set_unchecked`** — bounds-check-free array access for hot loops

### Fixed
- Benchmark pipeline: `clang -O2 -x ir` (was the #1 perf issue)
- LLVM optimization hints: datalayout, nounwind, noalias in both compilers
- `try_recv` now returns heap-allocated Option struct (0 is valid channel value)
- Gen2 fixpoint broken by FNV-1a offset basis overflow — used signed offset basis

### Changed
- Polyhedral loop optimization (Polly) enabled in benchmark pipeline

---

## [5.5.0] — 2026-02-08

Native floats, packed structs, conditional compilation, and const evaluation.

### Added
- **F64 / F32 types** — first-class floating-point with full arithmetic, conversion, comparison
- **Packed structs** — `@packed` attribute for C-style packed data structures
- **Conditional compilation** — `@cfg(target = "...")` for platform-specific code
- **Const evaluation** — compile-time constant evaluation including arithmetic, logical ops
- **`const def`** — functions evaluated at compile time
- **`@cImport`** — C header parsing for FFI type extraction
- **Inline assembly improvements** — full asm control with constraints and clobbers
- **Bit manipulation intrinsics** — `popcount`, `clz`, `ctz`, `bswap`

---

## [5.0.0] — 2026-02-06

Fixed-width integers, volatile access, memory ordering, and exhaustiveness checking.

### Added
- **Fixed-width integers** — `I8`, `I16`, `I32`, `U8`, `U16`, `U32`, `U64` types
- **LLVM type mapping** for fixed-width integers with literal parsing suffixes
- **FFI / `@repr(C)` compatibility** for fixed-width integer types
- **`volatile_load` / `volatile_store`** — LLVM volatile flags for MMIO
- **Memory ordering** — ordering parameters for atomic intrinsics (`Relaxed`, `Acquire`, `Release`, `AcqRel`, `SeqCst`)
- **`fence` intrinsic** — memory fence for fine-grained concurrency
- **Exhaustiveness checking** — compile-time match coverage for all enum variants

### Fixed
- `sockaddr_in` and C structure handling for networking tests

---

## [3.0.0] - 2026-01-17

### Added
- **Full Type Inference** — Ruby-like ergonomics with complete Hindley-Milner type inference
  - Array type inference from usage: `arr[0] + arr[1]` infers `arr: Array<Int>`
  - Struct type inference from field access: `p.x` infers `p: Point`
  - Type variables with proper unification algorithm
  - Let-polymorphism with generalization/instantiation
  - All 24 type inference tests passing

### Fixed
- **Parser**: Function parameters without type annotations no longer default to `Int`
- **Type variables**: Fresh type vars now start at -1 instead of 0

## [2.5.0] - 2026-01-17

### Fixed
- **Match expression codegen for simple enums** — generates proper integer comparison against variant tag
- 6 previously-pending specs now pass

### Added
- Match exhaustiveness test suite (4 tests)
- Generic type parsing test suite (7 tests)
- Range expression test suite (9 tests)

## [2.3.0] - 2026-01-15

### Fixed
- **BUG-001**: Struct field access generates correct IR (struct registry for field index)
- **BUG-002**: Generic enum type arguments no longer parsed as comparisons
- **BUG-003**: Nullary lambdas (`||`) parse correctly

## [2.2.0] - 2026-01-14

### Fixed
- Enum codegen parity between Quartz and C compilers
- Match statement pattern handling in MIR

### Added
- Compound assignment operators (+=, -=, *=, /=, %=)
- Nil coalescing operator (??)

## [2.1.0] - 2026-01-12

### Added
- Truthy/falsy conditions for if/while statements
- `str_starts_with` and `str_ends_with` intrinsics
- Doc comments (`##`) attached to def/struct/enum
- `str_split` builtin
- Docgen tool for documentation extraction

### Fixed
- String concatenation for param+param operands

## [2.0.0] - 2026-01-11

Quartz compiler becomes primary. Fixpoint achieved.

### Added
- Type inference integration with optional parameter annotations
- HM-style polymorphism tests
- Type inference unification algorithm

### Changed
- Quartz compiler is now primary for all builds and tests
- Removed C bootstrap directory from main repo

## [1.1.0] - 2026-01-07

### Added
- Complete UFCS migration across all compiler files
- String + operator replaces str_concat()

### Changed
- Rakefile refactored for Quartz-only workflow

## [1.0.0] - 2026-01-02

Self-hosting complete. Fixpoint achieved.

### Added
- Symbol literals (:ok, :error)
- Map literal syntax ({:key => value})
- Safe navigation operator (?.)
- Nil coalescing operator (??)
- String concatenation with + operator
- `getenv` intrinsic
- Hierarchical module imports
- Colors module with NO_COLOR support
- String equality by content comparison
- User functions can shadow builtins
- UFCS method calls as standalone statements
- Module UFCS transform

### Fixed
- Nested struct field access in MIR lowering
- vec_push codegen pointer reload after branches

## [0.8.0-pre-selfhost] - 2025-12-01

Pre-self-hosting release. C bootstrap compiler era.

### Added
- Core language features: structs, enums, pattern matching
- First-class functions and closures
- Const-by-default semantics
- Basic MIR and LLVM IR codegen
- Integration test suite (730 tests)
