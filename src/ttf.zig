const std = @import("std");
const ggb = @import("ggb/ggb.zig");
const math = @import("math.zig");

const freetype = @import("coolfreetype");
const harfbuzz = @import("coolharfbuzz");

const Printer = struct {
    allocator: std.mem.Allocator,
    allocated: std.ArrayList(PrinterElement),
    ggb_file: ggb.GGBFile,

    const PrinterElement = struct {
        allocatedString: []const u8,
        children: usize,
    };

    fn init(allocator: std.mem.Allocator, ggb_file_name: []const u8) !Printer {
        return .{
            .allocated = try std.ArrayList(PrinterElement).initCapacity(allocator, 1),
            .allocator = allocator,
            .ggb_file = try .init(allocator, ggb_file_name),
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
};

pub const Contour = struct {};
pub const Segment = struct {};

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
            _ = contours;
        }
    }

    const allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arenaAllocator = arena.allocator();

    var printer: Printer = try .init(arenaAllocator, "out.ggb");
    defer printer.deinit();

    const glyph_index = face.getCharIndex(0x130D3).?;

    try face.loadGlyph(glyph_index, .{});
    const contours = try parseOutlineBezier(allocator, face.glyph().outline().?);
    _ = contours;

    try printer.ggb_file.create();
}
