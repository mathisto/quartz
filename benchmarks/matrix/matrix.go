package main

import "fmt"

func main() {
	n := 200
	a := make([]int64, 0, n*n)
	b := make([]int64, 0, n*n)
	c := make([]int64, 0, n*n)
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			a = append(a, int64(i+j))
			b = append(b, int64(i*j))
			c = append(c, 0)
		}
	}
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			var sum int64 = 0
			for k := 0; k < n; k++ {
				sum += a[i*n+k] * b[k*n+j]
			}
			c[i*n+j] = sum
		}
	}
	fmt.Println(c[0])
}
