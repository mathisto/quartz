# Progress Sprint Quirks (Apr 12-13, 2026)

Ten compiler / typechecker bugs surfaced during the `std/progress` + idle-hook + async `sh()` sprint on branch `worktree-progress-effect-ticking`. Each had a workaround in place (documented in `feedback_quartz_module_quirks.md`); this file tracked them as proper issues so the permanent fixes could be sequenced.

**Roll-up status as of 2026-04-29:**
- ✅ **Closed: 9 of 10** — PSQ-1, -2, -3, -4, -5, -7, -8, -9, -10 all closed Apr 15-19.
- ⚠️ **Still open: PSQ-6 only** — `Vec.size` cross-thread read returns 0 from poller thread. Stream G (Apr 29) diagnosed as non-atomic global-pointer load on weak-memory ARM, but the proposed 1-LOC `load atomic ... acquire` fix is incomplete on memory-model grounds (acquire-load needs paired release-store; writer is `_g_live_actives.push()` compiling to plain non-atomic stores). Real fix needs design: either all-globals-atomic (perf cost), or marker-for-shared-globals + selective atomic, or std-level mutex discipline. Multi-session work; deferred.

When PSQ-6 lands, this whole file moves to `docs/bugs/done/`.

Relevant commits (context, not cause):
- `945cc265` — `sched_idle_hook_set/clear` intrinsic
- `1a60633c` — async-aware `std/process.qz` + Live render mutex

Severity legend: **BLOCKER** = prevents a planned feature; **HIGH** = silent wrong data or crash; **MEDIUM** = wrong but noisy; **LOW** = cosmetic / DX.

---

## PSQ-1: Methods leak as 2-arg free functions, colliding with same-named free functions

> **Severity**: BLOCKER (for `import * from progress`)
> **Status**: CLOSED — Apr 15, 2026 (D4 verified no longer reproduces, workaround reverted, regression-locked by `spec/qspec/method_arity_collision_spec.qz`)
> **Component**: typechecker / UFCS resolution
>
> **Resolution.** Some earlier commit (pre-D4, between the original PSQ-1
> filing and Batch D) implicitly closed the underlying call-resolution
> issue. When D4 went to reproduce the bug against current trunk, the
> reproducer compiled cleanly. Full `quake build`, `progress_spec` (56/56),
> and targeted UFCS regression sweep (impl_trait, hybrid_ufcs_traits,
> iterable_trait, arity_overload, iterator_protocol) are all green after
> reverting the `fail_with` / `warn_with` workaround to `fail` / `warn`.
> `spec/qspec/method_arity_collision_spec.qz` now locks in the five
> observable behaviors so this cannot regress silently:
> - free function beats impl method at matching arity
> - impl method still callable via dot syntax
> - impl method still callable via UFCS when no free function collides
> - arity overloading of free functions still works
> - wildcard-imported impl method does not clobber a local free function
>   (the exact shape that PSQ-1 originally reported)

### Symptom

Defining `Progress.fail(self, s)` in an impl block, then importing the module via `import * from progress` into a file that also defines a free `def fail(msg: String)`, causes the typechecker to report:

```
Function fail requires at least 2 arguments, got 1
```

when a single-arg call `fail("message")` should resolve to the free function. The typechecker matches `fail(...)` against the 2-arg method (treated as a free function via UFCS) instead of the 1-arg free function with matching arity.

### Root cause hypothesis

Quartz's open UFCS treats impl methods as free functions whose first param is the receiver. The resolver picks a match without considering that arity mismatches should disqualify. The correct behavior: when a call site supplies N arguments, a free function with `N` params must beat a method-as-free-function with `N+1` params at the same name.

### Fix direction

`typecheck_expr_handlers.qz` call resolution: prefer exact-arity name matches (true free functions) before UFCS-expanded method matches. Or: disallow method-as-free-function resolution entirely and require dot-syntax for impl methods.

### Workaround in tree

Rename impl methods that collide: `Progress.fail` → `Progress.fail_with`, `Progress.warn` → `Progress.warn_with`.

---

## PSQ-2: `import progress` inside `std/quake.qz` cascades module-system failure downstream

