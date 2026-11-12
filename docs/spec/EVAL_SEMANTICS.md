# Quartz Evaluation Semantics

> **Version**: v5.25.0-alpha  
> **Status**: DRAFT — Formal operational semantics for the Quartz language  
> **Audience**: Compiler implementers and language specification readers

---

## 1. Notation and Conventions

### 1.1 Semantic Domains

| Domain | Symbol | Description |
|--------|--------|-------------|
| Values | `v` | Runtime values (all represented as `i64`) |
| Environments | `Γ` | Variable → Value bindings |
| Expressions | `e` | Syntactic expressions |
| Statements | `s` | Syntactic statements |
| Programs | `P` | Top-level declarations |
| Results | `R` | `Val(v)` \| `Return(v)` \| `Break` \| `Continue` |

### 1.2 Judgment Forms

| Form | Meaning |
|------|---------|
| `Γ ⊢ e ⇓ v, Γ'` | Expression `e` evaluates to value `v` producing new environment `Γ'` |
| `Γ ⊢ s ⇒ R, Γ'` | Statement `s` produces result `R` and new environment `Γ'` |
| `Γ ⊢ body ⇒ R, Γ'` | Function body evaluates to result `R` |

### 1.3 Runtime Representation

All values at runtime are `i64`. There is no type erasure at compile time — types exist only for the checker.

```
v ::= n                  -- integer literal (i64)
    | ptr                -- heap pointer (i64, via inttoptr)
    | fptr               -- function pointer (i64)
    | closure_ptr        -- closure (tagged pointer, low bit = 1)
    | 0                  -- nil / false / void
    | 1                  -- true
```

---

## 2. Expression Evaluation

### 2.1 Literals

```
─────────────────────────
Γ ⊢ n ⇓ n, Γ                              [E-INT]

─────────────────────────
Γ ⊢ true ⇓ 1, Γ                            [E-TRUE]

─────────────────────────
Γ ⊢ false ⇓ 0, Γ                           [E-FALSE]

─────────────────────────
Γ ⊢ nil ⇓ 0, Γ                             [E-NIL]
```

String literals are allocated at compile time as global constants and referenced via pointer:
```
Γ ⊢ "s" ⇓ ptr_to_global_string(s), Γ      [E-STRING]
```

### 2.2 Variables

```
Γ(x) = v
─────────────────────────
Γ ⊢ x ⇓ v, Γ                              [E-VAR]
```

### 2.3 Binary Operations

```
Γ ⊢ e₁ ⇓ v₁, Γ₁    Γ₁ ⊢ e₂ ⇓ v₂, Γ₂
─────────────────────────────────────────────
Γ ⊢ e₁ ⊕ e₂ ⇓ v₁ ⊕ v₂, Γ₂               [E-BINOP]
```

Where `⊕ ∈ {+, -, *, /, %, ==, !=, <, <=, >, >=, &&, ||, &, |, ^, <<, >>}`

**Short-circuit evaluation** for `&&` and `||`:
```
Γ ⊢ e₁ ⇓ 0, Γ₁
─────────────────────────
Γ ⊢ e₁ && e₂ ⇓ 0, Γ₁                     [E-AND-SHORT]

Γ ⊢ e₁ ⇓ v₁, Γ₁    v₁ ≠ 0    Γ₁ ⊢ e₂ ⇓ v₂, Γ₂
─────────────────────────────────────────────
Γ ⊢ e₁ && e₂ ⇓ v₂, Γ₂                     [E-AND-EVAL]

Γ ⊢ e₁ ⇓ v₁, Γ₁    v₁ ≠ 0
─────────────────────────
Γ ⊢ e₁ || e₂ ⇓ v₁, Γ₁                     [E-OR-SHORT]
```

### 2.4 Unary Operations

```
Γ ⊢ e ⇓ v, Γ'
─────────────────────────
Γ ⊢ -e ⇓ 0 - v, Γ'                        [E-NEG]

Γ ⊢ e ⇓ v, Γ'
─────────────────────────
Γ ⊢ !e ⇓ (v == 0 ? 1 : 0), Γ'             [E-NOT]
```

### 2.5 Function Calls

```
Γ ⊢ f ⇓ fptr, Γ₁
Γ₁ ⊢ e₁ ⇓ v₁, Γ₂  ...  Γₙ ⊢ eₙ ⇓ vₙ, Γₙ₊₁
Γ_body = {p₁ → v₁, ..., pₙ → vₙ}
Γ_body ⊢ body ⇒ Return(v), _
─────────────────────────────────────────────
Γ ⊢ f(e₁, ..., eₙ) ⇓ v, Γₙ₊₁             [E-CALL]
```

**Closure calls** (tagged pointers with low bit = 1):
```
Γ ⊢ f ⇓ closure_ptr, Γ₁
closure_ptr = (env_ptr << 1) | 1
Γ_env = load_closure_env(env_ptr)
Γ₁ ⊢ e₁ ⇓ v₁, Γ₂  ...  Γₙ ⊢ eₙ ⇓ vₙ, Γₙ₊₁
Γ_body = Γ_env ∪ {p₁ → v₁, ..., pₙ → vₙ}
Γ_body ⊢ body ⇒ Return(v), _
─────────────────────────────────────────────
Γ ⊢ f(e₁, ..., eₙ) ⇓ v, Γₙ₊₁             [E-CLOSURE-CALL]
```

