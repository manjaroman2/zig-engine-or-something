const sdl3 = @import("sdl3");
const std = @import("std");
const zigimg = @import("zigimg");
const convert = @import("convert.zig");

const fps = 60;
const screen_width = 640;
const screen_height = 480;

pub fn loadShader(
    allocator: std.mem.Allocator,
    device: sdl3.gpu.Device,
    file_path: []const u8,
    stage: sdl3.gpu.ShaderStage,
    sampler_count: u32,
    uniform_buffer_count: u32,
    storage_buffer_count: u32,
    storage_texture_count: u32,
) !sdl3.gpu.Shader {
    const code = try std.fs.cwd().readFileAlloc(allocator, file_path, 4096);
    defer allocator.free(code);

    return device.createShader(.{
        .code = code,
        .entry_point = "main",
        .format = .{ .spirv = true },
        .stage = stage,
        .num_samplers = sampler_count,
        .num_uniform_buffers = uniform_buffer_count,
        .num_storage_buffers = storage_buffer_count,
        .num_storage_textures = storage_texture_count,
        .props = null,
    });
}

pub const Context = struct {
    device: sdl3.gpu.Device,
    window: sdl3.video.Window,
    fill_pipeline: sdl3.gpu.GraphicsPipeline = undefined,
    line_pipeline: sdl3.gpu.GraphicsPipeline = undefined,
    vertex_buffer: sdl3.gpu.Buffer = undefined,
    index_buffer: sdl3.gpu.Buffer = undefined,
    samplers: [sampler_names.len]sdl3.gpu.Sampler = undefined,
    samplers_idx: usize = 0,
    texture: sdl3.gpu.Texture = undefined,
    fontSmall: sdl3.ttf.Font = undefined,
    fontBig: sdl3.ttf.Font = undefined,
    textEngine: sdl3.ttf.GpuTextEngine = undefined,
    atlas_texture_size: i64 = 1 << 10,
    fragGlobals: FragGlobals = .{
        .gradientMin = .{ std.math.floatMax(f32), std.math.floatMax(f32), 0, 0 },
        .gradientMax = .{ std.math.floatMin(f32), std.math.floatMin(f32), 0, 0 },
        .time = 0,
        .speed = 2.0,
        .period = 1.0,
        ._pad = .{0},
    },
    gradient_texture: sdl3.gpu.Texture = undefined,
    indices_num: u32 = 6,
    instances_num: u32 = 1,
    delta_time: f32 = 0,
    time: f32 = 0,
    quit: bool = false,
    t_toggle: bool = true,
};

const PositionColorVertex = packed struct {
    position: @Vector(3, f32),
    color: @Vector(4, u8),
};

const PositionTextureVertex = packed struct {
    position: @Vector(3, f32),
    uv: @Vector(2, f32),
};

const PositionTextureColorVertex = packed struct {
    position: @Vector(3, f32),
    uv: @Vector(2, f32),
    color: @Vector(4, u8),
    _pad: u32 = 0,
};

const FragGlobals = packed struct {
    gradientMin: @Vector(4, f32),
    gradientMax: @Vector(4, f32),
    time: f32,
    speed: f32,
    period: f32,
    _pad: @Vector(1, u32),
};

const sampler_names = [_][]const u8{
    "PointClamp",
    "PointWrap",
    "LinearClamp",
    "LinearWrap",
    "AnisotropicClamp",
    "AnisotropicWrap",
};

pub fn loadImage(allocator: std.mem.Allocator, file_path: []const u8) !zigimg.Image {
    var file = try std.fs.cwd().openFile(
        file_path,
        .{},
    );
    defer file.close();

    const img_format = try zigimg.Image.detectFormatFromFile(&file);
    std.debug.print("img_format: {s}\n", .{@tagName(img_format)});
    return try zigimg.Image.fromFile(
        allocator,
        &file,
    );
}

