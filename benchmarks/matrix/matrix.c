#include <stdio.h>
#include <stdlib.h>

int main(void) {
    int n = 200;
    long *a = malloc(n * n * sizeof(long));
    long *b = malloc(n * n * sizeof(long));
    long *c = calloc(n * n, sizeof(long));
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            a[i * n + j] = i + j;
            b[i * n + j] = i * j;
        }
    }
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            long sum = 0;
            for (int k = 0; k < n; k++) {
                sum += a[i * n + k] * b[k * n + j];
            }
            c[i * n + j] = sum;
        }
    }
    printf("%ld\n", c[0]);
    free(a);
    free(b);
    free(c);
    return 0;
}
