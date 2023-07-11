const std = @import("std");
const metal = @import("./metal.zig");
const Allocator = std.mem.Allocator;
const print = std.debug.print;
const strutil = @import("./strutil.zig");

pub const Mode = enum {
    Normal,
    Insert,
    Visual,
};

pub const Key = union(enum) {
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

            print("CHAR: {d} {c}\n", .{ char, char });
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
