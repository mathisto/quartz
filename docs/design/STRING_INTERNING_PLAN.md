# P.5 — String Interning Plan

> **Status**: Design document — no compiler source modifications
> **Target**: Reduce self-compilation time from ~15.6s to <5s via string allocation elimination
> **Date**: Feb 28, 2026

---

## 1. Profiling Results

### Baseline Measurement

```
Self-compilation: ~63,794 lines across 48 .qz source files
Wall time:   15.585s
User time:    9.879s
System time:  1.619s (11.5s CPU, ~3.5× slower than ROADMAP's 8.4s target)
```

The ROADMAP records 8.4s after the length-prefixed string optimization (P.5-LP). The
current measurement of ~15.6s likely reflects additional compiler complexity added since
that measurement (intersection types, safety audit, stress tests, derive macros, etc.
— the compiler grew from ~1,357 functions to ~1,466+ functions).

### Compiler Pipeline Phase Structure

From `quartz.qz`, the compilation pipeline for a self-compile invocation processes:

| Phase | Description | Bottleneck Hypothesis |
|-------|-------------|----------------------|
| 1 | **Lexer** — tokenize source file | Moderate: 1 string allocation per token |
| 2 | **Parser** — build AST | Heavy: 12 parallel vectors per node, str1+str2 allocations |
| 2.4 | **Derive** — expand @derive annotations | Light |
| 2.5 | **Macros** — expand user macros | Light |
| 3 | **Resolver** — import resolution | Heavy: re-lex + re-parse each of ~35+ imported modules |
| 3.5 | **Build cache** — content hash check | Light (SHA-256 per source file) |
| 4.0a-e | **Type registration** — structs/enums/traits/impls/consts/globals | Moderate |
| 4.1 | **Signature registration** — function signatures | Moderate |
| 4.2 | **Liveness** — NLL pre-pass | Moderate |
| 4.3 | **Typecheck** — `tc_program` + `tc_function` for all modules | Heavy: ~3,167 lines typecheck.qz + ~5,763 lines typecheck_walk.qz |
| 5 | **MIR lowering** — `mir_lower_all` | Heavy: ~6,021 lines mir_lower.qz |
| 5.5 | **MIR optimization** — e-graph optimizer | Moderate |
| 6 | **Codegen** — emit LLVM IR | Heavy: ~2,070 + ~8,499 lines codegen + codegen_intrinsics |

### String Allocation Hotspots

**The compiler's dominant allocation pattern is strings.** Every identifier, type name,
function name, and error message is a heap-allocated `String` (length-prefixed since P.5-LP).

Key allocation sites:

| Source | `vec_new<String>` calls | `.push(string)` calls | Per-invocation estimate |
|--------|------------------------:|---------------------:|------------------------:|
| `lexer.qz` | 1 | 28 | ~N tokens × 4 vectors (but lexemes Vec<String>) |
| `parser.qz` | 6 | 105 | ~N nodes × str1/str2 pushes |
| `ast.qz` | 3 | 927 (total pushes) | 12 pushes per AST node — 2 are String vectors |
| `typecheck.qz` | 48 | — | Registries: struct names, field names, enum names, etc. |
| `mir.qz` + `mir_lower.qz` | 40 | — | Variable bindings, instruction names, string pools |
| `codegen.qz` | 0 | — | Builds IR strings (StringBuilder) |
| `resolver.qz` | 7 | — | Module paths, loaded paths, prefixed names |
| `quartz.qz` | 12 | — | CLI, import paths, cache hashes |

**Estimated string allocations per self-compile:**

The compiler sources total ~63,794 lines. Estimating:
- ~200,000 tokens → ~200,000 `lexeme` string allocations (one per token)
- ~60,000 AST nodes → ~120,000 `str1`/`str2` string pushes (2 per node)
- TypecheckState registries: ~50 `Vec<String>` vectors, each growing during compilation
- MIR: variable names, instruction labels, string pool entries

**Conservative estimate: 400,000–600,000 string allocations during self-compilation.**

Among these, a large fraction are **duplicate identifier strings**. The same identifiers
(`Int`, `String`, `Vec`, `Bool`, `Void`, `var`, `def`, `end`, function names, type names)
appear thousands of times and are allocated fresh each time.

### Deduplication Potential

Common identifiers across the compiler source:
- Keywords: `def`, `end`, `if`, `else`, `return`, `var`, `while`, `for`, `in` — appear in ~90% of lines
- Built-in types: `Int`, `String`, `Bool`, `Void`, `Vec`, `HashMap` — thousands of occurrences
- Field names: `size`, `push`, `get`, `set` — repeated per node access
- Operator strings: `+`, `-`, `*`, `/`, `==`, `!=` — appear in codegen string building

