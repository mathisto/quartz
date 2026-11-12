# Generic operator / trait-method dispatch is missing (bounded generics silently pointer-compare)

**Status:** OPEN — foundational compiler gap, high priority. Filed 2026-07-07 (conductor run `argtype-soundness-2026-07-07`, discovered while trying to make `assert_eq` polymorphic).
**Severity:** High — silent miscompile in a CORE language feature (trait-bounded generics). Confirmed live latent bug in shipped stdlib.

## Symptom (verified directly by the conductor)
Inside a trait-bounded generic body, an operator like `==` on a type parameter `T` does NOT dispatch to the concrete type's trait impl — it lowers to a raw i64 `icmp` (pointer/identity comparison). The bound (`<T: Eq>`) is checked at typecheck but is NOT load-bearing for operator resolution.

```qz
import * from traits           # trait Eq; extend String with Eq { op_eq = str_eq }

def check<T: Eq>(a: T, b: T): Bool
  return a == b
end

def main(): Int
  var s1 = "hel" + "lo"        # runtime-constructed String, distinct pointer
  var s2 = "hello"             # literal
  if check<String>(s1, s2)  puts("MATCH")  else  puts("NO_MATCH")  end
  return 0
end
```
**Output: `NO_MATCH`** — the two content-equal strings compare unequal because `==` compared pointers, not contents. (Concrete `String == String` outside a generic DOES content-compare via `str_eq` — the bug is specific to generic `T`.)

Also verified: calling the trait method directly on a generic — `op_eq(a, b)` inside `<T: Eq>` — emits QZ0215 erased-value warnings and **SIGSEGVs at runtime**. And `.to_s()` / the `Show` trait's `.show()` do not resolve on a generic `T` either (`.to_s()` is typecheck-special-cased for concrete Int/Float receivers only; `Show` has zero `extend ... with Show` impls in the tree).

## Confirmed live latent bug from this gap
`std/tui/widgets/focus.qz` — `FocusRing<Id: Eq>` `_focus_ring_index_of` uses `ids[i] == target`. With a content-equal-but-distinct-pointer String id, `focus_ring_is_focused` returns `false` when it should return `true`. Any bounded-generic container relying on `==`/`op_eq` over non-Int elements is silently broken.

## Root cause (hypothesis — needs confirmation during the fix)
Bounded generics DO monomorphize (a `check$2$String` body is emitted), but the operator `==` is lowered to `icmp` during the GENERIC pass (T abstract) and monomorphization copies the already-lowered body with T substituted — it does not RE-RESOLVE the operator (or trait method) against the monomorph's concrete type. The fix: defer operator/trait-method resolution on bounded type params until monomorphization (when T is concrete), or re-resolve at monomorph time against the concrete type's trait impl. This is how Rust/Swift trait-bound generics work.

## Scope of the fix (the epic)
1. **Generic operator dispatch:** `==`/`!=` (→ `op_eq`/`op_ne`), and presumably `<`/`<=`/… (→ `Ord`), `+`/`-`/… where trait-backed, on a bounded `T` route to the concrete impl at monomorph time. Built-in behavior for Int/primitives preserved.
2. **Generic trait-method dispatch:** calling a bound's method (`x.op_eq(y)`, `x.show()`) on a generic `T` must dispatch to the concrete impl (currently SIGSEGVs).
3. **`Show`/`to_s` on generic `T`:** make stringification dispatch through a trait so generic code can format values (needed for e.g. a polymorphic `assert_eq` failure message). Currently `.to_s()` is a concrete-receiver typecheck special-case.
4. **Audit** existing bounded-generic `==`/comparison uses for the same latent bug (FocusRing is one; grep `<[A-Za-z]*: Eq`, `: Ord`, generic containers).

## Why it matters / impact
Trait-bounded generics are a core language feature; silently miscompiling their operators to pointer-identity is a serious correctness gap. Fixing it unlocks correct generic equality/ordering everywhere, fixes the FocusRing bug, and cleanly enables a polymorphic `assert_eq` (the immediate motivation — see `docs/bugs/CALL_SITE_ARG_TYPE_UNCHECKED.md` / ROADMAP R2.3). Estimated multi-day (quartz-time); touches typecheck operator/method resolution + MIR monomorphization lowering.

## How this was found
Trying to make qspec's `assert_eq` polymorphic (`<T: Eq + Show>`) to unblock the R2.3 call-site arg-type check. A research pass claimed the bounded generic would content-compare; a direct test with a genuinely-distinct-pointer string (`"hel"+"lo"`) falsified it (`NO_MATCH`). Interim (per owner): the 3 latent string-`assert_eq` sites are migrated to the concrete `assert_eq_str` instead, and this epic is filed for a dedicated, properly-scoped effort.
