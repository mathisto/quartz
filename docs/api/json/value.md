# json/value

## Structs

### `JsonLocation` *(std/json/value.qz:19)*

| Field | Type |
|-------|------|
| `line` | `Int` |
| `column` | `Int` |

### `JsonError` *(std/json/value.qz:25)*

| Field | Type |
|-------|------|
| `message` | `String` |
| `location` | `JsonLocation` |

## Enums

### `JsonValue` *(std/json/value.qz:8)*

JSON Value Types and Accessors

Core data structures for representing JSON values in Be.
Follows RFC 8259 (The JavaScript Object Notation Data Interchange Format).

| Variant | Payload |
|---------|----------|
| `Null` | — |
| `Bool` | — |
| `Number` | — |
| `Float` | — |
| `String` | — |
| `Array` | — |
| `Object` | — |

### `JsonResult` *(std/json/value.qz:31)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

## Functions

### `json_null(): JsonValue` *(std/json/value.qz:40)*

---

### `json_bool(): JsonValue` *(std/json/value.qz:44)*

---

### `json_number(): JsonValue` *(std/json/value.qz:48)*

---

### `json_float(): JsonValue` *(std/json/value.qz:52)*

---

### `json_string(): JsonValue` *(std/json/value.qz:56)*

---

### `json_array(): JsonValue` *(std/json/value.qz:60)*

---

### `json_object(): JsonValue` *(std/json/value.qz:64)*

---

### `json_is_null(): Int` *(std/json/value.qz:72)*

---

### `json_is_bool(): Int` *(std/json/value.qz:84)*

---

### `json_is_number(): Int` *(std/json/value.qz:96)*

---

### `json_is_string(): Int` *(std/json/value.qz:108)*

---

### `json_is_array(): Int` *(std/json/value.qz:120)*

---

### `json_is_object(): Int` *(std/json/value.qz:132)*

---

### `json_as_bool(): Int` *(std/json/value.qz:148)*

---

### `json_as_number(): Int` *(std/json/value.qz:160)*

---

### `json_as_string(): String` *(std/json/value.qz:172)*

---

### `json_as_array(): Int` *(std/json/value.qz:184)*

---

### `json_as_object(): Int` *(std/json/value.qz:196)*

---

### `json_array_push(): Void` *(std/json/value.qz:212)*

---

### `json_array_get_impl(): JsonValue` *(std/json/value.qz:227)*

---

### `json_array_get(): JsonValue` *(std/json/value.qz:237)*

---

### `json_array_size(): Int` *(std/json/value.qz:249)*

---

### `json_object_set(): Void` *(std/json/value.qz:265)*

---

### `json_object_get_impl(): JsonValue` *(std/json/value.qz:280)*

---

### `json_object_get(): JsonValue` *(std/json/value.qz:290)*

---

### `json_object_has(): Int` *(std/json/value.qz:302)*

---

### `json_object_keys(): Int` *(std/json/value.qz:314)*

---

### `json_get_path(): JsonValue` *(std/json/value.qz:331)*

---

### `json_get_string(): String` *(std/json/value.qz:375)*

---

### `json_get_number(): Int` *(std/json/value.qz:379)*

---

### `json_get_bool(): Int` *(std/json/value.qz:383)*

---

### `json_error(): JsonError` *(std/json/value.qz:391)*

---

### `json_ok(): JsonResult` *(std/json/value.qz:396)*

---

### `json_err(): JsonResult` *(std/json/value.qz:400)*

---

