package main

import (
	"fmt"
	"sync"
	"time"
)

func worker(start, count int) int {
	sum := 0
	for i := start; i < start+count; i++ {
		sum += i
	}
	return sum
}

func main() {
	n := 100000
	numWorkers := 8
	itemsPerWorker := n / numWorkers

	start := time.Now()

	var wg sync.WaitGroup
	results := make([]int, numWorkers)

	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		w := w
		go func() {
			defer wg.Done()
			results[w] = worker(w*itemsPerWorker, itemsPerWorker)
		}()
	}

	wg.Wait()
	total := 0
	for _, r := range results {
		total += r
	}

	elapsed := time.Since(start).Nanoseconds()

	rate := int64(n) * 1000000000 / elapsed
	fmt.Printf("BENCH:fanout_fanin:items_per_sec:%d\n", rate)
	fmt.Printf("BENCH:fanout_fanin:elapsed_ns:%d\n", elapsed)
	fmt.Printf("BENCH:fanout_fanin:total_items:%d\n", n)
}
