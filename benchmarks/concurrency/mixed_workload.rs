// Concurrency Benchmark: Mixed Workload (Tokio)

use std::time::Instant;

fn compute_task(iters: i64) -> i64 {
    let mut sum: i64 = 0;
    for i in 0..iters {
        sum += i;
    }
    sum
}

#[tokio::main]
async fn main() {
    let num_compute: i64 = 80;
    let num_sleep: i64 = 20;
    let compute_iters: i64 = 10_000;

    let start = Instant::now();

    let mut handles = Vec::new();

    // Compute tasks
    for _ in 0..num_compute {
        handles.push(tokio::spawn(async move {
            compute_task(compute_iters);
        }));
    }

    // Sleep tasks
    for _ in 0..num_sleep {
        handles.push(tokio::spawn(async {
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }));
    }

    for h in handles {
        h.await.unwrap();
    }

    let elapsed = start.elapsed().as_nanos() as i64;
    let completed = num_compute + num_sleep;

    let rate = completed * 1_000_000_000 / elapsed;
    println!("BENCH:mixed_workload:tasks_per_sec:{}", rate);
    println!("BENCH:mixed_workload:elapsed_ns:{}", elapsed);
    println!("BENCH:mixed_workload:completed:{}", completed);
}
