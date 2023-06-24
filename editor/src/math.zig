pub const Float2 = extern struct {
    x: f32,
    y: f32,
};

pub const Float3 = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Float4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

pub fn float2(x: f32, y: f32) Float2 {
    return .{ .x = x, .y = y };
}

pub fn float3(x: f32, y: f32, z: f32) Float3 {
    return .{ .x = x, .y = y, .z = z };
}

pub fn float4(x: f32, y: f32, z: f32, w: f32) Float4 {
    return .{ .x = x, .y = y, .z = z, .w = w };
}

pub const Float4x4 = extern struct {
    _0: Float4,
    _1: Float4,
    _2: Float4,
    _3: Float4,

    pub fn init(_0: Float4, _1: Float4, _2: Float4, _3: Float4) Float4x4 {
        return .{
            ._0 = _0,
            ._1 = _1,
            ._2 = _2,
            ._3 = _3,
        };
    }

    pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Float4x4 {
        const dx = right - left;
        const dy = top - bottom;
        const dz = far - near;

        const tx = -(right + left) / dx;
        const ty = -(top + bottom) / dy;
        const tz = (far + near) / dz;

        return @This().init(float4(2 / dx, 0, 0, 0), float4(0, 2 / dy, 0, 0), float4(0, 0, 2 / dz, 0), float4(tx, ty, tz, 1));
    }

    pub fn scale_by(s: f32) Float4x4 {
        return Float4x4(
            Float4(s, 0, 0, 0),
            Float4(0, s, 0, 0),
            Float4(0, 0, s, 0),
            Float4(0, 0, 0, 1),
        );
    }

    pub fn rotation_about(axis: Float3, angle_radians: f32) Float4x4 {
        const x = axis.x;
        const y = axis.y;
        const z = axis.z;
        const c = @cos(angle_radians);
        const s = @sin(angle_radians);
        const t = 1 - c;
        return Float4x4(
            Float4(t * x * x + c, t * x * y + z * s, t * x * z - y * s, 0),
            Float4(t * x * y - z * s, t * y * y + c, t * y * z + x * s, 0),
            Float4(t * x * z + y * s, t * y * z - x * s, t * z * z + c, 0),
            Float4(0, 0, 0, 1),
        );
    }

    pub fn translation_by(t: Float3) Float4x4 {
        return Float4x4(
            Float4(1, 0, 0, 0),
            Float4(0, 1, 0, 0),
            Float4(0, 0, 1, 0),
            Float4(t.x, t.y, t.z, 1),
        );
    }
};
