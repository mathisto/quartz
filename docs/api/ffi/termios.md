# ffi/termios

## Functions

### `TCSANOW(): Int` *(std/ffi/termios.qz:31)*

Apply changes immediately.

---

### `TERMIOS_SIZE(): Int` *(std/ffi/termios.qz:58)*

Size of struct termios.

---

### `TERMIOS_LFLAG_OFFSET(): Int` *(std/ffi/termios.qz:65)*

Byte offset of c_lflag field.

---

### `TERMIOS_LFLAG_WIDTH(): Int` *(std/ffi/termios.qz:72)*

Byte width of c_lflag field.

---

### `TERMIOS_CC_OFFSET(): Int` *(std/ffi/termios.qz:79)*

Byte offset of c_cc array.

---

### `ICANON(): Int` *(std/ffi/termios.qz:90)*

Canonical mode — line editing enabled.

---

### `ECHO(): Int` *(std/ffi/termios.qz:97)*

Echo input characters.

---

### `ISIG(): Int` *(std/ffi/termios.qz:104)*

Enable signal generation (Ctrl-C → SIGINT, etc).

---

### `IEXTEN(): Int` *(std/ffi/termios.qz:111)*

Implementation-defined input processing.

---

### `ICRNL(): Int` *(std/ffi/termios.qz:122)*

Translate CR to NL on input.

---

### `TERMIOS_IFLAG_OFFSET(): Int` *(std/ffi/termios.qz:128)*

Byte offset of c_iflag field (always 0).

---

### `TERMIOS_IFLAG_WIDTH(): Int` *(std/ffi/termios.qz:132)*

Byte width of c_iflag field.

---

### `VMIN(): Int` *(std/ffi/termios.qz:143)*

Index for VMIN (minimum characters for non-canonical read).

---

### `VTIME(): Int` *(std/ffi/termios.qz:150)*

Index for VTIME (timeout for non-canonical read, in 1/10 sec).

---

### `TIOCGWINSZ(): Int` *(std/ffi/termios.qz:161)*

ioctl request code for getting terminal window size.

---

## FFI Functions

### `tcgetattr(fd: CInt, termios_p: CPtr): CInt` *(std/ffi/termios.qz:13)*

Terminal I/O control — POSIX termios FFI bindings.

Provides raw terminal access for line editing, syntax highlighting,
and interactive REPL functionality.

@since 5.13.0
Get terminal attributes.

### `tcsetattr(fd: CInt, actions: CInt, termios_p: CPtr): CInt` *(std/ffi/termios.qz:17)*

Set terminal attributes.
@param actions TCSANOW (0) for immediate, TCSADRAIN (1) after output, TCSAFLUSH (2) after flush.

### `isatty(fd: CInt): CInt` *(std/ffi/termios.qz:21)*

Check if file descriptor refers to a terminal.
Returns 1 if terminal, 0 otherwise.

### `ioctl(fd: CInt, request: CInt): CInt` *(std/ffi/termios.qz:24)*

File descriptor control.

