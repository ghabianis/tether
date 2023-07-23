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