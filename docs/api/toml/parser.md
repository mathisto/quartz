# toml/parser

## Structs

### `TomlParser` *(std/toml/parser.qz:16)*

Parser state for processing TOML tokens.

| Field | Type |
|-------|------|
| `lexer` | `TomlLexer` |
| `current` | `TomlToken` |
| `root` | `Int` |
| `current_table` | `Int` |

## Functions

### `toml_parser_new(): TomlParser` *(std/toml/parser.qz:28)*

Creates a new parser for the given TOML source.

---

### `toml_parser_advance(): Void` *(std/toml/parser.qz:47)*

Advances to the next token.

---

### `toml_parser_skip_newlines(): Void` *(std/toml/parser.qz:52)*

Skips newline tokens.

---

### `toml_parser_check(): Bool` *(std/toml/parser.qz:59)*

Checks if the current token matches the expected kind.

---

### `toml_parse_key(): Int` *(std/toml/parser.qz:68)*

Parses a key (bare, quoted, or dotted). Returns vector of segments.

---

### `toml_parse_value(): TomlResult` *(std/toml/parser.qz:128)*

Parses a TOML value.

---

### `toml_parse_array(): TomlResult` *(std/toml/parser.qz:183)*

Parses an array value.

---

### `toml_parse_inline_table(): TomlResult` *(std/toml/parser.qz:232)*

Parses an inline table.

---

### `toml_navigate_to_table(): Int` *(std/toml/parser.qz:300)*

Navigates to or creates a nested table. Returns the table or nil on error.

---

### `toml_insert_at_path(): Bool` *(std/toml/parser.qz:341)*

Inserts a value at a key path. Returns true on success.

---

### `toml_parse_table_header(): Bool` *(std/toml/parser.qz:382)*

Parses a table header: [table.name]

---

### `toml_parse_array_table_header(): Bool` *(std/toml/parser.qz:405)*

Parses an array-of-tables header: [[array.name]]

---

### `toml_parse_keyval(): Bool` *(std/toml/parser.qz:466)*

Parses a key-value pair.

---

### `toml_parse_document(): TomlResult` *(std/toml/parser.qz:489)*

Parses a complete TOML document.

---

### `toml_parse(): Result<TomlValue, ParseError>` *(std/toml/parser.qz:531)*

Parses a TOML string into a document table.

---

### `toml_parse_file(): Result<TomlValue, ParseError>` *(std/toml/parser.qz:541)*

Parses a TOML file into a document table.

---

### `toml_parse_legacy(): TomlResult` *(std/toml/parser.qz:550)*

---

