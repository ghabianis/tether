const std = @import("std");
const metal = @import("./metal.zig");
const anim = @import("anim.zig");
const cast = @import("./cast.zig");
const objc = @import("zig-objc");
const hdr = @import("./hdr.zig");
const Hdr = hdr.Hdr;

const QUAD_VERTEX_INPUT: [24]f32 = .{
    // First triangle (CCW)
    -1.0, 1.0, 0.0, 0.0, // A: position, texCoord
    1.0, 1.0, 1.0, 0.0, // B: position, texCoord
    -1.0, -1.0, 0.0, 1.0, // C: position, texCoord

    // Second triangle (CCW)
    -1.0, -1.0, 0.0, 1.0, // C: position, texCoord
    1.0, 1.0, 1.0, 0.0, // B: position, texCoord
    1.0, -1.0, 1.0, 1.0, // D: position, texCoord
};

// This is good!
// const NUMBER_OF_MIPS = 3;
// const FILTER_RADIUS: f32 = 10;
// const BRIGHTNESS_THRESHOLD: f32 = 2;

// This is thin and good!
// const NUMBER_OF_MIPS = 2;
// const FILTER_RADIUS: f32 = 0.1;
// const BRIGHTNESS_THRESHOLD: f32 = 2;

// THIS IS EVEN BETTER!
// const NUMBER_OF_MIPS = 3;
// const FILTER_RADIUS: f32 = 0.5;
// const BRIGHTNESS_THRESHOLD: f32 = 2;

const NUMBER_OF_MIPS = 2;
const FILTER_RADIUS: f32 = 1.0;
const BRIGHTNESS_THRESHOLD: f32 = 2;

const MipLevel = struct {
    texture: metal.MTLTexture,
    sampler: metal.MTLSamplerState,
    width: f32,
    height: f32,
};

