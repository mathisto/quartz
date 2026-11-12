const std = @import("std");

pub fn main() !void {
    const n: usize = 200;
    const allocator = std.heap.page_allocator;
    const a = try allocator.alloc(i64, n * n);
    defer allocator.free(a);
    const b = try allocator.alloc(i64, n * n);
    defer allocator.free(b);
    const c = try allocator.alloc(i64, n * n);
    defer allocator.free(c);
    for (0..n) |i| {
        for (0..n) |j| {
            a[i * n + j] = @as(i64, @intCast(i + j));
            b[i * n + j] = @as(i64, @intCast(i * j));
            c[i * n + j] = 0;
        }
    }
    for (0..n) |i| {
        for (0..n) |j| {
            var sum: i64 = 0;
            for (0..n) |k| {
                sum += a[i * n + k] * b[k * n + j];
            }
            c[i * n + j] = sum;
        }
    }
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("{}\n", .{c[0]});
}
