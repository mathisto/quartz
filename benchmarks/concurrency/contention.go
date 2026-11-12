package main

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	numTasks := 8
	totalIters := 1000000
	itersPerTask := totalIters / numTasks

	var counter int64

	start := time.Now()

	var wg sync.WaitGroup
	for t := 0; t < numTasks; t++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < itersPerTask; i++ {
				atomic.AddInt64(&counter, 1)
			}
		}()
	}

	wg.Wait()
	elapsed := time.Since(start).Nanoseconds()

	total := atomic.LoadInt64(&counter)
	rate := total * 1000000000 / elapsed
	fmt.Printf("BENCH:contention:ops_per_sec:%d\n", rate)
	fmt.Printf("BENCH:contention:elapsed_ns:%d\n", elapsed)
	fmt.Printf("BENCH:contention:total_ops:%d\n", total)
}
