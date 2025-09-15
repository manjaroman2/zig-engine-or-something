const std = @import("std");
const graphics = @import("graphics.zig");
const math = @import("math.zig");
const PositionTextureColorLayeredVertex = graphics.PositionTextureColorLayeredVertex;

const freetype = @import("coolfreetype");
const harfbuzz = @import("coolharfbuzz");

fn print_version(library: freetype.Library) !void {
    const version = library.version();
    std.log.info("FreeType version: {}.{}.{}\n", .{ version.major, version.minor, version.patch });
}

const ZERO_U64: u64 = 0;
const ONE_U64: u64 = 1;

fn glyph_write_bmp(glyph: freetype.GlyphSlot, outfile: []const u8) !void {
    const file = try std.fs.cwd().createFile(outfile, .{
        .truncate = true,
    });
    defer file.close();
    var buf: [32]u8 = undefined;
    const buffer_header = try std.fmt.bufPrint(&buf, "P5\n{} {}\n255\n", .{ glyph.bitmap().width(), glyph.bitmap().rows() });
    try file.writeAll(buffer_header);
    const buffer: []const u8 = glyph.bitmap().buffer().?[0 .. glyph.bitmap().width() * glyph.bitmap().rows()];
    try file.writeAll(buffer);
    std.debug.print("glyph -> {s}\n", .{outfile});
}

const Point = @Vector(2, i64);
const Point_MIN = .{ std.math.minInt(i64), std.math.minInt(i64) };
const Point_MAX = .{ std.math.maxInt(i64), std.math.maxInt(i64) };
inline fn PointEqual(a: Point, b: Point) bool {
    return a[0] == b[0] and a[1] == b[1];
}

inline fn PointZero(a: Point) bool {
    return a[0] == 0 and a[0] == 0;
}

const Printer = struct {
    allocator: std.mem.Allocator,
    allocated: std.ArrayList(PrinterElement),

    const PrinterElement = struct {
        allocatedString: []const u8,
        children: usize,
    };

    fn init(allocator: std.mem.Allocator) !Printer {
        return .{
            .allocated = try std.ArrayList(PrinterElement).initCapacity(allocator, 1),
            .allocator = allocator,
        };
    }

    fn allocPrintWithChildren(self: *Printer, children: usize, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const a = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.allocated.append(self.allocator, .{
            .allocatedString = a,
            .children = children,
        });
        return a;
    }

    fn free_last(self: *Printer) void {
        if (self.allocated.pop()) |last| {
            self.allocator.free(last.allocatedString);
            for (0..last.children) |_| self.free_last();
        }
    }

    fn deinit(self: Printer) void {
        while (self.allocated.items.len > 0) self.free_last();
        self.allocated.deinit(self.allocator);
    }

    fn point(self: *Printer, p: Point) ![]const u8 {
        return self.allocPrintWithChildren(0, "({},{})", .{ p[0], p[1] });
    }

    fn edge(self: *Printer, e: *const Edge) ![]const u8 {
        return self.allocPrintWithChildren(2, "{s},{s}", .{ try self.point(e.lp), try self.point(e.rp) });
    }

    fn contour(self: *Printer, c: *const Contour) ![]const u8 {
        var geogebra_domain_print = try self.allocator.alloc([]const u8, c.edgesCount);

        for (c.edges, 0..) |e, i| geogebra_domain_print[i] = try self.edge(&e);

        const result = try std.mem.join(self.allocator, ",\n", geogebra_domain_print);

        for (geogebra_domain_print) |_| self.free_last();
        self.allocator.free(geogebra_domain_print);

        try self.allocated.append(self.allocator, .{
            .allocatedString = result,
            .children = 0,
        });
        return result;
    }
};

const PointF = @Vector(2, f32);
const PointF_MIN = .{ std.math.floatMin(f32), std.math.floatMin(f32) };
const PointF_MAX = .{ std.math.floatMax(f32), std.math.floatMax(f32) };

fn PointF_fromInt(int: anytype) PointF {
    return @as(PointF, @floatFromInt(int));
}

const WindingOrder = enum {
    COUNTERCLOCKWISE,
    CLOCKWISE,
};

inline fn isInHalfPlane(windingOrder: WindingOrder, a: Point, b: Point) bool {
    return switch (windingOrder) {
        .COUNTERCLOCKWISE => isInHalfplaneCCW(a, b),
        .CLOCKWISE => isInHalfplaneCW(a, b),
    };
}

inline fn delauneyCondition(windingOrder: WindingOrder, a: Point, b: Point, c: Point, q: Point) bool {
    return switch (windingOrder) {
        .COUNTERCLOCKWISE => delauneyConditionCCW(a, b, c, q),
        .CLOCKWISE => delauneyConditionCW(a, b, c, q),
    };
}

pub const Contour = struct {
    edges: []Edge,
    edgesCount: usize,
    windingOrder: WindingOrder = undefined,
    max: Point = Point_MIN,
    min: Point = Point_MAX,
    maxEdge: *Edge = undefined,
    minEdge: *Edge = undefined,
    segments: std.ArrayList(Segment) = undefined,
};

pub const Segment = union(enum) {
    line: Line,
    conic: ConicBezier,
    cubic: CubicBezier,

    pub inline fn points(self: Segment) []const Point {
        return switch (self) {
            .line => |s| &[_]Point{ s.start, s.end },
            .conic => |s| &[_]Point{ s.start, s.control, s.end },
            .cubic => |s| &[_]Point{ s.start, s.control_1, s.control_2, s.end },
        };
    }
};

pub const Line = packed struct {
    start: Point,
    end: Point,
};

pub const ConicBezier = packed struct {
    start: Point,
    end: Point,
    control: Point,
};

pub const CubicBezier = packed struct {
    start: Point,
    end: Point,
    control_1: Point,
    control_2: Point,
};

fn interpolate(pointA: Point, pointB: Point) Point {
    return @divFloor(pointA + pointB, @as(Point, @splat(2)));
}

pub const errors = error{
    BadTag,
    BadContour,
};

