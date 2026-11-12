# Bidirectional lambda inference doesn't flow from let-binding annotation

**Filed:** 2026-05-21 (discovered while writing regression specs for HB-DOG.3(b) /
3(c) close-out, after centralizing alias resolution in the Fn-annotation
readers).
**Severity:** Medium — affects every `var f: Fn(...) = (a, b) -> ...` style
binding where the lambda body relies on the param types for correct
dispatch / arithmetic. Pre-existing on trunk (also reproduces on `64c76ca9`
before the alias-resolution fix; the alias fix is orthogonal).

## Summary

The bidirectional-lambda-param inference path lives in
`tc_expr_call` (`typecheck_expr_handlers.qz:3158-3192`, the FIX.6 Phase 2
block). It fires only when a lambda is **directly an argument** to a call:
the path scans the callee's `param_fn_ann` table and injects expected param
types into matching `NODE_LAMBDA` arguments.

A `var observer: Fn(Int, String): String = (n, s) -> s + s` binding never
reaches that path. The lambda's RHS is typechecked while binding `observer`,
and at that point the LHS annotation is not consulted to drive param
inference for the lambda body. The params default to fresh tv-vars, which
existential-erase to `Int`. The body then sees `String + String` as
`Int + Int` (a no-op pointer add), so the function compiles and links but
returns a meaningless integer value silently cast to String at the call
site.

## Reproducer

```quartz
def main(): Int
  var observer: Fn(Int, String, Int, String): String = (a, b, c, d) -> b + d
  print(observer(0, "AB", 0, "CD"))   # prints nothing (empty string)
  print("\n")
  return 0
end
```

Expected output: `ABCD`. Actual: empty line.

The same shape with a direct argument compiles and works correctly — that
codepath is the FIX.6 Phase 2 bidir-inject at the call site:

```quartz
def apply(f: Fn(Int, String, Int, String): String, a: Int, b: String, c: Int, d: String): String
  return f(a, b, c, d)
end

def main(): Int
  print(apply((a, b, c, d) -> b + d, 0, "AB", 0, "CD"))   # prints "ABCD" — works
  return 0
end
```

So the bug is specifically: **inference does not flow from the LET
ANNOTATION into the lambda RHS's param types.**

## Why it's silently wrong

`a, b, c, d` get tv-vars → defaulted to `Int` → `b + d` typechecks as
`Int + Int` because of existential erasure (everything is `i64` at
runtime). The compiler doesn't error on the assignment to `observer:
Fn(..., String): String` because the lambda's *inferred* return is `Int`,
the *declared* return is `String`, and existential erasure makes
`Int`-vs-`String` indistinguishable at the type level past parsing.

At runtime, `b` and `d` are pointers to interned string heap blocks. Adding
the two pointers gives an arbitrary integer; the caller reads that integer
as a String pointer; UB or empty-string ensues.

## Likely fix surface

When `tc_expr_let` (or the equivalent `var`-binding handler) sees a LET
node whose RHS is `NODE_LAMBDA` and whose LHS carries a `Fn(...)` (or
alias-to-`Fn(...)`) type annotation, the same logic that runs at the call
site should fire here:

1. Parse the LHS annotation as a Fn type.
2. For each lambda param without a `str2` annotation, inject the
   corresponding param string from the LHS annotation via
   `tc_fn_annotation_nth_param_str` (now alias-transparent post-3b/3c
   close-out, so `var f: Mapper = ...` is handled too).
3. Then walk the body — the params now have the correct types for method
   dispatch / `+` overload resolution.

The bidir-inject snippet is small (~30 lines); the let-binding handler
would need to replicate it pre-body-walk for the lambda-RHS case.

## Related

- **HB-DOG.3(b)** — argument-position bidir inference. The 2026-05-21
  alias-blind-readers fix made the call-site path alias-transparent;
  this LET-position bug is the next layer.
- **HB-DOG.3(c)** — field-call dispatch through alias. Closed in the
  same commit.
- **5c40a1e6** ("mir: explicit let-binding type annotation refines tracked
  struct type") — analog for struct types. Same shape of fix, different
  context.

## Workaround until fixed

Either:

* Annotate the lambda params explicitly:
  `var observer: Fn(Int, String, Int, String): String = (a: Int, b: String, c: Int, d: String) -> b + d`
* Or pass the lambda directly to its consumer instead of binding first.

## Pull-in trigger

When a real consumer hits this (the hyperbouba port's `observer` pattern
uses the explicit annotation workaround already; if anywhere else in the
codebase ends up bitten, this is the place to revisit).
