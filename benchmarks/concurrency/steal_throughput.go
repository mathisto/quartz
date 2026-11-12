package main

import (
	"fmt"
	"sync"
	"time"
)

func main() {
	n := 100000
	var wg sync.WaitGroup

	start := time.Now()

	// Flood goroutines from main — runtime scheduler distributes to P's
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// Minimal work — just signal completion
		}()
	}

	wg.Wait()
	elapsed := time.Since(start).Nanoseconds()

	rate := int64(n) * 1000000000 / elapsed
	fmt.Printf("BENCH:steal_throughput:tasks_per_sec:%d\n", rate)
	fmt.Printf("BENCH:steal_throughput:elapsed_ns:%d\n", elapsed)
}
