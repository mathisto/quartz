# The Journey: From 1,068 Lines of C to a Self-Hosting Compiler

**93 days. 1,696 commits. 128,474 lines of Quartz.**

This document is a visual walkthrough of the Quartz compiler's evolution —
from a `printf`-based C bootstrap to a self-hosting systems language with
Hindley-Milner inference, a borrow checker, an M:N scheduler, a race detector,
and a direct WASM backend.

---

## Day 0 — December 27, 2025

### The C Bootstrap

The entire compiler was **3 C files, 1,068 lines**. There was no AST — the parser
emitted LLVM IR directly via `printf`. The symbol table was a fixed-size array of 256 entries.

```c
// bootstrap/src/parser.c — the whole compiler
#define MAX_SYMBOLS 256
#define MAX_STRINGS 256
#define MAX_PARAMS 16

static Symbol symbols[MAX_SYMBOLS];
static int symbol_count = 0;

static void parse_function(void) {
    symbol_count = 0;
    reg_count = 1;

    expect(TOK_DEF);
    char func_name[MAX_LEXEME_LEN];
    strcpy(func_name, current_token.lexeme);
    get_token();

    expect(TOK_LPAREN);
    char params[MAX_PARAMS][MAX_LEXEME_LEN];
    int param_count = 0;
    // ... parse params, emit IR inline ...
}
```

The entry point read source, tokenized, and emitted IR in one pass:

```c
// bootstrap/src/main.c — 94 lines total
int main(int argc, char** argv) {
    char* source_code;
    if (argc > 1)
        source_code = read_file(argv[1]);
    else
        source_code = read_stdin();

    lexer_init(source_code);
    tokenize_all();
    emit_preamble();
    parse_program();
    emit_string_constants();
    free(source_code);
    return 0;
}
```

The first test suite:

```ruby
# spec/integration/arithmetic_spec.rb — Day 1
RSpec.describe 'Arithmetic' do
  it 'returns an integer literal' do
    result = compile_and_run("def main() -> Int\n  return 42\nend")
    expect(result.exit_code).to eq(42)
  end
end
```

> **Day 1 language**: `def`, `return`, integers, strings, `if`/`else`, `while`,
> basic structs and enums. No modules. No type inference. `->` for return types (later changed to `:`).

---

## Day 3 — December 30, 2025

### The Self-Hosted Compiler Appears

Three commits in one day birth the self-hosted pipeline. The language is writing itself.
But it's fighting itself too — Be's module system can't share struct types across files,
so the AST is built from **parallel integer arrays** with handle-based access:

```
# self-hosted/parser.be — Dec 30, 2025
# Arena-style AST because imports can't share struct types

def ast_new_storage(): Int
  var s = vec_new()
  var i = 0
  while i < 11
    vec_push(s, vec_new())
    i = i + 1
  end
  return s
end

def ast_get_kind(s: Int, h: Int): Int
  return vec_get(vec_get(s, 0), h)
end
```

The codegen is 426 lines of StringBuilder-based IR emission:

```
# self-hosted/codegen.be — Dec 30, 2025
def type_to_llvm(t: Int): String
  if t == 0
    return "i64"
  end
  if t == 1
    return "i1"
  end
  return "i64"
end
```

Everything is `Int`. Type tags are raw numbers. The `TokenType` enum has to be
**duplicated** in every file because the import system can't share it.

> **The compiler compiling itself with these limitations is the whole point.**
> You don't wait until the language is ready. You make it ready by using it.

---

## Day 6 — January 2, 2026

### Fixpoint: The Snake Eats Its Tail

```
Release v0.9.0: Self-hosting fixpoint achieved
Stage 2 == Stage 3, byte-identical
MD5: 530f7c685c4fe4ae8c7f1901be81db7e
```

Six days from empty directory to a compiler that compiles itself to identical output.
The entry point is already clean:

