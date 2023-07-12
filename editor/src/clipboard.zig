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
