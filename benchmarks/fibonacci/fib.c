#include <stdio.h>

long fib(long n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

int main(void) {
    long result = fib(40);
    printf("%ld\n", result);
    return 0;
}
