/* B.10 P3.4a oracle — narrow-integer struct-by-value, the Quartz->C direction.
 *
 * These C functions take and return small structs with sub-8-byte integer
 * fields BY VALUE, compiled by the system C compiler (canonical platform C ABI).
 * The Quartz caller (struct_narrow_call_main.qz) declares them `extern "C"`,
 * builds the structs, calls them, and asserts results — proving Quartz's
 * caller-side coercion (packed-layout load + struct-return reconstruct) matches
 * the real C ABI for narrow fields, where Quartz packs to true C offsets and the
 * SysV classifier coerces a partial trailing eightbyte to a sub-i64 integer.
 */
#include <stdint.h>

struct Vec2i { int32_t x, y; };                 /* 8B  -> i64        */
struct Rgba  { uint8_t r, g, b, a; };           /* 4B  -> i32 (SysV) */
struct I16x2 { int16_t a, b; };                 /* 4B  -> i32 (SysV) */
struct Pixel { uint8_t r, g, b; int64_t v; };   /* 16B -> {i64,i64}  */
struct Tri   { int32_t a, b, c; };              /* 12B -> {i64,i32}  */

/* struct param by value -> scalar */
long v2i_sum(struct Vec2i v)  { return (long)v.x + v.y; }
long rgba_sum(struct Rgba c)  { return (long)c.r + c.g + c.b + c.a; }
long i16_sum(struct I16x2 v)  { return (long)v.a + v.b; }
long pixel_ok(struct Pixel p) { return (p.r == 1 && p.g == 2 && p.b == 3 && p.v == 9000) ? 1 : 0; }
long tri_sum(struct Tri t)    { return (long)t.a + t.b + t.c; }

/* struct return by value */
struct Vec2i make_vec2i(int a, int b)           { struct Vec2i v = {a, b}; return v; }
struct Rgba  make_rgba(int r, int g, int b, int a){ struct Rgba c = {(uint8_t)r,(uint8_t)g,(uint8_t)b,(uint8_t)a}; return c; }
struct Tri   make_tri(int a, int b, int c)      { struct Tri t = {a, b, c}; return t; }

/* struct in -> struct out (both coercions on one call) */
struct Tri   tri_inc(struct Tri t)              { struct Tri r = {t.a+1, t.b+1, t.c+1}; return r; }
