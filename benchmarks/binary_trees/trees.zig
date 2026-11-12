const std = @import("std");

const Node = struct {
    left: ?*Node,
    right: ?*Node,
};

fn treeBuild(allocator: std.mem.Allocator, depth: i32) !*Node {
    const n = try allocator.create(Node);
    if (depth == 0) {
        n.* = .{ .left = null, .right = null };
    } else {
        n.left = try treeBuild(allocator, depth - 1);
        n.right = try treeBuild(allocator, depth - 1);
    }
    return n;
}

fn treeCheck(n: ?*const Node) i64 {
    const node = n orelse return 0;
    if (node.left == null) return 1;
    return 1 + treeCheck(node.left) + treeCheck(node.right);
}

pub fn main() !void {
    const max_depth: i32 = 15;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var total: i64 = 0;
    var d: i32 = 0;
    while (d < max_depth) : (d += 1) {
        _ = arena.reset(.retain_capacity);
        const tree = try treeBuild(arena.allocator(), d);
        total += treeCheck(tree);
    }
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("{}\n", .{total});
}
