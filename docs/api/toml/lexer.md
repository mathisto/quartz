# toml/lexer

## Structs

### `TomlToken` *(std/toml/lexer.qz:36)*

A single token produced by the lexer.

| Field | Type |
|-------|------|
| `kind` | `TomlTokenKind` |
| `value` | `String` |
| `location` | `TomlLocation` |

### `TomlLexer` *(std/toml/lexer.qz:43)*

Lexer state for tokenizing TOML source.

| Field | Type |
|-------|------|
| `source` | `String` |
| `pos` | `Int` |
| `line` | `Int` |
| `column` | `Int` |

## Enums

### `TomlTokenKind` *(std/toml/lexer.qz:14)*

Token type enumeration.

| Variant | Payload |
|---------|----------|
| `String` | — |
| `LiteralString` | — |
| `Int` | — |
| `Float` | — |
| `Bool` | — |
| `Ident` | — |
| `LBracket` | — |
| `RBracket` | — |
| `DoubleLBracket` | — |
| `DoubleRBracket` | — |
| `LBrace` | — |
| `RBrace` | — |
| `Equals` | — |
| `Comma` | — |
| `Dot` | — |
| `Newline` | — |
| `Eof` | — |
| `Error` | — |

## Functions

### `toml_lexer_new(): TomlLexer` *(std/toml/lexer.qz:55)*

Creates a new lexer for the given TOML source text.

---

### `toml_token_new(): TomlToken` *(std/toml/lexer.qz:65)*

Creates a token with the given kind and value.

---

### `toml_token_kind_name(): String` *(std/toml/lexer.qz:78)*

Returns a human-readable name for a token kind.

---

### `toml_lexer_peek(): Int` *(std/toml/lexer.qz:106)*

Returns the current character without advancing.

---

### `toml_lexer_peek_ahead(): Int` *(std/toml/lexer.qz:114)*

Returns the character at offset positions ahead.

---

### `toml_lexer_advance(): Void` *(std/toml/lexer.qz:123)*

Advances the lexer by one character.

---

### `toml_lexer_skip_whitespace(): Void` *(std/toml/lexer.qz:137)*

Skips whitespace (spaces and tabs) but NOT newlines.

---

### `toml_lexer_skip_comment(): Void` *(std/toml/lexer.qz:149)*

Skips a comment from `#` to end of line.

---

### `toml_is_bare_key_char(): Bool` *(std/toml/lexer.qz:161)*

Checks if a character is valid in a bare key.

---

### `toml_lexer_escape_char(): String` *(std/toml/lexer.qz:183)*

Helper to convert escape character to its escaped string value.
Returns empty string for invalid escapes.

---

### `toml_lexer_scan_string(): TomlToken` *(std/toml/lexer.qz:203)*

Scans a basic string (double-quoted).

---

### `toml_lexer_scan_literal_string(): TomlToken` *(std/toml/lexer.qz:249)*

Scans a literal string (single-quoted).

---

### `toml_lexer_scan_number(): TomlToken` *(std/toml/lexer.qz:276)*

Scans a number literal (integer or float).

---

### `toml_lexer_scan_ident(): TomlToken` *(std/toml/lexer.qz:360)*

Scans a bare key or keyword.

---

### `toml_lexer_next(): TomlToken` *(std/toml/lexer.qz:390)*

Returns the next token from the input.

---

### `toml_get_token(): TomlToken` *(std/toml/lexer.qz:501)*

Returns the token at the given index from a tokenized vector.

---

### `toml_token_count(): Int` *(std/toml/lexer.qz:506)*

Returns the number of tokens in a tokenized vector.

---

### `toml_tokenize(): Int` *(std/toml/lexer.qz:511)*

Tokenizes an entire TOML source string into a vector of tokens (Vec handle).

---

