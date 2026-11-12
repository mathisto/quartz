/* B.10 P3.4b oracle — F32 struct-by-value, the Quartz->C direction.
 *
 * These C functions take and return small structs with F32 (`float`) fields BY
 * VALUE, compiled by the system C compiler (canonical platform C ABI). An F32 is
 * stored 8-byte double-bits-in-i64 internally by Quartz but C packs it as a
 * 4-byte `float` at a true offset, so Quartz must boundary-REPACK each F32 field
 * (fptrunc/fpext) rather than alias memory (§13.5). The Quartz caller
 * (struct_float_call_main.qz) declares these `extern "C"`, builds the structs,
 * calls them, and asserts results — proving the F32 coerce both directions.
 *
 * SysV: Vec2f->`<2 x float>`, Vec3f->`{<2 x float>,float}`, Vec4f->`{<2 x
 * float>,<2 x float>}`, Mixf(int+float, one eightbyte)->`i64`, FMix->`{float,i64}`.
 * AArch64: Vec{2,3,4}f are HFAs (`[N x float]`); Mixf->`i64`; FMix->`[2 x i64]`.
 */
#include <stdint.h>

struct Vec2f { float x, y; };           /* 8B  */
struct Vec3f { float x, y, z; };        /* 12B */
struct Vec4f { float x, y, z, w; };     /* 16B */
struct Mixf  { int32_t a; float b; };   /* 8B  (int+float share one eightbyte) */
struct FMix  { float a; int64_t b; };   /* 16B (float alone in eb0) */

/* param by value -> scalar. Returns the sum scaled by 4 (all inputs are exact
 * multiples of 0.25, so the product is an exact integer) to avoid float compares
 * across the language boundary. */
long v2f_sum4(struct Vec2f v) { return (long)((v.x + v.y) * 4.0f); }              /* (1.5+2.5)*4=16 */
long v3f_sum4(struct Vec3f v) { return (long)((v.x + v.y + v.z) * 4.0f); }        /* 4.5*4=18 */
long v4f_sum4(struct Vec4f v) { return (long)((v.x + v.y + v.z + v.w) * 4.0f); }  /* 5.25*4=21 */
long mixf_chk(struct Mixf m)  { return (m.a == 7 && m.b == 1.5f) ? 1 : 0; }
long fmix_chk(struct FMix m)  { return (m.a == 2.5f && m.b == 9000) ? 1 : 0; }

/* return by value (C builds the struct, Quartz reads its fields). a4/b4 are
 * quarter-units so a4/4.0f is exact. */
struct Vec2f make_v2f(int a4, int b4)        { struct Vec2f v = { a4 / 4.0f, b4 / 4.0f }; return v; }
struct Mixf  make_mixf(int a, int b4)        { struct Mixf m = { a, b4 / 4.0f }; return m; }
struct FMix  make_fmix(int a4, long b)       { struct FMix m = { a4 / 4.0f, b }; return m; }
