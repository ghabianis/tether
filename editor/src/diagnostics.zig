const std = @import("std");
const objc = @import("zig-objc");
const metal = @import("./metal.zig");
const math = @import("./math.zig");
const highlight = @import("./highlight.zig");
const cast = @import("./cast.zig");
const binary_search = @import("./binary_search.zig");
const Rope = @import("./rope.zig").Rope;

const print = std.debug.print;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Diagnostics = @This();

pipeline: metal.MTLRenderPipelineState,
time: f32,
vertices: [6]Vertex,
instances: std.ArrayList(Instance),
instance_buffer: metal.MTLBuffer,

const COLOR_IN = math.hex3("df5953");
const COLOR_OUT = math.float3(1.0, 0.0, 0.0);

pub fn init(alloc: Allocator, device: metal.MTLDevice, view: metal.MTKView) Diagnostics {
    var diagnostics = Diagnostics{
        .pipeline = undefined,
        .time = 0.0,
        .vertices = [6]Vertex{
            // top left
            .{
                .pos = math.float2(-1.0, 1.0),
            },
            // top right
            .{
                .pos = math.float2(
                    1.0,
                    1.0,
                ),
            },
            // bot right
            .{
                .pos = math.float2(1.0, -1.0),
            },

            // bot right
            .{
                .pos = math.float2(1.0, -1.0),
            },
            // bot left
            .{
                .pos = math.float2(-1.0, -1.0),
            },
            // top left
            .{
                .pos = math.float2(-1.0, 1.0),
            },
        },

        .instances = std.ArrayList(Instance).initCapacity(alloc, 1024 / @sizeOf(Instance)) catch @panic("OOM"),
        .instance_buffer = undefined,
    };

    diagnostics.build_pipeline(device, view);

    return diagnostics;
}

pub fn update(
    self: *Diagnostics, 
    frame_arena: *ArenaAllocator,
    rope: *Rope,
    errors: []highlight.ErrorRange, 
    vertices: []math.Vertex, 
    starting_y: f32,
    window_start_byte: u32, 
    window_end_byte: u32, 
    screen_size: math.Float2,
    ascent: f32,
    descent: f32,
    text_dirty: bool
) !void {
    if (!text_dirty) return;
    self.instances.clearRetainingCapacity();

    // TODO: PERF: Only need to calculate lines that are visible. Also, move this to build text geometry loop?
    // First calculate mapping of line range -> glyph baseline
    var line_baselines = std.ArrayList(LineBaseline).initCapacity(frame_arena.allocator(), rope.nodes.len) catch @panic("OOM");
    {
        var iter = rope.iter_lines(rope.nodes.first orelse return);
        var start: u32 = 0;
        var end: u32 = 0;
        var y = starting_y;
        while (iter.next()) |line_text| {
            end = start + @as(u32, @intCast(line_text.len));
            try line_baselines.append(.{
                .start = start,
                .end = end,
                .baseline = y,
            });
            start = end;
            y -= ascent + descent;
        }
    }


    const squiggly_height = 40.0;
    const baseline_offset = -10.0;
    const aspect = screen_size.x / screen_size.y;

    for (errors) |err| {
        var prev: ?*Instance = null;
        for (err.start..err.end) |i| {
            if (i < window_start_byte) continue;
            if (i >= window_end_byte) break;
            const vert_index = (i - window_start_byte) * 6 + 6;
            const end_vert_index = vert_index + 6;
            const verts = vertices[vert_index..end_vert_index];
            
            const dummy_baseline: LineBaseline = .{
                .start = @intCast(i),
                .end = 420,
                .baseline = 69.0,
            };
            
            const baseline_idx = binary_search.find_index(
                LineBaseline, 
                line_baselines.items, 
                &dummy_baseline, 
                Instance.cmp_linebase
            ) orelse @panic("UH OH!");

            const baseline = line_baselines.items[baseline_idx].baseline + baseline_offset;

            var tl_screen: math.Vertex = verts[0];
            var br_screen: math.Vertex = verts[4];
            tl_screen.pos.y = baseline + squiggly_height / 2.0;
            br_screen.pos.y = baseline - squiggly_height / 2.0;

            const tl = math.float2(tl_screen.pos.x, tl_screen.pos.y).screen_to_ndc_point(screen_size);
            const br = math.float2(br_screen.pos.x, br_screen.pos.y).screen_to_ndc_point(screen_size);

            const instance: Instance = .{
                .top = tl.y,
                .left = tl.x * aspect,
                .bot = br.y,
                .right = br.x * aspect,
            };

            if (prev) |prev_instance| {
                if (instance.top == prev_instance.top) {
                    self.instances.items[self.instances.items.len - 1].right = instance.right;
                }
            } else {
                try self.instances.append(instance);
            }
            prev = &self.instances.items[self.instances.items.len - 1];
        }
    }

    // for (self.instances.items) |ins| {
    //     ins.debug();
    // }

    print("ERRORS: {d}\n", .{self.instances.items.len});
    self.instance_buffer.update(Instance, self.instances.items, 0);
}

