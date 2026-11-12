# Quartz API Design Guidelines

These guidelines govern the shape, feel, and consistency of every public-facing API in Quartz — from compiler intrinsics to standard library functions to user-facing syntax. When in doubt, defer to these rules.

## Fundamentals

### The Four Pillars

1. **Const by default.** Immutability is the happy path. Mutation requires `var`. APIs that return new values are preferred over APIs that mutate in place.

2. **Say what you mean.** Names should read like prose at the call site. `v.sorted()` clearly returns a new sorted vec. `v.sort()` clearly sorts in place. If you have to check the docs to know what a function does, the name is wrong.

3. **Types guide, then vanish.** Rich types exist at compile time to catch errors. At runtime, everything is `i64`. APIs should leverage the type system for safety but never burden users with type gymnastics.

4. **Noise is a bug.** Every character earns its place. No redundant prefixes, no unnecessary annotations, no verbose ceremony. If the compiler can infer it, the programmer shouldn't write it.

---

## Naming

### Cases

| Entity | Convention | Example |
|--------|-----------|---------|
| Functions, variables, parameters | `snake_case` | `vec_push`, `is_valid` |
| Types, structs, enums, traits | `PascalCase` | `Map`, `Option`, `Color` |
| Enum variants | `PascalCase` | `Some`, `None`, `Red` (unqualified in match) |
| Type parameters | Single uppercase | `T`, `K`, `V`, `E` |
| Constants | `SCREAMING_SNAKE_CASE` | `MAX_SIZE`, `PI` |
| Modules | `snake_case` | `net/http`, `collections/stack` |

### Vocabulary Rules

**Use `size` for counts.** Not `len`, not `length`, not `count` (except `count` as a higher-order predicate counter). Every sized type uses `.size`. No exceptions.

**Use `delete` for removal.** Not `del`, not `remove`. Every collection uses `.delete(k_or_i)` where `k_or_i` is whatever uniquely identifies the element — a key for Map/Set, an index for Vec. One verb across the whole collection surface, zero special cases.

**Use active verbs for mutation, past participles for copies:**

| Mutates in-place (Void) | Returns new value |
|--------------------------|-------------------|
| `v.sort()` | `sorted(v)` or `v.sorted()` |
| `v.reverse()` | `reversed(v)` or `v.reversed()` |
| `v.dedup()` | — |
| `v.retain(pred)` | `v.filter(pred)` |
| `v.truncate(n)` | `v.take(n)` |
| `v.extend(other)` | — |
| `v.clear()` | — |
| `v.push(x)` | — |

**Rule of thumb:** If it returns `Void`, it mutates the receiver. If it returns a value, the receiver is unchanged. No exceptions.

### Predicates

Boolean-returning queries use the `?` suffix:

```quartz
v.empty?          # Is the collection empty?
opt.some?         # Does the Option contain a value?
opt.none?         # Is the Option empty?
result.ok?        # Is the Result a success?
result.err?       # Is the Result an error?
c.digit?          # Is this codepoint a digit?
c.alpha?          # Is this codepoint alphabetic?
```

For parameterized predicates, use descriptive verb phrases:

```quartz
v.contains(42)         # Does v contain 42? (O(n) linear scan)
m.has("key")           # Does m have this key? (O(1) hash lookup)
s.starts_with("http")  # Does s start with this prefix?
s.ends_with(".qz")     # Does s end with this suffix?
a.is_subset(b)         # Is a a subset of b?
```

**`contains` vs `has`:** Use `contains` for O(n) membership tests (Vec, String). Use `has` for O(1) lookup (Map, Set). This signals performance characteristics.

### Operators

The `<<` shovel operator pushes/adds/appends based on LHS type:

```quartz
v << 42            # vec_push(v, 42)
s << "text"        # sb_append(s, "text")  (StringBuilder)
set << 10          # set_add(set, 10)
ch << msg          # send(ch, msg)         (Channel)
1 << 3             # left-shift (Int)      = 8
```

---

## Error Handling

### Option for Absence

When a value might not exist, return `Option<T>`:

```quartz
v.pop()            # Option<T> — empty vec returns None
m.get(k)           # Option<T> — missing key returns None
s.find(sub)        # Option<Int> — not found returns None
v.index_of(x)      # Option<Int> — not found returns None
```

**Never return sentinel values** (-1, 0, null) for "not found." Use `None`.

### Option/Result UFCS Methods

Prefer UFCS methods over free-function calls or verbose match blocks:

