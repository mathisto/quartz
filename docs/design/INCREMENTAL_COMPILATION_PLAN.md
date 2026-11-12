# P.2 — Incremental Compilation Plan

> **Status**: Design document — no compiler source modifications
> **Prior work**: `dep_graph.qz` (working), `qzi.qz` (blocked), `build_cache.qz`/`content_hash.qz` (working)
> **Target**: <1s recompilation for single-file edits during development
> **Date**: Feb 28, 2026

---

## 1. Current Module Loading Architecture

### Entry Point (`quartz.qz`)

```
compile(source, filename, import_paths, ...) → LLVM IR string
```

The compiler performs **whole-program compilation** for every invocation. Even
if only one source file changed, all modules are re-lexed, re-parsed, re-typechecked,
re-MIR'd, and re-codegen'd.

### Resolution Flow (`resolver.qz`)

```
resolve_imports(ast_storage, root, filename, import_paths)
  → for each `import foo` in root's children:
      → resolve_load_module(loaded, loading, all_funcs, base_path, import_paths, module_name, ...)
         → read_file(path)           # I/O: read source
         → lexer_tokenize(source)    # CPU: lex entire module
         → parse_with_state(...)     # CPU: parse entire module
         → resolve_process_imports(...)  # Recurse into module's imports
         → resolve_transform_ufcs(...)  # UFCS rewriting
         → resolve_collect_funcs(...)   # Collect exports into all_funcs
```

**Key observations:**
1. **No caching between invocations**: Each compilation reads, lexes, and parses every module from scratch
2. **Circular dependency protection**: `loaded` vector prevents re-loading within a single compilation
3. **Linear search for loaded modules**: `resolve_is_loaded()` uses `any()` on loaded names
4. **all_funcs flat list**: All imported functions are collected into one flat `Vec` (a 4-element sub-vec per entry: `[ast_storage, node_handle, prefixed_name, tag]`)

### Module Discovery Path Resolution

Modules are located by trying paths in order:
1. `base_path/module_name.qz`
2. `base_path/module_name/mod.qz`
3. `base_path/frontend/module_name.qz` (if non-hierarchical)
4. `base_path/middle/module_name.qz`
5. `base_path/backend/module_name.qz`
6. Each `-I` include path: `include_path/module_name.qz`

### Dependency Graph Shape

For self-compilation, the import tree looks like:

```
quartz.qz
├── lexer (→ token_constants)
├── parser (→ ast, token_constants, node_constants, compiler_types)
├── macro_expand (→ ast, node_constants)
├── derive (→ ast, node_constants)
├── resolver (→ lexer, parser, ast, node_constants)
├── hir
├── mir (→ ast, elem_width, op_constants, node_constants, compiler_types, type_constants)
├── mir_lower (→ mir, ast, ...)
├── mir_opt, egraph, egraph_opt, domtree
├── codegen (→ mir, codegen_util, codegen_intrinsics, codegen_runtime, op_constants)
├── typecheck (→ typecheck_util, typecheck_registry, typecheck_builtins, ...)
├── typecheck_walk
├── liveness
├── diagnostic, explain
├── content_hash, build_cache
└── std/* (qspec, collections, io, etc.)
```

**~35+ modules** loaded during self-compilation. Std modules are loaded transitively
when `import * from qspec` or similar appears.

### Build Cache (`build_cache.qz` + `content_hash.qz`)

The compiler already has a **whole-file cache** (Phase 3.5 in `quartz.qz`):
- After resolution, compute SHA-256 of all source files + config
- If the combined cache key matches, return cached LLVM IR
- Cache stored in `.quartz-cache/` directory

**Limitation**: This is all-or-nothing. If ANY source file changes, the entire cache
is invalidated. For self-compilation, editing one file invalidates everything.

---

## 2. What To Cache

### Option A: Cached Parsed AST (Moderate Impact)

Cache the result of lex + parse for each module:
- **Key**: SHA-256 of module source file
- **Value**: Serialized AST (the 12 parallel vectors from AstStorage)
- **Invalidation**: Source file content changes → invalidate that module's AST cache
- **Impact**: Eliminates re-lexing and re-parsing of unchanged modules

**Savings estimate**: Lex+parse is ~30-40% of compilation time for typical workloads.
For self-compilation, ~35 modules × (lex + parse) time.

