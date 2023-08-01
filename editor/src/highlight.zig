const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const ts = @import("./treesitter.zig");
const c = ts.c;
const Rope = @import("./rope.zig").Rope;
const math = @import("./math.zig");
const r = @import("./regex.zig");
const strutil = @import("./strutil.zig");

const CommonCaptureNames = enum {
    Attribute,
    Comment,
    Constant,
    Constructor,
    FunctionBuiltin,
    Function,
    Keyword,
    Label,
    Operator,
    Param,
    Property,
    Punctuation,
    PunctuationBracket,
    PunctuationDelimiter,
    PunctuationSpecial,
    String,
    StringSpecial,
    Tag,
    Type,
    TypeBuiltin,
    Variable,
    VariableBuiltin,
    VariableParameter,

    fn upper_camel_case_to_dot_notation(comptime N: usize, comptime str: *const [N]u8) []const u8 {
        const upper_case_count: usize = comptime upper_case_count: {
            var count: usize = 1;
            for (str[1..]) |char| {
                if (char >= 'A' and char <= 'Z') {
                    count += 1;
                }
            }
            break :upper_case_count count;
        };

        if (upper_case_count == 1) {
            return .{strutil.lowercase_char(str[0])} ++ str[1..];
        }

        const new_len = N + (upper_case_count - 1);
        const ret: [new_len]u8 = comptime ret: {
            var return_string: [new_len]u8 = [_]u8{0} ** new_len;
            var i: usize = 0;
            var j: usize = 0;
            while (j < N) : (j += 1) {
                if (j == 0) {
                    return_string[i] = strutil.lowercase_char(str[j]);
                    i += 1;
                } else if (j != 0 and strutil.is_uppercase_char(str[j])) {
                    return_string[i] = '.';
                    i += 1;
                    return_string[i] = strutil.lowercase_char(str[j]);
                    i += 1;
                } else {
                    return_string[i] = str[j];
                    i += 1;
                }
            }
            break :ret return_string;
        };
        return &ret;
    }

    pub fn as_str(self: CommonCaptureNames) []const u8 {
        inline for (@typeInfo(CommonCaptureNames).Enum.fields) |field| {
            if (field.value == @intFromEnum(self)) {
                const N = field.name.len;
                return comptime CommonCaptureNames.upper_camel_case_to_dot_notation(N, @as(*const [N]u8, @ptrCast(field.name.ptr)));
            }
        }
    }
    pub fn as_str_comptime(comptime self: CommonCaptureNames) []const u8 {
        return comptime self.as_str();
    }
};

const CaptureConfig = struct {
    name: []const u8,
    color: math.Float4,
};

const Highlight = @This();
const HashMap = std.AutoHashMap;

parser: *c.TSParser,
lang: *const ts.Language,
query: *c.TSQuery,
theme: []const ?math.Float4,
/// tree-sitter value id -> regex
regexes: HashMap(u32, r.regex_t),

/// Adapted with minor changes from:
/// https://github.com/tree-sitter/tree-sitter/blob/1c65ca24bc9a734ab70115188f465e12eecf224e/highlight/src/lib.rs#L366
///
/// Basically handles finding the best match for capture names with multiple
/// levels. For example, if the capture names of the query are @keyword.function
/// and @keyword.operator, and the theme defines colors for only @keyword, then
/// it makes sure @keyword.function and @keyword.operator get the color for
/// @keyword.
fn configure_higlights(alloc: Allocator, q: *c.TSQuery, recognized_names: []const CaptureConfig) ![]?math.Float4 {
    const count: u32 = c.ts_query_capture_count(q);
    var theme = try alloc.alloc(?math.Float4, @as(usize, @intCast(count)));
    @memset(theme, null);

    var capture_parts = std.ArrayList([]const u8).init(alloc);
    defer capture_parts.deinit();

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var length: u32 = 0;
        const capture_name_ptr = c.ts_query_capture_name_for_id(q, i, &length);
        const capture_name = capture_name_ptr[0..length];
        var temp_part_iter = std.mem.split(u8, capture_name, ".");
        var part_iter = temp_part_iter;
        while (part_iter.next()) |part| {
            try capture_parts.append(part);
        }
        defer {
            capture_parts.items.len = 0;
        }

        var best_index: ?u32 = null;
        var best_match_len: u32 = 0;

        var j: u32 = 0;
        while (j < recognized_names.len) : (j += 1) {
            const recognized_name = recognized_names[j];
            var len: u32 = 0;
            var matches: bool = true;
            var recognized_name_part_iter = std.mem.split(u8, recognized_name.name, ".");
            while (recognized_name_part_iter.next()) |recognized_name_part| {
                const has = has: {
                    if (len >= capture_parts.items.len) break :has false;
                    const capture_part = capture_parts.items[len];
                    break :has std.mem.eql(u8, capture_part, recognized_name_part);
                };
                len += 1;
                if (!has) {
                    matches = false;
                    break;
                }
            }

            if (matches and len > best_match_len) {
                best_index = j;
                best_match_len = len;
            }
        }

        if (best_index) |index| {
            theme[i] = recognized_names[index].color;
        }
    }

    return theme;
}

