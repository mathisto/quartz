# PL Paper Notation Primer

PL papers use a compact symbolic vocabulary that looks intimidating until you learn the key. Once you have the key, the notation does *less* work than English prose — it's denser, more precise, and universal across papers. This document is the key.

Every notation fragment is translated into English the first time it appears. Come back when you hit something new in a paper. The primer is expected to grow as we encounter new symbols.

---

## Part 1 — Inference rules: the core shape

Almost every type system, semantics, or logic paper uses **inference rules**. They look like this:

```
  premise₁   premise₂   ...   premiseₙ
  ─────────────────────────────────────  (name)
              conclusion
```

Read: "If all the premises hold, then the conclusion holds. This rule is called *name*."

The horizontal bar is pronounced "therefore" or "if-then." Reading top-to-bottom follows inference. Reading bottom-to-top follows proof search ("to prove the conclusion, I need to prove the premises").

### A concrete rule

```
  Γ ⊢ e₁ : Int    Γ ⊢ e₂ : Int
  ─────────────────────────────── (T-Plus)
       Γ ⊢ e₁ + e₂ : Int
```

Read out loud: "If, in context Γ, e₁ has type Int, and in context Γ, e₂ has type Int, then in context Γ, e₁ + e₂ has type Int. This is the T-Plus rule."

That's the whole shape. Every type system is a stack of these.

---

## Part 2 — Contexts and judgments

`Γ ⊢ e : τ` is a **typing judgment**. Parts:

- `Γ` (capital gamma) — the **context**. A finite mapping from variable names to types. Written as a comma-separated list: `x:Int, y:String, z:Bool`.
- `⊢` (turnstile, "tack") — "proves" or "entails" or "gives." Separates assumptions from conclusions.
- `e` — an expression.
- `:` — "has type."
- `τ` (tau) — a type.

Full reading: **"In context Γ, expression e has type τ."**

Context extension: `Γ, x:τ` means "the context Γ with the additional binding `x:τ`." Used in rules for lambdas and variable lookup.

### Another concrete rule

Lambda introduction:

```
  Γ, x:τ₁ ⊢ e : τ₂
  ─────────────────────── (T-Lambda)
  Γ ⊢ λx. e : τ₁ → τ₂
```

Read: "If in the context Γ extended with x bound to τ₁, the body e has type τ₂, then the lambda itself has type τ₁ → τ₂."

`λx. e` is "the function taking x, returning e." `λ` (lambda) is the binder. The dot separates the bound variable from the body.

---

## Part 3 — Greek letter conventions

Greek letters in PL papers aren't arbitrary. Seeing `ρ` in a paper telegraphs "row polymorphism." The key:

| Letter | Pronounced | Typical role |
|---|---|---|
| α β γ δ | alpha, beta, gamma, delta | Type variables |
| σ τ | sigma, tau | Types (sometimes type schemes) |
| ρ | rho | **Rows** — sets of labeled things with an optional tail variable. Records, effect rows. |
| ε | epsilon | Effects (a single effect, or an effect row depending on paper) |
| φ χ | phi, chi | Formulas, predicates |
| Γ Δ Θ | Gamma, Delta, Theta | Contexts / typing environments |
| Φ Ψ | Phi, Psi | Larger assumption sets; sometimes stores or memories |
| λ | lambda | Function abstraction. `λx. e` is a function |
| μ | mu | Recursive binder — see §11.1 for full treatment |
| Π Σ | Pi, Sigma | Dependent function/product types (rare in effects papers) |

`∀α. τ` reads "for all α, τ" — a **polymorphic type scheme**. `∀α. α → α` is the type of the identity function.

---

## Part 4 — Substitution

`e[x ↦ v]` — "e with x replaced by v."

This is **substitution** — the operation that makes beta reduction work. `(λx. x + 1)[x ↦ 5]` produces `5 + 1`.

The arrow `↦` is "maps to." Distinguished from `→` which is function type.

Substitution is capture-avoiding — if `v` contains a free variable with the same name as something bound inside `e`, rename the bound thing first. Papers handle this formally; you mostly don't have to think about it when reading.

---

## Part 5 — Reduction arrows (overloaded)

| Arrow | Meaning |
|---|---|
| `→` in a type | Function type: `Int → Int` |
| `→` between terms | One step of reduction: `e → e'` means "e reduces to e' in one step" |
| `→*` | Zero or more reduction steps |
| `→β` | Beta reduction: `(λx. e) v →β e[x ↦ v]` |
| `→η` | Eta reduction (mostly safe to ignore when reading) |
| `↓` or `⟹` | Big-step evaluation: `e ↓ v` means "e evaluates to v" |

