# collections/sorted_map

## Structs

### `SortedMap` *(std/collections/sorted_map.qz:15)*

| Field | Type |
|-------|------|
| `_keys` | `Vec<Int>` |
| `_values` | `Vec<Int>` |

#### Methods

##### `set(): Void`

Set a key-value pair. If key exists, updates the value.

##### `get(): Int`

Get the value for a key. Returns 0 if not found.

##### `has(): Bool`

Check if a key exists.

##### `delete(): Void`

Delete a key. No-op if key not found.

##### `size(): Int`

Return the number of entries.

##### `is_empty(): Bool`

Return true if the map is empty.

##### `min_key(): Int`

Return the smallest key. Returns 0 if empty.

##### `max_key(): Int`

Return the largest key. Returns 0 if empty.

##### `clear(): Void`

Remove all entries.

##### `free(): Void`

Free the underlying storage.

##### `keys(): Vec<Int>`

Return a copy of the keys Vec.

##### `values(): Vec<Int>`

Return a copy of the values Vec.

##### `to_vec(): Vec<Int>`

Convert to a Vec of keys (alias for keys).

##### `each(): Void`

Iterate over each key-value pair.

##### `map(): Vec<Int>`

Map each key-value pair to a new value.

##### `filter(): Vec<Int>`

Filter key-value pairs by predicate, returning matching keys.

##### `reduce(): Int`

Fold all key-value pairs into an accumulator.

##### `find(): Int`

Find first key-value pair matching predicate, returning the key. Returns 0 if not found.

##### `any(): Bool`

Check if any key-value pair matches predicate.

##### `all(): Bool`

Check if all key-value pairs match predicate.

##### `count(): Int`

Count key-value pairs matching predicate.

##### `iter(): SortedMapKeyIter`

Return an iterator over keys in sorted order.

##### `iter_values(): SortedMapValueIter`

Return an iterator over values in key-sorted order.

### `SortedMapKeyIter` *(std/collections/sorted_map.qz:264)*

SortedMapKeyIter — iterates over SortedMap keys in sorted order.

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_index` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for SortedMapKeyIter**

##### `next(): Option<Int>`

### `SortedMapValueIter` *(std/collections/sorted_map.qz:281)*

SortedMapValueIter — iterates over SortedMap values in key-sorted order.

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_index` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for SortedMapValueIter**

##### `next(): Option<Int>`

## Functions

### `sorted_map_new(): SortedMap` *(std/collections/sorted_map.qz:21)*

Create a new empty sorted map.

---

### `_sm_binary_search(): Int` *(std/collections/sorted_map.qz:27)*

Internal: binary search for key in sorted vec.
Returns the index where key is found or should be inserted.

---

