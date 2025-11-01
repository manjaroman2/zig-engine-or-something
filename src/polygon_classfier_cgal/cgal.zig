const std = @import("std");

const Polygon_with_holes_2 = opaque {};

// C API functions
extern fn classify_contours_from_doubles(
    x_coords: [*]const f64,
    y_coords: [*]const f64,
    contour_sizes: [*]const usize,
    num_contours: usize,
    out_size: *usize,
) [*]*Polygon_with_holes_2;

extern fn get_outer_boundary_size_simple(pwh: *const Polygon_with_holes_2) usize;
extern fn get_outer_boundary_point_simple(pwh: *const Polygon_with_holes_2, idx: usize, x: *f64, y: *f64) void;
extern fn get_num_holes_simple(pwh: *const Polygon_with_holes_2) usize;
extern fn get_hole_size_simple(pwh: *const Polygon_with_holes_2, hole_idx: usize) usize;
extern fn get_hole_point_simple(pwh: *const Polygon_with_holes_2, hole_idx: usize, point_idx: usize, x: *f64, y: *f64) void;
extern fn free_domains_simple(domains: [*]*Polygon_with_holes_2, size: usize) void;

// Triangulation C API
const TriangulationHandle = opaque {};

extern fn create_polygon_with_holes(outer_x: [*]const f64, outer_y: [*]const f64, outer_size: usize, holes_x: [*]const [*]const f64, holes_y: [*]const [*]const f64, hole_sizes: [*]const usize, num_holes: usize) ?*Polygon_with_holes_2;

extern fn free_single_polygon(pwh: *Polygon_with_holes_2) void;

extern fn triangulate_polygon_with_holes(pwh: *const Polygon_with_holes_2) ?*TriangulationHandle;
extern fn get_triangulation_num_triangles(handle: *TriangulationHandle) usize;
extern fn get_triangle_vertices(handle: *TriangulationHandle, idx: usize, x0: *f64, y0: *f64, x1: *f64, y1: *f64, x2: *f64, y2: *f64) void;
extern fn free_triangulation(handle: *TriangulationHandle) void;

// Nice Zig API
pub const Point = [2]f64;

pub const Polygon = struct {
    points: []const Point,
};

pub const PolygonWithHoles = struct {
    outer: []Point,
    holes: [][]Point,

    pub fn deinit(self: *PolygonWithHoles, allocator: std.mem.Allocator) void {
        allocator.free(self.outer);
        for (self.holes) |hole| {
            allocator.free(hole);
        }
        allocator.free(self.holes);
    }
};

pub const Triangle = struct {
    v0: Point,
    v1: Point,
    v2: Point,
};

pub const Triangulation = struct {
    triangles: []Triangle,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Triangulation) void {
        self.allocator.free(self.triangles);
    }
};

pub fn classifyContours(allocator: std.mem.Allocator, contours: []const []const Point) ![]PolygonWithHoles {
    if (contours.len == 0) return &[_]PolygonWithHoles{};

    // Validate contours
    for (contours, 0..) |contour, i| {
        if (contour.len < 3) {
            std.debug.print("Warning: Contour {} has only {} points (need at least 3)\n", .{ i, contour.len });
            return error.InvalidContour;
        }

        // Check for NaN or infinite values
        for (contour, 0..) |point, j| {
            if (!std.math.isFinite(point[0]) or !std.math.isFinite(point[1])) {
                std.debug.print("Warning: Contour {} point {} has invalid coordinates: ({d}, {d})\n", .{ i, j, point[0], point[1] });
                return error.InvalidPoint;
            }
        }
    }

    // Flatten all points into separate x and y arrays
    var total_points: usize = 0;
    for (contours) |contour| {
        total_points += contour.len;
    }

    var x_coords = try allocator.alloc(f64, total_points);
    defer allocator.free(x_coords);

    var y_coords = try allocator.alloc(f64, total_points);
    defer allocator.free(y_coords);

    var contour_sizes = try allocator.alloc(usize, contours.len);
    defer allocator.free(contour_sizes);

    var idx: usize = 0;
    for (contours, 0..) |contour, i| {
        contour_sizes[i] = contour.len;
        for (contour) |point| {
            x_coords[idx] = point[0];
            y_coords[idx] = point[1];
            idx += 1;
        }
    }

    // Call C++ function
    var out_size: usize = 0;
    const domains = classify_contours_from_doubles(
        x_coords.ptr,
        y_coords.ptr,
        contour_sizes.ptr,
        contours.len,
        &out_size,
    );

    // Check if C++ returned no results (error case)
    if (out_size == 0) {
        std.debug.print("CGAL returned no results or encountered an error\n", .{});
        return &[_]PolygonWithHoles{};
    }

    // Convert results to Zig structures
    var result = try allocator.alloc(PolygonWithHoles, out_size);
    errdefer allocator.free(result);

    for (0..out_size) |i| {
        const pwh = domains[i];

        // Get outer boundary
        const outer_size = get_outer_boundary_size_simple(pwh);
        var outer = try allocator.alloc(Point, outer_size);
        errdefer allocator.free(outer);

        for (0..outer_size) |j| {
            var x: f64 = undefined;
            var y: f64 = undefined;
            get_outer_boundary_point_simple(pwh, j, &x, &y);
            outer[j] = .{ x, y };
        }

        // Get holes
        const num_holes = get_num_holes_simple(pwh);
        var holes = try allocator.alloc([]Point, num_holes);
        errdefer allocator.free(holes);

        for (0..num_holes) |h| {
            const hole_size = get_hole_size_simple(pwh, h);
            var hole_points = try allocator.alloc(Point, hole_size);
            errdefer allocator.free(hole_points);

            for (0..hole_size) |p| {
                var x: f64 = undefined;
                var y: f64 = undefined;
                get_hole_point_simple(pwh, h, p, &x, &y);
                hole_points[p] = .{ x, y };
            }

            holes[h] = hole_points;
        }

        result[i] = PolygonWithHoles{
            .outer = outer,
            .holes = holes,
        };
    }

    // Free C++ memory
    free_domains_simple(domains, out_size);

    return result;
}

