# io/path

## Structs

### `Path` *(std/io/path.qz:15)*

| Field | Type |
|-------|------|
| `_value` | `String` |

#### Methods

##### `to_string(): String`

Return the path as a string.

##### `join(): Path`

Join a segment to this path, returning a new Path.

##### `parent(): Path`

Return the parent directory as a new Path.
Returns "." if there is no parent.

##### `filename(): String`

Return the filename component (after the last /).
Returns the entire path if there is no /.

##### `stem(): String`

Return the filename without its extension.

##### `extension(): String`

Return the file extension (without the dot). Empty string if none.

##### `is_absolute(): Bool`

Return true if the path is absolute (starts with /).

##### `is_relative(): Bool`

Return true if the path is relative.

##### `with_extension(): Path`

Replace the extension, returning a new Path.
If the path has no extension, appends one.

##### `components(): Vec<String>`

Split the path into its components.

##### `exists(): Bool`

Check if the path exists on disk.

## Functions

### `path_new(): Path` *(std/io/path.qz:20)*

Create a new Path from a string.

---

### `path_from(): Path` *(std/io/path.qz:25)*

Alias for path_new.

---

### `_path_last_slash(): Int` *(std/io/path.qz:30)*

Find the last occurrence of "/" in a string. Returns -1 if not found.

---

### `_path_last_dot(): Int` *(std/io/path.qz:43)*

Find the last occurrence of "." in a string, starting from `start`. Returns -1 if not found.

---

### `_path_get_filename(): String` *(std/io/path.qz:56)*

Extract filename from a path string.

---

### `_path_get_parent(): String` *(std/io/path.qz:65)*

Extract parent directory from a path string.

---