// Constructs bezier curves from outline data.
fn bezier(allocator: std.mem.Allocator, outline: freetype.Outline) ![]Contour {
    var contours = try allocator.alloc(Contour, outline.numContours());
    var contour_offset: usize = 0;
    for (outline.contours()[0..outline.numContours()], 0..) |contour_end_index, contourIdx| {
        //  So, imagine a tree
        //  ON=FT_CURVE_TAG_ON, CO=FT_CURVE_TAG_CONIC, CU=FT_CURVE_TAG_CUBIC
        //  tree_layer
        //  0           ┌────────────> ON
        //              │ ┌─────────────┼───────────────────────────────────┐
        //  1           ├─ON(Line)      CO                                  CU
        //              │               │                                   │
        //              │ ┌─────────────┼───────┐                 ┌─────────┼──────────┐
        //  2           ├─ON(Conic)     CO    CU(🗲)             ON(🗲)     CO(🗲)     CU
        //              │               │                                              │
        //              │ ┌─────────────┼───────┐                                      │
        //  3           ├─ON(2Conic)    CO(🗲) CU(🗲)                        ┌─────────┼──────────┐
        //              │                                                   ON(Cubic)  CO(🗲)    CU(🗲)
        //              └────────────────────────────────────────────────────┘

        const contour_length = @as(usize, @intCast(contour_end_index)) - contour_offset + 1;
        const tag_slice = outline.tags()[contour_offset .. contour_offset + contour_length];
        const point_slice = outline.points()[contour_offset .. contour_offset + contour_length];
        contour_offset += contour_length;

        var segments = try std.ArrayList(Segment).initCapacity(allocator, contour_length * 2);
        var last: u8 = undefined;
        var tree_layer: u8 = 0;

        var tags = try std.ArrayList(u8).initCapacity(allocator, contour_length + 2);
        defer tags.deinit(allocator);
        var points = try std.ArrayList(@Vector(2, i64)).initCapacity(
            allocator,
            contour_length + 2,
        );
        defer points.deinit(allocator);

        // ref: https://freetype.org/freetype2/docs/glyphs/glyphs-6.html
        // The first point in a contour can be a conic ‘off’ point itself;
        // in that case, use the last point of the contour as the contour's starting point.
        // If the last point is a conic ‘off’ point itself, start the contour with the virtual ‘on’ point
        // between the last and first point of the contour.
        if (tag_slice[0] & 0x03 == freetype.c.FT_CURVE_TAG_CONIC) {
            switch (tag_slice[contour_length - 1] & 0x03) {
                freetype.c.FT_CURVE_TAG_ON => {
                    tree_layer = 1;
                    last = freetype.c.FT_CURVE_TAG_CONIC;
                },
                freetype.c.FT_CURVE_TAG_CONIC => {
                    try points.append(allocator, interpolate(
                        Point{
                            @intCast(point_slice[0].x),
                            @intCast(point_slice[0].y),
                        },
                        Point{
                            @intCast(point_slice[contour_length - 1].x),
                            @intCast(point_slice[contour_length - 1].y),
                        },
                    ));
                    // insert extra ON tag
                    try tags.append(allocator, freetype.c.FT_CURVE_TAG_ON);
                },
                else => {
                    return errors.BadTag;
                },
            }
        }

        // ref: https://freetype.org/freetype2/docs/glyphs/glyphs-6.html
        // The last point in a contour uses the first as an end point to create a closed contour.
        // For example, if the last two points of a contour were an ‘on’ point followed by a conic
        // ‘off’ point, the first point in the contour would be used as final point to create an
        // ‘on’ – ‘off’ – ‘on’ sequence as described above.
        try tags.appendSlice(allocator, tag_slice);
        try tags.append(allocator, tag_slice[0]);
        for (point_slice) |p| {
            try points.append(allocator, .{ p.x, p.y });
        }
        try points.append(allocator, .{ point_slice[0].x, point_slice[0].y });

        // std.debug.print("{}\n", .{tags.items.len});

        for (0..tags.items.len) |i| {
            const tag = tags.items[i];
            const point = points.items[i];
            // std.debug.print("tree_layer={d}\n", .{tree_layer});
            switch (tag & 0x03) { // first two bits
                freetype.c.FT_CURVE_TAG_ON => {
                    // std.debug.print("{} ON\n", .{tree_layer});
                    switch (tree_layer) {
                        0 => {},
                        1 => {
                            try segments.append(allocator, Segment{ .line = Line{
                                .start = points.items[i - 1],
                                .end = point,
                            } });
                            tree_layer = 0;
                        },
                        2 => {
                            if (last == freetype.c.FT_CURVE_TAG_CONIC) {
                                try segments.append(allocator, Segment{ .conic = ConicBezier{
                                    .start = points.items[i - 2],
                                    .end = point,
                                    .control = points.items[i - 1],
                                } });
                                tree_layer = 0;
                            } else return errors.BadTag;
                        },
                        else => { // tree_layer >= 3
                            if (last == freetype.c.FT_CURVE_TAG_CUBIC) {
                                if (tree_layer == 3) {
                                    try segments.append(allocator, Segment{ .cubic = CubicBezier{
                                        .start = points.items[i - 3],
                                        .end = point,
                                        .control_1 = points.items[i - 2],
                                        .control_2 = points.items[i - 1],
                                    } });
                                } else {
                                    return errors.BadTag;
                                }
                            } else if (last != freetype.c.FT_CURVE_TAG_CONIC) {
                                return errors.BadTag;
                            } else {
                                var offs: usize = tree_layer - 2;
                                var start = points.items[i - offs - 2];
                                while (true) {
                                    const intermediatePoint = interpolate(
                                        points.items[i - offs - 1],
                                        points.items[i - offs - 0],
                                    );
                                    try segments.append(allocator, Segment{ .conic = ConicBezier{
                                        .start = start,
                                        .end = intermediatePoint,
                                        .control = points.items[i - offs - 1],
                                    } });
                                    start = intermediatePoint;
                                    if (offs == 1) break;
                                    offs -= 1;
                                }
                                try segments.append(allocator, Segment{ .conic = ConicBezier{
                                    .start = start,
                                    .end = points.items[i - 0],
                                    .control = points.items[i - 1],
                                } });
                            }
                            tree_layer = 0;
                        },
                    }
                    last = freetype.c.FT_CURVE_TAG_ON;
                },
                freetype.c.FT_CURVE_TAG_CONIC => {
                    // std.debug.print("{} CO\n", .{tree_layer});
                    switch (tree_layer) {
                        0 => return errors.BadTag,
                        1 => {},
                        else => if (last != freetype.c.FT_CURVE_TAG_CONIC)
                            return errors.BadTag,
                    }
                    last = freetype.c.FT_CURVE_TAG_CONIC;
                },
                freetype.c.FT_CURVE_TAG_CUBIC => {
                    // std.debug.print("{} CU\n", .{tree_layer});
                    switch (tree_layer) {
                        0 => return errors.BadTag,
                        1 => {},
                        2 => if (last != freetype.c.FT_CURVE_TAG_CUBIC)
                            return errors.BadTag,
                        else => return errors.BadTag,
                    }
                    last = freetype.c.FT_CURVE_TAG_CUBIC;
                },
                else => {
                    return errors.BadTag;
                },
            }
            tree_layer += 1;
        }

        contours[contourIdx] = try segmentsProcess(allocator, segments);
        contours[contourIdx].segments = segments;
        // defer segments.deinit(allocator);
    }
    return contours;
}

fn segmentsProcess(allocator: std.mem.Allocator, segments: std.ArrayList(Segment)) !Contour {
    var contour: Contour = .{
        .edges = try allocator.alloc(Edge, segments.items.len),
        .edgesCount = 0,
    };
    contour.edges[0] = Edge.fromSegment(segments.items[0]);
    contour.edges[0].idx = 0;
    contour.max = contour.edges[0].lp;
    contour.maxEdge = &contour.edges[0];
    contour.min = contour.edges[0].lp;
    contour.minEdge = &contour.edges[0];
    var i: usize = 1;
    for (segments.items[1..]) |seg| {
        const edge = Edge.fromSegment(seg);
        contour.edges[i] = edge;
        contour.edges[i].idx = i;
        contour.edges[i - 1].next = &contour.edges[i];
        contour.edges[i].prev = &contour.edges[i - 1];
        if (edge.lp[1] > contour.max[1] and edge.lp[0] > contour.max[0]) {
            contour.max = edge.lp;
            contour.maxEdge = &contour.edges[i];
        } else if (edge.lp[1] < contour.min[1] and edge.lp[0] < contour.min[0]) {
            contour.min = edge.lp;
            contour.minEdge = &contour.edges[i];
        }
        i += 1;
    }
    contour.edges[i - 1].next = &contour.edges[0];
    contour.edges[0].prev = &contour.edges[i - 1];
    contour.edgesCount = i;

    //
    // Determine winding order
    //
    // Reference:
    // https://stackoverflow.com/a/1180256/199364
    // https://en.wikipedia.org/wiki/Curve_orientation
    //
    const A = contour.minEdge.lp;
    const B = contour.minEdge.prev.lp;
    const C = contour.minEdge.next.lp;
    const metric = cross(B - A, C - A);
    if (metric == 0) return errors.BadContour;
    contour.windingOrder = if (metric > 0) .CLOCKWISE else .COUNTERCLOCKWISE;

    return contour;
}

