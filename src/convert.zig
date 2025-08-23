const std = @import("std");

pub fn convertIntsToU16s(allocator: std.mem.Allocator, input: []const c_int) ![]u16 {
    var result = try allocator.alloc(u16, input.len);
    for (input, 0..) |val, i| {
        if (val < 0 or val > std.math.maxInt(u16)) {
            return error.ValueOutOfRange;
        }
        result[i] = @intCast(val);
    }
    return result;
}
