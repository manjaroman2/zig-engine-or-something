const std = @import("std");

const ggb_xml = @embedFile("template/geogebra.xml");
const ggb_defaults2d_xml = @embedFile("template/geogebra_defaults2d.xml");
const ggb_defaults3d_xml = @embedFile("template/geogebra_defaults3d.xml");
const ggb_javascript_xml = @embedFile("template/geogebra_javascript.js");
const ggb_thumbnail_png = @embedFile("template/geogebra_thumbnail.png");

const ggb_xml_before: []const u8 = blk: {
    if (std.mem.indexOf(u8, ggb_xml, "</construction>")) |pos| {
        break :blk ggb_xml[0..pos];
    } else {
        @compileError("'</construction>' not found!");
    }
};

const ggb_xml_after: []const u8 = blk: {
    if (std.mem.indexOf(u8, ggb_xml, "</construction>")) |pos| {
        break :blk ggb_xml[pos..];
    } else {
        @compileError("'</construction>' not found!");
    }
};

const errors = error{
    BadTemplate,
    ZipFailed,
};

pub const GGBFile = struct {
    insertions: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !GGBFile {
        var ret = GGBFile{
            .alloc = alloc,
            .insertions = try std.ArrayList(u8).initCapacity(alloc, 1024),
        };
        try ret.insertions.appendSlice(alloc, ggb_xml_before);
        return ret;
    }

    pub fn add(self: *GGBFile, to_insert: []const u8) !void {
        try self.insertions.appendSlice(self.alloc, to_insert);
        try self.insertions.appendSlice(self.alloc, "\n");
    }

    fn build_template(self: *GGBFile) ![]u8 {
        try self.insertions.appendSlice(self.alloc, ggb_xml_after);
        return self.insertions.items;
    }

    pub fn create(self: *GGBFile, io: std.Io, filename: []const u8) !void {
        const custom_ggb_xml = try self.build_template();
        defer self.alloc.free(custom_ggb_xml);

        try writeFile(io, "geogebra.xml", custom_ggb_xml);
        try writeFile(io, "geogebra_defaults2d.xml", ggb_defaults2d_xml);
        try writeFile(io, "geogebra_defaults3d.xml", ggb_defaults3d_xml);
        try writeFile(io, "geogebra_javascript.js", ggb_javascript_xml);
        try writeFile(io, "geogebra_thumbnail.png", ggb_thumbnail_png);

        const argv = &[_][]const u8{
            "zip",
            "-Tm",
            "-r",
            filename,
            "geogebra.xml",
            "geogebra_defaults2d.xml",
            "geogebra_defaults3d.xml",
            "geogebra_javascript.js",
            "geogebra_thumbnail.png",
        };

        var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .ignore, .cwd = .{ .dir = std.Io.Dir.cwd() }});
        const exit = try child.wait(io);
        if (exit.exited != 0) {
            return errors.ZipFailed;
        }
    }
};

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}
