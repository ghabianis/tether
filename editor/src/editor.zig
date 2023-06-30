const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("zig-objc");

const rope = @import("./rope.zig");
const TextPos = rope.TextPos;
const Rope = rope.Rope;
const print = std.debug.print;

const Self = @This();

rope: Rope = Rope{},
cursor: TextPos = .{ .line = 0, .col = 0 },
draw_text: bool = false,

pub fn init(self: *Self) !void {
    try self.rope.init();
    // self.cursor = try self.rope.insert_text(self.cursor, "HEY\n");
}

pub fn filter_chars(in: []const u8, out: []u8) []u8 {
    var i: usize = 0;
    var len: usize = 0;
    for (in) |c| {
        if (c == 0) {
            break;
        }
        if (c < 127) {
            out[len] = c;
            len += 1;
        }
        i += 1;
    }
    return out[0..len];
}

pub fn insert(self: *Self, chars: []const u8) !void {
    try self.insert_at(self.cursor, chars);
}

pub fn insert_at(self: *Self, cursor: TextPos, chars: []const u8) !void {
    self.cursor = try self.rope.insert_text(cursor, chars);
    self.draw_text = true;
}

pub fn backspace(self: *Self) !void {
    const pos = self.cursor;
    const idx_pos = self.rope.pos_to_idx(pos) orelse @panic("OOPS!");
    try self.rope.remove_text(idx_pos - 1, idx_pos);
    self.cursor = if (pos.col == 0) .{
        .line = pos.line -| 1,
        .col = 0,
    } else .{
        .line = pos.line,
        .col = pos.col - 1,
    };
}

pub fn text(self: *Self, alloc: Allocator) ![]const u8 {
    return try self.rope.as_str(alloc);
}

test "backspace simple" {
    var editor = Self{};
    try editor.init();

    // editor.insert(.{}, chars: []const u8)
    var pos = try editor.insert("HEY MAN!");
    _ = pos;
    try editor.backspace();
    var str = try editor.text(std.heap.c_allocator);
    try std.testing.expectEqualStrings("HEY MAN", str);
}

test "backspace line" {
    var editor = Self{};
    try editor.init();

    try editor.insert("HEY MAN!\nA");
    try editor.backspace();
    var str = try editor.text(std.heap.c_allocator);
    try std.testing.expectEqualStrings("HEY MAN!\n", str);
    try editor.backspace();
    str = try editor.text(std.heap.c_allocator);
    // print("LAST NODE {s}\n", .{editor.rope.nodes.last.?.data.items});
    try std.testing.expectEqualStrings("HEY MAN!", str);
    str = try editor.text(std.heap.c_allocator);
}