pub fn init(alloc: Allocator, language: *const ts.Language, colors: []const CaptureConfig) !Highlight {
    var error_offset: u32 = undefined;
    var error_type: c.TSQueryError = undefined;

    const query = c.ts_query_new(language.lang_fn(), language.highlights.ptr, @as(u32, @intCast(language.highlights.len)), &error_offset, &error_type);

    if (query) |q| {
        var parser = c.ts_parser_new();
        if (!c.ts_parser_set_language(parser, language.lang_fn())) {
            @panic("Failed to set parser!");
        }

        var regexes = HashMap(u32, r.regex_t).init(alloc);

        const count = c.ts_query_pattern_count(query);
        for (0..count) |i| {
            var length: u32 = 0;
            var predicates_ptr = c.ts_query_predicates_for_pattern(query, @intCast(i), &length);
            if (length < 1) continue;
            const predicates: []const c.TSQueryPredicateStep = predicates_ptr[0..length];
            var j: u32 = 0;
            while (j < length) {
                const pred = predicates[j];
                var value_len: u32 = undefined;
                const value = c.ts_query_string_value_for_id(query, pred.value_id, &value_len);

                if (pred.type == c.TSQueryPredicateStepTypeString) {
                    // Example:
                    // TSQueryPredicateStepTypeString: match?
                    // TSQueryPredicateStepTypeCapture: function
                    // TSQueryPredicateStepTypeString: ^[a-z]+([A-Z][a-z0-9]*)+$
                    // TSQueryPredicateStepTypeDone
                    //
                    // Has 4 steps
                    if (std.mem.eql(u8, "match?", value[0..value_len])) {
                        const regex_step = predicates[j + 2];
                        var regex_len: u32 = undefined;
                        const regex_str_ptr = c.ts_query_string_value_for_id(query, regex_step.value_id, &regex_len);
                        const regex_str = regex_str_ptr[0..regex_len];
                        var regex: r.regex_t = undefined;

                        if (r.regncomp(&regex, regex_str.ptr, regex_str.len, 0) != 0) {
                            @panic("Failed to compile regular expression");
                        }

                        try regexes.put(regex_step.value_id, regex);

                        j += 4;
                        continue;
                    }
                }

                j += 1;
            }
        }

        const theme = try Highlight.configure_higlights(alloc, q, colors);

        return .{ .parser = parser.?, .query = q, .lang = language, .theme = theme, .regexes = regexes };
    }

    @panic("Query error!");
}

pub fn highlight(self: *Highlight, str: []const u8, charIdxToVertexIdx: []const u32, vertices: []math.Vertex) !void {
    if (!c.ts_parser_set_language(self.parser, self.lang.lang_fn())) {
        @panic("Failed to set parser!");
    }
    var tree = c.ts_parser_parse_string(self.parser, null, str.ptr, @as(u32, @intCast(str.len)));
    var root_node = c.ts_tree_root_node(tree);
    var query_cursor = c.ts_query_cursor_new();
    var match: c.TSQueryMatch = undefined;

    c.ts_query_cursor_exec(query_cursor, self.query, root_node);

    while (c.ts_query_cursor_next_match(query_cursor, &match)) {
        var last_match: ?u32 = null;

        var i: u32 = 0;
        while (i < match.capture_count) : (i += 1) {
            const capture_maybe: ?*const c.TSQueryCapture = &match.captures[i];
            const capture = capture_maybe.?;

            if (self.satisfies_text_predicates(capture, str, &match)) {
                last_match = i;
                break;
            }
        }

        if (last_match) |index| {
            const capture_maybe: ?*const c.TSQueryCapture = &match.captures[index];
            const capture = capture_maybe.?;

            const start = c.ts_node_start_byte(capture.node);
            const end = c.ts_node_end_byte(capture.node);

            var j: u32 = start;
            while (j < end) : (j += 1) {
                const vertIndex = charIdxToVertexIdx[j];
                if (self.theme[capture.index]) |color| {
                    vertices[vertIndex].color = color;
                    vertices[vertIndex + 1].color = color;
                    vertices[vertIndex + 2].color = color;
                    vertices[vertIndex + 3].color = color;
                    vertices[vertIndex + 4].color = color;
                    vertices[vertIndex + 5].color = color;
                }
            }
        }
    }

    c.ts_parser_reset(self.parser);
}

