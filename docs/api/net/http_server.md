# net/http_server

## Structs

### `SockaddrIn` *(std/net/http_server.qz:156)*

| Field | Type |
|-------|------|
| `sin_len` | `U8` |
| `sin_family` | `U8` |
| `sin_port` | `U16` |
| `sin_addr` | `U32` |
| `sin_zero` | `Int` |

### `Request` *(std/net/http_server.qz:182)*

| Field | Type |
|-------|------|
| `method` | `String` |
| `path` | `String` |
| `query_string` | `String` |
| `body` | `String` |
| `raw_path` | `String` |
| `header_keys` | `Vec<String>` |
| `header_vals` | `Vec<String>` |
| `params` | `Int` |
| `query` | `Int` |
| `context` | `Int` |

### `Response` *(std/net/http_server.qz:199)*

| Field | Type |
|-------|------|
| `status` | `Int` |
| `body` | `String` |
| `content_type` | `String` |
| `extra_header_keys` | `Vec<String>` |
| `extra_header_vals` | `Vec<String>` |

### `CookieOpts` *(std/net/http_server.qz:514)*

| Field | Type |
|-------|------|
| `path` | `String` |
| `max_age` | `Int` |
| `http_only` | `Int` |
| `secure` | `Int` |
| `same_site` | `String` |

### `Route` *(std/net/http_server.qz:1950)*

| Field | Type |
|-------|------|
| `method` | `String` |
| `pattern` | `String` |
| `handler` | `Fn(Request): Response` |

### `Router` *(std/net/http_server.qz:1956)*

| Field | Type |
|-------|------|
| `routes` | `Vec<Route>` |

### `RouterGroup` *(std/net/http_server.qz:1988)*

| Field | Type |
|-------|------|
| `router` | `Router` |
| `prefix` | `String` |

### `HttpServerConfig` *(std/net/http_server.qz:2353)*

HTTP server configuration with production defaults.

| Field | Type |
|-------|------|
| `port` | `Int` |
| `max_connections` | `Int` |
| `keepalive_max_requests` | `Int` |
| `keepalive_timeout_ms` | `Int` |
| `read_timeout_ms` | `Int` |
| `write_timeout_ms` | `Int` |
| `shutdown_timeout_ms` | `Int` |
| `max_body_size` | `Int` |

## Functions

### `socket_send(): Int` *(std/net/http_server.qz:43)*

---

### `socket_recv(): Int` *(std/net/http_server.qz:47)*

---

### `SSL_CTX_set_min_proto_version(): Int` *(std/net/http_server.qz:88)*

---

### `SSL_FILETYPE_PEM(): Int` *(std/net/http_server.qz:108)*

---

### `TLS1_2_VERSION(): Int` *(std/net/http_server.qz:110)*

---

### `AF_INET(): Int` *(std/net/http_server.qz:113)*

---

### `SOCK_STREAM(): Int` *(std/net/http_server.qz:114)*

---

### `SOL_SOCKET(): Int` *(std/net/http_server.qz:117)*

---

### `SO_REUSEADDR(): Int` *(std/net/http_server.qz:122)*

---

### `SO_NOSIGPIPE(): Int` *(std/net/http_server.qz:127)*

---

### `EVFILT_READ(): Int` *(std/net/http_server.qz:131)*

---

### `EVFILT_WRITE(): Int` *(std/net/http_server.qz:133)*

---

### `EV_ADD(): Int` *(std/net/http_server.qz:135)*

---

### `EV_DELETE(): Int` *(std/net/http_server.qz:137)*

---

### `EV_ENABLE(): Int` *(std/net/http_server.qz:139)*

---

### `EV_EOF(): Int` *(std/net/http_server.qz:141)*

---

### `KEVENT_SIZE(): Int` *(std/net/http_server.qz:143)*

---

### `MAX_EVENTS(): Int` *(std/net/http_server.qz:145)*

---

### `_make_sockaddr_in(): SockaddrIn` *(std/net/http_server.qz:167)*

---

### `empty_request(): Request` *(std/net/http_server.qz:211)*

---

### `text_response(): Response` *(std/net/http_server.qz:215)*

---

### `json_response(): Response` *(std/net/http_server.qz:219)*

---

### `html_response(): Response` *(std/net/http_server.qz:223)*

---

### `not_found(): Response` *(std/net/http_server.qz:227)*

---

### `method_not_allowed(): Response` *(std/net/http_server.qz:231)*

---

### `payload_too_large(): Response` *(std/net/http_server.qz:235)*

---

### `server_error(): Response` *(std/net/http_server.qz:239)*

---

### `redirect(): Response` *(std/net/http_server.qz:243)*

---

### `bad_request(): Response` *(std/net/http_server.qz:250)*

---

