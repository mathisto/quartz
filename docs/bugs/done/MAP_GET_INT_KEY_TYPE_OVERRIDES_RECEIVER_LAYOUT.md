# `map_get(m, int_typed_key)` always routes to int-key dispatch — silent SIGSEGV when m is string-keyed

**Closed:** 2026-05-07 by Path A (stdlib helper narrowing). `toml_table_new(): Map<String, TomlValue>` and `toml_table_keys(table: Int): Vec<String>` carry the K/V info forward through `var tbl = toml_table_new()` and `var keys = toml_table_keys(tbl)` so the `keys[i]` index types as `String` and `map_get` dispatches to the string-key path. Reproducer from this doc verified clean post-fix. Three Vec<String>/String workaround annotations in `std/toml/stringify.qz` reverted; sites swapped from raw `map_keys(entries)` to `toml_table_keys(entries)` to take advantage of the narrowed return. Compiler-side fix at `typecheck_expr_handlers.qz:2188` (Path C) deferred — Path A closes the surface for typed-handle stdlib helpers, which is the right place for it. Future stdlib map-builders (`std/yaml`, future `std/csv` rework) should follow the typed-handle precedent set here and by `std/json.qz` (`d0f608e8`).

**Filed:** 2026-05-07 (extracted from
`docs/bugs/done/TOML_STRINGIFY_NESTED_TABLE_NULL_DEREF.md`,
which surfaced the symptom but had the wrong root cause).
**Severity:** High — silent runtime SIGSEGV in any user code that
chains `map_keys` → `keys[i]` → `map_get(m, key)` against a string-
keyed map without explicit annotations.
**Sister:** `feedback_map_get_returns_option.md` — same dispatch-
fragility family; compounds when the consumer compares the result as
Int.

## Summary

`typecheck_expr_handlers.qz:2188` stamps `str2="Int"` on a `map_get`
call node whenever the key argument types as `TYPE_INT`. MIR-lower
reads that stamp and routes to the int-key dispatch
(`intmap_get` / `img_*` IR prefix) which assumes a 5-field hashmap
header (cap, size, keys, vals, used). Against a string-keyed
hashmap (4-field header: cap, size, keys, vals), the GEP chain
reads past the header → SIGSEGV at address near 0x20.

The conflation: `key_arg_type == TYPE_INT` covers two distinct cases:

1. **Genuine Int key.** User wrote `Map<Int, V>` annotation, the
   key argument is concretely Int-typed. The Int-keyed dispatch is
   correct.
2. **Defaulted-to-Int from erased Vec.** Key came from a
   `Vec<unknown>` index (e.g., `key = map_keys(m)[i]`), where Vec's
   element type erased to Int. The map might be string-keyed; the
   stamp routes the call to the wrong dispatch.

## Reproducer

```qz
import * from std/toml/value

def main(): Int
  var tbl = toml_table_new()                    # Int handle, string-keyed map
  toml_table_set(tbl, "name", TomlValue::String("test"))

  var keys = map_keys(tbl)                       # Vec — element type erases to Int
  var key = keys[0]                              # Int (defaulted)
  var opt = map_get(tbl, key)                    # SIGSEGV — int-key dispatch on string-key map
  return 0
end
```

Workaround (currently in `std/toml/stringify.qz`):

```qz
var keys: Vec<String> = map_keys(tbl)
var key: String = keys[0]
var opt = map_get(tbl, key)                      # OK — string-key dispatch
```

## Real fix — narrowed 2026-05-07

The struct-registry dedupe fix (commit `fca5789b`) closed the
`@.str.15` undefined-IR sister bug, which restored the
explicit-annotation escape hatch:
`var tbl: Map<String, TomlValue> = map_new()`. With that escape
hatch live, the existing typecheck (`tc_annotate_map_key_type` at
`typecheck_expr_handlers.qz:4336`) correctly handles annotated
receivers — `map_keys` propagates K to `Vec<K>` so `keys[i]` types
correctly, and the call-site str2 stamp doesn't fire as "Int."

The remaining bug surface is **bare-Int-receiver paths** —
stdlib helpers that return raw `Int` map handles instead of
`Map<K, V>`-typed values:

```qz
def toml_table_new(): Int      # <— loses K, V info
  return map_new()
end
```

Every consumer of `toml_table_new()` gets back an Int and is unable
to recover the K, V types via inference. The same pattern applies
to any future stdlib helper that wraps `map_new()` without
returning a parameterized type.

**Path A — narrow `toml_table_new` (and similar helpers) to return
`Map<String, TomlValue>`.** Cascades through `value.qz` API: the
`toml_table_set` / `toml_table_get` / `toml_table_keys` signatures
that take `table: Int` need `Map<String, TomlValue>` too, and
external callers (`std/toml/manifest.qz`, etc.) need to follow.

**Path B — make typecheck infer the binding's Map ptype from the
construction call.** When `var tbl = toml_table_new()` and the
return type is `Int`, `tbl`'s binding stays bare-Int. If the
typecheck could see that `toml_table_new()` is a `map_new()` wrapper
(via inlining or a `@maplike` annotation), it could lift the
implied Map<K, V> onto the binding. More speculative.

**Path C — default to string-keyed when no evidence either way.**
At `typecheck_expr_handlers.qz:2188`, when key arg types as
TYPE_INT but receiver has no Map<K, V> ptype, default to string-key
dispatch (don't stamp "Int"). Risks regressing
int-keyed-map-without-annotation usage. Pre-flight: grep stdlib +
examples for `map_new()` followed by `m[int_key] = ...` patterns;
estimate breakage.

## Sister codegen bug — RESOLVED 2026-05-07

When the user previously tried the explicit `var tbl: Map<String, TomlValue> = map_new()`
workaround, codegen emitted an undefined IR symbol `@.str.15`. Same
root cause as `TUI_DASHBOARD_QZ_HASH_TIME_DURATION_DUP` (struct
registry registered the same struct twice when reachable through two
import paths → IR string constants also collided). The dedupe at
`mir_ctx_register_struct` (commit `fca5789b`) closed both surfaces.

The receiver-side escape hatch is now usable:
```be
var tbl: Map<String, TomlValue> = map_new()
```
This makes `tbl` carry a `Map<String, TomlValue>` ptype that
`tc_annotate_map_key_type` reads — the call-site key argument's
default-Int type is overridden by the receiver's String key, and
dispatch routes correctly.

This is the **path B** option below in disguise (tie-break with
receiver evidence), now functional. Whether to additionally implement
path A (propagate K from `map_keys` so consumers don't need explicit
annotations) remains open scope work.

## Suggested next-session approach

1. Pre-flight survey via grep — find all `var keys = map_keys(...)` /
   `var key = keys[i]` / `map_get(...)` chains in stdlib and
   examples. Estimate scope.
2. Pick Path A or B based on scope.
3. Build a regression spec with the reproducer above + sister cases:
   string-keyed-map / int-keyed-map / struct-keyed-map, all without
   explicit annotation on the receiver.
4. Implement, run guard + smokes, update memory entry.

## Discoverability

- Surfaced 2026-05-07 closing
  `TOML_STRINGIFY_NESTED_TABLE_NULL_DEREF`. The bug doc filer hypothesized
  null deref in a recursion; lldb backtrace showed the real path
  was a single-frame crash inside `map_get`'s int-key dispatch on a
  string-key hashmap.
- Pre-existing across at least `c2aaabf7` and `ada11483`; not
  introduced by toml_parse_key widening.
