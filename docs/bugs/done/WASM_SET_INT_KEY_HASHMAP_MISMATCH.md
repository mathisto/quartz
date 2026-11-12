# WASM Set with Int keys silently routes to string-keyed hashmap_set

**Status**: ✅ RESOLVED 2026-04-30 — fixed in same-day follow-up commit (Option 1, type-driven dispatch via the existing slot2 elem_type channel).
**First observed**: 2026-04-30, running `examples/collections.qz` through the WASM backend.
**Symptom**: A small `set_add(s, intvalue)` test fills only 3 slots before silently dropping subsequent adds. Larger / different inputs trap with `memory fault at wasm address 0x10000` (out of bounds at the end of the initial 64KB linear memory).

## Resolution

The fix went with Option 1 from the original analysis (type-driven dispatch),
piggybacking on the existing slot2/elem_type channel that already serves
`map_*`. Five small changes:

1. **TC** (`typecheck_expr_handlers.qz`): extend the existing map_* slot2
   annotation block + UFCS dispatch path to also handle `set_*`. When
   `s.add(10)` / `s.has(10)` / `s.delete(10)` is type-checked and args[1]
   is Int, set slot2="Int" on the call node. Same logic for direct call
   form `set_add(s, 10)`. Layout-only ops (`set_size`, `set_clear`,
   `set_free`, `set_new`, `set_members`) inherit from the receiver via
   the existing `tc_annotate_map_key_type` helper, which reads
   `ptype.arg1` correctly for both Set<T> and Map<K, V>.

2. **MIR lowering** (`mir_lower_expr_handlers.qz`): the existing block
   that propagates AST `str2` → MIR `slot2` for `map_*` was extended to
   also fire for `set_*`. Without this, the typecheck-set annotation was
   dropped at the MIR boundary and the WASM codegen never saw the
   elem_type signal.

3. **WASM backend** (`wasm_runtime.qz`): added `_wasm_resolve_set_name`
   sibling to `_wasm_resolve_map_name`. For Int keys: `set_add` →
   `set_int_add` (new wrapper synth body, calls `intmap_set(s, v, 1)`
   instead of `hashmap_set(s, v, 1)`); `set_has` → `intmap_has` directly;
   `set_delete` → `intmap_delete` directly. Other set_* names unchanged.
   Updated the prescan dependency tracker to count `set_int_add` as
   triggering the intmap-helper cascade.

4. **WASM codegen** (`codegen_wasm.qz`): four call sites that already
   call `_wasm_resolve_map_name(name, slot2)` now also chain through
   `_wasm_resolve_set_name(name, slot2)`. Both functions are no-ops for
   names outside their respective prefixes.

5. **Spec** (`spec/qspec/wasm_set_int_keys_spec.qz`): 5 tests covering
   the original failing repro (5 distinct ints, size assertion), has()
   correctness for present and absent keys, delete(), values outside the
   small-int range that previously trapped at 0x10000, and a
   regression check that Set<String> still dispatches through hashmap_*.
   All 5 green; runs after compiling the spec source against a
   `--feature wasm` binary at `QUARTZ_COMPILER`.

**Acceptance**: `examples/collections.qz` Sets section now matches LLVM
output byte-for-byte on WASM. Fixpoint clean (2426 functions). Set spec
suites (`set_algebra`, `set_algebra_ufcs`, `set_comprehension`,
`api_unification`, `bool_returns`, `map_int`, `map_spec`) all green —
no regression.

---

## Original Analysis (preserved for context)

## Summary

The WASM backend's `set_*` synth bodies in `wasm_runtime.qz` are thin
wrappers around `hashmap_*` (`set_new` → `hashmap_new`, `set_add(s, v)`
→ `hashmap_set(s, v, 1)`, `set_size` → `hashmap_size`, etc). The
underlying `hashmap_*` implementation hashes its key via `str_hash`,
which interprets the i64 key as a pointer into linear memory and
dereferences it.

