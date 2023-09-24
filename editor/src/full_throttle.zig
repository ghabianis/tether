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


const opacity_frames: []const anim.ScalarTrack.Frame = &[_]anim.ScalarTrack.Frame{
                    .{
                        .time = 0.0, .value = Scalar.new(0.8), .in = Scalar.new(0.0), .out = Scalar.new(4.0)
                    },
                    .{
                        .time = 0.05, .value = Scalar.new(1.0), .in = Scalar.new(0.0), .out = Scalar.new(0.0)
                    },
                    .{
                        .time = 0.6, .value = Scalar.new(0.0), .in = Scalar.new(-0.5), .out = Scalar.new(0.0)
                        // .time = 2.6, .value = Scalar.new(0.0), .in = Scalar.new(-0.5), .out = Scalar.new(0.0)
                    }
                };

const velocity_factor_frames: []const anim.ScalarTrack.Frame = &[_]anim.ScalarTrack.Frame{
        .{
            .time = 0.0, .value = Scalar.new(2), .in = Scalar.new(8.0), .out = Scalar.new(8.0),
        },
        .{
            .time = 0.03, .value = Scalar.new(6), .in = Scalar.new(1), .out = Scalar.new(1),
        },
        .{
            .time = 0.1, .value = Scalar.new(1), .in = Scalar.new(1), .out = Scalar.new(1),
        },
        .{
            .time = 0.5, .value = Scalar.default(), .in = Scalar.new(-3.0), .out = Scalar.default()
        } 
};

const screen_shake_frames: []const anim.ScalarTrack.Frame = &[_]anim.ScalarTrack.Frame{
        .{
            .time = 0.0, .value = Scalar.new(1.0), .in = Scalar.new(0.0), .out = Scalar.new(4.0)
        },
        .{
            .time = 0.05, .value = Scalar.new(4.0), .in = Scalar.new(0.0), .out = Scalar.new(0.0)
        },
        .{
            .time = 0.2, .value = Scalar.new(0.0), .in = Scalar.new(-2.5), .out = Scalar.new(0.0)
        }
};


const MAX_CLUSTER_PARTICLE_AMOUNT = 128;
const MAX_CLUSTERS = 100;
const MAX_PARTICLES = MAX_CLUSTER_PARTICLE_AMOUNT * MAX_CLUSTERS;
pub const ParticleCluster = struct {
    time: f32,
    buf:  *align(8) Buf,

    pub const Buf = struct {
        particles: [MAX_CLUSTER_PARTICLE_AMOUNT]Particle,
        velocity: [MAX_CLUSTER_PARTICLE_AMOUNT]math.Float2
    };
};


const RndGen = std.rand.DefaultPrng;
pub var rnd = RndGen.init(0);

// const ClusterBufPool = std.heap.MemoryPool(ParticleCluster.Buf);
const ClusterBufPool = std.heap.MemoryPoolExtra(ParticleCluster.Buf, .{ .alignment = @alignOf(ParticleCluster.Buf), .growable = false });

