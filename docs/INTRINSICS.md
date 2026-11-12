# Quartz Intrinsics

Intrinsics are Quartz's semantic primitives. Everything else is sugar that desugars to these.

**Total: 28 intrinsics**

## Design Principles

1. If it can be a library function, it's NOT an intrinsic
2. Intrinsics are the compiler's syscalls—stable ABI
3. Adding an intrinsic requires discussion
4. Removing an intrinsic requires migration path

## Tier 0: Control Flow

| Intrinsic | Signature | LLVM |
|-----------|-----------|------|
| `@ret` | `(val: i64) -> !` | `ret i64` |
| `@br` | `(cond: i64, then: Label, else: Label) -> !` | `br i1, label, label` |
| `@jmp` | `(target: Label) -> !` | `br label` |
| `@unreachable` | `() -> !` | `unreachable` |

## Tier 1: Memory

| Intrinsic | Signature | Description |
|-----------|-----------|-------------|
| `@alloc` | `(words: i64) -> i64` | Heap allocate N words |
| `@load` | `(ptr: i64, offset: i64) -> i64` | Load word at ptr[offset] |
| `@store` | `(ptr: i64, offset: i64, val: i64) -> ()` | Store word at ptr[offset] |

## Tier 2: Arithmetic

| Intrinsic | Signature | Description |
|-----------|-----------|-------------|
| `@add` | `(a: i64, b: i64) -> i64` | Integer addition |
| `@sub` | `(a: i64, b: i64) -> i64` | Integer subtraction |
| `@mul` | `(a: i64, b: i64) -> i64` | Integer multiplication |
| `@div` | `(a: i64, b: i64) -> i64` | Integer division (signed) |
| `@mod` | `(a: i64, b: i64) -> i64` | Integer modulo |
| `@neg` | `(a: i64) -> i64` | Integer negation |

## Tier 3: Comparison

| Intrinsic | Signature | Description |
|-----------|-----------|-------------|
| `@eq` | `(a: i64, b: i64) -> i64` | Equal (returns 0 or 1) |
| `@ne` | `(a: i64, b: i64) -> i64` | Not equal |
| `@lt` | `(a: i64, b: i64) -> i64` | Less than (signed) |
| `@le` | `(a: i64, b: i64) -> i64` | Less or equal |
| `@gt` | `(a: i64, b: i64) -> i64` | Greater than |
| `@ge` | `(a: i64, b: i64) -> i64` | Greater or equal |

## Tier 4: Values & Tagging

| Intrinsic | Signature | Description |
|-----------|-----------|-------------|
| `@truthy` | `(val: i64) -> i64` | Ruby truthiness (only nil/false are falsy) |
| `@tag` | `(val: i64) -> i64` | Get type tag from value |
| `@box_int` | `(n: i64) -> i64` | Tag raw int as Quartz integer |
| `@unbox_int` | `(val: i64) -> i64` | Extract raw int from tagged value |

## Tier 5: Strings

| Intrinsic | Signature | Description |
|-----------|-----------|-------------|
| `@str_size` | `(s: i64) -> i64` | String length in codepoints |
| `@str_concat` | `(a: i64, b: i64) -> i64` | Concatenate two strings |
| `@str_eq` | `(a: i64, b: i64) -> i64` | String equality |

## Tier 6: Calls

| Intrinsic | Signature | Description |
|-----------|-----------|-------------|
| `@call` | `(fn: i64, args: i64, argc: i64) -> i64` | Indirect function call |

## Builtins (Not Intrinsics)

Builtins are compiler-provided functions that aren't semantic primitives. They're implemented in codegen but could eventually move to a standard library.

**Total: ~250+ builtins** (registered in `self-hosted/middle/typecheck_builtins.qz`)

### I/O

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `puts` | `(s: String, newline?: Bool) -> Void` | Print string **with** trailing newline |
| `print` | `(s: String) -> Void` | Print string **without** trailing newline |
| `eputs` | `(s: String, newline?: Bool) -> Void` | Print to stderr, **auto-appends** trailing newline (do not pass `"msg\n"` — you will get `msg\n\n`) |
| `eprint` | `(s: String) -> Void` | Print to stderr **without** trailing newline |
| `print_int` | `(n: Int) -> Void` | Print integer **with** trailing newline |
| `eprint_int` | `(n: Int) -> Void` | Print integer to stderr **with** trailing newline |
| `read_file` | `(path: String) -> String` | Read entire file contents |
| `write_file` | `(path: String, content: String) -> Int` | Write string to file |
| `read_line` | `() -> String` | Read one newline-stripped line from stdin (empty string on EOF) |
| `read_stdin` | `() -> String` | Read all of stdin to EOF into one string (preserves embedded newlines/blank lines) |

