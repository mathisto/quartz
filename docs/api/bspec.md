# bspec

## Structs

### `TestFailure` *(std/bspec.qz:30)*

| Field | Type |
|-------|------|
| `expected` | `String` |
| `actual` | `String` |
| `message` | `String` |

### `TestResult` *(std/bspec.qz:36)*

| Field | Type |
|-------|------|
| `name` | `String` |
| `status` | `TestStatus` |
| `failure` | `Int` |
| `duration_ms` | `Int` |

### `TestCase` *(std/bspec.qz:47)*

| Field | Type |
|-------|------|
| `name` | `String` |
| `test_fn` | `Int` |
| `is_focused` | `Int` |
| `is_skipped` | `Int` |

### `TestSuite` *(std/bspec.qz:57)*

| Field | Type |
|-------|------|
| `name` | `String` |
| `tests` | `Int` |
| `suites` | `Int` |
| `setup_fn` | `Int` |
| `teardown_fn` | `Int` |

### `BSpecContext` *(std/bspec.qz:84)*

| Field | Type |
|-------|------|
| `root_suite` | `Int` |
| `current_suite` | `Int` |
| `results` | `Int` |
| `output_mode` | `Int` |
| `total` | `Int` |
| `passed` | `Int` |
| `failed` | `Int` |
| `pending` | `Int` |
| `skipped` | `Int` |

### `Expectation` *(std/bspec.qz:311)*

| Field | Type |
|-------|------|
| `actual` | `Int` |
| `actual_str` | `String` |

## Enums

### `TestStatus` *(std/bspec.qz:23)*

| Variant | Payload |
|---------|----------|
| `Passed` | — |
| `Failed` | — |
| `Pending` | — |
| `Skipped` | — |

## Functions

### `bspec_new(): Int` *(std/bspec.qz:96)*

---

### `bspec_get_root(): Int` *(std/bspec.qz:119)*

---

### `bspec_set_root(): Void` *(std/bspec.qz:123)*

---

### `bspec_get_current(): Int` *(std/bspec.qz:127)*

---

### `bspec_set_current(): Void` *(std/bspec.qz:131)*

---

### `bspec_get_results(): Int` *(std/bspec.qz:135)*

---

### `bspec_get_output_mode(): Int` *(std/bspec.qz:139)*

---

### `bspec_inc_total(): Void` *(std/bspec.qz:143)*

---

### `bspec_inc_passed(): Void` *(std/bspec.qz:148)*

---

### `bspec_inc_failed(): Void` *(std/bspec.qz:153)*

---

### `suite_new(): Int` *(std/bspec.qz:162)*

---

### `suite_get_name(): String` *(std/bspec.qz:172)*

---

### `suite_get_tests(): Int` *(std/bspec.qz:176)*

---

### `suite_get_children(): Int` *(std/bspec.qz:180)*

---

### `suite_add_test(): Void` *(std/bspec.qz:184)*

---

### `suite_add_child(): Void` *(std/bspec.qz:189)*

---

### `test_new(): Int` *(std/bspec.qz:198)*

---

### `test_get_name(): String` *(std/bspec.qz:207)*

---

### `test_get_fn(): Int` *(std/bspec.qz:211)*

---

### `test_is_focused(): Int` *(std/bspec.qz:215)*

---

### `test_is_skipped(): Int` *(std/bspec.qz:219)*

---

### `describe(): Void` *(std/bspec.qz:250)*

---

### `it(): Void` *(std/bspec.qz:273)*

---

### `it_pending(): Void` *(std/bspec.qz:288)*

---

### `expect(): Expectation` *(std/bspec.qz:316)*

---

### `expect_str(): Expectation` *(std/bspec.qz:320)*

---

### `to_eq(): Int` *(std/bspec.qz:329)*

---

### `to_eq_str(): Int` *(std/bspec.qz:337)*

---

### `to_be_true(): Int` *(std/bspec.qz:348)*

---

### `to_be_false(): Int` *(std/bspec.qz:356)*

---

### `run_suite(): Void` *(std/bspec.qz:368)*

---

### `run_test(): Void` *(std/bspec.qz:398)*

---

### `print_indent(): Void` *(std/bspec.qz:424)*

---

### `bspec_inc_pending(): Void` *(std/bspec.qz:432)*

---

### `bspec_run(): Int` *(std/bspec.qz:441)*

---

