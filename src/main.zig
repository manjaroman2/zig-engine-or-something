const sdl3 = @import("sdl3");
const std = @import("std");
const zigimg = @import("zigimg");
const convert = @import("convert.zig");
const ttf = @import("ttf.zig");
const graphics = @import("graphics.zig");
const PositionTextureColorLayeredVertex = graphics.PositionTextureColorLayeredVertex;

const fps = 60;
const screen_width = 640;
const screen_height = 480;
const COLOR_BLACK: sdl3.pixels.FColor = .{ .r = 0, .b = 0, .g = 0, .a = 1 };
const COLOR_WHITE: sdl3.pixels.FColor = .{ .r = 1, .b = 1, .g = 1, .a = 1 };

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

pub const TextWithAnimatedGradient = struct {
    gradientMin: @Vector(2, f32),
    gradientMax: @Vector(2, f32),
    gradientAnimationSpeed: f32,
    gradientAnimationPeriod: f32,
    vertex_buffer: sdl3.gpu.Buffer,
    index_buffer: sdl3.gpu.Buffer,
    index_buffer_len: u32,
    fontAtlasTexture: sdl3.gpu.Texture,
    gradientTexture: sdl3.gpu.Texture,
    device: *const sdl3.gpu.Device,

    pub const Error = error{
        NoTextGpuData,
        TextTooLargeForAtlas,
    };

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        device: *const sdl3.gpu.Device,
        textEngine: sdl3.ttf.GpuTextEngine,
        font: sdl3.ttf.Font,
        fontAtlasTextureSize: u32,
        str: []const u8,
        gradientColorLeft: sdl3.pixels.FColor,
        gradientColorRight: sdl3.pixels.FColor,
        offset: @Vector(3, f32),
    ) !Self {
        var obj = Self{
            .vertex_buffer = undefined,
            .index_buffer = undefined,
            .index_buffer_len = 0,
            .gradientTexture = undefined,
            .fontAtlasTexture = undefined,
            .gradientMin = .{ std.math.floatMax(f32), std.math.floatMax(f32) },
            .gradientMax = .{ std.math.floatMin(f32), std.math.floatMin(f32) },
            .gradientAnimationSpeed = 2.0,
            .gradientAnimationPeriod = 2.0,
            .device = device,
        };

        var vertex_data = std.ArrayList(PositionTextureColorLayeredVertex).init(allocator);
        defer vertex_data.deinit();
        var index_data = std.ArrayList(u16).init(allocator);
        defer index_data.deinit();
        var font_texture_data = std.ArrayList(sdl3.gpu.Texture).init(allocator);
        defer font_texture_data.deinit();

        const text = try sdl3.ttf.Text.init(
            .{ .value = textEngine.value },
            font,
            str,
        );
        defer text.deinit();
        const root = sdl3.ttf.getGpuTextDrawData(text);
        var current = root;
        var total_vertex_num: usize = 0;
        var total_index_num: usize = 0;
        var total_font_texture_num: usize = 0;

        while (current) |node| {
            current = node.next;
            const d = sdl3.ttf.GpuAtlasDrawSequence.fromSdl(node);
            if (d.image_type == .invalid) {
                continue;
            }
            std.debug.assert(d.xy.len == d.uv.len);
            std.debug.assert(d.xy.len > 0);

            total_index_num += d.indices.len;
            try index_data.ensureTotalCapacity(total_index_num);

            try index_data.appendSlice(try convert.convertIntsToU16sOffset(
                allocator,
                d.indices,
                @as(u16, @intCast(total_vertex_num)),
            ));

            const vertex_num = d.xy.len;
            total_vertex_num += vertex_num;
            try vertex_data.ensureTotalCapacity(total_vertex_num);

            for (0..vertex_num) |i| {
                const position = d.xy[i];
                const uv = d.uv[i];
                const vertex = PositionTextureColorLayeredVertex{
                    .position = .{ position.x + offset[0], position.y + offset[1], 0 + offset[2] },
                    .uv = .{ uv.x, uv.y },
                    .color = .{ 255, 255, 255, 255 },
                    .layer = @intCast(total_font_texture_num),
                };
                try vertex_data.append(vertex);
                obj.gradientMin[0] = @min(obj.gradientMin[0], vertex.position[0]);
                obj.gradientMin[1] = @min(obj.gradientMin[1], vertex.position[1]);
                obj.gradientMax[0] = @max(obj.gradientMax[0], vertex.position[0]);
                obj.gradientMax[1] = @max(obj.gradientMax[1], vertex.position[1]);
            }

            total_font_texture_num += 1;
            try font_texture_data.ensureTotalCapacity(total_font_texture_num);
            try font_texture_data.append(d.atlas_texture);
        }

        obj.fontAtlasTexture = try device.createTexture(.{
            .texture_type = .two_dimensional_array,
            .format = .r8g8b8a8_unorm,
            .width = fontAtlasTextureSize,
            .height = fontAtlasTextureSize,
            .layer_count_or_depth = @as(u32, @intCast(total_font_texture_num)),
            .num_levels = 1,
            .usage = .{
                .sampler = true,
            },
        });
        errdefer device.releaseTexture(obj.fontAtlasTexture);

        const vertex_data_size: u32 = @intCast(total_vertex_num * @sizeOf(PositionTextureColorLayeredVertex));
        const index_data_size: u32 = @intCast(total_index_num * @sizeOf(u16));
        obj.index_buffer_len = @intCast(total_index_num);

        const aligned_vertex_size: usize = std.mem.alignForward(
            usize,
            vertex_data_size,
            @alignOf(u16),
        );

        obj.vertex_buffer = try device.createBuffer(.{
            .usage = .{ .vertex = true },
            .size = vertex_data_size,
        });
        errdefer device.releaseBuffer(obj.vertex_buffer);
        obj.index_buffer = try device.createBuffer(.{
            .usage = .{ .index = true },
            .size = index_data_size,
        });
        errdefer device.releaseBuffer(obj.index_buffer);

        const transfer_buffer = try device.createTransferBuffer(.{
            .usage = .upload,
            .size = @intCast(aligned_vertex_size + index_data_size),
        });
        defer device.releaseTransferBuffer(transfer_buffer);

        const raw_ptr: [*]u8 = @ptrCast(try device.mapTransferBuffer(transfer_buffer, false));
        const vertex_ptr: [*]PositionTextureColorLayeredVertex = @ptrCast(@alignCast(raw_ptr));
        const index_ptr: [*]u16 = @ptrCast(@alignCast(raw_ptr + aligned_vertex_size));
        std.mem.copyForwards(PositionTextureColorLayeredVertex, vertex_ptr[0..total_vertex_num], vertex_data.items);
        std.mem.copyForwards(u16, index_ptr[0..total_index_num], index_data.items);
        device.unmapTransferBuffer(transfer_buffer);

        // gradient texture
        const gradient_width: u32 = @intFromFloat(obj.gradientMax[0] - obj.gradientMin[0]);
        const gradient_raw = try make1DGradient(
            allocator,
            gradient_width,
            gradientColorLeft,
            gradientColorRight,
        );
        obj.gradientTexture = try device.createTexture(.{
            .texture_type = .two_dimensional,
            .format = .r8g8b8a8_unorm,
            .width = gradient_width,
            .height = 1,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .usage = .{
                .sampler = true,
            },
        });
        errdefer device.releaseTexture(obj.gradientTexture);

        const texture_transfer_buffer = try device.createTransferBuffer(.{
            .usage = .upload,
            .size = gradient_width * 4,
        });
        defer device.releaseTransferBuffer(texture_transfer_buffer);
        const texture_transfer_buffer_mapped = try device.mapTransferBuffer(
            texture_transfer_buffer,
            false,
        );
        @memcpy(texture_transfer_buffer_mapped, gradient_raw);
        device.unmapTransferBuffer(texture_transfer_buffer);

        // upload buf
        const upload_cmd_buf = try device.acquireCommandBuffer();
        const copy_pass = upload_cmd_buf.beginCopyPass();
        copy_pass.uploadToBuffer(
            .{
                .transfer_buffer = transfer_buffer,
                .offset = 0,
            },
            .{
                .buffer = obj.vertex_buffer,
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
                .buffer = obj.index_buffer,
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
                .texture = obj.gradientTexture,
                .width = gradient_width,
                .height = 1,
                .depth = 1,
            },
            false,
        );
        for (font_texture_data.items, 0..) |src_tex, layer_idx| {
            copy_pass.textureToTexture(
                sdl3.gpu.TextureLocation{
                    .mip_level = 0,
                    .texture = src_tex,
                    .layer = 0,
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                sdl3.gpu.TextureLocation{
                    .mip_level = 0,
                    .texture = obj.fontAtlasTexture,
                    .layer = @intCast(layer_idx),
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                fontAtlasTextureSize,
                fontAtlasTextureSize,
                0,
                false,
            );
        }
        std.debug.print("total_font_texture_num={d}\n", .{total_font_texture_num});

        copy_pass.end();
        try upload_cmd_buf.submit();

        return obj;
    }

    pub fn deinit(self: TextWithAnimatedGradient) void {
        self.device.releaseBuffer(self.vertex_buffer);
        self.device.releaseBuffer(self.index_buffer);
        self.device.releaseTexture(self.gradientTexture);
    }

    pub fn toFragmentUBO(self: TextWithAnimatedGradient, time: f32) FragGlobals {
        return FragGlobals{
            .gradientMin = .{ self.gradientMin[0], self.gradientMin[1], 0, 0 },
            .gradientMax = .{ self.gradientMax[0], self.gradientMax[1], 0, 0 },
            .time = time,
            .speed = self.gradientAnimationSpeed,
            .period = self.gradientAnimationPeriod,
        };
    }
};

pub const Fonts = struct {
    fonts: []sdl3.ttf.Font,
    fonts_num: usize,

    pub fn deinit(self: Fonts) void {
        for (0..self.fonts_num) |i| {
            self.fonts[i].deinit();
        }
    }
};

pub const Context = struct {
    device: sdl3.gpu.Device,
    window: sdl3.video.Window,
    textObjs: std.ArrayList(TextWithAnimatedGradient),
    smooth_edges_pipeline: sdl3.gpu.GraphicsPipeline = undefined,
    fill_pipeline: sdl3.gpu.GraphicsPipeline = undefined,
    // line_pipeline: sdl3.gpu.GraphicsPipeline = undefined,
    samplers: [sampler_names.len]sdl3.gpu.Sampler = undefined,
    fonts: []sdl3.ttf.Font = undefined,
    fontAtlasTextureSize: u32,
    fontFallback: sdl3.ttf.Font = undefined,
    textEngine: sdl3.ttf.GpuTextEngine,
    depthTexture: sdl3.gpu.Texture,
    samplers_idx: usize = 0,
    instances_num: u32 = 1,
    delta_time: f32 = 0,
    time: f32 = 0,
    quit: bool = false,
    t_toggle: bool = true,

    _allocator: *const std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: *const std.mem.Allocator,
        fontSizeRange: [2]u8,
        fontAtlasTextureSize: u32,
    ) !Self {
        const device = try sdl3.gpu.Device.init(
            .{ .spirv = true },
            true,
            null,
        );
        errdefer device.deinit();

        const window = try sdl3.video.Window.init(
            "hello sdl3",
            screen_width,
            screen_height,
            .{},
        );
        errdefer window.deinit();

        try device.claimWindow(window);

        const fonts_num: u8 = fontSizeRange[1] - fontSizeRange[0];
        var fonts = try allocator.alloc(sdl3.ttf.Font, fonts_num);
        errdefer allocator.free(fonts);

        const textEngine = try sdl3.ttf.GpuTextEngine.initWithProperties(.{
            .device = device,
            .atlas_texture_size = @as(i64, @intCast(fontAtlasTextureSize)),
        });

        std.debug.print("fontAtlasTextureSize: {d}\n", .{fontAtlasTextureSize});
        const font_path = "assets/fonts/SpaceMono/SpaceMono-Regular.ttf";
        const fontFallback = try sdl3.ttf.Font.init(
            font_path,
            24,
        );
        try fontFallback.setSdf(true);

        for (0..fonts_num) |i| {
            const font = try sdl3.ttf.Font.init(
                font_path,
                @floatFromInt(fontSizeRange[0] + i),
            );
            try font.setSdf(true);
            fonts[i] = font;
        }
        return .{
            .device = device,
            .window = window,
            .depthTexture = try device.createTexture(.{
                .texture_type = .two_dimensional,
                .format = .depth32_float,
                .width = screen_width,
                .height = screen_height,
                .layer_count_or_depth = 1,
                .num_levels = 1,
                .usage = .{
                    .depth_stencil_target = true,
                    .sampler = true,
                },
            }),
            .fonts = fonts,
            .fontAtlasTextureSize = fontAtlasTextureSize,
            .fontFallback = fontFallback,
            .textObjs = .init(allocator.*),
            .textEngine = textEngine,
            ._allocator = allocator,
        };
    }

    pub fn deinit(self: Context) void {
        for (self.textObjs.items) |t| t.deinit();
        self.textObjs.deinit();

        self.textEngine.deinit();

        self.device.releaseGraphicsPipeline(self.fill_pipeline);
        // self.device.releaseGraphicsPipeline(self.line_pipeline);
        for (self.samplers) |s| self.device.releaseSampler(s);
        self.device.releaseTexture(self.depthTexture);

        for (self.fonts) |*f| f.deinit();
        self._allocator.free(self.fonts);

        // try self.device.waitForIdle();
        self.device.releaseWindow(self.window);
        self.device.deinit();
        self.window.deinit();
    }
};

