# FileIo wrap deletion causes unhandled `fio_write` at runtime (cache-enabled)

**Discovered**: 2026-04-23, during Phase 5.4.e Option Z exploration.
**Status**: RESOLVED 2026-04-23 (commit `a6f174ae`). Root cause: effect-stack
`install`/`uninstall` asymmetry at the 32-slot cap. Fix: expanded cap 32→256.
See `## Resolution` section below.
**Repro**: Delete any `with FileIo { fio_write: fio_default_write } do -> fio_write(p, c) end`
wrap in the compiler source, rebuild, run the compiler **without** `--no-cache`.
Result: `unhandled effect op called` / `FileIo.fio_write` on stderr, exit 66.

## What works

- `quake guard` passes (both gen0→gen1 and gen1→gen2 use `--no-opt --no-cache`).
- Manual `quartz --no-cache ...` succeeds on the same source.
- Bare `fio_read(p)` in a trivial user program compiled by a wrap-deleted compiler.
- Smoke tests on `examples/style_demo.qz`, `examples/brainfuck.qz`.

## What fails

Only when:
1. At least one `with FileIo { ... } do -> ... fio_write(...) ... end` wrap has been
   deleted from the compiler source, **and**
2. The compiler is invoked with caching enabled (default — no `--no-cache` flag).

Crash site: `dep_graph::depgraph_save` (`self-hosted/shared/dep_graph.qz:408`) is the
first reliably-triggering call path, but the bug reproduces with other cache-path
`fio_write` callsites too. The specific unhandled op is **`FileIo.fio_write`** —
verified by instrumenting `@__qz_effect_unhandled` to echo `%eff.%op`.

## The mystery

With the P5.4.e prelude install in place (commit `95c0173f`), the main prelude runs
`__qz_effect_handle_install(@__qz_eff_name_file_io, @__qz_default_fileio_handler, 0,
null)` right before `@qz_main()`. Every subsequent `fio_*` call should find that
handler via the standard top-down scan in `@__qz_effect_perform`. It **does** work
for callsites reached via `--no-cache`. It **doesn't** work for cache-path callsites
when the wrap is removed.

Reapplying the wrap (`with FileIo { fio_write: file_io::fio_default_write } do ->
var _w = fio_write(filepath, out) end`) fixes the symptom — because the wrap installs
a second FileIo handler at a higher stack index before the call. Scan finds it first,
dispatches to `fio_default_write`, which just calls `write_file` (the libc intrinsic).
So the wrap functions as a defensive "local install" that sidesteps whatever state
corruption is making the prelude-level install unreachable.

## Diagnostic findings (2026-04-23 Path A session)

One debugging session spent narrowing the problem. Key data:

- **Reproduced with `dep_graph.qz:408` wrap deletion.** Replacing
  `with FileIo { fio_write: file_io::fio_default_write } do -> var _w =
  fio_write(filepath, out) end` with a bare `fio_write(filepath, out)`
  in `depgraph_save` triggers the crash on cache-enabled self-compile.
  `quake guard` still passes because it uses `--no-cache`.
- **Effect+op confirmed.** Instrumented `__qz_effect_unhandled` to
  write `<eff>.<op> top=<N>\n` to stderr. Output: `FileIo.fio_write top=
  8635`. Exit 66.
- **The value 8635 is deterministic** — three consecutive runs all
  produce `top=8635` exactly. Rules out race / ASLR-driven
  randomness. Something is writing this specific value.
- **`__qz_effect_handle_install` never sees `top > 40` at entry.**
  Instrumented the install path with a `top > 40` early-exit trace;
  never fired. So the corrupt-to-8635 transition is NOT happening via
  install/uninstall.
- **Only 3 writers to `@__qz_effect_stack_top` exist in the compiled
  IR** (grep of `store.*__qz_effect_stack_top` in tmp/build.ll): the
  init-to-zero at `__qz_effect_init`, the increment at install, and
  the decrement at uninstall. No third store. No stray writes from
  Piezo machinery.
- **Memory layout via `nm`** shows `__qz_effect_stack_top` at
  `0x1005d5a50`, immediately followed by `__qz_effect_stack_names` at
  `0x1005d5a58`. An underflow write to `stack_names[-1]` would
  clobber `stack_top`. No such negative-index write exists in the
  emitted IR (the scan guards at `i > 0`, the install GEP uses `top`
  which `sgt 0`-guarded uninstall keeps non-negative).

