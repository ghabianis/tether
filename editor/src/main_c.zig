const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("zig-objc");
const Font = @import("./font.zig");
const Glyph = Font.GlyphInfo;
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
// const earcut = @import("earcut");
const fullthrottle = @import("./full_throttle.zig");
const Diagnostics = @import("./diagnostics.zig");
const Time = @import("time.zig");
const cast = @import("./cast.zig");

const print = std.debug.print;
const ArrayList = std.ArrayListUnmanaged;
const ArenaAllocator = std.heap.ArenaAllocator;

const TextPoint = rope.TextPoint;
const Rope = rope.Rope;

const Vertex = math.Vertex;
const FullThrottle = fullthrottle.FullThrottleMode;
const Hdr = @import("./hdr.zig").Hdr;
const Bloom = @import("./bloom.zig").Bloom;

var Arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);

pub const Uniforms = extern struct { model_view_matrix: math.Float4x4, projection_matrix: math.Float4x4 };
const WindowLineRange = struct { start: u32, start_y: f32, end: u32, end_y: f32 };

const TEXT_COLOR = math.hex4("#b8c1ea");
// const TEXT_COLOR = math.hex4("#b8c1ea").mul_f(1.57);
const CURSOR_COLOR = math.hex4("#b4f9f8");
const BORDER_CURSOR_COLOR = math.hex4("#454961");

