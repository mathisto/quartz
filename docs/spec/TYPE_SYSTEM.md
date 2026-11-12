# Quartz Type System — Formal Specification

> **Version**: 5.25.0  
> **Status**: Living document — tracks `typecheck.qz` implementation  
> **Source of truth**: `self-hosted/middle/typecheck.qz`

## 1. Type Universe

### 1.1 Primitive Types

| Type     | Size    | Description                     |
|----------|---------|---------------------------------|
| `Int`    | 64-bit  | Signed integer (default)        |
| `Bool`   | 1-bit   | Boolean (`true` / `false`)      |
| `String` | ptr     | Immutable UTF-8 string          |
| `Void`   | 0-bit   | Unit type (no value)            |
| `F64`    | 64-bit  | IEEE 754 double precision       |
| `F32`    | 32-bit  | IEEE 754 single precision       |
| `!`      | 0-bit   | Never type (diverging)          |

### 1.2 Sized Integer Types

| Type  | Size   | Range                      |
|-------|--------|----------------------------|
| `I8`  | 8-bit  | −128 to 127                |
| `I16` | 16-bit | −32,768 to 32,767          |
| `I32` | 32-bit | −2³¹ to 2³¹−1             |
| `U8`  | 8-bit  | 0 to 255                   |
| `U16` | 16-bit | 0 to 65,535                |
| `U32` | 32-bit | 0 to 2³²−1                |

### 1.3 Compound Types

| Type              | Description                                  |
|-------------------|----------------------------------------------|
| `Vec<T>`          | Growable array of elements of type `T`       |
| `Map<K, V>`       | Hash map from `K` keys to `V` values        |
| `Set<T>`          | Hash set of unique `T` elements              |
| `Option<T>`       | Optional: `Some(T)` or `None`                |
| `Result<T, E>`    | Fallible: `Ok(T)` or `Err(E)`               |
| `Channel<T>`      | CSP-style typed channel                       |
| `Ptr<T>`          | Raw pointer (unsafe)                          |
| `StringBuilder`   | Mutable string builder                        |

### 1.4 FFI Types (C Interop)

| Type      | C equivalent   | Size                |
|-----------|----------------|---------------------|
| `CInt`    | `int`          | 32-bit (platform)   |
| `CChar`   | `char`         | 8-bit               |
| `CPtr`    | `void*`        | pointer-sized        |
| `CSize`   | `size_t`       | pointer-sized        |
| `CFloat`  | `float`        | 32-bit               |
| `CDouble` | `double`       | 64-bit               |

### 1.5 Memory Management Types

| Type          | Description                                 |
|---------------|---------------------------------------------|
| `Arena`       | Region-based memory arena                   |
| `Pool<T>`     | Fixed-size object pool                      |
| `ArenaPool`   | Arena-backed pool                            |
| `Mutex<T>`    | Mutual exclusion lock                        |
| `Atomic<T>`   | Atomic value (lock-free)                     |

---

## 2. Type Construction

### 2.1 Struct Types

A struct declaration creates a new nominal type with named fields:

```
struct Point
  x: Int
  y: Int
end
```

**Typing rule**:
```
Γ ⊢ struct S { f₁: T₁, ..., fₙ: Tₙ }
────────────────────────────────────────
Γ, S : Type  ⊢  S.fᵢ : Tᵢ  for each i
```

Struct types are **nominal** — two structs with identical fields are distinct types.

### 2.2 Enum Types

An enum declaration creates a sum type with named variants:

```
enum Shape
  Circle(F64)
  Rectangle(F64, F64)
  Point
end
```

**Typing rule**:
```
Γ ⊢ enum E { V₁(T₁₁,...), ..., Vₙ(Tₙ₁,...) }
───────────────────────────────────────────────
Γ ⊢ E::Vᵢ(e₁,...,eₖ) : E   when eⱼ : Tᵢⱼ
```

### 2.3 Type Aliases

```
type Callback = Fn(Int): Void
```

Type aliases are transparent — `Callback` and `Fn(Int): Void` are interchangeable.

### 2.4 Newtypes

```
newtype UserId = Int
```

Newtypes are **opaque** — `UserId` and `Int` are distinct types that cannot be used interchangeably without explicit conversion.

---

## 3. Generic Types

### 3.1 Parametric Polymorphism

Functions and structs can be parameterized over types:

```
def identity<T>(x: T): T = x

struct Pair<A, B>
  first: A
  second: B
end
```

