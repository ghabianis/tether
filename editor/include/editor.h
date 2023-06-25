#include <Cocoa/Cocoa.h>
#include <CoreGraphics/CoreGraphics.h>
#include <MetalKit/MetalKit.h>
#include <objc/runtime.h>

typedef void* Renderer;

Renderer renderer_create(id view, id device);
Renderer renderer_draw(Renderer renderer, id view);
void renderer_resize(Renderer renderer, CGSize new_size);
id renderer_get_atlas_image(Renderer renderer);
size_t renderer_get_val(Renderer);