### `unauthorized(): Response` *(std/net/http_server.qz:254)*

---

### `forbidden(): Response` *(std/net/http_server.qz:258)*

---

### `no_content(): Response` *(std/net/http_server.qz:262)*

---

### `created(): Response` *(std/net/http_server.qz:266)*

---

### `response_header(): Response` *(std/net/http_server.qz:270)*

---

### `request_header(): String` *(std/net/http_server.qz:280)*

---

### `str_eq_ignore_case(): Int` *(std/net/http_server.qz:291)*

---

### `_parse_query_into(): Void` *(std/net/http_server.qz:321)*

Parse query_string into req.query Map (first value per key wins).
Splits on & then on first = per pair, URL-decodes both key and value.

---

### `query_param(): String` *(std/net/http_server.qz:378)*

Get the first value for a query parameter, or "" if not present.

---

### `query_params(): Vec<String>` *(std/net/http_server.qz:386)*

Get all values for a query parameter key (re-parses query string).

---

### `query_has(): Bool` *(std/net/http_server.qz:429)*

Check if a query parameter exists.

---

### `path_param(): String` *(std/net/http_server.qz:438)*

Get a path parameter extracted at route match time, or "" if not present.

---

### `_extract_params(): Void` *(std/net/http_server.qz:447)*

Extract all path params from pattern into req.params Map.
Called at route match time by router_handler.

---

### `context_set(): Void` *(std/net/http_server.qz:493)*

Set a key-value pair in the request context (for middleware → handler data).

---

### `context_get(): String` *(std/net/http_server.qz:498)*

Get a value from the request context, or "" if not present.

---

### `context_has(): Bool` *(std/net/http_server.qz:506)*

Check if a key exists in the request context.

---

### `cookie_opts(): CookieOpts` *(std/net/http_server.qz:523)*

Create a CookieOpts with sensible defaults.

---

### `request_cookie(): String` *(std/net/http_server.qz:528)*

Get a cookie value from the request, or "" if not present.

---

### `request_has_cookie(): Bool` *(std/net/http_server.qz:575)*

Check if a cookie exists in the request.

---

### `set_cookie(): Response` *(std/net/http_server.qz:619)*

Set a cookie on a response. Returns the response with Set-Cookie header added.

---

### `delete_cookie(): Response` *(std/net/http_server.qz:648)*

Delete a cookie by setting Max-Age=-1.

---

### `request_json(): Result<JsonValue, ParseError>` *(std/net/http_server.qz:659)*

Parse the request body as JSON with Content-Type validation.
Returns Err if Content-Type is not application/json or body is empty.

---

### `request_form(): Result<Int, ParseError>` *(std/net/http_server.qz:681)*

Parse the request body as URL-encoded form data.
Returns Ok(Map handle) on success, Err if Content-Type is wrong or body is empty.

---

### `_parse_form_body(): Int` *(std/net/http_server.qz:697)*

Parse a URL-encoded key=value&key2=value2 string into a new Map.

---

### `status_text(): String` *(std/net/http_server.qz:747)*

---

### `parse_method(): String` *(std/net/http_server.qz:794)*

---

### `parse_path(): String` *(std/net/http_server.qz:802)*

---

### `tcp_read_bytes(): String` *(std/net/http_server.qz:821)*

---

### `tcp_read_line_raw(): String` *(std/net/http_server.qz:837)*

---

### `tcp_write_str(): Int` *(std/net/http_server.qz:872)*

---

### `http_parse_request(): Request` *(std/net/http_server.qz:890)*

---

### `http_write_response(): Int` *(std/net/http_server.qz:963)*

---

### `set_nonblocking(): Int` *(std/net/http_server.qz:986)*

---

### `ptr_write_i16(): Int` *(std/net/http_server.qz:994)*

---

### `ptr_write_i32(): Int` *(std/net/http_server.qz:1000)*

---

### `ptr_write_i64(): Int` *(std/net/http_server.qz:1008)*

---

### `ptr_read_i16(): Int` *(std/net/http_server.qz:1014)*

---

### `ptr_read_i32(): Int` *(std/net/http_server.qz:1024)*

---

### `ptr_read_i64(): Int` *(std/net/http_server.qz:1032)*

---

### `kevent_set(): Int` *(std/net/http_server.qz:1039)*

---

### `kevent_get_ident(): Int` *(std/net/http_server.qz:1050)*

---

### `kevent_get_filter(): Int` *(std/net/http_server.qz:1059)*

---

### `kq_add_read(): Int` *(std/net/http_server.qz:1064)*

---

### `http_serve(): Int` *(std/net/http_server.qz:1077)*

---

### `_http_get_errno(): Int` *(std/net/http_server.qz:1185)*

---

### `_http_EAGAIN(): Int` *(std/net/http_server.qz:1205)*

