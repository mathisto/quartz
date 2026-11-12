# Quartz Language Reference

> **Authority:** This is the sole detailed reference for currently executable
> Quartz syntax and behavior. Read root [`ref.md`](../ref.md) first for the compact
> authority map and current stabilization caveats.
> **Version:** `5.12.21-alpha` (per [`VERSION`](../VERSION)). Validation counts and
> current defects live in [`STATUS.md`](../STATUS.md), not in this reference.

## The 4 Big Rules

1. **Const by Default**: `x = 5` is immutable. Use `var x = 5` for mutable.
2. **Explicit Types**: Parameters and returns require annotations. Locals infer.
3. **Typed Mixed Representation**: Representation is type-directed; legitimate
   scalars and handles coexist with native floats, pointers, value aggregates,
   COW buffers, unions, records, and niches. Some erased one-word transport paths
   remain known stabilization defects.
4. **Self-Hosted**: The self-hosted compiler is the current implementation and
   LLVM is authoritative. The retired C bootstrap is not the normal toolchain.

> [!WARNING]
> Quartz does not yet implement the ratified lexical `unsafe` boundary. Raw
> pointers, unchecked indexing/memory access, representation casts, and inline
> assembly are not consistently fenced, and known safe-looking programs can
> still fault. This reference describes executable behavior, not a present
> memory-safety guarantee. Target semantics are in
> [`STABILIZATION_INVARIANTS.md`](design/STABILIZATION_INVARIANTS.md).

---

## Newline Significance

Newlines are **statement terminators** (like semicolons in C). No explicit terminator character needed.

### Rules

1. **Newlines end statements** — each line is one statement
2. **Only `{}` suppress newlines unconditionally** — `()` and `[]` do not make
   arbitrary newlines insignificant, but a comma continues an argument or
   element list onto the next line
3. **Keyword blocks span lines** — `if/end`, `def/end`, `struct/end`, etc. enclose multiple newline-separated statements (newlines ARE significant inside — they separate statements)
4. **Trailing operator continues** — a binary operator at end of line allows continuation (exception: range `..`/`...` does NOT continue across lines)
5. **Leading dot continues across lines** — `obj\n  .method()` is a chain; use for multi-line method chaining
6. **No line continuation character** — no backslash; use trailing operators or leading dot to continue across lines

### Examples

```quartz
# Newline terminates the statement
x = 5
y = 10

# Multi-line argument/element lists — OK because each continued line follows a comma
result = foo(
  a,
  b,
  c
)

items = [
  1, 2, 3,
  4, 5, 6
]

p = Point {
  x: 10,
  y: 20
}

# Trailing operator continues to next line — OK
total = a +
  b +
  c

config = Config.new() |>
           set_name("app") |>
           build()

# Leading dot continues to next line — method chaining
result = data
  .parse()
  .validate()
  .save()

# Leading operator does NOT continue (except dot and ?.)
total = a
  - b    # This is TWO statements: `a` then `-b` (unary minus)
```

### Blank Lines

Blank lines between statements are fine — treated as multiple newlines, all skipped.

---

## Identifiers

```
[a-zA-Z_][a-zA-Z0-9_$]*[?!]?
```

- Start with letter or underscore
- Body: letters, digits, underscores, `$`
- In the current lexer, identifiers may end with a single `?` or `!`

### Predicate and Mutating Method Names

```quartz
# Predicates (return Bool)
v.empty?        # Collection is empty
opt.some?       # Option contains a value
opt.none?       # Option is None
res.ok?         # Result is Ok
res.err?        # Result is Err
c.digit?        # Char is 0-9
c.alpha?        # Char is letter
c.alnum?        # Char is alphanumeric
c.whitespace?   # Char is whitespace
ptr.nil?        # Pointer is nil
```

