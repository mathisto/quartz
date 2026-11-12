# `.qzmod` MIR Body Shipping — Design Memo

> **Status:** Design memo for INC.1.0. No code yet.
> **Date:** 2026-05-13
> **Parent:** `docs/design/QZMOD_FORMAT.md` (§ 8 "MIR Bodies — v2")
> **Branch:** `qzmod-format` @ `8b880675`
> **Why this exists:** Phase 1.4.f attempted to gate body typecheck on `hit_ast_stores` for the cached-module case. It broke codegen with QZ0603 ("cannot resolve struct type for field access"). The brainfuck smoke compiled but produced garbage output. Rolled back. Per `feedback_qzmod_1_4_f_body_typecheck_ast_mutation_blocker.md`, the architecturally-correct fix is to ship MIR cross-module, matching Rust/Swift/GHC/OCaml/Scala 3/Lean. This memo specifies the shape.

---

## 1. Why MIR shipping (not "ship AST mutations")

Body typecheck (`tc_function` → `typecheck_walk::tc_function` → `typecheck_expr_handlers.qz`) writes resolved type info into AST nodes (~15 mutation sites on `ast_set_str2`: field-access receivers, method-call targets, etc.). MIR lowering then reads those mutations to translate field-access into `MIR_LOAD_OFFSET` with concrete offset numbers. So the dependency chain is **body TC → AST mutations → MIR lowering → codegen**, not **body TC → codegen** as the 1.4.f rollback memo phrased it.

There are three valid fix points along that chain:

| Approach | Skip | Ship | Effort | Why we pick / skip |
|---|---|---|---|---|
| A. Ship AST mutations | body TC | `(node_id, str2)` deltas | 3-5 d | TASTy-shaped retrofit on a codebase that already has MIR. Backwards architecture. |
| B. Ship MIR | body TC + MIR lowering | per-function MIR | 2-3 wk | What every production typed compiled language does. Architecturally right. |
| C. Targeted mutation-only re-walk | nothing | nothing — re-derives | 5-7 d | Couples mutation with TC; would need a separate pass. Half-measure. |

INC.1 takes path B. Justification in the parent project memo; the user directive 2026-05-13 was "no shortcuts."

---

## 2. What gets pickled per function

For each `MirFunc` in `mir_prog.functions` belonging to the module being emitted, the artifact carries:

### 2.1 Function-level metadata (one fixed-size record per fn)

From `struct MirFunc` (self-hosted/backend/mir.qz:166-187):

- `name: String` — already interned in producer's `_g_poll_callees`-style maps; pickled as pool index.
- `return_type: Int` — `MIR_TYPE_*` enum constant (stable across compiles — see §3).
- `params: Vec<String>` — parameter names. Pool-indexed strvec.
- `param_types: Vec<Int>` — parallel to `params`. MIR type constants.
- `param_type_names: Vec<String>` — source-level annotation per param (e.g. `"Vec<Int>"`, `"Foo"`). Pool-indexed.
- `return_type_name: String` — source annotation for return. Pool-indexed.
- `blocks: Vec<MirBlock>` — see §2.3.
- `entry: Int` — block index. Function-local.
- `value_counter: Int` — SSA register count. Function-local.
- `block_counter: Int` — block count. Function-local.
- `locals: Vec<String>` — local variable names. Pool-indexed.
- `local_narrow_names: Vec<String>` / `local_narrow_types: Vec<String>` — parallel arrays for narrow-int locals.
- `is_naked / is_no_preempt / is_weak / is_export / is_noinline: Int` — boolean flags.
- `line / col: Int` — source position. Optional; emit 0 if absent.

### 2.2 Per-block records

From `struct MirBlock` (mir.qz:190-198):

- `label: String` — pool-indexed.
- `instructions: Vec<MirInstr>` — see §2.3.
- `term_kind: Int` — `TERM_RETURN / TERM_JUMP / TERM_BRANCH / TERM_UNREACHABLE / TERM_SWITCH`.
- `term_data: Int` — SSA reg (return value) OR block index (jump/branch target). Function-local; no remap.
- `branch_true / branch_false: Int` — block indices. Function-local.
- `terminated: Int` — flag, fine as int.

