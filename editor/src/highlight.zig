const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;

const ts = @import("./treesitter.zig");
const c = ts.c;
const Rope = @import("./rope.zig").Rope;
const math = @import("./math.zig");
const r = @import("./regex.zig");
const strutil = @import("./strutil.zig");
const Edit = @import("./editor.zig").Edit;

const Highlight = @This();

parser: *c.TSParser,
lang: *const ts.Language,
tree: ?*c.TSTree = null,

query: *c.TSQuery,

/// Represents the byte of the starting character of the window
start_byte: u32 = 0,
end_byte: u32 = 0,

/// Mapping of TSQuery pattern index -> color
theme: []const ?math.Float4,
/// Cached regex state machines for pattern predicates. For the key we use tree-sitter's "value ID", which is an index to the store of values internally in tree-sitter
/// tree-sitter value id -> regex
regexes: HashMap(u32, r.regex_t),
/// Contains range and colors for text that needs to be highlighted
buf: HighlightBuf = .{},

error_query: *c.TSQuery,
errors: std.ArrayList(ErrorRange),

const ERROR_QUERY = "(ERROR) @__tether_error";

/// Initializes the highlighter with the given language and color scheme. `colors` is from calling `.to_indices()` on the theme
/// 
/// The highlighter must be configured to handle the queries (highlights):
///   1. If any queries have use `#match? <REGEX>` the REGEX needs to be compiled and stored
///   2. The given color scheme is turned into an array indexed by the TSQuery pattern index for easy retrieval of color to highlight text
///      (e.g. if IDENTIFIER is index 0 in the TSQueryCapture then `Highlight.theme[0]` will contain the color to highlight an identifier)
pub fn init(alloc: Allocator, language: *const ts.Language, colors: []const CaptureConfig) !Highlight {
    var error_offset: u32 = undefined;
    var error_type: c.TSQueryError = undefined;

    const query = c.ts_query_new(language.lang_fn(), language.highlights.ptr, @as(u32, @intCast(language.highlights.len)), &error_offset, &error_type) orelse @panic("Query error!");

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

    const theme = try Highlight.configure_highlights(alloc, query, colors);

    error_offset = undefined;
    error_type = undefined;

    const error_query = c.ts_query_new(language.lang_fn(), ERROR_QUERY, ERROR_QUERY.len, &error_offset, &error_type) orelse @panic("Failed to build error query");
    const errors = std.ArrayList(ErrorRange).init(alloc);

    return .{ .parser = parser.?, .query = query, .lang = language, .theme = theme, .regexes = regexes, .error_query = error_query, .errors = errors };
}

fn tree_or_init(self: *Highlight, str: []const u8) *c.TSTree {
    if (self.tree) |ts_tree| {
        return ts_tree;
    }
    var tree = c.ts_parser_parse_string(self.parser, null, str.ptr, @as(u32, @intCast(str.len))) orelse @panic("FAILED TO PARSE TREE!");
    self.tree = tree;
    return tree;
}

