/* B.10 P3 regression — `@repr(C)` struct-by-value WITHOUT `@value` (the C side).
 *
 * Real C, system C ABI. The Quartz caller (reprc_only_main.qz) declares these
 * `extern "C"`, building/reading structs marked `@repr(C)` ONLY (no `@value`).
 * Pt {int,int} is one INTEGER eightbyte; V2f {float,float} is an HFA / `<2 x
 * float>`. Proves the classifier fires for the bare-`@repr(C)` spelling. */
#include <stdint.h>

struct Pt  { int x; int y; };       /* 8B, one INTEGER eightbyte */
struct V2f { float x, y; };         /* 8B, HFA (2 x float)        */

/* struct param by value -> scalar */
long pt_sum(struct Pt p)   { return p.x + p.y; }                  /* 3+4=7 / 10+20=30 */
long v2f_sum4(struct V2f v) { return (long)((v.x + v.y) * 4.0f); } /* (1.5+2.5)*4=16   */

/* struct return by value (C builds it, Quartz reads its fields). a4/b4 are
 * quarter-units so a4/4.0f is exact. */
struct Pt  make_pt(int x, int y)    { struct Pt p = { x, y }; return p; }
struct V2f make_v2f(int a4, int b4) { struct V2f v = { a4 / 4.0f, b4 / 4.0f }; return v; }