> **Severity**: BLOCKER (for lifting `sh_with_progress` into `std/quake.qz`)
> **Status**: CLOSED — Apr 19, 2026 (no longer reproduces). Verified by injecting `import * from progress` at line 22 of `std/quake.qz` and compiling `Quakefile.qz` clean: 13 modules loaded (was 5 at the time of filing), full IR emitted, binary builds, `/tmp/qf --help` runs successfully. Presumed implicitly fixed by the Apr 15 resolver full-scope-tracking work (Tier 3 #11, commit range `c4086eea..d1c58715`) or the Maranget pattern-matrix parser rework (Apr 16). Regression coverage is via `spec/qspec/reexport_spec.qz` (10/10) which already exercises the transitive-wildcard-import pattern PSQ-2 described — the bug was a specific shape of that general behavior.
>
> **Follow-up (not a bug, just the deferred lift):** `sh_with_progress`, `live_phase`, `_qjson_get_string`, `_qf_fmt_elapsed`, and the `_qf_swp_bar` callback plumbing (Quakefile.qz:1-163) can now be moved into `std/quake.qz` so every user Quakefile gets progress-bar support for free. Not urgent — the workaround "duplicate in every Quakefile" is ugly but functional, and the lift is ~163 lines of mechanical move + dedup. Sequence after a fresh session's budget.
> **Component**: module resolver / load order — was, anyway. No longer a component-attributable bug.

### Symptom

Adding `import progress` at the top of `std/quake.qz` makes `Quakefile.qz` fail to compile with cascading errors:

```
fail undefined
color_red undefined
color_reset undefined
...
```

even though `Quakefile.qz` uses `import * from quake` which should pull those symbols. Module count drops from 11 to 5 when this happens, suggesting `std/quake.qz` fails to fully initialize.

### Root cause hypothesis

Module-system load-order bug in `resolver.qz`. When `std/quake.qz` imports `progress`, and a downstream file wildcard-imports `quake`, the resolver's topological sort may be dropping `quake`'s symbols from the symbol table — possibly because `progress` re-exports something that conflicts with `quake`'s own re-exports, or because the mutual-import fixpoint iteration terminates too early.

### Fix direction

Repro minimally (not just in the Quartz build — three-file repro in `/tmp/`), then `--dump-modules` on the failing compile to see which symbols get dropped. Likely in `resolver.qz` — symbol visibility computation.

### Impact

Until fixed, `sh_with_progress` and `live_phase` live in `Quakefile.qz` (duplicated for any user Quakefile, defeating the "ship progress bars with every Quake task" dogfood).

---

## PSQ-3: `var end = ...` breaks the parser with no useful diagnostic

> **Severity**: MEDIUM (DX paper cut, but the cascading garbage is misleading)
> **Status**: CLOSED — Apr 19, 2026 (resolved by the D3 QZ0530 refactor; regression-locked by `spec/qspec/reserved_ident_spec.qz:25-32` which asserts `var end = 42` produces exactly one `QZ0530` diagnostic. 6/6 green.)
> **Component**: parser / lexer

### Resolution

`ps_expect_binding_name` at `self-hosted/frontend/parser.qz:485` routes every reserved-keyword binding-site collision through a single `QZ0530` diagnostic and returns the keyword lexeme as a placeholder so parsing can continue without desyncing. The "cascading symbol-registry corruption" described in the original symptom was resolved when this helper replaced the legacy `ps_expect(TOK_IDENT, ...)` calls at `var`/`def` param / for-loop / match-pattern binding sites.

The one remaining wart — that the original reproducer's `return end` (using `end` as an *expression*) produces an additional parse error at the function's closing `end` — is a separate expression-level issue (reserved keyword misused as a primary expression), not PSQ-3. Covered by `stress_type_system_spec.qz` at a different angle.

### Original symptom (archived)

```qz
def foo(): Int
  var end = 42       # end is a reserved keyword
  return end
end
```

produces cascading `fail undefined`, `color_* undefined` errors throughout the module — NOT a clean parse error. The parser misinterprets `var end =` as a malformed block-end and corrupts the symbol registry for the rest of the file.

### Expected

```
error: `end` is a reserved keyword and cannot be used as an identifier
  --> file.qz:2:7
  |
2 |   var end = 42
  |       ^^^
```

### Fix direction

`frontend/parser.qz` `parse_var_stmt` / `parse_identifier`: when the next token is a reserved keyword, emit a clear diagnostic instead of trying to parse it as a `var` that happens to terminate the block. Apply to all reserved words: `end`, `begin`, `def`, `var`, `if`, `for`, `while`, `match`, `impl`, `trait`, `import`, `return`, `self`, `true`, `false`.

### Workaround

Never name a variable `end`. Use `v_end`, `pos_end`, `last`, etc.

---

## PSQ-4: `Vec<T>` element type lost on indexed access — **silent wrong-struct field resolution**

> **Severity**: HIGH — silent wrong-data reads, compiles and runs
> **Status**: CLOSED (Apr 15, 2026) — fix landed in `mir_lower_stmt_handlers.qz` + `mir_lower_iter.qz`. Regression-locked by `spec/qspec/vec_element_type_spec.qz` (10 tests, 3 new for the worst case).
> **Component**: MIR lowering — for-loop iter variable annotation propagation
>
> **Less-dangerous symptom closed** by C2 (commit `9517ef5b`, Vec<Struct> ptype). **Worse symptom still open** — minimal repro below.
>
> ```qz
> struct Progress
>   name: String; state: Int; pct: Int; total: Int; step: Int
>   _ended: Int  # offset 5
> end
> struct Live
>   screen: Int; a: Int; b: Int; c: Int; d: Int
>   e: Int; f: Int; g: Int; h: Int; i: Int
>   _ended: Int  # offset 10
> end
> def main(): Int
>   var l = Live { screen: 10, a: 0, b: 0, c: 0, d: 0, e: 0, f: 0, g: 0, h: 0, i: 0, _ended: 99 }
>   var actives: Vec<Live> = vec_new()
>   actives.push(l)
>   var total = 0
>   for item in actives
>     total += item._ended       # reads Progress._ended at offset 5 → total=0, not 99
>   end
>   puts("total=#{total}")       # prints "total=0"
>   return 0
> end
> ```
>
> With only `Live` in scope, prints `total=99`. With both `Progress` and `Live` in scope, prints `total=0`. Silent wrong-struct resolution through the `for item in Vec<Live>` binding.

### The worse symptom

Two structs share a field name (e.g., `Progress._started` at offset 5 and `Live._started` at offset 10). Inside a function that reads `var x = vec[i]; x._started`, the typechecker silently picks the **wrong** struct's field offsets — no error. The IR loads the field at the wrong offset and you get garbage data (typically a heap pointer or unrelated int from an adjacent field).

Hit **twice in a single commit** (`1a60633c`):
1. `_live_idle_render` walking `_g_live_actives: Vec<Live>` and reading `live._ended` — resolved to `Progress._ended`, read wrong offset
2. `_qf_on_phase_line` calling `bar.inc(1)` on a `Vec<Progress>` element — resolved to wrong struct's method

### The older (less dangerous) symptom

Inside an `it("...") do ->` closure:

```qz
var cols = progress_parse_template("{spinner}")
cols[0].kind    # Error: Unknown struct: Struct, unknown
```

The typechecker can't infer that `cols` is `Vec<Col>` and therefore `cols[0]` is `Col`.

### Root cause (confirmed)

The hypothesis was partly wrong. The bug was NOT in the typechecker — the typechecker correctly types `item` inside `for item in Vec<Live>` via `tc_ptype_arg1` and `tc_scope_bind`. The bug was in the MIR lowering layer:

1. `mir_lower_stmt_for` only populated the iter var's struct type annotation when the body started with a `NODE_STRUCT_DESTRUCTURE` pattern. For regular `for item in vec`, no annotation was recorded.
2. When `item._ended` hit codegen, `mir_infer_expr_type` looked up `item` in `struct_types` → empty → `mir_lower_field_access` fell through to `mir_find_field_globally` → picked the **first** struct with a matching field name in registration order.
3. Since `Progress` was declared before `Live`, `mir_find_field_globally` picked `Progress._ended` at offset 5 instead of `Live._ended` at offset 10. Silent wrong-data.

The two-headed framing was accurate in spirit: the fallthrough search was the *exploit*, and the missing annotation was the *primary*. Fixing the primary closes the exploit for `for item in vec` shapes. The global-search fallback still exists for record/intersection types; hardening it is tracked separately (see ROADMAP `B3-HARD-ERROR-FALLBACK`).

### Fix (landed)

`self-hosted/backend/mir_lower_iter.qz`: `lower_vec_iteration` takes a new `annotation_hint` parameter that marks the iter var's struct type for field-access resolution **without** changing the vec_get dispatch (the existing `elem_type` parameter is reserved for @value struct layout and destructure patterns — using it for non-@value structs would flip semantics from pointer-share to memcpy-copy).

`self-hosted/backend/mir_lower_stmt_handlers.qz`: `mir_lower_stmt_for` computes the annotation from two sources:
1. `mir_ctx_get_vec_elem_type(iter_ident)` — populated at let-statement time from `var v: Vec<T>` annotations (line 126 of the let handler).
2. `mir_infer_expr_type(iter_node) → mir_extract_generic_element_type` — fallback for call expressions returning a Vec.

Inner generic args are stripped (`GBox<Int>` → `GBox`) and the struct name is resolved through `mir_resolve_struct_name`.

### Workaround (no longer needed post-fix)

Pre-fix the workaround was typed local bindings + method dispatch:

```qz
var live: Live = _g_live_actives[i]
live.tick()              # method dispatch is type-safe
# AVOID: live._ended     # may resolve to Progress._ended (wrong offset)
```

Post-fix, `for live in _g_live_actives; live._ended` resolves correctly.

### Why this was the top priority

Compiled cleanly, ran cleanly, returned garbage. No error message, no crash, just wrong behavior. The debugging cost once this bit was enormous — you were chasing a phantom because the code "looked right." Every other bug on this list announced itself; this one hid.

---

## PSQ-5: `eputs("msg\n")` produces doubled newlines

> **Severity**: LOW (cosmetic)
> **Status**: CLOSED — Apr 19, 2026 (Option 2 — documented as auto-newlining; codebase audit found zero live callers passing a trailing `\n`. The offending callers only exist in `self-hosted/*.qz.save` backup files, not source. Regression-locked by `spec/qspec/eputs_newline_spec.qz`.)
> **Component**: stdlib — `eputs` implementation

### Resolution

`eputs` is implemented as `fprintf(stderr, "%s\n", s)` at `self-hosted/backend/codegen_runtime.qz:1241-1252` using format string `@.fmt.sn = "%s\n\0"`. This mirrors libc `puts(stdout)` behavior and is the deliberate contract: **both `puts` and `eputs` auto-append exactly one newline**.

Codebase audit (Apr 19 2026): `grep -rn 'eputs("[^"]*\\n"'` across live source (`self-hosted/*.qz` excluding `.save` backups, `std/`, `tools/`, `examples/`, `spec/`) returns zero matches — the only remaining hit is a single commented-out line in `self-hosted/frontend/macro_expand.qz:1393` (safe). 125 total `eputs(` call sites, all correctly using bare strings.

Regression-locked by `spec/qspec/eputs_newline_spec.qz` (3 tests): verifies `eputs("hello")` produces exactly one trailing newline, `eputs("line1\n")` produces two (documented as expected), and `puts("hi")` mirrors the stdout contract. This prevents anyone from "fixing" `eputs` to drop the auto-newline — doing so would silently break every live caller.

### Original symptom (archived)

```qz
eputs("error: something went wrong\n")
```

outputs two newlines at the end. `eputs` already appends `\n` the way `puts` does, so the trailing `\n` in the string produces a blank line.

---

## PSQ-6: `Vec.size` in while-loop reads 0 when called from I/O poller thread

> **Severity**: HIGH — wrong data, silent
> **Status**: CLOSED — 2026-04-30 via type-system enforcement.
>   The Sched-effect work (`docs/design/SCHED_EFFECT_THREAD_SAFETY.md`)
>   ships `can Sched` as a callback-context marker plus a body-walk
>   Sync check (Phase C). `_g_live_actives` rewritten as a Mutex-
>   protected slot in `std/progress.qz`; `_live_idle_render` now
>   reads via `mutex_lock` + `as_type<Vec<Live>>` to a fresh local.
>   The cached-size workaround is gone.
>   Closed by commits `03a6fa95` (Phase B call-site QZ1408) +
>   `21941d49` (Phase C+D body-walk + Mutex rewrite).
> **Component**: codegen / memory model — cross-thread global Vec reads

### Symptom

A function called from the M:N scheduler's I/O poller pthread (registered as an idle hook target) reads `_g_some_global_vec.size` as `0` in a while-loop condition, even when the actual size is 1. The main thread sees the correct size, and main-thread calls to the same function work fine.

```qz
# BROKEN — reads _g_live_actives.size as 0 from poller thread
def _live_idle_render(): Void
  var i = 0
  while i < _g_live_actives.size   # reads 0
    ...
    i += 1
  end
end

# WORKS — cached local read
def _live_idle_render(): Void
  var sz = _g_live_actives.size    # cached read returns correct value
  var i = 0
  while i < sz
    ...
    i += 1
  end
end
```

Repro is in `std/progress.qz _live_idle_render` (commit `1a60633c`).

### Root cause hypothesis

Candidate explanations (need investigation):

1. **Non-atomic global load**: Quartz globals are loaded without memory ordering. On ARM, a concurrent write from the main thread may not be visible to the poller pthread without a barrier. The cached-local workaround happens to load once at entry when the barrier fires implicitly via function call.
2. **Register allocation**: The codegen may hoist the `_g_live_actives.size` load out of the while condition and cache it in a register — but then cross-thread invalidation doesn't flush the register.
3. **Calling convention mismatch**: The I/O poller is called from emitted C runtime IR, not from Quartz user code. The function prologue may not establish the expected TLS/globals state.
4. **Vec size field layout**: `Vec.size` reads field 0 of the Vec struct pointer. If the global Vec pointer itself is stale (cached in TLS) when called from a non-Quartz thread, the `.size` read is against stale memory.

### Fix direction

First: add logging that dumps the global Vec's address and the address of `_g_live_actives.size` on every iteration, from both threads, and compare. If addresses match but values differ, it's a memory-ordering bug. If addresses differ, it's a globals caching bug.

Likely fix: emit cross-thread-safe loads for global Vec fields, OR add a barrier at the top of functions registered as scheduler callbacks.

### Related

`feedback_quartz_module_quirks.md` item 6 for the full workaround pattern. This may also affect signal handlers and any future non-Quartz-thread callback registration.

---

## PSQ-7: Audit suspendable-effect leaves for `uses_scheduler` flag propagation

> **Severity**: BLOCKER (latent linker errors) — one case already fixed
> **Status**: CLOSED — Apr 15, 2026 (D5: audited every leaf, no gaps found, 2 atomic slot reads upgraded, regression-locked by `spec/qspec/scheduler_effect_leaves_spec.qz`)
> **Component**: `mir_lower.qz` — effect leaf registry, `codegen_runtime.qz` — poller atomics
>
> **D5 audit result (Apr 15, 2026)**. Probed every suspendable leaf from
> bare `main()` without `sched_init()`: channel send/recv/recv_timeout/
> try_recv/try_send, channel_new_unbounded, mutex_lock/unlock, rwlock
> read/write, sched_yield, sched_idle_hook_set/clear. All 9 leaf probes
> compile cleanly, link, and run — no `@__qz_sched*` or `@__qz_completion*`
> undefined-symbol errors. The `NODE_AWAIT` fix in `1a60633c` was the
> only missing propagation; no others surfaced.
>
> **Two atomic slot read fixes applied during the audit**:
> - `__qz_sched_worker`'s `do_yield` branch read slot 8 (shutdown flag)
>   non-atomically outside the global mutex. Changed to
>   `load atomic ... acquire` to pair with the shutdown path's write.
> - `__qz_sched_spawn`'s entry read slot 34 (drain flag) non-atomically
>   before acquiring the global mutex. Changed to
>   `load atomic ... acquire` to pair with the shutdown path's mutex-
>   protected write.
>
> Slot-35 (idle hook) was already atomic per `1a60633c`. Slots 10, 16,
> 18 are either initialized once and read under mutex, or written via
> `atomicrmw`. Slot 8 reads outside do_yield are either atomic
> (`monotonic`/`acquire`) or inside the global mutex.
>
> 8-test regression-lock spec guards the leaf probes from future
> regressions. Finding propagation gaps now fails QSpec, not just
> the linker at build time.

### The fixed case

Pure `async ... await` from `main()` (no `go`, no `sched_spawn`, no other scheduler intrinsic) used to emit `completion_watch` calls referencing `@__qz_completion_map`, but the runtime decls for that global were gated on `mir_get_uses_scheduler()`. Result: LLC link error `use of undefined value '@__qz_completion_map'`.

Fix landed in `1a60633c`: `mir_lower.qz` now calls `mir_set_uses_scheduler(prog)` in the non-async-await path of `mir_emit_completion_await`.

### What's left

Other suspendable-effect leaves may have the same latent issue. When called from a non-async context that doesn't otherwise touch the scheduler, they should still flip `uses_scheduler` to pull in the runtime decls.

**Leaves to audit**:
- `io_suspend(fd)` — used by `std/process.qz` async sh helpers
- `channel_send` / `channel_recv` / `try_recv` / `try_send` / `try_recv_or_closed` — channel ops
- `mutex_lock` / `mutex_unlock` / `mutex_try_lock` — mutex ops
- `rwlock_read_lock` / `rwlock_write_lock` — read-write locks
- `condvar_wait` — condition variables
- `completion_block` / `completion_watch` — direct completion ops
- `sched_yield`
- `go_priority(task, level)`

**Audit procedure**: for each leaf, construct a minimal program that uses it from `main()` without ever calling `sched_init()` or any obvious scheduler intrinsic. Compile to IR and grep for undefined `@__qz_sched*` and `@__qz_completion*` globals. Each failure is a separate fix in `mir_lower.qz` along the same lines as the `NODE_AWAIT` fix.

### Related: weakly-ordered slot reads in poller

Also found in `1a60633c`: the I/O poller's `load` of scheduler slot 35 (idle hook) was not atomic, fixed in place as `load atomic ... seq_cst`. Audit other slot reads in `codegen_runtime.qz`'s `__qz_sched_io_poller` for similar weakly-ordered access:

- slot 8 — `shutdown`
- slot 10 — `init`
- slot 16 — `active_tasks`
- slot 34 — `drain`

Each of these is written by the main thread and read by the poller pthread. Without atomic load semantics the poller may observe stale values.

---

## PSQ-8: Typechecker accepts wrong-arity builtin calls, compiler crashes in codegen

> **Severity**: MEDIUM — compile-time crash (no wrong-data risk, no IR produced)
> **Status**: CLOSED (Apr 15, 2026) — concurrency primitives now registered with `tc_register_builtin_with_arity`. The arity check was already wired into `tc_expr_call`; the bug was that specific builtins bypassed it via `tc_register_builtin` (no arity). Regression-locked by `spec/qspec/builtin_arity_spec.qz` (10 tests).
> **Component**: typechecker — builtin arity validation, `tc_register_builtin` / `tc_expr_call`

### Symptom

Calling a scheduler/concurrency builtin with the wrong arity produces a compiler runtime crash from Quartz-level code rather than a clean diagnostic:

```
$ ./self-hosted/bin/quartz /tmp/probe.qz
[mem] resolve_pass1: 5 MB, 1 modules
[mem] resolve_pass2: 5 MB
index out of bounds: index 0, size 0
```

Reproducer:

```qz
def main(): Int
  var m = mutex_new()   # mutex_new takes 1 arg (initial value), user passed 0
  return 0
end
```

Passing the correct arity (`mutex_new(0)`) works. The typechecker lets the 0-arg form through to codegen, where `cg_intrinsic_conc_sched.qz`'s `mutex_new` handler reads `args[0]` and crashes with index-out-of-bounds because `args` is empty. Same shape reproduces for other mutex/rwlock/condvar/channel intrinsics.

### Root cause (confirmed)

The handoff's hypothesis about a missing registry field was wrong. `tc_register_builtin_with_arity` already existed in `typecheck_builtins.qz` and `tc_expr_call` already consulted `tc_lookup_builtin_min_arity` / `tc_lookup_builtin_max_arity`. The bug was simply that the concurrency primitives were registered via `tc_register_builtin` (which takes return type only) instead of the `_with_arity` variant. Calls to these went through the "no explicit arity — skip count check" branch at `tc_expr_call` lines 2366-2369, then handed an empty `args` vec to the codegen intrinsic handler, which crashed reading `args[0]`.

### Fix (landed)

`self-hosted/middle/typecheck_builtins.qz`: switched every concurrency primitive to `tc_register_builtin_with_arity`:
- `mutex_new` (1), `mutex_lock` (1), `mutex_unlock` (2), `mutex_try_lock` (1), `mutex_free` (1)
- `Mutex$lock`, `Mutex$unlock`, `Mutex$try_lock`, `Mutex$free` (same)
- `rwlock_new` (1), `rwlock_read` (1), `rwlock_read_unlock` (1), `rwlock_write` (1), `rwlock_write_unlock` (2), `rwlock_free` (1)
- `RWLock$read`, `RWLock$read_unlock`, `RWLock$write`, `RWLock$write_unlock`, `RWLock$free` (same)
- `channel_new` (1), `channel_new_unbounded` (0), `channel_free` (1), `Channel$free` (1)

No other code changes were needed — the existing arity check in `tc_expr_call` handles the rest. This is a much cleaner fix than the "new registry field + signature change + `tc_expr_call` refactor" the handoff anticipated.

### Related leaves discovered in same audit

All of the following also crash with "index out of bounds: index 0, size 0" when called with 0 args from bare `main()`:
- `mutex_new()`, `mutex_lock()`, `rwlock_new()`, `rwlock_read()`
- probably most `cg_intrinsic_conc_*.qz` handlers assume `args.size >= 1`

None of these crashes are specific to the scheduler-leaf class; they're a general typechecker gap for builtin arity.

---

## PSQ-10: `and`/`or` short-circuit codegen allocates a cell on the heap per evaluation

> **Severity**: HIGH (silently corrupts any tight loop that uses `and`/`or` as the loop condition)
> **Status**: CLOSED — Apr 19, 2026. Two-line fix in `mir_lower_expr_handlers.qz`: OP_AND and OP_OR handlers swapped `mir_emit_alloc(1)` for `mir_emit_alloc_stack(1, "")`. The result slot is function-local and never escapes, so escape analysis keeps it on the stack; MIR_ALLOC_STACK hoists a single alloca to fn-entry, reused across iterations. Per-iteration `call @malloc(i64 8)` is gone. Tight-loop programs now show zero malloc from `and`/`or` lowering (verified by IR inspection in `psq10_short_circuit_stack_spec.qz`). Bonus: compiler self-compile wall time roughly halved at the guard (22s → 11.5s gen1→gen2) because the compiler itself contains many `and`/`or` conditions in hot paths — it's a memory optimization for every Quartz program, not just kernel loops. Regression-locked by `spec/qspec/psq10_short_circuit_stack_spec.qz` (3 tests: no-malloc for both `and` and `or`, plus a short-circuit-semantics test that confirms RHS side-effects still don't fire when LHS determines the answer).
> **Component**: codegen — boolean short-circuit lowering (MIR-level).
> **Discovered:** KERN.3a virtio-net wait loop, Apr 18 2026.

