//
//  TetherFont.h
//  tether
//
//  Created by Zack Radisic on 08/06/2023.
//

#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#include <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

@interface TetherFont : NSObject

@end

void ShowGlyphsAtPositions(
                           CGContextRef ctx,
                           const CGGlyph *glyphs,
                           const CGPoint *glyph_pos,
size_t offset, size_t count);

void ShowGlyphsAtPoint(CGContextRef ctx, const CGGlyph *glyphs, CGFloat x, CGFloat y);

void SetTextMatrix(CGContextRef ctx, CGAffineTransform t);

NS_ASSUME_NONNULL_END
