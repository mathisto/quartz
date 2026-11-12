# net/event_loop

## Structs

### `ReadyEvent` *(std/net/event_loop.qz:38)*

| Field | Type |
|-------|------|
| `fd` | `Int` |
| `readable` | `Int` |
| `writable` | `Int` |
| `error` | `Int` |
| `eof` | `Int` |

### `EventLoop` *(std/net/event_loop.qz:47)*

| Field | Type |
|-------|------|
| `fd` | `Int` |

## Functions

### `MAX_EVENTS(): Int` *(std/net/event_loop.qz:52)*

---

### `event_loop_new(): EventLoop` *(std/net/event_loop.qz:61)*

---

### `event_loop_close(): Int` *(std/net/event_loop.qz:73)*

---

### `event_loop_add_read(): Int` *(std/net/event_loop.qz:83)*

---

### `event_loop_add_write(): Int` *(std/net/event_loop.qz:93)*

---

### `event_loop_add_readwrite(): Int` *(std/net/event_loop.qz:103)*

---

### `event_loop_remove_read(): Int` *(std/net/event_loop.qz:115)*

---

### `event_loop_remove_write(): Int` *(std/net/event_loop.qz:125)*

---

### `event_loop_remove(): Int` *(std/net/event_loop.qz:135)*

---

### `event_loop_wait(): Vec<ReadyEvent>` *(std/net/event_loop.qz:198)*

---