### Remaining hypothesis

**Wild memory write from elsewhere in the runtime.** Some
Quartz-level code path stores `i64 8635` to an i64 aligned pointer
that happens to hit `0x1005d5a50`. Candidates:

- A `Vec<Int>` or `Map<String, Int>` field allocated adjacent to
  stack_top, overflowing past its buffer into `stack_top`.
- A pointer miscomputation in `qz_alloc_*` / malloc wrapper producing
  a ptr that aliases `0x1005d5a50`.
- A struct-field store with a wrong offset.

`8635` as a value has no obvious semantic meaning in the compiler
(not a function count, not a line count — the file with the most
lines is `shared/lsp.qz` at 5987).

### lldb watchpoint attempt

Tried `watchpoint set expression -- &__qz_effect_stack_top` with
condition `__qz_effect_stack_top > 40`. The conditional watchpoint
slowed the compile to the point that it hadn't finished after
several minutes. An unconditional watchpoint would catch every
normal install/uninstall write (hundreds or thousands of events)
and require manual walk-through to find the anomalous one — doable
but time-consuming.

## Candidate hypotheses

None confirmed. Possible angles:

1. **Stack-top corruption in cache path.** Something in the cache-save chain
   (`cache_store` → `cache_flush` → `_save_manifest`, or earlier `cache_save_ast` /
   `cache_load_ast` hits from the resolver) decrements `@__qz_effect_stack_top`
   below the prelude install's slot. `handle_uninstall` checks `top > 0` but not
   `top > <prelude_slot>`. A pop-too-many could wipe the prelude defaults.

2. **TLS/global effect-stack asymmetry.** `stack_top` + `stack_names` +
   `stack_handlers` + `stack_op_filters` are global; `stack_bufs` + `stack_results`
   + `stack_resumed` + `stack_state_slots` are TLS. If the cache path transiently
   reads cached IR from a worker thread with top=0 view, a perform on that worker
   would see an empty stack. Quartz's compiler is single-threaded today, but some
   cache code may cross an unintentional thread boundary via a scheduler import
   side-effect.

3. **Piezo P5.1/P5.2/P5.3 body-wrap teardown double-pop.** The compile()-level
   body-wraps for Diag / State<TcCtx> / Emit each install-at-entry /
   uninstall-at-exit. If any teardown uninstalls more than it installed (an off-by-one
   in the bracket count) under the cache-save branch specifically, the prelude
   FileIo install gets popped. The body-wrap last-stmt memo
   (`feedback_body_wrap_last_stmt.md`) describes a related class of bugs.

4. **Effect-stack drift across the longjmp path for kind=2 `escape`.** `cg_codegen`'s
   Emit wrap is the last wrap to tear down before cache save. If Emit's perform-kind=2
   path leaves stack_top at a low number, cache-save runs with a partially-restored
   stack.

## Next-step investigation plan (post 2026-04-23 session)

Previous plan items 1 (instrument unhandled) and 4 partially done
(see Diagnostic findings above). Updated probe order:

1. **Unconditional lldb watchpoint** on `&__qz_effect_stack_top`.
   Instead of filtering with `top > 40`, let every write fire and
   use `watchpoint command add` to log each write's value + source
   line. Expected behavior: hundreds of 0→1→2→... transitions, then
   one anomalous 0→8635 or 1→8635. The anomalous one's backtrace
   points at the wild writer.
2. **ASAN-built compiler**. `clang -fsanitize=address -g` on the
   emitted `tmp/build.ll` + runtime. Run the cache-enabled self-
   compile; ASAN should flag the out-of-bounds write that hits
   `@__qz_effect_stack_top`.
3. **Memory-neighbor canary.** Define a read-only global at exactly
   `sizeof(i64)` before `@__qz_effect_stack_top` (e.g., via a
   deliberate padding global) with a sentinel value. If the canary
   gets clobbered too, the wild write is a buffer underflow from an
   adjacent allocation. If only stack_top is hit, the write is
   specifically targeting stack_top's address.
