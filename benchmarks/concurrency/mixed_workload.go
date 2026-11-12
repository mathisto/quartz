package main

import (
	"fmt"
	"sync"
	"time"
)

func computeTask(iters int) int {
	sum := 0
	for i := 0; i < iters; i++ {
		sum += i
	}
	return sum
}

func main() {
	numCompute := 80
	numSleep := 20
	computeIters := 10000
	sleepDur := time.Millisecond

	start := time.Now()

	var wg sync.WaitGroup

	// Compute tasks
	for i := 0; i < numCompute; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			computeTask(computeIters)
		}()
	}

	// Sleep tasks
	for i := 0; i < numSleep; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			time.Sleep(sleepDur)
		}()
	}

	wg.Wait()
	elapsed := time.Since(start).Nanoseconds()
	completed := numCompute + numSleep

	rate := int64(completed) * 1000000000 / elapsed
	fmt.Printf("BENCH:mixed_workload:tasks_per_sec:%d\n", rate)
	fmt.Printf("BENCH:mixed_workload:elapsed_ns:%d\n", elapsed)
	fmt.Printf("BENCH:mixed_workload:completed:%d\n", completed)
}
