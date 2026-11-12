# toml/value

## Structs

### `TomlLocation` *(std/toml/value.qz:22)*

A document location for error reporting.

| Field | Type |
|-------|------|
| `line` | `Int` |
| `column` | `Int` |

### `TomlError` *(std/toml/value.qz:28)*

Detailed error information from a failed parse.

| Field | Type |
|-------|------|
| `message` | `String` |
| `location` | `TomlLocation` |

## Enums

### `TomlValue` *(std/toml/value.qz:12)*

TOML Value Types

Core data structures for representing TOML values in Be.

@since 6.0.0
Represents any valid TOML value.

| Variant | Payload |
|---------|----------|
| `String` | — |
| `Int` | — |
| `Float` | — |
| `Bool` | — |
| `Array` | — |
| `Table` | — |

#### Methods

##### `is_string(): Bool`

##### `is_int(): Bool`

##### `is_float(): Bool`

##### `is_bool(): Bool`

##### `is_array(): Bool`

##### `is_table(): Bool`

##### `as_int(): Int`

##### `as_float(): Int`

##### `as_bool(): Bool`

##### `as_array(): Int`

##### `as_table(): Int`

### `TomlResult` *(std/toml/value.qz:34)*

Result type for TOML parsing operations.

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

## Functions

### `toml_table_new(): Int` *(std/toml/value.qz:44)*

Creates a new empty TOML table (as Map handle).

---

### `toml_location_new(): TomlLocation` *(std/toml/value.qz:49)*

Creates a new TomlLocation.

---

### `toml_ok(): TomlResult` *(std/toml/value.qz:54)*

Creates a successful parse result.

---

### `toml_err_result(): TomlResult` *(std/toml/value.qz:59)*

Creates a failed parse result.

---

### `toml_table_set(): Void` *(std/toml/value.qz:70)*

Sets a key-value pair in a TOML table.

---

### `toml_table_get(): TomlValue` *(std/toml/value.qz:75)*

Gets a value from a TOML table by key.

---

### `toml_table_has(): Bool` *(std/toml/value.qz:83)*

Checks if a key exists in a TOML table.

---

### `toml_table_keys(): Int` *(std/toml/value.qz:88)*

Returns all keys in a TOML table.

---

### `toml_as_string(): String` *(std/toml/value.qz:97)*

Extracts a string value from a TomlValue.

---

### `toml_as_int(): Int` *(std/toml/value.qz:105)*

Extracts an integer value from a TomlValue.

---

### `toml_as_float(): Int` *(std/toml/value.qz:113)*

Extracts a float value from a TomlValue (as f64 bits).

---

### `toml_as_bool(): Bool` *(std/toml/value.qz:121)*

Extracts a boolean value from a TomlValue.

---

### `toml_as_array(): Int` *(std/toml/value.qz:129)*

Extracts an array handle from a TomlValue.

---

### `toml_as_table(): Int` *(std/toml/value.qz:137)*

Extracts a table handle from a TomlValue.

---

### `toml_is_string(): Bool` *(std/toml/value.qz:149)*

Checks if a TOML value is a string.

---

### `toml_is_int(): Bool` *(std/toml/value.qz:157)*

Checks if a TOML value is an integer.

---

### `toml_is_float(): Bool` *(std/toml/value.qz:165)*

Checks if a TOML value is a float.

---

### `toml_is_bool(): Bool` *(std/toml/value.qz:173)*

Checks if a TOML value is a boolean.

---

### `toml_is_array(): Bool` *(std/toml/value.qz:181)*

Checks if a TOML value is an array.

---

### `toml_is_table(): Bool` *(std/toml/value.qz:189)*

Checks if a TOML value is a table.

---

### `toml_get_path(): TomlValue` *(std/toml/value.qz:202)*

Gets a nested value using dot-separated path notation.
Returns 0 (null handle) if path not found.

---

### `toml_get_string(): String` *(std/toml/value.qz:244)*

Gets a string value at a dot-separated path.

---

### `toml_get_int(): Int` *(std/toml/value.qz:256)*

Gets an integer value at a dot-separated path.

---

### `toml_get_bool(): Bool` *(std/toml/value.qz:268)*

Gets a boolean value at a dot-separated path.

---

### `toml_get_string_or(): String` *(std/toml/value.qz:280)*

Gets a string value with a fallback if missing.

---

### `toml_result_is_err(): Bool` *(std/toml/value.qz:293)*

Checks if a TomlResult is an error.

---

### `toml_result_is_ok(): Bool` *(std/toml/value.qz:301)*

Checks if a TomlResult is Ok.

---

### `toml_result_unwrap(): TomlValue` *(std/toml/value.qz:310)*

Extracts the value from a successful TomlResult.
PANICS if the result is an error.

---

### `toml_error_message(): String` *(std/toml/value.qz:325)*

Extracts the error message from a TomlError.

---

