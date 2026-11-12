# unicode

## Structs

### `CodepointIter` *(std/unicode.qz:18)*

---------------------------------------------------------------------------
CodepointIter — lazy, zero-allocation UTF-8 codepoint iteration
---------------------------------------------------------------------------

| Field | Type |
|-------|------|
| `s` | `String` |
| `pos` | `Int` |
| `len` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for CodepointIter**

##### `next(): Option<Int>`

### `CharIndexIter` *(std/unicode.qz:62)*

---------------------------------------------------------------------------
CharIndexIter — yields packed (byte_offset << 21) | codepoint
---------------------------------------------------------------------------

| Field | Type |
|-------|------|
| `s` | `String` |
| `pos` | `Int` |
| `len` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for CharIndexIter**

##### `next(): Option<Int>`

## Functions

### `str_codepoints(): CodepointIter` *(std/unicode.qz:54)*

4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx

---

### `str_char_indices(): CharIndexIter` *(std/unicode.qz:99)*

4-byte

---

### `char_index_offset(): Int` *(std/unicode.qz:104)*

Accessors for packed char-index values.

---

### `char_index_codepoint(): Int` *(std/unicode.qz:105)*

---

### `unicode_uppercase(): Int` *(std/unicode.qz:117)*

Convert a single codepoint to uppercase (simple 1:1 mapping).
Returns the codepoint unchanged if no mapping exists.

---

### `unicode_lowercase(): Int` *(std/unicode.qz:122)*

Convert a single codepoint to lowercase (simple 1:1 mapping).

---

### `unicode_casefold(): Int` *(std/unicode.qz:127)*

Case-fold a single codepoint (for case-insensitive comparison).

---

### `unicode_to_upper(): String` *(std/unicode.qz:133)*

Convert a string to uppercase (full mapping including 1-to-many).
"straße" → "STRASSE", "café" → "CAFÉ"

---

### `unicode_to_lower(): String` *(std/unicode.qz:162)*

Convert a string to lowercase.

---

### `unicode_case_fold(): String` *(std/unicode.qz:171)*

Case-fold a string (for case-insensitive comparison).

---

### `unicode_eq_ignore_case(): Bool` *(std/unicode.qz:180)*

Case-insensitive string comparison.

---

### `unicode_is_alphabetic(): Bool` *(std/unicode.qz:188)*

---------------------------------------------------------------------------
Unicode Character Classification
---------------------------------------------------------------------------

---

### `unicode_is_numeric(): Bool` *(std/unicode.qz:192)*

---

### `unicode_is_whitespace(): Bool` *(std/unicode.qz:196)*

---

### `unicode_is_uppercase(): Bool` *(std/unicode.qz:200)*

---

### `unicode_is_lowercase(): Bool` *(std/unicode.qz:204)*

---

### `unicode_is_alphanumeric(): Bool` *(std/unicode.qz:208)*

---

### `_binary_search_index(): Int` *(std/unicode.qz:217)*

---------------------------------------------------------------------------
Internal helpers
---------------------------------------------------------------------------
Binary search for exact key in sorted Vec. Returns index or -1.

---