### 2.3 Per-instruction records

From `struct MirInstr` (mir.qz:201-213):

- `kind: Int` — `MIR_*` opcode constant.
- `dest_id: Int` — SSA reg id. Function-local.
- `dest_type: Int` — `MIR_TYPE_*` constant.
- `operand1: Int`, `operand2: Int` — **per-kind discriminated**. See §3.
- `op: Int` — binary/unary opcode for `MIR_BINARY`/`MIR_UNARY`. Stable enum.
- `args: Vec<Int>` — **always SSA register IDs** (verified across `codegen_instr.qz` — every `instr.mir_instr_get_args()` call indexes args[i] as a `%v<i>` register). Function-local; no remap.
- `slot1: Int`, `slot2: Int` — **per-kind discriminated** (see §3).
- `line: Int`, `col: Int` — source position.

### 2.4 What stays out

Per design doc §1 non-goals: no cross-machine sharing in v1, no LSP-side data. The pickle covers only what codegen reads — debug info DWARF data is emitted via `cg_codegen_debug` from `MirFunc.line/col` (already covered above), so no extra sections.

Also out: anything in `MirContext` (mir.qz:304-430). The context is per-compile MIR-lowering state — once `mir_lower_all` returns, only `MirProgram` survives, and the context is discarded.

---

## 3. The portability problem — `as_int(String)` masking

MIR stores strings via `as_int(s: String)` → raw heap pointer cast to `i64`. Every read is paired with `as_string(operand)` to recover the pointer. **This is the hot path for cross-process portability**, because raw pointers don't survive serialization.

Per-kind discrimination of `operand1` / `operand2` / `slot1` / `slot2`:

| Kind | operand1 | operand2 | slot1 | slot2 |
|---|---|---|---|---|
| `MIR_NOP` | — | — | — | — |
| `MIR_CONST_INT` | int value | — | — | — |
| `MIR_CONST_BOOL` | 0/1 | — | — | — |
| `MIR_CONST_STRING` | — | **String ptr** | — | — |
| `MIR_CONST_FLOAT` | bit-pattern int | — | — | — |
| `MIR_LOAD_VAR` | **String ptr** (var) | — | is_global flag | — |
| `MIR_STORE_VAR` | **String ptr** (var) | SSA reg (val) | is_global flag | — |
| `MIR_BINARY` | SSA reg (lhs) | SSA reg (rhs) | — | — |
| `MIR_UNARY` | SSA reg | — | — | — |
| `MIR_CALL` | — | **String ptr** (func name) | — | — |
| `MIR_INTRINSIC` | — | **String ptr** (intrinsic name) | — | — |
| `MIR_FUNC_REF` | — | **String ptr** (func name) | — | — |
| `MIR_CALL_INDIRECT` | SSA reg (fn ptr) | — | — | — |
| `MIR_ALLOC` | size int / type info | — | — | — |
| `MIR_ALLOC_STACK` | size int | — | — | — |
| `MIR_LOAD` | SSA reg (addr) | — | — | — |
| `MIR_STORE` | SSA reg (addr) | SSA reg (val) | — | — |
| `MIR_FIELD_ACCESS` | SSA reg (base) | **String ptr** (field) | — | — |
| `MIR_LOAD_OFFSET` | **String ptr** (struct name) | **String ptr** (field type) | SSA reg (base) | offset int |
| `MIR_INDEX` / `MIR_INDEX_RAW` | SSA reg (arr) | SSA reg (idx) | — | — |
| `MIR_INDEX_STORE` / `MIR_INDEX_STORE_RAW` | SSA reg (arr) | SSA reg (idx) | SSA reg (val) | — |
| `MIR_PHI` | SSA reg (val1) | SSA reg (val2) | block idx (label1) | block idx (label2) |
| `MIR_SELECT` | SSA reg (cond) | SSA reg (true) | SSA reg (false) | — |
| `MIR_INLINE_C` | — | **String ptr** (asm code) | — | — |
| `MIR_ADDR_OF` | **String ptr** (var) | — | — | — |
| `MIR_UNION_WRAP` / `MIR_UNION_TAG` / `MIR_UNION_UNWRAP` | SSA reg | tag int / — | — | — |
| `MIR_VEC_DATA_PTR` | SSA reg | — | — | — |
| `MIR_BINARY_PACK` | layout_id int | — | — | — |
| `MIR_BINARY_UNPACK` | layout_id int | SSA reg (bytes) | — | — |
| `MIR_PACKED_BITCAST` | layout_id int | SSA reg (val) | — | — |
| `MIR_PERFORM_OP` | (see below) | **String ptr** (op name) | — | **String ptr** (effect name) |
| `MIR_HANDLE_INSTALL` | — | **String ptr** (effect name) | — | — |
| `MIR_HANDLE_UNINSTALL` | — | **String ptr** (effect name) | — | — |
| `MIR_HANDLE_UNINSTALL_DONE_ONLY` | — | **String ptr** (effect name) | — | — |
| `MIR_EFFECT_POP_N` | count int | **String ptr** (effect name) | — | — |

