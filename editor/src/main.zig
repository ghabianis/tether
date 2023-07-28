const std = @import("std");
const Atlas = @import("./font.zig").Atlas;

pub fn main() void {
    Atlas.new();
    std.debug.print("NICE!", .{});
}
