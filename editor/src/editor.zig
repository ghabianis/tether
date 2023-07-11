const std = @import("std");
const Allocator = std.mem.Allocator;

const objc = @import("zig-objc");
const strutil = @import("./strutil.zig");

const rope = @import("./rope.zig");
const TextPos = rope.TextPos;
const Rope = rope.Rope;

const Vim = @import("./vim.zig");

const print = std.debug.print;

const Self = @This();

rope: Rope = Rope{},
// TODO: also store the node of the current line
cursor: TextPos = .{ .line = 0, .col = 0 },
draw_text: bool = false,
mode: Vim.Mode = Vim.Mode.Normal,

pub fn init(self: *Self) !void {
    try self.rope.init();
}

pub fn keydown(self: *Self, key: Vim.Key) !void {
    switch (self.mode) {
        .Insert => try self.keydown_insert(key),
        .Normal => try self.keydown_normal(key),
        .Visual => try self.keydown_normal(key),
    }
}

fn keydown_insert(self: *Self, key: Vim.Key) !void {
    switch (key) {
        .Char => |c| {
            try self.insert_char(c);
        },
        .Up => {},
        .Down => {},
        .Left => self.left(),
        .Right => self.right(),
        .Esc => {
            self.left();
            self.mode = Vim.Mode.Normal;
        },
        .Shift => {},
        .Newline => try self.insert_char('\n'),
        .Ctrl => {},
        .Alt => {},
        .Backspace => try self.backspace(),
        .Tab => try self.insert("    "),
    }
}

fn keydown_normal(self: *Self, key: Vim.Key) !void {
    switch (key) {
        .Char => |c| {
            switch (c) {
                'h' => self.left(),
                'l' => self.right(),
                'k' => self.up(),
                'j' => self.down(),
                'i' => {
                    self.mode = Vim.Mode.Insert;
                },
                'a' => {
                    self.mode = Vim.Mode.Insert;
                    self.right();
                },
                'A' => {
                    self.mode = Vim.Mode.Insert;
                    self.end_of_line();
                },
                '$' => {
                    self.end_of_line();
                },
                'I' => {
                    self.mode = Vim.Mode.Insert;
                    self.start_of_line();
                },
                '0' => {
                    self.start_of_line();
                },
                'o' => {
                    self.mode = Vim.Mode.Insert;
                    self.end_of_line();
                    try self.insert_char('\n');
                },
                'O' => {
                    self.mode = Vim.Mode.Insert;
                    if (self.cursor.line == 0) {
                        const pos = .{ .line = 0, .col = 0 };
                        try self.insert_char_at(pos, '\n');
                        self.cursor = pos;
                    } else {
                        self.up();
                        self.end_of_line();
                        try self.insert_char('\n');
                    }
                },
                else => {},
            }
        },
        .Up => {},
        .Down => {},
        .Left => self.left(),
        .Right => self.right(),
        .Esc => {},
        .Shift => {},
        .Newline => {},
        .Ctrl => {},
        .Alt => {},
        .Backspace => self.left(),
        .Tab => {},
    }
}

pub fn insert_char(self: *Self, c: u8) !void {
    try self.insert_at(self.cursor, &[_]u8{c});
}

pub fn insert_char_at(self: *Self, cursor: TextPos, c: u8) !void {
    try self.insert_at(cursor, &[_]u8{c});
}

pub fn insert(self: *Self, chars: []const u8) !void {
    try self.insert_at(self.cursor, chars);
}

pub fn insert_at(self: *Self, cursor: TextPos, chars: []const u8) !void {
    const new_cursor = try self.rope.insert_text(cursor, chars);
    self.cursor = new_cursor;
    self.draw_text = true;
}

pub fn backspace(self: *Self) !void {
    const pos = self.cursor;
    const idx_pos = self.rope.pos_to_idx(pos) orelse @panic("OOPS!");

    self.cursor = cursor: {
        if (pos.col == 0) {
            const new_line = pos.line -| 1;
            const line_node = self.rope.node_at_line(new_line) orelse @panic("No node");
            break :cursor .{
                .line = new_line,
                .col = @intCast(u32, line_node.data.items.len) -| 1,
            };
        } else {
            break :cursor .{
                .line = pos.line,
                .col = pos.col - 1,
            };
        }
    };

    try self.rope.remove_text(idx_pos - 1, idx_pos);

    self.draw_text = true;
}

