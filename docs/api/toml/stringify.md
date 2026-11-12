# toml/stringify

## Functions

### `toml_escape_string(): String` *(std/toml/stringify.qz:13)*

TOML Serializer

Converts TomlValue trees back into TOML text format.

@since 6.0.0

---

### `toml_stringify_value(): String` *(std/toml/stringify.qz:44)*

Stringifies a TOML value (inline format).

---

### `toml_stringify_array(): String` *(std/toml/stringify.qz:62)*

Stringifies an array inline.

---

### `toml_stringify_inline_table(): String` *(std/toml/stringify.qz:80)*

Stringifies a table inline.

---

### `toml_is_simple_value(): Bool` *(std/toml/stringify.qz:110)*

Checks if a value is a simple scalar (not table or array-of-tables).

---

### `toml_stringify_table_pairs(): String` *(std/toml/stringify.qz:127)*

Stringifies key-value pairs for a table section.

---

### `toml_stringify_sections(): String` *(std/toml/stringify.qz:153)*

Recursively stringifies nested tables with section headers.

---

### `toml_stringify(): String` *(std/toml/stringify.qz:214)*

Stringifies a complete TOML document.
The input should be a TomlValue::Table (the root document).

---

