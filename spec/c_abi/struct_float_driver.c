/* B.10 P3.4b oracle — F32 struct-by-value, the C->Quartz direction.
 * C builds structs with F32 fields, passes them BY VALUE into Quartz `extern "C"`
 * functions, and reads F32 structs back BY VALUE. Linked against the Quartz callee
 * (struct_float_callee.qz); asserts the numeric results match. */
#include <stdio.h>
#include <stdint.h>

struct Vec2f { float x, y; };
struct Vec3f { float x, y, z; };
struct Vec4f { float x, y, z, w; };
struct Mixf  { int32_t a; float b; };
struct FMix  { float a; int64_t b; };

extern long qz_v2f_sum4(struct Vec2f);
extern long qz_v3f_sum4(struct Vec3f);
extern long qz_v4f_sum4(struct Vec4f);
extern long qz_mixf_chk(struct Mixf);
extern long qz_fmix_chk(struct FMix);
extern struct Vec2f qz_make_v2f(int, int);
extern struct Mixf  qz_make_mixf(int, int);
extern struct FMix  qz_make_fmix(int, long);

int run_tests(void) {
  struct Vec2f v2 = {1.5f, 2.5f};
  struct Vec3f v3 = {1.5f, 2.5f, 0.5f};
  struct Vec4f v4 = {1.5f, 2.5f, 0.5f, 0.75f};
  struct Mixf  m  = {7, 1.5f};
  struct FMix  fm = {2.5f, 9000};

  long s2  = qz_v2f_sum4(v2);   /* 16 */
  long s3  = qz_v3f_sum4(v3);   /* 18 */
  long s4  = qz_v4f_sum4(v4);   /* 21 */
  long mok = qz_mixf_chk(m);    /* 1  */
  long fok = qz_fmix_chk(fm);   /* 1  */

  struct Vec2f rv = qz_make_v2f(3, 5);       /* {3.0, 5.0}   */
  struct Mixf  rm = qz_make_mixf(42, 9);     /* {42, 9.0}    */
  struct FMix  rf = qz_make_fmix(4, 12345);  /* {4.0, 12345} */

  int rok = (rv.x == 3.0f) && (rv.y == 5.0f)
         && (rm.a == 42)   && (rm.b == 9.0f)
         && (rf.a == 4.0f) && (rf.b == 12345);
  int all = (s2 == 16) && (s3 == 18) && (s4 == 21) && (mok == 1) && (fok == 1) && rok;

  printf("v2f=%ld v3f=%ld v4f=%ld mixf=%ld fmix=%ld ret_ok=%d ALL=%d\n",
         s2, s3, s4, mok, fok, rok, all);
  return all ? 0 : 1;
}
