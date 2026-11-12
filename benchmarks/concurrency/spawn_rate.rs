// Concurrency Benchmark: Task Spawn Rate (Tokio)
// cargo add tokio --features full

use std::time::Instant;

#[tokio::main]
async fn main() {
    let n: i64 = 100_000;
    let start = Instant::now();

    let mut handles = Vec::with_capacity(n as usize);
    for _ in 0..n {
        handles.push(tokio::spawn(async { 0i64 }));
    }

    for h in handles {
        let _ = h.await;
    }

    let elapsed = start.elapsed().as_nanos() as i64;
    let rate = n * 1_000_000_000 / elapsed;
    println!("BENCH:spawn_rate:tasks_per_sec:{}", rate);
    println!("BENCH:spawn_rate:elapsed_ns:{}", elapsed);
    println!("BENCH:spawn_rate:total_tasks:{}", n);
}
