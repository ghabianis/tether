const std = @import("std");
const objc = @import("zig-objc");
// const ns = @import("ns.zig");

const NSString = struct {
    obj: objc.Object,

    fn fromId(id: anytype) NSString {
        return .{
            .obj = objc.Object.fromId(id)
        };
    }

    fn length(self: *const NSString) usize {
        return self.obj.msgSend(usize, objc.sel("length"), .{});
    }
};

export fn say_hello() ? [*:0]const u8 {
    return @ptrCast(?[*:0]const u8, "HELLO");
}

export fn string_len(nsstring: *void) usize {
    const str = NSString.fromId(nsstring);
    return str.length();
}