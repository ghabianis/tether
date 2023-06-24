const objc = @import("zig-objc");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Object = objc.Object;

// defined as unsigned long in NSObjCRuntime.h
pub const NSUInteger = usize;
pub const NSStringEncoding = enum(NSUInteger) {
    ascii = 1,
    utf8 = 4,
};

pub const NSString = struct {
    const Self = @This();
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());

    pub fn length(self: NSString) usize {
        return self.obj.msgSend(usize, objc.sel("length"), .{});
    }

    pub fn new_with_bytes(bytes: []const u8, encoding: NSStringEncoding) NSString {
        var object = @This().alloc();
        object = object.init_with_bytes(bytes, encoding);
        return object;
    }

    pub fn init_with_bytes(self: NSString, bytes: []const u8, encoding: NSStringEncoding) Self {
        const new = self.obj.msgSend(Self, objc.sel("initWithBytes:length:encoding:"), .{ bytes.ptr, bytes.len, encoding });
        return new;
    }

    pub fn to_c_string(self: NSString, buf: []u8) [*:0]u8 {
        const success = self.obj.msgSend(bool, objc.sel("getCString:maxLength:encoding:"), .{ buf.ptr, buf.len, NSStringEncoding.ascii });
        if (!success) {
            @panic("oh no!");
        }
        return @ptrCast([*:0]u8, buf);
    }
};

pub const MTLClearColor = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
};

pub const MTLLoadAction = enum(NSUInteger) {
    dont_care = 0,
    load = 1,
    clear = 2,
};

pub const MTLBlendOperation = enum(NSUInteger) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    operation_min = 3,
    operation_max = 4,
};

pub const MTLBlendFactor = enum(NSUInteger) {
    zero = 0,
    one = 1,
    source_color = 2,
    one_minus_source_color = 3,
    source_alpha = 4,
    one_minus_source_alpha = 5,
    destination_color = 6,
    one_minus_destination_color = 7,
    destination_alpha = 8,
    one_minus_destination_alpha = 9,
    source_alpha_saturated = 10,
    blend_color = 11,
    one_minus_blend_color = 12,
    blend_alpha = 13,
    one_minus_blend_alpha = 14,
    // MTLBlendFactorSource1Color              API_AVAILABLE(macos(10.12), ios(10.11)) = 15,
    // MTLBlendFactorOneMinusSource1Color      API_AVAILABLE(macos(10.12), ios(10.11)) = 16,
    // MTLBlendFactorSource1Alpha              API_AVAILABLE(macos(10.12), ios(10.11)) = 17,
    // MTLBlendFactorOneMinusSource1Alpha      API_AVAILABLE(macos(10.12), ios(10.11)) = 18,

};

// TODO: this is supposed to be an enum
pub const MTLPixelFormat = NSUInteger;

pub const MTLViewport = extern struct { origin_x: f64, origin_y: f64, width: f64, height: f64, znear: f64, zfar: f64 };

pub const MTLCommandBuffer = struct {
    const Self = @This();
    obj: objc.Object,
    pub usingnamespace DefineObject(Self);

    pub fn new_render_command_encoder(self: Self, render_pass_descriptor: objc.Object) MTLRenderCommandEncoder {
        return self.obj.msgSend(MTLRenderCommandEncoder, objc.sel("renderCommandEncoderWithDescriptor:"), .{render_pass_descriptor});
    }
};

pub const MTLRenderCommandEncoder = struct {
    const Self = @This();
    obj: objc.Object,
    pub usingnamespace DefineObject(Self);

    pub fn set_viewport(self: Self, viewport: MTLViewport) void {
        self.obj.msgSend(void, objc.sel("setViewport:"), .{viewport});
    }

    pub fn set_vertex_bytes(self: Self, bytes: []const u8, index: NSUInteger) void {
        self.obj.msgSend(void, objc.sel("setVertexBytes:length:atIndex:"), .{ bytes.ptr, bytes.len, index });
    }

    pub fn set_render_pipeline_state(self: Self, render_pipeline: MTLRenderPipelineState) void {
        self.obj.msgSend(void, objc.sel("setRenderPipelineState:"), .{render_pipeline});
    }

    pub fn set_vertex_buffer(self: Self, buffer: MTLBuffer, offset: NSUInteger, atIndex: NSUInteger) void {
        self.obj.msgSend(void, objc.sel("setVertexBuffer:offset:atIndex:"), .{ buffer.obj, offset, atIndex });
    }

    pub fn draw_primitives(self: Self, primitive_type: MTLPrimitiveType, vertex_start: NSUInteger, vertex_count: NSUInteger) void {
        self.obj.msgSend(void, objc.sel("drawPrimitives:vertexStart:vertexCount:"), .{ primitive_type, vertex_start, vertex_count });
    }

    pub fn end_encoding(self: Self) void {
        self.obj.msgSend(void, objc.sel("endEncoding"), .{});
    }
};

