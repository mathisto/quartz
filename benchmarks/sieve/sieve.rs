fn main() {
    let n: usize = 10_000_000;
    let mut sieve = vec![true; n];
    sieve[0] = false;
    sieve[1] = false;
    let mut i = 2;
    while i * i < n {
        if sieve[i] {
            let mut j = i * i;
            while j < n {
                sieve[j] = false;
                j += i;
            }
        }
        i += 1;
    }
    let count = sieve.iter().filter(|&&x| x).count();
    println!("{}", count);
}