/// Adapted with minor changes from:
/// https://github.com/tree-sitter/tree-sitter/blob/1c65ca24bc9a734ab70115188f465e12eecf224e/highlight/src/lib.rs#L366
/// 
/// Basically handles finding the best match for capture names with multiple
/// levels. For example, if the capture names of the query are @keyword.function
/// and @keyword.operator, and the theme defines colors for only @keyword, then
/// it makes sure @keyword.function and @keyword.operator get the color for
/// @keyword.
/// 
/// The return value is an array indexed by capture ID (basically index in the TSQuery) that contains the color for that capture.
fn configure_highlights(alloc: Allocator, q: *c.TSQuery, recognized_names: []const CaptureConfig) ![]?math.Float4 {
    const count: u32 = c.ts_query_capture_count(q);
    var theme = try alloc.alloc(?math.Float4, @as(usize, @intCast(count)));
    @memset(theme, null);

    var capture_parts = std.ArrayList([]const u8).init(alloc);
    defer capture_parts.deinit();

    // Note that capture ID basically means index
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var length: u32 = 0;
        const capture_name_ptr = c.ts_query_capture_name_for_id(q, i, &length);
        const capture_name = capture_name_ptr[0..length];

        // Now find the best matching capture. "Best" meaning a capture in `recognized_names` with the most matching "parts".
        // "parts" are separated by dots: e.g. "@keyword.function" has two parts => "keyword", and "function"
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

pub fn update_tree(self: *Highlight, str: []const u8, edits: ?[]const ts.Edit) void {
    // If `self.tree` exists, either apply the edit to it, or delete it so we
    // can reparse the source from scratch.
    const old_tree = old_tree: {
        if (self.tree) |tstree| {
            if (edits) |e| {
                for (e) |*edit| {
                    c.ts_tree_edit(tstree, edit);
                }
                break :old_tree tstree;
            }
            c.ts_tree_delete(tstree);
            self.tree = null;
            break :old_tree null;
        }
        break :old_tree null;
    };
    defer {
        if (old_tree) |old| c.ts_tree_delete(old);
    }
    
    // We reset the parser each time this is called
    defer c.ts_parser_reset(self.parser);
    if (!c.ts_parser_set_language(self.parser, self.lang.lang_fn())) {
        @panic("Failed to set parser!");
    }
    const tree = c.ts_parser_parse_string(self.parser, old_tree, str.ptr, @intCast(str.len));
    self.tree = tree;
}

/// This function assigns highlight colors to the text vertices in `vertices: []math.Vertex` parameter.
/// 
/// NOTE: This function expects `self.tree` to either:
///       - contain a TSTree parsed to the latest version of the text
///       - OR be null, in which case it will parse and set `self.tree` itself
pub fn highlight(self: *Highlight, alloc: Allocator, str: []const u8, vertices: []math.Vertex, window_start_byte: u32, window_end_byte: u32, text_dirty: bool) !void {
    if (str.len == 0) return;

    // Create a tree if we don't have one already
    const tree = self.tree_or_init(str);

    var root_node = c.ts_tree_root_node(tree);
    var query_cursor = c.ts_query_cursor_new() orelse @panic("Failed to make query cursor.");
    c.ts_query_cursor_set_byte_range(query_cursor, window_start_byte, window_end_byte);
    defer c.ts_query_cursor_delete(query_cursor);

    c.ts_query_cursor_exec(query_cursor, self.query, root_node);

    var highlight_buf = &self.buf;
    // If the text has not been updated, or the window range has not changed, we don't need to run the queries again
    if (!text_dirty and window_start_byte == self.start_byte and window_end_byte == self.end_byte) {
        highlight_buf.cpy_to_vertices(vertices, window_start_byte, window_end_byte);
        return;
    }
    defer {
        self.start_byte = window_start_byte;
        self.end_byte = window_start_byte;
    }

    // Otherwise, clear our highlight captures and run the queries
    highlight_buf.list.clearRetainingCapacity();

    var iter = ts.QueryCaptureIter.new(query_cursor);
    while (iter.next()) |result| {
        const capture = result.capture;
        var length: u32 = undefined;
        const predicates_ptr = c.ts_query_predicates_for_pattern(self.query, result.match.pattern_index, &length);

        const matches = length == 0 or 
                      (length > 1 and self.satisfies_text_predicates(capture, predicates_ptr[0..length], str));

        if (!matches) continue;

        const this_node = capture.node;

        const start = c.ts_node_start_byte(capture.node);
        const end = c.ts_node_end_byte(capture.node);

        var the_len: u32 = 0;
        const str_ptr = c.ts_query_capture_name_for_id(self.query, capture.index, &the_len);
        _ = str_ptr;
        // if (std.mem.eql(u8, "comment", str_ptr[0..the_len])) {
        //     print("In comment: @{s}\n", .{str_ptr[0..the_len]});
        // }

        // print("MATCHING THE NODE: {s} => {s}\n", .{str_ptr[0..the_len], str[start..end]});

        // Grab the color that is associated with this capture kind based on the theme
        const color = self.theme[capture.index] orelse continue;

        const the_highlight = HighlightBuf.HighlightCapture.new(start, end, color);
        _ = the_highlight.cpy_to_vertices(vertices, window_start_byte, window_end_byte);
        try highlight_buf.list.append(alloc, the_highlight);

        // Skip over any subsequent highlighting patterns that capture the same
        // node. Captures for a given node are ordered by pattern index, so the
        // current capture should be the matching one, and the rest should be
        // ignored.
        // https://github.com/tree-sitter/tree-sitter/blob/6bbb50bef8249e6460e7d69e42cc8146622fa4fd/highlight/src/lib.rs#L955
        while (iter.peek()) |peek_result| {
            const next_node = peek_result.capture.node;
            if (next_node.id == this_node.id) {
                _ = iter.next();
            } else {
                break;
            }
        }

        // std.sort.insertion(HighlightBuf.HighlightCapture, highlight_buf.list.items, {}, HighlightBuf.HighlightCapture.less_than_ctx);
    }
}

pub fn find_errors(self: *Highlight, src: []const u8, text_dirty: bool, window_start_byte: u32, window_end_byte: u32) !void {
    if (!text_dirty and window_start_byte == self.start_byte and window_end_byte == self.end_byte) return;
    defer {
        self.start_byte = window_start_byte;
        self.end_byte = window_start_byte;
    }

    self.errors.clearRetainingCapacity();
    const tree = self.tree_or_init(src);
    const root_node = c.ts_tree_root_node(tree);

    var query_cursor = c.ts_query_cursor_new();
    defer c.ts_query_cursor_delete(query_cursor);
    c.ts_query_cursor_set_byte_range(query_cursor, window_start_byte, window_end_byte);

    var match: c.TSQueryMatch = undefined;

    c.ts_query_cursor_exec(query_cursor, self.error_query, root_node);

    while (c.ts_query_cursor_next_match(query_cursor, &match)) {
        std.debug.assert(match.capture_count == 1);

        const capture_maybe: ?*const c.TSQueryCapture = &match.captures[0];
        const capture = capture_maybe.?;
        
        const start = c.ts_node_start_byte(capture.node);
        const end = c.ts_node_end_byte(capture.node);

        if (self.errors.items.len == 0) { 
            try self.errors.append(
                ErrorRange{
                    .start = start,
                    .end = end,
                }
            );
            continue; 
        }
        
        // Potentially merge overlapping ranges.
        // We assume the invariant that TSQueryMatches come in ordered by the
        // start byte. This means that if there is an overlapping range, it will
        // be the last one we pushed to `self.errors`
        const last = &self.errors.items[self.errors.items.len - 1];
        std.debug.assert(start >= last.start);

        if (start < last.end) {
            if (end > last.end) {
                last.end = end;
            }
            continue;
        } 

        try self.errors.append(
            ErrorRange{
                .start = start,
                .end = end,
            }
        );
    }
}

fn satisfies_text_predicates(self: *Highlight, capture: *const c.TSQueryCapture, predicates: []const c.TSQueryPredicateStep, src: []const u8) bool {
    var i: u32 = 0;
    while (i < predicates.len) {
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

pub const ErrorRange = struct{
    start: u32,
    end: u32,
};

const HashMap = std.AutoHashMap;

/// Contains a list of `HighlightCapture`: basically a list of text that need to be highlighted with a specific color.
/// 
/// HighlightCaptures are a range of text which need to be highlighted. They are
/// directly created from tree-sitter's query captures. The color is from taking
/// the capture name and looking it up from the current theme.
pub const HighlightBuf = struct {
    list: ArrayList(HighlightCapture) = .{},

    const HighlightCapture = struct {
        start: u32,
        end: u32,
        color: math.Float4,
        const ctx = void;

        pub fn new(start: u32, end: u32, color: math.Float4) HighlightCapture {
            std.debug.assert(start <= end);
            return .{
                .start = start,
                .end = end,
                .color = color,
            };
        }

        pub fn less_than_ctx(asdasd: @TypeOf({}), self: HighlightCapture, other: HighlightCapture) bool {
            _ = asdasd;
            return self.less_than(other);
        }

        pub fn less_than(self: HighlightCapture, other: HighlightCapture) bool {
            if (self.start < other.start) return true;
            if (self.start > other.start) return false;
            if (self.end < other.end) return true;
            if (self.end > other.end) return false;
            return false;
        }

        /// Invariants:
        /// self.start < self.end
        /// self.start >= window_start_byte
        pub fn cpy_to_vertices(self: *const HighlightCapture, vertices: []math.Vertex, window_start_byte: u32, window_end_byte: u32) bool {
            // TODO: Now that we call `ts_query_cursor_set_byte_range()` to narrow the range of highlights, these two conditions should always be true.
            if (self.end <= window_start_byte) return false;
            if (self.start >= window_end_byte) return false;
            for (self.start..self.end) |i| {
                if (i < window_start_byte) continue;
                if (i >= window_end_byte) break;
                const vertIndex = (i - window_start_byte) * 6 + 6;
                const color = self.color;
                vertices[vertIndex].color = color;
                vertices[vertIndex + 1].color = color;
                vertices[vertIndex + 2].color = color;
                vertices[vertIndex + 3].color = color;
                vertices[vertIndex + 4].color = color;
                vertices[vertIndex + 5].color = color;
            }
            return true;
        }
    };


    fn find_starting_insert_idx(self: *const HighlightBuf, start: u32) ?u32 {
        var size: usize = self.list.items.len;
        var left: usize = 0;
        var right: usize = size;

        while (left < right) {
            const mid = left + size / 2;
            const cap: HighlightCapture = self.list.items[mid];
            if (cap.start == start) {
                // Look left if there are anymore
                var cur: i64 = @intCast(mid -| 1);
                var prev: i64 = @intCast(mid);
                while (cur >= 0) {
                    if (self.list.items[@intCast(cur)].start != start) return @intCast(prev);
                    prev = cur;
                    cur -= 1;
                }
                return 0;
            } else if (cap.start > start) {
                right = mid;
            } else {
                left = mid + 1;
            }
            size = right - left;
        }

        return null;
    }

    pub fn cpy_to_vertices(self: *const HighlightBuf, vertices: []math.Vertex, start_byte: u32, end_byte: u32) void {
        // const start_idx = self.find_starting_insert_idx(start_byte) orelse @panic("WTF");
        // for (self.list.items[start_idx..], start_idx..self.list.items.len) |*h, i| {
        //     _ = i;
        //     if (!h.cpy_to_vertices(vertices, start_byte, end_byte)) {
        //         return;
        //     }
        // }
        for (self.list.items) |*h| {
            _ = h.cpy_to_vertices(vertices, start_byte, end_byte);
            // if (!h.cpy_to_vertices(vertices, start_byte, end_byte)) {
            //     return;
            // }
        }
    }

    fn print_items(self: *const HighlightBuf) void {
        print("HighlightBuf (\n", .{});
        for (self.list.items) |*h| {
            print("  HighlightCapture [\n", .{});
            print("    start: {},\n", .{h.start});
            print("    end: {},\n", .{h.end});
            print("    color: {},\n", .{h.color});
            print("  ],\n", .{});
        }
        print(")\n", .{});
    }
};

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

test "configure highlights levels" {
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
    const theme = try Highlight.configure_highlights(alloc, query, &.{
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

test "configure highlights levels edge case" {
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
    const theme = try Highlight.configure_highlights(alloc, query, &.{
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