const FragGlobals = packed struct {
    gradientMin: @Vector(4, f32),
    gradientMax: @Vector(4, f32),
    time: f32,
    speed: f32,
    period: f32,
    _pad: f32 = 0,
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

pub fn makeOrthoProjMatrix(width: f32, height: f32) [16]f32 {
    return .{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        1.0,          0.0,  1.0,
    };
}

pub fn make1DGradient(
    allocator: std.mem.Allocator,
    width: u32,
    leftColor: sdl3.pixels.FColor,
    rightColor: sdl3.pixels.FColor,
) ![]const u8 {
    const buf_size: usize = @intCast(width * 4);
    var buffer = try allocator.alloc(u8, buf_size);
    for (0..width) |x| {
        const t: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width - 1));

        const r = leftColor.r + (rightColor.r - leftColor.r) * t;
        const g = leftColor.g + (rightColor.g - leftColor.g) * t;
        const b = leftColor.b + (rightColor.b - leftColor.b) * t;
        // const a = leftColor.a + (rightColor.a - leftColor.a) * t;
        const a = 1.0;

        const offset = x * 4;

        buffer[offset + 0] = @intFromFloat(std.math.clamp(r * 255.0, 0.0, 255.0));
        buffer[offset + 1] = @intFromFloat(std.math.clamp(g * 255.0, 0.0, 255.0));
        buffer[offset + 2] = @intFromFloat(std.math.clamp(b * 255.0, 0.0, 255.0));
        buffer[offset + 3] = @intFromFloat(std.math.clamp(a * 255.0, 0.0, 255.0));
    }
    return buffer;
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

