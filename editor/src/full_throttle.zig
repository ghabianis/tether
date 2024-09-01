const std = @import("std");
const metal = @import("./metal.zig");
const objc = @import("zig-objc");
const math = @import("math.zig");
const anim = @import("anim.zig");
const mempool = @import("./memory_pool.zig");
const cast = @import("./cast.zig");

const print = std.debug.print;
const ArrayList = std.ArrayListUnmanaged;
const ArenaAllocator = std.heap.ArenaAllocator;

const Scalar = math.Scalar;

const Vertex = extern struct {
    pos: math.Float2,
};

pub const Uniforms = extern struct { model_view_matrix: math.Float4x4, projection_matrix: math.Float4x4 };

// 16 alignment
const Particle = extern struct {
    color: math.Float4 align(16),
    offset: math.Float2,
};

const opacity_frames: []const anim.ScalarTrack.Frame = &[_]anim.ScalarTrack.Frame{
    .{ .time = 0.0, .value = Scalar.new(0.8), .in = Scalar.new(0.0), .out = Scalar.new(4.0) },
    .{ .time = 0.05, .value = Scalar.new(1.0), .in = Scalar.new(0.0), .out = Scalar.new(0.0) },
    .{
        .time = 0.6,
        .value = Scalar.new(0.0),
        .in = Scalar.new(-0.5),
        .out = Scalar.new(0.0),
        // .time = 2.6, .value = Scalar.new(0.0), .in = Scalar.new(-0.5), .out = Scalar.new(0.0)
    },
};

const velocity_factor_frames: []const anim.ScalarTrack.Frame = &[_]anim.ScalarTrack.Frame{ .{
    .time = 0.0,
    .value = Scalar.new(2),
    .in = Scalar.new(8.0),
    .out = Scalar.new(8.0),
}, .{
    .time = 0.03,
    .value = Scalar.new(6),
    .in = Scalar.new(1),
    .out = Scalar.new(1),
}, .{
    .time = 0.1,
    .value = Scalar.new(1),
    .in = Scalar.new(1),
    .out = Scalar.new(1),
}, .{ .time = 0.5, .value = Scalar.default(), .in = Scalar.new(-3.0), .out = Scalar.default() } };

const screen_shake_frames: []const anim.ScalarTrack.Frame = &[_]anim.ScalarTrack.Frame{ .{ .time = 0.0, .value = Scalar.new(1.0), .in = Scalar.new(0.0), .out = Scalar.new(4.0) }, .{ .time = 0.05, .value = Scalar.new(4.0), .in = Scalar.new(0.0), .out = Scalar.new(0.0) }, .{ .time = 0.2, .value = Scalar.new(0.0), .in = Scalar.new(-2.5), .out = Scalar.new(0.0) } };

const MAX_CLUSTER_PARTICLE_AMOUNT = 128;
const MAX_CLUSTERS = 99;
const MAX_PARTICLES = MAX_CLUSTER_PARTICLE_AMOUNT * MAX_CLUSTERS;
pub const ParticleCluster = struct {
    time: f32,
    buf: *align(16) Buf,

    pub const Buf = struct { particles: [MAX_CLUSTER_PARTICLE_AMOUNT]Particle, velocity: [MAX_CLUSTER_PARTICLE_AMOUNT]math.Float2 };
};

pub const Explosions = struct {
    buf: *align(16) Buf,
    len: u8,
    // times: [MAX_CLUSTER_PARTICLE_AMOUNT]f32,
    pub const Buf = struct {
        explosions: [MAX_CLUSTER_PARTICLE_AMOUNT]Explosion,
    };
};

pub const UnifiedBuf = union {
    explosion: Explosions.Buf,
    particle: ParticleCluster.Buf,
};

comptime {
    std.debug.assert(@alignOf(Explosion) == @alignOf(Particle));
    // @compileLog("SIZE", @sizeOf(Explosion), @sizeOf(Particle));
}

// 16 byte alignment
pub const Explosion = extern struct {
    pos: math.Float2 align(16),
    tex: math.Float2,
    time: f32 = 0.0,
};

const TEXTURE_DIMENSION = math.float2(1000, 100);

const RndGen = std.rand.DefaultPrng;
pub var rnd = RndGen.init(0);

const ClusterBufPool = std.heap.MemoryPool(UnifiedBuf);
// for some reason this causes a segfault in zig build:
// const ClusterBufPool = mempool.MemoryPoolExtra(UnifiedBuf, .{ .alignment = @alignOf(UnifiedBuf), .growable = false });

