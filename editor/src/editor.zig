const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const objc = @import("zig-objc");
const strutil = @import("./strutil.zig");

const rope = @import("./rope.zig");
const TextPos = rope.TextPos;
const Rope = rope.Rope;

const Vim = @import("./vim.zig");
const Clipboard = @import("./clipboard.zig");
const Event = @import("./event.zig");
const Key = Event.Key;

const Self = @This();

rope: Rope = Rope{},
// TODO: also store the node of the current line
cursor: TextPos = .{ .line = 0, .col = 0 },
draw_text: bool = false,
vim: Vim = Vim{},
selection: ?Selection = null,
clipboard: Clipboard = undefined,

pub fn init(self: *Self) !void {
    try self.rope.init();
    try self.vim.init(std.heap.c_allocator, &Vim.DEFAULT_PARSERS);
    self.clipboard = Clipboard.init();
}

pub fn keydown(self: *Self, key: Key) !void {
    if (self.vim.parse(key)) |cmd| {
        switch (self.vim.mode) {
            .Insert => try self.handle_cmd_insert(cmd),
            .Normal => try self.handle_cmd_normal(cmd),
            .Visual => try self.handle_cmd_visual(cmd),
        }
        return;
    }

    if (self.vim.mode == .Insert) {
        try self.handle_key_insert(key);
    }
}

pub fn handle_cmd_insert(self: *Self, cmd: Vim.Cmd) !void {
    switch (cmd.kind) {
        .SwitchMode => |m| {
            self.switch_mode(m);
        },
        else => unreachable,
    }
}

pub fn handle_cmd_normal(self: *Self, cmd: Vim.Cmd) !void {
    switch (cmd.kind) {
        .Delete => |the_mv| try self.handle_cmd_move(.Delete, cmd.repeat, the_mv),
        .Change => |the_mv| try self.handle_cmd_move(.Change, cmd.repeat, the_mv),
        .Yank => |the_mv| try self.handle_cmd_move(.Yank, cmd.repeat, the_mv),

        .Move => |kind| self.move(cmd.repeat, kind),
        .SwitchMove => |swm| {
            self.switch_mode(swm.mode);
            self.move(cmd.repeat, swm.mv);
        },
        .SwitchMode => |m| self.switch_mode(m),
        .NewLine => |nwl| {
            if (nwl.switch_mode) self.switch_mode(.Insert);
            if (!nwl.up) {
                self.end_of_line();
                try self.insert_char('\n');
            } else {
                if (self.cursor.line == 0) {
                    const pos = .{ .line = 0, .col = 0 };
                    try self.insert_char_at(pos, '\n');
                    self.cursor = pos;
                } else {
                    self.up();
                    self.end_of_line();
                    try self.insert_char('\n');
                }
            }
        },
        .Undo => {},
        .Redo => {},

        .Custom => {},
    }
}

pub fn handle_cmd_visual(self: *Self, cmd: Vim.Cmd) !void {
    switch (cmd.kind) {
        .Delete => |the_mv| try self.handle_cmd_move(.Delete, cmd.repeat, the_mv),
        .Change => |the_mv| try self.handle_cmd_move(.Change, cmd.repeat, the_mv),
        .Yank => |the_mv| try self.handle_cmd_move(.Yank, cmd.repeat, the_mv),

        .Move => |kind| {
            self.visual_move(.{ .repeat = cmd.repeat, .kind = kind });
        },
        .SwitchMove => |swm| {
            self.switch_mode(swm.mode);
            self.move(cmd.repeat, swm.mv);
        },
        .SwitchMode => |m| self.switch_mode(m),
        .NewLine => |nwl| {
            if (nwl.switch_mode) self.switch_mode(.Insert);
            if (!nwl.up) {
                self.end_of_line();
                try self.insert_char('\n');
            } else {
                if (self.cursor.line == 0) {
                    const pos = .{ .line = 0, .col = 0 };
                    try self.insert_char_at(pos, '\n');
                    self.cursor = pos;
                } else {
                    self.up();
                    self.end_of_line();
                    try self.insert_char('\n');
                }
            }
        },
        .Undo => {},
        .Redo => {},

        .Custom => {},
    }
}

