const std = @import("std");
const Allocator = std.mem.Allocator;

const objc = @import("zig-objc");
const metal = @import("./metal.zig");

const NSPasteboard = metal.NSPasteboard;
const NSString = metal.NSString;
const NSMutableArray = metal.NSMutableArray;

const Self = @This();

/// NSPasteboard
pasteboard: NSPasteboard,

pub fn init() Self {
    return .{ .pasteboard = NSPasteboard.general_pasteboard() };
}

pub fn clear(self: *Self) void {
    self.pasteboard.clear_contents();
}

pub fn write_text(self: *Self, text: []const u8) void {
    // Use autorelease pool. Manually calling release for the string and the
    // array cause a crash, not sure why.
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const str = NSString.new_with_bytes(text, .ascii);
    // defer str.release();

    const arr = NSMutableArray.array();
    // defer arr.release();
    arr.add_object(str.obj);

    self.pasteboard.write_objects(arr.obj);
}

pub fn copy_text(self: *Self) ?NSString {
    const str = self.pasteboard.string_for_type(metal.NSPasteboardTypeString) orelse return null;
    return str;
}

pub fn copy_text_cstr(self: *Self, alloc: Allocator) !?struct { str: [*:0]u8, len: usize } {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const str = self.copy_text() orelse return null;
    const len = str.length();
    const buf = try alloc.alloc(u8, len + 1);
    const cstr = str.to_c_string(buf) orelse {
        alloc.free(buf);
        return null;
    };

    return .{
        .str = cstr,
        .len = len,
    };
}