pub fn render(self: *Diagnostics, dt: f32, command_encoder: metal.MTLRenderCommandEncoder, render_pass_desc: objc.Object, width: f64, height: f64, color_attachment_desc: objc.Object, camera_matrix: *math.Float4x4) void {
    if (self.instances.items.len == 0) return;
    _ = render_pass_desc;
    _ = camera_matrix;
    self.time += dt;
    color_attachment_desc.setProperty("loadAction", metal.MTLLoadAction.load);

    const w: f32 = @floatCast(width);
    const h: f32 = @floatCast(height);
    
    const aspect = w / h;
    var ortho = math.Float4x4.ortho(-aspect, aspect, -1.0, 1.0, 0.001, 100.0);
    const uniforms: Uniforms = .{
        .projection_matrix = ortho,
        // .model_view_matrix = scale,
        // .model_view_matrix = camera_matrix.*,
        .model_view_matrix = math.Float4x4.scale_by(1.0),
        .color_in = Diagnostics.COLOR_IN,
        .color_out = Diagnostics.COLOR_OUT,
        .time = self.time,
    };

    // const command_encoder = command_buffer.new_render_command_encoder(render_pass_desc);
    // command_encoder.set_label("Diagnostics");
    command_encoder.set_viewport(metal.MTLViewport{ .origin_x = 0.0, .origin_y = 0.0, .width = width, .height = height, .znear = 0.1, .zfar = 100.0 });

    command_encoder.set_vertex_bytes(cast.bytes(&self.vertices), 0);
    command_encoder.set_vertex_buffer(self.instance_buffer, 0, 1);
    command_encoder.set_vertex_bytes(cast.bytes(&uniforms), 2);

    command_encoder.set_fragment_bytes(cast.bytes(&uniforms), 0);

    command_encoder.set_render_pipeline_state(self.pipeline);
    command_encoder.draw_primitives_instanced(.triangle, 0, 6, self.instances.items.len);
    // command_encoder.draw_indexed_primitives_instanced(.triangle, 6, .UInt16, self.index_buffer, 0, 1);
    // command_encoder.end_encoding();
}

