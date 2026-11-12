# Separate Compilation Design

## Status: Design Document (Not Implemented)

## Problem

The Quartz compiler is monolithic: all modules are compiled as a single compilation unit, producing one LLVM IR file, one `llc` invocation, and one binary. This works for the current codebase (~1,400 functions) but does not scale:

- Self-compilation takes ~8-10 seconds, all single-threaded
- Any source change requires full recompilation (Tier 0/1 incremental helps but is workaround-level)
- Cannot parallelize compilation across CPU cores
- Cannot share pre-compiled library artifacts

## Current Architecture

```
Source (.qz) → Lexer → Parser → AST → TypeCheck → MIR → Single LLVM IR → llc → Binary
                                 ↑                          ↑
                           All modules                 One monolithic
                           in one AST                  IR output
```

### Blockers

Four architectural patterns prevent straightforward separate compilation:

### 1. Monomorphization

Generic functions (`vec_push<Int>`, `each<T>`) are specialized during MIR lowering via a queue-based system (`MirGenericState.pending_specs` in mir.qz). Each call site generates a concrete specialization with the type parameters resolved.

**Problem**: When module A calls `vec_push<Point>` but `vec_push<T>` is defined in the stdlib, the specialization `vec_push<Point>` must be emitted in A's compilation unit. This requires the generic body to be available at the caller's compilation time.

**Solution**: Use `linkonce_odr` linkage for monomorphized instances. Each compilation unit emits its own copy; the linker deduplicates at link time. This is the same strategy used by C++ templates and Rust generics.

### 2. UFCS Dispatch

Method calls like `v.push(x)` are rewritten by the typechecker (typecheck_walk.qz, lines 3256-3705) to canonical intrinsic names (e.g., `Vec$push` → `vec_push`). The rewrite depends on the receiver's full type, which requires the type registry for imported modules.

**Problem**: Cross-module UFCS requires type information from dependencies. If module B provides `struct Point`, module A needs B's type registry to dispatch `point.x`.

**Solution**: Module interface files (`.qzi`) already serialize struct definitions, function signatures, and type aliases. The typechecker can load `.qzi` data to resolve cross-module UFCS without re-parsing or re-typechecking dependency source.

### 3. String Pool

String constants are deduplicated globally via `cg_add_string()` (codegen_util.qz). Each unique string gets an `@.str.N` global. All modules share one pool.

**Problem**: Separate compilation units each have their own string pool. Duplicate strings across modules waste space; cross-module string references need resolution.

**Solution**: Use `linkonce_odr` or `private` linkage for string constants. Give each string a content-based name (e.g., `@.str.<hash>`) instead of sequential indices. The linker merges identical constants. Alternatively, emit `private` constants per module (simple, slight binary bloat, but no cross-module string coordination needed).

### 4. Global State and Module Init

Module-level globals are declared as `@global_NAME` and initialized by `__qz_module_init()`, which is called once from `qz_main()`. The init function runs all module-level expressions in dependency order.

**Problem**: With separate compilation, each module needs its own init function, and the main module must call them in topological order.

**Solution**: Each module emits `@__qz_module_init_<modname>()`. The main module's init function calls dependency inits in topological order (dep graph already provides this). Guard each init with a `@__qz_module_inited_<modname>` flag to handle diamond imports.

## Proposed Architecture

```
Module A (.qz) → Lex → Parse → TC → MIR → A.ll → A.o ─┐
Module B (.qz) → Lex → Parse → TC → MIR → B.ll → B.o ──┼→ clang → Binary
Module C (.qz) → Lex → Parse → TC → MIR → C.ll → C.o ─┘
                              ↑
                         Load .qzi for
                         cross-module types
```

### Phase 1: Module Interface Files (.qzi)

Already partially implemented in `self-hosted/shared/qzi.qz`. The `QziData` struct serializes:
- Struct definitions (names, fields, types, annotations)
- Function signatures (names, params, return types)
- Generic function templates (type params, constraints)
- Enum definitions (names, variants, payload types)
- Trait definitions and implementations
- Type aliases and newtypes
- Extern function declarations

**Extension needed**: Serialize generic function bodies (AST subtrees) so dependent modules can monomorphize them without access to the source.

### Phase 2: Per-Module LLVM IR

Each module emits its own `.ll` file:

```
# quartz -c module_a.qz → module_a.ll
# quartz -c module_b.qz → module_b.ll
# quartz --link module_a.ll module_b.ll → program.ll (or use llvm-link)
```

Key changes to `cg_emit_function()`:
- External functions from other modules: `declare` instead of `define`
- Monomorphized generics: `linkonce_odr` linkage
- String constants: `private` per module (simplest; slight duplication OK)
- Module init: `define void @__qz_module_init_<name>()`

### Phase 3: Parallel Compilation

With per-module IR, compilation becomes embarrassingly parallel:
```bash
# Parallel llc invocations
llc -filetype=obj module_a.ll -o module_a.o &
llc -filetype=obj module_b.ll -o module_b.o &
wait
clang module_a.o module_b.o -o program
```

Or let LLVM LTO handle it:
```bash
llvm-link module_a.ll module_b.ll -o combined.bc
opt -O2 combined.bc -o optimized.bc
llc optimized.bc -filetype=obj -o program.o
clang program.o -o program
```

### Phase 4: Incremental Integration

The existing Tier 1 incremental system tracks per-module content hashes and interface hashes via the dep graph. Separate compilation extends this naturally:

- Only recompile modules whose source changed
- Only re-typecheck modules whose dependency interfaces changed
- Cached `.o` files can be reused directly (no fragment splicing)

This eliminates the current Tier 2 complexity (fragment caching, string pool coordination, metadata slot management).

## Implementation Effort

| Phase | Scope | Estimate |
|-------|-------|----------|
| Phase 1: .qzi body serialization | Extend qzi.qz with generic body AST | 1-2 days |
| Phase 2: Per-module IR emission | New codegen mode, linkage changes | 2-3 days |
| Phase 3: Parallel build driver | Quake task for parallel llc | 0.5 day |
| Phase 4: Incremental integration | Replace Tier 2 with per-module caching | 1-2 days |

Total: ~5-8 days (with ÷4 calibration factor)

## Risks

- **Generic body serialization**: AST subtrees are not currently serializable. May need a compact binary format.
- **UFCS resolution order**: Cross-module UFCS depends on import order affecting type registry population. Must ensure `.qzi` loading is order-independent.
- **Linker compatibility**: `linkonce_odr` linkage for monomorphized functions requires LLD or a linker that handles COMDAT groups correctly on all targets.
- **Debug info**: DWARF metadata currently uses sequential indices across the whole program. Per-module emission needs per-module metadata numbering.

## Decision: Deferred

Separate compilation provides the foundation for scalable builds but requires significant plumbing. The current monolithic approach works for the ~1,400-function compiler. Prioritize when:
- Self-compilation exceeds 30 seconds
- Multiple developers need to work on different modules
- Pre-compiled library distribution is needed (package manager)
