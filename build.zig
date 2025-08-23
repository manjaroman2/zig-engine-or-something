const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .ext_ttf = true,
        .ext_image = true,
        .ext_net = true,
    });

    exe_mod.addImport("sdl3", sdl3.module("sdl3"));

    const zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("zigimg", zigimg.module("zigimg"));

    const exe = b.addExecutable(.{
        .name = "testing_zig",
        .root_module = exe_mod,
    });

    const compile_shaders = b.step("compile-shaders", "Compile GLSL to SPIR-V");
    compileShaders(b, compile_shaders);
    exe.step.dependOn(compile_shaders);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // const lib_unit_tests = b.addTest(.{
    //     .root_module = lib_mod,
    // });
    //
    // const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    //
    // const exe_unit_tests = b.addTest(.{
    //     .root_module = exe_mod,
    // });
    //
    // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    //
    // const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_lib_unit_tests.step);
    // test_step.dependOn(&run_exe_unit_tests.step);
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

        // std.debug.print("in: {s}\n", .{input_path});
        // std.debug.print("out: {s}\n", .{output_path});
        //
        // const naga_command = b.addSystemCommand(&.{
        //     "naga",
        //     input_path,
        //     output_path,
        // });

        compile_shaders.dependOn(&glslc_command.step);
    }
}