4. **Bisect the cache path by wrap.** Keep `depgraph_save`'s wrap
   intact; delete only the `quartz.qz:1109-1112` wrap (`fio_write`
   for `module_paths.txt` + `whole_program.ll`). If that triggers
   the crash, focus on what ran before line 1109 (cache_store ×N +
   cache_flush — both of which call `_save_manifest`'s `fio_write`).
5. **Search for `8635` in the source.** grep for any literal 8635
   or for computations that might produce it (string hash of some
   deterministic input? vec size after some loop?).

The rolling `.fixpoint` stamp and golden backup (`quartz-pre-p54e-option-z-golden`
and `quartz-pre-path-a-golden`) let the next session branch, experiment,
and restore the known-good compiler cheaply.

## Scope recommendation

Whoever resolves this bug should:
- Reinstate the wrap deletions (38 callsites across resolver/build_cache/codegen_separate/
  dep_graph/typecheck/typecheck_util/quartz.qz) in a fresh commit,
- Delete the one `can FileIo` annotation on `_resolve_search_paths`
  (resolver.qz:270) in the same commit,
- Verify `quake guard` passes + cache-enabled `quartz --no-opt self-hosted/quartz.qz`
  produces IR (not exit 66).

The deletion itself is mechanical (~100 LOC cleanup). The blocker is purely the
unhandled-op bug above.

## P5.5.c Pass 2b cross-symptom finding (2026-04-23)

Attempted the same wrap-deletion pattern for Intern in P5.5.c Pass 2b
(drop the `_tc_intern` / `_tc_resolve` body-wraps in typecheck_registry.qz
+ the inline `with Intern` wrap in build_cache.qz; rely on a prelude-installed
`@intern$intern_default_handler`). Pass 2b failed guard step 3 with the
SAME `unhandled effect op called` symptom — but this time on `Intern.intern`
(not `FileIo.fio_write`), and under `--no-cache` (not cache-enabled).

Key lldb finding inside Pass 2b binary:

```
(lldb) bt 3
  frame #0: __qz_effect_unhandled
  frame #1: __qz_effect_perform + 340
  frame #2: typecheck_registry$tc_lookup_function_index + 140
...
(lldb) memory read -fx -s8 -c1 0x1005d5a50    ; __qz_effect_stack_top
0x1005d5a50: 0x0000000000000002
(lldb) p (char*) 0x1005cd240
(char *) "Throws"
(lldb) p (char*) 0x1005cd247
(char *) "Log"
```

`stack_top == 2` at crash. `@main`'s prelude installed 5 defaults
(Throws, Log, Async, FileIo, Intern). Three of them (Async, FileIo,
Intern) were popped off the stack between `@main`'s prelude and the
first compile-time `tc_lookup_function_index` call — with no
corresponding installs to match the pops. Static IR count: 120 install
calls vs 112 uninstall calls. After subtracting the 5 non-popping
prelude installs, the balance is 115 install vs 112 uninstall —
three body-wrap install/uninstall pairs are missing their uninstall
in the static emission OR some runtime path decrements past the
matching install.

Both the FileIo (`top=8635`) and Intern (`top=2`) failures present
as "stack_top holds a value inconsistent with the number of recent
pushes." FileIo's 8635 is harder to source-locate (no Quartz code
writes that literal), Intern's 2 is a plausible uninstall-overshoot
value. These look like **two faces of the same bug**: body-wrap
deletion exposes a latent stack-accounting asymmetry in the effect
runtime or in body-wrap codegen.

Pass 2b was reverted 2026-04-23 in favor of preserving P5.5.c Pass 1
(`0e3d1d4c`: blessed-relaxation) and P5.5.c Pass 2a (`2d7eadbb`:
codegen install + flag plumbing, body-wraps intact). The retrofit
unblocks once this bug is rooted out.

Next probes specific to Pass 2b:

1. **Log every install/uninstall with `top_before`**. Wrap both with
   `write(2, ...)` printf-style (needs a debug-only codegen switch)
   and see which uninstall is the first one popping below 5 without
   a matching install. Scoping the probe to the first 10–20 calls
   might isolate it.
2. **Static audit of body-wrap codegen for multi-exit leaks**. A
   body-wrap with an early-return inside its do-block may emit two
   uninstalls but only one install. Search `cg_emit_handle_install`
   + `cg_emit_handle_uninstall` call counts in mir_lower for
   `NODE_WITH` handling and verify symmetry under all MIR terminators.
3. **kind=2 unwind path**. `with E { op: h } do -> escape(x) end` uses
   longjmp to leave the do-block. Verify that unwinding decrements
   stack_top the right number of times (not 0, not N+1). Pass 2b
   exposes this because Pass 2a's body-wrap installs would otherwise
   counter any underflow.

