# net/http

## Structs

### `HttpError` *(std/net/http.qz:24)*

| Field | Type |
|-------|------|
| `message` | `String` |
| `code` | `Int` |

### `HttpResponse` *(std/net/http.qz:35)*

| Field | Type |
|-------|------|
| `status` | `Int` |
| `status_text` | `String` |
| `body` | `String` |
| `content_length` | `Int` |

### `HttpConn` *(std/net/http.qz:175)*

| Field | Type |
|-------|------|
| `tcp_fd` | `Int` |
| `ssl_ptr` | `Int` |
| `is_tls` | `Int` |

## Enums

### `HttpResult` *(std/net/http.qz:46)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

## Functions

### `http_error(): HttpError` *(std/net/http.qz:29)*

---

### `http_result_is_ok(): Bool` *(std/net/http.qz:52)*

---

### `http_result_is_err(): Bool` *(std/net/http.qz:59)*

---

### `http_result_body(): String` *(std/net/http.qz:66)*

---

### `http_result_status(): Int` *(std/net/http.qz:73)*

---

### `url_host(): String` *(std/net/http.qz:84)*

---

### `url_port(): Int` *(std/net/http.qz:105)*

---

### `url_path(): String` *(std/net/http.qz:147)*

---

### `url_is_https(): Bool` *(std/net/http.qz:168)*

---

### `_http_conn_read(): String` *(std/net/http.qz:182)*

---

### `_http_conn_read_all(): String` *(std/net/http.qz:197)*

---

### `_http_conn_write(): Int` *(std/net/http.qz:212)*

---

### `_http_conn_close(): Void` *(std/net/http.qz:227)*

---

### `_get_tls_ctx(): TlsContext` *(std/net/http.qz:237)*

---

### `_http_connect(): HttpResult` *(std/net/http.qz:242)*

---

### `_http_request(): HttpResult` *(std/net/http.qz:280)*

---

### `_http_build_response(): HttpResult` *(std/net/http.qz:373)*

---

### `HTTP_MAX_REDIRECTS(): Int` *(std/net/http.qz:389)*

---

### `http_get(): HttpResult` *(std/net/http.qz:392)*

---

### `http_post(): HttpResult` *(std/net/http.qz:397)*

---

### `http_get_timeout(): HttpResult` *(std/net/http.qz:402)*

---

### `http_parse_response(): HttpResult` *(std/net/http.qz:410)*

---

### `http_parse_status(): Int` *(std/net/http.qz:416)*

---

### `http_parse_status_text(): String` *(std/net/http.qz:427)*

---

### `http_parse_header(): String` *(std/net/http.qz:451)*

---

### `http_is_ok(): Bool` *(std/net/http.qz:482)*

---

### `http_is_redirect(): Bool` *(std/net/http.qz:483)*

---

### `http_is_client_error(): Bool` *(std/net/http.qz:484)*

---

### `http_is_server_error(): Bool` *(std/net/http.qz:485)*

---

### `http_get_body(): String` *(std/net/http.qz:492)*

---

### `http_get_result(): HttpResult` *(std/net/http.qz:497)*

---

### `http_get_or_panic(): String` *(std/net/http.qz:502)*

---