fn satisfies_text_predicates(self: *Highlight, capture: *const c.TSQueryCapture, src: []const u8, match: *c.TSQueryMatch) bool {
    var length: u32 = undefined;

    var predicates_ptr = c.ts_query_predicates_for_pattern(self.query, match.pattern_index, &length);
    if (length < 1) return true;

    const predicates: []const c.TSQueryPredicateStep = predicates_ptr[0..length];

    var i: u32 = 0;
    while (i < length) {
        const predicate = predicates[i];
        switch (predicate.type) {
            c.TSQueryPredicateStepTypeString => {
                var value_len: u32 = undefined;
                const value = c.ts_query_string_value_for_id(self.query, predicate.value_id, &value_len);

                if (std.mem.eql(u8, "match?", value[0..value_len])) {
                    const regex_step = predicates[i + 2];
                    const start = c.ts_node_start_byte(capture.node);
                    const end = c.ts_node_end_byte(capture.node);
                    if (self.satisfies_match(src[start..end], regex_step.value_id)) {
                        return true;
                    }
                    i += 4;
                    continue;
                }

                return false;
            },
            else => {
                @panic("Unreachable");
            },
        }
    }

    return false;
}
fn satisfies_match(self: *Highlight, src: []const u8, regex_step_value_id: u32) bool {
    var regex = self.regexes.get(regex_step_value_id) orelse @panic("REGEX NOT FOUND!");

    const ret = r.regnexec(&regex, src.ptr, src.len, 0, null, 0);

    if (ret == 0) return true;
    if (ret == r.REG_NOMATCH) {
        return false;
    }

    // otherwise failed
    // @panic("Regex exec failed!");
    return false;
}

fn find_name(names: [][]const u8, name: []const u8) ?usize {
    var i: usize = 0;
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) {
            return i;
        }
        i += 1;
    }
    return null;
}

pub const TokyoNightStorm = struct {
    const Self = @This();
    const FG = math.hex4("#c0caf5");
    const FG_DARK = math.hex4("#a9b1d6");
    const BG = math.hex4("#24283b");
    const CYAN = math.hex4("#7dcfff");
    const GREEN = math.hex4("#9ece6a");
    const TURQUOISE = math.hex4("#0BB9D7");
    const BLUE = math.hex4("#7aa2f7");
    const BLUE5 = math.hex4("#89ddff");
    const blue1 = math.hex4("#2ac3de");
    const ORANGE = math.hex4("#ff9e64");
    const RED = math.hex4("#f7768e");
    const GREEN1 = math.hex4("#73daca");
    const COMMENT = math.hex4("#565f89");
    const MAGENTA = math.hex4("#bb9af7");
    const YELLOW = math.hex4("#e0af68");
    const GREY = math.hex4("#444B6A");

    const conf = [_]CaptureConfig{
        .{
            .name = CommonCaptureNames.Function.as_str_comptime(),
            .color = Self.BLUE,
        },
        .{
            .name = CommonCaptureNames.FunctionBuiltin.as_str_comptime(),
            .color = Self.TURQUOISE,
        },
        .{
            .name = CommonCaptureNames.Keyword.as_str_comptime(),
            .color = Self.MAGENTA,
        },
        .{
            .name = "conditional",
            .color = Self.MAGENTA,
        },
        .{
            .name = "type.qualifier",
            .color = Self.MAGENTA,
        },
        .{
            .name = CommonCaptureNames.Comment.as_str_comptime(),
            .color = Self.GREY,
        },
        .{
            .name = "spell",
            .color = Self.GREY,
        },
        .{
            .name = CommonCaptureNames.String.as_str_comptime(),
            .color = Self.GREEN,
        },
        .{
            .name = CommonCaptureNames.Operator.as_str_comptime(),
            .color = Self.CYAN,
        },
        .{
            .name = "boolean",
            .color = ORANGE,
        },
        .{
            .name = "constant",
            .color = YELLOW,
        },
        // .{
        //     .name = CommonCaptureNames.Punctuation.as_str_comptime(),
        //     .color = Self.CYAN,
        // },
        // .{
        //     .name = CommonCaptureNames.Label.as_str_comptime(),
        //     .color = Self.YELLOW,
        // },
    };

    pub fn to_indices() []const CaptureConfig {
        return &Self.conf;
    }
};

test "dot notation" {
    const str1 = "Keyword";
    const str2 = "KeywordFunction";
    const expected1 = "keyword";
    const expected2 = "keyword.function";

    const result1 = CommonCaptureNames.upper_camel_case_to_dot_notation(str1.len, str1);
    try std.testing.expectEqualStrings(expected1, result1);

    const result2 = CommonCaptureNames.upper_camel_case_to_dot_notation(str2.len, str2);
    try std.testing.expectEqualStrings(expected2, result2);
}

