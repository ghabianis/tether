const std = @import("std");
const objc = @import("zig-objc");
const ct = @import("./coretext.zig");
const metal = @import("./metal.zig");
const Conf = @import("./conf.zig");
const cast = @import("./cast.zig");

const Allocator = std.mem.Allocator;
const print = std.debug.print;
const assert = std.debug.assert;

const HashMap = std.AutoHashMap;
const ArrayList = std.ArrayListUnmanaged;

const Font = @This();

/// Visible ASCII characters
const ASCII_CHAR_END: u8 = 127;
const ASCII_CHARS = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\n\r";
const ASCII_CHAR_START: u8 = 10;

/// Common ligatures to pre-populate atlas with
const COMMON_LIGATURES = [_][]const u8{
    //
    "=>",
    "++",
    "->",
    "==",
    "===",
    "!=",
    "!==",
    "<=",
    ">=",
    "::",
    "*=",
    ":=",
    "//",
    "///",
    "<<",
    ">>",
    "!?",
    "!!",
    "..",
    "...",
};

alloc: Allocator,

/// Atlas
atlas: Atlas,

/// Glyphs
glyphs: HashMap(metal.CGGlyph, GlyphInfo),
char_to_glyph: [ASCII_CHAR_END]metal.CGGlyph = [_]metal.CGGlyph{0} ** ASCII_CHAR_END,
cursor: GlyphInfo,
border_cursor: GlyphInfo,

/// Font metrics
font: metal.NSFont,
font_size: u16,
baseline: f32,
ascent: f32,
descent: f32,
leading: f32,
/// The max advance of the ASCII characters
max_adv: f32,

pub fn init(alloc: Allocator, font_size: u16, atlas_width: u32, atlas_height: u32) !Font {
    // const iosevka = metal.NSString.new_with_bytes("Iosevka SS04", .ascii);
    const iosevka = metal.NSString.new_with_bytes("Rec Mono Linear", .ascii);
    // const iosevka = metal.NSString.new_with_bytes("Fira Code", .ascii);
    defer iosevka.release();
    const nsfont = metal.NSFont.from_name_and_size(iosevka, @floatFromInt(font_size));
    nsfont.retain();
    const baseline_nsnumber = metal.NSNumber.from_id(ct.CTFontCopyAttribute(nsfont.obj.value, ct.kCTFontBaselineAdjustAttribute));
    defer baseline_nsnumber.release();
    const baseline = baseline_nsnumber.float_value();

    var font: Font = .{
        .alloc = alloc,

        .atlas = try Atlas.init(alloc, atlas_width, atlas_height, 1),

        .glyphs = HashMap(metal.CGGlyph, GlyphInfo).init(alloc),
        .char_to_glyph = [_]metal.CGGlyph{0} ** ASCII_CHAR_END,
        // These two are set after the atlas is initialized with ASCII chars
        .cursor = GlyphInfo.default(),
        .border_cursor = GlyphInfo.default(),

        .font = nsfont,
        .font_size = font_size,
        .baseline = @floatCast(baseline),
        .ascent = @floatCast(ct.CTFontGetAscent(nsfont.obj.value)),
        .descent = @floatCast(ct.CTFontGetDescent(nsfont.obj.value)),
        .leading = @floatCast(ct.CTFontGetLeading(nsfont.obj.value)),
        .max_adv = 0.0,
    };

    try font.load_default();

    return font;
}

