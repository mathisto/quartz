# Quartz Style Guide

> The code is the interface. Make it beautiful.
>
> **v5.12.21-alpha** (per `VERSION`) | Last updated March 2026

---

## Philosophy

Quartz was built on a single heresy: systems code should be *pleasant to read*.

1. **Const by default** — Immutability is the happy path. `var` is the exception, not the rule.
2. **Say what you mean** — If there's a shorter, clearer way, use it.
3. **Types govern representation** — Runtime layout is type-directed; do not
   erase typed values to `Int` unless an explicitly documented low-level boundary
   requires it.
4. **Noise is a bug** — Every character should earn its place.

---

## At a Glance

This is what idiomatic Quartz looks like:

```quartz
Point { x, y } = get_origin()

squares = [n * n for n in 0..10]

name = user?.profile?.name ?? "Anonymous"

return Err("invalid") if input.empty?

return 0 if opt is None

val = opt.unwrap_or(default)

evens = items.filter() { it % 2 == 0 }

config = data |> parse |> validate |> build

def double(x: Int): Int = x * 2
```

If your code doesn't look like this, keep reading.

---

## The Idiomatic Cheat Sheet

When multiple valid forms exist, Quartz picks a winner. This is that
list. Use it as the reference for READMEs, marketing samples, demos,
docs, and any code you generate. If the prescribed form doesn't work
for your situation, you're free to use the alternative — but the
prescribed form is the default, and deviating from it should have a
reason you can name.

| Idiom | Prescribed | Avoid | Why |
|---|---|---|---|
| Binding | `x = 5` | `var x = 5` (when unmutated), `let x = 5` (no such keyword) | Const is the default. `var` is the *signal* that mutation is coming. |
| Mutation | `var n = 0` | `let mut n = 0` | Quartz has `var`, not `let`/`mut`. |
| Function def | `def double(x) = x * 2` | `def double(x: Int): Int = x * 2` (unless at an API boundary) | Inference wins. Annotate when the signature documents intent for callers. |
| Zero-arg def | `def pi = 3.14159` | `def pi(): Float = 3.14159` | Parens vanish when there are no params. Callers still write `pi()`. |
| Return type | `def greet(name) = "Hello, #{name}"` | `def greet(name) -> String` | No `->`. Return type goes after `:`, and only when you annotate at all. |
| Lambda body | `items.filter() { it > 0 }` | `items.filter(x -> x > 0)`, `items.filter() \|x\| x > 0` | Implicit `it` is the default. |
| Lambda with named param | `items.map(user -> user.active_since)` | `items.map() { it.active_since }` (when name clarifies intent) | Use `x -> expr` *only* when the name documents what `x` is, or when you need 2+ params. |
| Interpolation | `puts("Hello, #{name}!")` | `puts("Hello, " + name + "!")`, `puts(format("Hello, %s!", name))` | `#{}` is the canonical interpolator. |
| Variant test | `return 0 if opt is None` | `opt.is_none()`, `match opt \| None => 0 \| _ => ...` (for a single-arm test) | `is` is the predicate form. Reserve `match` for multi-arm dispatch. |
| Unwrap | `val = opt.unwrap_or(default)` | `if opt is Some; val = opt!; else ...` | Method form reads left-to-right and composes. |
| Propagate error | `value = try parse_int(s)` | `$try(parse_int(s))` (retired), postfix `?` (retired) | `try` prefix is the marker; both legacy forms were retired in the Piezo landing. |
| Assert unwrap | `x = opt!` | `x = opt.unwrap()` | `!` means "I proved this; crash if wrong." Not catchable. |
| Method call | `v.push(x)`, `m.get(k)` | `vec_push(v, x)`, `map_get(m, k)` | UFCS method style. Free-function style is legacy. |
| Nil-safety | `port = config?.port ?? 8080` | `port = if config != null and config.port != null then config.port else 8080` | `?.` + `??` compose cleanly; spell out the chain. |
| Safe navigation | `name = user?.profile?.name ?? "Anon"` | manual null checks at each level | Chain as deep as you need. |
| For-in | `for x in items` | `var i = 0; while i < items.size()` | Use the high-level iterator. Reach for index only when you need the index. |
| Enumerate with index | `for (i, x) in items.enumerate()` | `for i in 0..items.size(); x = items.get(i)` | Destructure the pair. |
| Range | `for i in 0..n` | `var i = 0; while i < n; i += 1; end` | Ranges are the canonical counted loop. |
| Qualified variant | `match opt \| Some(v) => ... \| None => ...` | `match opt \| Option::Some(v) => ... \| Option::None => ...` | Unqualified is the default when unambiguous. Qualify only when a variant name collides with another in-scope enum (e.g. a custom `Opt::None` when stdlib `Option::None` is also in scope). |
| Struct literal | `Point { x: 3, y: 4 }` | `Point::new(3, 4)`, `point_new(3, 4)` | Literal construction is the default; constructors are for invariants. |
| Predicate name | `empty?`, `some?`, `ok?` | `is_empty()`, `is_some()`, `is_ok()` | `?` suffix reads as English. |
| Mutator name | `push!`, `clear!`, `sort!` (if defined as banged) | N/A — banged suffix is a convention marker | `!` marks "this mutates its receiver." |
| Pipeline | `data \|> parse \|> validate \|> build` | `build(validate(parse(data)))` | Read left-to-right, data first. |
| Comprehension | `squares = [n * n for n in 0..10]` | `squares = (0..10).map() { it * it }.to_vec()` (works, but verbose) | List comprehension is shorter for "transform a range into a vec." |
| Destructuring | `Point { x, y } = origin` | `x = origin.x; y = origin.y` | Single-line unpack. |
| Struct field access inside impl | `@x`, `@name` | `self.x`, `self.name` (allowed, but @-form is idiomatic) | The `@`-prefix is the impl-block sigil. |
| `@value` struct | `@value struct Token \| kind: Int \| span: Int end` | Heap-allocate small value types | Use `@value` for small, copyable aggregates. |
| Endless def for one-liners | `def sum(v) = v.fold(0) { it.0 + it.1 }` | Block form with explicit `return` for trivial functions | Endless def disappears when the body is one expression. |
| Zero emojis in code | always | never | Emojis are for docs UX, not source. |

