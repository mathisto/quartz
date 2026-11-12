# `toml_stringify_table_pairs` SIGSEGVs on nested table walk

**Filed**: 2026-05-06 (surfaced during signature-widening pilot for `toml_parse_key`).
**Status**: OPEN. Pre-existing — reproduces on `c2aaabf7` (pre-`ada11483`) golden binary, so not introduced by the toml signature-widening commit.

## Symptom

Compiling and running `spec/qspec/toml_stringify_spec.qz` exits 139 (SIGSEGV). The compiler accepts the spec (exit 0); the crash is at runtime.

Faulting address `0x18` (24 bytes from null) → null-pointer dereference at struct field offset.

## Crash trace

From `~/Library/Logs/DiagnosticReports/qspec_1778035309179_toml_stringify_spec-2026-05-06-001515.ips`:

```
EXC_BAD_ACCESS / SIGSEGV (KERN_INVALID_ADDRESS) at 0x0000000000000018
  Data Abort: byte read Translation fault
  pc = 0x100b1ad24

Frame 0: toml_stringify_table_pairs +272
Frame 1: toml_stringify_table_pairs +84   ← self-recursion
Frame 2: toml_stringify           +108
Frame 3: __lambda_2               +328    ← qspec it() body
Frame 4: it                       +628
Frame 5: describe                 +436
Frame 6: qz_main                  +116
Frame 7: main                     +36
```

The +272 / +84 pair indicates the function recursed into itself (nested table walk) and crashed in the deeper frame. Faulting offset `0x18` is consistent with reading the third 8-byte field of a struct via a null pointer (slot 0x00 = field 0, 0x08 = field 1, 0x10 = field 2, 0x18 = field 3 — depending on layout).

## Hypothesis

`toml_stringify_table_pairs` walks a `Map<String, TomlValue>` (or whatever the table's payload shape is) and recurses when the value is itself a table. The recursive call probably descends without checking that the inner table handle is non-null, OR a missing-default-construction path leaves an uninitialized `TomlTable` slot with a null `pairs` field that the recursion reads.

Likely culprits:
- `std/toml/value.qz` — TomlValue construction; possibly an `IntoTable` / `as_table` path that returns null when called on a non-table variant
- `std/toml/stringify.qz` (if exists) or `std/toml/parser.qz` — the `toml_stringify_table_pairs` function itself; check its null-guard discipline at recursion entry

## Severity

Low-medium. Affects `toml_stringify_spec` only — no production user of TOML write-back has been reported. But the spec was added intentionally to catch round-trip correctness; its silent-SIGSEGV state means the round-trip is currently un-tested.

## Reproduction

```bash
./self-hosted/bin/quartz spec/qspec/toml_stringify_spec.qz > /tmp/ts.ll
llc -filetype=obj /tmp/ts.ll -o /tmp/ts.o
clang /tmp/ts.o -o /tmp/ts -lm -lpthread
/tmp/ts; echo "EXIT=$?"   # → EXIT=139
```

Reproduces on `c2aaabf7` (pre-toml-widening) AND `ada11483` (post-toml-widening) — the toml_parse_key widening did not affect this code path.

## Discoverability

- Surfaced during the signature-widening pilot for A.12 (commit `ada11483`) when the agent ran `toml_*_spec.qz` and saw the unrelated stringify spec fail.
- Not flagged by any prior session's smoke runs because qspec is only run on demand.

## Status

- **Closed 2026-05-07** at the user-code layer. Compiler-class bug
  filed as a follow-up (see "Real root cause" below).

## Real root cause (filer's hypothesis was wrong)

Not a null deref, not a nested-table walk crash. The bug is a
**typecheck dispatch mismatch** for `map_get(m, key)`:

1. `entries: Int` is a string-keyed hashmap (built via `map_new` →
   string-key layout, verified in IR — `__qz_alloc(32)` header).
2. `keys = map_keys(entries)` returns bare `Vec` (no element type —
   `map_keys` is registered as `TYPE_VEC` with no key-type
   propagation).
3. `key = keys[i]` defaults to `Int` because Vec element type
   defaulted to Int when erased.
4. `map_get(entries, key)` — at typecheck
   (`typecheck_expr_handlers.qz:2188`), `key_arg_type == TYPE_INT`
   triggers `ast_set_str2(node, "Int")`, which routes the call to
   the **int-key** dispatch in MIR-lower / codegen.
5. The int-key dispatch's IR reads the map header at offset
   `4*8 = 32` (the `used` array slot) which doesn't exist in the
   string-key 32-byte layout → SIGSEGV at offset 0x18 (the actual
   crash address depends on the GEP chain).

The recursion in the diagnostic report's frame trace is misleading;
the inner frame is just a different point in the same function (the
+272/+84 pair are the call site for inlined `map_get` and the
intrinsic's GEP-chain entry).

## Resolution

User-code fix in `std/toml/stringify.qz`: pin the keys-vector and
key-binding annotations as `Vec<String>` / `String`. This drives the
typecheck stamp away from "Int" via the `key_arg_type` branch (since
`key: String` types as TYPE_STRING, no stamp → defaults to the
string-key path, which matches the actual hashmap layout).

Three sites:
- `toml_stringify_inline_table` (lines ~83–84, 91)
- `toml_stringify_table_pairs` (lines ~130–135)
- `toml_stringify_sections` (lines ~156–161)

Each `var keys = map_keys(entries); var key = keys[i]` becomes
`var keys: Vec<String> = map_keys(entries); var key: String = keys[i]`.

## Compiler-class follow-up (file-as)

`MAP_GET_KEY_INT_TYPE_OVERRIDES_RECEIVER_LAYOUT`:

The typecheck rule at `typecheck_expr_handlers.qz:2188` stamps
`str2="Int"` whenever the key arg has type `TYPE_INT`. This conflates
two distinct cases:

1. **Definitive Int-keyed**: user wrote `Map<Int, V>` annotation, key
   is genuinely Int. Stamp is correct.
2. **Defaulted-to-Int**: key came from a `Vec<unknown>` index that
   erased to Int. The map might be string-keyed; the stamp routes
   the call to the wrong dispatch and SIGSEGVs at runtime.

Sister `@.str.15`-undefined IR bug surfaces when the user tries to
work around case 2 via `var tbl: Map<String, TomlValue> = map_new()`
— the codegen for the parameterized-Map binding emits a stale string
constant reference. Both are blockers to a clean compiler-side fix.

Probable fix paths:
- **Track Vec element type from `map_keys`/`map_values`**: when the
  receiver has a `Map<K, V>` ptype, propagate K to the returned Vec's
  element-type slot. This makes `keys[i]` correctly typed and breaks
  the dispatch-mismatch chain at the source.
- **Tie-break with receiver evidence**: at the str2 stamp, prefer
  the receiver's annotation when it carries non-Int K over the key
  arg's TYPE_INT default. Less invasive but doesn't help bare-typed
  `tbl: Int = map_new()`.
- **Fix the `@.str.15`-undefined codegen** for parameterized-Map
  bindings, which would let users escape via the explicit annotation.

## Related

- `ada11483` — A.12 prep: widen toml_parse_key Int → Vec<String> (preceded discovery; ruled out as cause)
- `feedback_quartz_module_quirks.md` — Vec/Option default-init patterns; same family of "missing default construction" friction
- `feedback_map_get_returns_option.md` — sister axis (Option-wrap on map_get); compounds with this when consumer compares as Int.
