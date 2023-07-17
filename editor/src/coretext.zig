const objc = @import("zig-objc");
const metal = @import("./metal.zig");

pub const CTFontRef = objc.c.id;
pub const Unichar = u16;
pub const CFIndex = i64;

pub const CTFontOrientation = enum(u32) {
    default = 0,
    horizontal = 1,
    vertical = 2,
};

pub const CFRange = extern struct {
    location: CFIndex,
    length: CFIndex,
};

pub const CFTypeRef = objc.c.id;
pub const CFStringRef = objc.c.id;
pub const CFAttributedStringRef = objc.c.id;
pub const CFMutableAttributedStringRef = objc.c.id;
pub const CFArrayRef = objc.c.id;
pub const CGContextRef = objc.c.id;
pub const CGColorSpaceRef = objc.c.id;
pub const CGColorRef = objc.c.id;
pub const CGFontRef = objc.c.id;
pub const CGImageRef = objc.c.id;
pub const CTLineRef = objc.c.id;
pub const CTRunRef = objc.c.id;

pub extern "C" const kCGColorSpaceSRGB: objc.c.id;
pub extern "C" const kCTFontBaselineAdjustAttribute: objc.c.id;
pub extern "C" const kCTLigatureAttributeName: objc.c.id;
pub extern "C" const kCTFontAttributeName: objc.c.id;
pub const kCGImageAlphaPremultipliedLast: u32 = 1;

pub extern "C" fn CTFontGetAscent(font: CTFontRef) metal.CGFloat;
pub extern "C" fn CTFontGetDescent(font: CTFontRef) metal.CGFloat;
pub extern "C" fn CTFontGetLeading(font: CTFontRef) metal.CGFloat;
pub extern "C" fn CTFontGetBoundingBox(font: CTFontRef) metal.CGRect;
pub extern "C" fn CTFontGetGlyphsForCharacters(font: CTFontRef, characters: [*]const Unichar, glyphs: [*]metal.CGGlyph, count: CFIndex) bool;
pub extern "C" fn CTFontGetBoundingRectsForGlyphs(font: CTFontRef, orientation: CTFontOrientation, glyphs: [*]const metal.CGGlyph, bounding_rects: [*]metal.CGRect, count: CFIndex) metal.CGRect;
pub extern "C" fn CTFontCopyGraphicsFont(font: CTFontRef, attributes: ?[*]const objc.c.id) objc.c.id;
pub extern "C" fn CTFontGetAdvancesForGlyphs(font: CTFontRef, orientation: CTFontOrientation, glyphs: [*]const metal.CGGlyph, advances: [*]metal.CGSize, count: CFIndex) f64;
pub extern "C" fn CTFontCopyAttribute(font: CTFontRef, attribute: CFStringRef) CFTypeRef;
pub extern "C" fn CTFontGetLigatureCaretPositions(font: CTFontRef, glyph: metal.CGGlyph, positions: [*]metal.CGFloat, max_positions: CFIndex) CFIndex;
pub extern "C" fn CTLineCreateWithAttributedString(string: CFAttributedStringRef) CTLineRef;
pub extern "C" fn CTLineGetGlyphRuns(line: CTLineRef) CFArrayRef;
pub extern "C" fn CTRunGetGlyphs(run: CTRunRef, range: CFRange, buffer: [*]metal.CGGlyph) void;
pub extern "C" fn CTRunGetGlyphCount(run: CTRunRef) CFIndex;
pub extern "C" fn CTRunGetPositions(run: CTRunRef, range: CFRange, buffer: [*]metal.CGPoint) void;

pub extern "C" fn CGFontGetGlyphAdvances(font: CGFontRef, glyphs: [*]metal.CGGlyph, count: usize, advances: [*]i32) bool;
pub extern "C" fn CGFontGetDescent(font: CGFontRef) i32;

pub extern "C" fn CFAttributedStringCreateMutable(alloc: objc.c.id, max_length: CFIndex) CFMutableAttributedStringRef;
pub extern "C" fn CFAttributedStringReplaceString(string: CFMutableAttributedStringRef, range: CFRange, replacement: CFStringRef) void;
pub extern "C" fn CFAttributedStringSetAttribute(string: CFMutableAttributedStringRef, range: CFRange, attribute: CFStringRef, value: CFTypeRef) void;
pub extern "C" fn CFAttributedStringGetLength(string: CFAttributedStringRef) CFIndex;

pub extern "C" fn CFArrayGetValueAtIndex(array: CFArrayRef, index: CFIndex) CFTypeRef;

pub extern "C" fn CFRelease(obj: CFTypeRef) void;

// pub extern "C" const kCGImageAlphaPremultipliedLast: u32;
pub extern "C" fn CGColorSpaceCreateWithName(name: objc.c.id) CGColorSpaceRef;
pub extern "C" fn CGBitmapContextCreate(
    data: ?[*]void,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    space: CGColorSpaceRef,
    bitmap_info: usize,
) CGContextRef;
pub extern "C" fn CGColorCreateGenericRGB(r: metal.CGFloat, g: metal.CGFloat, b: metal.CGFloat, a: metal.CGFloat) CGColorRef;
pub extern "C" fn CGContextSetFillColorWithColor(ctx: CGContextRef, color: CGColorRef) void;
pub extern "C" fn CGContextFillRect(ctx: CGContextRef, rect: metal.CGRect) void;
pub extern "C" fn CGContextStrokeRect(ctx: CGContextRef, rect: metal.CGRect) void;
pub extern "C" fn CGContextStrokeRectWithWidth(ctx: CGContextRef, rect: metal.CGRect, width: metal.CGFloat) void;
pub extern "C" fn CGContextSetStrokeColorWithColor(ctx: CGContextRef, color: CGColorRef) void;
pub extern "C" fn CGContextSetFont(ctx: CGContextRef, font: CGFontRef) void;
pub extern "C" fn CGContextSetFontSize(ctx: CGContextRef, size: metal.CGFloat) void;

pub extern "C" fn CGContextSetShouldAntialias(ctx: CGContextRef, val: bool) void;
pub extern "C" fn CGContextSetAllowsAntialiasing(ctx: CGContextRef, val: bool) void;
pub extern "C" fn CGContextSetShouldSmoothFonts(ctx: CGContextRef, val: bool) void;
pub extern "C" fn CGContextSetAllowsFontSmoothing(ctx: CGContextRef, val: bool) void;
pub extern "C" fn CGContextSetShouldSubpixelPositionFonts(ctx: CGContextRef, val: bool) void;
pub extern "C" fn CGContextSetShouldSubpixelQuantizeFonts(ctx: CGContextRef, val: bool) void;
pub extern "C" fn CGContextSetAllowsFontSubpixelPositioning(ctx: CGContextRef, val: bool) void;
pub extern "C" fn CGContextSetAllowsFontSubpixelQuantization(ctx: CGContextRef, val: bool) void;

pub extern "C" fn CGContextShowGlyphsAtPoint(ctx: CGContextRef, x: metal.CGFloat, y: metal.CGFloat, glyphs: [*]const metal.CGGlyph, count: usize) void;
pub extern "C" fn CGBitmapContextCreateImage(ctx: CGContextRef) CGImageRef;

pub extern "C" fn CGColorRelease(color: CGColorRef) void;
pub extern "C" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
pub extern "C" fn CGContextRelease(ctx: CGContextRef) void;

pub extern "C" fn CFRetain(val: objc.c.id) objc.c.id;
