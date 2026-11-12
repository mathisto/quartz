# csv

## Structs

### `CsvRow` *(std/csv.qz:15)*

A single CSV row (vector of field strings).

| Field | Type |
|-------|------|
| `fields` | `Int` |

#### Methods

##### `len(): Int`

##### `get(): String`

##### `push(): Void`

### `CsvDocument` *(std/csv.qz:20)*

A complete CSV document (optional headers + rows).

| Field | Type |
|-------|------|
| `headers` | `Int` |
| `rows` | `Int` |
| `has_headers` | `Bool` |

#### Methods

##### `row_count(): Int`

##### `get_row(): CsvRow`

##### `add_row(): Void`

##### `get_field(): String`

### `CsvParser` *(std/csv.qz:118)*

| Field | Type |
|-------|------|
| `source` | `String` |
| `pos` | `Int` |
| `line` | `Int` |
| `column` | `Int` |

## Functions

### `csv_row_new(): CsvRow` *(std/csv.qz:31)*

Creates an empty CSV row.

---

### `csv_row_from_vec(): CsvRow` *(std/csv.qz:36)*

Creates a CSV row from a vector of strings.

---

### `csv_document_new(): CsvDocument` *(std/csv.qz:41)*

Creates an empty CSV document with no headers.

---

### `csv_document_with_headers(): CsvDocument` *(std/csv.qz:46)*

Creates a CSV document with headers.

---

### `csv_row_len(): Int` *(std/csv.qz:55)*

Returns the number of fields in a row.

---

### `csv_row_get(): String` *(std/csv.qz:60)*

Gets a field by index.

---

### `csv_row_push(): Void` *(std/csv.qz:68)*

Adds a field to the end of a row.

---

### `csv_document_add_row(): Void` *(std/csv.qz:77)*

Adds a row to the document.

---

### `csv_document_row_count(): Int` *(std/csv.qz:82)*

Returns the number of data rows.

---

### `csv_document_get_row(): CsvRow` *(std/csv.qz:87)*

Gets a row by index.

---

### `csv_document_get_field(): String` *(std/csv.qz:95)*

Gets a field by row index and column name (requires headers).

---

### `csv_parser_new(): CsvParser` *(std/csv.qz:125)*

---

### `csv_parser_at_end(): Bool` *(std/csv.qz:129)*

---

### `csv_parser_peek(): Int` *(std/csv.qz:133)*

---

### `csv_parser_advance(): Int` *(std/csv.qz:140)*

---

### `csv_parse_quoted_field(): String` *(std/csv.qz:156)*

Parses a quoted field (handles escaped quotes "").

---

### `csv_parse_unquoted_field(): String` *(std/csv.qz:181)*

Parses an unquoted field.

---

### `csv_parse_row(): CsvRow` *(std/csv.qz:196)*

Parses a single row (one line of CSV).

---

### `csv_parse(): Result<CsvDocument, ParseError>` *(std/csv.qz:238)*

Parses a complete CSV string into a CsvDocument.
The first row is treated as headers.

---

### `csv_parse_no_headers(): Result<CsvDocument, ParseError>` *(std/csv.qz:271)*

Parses CSV without treating the first row as headers.

---

### `csv_needs_quoting(): Bool` *(std/csv.qz:303)*

Checks if a field needs quoting.

---

### `csv_escape_field(): String` *(std/csv.qz:317)*

Escapes a field for CSV output (quotes if needed).

---

### `csv_stringify_row(): String` *(std/csv.qz:339)*

Stringifies a single row.

---

### `csv_stringify(): String` *(std/csv.qz:356)*

Stringifies a complete CSV document.

---