pub const FullThrottleMode = struct {
    pipeline: metal.MTLRenderPipelineState,
    // First bytes (@sizeOf(Explosion)
    instance_buffer: metal.MTLBuffer,
    index_buffer: metal.MTLBuffer,
    vertices: [4]Vertex,
    indices: [6]u16,

    explosion_pipeline: metal.MTLRenderPipelineState,
    explosion_texture: metal.MTLTexture,
    explosion_sampler_state: objc.Object,
    explosion_vertices: [6]Explosion,

    // the first is always reserved for explosions
    cluster_buf_pool: ClusterBufPool,
    clusters: [MAX_CLUSTERS]ParticleCluster,
    clusters_len: u8,
    opacity: anim.ScalarTrack,
    velocity_factor: anim.ScalarTrack,

    explosions: Explosions,
    fire: Fire,

    screen_shake: anim.ScalarTrack,
    screen_shake_matrix: math.Float4x4,
    screen_shake_matrix_ndc: math.Float4x4,
    time: f32,

    const INSTANCEBUF_EXPLOSION_START = 0.0;
    const INSTANCEBUF_PARTICLE_START = @sizeOf(Explosion) * MAX_CLUSTER_PARTICLE_AMOUNT;

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

            .explosion_pipeline = undefined,

            .cluster_buf_pool = ClusterBufPool.initPreheated(std.heap.c_allocator, MAX_CLUSTERS + 1) catch @panic("OOM"),
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

            .explosions = undefined,
            .explosion_texture = undefined,
            .explosion_sampler_state = undefined,
            .explosion_vertices = [6]Explosion{
                // top-left
                .{
                    .pos = math.float2(-0.35, 0.35),
                    .tex = math.float2(0.0, 0.0).div(TEXTURE_DIMENSION),
                },
                // top-right
                .{
                    .pos = math.float2(
                        0.35,
                        0.35,
                    ),
                    .tex = math.float2(100.0, 0.0).div(TEXTURE_DIMENSION),
                },
                // bot-right
                .{
                    .pos = math.float2(0.35, -0.35),
                    .tex = math.float2(100.0, 100.0).div(TEXTURE_DIMENSION),
                },

                // bot-right
                .{
                    .pos = math.float2(0.35, -0.35),
                    .tex = math.float2(100.0, 100.0).div(TEXTURE_DIMENSION),
                },
                // bot-left
                .{
                    .pos = math.float2(-0.35, -0.35),
                    .tex = math.float2(0.0, 100.0).div(TEXTURE_DIMENSION),
                },
                // top-left
                .{
                    .pos = math.float2(-0.35, 0.35),
                    .tex = math.float2(0.0, 0.0).div(TEXTURE_DIMENSION),
                },
            },

            .screen_shake = .{
                .frames = screen_shake_frames,
                .interp = .Cubic,
            },
            .screen_shake_matrix = math.Float4x4.scale_by(1.0),
            .screen_shake_matrix_ndc = math.Float4x4.scale_by(1.0),
            // initialize to something very large so animation doesn't trigger on startup
            .time = 10000.0,

            .fire = Fire.init(device, view, 10000),
        };

        full_throttle.explosions = .{
            .buf = @ptrCast(full_throttle.cluster_buf_pool.create() catch @panic("OOM")),
            .len = 0,
            // .times = undefined,
        };

        full_throttle.build_particles_pipeline(device, view);
        full_throttle.build_explosions_pipeline(device, view);

        return full_throttle;
    }

    pub fn update_instance_buffer_particle(self: *FullThrottleMode, offset: usize, particles: *const [MAX_CLUSTER_PARTICLE_AMOUNT]Particle) void {
        const contents = self.instance_buffer.contents();
        const start_byte = INSTANCEBUF_PARTICLE_START;
        const contents_particles = @as([*]Particle, @ptrCast(@alignCast(contents + start_byte)));
        @memcpy(contents_particles[offset .. offset + particles.len], particles[0..]);
        self.instance_buffer.did_modify_range(.{ .location = start_byte + offset * @sizeOf(Particle), .length = particles.len * @sizeOf(Particle) });
    }

    pub fn update_instance_buffer_explosion(self: *FullThrottleMode) void {
        const contents = self.instance_buffer.contents();
        const contents_explosions = @as([*]Explosion, @ptrCast(@alignCast(contents)));
        @memcpy(contents_explosions[0..self.explosions.len], self.explosions.buf.explosions[0..self.explosions.len]);
        const byte_length = @sizeOf(Explosion) * @as(usize, self.explosions.len);
        self.instance_buffer.did_modify_range(.{ .location = 0, .length = byte_length });
    }

    pub fn remove_cluster(self: *FullThrottleMode, idx: u8) void {
        if (self.clusters_len == 1) return;
        const swap_idx = self.clusters_len - 1;
        const buf = self.clusters[idx].buf;
        self.cluster_buf_pool.destroy(@ptrCast(buf));
        self.clusters[idx] = self.clusters[swap_idx];
        self.clusters_len -= 1;
    }

    pub fn remove_explosion(self: *FullThrottleMode, idx: u8) void {
        if (self.explosions.len == 0) return;
        const swap_idx = self.explosions.len - 1;
        self.explosions.buf.explosions[idx] = self.explosions.buf.explosions[swap_idx];
        self.explosions.len -= 1;
    }

    pub fn add_explosion(self: *FullThrottleMode, offset_screen: math.Float2, w: f32, h: f32) void {
        if (self.explosions.len == MAX_CLUSTER_PARTICLE_AMOUNT) @panic("OOM");
        self.time = 0;
        const aspect = w / h;
        var offset = math.float2((offset_screen.x - w * 0.5) / (w * 0.5), (offset_screen.y - h * 0.5) / (h * 0.5));
        offset.x *= aspect;

        const idx = self.explosions.len;
        var explosion: *Explosion = &self.explosions.buf.explosions[idx];
        self.explosions.len += 1;
        explosion.pos = math.float2(offset.x, offset.y);
        // self.explosions.times[idx] = 0.0;
        explosion.time = 0.0;
        explosion.tex = math.float2(1000.0, 1000.0);
    }

    pub fn add_cluster(self: *FullThrottleMode, offset_screen: math.Float2, w: f32, h: f32) void {
        self.time = 0;
        const aspect = w / h;
        var offset = math.float2(
            // (offset_screen.x - w * 0.5) / (w * 0.5),
            // (offset_screen.y - h * 0.5) / (h * 0.5),
            (offset_screen.x - w * 0.5) / (w * 0.5),
            (offset_screen.y - h * 0.5) / (h * 0.5),
        );
        offset.x *= aspect;

        const idx = self.clusters_len;
        if (idx == MAX_CLUSTERS) @panic("Max clusters exceeded");
        self.clusters_len += 1;
        var cluster: *ParticleCluster = &self.clusters[idx];
        cluster.time = 0;
        cluster.buf = @ptrCast(@alignCast(self.cluster_buf_pool.create() catch @panic("OOM")));

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
            self.update_instance_buffer_particle(ci * MAX_CLUSTER_PARTICLE_AMOUNT, &cluster.buf.particles);
            cluster.time += dt;
            if (new_opacity.val <= 0.0) {
                self.remove_cluster(@intCast(ci));
            }
        }
        // for (self.clusters[0..self.clusters_len], 0..) |*c_,ci| {

        // }

        var i: usize = 0;
        const EXPLOSION_DURATION: f32 = 0.5;
        const EXPLOSION_SPRITE_COUNT: f32 = 10.0;
        while (i < self.explosions.len) {
            var explosion: *Explosion = &self.explosions.buf.explosions[i];
            const time = explosion.time;
            // const time = self.explosions.times[i];
            explosion.time += dt;
            const sprite_idx = @floor(time / (EXPLOSION_DURATION / EXPLOSION_SPRITE_COUNT));
            explosion.tex.y = 0;
            explosion.tex.x = @min(1.0, (sprite_idx * 100.0) / TEXTURE_DIMENSION.x);
            if (explosion.time > EXPLOSION_DURATION) {
                self.remove_explosion(@intCast(i));
            } else {
                i += 1;
            }
        }
        if (self.explosions.len > 0) {
            self.update_instance_buffer_explosion();
        }
    }

    pub fn build_explosions_pipeline(self: *FullThrottleMode, device: metal.MTLDevice, view: metal.MTKView) void {
        var err: ?*anyopaque = null;
        const shader_str = @embedFile("./shaders/explosion.metal");
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
            desc.set_attribute(0, .{ .format = .float2, .offset = @offsetOf(Explosion, "pos"), .buffer_index = 0 });
            desc.set_attribute(1, .{ .format = .float2, .offset = @offsetOf(Explosion, "tex"), .buffer_index = 0 });
            desc.set_attribute(2, .{ .format = .float2, .offset = @offsetOf(Explosion, "pos"), .buffer_index = 1 });
            desc.set_attribute(3, .{ .format = .float2, .offset = @offsetOf(Explosion, "tex"), .buffer_index = 1 });
            desc.set_layout(0, .{ .stride = @sizeOf(Explosion) });
            desc.set_layout(1, .{ .stride = @sizeOf(Explosion), .step_function = .PerInstance });
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

        pipeline_desc.set_label("Explosions");
        const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");
        self.explosion_pipeline = pipeline;

        const sprite_sheet_raw = @embedFile("./assets/spritesheet.png");
        const sprite_sheet = metal.NSData.new_with_bytes_no_copy(sprite_sheet_raw[0..], false);
        const tex_opts = metal.NSDictionary.new_mutable();
        tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_enum(metal.MTLTextureUsage.shader_read), metal.MTKTextureLoaderOptionTextureUsage });
        tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_enum(metal.MTLStorageMode.private), metal.MTKTextureLoaderOptionTextureStorageMode });
        tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_int(0), metal.MTKTextureLoaderOptionSRGB });

        const tex_loader_class = objc.getClass("MTKTextureLoader").?;
        var tex_loader = tex_loader_class.msgSend(objc.Object, objc.sel("alloc"), .{});
        tex_loader = tex_loader.msgSend(objc.Object, objc.sel("initWithDevice:"), .{device});

        const tex = tex_loader.msgSend(objc.Object, objc.sel("newTextureWithData:options:error:"), .{
            sprite_sheet,
            tex_opts,
        });
        metal.check_error(err) catch @panic("failed to make texture");
        self.explosion_texture = metal.MTLTexture.from_obj(tex);

        const sampler_descriptor = objc.getClass("MTLSamplerDescriptor").?.msgSend(objc.Object, objc.sel("alloc"), .{}).msgSend(objc.Object, objc.sel("init"), .{});
        sampler_descriptor.setProperty("minFilter", metal.MTLSamplerMinMagFilter.linear);
        sampler_descriptor.setProperty("magFilter", metal.MTLSamplerMinMagFilter.linear);
        sampler_descriptor.setProperty("sAddressMode", metal.MTLSamplerAddressMode.ClampToZero);
        sampler_descriptor.setProperty("tAddressMode", metal.MTLSamplerAddressMode.ClampToZero);

        const sampler_state = device.new_sampler_state(sampler_descriptor);
        self.explosion_sampler_state = sampler_state;
    }

    pub fn build_particles_pipeline(self: *FullThrottleMode, device: metal.MTLDevice, view: metal.MTKView) void {
        var err: ?*anyopaque = null;
        const shader_str = @embedFile("./shaders/particle.metal");
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

        pipeline_desc.set_label("Particles");
        const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");
        self.pipeline = pipeline;

        self.index_buffer = device.new_buffer_with_bytes(@as([*]const u8, @ptrCast(&self.indices))[0..@sizeOf([6]u16)], .storage_mode_managed);

        const instance_buffer_size = @sizeOf([MAX_CLUSTER_PARTICLE_AMOUNT]Explosion) + @sizeOf([MAX_CLUSTER_PARTICLE_AMOUNT]Particle) * MAX_CLUSTERS;
        self.instance_buffer = device.new_buffer_with_length(instance_buffer_size, .storage_mode_managed) orelse @panic("OOM");
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

    // pub fn render_explosions(self: *FullThrottleMode, command_buffer: metal.MTLCommandBuffer, render_pass_desc: objc.Object, width: f64, height: f64, color_attachment_desc: objc.Object, camera_matrix: *math.Float4x4) void {
    pub fn render_explosions(self: *FullThrottleMode, command_encoder: metal.MTLRenderCommandEncoder, render_pass_desc: objc.Object, width: f64, height: f64, color_attachment_desc: objc.Object, camera_matrix: *math.Float4x4) void {
        _ = render_pass_desc;
        if (self.explosions.len == 0) {
            return;
        }

        color_attachment_desc.setProperty("loadAction", metal.MTLLoadAction.load);
        const w: f32 = @floatCast(width);
        const h: f32 = @floatCast(height);

        const aspect = w / h;
        const toScreenSpaceMatrix2 = math.Float4x4.new(math.float4(w / 2, 0, 0, 0), math.float4(0, (h / 2), 0, 0), math.float4(0, 0, 1, 0), math.float4(w / 2, h / 2, 0, 1));
        var toScreenSpaceMatrix =
            toScreenSpaceMatrix2;
        const ortho = math.Float4x4.ortho(-aspect, aspect, -1.0, 1.0, 0.001, 100.0);
        const origin = math.float4(-1.0, 0.0, 0.0, 1.0);
        const p = toScreenSpaceMatrix.mul_f4(origin);
        _ = p;
        const scale = math.Float4x4.scale_by(0.05);
        _ = scale;
        const uniforms: Uniforms = .{
            .projection_matrix = ortho,
            // .model_view_matrix = scale,
            .model_view_matrix = self.model_matrix(4, w, h).mul(camera_matrix),
        };

        // const command_encoder = command_buffer.new_render_command_encoder(render_pass_desc);
        // command_encoder.set_viewport(metal.MTLViewport{ .origin_x = 0.0, .origin_y = 0.0, .width = width, .height = height, .znear = 0.1, .zfar = 100.0 });
        command_encoder.set_label("Explosions");

        command_encoder.set_vertex_bytes(@as([*]const u8, @ptrCast(&self.explosion_vertices))[0..@sizeOf([6]Explosion)], 0);
        command_encoder.set_vertex_buffer(self.instance_buffer, 0, 1);
        command_encoder.set_vertex_bytes(@as([*]const u8, @ptrCast(&uniforms))[0..@sizeOf(Uniforms)], 2);

        command_encoder.set_fragment_texture(self.explosion_texture, 0);
        command_encoder.set_fragment_sampler_state(self.explosion_sampler_state, 0);

        command_encoder.set_render_pipeline_state(self.explosion_pipeline);
        command_encoder.draw_primitives_instanced(.triangle, 0, 6, self.explosions.len);
        // command_encoder.end_encoding();
    }

    // pub fn render_particles(self: *FullThrottleMode, dt: f32, command_buffer: metal.MTLCommandBuffer, render_pass_desc: objc.Object, width: f64, height: f64, color_attachment_desc: objc.Object, camera_matrix: *math.Float4x4) void {
    pub fn render_particles(self: *FullThrottleMode, dt: f32, command_encoder: metal.MTLRenderCommandEncoder, render_pass_desc: objc.Object, width: f64, height: f64, color_attachment_desc: objc.Object, camera_matrix: *math.Float4x4) void {
        _ = render_pass_desc;
        self.update(dt);
        if (self.clusters_len == 0) {
            return;
        }
        color_attachment_desc.setProperty("loadAction", metal.MTLLoadAction.load);
        const w: f32 = @floatCast(width);
        const h: f32 = @floatCast(height);

        const aspect = w / h;
        const toScreenSpaceMatrix2 = math.Float4x4.new(math.float4(w / 2, 0, 0, 0), math.float4(0, (h / 2), 0, 0), math.float4(0, 0, 1, 0), math.float4(w / 2, h / 2, 0, 1));
        const scaleAspect = math.Float4x4.new(math.float4(0, 0, 0, 0), math.float4(0, aspect, 0, 0), math.float4(0, 0, 1, 0), math.float4(0, 0, 0, 1));
        _ = scaleAspect;
        //         var toScreenSpaceMatrix = scaleAspect.mul(
        //             &toScreenSpaceMatrix2
        // );
        var toScreenSpaceMatrix =
            toScreenSpaceMatrix2;
        // var ortho = math.Float4x4.ortho(0.0, w, 0.0, h, 0.1, 100.0);
        const ortho = math.Float4x4.ortho(-aspect, aspect, -1.0, 1.0, 0.001, 100.0);
        const origin = math.float4(-1.0, 0.0, 0.0, 1.0);
        const p = toScreenSpaceMatrix.mul_f4(origin);
        _ = p;
        const scale = math.Float4x4.scale_by(0.05);
        _ = scale;
        const uniforms: Uniforms = .{
            .projection_matrix = ortho,
            // .model_view_matrix = scale,
            .model_view_matrix = self.model_matrix(4, w, h).mul(camera_matrix),
        };

        // const command_encoder = command_buffer.new_render_command_encoder(render_pass_desc);
        // command_encoder.set_label("Particles");
        command_encoder.set_viewport(metal.MTLViewport{ .origin_x = 0.0, .origin_y = 0.0, .width = width, .height = height, .znear = 0.1, .zfar = 100.0 });

        command_encoder.set_vertex_bytes(@as([*]const u8, @ptrCast(&self.vertices))[0..@sizeOf([4]Vertex)], 0);
        command_encoder.set_vertex_buffer(self.instance_buffer, INSTANCEBUF_PARTICLE_START, 1);
        command_encoder.set_vertex_bytes(@as([*]const u8, @ptrCast(&uniforms))[0..@sizeOf(Uniforms)], 2);

        command_encoder.set_render_pipeline_state(self.pipeline);
        command_encoder.draw_indexed_primitives_instanced(.triangle, 6, .UInt16, self.index_buffer, 0, @as(usize, self.clusters_len) * MAX_CLUSTER_PARTICLE_AMOUNT);
        // command_encoder.end_encoding();
    }
};

