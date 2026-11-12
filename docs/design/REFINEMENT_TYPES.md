# Phase R: Refinement Types for Quartz

> **Status**: Design document — no compiler changes
> **Author**: Design session, March 2026
> **Target**: Post-v6.0.0 (research/moonshot phase)

---

## 1. Motivation

Quartz's type system today catches a large class of errors at compile time: type mismatches, exhaustiveness failures, move-after-use, borrow violations. But it cannot express **value-level constraints** — the compiler can verify that `divide(a, b)` receives two `Int` arguments, but not that `b != 0`.

Refinement types close this gap. They attach logical predicates to types, verified at compile time, with **zero runtime cost** — a perfect fit for Quartz's existential model where types vanish at runtime.

### What Refinement Types Would Enable

```quartz
# Array bounds — no runtime check needed
def get<T>(v: Vec<T>, i: Int where i >= 0 and i < v.size): T

# Non-null guarantees — compiler proves it
type NonEmpty = String{s | s.size > 0}

# Natural numbers — eliminates an entire class of bugs
type Nat = Int{n | n >= 0}

# Sorted preconditions
def binary_search(arr: Vec<Int>, key: Int): Int
  @requires sorted(arr)
  @ensures result >= -1
```

---

## 2. Prior Art

### 2.1 Liquid Haskell

**Approach**: Extends Haskell types with logical predicates in `{-@ ... @-}` annotations. Uses "Liquid Typing" — a fixpoint algorithm that generates verification conditions (VCs) from GHC Core, then sends them to Z3.

**Key mechanism**: Restricts predicates to quantifier-free logic of equality, uninterpreted functions, and linear arithmetic. This makes checking decidable and fully automated — no manual proofs.

**Strengths**: Fully automated; GHC plugin (not a fork); proven on 10K+ lines. Gradual adoption via annotations in comments.

**Weaknesses**: Quantifier-free restriction limits expressiveness (no inductive proofs without hints). Limited to Haskell's lazy evaluation model.

**Source**: Vazou et al., "Refinement Types for Haskell" (ICFP 2014); ucsd-progsys/liquidhaskell.

### 2.2 F*

**Approach**: Full dependent types + refinement predicates (`x:int{x >= 0}`). Type checking generates proof obligations sent to Z3. For SMT-proven facts, no explicit proof term is constructed (proof irrelevance).

**Key mechanism**: When SMT solver can't handle a proof automatically, Meta-F* tactics manipulate VCs into SMT-friendly fragments.

**Strengths**: Most expressive system — can encode nearly any property. Extracts verified code to F#, C, WASM.

**Weaknesses**: Full dependent types add significant complexity. Semi-automated — sometimes needs manual tactics. Steep learning curve.

**Source**: Swamy et al., "Dependent Types and Multi-Monadic Effects in F*" (POPL 2016); fstar-lang.org.

### 2.3 Ada/SPARK

**Approach**: Subtype predicates on Ada types. `Static_Predicate` (compile-time) and `Dynamic_Predicate` (runtime check). GNATprove tool performs formal verification.

**Key mechanism**: Predicates are inherited by subtypes. Static predicates use restricted expressions (membership tests, case expressions). GNATprove mathematically proves absence of runtime errors (buffer overflows, division by zero, null dereferences).

**Strengths**: Battle-tested in aerospace/defense. Pragmatic — mix static and dynamic checking. Excellent tooling (GNAT/GNATprove).

**Weaknesses**: Verbose syntax. Predicates are somewhat limited in expressiveness. Ecosystem is niche.

**Source**: AdaCore, "SPARK User's Guide"; ada-auth.org RM 2012+.

### 2.4 Dependent ML

**Approach**: Index types — types parameterized by static indices from a constraint domain (natural numbers with linear inequalities). `List(n)` means "list of length n".

**Key mechanism**: Index language is entirely separate from runtime language. Type checking remains decidable. Constraint solver (not SMT) checks index predicates.

