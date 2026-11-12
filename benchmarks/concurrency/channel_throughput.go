package main

import (
	"fmt"
	"time"
)

func main() {
	n := 10000
	ch := make(chan int, 1024)
	done := make(chan int64)

	start := time.Now()

	// Producer
	go func() {
		for i := 0; i < n; i++ {
			ch <- i
		}
		close(ch)
	}()

	// Consumer
	go func() {
		var sum int64
		for v := range ch {
			sum += int64(v)
		}
		done <- sum
	}()

	<-done
	elapsed := time.Since(start).Nanoseconds()

	rate := int64(n) * 1000000000 / elapsed
	fmt.Printf("BENCH:channel_throughput:msgs_per_sec:%d\n", rate)
	fmt.Printf("BENCH:channel_throughput:elapsed_ns:%d\n", elapsed)
	fmt.Printf("BENCH:channel_throughput:total_msgs:%d\n", n)
}
