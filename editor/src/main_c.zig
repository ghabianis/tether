const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("zig-objc");
const Atlas = @import("./font.zig").Atlas;
const metal = @import("./metal.zig");
const math = @import("./math.zig");
const font = @import("./font.zig");
const rope = @import("./rope.zig");

const TextPos = rope.TextPos;
const Rope = rope.Rope;

const ArrayList = std.ArrayListUnmanaged;

pub const Vertex = extern struct {
    pos: math.Float2,
    tex_coords: math.Float2,
    color: math.Float4,
};

pub const Uniforms = extern struct { model_view_matrix: math.Float4x4, projection_matrix: math.Float4x4 };

const Editor = struct {
    const Self = @This();

    rope: Rope = Rope{},
    cursor: TextPos = .{ .line = 0, .col = 0 },
    draw_text: bool = false,

    pub fn insert(self: *Self, cursor: TextPos, chars: []const u8) !void {
        try self.rope.insert_text(cursor, chars);
        self.draw_text = true;
    }
};

const Renderer = struct {
    const Self = @This();

    view: metal.MTKView,
    device: metal.MTLDevice,
    queue: metal.MTLCommandQueue,
    pipeline: metal.MTLRenderPipelineState,
    /// MTLTexture
    texture: objc.Object,
    /// MTLSamplerState
    sampler_state: objc.Object,

    vertices: ArrayList(Vertex),
    vertex_buffer: metal.MTLBuffer,
    screen_size: metal.CGSize,
    some_val: u64,

    atlas: font.Atlas,
    frame_arena: std.heap.ArenaAllocator,
    editor: Editor,

    pub fn init(alloc: Allocator, atlas: font.Atlas, view_: objc.c.id, device_: objc.c.id) *Renderer {
        const device = metal.MTLDevice.from_id(device_);
        const view = metal.MTKView.from_id(view_);
        const queue = device.make_command_queue() orelse @panic("SHIT");
        var renderer: Renderer = .{
            .view = view,
            .device = device,
            .queue = queue,
            .pipeline = Renderer.build_pipeline(device, view),
            .some_val = 69420,
            .vertices = ArrayList(Vertex){},
            .vertex_buffer = undefined,
            .atlas = atlas,
            .texture = undefined,
            .sampler_state = undefined,
            .screen_size = view.drawable_size(),
            // frame arena
            .frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .editor = Editor{},
        };

        renderer.vertex_buffer = device.new_buffer_with_length(32, metal.MTLResourceOptions.storage_mode_shared) orelse @panic("Failed to make buffer");

        const tex_opts = metal.NSDictionary.new_mutable();
        tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_enum(metal.MTLTextureUsage.shader_read), metal.MTKTextureLoaderOptionTextureUsage });
        tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_enum(metal.MTLStorageMode.private), metal.MTKTextureLoaderOptionTextureStorageMode });
        tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_int(0), metal.MTKTextureLoaderOptionSRGB });

        const tex_loader_class = objc.Class.getClass("MTKTextureLoader").?;
        var tex_loader = tex_loader_class.msgSend(objc.Object, objc.sel("alloc"), .{});
        tex_loader = tex_loader.msgSend(objc.Object, objc.sel("initWithDevice:"), .{device});

        var err: ?*anyopaque = null;
        const tex = tex_loader.msgSend(objc.Object, objc.sel("newTextureWithCGImage:options:error:"), .{
            atlas.atlas,
            tex_opts,
        });
        metal.check_error(err) catch @panic("failed to make texture");
        renderer.texture = tex;

        const sampler_descriptor = objc.Class.getClass("MTLSamplerDescriptor").?.msgSend(objc.Object, objc.sel("alloc"), .{}).msgSend(objc.Object, objc.sel("init"), .{});
        sampler_descriptor.setProperty("minFilter", metal.MTLSamplerMinMagFilter.linear);
        sampler_descriptor.setProperty("magFilter", metal.MTLSamplerMinMagFilter.linear);
        sampler_descriptor.setProperty("sAddressMode", metal.MTLSamplerAddressMode.ClampToZero);
        sampler_descriptor.setProperty("tAddressMode", metal.MTLSamplerAddressMode.ClampToZero);

        const sampler_state = device.new_sampler_state(sampler_descriptor);
        renderer.sampler_state = sampler_state;

        var ptr = alloc.create(Renderer) catch @panic("oom!");
        ptr.* = renderer;
        return ptr;
    }

    fn resize(self: *Self, alloc: Allocator, new_size: metal.CGSize) !void {
        self.screen_size = new_size;
        try self.update_text(alloc);
    }

    fn update_text(self: *Self, alloc: Allocator) !void {
        const str = try self.editor.rope.as_str(std.heap.c_allocator);
        std.debug.print("STRR {d} {s}\n", .{ self.editor.rope.len, str });
        // TODO: should deallocate, but if string is length 0 than dont deallocate
        // because it will be null pointer
        // defer std.heap.c_allocator.destroy(str);

        try self.build_text_geometry(alloc, str, @floatCast(f32, self.screen_size.width), @floatCast(f32, self.screen_size.height));
        // Creating a buffer of length 0 causes a crash, so we need to check if we have any vertices
        if (self.vertices.items.len > 0) {
            const old_vertex_buffer = self.vertex_buffer;
            defer old_vertex_buffer.release();
            self.vertex_buffer = self.device.new_buffer_with_bytes(@ptrCast([*]const u8, self.vertices.items.ptr)[0..(@sizeOf(Vertex) * self.vertices.items.len)], metal.MTLResourceOptions.storage_mode_shared);
            return;
        }
        self.editor.draw_text = false;
    }

    fn build_pipeline(device: metal.MTLDevice, view: metal.MTKView) metal.MTLRenderPipelineState {
        var err: ?*anyopaque = null;
        const shader_str = @embedFile("./shaders.metal");
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
            desc.set_attribute(1, .{ .format = .float2, .offset = @offsetOf(Vertex, "tex_coords"), .buffer_index = 0 });
            desc.set_attribute(2, .{ .format = .float4, .offset = @offsetOf(Vertex, "color"), .buffer_index = 0 });
            desc.set_layout(0, .{ .stride = @sizeOf(Vertex) });
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
            attachment.setProperty("rgbBlendOperation", @enumToInt(metal.MTLBlendOperation.add));
            attachment.setProperty("alphaBlendOperation", @enumToInt(metal.MTLBlendOperation.add));
            attachment.setProperty("sourceRGBBlendFactor", @enumToInt(metal.MTLBlendFactor.source_alpha));
            attachment.setProperty("sourceAlphaBlendFactor", @enumToInt(metal.MTLBlendFactor.source_alpha));
            attachment.setProperty("destinationRGBBlendFactor", @enumToInt(metal.MTLBlendFactor.one_minus_source_alpha));
            attachment.setProperty("destinationAlphaBlendFactor", @enumToInt(metal.MTLBlendFactor.one_minus_source_alpha));
        }

        const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");

        return pipeline;
    }

    /// TODO: Iterate rope text instead of passing string
    pub fn build_text_geometry(self: *Self, alloc: Allocator, text: []const u8, screenx: f32, screeny: f32) !void {
        _ = screenx;
        self.vertices.clearRetainingCapacity();
        var vertices = &self.vertices;

        var x: f32 = 0.0;
        var y: f32 = screeny - @intToFloat(f32, self.atlas.max_glyph_height);

        var starting_x = x;

        for (text) |char| {
            const glyph = self.atlas.lookup_char(char);
            const l = @floatCast(f32, glyph.rect.origin.x);
            const width = @intToFloat(f32, glyph.rect.widthCeil());
            // const height = @intToFloat(f32, glyph.rect.heightCeil());

            const xx = x + l;
            const yy = y + @intToFloat(f32, glyph.rect.maxyCeil());
            const bot = y + @intToFloat(f32, glyph.rect.minyCeil());

            const atlas_w = @intToFloat(f32, self.atlas.width);
            const atlas_h = @intToFloat(f32, self.atlas.height);

            const bitmap_w = @intToFloat(f32, glyph.rect.widthCeil());

            const tyt = glyph.ty - @intToFloat(f32, glyph.rect.heightCeil()) / atlas_h;
            const tyb = glyph.ty;

            switch (char) {
                // tab
                9 => {
                    x += self.atlas.lookup_char_from_str(" ").advance * 4.0;
                },
                // newline
                10 => {
                    x = starting_x;
                },
                else => {
                    // skip empty glyphs
                    if (glyph.rect.width() == 0.0 and glyph.rect.height() == 0.0) {
                        continue;
                    }
                    x += glyph.advance;
                    // x += 100.0;
                },
            }

            const color = math.float4(1.0, 0.0, 0.0, 1.0);

            const tl = math.float2(xx, yy);
            const tr = math.float2(xx + width, yy);
            const br = math.float2(xx + width, bot);
            const bl = math.float2(xx, bot);
            const tx_tl = math.float2(glyph.tx, tyt);
            const tx_tr = math.float2(glyph.tx + bitmap_w / atlas_w, tyt);
            const tx_bl = math.float2(glyph.tx, tyb);
            const tx_br = math.float2(glyph.tx + bitmap_w / atlas_w, tyb);

            try vertices.append(alloc, .{ .pos = tl, .tex_coords = tx_tl, .color = color });
            try vertices.append(alloc, .{ .pos = tr, .tex_coords = tx_tr, .color = color });
            try vertices.append(alloc, .{ .pos = bl, .tex_coords = tx_bl, .color = color });

            try vertices.append(alloc, .{ .pos = tr, .tex_coords = tx_tr, .color = color });
            try vertices.append(alloc, .{ .pos = br, .tex_coords = tx_br, .color = color });
            try vertices.append(alloc, .{ .pos = bl, .tex_coords = tx_bl, .color = color });
        }
    }

    pub fn draw(self: *Self, view: metal.MTKView) void {
        const command_buffer = self.queue.command_buffer();

        const render_pass_descriptor_id = view.obj.getProperty(objc.c.id, "currentRenderPassDescriptor");
        const drawable_id = view.obj.getProperty(objc.c.id, "currentDrawable");
        if (render_pass_descriptor_id == 0 or drawable_id == 0) return;

        const render_pass_desc = objc.Object.fromId(render_pass_descriptor_id);
        const drawable = objc.Object.fromId(drawable_id);

        const attachments = render_pass_desc.getProperty(objc.Object, "colorAttachments");
        const color_attachment_desc = attachments.msgSend(objc.Object, objc.sel("objectAtIndexedSubscript:"), .{@as(c_ulong, 0)});
        color_attachment_desc.setProperty("loadAction", metal.MTLLoadAction.clear);
        color_attachment_desc.setProperty("clearColor", metal.MTLClearColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 });

        const command_encoder = command_buffer.new_render_command_encoder(render_pass_desc);
        const drawable_size = view.drawable_size();
        command_encoder.set_viewport(metal.MTLViewport{ .origin_x = 0.0, .origin_y = 0.0, .width = drawable_size.width, .height = drawable_size.height, .znear = 0.1, .zfar = 100.0 });

        var model_matrix = math.Float4x4.scale_by(1.0);
        var view_matrix = math.Float4x4.translation_by(math.Float3{ .x = 0.0, .y = 0.0, .z = -1.5 });
        const model_view_matrix = view_matrix.mul(&model_matrix);
        const projection_matrix = math.Float4x4.ortho(0.0, @floatCast(f32, drawable_size.width), 0.0, @floatCast(f32, drawable_size.height), 0.1, 100.0);
        const uniforms = Uniforms{
            .model_view_matrix = model_view_matrix,
            .projection_matrix = projection_matrix,
        };

        command_encoder.set_vertex_bytes(@ptrCast([*]const u8, &uniforms)[0..@sizeOf(Uniforms)], 1);
        command_encoder.set_render_pipeline_state(self.pipeline);

        command_encoder.set_vertex_buffer(self.vertex_buffer, 0, 0);

        command_encoder.set_fragment_texture(self.texture, 0);
        command_encoder.set_fragment_sampler_state(self.sampler_state, 0);
        command_encoder.draw_primitives(.triangle, 0, self.vertices.items.len);
        command_encoder.end_encoding();

        command_buffer.obj.msgSend(void, objc.sel("presentDrawable:"), .{drawable});
        command_buffer.obj.msgSend(void, objc.sel("commit"), .{});

        _ = self.frame_arena.reset(.retain_capacity);
    }

    pub fn keydown(self: *Renderer, alloc: Allocator, event: metal.NSEvent) !void {
        var char_buf = [_]u8{0} ** 256;
        const nschars = event.characters() orelse return;
        const chars = nschars.to_c_string(&char_buf);
        try self.editor.insert(self.editor.cursor, chars[0..256]);
        try self.update_text(alloc);
    }
};

export fn renderer_create(view: objc.c.id, device: objc.c.id) *Renderer {
    var atlas = font.Atlas.new(64.0 * 2.0);
    atlas.make_atlas();
    const class = objc.Class.getClass("TetherFont").?;
    const obj = class.msgSend(objc.Object, objc.sel("alloc"), .{});
    defer obj.msgSend(void, objc.sel("release"), .{});
    return Renderer.init(std.heap.c_allocator, atlas, view, device);
}

export fn renderer_draw(renderer: *Renderer, view_id: objc.c.id) void {
    const view = metal.MTKView.from_id(view_id);
    renderer.draw(view);
}

export fn renderer_resize(renderer: *Renderer, new_size: metal.CGSize) void {
    renderer.resize(std.heap.c_allocator, new_size) catch @panic("oops");
}

export fn renderer_handle_keydown(renderer: *Renderer, event_id: objc.c.id) void {
    const event = metal.NSEvent.from_id(event_id);
    renderer.keydown(std.heap.c_allocator, event) catch @panic("oops");
}

export fn renderer_get_atlas_image(renderer: *Renderer) objc.c.id {
    return renderer.atlas.atlas;
}

export fn renderer_get_val(renderer: *Renderer) u64 {
    return renderer.some_val;
}