**The underlying pattern:** Quartz has invested heavily in making the
most common thing the shortest thing. If you're typing something that
feels longer than it should, check this table before committing.

---

## Naming

| Element | Convention | Example |
|---------|------------|---------|
| Functions | `snake_case` | `parse_token`, `emit_ir` |
| Variables | `snake_case` | `token_count`, `current_node` |
| Types | `PascalCase` | `Token`, `AstNode`, `TypeChecker` |
| Enum variants | `PascalCase` | `Some`, `None`, `IntLit` |
| Type parameters | Single uppercase | `T`, `U`, `E`, `K`, `V` |
| Newtypes | `PascalCase` | `UserId`, `Meters` |
| Modules | `snake_case` | `import frontend/lexer` |
| Traits | `PascalCase` | `Eq`, `Ord`, `Hash`, `Show` |
| Constants | `SCREAMING_SNAKE` | `const MAX_SIZE = 1024` |

### Predicates and Mutators

`?` for questions. `!` for mutations. No exceptions:

```quartz
v.empty?             # Bool — "is it empty?"
opt.some?            # Bool — "does it hold a value?"
c.digit?             # Bool — "is it a digit?"

v.clear()            # Void — mutates in place
```

### Abbreviations

**Use freely:** `ctx`, `idx`, `len`, `buf`, `ptr`, `fn`, `arg`, `val`, `str`, `num`
**Spell out:** `process`, `manager`, `helper`, `user`, `config`
**Loop vars:** `i`, `j`, `k`, `n`, `x`

---

## Formatting

- **2 spaces.** No tabs. No debate.
- **100 character** line limit.
- **Space around operators:** `a + b`, `x: Int`, `f(a, b)`
- **One blank line** between top-level definitions.
- **No blank line** after `def` or before `end`.

### Newlines Are Statements

Newlines terminate statements. Continue with trailing operators or leading dots:

```quartz
# Trailing operator continues
total = a +
  b +
  c

# Leading dot chains
result = data
  .parse()
  .validate()
  .save()

# Pipeline continuation
config = Config.new() |>
  set_name("app") |>
  build()
```

---

## Functions

### Endless Def

**Always** use endless def for single-expression functions. This is the signature Quartz style.
Omit type annotations when inference handles it — annotate only at API boundaries or when it aids readability:

```quartz
# Preferred — let inference work
def double(x) = x * 2
def is_valid(n) = n > 0 and n < 100
def greet(name) = "Hello, #{name}!"
def pi = 3.14159

# Annotate at API boundaries or for clarity
def origin(): Point = Point { x: 0, y: 0 }
def apply(f: Fn(Int): Int, x: Int): Int = f(x)
```

Zero-arg functions don't need parens in the definition (callers still use `pi()`, `origin()`):

```quartz
def default_port = 8080
def version = "1.0.0"
```

### Block Form

Multi-statement functions use `def`/`end` with explicit `return`:

```quartz
def process(items: Vec<Item>): Int
  return 0 if items.empty?
  var count = 0
  for item in items
    continue unless item.valid?
    count += 1
  end
  return count
end
```

### First-Class Functions

Functions are values. No wrappers, no ceremony:

```quartz
def double(x: Int): Int = x * 2
result = apply(double, 21)    # 42
```

### Compile-Time Functions

```quartz
const def square(n: Int): Int = n * n
const AREA = square(8)
static_assert(AREA == 64, "area must be 64")
```

---

## Lambdas

Arrow syntax. That's it.

```quartz
# Nullary
tick = -> 42

# One param
double = x -> x * 2

# Multiple params
add = (x, y) -> x + y

# Typed when needed
transform = x: Int -> x * x
```

### Trailing Blocks

Lambdas as the last argument get special syntax:

```quartz
# Single-line: curly braces — prefer implicit `it` for single-param
items.each() { puts(it.to_s()) }
count = items.filter() { it > 0 }.size
items.map() { it * 2 }

# Explicit param when the name adds clarity
users.filter() { user -> user.active? }

# Multi-line: do...end (always use explicit param names)
items.map() do item ->
  name = item.name
  "Hello, #{name}!"
end
```

**Convention:** `{ }` for one-liners, `do...end` for multi-line. Prefer implicit `it` in short curly blocks.

### Closures

Lambdas capture by **value** at creation time:

```quartz
def make_adder(n: Int): Fn(Int): Int = x -> x + n

add5 = make_adder(5)
add5(3)    # 8
```

Mutation after capture does *not* affect the closure.

---

## Variables and Bindings

### Const by Default

```quartz
x = 5             # immutable
var y = 10         # mutable — explicit opt-in
y += 1             # OK
# x = 10           # ERROR
```

**Rule:** Default to immutable. Reach for `var` only when you must reassign.

### Compound Assignment

Always. No exceptions:

```quartz
count += 1         # not count = count + 1
total -= discount
index *= 2
```

### Type Inference

Let the compiler work. Quartz infers types for variables, function parameters, and return types:

```quartz
# Variables — always inferred
count = 0                # Int
name = "Quartz"          # String
items = vec_new()        # Vec — generic until used

# Parameters — inferred as Int (existential erasure)
def double(x) = x * 2
def add(a, b) = a + b

# Return types — omit unless you need to enforce a specific type
def greet(name) = "Hello, #{name}!"
```

Annotate only at module boundaries, for complex types, or when it aids readability:

```quartz
# Complex types that benefit from annotation
var buffer: Vec<String> = vec_new()
def connect(host: String, port: Int, timeout: Int): Connection
```

### Destructuring

Decompose structs and vecs in a single binding:

```quartz
# Struct — type name required for immutable
Point { x, y } = get_point()

# Mutable — var keyword
var Point { x, y } = get_point()
var { x, y } = get_point()              # type inferred

# Rename fields
Point { x: px, y: py } = get_point()

# Partial — ignore the rest
Point3D { x, .. } = get_3d()

# Vec
[first, second, third] = my_vec
[head, ..tail] = my_vec                 # rest binding
[only, ..] = my_vec                     # head only

# In for-in loops
for Point { x, y } in points
  draw(x, y)
end

# In match arms
match point
  Point { x, y } => x + y
  { x, y } => x + y                     # inferred type
end
```

---

## Control Flow

### Postfix Guards

The single most important style rule in Quartz. **Flatten everything:**

```quartz
def process(node: Int): Int
  return 0 if node == 0
  return -1 unless is_valid(node)
  # main logic — no nesting
end

for item in items
  continue unless item.active?
  break if item.terminal?
  process(item)
end
```

Postfix guards work with `return`, `break`, and `continue`:

```quartz
return value if condition
return value unless condition
break if done
continue unless relevant
```

**Never nest** when a guard will do.

### If / Elsif / Else

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

Reads better than `if not`:

```quartz
unless logged_in
  redirect("/login")
end
```

### Pattern Matching

Prefer `match` over `if/elsif` chains. Use **unqualified variants** (no `Option::` prefix):

```quartz
# As expression — no semicolons, no braces, just arms
size = match level
  Low => 5
  Medium => 10
  High => 20
end

# Destructuring — unqualified variants (preferred)
match option
  Some(v) => v                    # not Option::Some(v)
  None => 0                       # not Option::None
end

# For simple variant checks, prefer `is` keyword over match
return 0 if opt is None
return -1 if result is Err

# For simple unwrap, prefer .unwrap_or() over match
val = opt.unwrap_or(0)            # not: match opt { Some(v) => v / None => 0 }
```

# Guards
match value
  n if n > 100 => "big"
  n if n > 0 => "small"
  _ => "zero or negative"
end

# Multi-statement arms
match choice
  A => {
    var g = Guard { id: 1 }
    process(g)
    result
  }
  B => simple_expr
end

# Struct patterns
match point
  Point { x, y } => x + y
end

# String and regex
match token
  "def" => TOK_DEF
  "end" => TOK_END
  ~r"\d+" => TOK_NUMBER
  _ => TOK_IDENT
end
```

### Loops

```quartz
# Range — preferred for counted iteration
for i in 0..10           # 0 to 9 (exclusive)
  process(i)
end

for i in 0...5           # 0 to 5 (inclusive)
  process(i)
end

# Collection
for item in items
  process(item)
end

# Infinite
loop
  data = read()
  break if data == 0
  process(data)
end

# Labeled
@outer for i in 0..10
  for j in 0..10
    break @outer if found(i, j)
  end
end
```

### Defer

Guaranteed cleanup, LIFO order:

```quartz
def process_file(path: String): Result<Data, Error>
  f = file_open(path)
  defer file_close(f)

  data = parse(f)?
  transform(data)