fn print_bezier_points(glyph: freetype.c.struct_FT_GlyphSlotRec_) void {
    const outline = glyph.outline;
    const tags = outline.tags[0..outline.n_points];
    std.debug.print("{}\n", .{freetype.c.FT_CURVE_TAG_ON});
    std.debug.print("{}\n", .{freetype.c.FT_CURVE_TAG_CONIC});
    std.debug.print("{}\n", .{freetype.c.FT_CURVE_TAG_CUBIC});
    std.debug.print("{}\n", .{freetype.c.FT_CURVE_TAG_HAS_SCANMODE});
    std.debug.print("{}\n", .{freetype.c.FT_CURVE_TAG_TOUCH_X});
    std.debug.print("{}\n", .{freetype.c.FT_CURVE_TAG_TOUCH_Y});
    std.debug.print("{}\n", .{freetype.c.FT_CURVE_TAG_TOUCH_BOTH});
    // std.debug.print("{}\n", .{freetype.c.FT_CURVE_TAG(outline.flags)});
    std.debug.print("{}\n", .{outline.tags[0]});
    std.debug.assert(tags[0] & 0x03 == freetype.c.FT_CURVE_TAG_ON);

    for (0..outline.n_points) |i| {
        const point = outline.points[i];
        const tag = tags[i];
        switch (tag & 0x03) {
            freetype.c.FT_CURVE_TAG_ON => {
                std.debug.print("FT_CURVE_TAG_ON", .{});
            },
            freetype.c.FT_CURVE_TAG_CONIC => {
                std.debug.print("FT_CURVE_TAG_CONIC", .{});
            },
            freetype.c.FT_CURVE_TAG_CUBIC => {
                std.debug.print("FT_CURVE_TAG_CUBIC", .{});
            },
            else => {
                std.debug.print("unknown", .{});
            },
        }
        std.debug.print("({},{})\n", .{ point.x, point.y });
    }
}

pub fn geometricMedian(points: []const Point, max_iters: usize, eps: f32) Point {
    // start with centroid as initial guess
    var sum: Point = .{ 0, 0 };
    for (points) |p| {
        sum += p;
    }
    var xy = @divFloor(sum, @as(Point, @splat(@intCast(points.len))));
    var i: usize = 0;
    while (i < max_iters) : (i += 1) {
        var num_xy: @Vector(2, f32) = .{ 0, 0 };
        var denom: f32 = 0;

        for (points) |p| {
            const dxy = xy - p;
            const dist = @sqrt(@as(f32, @floatFromInt(@reduce(.Add, dxy * dxy))));

            if (dist < eps) {
                return p;
            }

            const w = 1.0 / dist;
            num_xy = @mulAdd(@Vector(2, f32), @floatFromInt(p), @splat(w), num_xy);
            denom += w;
        }

        const new_xy: Point = @intFromFloat(num_xy / @as(@Vector(2, f32), @splat(denom)));

        if (@reduce(.And, @as(Point, @intCast(@abs(new_xy - xy))) <= @as(Point, @splat(0)))) {
            break;
        }

        xy = new_xy;
    }

    return xy;
}

fn rotate(point: PointF, degree: f32) PointF {
    const t = std.math.degreesToRadians(degree);
    const v: @Vector(2, f32) = .{ @cos(t), -@sin(t) };
    const u: @Vector(2, f32) = .{ @sin(t), @cos(t) };
    return .{
        @reduce(.Add, v * point),
        @reduce(.Add, u * point),
    };
}

inline fn orthogonal(p: PointF) PointF {
    return .{ -p[1], p[0] };
}

inline fn scaledOrthogonal(point: PointF, scalar: f32) PointF {
    return .{ -point[1] * scalar, point[0] * scalar };
}

inline fn magnitude(point: PointF) f32 {
    return @sqrt(@reduce(.Add, point * point));
}

inline fn halfCrossProduct(a: PointF, b: PointF) f32 {
    return a[1] * b[0] - a[0] * b[1];
    // return @reduce(.Add, a * orthogonal(b));
}

inline fn barycentric(p: PointF, a: PointF, b: PointF, c: PointF) PointF {
    const scalar = 1.0 / (halfCrossProduct(c, b) + (b - c) * orthogonal(a));
    const p_orthogonal = orthogonal(p);
    const s = scalar * (halfCrossProduct(a, c) + (c - a) * p_orthogonal);
    const t = scalar * (halfCrossProduct(b, a) + (a - b) * p_orthogonal);
    return .{ s, t };
}

// inline fn planarPointWithinTriangle(p: PointF, a: PointF, b: PointF, c: PointF) bool {
//     const st = barycentric(p, a, b, c);
//     const s = st[0];
//     const t = st[1];
//     return (-s <= EPS_F32 and -t <= EPS_F32 and s + t - 1 <= EPS_F32);
// }

inline fn sign(p1: PointF, p2: PointF, p3: PointF) bool {
    return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1]);
}

inline fn pointInTriangle(p: PointF, a: PointF, b: PointF, c: PointF) bool {
    const b1 = sign(p, a, b) < 0;
    const b2 = sign(p, b, c) < 0;
    const b3 = sign(p, c, a) < 0;
    return (b1 == b2) and (b2 == b3);
}

inline fn isConvex(a: PointF, b: PointF, c: PointF) bool {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) > 0;
}

const EdgeState = enum {
    PLUS,
    MINUS,
    EQUAL,

    fn fromDiff(diff: i64) EdgeState {
        if (diff > 0) return .PLUS;
        if (diff < 0) return .MINUS;
        return .EQUAL;
    }
};

const Edge = struct {
    lp: Point,
    rp: Point,
    diffp: Point,
    lpF: PointF = undefined,
    rpF: PointF = undefined,
    diffpF: PointF = undefined,
    m: f32 = undefined,
    t: f32 = undefined,
    stateY: EdgeState = undefined,
    stateX: EdgeState = undefined,
    next: *Edge = undefined,
    prev: *Edge = undefined,
    idx: usize = undefined,

    pub inline fn fromSegment(seg: Segment) Edge {
        var ret = switch (seg) {
            .line => |s| Edge{
                .lp = s.start,
                .rp = s.end,
                .diffp = s.start - s.end,
            },
            .conic => |s| Edge{
                .lp = s.start,
                .rp = s.end,
                .diffp = s.start - s.end,
            },
            .cubic => |s| Edge{
                .lp = s.start,
                .rp = s.end,
                .diffp = s.start - s.end,
            },
        };
        ret.lpF = PointF_fromInt(ret.lp);
        ret.rpF = PointF_fromInt(ret.rp);
        ret.diffpF = PointF_fromInt(ret.diffp);
        ret.stateY = EdgeState.fromDiff(ret.diffp[1]);
        ret.stateX = EdgeState.fromDiff(ret.diffp[0]);
        ret.m = ret.diffpF[1] / ret.diffpF[0];
        ret.t = ret.rpF[1] - ret.m * ret.rpF[0];
        return ret;
    }
};

fn intersectWithEdge(anchor: PointF, edge: Edge) struct { hasIntersection: bool, gamma: f32, lambda: f32 } {
    if (edge.stateY == .EQUAL) {
        return .{
            .hasIntersection = false,
            .gamma = std.math.nan(f32),
            .lambda = std.math.nan(f32),
        };
    }
    const anchorEdgeLVec = edge.lpF - anchor;
    // λ ∈ [0,1) is the position on the line pq (0=p, 1=q)
    const lambda: f32 = anchorEdgeLVec[1] / edge.diffpF[1];
    if (math.f32s_lt(lambda, 0) or math.f32s_gt(lambda, 1)) {
        return .{
            .hasIntersection = false,
            .gamma = std.math.nan(f32),
            .lambda = lambda,
        };
    } else {
        // γ is distance of intersection from anchor in x-direction
        const gamma = anchorEdgeLVec[0] - edge.diffpF[0] * lambda;
        if (math.f32s_lt(gamma, 0)) {
            return .{
                .hasIntersection = false,
                .gamma = gamma,
                .lambda = lambda,
            };
        }
        return .{
            .hasIntersection = true,
            .gamma = gamma,
            .lambda = lambda,
        };
    }
}

