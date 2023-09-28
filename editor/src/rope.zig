const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const print = std.debug.print;

const strutil = @import("./strutil.zig");

pub const TextPos = packed struct {
    line: u32,
    /// An important thing to note is that in VISUAL and INSERT mode,
    /// the cursor is allowed to go past the end of the line. See `Editor.cursor_eol_for_mode()`
    col: u32,

    pub fn cmp(a: TextPos, b: TextPos) enum { Less, Equal, Greater } {
        if (a.line < b.line) return .Less;
        if (a.line > b.line) return .Greater;
        if (a.col < b.col) return .Less;
        if (a.col > b.col) return .Greater;
        return .Equal;
    }
};

/// Data structure to make text editing operations more efficient for longer text.
/// This implementation uses a doubly linked list where each node is a line.
/// 
/// Some invariants:
/// - There is at least always 1 node, even if text is empty that 1 node will have empty items
/// - Each node = 1 line, the newline char is on the preceeding node
pub const Rope = struct {
    const Self = @This();
    /// TODO: accessing data requires additional indirection, an optimization
    /// could be to have the node header (prev, next) and string data in the
    /// same allocation. Note that growing the allocation would mean the pointer
    /// is invalidated so we would have to update it (the nodes who point to the
    /// node we grow)
    const NodeList = DoublyLinkedList(ArrayList(u8));
    pub const Node =
        NodeList.Node;

    node_alloc: Allocator = std.heap.c_allocator,
    text_alloc: Allocator = std.heap.c_allocator,

    /// The length of the text in the rope
    len: usize = 0,

    /// each node represents a line of text
    /// TODO: this is inefficient for text with many small lines. easy
    /// optimization for now is to have a separate kind of node just for
    /// representing a span of empty lines.
    nodes: NodeList = NodeList{},

    pub fn init(self: *Self) !void {
        _ = try self.nodes.insert(self.node_alloc, ArrayList(u8){}, null);
    }

    pub fn print_nodes(self: *Self) void {
        print("NODES: [\n", .{});
        var node = self.nodes.first;
        var i: usize = 0;
        while (node) |n| {
            print("  {d} (len={d}): \"{s}\"\n", .{ i, n.data.items.len, n.data.items });
            i += 1;
            node = n.next;
        }
        print("]\n", .{});
    }

    pub fn next_line(text_: ?[]const u8) struct { line: ?[]const u8, rest: ?[]const u8, newline: bool } {
        if (text_ == null or text_.?.len == 0) return .{ .line = null, .rest = null, .newline = false };
        const text = text_.?;
        var end: usize = 0;
        while (end < text.len) : (end += 1) {
            if (strutil.is_newline(text[end])) {
                const rest = rest: {
                    if (end + 1 >= text.len) {
                        break :rest null;
                    }
                    break :rest text[end + 1 .. text.len];
                };
                return .{
                    .line = text[0 .. end + 1],
                    .rest = rest,
                    .newline = true,
                };
            }
        }

        return .{ .line = text[0..text.len], .rest = null, .newline = false };
    }

    pub fn replace_line(self: *Self, line_node: *Node, txt: []const u8) !void {
        self.len -= line_node.data.items.len;
        self.len += txt.len;
        try line_node.data.replaceRange(self.text_alloc, 0, line_node.data.items.len, txt);
    }

    /// TODO: allowing passing initial node to this function
    pub fn insert_text(self: *Self, pos_: TextPos, text: []const u8) !TextPos {
        var pos = pos_;
        var nlr = next_line(text);
        var prev_node: ?*Node = null;

        while (nlr.line) |nlr_line| {
            const has_newline = nlr.newline;
            if (pos.line > self.nodes.len) {
                std.debug.print("(pos.line={}) > (self.nodes.len={})\n", .{ pos.line, self.nodes.len });
                @panic("WTF");
            }

            const node: *Node = n: {
                if (prev_node) |pnode| {
                    break :n pnode;
                }
                const node_find = self.nodes.at_index_impl(pos.line);
                if (node_find.cur) |nf| {
                    break :n nf;
                }
                @panic("Failed to find node!");
            };

            if (has_newline) {
                prev_node = try self.split_node(node, pos.col);
            } else {
                prev_node = node;
            }

            if (pos.col == node.data.items.len) {
                try node.data.appendSlice(self.text_alloc, nlr_line);
            } else {
                try node.data.insertSlice(self.text_alloc, pos.col, nlr_line);
            }

            self.len += nlr_line.len;
            nlr = next_line(nlr.rest);
            if (has_newline) {
                pos.line += 1;
                pos.col = 0;
            } else {
                pos.col += @as(u32, @intCast(nlr_line.len));
                std.debug.assert(nlr.line == null);
            }
        }

        return pos;
    }

    /// Finds the node and its index in linked list at the given char index
    fn char_index_node(self: *Self, char_idx: usize, starting_node: ?*Node) ?struct { node: *Node, i: usize } {
        if (char_idx >= self.len) return null;

        var node: ?*Node = starting_node orelse self.nodes.first;
        var i: usize = 0;

        while (node != null) : (node = node.?.next) {
            if (char_idx >= i and char_idx < i + node.?.data.items.len) {
                return .{ .node = node.?, .i = i };
            }
            i += node.?.data.items.len;
        }

        return null;
    }

    pub fn node_at_line(self: *Self, line: u32) ?*Node {
        if (self.node_at_line_impl(line)) |nl| {
            return nl.node;
        }
        return null;
    }

    fn node_at_line_impl(self: *Self, line: u32) ?struct { node: *Node, i: usize } {
        var i: usize = 0;
        var iter: ?*Node = self.nodes.first;
        while (iter != null and i < line) {
            iter = iter.?.next;
            i += 1;
        }
        const node = iter orelse return null;
        return .{ .node = node, .i = i };
    }

    pub fn pos_to_idx(self: *Self, pos: TextPos) ?usize {
        var line: usize = pos.line;
        var iter_node: ?*Node = self.nodes.first;
        var i: usize = 0;
        while (iter_node != null and line > 0) {
            line -= 1;
            i += iter_node.?.data.items.len;
            iter_node = iter_node.?.next;
        }

        const node = iter_node orelse return null;
        _ = node;
        return i + @as(usize, @intCast(pos.col));
    }

    pub fn idx_to_pos(self: *Self, idx: usize) ?TextPos {
        var line: u32 = 0;
        var col: u32 = 0;

        var node = self.nodes.first;
        var i: usize = 0;
        while (node) |n| {
            if (idx >= i and idx < i + n.data.items.len) {
                col = @as(u32, @intCast(idx - i));
                return .{ .line = line, .col = col };
            }
            line += 1;
            i += n.data.items.len;
            node = n.next;
        }

        return null;
    }

    pub fn remove_line(self: *Self, line: u32) !void {
        var node = self.node_at_line(line) orelse unreachable;

        try self.remove_node(node);
    }

    pub fn remove_text(self: *Self, text_start_: usize, text_end: usize) !void {
        var text_start = text_start_;
        var index_result = self.char_index_node(text_start, null) orelse return;
        var node: *Node = index_result.node;
        var i: usize = index_result.i;

        while (i < text_end) {
            const len = node.data.items.len;
            // If within the cut range
            if (text_start >= i and text_start < i + len) {
                // Convert global string index => local node string index
                var node_cut_start = (text_start - i);
                var node_cut_end: usize = if (text_end - i > len) len else text_end - i;

                const cut_len = node_cut_end - node_cut_start;
                self.len -= cut_len;

                node.data.items = remove_range(node.data.items, node_cut_start, node_cut_end);
                // If the text range spans multiple nodes, incrementing
                // `text_start` by `cut_len` will put `text_start` at the
                // beginning of the next node (0), making the above
                // `node_cut_start` calculation correct
                text_start += cut_len;
            }

            const next = node.next;
            if (node.data.items.len == 0 and node.next != null) {
                try self.remove_node_dont_decrement_len(node);
            } else if (node.data.items.len > 0 and !strutil.is_newline(node.data.items[node.data.items.len - 1])) {
                try self.collapse_nodes(node);
            }

            node = next orelse return;
            i += len;
        }
    }

    fn split_node(self: *Self, node: *Node, loc: usize) !*Node {
        // Split the text slice
        var new_node_data = ArrayList(u8){};
        try new_node_data.appendSlice(self.text_alloc, node.data.items[loc..node.data.items.len]);
        // 0 1 2 3 5
        // h e l l o
        node.data.items.len = if (node.data.items.len == 0) 0 else loc;

        var new_node = try self.nodes.insert(self.node_alloc, new_node_data, node);
        return new_node;
    }

    /// Merge the given node with the one after it if it exists
    fn collapse_nodes(self: *Self, node: *Node) !void {
        const next = node.next orelse return;
        try node.data.appendSlice(self.text_alloc, next.data.items);
        try self.remove_node_dont_decrement_len(next);
    }

    fn remove_node(self: *Self, node: *Node) !void {
        self.len -= node.data.items.len;
        try self.remove_node_dont_decrement_len(node);
    }

    fn remove_node_dont_decrement_len(self: *Self, node: *Node) !void {
        // if we have 1 node keep it around
        if (node == self.nodes.first and node.next == null) {
            node.data.items.len = 0;
        } else {
            _ = self.nodes.remove(node);
            try node.free(self.node_alloc);
        }
    }

    pub fn modify_node_length(self: *Self, node: *Node, new_len: usize) void {
        if (new_len >= node.data.items.len) {
            const diff = new_len - node.data.items.len;
            self.len += diff;
        } else {
            const diff = node.data.items.len - new_len;
            self.len -= diff;
        }

        node.data.items.len = new_len;
    }

    pub fn as_str(self: *const Self, alloc: Allocator) ![]const u8 {
        var str: []u8 = try alloc.alloc(u8, self.len);
        var cur: ?*Node = self.nodes.first;

        var i: usize = 0;
        while (cur != null) : (cur = cur.?.next) {
            @memcpy(str[i .. i + cur.?.data.items.len], cur.?.data.items);
            i += cur.?.data.items.len;
        }

        return str;
    }

    /// TODO: Make this more efficient
    pub fn as_str_range(self: *const Self, alloc: Allocator, start: u32, end: u32) ![]const u8 {
        const ret = try alloc.alloc(u8, end - start);
        const str = try self.as_str(alloc);
        defer alloc.free(str);
        @memcpy(ret, str[start..end]);
        return ret;
    }

    pub fn next_char(self: *const Self, node: *const Node, idx: u32) ?u8 {
        _ = self;

        if (idx + 1 < node.data.items.len) {
            return node.data.items[idx + 1];
        }

        if (node.next) |next| {
            if (next.data.items.len > 0)
                return next.data.items[0];
        }

        return null;
    }

    pub fn iter_lines(self: *const Rope, starting_node: *const Node) RopeLineIterator {
        return .{
            .rope = self,
            .node = starting_node,
        };
    }

    pub fn iter_chars(starting_node: *const Node, cursor: TextPos) RopeCharIterator {
        return .{
            .node = starting_node,
            .cursor = cursor,
        };
    }

    pub fn iter_chars_rev(starting_node: *const Node, cursor: TextPos) RopeCharIteratorRev {
        return .{
            .node = starting_node,
            .cursor = cursor,
        };
    }
};

