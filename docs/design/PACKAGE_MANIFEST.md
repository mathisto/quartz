# Quartz Package Manifest Specification

> **Status**: Draft v0.1 (January 2026)
> **Target**: Quartz v6.0 Package Manager Phase 1

## Overview

The `quartz.toml` manifest file defines a Quartz package's metadata, dependencies, and build configuration. This specification covers the schema, parsing requirements, and CLI integration.

## Design Principles

1. **Minimal Core** — Only essential fields required; everything else optional
2. **Cargo-Inspired** — Familiar patterns for Rust developers
3. **Quartz-Native** — Leverage Quartz's features (symbols, traits, modules)
4. **Forward-Compatible** — Schema versioning for evolution

---

## File Location

```
my-package/
├── quartz.toml          # Package manifest (required)
├── src/
│   ├── lib.qz       # Library entry point (optional)
│   └── main.qz      # Binary entry point (optional)
├── tests/           # Integration tests
└── examples/        # Example programs
```

---

## Schema

### Required Section: `[package]`

```toml
[package]
name = "my-package"        # Package name (required)
version = "1.0.0"          # SemVer version (required)
```

### Full `[package]` Section

```toml
[package]
name = "json-parser"
version = "1.2.0"
edition = "2026"           # Quartz language edition (default: current year)

# Metadata (optional)
description = "A fast JSON parser for Quartz"
license = "MIT"
authors = ["Alice <alice@example.com>", "Bob <bob@example.com>"]
repository = "https://github.com/user/json-parser"
homepage = "https://example.com/json-parser"
documentation = "https://docs.example.com/json-parser"
readme = "README.md"
keywords = ["json", "parser", "serialization"]
categories = ["parsing", "encoding"]

# Build configuration
include-dirs = ["src", "vendor"]    # Additional -I paths
default-features = ["std"]          # Features enabled by default
```

### Field Specifications

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | String | Yes | Package identifier. Must match `[a-z][a-z0-9_-]*` |
| `version` | String | Yes | Semantic version (MAJOR.MINOR.PATCH) |
| `edition` | String | No | Language edition year (default: "2026") |
| `description` | String | No | Short package description |
| `license` | String | No | SPDX license identifier |
| `authors` | Array | No | List of "Name <email>" strings |
| `repository` | String | No | Source repository URL |
| `include-dirs` | Array | No | Additional include directories |

---

## Dependencies

### Basic Dependency Syntax

```toml
[dependencies]
http-client = "2.1.0"              # Registry dependency (future)
json = { version = "1.0", features = ["pretty"] }
```

### Path Dependencies (Phase 1)

```toml
[dependencies]
my-lib = { path = "../my-lib" }    # Local path dependency
shared = { path = "./libs/shared" }
```

### Git Dependencies (Phase 2)

```toml
[dependencies]
cool-lib = { git = "https://github.com/user/cool-lib" }
cool-lib = { git = "https://github.com/user/cool-lib", branch = "main" }
cool-lib = { git = "https://github.com/user/cool-lib", tag = "v1.0.0" }
cool-lib = { git = "https://github.com/user/cool-lib", rev = "abc123" }
```

### Development Dependencies

```toml
[dev-dependencies]
test-utils = { path = "../test-utils" }
benchmark = "0.5.0"
```

---

## Features

Features allow conditional compilation and optional dependencies.

```toml
[features]
default = ["std"]                  # Enabled by default
std = []                           # Standard library integration
pretty = ["dep:pretty-print"]      # Enables optional dependency
full = ["std", "pretty", "async"]  # Feature group
```

### Using Features

```toml
# In dependent package
[dependencies]
json = { version = "1.0", features = ["pretty"], default-features = false }
```

---

## Build Targets

### Binary Targets

```toml
[[bin]]
name = "my-cli"
path = "src/main.qz"

[[bin]]
name = "my-tool"
path = "src/bin/tool.qz"
```

### Library Target

```toml
[lib]
name = "my_lib"                    # Defaults to package name
path = "src/lib.qz"                # Default path
```

### Examples

```toml
[[example]]
name = "basic-usage"
path = "examples/basic.qz"

[[example]]
name = "advanced"
path = "examples/advanced.qz"
required-features = ["full"]
```

---

## Profiles

Build profiles for different optimization levels.

```toml
[profile.dev]
debug = true                       # DWARF debug info (--debug flag)
opt-level = 0                      # No optimization

[profile.release]
debug = false
opt-level = 3                      # Full optimization
lto = true                         # Link-time optimization (future)
```

---

## Workspaces (Future)

For monorepos with multiple packages.

```toml
[workspace]
members = [
    "core",
    "cli",
    "libs/*"
]

# Shared dependencies across workspace
[workspace.dependencies]
json = "1.0.0"
```

---

## Complete Example

