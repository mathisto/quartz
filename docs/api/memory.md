# memory

## Structs

### `Arena` *(std/memory.qz:40)*

Arena struct - first-class arena allocator with automatic cleanup
Implements Drop for RAII-style resource management

| Field | Type |
|-------|------|
| `handle` | `Int` |

#### Trait Implementations

**impl Drop for Arena**

##### `drop(): Void`

**impl Allocator for Arena**

##### `allocate(): Int`

##### `deallocate(): Void`

### `PoolWrapper` *(std/memory.qz:83)*

PoolWrapper - fixed-size block allocator wrapper
Fast allocation/deallocation of fixed-size blocks.
Good for objects of uniform size.

| Field | Type |
|-------|------|
| `pool_handle` | `Int` |

#### Trait Implementations

**impl Allocator for PoolWrapper**

##### `allocate(): Int`

##### `deallocate(): Void`

## Traits

### `Drop`

std/memory - Memory allocation primitives

Provides the Allocator trait and wrapper types for Arena and Pool allocators.

Usage:
  import std/memory

  def main(): Int
    a = arena_create()
    ptr = alloc(a, 64)
    free(a, ptr)
    arena_wrapper_destroy(a)
    return 0
  end
Drop trait - called when value goes out of scope

### `Allocator`

Allocator trait - unified interface for memory allocation strategies

## Type Aliases

### `ArenaHandle`

Alias for `Int`

Arena type alias - for raw arena handles from arena intrinsics
Backward compatibility: allows `a: Arena` with arena_new() result

## Functions

### `arena_create(): Arena` *(std/memory.qz:61)*

Create a new Arena allocator with automatic cleanup via Drop

---

### `arena_wrapper_reset(): Void` *(std/memory.qz:66)*

Reset the arena (reuse memory without freeing)

---

### `arena_wrapper_bytes_used(): Int` *(std/memory.qz:71)*

Get bytes currently allocated

---

### `arena_wrapper_capacity(): Int` *(std/memory.qz:76)*

Get total capacity

---

### `pool_create(): PoolWrapper` *(std/memory.qz:101)*

Create a new Pool allocator
block_size: size of each block in bytes
block_count: number of blocks to pre-allocate

---

### `pool_wrapper_destroy(): Void` *(std/memory.qz:106)*

Destroy the pool and free all memory

---

### `pool_wrapper_capacity(): Int` *(std/memory.qz:111)*

Get total block capacity

---

### `pool_wrapper_free_count(): Int` *(std/memory.qz:116)*

Get number of free blocks available

---

### `allocator_alloc(): Int` *(std/memory.qz:122)*

Generic allocation helper - allocate using any Allocator
Named allocator_alloc to avoid collision with builtin alloc

---

### `allocator_free(): Void` *(std/memory.qz:127)*

Generic deallocation helper - deallocate using any Allocator

---