end
```

### Scoped Resources (`with`)

Prefer `with X do v -> body end` over manual `acquire`/`release` pairs.
The with-block fires release on every exit path — normal fall-through,
`return`, `break`, `continue`, AND throw/panic unwind. Manual pairs leak
the resource on the throw path.

```quartz
# Manual — leaks the lock if process(v) throws
v = mutex_lock(m)
process(v)
mutex_unlock(m, v)

# Scoped — guaranteed unlock on every exit
with m.lock do v ->
  process(v)
end
```

Stdlib types with `impl Scoped`: `Mutex`, `RwLock`, `FileGuard`,
`ChannelGuard`, `ScopeGuard`, `TcpStreamGuard`, `TcpListenerGuard`,
`EventLoopGuard`. See [Scoped Resources](QUARTZ_REFERENCE.md#scoped-resources-b8)
in the language reference for the full impl matrix and decision tree.

When the bound value is meaningless, use `_`:

```quartz
with chan_scope(ch) do _ ->
  send(ch, 42)
end
```

The bound `v` is implicitly `var` — reassignments inside the body
write back through `release(self, v)` (so `with mutex.lock do v ->
v = v + 1 end` is the canonical "increment counter" pattern).

### Block Expressions

```quartz
x = do
  tmp = compute()
  tmp * tmp
end
```

---

## Error Handling

Quartz has two error mechanisms. Pick by **caller intent**, not by mechanism preference.

**Decision tree** when writing a function that can fail:

1. **Will most callers want to handle this locally?** Use `Result<T, E>`. Failure is part of the function's interface; the caller pattern-matches.
2. **Is this exceptional but recovery is plausible at *some* layer up the stack?** Use `throw(msg)`. Failure unwinds via the `Throws` effect; a `with Throws { throw: handler } do ... end` block somewhere up the stack catches it.
3. **Is this a bug — an invariant the program should never violate?** Use
   `panic(msg)`. Current code can route panic through `Throws`, but that is a
   known nonconformance: the stabilization target makes panic non-recoverable.

```quartz
# Right: parse failure is part of the contract — caller handles
def parse_int(s: String): Result<Int, String>
  return Err("empty") if s.size == 0
  ...
end

# Right: out-of-memory is exceptional; caller probably can't recover at this layer
def alloc_buffer(size: Int): Buffer
  raw = mem_alloc(size)
  throw("buffer alloc failed: requested #{size} bytes") if raw == 0
  Buffer { ptr: raw, size: size }
end

# Right: bug — this state should be impossible
def state_step(s: State): State
  panic("state.count went negative: #{s.count}") if s.count < 0
  ...
end
```

**Wrong patterns:**

```quartz
# Wrong: panic for an expected failure
def parse_int(s: String): Int
  panic("empty input") if s.size == 0   # Caller can handle this — use Result
  ...
end

# Wrong: Result for an unrecoverable invariant violation
def state_step(s: State): Result<State, String>
  return Err("count went negative") if s.count < 0   # This is a bug — use panic
  ...
end
```

**Do not catch panics in new code.** Current `with Throws` interception is a
compatibility behavior scheduled for removal. Use `throw` for recoverable
control flow and reserve `panic` for non-recoverable invariant failure.

```quartz
def cli_main(): Int
  with Throws { throw: log_and_exit } do ->
    run_user_script()
    0
  end
end
```

Reference: [`docs/QUARTZ_REFERENCE.md`](QUARTZ_REFERENCE.md#error-handling) for the full mechanism details. Design rationale: [`docs/design/ERROR_HANDLING_UNIFICATION.md`](design/ERROR_HANDLING_UNIFICATION.md).

---

## Collections

### Literals

```quartz
numbers = [1, 2, 3, 4, 5]
config = {name: "Quartz", version: 5, debug: false}
unique = {1, 2, 3}
empty = {:}
```

**Always** use `{key: val}` shorthand for symbol keys — never hashrocket.

### Comprehensions

Prefer comprehensions over manual accumulation:

```quartz
squares = [x * x for x in 0..10]
evens = [x for x in items if x % 2 == 0]
lookup = {x => x * 2 for x in 1..5}
```

Use explicit loops only for side effects, early termination, or complex bodies.

### Unified API

Every collection speaks the same language:

```quartz
v.size               # Vec, String, Map — all .size
v.empty?             # all .empty?
opt.some?            # Option
res.ok?              # Result
```

**Never** use `.len`, `.length`, `is_empty`, or `is_some`.

---

## Pipelines and UFCS

### Pipeline Operator (`|>`)

For data transformation chains — read left to right:

```quartz
result = data |> parse |> validate |> transform

# With arguments
result = x |> add(10) |> multiply(2)

# Multi-line
config = Config.new() |>
  set_name("app") |>
  set_debug(true) |>
  build()
```

### UFCS

For method-like calls on objects. Any function whose first parameter matches the receiver type can be called with dot syntax (open UFCS):

```quartz
len = text.size
count = items.filter() { x -> x > 0 }.size
"hello".starts_with("he")

