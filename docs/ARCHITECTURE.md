# Quartz Architecture

## Overview

Quartz is a self-hosting systems programming language that compiles to LLVM IR.
The compiler, linter, and Quake build system are written in Quartz. A lossless
CST formatter implementation is in progress, but the formatter is not shipped.

## Current State

**Version:** `5.12.21-alpha` (per [`VERSION`](../VERSION)). LLVM is the
authoritative backend and the current validation baseline is red. See
[`STATUS.md`](../STATUS.md) for dated counts and qualifications.

```
Source (.qz) → Lexer → Parser → Desugar → TypeCheck → MIR → LLVM IR → Binary
```

## Pipeline Stages

| Stage | Input | Output | Responsibility |
|-------|-------|--------|----------------|
| **Lexer** | Source text | Token stream | Tokenize, track line/col, keywords |
| **Parser** | Tokens | Surface AST | CST pipeline: `cst_parser` builds a lossless concrete syntax tree, `cst_lower` lowers it to the surface AST |
| **Desugar** | Surface AST | HIR | Eliminate sugar (interpolation, for-in, compound assign) |
| **TypeCheck** | HIR | Typed HIR | Validate types, resolve names, check mutability, borrow checking |
| **MIR Lower** | Typed HIR | MIR | Reduce to intrinsics, structural dispatch, monomorphization |
| **Codegen** | MIR | LLVM IR | Mechanical translation to LLVM IR |

### MIR Lowering Passes

| Pass | Purpose |
|------|---------|
| **PASS 0.55** | Register Drop types from impl blocks |
| **PASS 0.9** | Register bounded generic functions (`<T: Trait>`) for monomorphization |
| **PASS 0.95** | Register structurally-constrained functions (untyped params + UFCS) |
| **PASS 0.96** | Transitive structural detection (fixpoint loop for chained calls) |
| **PASS 1** | Lower all functions, skipping bounded generics and structural functions |
| **PASS 1.5** | Register Drop types from impl blocks in lowered functions |
| **PASS 2** | Emit pending specializations (cascading monomorphization) |

### Debug-Location Emission (`--debug`)

Debug builds attach a `!dbg` DILocation to every emitted LLVM instruction so
LLVM's verifier accepts the DWARF metadata (an inlinable call inside a
debug-info function *must* carry `!dbg`, or LLVM discards the whole module's
debug info). Rather than thread a location through ~16.8K instruction emit
sites, codegen emits one `; __qzdbgloc N` sentinel comment per MIR instruction
(`cg_emit_instr`) plus a function-entry sentinel (`cg_emit_function`). A single
post-pass, `cg_apply_debug_locations` (`backend/codegen.qz`), walks the finished
IR once: it stamps `, !dbg !N` onto every indented non-comment instruction from
the active sentinel, places the `switch` location after its closing `]`, and
strips the sentinels. The pass runs in `quartz.qz` on `final_ir` for debug
builds only. `quake guard`'s "Verifying debug info" phase runs
`opt -passes=verify` on a `--debug` build and fails on any diagnostic.

This is **line-table-level DWARF only** (`cg_emit_debug_metadata`,
`codegen.qz:1660`): one `DICompileUnit`, a per-module `DIFile`, one
`DISubprogram` per function (all sharing a placeholder
`!DISubroutineType(types: !{null})`), and `DILocation` line entries
(column hardcoded to 1). No `DILocalVariable`, `DICompositeType`,
`DIBasicType`, or `dbg.declare`/`dbg.value` are emitted, so `file:line`
breakpoints and backtraces work but typed variable inspection (`frame
variable`) does not. Variable-level DWARF is unbuilt.

### Key Invariants

| Boundary | Invariant |
|----------|-----------|
| Post-Parse | Valid AST, source spans preserved |
| Post-Desugar | No surface syntax (interpolation, ranges, etc.) |
| Post-TypeCheck | All expressions typed, no unbound names, mutability checked |
| Post-MIR | Only intrinsics, explicit control flow |

**Invariant violations in later phases are compiler bugs, not user errors.**

## Compilation Modes

### Single-File Compilation (Default)

Compiles the entire compiler to a single `.ll` file, then to binary via `llc` + `clang`.

### Separate Compilation (v5.8+)

Per-module `.ll` files → parallel `llc` → `.o` caching → link. Significantly faster for incremental builds.

```bash
./self-hosted/bin/quake build:separate
```

### Incremental Compilation (v5.10+)

Three-tier caching strategy:
- **Tier 0**: Dependency graph — skip modules whose inputs haven't changed
- **Tier 1**: Interface hash early cutoff — skip downstream if public API unchanged
- **Tier 2**: Object file caching — reuse `.o` files when `.ll` hasn't changed

