# Generic Structs & Enums Roadmap

> **Goal**: Full generic type parameter support for user-defined structs and enums.
> Prerequisite for `Array<T, const N: Int>` (Phase 8 const-param arrays).

## Status Quo

### What Works
- **Parser**: `ps_parse_optional_type_params()` already parses `<T, E>` for both structs
  and enums, stores in AST `str2s` slot
- **C bootstrap enums**: Full pipeline — `EnumDef.type_param_names` → `type_enum_generic()`
  → variant field annotation tracking → inference from construction
- **C bootstrap structs**: Full pipeline — `StructDef.type_param_names` → `type_struct_generic()`
  → field annotation tracking → depth-aware type arg parsing (added in G1.1)
- **Hardcoded collections**: `Vec<T>`, `HashMap<K,V>`, `Option<T>`, `Result<T,E>` work via
  dedicated `strncmp` branches in `tc_parse_type_annotation` (not true generics)
- **Self-hosted TypeStorage**: 8 parallel vectors including `type_params` — stores type param
  info for both definitions and instantiations (added in G1.2)
- **Self-hosted TypecheckState**: `struct_type_params` and `enum_type_params` registry vectors —
  stores type params from AST during registration (added in G1.3)
- **Self-hosted tc_parse_type**: Resolves `Foo<T>` syntax — looks up base name in struct/enum
  registries, returns correct TYPE_STRUCT/TYPE_ENUM (added in G1.3)

### What Doesn't Work Yet
- **Field type substitution**: No mapping from type params to concrete type args during field access
- **Construction type checking**: No verification that field initializers match substituted types
- **Type argument inference**: No inference from construction context
- **Pattern matching propagation**: Type args not propagated through pattern bindings
- **Extend blocks with type params**: Type params not in scope during extend methods

---

## Phase G1: Generic Type Infrastructure (COMPLETE)

**Objective**: Store, register, and resolve generic type parameters + arguments.
No semantic checking yet — just make `Pair<Int, String>` parse into a real type.

### G1.1 — C Bootstrap: StructDef Generics (COMPLETE)

**Files**: `types.h`, `types.c`, `typecheck.c`

1. Add to `StructDef`:
   ```c
   const char** type_param_names;  // ["T", "U"] for struct Pair<T, U>
   int type_param_count;
   const char** field_annotations; // original type strings for param mapping
   ```

2. Add `type_struct_generic()` in `types.c`:
   ```c
   Type* type_struct_generic(TypeArena* arena, const char* name, StructDef* def,
                             Type** type_args, int type_arg_count);
   ```
   - Mirror `type_enum_generic()` — non-interned, copies type_args into arena
   - Expand `data.strukt` in the Type union:
     ```c
     struct {
         const char* name;
         StructDef* def;
         Type** type_args;      // NEW
         int type_arg_count;    // NEW
     } strukt;
     ```

3. Update `register_struct_def()` in `typecheck.c`:
   - Copy `type_params` from AST node into `StructDef.type_param_names`
   - Store field type annotation strings in `StructDef.field_annotations`

4. Update `tc_parse_type_annotation()` Phase 7 (line ~1645):
   - Currently: `if (gsd) return type_struct(ctx->arena, base_name, gsd);` — discards args
   - Change to: parse type args (same comma-split logic as enum path), call
     `type_struct_generic()` if args present

5. Rebuild bootstrap: `make -C ../quartz-bootstrap`

**Tests**: Write Quartz programs that declare `struct Pair<T, U> { first: T, second: U }`
and use `Pair<Int, String>` in type annotations. Verify no crash, correct type stored.

### G1.2 — Self-Hosted: TypeStorage type_params Vector (COMPLETE)

**File**: `self-hosted/middle/types.qz`

1. Add 8th parallel vector: `type_params: Vec<String>`
   - Stores comma-joined type param names for definitions (e.g., `"T,U"`)
   - Stores comma-joined concrete type handles for instantiations (e.g., `"5,12"`)

2. Update constructors:
   ```
   type_struct(s, name, fields)       → type_struct(s, name, fields, type_params)
   type_enum(s, name, variants)       → type_enum(s, name, variants, type_params)
   ```
   - Default `type_params = ""` for backward compat

3. Add `type_struct_generic(s, name, fields, type_args): Int` — returns new handle
   with type_args stored. Not interned (same semantics as bootstrap).

4. Add `type_get_type_params(s, handle): String` accessor.

### G1.3 — Self-Hosted: TypecheckState Registration (COMPLETE)

**File**: `self-hosted/middle/typecheck.qz`

1. Add registries:
   ```
   struct_type_params: Vec<String>    # parallel to struct_names, stores "T,U"
   enum_type_params: Vec<String>      # parallel to enum_names, stores "T,E"
   ```