# Open UFCS: your own functions become methods automatically
def area(c: Circle): Int = c.radius * c.radius * 3
my_circle.area()       # calls area(my_circle)
```

### When to Use Which

| 1 step | 2 steps | 3+ steps |
|--------|---------|----------|
| `f(x)` | whichever reads better | pipeline `\|>` or UFCS `.` |

```quartz
# 1 step — just call it
len = items.size

# 2 steps — either works
result = validate(parse(data))        # direct
result = data |> parse |> validate    # pipeline

# 3+ steps — always chain
output = raw |> parse |> validate |> transform |> save
```

---

## Strings

### Interpolation

Preferred for embedding values:

```quartz
message = "User #{name} has #{count} items"
```

### Concatenation

For simple joins:

```quartz
greeting = "Hello, " + name + "!"
```

### Methods

```quartz
s.size                 # length
s[i]                   # char at index
s[a:b]                 # slice
s.find("needle")       # find substring
s.starts_with("he")    # prefix
s.ends_with("!")       # suffix
s.contains("world")    # substring check
s.downcase()           # lowercase
s.upcase()             # uppercase
s.trim()               # trim whitespace
s.replace(old, new)    # replace all
n.to_s                 # Int to String
s.to_i                 # String to Int
```

### Multi-Line and Raw

```quartz
text = """
  Multi-line string.
  Interpolation #{works} too.
"""

path = r"C:\Users\data"        # no escape processing
```

---

## Types

### Structs

```quartz
struct Point
  x: Int
  y: Int
end

p = Point { x: 10, y: 20 }
```

### Associated Functions and Extend

```quartz
def Point.origin(): Point = Point { x: 0, y: 0 }

extend Point {
  def sum(): Int = @x + @y
  def scale(n: Int): Point = Point { x: @x * n, y: @y * n }
}

Point.origin().sum()    # 0
```

### Enums

```quartz
enum Color
  Red
  Green
  Blue
end

enum Shape
  Circle(radius: Int)
  Rectangle(width: Int, height: Int)
  Point
end

enum Option<T>
  Some(value: T)
  None
end
```

### Union Types

True union types — no wrappers, no boxing:

```quartz
def process(value: Int | String): Void
  match value
    Int => puts("number")
    String => puts("text")
  end
end
```

### Intersection Types

```quartz
def print_if_equal<T: Eq & Ord>(a: T, b: T): Void
  puts("equal") if eq(a, b)
end
```

### Record Types

Structural typing — if it has the fields, it fits:

```quartz
def greet(who: { name: String }): Void
  puts("Hello, #{who.name}!")
end
```

### Newtypes

Distinct types that prevent accidental mixing:

```quartz
newtype UserId = Int
newtype Email = String

def get_user(id: UserId): User    # can't pass raw Int
```

### Type Aliases

Transparent shortcuts for readability:

```quartz
type Callback = Fn(Int): Bool
type IntTransform = Fn(Int): Int
```

---

## Traits

```quartz
trait Show
  def show(self): String
    return "<unknown>"
  end
end

impl Show for Point
  def show(self): String
    return "(#{self.x}, #{self.y})"
  end
end
```

### Self Type

`Self` resolves to the implementing type inside trait/impl blocks:

```quartz
trait Cloneable
  def clone(self): Self = self
end

impl Cloneable for Point
  def clone(self): Self = Point { x: @x, y: @y }  # Self = Point
end
```

### Bounds

Use UFCS in bounded generics — call trait methods with dot syntax:

```quartz
def max<T: Ord>(a: T, b: T): T
  return a if a.gt(b)
  return b
end

def compare<T: Eq + Ord>(a: T, b: T): Int
  return 0 if a.eq(b)
  return -1 if a.lt(b)
  return 1
end
```

### Standard Traits

| Trait | Purpose |
|-------|---------|
| `Eq` | Equality (`eq`, `ne`) |
| `Ord` | Ordering (`lt`, `le`, `gt`, `ge`) |
| `Hash` | Hashing (`hash`) |
| `Show` | String representation (`show`) |
| `Clone` | Deep copy (`clone`) |
| `Drop` | RAII cleanup (`drop`) |

---

## Operator Overloading

```quartz
extend Vec2 {
  def +(other: Vec2): Vec2 = Vec2 { x: @x + other.x, y: @y + other.y }
  def ==(other: Vec2): Bool = @x == other.x and @y == other.y
}

a = Vec2 { x: 1, y: 2 }
b = Vec2 { x: 3, y: 4 }
c = a + b    # Vec2 { x: 4, y: 6 }
```

---

## Error Handling

### Result + `?`

```quartz
def divide(a: Int, b: Int): Result<Int, String>
  return Err("division by zero") if b == 0
  Ok(a / b)
end

def calc(x: Int, y: Int): Result<Int, String>
  a = divide(x, y)?    # propagates Err
  Ok(a * 2)
