# qspec/formatter

## Functions

### `_init_format(): Void` *(std/qspec/formatter.qz:27)*

QSpec Formatter - Beautiful CLI output

Three output modes:
  Pretty (default) — Indented tree with ✓/✗ and timing
  Progress          — Live progress bar with ✓✗ stream
  Dots              — Minimal .F* output for CI

Usage:
  import qspec/formatter

  qspec_format_pretty(suites)
  qspec_format_summary()

---

### `format_set_pretty(): Void` *(std/qspec/formatter.qz:33)*

---

### `format_set_progress(): Void` *(std/qspec/formatter.qz:38)*

---

### `format_set_dots(): Void` *(std/qspec/formatter.qz:43)*

---

### `format_mode(): Int` *(std/qspec/formatter.qz:48)*

---

### `_indent(): String` *(std/qspec/formatter.qz:60)*

---

### `_format_duration(): String` *(std/qspec/formatter.qz:74)*

---

### `_format_test_pretty(): Void` *(std/qspec/formatter.qz:96)*

---

### `_format_suite_pretty(): Void` *(std/qspec/formatter.qz:120)*

---

### `qspec_format_pretty(): Void` *(std/qspec/formatter.qz:142)*

Format all suites in pretty mode

---

### `_format_test_dot(): Void` *(std/qspec/formatter.qz:156)*

---

### `_format_suite_dots(): Void` *(std/qspec/formatter.qz:175)*

---

### `qspec_format_dots(): Void` *(std/qspec/formatter.qz:192)*

Format all suites in dots mode

---

### `_count_tests_in_suite(): Int` *(std/qspec/formatter.qz:208)*

---

### `qspec_format_progress(): Void` *(std/qspec/formatter.qz:220)*

Format in progress mode with running bar

---

### `qspec_format_summary(): Void` *(std/qspec/formatter.qz:253)*

Print the test summary with failures

---

### `qspec_format(): Void` *(std/qspec/formatter.qz:328)*

Run the appropriate formatter based on mode, then print summary

---

