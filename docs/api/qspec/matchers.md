# qspec/matchers

## Structs

### `Expectation` *(std/qspec/matchers.qz:65)*

| Field | Type |
|-------|------|
| `actual_int` | `Int` |
| `actual_str` | `String` |
| `negated` | `Int` |
| `kind` | `Int` |

## Functions

### `_init_matchers(): Void` *(std/qspec/matchers.qz:23)*

QSpec Matchers - Assertion library

Provides the `expect` function and matcher methods for fluent assertions.
Both `expect(x).to_eq(y)` style and `assert_eq(x, y)` shorthand supported.

Usage:
  import qspec/matchers

  expect(42).to_eq(42)
  expect(true).to_be_true()
  assert_eq(1 + 1, 2)

---

### `matcher_assertion_count(): Int` *(std/qspec/matchers.qz:29)*

---

### `matcher_failure_count(): Int` *(std/qspec/matchers.qz:34)*

---

### `matcher_get_failure(): String` *(std/qspec/matchers.qz:38)*

---

### `matcher_clear(): Void` *(std/qspec/matchers.qz:42)*

---

### `_inc_assertions(): Void` *(std/qspec/matchers.qz:51)*

---

### `_record_failure(): Void` *(std/qspec/matchers.qz:57)*

---

### `expect(): Expectation` *(std/qspec/matchers.qz:76)*

---

### `expect_str(): Expectation` *(std/qspec/matchers.qz:85)*

---

### `expect_bool(): Expectation` *(std/qspec/matchers.qz:94)*

---

### `negate(): Expectation` *(std/qspec/matchers.qz:113)*

---

### `_fail_expectation(): Void` *(std/qspec/matchers.qz:130)*

---

### `to_eq(): Void` *(std/qspec/matchers.qz:149)*

Expects actual to equal expected (by value)

---

### `to_eq_str(): Void` *(std/qspec/matchers.qz:161)*

Expects actual string to equal expected string

---

### `to_be_gt(): Void` *(std/qspec/matchers.qz:174)*

Expects actual to be greater than expected

---

### `to_be_lt(): Void` *(std/qspec/matchers.qz:186)*

Expects actual to be less than expected

---

### `to_be_gte(): Void` *(std/qspec/matchers.qz:198)*

Expects actual to be greater than or equal to expected

---

### `to_be_lte(): Void` *(std/qspec/matchers.qz:210)*

Expects actual to be less than or equal to expected

---

### `to_be_true(): Void` *(std/qspec/matchers.qz:222)*

Expects actual to be truthy (non-zero / true)

---

### `to_be_false(): Void` *(std/qspec/matchers.qz:234)*

Expects actual to be falsy (zero / false)

---

### `qspec_assert(): Void` *(std/qspec/matchers.qz:250)*

Assert boolean condition is true

---

### `assert_eq(): Void` *(std/qspec/matchers.qz:258)*

Assert two integers are equal

---

### `assert_eq_str(): Void` *(std/qspec/matchers.qz:271)*

Assert two strings are equal

---

### `assert_ne(): Void` *(std/qspec/matchers.qz:284)*

Assert two integers are NOT equal

---

### `assert_gt(): Void` *(std/qspec/matchers.qz:295)*

Assert actual > expected

---

### `assert_lt(): Void` *(std/qspec/matchers.qz:308)*

Assert actual < expected

---

### `assert_output(): Void` *(std/qspec/matchers.qz:321)*

Assert that a closure's stdout output equals expected string

---

### `assert_output_contains(): Void` *(std/qspec/matchers.qz:337)*

Assert that a closure's stdout output contains expected substring

---

