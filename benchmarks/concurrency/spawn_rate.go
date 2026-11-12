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

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
		}()
	}

	wg.Wait()
	elapsed := time.Since(start).Nanoseconds()

	rate := int64(n) * 1000000000 / elapsed
	fmt.Printf("BENCH:spawn_rate:tasks_per_sec:%d\n", rate)
	fmt.Printf("BENCH:spawn_rate:elapsed_ns:%d\n", elapsed)
	fmt.Printf("BENCH:spawn_rate:total_tasks:%d\n", n)
}
