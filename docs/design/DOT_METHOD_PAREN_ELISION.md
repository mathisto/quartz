# Dot-Method Paren Elision (B.6)

**Status**: Shipped 2026-05-02.
**Stance**: Stance 4 in `docs/ROADMAP.md` — paren-optional only at dot-access position, never at bareword position.

## What changed

`obj.method` (no parens) now calls `method(obj)` when `method` is a zero-arg
method on `obj`'s type or a free function whose first parameter matches.
Before B.6, the same expression either errored ("Struct 'X' has no field
'method'") or produced silent garbage (TYPE_INT receiver fell through with a
QZ0603 "cannot resolve struct" warning).

Examples that work after B.6:

```be
struct Point
  x: Int
  y: Int
end

extend Point
  def magnitude(self): Int = @x + @y
end

p = Point { x: 3, y: 4 }
p.magnitude        # 7 — was an error
p.magnitude.to_s   # "7" — chains transparently

def triple(n: Int): Int = n * 3
5.triple           # 15 — open UFCS, was QZ0603 + garbage
5.triple.triple    # 45 — chained
```

Examples that **still** work the same way (refactoring safety):

```be
p.magnitude()      # 7 — explicit-paren form unchanged
5.triple()         # 15 — explicit-paren form unchanged
```

Examples that work **as before** (bareword bindings unaffected):

```be
def apply(f: Fn(Int): Int, n: Int): Int = f(n)
apply(triple, 4)   # 12 — bareword `triple` is still the function value
```

## Field-vs-method precedence

When a struct has both a field and a method with the same name, **the field
wins**:

```be
struct R
  tag: Int
end

extend R
  def tag(self): Int = 999
end

r = R { tag: 7 }
r.tag      # 7 (field), not 999 (method)
r.tag()    # 999 — explicit method call
```

Rationale: existing code that reads `r.tag` as a field cannot silently flip
meaning when an `extend` block adds a same-named method later. The user keeps
unambiguous access to the method via `r.tag()`.

## Why this and not more

Quartz already had:

- **Endless def for zero-arg functions**: `def pi = 3.14` (definition), `pi()`
  (call). Bareword `pi` is the function value, not the call.
- **Open UFCS with parens**: `5.triple()` calls `triple(5)`.
- **Builtin paren elision via predicate forms**: `vec.size`, `s.empty?`,
  `opt.some?` — all work without parens.

B.6 generalizes the third: any zero-arg method, on any type, works without
parens at the dot-access position. The change is **one direction only**:
where parens were required, they're now optional. No new ambiguity was
introduced.

What B.6 **explicitly does not** add:

- **Bareword paren elision**: `puts hello` (Yuescript-style) is still a syntax
  error. Bare `foo` always means "the function value `foo`."
- **Curried definition syntax**: no `def add x y = x + y`. Quartz uses
  `def add(x, y) = x + y` and `def adder(x) = (y -> x + y)`.
- **Type-directed parsing disambiguation**: the parser still treats
  `obj.method` and `obj.method()` as syntactically distinct shapes. The
  typechecker resolves each based on what's in scope; nothing in the parser
  needs to know whether `method` is a zero-arg method or a field.

## Prior-art survey

This was the deciding factor for the conservative scope. The design discussion
on May 1, 2026 surveyed:

| Language | Paren elision | Outcome |
|---|---|---|
| **Eiffel** | Universal Access Principle: `obj.foo` calls or reads, indistinguishable | Painful — function references require explicit `agent` syntax. Cited as an antipattern in modern language design. |
| **Scala 2** | Auto-apply for zero-arg methods (`obj.foo` calls if def, reads if val) | Walked back in Scala 3: empty-parens methods now require `()` on call to disambiguate from eta-expansion. Scala 3 cites the same lesson. |
| **Yuescript** | Paren-free calls everywhere: `puts hello` valid | Relies on Lua's runtime model and lack of first-class function shadowing. Doesn't transfer to Quartz. |
| **Kotlin** | Properties (`val`) read paren-free; functions need `()` on call | Distinction is at the declaration site, not the call site — different design point. |
| **Swift** | Computed properties paren-free; methods need `()` on call | Same design point as Kotlin. |
| **Ruby** | All method calls paren-free; bareword cannot reference a method | The "no first-class functions" route. Quartz rejected this with first-class functions early. |

