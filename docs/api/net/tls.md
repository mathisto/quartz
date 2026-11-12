# net/tls

## Structs

### `TlsError` *(std/net/tls.qz:46)*

| Field | Type |
|-------|------|
| `message` | `String` |
| `code` | `Int` |

### `TlsContext` *(std/net/tls.qz:78)*

| Field | Type |
|-------|------|
| `ssl_ctx` | `Int` |
| `is_server` | `Int` |

### `TlsStream` *(std/net/tls.qz:188)*

| Field | Type |
|-------|------|
| `ssl` | `Int` |
| `fd` | `Int` |
| `host` | `String` |
| `port` | `Int` |

## Enums

### `TlsResult` *(std/net/tls.qz:59)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

### `TlsReadResult` *(std/net/tls.qz:64)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

### `TlsWriteResult` *(std/net/tls.qz:69)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

## Functions

### `_tls_write_i32(): Void` *(std/net/tls.qz:30)*

---

### `_tls_write_i64(): Void` *(std/net/tls.qz:37)*

---

### `tls_error(): TlsError` *(std/net/tls.qz:51)*

---

### `tls_ctx_new_client(): TlsContext` *(std/net/tls.qz:87)*

---

### `tls_ctx_new_server(): TlsContext` *(std/net/tls.qz:112)*

---

### `tls_ctx_free(): Void` *(std/net/tls.qz:128)*

---

### `tls_ctx_load_cert(): Int` *(std/net/tls.qz:137)*

---

### `tls_ctx_load_key(): Int` *(std/net/tls.qz:148)*

---

### `tls_ctx_check_key(): Int` *(std/net/tls.qz:158)*

---

### `tls_ctx_load_ca(): Int` *(std/net/tls.qz:168)*

---

### `tls_ctx_disable_verify(): Void` *(std/net/tls.qz:178)*

---

### `tls_connect(): TlsResult` *(std/net/tls.qz:200)*

---

### `tls_connect_noverify(): TlsResult` *(std/net/tls.qz:259)*

---

### `tls_connect_timeout(): TlsResult` *(std/net/tls.qz:300)*

---

### `tls_accept(): TlsResult` *(std/net/tls.qz:362)*

---

### `tls_read(): TlsReadResult` *(std/net/tls.qz:396)*

---

### `tls_write(): TlsWriteResult` *(std/net/tls.qz:437)*

---

### `tls_write_all(): TlsWriteResult` *(std/net/tls.qz:462)*

---

### `tls_close(): Void` *(std/net/tls.qz:490)*

---

### `tls_set_timeout(): Int` *(std/net/tls.qz:504)*

---

### `tls_fd(): Int` *(std/net/tls.qz:519)*

---

### `tls_ssl_ptr(): Int` *(std/net/tls.qz:522)*

---

