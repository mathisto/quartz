# T3c.1: True Hindley-Milner Type Inference — Implementation Plan

> **Status**: Phase 1 DONE, Phase 2 DONE, Phase 3 BLOCKED, Phase 4 DONE (pre-existing)
> **Effort**: 1-2 weeks (4 phases)
> **Risk**: Medium — touches the core type checker, but evolutionary approach preserves existing logic
> **Prerequisite**: None (self-contained)
> **Enables**: Row Polymorphism (ROW), Interprocedural Inference (INTERPROC investigation)
>
> **Phase 3 BLOCKED**: Let-polymorphism requires structured function types in the TC type
> system (param types + return types as parallel arrays). Currently `TYPE_FUNCTION = 6`
> is a flat integer with no type structure. Cannot represent `forall a. Fn(a): a` without
> this. See "Phase 3 Dependency" section below.
>
> **Phase 4 ALREADY DONE**: Bidirectional lambda parameter inference was already
> implemented (FIX.6 Phase 2, `typecheck_walk.qz:4411-4445`). It injects expected
> param types from `Fn(...)` annotations into lambda AST nodes before type-checking.
> Verified working: `apply(x -> x * 2, 21)`, multi-param lambdas, standalone lambdas.

---

## Problem Statement

The current type checker has two separate systems:

**System A** (`tc_expr`, `typecheck_walk.qz:4796`, 61 branches, ~2,500 lines):
- Annotation-driven. Returns concrete types directly.
- Handles ~95% of expressions via function signature lookup, UFCS dispatch, struct field resolution.
- Returns `TYPE_UNKNOWN` when it can't determine a type.

**System B** (`infer_expr`, `infer.qz:871`, 1,242 lines):
- Real unification engine: type variables, occurs-check, binding, structural comparison.
- Has its own AST walker, own environment, own type representation (different numbering from System A).
- Called from exactly 3 sites as a fallback when System A returns `TYPE_UNKNOWN`.

### What's wrong

1. **Two incompatible type representations.** System A uses `TYPE_INT=1, TYPE_BOOL=2, TYPE_STRING=3`. System B uses `TYPE_INT=2, TYPE_BOOL=3, TYPE_STRING=4`. A lossy bridge function (`tc_infer_type_to_type`) converts between them. Type variables (negative IDs in System B) become `TYPE_UNKNOWN` in System A, losing all constraint information.

2. **No let-polymorphism.** `id = x -> x` gets a single concrete type from first use. `id(5)` works, then `id("hello")` fails. True H-M generalizes: `id : forall a. a -> a`.

3. **No constraint propagation.** In `f(x)` where `f: Fn(Int): String`, the type of `x` must already be known. True H-M infers `x: Int` from the call context.

4. **Inference doesn't feed back.** Even when System B resolves a type, that information only affects the immediate let-binding. Downstream uses within the same function don't benefit.

5. **Duplicate AST constants.** `infer.qz` lines 20-147 duplicate `node_constants.qz`. Lines 152-195 duplicate `type_constants.qz`. Maintenance hazard.

### What "true H-M" means for Quartz

```
# Today: requires annotation
var adder: Fn(Int): Fn(Int): Int = n -> x -> x + n

# After Phase 2: inferred from usage
adder = n -> x -> x + n
add5 = adder(5)    # compiler infers n: Int from 5
result = add5(10)  # compiler infers x: Int from 10, result: Int from x + n

# After Phase 3: let-polymorphism
id = x -> x
a = id(42)         # id instantiated as Int -> Int
b = id("hello")    # id instantiated as String -> String (both work)
```

---

## Architecture Decision: Evolutionary (Approach A)

Integrate type variables into the existing `tc_expr` system rather than replacing it.

**Why not revolutionary (promoting `infer_expr` to primary)?**
- `tc_expr` is 2,500 lines with 61 branches that handle UFCS dispatch, trait resolution, builtin awareness, borrow checking, arena safety, operator overloading, etc.
- Replicating all of that in `infer_expr` would be a ~18K line rewrite with high regression risk.
- The evolutionary approach adds ~500-800 lines to the existing system while preserving all existing behavior.

**Key principle**: Annotations constrain inference, not replace it. Every annotation becomes a unification constraint (`unify(inferred_type, annotated_type)`). Code that works today continues to work. Code that required annotations can gradually drop them.

---

## Phase 1: Unified Type Representation (~2-3 days)

### Goal
Eliminate the dual type system. Type variables become first-class citizens in the primary type checker.

