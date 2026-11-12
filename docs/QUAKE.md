# Quake — The Quartz Build System

> A self-hosted build automation tool written in Quartz. Replaces Rake, completing the self-hosting story.

## Quick Start

```sh
# List available tasks
./self-hosted/bin/quake --list

# Run a task
./self-hosted/bin/quake build
./self-hosted/bin/quake qspec
# `format` and `format_check` are disabled until the formatter ships.

# Get help
./self-hosted/bin/quake --help
./self-hosted/bin/quake --quake-help   # Launcher-specific help
```

## Architecture

Quake has three layers:

### 1. Runtime Library (`std/quake.qz`)

The core library that Quakefiles import:

```quartz
import * from quake

def main(): Int
  task("hello", "Say hello") do ->
    puts("Hello!")
  end
  return quake_main()
end
```

**API Surface:**

| Category | Functions |
|----------|-----------|
| **Tasks** | `task(name, desc, body)`, `task_dep(name, desc, deps, body)`, `task_alias(name, deps)` |
| **Shell** | `sh(cmd)`, `sh_capture(cmd)`, `sh_quiet(cmd)`, `sh_maybe(cmd)` |
| **Files** | `rm(path)`, `mv(src, dst)`, `cp(src, dst)`, `mkdir_p(path)`, `rm_rf(path)` |
| **Glob** | `glob(pattern)` — pure Quartz, supports `*` and `**` |
| **Env** | `env(key, val)`, `env_get(key)` |
| **Progress** | `step(label, body)` — cyan `→ label ✓` output |
| **Errors** | `fail(msg)` — red error output, exit 1 |
| **CLI** | `quake_main()` — parses `--list`, `--help`, `-v`, `-q` |

**Features:**
- **Dependency resolution**: topological sort with diamond-deduplication
- **Did you mean?**: Levenshtein-like fuzzy matching for unknown task names
- **Aligned listing**: Task names and descriptions in aligned columns

### 2. Launcher Binary (`tools/quake.qz` → `self-hosted/bin/quake`)

The launcher handles:
- **Quakefile discovery**: walks from `cwd` up to root looking for `Quakefile.qz`
- **Compile-and-cache**: compiles the Quakefile through `quartz → llc → clang`, caches in `.quake/bin/`
- **Cache invalidation**: file-size stamp detects changes; stale cache triggers recompilation
- **Compiler discovery**: checks `QUARTZ_HOME`, relative path, `PATH`
- **Arg forwarding**: passes all non-launcher args to the compiled Quakefile

### 3. Quakefile (`Quakefile.qz`)

The project's task definitions. The Quartz project's Quakefile includes:

| Task | Description | Rake Equivalent |
|------|-------------|-----------------|
| `build` | Compile the compiler (debug) | `rake build` |
| `build:release` | Compile with `-O2` | `rake build:release` |
| `qspec` | Run the QSpec normal lane; current baseline is red (see `STATUS.md`) | `rake qspec` |
| `fixpoint` | gen0→gen1→gen2 validation | `rake quartz:fixpoint` |
| `validate` | fixpoint + bench | `rake quartz:validate` |
| `format` | Disabled; fail closed without writing | `rake format` |
| `format_check` | Disabled; fail closed until formatter ships | `rake format_check` |
| `clean` | Remove build artifacts | `rake clean` |
| `bench` | Full benchmarks | `rake bench` |
| `snapshots` | IR snapshot tests | `rake snapshots` |
| `install` | Install versioned binary | `rake install` |
| `release` | Full release pipeline | `rake release[ver]` |

## Design Decisions

### Why Not Just Use Make/Rake?

1. **Self-hosting**: Quartz should build itself without external language runtimes
2. **Dogfooding**: Using Quartz for build automation surfaces real-world pain points
3. **Single binary**: No Ruby/Python/Node dependency — just the Quartz compiler

### Compile-and-Cache vs Interpreted

Quakefiles are compiled to native binaries (via LLVM), not interpreted. This means:
- **Fast execution**: Native-speed task logic, no interpreter overhead
- **Normal Quartz**: Full language features (closures, generics, pattern matching)
- **Cached**: Only recompiles when the Quakefile changes

### File-Size Stamp vs Content Hash

Cache invalidation uses file size comparison rather than content hashing. This is a pragmatic trade-off:
- **Pro**: Zero-cost check (single stat call)
- **Con**: Doesn't detect same-size changes (rare in practice)
- **Future**: Content hashing planned when `std/crypto.qz` is available

## Adding the `.quake/` Directory to `.gitignore`

```sh
echo ".quake/" >> .gitignore
```

## Writing a Quakefile

```quartz
import * from quake

def main(): Int
  # Simple task
  task("hello", "Print a greeting") do ->
    puts("Hello, world!")
  end

  # Task with progress steps
  task("deploy", "Deploy the application") do ->
    step("Building") do ->
      sh("make build")
    end
    step("Uploading") do ->
      sh("rsync -avz ./dist/ server:/app/")
    end
  end

  # Task with dependencies
  var deps: Vec<String> = vec_new<String>()
  deps.push("hello")
  deps.push("deploy")
  task_dep("all", "Run everything", deps) do ->
    puts("Done!")
  end

  return quake_main()
end
```