pub fn basicTriangle(ctx: *Context) !sdl3.gpu.VertexInputState {
    const vertex_buffer_desc = [1]sdl3.gpu.VertexBufferDescription{
        .{
            .pitch = @sizeOf(PositionColorVertex),
            .input_rate = .vertex,
            .slot = 0,
            .instance_step_rate = 0,
        },
    };
    const vertex_attributes = [2]sdl3.gpu.VertexAttribute{
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.f32x3,
            .offset = 0,
        },
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.u8x4_normalized,
            .offset = @offsetOf(PositionColorVertex, "color"),
        },
    };

    const vertex_data = [_]PositionColorVertex{
        .{ .position = .{ -1, -1, 0.0 }, .color = .{ 255, 0, 0, 255 } },
        .{ .position = .{ 1, -1, 0.0 }, .color = .{ 0, 255, 0, 255 } },
        .{ .position = .{ 0, 1, 0.0 }, .color = .{ 0, 0, 255, 255 } },

        .{ .position = .{ -1, -1, 0 }, .color = .{ 255, 165, 0, 255 } },
        .{ .position = .{ 1, -1, 0 }, .color = .{ 0, 128, 0, 255 } },
        .{ .position = .{ 0, 1, 0 }, .color = .{ 0, 255, 255, 255 } },

        .{ .position = .{ -1, -1, 0 }, .color = .{ 255, 255, 255, 255 } },
        .{ .position = .{ 1, -1, 0 }, .color = .{ 255, 255, 255, 255 } },
        .{ .position = .{ 0, 1, 0 }, .color = .{ 255, 255, 255, 255 } },
    };
    const index_data = [_]u16{ 0, 1, 2, 3, 4, 5 };

    const vertex_data_size: u32 = @intCast(@sizeOf(@TypeOf(vertex_data)));
    const index_data_size: u32 = @intCast(@sizeOf(@TypeOf(index_data)));
    ctx.indices_num = @intCast(index_data.len);

    ctx.vertex_buffer = try ctx.device.createBuffer(.{
        .usage = .{ .vertex = true },
        .size = vertex_data_size,
    });
    errdefer ctx.device.releaseBuffer(ctx.vertex_buffer);

    ctx.index_buffer = try ctx.device.createBuffer(.{
        .usage = .{ .index = true },
        .size = index_data_size,
    });
    errdefer ctx.device.releaseBuffer(ctx.index_buffer);

    const transfer_buffer = try ctx.device.createTransferBuffer(.{
        .usage = .upload,
        .size = vertex_data_size + index_data_size,
    });
    defer ctx.device.releaseTransferBuffer(transfer_buffer);
    const transfer_buffer_mapped = @as(
        *@TypeOf(vertex_data),
        @alignCast(@ptrCast(try ctx.device.mapTransferBuffer(transfer_buffer, false))),
    );
    transfer_buffer_mapped.* = vertex_data;
    @as(*@TypeOf(index_data), @ptrFromInt(@intFromPtr(transfer_buffer_mapped) + vertex_data_size)).* = index_data;
    ctx.device.unmapTransferBuffer(transfer_buffer);

    const upload_cmd_buf = try ctx.device.acquireCommandBuffer();
    const copy_pass = upload_cmd_buf.beginCopyPass();
    copy_pass.uploadToBuffer(
        .{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        },
        .{
            .buffer = ctx.vertex_buffer,
            .offset = 0,
            .size = vertex_data_size,
        },
        false,
    );
    copy_pass.uploadToBuffer(
        .{
            .transfer_buffer = transfer_buffer,
            .offset = vertex_data_size,
        },
        .{
            .buffer = ctx.index_buffer,
            .offset = 0,
            .size = index_data_size,
        },
        false,
    );

    copy_pass.end();
    try upload_cmd_buf.submit();

    return .{
        .vertex_buffer_descriptions = &vertex_buffer_desc,
        .vertex_attributes = &vertex_attributes,
    };
}