/// Loads the default ASCII chars, COMMON_LIGATURES, and cursor / border cursor glyphs
fn load_default(self: *Font) !void {
    var glyphs = ArrayList(metal.CGGlyph){};
    var glyph_rects = ArrayList(metal.CGRect){};

    // Ideally we'd call `self.get_glyphs_from_str()` to do this, but for some
    // reason it will always put ligatures even when kCTLigatureAttributeName is
    // set to 0, so we build the glyphs manually here.
    const chars = metal.NSString.new_with_bytes(ASCII_CHARS, .ascii);
    defer chars.release();
    const chars_len = chars.length();
    try glyphs.appendNTimes(self.alloc, 0, chars_len);
    try glyph_rects.appendNTimes(self.alloc, metal.CGRect.default(), chars_len);
    var unichars = [_]u16{0} ** ASCII_CHARS.len;
    chars.get_characters(&unichars);
    if (!ct.CTFontGetGlyphsForCharacters(self.font.obj.value, &unichars, glyphs.items.ptr, @as(i64, @intCast(chars_len)))) {
        @panic("Failed to get glyphs for characters");
    }
    _ = ct.CTFontGetBoundingRectsForGlyphs(self.font.obj.value, .horizontal, glyphs.items.ptr, glyph_rects.items.ptr, @as(i64, @intCast(chars_len)));

    var max_width: f32 = 0.0;
    // First do a pass over the glyphs where we add them to the atlas and
    // `self.glyphs` and `self.char_to_glyph`
    for (glyphs.items, 0..) |glyph, i| {
        const rect = glyph_rects.items[i];
        const region = try self.add_glyph_to_atlas_no_resize(rect);
        const advance: f32 = @floatFromInt(self.get_advance(glyph));
        const glyph_info: GlyphInfo = .{
            .rect = rect,
            .advance = advance,
            .tx = cast.num(f32, region.x) / cast.num(f32, self.atlas.width),
            .ty = cast.num(f32, region.y) / cast.num(f32, self.atlas.height),
        };

        if (!(region.width == 0 and region.height == 0)) {
            try self.rasterize_glyph(glyph, rect, region);
        }

        self.char_to_glyph[ASCII_CHARS[i]] = glyph;
        try self.glyphs.put(glyph, glyph_info);

        self.max_adv = @max(self.max_adv, advance);
        max_width = @max(max_width, @as(f32, @floatCast(rect.size.width)));
        max_width = @max(max_width, @as(f32, @floatCast(rect.size.width)));
    }

    // Now create the cursor and border cursor glyphs
    {
        const cursor_rect: metal.CGRect = .{
            .size = .{ .width = max_width, .height = self.ascent + self.descent },
            .origin = .{ .x = 0.0, .y = 0.0 },
        };

        var cursor_glyph_info = GlyphInfo.default();
        cursor_glyph_info.rect = cursor_rect;
        cursor_glyph_info.advance = self.max_adv;
        var border_cursor_glyph_info = cursor_glyph_info;

        const cursor_region = try self.add_glyph_to_atlas_no_resize(cursor_rect);
        const border_cursor_region = try self.add_glyph_to_atlas_no_resize(cursor_rect);
        cursor_glyph_info.tx = @as(f32, @floatFromInt(cursor_region.x)) / @as(f32, @floatFromInt(self.atlas.width));
        cursor_glyph_info.ty = @as(f32, @floatFromInt(cursor_region.y)) / @as(f32, @floatFromInt(self.atlas.height));
        border_cursor_glyph_info.tx = @as(f32, @floatFromInt(border_cursor_region.x)) / @as(f32, @floatFromInt(self.atlas.width));
        border_cursor_glyph_info.ty = @as(f32, @floatFromInt(border_cursor_region.y)) / @as(f32, @floatFromInt(self.atlas.height));

        self.cursor = cursor_glyph_info;
        self.border_cursor = border_cursor_glyph_info;

        // Now rasterize the cursor and border cursor
        const width: usize = @intFromFloat(@ceil(cursor_rect.size.width));
        const height: usize = @intFromFloat(@ceil(cursor_rect.size.height));
        const color_space = ct.CGColorSpaceCreateDeviceGray();
        defer ct.CGColorRelease(color_space);
        const ctx = ct.CGBitmapContextCreate(null, width, height, 8, width, color_space, ct.kCGImageAlphaNone & ct.kCGBitmapAlphaInfoMask);

        if (ctx == null) @panic("Failed to make CGContext");
        defer ct.CGContextRelease(ctx);

        // Draw the cursor
        ct.CGContextSetGrayFillColor(ctx, 1.0, 1.0);
        ct.CGContextFillRect(ctx, cursor_rect);
        var data: [*]u8 = @ptrCast(@alignCast(ct.CGBitmapContextGetData(ctx)));
        self.atlas.set_region(cursor_region, data[0 .. width * height * self.atlas.depth]);

        // Draw the border cursor
        // https://stackoverflow.com/questions/14258924/uiview-drawrect-is-it-possible-to-stroke-inside-a-path
        ct.CGContextClearRect(ctx, cursor_rect);
        ct.CGContextSetGrayFillColor(ctx, 0.0, 0.0);
        ct.CGContextFillRect(ctx, cursor_rect);
        ct.CGContextClipToRect(ctx, cursor_rect);
        ct.CGContextSetGrayFillColor(ctx, 1.0, 1.0);
        ct.CGContextSetGrayStrokeColor(ctx, 1.0, 1.0);
        ct.CGContextStrokeRectWithWidth(ctx, cursor_rect, 4.0);
        data = @ptrCast(@alignCast(ct.CGBitmapContextGetData(ctx)));
        self.atlas.set_region(border_cursor_region, data[0 .. width * height * self.atlas.depth]);
    }

    // // Now properly assign the correct texture coordinates to the glyphs
    // var iter = self.glyphs.iterator();
    // while (iter.next()) |entry| {
    //     var glyph_info: *GlyphInfo = entry.value_ptr;
    //     glyph_info.tx /= @as(f32, @floatFromInt(self.atlas.width));
    //     glyph_info.ty /= @as(f32, @floatFromInt(self.atlas.height));
    //     assert(glyph_info.ty >= 0);
    //     assert(glyph_info.tx >= 0);
    // }
}