```quartz
# Simple unwrap with fallback — prefer .unwrap_or() or ??
val = opt.unwrap_or(0)
val = opt ?? 0                     # Nil coalescing (equivalent)

# Quick variant check — prefer `is` keyword
return 0 if opt is None
return -1 if result is Err

# Boolean predicates
if opt.is_some()                   # or: opt.some?
  process(opt.unwrap_or(0))
end

# Transform inner value
doubled = opt.map(x -> x * 2)     # Some(42) → Some(84), None → None
```

**When to use which:**

| Pattern | Use when |
|---------|----------|
| `opt.unwrap_or(default)` | Simple fallback value needed |
| `opt ?? default` | Same as above (nil coalescing syntax) |
| `opt is None` / `opt is Some` | Boolean check, no value extraction |
| `if Some(v) = opt` | Need to extract value in one branch |
| `match opt { Some(v) => ... None => ... }` | Need to handle both branches with distinct logic |
| `$try(opt)` | Propagate None/Err to caller |
| `$unwrap(opt)` | Invariant — panic on None (programmer error) |

### Result for Recoverable Errors

When an operation can fail with context, return `Result<T, E>`:

```quartz
match parse_config(path)
  Ok(cfg) => use(cfg)              # Unqualified variants in match
  Err(msg) => log_error(msg)
end

# Or use `is` for quick checks
result = parse_config(path)
return -1 if result is Err
```

### Panic for Programmer Error

`panic()` is for invariant violations — states that should be impossible in correct code:

```quartz
panic("index out of bounds")      # Bug in caller
panic("unreachable match arm")    # Logic error
```

**Never panic for expected conditions** like missing files or network timeouts.

### Implicit `it` Guidelines

Use implicit `it` for single-param trailing blocks where the body is short and intent is obvious:

```quartz
# Good — short, clear intent
items.filter() { it > 0 }
items.map() { it * 2 }
items.any?() { it == target }
items.each() { puts("#{it}") }

# Prefer explicit params when:
# - Multiple parameters
items.reduce(0) do acc, x -> acc + x end
items.sort_by() { a, b -> a - b }

# - Body is complex or multi-line
items.map() do item ->
  name = item.name
  "Hello, #{name}!"
end

# - Descriptive name adds clarity
users.filter() { user -> user.active? and user.age > 18 }
```

**Rule of thumb:** If the block fits on one line and reads naturally with `it`, use implicit `it`. Otherwise, name the parameter.

---

## Collections

### Universal Protocol

Every collection type supports:

| Method | Returns | Meaning |
|--------|---------|---------|
| `.size` | `Int` | Number of elements |
| `.empty?` | `Bool` | Is size zero? |
| `.clear()` | `Void` | Remove all elements |
| `.free()` | `Void` | Deallocate memory |

### Type-Specific Methods

**Vec** (ordered, indexed):
`.push(x)`, `.pop()`, `.get(i)`, `.set(i, x)`, `.contains(x)`, `.index_of(x)`,
`.insert(i, x)`, `.delete(i)`, `.sort()`, `.sort_by(cmp)`, `.reverse()`, `.clone()`,
`.slice(a, b)`, `.join(sep)`, `.extend(other)`, `.capacity()`, `.truncate(n)`,
`.dedup()`, `.retain(pred)`, `.shrink_to_fit()`

**Map** (key-value, unordered — dispatches to string-key or int-key backend by key type):
`.get(k)`, `.set(k, v)`, `.has(k)`, `.delete(k)`, `.keys()`, `.values()`

**Set** (unique elements, unordered):
`.add(x)`, `.has(x)`, `.delete(x)`, `.members()`,
`.union(other)`, `.intersection(other)`, `.difference(other)`, `.is_subset(other)`

**StringBuilder** (mutable string buffer):
`.append(s)`, `.append_char(c)`, `.to_string()`

### Higher-Order Collection Operations

These work on any Vec via UFCS or function-call syntax:

