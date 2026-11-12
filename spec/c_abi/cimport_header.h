/* B.11b @cImport oracle header (MEMORY_MODEL_V3.md §13.6a, P3.6a).
 *
 * Exercised end-to-end: the Quartz driver does `cimport "cimport_header.h"`,
 * which shells out to clang's AST dump, translates these declarations into
 * `@value @repr(C)` structs + `extern "C"` defs, and the generated bindings ride
 * the C-ABI classifier. cimport_lib.c is the real C impl. Covers: scalar,
 * narrow-int struct return (CPoint = {int,int}), F32 struct in+out (CVec2f),
 * F64+F32 scalar mix, narrow scalar widths, and enums (named + typedef'd, with
 * explicit + implicit enumerator values) passed as int-rank arguments.
 */
typedef struct CPoint { int x; int y; } CPoint;
struct CVec2f { float fx; float fy; };

enum CStatus { CST_OK, CST_WARN = 5, CST_ERR };
typedef enum { CM_LO, CM_HI = 10 } CMode;

typedef unsigned int CU32;
typedef CU32 CHandle;   /* alias-of-alias: CHandle -> CU32 -> unsigned int */

#define CI_MAX 64
#define CI_FLAG 0x10
#define CI_SCALE 3
#define CI_LABEL "ci"
#define CI_SQUARE(x) ((x) * (x))

int ci_addi(int a, int b);
CPoint ci_make_point(int x, int y);
struct CVec2f ci_vscale(struct CVec2f v, float k);
double ci_dscale(double v, float k);
unsigned long ci_counter(unsigned char flag, short s);
int ci_status_code(enum CStatus s);
int ci_mode_base(CMode m);
CU32 ci_alias_sum(CU32 a, CHandle b);

/* P3.6c-ptrfields: a struct with a POINTER field, passed/returned by value. The
 * pointer is an 8-byte INTEGER eightbyte (== long), so CSpan = {ptr, int} crosses
 * the boundary exactly like {long, int}. ci_span_data hands Quartz a real C
 * pointer; ci_make_span builds the struct (pointer in RETURN); ci_span_sum
 * dereferences it (pointer in PARAM) — round-tripping a live pointer by value. */
typedef struct CSpan { int *data; int len; } CSpan;
int *ci_span_data(void);
CSpan ci_make_span(int *p, int n);
int ci_span_sum(CSpan s);
