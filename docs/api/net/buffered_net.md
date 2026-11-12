# net/buffered_net

## Structs

### `BufferedNetReader` *(std/net/buffered_net.qz:27)*

| Field | Type |
|-------|------|
| `fd` | `Int` |
| `ssl` | `Int` |
| `buf` | `Int` |
| `buf_pos` | `Int` |
| `buf_len` | `Int` |
| `buf_cap` | `Int` |
| `eof` | `Int` |

### `BufferedNetWriter` *(std/net/buffered_net.qz:236)*

| Field | Type |
|-------|------|
| `fd` | `Int` |
| `ssl` | `Int` |
| `buf` | `Int` |
| `buf_len` | `Int` |
| `buf_cap` | `Int` |

## Functions

### `NET_BUF_SIZE(): Int` *(std/net/buffered_net.qz:38)*

---

### `net_reader_new_tcp(): BufferedNetReader` *(std/net/buffered_net.qz:41)*

---

### `net_reader_new_tls(): BufferedNetReader` *(std/net/buffered_net.qz:57)*

---

### `net_reader_new_tcp_sized(): BufferedNetReader` *(std/net/buffered_net.qz:71)*

---

### `_net_reader_refill(): Void` *(std/net/buffered_net.qz:85)*

---

### `net_reader_read_line(): String` *(std/net/buffered_net.qz:112)*

---

### `net_reader_read_n(): String` *(std/net/buffered_net.qz:162)*

---

### `net_reader_read_all(): String` *(std/net/buffered_net.qz:189)*

---

### `net_reader_is_eof(): Bool` *(std/net/buffered_net.qz:211)*

---

### `net_reader_close(): Void` *(std/net/buffered_net.qz:224)*

---

### `net_writer_new_tcp(): BufferedNetWriter` *(std/net/buffered_net.qz:245)*

---

### `net_writer_new_tls(): BufferedNetWriter` *(std/net/buffered_net.qz:257)*

---

### `_net_writer_do_flush(): Int` *(std/net/buffered_net.qz:269)*

---

### `net_writer_write(): Int` *(std/net/buffered_net.qz:293)*

---

### `net_writer_flush(): Int` *(std/net/buffered_net.qz:321)*

---

### `net_writer_close(): Void` *(std/net/buffered_net.qz:327)*

---