/// Adds glyph to atlas by reserving a region for it, accounting for border. Disallows resizing.
fn add_glyph_to_atlas_no_resize(self: *Font, rect: metal.CGRect) !Atlas.Region {
    return self.add_glyph_to_atlas_impl(rect, false);
}

/// Adds glyph to atlas by reserving a region for it, accounting for border. Allows resizing.
fn add_glyph_to_atlas(self: *Font, rect: metal.CGRect) !Atlas.Region {
    return self.add_glyph_to_atlas_impl(rect, true);
}

/// Adds glyph to atlas by reserving a region for it, accounting for border.
fn add_glyph_to_atlas_impl(self: *Font, rect: metal.CGRect, comptime allow_resize: bool) !Atlas.Region {
    // Add border to prevent artifacts from texture sampling
    const border = 2;

    const width: u32 = @intFromFloat(@ceil(rect.size.width));
    const height: u32 = @intFromFloat(@ceil(rect.size.height));

    if (width == 0 and height == 0) return Atlas.Region.default();

    var region = try self.atlas.get_region(self.alloc, width + border * 2, height + border * 2);
    if (region == null) {
        if (comptime allow_resize) @panic("Exceeded atlas dimensions but resizing not allowed in this context.");
        try self.atlas.enlarge(self.alloc, self.atlas.width * 2, self.atlas.height * 2);
        return try self.add_glyph_to_atlas_impl(rect, allow_resize);
    }

    region.?.width -= border * 2;
    region.?.height -= border * 2;
    region.?.x += border;
    region.?.y += border;

    return region.?;
}

/// Grow the atlas bitmap to the new size.
///
/// This updates the texture coordinates of each GlyphInfo in `self.glyphs`
///
/// TODO: Recalculating texcoords involves multiplying original texcoords with original atlas size. Does this result in floating point miscalculations that cause artifacts? Investigate.
fn enlarge_atlas(self: *Font, new_width: u32, new_height: u32) !void {
    const old_width = self.atlas.width;
    const old_height = self.atlas.height;
    try self.atlas.enlarge(self.alloc, new_width, new_height);
    var iter = self.glyphs.valueIterator();
    for (iter.next()) |glyph_info| {
        glyph_info.tx *= old_width * (1.0 / new_width);
        glyph_info.ty *= old_height * (1.0 / new_height);
    }
}

