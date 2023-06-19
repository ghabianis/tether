const objc = @import("zig-objc");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Object = objc.Object;

// defined as unsigned long in NSObjCRuntime.h
pub const NSUInteger = usize;
pub const NSStringEncoding = enum (NSUInteger) {
    ascii = 1,
    utf8 = 4,
};

pub const NSString = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());

    pub fn length(self: NSString) usize {
        return self.obj.msgSend(usize, objc.sel("length"), .{});
    }

    pub fn new_with_bytes(bytes: []const u8, encoding: NSStringEncoding) NSString {
        const object = @This().alloc();
        object.init_with_bytes(bytes, encoding);
        return object;
    }

    pub fn init_with_bytes(self: NSString, bytes: []u8, encoding: NSStringEncoding) void {
        self.obj.msgSend(void, "initWithBytes:length:encoding:", .{ bytes.ptr, bytes.len, encoding });
    }

    pub fn to_c_string(self: NSString, buf: []const u8) [*:0]const u8 {
        const got_error = self.obj.msgSend(bool, "getCString:maxLength:encoding", .{buf.ptr, buf.len, NSStringEncoding.ascii});
        if (got_error) {
            @panic("oh no!");
        }
        return @ptrCast([*:0]const u8, buf);
    }
};

pub const MTLRenderCommandEncoder = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());
};

pub const MTKView = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());
};

pub const MTLDevice = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());

    pub fn make_command_queue(self: MTLDevice) ?MTLCommandQueue {
        const value = self.obj.msgSend(objc.c.id, objc.sel("newCommandQueue"), .{});
        if (value == 0) {
            return null;
        }

        return MTLCommandQueue.from_id(value);
    }
};

pub const MTLCommandQueue = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());
};

pub const MTLRenderPipelineState = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());
};

pub const MTLVertexDescriptor = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());
};

fn DefineObject(comptime T: type) type {
    return struct {

        pub fn from_id(id: anytype) T {
            return .{
                .obj = Object.fromId(id),
            };
        }

        pub fn alloc() T {
            const class = objc.Class.getClass(@typeName(T));
            const object = class.msgSend(objc.Object, "alloc", .{});
            return .{.obj = object};
        }

        pub fn init(self: @This()) void {
            self.obj.msgSend(void, objc.sel("init"), .{});
        }

        pub fn release(self: @This()) void {
            self.obj.msgSend(void, objc.sel("release"), .{});
        }
    };
}

// pub fn object_from_id(comptime T: type, id: anytype) T {
//     return .{
//         .obj = Object.fromId(id)
//     };
// }

// pub fn object_alloc(comptime T: type, class_name: [:0]const u8) T {
//     const class = objc.Class.getClass(class_name);
//     const object = class.msgSend(objc.Object, "alloc", .{});
//     return .{.obj = object};
// }