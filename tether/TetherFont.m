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
//    [options setObject:@(MTLTextureUsageShaderRead) forKey:MTKTextureLoaderOptionTextureUsage];
//    [options setObject:@(MTLStorageModePrivate) forKey:MTKTextureLoaderOptionTextureStorageMode];
//    [options setObject:@(YES) forKey:MTKTextureLoaderOptionSRGB];
    
//    NSPasteboard *pb = NSPasteboard.generalPasteboard;
//    [pb stringForType:]
//    CTFontDrawGlyphs(<#CTFontRef  _Nonnull font#>, <#const CGGlyph * _Nonnull glyphs#>, <#const CGPoint * _Nonnull positions#>, <#size_t count#>, <#CGContextRef  _Nonnull context#>)
    NSEventPhase p;
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

void DoShit(CTFontRef font) {
    CTFontRef fontRef = CTFontCreateWithName((CFStringRef)@"Helvetica", 12, NULL);
    NSNumber *baselineOffset = (__bridge NSNumber *)CTFontCopyAttribute(fontRef, kCTFontBaselineAdjustAttribute);
    CGFloat baseline = [baselineOffset floatValue];
    CFRelease(fontRef);
}

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

void RandomTest(CFAttributedStringRef str) {
//    CTFrameGetLines(jdlkf)
    CTFramesetterRef frame_setter = CTFramesetterCreateWithAttributedString(str);
//    CTFrameRef frame = CTFramesetterCreateFrame(frame_setter, CFRangeMake(0, 0), <#CGPathRef  _Nonnull path#>, <#CFDictionaryRef  _Nullable frameAttributes#>);
    
    
}