fn rasterize_glyph(self: *Font, glyph: metal.CGGlyph, rect: metal.CGRect, region: Atlas.Region) !void {
    const width: u32 = @intFromFloat(@ceil(rect.size.width));
    const height: u32 = @intFromFloat(@ceil(rect.size.height));

    const color_space = ct.CGColorSpaceCreateDeviceGray();
    const ctx = ct.CGBitmapContextCreate(null, @intCast(width), @intCast(height), 8, width, color_space, ct.kCGImageAlphaNone & ct.kCGBitmapAlphaInfoMask);
    if (ctx == null) {
        @panic("Failed to create bitmap context");
    }

    defer ct.CGColorSpaceRelease(color_space);
    defer ct.CGContextRelease(ctx);

    ct.CGContextSetGrayFillColor(ctx, 1.0, 0.0);
    ct.CGContextFillRect(ctx, metal.CGRect.new(0.0, 0.0, @floatFromInt(width), @floatFromInt(height)));

    ct.CGContextSetFont(ctx, self.font.obj.value);
    ct.CGContextSetFontSize(ctx, @floatFromInt(self.font_size));

    ct.CGContextSetShouldAntialias(ctx, true);
    ct.CGContextSetAllowsAntialiasing(ctx, true);
    ct.CGContextSetShouldSmoothFonts(ctx, true);
    ct.CGContextSetAllowsFontSmoothing(ctx, true);

    // ct.CGContextSetShouldSubpixelPositionFonts(ctx, false);
    // ct.CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
    // ct.CGContextSetAllowsFontSubpixelPositioning(ctx, false);
    // ct.CGContextSetAllowsFontSubpixelQuantization(ctx, false);

    ct.CGContextSetShouldSubpixelPositionFonts(ctx, true);
    ct.CGContextSetShouldSubpixelQuantizeFonts(ctx, true);
    ct.CGContextSetAllowsFontSubpixelPositioning(ctx, true);
    ct.CGContextSetAllowsFontSubpixelQuantization(ctx, true);

    ct.CGContextSetGrayFillColor(ctx, 1.0, 1.0);

    // CGContext draws with the glyph's origin into account, for
    // example x = -2 will be to the left we want to draw at ox & oy,
    // so subtract the glyph's origin values to do this.
    //
    // We use CGPath because CGContextShowGlyphs* caused off-by-one
    // problems causing the glyphs to be rendered incorrectly.
    const transform = ct.CGAffineTransform{ .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = -rect.origin.x, .ty = -rect.origin.y };
    const path = ct.CTFontCreatePathForGlyph(self.font.obj.value, glyph, &transform);
    defer ct.CGPathRelease(path);
    ct.CGContextAddPath(ctx, path);
    ct.CGContextFillPath(ctx);

    const data: [*]u8 = @ptrCast(@alignCast(ct.CGBitmapContextGetData(ctx)));

    self.atlas.set_region(region, data[0 .. width * height * self.atlas.depth]);
}

pub fn lookup(self: *Font, g: metal.CGGlyph) !*const GlyphInfo {
    return self.glyphs.getPtr(g) orelse {
        try self.get_glyph(g);
        return self.glyphs.getPtr(g) orelse @panic("This should not happen.");
    };
}

pub fn lookup_char(self: *Font, char: u8) !*const GlyphInfo {
    const key = self.char_to_glyph[char];
    return self.lookup(key);
}

pub fn lookup_char_from_str(self: *Font, str: []const u8) !*const GlyphInfo {
    return self.lookup_char(str[0]);
}

pub fn lookup_glyph_rects(self: *Font, glyphs: []const metal.CGGlyph, glyph_rects: []metal.CGRect) !void {
    var i: usize = 0;
    for (glyphs) |glyph| {
        const glyph_info = try self.lookup(glyph);
        glyph_rects[i] = glyph_info.rect;
        i += 1;
    }
}

