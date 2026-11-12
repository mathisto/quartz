const std = @import("std");

pub fn main() !void {
    const n: usize = 10_000_000;
    var sieve: [n]u8 = undefined;
    @memset(&sieve, 1);
    sieve[0] = 0;
    sieve[1] = 0;
    var i: usize = 2;
    while (i * i < n) : (i += 1) {
        if (sieve[i] == 1) {
            var j: usize = i * i;
            while (j < n) : (j += i) {
                sieve[j] = 0;
            }
        }
    }
    var count: usize = 0;
    for (sieve) |s| {
        if (s == 1) count += 1;
    }
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("{}\n", .{count});
}
