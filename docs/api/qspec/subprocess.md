# qspec/subprocess

## Structs

### `SubResult` *(std/qspec/subprocess.qz:94)*

| Field | Type |
|-------|------|
| `exit_code` | `Int` |
| `stdout_content` | `String` |
| `stderr_content` | `String` |

## Functions

### `_sub_init(): Void` *(std/qspec/subprocess.qz:35)*

---

### `_sub_next_id(): Int` *(std/qspec/subprocess.qz:55)*

---

### `_sub_tmp(): String` *(std/qspec/subprocess.qz:65)*

Generate PID-scoped temp file path: /tmp/_qspec_sub_PID_N.ext
Each spec binary gets its own PID, so parallel or overlapping runs
can never collide on temp files.

---

### `_sub_timeout_wrap(): String` *(std/qspec/subprocess.qz:81)*

Wrap a shell command with a timeout that kills after _sub_timeout_secs.
Prevents runaway scheduler programs from consuming all memory.

---

### `subprocess_compile(): SubResult` *(std/qspec/subprocess.qz:104)*

---

### `subprocess_run(): SubResult` *(std/qspec/subprocess.qz:164)*

---

### `assert_compile_fails(): Void` *(std/qspec/subprocess.qz:328)*

Assert that source code fails to compile

---

### `assert_compile_error(): Void` *(std/qspec/subprocess.qz:337)*

Assert that source code fails to compile with stderr containing expected pattern

---

### `assert_compile_succeeds(): Void` *(std/qspec/subprocess.qz:357)*

Assert that source code compiles successfully

---

### `assert_ir_contains(): Void` *(std/qspec/subprocess.qz:369)*

Assert that compiled IR contains a pattern

---

### `assert_ir_not_contains(): Void` *(std/qspec/subprocess.qz:389)*

Assert that compiled IR does NOT contain a pattern

---

### `assert_run_exits(): Void` *(std/qspec/subprocess.qz:409)*

Assert that program exits with specific exit code

---

### `assert_run_stderr_contains(): Void` *(std/qspec/subprocess.qz:430)*

Assert that program's stderr contains expected pattern

---

### `assert_run_panics(): Void` *(std/qspec/subprocess.qz:452)*

Assert that program panics (non-zero exit) and output contains message
Checks both stdout and stderr since panic output location varies by compiler

---

### `subprocess_compile_with_fixtures(): SubResult` *(std/qspec/subprocess.qz:481)*

Compile source with fixtures include path (for cross-module tests)

---

### `assert_compile_error_with_fixtures(): Void` *(std/qspec/subprocess.qz:543)*

Assert that source code fails to compile (with fixtures include path)

---

### `subprocess_compile_with_flags(): SubResult` *(std/qspec/subprocess.qz:561)*

Compile source with extra compiler flags

---

### `subprocess_run_with_flags(): SubResult` *(std/qspec/subprocess.qz:619)*

Run source with extra compiler flags

---

### `assert_ir_contains_with_flags(): Void` *(std/qspec/subprocess.qz:778)*

Assert that compiled IR contains a pattern (with extra flags)

---

### `assert_ir_not_contains_with_flags(): Void` *(std/qspec/subprocess.qz:798)*

Assert that compiled IR does NOT contain a pattern (with extra flags)

---

### `assert_run_panics_with_flags(): Void` *(std/qspec/subprocess.qz:818)*

Assert that program panics with extra compiler flags

---

### `assert_run_exits_with_flags(): Void` *(std/qspec/subprocess.qz:847)*

Assert that program exits with specific code with extra compiler flags

---

### `assert_run_stdout_eq(): Void` *(std/qspec/subprocess.qz:868)*

Assert that program's stdout equals expected string

---

### `subprocess_run_with_timeout(): SubResult` *(std/qspec/subprocess.qz:896)*

Run a compiled Quartz program with a timeout to prevent hangs.
If the program doesn't exit within _sub_timeout_secs, it is killed.
Returns SubResult with exit code 137 on timeout (SIGKILL).

---

### `assert_run_exits_timeout(): Void` *(std/qspec/subprocess.qz:1021)*

Assert that program exits with specific exit code (with timeout).

---

### `_sub_multi_dir(): String` *(std/qspec/subprocess.qz:1046)*

Create a temp directory path for multi-file compilation.

---

### `_sub_write_multi(): Vec` *(std/qspec/subprocess.qz:1057)*

Write multi-file sources to a temp directory.
files: Vec with alternating [filename, source] pairs.
main_idx: which pair (0-based) is the main file.
Returns: Vec of [dir_path, main_file_path] as int handles.

---

### `_sub_cleanup_multi(): Void` *(std/qspec/subprocess.qz:1094)*

Clean up multi-file temp directory.

---

### `subprocess_compile_multi(): SubResult` *(std/qspec/subprocess.qz:1128)*

Compile a multi-file project.
files: Vec with alternating [filename, source] pairs.
main_idx: which pair (0-based) is the main file to compile.
Returns SubResult with IR in stdout_content, errors in stderr_content.

---

### `subprocess_run_multi(): SubResult` *(std/qspec/subprocess.qz:1192)*

Compile and run a multi-file project.
files: Vec with alternating [filename, source] pairs.
main_idx: which pair (0-based) is the main file to compile.

---

### `assert_multi_compile_succeeds(): Void` *(std/qspec/subprocess.qz:1355)*

Assert multi-file project compiles successfully.

---

### `assert_multi_compile_error(): Void` *(std/qspec/subprocess.qz:1367)*

Assert multi-file project fails to compile with expected error.

---

### `assert_multi_run_exits(): Void` *(std/qspec/subprocess.qz:1385)*

Assert multi-file project runs and exits with expected code.

---

### `assert_multi_run_output(): Void` *(std/qspec/subprocess.qz:1406)*

Assert multi-file project runs and stdout matches expected.

---

### `assert_multi_ir_contains(): Void` *(std/qspec/subprocess.qz:1428)*

Assert multi-file project's IR contains a pattern.

---

### `assert_compile_warning(): Void` *(std/qspec/subprocess.qz:1449)*

Assert that source code compiles successfully BUT produces a warning on stderr
Unlike assert_compile_error, this checks for warnings that don't prevent compilation.

---

### `subprocess_lint(): SubResult` *(std/qspec/subprocess.qz:1474)*

========================================================================
Lint helpers
========================================================================
Run `quartz lint` on source, returning stdout+stderr as SubResult.

---

### `assert_lint_warns(): Void` *(std/qspec/subprocess.qz:1510)*

Assert that linting source produces a warning with the given code.

---

### `assert_lint_clean(): Void` *(std/qspec/subprocess.qz:1523)*

Assert that linting source produces no warnings.

---

## FFI Functions

### `getpid(): CInt` *(std/qspec/subprocess.qz:20)*

QSpec Subprocess Testing - Compile and run Quartz programs as subprocesses

Provides assertion functions for testing compiler errors, IR output,
panic behavior, and stderr output by invoking the compiler as a subprocess.

Requires environment variables:
  QUARTZ_COMPILER - path to the Quartz compiler binary
  QUARTZ_STD      - path to the std/ directory (for -I flag)
  QUARTZ_LLI      - path to lli (LLVM interpreter, for runtime tests)

Usage:
  import * from qspec/subprocess

  assert_compile_error(source, "error message")
  assert_ir_contains(source, "load volatile")
  assert_run_exits(source, 1)