If 60–70% of string allocations are duplicates (conservative for a compiler that processes
its own source), interning would eliminate **250,000–400,000 allocations**.

---

## 2. String Interner Design

### API

```quartz
# A string interner returns integer handles instead of heap-allocated strings.
# The interner owns all string data; handles are just indices.

newtype InternId = Int

struct StringInterner
  strings: Vec<String>       # handle → string (indexed lookup)
  lookup: HashMap<String, Int>  # string → handle (dedup lookup)
end

def intern_new(): StringInterner
  return StringInterner {
    strings: vec_new<String>(),
    lookup: hashmap_new<String, Int>()
  }
end

## Intern a string. Returns existing handle if already interned,
## otherwise stores the string and returns a new handle.
def intern(interner: StringInterner, s: String): InternId
  var existing = interner.lookup.get(s)
  if existing >= 0
    return existing
  end
  var id = interner.strings.size
  interner.strings.push(s)
  interner.lookup.set(s, id)
  return id
end

## Resolve an interned handle back to its string.
def intern_resolve(interner: StringInterner, id: InternId): String
  return interner.strings[id]
end
```

### Storage Model

```
StringInterner
├── strings: Vec<String>          # Dense array: handle → string value
│   [0] = "Int"
│   [1] = "String"
│   [2] = "Bool"
│   [3] = "main"
│   [4] = "def"
│   ...
└── lookup: HashMap<String, Int>  # Hash map: string → handle
    "Int" → 0
    "String" → 1
    ...
```

**Characteristics:**
- O(1) amortized intern (HashMap lookup + optional insert)
- O(1) resolve (Vec index)
- Memory: one copy of each unique string + HashMap overhead
- Thread-unsafe (single-threaded compiler — fine)

### Integration Points

The interner would be a **global singleton** passed through the pipeline. Every phase
that currently stores `String` identifiers would instead store `InternId` handles.

---

## 3. Migration Strategy

### Phase 1: Lexer Integration (Highest Impact)

**Goal:** Intern all identifier and keyword tokens at lex time.

**Current** (lexer.qz):
```
LexerResult {
  types: Vec<Int>,      # token types — keep as-is
  lexemes: Vec<String>, # ← each token is a heap-allocated string
  lines: Vec<Int>,      # line numbers — keep as-is
  cols: Vec<Int>        # column numbers — keep as-is
}
```

**After:**
```
LexerResult {
  types: Vec<Int>,
  lexemes: Vec<InternId>,  # ← intern IDs instead of strings
  lines: Vec<Int>,
  cols: Vec<Int>,
  interner: StringInterner # ← shared interner
}
```

**Files changed:** `lexer.qz`
**Impact:** Eliminates ~200,000 string allocations, reduces Vec<String> to Vec<Int>

### Phase 2: Parser/AST Integration

**Goal:** Store interned IDs in AST string slots (str1, str2, str3).

**Current** (ast.qz):
```
struct AstStorage
  ...
  str1s: Vec<String>   # ← primary names (identifiers, type names)
  str2s: Vec<String>   # ← secondary names (type annotations)
  str3s: Vec<String>   # ← tertiary (type params)
  ...
end
```

**After:**
```
struct AstStorage
  ...
  str1s: Vec<InternId>   # handles into shared interner
  str2s: Vec<InternId>
  str3s: Vec<InternId>
  ...
end
```

**Files changed:** `ast.qz`, `parser.qz`
**Impact:** Eliminates ~120,000 AST string allocations
**Risk:** All downstream consumers of `ast_get_str1()` etc. must be updated to resolve via interner

### Phase 3: Typecheck Registry Integration

**Goal:** Use InternId for type/function name lookups.

**Current** (typecheck.qz / typecheck_util.qz):
```
struct TcRegistry
  struct_names: Vec<String>
  enum_names: Vec<String>
  func_names: Vec<String>
  ...
end
```

**After:** Store `Vec<InternId>` and use integer comparison instead of string comparison
for name lookups. This changes name resolution from O(n × strlen) to O(n × 1).

**Files changed:** `typecheck.qz`, `typecheck_util.qz`, `typecheck_registry.qz`, `typecheck_builtins.qz`, `typecheck_walk.qz`
**Impact:** Faster type lookups, reduced memory churn

### Phase 4: MIR & Codegen Integration

**Goal:** Use InternId for variable bindings and function references in MIR.

