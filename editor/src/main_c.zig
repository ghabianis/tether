const std = @import("std");
const objc = @import("zig-objc");
const CoreText = @import("coretext/coretext.zig");
const Atlas = @import("./font.zig").Atlas;
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
    Atlas.new();
    return @ptrCast(?[*:0]const u8, "HELLO");
}

// export fn string_len(nsstring: *void) usize {
//     // std.debug.print("nice: {any}\n", CoreText.c);
//     ns
//     const str = NSString.fromId(nsstring);
//     return str.length();
// }