**Complexity**: MEDIUM — requires AstStorage serialization/deserialization. The prior
`qzi.qz` attempt was blocked by the chained field access cross-module bug.

### Option B: Cached Typed AST (High Impact)

Cache the result of lex + parse + typecheck for each module:
- **Key**: SHA-256 of source file + SHA-256 of all import signatures
- **Value**: Serialized typed AST + type registry entries for this module
- **Invalidation**: Source changes, OR any imported module's signature changes
- **Impact**: Eliminates re-typechecking unchanged modules

**Savings estimate**: Typecheck is ~30-40% of compilation time.

**Complexity**: HIGH — requires serializing TypecheckState modifications per-module.
Currently typecheck operates on a single global TypecheckState.

### Option C: Cached LLVM IR per Module (Highest Impact)

Cache the final LLVM IR output for each module:
- **Key**: SHA-256 of source + all transitive dependencies
- **Value**: LLVM IR text for this module's functions
- **Invalidation**: Source changes, OR any transitive dependency changes
- **Impact**: Eliminates ALL recompilation for unchanged modules

**Savings estimate**: If 34/35 modules are unchanged, only 1 module needs full pipeline.

**Complexity**: VERY HIGH — requires splitting LLVM IR emission per-module. Currently
codegen emits one monolithic IR output with all functions, globals, and extern declarations
interleaved. This is essentially P.3 (Separate Compilation).

### Recommended Approach: Option A First, Then B

Option A (AST cache) gives the best complexity-to-impact ratio and is partially
implemented (dep_graph.qz works, content_hash.qz works). The qzi.qz serialization
bug needs to be fixed or worked around.

---

## 3. Cache Architecture

### Directory Structure

```
.quartz-cache/
├── manifest.json           # Module → cache key → cache file mapping
├── dep_graph.txt           # Module dependency DAG (from dep_graph.qz)
├── ast/
│   ├── <sha256>.qzast      # Serialized AstStorage for module
│   └── ...
└── ir/                     # Future: per-module LLVM IR cache
    ├── <sha256>.ll
    └── ...
```

### Cache Key Computation

For each module `M`:
```
key(M) = SHA-256(
  source_content(M),
  for each import I of M:
    key(I)    # Recursive — transitively includes all dependencies
)
```

This ensures that changing a leaf module invalidates all modules that import it.

`content_hash.qz` already provides `content_hash(source)` and `content_hash_combine(hashes)`.

### Dependency DAG

`dep_graph.qz` already implements:
- `depgraph_add_dep(graph, from, to)` — register dependency
- `depgraph_topo_sort(graph)` — topological ordering
- `depgraph_invalidate(graph, changed)` — BFS invalidation from changed nodes
- `depgraph_save(graph, path)` / `depgraph_load(path)` — persistence

The graph captures `module_name → [imports]` relationships. When a file changes:
1. Load existing dep graph
2. Find changed module(s) by comparing file hashes
3. `depgraph_invalidate(graph, changed_modules)` returns set of invalidated modules
4. Only recompile invalidated modules; load cached AST for others

### AstStorage Serialization

The blocked `qzi.qz` used a 35-field struct that triggered chained field access bugs.

**Alternative approach**: Serialize AstStorage's 12 parallel vectors directly, without
a wrapper struct. Each vector is written as `count:element:element:...` lines.

```quartz
def ast_serialize(store: AstStorage, out: StringBuilder): Void
  # Vec<Int> vectors: write as space-separated integers
  serialize_vec_int(out, store.kinds)
  serialize_vec_int(out, store.lines)
  serialize_vec_int(out, store.cols)
  serialize_vec_int(out, store.int_vals)
  # Vec<String> vectors: write as length-prefixed strings
  serialize_vec_string(out, store.str1s)
  serialize_vec_string(out, store.str2s)
  # ... etc for all 12 vectors
end
```

**Workaround for chained field access bug**: Extract each vector into a local variable
before serializing: `var kinds = store.kinds; serialize_vec_int(out, kinds)`.

---

## 4. Incremental Rebuild Algorithm

### On Compilation

