// Concurrency Benchmark: Contention — Atomic Increment (Tokio)

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Instant;

#[tokio::main]
async fn main() {
    let num_tasks: i64 = 8;
    let total_iters: i64 = 1_000_000;
    let iters_per_task = total_iters / num_tasks;

    let counter = Arc::new(AtomicI64::new(0));

    let start = Instant::now();

    let mut handles = Vec::new();
    for _ in 0..num_tasks {
        let counter = counter.clone();
        handles.push(tokio::spawn(async move {
            for _ in 0..iters_per_task {
                counter.fetch_add(1, Ordering::Relaxed);
            }
        }));
    }

    for h in handles {
        h.await.unwrap();
    }

    let elapsed = start.elapsed().as_nanos() as i64;
    let total = counter.load(Ordering::Relaxed);

    let rate = total * 1_000_000_000 / elapsed;
    println!("BENCH:contention:ops_per_sec:{}", rate);
    println!("BENCH:contention:elapsed_ns:{}", elapsed);
    println!("BENCH:contention:total_ops:{}", total);
}