### Symptom

A tight poll loop of the form:

```qz
while used_idx == 0 and spins < max_spins
  spins = spins + 1
  used_idx = volatile_load<U16>(addr)
end
```

allocates one 8-byte cell per iteration via `malloc`. With `max_spins = 200_000_000` this consumes ~1.5 GiB of heap before the loop would otherwise terminate, which exhausts a 64 MiB PMM pool in milliseconds and OOM-kills an otherwise correct freestanding kernel.

### IR evidence

Generated LLVM IR for the loop condition (trimmed):

```llvm
while_cond1:
  %v8 = load i64, ptr %used_idx, align 8
  %cmp_tmp10 = icmp eq i64 %v8, %v9
  %v10 = zext i1 %cmp_tmp10 to i64
  %alloc_11 = call noalias ptr @malloc(i64 8)      ; <-- per-iter alloc
  %v11 = ptrtoint ptr %alloc_11 to i64
  %cmp10 = icmp ne i64 %v10, 0
  br i1 %cmp10, label %and_rhs4, label %and_skip5
and_rhs4:
  ...
  %sptr_19 = inttoptr i64 %v11 to ptr
  store i64 %v18, ptr %sptr_19, align 8            ; stash RHS result
  br label %and_merge6
and_skip5:
  %sptr_13 = inttoptr i64 %v11 to ptr
  store i64 %v12, ptr %sptr_13, align 8            ; stash "false" sentinel
  br label %and_merge6
and_merge6:
  %loptr_20 = inttoptr i64 %v11 to ptr
  %logep_20 = getelementptr inbounds i64, ptr %loptr_20, i64 0
  %v20 = load i64, ptr %logep_20, align 8          ; reload merged result
  %cmp20 = icmp ne i64 %v20, 0
  br i1 %cmp20, label %while_body2, label %while_exit3
```

