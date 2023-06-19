//
//  TetherFont.m
//  tether
//
//  Created by Zack Radisic on 08/06/2023.
//

#import "TetherFont.h"
#import <MetalKit/MetalKit.h>
#import <Metal/Metal.h>
#import <Metal/MTLDevice.h>

@implementation TetherFont
- (void) dealloc {
    [MTLVertexDescriptor init];
    printf("HOLY FUCKING SHIT IT WORKS!\n");
}
@end

void ShowGlyphsAtPositions(
                           CGContextRef ctx,
                           const CGGlyph *glyphs,
                           const CGPoint *glyph_pos,
                           size_t offset, size_t count)
{
    return CGContextShowGlyphsAtPositions(ctx, &glyphs[offset], &glyph_pos[offset], count);
}

void ShowGlyphsAtPoint(CGContextRef ctx, const CGGlyph *glyphs, CGFloat x, CGFloat y) {
    return CGContextShowGlyphsAtPoint(ctx, x, y, glyphs, 1);
}

void SetTextMatrix(CGContextRef ctx, CGAffineTransform t) {
    CGContextSetTextMatrix(ctx, t);
}