pub const Bloom = struct {
    output: metal.MTLTexture,

    extract_texture: metal.MTLTexture,
    extract_pipeline: metal.MTLRenderPipelineState,

    mip_levels: std.BoundedArray(MipLevel, 8) = .{},

    downsample_pipeline: metal.MTLRenderPipelineState,
    downsample_sampler: metal.MTLSamplerState,

    upsample_pipeline: metal.MTLRenderPipelineState,

    width: f32,
    height: f32,

    const Self = @This();

    pub fn read_texture_for_mip_level(self: *Self, mip_level: usize) metal.MTLTexture {
        return if (mip_level == 0) self.extract_texture else self.mip_levels.buffer[mip_level - 1].texture;
    }

    pub fn init(device: metal.MTLDevice, output: metal.MTLTexture, width: f32, height: f32) Bloom {
        const downsample_vert, const downsample_frag = brk: {
            const downsample_shader = @embedFile("./shaders/bloom_downsample.metal");
            const library = metal.MTLLibrary.new_with_utf8_source_options_error(
                device,
                downsample_shader,
                null,
            );
            defer library.release();

            const vert = library.new_function_with_utf8_name("vs_main");
            const frag = library.new_function_with_utf8_name("fs_main");
            break :brk .{ vert, frag };
        };

        const upsample_vert, const upsample_frag = brk: {
            const shader = @embedFile("./shaders/bloom_upsample.metal");
            const library = metal.MTLLibrary.new_with_utf8_source_options_error(
                device,
                shader,
                null,
            );
            defer library.release();

            const vert = library.new_function_with_utf8_name("vs_main");
            const frag = library.new_function_with_utf8_name("fs_main");
            break :brk .{ vert, frag };
        };
        const extract_high_freq_vert, const extract_high_freq_frag = brk: {
            const shader = @embedFile("./shaders/bloom_extract_high_freq.metal");
            const library = metal.MTLLibrary.new_with_utf8_source_options_error(
                device,
                shader,
                null,
            );
            defer library.release();

            const vert = library.new_function_with_utf8_name("vs_main");
            const frag = library.new_function_with_utf8_name("fs_main");
            break :brk .{ vert, frag };
        };

        const extract_texture = extract_texture: {
            const desc = metal.MTLTextureDescriptor.new_2d_with_pixel_format(
                Hdr.format,
                @intFromFloat(width),
                @intFromFloat(height),
                false,
            );
            desc.set_usage(@intFromEnum(metal.MTLTextureUsage.shader_read) |
                @intFromEnum(metal.MTLTextureUsage.shader_write) |
                @intFromEnum(metal.MTLTextureUsage.render_target) |
                @intFromEnum(metal.MTLTextureUsage.pixel_format_view));
            break :extract_texture device.new_texture_with_descriptor(desc);
        };

        const downsample_sampler = downsample_sampler: {
            const desc = metal.MTLSamplerDescriptor.new();
            // desc.set_s_address_mode(.ClampToEdge);
            // desc.set_t_address_mode(.ClampToEdge);
            // desc.set_r_address_mode(.ClampToEdge);
            // desc.set_mag_filter(.nearest);
            // desc.set_min_filter(.nearest);
            // desc.set_mip_filter(.Nearest);
            // desc.set_lod_min_clamp(0.0);
            // desc.set_lod_max_clamp(100.0);
            break :downsample_sampler device.new_sampler_state(desc.obj);
        };

        std.debug.print("Making MIP-LEVELS! {d}x{d}\n", .{ width, height });
        var mip_levels = std.BoundedArray(MipLevel, 8).init(0) catch @panic("OOM");
        for (0..NUMBER_OF_MIPS) |i| {
            const if32: f32 = @floatFromInt(i);
            const w: usize = @intFromFloat(width / std.math.pow(f32, 2.0, if32 + 1));
            const h: usize = @intFromFloat(height / std.math.pow(f32, 2.0, if32 + 1));
            std.debug.print("MIP-LEVEL: {d}, {d}x{d}\n", .{ i, w, h });

            const desc = metal.MTLTextureDescriptor.new_2d_with_pixel_format(Hdr.format, w, h, false);
            desc.set_usage(@intFromEnum(metal.MTLTextureUsage.shader_read) |
                @intFromEnum(metal.MTLTextureUsage.shader_write) |
                @intFromEnum(metal.MTLTextureUsage.render_target) |
                @intFromEnum(metal.MTLTextureUsage.pixel_format_view));
            const texture = device.new_texture_with_descriptor(desc);

            mip_levels.append(.{
                .texture = texture,
                .width = @floatFromInt(w),
                .height = @floatFromInt(h),
                .sampler = downsample_sampler,
            }) catch @panic("OOM");
        }

        const extract_pipeline = extract_pipeline: {
            const pipeline_desc = pipeline_desc: {
                const vertex_desc = vertex_descriptor: {
                    var desc = metal.MTLVertexDescriptor.alloc();
                    desc = desc.init();
                    desc.set_attribute(0, .{
                        .format = .float2,
                        .offset = 0,
                        .buffer_index = 0,
                    });
                    desc.set_attribute(1, .{
                        .format = .float2,
                        .offset = @sizeOf(f32) * 2,
                        .buffer_index = 0,
                    });
                    desc.set_layout(0, .{ .stride = @sizeOf(f32) * 4 });
                    break :vertex_descriptor desc;
                };

                var desc = metal.MTLRenderPipelineDescriptor.alloc();
                desc = desc.init();
                desc.retain();
                desc.set_vertex_function(extract_high_freq_vert.obj);
                desc.set_vertex_descriptor(vertex_desc);
                desc.set_fragment_function(extract_high_freq_frag.obj);
                desc.set_label_comptime("bloom_extract_high_freq");

                const attachment = desc.get_color_attachments().object_at(0).?;
                attachment.set_pixel_format(metal.MTLPixelFormatRGBA16Float);
                attachment.set_write_mask(metal.MTLColorWriteMask.All);
                break :pipeline_desc desc;
            };

            // {
            //     const attachments = pipeline_desc.get_color_attachments();
            //     const attachment: metal.MTLRenderPipelineColorAttachmentDescriptor = attachments.object_at(0) orelse {
            //         @panic("No attachment");
            //     };

            //     attachment.set_pixel_format(Hdr.format);
            // }

            const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");
            break :extract_pipeline pipeline;
        };

        const downsample_pipeline = downsample_pipeline: {
            const pipeline_desc = pipeline_desc: {
                const vertex_desc = vertex_descriptor: {
                    var desc = metal.MTLVertexDescriptor.alloc();
                    desc = desc.init();
                    desc.set_attribute(0, .{
                        .format = .float2,
                        .offset = 0,
                        .buffer_index = 0,
                    });
                    desc.set_attribute(1, .{
                        .format = .float2,
                        .offset = @sizeOf(f32) * 2,
                        .buffer_index = 0,
                    });
                    desc.set_layout(0, .{ .stride = @sizeOf(f32) * 4 });
                    break :vertex_descriptor desc;
                };

                var desc = metal.MTLRenderPipelineDescriptor.alloc();
                desc = desc.init();
                desc.set_vertex_function(downsample_vert.obj);
                desc.set_vertex_descriptor(vertex_desc);
                desc.set_fragment_function(downsample_frag.obj);
                desc.set_label_comptime("bloom_downsample");

                const attachment = desc.get_color_attachments().object_at(0).?;
                attachment.set_pixel_format(metal.MTLPixelFormatRGBA16Float);
                attachment.set_write_mask(metal.MTLColorWriteMask.All);
                break :pipeline_desc desc;
            };

            {
                const attachments = pipeline_desc.get_color_attachments();
                const attachment: metal.MTLRenderPipelineColorAttachmentDescriptor = attachments.object_at(0) orelse {
                    @panic("No attachment");
                };

                attachment.set_pixel_format(Hdr.format);
                attachment.set_write_mask(metal.MTLColorWriteMask.All);
            }

            const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");
            break :downsample_pipeline pipeline;
        };

        const upsample_pipeline = upsample_pipeline: {
            const pipeline_desc = pipeline_desc: {
                const vertex_desc = vertex_descriptor: {
                    var desc = metal.MTLVertexDescriptor.alloc();
                    desc = desc.init();
                    desc.set_attribute(0, .{
                        .format = .float2,
                        .offset = 0,
                        .buffer_index = 0,
                    });
                    desc.set_attribute(1, .{
                        .format = .float2,
                        .offset = @sizeOf(f32) * 2,
                        .buffer_index = 0,
                    });
                    desc.set_layout(0, .{ .stride = @sizeOf(f32) * 4 });
                    break :vertex_descriptor desc;
                };

                var desc = metal.MTLRenderPipelineDescriptor.alloc();
                desc = desc.init();
                desc.set_vertex_function(upsample_vert.obj);
                desc.set_vertex_descriptor(vertex_desc);
                desc.set_fragment_function(upsample_frag.obj);
                desc.set_label_comptime("bloom_upsample");

                const attachment = desc.get_color_attachments().object_at(0).?;
                attachment.set_blending_enabled(true);
                attachment.set_pixel_format(metal.MTLPixelFormatRGBA16Float);
                attachment.set_write_mask(metal.MTLColorWriteMask.All);
                attachment.set_blending_enabled(true);
                attachment.set_rgb_blend_operation(.add);
                attachment.set_alpha_blend_operation(.add);
                attachment.set_source_rgb_blend_factor(.source_alpha);
                attachment.set_destination_rgb_blend_factor(.one_minus_source_alpha);
                attachment.set_source_alpha_blend_factor(.source_alpha);
                attachment.set_destination_alpha_blend_factor(.one_minus_source_alpha);
                break :pipeline_desc desc;
            };

            {
                const attachments = pipeline_desc.get_color_attachments();
                const attachment: metal.MTLRenderPipelineColorAttachmentDescriptor = attachments.object_at(0) orelse {
                    @panic("No attachment");
                };

                attachment.set_pixel_format(Hdr.format);
                attachment.set_write_mask(metal.MTLColorWriteMask.All);
            }

            const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");
            break :upsample_pipeline pipeline;
        };

        return Bloom{
            .output = output,
            .extract_texture = extract_texture,
            .extract_pipeline = extract_pipeline,
            .downsample_pipeline = downsample_pipeline,
            .downsample_sampler = downsample_sampler,
            .upsample_pipeline = upsample_pipeline,
            .mip_levels = mip_levels,
            .width = width,
            .height = height,
        };
    }

    pub fn render(self: *Bloom, command_buffer: metal.MTLCommandBuffer, hdr_texture: metal.MTLTexture, width: f32, height: f32) void {
        _ = width; // autofix
        _ = height; // autofix
        // Extract high frequency from the texture
        {
            const render_pass_desc = metal.MTLRenderPassDescriptor.render_pass_descriptor();
            {
                const attachments = render_pass_desc.attachments();
                const attachment = attachments.object_at(0).?;
                attachment.set_texture(self.extract_texture);
                attachment.set_load_action(metal.MTLLoadAction.clear);
                attachment.set_clear_color(metal.MTLClearColor{
                    .r = 0.0,
                    .g = 0.0,
                    .b = 0.0,
                    .a = 0.0,
                });
                attachment.set_store_action(metal.MTLStoreAction.store);
            }
            const pass = command_buffer.new_render_command_encoder(render_pass_desc);
            pass.set_render_pipeline_state(self.extract_pipeline);
            pass.set_vertex_bytes(cast.bytes(&QUAD_VERTEX_INPUT), 0);
            // pass.set_fragment_texture(self.output, 0);
            pass.set_fragment_texture(hdr_texture, 0);
            pass.set_fragment_sampler_state(self.downsample_sampler.obj, 1);
            pass.set_fragment_bytes(cast.bytes(&BRIGHTNESS_THRESHOLD), 2);
            pass.draw_primitives(.triangle, 0, 6);
            pass.end_encoding();
        }

        // Downsample N times for each mip level
        for (self.mip_levels.slice(), 0..) |*mip_, mip_level| {
            const mip: *const MipLevel = mip_;
            const pass = pass: {
                const render_pass_desc = metal.MTLRenderPassDescriptor.render_pass_descriptor();
                const attachments = render_pass_desc.attachments();
                const attachment = attachments.object_at(0).?;
                attachment.set_texture(mip.texture);
                attachment.set_load_action(.load);
                attachment.set_store_action(.store);
                const pass = command_buffer.new_render_command_encoder(render_pass_desc);
                break :pass pass;
            };

            pass.set_label_comptime("downsample");

            const read_texture = self.read_texture_for_mip_level(mip_level);
            const dimensions: [2]f32 = .{ mip.width, mip.height };

            pass.set_render_pipeline_state(self.downsample_pipeline);
            pass.set_fragment_texture(read_texture, 0);
            pass.set_fragment_sampler_state(self.downsample_sampler.obj, 1);
            pass.set_fragment_bytes(cast.bytes(&dimensions), 2);
            pass.set_vertex_bytes(cast.bytes(&QUAD_VERTEX_INPUT), 0);
            pass.draw_primitives(.triangle, 0, 6);
            pass.end_encoding();
        }

        // SRC -> 1024 -> 512 -> 256 -> 128
        //
        // 128 -> 256 -> 512 -> 1024 -> SRC
        for (0..NUMBER_OF_MIPS) |_i| {
            const i = self.mip_levels.len - 1 - _i;

            const mip_level = self.mip_levels.get(i);
            const output = if (i == 0) self.output else self.mip_levels.get(i - 1).texture;

            const pass = pass: {
                const render_pass_desc = metal.MTLRenderPassDescriptor.render_pass_descriptor();
                const attachments = render_pass_desc.attachments();
                const attachment = attachments.object_at(0).?;
                attachment.set_texture(output);
                attachment.set_load_action(.load);
                attachment.set_store_action(.store);
                const pass = command_buffer.new_render_command_encoder(render_pass_desc);
                break :pass pass;
            };

            const dimensions: [2]f32 = dimensions: {
                // const next_mip_level = if (i == 0) {
                //     break :dimensions .{ self.width, self.height };
                // } else self.mip_levels.get(i - 1);
                // break :dimensions .{ next_mip_level.width, next_mip_level.height };
                break :dimensions .{ mip_level.width, mip_level.height };
            };

            pass.set_label_comptime("upsample");

            pass.set_render_pipeline_state(self.upsample_pipeline);
            pass.set_fragment_texture(
                // if (self.mip_levels.len == 0)
                //     self.extract_texture
                // else
                //     self.mip_levels.buffer[self.mip_levels.len - 1].texture,
                mip_level.texture,
                0,
            );
            const filter_radius_buf: [2]f32 = .{
                FILTER_RADIUS,
                69420.0, // padding
            };
            pass.set_vertex_bytes(cast.bytes(&QUAD_VERTEX_INPUT), 0);
            pass.set_fragment_sampler_state(self.downsample_sampler.obj, 1);
            pass.set_fragment_bytes(cast.bytes(&filter_radius_buf), 2);
            pass.set_fragment_bytes(cast.bytes(&dimensions), 3);
            pass.draw_primitives(.triangle, 0, 6);
            pass.end_encoding();
        }

        // Upsample
        // Only doing once because I like the effect, and it's cheap
        // {
        //     const pass = pass: {
        //         const render_pass_desc = metal.MTLRenderPassDescriptor.render_pass_descriptor();
        //         const attachments = render_pass_desc.attachments();
        //         const attachment = attachments.object_at(0).?;
        //         attachment.set_texture(self.output);
        //         attachment.set_load_action(.load);
        //         attachment.set_store_action(.store);
        //         const pass = command_buffer.new_render_command_encoder(render_pass_desc);
        //         break :pass pass;
        //     };

        //     pass.set_render_pipeline_state(self.upsample_pipeline);
        //     pass.set_fragment_texture(
        //         if (self.mip_levels.len == 0)
        //             self.extract_texture
        //         else
        //             self.mip_levels.buffer[self.mip_levels.len - 1].texture,
        //         0,
        //     );
        //     const filter_radius_buf: [2]f32 = .{
        //         FILTER_RADIUS,
        //         69420.0, // padding
        //     };
        //     pass.set_vertex_bytes(cast.bytes(&QUAD_VERTEX_INPUT), 0);
        //     pass.set_fragment_sampler_state(self.downsample_sampler.obj, 1);
        //     pass.set_fragment_bytes(cast.bytes(&filter_radius_buf), 2);
        //     pass.set_fragment_bytes(cast.bytes(&dimensions), 3);
        //     pass.draw_primitives(.triangle, 0, 6);
        //     pass.end_encoding();
        // }
    }
};