## Directory Structure

```
quartz/
├── self-hosted/              # Quartz compiler written in Quartz
│   ├── quartz.qz                 # Entry point, CLI
│   ├── resolver.qz               # Module resolution
│   ├── frontend/                  # Lexer, parser, AST, macros, derive
│   ├── middle/                    # Type checking, diagnostics, inference
│   ├── backend/                   # MIR lowering, codegen, domtree
│   ├── shared/                    # Build cache, interning
│   ├── error/                     # Error explanations
│   └── bin/                       # Compiled binaries
├── std/                      # Standard library (Quartz)
│   ├── string.qz                 # String utilities
│   ├── json.qz                   # JSON parser
│   ├── colors.qz                 # Terminal colors
│   ├── http.qz                   # HTTP client
│   └── ...                       # Math, random, time, etc.
├── tools/                    # Self-hosted tools (Quartz)
│   ├── fmt.qz                    # Historical formatter code; task is disabled
│   ├── lint.qz                   # Linter
│   └── quake.qz                  # Quake build system launcher
├── Quakefile.qz              # Build task definitions
├── spec/                     # Test suites
│   ├── qspec/                    # QSpec native tests (*_spec.qz) — primary
│   └── integration/              # RSpec integration tests (*_spec.rb) — residual
└── docs/                     # Language documentation
```

### Key Source Files

| File | Purpose |
|------|---------|
| `frontend/lexer.qz` | Tokenization, keywords, escape sequences |
| `frontend/cst_parser.qz` | CST parser — builds a lossless concrete syntax tree from tokens |
| `frontend/cst_lower.qz` | Lowers the CST to the surface AST; also evaluates `@cfg` declarations against the cross-compile target |
| `frontend/cfg.qz` | `@cfg(os:/arch:/feature:/...)` condition evaluation |
| `frontend/ast.qz` | AST node types and constructors |
| `frontend/macro_expand.qz` | Macro expansion |
| `frontend/derive.qz` | `@derive` attribute processing |
| `middle/typecheck.qz` | Bidirectional type checking, scope management |
| `middle/typecheck_walk.qz` | AST walking: tc_expr/tc_stmt dispatchers |
| `middle/typecheck_helpers.qz` | Pure validation helpers (binary/unary/let/call) |
| `middle/typecheck_generics.qz` | Type parameter inference, struct/enum support |
| `middle/typecheck_match.qz` | Pattern matching, exhaustiveness checking |
| `middle/typecheck_concurrency.qz` | Send/Sync, spawn/await/select checks |
| `middle/typecheck_capture.qz` | Closure capture analysis |
| `middle/typecheck_expr_handlers.qz` | Expression handler functions (call, lambda, match, etc.) |
| `middle/typecheck_registry.qz` | Type/trait/impl registry |
| `middle/typecheck_builtins.qz` | Builtin function registration |
| `backend/mir.qz` | MIR data structures, Drop support |
| `backend/mir_lower.qz` | MIR lowering: dispatchers + orchestration |
| `backend/mir_lower_async_registry.qz` | Async function tracking, suspendable leaves |
| `backend/mir_lower_gen.qz` | Generator/async state machine lowering |
| `backend/mir_lower_expr_handlers.qz` | Expression lowering handlers (call, binary, match, etc.) |
| `backend/mir_lower_stmt_handlers.qz` | Statement lowering handlers (let, if, for, etc.) |
| `backend/mir_lower_iter.qz` | Collection iteration lowering |
| `backend/codegen.qz` | LLVM IR emission: entry points + function orchestration |
| `backend/codegen_instr.qz` | LLVM IR instruction emission + dispatcher |
| `backend/codegen_separate.qz` | Incremental + separate compilation modes |
| `backend/codegen_intrinsics.qz` | Intrinsic dispatch registry (hub) |
| `backend/cg_intrinsic_*.qz` | 7 intrinsic handler modules (collection, concurrency, core, data, memory, simd, string) |
| `resolver.qz` | Module resolution, mutual imports, path handling |
| `shared/build_cache.qz` | Incremental compilation cache |

## Type System

### Runtime Representation