pub fn texturedQuad(ctx: *Context, allocator: std.mem.Allocator) !sdl3.gpu.VertexInputState {
    const vertex_buffer_desc = [1]sdl3.gpu.VertexBufferDescription{
        .{
            .pitch = @sizeOf(PositionTextureVertex),
            .input_rate = .vertex,
            .slot = 0,
            .instance_step_rate = 0,
        },
    };
    const vertex_attributes = [2]sdl3.gpu.VertexAttribute{
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.f32x3,
            .offset = 0,
        },
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.f32x2,
            .offset = @offsetOf(PositionTextureVertex, "uv"),
        },
    };

    var image_data = try loadImage(
        allocator,
        "assets/images/zig.png",
    );
    try image_data.convert(.rgba32);

    defer image_data.deinit();
    ctx.samplers[0] = try ctx.device.createSampler(.{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
    });
    ctx.samplers[1] = try ctx.device.createSampler(.{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .mipmap_mode = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
    });
    ctx.samplers[2] = try ctx.device.createSampler(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
    });
    ctx.samplers[3] = try ctx.device.createSampler(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
    });
    ctx.samplers[4] = try ctx.device.createSampler(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .max_anisotropy = 4,
    });
    ctx.samplers[5] = try ctx.device.createSampler(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .max_anisotropy = 4,
    });

    const vertex_data = [_]PositionTextureVertex{
        .{
            .position = .{ -1, 1, 0 },
            .uv = .{ 0, 0 },
        },
        .{
            .position = .{ 1, 1, 0 },
            .uv = .{ 2, 0 },
        },
        .{
            .position = .{ 1, -1, 0 },
            .uv = .{ 2, 2 },
        },
        .{
            .position = .{ -1, -1, 0 },
            .uv = .{ 0, 2 },
        },
    };
    const index_data = [_]u16{ 0, 1, 2, 0, 2, 3 };
    const vertex_data_size: u32 = @intCast(@sizeOf(@TypeOf(vertex_data)));
    const index_data_size: u32 = @intCast(@sizeOf(@TypeOf(index_data)));
    ctx.indices_num = @intCast(index_data.len);

    ctx.vertex_buffer = try ctx.device.createBuffer(.{
        .usage = .{ .vertex = true },
        .size = vertex_data_size,
    });
    errdefer ctx.device.releaseBuffer(ctx.vertex_buffer);

    ctx.index_buffer = try ctx.device.createBuffer(.{
        .usage = .{ .index = true },
        .size = index_data_size,
    });
    errdefer ctx.device.releaseBuffer(ctx.index_buffer);

    const transfer_buffer = try ctx.device.createTransferBuffer(.{
        .usage = .upload,
        .size = vertex_data_size + index_data_size,
    });
    defer ctx.device.releaseTransferBuffer(transfer_buffer);

    const transfer_buffer_mapped = @as(
        *@TypeOf(vertex_data),
        @alignCast(@ptrCast(try ctx.device.mapTransferBuffer(transfer_buffer, false))),
    );
    transfer_buffer_mapped.* = vertex_data;
    @as(*@TypeOf(index_data), @ptrFromInt(@intFromPtr(transfer_buffer_mapped) + vertex_data_size)).* = index_data;
    ctx.device.unmapTransferBuffer(transfer_buffer);

    ctx.texture = try ctx.device.createTexture(.{
        .texture_type = .two_dimensional,
        .format = .r8g8b8a8_unorm,
        .width = @intCast(image_data.width),
        .height = @intCast(image_data.height),
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .usage = .{ .sampler = true },
    });
    errdefer ctx.device.releaseTexture(ctx.texture);

    const texture_transfer_buffer = try ctx.device.createTransferBuffer(.{
        .usage = .upload,
        .size = @intCast(image_data.width * image_data.height * 4),
    });
    defer ctx.device.releaseTransferBuffer(texture_transfer_buffer);
    const texture_transfer_buffer_mapped = try ctx.device.mapTransferBuffer(texture_transfer_buffer, false);
    @memcpy(texture_transfer_buffer_mapped, image_data.rawBytes());
    ctx.device.unmapTransferBuffer(texture_transfer_buffer);

    const upload_cmd_buf = try ctx.device.acquireCommandBuffer();
    const copy_pass = upload_cmd_buf.beginCopyPass();
    copy_pass.uploadToBuffer(
        .{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        },
        .{
            .buffer = ctx.vertex_buffer,
            .offset = 0,
            .size = vertex_data_size,
        },
        false,
    );
    copy_pass.uploadToBuffer(
        .{
            .transfer_buffer = transfer_buffer,
            .offset = vertex_data_size,
        },
        .{
            .buffer = ctx.index_buffer,
            .offset = 0,
            .size = index_data_size,
        },
        false,
    );

    copy_pass.uploadToTexture(
        .{
            .transfer_buffer = texture_transfer_buffer,
            .offset = 0,
        },
        .{
            .texture = ctx.texture,
            .width = @intCast(image_data.width),
            .height = @intCast(image_data.height),
            .depth = 1,
        },
        false,
    );
    copy_pass.end();
    try upload_cmd_buf.submit();

    return .{
        .vertex_buffer_descriptions = &vertex_buffer_desc,
        .vertex_attributes = &vertex_attributes,
    };
}

