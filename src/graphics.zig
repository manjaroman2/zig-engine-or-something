const std = @import("std");

pub const PositionColorVertex = packed struct {
    position: @Vector(3, f32),
    color: @Vector(4, u8),
};

pub const PositionTextureVertex = packed struct {
    position: @Vector(3, f32),
    uv: @Vector(2, f32),
};

pub const PositionTextureColorVertex = packed struct {
    position: @Vector(3, f32),
    uv: @Vector(2, f32),
    color: @Vector(4, u8),
    _pad: u32 = 0,
};

pub const PositionTextureColorLayeredVertex = packed struct {
    position: @Vector(3, f32),
    uv: @Vector(2, f32),
    color: @Vector(4, u8),
    layer: i32,
};

pub fn Mesh(vertex_type: type) type {
    return struct {
        vertices: std.ArrayList(vertex_type),
        indices: std.ArrayList(u16),
    };
}
