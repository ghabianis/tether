const std = @import("std");
const print = std.debug.print;

pub fn cstring_len(cstr: [*:0]u8) usize {
    var i: usize = 0;
    while (cstr[i] != 0) : (i += 1) {}
    return i;
}

pub fn is_newline(c: u8) bool {
    return c == '\n' or c == '\r';
}

pub fn is_whitespace(c: u8) bool {
    return c == ' ' or c == '\t' or is_newline(c);
}

pub fn is_uppercase_char(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

pub fn lowercase_char(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') {
        return c + ('a' - 'A');
    }
    return c;
}

pub fn digit_to_char(val: u8) u8 {
    return switch (val) {
        0 => '0',
        1 => '1',
        2 => '2',
        3 => '3',
        4 => '4',
        5 => '5',
        6 => '6',
        7 => '7',
        8 => '8',
        9 => '9',
        else => @panic("BAD VAL"),
    };
}

pub fn number_to_str(num: u32, digit_count: u32, buf: *[16]u8) []u8 {
    var len: u32 = 0;
    var temp: u32 = num;

    var i: i64 = @intCast(i64, digit_count);
    while (i > 0) : (i -= 1) {
        const pow10 = std.math.pow(u32, 10, @intCast(u32, @max(i - 1, 0)));
        const val = temp / pow10;
        buf[len] = digit_to_char(@intCast(u8, val));
        temp -= pow10 * val;
        len += 1;
    }

    return buf[0..len];
}

test "number_to_str" {
    const Input = struct {
        val: u32,
        expected: []const u8,
    };

    const inputs = [_]Input{
        .{ 
            .val = 0, 
            .expected = "0"
        },
        .{ 
            .val = 1, 
            .expected = "1"
        },
        .{ 
            .val = 12, 
            .expected = "12"
        },
        .{ 
            .val = 300, 
            .expected = "300"
        },
    };

    var buf = [_]u8{0} ** 16;
    for (inputs) |input| {
        const digits = if (input.val == 0) 1 else @floatToInt(u32, @floor(@log10(@intToFloat(f32, input.val)))) + 1;
        const result = number_to_str(input.val, digits, &buf);
        try std.testing.expectEqualStrings(input.expected, result);
    }
}