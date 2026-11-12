/* B.10 P3.3 oracle — the C->Quartz direction for LARGE (>16B) structs.
 *
 * Quartz `main` calls this C `run_tests`, which builds structs and calls the
 * Quartz `extern "C"` functions (struct_large_callee.qz) that take/return them
 * by value. Compiled by the system C compiler, so the call sites use the
 * canonical platform C ABI for >16B aggregates (indirect param, sret return).
 * The round-trip avoids a `main` clash in the single linked binary. A green run
 * proves Quartz's callee-side signature + sret terminator match real C.
 */
#include <stdio.h>

struct P3   { long a, b, c; };
struct Big6 { double a, b, c, d, e, f; };
struct M3   { long i; double d; long k; };

extern long qz_p3_sum(struct P3 p);
extern long qz_big6_ok(struct Big6 b);
extern long qz_m3_ok(struct M3 m);
extern struct P3 qz_make_p3(long a, long b, long c);
extern struct M3 qz_make_m3(long i, double d, long k);
extern struct P3 qz_p3_rot(struct P3 p);

int run_tests(void) {
  struct P3   p  = {10, 20, 30};
  struct Big6 b6 = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0};
  struct M3   m  = {1, 2.5, 3};

  long p3sum  = qz_p3_sum(p);
  long big6ok = qz_big6_ok(b6);
  long m3ok   = qz_m3_ok(m);

  struct P3 rp  = qz_make_p3(7, 8, 9);
  struct M3 rm  = qz_make_m3(5, 6.5, 11);
  struct P3 rot = qz_p3_rot((struct P3){1, 2, 3});

  int ret_ok = (rp.a == 7 && rp.b == 8 && rp.c == 9 &&
                rm.i == 5 && rm.d == 6.5 && rm.k == 11 &&
                rot.a == 3 && rot.b == 1 && rot.c == 2) ? 1 : 0;

  int all = (p3sum == 60 && big6ok == 1 && m3ok == 1 && ret_ok == 1) ? 1 : 0;

  printf("p3_sum=%ld big6_ok=%ld m3_ok=%ld ret_ok=%d ALL=%d\n",
         p3sum, big6ok, m3ok, ret_ok, all);
  return all == 1 ? 0 : 1;
}
