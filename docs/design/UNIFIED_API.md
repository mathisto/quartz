# Unified Collection API Design

> **Status**: Mostly Implemented | **Created**: Feb 1, 2026 | **Updated**: Feb 18, 2026

## Overview

This document defines Quartz's unified collection API — a consistent interface across all
collection types (String, Vec, HashMap, Set, Array, StringBuilder). The goal is to provide
a "trait-like" experience where common operations have identical syntax regardless of type.

**Design Principles**:
1. **Property-style access** for zero-argument getters (`.size`, not `.size()`)
2. **UFCS desugaring** — methods compile to existing intrinsics, zero runtime overhead
3. **Rename to unified** — deprecate prefixed functions (`str_len` → `.size`)
4. **Compile-time protocols** — no runtime trait objects, just consistent naming

## Core Protocols

These are conceptual groupings that define which methods a type supports.

### Sized Protocol

All collections that have a countable size.

| Property    | Type    | Description              |
|-------------|---------|--------------------------|
| `.size`     | Int     | Number of elements       |
| `.is_empty` | Bool    | True if size == 0        |

**Implementors**: String, Vec, HashMap, Set, Array, StringBuilder

**Desugaring**:
```quartz
s.size      → str_len(s)       # when s: String
v.size      → vec_len(v)       # when v: Vec<T>
m.size      → hashmap_size(m)  # when m: HashMap<K,V>
s.size      → set_size(s)      # when s: Set<T>
a.size      → arr_len(a)       # when a: Array
sb.size     → sb_len(sb)       # when sb: StringBuilder

x.is_empty  → x.size == 0      # synthesized for all Sized
```

### Pushable Protocol

Collections that support appending elements.

| Method      | Signature       | Description              |
|-------------|-----------------|--------------------------|
| `.push(x)`  | (T) -> Void     | Append element           |

**Implementors**: Vec, StringBuilder

**Desugaring**:
```quartz
v.push(x)   → vec_push(v, x)   # when v: Vec<T>
sb.push(s)  → sb_append(sb, s) # when sb: StringBuilder
```

### Poppable Protocol

Collections that support removing the last element.

| Method      | Signature       | Description              |
|-------------|-----------------|--------------------------|
| `.pop()`    | () -> T         | Remove and return last   |

**Implementors**: Vec

**Desugaring**:
```quartz
v.pop()     → vec_pop(v)       # when v: Vec<T>
```

### Indexable Protocol

Collections with keyed access.

| Syntax          | Description              |
|-----------------|--------------------------|
| `x[i]`          | Get element at index/key |
| `x[i] = y`      | Set element at index/key |
| `.get(k)`       | Explicit get (HashMap)   |
| `.set(k, v)`    | Explicit set (HashMap)   |

**Implementors**: String (read-only), Vec, Array, HashMap

**Desugaring**:
```quartz
s[i]        → str_char_at(s, i)       # when s: String (returns Int codepoint)
v[i]        → vec_get(v, i)           # when v: Vec<T>
v[i] = x    → vec_set(v, i, x)        # when v: Vec<T>
m[k]        → hashmap_get(m, k)       # when m: HashMap<K,V>
m[k] = v    → hashmap_set(m, k, v)    # when m: HashMap<K,V>
a[i]        → arr_get(a, i)           # when a: Array
a[i] = x    → arr_set(a, i, x)        # when a: Array
```

### Clearable Protocol

Collections that can be emptied.

| Method      | Signature       | Description              |
|-------------|-----------------|--------------------------|
| `.clear()`  | () -> Void      | Remove all elements      |

**Implementors**: Vec, HashMap, Set, StringBuilder

**Desugaring**:
```quartz
v.clear()   → vec_clear(v)       # when v: Vec<T>
m.clear()   → hashmap_clear(m)   # when m: HashMap<K,V>
s.clear()   → set_clear(s)       # when s: Set<T>
sb.clear()  → sb_clear(sb)       # when sb: StringBuilder
```

### Deletable Protocol

Collections that support key/element removal.

| Method        | Signature       | Description              |
|---------------|-----------------|--------------------------|
| `.delete(k)`  | (K) -> Void     | Remove by key/element    |

**Implementors**: HashMap, Set

**Desugaring**:
```quartz
m.delete(k) → hashmap_del(m, k)  # when m: HashMap<K,V>
s.delete(x) → set_delete(s, x)   # when s: Set<T>
```

### Contains Protocol

Collections that support membership testing.

| Method          | Signature       | Description              |
|-----------------|-----------------|--------------------------|
| `.contains(x)`  | (T) -> Bool     | True if element present  |
| `.has(k)`       | (K) -> Bool     | True if key present      |

**Implementors**: Set (contains), HashMap (has), String (contains)

**Desugaring**:
```quartz
s.contains(x) → set_contains(s, x)       # when s: Set<T>
s.contains(n) → str_find(s, n) != -1     # when s: String
m.has(k)      → hashmap_has(m, k)        # when m: HashMap<K,V>
```

### Iterable Protocol (Future)

Collections that support `for..in` iteration.

| Syntax          | Description              |
|-----------------|--------------------------|
| `for x in coll` | Iterate elements         |

**Implementors**: Vec, Array, HashMap.keys(), HashMap.values(), Set

**Note**: Requires iterator desugaring infrastructure. Deferred to Phase 6.

## String Methods

String has additional text-specific methods.