fn countRayIntersections(contourJ: Contour, edge: Edge) u32 {
    // Cast horizontal ray and check number of intersections with outer contour.
    // Check grid cells horizontally
    const p = edge.lp;
    var intersectionCount: u32 = 0;
    var curr = &contourJ.edges[0];
    var next = curr.next;
    var i: usize = 0;
    // if (debug) std.debug.print("p={} {}\n", .{ p, contourJ.edges.len });
    while (i < contourJ.edges.len) {
        var hitVertex = false;
        // if (debug) std.debug.print("{} {} {} {},{} {},{}\n", .{ i, intersectionCount, curr.state, curr.lp, curr.rp, next.lp, next.rp });
        if (curr.lp[0] < p[0] and curr.rp[0] < p[0]) {
            curr = next;
            next = curr.next;
            i += 1;
            continue;
        }
        if (p[1] == curr.lp[1]) {
            // vertex is to the left, early skip
            if (curr.lp[0] < p[0]) {
                curr = next;
                next = curr.next;
                i += 1;
                continue;
            }
            // we encounter the wrong vertex, so we skip, set hitVertex = false
            hitVertex = @reduce(.And, next.rp == curr.lp);
        } else if (p[1] == curr.rp[1]) {
            // vertex is to the left, early skip
            if (curr.rp[0] < p[0]) {
                curr = next;
                next = curr.next;
                i += 1;
                continue;
            }
            // we encounter the wrong vertex, so we skip, set hitVertex = false
            hitVertex = @reduce(.And, next.lp == curr.rp);
        } else {
            // no vertex hit, just intersecting edges
            const result = intersectWithEdge(PointF_fromInt(p), curr.*);
            if (result.hasIntersection) intersectionCount += 1;
            // if (debug) std.debug.print("{} {} {} λ={} γ={}\n", .{ i, intersectionCount, result.hasIntersection, result.lambda, result.gamma });
            curr = next;
        }

        if (hitVertex) {
            switch (curr.stateY) {
                .MINUS => {
                    while (i < contourJ.edges.len - 1) {
                        switch (next.stateY) {
                            .MINUS => { // intersect!
                                intersectionCount += 1;
                                break;
                            },
                            .PLUS => { // no intersect!
                                break;
                            },
                            .EQUAL => {
                                next = next.next;
                                i += 1;
                            },
                        }
                    }
                    curr = next.next;
                },
                .PLUS => {
                    while (i < contourJ.edges.len - 1) {
                        switch (next.stateY) {
                            .MINUS => { // no intersect!
                                break;
                            },
                            .PLUS => { // intersect!
                                intersectionCount += 1;
                                break;
                            },
                            .EQUAL => {
                                next = next.next;
                                i += 1;
                                // if (debug) std.debug.print("    {} {},{}\n", .{ i, next.lp, next.rp });
                            },
                        }
                    }
                    i += 1;
                    curr = next.next;
                },
                .EQUAL => {
                    curr = next;
                },
            }
        }

        next = curr.next;
        i += 1;
        // if (debug) std.debug.print("  {} {} {} {},{} {},{}\n", .{ i, intersectionCount, curr.state, curr.lp, curr.rp, next.lp, next.rp });
    }
    return intersectionCount;
}

const ContourType = enum {
    HOLE,
    DISJOINT,
    PARTIAL,
};

const PolygonalDomain = struct {
    outer: Contour,
    holes: []Contour,
};

const TreeNode = struct {
    value: usize,
    children: std.ArrayList(TreeNode),
};

fn isOutermost(contours: []Contour, contourRelations: []ContourType, i: usize) bool {
    var isOuter = true;
    for (0..contours.len) |j| {
        if (i == j) continue;
        const relIJ = contourRelations[i * contours.len + j];
        switch (relIJ) {
            .HOLE => {
                isOuter = !isOutermost(
                    contours,
                    contourRelations,
                    j,
                );
            },
            .DISJOINT => {},
            .PARTIAL => {},
        }
    }
    return isOuter;
}

pub fn contoursPolygonalDomains(allocator: std.mem.Allocator, contours: []Contour) ![]PolygonalDomain {
    // The character 'A' for example consists of two contours, one for the outside
    // and another one for the hole. We (TTF) don't know that its a hole
    // but its essential to know for triangulation.
    // Considering contour A and B, there are 3 cases:
    // 1. Some edges of A intersect B.
    //    This is a partial cover.
    // 2. No edges of A intersect B and all vertices of A are inside B.
    //    This case is called a hole.
    // 2. No edges of A intersect B and all vertices of A are outside B.
    //    This is called disjoint.
    //
    // Case 1 should be impossible, but its common in faulty TTFs.
    // Handling it is complicated, most (if not all) of the overlaps
    // should not produce any holes.
    // Case 2&3 can be triangulated normally.

    var contourRelations = try allocator.alloc(ContourType, contours.len * contours.len);
    errdefer allocator.free(contourRelations);

    // Check the boundary pairs for case 1-3.

    for (contours, 0..) |contourI, i| {
        for (contours, 0..) |contourJ, j| {
            // check every possible combination of contours, for example
            // '%' has two holes but the second hole is not inside of the first contour
            // so we have to check how all the contours relate to each other
            if (i == j) continue;
            var contourTypeInvalid = true;
            var contourType: ContourType = undefined;

            for (contourI.edges) |edge| {
                const intersectionCount = countRayIntersections(contourJ, edge);
                if (intersectionCount % 2 == 0) {
                    if (contourTypeInvalid) {
                        contourTypeInvalid = false;
                        contourType = .DISJOINT;
                    } else if (contourType != .DISJOINT) {
                        contourType = .PARTIAL;
                    }
                } else {
                    if (contourTypeInvalid) {
                        contourTypeInvalid = false;
                        contourType = .HOLE;
                    } else if (contourType != .HOLE) {
                        contourType = .PARTIAL;
                    }
                }
            }
            // std.debug.print("Contour {}/{} = {}\n", .{ i, j, contourType });
            if (contourType == .PARTIAL) {
                return errors.BadContour;
            }
            contourRelations[i * contours.len + j] = contourType;
        }
    }

    // Convert relation matrix to polygonal domains.
    var outermostContours = try std.ArrayList(usize).initCapacity(allocator, contours.len);
    defer outermostContours.deinit(allocator);
    for (0..contours.len) |i| {
        if (isOutermost(contours, contourRelations, i)) {
            outermostContours.appendAssumeCapacity(i);
        }
    }
    var polygonalDomains = try std.ArrayList(PolygonalDomain).initCapacity(allocator, outermostContours.items.len);
    defer polygonalDomains.deinit(allocator);
    for (outermostContours.items) |contourIdx| {
        var holes = try std.ArrayList(Contour).initCapacity(allocator, contours.len);
        defer holes.deinit(allocator);
        for (0..contours.len) |j| {
            if (contourIdx != j and //
                std.mem.indexOfScalar(usize, outermostContours.items, j) == null and //
                contourRelations[j * contours.len + contourIdx] == .HOLE)
            {
                holes.appendAssumeCapacity(contours[j]);
            }
        }
        const polygonalDomain: PolygonalDomain = .{
            .outer = contours[contourIdx],
            .holes = try holes.toOwnedSlice(allocator),
        };
        for (polygonalDomain.holes) |hole| {
            if (polygonalDomain.outer.windingOrder == hole.windingOrder) {
                std.debug.print("winding order missmatch, outer={}, hole={}\n", .{ polygonalDomain.outer.windingOrder, hole.windingOrder });
            }
        }
        polygonalDomains.appendAssumeCapacity(polygonalDomain);
    }
    return polygonalDomains.toOwnedSlice(allocator);
}

inline fn dotProduct(a: Point, b: Point) i64 {
    return @reduce(.Add, a * b);
}

inline fn length(a: Point) f32 {
    return @sqrt(@as(f32, @floatFromInt(@reduce(.Add, a * a))));
}

