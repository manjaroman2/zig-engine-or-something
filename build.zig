const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ttf_mod = b.createModule(.{
        .root_source_file = b.path("src/ttf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // mach_freetype
    const mach_freetype_dep = b.dependency("mach_freetype", .{
        .target = target,
        .optimize = optimize,
    });
    const mach_freetype_mod = mach_freetype_dep.module("mach-freetype");
    const mach_harfbuzz_mod = mach_freetype_dep.module("mach-harfbuzz");
    ttf_mod.addImport("coolfreetype", mach_freetype_mod);
    ttf_mod.addImport("coolharfbuzz", mach_harfbuzz_mod);

    // zlm
    const zlm_dep = b.dependency("zlm", .{
        .target = target,
        .optimize = optimize,
    });
    const zlm_mod = zlm_dep.module("zlm");
    ttf_mod.addImport("zlm", zlm_mod);

    // cgal
    const cgal_mod = b.addModule("cgal", .{
        .root_source_file = b.path("src/polygon_classfier_cgal/cgal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    ttf_mod.addImport("cgal", cgal_mod);

    const cmake_build = b.addSystemCommand(&[_][]const u8{
        "cmake",
        "-B",
        "cpp_build",
        "-S",
        "src/polygon_classfier_cgal/",
        "-DCMAKE_BUILD_TYPE=Release",
    });
    const make_build = b.addSystemCommand(&[_][]const u8{
        "cmake",
        "--build",
        "cpp_build",
        "--config",
        "Release",
    });
    make_build.step.dependOn(&cmake_build.step);

    cgal_mod.addIncludePath(b.path("."));
    cgal_mod.addObjectFile(b.path("cpp_build/libpolygon_classifier.a"));

    // Link C library first
    // cgal_mod.linkLibC();

    cgal_mod.addObjectFile(.{ .cwd_relative = "/usr/lib/libstdc++.so.6" });

    cgal_mod.linkSystemLibrary("gcc_s", .{});

    cgal_mod.linkSystemLibrary("gmp", .{});
    cgal_mod.linkSystemLibrary("mpfr", .{});

    const exe = b.addExecutable(.{
        .name = "testing_zig",
        .root_module = ttf_mod,
    });

    exe.step.dependOn(&make_build.step);

    // compile shaders
    // const compile_shaders = b.step("compile-shaders", "Compile GLSL to SPIR-V");
    // compileShaders(b, compile_shaders);
    // exe.step.dependOn(compile_shaders);

    b.installArtifact(exe);

    // zig build run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn compileShaders(b: *std.Build, compile_shaders: *std.Build.Step) void {
    std.fs.cwd().makePath("assets/shaders") catch |err| {
        std.debug.print("Error creating assets/shaders: {}\n", .{err});
        return;
    };

    var shader_dir = std.fs.cwd().openDir("src/shaders", .{ .iterate = true }) catch |err| {
        std.debug.print("Error opening src/shaders: {}\n", .{err});
        return;
    };
    defer shader_dir.close();

    var walker = shader_dir.walk(b.allocator) catch |err| {
        std.debug.print("Error creating directory walker: {}\n", .{err});
        return;
    };
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        const basename = entry.basename;
        var parts = std.mem.splitSequence(u8, basename, ".");

        var collected_parts: [3][]const u8 = undefined;
        var part_count: usize = 0;
        while (parts.next()) |part| : (part_count += 1) {
            if (part_count >= 3) break;
            collected_parts[part_count] = part;
        }

        if (part_count < 3) continue;

        var shader_language: []const u8 = "";
        const shader_spv = std.mem.join(b.allocator, ".", &[_][]const u8{
            collected_parts[0],
            collected_parts[1],
        }) catch |err| {
            std.debug.print("Failed to join shader name: {}\n", .{err});
            continue;
        };
        if (std.mem.eql(u8, collected_parts[2], "glsl") == true) {
            shader_language = "glsl";
        } else if (std.mem.eql(u8, collected_parts[2], "hlsl")) {
            std.debug.print("Error: HLSL shaders are not supported. Skipping {s}\n", .{basename});
            continue;
        }

        const input_path = b.fmt("src/shaders/{s}", .{entry.path});
        const output_path = b.fmt("assets/shaders/{s}.spv", .{shader_spv});

        var shader_type: []const u8 = "";
        if (std.mem.eql(u8, collected_parts[1], "vert") == true) {
            shader_type = "-fshader-stage=vertex";
        } else if (std.mem.eql(u8, collected_parts[1], "frag")) {
            shader_type = "-fshader-stage=fragment";
        } else if (std.mem.eql(u8, collected_parts[1], "comp")) {
            std.debug.print("Error: Compute shaders not supported. Skipping {s}\n", .{basename});
            continue;
        }

        const glslc_command = b.addSystemCommand(&.{
            "glslc",
            shader_type,
            "-std=450",
            // "-O",
            input_path,
            "-o",
            output_path,
        });

        compile_shaders.dependOn(&glslc_command.step);
    }
}
const freetype_srcs: []const []const u8 = &.{
    "src/autofit/autofit.c",
    "src/base/ftbase.c",
    "src/base/ftbbox.c",
    "src/base/ftbdf.c",
    "src/base/ftbitmap.c",
    "src/base/ftcid.c",
    "src/base/ftfstype.c",
    "src/base/ftgasp.c",
    "src/base/ftglyph.c",
    "src/base/ftgxval.c",
    "src/base/ftinit.c",
    "src/base/ftmm.c",
    "src/base/ftotval.c",
    "src/base/ftpatent.c",
    "src/base/ftpfr.c",
    "src/base/ftstroke.c",
    "src/base/ftsynth.c",
    "src/base/fttype1.c",
    "src/base/ftwinfnt.c",
    "src/bdf/bdf.c",
    "src/bzip2/ftbzip2.c",
    "src/cache/ftcache.c",
    "src/cff/cff.c",
    "src/cid/type1cid.c",
    "src/gzip/ftgzip.c",
    "src/lzw/ftlzw.c",
    "src/pcf/pcf.c",
    "src/pfr/pfr.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/raster/raster.c",
    "src/sdf/sdf.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/svg/svg.c",
    "src/truetype/truetype.c",
    "src/type1/type1.c",
    "src/type42/type42.c",
    "src/winfonts/winfnt.c",
};