**INC.1.1 task:** lock this table down rigorously by walking every `mir_emit_*` call site, then producing it as a single `cg_intrinsic_*` /  `codegen_instr.qz`-cross-referenced authority. Treat any ambiguity as a bug, not a feature.

The pickle's per-kind dispatch reads `as_string(operand_i)` for every cell marked "String ptr" and substitutes a pool index; the unpickle reverses the substitution after re-interning via the consumer's `intern_global`.

**Type IDs** in `MirFunc.return_type` / `MirFunc.param_types[i]` / `MirInstr.dest_type` are MIR's enum constants (`MIR_TYPE_INT=0, MIR_TYPE_BOOL=1, …, MIR_TYPE_F64=11`). These are **stable across compiles** because they're statically declared constants in `mir.qz:438-461`. No remap needed. This is the single biggest simplification vs the AST-path TYPES section's ptype-arena indices.

---

## 4. Byte layout — `.qzmod` MIR_BODIES section

Mirrors the existing qzmod_emit pattern (pool + blob + offsets table). New files in each `.qzmod/<module>/` directory:

```
mir_bodies.bin      Vec<Int>  Flat per-function MIR. Variable-length records.
mir_bodies_off.bin  Vec<Int>  Per-function start-offset into mir_bodies.bin.
                              Parallel to funcs_name.bin. Size = N_funcs.
mir_struct_defs.bin Vec<Int>  Per-module MIR struct registry. See §4.3.
mir_enum_defs.bin   Vec<Int>  Per-module MIR enum registry. See §4.3.
```

All strings interned into the **existing** `strings.bin` pool (extended at emit time alongside funcs/structs/effects strings — same producer pattern, same `qzmod_pool_intern` call site).

### 4.1 Per-function record layout in `mir_bodies.bin`

A flat `Vec<Int>` blob, one record per function:

```
[fn_meta_section, blocks_section]
```

**fn_meta_section** (fixed prefix + variable lists):

```
name_idx                          # into strings pool
return_type_int                   # MIR_TYPE_* constant
n_params
  param_name_idx_0 ... param_name_idx_{n-1}
  param_type_int_0 ... param_type_int_{n-1}     # MIR_TYPE_*
  param_type_name_idx_0 ... param_type_name_idx_{n-1}
return_type_name_idx
n_locals
  local_name_idx_0 ... local_name_idx_{n-1}
n_local_narrow
  local_narrow_name_idx_0 ... local_narrow_name_idx_{n-1}
  local_narrow_type_idx_0 ... local_narrow_type_idx_{n-1}
flags                             # packed: naked|no_preempt|weak|export|noinline
entry_block_idx
value_counter
block_counter
line
col
```

**blocks_section**:

```
n_blocks
  block_record_0
  block_record_1
  ...
```

Each `block_record` is:

```
label_idx                         # into strings pool
n_instructions
  instr_record_0 ... instr_record_{n-1}
term_kind                         # TERM_*
term_data                         # SSA reg | block idx (kind-dispatched on read)
branch_true_idx
branch_false_idx
terminated_flag
```

