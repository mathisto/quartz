enum Tree {
    Leaf,
    Node(Box<Tree>, Box<Tree>),
}

fn tree_build(depth: i32) -> Tree {
    if depth == 0 {
        Tree::Leaf
    } else {
        Tree::Node(
            Box::new(tree_build(depth - 1)),
            Box::new(tree_build(depth - 1)),
        )
    }
}

fn tree_check(t: &Tree) -> i64 {
    match t {
        Tree::Leaf => 1,
        Tree::Node(left, right) => 1 + tree_check(left) + tree_check(right),
    }
}

fn main() {
    let max_depth = 15;
    let mut total: i64 = 0;
    for d in 0..max_depth {
        let tree = tree_build(d);
        total += tree_check(&tree);
    }
    println!("{}", total);
}