end
```

### Safe Navigation + Nil Coalescing

```quartz
name = user?.profile?.name ?? "Anonymous"
port = config?.port ?? 8080
```

### Built-in Macros

```quartz
length = $try(get_length(s))        # early return None on failure
val = $unwrap(get_value())          # unwrap or panic
$assert(x > 0)                      # panic if false
x = $debug(10 + 20)                 # stderr debug, returns value
```

---

## Modules

### Import Order

1. Standard library
2. Project (hierarchical)
3. Flat imports
4. Selective imports

```quartz
import std/colors
import std/traits

import frontend/lexer
import frontend/parser

import token
from token import Token, Loc
```

### Qualification

```quartz
import math
result = math.add(1, 2)    # dot syntax — always
```

### Visibility

```quartz
struct Public { x: Int }       # accessible everywhere

private

struct Secret { value: Int }   # this module only

priv def helper(): Int = 42   # per-item
```

### Import Styles

```quartz
import lib                     # prefixed: lib.Point
from lib import *              # wildcard: Point (no prefix)
from lib import Point, greet   # selective
pub import lib                 # re-export
```

---

## Symbols

For lightweight tags and map keys:

```quartz
status = :ok

match status
  :ok => handle_success()
  :error => handle_failure()
end

config = {name: "Quartz", version: 5}
```

**Symbols** for simple flags. **Enums** when you need payloads or exhaustiveness.

---

## Regex

```quartz
pattern = ~r"hello"
email = ~r"[a-z]+@[a-z]+\.[a-z]+"

if s =~ ~r"\d+"
  puts("contains digits")
end
```

---

## Macros

```quartz
macro max(a: expr, b: expr) do
  "if #{a} > #{b} then #{a} else #{b} end"
end

result = $max(10, 20)
```

---

## Concurrency

Quartz's concurrency is colorless — the same code shape works for
sync and async. `go` fires a task, `await` waits for a handle,
channels carry values, `select` races multiple channels.

```quartz
sched_init(4)              # worker threads — call once near `main`

# Fire-and-forget task
go background_worker()

# Producer / consumer over a typed channel
ch = channel_new(64)
go do ->
  for i in 0..100
    send(ch, i * i)
  end
  channel_close(ch)
end

for value in ch            # iterate until closed
  puts(value)
end

# Async/await with eager futures
future = async compute(42)
result = await future

# Select across Selectables (C.13 — channel recv/send, deadlines,
# scope cancel, futures all dispatch through the same trait)
import * from std/sync/communication/channel
import * from std/sync/composition/scope
import * from std/sync/composition/awaitable

select
  case order = recvable(orders)  => process(order)
  case id    = recvable(cancels) => cancel(id)
  case _     = deadline_ms(5000) => give_up()        # throws
  default                         => idle()
end

sched_shutdown()
```

Rules of thumb:

- `ch = channel_new(64)`, `future = async ...`, `result = await ...`
  — all const bindings. The handle doesn't change; only what you
  send through it does. Only use `var` when you actually re-assign
  the name.
- Inside `go do ->` block bodies, the usual idioms apply — implicit
  `it`, `#{}` interpolation, UFCS chains.
- **Prefer `select` over hand-rolled multiplexing.** When you need to
  race "value arrived on channel" against "scope was cancelled" /
  "deadline expired" / "task completed", reach for `select { case
  ... }` with the appropriate Selectables (`recvable`, `sendable`,
  `cancellable`, `deadline_ms`, `awaitable`). Hand-rolling polling
  loops is fragile and won't benefit from the scheduler's active-wake
  retrofit (Phase 4b).
- For compute-heavy parallel iteration, reach for a parallel
  combinator (e.g. `parallel_map`) rather than hand-rolling spawns.

### Cancellation (B.7)

The canonical way to bound concurrent work is `scope_with` from
`std/sync/composition/scope`. It wraps a body, installs a `Scope` as the per-thread
current scope, and tears down on exit (cancelling the scope, re-throwing
captured exceptions). Goroutines spawned with `go fn()` inherit the
current scope at spawn time.

```quartz
import * from std/sync/composition/scope

# Bounded work with a 5-second deadline.
scope_with(scope_timeout(scope_root(), 5_000), do_work)

# Bounded work with explicit cancel.
def do_work(): Int
  scope_sleep_ms(1_000)            # respects deadline; throws on cancel
  for chunk in batches
    process(chunk)
    scope_check(current_scope())   # check between long CPU-bound steps
  end
  return 0
end
```

Rules of thumb:

- **Prefer `scope_with(scope_with_cancel(current_scope()), body)` over
  manual cancel-token threading.** Scope is the structural,
  ambient-by-TLS primitive. Cancel tokens are reserved for the
  capability corner (passable handles, peer-to-peer cancel,
  externally-triggered cancel — `supervisor_tree`, `go_cancellable`,
  racing patterns).
- **Wire long CPU-bound loops with `scope_check(current_scope())`** at
  iteration boundaries so cancel observation isn't bounded by the
  longest single iteration. Blocking primitives (`scope_sleep_ms`,
  `scope_recv`, `scope_send`, `scope_lock`, `scope_rwlock_read`,
  `scope_rwlock_write`) already check; raw `mutex_lock` / `recv` /
  `sleep` / etc. do not.
