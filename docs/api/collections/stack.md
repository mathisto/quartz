# collections/stack

## Structs

### `Stack` *(std/collections/stack.qz:13)*

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |

#### Methods

##### `push(): Void`

Push a value onto the top of the stack.

##### `pop(): Option<Int>`

Pop the top value off the stack. Returns Option::None if empty.

##### `peek(): Option<Int>`

Peek at the top value without removing it. Returns Option::None if empty.

##### `size(): Int`

Return the number of elements in the stack.

##### `is_empty(): Bool`

Return true if the stack is empty.

##### `clear(): Void`

Remove all elements from the stack.

##### `free(): Void`

Free the underlying storage.

##### `to_vec(): Vec<Int>`

Convert to a Vec (bottom to top).

##### `each(): Void`

Iterate over each element (bottom to top).

##### `map(): Vec<Int>`

Map each element to a new value.

##### `filter(): Vec<Int>`

Filter elements by predicate.

##### `reduce(): Int`

Fold/reduce all elements.

##### `find(): Int`

Find first element matching predicate. Returns 0 if not found.

##### `any(): Bool`

Check if any element matches predicate.

##### `all(): Bool`

Check if all elements match predicate.

##### `count(): Int`

Count elements matching predicate.

##### `iter(): StackIter`

Return an iterator over stack elements (bottom to top).

### `StackIter` *(std/collections/stack.qz:180)*

StackIter — iterates over Stack elements by index (bottom to top).

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_index` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for StackIter**

##### `next(): Option<Int>`

## Functions

### `stack_new(): Stack` *(std/collections/stack.qz:18)*

Create a new empty stack.

---