### Changes

#### 1.1: Add `TYPE_VAR` to `type_constants.qz`

```
# After TYPE_FUTURE = 54:
const TYPE_VAR = 55       # Unification type variable (negative IDs in binding table)
const TYPE_VAR_BASE = 55  # Alias for clarity
```

Type variables are represented as `TYPE_VAR_BASE - var_id` where `var_id` starts at 1. So the first type variable is `TYPE_VAR_BASE - 1 = 54`, second is `53`, etc. This avoids collision with existing types (all positive, max 54) and with the ptype system (`PTYPE_BASE = 100000`).

**Wait — this collides with TYPE_FUTURE.** Better approach: use negative numbers directly in the TC type space, just like `infer.qz` already does. The TC type system already handles negative IDs as error sentinels in some paths. We need to carve out a clean range.

**Revised approach**: Type variables are negative integers in the TC type space. `tc_is_type_var(t) = t < -100` (leaves room for error sentinels which use -1 through ~-10). First var is -101, second is -102, etc. The binding table maps `abs(var_id) - 101` to the bound type (0 = unbound).

#### 1.2: Add type variable state to `TypecheckState`

Add to `TypecheckState` struct in `typecheck_util.qz`:

```
# Type inference state (unified with TC types)
tv_next: Int              # Next type variable ID (starts at 101)
tv_bindings: Vec<Int>     # Binding table: index = var_id - 101, value = bound type (0 = unbound)
tv_origin_lines: Vec<Int> # Where each type var was created (for error messages)
tv_origin_cols: Vec<Int>
tv_origin_descs: Vec<String>
```

#### 1.3: Core type variable operations in `typecheck_util.qz`

```
def tc_fresh_type_var(tc: TypecheckState): Int
  # Returns a new type variable as a negative integer
  var id = tc.tv_next
  tc.tv_next = id + 1
  tc.tv_bindings.push(0)  # unbound
  tc.tv_origin_lines.push(0)
  tc.tv_origin_cols.push(0)
  tc.tv_origin_descs.push("")
  return 0 - id  # -101, -102, ...
end

def tc_fresh_type_var_with_origin(tc: TypecheckState, line: Int, col: Int, desc: String): Int
  var id = tc.tv_next
  tc.tv_next = id + 1
  tc.tv_bindings.push(0)
  tc.tv_origin_lines.push(line)
  tc.tv_origin_cols.push(col)
  tc.tv_origin_descs.push(desc)
  return 0 - id
end

def tc_is_type_var(t: Int): Bool = t < -100

def tc_resolve_type(tc: TypecheckState, t: Int): Int
  # Follow binding chain to concrete type
  if tc_is_type_var(t) == false
    return t
  end
  var idx = (0 - t) - 101
  if idx < 0 or idx >= tc.tv_bindings.size
    return t  # Out of range — return as-is
  end
  var bound = tc.tv_bindings[idx]
  if bound == 0
    return t  # Unbound — return the variable itself
  end
  return tc_resolve_type(tc, bound)  # Chase chain
end

def tc_bind_type_var(tc: TypecheckState, var_id: Int, bound_type: Int): Void
  var idx = (0 - var_id) - 101
  tc.tv_bindings[idx] = bound_type
end

def tc_occurs_in(tc: TypecheckState, var_id: Int, t: Int): Bool
  var resolved = tc_resolve_type(tc, t)
  if resolved == var_id
    return true
  end
  # For compound types (function, array), recurse into components
  # This requires looking up the type's structure — Phase 2 concern
  return false
end

def tc_unify(tc: TypecheckState, t1: Int, t2: Int): Bool
  var r1 = tc_resolve_type(tc, t1)
  var r2 = tc_resolve_type(tc, t2)

  # Same type — trivially unified
  return true if r1 == r2

  # If r1 is a type variable, bind it to r2
  if tc_is_type_var(r1)
    return false if tc_occurs_in(tc, r1, r2)  # Infinite type
    tc_bind_type_var(tc, r1, r2)
    return true
  end

  # If r2 is a type variable, bind it to r1
  if tc_is_type_var(r2)
    return false if tc_occurs_in(tc, r2, r1)
    tc_bind_type_var(tc, r2, r1)
    return true
  end

  # Both concrete — check compatibility
  # TYPE_UNKNOWN matches anything (legacy behavior, preserves existing semantics)
  return true if r1 == TYPE_UNKNOWN
  return true if r2 == TYPE_UNKNOWN

  # Same concrete type — match
  return r1 == r2
end

def tc_reset_type_vars(tc: TypecheckState): Void
  # Called at function scope boundaries
  tc.tv_next = 101
  tc.tv_bindings = vec_new()
  tc.tv_origin_lines = vec_new()
  tc.tv_origin_cols = vec_new()
  tc.tv_origin_descs = vec_new()
end
```