/// Normal mode -> cursor can only be on the last char
/// Visual/Insert mode -> cursor is allowed to be in front of the last char
fn cursor_eol_for_mode(self: *Self, line_node: *const Rope.Node) u32 {
    if (self.mode == .Normal) {
        if (line_node.data.items.len > 0) {
            if (strutil.is_newline(line_node.data.items[line_node.data.items.len - 1])) {
                return @intCast(u32, line_node.data.items.len -| 1);
            }
        } else {
            return 0;
        }
    }
    return if (line_node.data.items.len > 0 and !strutil.is_newline(line_node.data.items[line_node.data.items.len - 1])) @intCast(u32, line_node.data.items.len + 1) else @intCast(u32, line_node.data.items.len);
}

pub fn end_of_line(self: *Self) void {
    var cur_node = self.rope.node_at_line(self.cursor.line) orelse @panic("No node");
    self.cursor.col = self.cursor_eol_for_mode(cur_node) -| 1;
    self.draw_text = true;
}

pub fn start_of_line(self: *Self) void {
    self.cursor.col = 0;
    self.draw_text = true;
}

pub fn left(self: *Self) void {
    self.move_char(-1, true);
}

pub fn right(self: *Self) void {
    self.move_char(1, true);
}

pub fn up(self: *Self) void {
    self.move_line(-1);
}

pub fn down(self: *Self) void {
    self.move_line(1);
}

pub fn move_line(self: *Self, delta: i64) void {
    const d = @intCast(u32, if (delta < 0) -delta else delta);
    const line = if (delta < 0) self.cursor.line -| d else @min(self.rope.nodes.len -| 1, self.cursor.line + d);
    const col = @min(self.cursor_eol_for_mode(self.rope.node_at_line(line).?) -| 1, self.cursor.col);
    self.cursor.line = line;
    self.cursor.col = col;
    self.draw_text = true;
}

pub fn move_char(self: *Self, delta_: i64, limited_to_line: bool) void {
    const Dir = enum { Left, Right };
    var dir = if (delta_ > 0) Dir.Right else Dir.Left;

    var cur_node = self.rope.node_at_line(self.cursor.line) orelse @panic("No node");
    var line: u32 = self.cursor.line;
    var col: i64 = self.cursor.col;
    var delta: i64 = if (delta_ < 0) -delta_ else delta_;
    while (delta > 0) {
        // go next line:
        if (dir == .Right and delta + col >= @intCast(i64, self.cursor_eol_for_mode(cur_node))) {
            // I :: len = 3
            // N :: len = 2
            // hi\
            // 012
            if (!limited_to_line and cur_node.next != null) {
                delta -= @intCast(i64, cur_node.data.items.len) - col;
                col = 0;
                cur_node = cur_node.next.?;
            } else {
                col = self.cursor_eol_for_mode(cur_node) -| 1;
                break;
            }
            line += 1;
        }

        if (dir == .Left and col - delta < 0) {
            if (!limited_to_line and cur_node.prev != null) {
                delta -= col + 1;
                col = @intCast(i64, cur_node.data.items.len) -| 1;
                cur_node = cur_node.prev.?;
            } else {
                col = 0;
                break;
            }
            line -= 1;
        }

        col += if (dir == .Right) delta else -delta;
        delta = 0;
    }

    self.cursor.line = line;
    self.cursor.col = @intCast(u32, col);
    // TODO: Probably very bad to redraw entire text after just moving cursor
    self.draw_text = true;
}

pub fn text(self: *Self, alloc: Allocator) ![]const u8 {
    return try self.rope.as_str(alloc);
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

test "backspace simple" {
    var editor = Self{};
    try editor.init();

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
    try std.testing.expectEqualStrings("HEY MAN!", str);
    str = try editor.text(std.heap.c_allocator);
}