**Typing rule** (generic function):
```
Γ, T : Type ⊢ body : U
──────────────────────────
Γ ⊢ def f<T>(x: T): U : ∀T. T → U
```

### 3.2 Monomorphization

Generic types are monomorphized at compile time. Each unique instantiation `T<Int>`, `T<String>`, etc., generates a distinct function/struct in the output IR.

### 3.3 Trait Bounds

Type parameters can be constrained with trait bounds:

```
def sort<T>(items: Vec<T>): Vec<T> where T: Ord
```

**Typing rule**:
```
Γ ⊢ T : Ord, Γ ⊢ items : Vec<T>
──────────────────────────────────
Γ ⊢ sort(items) : Vec<T>
```

---

## 4. Union and Intersection Types

### 4.1 Union Types

A union type `A | B` accepts values of either type:

```
def handle(x: Int | String): Void
```

**Typing rules**:
```
Γ ⊢ e : A         Γ ⊢ e : B
──────────────    ──────────────
Γ ⊢ e : A | B    Γ ⊢ e : A | B
```

Union types are narrowed via `match` or type guards.

### 4.2 Intersection Types

An intersection type `A & B` requires a value to satisfy both types:

```
def compare<T>(a: T, b: T): Int where T: Eq & Ord
```

**Typing rule**:
```
Γ ⊢ e : A & B
──────────────    ──────────────
Γ ⊢ e : A        Γ ⊢ e : B
```

### 4.3 Structural Record Types

Record types can be combined with union/intersection operators:

```
type Named = { name: String }
type Aged  = { age: Int }
type Person = Named & Aged    # has both name and age
```

---

## 5. Function Types

### 5.1 Function Declarations

```
def add(a: Int, b: Int): Int = a + b
```

**Typing rule**:
```
Γ, a: Int, b: Int ⊢ a + b : Int
────────────────────────────────
Γ ⊢ add : Fn(Int, Int): Int
```

### 5.2 Lambda Expressions

Arrow lambdas with optional type annotations:

```
x -> x * 2                    # inferred types
(x: Int) -> x * 2             # explicit param type
(x: Int, y: Int) -> x + y     # multi-param
```

Block lambdas using `do/end`:

```
do -> 42 end                   # nullary
do x -> x * 2 end             # single param
```

### 5.3 UFCS (Uniform Function Call Syntax)

Methods defined via `extend` blocks are available as dot-notation calls:

```
extend String
  def shout(self: String): String
    return str_to_upper(self)
  end
end

"hello".shout()   # desugars to: shout("hello")
```

### 5.4 Closures

Lambdas capture variables from enclosing scope. Captured variables are passed as an implicit environment pointer.

---

## 6. Type Inference

### 6.1 Bidirectional Type Checking

The type checker uses bidirectional type checking:

1. **Synthesis** (↑): Infer the type of an expression from its structure
2. **Checking** (↓): Check that an expression has an expected type

```
(synthesis)     Γ ⊢ 42 ↑ Int
(checking)      Γ ⊢ x : Int  ⊢ x ↓ Int
(let-binding)   Γ ⊢ e ↑ T,  Γ, x: T ⊢ body ↑ U
                ──────────────────────────────────
                Γ ⊢ let x = e; body ↑ U
```

### 6.2 Variable Declarations

- `let x = e` — immutable binding, type inferred from `e`
- `var x = e` — mutable binding, type inferred from `e`
- `let x: T = e` — immutable with explicit type annotation
- `var x: T = e` — mutable with explicit type annotation

### 6.3 Return Type Inference

Function return types can be explicit or inferred:
- Explicit: `def f(): Int = 42`
- Expression body: type of the expression
- Block body: type of the last expression, or `Void` for statement-only bodies

---

## 7. Subtyping Relations

### 7.1 Structural Subtyping

Record types use structural subtyping — a record with more fields is a subtype of a record with fewer:

```
{ name: String, age: Int }  <:  { name: String }
```

### 7.2 Never Type

The `!` (never) type is the bottom type — it is a subtype of every type:

```
!  <:  T    for all T
```

Functions that diverge (infinite loop, panic) have return type `!`.

### 7.3 Type Coercions

Implicit coercions exist between:
- Sized integers and `Int` (widening only)
- `CInt` ↔ `Int` (at FFI boundaries)
- `CPtr` ↔ `Ptr<T>` (at FFI boundaries)

