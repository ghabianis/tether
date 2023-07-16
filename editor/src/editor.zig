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
        .Paste => try self.paste(false),
        .PasteBefore => try self.paste(true),

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
        .Paste => try self.paste(false),
        .PasteBefore => try self.paste(true),

        .Custom => {},
    }
}

fn handle_cmd_move(self: *Self, comptime cmd_kind: Vim.CmdKindEnum, repeat: u16, the_move: ?Vim.Move) !void {
    // TODO: Handle visual mode
    if (self.vim.mode == .Visual) {
        const sel = self.selection orelse unreachable;
        if (comptime cmd_kind == .Delete) {
            try self.delete_range(sel);
            self.switch_mode(.Normal);
        } else if (comptime cmd_kind == .Change) {
            self.switch_mode(.Insert);
            try self.delete_range(sel);
        } else if (comptime cmd_kind == .Yank) {
            try self.yank(sel);
            self.switch_mode(.Normal);
        }
        return;
    }
    if (comptime cmd_kind == .Change) self.switch_mode(.Insert);

    if (the_move) |mv| {
        var i: usize = 0;
        while (i < repeat) : (i += 1) {
            const prev_cursor = self.cursor;
            self.move(mv.repeat, mv.kind);
            const next_cursor = self.cursor;

            const prev_abs = self.rope.pos_to_idx(prev_cursor) orelse unreachable;
            const next_abs = self.rope.pos_to_idx(next_cursor) orelse unreachable;

            const end_offset: usize = if (mv.kind.is_delete_end_inclusive()) 1 else 0;
            const start = @intCast(u32, @min(prev_abs, next_abs));
            const end = @intCast(u32, @max(prev_abs, next_abs) + end_offset);

            if (comptime cmd_kind == .Change or cmd_kind == .Delete) {
                try self.delete_range(.{ .start = start, .end = end });
            } else {
                try self.yank(.{ .start = start, .end = end });
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
        .Word => |skip_punctuation| {
            self.forward_word(skip_punctuation);
        },
        .BeginningWord => |skip_punctuation| {
            self.backward_word(skip_punctuation);
        },
        .EndWord => |skip_punctuation| {
            print("NICE: \n", .{});
            self.forward_word_end(skip_punctuation);
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

fn paste(self: *Self, before: bool) !void {
    const result = try self.clipboard.copy_text_cstr(std.heap.c_allocator) orelse return;
    defer std.heap.c_allocator.free(result.str[0 .. result.len + 2]);

    const str = result.str[0..result.len];

    var insert_pos = self.cursor;
    if (before) {
        insert_pos.col = insert_pos.col -| 1;
    } else {
        insert_pos.col = @min(self.rope.len, insert_pos.col + 1);
    }
    self.cursor = try self.rope.insert_text(insert_pos, str);
    self.draw_text = true;
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

fn delete_range(self: *Self, range: Selection) !void {
    try self.rope.remove_text(range.start, range.end);
}

pub fn delete_line(self: *Self) !void {
    try self.rope.remove_line(self.cursor.line);
    if (self.cursor.line >= self.rope.nodes.len) {
        self.cursor.line = self.cursor.line -| 1;
    }

    self.cursor.col = if (self.rope.nodes.last) |last| @min(self.cursor_eol_for_mode(last) -| 1, self.cursor.col) else 0;
}

/// Normal mode        -> cursor can only be on the last char
/// Visual/Insert mode -> cursor is allowed to be in front of the last char
///                       (on the '\n' char of the line, if it exists. If not then where it would be)
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

    // Even if there is no \n at end of line, visual and insert mode can be to the right of the last char.
    if (line_node.data.items.len > 0 and !strutil.is_newline(line_node.data.items[line_node.data.items.len - 1])) {
        return @intCast(u32, line_node.data.items.len + 1);
    }

    return @intCast(u32, line_node.data.items.len);
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

/// w -> start of next word
/// W -> same as above but punctuation inclusive
///
/// w/W => always goes to next word, if EOL then go to the last char
fn forward_word(self: *Self, skip_punctuation: bool) void {
    var node = self.rope.node_at_line(self.cursor.line) orelse return;

    // TODO: initialize this properly
    var prev_char: u8 = 0;
    var can_break = !skip_punctuation and self.is_punctuation(prev_char, node.data.items[self.cursor.col]);

    var prev_cursor: TextPos = .{ .line = self.cursor.line, .col = self.cursor.col + 1 };
    var iter = Rope.iter_chars(
        node,
        prev_cursor,
    );
    while (iter.next_update_prev_cursor(&prev_cursor)) |char| {
        if (strutil.is_whitespace(char)) {
            can_break = true;
        } else if (can_break or (!skip_punctuation and self.is_punctuation(prev_char, char))) {
            prev_char = char;
            break;
        }
        prev_char = char;
    }

    self.cursor = prev_cursor;
}

/// e -> end of word (if already at end of cur word go to end of next word)
/// E -> same as above, punctuation inclusive
///
/// e/E => need to check if at the end of the current word, which means
///        char_at(cur_pos + 1) is whitespace or punctuation (if E)
///
fn forward_word_end(self: *Self, skip_punctuation: bool) void {
    self.backward_word_or_forward_word_end(skip_punctuation, .EndWord);
}

/// b -> start of word (if pos == cur word start then go to next word)
/// B -> start of prev word, punctuation inclusive
///
/// b/B => need to check if at start of cur word, meaning char_at(cur_pos - 1) is
///        whitespace or punctuation (if B)
///
fn backward_word(self: *Self, skip_punctuation: bool) void {
    self.backward_word_or_forward_word_end(skip_punctuation, .BeginningWord);
}

/// b/B and e/E are the inverse of each other
fn backward_word_or_forward_word_end(self: *Self, skip_punctuation: bool, comptime dir: Vim.MoveKindEnum) void {
    var node = self.rope.node_at_line(self.cursor.line) orelse return;
    var prev_cursor: TextPos = .{ .line = self.cursor.line, .col = self.cursor.col };

    // TODO: Initialize this properly
    var prev_char: u8 = 0;
    var prev_char_punctual: bool = self.is_punctuation(prev_char, node.data.items[prev_cursor.col]);
    _ = prev_char_punctual;

    var iter = if (comptime dir == .BeginningWord) Rope.iter_chars_rev(
        node,
        prev_cursor,
    ) else if (comptime dir == .EndWord) Rope.iter_chars(node, prev_cursor) else @compileError("BAD dir");

    if (iter.peek()) |initial_peek| {
        // Skip initial whitespace
        if (strutil.is_whitespace(initial_peek)) {
            while (iter.peek()) |peek| {
                if (strutil.is_whitespace(peek)) {
                    _ = iter.next_update_prev_cursor(&prev_cursor);
                } else {
                    break;
                }
            }
        }
        // Otherwise, check if already at end of word
        else if (iter.peek2()) |initial_peek2| {
            if (strutil.is_whitespace(initial_peek2) or (!skip_punctuation and self.is_punctuation(prev_char, initial_peek2))) {
                _ = iter.next_update_prev_cursor(&prev_cursor);
                prev_cursor = iter.cursor;
                // Skip whitespace if needed
                while (iter.peek()) |peek| {
                    if (strutil.is_whitespace(peek)) {
                        _ = iter.next_update_prev_cursor(&prev_cursor);
                    } else {
                        break;
                    }
                }
            }
        }
    } else {
        // Means there's nothing so return
        return;
    }

    while (iter.next_update_prev_cursor(&prev_cursor)) |char| {
        // Check if at end of word
        if (iter.peek()) |c| {
            if (strutil.is_whitespace(c) or (!skip_punctuation and self.is_punctuation(prev_char, c))) {
                break;
            }
        }
        prev_char = char;
    }

    self.cursor = prev_cursor;
}

fn breaks_word(self: *Self, skip_punctuation: bool, prev_char_punctual: bool, prev_char: u8, c: u8) bool {
    if (!skip_punctuation) return strutil.is_whitespace(c);
    if (strutil.is_whitespace(c)) return true;
    if (prev_char_punctual) return !self.is_punctuation(prev_char, c);
    return self.is_punctuation(prev_char, c);
}

fn is_punctuation(self: *Self, prev_char: u8, c: u8) bool {
    _ = self;
    return switch (c) {
        '#', '&', '^', '%', '!', '@', '`', ':', ';', '/', '-', '+', '*', '.', ',', '(', '[', '<' => true,
        '"' => return prev_char != '"',
        '\'' => return prev_char != '\'',
        ')' => return prev_char != '(',
        ']' => return prev_char != '[',
        '>' => return prev_char != '<',
        else => false,
    };
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