pub const MTLPrimitiveType = enum(NSUInteger) {
    point = 0,
    line = 1,
    line_strip = 2,
    triangle = 3,
    triangle_strip = 4,
};

pub const MTLBuffer = struct {
    const Self = @This();
    obj: objc.Object,
    pub usingnamespace DefineObject(Self);
};

pub const MTLRenderPassDescriptor = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());
};

pub const MTKView = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());

    pub fn current_render_pass_descriptor(self: @This()) ?MTLRenderPassDescriptor {
        return MTLRenderPassDescriptor.from_obj(self.obj.getProperty(objc.Object, "currentRenderPassDescriptor"));
    }

    pub fn color_pixel_format(self: @This()) MTLPixelFormat {
        return self.obj.getProperty(MTLPixelFormat, "colorPixelFormat");
    }
};

pub const MTLDevice = struct {
    const Self = @This();
    obj: objc.Object,
    pub usingnamespace DefineObject(Self);

    pub fn make_command_queue(self: MTLDevice) ?MTLCommandQueue {
        const value = self.obj.msgSend(objc.c.id, objc.sel("newCommandQueue"), .{});
        if (value == 0) {
            return null;
        }

        return MTLCommandQueue.from_id(value);
    }

    pub fn new_render_pipeline(self: Self, desc: MTLRenderPipelineDescriptor) !MTLRenderPipelineState {
        var err: ?*anyopaque = null;
        const pipeline_state = self.obj.msgSend(objc.Object, objc.sel("newRenderPipelineStateWithDescriptor:error:"), .{ desc.obj, err });
        try check_error(err);
        return MTLRenderPipelineState.from_obj(pipeline_state);
    }

    pub fn new_buffer_with_bytes(self: Self, bytes: []const u8, opts: MTLResourceOptions) MTLBuffer {
        const buf = self.obj.msgSend(MTLBuffer, objc.sel("newBufferWithBytes:length:options:"), .{ bytes.ptr, bytes.len, opts });
        return buf;
    }
};

pub const MTLResourceCPUCacheModeShift: NSUInteger = 0;
pub const MTLResourceCPUCacheModeMask: NSUInteger = 0xf << MTLResourceCPUCacheModeShift;

pub const MTLResourceStorageModeShift: NSUInteger = 4;
pub const MTLResourceStorageModeMask: NSUInteger = 0xf << MTLResourceStorageModeShift;

pub const MTLResourceHazardTrackingModeShift: NSUInteger = 8;
pub const MTLResourceHazardTrackingModeMask: NSUInteger = 0x3 << MTLResourceHazardTrackingModeShift;

// TODO: these broken
pub const MTLResourceOptions = enum(NSUInteger) {
    // cpu_cache_mode_default_cache = @enumToInt(MTLCPUCacheMode.default_cache) << MTLResourceCPUCacheModeShift,
    // cpu_cache_mode_write_combined = @enumToInt(MTLCPUCacheMode.write_combined) << MTLResourceCPUCacheModeShift,

    storage_mode_shared = @enumToInt(MTLStorageMode.shared) << MTLResourceStorageModeShift,
    storage_mode_managed = @enumToInt(MTLStorageMode.managed) << MTLResourceStorageModeShift,
    storage_mode_private = @enumToInt(MTLStorageMode.private) << MTLResourceStorageModeShift,
    storage_mode_memoryless = @enumToInt(MTLStorageMode.memoryless) << MTLResourceStorageModeShift,

    // hazard_tracking_mode_default = @enumToInt(MTLHazardTrackingMode.default) << MTLResourceHazardTrackingModeShift,
    // hazard_tracking_mode_untracked = @enumToInt(MTLHazardTrackingMode.untracked) << MTLResourceHazardTrackingModeShift,
    // hazard_tracking_mode_tracked = @enumToInt(MTLHazardTrackingMode.tracked) << MTLResourceHazardTrackingModeShift,
};

pub const MTLCPUCacheMode = enum(NSUInteger) {
    default_cache = 0,
    write_combined = 1,
};

pub const MTLStorageMode = enum(NSUInteger) {
    shared = 0,
    managed = 1,
    private = 2,
    memoryless = 3,
};

pub const MTLHazardTrackingMode = enum(NSUInteger) {
    default = 0,
    untracked = 1,
    tracked = 2,
};