```toml
[package]
name = "be-json"
version = "1.0.0"
edition = "2026"
description = "JSON parsing and serialization for Quartz"
license = "MIT"
authors = ["Quartz Team <team@quartz-lang.org>"]
repository = "https://github.com/be-lang/be-json"
keywords = ["json", "parsing", "serialization"]

[features]
default = ["std"]
std = []
pretty = []
preserve-order = []

[dependencies]
# None for v1.0

[dev-dependencies]
test-utils = { path = "../test-utils" }

[lib]
name = "json"
path = "src/lib.qz"

[[bin]]
name = "json-fmt"
path = "src/bin/fmt.qz"
required-features = ["pretty"]

[[example]]
name = "parse-file"
path = "examples/parse_file.qz"

[profile.dev]
debug = true
opt-level = 0

[profile.release]
debug = false
opt-level = 3
```

---

## CLI Integration

### `be init`

Creates a new package with scaffold:

```bash
$ be init my-package
Created package `my-package` in ./my-package

$ be init --lib my-lib
Created library `my-lib` in ./my-lib
```

Generated `quartz.toml`:
```toml
[package]
name = "my-package"
version = "0.1.0"
edition = "2026"
```

### `be build`

Reads manifest and builds package:

```bash
$ be build                    # Build with dev profile
$ be build --release          # Build with release profile
$ be build --features pretty  # Enable feature
```

### `be check`

Validates manifest and type-checks without building:

```bash
$ be check
```

---

## TOML Subset for Phase 1

Phase 1 implements a minimal TOML subset sufficient for package manifests:

### Supported Syntax

```toml
# Comments (start with #)

# Basic strings
name = "value"

# Multi-line basic strings (future)
# description = """
# Long text
# """

# Literal strings (no escapes)
path = 'C:\path\to\file'

# Integers
timeout = 30

# Booleans
debug = true
lto = false

# Arrays
keywords = ["one", "two", "three"]
authors = [
    "Alice <a@example.com>",
    "Bob <b@example.com>"
]

# Tables (sections)
[package]
name = "foo"

[dependencies]
bar = "1.0"

# Inline tables
bar = { version = "1.0", features = ["x"] }

# Array of tables
[[bin]]
name = "app1"
path = "src/app1.qz"

[[bin]]
name = "app2"
path = "src/app2.qz"
```

### Not Supported in Phase 1

- Dotted keys: `package.name = "foo"`
- Multi-line strings: `"""`
- Dates/times: `2026-01-23T10:30:00Z`
- Floats: `3.14`
- Hexadecimal/octal/binary integers
- Nested inline tables

---

## Parser Implementation Notes

### Data Model

```be
enum TomlValue
    String(value: String)
    Int(value: Int)
    Bool(value: Bool)
    Array(items: Vec<TomlValue>)
    Table(entries: HashMap<String, TomlValue>)
end

struct TomlDoc
    root: HashMap<String, TomlValue>
end
```

### Parsing Strategy

1. **Lexer**: Tokenize into `[`, `]`, `=`, strings, idents, newlines
2. **Parser**: Recursive descent, table-oriented
3. **Validation**: Check required fields, validate types

### Required Builtins

All needed for Phase 1:
- `read_file(path: String) -> String`
- `str_char_at`, `str_slice`, `str_find`, `str_len`
- `is_digit`, `is_alpha`, `is_whitespace`
- `vec_new`, `vec_push`, `vec_get`, `vec_len`
- `hashmap_new`, `hashmap_set`, `hashmap_get`, `hashmap_has`

---

## Migration Path

### Phase 1: Local Manifest
- `quartz.toml` schema parsing
- `be init` scaffold generation  
- `be build` reads manifest
- Path dependencies only

### Phase 2: Git Dependencies
- Clone/fetch git repos
- Lockfile (`be.lock`)
- Dependency resolution

### Phase 3: Registry
- Central package registry
- `be publish` command
- Version resolution with SemVer

---

## Open Questions

1. **Lockfile format**: TOML or custom?
2. **Build cache location**: `.qz/` or `target/`?
3. **Workspace inheritance**: How deep?
4. **Feature unification**: Cargo-style or simpler?

---

## Appendix: TOML Grammar (Subset)

```ebnf
document     = { line }
line         = table | keyval | comment | newline
table        = "[" key "]" newline
array-table  = "[[" key "]]" newline
keyval       = key "=" value newline
key          = basic-string | literal-string | unquoted-key
value        = string | integer | boolean | array | inline-table
string       = basic-string | literal-string
basic-string = '"' { char } '"'
literal-string = "'" { char } "'"
integer      = [ "-" | "+" ] digit { digit }
boolean      = "true" | "false"
array        = "[" [ value { "," value } [ "," ] ] "]"
inline-table = "{" [ keyval { "," keyval } ] "}"
comment      = "#" { any-char }
```

---

## References

- [TOML v1.0.0 Specification](https://toml.io/en/v1.0.0)
- [Cargo Manifest Format](https://doc.rust-lang.org/cargo/reference/manifest.html)
- [Quartz Language Documentation](./QUARTZ_REFERENCE.md)