pub const RopeLineIterator = struct {
    rope: *const Rope,
    node: ?*const Rope.Node,

    pub fn next(self: *@This()) ?[]const u8 {
        if (self.rope.len == 0) return null;
        if (self.node) |n| {
            self.node = n.next;
            return n.data.items;
        } else {
            return null;
        }
    }
};

fn _SIMDRopeCharIterator() type {
    return struct {
        const VectorWidth: usize = 8;
        const Vector = @Vector(VectorWidth, u8);
        node: ?*Rope.Node,
        cursor: TextPos,
        last_imcomplete: ?u8 = null,

        fn reverse_buf(buf: *[VectorWidth]u8) void {
            var i: u8 = 0;
            while (i < VectorWidth / 2) : (i += 1) {
                const last = VectorWidth - 1 -| i;
                const temp = buf[last];
                buf[last] = buf[i];
                buf[i] = temp;
            }
        }

        fn next(self: *@This()) ?Vector {
            var buf = self.next_impl() orelse return null;
            // reverse_buf(&buf);
            return buf;
        }

        fn next_impl(self: *@This()) ?[8]u8 {
            if (self.last_imcomplete != null) return null;
            var buf: [VectorWidth]u8 = [_]u8{0} ** 8;
            var col: i64 = @as(i64, @intCast(self.cursor.col));

            var filled_amount: u8 = 0;
            while (filled_amount < VectorWidth) {
                const node = self.node orelse {
                    self.last_imcomplete = filled_amount;
                    return buf;
                };
                // 0123456789
                // we're asumming cursor always points in front of last char to grab
                // in this iteration
                var amount_to_grab: u8 = @as(u8, @intCast(VectorWidth)) - filled_amount;
                var start: usize = undefined;
                // line doesn't have enough to grab, grab entire line
                if (self.cursor.col + 1 < amount_to_grab) {
                    amount_to_grab = @as(u8, @intCast(self.cursor.col + 1));
                    start = 0;
                } else {
                    start = self.cursor.col - amount_to_grab + 1;
                }
                @memcpy(buf[filled_amount .. filled_amount + amount_to_grab], node.data.items[start .. start + amount_to_grab]);
                col -= @as(i64, @intCast(amount_to_grab));
                self.cursor.col = @as(u32, @intCast(@max(col, 0)));
                filled_amount += amount_to_grab;
                if (col < 0) {
                    self.node = node.prev;
                    self.cursor.line = self.cursor.line -| 1;
                    self.cursor.col = if (self.node) |n| @as(u32, @intCast(n.data.items.len -| 1)) else 0;
                    col = self.cursor.col;
                }
            }

            return buf;
        }

        // hello mate
        // whats going on
        // fn next_impl(self: *@This()) ?[8]u8 {
        //     if (self.last_imcomplete) return null;
        //     const node = self.node orelse return null;
        //     var buf: [VectorWidth]u8 = [_]u8{0} ** 8;

        //     // need to grab chars across multiple nodes
        //     if (node.data.items.len < VectorWidth) {
        //         @memcpy(buf[0..node.data.items.len], node.data.items);
        //         var filled_amount: u8 = @intCast(u8, node.data.items.len);
        //         var iter_node = node;
        //         while (iter_node.prev) |prev| {
        //             const wanted = VectorWidth - filled_amount;
        //             const grab_amount = @min(prev.data.items.len, wanted);
        //             @memcpy(buf[filled_amount..filled_amount+grab_amount], prev.data.items[0..grab_amount]);
        //             filled_amount += @intCast(u8, grab_amount);
        //             self.cursor.line = self.cursor.line -| 1;
        //             self.cursor.col  = @intCast(u32, prev.data.items.len) -| @intCast(u32, grab_amount);
        //             iter_node = prev;
        //             if (filled_amount >= VectorWidth) break;
        //         }
        //         if (filled_amount != VectorWidth) {
        //             self.last_imcomplete = true;
        //             return buf;
        //         }
        //         self.node = iter_node;
        //         return buf;
        //     }

        //     if (self.cursor.col < VectorWidth) {
        //         const end = 8;
        //         const start = 0;
        //         self.node = node.prev;
        //         self.cursor.line = self.cursor.line -| 1;
        //         self.cursor.col = if (self.node) |n| @intCast(u32, n.data.items.len) -| 1 else 0;
        //         @memcpy(buf[0..], node.data.items[start..end]);
        //         return buf;
        //     }

        //     const end = self.cursor.col;
        //     self.cursor.col -= @intCast(u32, VectorWidth);
        //     const start = self.cursor.col;
        //     @memcpy(buf[0..], node.data.items[start..end]);
        //     return buf;
        // }
    };
}

