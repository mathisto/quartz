fn main() {
    let n: usize = 200;
    let mut a = vec![0i64; n * n];
    let mut b = vec![0i64; n * n];
    let mut c = vec![0i64; n * n];
    for i in 0..n {
        for j in 0..n {
            a[i * n + j] = (i + j) as i64;
            b[i * n + j] = (i * j) as i64;
        }
    }
    for i in 0..n {
        for j in 0..n {
            let mut sum: i64 = 0;
            for k in 0..n {
                sum += a[i * n + k] * b[k * n + j];
            }
            c[i * n + j] = sum;
        }
    }
    println!("{}", c[0]);
}