#### 1.4: Remove duplicate constants from `infer.qz`

Delete lines 20-195 (duplicate AST and type constants). Import from `node_constants` and `type_constants` instead. Update `infer_expr` to use the canonical constants.

#### 1.5: Bridge the old inference API

The existing 3 call sites and `tc_infer_*` wrappers in `typecheck_util.qz` continue to work via the old `InferGlobals`. No call site changes in Phase 1. The new `tc_unify`/`tc_fresh_type_var` functions are available but not yet called from `tc_expr`.

### Tests

- Existing QSpec suite passes (no regressions).
- New tests: `tc_unify(tc, TYPE_INT, TYPE_INT) == true`, `tc_unify(tc, TYPE_INT, TYPE_STRING) == false`, `tc_unify(tc, fresh_var, TYPE_INT) == true` then `resolve(fresh_var) == TYPE_INT`.
- Fixpoint verified.

### Files Modified
- `self-hosted/shared/type_constants.qz` — no new constant needed (vars are negative)
- `self-hosted/middle/typecheck_util.qz` — add 5 fields to TypecheckState, add ~80 lines of type variable operations, add `tc_reset_type_vars` call in `tc_new`
- `self-hosted/middle/infer.qz` — delete duplicate constants, import canonical ones
- `spec/qspec/type_inference_spec.qz` — new test file for unification primitives

---

## Phase 2: Constraint-Based tc_expr (~1 week)

### Goal
Make `tc_expr` generate and solve constraints via unification instead of returning `TYPE_UNKNOWN` when types are ambiguous.

### Changes

#### 2.1: Let-bindings use type variables

In `tc_stmt` NODE_LET handler (`typecheck_walk.qz:5521`), **replace the inference fallback pattern**:

```
# BEFORE (3 copies of this pattern):
var init_type = tc_expr(tc, ast_storage, init_node)
if init_type == TYPE_UNKNOWN
  var globals = tc_get_infer_globals(tc)
  var inferred = infer_expression_type(globals, ast_storage, init_node)
  tc_surface_infer_errors(tc, globals)
  if inferred > 0
    init_type = tc_infer_type_to_type(inferred)
  end
end

# AFTER:
var init_type = tc_expr(tc, ast_storage, init_node)
if init_type == TYPE_UNKNOWN
  init_type = tc_fresh_type_var_with_origin(tc, line, col, "let #{var_name}")
end
```

The type variable will be resolved later when the binding is used in a context that constrains it.

#### 2.2: Annotations constrain via unification

When a type annotation is present on a let-binding, **unify instead of override**:

```
# BEFORE:
if str_byte_len(let_type_ann) > 0
  var ann_type = tc_parse_type(tc, let_type_ann)
  init_type = ann_type  # Annotation overrides inferred type

# AFTER:
if str_byte_len(let_type_ann) > 0
  var ann_type = tc_parse_type(tc, let_type_ann)
  if tc_unify(tc, init_type, ann_type) == false
    tc_error(tc, "Type annotation '#{let_type_ann}' conflicts with inferred type", line, col)
  end
  init_type = tc_resolve_type(tc, init_type)
```

**This is also T3c.4 (annotation cross-checking)** — `var y: String = 42` will now produce an error because `unify(TYPE_INT, TYPE_STRING)` fails. Two birds, one stone.

#### 2.3: Function call argument inference

In `tc_expr_call` (`typecheck_walk.qz:4422`), after type-checking each argument, **unify with the parameter type**:

```
# BEFORE (line 4422-4428):
for tc_ai in 0..arg_count
  tc_expr(tc, ast_storage, args[tc_ai])
end

# AFTER:
var param_anns = tc_function_param_annotations(tc, func_idx)
for tc_ai in 0..arg_count
  var arg_type = tc_expr(tc, ast_storage, args[tc_ai])
  var param_type = tc_get_param_type_at(tc, func_idx, tc_ai, param_anns)
  if param_type > 0 and param_type != TYPE_UNKNOWN
    if tc_is_type_var(arg_type)
      tc_unify(tc, arg_type, param_type)
    end
  end
end
```

