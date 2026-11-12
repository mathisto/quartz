/* N-body simulation benchmark
 * Tests struct field access performance and floating-point arithmetic
 * Uses same allocation strategy as Quartz (parallel arrays, integer math)
 * for fair comparison.
 */

#include <stdio.h>

#define NUM_BODIES 5
#define NUM_STEPS 500000
#define SOLAR_MASS 39478
#define DT 1

static long bx[NUM_BODIES], by[NUM_BODIES], bz[NUM_BODIES];
static long bvx[NUM_BODIES], bvy[NUM_BODIES], bvz[NUM_BODIES];
static long bmass[NUM_BODIES];

static long isqrt_l(long n) {
  if (n <= 0)
    return 0;
  long x = n, y = (x + 1) / 2;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2;
  }
  return x;
}

void init_bodies(void) {
  /* Sun */
  bx[0] = 0;
  by[0] = 0;
  bz[0] = 0;
  bvx[0] = 0;
  bvy[0] = 0;
  bvz[0] = 0;
  bmass[0] = SOLAR_MASS;
  /* Jupiter */
  bx[1] = 4841;
  by[1] = -1160;
  bz[1] = -103;
  bvx[1] = 606;
  bvy[1] = 2811;
  bvz[1] = -25;
  bmass[1] = 37694;
  /* Saturn */
  bx[2] = 8343;
  by[2] = 4124;
  bz[2] = -403;
  bvx[2] = -876;
  bvy[2] = 1826;
  bvz[2] = 8;
  bmass[2] = 11286;
  /* Uranus */
  bx[3] = 12894;
  by[3] = -15111;
  bz[3] = -223;
  bvx[3] = 1082;
  bvy[3] = 868;
  bvz[3] = -10;
  bmass[3] = 1723;
  /* Neptune */
  bx[4] = 15379;
  by[4] = -25919;
  bz[4] = 179;
  bvx[4] = 979;
  bvy[4] = 594;
  bvz[4] = -24;
  bmass[4] = 2033;
}

void advance(int n) {
  for (int step = 0; step < n; step++) {
    for (int i = 0; i < NUM_BODIES; i++) {
      long ix = bx[i], iy = by[i], iz = bz[i], im = bmass[i];
      for (int j = i + 1; j < NUM_BODIES; j++) {
        long dx = ix - bx[j];
        long dy = iy - by[j];
        long dz = iz - bz[j];
        long dist_sq = dx * dx + dy * dy + dz * dz;
        if (dist_sq < 1)
          dist_sq = 1;
        long dist = isqrt_l(dist_sq);
        if (dist < 1)
          dist = 1;
        long dist_cubed = dist * dist * dist;
        if (dist_cubed < 1)
          dist_cubed = 1;
        long mag = DT * 1000 / dist_cubed;
        long jm = bmass[j];
        bvx[i] -= dx * jm * mag / 1000000;
        bvy[i] -= dy * jm * mag / 1000000;
        bvz[i] -= dz * jm * mag / 1000000;
        bvx[j] += dx * im * mag / 1000000;
        bvy[j] += dy * im * mag / 1000000;
        bvz[j] += dz * im * mag / 1000000;
      }
    }
    for (int i = 0; i < NUM_BODIES; i++) {
      bx[i] += bvx[i] * DT / 1000;
      by[i] += bvy[i] * DT / 1000;
      bz[i] += bvz[i] * DT / 1000;
    }
  }
}

long energy(void) {
  long e = 0;
  for (int i = 0; i < NUM_BODIES; i++) {
    long vx = bvx[i], vy = bvy[i], vz = bvz[i];
    e += bmass[i] * (vx * vx + vy * vy + vz * vz) / (2 * 1000000);
    for (int j = i + 1; j < NUM_BODIES; j++) {
      long dx = bx[i] - bx[j];
      long dy = by[i] - by[j];
      long dz = bz[i] - bz[j];
      long dist = isqrt_l(dx * dx + dy * dy + dz * dz);
      if (dist < 1)
        dist = 1;
      e -= bmass[i] * bmass[j] / (dist * 1000);
    }
  }
  return e;
}

int main(void) {
  init_bodies();
  long e0 = energy();
  printf("Energy before: %ld\n", e0);
  advance(NUM_STEPS);
  long e1 = energy();
  printf("Energy after:  %ld\n", e1);
  return 0;
}
