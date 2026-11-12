/* B.10 P3.4a oracle — narrow-integer struct-by-value, the C->Quartz direction.
 * C builds structs with sub-8-byte int fields, passes them BY VALUE into Quartz
 * `extern "C"` functions, and reads narrow structs back BY VALUE. Linked against
 * the Quartz callee (struct_narrow_callee.qz); asserts the numeric results match.
 */
#include <stdio.h>
#include <stdint.h>

struct Vec2i { int32_t x, y; };
struct Rgba  { uint8_t r, g, b, a; };
struct Pixel { uint8_t r, g, b; int64_t v; };
struct Tri   { int32_t a, b, c; };

extern long qz_v2i_sum(struct Vec2i);
extern long qz_rgba_sum(struct Rgba);
extern long qz_tri_sum(struct Tri);
extern long qz_pixel_ok(struct Pixel);
extern struct Vec2i qz_make_vec2i(int, int);
extern struct Rgba  qz_make_rgba(int, int, int, int);
extern struct Tri   qz_make_tri(int, int, int);

int run_tests(void) {
  struct Vec2i v = {10, 3};
  struct Rgba  c = {1, 2, 3, 4};
  struct Pixel p = {1, 2, 3, 9000};
  struct Tri   t = {5, 6, 7};

  long vs = qz_v2i_sum(v);
  long cs = qz_rgba_sum(c);
  long ts = qz_tri_sum(t);
  long pok = qz_pixel_ok(p);

  struct Vec2i rv = qz_make_vec2i(42, 8);
  struct Rgba  rc = qz_make_rgba(11, 22, 33, 44);
  struct Tri   rt = qz_make_tri(1, 2, 3);

  int rok = (rv.x == 42) && (rv.y == 8)
         && (rc.r == 11) && (rc.g == 22) && (rc.b == 33) && (rc.a == 44)
         && (rt.a == 1) && (rt.b == 2) && (rt.c == 3);
  int all = (vs == 13) && (cs == 10) && (ts == 18) && (pok == 1) && rok;

  printf("v2i=%ld rgba=%ld tri=%ld pixel=%ld ret_ok=%d ALL=%d\n",
         vs, cs, ts, pok, rok, all);
  return all ? 0 : 1;
}