This means: if the argument's type is a type variable (from an un-annotated let-binding), and the function parameter has a known type, the variable gets constrained. `x = some_expr(); f(x)` where `f(n: Int)` now infers `x: Int`.

#### 2.4: Binary/unary operator inference

In `tc_expr` NODE_BINARY handler, when operands are type variables, unify with the expected operand type:

```
# For arithmetic operators (+, -, *, /):
if tc_is_type_var(left_type)
  tc_unify(tc, left_type, TYPE_INT)
end
if tc_is_type_var(right_type)
  tc_unify(tc, right_type, TYPE_INT)
end
```

#### 2.5: If/match branch unification

In `tc_expr` NODE_IF handler, unify the then-branch and else-branch types instead of checking equality:

```
# BEFORE:
if then_type != else_type
  tc_error(tc, "Branch type mismatch", ...)
end

# AFTER:
if tc_unify(tc, then_type, else_type) == false
  tc_error(tc, "Branch type mismatch: ...")
end
var result_type = tc_resolve_type(tc, then_type)
```

#### 2.6: Variable use resolves type variables

In `tc_expr` NODE_IDENT handler, after scope lookup, resolve:

```
var binding_type = tc_scope_lookup(tc, name)
return tc_resolve_type(tc, binding_type)
```

This ensures that a type variable bound in a let-statement, later constrained by usage, returns the resolved concrete type when the variable is referenced again.

### Interaction with existing systems

- **UFCS dispatch**: Unchanged. UFCS resolves method names to concrete functions with known signatures. Those signatures feed into the constraint system via 2.3.
- **Builtin types**: Unchanged. Builtins have known signatures that constrain type variables.
- **Borrow checker**: The borrow checker operates on binding indices, not types. Type variables don't affect it.
- **Trait resolution**: Trait method lookup uses concrete types. If a type variable hasn't been resolved when trait dispatch is needed, fall back to TYPE_UNKNOWN (preserving current behavior).

### Tests

- All existing QSpec tests pass.
- New tests:
  - `x = 5; y = x + 10` — y inferred as Int without annotation
  - `var x: String = 42` — compile error (annotation cross-check)
  - `x = some_val(); f(x)` where `f(n: Int)` — x inferred as Int
  - `x = if true then 5 else 10` — x inferred as Int
  - `x = if true then 5 else "hello"` — compile error (branch mismatch)
- Fixpoint verified.

### Files Modified
- `self-hosted/middle/typecheck_walk.qz` — modify NODE_LET handler (3 sites), NODE_BINARY, NODE_IF, NODE_MATCH, NODE_IDENT, tc_expr_call argument loop
- `self-hosted/middle/typecheck_util.qz` — add `tc_get_param_type_at` helper
- `spec/qspec/type_inference_spec.qz` — expand with constraint propagation tests

---

## Phase 3: Let-Polymorphism (~3-5 days)

### Goal
Generalize at let-bindings so `id = x -> x` can be used polymorphically.

### Design

#### Type Schemes

A **type scheme** wraps a type with universally quantified type variables:

```
ForAll([a, b, ...], body_type)
```

Representation in the TC type system: a new `TYPE_SCHEME` constant is NOT needed. Instead, we store generalized bindings in a parallel array on `TypecheckState`:

```
# Added to TypecheckState:
tv_schemes: Vec<String>          # Serialized schemes: "" = monomorphic, "a,b" = quantified vars
tv_scheme_bodies: Vec<Int>       # The body type of the scheme
```

When a binding has a non-empty scheme, its type is instantiated (fresh vars substituted for quantified vars) at each use site.

#### Generalization

After type-checking a let-binding's initializer, generalize:

1. Collect all free type variables in `init_type` that are NOT free in the enclosing scope's bindings.
2. If there are any, record them as the scheme's quantified variables.
3. Store the scheme alongside the binding.

```
def tc_generalize(tc: TypecheckState, init_type: Int): Pair<String, Int>
  # Find free type vars in init_type
  var free_vars = tc_collect_free_vars(tc, init_type)
  # Remove vars that appear free in the enclosing scope
  var env_vars = tc_collect_env_free_vars(tc)
  var quantified = filter(free_vars, not_in(env_vars))
  if quantified.is_empty()
    return ("", init_type)  # Monomorphic
  end
  return (serialize(quantified), init_type)
end
```

#### Instantiation

At variable use sites (NODE_IDENT), if the binding has a non-empty scheme:

