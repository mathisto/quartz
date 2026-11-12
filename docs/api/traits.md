# traits

Standard Traits Library (`std/traits.qz`)

Core traits for common operations. Traits can have **abstract** methods (bodyless — must be implemented)
and **default** methods (have a body — inherited if not overridden).

**Auto-satisfaction**: If a type's inherent `impl` already provides a method matching a trait requirement,
the trait is automatically satisfied. Empty impl blocks are idiomatic: `impl Container for Queue end`.

## Equality & Ordering

### `Eq`

Equality comparison. Method names match operator dispatch: `op_eq` enables `==`, `op_ne` enables `!=`.

```quartz
trait Eq
  def op_eq(self, other: Self): Bool   # abstract
  def op_ne(self, other: Self): Bool   # default: not op_eq(self, other)
end
```

**Implementations**: `impl Eq for String` (via `str_eq`), `impl Eq for Bytes` (element-wise).

### `Ord`

Ordering comparison. All defaults derived purely from `op_lt` — no Eq dependency.

```quartz
trait Ord
  def op_lt(self, other: Self): Bool   # abstract
  def op_le(self, other: Self): Bool   # default: not op_lt(other, self)
  def op_gt(self, other: Self): Bool   # default: op_lt(other, self)
  def op_ge(self, other: Self): Bool   # default: not op_lt(self, other)
end
```

## Arithmetic & Indexing

### `Add`, `Sub`, `Mul`, `Div`, `Mod`

Each trait has one abstract method matching operator dispatch.

```quartz
trait Add
  def op_add(self, other: Self): Self  # abstract — enables +
end
```

Same pattern for `Sub` (`op_sub`, `-`), `Mul` (`op_mul`, `*`), `Div` (`op_div`, `/`), `Mod` (`op_mod`, `%`).

### `Index`

Enables `obj[key]` via `op_index`.

```quartz
trait Index
  def op_index(self, key: Int): Int    # abstract
end
```

## Common Traits

### `Hash`

Hash code generation for use in hash maps.

```quartz
trait Hash
  def hash(self): Int                  # abstract
end
```

### `Show`

String representation. Has a sensible default.

```quartz
trait Show
  def show(self): String               # default: "<unknown>"
end
```

**Implementations**: `impl Show for JsonValue` (via `json_stringify`), `impl Show for TomlValue` (via `toml_stringify_value`).

### `Clone`

Value copying. Default returns self (works for small/primitive types).

```quartz
trait Clone
  def clone(self): Self                # default: self
end
```

### `Serializable`

JSON conversion.

```quartz
trait Serializable
  def to_json(self): Int               # abstract
end
```

**Implementations**: `impl Serializable for JsonValue`.

## Resource Management

### `Drop`

RAII cleanup. The compiler inserts `drop()` calls automatically at scope exit, return, break/continue, and `?` operator early return. Drop calls are in LIFO order.

```quartz
trait Drop
  def drop(self): Void                 # abstract
end
```

## Collections

### `Container`

Common interface for sized collections. `size` and `clear` are abstract; `is_empty` has a sensible default.

```quartz
trait Container
  def size(self): Int                  # abstract
  def is_empty(self): Bool             # default: self.size() == 0
  def clear(self): Void                # abstract
end
```

**Implementations**: Queue, Stack, Deque, LinkedList — all via auto-satisfaction from inherent impl methods.

### `Iterator<T>`

Core iteration protocol. Returns `Option::Some(value)` for each element, `Option::None` when exhausted.

```quartz
trait Iterator<T>
  def next(self): Option<T>            # default: Option::None
end
```

### `AsyncIterator<T>`

Async iteration protocol for `for await x in source`.

### `Iterable<T>`

Types that can produce an iterator via `iter()`.

## Deriving Traits

Use `@derive` to auto-generate trait implementations for structs:

```quartz
@derive(Eq, Hash, Show, Clone, Ord)
struct Point
  x: Int
  y: Int
end
```
