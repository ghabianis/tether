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
#import <Metal/MTLCommandQueue.h>
#import <Metal/MTLCommandBuffer.h>
#import <Metal/MTLRenderCommandEncoder.h>

@implementation TetherFont
- (void) dealloc {
//    [[NSString alloc] initWithBytes:<#(nonnull const void *)#> length:<#(NSUInteger)#> encoding:<#(NSStringEncoding)#>]
//    NSString ns;
//    [ns getCString:<#(nonnull char *)#> maxLength:<#(NSUInteger)#> encoding:<#(NSStringEncoding)#>]
//    MTLRenderComm
    printf("HOLY FUCKING SHIT IT WORKS!\n");
}
@end

//void shit() {
//    MTLResourceOptions opts;
//    [[NSString alloc] initWithB]
//    MTKView view;
//    view.drawableSize
//    MTLRenderComma vwp;
//    MTLCommandBuffer buf;
//}

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
