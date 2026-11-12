/* B.11b @cImport oracle — real C implementation, compiled by the system C
 * compiler (canonical platform C ABI). Linked against the Quartz driver whose
 * bindings were auto-generated from cimport_header.h by @cImport. */
#include "cimport_header.h"
int ci_addi(int a, int b) { return a + b; }
CPoint ci_make_point(int x, int y) { CPoint p = {x, y}; return p; }
struct CVec2f ci_vscale(struct CVec2f v, float k) { struct CVec2f r = {v.fx * k, v.fy * k}; return r; }
double ci_dscale(double v, float k) { return v * (double)k; }
unsigned long ci_counter(unsigned char flag, short s) { return (unsigned long)flag + (unsigned long)s; }
int ci_status_code(enum CStatus s) { return (int)s + 100; }
int ci_mode_base(CMode m) { return (int)m * 2; }
CU32 ci_alias_sum(CU32 a, CHandle b) { return a + b; }

static int ci_span_arr[3] = {10, 20, 30};
int *ci_span_data(void) { return ci_span_arr; }
CSpan ci_make_span(int *p, int n) { CSpan s = {p, n}; return s; }
int ci_span_sum(CSpan s) {
  int t = 0;
  for (int i = 0; i < s.len; i++) t += s.data[i];
  return t;
}
