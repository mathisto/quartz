---
title: `%wb.pretop` (effect-install index) doesn't dominate perform fast-path use after a colorless-call resume — invalid IR
severity: Medium (effect handler whose body suspends, then performs again after the suspend — e.g. `local(..)` + `ask()` in one `with Reader` body)
surfaced: 2026-06-05 (full qspec run: effect_reader_p2b_spec "llc failed"; A.44 triage)
status: ✅ RESOLVED 2026-06-05 — frame-spill the install index to an fn_entry-hoisted slot; the perform static fast path reloads it. Fixpoint 2688.
related: docs/bugs/done/POLL_BODY_WB_RESULT_SLOT_DOMINANCE.md (sibling — result_slot dominance, hoisted to fn_entry)
---

# Resolution (2026-06-05)

Implemented the frame-spill from the fix direction below, mirroring the
sibling result_slot discipline:

* **`codegen.qz`** (HANDLE_INSTALL hoist block, alongside `%wb.jmpbuf.<dest>`
  / `%wb.result_slot.<dest>`): added a hoisted `%wb.pretop_slot.<dest> =
  alloca i64`. The alloca is position-independent so it lifts to `fn_entry`
  and dominates every block; only the *value* couldn't be hoisted.
* **`codegen_instr.qz`** install site (after the `%wb.pretop.<dest>` load):
  `store i64 %wb.pretop.<dest>, ptr %wb.pretop_slot.<dest>`.
* **`codegen_instr.qz`** perform static fast paths (G.2 kind<2 and the
  static-unwind branch): reload `%v<dest>.pretop_rl = load %wb.pretop_slot.<install>`
  and use it for the `@__qz_effect_current_install_idx` store and the
  unwind `uw_slot` GEP — instead of referencing the install-block SSA
  `%wb.pretop.<install>`, which a poll-resume block doesn't dominate.

Same-block install-side uses (zero-init fold, state-slot init, catch-block
OR-fold) keep referencing the SSA directly — the install block dominates
them, so no reload needed there.

**Verification done:** minimal repro prints `40`, `opt -passes=verify`
clean (golden produced "Instruction does not dominate all uses!" →
`%wb.pretop.5` defined in `poll_start2`, used in resume block `cl_done3`).
`effect_reader_p2b_spec` 7/7 (the failing case is its `assert_run_stdout_eq`
subprocess-compile of the exact repro). Effect-handler sweep green:
`effect_state_p2a`, `effect_unwind_f3b`, `effect_multi_compose_p2c`,
`effect_op_kind3_p3c_resume`, `exec_effect_handlers`,
`phase_6_1c_handler_throws`, `panic_as_throws`, `for_loop_state_in_poll`.
`quake guard` fixpoint 2688; Rule-2 smokes (style_demo, brainfuck) green.

Original filing kept below for historical context.

# Summary

A `with <Effect>(..) do ... end` body that (a) makes a **suspending call**
(any indirect/colorless call — e.g. `local(f, body)` whose lambdas the
effect machinery marks EFFECT_SUSPEND) and then (b) **performs the effect
again after that call** emits IR that `llc`/`opt` rejects:

```
Instruction does not dominate all uses!
  %wb.pretop.5 = load i64, ptr @__qz_effect_stack_top, align 8
  store i64 %wb.pretop.5, ptr @__qz_effect_current_install_idx, align 8
```

# Minimal reproducer

```
import std/reader

def main(): Int
  var r = with Reader(10) do ->
    var inside = local(x -> x * 3, () -> ask())   # suspends (indirect lambda calls)
    var outside = ask()                            # performs Reader AFTER the suspend
    inside + outside
  end
  puts(r.to_s())
  return 0
end
```
`quartz --no-cache ... /tmp/rdr.qz | opt -passes=verify` → broken module.
Expected stdout `40`. (The PASSING sibling test puts `local(..)` as the
tail expression with no later `ask()`, so no second perform after the
suspend.)

# Root cause (block-precise, in `@__Future_main$poll`)

* `%wb.pretop.5 = load @__qz_effect_stack_top` is emitted **inline at the
  `with Reader` install**, in block `poll_start2` (the initial-entry path).
  It is the runtime stack index of this install (pretop captured just
  before the install pushed its entry).
* `local(..)` is a colorless/suspending call → `main` is a `$poll`
  coroutine; the call splits control flow, and the code after it lands in
  the resume block `cl_done3`, reached from the `poll_switch` dispatch
  (which jumps straight to `cl_done3`, bypassing `poll_start2`).
* `outside = ask()` performs Reader in `cl_done3`. The perform **static
  fast path** (`codegen_instr.qz:1998-2009`) replicates the runtime's
  "set `@__qz_effect_current_install_idx` to this install's index" by
  emitting `store i64 %wb.pretop.<dest>, ptr @__qz_effect_current_install_idx`
  — referencing the `poll_start2` SSA value, which does not dominate
  `cl_done3`. → invalid IR.

So it is the same class as the closures.qz dominance bug (`40033381`,
value computed before a suspend used after the resume) and the sibling
`POLL_BODY_WB_RESULT_SLOT_DOMINANCE` (result_slot), but for the
**effect-install index** consumed by the perform fast path.

# Why the existing fn_entry-hoist (F.3b / sibling bug) doesn't apply

The jmp_buf + result_slot **allocas** were hoisted to `fn_entry` because
allocas are position-independent. `%wb.pretop` cannot hoist: its VALUE is
the dynamic effect-stack top **at this install point** (nested installs
have different pretops), so a fn_entry load would capture the wrong index.

# Fix direction

Frame-spill, analogous to closures.qz but at the codegen layer:
* When emitting a with-install's `%wb.pretop.<dest>` inside a `$poll` body
  (`mir_gen_is_active() >= 2`), also **spill it to a coroutine-frame slot**.
* At each perform fast-path store (`codegen_instr.qz:2007` and the kind=2
  path ~2065) and any other `%wb.pretop.<dest>` consumer that can sit in a
  resume-reachable block, **reload from the frame slot** instead of
  referencing the install-block SSA.

Alternative (investigate): have the perform fast path reload the install
index from a stable per-with-block frame slot that the install writes,
rather than threading the raw SSA `%wb.pretop.<dest>` to consumers. The
sibling result_slot fix already established a frame-slot discipline here;
extending it to the pretop/install-index is the natural shape.

# Verification checklist for the fix

* Minimal repro above → prints `40`, `opt -passes=verify` clean.
* `effect_reader_p2b_spec` → 7/7 (currently 6/7).
* Effect-handler sweep: the `effect_*` / `state_*` / `with_*` / Reader /
  State / Throws specs (the perform fast path + nested-install patterns).
* `quake guard` fixpoint + Rule-2 smokes — the compiler uses effect
  handlers (Throws) heavily, so a wrong spill mis-lowers its own code.

# Scope note

Deterministic (fails standalone under `--no-cache`), narrow trigger.
Not a pool-contention flake — distinct from the A.44 multi-file/timeout
cluster.
