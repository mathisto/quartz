# collections/queue

## Structs

### `Queue` *(std/collections/queue.qz:15)*

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_head` | `Int` |

#### Methods

##### `enqueue(): Void`

Add a value to the back of the queue.

##### `dequeue(): Option<Int>`

Remove and return the front value. Returns Option::None if empty.

##### `peek(): Option<Int>`

Peek at the front value without removing it. Returns Option::None if empty.

##### `size(): Int`

Return the number of elements in the queue.

##### `is_empty(): Bool`

Return true if the queue is empty.

##### `clear(): Void`

Remove all elements from the queue.

##### `free(): Void`

Free the underlying storage.

##### `push(): Void`

Alias for enqueue — add to end.

##### `shift(): Option<Int>`

Alias for dequeue — remove from front.

##### `first(): Option<Int>`

Alias for peek — peek at front.

##### `to_vec(): Vec<Int>`

##### `each(): Void`

##### `map(): Vec<Int>`

##### `filter(): Vec<Int>`

##### `reduce(): Int`

##### `find(): Int`

##### `any(): Bool`

##### `all(): Bool`

##### `count(): Int`

##### `iter(): QueueIter`

Return an iterator over queue elements (front to back).

### `QueueIter` *(std/collections/queue.qz:208)*

QueueIter — iterates over Queue elements from front to back.

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_index` | `Int` |
| `_end` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for QueueIter**

##### `next(): Option<Int>`

## Functions

### `queue_new(): Queue` *(std/collections/queue.qz:21)*

Create a new empty queue.

---