### 2.6 UFCS (Uniform Function Call Syntax)

UFCS is syntactic sugar desugared before evaluation:
```
e.f(args...)  ≡  f(e, args...)              [DESUGAR-UFCS]
```

For methods defined via `extend`, the receiver is passed as the first argument.

### 2.7 Struct Construction

```
Γ ⊢ e₁ ⇓ v₁, Γ₁  ...  Γₙ ⊢ eₙ ⇓ vₙ, Γₙ₊₁
ptr = malloc(n × 8)
store(ptr + 0, v₁)  ...  store(ptr + (n-1)×8, vₙ)
─────────────────────────────────────────────
Γ ⊢ S { f₁: e₁, ..., fₙ: eₙ } ⇓ ptr, Γₙ₊₁  [E-STRUCT]
```

### 2.8 Field Access

```
Γ ⊢ e ⇓ ptr, Γ'
offset = field_offset(S, f)
v = load(ptr + offset)
─────────────────────────
Γ ⊢ e.f ⇓ v, Γ'                            [E-FIELD]
```

Where `field_offset` returns the byte offset (always `field_index × 8` for standard structs).

### 2.9 Lambda / Closure Construction

```
vars = free_variables(body) ∩ dom(Γ)
env_ptr = malloc(|vars| × 8)
∀ (xᵢ, i) ∈ enumerate(vars): store(env_ptr + i×8, Γ(xᵢ))
closure_ptr = (env_ptr << 1) | 1
─────────────────────────────────────────────
Γ ⊢ (p₁, ..., pₙ) -> body ⇓ closure_ptr, Γ [E-LAMBDA]
```

**Capture semantics**: Variables are captured **by value** at the time of closure construction. Subsequent mutations to the captured variable do not affect the closure's copy.

---

## 3. Control Flow

### 3.1 Variable Binding

**Immutable binding** (`x = e`):
```
Γ ⊢ e ⇓ v, Γ'
─────────────────────────
Γ ⊢ x = e ⇒ Val(()), Γ'[x → v]            [S-LET]
```

**Mutable binding** (`var x = e`):
```
Γ ⊢ e ⇓ v, Γ'
─────────────────────────
Γ ⊢ var x = e ⇒ Val(()), Γ'[x → v]        [S-VAR]
```

**Assignment** (only for `var` bindings):
```
Γ ⊢ e ⇓ v, Γ'    x ∈ mutable(Γ)
─────────────────────────
Γ ⊢ x = e ⇒ Val(()), Γ'[x → v]            [S-ASSIGN]
```

**Compound assignment** desugars:
```
x += e  ≡  x = x + e                       [DESUGAR-COMPOUND]
x -= e  ≡  x = x - e
x *= e  ≡  x = x * e
```

### 3.2 If/Else

```
Γ ⊢ e ⇓ v, Γ₁    v ≠ 0    Γ₁ ⊢ body_then ⇒ R, Γ₂
─────────────────────────────────────────────
Γ ⊢ if e then body_then else body_else end ⇒ R, Γ₂  [S-IF-TRUE]

Γ ⊢ e ⇓ v, Γ₁    v = 0    Γ₁ ⊢ body_else ⇒ R, Γ₂
─────────────────────────────────────────────
Γ ⊢ if e then body_then else body_else end ⇒ R, Γ₂  [S-IF-FALSE]
```

**Truthiness**: Any non-zero value is truthy. Zero is falsy.

### 3.3 While Loop

```
Γ ⊢ e ⇓ v, Γ₁    v = 0
─────────────────────────
Γ ⊢ while e do body end ⇒ Val(()), Γ₁     [S-WHILE-DONE]

Γ ⊢ e ⇓ v, Γ₁    v ≠ 0
Γ₁ ⊢ body ⇒ Val(()), Γ₂
Γ₂ ⊢ while e do body end ⇒ R, Γ₃
─────────────────────────────────────────────
Γ ⊢ while e do body end ⇒ R, Γ₃           [S-WHILE-CONT]

Γ ⊢ e ⇓ v, Γ₁    v ≠ 0
Γ₁ ⊢ body ⇒ Break, Γ₂
─────────────────────────────────────────────
Γ ⊢ while e do body end ⇒ Val(()), Γ₂     [S-WHILE-BREAK]

Γ ⊢ e ⇓ v, Γ₁    v ≠ 0
Γ₁ ⊢ body ⇒ Continue, Γ₂
Γ₂ ⊢ while e do body end ⇒ R, Γ₃
─────────────────────────────────────────────
Γ ⊢ while e do body end ⇒ R, Γ₃           [S-WHILE-CONTINUE]
```

### 3.4 For-In (Range)

Desugars to while loop:
```
for x in a..b         ≡  var x = a
  body                     while x < b
end                          body
                             x = x + 1
                           end             [DESUGAR-FOR-RANGE]
```