fn build_pipeline(self: *Diagnostics, device: metal.MTLDevice, view: metal.MTKView) void {
    var err: ?*anyopaque = null;
    const shader_str = @embedFile("./shaders/squiggly.metal");
    const shader_nsstring = metal.NSString.new_with_bytes(shader_str, .utf8);
    defer shader_nsstring.release();

    const library = device.obj.msgSend(objc.Object, objc.sel("newLibraryWithSource:options:error:"), .{ shader_nsstring, @as(?*anyopaque, null), &err });
    metal.check_error(err) catch @panic("failed to build library");

    const func_vert = func_vert: {
        const str = metal.NSString.new_with_bytes(
            "vertex_main",
            .utf8,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_vert objc.Object.fromId(ptr.?);
    };

    const func_frag = func_frag: {
        const str = metal.NSString.new_with_bytes(
            "fragment_main",
            .utf8,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_frag objc.Object.fromId(ptr.?);
    };

    const vertex_desc = vertex_descriptor: {
        var desc = metal.MTLVertexDescriptor.alloc();
        desc = desc.init();
        desc.set_attribute(0, .{ .format = .float2, .offset = @offsetOf(Vertex, "pos"), .buffer_index = 0 });
        desc.set_layout(0, .{ .stride = @sizeOf(Vertex) });
        // desc.set_layout(1, .{ .stride = @sizeOf(Instance), .step_function = .PerInstance });
        break :vertex_descriptor desc;
    };

    const pipeline_desc = pipeline_desc: {
        var desc = metal.MTLRenderPipelineDescriptor.alloc();
        desc = desc.init();
        desc.set_vertex_function(func_vert);
        desc.set_fragment_function(func_frag);
        desc.set_vertex_descriptor(vertex_desc);
        break :pipeline_desc desc;
    };

    const attachments = objc.Object.fromId(pipeline_desc.obj.getProperty(?*anyopaque, "colorAttachments"));
    {
        const attachment = attachments.msgSend(
            objc.Object,
            objc.sel("objectAtIndexedSubscript:"),
            .{@as(c_ulong, 0)},
        );

        const pix_fmt = view.color_pixel_format();
        // Value is MTLPixelFormatBGRA8Unorm
        attachment.setProperty("pixelFormat", @as(c_ulong, pix_fmt));

        // Blending. This is required so that our text we render on top
        // of our drawable properly blends into the bg.
        attachment.setProperty("blendingEnabled", true);
        attachment.setProperty("rgbBlendOperation", @intFromEnum(metal.MTLBlendOperation.add));
        attachment.setProperty("alphaBlendOperation", @intFromEnum(metal.MTLBlendOperation.add));
        attachment.setProperty("sourceRGBBlendFactor", @intFromEnum(metal.MTLBlendFactor.source_alpha));
        attachment.setProperty("sourceAlphaBlendFactor", @intFromEnum(metal.MTLBlendFactor.source_alpha));
        attachment.setProperty("destinationRGBBlendFactor", @intFromEnum(metal.MTLBlendFactor.one_minus_source_alpha));
        attachment.setProperty("destinationAlphaBlendFactor", @intFromEnum(metal.MTLBlendFactor.one_minus_source_alpha));
    }

    const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");
    self.pipeline = pipeline;

    // Pre initialize 
    const initial_size = 1024 / @sizeOf(Instance);
    self.instance_buffer = device.new_buffer_with_length(@sizeOf(Instance) * initial_size, .storage_mode_managed) orelse @panic("OOM"); 
}

const Vertex = extern struct {
    pos: math.Float2 align(8),
};

const Instance = extern struct {
    top: f32,
    bot: f32,
    left: f32,
    right: f32,

    fn debug(self: Instance) void {
        print("INSTANCE: t={d} b={d} l={d} r={d}\n", .{self.top, self.bot, self.left, self.right});
    }

    fn cmp_linebase(search: *const LineBaseline, check: *const LineBaseline) binary_search.Order {
        if (search.start >= check.start and search.start < check.end) return .Equal;
        if (search.start < check.start) return .Less;
        return .Greater;
    }

    fn from_text_vertices(v: []const math.Vertex, idx: u32, screen_size: math.Float2, line_baselines: []const LineBaseline) Instance {
        const dummy_baseline: LineBaseline = .{
            .start = idx,
            .end = 420,
            .baseline = 69.0,
        };

        const baseline_idx = binary_search.find_index(
            LineBaseline, 
            line_baselines, 
            &dummy_baseline, 
            Instance.cmp_linebase
        ) orelse @panic("UH OH!");

        const squiggly_height = 40.0;
        const baseline_offset = -10.0;

        const baseline = line_baselines[baseline_idx].baseline + baseline_offset;

        var tl_screen: math.Vertex = v[0];
        var br_screen: math.Vertex = v[4];
        tl_screen.pos.y = baseline + squiggly_height / 2.0;
        br_screen.pos.y = baseline - squiggly_height / 2.0;

        const tl = math.float2(tl_screen.pos.x, tl_screen.pos.y).screen_to_ndc_point(screen_size);
        const br = math.float2(br_screen.pos.x, br_screen.pos.y).screen_to_ndc_point(screen_size);

        const aspect = screen_size.x / screen_size.y;
        return .{
            .top = tl.y,
            .left = tl.x * aspect,
            .bot = br.y,
            .right = br.x * aspect,
        };
    }
};

pub const Uniforms = extern struct { 
    model_view_matrix: math.Float4x4 align(16), 
    projection_matrix: math.Float4x4 align(16),
    color_in: math.Float3 align(16),
    color_out: math.Float3 align(16),
    time: f32 align(16),
};

const LineBaseline = struct { 
    start: u32, 
    end: u32, 
    baseline: f32,
};

