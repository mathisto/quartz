# Borrowing & Mutation

> **Current scope:** Quartz implements lexical borrow/exclusivity checks for
> `&` and `&mut`, including overlapping-place and non-escape diagnostics. This
> is not yet a complete memory-safety boundary: lexical `unsafe` does not exist,
> raw/unchecked operations are not consistently fenced, deeper liveness cases
> remain, and known safe-looking programs can still fault. See
> [`STABILIZATION_INVARIANTS.md`](design/STABILIZATION_INVARIANTS.md).

---

## The Problem

Memory safety bugs — use-after-free, dangling pointers, data races from aliased mutation — are the #1 source of security vulnerabilities in systems code. Chrome, Microsoft, and Android all report 65-70% of their security bugs come from this single class of error.

The root cause is **aliased mutation**: two references to the same data where at least one can write. One reference reads stale data, or two writers corrupt each other.

## The Rule

**Many readers OR one writer. Never both.**

Quartz statically enforces this rule for the borrow forms and places recognized
by the current exclusivity pass. Do not generalize that scoped check into a
whole-language memory-safety guarantee.

---

## Two Kinds of Borrows

### `&x` — Shared (Read-Only) Borrow

Multiple shared borrows can coexist. Nobody can write.

```quartz
var p = Point { x: 3, y: 4 }
a = point_sum(&p)     # OK — read-only
b = point_sum(&p)     # OK — multiple readers fine
```

### `&mut x` — Exclusive (Mutable) Borrow

Only one exclusive borrow at a time. The borrower can write back to the original.

```quartz
var p = Point { x: 0, y: 0 }
set_x(&mut p, 42)
# p.x is now 42 — mutation went through the borrow
```

---

## The Rules

There are exactly **five rules**. If you remember these, you know the entire borrow checker.

### 1. Multiple `&` is fine — multiple `&mut` is not

```quartz
var x = 42
a = &x       # OK
b = &x       # OK — multiple shared borrows

var y = 42
a = &mut y   # OK
b = &mut y   # ERROR (QZ1205) — only one exclusive borrow allowed
```

### 2. `&` and `&mut` cannot coexist

```quartz
var x = 42
a = &x       # shared borrow
b = &mut x   # ERROR (QZ1206) — conflicts with shared borrow

var y = 42
a = &mut y   # exclusive borrow
b = &y       # ERROR (QZ1206) — conflicts with exclusive borrow
```

### 3. Cannot mutate while borrowed

```quartz
var x = 42
p = &x
x = 99       # ERROR (QZ1209) — x is borrowed, can't mutate it
```

This applies to all mutation forms: `=`, `+=`, field assign, index assign.

### 4. Cannot return a borrow

```quartz
def bad(): Int
  var x = 42
  return &x   # ERROR (QZ1210) — x dies when bad() returns
end
```

The variable is destroyed when the function returns. The borrow would dangle.

This also applies **indirectly** — returning a binding that holds a borrow:

```quartz
def also_bad(): Int
  var x = 42
  var r = &x
  return r    # ERROR (QZ1210) — r holds a borrow of x
end
```

### 5. Cannot store a borrow in a struct field

```quartz
struct Holder
  ptr: Int
end

var x = 42
h = Holder { ptr: &x }  # ERROR (QZ1211) — borrow may outlive source
```

The struct could be passed around, outliving the variable it borrows from.

This also applies **indirectly** — storing a binding that holds a borrow:

```quartz
var x = 42
var r = &x
h = Holder { ptr: r }   # ERROR (QZ1211) — r holds a borrow of x
```

---

## Ephemeral Borrows

Borrows passed as function arguments are **ephemeral** — they're released when the call returns.

```quartz
def peek(r: &Int): Int = 0

var x = 42
peek(&x)        # shared borrow created, then released
var p = &mut x   # OK — the shared borrow is gone
```

This is the common case. Most borrows are ephemeral and never cause issues.

**Stored borrows** (assigned to a variable) live until their **last use** (NLL-lite):

```quartz
var x = 42
var p = &x       # stored borrow
var y = p + 1    # last use of p — borrow released here
x = 99           # OK — p's borrow has expired
```

If the borrow is used after the mutation, it's still an error:

```quartz
var x = 42
var p = &x
x = 99           # ERROR (QZ1209) — p is still live (used below)
var y = p + 1    # last use of p
```

---

## Reassignment Releases Borrows

If you reassign a variable that holds a borrow, the old borrow is released:

```quartz
var x = 42
var p = &x       # p borrows x (shared)
p = 0            # p reassigned — borrow on x released
var q = &mut x   # OK — x is no longer borrowed
```

---

## Borrows Inside Loops

Borrows created inside a loop body are scoped to that iteration. They don't leak across iterations or persist after the loop:

```quartz
var x = 42
var i = 0
while i < 3
  var r = &x     # borrow created each iteration
  var y = r + 1  # last use — NLL releases it
  i = i + 1
end
x = 99           # OK — no borrow persists after the loop
```

Borrows created **before** a loop are unaffected — they keep their existing lifetime:

```quartz
var x = 42
var r = &x       # borrow created before loop
while i < 3
  i = i + 1
end
var y = r + 1    # OK — r is still live
```

---

## Lifetime Diagnostics

Borrow errors include **dual-span information** — both the error site and the borrow creation site:

```
error[QZ1209]: Cannot mutate 'x' while it is borrowed by 'r' (borrow created at line 3, live until line 5)
 --> file.qz:4:3
```

For dangling reference errors:

```
error[QZ1218]: Dangling borrow — 'r' borrows 'inner' which is going out of scope (borrow created at line 5)
```

---

## `&mut` Requires `var`

You can only create a mutable borrow of a mutable binding:

```quartz
x = 42           # immutable (no var)
p = &mut x       # ERROR (QZ1208) — x is not mutable

var y = 42       # mutable
p = &mut y       # OK
```

---

## Error Code Reference

| Code | Error | Meaning |
|------|-------|---------|
| **QZ1205** | Cannot create exclusive borrow | Variable is already `&mut` borrowed |
| **QZ1206** | Conflicting borrows | Mixing `&` and `&mut` on the same variable |
| **QZ1208** | Cannot &mut immutable binding | Target must be declared with `var` |
| **QZ1209** | Cannot mutate while borrowed | Any assign/compound-assign while a borrow exists |
| **QZ1210** | Cannot return borrow of local | Local dies at function exit; borrow would dangle |
| **QZ1211** | Cannot store borrow in struct | Struct may outlive the borrowed variable |

All error codes support `quartz --explain QZ1209` for detailed help.

---

## What This Doesn't Cover

Quartz's borrow checker is deliberately simpler than Rust's. These patterns are **not supported** and don't need to be:

| Pattern | Why Not |
|---------|---------|
| Borrowing through containers (Vec, Map) | Would need generic lifetime params |
| Borrow splitting (different struct fields) | Not worth the complexity |
| Named lifetime annotations (`'a`) | NLL-lite covers the common cases without annotations |

For the rare cases that need these patterns, use `CPtr` and FFI.

---

## Who Needs to Know This

**Most users: nobody.** The borrow checker is silent for code that doesn't use `&` or `&mut`. It only activates when you explicitly create borrows.

**Systems programmers** passing data by reference will encounter these rules. The errors are clear, the fixes are straightforward, and there's nothing to annotate.

**Coming from Rust?** You already know this, minus the lifetimes. That's the whole difference.
