# ffi/socket

## Structs

### `SockaddrIn` *(std/ffi/socket.qz:94)*

| Field | Type |
|-------|------|
| `sin_len` | `U8` |
| `sin_family` | `U8` |
| `sin_port` | `U16` |
| `sin_addr` | `U32` |
| `sin_zero` | `Int` |

### `Timeval` *(std/ffi/socket.qz:105)*

| Field | Type |
|-------|------|
| `tv_sec` | `Int` |
| `tv_usec` | `Int` |

### `Addrinfo` *(std/ffi/socket.qz:115)*

| Field | Type |
|-------|------|
| `ai_flags` | `U32` |
| `ai_family` | `U32` |
| `ai_socktype` | `U32` |
| `ai_protocol` | `U32` |
| `ai_addrlen` | `U32` |
| `ai_canonname` | `Int` |
| `ai_addr` | `Int` |
| `ai_next` | `Int` |

## Functions

### `AF_UNSPEC(): Int` *(std/ffi/socket.qz:19)*

---

### `AF_UNIX(): Int` *(std/ffi/socket.qz:20)*

---

### `AF_INET(): Int` *(std/ffi/socket.qz:21)*

---

### `AF_INET6(): Int` *(std/ffi/socket.qz:25)*

---

### `SOCK_STREAM(): Int` *(std/ffi/socket.qz:31)*

---

### `SOCK_DGRAM(): Int` *(std/ffi/socket.qz:32)*

---

### `SOCK_RAW(): Int` *(std/ffi/socket.qz:33)*

---

### `IPPROTO_TCP(): Int` *(std/ffi/socket.qz:36)*

---

### `IPPROTO_UDP(): Int` *(std/ffi/socket.qz:37)*

---

### `SHUT_RD(): Int` *(std/ffi/socket.qz:40)*

---

### `SHUT_WR(): Int` *(std/ffi/socket.qz:41)*

---

### `SHUT_RDWR(): Int` *(std/ffi/socket.qz:42)*

---

### `SOL_SOCKET(): Int` *(std/ffi/socket.qz:46)*

---

### `SO_REUSEADDR(): Int` *(std/ffi/socket.qz:53)*

---

### `SO_KEEPALIVE(): Int` *(std/ffi/socket.qz:59)*

---

### `SO_RCVTIMEO(): Int` *(std/ffi/socket.qz:65)*

---

### `SO_SNDTIMEO(): Int` *(std/ffi/socket.qz:71)*

---

### `TCP_NODELAY(): Int` *(std/ffi/socket.qz:77)*

---

### `SO_NOSIGPIPE(): Int` *(std/ffi/socket.qz:81)*

---

### `htons(): Int` *(std/ffi/socket.qz:209)*

---

### `ntohs(): Int` *(std/ffi/socket.qz:212)*

---

### `htonl(): Int` *(std/ffi/socket.qz:215)*

---

### `ntohl(): Int` *(std/ffi/socket.qz:224)*

---

### `get_errno(): Int` *(std/ffi/socket.qz:285)*

---

### `POLLFD_SIZE(): Int` *(std/ffi/socket.qz:322)*

---

### `POLLIN(): Int` *(std/ffi/socket.qz:325)*

---

### `POLLOUT(): Int` *(std/ffi/socket.qz:326)*

---

### `POLLERR(): Int` *(std/ffi/socket.qz:327)*

---

### `POLLHUP(): Int` *(std/ffi/socket.qz:328)*

---

### `POLLNVAL(): Int` *(std/ffi/socket.qz:329)*

---

### `pollfd_new(): Int` *(std/ffi/socket.qz:332)*

---

### `pollfd_revents(): Int` *(std/ffi/socket.qz:349)*

---

### `F_GETFL(): Int` *(std/ffi/socket.qz:359)*

---

### `F_SETFL(): Int` *(std/ffi/socket.qz:360)*

---

### `O_NONBLOCK(): Int` *(std/ffi/socket.qz:361)*

---

### `EINPROGRESS(): Int` *(std/ffi/socket.qz:365)*

---

### `EAGAIN(): Int` *(std/ffi/socket.qz:372)*

---

### `EWOULDBLOCK(): Int` *(std/ffi/socket.qz:376)*

---

### `SO_ERROR(): Int` *(std/ffi/socket.qz:381)*

---

### `socket_fcntl(): Int` *(std/ffi/socket.qz:391)*

