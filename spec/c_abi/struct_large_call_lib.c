/* B.10 P3.3 oracle — Quartz->C direction, LARGE (>16B) structs.
 *
 * These C functions take and return structs LARGER than 16 bytes by value,
 * compiled by the system C compiler so they use the canonical platform C ABI.
 * On both SysV-AMD64 and AArch64-AAPCS a >16B non-HFA struct is passed
 * INDIRECTLY: a `byval` pointer for a param, a hidden `sret` pointer for a
 * return. The Quartz driver (struct_large_call_main.qz) declares them
 * `extern "C"`, builds the structs, calls them, and asserts the results —
 * proving Quartz's caller-side byval/sret emission matches the real C ABI.
 *
 * Big6 (6 doubles) is deliberately NOT a Homogeneous Float Aggregate on
 * AArch64 (HFAs cap at 4 members), so it exercises the all-double indirect path.
 */
struct P3   { long a, b, c; };            /* 24B */
struct Quad { long a, b, c, d; };         /* 32B */
struct Big6 { double a, b, c, d, e, f; }; /* 48B — >4 members ⇒ not an HFA */
struct M3   { long i; double d; long k; };/* 24B, mixed int/float */

/* byval param -> scalar */
long c_p3_sum(struct P3 p)    { return p.a + p.b + p.c; }
long c_quad_sum(struct Quad q){ return q.a + q.b + q.c + q.d; }
long c_big6_ok(struct Big6 b) { return (b.a + b.b + b.c + b.d + b.e + b.f == 21.0) ? 1 : 0; }
long c_m3_ok(struct M3 m)     { return (m.i == 1 && m.d == 2.5 && m.k == 3) ? 1 : 0; }

/* sret return */
struct P3   c_make_p3(long a, long b, long c)            { struct P3 p = {a, b, c}; return p; }
struct Big6 c_make_big6(double base)                     { struct Big6 b = {base, base+1, base+2, base+3, base+4, base+5}; return b; }
struct M3   c_make_m3(long i, double d, long k)          { struct M3 m = {i, d, k}; return m; }

/* byval-in + sret-out on one call */
struct P3   c_p3_rot(struct P3 p)                        { struct P3 r = {p.c, p.a, p.b}; return r; }
