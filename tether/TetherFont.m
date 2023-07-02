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
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreGraphics/CGFont.h>

@implementation TetherFont
- (void) dealloc {
    
    //    sel_
//    MTKTextureLoader* textureLoader = [[MTKTextureLoader alloc] initWithDevice:device];
//
//    NSMutableDictionary *options = [[NSMutableDictionary alloc] init];
//    [options setObject:@(MTLTextureUsageShaderRead) forKey:MTKTextureLoaderOptionTextureUsage];
//    [options setObject:@(MTLStorageModePrivate) forKey:MTKTextureLoaderOptionTextureStorageMode];
//    [options setObject:@(YES) forKey:MTKTextureLoaderOptionSRGB];
    
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
//    CTFontLe
    return CGContextShowGlyphsAtPoint(ctx, x, y, glyphs, 1);
}

void SetTextMatrix(CGContextRef ctx, CGAffineTransform t) {
    CGContextSetTextMatrix(ctx, t);
}