An `alloca` or a phi would be the obvious lowering; heap allocation is indefensible here. The cell is never freed either — in a loop it's a monotonic drip.

### Expected

Lower `a and b` with either a phi:

```llvm
%result = phi i64 [ %rhs, %and_rhs ], [ 0, %and_skip ]
```

or an `alloca` in the function's entry block reused across iterations. Either eliminates the per-iteration heap pressure.

### Reproducer

```qz
def main(): Int
  var i = 0
  var stop = 1000000
  var x = 0
  while x == 0 and i < stop
    i = i + 1
  end
  return i
end
```

Compile with `--target x86_64-unknown-linux-gnu`, inspect the IR, observe `call noalias ptr @malloc(i64 8)` inside the loop's condition block.

### Workaround

Split the compound condition into a nested form:

```qz
while used_idx == 0
  if spins >= max_spins
    return 0 - 1
  end
  spins = spins + 1
  used_idx = volatile_load<U16>(addr)
end
```

This generates no heap allocs — just a sequence of compares and branches.

### Impact

- Any tight-loop with a compound condition gets the allocator involved.
- In freestanding / kernel code with a small bump allocator, OOM is near-instant.
- In hosted builds with glibc, the program still runs but bleeds memory at a rate proportional to loop trip-count. A polling loop that runs 100 M iterations leaks ~800 MB silently.