1. Create fresh type variables for each quantified variable.
2. Substitute them throughout the body type.
3. Return the instantiated type.

```
def tc_instantiate(tc: TypecheckState, scheme_vars: String, body_type: Int): Int
  if str_byte_len(scheme_vars) == 0
    return body_type  # Monomorphic — no instantiation
  end
  # Parse quantified var IDs from scheme_vars
  var qvars = parse_var_ids(scheme_vars)
  # Create fresh vars for each
  var substitution = new_substitution()
  for qvar in qvars
    substitution.add(qvar, tc_fresh_type_var(tc))
  end
  # Apply substitution to body_type
  return tc_substitute(tc, body_type, substitution)
end
```

#### The value restriction

Without care, let-polymorphism + mutation = unsoundness. The classic example:

```
var r = ref(id)      # r: Ref<forall a. a -> a>
r := (x -> x + 1)   # r: Ref<Int -> Int>
r()(true)            # BOOM: applies Int -> Int to Bool
```

Quartz's const-by-default helps: only `var` bindings are mutable, and we can restrict generalization to immutable bindings (the **value restriction** from SML). Mutable bindings get monomorphic types.

```
# In tc_stmt NODE_LET:
if is_mutable == 0  # const binding
  var (scheme, body) = tc_generalize(tc, init_type)
  tc_scope_bind_with_scheme(tc, var_name, body, scheme)
else  # var binding
  tc_scope_bind(tc, var_name, init_type)  # monomorphic
end
```

### Interaction with existing systems

- **Bounded generics**: `def max<T: Ord>(a: T, b: T)` already has explicit type parameters. Let-polymorphism applies to local let-bindings, not top-level function definitions. No conflict.
- **Existential model**: Types still vanish at runtime. `id(5)` and `id("hello")` compile to the same i64 code. Generalization is purely compile-time.
- **Self-hosting**: The compiler source has full annotations. Let-polymorphism is opt-in (drop an annotation, get inference). No bootstrap risk.

### Tests

- `id = x -> x; a = id(5); b = id("hello")` — both work
- `pair = (a, b) -> (a, b); p1 = pair(1, "x"); p2 = pair(true, 42)` — polymorphic
- `var f = x -> x; f = x -> x + 1; f("hello")` — error (mutable binding, monomorphic)
- `double = x -> x + x; a = double(5)` — infers `x: Int` from `+`, `a: Int` from result
- Fixpoint verified.

### Files Modified
- `self-hosted/middle/typecheck_util.qz` — add scheme fields to TypecheckState, `tc_generalize`, `tc_instantiate`, `tc_substitute`, `tc_collect_free_vars`
- `self-hosted/middle/typecheck_walk.qz` — modify NODE_LET to generalize, modify NODE_IDENT to instantiate
- `spec/qspec/type_inference_spec.qz` — let-polymorphism tests

---

## Phase 4: Lambda Parameter Inference (~2-3 days)

### Goal
Infer lambda parameter types from call context: `apply((x) -> x + 1, 5)` works without `(x: Int)`.

### Design

This requires **bidirectional type checking**: propagating expected types *downward* into sub-expressions.

#### Expected-type propagation

When `tc_expr_call` type-checks a lambda argument, it already has access to the function's parameter annotations. If the parameter expects `Fn(Int): Int` and the argument is a lambda, inject the expected parameter types before type-checking the lambda body.

**This partially exists already** (`typecheck_walk.qz:4386-4420`, "Bidirectional lambda inference"). The current implementation injects expected types into the lambda's AST param annotations. We extend this to handle un-annotated lambdas more completely.

#### Changes

In `tc_expr_call`, before calling `tc_expr` on lambda arguments:

1. Look up the expected type of the parameter position.
2. If it's `Fn(A, B, ...): R` and the argument is `NODE_LAMBDA`:
   a. For each lambda param without an annotation, inject a fresh type variable.
   b. Unify that type variable with the corresponding expected param type.
   c. Type-check the lambda body with the constrained variables in scope.
   d. Unify the lambda body type with the expected return type.

```
# For each lambda argument at position i:
var expected_fn_type = tc_get_param_fn_type(tc, func_idx, i)
if expected_fn_type is Fn(param_types): ret_type
  for j in 0..lambda_param_count
    if lambda_param_annotation[j] is empty
      var tv = tc_fresh_type_var(tc)
      tc_unify(tc, tv, param_types[j])
      # Bind lambda param to the type variable (now constrained)
      tc_scope_bind(tc, lambda_param_name[j], tc_resolve_type(tc, tv))
    end
  end
  # Type-check lambda body
  var body_type = tc_expr(tc, ast_storage, lambda_body)
  tc_unify(tc, body_type, ret_type)
end
```