| Old API                    | New UFCS               | Notes                    |
|----------------------------|------------------------|--------------------------|
| `str_len(s)`               | `s.size`               | Sized protocol           |
| `str_char_at(s, i)`        | `s[i]`                 | Returns Int codepoint    |
| `str_slice(s, a, b)`       | `s.slice(a, b)`        | Future: `s[a:b]`         |
| `str_find(s, needle)`      | `s.find(needle)`       | Returns -1 if not found  |
| `str_split(s, delim)`      | `s.split(delim)`       | Returns Vec<String>      |
| `str_concat(a, b)`         | `a + b`                | Already works            |
| `str_eq(a, b)`             | `a == b`               | Already works            |
| `str_cmp(a, b)`            | `a.cmp(b)`             | For ordering             |
| `str_to_lower(s)`          | `s.downcase()`         | Primary form             |
| `str_to_upper(s)`          | `s.upcase()`           | Primary form             |
| `str_trim(s)`              | `s.trim()`             |                          |
| `str_replace(s, old, new)` | `s.replace(old, new)`  |                          |
| `str_starts_with(s, p)`    | `s.starts_with(p)`     |                          |
| `str_ends_with(s, p)`      | `s.ends_with(p)`       |                          |

## Conversion Methods

| Old API            | New UFCS       | Notes                    |
|--------------------|----------------|--------------------------|
| `str_to_int(s)`    | `s.to_i()`     | String to Int            |
| `str_from_int(n)`  | `n.to_s()`     | Int to String            |
| `char_to_string(c)`| `c.to_s()`     | Char (Int) to String     |

## HashMap-Specific Methods

| Old API              | New UFCS       | Notes                    |
|----------------------|----------------|--------------------------|
| `hashmap_keys(m)`    | `m.keys()`     | Returns Vec<K>           |
| `hashmap_values(m)`  | `m.values()`   | Returns Vec<V>           |

## Migration Strategy

### Phase 1: Add UFCS Aliases (Non-Breaking)

Add method resolution for all new UFCS forms. Old prefixed functions continue to work.

```quartz
# Both work:
str_len(s)   # old
s.size       # new
```

### Phase 2: Compiler Warnings (Soft Deprecation)

Emit warnings when prefixed functions are used:

```
warning: `str_len(s)` is deprecated, use `s.size` instead
```

### Phase 3: Remove Prefixed Functions (Breaking)

Remove old APIs from public surface. Internal intrinsics remain for UFCS desugaring.

## Implementation Checklist

### C Bootstrap (`typecheck.c`)

| Method     | Types                      | Status   |
|------------|----------------------------|----------|
| `.size`    | Vec                        | Done     |
| `.size`    | String, HashMap            | Done     |
| `.size`    | Set, Array                 | Done     |
| `.size`    | StringBuilder              | Done     |
| `.is_empty`| String, HashMap            | Done     |
| `.is_empty`| Vec, Set, Array, SB        | Done     |
| `.empty?`  | String, Vec, HashMap       | Done     |
| `.push`    | Vec                        | Done     |
| `.push`    | StringBuilder              | Done (via `.append()`) |
| `.pop`     | Vec                        | Done     |
| `.clear`   | Vec, HashMap, Set, SB      | Done     |
| `.delete`  | HashMap                    | Done     |
| `.delete`  | Set                        | Done     |
| `.contains`| Set, String                | Pending  |
| `.has`     | HashMap                    | Done     |
| `.find`    | String                     | Done     |
| `.slice`   | String                     | Done     |
| `.split`   | String                     | Pending  |
| `.keys`    | HashMap                    | Done     |
| `.values`  | HashMap                    | Done     |
| `.starts_with` | String                 | Done     |
| `.ends_with`   | String                 | Done     |
| `.downcase`| String                     | Done     |
| `.upcase`  | String                     | Done     |
| `.trim`    | String                     | Done     |
| `.replace` | String                     | Done     |
| `.to_i`    | String                     | Done     |
| `.to_s`    | Int                        | Done     |
| `.cmp`     | String                     | Done     |
| `.hash`    | String                     | Done     |
| `.free`    | Vec, HashMap, StringBuilder| Done     |
| `.get`     | HashMap                    | Done     |
| `.set`     | HashMap                    | Done     |
| `.get_unchecked` | Vec                  | Done     |
| `.set_unchecked` | Vec                  | Done     |
| `.append`  | StringBuilder              | Done     |
| `.append_int` | StringBuilder           | Done     |
| `.append_char`| StringBuilder           | Done     |
| `.to_string`  | StringBuilder           | Done     |

### Self-Hosted (`typecheck.qz`)

Self-hosted mirrors all C bootstrap UFCS mappings and adds additional methods.

## Examples

```quartz
# Before (inconsistent)
def process(items: Vec<String>, lookup: HashMap<String, Int>): Int
    var count = 0
    var i = 0
    while i < vec_len(items)
        name = vec_get(items, i)
        if hashmap_has(lookup, name)
            count = count + hashmap_get(lookup, name)
        i = i + 1
    count

# After (unified)
def process(items: Vec<String>, lookup: HashMap<String, Int>): Int
    var count = 0
    var i = 0
    while i < items.size
        name = items[i]
        if lookup.has(name)
            count = count + lookup[name]
        i = i + 1
    count
```

## Related Documents

- [ROADMAP.md](ROADMAP.md) — Phase 5.7 implementation plan
- [INTRINSICS.md](INTRINSICS.md) — Low-level intrinsic documentation
- [QUARTZ_REFERENCE.md](QUARTZ_REFERENCE.md) — Language reference
