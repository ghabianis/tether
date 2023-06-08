//
//  ObjcTestView.m
//  tether
//
//  Created by Zack Radisic on 06/06/2023.
//

#import "ObjcTestView.h"
#import <simd/simd.h>
#import <Metal/MTLDevice.h>
#import <CoreText/CoreText.h>

//@interface ObjcTestView ()
//
//@end

@implementation ObjcTestView

- (void) loadView {
    
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [NSColor grayColor].CGColor;
    
    
    NSString *hi = @"HELLO";
    
    NSTextView *text_view = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    text_view.string = @"Hello world";
    [view addSubview:text_view];
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
}


//void GetGlyphsForCharacters(CFStringRef string, CGFloat size)
//{
//    // Get the string length.
//    CFIndex count = CFStringGetLength(string);
// 
//    // Allocate our buffers for characters and glyphs.
//    UniChar *characters = (UniChar *)malloc(sizeof(UniChar) * count);
//    CGGlyph *glyphs = (CGGlyph *)malloc(sizeof(CGGlyph) * count);
// 
//    // Get the characters from the string.
//    CFStringGetCharacters(string, CFRangeMake(0, count), characters);
// 
//    // Get the glyphs for the characters.
//    CTFontGetGlyphsForCharacters(font, characters, glyphs, count);
// 
//    // Do something with the glyphs here. Characters not mapped by this font will be zero.
// 
//    // Free the buffers
////    free(characters);
////    free(glyphs);
//}

@end
