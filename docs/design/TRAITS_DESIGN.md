# Quartz Traits System Design (v5.0)

## Overview

Traits in Quartz provide a mechanism for:
1. Defining shared behavior across types (interfaces)
2. Enabling polymorphism through static dispatch (monomorphization)
3. Constraining generic type parameters

## Design Decisions

### 1. Static Dispatch (Monomorphization) — CHOSEN

Quartz uses **static dispatch** (not vtables/dynamic dispatch):
- All trait method calls resolved at compile time
- No runtime overhead
- Generic code is monomorphized (specialized for each concrete type)
- Similar to Rust's approach

**Why not vtables?**
- Quartz values simplicity and predictable performance
- vtables add indirection and complexity
- Dynamic dispatch rarely needed in systems languages

### 2. No Self Types Yet

Initially, traits won't support associated types or `Self` return types.
Keep it simple: methods take `self` as first parameter.

## Syntax

### Trait Declaration

```be
trait Eq
  def eq(self, other: Self): Bool
end

trait Ord: Eq  # Requires Eq
  def lt(self, other: Self): Bool
  def gt(self, other: Self): Bool
end

trait Enumerable<T>
  def each(self, f: Fn(T): Void): Void
  def map<U>(self, f: Fn(T): U): Array<U>
  def filter(self, f: Fn(T): Bool): Array<T>
  def reduce<U>(self, init: U, f: Fn(U, T): U): U
end
```

### Impl Blocks

```be
impl Eq for Int
  def eq(self, other: Int): Bool
    return self == other
  end
end

impl Ord for Int
  def lt(self, other: Int): Bool
    return self < other
  end
  
  def gt(self, other: Int): Bool
    return self > other
  end
end

impl<T> Enumerable<T> for Array<T>
  def each(self, f: Fn(T): Void): Void
    var i = 0
    while i < len(self)
      f(self[i])
      i += 1
    end
  end
  
  def map<U>(self, f: Fn(T): U): Array<U>
    result = array_new<U>()
    each(self, |x| array_push(result, f(x)))
    return result
  end
  
  # ... etc
end
```

### Trait Bounds

```be
# Simple bound
def max<T: Ord>(a: T, b: T): T
  if gt(a, b)
    return a
  else
    return b
  end
end

# Multiple bounds
def process<T: Eq + Ord>(items: Array<T>): Void
  # ...
end

# Where clause (complex bounds)
def complex<K, V>(map: Map<K, V>): Void
  where K: Eq, V: Clone
  # ...
end
```

## AST Node Types

### NodeTraitDef (new)
- `str1`: trait name
- `str2`: supertraits (comma-separated, or empty)
- `children`: method signatures (NodeDef nodes without bodies)
- `extras`: type parameters (NodeTypeParam nodes)

### NodeImplBlock (new)
- `str1`: trait name being implemented
- `str2`: implementing type
- `children`: method implementations (NodeDef nodes with bodies)
- `extras`: type parameters for generic impls

### NodeTraitBound (new)
- `str1`: type variable name
- `str2`: trait name (or "+" separated traits)
- Used in generic parameter constraints

## Token Types

Add to token_constants.qz:
- `TOK_TRAIT = 80`
- `TOK_IMPL = 81`
- `TOK_FOR = 82` (already exists? check)
- `TOK_WHERE = 83`

## Type Representation

### TraitType
In the type system, traits need representation:
- TYPE_TRAIT = new type constant
- Trait registry: name → trait info (methods, supertraits)
- Impl registry: (trait, type) → impl info (method implementations)

### Type Checking

1. **Trait Declaration**: Register trait with its methods
2. **Impl Block**: Verify all trait methods are implemented with correct signatures
3. **Trait Bounds**: When calling generic function, verify type satisfies bounds

## Implementation Plan

### Phase 1: Lexer + Parser
1. Add TOK_TRAIT, TOK_IMPL, TOK_WHERE tokens
2. Add NodeTraitDef, NodeImplBlock, NodeTraitBound AST nodes
3. Parse trait declarations
4. Parse impl blocks
5. Parse trait bounds in generic parameters

### Phase 2: Type Checking
1. Register traits in global scope
2. Type check trait method signatures
3. Type check impl blocks (verify completeness)
4. Enforce trait bounds on generic instantiation

### Phase 3: Code Generation
1. For each trait method call, resolve to concrete impl
2. Generate monomorphized code for generic functions
3. No vtables needed (static dispatch)

## Examples to Support

```be
# Basic trait
trait Show
  def show(self): String
end

impl Show for Int
  def show(self): String
    return int_to_string(self)
  end
end

impl Show for String
  def show(self): String
    return self
  end
end

# Generic function with trait bound
def print_all<T: Show>(items: Array<T>): Void
  var i = 0
  while i < len(items)
    puts(show(items[i]))
    i += 1
  end
end

# Usage
arr = [1, 2, 3]
print_all(arr)  # Prints: 1, 2, 3
```

## Resolved Questions (v5.27)

1. **Self type**: YES — `Self` resolves to the implementing type inside impl blocks, and to TYPE_INT (generic placeholder) inside trait definitions. Parameter and return annotations are substituted during impl registration.
2. **Default methods**: YES — Traits support default method implementations with `self`, `Self`, and cross-method delegation. The resolver synthesizes `Type$method` wrappers for inherited defaults.
3. **Orphan rules**: RELAXED — Duplicate impls (same trait + same type) are rejected at compile time. Relaxed orphan rules planned (own trait OR type). Currently single-compilation-unit enforcement.
4. **Coherence**: Two-layer approach: `tc_register_impl` is idempotent, Phase 1.65 in typecheck_walk detects user-written duplicate impl blocks with line-number error reporting.
5. **Open UFCS**: YES — Any function `f(x: T, ...)` in scope can be called as `x.f(...)`. Member methods and trait impls take precedence. No declaration needed.

## Deferred Features

- Associated types (`trait Iterator { type Item; ... }`)
- Higher-kinded types
- Cross-compilation-unit orphan rules
- Abstract trait methods (bodyless — currently requires default body)
- Dynamic dispatch / trait objects
