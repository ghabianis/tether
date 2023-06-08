//
//  TetherFont.h
//  tether
//
//  Created by Zack Radisic on 07/06/2023.
//

#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface TetherFont : NSObject
@end


void ShowGlyphsAtPositions(
                           CGContextRef ctx,
                           const CGGlyph *glyphs,
                           const CGPoint *glyph_pos,
                           size_t offset, size_t count);

NS_ASSUME_NONNULL_END
