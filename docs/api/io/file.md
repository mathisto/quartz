# io/file

## Structs

### `FileHandle` *(std/io/file.qz:80)*

FileHandle — handle-based file I/O for streaming.

| Field | Type |
|-------|------|
| `_handle` | `Int` |
| `_path` | `String` |

#### Methods

##### `read(): String`

Read n bytes from the file.

##### `read_line(): String`

Read a single line from the file.

##### `write_str(): Int`

Write data to the file. Returns number of bytes written.

##### `close(): Void`

Close the file handle.

##### `is_open(): Bool`

Return true if the file handle is open.

## Functions

### `file_read_all(): String` *(std/io/file.qz:16)*

Read the entire contents of a file as a string.

---

### `file_write_all(): Void` *(std/io/file.qz:21)*

Write a string to a file, creating or overwriting it.

---

### `file_read(): Result<String, IoError>` *(std/io/file.qz:26)*

Read the entire contents of a file, returning Result<String, IoError>.

---

### `file_write(): Result<Int, IoError>` *(std/io/file.qz:36)*

Write a string to a file, returning Result<Int, IoError>.
Returns Ok(0) on success.

---

### `file_read_lines(): Vec<String>` *(std/io/file.qz:42)*

Read a file and split it into lines.

---

### `file_append(): Void` *(std/io/file.qz:48)*

Append a string to a file.

---

### `file_copy(): Int` *(std/io/file.qz:57)*

Copy a file from src to dst. Returns 1 on success, 0 on failure.

---

### `file_exists_at(): Bool` *(std/io/file.qz:70)*

Check if a file exists at the given path.

---

### `file_list_dir(): Vec<String>` *(std/io/file.qz:75)*

List directory contents. Returns a Vec of filenames.

---

### `file_open(): FileHandle` *(std/io/file.qz:87)*

Open a file with the given mode ("r", "w", "a").
Returns a FileHandle. Check .is_open() before using.

---

