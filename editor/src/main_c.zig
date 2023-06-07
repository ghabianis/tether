const std = @import("std");
const objc = @import("zig-objc");

pub fn macosVersionAtLeast(major: i64, minor: i64, patch: i64) bool {
    /// Get the objc class from the runtime
    const NSProcessInfo = objc.Class.getClass("NSProcessInfo").?;

    /// Call a class method with no arguments that returns another objc object.
    const info = NSProcessInfo.msgSend(objc.Object, objc.sel("processInfo"), .{});

    /// Call an instance method that returns a boolean and takes a single
    /// argument.
    return info.msgSend(bool, objc.sel("isOperatingSystemAtLeastVersion:"), .{
        NSOperatingSystemVersion{ .major = major, .minor = minor, .patch = patch },
    });
}

export fn say_hello() ? [*:0]const u8 {
    return @ptrCast(?[*:0]const u8, "HELLO");
}