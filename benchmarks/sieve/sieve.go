package main

import "fmt"

func main() {
	n := 10000000
	sieve := make([]byte, n)
	for i := range sieve {
		sieve[i] = 1
	}
	sieve[0] = 0
	sieve[1] = 0
	for i := 2; int64(i)*int64(i) < int64(n); i++ {
		if sieve[i] == 1 {
			for j := i * i; j < n; j += i {
				sieve[j] = 0
			}
		}
	}
	count := 0
	for i := 0; i < n; i++ {
		if sieve[i] == 1 {
			count++
		}
	}
	fmt.Println(count)
}
