#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    int n = 10000000;
    char *sieve = malloc(n);
    memset(sieve, 1, n);
    sieve[0] = 0;
    sieve[1] = 0;
    for (int i = 2; (long)i * i < n; i++) {
        if (sieve[i]) {
            for (int j = i * i; j < n; j += i) {
                sieve[j] = 0;
            }
        }
    }
    int count = 0;
    for (int i = 0; i < n; i++) {
        if (sieve[i]) count++;
    }
    printf("%d\n", count);
    free(sieve);
    return 0;
}