### String Functions — Codepoint Level (default)

Strings in Quartz are UTF-8 encoded. The default string API operates at codepoint level:
`.size` returns codepoint count, `s[i]` returns the codepoint at codepoint index `i`,
`.slice(a, b)` extracts by codepoint range. Codepoint indexing is O(n) per access.

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `str_size` | `(s: String) -> Int` | String length in codepoints |
| `str_char_at` | `(s: String, i: Int) -> Int` | Codepoint value at codepoint index |
| `str_slice` | `(s: String, start: Int, end: Int) -> String` | Substring by codepoint range [start, end) |
| `str_find` | `(s: String, needle: String) -> Option<Int>` | Find substring, returns codepoint offset |
| `str_codepoint_at` | `(s: String, i: Int) -> Int` | Alias for `str_char_at` (deprecated) |
| `str_from_codepoint` | `(cp: Int) -> String` | Codepoint to string |
| `str_concat` | `(a: String, b: String) -> String` | Concatenate two strings |
| `str_contains` | `(s: String, needle: String) -> Bool` | Check substring existence |
| `str_split` | `(s: String, delim: String) -> Vec<String>` | Split into vector |
| `str_from_int` | `(n: Int) -> String` | Integer to string |
| `str_from_char` | `(code: Int) -> String` | Char code to single-char string |
| `str_eq` | `(a: String, b: String) -> Bool` | String equality |
| `str_cmp` | `(a: String, b: String) -> Int` | String comparison (-1/0/1) |
| `str_hash` | `(s: String) -> Int` | String hash |
| `str_to_int` | `(s: String) -> Int` | Parse string to integer |
| `str_to_f64` | `(s: String) -> F64` | Parse string to float |
| `f64_to_str` | `(f: F64) -> String` | Float to string |
| `str_starts_with` | `(s: String, prefix: String) -> Bool` | Check prefix |
| `str_ends_with` | `(s: String, suffix: String) -> Bool` | Check suffix |
| `str_downcase` | `(s: String) -> String` | Lowercase |
| `str_upcase` | `(s: String) -> String` | Uppercase |
| `str_trim` | `(s: String) -> String` | Trim whitespace |
| `str_trim_left` | `(s: String) -> String` | Trim left whitespace |
| `str_trim_right` | `(s: String) -> String` | Trim right whitespace |
| `str_replace` | `(s: String, old: String, new: String) -> String` | Replace occurrences |
| `str_reverse` | `(s: String) -> String` | Reverse string |
| `str_repeat` | `(s: String, n: Int) -> String` | Repeat N times |
| `str_count` | `(s: String, sub: String) -> Int` | Count occurrences |
| `str_join` | `(v: Vec<String>, sep: String) -> String` | Join vector with separator |
| `str_is_empty` | `(s: String) -> Bool` | Check if empty |
| `str_substr` | `(s: String, start: Int, len: Int) -> String` | Substring by offset+length |
| `str_pad_left` | `(s: String, width: Int, pad: String) -> String` | Left pad |
| `str_pad_right` | `(s: String, width: Int, pad: String) -> String` | Right pad |
| `str_chars` | `(s: String) -> Vec<Int>` | String to codepoint vector |

### String Functions — Byte Level

Byte-level intrinsics provide O(1) indexed access to the raw UTF-8 bytes. Use these
for performance-critical code, ASCII protocol parsing, or when you need byte-exact control.
Available as both free functions and UFCS methods (e.g., `s.byte_len()`).

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `str_byte_len` | `(s: String) -> Int` | String length in bytes, O(1) |
| `str_byte_at` | `(s: String, i: Int) -> Int` | Byte value at byte index, O(1) |
| `str_byte_slice` | `(s: String, start: Int, end: Int) -> String` | Substring by byte range [start, end), O(1) |
| `str_byte_find` | `(s: String, needle: String) -> Option<Int>` | Find substring, returns byte offset |
| `str_bytes` | `(s: String) -> Vec<Int>` | String to byte value vector |
| `str_from_bytes` | `(bytes: Vec<Int>) -> String` | Byte-exact String from a byte vector — the inverse of `str_bytes`. Each element is truncated to its low 8 bits; NUL bytes are preserved. **Not** a UTF-8 encoder (unlike `str_from_char`/`str_from_codepoint`) — use it with `write_file` to emit binary formats. |
| `str_is_valid_utf8` | `(s: String) -> Bool` | Validate UTF-8 encoding |