Quartz uses a mixed, type-directed representation. `Int`, lengths, tags,
compiler IDs, opaque handles, and target ABI values may legitimately lower to
`i64`; native floats, pointers, decomposed/value-layout aggregates, COW buffers,
records, unions, and niche encodings do not fit a universal scalar model.
Remaining effect, channel, task, compiler-handle, and module paths still erase
typed values through one-word transports. Those are stabilization defects, not
the language's intended representation invariant. See
[`STABILIZATION_INVARIANTS.md`](design/STABILIZATION_INVARIANTS.md#representation-invariant).

### Const-by-Default

```quartz
x = 5           # Immutable binding
var y = 10      # Mutable binding
y = 20          # OK
x = 10          # ERROR: Cannot reassign immutable 'x'
```

### Move Semantics & Drop

Types implementing `Drop` have linear/move semantics:
- Values are moved (not copied) on assignment or function call
- `Drop.drop()` is called automatically at scope exit
- `Copy` and `Drop` are mutually exclusive (QZ1215)
- Nested fields implementing `Drop` are dropped recursively

### Length-Prefixed Strings

Quartz strings store length at `ptr[-8]` (8 bytes before the string data) and are null-terminated for C compatibility. String comparison (`==`) does content comparison.

## Sugar vs Core

Surface syntax desugars to core forms:

| Sugar | Core |
|-------|------|
| `"a#{x}b"` | `str_concat(str_concat("a", str_from_int(x)), "b")` |
| `x += 1` | `x = x + 1` |
| `for i in 0..n` | `while` loop with counter |
| `try x` | Early return on `None`/`Err`, otherwise unwrap |

## Debug Tools

```bash
./self-hosted/bin/quartz --dump-ast program.qz   # Show AST
./self-hosted/bin/quartz --dump-mir program.qz   # Show MIR
./self-hosted/bin/quartz --dump-ir program.qz    # Show LLVM IR
# Formatting is not shipped; format tasks fail closed.
```

## Adding New Builtins

| Step | File | What to Do |
|------|------|------------|
| 1 | `typecheck_builtins.qz` | Register builtin type signature |
| 2 | `mir.qz` | Add to intrinsic recognition |
| 3 | `codegen_intrinsics.qz` | Register in `cg_init_intrinsic_registry()` with category |
| 4 | `cg_intrinsic_*.qz` | Add handler in the appropriate category file |

**All four steps required.** Missing step 2 causes calls to become closures.

## Self-Hosting Chain

```
v0.1.0 (C bootstrap) → ... → v5.x (self-hosting, fixpoint achieved)
```

The C bootstrap compiler was retired in February 2026 and is not in this
repository. The self-hosted compiler is the current implementation. Preserved
previous binaries are the normal recovery path; an externally retained retired
bootstrap is recovery-only, not a second implementation to update.

## Effect Machinery

Algebraic effects are first-class in Quartz (Phase 1 landed in April 2026;
compiler dogfooding Phase 5 completed April 23). Current executable behavior is
specified in [`QUARTZ_REFERENCE.md`](QUARTZ_REFERENCE.md); [`EFFECTS.md`](EFFECTS.md)
is a historical Piezo design record. Migration procedure:
[`EFFECT_MIGRATION_PLAYBOOK.md`](design/EFFECT_MIGRATION_PLAYBOOK.md).

### Runtime ABI

Effect state is held in eight global arrays (`__qz_effect_stack_*`), sized `[256 x i64]` each. `stack_top` tracks the high-water mark.

| Symbol | Purpose |
|--------|---------|
| `__qz_effect_stack_names` | Effect name cstr at each frame |
| `__qz_effect_stack_handlers` | Function-pointer handler at each frame |
| `__qz_effect_stack_op_filters` | Per-op filter (null = all ops, cstr = one op) |
| `__qz_effect_stack_bufs` | `sigjmp_buf` for kind=2 (unwind) |
| `__qz_effect_stack_results` | Result slot for kind=2 unwind |
| `__qz_effect_stack_resumed` | Flag: did the handler call `resume`? |
| `__qz_effect_stack_state_slots` | State<S> evidence slot |
| `__qz_effect_stack_top` | Next-free index |

Three ABI functions, all inline-LLVM-emitted in `cg_emit_effect_runtime`:

- `__qz_effect_handle_install(name, handler, kind, op_filter)` — push a frame; no-op if `stack_top >= 256`.
- `__qz_effect_handle_uninstall()` — pop (if `stack_top > 0`).
- `__qz_effect_perform(eff, op, argc, argv, kind)` — top-down scan for a matching `(name, op_filter)`, invoke handler, return its result.

The emitted handler ABI is `(op_name: ptr, argc: i64, argv: ptr): i64`. This is
an **internal, unsafe, semantically erased, and currently nonconforming** runtime
boundary, not the intended typed user model. ABI-shaped Quartz handlers such as
`def my_h(op: Int, argc: Int, argv: Int): Int` expose the defect directly and can
misrepresent typed or multiword payloads. See the tracked
[T1 transport evidence](sagas/stabilization-baseline-2026-07-15-research/runtime-transport-census.md#t1-effect-operations-have-one-hardwired-word-abi-regardless-of-declaration).

### Continuation kinds

| Kind | Semantics | Implementation |
|------|-----------|----------------|
| **kind=1** | Function-call. Handler returns, perform returns with the handler's value. | Direct call. |
| **kind=2** | Unwinding. Handler's return value is the value of the enclosing `with E {...} do -> ... end` block. | `sigsetjmp` at wrap install; `siglongjmp` in handler when a kind=2 op is performed. |
| **kind=3** | CPS continuation. Handler's `resume(v)` re-enters the caller's `$poll`-style state machine with `v`. | `@__qz_effect_park_rv` TLS; continuation frame at `@__qz_effect_current_cont_frame`. |

Kind=3 is the basis of async — `Async.await`, `Async.spawn`, `Async.suspend`, `Async.yield` are all kind=3. See [`docs/design/P3_0_KIND3_CPS.md`](design/P3_0_KIND3_CPS.md) for the continuation model.

### Body-wrap codegen

`with E { op: h, ... } do -> <body> end` lowers to a three-block structure:

- `wb.body` — install handler(s), setjmp for kind=2, execute body, uninstall, branch to `wb.done`.
- `wb.catch` — siglongjmp landing pad (kind=2 only); uninstall, load result, branch to `wb.done`.
- `wb.done` — merge point; phi node joins body's value with catch's result.

Multi-op records (`{ op1: h1, op2: h2 }`) push one frame per op, each with its own `op_filter` cstr. A perform scan stops at the first `(name, filter)` match. Unlisted ops fall through to outer frames. The H-delegate row in the tracked [Piezo Phase 2 milestone history](research/EFFECTS_IMPLEMENTATION_PLAN.md#phase-2-milestone-tracker-post-d-follow-ons) records the implementation change.

**Last-statement rule**: a body-wrap's do-block MUST end in a bare expression, not `return X`. Last-statement `return` sets the merge block's TERM_RETURN before `handle_uninstall`'s direct text emission crosses block boundaries, which trips SSA dominance. Mid-body returns are fine.

### D.4 blessed-relaxation

Five effects bypass the `can E` / `with E` requirement for bare callsites (the "invisible by default" path from `docs/EFFECTS.md §1`):

| Effect | Default handler | Purpose |
|--------|-----------------|---------|
| `Throws` | `panic` with the throw arg | Trivial error paths don't need ceremony. |
| `Log` | libc `write(2, ...)` | `log::info(...)` just works. |
| `Async` | `usleep(1)` yield / stub others / `__qz_effect_park` for suspend | Main prelude auto-inits scheduler on first spawn. |
| `FileIo` | libc `fopen` / `fread` / `fwrite` / `access` / `qz_readdir` | Compiler + any Quartz program gets fs without `can FileIo`. |
| `Intern` | Global string interner (`std/intern.qz`) | Symbol tables work without wraps. |

The blessed set is the allow-list in `typecheck_expr_handlers.qz::tc_is_blessed_effect`. Adding an effect requires also emitting an inline-LLVM default handler from `cg_emit_effect_runtime` and installing it in `cg_emit_effect_main_prelude`.

### Three-pass bootstrap discipline

Migrating a capability to an effect in the self-hosted compiler uses three sequential passes:

1. **Pass 1** — typecheck-only propagation. Add the effect declaration; wrap a small slice of callsites with the default handler. Nothing else moves.
2. **Pass 2a** — install the default handler in the main prelude (and blessed-relaxation list, if applicable). Wraps become redundant but harmless.
3. **Pass 2b** — delete the wraps. Each callsite reduces to its body expression or statement.

Each pass ships with `quake guard` + cold+warm cache-enabled self-compile green. Details and incident log: [`EFFECT_MIGRATION_PLAYBOOK.md`](design/EFFECT_MIGRATION_PLAYBOOK.md).

### Known limitations

- **Stack cap is 256 frames**. Max observed depth during self-compile: 33. A truly-symmetric always-increment-top design is filed as Tier 4; the cap provides 7.7× headroom.
- **Handlers cannot close over state**. Routing a context object into a handler requires a bridge (single-slot module-global set inside the outermost `with`) or a threaded sink (extra op arg). Closures are a Phase 6 candidate.
- **No effect-op inlining**. Every perform goes through `__qz_effect_perform` dispatch even when the handler is provably the prelude default. Filed as Tier 4; not a current hotspot (Phase 5 perf measured at < 0.1 % overhead on self-compile).
