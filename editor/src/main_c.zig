const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("zig-objc");
const font = @import("./font.zig");
const Atlas = font.Atlas;
const Glyph = font.GlyphInfo;
const metal = @import("./metal.zig");
const math = @import("./math.zig");
const rope = @import("./rope.zig");
const Editor = @import("./editor.zig");
const ct = @import("./coretext.zig");
const Vim = @import("./vim.zig");
const Event = @import("./event.zig");
const strutil = @import("./strutil.zig");
const Conf = @import("./conf.zig");
const ts = @import("./treesitter.zig");
const Highlight = @import("./highlight.zig");

const print = std.debug.print;
const ArrayList = std.ArrayListUnmanaged;
const ArenaAllocator = std.heap.ArenaAllocator;

const TextPos = rope.TextPos;
const Rope = rope.Rope;

const Vertex = math.Vertex;

var Arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);

pub const Uniforms = extern struct { model_view_matrix: math.Float4x4, projection_matrix: math.Float4x4 };

const TEXT_COLOR = math.hex4("#b8c1ea");

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
    highlight: ?Highlight = null,

    pub fn init(alloc: Allocator, atlas: font.Atlas, view_: objc.c.id, device_: objc.c.id) *Renderer {
        const device = metal.MTLDevice.from_id(device_);
        const view = metal.MTKView.from_id(view_);
        const queue = device.make_command_queue() orelse @panic("SHIT");
        const highlight = Highlight.init(alloc, &ts.ZIG, Highlight.TokyoNightStorm.to_indices()) catch @panic("SHIT");

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
            .highlight = highlight,
        };
        renderer.editor.init() catch @panic("oops");

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
        try self.update(alloc);
    }

    fn update_if_needed(self: *Self, alloc: Allocator) !void {
        if (self.editor.draw_text) {
            try self.update(alloc);
        }
    }

    fn update(self: *Self, alloc: Allocator) !void {
        try self.update_text(alloc);
    }

    fn update_text(self: *Self, alloc: Allocator) !void {
        const str = try self.editor.rope.as_str(std.heap.c_allocator);
        print("STR: {s}\n", .{str});
        defer {
            if (str.len > 0) {
                std.heap.c_allocator.destroy(str);
            }
        }

        const screenx = @floatCast(f32, self.screen_size.width);
        const screeny = @floatCast(f32, self.screen_size.height);

        try self.build_text_geometry(alloc, &Arena, str, screenx, screeny);
        try self.build_selection_geometry(alloc, str, screenx, screeny);

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

    pub fn build_cursor_geometry(self: *Self, y: f32, xx: f32, width: f32) [6]Vertex {
        const yy2 = y + self.atlas.ascent;
        const bot2 = y - self.atlas.descent;
        var ret: [6]Vertex = [_]Vertex{Vertex.default()} ** 6;

        const tl = math.float2(xx, yy2);
        const tr = math.float2(xx + width, yy2);
        const br = math.float2(xx + width, bot2);
        const bl = math.float2(xx, bot2);

        const txt = self.atlas.cursor_ty;
        const txbb = txt - self.atlas.cursor_h;
        const txl = self.atlas.cursor_tx;
        const txr = txl + self.atlas.cursor_w;

        const tx_tl = math.float2(txl, txt);
        const tx_tr = math.float2(txr, txt);
        const tx_bl = math.float2(txl, txbb);
        const tx_br = math.float2(txr, txbb);

        var bg = math.hex4("#b4f9f8");
        // if (self.editor.mode == .Visual) {
        //     bg.w = 0.5;
        // }

        ret[0] = .{ .pos = tl, .tex_coords = tx_tl, .color = bg };
        ret[1] = .{ .pos = tr, .tex_coords = tx_tr, .color = bg };
        ret[2] = .{ .pos = bl, .tex_coords = tx_bl, .color = bg };

        ret[3] = .{ .pos = tr, .tex_coords = tx_tr, .color = bg };
        ret[4] = .{ .pos = br, .tex_coords = tx_br, .color = bg };
        ret[5] = .{ .pos = bl, .tex_coords = tx_bl, .color = bg };

        return ret;
    }

    fn text_attributed_string_dict(self: *Self) objc.Object {
        const dict = metal.NSDictionary.new_mutable();
        const two = metal.NSNumber.number_with_int(2);
        defer two.release();

        dict.msgSend(void, objc.sel("setObject:forKey:"), .{
            two.obj.value,
            ct.kCTLigatureAttributeName,
        });
        dict.msgSend(void, objc.sel("setObject:forKey:"), .{
            self.atlas.font.value,
            ct.kCTFontAttributeName,
        });

        return dict;
    }

    pub fn build_text_geometry(self: *Self, alloc: Allocator, frame_arena: *ArenaAllocator, str: []const u8, screenx: f32, screeny: f32) !void {
        _ = screenx;
        var charIdxToVertexIdx = try ArrayList(u32).initCapacity(frame_arena.allocator(), str.len);
        charIdxToVertexIdx.items.len = str.len;
        for (charIdxToVertexIdx.items[0..charIdxToVertexIdx.items.len]) |*b| b.* = std.math.maxInt(u32);

        var cursor_vertices: [6]Vertex = [_]Vertex{Vertex.default()} ** 6;
        var cursor_vert_index: ?u32 = null;

        var initial_x: f32 = 0.0;
        var starting_x: f32 = initial_x;
        var starting_y: f32 = screeny - @intToFloat(f32, self.atlas.max_glyph_height);

        const atlas_w = @intToFloat(f32, self.atlas.width);
        const atlas_h = @intToFloat(f32, self.atlas.height);

        self.vertices.clearRetainingCapacity();

        try self.vertices.appendSlice(alloc, cursor_vertices[0..]);

        // TODO: This can be created once at startup
        const text_attributes = self.text_attributed_string_dict();
        defer text_attributes.msgSend(void, objc.sel("release"), .{});

        var iter = self.editor.rope.iter_lines(self.editor.rope.nodes.first orelse return);

        var cursor_line: u32 = 0;
        var cursor_col: u32 = 0;
        var index: u32 = 0;
        while (iter.next()) |the_line| {
            // if empty line or line with only \n
            if (the_line.len == 0 or the_line.len == 1 and strutil.is_newline(the_line[0])) {
                if (cursor_line == self.editor.cursor.line and cursor_col == self.editor.cursor.col) {
                    cursor_vertices = self.build_cursor_geometry(starting_y, initial_x, @intToFloat(f32, self.atlas.max_glyph_width_before_ligatures));
                }
                if (the_line.len == 1) {
                    charIdxToVertexIdx.items[index] = @intCast(u32, self.vertices.items.len);
                    try self.vertices.appendSlice(alloc, &[_]Vertex{Vertex.default()} ** 6);
                    index += 1;
                }

                starting_y -= self.atlas.descent + self.atlas.ascent;
                cursor_line += 1;
                cursor_col = 0;
                continue;
            }
            // remove \n
            var line = if (strutil.is_newline(the_line[the_line.len - 1])) the_line[0 .. the_line.len - 1] else the_line;

            // TODO: I think this can be created once before this loop, then
            //       reused by calling init_with_bytes_no_copy
            const nstring = metal.NSString.new_with_bytes_no_copy(line, .ascii);
            // TODO: Same as above
            const attributed_string = metal.NSAttributedString.new_with_string(nstring, text_attributes);
            defer attributed_string.release();

            const ctline = ct.CTLineCreateWithAttributedString(attributed_string.obj.value);
            const runs = ct.CTLineGetGlyphRuns(ctline);
            const run_count = ct.CFArrayGetCount(runs);
            std.debug.assert(run_count <= 1);
            if (run_count == 0) {
                @panic("This is bad");
            }

            const run = ct.CFArrayGetValueAtIndex(runs, 0);
            const glyph_count = @intCast(usize, ct.CTRunGetGlyphCount(run));

            var glyphs = try ArrayList(metal.CGGlyph).initCapacity(frame_arena.allocator(), glyph_count);
            var glyph_rects = try ArrayList(metal.CGRect).initCapacity(frame_arena.allocator(), glyph_count);
            var positions = try ArrayList(metal.CGPoint).initCapacity(frame_arena.allocator(), glyph_count);

            glyphs.items.len = glyph_count;
            glyph_rects.items.len = glyph_count;
            positions.items.len = glyph_count;

            ct.CTRunGetGlyphs(run, .{ .location = 0, .length = @intCast(i64, glyph_count) }, glyphs.items.ptr);
            ct.CTRunGetPositions(run, .{ .location = 0, .length = 0 }, positions.items.ptr);
            self.atlas.get_glyph_rects(glyphs.items, glyph_rects.items);

            var i: usize = 0;
            var last_x: f32 = 0.0;
            while (i < glyphs.items.len) : (i += 1) {
                defer {
                    cursor_col += 1;
                    index += 1;
                }

                const has_cursor = cursor_line == self.editor.cursor.line and cursor_col == self.editor.cursor.col;
                const color = TEXT_COLOR;

                const glyph = glyphs.items[i];
                const glyph_info = self.atlas.lookup(glyph);
                const rect = glyph_rects.items[i];
                var pos = positions.items[i];

                const width = @intToFloat(f32, glyph_info.rect.widthCeil());
                const b = @floatCast(f32, pos.y) + starting_y + @floatCast(f32, rect.origin.y);
                const t = b + @floatCast(f32, rect.size.height);
                const l = @floatCast(f32, pos.x) + starting_x + @floatCast(f32, rect.origin.x);
                const r = l + @floatCast(f32, rect.size.width);

                const txt = glyph_info.ty - @intToFloat(f32, glyph_info.rect.heightCeil()) / atlas_h;
                const txb = glyph_info.ty;
                const txl = glyph_info.tx;
                const txr = glyph_info.tx + width / atlas_w;

                const vertices = Vertex.square(.{ .t = t, .b = b, .l = l, .r = r }, .{ .t = txt, .b = txb, .l = txl, .r = txr }, color);
                charIdxToVertexIdx.items[index] = @intCast(u32, self.vertices.items.len);
                if (has_cursor) {
                    cursor_vertices = self.build_cursor_geometry(starting_y + @floatCast(f32, pos.y), starting_x + @floatCast(f32, pos.x), if (glyph_info.advance == 0.0) @intToFloat(f32, self.atlas.max_glyph_width_before_ligatures) else glyph_info.advance);
                    cursor_vert_index = @intCast(u32, self.vertices.items.len);
                }
                try self.vertices.appendSlice(alloc, &vertices);
                last_x = l + glyph_info.advance;
            }

            if (cursor_line == self.editor.cursor.line and cursor_col == self.editor.cursor.col) {
                const pos = positions.items[positions.items.len - 1];
                cursor_vertices = self.build_cursor_geometry(starting_y + @floatCast(f32, pos.y), last_x, @intToFloat(f32, self.atlas.max_glyph_width_before_ligatures));
            }
            starting_y -= self.atlas.descent + self.atlas.ascent;
            cursor_line += 1;
            cursor_col = 0;
            index += 1;
            // _ = frame_arena.reset(.retain_capacity);
        }

        if (self.highlight) |*highlight| {
            try highlight.highlight(str, charIdxToVertexIdx.items, self.vertices.items);
        }

        if (cursor_vert_index) |vi| {
            const black = math.Float4.new(0.0, 0.0, 0.0, 1.0);
            self.vertices.items[vi].color = black;
            self.vertices.items[vi + 1].color = black;
            self.vertices.items[vi + 2].color = black;
            self.vertices.items[vi + 3].color = black;
            self.vertices.items[vi + 4].color = black;
            self.vertices.items[vi + 5].color = black;
        }
        @memcpy(self.vertices.items[0..6], cursor_vertices[0..6]);

        _ = frame_arena.reset(.retain_capacity);
    }

    pub fn build_selection_geometry(self: *Self, alloc: Allocator, text_: []const u8, screenx: f32, screeny: f32) !void {
        _ = screenx;
        // const color = math.Float4.new(0.05882353, 0.7490196, 1.0, 0.2);
        var bg = math.hex4("#b4f9f8");
        bg.w = 0.2;
        // const color = math.Float4.new(0.05882353, 0.7490196, 1.0, 0.2);
        const color = bg;
        const selection = self.editor.selection orelse return;

        var y: f32 = screeny - @intToFloat(f32, self.atlas.max_glyph_height);
        var x: f32 = 0.0;
        var starting_x: f32 = 0.0;
        var text = text_;

        var i: u32 = 0;
        var line_state = false;
        var yy: f32 = 0.0;
        var l: f32 = 0.0;
        var r: f32 = 0.0;
        for (text) |char| {
            defer i += 1;
            if (i >= selection.end) break;
            const glyph = self.atlas.lookup_char(char);

            if (i < selection.start) {
                if (char == 9) {
                    x += self.atlas.lookup_char_from_str(" ").advance * 4.0;
                } else if (strutil.is_newline(char)) {
                    x = starting_x;
                    // y += -@intToFloat(f32, self.atlas.max_glyph_height) - self.atlas.descent;
                    y -= self.atlas.descent + self.atlas.ascent;
                } else {
                    x += glyph.advance;
                }
                continue;
            }

            if (!line_state) {
                yy = y;
                l = x;
                // r = x + @intToFloat(f32, self.atlas.max_glyph_width);
                r = x + glyph.advance;
                line_state = true;
            } else {
                r += glyph.advance;
            }

            if (char == 9) {
                x += self.atlas.lookup_char_from_str(" ").advance * 4.0;
            } else if (strutil.is_newline(char)) {
                x = starting_x;
                // y += -@intToFloat(f32, self.atlas.max_glyph_height) - self.atlas.descent;
                y -= self.atlas.descent + self.atlas.ascent;
            } else {
                x += glyph.advance;
            }

            // Push vertices if end of line or entire selection
            if (strutil.is_newline(char) or i == selection.end -| 1) {
                line_state = false;

                try self.vertices.appendSlice(alloc, &Vertex.square(.{
                    .t = yy + self.atlas.ascent,
                    .b = yy - self.atlas.descent,
                    .l = l,
                    .r = r,
                }, .{
                    .t = self.atlas.cursor_ty,
                    .b = self.atlas.cursor_ty - self.atlas.cursor_h,
                    .l = self.atlas.cursor_tx,
                    .r = self.atlas.cursor_tx + self.atlas.cursor_w,
                }, color));
            }
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
        const bg = math.hex4("#1a1b26");
        color_attachment_desc.setProperty("clearColor", metal.MTLClearColor{ .r = bg.x, .g = bg.y, .b = bg.z, .a = bg.w });

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
        const key = Event.Key.from_nsevent(event) orelse return;
        try self.editor.keydown(key);

        try self.update_if_needed(alloc);
    }
};

export fn renderer_create(view: objc.c.id, device: objc.c.id) *Renderer {
    const alloc = std.heap.c_allocator;
    var atlas = font.Atlas.new(alloc, 32.0);
    atlas.make_atlas(alloc) catch @panic("OOPS");
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

export fn renderer_insert_text(renderer: *Renderer, text: [*:0]const u8, len: usize) void {
    renderer.editor.insert(text[0..len]) catch @panic("oops");
    renderer.update_if_needed(std.heap.c_allocator) catch @panic("oops");
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