### Character Classification

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `is_digit` | `(ch: Int) -> Bool` | Is 0-9 |
| `is_alpha` | `(ch: Int) -> Bool` | Is a-z, A-Z |
| `is_alnum` | `(ch: Int) -> Bool` | Is alphanumeric |
| `is_whitespace` | `(ch: Int) -> Bool` | Is space/tab/newline |
| `is_upper` | `(ch: Int) -> Bool` | Is uppercase |
| `is_lower` | `(ch: Int) -> Bool` | Is lowercase |

### Control Flow

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `exit` | `(code: Int) -> !` | Exit process |
| `assert` | `(cond: Int) -> Void` | Abort if false |
| `panic` | `(msg: String) -> !` | Panic with message |
| `unreachable` | `() -> !` | Mark unreachable code |
| `expect` | `(cond: Int) -> Int` | Assert with return |

### Vector Operations

All Vec builtins support UFCS. Prefer `v.push(x)` over `vec_push(v, x)`.

| Builtin | UFCS | Description |
|---------|------|-------------|
| `vec_new<T>` | — | Create new dynamic array |
| `vec_new_filled` | — | Create filled vector |
| `vec_push<T>` | `v.push(val)` | Append to end |
| `vec_pop<T>` | `v.pop()` | Remove last — Option<T> (v5.26) |
| `vec_get<T>` | `v.get(idx)` or `v[idx]` | Get value at index |
| `vec_set<T>` | `v.set(idx, val)` or `v[idx] = val` | Set value at index |
| `vec_get_unchecked<T>` | — | Get without bounds check |
| `vec_set_unchecked<T>` | — | Set without bounds check |
| `vec_size<T>` | `v.size` | Get length |
| `vec_free<T>` | `v.free()` | Free memory |
| `vec_clear` | `v.clear()` | Remove all elements |
| `vec_contains` | `v.contains(val)` | Check if contains value |
| `vec_index_of` | `v.index_of(val)` | Find index — Option<Int> (v5.26) |
| `vec_insert` | `v.insert(idx, val)` | Insert at index |
| `vec_delete` | `v.delete(idx)` | Delete at index |
| `vec_join` | `v.join(sep)` | Join strings |
| `vec_reverse` | `v.reverse()` | Reverse copy |
| `vec_clone` | `v.clone()` | Deep copy |
| `vec_sort` | `v.sort()` | In-place sort ascending |
| `vec_sort_by` | `v.sort_by(cmp)` | Sort with comparator |

### Binary Vec I/O

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `vec_save` | `(v: Vec<Int>, path: String) -> Int` | Save Vec to file |
| `vec_load` | `(path: String) -> Vec<Int>` | Load Vec from file |
| `strvec_save` | `(v: Vec<String>, path: String) -> Int` | Save string Vec to file |
| `strvec_load` | `(path: String) -> Vec<String>` | Load string Vec from file |

### Map Operations

Quartz has a unified `Map<K,V>` type. The compiler dispatches to string-key or integer-key implementations based on the key type. All Map builtins support UFCS. Prefer `m.get(k)` over `map_get(m, k)`.

| Builtin | UFCS | Description |
|---------|------|-------------|
| `map_new<K,V>` | — | Create new map |
| `map_get<K,V>` | `m.get(key)` | Get value — Option<V> |
| `map_set<K,V>` | `m.set(key, val)` | Set key-value |
| `map_has<K,V>` | `m.has(key)` | Check key exists |
| `map_delete<K,V>` | `m.delete(key)` | Delete key |
| `map_free<K,V>` | `m.free()` | Free memory |
| `map_clear` | `m.clear()` | Remove all entries |
| `map_size` | `m.size()` | Number of entries |
| `map_keys` | `m.keys()` | All keys |
| `map_values` | `m.values()` | All values |

### Set Operations

All Set builtins support UFCS. Prefer `s.add(x)` over `set_add(s, x)`.

| Builtin | UFCS | Description |
|---------|------|-------------|
| `set_new` | — | Create new set |
| `set_add` | `s.add(val)` | Add element |
| `set_has` | `s.has(val)` | Check membership |
| `set_delete` | `s.delete(val)` | Remove element |
| `set_size` | `s.size()` | Number of elements |
| `set_members` | `s.members()` | All members |
| `set_clear` | `s.clear()` | Remove all |
| `set_free` | `s.free()` | Free memory |
| `set_union` | `s.union(other)` | Union |
| `set_intersection` | `s.intersection(other)` | Intersection |
| `set_difference` | `s.difference(other)` | Difference |
| `set_is_subset` | `s.is_subset(other)` | Subset check |

