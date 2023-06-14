const freetype = @cImport({
    @cInclude("ft2build.h");
    @cInclude("FT_FREETYPE_H");
});

pub const Glyph = struct {
    advance_x: f32,
    advance_y: f32,
    bitmap_w: f32,
    bitmap_h: f32,
    bitmap_l: f32,
    bitmap_t: f32,
    tx: f32, // x offset of glyph in texture coordinates
    ty: f32, // y offset of glyph in texture coordinates}
};

pub const Atlas = struct {

    pub fn new() void {
        freetype.
        const FT_Library = freetype.Library;
        freetype.FT_Init_FreeType(&FT_Library);
    }
};