---

## 8. Ownership and Borrowing

### 8.1 Ownership Rules

1. Every value has exactly one owner
2. When the owner goes out of scope, the value is dropped
3. Ownership can be transferred (moved) or shared (borrowed)

### 8.2 Borrow Types

- `&T` — shared (immutable) borrow
- `&mut T` — exclusive (mutable) borrow

**Borrow rules**:
- Multiple `&T` borrows may coexist
- At most one `&mut T` borrow may exist
- `&T` and `&mut T` may not coexist

### 8.3 Lifetime Inference

Borrows have implicit lifetimes. The compiler infers that:
- A borrow must not outlive the borrowed value
- A function returning `&T` derives its lifetime from parameters

### 8.4 Drop Trait (RAII)

Types implementing the `Drop` trait have their `drop` method called automatically when they go out of scope:

```
impl Drop for FileHandle
  def drop(self: FileHandle): Void
    close_fd(self.fd)
  end
end
```

---

## 9. Trait System

### 9.1 Trait Declarations

Traits define interfaces with optional default implementations:

```
trait Printable
  def to_string(self: Self): String
end
```

### 9.2 Implementations

Traits are implemented for specific types:

```
impl Printable for Point
  def to_string(self: Point): String
    return format2("{}, {}", self.x.to_s(), self.y.to_s())
  end
end
```

### 9.3 Trait Coherence

- Each `(Trait, Type)` pair can have at most one implementation
- Implementations must be in the same module as either the trait or the type

### 9.4 Where Clauses

Complex bounds are expressed via `where` clauses:

```
def merge<A, B>(a: A, b: B): String
  where A: Printable, B: Printable + Eq
```

---

## 10. Pattern Matching

### 10.1 Exhaustiveness

`match` expressions must be exhaustive — all possible values must be covered:

```
match shape
  Shape::Circle(r) => pi * r * r
  Shape::Rectangle(w, h) => w * h
  Shape::Point => 0.0
end
```

### 10.2 Pattern Types

| Pattern            | Description                 |
|--------------------|-----------------------------|
| `_`                | Wildcard (matches anything) |
| `x`               | Variable binding            |
| `42`, `"hello"`    | Literal match               |
| `true`, `false`    | Boolean literal             |
| `nil`              | Nil literal                 |
| `E::V(p₁, p₂)`   | Enum variant destructure    |
| `p if guard`       | Guarded pattern             |
| `p₁ \| p₂`        | Or-pattern                  |

### 10.3 Typing Rule

```
Γ ⊢ e : T
Γ, bindings(pᵢ, T) ⊢ bodyᵢ : U   for each arm i
exhaustive(p₁, ..., pₙ, T)
───────────────────────────────────
Γ ⊢ match e { p₁ => body₁, ..., pₙ => bodyₙ } : U
```

---

## 11. Concurrency Types

### 11.1 Channels (CSP)

Typed channels for goroutine-style communication:

```
var ch = channel_new<Int>()
spawn do ->
  channel_send(ch, 42)
end
var val = channel_recv(ch)
```

### 11.2 Spawn

`spawn expr` creates a lightweight thread (mapped to OS threads via the runtime):

```
spawn do ->
  heavy_computation()
end
```

### 11.3 Select

Non-deterministic channel selection:

```
select
  when val = channel_recv(ch1)
    handle(val)
  when val = channel_recv(ch2)
    handle(val)
  default
    idle()
end
```

---

## 12. Memory Management

### 12.1 Arena Allocation

Block-scoped region allocator:

```
arena
  var buf = alloc<Buffer>(1024)
  process(buf)
  # buf freed when arena exits
end
```

### 12.2 Pool Allocation

Fixed-size object pool for high-frequency allocation:

```
var pool = pool_new<Node>(1000)
var n = pool_alloc(pool)
```

### 12.3 Bump Allocation

Arena provides bump allocation — O(1) alloc, bulk free on scope exit.

---

## 13. Error Handling

### 13.1 Result Type

Functions that can fail return `Result<T, E>`:

```
def parse_int(s: String): Result<Int, String>
```

### 13.2 Try-Catch

Structured error handling:

```
try
  var val = risky_operation()
  use(val)
catch err
  handle_error(err)
end
```

### 13.3 Error Propagation

The `$try` macro propagates errors:

```
def process(): Result<Int, String>
  var x = $try(parse_int("42"))
  return Ok(x * 2)
end
```
