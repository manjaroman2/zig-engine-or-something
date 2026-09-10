const ttf = @import("ttf.zig");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try ttf.main(init);
    return;
}
