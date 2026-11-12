# iter

## Structs

### `MapIter` *(std/iter.qz:38)*

MapIter — transforms each element via a function.
next_fn is a closure that calls the inner iterator's next() method.
The closure is created at the call site where the concrete type is known.

| Field | Type |
|-------|------|
| `next_fn` | `Fn(): Option<Int>` |
| `f` | `Fn(Int): Int` |

#### Trait Implementations

**impl Iterator<Int> for MapIter**

##### `next(): Option<Int>`

### `FilterIter` *(std/iter.qz:53)*

FilterIter — keeps elements matching a predicate.

| Field | Type |
|-------|------|
| `next_fn` | `Fn(): Option<Int>` |
| `pred` | `Fn(Int): Bool` |

#### Trait Implementations

**impl Iterator<Int> for FilterIter**

##### `next(): Option<Int>`

### `TakeIter` *(std/iter.qz:73)*

TakeIter — yields at most N elements from the inner iterator.

| Field | Type |
|-------|------|
| `next_fn` | `Fn(): Option<Int>` |
| `remaining` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for TakeIter**

##### `next(): Option<Int>`

### `SkipIter` *(std/iter.qz:90)*

SkipIter — skips the first N elements, then yields the rest.

| Field | Type |
|-------|------|
| `next_fn` | `Fn(): Option<Int>` |
| `remaining` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for SkipIter**

##### `next(): Option<Int>`

### `TakeWhileIter` *(std/iter.qz:108)*

TakeWhileIter — yields elements while predicate holds, then stops.

| Field | Type |
|-------|------|
| `next_fn` | `Fn(): Option<Int>` |
| `pred` | `Fn(Int): Bool` |
| `done` | `Bool` |

#### Trait Implementations

**impl Iterator<Int> for TakeWhileIter**

##### `next(): Option<Int>`

### `VecIter` *(std/iter.qz:147)*

VecIter — iterates over Vec<Int> elements by index.

| Field | Type |
|-------|------|
| `data` | `Vec<Int>` |
| `index` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for VecIter**

##### `next(): Option<Int>`

### `RangeIter` *(std/iter.qz:169)*

RangeIter — iterates over a numeric range [start, stop).

| Field | Type |
|-------|------|
| `current` | `Int` |
| `stop` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for RangeIter**

##### `next(): Option<Int>`

### `EnumerateIter` *(std/iter.qz:393)*

EnumerateIter — yields (index, element) tuples.

| Field | Type |
|-------|------|
| `next_fn` | `Fn(): Option<Int>` |
| `index` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for EnumerateIter**

##### `next(): Option<Int>`

### `ZipIter` *(std/iter.qz:409)*

ZipIter — yields (a, b) tuples from two iterators. Stops when either is exhausted.

| Field | Type |
|-------|------|
| `next_a` | `Fn(): Option<Int>` |
| `next_b` | `Fn(): Option<Int>` |

#### Trait Implementations

**impl Iterator<Int> for ZipIter**

##### `next(): Option<Int>`

### `ChainIter` *(std/iter.qz:425)*

ChainIter — concatenates two iterators: yields all from first, then all from second.

| Field | Type |
|-------|------|
| `first` | `Fn(): Option<Int>` |
| `second` | `Fn(): Option<Int>` |
| `first_done` | `Bool` |

#### Trait Implementations

**impl Iterator<Int> for ChainIter**

##### `next(): Option<Int>`

### `FlatMapIter` *(std/iter.qz:449)*

FlatMapIter — maps each element to a Vec<Int> and flattens.
Maintains an internal buffer of the current expansion.

| Field | Type |
|-------|------|
| `next_fn` | `Fn(): Option<Int>` |
| `f` | `Fn(Int): Vec<Int>` |
| `buffer` | `Vec<Int>` |
| `buf_idx` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for FlatMapIter**

##### `next(): Option<Int>`

### `ScanIter` *(std/iter.qz:478)*

ScanIter — stateful fold yielding each intermediate accumulator value.
Given f(acc, elem) -> new_acc, yields new_acc after each element.

| Field | Type |
|-------|------|
| `next_fn` | `Fn(): Option<Int>` |
| `acc` | `Int` |
| `f` | `Fn(Int, Int): Int` |

#### Trait Implementations

**impl Iterator<Int> for ScanIter**

##### `next(): Option<Int>`

## Functions

### `vec_iter(): VecIter` *(std/iter.qz:164)*

Create an iterator from a Vec<Int>.

---

### `range_iter(): RangeIter` *(std/iter.qz:186)*

Create a range iterator from start (inclusive) to stop (exclusive).

---

### `iter_map(): MapIter` *(std/iter.qz:196)*

Transform each element using a function.
Usage: iter_map(-> counter.next(), x -> x * 2)

---

### `iter_filter(): FilterIter` *(std/iter.qz:201)*

Keep only elements matching a predicate.

---

### `iter_take(): TakeIter` *(std/iter.qz:206)*

Yield at most N elements.

---

### `iter_skip(): SkipIter` *(std/iter.qz:211)*

Skip the first N elements.

---

### `iter_take_while(): TakeWhileIter` *(std/iter.qz:216)*

Yield elements while predicate holds.

---

### `iter_enumerate(): EnumerateIter` *(std/iter.qz:221)*

Pair each element with its index: yields (index, value) tuples.

---

### `iter_zip(): ZipIter` *(std/iter.qz:226)*

Zip two iterators together: yields (a, b) tuples. Stops when either is exhausted.

---

### `iter_chain(): ChainIter` *(std/iter.qz:231)*

Chain two iterators: yields all elements from the first, then all from the second.

---

### `iter_flat_map(): FlatMapIter` *(std/iter.qz:237)*

FlatMap: maps each element to a Vec<Int> and flattens the results.
The mapping function produces a Vec<Int> for each input element.

---

### `iter_scan(): ScanIter` *(std/iter.qz:243)*

Scan: stateful fold that yields each intermediate accumulator value.
Like fold, but produces a sequence of partial results instead of a final value.

---

### `iter_collect(): Vec<Int>` *(std/iter.qz:252)*

Collect all elements into a Vec<Int>.

---

### `iter_sum(): Int` *(std/iter.qz:266)*

Sum all elements.

---

### `iter_count(): Int` *(std/iter.qz:280)*

Count all elements.

---

### `iter_fold(): Int` *(std/iter.qz:294)*

Left fold with accumulator.

---

### `iter_any(): Bool` *(std/iter.qz:311)*

Returns true if any element matches the predicate.

---

### `iter_all(): Bool` *(std/iter.qz:329)*

Returns true if all elements match the predicate.

---

### `iter_find(): Option<Int>` *(std/iter.qz:347)*

Find the first element matching a predicate.

---

### `iter_for_each(): Void` *(std/iter.qz:360)*

Apply a function to each element (eager, for side effects).

---

### `iter_min(): Option<Int>` *(std/iter.qz:375)*

Find the minimum element (returns Option::None for empty iterators).

---

### `iter_max(): Option<Int>` *(std/iter.qz:495)*

Find the maximum element (returns Option::None for empty iterators).

---