pub fn freePolygons(allocator: std.mem.Allocator, polygons: []PolygonWithHoles) void {
    for (polygons) |*polygon| {
        polygon.deinit(allocator);
    }
    allocator.free(polygons);
}

// Triangulation API - directly construct polygon from outer + holes
pub fn triangulatePolygon(allocator: std.mem.Allocator, polygon: *const PolygonWithHoles) !Triangulation {
    // Prepare outer boundary
    var outer_x = try allocator.alloc(f64, polygon.outer.len);
    defer allocator.free(outer_x);
    var outer_y = try allocator.alloc(f64, polygon.outer.len);
    defer allocator.free(outer_y);

    for (polygon.outer, 0..) |point, i| {
        outer_x[i] = point[0];
        outer_y[i] = point[1];
    }

    // Prepare holes
    var holes_x = try allocator.alloc([*]const f64, polygon.holes.len);
    defer allocator.free(holes_x);
    var holes_y = try allocator.alloc([*]const f64, polygon.holes.len);
    defer allocator.free(holes_y);
    var hole_sizes = try allocator.alloc(usize, polygon.holes.len);
    defer allocator.free(hole_sizes);

    var hole_x_arrays = try allocator.alloc([]f64, polygon.holes.len);
    defer {
        for (hole_x_arrays) |arr| allocator.free(arr);
        allocator.free(hole_x_arrays);
    }
    var hole_y_arrays = try allocator.alloc([]f64, polygon.holes.len);
    defer {
        for (hole_y_arrays) |arr| allocator.free(arr);
        allocator.free(hole_y_arrays);
    }

    for (polygon.holes, 0..) |hole, i| {
        hole_sizes[i] = hole.len;

        var hx = try allocator.alloc(f64, hole.len);
        var hy = try allocator.alloc(f64, hole.len);

        for (hole, 0..) |point, j| {
            hx[j] = point[0];
            hy[j] = point[1];
        }

        holes_x[i] = hx.ptr;
        holes_y[i] = hy.ptr;
        hole_x_arrays[i] = hx;
        hole_y_arrays[i] = hy;
    }

    // Create C++ polygon with holes
    const pwh = create_polygon_with_holes(outer_x.ptr, outer_y.ptr, polygon.outer.len, holes_x.ptr, holes_y.ptr, hole_sizes.ptr, polygon.holes.len) orelse {
        return error.FailedToCreatePolygon;
    };
    defer free_single_polygon(pwh);

    // Triangulate
    const handle = triangulate_polygon_with_holes(pwh) orelse {
        std.debug.print("Failed to triangulate polygon\n", .{});
        return error.TriangulationFailed;
    };
    defer free_triangulation(handle);

    const num_triangles = get_triangulation_num_triangles(handle);
    // std.debug.print("Got {} triangles\n", .{num_triangles});

    var triangles = try allocator.alloc(Triangle, num_triangles);
    errdefer allocator.free(triangles);

    for (0..num_triangles) |i| {
        var x0: f64 = undefined;
        var y0: f64 = undefined;
        var x1: f64 = undefined;
        var y1: f64 = undefined;
        var x2: f64 = undefined;
        var y2: f64 = undefined;

        get_triangle_vertices(handle, i, &x0, &y0, &x1, &y1, &x2, &y2);

        triangles[i] = Triangle{
            .v0 = .{ x0, y0 },
            .v1 = .{ x1, y1 },
            .v2 = .{ x2, y2 },
        };
    }

    return Triangulation{
        .triangles = triangles,
        .allocator = allocator,
    };
}