| Operation | Returns | Mutates? |
|-----------|---------|----------|
| `v.map(f)` | `Vec` | No — returns new |
| `v.filter(pred)` | `Vec` | No — returns new |
| `v.reduce(init, f)` | `T` | No |
| `v.each(f)` | `Void` | No (side effects only) |
| `v.find(pred)` | `T` | No |
| `v.count(pred)` | `Int` | No |
| `v.any?(pred)` | `Bool` | No — predicate suffix, returns Bool |
| `v.all?(pred)` | `Bool` | No — predicate suffix, returns Bool |
| `v.first()` | `T` | No |
| `v.last()` | `T` | No |
| `v.take(n)` | `Vec` | No — returns first n |
| `v.drop(n)` | `Vec` | No — returns without first n |
| `v.sum()` | `Int` | No |
| `v.product()` | `Int` | No |
| `sorted(v)` | `Vec` | No — returns sorted copy |
| `reversed(v)` | `Vec` | No — returns reversed copy |
| `unique(v)` | `Vec` | No — returns deduplicated+sorted copy |
| `flatten(v)` | `Vec` | No — flattens Vec<Vec<T>> |
| `enumerate(v)` | `Vec` | No — Vec of [index, value] pairs |
| `zip(a, b)` | `Vec` | No — Vec of [a, b] pairs |
| `partition(v, pred)` | `[Vec, Vec]` | No — [matching, non-matching] |

---

## Strings

### The Model

Quartz strings are **UTF-8 encoded byte sequences** with a **codepoint-first default API**. This means:

- `.size` returns **codepoint count** (like Swift)
- `s[i]` returns the **codepoint value** at codepoint index `i`
- `.find(sub)` returns a **codepoint offset**
- `.slice(a, b)` slices by **codepoint range**

For performance-critical code that operates on raw bytes, use the `byte_` prefix:

- `.byte_size` returns **byte count** (O(1))
- `.byte_at(i)` returns **byte value** at byte index `i`
- `.byte_slice(a, b)` slices by **byte range** (O(1))
- `.byte_find(sub)` returns a **byte offset**

**When to use which:**
- **Default (codepoint):** User-facing text, display, string manipulation
- **Byte-prefixed:** Parsing protocols, binary data, performance-critical inner loops
- **For ASCII-only data:** No difference — 1 codepoint = 1 byte

### String Operations

All string operations return **new strings** (strings are immutable):

```quartz
s.downcase()       # "HELLO" → "hello"
s.upcase()         # "hello" → "HELLO"
s.trim()           # "  hi  " → "hi"
s.replace(a, b)    # Replace all occurrences of a with b
s.repeat(n)        # Repeat string n times
s.reverse()        # Reverse by codepoints
s.split(delim)     # Split into Vec<String>
s.starts_with(p)   # Bool
s.ends_with(p)     # Bool
s.contains(sub)    # Bool
s.find(sub)        # Option<Int> — codepoint offset
```

---

## Concurrency

Quartz concurrency is **structured by default**. Tasks are children of a scope. Errors propagate. Cancellation is built in. You only drop down to lower levels when you have a specific reason.

### The Three Levels

Use the **highest** level that meets your needs.

#### 1. Structured Concurrency (the default)

`go_scope`, `go_supervisor`, `go_race`, `go_scope_timeout`. Tasks live inside a lexical scope. The scope does not return until all child tasks complete or are cancelled. Failures in any child propagate to the parent. No leaked goroutines, no orphaned work.

```quartz
# Run two tasks in parallel; wait for both
go_scope() do ->
  go() do -> fetch_user(id) end
  go() do -> fetch_orders(id) end
end

# Race — first winner cancels the rest
result = go_race([
  -> fetch_from(primary),
  -> fetch_from(replica),
])

# Supervisor — restart children on panic
go_supervisor() do ->
  go() do -> long_running_worker() end
end
```

**Use when**: any time you have more than one concurrent task. This is the default. If you find yourself wanting `go(f)` directly, ask "what scope owns this task?" first.

#### 2. Tasks + Channels

`go(f) → handle`, `await h`, `channel_new(cap)`, `send`, `recv`, `try_send`, `try_recv`, `close`, `select`. The unstructured layer underneath structured concurrency. Tasks return values via channels or `await`. Channels are the **canonical synchronization primitive** — prefer them to locks whenever the problem is "passing data between tasks."

```quartz
# Spawn a single task and await its result
h = go() do -> compute() end
val = await h

# Channel between producer and consumer
ch = channel_new(16)        # buffered, capacity 16
go() do -> ch.send(work_item) end
item = ch.recv()

# Select over multiple channels
select
  case msg = <- ch1: process(msg)
  case <- ch2: shutdown()
  case <- timeout(100): retry()
end
```

**Use when**: you genuinely need a long-lived task or a producer/consumer pattern that doesn't fit a single scope.

#### 3. Synchronization Primitives

