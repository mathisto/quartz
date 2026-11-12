#include <stdio.h>
#include <stdlib.h>

#define NUM_POINTS 100000
#define ITERATIONS 50

typedef struct {
    long x, y, z;
} Point3D;

typedef struct {
    long min_x, min_y, min_z;
    long max_x, max_y, max_z;
} BoundingBox;

static Point3D point_new(long x, long y, long z) {
    return (Point3D){x, y, z};
}

static long point_dist_sq(Point3D a, Point3D b) {
    long dx = a.x - b.x;
    long dy = a.y - b.y;
    long dz = a.z - b.z;
    return dx * dx + dy * dy + dz * dz;
}

static Point3D point_add(Point3D a, Point3D b) {
    return (Point3D){a.x + b.x, a.y + b.y, a.z + b.z};
}

static BoundingBox bbox_new(void) {
    return (BoundingBox){999999999, 999999999, 999999999,
                         -999999999, -999999999, -999999999};
}

static BoundingBox bbox_include(BoundingBox bb, Point3D p) {
    if (p.x < bb.min_x) bb.min_x = p.x;
    if (p.y < bb.min_y) bb.min_y = p.y;
    if (p.z < bb.min_z) bb.min_z = p.z;
    if (p.x > bb.max_x) bb.max_x = p.x;
    if (p.y > bb.max_y) bb.max_y = p.y;
    if (p.z > bb.max_z) bb.max_z = p.z;
    return bb;
}

static long bbox_volume(BoundingBox bb) {
    return (bb.max_x - bb.min_x) * (bb.max_y - bb.min_y) * (bb.max_z - bb.min_z);
}

int main(void) {
    Point3D *points = malloc(NUM_POINTS * sizeof(Point3D));
    if (!points) return 1;

    /* Allocate points with deterministic pseudo-random coordinates */
    long seed = 42;
    for (int i = 0; i < NUM_POINTS; i++) {
        seed = (seed * 1103515245 + 12345) % 2147483648L;
        long x = seed % 10000;
        seed = (seed * 1103515245 + 12345) % 2147483648L;
        long y = seed % 10000;
        seed = (seed * 1103515245 + 12345) % 2147483648L;
        long z = seed % 10000;
        points[i] = point_new(x, y, z);
    }

    long total_dist = 0;
    long total_vol = 0;

    for (int iter = 0; iter < ITERATIONS; iter++) {
        /* Sum pairwise distances (strided to keep O(n)) */
        long dist_sum = 0;
        for (int i = 0; i < NUM_POINTS - 1; i++) {
            dist_sum += point_dist_sq(points[i], points[i + 1]);
        }
        total_dist += dist_sum;

        /* Compute bounding box over all points */
        BoundingBox bb = bbox_new();
        for (int i = 0; i < NUM_POINTS; i++) {
            bb = bbox_include(bb, points[i]);
        }
        total_vol += bbox_volume(bb);

        /* Transform points: shift + scale */
        Point3D offset = point_new(iter, iter * 2, iter * 3);
        for (int i = 0; i < NUM_POINTS; i++) {
            points[i] = point_add(points[i], offset);
        }
    }

    printf("dist_sum: %ld\n", total_dist);
    printf("vol_sum:  %ld\n", total_vol);
    free(points);
    return 0;
}