fn get_glyph(self: *Font, glyph: metal.CGGlyph) !void {
    if (self.glyphs.contains(glyph)) return;

    var glyphs = [_]metal.CGGlyph{glyph};
    var glyph_rect = [_]metal.CGRect{metal.CGRect.default()};
    _ = ct.CTFontGetBoundingRectsForGlyphs(self.font.obj.value, .horizontal, @ptrCast(&glyphs), @ptrCast(&glyph_rect), 1);

    const rect = glyph_rect[0];
    const region = try self.add_glyph_to_atlas(rect);
    const advance: f32 = @floatFromInt(self.get_advance(glyph));
    const glyph_info: GlyphInfo = .{
        .rect = rect,
        .advance = advance,
        .tx = cast.num(f32, region.x) / cast.num(f32, self.atlas.width),
        .ty = cast.num(f32, region.y) / cast.num(f32, self.atlas.height),
    };
    self.max_adv = @max(self.max_adv, advance);
    try self.glyphs.put(glyph, glyph_info);
    try self.rasterize_glyph(glyph, rect, region);
}

fn get_glyphs_from_str(self: *Font, alloc: Allocator, glyphs: *ArrayList(metal.CGGlyph), glyph_rects: *ArrayList(metal.CGRect), str: []const u8, comptime ligatures: bool) !void {
    const attributed_string = self.font_attribute_string(str, ligatures);
    defer ct.CFRelease(attributed_string);

    const line = ct.CTLineCreateWithAttributedString(attributed_string);
    const glyph_runs = ct.CTLineGetGlyphRuns(line);
    const glyph_run = ct.CFArrayGetValueAtIndex(glyph_runs, 0);
    const glyph_count = @as(usize, @intCast(ct.CTRunGetGlyphCount(glyph_run)));

    const start = glyphs.items.len;
    try glyphs.appendNTimes(alloc, 0, glyph_count);
    try glyph_rects.appendNTimes(alloc, metal.CGRect.default(), glyph_count);
    const end = glyphs.items.len;
    const glyph_slice = glyphs.items[start..end];
    const glyph_rects_slice = glyph_rects.items[start..end];

    ct.CTRunGetGlyphs(glyph_run, .{ .location = 0, .length = @as(i64, @intCast(glyph_count)) }, glyph_slice.ptr);
    _ = ct.CTFontGetBoundingRectsForGlyphs(self.font.obj.value, .horizontal, glyph_slice.ptr, glyph_rects_slice.ptr, @as(i64, @intCast(glyph_count)));
}

pub fn create_image(self: *Font) ct.CGImageRef {
    const color_space = ct.CGColorSpaceCreateDeviceGray();
    defer ct.CGColorSpaceRelease(color_space);
    const ctx = ct.CGBitmapContextCreate(@ptrCast(self.atlas.data.ptr), self.atlas.width, self.atlas.height, 8, self.atlas.width, color_space, ct.kCGImageAlphaNone & ct.kCGBitmapAlphaInfoMask);
    defer ct.CGContextRelease(ctx);
    const image = ct.CGBitmapContextCreateImage(ctx);
    return image;
}

pub fn create_texture(self: *Font, device: metal.MTLDevice) metal.MTLTexture {
    const color_space = ct.CGColorSpaceCreateDeviceGray();
    defer ct.CGColorSpaceRelease(color_space);

    // const ctx = ct.CGBitmapContextCreate(@ptrCast(self.atlas.data.ptr), self.atlas.width, self.atlas.height, 8, 0, color_space, ct.kCGImageAlphaNone);
    const ctx = ct.CGBitmapContextCreate(@ptrCast(self.atlas.data.ptr), self.atlas.width, self.atlas.height, 8, self.atlas.width, color_space, ct.kCGImageAlphaNone & ct.kCGBitmapAlphaInfoMask);
    defer ct.CGContextRelease(ctx);

    const image = ct.CGBitmapContextCreateImage(ctx);
    const tex_opts = metal.NSDictionary.new_mutable();
    tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_enum(metal.MTLTextureUsage.shader_read), metal.MTKTextureLoaderOptionTextureUsage });
    tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_enum(metal.MTLStorageMode.private), metal.MTKTextureLoaderOptionTextureStorageMode });
    tex_opts.msgSend(void, objc.sel("setObject:forKey:"), .{ metal.NSNumber.from_int(0), metal.MTKTextureLoaderOptionSRGB });

    const tex_loader_class = objc.getClass("MTKTextureLoader").?;
    var tex_loader = tex_loader_class.msgSend(objc.Object, objc.sel("alloc"), .{});
    tex_loader = tex_loader.msgSend(objc.Object, objc.sel("initWithDevice:"), .{device});

    const err: ?*anyopaque = null;
    const tex = tex_loader.msgSend(objc.Object, objc.sel("newTextureWithCGImage:options:error:"), .{
        image,
        tex_opts,
    });
    metal.check_error(err) catch @panic("failed to make texture");

    self.atlas.dirty = false;

    return metal.MTLTexture.from_obj(tex);
}

