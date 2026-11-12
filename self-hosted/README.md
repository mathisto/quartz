# Quartz Self-Hosted Compiler

> The Quartz compiler, written in Quartz. **Now primary for all builds.**

## Status

**v5.12.15-alpha** — February 9, 2026

**TRUE FIXPOINT ACHIEVED.** Gen2 == Gen3 == Gen4: byte-identical LLVM IR (294,125 lines, 1,269 functions). The self-hosted compiler compiles itself and produces identical output across all generations.

### Version History

| Version | Date | Milestone |
|---------|------|-----------|
| v0.9.0 | Jan 2, 2026 | First fixpoint achieved (basic) |
| v2.0.0 | Jan 11, 2026 | Full parity, becomes primary |
| v2.5.0 | Jan 17, 2026 | Type checker enabled, match codegen fixed |
| v5.12.15 | Feb 9, 2026 | **True fixpoint: gen2==gen3==gen4 byte-identical** |

### Self-Hosting Milestones (Feb 2026)

| Fix | Impact |
|-----|--------|
| Bounds-checked MIR_INDEX/MIR_INDEX_STORE | Gen2 no longer crashes on OOB vector access |
| Added `str_find` intrinsic to codegen | Fixed SIGSEGV in struct field access (str_slice on empty) |
| Added `str_contains` intrinsic to codegen | Prevented future unknown-intrinsic bugs |
| Added `unwrap` intrinsic to codegen | Fixed Option unwrap returning 0 |
| Added NodeCall handler in mir_lower_stmt | Fixed empty match arm bodies in gen3 |
| Struct init field type/name checking | Validates struct literal correctness |
| Generic struct field access | Type substitution through field access |

### Feature Parity (Complete)

| Feature | Status |
|---------|--------|
| Core language (functions, structs, enums, match) | ✅ |
| Symbols (`:ok`, `:error`) | ✅ |
| String concatenation (`+`) | ✅ |
| CLI intrinsics (argc, argv, getenv) | ✅ |
| Map literals | ✅ |
| Safe navigation (`?.`) | ✅ |
| Nil coalescing (`??`) | ✅ |
| Hierarchical imports | ✅ |
| Module-qualified calls (`math.add` → `math$add`) | ✅ |
| "Did you mean?" suggestions | ✅ |
| StringBuilder intrinsics (sb_new, sb_append, etc.) | ✅ |
| Bounds-checked vector access | ✅ |
| str_find / str_contains / unwrap intrinsics | ✅ |

### Binaries

```
self-hosted/bin/
  be           # Current (v2.0.0)
  be-v2.0.0    # Archived v2.0.0
  be-v0.9.0    # Archived v0.9.0 (first fixpoint)
```

## Directory Structure

```
self-hosted/
  be.qz                    # Entry point, CLI argument parsing
  resolver.qz              # Import resolution, module loading
  
  frontend/
    token.qz               # Token enum, TokenType, Loc struct
    lexer.qz               # Lexer struct, tokenization functions
    ast.qz                 # ASTNode, NodeKind, all node data structs
    parser.qz              # Parser struct, parsing functions
    
  backend/
    mir.qz                 # MIR instructions, lowering, intrinsics
    codegen.qz             # MIR to LLVM IR emission
    
  bin/
    be                     # Current compiler binary
    be-v2.0.0              # Archived v2.0.0
    be-v0.9.0              # Archived v0.9.0
```

## Architecture

### Data Flow

```
Source (.qz)
    |
    v
[Lexer] --> Vec<Token>
    |
    v
[Parser] --> ASTNode (tree)
    |
    v
[Resolver] --> Multi-module AST + function registry
    |
    v
[MIR Lower] --> MIRProgram (flat instructions)
    |
    v
[Codegen] --> LLVM IR (text)
    |
    v
llc/clang --> Executable
```

### Key Design Decisions

1. **No Global State**: Each compiler phase uses explicit state structs
2. **MIR-level Module Resolution**: Module-qualified calls handled during MIR lowering
3. **Wrapper + Tagged Data for AST**: NodeKind enum with shared metadata
4. **One-Way Dependencies**: backend → frontend

## Building

```bash
# The Quartz compiler is now primary - use quake
./self-hosted/bin/quake build    # Builds using self-hosted/bin/quartz

# Manual compilation
./self-hosted/bin/Quartz self-hosted/be.qz | llc -filetype=obj -o be.o
clang be.o -o be-new

# Verify fixpoint
./be-new self-hosted/be.qz > stage2.ll
./self-hosted/bin/Quartz self-hosted/be.qz > stage1.ll
diff stage1.ll stage2.ll  # Should be empty
```

## Escape Hatches

If the Quartz compiler breaks:

1. **Use previous version**: `./self-hosted/bin/quartz-v0.9.0`
2. **Use C bootstrap**: `./bootstrap/bin/quartz`
3. **Rebuild from C**: `make -C bootstrap`

You cannot strand yourself on Compiler Island.