pub fn makeOrthoProjMatrix(width: f32, height: f32) [16]f32 {
    return .{
        2.0 / width, 0.0, 0.0, 0.0, // column 0
        0.0, 2.0 / height, 0.0, 0.0, // column 1
        0.0, 0.0, -1.0, 0.0, // column 2
        -1.0, 1.0, 0.0, 1.0, // column 3 (translation + w)
    };
}

pub fn make1DGradient(allocator: std.mem.Allocator, width: u32) ![]const u8 {
    var pixels = try allocator.alloc(u8, width * 4);
    for (0..width) |x| {
        const idx = x * 4;
        const tx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width - 1));

        var r: f32 = 0.0;
        var g: f32 = 0.0;
        var b: f32 = 0.0;

        const t = tx;
        r = 255.0 * (1.0 - t);
        g = 255.0 * t;
        b = 0.0;
        // if (tx <= 0.5) { // Red -> Green
        //     const t = tx / 0.5; // remap [0,0.5] -> [0,1]
        //     r = 255.0 * (1.0 - t);
        //     g = 255.0 * t;
        //     b = 0.0;
        // } else { // Green -> Blue
        //     const t = (tx - 0.5) / 0.5; // remap [0.5,1] -> [0,1]
        //     r = 0.0;
        //     g = 255.0 * (1.0 - t);
        //     b = 255.0 * t;
        // }

        pixels[idx + 0] = @intFromFloat(r);
        pixels[idx + 1] = @intFromFloat(g);
        pixels[idx + 2] = @intFromFloat(b);
        pixels[idx + 3] = 255;
    }
    return pixels;
}

pub fn make2DGradient(allocator: std.mem.Allocator, width: u32, height: u32) ![]const u8 {
    var pixels = try allocator.alloc(u8, width * height * 4);
    for (0..width) |x| {
        for (0..height) |y| {
            const idx = (y * width + x) * 4;
            const tx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width - 1));
            const ty = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height - 1));
            var shifted = tx + ty;
            if (shifted > 1.0) shifted -= 1.0;
            const r: u8 = @intFromFloat(255.0 * (1.0 - shifted));
            const g: u8 = @intFromFloat(255.0 * shifted);
            const b: u8 = 0;
            const a: u8 = 255;
            pixels[idx + 0] = r;
            pixels[idx + 1] = g;
            pixels[idx + 2] = b;
            pixels[idx + 3] = a;
        }
    }
    return pixels;
}

