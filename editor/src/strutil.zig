pub fn cstring_len(cstr: [*:0]u8) usize {
    var i: usize = 0;
    while (cstr[i] != 0) : (i += 1) {}
    return i;
}

pub fn is_newline(c: u8) bool {
    return c == '\n' or c == '\r';
}
