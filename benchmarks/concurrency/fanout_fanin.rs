// Concurrency Benchmark: Fan-out / Fan-in (Tokio)

use std::time::Instant;

fn worker(start: i64, count: i64) -> i64 {
    let mut sum: i64 = 0;
    for i in start..(start + count) {
        sum += i;
    }
    sum
}

#[tokio::main]
async fn main() {
    let n: i64 = 100_000;
    let num_workers: i64 = 8;
    let items_per_worker = n / num_workers;

    let start = Instant::now();

    let mut handles = Vec::new();
    for w in 0..num_workers {
        let base = w * items_per_worker;
        handles.push(tokio::spawn(async move {
            worker(base, items_per_worker)
        }));
    }

    let mut total: i64 = 0;
    for h in handles {
        total += h.await.unwrap();
    }

    let elapsed = start.elapsed().as_nanos() as i64;

    let rate = n * 1_000_000_000 / elapsed;
    println!("BENCH:fanout_fanin:items_per_sec:{}", rate);
    println!("BENCH:fanout_fanin:elapsed_ns:{}", elapsed);
    println!("BENCH:fanout_fanin:total_items:{}", n);
}
