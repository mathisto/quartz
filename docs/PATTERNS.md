# Quartz Language Affordances & Patterns

> **Comprehensive catalog of Quartz idioms, patterns, and capabilities**
> Reference for both humans and AI to understand what Quartz can do.

## Table of Contents

1. [Type System Affordances](#type-system-affordances)
2. [Control Flow Patterns](#control-flow-patterns)
3. [Data Structure Patterns](#data-structure-patterns)
4. [Error Handling Patterns](#error-handling-patterns)
5. [Functional Patterns](#functional-patterns)
6. [Memory Patterns](#memory-patterns)
7. [Concurrency Patterns](#concurrency-patterns)
8. [Module Patterns](#module-patterns)

---

## Type System Affordances

### What Quartz Has

| Feature | Syntax | Status |
|---------|--------|--------|
| **Generic functions** | `def foo<T>(x: T): T` | ✅ Full support |
| **Generic enums** | `enum Option<T>` | ✅ Full support |
| **Generic structs** | `struct Pair<T, U>` | ✅ Full support |
| **Trait bounds** | `def max<T: Ord>(a: T, b: T)` | ✅ Full support |
| **Multiple bounds** | `<T: Eq + Ord>` | ✅ Full support |
| **Type aliases** | `type UserId = Int` | ✅ Full support |
| **Newtypes** | `newtype Meters = Int` | ✅ Parsing, ⏳ Enforcement |
| **Function types** | `Fn(Int, Int): Bool` | ✅ Full support |
| **Nil type** | `x = nil` | ✅ Full support |

### What Quartz Doesn't Have (Yet)

| Feature | Notes |
|---------|-------|
| Higher-kinded types | No `Functor<F<_>>` |
| Associated types | Trait methods use `Self` |
| GADTs | No type witnesses |
| Existential wrappers | No `dyn Trait` |
| Variance annotations | Implicit invariance |
| Never/Bottom type | `panic()` returns `Void`, not `!` |

### Generic Enum Patterns

```be
# Definition
enum Option<T>
  Some(value: T)
  None
end

# Construction
opt = Option::Some(42)
none = Option::None

# Pattern matching (required: exhaustive)
match opt
  Option::Some(v) => use(v)
  Option::None => handle_missing()
end

# Generic functions over enums
def is_some<T>(opt: Option<T>): Bool
  match opt
    Option::Some(x) => true
    Option::None => false
  end
end
```

### Type Alias Patterns

```be
# Simple readability
type UserId = Int
type Handler = Fn(Request): Response

# Domain modeling
type Celsius = Int
type Fahrenheit = Int

def to_fahrenheit(c: Celsius): Fahrenheit
  return c * 9 / 5 + 32
end
```

---

## Control Flow Patterns

### Guard Clauses (Early Return)

```be
# Prefix form
def process(x: Int): Int
  if x < 0
    return -1
  end
  if x == 0
    return 0
  end
  # Happy path
  return x * 2
end

# Postfix form (v5.1+)
def process(x: Int): Int
  return -1 if x < 0
  return 0 if x == 0
  return x * 2
end

# Unless variant
def validate(s: String): Bool
  return false unless str_len(s) > 0
  return false unless str_len(s) < 100
  return true
end
```

### Match Expression Patterns

```be
# As expression (returns value)
result = match status
  :ok => 0
  :error => 1
  :pending => 2
end

# Multi-statement arms
match choice
  A => {
    var g = setup()
    process(g)
    finalize(g)  # Last expression is result
  }
  B => simple_value
end

# Nested patterns
match point
  Point { x: 0, y: 0 } => "origin"
  Point { x: 0, y: y } => "y-axis"
  Point { x: x, y: 0 } => "x-axis"
  _ => "elsewhere"
end
```

### Loop Patterns

```be
# Accumulator
var sum = 0
for x in items
  sum += x
end

# Filter-map in loop
var results = vec_new()
for item in items
  continue unless is_valid(item)
  vec_push(results, transform(item))
end

# Labeled loops for early exit
@outer for i in 0..10
  for j in 0..10
    break @outer if found(i, j)
  end
end
```

---

## Data Structure Patterns

### Struct Initialization

```be
# Required: single line, curly braces
p = Point { x: 10, y: 20 }

# Associated constructor
def Point.origin(): Point = Point { x: 0, y: 0 }
def Point.at(x: Int, y: Int): Point = Point { x: x, y: y }

p = Point.origin()
q = Point.at(5, 10)
```

### Enum State Machines

```be
enum ConnectionState
  Disconnected
  Connecting(attempt: Int)
  Connected(session_id: Int)
  Error(message: String)
end

def transition(state: ConnectionState): ConnectionState
  match state
    ConnectionState::Disconnected => 
      ConnectionState::Connecting(1)
    ConnectionState::Connecting(n) => {
      if n > 3
        ConnectionState::Error("timeout")
      else
        ConnectionState::Connecting(n + 1)
      end
    }
    ConnectionState::Connected(id) => 
      ConnectionState::Disconnected
    ConnectionState::Error(msg) => 
      ConnectionState::Disconnected
  end
end
```

### Builder Pattern with Pipeline

```be
config = Config.new()
          |> set_name("app")
          |> set_port(8080)
          |> set_debug(true)
          |> build()
```

---

## Error Handling Patterns

### Result Pattern

```be
enum Result<T, E>
  Ok(value: T)
  Err(error: E)
end

def parse_int(s: String): Result<Int, String>
  if is_numeric(s)
    Result::Ok(str_to_int(s))
  else
    Result::Err("not a number")
  end
end

# Handling
match parse_int(input)
  Result::Ok(n) => use(n)
  Result::Err(e) => log_error(e)
end
```

### Option Pattern

```be
enum Option<T>
  Some(value: T)
  None
end

def find_user(id: Int): Option<User>
  if exists(id)
    Option::Some(load_user(id))
  else
    Option::None
  end
end
```

### Try-Catch Pattern

```be
# Inline form
value = try risky() catch Err(e) fallback

# Block form
value = try
  parse(data)
catch Err(e)
  log("Parse failed: #{e}")
  default_value
end
```

### Sentinel Values (Legacy)

```be
# Still common in low-level code
def lookup(name: String): Int
  # Returns -1 if not found
  ...
end

idx = lookup(name)
if idx < 0
  return handle_not_found()
end
```

---

## Functional Patterns

### First-Class Functions

```be
def apply(f: Fn(Int): Int, x: Int): Int = f(x)
def compose(f: Fn(Int): Int, g: Fn(Int): Int): Fn(Int): Int
  return |x: Int| f(g(x))
end

def double(x: Int): Int = x * 2
def add_one(x: Int): Int = x + 1

# Pass named function
result = apply(double, 21)  # 42

# Compose
transform = compose(double, add_one)
transform(5)  # 12
```

### Lambda Expressions

```be
# Single expression (implicit return)
double = |x: Int| x * 2
add = |a: Int, b: Int| a + b
thunk = || 42

# Multi-statement
process = |x: Int| {
  var temp = x * 2
  temp + 1
}
```

### Higher-Order Collection Functions

```be
# Transform
doubled = map(items, |x: Int| x * 2)

# Filter
evens = filter(items, |x: Int| x % 2 == 0)

# Reduce
sum = reduce(items, 0, |acc: Int, x: Int| acc + x)

# Predicates (? suffix — they return Bool)
has_negative = any?(items, |x: Int| x < 0)
all_positive = all?(items, |x: Int| x > 0)

# Find
first_match = find(items, |x: Int| x > 100)
```

### Pipeline Operator

```be
# Left-to-right data flow
result = data
  |> parse
  |> validate
  |> transform
  |> format

# With arguments (value becomes first arg)
result = x |> add(10) |> multiply(2)
# Equivalent: multiply(add(x, 10), 2)
```

### List Comprehensions

```be
# Simple
squares = [x * x for x in 0..10]

# With filter
evens = [x for x in 0..20 if x % 2 == 0]

# Nested (cartesian product)
pairs = [x + y for x in 0..3 for y in 0..3]

# Map comprehension
lookup = {x => x * 2 for x in 1..5}
```

---

## Memory Patterns

### RAII with Drop Trait

```be
import std/memory

def main(): Int
  var arena = arena_create()
  # Use arena...
  # Auto-destroyed at scope end via Drop
  0
end
```

### Defer for Cleanup

```be
def process_file(path: String): Int
  f = file_open(path)
  defer file_close(f)  # Runs on any return
  
  data = parse(f)?
  return process(data)
end

# Multiple defers (LIFO order)
def example(): Void
  defer puts("first")
  defer puts("second")
  defer puts("third")
  puts("working")
end
# Output: working, third, second, first
```

### Arena Allocation

```be
# Low-level
a = arena_new()
ptr = arena_alloc(a, 64)
arena_reset(a)
arena_destroy(a)

# Typed allocation
p = arena_alloc<Point>(a)
```

---

## Concurrency Patterns

### Spawn and Join

```be
def worker(): Void
  puts("Working...")
end

h = spawn(worker)
thread_join(h)

# With argument
h = spawn_with(|x: Int| process(x), 42)
```

### Mutex Pattern

```be
m = mutex_new()
mutex_lock(m)
# Critical section
shared_data += 1
mutex_unlock(m)
```

### Parallel Iteration

```be
# Parallel map
results = parallel_map(items, |x: Int| expensive_compute(x))

# Parallel for (side effects)
parallel_for(items, |item: Int| process(item))

# Parallel reduce
sum = parallel_reduce(items, 0, |acc: Int, x: Int| acc + x)
```

---

## Module Patterns

### Public/Private Visibility

```be
# lib.qz
def public_fn(): Int = 42
struct PublicStruct { x: Int }

private

def internal_helper(): Int = 99
struct InternalData { secret: Int }
```

### Module-Qualified Access

```be
import math

# Dot syntax (preferred)
result = math.add(1, 2)

# Explicit syntax
result = math$add(1, 2)

# Types
p = math.Point { x: 10, y: 20 }
c = math.Color::Red
```

### Selective Imports

```be
from token import Token, Loc
from math import add, multiply
```

### Aliased Imports

```be
import very_long_module_name as m
m.function()
```

---

## Known Limitations

> **Refreshed 2026-07-07 (truth-in-docs).** The five limitations previously listed here were all **stale** and are now resolved — verified by fresh repro: `Never` exists (`def f(): Never`); `panic()` unifies in value position (`Never` bottom-type); wildcard `_` works in match arms; struct literals span multiple lines; and higher-order generic functions (`apply<T>(f: Fn(T): T, x: T)`) pass **and run** correctly. The genuine current limitations:

| Area | Limitation | Workaround |
|------|------------|------------|
| **Flow-narrowing scope** | Only *bare identifiers* narrow after `if x.some?` / `if Some(v) = x`. Field paths (`a.b.opt.some?`), index exprs, and call results do **not** narrow (they can change between check and use). | Bind a local first: `c = a.b.opt; if c.some? ... end` |
| **niche-multi `Result<String,String>`** | The flow-*narrowing reprojection* on a niche-multi `Result<String,String>` is parked; the `match`/`is` path itself works. | Use an explicit `match` |
| **Generic operator/trait dispatch** | `==` (and trait methods) on a bounded generic `T: Eq` don't yet dispatch to the concrete impl — they pointer-compare. Affects comparing/matching *inside* a generic body. Tracked as ROADMAP **R2.4** (`docs/bugs/GENERIC_OPERATOR_TRAIT_DISPATCH_MISSING.md`). | Compare on concrete types, or unwrap before comparing |
| **niche Symptom-1** | An M1 user-enum `match` can read a wrong value in imported-module contexts (silent). Tracked in `docs/bugs/NICHE_MULTI_MATCH_CONTEXT_DEPENDENT_GARBAGE.md`. | Keep such matches in the entry module, or add a wildcard |

---

## Version Changelog

| Version | Key Additions |
|---------|--------------|
| v5.2–v5.12.21-alpha | Algebraic effects + handlers, value semantics + copy-on-write, union/record/intersection types (termification), flow-narrowing (smart-casts), Law-of-Exclusivity borrow checking, drop/scoped RAII, call-site arg-type soundness (QZ0201), Maranget exhaustiveness checking, e-graph optimizer, did-you-mean diagnostics. Version of record: **v5.12.21-alpha** — see `docs/ROADMAP.md` for live status. |
| v5.1 | Postfix guards, generic trait bounds, module.function() |
| v5.0 | Traits, parallel iteration, pipelines, list comprehensions |
| v4.0 | DWARF debug info, type checker parity |
| v3.0 | Full type inference |
| v2.0 | Hierarchical imports, fixpoint validation |
| v1.0 | Self-hosting, const-by-default, first-class functions |
