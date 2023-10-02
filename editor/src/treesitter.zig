pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub extern "C" fn tree_sitter_zig() *c.TSLanguage;
pub extern "C" fn tree_sitter_c() *c.TSLanguage;
pub extern "C" fn tree_sitter_rust() *c.TSLanguage;
// pub extern "C" fn tree_sitter_typescript() *c.TSLanguage;

pub const RUST: Language = Language.comptime_new(
    tree_sitter_rust, 
    "./syntax/tree-sitter-rust/queries/highlights.scm", 
    "./syntax/tree-sitter-rust/queries/highlights.scm", 
    null
);

pub const ZIG: Language = Language.comptime_new(
    tree_sitter_zig,
    "./syntax/tree-sitter-zig/queries/highlights.scm",
    "./syntax/tree-sitter-zig/queries/injections.scm",
    null,
);

pub const C: Language = Language.comptime_new(
    tree_sitter_c,
    "./syntax/tree-sitter-c/queries/highlights.scm",
    null,
    null,
);

// pub const TS: Language = Language.comptime_new(
//     tree_sitter_typescript,
//     "./syntax/tree-sitter-typescript/queries/highlights.scm",
//     null,
//     null,
// );

pub const Language = struct {
    highlights: []const u8,
    injections: []const u8,
    locals: []const u8,
    lang_fn: *const fn () callconv(.C) *c.TSLanguage,

    pub fn comptime_new(comptime lang_fn: *const fn () callconv(.C) *c.TSLanguage, comptime highlights_path: []const u8, comptime injections_path: ?[]const u8, comptime locals_path: ?[]const u8) Language {
        const highlights = @embedFile(highlights_path);
        const injections = if (injections_path) |path| @embedFile(path) else "";
        const locals = if (locals_path) |path| @embedFile(path) else "";

        return .{
            .lang_fn = lang_fn,
            .highlights = highlights,
            .injections = injections,
            .locals = locals,
        };
    }
};

pub const Tree = packed struct {
    ptr: *c.TSTree,

    pub fn from_ptr(p: *c.TSTree) Tree {
        return .{ .ptr = p };
    }

    pub fn deinit(self: Tree) !void {
        c.ts_tree_delete(self.ptr);
    }
};

pub const Edit = c.TSInputEdit;

pub const QueryCaptureIter = struct {
    cursor: *c.TSQueryCursor,
    peeked: ?Item,

    pub const Item = struct {
        match: c.TSQueryMatch,
        idx: u32,
        capture: *const c.TSQueryCapture
    };

    pub fn new(cursor: *c.TSQueryCursor) QueryCaptureIter {
        return .{
            .cursor = cursor,
            .peeked = null,
        };
    }

    pub fn next(self: *QueryCaptureIter) ?Item {
        if (self.peeked) |p| {
            self.peeked = null;
            return p;
        }

        var match: c.TSQueryMatch = undefined;
        var idx: u32 = undefined;
        if (!c.ts_query_cursor_next_capture(self.cursor, &match, &idx)) {
            return null;
        } 

        const capture_maybe: ?*const c.TSQueryCapture = &match.captures[idx];
        const capture = capture_maybe.?;
        return .{ .match = match, .idx = idx, .capture = capture };
    }

    pub fn peek(self: *QueryCaptureIter) ?Item {
        if (self.peeked) |p| {
            return p;
        }

        var match: c.TSQueryMatch = undefined;
        var idx: u32 = undefined;
        if (!c.ts_query_cursor_next_capture(self.cursor, &match, &idx)) {
            return null;
        } 

        const capture_maybe: ?*const c.TSQueryCapture = &match.captures[idx];
        const capture = capture_maybe.?;
        const result = .{ .match = match, .idx = idx, .capture = capture };
        self.peeked = result;

        return self.peeked;
    }
};
