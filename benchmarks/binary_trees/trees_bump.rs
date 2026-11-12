/// Binary tree benchmark using bump allocator (fair comparison)
///
/// Same algorithm as trees.rs but uses a simple bump allocator
/// instead of per-node Box allocation. Apples-to-apples comparison
/// with trees_bump.qz and trees_bump.c.

struct Bump {
    buf: Vec<u8>,
    offset: usize,
}

impl Bump {
    fn new(capacity: usize) -> Self {
        Bump {
            buf: vec![0u8; capacity],
            offset: 0,
        }
    }

    fn alloc(&mut self) -> *mut Node {
        let align = std::mem::align_of::<Node>();
        let size = std::mem::size_of::<Node>();
        // Align offset
        self.offset = (self.offset + align - 1) & !(align - 1);
        let ptr = unsafe { self.buf.as_mut_ptr().add(self.offset) as *mut Node };
        self.offset += size;
        ptr
    }

    fn reset(&mut self) {
        self.offset = 0;
    }
}

struct Node {
    left: *const Node,
    right: *const Node,
}

fn tree_build(bump: &mut Bump, depth: i32) -> *const Node {
    let n = bump.alloc();
    if depth == 0 {
        unsafe {
            (*n).left = std::ptr::null();
            (*n).right = std::ptr::null();
        }
    } else {
        unsafe {
            (*n).left = tree_build(bump, depth - 1);
            (*n).right = tree_build(bump, depth - 1);
        }
    }
    n
}

fn tree_check(n: *const Node) -> i64 {
    if n.is_null() {
        return 0;
    }
    unsafe {
        if (*n).left.is_null() {
            return 1;
        }
        1 + tree_check((*n).left) + tree_check((*n).right)
    }
}

fn main() {
    let max_depth = 15;
    let mut total: i64 = 0;
    let mut bump = Bump::new(2_097_152); // 2MB — same as Quartz
    for d in 0..max_depth {
        bump.reset();
        let tree = tree_build(&mut bump, d);
        total += tree_check(tree);
    }
    println!("{}", total);
}