fn handle_cmd_move(self: *Self, comptime cmd_kind: Vim.CmdKindEnum, repeat: u16, the_move: ?Vim.Move) !void {
    if (comptime cmd_kind == .Change) self.switch_mode(.Insert);
    // TODO: Handle visual mode
    if (self.vim.mode == .Visual) {
        if (comptime cmd_kind == .Yank) {}
        self.switch_mode(.Normal);
        return;
    }

    if (the_move) |mv| {
        var i: usize = 0;
        while (i < repeat) : (i += 1) {
            const prev_cursor = self.cursor;
            self.move(mv.repeat, mv.kind);
            const next_cursor = self.cursor;

            const prev_abs = self.rope.pos_to_idx(prev_cursor) orelse unreachable;
            const next_abs = self.rope.pos_to_idx(next_cursor) orelse unreachable;

            const end_offset: usize = if (mv.kind.is_delete_end_inclusive()) 1 else 0;
            const start = @min(prev_abs, next_abs);
            const end = @max(prev_abs, next_abs) + end_offset;

            if (comptime cmd_kind == .Change or cmd_kind == .Delete) {
                try self.rope.remove_text(start, end);
            } else {
                try self.yank(.{ .start = @intCast(u32, start), .end = @intCast(u32, end) });
            }

            if (next_abs >= prev_abs) {
                self.cursor = prev_cursor;
            } else {
                self.cursor = next_cursor;
            }
        }
        return;
    }

    var i: usize = 0;
    while (i < repeat) : (i += 1) {
        if (comptime cmd_kind == .Change or cmd_kind == .Delete) {
            try self.delete_line();
        } else {
            try self.yank_line(self.cursor.line);
        }
    }
}

fn move(self: *Self, amount: u16, mv: Vim.MoveKind) void {
    if (amount > 1) {
        self.move_repeated(amount, mv);
    } else {
        self.move_impl(mv);
    }
}

fn move_repeated(self: *Self, amount: u16, mv: Vim.MoveKind) void {
    var i: u16 = 0;
    while (i < amount) : (i += 1) {
        i += 1;
        self.move_impl(mv);
    }
}

fn move_impl(self: *Self, mv: Vim.MoveKind) void {
    switch (mv) {
        .Left => self.left(),
        .Right => self.right(),
        .Up => self.up(),
        .Down => self.down(),
        .LineStart => self.start_of_line(),
        .LineEnd => self.end_of_line(),
        // Bool is true if find in reverse
        .Find => |f| {
            _ = f;
        },
        .ParagraphBegin => {},
        .ParagraphEnd => {},
        .Start => {},
        .End => {},
        .Word => |rev| {
            _ = rev;
        },
        .BeginningWord => |rev| {
            _ = rev;
        },
        .EndWord => |rev| {
            _ = rev;
        },
    }
}

fn handle_key_insert(self: *Self, key: Key) !void {
    switch (key) {
        .Char => |c| {
            try self.insert_char(c);
        },
        .Up => self.up(),
        .Down => self.down(),
        .Left => self.left(),
        .Right => self.right(),
        .Esc => unreachable,
        .Shift => {},
        .Newline => try self.insert_char('\n'),
        .Ctrl => {},
        .Alt => {},
        .Backspace => try self.backspace(),
        .Tab => try self.insert("    "),
    }
}

// fn keydown_visual(self: *Self, key: Key) !void {
//     switch (key) {
//         .Char => |c| {
//             switch (c) {
//                 'v' => self.switch_mode(.Normal),

//                 'h' => self.visual_move(Self.left),
//                 'l' => self.visual_move(Self.right),
//                 'k' => self.visual_move(Self.up),
//                 'j' => self.visual_move(Self.down),
//                 'A' => {
//                     // TODO: move cursor to end of selection, wait for input, then replace selection
//                     // self.switch_mode(.Insert);
//                     // self.end_of_line();
//                     self.end_of_selection();
//                     @panic("TODO");
//                 },
//                 '$' => {
//                     self.end_of_line();
//                 },
//                 'I' => {
//                     // TODO: move cursor to start of selection, wait for input, then replace selection
//                     // self.switch_mode(.Insert);
//                     // self.end_of_line();
//                     self.start_of_selection();
//                     @panic("TODO");
//                 },
//                 '0' => {
//                     self.visual_move(Self.start_of_line);
//                 },
//                 'y' => {
//                     const sel = try self.get_selection(std.heap.c_allocator) orelse return;
//                     // defer std.heap.c_allocator.free(sel);
//                     print("COPYING TEXT!! {s}\n", .{sel});
//                     // defer std.heap.c_allocator.destroy(sel);
//                     self.clipboard.clear();
//                     self.clipboard.write_text(sel);
//                 },
//                 else => {},
//             }
//         },
//         .Up => self.visual_move(Self.up),
//         .Down => self.visual_move(Self.down),
//         .Left => self.visual_move(Self.left),
//         .Right => self.visual_move(Self.right),
//         .Esc => {
//             self.switch_mode(.Normal);
//         },
//         .Shift => {},
//         .Newline => {},
//         .Ctrl => {},
//         .Alt => {},
//         .Backspace => self.visual_move(Self.left),
//         .Tab => {},
//     }
// }