pub const FullThrottleMode = struct {
    pipeline: metal.MTLRenderPipelineState,
    instance_buffer: metal.MTLBuffer,
    index_buffer: metal.MTLBuffer,
    vertices: [4]Vertex,
    indices: [6]u16,

    cluster_buf_pool: ClusterBufPool,
    clusters: [MAX_CLUSTERS]ParticleCluster,
    clusters_len: u8,
    opacity: anim.ScalarTrack,
    velocity_factor: anim.ScalarTrack,
    screen_shake: anim.ScalarTrack,
    screen_shake_matrix: math.Float4x4,
    screen_shake_matrix_ndc: math.Float4x4,
    time: f32,


    pub fn init(device: metal.MTLDevice, view: metal.MTKView) FullThrottleMode {
        var full_throttle: FullThrottleMode = .{
            .pipeline = undefined,
            .instance_buffer = undefined,
            .index_buffer = undefined,
            .vertices = [4]Vertex{
                .{
                    .pos = math.float2(-0.006, 0.006),
                },
                .{
                    .pos = math.float2(
                        0.006,
                        0.006,
                    ),
                },
                .{
                    .pos = math.float2(0.006, -0.006),
                },
                .{
                    .pos = math.float2(-0.006, -0.006),
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

            .cluster_buf_pool = ClusterBufPool.initPreheated(std.heap.c_allocator, MAX_CLUSTERS) catch @panic("OOM"),
            .clusters = undefined,
            .clusters_len = 0,
            .opacity = .{
                .frames = opacity_frames,
                .interp = .Cubic,
            },
            .velocity_factor = .{
                .frames = velocity_factor_frames,
                .interp = .Cubic,
            },
            .screen_shake = .{
                .frames = screen_shake_frames,
                .interp = .Cubic,
            },
            .screen_shake_matrix = math.Float4x4.scale_by(1.0),
            .screen_shake_matrix_ndc = math.Float4x4.scale_by(1.0),
            // initialize to something very large so animation doesn't trigger on startup
            .time = 10000.0,
        };

        full_throttle.build_pipeline(device, view);
        
        return full_throttle;
    }

    pub fn update_instance_buffer(self: *FullThrottleMode, offset: usize, particles: *const [MAX_CLUSTER_PARTICLE_AMOUNT]Particle) void {
        const contents = self.instance_buffer.contents();
        @memcpy(@as([*]Particle, @ptrCast(@alignCast(contents)))[offset..offset + particles.len], particles[0..]);
        self.instance_buffer.did_modify_range(.{.location = offset, .length = particles.len * @sizeOf(Particle) });
    }

    pub fn remove_cluster(self: *FullThrottleMode, idx: u8) void {
        if (self.clusters_len == 0) return;
        const swap_idx = self.clusters_len - 1;
        const buf = self.clusters[idx].buf;
        self.cluster_buf_pool.destroy(buf);
        self.clusters[idx] = self.clusters[swap_idx];
        self.clusters_len -= 1;
    }

    pub fn add_cluster(self: *FullThrottleMode, offset_screen: math.Float2, w: f32, h: f32) void {
        self.time = 0;
        const aspect = w / h;
        var offset = math.float2((offset_screen.x - w * 0.5) / (w * 0.5), (offset_screen.y - h * 0.5) / (h * 0.5));
        offset.x *= aspect;

        const idx = self.clusters_len;
        if (idx == MAX_CLUSTERS) @panic("Max clusters exceeded");
        self.clusters_len += 1;
        var cluster: *ParticleCluster = &self.clusters[idx];
        cluster.time = 0;
        cluster.buf = self.cluster_buf_pool.create() catch @panic("OOM");

        const PARTICLE_SHAPE_CIRCLE = false;
        
        // const offsetx: f32 = rnd.random().float(f32) * 2.0 - 1.0;
        // const offsety: f32 = rnd.random().float(f32) * 2.0 - 1.0;
        for (0..MAX_CLUSTER_PARTICLE_AMOUNT) |i| {
            const anglex: f32 = rnd.random().float(f32) * 2.0 - 1.0;
            const angley: f32 = rnd.random().float(f32) * 2.0 - 1.0;
            const speed: f32 = rnd.random().float(f32) * 2.0;
            _ = speed;

            if (comptime PARTICLE_SHAPE_CIRCLE) {
                const variance = math.float2((rnd.random().float(f32) * 2.0 - 1.0) * 0.1, (rnd.random().float(f32) * 2.0 - 1.0) * 0.1);
                const dir = math.float2(anglex, angley).norm().add(variance).mul_f(0.005);
                cluster.buf.velocity[i] = dir;
            } else {
                const dir = math.float2(anglex, angley).mul_f(0.01);
                cluster.buf.velocity[i] = dir;
            }
            cluster.buf.particles[i].offset = math.float2(offset.x, offset.y);
            cluster.buf.particles[i].color = math.float4(11.0 / 255.0, 197.0 / 255.0, 230.0 / 255.0, 1.0);
        }
    }

    pub fn compute_shake(self: *FullThrottleMode, dt: f32, w: f32, h: f32) void {
        self.time += dt;
        const intensity: f32 = self.screen_shake.sample(self.time, false).val;
        var shake_dir = math.float3((rnd.random().float(f32) * 2.0 - 1.0), (rnd.random().float(f32) * 2.0 - 1.0), 0);
        shake_dir = shake_dir.norm().mul_f(intensity);
        self.screen_shake_matrix = math.Float4x4.translation_by(shake_dir);

        // const aspect = w / h;
        // var shake_dir_ndc = math.float3((shake_dir.x - w * 0.5) / (w * 0.5), (shake_dir.y - h * 0.5) / (h * 0.5), 0);
        var shake_dir_ndc = shake_dir;
        shake_dir_ndc.x /= w;
        shake_dir_ndc.y /= h;
        self.screen_shake_matrix_ndc = math.Float4x4.translation_by(shake_dir_ndc);
    }

    pub fn update(self: *FullThrottleMode, dt: f32) void {
        for (self.clusters[0..self.clusters_len], 0..) |*c_, ci| {
            var cluster: *ParticleCluster = c_;
            const new_opacity = self.opacity.sample(cluster.time + dt, false);
            const new_factor = self.velocity_factor.sample(cluster.time + dt, false);
            for (&cluster.buf.particles, 0..) |*p_, i| {
                const p: *Particle = p_;
                const vel = &cluster.buf.velocity[i];
                p.offset = p.offset.add(vel.mul_f(new_factor.val));
                p.color.w = new_opacity.val;
            }
            self.update_instance_buffer(ci * MAX_CLUSTER_PARTICLE_AMOUNT, &cluster.buf.particles);
            cluster.time += dt;
            if (new_opacity.val <= 0.0) {
                self.remove_cluster(@intCast(ci));
            }
        }
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

        self.instance_buffer = device.new_buffer_with_length(@sizeOf([MAX_CLUSTER_PARTICLE_AMOUNT]Particle) * MAX_CLUSTERS, .storage_mode_managed) orelse @panic("OOM"); 
    }

    fn model_matrix(self: *FullThrottleMode, side_length: f32, width: f32, height: f32) math.Float4x4 {
        const scale = side_length / @min(width, height);
        _ = scale;

        // return math.Float4x4.new(
        //     math.float4(scale, 0.0, 0.0, 0.0),
        //     math.float4(0.0, scale, 0.0, 0.0),
        //     math.float4(0.0, 0.0, 1.0, 0.0),
        //     math.float4(0.0, 0.0, 1.0, 1.0),
        // );

        // return math.Float4x4.scale_by(0.02);
        // return math.Float4x4.scale_by(1.0);
        return self.screen_shake_matrix_ndc;
        // return math.Float4x4.new(
        //     math.float4(0.01, 0.0, 0.0, 0.0),
        //     math.float4(0.0, 0.01, 0.0, 0.0),
        //     math.float4(0.0, 0.0, 0.01, 0.0),
        //     math.float4(0.0, 0.0, 1.0, 0.01),
        // );
    }

    pub fn render(self: *FullThrottleMode, dt: f32, command_buffer: metal.MTLCommandBuffer, render_pass_desc: objc.Object, width: f64, height: f64) void {
        self.update(dt);
        if (self.clusters_len == 0) {
            return;
        }
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
            .model_view_matrix = self.model_matrix(4, w, h),
        };

        const command_encoder = command_buffer.new_render_command_encoder(render_pass_desc);
        command_encoder.set_viewport(metal.MTLViewport{ .origin_x = 0.0, .origin_y = 0.0, .width = width, .height = height, .znear = 0.1, .zfar = 100.0 });

        command_encoder.set_vertex_bytes(@as([*]const u8, @ptrCast(&self.vertices))[0..@sizeOf([4]Vertex)], 0);
        command_encoder.set_vertex_buffer(self.instance_buffer, 0, 1);
        command_encoder.set_vertex_bytes(@as([*]const u8, @ptrCast(&uniforms))[0..@sizeOf(Uniforms)], 2);

        command_encoder.set_render_pipeline_state(self.pipeline);
        command_encoder.draw_indexed_primitives_instanced(.triangle, 6, .UInt16, self.index_buffer, 0, @as(usize, self.clusters_len) * MAX_CLUSTER_PARTICLE_AMOUNT);
        command_encoder.end_encoding();
    }
};