fn _RopeCharIterator(comptime Reverse: bool) type {
    return struct {
        node: *const Rope.Node,

        /// Points to the NEXT position to look at
        cursor: TextPos,

        past_boundary: if (Reverse) bool else void = if (Reverse) false else undefined,

        pub fn next(self: *@This()) ?u8 {
            // This means next_node() was called and there was no next node,
            // so quit
            if (comptime Reverse != true) {
                if (self.cursor.col >= self.node.data.items.len) return null;
            } else {
                if (self.past_boundary) return null;
            }

            const ret = self.node.data.items[self.cursor.col];
            _ = self.incr_cursor();
            return ret;
        }

        pub fn next_update_prev_cursor(self: *@This(), prev: *TextPos) ?u8 {
            const temp = self.cursor;
            if (self.next()) |ret| {
                prev.* = temp;
                return ret;
            }
            return null;
        }

        /// Look at the current char without consuming it
        pub fn peek(self: *@This()) ?u8 {
            var node_cpy = self.node;
            var cursor_cpy = self.cursor;
            var past_boundary_cpy = self.past_boundary;

            const ret = self.next();

            self.node = node_cpy;
            self.cursor = cursor_cpy;
            self.past_boundary = past_boundary_cpy;

            return ret;
        }

        /// Look at the next char without consuming anythign
        pub fn peek2(self: *@This()) ?u8 {
            var node_cpy = self.node;
            var cursor_cpy = self.cursor;
            var past_boundary_cpy = self.past_boundary;

            _ = self.next();
            const ret = self.next();

            self.node = node_cpy;
            self.cursor = cursor_cpy;
            self.past_boundary = past_boundary_cpy;

            return ret;
        }

        pub fn back(self: *@This(), prev: *TextPos) void {
            if (self.cursor.col == 0) {
                self.node = self.node.prev orelse @panic("Back on col 0 line 0");
            }
            self.cursor = prev;
        }

        pub fn incr_cursor(self: *@This()) bool {
            if (comptime Reverse) {
                if (self.cursor.col == 0) {
                    return self.next_node();
                } else {
                    self.cursor.col -= 1;
                    return true;
                }
            } else {
                self.cursor.col += 1;
                if (self.cursor.col >= self.node.data.items.len) {
                    return self.next_node();
                }
                return true;
            }
        }

        fn next_node(self: *@This()) bool {
            if (comptime Reverse) {
                if (self.node.prev) |n| {
                    self.cursor.line -= 1;
                    self.cursor.col = @as(u32, @intCast(n.data.items.len)) -| 1;
                    self.node = n;
                    return true;
                }
                self.past_boundary = true;
                return false;
            } else {
                if (self.node.next) |n| {
                    self.cursor.line += 1;
                    self.cursor.col = 0;
                    self.node = n;
                    return true;
                }

                return false;
            }
        }
    };
}