**Strengths**: Clean separation of static indices from runtime. Decidable type checking. Practical for array bounds elimination.

**Weaknesses**: Restricted to its constraint domain (linear arithmetic over naturals). Superseded by ATS (more complex).

**Source**: Xi & Pfenning, "Eliminating Array Bound Checking through Dependent Types" (PLDI 1998); Xi, "Dependent ML" (JFP 2007).

### 2.5 Synthesis

| Dimension | Liquid Haskell | F* | Ada/SPARK | Dependent ML |
|-----------|---------------|-----|-----------|-------------|
| Automation | **Full** | Semi | Full (static) | Full |
| Expressiveness | Medium | **High** | Low–Medium | Low |
| Ergonomics | Good (annotations) | Poor (tactics) | Good (subtypes) | Good (index types) |
| Runtime cost | Zero | Zero | Dynamic optional | Zero |
| SMT dependency | Z3 required | Z3 required | GNATprove | No (constraint solver) |

**Best fit for Quartz**: Liquid Haskell's approach — fully automated, annotation-based, zero runtime cost. Restrict to decidable logic fragment. Take inspiration from Ada/SPARK's pragmatic "static vs dynamic" split.

---

## 3. Syntax Proposals

### Proposal A: `where` Clause (Recommended)

```quartz
# On function parameters
def divide(a: Int, b: Int where b != 0): Int = a / b

# On return types
def abs(n: Int): Int where result >= 0
  if n < 0
    return 0 - n
  end
  return n
end

# Multiple constraints
def slice(s: String, start: Int where start >= 0, end: Int where end <= s.size and end >= start): String

# On type definitions
type PosInt = Int where self > 0
type NonEmptyString = String where self.size > 0
type ValidIndex<T> = Int where self >= 0 and self < T.size
```

**Rationale**: `where` is familiar from SQL, Haskell, Rust (trait bounds). Reads naturally: "b: Int where b is not zero." Doesn't require new delimiters or symbols.

### Proposal B: Inline Predicate `{}`

```quartz
# Liquid Haskell-style
def divide(a: Int, b: Int{v | v != 0}): Int = a / b
type PosInt = Int{v | v > 0}
type Bounded = Int{v | v >= 0 and v < 100}
```

**Rationale**: Compact, mathematically clean. However, `{}` is already used for:
- Struct literals: `Point { x: 10, y: 20 }`
- Set literals: `{1, 2, 3}`
- HashMap literals: `{"key" => val}`
- Curly block expressions

> [!WARNING]
> Proposal B creates parser ambiguity with existing `{}` uses. Proposal A is strongly preferred.

### Proposal C: `@refine` Annotation

```quartz
@refine(b != 0)
def divide(a: Int, b: Int): Int = a / b

@refine(result >= 0)
def abs(n: Int): Int
  if n < 0
    return 0 - n
  end
  return n
end
```

**Rationale**: Uses existing annotation infrastructure (`@cfg`, `@derive`, `@packed`). Clean separation of spec from code. But predicate variables (`b`) are disconnected from parameter positions.

### Recommendation

**Proposal A (`where` clause)** is the clear winner:
- No parser ambiguity
- Self-documenting (reads naturally)
- Scales to complex multi-parameter constraints
- Consistent with Rust/Haskell convention

---

## 4. SMT Solver Integration Strategy

### 4.1 Architecture

```
Source (.qz) → Lex → Parse → TypeCheck → [Refinement Check] → MIR → Codegen
                                                ↓
                                        Generate VCs
                                                ↓
                                        Encode to SMT-LIB2
                                                ↓
                                        Call Z3 (child process)
                                                ↓
                                        SAT → verified  |  UNSAT → error
```

The refinement checker is a **new pass** inserted between type checking and MIR lowering. It reads the typed AST, extracts refinement annotations, generates verification conditions, and delegates to Z3.

### 4.2 Z3 Integration Options