Each `instr_record` is a fixed-shape 11-int row:

```
kind | dest_id | dest_type | operand1 | operand2 | op | n_args | arg_0 ... arg_{n-1} | slot1 | slot2 | line | col
```

Variable section is `n_args + arg_0 ... arg_{n-1}` — known to be SSA regs (function-local) per §2.3. The producer encodes string-typed operand1/operand2 by replacing the raw `as_int(s)` pointer with the pool index BEFORE writing; the consumer reverses this after reading.

### 4.2 Offsets table — `mir_bodies_off.bin`

A parallel `Vec<Int>` to `funcs_name.bin`. Slot `i` is the int-offset into `mir_bodies.bin` where function `i`'s record starts. Empty/skipped functions (forward decls, bounded generics, …) get offset = -1 → consumer falls back to MIR lowering for that function. This makes the section advisory at the function granularity, matching design doc Principle #6.

### 4.3 MirProgram struct/enum registries

`MirProgram` carries cross-function tables that codegen reads via `mir_prog_get_struct_field_count`, etc. (codegen.qz:457, mir.qz:1499-1538). These are populated by `mir_collect_structs` / `mir_collect_enums` during PASS 0/0.5 of `mir_lower_all`, walking every AST store.

For hit modules whose functions skip MIR lowering, the cross-fn registries also need to be populated WITHOUT walking the hit module's AST. Three options:

**(a) Re-derive from tc.registry post-inject.** `tc_inject_qzmod` already populates `tc.registry.struct_*` and `tc.registry.enum_*`. After inject, MIR's PASS 0/0.5 can read from `tc.registry` instead of AST for hit modules. Cleanest, no new section.

**(b) Ship `mir_struct_defs.bin` / `mir_enum_defs.bin` per module.** Pickles the producer's `mir_collect_structs`/`mir_collect_enums` output. Consumer merges into its own `mir_prog.struct_defs` after the live walk over non-hit modules. Slightly redundant with .qzmod's STRUCTS/ENUMS sections.

**(c) Hybrid:** ship the MIR-shape registries (b) because the tc.registry/MIR shapes differ slightly (MIR struct_defs entries are `[name_int, field_names_vec, field_types_vec, ...]` while tc.registry uses parallel vecs). Less translation work.

**Recommendation:** start with (a). The data shape mismatch is mechanical and we already have `tc_inject_qzmod` for the harder cases. If profiling shows the re-derivation is hot, fall back to (c). Decision deferred to INC.1.3.

### 4.4 Binary DSL layouts

`mir_prog.binary_layout_*` (mir.qz:124-154) is populated by `mir_collect_binary_layouts` in `mir_lower_all` PASS 0.55. Same problem as struct_defs. Same recommendation: re-derive from tc.registry (which qzmod inject populates today) at consumer load time.

---

## 5. Type-ID remap mechanism

Three observations from §3:

