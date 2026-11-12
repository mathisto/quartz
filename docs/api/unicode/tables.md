# unicode/tables

## Functions

### `unicode_range_contains(): Bool` *(std/unicode/tables.qz:9)*

Unicode Table Lookup Infrastructure

Provides O(log n) binary search over sorted codepoint range tables
and mapping tables for Unicode property lookups.
Check if a codepoint falls within any range in a sorted table.
Each element is packed as (start << 21) | end.
Ranges are inclusive: [start, end].

---

### `unicode_mapping_lookup(): Int` *(std/unicode/tables.qz:33)*

Look up a mapping in parallel sorted arrays.
keys and values must be the same length and sorted by key.
Returns the mapped value if found, otherwise returns cp unchanged.

---

