const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const print = std.debug.print;

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

pub const TextPos = struct {
    col: u32,
    line: u32,
};

pub const Rope = struct {
    const Self = @This();
    const NodeList = DoublyLinkedList(ArrayList(u8));
    const Node = NodeList.Node;

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

    pub fn insert_text(self: *Self, pos_: TextPos, text: []const u8) !void {
        var pos = pos_;
        var nlr = next_line(text);
        var prev_node: ?*Node = null;

        while (nlr.line) |nlr_line| {
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

            if (pos.col >= node.data.items.len) {
                try node.data.appendSlice(self.text_alloc, nlr_line);
            } else {
                try node.data.insertSlice(self.text_alloc, pos.col, nlr_line);
            }

            self.len += nlr_line.len;

            if (nlr.newline) {
                pos.line += 1;
                pos.col = 0;
            } else {
                pos.col += @intCast(u32, nlr_line.len);
            }

            nlr = next_line(nlr.rest);
            prev_node = node;
        }
    }

    fn index_node(self: *Self, char_idx: usize, starting_node: ?*Node) ?*Node {
        if (char_idx >= self.nodes.len) return null;

        var node: ?*Node = starting_node orelse self.nodes.first;
        var i: usize = 0;

        while (node != null) : (node = node.?.next) {
            if (i + node.?.data.items.len > char_idx) {
                return node;
            }
            i += node.?.data.items.len;
        }

        return node;
    }

    pub fn remove_text(self: *Self, start_: usize, end_: usize) !void {
        var tstart = start_;
        var tend = end_;
        var node: *Node = self.index_node(tstart, null) orelse return;
        var node_start: usize = 0;

        while (true) {
            if (node_start <= tstart) {
                var cut_start = tstart - node_start;
                var cut_end: usize = if (tend < node_start + node.data.items.len) tend - node_start else node.data.items.len;

                self.len -= cut_end - cut_start;
                node.data.items = remove_range(node.data.items, cut_start, cut_end);

                tstart += cut_end;
            }

            const temp = node;
            if (temp.data.items.len == 0) {
                try self.remove_node(temp);
            }

            node = node.next orelse return;
            node_start += node.data.items.len;
        }
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

    try rope.insert_text(.{ .line = 0, .col = 0 }, "pls work wtf");
    var str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings(str, "pls work wtf");
    try rope.insert_text(.{ .line = 0, .col = 12 }, "!!!");
    std.debug.print("NODE LEN: {d}\n", .{rope.nodes.len});
    str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings(str, "pls work wtf!!!");
}

test "multi-line insertion" {
    var rope = Rope{};

    try rope.insert_text(.{ .line = 0, .col = 0 }, "hello\nfriends\n");
    var str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqual(@as(usize, 2), rope.nodes.len);
    try std.testing.expectEqualStrings("hello\nfriends\n", str);

    try rope.insert_text(.{ .line = 0, .col = 0 }, "now in front\n");
    str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqual(@as(usize, 3), rope.nodes.len);
    try std.testing.expectEqualStrings("now in front\nhello\nfriends\n", str);

    try rope.insert_text(.{ .line = 2, .col = 0 }, "NOT!\n");
    str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqual(@as(usize, 4), rope.nodes.len);
    try std.testing.expectEqualStrings("now in front\nhello\nNOT!\nfriends\n", str);
}

test "deletion simple" {
    var rope = Rope{};

    try rope.insert_text(.{ .line = 0, .col = 0 }, "line 1\n");
    try rope.insert_text(.{ .line = 1, .col = 0 }, "line 2\n");

    var str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings("line 1\nline 2\n", str);
    try rope.remove_text(0, 7);
    str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings("line 2\n", str);
}

test "deletion multiline" {
    var rope = Rope{};

    try rope.insert_text(.{ .line = 0, .col = 0 }, "line 1\n");
    try rope.insert_text(.{ .line = 1, .col = 0 }, "line 2\n");

    var str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings("line 1\nline 2\n", str);
    try rope.remove_text(0, 10);
    str = try rope.as_str(std.heap.c_allocator);
    try std.testing.expectEqualStrings("e 2\n", str);
}

test "remove range" {
    var noobs = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };

    const noob = remove_range(&noobs, 0, 9);
    for (noob) |i| {
        std.debug.print("NICE: {}\n", .{i});
    }
}
