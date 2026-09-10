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
    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
    });
    ttf_mod.linkLibrary(freetype.artifact("freetype"));
    ttf_mod.addIncludePath(freetype.path("include"));

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
    cgal_mod.addObjectFile(.{ .cwd_relative = "/usr/lib/libstdc++.so.6" });
    cgal_mod.linkSystemLibrary("gcc_s", .{});
    cgal_mod.linkSystemLibrary("gmp", .{});
    cgal_mod.linkSystemLibrary("mpfr", .{});

    const exe = b.addExecutable(.{
        .name = "testing_zig",
        .root_module = ttf_mod,
    });

    exe.step.dependOn(&make_build.step);

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
