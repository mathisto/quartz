# Bootstrap Recovery

How to rebuild a working Quartz compiler when the macOS or Linux binary chain breaks. This document is the distilled, evergreen recipe — see `docs/Roadmap/archive/HANDOFF_LINUX_BOOTSTRAP.md` for the original step-by-step from the April 2026 recovery.

---

## When you need this document

You need this if:

- The committed `self-hosted/bin/quartz` segfaults or hangs on its own source.
- `quake build` produces invalid IR (truncated, dangling refs, fixpoint mismatch).
- Both `quartz-golden` and `quartz-prev` in `self-hosted/bin/backups/` are broken.
- The macOS binary hits the **mimalloc/IOAccelerator memory collision** documented in `docs/Roadmap/archive/HANDOFF_LINUX_BOOTSTRAP.md` (`SIGSEGV at 0x0...bc0000000`, vmRegionInfo shows `IOAccelerator 36.0G`).

If `quake guard` would have caught it before it landed, this document is the manual version of that protection. If `quake guard` *did* catch it, fix the underlying source and re-run guard — you don't need this.

---

## Two recovery paths

### Path A — Use an archived `quartz-pre-*` binary on macOS

This is the fast path when you need a working compiler back **on macOS** and the broken binary is recent enough that an archived binary can compile near-HEAD source.

**Requirements:**
- A `self-hosted/bin/quartz-pre-*` binary that runs (`./self-hosted/bin/quartz-pre-X --version` returns a version string).
- That binary must be **non-mimalloc** (`otool -L self-hosted/bin/quartz-pre-X | grep -v mimalloc` returns the binary itself with no `libmimalloc.*.dylib` reference).
- A commit close to HEAD whose source the archived binary can typecheck.

**Recipe:**

```bash
# 1. Audit the binary fleet for non-mimalloc candidates.
cd /path/to/quartz
for bin in self-hosted/bin/quartz self-hosted/bin/quartz-pre-* self-hosted/bin/backups/quartz-*; do
  [ -f "$bin" ] || continue
  if otool -L "$bin" 2>/dev/null | grep -q libmimalloc; then
    status="LINKS_MIMALLOC"
  else
    status="no_mimalloc   "
  fi
  mtime=$(stat -f "%Sm" -t "%Y-%m-%d_%H:%M" "$bin")
  printf "%-50s %s  %s\n" "$bin" "$status" "$mtime"
done

# 2. Pick the most recent non_mimalloc binary that runs.
./self-hosted/bin/quartz-pre-cleanup --version

# 3. Find the source commit it can compile cleanly. The bisect technique:
git worktree add /tmp/quartz-recovery <candidate-commit>
cd /tmp/quartz-recovery
/path/to/quartz/self-hosted/bin/quartz-pre-cleanup \
  --no-cache --no-opt \
  --target x86_64-unknown-linux-gnu \
  -I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend \
  -I self-hosted/error -I self-hosted/shared -I tools -I std \
  self-hosted/quartz.qz > /tmp/quartz-recovery.ll 2> /tmp/quartz-recovery.err
echo "EXIT=$?"
# If exit 0 and quartz-recovery.ll > 0 bytes — you have a viable target.
```

If the binary rejects HEAD source with errors like "Undefined function: map_new" or "Unknown type 'Map<String, Int>'", the binary is from before the unified Map migration (Apr 6, 2026). Walk back to commits before that. If the binary rejects with `@cfg must precede a definition`, walk back before `5d1aaa23` (Apr 8). If the binary parses `module$func()` but rejects the source, walk *forward* — your binary expects the new `module::func()` syntax.

The commit that survived this drill in April 2026 was **`bce5e646` (Mar 25)**, which `quartz-pre-cleanup` (whose effective build date was somewhere between Feb 24 and the Mar `map_new` introduction) could compile cleanly.

**Once you have a working source revision:**

1. Cross-compile to Linux IR (see Path B step 3 below for the patches needed)
2. Transfer to a Linux machine (USB stick is the most reliable)
3. Continue with Path B from step 4

### Path B — Cross-compile from macOS to Linux, bootstrap forward on Linux

This is the recovery path the April 2026 incident used. It's slower but it's the **only path that works when the macOS binary cannot self-compile at all** (e.g., the IOAccelerator/mimalloc bug).

