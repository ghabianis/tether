#include <Cocoa/Cocoa.h>
#include <CoreGraphics/CGFont.h>
#include <MetalKit/MetalKit.h>
#include <objc/runtime.h>

typedef void* Renderer;

Renderer renderer_create(id view, id device);
Renderer renderer_draw(Renderer renderer, id view);
void renderer_str_test();
size_t renderer_get_val(Renderer);