//
//  ObjcTestView.m
//  tether
//
//  Created by Zack Radisic on 06/06/2023.
//

#import "ObjcTestView.h"
#import <simd/simd.h>

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

@end