inline fn signedAngle(a: Point, b: Point) f32 {
    return std.math.atan2(@as(f32, @floatFromInt(a[0] * b[1] - a[1] * b[0])), @as(f32, @floatFromInt(a[0] * b[0] + a[1] * b[1])));
}

const MetricEdgeRef = struct {
    edge: *Edge,
    value: f32,
};

fn bisectLeft(arr: []const MetricEdgeRef, target: f32) usize {
    var lo: usize = 0;
    var hi: usize = arr.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (arr[mid].value < target)
            lo = mid + 1
        else
            hi = mid;
    }
    return lo;
}

inline fn cross(a: Point, b: Point) i64 {
    return a[0] * b[1] - a[1] * b[0];
}

inline fn isInHalfplaneCCW(a: Point, b: Point) bool {
    return cross(a, b) > 0;
}

inline fn isInHalfplaneCW(a: Point, b: Point) bool {
    return cross(a, b) < 0;
}

inline fn lengthSq(a: Point) i64 {
    return a[0] * a[0] + a[1] * a[1];
}

inline fn delauneyConditionDeterminant(a: Point, b: Point, c: Point, q: Point) i64 {
    const aqx = a[0] - q[0];
    const aqy = a[1] - q[1];
    const bqx = b[0] - q[0];
    const bqy = b[1] - q[1];
    const cqx = c[0] - q[0];
    const cqy = c[1] - q[1];
    const aq_length_sq = aqx * aqx + aqy * aqy;
    const bq_length_sq = bqx * bqx + bqy * bqy;
    const cq_length_sq = cqx * cqx + cqy * cqy;
    return (aqx * bqy * cq_length_sq + aqy * bq_length_sq * cqx + aq_length_sq * bqx * cqy) - //
        (cqx * bqy * aq_length_sq + cqy * bq_length_sq * aqx + cq_length_sq * bqx * aqy);
}

//
// returns true if q is outside or on the circumcircle of the triangle abc.
// Conversely returns false if q is strictly (!) inside the circumcircle.
//
inline fn delauneyConditionCCW(a: Point, b: Point, c: Point, q: Point) bool {
    return delauneyConditionDeterminant(a, b, c, q) <= 0;
}
inline fn delauneyConditionCW(a: Point, b: Point, c: Point, q: Point) bool {
    return delauneyConditionDeterminant(a, b, c, q) >= 0;
}

const SubContourBuilder = struct {
    allocator: std.mem.Allocator,
    edgesList: std.ArrayList(Edge),

    fn init(allocator: std.mem.Allocator) !SubContourBuilder {
        return .{
            .allocator = allocator,
            .edgesList = try std.ArrayList(Edge).initCapacity(allocator, 2),
        };
    }

    fn append(
        self: *SubContourBuilder,
        contour: Contour,
        start_edge: *const Edge,
        end_edge: *const Edge,
        start_vertex: Point,
        end_vertex: Point,
    ) !void {
        try self.edgesList.ensureUnusedCapacity(self.allocator, contour.edgesCount + 1);
        if (start_edge.idx >= end_edge.idx) {
            self.edgesList.appendSliceAssumeCapacity(contour.edges[start_edge.idx..]);
            self.edgesList.appendSliceAssumeCapacity(contour.edges[0..end_edge.idx]);
        } else {
            self.edgesList.appendSliceAssumeCapacity(contour.edges[start_edge.idx..end_edge.idx]);
        }
        self.edgesList.appendAssumeCapacity(Edge.fromSegment(.{ .line = .{
            .start = start_vertex,
            .end = end_vertex,
        } }));
    }

    fn relink(self: *SubContourBuilder) ![]Edge {
        var edges = try self.edgesList.toOwnedSlice(self.allocator);
        for (1..edges.len) |i| {
            edges[i].prev = &edges[i - 1];
            edges[i - 1].next = &edges[i];
            edges[i].idx = i;
        }
        edges[0].prev = &edges[edges.len - 1];
        edges[edges.len - 1].next = &edges[0];
        edges[0].idx = 0;
        return edges;
    }
};

// http://www.cse.yorku.ca/~amana/research/grid.pdf
// fn rayTraverseGrid(ray: Ray) []*GridCell {
//
// }

pub fn findStartingEdge(allocator: std.mem.Allocator, contour: Contour) !*Edge {
    var sorted = try allocator.alloc(MetricEdgeRef, contour.edges.len);
    var count: usize = 0;
    for (contour.edges) |curr| {
        const next = curr.next;
        const ba = -curr.diffp; // lp - rp
        const bc = next.diffp;
        var alpha_1 = signedAngle(ba, bc);
        if (alpha_1 < 0) alpha_1 += 2 * std.math.pi;

        const cb = -bc;
        const cd = next.next.diffp;
        var alpha_2 = signedAngle(cb, cd);
        if (alpha_2 < 0) alpha_2 += 2 * std.math.pi;

        const m_1 = @max(alpha_1, std.math.pi) + @max(alpha_2, std.math.pi);

        const insert_val: MetricEdgeRef = .{ .edge = next, .value = m_1 };
        const idx = bisectLeft(sorted[0..count], insert_val.value);
        std.mem.copyBackwards(MetricEdgeRef, sorted[idx + 1 .. count + 1], sorted[idx..count]);
        sorted[idx] = insert_val;
        count += 1;
    }
    return sorted[sorted.len - 1].edge;
}

fn vertexIsValid(edge: *Edge, other_vertex: Point, searchContour: Contour, delauneyTriangleWindingOrder: WindingOrder) bool {
    var vertex_is_valid = true;
    var i: usize = 0;
    var curr = &searchContour.edges[0];
    while (i < searchContour.edgesCount) : (i += 1) {
        const to_check: Point = curr.rp;
        if (!PointEqual(to_check, edge.lp) and
            !PointEqual(to_check, edge.rp) and
            !PointEqual(to_check, other_vertex) and
            !delauneyCondition(delauneyTriangleWindingOrder, edge.lp, edge.rp, other_vertex, to_check))
        {
            std.debug.print("  ({},{}) isDelauney={} {}\n", .{ to_check[0], to_check[1], false, delauneyTriangleWindingOrder });
            vertex_is_valid = false;
            break;
        }
        curr = curr.next;
    }
    return vertex_is_valid;
}

//
// Reference:
// https://math.stackexchange.com/a/1425630
//
fn edgesIntersect(edgeA: Edge, edgeB: Edge) bool {
    const vAC = edgeB.rp - edgeA.rp;
    const vAD = edgeB.lp - edgeA.rp;
    std.debug.print("vAC=({},{}),vAD=({},{})\n", .{ vAC[0], vAC[1], vAD[0], vAD[1] });
    if (PointZero(vAC)) { // implies hC = 0
        // both edges anchor the same point
        if (PointZero(vAD)) return false; // degenerate case: edge is point
        // either colinear or no intersect
        const hD = cross(edgeA.diffp, vAD);
        if (hD == 0) { // colinear
            const minCD = @min(edgeB.rp, edgeB.lp);
            const maxAB = @max(edgeA.rp, edgeA.lp);
            const maxCD = @max(edgeB.rp, edgeB.lp);
            const minAB = @min(edgeA.rp, edgeA.lp);
            return @reduce(.And, minCD < maxAB) and @reduce(.And, maxCD > minAB);
        } else {
            return false;
        }
    } else if (PointZero(vAD)) { // implies hD = 0
        // also vAC != 0 in this branch
        // either colinear or no intersect
        const hC = cross(edgeA.diffp, vAC);
        std.debug.print("hC={}\n", .{hC});
        if (hC == 0) { // colinear
            const minCD = @min(edgeB.rp, edgeB.lp);
            const maxAB = @max(edgeA.rp, edgeA.lp);
            const maxCD = @max(edgeB.rp, edgeB.lp);
            const minAB = @min(edgeA.rp, edgeA.lp);
            return @reduce(.And, minCD < maxAB) and @reduce(.And, maxCD > minAB);
        } else {
            return false;
        }
    } else {
        // vAC != 0 and vAD != 0 in this branch
        const hC = cross(edgeA.diffp, vAC);
        const hD = cross(edgeA.diffp, vAD);
        if (hC == 0 and hD == 0) { // colinear
            const minCD = @min(edgeB.rp, edgeB.lp);
            const maxAB = @max(edgeA.rp, edgeA.lp);
            const maxCD = @max(edgeB.rp, edgeB.lp);
            const minAB = @min(edgeA.rp, edgeA.lp);
            return @reduce(.And, minCD <= maxAB) and @reduce(.And, maxCD >= minAB);
        }
        const gA = cross(edgeB.diffp, edgeA.rp - edgeB.rp);
        const gB = cross(edgeB.diffp, edgeA.lp - edgeB.rp);
        return hC * hD <= 0 and gA * gB <= 0;
    }
}

