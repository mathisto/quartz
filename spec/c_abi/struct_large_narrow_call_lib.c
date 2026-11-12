/* B.10 P3.4-ii-a oracle — >16B NARROW-packed struct-by-value, Quartz->C.
 *
 * Structs >16 bytes cross the C boundary INDIRECTLY (byval param / sret return).
 * When they contain sub-8-byte int fields the true C layout is packed
 * (`struct N6{int32 x6}` = 24B), NOT N contiguous 8-byte words — the Quartz
 * INTERNAL `%struct.Name` (packed iN slots) already equals it, so the boundary
 * memory type must be the true-size `%struct.Name`, not `[N x i64]` (= 48B for
 * N6, wrong). The Quartz caller (struct_large_narrow_call_main.qz) declares these
 * `extern "C"`, builds the structs, calls them, asserts results — proving the
 * caller-side byval/sret emission matches the real platform C ABI. */
#include <stdint.h>

struct N6 { int32_t a, b, c, d, e, f; };          /* 24B, pure narrow */
struct NW { int64_t a; int32_t b, c, d; };         /* 24B, narrow + wide */

long c_n6_sum(struct N6 v) { return (long)v.a + v.b + v.c + v.d + v.e + v.f; }
long c_nw_sum(struct NW v) { return (long)v.a + v.b + v.c + v.d; }

struct N6 c_make_n6(int base) {
  struct N6 v = {base, base + 1, base + 2, base + 3, base + 4, base + 5};
  return v;
}
struct NW c_make_nw(long a, int b, int c, int d) {
  struct NW v = {a, b, c, d};
  return v;
}

/* byval-in + sret-out on one call */
struct N6 c_n6_inc(struct N6 v) {
  struct N6 r = {v.a + 1, v.b + 1, v.c + 1, v.d + 1, v.e + 1, v.f + 1};
  return r;
}
