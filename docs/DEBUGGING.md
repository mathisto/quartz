# Debugging with lldb (DX.1, line-level DWARF)

Every compiled Quartz binary carries line-level DWARF out of the box (`--debug` is `quake build` default). What works: source-line and function breakpoints, stepping, and backtraces keyed to `file:line`.

```bash
lldb ./self-hosted/bin/quartz -- --no-cache -I self-hosted/frontend -I self-hosted/middle \
  -I self-hosted/backend -I self-hosted/shared -I std -I tools self-hosted/quartz.qz
(lldb) b lexer.qz:42              # breakpoint on source line — works
(lldb) b lexer$lexer_tokenize     # breakpoint on function — works
(lldb) bt                         # backtrace by file:line — works

# Verify IR debug metadata is valid (silent on success)
./self-hosted/bin/quartz --debug program.qz | opt -passes=verify -S -o /dev/null
```

**Scope (verified at `self-hosted/backend/codegen.qz:1660-1731`, sole emitter `cg_emit_debug_metadata`):** line-table level only. Emits one `DICompileUnit`, a per-module `DIFile`, one `DISubprogram` per function (all sharing a single placeholder `!DISubroutineType(types: !{null})`), and `DILocation` entries (column hardcoded to 1). There are **zero** `DILocalVariable`, **zero** `DICompositeType`, **zero** `DIBasicType`, and **no** `llvm.dbg.declare`/`llvm.dbg.value`. Consequence: `frame variable` / `p struct.field` does NOT show rich, typed locals — variable inspection is not yet supported. Promoting to variable-level DWARF (typed locals via `DILocalVariable` + `DICompositeType` + `dbg.declare`) is unbuilt work.