#### Standalone lambda inference

For lambdas not in a call context (`filter = x -> x > 0`), parameter types are initially type variables. They get constrained when the lambda is later called or passed to a function with known types:

```
filter = x -> x > 0         # x: ?a (type var), > constrains ?a = Int, body: Bool
                             # filter: Fn(Int): Bool (resolved)
result = apply(filter, 5)   # Works: Fn(Int): Bool matches expected Fn(Int): Bool
```

This falls out naturally from Phase 2's constraint propagation — the `> 0` constrains the type variable to Int, and the lambda's type resolves to `Fn(Int): Bool`.

### Tests

- `apply((x) -> x + 1, 5)` — x inferred as Int from param position
- `nums.filter(x -> x > 0)` — x inferred as Int from Vec<Int> element type
- `map(items, x -> x.name)` — x inferred from items element type
- `compose = (f, g) -> x -> f(g(x))` — all types inferred from usage
- Fixpoint verified.

### Files Modified
- `self-hosted/middle/typecheck_walk.qz` — extend bidirectional lambda inference block, modify NODE_LAMBDA handler to use type variables for un-annotated params
- `spec/qspec/type_inference_spec.qz` — lambda inference tests

---

## Migration & Bootstrap Strategy

### Zero bootstrap risk

The self-hosted compiler has full type annotations on every function, every let-binding, every lambda parameter. True H-M inference is purely additive — it enables *dropping* annotations, not *changing* behavior for annotated code.

**Phase 1** changes the internal representation but not the external behavior. Fixpoint should be trivially preserved.

**Phase 2** adds unification calls in `tc_expr`. With full annotations, every unification should succeed (annotations match inferred types). If a unification fails, it means the existing code has a type error that was previously silently accepted — which is a *feature*, not a regression (T3c.4 cross-checking).

**Phase 3** adds generalization, but only for bindings without annotations. The compiler source has annotations everywhere, so generalization produces empty schemes — no behavioral change.

**Phase 4** adds lambda param inference, but the compiler's lambdas have explicit param types.

### Incremental verification

After each phase:
1. `./self-hosted/bin/quake build` — compiler builds
2. `./self-hosted/bin/quake fixpoint` — byte-identical output
3. `./self-hosted/bin/quake qspec` — all tests pass

If fixpoint breaks after Phase 2 (annotation cross-checking catches a pre-existing type confusion in the compiler source), fix the compiler source rather than weakening the check.

---

## Deferred: What This Plan Does NOT Cover

| Feature | Why deferred | When |
|---------|-------------|------|
| **Row polymorphism** | Requires type variables that range over field sets, not just types. Needs Phase 1's unified representation as foundation. `InferStorage.row_constraints` placeholder exists. | After T3c.1, as ROW |
| **Interprocedural inference** | Most languages don't do this. Investigation needed to assess tradeoffs for Quartz. | INTERPROC discussion |
| **Parametric polymorphism for top-level functions** | `def id(x): ? = x` without `<T>`. Would require global constraint solving. | Post-T3c.1 evaluation |
| **GADTs / type-level computation** | Academic territory. No current use case. | Post-launch |
| **Compound type unification in occurs-check** | Phase 1's `tc_occurs_in` is conservative (doesn't recurse into function param/return types). Needs extension for Phase 3 correctness. | Phase 3 implementation |

---

## Success Criteria

After all 4 phases, this code compiles without annotations:

```
# Type inference from literals
x = 42
name = "hello"
flag = true

# Type inference from operators
sum = x + 10           # Int + Int = Int
greeting = name + "!"  # String + String = String

# Type inference from function calls
len = str_len(name)    # str_len(String): Int, so len: Int

# Type inference from control flow
result = if flag then x else 0   # both branches Int, so result: Int

# Let-polymorphism
id = x -> x
a = id(42)       # id instantiated as Int -> Int
b = id("hello")  # id instantiated as String -> String

# Lambda parameter inference
doubled = map(items, x -> x * 2)  # x inferred from items element type

# Annotations as optional constraints
var counter: Int = 0  # annotation verified against inferred type
```

And this code produces a compile error:

```
var x: String = 42            # T3c.4: annotation conflicts with inferred Int
var y = if true then 5 else "no"  # branch type mismatch
```
