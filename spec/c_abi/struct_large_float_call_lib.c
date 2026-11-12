/* B.10 P3.4-ii-b oracle — >16B F32 struct-by-value, the Quartz->C direction.
 *
 * Structs >16 bytes with F32 fields cross the C boundary INDIRECTLY (byval param
 * / sret return), and their true C layout (packed 4-byte floats, e.g.
 * `struct F6{float x6}` = 24B) differs from Quartz's INTERNAL layout (F32 in an
 * 8-byte double-bits i64 slot, 48B). So Quartz must REPACK each F32 field
 * (fptrunc/fpext) into a C-layout `%struct.Name.cabi` buffer at the boundary.
 * The Quartz caller (struct_large_float_call_main.qz) declares these `extern
 * "C"`, builds the structs, calls them, asserts results. */
#include <stdint.h>

struct F6    { float a, b, c, d, e, f; };           /* 24B all float       */
struct FMix6 { int32_t a, b, c; float d, e, f; };    /* 24B int + float     */
struct FW    { float a, b; int64_t c, d; };          /* 24B float + wide    */

/* byval param -> scalar; sum*4 is exact (inputs are quarter-units) */
long f6_sum4(struct F6 v)    { return (long)((v.a + v.b + v.c + v.d + v.e + v.f) * 4.0f); }
long fmix6_chk(struct FMix6 v) { return (v.a == 1 && v.b == 2 && v.c == 3 && v.d == 1.5f && v.f == 3.5f) ? 1 : 0; }
long fw_chk(struct FW v)     { return (v.a == 1.5f && v.b == 2.5f && v.c == 100 && v.d == 200) ? 1 : 0; }

/* sret return (a4/4.0f is exact) */
struct F6 mk_f6(int a4) {
  struct F6 v = {a4 / 4.0f, (a4 + 1) / 4.0f, (a4 + 2) / 4.0f, (a4 + 3) / 4.0f, (a4 + 4) / 4.0f, (a4 + 5) / 4.0f};
  return v;
}
struct FMix6 mk_fmix6(int a, int d4) {
  struct FMix6 v = {a, a + 1, a + 2, d4 / 4.0f, (d4 + 1) / 4.0f, (d4 + 2) / 4.0f};
  return v;
}

/* byval-in + sret-out on one call */
struct F6 f6_inc(struct F6 v) {
  struct F6 r = {v.a + 1.0f, v.b + 1.0f, v.c + 1.0f, v.d + 1.0f, v.e + 1.0f, v.f + 1.0f};
  return r;
}