pub const SimdRopeCharIterator = _SIMDRopeCharIterator();
pub const RopeCharIterator = _RopeCharIterator(false);
pub const RopeCharIteratorRev = _RopeCharIterator(true);

fn DoublyLinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        first: ?*Node = null,
        last: ?*Node = null,
        len: usize = 0,

        const Node = struct {
            data: T,
            prev: ?*Node = null,
            next: ?*Node = null,

            pub fn free(self: *Node, alloc: Allocator) !void {
                alloc.destroy(self);
            }

            /// Return the index where the newline is
            pub fn end(self: *Node) usize {
                return if (self.data.items.len == 0) 0 else self.data.items.len - 1;
            }

            pub fn decrement_textpos(node: **const Node, pos: *TextPos) void {
                if (pos.col == 0) {
                    if (node.*.prev) |prev| {
                        pos.line -= 1;
                        pos.col = @intCast(prev.data.items.len -| 1);
                        node.* = prev;
                    }
                } else {
                    pos.col -= 1;
                }
            }

            pub fn increment_textpos(node: **const Node, pos: *TextPos) void {
                pos.col += 1;
                if (pos.col >= node.*.data.items.len) {
                    if (node.*.next) |next| {
                        pos.col = 0;
                        node.* = next;
                        pos.line += 1;
                    }
                }
            }
        };

        fn at_index_impl(self: *Self, idx: usize) struct { prev: ?*Node, cur: ?*Node } {
            var prev: ?*Node = null;
            var next: ?*Node = self.first;
            var i: usize = 0;
            while (i < idx and next != null) : (i += 1) {
                prev = next;
                next = next.?.next;
            }

            return .{
                .prev = prev,
                .cur = next,
            };
        }

        pub fn insert_at(self: *Self, alloc: Allocator, data: T, idx: usize) !*Node {
            const find = self.at_index_impl(idx);

            return self.insert(alloc, data, find.prev);
        }

        pub fn insert(self: *Self, alloc: Allocator, data: T, prev: ?*Node) !*Node {
            const node = try alloc.create(Node);
            node.* = Node{
                .data = data,
            };
            self.len += 1;

            if (prev == null) {
                if (self.first) |f| {
                    node.next = f;
                } else {
                    self.last = node;
                }
                self.first = node;
                return node;
            }

            const next = prev.?.next;
            node.prev = prev;
            node.next = next;
            prev.?.next = node;
            if (next) |next_node| {
                next_node.prev = node;
            } else {
                self.last = node;
            }

            return node;
        }

        pub fn remove_at(self: *Self, idx: usize) bool {
            const find = self.at_index_impl(idx);
            if (find.next != null) return self.remove(find.next);
            return false;
        }

        pub fn remove(self: *Self, node: *Node) bool {
            self.len -= 1;
            if (node.prev == null) {
                if (node.next) |next_node| {
                    self.first = next_node;
                    next_node.prev = null;
                } else {
                    self.first = null;
                    self.last = null;
                }
                return true;
            }

            const next = node.next;
            if (next) |next_node| {
                next_node.prev = node.prev.?;
                node.prev.?.next = next_node;
            } else {
                node.prev.?.next = null;
                self.last = node.prev;
            }

            return true;
        }
    };
}

