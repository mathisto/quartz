# C Backend Design

## Status: Design Document (Not Implemented)

## Motivation

The current Quartz compiler emits LLVM IR, requiring LLVM (`llc`) and `clang` as external dependencies. A C backend would:

- Remove the LLVM dependency (~500MB) for end users
- Enable compilation on any platform with a C compiler
- Provide a readable intermediate form for debugging
- Enable bootstrapping on systems without LLVM
- Simplify cross-compilation (C compilers exist for every target)

## Current LLVM Codegen Architecture

The existing pipeline (codegen.qz, ~2,400 lines):

```
MIR Program → cg_emit_function() per function → LLVM IR string → llc → clang → Binary
```

Key components:
- `cg_emit_function()` (codegen.qz:1259): Emit function prologue, allocas, blocks
- `cg_emit_instr()` (codegen.qz:130): Dispatch MIR instructions to LLVM IR
- `cg_emit_intrinsic()` (codegen_intrinsics.qz:490): 407 intrinsics across 16 categories
- `cg_emit_runtime_decls()` (codegen_runtime.qz:172): C library declarations
- `cg_emit_string_constants()` (codegen_util.qz:385): Length-prefixed string globals

## Type Mapping

Quartz uses an existential type model — everything is `i64` at runtime. This maps trivially to C:

| Quartz Type | LLVM IR | C Type |
|-------------|---------|--------|
| Int | i64 | int64_t |
| Bool | i64 (0/1) | int64_t |
| String | i64 (pointer) | int64_t (cast from char*) |
| Struct | i64 (heap pointer) | int64_t (cast from struct*) |
| Fn(A): B | i64 (fn pointer) | int64_t (cast from fn pointer) |
| Vec\<T\> | i64 (heap pointer) | int64_t (cast from vec header*) |
| F64 | double (bitcast) | double (via union or memcpy) |

The uniform `int64_t` representation makes C emission straightforward — no complex type system mapping needed.

## Architecture

### New Module: codegen_c.qz

Parallel to `codegen.qz`, taking the same MIR input:

```
MIR Program → cg_c_codegen() → C source string → cc -O2 → Binary
```

Estimated size: ~2,000-3,000 lines (vs 2,400 for LLVM backend). Simpler because C handles many things LLVM IR makes explicit (stack management, register allocation, ABI).

### CLI Integration

```bash
# New flag
./quartz --backend c program.qz > program.c
cc -O2 program.c quartz_runtime.c -o program

# Default remains LLVM
./quartz program.qz > program.ll
```

### Function Emission

LLVM IR:
```llvm
define i64 @helper$add(i64 noundef %p0, i64 noundef %p1) {
  %a = alloca i64
  %b = alloca i64
  store i64 %p0, i64* %a
  store i64 %p1, i64* %b
  %v0 = load i64, i64* %a
  %v1 = load i64, i64* %b
  %v2 = add i64 %v0, %v1
  ret i64 %v2
}
```

C equivalent:
```c
int64_t helper__add(int64_t p0, int64_t p1) {
    int64_t a = p0;
    int64_t b = p1;
    int64_t v0 = a;
    int64_t v1 = b;
    int64_t v2 = v0 + v1;
    return v2;
}
```

Note: `$` in function names becomes `__` in C (valid identifier character).

### String Constants

LLVM IR uses length-prefixed packed structs:
```llvm
@.str.0 = private constant <{ i64, [6 x i8] }> <{ i64 5, [6 x i8] c"hello\00" }>
```

C equivalent:
```c
static const struct { int64_t len; char data[6]; } _str_0 = { 5, "hello" };
#define STR_0 ((int64_t)(intptr_t)&_str_0.data[0])
```

### Closure Emission

LLVM IR (tagged pointer with low bit = 1 for closure):
```llvm
; Create closure: malloc env, store fn ptr + captures
%env = call i8* @malloc(i64 24)   ; 3 slots: fn, cap1, cap2
%envp = bitcast i8* %env to i64*
store i64 ptrtoint(@__lambda_0), i64* %envp        ; slot 0: fn pointer
store i64 %captured_x, i64* getelementptr(i64* %envp, 1)  ; slot 1
store i64 %captured_y, i64* getelementptr(i64* %envp, 2)  ; slot 2
%tagged = or i64 ptrtoint(%env), 1   ; tag with low bit
```

C equivalent:
```c
int64_t* env = (int64_t*)malloc(24);
env[0] = (int64_t)(intptr_t)&__lambda_0;  // fn pointer
env[1] = captured_x;                       // capture 1
env[2] = captured_y;                       // capture 2
int64_t tagged = (int64_t)(intptr_t)env | 1;  // tag low bit
```

### Call Dispatch (Plain vs Closure)

```c
int64_t qz_call_1(int64_t fn_val, int64_t arg0) {
    if (fn_val & 1) {
        // Closure: extract env, load fn, call with env
        int64_t* env = (int64_t*)(fn_val & ~1L);
        int64_t (*cfn)(int64_t, int64_t) = (void*)(intptr_t)env[0];
        return cfn((int64_t)(intptr_t)env, arg0);
    } else {
        // Plain function
        int64_t (*pfn)(int64_t) = (void*)(intptr_t)fn_val;
        return pfn(arg0);
    }
}
```

## Intrinsic Mapping

The compiler has 407 intrinsics across 16 categories. Mapping strategy:

### Direct Map (~60%)

Intrinsics that map directly to C library calls:

