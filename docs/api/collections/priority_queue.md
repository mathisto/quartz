# collections/priority_queue

## Structs

### `PriorityQueue` *(std/collections/priority_queue.qz:19)*

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_is_max` | `Int` |

#### Methods

##### `push(): Void`

Push a value onto the heap.

##### `pop(): Option<Int>`

Pop and return the highest-priority value. Returns Option::None if empty.

##### `peek(): Option<Int>`

Peek at the highest-priority value without removing it. Returns Option::None if empty.

##### `size(): Int`

Return the number of elements.

##### `is_empty(): Bool`

Return true if the queue is empty.

##### `clear(): Void`

Remove all elements.

##### `free(): Void`

Free the underlying storage.

##### `to_vec(): Vec<Int>`

##### `each(): Void`

##### `map(): Vec<Int>`

##### `filter(): Vec<Int>`

##### `reduce(): Int`

##### `find(): Int`

##### `any(): Bool`

##### `all(): Bool`

##### `count(): Int`

##### `iter(): PQIter`

Return an iterator over heap elements (array order, NOT priority order).

### `PQIter` *(std/collections/priority_queue.qz:265)*

PQIter — iterates over PriorityQueue elements by array index.

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |
| `_index` | `Int` |

#### Trait Implementations

**impl Iterator<Int> for PQIter**

##### `next(): Option<Int>`

## Functions

### `pq_new(): PriorityQueue` *(std/collections/priority_queue.qz:25)*

Create a new min-heap priority queue.

---

### `pq_new_max(): PriorityQueue` *(std/collections/priority_queue.qz:30)*

Create a new max-heap priority queue.

---

### `priority_queue_new(): PriorityQueue` *(std/collections/priority_queue.qz:35)*

Alias for pq_new — more descriptive constructor name.

---

### `priority_queue_new_max(): PriorityQueue` *(std/collections/priority_queue.qz:40)*

Alias for pq_new_max — more descriptive constructor name.

---

### `_pq_should_swap(): Int` *(std/collections/priority_queue.qz:46)*

Internal: should element at index a be above element at index b?
Min-heap: a < b. Max-heap: a > b.

---

### `_pq_swap(): Void` *(std/collections/priority_queue.qz:60)*

Internal: swap two elements in the data vec.

---

### `_pq_sift_up(): Void` *(std/collections/priority_queue.qz:67)*

Internal: sift up from index to restore heap property.

---

### `_pq_sift_down(): Void` *(std/collections/priority_queue.qz:81)*

Internal: sift down from index to restore heap property.

---