Used as an `if` condition, the presence/variant predicates (`some?`, `none?`, `ok?`,
`err?`) also **narrow** the subject — inside the branch the binding reads as its inner
payload type with no unwrap. See [Flow-Narrowing](#flow-narrowing-smart-casts).

Mutation is signaled by verb pair, not a `!` suffix: `v.sort()` mutates
in place and returns `Void`; `v.sorted()` returns a new sorted Vec. See
[`docs/COLLECTIONS_STYLE.md`](COLLECTIONS_STYLE.md) for the full naming
table.

### `try` prefix keyword (Try-Unwrap)

```quartz
val = try map.get("key")      # Early return None if missing, unwrap if present
data = try json_parse(text)   # Early return Err if invalid, unwrap Ok
$unwrap(expr)                 # Panic on None/Err (not early return)
```

`try expr` is the canonical try-unwrap form — a prefix keyword, parsed
directly, no macro. It replaced the old `$try(expr)` macro in Piezo
Milestone A (`86e0f906`); the old form now emits `QZ0503` with a
migration hint.

The result type of `try e` is the payload type `T` of `e`'s
`Result<T, E>` / `Option<T>` — so `var v = try json_parse(s)` binds
`v : JsonValue`, and struct/method/field access on `v` typechecks
against the real payload type. (When `e`'s type carries no recorded type
arguments — a genuinely erased bare `Result`/`Option` — the result falls
back to the scalar sentinel.)

Postfix `?` was deliberately removed during the April 2026 Piezo work because the lexer
reserves trailing `?` for predicate methods (`.some?`, `.none?`,
`.empty?`, `.ok?`); the two cannot coexist without semantic-information
ambiguity at the predicate-method call site.

### Auto-Coercion in `puts`

```quartz
puts(42)                    # Prints "42" — auto-calls to_str()
puts(3.14)                  # Prints "3.14"
puts("hello")               # Prints "hello" — no coercion needed
```

---

## Variables

```quartz
x = 5                    # Immutable (const), inferred type
x: Int = 5               # Immutable (const), explicit type
var y = 10               # Mutable, inferred type
var y: Int = 10          # Mutable, explicit type
y = 20                   # OK
x = 10                   # ERROR: immutable
```

### Compile-Time Constants

```quartz
const MAX_SIZE = 1024          # Compile-time constant (evaluated at compile time)
const MASK = MAX_SIZE - 1      # Can reference other consts
const FLAG = 1 + 2 * 3         # Arithmetic, comparison, logical ops supported

# Const functions — evaluated at compile time when called in const context
const def square(n: Int): Int = n * n
const def abs(n: Int): Int
  if n < 0
    return 0 - n
  end
  return n
end
const AREA = square(8)         # Evaluated at compile time → 64

static_assert(MAX_SIZE > 0, "MAX_SIZE must be positive")
static_assert(FLAG == 7, "FLAG should be 7")
static_assert(square(4) == 16, "square must work")
```

- Integer/bool `const`s are folded at compile time by `mir_const_eval`
- String and float `const`s (which can't be folded to an integer) are lowered as module globals initialized at module load — the same mechanism a module-level `var` uses; their *values* are still constant, they just aren't compile-time integer literals
- Supports: int/float/bool/string literals, arithmetic (`+`,`-`,`*`,`/`,`%`), comparison (`==`,`!=`,`<`,`>`,`<=`,`>=`), logical (`and`,`or`,`not`), bitwise (`&`,`|`,`^`,`~`,`<<`,`>>`), unary negation, references to other consts
- `const def` declares a compile-time function — can use `if`/`elsif`/`else`, `return`, local variables, and call other const functions
- Const functions also remain callable at runtime (dual-use)
- Max call depth: 32 (prevents infinite recursion)
- `static_assert(cond, "msg")` aborts compilation if `cond` evaluates to 0/false

### Compound Assignment

```quartz
x += 1                   # x = x + 1
x -= 5                   # x = x - 5
x *= 2                   # x = x * 2
x /= 4                   # x = x / 4
x %= 3                   # x = x % 3

# Current String += behavior
var s = "hello"
s += " world"            # s = str_concat(s, " world")
```

### Nil

```quartz
x = nil                  # Absence of value (typed as Nil)
if x == nil              # Compare with nil
  puts("x is nil")
end

# nil is falsy in conditionals
if x                     # Does not execute (nil is falsy)
  puts("not nil")
end
```

**Note**: `nil` has type `Nil` and is represented as `i64 0` at runtime (same as `false`).

> [!IMPORTANT]
> **`nil` is not a typed value (QZ0213, B.15).** A `nil` *literal* may not flow into a heap/reference-typed slot — `String`,
> a struct/enum, `Vec`, `Map`, `Set`, `Option`, a closure, etc. — at any of the three coercion positions: a `var`/`const`
> binding, a `return`, or a **call argument** (`f(nil)` into a boxed parameter). Use `Option<T>` and `None` to express absence:
> ```quartz
> def find(id: Int): Option<Widget>   # not `: Widget` with `return nil`
>   if id == 0
>     return None                      # ✓   (return nil → QZ0213 error)
>   end
>   return Some(lookup(id))
> end
> ```
> `nil` stays legal for the integer `0` (scalar slots) and for `CPtr` (the C-NULL FFI sentinel); at an FFI boundary, bridge a
> nullable pointer into an `Option` with `cptr_to_option(p)` from `std/ffi/ptr`. *(Currently the check keys off the syntactic
> `nil` literal; a bare `0` into a boxed slot is still accepted pending the N3 de-existentialization that makes the full wall
> possible.)*

### Global Variable Attributes

```quartz
@thread_local
var g_counter = 0                  # Thread-local storage (one copy per thread)
```

---

## Numeric Literals

```quartz
42                         # Decimal integer
1_000_000                  # Underscores for readability (ignored)
0xFF                       # Hexadecimal (0x or 0X prefix)
0xFF_FF                    # Hex with underscores
0b1010                     # Binary (0b or 0B prefix)
0b1111_0000                # Binary with underscores
0o755                      # Octal (0o or 0O prefix)
0o777                      # Octal file permissions
3.14                       # Float literal (Float64)
```

**Integer type suffixes** narrow the storage width:

```quartz
val = 255_u8               # U8 (unsigned 8-bit)
val = 1024_u16             # U16 (unsigned 16-bit)
val = 70000_u32            # U32 (unsigned 32-bit)
```

**Conversion intrinsics:**

```quartz
to_u8(n)                   # Int -> U8 (truncates)
to_u16(n)                  # Int -> U16 (truncates)
to_u32(n)                  # Int -> U32 (truncates)
```

## Character Literals

```quartz
'a'                        # 97 (ASCII code of 'a')
'A'                        # 65
'0'                        # 48
'\n'                       # 10 (newline)
'\t'                       # 9  (tab)
'\r'                       # 13 (carriage return)
'\\'                       # 92 (backslash)
'\''                       # 39 (single quote)
'"'                        # 34 (double quote)
' '                        # 32 (space)
```

Character literals compile to their integer codepoint value. They are syntactic sugar for the corresponding ASCII integer. Use them instead of magic numbers in character-processing code:

```quartz
if ch >= 'a' and ch <= 'z'    # Readable character range check
  # ...
end
```

## Negative Indexing

```quartz
var v = [10, 20, 30, 40, 50]
v[-1]                      # 50 (last element)
v[-2]                      # 40 (second to last)
v[-5]                      # 10 (first element)
v[-1] = 99                 # Assigns to last element
```

Negative literal indices are rewritten to `v[v.size + i]` at compile time. Only literal negative indices are supported (not runtime negative values).

---

## Functions

### Block Form

```quartz
def add(a: Int, b: Int): Int
  return a + b
end
```

### Endless Def (single expression)

```quartz
def double(x: Int): Int = x * 2
def is_empty(s: String): Bool = s.size == 0
```

### Default Arguments

```quartz
def greet(name: String = "World"): Void
  puts("Hello, " + name)
end

greet()         # "Hello, World"
greet("Be")     # "Hello, Be"
```

### Named Arguments

Call functions with `name: value` syntax to reorder arguments or skip middle defaults.
Positional arguments must come before named arguments. Names vanish after type checking (zero runtime cost).

```quartz
def connect(host: String, port: Int = 443, ssl: Bool = true): Void

connect("localhost")                       # all positional
connect("localhost", port: 8080)           # mixed positional + named
connect("localhost", ssl: false)           # skip middle default (port)
connect(port: 8080, host: "localhost")     # fully named, reordered
```

Named arguments work with any user-defined function. Not supported for builtins or lambda calls.

### Multi-Clause Function Definitions

Define functions by cases using repeated `def` with patterns in parameter position. Clauses must be contiguous and have the same arity. The compiler merges them into a single function with internal match dispatch (zero runtime overhead beyond the match itself).

```quartz
# Integer literal patterns
def factorial(0): Int = 1
def factorial(n: Int): Int = n * factorial(n - 1)

# Multiple clauses (3+)
def fib(0): Int = 0
def fib(1): Int = 1
def fib(n: Int): Int = fib(n - 1) + fib(n - 2)

# Bool literal patterns
def describe(true): String = "yes"
def describe(false): String = "no"

# Wildcard catch-all
def to_str(_): String = "anything"

# Multi-param — each position can independently be a pattern or regular param
def add(0, m: Int): Int = m
def add(n: Int, 0): Int = n
def add(n: Int, m: Int): Int = n + m

# Block form works too
def block_form(0): Int
  return 42
end
def block_form(n: Int): Int
  return n * 2
end
```

**Guards** use `when` after the return type to add boolean conditions:

```quartz
def classify(n: Int): String when n < 0 = "negative"
def classify(n: Int): String when n == 0 = "zero"
def classify(n: Int): String = "positive"

# Complex guard expressions
def range_label(n: Int): String when n >= 0 and n < 100 = "in range"
def range_label(n: Int): String = "out of range"
```

**Supported patterns in parameter position:**
- Integer literals: `0`, `1`, `42`
- Bool literals: `true`, `false`
- String literals: `"hello"`
- Wildcard: `_`
- Named params: `n: Int` (matches anything, binds `n`)

**Restrictions (v1):**
- Cannot mix with default parameters, named arguments, variadic params, or generics
- Enum variant patterns (e.g., `Some(v)`) only supported at position 0
- Not supported inside `impl` blocks
- No exhaustiveness checking — unmatched input panics at runtime with `FunctionClauseError`

### First-Class Functions

```quartz
def double(x: Int): Int = x * 2
def apply(f: Fn(Int): Int, x: Int): Int = f(x)

apply(double, 21)    # Returns 42
```

### Generator Functions

Any function that contains `yield` is a generator. Generators must declare `impl Iterator<T>` as their return type. They compile to stackless state machines — the constructor allocates a state struct, and a synthesized `$next` method resumes execution from where the last `yield` left off.

```quartz
import traits

# Basic generator — yields three values
def three_values(): impl Iterator<Int>
  yield 1
  yield 2
  yield 3
end

# Consumed via for-in (seamless integration)
for x in three_values()
  puts(x.to_s())
end

# Infinite generator — must break to terminate
def fibonacci(): impl Iterator<Int>
  var a = 0
  var b = 1
  while true
    yield a
    var temp = a
    a = b
    b = temp + b
  end
end

# Parameterized generators
def range_gen(start: Int, stop: Int): impl Iterator<Int>
  var i = start
  while i < stop
    yield i
    i = i + 1
  end
end
```

**Key rules:**
- `yield` inside a function body makes it a generator — no special keyword needed
- Return type MUST be `impl Iterator<T>` (requires `import traits`)
- `return` in a generator = stop producing values (iterator exhausted)
- All local variables and parameters are captured in the state struct
- `yield` works inside `while`, `for`, `if/else` — any control flow
- Generators integrate with `for-in` loops automatically

**Not yet supported:** `yield from` (delegation), `send()` (bidirectional), generators in closures.

---

## Lambdas

Arrow syntax for inline functions:

```quartz
# Arrow syntax
double = x: Int -> x * 2         # Single expression, implicit return
add = x: Int, y: Int -> x + y   # Multiple params (typed)
add = (x, y) -> x + y           # Multiple params (parenthesized, untyped)
nullary = -> 42                  # No params
untyped = x -> x * 2            # Type inferred from context
```

### Multi-statement (rare)

```quartz
# Arrow with block body
process = n: Int -> {
  var result = n * 2
  result + 1
}
```

### Arrow Syntax Details

```quartz
# Inline arrow lambdas
-> 42                             # Nullary
x -> x * 2                       # Single param, untyped
x: Int -> x * 2                  # Single param, typed
x: Int, y: Int -> x + y         # Multi param, typed
(x, y) -> x + y                  # Multi param, parenthesized (untyped)
(x: Int, y: Int) -> x + y       # Multi param, parenthesized (typed)
() -> 42                          # Nullary, parenthesized

# Curly block with arrow params
list.each() { x -> puts("#{x}") }
list.map() { x: Int -> x * 2 }
run() { -> 42 }                  # Nullary curly block

# Do-end block with arrow params
list.map() do x ->
  x * 2
end
run() do ->
  42
end
combine(a, b) do x, y ->
  x + y
end
```

**Known limitation:** Typed arrow lambdas (`x: Int -> expr`) cannot appear
bare at statement level — `x: Int` is parsed as a variable declaration.
Use untyped (`x -> expr`) or block syntax at statement level.

**Multi-param inline:** Untyped multi-param lambdas (`x, y -> expr`) are ambiguous
with function argument separators when used inline. Use parenthesized form
(`(x, y) -> expr`) or block syntax (`{ x, y -> expr }`, `do x, y -> ... end`).

### Closures (v5.10+)

Lambdas capture variables from enclosing scope **by value** at creation time:

```quartz
def make_adder(n: Int): Fn(Int): Int
  return x -> x + n              # captures n (arrow)
end
add5 = make_adder(5)
add5(3)                          # => 8
```

**Nested closures** work — inner lambdas capture from any outer scope:

```quartz
x = 10
f = a: Int -> do
  g = b -> x + a + b            # captures x and a
  return g(1)
end
f(100)                           # => 111
```

**Key facts:**
- Capture by **value** (not reference) — mutations after capture don't affect closure
- Works with `map`, `reduce`, `each`, and any HOF accepting `Fn` type
- Closure type is compatible with `Fn(params): Return` annotations
- Runtime: tagged pointer (low bit = 1 means closure), struct holds fn_ptr + captures
- Nested closures: outer lambda automatically captures vars needed by inner lambdas

**Common mistake:** Expecting mutation to be visible inside closure:
```quartz
var x = 10
f = a: Int -> x + a             # captures x=10 by value
x = 99                           # does NOT affect f
f(1)                             # => 11, not 100
```

---

## Structs

```quartz
struct Point
  x: Int
  y: Int
end

p = Point { x: 10, y: 20 }     # Curly braces required
p.x                             # Field access

# Multi-line struct literals are fine (newlines ignored inside {})
big = MyStruct {
  field1: val1,
  field2: val2,
  field3: val3
}

# Struct update: copy fields from a base, override the rest
q = Point { ...p, x: 99 }       # x = 99, y = p.y
clone = Point { ...p }          # full clone
```

**Wrong:**
```quartz
# Point(x: 10, y: 20)          # NO parens — use curly braces
# Point { ...a, ...b }          # NO multiple spreads — at most one base
```

### Struct Update Syntax (`...base`)

`Struct { ...base, k: v, ... }` desugars to a full literal that copies every
field of `base` into the result, with explicit `k: v` entries taking
precedence. Equivalent to Rust's `..base`, OCaml's `{ r with ... }`.

```quartz
struct World
  hp: Int
  gold: Int
  floor: Int
  log: String
end

w = World { hp: 10, gold: 0, floor: 1, log: "" }
w2 = World { ...w, hp: 5, gold: w.gold + 10 }
# Equivalent to:
# w2 = World { hp: 5, gold: w.gold + 10, floor: w.floor, log: w.log }
```

Rules:
- At most one `...base` per literal — multiple spreads are ambiguous.
- `base` must have the same struct type as the literal's constructor.
- Unknown explicit fields still error as in any struct literal.
- Works on generic structs: `Box<Int> { ...box, value: 42 }`.

### Associated Functions

```quartz
def Point.origin(): Point = Point { x: 0, y: 0 }
def Point.distance(p: Point): Int = abs(p.x) + abs(p.y)

p = Point.origin()             # Type.method() call
d = Point.distance(p)
```

### `@derive` Attribute (v5.12+)

Automatically generate trait implementations for structs:

```quartz
@derive(Eq, Hash, Show, Clone, Ord)
struct Point
  x: Int
  y: Int
end

# Generated implementations:
# - Eq:    Point == Point (field-by-field equality)
# - Hash:  hash(Point) (combined field hashes)
# - Show:  to_s(Point) → "Point { x: 10, y: 20 }"
# - Clone: clone(Point) → deep copy
# - Ord:   cmp(Point, Point) → -1/0/1 (lexicographic)
```

**Available traits**: `Eq`, `Hash`, `Show`, `Clone`, `Ord`

**Mechanism**: Source string generation + re-parse at Phase 2.4 (after parsing,
before macro expansion). The `@derive` annotation is stored in the doc slot
with a `@derive:` prefix.

**Key Properties:**
- Multiple traits can be derived in a single `@derive(...)` call
- Works with any struct (including generic structs)
- Can coexist with `## doc comments` — uses prefixed doc slot to avoid collision
- 15 tests in `derive_spec.qz`

### `@value` Attribute

`@value` explicitly requests value semantics and value-layout eligibility.
Small eligible values can be inline/stack-backed and decomposed at call
boundaries; flat values larger than 16 bytes use copy-on-write buffers. Storage
and ABI representation remain type- and context-directed.

```quartz
@value
struct Point
  x: Int
  y: Int
end

var p = Point { x: 10, y: 20 }    # Value semantics; small layout is inline
var v = vec_new<Point>()
v.push(Point { x: 1, y: 2 })      # Stored inline in Vec memory
```

**Key properties:**
- Independent value semantics across binding/call/storage copy boundaries
- Parameters may be decomposed into registers at call boundaries
- Inline collection storage when the selected layout permits it
- Atomic-refcounted COW storage for eligible flat values larger than 16 bytes
- Use for small, frequently-allocated types (e.g., 2D/3D points, color values)

#### Value semantics (live as of 2026-06-15)

A value-layout struct is a **value type**: it is *copied*, not aliased, whenever it
crosses a binding boundary. Each name holds its own independent copy, so mutating
one never affects another. This is the C/Rust/Swift `struct` model. Eligible
plain structs now follow the same semantic rule; `@value` makes the request
explicit (see scope below).

A `@value` struct is **copied** at every one of these sites:

```quartz
@value
struct Point
  x: Int
  y: Int
end

def bump(q: Point): Int          # by-value param → callee gets a copy
  q.x = 999                       # mutates the copy only
  return q.x
end

var a = Point { x: 1, y: 2 }
var b = a                         # COPY (let-binding): b is independent of a
b.x = 100
# a.x is still 1, b.x is 100

var c = Point { x: 0, y: 0 }
c = a                             # COPY (reassignment): c is independent of a

bump(a)                           # COPY (call argument by value): a unchanged, a.x still 1

@value
struct Line
  start: Point
end
var outer = Line { start: a }     # COPY (struct field-init): outer.start is independent of a

var v = vec_new<Point>()
v.push(a)                         # COPY (collection insert): the element is independent of a

var m = map_new<String, Point>()
m.set("k", a)                     # COPY (map insert)
```

A `@value` struct **moves** (does NOT copy) on `return` — the dying local's
ownership transfers to the caller, so there is no wasted copy of the return value:

```quartz
def make(): Point
  var p = Point { x: 7, y: 8 }
  return p                        # MOVE: ownership transfers out, no copy
end
```

**Opt out of the copy with `&` / `&mut`.** A borrow passes a *reference* instead
of a copy, which is how you let a callee mutate the caller's struct in place:

```quartz
def grow(q: &mut Point): Void
  q.x = q.x + 1                   # mutates the caller's struct through the borrow
end

var p = Point { x: 1, y: 2 }
grow(&mut p)                      # no copy; p.x is now 2
inspect(&p)                       # shared read borrow; no copy
```

**Scope.** `@value` explicitly requests value layout, and eligible plain structs
also use value semantics because the default-struct gate is live. `@repr(C)`,
recursive, firewall-mixed, and other ineligible structs remain on excluded
layouts; `String`, `Vec`, `Map`, and `Set` remain reference-shared handles and
are not copied by these rules. A value-layout struct that *contains*
such a handle field copies only its own inline/scalar fields; the bit-copied handle
stays shared, so the copy and the original observe the same underlying `Vec`/`String`:

```quartz
@value
struct Bag
  tag: Int                       # inline scalar → copied
  items: Vec<Int>                # heap handle → bit-copied, still SHARED
end

var x = Bag { tag: 1, items: [10] }
var y = x                         # tag is copied; items handle is shared
y.tag = 2                         # x.tag still 1 (independent)
y.items.push(20)                  # x.items ALSO sees [10, 20] (shared handle)
```

If you need a deep, independent copy of the handle fields too, copy them
explicitly (e.g. `Vec` clone) — value semantics does not deep-copy reference types.

**QZ0221 — a value-layout struct cannot be erased through a conversion bridge.**
Passing an explicit `@value` or eligible plain value-layout struct through
`as_int`, `as_int_generic`, `as_string`,
`as_type`, or `as_vec` is a compile error. Erasing the struct to a machine word
would silently reinterpret its identity and reintroduce the indirection that value
types exist to eliminate. The reject is conservative.

```quartz
var p = Point { x: 1, y: 2 }
var n = as_int(p)                 # error QZ0221: cannot erase a value-layout struct
```

> **Implementation note (non-user-facing).** Flat value-layout structs larger
> than 16 bytes use an atomic-refcounted copy-on-write buffer; smaller values use
> inline/eager copies. Safety exclusions can retain boxed or eager layouts.

---

## Extend Blocks (LEO Phase 5+)

Add methods to a struct type using `extend Type ... end`. Methods receive an implicit `self` parameter.

### Basic Syntax

```quartz
struct Counter
  value: Int
end

extend Counter
  def increment(): Void
    self.value = self.value + 1
  end

  def get(): Int
    return self.value
  end
end

c = Counter { value: 0 }
c.increment()
c.get()                        # 1
```

### `@field` Shorthand

Inside extend blocks, `@field` is shorthand for `self.field` — works for both reads and writes:

```quartz
extend Counter
  def reset(): Void
    @value = 0                 # Same as: self.value = 0
  end

  def current(): Int
    return @value               # Same as: return self.value
  end
end
```

### Combining with Traits

```quartz
extend Counter with Eq
  def eq(self, other: Counter): Bool
    return @value == other.value
  end
end
```

**Key Properties:**
- `self` is always the first implicit parameter
- `@field` is pure syntactic sugar for `self.field`
- Multiple `extend` blocks for the same type are allowed
- `extend Type with Trait` registers trait implementations

---

## Tuples (LEO Phase 9+)

First-class tuple types for grouping values without defining a struct.

### Creation and Access

```quartz
pair = (10, 20)
pair.0                          # 10 (first element)
pair.1                          # 20 (second element)

triple = (1, "hello", true)
triple.0                        # 1
triple.1                        # "hello"
triple.2                        # true
```

### Type Annotations

```quartz
def divide(a: Int, b: Int): (Int, Int)
  return (a / b, a % b)
end

var (quotient, remainder) = divide(17, 5)
# quotient = 3, remainder = 2
```

### Tuple Destructuring

```quartz
var (x, y) = (10, 20)
# x = 10, y = 20

# In function returns
def min_max(a: Int, b: Int): (Int, Int)
  if a < b
    return (a, b)
  end
  return (b, a)
end

var (lo, hi) = min_max(42, 7)
# lo = 7, hi = 42
```

### Struct Destructuring

```quartz
struct Point
  x: Int
  y: Int
end

var p = Point { x: 10, y: 20 }
Point { x, y } = p                # x = 10, y = 20
var Point { x: a, y: b } = p      # Rename: a = 10, b = 20
var Point { x, .. } = p           # Partial: only bind x, ignore rest
```

### Vec Destructuring

```quartz
var v = [10, 20, 30, 40, 50]
var [a, b, ..rest] = v             # a = 10, b = 20, rest = [30, 40, 50]
var [first, ..] = v                # first = 10, ignore rest
```

**Key Properties:**
- Access tuple elements with `.0`, `.1`, `.2`, etc.
- Tuple destructuring: `var (x, y) = expr`
- Struct destructuring: `Point { x, y } = expr`
- Vec destructuring: `var [a, b, ..rest] = expr`
- Tuple types use parenthesized syntax: `(Int, String)`
- Tuples are value types (stored inline)

---

## Iterators (LEO Phase 7+)

Quartz has a formal iterator protocol for lazy, composable iteration.

### Iterator Trait

```quartz
# Defined in std/iter.qz
# An iterator must have a .next() method returning Option<Int>
struct VecIter
  _data: Vec<Int>
  _index: Int
end

extend VecIter with Iterator<Int>
  def next(self): Option<Int>
    if self._index >= self._data.size
      return Option::None
    end
    var val = self._data[self._index]
    self._index = self._index + 1
    return Option::Some(val)
  end
end
```

### For-In Integration

`for x in iterable` desugars to calling `.iter()` then looping on `.next()`:

```quartz
var v = [1, 2, 3]
for x in v
  puts("#{x}")
end
# Desugars to:
# var __iter = v.iter()
# while true
#   match __iter.next()
#     Some(x) => { puts("#{x}") }
#     None => break
#   end
# end
```

### Lazy Adapters

Adapters accept `Fn(): Option<Int>` (a "next function") and return new iterator structs:

```quartz
import iter

var v = [1, 2, 3, 4, 5]
var it = VecIter { _data: v, _index: 0 }

# iter_map — transform each element
var doubled = iter_map(-> it.next(), x -> x * 2)

# iter_filter — keep elements matching predicate
var evens = iter_filter(-> it.next(), x -> x % 2 == 0)

# iter_take — yield at most N elements
var first_3 = iter_take(-> it.next(), 3)

# iter_skip — skip first N elements
var rest = iter_skip(-> it.next(), 2)

# iter_take_while — yield while predicate holds
var small = iter_take_while(-> it.next(), x -> x < 4)
```

### Terminal Operations

```quartz
# iter_collect — gather all elements into a Vec<Int>
var result = iter_collect(-> it.next())

# iter_count — count elements
var n = iter_count(-> it.next())

# iter_sum — sum all elements
var total = iter_sum(-> it.next())

# iter_for_each — apply function to each element (eager)
iter_for_each(-> it.next(), x -> puts("#{x}"))

# iter_fold — accumulate with initial value
var sum = iter_fold(-> it.next(), 0, acc, x -> acc + x)

# iter_any — true if any element matches predicate
var has_big = iter_any(-> it.next(), x -> x > 100)

# iter_find — first element matching predicate, or None
var found = iter_find(-> it.next(), x -> x > 3)
```

### Built-in Iterators

| Iterator | Source | Description |
|----------|--------|-------------|
| `VecIter` | `Vec<Int>` | Iterates elements by index |
| `RangeIter` | `0..N` | Iterates integer range |
| `MapIter` | adapter | Transforms each element |
| `FilterIter` | adapter | Keeps matching elements |
| `TakeIter` | adapter | Yields at most N elements |
| `SkipIter` | adapter | Skips first N elements |
| `TakeWhileIter` | adapter | Yields while predicate holds |
| `ZipIter` | adapter | Pairs elements from two iterators |
| `EnumerateIter` | adapter | Yields (index, value) pairs |

---

## April 2026 Collection API Changes

Several collection methods now return `Option<T>` instead of sentinel values:

| Function | Earlier form | Current form |
|----------|---------------|---------------|
| `vec_pop(v)` | Raw value (undefined on empty) | `Option<T>` (`None` on empty) |
| `str_find(s, needle)` | `-1` if not found | `Option<Int>` (`None` if not found) |
| `map_get(m, key)` | `0` if not found | `Option<T>` (`None` if not found) |
| `vec_index_of(v, val)` | `-1` if not found | `Option<Int>` (`None` if not found) |

**Migration pattern:**
```quartz
# Earlier form:
var idx = str_find(s, "needle")
if idx >= 0
  # use idx
end

# Current form — match with unqualified variants:
match s.find("needle")
  Some(idx) => {
    # use idx
  }
  None => {}
end

# Or use unwrap_or for simple cases:
idx = s.find("needle").unwrap_or(-1)

# Or use `is` + pattern binding:
if Some(idx) = s.find("needle")
  # use idx
end
```

All stdlib collection `pop`/`peek` methods also return `Option<Int>`.

---

## Enums

### Simple

```quartz
enum Color
  Red
  Green
  Blue
end

c = Color::Red
```

### With Payloads

```quartz
enum Shape
  Circle(radius: Int)
  Rectangle(width: Int, height: Int)
  Point                              # No payload
end

shape = Shape::Circle(10)
match shape
  Shape::Circle(r) => area = r * r * 3
  Shape::Rectangle(w, h) => area = w * h
  Shape::Point => area = 0
end
```

### Generic Enums

```quartz
enum Option<T>
  Some(value: T)
  None
end

enum Result<T, E>
  Ok(value: T)
  Err(error: E)
end

opt = Option::Some(42)
res = Result::Ok(100)
```

### Option/Result UFCS Methods

Option and Result values support method-style calls via UFCS:

```quartz
# Option methods
opt = Option::Some(42)
opt.unwrap_or(0)               # 42 — unwrap with fallback
opt.is_some()                  # true
opt.is_none()                  # false
opt.map(x -> x * 2)           # Some(84) — transform inner value

# Result methods
res = Result::Ok(100)
res.is_ok()                    # true
res.is_err()                   # false

# Predicate-style (? suffix)
opt.some?                      # true
opt.none?                      # false
res.ok?                        # true
res.err?                       # false

# Combine with `is` keyword
return 0 if opt is None
return -1 if res is Err
```

**Choosing the right unwrap style:**

| Style | Use when |
|-------|----------|
| `if opt.some? ... end` (flow-narrowing) | Guard then use `opt` directly as the inner `T` — no unwrap (see [Flow-Narrowing](#flow-narrowing-smart-casts)) |
| `opt.unwrap_or(default)` | Simple fallback value |
| `opt ?? default` | Nil coalescing (same as unwrap_or for Option) |
| `match opt { Some(v) => ... }` | Need to handle both branches with logic |
| `if Some(v) = opt` | Single-arm destructure |
| `try opt` | Propagate None to caller (prefix keyword; `$try` retired) |
| `$unwrap(opt)` | Panic on None (only for invariants) |

**Note**: Generic enum type parameters use angle brackets `<T>`, not square brackets.

**Representation — `Option<T>` is zero-cost for boxed payloads.** When `T` is a heap-boxed type, `Option<T>`
is a single machine word with **no tag word and no extra heap box**: `None` is the null pointer `0` and `Some(p)` is the
pointer `p` itself (the boxed-pointer `None` niche — Rust's guaranteed `Option<Box<T>>` null-pointer optimization).
This covers non-`@value` user structs and the builtins **String, Vec, Map, Set, IntMap, Regex, Future, and
Function/closure**. Scalars (`Option<Int>`, `Option<Bool>`, narrow ints) and `Option<CPtr>` keep an explicit tag word
(every bit pattern — including `0` — is a valid value, so there is no spare niche). `Option<Bool>` and `Option<NonZero>`
are nonetheless tag-free via dedicated small niches. (Tuple and payload-bearing-enum payloads are tagged for now.)
This is why `Option<T>` can be the mandatory way to express absence at no runtime cost.

---

## Flow-Narrowing (Smart-Casts)

After a control-flow guard *proves* that an `Option` / `Result` / user-enum binding
holds a specific variant, the binding is usable **as the inner payload type** inside the
proven region — with no explicit `.unwrap()`, no `!`, and no re-bind. This is the
Ruby-like "just use it" with ML-grade safety: the compiler inserts the payload extract
at a point control flow has already proven safe, so a narrowed read can never hit a
`None`/`Err` trap.

```quartz
o: Option<Int> = option_some(42)
if o.some?
  # `o` reads as Int here — no unwrap needed
  use_int(o + 100)              # 142
end
# past `end`, `o` is Option<Int> again — narrowing does NOT leak
```

Narrowing is **purely additive**: it only ever removes required ceremony. A program that
typechecked before still typechecks; explicit `.unwrap()` / `!` on a narrowed value stays
valid (it collapses to the same single extract).

### What triggers narrowing

All of these spellings narrow, for `Option`, `Result`, and arbitrary user enums:

```quartz
if x is Some          # `is` keyword (Some / Ok / Err / any user variant)
if x is Ok
if x.some?            # predicate methods
if x.none?
if x.ok?
if x.err?
if x.is_some()        # UFCS predicate methods
if x.is_none()
if x.is_ok()
if x.is_err()
if Some(v) = x        # refutable bind — narrows `v` to T AND narrows `x` to Some
```

### then / else / guard-style

- **then-branch** narrowing applies to every form above.
- **else-branch** narrowing applies to **binary enums** (`Option`, `Result`, and any
  2-variant user enum): the `else` of `if x.some?` proves `None`, the `else` of `is Ok`
  proves `Err`, etc. Enums with **3 or more variants** narrow the then-branch only — the
  `else` could still be any of the remaining variants, so use an explicit `match` there.
- **guard-style early-exit**: when the then-branch *definitely diverges*
  (`return` / `break` / `continue` / `panic` / `throw`), the negated fact is injected
  into the enclosing scope for the statements *after* the `if`:

```quartz
if o.none?
  return
end
use_int(o)            # `o` is narrowed to Int from here to end of scope
```

### const vs var

- **`const` bindings narrow freely.** Since a const cannot be reassigned, the proof at
  the guard holds at every use in the region. (Quartz is const-by-default, so this is the
  overwhelmingly common case.)
- **`var` bindings narrow too, but the refinement is invalidated** as soon as the `var`
  is **reassigned** anywhere in the narrowed region, or **captured by a lambda** (a
  closure could reassign it or run re-entrantly). After invalidation, reading the binding
  as the inner type no longer typechecks — bind it with `if Some(v) = x` or unwrap
  explicitly instead.

```quartz
var o: Option<Int> = option_some(1)
if o.some?
  o = option_some(2)  # reassigned → narrowing dropped
  # `o` is Option<Int> again here, not Int
end
```

### and-chains

`if a.some? and b.some?` narrows **both** `a` and `b` in the then-branch (the facts from
each conjunct are unioned). The `else` of an and-chain narrows nothing — by De Morgan,
`not (a and b)` proves nothing about either operand individually.

### Round-tripping

A narrowed value that flows **whole** back into a wide `Option` / `Result` / enum slot —
returned, assigned, stored in a struct field, passed as a wide call argument, or consumed
by `try` — round-trips the wrapper correctly. You only see the inner `T` when you read the
narrowed binding directly; passing the binding along as the wide type still works.

### Limitations

- **Bare identifiers only.** Field paths (`a.b.opt.some?`), index expressions, and call
  results do **not** narrow — those can change between check and use with no syntactic
  signal. Bind a local first: `c = a.b.opt; if c.some? ... end`.
- **`Result<String, String>` (niche-multi) flow-narrowing reprojection is parked.** The
  underlying niche-multi `match`/`is` path now reads correctly (`mir_multi_niche_result_live()`
  returns 1; the three niche-Result cases in `flow_narrow_p3` were un-parked 2026-07-05). What
  remains parked is only the flow-*narrowing reprojection* layered on top — a separate item, no
  longer blocked on the match path.
- **`while`-condition narrowing works in the loop body.** `while (x.some?)` narrows `x` to the
  inner type inside the loop body, matching `if` / `elsif` / guard-style narrowing (pinned by
  `spec/qspec/flow_narrow_while_spec.qz`, 7/7 green).

---

## Type Aliases

Transparent type synonyms — purely compile-time sugar for readability.

### Basic Aliases

```quartz
type UserId = Int
type Name = String
type Flag = Bool

def get_user(id: UserId): String
  return "User #{id}"
end
```

### Function Type Aliases

```quartz
type IntTransform = Fn(Int): Int
type BinaryOp = Fn(Int, Int): Int
type Callback = Fn(Int): Void

def apply(f: IntTransform, x: Int): Int = f(x)
```

### Aliases in Struct Fields

```quartz
type UserId = Int
type UserName = String

struct User
  id: UserId
  name: UserName
end
```

### Chained Aliases

```quartz
type A = Int
type B = A
type C = B      # C is Int
```

**Key Properties:**
- **Transparent**: `UserId` and `Int` are fully interchangeable
- **Compile-time only**: No runtime overhead
- **Recursive check**: `type A = A` is an error

---

## Newtypes

Newtypes create distinct types with zero runtime cost. Unlike type aliases,
newtypes are **not** interchangeable with their wrapped type.

```quartz
newtype UserId = Int
newtype Meters = Int
newtype Seconds = Int

def get_user_id(): UserId = 42

def main(): Int
  var id = get_user_id()
  print(id)
  return 0
end
```

### Multiple Newtypes

```quartz
newtype Width = Int
newtype Height = Int
newtype Area = Int

def calculate_area(w: Width, h: Height): Area
  return w * h
end
```

### Newtype vs Type Alias

| Feature | Type Alias (`type`) | Newtype (`newtype`) |
|---------|---------------------|---------------------|
| Interchangeable | Yes | No |
| Runtime cost | Zero | Zero |
| Purpose | Readability | Type safety |

**Note**: Newtypes have **strict type enforcement** for the cases described here. `Vec<TestId>`
rejects `Int`, and cross-newtype assignment is a type error. Newtypes are **not**
transparent — they are distinct types that happen to have the same runtime
representation.

### `@strict` Newtypes (STRICT_NEWTYPES)

Adding the `@strict` attribute makes a newtype **opaque in both directions**:
implicit conversion to / from the wrapped type is rejected at every position
(let, function argument **either direction**, return, branch condition, match
scrutinee, array index, relational operators, bit-shift). Crossing the
boundary requires the explicit `as_type<T>(value)` cast — a single
audit-greppable callsite. This is the type-system primitive
`std/core/crypto/secret.qz`'s `Secret<T>` is built on; see the crypto stdlib
for the canonical use.

Generic strict newtypes bind their type parameter at the call site (explicit
`f<T>(...)` or via inference) — `@strict newtype Box<T> = T` admits the same
polymorphic wrap/unwrap surface a loose generic newtype would, with the
strictness gates layered on top.

```quartz
@strict
newtype Secret<T> = T

# The audit-greppable polymorphic wrap / unwrap boundary.
def secret_wrap<T>(t: T): Secret<T> = as_type<Secret<T>>(t)
def secret_unwrap<T>(s: Secret<T>): T = as_type<T>(s)

def takes_int(x: Int): Int = x + 1

def main(): Int
  s: Secret<Int> = secret_wrap(42)          # T inferred = Int

  # All of these are rejected at compile time:
  # bad1: Int = s                            # implicit unwrap at let
  # bad2: Int = takes_int(s)                 # arg-as-Int mismatch (strict ACTUAL)
  # bad3 = if s then 1 else 0 end            # branch on Secret
  # bad4 = (s == secret_wrap(0))             # relational
  # bad5 = 1 << s                            # shift by Secret
  # bad6 = vec_new<Int>()[s]                 # index by Secret
  # bad7 = takes_other(s)                    # Secret<String> param won't bind

  # The explicit boundary:
  v: Int = secret_unwrap(s)                  # ✓ permitted (T binds = Int)
  return v
end
```

| Position | Loose newtype | `@strict` newtype |
|----------|---------------|-------------------|
| `var x: NT = wrapped_val` | allowed (implicit construct) | rejected — use `as_type<NT>(v)` |
| `var v: T = nt_val` | allowed (implicit unwrap) | rejected — use `as_type<T>(s)` |
| `takes_t(nt_val)` (param is `T`) | allowed | rejected (asymmetric arg-as-T direction) |
| `takes_nt(wrapped_val)` (param is `NT`) | allowed | rejected (asymmetric arg-as-NT direction) |
| `def f(): NT return wrapped_val end` | allowed | rejected |
| `if nt_val` / `match nt_val` | allowed | **rejected** (control-flow leak) |
| `arr[nt_val]` | allowed | **rejected** (memory-access leak) |
| `nt_val == other` (any relational) | allowed | **rejected** — use `subtle::ct_eq_*` |
| `x << nt_val` / `x >> nt_val` | allowed | **rejected** (variable-shift leak) |
| `nt_val + nt_val` (same id) | allowed | **allowed** (arithmetic permitted) |
| Distinct newtype id mismatch | rejected | rejected |
| `Box<A>` vs `Box<B>` (same base, different inner) | allowed via i64-flow | **rejected** (strict inner-arg equality) |

Existing in-tree newtypes (`InternId`, `AstNodeId`, etc.) do **not** opt into
`@strict` — their behaviour is unchanged. `@strict` is for security-sensitive
wrappers where every bit-leak position must be a compile error.

### `@ct` Constant-Time Functions (NET.4 Layer 3)

`@ct` on a function definition marks it as a **constant-time region**. A MIR
taint pass (`self-hosted/middle/ct_taint.qz`) runs after MIR lowering and
rejects branches, array indices, comparisons, and variable shifts whose
operand is derived from a `Secret<T>`-typed parameter — including taint that
flows through `secret_unwrap`, since `secret_unwrap` is the boundary marker,
not a sanitizer, inside `@ct`.

```quartz
import * from std/core/crypto/secret

@ct
def ct_xor(a: Secret<Int>, b: Secret<Int>): Int
  # Pure arithmetic on unwrapped secrets — passes Layer 3.
  return secret_unwrap<Int>(a) ^ secret_unwrap<Int>(b)
end

@ct
def bad_branch(s: Secret<Int>): Int
  var n = secret_unwrap<Int>(s)
  if (n & 1) == 1                  # error[QZ0700] branch on Secret-derived condition
    return 1
  end
  return 0
end
```

**Diagnostic codes:**

| Code     | Sink position                                | Suggested fix                          |
|----------|----------------------------------------------|----------------------------------------|
| `QZ0700` | branch on Secret-derived condition           | `subtle::ct_select_int` + mask compose |
| `QZ0701` | array index by Secret-derived value          | `subtle::ct_copy_if_byte` / mask scan  |
| `QZ0702` | comparison with a Secret-derived operand     | `subtle::ct_eq_byte` / `ct_eq_bytes`   |
| `QZ0703` | variable shift by a Secret-derived amount    | unwrap, mask, or use a constant amount |

**Sources of taint:** function parameters typed `Secret<T>`; results of
`secret_wrap` calls; every SSA value produced by an op consuming a tainted
operand. `secret_unwrap` does **not** declassify inside `@ct` — the
parameter remains the only declassification boundary.

**Out of scope (v1):** byte-level taint through memory (`memcpy`, raw
pointer writes) — the v1 pass tracks SSA registers and variable slots, not
pointer-reachable memory. Functions whose secret data flows through fresh
`malloc` + `memcpy` are not validated end-to-end by Layer 3 today; pair
with `dudect:smoke` for empirical validation. Filed as a forward extension
in `docs/design/SECRET_T_AND_DUDECT_DESIGN.md`.

`@ct` is opt-in per function; it composes with `@strict` newtypes (Layer 1)
without overlap — Layer 1 catches the same four sinks **when the value is
still typed `Secret<T>` at the use site**, Layer 3 catches them after the
value crosses `secret_unwrap` inside an `@ct` body.

---

## Pattern Matching

Enum variants in match arms are **unqualified** — write `Some(v)`, not `Some(v)`:

```quartz
match color
  Red => puts("red")           # Unqualified variant (preferred)
  Green => puts("green")
  _ => puts("other")           # Wildcard
end

match opt
  Some(v) => puts("#{v}")     # Unqualified — not Some(v)
  None => puts("nothing")     # Unqualified — not None
end

match n
  0 => 1
  1 => 1
  _ => fib(n - 1) + fib(n - 2)       # Expression result
end

# String literal match arms (desugars to str_eq chains)
match text
  "def" => TOK_DEF
  "end" => TOK_END
  "if"  => TOK_IF
  _     => TOK_IDENT
end
```

**Multi-statement arms use brace blocks:**
```quartz
match choice
  A => {
    var g = Guard { id: 1 }   # Local variable
    process(g)                 # Multiple statements
    100                        # Last expression is result
  }
  B => 200                     # Single expression (no braces needed)
end
```

**Exhaustiveness Checking (v5.12+):**

Match expressions on enum types must cover all variants or include a wildcard `_` pattern.
Match on Int/String always requires a wildcard. Error code: `QZ0106`.

```quartz
# ERROR: QZ0106 — missing variant 'Blue'
match color
  Red => 1
  Green => 2
end

# OK: all variants covered
match color
  Red => 1
  Green => 2
  Blue => 3
end

# OK: wildcard covers remaining
match color
  Red => 1
  _ => 0
end
```

**Or-Patterns:**

Multiple patterns can share a match arm body using `|`:

```quartz
match x
  1 | 2 | 3 => "small"
  4 | 5 => "medium"
  _ => "large"
end

# Works with enum variants (unqualified preferred)
match color
  Red | Blue => "primary"
  Green => "secondary"
  _ => "other"
end

# Works with string literals
match command
  "quit" | "exit" | "q" => shutdown()
  _ => process(command)
end

# Or-patterns can have guards
match x
  1 | 2 | 3 if x < 3 => "small-filtered"
  1 | 2 | 3 => "small"
  _ => "large"
end

# Or-patterns count toward exhaustiveness
match color
  Red | Blue => "rb"
  Green | Yellow => "gy"    # All variants covered, no wildcard needed
end
```

**Range Patterns:**

Integer range patterns match values within a range:

```quartz
match n
  0 => "zero"
  1..10 => "small"         # Exclusive: matches 1 through 9
  10...100 => "medium"     # Inclusive: matches 10 through 100
  _ => "large"
end
```

Range patterns use the same `..` (exclusive) and `...` (inclusive) syntax as range
expressions. Both endpoints must be integer literals. Range patterns work alongside
other pattern types (literals, or-patterns, wildcards) and participate in
exhaustiveness checking.

**Pattern Binding in Conditionals:**

`if PATTERN = EXPR` destructures an enum in a single-arm conditional, replacing verbose single-arm `match` blocks:

```quartz
# Instead of:
match lookup(key)
  Some(v) => process(v)
  _ =>
end

# Write:
if Some(v) = lookup(key)
  process(v)
end
```

Pattern variables are scoped to the then-block only. Supports `else`, `elsif` (pattern or expression), and expression position:

```quartz
# With else
if Some(v) = lookup(key)
  process(v)
else
  handle_missing()
end

# Elsif chains (pattern + pattern, or pattern + expression)
if Some(x) = first()
  use(x)
elsif Some(y) = second()
  use(y)
else
  neither()
end

# Expression position
result = if Some(v) = expr then v * 2 else 0 end

# Qualified patterns
if MyEnum::Variant(x) = expr
  use(x)
end

# No-payload patterns
if None = expr
  handle_none()
end

# Wildcard (always matches)
if _ = expr
  always_runs()
end
```

All pattern types from `match` work: enum (qualified/unqualified), wildcard, struct destructure, vec destructure, or-patterns.

---

## Control Flow

### If/Elsif/Else

```quartz
if x > 0
  puts("positive")
elsif x < 0
  puts("negative")
else
  puts("zero")
end
```

### Unless

```quartz
unless logged_in
  puts("Please log in")
end
```

### Truthy/Falsy

```quartz
# Falsy: 0, false, nil
# Truthy: everything else

if items.size                  # Truthy if > 0
  puts("has items")
end
```

### Loops

```quartz
while x > 0
  x -= 1
end

for i in 0..10                 # Range: 0 to 9 (exclusive end)
  puts("#{i}")                 # Auto-to_s in interpolation
end

for i in 0...5                 # Range: 0 to 5 (inclusive end with ...)
  puts("#{i}")
end

# Range with step — custom increment
for i in 0..10 step 2          # 0, 2, 4, 6, 8
  puts("#{i}")
end

for i in 10..0 step -1         # 10, 9, 8, ..., 1 (countdown)
  puts("#{i}")
end

for i in 0...10 step 3         # 0, 3, 6, 9 (inclusive, step 3)
  puts("#{i}")
end

# Step can be any expression
var stride = compute_stride()
for i in 0..n step stride
  process(i)
end

# For-in with collections (Vec, array)
var names = vec_new<String>()
names.push("Alice")
names.push("Bob")
for name in names              # Iterates over Vec elements
  puts("Hello, #{name}!")
end

# For-in with strings (iterates codepoints as Int values)
for c in "hello"
  puts(c.to_s())               # Prints codepoint value: 104, 101, ...
end

# For-in with maps (iterates keys)
var m = map_new()
m.set("a", 1)
m.set("b", 2)
for k in m                     # k is each key
  var v = m.get(k).unwrap()
  puts("#{k} = #{v}")
end

# For-in with channels
for msg in channel              # Receives until channel closed
  process(msg)
end

# Infinite loop — must break to exit
loop
  data = read_next()
  break if data == 0
end
```

### Break and Continue

`break` exits the innermost loop. `continue` skips to the next iteration.

```quartz
# break: exit loop early
while true
  data = read_next()
  break if data == 0           # Exit when sentinel found
  process(data)
end

# continue: skip current iteration
for i in 0..100
  continue if i % 2 == 0      # Skip even numbers
  puts("#{i}")
end
```

Both work with `while`, `for..in`, and `loop` constructs.

### Labeled Loops

Labels use symbol syntax (`:name` prefix):

```quartz
:outer for i in 0..10
  for j in 0..10
    break :outer if j == 5     # Break outer loop
  end
end
```

Labels work with `while`, `for..in`, and `loop`. Both `break` and `continue`
accept optional labels.

### Postfix Guards

Execute statements conditionally without block syntax:

```quartz
# Return early if condition is true
return 42 if x > 0
return -1 unless x             # Return if x is falsy (0)

# Break/continue loops conditionally
break if done
continue unless valid

# Expression statements
increment() if should_increment
log_error(msg) unless silent
```

**Key Properties:**
- Works with `return`, `break`, `continue`, and expression statements
- `if` executes when condition is true
- `unless` executes when condition is false
- Desugars to standard if/unless blocks at parse time

### Block Expressions (v5.9.9)

Blocks can be used as expressions — the last expression in the block becomes its value.

```quartz
# do...end form (preferred, unambiguous)
x = do
  tmp = 5
  tmp * tmp
end                              # x = 25

# Curly brace form (when first token is a statement keyword)
y = {
  var count = 0
  count = count + 10
  count
}                                # y = 10

# Nested blocks
result = do
  inner = do
    3
  end
  inner + 1
end                              # result = 4
```

**Key Properties:**
- `do...end` blocks always parse as block expressions in expression context
- `{ }` blocks parse as block expressions when the first token is a statement keyword (`var`, `if`, `while`, `for`, `match`, `return`, etc.)
- The block's type is the type of its last expression statement
- Local bindings inside the block are scoped to the block
- Enables expression-returning macros like `$debug(expr)`

### Defer

Execute code on function exit, regardless of how the function exits:

```quartz
def process_file(path: String): Result<Data, Error>
  f = file_open(path)
  defer file_close(f)      # Guaranteed to run before function returns
  
  data = try parse(f)      # Early return still runs defer
  transform(data)
end
```

**Multiple defers** execute in LIFO order (last registered, first executed):

```quartz
def example(): Void
  defer puts("first")
  defer puts("second")
  defer puts("third")
  puts("working")
end
# Output: working, third, second, first
```

**Key Properties:**
- Function-scoped: All defers run at function exit, not block exit
- LIFO order: Last defer registered runs first
- Runs on all exits: `return`, early return, end of function
- Arguments evaluated at execution time (not registration)
- Runs before Drop trait cleanup

---

## Collections

### Vectors (dynamic arrays)

```quartz
# Preferred: UFCS method-style API
var v = vec_new<Int>()
v.push(42)                     # Push element
val = v[0]                     # Index access (or v.get(0))
len = v.size                   # Length (field-style, or v.size())
v[0] = 100                     # Index assignment (or v.set(0, 100))
last = v.pop()                 # Remove and return last — Option<Int>
v.clear()                      # Remove all elements
v.free()                       # Free memory

# Also available: functional intrinsic-style
v = vec_new()
vec_push(v, 42)
val = vec_get(v, 0)
len = vec_size(v)
vec_set(v, 0, 100)
last = vec_pop(v)              # Remove and return last — Option<Int>
vec_clear(v)
vec_free(v)
```

**Bounds checking**: All Vec access is bounds-checked. Out-of-bounds access panics with a message to stderr and aborts:

```quartz
var v = vec_new<Int>()
v.push(42)
v[5]   # panic: "index out of bounds: index 5, size 1"
```

Use `vec_get_unchecked(v, i)` for performance-critical paths where bounds are pre-validated.

### Array Literals

```quartz
arr = [1, 2, 3]
x = arr[0]                     # Index access
```

### Spread Operator

The spread operator `...` expands a Vec into individual elements inside an array literal:

```quartz
a = [1, 2, 3]
b = [4, 5]
c = [...a, ...b]               # [1, 2, 3, 4, 5]
d = [0, ...a, 99]              # [0, 1, 2, 3, 99]
copy = [...a]                  # Shallow copy of a
```

Spread creates a new Vec (value copy semantics). Mixed spread and non-spread elements are supported. Multiple spreads per literal are allowed. Spread with list comprehension is a parse error.

### List Comprehensions

```quartz
squares = [x * x for x in 0..10]
evens = [x for x in 0..20 if x % 2 == 0]
pairs = [x + y for x in 0..3 for y in 0..3]   # Nested
odds = [x for x in 1..20 step 2]               # Step: 1, 3, 5, ..., 19
rev = [x for x in 10..0 step -1 if x > 5]     # Step + filter
```

### Map Comprehensions

```quartz
doubles = {x => x * 2 for x in 1..5}         # {1=>2, 2=>4, 3=>6, 4=>8}
evens = {x => x for x in 1..10 if x % 2 == 0} # Filter with condition
lookup = {x * 10 => x for x in 1..4}          # Computed keys: {10=>1, 20=>2, 30=>3}
val = doubles.get(2)                          # Returns 4
```

**Note:** Map comprehensions create `Map<Int,V>` (integer-keyed maps). Use `map_get` to access values.

### Maps

```quartz
# Preferred: UFCS method-style API
var m = map_new<String, Int>()
m.set("key", 42)               # Set key-value pair
val = m.get("key")             # Returns Option<T> (None if not found)
has = m.has("key")             # Returns 1 if exists, 0 otherwise
m.delete("key")                # Delete key
size = m.size()                # Number of entries
keys = m.keys()                # Vec of all keys
vals = m.values()              # Vec of all values
m.free()                       # Free memory

# Also available: functional intrinsic-style
m = map_new()
map_set(m, "key", 42)
map_get(m, "key")              # Returns Option<T>
has = map_has(m, "key")
map_delete(m, "key")
size = map_size(m)
keys = map_keys(m)
vals = map_values(m)
map_free(m)
```

**Subscript vs `.get()` — different return types, pick by key provenance:**

| Form         | Returns     | On missing key | Use when                                              |
|--------------|-------------|----------------|-------------------------------------------------------|
| `m[key]`     | `V`         | **panics**     | Key is structurally guaranteed to exist               |
| `m.get(key)` | `Option<V>` | returns `None` | Missing key is an expected outcome of normal control flow |

```quartz
# Subscript — key came from m.keys(), missing is impossible
for key in m.keys()
  process(key, m[key])
end

# Accessor — user input, missing is a real outcome
match config.get(path)
  Some(v) => apply(v)
  None    => apply(default)
end
```

The subscript form (`m[key]`) rewrites internally to `map_fetch` and
propagates the value type `V` through the type checker. See
[`STYLE.md`](STYLE.md#map-subscript-vs-get--pick-by-key-provenance)
for full guidance.

> Vec by-index access (`v[i]` and `v.get(i)`) is panic-only; the
> `Option`-returning duality is Map-specific. Use `vec_first` /
> `vec_last` for safe positional Vec access.

**Implementation Notes:**
- Unified `Map<K,V>` type — compiler dispatches to string-key or int-key backend by key type
- Dynamic resize at 75% load factor (2x capacity growth)
- O(1) average lookup via linear probing
- Used internally by the self-hosted compiler for builtin registry

### Map Literals

```quartz
# Symbol keys (traditional)
config = {:name => "Be", :version => 1}
name = config.get(:name)

# String keys (Jan 2026)
headers = {"Content-Type" => "application/json", "Accept" => "*/*"}
ctype = headers.get("Content-Type")

# Computed keys (any expression before =>)
key = "dynamic"
data = {key => 42, get_key() => 99, "literal" => 1}
```

### Sets

```quartz
# Preferred: UFCS method-style API
var s = {1, 2, 3}              # Set literal
s = set_new()                  # Empty set
s.add(42)                      # Add element
has = s.has(42)                # Returns 1 if exists
s.delete(42)                   # Remove element (canonical verb)
size = s.size()                # Number of elements
members = s.members()          # Vec of all elements

# Also available: functional intrinsic-style
set_add(s, 42)
has = set_has(s, 42)
set_delete(s, 42)
size = set_size(s)
members = set_members(s)
```

**Implementation Notes:**
- Sets store i64 values (polymorphic - works with Int, String pointers, etc.)
- Backed by the integer-keyed open-addressing hash table (the same runtime as
  `Map<Int, _>`): the element is the key. `add`/`has`/`delete` are O(1)
  amortized; the table grows and rehashes as it fills (no fixed capacity).
- Element identity is by i64 value (`icmp eq`), so any element including 0
  and 1 is stored correctly.
- Deduplicates automatically during add operations
- `members()` returns elements in unspecified (hash) order — a Set is unordered
- Set literals `{e1, e2, e3}` desugar to set_new() + set_add() calls

### Stdlib Collections (`std/collections/`)

Six additional collection types are available via `import collections/...`:

#### Stack (LIFO)

Backed by `Vec<Int>`. All operations O(1) amortized.

```quartz
import collections/stack

var s = stack_new()
s.push(1)
s.push(2)
s.pop()                        # Some(2)
s.peek()                       # Some(1)
s.size()                       # 1
s.is_empty()                   # false
s.to_vec()                     # [1] (bottom to top)
s.clear()
s.free()
```

#### Queue (FIFO)

Backed by `Vec<Int>` with head pointer. Auto-compacts when head passes half capacity.

```quartz
import collections/queue

var q = queue_new()
q.enqueue(1)                   # or q.push(1)
q.enqueue(2)
q.dequeue()                    # Some(1) — or q.shift()
q.peek()                       # Some(2) — or q.first()
q.size()                       # 1
```

#### Deque (Double-Ended Queue)

Ring buffer backed by `Vec<Int>`. Grows by doubling. Default capacity 8.

```quartz
import collections/deque

var d = deque_new()             # or deque_new_with_capacity(16)
d.push_back(1)                 # or d.push(1)
d.push_front(0)                # or d.unshift(0)
d.pop_front()                  # Some(0) — or d.shift()
d.pop_back()                   # Some(1) — or d.pop()
d.peek_front()                 # or d.first()
d.peek_back()                  # or d.last()
d.get(0)                       # element at logical index
d.set(0, 42)                   # set at logical index
```

#### LinkedList (Doubly-Linked)

Parallel arrays (`_data`, `_next`, `_prev`) with slot allocation and free list. O(1) push/pop at both ends.

```quartz
import collections/linked_list

var ll = ll_new()               # or linked_list_new()
ll.push_back(1)                # or ll.push(1)
ll.push_front(0)               # or ll.unshift(0)
ll.pop_front()                 # Some(0) — or ll.shift()
ll.pop_back()                  # Some(1) — or ll.pop()
ll.get(0)                      # O(n) indexed access
ll.contains(42)                # O(n) search
ll.to_vec()                    # head-to-tail traversal
```

#### PriorityQueue (Binary Heap)

Min-heap by default. Push/pop O(log n), peek O(1).

```quartz
import collections/priority_queue

var pq = pq_new()              # min-heap (or priority_queue_new())
pq.push(30)
pq.push(10)
pq.push(20)
pq.pop()                       # Some(10) — smallest first
pq.peek()                      # Some(20)

var mx = pq_new_max()          # max-heap
mx.push(30)
mx.push(10)
mx.pop()                       # Some(30) — largest first
```

#### SortedMap (Sorted Key-Value)

Sorted parallel `Vec<Int>` arrays. Binary search O(log n) lookup, O(n) insert/delete.

```quartz
import collections/sorted_map

var m = sorted_map_new()
m.set(3, 30)
m.set(1, 10)
m.set(2, 20)
m.get(2)                       # 20 (0 if not found)
m.has(1)                       # true
m.delete(3)
m.min_key()                    # 1
m.max_key()                    # 2
m.keys()                       # Vec of sorted keys
m.values()                     # Vec of values in key order
```

#### Common Collection Methods

All 6 collections share these higher-order methods (inside their `impl` blocks):

| Method | Signature | Description |
|--------|-----------|-------------|
| `to_vec()` | `(): Vec<Int>` | Convert to Vec |
| `each(f)` | `(Fn(Int): Void): Void` | Iterate with side effects |
| `map(f)` | `(Fn(Int): Int): Vec<Int>` | Map to new values |
| `filter(f)` | `(Fn(Int): Bool): Vec<Int>` | Filter by predicate |
| `reduce(init, f)` | `(Int, Fn(Int, Int): Int): Int` | Fold/accumulate |
| `find(f)` | `(Fn(Int): Bool): Int` | First match or 0 |
| `any?(f)` | `(Fn(Int): Bool): Bool` | Any element matches |
| `all?(f)` | `(Fn(Int): Bool): Bool` | All elements match |
| `count(f)` | `(Fn(Int): Bool): Int` | Count matches |

**Note:** SortedMap's `each`, `map`, `filter`, `reduce` take `Fn(Int, Int)` (key, value) instead of `Fn(Int)`.

### Unified Collection API (v5.7)

All collection types share consistent method names via UFCS (Uniform Function Call Syntax).
Methods are called on values using dot notation and rewrite to canonical intrinsics.

#### Common Methods

| Method | Types | Description |
|--------|-------|-------------|
| `.size` | Vec, Map, Set, String, Array, StringBuilder | Number of elements/chars |
| `.empty?` | Vec, Map, Set, String, StringBuilder | True if empty (size == 0) |
| `.clear()` | Vec, Map, Set, StringBuilder | Remove all elements |
| `.free()` | Vec, Map, StringBuilder | Free underlying allocation |
| `.cmp()` | String | Compare strings (returns -1, 0, 1) |
| `.hash()` | String | FNV-1a hash of string |
| `.some?` | Option | True if Some (rewrites to `is_some`) |
| `.none?` | Option | True if None (rewrites to `is_none`) |
| `.ok?` | Result | True if Ok (rewrites to `is_ok`) |
| `.err?` | Result | True if Err (rewrites to `is_err`) |
| `.digit?` | Int (char) | True if 0-9 (rewrites to `is_digit`) |
| `.alpha?` | Int (char) | True if a-z/A-Z (rewrites to `is_alpha`) |
| `.alnum?` | Int (char) | True if alphanumeric (rewrites to `is_alnum`) |
| `.whitespace?` | Int (char) | True if space/tab/newline (rewrites to `is_whitespace`) |
| `.nil?` | Ptr | True if pointer is nil |

```quartz
v = vec_new()
v.push(1)              # UFCS: vec_push(v, 1)
v.push(2)              # UFCS: vec_push(v, 2)
print(v.size)          # 2 (rewrites to vec_size)
print(v.get(0))        # UFCS: vec_get(v, 0) -> 1
v.clear()              # Empty the vector
print(v.empty?)        # 1 (true)
```

#### Map Methods

```quartz
m = map_new()
m.set("key", 42)       # UFCS: map_set(m, "key", 42)
m.get("key")           # UFCS: map_get(m, "key") -> Option<T>
m.has("key")           # UFCS: map_has(m, "key") -> 1
m.delete("key")        # UFCS: map_delete(m, "key")
m.keys()               # UFCS: map_keys(m) -> Vec
m.values()             # UFCS: map_values(m) -> Vec
m.clear()              # UFCS: map_clear(m)
m.free()               # UFCS: map_free(m)
```

#### StringBuilder Methods

```quartz
var sb = sb_new()
sb.append("Hello")     # UFCS: sb_append(sb, "Hello")
sb.append(", World!")  # UFCS: sb_append(sb, ", World!")
sb.append_int(42)      # UFCS: sb_append_int(sb, 42)
sb.append_char(33)     # UFCS: sb_append_char(sb, 33) — '!'
sb.size()              # UFCS: sb_len(sb) -> 18
sb.to_string()         # UFCS: sb_to_string(sb) -> "Hello, World!42!"
sb.clear()             # UFCS: sb_clear(sb) — reset for reuse
sb.free()              # UFCS: sb_free(sb) — free allocation
```

#### String Methods

```quartz
s = "Hello, World!"
s.size                 # 13
s.empty?               # 0 (false)
s.starts_with("Hello") # 1 (true)
s.ends_with("!")       # 1 (true)
s.contains("World")    # 1 (true) - returns Bool, not index
```

**Design Principles:**
- **Consistency**: Same method name across types (`size`, not `len`/`length`/`count`)
- **Bool semantics**: Predicates return 1 (true) or 0 (false)
- **Zero runtime cost**: UFCS rewrites to intrinsic at compile-time

### `contains` — membership, not implementation

Every collection answers the same question the same way: `c.contains(x)` asks "is `x` inside `c`?" The compiler dispatches on the receiver type, so the *implementation* differs — `Vec.contains` is element-equality, `Set.contains` is a hash/tree lookup, `Map.contains` is key-equality, `String.contains` is substring search — but the *question* is always the same. Users ask membership questions, not implementation questions, and the type system knows enough to pick the right answer.

**Corollary:** `Vec<String>.contains("hello")` is **exact-element match**, not substring-search-across-elements. If you want "any element containing this substring," write `v.any?(s -> s.contains("hello"))` — that's two explicit operations, and the explicitness is the point.

---

## Strings

```quartz
name = "world"
puts("Hello, #{name}!")        # Interpolation
full = "Hello, " + name        # Concatenation with +

# Triple-quoted strings with indentation stripping
# When closing """ is on its own line, its indentation defines the baseline.
# Content lines have that many leading spaces stripped automatically.
sql = """
  SELECT *
  FROM users
  WHERE id = 1
  """
# sql == "SELECT *\nFROM users\nWHERE id = 1"

# Relative indentation is preserved:
code = """
  def main(): Int
    return 0
  end
  """
# code == "def main(): Int\n  return 0\nend"

# Backward compatible: closing """ at column 1 strips nothing.

# Raw strings — no escape processing
path = r"C:\Users\name\file.txt"       # Backslashes are literal
regex_source = r"\d+\.\d+"            # No need to double-escape
```

Raw strings (`r"..."`) pass the content through verbatim — no escape sequences
(`\n`, `\t`, `\\`, etc.) are processed. Useful for regex patterns, file paths,
and any content where backslashes should be literal.

### String Representation

Quartz strings are **length-prefixed fat pointers**:

```
┌──────────┬──────────────┐
│ length   │ data_ptr     │   ← two i64 fields (16 bytes total)
└──────────┴──────────────┘
                │
                ▼
         ┌─────────────────┐
         │ UTF-8 bytes...  │   ← heap-allocated, null-terminated
         └─────────────────┘
```

**Key Properties:**
- `.size` returns the **codepoint count** (O(n) — scans UTF-8 bytes)
- `str_byte_len(s)` / `s.byte_len()` returns **byte count** (O(1))
- Null terminator is maintained for C interop but not included in length
- String content comparison via `==` compares bytes, not pointer identity
- Created by runtime helpers: `qz_alloc_str(len, data)` and `qz_wrap_cstr(cstr)`

### String Equality (`==` operator)

`==` on strings performs **content comparison** (not pointer identity):

```quartz
a = "hello"
b = "hel" + "lo"
a == b              # true — same content, different allocations
str_eq(a, b)       # 1 — explicit function, same semantics
```

**Mechanism**: The `==` operator on strings desugars to `str_eq(a, b)`,
which compares lengths first (fast path) then byte content via `memcmp`.

### Unicode Model

Quartz strings are UTF-8 encoded with a **dual-level API**:

| Level | `.size` | `s[i]` | `.slice(a,b)` | `.find(x)` | Perf |
|-------|---------|--------|---------------|------------|------|
| **Codepoint** (default) | Codepoint count | Codepoint value | By codepoint range | Codepoint offset | O(n) |
| **Byte** (`str_byte_*`) | Byte count | Byte value | By byte range | Byte offset | O(1) |

```quartz
s = str_from_codepoint(233)    # é (U+00E9) — 1 codepoint, 2 bytes
s.size                          # 1 (codepoint count)
s.byte_len()                    # 2 (byte count)
s.byte_at(0)                    # 195 (0xC3, first UTF-8 byte)

# For ASCII strings, byte == codepoint — no difference
"hello".size                    # 5
"hello".byte_len()              # 5
```

**When to use byte-level**: ASCII protocol parsing, performance-critical loops,
binary data handling. The stdlib uses byte-level internally for O(1) indexing.

### String Builtins — Codepoint Level

```quartz
str_size(s)                    # Length in codepoints
str_concat(a, b)               # Concatenate
str_char_at(s, i)              # Codepoint value at codepoint index
str_from_int(n)                # Int to String (prefer "#{n}" interpolation)
str_from_char(c)               # Char code to String
str_slice(s, start, end)       # Substring by codepoint range [start, end)
str_find(s, needle)            # Find substring, returns Option<Int> (codepoint offset)
str_split(s, delim)            # Split into vector of strings
str_eq(a, b)                   # String equality (prefer a == b)

# String transformation (v5.7.9+)
s.downcase()                   # Convert to lowercase
s.upcase()                     # Convert to uppercase
s.trim()                       # Trim whitespace from both ends
s.replace(old, new)            # Replace all occurrences of old with new
str_join(vec, sep)             # Join vector of strings with separator
```

### String Builtins — Byte Level

```quartz
str_byte_len(s)                # Length in bytes, O(1)
str_byte_at(s, i)              # Byte value at byte index, O(1)
str_byte_slice(s, start, end)  # Substring by byte range [start, end), O(1)
str_byte_find(s, needle)       # Find substring, returns byte offset
str_bytes(s)                   # String to Vec of byte values
s.byte_len()                   # UFCS: str_byte_len(s)
s.byte_at(i)                   # UFCS: str_byte_at(s, i)
s.byte_slice(a, b)             # UFCS: str_byte_slice(s, a, b)
s.byte_find(needle)            # UFCS: str_byte_find(s, needle)
s.bytes()                      # UFCS: str_bytes(s)
```

### Unicode Library (`import unicode`)

Full Unicode support beyond the built-in codepoint/byte intrinsics. Import with `import * from unicode`.

**Codepoint Iteration** — zero-allocation lazy iterator:
```quartz
import * from unicode

## Iterate codepoints (must pre-assign iterator to a variable)
var iter = str_codepoints(s)
for cp in iter
  puts(str_from_codepoint(cp))
end

## Iterate with byte offsets (packed as (offset << 21) | codepoint)
var ci = str_char_indices(s)
for pair in ci
  var offset = char_index_offset(pair)
  var cp = char_index_codepoint(pair)
end
```

**Unicode Case Conversion** — full Unicode mapping including 1-to-many:
```quartz
unicode_to_upper("café")          # "CAFÉ"
unicode_to_lower("HELLO")         # "hello"
unicode_to_upper("straße")        # "STRASSE" (ß → SS)
unicode_eq_ignore_case("Héllo", "héllo")  # true
```

**Unicode Character Classification**:
```quartz
unicode_is_alphabetic(0xE9)       # true (é)
unicode_is_numeric(0x0661)        # true (Arabic digit 1)
unicode_is_whitespace(0x2003)     # true (em space)
unicode_is_uppercase(0xC9)        # true (É)
unicode_is_lowercase(0xE9)        # true (é)
unicode_is_alphanumeric(cp)       # alphabetic or numeric
```

**String Normalization** (NFC/NFD, `import * from unicode/normalize`):
```quartz
import * from unicode/normalize

unicode_nfd(s)                    # Canonical decomposition
unicode_nfc(s)                    # Canonical composition
unicode_eq_canonical(a, b)        # NFC(a) == NFC(b)
```

**Grapheme Cluster Iteration** (`import * from unicode/grapheme`):
```quartz
import * from unicode/grapheme

str_grapheme_count("e\u0301")     # 1 (e + combining accent = 1 grapheme)
var gi = str_graphemes(s)
for g in gi                       # g is Int — use as_string(g) for the substring
  puts(as_string(g))
end
```

### String Sweetness (v5.3.0+)

```quartz
s.size                         # Length in codepoints: str_size(s)
s[i]                           # Codepoint at index (bounds-checked, returns 0 if out of bounds)
s[a:b]                         # Slice: str_slice(s, a, b) — codepoint range
s[:b]                          # Slice from start: str_slice(s, 0, b)
s[a:]                          # Slice to end: str_slice(s, a, str_size(s))
n.to_s                         # Int to string: int_to_s(n)
s.find("needle")               # Find substring: str_find(s, "needle")
s.to_i                         # String to int: str_to_int(s)
```

### Collection Literals (v5.3.0+)

```quartz
# Vec literals
[]                             # Empty Vec
[1, 2, 3]                      # Vec with elements
[1, 2, 3,]                     # Trailing comma allowed
v.size                         # Length: vec_size(v)

# Map literals
{:}                            # Empty Map
{key: 1, other: 2}             # Shorthand symbol keys (preferred)
{key: 1}                       # Same as {:key => 1}
{"key" => 1}                   # String keys with hashrocket
{:symbol => val}               # Symbol keys with hashrocket (avoid)
m.size                         # Size: map_size(m)
m["key"]                       # Get: map_get(m, "key")
```

**Note:** Strings are Int handles. Compare to `0`, not `""`.

---

## Regex

Regular expressions for pattern matching on strings. Uses PCRE2 under the hood.

### Regex Literals

```quartz
pattern = ~r"hello"               # Basic pattern
digits = ~r"\d+"                  # Escape sequences
email = ~r"[a-z]+@[a-z]+\.[a-z]+" # Character classes
anchor = ~r"^start.*end$"         # Anchors
groups = ~r"(\w+)@(\w+)"          # Capture groups
named = ~r"(?<user>\w+)@(?<domain>\w+)"  # Named capture groups
```

### Match Operator `=~`

Returns `Bool` — true if pattern matches anywhere in string:

```quartz
if s =~ ~r"hello"
  puts("found hello")
end

# With variables
text = "user@example.com"
pattern = ~r"@"
if text =~ pattern
  puts("valid email format")
end
```

### Not-Match Operator `!~`

Returns `Bool` — true if pattern does NOT match:

```quartz
if email !~ ~r"@"
  puts("invalid email: no @ symbol")
end
```

### Capture Operator `=~?`

Returns `Vec<String>` of captured groups (or `0` if no match):

```quartz
s = "hello123world"
captures = s =~? ~r"([a-z]+)([0-9]+)([a-z]+)"
if captures != 0
  full = as_string(vec_get(captures, 0))   # "hello123world" (group 0 = full match)
  word1 = as_string(vec_get(captures, 1))  # "hello" (group 1)
  nums = as_string(vec_get(captures, 2))   # "123" (group 2)
  word2 = as_string(vec_get(captures, 3))  # "world" (group 3)
end
```

### Named Captures

Use `regex_capture_named(text, pattern, name)` to extract a named group:

```quartz
s = "hello world"
word = regex_capture_named(s, "(?<word>w\\w+)", "word")
# word = "world"
```

### Regex in Match Expressions

Pattern match strings against regexes:

```quartz
result = match s
  ~r"\d+" => 1           # Matches if s contains digits
  ~r"foo" => 2           # Matches if s contains "foo"
  _ => 0                 # Default case
end
```

**Note:** Regex patterns in match arms test if the regex matches anywhere in the string (partial match), not if the entire string matches the pattern.

### Regex Type

The `Regex` type can be used in function signatures:

```quartz
def matches_pattern(text: String, pattern: Regex): Bool
  return text =~ pattern
end

matches_pattern("hello", ~r"ell")  # true
```

### Summary Table

| Syntax | Returns | Description |
|--------|---------|-------------|
| `~r"pattern"` | `Regex` | Regex literal |
| `s =~ pattern` | `Bool` | True if pattern matches anywhere in s |
| `s !~ pattern` | `Bool` | True if pattern does NOT match |
| `s =~? pattern` | `Vec<String>` or `0` | Captured groups (0 = no match) |
| `regex_capture_named(s, pat, name)` | `String` | Named capture group value |
| `match s { ~r"..." => ... }` | varies | Pattern matching with regex |

---

## Symbols

```quartz
status = :ok
result = :error

match status
  :ok => handle_success()
  :error => handle_failure()
end
```

---

## Operators

### Arithmetic
`+`, `-`, `*`, `/`, `%`

### Comparison
`==`, `!=`, `<`, `<=`, `>`, `>=`

### Logical
`and`, `or`, `not`

**Note**: `not` strictly requires a `Bool` operand. `not 0` is a compile error —
use `not (x == 0)` or a Bool-returning function like `not map_has(m, k)`.

### Bitwise
`&` (and), `|` (or), `^` (xor), `~` (not), `<<` (left shift), `>>` (right shift)

#### Bit Manipulation Intrinsics

| Intrinsic | Signature | Description |
|-----------|-----------|-------------|
| `popcount` | `(Int): Int` | Count set bits (ones) |
| `clz` | `(Int): Int` | Count leading zeros |
| `ctz` | `(Int): Int` | Count trailing zeros |
| `bswap` | `(Int): Int` | Reverse byte order (endian swap) |
| `rotl` | `(Int, Int): Int` | Rotate bits left by N |
| `rotr` | `(Int, Int): Int` | Rotate bits right by N |

```quartz
popcount(0xFF)       # 8 (eight 1-bits)
clz(1)               # 63 (on 64-bit)
ctz(8)               # 3
bswap(0x0102030405060708)  # 0x0807060504030201
rotl(1, 3)           # 8
rotr(8, 3)           # 1
```

### Multi-line expressions

A statement ends at the newline. To split a long binary expression across
lines, put the operator at the **end** of each line — a newline immediately
after a binary operator is a continuation:

```quartz
var c = lane(0) ^
        lane(1) ^
        lane(2) ^
        lane(3)
```

Leading the continuation line with the operator does **not** work and is a
compile error (`QZ0103`) — the newline already ended the statement:

```quartz
# Wrong — QZ0103:
var c = lane(0)
        ^ lane(1)
        ^ lane(2)
```

(Before the May 2026 parser correction, the leading-operator form was silently miscompiled: the `^`
lines were parsed as separate discarded statements, so `c` got only
`lane(0)`. It is now a hard parse error.)

### Safe Navigation

```quartz
name = user?.profile?.name     # Returns nil if any is nil
```

### Nil Coalescing

```quartz
port = config?.port ?? 8080    # Default if nil
name = user?.name ?? "Anonymous"
```

**Note**: Spaces are required around `??` for readability. `x??42` is a syntax error.
Use `x ?? 42` instead.

### Pipeline

```quartz
result = data |> parse |> transform |> format
# Equivalent to: format(transform(parse(data)))

result = x |> add(10) |> multiply(2)
# Equivalent to: multiply(add(x, 10), 2)
```

---

## Imports

```quartz
import token                   # Loads token.qz from same directory
import frontend/lexer          # Hierarchical (v1.0+)
import std/colors              # Standard library
from token import Token, Loc   # Selective
import token as t              # Aliased
import * from qspec            # Wildcard — all symbols available unprefixed
from module import *           # Alternative wildcard syntax
pub import utils               # Re-export: importers of this module also get utils
```

### Module-Qualified Calls

```quartz
import math

math.add(1, 2)                 # Dot syntax (preferred)
math$add(1, 2)                 # Explicit syntax
```

### Module-Qualified Types

Access structs and enums from imported modules:

```quartz
import lib

# Struct from another module
p = lib.Point { x: 10, y: 20 }

# Enum variant from another module
c = lib.Color::Red

# Match patterns work too
match c
  lib.Color::Red => puts("red")
  lib.Color::Blue => puts("blue")
end
```

### Visibility (Private)

Items after `private` are not accessible from other modules:

```quartz
# lib.qz
struct Public          # Accessible from other modules
  x: Int
end

private

struct Secret          # Only accessible within lib.qz
  value: Int
end
```

```quartz
# main.qz
import lib

lib.Public { x: 1 }            # OK
# lib.Secret { value: 1 }      # ERROR: Secret is private
```

**Wrong:**
```quartz
# import a::b                  # `::` is NOT the import-path separator (imports use `/`)
# import "token.qz"            # NO string paths
```

Note: `::` itself is used pervasively elsewhere — it is the variant/path
separator. After `import codegen_util`, calls are written
`codegen_util::cg_emit(...)` (module-qualified call), and enum variants are
written `Option::Some(x)`, `Result::Ok`, `Color::Red`. Across the source tree
`::` appears ~87,000× (~70,800 of those are `module::function` qualified calls,
~4,100 are enum-variant qualifiers). Only the `import` statement uses `/`; the
`.`-as-module-path form (`math.add`) coexists but is essentially never the
qualifier in compiler source.

---

## Macros (v5.5+)

Quartz has a hygienic macro system with quote/unquote semantics.

### Basic Macro

```quartz
macro max(a, b) do
  "if ${a} > ${b} then ${a} else ${b} end"
end

result = $max(10, 20)    # Expands to: if 10 > 20 then 10 else 20 end
```

### Quote/Unquote Macros

```quartz
macro double(x) do
  quote do
    unquote(x) + unquote(x)
  end
end

result = $double(21)     # Expands to: 21 + 21
```

### Variadic Macros

```quartz
macro sum(args...) do
  quote do
    unquote_each(args, " + ")
  end
end

result = $sum(1, 2, 3)   # Expands to: 1 + 2 + 3
```

**Key Properties:**
- Macro invocation: `$macro(args)` — dollar prefix
- Hygiene: Local bindings in macros don't capture user variables
- String templates: `"${param}"` for simple text substitution
- Quote/unquote: For AST manipulation
- Debug: `--expand-macros` flag shows expansion

### Built-in Macros (v5.9.9+)

Four built-in macros that expand at compile time. No import or
definition needed. (`$try` is retired — use the `try` prefix keyword.)

```quartz
# $unwrap(expr) — unwrap Option or panic with source location
val = $unwrap(get_value())         # Panics: "unwrap failed at line 42"

# $assert(condition) — panic if condition is false
$assert(x > 0)                     # Panics: "assertion failed at line 5"
$assert(vec_size(v) == 3)

# $debug(expr) — print value to stderr, return value (expression-returning)
$debug(x)                          # stderr: "[debug] line 7: 42", returns x
x = $debug(10 + 20)               # stderr: "[debug] line 3: 30", x = 30
print_int($debug(a) + $debug(b))  # Debug both, then print sum

# $caller(name) — escape-hatch identifier that resolves against
# caller scope instead of the macro's hygiene-renamed body scope
# (used inside macro bodies for intentional cross-scope reference)
```

**Expansion details:**
- `$unwrap(expr)` → `match expr / Some(__v) => __v / None => panic("unwrap failed at line N") / end`
- `$assert(cond)` → `if !(cond) then { panic("assertion failed at line N"); 0 } end`
- `$debug(expr)` → `do __v = expr; eputs("[debug] line N: "); eprint_int(__v); eputs("\n"); __v end`
- `$caller(ident)` → a `NODE_IDENT` stamped with the caller's scope set, bypassing body-local alpha-rename. See [`MACROS.md`](MACROS.md#the-caller-escape-hatch).

**Limitations:**
- `$unwrap` only works with `Option<T>` (panics on `None`). For early-return-on-failure of `Option` or `Result`, use the `try` prefix keyword instead.
- `$debug` only prints `Int` values via `eprint_int` to stderr
- `$caller` accepts exactly one bare identifier argument; literals and expressions are rejected with `QZ0510`.

**Behavioral notes:**
- `panic()` writes to stderr via `write(2, ...)`, never stdout
- `$debug` framing (`[debug] line N: `) goes to stderr via `eputs`, value via `eprint_int` to stderr
- `$debug` returns its argument value — usable anywhere an expression is expected
- `$debug` evaluates its argument exactly once (gensym binding)

### Full reference

[`MACROS.md`](MACROS.md) is the complete reference: grammar, fragment
specifiers, hygiene semantics, the `$caller` escape hatch, expansion
diagnostics, error codes, and known limits.

---

## UFCS (Uniform Function Call Syntax)

Enables method-like syntax for any function. If `x.f(y)` is called but `f` is not a method on `x`, the compiler rewrites it to `f(x, y)`.

```quartz
def double(n: Int): Int = n * 2
def add(a: Int, b: Int): Int = a + b

def main(): Int
  x = 5
  x.double()        # Rewrites to: double(x) → 10
  x.add(3)          # Rewrites to: add(x, 3) → 8
  x.double().add(1) # Chaining: add(double(x), 1) → 11
end
```

**Works with all types:** UFCS applies to any receiver including primitives, structs, strings, vectors. Impl methods and trait impls take precedence over free functions.

```quartz
[1, 2, 3].map(x: Int -> x * 2)    # Rewrites to: map([1, 2, 3], x: Int -> x * 2)
"hello".size                       # Rewrites to: str_size("hello")
```

### Dot-Method Paren Elision

Zero-arg method calls do not require parentheses at the dot-access position. `obj.method` calls `method(obj)` whenever `method` resolves as an impl method on `obj`'s type or as a free function whose first parameter matches `obj`. This applies symmetrically to user-defined methods, free functions called via open UFCS, and the existing builtin shortcuts (`.size`, `.empty?`, etc.).

```quartz
struct Point
  x: Int
  y: Int
end

extend Point
  def magnitude(self): Int = @x + @y
end

def triple(n: Int): Int = n * 3

def main(): Int
  p = Point { x: 3, y: 4 }
  p.magnitude       # 7  — earlier parsers rejected this; now calls magnitude(p)
  p.magnitude.to_s  # "7" — chains transparently
  5.triple          # 15 — open UFCS, no parens required
  5.triple.triple   # 45
  return 0
end
```

**Field-vs-method precedence**: when a struct has both a field and a method with the same name, the field wins. Use explicit parentheses (`r.tag()`) to call the method.

```quartz
struct R
  tag: Int
end
extend R
  def tag(self): Int = 999
end
r = R { tag: 7 }
r.tag    # 7   — field wins
r.tag()  # 999 — explicit method call
```

**Bareword bindings are unchanged.** Paren elision applies only at the dot-access position; bare `foo` (no receiver) still resolves to the function value, never an auto-call. Pass `foo` directly into `Fn`-typed parameters as before.

```quartz
def apply(f: Fn(Int): Int, n: Int): Int = f(n)
apply(triple, 4)  # 12 — bareword `triple` is the function value
```

See [`design/DOT_METHOD_PAREN_ELISION.md`](design/DOT_METHOD_PAREN_ELISION.md) for the design rationale and prior-art survey.

### UFCS for Collections and Option/Result

All builtin types have UFCS aliases. Prefer UFCS style over free-function calls:

```quartz
# Vec — UFCS preferred
v = vec_new()
v.push(42)                     # not vec_push(v, 42)
v.pop()                        # not vec_pop(v)
v.size                         # not vec_size(v) — use .size field-style

# Map — UFCS preferred
m = map_new()
m.set("key", 42)              # not map_set(m, "key", 42)
m.get("key")                  # not map_get(m, "key")
m.has("key")                  # not map_has(m, "key")

# Option — UFCS preferred
opt = Option::Some(42)
opt.unwrap_or(0)               # not unwrap_or(opt, 0)
opt.is_some()                  # not option_is_some(opt)
opt.map(x -> x * 2)           # transform the inner value

# Result — UFCS preferred
res = Result::Ok(42)
res.is_ok()                    # check success
res.is_err()                   # check failure
```

---

## The `is` Keyword

The `is` keyword tests whether a value matches an enum variant. Returns `Bool`.

```quartz
opt = Option::Some(42)
opt is Some                    # true
opt is None                    # false

res = Result::Ok(100)
res is Ok                      # true
res is Err                     # false
```

### With Postfix Guards

`is` combines naturally with postfix guards for concise early returns:

```quartz
def process(opt: Option<Int>): Int
  return 0 if opt is None
  val = opt.unwrap_or(0)
  return val * 2
end

def handle(res: Result<Int, String>): Int
  return -1 if res is Err
  # ...happy path
end
```

### In Conditionals

```quartz
if opt is Some
  puts("has value")
end

unless result is Ok
  puts("error occurred")
end
```

**Key Properties:**
- Works with any enum variant: `val is VariantName`
- Unqualified variants only — `val is Some`, not `val is Option::Some`
- Returns `Bool` (1 or 0)
- Usable anywhere a boolean expression is expected

### Smart Narrowing

After `if opt is Some`, the compiler knows `opt` is `Some` in the then-block. Subsequent `opt!` (force-unwrap) skips the redundant tag check and extracts the payload directly:

```quartz
if opt is Some
  val = opt!        # No tag check — compiler knows opt is Some
  process(val)
end
```

Narrowing also works in else-blocks for 2-variant enums (Option, Result):

```quartz
if opt is None
  return -1
else
  val = opt!        # No tag check — compiler knows opt is Some
end
```

And with is-bindings:

```quartz
if opt is Some(v)
  total = v + opt!  # opt narrowed to Some, opt! skips tag check
end
```

**Rules:**
- Only simple variable references are narrowed (not function calls or complex expressions)
- Supports Option (`Some`/`None`) and Result (`Ok`/`Err`)
- Narrowing is scope-bounded — exits when the if-block ends
- Re-assigning the variable in the block does NOT invalidate narrowing (it trusts the branch)

---

## Implicit `it` Parameter

Trailing block lambdas with curly braces can omit the parameter name. Inside the block, the implicit parameter is named `it`:

```quartz
items = [1, 2, 3, 4, 5]

# Explicit parameter
positives = items.filter() { x -> x > 0 }

# Implicit `it` — shorter, idiomatic
positives = items.filter() { it > 0 }
doubled = items.map() { it * 2 }
items.each() { puts("#{it}") }
```

### When to Use

- **Use implicit `it`** for single-param trailing blocks where the body is short and the meaning is clear:
  ```quartz
  items.filter() { it > 0 }
  items.map() { it * 2 }
  items.any?() { it == target }
  ```

- **Use explicit params** when there are multiple parameters, or when the body is complex enough to benefit from a descriptive name:
  ```quartz
  items.reduce(0) do acc, x -> acc + x end
  items.sort_by() { a, b -> a - b }
  ```

**Key Properties:**
- Only available in curly-brace blocks `{ ... }`, not in `do...end` blocks
- Only for single-parameter lambdas — multi-param blocks need explicit names
- `it` is a real binding visible inside the block, not magic syntax
- Nesting implicit `it` blocks shadows the outer `it` (avoid this)

---

## Extend Blocks

Extend blocks add methods to existing types without modifying their definition. Methods use `self` to refer to the receiver.

### Basic Syntax

```quartz
extend Int {
  def double(): Int = self * 2
  def plus(n: Int): Int = self + n
}

def main(): Int
  x = 10
  x.double()           # 20
  x.double().plus(5)   # 25
end
```

### Extending Structs

```quartz
struct Point
  x: Int
  y: Int
end

extend Point {
  def sum(): Int = self.x + self.y
}

p = Point { x: 10, y: 32 }
p.sum()  # 42
```

### Direct Call Syntax

Extension methods can be called with `Type$method(receiver)`:

```quartz
extend Int {
  def triple(): Int = self * 3
}

Int$triple(7)  # 21 (same as 7.triple())
```

### Generic Extensions (planned)

```quartz
extend<T> Vec<T> {
  def first(): T = vec_get(self, 0)
}
```

**Key Properties:**
- Extension methods appear in scope immediately after the extend block
- Multiple extend blocks for the same type are allowed
- Recursive calls work: `(self - 1).factorial()`
- Works with Bool, Int, String, structs, and other types

---

## Traits

### Definition

Trait methods can be **abstract** (bodyless — must be implemented) or **default** (have a body — inherited if not overridden):

```quartz
trait Eq
  def op_eq(self, other: Self): Bool       # abstract — implementors MUST provide
  def op_ne(self, other: Self): Bool       # default — delegates to op_eq
    return not self.op_eq(other)
  end
end

trait Show
  def show(self): String                   # default — can be overridden
    return "<unknown>"
  end
end
```

### Implementation

```quartz
extend Point with Eq
  def op_eq(self, other: Self): Bool
    return @x == other.x and @y == other.y
  end
  # op_ne inherited from default
end
```

### Abstract Methods

Methods without a body are abstract — the compiler enforces that every `extend ... with Trait` block provides them:

```quartz
trait Shape
  def area(self): Int           # abstract — no body
  def perimeter(self): Int      # abstract — no body
  def name(self): String        # abstract — no body
  def describe(self): String    # default — has body
    return "#{self.name()}: area=#{self.area()}"
  end
end

extend Rect with Shape
  def area(self): Int = @w * @h
  def perimeter(self): Int = 2 * (@w + @h)
  def name(self): String = "rect"
  # describe inherited — calls our area() and name()
end
```

### Auto-Satisfaction

If a type's inherent `extend` block already provides a method matching a trait requirement, the trait is **automatically satisfied** — no need to re-define it:

```quartz
struct Queue
  _data: Vec<Int>
  _head: Int
end

extend Queue
  def size(): Int = @_data.size - @_head
  def is_empty(): Bool = @_head >= @_data.size
  def clear(): Void
    vec_clear(@_data)
    @_head = 0
  end
end

trait Container
  def size(self): Int
  def is_empty(self): Bool = self.size() == 0
  def clear(self): Void
end

# Empty extend — all methods auto-satisfied from inherent extend
extend Queue with Container end
```

This enables bounded generics over collections:

```quartz
def print_size<T: Container>(c: T): Void
  puts("size: #{c.size()}")
end
print_size(my_queue)  # works — Queue satisfies Container
```

### Self Type

Inside trait definitions and extend blocks, `Self` refers to the implementing type:

```quartz
trait Cloneable
  def clone(self): Self       # Self = concrete type in extend
    return self
  end
end

extend Point with Cloneable
  def clone(self): Self       # Self = Point here
    return Point { x: @x, y: @y }
  end
end
```

### Default Methods

Trait methods with bodies serve as defaults. Extend blocks can override some and inherit others:

```quartz
trait Comparable
  def op_eq(self, other: Self): Bool   # abstract
  def op_ne(self, other: Self): Bool = not self.op_eq(other)  # default
end

extend Point with Comparable
  def op_eq(self, other: Self): Bool     # required — abstract
    return @x == other.x and @y == other.y
  end
  # op_ne inherited — calls self.op_eq() which dispatches to our override
end
```

### Generic Trait Bounds

```quartz
def largest<T: Area>(a: T, b: T): Int
  if a.area() > b.area()     # UFCS through trait bound
    return a.area()
  end
  return b.area()
end

def describe<T: Show + Area>(s: T): String   # Multiple bounds
  return "#{s.show()} area=#{s.area()}"
end
```

### Coherence

Duplicate implementations of the same trait for the same type are rejected:

```quartz
extend Point with Eq          # OK
  def eq(self, other: Self): Bool = @x == other.x
end

extend Point with Eq          # ERROR: Conflicting trait implementation
  def eq(self, other: Self): Bool = @y == other.y
end
```

### `impl Trait` (LF2.7)

`impl Trait` lets a function *commit to* a trait as the type of a value
without naming the concrete type. Quartz supports it in two positions:

- **Return position** — "I return some type that implements this trait,
  but you don't need to care which one."
- **Argument position** — syntactic sugar for an implicit generic
  parameter. `def drain(src: impl Iter)` is equivalent to
  `def drain<T: Iter>(src: T)`.

Both positions are **transparently monomorphized**. There is no vtable,
no boxing, no runtime cost — each call site uses the concrete type
directly, just like a regular generic.

#### Return position

```quartz
def make_greeter(): impl Greeter = Hello { val: 42 }

def make_counter(start: Int): impl Counter
  return SimpleCounter { n: start }
end
```

UFCS dispatch, chaining, and bounded-generic propagation all work:

```quartz
var g = make_greeter()
g.greet()                            # Dispatches to Hello$greet(g)
make_greeter().greet()               # Chained call also works

def take_three<T: Greeter>(src: T): Int
  return src.greet() + src.greet() + src.greet()
end
take_three(make_greeter())           # Bound propagation ✓
```

**Same-type constraint**: all `return` paths must yield the same concrete
type. Quartz infers this by scanning every return site in the body:

```quartz
# OK — both branches return Hello
def make(flag: Int): impl Greeter
  if flag == 1
    return Hello { val: 99 }
  end
  return Hello { val: 0 }
end

# ERROR (QZ0161) — conflicting concrete types
def make_bad(flag: Int): impl Greeter
  if flag == 1
    return Hello { val: 1 }    # Hello
  end
  return World { val: 2 }      # World ← conflict
end
```

#### Argument position

```quartz
def drain(src: impl Iter): Int
  return src.next() + src.next()
end
```

The resolver rewrites this to an implicit generic parameter before the
typechecker runs:

```quartz
def drain<_impl_0: Iter>(src: _impl_0): Int
  ...
end
```

So each distinct caller instantiates its own monomorphized copy. Two
different impls passed to the same `impl Trait` argument do **not**
collapse into one specialization — the resolver's desugar pass is what
closes that hole (Apr 13 2026 sprint, probe 5).

You can still mix explicit and implicit type parameters on the same
function. Synthetic params are appended to the explicit ones:

```quartz
def zip_with<T>(tag: T, src: impl Iter): Int
  return src.next() + tag
end
# desugars to: zip_with<T, _impl_0: Iter>(tag: T, src: _impl_0)
```

#### Trait-bound propagation

A value produced by `impl Trait`–returning function can be passed to a
bounded generic argument, and the typechecker resolves through the
impl-return registry to satisfy the bound:

```quartz
def sum_all<T: Iter>(src: T): Int
  var total = 0
  while true
    match src.next()
      Some(v) => total += v
      None => return total
    end
  end
  return total
end

sum_all(make_greeter())              # OK — Greeter's concrete impls Iter
```

#### Bounded generic struct fields

Adapter structs that wrap an iterator can carry the bound on their type
parameter:

```quartz
struct MapIter<I: Iter>
  source: I
end

extend MapIter<T> with Iter
  def next(self): Option<Int>
    return self.source.next()
  end
end
```

Bound enforcement fires at **struct initialization** time. Constructing
a `MapIter<NotAnIter> { source: ... }` fails with a "does not implement
trait" error. Bounds on type parameters that themselves refer to an
enclosing function's type parameter are deferred to monomorphization —
`def iter_map<I: Iter>(src: I): MapIter<I>` doesn't eagerly error just
because `I` isn't a registered struct.

This shape — a bounded generic struct

  struct MapIter<I: Iter>
    source: I
  end

plus `impl Iter for MapIter<T>` — used to hang the parser in an infinite
loop. The bounded-type-param half was fixed in the Apr 13 2026 sprint; the
brace-delimited-body half (`struct MapIter<I: Iter> { source: I }`) hung
until the Jun 1 2026 fix, which now rejects braced struct *bodies* with
`QZ0102` (use the `end`-delimited form above; `{ }` is for struct literals).

#### Errors

| Code | Meaning |
|------|---------|
| `QZ0160` | Unknown trait in `impl` return type |
| `QZ0161` | Conflicting concrete types across return paths |
| `QZ0162` | Concrete type does not implement the declared trait |
| `QZ0200` | Type arg to a bounded generic struct violates the declared bound |

#### Current limitations

- **Opacity is enforced.** QZ0167 rejects assigning an opaque return to
  an explicit concrete annotation, and QZ0168 rejects unifying opaque values
  from distinct origins. Callers use the trait interface while compiler
  monomorphization retains the hidden concrete type.
- Return-position `impl Trait` in trait methods is implemented for the current
  statically dispatched trait model.
- **Nested monomorphization through type-parameter UFCS**: inside a
  bounded generic body, UFCS dispatch like `src.next()` on a
  type-parameter receiver doesn't always re-dispatch through the caller's
  resolved concrete. Filed as `NESTED-MONO-UFCS-TYPE-PARAM`.

### Standard Traits (std/traits.qz)

| Trait | Methods |
|-------|---------|
| `Eq` | `eq(self, other)`, `ne(self, other)` |
| `Ord` | `lt`, `le`, `gt`, `ge` |
| `Hash` | `hash(self) -> Int` |
| `Show` | `show(self) -> String` |
| `Clone` | `clone(self) -> Self` |
| `Drop` | `drop(self)` (RAII cleanup) |

---

## Enumerable

### Simple Operations

```quartz
sum(arr)                       # Sum all elements
product(arr)                   # Product of all
first(arr)                     # First element
last(arr)                      # Last element
min(arr)                       # Minimum
max(arr)                       # Maximum
```

### Higher-Order

```quartz
# UFCS + implicit `it` — preferred modern style
arr.each() { puts("#{it}") }
doubled = arr.map() { it * 2 }
evens = arr.filter() { it % 2 == 0 }
total = arr.reduce(0) do acc, x -> acc + x end
count = arr.count() { it > 0 }
has_neg = arr.any?() { it < 0 }
all_pos = arr.all?() { it > 0 }
found = arr.find() { it == 42 }   # First matching element or 0
first_3 = arr.take(3)
rest = arr.drop(3)

# Explicit params — when names add clarity or multi-param
arr.reduce(0, (acc: Int, x: Int) -> acc + x)

# Free-function style — also works but less idiomatic
doubled = map(arr, x: Int -> x * 2)
```

### Parallel

```quartz
squares = parallel_map(arr, x: Int -> x * x)
parallel_for(items, item: Int -> process(item))
sum = parallel_reduce(arr, 0, acc: Int, x: Int -> acc + x)
```

---

## Error Handling

Quartz provides **two error-handling mechanisms** with distinct purposes:

| Mechanism | Use when | Mental model |
|-----------|----------|--------------|
| `Result<T, E>` | The caller probably has a meaningful local response (parsing, validation, missing-key lookup, file I/O). | **Value-level error** — failure is part of the function's interface. |
| `throw(msg)` (catchable via `with Throws`) | Exceptional condition; recovery (if any) is far up the stack. | **Control-flow-level error** — failure is part of the function's *unwinding* contract. |

`panic(msg)` currently has a nonconforming compatibility path that routes
through a user `Throws` handler when one is installed. The owner-ratified target
makes panic non-recoverable and separate from `throw`; Phase 6 must remove that
catchability and define abort versus emergency cleanup. New code must not rely on
catching panic.

### Decision tree

When writing a function that can fail, ask in order:

1. **Will most callers want to handle this locally?** → `Result<T, E>`. Classic cases: parse errors, validation failures, missing-key lookups, file I/O.
2. **Is this exceptional but recovery is plausible at *some* layer up the stack?** → `throw(msg)`. Classic cases: out-of-memory, unexpected I/O state, contract violations a top-level handler can recover from.
3. **Is this a bug — an invariant the program should never violate?** → `panic(msg)`. Classic cases: array bounds, integer overflow, unreachable code paths reached, assertion failures, internal-state corruption. Do not recover from it.

The distinction between (2) and (3) is semantic: `throw` is recoverable typed
control flow; panic is the non-recoverable stabilization target. The current
shared runtime path is an implementation defect, not the model.

### Result Type

```quartz
def parse(s: String): Result<Int, String>
  # ...
end

# Unqualified variants in match (preferred)
match parse("42")
  Ok(v) => puts("#{v}")
  Err(e) => puts(e)
end

# Or use `is` for quick checks
result = parse("42")
return -1 if result is Err
```

### Throw and Current Panic Nonconformance

`throw(msg)` routes to the nearest `with Throws { throw: handler } do ... end`
block. Current executable behavior also lets `panic(msg)` take that path, as the
following compatibility example demonstrates, but this behavior is scheduled
for removal and must not be used as a recovery contract.

```quartz
import * from std/throws

def my_handler(op: Int, argc: Int, argv: Int): Int
  msg = as_type<String>(load(argv, 0))
  puts("recovered: #{msg}")
  return -1   # Handler return value flows back as the with-block's value
end

def main(): Int
  result = with Throws { throw: my_handler } do ->
    panic("something is very wrong")
    99   # NOT reached — panic unwinds via Throws.throw
  end
  # result == -1; my_handler received "panic: something is very wrong"
  puts("after-with reached")
  return result
end
```

**Current behavior and target:**
- `throw(msg)` is recoverable unwind-style control flow.
- Current `panic(msg)` can be intercepted by `Throws`; target `panic(msg)` cannot.
- The handler receives the message as `argv[0]` (decode via `as_type<String>(load(argv, 0))`).
- The handler's return value becomes the `with` block's value.
- `panic(msg)` prepends `"panic: "` to the message; the handler sees the combined string.
- Without a user `with Throws`, both currently reach a terminating runtime path.

**Picking between `throw` and `panic` at the call site:**
- `throw("connection lost")` — the caller might reasonably retry or fall back.
- `panic("invariant violated: state.count went negative")` — bug; the program must not continue or recover.

### Try-Catch (Result-only sugar)

```quartz
value = try risky_call() catch Err(e) fallback_value

value = try
  risky_call()
catch Err(e)
  handle_error(e)
end
```

`try ... catch Err(e) ...` is sugar for matching on a `Result`. It does NOT catch `throw` / `panic` — for those, use `with Throws`.

### Sentinel Values (legacy)

Pre-`Result` code in some compiler internals uses sentinel return values:

```quartz
idx = lookup(name)
if idx < 0
  return  # Not found
end
```

New code should prefer `Result<T, E>` or `LookupResult` (below).

### LookupResult (new code)

```quartz
match lookup(name)
  LookupResult::Found(v) => use(v)
  LookupResult::NotFound => handle_missing()
end
```

---

## Memory

### Basic

```quartz
ptr = alloc(size)              # Allocate bytes — routes through Alloc effect
dealloc(ptr)                   # Free memory — routes through Alloc effect
ptr = realloc(ptr, new_size)   # Resize (libc-direct; see ALLOC.md)
```

`alloc` and `dealloc` are operations of the `Alloc` algebraic effect, declared
in `std/alloc.qz`. By default they forward to `malloc`/`free`; user code wraps
the call site in `with Alloc { ... } do body end` (or one of the call-form
sugars below) to retarget allocations contextually.

### Alloc Effect

Every allocation in the language flows through the `Alloc` effect. Programs
that don't install a custom handler get the runtime-blessed default
(forwards to `malloc`/`free`, zero overhead via the `__qz_alloc_blessed_watermark`
fast-path). Programs that install a handler observe every alloc/dealloc in
the lexical extent of the body — including stdlib-internal allocations from
`Vec`, `String`, `Map`, struct-heap-init, channels, etc.

```quartz
import std/alloc
import std/memory

# Arena-backed allocation — body's allocations land in `ar`
def parse_phase(src: String): Ast
  var ar = arena_new(16384)
  with Alloc.in_arena(ar) do ->
    var tokens = tokenize(src)
    var ast = parse(tokens)
    return ast
  end
  # arena_destroy(ar) here would free; intentional skip for the example
end

# Sandbox — every alloc throws via Throws (process exits 66 by default)
def run_untrusted(plugin: String): Void
  with Alloc.deny_all() do ->
    plugin_dispatch(plugin)
  end
end

# Budget — total allocations capped at N bytes; throws when exceeded
def with_quota(): Void
  with Alloc.with_budget(64 * 1024) do ->
    work()
  end
end

# Test isolation — singleton arena, reset on each acquire
def run_test(): Void
  with TestAlloc do ->
    setup()
    assert_some_invariant()
  end
end
```

See `docs/ALLOC.md` for the full surface reference (custom handlers, the
static fast-path, env-aware handlers, blessed-default semantics).

### Borrowing

Quartz prevents aliased mutation bugs at compile time using borrows:

```quartz
var x = 42
a = &x                            # Shared (read-only) borrow
b = &x                            # OK — multiple shared borrows

var y = 42
p = &mut y                         # Exclusive (mutable) borrow
# q = &mut y                       # ERROR (QZ1205): only one exclusive borrow

var z = 42
r = &z
# z = 99                           # ERROR (QZ1209): cannot mutate while borrowed
```

**The rule**: Many readers (`&`) OR one writer (`&mut`). Never both.

**Five borrow rules:**
1. Multiple `&` is fine — multiple `&mut` is not (QZ1205)
2. `&` and `&mut` cannot coexist on the same variable (QZ1206)
3. Cannot mutate a variable while it is borrowed (QZ1209)
4. Cannot return a borrow of a local variable (QZ1210)
5. Cannot store a borrow in a struct field (QZ1211)

Borrows are released at last use (NLL-lite). Reassignment also releases borrows.
See `docs/BORROWING.md` for the complete guide.

### Placement Allocation (v5.12+)

Control where data is allocated with `@heap` and `@arena_name`:

```quartz
# Heap allocation - persists until explicitly freed
arr = @heap [1, 2, 3]              # Array on heap
p = @heap Point { x: 10, y: 20 }   # Struct on heap
s = @heap "hello"                  # String copy on heap

# Arena allocation - freed when arena is destroyed
arena scratch do
  arr = @scratch [1, 2, 3]         # Array in arena
  p = @scratch Point { x: 10 }     # Struct in arena
end
```

**When to use @heap:**
- Returning data from functions (outlives scope)
- Long-lived data structures
- Data shared across threads

**Key Properties:**
- `@heap` uses malloc, must be freed with `free()`
- `@arena_name` allocates from named arena
- Strings use strdup for heap copy

### Arenas (v5.0+)

**Low-level intrinsics:**
```quartz
a = arena_new()                # Create (4KB default)
ptr = arena_alloc(a, 64)       # Allocate bytes
p = arena_alloc<Point>(a)      # Typed allocation
arena_reset(a)                 # Reset for reuse
arena_destroy(a)               # Free all
```

**First-class Arena type (v5.1+):**
```quartz
import std/memory              # Arena struct with Drop + Allocator

def main(): Int
  var alloc = arena_create()   # Returns Arena struct
  ptr = alloc.allocate(64)     # Via Allocator trait
  # Arena auto-destroys at scope end via Drop trait
  0
end
```

**Implicit drop glue for nested structs:**
```quartz
struct Context
  alloc: Arena                 # Arena implements Drop
  name: String
end

def main(): Int
  var ctx = Context { alloc: arena_create(), name: "test" }
  # ctx.alloc is automatically dropped even though Context
  # itself doesn't implement Drop - compiler generates "drop glue"
  0
end
```

### Arena Pools (v5.2+)

```quartz
pool = arena_pool_new(2048, 4) # 4 arenas, 2KB each
a = arena_pool_acquire(pool)   # Get an arena
# ... use arena ...
arena_pool_release(pool, a)    # Return (auto-resets)
arena_pool_destroy(pool)
```

### Typed Pointers (v5.2+)

```quartz
ptr_write<Int>(ptr, 42)        # Write typed value
val = ptr_read<Int>(ptr)       # Read typed value
```

### Volatile Access (v5.12+)

```quartz
val = volatile_load<Int>(ptr)       # Read with volatile semantics (not optimized away)
volatile_store<Int>(ptr, 42)        # Write with volatile semantics
```

Volatile prevents the compiler from reordering, coalescing, or eliminating
memory accesses. Use for memory-mapped I/O, hardware registers, or shared
memory where every load/store must actually happen. Supports all types that
`ptr_read`/`ptr_write` support.

### Atomics (v5.0+)

```quartz
atomic_load(ptr)
atomic_store(ptr, val)
atomic_add(ptr, val)
atomic_sub(ptr, val)
atomic_cas(ptr, expected, desired)
```

#### Memory Ordering (v5.12+)

All atomic operations accept an optional last argument for memory ordering.
Omitting it defaults to `seq_cst` (sequential consistency).

Constants: `RELAXED=0`, `ACQUIRE=2`, `RELEASE=3`, `ACQ_REL=4`, `SEQ_CST=5`

```quartz
RELAXED = 0
ACQUIRE = 2
RELEASE = 3
ACQ_REL = 4
SEQ_CST = 5

atomic_load(ptr, ACQUIRE)        # acquire load
atomic_store(ptr, val, RELEASE)  # release store
atomic_add(ptr, val, RELAXED)    # relaxed add
atomic_cas(ptr, exp, new, ACQ_REL) # acq_rel CAS

fence(SEQ_CST)                   # full memory fence
compiler_fence(ACQ_REL)          # compiler-only fence (no hardware barrier)
```

Bootstrap `atomic_compare_exchange` also accepts optional ordering:
```quartz
atomic_compare_exchange(ptr, expected, new_val, ACQ_REL)
```

---

## Concurrency (v5.0+)

### The Four Shapes (D.10)

Concurrency primitives are organized along four orthogonal axes — each
solves a genuinely different problem and the stdlib keeps them in
clearly-named subdirectories so it's obvious where to look.

| Shape | What it solves | Primitives | Subdir |
|---|---|---|---|
| **Communication** | Move values between concurrent units | `Channel`, broadcast (fan-out), oneshot, rendezvous | `std/sync/communication/` |
| **Exclusion** | Serialize access to mutable state | `Mutex<T>`, `RwLock<T>`, `Spinlock`, `Semaphore`, `Barrier`, `WaitGroup` | `std/sync/exclusion/` |
| **Atomicity** | Lock-free single-word state | `AtomicInt` (load/store/cas/add/sub) | `std/sync/atomic/` |
| **Composition** | Coordinate, race, cancel, deadline | `Future`, `select{}`, `Scope`, `Signal`, `Scoped`/`Selectable` traits, `go` family, `parallel_map` | `std/sync/composition/` |

Higher-level abstractions:

- **Actors** (`std/actor.qz`) — Layer 1 for the 95% case. Built on top
  of the four shapes; recommended starting point unless you need raw
  primitives.
- **Scoped resources** (`std/scoped.qz` trait) — `with X do v -> body
  end` releases `X` at end-of-block, throw-safe. Pervasive across
  `std/io/`, `std/net/`, and the exclusion / composition subdirs.
- **Selectable** (`std/selectable.qz` trait) — every `select` arm
  dispatches through this trait. Stdlib impls live alongside their
  underlying resource (`recvable(ch)` in `communication/channel.qz`,
  `deadline_ms(ms)` in `composition/scope.qz`, etc.).

The constructors follow a uniform `Type.new(...)` shape:

```quartz
var ch  = Channel.new(64)
var m   = Mutex.new(0)
var rw  = RwLock.new(0)
var s   = Spinlock.new()
var a   = AtomicInt.new(0)
var wg  = WaitGroup.new()
var oc  = OnceCell.new()
var tok = CancelToken.new()
```

Older free-function constructors (`channel_new`, `mutex_new`, ...) are
still around as the underlying intrinsics; the `Type.new` form is the
preferred surface. Adapter functions used inside `select` arms keep
lowercase free-fn names (`recvable`, `sendable`, `awaitable`,
`deadline_ms`, `cancellable`) — they read as adjectives in arm position
and are not primitives.

### Threads

```quartz
h = spawn(fn)                  # Spawn OS thread
h = spawn_with(fn, arg)        # Spawn with argument
thread_join(h)                 # Wait for completion
```

### Mutex (Mutual Exclusion)

**Preferred form**: use the [Scoped wrapper](#scoped-resources-b8). The
`with`-block guarantees throw-safe release and write-back of mutations.

```quartz
import * from std/sync/exclusion/mutex

var m = mutex(0)               # Mutex<Int>
with m.lock do v ->
  v = v + 1                    # write-back: mutex_unlock(m, v) on exit
end
```

Procedural intrinsics (still available — used inside Scoped impls and for
hot-path code where a `with`-block isn't appropriate):

```quartz
m = mutex_new(0)               # Create mutex with initial value
val = mutex_lock(m)            # Lock, returns protected value
mutex_unlock(m, val + 1)       # Unlock, stores new value
ok = mutex_try_lock(m)         # Non-blocking lock attempt
mutex_free(m)                  # Free resources
```

### Channels (Buffered MPMC)

```quartz
ch = channel_new(16)           # Create buffered channel (capacity 16)
send(ch, 42)                   # Send (blocks if full)
val = recv(ch)                 # Receive (blocks if empty)
ok = try_send(ch, 42)          # Non-blocking send
ok = try_recv(ch)              # Non-blocking receive
val = recv_timeout(ch, 1000)   # Receive with 1s timeout
channel_close(ch)              # Close channel
channel_free(ch)               # Free resources
```

To close-on-block-exit (throw-safe), wrap with [`chan_scope`](#scoped-resources-b8):

```quartz
import * from std/sync/communication/channel
with chan_scope(ch) do h ->
  send(h, 42)
end                            # implicit channel_close on exit
```

### Select — multiplex over Selectables (C.13)

`select` races several *Selectables* and runs the first arm whose
resource is ready. Every arm has the shape `case <pat> = <Selectable>
=> body`, plus an optional `default => body` arm that fires only when
nothing else is ready (non-blocking probe).

```quartz
import * from std/sync/communication/channel
import * from std/sync/composition/scope
import * from std/sync/composition/awaitable
import * from std/sync/exclusion/mutex
import * from std/sync/composition/signal

select
  case v = recvable(ch)        => process(v)
  case _ = sendable(ch2, 42)   => sent_count += 1
  case x = awaitable(task)     => use_result(x)
  case v = try_lockable(m)     => use_locked(v)        # lock now held
  case s = signal_ready(SIGINT) => handle_signal(s)
  case _ = deadline_ms(5000)   => timeout_path()       # throws
  case _ = cancellable(scope)  => cancel_path()        # throws
  default                       => non_blocking_path()
end
```

When no `default` arm is present, `select` blocks until one Selectable
becomes ready. The runtime parks the polling task and consumes ~zero
CPU while parked — every Selectable except `signal_ready` calls
`sched_wake` on the parked frame via the resource-waiter side-table
(`@__qz_waiters`) when its underlying resource changes state. Wake
latency: scheduler round-trip, typically under 5ms wall.

Observation cadence by Selectable (C.13.6, May 2026):

| Selectable | Wake mechanism |
|------------|---------------|
| `recvable(ch)` / `sendable(ch, v)` | Kind-tagged side-table key — recv-waiters park on `@ch`, send-waiters on `@ch \| 1`. Channel handles are 16-byte aligned so the two keys never collide. Every send / recv / try_* / close fires `__qz_waiter_notify_all` on the matching key. Zero spurious cross-direction wakes. Same precision as Go's split recvq/sendq. |
| `awaitable(t)` | Side-table key is the target task frame. `task_done` / `panic_caught` fire `__qz_waiter_notify_all(frame)`. |
| `try_lockable(m)` | Side-table key is the mutex handle. Every `mutex_unlock` fires `__qz_waiter_notify_all(handle)` after the pthread unlock. |
| `deadline_ms(ms)` | Piggybacks on the active scope's pthread cond — `scope_deadline(scope_root(), deadline_ns)` registers the waker. Pre-existing scope-deadline plumbing wakes us. |
| `cancellable(s)` | Piggybacks on the scope's cancel cond. `scope_cancel` wakes every registered waiter. |
| `signal_ready(sig)` | **Polling-only** — 10ms cadence. Can't `sched_wake` from async-signal context. |

The `default` arm short-circuits the park loop entirely — all
Selectables are tried once and if none is ready, `default` fires.

#### Stdlib Selectables (decision tree)

| Selectable | When the arm fires | Binding | Notes |
|------------|-------------------|---------|-------|
| `recvable(ch)` | a value is in `ch`'s buffer | popped value | Destructive — calls `try_recv` and pops. Loser arms on the SAME channel race for the head value. |
| `sendable(ch, v)` | `ch` has buffer space | placeholder `0` | Destructive — value lands in the buffer. Loser arms on the SAME channel race for the slot. |
| `awaitable(t)` | task `t` is done | task's return value | Non-destructive — reads frame slot 1 without consuming. Multiple arms watching the same task all see the same result. |
| `try_lockable(m)` | `mutex_try_lock(m)` succeeds | mutex's protected value (lock now held by current thread!) | Destructive in the lock-acquisition sense — the lock IS held when the arm body runs. Body is responsible for `mutex_unlock`. |
| `signal_ready(sig)` | signal `sig` has fired since last observation | signal number | Polling-only (no active-wake). Cadence ~10ms. |
| `deadline_ms(ms)` | `ms` ms have elapsed since construction | unobservable — `complete` throws `"deadline_exceeded"` | Wrap the `select` in `with Throws { throw: handler } do -> ... end` to catch. `deadline_at_ns(ns)` is the absolute-timestamp variant. |
| `cancellable(s)` | `scope_is_cancelled(s)` is true | unobservable — `complete` throws `scope_cancel_reason(s)` | Same Throws-wrap pattern as `deadline_ms`. |

#### Throw semantics

For Selectables whose `complete` throws (`deadline_ms`, `cancellable`,
future Signal/IoFailed impls), the throw fires **before** the arm
body runs — the body never observes the binding. The user's actual
handling lives in the surrounding `with Throws { throw: handler }`:

```quartz
import * from std/throws
import * from std/sync/composition/scope

def my_handler(op: Int, argc: Int, argv: Int): Int
  var msg = as_string(load(argv, 0))
  log("aborted: " + msg)
  return 0
end

with Throws { throw: my_handler } do ->
  select
    case v = recvable(ch)        => process(v)
    case _ = deadline_ms(5000)   => 0      # never reached; complete throws
  end
  0
end
```

For Selectables whose `complete` is side-effect-only or no-op
(`recvable`, `sendable`, `awaitable`), the bound value flows through
to the body normally.

#### Cancellation-safety contract

Each Selectable's `try_poll` MAY consume the underlying resource:

- **Destructive**: `recvable` (pops queue), `sendable` (pushes value),
  `try_lockable` (acquires lock). Multiple arms on the same resource
  race for it.
- **Non-destructive**: `awaitable` (reads frame), `signal_ready`
  (reads signal-fired flag), `deadline_ms` (compares timestamps),
  `cancellable` (reads cancel flag). Multiple arms on the same
  resource see the same observation; no race.

If two arms in the SAME select observe destructive Selectables on the
SAME resource, the loser's destructive op already happened by the
time the arm was abandoned. For the common one-channel-per-arm case
this is fine. A future `channel_peek` intrinsic + non-destructive
`recvable` variant is filed as a follow-up.

#### Active-wake side-table (C.13.6)

Active-wake routes through a single runtime registry, `@__qz_waiters`,
shaped as `(target_key: i64, waiter_frame: i64)` pairs. `target_key`
is kind-tagged for resources that observe more than one event class:

- Task frame, mutex handle, scope cond — bit 0 clear (single-event).
- Channel handle `\| 0` — read-waiters parked on `recvable`.
- Channel handle `\| 1` — write-waiters parked on `sendable`.
- `channel_close` notifies both keys.

Channel handles come from `malloc`, which returns ≥16-byte alignment,
so the low 3 bits are reliably free for kind-tagging. The encoding
generalizes to up to 4 event classes per resource without colliding
with the handle bits — `RwLock` read/write/upgrade is the obvious
next consumer.

`waiter_register(target, frame)` and `waiter_unregister(target,
frame)` are the user-facing intrinsics every `Selectable.register_waker`
calls. The notify side is wired in codegen — `mutex_unlock`, every
channel op, `task_done`, and `panic_caught` all emit a
`__qz_waiter_notify_all` call after the underlying state change.

### Atomics

```quartz
a = atomic_new(0)              # Create atomic integer
val = atomic_load(a)           # Atomic load
atomic_store(a, 42)            # Atomic store
old = atomic_add(a, 1)         # Add, returns old value
old = atomic_sub(a, 1)         # Subtract, returns old value
old = atomic_exchange(a, 10)   # Exchange, returns old
ok = atomic_cas(a, 10, 20)     # Compare-and-swap
```

### RWLock (Read-Write Lock)

**Preferred form**: use the [Scoped wrappers](#scoped-resources-b8) for
throw-safe release and (on the write side) write-back.

```quartz
import * from std/sync/exclusion/rwlock

var rw = rwlock(0)
with rw.read do v ->           # shared read lock
  inspect(v)
end
with rw.write do v ->          # exclusive write lock; v writes back
  v = compute_next(v)
end
```

Procedural intrinsics:

```quartz
rw = rwlock_new(0)             # Create with initial value
val = rwlock_read(rw)          # Acquire read lock, get value
rwlock_read_unlock(rw)         # Release read lock
old = rwlock_write(rw)         # Acquire write lock, get value
rwlock_write_unlock(rw, 99)    # Store new value, release
rwlock_free(rw)                # Free resources
```

### Task Groups (Thread Pool)

```quartz
task_group |g|                 # Scoped thread pool block
  taskgroup_spawn(g, -> work())
  taskgroup_spawn(g, -> work())
  results = taskgroup_collect(g)  # Wait for all, get Vec<Int>
end
pool_shutdown()                # Shut down pool (optional cleanup)
```

### Scope and Cancellation (B.7)

A **`Scope`** is the dynamic extent of concurrent work. It carries a cancel
flag, an optional deadline, and a parent pointer (forming a tree).
Cancelling a scope auto-cancels all descendants. Deadlines auto-fire (lazily,
on next `is_cancelled` / `check`, plus a proactive timer thread for
zero-jitter observation). Goroutines spawned via `go fn()` inherit the
parent's `current_scope()` at spawn time; the scope-aware blocking
primitives (`scope_sleep_ms`, `scope_recv`, `scope_send`, `scope_lock`,
`scope_rwlock_read`, `scope_rwlock_write`) consult `current_scope()` and
unwind via the unified Throws transport when the scope cancels.

`Scope` lives in [`std/sync/composition/scope.qz`](../std/sync/composition/scope.qz). Import it
with `import * from std/sync/composition/scope` (wildcard — the proactive deadline
timer thread expects `_scope_fire_deadline_exceeded` to bind under its
bare name).

```quartz
import * from std/sync/composition/scope

def main(): Int
  # Create a child scope with a 5-second deadline.
  var s = scope_timeout(scope_root(), 5_000)

  # Run work inside the scope. body sees `s` via current_scope().
  # On normal return, scope auto-cancels; on throw, scope auto-cancels
  # and the throw re-propagates.
  scope_with(s, do_work)
  return 0
end

# Equivalent with-block form (preferred when body is inline):
def main_with(): Int
  with scope_owned(scope_timeout(scope_root(), 5_000)) do _ ->
    do_work()
  end
  return 0
end

def do_work(): Int
  # Inside the scope, scope-aware helpers throw on cancel/deadline.
  scope_sleep_ms(1_000)        # respects deadline; throws on cancel
  var v = scope_recv(my_chan)  # throws on cancel
  scope_lock(my_mtx)           # throws on cancel
  return 0
end
```

#### Constructors

```quartz
scope_root()                  # Root scope (uncancellable; lazily init)
scope_timeout(parent, ms)     # Child with relative-ms deadline
scope_deadline(parent, abs_ns) # Child with absolute-ns deadline
scope_with_cancel(parent)     # Child with no deadline; manually cancellable
scope_supervised(parent)      # Child whose failures don't cascade to siblings
```

The effective deadline of a child is `min(parent_deadline, requested)` —
parents cap their children. A new child registers a proactive deadline
timer iff it is the deadline originator (the parent doesn't already have a
tighter or equal deadline).

#### Inspection

```quartz
scope_is_cancelled(s): Bool      # Lazy-fires deadline; non-throwing read
scope_cancelled_at(s): Int       # Monotonic-ns timestamp at cancel; -1 if not
scope_deadline_remaining_ms(s): Int  # ms until deadline; -1 if none
scope_cancel_reason(s): String   # "cancelled" / "deadline_exceeded" / user reason
scope_is_supervised(s): Bool     # Was created via scope_supervised
```

#### Cancellation

```quartz
scope_check(s)                # Throws cancel reason if cancelled; no-op else
scope_cancel(s)               # Cancel with reason "cancelled"
scope_cancel_with(s, reason)  # Cancel with explicit reason string
```

#### Per-thread current scope

```quartz
current_scope()               # Get TLS current scope (root if not entered)
scope_with(s, body)           # Push s; run body; restore prev; auto-cancel s
                              # Throw-safe: re-throws captured exceptions
                              # after teardown
```

#### Scope-aware blocking primitives

Each helper integrates with the scope's cancel flag (active-wake via
`sched_wake` from the cancel walker, in microseconds) and with the scope's
deadline (chunk size shrinks to deadline-remaining when close):

```quartz
scope_sleep_ms(ms)            # sched_sleep, but throws on cancel
scope_recv(ch): Result<Int, Int>   # try_recv_or_closed loop; Err(0) on closed
scope_send(ch, val)           # try_send loop
scope_lock(m): Int            # mutex_try_lock loop; returns protected value
scope_rwlock_read(rw): Int    # rwlock_try_read loop
scope_rwlock_write(rw): Int   # rwlock_try_write loop; caller unlocks afterward
```

Under root scope (no `scope_with` active), each helper degrades to its
underlying blocking primitive — zero overhead for non-scoped code.

#### Decision tree — Scope vs. CancelToken

Cancellation has two orthogonal axes:

```
Axis 1: who can cancel?
  - just the enclosing block / parent task ────> Scope (structural)
  - any holder of a passable identity ─────────> CancelToken (capability)

Axis 2: how is the cancel-target named?
  - implicit (current_scope, TLS-propagated) ──> with scope_with(...) do ... end
  - explicit (passed as argument) ─────────────> tok = cancel_token_new(); ...
```

Most code lives at **(structural, ambient)** — a goroutine started via
`go fn()` inside a `scope_with(scope_with_cancel(current_scope()), body)`
block inherits the scope automatically; the parent's `scope_cancel(s)` walks
the scope tree and wakes any blocked descendants via `sched_wake`.

The **(capability, explicit)** corner is for patterns where a passable
cancel handle is the right primitive — supervisor restart strategies,
mapreduce-with-early-return, racing for the first success. Use
[Cancel Tokens](#cancel-tokens) (next subsection) for that shape.

#### Open-UFCS dispatch

Every `scope_*` function takes a Scope handle as its first arg, so they
are callable as `s.timeout(ms)`, `s.is_cancelled()`, `s.check()`, etc. via
Quartz's open-UFCS rule.

### Cancel Tokens

The **(capability, explicit)** corner of the decision tree above. A
`CancelToken` is a passable `Atomic<i64>` flag — any code holding the
token can cancel it, and any code holding the token can check whether it's
been cancelled. Used by `supervisor_tree`, `go_cancellable`,
`scope_cancel_on_failure`, and similar primitives where peer-to-peer cancel
or externally-triggered cancel is the right model.

```quartz
tok = cancel_token_new()       # Create token
cancel_token_cancel(tok)       # Signal cancellation
is = cancel_token_is_cancelled(tok)  # Check

tok = cancel_token_with_deadline(5000)  # Auto-cancel after 5s
is_cancelled()                 # Check current task_group scope
cancel_token_free(tok)         # Free resources
```

For (structural, ambient) cancellation — the common case — prefer
[Scope](#scope-and-cancellation-b7) instead. CancelTokens are not legacy;
they are the deliberate corner of the design where the scope's
parent-controlled cascade isn't the right mechanism.

### WaitGroup

```quartz
wg = waitgroup_new(3)          # Wait for 3 operations
waitgroup_done(wg)             # Signal one complete
waitgroup_wait(wg)             # Block until count reaches 0
waitgroup_free(wg)
```

### OnceCell (Lazy Init)

```quartz
cell = oncecell_new()          # Create empty cell
val = oncecell_get_or_init(cell, -> expensive_compute())
val = oncecell_get(cell)       # Get (aborts if uninitialized)
oncecell_free(cell)
```

### Structured Concurrency (`std/concurrency`)

These are thin wrappers around [Scope](#scope-and-cancellation-b7) for
the goroutine-spawning patterns. The canonical entry point is
`with scope_with(scope_with_cancel(current_scope())) do ... end`; the
wrappers below (`go_scope`, `go_supervisor`, `go_scope_timeout`) collect
spawned child handles and `await` them at exit.

```quartz
import concurrency

# go_scope: spawn a body that auto-awaits its goroutine children;
# child panics propagate.
go_scope(-> {
  go work_a()
  go work_b()
})

# go_supervisor: child failures don't cascade to siblings (under
# scope_supervised semantics).
results = go_supervisor(-> {
  go work_a()
  go work_b()
})

# go_scope_timeout: deadline-bounded scope; throws "deadline_exceeded"
# (catchable via `with Throws`) if the body doesn't finish in time.
go_scope_timeout(5000, -> {
  go slow_work()
})
```

For peer-to-peer or externally-triggered cancel patterns (supervisor
restart strategies, racing, mapreduce-with-early-return), use the
capability primitives (`go_cancellable`, `cancel_token_*`,
`supervisor_tree`, `scope_cancel_on_failure`) — see
[Cancel Tokens](#cancel-tokens) above.

### M:N Scheduler (Green Threads)

Lightweight task scheduling with `go` keyword. Tasks are multiplexed onto N OS worker threads via a global queue with kqueue/epoll I/O integration.

```quartz
def worker(id: Int): Int
  puts("worker " + id.to_s())
  return id
end

def main(): Int
  sched_init(4)          # 4 worker threads (0 = auto-detect)

  go worker(1)           # spawn lightweight task
  go worker(2)
  go worker(3)

  sched_shutdown()       # waits for ALL tasks to complete, then cleans up
  return 0
end
```

**I/O Integration:** Tasks that call `io_suspend(fd)` automatically suspend and resume when the fd becomes ready (via kqueue on macOS, epoll on Linux). The scheduler's I/O poller thread handles fd monitoring.

```quartz
def reader(fd: Int): Int
  io_suspend(fd)         # suspend until fd is readable
  # ... read from fd ...
  return 0
end

sched_init(2)
var t = async reader(my_fd)
sched_spawn(t)
sched_shutdown()
```

**Current limitation:** `sched_shutdown()` waits on tracked tasks, but teardown,
forced cancellation, and ownership are not yet a proved safety guarantee.
Interleavings involving bounded supervisor drain and immediate shutdown have
historically hung or faulted; production ordering must follow the focused
supervisor protocol. Stabilization Phase 5 owns the complete lifecycle proof.

### Async/Await

`async`, `await`, `go`, and `for await` are keywords for concurrent programming.

```quartz
# async expr — wraps a function call as an eager Future
# The call executes immediately; the Future holds the result.
var future = async compute(42)

# await expr — extracts the result from a Future or waits for a go task
var result = await future

# go func(args) — spawn a lightweight task on the M:N scheduler
# Requires sched_init() beforehand.
go worker(1)

# for await x in channel — iterate over a channel until it is closed
var ch = channel_new(16)
for await msg in ch
  puts("received: #{msg}")
end
```

**Key semantics:**
- `async expr` creates an eager `Future` — the call runs immediately and the result is stored. The return type is `Int` (the Future handle).
- `await expr` dispatches based on the value: if it is a `Future` (from `async`), extracts the result; if it is a `go` task handle, waits for completion via the scheduler's completion notification system.
- `go func(args)` spawns a green thread on the M:N scheduler. Unlike `async`, the task runs concurrently on a worker thread. Requires `sched_init(n)` before use and `sched_shutdown()` after.
- `for await x in channel` desugars to a loop that calls `recv()` on the channel, breaking when the channel is closed. The loop variable `x` receives each value in turn.

### Actors (C.14)

BEAM-in-a-box. Two pieces compose:

1. The `actor X ... end` keyword — spawns a green-thread task with a private mailbox and synthesizes typed method-call proxies. Per-handler panic recovery preserves state across bad messages. **In the language already** (no import needed).
2. `std/actor.qz` — `Supervisor` and `DynamicSupervisor` for restart-on-death semantics across a set of actors. **Layer 1 stdlib.**

#### Decision tree

```
Need concurrent code? ──────────────────────────────────────────────────────────
│
├─ Single mutable thing, accessed from many callers, request/reply API?
│      → `actor X ... end` (mailbox + typed methods, per-handler crash firewall)
│
├─ Anonymous worker pool (map/reduce, fan-out/fan-in, pipeline)?
│      → `go fn(...)` + channels (lighter; no method dispatch overhead)
│
├─ Need parent-cancel cascade, deadline, racing?
│      → `with scope_with(scope_with_cancel(current_scope())) do ... end`
│
└─ Need restart-on-death semantics (long-running services, "let it crash")?
       → wrap the actor's spawn closure in `Supervisor` / `DynamicSupervisor`

`actor X` alone gets you per-handler crash recovery (one bad call drops its
reply, the actor keeps its state). `Supervisor` gets you process-level
restart (the entire actor respawns with fresh state — OTP semantics).
```

#### `actor X ... end` — the keyword

```quartz
actor Counter
  var count: Int = 0

  def increment(): Void
    count += 1
  end

  def get(): Int = count
end

var c = Counter()        # spawn — returns inbox handle (Int)
c.increment()            # fire-and-forget (no reply expected)
var n = c.get()          # request-reply — blocks on internal reply channel
var ch = c.get_async()   # async proxy — returns reply channel handle

# select-friendly: the async-proxy channel is `recvable`-Selectable
select
  case v = recvable(ch)        => use(v)
  case _ = deadline_ms(100)    => timeout()
end

c.link(c2)               # bidirectional crash-cascade — when one dies, other dies
c.unlink(c2)
c.stop()                 # synchronous stop, returns after handler quits
```

**Semantics:**
- Each method on `actor X` gets four auto-generated proxies: `X$method` (fire-and-forget if `Void`, request-reply otherwise), `X$method_async` (returns reply channel), `X$stop`, `X$link`/`X$unlink`. Dotted method calls resolve to the appropriate proxy.
- The actor's state struct lives in the actor's frame; only its mailbox handle is shared. Per-method send/recv is mailbox-mediated — no shared memory, no manual mutex.
- A panic inside a handler is caught by the scheduler-side actor firewall (`frame[3] == -999` sentinel). The offending reply channel gets a 0; the actor keeps its state and processes the next message. **The actor does NOT die on a handler panic** — you need `actor_die()` (Phase 4 future work) or `.stop()` for that.

#### `Supervisor` — static set of supervised children

For a fixed roster of long-running actors with restart-on-death:

```quartz
import * from actor

actor Echo
  def ping(x: Int): Int = x
end

def spawn_echo(): Int = Echo()

var spawns = vec_new<Fn(): Int>()
spawns.push(spawn_echo)
spawns.push(spawn_echo)
spawns.push(spawn_echo)

# max_restarts=5 within period_ms=10_000 (rolling intensity window;
# OTP-equivalent defaults). On excess, watcher sets `escalated=1` and exits.
var sup = supervisor_new(spawns, 5, 10000)

var e0 = supervisor_child(sup, 0)   # current inbox for child 0 (refreshed across restart)
e0.ping(42)

supervisor_stop(sup)                # synchronous shutdown — cascades to all children
```

**Strategies:**

```quartz
# One restart strategy per supervisor. Use the explicit constructor:
var sup1 = supervisor_with_strategy(spawns, SUPERVISOR_ONE_FOR_ONE,  5, 10000)
var sup2 = supervisor_with_strategy(spawns, SUPERVISOR_ONE_FOR_ALL,  5, 10000)
var sup3 = supervisor_with_strategy(spawns, SUPERVISOR_REST_FOR_ONE, 5, 10000)
```

| Strategy | On a child's death | Use when |
|---|---|---|
| `SUPERVISOR_ONE_FOR_ONE` (default) | Respawn just the dead child | Independent children (workers, isolated services) |
| `SUPERVISOR_ONE_FOR_ALL` | Stop + respawn ALL children | Tight coupling (children share invariants; one death implies all are suspect) |
| `SUPERVISOR_REST_FOR_ONE` | Stop + respawn children at index >= dead | Pipeline (later stages depend on earlier ones) |

**Observability:**

```quartz
supervisor_alive(sup)              # 0 if stopped or escalated past max_restarts
supervisor_restart_count(sup)      # restarts within current rolling window
supervisor_child(sup, i)           # latest inbox for child i (refreshes across restart)
```

#### `DynamicSupervisor` — spawn-on-demand

For homogeneous worker pools where the population grows at runtime. Strategy is fixed `one_for_one` (per Elixir/Broadway — `one_for_all` at scale is a denial-of-service primitive).

```quartz
actor Worker
  def process(job: Int): Int = job * 2
end

def spawn_worker(): Int = Worker()

var dsup = dynamic_supervisor_new(spawn_worker, 5, 10000)

for i in 0..1000
  var w = dynamic_supervisor_spawn(dsup)   # spawn one supervised child
  w.process(i)
end

var n = dynamic_supervisor_alive(dsup)     # current child count
dynamic_supervisor_iter(dsup, w -> puts("inbox=#{w}"))
dynamic_supervisor_stop(dsup)              # synchronous shutdown
```

`DynamicSupervisor` exposes `restart_type` and `backoff` at the supervisor level (not per-child) — the population is homogeneous by construction.

#### Restart types (C.14.4)

Per-child (`Supervisor`) / per-supervisor (`DynamicSupervisor`) policy controlling when a death triggers respawn. Mirrors Erlang/OTP `child_spec.restart`:

| Constant | Behavior | Use when |
|---|---|---|
| `RESTART_PERMANENT` (0, default) | Always respawn, regardless of how the child died | Long-running services (web request handler, message router) |
| `RESTART_TRANSIENT` (1) | Respawn only if the child crashed (panic / abnormal exit). Clean `.stop()` or link-cascade clean exit skips respawn | Workers that have a natural completion path AND can crash mid-job |
| `RESTART_TEMPORARY` (2) | Never respawn | One-shot workers (process this job once; don't resurrect) |

```quartz
supervisor_set_restart_type(sup, 0, RESTART_TRANSIENT)        # per-child
supervisor_set_all_restart_types(sup, RESTART_TRANSIENT)      # all children
dynamic_supervisor_set_restart_type(dsup, RESTART_TEMPORARY)  # all dyn children
```

**How "clean vs crash" is determined:** the auto-generated actor poll loop calls `actor_mark_clean(inbox)` on its stop / cascade-stop paths before closing the inbox. The supervisor watcher consults `actor_check_clean(inbox)` — present → `EXIT_NORMAL`, absent → `EXIT_CRASH`.

**When `Transient` vs `Temporary` matters:** if every supervised actor is fundamentally "stay up forever," leave them `Permanent`. Pick `Transient` for workers that can finish their job AND can also crash — you want clean completion to drop them, panics to respawn them. Pick `Temporary` when respawn would be semantically wrong (the work was a one-shot; resurrecting it would re-do the side effects).

#### `restart_with_backoff` (C.14.5)

Exponential restart backoff with jitter. Akka's `(min_backoff, max_backoff, random_factor)` signature, adapted to integer math (`random_factor_pct` in percent):

```quartz
# 100ms..5s exponential, ±25% jitter. Disabled by default (min=0).
supervisor_set_backoff(sup, 100, 5000, 25)
dynamic_supervisor_set_backoff(dsup, 100, 5000, 25)
```

**State machine:** `current_delay_ms` starts at `min_backoff_ms`. Each respawn sleeps for the current delay (with jitter), then doubles `current_delay_ms` for the next respawn (capped at `max_backoff_ms`). If the child survived longer than `min_backoff_ms` between deaths, `current_delay_ms` resets to `min_backoff_ms` — the new death is "fresh," not part of the same crash storm.

```quartz
supervisor_current_backoff_ms(sup)            # what the next respawn will wait
dynamic_supervisor_current_backoff_ms(dsup)
```

**When `restart_with_backoff` matters:** an upstream dependency keeps glitching (network timeout, occasional contention, transient resource pressure). Without backoff, the supervised actor's intensity window fills in milliseconds and the supervisor escalates. With backoff, deaths get spaced out exponentially — the supervisor stays alive, the actor stays restartable, and intensity remains the final circuit-breaker for failures that aren't actually transient.

**Backoff and intensity are complementary, not alternatives.** Backoff spaces deaths out so a transient-failure storm doesn't trip the circuit-breaker. Intensity is still the answer when something is fundamentally broken — a child crashing in `< min_backoff_ms` repeatedly will still fill the intensity window because backoff never reduces below `min_backoff_ms`.

#### PreRestart hook (C.14.4)

Fires once per respawn, given the dead inbox handle. Bind `Scoped` (B.8) resource release inside the closure:

```quartz
supervisor_on_pre_restart(sup, dead_inbox -> {
  # Release file handles, network sockets, mutex guards held by the dead actor.
  # Hook runs ON THE WATCHER goroutine, not the dead actor's frame.
})

dynamic_supervisor_on_pre_restart(dsup, dead -> log_death(dead))
```

The hook does NOT fire when restart is skipped (`Transient` saw clean, `Temporary` saw any death). Inspect `supervisor_skipped_count(sup)` / `supervisor_pre_restart_count(sup)` (and `dynamic_supervisor_*` equivalents) for telemetry / spec assertions.

#### Surface summary

| Surface | Type | Constructor / entry | Notes |
|---|---|---|---|
| `actor X ... end` | keyword | `X()` returns inbox handle | Per-handler crash firewall (preserves state) |
| `Supervisor` | struct | `supervisor_new(spawns, max_restarts, period_ms)` | Static roster, one_for_one default |
| `Supervisor` | struct | `supervisor_with_strategy(spawns, strategy, max_restarts, period_ms)` | Strategy-explicit form |
| `DynamicSupervisor` | struct | `dynamic_supervisor_new(spawn_fn, max_restarts, period_ms)` | Spawn-on-demand, one_for_one fixed |
| Strategy | const | `SUPERVISOR_ONE_FOR_ONE` / `_ALL` / `REST_FOR_ONE` | |
| Restart type | const | `RESTART_PERMANENT` / `_TRANSIENT` / `_TEMPORARY` | |

**See also:** `std/actor.qz` (the implementation; module-level doc comment is the canonical longform), `docs/design/ACTOR_MODEL.md` (design rationale + Erlang/Akka/Pony survey), `spec/qspec/actor_supervisor_spec.qz` and `spec/qz/actor_*_smoke.qz` (executable examples).

---

## I/O

### Output Functions

| Function | Stream | Newline | Description |
|----------|--------|---------|-------------|
| `puts(s)` | stdout | yes | Print string with trailing newline |
| `print(s)` | stdout | no | Print string without newline |
| `eputs(s)` | stderr | yes | Print to stderr with trailing newline |
| `eprint(s)` | stderr | no | Print to stderr without newline |
| `print_int(n)` | stdout | yes | Print integer with trailing newline |

```quartz
# Standard output
puts("Hello, World!")           # Prints: Hello, World!\n
print("No ")                    # Prints: No  (no newline)
print("newline")                # Prints: newline (same line)
puts("")                        # Just prints newline

# Standard error (for diagnostics/errors)
eputs("Error: file not found")  # Prints to stderr with newline
eprint("Warning: ")             # Prints to stderr without newline
eprint("check config")          # Same stderr line

# Integers
print_int(42)                   # Prints: 42\n
```

**Naming Convention:**
- `puts`/`print` — stdout (standard output)
- `eputs`/`eprint` — stderr (e = error, standard error)
- `-s` suffix means "with newline" (like Ruby's `puts`)
- No suffix means "without newline" (like C's `printf`)

**Implementation:** All I/O functions use unbuffered `write()` syscalls internally. This ensures output
appears in the exact order you call it — no hidden stdio buffering. `print_int` converts to a stack
buffer via `sprintf`, then writes with `write()`.

### File I/O

```quartz
content = read_file(path)      # Read file contents
write_file(path, content)      # Write file
```

For block-scoped opens with throw-safe close (and "w"/"wb"-mode rollback
on throw), see [Scoped Resources](#scoped-resources-b8):

```quartz
import * from std/io/file

with file_scoped("/tmp/out", "w") do f ->
  if f != 0
    file_writeln(f, "hello")
  end
end                            # implicit close + on-throw rollback
```

### CLI Arguments

```quartz
n = argc()                     # Number of args
arg = argv(1)                  # Get arg N as String
env = getenv("PATH")           # Environment variable
```

### File Enumerable

```quartz
lines = file_lines(path)       # Vec of lines
chars = file_chars(path)       # Vec of char codes
bytes = file_bytes(path)       # Vec of bytes
```

---

## Scoped Resources (B.8)

Quartz has two cleanup mechanisms. They are not interchangeable.

| | `trait Drop` | `trait Scoped` |
|---|---|---|
| Lifetime | Owned by a binding; runs when the binding dies | Block-leased; runs when the surrounding `with`-block exits |
| Throw-safety | **No** — drop walk does not run on throw unwind | **Yes** — `release_on_throw` fires on `throw`/`panic` |
| Signature | `def drop(self): Void` | `def acquire(self): R`, `def release(self, v: R): Void`, `def release_on_throw(self, v: R, msg: String): Void` |
| Parameterized release | No | **Yes** (e.g. `mutex_unlock(m, new_value)` writes value back) |
| Stdlib examples | `Arena` | Mutex, RwLock, File, Channel, Scope, Tcp{Stream,Listener}, EventLoop |

`with X do v -> body end` desugars to:

```
v = X.acquire()                                  # implicitly `var v` (Phase 6.5)
with Throws { throw: |msg| ->                    # installed throw handler
  X.release_on_throw(self, v, msg)               #   reads v from its slot at fire time
  rethrow msg
} do ->
  body                                           # caller may reassign `v` inside
  X.release(self, v)                             # only on normal exit
end
```

### Decision tree

```
Need cleanup on block exit (incl. throw)?
├─ Yes → with X do v -> ... end                  # Scoped trait
└─ No, the resource owns itself for its full lifetime
   ├─ Owned by one binding, released when binding dies → Drop trait
   └─ Multiple owners, dynamic lifetime → manual / Rc<T> (future)
```

```
Resource has parameterized release (write-back)?
├─ Yes (mutex_unlock takes value, file path needs rollback, ...) → Scoped
└─ No → either trait works; prefer Drop for "always-on", Scoped for block-scoped lease
```

```
Need to release on error but commit on success (errdefer-style)?
└─ Override Scoped::release_on_throw to release; let release(v) be no-op transfer.
```

### Write-back semantics (Phase 6.5)

The bound `v` is implicitly `var`. Reassignments inside the body propagate
to `release(self, v)` at every exit site (natural fall-through, `return`,
`break`, `continue`, throw):

```quartz
import * from std/sync/exclusion/mutex

var counter = mutex(0)

with counter.lock do v ->
  v = v + 1                  # mutate the snapshot
end
# implicit: mutex_unlock(counter, v) — the new value writes back

with counter.lock do v ->
  return v                   # early-return drains the wrap-stack:
end                          #   release(self, v) STILL fires before return
```

The runtime stores the bound-value slot's *address* (not a snapshot value)
on the TLS Scoped-context stack, so the throw-unwind path also sees the
most recent assignment.

### Stdlib impl matrix

All seven stdlib types ship `impl Scoped`. Construct via the factory in the
left column; pass to `with` to lease.

| Factory | Guard struct | Bound `v` | release | release_on_throw asymmetry |
|---|---|---|---|---|
| `mutex(initial: Int).lock` | `MutexGuard` | protected `Int` | `mutex_unlock(m, v)` (write-back) | symmetric |
| `rwlock(initial: Int).read` | `RwLockReadGuard` | protected `Int` snapshot | `rwlock_read_unlock(rw)` | symmetric |
| `rwlock(initial: Int).write` | `RwLockWriteGuard` | protected `Int` | `rwlock_write_unlock(rw, v)` (write-back) | symmetric |
| `file_scoped(path, mode)` | `FileGuard` | `FILE*` handle (`0` on open failure) | `close_file(v)` | **`"w"` / `"wb"` mode**: also `file_delete(path)` for rollback |
| `chan_scope(handle)` | `ChannelGuard` | channel handle | `channel_close(handle)` | symmetric |
| `scope_owned(s)` | `ScopeGuard` | scope handle | `current_scope_store(prev) + scope_cancel(s)` | symmetric |
| `tcp_stream_scoped(stream)` | `TcpStreamGuard` | fd | `tcp_close(stream)` | symmetric |
| `tcp_listener_scoped(listener)` | `TcpListenerGuard` | fd | `tcp_close_listener(listener)` | symmetric |
| `event_loop_scoped(el)` | `EventLoopGuard` | fd | `event_loop_close(el)` | symmetric |

### Worked examples

```quartz
import * from std/sync/exclusion/mutex
import * from std/sync/exclusion/rwlock
import * from std/sync/communication/channel
import * from std/sync/composition/scope
import * from std/io/file
import * from std/net/tcp
import * from std/net/event_loop

# Mutex — write-back protected counter
var counter = mutex(0)
with counter.lock do v ->
  v = v + 1
end

# RwLock — read-side
var registry = rwlock(0)
with registry.read do v ->
  inspect(v)
end
# RwLock — write-side (write-back)
with registry.write do v ->
  v = compute_next(v)
end

# File — auto-close, "w" mode rolls back on throw
with file_scoped("/tmp/out", "w") do f ->
  if f == 0
    return -1                  # open failed; no release_on_throw fires
  end
  file_writeln(f, "hello")
  if input_invalid()
    throw("invalid")            # close_file + file_delete fire on unwind
  end
end

# Channel — close on exit; receivers see EOF
var ch = channel_new(64)
go consumer(ch)
with chan_scope(ch) do h ->
  for i in 0..10
    send(h, i)
  end
end

# Scope — push/pop current_scope + cancel on exit
var s = scope_with_cancel(scope_root())
with scope_owned(s) do _ ->
  scope_sleep_ms(100)           # respects scope-cancel via Throws
end

# Tcp — listener scoped to block
var listener = tcp_listen("127.0.0.1", 0)
with tcp_listener_scoped(listener) do fd ->
  serve_until_done(fd)
end

# EventLoop — close fd on exit
var el = event_loop_new()
with event_loop_scoped(el) do fd ->
  drive_loop(el)
end
```

### Asymmetric release (errdefer-style)

`File`'s `"w"` / `"wb"` modes ship the canonical asymmetry: normal exit
flushes-and-closes, throw exit flushes-closes-and-unlinks. Apps wanting
custom commit-on-success semantics define a separate guard struct + impl:

```quartz
struct CommitOnSuccess
  path: String
end

extend CommitOnSuccess with Scoped
  def acquire(self): Int = open_file(@path + ".tmp", "w")
  def release(self, value: Int): Void
    close_file(value)
    file_rename(@path + ".tmp", @path)         # commit
  end
  def release_on_throw(self, value: Int, exc_msg: String): Void
    close_file(value)
    file_delete(@path + ".tmp")                # roll back
  end
end
```

### Bare `with X do -> body end`

When no useful bound value exists, drop the binding. The release(0) call
still fires:

```quartz
import * from std/sync/composition/scope

with scope_owned(scope_with_cancel(scope_root())) do _ ->
  do_work()
end
```

(Use `_` rather than no-binding form for a Scoped resource — the no-binding
form is reserved for effect-handler `with`s.)

### Interaction with Drop

If the bound `v` itself implements `Drop`, the existing droppable-stack
machinery still emits `Type$drop` for `v` at the end of body. Scoped's
release runs *outside* that — it's the resource container's cleanup, not
the bound value's. (Concretely: for `with mutex.lock do v -> ... end`,
`mutex.release(v)` runs after the body's drop walk finishes.)

### Reserved-keyword field-name caveat

Don't name guard fields `loop`, `for`, `while`, `is`, `as`, etc. — the
field-list parser doesn't bail on keyword-where-IDENT-expected and the
compiler hangs at 100% CPU + several GiB RES. Use a synonym (`inner`,
`body`, `target`).

### See also

- Full design memo: [`docs/design/SCOPED_RESOURCES.md`](design/SCOPED_RESOURCES.md)
- The trait definition: `std/scoped.qz`
- Concurrency primitives: [Mutex](#mutex-mutual-exclusion), [Channels](#channels-buffered-mpmc), [RWLock](#rwlock-read-write-lock), [Scope](#scope-and-cancellation-b7)
- File I/O: [File I/O](#file-io)

---

## Character Classification

```quartz
is_digit(c)                    # 0-9
is_alpha(c)                    # a-z, A-Z
is_alnum(c)                    # Alphanumeric
is_whitespace(c)               # Space, tab, newline
```

---

## Doc Comments

```quartz
## Adds two numbers together.
##
## @param a - First operand
## @param b - Second operand
## @returns The sum of a and b
## @example
##   add(1, 2)  # => 3
def add(a: Int, b: Int): Int
  return a + b
end
```

Tags: `@param`, `@returns`, `@example`

---

## Type System

### Primitive Types
`Int`, `Bool`, `String`, `Void`, `Float64`, `Float32`

### Unsigned Integer Types
`U8`, `U16`, `U32`

Unsigned types use narrower bit widths (8, 16, or 32 bits). Comparisons on
unsigned types emit unsigned LLVM instructions (`ult`, `ugt`, `ule`, `uge`)
instead of the signed variants used for `Int`. This means `U8` values compare
as 0-255 (not as sign-extended i64). Arithmetic and bitwise operations
automatically use the correct width.

```quartz
x = to_u8(200)
y = to_u8(100)
x > y                     # true — unsigned comparison (200 > 100)
```

### Generic Types
`Array<T>`, `Vec<T>`, `Option<T>`, `Result<T, E>`, `Fn(Args): Return`

### Type Handles
At runtime, all types are `i64`. Vectors, strings, maps are handles (pointers as Int).

### Explicit Type Erasure (v5.12+)

For storing arbitrary types in `Vec<Int>`, use explicit type erasure:

```quartz
# Erase any type to Int for storage
i = as_int_generic(my_struct)      # T -> Int (identity at runtime)

# Recover typed value with explicit type argument
s = as_type<MyStruct>(i)           # Int -> T (identity at runtime)
```

**Pattern: Heterogeneous collection**

```quartz
struct Item
  value: Int
end

var items: Vec<Int> = vec_new()
items.push(as_int_generic(Item { value: 42 }))   # Explicit erasure
items.push(as_int_generic(Item { value: 99 }))

for i in 0..items.size
  var item = as_type<Item>(items[i])             # Explicit recovery
  puts("#{item.value}")
end
```

**Key properties:**
- Both are **identity operations** at runtime (no actual conversion)
- `as_int_generic` accepts any type, returns `Int`
- `as_type<T>` requires explicit type argument in angle brackets
- Makes type erasure visible and greppable (`as_int_generic(` → storage points)

### Union Types

```quartz
type Value = Int | String          # Named union via type alias

def accept(x: Int | String): Int   # Union parameter type
  return 42
end
```

Union values are **constructible and narrowable** (R2.1 termification). A value
of an arm type auto-widens into the union — no wrap ceremony, no `|` in value
position (type-directed construction). Widening is inserted at `let`/`var`,
`return`, argument-pass, and field/element-store sites. At runtime a union is a
tagged `{tag, payload}` cell (`tag = hash(arm type)`).

Narrow back to a member with `if x is T` or `match`; the tag is proved at
runtime and the member value recovered:

```quartz
var x: Int | String = 5            # arm Int auto-widens into Int | String
if x is Int
  puts("recovered #{str_from_int(x)}")   # x is Int here; prints "recovered 5"
end
```

Narrowing also works on field-access subjects (`s.u is Int`):

```quartz
struct S
  u: Int | String
end
var s = S { u: 0 }
s.u = 8
if s.u is Int
  return s.u                       # recovers 8, not the cell pointer
end
```

Union types support subtype relations: `A` is a subtype of `A | B`.

**Status (R2.1):**
- A union **returned** from a function and then recovered as a bare scalar in
  another function (the union-in-return-annotation path) now works end-to-end —
  `union_types_spec` is **15/15 green** (union-return roundtrip landed `c3d89f12`).
- `T | Nil` niche: **DONE for spare-bit arms** — `Bool | Nil`, `&T | Nil`, and
  `NonZero | Nil` fire the niche with ZERO allocation (the tag word is dropped).
  Only boxed-pointer arms (e.g. `String | Nil`) INTENTIONALLY spill to a full
  `{tag, payload}` cell, because the null niche would collide with a `Nil = 0`
  arm value. Extending the niche to boxed-pointer arms is a layout-changing,
  silent-miscompile-hazardous optimization — deliberately deferred, not an
  oversight.

### Intersection Types

```quartz
struct AB
  a: Int
  b: Int
end

# Record intersection — merges to a constructible record { a: Int, b: Int }
def make(): { a: Int } & { b: Int } = AB { a: 20, b: 22 }

def main(): Int
  var r: { a: Int } & { b: Int } = make()
  return r.a + r.b                 # 42
end

# Trait intersection — bound-only, must implement both
def process<T: Eq & Ord>(x: T): Int = 0
```

`record & record` merges the fields into a single constructible record
(`{ a: Int } & { b: Int }` becomes `{ a: Int, b: Int }`) — construct it from any
struct literal carrying those fields, then read the fields directly. Nominal and
trait intersections stay **bound-only** (a static obligation, no distinct
runtime value).

Impossible intersections (e.g., `Int & String`) are detected at compile time
(error QZ0150). Conflicting record field types (same label, different type) emit
QZ0151.

### Record Types

```quartz
struct Point
  x: Int
  y: Int
end

# Structural type — any struct with matching fields satisfies it
def get_x(r: { x: Int, y: Int }): Int = r.x

def main(): Int
  var p: { x: Int, y: Int } = Point { x: 7, y: 9 }   # type-directed construction
  return get_x(p)                                     # 7
end
```

Records are standalone flat-offset value types (fields laid out in a canonical
sorted order, each at a fixed offset — no runtime name→offset map). They are
constructed type-directed from a nominal struct literal whose fields match, and
work in **parameter, `let`/`var`, return, and `Vec<{...}>` element** positions:

```quartz
def make(): { x: Int, y: Int } = Point { x: 7, y: 9 }   # record return
var v: Vec<{ x: Int }> = vec_new()                      # records as elements
```

Width and depth subtyping are enforced structurally: `{ x, y }` satisfies
`{ x }` (extra fields OK); `{ x }` does **not** satisfy `{ x, y }`.

**Current limitations (R2.1):**
- A record-typed `let`/`var` initialised **directly** from a `>16B` nominal
  source value (read without going through a call) is not yet reprojected — use
  the call form, or keep the source `≤16B`. Call-arg, return, and element sites
  are covered.
- The turbofish form `vec_new<{ x: Int }>()` mis-parses; use the annotation
  form `var v: Vec<{ x: Int }> = vec_new()`.
- Bare `{ k: v }` is always a **Map** literal — a record value comes from the
  expected type (type-directed), never a bare brace literal.

---

## Common Patterns

### Guard Clause

```quartz
if x < 0
  return -1
end
# happy path continues
```

### Accumulator Loop

```quartz
var total = 0
for item in items
  total += item.value
end
```

### Builder Pattern

```quartz
# Trailing |> — newlines skipped AFTER the operator
config = Config.new() |>
           set_name("app") |>
           set_debug(true) |>
           build()
```

---

## Standard Library (std/)

| Module | Purpose |
|--------|---------|
| `std/option` | `Option<T>` enum: `Some(value)`, `None`. UFCS: `opt.unwrap_or()`, `opt.is_some()`, `opt.map()`, `opt is Some` |
| `std/result` | `Result<T, E>` enum: `Ok(value)`, `Err(error)`. UFCS: `res.is_ok()`, `res.is_err()`, `res is Ok` |
| `std/iter` | Iterator protocol: `VecIter`, `RangeIter`, adapters, terminal ops |
| `std/collections/*` | Stack, Queue, Deque, LinkedList, PriorityQueue, SortedMap |
| `std/colors` | ANSI terminal colors: `red(s)`, `green(s)`, `bold(s)` |
| `std/traits` | Core traits: Eq, Ord, Hash, Show, Clone, Drop |
| `std/string` | String utilities: StringBuilder, interning |
| `std/json` | JSON parsing: `json_parse(s)` |
| `std/toml` | TOML parsing: `toml_parse(s)` |
| `std/memory` | Arena/pool wrappers |
| `std/net/*` | HTTP client/server |

---

## Common Mistakes

| Wrong | Right | Why |
|-------|-------|-----|
| `import a::b` | `import a/b` | `::` is not the import-path separator (`/` is); `::` IS used as the variant/path separator everywhere else (`Option::Some`, `codegen_util::cg_emit`) |
| `Struct(field: val)` | `Struct { field: val }` | Curly braces, not parens |
| `Pattern => do code end` | `Pattern => { stmts; expr }` | Brace blocks for multi-statement |
| `if s != ""` | `if s != 0` | Strings are Int handles |
| `v.len` or `v.length` | `v.size` | Use `.size` consistently |
| `v.is_empty` | `v.empty?` | Use `?` suffix for predicates |
| `vec_push(v, x)` | `v.push(x)` | Use UFCS style for collections |
| `map_get(m, k)` | `m.get(k)` | Use UFCS style for maps |
| `Some(v)` in match | `Some(v)` | Unqualified variants in match arms |
| `option_is_some(opt)` | `opt.is_some()` or `opt is Some` | Use UFCS or `is` keyword |
| `a\n  + b` (leading binary op) | `a +\n  b` (trailing op) | Leading binary ops start new statement; leading `.` for method chains is OK |
| `x..y` across lines | Keep `..`/`...` on one line | Range ops don't allow continuation |
| `as_int(p)` on a `@value` struct | Pass the struct itself, or `&p` to borrow | `QZ0221`: erasing a `@value` struct to a word reinterprets its identity |

---

## Commands

```bash
# Build & Test
./self-hosted/bin/quake qspec     # Run QSpec test suite
./self-hosted/bin/quake build     # Build compiler (debug mode)
./self-hosted/bin/quake build:release  # Build without debug
./self-hosted/bin/quake fixpoint  # Verify gen1 == gen2

# Compile
./self-hosted/bin/quartz file.qz  # Compile to LLVM IR

# Debug Flags
./self-hosted/bin/quartz --dump-ast file.qz
./self-hosted/bin/quartz --dump-mir file.qz
./self-hosted/bin/quartz --dump-ir file.qz
./self-hosted/bin/quartz --debug file.qz    # DWARF debug info
./self-hosted/bin/quartz --overflow-check file.qz  # Runtime integer overflow detection

# Tools
# `quake format` and `format_check` are disabled and intentionally fail closed.
# The formatter is not shipped; neither command writes source today.
```

---

## FFI (Foreign Function Interface)

### Extern C Functions

Call C functions with `extern "C"`:

```quartz
extern "C" def puts(s: String): Int
extern "C" def malloc(size: Int): CPtr
extern "C" def free(ptr: CPtr): Void
extern "C" def memset(ptr: CPtr, c: Int, n: Int): CPtr

def main(): Int
  puts("Hello from C!")
  return 0
end
```

Floating-point C functions are supported: `F64`/`Float` in an `extern`
signature denote a C `double`, `F32` a C `float` (the `CDouble`/`CFloat`
aliases are equivalent). They are passed and returned through the platform
FP registers — `extern "C" def pow(b: F64, e: F64): F64` works directly.

### C Header Imports

```quartz
cimport "stdlib.h"                 # Curated: maps to std/ffi/stdlib.qz
cimport "stdio.h"                  # Curated: maps to std/ffi/stdio.qz
cimport "string.h"                 # Curated: maps to std/ffi/string_h.qz
cimport "math.h"                   # Curated: maps to std/ffi/math.qz

cimport "mylib.h"                  # Any other header: bindings auto-generated
```

The four headers above map to hand-tuned Quartz FFI stub modules in `std/ffi/`.

**Any other header** is bound automatically (B.11b): the compiler shells out to
`clang -Xclang -ast-dump=json` to read the header, translates the C declarations
into `@value @repr(C)` struct mirrors + `extern "C"` defs, and loads them as a
generated module. The header is resolved relative to the importing file's
directory (and the current directory). `clang` must be on `PATH`.

```c
// mylib.h
typedef struct Point { int x; int y; } Point;
int add(int a, int b);
Point make_point(int x, int y);
```

```quartz
cimport "mylib.h"
def main(): Int
  var p = make_point(3, 4)        # struct-by-value return, real C ABI
  puts(str_from_int(p.x))         # 3
  return 0
end
```

C scalars map to fixed-width Quartz types (`int`→`I32`, `unsigned char`→`U8`,
`long`→`I64`, `float`→`F32`, `double`→`F64`, `size_t`→`U64`, any pointer→`CPtr`).
Struct-by-value params/returns work across the full C ABI (small/large, both
architectures).

**Enums** are translated: each C enumerator becomes a module-level `const`, and
an enum-typed argument/return/field maps to `I32` (C int rank). Named
(`enum Tag {...}`) and typedef'd anonymous (`typedef enum {...} Mode;`) enums are
both supported; implicit values increment from the previous enumerator.

```c
// mylib.h
enum Status { OK, WARN = 5, ERR };   // OK=0, WARN=5, ERR=6
int status_code(enum Status s);
```

```quartz
cimport "mylib.h"
def main(): Int
  return status_code(ERR)            # ERR == 6, passed as a C int
end
```

**Object-like `#define` constants** are translated to module-level `const`s
(integer, hex, and float literals; C integer suffixes like `UL` are stripped).
**String `#define`s** (`#define NAME "text"`, a single double-quoted literal)
also become string `const`s. Function-like macros (`#define SQ(x) ...`),
expression macros, char literals, and adjacent-string concatenation (`"a" "b"`)
are *not* translated — they become `# cimport:` comments.

```c
// mylib.h
#define MAX_CONN 64
#define FLAG_RW  0x6
#define BANNER   "mylib v1"
```

```quartz
cimport "mylib.h"
def main(): Int
  return MAX_CONN + FLAG_RW          # 64 + 6
end
```

**Typedef aliases** are resolved through to the underlying type wherever they
appear (parameter, return, or struct field), including alias-of-alias chains. A
`typedef unsigned int Uint32;` lets `Uint32` be used in any signature and maps to
`U32`; a pointer alias (`typedef char *CString;`) maps to `CPtr`.

**Pointer struct fields** are translated and cross the C boundary by value: a
field of pointer type (`int *`, `const char *`, `void **`, …) maps to `CPtr`, an
8-byte word the ABI treats identically to a wide integer.

```c
// mylib.h
typedef struct Span { int *data; int len; } Span;
int span_sum(Span s);              // pointer field, struct passed by value
```

Constructs not yet translated — unions, function pointers, variadics, bitfields,
and structs with *nested-struct* fields — are emitted as `# cimport:` comments
rather than incorrect bindings; bind those by hand with an `extern "C"`
declaration. Note: a struct passed to/from C **by value** must be
declared **both** `@value` and `@repr(C)` (this is what `@cImport` generates) —
`@repr(C)` alone is not enough for the by-value C ABI.

### CPtr Type

`CPtr` is the Quartz type for C pointers. It represents a raw memory address.

### FFI Intrinsics

| Intrinsic | Signature | Description |
|-----------|-----------|-------------|
| `cstr_to_string` | `(CPtr): String` | C string to Quartz String |
| `string_to_cstr` | `(String): CPtr` | Quartz String to C string (strdup) |
| `cptr_to_string_with_len` | `(CPtr, Int): String` | Buffer with length to String (handles embedded nulls) |
| `cptr_to_int` | `(CPtr): Int` | Pointer to integer |
| `int_to_cptr` | `(Int): CPtr` | Integer to pointer |
| `ptr_add` | `(CPtr, Int): CPtr` | Pointer arithmetic |
| `ptr_write_byte` | `(CPtr, Int): Void` | Write byte at pointer |
| `ptr_read_byte` | `(CPtr): Int` | Read byte at pointer |
| `qz_malloc` | `(Int): CPtr` | Allocate memory |
| `qz_free` | `(CPtr): Void` | Free memory |
| `volatile_load<T>` | `(CPtr): T` | Volatile read (not optimized away) |
| `volatile_store<T>` | `(CPtr, T): Void` | Volatile write (not optimized away) |
| `field_offset<T>` | `(String): Int` | Byte offset of field in `@repr(C)` struct (compile-time) |

### Float Conversion Intrinsics

| Intrinsic | Signature | Description |
|-----------|-----------|-------------|
| `to_f64` | `(Int): Float64` | Integer to 64-bit float |
| `to_f32` | `(Int): Float32` | Integer to 32-bit float |
| `to_int` | `(Float64): Int` | 64-bit float to integer (truncates) |

```quartz
pi = to_f64(355) / to_f64(113)  # 3.14159...
n = to_int(pi)                   # 3 (truncates toward zero)
half = to_f32(1) / to_f32(2)    # 0.5 as Float32
```

**NaN/Inf behavior:** `to_int` on NaN or Inf returns an implementation-defined value (LLVM `fptosi` poison).

**Float → String (shortest round-trip).** `to_str(f)`, string interpolation `#{f}`,
`puts(f)`, `+` concat-coercion, and `f.to_s()` all format a float as its *shortest
decimal that round-trips* — the fewest digits that parse back to the exact same IEEE
value. This is a pure-Quartz Dragon4 formatter (`std/fmt/float.qz`, prelude-imported),
not C `printf("%g")`: it is exact (no 6-significant-figure truncation) and freestanding
(no libc). NaN/±Inf print as `nan`/`inf`/`-inf`.

```quartz
puts(to_str(0.1))           # 0.1        (not 0.10000000000000001)
puts("#{1.0 / 3.0}")        # 0.3333333333333333
puts((0.1 + 0.2).to_s())    # 0.30000000000000004  (round-trips exactly)
```

### Struct Field Offsets

Query the byte offset of fields in `@repr(C)` structs at compile time:

```quartz
@repr(C)
struct Point
  x: CInt    # 4 bytes
  y: CInt    # 4 bytes
end

offset_y = field_offset<Point>("y")  # Returns 4
```

**C ABI alignment:**
```quartz
@repr(C)
struct Padded
  a: CChar   # 1 byte at offset 0
  b: CInt    # 4 bytes at offset 4 (padded)
  c: CLong   # 8 bytes at offset 8
end

field_offset<Padded>("b")  # Returns 4 (not 1, due to alignment)
```

### Packed Structs

Use `@packed` to suppress alignment padding. Fields are laid out contiguously:

```quartz
@packed
struct Dense
  a: CChar   # 1 byte at offset 0
  b: CInt    # 4 bytes at offset 1 (no padding!)
  c: CLong   # 8 bytes at offset 5
end

field_offset<Dense>("b")  # Returns 1 (not 4)
```

Combine with `@repr(C)` in any order:

```quartz
@repr(C) @packed
struct Wire
  tag: CChar
  payload: CLong
end

# Or equivalently:
@packed @repr(C)
struct Wire2
  tag: CChar
  payload: CLong
end
```

`@packed` emits LLVM packed struct types (`<{ i8, i32, i64 }>` instead of `{ i8, i32, i64 }`), ensuring no padding between fields. Useful for binary protocols and memory-mapped I/O.

### Conditional Compilation

Use `@cfg` to include definitions only for specific platforms. Non-matching definitions are skipped entirely during parsing.

```quartz
@cfg(os: "macos")
def open_file(path: String): Int
  return syscall(SYS_OPEN_NOCANCEL, path, O_RDONLY, 0)
end

@cfg(os: "linux")
def open_file(path: String): Int
  return syscall(SYS_OPEN, path, O_RDONLY, 0)
end
```

**Available conditions:**

| Condition | Values |
|-----------|--------|
| `os` | `"linux"`, `"macos"`, `"windows"`, `"freebsd"` |
| `arch` | `"x86_64"`, `"aarch64"`, `"arm"`, `"riscv64"` |
| `pointer_width` | `"32"`, `"64"` |

**Applies to:** `def` (block and endless), `struct`, `enum`, `type`, `newtype`

```quartz
@cfg(os: "macos")
struct MacHandle
  value: Int
end

@cfg(os: "linux")
struct LinuxHandle
  fd: Int
end

@cfg(os: "macos")
type Handle = MacHandle

@cfg(os: "linux")
type Handle = LinuxHandle

@cfg(arch: "aarch64")
def get_arch(): Int = 1

@cfg(arch: "x86_64")
def get_arch(): Int = 2
```

**Combinable with other attributes:**

```quartz
@cfg(os: "macos")
@repr(C)
@packed
struct WireFormat
  tag: CChar
  payload: CInt
end
```

**Key properties:**
- Evaluated at parse time — non-matching code is never parsed
- Single key-value pair per `@cfg`: `@cfg(key: "value")`
- `not:` is supported (e.g., `@cfg(not: os: "wasi")`). `any:` is planned but not yet implemented
- Cross-compilation `--target` flag is planned but not yet implemented

### Memory Management

```quartz
def main(): Int
  # Allocate 64 bytes
  buf = qz_malloc(64)
  
  # Write/read bytes
  ptr_write_byte(buf, 42)
  val = ptr_read_byte(buf)
  
  # Pointer arithmetic
  ptr_write_byte(ptr_add(buf, 1), 99)
  
  # Free when done
  qz_free(buf)
  return 0
end
```

### String Interop

```quartz
extern "C" def strlen(s: CPtr): Int

def main(): Int
  # Quartz to C
  cstr = string_to_cstr("hello")
  len = strlen(cstr)
  
  # C to Quartz (with length for embedded nulls)
  buf = qz_malloc(5)
  ptr_write_byte(buf, 104)  # 'h'
  ptr_write_byte(ptr_add(buf, 1), 105)  # 'i'
  s = cptr_to_string_with_len(buf, 2)
  
  qz_free(buf)
  return 0
end
```

### Inline Assembly

#### Basic: `@c()` Escape Hatch

Low-level inline assembly using LLVM asm. Returns `Int`. Operands referenced as `$0` (output), `$1`, `$2`... (inputs):

```quartz
# No inputs — just runs asm
x = @c("nop")

# With inputs — $0 = output register, $1 = a, $2 = b
def add_asm(a: Int, b: Int): Int
  return @c("add $0, $1, $2", a, b)
end
```

#### Extended: `@asm()`

Structured inline assembly with named sections for outputs, inputs, and clobbers:

```quartz
@asm("template",
  output: constraint = var,
  input: constraint = expr,
  clobbers: reg1, reg2)
```

**Constraint keywords:**

| Constraint | LLVM | Meaning |
|------------|------|---------|
| `reg` | `r` / `=r` | Any general-purpose register |
| `x0`..`x30` | `{x0}` | Specific ARM64 register |
| `w0`..`w30` | `{w0}` | Specific 32-bit register |
| `imm` | `i` | Immediate integer |
| `mem` | `m` | Memory operand |

**Clobber names:** `memory`, `cc`, or any register name (`x0`, `x9`, etc.)

**Examples:**

```quartz
# Input only — result in expression return value
result = @asm("add $0, $1, $2", input: reg = a, reg = b)

# Output to variable
var sum = 0
@asm("add $0, $1, $2", output: reg = sum, input: reg = a, reg = b)

# With clobbers
@asm("nop", clobbers: memory, cc)

# Specific register
@asm("mov $0, $1", input: x0 = value)

# All sections
@asm("add $0, $1, $2",
  output: reg = result,
  input: reg = a, reg = b,
  clobbers: cc)
```

#### `@naked` Function Attribute

Functions marked `@naked` emit no prologue/epilogue — the function body must handle everything via inline assembly:

```quartz
@naked
def syscall_exit(code: Int): !
  @c("mov x0, x1; mov x16, #1; svc #0x80")
end
```

**Rules:**
- No alloca/variable setup emitted by compiler
- Function body should be pure inline asm
- Must handle its own return (`ret` instruction)
- Emits LLVM `naked` attribute on the function

---

## Project Structure

```
quartz/
  self-hosted/             # Quartz compiler (fully self-hosted)
    quartz.qz              # Entry point, CLI
    resolver.qz            # Module resolution
    frontend/              # Lexer, parser, AST, macros, derive
    middle/                # Type checking, diagnostics, inference
    backend/               # MIR lowering, codegen, domtree
    shared/                # Build cache, interning
    error/                 # Error explanations
    bin/quartz             # Compiled binary
  std/                     # Standard library
    collections/           # Stack, Queue, Deque, LinkedList, PriorityQueue, SortedMap
    net/                   # HTTP client/server
    json/                  # JSON parser/stringify
    colors.qz, traits.qz, iter.qz, memory.qz, string.qz
  tools/
    fmt.qz                 # Formatter
    lint.qz                # Linter
    quake.qz               # Quake build system launcher
  Quakefile.qz             # Build task definitions
  spec/                    # Test suites
    qspec/                 # QSpec native tests (*_spec.qz) — primary
  docs/
    QUARTZ_REFERENCE.md    # Language reference
    INTRINSICS.md          # Semantic primitives
    ARCHITECTURE.md        # Compiler pipeline
    STYLE.md               # Code conventions
```

---

## Limits

| Limit | Value |
|-------|-------|
| MAX_TOKENS | 65536 per file |
| MAX_SOURCE_SIZE | 524288 bytes (512KB) per file |
| Struct/function fields/params | 64 (MAX_PARAMS) |

---

## Milestone History

The labels through `v5.12` below are historical. Later work is dated rather than
assigned an impossible shipped version above the current `5.12.21-alpha` value.

| Milestone | Highlights |
|-----------|------------|
| v1.0 | Type checking, const-by-default, first-class functions, self-hosting |
| v2.0 | Feature parity, hierarchical imports, fixpoint validation |
| v3.0 | Full type inference |
| v4.0 | DWARF debug info, type checker parity |
| v5.0 | Traits, parallel iteration, pipelines, list comprehensions |
| v5.1 | Generic trait bounds, module.function() calls, quartz.toml manifest |
| v5.2 | Arena pools, typed pointers, postfix guards, defer statement |
| v5.3 | String sweetness, collection literals, unified API (.size, .clear) |
| v5.4 | Parameterized types (Vec<T>, Map<K,V>), type safety |
| v5.5 | Macro system (quote/unquote, hygiene, variadic), prelude auto-import |
| v5.9.9 | Built-in macros ($try, $unwrap, $assert, $debug), return→Never in match arms |
| v5.10 | Closures (capture by value), nested closures |
| v5.12 | Explicit type erasure (`as_int_generic`, `as_type<T>`), Vec<Int> UFCS |
| February 2026 language work | Float conversions (`to_int`, `to_f64`, `to_f32`), `@packed` structs, bit manipulation intrinsics (`popcount`, `clz`, `ctz`, `bswap`, `rotl`, `rotr`), conditional compilation (`@cfg`) |
| April-May 2026 language work | Option/Result UFCS (`.unwrap_or()`, `.is_some()`, `.map()`), `is` keyword (`opt is Some`), implicit `it` parameter (`{ it > 0 }`), unqualified enum variants in match, `<<` shovel operator, collection ops (enumerate, zip, partition) |