**Requirements:**
- A working non-mimalloc macOS binary (per Path A step 1)
- A Linux machine (real or VM) with `clang`, `llc`, and ideally `mimalloc-dev`
- The source commit you want to bootstrap *from* (the commit your binary can compile cleanly — see Path A step 3)

**Step 1 — Set up a worktree at the target commit on macOS:**

```bash
cd /path/to/quartz
git worktree add /tmp/quartz-recovery <target-commit>
```

Do **not** check out the target commit in your main working tree if you have uncommitted work — use a worktree instead. The April 2026 incident lost work this way; the rule is "no `git checkout` with a dirty tree."

**Step 2 — Cross-compile compiler + quake to Linux IR:**

```bash
cd /tmp/quartz-recovery
mkdir -p tmp

# Compiler
/path/to/quartz/self-hosted/bin/quartz-pre-cleanup \
  --no-cache --no-opt \
  --target x86_64-unknown-linux-gnu \
  -I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend \
  -I self-hosted/error -I self-hosted/shared -I tools -I std \
  self-hosted/quartz.qz > tmp/quartz-linux.ll 2> tmp/quartz-linux.err
echo "EXIT=$?"   # expect 0
head -3 tmp/quartz-linux.ll | grep -q 'target triple = "x86_64-unknown-linux-gnu"'

# Quake
/path/to/quartz/self-hosted/bin/quartz-pre-cleanup \
  --no-cache --no-opt \
  --target x86_64-unknown-linux-gnu \
  -I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend \
  -I self-hosted/error -I self-hosted/shared -I tools -I std \
  tools/quake.qz > tmp/quake-linux.ll 2> tmp/quake-linux.err
```

**Step 3 — Patch macOS-isms out of the IR.**

The cross-compile codegen in older binaries doesn't fully scrub macOS-specific symbols. You'll see:

- **Duplicate `declare` lines** for `@fopen`, `@sysconf`, `@fclose` (LLVM 15+ rejects)
- **`@__stderrp` references** (macOS name; Linux uses `@stderr`)

