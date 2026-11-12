# json/lexer

## Structs

### `JsonToken` *(std/json/lexer.qz:31)*

| Field | Type |
|-------|------|
| `kind` | `JsonTokenKind` |
| `value` | `String` |
| `line` | `Int` |
| `column` | `Int` |

### `JsonLexer` *(std/json/lexer.qz:39)*

| Field | Type |
|-------|------|
| `source` | `String` |
| `pos` | `Int` |
| `line` | `Int` |
| `column` | `Int` |

## Enums

### `JsonTokenKind` *(std/json/lexer.qz:9)*

JSON Lexer

Tokenizes JSON input according to RFC 8259.
Handles strings, numbers, booleans, null, and structural characters.

| Variant | Payload |
|---------|----------|
| `String` | — |
| `Number` | — |
| `True` | — |
| `False` | — |
| `Null` | — |
| `LBrace` | — |
| `RBrace` | — |
| `LBracket` | — |
| `RBracket` | — |
| `Colon` | — |
| `Comma` | — |
| `Eof` | — |
| `Error` | — |

## Functions

### `json_lexer_new(): JsonLexer` *(std/json/lexer.qz:50)*

---

### `json_lexer_at_end(): Int` *(std/json/lexer.qz:59)*

---

### `json_lexer_peek(): Int` *(std/json/lexer.qz:66)*

---

### `json_lexer_peek_next(): Int` *(std/json/lexer.qz:73)*

---

### `json_lexer_advance(): Int` *(std/json/lexer.qz:80)*

---

### `json_lexer_skip_whitespace(): Void` *(std/json/lexer.qz:95)*

---

### `json_token(): JsonToken` *(std/json/lexer.qz:111)*

---

### `json_token_simple(): JsonToken` *(std/json/lexer.qz:120)*

---

### `json_token_error(): JsonToken` *(std/json/lexer.qz:124)*

---

### `json_escape_char(): Int` *(std/json/lexer.qz:134)*

---

### `json_lexer_scan_string(): JsonToken` *(std/json/lexer.qz:165)*

---

### `json_is_digit(): Int` *(std/json/lexer.qz:214)*

---

### `json_lexer_scan_number(): JsonToken` *(std/json/lexer.qz:221)*

---

### `json_lexer_scan_keyword(): JsonToken` *(std/json/lexer.qz:275)*

---

### `json_lexer_next(): JsonToken` *(std/json/lexer.qz:300)*

---

