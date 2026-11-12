# ffi/stdlib

## FFI Functions

### `malloc(size: Int): Int` *(std/ffi/stdlib.qz:6)*

C stdlib.h FFI declarations

Provides extern "C" bindings for standard library functions.
Usage: cimport "stdlib.h"

### `free(ptr: Int): Void` *(std/ffi/stdlib.qz:7)*

### `realloc(ptr: Int, size: Int): Int` *(std/ffi/stdlib.qz:8)*

### `exit(code: Int): Void` *(std/ffi/stdlib.qz:9)*

### `atoi(s: CPtr): Int` *(std/ffi/stdlib.qz:10)*

### `getenv(name: CPtr): Int` *(std/ffi/stdlib.qz:11)*

