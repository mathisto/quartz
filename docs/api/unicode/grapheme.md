# unicode/grapheme

## Structs

### `GraphemeIter` *(std/unicode/grapheme.qz:160)*

---------------------------------------------------------------------------
GraphemeIter — iterates over grapheme cluster substrings
---------------------------------------------------------------------------

| Field | Type |
|-------|------|
| `s` | `String` |
| `pos` | `Int` |
| `len` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for GraphemeIter**

##### `next(): Option<Int>`

## Functions

### `_gb_category(): Int` *(std/unicode/grapheme.qz:18)*

---------------------------------------------------------------------------
Grapheme Break Category Lookup
---------------------------------------------------------------------------
Get the Grapheme Break category for a codepoint.

---

### `_should_break(): Bool` *(std/unicode/grapheme.qz:68)*

---------------------------------------------------------------------------
UAX #29 Break Rules
---------------------------------------------------------------------------

---

### `_gi_decode(): Int` *(std/unicode/grapheme.qz:135)*

Decode a UTF-8 codepoint at the given byte position in string s.
Sets _gi_decode_pos to the byte position AFTER the decoded codepoint.
Decode a UTF-8 codepoint at position, update _gi_decode_pos to next byte.

---

### `str_graphemes(): GraphemeIter` *(std/unicode/grapheme.qz:227)*

Create a grapheme cluster iterator for a string.

---

### `str_grapheme_count(): Int` *(std/unicode/grapheme.qz:232)*

Count the number of grapheme clusters in a string.

---

