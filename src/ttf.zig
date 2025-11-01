const std = @import("std");
const cgal = @import("cgal");
const ggb = @import("ggb/ggb.zig");
const math = @import("math.zig");
const zlm_i64 = @import("zlm").as(i64);
const Point = zlm_i64.Vec2;
const point_new = zlm_i64.vec2;
const Allocator = std.mem.Allocator;

const freetype = @import("coolfreetype");
const harfbuzz = @import("coolharfbuzz");

const GGBPrinter = struct {
    alloc: Allocator,
    elements: std.ArrayList(PrinterElement),
    ggb_file: ggb.GGBFile,

    const PrinterElement = struct {
        allocatedString: []const u8,
        children: usize,
    };

    fn init(alloc: Allocator) !GGBPrinter {
        return .{
            .elements = try std.ArrayList(PrinterElement).initCapacity(alloc, 1),
            .alloc = alloc,
            .ggb_file = try .init(alloc),
        };
    }

    fn allocPrintWithChildren(self: *GGBPrinter, children: usize, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const a = try std.fmt.allocPrint(self.alloc, fmt, args);
        try self.elements.append(self.alloc, .{
            .allocatedString = a,
            .children = children,
        });
        return a;
    }

    fn free_last(self: *GGBPrinter) void {
        if (self.elements.pop()) |last| {
            self.alloc.free(last.allocatedString);
            for (0..last.children) |_| self.free_last();
        }
    }

    fn deinit(self: *GGBPrinter) void {
        while (self.elements.items.len > 0) self.free_last();
        self.elements.deinit(self.alloc);
    }
};

const StdoutPrinter = struct {
    allocator: Allocator,
    allocated: std.ArrayList(PrinterElement),

    const PrinterElement = struct {
        allocatedString: []const u8,
        children: usize,
    };

    fn init(allocator: Allocator) !StdoutPrinter {
        return .{
            .allocated = try std.ArrayList(PrinterElement).initCapacity(allocator, 1),
            .allocator = allocator,
        };
    }

    fn allocPrintWithChildren(self: *StdoutPrinter, children: usize, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const a = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.allocated.append(self.allocator, .{
            .allocatedString = a,
            .children = children,
        });
        return a;
    }

    fn free_last(self: *StdoutPrinter) void {
        if (self.allocated.pop()) |last| {
            self.allocator.free(last.allocatedString);
            for (0..last.children) |_| self.free_last();
        }
    }

    fn deinit(self: *StdoutPrinter) void {
        while (self.allocated.items.len > 0) self.free_last();
        self.allocated.deinit(self.allocator);
    }
};

pub const Node = struct {
    p: Point,
    nxt: *Node = undefined,
    prv: *Node = undefined,
    pMnxtp: Point = undefined,
};