fn remove_range(src: []u8, start: usize, end: usize) []u8 {
    const len = src.len - (end - start);
    if (start > 0) {
        // [ ___ XXX ___ ]
        std.mem.copyForwards(u8, src[start..src.len], src[end..src.len]);
    } else {
        // [ XXX ________ ]
        std.mem.copyForwards(u8, src, src[end..src.len]);
    }
    return src[0..len];
}

test "linked list impl" {
    const alloc = std.heap.c_allocator;
    var list = DoublyLinkedList([]const u8){};

    var a = try list.insert(alloc, "HELLO", null);
    var b = try list.insert(alloc, "NICE", a);

    try std.testing.expectEqual(a.next, b);
    try std.testing.expectEqual(b.prev, a);
    try std.testing.expectEqual(list.first, a);
    try std.testing.expectEqual(list.last, b);

    var c = try list.insert(alloc, "in between", a);
    try std.testing.expectEqual(a.next, c);
    try std.testing.expectEqual(c.prev, a);
    try std.testing.expectEqual(c.next, b);
    try std.testing.expectEqual(b.prev, c);
    try std.testing.expectEqual(b.next, null);
    try std.testing.expectEqual(list.first, a);
    try std.testing.expectEqual(list.last, b);
}

test "basic insertion" {
    var rope = Rope{};
    try rope.init();

    var pos = try rope.insert_text(.{ .line = 0, .col = 0 }, "pls work wtf");
    var expected_pos: TextPos = .{ .line = 0, .col = 12 };
    try std.testing.expectEqual(expected_pos, pos);

    var str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings(str, "pls work wtf");

    pos = try rope.insert_text(.{ .line = 0, .col = 12 }, "!!!");
    expected_pos.col += 3;
    try std.testing.expectEqual(expected_pos, pos);

    str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings(str, "pls work wtf!!!");
}

