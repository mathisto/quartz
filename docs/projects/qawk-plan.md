# QAwk: GAWK-Compatible AWK Interpreter in Quartz

> **Status**: Plan saved. Implementation discarded (3,127 lines + 642 lines of tests).
> **Purpose**: Dogfooding validation project — exercises Quartz's string handling, hashmaps, closures, regex, I/O, and dynamic dispatch.

## Overview

A tree-walking AWK interpreter written in Quartz, targeting GAWK compatibility. Single-file tool (`tools/qawk.qz`) compiled via the Quartz compiler to a native binary.

## Architecture

### Pipeline
```
AWK source → Lexer → Parser → AST → Tree-Walk Interpreter → Output
```

### Major Components

| Component | Description |
|-----------|-------------|
| **Token Types** (64 kinds) | Full AWK token set: operators, keywords, regex literals, identifiers |
| **Node Types** (~40 kinds) | AST nodes: program, rule, func, patterns, statements, expressions |
| **Value System** | Tagged values with strnum semantics (AWK's string/number duality) |
| **Lexer** | Hand-written, handles regex vs division disambiguation |
| **Parser** | Recursive descent, precedence climbing for expressions |
| **Statement Parser** | if/else, while, for, for-in, do-while, break, continue, next, return |
| **Expression Evaluator** | Binary ops, unary ops, field access ($N), array subscript, function call, regex match, ternary, concatenation, pre/post increment |
| **Interpreter State** | Variables, fields, arrays, open files/pipes, user functions, output buffers |
| **Field Management** | $0 record splitting, $N field access, field assignment with $0 reconstruction |
| **Built-in Functions** | String (length, substr, index, split, sub, gsub, match, tolower, toupper, sprintf), Math (sqrt, sin, cos, atan2, exp, log, int, rand, srand) |
| **I/O** | print/printf with `>`, `>>`, `|` redirection; getline from file/pipe/command; close |
| **Pattern Matching** | BEGIN/END, regex, expression, range patterns, negated patterns |

### Design Decisions

1. **Single-file**: Entire interpreter in one .qz file (no modules needed)
2. **Strnum semantics**: Values carry flags for string/number/strnum status, matching GAWK's coercion rules
3. **Map-based arrays**: AWK's associative arrays map directly to Quartz maps
4. **SUBSEP support**: Multi-dimensional array subscripts via separator concatenation
5. **Flow signals**: break/continue/next/return/exit handled via integer signal codes propagated up the call stack
6. **User functions**: First-class with local variables via AWK's "extra parameters" idiom

### Test Coverage (14 groups, 84 tests)

1. Basic output (5): print, BEGIN/END
2. Fields (8): $N, NF, custom FS, field reassignment, NR
3. Patterns (8): regex, expression, NR, range, multiple rules, negated, match operator
4. Expressions (10): arithmetic, concatenation, comparison, regex match, ternary, increment, coercion, modulo, exponentiation
5. Variables (6): user vars, accumulation, NR/FNR, NF, OFS, ORS
6. Control flow (9): if/else, while, for, for-in, do-while, break, continue, next
7. Arrays (6): assign/retrieve, delete, for-in, SUBSEP, membership, delete entire array
8. String functions (10): length, substr, index, split, sub, gsub, match, tolower, toupper
9. Math functions (4): sqrt, int, sin/cos, rand
10. sprintf/printf (5): %d, %s, %f, width, sprintf
11. User functions (5): define/call, return, local vars, recursion, mutual calls
12. I/O (5): file write/read, append, getline variants, close
13. Pipe I/O (3): command getline, pipe output, pipe close
14. Classic one-liners (8): line count, column sum, max length, dedup, field reverse, word count, field sum, range pattern

### Quartz Features Exercised

- Map (AWK associative arrays)
- String operations (split, concat, substr, regex)
- Closures / first-class functions (not heavily — tree-walk uses manual dispatch)
- File I/O (fopen, fclose, read, write)
- Process I/O (popen, pclose)
- Dynamic field access ($N where N is runtime-computed)
- Recursive descent parsing
- Float arithmetic (AWK numbers are doubles)

## Implementation Notes

- AWK's string concatenation by juxtaposition requires careful parser handling — no explicit operator
- Regex vs division disambiguation in lexer requires context tracking
- getline has 8+ syntactic forms (standalone, with var, from file, from pipe, combinations)
- printf format parsing is substantial (~250 lines for full %d/%f/%s/%e/%g/%x/%o/%c with width/precision/flags)
- Range patterns need per-rule state tracking (active/inactive)

## Resumption Guide

To re-implement, start with:
1. Value system + strnum coercion (this is the hardest part to get right)
2. Lexer + parser (straightforward recursive descent)
3. Core interpreter loop: BEGIN → record processing → END
4. Field splitting and $0 reconstruction
5. Built-in functions (can be added incrementally)
6. I/O redirection and getline (most complex interaction surface)
7. printf/sprintf (tedious but mechanical)