1. MIR's primary type identifiers are **`MIR_TYPE_*` enum constants** — stable, no remap.
2. Source-level type names (`Vec<Int>`, `Foo`, etc.) are **strings** — re-interned via the consumer's `intern_global` on load.
3. Struct/enum identity in `MIR_LOAD_OFFSET.operand1` etc. is a **string** (the struct's name), not a producer-local ptype-arena index.

This is **dramatically simpler than the AST-path's TYPES-section remap** (qzmod_remap.qz::qzmod_build_ptype_remap). MIR was designed for codegen, not typechecking, so it bottomed out on strings + the small fixed `MIR_TYPE_*` constants. No ptype-arena indexing.

**The remap is therefore just: re-intern every pool string through the consumer's interner during unpickle.** The pool entries become live Strings on the consumer side; subsequent `as_int(s)` calls produce the consumer's heap pointers; equality with other consumer-side strings holds via canonical interner.

### 5.1 Closure-bounded shipping is not needed for MIR

The AST-path TYPES section's closure-bounded ship pattern (Phase 1.4.c.2) exists because ptype-arena identity is process-local. MIR has no analog — the `operand1`/`operand2` string-vs-int discrimination IS the type-system surface.

### 5.2 Function names referenced cross-module

`MIR_CALL.operand2` is the **mangled function name** (e.g. `std_string$concat`). The consumer doesn't need a function-table remap — codegen emits `call @std_string$concat` from the name directly, and the linker resolves. This is identical to today's non-cached behavior; .qzmod just feeds codegen the same string the live MIR pass would.

---

## 6. Codegen integration surface

Today, `compile()` in `self-hosted/quartz.qz:1123` does:

```qz
var mir_prog = mir_lower::mir_lower_all(all_funcs)
# ...
codegen::cg_codegen(master_out, mir_prog, target, all_funcs, overflow_check, stack_alloc, race_mode)
```

`mir_lower_all` walks every entry in `all_funcs` and produces a fully-populated `MirProgram`. For INC.1, we change the contract: `mir_lower_all` lowers ONLY the non-hit modules' functions, then merges in MIR loaded from `.qzmod` artifacts for hit modules.

### 6.1 Proposed contract

```qz
# New signature; old form is mir_lower_all(all_funcs)
var mir_prog = mir_lower::mir_lower_all_incremental(all_funcs, hit_ast_stores, qzmod_results)
```

Where `qzmod_results: Vec<QzmodLoadResult>` is the same vec collected during Phase 4.0 pre-pass (already in scope at quartz.qz:545-571). The incremental form:

1. Runs PASS 0/0.5/0.55 cross-module scans EXCLUDING hit-module AST stores; populates `mir_prog.struct_defs / enum_defs / binary_layouts` from non-hit modules.
2. Merges hit-module `struct_defs / enum_defs / binary_layouts` from each `QzmodLoadResult` (either via tc.registry re-derive — §4.3 path a — or from new MIR-shape sections — path c).
3. PASS 1: lowers only functions whose `entry.ast_store NOT IN hit_ast_stores`.
4. **NEW PASS 1.0** (after PASS 1, before specialization): for each hit module, decode `mir_bodies.bin` per fn; push `MirFunc` onto `mir_prog.functions`.
5. PASS 1.1/1.2/1.3: existing specialization + async-target generation. Hit-module functions are already in `mir_prog.functions`, so call-graph analysis sees them; their specializations get re-emitted on demand (specializations are by definition NOT in cache — they're produced at consumer's call sites).

### 6.2 What codegen needs

Audited: `cg_codegen` (codegen.qz:1276) and `cg_emit_function` (codegen.qz:348) read `prog: MirProgram` + `func: MirFunc` + `state: CodegenState`. No AST reads in the per-function emission path — confirmed across `codegen.qz / codegen_instr.qz / codegen_runtime.qz / codegen_separate.qz / cg_intrinsic_*.qz`. The only AST reads in codegen are in `cg_emit_extern_declarations` (codegen.qz:1078-1267), which walks `all_funcs` for extern fn signatures; this path is independent of MIR shipping.

**No codegen changes are required.** The interface is data-shape only — codegen reads the same `MirProgram` whether it was built live or partially loaded from `.qzmod`. This is the cleanest possible boundary.

### 6.3 Specializations and the inject-then-lower order

Bounded generics (`def foo<T: Eq>(...)`) are skipped at the producer (mir_lower.qz:5183) and re-emitted as specializations at consumer call sites. .qzmod must NOT ship specialization bodies — they're produced from the user's call types, not from the generic's source. Confirmed: `mir_emit_pending_specializations` runs at PASS 1.1, ONLY for the consumer's own call graph. Hit modules' specializations are consumer-local artifacts.

### 6.4 Lambda numbering

Today `mir_lower_all` assigns lambda numbers sequentially across all modules during PASS 1 (mir_lower.qz:5497 comment: "Always lower ALL functions — MIR skip is unsafe because lambda numbering is global/sequential and would shift if modules are skipped").

If hit-module bodies skip MIR lowering at the consumer, lambda numbering inside those bodies must be FROZEN at the producer's numbering. The pickle covers this naturally — `__lambda_42`-named functions are part of the producer's `mir_prog.functions` and get serialized like any other function. The consumer's lambda counter starts at the max lambda id seen across all hit modules + 1.

**INC.1.3 task:** confirm `MirFunc.name` carrying `__lambda_<N>` is the only place lambda identity leaks, and pickle/unpickle preserves it. Concern level: low — lambda call sites also go through `MIR_CALL` / `MIR_FUNC_REF` by name.

---

## 7. Open questions / risks for INC.1.1+

Each below is a thing that could blow up the 10-15-day estimate. Filing them here keeps INC.1.0's re-evaluation gate honest.

### 7.1 The complete operand-discrimination table (§3) might be incomplete

The table covers ~30 of the ~40 MIR kinds. Less-common kinds (effect ops, actor lowering's synthetic kinds, async generator state machine markers) need confirmation. **Mitigation:** INC.1.1 starts with a complete pass through `mir_lower_expr_handlers.qz` + `mir_lower_stmt_handlers.qz` + `mir_lower_gen.qz` to enumerate every `mir_emit_*` call site. Cap the audit at 1 day; if it overruns, the design is brittler than thought.

### 7.2 MirProgram has process-local pointers we haven't audited

`mir_prog.struct_defs[i][0]` is an `as_int(name_string)` — a heap pointer. We've identified this and propose re-deriving from tc.registry. But `binary_layout_*` has similar surface (mir.qz:124-154). **Mitigation:** INC.1.0 captures the pattern; INC.1.3 does the implementation pass.

### 7.3 Async-target propagation across module boundaries

Async target registration (mir_lower_async_registry.qz) is process-global Vec state, populated during MIR lowering at PASS 0.98 ("Pre-scan all AST stores for async targets"). If hit modules skip MIR lowering, async-target registration must come from somewhere. **Two paths:**
   - Ship `mir_async_targets.bin` per module → trivially correct.
   - Re-walk the hit module's AST in PASS 0.98 only (cheap relative to body TC). Less new code; preserves the existing API.

Recommend the AST-walk path because async-target registration is read-only and idempotent. The expensive part of PASS 0 isn't the scan; it's PASS 0.99b's fixpoint suspend-effect propagation, which runs after — and that READS from the async-target registry. If we miss hit-module async targets, propagation goes wrong.

### 7.4 `quake snapshots` is NOT a MIR serializer (design doc §8.1 is wrong)

Captured separately as a feedback memo. `tools/check_ufcs_snapshot.sh` is for surface-syntax checks; `quake snapshots` (Quakefile.qz:4020-4068) is a fixture-driven LLVM IR text diff. There is no pre-existing MIR serialization in tree. The QZMOD_FORMAT design doc's "MIR encoding reuses `quake snapshots` format" claim (§ 11 decision #4) is wrong and must be corrected. **Impact on INC.1.1:** the pickle/unpickle primitives have to be written from scratch. They're not particularly hard (mirroring qzmod_emit's pattern), but the 2-3-day estimate assumed reuse and now doesn't.

**Adjusted INC.1.1 sizing:** 3-4 quartz-days instead of 2-3. Total INC.1 nudges to 11-16 quartz-days.

### 7.5 Round-trip determinism

`quake guard` requires gen1.ll == gen2.ll byte-identical. The pickle must be deterministic: instruction order, block order, function order all stable. **Mitigation:** the existing qzmod_emit code is already deterministic (vec_save/strvec_save round-trip losslessly). The MIR pickle inherits this property by following the same pattern. INC.1.4's measurement step verifies — gen1.ll == gen2.ll with .qzmod enabled IS the acceptance gate.

### 7.6 Specialization across compile boundaries

If a stdlib generic `def map<T,U>(xs: Vec<T>, f: T -> U): Vec<U>` is specialized as `map<Int, String>` in spec A and `map<Int, Bool>` in spec B, both specs get the spec body in their MIR via PASS 1.1, not from .qzmod. **No new problem** — confirmed at §6.3. But the .qzmod could ship the specialization seed (the generic's MIR) to save the lowering of the generic body once per consumer. Probably P2; ignore for INC.1.

### 7.7 What if `mir_bodies.bin` for a function is corrupt?

Per design Principle #6, fall back. The slot-level offset of -1 already covers per-function skip. A decode error (e.g. negative array index) should be caught, set `should_lower_for_this_fn = 1`, and the AST-path takes over. INC.1.3 needs a `mir_unpickle_function(blob, offset) -> Option<MirFunc>` API that returns `None` on any structural fault.

### 7.8 The "should we ship struct_defs/enum_defs as MIR sections" decision (§4.3)

Recommend (a). But the call is INC.1.3-time. Don't pre-decide.

### 7.9 Compiler binary hash as cache version (Principle #1 from parent doc) holds

The pickle format spec IS the compiler binary. If the format changes, the binary hash changes, every `.qzmod` is auto-invalidated, no version field. **This is load-bearing for INC.1.** Verified: `qzmod_format::qzmod_compiler_shard` uses the binary hash. The new MIR section is covered transitively.

---

## 8. Acceptance for INC.1.0 (this memo)

Per the parent project memo:

- [x] Memo committed at `docs/design/QZMOD_MIR_BODIES.md`.
- [x] Answers (a)-(e) from §1 of project_qzmod_format_handoff.md: §2 (a), §4 (b), §5 (c), §6 (d), §7 (e).
- [x] Identifies cross-function MIR references that need remapping: §3 (per-kind operand discrimination), §5 (none beyond string re-interning).
- [x] No code changes.

## 9. INC.1.1 — Next chunk

**Deliverable:** MIR pickle/unpickle primitives + roundtrip spec.

**Tasks:**

1. Complete the §3 operand-discrimination table by walking every `mir_emit_*` call site. Output: a constant table in `self-hosted/backend/mir.qz` mapping `kind → (op1_is_string, op2_is_string, slot1_is_string, slot2_is_string)`. This becomes the single source of truth for pickling.
2. Implement `mir_pickle_function(func: MirFunc, pool: QzmodEmitPool) -> Vec<Int>` in `self-hosted/shared/qzmod_emit.qz`. Returns the per-function blob fragment.
3. Implement `mir_unpickle_function(blob: Vec<Int>, off: Int, strings: Vec<String>) -> Option<MirFunc>` in `self-hosted/shared/qzmod_load.qz`. Returns `None` on any structural fault.
4. Round-trip qspec at `spec/qspec/qzmod_mir_bodies_roundtrip_spec.qz`: build a synthetic `MirFunc` covering every kind from §3, pickle, unpickle, deep-compare. Cover edge cases: empty blocks, empty instructions, lambda-named functions, multi-block functions with branches, PHI nodes.
5. **Acceptance:** spec passes. `quake guard` PASS. No producer/consumer integration yet — this is the bricks, not the wall.

**Sized:** 3-4 quartz-days (revised upward from 2-3 per §7.4).

**Constraint:** still no `self-hosted/*.qz` shipping changes beyond `mir.qz` (table) + `qzmod_emit.qz` / `qzmod_load.qz` (primitives). The producer + consumer integration is INC.1.2 and INC.1.3.

---

## 10. References

- `docs/design/QZMOD_FORMAT.md` — parent design.
- `feedback_qzmod_1_4_f_body_typecheck_ast_mutation_blocker.md` — why we're here.
- `self-hosted/backend/mir.qz:96-213` — MirProgram / MirFunc / MirBlock / MirInstr definitions.
- `self-hosted/backend/mir_lower.qz:4912-5789` — `mir_lower_all` PASS structure.
- `self-hosted/backend/codegen.qz:348-1525` — `cg_emit_function` / `cg_codegen` entry surface.
- `self-hosted/backend/codegen_instr.qz` — per-MIR-kind LLVM IR emit (~2800 lines; the authority on how each kind's operand fields are interpreted).
- `self-hosted/shared/qzmod_emit.qz` / `qzmod_load.qz` — section-emit pattern this design extends.
- `self-hosted/quartz.qz:535-1126` — Phase 4.0a-4.1 / Phase 4.4 / Phase 6 integration surface.
- `Quakefile.qz:4020-4068` — `run_snapshots` (LLVM IR text, NOT MIR — see §7.4).
