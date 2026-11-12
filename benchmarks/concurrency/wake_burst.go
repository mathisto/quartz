package main

import (
	"fmt"
	"runtime"
	"sync"
	"time"
)

func main() {
	n := 10000
	inboxes := make([]chan struct{}, n)
	var wg sync.WaitGroup

	// Spawn workers, each blocks on its inbox
	for i := 0; i < n; i++ {
		inboxes[i] = make(chan struct{}, 1)
		wg.Add(1)
		go func(inbox chan struct{}) {
			defer wg.Done()
			<-inbox
		}(inboxes[i])
	}

	// Let all goroutines park
	runtime.Gosched()
	runtime.Gosched()
	runtime.Gosched()

	// Burst-send to wake all
	start := time.Now()
	for i := 0; i < n; i++ {
		inboxes[i] <- struct{}{}
	}
	wg.Wait()
	elapsed := time.Since(start).Nanoseconds()

	rate := int64(n) * 1000000000 / elapsed
	fmt.Printf("BENCH:wake_burst:wakes_per_sec:%d\n", rate)
	fmt.Printf("BENCH:wake_burst:elapsed_ns:%d\n", elapsed)
}
