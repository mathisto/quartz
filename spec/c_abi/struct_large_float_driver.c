/* B.10 P3.4-ii-b oracle — >16B F32 struct-by-value, the C->Quartz direction.
 * C builds >16B structs with F32 fields, passes them BY VALUE (byval) into Quartz
 * `extern "C"` functions, and reads F32 structs back BY VALUE (sret). Linked
 * against the Quartz callee (struct_large_float_callee.qz); asserts the numeric
 * results match. */
#include <stdio.h>
#include <stdint.h>

struct F6    { float a, b, c, d, e, f; };
struct FMix6 { int32_t a, b, c; float d, e, f; };
struct FW    { float a, b; int64_t c, d; };

extern long qz_f6_sum4(struct F6);
extern long qz_fmix6_chk(struct FMix6);
extern long qz_fw_chk(struct FW);
extern struct F6 qz_mk_f6(int);
extern struct FMix6 qz_mk_fmix6(int, int);

int run_tests(void) {
  struct F6    v = {1.5f, 2.5f, 0.5f, 0.75f, 0.25f, 1.0f};
  struct FMix6 m = {1, 2, 3, 1.5f, 2.5f, 3.5f};
  struct FW    w = {1.5f, 2.5f, 100, 200};

  long s   = qz_f6_sum4(v);     /* 26 */
  long mok = qz_fmix6_chk(m);   /* 1  */
  long wok = qz_fw_chk(w);      /* 1  */

  struct F6    rf = qz_mk_f6(3);          /* {3,4,5,6,7,8}        */
  struct FMix6 rm = qz_mk_fmix6(20, 5);   /* {20,21,22,5,6,7}     */

  int rok = (rf.a == 3.0f) && (rf.f == 8.0f)
         && (rm.a == 20) && (rm.c == 22) && (rm.d == 5.0f) && (rm.f == 7.0f);
  int all = (s == 26) && (mok == 1) && (wok == 1) && rok;

  printf("f6=%ld fmix6=%ld fw=%ld ret_ok=%d ALL=%d\n", s, mok, wok, rok, all);
  return all ? 0 : 1;
}