test "configure higlights levels" {
    const alloc = std.heap.c_allocator;
    const language = ts.ZIG;

    var error_offset: u32 = undefined;
    var error_type: c.TSQueryError = undefined;

    const query = c.ts_query_new(ts.tree_sitter_zig(), language.highlights.ptr, @as(u32, @intCast(language.highlights.len)), &error_offset, &error_type) orelse @panic("Failed to set up query");

    var parser = c.ts_parser_new();
    if (!c.ts_parser_set_language(parser, ts.tree_sitter_zig())) {
        @panic("Failed to set parser!");
    }

    const count = c.ts_query_capture_count(query);
    const names = try alloc.alloc([]const u8, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var length: u32 = 0;
        const capture_name_ptr = c.ts_query_capture_name_for_id(query, i, &length);
        const capture_name = capture_name_ptr[0..length];
        names[i] = capture_name;
    }

    const color_keyword = math.Float4.new(69.0, 420.0, 69420.0, 1.0);
    const color_keyword_function = math.Float4.new(32.0, 32.0, 32.0, 1.0);
    const color_punctuation = math.Float4.new(1.0, 1.0, 0.0, 1.0);
    const color_function = math.Float4.new(0.0, 1.0, 0.0, 0.0);
    const theme = try Highlight.configure_higlights(alloc, query, &.{
        .{ .name = "keyword", .color = color_keyword },
        .{ .name = "keyword.function", .color = color_keyword_function },
        .{ .name = "function", .color = color_function },
        .{ .name = "punctuation", .color = color_punctuation },
    });

    const keyword_coroutine_idx = find_name(names, "keyword.coroutine") orelse @panic("oops!");
    const keyword_idx = find_name(names, "keyword") orelse @panic("oops!");
    const keyword_function_idx = find_name(names, "keyword.function") orelse @panic("oops!");
    const punctuation_idx = find_name(names, "punctuation.bracket") orelse @panic("oops!");
    const function_idx = find_name(names, "function") orelse @panic("oops!");

    try std.testing.expectEqualDeep(theme[keyword_coroutine_idx], color_keyword);
    try std.testing.expectEqualDeep(theme[keyword_idx], color_keyword);
    try std.testing.expectEqualDeep(theme[keyword_function_idx], color_keyword_function);
    try std.testing.expectEqualDeep(theme[punctuation_idx], color_punctuation);
    try std.testing.expectEqualDeep(theme[function_idx], color_function);
}

test "configure higlights levels edge case" {
    const alloc = std.heap.c_allocator;
    const language = ts.ZIG;

    var error_offset: u32 = undefined;
    var error_type: c.TSQueryError = undefined;

    const query = c.ts_query_new(ts.tree_sitter_zig(), language.highlights.ptr, @as(u32, @intCast(language.highlights.len)), &error_offset, &error_type) orelse @panic("Failed to set up query");

    var parser = c.ts_parser_new();
    if (!c.ts_parser_set_language(parser, ts.tree_sitter_zig())) {
        @panic("Failed to set parser!");
    }

    const count = c.ts_query_capture_count(query);
    const names = try alloc.alloc([]const u8, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var length: u32 = 0;
        const capture_name_ptr = c.ts_query_capture_name_for_id(query, i, &length);
        const capture_name = capture_name_ptr[0..length];
        names[i] = capture_name;
    }

    const color_keyword = math.Float4.new(69.0, 420.0, 69420.0, 1.0);
    const color_punctuation = math.Float4.new(1.0, 1.0, 0.0, 1.0);
    const color_function = math.Float4.new(0.0, 1.0, 0.0, 0.0);
    const theme = try Highlight.configure_higlights(alloc, query, &.{
        .{ .name = "keyword", .color = color_keyword },
        .{ .name = "function", .color = color_function },
        .{ .name = "punctuation", .color = color_punctuation },
    });

    const keyword_coroutine_idx = find_name(names, "keyword.coroutine") orelse @panic("oops!");
    const keyword_idx = find_name(names, "keyword") orelse @panic("oops!");
    const keyword_function_idx = find_name(names, "keyword.function") orelse @panic("oops!");
    const punctuation_idx = find_name(names, "punctuation.bracket") orelse @panic("oops!");
    const function_idx = find_name(names, "function") orelse @panic("oops!");

    try std.testing.expectEqualDeep(theme[keyword_coroutine_idx], color_keyword);
    try std.testing.expectEqualDeep(theme[keyword_idx], color_keyword);
    try std.testing.expectEqualDeep(theme[keyword_function_idx], color_keyword);
    try std.testing.expectEqualDeep(theme[punctuation_idx], color_punctuation);
    try std.testing.expectEqualDeep(theme[function_idx], color_function);
}