`Mutex`, `RwLock`, `Semaphore`, `Barrier`, `WaitGroup`, `OnceCell`. Use **only** when channels can't express the pattern naturally — typically protecting shared mutable state that multiple tasks read and write to in-place.

```quartz
m = mutex_new()
m.lock()
shared_state.update(...)
m.unlock()

# Or with auto-unlock
m.with() do -> shared_state.update(...) end

# Counting semaphore for resource pools
sem = semaphore_new(10)     # max 10 concurrent
sem.acquire()
do_work()
sem.release()
```

**Use when**: you need `Mutex` for in-place mutation under contention, `RwLock` for many-readers/few-writers, `Semaphore` for resource limits, `WaitGroup` for fan-out/fan-in without channels.

**Don't use when**: you can model the problem as message passing. Channels make ownership obvious.

### Combinators

For common patterns, prefer the named combinator over hand-rolled scope+go+await:

| Combinator | Pattern |
|------------|---------|
| `async_all(tasks)` | Await every task, collect results in order |
| `async_race(tasks)` | Return first completed result, cancel the rest |
| `async_map(items, f)` | Spawn `f(item)` for each item, collect in order |
| `async_timeout(f, ms)` | Run `f` with deadline, return `Option<T>` |
| `parallel_map(items, f)` | CPU-bound map across worker pool |
| `parallel_reduce(items, init, f)` | CPU-bound reduce |

### Cancellation

Cancellation is **cooperative** and propagates through scopes. A cancel token is created by `cancel_token_new()` and passed to `go_cancellable(f, tok)`. Inside `f`, check `tok.cancelled?` periodically (or use `tok.check()` to early-return). `go_scope_timeout` and `go_race` create cancel tokens implicitly.

**Don't poll-check on every iteration** of a tight loop — pick natural suspension points (I/O, channel ops, sleeps).

### Rules

1. **Default to structured.** `go(f)` outside a scope is a smell. Use `go_scope`/`go_supervisor`/`go_race`.
2. **Prefer channels over locks.** If two tasks need to coordinate, ask "can this be a channel?" before reaching for `Mutex`.
3. **Bounded channels by default.** `channel_new(cap)` with a finite cap. Unbounded channels (`channel_new_unbounded()`) leak under overload — use them only when you've thought about backpressure.
4. **Send/recv are blocking.** Use `try_send`/`try_recv` only when you genuinely have non-blocking work to do on the failure path. Never poll a channel in a tight loop.
5. **Closed channels are observable.** `recv` on a closed empty channel returns immediately; check with `try_recv_or_closed`. `send` on a closed channel panics — close from the producer side.
6. **`await` is colorless.** Any function can call `await h`. There is no `async fn` color in Quartz. The compiler tracks await sites and lowers them to state machines under the hood. Write straight-line code.
7. **Don't `sched_spawn`/`sched_park`/`completion_watch` directly.** Those are runtime internals — they exist for the standard library, not user code. If you find yourself reaching for them, the right answer is almost always to use `go` and channels instead, or to file a missing combinator as a roadmap item.

---

## Iterators

Quartz iterators are **lazy** and **composable**. The core protocol:

```quartz
# Every iterator has a next() method returning Option<T>
match iter.next()
  Some(val) => process(val)       # Unqualified variants
  None => break
end
```

Adapters transform iterators without evaluating:

```quartz
var it = range_iter(0, 100)
var result = iter_map(-> it.next(), x -> x * 2)
             |> iter_filter(-> result.next(), x -> x > 50)
             |> iter_take(-> result.next(), 5)
             |> iter_collect
```

**Eager vs Lazy:**
- Collection methods (`v.map(f)`, `v.filter(pred)`) are **eager** — they return a new Vec immediately
- Iterator adapters (`iter_map`, `iter_filter`) are **lazy** — they compose without allocating

Use eager methods for small collections. Use iterators for large data or when you want to short-circuit.

---

## Anti-Patterns

**Don't use sentinels.** Return `Option<T>` instead of `-1` or `0` for "not found."

**Don't mix mutation and return.** A function either mutates (returns Void) or returns a new value. Never both.

**Don't prefix with type names in UFCS context.** Write `v.push(x)`, not `v.vec_push(x)`. The type-prefixed form (`vec_push(v, x)`) is for function-call syntax only.

**Don't use `len`.** Use `size`. Always.

**Don't use `del` or `remove` for key-based deletion.** Use `delete`.

**Don't return raw values from fallible operations.** If it can fail, wrap in `Option<T>` or `Result<T, E>`.
