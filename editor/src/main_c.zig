const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("zig-objc");
const Atlas = @import("./font.zig").Atlas;
const metal = @import("./metal.zig");
const math = @import("./math.zig");
const font = @import("./font.zig");

pub const Vertex = extern struct {
    pos: math.Float2,
    tex_coords: math.Float2,
    color: math.Float4,
};

const Renderer = struct {
    view: metal.MTKView,
    device: metal.MTLDevice,
    queue: metal.MTLCommandQueue,
    pipeline: metal.MTLRenderPipelineState,

    vertices: [6]Vertex,
    vertex_buffer: metal.MTLBuffer,
    some_val: u64,

    atlas: font.Atlas,

    pub fn init(alloc: Allocator, atlas: font.Atlas, view_: objc.c.id, device_: objc.c.id) *Renderer {
        const device = metal.MTLDevice.from_id(device_);
        const view = metal.MTKView.from_id(view_);
        const queue = device.make_command_queue() orelse @panic("SHIT");
        var renderer: Renderer = .{
            .view = view,
            .device = device,
            .queue = queue,
            .pipeline = Renderer.build_pipeline(device, view),
            .some_val = 69420,
            .vertices = undefined,
            .vertex_buffer = undefined,
            .atlas = atlas,
        };

        const tl = math.float2(-1.0, 1.0);
        const tr = math.float2(1.0, 1.0);
        const bl = math.float2(-1.0, -1.0);
        const br = math.float2(1.0, -1.0);
        const texCoords = math.float2(0.0, 0.0);
        const color = math.float4(1.0, 0.0, 0.0, 1.0);

        const dummy_vertices: [6]Vertex = .{
            .{ .pos = tl, .tex_coords = texCoords, .color = color },
            .{ .pos = tr, .tex_coords = texCoords, .color = color },
            .{ .pos = bl, .tex_coords = texCoords, .color = color },

            .{ .pos = tr, .tex_coords = texCoords, .color = color },
            .{ .pos = br, .tex_coords = texCoords, .color = color },
            .{ .pos = bl, .tex_coords = texCoords, .color = color },
        };
        renderer.vertices = dummy_vertices;
        renderer.vertex_buffer = device.new_buffer_with_bytes(@ptrCast([*]const u8, &dummy_vertices)[0..(@sizeOf(Vertex) * dummy_vertices.len)], metal.MTLResourceOptions.storage_mode_shared);

        var ptr = alloc.create(Renderer) catch @panic("oom!");
        ptr.* = renderer;
        return ptr;
    }

    fn build_pipeline(device: metal.MTLDevice, view: metal.MTKView) metal.MTLRenderPipelineState {
        const shader_str = @embedFile("./shaders.metal");
        const shader_nsstring = metal.NSString.new_with_bytes(shader_str, .utf8);
        defer shader_nsstring.release();

        var err: ?*anyopaque = null;
        const library = device.obj.msgSend(objc.Object, objc.sel("newLibraryWithSource:options:error:"), .{ shader_nsstring, @as(?*anyopaque, null), &err });
        metal.check_error(err) catch @panic("failed to build library");

        const func_vert = func_vert: {
            const str = metal.NSString.new_with_bytes(
                "vertex_main",
                .utf8,
            );
            defer str.release();

            const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
            break :func_vert objc.Object.fromId(ptr.?);
        };

        const func_frag = func_frag: {
            const str = metal.NSString.new_with_bytes(
                "fragment_main",
                .utf8,
            );
            defer str.release();

            const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
            break :func_frag objc.Object.fromId(ptr.?);
        };

        const vertex_desc = vertex_descriptor: {
            var desc = metal.MTLVertexDescriptor.alloc();
            desc = desc.init();
            desc.set_attribute(0, .{ .format = .float2, .offset = @offsetOf(Vertex, "pos"), .buffer_index = 0 });
            desc.set_attribute(1, .{ .format = .float2, .offset = @offsetOf(Vertex, "tex_coords"), .buffer_index = 0 });
            desc.set_attribute(2, .{ .format = .float4, .offset = @offsetOf(Vertex, "color"), .buffer_index = 0 });
            desc.set_layout(0, .{ .stride = @sizeOf(Vertex) });
            break :vertex_descriptor desc;
        };

        const pipeline_desc = pipeline_desc: {
            var desc = metal.MTLRenderPipelineDescriptor.alloc();
            desc = desc.init();
            desc.set_vertex_function(func_vert);
            desc.set_fragment_function(func_frag);
            desc.set_vertex_descriptor(vertex_desc);
            break :pipeline_desc desc;
        };

        const attachments = objc.Object.fromId(pipeline_desc.obj.getProperty(?*anyopaque, "colorAttachments"));
        {
            const attachment = attachments.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            const pix_fmt = view.color_pixel_format();
            // Value is MTLPixelFormatBGRA8Unorm
            attachment.setProperty("pixelFormat", @as(c_ulong, pix_fmt));

            // Blending. This is required so that our text we render on top
            // of our drawable properly blends into the bg.
            attachment.setProperty("blendingEnabled", true);
            attachment.setProperty("rgbBlendOperation", @enumToInt(metal.MTLBlendOperation.add));
            attachment.setProperty("alphaBlendOperation", @enumToInt(metal.MTLBlendOperation.add));
            attachment.setProperty("sourceRGBBlendFactor", @enumToInt(metal.MTLBlendFactor.one));
            attachment.setProperty("sourceAlphaBlendFactor", @enumToInt(metal.MTLBlendFactor.one));
            attachment.setProperty("destinationRGBBlendFactor", @enumToInt(metal.MTLBlendFactor.one_minus_source_alpha));
            attachment.setProperty("destinationAlphaBlendFactor", @enumToInt(metal.MTLBlendFactor.one_minus_source_alpha));
        }

        const pipeline = device.new_render_pipeline(pipeline_desc) catch @panic("failed to make pipeline");

        return pipeline;
    }

    pub fn draw(self: @This(), view: metal.MTKView) void {
        const command_buffer = self.queue.command_buffer();

        const render_pass_descriptor_id = view.obj.getProperty(objc.c.id, "currentRenderPassDescriptor");
        const drawable_id = view.obj.getProperty(objc.c.id, "currentDrawable");
        if (render_pass_descriptor_id == 0 or drawable_id == 0) return;

        const render_pass_desc = objc.Object.fromId(render_pass_descriptor_id);
        const drawable = objc.Object.fromId(drawable_id);

        const attachments = render_pass_desc.getProperty(objc.Object, "colorAttachments");
        const color_attachment_desc = attachments.msgSend(objc.Object, objc.sel("objectAtIndexedSubscript:"), .{@as(c_ulong, 0)});
        color_attachment_desc.setProperty("loadAction", metal.MTLLoadAction.clear);
        color_attachment_desc.setProperty("clearColor", metal.MTLClearColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 });

        const command_encoder = command_buffer.new_render_command_encoder(render_pass_desc);
        const drawable_size = view.obj.getProperty(metal.CGSize, "drawableSize");
        command_encoder.set_viewport(metal.MTLViewport{ .origin_x = 0.0, .origin_y = 0.0, .width = drawable_size.width, .height = drawable_size.height, .znear = 0.1, .zfar = 100.0 });

        command_encoder.set_render_pipeline_state(self.pipeline);
        command_encoder.set_vertex_buffer(self.vertex_buffer, 0, 0);
        command_encoder.draw_primitives(.triangle, 0, self.vertices.len);
        command_encoder.end_encoding();

        command_buffer.obj.msgSend(void, objc.sel("presentDrawable:"), .{drawable});
        command_buffer.obj.msgSend(void, objc.sel("commit"), .{});
    }
};


export fn renderer_create(view: objc.c.id, device: objc.c.id) *Renderer {
    var atlas = font.Atlas.new(64.0);
    atlas.make_atlas();
    const class = objc.Class.getClass("TetherFont").?;
    const obj = class.msgSend(objc.Object, objc.sel("alloc"), .{});
    defer obj.msgSend(void, objc.sel("release"), .{});
    return Renderer.init(std.heap.c_allocator, atlas, view, device);
}

export fn renderer_draw(renderer: *Renderer, view_id: objc.c.id) void {
    const view = metal.MTKView.from_id(view_id);
    renderer.draw(view);
}

export fn renderer_get_atlas_image(renderer: *Renderer) objc.c.id {
    return renderer.atlas.atlas;
}

export fn renderer_get_val(renderer: *Renderer) u64 {
    return renderer.some_val;
}