pub fn fontShader(ctx: *Context, allocator: std.mem.Allocator) !sdl3.gpu.VertexInputState {
    const vertex_buffer_desc = [1]sdl3.gpu.VertexBufferDescription{
        .{
            .pitch = @sizeOf(PositionTextureColorVertex),
            .input_rate = .vertex,
            .slot = 0,
            .instance_step_rate = 0,
        },
    };

    const vertex_attributes = [3]sdl3.gpu.VertexAttribute{
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.f32x3,
            .offset = 0,
        },
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.f32x2,
            .offset = @offsetOf(PositionTextureColorVertex, "uv"),
        },
        .{
            .location = 2,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.u8x4_normalized,
            .offset = @offsetOf(PositionTextureColorVertex, "color"),
        },
    };

    ctx.samplers[0] = try ctx.device.createSampler(.{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
    });
    ctx.samplers[1] = try ctx.device.createSampler(.{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .mipmap_mode = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
    });
    ctx.samplers[2] = try ctx.device.createSampler(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
    });
    ctx.samplers[3] = try ctx.device.createSampler(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
    });
    ctx.samplers[4] = try ctx.device.createSampler(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .max_anisotropy = 4,
    });
    ctx.samplers[5] = try ctx.device.createSampler(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .max_anisotropy = 4,
    });
    const text_obj = try sdl3.ttf.Text.init(
        .{ .value = ctx.textEngine.value },
        ctx.fontBig,
        "Zig is cool!",
    );
    defer text_obj.deinit();

    var current = sdl3.ttf.getGpuTextDrawData(text_obj);
    var vertex_data = std.ArrayList(PositionTextureColorVertex).init(allocator);
    defer vertex_data.deinit();

    while (current) |node| {
        const draw_sequence = sdl3.ttf.GpuAtlasDrawSequence.fromSdl(node);
        std.debug.assert(draw_sequence.xy.len == draw_sequence.uv.len);
        const vertex_num = draw_sequence.xy.len;
        std.debug.assert(vertex_num > 0);

        try vertex_data.ensureTotalCapacity(vertex_data.capacity + vertex_num);
        for (0..vertex_num) |i| {
            const position = draw_sequence.xy[i];
            const uv = draw_sequence.uv[i];
            const vertex = PositionTextureColorVertex{
                .position = .{ position.x + 10, position.y - 10, 0 },
                .uv = .{ uv.x, uv.y },
                .color = .{ 255, 0, 0, 255 },
            };
            try vertex_data.append(vertex);
            ctx.fragGlobals.gradientMin[0] = @min(ctx.fragGlobals.gradientMin[0], vertex.position[0]);
            ctx.fragGlobals.gradientMin[1] = @min(ctx.fragGlobals.gradientMin[1], vertex.position[1]);
            ctx.fragGlobals.gradientMax[0] = @max(ctx.fragGlobals.gradientMax[0], vertex.position[0]);
            ctx.fragGlobals.gradientMax[1] = @max(ctx.fragGlobals.gradientMax[1], vertex.position[1]);
        }
        std.debug.print(
            "draw_sequence.xy.len={d}, draw_sequence.indices.len={d}\n",
            .{ draw_sequence.xy.len, draw_sequence.indices.len },
        );
        std.debug.print("size={} align={} pitch={}\n", .{ @sizeOf(PositionTextureColorVertex), @alignOf(PositionTextureColorVertex), vertex_buffer_desc[0].pitch });
        const vertex_data_size: u32 = @intCast(vertex_num * @sizeOf(PositionTextureColorVertex));
        const index_data = try convert.convertIntsToU16s(allocator, draw_sequence.indices);
        const index_data_size: u32 = @intCast(index_data.len * @sizeOf(u16));
        ctx.indices_num = @intCast(index_data.len);

        const aligned_vertex_size: usize = std.mem.alignForward(
            usize,
            vertex_data_size,
            @alignOf(u16),
        );

        ctx.vertex_buffer = try ctx.device.createBuffer(.{
            .usage = .{ .vertex = true },
            .size = vertex_data_size,
        });
        errdefer ctx.device.releaseBuffer(ctx.vertex_buffer);
        ctx.index_buffer = try ctx.device.createBuffer(.{
            .usage = .{ .index = true },
            .size = index_data_size,
        });
        errdefer ctx.device.releaseBuffer(ctx.index_buffer);

        const transfer_buffer = try ctx.device.createTransferBuffer(.{
            .usage = .upload,
            .size = @intCast(aligned_vertex_size + index_data_size),
        });
        defer ctx.device.releaseTransferBuffer(transfer_buffer);

        const raw_ptr: [*]u8 = @ptrCast(try ctx.device.mapTransferBuffer(transfer_buffer, false));
        const vertex_ptr: [*]PositionTextureColorVertex = @alignCast(@ptrCast(raw_ptr));
        const index_ptr: [*]u16 = @alignCast(@ptrCast(raw_ptr + aligned_vertex_size));
        std.mem.copyForwards(PositionTextureColorVertex, vertex_ptr[0..vertex_data.items.len], vertex_data.items);
        std.mem.copyForwards(u16, index_ptr[0..index_data.len], index_data);
        ctx.device.unmapTransferBuffer(transfer_buffer);

        ctx.texture = draw_sequence.atlas_texture;
        errdefer ctx.device.releaseTexture(ctx.texture);

        // gradient texture
        const gradient_width: u32 = @intFromFloat(ctx.fragGlobals.gradientMax[0] - ctx.fragGlobals.gradientMin[0]);
        // const gradient_height: u32 = @intFromFloat(ctx.fragGlobals.gradientMax[1] - ctx.fragGlobals.gradientMin[1]);
        const gradient_height: u32 = 1;
        std.debug.print("gradient_width={d} gradient_height={d}\n", .{ gradient_width, gradient_height });
        const gradient_raw = try make1DGradient(
            allocator,
            gradient_width,
        );
        ctx.gradient_texture = try ctx.device.createTexture(.{
            .texture_type = .two_dimensional,
            .format = .r8g8b8a8_unorm,
            .width = gradient_width,
            .height = gradient_height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .usage = .{
                .sampler = true,
            },
        });
        errdefer ctx.device.releaseTexture(ctx.gradient_texture);

        const texture_transfer_buffer = try ctx.device.createTransferBuffer(.{
            .usage = .upload,
            .size = gradient_width * gradient_height * 4,
        });
        defer ctx.device.releaseTransferBuffer(texture_transfer_buffer);
        const texture_transfer_buffer_mapped = try ctx.device.mapTransferBuffer(
            texture_transfer_buffer,
            false,
        );
        @memcpy(texture_transfer_buffer_mapped, gradient_raw);
        ctx.device.unmapTransferBuffer(texture_transfer_buffer);

        const upload_cmd_buf = try ctx.device.acquireCommandBuffer();
        const copy_pass = upload_cmd_buf.beginCopyPass();
        copy_pass.uploadToBuffer(
            .{
                .transfer_buffer = transfer_buffer,
                .offset = 0,
            },
            .{
                .buffer = ctx.vertex_buffer,
                .offset = 0,
                .size = vertex_data_size,
            },
            false,
        );
        copy_pass.uploadToBuffer(
            .{
                .transfer_buffer = transfer_buffer,
                .offset = @intCast(aligned_vertex_size),
            },
            .{
                .buffer = ctx.index_buffer,
                .offset = 0,
                .size = index_data_size,
            },
            false,
        );

        // upload gradient texture
        copy_pass.uploadToTexture(
            .{
                .transfer_buffer = texture_transfer_buffer,
                .offset = 0,
            },
            .{
                .texture = ctx.gradient_texture,
                .width = gradient_width,
                .height = gradient_height,
                .depth = 1,
            },
            false,
        );

        copy_pass.end();
        try upload_cmd_buf.submit();

        // Todo handle multiple
        std.debug.assert(node.next == null);
        current = node.next;
        break;
    }
    return .{
        .vertex_buffer_descriptions = &vertex_buffer_desc,
        .vertex_attributes = &vertex_attributes,
    };
}

