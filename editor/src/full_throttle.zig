const std = @import("std");
const metal = @import("./metal.zig");
const objc = @import("zig-objc");
const math = @import("math.zig");
const anim = @import("anim.zig");

const print = std.debug.print;
const ArrayList = std.ArrayListUnmanaged;
const ArenaAllocator = std.heap.ArenaAllocator;

const Scalar = math.Scalar;

const Vertex = extern struct {
    pos: math.Float2,
};

pub const Uniforms = extern struct { model_view_matrix: math.Float4x4, projection_matrix: math.Float4x4 };

const Particle = extern struct {
    color: math.Float4,
    offset: math.Float2,
    _pad: math.Float2,
};

const MAX_PARTICLES = 1024;

const opacity_frames: []const anim.ScalarTrack.Frame = &[_]anim.ScalarTrack.Frame{
                    .{
                        .time = 0.0, .value = Scalar.new(0.8), .in = Scalar.new(0.0), .out = Scalar.new(4.0)
                    },
                    .{
                        .time = 0.1, .value = Scalar.new(1.2), .in = Scalar.new(0.0), .out = Scalar.new(0.0)
                    },
                    .{
                        .time = 1.0, .value = Scalar.new(0.0), .in = Scalar.new(-4.0), .out = Scalar.new(0.0)
                    }
                };