```
1. Read existing dep_graph and manifest from .quartz-cache/
2. Resolve all imports (get module list + dependency edges)
3. Hash each module's source file
4. For each module:
   a. If source_hash matches manifest entry → CACHE HIT
      - Load cached AstStorage from .quartz-cache/ast/<hash>.qzast
      - Add to all_funcs via resolve_collect_funcs (with cached AST)
   b. If source_hash differs → CACHE MISS
      - Lex + parse module normally
      - Serialize AstStorage to cache
      - Update manifest
5. Run transitive invalidation:
   - If module M is MISS, ALL modules that import M (directly or transitively)
     must also be re-typechecked
   - BUT their AST caches are still valid if their source didn't change
6. Continue with typecheck → MIR → codegen using hybrid (cached + fresh) ASTs
7. Save updated dep_graph and manifest
```

### Invalidation Granularity

| What Changed | What Needs Recompilation |
|-------------|------------------------|
| Module source | That module (re-lex, re-parse, re-typecheck, re-MIR, re-codegen) |
| Imported module's exports | All importers need re-typecheck (but NOT re-parse) |
| Compiler flags (`-O`, `--target`) | Everything (flags are part of cache key) |
| Compiler version | Everything (version string is part of cache key) |

---

## 5. File Changes Required

### Core Changes

| File | Change | Complexity |
|------|--------|:----------:|
| `quartz.qz` | Cache integration point: check cache before full pipeline | Medium |
| `resolver.qz` | Return cached AST when available instead of re-lexing | Medium |
| `shared/build_cache.qz` | Extend to per-module caching (currently whole-file only) | Medium |
| `shared/dep_graph.qz` | Already done — wire into quartz.qz pipeline | Low |
| `shared/content_hash.qz` | Already done — used for cache keys | None |
| `frontend/ast.qz` | Add `ast_serialize()` / `ast_deserialize()` | High |

### New Files

| File | Purpose |
|------|---------|
| `shared/ast_cache.qz` | Cache management: serialize, deserialize, lookup, store |
| `spec/qspec/ast_cache_spec.qz` | Serialization round-trip tests |

### Files NOT Changed

All typecheck, MIR, and codegen files remain unchanged in Phase 1.
They continue to receive AstStorage and all_funcs as before — they don't
know whether the AST came from parsing or from cache.

---

## 6. Estimated Impact Per Phase

| Phase | What's Cached | Single-File Edit Time | Full Rebuild Time |
|-------|---------------|:---------------------:|:-----------------:|
| Current | Nothing (per-module) | ~15.6s | ~15.6s |
| AST cache | Lex + Parse | ~10–12s | ~15.6s (all miss) |
| Typed AST cache | + Typecheck | ~5–7s | ~15.6s |
| IR cache | Everything | ~1–3s | ~15.6s |

The AST cache alone should save 25–35% on single-file edits, since lex+parse
of ~35 unchanged modules is avoided. The biggest wins come from typed AST and
IR caching, but those have much higher implementation complexity.

---

## 7. Prerequisites and Blockers

### Must Fix First

1. **Cross-module chained struct field access** (Bug #4 in P2_P3_INCREMENTAL_PAUSED.md):
   `data.struct_names.size` resolves to offset 0 instead of offset 1. This blocks any
   struct-based serialization approach. Workaround: extract to local variable.

2. **Cross-module UFCS String methods** (Bug #3): `.char_at()`, `.slice()`, `.contains()`
   don't resolve cross-module. Workaround: use `str_char_at()` etc.

### Can Work Around

3. **Global variable reassignment** (Bug #1): Use `vec_clear()` instead of reassigning.
4. **`str_split` trailing empty** (Bug #5): Already fixed (CMF phase).

### Not Required

- String interning (P.5) — nice to have, not a dependency
- Separate compilation (P.3) — blocked by P.2, comes after

---

## 8. Implementation Order

1. **Fix the chained field access bug** — or implement serialization using
   local variable extraction as workaround
2. **Implement ast_serialize/ast_deserialize** in `frontend/ast.qz` or new
   `shared/ast_cache.qz`
3. **Wire dep_graph.qz into resolver.qz** — build dependency graph during
   module resolution
4. **Add cache check to resolver** — before `read_file(path)`, check if cached
   AST exists with matching hash
5. **Add manifest management** — track module → hash → cache file mapping
6. **Update quartz.qz** — integrate cache check into compilation pipeline
7. **Write tests** — round-trip serialization, cache hit/miss, invalidation

### Verification

- `quake build` — compiler builds with caching enabled
- `quake qspec` — all tests pass
- `quake fixpoint` — gen1 == gen2 (caching doesn't affect output)
- Manual test: edit one file, re-compile, verify faster than full rebuild
