const std = @import("std");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(gpa);
    for (0..100_000) |_| {
        try list.append(gpa, 'x');
    }
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("{}\n", .{list.items.len});
}
