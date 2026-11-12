# collections/linked_list

## Structs

### `LinkedList` *(std/collections/linked_list.qz:16)*

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_next` | `Vec<Int>` |
| `_prev` | `Vec<Int>` |
| `_free_slots` | `Vec<Int>` |
| `_head` | `Int` |
| `_tail` | `Int` |
| `_size` | `Int` |

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

Peek at the front value. Returns Option::None if empty.

##### `peek_back(): Option<Int>`

Peek at the back value. Returns Option::None if empty.

##### `get(): Int`

Get the element at index (0-based, O(n) traversal). Returns 0 if out of bounds.

##### `contains(): Bool`

Check if the list contains a value.

##### `to_vec(): Vec<Int>`

Convert the list to a Vec, traversing head to tail.

##### `size(): Int`

Return the number of elements.

##### `is_empty(): Bool`

Return true if the list is empty.

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

##### `each(): Void`

##### `map(): Vec<Int>`

##### `filter(): Vec<Int>`

##### `reduce(): Int`

##### `find(): Int`

##### `any(): Bool`

##### `all(): Bool`

##### `count(): Int`

##### `iter(): LinkedListIter`

Return an iterator over linked list elements (head to tail).

### `LinkedListIter` *(std/collections/linked_list.qz:353)*

LinkedListIter — iterates over LinkedList elements by following the next-pointer chain.

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_next` | `Vec<Int>` |
| `_current` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for LinkedListIter**

##### `next(): Option<Int>`

## Functions

### `ll_new(): LinkedList` *(std/collections/linked_list.qz:27)*

Create a new empty linked list.

---

### `linked_list_new(): LinkedList` *(std/collections/linked_list.qz:40)*

Alias for ll_new — more descriptive constructor name.

---

### `_ll_alloc_slot(): Int` *(std/collections/linked_list.qz:45)*

Internal: allocate a slot, reusing from free list if possible.

---

### `_ll_free_slot(): Void` *(std/collections/linked_list.qz:66)*

Internal: recycle a slot back to the free list.

---

