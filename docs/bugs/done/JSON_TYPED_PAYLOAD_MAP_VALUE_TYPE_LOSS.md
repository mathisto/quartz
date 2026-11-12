# JSON typed-payload Map<String, JsonValue> value-type loss → QZ0200

## Status

**✅ RESOLVED 2026-05-02 in `<commit-hash-tbd>`** during A.9 (JSON typed
payload audit). Root cause was the `parse_type_cache` in
`tc_parse_type` (typecheck.qz:1070): when a self-recursive enum payload
referenced its own enum (e.g. `Object(fields: Map<String, JsonValue>)`),
`tc_parse_type` was called from `tc_register_enum_def` BEFORE the enum
was added to the registry, returning `Map<String, Int>` (JsonValue
unrecognized → fall back to TYPE_INT) and caching that stale entry.
Match-arm time later called `tc_resolve_variant_type` → `tc_parse_type`
again with the same annotation, hit the cache, returned the stale
result, and `map_set`'s value-type check fired QZ0200 against TYPE_INT.

Fix: invalidate `tc.parse_type_cache` after each enum registration
(`typecheck.qz:tc_register_enum_def` post-registration). Forces re-parse
on next access — by then the enum's name is in the registry. Single-line
fix; sister to the `c909c853` Vec<T> match-arm payload fix on the same
mechanism (annotation→TypeId resolution under forward references).

Filed 2026-05-01.

Pre-existing latent quirk surfaced by `d0f608e8`
(2026-04-27) "Migrate JsonValue Object/Array to typed payloads".

## Symptom

Any user program that imports `std/json` and calls `json_object_set` on a
freshly-constructed `json_object()` fails to compile with:

```
error[QZ0200]: map_set: expected value type Int, got Enum
   --> ./std/json.qz:294:34
   |
294|     JsonValue::Object(fields) => map_set(fields, key, val)
   |                                  ^
```

Reproducer:

```be
import * from json

def main(): Int
  var o = json_object()
  json_object_set(o, "k", json_string("v"))
  return 0
end
```

```
$ rm -rf .quartz-cache
$ ./self-hosted/bin/quartz -I std -I . /tmp/_jmin.qz
error[QZ0200]: map_set: expected value type Int, got Enum
```

Same error if the program merely imports json and instantiates
`Vec<Vec<Int>>` somewhere. The typecheck fires inside std/json.qz's
own body, not the user program.

## Why d0f608e8 doesn't show this

The commit message claims all 5 json specs + style_demo + stdlib_traits_spec
were green at commit time. They were — under cached compilation that had
already absorbed pre-migration type info. **A clean .quartz-cache + a fresh
compile fails.** The qspec runner currently relies on shared cache state to
mask this.

## Root cause hypothesis

`Object(fields: Map<String, JsonValue>)` declares a typed Map payload.
At the `match v { Object(fields) => map_set(fields, key, val) }` site,
`fields` should bind with type `Map<String, JsonValue>` — making
`map_set(fields, key, val)` a valid signature with `val: JsonValue`.
Instead, the typecheck pass loses the value-type parameter and resolves
`map_set`'s expected value type to its default-Int instantiation.

Sister to the `Vec<T>` element-type-loss quirk in
`feedback_quartz_module_quirks.md` ("highest impact, hit twice in
1a60633c"). The pattern: generic-param payload on enum variant erases
to Int in match-arm binding, then downstream builtin/UFCS dispatch
sees the wrong instantiation.

Confirmed adjacent: `json_object_set` is the consumer; `json_array_push`
likely has the same shape via `JsonValue::Array(items: Vec<JsonValue>)`
→ `vec_push(items, val)`.

## Impact

- Blocks every external tool that wants to read/write typed JSON via
  std/json. Today's blocked consumers: any new tool importing json from
  outside the cached spec/qspec ecosystem. Discovered while writing
  `tools/measure_rss.qz` (Phase A.2 P2 gating measurement harness).
- The qspec runner's apparent green status on json specs is a false
  signal — re-run with `rm -rf .quartz-cache` and the specs fail
  (verified for spec/qspec/json_spec.qz at HEAD).

## Workaround

Avoid std/json in fresh tool code. Hand-roll line-based parsing for
fixed NDJSON shapes. CSV is a viable snapshot format that doesn't need
json. Used by tools/measure_rss.qz today.

Long-term fix: align Map<K, V> match-arm payload binding with the
existing Vec<T> work that closed the symmetric quirk. Likely target:
`typecheck_match.qz` arm-binding flow, where the payload type
annotation needs to flow into the bound name's ptype not just the
match-discriminant analysis.

## Sequencing

Phase A.10 candidate (open compiler bug, opportunistic). Pulls in if a
real consumer needs typed json access from a fresh code path — for now,
all known consumers can either work around with CSV or live in the
cached qspec ecosystem. **Ranked above** EXTERN_INTERRUPT_CAN_CLAUSE_PARSE_REJECT
(KERN-priority) and below CAN_E_TINY_PROGRAM_SIGSEGV (workaround-gated).
