# @cImport Design Document

**Status**: Draft  
**Priority**: P5  
**Target**: v5.3.0

## Overview

Zig-style compile-time C header parsing. The compiler invokes clang to parse C headers and generates Quartz FFI bindings automatically.

## Syntax Options

### Option A: Zig-style (Recommended)
```quartz
const c = @cImport(@cInclude("stdio.h"))

def main(): Int
  c.printf("Hello %s\n".cstr, "world".cstr)
  0
end
```

### Option B: Import statement
```quartz
import c from @cImport("stdio.h")
```

### Option C: Direct inclusion
```quartz
@cInclude("stdio.h")  # Pollutes namespace
```

**Decision**: Option A — matches Zig, explicit namespace, composable.

## Semantics

### @cInclude(path: String) -> CImportBlock
Returns a block of C declarations to be parsed.

### @cImport(blocks...) -> Module  
Parses C declaration blocks, returns a Quartz module with:
- `extern "C"` function declarations
- `@repr(C)` struct definitions
- Type aliases for typedefs
- Constants for `#define` values (where possible)

## Type Mapping

| C Type | Quartz Type |
|--------|-------------|
| `int` | `CInt` (i32) |
| `long` | `CLong` (i64 on LP64) |
| `unsigned int` | `CUInt` |
| `size_t` | `CSize` |
| `char *` | `CPtr` or `CString` |
| `void *` | `CPtr` |
| `struct X` | `@repr(C) struct X` |
| `enum X` | `@repr(C) enum X` |

## Implementation Strategy

### Phase 1: Clang JSON AST (MVP)
1. Compiler spawns `clang -Xclang -ast-dump=json`
2. Parse JSON output
3. Generate Quartz AST nodes for declarations

**Pros**: No libclang dependency, simpler  
**Cons**: Spawns external process, JSON parsing overhead

### Phase 2: libclang Integration (Optional)
Direct libclang bindings for faster parsing.

## Compiler Changes

### Parser
- Add `@cImport` and `@cInclude` as builtin expressions
- Parse at expression position, return module reference

### Type Checker
- Resolve C types to Quartz equivalents
- Handle incomplete types (forward declarations)

### MIR
- Generate `extern "C"` for functions
- Generate `@repr(C)` for structs

### Codegen
- No changes needed (extern/repr(C) already work)

## Edge Cases

1. **Recursive includes**: Parse once, cache results
2. **Variadic functions**: `extern "C" variadic def printf(...)`
3. **Function pointers**: Map to Quartz function types
4. **Inline functions**: Skip or warn
5. **Macros**: Best-effort for simple `#define VALUE 42`

## Test Plan

```ruby
it 'imports C function declaration' do
  result = compile_and_run(<<~QZ)
    const c = @cImport(@cInclude("stdlib.h"))
    
    def main(): Int
      c.abs(-42)
    end
  QZ
  expect(result.exit_code).to eq(42)
end

it 'imports C struct' do
  result = compile_and_run(<<~QZ)
    const c = @cImport(@cInclude("sys/time.h"))
    
    def main(): Int
      var tv: c.timeval
      tv.tv_sec = 42
      tv.tv_sec
    end
  QZ
  expect(result.exit_code).to eq(42)
end
```

## Open Questions

1. **Caching**: Cache parsed headers per-file or globally?
2. **Errors**: How to report C parse errors to user?
3. **Includes**: How to handle `-I` include paths?
4. **Preprocessor**: Handle `#ifdef` via `-D` flags?

## Timeline

- [ ] Week 1: Parser support for @cImport/@cInclude syntax
- [ ] Week 2: Clang JSON AST parser in C bootstrap
- [ ] Week 3: Function import working
- [ ] Week 4: Struct import working
- [ ] Week 5: Typedef/enum support
- [ ] Week 6: Port to self-hosted compiler