pub fn createSamplers(ctx: *Context) !void {
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
}

pub fn fontShader(ctx: *Context, allocator: std.mem.Allocator) !sdl3.gpu.VertexInputState {
    const vertex_buffer_desc = [1]sdl3.gpu.VertexBufferDescription{
        .{
            .pitch = @sizeOf(PositionTextureColorLayeredVertex),
            .input_rate = .vertex,
            .slot = 0,
            .instance_step_rate = 0,
        },
    };

    const vertex_attributes = [4]sdl3.gpu.VertexAttribute{
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.f32x3,
            .offset = @offsetOf(PositionTextureColorLayeredVertex, "position"),
        },
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.f32x2,
            .offset = @offsetOf(PositionTextureColorLayeredVertex, "uv"),
        },
        .{
            .location = 2,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.u8x4_normalized,
            .offset = @offsetOf(PositionTextureColorLayeredVertex, "color"),
        },
        .{
            .location = 3,
            .buffer_slot = 0,
            .format = sdl3.gpu.VertexElementFormat.i32x1,
            .offset = @offsetOf(PositionTextureColorLayeredVertex, "layer"),
        },
    };

    try createSamplers(ctx);

    try ctx.textObjs.append(try TextWithAnimatedGradient.init(
        allocator,
        &ctx.device,
        ctx.textEngine,
        // ctx.fontFallback,
        ctx.fonts[40],
        ctx.fontAtlasTextureSize,
        "And awesome!",
        .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        .{ .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 },
        .{ 300, -50, 0.7 },
    ));
    try ctx.textObjs.append(try TextWithAnimatedGradient.init(
        allocator,
        &ctx.device,
        ctx.textEngine,
        // ctx.fontFallback,
        ctx.fonts[80],
        ctx.fontAtlasTextureSize,
        "Zig is cool!",
        .{ .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 },
        .{ .r = 0.0, .g = 1.0, .b = 1.0, .a = 1.0 },
        .{ 0, 0, 0.6 },
    ));

    return .{
        .vertex_buffer_descriptions = &vertex_buffer_desc,
        .vertex_attributes = &vertex_attributes,
    };
}