- **Don't catch the cancel throw in workers.** `with Throws { throw: ... }`
  catchers belong at the orchestration boundary (the `scope_with`
  caller's scope), not in the worker body. Catching inside the worker
  defeats the structural cascade.

---

## Effects (Piezo)

The algebraic effect system lives alongside the idiomatic rules
above without replacing them. Code written *invisibly* (no `can`
rows, no `try`, no `with`) still reads exactly like the cheat
sheet prescribes — effects only appear when you reach for them.

```quartz
# Invisible — just write the code
def greet(name)
  puts("Hello, #{name}!")
end

# Implicit — effects inferred, visible in LSP/docs, no source noise
def read_or_default(path)
  raw = try read_file(path)
  return parse_or_default(raw)
end

# Explicit — `can` rows at API boundaries, like any type annotation
def read_config(path: String): Config can FileIo, Throws<ConfigError>
  raw = try read_file(path)
  return try parse_toml(raw)
end

# Sandbox / handler installation
result = with catch (e: ConfigError) -> default_config() do ->
  read_config("/etc/app.toml")
end

# Reify — convert a throwing block into a Result<T, E>
res: Result<Int, ParseError> = reify { parse_int(input) }
```

When it's time to write effect-aware code, apply the same rules:

- **Annotate `can` rows at API boundaries**, not inside bodies. They
  carry the same weight as return-type annotations — document the
  contract for callers, omit when inference is obvious.
- **`try` is a visibility marker**, not a coercion. Use it when the
  propagation point is non-obvious to the reader. Implicit
  propagation is fine when the call site already looks effectful.
- **`with catch` blocks** use `e -> ...` named params (the name
  documents "this is the caught error"), not implicit `it`.
- **Never mix** `$try()` with the new `try` prefix — `$try()` was
  retired in the Piezo Milestone A landing (Apr 2026). All new
  propagation points use the prefix form.

For executable behavior, follow the effect and error-handling sections of
[QUARTZ_REFERENCE.md](QUARTZ_REFERENCE.md). [EFFECTS.md](EFFECTS.md) is a
historical Piezo design record and includes retired and proposed forms.

---

## Memory and Systems

### Linear Types

```quartz
linear struct FileHandle
  fd: Int
end

def read_all(f: &FileHandle): String
  # borrow — doesn't consume
end
```

### Placement Allocation

```quartz
arr = @heap [1, 2, 3]

arena scratch do
  p = @scratch Point { x: 10, y: 20 }
end
```

---

## Annotations

| Annotation | Purpose |
|------------|---------|
| `@value` | Value-type struct (inline storage, copy semantics) |
| `@cfg(os: "macos")` | Conditional compilation |
| `@repr(C)` | C-compatible layout |
| `@packed` | No alignment padding |
| `@naked` | No function prologue/epilogue |
| `@thread_local` | Thread-local storage |
| `@field` / `@x` | Implicit `self.x` in extend blocks |

---

## FFI

```quartz
extern "C" def puts(s: String): Int
extern "C" def malloc(size: Int): CPtr
extern "C" def free(ptr: CPtr): Void
```

---

## Documentation

Use `##` for doc comments:

```quartz
## Adds two numbers.
##
## @param a - First operand
## @param b - Second operand
## @returns The sum
## @example
##   add(1, 2)  # => 3
def add(a: Int, b: Int): Int = a + b
```

Comment what's *non-obvious*. Never comment what the code already says.

---

## File Organization

1. Imports
2. Type definitions (structs, enums, newtypes)
3. Constants
4. Trait implementations
5. Private helpers
6. Public API
7. `main` (if applicable)

---

## The Rules

Every rule in this guide reduces to two principles:

**Use the most expressive construct available:**

```quartz
def double(x: Int): Int = x * 2          # not block def
count += 1                                # not count = count + 1
squares = [x * x for x in 0..10]         # not manual loop
return 0 if x < 0                         # not block if
return 0 if opt is None                   # not match for bool check
val = opt.unwrap_or(0)                    # not match for simple unwrap
name = user?.name ?? "Anon"               # not nil check
items.filter() { it > 0 }                # not { x -> x > 0 }
v.push(x)                                # not vec_push(v, x)
Point { x, y } = get_point()              # not manual field access
```

**Never nest when you can flatten:**

```quartz
# Yes
def process(n: Int): Int
  return 0 if n == 0
  return -1 unless valid(n)
  compute(n)
end

# No
def process(n: Int): Int
  if n != 0
    if valid(n)
      compute(n)
    else
      return -1
    end
  else
    return 0
  end
end
```

---

## Modern Idioms (v5.26+)

### UFCS-First

Prefer method-call style over free-function style for all collections:

```quartz
# Yes
v.push(x)
v.pop()
m.set(k, v)
m.get(k)
s.find("needle")

# No
vec_push(v, x)
vec_pop(v)
map_set(m, k, v)
map_get(m, k)
str_find(s, "needle")
```

### Map subscript vs `.get()` — pick by key provenance

`Map<K, V>` exposes two access forms with **different return types and
different failure modes**. Pick by where the key came from, not by
which one looks shorter:

| Form        | Returns     | On missing key | Use when                                                   |
|-------------|-------------|----------------|------------------------------------------------------------|
| `m[key]`    | `V`         | **panics**     | Key is structurally guaranteed to exist                    |
| `m.get(key)`| `Option<V>` | returns `None` | Missing key is an expected outcome of normal control flow  |

The mental model: subscript says "trust me, this key exists; if it
doesn't that's a bug — fail loud." The accessor says "this lookup
might miss; I'll handle the None case explicitly."

```quartz
# Yes — key came from m.keys(), so missing is structurally impossible.
# Subscript collapses match-Some/None scaffolding to a single expression.
for key in m.keys()
  process(key, m[key])
end

# Yes — `path` is user input, missing is a real outcome we handle.
match config.get(path)
  Some(v) => apply(v)
  None    => apply(default)
end

# No — verbose Option dance when key is guaranteed present:
for key in m.keys()
  match m.get(key)
    Some(v) => process(key, v)
    _       => ()              # unreachable, but typecheck demands it
  end
end

# No — silent panic-swallowing when a real lookup might miss:
val = config[user_supplied_path]   # panics on typo
```

> **Vec note**: `v[i]` and `v.get(i)` *both* return `T` and panic on
> out-of-bounds — Vec doesn't have an `Option`-returning by-index
> accessor today. Use `vec_first` / `vec_last` for safe positional
> access. The panic-vs-`Option` duality applies to Map, not Vec.

### Option/Result Handling

Use UFCS methods, the `is` keyword, and the `try` prefix for
Option/Result handling. Reserve `match` for true multi-arm dispatch.

```quartz
# Predicate tests — `is` keyword
return 0 if opt is None
return -1 if result is Err

# Extract with default — UFCS
val = opt.unwrap_or(0)
val = opt.unwrap_or_else() { compute_default() }
count = result.unwrap_or(0)

# Propagate errors — `try` prefix (replaces the retired $try() macro
# and the retired postfix `?`)
def read_config(path): Result<Config, IoError>
  raw = try read_file(path)
  parsed = try parse_toml(raw)
  return Ok(Config { raw, parsed })
end
```

A single-arm match to unwrap is always a bad smell — use `is`,
`unwrap_or`, or `try` instead. Save `match` for when there are
multiple variants with real dispatch logic.

### Unqualified Enum Variants

Module prefixes never appear in match arms — variants resolve from
the scrutinee's type:

```quartz
match opt
  Some(v) => process(v)
  None => default()
end
```

`Option::Some` and `Option::None` are not valid pattern syntax. Not
"discouraged" — the parser rejects them.

### Implicit `it`

Implicit `it` is the default for any single-param trailing block.
Reach for `x ->` only when the parameter name documents intent, or
when the block takes two or more params.

```quartz
# Default form — use `it`
items.filter() { it > 0 }
items.map() { it * 2 }
items.each() { puts("#{it}") }

# Named param — only when the name is load-bearing
users.map(user -> user.active_since)
# (the name `user` tells the reader what it is — `{ it.active_since }`
#  leaves the reader to guess from the collection name)

# Multi-param — always named
items.reduce(0) do acc, x -> acc + x end
```

If the body is long or has multiple statements, that's not a signal
to switch away from `it` — it's usually a signal to extract a
named function:

```quartz
# When the body grows past one clear expression:
def is_eligible(u) = u.active? and u.age > 18 and u.region == "US"
users.filter(is_eligible)
```

---

## Anti-Patterns

| Avoid | Instead |
|-------|---------|
| `count = count + 1` | `count += 1` |
| `v.len`, `v.length` | `v.size` |
| `is_empty(v)` | `v.empty?` |
| `vec_push(v, x)` | `v.push(x)` |
| `map_get(m, k)` | `m.get(k)` |
| `Option::Some(v)` in match | `Some(v)` |
| `option_is_some(opt)` | `opt.is_some()` or `opt is Some` |
| `match opt { ... }` for unwrap | `opt.unwrap_or(default)` |
| `{ x -> x * 2 }` (trivial) | `{ it * 2 }` |
| Block def for single expr | `def f(x): T = expr` |
| Deep nesting | Postfix guards + early return |
| Manual while for counting | `for i in 0..n` |
| Done-flag loops | `loop` + `break` |
| Hashrocket for symbol keys | `{key: val}` |
| `math$add(1, 2)` | `math.add(1, 2)` |
| Manual field extraction | Destructuring |

### The Done-Flag

Never simulate `break` with a flag:

```quartz
# No
var done = 0
while done == 0
  if pos >= len
    done = 1
  end
end

# Yes
loop
  break if pos >= len
  var ch = source[pos]
  break if ch == 10
  pos += 1
end
```
