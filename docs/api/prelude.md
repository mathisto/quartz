# prelude

## Enums

### `Option<<T>>` *(std/prelude.qz:23)*

| Variant | Payload |
|---------|----------|
| `Some` | — |
| `None` | — |

#### Methods

##### `unwrap(): T`

##### `unwrap_or(): T`

##### `is_some(): Bool`

##### `is_none(): Bool`

### `Result<<T, E>>` *(std/prelude.qz:74)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

#### Methods

##### `unwrap(): T`

##### `unwrap_err(): E`

##### `is_ok(): Bool`

##### `is_err(): Bool`

## Functions

### `is_some(): Bool` *(std/prelude.qz:29)*

---

### `is_none(): Bool` *(std/prelude.qz:37)*

---

### `unwrap(): T` *(std/prelude.qz:46)*

---

### `unwrap_or(): T` *(std/prelude.qz:54)*

---

### `is_ok(): Bool` *(std/prelude.qz:80)*

---

### `is_err(): Bool` *(std/prelude.qz:88)*

---

### `unwrap_ok(): T` *(std/prelude.qz:97)*

---

### `unwrap_err(): E` *(std/prelude.qz:106)*

---

### `unwrap_or_ok(): T` *(std/prelude.qz:114)*

---

### `ok(): Option<T>` *(std/prelude.qz:122)*

---

### `err(): Option<E>` *(std/prelude.qz:130)*

---

### `result_map(): Result<U, E>` *(std/prelude.qz:142)*

---

### `result_map_err(): Result<T, F>` *(std/prelude.qz:150)*

---

### `result_and_then(): Result<U, E>` *(std/prelude.qz:158)*

---

### `result_or(): T` *(std/prelude.qz:166)*

---

### `option_map(): Option<U>` *(std/prelude.qz:178)*

---

### `option_and_then(): Option<U>` *(std/prelude.qz:186)*

---

### `option_or(): T` *(std/prelude.qz:194)*

---