**Files changed:** `mir.qz`, `mir_lower.qz`, `codegen.qz`, `codegen_util.qz`, `codegen_intrinsics.qz`
**Risk:** Codegen builds LLVM IR strings using actual string values — this phase needs the interner to _resolve_ IDs back to strings for IR emission. The interner speeds up everything _before_ final IR emission.

### Recommended Order

1. **Phase 1: Lexer** — highest impact, lowest risk, self-contained
2. **Phase 2: AST** — requires updating all `ast_get_str1/str2/str3` callers
3. **Phase 3: Typecheck** — large surface area but mechanical
4. **Phase 4: MIR/Codegen** — lowest priority, most complex

Each phase should be independently buildable and fixpoint-verifiable.

---

## 4. Risk Assessment

### Fixpoint Implications

The interner changes the internal representation but **not the output**. The compiler
still emits identical LLVM IR. However:

1. **Order sensitivity**: The interner assigns sequential IDs. If the intern order changes
   between gen1 and gen2, the compiler's internal state differs, but the output IR should
   be identical because IDs are always resolved back to strings for codegen.

2. **Two-stage bootstrap**: Like the length-prefixed string migration (P.5-LP), this may
   require gen0 → gen1 → gen2 → gen3 with gen2==gen3 verification, since gen0 (current
   compiler) doesn't have the interner but gen1 does.

3. **HashMap determinism**: The interner's HashMap must produce deterministic iteration
   order. Since we use `intern()` for lookup and `intern_resolve()` for output, and
   codegen resolves IDs to strings, the output is independent of HashMap order.

### Breaking Changes

- `ast_get_str1()` return type changes from `String` to `InternId` (or we keep a wrapper
  that auto-resolves — safer but slower)
- Every file that calls `ast_get_str1()` etc. needs updating
- The interner must be thread-safe or single-threaded — currently fine since the compiler
  is single-threaded

### Mitigation

- **Incremental migration**: Use a wrapper `ast_get_str1_resolved(store, handle, interner)`
  that resolves automatically. Gradually migrate callers to use raw InternId.
- **One phase at a time**: Each phase should build + test + fixpoint before proceeding.
- **Escape hatch**: If a phase breaks, revert and use the previous binary.

---

## 5. Estimated Impact

| Optimization | Est. Allocations Eliminated | Est. Time Reduction |
|-------------|---------------------------:|--------------------:|
| Lexer interning | ~200,000 | 2–3s |
| AST interning | ~120,000 | 1–2s |
| Typecheck interning | ~50,000 | 0.5–1s |
| MIR interning | ~30,000 | 0.3–0.5s |
| **Total** | **~400,000** | **4–7s** |

If self-compilation drops from ~15.6s to ~8–11s, that's a meaningful improvement.
Combined with other optimizations (arena allocation for AST nodes, Vec preallocation),
the <5s target may be achievable.

### Additional Optimizations (Not In Scope)

These complement interning but are separate work items:

1. **Arena AST allocation**: Instead of 12 parallel Vecs with individual pushes, use one
   contiguous arena with fixed-size AST node records.
2. **StringBuilder pooling**: Reuse StringBuilder instances instead of creating new ones.
3. **Vec preallocation**: `vec_new_with_capacity<String>(estimated_tokens)` avoids resizing.
4. **Lazy module loading**: Don't re-lex/re-parse unchanged modules (this is P.2 incremental compilation).
5. **Parallel module compilation**: Lex/parse modules in parallel (blocked by single-threaded interner).

---

## 6. Implementation Checklist

- [ ] Create `self-hosted/shared/string_intern.qz` with `StringInterner` struct
- [ ] Add QSpec tests for interner (`spec/qspec/string_intern_spec.qz`)
- [ ] Phase 1: Integrate into lexer.qz, update LexerResult
- [ ] Phase 1: Update all LexerResult consumers (parser.qz)
- [ ] Build + QSpec + Fixpoint after Phase 1
- [ ] Phase 2: Change AstStorage str1s/str2s/str3s to Vec<InternId>
- [ ] Phase 2: Update all ast_get_str1/str2/str3 callers (or add resolved wrappers)
- [ ] Build + QSpec + Fixpoint after Phase 2
- [ ] Phase 3: Change TcRegistry string vectors to InternId
- [ ] Build + QSpec + Fixpoint after Phase 3
- [ ] Phase 4: Change MIR bindings to InternId
- [ ] Build + QSpec + Fixpoint after Phase 4
- [ ] Final profiling measurement — compare against baseline
