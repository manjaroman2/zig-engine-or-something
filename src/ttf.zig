const std = @import("std");
const graphics = @import("graphics.zig");
const math = @import("math.zig");
const ZERO_U64 = math.ZERO_U64;
const ONE_U64 = math.ONE_U64;
const Point = math.Point;
const Point_MIN = math.Point_MIN;
const Point_MAX = math.Point_MAX;
const PointEqual = math.PointEqual;
const PointLessThan = math.PointLessThan;
const PointLessThanEqual = math.PointLessThanEqual;
const PointZero = math.PointZero;
const PointMin = math.PointMin;
const PointMax = math.PointMax;
const PointNegate = math.PointNegate;
const PointSubtract = math.PointSubtract;
const PointInterpolate = math.PointInterpolate;
const PointF = math.PointF;
const PointFfromInt = math.PointFfromInt;

const freetype = @import("coolfreetype");
const harfbuzz = @import("coolharfbuzz");

fn print_version(library: freetype.Library) !void {
    const version = library.version();
    std.log.info("FreeType version: {}.{}.{}\n", .{ version.major, version.minor, version.patch });
}

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

    fn deinit(self: *Printer) void {
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

    fn domain(self: *Printer, d: *const PolygonalDomain) ![]const u8 {
        var holes = try self.allocator.alloc([]const u8, d.holes.len);
        defer {
            for (holes) |h| self.allocator.free(h);
            self.allocator.free(holes);
        }
        for (d.holes, 0..) |hole, holeI| {
            holes[holeI] = try std.fmt.allocPrint(self.allocator, "hole{}:\n{s}", .{ holeI, try self.contour(&hole) });
            // holes[holeI] = try self.contour(&hole);
        }
        const holesJoined = try std.mem.join(self.allocator, "\n", holes);
        defer self.allocator.free(holesJoined);
        const outer = try self.contour(&d.outer);
        return try self.allocPrintWithChildren(d.holes.len + 1, "outer:\n{s}\n{s}\n", .{ outer, holesJoined });
    }
};

const WindingOrder = enum {
    COUNTERCLOCKWISE,
    CLOCKWISE,
};

inline fn isInHalfPlane(windingOrder: WindingOrder, a: Point, b: Point) bool {
    return switch (windingOrder) {
        .COUNTERCLOCKWISE => math.isInHalfplaneCCW(a, b),
        .CLOCKWISE => math.isInHalfplaneCW(a, b),
    };
}

inline fn delauneyCondition(windingOrder: WindingOrder, a: Point, b: Point, c: Point, q: Point) bool {
    return switch (windingOrder) {
        .COUNTERCLOCKWISE => math.delauneyConditionCCW(a, b, c, q),
        .CLOCKWISE => math.delauneyConditionCW(a, b, c, q),
    };
}

// @@TODO Change data structure of Contour
//   points: []Point linked list
//   windingOrder: ...
//   segments: ...
//
// Point could look like this:
//   value: @Vec(2, i64)
//   next: Point
//   prev: Point
//   nextDiff: Point = next.value - self.value
//   prevDiff: ...
// Advantages:
// - be more compact memory, currently we store duplicates in lp and rp
// - More efficent algorithms, don't need to check next.lp=rp
//

