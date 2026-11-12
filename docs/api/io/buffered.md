# io/buffered

## Structs

### `BufferedReader` *(std/io/buffered.qz:14)*

BufferedReader — reads from a file handle in chunks.

| Field | Type |
|-------|------|
| `_handle` | `Int` |
| `_buf` | `String` |
| `_pos` | `Int` |
| `_buf_size` | `Int` |
| `_eof` | `Int` |

#### Methods

##### `read_line(): String`

Read a single line from the file. Returns "" at EOF.

##### `read_byte(): Int`

Read a single byte as an integer. Returns -1 at EOF.

##### `read_n(): String`

Read n bytes as a string. May return fewer bytes at EOF.

##### `is_eof(): Bool`

Return true if end-of-file has been reached and buffer is exhausted.

##### `close(): Void`

Close the underlying file handle.

### `BufferedWriter` *(std/io/buffered.qz:147)*

BufferedWriter — writes to a file handle in chunks.

| Field | Type |
|-------|------|
| `_handle` | `Int` |
| `_buf` | `Vec<Int>` |
| `_buf_size` | `Int` |
| `_written` | `Int` |

#### Methods

##### `write_str(): Void`

Write a string to the buffer. Flushes when buffer is full.

##### `write_line(): Void`

Write a string followed by a newline.

##### `flush(): Void`

Flush the buffer to the file.

##### `close(): Void`

Flush and close the underlying file handle.

## Functions

### `buffered_reader_new(): BufferedReader` *(std/io/buffered.qz:23)*

Create a new BufferedReader with default buffer size (8192 bytes).

---

### `buffered_reader_new_sized(): BufferedReader` *(std/io/buffered.qz:34)*

Create a new BufferedReader with a specific buffer size.

---

### `_br_refill(): Void` *(std/io/buffered.qz:45)*

Internal: refill the buffer from the file handle.

---

### `buffered_writer_new(): BufferedWriter` *(std/io/buffered.qz:155)*

Create a new BufferedWriter with default buffer size (8192 bytes).

---

### `buffered_writer_new_sized(): BufferedWriter` *(std/io/buffered.qz:165)*

Create a new BufferedWriter with a specific buffer size.

---

### `_bw_flush_buf(): Void` *(std/io/buffered.qz:175)*

Internal: convert the buffer Vec<Int> of char codes to a string and write it.

---

### `_bw_write_data(): Void` *(std/io/buffered.qz:191)*

Internal: append a string's bytes to the writer's buffer, flushing as needed.

---

