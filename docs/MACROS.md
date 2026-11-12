# Macros

Quartz has a hygienic, compile-time macro system. Macros take AST as
input and produce AST as output, expanded between parsing and name
resolution. This document is the complete reference.

## Contents

1. [Invocation syntax](#invocation-syntax)
2. [Defining a macro](#defining-a-macro)
3. [Quote / unquote](#quote--unquote)
4. [String templates](#string-templates)
5. [Fragment specifiers](#fragment-specifiers)
6. [Variadic parameters](#variadic-parameters)
7. [Hygiene](#hygiene)
8. [The `$caller` escape hatch](#the-caller-escape-hatch)
9. [Built-in macros](#built-in-macros)
10. [`@derive` annotations](#derive-annotations)
11. [Expansion diagnostics](#expansion-diagnostics)
12. [Limits and gaps](#limits-and-gaps)
13. [Error codes](#error-codes)

---

## Invocation syntax

Every macro call is prefixed with `$`. The prefix distinguishes macro
expansion from a regular function call at parse time.

```be
$max(a, b)          # call the `max` macro with two args
$unwrap(optional)   # built-in macro
```

Macros are expanded AST-to-AST at compile time. The resulting code is
what the rest of the pipeline (resolver, typecheck, MIR, codegen) sees.

---

## Defining a macro

```be
macro NAME(PARAMS) do
  BODY
end
```

Two body shapes are supported:

- **Quote / unquote** (AST form) — the body is a `quote do … end` block.
  Recommended for any macro that composes with other code.
- **String template** — the body is a single string literal with
  `#{param}` interpolation holes. Simpler to write but limited:
  the result is re-parsed, so templates can't carry AST that didn't
  originate as source text.

Macro definitions must appear at the top level of a file. They are not
permitted inside functions, structs, traits, or impl blocks.

---

## Quote / unquote

The quote/unquote form is the primary way to write a macro:

```be
macro double(x) do
  quote do
    unquote(x) + unquote(x)
  end
end

result = $double(21)   # expands to: 21 + 21
```

- `quote do … end` captures the enclosed code as AST.
- `unquote(PARAM)` splices a macro parameter into the expansion.

A parameter referenced without `unquote` is treated as a *name* in the
body — hygiene rules apply (see [Hygiene](#hygiene)).

### Composing macros

A macro body can contain other macro calls. They are expanded
recursively with their own hygiene context:

```be
macro shout(x) do
  quote do
    puts("SHOUT: " + unquote(x))
  end
end

macro shout_twice(x) do
  quote do
    $shout(unquote(x))
    $shout(unquote(x))
  end
end
```

Expansion depth is bounded at 64 to prevent infinite recursion; exceeding
the bound raises `QZ0502`.

---

## String templates

A simpler form for macros that produce text:

```be
macro max(a, b) do
  "if #{a} > #{b} then #{a} else #{b} end"
end

x = $max(10, 20)   # expands to: if 10 > 20 then 10 else 20 end
```

- `#{param}` is replaced by the parameter's source text.
- The result is re-parsed by the lexer/parser at expansion time.

Use string templates for simple substitution. For anything with control
flow or binding structure, prefer quote/unquote — template results go
through a full re-parse, which makes error messages harder to follow.

---

## Fragment specifiers

Parameters can be annotated with a fragment specifier that restricts
what shape of argument is accepted:

```be
macro assert_eq(lhs: expr, rhs: expr) do
  quote do
    if unquote(lhs) != unquote(rhs)
      panic("mismatch")
    end
  end
end

macro def_getter(field: ident) do
  quote do
    def get_unquote(field)() = self.unquote(field)
  end
end
```

Available specifiers:

| Specifier | Accepts                       | Notes                                             |
|-----------|-------------------------------|---------------------------------------------------|
| `expr`    | Any expression (default)      | The unannotated default. Accepts anything.        |
| `ident`   | A bare identifier             | Emits `QZ0504` if given an expression or literal. |
| `type`    | A type expression             | Accepts any AST; validated semantically later.    |
| `block`   | A `do … end` block or lambda  | Emits `QZ0504` otherwise.                         |
| `tt`      | A single token/node, transparent | Useful for passing fragments through untouched.|

Fragment checks run at expansion time. A violated fragment spec aborts
expansion with `QZ0504` before the macro body is cloned.

---

## Variadic parameters

The last parameter can be variadic using `...`:

```be
macro sum(args...) do
  quote do
    unquote_each(args, " + ")
  end
end

$sum(1, 2, 3)   # expands to: 1 + 2 + 3
```

- `args...` binds a sequence of arguments.
- `unquote_each(args, SEP)` joins them with the separator (a literal
  string — supported: `" + "`, `" - "`, `" * "`, `" / "`, `" % "`,
  `" and "`, `" or "`).
- A variadic with zero args is legal.
- Exactly one variadic parameter is permitted, and it must be last.

```be
macro first_of(x, rest...) do
  quote do
    unquote(x)
  end
end

$first_of(10)            # 10
$first_of(10, 20, 30)    # 10 — rest is dropped
```

---

## Hygiene

Macros are **hygienic by default**. A body-local `var` introduced by a
macro cannot shadow or capture a same-named binding in the caller's
scope, and vice versa.

```be
macro swap_through_tmp(a, b) do
  quote do
    var tmp = unquote(a)
    unquote(a) = unquote(b)
    unquote(b) = tmp
  end
end

def main(): Int
  var tmp = 999           # caller's `tmp`
  var x = 1
  var y = 2
  $swap_through_tmp(x, y) # body's `tmp` is distinct
  return tmp              # → 999 (caller's `tmp` is preserved)
end
```

Under the hood, body-local binders are alpha-renamed during expansion.
`var tmp = …` in the body becomes `var tmp__hyg_N__ = …` where `N` is a
fresh integer per expansion. References to `tmp` inside the same body
are renamed consistently. Unquoted arguments flow through with their
original names.

### Binders covered by hygiene

Alpha-rename applies to every body-local name-introducing form:

- `var NAME = …`
- `var (a, b, c) = …` (tuple destructure)
- `Struct { x, y } = …` / `Struct { x: alias, y: alias2 } = …`
- `var [first, second, ..rest] = …` (vec destructure)
- `for NAME in …`
- `for await NAME in …`
- `arena NAME do … end`
- `task_group NAME do … end`
- Lambda params in `(x, y) -> …`
- `if … is Variant(NAME)` pattern binders

### What is *not* hygiene-renamed

- Unquoted arguments. `unquote(x)` substitutes whatever AST the caller
  passed in, preserving the caller's names. This is the primary escape
  hatch: pass a caller-scope identifier through unquote and it stays
  bound to the caller's value.
- Function calls. `vec_new()` inside a macro body is not a binder, so
  it resolves against the caller's scope (typically the stdlib).
- Free references the macro body makes without a corresponding local
  declaration. If a macro body writes `tmp` with no `var tmp = …`, that
  reference lives in the caller's scope. Most macros avoid this — it
  silently couples the macro to caller-visible state.

### Nested expansion

Each macro call gets its own fresh hygiene scope. A macro that calls
another macro sees two levels of rename layered on top of each other:

```be
macro inner() do
  quote do
    var t = 1
  end
end

macro outer() do
  quote do
    var t = 2
    $inner()   # body's `t` becomes `t__hyg_N__`, inner's becomes `t__hyg_M__`
  end
end
```

The two `t`s are distinct at every downstream stage.

---

## The `$caller` escape hatch

Sometimes a macro genuinely wants to reach into the caller's scope — a
`log!`-style macro that references the enclosing function's `logger`
binding, for example. For that case, Quartz provides `$caller(NAME)`,
which emits an identifier that resolves against the caller's scope
instead of the body's:

```be
macro log_it() do
  quote do
    # `$caller(logger)` finds the caller's `logger` binding
    $caller(logger).info("something happened")
  end
end

def do_work(): Void
  var logger = Logger::new()
  $log_it()   # writes through the caller's `logger`
end
```

- `$caller` accepts exactly one argument; it must be a bare identifier.
  Passing a literal or expression raises `QZ0510`.
- The emitted identifier is marked so hygiene does not rename it. At
  typecheck, it resolves against whatever binding the caller has in
  scope with that name.
- If the caller has no matching binding, you get a normal
  "undefined variable" error at the call site.

The convention in Elixir is `var!(foo)`; in Racket it's
`datum->syntax`. `$caller(foo)` is Quartz's form.

---

## Built-in macros

Four macros ship built in. They need no import.

### `$unwrap(expr)`

Unwrap an `Option<T>` or panic with a source location.

```be
val = $unwrap(get_value())   # panics: "unwrap failed at line N" on None
```

Use `try` (the prefix keyword) when you want early-return on `None`
instead of panic.

### `$assert(cond)`

Panic if the condition is false, including the source line in the
message.

```be
$assert(x > 0)                    # "assertion failed at line N"
$assert(vec_size(v) == 3)
```

### `$debug(expr)`

Print an integer to stderr and return the original value.

```be
$debug(x)                         # stderr: "[debug] line N: 42"
y = $debug(a + b) * 2             # prints a+b, uses it in the expression
```

Single-evaluation is guaranteed — the argument is only evaluated once
even when the expansion references it multiple times. Only `Int` values
render usefully; other types print as an integer representation.

### `$caller(name)`

Escape-hatch identifier that resolves against the caller's scope. See
[The `$caller` escape hatch](#the-caller-escape-hatch).

### Retired: `$try`

Pre-Piezo code used `$try(expr)`. It was promoted to the `try` prefix
keyword:

```be
# old (no longer valid)
val = $try(get_value())

# new
val = try get_value()
```

Using the old form emits `QZ0503` with a migration hint pointing at the
keyword form.

---

## `@derive` annotations

`@derive` is a compile-time attribute, parsed before macro expansion,
that synthesizes trait implementations automatically:

```be
@derive(Eq, Ord, Debug, Clone, Hash)
struct Point
  x: Int
  y: Int
end
```

Supported traits: `Eq`, `Ord`, `Debug`, `Clone`, `Hash`. Derivations
coexist with hand-written `impl` blocks — if you derive `Debug` but
then also write `impl Debug for Point`, the hand-written impl wins.

`@derive` is not technically a macro in the expansion-pipeline sense —
it runs during parse as an annotation. It's documented here because it
has the same compile-time-code-generation feel.

---

## Expansion diagnostics

Errors that originate inside an expansion carry an expansion chain, so
you can see which macro introduced the offending code and where it was
invoked:

```
error[QZ0401]: Undefined function: undefined_helper
 --> x.qz:8:10
   = note: in expansion of macro '$call_missing' (defined at 1:1), called at 8:10
```

For nested expansions, the chain walks outward:

```
   = note: in expansion of macro '$inner' (defined at 3:1), called at 5:3
   = note: in expansion of macro '$outer' (defined at 10:1), called at 20:5
```

JSON-format diagnostics (`--error-format json`) include the chain as a
structured `expansion_chain` array.

Both the parser's macro-site errors (e.g. unknown macro, variadic
mismatch) and typecheck errors triggered by expanded code populate the
chain. The coverage is per-error-site, not comprehensive — a few
`tc_error` sites still render without the chain; migrating them is
mechanical (call `tc_error_at(tc, msg, s, h)` instead of
`tc_error(tc, msg, line, col)`).

---

## Limits and gaps

### Hard limits

- Macro expansion depth: **64**. Exceeded by `$a → $b → …`
  cycles — a warning sign for accidental infinite recursion.
- Fragment specifiers: accept / reject only; no custom semantic
  validation.
- Variadic parameters: exactly one per macro, and it must be last.
- Macros are module-local. Importing a module does not bring its
  macros into scope. Workaround: define the macro in each file that
  uses it, or centralize in a prelude file.

### Soft limits and known gaps

- Only `$caller(ident)` accepts an identifier argument — not struct
  accesses, not expressions. A pattern like `$caller(self.field)` does
  not work; write a wrapper.
- `@derive` has a fixed trait set; arbitrary user traits can't be
  derived today.
- Lambda-in-macro-body has an unrelated codegen bug that surfaces when
  the lambda closure is invoked. Filed separately; not a hygiene issue.
- Comprehension bodies that declare `var` inside a condition
  (`[x for x in xs if var y = …]`) bypass hygiene coverage. The walker
  cannot safely recurse into `extras`-stored AST without per-kind
  dispatch, and this specific case hasn't been filed as needed yet.

---

## Error codes

| Code    | Meaning                                                                   |
|---------|---------------------------------------------------------------------------|
| QZ0501  | `unquote` used outside a `quote` block.                                   |
| QZ0502  | Expansion depth exceeded (possible infinite recursion).                   |
| QZ0503  | Unknown macro. Includes a hint for retired `$try` usage.                  |
| QZ0504  | Fragment specifier violation (e.g. `ident` param got an expression).      |
| QZ0510  | Built-in macro ABI error (wrong arity, wrong arg shape).                  |

All macro-phase errors route through the same pipeline as typecheck
errors, with full expansion-chain breadcrumbs attached.

---

## Further reading

- [`QUARTZ_REFERENCE.md`](QUARTZ_REFERENCE.md) — Quartz syntax reference;
  includes a brief "Macros" section that points here.
- [`design/MACRO_AUDIT_8B.md`](design/MACRO_AUDIT_8B.md) — audit memo
  and original sprint plan for the hygiene retrofit.
