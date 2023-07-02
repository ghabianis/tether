const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const print = std.debug.print;

pub const TextPos = struct {
    col: u32,
    line: u32,
};

/// Data structure to make text editing operations more efficient for longer text.
/// This implementation uses a doubly linked list where each node is a line.
pub const Rope = struct {
    const Self = @This();
    /// TODO: accessing data requires additional indirection, an optimization
    /// could be to have the node header (prev, next) and string data in the
    /// same allocation. Note that growing the allocation would mean the pointer
    /// is invalidated so we would have to update it (the nodes who point to the
    /// node we grow)
    const NodeList = DoublyLinkedList(ArrayList(u8));
    const Node =
        NodeList.Node;

    node_alloc: Allocator = std.heap.c_allocator,
    text_alloc: Allocator = std.heap.c_allocator,

    len: usize = 0,
    /// each node represents a line of text
    /// TODO: this is inefficient for text with many small lines. easy
    /// optimization for now is to have a separate kind of node just for
    /// representing a span of empty lines.
    nodes: NodeList = NodeList{},

    pub fn init(self: *Self) !void {
        _ = try self.nodes.insert(self.node_alloc, ArrayList(u8){}, null);
    }

    fn next_line(text_: ?[]const u8) struct { line: ?[]const u8, rest: ?[]const u8, newline: bool } {
        if (text_ == null or text_.?.len == 0) return .{ .line = null, .rest = null, .newline = false };
        const text = text_.?;
        var end: usize = 0;
        while (end < text.len) : (end += 1) {
            if (text[end] == '\n') {
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
                pos.col += @intCast(u32, nlr_line.len);
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

    pub fn line_index_node(self: *Self, line: u32) ?struct { node: *Node, i: usize } {
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
        return i + @intCast(usize, pos.col);
    }

    pub fn remove_text(self: *Self, text_start_: usize, text_end: usize) !void {
        var text_start = text_start_;
        var index_result = self.char_index_node(text_start, null) orelse return;
        var node: *Node = index_result.node;
        var i: usize = index_result.i;

        while (i < text_end) {
            const len = node.data.items.len;
            if (text_start >= i and text_start < i + len) {
                var node_cut_start = (text_start - i);
                var node_cut_end: usize = if (text_end < i + node.data.items.len) node_cut_start + (text_end - i) else node.data.items.len;
                const cut_len = node_cut_end - node_cut_start;

                self.len -= cut_len;
                node.data.items = remove_range(node.data.items, node_cut_start, node_cut_end);
                text_start += len;
            }

            if (node.data.items.len == 0 and node.next != null) {
                try self.remove_node(node);
            } else if (node.data.items.len > 0 and node.data.items[node.data.items.len - 1] != '\n') {
                try self.collapse_nodes(node);
            }
            const next = node.next;

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

    fn collapse_nodes(self: *Self, node: *Node) !void {
        const next = node.next orelse return;
        try node.data.appendSlice(self.text_alloc, next.data.items);
        try self.remove_node(next);
    }

    fn remove_node(self: *Self, node: *Node) !void {
        _ = self.nodes.remove(node);
        try node.free(self.node_alloc);
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
};

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

test "remove range" {
    var input = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var expected = [_]u8{9};

    const result = remove_range(&input, 0, 9);
    var known_at_runtime_zero: usize = 0;

    try std.testing.expectEqualDeep(expected[known_at_runtime_zero..expected.len], result[known_at_runtime_zero..result.len]);
}
