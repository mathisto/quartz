# json

## Structs

### `JsonLocation` *(std/json.qz:28)*

| Field | Type |
|-------|------|
| `line` | `Int` |
| `column` | `Int` |

### `JsonError` *(std/json.qz:34)*

| Field | Type |
|-------|------|
| `message` | `String` |
| `location` | `JsonLocation` |

### `JsonToken` *(std/json.qz:65)*

| Field | Type |
|-------|------|
| `kind` | `JsonTokenKind` |
| `value` | `String` |
| `line` | `Int` |
| `column` | `Int` |

### `JsonLexer` *(std/json.qz:72)*

| Field | Type |
|-------|------|
| `source` | `String` |
| `pos` | `Int` |
| `line` | `Int` |
| `column` | `Int` |

### `JsonParser` *(std/json.qz:83)*

| Field | Type |
|-------|------|
| `lexer` | `JsonLexer` |
| `current` | `JsonToken` |
| `had_error` | `Int` |
| `error_message` | `String` |
| `error_line` | `Int` |
| `error_column` | `Int` |

## Enums

### `JsonValue` *(std/json.qz:12)*

JSON Library for Be

A complete JSON parser and serializer following RFC 8259.
Supports parsing, value manipulation, and stringification.

| Variant | Payload |
|---------|----------|
| `Null` | — |
| `Bool` | — |
| `Number` | — |
| `Float` | — |
| `String` | — |
| `Array` | — |
| `Object` | — |

#### Methods

##### `is_null(): Bool`

##### `is_bool(): Bool`

##### `is_number(): Bool`

##### `is_float(): Bool`

##### `is_string(): Bool`

##### `is_array(): Bool`

##### `is_object(): Bool`

##### `as_bool(): Int`

##### `as_number(): Int`

##### `as_string(): String`

##### `as_array(): Int`

##### `as_object(): Int`

##### `get(): JsonValue`

##### `get_at(): JsonValue`

##### `set(): Void`

##### `has(): Bool`

##### `size(): Int`

##### `push(): Void`

##### `to_s(): String`

##### `to_pretty(): String`

##### `path(): JsonValue`

### `JsonResult` *(std/json.qz:40)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

### `JsonTokenKind` *(std/json.qz:49)*

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

## Type Aliases

### `JsonPrimitive`

Alias for `Int | F64 | String | Bool`

Union type alias for primitive JSON scalar values (v5.25).
Not a replacement for JsonValue — a convenience type for functions
that only accept scalar primitives (no arrays/objects/null).

## Functions

### `json_null(): JsonValue` *(std/json.qz:96)*

---

### `json_bool(): JsonValue` *(std/json.qz:100)*

---

### `json_number(): JsonValue` *(std/json.qz:104)*

---

### `json_float(): JsonValue` *(std/json.qz:108)*

---

### `json_string(): JsonValue` *(std/json.qz:112)*

---

### `json_array(): JsonValue` *(std/json.qz:116)*

---

### `json_object(): JsonValue` *(std/json.qz:120)*

---

### `json_is_null(): Bool` *(std/json.qz:128)*

---

### `json_is_bool(): Bool` *(std/json.qz:135)*

---

### `json_is_number(): Bool` *(std/json.qz:142)*

---

### `json_is_float(): Bool` *(std/json.qz:149)*

---

### `json_is_string(): Bool` *(std/json.qz:156)*

---

### `json_is_array(): Bool` *(std/json.qz:163)*

---

### `json_is_object(): Bool` *(std/json.qz:170)*

---

### `json_as_bool(): Int` *(std/json.qz:181)*

---

### `json_as_number(): Int` *(std/json.qz:193)*

---

### `json_as_string(): String` *(std/json.qz:205)*

---

### `json_as_array(): Int` *(std/json.qz:217)*

---

### `json_as_object(): Int` *(std/json.qz:229)*

---

### `json_array_push(): Void` *(std/json.qz:245)*

---

### `json_array_get_impl(): JsonValue` *(std/json.qz:257)*

---

### `json_array_get(): JsonValue` *(std/json.qz:267)*

---

### `json_array_size(): Int` *(std/json.qz:279)*

---

### `json_object_set(): Void` *(std/json.qz:295)*

