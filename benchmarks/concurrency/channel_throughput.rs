// Concurrency Benchmark: Channel Throughput (Tokio)

use std::time::Instant;
use tokio::sync::mpsc;

#[tokio::main]
async fn main() {
    let n: i64 = 10_000;
    let (tx, mut rx) = mpsc::channel::<i64>(1024);

    let start = Instant::now();

    // Producer
    let prod = tokio::spawn(async move {
        for i in 0..n {
            tx.send(i).await.unwrap();
        }
    });

    // Consumer
    let cons = tokio::spawn(async move {
        let mut sum: i64 = 0;
        while let Some(v) = rx.recv().await {
            sum += v;
        }
        sum
    });

    prod.await.unwrap();
    let _sum = cons.await.unwrap();
    let elapsed = start.elapsed().as_nanos() as i64;

    let rate = n * 1_000_000_000 / elapsed;
    println!("BENCH:channel_throughput:msgs_per_sec:{}", rate);
    println!("BENCH:channel_throughput:elapsed_ns:{}", elapsed);
    println!("BENCH:channel_throughput:total_msgs:{}", n);
}