| Option | Mechanism | Complexity | Distribution |
|--------|-----------|-----------|-------------|
| **A: Child process** | Shell out to `z3` binary, read SMT-LIB2 output | Low | User installs Z3 separately |
| **B: C FFI** | Link `libz3.so` via Quartz's C FFI intrinsics | Medium | Bundled or `-lz3` link flag |
| **C: Embedded solver** | Build a simple solver in Quartz (linear arithmetic only) | High | Zero dependencies |

**Recommended: Option A (child process)** for initial implementation.

- Quartz already has `exec_subprocess` intrinsics for running child processes
- Zero linking complexity
- SMT-LIB2 is a standardized text format — easy to generate and parse
- Z3 is widely available (`brew install z3`, `apt install z3`)
- Fallback: if Z3 not found, skip refinement checking with a warning

### 4.3 Decidable Logic Fragment

Restrict refinements to **QF_LIA** (quantifier-free linear integer arithmetic) + uninterpreted functions:

- Integer comparisons: `x > 0`, `x <= y`, `x != 0`
- Linear arithmetic: `x + y <= z`, `2 * x < 100` (no `x * y`)
- Boolean connectives: `and`, `or`, `not`
- Uninterpreted functions: `sorted(arr)`, `valid(ptr)` (user-declared, SMT treats as opaque)
- Size properties: `v.size`, `s.size` (rewritten to uninterpreted functions)

**Excluded** (for now): nonlinear arithmetic (`x * y > z`), quantifiers (`forall`, `exists`), inductive proofs, floating point.

---

## 5. Interaction with Quartz's Existential Type Model

### 5.1 Perfect Compatibility

Quartz's existential model (types vanish at runtime, everything is `i64`) is **ideally suited** for refinement types:

- Refinements are inherently compile-time-only — they add no runtime representation
- No "type erasure" problem — refinements were never there at runtime
- Struct field refinements work naturally: `struct Range { lo: Int, hi: Int where hi >= lo }` — the `where` is checked at construction sites, not stored

### 5.2 Refinement Flow

```quartz
type PosInt = Int where self > 0

def sqrt_int(n: PosInt): PosInt
  # ... Newton's method
  # Compiler verifies: n > 0 ⊢ result > 0
end

def main(): Int
  x = 42
  y = sqrt_int(x)     # OK: compiler proves 42 > 0
  z = sqrt_int(-1)    # ERROR: cannot prove -1 > 0
  
  var w = read_int()
  if w > 0
    sqrt_int(w)        # OK: branch condition w > 0 is in scope
  end
  
  sqrt_int(w)          # ERROR: cannot prove w > 0 (no branch guard)
  return 0
end
```

### 5.3 Refinement State Tracking

The refinement checker maintains a **path condition** — the conjunction of all branch conditions along the current execution path. When a refined function is called, the checker proves `path_condition ⊢ refinement_predicate`.

- `if x > 0` adds `x > 0` to the path condition for the then-branch
- `while x < n` adds `x < n` to the loop body's path condition
- `match` arms add their pattern conditions
- Function preconditions are assumed true in the function body

---

## 6. Gradual Adoption Path

### Phase R.0: Infrastructure (1–2 days)

- Parse `where` clauses on function parameters, return types, and type definitions
- Store refinements in the AST as annotation nodes
- No verification — just parse and ignore

### Phase R.1: Simple Numeric Refinements (3–5 days)

- Implement VC generation for integer comparisons and linear arithmetic
- Integrate Z3 child process (generate SMT-LIB2, parse output)
- Verify function preconditions at call sites
- `@check` pragma to enable/disable per module
- Error messages: "Cannot verify: b != 0 at line 42. Path condition: (none)"

### Phase R.2: Path Sensitivity (2–3 days)

- Track branch conditions as path conditions
- Support `if`/`elsif`/`else`, `match`, `while` loop invariants
- Verify postconditions and return-type refinements

### Phase R.3: Container Properties (2–3 days)

