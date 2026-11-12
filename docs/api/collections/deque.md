# collections/deque

## Structs

### `Deque` *(std/collections/deque.qz:16)*

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_head` | `Int` |
| `_size` | `Int` |
| `_capacity` | `Int` |

#### Methods

##### `push_front(): Void`

Push a value to the front.

##### `push_back(): Void`

Push a value to the back.

##### `pop_front(): Option<Int>`

Pop and return the front value. Returns Option::None if empty.

##### `pop_back(): Option<Int>`

Pop and return the back value. Returns Option::None if empty.

##### `peek_front(): Option<Int>`

Peek at the front value without removing it. Returns Option::None if empty.

##### `peek_back(): Option<Int>`

Peek at the back value without removing it. Returns Option::None if empty.

##### `get(): Int`

Get the element at a logical index. Returns 0 if out of bounds.

##### `set(): Void`

Set the element at a logical index.

##### `size(): Int`

Return the number of elements.

##### `is_empty(): Bool`

Return true if the deque is empty.

##### `clear(): Void`

Remove all elements.

##### `free(): Void`

Free the underlying storage.

##### `push(): Void`

Alias for push_back — add to end.

##### `pop(): Option<Int>`

Alias for pop_back — remove from end.

##### `unshift(): Void`

Alias for push_front — add to front.

##### `shift(): Option<Int>`

Alias for pop_front — remove from front.

##### `first(): Option<Int>`

Alias for peek_front — peek at front.

##### `last(): Option<Int>`

Alias for peek_back — peek at end.

##### `to_vec(): Vec<Int>`

##### `each(): Void`

##### `map(): Vec<Int>`

##### `filter(): Vec<Int>`

##### `reduce(): Int`

##### `find(): Int`

##### `any(): Bool`

##### `all(): Bool`

##### `count(): Int`

##### `iter(): DequeIter`

Return an iterator over deque elements (front to back).
Creates a snapshot of elements in logical order.

### `DequeIter` *(std/collections/deque.qz:319)*

DequeIter — iterates over a snapshot of Deque elements (front to back).

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_index` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for DequeIter**

##### `next(): Option<Int>`

## Functions

### `_deque_make_buf(): Vec<Int>` *(std/collections/deque.qz:24)*

Internal: create a Vec<Int> pre-filled with n zeros.

---

### `deque_new(): Deque` *(std/collections/deque.qz:35)*

Create a new empty deque with default capacity 8.

---

### `deque_new_with_capacity(): Deque` *(std/collections/deque.qz:42)*

Create a new empty deque with a specific initial capacity.

---

### `_deque_grow(): Void` *(std/collections/deque.qz:52)*

Internal: grow the deque by copying elements in logical order to a new buffer.

---