Context tells you which `→` you're looking at. Types vs. terms is almost always clear from what's around the arrow.

---

## Part 6 — Logic and set theory (quick reference)

| Symbol | Reading |
|---|---|
| ∀ | "for all" |
| ∃ | "there exists" |
| ∧ | "and" |
| ∨ | "or" |
| ¬ | "not" |
| ⇒ | "implies" |
| ⇔ | "iff" (if and only if) |
| ∈ / ∉ | "is / isn't a member of" |
| ⊆ | "is a subset of" |
| ∪ / ∩ | "union / intersection" |
| ∅ | "empty set" |
| ⊥ | "bottom" — absurdity, or the bottom type |
| ⊤ | "top" — trivially true, or the top type |
| ⊨ | "models" — semantic entailment (contrast with ⊢, proof-theoretic) |
| ≡ | "definitionally equal" (stronger than `=`) |

---

## Part 7 — Rows: the thing you'll actually need

Rows are how effect systems (and row-polymorphic records) express "a set of things with an optional extension variable." This is the notation you'll see everywhere in Koka / Leijen / Rémy.

### Row syntax

- `⟨⟩` — empty row
- `⟨ℓ : τ⟩` — row with one label `ℓ` of associated type τ
- `⟨ℓ₁ : τ₁, ℓ₂ : τ₂⟩` — row with two labels
- `⟨ℓ : τ | ρ⟩` — row with label ℓ **and** whatever row ρ contains (the "row extension" form)

The `|` separator reads as "and then whatever." The part after `|` is the **tail variable** — a row variable that can be instantiated to any further set of labels.

For effect rows specifically, papers often drop the `:τ` since the operation's type is fixed by its declaration:

- `⟨⟩` — pure (no effects)
- `⟨io⟩` — does io
- `⟨io, throws⟩` — does io and can throw
- `⟨io | ε⟩` — does io and whatever else ε represents (polymorphic in the rest)

### Row operations

- `ρ ⊕ ρ'` — row concatenation (sometimes written `ρ, ρ'`)
- `ℓ ∈ ρ` — label ℓ is in row ρ
- `ρ \ ℓ` — row ρ with label ℓ removed (what a handler does to the effect row of its body)

### The Rémy unification move

When unifying `⟨io | ρ₁⟩` with `⟨throws | ρ₂⟩`:

1. They share no labels.
2. Introduce a fresh row variable ρ' and bind:
   - ρ₁ ↦ `⟨throws | ρ'⟩`
   - ρ₂ ↦ `⟨io | ρ'⟩`
3. Now both rows equal `⟨io, throws | ρ'⟩`.

When you see unification rules in a paper, this is what they're doing. The notation looks dense; the idea is "make the rows match by pushing missing labels into the tail variables."

---

## Part 8 — Reading a real rule, out loud

Here's a rule from the Koka-lineage, for calling an effect operation. Some papers use `!` to separate a type from its effect row; others subscript the arrow. I'll use `!` here.

```
  op : ∀α. τ₁ → τ₂ ! ⟨ℓ⟩
  Γ ⊢ e : τ₁ ! ε
  ──────────────────────────────── (T-Op)
  Γ ⊢ op e : τ₂ ! ⟨ℓ | ε⟩
```

Reading piece by piece:

**Premise 1** — `op : ∀α. τ₁ → τ₂ ! ⟨ℓ⟩`
- `op` is an effect operation.
- Its declared type is: for all α, a function from τ₁ to τ₂ with effect row `⟨ℓ⟩`.
- So `op` has exactly one effect: the label ℓ.

**Premise 2** — `Γ ⊢ e : τ₁ ! ε`
- In context Γ, the argument `e` has type τ₁ and produces effect row ε.
- ε is a row variable — whatever effects evaluating `e` happens to have.

**Conclusion** — `Γ ⊢ op e : τ₂ ! ⟨ℓ | ε⟩`
- In context Γ, the call `op e` has type τ₂ and effect row `⟨ℓ | ε⟩`.
- The row is: ℓ (from the operation itself), plus whatever ε contained (from evaluating the argument).

**In plain English**: "Calling an effect operation adds the operation's effect label to the effect row of the call expression, along with any effects produced by evaluating the argument."

That's a formal rule from a real paper, read out loud in ordinary English. When you can do this for every rule in a paper, you've read the paper.

---

## Part 9 — BNF: how papers define languages

You'll hit this in nearly every paper:

```
e ::= x           -- variable
    | λx. e       -- lambda
    | e₁ e₂       -- application
    | n           -- integer literal
    | e₁ + e₂     -- addition
```

Read: "An expression `e` is one of: a variable `x`, or a lambda `λx. e`, or an application `e₁ e₂`, or an integer literal `n`, or a sum `e₁ + e₂`."