### StringBuilder

All StringBuilder builtins support UFCS. Prefer `sb.append(s)` over `sb_append(sb, s)`.

| Builtin | UFCS | Description |
|---------|------|-------------|
| `sb_new` | — | Create builder |
| `sb_append` | `sb.append(s)` | Append string |
| `sb_append_int` | `sb.append_int(n)` | Append integer |
| `sb_append_char` | `sb.append_char(c)` | Append char code |
| `sb_to_string` | `sb.to_string()` | Build string |
| `sb_len` | `sb.size()` | Current length |
| `sb_clear` | `sb.clear()` | Reset builder |
| `sb_free` | `sb.free()` | Free memory |

### Option/Result

All Option/Result builtins support UFCS. Prefer `opt.unwrap_or(0)` over `unwrap_or(opt, 0)`.
Also use the `is` keyword for variant checks: `opt is Some`, `result is Err`.

| Builtin | UFCS | Description |
|---------|------|-------------|
| `unwrap` | `opt.unwrap()` | Unwrap or panic |
| `unwrap_or` | `opt.unwrap_or(fallback)` | Unwrap with default |
| `option_is_some` | `opt.is_some()` or `opt is Some` | Check if Some |
| `option_is_none` | `opt.is_none()` or `opt is None` | Check if None |
| `option_map` | `opt.map(fn)` | Transform inner value |
| `option_get` | `opt.get()` | Extract value |
| `option_free` | `opt.free()` | Free option |
| `option_some` | — | Construct Some |
| `option_none` | — | Construct None |

### Arena Operations (v5.1+)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `arena_new` | `() -> Arena` | Create new arena (4KB default) |
| `arena_alloc` | `(arena: Arena, size: Int) -> Int` | Allocate bytes |
| `arena_alloc<T>` | `(arena: Arena) -> Ptr<T>` | Typed allocation |
| `arena_reset` | `(arena: Arena) -> Void` | Reset (preserves chain) |
| `arena_destroy` | `(arena: Arena) -> Void` | Free all blocks |
| `arena_bytes_used` | `(arena: Arena) -> Int` | Total allocated bytes |
| `arena_capacity` | `(arena: Arena) -> Int` | Total capacity |
| `arena_alloc_count` | `(arena: Arena) -> Int` | Number of allocations |
| `arena_block_count` | `(arena: Arena) -> Int` | Number of blocks |

### Bump Allocator

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `bump_new` | `(capacity: Int) -> Int` | Create bump allocator |
| `bump_alloc` | `(bump: Int, size: Int) -> Int` | Allocate (branchless) |
| `bump_reset` | `(bump: Int) -> Void` | Reset to start |
| `bump_free` | `(bump: Int) -> Void` | Free allocator |

### Pool Allocator

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `pool_new` | `(elem_size: Int, count: Int) -> Pool` | Create pool |
| `pool_alloc` | `(pool: Pool) -> Int` | Allocate slot |
| `pool_free` | `(pool: Pool, ptr: Int) -> Void` | Free slot |
| `pool_destroy` | `(pool: Pool) -> Void` | Destroy pool |
| `pool_capacity` | `(pool: Pool) -> Int` | Total slots |
| `pool_alloc_count` | `(pool: Pool) -> Int` | Active allocations |
| `pool_free_count` | `(pool: Pool) -> Int` | Free slots |

### Arena Pools (v5.2+)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `arena_pool_new` | `(arena_size: Int, count: Int) -> ArenaPool` | Create pool of arenas |
| `arena_pool_acquire` | `(pool: ArenaPool) -> Arena` | Get available arena |
| `arena_pool_release` | `(pool: ArenaPool, arena: Arena) -> Void` | Return arena (auto-reset) |
| `arena_pool_destroy` | `(pool: ArenaPool) -> Void` | Free pool and all arenas |
| `arena_pool_available` | `(pool: ArenaPool) -> Int` | Available arenas |
| `arena_pool_capacity` | `(pool: ArenaPool) -> Int` | Total arenas |

### Type-safe Pointers (v5.2+)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `ptr_read<T>` | `(ptr: Int) -> T` | Read typed value |
| `ptr_write<T>` | `(ptr: Int, value: T) -> Void` | Write typed value |
| `ptr_alloc` | `(n: Int) -> Int` | Allocate n * 8 bytes |
| `ptr_add` | `(ptr: Int, offset: Int) -> Int` | Pointer arithmetic |
| `ptr_is_null` | `(ptr: CPtr) -> Bool` | Null check |
| `addr_of` | `(var: T) -> Int` | Address of variable |