test "basic insertion2" {
    var rope = Rope{};
    try rope.init();

    var pos = try rope.insert_text(.{ .line = 0, .col = 0 }, "pls work wtf");
    pos.col -= 5;
    pos = try rope.insert_text(pos, "!!!");
    var str = try rope.as_str(std.heap.c_allocator);
    print("str: {s}\n", .{str});
}

test "multi-line insertion" {
    var rope = Rope{};
    try rope.init();

    var pos = try rope.insert_text(.{ .line = 0, .col = 0 }, "hello\nfriends\n");
    var expected_pos: TextPos = .{ .line = 2, .col = 0 };
    try std.testing.expectEqual(expected_pos, pos);

    var str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqual(@as(usize, 3), rope.nodes.len);
    try std.testing.expectEqualStrings("hello\nfriends\n", str);

    _ = try rope.insert_text(.{ .line = 0, .col = 0 }, "now in front\n");
    str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqual(@as(usize, 4), rope.nodes.len);
    try std.testing.expectEqualStrings("now in front\nhello\nfriends\n", str);

    _ = try rope.insert_text(.{ .line = 2, .col = 0 }, "NOT!\n");
    str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqual(@as(usize, 5), rope.nodes.len);
    try std.testing.expectEqualStrings("now in front\nhello\nNOT!\nfriends\n", str);
}