```
# self-hosted/be.be — Jan 2, 2026 (v0.9.0)
import lexer
import parser
import resolver
import mir
import codegen

def compile(source: String, filename: String): Int
  var lex_result = lexer$lexer_tokenize(source)

  var types = lexer$lexer_get_types(lex_result)
  var lexemes = lexer$lexer_get_lexemes(lex_result)
  var lines = lexer$lexer_get_lines(lex_result)
  var cols = lexer$lexer_get_cols(lex_result)
  var count = lexer$lexer_token_count(lex_result)

  var ps = parser$parse_with_state(types, lexemes, lines, cols, count)
  var ast_storage = parser$ps_get_ast_storage(ps)
  var root = parser$ps_get_program(ps)
  var all_funcs = resolver$resolve_imports(ast_storage, root, filename)
  var mir_prog = mir$mir_lower_all(all_funcs)
  var llvm_ir = codegen$cg_codegen(mir_prog)
  puts(llvm_ir)
  return 0
end
```

> ~6,671 lines of Be compiling ~6,671 lines of Be. The C bootstrap still exists
> but is now redundant. The patient is off life support.

---

## Day 14 — January 10, 2026

### v1.0.0

Self-hosting discipline infrastructure. The C bootstrap directory is deleted the
next day. From here forward, the compiler compiles itself or it doesn't ship.

---

## Day 31 — January 27, 2026

### Be Becomes Quartz

`.be` → `.qz`. "Be" was always a placeholder. The language has earned a real name.

---

## Day 44 — February 9, 2026

### True Fixpoint: gen2 == gen3 == gen4

```
294,125 lines of LLVM IR
1,269 functions
Byte-identical across all generations
```

This isn't "compiler compiles itself." This is "compiler compiled by *any* generation
produces identical output." The C bootstrap is formally retired. There is no escape
hatch back to C. The language stands alone.

---

## Day 60 — February 26, 2026

### The Self-Hosted Ecosystem

By now, Quartz has built its own tools:

- **QSpec** — native test framework (RSpec-style DSL, property testing)
- **Quake** — build system (self-hosted Rake replacement)
- **Formatter** — `quake format` reformats all `.qz` files
- **Linter** — 24 rules, `--fix`, suppression comments
- **String interpolation** — `"Hello, #{name}!"`

The test went from this:

```ruby
# Day 1: Ruby shelling out to the compiler
result = compile_and_run("def main() -> Int\n  return 42\nend")
expect(result.exit_code).to eq(42)
```

To this:

```
# Day 60: Quartz testing itself
import * from qspec

def main(): Int
  describe("arithmetic") do ctx ->
    it(ctx, "adds integers") do ->
      assert_eq(1 + 1, 2)
    end
  end
  return qspec_main()
end
```

---

## Day 75 — March 12, 2026

### The Concurrency Epoch

The `go` keyword lands with an M:N scheduler, work-stealing, channels, mutexes,
and `select`. A single commit adds 2,400 lines across MIR lowering and the
codegen runtime.

```
# March 2026: goroutine-style concurrency
ch = channel_new(10)

go do ->
  for i in 0..100
    send(ch, i * 2)
  end
  close(ch)
end

for await msg in ch
  puts(msg.to_s())
end
```

Compare with the Day 1 language, which couldn't even pass a function as a value.

---

## Day 80 — March 16, 2026

### Three Pillars in One Day

**Hindley-Milner type inference**, **interprocedural borrow checker**, and
**e-graph equality saturation** all land on the same day. The inference engine
replaces 1,243 lines of legacy code with a proper constraint-based solver.
Net change: **-1,024 lines**.

The language goes from requiring explicit annotations everywhere:

```
# Before H-M (explicit annotations required)
def map(items: Vec<Int>, f: Fn(Int): Int): Vec<Int>
  var result: Vec<Int> = vec_new()
  # ...
end
```

To inferring them:

```
# After H-M (inferred from usage)
def double(x) = x * 2
items = vec_new()
items.push(42)           # Vec<Int> inferred
mapped = items.map(double)
```

---

## Day 85 — March 19, 2026

### The Compiler Has an IDE

An LSP server, written in Quartz, providing: go-to-definition, hover types,
find references, rename, semantic tokens, inlay hints, workspace diagnostics,
and code actions. The compiler is now introspectable from VS Code.

---

## Day 87 — March 24, 2026