### FFI / C Interop

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `string_to_cstr` | `(s: String) -> CPtr` | String to C string (strdup) |
| `cstr_to_string` | `(p: CPtr) -> String` | C string to Quartz string |
| `cptr_to_string_with_len` | `(p: CPtr, len: Int) -> String` | Buffer with length to String |
| `cptr_to_int` | `(p: CPtr) -> Int` | Pointer to integer |
| `int_to_cptr` | `(i: Int) -> CPtr` | Integer to pointer |
| `ptr_read_byte` | `(p: CPtr) -> Int` | Read byte |
| `ptr_write_byte` | `(p: CPtr, val: Int) -> Void` | Write byte |
| `qz_malloc` | `(size: Int) -> CPtr` | Allocate memory |
| `qz_free` | `(p: CPtr) -> Void` | Free memory |
| `field_offset<T>` | `(field: String) -> Int` | Byte offset of field |

### Type Conversion

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `to_int` | `(f: F64) -> Int` | Float to integer (truncates) |
| `to_f64` | `(n: Int) -> F64` | Integer to double |
| `to_f32` | `(n: Int) -> F32` | Integer to float |
| `to_i8` | `(n: Int) -> I8` | Truncate to signed 8-bit |
| `to_i16` | `(n: Int) -> I16` | Truncate to signed 16-bit |
| `to_i32` | `(n: Int) -> I32` | Truncate to signed 32-bit |
| `to_u8` | `(n: Int) -> U8` | Truncate to unsigned 8-bit |
| `to_u16` | `(n: Int) -> U16` | Truncate to unsigned 16-bit |
| `to_u32` | `(n: Int) -> U32` | Truncate to unsigned 32-bit |
| `to_u64` | `(n: Int) -> Int` | Identity (U64 = Int width) |
| `as_string` | `(val: Int) -> String` | Coerce to string |
| `as_int` | `(val: String) -> Int` | Coerce to int |
| `as_int_generic` | `(val: T) -> Int` | Type erasure (identity) |
| `as_type<T>` | `(val: Int) -> T` | Type recovery (identity) |
| `as_f64` | `(bits: Int) -> F64` | Reinterpret raw IEEE-754 bits as a double — the inverse of `as_int` on an `F64`. **Not** a numeric conversion: `as_f64(x)` reinterprets `x`'s bit pattern, `to_f64(x)` converts `x`'s integer value. Use the pair `as_int`/`as_f64` for `F64`↔bytes serialization. |

### Bitwise Operations

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `bor` | `(a: Int, b: Int) -> Int` | Bitwise OR |
| `band` | `(a: Int, b: Int) -> Int` | Bitwise AND |
| `bxor` | `(a: Int, b: Int) -> Int` | Bitwise XOR |
| `bnot` | `(a: Int) -> Int` | Bitwise NOT |
| `shl` | `(a: Int, b: Int) -> Int` | Shift left |
| `shr` | `(a: Int, b: Int) -> Int` | Shift right |
| `popcount` | `(n: Int) -> Int` | Count set bits |
| `clz` | `(n: Int) -> Int` | Count leading zeros |
| `ctz` | `(n: Int) -> Int` | Count trailing zeros |
| `bswap` | `(n: Int) -> Int` | Byte swap |
| `rotl` | `(n: Int, k: Int) -> Int` | Rotate left |
| `rotr` | `(n: Int, k: Int) -> Int` | Rotate right |

### Concurrency (v5.5+)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `channel_new` | `(capacity: Int) -> Int` | Create buffered channel |
| `send` | `(ch: Int, val: Int) -> Void` | Send (blocks if full) |
| `recv` | `(ch: Int) -> Int` | Receive (blocks if empty) |
| `recv_timeout` | `(ch: Int, ms: Int) -> Int` | Receive with timeout |
| `try_send` | `(ch: Int, val: Int) -> Bool` | Non-blocking send |
| `try_recv` | `(ch: Int) -> Bool` | Non-blocking receive |
| `channel_close` | `(ch: Int) -> Void` | Close channel |
| `channel_closed` | `(ch: Int) -> Bool` | Check if closed |
| `channel_len` | `(ch: Int) -> Int` | Buffered items |
| `mutex_new` | `(init: Int) -> Int` | Create mutex |
| `mutex_lock` | `(m: Int) -> Int` | Lock (returns value) |
| `mutex_unlock` | `(m: Int, val: Int) -> Void` | Unlock (stores value) |
| `mutex_try_lock` | `(m: Int) -> Bool` | Non-blocking lock |
| `channel_free` | `(ch: Int) -> Void` | Free channel resources |
| `mutex_free` | `(m: Int) -> Void` | Free mutex resources |
| `pool_shutdown` | `() -> Void` | Shut down thread pool |