---

### `kq_add_readwrite(): Int` *(std/net/http_server.qz:1211)*

---

### `kq_remove(): Int` *(std/net/http_server.qz:1222)*

---

### `_async_http_recv(): Int` *(std/net/http_server.qz:1233)*

---

### `_async_http_send(): Int` *(std/net/http_server.qz:1250)*

---

### `_async_http_recv_timeout(): Int` *(std/net/http_server.qz:1268)*

---

### `_async_http_send_timeout(): Int` *(std/net/http_server.qz:1297)*

---

### `_async_http_parse_request_timeout(): Request` *(std/net/http_server.qz:1324)*

---

### `_async_http_write_response_timeout(): Int` *(std/net/http_server.qz:1338)*

---

### `_parse_request_from_buffer(): Request` *(std/net/http_server.qz:1356)*

---

### `_async_http_parse_request(): Request` *(std/net/http_server.qz:1438)*

---

### `_async_http_write_response(): Int` *(std/net/http_server.qz:1452)*

---

### `_handle_connection_async(): Int` *(std/net/http_server.qz:1473)*

---

### `_http_decode_fd(): Int` *(std/net/http_server.qz:1485)*

---

### `http_serve_async(): Int` *(std/net/http_server.qz:1494)*

---

### `tls_read_bytes(): String` *(std/net/http_server.qz:1618)*

---

### `tls_read_line_raw(): String` *(std/net/http_server.qz:1635)*

---

### `tls_write_str(): Int` *(std/net/http_server.qz:1671)*

---

### `http_parse_request_tls(): Request` *(std/net/http_server.qz:1687)*

---

### `_tls_write_response(): Int` *(std/net/http_server.qz:1754)*

---

### `http_serve_tls(): Int` *(std/net/http_server.qz:1773)*

---

### `router_new(): Router` *(std/net/http_server.qz:1960)*

---

### `router_get(): Int` *(std/net/http_server.qz:1964)*

---

### `router_post(): Int` *(std/net/http_server.qz:1969)*

---

### `router_put(): Int` *(std/net/http_server.qz:1974)*

---

### `router_delete(): Int` *(std/net/http_server.qz:1979)*

---

### `router_group(): RouterGroup` *(std/net/http_server.qz:1993)*

---

### `group_get(): Int` *(std/net/http_server.qz:1997)*

---

### `group_post(): Int` *(std/net/http_server.qz:2002)*

---

### `group_put(): Int` *(std/net/http_server.qz:2007)*

---

### `group_delete(): Int` *(std/net/http_server.qz:2012)*

---

### `route_matches(): Int` *(std/net/http_server.qz:2021)*

---

### `route_param(): String` *(std/net/http_server.qz:2062)*

---

### `route_call_handler(): Response` *(std/net/http_server.qz:2112)*

---

### `router_handler(): Fn(Request): Response` *(std/net/http_server.qz:2116)*

---

### `with_logging(): Fn(Request): Response` *(std/net/http_server.qz:2135)*

---

### `with_cors(): Fn(Request): Response` *(std/net/http_server.qz:2144)*

---

### `_mime_type(): String` *(std/net/http_server.qz:2163)*

Detect MIME type from file extension.

---

### `_has_path_traversal(): Bool` *(std/net/http_server.qz:2213)*

Check if a path contains ".." traversal (raw or percent-encoded).

---

### `with_static(): Fn(Fn(Request): Response): Fn(Request): Response` *(std/net/http_server.qz:2229)*

Static file serving middleware with automatic Markdown rendering.
Serves files from `dir` when request path starts with `url_prefix`.
Markdown files (.md) are auto-rendered as styled HTML pages.
Falls through to the next handler if no matching file is found.

Usage: http_serve(8080, handler | with_static("/", "./public"))

---

### `_static_middleware(): Fn(Fn(Request): Response): Fn(Request): Response` *(std/net/http_server.qz:2233)*

---

### `_static_make_handler(): Fn(Request): Response` *(std/net/http_server.qz:2237)*

---

### `_static_handle_request(): Response` *(std/net/http_server.qz:2243)*

---

### `http_serve_concurrent(): Int` *(std/net/http_server.qz:2299)*

---

### `http_server_shutdown(): Void` *(std/net/http_server.qz:2348)*

Request graceful shutdown of the HTTP server.
Can be called from any thread (uses atomic store).

---

### `http_server_config(): HttpServerConfig` *(std/net/http_server.qz:2365)*

Create a server config with sensible production defaults.

---

### `_http_should_close(): Bool` *(std/net/http_server.qz:2379)*

Check if a request wants connection close.

---

### `_handle_connection_keepalive(): Int` *(std/net/http_server.qz:2400)*