test "deletion simple" {
    var rope = Rope{};
    try rope.init();

    _ = try rope.insert_text(.{ .line = 0, .col = 0 }, "line 1\n");
    _ = try rope.insert_text(.{ .line = 1, .col = 0 }, "line 2\n");

    var str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings("line 1\nline 2\n", str);
    try rope.remove_text(0, 7);
    str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings("line 2\n", str);
}

test "deletion multiline" {
    var rope = Rope{};
    try rope.init();

    _ = try rope.insert_text(.{ .line = 0, .col = 0 }, "line 1\n");
    _ = try rope.insert_text(.{ .line = 1, .col = 0 }, "line 2\n");

    var str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings("line 1\nline 2\n", str);
    try rope.remove_text(0, 10);
    str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings("e 2\n", str);
}

test "delete all" {
    var rope = Rope{};
    try rope.init();

    const insertion_text = "fuck\nthis\nshit\nbro!";
    _ = try rope.insert_text(.{ .line = 0, .col = 0 }, insertion_text);
    try rope.remove_text(0, insertion_text.len);

    var str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings("", str);
}

test "remove range" {
    var input = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var expected = [_]u8{9};

    const result = remove_range(&input, 0, 9);
    var known_at_runtime_zero: usize = 0;

    try std.testing.expectEqualDeep(expected[known_at_runtime_zero..expected.len], result[known_at_runtime_zero..result.len]);
}

const TagSize = u15;
const AddressableSize = u49;

pub const TaggedPointer = packed struct {
    _ptr: AddressableSize,
    data: TagSize,

    pub inline fn init(ptr: anytype, data: TagSize) TaggedPointer {
        const Ptr = @TypeOf(ptr);

        if (comptime @typeInfo(Ptr) != .Pointer and Ptr != ?*anyopaque) {
            @compileError(@typeName(Ptr) ++ " must be a ptr, received: " ++ @tagName(@typeInfo(Ptr)));
        }

        const address = @intFromPtr(ptr);

        return TaggedPointer{
            ._ptr = @as(AddressableSize, @truncate(address)),
            .data = data,
        };
    }

    pub inline fn get(this: TaggedPointer, comptime Type: type) *Type {
        return @as(*Type, @ptrFromInt(@as(usize, @intCast(this._ptr))));
    }

    pub inline fn from(val: anytype) TaggedPointer {
        const ValueType = @TypeOf(val);
        return switch (ValueType) {
            f64, i64, u64 => @as(TaggedPointer, @bitCast(val)),
            ?*anyopaque, *anyopaque => @as(TaggedPointer, @bitCast(@intFromPtr(val))),
            else => @compileError("Unsupported type: " ++ @typeName(ValueType)),
        };
    }

    pub inline fn to(this: TaggedPointer) *anyopaque {
        return @as(*anyopaque, @ptrFromInt(@as(u64, @bitCast(this))));
    }
};

// partially emulates behaviour of @typeName in previous Zig versions,
// converting "some.namespace.MyType" to "MyType"
pub fn typeBaseName(comptime fullname: []const u8) []const u8 {

    // leave type name like "namespace.WrapperType(namespace.MyType)" as it is
    const baseidx = comptime std.mem.indexOf(u8, fullname, "(");
    if (baseidx != null) return fullname;

    const idx = comptime std.mem.lastIndexOf(u8, fullname, ".");

    const name = if (idx == null) fullname else fullname[(idx.? + 1)..];
    return comptime std.fmt.comptimePrint("{s}", .{name});
}