| Quartz Intrinsic | C Implementation |
|-----------------|------------------|
| puts(s) | puts((char*)(intptr_t)s) |
| str_len(s) | *(int64_t*)((char*)(intptr_t)s - 8) |
| malloc(n) | (int64_t)(intptr_t)malloc(n) |
| free(p) | free((void*)(intptr_t)p) |
| str_from_int(n) | sprintf to malloc'd buffer |
| file_exists(p) | access((char*)p, F_OK) |

### Runtime Library (~30%)

Intrinsics that need helper implementations:

| Quartz Intrinsic | C Runtime Function |
|-----------------|-------------------|
| vec_new\<T\>() | qz_vec_new(elem_width) |
| vec_push(v, x) | qz_vec_push(v, x, elem_width) |
| vec_get(v, i) | qz_vec_get(v, i, elem_width) |
| hashmap_new() | qz_hashmap_new() |
| hashmap_set(m,k,v) | qz_hashmap_set(m, k, v) |
| str_concat(a,b) | qz_str_concat(a, b) |
| str_split(s,d) | qz_str_split(s, d) |
| sb_new() | qz_sb_new() |
| sb_append(sb, s) | qz_sb_append(sb, s) |

### Platform-Specific (~10%)

| Quartz Intrinsic | C Implementation |
|-----------------|------------------|
| atomic_load(p) | __atomic_load_n(p, __ATOMIC_SEQ_CST) |
| atomic_store(p,v) | __atomic_store_n(p, v, __ATOMIC_SEQ_CST) |
| atomic_cas(p,e,d) | __atomic_compare_exchange_n(...) |
| spawn(fn) | pthread_create(...) |
| channel_new() | pipe + mutex wrapper |

## Runtime Library: quartz_runtime.c

A C file (~800-1,200 lines) providing data structure implementations:

### Vec Implementation
```c
typedef struct {
    int64_t capacity;
    int64_t length;
    int64_t data;      // pointer to element array (as int64_t)
    int64_t elem_width; // bytes per element (1, 2, 4, or 8)
} QzVec;
```

### HashMap Implementation
```c
typedef struct {
    int64_t capacity;
    int64_t size;
    int64_t keys;       // pointer to key array
    int64_t values;     // pointer to value array
    int64_t states;     // pointer to state array (0=empty, 1=occupied, 2=deleted)
} QzHashMap;
```

### StringBuilder Implementation
```c
typedef struct {
    char* data;
    int64_t length;
    int64_t capacity;
} QzStringBuilder;
```

### String Functions

Length-prefixed string operations:
```c
int64_t qz_alloc_str(int64_t len) {
    char* buf = malloc(8 + len + 1);
    *(int64_t*)buf = len;
    char* data = buf + 8;
    data[len] = '\0';
    return (int64_t)(intptr_t)data;
}

int64_t qz_str_concat(int64_t a, int64_t b) {
    int64_t alen = *(int64_t*)((char*)(intptr_t)a - 8);
    int64_t blen = *(int64_t*)((char*)(intptr_t)b - 8);
    int64_t result = qz_alloc_str(alen + blen);
    memcpy((char*)(intptr_t)result, (char*)(intptr_t)a, alen);
    memcpy((char*)(intptr_t)result + alen, (char*)(intptr_t)b, blen);
    return result;
}
```

## Build Driver

```bash
# Emit C source
./quartz --backend c program.qz > program.c

# Compile with system C compiler
cc -O2 -o program program.c quartz_runtime.c -lpthread -lm

# Or single step via quake
./quake build:c   # Emits C, compiles, links
```

## Implementation Plan

| Phase | Scope | Estimate |
|-------|-------|----------|
| Phase 1: Core emission | Function bodies, control flow, arithmetic | 2-3 days |
| Phase 2: Runtime library | Vec, HashMap, StringBuilder, String ops | 2-3 days |
| Phase 3: Intrinsic mapping | 407 intrinsics → C (by category) | 3-4 days |
| Phase 4: Closures + UFCS | Tagged pointers, call dispatch | 1-2 days |
| Phase 5: Build integration | --backend c flag, quake task | 0.5 day |

Total: ~9-13 days (with ÷4 calibration factor)

## Test Strategy

1. **Spec tests**: `spec/qspec/c_backend_spec.qz` has 7 `it_pending` tests ready for activation
2. **Cross-validation**: Compile test programs with both LLVM and C backends, compare output
3. **Self-compilation**: Ultimate goal — Quartz compiles itself via C backend (no LLVM)
4. **Benchmark**: Compare LLVM -O2 vs C -O2 performance on sieve, string ops, compiler self-compile

## Risks

- **Float handling**: `F64` values are stored as `i64` (bitcast in LLVM). In C, need `union { double d; int64_t i; }` or `memcpy` for type-punning without UB.
- **Tail calls**: LLVM's `musttail` has no C equivalent. TCO depends on compiler optimization level. May need `-O2` minimum.
- **SIMD**: No direct C equivalent for LLVM vector intrinsics. Would need platform-specific intrinsics (`<arm_neon.h>`, `<immintrin.h>`) or be omitted.
- **Inline assembly**: No LLVM inline asm equivalent in portable C.
- **Debug info**: LLVM emits DWARF directly. C backend relies on C compiler's debug info (`-g`), which maps to C source not Quartz source.

## Decision: Deferred

The C backend is valuable for portability and bootstrap independence but is a significant implementation effort. Prioritize when:
- Quartz needs to compile on platforms without LLVM (embedded, exotic architectures)
- The package manager needs pre-compiled artifacts that don't depend on LLVM version
- A second backend is needed for compiler correctness validation (compare LLVM vs C output)
