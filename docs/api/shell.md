# shell

## Structs

### `ShellResult` *(std/shell.qz:60)*

Run a shell command and capture both stdout and exit code.
Returns a ShellResult struct.

| Field | Type |
|-------|------|
| `stdout` | `String` |
| `exit_code` | `Int` |

## Functions

### `shell_capture(): String` *(std/shell.qz:23)*

# Shell — Command Execution Utilities

Execute shell commands and capture their output from Quartz programs.

## Usage

  ```qz
  import * from shell

  var output = shell_capture("ls -la")
  var code = shell_exit("gcc --version > /dev/null 2>&1")
  var ok = shell_ok("which qemu-system-aarch64")
  ```

@since Quartz 5.15.0
Run a shell command and capture its stdout as a String.
Returns the full stdout output. Newlines are preserved.

Example:
  var files = shell_capture("ls *.qz")
  var version = shell_capture("quartz --version")

---

### `shell_exit(): Int` *(std/shell.qz:40)*

Run a shell command and return its exit code.
Unlike system(), this returns the properly decoded exit code (0-255).

---

### `shell_ok(): Int` *(std/shell.qz:54)*

Check if a shell command succeeds (exit code 0).
Useful for probing tool availability:
  if shell_ok("which qemu-system-aarch64")
    # QEMU is available
  end

---

### `shell_run(): ShellResult` *(std/shell.qz:65)*

---