`::=` is "is defined as." `|` means "or." The identifiers on the left (e, v, τ, etc.) are **metavariables** — placeholders ranging over the syntactic category defined on the right.

Metavariable conventions (so common they barely get introduced in papers):

| Metavariable | Ranges over |
|---|---|
| `e` | expressions |
| `v` | values (expressions that are done reducing) |
| `τ`, `σ` | types / type schemes |
| `x, y, z` | variable names |
| `n, m` | integer constants |
| `ℓ` | labels (for records or effects) |
| `h` | handlers |
| `κ` | continuations |

When you see `e` unqualified in a formal rule, it means "any expression." When you see `v`, it specifically means a value — the distinction matters for reduction rules.

---

## Part 10 — What to do when you're lost in a paper

1. **Find the grammar.** Most papers define their language in BNF near the start. That section names every symbol used and its role. When you're lost, go back to the grammar.
2. **Find a worked derivation.** Most papers show the rules applied to a concrete program. If you can follow one derivation step-by-step, the rest are the same shape.
3. **Translate symbols to English, out loud, the first time.** "Gamma turnstile e colon tau" → "in context Γ, e has type τ." After a few pages you stop needing to.
4. **Accept overloaded notation.** `→` is function type *and* reduction. `ε` might be effect *or* evaluation. Context tells you which. When it doesn't, the paper probably tells you explicitly.
5. **Skip lemmas on your first pass.** The main theorems and the key rules carry most of the content. Come back for proofs after you have the shape.
6. **Note unknown notation as you hit it.** If a paper introduces something this primer doesn't cover, add it here. The primer grows with you.

---

## Part 11 — Deeper dives

Symbols that deserve more than a line in the conventions table.

### 11.1 — μ: the recursive binder

`μα. τ` means: "α is the type such that α = τ, where τ may mention α."

It's how we give a *finite* type expression to an *infinitely self-referential* structure.

#### The paradox it solves

Suppose you want a type for binary trees. Informally:

```
Tree = Leaf | Node(Int, Tree, Tree)
```

What *is* Tree? It mentions itself. If you try to expand "Tree" everywhere it appears:

```
Leaf | Node(Int, Leaf | Node(Int, ..., ...), Leaf | Node(Int, ..., ...))
```

That's infinite. Finite type expressions can't describe infinite structures directly. **μ is the patch**: it gives you a finite syntactic handle on "the thing that satisfies this self-referential definition."

#### Reading a concrete μ type

Binary trees:

```
μα. Unit + (Int × α × α)
```

Piece by piece:
- `μα. ...` — "α is defined as the following expression, which may mention α."
- `Unit + (Int × α × α)` — "either Unit (empty tree), or a triple of an Int and two α's (a node with a value and two subtrees)."
- Each `α` is "another tree of the same shape."

Read out loud: "Define α to be: a leaf, or an Int paired with two α's."

#### More examples

**Lists of Int:**
```
μα. Unit + (Int × α)
```
"α is: empty, or an Int paired with another α." A list is either nil or a (head, tail-list) pair.

**Infinite streams:**
```
μα. Int × α
```
"α is: always an Int paired with another α." No base case, so the type describes infinite structures.

**Lambda calculus terms:**
```
μα. Var(String) + Abs(String × α) + App(α × α)
```
"α is: a variable, or an abstraction (name + body), or an application (function + argument)." The recursive α's are "more terms of the same kind."

#### Why "binder"

`λ` binds a term variable in a function body. `λx. x + 1` means "x refers to the parameter of this function, throughout the body `x + 1`."

`μ` binds a type variable in a recursive type definition. `μα. Unit + (Int × α × α)` means "α refers to the whole type being defined, throughout the body `Unit + (Int × α × α)`."

Same word — "binder" — because both introduce a name with a specific scope. λ binds at the term level; μ binds at the type level.

#### What it really is: a fixpoint

μ is the type-level sibling of the fixpoint combinator. In the term world, `fix f = f (fix f)` lets a function refer to itself. In the type world, `μα. τ = τ[α ↦ μα. τ]` lets a type refer to itself.

A μ type is a **fixpoint of the type equation α = τ**. The solution *is* the type that equals its own unfolding.

This is why the "recursive type α such that..." phrasing sounds weird at first. α is not a free variable that you substitute in from outside — α *is* the whole self-referential type. μ introduces it and binds it to itself.

#### Two flavors (matters when reading papers)

- **Iso-recursive**: `μα. τ` is a *distinct* type from `τ[α ↦ μα. τ]`. Explicit `fold` / `unfold` operations convert between them. System F uses this. Cleaner theory, slightly more ceremony.
- **Equi-recursive**: `μα. τ` *is* `τ[α ↦ μα. τ]` — the type system treats them as equal automatically. More convenient for programmers. Harder to typecheck (requires strong type-equivalence algorithms).