pub fn loadShaders(ctx: *Context, allocator: std.mem.Allocator) !void {
    const vert_shader = try loadShader(
        allocator,
        ctx.device,
        "assets/shaders/Font.vert.spv",
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
        .fragment,
        2,
        1,
        0,
        0,
    );
    defer ctx.device.releaseShader(frag_shader);
    const frag_smooth_shader = try loadShader(
        allocator,
        ctx.device,
        "assets/shaders/FontSmooth.frag.spv",
        .fragment,
        2,
        1,
        0,
        0,
    );
    defer ctx.device.releaseShader(frag_smooth_shader);

    const vertex_input_state = try fontShader(ctx, allocator);

    var pipeline_create_info = sdl3.gpu.GraphicsPipelineCreateInfo{
        .target_info = .{
            .color_target_descriptions = &.{
                .{
                    .format = ctx.device.getSwapchainTextureFormat(ctx.window),
                    .blend_state = .{
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
                        .enable_color_write_mask = false,
                    },
                },
            },
            .depth_stencil_format = .depth32_float,
        },
        .primitive_type = sdl3.gpu.PrimitiveType.triangle_list,
        .vertex_input_state = vertex_input_state,
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .depth_stencil_state = .{
            .enable_depth_test = true,
            .enable_depth_write = true,
            .compare = .less,
            .enable_stencil_test = false,
        },
    };
    ctx.fill_pipeline = try ctx.device.createGraphicsPipeline(pipeline_create_info);
    errdefer ctx.device.releaseGraphicsPipeline(ctx.fill_pipeline);

    pipeline_create_info.target_info.color_target_descriptions = &.{
        .{
            .format = ctx.device.getSwapchainTextureFormat(ctx.window),
            .blend_state = .{
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
            },
        },
    };

    // pipeline_create_info.target_info.color_target_descriptions[0].blend_state = .{
    //     .enable_blend = true,
    //     .source_color = .src_alpha,
    //     .destination_color = .one_minus_src_alpha,
    //     .color_blend = .add,
    //     .source_alpha = .one,
    //     .destination_alpha = .one_minus_src_alpha,
    //     .alpha_blend = .add,
    //     .color_write_mask = .{
    //         .alpha = true,
    //         .red = true,
    //         .blue = true,
    //         .green = true,
    //     },
    //     .enable_color_write_mask = true,
    // };
    pipeline_create_info.depth_stencil_state = .{
        .enable_depth_test = true,
        .enable_depth_write = false,
        .compare = .less,
        .enable_stencil_test = false,
    };
    pipeline_create_info.fragment_shader = frag_smooth_shader;
    ctx.smooth_edges_pipeline = try ctx.device.createGraphicsPipeline(pipeline_create_info);
    errdefer ctx.device.releaseGraphicsPipeline(ctx.smooth_edges_pipeline);

    // pipeline_create_info.rasterizer_state.fill_mode = .line;
    // ctx.line_pipeline = try ctx.device.createGraphicsPipeline(pipeline_create_info);
    // errdefer ctx.device.releaseGraphicsPipeline(ctx.line_pipeline);
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
    const proj_bytes: []const u8 = std.mem.asBytes(&proj);

    if (swapchain_texture.texture) |texture| {
        const render_pass = cmd_buf.beginRenderPass(
            &[_]sdl3.gpu.ColorTargetInfo{
                .{
                    .texture = texture,
                    .clear_color = COLOR_BLACK,
                    .load = .clear,
                    .store = .store,
                },
            },
            .{
                .texture = ctx.depthTexture,
                .load = .clear,
                .store = .store,
                .clear_depth = 1,
                .cycle = false,
                .stencil_load = .load,
                .stencil_store = .store,
                .clear_stencil = 0,
            },
        );
        defer render_pass.end();
        render_pass.bindGraphicsPipeline(ctx.fill_pipeline);

        cmd_buf.pushVertexUniformData(
            0,
            proj_bytes,
        );

        for (ctx.textObjs.items) |textObj| {
            render_pass.bindVertexBuffers(0, &.{.{
                .buffer = textObj.vertex_buffer,
                .offset = 0,
            }});

            render_pass.bindIndexBuffer(.{
                .buffer = textObj.index_buffer,
                .offset = 0,
            }, .indices_16bit);

            render_pass.bindFragmentSamplers(0, &.{.{
                .texture = textObj.fontAtlasTexture,
                .sampler = ctx.samplers[ctx.samplers_idx],
            }});
            render_pass.bindFragmentSamplers(1, &.{.{
                .texture = textObj.gradientTexture,
                .sampler = ctx.samplers[ctx.samplers_idx],
            }});
            cmd_buf.pushFragmentUniformData(
                0,
                std.mem.asBytes(&textObj.toFragmentUBO(ctx.time)),
            );

            render_pass.drawIndexedPrimitives(
                textObj.index_buffer_len,
                ctx.instances_num,
                0,
                0,
                0,
            );
            // render_pass.bindGraphicsPipeline(ctx.smooth_edges_pipeline);
            // render_pass.drawIndexedPrimitives(
            //     textObj.index_buffer_len,
            //     ctx.instances_num,
            //     0,
            //     0,
            //     0,
            // );
            // render_pass.bindGraphicsPipeline(ctx.fill_pipeline);
        }
    }

    try cmd_buf.submit();
}

