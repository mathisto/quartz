package main

import (
	"fmt"
	"sync"
	"time"
)

func spawnAndWait(n int) int64 {
	var wg sync.WaitGroup
	start := time.Now()
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
		}()
	}
	wg.Wait()
	elapsed := time.Since(start).Nanoseconds()
	return int64(n) * 1000000000 / elapsed
}

func main() {
	scales := []int{1000, 10000, 100000, 1000000}
	rates := make([]int64, 4)

	for i, n := range scales {
		rates[i] = spawnAndWait(n)
	}

	// Scaling efficiency = rate_1M / rate_1K * 1000
	efficiency := int64(0)
	if rates[0] > 0 {
		efficiency = rates[3] * 1000 / rates[0]
	}

	fmt.Printf("BENCH:scalability_curve:efficiency_x1000:%d\n", efficiency)
	fmt.Printf("BENCH:scalability_curve:rate_1k:%d\n", rates[0])
	fmt.Printf("BENCH:scalability_curve:rate_10k:%d\n", rates[1])
	fmt.Printf("BENCH:scalability_curve:rate_100k:%d\n", rates[2])
	fmt.Printf("BENCH:scalability_curve:rate_1m:%d\n", rates[3])
}
