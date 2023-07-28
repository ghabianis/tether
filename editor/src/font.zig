const std = @import("std");
const objc = @import("zig-objc");
const ct = @import("./coretext.zig");
const metal = @import("./metal.zig");
const Conf = @import("./conf.zig");

const Allocator = std.mem.Allocator;
const print = std.debug.print;

/// TODO: Use BTree: https://bitbucket.org/luizufu/zig-btree/src/master/
const HashMap = std.AutoHashMap;
const ArrayList = std.ArrayListUnmanaged;

pub const GlyphInfo = struct {
    const Self = @This();

    const DEFAULT = Self.default();

    /// TODO: Not really necessary to store this anymore
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

pub fn intCeil(float: f64) i32 {
    return @floatToInt(i32, @ceil(float));
}

/// rounding down the number plus half is the same of rounding to the nearest integer
fn round(float: anytype) @TypeOf(float) {
    return @trunc(float + 0.5);
}

pub const Atlas = struct {
    const Self = @This();
    const MAX_WIDTH: f64 = 1024.0;
    const CHAR_START: u8 = 32;
    const CHAR_END: u8 = 127;
    const CHAR_LEN: u8 = Self.CHAR_END - Self.CHAR_START;

    /// NSFont
    font: objc.Object,
    font_size: metal.CGFloat,

    glyph_info: HashMap(metal.CGGlyph, GlyphInfo),
    char_to_glyph: [CHAR_END]metal.CGGlyph = [_]metal.CGGlyph{0} ** CHAR_END,

    max_glyph_height: i32,
    max_glyph_width: i32,
    max_glyph_width_before_ligatures: i32,
    max_adv_before_ligatures: f32,

    atlas: ct.CGImageRef,
    width: i32,
    height: i32,
    baseline: f32,
    ascent: f32,
    descent: f32,
    leading: f32,
    lowest_origin: f32,

    cursor_tx: f32,
    cursor_ty: f32,
    cursor_w: f32,
    cursor_h: f32,

    border_cursor_tx: f32,
    border_cursor_ty: f32,
    border_cursor_w: f32,
    border_cursor_h: f32,

    pub fn new(alloc: Allocator, font_size: metal.CGFloat) Self {
        const iosevka = metal.NSString.new_with_bytes("Iosevka SS04", .ascii);
        // const iosevka = metal.NSString.new_with_bytes("Iosevka-SS04-Light", .ascii);
        // const iosevka = metal.NSString.new_with_bytes("Iosevka-SS04-Italic", .ascii);
        // const iosevka = metal.NSString.new_with_bytes("Fira Code", .ascii);
        const Class = objc.Class.getClass("NSFont").?;
        const font = Class.msgSend(objc.Object, objc.sel("fontWithName:size:"), .{ iosevka, font_size });
        const baseline_nsnumber = metal.NSNumber.from_id(ct.CTFontCopyAttribute(font.value, ct.kCTFontBaselineAdjustAttribute));
        defer baseline_nsnumber.release();
        const baseline = baseline_nsnumber.float_value();
        const bb = ct.CTFontGetBoundingBox(font.value);
        _ = bb;
        const glyph_info = HashMap(metal.CGGlyph, GlyphInfo).init(alloc);

        return Self{
            .font = font,
            .font_size = font_size,
            .glyph_info = glyph_info,
            .max_glyph_height = undefined,
            .max_glyph_width = undefined,
            .max_glyph_width_before_ligatures = undefined,
            .max_adv_before_ligatures = undefined,

            .atlas = undefined,
            .width = undefined,
            .height = undefined,
            .baseline = @floatCast(f32, baseline),
            .ascent = @floatCast(f32, ct.CTFontGetAscent(font.value)),
            .descent = undefined,
            .leading = @floatCast(f32, ct.CTFontGetLeading(font.value)),
            .lowest_origin = undefined,

            .cursor_tx = undefined,
            .cursor_ty = undefined,
            .cursor_w = undefined,
            .cursor_h = undefined,

            .border_cursor_tx = undefined,
            .border_cursor_ty = undefined,
            .border_cursor_w = undefined,
            .border_cursor_h = undefined,
        };
    }

    pub fn get_glyph_rects(self: *Self, glyphs: []const metal.CGGlyph, glyph_rects: []metal.CGRect) void {
        var i: usize = 0;
        for (glyphs) |glyph| {
            const glyph_info = self.lookup(glyph);
            glyph_rects[i] = glyph_info.rect;
            i += 1;
        }
    }

    pub fn lookup(self: *const Self, g: metal.CGGlyph) *const GlyphInfo {
        return self.glyph_info.getPtr(g) orelse {
            print("Unhandled glyph: {d}\n", .{g});
            @panic("TODO: Handle missing glyph");
        };
    }

    pub fn lookup_char(self: *const Self, char: u8) *const GlyphInfo {
        if (char < CHAR_START) return &GlyphInfo.DEFAULT;
        std.debug.assert(char < CHAR_END);
        const key = self.char_to_glyph[char];
        return self.lookup(key);
    }

    pub fn lookup_char_from_str(self: *const Self, str: []const u8) *const GlyphInfo {
        return self.lookup_char(str[0]);
    }

    fn get_advance(self: *Self, cgfont: ct.CGFontRef, glyph: metal.CGGlyph) i32 {
        _ = cgfont;
        var glyphs = [_]metal.CGGlyph{glyph};
        var advances = [_]metal.CGSize{metal.CGSize.default()};
        _ = ct.CTFontGetAdvancesForGlyphs(self.font.value, .horizontal, &glyphs, &advances, 1);

        return intCeil(advances[0].width);
    }

    /// To get ligatures you need to create an attributed string with kCTLigatureAttributeName set to 1 or 2,
    /// then later you can create a CTLine from that attributed string and get the glyph runs from that.
    ///
    /// Reference:https://stackoverflow.com/questions/26770894/coretext-get-ligature-glyph
    fn font_attribute_string(self: *Self, chars_c: []const u8, comptime enable_ligatures: bool) ct.CFAttributedStringRef {
        const chars = metal.NSString.new_with_bytes(chars_c, .ascii);
        defer chars.release();
        const ligature_value = metal.NSNumber.number_with_int(if (comptime enable_ligatures) 2 else 0);
        defer ligature_value.release();
        const len = @intCast(i64, chars.length());

        const attributed_string = ct.CFAttributedStringCreateMutable(0, len);
        ct.CFAttributedStringReplaceString(attributed_string, .{ .location = 0, .length = 0 }, chars.obj.value);
        const attrib_len = ct.CFAttributedStringGetLength(attributed_string);
        ct.CFAttributedStringSetAttribute(attributed_string, .{ .location = 0, .length = attrib_len }, ct.kCTLigatureAttributeName, ligature_value.obj.value);
        ct.CFAttributedStringSetAttribute(attributed_string, .{ .location = 0, .length = attrib_len }, ct.kCTFontAttributeName, self.font.value);

        return attributed_string;
    }

    pub fn str_width(self: *Self, str: []const u8) f64 {
        // TODO: PERF: create this string once at startup
        const attributed_string = self.font_attribute_string(str, false);
        defer ct.CFRelease(attributed_string);

        const line = ct.CTLineCreateWithAttributedString(attributed_string);
        defer ct.CFRelease(line);

        const width = ct.CTLineGetTypographicBounds(line, null, null, null);
        return width;
    }

    fn get_glyphs(self: *Self, alloc: Allocator, glyphs: *ArrayList(metal.CGGlyph), glyph_rects: *ArrayList(metal.CGRect), str: []const u8, comptime ligatures: bool) !void {
        const attributed_string = self.font_attribute_string(str, ligatures);
        defer ct.CFRelease(attributed_string);

        const line = ct.CTLineCreateWithAttributedString(attributed_string);
        const glyph_runs = ct.CTLineGetGlyphRuns(line);
        const glyph_run = ct.CFArrayGetValueAtIndex(glyph_runs, 0);
        const glyph_count = @intCast(usize, ct.CTRunGetGlyphCount(glyph_run));

        const start = glyphs.items.len;
        try glyphs.appendNTimes(alloc, 0, glyph_count);
        try glyph_rects.appendNTimes(alloc, metal.CGRect.default(), glyph_count);
        const end = glyphs.items.len;
        const glyph_slice = glyphs.items[start..end];
        const glyph_rects_slice = glyph_rects.items[start..end];

        ct.CTRunGetGlyphs(glyph_run, .{ .location = 0, .length = @intCast(i64, glyph_count) }, glyph_slice.ptr);
        _ = ct.CTFontGetBoundingRectsForGlyphs(self.font.value, .horizontal, glyph_slice.ptr, glyph_rects_slice.ptr, @intCast(i64, glyph_count));
    }

    pub fn make_atlas(self: *Self, alloc: Allocator) !void {
        var glyphs = ArrayList(metal.CGGlyph){};
        var glyph_rects = ArrayList(metal.CGRect){};

        const chars_c = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\n    ";
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
            // these are sus glyphs
            ".?",
            ".?.",
            "..",
            "...",
            "!?",
            "!!",
            "\\\\",
        };

        // For some reason this will always put ligatures even when kCTLigatureAttributeName is set to 0,
        // so we build the glyphs manually here.
        // try self.get_glyphs(alloc, &glyphs, &glyph_rects, chars_c, false);
        const chars = metal.NSString.new_with_bytes(chars_c, .ascii);
        const chars_len = chars.length();
        try glyphs.appendNTimes(alloc, 0, chars_len);
        try glyph_rects.appendNTimes(alloc, metal.CGRect.default(), chars_len);
        var unichars = [_]u16{0} ** chars_c.len;
        chars.get_characters(&unichars);
        if (!ct.CTFontGetGlyphsForCharacters(self.font.value, &unichars, glyphs.items.ptr, @intCast(i64, chars_len))) {
            @panic("Failed to get glyphs for characters");
        }
        _ = ct.CTFontGetBoundingRectsForGlyphs(self.font.value, .horizontal, glyphs.items.ptr, glyph_rects.items.ptr, @intCast(i64, chars_len));

        for (COMMON_LIGATURES) |ligature| {
            try self.get_glyphs(alloc, &glyphs, &glyph_rects, ligature[0..ligature.len], true);
        }

        const glyphs_len = glyphs.items.len;

        const cgfont = ct.CTFontCopyGraphicsFont(self.font.value, null);

        var roww: i32 = 0;
        var rowh: i32 = 0;
        var w: i32 = 0;
        var h: i32 = 0;
        var max_w_before_ligatures: i32 = 0;
        var max_w: i32 = 0;
        var max_advance: i32 = 0;
        var max_advance_before_ligatures: f32 = 0;
        var lowest_origin: f32 = 0.0;
        {
            var i: usize = 0;
            while (i < glyphs_len) : (i += 1) {
                const glyph = glyphs.items[i];
                const glyph_rect: metal.CGRect = glyph_rects.items[i];
                const advance = self.get_advance(cgfont, glyph);
                max_advance = @max(max_advance, advance);
                lowest_origin = @min(lowest_origin, @floatCast(f32, glyph_rect.origin.y));

                if (roww + glyph_rect.widthCeil() + advance + 1 >= intCeil(Self.MAX_WIDTH)) {
                    w = @max(w, roww);
                    h += rowh;
                    roww = 0;
                }

                // ligatures screw up the max width calculation
                if (i < chars_len) {
                    max_advance_before_ligatures = @max(max_advance_before_ligatures, @intToFloat(f32, advance));
                    max_w_before_ligatures = @max(max_w, glyph_rect.widthCeil());
                    max_w = @max(max_w_before_ligatures, glyph_rect.widthCeil());
                } else {
                    max_w = @max(max_w, glyph_rect.widthCeil());
                }

                roww += glyph_rect.widthCeil() + advance + 1;
                rowh = @max(rowh, glyph_rect.heightCeil());
            }
        }

        // Add the texture for cursor
        if (roww + max_w + 1 >= intCeil(Self.MAX_WIDTH)) {
            w = @max(w, roww);
            h += rowh;
            roww = 0;
        }
        roww += max_w + max_advance + 1;

        const max_h = rowh;
        self.max_glyph_height = max_h;
        self.max_glyph_width = max_w;
        self.max_glyph_width_before_ligatures = max_w_before_ligatures;
        w = @max(w, roww);
        h += rowh;
        h += max_h;

        const tex_w = w;
        const tex_h = h;
        self.width = tex_w;
        self.height = tex_h;

        const name = ct.kCGColorSpaceSRGB;
        const color_space = ct.CGColorSpaceCreateWithName(name);
        const ctx = ct.CGBitmapContextCreate(null, @intCast(usize, tex_w), @intCast(usize, tex_h), 8, 0, color_space, ct.kCGImageAlphaPremultipliedLast);
        const fill_color = ct.CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.0);
        defer ct.CGColorSpaceRelease(color_space);
        defer ct.CGContextRelease(ctx);
        defer ct.CGColorRelease(fill_color);

        ct.CGContextSetFillColorWithColor(ctx, fill_color);
        ct.CGContextFillRect(ctx, metal.CGRect.new(0.0, 0.0, @intToFloat(f64, tex_w), @intToFloat(f64, tex_h)));

        ct.CGContextSetFont(ctx, cgfont);
        ct.CGContextSetFontSize(ctx, self.font_size);

        // self.descent = @intToFloat(f32, ct.CGFontGetDescent(cgfont));
        self.descent = @ceil(@floatCast(f32, ct.CTFontGetDescent(self.font.value)));

        ct.CGContextSetShouldAntialias(ctx, true);
        ct.CGContextSetAllowsAntialiasing(ctx, true);
        ct.CGContextSetShouldSmoothFonts(ctx, true);
        ct.CGContextSetAllowsFontSmoothing(ctx, true);

        // ct.CGContextSetShouldSubpixelPositionFonts(ctx, true);
        // ct.CGContextSetShouldSubpixelQuantizeFonts(ctx, true);
        // ct.CGContextSetAllowsFontSubpixelPositioning(ctx, true);
        // ct.CGContextSetAllowsFontSubpixelQuantization(ctx, true);

        ct.CGContextSetShouldSubpixelPositionFonts(ctx, false);
        ct.CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
        ct.CGContextSetAllowsFontSubpixelPositioning(ctx, false);
        ct.CGContextSetAllowsFontSubpixelQuantization(ctx, false);

        const text_color = ct.CGColorCreateGenericRGB(1.0, 0.0, 0.0, 1.0);
        const other_text_color = ct.CGColorCreateGenericRGB(0.0, 0.0, 1.0, 0.2);
        defer ct.CGColorRelease(text_color);
        defer ct.CGColorRelease(other_text_color);

        ct.CGContextSetFillColorWithColor(ctx, text_color);

        var ox: i32 = 0;
        var oy: i32 = 10;
        {
            var i: usize = 0;
            while (i < glyphs_len) : (i += 1) {
                const glyph = glyphs.items[i];
                const rect = glyph_rects.items[i];

                const rectw = rect.widthCeil();
                const recth = rect.heightCeil();
                _ = recth;

                const advance = self.get_advance(cgfont, glyph);

                if (ox + rectw + max_advance + 1 >= intCeil(Self.MAX_WIDTH)) {
                    ox = 0;
                    oy += max_h;
                    rowh = 0;
                }

                const tx = @intToFloat(f32, ox) / @intToFloat(f32, tex_w);
                const ty = (@intToFloat(f32, tex_h) - (@intToFloat(f32, oy))) / @intToFloat(f32, tex_h);
                var the_glyph = [_]metal.CGGlyph{glyph};
                _ = the_glyph;

                // CGContext draws with the glyph's origin into account, for
                // example x = -2 will be to the left we want to draw at ox & oy,
                // so subtract the glyph's origin values to do this.
                //
                // We use CGPath because CGContextShowGlyphs* caused off-by-one
                // problems causing the glyphs to be rendered incorrectly.
                const transform = ct.CGAffineTransform{ .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .tx = @intToFloat(f64, ox) - rect.origin.x, .ty = @intToFloat(f64, oy) - rect.origin.y };
                const path = ct.CTFontCreatePathForGlyph(self.font.value, glyph, &transform);
                defer ct.CGPathRelease(path);
                ct.CGContextAddPath(ctx, path);
                ct.CGContextFillPath(ctx);

                var new_rect = rect;

                if (i < chars_c.len) {
                    const char = chars_c[i];
                    self.char_to_glyph[char] = glyph;
                }

                try self.glyph_info.put(glyph, .{
                    .rect = new_rect,
                    .tx = tx,
                    .ty = @floatCast(f32, ty),
                    .advance = @intToFloat(f32, advance),
                });

                ox += rectw + max_advance + 1;
            }

            // add cursor glyph
            if (ox + max_w_before_ligatures + max_advance + 1 >= intCeil(Self.MAX_WIDTH)) {
                ox = 0;
                oy += max_h;
                rowh = 0;
            }
            ox += max_w_before_ligatures + @floatToInt(i32, @ceil(max_advance_before_ligatures)) + 1;
            const cursor_rect = .{
                .origin = .{ .x = @intToFloat(f32, ox), .y = @intToFloat(f32, oy) },
                .size = .{ .width = @intToFloat(f32, max_w_before_ligatures), .height = @intToFloat(f32, max_h) },
            };
            const tx = @intToFloat(f32, ox) / @intToFloat(f32, tex_w);
            const ty = (@intToFloat(f32, tex_h) - (@intToFloat(f32, oy))) / @intToFloat(f32, tex_h);
            ct.CGContextFillRect(ctx, cursor_rect);
            self.cursor_tx = tx;
            self.cursor_ty = ty;
            self.cursor_w = cursor_rect.size.width / @intToFloat(f32, tex_w);
            self.cursor_h = cursor_rect.size.height / @intToFloat(f32, tex_h);

            // add rectangular cursor glyph
            if (ox + max_w_before_ligatures + max_advance + 1 >= intCeil(Self.MAX_WIDTH)) {
                ox = 0;
                oy += max_h;
                rowh = 0;
            }
            ox += max_w_before_ligatures + @floatToInt(i32, @ceil(max_advance_before_ligatures)) + 1;
            const rectangular_cursor_rect = .{
                .origin = .{ .x = @intToFloat(f32, ox), .y = @intToFloat(f32, oy) },
                .size = .{ .width = @intToFloat(f32, max_w_before_ligatures), .height = @intToFloat(f32, max_h) },
            };
            const border_tx = @intToFloat(f32, ox) / @intToFloat(f32, tex_w);
            const border_ty = (@intToFloat(f32, tex_h) - (@intToFloat(f32, oy))) / @intToFloat(f32, tex_h);
            // https://stackoverflow.com/questions/14258924/uiview-drawrect-is-it-possible-to-stroke-inside-a-path
            ct.CGContextClipToRect(ctx, rectangular_cursor_rect);
            ct.CGContextStrokeRectWithWidth(ctx, rectangular_cursor_rect, 4.0);
            self.border_cursor_tx = border_tx;
            self.border_cursor_ty = border_ty;
            self.border_cursor_w = rectangular_cursor_rect.size.width / @intToFloat(f32, tex_w);
            self.border_cursor_h = rectangular_cursor_rect.size.height / @intToFloat(f32, tex_h);
        }

        self.atlas = ct.CGBitmapContextCreateImage(ctx);
        self.max_adv_before_ligatures = max_advance_before_ligatures;

        print("MAX ADV BEFORE LIGATURES: {d}\n", .{self.max_glyph_width_before_ligatures});
    }
};
