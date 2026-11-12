fn main() {
    let mut s = String::new();
    for _ in 0..100_000 {
        s.push('x');
    }
    println!("{}", s.len());
}
