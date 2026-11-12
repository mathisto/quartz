# Quartz Language for VS Code

Syntax highlighting, snippets, formatting, and build integration for the [Quartz](https://github.com/quartz-lang/quartz) programming language.

## Features

### Syntax Highlighting

Full TextMate grammar covering the frozen Quartz syntax:

- **Keywords** — control flow (`if`, `match`, `select`, `for`, `while`), declarations (`def`, `struct`, `enum`, `trait`), concurrency (`go`, `async`, `await`, `yield`, `spawn`)
- **Literals** — strings with `#{}` interpolation, raw strings (`r"..."`), regex (`~r"..."`), char literals, symbols (`:name`), integers (decimal, hex, binary, octal), floats
- **Types** — built-in types (`Int`, `String`, `Bool`, `Vec`, `Option`, `Result`), optional shorthand (`Int?`), generics, user-defined PascalCase types
- **Operators** — arithmetic, comparison, bitwise, pipeline (`|>`), safe navigation (`?.`, `??`), ranges (`..`, `...`), compound assignment (`+=`, `-=`, `&=`, `<<=`, etc.)
- **Attributes** — `@packed`, `@heap`, `@cfg(...)`, `@repr(C)`, `@derive(...)`
- **Macros** — `$try(...)`, `$unwrap(...)`, `$assert(...)`, `$debug(...)`
- **Comments** — line (`#`), doc (`##`), module doc (`##!`) with `@param`/`@returns` annotation highlighting

### Snippets

68 snippets covering all language constructs:

| Prefix | Description |
|--------|-------------|
| `def` | Function definition |
| `defe` | Single-expression (endless) function |
| `main` | Main entry point |
| `struct` | Struct definition |
| `enum` | Enum definition |
| `match` | Pattern match |
| `for` | For..in range loop |
| `if` / `ife` | If / if-else block |
| `impl` | Trait implementation |
| `go` | Spawn concurrent task |
| `async` | Async expression |
| `await` | Await a handle |
| `gen` | Generator function with yield |
| `sel` | Select over channels |
| `chan` | Channel creation |
| `forawait` | For await channel loop |
| `defm` | Multi-clause function |
| `defopt` | Optional return function |
| `test` | QSpec test file template |
| `it` / `itp` | QSpec test case / pending |

See all snippets: `Ctrl+Space` in a `.qz` file.

### Format on Save

Automatic formatting via `quartz --format` on save. Configure in settings:

- `quartz.formatOnSave` — Enable/disable (default: `true`)
- `quartz.compilerPath` — Custom compiler path (default: searches `PATH`)
- `quartz.formatArgs` — Extra formatter arguments

### Build Integration

Commands available from the Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`):

| Command | Keybinding | Description |
|---------|-----------|-------------|
| `Quartz: Run Current File` | `Cmd+Shift+R` | Compile and run the active `.qz` file |
| `Quartz: Build Project` | `Cmd+Shift+B` | Run `quake build` |
| `Quartz: Run Tests` | `Cmd+Shift+T` | Run `quake qspec` |
| `Quartz: Format Document` | — | Format via `quartz --format` |

### Problem Matcher

The `$quartz` problem matcher parses compiler error output:

```
error[QZ0101]: Expected expression
 --> src/main.qz:1:18
```

Errors appear in the Problems panel with clickable file/line/column links. Use with tasks:

```json
{
  "type": "shell",
  "label": "Quartz: Build",
  "command": "quake build",
  "problemMatcher": "$quartz"
}
```

## Requirements

- [Quartz compiler](https://github.com/quartz-lang/quartz) on your `PATH` (or configured via `quartz.compilerPath`)
- For build commands: `quake` build tool on your `PATH` (or configured via `quartz.quakePath`)

## Configuration

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `quartz.formatOnSave` | boolean | `true` | Format on save |
| `quartz.compilerPath` | string | `""` | Path to `quartz` binary |
| `quartz.quakePath` | string | `""` | Path to `quake` binary |
| `quartz.formatArgs` | string[] | `[]` | Extra formatter arguments |

## License

MIT
