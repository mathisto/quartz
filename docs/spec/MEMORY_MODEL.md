# Quartz Memory Model

> **Version**: v5.25.0-alpha  
> **Status**: DRAFT — Formal ownership and memory specification  
> **Audience**: Compiler implementers and language specification readers

---

## 1. Runtime Representation

### 1.1 The i64 Universal Type

All Quartz values are represented as `i64` at runtime. There is no runtime type information.

| Source Type | Runtime Representation |
|------------|----------------------|
| `Int` | `i64` direct value |
| `Bool` | `i64` (0 = false, nonzero = true) |
| `String` | `i64` pointer to heap-allocated string |
| `struct S` | `i64` pointer to heap-allocated fields |
| `enum E` | `i64` pointer to heap-allocated tag + payload |
| `Vec<T>` | `i64` pointer to vector handle |
| `Fn(...): R` | `i64` function pointer or tagged closure pointer |
| `CPtr` | `i64` raw pointer value |
| `Void` | `i64` (value is 0, ignored) |

### 1.2 Struct Layout

Standard structs are heap-allocated. Each field occupies 8 bytes (i64):

```
struct S { f₁: T₁, ..., fₙ: Tₙ }

Heap layout:
  [ptr + 0×8]: f₁ (i64)
  [ptr + 1×8]: f₂ (i64)
  ...
  [ptr + (n-1)×8]: fₙ (i64)

Total allocation: n × 8 bytes via malloc()
```

### 1.3 @value Structs

Structs annotated with `@value` use stack allocation and are passed by value:

```
@value struct Point { x: Int, y: Int }

Stack layout: 2 × i64 contiguous on stack (no malloc)
```

### 1.4 @repr(C) Structs

Structs annotated with `@repr(C)` follow C ABI layout rules:
- Fields use their natural C sizes (`CInt` = 4 bytes, `CChar` = 1 byte)
- Alignment padding is inserted per C ABI rules
- `@packed` suppresses padding

### 1.5 Enum Layout

```
enum E { V₁(p₁: T₁), V₂, V₃(p₂: T₂, p₃: T₃) }

Heap layout:
  [ptr + 0]: tag (i64, variant index: V₁=0, V₂=1, V₃=2)
  [ptr + 8]: payload field 1 (if present)
  [ptr + 16]: payload field 2 (if present)
  ...
```

---

## 2. Value Categories

### 2.1 Owned Values

Every value has exactly one owner — the variable or expression it is bound to. Owned values are destroyed when their owner goes out of scope (unless moved).

```
var x = S { f: 42 }    -- x owns the struct
                         -- struct is freed when x goes out of scope
```

### 2.2 Borrowed Values (Shared Reference)

A shared borrow `&x` creates a read-only alias. Multiple shared borrows may coexist.

```
var x = 42
var r = &x              -- r is a shared borrow of x
var s = &x              -- s is also a shared borrow of x (OK)
```

### 2.3 Borrowed Values (Exclusive Reference)

An exclusive borrow `&mut x` creates a read-write alias. Only one exclusive borrow may exist at a time, and it conflicts with all shared borrows.

```
var x = 42
var r = &mut x          -- r is an exclusive borrow of x
```

---

## 3. Ownership Rules

### 3.1 Move Semantics

For types that implement `Drop`, passing the value to a function or assigning it to another variable **transfers ownership** (move). The original binding becomes invalid.

```
Γ ⊢ x: T    T: Drop    Γ ⊢ f(x) ⇓ v
─────────────────────────────────────────
Γ ⊢ x is MOVED after f(x)              [MOVE]
```

**After a move, using the original variable is a compile error (QZ1212).**

### 3.2 Copy Trait

Types implementing `Copy` are duplicated rather than moved:

```
Γ ⊢ x: T    T: Copy    Γ ⊢ f(x) ⇓ v
─────────────────────────────────────────
Γ ⊢ x is still valid after f(x)        [COPY]
```

**Invariant: A type cannot implement both `Copy` and `Drop` (QZ1215).**

### 3.3 Move in Loops

Moving a value inside a loop body is **rejected** unless the value is re-initialized before the next iteration:

```
-- REJECTED (QZ1212): move without reinit
while cond
  consume(x)            -- x moved
end                     -- next iteration: x is invalid

-- ACCEPTED: move with reinit
while cond
  consume(x)            -- x moved
  x = new_value()       -- x re-initialized
end
```

### 3.4 Partial Moves

Moving a field of a struct partially invalidates the struct:

```
consume(p.x)            -- p.x moved (partial move)
use(p)                  -- ERROR (QZ1216): p is partially moved
```

### 3.5 Re-initialization After Move

A moved variable can be re-initialized:

```
var x = Res { n: 1 }
consume(x)              -- x is moved
x = Res { n: 2 }        -- x is re-initialized (valid)
consume(x)              -- OK
```

---

## 4. Borrowing Rules

### 4.1 The Five Rules

These are the complete set of borrow rules. They are checked at compile time.

| # | Rule | Error Code |
|---|------|------------|
| 1 | Multiple `&` on same variable: allowed | — |
| 2 | Multiple `&mut` on same variable: rejected | QZ1205 |
| 3 | `&` and `&mut` on same variable: rejected | QZ1206 |
| 4 | Cannot mutate while borrowed (`=`, `+=`, etc.) | QZ1209 |
| 5 | `&mut` requires `var` binding | QZ1208 |

