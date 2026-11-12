# error

## Structs

### `SimpleError` *(std/error.qz:32)*

| Field | Type |
|-------|------|
| `_message` | `String` |

#### Trait Implementations

**impl Error for SimpleError**

##### `message(): String`

##### `kind(): String`

### `IoError` *(std/error.qz:54)*

| Field | Type |
|-------|------|
| `_message` | `String` |
| `_path` | `String` |
| `_code` | `Int` |

#### Methods

##### `path(): String`

##### `code(): Int`

#### Trait Implementations

**impl Error for IoError**

##### `message(): String`

##### `kind(): String`

### `ParseError` *(std/error.qz:90)*

| Field | Type |
|-------|------|
| `_message` | `String` |
| `_line` | `Int` |
| `_column` | `Int` |
| `_source` | `String` |

#### Methods

##### `line(): Int`

##### `column(): Int`

##### `source(): String`

#### Trait Implementations

**impl Error for ParseError**

##### `message(): String`

##### `kind(): String`

### `ValueError` *(std/error.qz:130)*

| Field | Type |
|-------|------|
| `_message` | `String` |
| `_expected` | `String` |
| `_got` | `String` |

#### Methods

##### `expected(): String`

##### `got(): String`

#### Trait Implementations

**impl Error for ValueError**

##### `message(): String`

##### `kind(): String`

### `FormatError` *(std/error.qz:162)*

| Field | Type |
|-------|------|
| `_message` | `String` |
| `_format` | `String` |

#### Methods

##### `format(): String`

#### Trait Implementations

**impl Error for FormatError**

##### `message(): String`

##### `kind(): String`

### `WrappedError` *(std/error.qz:190)*

| Field | Type |
|-------|------|
| `_message` | `String` |
| `_cause_message` | `String` |
| `_cause_kind` | `String` |

#### Methods

##### `cause_message(): String`

##### `cause_kind(): String`

#### Trait Implementations

**impl Error for WrappedError**

##### `message(): String`

##### `kind(): String`

## Traits

### `Error`

## Functions

### `simple_error(): SimpleError` *(std/error.qz:36)*

---

### `io_error(): IoError` *(std/error.qz:60)*

---

### `io_error_with_code(): IoError` *(std/error.qz:64)*

---

### `parse_error(): ParseError` *(std/error.qz:97)*

---

### `parse_error_with_source(): ParseError` *(std/error.qz:101)*

---

### `value_error(): ValueError` *(std/error.qz:136)*

---

### `format_error(): FormatError` *(std/error.qz:167)*

---

### `wrap_error(): WrappedError` *(std/error.qz:196)*

---

