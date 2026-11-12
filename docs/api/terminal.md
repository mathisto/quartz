# terminal

## Functions

### `KEY_UP(): Int` *(std/terminal.qz:16)*

Special key codes (above byte range to avoid collisions).

---

### `KEY_DOWN(): Int` *(std/terminal.qz:17)*

---

### `KEY_RIGHT(): Int` *(std/terminal.qz:18)*

---

### `KEY_LEFT(): Int` *(std/terminal.qz:19)*

---

### `KEY_HOME(): Int` *(std/terminal.qz:20)*

---

### `KEY_END(): Int` *(std/terminal.qz:21)*

---

### `KEY_DELETE(): Int` *(std/terminal.qz:22)*

---

### `KEY_BACKSPACE(): Int` *(std/terminal.qz:23)*

---

### `KEY_ENTER(): Int` *(std/terminal.qz:24)*

---

### `KEY_TAB(): Int` *(std/terminal.qz:25)*

---

### `KEY_EOF(): Int` *(std/terminal.qz:26)*

---

### `KEY_CTRL_A(): Int` *(std/terminal.qz:29)*

---

### `KEY_CTRL_B(): Int` *(std/terminal.qz:30)*

---

### `KEY_CTRL_C(): Int` *(std/terminal.qz:31)*

---

### `KEY_CTRL_D(): Int` *(std/terminal.qz:32)*

---

### `KEY_CTRL_E(): Int` *(std/terminal.qz:33)*

---

### `KEY_CTRL_F(): Int` *(std/terminal.qz:34)*

---

### `KEY_CTRL_K(): Int` *(std/terminal.qz:35)*

---

### `KEY_CTRL_L(): Int` *(std/terminal.qz:36)*

---

### `KEY_CTRL_N(): Int` *(std/terminal.qz:37)*

---

### `KEY_CTRL_P(): Int` *(std/terminal.qz:38)*

---

### `KEY_CTRL_U(): Int` *(std/terminal.qz:39)*

---

### `KEY_CTRL_W(): Int` *(std/terminal.qz:40)*

---

### `term_is_tty(): Bool` *(std/terminal.qz:53)*

Check if stdin is a terminal.

---

### `term_enter_raw_mode(): Int` *(std/terminal.qz:59)*

Enter raw terminal mode.
Disables canonical mode, echo, and signal processing.
Sets VMIN=1, VTIME=0 for single-character reads.
Returns 1 on success, 0 on failure.

---

### `term_exit_raw_mode(): Void` *(std/terminal.qz:106)*

Exit raw terminal mode, restoring original settings.

---

### `term_read_byte(): Int` *(std/terminal.qz:121)*

Read a single byte from stdin. Returns byte value, or -1 on EOF/error.

---

### `term_read_key(): Int` *(std/terminal.qz:135)*

Read a single keystroke, decoding escape sequences.
Returns a key constant (KEY_UP, etc.) or a byte value for regular chars.

---

### `term_get_width(): Int` *(std/terminal.qz:220)*

Get terminal width in columns.
Returns 80 as fallback if ioctl fails.

---

### `term_get_height(): Int` *(std/terminal.qz:241)*

Get terminal height in rows.
Returns 24 as fallback if ioctl fails.

---

### `term_write(): Void` *(std/terminal.qz:264)*

Write a string directly to stdout (fd 1) without buffering.

---

### `term_bell(): Void` *(std/terminal.qz:273)*

Ring the terminal bell.

---

### `_term_read_field(): Int` *(std/terminal.qz:281)*

---

### `_term_write_field(): Void` *(std/terminal.qz:302)*

---

