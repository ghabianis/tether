const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("zig-objc");
const Atlas = @import("./font.zig").Atlas;
const metal = @import("./metal.zig");

const Renderer = struct {
    view: metal.MTKView,
    device: metal.MTLDevice,
    queue: metal.MTLCommandQueue,
    some_val: u64,

    pub fn init(alloc: Allocator, view: objc.c.id, device: objc.c.id) *Renderer {
        const rdevice = metal.MTLDevice.from_id(device);
        var renderer: Renderer = .{
            .view = metal.MTKView.from_id(view),
            .device = rdevice,
            .queue = rdevice.make_command_queue() orelse @panic("SHIT"),
            .some_val = 69420,
        };

        var ptr = alloc.create(Renderer) catch @panic("oom!");
        ptr.* = renderer;
        return ptr;
    }

    fn build_pipeline(device: metal.MTLDevice, view: metal.MTKView) metal.MTLRenderPipelineState {
        const shader_str = @embedFile("/Users/zackradisic/Code/tether/tether/Shaders.metal");
        const shader_nsstring = metal.NSString.new_with_bytes(shader_str, .utf8);
        defer shader_nsstring.release();

        var err: ?*anyopaque = null;
        const library = device.obj.msgSend(objc.Object, "newLibraryWithSource:options:error", .{ shader_nsstring, @as(?*anyopaque, null), &err });
        checkError(err);

        const func_vert = func_vert: {
            const str = try metal.NSString.new_with_bytes(
                "vertex_main",
                .utf8,
            );
            defer str.release();

            const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
            break :func_vert objc.Object.fromId(ptr.?);
        };

        const func_frag = func_frag: {
            const str = try metal.NSString.new_with_bytes(
                "fragment_main",
                .utf8,
            );
            defer str.release();

            const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
            break :func_frag objc.Object.fromId(ptr.?);
        };

        _ = library;
        _ = view;
    }

    // fn checkError(err_: ?*anyopaque) !void {
    fn checkError(err_: ?*anyopaque) void {
        if (err_) |err| {
            const nserr = objc.Object.fromId(err);
            const str = @ptrCast(
                *metal.NSString,
                nserr.getProperty(?*anyopaque, "localizedDescription").?,
            );

            var buf: [256]u8 = undefined;

            std.debug.print("meta error={s}\n", .{str.to_c_string(&buf)});

            // return error.MetalFailed;
            @panic("metal error");
        }
    }
};

export fn renderer_create(view: objc.c.id, device: objc.c.id) *Renderer {
    const class = objc.Class.getClass("TetherFont").?;
    const obj = class.msgSend(objc.Object, objc.sel("alloc"), .{});
    defer obj.msgSend(void, objc.sel("release"), .{});
    return Renderer.init(std.heap.c_allocator, view, device);
}

export fn renderer_get_val(renderer: *Renderer) u64 {
    return renderer.some_val;
}
