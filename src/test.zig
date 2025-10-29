const std = @import("std");
const freetype = @import("coolfreetype");
const math = @import("math.zig");

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

const PointSIMD = @Vector(2, i64);
const PointArray = [2]i64;
const Batch8Type = @Vector(16, i64);
const Batch4Type = @Vector(8, i64);

const BatchN = 4;
const BatchNType = Batch4Type;

fn ConstructBatch(batch: []PointSIMD) BatchNType {
    std.debug.assert(batch.len == BatchN);
    var flat: BatchNType = undefined;
    for (batch, 0..) |point, i| {
        for (0..@typeInfo(PointSIMD).vector.len) |j| {
            flat[i * @typeInfo(PointSIMD).vector.len + j] = point[j];
        }
    }
    return flat;
}

const RandomVectorGen = struct {
    prng: std.Random.Xoshiro256,
    rand: std.Random,
    fn init() !RandomVectorGen {
        var prng = std.Random.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        });
        const rand = prng.random();
        return .{
            .prng = prng,
            .rand = rand,
        };
    }

    fn getSIMD(self: RandomVectorGen) PointSIMD {
        return .{ self.rand.int(i32), self.rand.int(i32) };
    }
    fn getArray(self: RandomVectorGen) PointArray {
        return .{ self.rand.int(i32), self.rand.int(i32) };
    }
};

fn testSimd() !void {
    const N = 8 * 1000;
    std.debug.print("N={d}\n", .{N});
    const randomGen: RandomVectorGen = try .init();

    var timer: i128 = undefined;
    var time: i128 = undefined;
    // test simd batch
    {
        timer = std.time.nanoTimestamp();

        std.debug.assert(N % BatchN == 0);
        var stack: [N]PointSIMD = undefined;
        var batches: [N / BatchN]BatchNType = undefined;
        for (0..N) |i| {
            stack[i] = randomGen.getSIMD();
            if ((i + 1) % BatchN == 0) {
                const batch_index = @divFloor(i, BatchN);
                batches[batch_index] = ConstructBatch(stack[i + 1 - BatchN .. i + 1]);
            }
        }

        time = std.time.nanoTimestamp() - timer;
        std.debug.print("constructing batch\n  time={d} ns\n", .{time});
        timer = std.time.nanoTimestamp();
        for (0..batches.len - 1) |i| {
            const c = batches[i] + batches[i + 1];
            _ = c;
        }
        time = std.time.nanoTimestamp() - timer;
        std.debug.print("adding batches\n  time={d} ns\n", .{time});
    }
    // test simd
    {
        timer = std.time.nanoTimestamp();
        const a: PointSIMD = randomGen.getSIMD();
        const b: PointSIMD = randomGen.getSIMD();
        for (0..N) |_| {
            const c = a + b;
            _ = c;
        }
        time = std.time.nanoTimestamp() - timer;
        std.debug.print("type={}\n  time={d} ns\n", .{ PointSIMD, time });
    }
    // test array
    {
        timer = std.time.nanoTimestamp();
        const a: PointArray = randomGen.getArray();
        const b: PointArray = randomGen.getArray();
        for (0..N) |_| {
            const c = .{ a[0] + b[0], a[1] + b[1] };
            _ = c;
        }
        time = std.time.nanoTimestamp() - timer;
        std.debug.print("type={}\n  time={d} ns\n", .{ PointArray, time });
    }
}

pub fn main() !void {
    // const lib = try freetype.Library.init();
    // std.debug.print("{}\n", .{lib.version()});
    try testSimd();
}