pub const MTLCommandQueue = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());

    pub fn command_buffer(self: @This()) MTLCommandBuffer {
        return self.obj.msgSend(MTLCommandBuffer, objc.sel("commandBuffer"), .{});
    }
};

pub const MTLRenderPipelineState = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());
};

pub const MTLVertexFormat = enum(NSUInteger) {
    float = 28,
    float2 = 29,
    float3 = 30,
    float4 = 41,
};

pub const MTLVertexStepFunction = enum(NSUInteger) {
    Constant = 0,
    PerVertex = 1,
    PerInstance = 2,
    // MTLVertexStepFunctionPerPatch API_AVAILABLE(macos(10.12), ios(10.0)) = 3,
    // MTLVertexStepFunctionPerPatchControlPoint API_AVAILABLE(macos(10.12), ios(10.0)) = 4,
};

pub const MTLVertexDescriptor = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());
    pub const Attribute = struct {
        format: MTLVertexFormat,
        offset: NSUInteger,
        buffer_index: NSUInteger,
    };
    pub const Layout = struct {
        stride: NSUInteger,
        step_function: ?MTLVertexStepFunction = null,
        step_rate: ?NSUInteger = null,
    };

    pub fn set_attribute(self: @This(), idx: NSUInteger, attrib: Attribute) void {
        const attrs = objc.Object.fromId(self.obj.getProperty(?*anyopaque, "attributes"));
        const attr = attrs.msgSend(objc.Object, objc.sel("objectAtIndexedSubscript:"), .{idx});
        attr.setProperty("format", @enumToInt(attrib.format));
        attr.setProperty("offset", attrib.offset);
        attr.setProperty("bufferIndex", attrib.buffer_index);
    }

    pub fn set_layout(self: @This(), idx: NSUInteger, layout: Layout) void {
        const attrs = objc.Object.fromId(self.obj.getProperty(?*anyopaque, "layouts"));
        const attr = attrs.msgSend(objc.Object, objc.sel("objectAtIndexedSubscript:"), .{idx});
        attr.setProperty("stride", layout.stride);
        if (layout.step_function) |stepfn| {
            attr.setProperty("stepFunction", stepfn);
        }
        if (layout.step_rate) |steprate| {
            attr.setProperty("stepRate", steprate);
        }
    }
};

pub const MTLRenderPipelineDescriptor = struct {
    obj: objc.Object,
    pub usingnamespace DefineObject(@This());

    pub fn set_vertex_function(self: @This(), func_vert: objc.Object) void {
        self.obj.setProperty("vertexFunction", func_vert);
    }

    pub fn set_fragment_function(self: @This(), func_frag: objc.Object) void {
        self.obj.setProperty("fragmentFunction", func_frag);
    }

    pub fn set_vertex_descriptor(self: @This(), vertex_desc: MTLVertexDescriptor) void {
        self.obj.setProperty("vertexDescriptor", vertex_desc);
    }
};

fn DefineObject(comptime T: type) type {
    return struct {
        pub fn from_id(id: anytype) T {
            return .{
                .obj = Object.fromId(id),
            };
        }

        pub fn from_obj(object: objc.Object) T {
            return .{
                .obj = object,
            };
        }

        pub fn alloc() T {
            const class = objc.Class.getClass(comptime classTypeName(T)).?;
            const object = class.msgSend(objc.Object, objc.sel("alloc"), .{});
            return .{ .obj = object };
        }

        pub fn init(self: T) T {
            const obj = self.obj.msgSend(objc.Object, objc.sel("init"), .{});
            return from_obj(obj);
        }

        pub fn release(self: T) void {
            self.obj.msgSend(void, objc.sel("release"), .{});
        }
    };
}

pub const MetalError = error{
    Uhoh
};

/// Wrapper around @typeName(T) that strips the namespaces out of the string
pub fn classTypeName(comptime T: type) [:0]const u8 {
    const str = @typeName(T);
    var i = 0;
    var last_dot_idx = -1;
    while (str[i] != 0) {
        if (str[i] == '.') {
            last_dot_idx = i;
        }
        i += 1;
    }
    if (last_dot_idx == -1) return str[0..i : 0];
    
    return str[last_dot_idx + 1..i : 0];
}

pub fn check_error(err_: ?*anyopaque) !void {
    if (err_) |err| {
        const nserr = objc.Object.fromId(err);
        const str = 
            nserr.getProperty(?*NSString, "localizedDescription").?;

        var buf: [256]u8 = undefined;

        std.debug.print("meta error={s}\n", .{str.to_c_string(&buf)});

        return MetalError.Uhoh;
    }
}