### 4.2 Borrow Lifetimes (NLL-lite)

Borrows have non-lexical lifetimes. A borrow expires at its **last use**, not at scope exit:

```
var x = 42
var r = &x              -- borrow starts
var y = r + 1           -- last use of r → borrow expires
x = 99                  -- OK: borrow has expired
```

If the borrow is used after a conflicting operation, it remains live:

```
var x = 42
var r = &x              -- borrow starts
x = 99                  -- ERROR (QZ1209): r still live (used below)
var y = r + 1           -- r used after mutation
```

### 4.3 Ephemeral Borrows

Borrows passed directly as function arguments are **ephemeral** — they are released when the call returns:

```
def peek(r: &Int): Int = 0
var x = 42
peek(&x)                -- borrow created, then released
var p = &mut x          -- OK: no outstanding borrow
```

### 4.4 Reassignment Releases Borrows

Reassigning a variable that holds a borrow releases the old borrow:

```
var x = 42
var p = &x              -- p borrows x (shared)
p = 0                   -- p reassigned → borrow on x released
var q = &mut x          -- OK: x is no longer borrowed
```

### 4.5 Borrows Cannot Escape

| Escape | Error | Code |
|--------|-------|------|
| Return borrow of local | Dangling reference | QZ1210 |
| Store borrow in struct field | Struct may outlive source | QZ1211 |

---

## 5. Drop Semantics

### 5.1 Automatic Drop

When a value implementing `Drop` goes out of scope, its `drop` method is called automatically. This is the **only** automatic destructor mechanism.

```
Γ ⊢ var x: T = v    T: Drop
x goes out of scope
─────────────────────────
call T$drop(x)                              [DROP]
```

### 5.2 Drop Order

Values are dropped in **reverse declaration order** within a scope (LIFO):

```
def f()
  var a = Res { ... }   -- dropped 3rd (last)
  var b = Res { ... }   -- dropped 2nd
  var c = Res { ... }   -- dropped 1st (first)
end
```

### 5.3 Drop and Moves

Moved values are **not** dropped. The compiler tracks which values have been moved and skips their drop:

```
var x = Res { ... }
consume(x)              -- x moved → no drop for x
```

### 5.4 Drop Glue

Structs containing fields that implement `Drop` get **implicit drop glue** generated by the compiler, even if the struct itself doesn't implement `Drop`:

```
struct Context
  alloc: Arena          -- Arena implements Drop
  name: String
end
-- compiler generates drop glue that calls Arena$drop on ctx.alloc
```

### 5.5 Defer and Drop Interaction

`defer` expressions run **before** automatic drops at scope exit:

```
sequence on scope exit:
  1. All defer expressions (LIFO order)
  2. All drops (LIFO order, excluding moved values)
```

---

## 6. Memory Allocation Strategies

### 6.1 Default: malloc/free

Standard structs and enums use `malloc` for allocation. The `Drop` trait automates `free` at scope exit.

### 6.2 Arenas

Arena allocators provide bulk allocation with single-point deallocation:

```
arena scratch do
  p = @scratch Point { x: 1, y: 2 }  -- allocated from arena
end                                     -- entire arena freed
```

Arena-allocated values are **not** individually freed. The entire arena is destroyed at scope exit.

### 6.3 @heap Placement

`@heap` explicitly allocates on the heap:

```
arr = @heap [1, 2, 3]              -- heap-allocated array
p = @heap Point { x: 10, y: 20 }   -- heap-allocated struct
```

### 6.4 Vec Storage Model

Vec uses width-aware storage for narrow types:

| Element Type | Storage Width | Memory |
|-------------|--------------|--------|
| `Int`, `String`, ... | 8 bytes | Standard |
| `U8`, `I8` | 1 byte | Narrow |
| `I16`, `U16` | 2 bytes | Narrow |
| `I32`, `U32`, `F32` | 4 bytes | Narrow |

---

## 7. Concurrency Model

### 7.1 Thread Safety

Quartz provides thread-level concurrency via `spawn` / `thread_join`. There is no implicit sharing — data must be explicitly passed to threads.

### 7.2 Atomics

Atomic operations follow the LLVM memory model:

| Ordering | Constant | Semantics |
|----------|----------|-----------|
| Relaxed | 0 | No ordering guarantee |
| Acquire | 2 | Reads-from synchronizes |
| Release | 3 | Synchronizes-with reads |
| AcqRel | 4 | Both acquire and release |
| SeqCst | 5 | Total order (default) |

### 7.3 Volatile Access

`volatile_load<T>` and `volatile_store<T>` prevent compiler reordering and elimination. Used for memory-mapped I/O and hardware registers.

---

## 8. Error Code Reference

| Code | Error | Category |
|------|-------|----------|
| QZ1205 | Cannot create exclusive borrow | Borrow |
| QZ1206 | Conflicting borrows (shared + exclusive) | Borrow |
| QZ1208 | Cannot &mut immutable binding | Borrow |
| QZ1209 | Cannot mutate while borrowed | Borrow |
| QZ1210 | Cannot return borrow of local | Borrow |
| QZ1211 | Cannot store borrow in struct field | Borrow |
| QZ1212 | Use of moved value | Move |
| QZ1215 | Copy + Drop conflict | Trait |
| QZ1216 | Use of partially moved value | Move |