pub fn loadShaders(ctx: *Context) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const vert_shader = try loadShader(
        allocator,
        ctx.device,
        "assets/shaders/Font.vert.spv",
        // "assets/shaders/TexturedQuad.vert.spv",
        .vertex,
        0,
        1,
        0,
        0,
    );
    defer ctx.device.releaseShader(vert_shader);
    const frag_shader = try loadShader(
        allocator,
        ctx.device,
        "assets/shaders/Font.frag.spv",
        // "assets/shaders/TexturedQuad.frag.spv",
        .fragment,
        2,
        1,
        0,
        0,
    );
    defer ctx.device.releaseShader(frag_shader);

    // const vertex_input_state = try texturedQuad(ctx, allocator);
    const vertex_input_state = try fontShader(ctx, allocator);

    const blend_state: sdl3.gpu.ColorTargetBlendState = .{
        .enable_blend = true,
        .source_color = .src_alpha,
        .destination_color = .one_minus_src_alpha,
        .color_blend = .add,
        .source_alpha = .one,
        .destination_alpha = .one_minus_src_alpha,
        .alpha_blend = .add,
        .color_write_mask = .{
            .alpha = true,
            .red = true,
            .blue = true,
            .green = true,
        },
        .enable_color_write_mask = true,
    };

    var pipeline_create_info = sdl3.gpu.GraphicsPipelineCreateInfo{
        .target_info = .{
            .color_target_descriptions = &.{
                .{
                    .format = ctx.device.getSwapchainTextureFormat(ctx.window),
                    .blend_state = blend_state,
                },
            },
        },
        .primitive_type = sdl3.gpu.PrimitiveType.triangle_list,
        .vertex_input_state = vertex_input_state,
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
    };
    ctx.fill_pipeline = try ctx.device.createGraphicsPipeline(pipeline_create_info);
    errdefer ctx.device.releaseGraphicsPipeline(ctx.fill_pipeline);

    pipeline_create_info.rasterizer_state.fill_mode = .line;
    ctx.line_pipeline = try ctx.device.createGraphicsPipeline(pipeline_create_info);
    errdefer ctx.device.releaseGraphicsPipeline(ctx.line_pipeline);
}