pub fn main() !void {
    try ttf.main();
    return;
    // const log_app = sdl3.log.Category.application;
    // defer sdl3.shutdown();
    //
    // const init_flags = sdl3.InitFlags{
    //     .video = true,
    //     .audio = true,
    //     .events = true,
    // };
    //
    // try sdl3.init(init_flags);
    // defer sdl3.quit(init_flags);
    //
    // try sdl3.ttf.init();
    // defer sdl3.ttf.quit();
    //
    // std.log.info("Using SDL_ttf {d}.{d}.{d}", .{ sdl3.ttf.major_version, sdl3.ttf.minor_version, sdl3.ttf.micro_version });
    // std.log.info("Linked against SDL_ttf version: {}", .{sdl3.ttf.getVersion()});
    // std.debug.assert(sdl3.ttf.Version.atLeast(3, 0, 0));
    // const ft_version = sdl3.ttf.getFreeTypeVersion();
    // try log_app.logInfo("Using FreeType {d}.{d}.{d}", .{ ft_version.major, ft_version.minor, ft_version.patch });
    // const hb_version = sdl3.ttf.getHarfBuzzVersion();
    // try log_app.logInfo("Using HarfBuzz {d}.{d}.{d}", .{ hb_version.major, hb_version.minor, hb_version.patch });
    // std.debug.assert(sdl3.ttf.wasInit() > 0);
    //
    // const allocator = std.heap.smp_allocator;
    // var ctx = try Context.init(
    //     &allocator,
    //     .{ 10, 100 },
    //     1 << 12,
    // );
    // defer ctx.deinit();
    //
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    // try loadShaders(&ctx, arena.allocator());
    //
    // var fps_capper = sdl3.extras.FramerateCapper(f32){
    //     .mode = .{ .limited = fps },
    // };
    //
    // while (!ctx.quit) {
    //     ctx.delta_time = fps_capper.delay();
    //     ctx.time += ctx.delta_time;
    //
    //     pollEvents(&ctx);
    //     try draw(ctx);
    //
    //     std.debug.print("{}\n", .{fps_capper.frame_num});
    // }
}
