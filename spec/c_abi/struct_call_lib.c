/* B.10 P3.1c oracle — the Quartz->C direction (mirror of struct_params_*).
 *
 * These C functions take and return small int/double structs BY VALUE, compiled
 * by the system C compiler so they use the canonical platform C ABI. The Quartz
 * driver (struct_call_main.qz) declares them `extern "C"`, builds the structs,
 * calls them, and asserts the results — proving Quartz's caller-side coercion
 * (arg load + struct-return reconstruct) matches the real C ABI on this target.
 */
struct Pair { long a, b; };
struct V2   { double x, y; };
struct Mix  { long i; double d; };

/* struct param by value -> scalar */
long c_pair_sum(struct Pair p)  { return p.a + p.b; }
long c_pair_diff(struct Pair p) { return p.a - p.b; }
long c_v2_is34(struct V2 v)     { return (v.x == 3.0 && v.y == 4.0) ? 1 : 0; }
long c_mix_ok(struct Mix m)     { return (m.i == 42 && m.d == 2.5) ? 1 : 0; }

/* struct return by value */
struct Pair c_make_pair(long a, long b)   { struct Pair p = {a, b}; return p; }
struct V2   c_make_v2(double x, double y) { struct V2 v = {x, y}; return v; }
struct Mix  c_make_mix(long i, double d)  { struct Mix m = {i, d}; return m; }

/* struct in -> struct out (both coercions on one call) */
struct Pair c_pair_swap(struct Pair p)    { struct Pair r = {p.b, p.a}; return r; }
struct V2   c_v2_scale(struct V2 v, double k) { struct V2 r = {v.x * k, v.y * k}; return r; }