pub fn pollEvents(ctx: *Context) void {
    if (sdl3.events.poll()) |event|
        switch (event) {
            .quit => {
                ctx.quit = true;
            },
            .terminating => {
                ctx.quit = true;
            },
            .key_down => {
                std.debug.print("{?}\n", .{event.key_down.key});
                if (event.key_down.key) |kc| {
                    switch (kc) {
                        sdl3.keycode.Keycode.q => {
                            ctx.quit = true;
                        },
                        sdl3.keycode.Keycode.t => {
                            ctx.t_toggle = !ctx.t_toggle;
                            ctx.samplers_idx = (ctx.samplers_idx + 1) % sampler_names.len;
                            std.debug.print("samplers_idx: {d}\n", .{ctx.samplers_idx});
                        },
                        else => {},
                    }
                }
            },
            else => {},
        };
}

pub fn draw(ctx: Context) !void {
    const cmd_buf = try ctx.device.acquireCommandBuffer();
    const swapchain_texture = try cmd_buf.waitAndAcquireSwapchainTexture(ctx.window);
    const proj = makeOrthoProjMatrix(screen_width, screen_height);
    const bytes: []const u8 = std.mem.asBytes(&proj);

    if (swapchain_texture.texture) |texture| {
        const render_pass = cmd_buf.beginRenderPass(
            &.{
                sdl3.gpu.ColorTargetInfo{ .texture = texture, .clear_color = .{
                    .r = 1,
                    .b = 1,
                    .g = 1,
                    .a = 1,
                }, .load = .clear },
            },
            null,
        );
        defer render_pass.end();
        // render_pass.setViewport(.{
        //     .min_depth = 0,
        //     .max_depth = 1,
        //     .region = .{
        //         .x = 0,
        //         .y = 0,
        //         .h = screen_height,
        //         .w = screen_width,
        //     },
        // });

        render_pass.bindGraphicsPipeline(ctx.fill_pipeline);

        cmd_buf.pushVertexUniformData(
            0,
            bytes,
        );

        render_pass.bindVertexBuffers(0, &.{.{
            .buffer = ctx.vertex_buffer,
            .offset = 0,
        }});

        render_pass.bindIndexBuffer(.{
            .buffer = ctx.index_buffer,
            .offset = 0,
        }, .indices_16bit);

        render_pass.bindFragmentSamplers(0, &.{.{
            .texture = ctx.texture,
            .sampler = ctx.samplers[ctx.samplers_idx],
        }});
        render_pass.bindFragmentSamplers(1, &.{.{
            .texture = ctx.gradient_texture,
            .sampler = ctx.samplers[ctx.samplers_idx],
        }});

        cmd_buf.pushFragmentUniformData(0, std.mem.asBytes(&ctx.fragGlobals));

        render_pass.drawIndexedPrimitives(
            ctx.indices_num,
            ctx.instances_num,
            0,
            0,
            0,
        );
    }

    try cmd_buf.submit();
}