---

### `socket_accept(): Int` *(std/ffi/socket.qz:393)*

---

### `socket_send(): Int` *(std/ffi/socket.qz:395)*

---

### `socket_recv(): Int` *(std/ffi/socket.qz:399)*

---

### `pipe_create(): Vec<Int>` *(std/ffi/socket.qz:418)*

---

### `fd_write_byte(): Int` *(std/ffi/socket.qz:442)*

---

### `fd_read(): Int` *(std/ffi/socket.qz:451)*

---

## FFI Functions

### `socket(domain: CInt, socket_type: CInt, protocol: CInt): CInt` *(std/ffi/socket.qz:146)*

### `connect(sockfd: CInt, addr: CPtr, addrlen: CInt): CInt` *(std/ffi/socket.qz:150)*

### `bind(sockfd: CInt, addr: CPtr, addrlen: CInt): CInt` *(std/ffi/socket.qz:154)*

### `listen(sockfd: CInt, backlog: CInt): CInt` *(std/ffi/socket.qz:158)*

### `accept(sockfd: CInt, addr: CPtr, addrlen: CPtr): CInt` *(std/ffi/socket.qz:162)*

### `send(sockfd: CInt, buf: CPtr, len: CSize, flags: CInt): Int` *(std/ffi/socket.qz:168)*

### `recv(sockfd: CInt, buf: CPtr, len: CSize, flags: CInt): Int` *(std/ffi/socket.qz:174)*

### `sendto(sockfd: CInt, buf: CPtr, len: CSize, flags: CInt, addr: CPtr, addrlen: CInt): Int` *(std/ffi/socket.qz:178)*

### `recvfrom(sockfd: CInt, buf: CPtr, len: CSize, flags: CInt, addr: CPtr, addrlen: CPtr): Int` *(std/ffi/socket.qz:182)*

### `shutdown(sockfd: CInt, how: CInt): CInt` *(std/ffi/socket.qz:186)*

### `close(fd: CInt): CInt` *(std/ffi/socket.qz:189)*

### `setsockopt(sockfd: CInt, level: CInt, optname: CInt, optval: CPtr, optlen: CInt): CInt` *(std/ffi/socket.qz:193)*

### `getsockname(sockfd: CInt, addr: CPtr, addrlen: CPtr): CInt` *(std/ffi/socket.qz:197)*

### `getsockopt(sockfd: CInt, level: CInt, optname: CInt, optval: CPtr, optlen: CPtr): CInt` *(std/ffi/socket.qz:201)*

### `inet_pton(af: CInt, src: CPtr, dst: CPtr): CInt` *(std/ffi/socket.qz:228)*

### `inet_ntop(af: CInt, src: CPtr, dst: CPtr, size: CInt): CPtr` *(std/ffi/socket.qz:232)*

### `getaddrinfo(node: CPtr, service: CPtr, hints: CPtr, res: CPtr): CInt` *(std/ffi/socket.qz:240)*

### `freeaddrinfo(res: CPtr): CInt` *(std/ffi/socket.qz:243)*

### `gai_strerror(errcode: CInt): CPtr` *(std/ffi/socket.qz:246)*

### `malloc(size: CSize): CPtr` *(std/ffi/socket.qz:253)*

### `free(ptr: CPtr): Void` *(std/ffi/socket.qz:256)*

### `memset(ptr: CPtr, value: CInt, size: CSize): CPtr` *(std/ffi/socket.qz:259)*

### `memcpy(dest: CPtr, src: CPtr, size: CSize): CPtr` *(std/ffi/socket.qz:262)*

### `strlen(str: CPtr): CSize` *(std/ffi/socket.qz:265)*

### `__error(): CPtr` *(std/ffi/socket.qz:275)*

### `strerror(errnum: CInt): CPtr` *(std/ffi/socket.qz:281)*

### `poll(fds: CPtr, nfds: CInt, timeout: CInt): CInt` *(std/ffi/socket.qz:316)*

### `fcntl(fd: CInt, cmd: CInt): CInt` *(std/ffi/socket.qz:356)*

### `read(fd: CInt, buf: CPtr, count: CSize): Int` *(std/ffi/socket.qz:408)*

### `write(fd: CInt, buf: CPtr, count: CSize): Int` *(std/ffi/socket.qz:411)*

### `pipe(pipefd: CPtr): CInt` *(std/ffi/socket.qz:415)*

