const std = @import("std");
const freetype = @import("coolfreetype");

// fn test123() !void {
//     const N = 10_000_000;
//
//     // Generate some test data
//     const a: Point = .{ 3, 7 };
//     const b: Point = .{ 5, 2 };
//     const c: Point = .{ 2, 3 };
//     const q: Point = .{ 6, -10 };
//     const tmp1: @Vector(6, i64) = .{
//         a[0], a[1],
//         b[0], b[1],
//         c[0], c[1],
//     };
//
//     var result: i64 = 0;
//     var timer: i128 = undefined;
//     var time: i128 = 0;
//
//     result = 0;
//     timer = std.time.nanoTimestamp();
//     for (0..N) |_| result += fastTest(a, b, c, q);
//     time = std.time.nanoTimestamp() - timer;
//     std.debug.print("fast result = {d}:\ntime = {d} ns\n", .{ result, time });
//
//     result = 0;
//     timer = std.time.nanoTimestamp();
//     for (0..N) |_| result += fastTest2(tmp1, q);
//     time = std.time.nanoTimestamp() - timer;
//     std.debug.print("fast2 result = {d}:\ntime = {d} ns\n", .{ result, time });
//
//     result = 0;
//     timer = std.time.nanoTimestamp();
//     for (0..N) |_| result += normalTest(a, b, c, q);
//     time = std.time.nanoTimestamp() - timer;
//     std.debug.print("normal result = {d}:\ntime = {d} ns\n", .{ result, time });
// }

pub fn main() !void {
    const lib = try freetype.Library.init();
    std.debug.print("{}\n", .{lib.version()});
}