pub const Contour = struct {
    nodes: []Node = undefined,
    segments: std.ArrayList(Segment) = undefined,

    pub fn toGGALPointList(self: *const Contour, alloc: Allocator) ![]cgal.Point {
        var ret = try alloc.alloc(cgal.Point, self.nodes.len);
        for (self.nodes, 0..) |node, i| {
            ret[i][0] = @floatFromInt(node.p.x);
            ret[i][1] = @floatFromInt(node.p.y);
        }
        return ret;
    }

    pub fn print_ggb(self: *const Contour, printer: *GGBPrinter, name: []const u8) !void {
        var tmp = try printer.alloc.alloc([]const u8, self.nodes.len);

        for (self.nodes, 0..) |node, i| {
            tmp[i] = try printer.allocPrintWithChildren(0, "({},{})", .{ node.p.x, node.p.y });
        }

        const result = try std.mem.join(printer.alloc, ",", tmp);
        for (tmp) |_| printer.free_last();
        printer.alloc.free(tmp);

        const source =
            \\<command name="Polygon">
            \\<input a0="{{{s}}}"/>
            \\<output a0="{s}"/>
            \\</command>
            \\<element type="polygon" label="{s}">
            \\<lineStyle thickness="5" type="0" typeHidden="1" opacity="178"/>
            \\<show object="true" label="false"/>
            \\<objColor r="153" g="51" b="0" alpha="0.10000000149011612"/>
            \\<layer val="0"/>
            \\<labelMode val="0"/>
            \\</element>
        ;
        const string = try printer.allocPrintWithChildren(0, source, .{ result, name, name });
        printer.alloc.free(result);

        try printer.ggb_file.add(string);
    }

    // Constructs bezier curves from outline data.
    pub fn parseOutlineBezier(alloc: Allocator, outline: freetype.Outline, printer: *GGBPrinter) ![]Contour {
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
        var contours = try alloc.alloc(Contour, outline.numContours());
        var contour_offset: usize = 0;
        var arena = std.heap.ArenaAllocator.init(alloc);
        const arenaAllocator = arena.allocator();
        defer arena.deinit();
        for (outline.contours()[0..outline.numContours()], 0..) |contour_end_index, contourIdx| {
            const contour_length = @as(usize, @intCast(contour_end_index)) - contour_offset + 1;
            const tag_slice = outline.tags()[contour_offset .. contour_offset + contour_length];
            const point_slice = outline.points()[contour_offset .. contour_offset + contour_length];

            contour_offset += contour_length;

            var segments = try std.ArrayList(Segment).initCapacity(alloc, contour_length * 2);
            var last: u8 = undefined;
            var tree_layer: u8 = 0;

            var tags = try std.ArrayList(u8).initCapacity(arenaAllocator, contour_length + 2);
            var points = try std.ArrayList(Point).initCapacity(
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
                        try points.append(arenaAllocator, PointInterpolate(point_new(
                            @intCast(point_slice[0].x),
                            @intCast(point_slice[0].y),
                        ), point_new(
                            @intCast(point_slice[contour_length - 1].x),
                            @intCast(point_slice[contour_length - 1].y),
                        )));
                        // ));
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
                try points.append(arenaAllocator, point_new(p.x, p.y));
            }
            try points.append(arenaAllocator, point_new(point_slice[0].x, point_slice[0].y));

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
                                try segments.append(alloc, Segment{ .line = Line{
                                    .start = points.items[i - 1],
                                    .end = point,
                                } });
                                tree_layer = 0;
                            },
                            2 => {
                                if (last == freetype.c.FT_CURVE_TAG_CONIC) {
                                    try segments.append(alloc, Segment{ .conic = ConicBezier{
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
                                        try segments.append(alloc, Segment{ .cubic = CubicBezier{
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
                                        try segments.append(alloc, Segment{ .conic = ConicBezier{
                                            .start = start,
                                            .end = intermediatePoint,
                                            .control = points.items[i - offs - 1],
                                        } });
                                        start = intermediatePoint;
                                        if (offs == 1) break;
                                        offs -= 1;
                                    }
                                    try segments.append(alloc, Segment{ .conic = ConicBezier{
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

            contours[contourIdx] = try Contour.fromSegments(alloc, segments);
            var buf: [1024]u8 = undefined;
            try contours[contourIdx].print_ggb(printer, try std.fmt.bufPrint(&buf, "contour{}", .{contourIdx}));
        }
        return contours;
    }

    fn fromSegments(alloc: Allocator, segments: std.ArrayList(Segment)) !Contour {
        var nodes = try alloc.alloc(Node, segments.items.len);
        var i: usize = 0;
        for (segments.items) |seg| {
            switch (seg) {
                inline else => |e| {
                    nodes[i] = .{ .p = e.start };
                    // nodes[i + 1] = .{ .p = e.end };
                },
            }
            i += 1;
        }
        i = 0;
        while (i < nodes.len - 1) : (i += 1) {
            nodes[i].nxt = &nodes[i + 1];
            nodes[i + 1].prv = &nodes[i];
            nodes[i].pMnxtp = Point.sub(nodes[i].p, nodes[i + 1].p);
        }
        nodes[nodes.len - 1].nxt = &nodes[0];
        nodes[0].prv = &nodes[nodes.len - 1];
        nodes[nodes.len - 1].pMnxtp = Point.sub(nodes[nodes.len - 1].p, nodes[0].p);

        return .{ .segments = segments, .nodes = nodes };
    }

    inline fn PointInterpolate(a: Point, b: Point) Point {
        return point_new(@divFloor(a.x + b.x, 2), @divFloor(a.y + b.y, 2));
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

pub fn print_ListOfCGALPoints(self: *const []cgal.Point, printer: *GGBPrinter, name: []const u8) !void {
    var tmp = try printer.alloc.alloc([]const u8, self.len);

    for (self.*, 0..) |point, i| {
        tmp[i] = try printer.allocPrintWithChildren(0, "({},{})", .{ point[0], point[1] });
    }

    const result = try std.mem.join(printer.alloc, ",", tmp);
    for (tmp) |_| printer.free_last();
    printer.alloc.free(tmp);

    const source =
        \\<command name="Polygon">
        \\<input a0="{{{s}}}"/>
        \\<output a0="{s}"/>
        \\</command>
        \\<element type="polygon" label="{s}">
        \\<lineStyle thickness="5" type="0" typeHidden="1" opacity="178"/>
        \\<show object="true" label="false"/>
        \\<objColor r="153" g="51" b="0" alpha="0.10000000149011612"/>
        \\<layer val="0"/>
        \\<labelMode val="0"/>
        \\</element>
    ;
    const string = try printer.allocPrintWithChildren(0, source, .{ result, name, name });
    printer.alloc.free(result);

    try printer.ggb_file.add(string);
}

pub fn print_PolygonWithHoles(self: *const cgal.PolygonWithHoles, printer: *GGBPrinter, name: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try print_ListOfCGALPoints(&self.outer, printer, try std.fmt.bufPrint(&buf, "{s}-outer", .{name}));
    for (self.holes, 0..) |hole, i| {
        try print_ListOfCGALPoints(&hole, printer, try std.fmt.bufPrint(&buf, "{s}-hole{}", .{ name, i }));
    }
}

pub fn print_Triangles(self: *const []cgal.Triangle, printer: *GGBPrinter, name: []const u8) !void {
    var tmp = try printer.alloc.alloc([]const u8, self.len);

    var buf_point: [3][1024]u8 = undefined;
    for (self.*, 0..) |triangle, i| {
        var vn = try printer.alloc.alloc([]const u8, 3);
        vn[0] = try std.fmt.bufPrint(&buf_point[0], "({},{})", .{ triangle.v0[0], triangle.v0[1] });
        vn[1] = try std.fmt.bufPrint(&buf_point[1], "({},{})", .{ triangle.v1[0], triangle.v1[1] });
        vn[2] = try std.fmt.bufPrint(&buf_point[2], "({},{})", .{ triangle.v2[0], triangle.v2[1] });

        const points_string = try std.mem.join(printer.alloc, ",", vn);

        tmp[i] = try printer.allocPrintWithChildren(0, "Polygon[{{{s}}}]", .{points_string});
        printer.alloc.free(points_string);
    }

    const triangles_list_string = try std.mem.join(printer.alloc, ",", tmp);
    for (tmp) |_| printer.free_last();
    printer.alloc.free(tmp);

    //<expression label="tri" exp="{Polygon[{(1, 1), (1, 2), (2, 1)}], Polygon[{(2, 2), (2, 3), (4, 3)}]}" />
    const source =
        \\<expression label="{s}" exp="{{{s}}}" />
        \\<element type="list" label="{s}">
        \\<show object="true" label="true"/>
        \\<objColor r="0" g="100" b="0" alpha="0.10000000149011612"/>
        \\<layer val="0"/>
        \\<labelMode val="0"/>
        \\<lineStyle thickness="5" type="0" typeHidden="1"/>
        \\<pointSize val="5"/>
        \\<pointStyle val="0"/>
        \\<angleStyle val="0"/>
        \\</element>
    ;

    const string = try printer.allocPrintWithChildren(0, source, .{ name, triangles_list_string, name });
    printer.alloc.free(triangles_list_string);

    try printer.ggb_file.add(string);
}

// render text without a texture: https://poniesandlight.co.uk/reflect/debug_print_text/
pub fn main() !void {
    const library = try freetype.Library.init();
    defer library.deinit();

    {
        const version = library.version();
        std.log.info("FreeType version: {}.{}.{}\n", .{ version.major, version.minor, version.patch });
    }

    // const face = try library.createFace("assets/fonts/SpaceMono/SpaceMono-Regular.ttf", 0);
    const face = try library.createFace("assets/fonts/NotoSans/NotoSansEgyptianHieroglyphs-Regular.ttf", 0);
    defer face.deinit();

    try face.selectCharmap(.unicode);
    try face.setCharSize(0, 16 * 64, 300, 300);

    {
        // var renderChars: [126 + 1 - 33]u32 = undefined;
        // for (0..(126 + 1 - 33)) |i| renderChars[i] = '!' + @as(u32, @intCast(i));
        const allocator = std.heap.page_allocator;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arenaAllocator = arena.allocator();

        var renderCharsList = try std.ArrayList(u32).initCapacity(allocator, 2);

        // const codepoint_start: u32 = 0x13000;
        // const codepoint_end: u32 = 0x1342F;

        const codepoint_start: u32 = 0x1303B;
        const codepoint_end: u32 = 0x1303B;

        // const codepoint_start: u32 = 'A';
        // const codepoint_end: u32 = 'B';
        for (0..codepoint_end - codepoint_start + 1) |i| {
            try renderCharsList.append(allocator, @intCast(codepoint_start + i));
        }

        const codepoints = renderCharsList.items;
        // var buf: [4]u8 = undefined; // max UTF-8 length for a single code point is 4 bytes
        var ggb_filename_buf: [1024]u8 = undefined;
        var maxlen: usize = 0;
        var maxlen_codepoint: u32 = 0;
        for (codepoints) |codepoint| {
            const ggb_contour_filename = try std.fmt.bufPrint(&ggb_filename_buf, "out/0x{X}-contours.ggb", .{codepoint});
            var printer_contours: GGBPrinter = try .init(arenaAllocator);
            defer printer_contours.deinit();

            var buf: [1024]u8 = undefined;
            const len = try std.unicode.utf8Encode(@intCast(codepoint), &buf);
            std.debug.print("rendering {s} (0x{X})\n", .{ buf[0..len], codepoint });
            const glyph_index = face.getCharIndex(codepoint).?;

            try face.loadGlyph(glyph_index, .{});

            // parse contours
            const contours = try Contour.parseOutlineBezier(allocator, face.glyph().outline().?, &printer_contours);
            if (contours.len > maxlen) {
                maxlen_codepoint = codepoint;
                maxlen = contours.len;
            }
            try printer_contours.ggb_file.create(ggb_contour_filename);

            // create polygonal domains
            var contoursToClassify = try allocator.alloc([]const cgal.Point, contours.len);
            defer allocator.free(contoursToClassify);
            for (contours, 0..) |contour, i| {
                contoursToClassify[i] = try contour.toGGALPointList(allocator);
            }
            defer {
                for (contoursToClassify) |contourToClassify| {
                    allocator.free(contourToClassify);
                }
            }

            const polygons = try cgal.classifyContours(allocator, contoursToClassify);
            defer cgal.freePolygons(allocator, polygons);

            std.debug.print("classifyContours returned {} polygon(s)\n", .{polygons.len});
            for (polygons, 0..) |polygon, i| {
                std.debug.print("  Polygon {}: {} outer points, {} holes\n", .{ i, polygon.outer.len, polygon.holes.len });
            }

            const ggb_polygons_filename = try std.fmt.bufPrint(&ggb_filename_buf, "out/0x{X}-polygons.ggb", .{codepoint});
            var printer_polygons: GGBPrinter = try .init(arenaAllocator);
            defer printer_polygons.deinit();

            for (polygons, 0..) |polygon, i| {
                try print_PolygonWithHoles(&polygon, &printer_polygons, try std.fmt.bufPrint(&buf, "polygon{}", .{i}));
            }

            try printer_polygons.ggb_file.create(ggb_polygons_filename);

            // triangulate
            const ggb_triangulation_filename = try std.fmt.bufPrint(&ggb_filename_buf, "out/0x{X}-triangulation.ggb", .{codepoint});
            var printer_triangulation: GGBPrinter = try .init(arenaAllocator);
            defer printer_triangulation.deinit();
            for (polygons, 0..) |*polygon, polygonIdx| {
                var triangulation = try cgal.triangulatePolygon(allocator, polygon);
                defer triangulation.deinit();

                std.debug.print("Triangulated into {} triangles\n", .{triangulation.triangles.len});

                // Debug: check if any triangle centers are in the hole
                if (polygon.holes.len > 0) {
                    const hole = polygon.holes[0];
                    std.debug.print("Checking triangles against hole with {} points\n", .{hole.len});

                    for (triangulation.triangles, 0..) |tri, i| {
                        const cx = (tri.v0[0] + tri.v1[0] + tri.v2[0]) / 3.0;
                        const cy = (tri.v0[1] + tri.v1[1] + tri.v2[1]) / 3.0;
                        if (i < 3) {
                            std.debug.print("  Triangle {} centroid: ({d:.1}, {d:.1})\n", .{ i, cx, cy });
                        }
                    }
                }

                try print_Triangles(&triangulation.triangles, &printer_triangulation, try std.fmt.bufPrint(&buf, "polygon{}-tri", .{polygonIdx}));
                for (triangulation.triangles) |tri| {
                    std.debug.print("Triangle: ({d:.1}, {d:.1}) ({d:.1}, {d:.1}) ({d:.1}, {d:.1})\n", .{ tri.v0[0], tri.v0[1], tri.v1[0], tri.v1[1], tri.v2[0], tri.v2[1] });
                }
            }

            try printer_triangulation.ggb_file.create(ggb_triangulation_filename);
        }
        std.debug.print("most contours: 0x{X} ({})", .{ maxlen_codepoint, maxlen });
    }
}