const Renderer = struct {
    const Self = @This();

    view: metal.MTKView,
    device: metal.MTLDevice,
    queue: metal.MTLCommandQueue,
    pipeline: metal.MTLRenderPipelineState,
    /// MTLTexture
    texture: metal.MTLTexture,
    /// MTLSamplerState
    sampler_state: objc.Object,

    vertices: ArrayList(Vertex),
    vertex_buffer: metal.MTLBuffer,
    screen_size: metal.CGSize,
    tx: f32,
    ty: f32,
    scroll_phase: ?metal.NSEvent.Phase = null,
    text_width: f32,
    text_height: f32,
    some_val: u64,

    font: Font,
    frame_arena: std.heap.ArenaAllocator,
    editor: Editor,
    fullthrottle: FullThrottle,
    hdr: Hdr,
    bloom: Bloom,
    // surface_texture: metal.MTLTexture,
    resolve_texture: metal.MTLTexture,
    diagnostic_renderer: Diagnostics,

    last_clock: ?c_ulong,

    pub fn init(alloc: Allocator, font: Font, view_: objc.c.id, device_: objc.c.id, width_: metal.CGFloat, height_: metal.CGFloat) *Renderer {
        const device = metal.MTLDevice.from_id(device_);
        device.retain();
        defer device.release();
        const view = metal.MTKView.from_id(view_);
        const queue = device.make_command_queue() orelse @panic("SHIT");
        const size = metal.CGSize{
            .height = height_,
            .width = width_,
        };

        const width: f32 = @floatCast(size.width);
        const height: f32 = @floatCast(size.height);

        const hdr_texture = hdr_texture: {
            const tex_desc = metal.MTLTextureDescriptor.new_2d_with_pixel_format(
                Hdr.format,
                @intFromFloat(size.width * 2.0),
                @intFromFloat(size.height * 2.0),
                false,
            );
            tex_desc.set_usage(@intFromEnum(metal.MTLTextureUsage.pixel_format_view) |
                @intFromEnum(metal.MTLTextureUsage.render_target) |
                @intFromEnum(metal.MTLTextureUsage.shader_read));

            break :hdr_texture device.new_texture_with_descriptor(tex_desc);
        };

        const bloom_texture = bloom_texture: {
            const tex_desc = metal.MTLTextureDescriptor.new_2d_with_pixel_format(
                Hdr.format,
                @intFromFloat(size.width),
                @intFromFloat(size.height),
                false,
            );
            tex_desc.set_usage(@intFromEnum(metal.MTLTextureUsage.pixel_format_view) |
                @intFromEnum(metal.MTLTextureUsage.render_target) |
                @intFromEnum(metal.MTLTextureUsage.shader_read));

            break :bloom_texture device.new_texture_with_descriptor(tex_desc);
        };

        const hdr = Hdr.init(device, hdr_texture, bloom_texture);
        const bloom = Bloom.init(device, bloom_texture, width, height);

        // const surface_texture = surface_texture: {
        //     const tex_desc = metal.MTLTextureDescriptor.new_2d_with_pixel_format(
        //         Hdr.SURFACE_FORMAT,
        //         @intFromFloat(size.width),
        //         @intFromFloat(size.height),
        //         false,
        //     );
        //     tex_desc.set_usage(@intFromEnum(metal.MTLTextureUsage.render_target) | @intFromEnum(metal.MTLTextureUsage.shader_read));
        //     tex_desc.set_sample_count(Hdr.SAMPLE_COUNT);
        //     tex_desc.set_texture_type(metal.MTLTextureType.texture_2d_multisample);
        //     break :surface_texture device.new_texture_with_descriptor(tex_desc);
        // };
        const resolve_texture = resolve_texture: {
            const tex_desc = metal.MTLTextureDescriptor.new_2d_with_pixel_format(
                Hdr.SURFACE_FORMAT,
                @intFromFloat(size.width),
                @intFromFloat(size.height),
                false,
            );
            tex_desc.set_usage(@intFromEnum(metal.MTLTextureUsage.render_target) | @intFromEnum(metal.MTLTextureUsage.shader_read));
            tex_desc.set_sample_count(1);
            // tex_desc.set_texture_type(metal.MTLTextureType.texture_2d_multisample);
            tex_desc.set_storage_mode(metal.MTLStorageMode.private);
            break :resolve_texture device.new_texture_with_descriptor(tex_desc);
        };

        var renderer: Renderer = .{
            .view = view,
            .device = device,
            .queue = queue,
            .pipeline = Renderer.build_pipeline(device, view),
            .tx = 0.0,
            .ty = 0.0,
            .text_width = 0.0,
            .text_height = 0.0,
            .some_val = 69420,
            .vertices = ArrayList(Vertex){},
            .vertex_buffer = undefined,
            .font = font,
            .texture = undefined,
            .sampler_state = undefined,
            .screen_size = size,
            // frame arena
            .frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .editor = Editor{},
            .fullthrottle = FullThrottle.init(device, view),
            .diagnostic_renderer = Diagnostics.init(std.heap.c_allocator, device, view),
            .hdr = hdr,
            .bloom = bloom,
            // .surface_texture = surface_texture,
            .resolve_texture = resolve_texture,

            .last_clock = null,
        };
        const highlight = Highlight.init(alloc, &ts.C, Highlight.TokyoNightStorm.to_indices()) catch @panic("SHIT");
        renderer.editor.init_with_highlighter(highlight) catch @panic("oops");

        renderer.vertex_buffer = device.new_buffer_with_length(32, metal.MTLResourceOptions.storage_mode_managed) orelse @panic("Failed to make buffer");

        renderer.texture = renderer.font.create_texture(device);

        const sampler_descriptor = objc.getClass("MTLSamplerDescriptor").?.msgSend(objc.Object, objc.sel("alloc"), .{}).msgSend(objc.Object, objc.sel("init"), .{});
        sampler_descriptor.setProperty("minFilter", metal.MTLSamplerMinMagFilter.linear);
        sampler_descriptor.setProperty("magFilter", metal.MTLSamplerMinMagFilter.linear);
        sampler_descriptor.setProperty("sAddressMode", metal.MTLSamplerAddressMode.ClampToZero);
        sampler_descriptor.setProperty("tAddressMode", metal.MTLSamplerAddressMode.ClampToZero);

        const sampler_state = device.new_sampler_state(sampler_descriptor);
        renderer.sampler_state = sampler_state.obj;

        const ptr = alloc.create(Renderer) catch @panic("oom!");
        ptr.* = renderer;
        return ptr;
    }

    fn resize(self: *Self, alloc: Allocator, new_size: metal.CGSize) !void {
        self.screen_size = new_size;
        try self.update(alloc, &[_]Editor.Edit{});
    }

    fn update_if_needed(self: *Self, alloc: Allocator, edits: []const Editor.Edit) !void {
        if (self.editor.cursor_dirty or self.editor.text_dirty()) {
            self.adjust_scroll_to_cursor(@floatCast(self.screen_size.height));
            try self.update(alloc, edits);
        }
    }

    fn update(self: *Self, alloc: Allocator, edits: []const Editor.Edit) !void {
        try self.update_text(alloc, edits);
    }

    fn digits(val: usize) u32 {
        return if (val == 0) 1 else @as(u32, @intFromFloat(@floor(@log10(@as(f32, @floatFromInt(val)))))) + 1;
    }

    fn line_number_column_width(self: *Self) f32 {
        const line = self.editor.cursor.line;
        const max_line = self.editor.rope.nodes.len;

        const min: u32 = 99;
        const up = @as(u32, @intCast(@max(0, @as(i64, @intCast(line)) - 1)));
        const down = max_line - line;

        const biggest_num = @max(@max(up, @max(down, line)), min);
        const digit_count = digits(biggest_num);
        var number_str_buf = [_]u8{0} ** 16;

        const number_str = strutil.number_to_str(@intCast(biggest_num), digit_count, &number_str_buf);
        const padding = self.font.max_adv;
        const width = self.font.str_width(number_str) + padding;

        return @as(f32, @floatCast(width));
    }

    fn update_text(self: *Self, alloc: Allocator, edits: []const Editor.Edit) !void {
        const str = try self.editor.rope.as_str(std.heap.c_allocator);
        defer {
            if (str.len > 0) {
                std.heap.c_allocator.free(str);
            }
        }

        if (self.editor.text_dirty()) {
            if (self.editor.highlight) |*h| {
                const ts_edit: ?[]const ts.Edit = if (edits.len > 0) @ptrCast(edits) else null;
                h.update_tree(str, ts_edit);
            }
        }

        const screenx = @as(f32, @floatCast(self.screen_size.width));
        const screeny = @as(f32, @floatCast(self.screen_size.height));
        const text_start_x = self.line_number_column_width();

        const window_range = self.find_start_end_lines(screeny);
        try self.build_text_geometry(alloc, &Arena, str, screenx, screeny, text_start_x, window_range);
        try self.build_selection_geometry(alloc, str, screenx, screeny, text_start_x, window_range);
        try self.build_line_numbers_geometry(alloc, &Arena, screenx, screeny, text_start_x, window_range);

        if (self.vertices.items.len == 0) {
            self.editor.cursor_dirty = false;
            return;
        }

        // Create new buffer if amount of vertices exceeds it
        // TODO: Amortized growth?
        if (self.vertices.items.len * @sizeOf(Vertex) > self.vertex_buffer.length()) {
            const old_vertex_buffer = self.vertex_buffer;
            defer old_vertex_buffer.release();
            self.vertex_buffer = self.device.new_buffer_with_bytes(@as([*]const u8, @ptrCast(self.vertices.items.ptr))[0..(@sizeOf(Vertex) * self.vertices.items.len)], metal.MTLResourceOptions.storage_mode_managed);
        } else {
            self.vertex_buffer.update(Vertex, self.vertices.items, 0);
        }

        if (self.font.atlas.dirty) {
            const tex = self.texture;
            defer tex.release();
            self.texture = self.font.create_texture(self.device);
        }
    }

    fn build_pipeline(device: metal.MTLDevice, view: metal.MTKView) metal.MTLRenderPipelineState {
        _ = view; // autofix
        var err: ?*anyopaque = null;
        const shader_str = @embedFile("./shaders/text.metal");
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
            desc.set_raster_sample_count(if (Hdr.enable) 1 else Hdr.SAMPLE_COUNT);
            break :pipeline_desc desc;
        };

        const attachments = objc.Object.fromId(pipeline_desc.obj.getProperty(?*anyopaque, "colorAttachments"));
        {
            const attachment = attachments.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            // Value is MTLPixelFormatBGRA8Unorm
            // const pix_fmt = view.color_pixel_format();

            attachment.setProperty("pixelFormat", @as(c_ulong, Hdr.format));

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

        pipeline_desc.set_label("Text");
        const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");

        return pipeline;
    }

    fn build_cursor_geometry_from_tbrl(self: *Self, t: f32, b: f32, l: f32, r: f32, comptime is_border: bool) [6]Vertex {
        var ret: [6]Vertex = [_]Vertex{Vertex.default()} ** 6;
        const tl = math.float2(l, t);
        const tr = math.float2(r, t);
        const br = math.float2(r, b);
        const bl = math.float2(l, b);

        // const txt: f32 = @floatCast(if (comptime !is_border) self.font.cursor.ty else self.font.border_cursor.ty);
        // const txbb: f32 = @floatCast(if (comptime !is_border) txt - self.font.cursor.rect.size.height else txt - self.font.border_cursor.rect.size.height);
        // const txl: f32 = @floatCast(if (comptime !is_border) self.font.cursor.tx else self.font.border_cursor.tx);
        // const txr: f32 = @floatCast(if (comptime !is_border) txl + self.font.cursor.rect.size.width else txl + self.font.border_cursor.rect.size.width);

        const txt: f32 = @floatCast(if (comptime !is_border) self.font.cursor.ty else self.font.border_cursor.ty);
        const txbb: f32 = @floatCast(if (comptime !is_border) txt + self.font.cursor.rect.size.height / @as(f32, @floatFromInt(self.font.atlas.height)) else txt + self.font.border_cursor.rect.size.height / @as(f32, @floatFromInt(self.font.atlas.height)));
        const txl: f32 = @floatCast(if (comptime !is_border) self.font.cursor.tx else self.font.border_cursor.tx);
        const txr: f32 = @floatCast(if (comptime !is_border) txl + self.font.cursor.rect.size.width / @as(f32, @floatFromInt(self.font.atlas.width)) else txl + self.font.border_cursor.rect.size.width / @as(f32, @floatFromInt(self.font.atlas.width)));

        const tx_tl = math.float2(txl, txt);
        const tx_tr = math.float2(txr, txt);
        const tx_bl = math.float2(txl, txbb);
        const tx_br = math.float2(txr, txbb);

        const bg = if (comptime !is_border) CURSOR_COLOR else BORDER_CURSOR_COLOR;

        ret[0] = .{ .pos = tl, .tex_coords = tx_tl, .color = bg };
        ret[1] = .{ .pos = tr, .tex_coords = tx_tr, .color = bg };
        ret[2] = .{ .pos = bl, .tex_coords = tx_bl, .color = bg };

        ret[3] = .{ .pos = tr, .tex_coords = tx_tr, .color = bg };
        ret[4] = .{ .pos = br, .tex_coords = tx_br, .color = bg };
        ret[5] = .{ .pos = bl, .tex_coords = tx_bl, .color = bg };

        return ret;
    }

    pub fn build_cursor_geometry(self: *Self, y: f32, xx: f32, width: f32, comptime is_border: bool) [6]Vertex {
        const yy2 = y + self.font.ascent;
        const bot2 = y - self.font.descent;
        return self.build_cursor_geometry_from_tbrl(yy2, bot2, xx, xx + width, is_border);
    }

    fn text_attributed_string_dict(self: *Self, comptime alignment: ct.CTTextAlignment) objc.Object {
        const dict = metal.NSDictionary.new_mutable();
        const two = metal.NSNumber.number_with_int(1);
        defer two.release();

        dict.msgSend(void, objc.sel("setObject:forKey:"), .{
            two.obj.value,
            ct.kCTLigatureAttributeName,
        });
        dict.msgSend(void, objc.sel("setObject:forKey:"), .{
            self.font.font.obj.value,
            ct.kCTFontAttributeName,
        });
        if (comptime alignment != .Left) {
            const settings = [_]ct.CTParagraphStyleSetting{.{
                .spec = ct.CTParagraphStyleSpecifier.Alignment,
                .value_size = @sizeOf(ct.CTTextAlignment),
                .value = @as(*const anyopaque, @ptrCast(&alignment)),
            }};
            const paragraph_style = ct.CTParagraphStyleCreate(&settings, settings.len);
            defer objc.Object.fromId(paragraph_style).msgSend(void, objc.sel("release"), .{});
            dict.msgSend(void, objc.sel("setObject:forKey:"), .{ paragraph_style, ct.kCTParagraphStyleAttributeName });
        }

        return dict;
    }

    /// If the cursor is partially obscured, adjust the screen scroll
    fn adjust_scroll_to_cursor(self: *Self, screeny: f32) void {
        if (self.scroll_phase) |phase| {
            // Skip if scrolling
            switch (phase) {
                .None, .Ended, .Cancelled => {
                    self.scroll_phase = null;
                    return;
                },
                .Changed, .Began, .MayBegin, .Stationary => {
                    return;
                },
            }
        }

        // 1. Get y of start of screen
        // 2. Get y of end of screen
        // 3. Get y of cursor top and bot
        // 4. Check if cursor is within those bounds.
        const ascent: f32 = @floatCast(self.font.ascent);
        const descent: f32 = @floatCast(self.font.descent);

        const cursor_line = self.editor.cursor.line;

        const start_end = self.find_start_end_lines(screeny);

        if (cursor_line > start_end.start and cursor_line < start_end.end -| 1) return;

        const cursor_y = cursor_y: {
            const initial_y: f32 = screeny + self.ty - ascent;
            var y: f32 = initial_y;
            var i: usize = 0;
            while (i < cursor_line) {
                y -= ascent + descent;
                i += 1;
            }
            break :cursor_y y;
        };

        const cursor_top = cursor_y + ascent;
        const cursor_bot = cursor_y - descent;

        const maxy_screen = screeny;
        const miny_screen = 0.0;

        if (cursor_top > maxy_screen) {
            const delta = cursor_top - maxy_screen;
            self.ty -= delta;
        } else if (cursor_bot < miny_screen) {
            const delta = cursor_bot - miny_screen;
            self.ty -= delta;
        }
    }

    /// Returns the indices of the first and last (exclusive) lines that
    /// are visible on the screen. Also returns y pos of first line.
    ///
    /// The y pos is BEFORE scroll translation, and is the BASELINE of the line,
    /// meaning (y + ascent = top of line, y - descent = bot of line)
    ///
    /// TODO: this can be made faster, just do multiplication bruh
    fn find_start_end_lines(self: *Self, screeny: f32) WindowLineRange {
        const ascent: f32 = @floatCast(self.font.ascent);
        const descent: f32 = @floatCast(self.font.descent);

        const lines_len = self.editor.rope.nodes.len;
        const top = screeny;
        const bot = 0.0;

        const initial_y: f32 = top + self.ty - ascent;
        var y: f32 = initial_y;

        if (lines_len == 1) {
            return .{ .start = 0, .end = 1, .start_y = y - self.ty, .end_y = y - (ascent + descent) - self.ty };
        }

        var i: u32 = 0;
        var start_y: f32 = 0.0;
        var end_y: f32 = 0.0;

        const start: u32 = start: {
            while (i < lines_len) {
                if (y - descent <= top) {
                    start_y = y - self.ty;
                    break :start @intCast(i);
                }
                y -= descent + ascent;
                i += 1;
            }
            start_y = initial_y - self.ty;
            break :start @intCast(0);
        };

        const end: u32 = end: {
            while (i < lines_len) {
                if (y + ascent <= bot) {
                    end_y = y - self.ty;
                    break :end @intCast(i);
                }
                y -= descent + ascent;
                i += 1;
            }
            end_y = start_y - (ascent + descent) - self.ty;
            break :end @intCast(lines_len + 1);
        };

        return .{ .start = start, .end = end, .start_y = start_y, .end_y = end_y };
    }

    pub fn build_text_geometry(self: *Self, alloc: Allocator, frame_arena: *ArenaAllocator, str: []const u8, screenx: f32, screeny: f32, text_start_x: f32, start_end: WindowLineRange) !void {
        _ = screeny;
        _ = screenx;
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        // const start_end = self.find_start_end_lines(screeny);
        const offset: f32 = @floatFromInt(start_end.start);
        _ = offset;

        var cursor_vertices: [6]Vertex = [_]Vertex{Vertex.default()} ** 6;
        // The index of the vertices where the cursor is
        var cursor_vert_index: ?struct { str_index: u32, index: u32, c: u8, y: f32, xx: f32, width: f32 } = null;

        const initial_x: f32 = text_start_x;
        const starting_x: f32 = initial_x;
        var starting_y: f32 = start_end.start_y;
        var text_max_width: f32 = 0.0;

        const atlas_w: f32 = @floatFromInt(self.font.atlas.width);
        const atlas_h: f32 = @floatFromInt(self.font.atlas.height);

        self.vertices.clearRetainingCapacity();

        try self.vertices.appendSlice(alloc, cursor_vertices[0..]);

        // TODO: This can be created once at startup
        const text_attributes = self.text_attributed_string_dict(.Left);
        defer text_attributes.msgSend(void, objc.sel("autorelease"), .{});

        const default_glyph_count = 256;
        var glyphs = try ArrayList(metal.CGGlyph).initCapacity(frame_arena.allocator(), default_glyph_count);
        var glyph_rects = try ArrayList(metal.CGRect).initCapacity(frame_arena.allocator(), default_glyph_count);
        var positions = try ArrayList(metal.CGPoint).initCapacity(frame_arena.allocator(), default_glyph_count);

        const starting_line: u32 = start_end.start;
        var iter = self.editor.rope.iter_lines(self.editor.rope.node_at_line(starting_line) orelse return);

        const start_byte: u32 = @intCast(self.editor.rope.pos_to_idx(.{ .line = starting_line, .col = 0 }) orelse 0);
        var end_byte: u32 = 0;
        var cursor_line: u32 = starting_line;
        var cursor_col: u32 = 0;
        var index: u32 = 0;
        while (iter.next()) |the_line| {
            if (cursor_line > start_end.end) {
                break;
            }

            // empty line
            if (the_line.len == 0) {
                if (cursor_line == self.editor.cursor.line and cursor_col == self.editor.cursor.col) {
                    cursor_vertices = self.build_cursor_geometry(starting_y, initial_x, @floatCast(self.font.cursor.rect.size.width), false);
                }
                starting_y -= self.font.descent + self.font.ascent;
                cursor_line += 1;
                cursor_col = 0;
                continue;
            }

            const has_newline = strutil.is_newline(the_line[the_line.len - 1]);
            _ = has_newline;
            const line = the_line;

            var last_x: f32 = initial_x;
            if (line.len > 0) {
                glyphs.clearRetainingCapacity();
                glyph_rects.clearRetainingCapacity();
                positions.clearRetainingCapacity();

                // TODO: I think this can be created once before this loop, then
                //       reused by calling init_with_bytes_no_copy
                const nstring = metal.NSString.new_with_bytes_no_copy(line, .ascii);
                defer nstring.autorelease();
                // TODO: Same as above
                const attributed_string = metal.NSAttributedString.new_with_string(nstring, text_attributes);
                defer attributed_string.autorelease();

                const ctline = ct.CTLineCreateWithAttributedString(attributed_string.obj.value);
                defer objc.Object.fromId(ctline).msgSend(void, objc.sel("autorelease"), .{});
                const runs = ct.CTLineGetGlyphRuns(ctline);
                const run_count = ct.CFArrayGetCount(runs);
                std.debug.assert(run_count <= 1);
                if (run_count == 0) {
                    @panic("This is bad");
                }

                const run = ct.CFArrayGetValueAtIndex(runs, 0);
                const glyph_count = @as(usize, @intCast(ct.CTRunGetGlyphCount(run)));

                try glyphs.resize(frame_arena.allocator(), glyph_count);
                try glyph_rects.resize(frame_arena.allocator(), glyph_count);
                try positions.resize(frame_arena.allocator(), glyph_count);

                glyphs.items.len = glyph_count;
                glyph_rects.items.len = glyph_count;
                positions.items.len = glyph_count;

                ct.CTRunGetGlyphs(run, .{ .location = 0, .length = @as(i64, @intCast(glyph_count)) }, glyphs.items.ptr);
                ct.CTRunGetPositions(run, .{ .location = 0, .length = 0 }, positions.items.ptr);
                try self.font.lookup_glyph_rects(glyphs.items, glyph_rects.items);
                if (glyphs.items.len != line.len) {
                    @panic("Houston we have a problem");
                }

                var i: usize = 0;
                while (i < glyphs.items.len) : (i += 1) {
                    defer {
                        cursor_col += 1;
                        index += 1;
                    }

                    const has_cursor = cursor_line == self.editor.cursor.line and cursor_col == self.editor.cursor.col;
                    const color = TEXT_COLOR;

                    const glyph = glyphs.items[i];
                    const glyph_info = try self.font.lookup(glyph);
                    const rect = glyph_rects.items[i];
                    const pos = positions.items[i];

                    const vertices = Vertex.square_from_glyph(
                        &rect,
                        &pos,
                        glyph_info,
                        color,
                        starting_x,
                        starting_y,
                        atlas_w,
                        atlas_h,
                    );
                    const l = vertices[0].pos.x;

                    if (has_cursor) {
                        cursor_vertices = self.build_cursor_geometry(starting_y + @as(f32, @floatCast(pos.y)), starting_x + @as(f32, @floatCast(pos.x)), if (glyph_info.advance == 0.0) @floatCast(self.font.cursor.rect.size.width) else glyph_info.advance, false);
                        // TODO: This will break if there is no 1->1 mapping of character to glyphs (some ligatures)
                        cursor_vert_index = .{
                            .str_index = index,
                            .index = @as(u32, @intCast(self.vertices.items.len)),
                            .c = line[i],
                            .y = starting_y + @as(f32, @floatCast(pos.y)),
                            .xx = starting_x + @as(f32, @floatCast(pos.x)),
                            .width = if (glyph_info.advance == 0.0) @floatCast(self.font.cursor.rect.size.width) else glyph_info.advance,
                        };
                    }
                    try self.vertices.appendSlice(alloc, &vertices);
                    last_x = l + glyph_info.advance;
                }
            }

            if (cursor_line == self.editor.cursor.line and cursor_col == self.editor.cursor.col) {
                cursor_vertices = self.build_cursor_geometry(starting_y, last_x, @floatCast(self.font.cursor.rect.size.width), false);
            }

            text_max_width = @max(text_max_width, last_x + @as(f32, @floatCast(self.font.cursor.rect.size.width)));
            starting_y -= self.font.descent + self.font.ascent;
            cursor_line += 1;
            cursor_col = 0;
            // if (has_newline) {
            // try self.vertices.appendSlice(alloc, &[_]Vertex{Vertex.default()} ** 6);
            // index += 1;
            // }
            // _ = frame_arena.reset(.retain_capacity);
        }
        end_byte = start_byte + index;

        self.text_width = text_max_width;
        self.text_height = @abs(starting_y);

        if (self.editor.highlight) |*highlight| {
            try highlight.highlight(alloc, str, self.vertices.items, start_byte, end_byte, self.editor.text_dirty());
            try highlight.find_errors(str, self.editor.text_dirty(), start_byte, end_byte);
            try self.diagnostic_renderer.update(frame_arena, &self.editor.rope, highlight.errors.items, self.vertices.items, start_end.start_y, start_byte, end_byte, math.float2(@floatCast(self.screen_size.width), @floatCast(self.screen_size.height)), self.font.ascent, self.font.descent, self.editor.text_dirty());
        }

        if (cursor_vert_index) |cvi| {
            const vi = cvi.index;
            const black = math.Float4.new(0.0, 0.0, 0.0, 1.0);
            self.vertices.items[vi].color = black;
            self.vertices.items[vi + 1].color = black;
            self.vertices.items[vi + 2].color = black;
            self.vertices.items[vi + 3].color = black;
            self.vertices.items[vi + 4].color = black;
            self.vertices.items[vi + 5].color = black;
            var is_opening = false;
            if (self.editor.is_delimiter(cvi.c, &is_opening)) {
                const border_cursor_ = self.build_cursor_geometry(cvi.y, cvi.xx, cvi.width, true);
                try self.vertices.appendSlice(alloc, &border_cursor_);
                if (is_opening) {
                    var stack_count: u32 = 0;
                    for (str[start_byte + cvi.str_index ..], cvi.str_index..) |c, i| {
                        if (self.editor.matches_opening_delimiter(cvi.c, c)) {
                            if (stack_count == 1) {
                                const vert_index = i * 6 + 6;
                                const tl: *const Vertex = &self.vertices.items[vert_index];
                                const br: *const Vertex = &self.vertices.items[vert_index + 4];
                                const border_cursor = self.build_cursor_geometry_from_tbrl(tl.pos.y, br.pos.y, tl.pos.x, br.pos.x, true);
                                try self.vertices.appendSlice(alloc, &border_cursor);
                                break;
                            }
                            stack_count -= 1;
                        } else if (c == cvi.c) {
                            stack_count += 1;
                        }
                    }
                } else {
                    var i: i64 = @intCast(start_byte + cvi.str_index);
                    var stack_count: u32 = 0;
                    while (i >= 0) : (i -= 1) {
                        const c = str[@intCast(i)];
                        if (self.editor.matches_closing_delimiter(cvi.c, c)) {
                            if (stack_count == 1) {
                                const vert_index: u32 = @intCast((i - start_byte) * 6 + 6);
                                const tl: *const Vertex = &self.vertices.items[vert_index];
                                const br: *const Vertex = &self.vertices.items[vert_index + 4];
                                const border_cursor = self.build_cursor_geometry_from_tbrl(tl.pos.y, br.pos.y, tl.pos.x - 1.5, br.pos.x, true);
                                try self.vertices.appendSlice(alloc, &border_cursor);
                                break;
                            }
                            stack_count -= 1;
                        } else if (c == cvi.c) {
                            stack_count += 1;
                        }
                    }
                }
            }
        }
        @memcpy(self.vertices.items[0..6], cursor_vertices[0..6]);

        _ = frame_arena.reset(.retain_capacity);
    }

    pub fn build_line_numbers_geometry(
        self: *Self,
        alloc: Allocator,
        frame_arena: *ArenaAllocator,
        screenx: f32,
        screeny: f32,
        line_nb_col_width: f32,
        start_end: WindowLineRange,
    ) !void {
        _ = screeny;
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const offset: f32 = @floatFromInt(start_end.start);
        _ = offset;

        _ = screenx;
        const line_count = self.editor.rope.nodes.len;
        _ = line_count;
        const text_attributes = self.text_attributed_string_dict(.Right);
        defer text_attributes.msgSend(void, objc.sel("release"), .{});

        const starting_x: f32 = 0.0 + self.font.max_adv * 0.5;
        var starting_y: f32 = start_end.start_y;

        const atlas_w = @as(f32, @floatFromInt(self.font.atlas.width));
        const atlas_h = @as(f32, @floatFromInt(self.font.atlas.height));

        const p = self.font.max_adv * 0.5;

        var number_buf = [_]u8{0} ** 16;

        var i: usize = start_end.start;
        while (i < start_end.end) : (i += 1) {
            defer {
                starting_y -= self.font.descent + self.font.ascent;
            }
            var on_current_line = false;
            const num = num: {
                if (i == self.editor.cursor.line) {
                    on_current_line = true;
                    break :num @as(u32, @intCast(i));
                }

                break :num @as(u32, @intCast(@abs(@as(i64, @intCast(self.editor.cursor.line)) - @as(i64, @intCast(i)))));
            };
            const digit_count = digits(num);
            const str = strutil.number_to_str(num, digit_count, &number_buf);
            const nstring = metal.NSString.new_with_bytes_no_copy(str, .ascii);
            defer nstring.autorelease();
            const attributed_string = metal.NSAttributedString.new_with_string(nstring, text_attributes);
            defer attributed_string.autorelease();

            const ctline = ct.CTLineCreateWithAttributedString(attributed_string.obj.value);
            defer objc.Object.fromId(ctline).msgSend(void, objc.sel("autorelease"), .{});

            const runs = ct.CTLineGetGlyphRuns(ctline);
            const run_count = ct.CFArrayGetCount(runs);
            std.debug.assert(run_count <= 1);
            if (run_count == 0) {
                @panic("This is bad");
            }

            const run = ct.CFArrayGetValueAtIndex(runs, 0);
            const glyph_count = @as(usize, @intCast(ct.CTRunGetGlyphCount(run)));

            var glyphs = try ArrayList(metal.CGGlyph).initCapacity(frame_arena.allocator(), glyph_count);
            var glyph_rects = try ArrayList(metal.CGRect).initCapacity(frame_arena.allocator(), glyph_count);
            var positions = try ArrayList(metal.CGPoint).initCapacity(frame_arena.allocator(), glyph_count);

            glyphs.items.len = glyph_count;
            glyph_rects.items.len = glyph_count;
            positions.items.len = glyph_count;

            ct.CTRunGetGlyphs(run, .{ .location = 0, .length = @as(i64, @intCast(glyph_count)) }, glyphs.items.ptr);
            ct.CTRunGetPositions(run, .{ .location = 0, .length = 0 }, positions.items.ptr);
            try self.font.lookup_glyph_rects(glyphs.items, glyph_rects.items);
            if (glyphs.items.len != str.len) {
                @panic("Houston we have a problem");
            }

            const run_width: metal.CGFloat = run_width: {
                if (glyph_rects.items.len == 0) continue;

                const pos: metal.CGPoint = positions.items[glyph_rects.items.len - 1];
                const glyph_info: *const Glyph = try self.font.lookup(glyphs.items[glyph_rects.items.len - 1]);

                break :run_width pos.x + if (glyph_info.advance == 0.0) @as(f32, @floatCast(self.font.cursor_w())) else glyph_info.advance;
            };

            const origin_adjust = (line_nb_col_width - p * 2.0) - run_width;

            var j: usize = 0;
            while (j < glyphs.items.len) : (j += 1) {
                const glyph = glyphs.items[j];
                const glyph_info = try self.font.lookup(glyph);
                const rect: metal.CGRect = glyph_rects.items[j];

                // Align text position to the right
                var pos = positions.items[j];
                pos.x += origin_adjust;

                // TODO ZACK BRING THIS SHIT BACK!
                const color = if (on_current_line) math.hex4("#7279a1") else math.hex4("#353a52");
                // const color = math.Float4.new(1.0, 1.0, 1.0, 1.0).mul_f(10.0);

                const vertices = Vertex.square_from_glyph(
                    &rect,
                    &pos,
                    glyph_info,
                    color,
                    starting_x,
                    starting_y,
                    atlas_w,
                    atlas_h,
                );

                try self.vertices.appendSlice(alloc, &vertices);
            }
        }
    }

    /// TODO: use frame scratch arena
    pub fn build_selection_geometry(self: *Self, alloc: Allocator, text_: []const u8, screenx: f32, screeny: f32, text_start_x: f32, start_end: WindowLineRange) !void {
        _ = screeny;
        _ = screenx;
        // const color = math.Float4.new(0.05882353, 0.7490196, 1.0, 0.2);
        var bg = math.hex4("#b4f9f8");
        bg.w = 0.2;
        // const color = math.Float4.new(0.05882353, 0.7490196, 1.0, 0.2);
        const color = bg;
        const selection = self.editor.selection orelse return;

        // var y: f32 = screeny - @as(f32, @floatCast(self.font.ascent + self.font.descent));
        var y: f32 = start_end.start_y;
        const starting_x: f32 = text_start_x;
        var x: f32 = starting_x;
        const text = text_;

        var i: u32 = 0;
        var line_state = false;
        var yy: f32 = 0.0;
        var l: f32 = 0.0;
        var r: f32 = 0.0;
        for (text) |char| {
            defer i += 1;
            if (i >= selection.end) break;
            const glyph = try self.font.lookup_char(char);

            if (i < selection.start) {
                if (char == 9) {
                    x += (try self.font.lookup_char_from_str(" ")).advance * 4.0;
                } else if (strutil.is_newline(char)) {
                    x = starting_x;
                    // y += -@intToFloat(f32, self.atlas.max_glyph_height) - self.font.descent;
                    y -= self.font.descent + self.font.ascent;
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
                x += (try self.font.lookup_char_from_str(" ")).advance * 4.0;
            } else if (strutil.is_newline(char)) {
                x = starting_x;
                // y += -@intToFloat(f32, self.atlas.max_glyph_height) - self.font.descent;
                y -= self.font.descent + self.font.ascent;
            } else {
                x += glyph.advance;
            }

            // Push vertices if end of line or entire selection
            if (strutil.is_newline(char) or i == selection.end -| 1) {
                line_state = false;

                // Use the middle of the cursor glyph because there's some
                // texture sampling errors that make the selection fade into the
                // background
                const txt: f32 = self.font.cursor.ty + cast.num(f32, self.font.cursor.rect.size.height / 2.0) / @as(f32, @floatFromInt(self.font.atlas.height));
                const txbb: f32 = txt;
                const txl: f32 = self.font.cursor.tx + cast.num(f32, self.font.cursor.rect.size.width / 2.0) / cast.num(f32, self.font.atlas.width);
                const txr: f32 = txl;

                try self.vertices.appendSlice(alloc, &Vertex.square(.{
                    .t = yy + self.font.ascent,
                    .b = yy - self.font.descent,
                    .l = l,
                    .r = r,
                }, .{
                    .t = txt,
                    .b = txbb,
                    .l = txl,
                    .r = txr,
                }, color));
            }
        }
    }

    pub fn draw(self: *Self, view: metal.MTKView, surface_texture: metal.MTLTexture, multisample_texture: metal.MTLTexture) void {
        const dt: f32 = dt: {
            if (self.last_clock) |lc| {
                const now = Time.clock();
                self.last_clock = now;
                break :dt @floatCast((@as(f64, @floatFromInt(now - lc)) * 10.0) / @as(f64, @floatFromInt(Time.CLOCKS_PER_SEC)));
            } else {
                self.last_clock = Time.clock();
                break :dt 0.0;
            }
        };

        self.fullthrottle.compute_shake(dt, @floatCast(self.screen_size.width), @floatCast(self.screen_size.height));

        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const command_buffer = self.queue.command_buffer();
        // for some reason this causes crash
        // defer command_buffer.autorelease();

        const drawable_id = view.obj.getProperty(objc.c.id, "currentDrawable");
        const drawable = objc.Object.fromId(drawable_id);
        const drawable_size = view.drawable_size();
        {
            // const render_pass_descriptor_id = view.obj.getProperty(objc.c.id, "currentRenderPassDescriptor");
            // if (render_pass_descriptor_id == 0 or drawable_id == 0) return;

            // const render_pass_desc = objc.Object.fromId(render_pass_descriptor_id);
            const render_pass_desc = metal.MTLRenderPassDescriptor.render_pass_descriptor();

            const attachments = render_pass_desc.attachments();
            const color_attachment_desc = attachments.object_at(0).?;
            color_attachment_desc.set_load_action(metal.MTLLoadAction.clear);
            color_attachment_desc.set_texture(self.hdr.texture);
            const bg = math.hex4("#1a1b26");
            // color_attachment_desc.setProperty("clearColor", metal.MTLClearColor{ .r = bg.x, .g = bg.y, .b = bg.z, .a = bg.w });
            color_attachment_desc.set_clear_color(metal.MTLClearColor{ .r = bg.x, .g = bg.y, .b = bg.z, .a = bg.w });
            // color_attachment_desc.setProperty("clearColor", metal.MTLClearColor{ .r = bg.x, .g = bg.y, .b = bg.z, .a = bg.w });

            const command_encoder = command_buffer.new_render_command_encoder(render_pass_desc);
            // command_encoder.set_label("Text");
            // for some reason this causes crash
            // defer command_encoder.autorelease();
            std.debug.print("DRAW: {d} {d}", .{ drawable_size.width, drawable_size.height });
            // command_encoder.set_viewport(metal.MTLViewport{ .origin_x = 0.0, .origin_y = 0.0, .width = drawable_size.width, .height = drawable_size.height, .znear = 0.1, .zfar = 100.0 });

            var model_matrix = math.Float4x4.scale_by(1.0);
            var view_matrix = math.Float4x4.translation_by(math.Float3{ .x = -self.tx, .y = self.ty, .z = 0.5 });
            view_matrix = view_matrix.mul(&self.fullthrottle.screen_shake_matrix);
            const model_view_matrix = view_matrix.mul(&model_matrix);
            const projection_matrix = math.Float4x4.ortho(0.0, @as(f32, @floatCast(drawable_size.width)), 0.0, @as(f32, @floatCast(drawable_size.height)), 0.1, 100.0);
            const uniforms = Uniforms{
                .model_view_matrix = model_view_matrix,
                .projection_matrix = projection_matrix,
            };

            command_encoder.set_vertex_bytes(@as([*]const u8, @ptrCast(&uniforms))[0..@sizeOf(Uniforms)], 1);
            command_encoder.set_render_pipeline_state(self.pipeline);

            command_encoder.set_vertex_buffer(self.vertex_buffer, 0, 0);

            command_encoder.set_fragment_texture(self.texture, 0);
            command_encoder.set_fragment_sampler_state(self.sampler_state, 0);
            command_encoder.draw_primitives(.triangle, 0, self.vertices.items.len);

            var translate = math.Float3{ .x = -self.tx, .y = self.ty, .z = 0 };
            var view_matrix_ndc = math.Float4x4.translation_by(translate.screen_to_ndc_vec(math.float2(@floatCast(drawable_size.width), @floatCast(drawable_size.height))));
            self.fullthrottle.render_particles(dt, command_encoder, render_pass_desc.obj, @floatCast(drawable_size.width), @floatCast(drawable_size.height), color_attachment_desc.obj, &view_matrix_ndc);
            self.fullthrottle.render_explosions(command_encoder, render_pass_desc.obj, @floatCast(drawable_size.width), @floatCast(drawable_size.height), color_attachment_desc.obj, &view_matrix_ndc);
            // self.fullthrottle.fire.render(dt, self.queue, command_encoder, render_pass_desc, @floatCast(drawable_size.width), @floatCast(drawable_size.height), color_attachment_desc.obj, &view_matrix_ndc);

            self.diagnostic_renderer.render(dt, command_encoder, render_pass_desc.obj, @floatCast(drawable_size.width), @floatCast(drawable_size.height), color_attachment_desc.obj, &view_matrix_ndc);
            command_encoder.end_encoding();
        }

        // const surface_texture = drawable.getProperty(metal.MTLTexture, "texture");

        self.bloom.render(command_buffer, self.hdr.texture, @floatCast(drawable_size.width), @floatCast(drawable_size.height));
        self.hdr.render(
            command_buffer,
            surface_texture,
            multisample_texture,
            @floatCast(drawable_size.width),
            @floatCast(drawable_size.height),
        );

        command_buffer.obj.msgSend(void, objc.sel("presentDrawable:"), .{drawable});
        command_buffer.obj.msgSend(void, objc.sel("commit"), .{});

        _ = self.frame_arena.reset(.retain_capacity);
    }

    pub fn keydown(self: *Renderer, alloc: Allocator, event: metal.NSEvent) !void {
        const key = Event.Key.from_nsevent(event) orelse return;
        const edits = try self.editor.keydown(key);
        defer {
            self.editor.edits.clearRetainingCapacity();
        }

        try self.update_if_needed(alloc, edits);

        if (edits.len > 0) {
            // cursor vertices are first 6 vertices of text
            const tl: Vertex = self.vertices.items.ptr[0];
            const br: Vertex = self.vertices.items.ptr[4];
            const top = tl.pos.y;
            const left = tl.pos.x;
            const bot = br.pos.y;
            const right = br.pos.x;
            const center = math.float2((left + right) / 2, (top + bot) / 2);
            if (@as(Event.KeyEnum, key) == Event.KeyEnum.Backspace) {
                self.fullthrottle.add_explosion(center, @floatCast(self.screen_size.width), @floatCast(self.screen_size.height));
                return;
            }
            self.fullthrottle.add_cluster(center, @floatCast(self.screen_size.width), @floatCast(self.screen_size.height));
        }
    }

    pub fn scroll(self: *Renderer, dx: metal.CGFloat, dy: metal.CGFloat, phase: metal.NSEvent.Phase) void {
        _ = dx;
        self.scroll_phase = phase;
        self.ty = self.ty + @as(f32, @floatCast(dy));
        self.editor.cursor_dirty = true;
        self.update_if_needed(std.heap.c_allocator, &.{}) catch @panic("test");
        // const vertical = std.math.fabs(dy) > std.math.fabs(dx);
        // if (vertical) {
        //     self.ty = @min(self.text_height, @max(0.0, self.ty + @as(f32, @floatCast(dy))));
        // } else {
        //     self.tx = @min(self.text_width, @max(0.0, self.tx + @as(f32, @floatCast(dx))));
        // }
    }
};

export fn renderer_create(view: objc.c.id, device: objc.c.id, width: metal.CGFloat, height: metal.CGFloat) *Renderer {
    const alloc = std.heap.c_allocator;
    const font = Font.init(alloc, 48.0, 1024, 1024) catch @panic("Failed to create Font");
    var buf = std.ArrayListUnmanaged(u8){};
    font.serialize(alloc, &buf) catch @panic("OOPS");
    const class = objc.getClass("TetherFont").?;
    const obj = class.msgSend(objc.Object, objc.sel("alloc"), .{});
    defer obj.msgSend(void, objc.sel("release"), .{});
    return Renderer.init(std.heap.c_allocator, font, view, device, width, height);
}

export fn renderer_draw(renderer: *Renderer, view_id: objc.c.id, texture_id: objc.c.id, multisample_texture_id: objc.c.id) void {
    const view = metal.MTKView.from_id(view_id);
    const texture = metal.MTLTexture.from_id(texture_id);
    const multisample_texture = metal.MTLTexture.from_id(multisample_texture_id);
    renderer.draw(view, texture, multisample_texture);
}

export fn renderer_resize(renderer: *Renderer, new_size: metal.CGSize) void {
    renderer.resize(std.heap.c_allocator, new_size) catch @panic("oops");
}

export fn renderer_insert_text(renderer: *Renderer, text: [*:0]const u8, len: usize) void {
    renderer.editor.insert(text[0..len]) catch @panic("oops");
    renderer.update_if_needed(std.heap.c_allocator, &[_]Editor.Edit{}) catch @panic("oops");
}

export fn renderer_handle_keydown(renderer: *Renderer, event_id: objc.c.id) void {
    const event = metal.NSEvent.from_id(event_id);
    renderer.keydown(std.heap.c_allocator, event) catch @panic("oops");
}

export fn renderer_handle_scroll(renderer: *Renderer, dx: metal.CGFloat, dy: metal.CGFloat, phase: metal.NSEvent.Phase) void {
    // renderer.scroll(-dx * 10.0, -dy * 10.0, phase);
    renderer.scroll(-dx * 10.0, -dy, phase);
}

export fn renderer_get_atlas_image(renderer: *Renderer) objc.c.id {
    return renderer.font.create_image();
}

export fn renderer_get_val(renderer: *Renderer) u64 {
    return renderer.some_val;
}

// test "selection triangulation" {
//     const alloc = std.heap.c_allocator;
//     var processor = earcut.Processor(f32){};
//     var vertices = ArrayList(f32){};

//     try vertices.appendSlice(alloc, &.{
//         // line 1
//         0.0,  100.0, 40.0, 100.0, 40.0, 90.0,
//         // line 2
//         20.0, 90.0,  20.0, 80.0,
//         // last point
//          0.0,  80.0,
//     });

//     try processor.process(alloc, vertices.items, null, 2);

//     var j: usize = 0;
//     while (j < processor.triangles.items.len) : (j += 3) {
//         print("TRI\n", .{});
//         const idx0 = processor.triangles.items[j] * 2;
//         const idx1 = processor.triangles.items[j + 1] * 2;
//         const idx2 = processor.triangles.items[j + 2] * 2;
//         const v0 = math.Float2.new(vertices.items[idx0], vertices.items[idx0 + 1]);
//         const v1 = math.Float2.new(vertices.items[idx1], vertices.items[idx1 + 1]);
//         const v2 = math.Float2.new(vertices.items[idx2], vertices.items[idx2 + 1]);
//         v0.debug();
//         v1.debug();
//         v2.debug();
//         print("\n", .{});
//     }
// }
