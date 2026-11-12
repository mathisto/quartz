# ffi/tls

## Functions

### `SSL_CTX_set_min_proto_version(): Int` *(std/ffi/tls.qz:91)*

---

### `ssl_set_hostname(): Int` *(std/ffi/tls.qz:150)*

---

### `ssl_set_verify_hostname(): Int` *(std/ffi/tls.qz:161)*

---

### `ssl_error_string(): String` *(std/ffi/tls.qz:186)*

---

### `ssl_drain_errors(): String` *(std/ffi/tls.qz:199)*

---

### `SSL_VERIFY_NONE(): Int` *(std/ffi/tls.qz:228)*

---

### `SSL_VERIFY_PEER(): Int` *(std/ffi/tls.qz:229)*

---

### `SSL_VERIFY_FAIL_IF_NO_PEER_CERT(): Int` *(std/ffi/tls.qz:230)*

---

### `SSL_FILETYPE_PEM(): Int` *(std/ffi/tls.qz:233)*

---

### `SSL_FILETYPE_ASN1(): Int` *(std/ffi/tls.qz:234)*

---

### `SSL_ERROR_NONE(): Int` *(std/ffi/tls.qz:237)*

---

### `SSL_ERROR_SSL(): Int` *(std/ffi/tls.qz:238)*

---

### `SSL_ERROR_WANT_READ(): Int` *(std/ffi/tls.qz:239)*

---

### `SSL_ERROR_WANT_WRITE(): Int` *(std/ffi/tls.qz:240)*

---

### `SSL_ERROR_WANT_X509_LOOKUP(): Int` *(std/ffi/tls.qz:241)*

---

### `SSL_ERROR_SYSCALL(): Int` *(std/ffi/tls.qz:242)*

---

### `SSL_ERROR_ZERO_RETURN(): Int` *(std/ffi/tls.qz:243)*

---

### `SSL_ERROR_WANT_CONNECT(): Int` *(std/ffi/tls.qz:244)*

---

### `SSL_ERROR_WANT_ACCEPT(): Int` *(std/ffi/tls.qz:245)*

---

### `X509_V_OK(): Int` *(std/ffi/tls.qz:248)*

---

### `TLS1_2_VERSION(): Int` *(std/ffi/tls.qz:251)*

---

### `TLS1_3_VERSION(): Int` *(std/ffi/tls.qz:252)*

---

### `OPENSSL_INIT_LOAD_SSL_STRINGS(): Int` *(std/ffi/tls.qz:255)*

---

### `OPENSSL_INIT_LOAD_CRYPTO_STRINGS(): Int` *(std/ffi/tls.qz:256)*

---

## FFI Functions

### `OPENSSL_init_ssl(opts: Int, settings: CPtr): CInt` *(std/ffi/tls.qz:21)*

### `OPENSSL_init_crypto(opts: Int, settings: CPtr): CInt` *(std/ffi/tls.qz:24)*

### `TLS_method(): CPtr` *(std/ffi/tls.qz:32)*

### `TLS_client_method(): CPtr` *(std/ffi/tls.qz:35)*

### `TLS_server_method(): CPtr` *(std/ffi/tls.qz:38)*

### `SSL_CTX_new(method: CPtr): CPtr` *(std/ffi/tls.qz:47)*

### `SSL_CTX_free(ctx: CPtr): Void` *(std/ffi/tls.qz:50)*

### `SSL_CTX_set_verify(ctx: CPtr, mode: CInt, callback: CPtr): Void` *(std/ffi/tls.qz:55)*

### `SSL_CTX_set_default_verify_paths(ctx: CPtr): CInt` *(std/ffi/tls.qz:61)*

### `SSL_CTX_load_verify_locations(ctx: CPtr, file: CPtr, path: CPtr): CInt` *(std/ffi/tls.qz:67)*

### `SSL_CTX_use_certificate_file(ctx: CPtr, file: CPtr, file_type: CInt): CInt` *(std/ffi/tls.qz:73)*

### `SSL_CTX_use_PrivateKey_file(ctx: CPtr, file: CPtr, file_type: CInt): CInt` *(std/ffi/tls.qz:79)*

### `SSL_CTX_check_private_key(ctx: CPtr): CInt` *(std/ffi/tls.qz:83)*

### `SSL_CTX_ctrl(ctx: CPtr, cmd: CInt, larg: Int, parg: CPtr): Int` *(std/ffi/tls.qz:87)*

### `SSL_new(ctx: CPtr): CPtr` *(std/ffi/tls.qz:101)*

### `SSL_free(ssl: CPtr): Void` *(std/ffi/tls.qz:104)*

### `SSL_set_fd(ssl: CPtr, fd: CInt): CInt` *(std/ffi/tls.qz:108)*

### `SSL_connect(ssl: CPtr): CInt` *(std/ffi/tls.qz:112)*

### `SSL_accept(ssl: CPtr): CInt` *(std/ffi/tls.qz:116)*

### `SSL_read(ssl: CPtr, buf: CPtr, num: CInt): CInt` *(std/ffi/tls.qz:120)*

### `SSL_write(ssl: CPtr, buf: CPtr, num: CInt): CInt` *(std/ffi/tls.qz:124)*

### `SSL_shutdown(ssl: CPtr): CInt` *(std/ffi/tls.qz:128)*

### `SSL_get_error(ssl: CPtr, ret: CInt): CInt` *(std/ffi/tls.qz:133)*

### `SSL_get_verify_result(ssl: CPtr): Int` *(std/ffi/tls.qz:137)*

### `SSL_ctrl(ssl: CPtr, cmd: CInt, larg: Int, parg: CPtr): Int` *(std/ffi/tls.qz:146)*

### `SSL_set1_host(ssl: CPtr, hostname: CPtr): CInt` *(std/ffi/tls.qz:158)*

### `ERR_get_error(): Int` *(std/ffi/tls.qz:172)*

### `ERR_error_string_n(e: Int, buf: CPtr, len: CSize): Void` *(std/ffi/tls.qz:177)*

### `ERR_clear_error(): Void` *(std/ffi/tls.qz:180)*

### `ERR_peek_last_error(): Int` *(std/ffi/tls.qz:183)*

### `malloc(size: CSize): CPtr` *(std/ffi/tls.qz:219)*

### `free(ptr: CPtr): Void` *(std/ffi/tls.qz:220)*

### `memset(ptr: CPtr, value: CInt, size: CSize): CPtr` *(std/ffi/tls.qz:221)*