pub const FullThrottleMode = struct {
    pipeline: metal.MTLRenderPipelineState,
    instance_buffer: metal.MTLBuffer,
    index_buffer: metal.MTLBuffer,
    vertices: [4]Vertex,
    indices: [6]u16,

    particles: [MAX_PARTICLES]Particle,
    opacity: anim.ScalarTrack,
    // velocity: [MAX_PARTICLES]anim.Float2Track,
    velocity: [MAX_PARTICLES]math.Float2,
    particles_count: u16,
    time: f32,

    pub fn init(device: metal.MTLDevice, view: metal.MTKView) FullThrottleMode {
        var full_throttle: FullThrottleMode = .{
            .pipeline = undefined,
            .instance_buffer = undefined,
            .index_buffer = undefined,
            .vertices = [4]Vertex{
                .{
                    .pos = math.float2(-1.0, 1.0),
                },
                .{
                    .pos = math.float2(
                        1.0,
                        1.0,
                    ),
                },
                .{
                    .pos = math.float2(1.0, -1.0),
                },
                .{
                    .pos = math.float2(-1.0, -1.0),
                },
            },
            .indices = [6]u16{
                0, // Top-left corner
                1, // Top-right corner
                2, // Bottom-right corner
                2, // Bottom-right corner
                3, // Bottom-left corner
                0, // Top-left corner
            },

            .particles = undefined,
            .velocity = undefined,
            .opacity = .{
                .frames = opacity_frames,
                .interp = .Cubic,
            },
            .particles_count = 0,
            .time = 0.0,
        };

        const RndGen = std.rand.DefaultPrng;
        var rnd = RndGen.init(0);

        const initial_particles = 128;
        full_throttle.particles_count = initial_particles;
        for (0..initial_particles) |i| {
            const anglex: f32 = rnd.random().float(f32) * 2.0 - 1.0;
            const angley: f32 = rnd.random().float(f32) * 2.0 - 1.0;
            const speed: f32 = rnd.random().float(f32) * 2.0;

            full_throttle.particles[i].offset = math.float2(0.0, 0.0);
            // full_throttle.particles[i].offset = math.float2(69.0, 69.0);
            full_throttle.particles[i].color = math.float4(11.0 / 255.0, 197.0 / 255.0, 230.0 / 255.0, 1.0);
            full_throttle.velocity[i] = math.float2(anglex * speed, angley * speed);
        }

        full_throttle.build_pipeline(device, view);

        return full_throttle;
    }

    pub fn update_instance_buffer(self: *FullThrottleMode, offset: usize, count: usize) void {
        const contents = self.instance_buffer.contents();
        @memcpy(@as([*]Particle, @ptrCast(@alignCast(contents)))[offset..count], self.particles[offset..count]);
        self.instance_buffer.did_modify_range(.{.location = offset, .length = count * @sizeOf(Particle) });
    }

    pub fn update(self: *FullThrottleMode, dt: f32) void {
        const new_opacity = self.opacity.sample(self.time + dt, false);
        for (0..self.particles_count) |i| {
            const p: *Particle = &self.particles[i];
            const dir: math.Float2 = self.velocity[i];
            p.offset = p.offset.add(dir.mul_f(1.0));
            if (i == 0) {
            }
            p.color.w = new_opacity.val;
        }
        self.update_instance_buffer(0, self.particles_count);
        self.time += dt;
    }

    pub fn build_pipeline(self: *FullThrottleMode, device: metal.MTLDevice, view: metal.MTKView) void {
        var err: ?*anyopaque = null;
        const shader_str = @embedFile("./FullThrottleShader.metal");
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
            desc.set_attribute(1, .{ .format = .float4, .offset = @offsetOf(Particle, "color"), .buffer_index = 1 });
            desc.set_attribute(2, .{ .format = .float2, .offset = @offsetOf(Particle, "offset"), .buffer_index = 1 });
            desc.set_layout(0, .{ .stride = @sizeOf(Vertex) });
            desc.set_layout(1, .{ .stride = @sizeOf(Particle), .step_function = .PerInstance });
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

        self.index_buffer = device.new_buffer_with_bytes(@as([*]const u8, @ptrCast(&self.indices))[0..@sizeOf([6]u16)], .storage_mode_managed);
        print("SIZE: {d} {d}\n", .{@sizeOf([MAX_PARTICLES]Particle), @sizeOf(Particle)});

        self.instance_buffer = device.new_buffer_with_bytes(@as([*]const u8, @ptrCast(&self.particles))[0..@sizeOf([MAX_PARTICLES]Particle)], .storage_mode_managed);
        // self.instance_buffer.did_modify_range(.{.location = 0, .length = @sizeOf([MAX_PARTICLES]Particle)});
    }

    fn model_matrix(side_length: f32, width: f32, height: f32) math.Float4x4 {
        const scale = side_length / @min(width, height);

        return math.Float4x4.new(
            math.float4(scale, 0.0, 0.0, 0.0),
            math.float4(0.0, scale, 0.0, 0.0),
            math.float4(0.0, 0.0, 1.0, 0.0),
            math.float4(0.0, 0.0, 1.0, 1.0),
        );

        // return math.Float4x4.new(
        //     math.float4(1.0, 0.0, 0.0, 0.0),
        //     math.float4(0.0, 1.0, 0.0, 0.0),
        //     math.float4(0.0, 0.0, 1.0, 0.0),
        //     math.float4(0.0, 0.0, 1.0, 1.0),
        // );
    }

    pub fn render(self: *FullThrottleMode, dt: f32, command_buffer: metal.MTLCommandBuffer, render_pass_desc: objc.Object, width: f64, height: f64) void {
        self.update(dt);
        const w: f32 = @floatCast(width);
        const h: f32 = @floatCast(height);
        
        const aspect = w / h;
        var toScreenSpaceMatrix2 = math.Float4x4.new(
            math.float4(w / 2, 0, 0, 0),
            math.float4(0, (h / 2), 0, 0),
            math.float4(0, 0, 1, 0),
            math.float4(w / 2, h / 2, 0, 1)
        );
        var scaleAspect = math.Float4x4.new(
            math.float4(0, 0, 0, 0),
            math.float4(0, aspect, 0, 0),
            math.float4(0, 0, 1, 0),
            math.float4(0, 0, 0, 1));
        _ = scaleAspect;
//         var toScreenSpaceMatrix = scaleAspect.mul(
//             &toScreenSpaceMatrix2
// );
        var toScreenSpaceMatrix = 
            toScreenSpaceMatrix2;
        // var ortho = math.Float4x4.ortho(0.0, w, 0.0, h, 0.1, 100.0);
        var ortho = math.Float4x4.ortho(-aspect, aspect, -1.0, 1.0, 0.001, 100.0);
        const origin = math.float4(-1.0, 0.0, 0.0, 1.0);
        const p = toScreenSpaceMatrix.mul_f4(origin);
        _ = p;
        var scale = math.Float4x4.scale_by(0.05);
        _ = scale;
        const uniforms: Uniforms = .{
            .projection_matrix = ortho,
            // .model_view_matrix = scale,
            .model_view_matrix = FullThrottleMode.model_matrix(16, w, h),
        };

        const command_encoder = command_buffer.new_render_command_encoder(render_pass_desc);
        command_encoder.set_viewport(metal.MTLViewport{ .origin_x = 0.0, .origin_y = 0.0, .width = width, .height = height, .znear = 0.1, .zfar = 100.0 });

        command_encoder.set_vertex_bytes(@as([*]const u8, @ptrCast(&self.vertices))[0..@sizeOf([4]Vertex)], 0);
        command_encoder.set_vertex_buffer(self.instance_buffer, 0, 1);
        command_encoder.set_vertex_bytes(@as([*]const u8, @ptrCast(&uniforms))[0..@sizeOf(Uniforms)], 2);

        command_encoder.set_render_pipeline_state(self.pipeline);
        command_encoder.draw_indexed_primitives_instanced(.triangle, 6, .UInt16, self.index_buffer, 0, self.particles_count);
        command_encoder.end_encoding();
    }
};
