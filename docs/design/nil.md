# nil Implementation Plan

> **Status**: ⚠️ **Superseded philosophy — historical.** This doc describes the *permissive* "nil = 0, accepted anywhere,
> hybrid nil+Option" model shipped in early 2026 (`nil` IS implemented now; the C-bootstrap/Ruby-spec steps below are dead —
> the C bootstrap was retired Feb 2026 and there is no Ruby). **B.15 reverses this philosophy**: `Option<T>` becomes the *only*
> way to express absence, `nil`-as-value becomes a compile error outside the FFI boundary. See
> **[`B15_NIL_ELIMINATION.md`](B15_NIL_ELIMINATION.md)** for the research-first sub-memo + migration plan. The *runtime model*
> section below (nil/false/0 all `0`, truthiness) remains accurate; the *philosophy* section is what B.15 overturns.

## Overview

Quartz currently has `true` and `false` but **`nil` is documented but not implemented**. This plan adds `nil` as a first-class keyword while also providing `Option[T]` for explicit optionality.

## Design Decision

**Both: nil + Option types** — the world-class hybrid approach.

## Runtime Model

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Quartz's Truth & Optionality Model                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  LAYER 1: Runtime Values (all i64)                                          │
│  ═════════════════════════════════                                          │
│                                                                             │
│    nil   = 0         # "nothing" / null pointer                             │
│    false = 0         # boolean false                                        │
│    true  = 1         # boolean true                                         │
│    0     = 0         # integer zero                                         │
│                                                                             │
│    All three (nil, false, 0) are the SAME at runtime.                       │
│    This is intentional — Quartz is a systems language.                          │
│                                                                             │
│  LAYER 2: Truthiness (for conditionals)                                     │
│  ══════════════════════════════════════                                     │
│                                                                             │
│    Falsy:  0, false, nil (all equivalent)                                   │
│    Truthy: everything else (non-zero)                                       │
│                                                                             │
│    if value     # truthy check                                              │
│      ...                                                                    │
│    end                                                                      │
│                                                                             │
│  LAYER 3: Compile-Time Types (rich, existential)                            │
│  ════════════════════════════════════════════════                           │
│                                                                             │
│    Bool        # true or false                                              │
│    Int         # any integer                                                │
│    Option[T]   # Some(value) or None — explicit optionality                 │
│    Result[T,E] # Ok(value) or Err(error) — explicit fallibility             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## The Philosophy

- **nil** is for quick-and-dirty: "I don't have a value"
- **Option[T]** is for when you want the compiler to enforce handling
- You can always go from explicit → implicit (Option → nil)
- But you can't go implicit → explicit without checking

## Usage Examples

### Quick and Dirty (nil-based)

```be
def find_user(id: Int): User
  if id == 0
    return nil   # No user found
  end
  User { id: id, name: "Alice" }
end

user = find_user(42)
if user
  print(user.name)
end
```

### Explicit and Safe (Option-based)

```be
def find_user_safe(id: Int): Option[User]
  if id == 0
    return Option::None
  end
  Option::Some(User { id: id, name: "Alice" })
end

match find_user_safe(42)
  Option::Some(user) => print(user.name)
  Option::None => print("Not found")
end
```

### Optional Chaining (future)

```be
# If we add ?. operator
user?.profile?.avatar?.url
```

## Implementation Steps

### Phase 1–2: `nil` keyword (DONE)

`nil` is implemented in the self-hosted compiler today: `TOK_NIL` (`lexer.qz`), `NodeNilLit` parse (`parser.qz`), typed as `Int`
(`typecheck.qz`), emits `0` (`codegen.qz`). B.15 does not remove the literal — it restricts *where it is accepted as a value*
(see [`B15_NIL_ELIMINATION.md`](B15_NIL_ELIMINATION.md)).

### Phase 3: Add `Option[T]` to stdlib

```be
# std/core/option.qz
enum Option[T]
  Some(value: T)
  None
end

def option_is_some(opt: Option[T]): Bool
  match opt
    Option::Some(_) => true
    Option::None => false
  end
end

def option_unwrap(opt: Option[T]): T
  match opt
    Option::Some(v) => v
    Option::None => panic("unwrap on None")
  end
end

def option_unwrap_or(opt: Option[T], default: T): T
  match opt
    Option::Some(v) => v
    Option::None => default
  end
end

def option_map(opt: Option[T], f: fn(T): U): Option[U]
  match opt
    Option::Some(v) => Option::Some(f(v))
    Option::None => Option::None
  end
end
```

### Phase 4: Add `Result[T, E]` to stdlib

```be
# std/core/result.qz
enum Result[T, E]
  Ok(value: T)
  Err(error: E)
end

def result_is_ok(res: Result[T, E]): Bool
  match res
    Result::Ok(_) => true
    Result::Err(_) => false
  end
end

def result_unwrap(res: Result[T, E]): T
  match res
    Result::Ok(v) => v
    Result::Err(e) => panic("unwrap on Err")
  end
end

def result_map(res: Result[T, E], f: fn(T): U): Result[U, E]
  match res
    Result::Ok(v) => Result::Ok(f(v))
    Result::Err(e) => Result::Err(e)
  end
end
```


## Compatibility Notes

- `nil`, `false`, and `0` are all the same value at runtime
- This is by design for C FFI compatibility (NULL == 0)
- Type system can distinguish them at compile time if needed
- Existing code using `0` as "no value" continues to work

## Related Future Work

- **Optional chaining**: `user?.profile?.name`
- **Nil coalescing**: `value ?? default`
- **Guard clauses**: `return if x == nil`
- **Postfix guards with nil**: `result? or return nil`

---

*Created: January 26, 2026*  
*Decision: Both nil + Option types (hybrid approach)*
