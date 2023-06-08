//
//  TetherFont.m
//  tether
//
//  Created by Zack Radisic on 07/06/2023.
//

#import "TetherFont.h"

//typedef struct {
//    CGGlyph glyph;
//    CGPathRef path;
//} GlyphInfo;

@implementation TetherFont
//CTFontRef font;
//GlyphInfo *glyph_info;

//- (instancetype)initWithName:(CFStringRef) name
//                    withSize:(CGFloat) size {
//    int count = 128 - 32;
//
//    font = CTFontCreateWithName(name, size, NULL);
//    glyph_info = (GlyphInfo *)malloc(sizeof(GlyphInfo) * count);
//
//    char *glyph_chars = (char *)malloc(sizeof(char) * (count + 1));
//    for (int i = 32; i < 128; i++) {
//        glyph_chars[i - 32] = (char) i;
//    }
//    glyph_chars[count] = '\0';
//
//    CFStringRef glyphStr = CFStringCreateWithCStringNoCopy(kCFAllocatorDefault, glyph_chars, kCFStringEncodingUTF8, kCFAllocatorDefault);
//
//
//    // Allocate our buffers for characters and glyphs.
//    UniChar *characters = (UniChar *)malloc(sizeof(UniChar) * count);
//    CGGlyph *glyphs = (CGGlyph *)malloc(sizeof(CGGlyph) * count);
//
//    // Get the characters from the string.
//    CFStringGetCharacters(glyphStr, CFRangeMake(0, count), characters);
//
//    // Get the glyphs for the characters.
//    CTFontGetGlyphsForCharacters(font, characters, glyphs, count);
//
//    for (int i = 0; i < count; i++) {
//        CGGlyph glyph = glyphs[i];
//        CGPathRef glyph_path = CTFontCreatePathForGlyph(font, glyph, NULL);
//        glyph_info[i] = (GlyphInfo){ glyph, glyph_path };
//    }
//
//
//
//    // Free the buffers
//    free(characters);
//    free(glyphs);
//
//    return self;
//}
//
//-(void)dealloc {
//    if (glyph_info != NULL) {
//        free(glyph_info);
//        glyph_info = NULL;
//    }
//}

void ShowGlyphsAtPositions(
                           CGContextRef ctx,
                           const CGGlyph *glyphs,
                           const CGPoint *glyph_pos,
                           size_t offset, size_t count)
{
    return CGContextShowGlyphsAtPositions(ctx, &glyphs[offset], &glyph_pos[offset], count);
}
@end