2. Update `tc_register_struct_def`:
   - Read `str2` (type_params) from AST node
   - Store in `struct_type_params` registry
   - Store field type annotation strings for later substitution

3. Update `tc_register_enum_def`:
   - Same — read and store `str2` type_params

4. Update `tc_parse_type` (line ~2075):
   - Add `strchr(name, '<')` check before the final `TYPE_UNKNOWN` fallback
   - Extract base name, look up struct/enum def
   - Parse comma-separated type args between `<` and `>`
   - Call `type_struct_generic()` or `type_enum_generic()`
   - **Use depth-aware comma splitting** (fix the naive bootstrap bug)

**Tests**: `struct Pair<T, U> { first: T, second: U }` with `x: Pair<Int, String>` annotation
resolves to a type with correct type_args.

---

## Phase G2: Generic Struct Semantics

**Objective**: Make generic structs actually type-check — field resolution, construction,
inference, pattern matching.

### G2.1 — Field Type Substitution

When accessing `pair.first` where `pair: Pair<Int, String>`:

1. Look up `StructDef` → field `first` has annotation `"T"`
2. Match `"T"` against `type_param_names[0]` → index 0
3. Return `type_args[0]` → `Int`

**Implementation**: Add `tc_resolve_field_type(struct_type, field_name)` that performs
this substitution. Called from field access typechecking.

Same logic for enum variant payloads — already partially exists in bootstrap but needs
self-hosted implementation.

### G2.2 — Construction Type Checking

For `Pair<Int, String> { first: 42, second: "hello" }`:

1. Parse type annotation → `Pair<Int, String>` with type_args `[Int, String]`
2. For each field initializer, substitute type params in field type
3. Check initializer expression type matches substituted field type

For `Pair { first: 42, second: "hello" }` (inferred):

1. Type-check each field initializer independently
2. Build type_args array from inferred types: `[Int, String]`
3. Return `Pair<Int, String>`

### G2.3 — Type Argument Inference from Construction

When constructing without explicit type args:
```
p = Pair { first: 42, second: "hello" }
# Infer: p: Pair<Int, String>
```

**Strategy**: Same as bootstrap enum inference (typecheck.c:4723-4755) —
check each field's type, map to the type param via annotation string, build type_args.

### G2.4 — Pattern Matching

```
match pair
  Pair { first: x, second: y } =>
    # x: Int, y: String (from Pair<Int, String>)
```

Propagate type_args through pattern bindings using same substitution logic as G2.1.

### G2.5 — Extend Blocks

```
extend Pair<T, U>
  def swap(): Pair<U, T>
    Pair { first: self.second, second: self.first }
```

- `self` type is `Pair<T, U>` with `T`, `U` as type parameters in scope
- Methods can reference type params in signatures and bodies
- Instantiation: `pair.swap()` where `pair: Pair<Int, String>` → returns `Pair<String, Int>`

---

## Phase G3: Unify & Harden (PARTIAL)

**Objective**: Migrate hardcoded special types to true generics. Harden edge cases.

### G3.0 — Parameterized Type Interning (COMPLETE)

Self-hosted compiler now tracks type parameters for all builtin generic types via an
interning system:

- `PTYPE_BASE = 100000` — parameterized type IDs start here
- `tc_make_ptype(tc, base, arg1, arg2)` — intern parameterized types; same base+args → same ID
- `tc_base_kind(tc, t)` — resolve ptype to bare TYPE_VEC/TYPE_HASHMAP/etc.
- `tc_parse_type` creates ptypes for: `CPtr<T>`, `Vec<T>`, `Array<T>`, `HashMap<K,V>`, `Option<T>`, `Result<T,E>`
- UFCS dispatch normalized at 4 sites: `tc_get_type_alias`, call dispatch, field access, index access
- `tc_types_match` handles ptype equality via interned IDs

**Note**: C bootstrap already had full generic type support (Type struct with elem/key/value fields).
Self-hosted now has equivalent tracking via the ptype system.

### G3.1 — Propagate Element Types Through Builtins (COMPLETE)

| Current | Target | Status |
|---------|--------|--------|
| `TYPE_OPTION` (kind 10) | `Option<T>` generic enum | Tracked via ptypes |
| `TYPE_RESULT` (kind 11) | `Result<T, E>` generic enum | Tracked via ptypes |
| `TYPE_VEC` (kind 12) | `Vec<T>` generic struct | **Propagated** via ptypes |
| `TYPE_HASHMAP` (kind 13) | `HashMap<K, V>` generic struct | **Propagated** via ptypes |