const Fire = struct {
    compute_pipeline: metal.MTLComputePipelineState,
    render_pipeline: metal.MTLRenderPipelineState,
    particle_buffer: metal.MTLBuffer,
    time: f32,
    vertices: [4]Fire.Vertex,
    indices: [6]u16,
    index_buffer: metal.MTLBuffer,
    particle_count: usize,
    texture: objc.Object,
    sampler_state: objc.Object,

    const Vertex = extern struct {
        pos: math.Float2 align(8),
        texcoords: math.Float2 align(8),
    };

    // time_buffer: metal.MTLBuffer,

    const FireParticle = extern struct {
        position: math.Float2 align(8),
        color: math.Float4 align(16),
        velocity: math.Float2 align(8),
        gravity: math.Float2 align(8),
        life: f32,
        fade: f32,
    };

    const VERTEX_SIZE: f32 = 0.33;

    pub fn init(device: metal.MTLDevice, view: metal.MTKView, particle_count: usize) Fire {
        var fire: Fire = .{
            .compute_pipeline = undefined,
            .render_pipeline = undefined,
            .particle_buffer = undefined,
            // .time_buffer = undefined,
            .time = 0.0,

            .vertices = [4]Fire.Vertex{
                .{
                    .pos = math.float2(-VERTEX_SIZE, VERTEX_SIZE),
                    .texcoords = math.float2(0.0, 0.0),
                },
                .{
                    .pos = math.float2(
                        VERTEX_SIZE,
                        VERTEX_SIZE,
                    ),
                    .texcoords = math.float2(1.0, 0.0),
                },
                .{
                    .pos = math.float2(VERTEX_SIZE, -VERTEX_SIZE),
                    .texcoords = math.float2(1.0, 1.0),
                },
                .{
                    .pos = math.float2(-VERTEX_SIZE, -VERTEX_SIZE),
                    .texcoords = math.float2(0.0, 1.0),
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
            .index_buffer = undefined,
            .particle_count = particle_count,
            .texture = undefined,
            .sampler_state = undefined,
        };

        fire.build_pipelines(device, view);
        fire.initialize_particles(device);

        return fire;
    }

    // pub fn render(self: *Fire, dt: f32, command_queue: metal.MTLCommandQueue, command_buffer: metal.MTLCommandBuffer, render_pass_desc: objc.Object, width: f64, height: f64, color_attachment_desc: objc.Object, camera_matrix: *math.Float4x4) void {
    pub fn render(self: *Fire, dt: f32, command_queue: metal.MTLCommandQueue, render_command_encoder: metal.MTLRenderCommandEncoder, render_pass_desc: objc.Object, width: f64, height: f64, color_attachment_desc: objc.Object, camera_matrix: *math.Float4x4) void {
        _ = render_pass_desc;
        self.time += dt;

        color_attachment_desc.setProperty("loadAction", metal.MTLLoadAction.load);
        const compute_command_buffer = command_queue.command_buffer();
        const compute_command_encoder = compute_command_buffer.compute_command_encoder();

        compute_command_encoder.set_compute_pipeline_state(self.compute_pipeline);
        compute_command_encoder.set_buffer(self.particle_buffer, 0, 0);
        const time_bytes = cast.bytes(&self.time);
        std.debug.assert(time_bytes.len == @sizeOf(f32));
        compute_command_encoder.set_bytes(time_bytes, 1);

        const grid_size = metal.MTLSize.new(self.particle_count, 1, 1);
        const thread_group_size = metal.MTLSize.new(1, 1, 1);
        compute_command_encoder.dispatch_threadgroups(grid_size, thread_group_size);
        compute_command_encoder.end_encoding();

        compute_command_buffer.commit();
        // wait for results to populate the particle buffer
        // compute_command_buffer.wait_until_completed();

        // const render_command_encoder = command_buffer.new_render_command_encoder(render_pass_desc);
        // render_command_encoder.set_viewport(metal.MTLViewport{ .origin_x = 0.0, .origin_y = 0.0, .width = width, .height = height, .znear = 0.1, .zfar = 100.0 });
        render_command_encoder.set_render_pipeline_state(self.render_pipeline);

        const w: f32 = @floatCast(width);
        const h: f32 = @floatCast(height);
        const aspect = w / h;
        const ortho = math.Float4x4.ortho(-aspect, aspect, -1.0, 1.0, 0.001, 100.0);
        _ = ortho;
        // var pers = math.Float4x4.perspective(45 * std.math.pi  / 180.0, 1.0, 0.001, 100.0);
        const pers = math.Float4x4.perspective(45 * std.math.pi / 180.0, aspect, 0.001, 100.0);
        const uniforms: Uniforms = .{
            // .projection_matrix = ortho,
            .projection_matrix = pers,
            // .model_view_matrix = scale,
            // .model_view_matrix = self.model_matrix(4, w, h).mul(camera_matrix),
            .model_view_matrix = camera_matrix.*,
        };

        render_command_encoder.set_vertex_bytes(cast.bytes(&self.vertices), 0);
        render_command_encoder.set_vertex_buffer(self.particle_buffer, 0, 1);
        render_command_encoder.set_vertex_bytes(cast.bytes(&uniforms), 2);

        render_command_encoder.set_fragment_texture(.{ .obj = self.texture }, 0);
        render_command_encoder.set_fragment_sampler_state(self.sampler_state, 0);

        render_command_encoder.draw_indexed_primitives_instanced(.triangle, 6, .UInt16, self.index_buffer, 0, self.particle_count);

        // render_command_encoder.end_encoding();
    }

    fn initialize_particles(self: *Fire, device: metal.MTLDevice) void {
        // self.particle_buffer = device.new_buffer_with_bytes(particles_ptr[0..@sizeOf(FireParticle) * particles.len], .storage_mode_shared);
        self.particle_buffer = device.new_buffer_with_length(self.particle_count * @sizeOf(FireParticle), .storage_mode_managed) orelse @panic("OOM!");
        var particles = self.particle_buffer.contents_typed(FireParticle)[0..self.particle_count];
        for (0..particles.len) |i| {
            var p: *FireParticle = &particles[i];
            p.position = math.float2(0.0, -5.0).add(math.float2(rnd.random().float(f32) * 0.2 - 0.1, rnd.random().float(f32) * 0.2 - 0.1));
            p.life = 1.0;
            p.fade = (rnd.random().float(f32) * 100.0) / 1000.0 + 0.003;
            p.color = math.Float4.WHITE;
            p.velocity = math.float2(rnd.random().float(f32) * 2.0 - 1.0, rnd.random().float(f32) * 2.0 - 1.0).norm().mul_f(rnd.random().float(f32) * 2000);
            // p.velocity = math.float2(
            //     (rnd.random().float(f32) * 50.0 - 25.0) * 100.0,
            //     (rnd.random().float(f32) * 50.0 - 25.0) * 100.0

            //     // (rnd.random().float(f32) * 50.0 - 25.0) * 1.0,
            //     // (rnd.random().float(f32) * 50.0 - 25.0) * 1.0

            //     // rnd.random().float(f32) * 2.0 - 1.0,
            //     // rnd.random().float(f32) * 2.0 - 1.0
            // );
            p.gravity = math.float2(0.0, 0.8);
        }
        self.particle_buffer.did_modify_range(.{ .location = 0, .length = @sizeOf(FireParticle) * self.particle_count });
    }

    fn build_pipelines(self: *Fire, device: metal.MTLDevice, view: metal.MTKView) void {
        var err: ?*anyopaque = null;
        const shader_str = @embedFile("./shaders/fire.metal");
        const shader_nsstring = metal.NSString.new_with_bytes(shader_str, .utf8);
        defer shader_nsstring.release();

        const library = device.obj.msgSend(objc.Object, objc.sel("newLibraryWithSource:options:error:"), .{ shader_nsstring, @as(?*anyopaque, null), &err });
        metal.check_error(err) catch @panic("failed to build library");

        const func_compute = func_compute: {
            const str = metal.NSString.new_with_bytes(
                "compute_main",
                .utf8,
            );
            defer str.release();

            const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
            break :func_compute objc.Object.fromId(ptr.?);
        };

        self.compute_pipeline = device.new_compute_pipeline_with_function(func_compute) catch @panic("Failed to make compute pipeline");

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
            desc.set_attribute(0, .{ .format = .float2, .offset = @offsetOf(Fire.Vertex, "pos"), .buffer_index = 0 });
            desc.set_attribute(1, .{ .format = .float2, .offset = @offsetOf(Fire.Vertex, "texcoords"), .buffer_index = 0 });
            desc.set_attribute(2, .{ .format = .float2, .offset = @offsetOf(FireParticle, "position"), .buffer_index = 1 });
            desc.set_attribute(3, .{ .format = .float2, .offset = @offsetOf(FireParticle, "color"), .buffer_index = 1 });
            desc.set_layout(0, .{ .stride = @sizeOf(Fire.Vertex) });
            desc.set_layout(1, .{ .stride = @sizeOf(FireParticle), .step_function = .PerInstance });
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
            // attachment.setProperty("pixelFormat", @as(c_ulong, 81));

            // Blending. This is required so that our text we render on top
            // of our drawable properly blends into the bg.
            attachment.setProperty("blendingEnabled", true);
            attachment.setProperty("rgbBlendOperation", @intFromEnum(metal.MTLBlendOperation.add));
            attachment.setProperty("alphaBlendOperation", @intFromEnum(metal.MTLBlendOperation.add));
            attachment.setProperty("sourceRGBBlendFactor", @intFromEnum(metal.MTLBlendFactor.source_alpha));
            attachment.setProperty("sourceAlphaBlendFactor", @intFromEnum(metal.MTLBlendFactor.source_alpha));
            // attachment.setProperty("destinationRGBBlendFactor", @intFromEnum(metal.MTLBlendFactor.one_minus_source_alpha));
            // attachment.setProperty("destinationAlphaBlendFactor", @intFromEnum(metal.MTLBlendFactor.one_minus_source_alpha));
            attachment.setProperty("destinationRGBBlendFactor", @intFromEnum(metal.MTLBlendFactor.one));
            attachment.setProperty("destinationAlphaBlendFactor", @intFromEnum(metal.MTLBlendFactor.one));
        }

        pipeline_desc.set_label("Fire");
        const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");
        self.render_pipeline = pipeline;
        self.index_buffer = device.new_buffer_with_bytes(@as([*]const u8, @ptrCast(&self.indices))[0..@sizeOf([6]u16)], .storage_mode_managed);

        // // const fire_texture_raw = @embedFile("./assets/Particle.bmp");
        // // const fire_texture_raw = @embedFile("./assets/particle2.png");
        // // const fire_texture_raw = @embedFile("./assets/fire.png");
        // // const fire_texture_raw = @embedFile("./assets/fire2.png");
        // const fire_texture_raw = @embedFile("./assets/flare.png");
        // const fire_texture = metal.NSData.new_with_bytes_no_copy(fire_texture_raw[0..], false);
        // // const fire_full_path = metal.NSString.new_with_bytes("/Users/zackradisic/Downloads/fireparticle.png", .ascii);
        // // NSURL *textureFileURL = [NSURL fileURLWithPath:fullFilePath];

        // const tex_opts = metal.NSDictionary.new_mutable();
        // tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_enum(metal.MTLTextureUsage.shader_read), metal.MTKTextureLoaderOptionTextureUsage });
        // tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_enum(metal.MTLStorageMode.private), metal.MTKTextureLoaderOptionTextureStorageMode });
        // tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_int(0), metal.MTKTextureLoaderOptionSRGB });
        // // tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.MTLPixelFormatR8Unorm, metal.MTKTextureLoaderOptionPixelFormat });

        // const tex_loader_class = objc.getClass("MTKTextureLoader").?;
        // var tex_loader = tex_loader_class.msgSend(objc.Object, objc.sel("alloc"), .{});
        // tex_loader = tex_loader.msgSend(objc.Object, objc.sel("initWithDevice:"), .{device});

        // err = null;
        // const tex = tex_loader.msgSend(objc.Object, objc.sel("newTextureWithData:options:error:"), .{
        //     fire_texture,
        //     tex_opts,
        //     &err
        // });
        // // const nsurl = metal.NSURL.file_url_with_path(fire_full_path);
        // // const tex = tex_loader.msgSend(objc.Object, objc.sel("newTextureWithContentsOfURL:options:error:"), .{
        // //     nsurl,
        // //     tex_opts,
        // // });
        // metal.check_error(err) catch @panic("failed to make texture");
        const tex = @import("./texture_loader.zig").load_texture_from_img_bytes(device, @embedFile("./assets/Particle.bmp")[0..], metal.MTLPixelFormatRGBA8Unorm);
        // const tex = @import("./texture_loader.zig").load_texture_from_img_bytes(device, @embedFile("./assets/fire2.png")[0..]);
        // const tex = @import("./texture_loader.zig").load_texture_from_img_bytes(device, @embedFile("./assets/flare.png")[0..]);
        self.texture = tex.obj;

        const sampler_descriptor = objc.getClass("MTLSamplerDescriptor").?.msgSend(objc.Object, objc.sel("alloc"), .{}).msgSend(objc.Object, objc.sel("init"), .{});
        sampler_descriptor.setProperty("minFilter", metal.MTLSamplerMinMagFilter.linear);
        sampler_descriptor.setProperty("magFilter", metal.MTLSamplerMinMagFilter.linear);
        sampler_descriptor.setProperty("sAddressMode", metal.MTLSamplerAddressMode.ClampToZero);
        sampler_descriptor.setProperty("tAddressMode", metal.MTLSamplerAddressMode.ClampToZero);

        const sampler_state = device.new_sampler_state(sampler_descriptor);
        self.sampler_state = sampler_state;
    }
};