pub fn main() !void {
    const log_app = sdl3.log.Category.application;

    defer sdl3.shutdown();

    const init_flags = sdl3.InitFlags{
        .video = true,
        .audio = true,
        .events = true,
    };

    try sdl3.init(init_flags);
    defer sdl3.quit(init_flags);

    try sdl3.ttf.init();
    defer sdl3.ttf.quit();

    // render text without a texture: https://poniesandlight.co.uk/reflect/debug_print_text/

    std.log.info("Using SDL_ttf {d}.{d}.{d}", .{ sdl3.ttf.major_version, sdl3.ttf.minor_version, sdl3.ttf.micro_version });
    std.log.info("Linked against SDL_ttf version: {}", .{sdl3.ttf.getVersion()});
    std.debug.assert(sdl3.ttf.Version.atLeast(3, 0, 0));
    const ft_version = sdl3.ttf.getFreeTypeVersion();
    try log_app.logInfo("Using FreeType {d}.{d}.{d}", .{ ft_version.major, ft_version.minor, ft_version.patch });
    const hb_version = sdl3.ttf.getHarfBuzzVersion();
    try log_app.logInfo("Using HarfBuzz {d}.{d}.{d}", .{ hb_version.major, hb_version.minor, hb_version.patch });
    std.debug.assert(sdl3.ttf.wasInit() > 0);

    const device = try sdl3.gpu.Device.init(
        .{ .spirv = true },
        true,
        null,
    );
    defer device.deinit();

    const window = try sdl3.video.Window.init(
        "Hello SDL3",
        screen_width,
        screen_height,
        .{},
    );
    defer window.deinit();

    try device.claimWindow(window);

    var ctx: Context = .{ .device = device, .window = window };

    const font_path = "assets/fonts/SpaceMono/SpaceMono-Regular.ttf";
    ctx.fontSmall = try sdl3.ttf.Font.init(font_path, 24);
    defer ctx.fontSmall.deinit();
    ctx.fontBig = try sdl3.ttf.Font.init(font_path, 64);
    defer ctx.fontBig.deinit();
    std.debug.print("fontSmall {}\n", .{ctx.fontSmall});
    std.debug.print("fontBig {}\n", .{ctx.fontBig});

    ctx.textEngine = try sdl3.ttf.GpuTextEngine.initWithProperties(.{
        .device = ctx.device,
        .atlas_texture_size = ctx.atlas_texture_size,
    });
    defer ctx.textEngine.deinit();

    try loadShaders(&ctx);

    defer ctx.device.releaseWindow(ctx.window);
    defer ctx.device.releaseGraphicsPipeline(ctx.fill_pipeline);
    defer ctx.device.releaseGraphicsPipeline(ctx.line_pipeline);

    var fps_capper = sdl3.extras.FramerateCapper(f32){ .mode = .{ .limited = fps } };

    while (!ctx.quit) {
        ctx.delta_time = fps_capper.delay();
        ctx.time += ctx.delta_time;
        ctx.fragGlobals.time = ctx.time;

        pollEvents(&ctx);
        try draw(ctx);
    }
    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();
    // try stdout.print("Run `zig build test` to run the tests.\n", .{});
    // try bw.flush();
}
