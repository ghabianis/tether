const metal = @import("./metal.zig");
const anim = @import("anim.zig");
const cast = @import("./cast.zig");
const objc = @import("zig-objc");

pub const Hdr = struct {
    /// The output of rendering the scene
    texture: metal.MTLTexture,
    /// The output of the bloom pass, will be blended with the actual texture
    bloom_texture: metal.MTLTexture,
    sampler: objc.Object,
    pipline: metal.MTLRenderPipelineState,

    pub const format: metal.MTLPixelFormat = metal.MTLPixelFormatRGBA16Float;
    // pub const SURFACE_FORMAT: metal.MTLPixelFormat = metal.MTLPixelFormatBGRA8Unorm;
    pub const SURFACE_FORMAT: metal.MTLPixelFormat = metal.MTLPixelFormatBGRA8Unorm_sRGB;

    // pub const SURFACE_FORMAT_SIGNED: metal.MTLPixelFormat = metal.MTLPixelFormatBGRA8Unorm_sRGB;
    pub const SAMPLE_COUNT = 4;

    pub const enable: bool = true;

    pub fn init(device: metal.MTLDevice, actual_texture: metal.MTLTexture, bloom_texture: metal.MTLTexture) Hdr {
        var err: ?*anyopaque = null;

        const sampler_descriptor = metal.MTLSamplerDescriptor.new();
        sampler_descriptor.set_min_filter(.linear);
        sampler_descriptor.set_mag_filter(.linear);
        sampler_descriptor.set_s_address_mode(.ClampToZero);
        sampler_descriptor.set_t_address_mode(.ClampToZero);
        sampler_descriptor.set_mip_filter(.Nearest);
        sampler_descriptor.set_lod_min_clamp(0.0);
        sampler_descriptor.set_lod_max_clamp(100.0);
        const sampler = device.new_sampler_state(sampler_descriptor.obj);

        const shader_str = @embedFile("./shaders/hdr_bloom.metal");
        const shader_nsstring = metal.NSString.new_with_bytes(shader_str, .utf8);
        defer shader_nsstring.release();

        const library = device.obj.msgSend(objc.Object, objc.sel("newLibraryWithSource:options:error:"), .{ shader_nsstring, @as(?*anyopaque, null), &err });
        defer library.release();
        metal.check_error(err) catch @panic("failed to build library");

        const func_vert = func_vert: {
            const str = metal.NSString.new_with_bytes(
                "vs_main",
                .utf8,
            );
            defer str.release();

            const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
            break :func_vert objc.Object.fromId(ptr.?);
        };

        const func_frag = func_frag: {
            const str = metal.NSString.new_with_bytes(
                "fs_main",
                .utf8,
            );
            defer str.release();

            const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
            break :func_frag objc.Object.fromId(ptr.?);
        };

        const pipeline_desc = pipeline_desc: {
            var desc = metal.MTLRenderPipelineDescriptor.alloc();
            desc = desc.init();
            desc.set_vertex_function(func_vert);
            desc.set_fragment_function(func_frag);
            desc.set_raster_sample_count(SAMPLE_COUNT);
            // desc.set_vertex_descriptor(vertex_desc);
            break :pipeline_desc desc;
        };

        {
            const attachments = pipeline_desc.get_color_attachments();
            const attachment: metal.MTLRenderPipelineColorAttachmentDescriptor = attachments.object_at(0) orelse {
                @panic("No attachment");
            };

            attachment.set_pixel_format(SURFACE_FORMAT);
        }

        const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");

        return Hdr{
            .pipline = pipeline,
            .texture = actual_texture,
            .bloom_texture = bloom_texture,
            .sampler = sampler.obj,
        };
    }

    pub fn render(self: *Hdr, command_buffer: metal.MTLCommandBuffer, surface_texure: metal.MTLTexture, resolve_texture: metal.MTLTexture, width: f32, height: f32) void {
        _ = width; // autofix
        _ = height; // autofix
        const render_pass_desc = metal.MTLRenderPassDescriptor.render_pass_descriptor();
        const attachments = render_pass_desc.attachments();
        const attachment = attachments.object_at(0).?;
        // attachment.set_texture(surface_texure);
        // attachment.set_resolve_texture(resolve_texture);
        attachment.set_texture(resolve_texture);
        attachment.set_resolve_texture(surface_texure);
        attachment.set_load_action(.load);
        attachment.set_store_action(.store_and_multisample_resolve);

        const pass = command_buffer.new_render_command_encoder(render_pass_desc);

        pass.set_render_pipeline_state(self.pipline);
        pass.set_fragment_texture(self.bloom_texture, 0);
        pass.set_fragment_sampler_state(self.sampler, 0);
        pass.set_fragment_texture(self.texture, 1);
        pass.set_fragment_sampler_state(self.sampler, 1);
        pass.draw_primitives(.triangle, 0, 6);
        pass.end_encoding();
    }
};