const Contour = struct {
    edges: []Edge,
    edgesCount: usize,
    windingOrder: WindingOrder,
    segments: std.ArrayList(Segment) = undefined,

    fn fromSegments(allocator: std.mem.Allocator, segments: std.ArrayList(Segment)) !Contour {
        var edges = try allocator.alloc(Edge, segments.items.len);

        edges[0] = Edge.fromSegment(segments.items[0]);
        edges[0].idx = 0;
        var max = edges[0].lp;
        var maxEdge = &edges[0];
        var min = edges[0].lp;
        var minEdge = &edges[0];
        var i: usize = 1;
        for (segments.items[1..]) |seg| {
            const edge = Edge.fromSegment(seg);
            edges[i] = edge;
            edges[i].idx = i;
            edges[i - 1].next = &edges[i];
            edges[i].prev = &edges[i - 1];
            if (edge.lp[1] > max[1] and edge.lp[0] > max[0]) {
                max = edge.lp;
                maxEdge = &edges[i];
            } else if (edge.lp[1] < min[1] and edge.lp[0] < min[0]) {
                min = edge.lp;
                minEdge = &edges[i];
            }
            i += 1;
        }
        edges[i - 1].next = &edges[0];
        edges[0].prev = &edges[i - 1];

        //
        // Determine winding order
        //
        // Reference:
        // https://stackoverflow.com/a/1180256/199364
        // https://en.wikipedia.org/wiki/Curve_orientation
        //
        const A = minEdge.lp;
        const B = minEdge.prev.lp;
        const C = minEdge.next.lp;
        const metric = math.cross(PointSubtract(B, A), PointSubtract(C, A));

        if (metric == 0) return errors.BadContour;
        return .{
            .edges = edges,
            .edgesCount = edges.len,
            .segments = segments,
            .windingOrder = if (metric > 0) .CLOCKWISE else .COUNTERCLOCKWISE,
        };
    }

    fn deinit(self: Contour, allocator: std.mem.Allocator) void {
        allocator.free(self.edges);
        allocator.free(self.segments);
    }
};

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
                .diffp = PointSubtract(s.start, s.end),
            },
            .conic => |s| Edge{
                .lp = s.start,
                .rp = s.end,
                .diffp = PointSubtract(s.start, s.end),
            },
            .cubic => |s| Edge{
                .lp = s.start,
                .rp = s.end,
                .diffp = PointSubtract(s.start, s.end),
            },
        };
        ret.lpF = PointFfromInt(ret.lp);
        ret.rpF = PointFfromInt(ret.rp);
        ret.diffpF = PointFfromInt(ret.diffp);
        ret.stateY = EdgeState.fromDiff(ret.diffp[1]);
        ret.stateX = EdgeState.fromDiff(ret.diffp[0]);
        ret.m = ret.diffpF[1] / ret.diffpF[0];
        ret.t = ret.rpF[1] - ret.m * ret.rpF[0];
        return ret;
    }
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

pub const Line = struct {
    start: Point,
    end: Point,
};

pub const ConicBezier = struct {
    start: Point,
    end: Point,
    control: Point,
};

pub const CubicBezier = struct {
    start: Point,
    end: Point,
    control_1: Point,
    control_2: Point,
};

pub const errors = error{
    BadTag,
    BadContour,
};