pub fn TaggedPointerUnion(comptime Types: anytype) type {
    const TagType: type = tag_break: {
        if (std.meta.trait.isIndexable(@TypeOf(Types))) {
            var enumFields: [Types.len]std.builtin.Type.EnumField = undefined;
            var decls = [_]std.builtin.Type.Declaration{};

            inline for (Types, 0..) |field, i| {
                enumFields[i] = .{
                    .name = comptime typeBaseName(@typeName(field)),
                    .value = 1024 - i,
                };
            }

            break :tag_break @Type(.{
                .Enum = .{
                    .tag_type = TagSize,
                    .fields = &enumFields,
                    .decls = &decls,
                    .is_exhaustive = false,
                },
            });
        } else {
            const Fields: []const std.builtin.Type.StructField = std.meta.fields(@TypeOf(Types));
            var enumFields: [Fields.len]std.builtin.Type.EnumField = undefined;
            var decls = [_]std.builtin.Type.Declaration{};

            inline for (Fields, 0..) |field, i| {
                enumFields[i] = .{
                    .name = comptime typeBaseName(@typeName(field.default_value.?)),
                    .value = 1024 - i,
                };
            }

            break :tag_break @Type(.{
                .Enum = .{
                    .tag_type = TagSize,
                    .fields = &enumFields,
                    .decls = &decls,
                    .is_exhaustive = false,
                },
            });
        }
    };

    return struct {
        pub const Tag = TagType;
        repr: TaggedPointer,

        const This = @This();
        fn assert_type(comptime Type: type) void {
            var name = comptime typeBaseName(@typeName(Type));
            if (!comptime @hasField(Tag, name)) {
                @compileError("TaggedPointerUnion does not have " ++ name ++ ".");
            }
        }
        pub inline fn get(this: This, comptime Type: anytype) ?*Type {
            comptime assert_type(Type);

            return if (this.is(Type)) this.as(Type) else null;
        }

        pub inline fn tag(this: This) TagType {
            return @as(TagType, @enumFromInt(this.repr.data));
        }

        /// unsafely cast a tagged pointer to a specific type, without checking that it's really that type
        pub inline fn as(this: This, comptime Type: type) *Type {
            comptime assert_type(Type);
            return this.repr.get(Type);
        }

        pub inline fn is(this: This, comptime Type: type) bool {
            comptime assert_type(Type);
            return this.repr.data == comptime @intFromEnum(@field(Tag, typeBaseName(@typeName(Type))));
        }

        pub fn set(this: *@This(), _ptr: anytype) void {
            this.* = @This().init(_ptr);
        }

        pub inline fn isValidPtr(_ptr: ?*anyopaque) bool {
            return This.isValid(This.from(_ptr));
        }

        pub inline fn isValid(this: This) bool {
            return switch (this.repr.data) {
                @intFromEnum(
                    @field(Tag, typeBaseName(@typeName(Types[Types.len - 1]))),
                )...@intFromEnum(
                    @field(Tag, typeBaseName(@typeName(Types[0]))),
                ) => true,
                else => false,
            };
        }

        pub inline fn from(_ptr: ?*anyopaque) This {
            return This{ .repr = TaggedPointer.from(_ptr) };
        }

        pub inline fn ptr(this: This) *anyopaque {
            return this.repr.to();
        }

        pub inline fn ptrUnsafe(this: This) *anyopaque {
            @setRuntimeSafety(false);
            return this.repr.to();
        }

        pub inline fn init(_ptr: anytype) This {
            const Type = std.meta.Child(@TypeOf(_ptr));
            return initWithType(Type, _ptr);
        }

        pub inline fn initWithType(comptime Type: type, _ptr: anytype) This {
            const name = comptime typeBaseName(@typeName(Type));

            // there will be a compiler error if the passed in type doesn't exist in the enum
            return This{ .repr = TaggedPointer.init(_ptr, @intFromEnum(@field(Tag, name))) };
        }
    };
}

test "tagged pointer" {
    const IntPrimitive = struct { val: u32 = 0 };
    const StringPrimitive = struct { val: []const u8 = "" };
    const Object = struct { blah: u32, val: u32 };
    // const Invalid = struct {
    //     wrong: bool = true,
    // };
    const Union = TaggedPointerUnion(.{ IntPrimitive, StringPrimitive, Object });
    var str = try std.heap.c_allocator.create(StringPrimitive);
    str.* = StringPrimitive{ .val = "hello!" };
    var un = Union.init(str);
    try std.testing.expect(un.is(StringPrimitive));
    try std.testing.expectEqualStrings(un.as(StringPrimitive).val, "hello!");
    try std.testing.expect(!un.is(IntPrimitive));
}