---

### `json_object_get_impl(): JsonValue` *(std/json.qz:307)*

---

### `json_object_get(): JsonValue` *(std/json.qz:317)*

---

### `json_object_has(): Bool` *(std/json.qz:329)*

---

### `json_object_keys(): Int` *(std/json.qz:336)*

---

### `json_get_path(): JsonValue` *(std/json.qz:352)*

---

### `json_get_string(): String` *(std/json.qz:392)*

---

### `json_get_number(): Int` *(std/json.qz:396)*

---

### `json_get_bool(): Int` *(std/json.qz:400)*

---

### `json_error(): JsonError` *(std/json.qz:408)*

---

### `json_ok(): JsonResult` *(std/json.qz:413)*

---

### `json_err(): JsonResult` *(std/json.qz:417)*

---

### `json_lexer_new(): JsonLexer` *(std/json.qz:425)*

---

### `json_lexer_at_end(): Int` *(std/json.qz:434)*

---

### `json_lexer_peek(): Int` *(std/json.qz:441)*

---

### `json_lexer_advance(): Int` *(std/json.qz:448)*

---

### `json_lexer_skip_whitespace(): Void` *(std/json.qz:463)*

---

### `json_token(): JsonToken` *(std/json.qz:474)*

---

### `json_token_simple(): JsonToken` *(std/json.qz:483)*

---

### `json_token_error(): JsonToken` *(std/json.qz:487)*

---

### `json_escape_char(): Int` *(std/json.qz:491)*

---

### `json_hex_digit_value(): Int` *(std/json.qz:526)*

---

### `json_parse_unicode_hex4(): Int` *(std/json.qz:539)*

---

### `json_codepoint_to_utf8(): String` *(std/json.qz:557)*

---

### `json_lexer_scan_string(): JsonToken` *(std/json.qz:588)*

---

### `json_is_digit(): Int` *(std/json.qz:657)*

---

### `json_lexer_scan_number(): JsonToken` *(std/json.qz:664)*

---

### `json_lexer_scan_keyword(): JsonToken` *(std/json.qz:714)*

---

### `json_lexer_next(): JsonToken` *(std/json.qz:735)*

---

### `json_parser_new(): JsonParser` *(std/json.qz:797)*

---

### `json_parser_error(): Void` *(std/json.qz:810)*

---

### `json_parser_get_value(): String` *(std/json.qz:820)*

Helper to get current token value (workaround for nested field access type issue)

---

### `json_parser_get_kind(): Int` *(std/json.qz:826)*

Helper to get current token kind (workaround for nested field access type issue)

---

### `json_parser_advance(): JsonToken` *(std/json.qz:831)*

---

### `json_parser_check(): Int` *(std/json.qz:837)*

---

### `json_parser_match(): Int` *(std/json.qz:844)*

---

### `json_parser_expect(): Int` *(std/json.qz:852)*

---

### `json_parse_array(): JsonValue` *(std/json.qz:861)*

---

### `json_parse_object(): JsonValue` *(std/json.qz:890)*

---

### `json_parse_value(): JsonValue` *(std/json.qz:941)*

---

### `json_parse(): Result<JsonValue, ParseError>` *(std/json.qz:1004)*

---

### `json_parse_or_null(): JsonValue` *(std/json.qz:1019)*

---

### `json_parse_legacy(): JsonResult` *(std/json.qz:1028)*

---

### `json_escape_string(): String` *(std/json.qz:1047)*

---

### `json_stringify_array(): String` *(std/json.qz:1078)*

---

### `json_stringify_object(): String` *(std/json.qz:1096)*

---

### `json_stringify_bool(): String` *(std/json.qz:1123)*

---

### `json_stringify_string(): String` *(std/json.qz:1131)*

---

### `json_stringify(): String` *(std/json.qz:1138)*

---

### `json_make_indent(): String` *(std/json.qz:1150)*

---

### `json_stringify_array_pretty(): String` *(std/json.qz:1160)*

---

### `json_stringify_object_pretty(): String` *(std/json.qz:1184)*

---

### `json_stringify_pretty_inner(): String` *(std/json.qz:1217)*

---

### `json_stringify_pretty(): String` *(std/json.qz:1229)*

---

