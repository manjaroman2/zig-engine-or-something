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

    pub fn create(self: *GGBFile, filename: []const u8) !void {
        var cwd_buf: [1024]u8 = undefined;
        const cwd = try std.fs.cwd().realpath(".", &cwd_buf);

        const custom_ggb_xml = try self.build_template();
        defer self.alloc.free(custom_ggb_xml);

        try writeFile("geogebra.xml", custom_ggb_xml);
        try writeFile("geogebra_defaults2d.xml", ggb_defaults2d_xml);
        try writeFile("geogebra_defaults3d.xml", ggb_defaults3d_xml);
        try writeFile("geogebra_javascript.js", ggb_javascript_xml);
        try writeFile("geogebra_thumbnail.png", ggb_thumbnail_png);

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

        var child = std.process.Child.init(argv, self.alloc);

        child.stdout_behavior = .Ignore;

        child.cwd = cwd;
        try child.spawn();
        const exit = try child.wait();
        if (exit.Exited != 0) {
            return errors.ZipFailed;
        }
    }
};

fn writeFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}