For Set<Int> (the most common case in user code: `s.add(10); s.add(20)`),
this is wrong. Int keys are NOT pointers — `str_hash(10)` walks
`memory[10..]` reading whatever bytes happen to live at those low
addresses. With small int values (0..16) those bytes are typically zero
or the WASM scratch area, producing collision-prone hashes that funnel
many distinct int keys into the same hashmap slot. Past 3-4 unique
adds, behaviour ranges from "silent drop" (collision overwrites) to
"memory fault at 0x10000" (str_hash walks past the end of initial
linear memory looking for a null terminator that never arrives).

## Reproducer

```quartz
def main(): Int
  var s = set_new()
  s.add(10)
  s.add(20)
  s.add(30)
  s.add(40)
  s.add(50)
  puts("size=#{s.size}")  # WASM: prints 3, expected 5
  return 0
end
```

WASM output: `size=3` (LLVM correctly prints `size=5`). The original
`examples/collections.qz` traps with an out-of-bounds memory access
because its Sets section uses values outside the small-int range.

## Cause

`wasm_runtime.qz`:

```
def _wasm_synth_set_add(): Vec<Int>     # set_add(s, v) calls hashmap_set(s, v, 1)
  ...
  wasm_emit_u32(body, _wasm_get_func_idx("hashmap_set"))
  ...
end
```

`_wasm_synth_hashmap_set` (line 6266) hashes its key via `str_hash` —
correct for `Map<String, V>`, wrong for `Set<Int>` / `Map<Int, V>`. The
`intmap_*` synth bodies exist (`set_*` for int-keyed maps would route
there) but `set_*` doesn't dispatch on key type.

The LLVM backend doesn't have this problem because its `qz_set_*`
runtime helpers in `codegen_runtime.qz` use `qz_hashmap_set` which has
been hardened against the int-vs-string ambiguity (it likely treats
keys uniformly via the value-as-i64 contract, with hashing keyed on
the raw i64 not pointer dereference).

## Fix Options

1. **Type-driven dispatch.** At MIR-lower / codegen time, detect the
   Set's element type and emit `intmap_*` for `Set<Int>` (and
   `Set<Bool>`, etc), `hashmap_*` for `Set<String>`. Requires the
   element type to be carried through the existential type erasure to
   the call site, which is non-trivial and not currently done.

2. **Single int-keyed implementation.** Stop synthesizing two parallel
   tables and route Sets uniformly through `intmap_*`. String-keyed
   Sets would then need their own opt-in form (e.g., a separate
   `string_set_new`). This breaks Quartz's "Set is generic" semantics
   on the WASM backend specifically.

3. **Universal i64-keyed hashmap with explicit string-aware entry
   point.** Change `hashmap_set` to treat keys as opaque i64 by
   default and add a separate `hashmap_set_str` for the
   pointer-dereference-and-hash semantics. `set_add` calls the i64
   variant. `Map<String, V>.set` calls the str variant.

Option 3 is the cleanest long-term: it matches what Rust / Go / etc do
(generic hashmap parameterized over key hashing). Option 1 is the
"correct" Quartz answer if the type system carries enough info to the
codegen site, but doing so for collection element types is a known gap
on the existential-type model.

## Related

- The wider int-vs-string Set/Map dispatch question. LLVM gets it right
  via runtime helpers that special-case; WASM exposes the gap because
  it synthesizes inline.
- `feedback_struct_size_field_vec_size_hijack.md` — a different
  manifestation of "integer values flowing where pointers are expected."

## Workaround

Use `Map<Int, Int>` (`intmap_*`) explicitly for int-keyed sets on
WASM. Or use small enums + tag-based discrimination if you only need a
small fixed-size set. Or compile to LLVM.

## Acceptance criteria

- `examples/collections.qz` runs end-to-end on WASM matching LLVM output.
- A new `wasm_set_int_keys_spec.qz` exercises the failing reproducer
  (5 adds, asserts size=5 and contains-checks for each value).
- LLVM behaviour unchanged.