// Constructs bezier curves from outline data.
fn parseOutlineBezier(allocator: std.mem.Allocator, outline: freetype.Outline) ![]Contour {
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
    var contours = try allocator.alloc(Contour, outline.numContours());
    var contour_offset: usize = 0;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arenaAllocator = arena.allocator();
    defer arena.deinit();
    for (outline.contours()[0..outline.numContours()], 0..) |contour_end_index, contourIdx| {
        const contour_length = @as(usize, @intCast(contour_end_index)) - contour_offset + 1;
        const tag_slice = outline.tags()[contour_offset .. contour_offset + contour_length];
        const point_slice = outline.points()[contour_offset .. contour_offset + contour_length];
        contour_offset += contour_length;

        var segments = try std.ArrayList(Segment).initCapacity(allocator, contour_length * 2);
        var last: u8 = undefined;
        var tree_layer: u8 = 0;

        var tags = try std.ArrayList(u8).initCapacity(arenaAllocator, contour_length + 2);
        var points = try std.ArrayList(@Vector(2, i64)).initCapacity(
            arenaAllocator,
            contour_length + 2,
        );

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
                    try points.append(arenaAllocator, PointInterpolate(
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
                    try tags.append(arenaAllocator, freetype.c.FT_CURVE_TAG_ON);
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
        try tags.appendSlice(arenaAllocator, tag_slice);
        try tags.append(arenaAllocator, tag_slice[0]);
        for (point_slice) |p| {
            try points.append(arenaAllocator, .{ p.x, p.y });
        }
        try points.append(arenaAllocator, .{ point_slice[0].x, point_slice[0].y });

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
                                    const intermediatePoint = PointInterpolate(
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

        contours[contourIdx] = try Contour.fromSegments(allocator, segments);
    }
    return contours;
}

// http://www.cse.yorku.ca/~amana/research/grid.pdf
// fn rayTraverseGrid(ray: Ray) []*GridCell {
//
// }

fn rayHorizonalIntersectWithEdgeOld(anchor: PointF, edge: Edge) struct { hasIntersection: bool, gamma: f32, lambda: f32 } {
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

fn rayHorizonalIntersectWithEdge(anchor: PointF, edge: Edge) bool {
    if (edge.stateY == .EQUAL) return false;
    const anchorEdgeLVec = edge.lpF - anchor;
    // λ ∈ [0,1) is the position on the line pq (0=p, 1=q)
    const lambda: f32 = anchorEdgeLVec[1] / edge.diffpF[1];
    if (math.f32s_lt(lambda, 0) or math.f32s_gt(lambda, 1)) {
        return false;
    } else {
        // γ is distance of intersection from anchor in x-direction
        const gamma = anchorEdgeLVec[0] - edge.diffpF[0] * lambda;
        return math.f32s_gte(gamma, 0);
    }
}

fn rayCountIntersections(contourJ: Contour, edge: Edge) u32 {
    // Cast horizontal ray and check number of intersections with outer contour.
    // Check grid cells horizontally
    const p = edge.lp;
    const pF = edge.lpF;
    var intersectionCount: u32 = 0;
    var curr = &contourJ.edges[0];
    var next = curr.next;
    var i: usize = 0;
    while (i < contourJ.edges.len) {
        var hitVertex = false;
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
            // hitVertex = @reduce(.And, next.rp == curr.lp);
            hitVertex = PointEqual(next.rp, curr.lp);
        } else if (p[1] == curr.rp[1]) {
            // vertex is to the left, early skip
            if (curr.rp[0] < p[0]) {
                curr = next;
                next = curr.next;
                i += 1;
                continue;
            }
            // we encounter the wrong vertex, so we skip, set hitVertex = false
            // hitVertex = @reduce(.And, next.lp == curr.rp);
            hitVertex = PointEqual(next.lp, curr.rp);
        } else {
            // no vertex hit, just intersecting edges
            if (rayHorizonalIntersectWithEdge(pF, curr.*)) intersectionCount += 1;
            curr = next;
        }

        if (!hitVertex) {
            next = curr.next;
            i += 1;
            continue;
        }

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

        next = curr.next;
        i += 1;
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

fn toOwnedSliceCopy(comptime T: type, allocator: std.mem.Allocator, src: []T) ![]T {
    const dst = try allocator.alloc(T, src.len);
    @memcpy(dst, src);
    return dst;
}

pub fn contoursPolygonalDomains(allocator: std.mem.Allocator, contours: []Contour) ![]PolygonalDomain {
    // The character 'A' for example consists of two contours, one for the outside
    // and another one for the hole. We (TTF) don't know that its a hole
    // but its essential to know for our approach to triangulation.
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

    var arena = std.heap.ArenaAllocator.init(allocator);
    const arenaAllocator = arena.allocator();
    defer arena.deinit();
    var contourRelations = try arenaAllocator.alloc(ContourType, contours.len * contours.len);

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
                const intersectionCount = rayCountIntersections(contourJ, edge);
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
    var outermostContours = try std.ArrayList(usize).initCapacity(arenaAllocator, contours.len);
    for (0..contours.len) |i| {
        if (isOutermost(contours, contourRelations, i)) {
            outermostContours.appendAssumeCapacity(i);
        }
    }
    var polygonalDomains = try std.ArrayList(PolygonalDomain).initCapacity(arenaAllocator, outermostContours.items.len);
    for (outermostContours.items) |contourIdx| {
        var holes = try std.ArrayList(Contour).initCapacity(arenaAllocator, contours.len);
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
            .holes = try toOwnedSliceCopy(Contour, allocator, holes.items[0..]),
        };
        for (polygonalDomain.holes) |hole| {
            if (polygonalDomain.outer.windingOrder == hole.windingOrder) {
                std.debug.print("winding order missmatch, outer={}, hole={}\n", .{ polygonalDomain.outer.windingOrder, hole.windingOrder });
            }
        }
        polygonalDomains.appendAssumeCapacity(polygonalDomain);
    }

    return try toOwnedSliceCopy(PolygonalDomain, allocator, polygonalDomains.items[0..]);
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

const StartingEdgePicker = struct {
    allocator: std.mem.Allocator,
    sorted: []MetricEdgeRef,
    idx: usize,

    const MetricEdgeRef = struct {
        edge: *Edge,
        value: f32,
    };

    fn next(self: *StartingEdgePicker) *Edge {
        const edge = self.sorted[self.sorted.len - 1 - self.idx].edge;
        self.idx += 1;
        return edge;
    }

    fn init(allocator: std.mem.Allocator, contour: Contour) !StartingEdgePicker {
        var sorted = try allocator.alloc(MetricEdgeRef, contour.edges.len);
        var count: usize = 0;
        for (contour.edges) |curr| {
            const nextEdge = curr.next;
            const ba = PointNegate(curr.diffp);
            const bc = nextEdge.diffp;
            var alpha_1 = math.signedAngle(ba, bc);
            if (alpha_1 < 0) alpha_1 += 2 * std.math.pi;

            const cb = PointNegate(bc);
            const cd = nextEdge.next.diffp;
            var alpha_2 = math.signedAngle(cb, cd);
            if (alpha_2 < 0) alpha_2 += 2 * std.math.pi;

            const m_1 = @max(alpha_1, std.math.pi) + @max(alpha_2, std.math.pi);

            const insert_val: MetricEdgeRef = .{ .edge = nextEdge, .value = m_1 };
            const idx = bisectLeft(sorted[0..count], insert_val.value);
            std.mem.copyBackwards(MetricEdgeRef, sorted[idx + 1 .. count + 1], sorted[idx..count]);
            sorted[idx] = insert_val;
            count += 1;
        }
        return .{ .idx = 0, .sorted = sorted, .allocator = allocator };
        // const edge = sorted[sorted.len - 1].edge;
    }

    fn deinit(self: StartingEdgePicker) void {
        self.allocator.free(self.sorted);
    }

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
};

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
    const vAC = PointSubtract(edgeB.rp, edgeA.rp);
    const vAD = PointSubtract(edgeB.lp, edgeA.rp);
    std.debug.print("vAC=({},{}),vAD=({},{})\n", .{ vAC[0], vAC[1], vAD[0], vAD[1] });
    if (PointZero(vAC)) { // implies hC = 0
        // both edges anchor the same point
        if (PointZero(vAD)) return false; // degenerate case: edge is point
        // either colinear or no intersect
        const hD = math.cross(edgeA.diffp, vAD);
        if (hD == 0) { // colinear
            const minCD = PointMin(edgeB.rp, edgeB.lp);
            const maxAB = PointMax(edgeA.rp, edgeA.lp);
            const maxCD = PointMin(edgeB.rp, edgeB.lp);
            const minAB = PointMax(edgeA.rp, edgeA.lp);
            return PointLessThan(minCD, maxAB) and PointLessThan(minAB, maxCD);
        } else {
            return false;
        }
    } else if (PointZero(vAD)) { // implies hD = 0
        // also vAC != 0 in this branch
        // either colinear or no intersect
        const hC = math.cross(edgeA.diffp, vAC);
        std.debug.print("hC={}\n", .{hC});
        if (hC == 0) { // colinear
            const minCD = PointMin(edgeB.rp, edgeB.lp);
            const maxAB = PointMax(edgeA.rp, edgeA.lp);
            const maxCD = PointMin(edgeB.rp, edgeB.lp);
            const minAB = PointMax(edgeA.rp, edgeA.lp);
            return PointLessThan(minCD, maxAB) and PointLessThan(minAB, maxCD);
        } else {
            return false;
        }
    } else {
        // vAC != 0 and vAD != 0 in this branch
        const hC = math.cross(edgeA.diffp, vAC);
        const hD = math.cross(edgeA.diffp, vAD);
        if (hC == 0 and hD == 0) { // colinear
            const minCD = PointMin(edgeB.rp, edgeB.lp);
            const maxAB = PointMax(edgeA.rp, edgeA.lp);
            const maxCD = PointMin(edgeB.rp, edgeB.lp);
            const minAB = PointMax(edgeA.rp, edgeA.lp);
            return PointLessThanEqual(minCD, maxAB) and PointLessThanEqual(minAB, maxCD);
        }
        const gA = math.cross(edgeB.diffp, PointSubtract(edgeA.rp, edgeB.rp));
        const gB = math.cross(edgeB.diffp, PointSubtract(edgeA.lp, edgeB.rp));
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

fn triangulatePolygonalDomain(allocator: std.mem.Allocator, printer: *Printer, triangulation: *std.ArrayList(Point), domain: PolygonalDomain, depth: u6, recursionTreeBitmask: u64) !void {
    std.debug.print("CALL triangulatePolygonalDomain() holes={}\n", .{domain.holes.len});
    var found_delauney_triangle = false;

    if (domain.holes.len == 0) {
        const currentContour = domain.outer;

        var startingEdgePicker: StartingEdgePicker = try .init(allocator, currentContour);
        defer startingEdgePicker.deinit();
        var starting_edge = startingEdgePicker.next();
        while (startingEdgePicker.idx < startingEdgePicker.sorted.len) {
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
                if (isInHalfPlane(
                    currentContour.windingOrder,
                    PointNegate(starting_edge.diffp),
                    PointSubtract(consideringEdge.rp, starting_edge.lp),
                ))
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
            starting_edge = startingEdgePicker.next();
        }
    } else if (domain.holes.len == 1) {
        var startingEdgePicker: StartingEdgePicker = try .init(allocator, domain.holes[0]);
        defer startingEdgePicker.deinit();
        var starting_edge = startingEdgePicker.next();
        while (startingEdgePicker.idx < startingEdgePicker.sorted.len) {
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
                    PointNegate(starting_edge.diffp),
                    PointSubtract(consideringVertex, starting_edge.lp),
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
            starting_edge = startingEdgePicker.next();
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

            var startingEdgePicker: StartingEdgePicker = try .init(allocator, currentHole);
            defer startingEdgePicker.deinit();
            var starting_edge = startingEdgePicker.next();
            while (startingEdgePicker.idx < startingEdgePicker.sorted.len) {
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
                                PointNegate(starting_edge.diffp),
                                PointSubtract(consideringVertex, starting_edge.lp),
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
                                PointNegate(starting_edge.diffp),
                                PointSubtract(consideringVertex, starting_edge.lp),
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
                starting_edge = startingEdgePicker.next();
            }

            if (found_delauney_triangle) break;
        }
    }
    if (!found_delauney_triangle) {
        std.debug.print("ERROR: Could not complete delauney triangulation after iterating considering all edges as starting edges!\n", .{});
        return errors.BadContour;
    }
}

const Mesh = struct {
    vertices: []@Vector(3, f32),
    indices: []u16,
};

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
            const allocator = std.heap.page_allocator;
            var printer: Printer = try .init(allocator);
            defer printer.deinit();

            const len = try std.unicode.utf8Encode(@intCast(renderChar), &buf);
            std.debug.print("rendering {s}\n", .{buf[0..len]});
            const glyph_index = face.getCharIndex(renderChar).?;

            try face.loadGlyph(glyph_index, .{});
            const contours = try parseOutlineBezier(allocator, face.glyph().outline());
            const polygonalDomains = try contoursPolygonalDomains(allocator, contours);
            for (polygonalDomains, 0..) |domain, domainIdx| {
                std.debug.print("domain{}:\n{s}\n", .{ domainIdx, try printer.domain(&domain) });
                printer.free_last();
            }
            try triangulatePolygonalDomains(allocator, &printer, polygonalDomains);
        }
    }

    const allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arenaAllocator = arena.allocator();

    var printer: Printer = try .init(arenaAllocator);
    defer printer.deinit();

    const glyph_index = face.getCharIndex('%').?;

    // try face.loadGlyph(glyph_index, .{});
    // const glyph = face.glyph();
    // try glyph.render(.sdf);
    // try glyph_write_bmp(glyph, "out.bmp");

    try face.loadGlyph(glyph_index, .{});
    const contours = try parseOutlineBezier(allocator, face.glyph().outline().?);
    const polygonalDomains = try contoursPolygonalDomains(allocator, contours);

    for (polygonalDomains, 0..) |domain, domainIdx| {
        std.debug.print("domain{}:\n{s}\n", .{ domainIdx, try printer.domain(&domain) });
        printer.free_last();
    }

    try triangulatePolygonalDomains(allocator, &printer, polygonalDomains);
}
