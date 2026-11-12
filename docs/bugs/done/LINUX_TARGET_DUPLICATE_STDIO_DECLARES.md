# Linux-target codegen emits duplicate `declare`s (fopen/fclose/…) → invalid IR

## Status

**CLOSED 2026-06-07.** Root cause was exactly as diagnosed below: the linux
`/proc/self/statm` RSS helper in `codegen_runtime.qz` re-declared `fopen` /
`fclose` (already emitted by the unconditional file-IO block) **plus `sysconf`**
(already emitted by the unconditional pthread/concurrency block) — three dupes,
not the two the filing caught. Fix (option 1): dropped the redundant
`declare`s from the RSS helper, keeping only `fscanf` (the one symbol unique to
it), after verifying `fopen`/`fclose`/`sysconf` are emitted unconditionally on
every linux path that reaches the helper (`fopen`/`fclose` in the function-body
file-IO block; `sysconf` in the non-windows `else` of `if cg_is_wasi == 0`).
macOS is structurally unaffected (its RSS helper uses `mach_task_basic_info`).
Gated to the linux branch ⇒ the apple self-compile path is byte-identical ⇒
fixpoint clean (guard 2735). Also deleted two dead, tree-shaken near-duplicate
emitters found alongside it (`cg_emit_runtime_declares`, which carried the
identical dup-declare pattern, and `cg_emit_format_strings`).

Verified: `x86_64-unknown-linux-gnu` IR for `style_demo` + the C-ABI oracle now
has exactly one `fopen`/`fclose`/`sysconf` and `llc -filetype=obj` exits 0 (was
rejected); macOS output unchanged and still `llc`-valid; full native QSpec
green; Rule-2 smokes pass. The `awk` declare-dedup workaround was removed from
`spec/c_abi/run.sh`.

---

**Filed**: 2026-06-07, while building the Phase 3 C-ABI oracle (B.10 §13, P3.1a).
Pre-existing — the golden compiler reproduces it; **not** introduced by the C-ABI
work. Surfaced because the SysV oracle cross-compiles to `x86_64-unknown-linux-gnu`
and feeds the IR to `llc`.

## Symptom

Compiling **any** program for a **linux target** and running the emitted IR
through `llc` (or `opt`) fails:

```
$ quartz --target=x86_64-unknown-linux-gnu prog.qz | llc -filetype=obj -o prog.o
llc: error: invalid redefinition of function 'fopen'
declare ptr @fopen(ptr, ptr)
            ^
```

After deduping `fopen`, the next duplicate (`fclose`, …) errors the same way.
The emitted `.ll` contains **two** `declare ptr @fopen(ptr, ptr)` (and
`declare i32 @fclose(ptr)`). LLVM allows only one declaration per symbol per
module, so the textual IR is rejected. **This means x86_64-linux IR — the deploy
target — is currently invalid for every program**, not just C-ABI ones.

macOS (arm64-apple / x86_64-apple) is unaffected: it emits only one set of these
declares (see root cause).

## Root cause (confirmed)

`self-hosted/backend/codegen_runtime.qz` hard-codes stdio `declare`s at multiple
sites with no dedup against each other or against the `std/ffi/stdio.qz` externs:

- `codegen_runtime.qz:4098-4099` — `declare ptr @fopen(ptr, ptr)` /
  `declare i32 @fclose(ptr)` (file-IO runtime block).
- `codegen_runtime.qz:4627-4629` — the **Linux** peak-RSS helper
  (`/proc/self/statm` reader, ~`:4595`) emits its **own** `declare ptr @fopen` /
  `declare i32 @fclose` before its `fopen(@.statm_path, "r")` call.

On macOS the RSS helper uses `mach_task_basic_info` instead of `/proc/self/statm`,
so the second declare block (4627-4629) is **not** emitted → no collision. On
linux both fire → duplicate declares → invalid IR.

The extern-declare dedup machinery (`cg_emit_extern_declarations`,
codegen.qz:1436 — tracks `ir_defined_funcs` + an `emitted` map) covers
`extern "C" def` declarations, but these **raw `cg_emit_line("declare …")`**
sites in `codegen_runtime.qz` bypass it entirely.

## Fix options (for the implementer)

1. **Cheapest:** drop the redundant `declare`s from the linux RSS helper
   (4627-4629) — the file-IO block (4098-4099) already declares `fopen`/`fclose`.
   Verify 4098-4099 is always emitted on linux targets before relying on it (if
   it's itself conditional, hoist a single unconditional stdio-declare block).
2. **Robust:** route all hard-coded runtime `declare`s through a single
   emitted-once set (a `Set<String>` of already-declared signatures in
   `CodegenState`), so any site can request a declare and dedup is automatic.
   This also future-proofs other raw-declare sites.

## Repro / regression oracle

```
quartz --target=x86_64-unknown-linux-gnu examples/style_demo.qz > /tmp/p.ll
grep -c '^declare ptr @fopen' /tmp/p.ll      # currently 2; must be 1
llc -filetype=obj /tmp/p.ll -o /tmp/p.o      # currently errors; must succeed
```

The Phase 3 SysV oracle (`spec/c_abi/run.sh --sysv <host>`) currently works
around this by deduping `declare` lines with `awk` before `llc`; once fixed,
remove that workaround from the runner.

## Impact

High for the deploy path: x86_64-linux is the production target (the Quartz VPS),
and its IR is currently `llc`-invalid out of the box. Anything that compiles
Quartz→IR→object on/for linux without the awk-dedup workaround hits this. The
self-hosted build on the macOS dev box doesn't (apple target), which is why it
went unnoticed.
