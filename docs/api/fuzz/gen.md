# fuzz/gen

## Structs

### `FuzzConfig` *(std/fuzz/gen.qz:17)*

| Field | Type |
|-------|------|
| `max_depth` | `Int` |
| `max_funcs` | `Int` |
| `max_stmts` | `Int` |
| `max_params` | `Int` |

### `FuzzEnv` *(std/fuzz/gen.qz:37)*

| Field | Type |
|-------|------|
| `depth` | `Int` |
| `var_count` | `Int` |
| `func_count` | `Int` |
| `sb` | `Int` |
| `config` | `FuzzConfig` |
| `local_vars` | `Vec<String>` |
| `func_arities` | `Vec<Int>` |

## Functions

### `fuzz_config_default(): FuzzConfig` *(std/fuzz/gen.qz:24)*

---

### `fuzz_env_new(): FuzzEnv` *(std/fuzz/gen.qz:49)*

Track defined helper functions: arities

---

### `_fz_emit(): Void` *(std/fuzz/gen.qz:65)*

---

### `_fz_emit_indent(): Void` *(std/fuzz/gen.qz:69)*

---

### `_fz_emit_line(): Void` *(std/fuzz/gen.qz:75)*

---

### `_fz_fresh_var(): String` *(std/fuzz/gen.qz:85)*

---

### `_fz_fresh_var_deferred(): String` *(std/fuzz/gen.qz:95)*

Like _fz_fresh_var but does NOT add to local_vars yet.
Use when the variable should not be referenceable in its own init expr.

---

### `_fz_fresh_func(): String` *(std/fuzz/gen.qz:101)*

---

### `_fz_has_vars(): Int` *(std/fuzz/gen.qz:107)*

---

### `_fz_random_var(): String` *(std/fuzz/gen.qz:111)*

---

### `_fz_gen_int_literal(): Void` *(std/fuzz/gen.qz:122)*

---

### `_fz_gen_string_literal(): Void` *(std/fuzz/gen.qz:126)*

---

### `_fz_gen_bool_literal(): Void` *(std/fuzz/gen.qz:137)*

---

### `_fz_gen_expr(): Void` *(std/fuzz/gen.qz:145)*

---

### `_fz_gen_stmt(): Void` *(std/fuzz/gen.qz:244)*

---

### `_fz_gen_helper_func(): Void` *(std/fuzz/gen.qz:359)*

Fallback: var declaration (deferred to avoid self-reference)

---

### `fuzz_generate(): String` *(std/fuzz/gen.qz:399)*

Restore previous scope

---

