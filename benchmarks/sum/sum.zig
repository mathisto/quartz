const std = @import("std");

pub fn main() !void {
    var total: i64 = 0;
    var i: i64 = 0;
    while (i < 100_000_000) : (i += 1) {
        total += i;
    }
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("{}\n", .{total});
}