---

## PSQ-9: Parameter named `from` OOM-loops the typechecker

> **Severity**: HIGH (crashes the compiler with no error; easy to hit accidentally)
> **Status**: CLOSED — Apr 19, 2026. Root-caused to the parser's extern-fn param loop: `ps_expect(TOK_IDENT, ...)` at parser.qz:6084 fired `ps_error` but didn't advance when the current token was `TOK_FROM` (a hard keyword from the lexer's keyword table). The outer `while ps_check(ps, TOK_RPAREN) == 0` loop then re-ran forever, with each iteration appending an error message and re-attempting `ps_parse_type`. 11ms → never (OOM at 30 GB+) degenerates to 11ms → 11ms (single QZ0530 error, compile fails fast). Fix landed as two edits: (1) added `TOK_FROM`, `TOK_AS`, `TOK_WHERE`, `TOK_PRIVATE`, `TOK_PUBLIC` to `_ps_is_reserved_ident_token` at parser.qz:478-482 so `ps_expect_binding_name` rejects them cleanly with QZ0530; (2) switched `ps_parse_extern_fn`'s param parse from raw `ps_expect(TOK_IDENT)` to `ps_expect_binding_name("extern function parameter")` at parser.qz:6084-6092 so the reject path actually advances past the keyword. Regression-locked by `spec/qspec/psq9_from_param_spec.qz` (4 tests). Workaround in `tools/baremetal/hello_x86.qz` can be reverted back to `from` — the original name — but the fix doesn't require that (the rename is valid Quartz).
> **Component**: parser — keyword vs. identifier disambiguation at extern-fn param position.
> **Discovered:** KERN.1 context-switching scheduler sprint, Apr 18 2026 (commit `6bcacfba`).

### Symptom

Declaring an extern with a parameter named `from`:

```qz
extern "C" def switch_to(from: Int, to: Int): Void
```

compiles for ~30 minutes while RSS grows linearly past 30 GB. No error, no warning — the process just eats memory until killed. `exit=0` never arrives. Removing the declaration returns compile time to 0.08 s.

### Expected

Either (a) `from` should be a valid identifier (preferred — it's a very common parameter name in copy/move/context-switch APIs), or (b) the compiler should emit a parse/type error within the first few tokens, matching Quartz's normal reaction to reserved-word collisions.

### Actual

The compiler accepts the declaration into the parser but something downstream — probably the typechecker's name-resolution or scope-walk — gets wedged in a loop that allocates unboundedly. OS OOM-kill is the only recovery.

### Hypothesis

`from` is the tail keyword of `import * from module`. Quartz probably tokenizes it as a contextual keyword (only keyword-y in import position), but the identifier table or lookup path fails to distinguish the contexts when `from` appears in a parameter-list position. The resulting infinite recursion in scope resolution / type elaboration consumes memory bounded only by `ulimit`.

### Repro

```qz
extern "C" def foo(from: Int): Void

def main(): Int
  return 0
end
```

```
$ time ./self-hosted/bin/quartz --no-cache foo.qz
  # killed at 30 GB after several minutes
```

### Workaround

Rename the parameter. `from_slot`, `src`, `source` all work.

### Audit item

Grep the codebase for other reserved-word collisions that might be lurking (`in`, `to`, `do`, `end`, etc. as identifier positions). The fact that `from` silently wedged instead of erroring suggests the keyword-table lookup doesn't fail loudly — other keywords may share the trap.

---

## Suggested fix ordering

1. **PSQ-4** — silent wrong-data is the worst failure mode. Fix first, even though it's the deepest.
2. **PSQ-9** — silent compiler hang with unbounded memory. Mechanically dangerous (will trash a dev's machine); trivial repro; worth fixing next.
3. **PSQ-6** — also silent wrong-data, with a known repro. Investigate jointly; may share root cause with PSQ-4 if globals caching is the common thread.
4. **PSQ-7** — systematic audit, mechanical once the pattern is understood.
5. **PSQ-2** — unblocks the `sh_with_progress` lift into `std/quake.qz`.
6. **PSQ-1** — typechecker polish, unblocks wildcard imports of progress-shaped modules.
7. **PSQ-3** — DX paper cut, clean fix.
8. **PSQ-5** — cosmetic, anytime.

Total estimated quartz-time: 1-2 sessions for PSQ-4 alone (deep), 0.5-1 session for the rest combined.