- `.size` as uninterpreted function in SMT
- Verify array bounds: `v[i]` generates `0 <= i and i < v.size`
- Track size changes through `push`/`pop`

### Phase R.4: User-Declared Properties (1–2 days)

- `@axiom def sorted(arr: Vec<Int>): Bool` — declare without body (SMT treats as uninterpreted)
- `@ensures sorted(result)` — postcondition annotations
- `@requires sorted(arr)` — precondition annotations (alternative to `where`)

---

## 7. Concrete Examples

### Array Bounds Safety

```quartz
# Before: runtime bounds check or manual validation
def safe_get<T>(v: Vec<T>, i: Int): T
  if i < 0 or i >= v.size
    panic("index out of bounds")
  end
  return v[i]
end

# After: compile-time guarantee, no runtime check needed
def safe_get<T>(v: Vec<T>, i: Int where i >= 0 and i < v.size): T
  return v[i]  # guaranteed safe by refinement
end
```

### Division Safety

```quartz
def divide(a: Int, b: Int where b != 0): Int = a / b
def modulo(a: Int, b: Int where b != 0): Int = a % b

# Usage
x = divide(10, 3)    # OK
y = divide(10, 0)    # COMPILE ERROR: cannot prove 0 != 0

var d = parse_int(input)
if d != 0
  divide(100, d)     # OK: branch condition proves d != 0
end
```

### Natural Numbers

```quartz
type Nat = Int where self >= 0

def factorial(n: Nat): Nat
  if n == 0
    return 1
  end
  return n * factorial(n - 1)  # Compiler proves: n >= 0 and n != 0 ⊢ n - 1 >= 0
end
```

---

## 8. Feasibility Assessment

### Feasible (R.0–R.2, ~2 weeks)

- Parsing `where` clauses — straightforward parser extension
- Z3 child process integration — Quartz already has subprocess intrinsics
- Simple numeric refinements (comparisons, linear arithmetic)
- Path-sensitive checking through if/match branches
- Opt-in `@check` pragma

### Ambitious but Achievable (R.3, ~1 week additional)

- Container `.size` tracking via uninterpreted functions
- Basic array bounds verification

### Moonshot (R.4+, deferred)

- User-declared axioms and lemmas
- Loop invariant inference (undecidable in general)
- Nonlinear arithmetic (`x * y <= z`)
- Full dependent types (types parameterized by runtime values)
- Inductive proofs over data structures (sorted, balanced, etc.)
- Multiple SMT backend support (CVC5, MathSat)

### Genuine Tensions

1. **Expressiveness vs. decidability**: The more predicates we allow, the more often Z3 times out or returns "unknown". QF_LIA is the safe default but can't express multiplication.

2. **Ergonomics vs. precision**: Too many annotations burden the programmer. Too few and the system can't prove anything useful. The gradual adoption path (opt-in, module-level) mitigates this.

3. **Compilation speed**: Each refinement check requires a Z3 invocation. For large programs with many refined types, this could dominate compilation time. Mitigation: cache VCs per module, only re-check changed functions (leveraging P.2 incremental compilation).

4. **Error messages**: SMT solver failures are notoriously hard to explain to users. "Cannot verify constraint" is unhelpful. Need to invest in mapping solver failures back to source locations with suggested fixes.

---

## 9. References

- Vazou et al., "Refinement Types for Haskell" (ICFP 2014)
- Swamy et al., "Dependent Types and Multi-Monadic Effects in F*" (POPL 2016)
- Xi & Pfenning, "Eliminating Array Bound Checking through Dependent Types" (PLDI 1998)
- Xi, "Dependent ML: An Approach to Practical Programming with Dependent Types" (JFP 2007)
- AdaCore, "SPARK User's Guide" — learn.adacore.com
- de Moura & Bjørner, "Z3: An Efficient SMT Solver" (TACAS 2008)
- Rondon et al., "Liquid Types" (PLDI 2008)
