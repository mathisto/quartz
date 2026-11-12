# qspec/property

## Functions

### `_init_rng(): Void` *(std/qspec/property.qz:27)*

QSpec Property Testing - forall sugar with generators and shrinking

First-class property-based testing for Quartz.
No mainstream systems language has this built into its test framework.

Usage:
  import qspec
  import qspec/property

  describe("addition") do ->
    forall_ii(ctx, "is commutative") do x: Int, y: Int ->
      assert_eq(x + y, y + x)
    end
  end

---

### `qspec_seed(): Void` *(std/qspec/property.qz:35)*

Seed the RNG with a specific value

---

### `gen_next(): Int` *(std/qspec/property.qz:41)*

Generate next pseudo-random integer

---

### `gen_int(): Int` *(std/qspec/property.qz:55)*

Generate random Int in [lo, hi] inclusive

---

### `gen_nat(): Int` *(std/qspec/property.qz:68)*

Generate random non-negative Int up to max

---

### `gen_bool(): Bool` *(std/qspec/property.qz:73)*

Generate random Bool

---

### `gen_string(): String` *(std/qspec/property.qz:78)*

Generate random String of given max length

---

### `gen_vec_int(): Int` *(std/qspec/property.qz:91)*

Generate random Vec<Int> of given max length, with values in [lo, hi]

---

### `shrink_int(): Int` *(std/qspec/property.qz:107)*

Shrink an Int toward zero

---

### `qspec_set_iterations(): Void` *(std/qspec/property.qz:140)*

---

### `forall_i(): Void` *(std/qspec/property.qz:149)*

Property test: forall x: Int in default range

---

### `_run_forall_i(): Void` *(std/qspec/property.qz:153)*

---

### `_shrink_i(): Int` *(std/qspec/property.qz:185)*

---

### `forall_ii(): Void` *(std/qspec/property.qz:216)*

Property test: forall x: Int, y: Int

---

### `_run_forall_ii(): Void` *(std/qspec/property.qz:220)*

---

### `_shrink_ii(): Int` *(std/qspec/property.qz:254)*

---

### `property_commutative(): Void` *(std/qspec/property.qz:307)*

Test that a function is commutative: f(a, b) == f(b, a)

---

### `property_identity(): Void` *(std/qspec/property.qz:314)*

Test that a function has an identity element: f(x, e) == x

---

### `property_idempotent(): Void` *(std/qspec/property.qz:321)*

Test idempotence: f(f(x)) == f(x)

---

