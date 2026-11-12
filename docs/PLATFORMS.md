# Platform Support Matrix

Quartz targets multiple platforms via LLVM IR cross-compilation. The compiler
runs natively on macOS and cross-compiles for all other targets.

## Compiler Host

| Platform | Arch | Status | Notes |
|----------|------|--------|-------|
| macOS | arm64 | **Primary** | Self-hosted compiler, full stdlib, all tests |
| macOS | x86_64 | Supported | Via Rosetta 2 or native Intel |
| Linux | x86_64 | CI verified | Cross-compiled from macOS, bootstraps + self-compiles |
| Linux | aarch64 | CI verified | Cross-compiled from macOS, bootstraps + self-compiles |

## Compilation Targets

| Target Triple | OS | Arch | Status | Notes |
|--------------|-----|------|--------|-------|
| `arm64-apple-macosx14.0.0` | macOS | arm64 | Full | Primary development target |
| `x86_64-apple-macosx14.0.0` | macOS | x86_64 | Full | Rosetta or native |
| `x86_64-unknown-linux-gnu` | Linux | x86_64 | Full | CI tested, Docker verified |
| `aarch64-unknown-linux-gnu` | Linux | aarch64 | Full | CI tested, Docker verified (OrbStack) |
| `wasm32-wasi` | WASI | wasm32 | Partial | wasmtime verified, stdlib gated with `@cfg` |

## Runtime Dependencies

| Target | Libc | Allocator | Optional | Container Base |
|--------|------|-----------|----------|---------------|
| macOS | system | system `malloc` | OpenSSL 3 (TLS), PCRE2 (regex) | N/A |
| Linux glibc | glibc | mimalloc | OpenSSL (TLS), PCRE2 (regex) | `ubuntu:24.04` |
| Linux musl | musl | mimalloc | — | `alpine:3.21` (static link) |
| WASI | wasi-libc | wasi default | — | N/A (wasmtime) |

**Allocator note.** Linux builds link mimalloc for a 30-50% RSS reduction on
allocation-heavy workloads. macOS does **not** link mimalloc: on Apple Silicon,
mimalloc hits a dyld TLS-slot bootstrap race (microsoft/mimalloc#343) where
`ImageLoader` calls `malloc` before `tpidr_el0` points at a valid TCB, causing
SIGSEGV during process init. This cost a week of debugging in April 2026. The
performance loss on macOS self-compile is acceptable; catastrophic bootstrap
failure is not. See `docs/BOOTSTRAP_RECOVERY.md` for recovery procedures.

## Cross-Compilation Flow

```
macOS (arm64)                    Linux (target arch)
─────────────                    ───────────────────
quartz --target <triple>         llc -filetype=obj program.ll
  program.qz > program.ll  ──→  clang [-static] program.o -o program
```

The compiler emits platform-aware LLVM IR via `@cfg(os: ...)` annotations:
- Socket constants (`SOL_SOCKET`, `SO_REUSEADDR`) differ between macOS/Linux
- Struct layouts (`SockaddrIn.sin_len` is BSD-only)
- Runtime symbols (`__stderrp` vs `stderr`, `arc4random_buf` vs `getrandom`)
- kqueue (macOS) vs epoll (Linux) for event loops

## CI Pipeline

| Job | Runner | What it does |
|-----|--------|-------------|
| `macos` | macOS-latest | Build, QSpec, fixpoint, cross-compile IR for Linux |
| `linux-x86` | ubuntu-latest | Bootstrap from IR, self-compile, QSpec, fixpoint |
| `linux-arm` | ubuntu-24.04-arm | Bootstrap from IR, self-compile, QSpec, fixpoint |
| `docker` | ubuntu-24.04-arm | Validate Docker image builds and starts |

> **Note (2026-05-31):** GitHub is no longer used. Source lives on the self-hosted
> Forgejo (`git.mattkelly.io`) with a sourcehut mirror, and the marketing site
> deploys to the lovelace Proxmox host — **not** GitHub Pages. The old `pages`
> workflow was removed. The remaining `.github/workflows/*` jobs above are stale
> GitHub-Actions definitions pending migration to Forgejo Actions or removal. See
> `docs/DEPLOY.md` for the current deploy story.

## LLVM Versions

| Platform | LLVM Version | Notes |
|----------|-------------|-------|
| macOS (dev) | 21.x | Homebrew `llvm` |
| Linux CI | 18.x | Ubuntu apt `llvm-18` |
| Docker (Alpine) | 18.x | Alpine apk `llvm18` |