**Quartz's design point**: closer to Scala 3's discipline (paren elision is
restricted to a syntactically unambiguous position) than Eiffel/Ruby (paren
elision everywhere, function references require new sugar). The dot-access
position is exactly where Scala 3 still allows elision today, because the
preceding receiver disambiguates.

## What this enables

- Cleaner chains: `users.filter() { it.active }.map() { it.name }.sort` reads
  as data-flow rather than method-call ceremony.
- Property-style access for computed values: `vec.size`, `point.magnitude`,
  `result.is_ok` all read like field access.
- Symmetric treatment of impl methods and free functions: `5.triple` and
  `5.double` work the same way, regardless of whether `triple` is a free
  function or `double` is a method on `Int`.

## Implementation

Single edit in `self-hosted/middle/typecheck_expr_handlers.qz`,
`tc_expr_field_access`. After the existing builtin rewrites (`.size`,
`.empty?`, etc.) but before the catch-all field-access path, attempt to
resolve `field_name` as a callable target:

1. **Struct receiver, missing field**: Try `Type$method` mangle (impl
   methods), then bare function name (open UFCS). If either resolves, rewrite
   `NODE_FIELD_ACCESS` → `NODE_CALL([receiver])` with `is_ufcs=1` and
   re-typecheck. The downstream `tc_expr_call` dispatches via existing
   trait-method-resolution and direct-call paths.
2. **Non-struct receiver (TYPE_INT, etc.)**: Try open UFCS lookup. Same
   rewrite-and-retypecheck on success.
3. **Otherwise**: Fall through to the existing field-access error path
   (`tc_check_field_access` reports the helpful "Struct 'X' has no field 'Y'"
   diagnostic).

Field-vs-method precedence is preserved by checking field existence first
(`tc_struct_field_type` returns `TYPE_ERROR` for missing fields without
emitting a diagnostic — clean peek). Only if the field is missing does the
method-resolution path fire.

The rewrite reuses the same in-place AST transform pattern that the existing
`.size` / predicate rewrites already use (line 1188-1198 of the same file),
ensuring uniform downstream lowering.

**No parser change**, no MIR/codegen change, no new opcodes. The whole
feature is type-checker-localized.

## Method references as values

B.6 does **not** introduce `obj::foo` method-reference syntax. The roadmap
row's original sketch included it, but the strict-relaxation rule is fully
satisfied without:

- Bareword `foo` is still the function value reference (unchanged behavior).
- A bound-to-receiver function value is `() -> obj.foo()` or
  `() -> foo(obj)` — explicit closure syntax.
- The `Mod::fn` syntax for module-qualified function references is unaffected
  (LHS is a module path, not a value).

If a concrete user need for `obj::foo` sugar surfaces, it can be added as a
parser-only follow-up: when the LHS of `::` is an expression (not a module
path), produce a NODE_LAMBDA wrapping `obj.foo()`. No typechecker or codegen
change required. Filed as a B.6 follow-up; no scheduling commitment until
demand surfaces.

## What B.6 does not change

- Parser: `obj.method` still parses as `NODE_FIELD_ACCESS`. The typechecker
  rewrites it to a call when appropriate.
- Bareword expression form: `foo` is the function value, not a call.
- Existing builtin shortcuts: `.size`, `.empty?`, `.some?`, etc. continue to
  fire on the same path they always did. B.6 just generalizes the same
  in-place rewrite to cover any zero-arg method.
- Open UFCS with parens: `5.triple()` works exactly as before.

## Test coverage

`spec/qspec/method_call_no_parens_spec.qz` (8/8 green) covers:

- Impl method paren-less call (terminal position)
- Open UFCS paren-less on Int receiver
- Open UFCS chain (`5.triple.b6_negate`)
- Open UFCS on struct receiver
- Impl method chain (terminal paren-less)
- Refactoring safety: explicit-parens form still works
- Field-vs-method precedence: field wins
- Bareword still resolves to function value (passable to Fn-typed parameters)

Existing UFCS specs (`open_ufcs`, `method_syntax`, `method_arity_collision`,
`generic_ufcs_dispatch`, `hybrid_ufcs_traits`, `binary_methods`,
`option_ufcs`, `map_ufcs`, `json_ufcs`, `range_ufcs`) all green post-fix.

## Fixpoint

Compiler self-build clean at 2459 functions (function-count-neutral; no new
helpers), gen1 == gen2 byte-identical. Smoke tests on `style_demo`,
`brainfuck`, and the new spec all pass against the rebuilt binary.