### RWLock (v5.13+)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `rwlock_new` | `(init: Int) -> Int` | Create read-write lock with initial value |
| `rwlock_read` | `(rw: Int) -> Int` | Acquire read lock, return value |
| `rwlock_read_unlock` | `(rw: Int) -> Void` | Release read lock |
| `rwlock_write` | `(rw: Int) -> Int` | Acquire write lock, return value |
| `rwlock_write_unlock` | `(rw: Int, val: Int) -> Void` | Store new value, release write lock |
| `rwlock_free` | `(rw: Int) -> Void` | Destroy and free rwlock |

### WaitGroup (v5.13+)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `waitgroup_new` | `(count: Int) -> Int` | Create waitgroup with initial count |
| `waitgroup_done` | `(wg: Int) -> Void` | Decrement count; signal when zero |
| `waitgroup_wait` | `(wg: Int) -> Void` | Block until count reaches zero |
| `waitgroup_free` | `(wg: Int) -> Void` | Free waitgroup resources |

### OnceCell (v5.13+)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `oncecell_new` | `() -> Int` | Create empty once-cell |
| `oncecell_get_or_init` | `(cell: Int, init: Fn(): Int) -> Int` | Initialize or return cached value |
| `oncecell_get` | `(cell: Int) -> Int` | Get value (aborts if uninitialized) |
| `oncecell_free` | `(cell: Int) -> Void` | Free once-cell resources |

### Atomics (v5.5+)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `atomic_new` | `(val: Int) -> AtomicInt` | Create atomic integer |
| `atomic_load` | `(a: AtomicInt, ord?: Int) -> Int` | Atomic load |
| `atomic_store` | `(a: AtomicInt, val: Int, ord?: Int) -> Void` | Atomic store |
| `atomic_add` | `(a: AtomicInt, val: Int, ord?: Int) -> Int` | Atomic add (returns old) |
| `atomic_sub` | `(a: AtomicInt, val: Int, ord?: Int) -> Int` | Atomic subtract (returns old) |
| `atomic_exchange` | `(a: AtomicInt, val: Int, ord?: Int) -> Int` | Exchange (returns old) |
| `atomic_cas` | `(a: AtomicInt, exp: Int, new: Int, ord?: Int) -> Bool` | Compare-and-swap |
| `fence` | `(ordering: Int) -> Void` | Full memory barrier |
| `compiler_fence` | `(ordering: Int) -> Void` | Compiler-only fence |

### F64 Math

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `f64_sqrt` | `(f: F64) -> F64` | Square root |
| `f64_sin`/`cos`/`tan` | `(f: F64) -> F64` | Trigonometric |
| `f64_asin`/`acos`/`atan` | `(f: F64) -> F64` | Inverse trig |
| `f64_atan2` | `(y: F64, x: F64) -> F64` | Two-argument arctangent |
| `f64_floor`/`ceil`/`round` | `(f: F64) -> F64` | Rounding |
| `f64_abs` | `(f: F64) -> F64` | Absolute value |
| `f64_log`/`log2`/`log10` | `(f: F64) -> F64` | Logarithms |
| `f64_exp` | `(f: F64) -> F64` | Exponential |
| `f64_pow` | `(base: F64, exp: F64) -> F64` | Power |
| `f64_min`/`f64_max` | `(a: F64, b: F64) -> F64` | Min/max |

### Regex

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `regex_replace` | `(s: String, pat: String, rep: String) -> String` | First match replace |
| `regex_replace_all` | `(s: String, pat: String, rep: String) -> String` | All matches replace |
| `regex_split` | `(s: String, pat: String) -> Vec<String>` | Split by pattern |
| `regex_count` | `(s: String, pat: String) -> Int` | Count matches |
| `regex_matches` | `(s: String, pat: String) -> Vec<String>` | All match strings |
| `regex_match_start` | `(s: String, pat: String) -> Option<Int>` | Match start index |
| `regex_match_end` | `(s: String, pat: String) -> Option<Int>` | Match end index |
| `regex_capture_named` | `(s: String, pat: String, name: String) -> String` | Named capture |