fn formatBitmask(allocator: std.mem.Allocator, value: u64, width: usize) ![]const u8 {
    const fmtops: std.fmt.FormatOptions = .{
        .width = width,
        .fill = '0',
        .alignment = .right,
    };
    const buf = try allocator.alloc(u8, @max(@bitSizeOf(u64), width));
    return buf[0..std.fmt.printInt(buf, value, 2, .lower, fmtops)];
}

fn triangulatePolygonalDomain(
    allocator: std.mem.Allocator,
    printer: *Printer,
    triangulation: *std.ArrayList(Point),
    domain: PolygonalDomain,
    depth: u6,
    recursionTreeBitmask: u64,
) !void {
    std.debug.print("CALL triangulatePolygonalDomain() holes={}\n", .{domain.holes.len});
    var found_delauney_triangle = false;

    if (domain.holes.len == 0) {
        const currentContour = domain.outer;

        const original_starting_edge = try findStartingEdge(allocator, currentContour);
        var starting_edge = original_starting_edge;
        while (starting_edge.next.idx != original_starting_edge.idx) {
            std.debug.print("starting_edge={s}\n", .{try printer.edge(starting_edge)});
            printer.free_last();

            //
            // Find potential_other_vertices
            //
            var potential_other_vertices = try std.ArrayList(*Edge).initCapacity(
                allocator,
                currentContour.edges.len,
            );
            const consideringEdgeStart = &currentContour.edges[0];
            var consideringEdge = consideringEdgeStart.next;
            while (consideringEdge.idx != consideringEdgeStart.idx) {
                if (isInHalfPlane(currentContour.windingOrder, -starting_edge.diffp, consideringEdge.rp - starting_edge.lp))
                    try potential_other_vertices.append(allocator, consideringEdge); // inside halfplane
                consideringEdge = consideringEdge.next;
            }

            std.debug.print("Found {} potential other vertices\n", .{potential_other_vertices.items.len});
            for (potential_other_vertices.items) |other_vertex_edge| {
                if (!vertexIsValid(
                    starting_edge,
                    other_vertex_edge.rp,
                    currentContour,
                    currentContour.windingOrder,
                )) continue;

                std.debug.print("Found delauney triangle: ({},{}),({},{}),({},{})\n", .{ starting_edge.lp[0], starting_edge.lp[1], starting_edge.rp[0], starting_edge.rp[1], other_vertex_edge.rp[0], other_vertex_edge.rp[1] });
                found_delauney_triangle = true;
                const delauneyTriangle: [3]Point = .{ starting_edge.lp, starting_edge.rp, other_vertex_edge.rp };
                try triangulation.appendSlice(allocator, delauneyTriangle[0..]);

                //
                // subdomain 1
                //
                if ((starting_edge.next.idx + 1) % currentContour.edgesCount != other_vertex_edge.next.idx) {
                    const recursionTreeBitmask_modified = recursionTreeBitmask | (ZERO_U64 << depth);

                    var subContour: SubContourBuilder = try .init(allocator);
                    try subContour.append(
                        currentContour,
                        starting_edge.next,
                        other_vertex_edge.next,
                        other_vertex_edge.next.lp,
                        starting_edge.next.lp,
                    );
                    const edges = try subContour.relink();
                    defer allocator.free(edges);

                    const subDomain: PolygonalDomain = .{
                        .holes = &[_]Contour{},
                        .outer = .{
                            .edges = edges,
                            .edgesCount = edges.len,
                            .windingOrder = currentContour.windingOrder,
                        },
                    };
                    {
                        const buf = try formatBitmask(allocator, recursionTreeBitmask_modified, depth + 1);
                        defer allocator.free(buf);
                        std.debug.print("depth={} subdomain{s}={{\n{s}\n}}\n", .{ depth, buf, try printer.contour(&subDomain.outer) });
                        printer.free_last();
                    }

                    try triangulatePolygonalDomain(
                        allocator,
                        printer,
                        triangulation,
                        subDomain,
                        depth + 1,
                        recursionTreeBitmask_modified,
                    );
                }
                //
                // subdomain 2
                //
                if ((other_vertex_edge.next.idx + 1) % currentContour.edgesCount != starting_edge.idx) {
                    const recursionTreeBitmask_modified = recursionTreeBitmask | (ONE_U64 << depth);

                    var subContour: SubContourBuilder = try .init(allocator);
                    try subContour.append(
                        currentContour,
                        other_vertex_edge.next,
                        starting_edge,
                        starting_edge.lp,
                        other_vertex_edge.next.lp,
                    );
                    const edges = try subContour.relink();
                    defer allocator.free(edges);

                    const subDomain: PolygonalDomain = .{
                        .holes = &[_]Contour{},
                        .outer = .{
                            .edges = edges,
                            .edgesCount = edges.len,
                            .windingOrder = currentContour.windingOrder,
                        },
                    };

                    {
                        const buf = try formatBitmask(allocator, recursionTreeBitmask_modified, depth + 1);
                        defer allocator.free(buf);
                        std.debug.print("depth={} subdomain{s}={{\n{s}\n}}\n", .{ depth, buf, try printer.contour(&subDomain.outer) });
                        printer.free_last();
                    }

                    try triangulatePolygonalDomain(
                        allocator,
                        printer,
                        triangulation,
                        subDomain,
                        depth + 1,
                        recursionTreeBitmask_modified,
                    );
                }
                break;
            }

            if (found_delauney_triangle) break;
            starting_edge = starting_edge.next;
        }
    } else if (domain.holes.len == 1) {
        const original_starting_edge = try findStartingEdge(allocator, domain.holes[0]);
        var starting_edge = original_starting_edge;
        while (starting_edge.next.idx != original_starting_edge.idx) {
            std.debug.print("startingEdge={s}\n", .{try printer.edge(starting_edge)});
            printer.free_last();
            //
            // Find potential other vertices
            //
            const consideringEdgeStart = &domain.outer.edges[0];
            var consideringEdge = consideringEdgeStart;
            var edgeCounter: usize = 0;
            while (edgeCounter < domain.outer.edgesCount) {
                edgeCounter += 1;
                consideringEdge = consideringEdge.next;

                const consideringVertex = consideringEdge.rp;

                std.debug.print("L={{Element(startingEdge, 1), Element(startingEdge, 2), {s}}}\n", .{try printer.point(consideringVertex)});
                printer.free_last();
                //
                // check if consideringVertex is in halfplane to consider
                //
                if (!isInHalfPlane(
                    domain.outer.windingOrder,
                    -starting_edge.diffp,
                    consideringVertex - starting_edge.lp,
                )) continue;

                //
                // Check delauneyCondition for all vertices in searchContours
                //
                std.debug.print("Checking delauneyCondition outer!\n", .{});
                if (!vertexIsValid(
                    starting_edge,
                    consideringVertex,
                    domain.outer,
                    domain.outer.windingOrder,
                )) continue;
                std.debug.print("Checking delauneyCondition holes[0]!\n", .{});
                if (!vertexIsValid(
                    starting_edge,
                    consideringVertex,
                    domain.holes[0],
                    domain.outer.windingOrder,
                )) continue;

                //
                // found first delauney triangle
                //
                found_delauney_triangle = true;
                const delauneyTriangle: [3]Point = .{ starting_edge.lp, starting_edge.rp, consideringVertex };
                try triangulation.appendSlice(allocator, delauneyTriangle[0..]);
                std.debug.print("Found delauney!\n", .{});

                //
                // Divide domain
                //
                var subContour: SubContourBuilder = try .init(allocator);
                try subContour.append(
                    domain.outer,
                    consideringEdge.next,
                    consideringEdge.next,
                    consideringEdge.next.lp,
                    starting_edge.rp,
                );
                try subContour.append(
                    domain.holes[0],
                    starting_edge.next,
                    starting_edge,
                    starting_edge.lp,
                    consideringEdge.next.lp,
                );
                const edges = try subContour.relink();

                const subDomain: PolygonalDomain = .{
                    .holes = &[_]Contour{},
                    .outer = .{
                        .edges = edges,
                        .edgesCount = edges.len,
                        .windingOrder = domain.outer.windingOrder,
                    },
                };

                const recursionTreeBitmask_modified = recursionTreeBitmask | (ZERO_U64 << depth);
                {
                    const buf = try formatBitmask(allocator, recursionTreeBitmask_modified, depth + 1);
                    defer allocator.free(buf);
                    std.debug.print("depth={} subdomain{s}={{\n{s}\n}}\n", .{ depth, buf, try printer.contour(&subDomain.outer) });
                    printer.free_last();
                }

                try triangulatePolygonalDomain(
                    allocator,
                    printer,
                    triangulation,
                    subDomain,
                    depth + 1,
                    recursionTreeBitmask_modified,
                );
                break;
            }

            if (found_delauney_triangle) break;
            starting_edge = starting_edge.next;
        }
    } else {
        // what could happen
        //
        // - connect two holes into one -> one hole case
        // - one hole gets removed -> one hole case
        //
        // in general if we have n holes:
        // - connect two holes -> n - 1 holes (todo)
        // - connect hole to outer -> n - 1 holes (kind of handled)

        var otherHoles = try allocator.alloc(Contour, domain.holes.len - 1);
        defer allocator.free(otherHoles);
        for (domain.holes, 0..) |currentHole, currentHoleIdx| {
            @memcpy(otherHoles[0..currentHoleIdx], domain.holes[0..currentHoleIdx]);
            @memcpy(otherHoles[currentHoleIdx..], domain.holes[currentHoleIdx + 1 ..]);

            const original_starting_edge = try findStartingEdge(allocator, currentHole);
            var starting_edge = original_starting_edge;
            while (starting_edge.next.idx != original_starting_edge.idx) {
                std.debug.print("startingEdge={s}\n", .{try printer.edge(starting_edge)});
                printer.free_last();
                //
                // Find other vertex on outer contour
                //
                {
                    var consideringEdges = try std.ArrayList(*const Edge).initCapacity(allocator, 2);
                    {
                        const consideringEdgeStart = &domain.outer.edges[0];
                        var consideringEdge = consideringEdgeStart;
                        var edgeCounter: usize = 0;
                        while (edgeCounter < domain.outer.edgesCount) {
                            edgeCounter += 1;
                            consideringEdge = consideringEdge.next;
                            const consideringVertex = consideringEdge.rp;
                            printer.free_last();
                            if (!isInHalfPlane(
                                domain.outer.windingOrder,
                                -starting_edge.diffp,
                                consideringVertex - starting_edge.lp,
                            )) continue;
                            std.debug.print("L={{Element(startingEdge, 1), Element(startingEdge, 2), {s}}}\n", .{try printer.point(consideringVertex)});
                            try consideringEdges.append(allocator, consideringEdge);
                        }
                    }
                    std.debug.print("checking intersections with outer at depth={} holes={}\n", .{ depth, domain.holes.len });
                    for (consideringEdges.items, 0..) |consideringEdge, consideringEdgeIdx| {
                        const consideringVertex = consideringEdge.rp;
                        //
                        // Check if consideringVertex is visible from starting_edge.
                        // We can restrict our search to the edges that are in the halfplane
                        // which is a small optimization.
                        //
                        var hasIntersections = false;
                        for (consideringEdges.items, 0..) |intersectingEdge, intersectingEdgeIdx| {
                            if (consideringEdgeIdx == intersectingEdgeIdx) continue;
                            if (edgesIntersect(
                                Edge.fromSegment(.{ .line = .{
                                    .start = starting_edge.lp,
                                    .end = consideringVertex,
                                } }),
                                intersectingEdge.*,
                            )) {
                                std.debug.print("Has intersections: {s} with={s}\n", .{ try printer.point(consideringVertex), try printer.edge(intersectingEdge) });
                                printer.free_last();
                                printer.free_last();
                                hasIntersections = true;
                                break;
                            }
                        }
                        if (hasIntersections) {
                            // std.debug.print("Has intersections: {s}\n", .{try printer.point(consideringVertex)});
                            // printer.free_last();
                            continue;
                        }

                        //
                        // Check delauneyCondition for all vertices in searchContours
                        //
                        std.debug.print("Checking delauneyCondition outer!\n", .{});
                        if (!vertexIsValid(
                            starting_edge,
                            consideringVertex,
                            domain.outer,
                            domain.outer.windingOrder,
                        )) continue;
                        var vertex_is_valid = true;
                        for (domain.holes, 0..) |searchHole, searchHoleIdx| {
                            std.debug.print("Checking delauneyCondition holes[{}]!\n", .{searchHoleIdx});
                            // @@Very Hot code
                            if (!vertexIsValid(
                                starting_edge,
                                consideringVertex,
                                searchHole,
                                domain.outer.windingOrder,
                            )) {
                                vertex_is_valid = false;
                                break;
                            }
                        }
                        if (!vertex_is_valid) continue;

                        //
                        // found first delauney triangle
                        //
                        found_delauney_triangle = true;
                        const delauneyTriangle: [3]Point = .{ starting_edge.lp, starting_edge.rp, consideringVertex };
                        try triangulation.appendSlice(allocator, delauneyTriangle[0..]);
                        std.debug.print("Found delauney!\n", .{});

                        //
                        // Divide domain
                        //
                        var subContour: SubContourBuilder = try .init(allocator);
                        try subContour.append(
                            domain.outer,
                            consideringEdge.next,
                            consideringEdge.next,
                            consideringEdge.next.lp,
                            starting_edge.rp,
                        );
                        try subContour.append(
                            currentHole,
                            starting_edge.next,
                            starting_edge,
                            starting_edge.lp,
                            consideringEdge.next.lp,
                        );
                        const edges = try subContour.relink();

                        const subDomain: PolygonalDomain = .{
                            // .holes = &[_]Contour{},
                            .holes = otherHoles,
                            .outer = .{
                                .edges = edges,
                                .edgesCount = edges.len,
                                .windingOrder = domain.outer.windingOrder,
                            },
                        };

                        const recursionTreeBitmask_modified = recursionTreeBitmask | (ZERO_U64 << depth);
                        {
                            const buf = try formatBitmask(allocator, recursionTreeBitmask_modified, depth + 1);
                            defer allocator.free(buf);
                            std.debug.print("depth={} subdomain{s}={{\n{s}\n}}\n", .{ depth, buf, try printer.contour(&subDomain.outer) });
                            printer.free_last();
                        }

                        try triangulatePolygonalDomain(
                            allocator,
                            printer,
                            triangulation,
                            subDomain,
                            depth + 1,
                            recursionTreeBitmask_modified,
                        );
                        break;
                    }
                    // outer
                }

                if (found_delauney_triangle) break;

                // @@DEBUG
                if (!found_delauney_triangle) {
                    return errors.BadContour;
                }

                //
                // Find other vertex on hole contour
                //
                for (otherHoles) |consideringHole| {
                    var consideringEdges = try std.ArrayList(*const Edge).initCapacity(allocator, 2);
                    {
                        const consideringEdgeStart = &consideringHole.edges[0];
                        var consideringEdge = consideringEdgeStart;
                        var edgeCounter: usize = 0;
                        while (edgeCounter < domain.outer.edgesCount) {
                            edgeCounter += 1;
                            consideringEdge = consideringEdge.next;
                            const consideringVertex = consideringEdge.rp;
                            printer.free_last();
                            if (!isInHalfPlane(
                                domain.outer.windingOrder,
                                -starting_edge.diffp,
                                consideringVertex - starting_edge.lp,
                            )) continue;
                            std.debug.print("L={{Element(startingEdge, 1), Element(startingEdge, 2), {s}}}\n", .{try printer.point(consideringVertex)});
                            try consideringEdges.append(allocator, consideringEdge);
                        }
                    }
                    for (consideringEdges.items, 0..) |consideringEdge, consideringEdgeIdx| {
                        const consideringVertex = consideringEdge.rp;
                        //
                        // Check if consideringVertex is visible from starting_edge
                        //
                        // check if edges intersect
                        // https://math.stackexchange.com/a/1425630
                        var hasIntersections = false;
                        for (consideringEdges.items, 0..) |intersectingEdge, intersectingEdgeIdx| {
                            if (consideringEdgeIdx == intersectingEdgeIdx) continue;
                            if (edgesIntersect(
                                Edge.fromSegment(.{ .line = .{
                                    .start = starting_edge.lp,
                                    .end = consideringVertex,
                                } }),
                                intersectingEdge.*,
                            )) {
                                std.debug.print("Has intersections: {s} with={s}\n", .{ try printer.point(consideringVertex), try printer.edge(intersectingEdge) });
                                printer.free_last();
                                printer.free_last();
                                hasIntersections = true;
                                break;
                            }
                        }
                        if (hasIntersections) {
                            std.debug.print("Has intersections: {s}\n", .{try printer.point(consideringVertex)});
                            printer.free_last();
                            continue;
                        }
                        //
                        // Vertex is visible from starting_edge!
                        //

                        return errors.BadContour;
                    }
                }

                if (found_delauney_triangle) break;
                starting_edge = starting_edge.next;
            }

            if (found_delauney_triangle) break;
        }
    }
    if (!found_delauney_triangle) {
        std.debug.print("ERROR: Could not complete delauney triangulation after iterating considering all edges as starting edges!\n", .{});
        return errors.BadContour;
    }
}

