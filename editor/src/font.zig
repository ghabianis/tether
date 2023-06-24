const std = @import("std");
const objc = @import("zig-objc");
const ct = @import("./coretext.zig");
const metal = @import("./metal.zig");

pub const GlyphInfo = struct {
    const Self = @This();
    glyph: metal.CGGlyph,
    rect: metal.CGRect,
    tx: f32,
    ty: f32,
    advance: f32,

    fn default() Self {
        return Self{
            .glyph = 0,
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

pub const Atlas = struct {
    const Self = @This();
    const CHAR_START: u8 = 32;
    const CHAR_END: u8 = 127;
    const CHARS_LEN: u8 = CHAR_END - CHAR_START;
    const MAX_WIDTH: f64 = 1024.0;

    /// NSFont
    font: objc.Object,
    font_size: metal.CGFloat,

    glyph_info: [CHAR_END]GlyphInfo,
    max_glyph_height: i32,

    atlas: ct.CGImageRef,

    pub fn new(font_size: metal.CGFloat) Self {
        const iosevka = metal.NSString.new_with_bytes("Iosevka SS04", .ascii);
        const Class = objc.Class.getClass("NSFont").?;
        const font = Class.msgSend(objc.Object, objc.sel("fontWithName:size:"), .{ iosevka, font_size });

        return Self{ 
            .font = font, 
            .font_size = font_size, 
            .glyph_info = [_]GlyphInfo{GlyphInfo.default()} ** CHAR_END, 
            .max_glyph_height = undefined,  
            .atlas = undefined,
        };
    }

    fn get_advance(self: *Self, glyph: metal.CGGlyph) i32 {
        var glyphs = [_]metal.CGGlyph{glyph};
        var advances = [_]metal.CGSize{metal.CGSize.default()};
        _ = ct.CTFontGetAdvancesForGlyphs(self.font.value, .horizontal, @ptrCast([*]const u16, &glyphs), @ptrCast([*]metal.CGSize, &advances), 1);
        return intCeil((advances[0].width / 1000.0) * self.font_size);
    }

    pub fn make_atlas(self: *Self) void {
        var chars_c = [_]u8{0} ** CHARS_LEN;
        {
            var i: u8 = 32;
            while (i < Self.CHAR_END) : (i += 1) {
                chars_c[i - 32] = i;
            }
        }

        const chars = metal.NSString.new_with_bytes(&chars_c, .ascii);
        const chars_len = chars.length();
        var unichars = [_]u16{0} ** CHARS_LEN;
        chars.get_characters(&unichars);
        var glyphs = [_]metal.CGGlyph{0} ** CHARS_LEN;
        if (!ct.CTFontGetGlyphsForCharacters(self.font.value, &unichars, &glyphs, @intCast(i64, chars_len))) {
            @panic("Failed to get glyphs for characters");
        }

        var glyph_rects: [CHARS_LEN]metal.CGRect = [_]metal.CGRect{metal.CGRect.default()} ** CHARS_LEN;
        _ = ct.CTFontGetBoundingRectsForGlyphs(self.font.value, .horizontal, &glyphs, &glyph_rects, @intCast(i64, chars_len));
        const cgfont = ct.CTFontCopyGraphicsFont(self.font.value, null);

        var roww: i32 = 0;
        var rowh: i32 = 0;
        var w: i32 = 0;
        var h: i32 = 0;
        var max_w: i32 = 0;
        {
            var i: usize = 32;
            while (i < Self.CHAR_END) : (i += 1) {
                const j: usize = i - 32;
                const glyph = glyphs[j];
                const glyph_rect: metal.CGRect = glyph_rects[j];
                const advance = self.get_advance(glyph);
                // const advance: i32 = 100;

                if (roww + glyph_rect.widthCeil() + advance + 1 >= intCeil(Self.MAX_WIDTH)) {
                    w = @max(w, roww);
                    h += rowh;
                    roww = 0;
                }

                max_w = @max(max_w, glyph_rect.widthCeil());

                roww += glyph_rect.widthCeil() + advance + 1;
                rowh = @max(rowh, glyph_rect.heightCeil());
            }
        }

        const max_h = rowh;
        self.max_glyph_height = max_h;
        w = @max(w, roww);
        h += rowh;

        const tex_w = w;
        const tex_h = h;

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

        ct.CGContextSetShouldAntialias(ctx, true);
        ct.CGContextSetAllowsAntialiasing(ctx, true);
        ct.CGContextSetShouldSmoothFonts(ctx, true);
        ct.CGContextSetAllowsFontSmoothing(ctx, true);

        ct.CGContextSetShouldSubpixelPositionFonts(ctx, false);
        ct.CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
        ct.CGContextSetAllowsFontSubpixelPositioning(ctx, false);
        ct.CGContextSetAllowsFontSubpixelQuantization(ctx, false);

        const text_color = ct.CGColorCreateGenericRGB(1.0, 0.0, 0.0, 1.0);
        defer ct.CGColorRelease(text_color);

        ct.CGContextSetFillColorWithColor(ctx, text_color);

        var ox: i32 = 0;
        var oy: i32 = 0;

        {
            var i: usize = 32;
            while (i < CHAR_END): (i += 1) {
                const j: usize = i - 32;
                const glyph = glyphs[j];
                const rect = glyph_rects[j];

                const rectw = rect.widthCeil();
                const recth = rect.heightCeil();
                _ = recth;

                const advance = self.get_advance(glyph);
                // const advance: i32 = 100;

                if (ox + rectw + advance + 1 >= intCeil(Self.MAX_WIDTH)) {
                    ox = 0;
                    oy += max_h;
                    rowh = 0;
                }

                const tx = @intToFloat(f32, ox) / @intToFloat(f32, tex_w);
                const ty = (@intToFloat(f32, tex_h) - (@intToFloat(f32, oy) + rect.origin.y)) / @intToFloat(f32, tex_h);
                var the_glyph = [_]metal.CGGlyph{glyph};

                ct.CGContextShowGlyphsAtPoint(ctx, @intToFloat(f64, ox), @intToFloat(f64, oy), @ptrCast([*]const metal.CGGlyph, &the_glyph), 1);

                var new_rect = rect;
                new_rect = metal.CGRect.new(new_rect.origin.x, new_rect.origin.y, @intToFloat(f64, advance), new_rect.height());

                self.glyph_info[i] = .{
                    .glyph = glyph,
                    .rect = new_rect,
                    .tx = tx,
                    .ty = @floatCast(f32, ty),
                    .advance = @intToFloat(f32, advance),
                };

                ox += rectw + advance + 1;
            }
        }

        self.atlas = ct.CGBitmapContextCreateImage(ctx);
    }
};