fn get_advance(self: *Font, glyph: metal.CGGlyph) i32 {
    var glyphs = [_]metal.CGGlyph{glyph};
    var advances = [_]metal.CGSize{metal.CGSize.default()};
    _ = ct.CTFontGetAdvancesForGlyphs(self.font.obj.value, .horizontal, &glyphs, &advances, 1);

    return @intFromFloat(@ceil((advances[0].width)));
}

/// To get ligatures you need to create an attributed string with kCTLigatureAttributeName set to 1 or 2,
/// then later you can create a CTLine from that attributed string and get the glyph runs from that.
///
/// Reference: https://stackoverflow.com/questions/26770894/coretext-get-ligature-glyph
fn font_attribute_string(self: *Font, chars_c: []const u8, comptime enable_ligatures: bool) ct.CFAttributedStringRef {
    const chars = metal.NSString.new_with_bytes(chars_c, .ascii);
    defer chars.release();
    const ligature_value = metal.NSNumber.number_with_int(if (comptime enable_ligatures) 2 else 0);
    defer ligature_value.release();
    const len = @as(i64, @intCast(chars.length()));

    const attributed_string = ct.CFAttributedStringCreateMutable(0, len);
    ct.CFAttributedStringReplaceString(attributed_string, .{ .location = 0, .length = 0 }, chars.obj.value);
    const attrib_len = ct.CFAttributedStringGetLength(attributed_string);
    ct.CFAttributedStringSetAttribute(attributed_string, .{ .location = 0, .length = attrib_len }, ct.kCTLigatureAttributeName, ligature_value.obj.value);
    ct.CFAttributedStringSetAttribute(attributed_string, .{ .location = 0, .length = attrib_len }, ct.kCTFontAttributeName, self.font.obj.value);

    return attributed_string;
}

pub fn str_width(self: *Font, str: []const u8) f64 {
    // TODO: PERF: create this string once at startup
    const attributed_string = self.font_attribute_string(str, false);
    defer ct.CFRelease(attributed_string);

    const line = ct.CTLineCreateWithAttributedString(attributed_string);
    defer ct.CFRelease(line);

    const width = ct.CTLineGetTypographicBounds(line, null, null, null);
    return width;
}

pub fn cursor_ty(self: *const Font) f32 {
    return self.cursor.ty;
}

pub fn cursor_tx(self: *const Font) f32 {
    return self.cursor.ty;
}

pub fn cursor_h(self: *const Font) f32 {
    return @floatCast(self.cursor.rect.width());
}

pub fn cursor_w(self: *const Font) f32 {
    return @floatCast(self.cursor.rect.height());
}

pub fn serialize(self: *const Font, alloc: Allocator, buf: *ArrayList(u8)) !void {
    try Serialize.serialize(self, alloc, buf);
}

