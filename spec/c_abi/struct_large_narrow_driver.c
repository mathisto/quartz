/* B.10 P3.4-ii-a oracle — >16B NARROW-packed struct-by-value, the C->Quartz
 * direction. C builds >16B structs with sub-8-byte int fields, passes them BY
 * VALUE (byval) into Quartz `extern "C"` functions, and reads narrow structs
 * back BY VALUE (sret). Linked against the Quartz callee
 * (struct_large_narrow_callee.qz); asserts the numeric results match. */
#include <stdio.h>
#include <stdint.h>

struct N6 { int32_t a, b, c, d, e, f; };
struct NW { int64_t a; int32_t b, c, d; };

extern long qz_n6_sum(struct N6);
extern long qz_nw_sum(struct NW);
extern struct N6 qz_make_n6(int);
extern struct NW qz_make_nw(long, int, int, int);

int run_tests(void) {
  struct N6 n = {1, 2, 3, 4, 5, 6};
  struct NW w = {1000, 7, 8, 9};

  long n6sum = qz_n6_sum(n);   /* 21   */
  long nwsum = qz_nw_sum(w);   /* 1024 */

  struct N6 rn = qz_make_n6(10);             /* {10,11,12,13,14,15} */
  struct NW rw = qz_make_nw(5000, 1, 2, 3);  /* {5000,1,2,3}        */

  int rok = (rn.a == 10) && (rn.b == 11) && (rn.f == 15)
         && (rw.a == 5000) && (rw.b == 1) && (rw.d == 3);
  int all = (n6sum == 21) && (nwsum == 1024) && rok;

  printf("n6_sum=%ld nw_sum=%ld ret_ok=%d ALL=%d\n", n6sum, nwsum, rok, all);
  return all ? 0 : 1;
}
