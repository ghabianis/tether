const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const metal = @import("./metal.zig");
const strutil = @import("./strutil.zig");

pub const KeyEnum = enum {
    Char,
    Up,
    Down,
    Left,
    Right,
    Esc,
    Shift,
    Newline,
    Ctrl,
    Alt,
    Backspace,
    Tab,
};

pub const Key = union(KeyEnum) {
    Char: u8,
    Up,
    Down,
    Left,
    Right,
    Esc,
    Shift,
    Newline,
    Ctrl,
    Alt,
    Backspace,
    Tab,

    pub fn as_char(self: Key) ?u8 {
        switch (self) {
            .Char => |c| return c,
            else => return null,
        }
    }

    pub fn eq(a: Key, b: Key) bool {
        if (@as(KeyEnum, a) != @as(KeyEnum, b)) return false;
        if (@as(KeyEnum, a) == KeyEnum.Char) {
            return a.Char == b.Char;
        }
        return false;
    }

    pub fn from_nsevent(event: metal.NSEvent) ?Key {
        var in_char_buf = [_]u8{0} ** 128;
        const nschars = event.characters() orelse return null;
        if (nschars.to_c_string(&in_char_buf)) |chars| {
            const len = strutil.cstring_len(chars);
            if (len > 1) @panic("TODO: handle multi-char input");
            // var out_char_buf = [_]u8{0} ** 128;
            // const filtered_chars = Editor.filter_chars(chars[0..len], out_char_buf[0..128]);
            // try self.editor.insert(self.editor.cursor, filtered_chars);

            const char = chars[0];

            switch (char) {
                27 => return Key.Esc,
                127 => return Key.Backspace,
                else => return Key{ .Char = char },
            }
        }

        const keycode = event.keycode();
        switch (keycode) {
            123 => return Key.Left,
            124 => return Key.Right,
            125 => return Key.Down,
            126 => return Key.Up,
            else => print("Unknown keycode: {d}\n", .{keycode}),
        }

        return null;
    }
};
