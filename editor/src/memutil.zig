const std = @import("std");

pub fn as_bytes(value_ptr: anytype) []const u8 {
    const tyinfo = comptime @typeInfo(@TypeOf(value_ptr));
    if (comptime @as(std.builtin.TypeId, tyinfo) != std.builtin.TypeId.Pointer) {
        @compileError("Not a pointer");
    }

    return @as([*]const u8, @ptrCast(value_ptr))[0..@sizeOf(tyinfo.Pointer.child)];
}