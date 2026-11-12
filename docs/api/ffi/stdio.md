# ffi/stdio

## FFI Functions

### `puts(s: CPtr): Int` *(std/ffi/stdio.qz:6)*

C stdio.h FFI declarations

Provides extern "C" bindings for standard I/O functions.
Usage: cimport "stdio.h"

### `printf(fmt: CPtr): Int` *(std/ffi/stdio.qz:7)*

### `fprintf(stream: CPtr, fmt: CPtr): Int` *(std/ffi/stdio.qz:8)*

### `fopen(path: CPtr, mode: CPtr): Int` *(std/ffi/stdio.qz:9)*

### `fclose(stream: Int): Int` *(std/ffi/stdio.qz:10)*

### `fgets(buf: CPtr, size: Int, stream: Int): Int` *(std/ffi/stdio.qz:11)*

### `fread(buf: CPtr, size: Int, count: Int, stream: Int): Int` *(std/ffi/stdio.qz:12)*

### `fwrite(buf: CPtr, size: Int, count: Int, stream: Int): Int` *(std/ffi/stdio.qz:13)*

### `fflush(stream: Int): Int` *(std/ffi/stdio.qz:14)*