fn visual_move(self: *Self, mv: Vim.Move) void {
    print("PREV SEL: {any}\n", .{self.selection});
    const prev_cursor = self.cursor;

    var i: usize = 0;
    while (i < mv.repeat) : (i += 1) {
        self.move_impl(mv.kind);
    }

    const sel = self.selection orelse return;

    const next_cursor = self.cursor;
    const prev_abs = @intCast(u32, self.rope.pos_to_idx(prev_cursor) orelse @panic("ohno"));
    const next_abs = @intCast(u32, self.rope.pos_to_idx(next_cursor) orelse @panic("ohno"));

    if (prev_abs == sel.start and sel.end == sel.start + 1) {
        if (next_abs > sel.start) {
            self.selection = .{
                .start = sel.start,
                .end = next_abs,
            };
        } else {
            self.selection = .{
                .start = next_abs,
                .end = sel.start + 1,
            };
        }
    } else if (next_abs >= sel.start and next_abs < sel.end) {
        const swap = prev_abs != sel.end -| 1;
        self.selection = if (swap) .{
            .start = next_abs,
            .end = sel.end,
        } else .{ .start = sel.start, .end = next_abs + 1 };
    } else if (next_abs >= sel.end) {
        const swap = prev_abs == sel.start;
        self.selection = if (swap) .{
            .start = sel.end -| 1,
            .end = next_abs + 1,
        } else .{
            .start = sel.start,
            .end = next_abs + 1,
        };
    } else if (next_abs < sel.start) {
        self.selection = .{ .start = next_abs, .end = sel.end };
    }

    self.draw_text = true;

    print("NEXT SEL: {any}\n", .{self.selection});
}

pub fn switch_mode(self: *Self, mode: Vim.Mode) void {
    if (self.vim.mode == .Visual) {
        self.selection = null;
    }
    if (mode == .Visual) {
        const cursor_absolute_pos = @intCast(u32, self.rope.pos_to_idx(self.cursor) orelse @panic("SHIT!"));
        self.selection = .{ .start = cursor_absolute_pos, .end = cursor_absolute_pos + 1 };
    } else if (self.vim.mode == .Insert and mode == .Normal) {
        self.left();
    }
    self.vim.mode = mode;
}

pub fn yank(self: *Self, range: Selection) !void {
    const sel = try self.get_selection_impl(std.heap.c_allocator, range) orelse return;
    defer std.heap.c_allocator.free(sel);
    self.yank_text(sel);
}

fn yank_text(self: *Self, txt: []const u8) void {
    print("COPYING TEXT!! {s}\n", .{txt});
    self.clipboard.clear();
    self.clipboard.write_text(txt);
}

fn yank_line(self: *Self, line: u32) !void {
    const the_line = self.rope.node_at_line(line) orelse return;
    self.yank_text(the_line.data.items);
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

pub fn delete_line(self: *Self) !void {
    try self.rope.remove_line(self.cursor.line);
    if (self.cursor.line >= self.rope.nodes.len) {
        self.cursor.line = self.cursor.line -| 1;
    }

    self.cursor.col = if (self.rope.nodes.last) |last| @min(self.cursor_eol_for_mode(last) -| 1, self.cursor.col) else 0;
}

/// Normal mode -> cursor can only be on the last char
/// Visual/Insert mode -> cursor is allowed to be in front of the last char
fn cursor_eol_for_mode(self: *Self, line_node: *const Rope.Node) u32 {
    if (self.vim.mode == .Normal) {
        if (line_node.data.items.len > 0) {
            const has_newline = strutil.is_newline(line_node.data.items[line_node.data.items.len - 1]);
            if (line_node == self.rope.nodes.last or has_newline) {
                if (has_newline) return @intCast(u32, line_node.data.items.len -| 1);
                return @intCast(u32, line_node.data.items.len);
            }
        } else {
            return 0;
        }
    }
    return if (line_node.data.items.len > 0 and !strutil.is_newline(line_node.data.items[line_node.data.items.len - 1])) @intCast(u32, line_node.data.items.len + 1) else @intCast(u32, line_node.data.items.len);
}

pub fn start_of_line(self: *Self) void {
    self.cursor.col = 0;
    self.draw_text = true;
}

pub fn end_of_line(self: *Self) void {
    var cur_node = self.rope.node_at_line(self.cursor.line) orelse @panic("No node");
    self.cursor.col = self.cursor_eol_for_mode(cur_node) -| 1;
    self.draw_text = true;
}

pub fn start_of_selection(self: *Self) void {
    _ = self;
    @panic("TODO!");
}

pub fn end_of_selection(self: *Self) void {
    _ = self;
    @panic("TODO!");
}

pub fn get_selection(self: *Self, alloc: Allocator) !?[]const u8 {
    const sel = self.selection orelse return null;
    return self.get_selection_impl(alloc, sel);
}

fn get_selection_impl(self: *Self, alloc: Allocator, sel: Selection) !?[]const u8 {
    // TODO: this is inefficient for large text
    const ret = try alloc.alloc(u8, sel.len());
    const str = try self.rope.as_str(alloc);
    defer std.heap.c_allocator.destroy(str);
    @memcpy(ret, str[sel.start..sel.end]);
    return ret;
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

pub const Selection = struct {
    start: u32,
    end: u32,

    pub fn len(self: Selection) u32 {
        return self.end - self.start;
    }
};

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

// 012345
