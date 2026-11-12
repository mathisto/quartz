package main

import (
	"fmt"
	"runtime"
	"sync"
)

func main() {
	n := 100000

	// Force GC and measure baseline
	runtime.GC()
	var memBefore runtime.MemStats
	runtime.ReadMemStats(&memBefore)

	// Spawn goroutines that block on a channel (keep them alive)
	blocker := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-blocker
		}()
	}

	// Measure with all goroutines alive
	runtime.GC()
	var memAfter runtime.MemStats
	runtime.ReadMemStats(&memAfter)

	delta := memAfter.Sys - memBefore.Sys
	bytesPerTask := int64(delta) / int64(n)

	// Release all goroutines
	close(blocker)
	wg.Wait()

	fmt.Printf("BENCH:memory_efficiency:bytes_per_task:%d\n", bytesPerTask)
	fmt.Printf("BENCH:memory_efficiency:total_bytes:%d\n", delta)
	fmt.Printf("BENCH:memory_efficiency:goroutines:%d\n", n)
}
