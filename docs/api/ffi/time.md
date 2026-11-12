# ffi/time

## Structs

### `Tm` *(std/ffi/time.qz:24)*

| Field | Type |
|-------|------|
| `tm_sec` | `CInt` |
| `tm_min` | `CInt` |
| `tm_hour` | `CInt` |
| `tm_mday` | `CInt` |
| `tm_mon` | `CInt` |
| `tm_year` | `CInt` |
| `tm_wday` | `CInt` |
| `tm_yday` | `CInt` |
| `tm_isdst` | `CInt` |
| `tm_gmtoff` | `Int` |
| `tm_zone` | `CPtr` |

## FFI Functions

### `time(tloc: CPtr): Int` *(std/ffi/time.qz:45)*

### `clock(): Int` *(std/ffi/time.qz:50)*

### `difftime(time1: Int, time0: Int): CDouble` *(std/ffi/time.qz:54)*

### `localtime(timep: CPtr): CPtr` *(std/ffi/time.qz:59)*

### `gmtime(timep: CPtr): CPtr` *(std/ffi/time.qz:64)*

### `mktime(tm: CPtr): Int` *(std/ffi/time.qz:69)*

### `strftime(buf: CPtr, maxsize: CSize, format: CPtr, tm: CPtr): CSize` *(std/ffi/time.qz:79)*

### `gettimeofday(tv: CPtr, tz: CPtr): CInt` *(std/ffi/time.qz:84)*