### File System

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `file_exists` | `(path: String) -> Bool` | Check file existence |
| `file_size` | `(path: String) -> Int` | File size in bytes |
| `file_delete` | `(path: String) -> Int` | Delete file |
| `open_file` | `(path: String, mode: Int) -> Int` | Open file descriptor |
| `close_file` | `(fd: Int) -> Int` | Close file descriptor |
| `fwrite` | `(fd: Int, data: String) -> Int` | Write to file descriptor |
| `fread` | `(fd: Int, len: Int) -> String` | Read from file descriptor |
| `mkdir` | `(path: String) -> Int` | Create directory |
| `rmdir` | `(path: String) -> Int` | Remove directory |
| `readdir` | `(path: String) -> Vec<String>` | List directory entries |
| `rename` | `(old: String, new: String) -> Int` | Rename file/directory |

### Path Operations

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `path_join` | `(a: String, b: String) -> String` | Join paths |
| `path_ext` | `(path: String) -> String` | File extension |
| `path_dir` | `(path: String) -> String` | Directory component |
| `path_basename` | `(path: String) -> String` | Base name |

### Environment

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `getenv` | `(name: String) -> String` | Get environment variable |
| `setenv` | `(name: String, value: String) -> Int` | Set environment variable |
| `argc` | `() -> Int` | Number of CLI arguments |
| `argv` | `(n: Int) -> String` | Get CLI argument N |
| `system` | `(cmd: String) -> Int` | Execute shell command |
| `getcwd` | `() -> String` | Current working directory |
| `chdir` | `(path: String) -> Int` | Change directory |

### Random Numbers

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `rand_seed` | `(seed: Int) -> Void` | Seed the RNG |
| `rand_int` | `() -> Int` | Random integer |
| `rand_range` | `(min: Int, max: Int) -> Int` | Random in range |
| `rand_float` | `() -> F64` | Random float [0, 1) |

### System & Timing

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `time_mono_ns` | `() -> Int` | Monotonic clock (nanoseconds) |
| `sleep_ms` | `(ms: Int) -> Void` | Sleep for milliseconds |
| `mem_peak_rss` | `() -> Int` | Peak resident set size (bytes, via getrusage) |
| `mem_forget` | `(val: T) -> Void` | Prevent destructor from running |

### Enumerable Functions

All enumerable functions support UFCS. Prefer `arr.map() { it * 2 }` over `map(arr, x -> x * 2)`.
Use implicit `it` in short trailing blocks: `arr.filter() { it > 0 }`.

| Builtin | UFCS + implicit `it` | Description |
|---------|---------------------|-------------|
| `each` | `arr.each() { puts("#{it}") }` | Iterate with side effects |
| `map` | `arr.map() { it * 2 }` | Transform elements |
| `filter` | `arr.filter() { it > 0 }` | Filter by predicate |
| `reduce` | `arr.reduce(0) do acc, x -> acc + x end` | Accumulate |
| `any?`/`all?` | `arr.any?() { it < 0 }` | Quantifier predicates (return `Bool`, so `?` suffix) |
| `find` | `arr.find() { it == 42 }` | First matching element |
| `first`/`last` | `arr.first()` | First/last element |
| `take`/`drop` | `arr.take(3)` | Slice operations |
| `count` | `arr.count() { it > 0 }` | Count matches |
| `sum`/`product` | `arr.sum()` | Aggregation |
| `min`/`max` | `arr.min()` | Extrema |
| `sort` | `sorted(arr)` | Sorted copy |
| `reverse` | `reversed(arr)` | Reversed copy |
| `unique` | `unique(arr)` | Deduplicated copy |
| `zip` | `zip(a, b)` | Zip two arrays |
| `enumerate` | `enumerate(arr)` | Index-value pairs |
| `flatten` | `flatten(nested)` | Flatten nested arrays |
| `group_by` | `group_by(arr, fn)` | Group by function |
| `partition` | `partition(arr, fn)` | Split by predicate |
| `parallel_map`/`parallel_for`/`parallel_reduce` | ... | Parallel variants |

### SIMD Intrinsics

See `typecheck_builtins.qz` for the full list (~60 builtins). Grouped by vector type:

- **F32x4** (128-bit, 4×float): `simd_f32x4_splat`, `_add`, `_sub`, `_mul`, `_div`, `_load`, `_store`, `_extract`, `_sum`, `_fma`, `_min`, `_max`, `_abs`, `_shuffle`, `_gather`, `_scatter`
- **F64x2** (128-bit, 2×double): `simd_f64x2_splat`, `_add`, `_sub`, `_mul`, `_div`, `_extract`, `_sum`, `_fma`, `_min`, `_max`, `_abs`, `_shuffle`, `_gather`, `_scatter`
- **I32x4** (128-bit, 4×i32): `simd_i32x4_splat`, `_add`, `_sub`, `_mul`, `_extract`, `_sum`, `_fma`, `_min`, `_max`, `_abs`, `_shuffle`, `_gather`, `_scatter`
- **F32x8** (256-bit, 8×float): `simd_f32x8_splat`, `_add`, `_sub`, `_mul`, `_div`, `_load`, `_store`, `_extract`, `_sum`, `_fma`, `_min`, `_max`, `_abs`, `_sqrt`, `_gather`, `_scatter`
- **Conversion**: `simd_convert_f32x4_to_i32x4`, `simd_convert_i32x4_to_f32x4`, etc.

