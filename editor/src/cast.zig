const std = @import("std");

pub fn bytes(value_ptr: anytype) []const u8 {
    const tyinfo = comptime @typeInfo(@TypeOf(value_ptr));
    if (comptime @as(std.builtin.TypeId, tyinfo) != std.builtin.TypeId.Pointer) {
        @compileError("Not a pointer");
    }

    return @as([*]const u8, @ptrCast(value_ptr))[0..@sizeOf(tyinfo.Pointer.child)];
}

pub inline fn num(comptime K: type, val: anytype) K {
    const result_type = @typeInfo(K);
    const val_type = @typeInfo(@TypeOf(val));
    const result_kind = comptime @as(std.builtin.TypeId, result_type);
    const val_kind = comptime @as(std.builtin.TypeId, val_type);

    if (!is_num_type(result_kind) or !is_num_type(val_kind)) {
        @compileError("castnum only works on numeric types: " ++ @tagName(result_kind) ++ " " ++ @tagName(val_kind));
    }

    if (result_kind == val_kind) {
        switch (comptime result_kind) {
            .Int => return @as(K, @intCast(val)),
            .Float => return @as(K, @floatCast(val)),
            else => unreachable,
        }
    }

    if (result_kind == .Int) {
        switch (comptime val_kind) {
            .Float => return @as(K, @intFromFloat(val)),
            else => unreachable,
        }
    }

    if (result_kind == .Float) {
        switch (comptime val_kind) {
            .Int => return @as(K, @floatFromInt(val)),
            else => unreachable,
        }
    }
}

inline fn is_num_type(comptime tyid: std.builtin.TypeId) bool {
    switch (tyid) {
        .Int, .Float => return true,
        else => return false,
    }
}