pub const Serialize = struct {
    pub const Glyph = extern struct {
        tx: f32 align(8),
        ty: f32,
        bitmap_w: f32,
        bitmap_h: f32,
        bitmap_l: f32,
        bitmap_t: f32,
        advance_x: f32,
    };

    pub const Header = extern struct {
        width: u32 align(8),
        height: u32,
        ascent: u32,
        descent: u32,
        glyph_len: u32,
        _pad: u32 = 0,
    };

    pub fn serialize(self: *const Font, alloc: Allocator, buf: *ArrayList(u8)) !void {
        const glyph_len = self.glyphs.unmanaged.size;
        const header: Header = .{
            .width = self.atlas.width,
            .height = self.atlas.height,
            .ascent = @intFromFloat(@ceil(self.ascent)),
            .descent = @intFromFloat(@ceil(self.descent)),
            .glyph_len = glyph_len,
        };

        try buf.appendSlice(alloc, cast.bytes(&header));

        for (ASCII_CHAR_START..ASCII_CHAR_END) |char_raw| {
            const glyph = self.char_to_glyph[char_raw];
            const glyph_info = self.glyphs.get(glyph) orelse continue;

            const ser_glyph = Serialize.Glyph{
                .tx = glyph_info.tx,
                .ty = glyph_info.ty,
                .bitmap_w = @floatCast(glyph_info.rect.size.width),
                .bitmap_h = @floatCast(glyph_info.rect.size.height),
                .bitmap_t = @floatCast(glyph_info.rect.origin.y + glyph_info.rect.size.height),
                .bitmap_l = @floatCast(glyph_info.rect.origin.x + glyph_info.rect.size.width),
                .advance_x = @floatCast(glyph_info.advance),
            };

            try buf.appendSlice(alloc, cast.bytes(&ser_glyph));
        }

        var file = std.fs.createFileAbsolute("/Users/zackradisic/Code/tether/editor/atlas.bin", .{}) catch @panic("OOPS");
        defer file.close();
        file.writeAll(buf.items[0..]) catch @panic("oops");
    }
};

pub const GlyphInfo = struct {
    const Self = @This();

    const DEFAULT = Self.default();

    rect: metal.CGRect,
    tx: f32,
    ty: f32,
    advance: f32,

    fn default() Self {
        return Self{
            .rect = metal.CGRect.default(),
            .tx = 0.0,
            .ty = 0.0,
            .advance = 0.0,
        };
    }
};

