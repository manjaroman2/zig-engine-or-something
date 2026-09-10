const std = @import("std");

pub const CPoint = extern struct { x: f64, y: f64 };

pub const ReturnData = extern struct {
    indices: [*]Index,
    indices_count: usize,
    indices_per_polygon: [*]usize,
    vertices: [*]Vertex,
    vertices_count: usize,
    vertices_per_polygon: [*]usize,
    polygon_count: usize,
};

pub const Triangle = [3]i32;
pub const Index = usize;
pub const Vertex = struct { x: i32, y: i32 };
pub const Mesh = struct {
    mem: []u8,
    vertices: []Vertex,
    indices: []Index,

    pub fn alloc(allocator: std.mem.Allocator, n_vertices: usize, n_indices: usize) !Mesh {
        const index_offset = std.mem.alignForward(usize, n_vertices * @sizeOf(Vertex), @alignOf(Index));
        const total_bytes = index_offset + n_indices * @sizeOf(Index);

        const mem = try allocator.alignedAlloc(u8, comptime .fromByteUnits(@max(
            @alignOf(Index),
            @alignOf(Vertex),
        )), total_bytes);

        const vertices: []Vertex = @as(
            [*]Vertex,
            @ptrCast(@alignCast(mem.ptr)),
        )[0..n_vertices];

        const indices: []Index = @as(
            [*]Index,
            @ptrCast(@alignCast(mem.ptr + index_offset)),
        )[0..n_indices];

        return .{
            .mem = mem,
            .vertices = vertices,
            .indices = indices,
        };
    }

    pub fn free(self: *const Mesh, allocator: std.mem.Allocator) void {
        defer allocator.free(self.mem);
    }
};

const Context = opaque {};

extern fn context_create(
    contour_points: [*]const CPoint,
    contour_lengths: [*]const usize,
    contour_count: usize,
) ?*Context;
extern fn context_destroy(ctx: *Context) void;

extern fn triangulate_polygons(ctx: *Context, out: *ReturnData, max_indices: usize, max_vertices: usize, max_polygons: usize) void;

pub fn triangulate(alloc: std.mem.Allocator, contours: []const []const CPoint) ![]Mesh {
    var total: usize = 0;
    for (contours) |c| total += c.len;

    const flat = try alloc.alloc(CPoint, total);
    defer alloc.free(flat);
    const lengths = try alloc.alloc(usize, contours.len);
    defer alloc.free(lengths);

    var off: usize = 0;
    for (contours, 0..) |c, i| {
        lengths[i] = c.len;
        @memcpy(flat[off .. off + c.len], c);
        off += c.len;
    }

    const ctx = context_create(flat.ptr, lengths.ptr, contours.len) orelse return error.OutOfMemoryError;

    var max_indices: usize = 6;
    var max_vertices: usize = 3;
    var max_polygons: usize = 1;
    var indices = try alloc.alloc(Index, max_indices);
    var vertices = try alloc.alloc(Vertex, max_vertices);
    var indices_per_polygon = try alloc.alloc(usize, max_polygons);
    var vertices_per_polygon = try alloc.alloc(usize, max_polygons);
    @memset(indices_per_polygon, 0);
    @memset(vertices_per_polygon, 0);

    var out: ReturnData = .{
        .indices_count = 0,
        .indices = indices.ptr,
        .indices_per_polygon = indices_per_polygon.ptr,

        .vertices_count = 0,
        .vertices = vertices.ptr,
        .vertices_per_polygon = vertices_per_polygon.ptr,

        .polygon_count = 0,
    };

    triangulate_polygons(ctx, &out, max_indices, max_vertices, max_polygons);

    while (out.indices_count > max_indices or out.vertices_count > max_vertices or out.polygon_count > max_polygons) {
        if (out.indices_count > max_indices) {
            alloc.free(indices);
            max_indices = out.indices_count;
            indices = try alloc.alloc(Index, max_indices);
            out.indices = indices.ptr;
        }
        if (out.vertices_count > max_vertices) {
            alloc.free(vertices);
            max_vertices = out.vertices_count;
            vertices = try alloc.alloc(Vertex, max_vertices);
            out.vertices = vertices.ptr;
        }
        if (out.polygon_count > max_polygons) {
            alloc.free(indices_per_polygon);
            alloc.free(vertices_per_polygon);
            max_polygons = out.polygon_count;
            indices_per_polygon = try alloc.alloc(usize, max_polygons);
            vertices_per_polygon = try alloc.alloc(usize, max_polygons);
            out.indices_per_polygon = indices_per_polygon.ptr;
            out.vertices_per_polygon = vertices_per_polygon.ptr;
            @memset(indices_per_polygon, 0);
            @memset(vertices_per_polygon, 0);
        }
        triangulate_polygons(ctx, &out, max_indices, max_vertices, max_polygons);
    }

    std.debug.print("b\n", .{});
    defer alloc.free(indices);
    defer alloc.free(vertices);
    defer alloc.free(indices_per_polygon);
    defer alloc.free(vertices_per_polygon);

    const polygons = try alloc.alloc(Mesh, out.polygon_count);
    var index_offs: usize = 0;
    var vertex_offs: usize = 0;
    for (0..out.polygon_count) |pi| {
        const polygon_index_count = indices_per_polygon[pi];
        const polygon_vertex_count = vertices_per_polygon[pi];
        const mesh = try Mesh.alloc(alloc, polygon_vertex_count, polygon_index_count);
        polygons[pi] = mesh;

        @memcpy(mesh.indices, indices[index_offs..index_offs+polygon_index_count]);
        @memcpy(mesh.vertices, vertices[vertex_offs..vertex_offs+polygon_vertex_count]);
        index_offs += polygon_index_count;
        vertex_offs += polygon_vertex_count;
    }
    return polygons;
}