### WASM Without LLVM

A direct WASM bytecode backend emitting `.wasm` binaries from MIR. No LLVM, no
`llc`, no `wasm-ld`. Just Quartz reading its own MIR and writing WebAssembly
binary format. 6,301 lines of synthesized runtime.

---

## Day 92-93 — March 29-30, 2026

### The Soul of Quartz

A race detector — the first in any self-hosted compiler. Shadow memory, vector
clocks, 64-thread tracking. Chase-Lev lock-free work-stealing deques. And a
live demo running **1,000,000 concurrent tasks at 315 MB**, with an HTTP server
staying responsive throughout.

```
# The Soul of Quartz demo — 1M tasks, zero-CPU park, instant HTTP
def main(): Int
  sched_init(8)

  ch = channel_new(1000)
  go_priority(PRIORITY_CRITICAL) do ->
    http_serve(8080, ch)
  end

  for i in 0..1_000_000
    go do ->
      sched_park()       # zero CPU until woken
    end
  end

  return sched_run()
end
```

And the stream combinators — async generators composing like Unix pipes:

```
# std/streams.qz — async iterator combinators
def stream_map(src: impl AsyncIterator<Int>, f: Fn(Int): Int): impl AsyncIterator<Int>
  for await v in src
    yield f(v)
  end
end

def stream_filter(src: impl AsyncIterator<Int>, pred: Fn(Int): Bool): impl AsyncIterator<Int>
  for await v in src
    if pred(v)
      yield v
    end
  end
end

# Compose: filter → map → collect
result = stream_collect(
  stream_map(
    stream_filter(numbers(), x -> x % 2 == 0),
    x -> x * 10
  )
)
```

---

## The Numbers

| | Day 0 | Day 6 | Day 93 |
|---|---|---|---|
| **Language** | C | Be | Quartz |
| **Compiler** | 1,068 LOC (3 files) | 6,671 LOC (5 files) | 128,474 LOC (78 files) |
| **Tests** | 14 (Ruby/RSpec) | ~70 (Ruby/RSpec) | 5,307 (QSpec) + 2,048 (RSpec) |
| **Test files** | 1 | ~8 | 468 (QSpec) + ~120 (RSpec) |
| **Modules** | 0 | 5 | 38+ imports in entry point |
| **Backends** | printf→LLVM IR | StringBuilder→LLVM IR | LLVM IR, C, WASM (direct) |
| **Type system** | Manual annotations | Manual annotations | H-M inference, borrow checker |
| **Concurrency** | — | — | M:N scheduler, work-stealing, channels, race detector |
| **Tooling** | Makefile + Ruby | Makefile + Ruby | Quake, QSpec, formatter, linter, LSP |
| **Commits** | 1 | ~70 | 1,696 |
| **Self-hosting** | No | Yes (fixpoint) | gen2==gen3==gen4, C bootstrap deleted |

---

## The Entry Point, Then and Now

**Day 0 — C bootstrap (94 lines, no phases):**
```c
int main(int argc, char** argv) {
    lexer_init(source_code);
    tokenize_all();
    emit_preamble();
    parse_program();        // parse + codegen in one pass
    emit_string_constants();
    return 0;
}
```

**Day 6 — First fixpoint (5 imports, 5 phases):**
```
import lexer
import parser
import resolver
import mir
import codegen
```

**Day 93 — Current (38+ imports, full pipeline):**
```
QUARTZ_VERSION = "5.12.21-alpha"

import lexer
import parser
import macro_expand
import derive
import resolver
import mir
import mir_lower
import mir_lower_async_registry
import mir_opt
import egraph
import egraph_opt
import domtree
import codegen
import codegen_separate
import codegen_c
import codegen_wasm
import typecheck
import typecheck_walk
import typecheck_registry
import typecheck_util
import liveness
import diagnostic
import explain
import content_hash
import lint
import build_cache
import dep_graph
import string_intern
import lsp
import repl
```

Each import is a real compiler phase. None are wrappers. Every one required
changes to the compiler, the type system, or the runtime. This is not a toy.

---

*Generated March 30, 2026 — 93 days in.*
