#include <stdio.h>
struct Pair { long a, b; };
struct V2  { double x, y; };
struct Mix { long i; double d; };
extern long qz_pair_sum(struct Pair);
extern long qz_pair_diff(struct Pair);
extern long qz_v2_ok(struct V2);
extern long qz_mix_ok(struct Mix);
/* P3.1b — struct returns by value */
extern struct Pair qz_make_pair(long, long);
extern struct V2   qz_make_v2(double, double);
extern struct Mix  qz_make_mix(long, double);
extern double      qz_scale2(double);
int run_tests(void){
  struct Pair p = {10, 3};
  struct V2  v = {3.0, 4.0};
  struct Mix m = {42, 2.5};
  long sum = qz_pair_sum(p), diff = qz_pair_diff(p);
  long vok = qz_v2_ok(v), mok = qz_mix_ok(m);
  /* returns */
  struct Pair rp = qz_make_pair(5, 9);
  struct V2   rv = qz_make_v2(1.5, 2.5);
  struct Mix  rm = qz_make_mix(7, 8.5);
  double sc = qz_scale2(2.5);
  int rok = (rp.a==5) && (rp.b==9)
         && (rv.x==1.5) && (rv.y==2.5)
         && (rm.i==7) && (rm.d==8.5)
         && (sc==5.0);
  int all = (sum==13) && (diff==7) && (vok==1) && (mok==1) && rok;
  printf("pair_sum=%ld pair_diff=%ld v2_ok=%ld mix_ok=%ld ret_ok=%d ALL=%d\n",
         sum, diff, vok, mok, rok, all);
  return all ? 0 : 1;
}