**Completed Feb 10, 2026**: Element type propagation through builtin return types.
`vec_get` on `Vec<String>` now returns `TYPE_STRING`. `hashmap_get` on `HashMap<K,V>`
returns value type. `hashmap_keys`/`hashmap_values` return typed `Vec<K>`/`Vec<V>`.

Changes:
- Fixed `ast_let` to store type annotations in str2 (was always 0)
- `var v: Vec<String>` annotation → `tc_parse_type` → ptype stored in binding
- `vec_new<T>()` / `hashmap_new<K,V>()` return ptypes
- After builtin return type resolved, check receiver ptype and substitute
- `tc_type_name_full(tc, t)` renders ptypes as `Vec<String>`
- Backward compat: bare `TYPE_VEC` (no ptype) → returns `TYPE_INT` as before

### G3.2 — Type Equality for Generics (COMPLETE in self-hosted)

Self-hosted uses interned ptype IDs — same base+args → same ID, so equality is
just integer comparison. Different interned IDs = different types.

C bootstrap uses deep equality in `types_equal_deep` — compares type args recursively.

### G3.3 — Depth-Aware Comma Splitting (COMPLETE)

Both compilers use depth-tracking when parsing nested generic type args like
`Result<HashMap<K,V>, String>`. Self-hosted uses `tc_extract_nth_type_arg` with
angle-bracket depth counting.

### G3.4 — Error Messages (COMPLETE)

**Completed Feb 10, 2026**: Ptype-aware error messages and element type checking.

- `tc_type_name_full` renders ptypes in errors: "Type mismatch: expected Vec<String> but got Int"
- `tc_error_type_mismatch` and `tc_error_match_arm_mismatch` use `tc_type_name_full`
- Element type checking for `vec_push`/`vec_set` on typed Vecs
- Arity mismatch and raw generic warnings deferred (not yet needed)

### G3.5 — Harden Edge Cases (COMPLETE)

**Completed Feb 10, 2026**: 8 new edge case tests added, all passing.

- Nested ptype instantiation: `Vec<Vec<Int>>`, `HashMap<String, Vec<Int>>`
- Generic structs: `Box<T>`, `Pair<T, U>` with field access
- Generic enums: `Option<Int>`, `Result<Int, String>` with pattern matching
- Backward compat: bare Vec matches Vec<T> in function params
- Still future work: recursive types (`Node<T>` with `Option<Node<T>>`), generic aliases

---

## Implementation Order & Dependencies

```
G1.1 (C bootstrap StructDef)
  ├── G1.2 (TypeStorage vector) ──── requires G1.1 to compile self-hosted
  └── G1.3 (TypecheckState)    ──── requires G1.2
        │
        ▼
G2.1 (Field substitution) ────────── requires G1.3
  ├── G2.2 (Construction checking)
  ├── G2.3 (Inference)
  ├── G2.4 (Pattern matching)
  └── G2.5 (Extend blocks)
        │
        ▼
G3.1 (Migrate built-ins) ─────────── requires G2 complete
G3.2 (Type equality) ─────────────── can start after G1
G3.3 (Depth-aware splitting) ─────── can start after G1
G3.4 (Error messages) ─────────────── throughout G2
G3.5 (Edge cases) ────────────────── after G2 complete
```

## Key Design Decisions

1. **No monomorphization**: Runtime is existential i64. Generic types exist purely for
   type-checking. No code duplication per instantiation.

2. **Non-interned generic types**: `Pair<Int, String>` allocates fresh `Type*` each time
   (same as `type_enum_generic`). Use deep equality, not pointer equality.

3. **Annotation-based substitution**: Store original field type annotation strings (like `"T"`)
   alongside resolved types. At instantiation, map annotation → param index → concrete type.
   This avoids needing a separate "unresolved type" representation.

4. **Parallel vector storage** (self-hosted): Add `type_params` as 8th vector in TypeStorage.
   Keeps the flat indexing model. Encode as comma-joined strings.

5. **Bootstrap first**: Each G1 substep starts in C bootstrap, then self-hosted. This ensures
   the self-hosted compiler can be compiled with the new features.

6. **Don't unify special types immediately**: Build generic infrastructure alongside hardcoded
   `TYPE_OPTION`/`TYPE_VEC`/etc. Migrate only after generics are proven stable (G3.1).

## Relation to Phase 8 (Const Evaluation)

Phase 8 adds `Array<T, const N: Int>` — a fixed-size array with compile-time size.
This requires:
- **Generic type params** (this roadmap) — for `T`
- **Const type params** (Phase 8) — for `const N: Int`

Const params are a separate concern: they affect codegen (stack allocation size) while
type params are erased at runtime. This roadmap handles type params only. Const params
will layer on top using the same TypeStorage infrastructure (additional vectors or
extending the `type_params` encoding).
