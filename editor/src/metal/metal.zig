const Object = @import("zig-objc").Object;

pub const MTLRenderCommandEncoder = struct {
    const Self = @This();

    obj: Object,

    pub fn fromId(id: anytype) Self {
        return .{
            .obj = Object.fromId(id),
        };
    }

    
};