Patch with awk + sed (anchored to end-of-line so string-constant data isn't touched):

```bash
awk '/^declare / { if (seen[$0]++) next } { print }' tmp/quartz-linux.ll \
  | sed -E 's/@__stderrp$/@stderr/' > tmp/quartz-linux-patched.ll
awk '/^declare / { if (seen[$0]++) next } { print }' tmp/quake-linux.ll \
  | sed -E 's/@__stderrp$/@stderr/' > tmp/quake-linux-patched.ll
```

Validate locally with `llvm-as` (homebrew LLVM is the strictest):

```bash
PATH="/opt/homebrew/opt/llvm/bin:$PATH" llvm-as tmp/quartz-linux-patched.ll -o /tmp/quartz.bc
PATH="/opt/homebrew/opt/llvm/bin:$PATH" llvm-as tmp/quake-linux-patched.ll  -o /tmp/quake.bc
```

If `llvm-as` complains about other macOS-isms (`@arc4random`, `@backtrace`, `@__error`), the binary you're cross-compiling with predates the relevant Linux runtime fixes. Walk to a more recent source commit, or write additional sed patches.

**Step 4 — Transfer to Linux.**

The fast/reliable path is **a USB stick or git remote** through GitHub/sourcehut. Tailscale + scp has been observed to fail mid-stream on long transfers; if you must use it, set `ServerAliveInterval=5` and `ServerAliveCountMax=120` and use `ssh -O check` to verify the mux session is alive.

```bash
gzip -k tmp/quartz-linux-patched.ll tmp/quake-linux-patched.ll
# → transfer the .gz files to /tmp/ on the Linux machine
```

**Step 5 — On the Linux machine, link and smoke-test.**

```bash
sudo apt-get install -y clang llvm libmimalloc-dev   # or use linuxbrew

gunzip /tmp/quartz-linux-patched.ll.gz /tmp/quake-linux-patched.ll.gz

llc -filetype=obj /tmp/quartz-linux-patched.ll -o /tmp/quartz.o
clang /tmp/quartz.o -o /tmp/quartz-linux -lm -lpthread
# Add -lmimalloc only if the source revision links it (post-afad28c0)

llc -filetype=obj /tmp/quake-linux-patched.ll -o /tmp/quake.o
clang /tmp/quake.o -o /tmp/quake-linux -lm -lpthread

/tmp/quartz-linux --version    # expect a version string
/tmp/quake-linux --list        # expect task listing
```

**Step 6 — Walk forward from the bootstrap point to HEAD.**

The walker uses each successful binary as gen0 for the next commit. The pattern at every commit:

1. Create a worktree at the next forward commit
2. Copy the most recent working `quartz-linux-x64-<prev>-golden` into the worktree as `self-hosted/bin/quartz`
3. Apply any required source patches (see "Standard patch set" below)
4. Run `quake build` to produce the new binary
5. Verify it builds gen2 (fixpoint check)
6. Save as `self-hosted/bin/backups/quartz-linux-x64-<commit>-golden` and the matching `quake-linux-x64-<commit>-golden`
7. Advance to the next commit

Each forward step is small (1–10 commits at a time) when crossing intrinsic-introduction commits; larger jumps work between milestones. The April 2026 walk made 14 successful gen-N→gen-N+1 steps to reach HEAD from `bce5e646`.

**Step 7 — Verify HEAD fixpoint.**

```bash
cd /path/to/worktree-at-HEAD
./self-hosted/bin/quake build         # gen1
./self-hosted/bin/quake build         # gen2
./self-hosted/bin/quake fixpoint      # must produce gen1.ll == gen2.ll
```

If fixpoint passes, save the binary as `quartz-linux-x64-<HEAD>-golden` and you're done.

**Step 8 — Cross-compile back to macOS (if needed).**

If the macOS binary is still broken from the original incident, the Linux gen-N can cross-compile its own source back to macOS:

```bash
# On Linux
./self-hosted/bin/quartz \
  --target arm64-apple-darwin \
  -I self-hosted/frontend -I self-hosted/middle -I self-hosted/backend \
  -I self-hosted/error -I self-hosted/shared -I tools -I std \
  self-hosted/quartz.qz > /tmp/quartz-macos.ll
# Transfer to Mac, then:
clang -target arm64-apple-darwin /tmp/quartz-macos.ll -o /tmp/quartz-macos -lm -lpthread
```

---

## The macOS mimalloc/IOAccelerator collision

This is the bug that triggered the April 2026 incident. Symptoms:

- Compiler segfaults during `resolve_pass1` after consuming ~10 GB RSS
- Crash report shows `SIGSEGV at 0x0000000bc0000000`
- `vmRegionInfo` shows `IOAccelerator 36.0G  366` regions
- Stack trace is `qz_str_hash → string_intern$intern → ast_set_str1 → resolver$resolve_rewrite_calls`

**Root cause:** mimalloc on Apple Silicon allocates large slabs from `IOAccelerator` regions (GPU memory). When a string-interner buffer overruns by 1 byte, it walks off the end of an `IOAccelerator` slab and the process dies with a `KERN_INVALID_ADDRESS` at the slab boundary.

**Workarounds tried that DO NOT WORK:**

- `MIMALLOC_RESERVE_HUGE_OS_PAGES=0` and similar env vars — mimalloc respects them but the bug isn't huge-pages, it's `arena_reserve` (~1 GiB allocations)
- `DYLD_INSERT_LIBRARIES` with a system-malloc shim — fails because `bash` is `arm64e` and `libsystem_malloc` is `arm64`. Try `env -i ./quartz` to bypass the launcher mismatch.

**Workarounds that DO work:**

1. **Use a non-mimalloc archived binary** (`self-hosted/bin/quartz-pre-cleanup` and most older `quartz-pre-*` binaries are mimalloc-free)
2. **`install_name_tool` shim** — replace the linked `libmimalloc.dylib` reference with a custom dylib that forwards `mi_*` to system `malloc`. Requires no rebuild:
   ```bash
   cat > /tmp/mi_shim.c <<'EOF'
   #include <stdlib.h>
   #include <malloc/malloc.h>
   void* mi_malloc(size_t n)             { return malloc(n); }
   void* mi_zalloc(size_t n)             { return calloc(1, n); }
   void* mi_calloc(size_t c, size_t n)   { return calloc(c, n); }
   void* mi_realloc(void* p, size_t n)   { return realloc(p, n); }
   void  mi_free(void* p)                { free(p); }
   size_t mi_usable_size(void* p)        { return malloc_size(p); }
   EOF
   clang -dynamiclib -o /tmp/libmimalloc.3.2.dylib /tmp/mi_shim.c \
     -install_name /tmp/libmimalloc.3.2.dylib

   cp self-hosted/bin/quartz /tmp/quartz-no-mimalloc
   install_name_tool -change \
     /opt/homebrew/opt/mimalloc/lib/libmimalloc.3.2.dylib \
     /tmp/libmimalloc.3.2.dylib \
     /tmp/quartz-no-mimalloc
   codesign -s - /tmp/quartz-no-mimalloc
   /tmp/quartz-no-mimalloc --version
   ```
   You'll need to add additional `mi_*` shim functions as the linker reveals them — typically 10–15 total.
3. **Bootstrap on Linux** (Path B above) and cross-compile back to macOS without mimalloc

The proper long-term fix is to gate the mimalloc link behind `@cfg(target = "linux")` so macOS never links it. That's an open ROADMAP item.

---

## macOS jetsam vs the compiler

A separate but related macOS pathology: the kernel's **jetsam** subsystem will kill a long-running process that uses 16+ GB of resident memory, **even if 50 GB of physical RAM is free**. Symptoms:

- Compiler hits ~14–22 minutes of CPU time, RSS climbs to 16 GB
- Process is killed with no core dump
- Console.log shows `jetsam` killed PID
- Memory pressure indicator stays green the whole time

**There is no fix for this on macOS.** It's a deliberate iOS-derived behavior. The only real workaround is to do compiler work on Linux, which has a real OOM killer that fires only when memory is actually exhausted.

**If you're stuck on macOS during recovery:**

- Strip optional modules from the source you're compiling (delete imports for `lsp`, `repl`, `codegen_wasm`, `mir_opt`, `egraph`, `domtree`, `codegen_separate`)
- Use `--no-cache --no-opt` to keep the working set minimal
- Avoid running anything else memory-heavy on the same Mac during the build

---

## Standard patch set for source-only walks — RETIRED

> **All fossils resolved as of Apr 12, 2026.** The source tree is now source-only-buildable
> without any patches. The patch recipes below are retained only for historical reference —
> they are needed when walking the bootstrap forward through *old* commits (pre-Apr 12)
> where the fossils were still present.

**The April 2026 fossils** (resolved in source at HEAD; patches only needed for historical walks):

1. **Strip cconv_c if-blocks from `mir_lower.qz`** (2–4 sites). The pattern:
   ```qz
   if ast::ast_func_is_cconv_c(s, node)
     mir::mir_func_set_cconv_c(func)
   end
   ```
   Delete the entire `if`/`end` block.

2. **Strip cconv_c from `resolver.qz`** (1 site at line ~851). Same shape, same deletion.

3. **Strip `mir_register_poll_callee` if-block from `mir_lower_expr_handlers.qz`**. Same shape.

4. **Add fossil constants to shared modules:**
   ```qz
   # self-hosted/shared/type_constants.qz
   const TYPE_MAP = 25            # alias for TYPE_HASHMAP

   # self-hosted/shared/node_constants.qz
   const NODE_IS_CHECK = -1       # stub; real value not assigned
   ```

5. **Stub the hashable check blocks** in `typecheck_expr_handlers.qz` and `typecheck.qz`. Replace the body of any `tc_type_is_hashable` / `tc_struct_is_hashable` / `tc_hashable_rejection_reason` call site with an unconditional `true` / `0` until the real definitions land.

6. **Substitute `Map<` → `HashMap<`** and `map_new<` → `hashmap_new<` in source files when crossing the unified-Map migration commits if your bootstrap binary predates them.

7. **Strip `@cfg(feature)` lines from `quartz.qz`** when crossing `5d1aaa23` (Apr 7) with a binary built before parser support landed. There are 3 sites in HEAD source.

8. **Substitute `sb_append_byte(` → `sb_append_char(`** when crossing `5f9448b1` (Apr 7) with a pre-UTF-8-fix binary.

These patches are **temporary** — they're applied to the source in the worktree before each `quake build` call, and discarded as soon as the new binary is committed. They never go into trunk source.

---

## The cache-pattern miscompile in `54eb4965`

A latent codegen bug exposed by the mangle/suffix caching introduced in `afad28c0` and `77d968d5`. Both commits use an `as_int(result)` / `as_string(cached)` round-trip through an intmap to deduplicate strings. The `54eb4965` binary miscompiles this pattern when the cache grows large (~9 GB into compilation): cross-module struct type lookups mysteriously fail at typecheck time.

**Symptom:** A binary built from `54eb4965` source successfully compiles small programs but fails on `self-hosted/quartz.qz` itself with "no struct type for X" errors after `[mem] resolve_pass1: ~9.7GB`.

**Workaround for the walker:** When walking through `54eb4965` and beyond, revert these source changes before building:

- `self-hosted/resolver.qz`: `string_intern::mangle(a, b)` → `"#{a}$#{b}"` (2 call sites)
- `self-hosted/middle/typecheck_registry.qz`: `_cached_suffix(tc, name)` → `"$#{name}"` (8 call sites; the `_cached_suffix` function definition can be left as dead code)

**Root cause:** Open. The `as_int` / `as_string` round-trip is supposed to be a no-op pointer identity, but somewhere in the codegen path the boundary between `as_int(string)` and `as_string(int)` produces a stale pointer when the cache is large enough. This is filed as a known compiler bug — see ROADMAP "Open bugs".

---

## Escape hatches you cannot strand yourself with

Always at least one of these is available, even if everything else is broken:

1. **Archived binaries:** `self-hosted/bin/quartz-pre-*` (40+ snapshots back to Feb 2026)
2. **Backups directory:** `self-hosted/bin/backups/quartz-golden`, `quartz-prev`, plus `quartz-linux-x64-*-golden` chain
3. **Git history:** `git checkout HEAD~1 -- self-hosted/bin/quartz` recovers the previous committed binary
4. **Linux fixpoint chain:** `self-hosted/bin/backups/quartz-linux-x64-*-golden` are all fixpoint-verified at their commit; any one can serve as a Linux gen0
5. **Cross-compile from macOS:** Path B above
6. **Reinstall the C bootstrap:** the original C-implemented Quartz compiler was removed in commit `6521f3e4` (Jan 11, 2026) but is recoverable with `git archive 6521f3e4~1 -- bootstrap/`. Two `#include <stdint.h>` patches make it build on modern Linux clang. The C bootstrap cannot compile post-Jan 11 source directly, but it can bootstrap a chain forward.

**Rule:** never delete *all* backup binaries simultaneously. The CLAUDE.md binary backup protocol exists for exactly this reason.

---

## Verification checklist after recovery

A recovered binary is "good" only if it passes ALL of these:

1. `quartz --version` returns the source's `VERSION` constant
2. `quake build` produces a new binary without errors
3. `quake build` a *second* time (gen2) produces a binary
4. `quake fixpoint` reports `gen1.ll == gen2.ll` byte-identical
5. `examples/style_demo.qz` runs and produces colored output
6. `examples/brainfuck.qz` runs all 4 BF programs
7. `spec/qspec/async_spill_regression_spec.qz` reports 12/12 passing
8. A handful of non-self programs compile cleanly (e.g. `examples/hello.qz`, `examples/concurrency.qz`)

**Fixpoint alone is not sufficient.** The April 2026 incident proved that a bad binary can produce IR that, when recompiled, produces *the same bad IR* — fixpoint passes, the binary is broken. Always run real programs as part of the verification.

---

## Related documents

- [QUARTZ_GUARD.md](QUARTZ_GUARD.md) — the source-only build invariant and the fossils that motivated it
- [docs/Roadmap/archive/HANDOFF_LINUX_BOOTSTRAP.md](Roadmap/archive/HANDOFF_LINUX_BOOTSTRAP.md) — full step-by-step from the April 2026 walk
- [docs/Roadmap/archive/HANDOFF_CONCURRENCY_FIXES.md](Roadmap/archive/HANDOFF_CONCURRENCY_FIXES.md) — the concurrency bugs found during recovery
- [docs/Roadmap/archive/HANDOFF_SESSION_4.md](Roadmap/archive/HANDOFF_SESSION_4.md) — rebuild-cycle lessons and the "free without zero" pattern
- [docs/Roadmap/archive/HANDOFF_OVERNIGHT_SUMMARY.md](Roadmap/archive/HANDOFF_OVERNIGHT_SUMMARY.md) — the merge-back summary
