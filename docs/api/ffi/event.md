# ffi/event

## Functions

### `F_GETFL(): Int` *(std/ffi/event.qz:20)*

---

### `F_SETFL(): Int` *(std/ffi/event.qz:21)*

---

### `O_NONBLOCK(): Int` *(std/ffi/event.qz:25)*

---

### `set_nonblocking(): Int` *(std/ffi/event.qz:36)*

---

### `KEVENT_SIZE(): Int` *(std/ffi/event.qz:70)*

---

### `EVFILT_READ(): Int` *(std/ffi/event.qz:73)*

---

### `EVFILT_WRITE(): Int` *(std/ffi/event.qz:74)*

---

### `EV_ADD(): Int` *(std/ffi/event.qz:77)*

---

### `EV_DELETE(): Int` *(std/ffi/event.qz:78)*

---

### `EV_ENABLE(): Int` *(std/ffi/event.qz:79)*

---

### `EV_ONESHOT(): Int` *(std/ffi/event.qz:80)*

---

### `EV_EOF(): Int` *(std/ffi/event.qz:81)*

---

### `EV_ERROR(): Int` *(std/ffi/event.qz:82)*

---

### `EPOLL_EVENT_SIZE(): Int` *(std/ffi/event.qz:96)*

---

### `EPOLL_CTL_ADD(): Int` *(std/ffi/event.qz:99)*

---

### `EPOLL_CTL_DEL(): Int` *(std/ffi/event.qz:100)*

---

### `EPOLL_CTL_MOD(): Int` *(std/ffi/event.qz:101)*

---

### `EPOLLIN(): Int` *(std/ffi/event.qz:104)*

---

### `EPOLLOUT(): Int` *(std/ffi/event.qz:105)*

---

### `EPOLLERR(): Int` *(std/ffi/event.qz:106)*

---

### `EPOLLHUP(): Int` *(std/ffi/event.qz:107)*

---

### `EPOLLET(): Int` *(std/ffi/event.qz:108)*

---

### `ptr_write_i16(): Int` *(std/ffi/event.qz:115)*

---

### `ptr_read_i16(): Int` *(std/ffi/event.qz:122)*

---

### `ptr_write_i32(): Int` *(std/ffi/event.qz:134)*

---

### `ptr_read_i32(): Int` *(std/ffi/event.qz:143)*

---

### `ptr_write_i64(): Int` *(std/ffi/event.qz:152)*

---

### `ptr_read_i64(): Int` *(std/ffi/event.qz:159)*

---

### `kevent_set(): Int` *(std/ffi/event.qz:172)*

---

### `kevent_get_ident(): Int` *(std/ffi/event.qz:184)*

---

### `kevent_get_filter(): Int` *(std/ffi/event.qz:190)*

---

### `kevent_get_flags(): Int` *(std/ffi/event.qz:196)*

---

### `kevent_get_data(): Int` *(std/ffi/event.qz:204)*

---

### `timespec_set(): Int` *(std/ffi/event.qz:239)*

---

## FFI Functions

### `fcntl(fd: CInt, cmd: CInt): CInt` *(std/ffi/event.qz:17)*

### `kqueue(): CInt` *(std/ffi/event.qz:57)*

### `kevent(kq: CInt, changelist: CPtr, nchanges: CInt, eventlist: CPtr, nevents: CInt, timeout: CPtr): CInt` *(std/ffi/event.qz:60)*

### `epoll_create1(flags: CInt): CInt` *(std/ffi/event.qz:88)*

### `epoll_ctl(epfd: CInt, op: CInt, fd: CInt, event: CPtr): CInt` *(std/ffi/event.qz:89)*

### `epoll_wait(epfd: CInt, events: CPtr, maxevents: CInt, timeout: CInt): CInt` *(std/ffi/event.qz:90)*