## Resolution (2026-04-23, `a6f174ae`)

Root cause: **asymmetric overflow handling between `__qz_effect_handle_install`
and `__qz_effect_handle_uninstall`** at the static 32-slot cap on the effect
stack (`[32 x i64]` global arrays: `__qz_effect_stack_names`, `_handlers`,
`_bufs`, `_results`, `_op_filters`, `_resumed`, `_state_slots`).

- Install silently skips (no-op) when `stack_top >= 32`. Top stays at 32.
- Uninstall unconditionally decrements `stack_top` when it's `> 0`.

When a wrap attempted installation at `top==32`, the install recorded as a
no-op but the matching uninstall later still decremented, **popping a
legitimately-installed entry from below**. Over many "overflow incidents"
during self-compilation, `stack_top` drifted downward, eventually drained
the 5 prelude default handlers (Throws/Log/Async/FileIo/Intern at slots
0..4), and subsequent performs hit `__qz_effect_unhandled`.

### Diagnostic trace (2026-04-23 session)

Instrumented a gen2 compiler with per-install/per-uninstall
`dprintf(2, "±%s top=%ld\n", eff_name, top_before)` logging + a strict
`top < 5` abort guard in `handle_uninstall`. Running the instrumented binary
on `examples/style_demo.qz` produced the trace. Key observations:

- Prelude: 5 installs (Throws top=0, Log top=1, Async top=2, FileIo top=3,
  Intern top=4) — expected.
- Max observed `stack_top`: **33**, with `+Intern top=32` attempting a push
  that the 32-cap silently skipped.
- First drop below prelude occurred at event number 18386 in the trace:
  a `-Diag top=5` uninstall that brought top to 4, popping the prelude
  Intern slot.
- From prelude ship to first underflow: 1500 Diag installs, 1494 Diag
  uninstalls, plus many Intern/FileIo cycles — overall 9198 installs vs
  9186 uninstalls recorded in the log (delta +12), but actual `stack_top`
  was 5 at the trap entry because ~8 of those installs silently failed at
  the 32-cap.

The two reported symptom values (`FileIo.fio_write top=8635` and
`Intern.intern top=2`) were both consequences of this same mechanism;
8635 was the specific drift level reached during self-compilation's
cache-save path, 2 was the level at the simpler Pass 2b reproducer.

### The fix

Commit `a6f174ae` raises the array size and cap from 32 to 256:

- `codegen_runtime.qz`: 14 global decls (7 linkonce_odr + 7 internal),
  16 GEPs, 1 install cap check (`icmp slt %top, 256`).
- `codegen_instr.qz`: 4 GEPs in the with-block install/uninstall emission.

Untouched: jmpbuf allocas (codegen_runtime.qz:2688-2689 and
codegen_instr.qz:2074) — those are sigjmp_buf sizing, unrelated to the
effect stack.

This gives 256/33 = 7.7× headroom over the self-compile's max observed
depth. A truly symmetric design (e.g. always-increment `stack_top` on
install + bounds-checked reads in perform/state-accessors) is filed as
a followup; 256 is adequate for the practical range of wrap-nesting
depths in compiler dogfooding.

### Verification

- `quake guard` PASSED (fixpoint 2327 functions).
- Cache-enabled `quartz --no-opt self-hosted/quartz.qz` produces 1.8M
  lines of IR, exit 0 — the exact path that previously crashed.
- dep_graph.qz's two FileIo wraps (the memo's reliably-triggering repro)
  deleted cleanly in commit `7d747304` as a demonstrative cleanup;
  cache-enabled self-compile still passes.
- P5.5.c Pass 2b retrofit unblocked in commit `2f026294`; user
  `with Intern { intern: my_mock }` overrides now reach registry
  interning end-to-end (standalone test at
  `/tmp/intern_customization_test.qz` passes: mock handler invoked
  on `intern("hello")` call from inside `compile()`-scope).

### Remaining followup

The scope recommendation still stands for a bulk-cleanup commit: the
**remaining 36 FileIo wraps** (quartz.qz, resolver.qz, typecheck.qz,
typecheck_util.qz, codegen_separate.qz, build_cache.qz) + the lone
`can FileIo` annotation on `resolver.qz:270::_resolve_search_paths` can
be dropped. Mechanical editing, each wrap reducing to the body expr or
statement. Estimate: one focused session (~30-60 min of Edit calls).
No further debugging required.
