# string

## Functions

### `str_split(): Vec<String>` *(std/string.qz:28)*

Split a string by delimiter, returning a Vec of substrings.
Returns a single-element Vec containing the original string if delimiter not found.
Returns empty strings for consecutive delimiters.

---

### `str_join(): String` *(std/string.qz:61)*

Join a Vec of strings with a separator.

---

### `is_whitespace(): Bool` *(std/string.qz:76)*

Check if a character code is ASCII whitespace (space, tab, newline, carriage return).

---

### `str_trim(): String` *(std/string.qz:81)*

Trim whitespace from both sides of a string.

---

### `str_trim_left(): String` *(std/string.qz:95)*

Trim whitespace from the left side of a string.

---

### `str_trim_right(): String` *(std/string.qz:105)*

Trim whitespace from the right side of a string.

---

### `str_replace(): String` *(std/string.qz:116)*

Replace all occurrences of `old` with `new_str` in `s`.
Returns the original string if `old` is not found.

---

### `str_starts_with(): Bool` *(std/string.qz:147)*

Check if a string starts with the given prefix.

---

### `str_ends_with(): Bool` *(std/string.qz:156)*

Check if a string ends with the given suffix.

---

### `str_to_upper(): String` *(std/string.qz:166)*

Convert ASCII letters in a string to uppercase.

---

### `str_to_lower(): String` *(std/string.qz:181)*

Convert ASCII letters in a string to lowercase.

---

### `str_contains(): Bool` *(std/string.qz:196)*

Check if a string contains a substring.

---

### `str_chars(): Vec<Int>` *(std/string.qz:207)*

Get a Vec of character codes (codepoint values) from a string.
Uses codepoint-level iteration. For byte iteration, use str_bytes().
Note: O(n²) on multi-byte strings due to codepoint indexing.

---

### `str_repeat(): String` *(std/string.qz:217)*

Repeat a string `n` times.

---

### `str_pad_left(): String` *(std/string.qz:229)*

Pad a string on the left to reach target length.

---

### `str_pad_right(): String` *(std/string.qz:244)*

Pad a string on the right to reach target length.

---

### `str_reverse(): String` *(std/string.qz:259)*

Reverse a string (byte-level, ASCII-safe).

---

### `str_count(): Int` *(std/string.qz:274)*

Count occurrences of a substring in a string.

---

### `str_is_empty(): Bool` *(std/string.qz:298)*

Check if a string is empty.

---

### `str_substr(): String` *(std/string.qz:303)*

Get a substring given start index and length.

---