// https://cg.cs.uni-bonn.de/backend/v1/files/publications/klein-1996-construction.pdf
pub fn triangulatePolygonalDomains(allocator: std.mem.Allocator, printer: *Printer, polygonalDomains: []PolygonalDomain) !void {
    std.debug.print("-----------------------------\n      STARTING TRIANGULATION\n-----------------------------\n", .{});
    const results = try allocator.alloc([]const u8, polygonalDomains.len);
    defer {
        // for (results) |r| allocator.free(r);
        allocator.free(results);
    }
    for (polygonalDomains, 0..) |domain, domainIdx| {
        std.debug.print("domain{}outer={{\n{s}\n}}\n", .{ domainIdx, try printer.contour(&domain.outer) });
        printer.free_last();
        std.debug.print("domain{}outerPoly=Polygon(domain{}outer)\n", .{ domainIdx, domainIdx });
        for (domain.holes, 0..) |hole, holeIdx| {
            std.debug.print("domain{}hole{}={{\n{s}\n}}\n", .{ domainIdx, holeIdx, try printer.contour(&hole) });
            printer.free_last();
            std.debug.print("domain{}hole{}Poly=Polygon(domain{}hole{})\n", .{ domainIdx, holeIdx, domainIdx, holeIdx });
        }

        var triangulation = try std.ArrayList(Point).initCapacity(allocator, domain.outer.edgesCount * 3);
        try triangulatePolygonalDomain(allocator, printer, &triangulation, domain, 0, 0);

        var geogebra_polys_print = try allocator.alloc([]const u8, triangulation.items.len / 3);
        defer {
            for (geogebra_polys_print) |s| allocator.free(s);
            allocator.free(geogebra_polys_print);
        }
        for (0..triangulation.items.len / 3) |i| {
            const A = triangulation.items[i * 3 + 0];
            const B = triangulation.items[i * 3 + 1];
            const C = triangulation.items[i * 3 + 2];
            geogebra_polys_print[i] = try std.fmt.allocPrint(allocator, "Polygon({{({},{}),({},{}),({},{})}})", .{ A[0], A[1], B[0], B[1], C[0], C[1] });
        }
        results[domainIdx] = try std.mem.join(allocator, ",\n", geogebra_polys_print);
    }
    const endResult = try std.mem.join(allocator, ",\n\n", results);
    defer allocator.free(endResult);
    std.debug.print("tri={{\n{s}\n}}\n", .{endResult});
}