Most papers are explicit about which they use. Quartz user-level syntax is equi-recursive (you never fold/unfold), though the internal representation might be iso-recursive.

#### How often you'll hit it

Not constantly in effect-system papers. Effect rows are about *sets of labels*, not self-referential data. You'll see μ most in:

- Papers on recursive types as first-class objects (Amadio & Cardelli)
- System F and F-omega foundational type theory
- Occasionally in effect handler semantics when the handler is recursive (but papers usually avoid the notation in favor of explicit definitions)

Worth knowing. Rarely central to what we'll read.

---

## Part 11.2 — Koka-specific conventions

Leijen's papers use a specific convention worth pinning down, since it differs from the generic notation in earlier sections.

### Function type with effect

Koka writes function types as:

```
(τ₁, ..., τₙ) → ε τ
```

The effect row `ε` sits **between the arrow and the return type**. This is different from `τ ! ε` (which we used in §8 for clarity) and different from `τ →ε τ` with a subscripted arrow (seen in some papers).

Parse `int → total int` as: "function from int, with effect `total`, returning int." Three tokens after the arrow, but they're two things: the effect label (`total`) and the return type (`int`).

### Koka's shipped effect labels

These appear throughout Leijen's papers and examples:

| Label | Meaning |
|---|---|
| `total` | No effects — pure function. Equivalent to the empty row `⟨⟩` |
| `exn` | Can throw an exception |
| `div` | Can diverge / non-terminate |
| `ndet` | Non-deterministic |
| `alloc⟨h⟩` | Allocates on heap `h` |
| `read⟨h⟩` | Reads from heap `h` |
| `write⟨h⟩` | Writes to heap `h` |
| `io` | Input/output (often a shorthand for the combined I/O set) |

Angle brackets `⟨h⟩` on `alloc`/`read`/`write` are **type application**, not row delimiters. `alloc⟨h⟩` reads "alloc applied to type argument h" — parameterizes the heap effect by a specific heap tag.

### Row delimiters vs type application

Koka overloads angle brackets `⟨⟩`:
- `⟨exn, div⟩` — a row of effects (row delimiter)
- `alloc⟨h⟩` — type application on a single effect label (generic argument)

Context disambiguates. In a row position, `⟨⟩` means "row." Next to an identifier with no preceding arrow, `⟨⟩` means "type application."

### μ in Koka papers

**Heads up — notation overload.** In general type theory, `μ` is the recursive binder (primer §11.1). In **Koka papers, `μ` is often used as a metavariable for effect row variables** (the thing we called `ρ` or `ε` in §7). Same symbol, different meaning.

When you see `∀μ. τ` in Leijen 2014, read μ as "some effect row." When you see `μα. τ` in a type-theory paper, read μ as the recursive binder. The paper's grammar section will usually make clear which one is meant.

## Part 12 — Living glossary

Add rows as we encounter new notation.

| Symbol | Section | Meaning |
|---|---|---|
| Γ ⊢ e : τ | §2 | Typing judgment |
| λx. e | §2 | Lambda |
| α β γ | §3 | Type variables |
| τ σ | §3 | Types |
| ρ | §3, §7 | Row |
| ε | §3, §7 | Effect (or effect row) |
| μ | §3, §11.1, §11.2 | Recursive binder (classic) OR effect row variable (Koka) |
| ∀α. τ | §3 | Type scheme |
| e[x ↦ v] | §4 | Substitution |
| → | §5 | Function type / reduction |
| →β | §5 | Beta reduction |
| ⟨ℓ : τ \| ρ⟩ | §7 | Row extension |
| ρ ⊕ ρ' | §7 | Row concatenation |
| ρ \ ℓ | §7 | Row with label removed |
| τ ! ε | §8 | Type with effect row (generic convention) |
| (τ₁,...,τₙ) → ε τ | §11.2 | Koka function type: effect between arrow and return |
| `total` | §11.2 | Koka: no-effects label (= empty row `⟨⟩`) |
| `exn` | §11.2 | Koka: exception effect |
| `div` | §11.2 | Koka: divergence effect |
| `ndet` | §11.2 | Koka: non-determinism effect |
| `alloc⟨h⟩` | §11.2 | Koka: allocation on heap `h` |
| `read⟨h⟩` | §11.2 | Koka: read from heap `h` |
| `write⟨h⟩` | §11.2 | Koka: write to heap `h` |
| `io` | §11.2 | Koka: combined I/O effect |
| e ::= ... | §9 | BNF production |