### Structured Concurrency

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `task_pool_get` | `() -> Int` | Get thread pool |
| `task_group_new` | `(pool: Int) -> Int` | Create task group |
| `task_group_await_all` | `(tg: Int) -> Void` | Wait for all tasks |
| `task_group_destroy` | `(tg: Int) -> Void` | Destroy task group |
| `taskgroup_spawn` | `(tg: Int, fn: Fn) -> Void` | Spawn task |
| `taskgroup_collect` | `(tg: Int) -> Vec<Int>` | Collect results |
| `taskgroup_cancel` | `(tg: Int) -> Void` | Cancel group |
| `cancel_token_new` | `() -> Int` | Create token |
| `cancel_token_cancel` | `(tok: Int) -> Void` | Signal cancel |
| `cancel_token_is_cancelled` | `(tok: Int) -> Bool` | Check cancelled |
| `cancel_token_with_deadline` | `(timeout_ms: Int) -> Int` | Create token that auto-cancels after timeout |
| `cancel_token_free` | `(tok: Int) -> Void` | Free cancel token |
| `is_cancelled` | `() -> Bool` | Check current thread |

### M:N Scheduler (v5.26+)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `sched_init` | `(num_workers: Int) -> Void` | Initialize scheduler with N worker threads (0 = auto-detect) |
| `sched_spawn` | `(task: Int) -> Void` | Enqueue async task frame onto scheduler |
| `sched_shutdown` | `() -> Void` | Wait for all tasks to complete, then shut down |
| `sched_yield` | `() -> Void` | Cooperative yield (re-enqueue current task) |
| `sched_register_io` | `(fd: Int, task: Int) -> Void` | Register fd for I/O wakeup (internal) |

The `go` keyword desugars to `async func(args)` + `sched_spawn(frame)`:
```quartz
sched_init(4)
go my_func(arg1, arg2)   # spawns lightweight task
sched_shutdown()          # waits for all tasks, then cleans up
```

When a task calls `io_suspend(fd)`, the scheduler registers the fd with kqueue (macOS) or epoll (Linux). When the fd becomes ready, the task is automatically re-enqueued and resumed.

### Output Capture (Testing)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `capture_output_start` | `() -> Int` | Start stdout capture |
| `capture_output_end` | `(handle: Int) -> String` | End capture, get output |

### UFCS Method Aliases

All built-in types have UFCS method aliases registered as `Type$method`. These allow calling builtins with dot syntax. **UFCS style is preferred over free-function calls:**

```quartz
# Preferred UFCS style
v.push(x)                        # → vec_push(v, x)
v.pop()                          # → vec_pop(v)
v.size                           # → vec_size(v)
s.find("x")                      # → str_find(s, x)
m.get(k)                         # → map_get(m, k)
m.set(k, v)                      # → map_set(m, k, v)
m.has(k)                         # → map_has(m, k)
a.load()                         # → atomic_load(a)
ch.send(v)                       # → send(ch, v)

# Option/Result UFCS
opt.unwrap_or(0)                 # → unwrap_or(opt, 0)
opt.is_some()                    # → option_is_some(opt)
opt.is_none()                    # boolean check
opt.map(x -> x * 2)             # transform inner value
res.is_ok()                      # boolean check
res.is_err()                     # boolean check
```

Types with UFCS aliases: `Vec`, `Map`, `Set`, `StringBuilder`, `String`, `Int`, `F64`, `Channel`, `Mutex`, `AtomicInt`, `TaskGroup`, `Option`, `Result`.

## Future Intrinsics (When Needed)

Reserved for future implementation:

| Intrinsic | Purpose |
|-----------|---------|
| `@gc_safepoint` | GC integration |

## Versioning

Intrinsic ABI is versioned with the language:

- v0.x: Intrinsics may change
- v1.0+: Intrinsics are stable ABI

To change an intrinsic after v1.0:
1. Add new intrinsic with new name
2. Deprecate old intrinsic
3. Remove old intrinsic after 2 major versions