// render text without a texture: https://poniesandlight.co.uk/reflect/debug_print_text/
pub fn main() !void {
    const library = try freetype.Library.init();
    defer library.deinit();
    try print_version(library);

    const face = try library.createFace("assets/fonts/SpaceMono/SpaceMono-Regular.ttf", 0);
    defer face.deinit();

    try face.selectCharmap(.unicode);
    try face.setCharSize(0, 16 * 64, 300, 300);

    const testAll = false;
    if (testAll) {
        var renderChars: [126 + 1 - 33]u32 = undefined;
        for (0..(126 + 1 - 33)) |i| {
            renderChars[i] = '!' + @as(u32, @intCast(i));
        }
        var buf: [4]u8 = undefined; // max UTF-8 length for a single code point is 4 bytes
        for (renderChars) |renderChar| {
            const len = try std.unicode.utf8Encode(@intCast(renderChar), &buf);
            std.debug.print("rendering {s}\n", .{buf[0..len]});
            const glyph_index = face.getCharIndex(renderChar).?;
            try face.loadGlyph(glyph_index, .{});
            const glyph = face.glyph();
            try glyph.render(.sdf);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            // try glyph_write_bmp(glyph, try std.fmt.allocPrint(alloc, "glyph-out/out-{s}.bmp", .{buf[0..len]}));
            const contours = try bezier(alloc, glyph.outline);
            const polygonalDomains = try contoursPolygonalDomains(alloc, contours);
            for (polygonalDomains) |domain| {
                std.debug.print("outer={} nholes={}\n", .{ domain.outer.edgesCount, domain.holes.len });
            }
            try triangulatePolygonalDomains(alloc, polygonalDomains);
        }
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const glyph_index = face.getCharIndex('8').?;

    // try face.loadGlyph(glyph_index, .{});
    // const glyph = face.glyph();
    // try glyph.render(.sdf);
    // try glyph_write_bmp(glyph, "out.bmp");

    try face.loadGlyph(glyph_index, .{});
    const contours = try bezier(alloc, face.glyph().outline().?);
    const polygonalDomains = try contoursPolygonalDomains(alloc, contours);
    var printer: Printer = try .init(alloc);
    for (polygonalDomains, 0..) |domain, i| {
        std.debug.print("domain {}: outer={} nholes={}\n", .{ i, domain.outer.edgesCount, domain.holes.len });

        std.debug.print("outer:\n", .{});
        for (domain.outer.edges) |e| {
            std.debug.print("{s},\n", .{try printer.edge(&e)});
            printer.free_last();
        }
        for (domain.holes, 0..) |hole, holeI| {
            std.debug.print("hole{}:\n", .{holeI});
            for (hole.edges) |e| {
                std.debug.print("{s},\n", .{try printer.edge(&e)});
                printer.free_last();
            }
        }
    }

    try triangulatePolygonalDomains(alloc, &printer, polygonalDomains);
}
