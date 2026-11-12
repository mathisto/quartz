# Bootstrap Escape Roadmap

**Goal**: Self-hosted compiler can compile itself without the C bootstrap.

**Current State**: v5.12.15-alpha, 1907 tests passing

---

## Immediate Blockers (Fix These First)

### Blocker 1: Prelude Resolution Bug (CRITICAL)
**Location**: `self-hosted/resolver.qz:841-843`

```quartz
def resolve_check_prelude_exists(import_paths: Vec<String>): Int
  return 1 if import_paths.size > 0  # BUG: Doesn't check if file exists
  return 0
end
```

**Problem**: Returns true if ANY import paths exist, without checking if `prelude.qz` actually exists in those paths. The C bootstrap correctly uses `access(prelude_path, F_OK)` to verify.

**Effect**: When running `self-hosted/bin/quartz -I self-hosted/backend ...`, it tries to import prelude from those paths, fails with "Cannot find module prelude".

**Fix Options**:
1. Add `file_exists` intrinsic and check properly (preferred)
2. Always include `-I std` in self-hosted builds (workaround)
3. Change to never auto-import prelude (breaking change)

**Difficulty**: LOW - single function fix + new intrinsic

---

### Blocker 2: Nested Generics in User Structs
**Location**: Bootstrap typecheck.c limitations

**Problem**: Bootstrap cannot compile `Vec<CustomStruct>` where CustomStruct has generic fields like `Vec<String>`. Also cannot compile `Option<CustomStruct>` for user-defined types.

**Effect**: Blocks proper typing of struct_registry (currently uses `Vec<Vec<Int>>` workaround with `as_int`/`as_string`).

**Fix Options**:
1. Wait for bootstrap escape, then refactor (preferred)
2. Add hardcoded type handling to bootstrap (not recommended)

**Difficulty**: NONE after escape - intentionally deferred

---

## Syntax/Feature Gap Analysis

### Features Self-Hosted Uses That Bootstrap Supports
| Feature | Status | Notes |
|---------|--------|-------|
| Nested generics `Vec<Vec<Int>>` | WORKS | Parser handles depth |
| Match expressions (50+ arms) | WORKS | Full pattern matching |
| Expression-bodied functions | WORKS | `def foo() = expr` |
| Postfix conditionals | WORKS | `return x if cond` |
| Module$function calls | WORKS | `ast$ast_get_kind()` |
| String interpolation | WORKS | `"#{expr}"` |
| Range iteration | WORKS | `for i in 0..n` |
| Enum payloads | WORKS | `Found(v) =>` |
| Lambda expressions | WORKS | `\|x\| x + 1` |
| Struct field access `.size` | WORKS | Member access |

### Features With Known Limits
| Feature | Limit | Self-Hosted Usage |
|---------|-------|-------------------|
| Generic type params | 8 max | Uses ≤3 |
| Function parameters | 64 max | Uses ≤12 |
| Struct fields | 64 max | Uses ≤20 |
| Enum variants | 128 max | NodeKind has 50+ |
| Trait methods | 16 max | Uses ≤5 |
| Source file size | 512KB | Largest ~170KB |

**All limits are sufficient** for self-hosted compilation.

---

## Bootstrap Escape Sequence

### Phase 1: Fix Prelude Resolution
1. Add `file_exists(path: String): Bool` intrinsic to both compilers
2. Update `resolve_check_prelude_exists` to use it
3. Test: `self-hosted/bin/quartz` can compile simple programs with `-I` flags

### Phase 2: Validate Stage 2 Compilation
1. Build self-hosted with C bootstrap (existing rake build)
2. Use self-hosted binary to compile self-hosted source
3. Compare generated IR (should be identical or functionally equivalent)
4. Build stage 2 binary and run test suite

### Phase 3: Remove Bootstrap Dependency
1. Add `rake quartz:stage2` task for self-hosted → self-hosted builds
2. Add `rake quartz:escape` task that validates stage 2 = stage 3 (fixpoint)
3. Document escape achieved in ROADMAP.md

### Phase 4: Post-Escape Improvements
1. Refactor struct_registry to use proper `StructInfo` type
2. Implement `Option<CustomStruct>` properly
3. Clean up all `as_int`/`as_string` workarounds
4. Consider archiving C bootstrap

---

## Testing Bootstrap Escape

```bash
# Phase 1: Verify C bootstrap still works
rake build
rake test

# Phase 2: Stage 2 compilation
self-hosted/bin/quartz \
  -I self-hosted/backend \
  -I self-hosted/frontend \
  -I self-hosted/middle \
  -I self-hosted/error \
  -I std \
  self-hosted/quartz.qz > stage2.ll

# Build and test stage 2
llc -O2 stage2.ll -o stage2.o
clang stage2.o runtime/libquartz.a -o stage2-quartz
./stage2-quartz --version

# Phase 3: Verify fixpoint
./stage2-quartz [same args] > stage3.ll
diff stage2.ll stage3.ll  # Should be identical
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Prelude fix breaks something | Low | Medium | Good test coverage |
| Stage 2 produces wrong code | Medium | High | Careful IR comparison |
| Performance regression | Low | Low | Can optimize later |
| Bootstrap needed for emergency | Medium | Medium | Keep bootstrap frozen |

---

## Success Criteria

Bootstrap escape is complete when:
1. `self-hosted/bin/quartz` can compile `self-hosted/quartz.qz`
2. The resulting binary passes all 1907+ tests
3. Stage 2 and Stage 3 IR are identical (fixpoint)
4. C bootstrap is not invoked in normal development

---

## Appendix: Key Files

| File | Role |
|------|------|
| `self-hosted/resolver.qz` | Module resolution, prelude injection |
| `self-hosted/quartz.qz` | Main entry point |
| `quartz-bootstrap/src/resolver.c` | Reference implementation |
| `std/prelude.qz` | Standard prelude (Option, Vec methods, etc.) |
