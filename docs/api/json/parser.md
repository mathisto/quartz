# json/parser

## Structs

### `JsonParser` *(std/json/parser.qz:10)*

JSON Parser

Recursive descent parser for JSON according to RFC 8259.
Builds a tree of JsonValue nodes.

| Field | Type |
|-------|------|
| `lexer` | `JsonLexer` |
| `current` | `JsonToken` |
| `had_error` | `Int` |
| `error_message` | `String` |
| `error_line` | `Int` |
| `error_column` | `Int` |

## Functions

### `json_parser_new(): JsonParser` *(std/json/parser.qz:23)*

---

### `json_parser_advance(): JsonToken` *(std/json/parser.qz:36)*

---

### `json_parser_check(): Int` *(std/json/parser.qz:42)*

---

### `json_parser_match(): Int` *(std/json/parser.qz:49)*

---

### `json_parser_error(): Void` *(std/json/parser.qz:57)*

---

### `json_parser_expect(): Int` *(std/json/parser.qz:67)*

---

### `json_parse_value(): JsonValue` *(std/json/parser.qz:81)*

---

### `json_parse_array(): JsonValue` *(std/json/parser.qz:88)*

---

### `json_parse_object(): JsonValue` *(std/json/parser.qz:121)*

---

### `json_parse_value(): JsonValue` *(std/json/parser.qz:176)*

---

### `json_parse(): JsonResult` *(std/json/parser.qz:253)*

Parse a JSON string into a JsonValue.
Returns JsonResult::Ok(value) on success, JsonResult::Err(error) on failure.

---

### `json_parse_or_null(): JsonValue` *(std/json/parser.qz:270)*

Parse JSON, returning null on error (convenience function).

---