/// This is a direct port from: https://github.com/rougier/freetype-gl/blob/513fa238357f7c11a9f427965fe336aae7955297/texture-atlas.c
const Atlas = struct {
    width: u32,
    height: u32,
    /// How many channels
    depth: u32,
    used: usize,
    data: []u8,
    nodes: ArrayList(Node),
    dirty: bool,

    const Node = struct {
        x: u32,
        y: u32,
        width: u32,
    };

    const Region = struct {
        x: u32,
        y: u32,
        width: u32,
        height: u32,

        fn default() Region {
            return .{
                .x = 0,
                .y = 0,
                .width = 0,
                .height = 0,
            };
        }
    };

    pub fn init(alloc: Allocator, width: u32, height: u32, depth: u32) !Atlas {
        std.debug.assert(depth > 0 and depth <= 4);

        var self: Atlas = .{
            // Initialize with the ASCII chars and cursor and border cursor.
            .nodes = try ArrayList(Node).initCapacity(alloc, ASCII_CHARS.len + 2),
            .used = 0,
            .width = width,
            .height = height,
            .depth = depth,
            .dirty = true,
            .data = try alloc.alloc(u8, width * height * depth),
        };
        @memset(self.data, 0);
        try self.enlarge(alloc, width, height);

        // We want a one pixel border around the whole atlas to avoid any artefact when
        // sampling texture
        const node: Node = .{
            .x = 1,
            .y = 1,
            .width = width - 2,
        };
        try self.nodes.append(alloc, node);

        return self;
    }

    pub fn fit(self: *Atlas, index: usize, width: usize, height: usize) ?u32 {
        var node: *Node = &self.nodes.items[index];
        const x = node.x;
        var y = node.y;
        // var width_left = node.width;
        var width_left = width;
        var i = index;

        if (x + width > self.width - 1) {
            return null;
        }

        while (width_left > 0) {
            node = &self.nodes.items[i];
            if (node.y > y) {
                y = node.y;
            }
            if (y + height > self.height - 1) {
                return null;
            }
            width_left -|= node.width;
            i += 1;
        }

        return y;
    }

    pub fn set_region(self: *Atlas, region: Region, data: []u8) void {
        assert(region.x <= self.width - 1);
        assert(region.y <= self.height - 1);
        assert(region.x + region.width <= self.width - 1);
        assert(region.y + region.height <= self.height - 1);
        assert(region.width * region.height * self.depth == data.len);

        const depth = self.depth;

        // Copy the data to the atlas data
        for (0..region.height) |i| {
            const len = region.width * depth;
            const dest_start = (((region.y + i) * self.width) + region.x) * depth;
            const dest = self.data[dest_start .. dest_start + len];

            const offset = i * region.width * depth;
            const source = data[offset .. offset + len];

            @memcpy(dest, source);
        }

        self.dirty = true;
    }

    /// Reserves a `width` x `height` rectangle in the atlas, returning the region.
    ///
    /// If you plan to reserve a region for a glyph, instead use
    /// `Font.add_glyph_to_atlas()`, which adds border to prevent artifacts from
    /// texture sampling.
    pub fn get_region(self: *Atlas, alloc: Allocator, width: u32, height: u32) !?Region {
        var maybe_best_index: ?u32 = null;
        var best_height: usize = std.math.maxInt(usize);
        var best_width: usize = std.math.maxInt(usize);

        var region: Region = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        };
        if (region.width == 0 and region.height == 0) return Region.default();

        for (0..self.nodes.items.len) |i| {
            const maybe_y = self.fit(i, width, height);
            if (maybe_y) |y| {
                const node = self.nodes.items[i];

                if ((y + height < best_height) or (y + height == best_height and node.width > 0 and node.width < best_width)) {
                    best_height = y + height;
                    maybe_best_index = @intCast(i);
                    best_width = node.width;
                    region.x = node.x;
                    region.y = y;
                }
            }
        }

        // Couldn't find space for region
        if (maybe_best_index == null) {
            return null;
        }

        const best_index = maybe_best_index.?;

        const node_to_add = .{
            .x = region.x,
            .y = region.y + height,
            .width = width,
        };

        try self.nodes.insert(alloc, best_index, node_to_add);

        var i: u32 = best_index + 1;
        while (i < self.nodes.items.len) : (i += 1) {
            const node = &self.nodes.items[i];
            const prev = self.nodes.items[i - 1];

            if (node.x < prev.x + prev.width) {
                const shrink = prev.x + prev.width - node.x;
                node.x += shrink;
                node.width -|= shrink;
                if (node.width <= 0) {
                    _ = self.nodes.orderedRemove(i);
                    i -= 1;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        self.merge();
        self.used += width * height;
        self.dirty = true;
        return region;
    }

    fn merge(self: *Atlas) void {
        var node: *Node = undefined;
        var next: *Node = undefined;

        var i: usize = 0;
        while (i < self.nodes.items.len - 1) {
            node = &self.nodes.items[i];
            next = &self.nodes.items[i + 1];
            if (node.y == next.y) {
                node.width += next.width;
                _ = self.nodes.orderedRemove(i + 1);
                continue;
            }
            i += 1;
        }
    }

    fn enlarge(self: *Atlas, alloc: Allocator, width: u32, height: u32) !void {
        assert(width >= self.width);
        assert(height >= self.height);
        if (width == self.width and height == self.height) return;

        const width_old = self.width;
        const height_old = self.height;

        const data_old = self.data;
        defer alloc.free(data_old);

        self.data = try alloc.realloc(self.data, width * height * self.depth);
        @memset(self.data, 0);

        self.width = width;
        self.height = height;

        // Add node reflecting the gained space on the right
        try self.nodes.append(alloc, .{
            .x = width_old - 1,
            .y = 1,
            .width = width - width_old,
        });

        // Copy over data from the old buffer, skipping first row and column because of the margin
        const pixel_size = self.depth;
        const old_row_size = width_old * pixel_size;
        self.set_region(.{
            .x = 1,
            .y = 1,
            .width = width_old - 2,
            .height = height_old - 2,
        }, data_old[old_row_size + pixel_size ..]);
    }
};
