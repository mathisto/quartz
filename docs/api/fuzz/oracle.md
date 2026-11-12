# fuzz/oracle

## Structs

### `FuzzResult` *(std/fuzz/oracle.qz:43)*

| Field | Type |
|-------|------|
| `ok` | `Int` |
| `level` | `String` |
| `message` | `String` |

## Functions

### `fuzz_oracle_init(): Void` *(std/fuzz/oracle.qz:24)*

---

### `_fuzz_next_id(): Int` *(std/fuzz/oracle.qz:33)*

---

### `fuzz_result_ok(): FuzzResult` *(std/fuzz/oracle.qz:49)*

Human-readable result

---

### `fuzz_result_fail(): FuzzResult` *(std/fuzz/oracle.qz:53)*

---

### `fuzz_check_crash(): FuzzResult` *(std/fuzz/oracle.qz:63)*

Compile a program and check for crashes (signals or exit code > 1).
Exit code 1 = normal compile error (OK). Signal = compiler bug.

---

### `fuzz_check_determinism(): FuzzResult` *(std/fuzz/oracle.qz:95)*

Compile the same program twice and check that IR output is identical.

---

### `fuzz_check_ir_valid(): FuzzResult` *(std/fuzz/oracle.qz:136)*

Run LLVM opt -verify on compiled IR to check for codegen bugs.

---

### `fuzz_check_differential(): FuzzResult` *(std/fuzz/oracle.qz:176)*

Compile with current and alternate compiler, compare behavior.

---

### `fuzz_shrink(): String` *(std/fuzz/oracle.qz:230)*

Attempt to minimize a crashing program by removing lines.
Returns the smallest source that still triggers the same crash.

---