Handle a single connection with keep-alive support.
Loops on the connection, serving multiple requests until:
  - Connection: close header
  - Max requests reached
  - Read error/timeout
  - Shutdown flag set

---

### `_http_send_503(): Void` *(std/net/http_server.qz:2438)*

---

### `http_serve_opts(): Int` *(std/net/http_server.qz:2445)*

Production HTTP server with configurable options.
Supports: keep-alive, connection limits, graceful shutdown via SIGTERM.

---

## FFI Functions

### `socket(domain: CInt, socket_type: CInt, protocol: CInt): CInt` *(std/net/http_server.qz:34)*

### `connect(sockfd: CInt, addr: CPtr, addrlen: CInt): CInt` *(std/net/http_server.qz:35)*

### `bind(sockfd: CInt, addr: CPtr, addrlen: CInt): CInt` *(std/net/http_server.qz:36)*

### `listen(sockfd: CInt, backlog: CInt): CInt` *(std/net/http_server.qz:37)*

### `accept(sockfd: CInt, addr: CPtr, addrlen: CPtr): CInt` *(std/net/http_server.qz:38)*

### `sendto(sockfd: CInt, buf: CPtr, len: CSize, flags: CInt, addr: CPtr, addrlen: CInt): Int` *(std/net/http_server.qz:39)*

### `recvfrom(sockfd: CInt, buf: CPtr, len: CSize, flags: CInt, addr: CPtr, addrlen: CPtr): Int` *(std/net/http_server.qz:40)*

### `shutdown(sockfd: CInt, how: CInt): CInt` *(std/net/http_server.qz:50)*

### `close(fd: CInt): CInt` *(std/net/http_server.qz:51)*

### `setsockopt(sockfd: CInt, level: CInt, optname: CInt, optval: CPtr, optlen: CInt): CInt` *(std/net/http_server.qz:52)*

### `htons(hostshort: CInt): CInt` *(std/net/http_server.qz:53)*

### `inet_pton(af: CInt, src: CPtr, dst: CPtr): CInt` *(std/net/http_server.qz:54)*

### `malloc(size: CSize): CPtr` *(std/net/http_server.qz:55)*

### `free(ptr: CPtr): Void` *(std/net/http_server.qz:56)*

### `memset(ptr: CPtr, value: CInt, size: CSize): CPtr` *(std/net/http_server.qz:57)*

### `strlen(str: CPtr): CSize` *(std/net/http_server.qz:58)*

### `kqueue(): CInt` *(std/net/http_server.qz:60)*

### `kevent(kq: CInt, changelist: CPtr, nchanges: CInt, eventlist: CPtr, nevents: CInt, timeout: CPtr): CInt` *(std/net/http_server.qz:62)*

### `fcntl(fd: CInt, cmd: CInt, arg: CInt): CInt` *(std/net/http_server.qz:63)*

### `OPENSSL_init_ssl(opts: Int, settings: CPtr): CInt` *(std/net/http_server.qz:69)*

### `TLS_server_method(): CPtr` *(std/net/http_server.qz:71)*

### `SSL_CTX_new(method: CPtr): CPtr` *(std/net/http_server.qz:73)*

### `SSL_CTX_free(ctx: CPtr): Void` *(std/net/http_server.qz:75)*

### `SSL_CTX_use_certificate_file(ctx: CPtr, file: CPtr, file_type: CInt): CInt` *(std/net/http_server.qz:77)*

### `SSL_CTX_use_PrivateKey_file(ctx: CPtr, file: CPtr, file_type: CInt): CInt` *(std/net/http_server.qz:79)*

### `SSL_CTX_check_private_key(ctx: CPtr): CInt` *(std/net/http_server.qz:81)*

### `SSL_CTX_ctrl(ctx: CPtr, cmd: CInt, larg: Int, parg: CPtr): Int` *(std/net/http_server.qz:83)*

### `SSL_new(ctx: CPtr): CPtr` *(std/net/http_server.qz:92)*

### `SSL_free(ssl: CPtr): Void` *(std/net/http_server.qz:94)*

### `SSL_set_fd(ssl: CPtr, fd: CInt): CInt` *(std/net/http_server.qz:96)*

### `SSL_accept(ssl: CPtr): CInt` *(std/net/http_server.qz:98)*

### `SSL_read(ssl: CPtr, buf: CPtr, num: CInt): CInt` *(std/net/http_server.qz:100)*

### `SSL_write(ssl: CPtr, buf: CPtr, num: CInt): CInt` *(std/net/http_server.qz:102)*

### `SSL_shutdown(ssl: CPtr): CInt` *(std/net/http_server.qz:104)*

### `ERR_clear_error(): Void` *(std/net/http_server.qz:106)*

### `__error(): CPtr` *(std/net/http_server.qz:1179)*

