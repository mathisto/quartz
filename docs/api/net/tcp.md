# net/tcp

## Structs

### `TcpError` *(std/net/tcp.qz:110)*

| Field | Type |
|-------|------|
| `message` | `String` |
| `code` | `Int` |

### `TcpStream` *(std/net/tcp.qz:158)*

| Field | Type |
|-------|------|
| `fd` | `Int` |
| `host` | `String` |
| `port` | `Int` |
| `connected` | `Int` |

### `TcpListener` *(std/net/tcp.qz:174)*

| Field | Type |
|-------|------|
| `fd` | `Int` |
| `_host` | `String` |
| `port` | `Int` |
| `active` | `Int` |

### `Tcp` *(std/net/tcp.qz:194)*

| Field | Type |
|-------|------|
| `_placeholder` | `Int` |

## Enums

### `TcpResult` *(std/net/tcp.qz:125)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

### `ReadResult` *(std/net/tcp.qz:131)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

### `WriteResult` *(std/net/tcp.qz:137)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

### `AcceptResult` *(std/net/tcp.qz:143)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

### `ListenResult` *(std/net/tcp.qz:149)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

## Functions

### `_tcp_write_i32(): Void` *(std/net/tcp.qz:62)*

---

### `_tcp_write_i64(): Void` *(std/net/tcp.qz:69)*

---

### `_tcp_make_sockaddr(): Int` *(std/net/tcp.qz:79)*

---

### `_tcp_read_sockaddr_port(): Int` *(std/net/tcp.qz:91)*

---

### `_tcp_write_sockaddr_addr(): Void` *(std/net/tcp.qz:98)*

---

### `tcp_error(): TcpError` *(std/net/tcp.qz:116)*

---

### `tcp_stream(): TcpStream` *(std/net/tcp.qz:166)*

---

### `tcp_listener(): TcpListener` *(std/net/tcp.qz:185)*

---

### `resolve_host(): Int` *(std/net/tcp.qz:201)*

---

### `tcp_connect(): TcpResult` *(std/net/tcp.qz:260)*

---

### `tcp_connect_timeout(): TcpResult` *(std/net/tcp.qz:298)*

---

### `tcp_listen(): ListenResult` *(std/net/tcp.qz:385)*

---

### `tcp_read(): ReadResult` *(std/net/tcp.qz:435)*

---

### `tcp_write(): WriteResult` *(std/net/tcp.qz:462)*

---

### `tcp_set_nonblocking(): Int` *(std/net/tcp.qz:485)*

---

### `tcp_read_nb(): Int` *(std/net/tcp.qz:495)*

---

### `tcp_write_nb(): Int` *(std/net/tcp.qz:501)*

---

### `async_tcp_read(): Int` *(std/net/tcp.qz:513)*

Async non-blocking TCP read. Suspends via io_suspend when EAGAIN.
For use in functions called via `async` and driven by EventedIo.
fd must already be in non-blocking mode (via tcp_set_nonblocking).

---

### `async_tcp_write(): Int` *(std/net/tcp.qz:531)*

Async non-blocking TCP write. Suspends via io_suspend when EAGAIN.
fd must already be in non-blocking mode (via tcp_set_nonblocking).

---

### `async_tcp_accept(): Int` *(std/net/tcp.qz:549)*

Async non-blocking TCP accept. Suspends via io_suspend when EAGAIN.
listener fd must already be in non-blocking mode.

---

### `tcp_close(): Int` *(std/net/tcp.qz:565)*

---

### `tcp_accept(): AcceptResult` *(std/net/tcp.qz:576)*

---

### `tcp_close_listener(): Int` *(std/net/tcp.qz:586)*

---

### `tcp_is_connected(): Bool` *(std/net/tcp.qz:598)*

---

### `tcp_fd(): Int` *(std/net/tcp.qz:601)*

---

### `tcp_set_timeout(): Int` *(std/net/tcp.qz:606)*

---

### `tcp_set_send_timeout(): Int` *(std/net/tcp.qz:616)*

---

### `tcp_set_nodelay(): Int` *(std/net/tcp.qz:626)*

---

### `tcp_write_all(): WriteResult` *(std/net/tcp.qz:635)*

---

### `tcp_read_line(): ReadResult` *(std/net/tcp.qz:654)*

---

### `tcp_serve(): Int` *(std/net/tcp.qz:724)*

---