Inclusive ranges:
```
for x in a...b        ≡  var x = a
  body                     while x <= b
end                          body
                             x = x + 1
                           end             [DESUGAR-FOR-RANGE-INCL]
```

### 3.5 Match Expression

```
Γ ⊢ e ⇓ v, Γ₁
match_arm(v, armₖ) = (bindings, bodyₖ)     -- first matching arm
Γ₁ ∪ bindings ⊢ bodyₖ ⇓ vₖ, Γ₂
─────────────────────────────────────────────
Γ ⊢ match e { arm₁ ... armₙ } ⇓ vₖ, Γ₂   [E-MATCH]
```

**Pattern matching rules**:
- Integer literal: matches if `v == n`
- String literal: matches via `str_eq(v, s)`
- Wildcard `_`: always matches
- Variable `x`: always matches, binds `x → v`
- Enum variant `E::V(p₁, ..., pₙ)`: matches if tag equals variant tag, then recursively matches payloads

### 3.6 Return, Break, Continue

```
Γ ⊢ e ⇓ v, Γ'
─────────────────────────
Γ ⊢ return e ⇒ Return(v), Γ'              [S-RETURN]

─────────────────────────
Γ ⊢ break ⇒ Break, Γ                       [S-BREAK]

─────────────────────────
Γ ⊢ continue ⇒ Continue, Γ                 [S-CONTINUE]
```

### 3.7 Defer

`defer` registers an expression to execute at scope exit, in LIFO order:

```
Γ ⊢ body ⇒ R, Γ₁    (with deferred = [d₁, ..., dₙ] accumulated)
Γ₁ ⊢ dₙ ⇓ _, Γₙ   ...   Γ₂ ⊢ d₁ ⇓ _, Γ'
─────────────────────────────────────────────
scope with defers ⇒ R, Γ'                  [S-DEFER-EXIT]
```

Deferred expressions run regardless of how the scope exits (normal, return, break).

---

## 4. Enum Semantics

### 4.1 Enum Representation

Enums are heap-allocated with a tag field at offset 0:
```
Enum value layout:
  [offset 0]: tag (Int, variant index starting at 0)
  [offset 8]: payload field 1
  [offset 16]: payload field 2
  ...
```

### 4.2 Enum Construction

```
tag = variant_index(E, V)
ptr = malloc((1 + n) × 8)
store(ptr + 0, tag)
Γ ⊢ e₁ ⇓ v₁  ...  Γ ⊢ eₙ ⇓ vₙ
store(ptr + 8, v₁)  ...  store(ptr + n×8, vₙ)
─────────────────────────────────────────────
Γ ⊢ E::V(e₁, ..., eₙ) ⇓ ptr, Γ            [E-ENUM-CTOR]
```

### 4.3 Enum Pattern Matching

```
tag = load(ptr + 0)
tag == variant_index(E, V)
v₁ = load(ptr + 8)  ...  vₙ = load(ptr + n×8)
bindings = {p₁ → v₁, ..., pₙ → vₙ}
─────────────────────────────────────────────
match_arm(ptr, E::V(p₁, ..., pₙ)) = (bindings, body)  [MATCH-ENUM]
```

---

## 5. Desugaring Rules

| Surface Syntax | Desugared Form |
|---------------|----------------|
| `e.f(args)` | `f(e, args)` |
| `x += e` | `x = x + e` |
| `x -= e` | `x = x - e` |
| `for x in a..b body end` | `var x=a; while x<b do body; x=x+1 end` |
| `e₁ \|> f(args)` | `f(e₁, args)` |
| `unless cond body end` | `if !(cond) body end` |
| `expr if cond` | `if cond then expr end` (postfix guard) |
| `expr unless cond` | `if !(cond) then expr end` (postfix guard) |
| `a ?? b` | `if a != 0 then a else b end` |
| `a?.f` | `if a != 0 then a.f else 0 end` |

---

## 6. Program Execution Model

### 6.1 Top-Level Declarations

A Quartz program is a sequence of declarations processed in order:
1. **Imports** are resolved first (module dependency graph)
2. **Type declarations** (struct, enum, type, newtype) register types
3. **Global variables** are initialized in declaration order
4. **Function declarations** register callable definitions
5. **`main()` is called** — execution begins at `def main(): Int`

### 6.2 Function Resolution

Functions are resolved by name and arity. When multiple definitions exist:
1. Module-qualified names have priority
2. Local definitions shadow imports
3. Arity-based overloading selects the matching version

### 6.3 Exit Code

The program's exit code is the return value of `main()`, truncated to `i32`.

---

## 7. Generic Instantiation

### 7.1 Type Erasure Model

Generics use **existential type erasure** — all type parameters are erased to `i64` at runtime. A generic function `def id<T>(x: T): T = x` compiles to a single function that operates on `i64` values.

### 7.2 Specialization

The compiler may generate specialized versions of generic functions when the concrete type is known. This is an optimization and does not affect semantics.

### 7.3 Trait Dispatch

Trait methods are resolved statically by mangled name: `StructName$methodName`. Dynamic dispatch through trait objects is not currently supported.
