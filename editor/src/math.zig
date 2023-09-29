const std = @import("std");
const metal = @import("./metal.zig");
const GlyphInfo = @import("./font.zig").GlyphInfo;

pub const Vertex = extern struct {
    pos: Float2,
    tex_coords: Float2,
    color: Float4,

    pub fn default() Vertex {
        return .{ .pos = .{ .x = 0.0, .y = 0.0 }, .tex_coords = .{ .x = 0.0, .y = 0.0 }, .color = .{ .x = 0.0, .y = 0.0, .w = 0.0, .z = 0.0 } };
    }

    pub fn is_default(self: *const Vertex) bool {
        return self.pos.x == 0 and self.pos.y == 0 and self.tex_coords.x == 0 and self.tex_coords.y == 0 and self.color.x == 0 and self.color.y == 0 and self.color.z == 0 and self.color.w == 0;
    }

    pub fn square_from_glyph(
        rect: *const metal.CGRect,
        pos: *const metal.CGPoint,
        glyph_info: *const GlyphInfo,
        color: Float4,
        x: f32,
        y: f32,
        atlas_w: f32,
        atlas_h: f32,
    ) [6]Vertex {
        const width = @as(f32, @floatFromInt(rect.widthCeil()));
        const b = @as(f32, @floatCast(pos.y)) + y + @as(f32, @floatCast(rect.origin.y));
        const t = b + @as(f32, @floatCast(rect.size.height));
        const l = @as(f32, @floatCast(pos.x)) + x + @as(f32, @floatCast(rect.origin.x));
        const r = l + @as(f32, @floatCast(rect.size.width));

        const txt = glyph_info.ty - @as(f32, @floatFromInt(rect.heightCeil())) / atlas_h;
        const txb = glyph_info.ty;
        const txl = glyph_info.tx;
        const txr = glyph_info.tx + width / atlas_w;

        return Vertex.square(.{ .t = t, .b = b, .l = l, .r = r }, .{ .t = txt, .b = txb, .l = txl, .r = txr }, color);
    }

    pub fn square(coords: struct { t: f32, b: f32, l: f32, r: f32 }, tex_coords: struct { t: f32, b: f32, l: f32, r: f32 }, color: Float4) [6]Vertex {
        const t = coords.t;
        const b = coords.b;
        const l = coords.l;
        const r = coords.r;

        const tl = float2(l, t);
        const tr = float2(r, t);
        const bl = float2(l, b);
        const br = float2(r, b);

        const txt = tex_coords.t;
        const txb = tex_coords.b;
        const txl = tex_coords.l;
        const txr = tex_coords.r;
        const tx_tl = float2(txl, txt);
        const tx_tr = float2(txr, txt);
        const tx_bl = float2(txl, txb);
        const tx_br = float2(txr, txb);

        return [_]Vertex{
            // triangle 1
            .{
                .pos = tl,
                .tex_coords = tx_tl,
                .color = color,
            },
            .{
                .pos = tr,
                .tex_coords = tx_tr,
                .color = color,
            },
            .{
                .pos = bl,
                .tex_coords = tx_bl,
                .color = color,
            },

            // triangle 2
            .{
                .pos = tr,
                .tex_coords = tx_tr,
                .color = color,
            },
            .{
                .pos = br,
                .tex_coords = tx_br,
                .color = color,
            },
            .{
                .pos = bl,
                .tex_coords = tx_bl,
                .color = color,
            },
        };
    }
};

pub const Scalar = extern struct {
    val: f32,

    pub fn new(v: f32) Scalar {
        return .{.val = v};
    }

    pub fn interpolate(start: Scalar, end: Scalar, t: f32) Scalar {
        return .{ .val = start.val + (end.val - start.val) * t };
    }

    pub fn mul_f(self: Scalar, f: f32) Scalar {
        return .{ .val = self.val * f };
    }

    pub fn add(self: Scalar, other: Scalar) Scalar {
        return .{ .val = self.val + other.val };
    }

    pub fn hermite(t: f32, p1: Scalar, s1: Scalar, p2: Scalar, s2: Scalar) Scalar {
        return hermite_generic(Scalar, t, p1, s1, p2, s2);
    }

    pub fn default() Scalar {
        return .{ .val = 0 };
    }
};

pub const Float2 = extern struct {
    x: f32,
    y: f32,

    pub fn debug(self: *const Float2) void {
        std.debug.print("Float2[x = {d}, y = {d}]\n", .{ self.x, self.y });
    }

    pub inline fn new(x: f32, y: f32) Float2 {
        return .{
            .x = x,
            .y = y,
        };
    }

    pub fn div(self: Float2, other: Float2) Float2 {
        return float2(
            self.x / other.x,
            self.y / other.y,
        );
    }

    pub fn as_slice(self: *Float2) []f32 {
        return @ptrCast(@as(*[2]f32, @ptrCast(self)));
    }

    pub fn as_slice_const(self: *const Float2) []const f32 {
        return @ptrCast(@as(*const [2]f32, @ptrCast(self)));
    }

    pub fn add(self: Float2, other: Float2) Float2 {
        return float2(self.x + other.x, self.y + other.y);
    }
    
    pub fn mul_f(self: Float2, scalar: f32) Float2 {
        return float2(self.x * scalar, self.y * scalar);
    }

    pub fn default() Float2 {
        return float2(0, 0);
    }

    pub fn interpolate(start: Float2, end: Float2, t: f32) Float2 {
        return float2(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t);
    }

    pub fn hermite(t: f32, p1: Float2, s1: Float2, p2: Float2, s2: Float2) Float2 {
        return hermite_generic(Float2, t, p1, s1, p2, s2);
    }

    pub fn magnitude(self: Float2) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn norm(self: Float2) Float2 {
        const mag = self.magnitude();
        if (mag > 0) {
            return float2(self.x / mag, self.y / mag);
        }
        return self;
    }
};

pub const Float3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    pub const WHITE = float3(1.0, 1.0, 1.0);
    pub const BLUE = float3(0.0, 0.0, 1.0);
    pub const YELLOW = float3(1.0, 1.0, 0.0);
    pub const ORANGE = float3(1.0, 0.5, 0.0);
    pub const RED = float3(1.0, 0.1, 0.0);

    pub fn screen_to_ndc_vec(self: Float3, screen_size: Float2) Float3 {
        return float3((2 * self.x / screen_size.x), (2 * self.y / screen_size.y), self.z);
    }

    pub fn screen_to_ndc_point(self: Float3, screen_size: Float2) Float3 {
        return float3((2 * self.x / screen_size.x) - 1, (2 * self.y / screen_size.y) - 1, self.z);
    }

    pub fn interpolate(start: Float3, end: Float3, t: f32) Float3 {
        return float3(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t,
                  start.z + (end.z - start.z) * t);
    }

    pub fn mul_f(self: Float3, scalar: f32) Float3 {
        return float3(self.x * scalar, self.y * scalar, self.z * scalar);
    }

    pub fn add(self: Float3, other: Float3) Float3 {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
            .z = self.z + other.z,
        };
    }

    pub fn hermite(t: f32, p1: Float3, s1: Float3, p2: Float3, s2: Float3) Float3 {
        return hermite_generic(Float3, t, p1, s1, p2, s2);
    }

    pub fn default() Float3 {
        return float3(0, 0, 0);
    }

    pub fn magnitude(self: Float3) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fn norm(self: Float3) Float3 {
        const mag = self.magnitude();
        if (mag > 0) {
            return float3(self.x / mag, self.y / mag, self.z / mag);
        }
        return self;
    }
};

pub const Float4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,


    pub inline fn new(x: f32, y: f32, z: f32, w: f32) Float4 {
        return Float4{
            .x = x,
            .y = y,
            .z = z,
            .w = w,
        };
    }

    pub fn hex(str: []const u8) Float4 {
        var hex_str = str;
        if (hex_str[0] == '#') {
            hex_str = hex_str[1..];
        }
        // if (hex_str.len < 6) {
        //     @compileError("Invalid hex color string");
        // }
        return Float4.new(
            (hex_to_decimal(hex_str[0]) * 16.0 + hex_to_decimal(hex_str[1])) / 255.0,
            (hex_to_decimal(hex_str[2]) * 16.0 + hex_to_decimal(hex_str[3])) / 255.0,
            (hex_to_decimal(hex_str[4]) * 16.0 + hex_to_decimal(hex_str[5])) / 255.0,
            1.0,
        );
    }

    pub fn add(self: Float4, other: Float4) Float4 {
        return float4(self.x + other.x, self.y + other.y, self.z + other.z, self.w + other.w);
    }

    pub fn to_hex(self: Float4) [7]u8 {
        var ret = [_]u8{ '#', 0, 0, 0, 0, 0, 0 };
        // ret[1] = (self.x * 255.0)
        const digit12temp = @floor(self.x * 255.0);
        const digit1 = @as(u8, @intFromFloat(@floor(digit12temp / 16.0)));
        const digit2 = @as(u8, @intFromFloat(digit12temp - @as(f32, @floatFromInt(digit1 * 16))));

        const digit34temp = @floor(self.y * 255.0);
        const digit3 = @as(u8, @intFromFloat(@floor(digit34temp / 16.0)));
        const digit4 = @as(u8, @intFromFloat(digit34temp - @as(f32, @floatFromInt(digit3 * 16))));

        const digit56temp = @floor(self.z * 255.0);
        const digit5 = @as(u8, @intFromFloat(@floor(digit56temp / 16.0)));
        const digit6 = @as(u8, @intFromFloat(digit56temp - @as(f32, @floatFromInt(digit5 * 16))));

        ret[1] = decimal_to_hex(digit1);
        ret[2] = decimal_to_hex(digit2);
        ret[3] = decimal_to_hex(digit3);
        ret[4] = decimal_to_hex(digit4);
        ret[5] = decimal_to_hex(digit5);
        ret[6] = decimal_to_hex(digit6);
        return ret;
    }

    pub inline fn dot(a: Float4, b: Float4) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }

    pub inline fn col(self: Float4, comptime col_idx: usize) f32 {
        switch (col_idx) {
            0 => return self.x,
            1 => return self.y,
            2 => return self.z,
            3 => return self.w,
            else => unreachable,
        }
    }
};

pub inline fn float2(x: f32, y: f32) Float2 {
    return .{ .x = x, .y = y };
}

pub inline fn float3(x: f32, y: f32, z: f32) Float3 {
    return .{ .x = x, .y = y, .z = z };
}

pub inline fn float4(x: f32, y: f32, z: f32, w: f32) Float4 {
    return .{ .x = x, .y = y, .z = z, .w = w };
}
pub fn hex4(comptime hex: []const u8) Float4 {
    return comptime Float4.hex(hex);
}

pub const Float4x4 = extern struct {
    // THIS IS COLUMN MAJOR
    _0: Float4,
    _1: Float4,
    _2: Float4,
    _3: Float4,

    pub fn new(_0: Float4, _1: Float4, _2: Float4, _3: Float4) Float4x4 {
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
        const tz = -near / dz;

        return @This().new(float4(2 / dx, 0, 0, 0), float4(0, 2 / dy, 0, 0), float4(0, 0, 1 / dz, 0), // Adjusted the Z-scale term
            float4(tx, ty, tz, 1));
    }

    pub fn scale_by(s: f32) Float4x4 {
        return Float4x4.new(
            Float4.new(s, 0, 0, 0),
            Float4.new(0, s, 0, 0),
            Float4.new(0, 0, s, 0),
            Float4.new(0, 0, 0, 1),
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
            Float4.new(t * x * x + c, t * x * y + z * s, t * x * z - y * s, 0),
            Float4.new(t * x * y - z * s, t * y * y + c, t * y * z + x * s, 0),
            Float4.new(t * x * z + y * s, t * y * z - x * s, t * z * z + c, 0),
            Float4.new(0, 0, 0, 1),
        );
    }

    pub fn translation_by(t: Float3) Float4x4 {
        return Float4x4.new(
            Float4.new(1, 0, 0, 0),
            Float4.new(0, 1, 0, 0),
            Float4.new(0, 0, 1, 0),
            Float4.new(t.x, t.y, t.z, 1),
        );
    }

    pub fn col(self: *const Float4x4, comptime col_idx: usize) *const Float4 {
        switch (col_idx) {
            0 => return &self._0,
            1 => return &self._1,
            2 => return &self._2,
            3 => return &self._3,
            else => unreachable,
        }
    }

    pub fn row(self: *const Float4x4, comptime row_idx: usize) Float4 {
        switch (row_idx) {
            0 => return Float4{
                .x = self.col(0).x,
                .y = self.col(1).x,
                .z = self.col(2).x,
                .w = self.col(3).x,
            },
            1 => return Float4{
                .x = self.col(0).y,
                .y = self.col(1).y,
                .z = self.col(2).y,
                .w = self.col(3).y,
            },
            2 => return Float4{
                .x = self.col(0).z,
                .y = self.col(1).z,
                .z = self.col(2).z,
                .w = self.col(3).z,
            },
            3 => return Float4{
                .x = self.col(0).w,
                .y = self.col(1).w,
                .z = self.col(2).w,
                .w = self.col(3).w,
            },
            else => unreachable,
        }
    }

    pub fn mul(self: *const Float4x4, other: *const Float4x4) Float4x4 {
        return Float4x4.new(
            Float4.new(
                self.col(0).dot(other.row(0)),
                self.col(0).dot(other.row(1)),
                self.col(0).dot(other.row(2)),
                self.col(0).dot(other.row(3)),
            ),
            Float4.new(
                self.col(1).dot(other.row(0)),
                self.col(1).dot(other.row(1)),
                self.col(1).dot(other.row(2)),
                self.col(1).dot(other.row(3)),
            ),
            Float4.new(
                self.col(2).dot(other.row(0)),
                self.col(2).dot(other.row(1)),
                self.col(2).dot(other.row(2)),
                self.col(2).dot(other.row(3)),
            ),
            Float4.new(
                self.col(3).dot(other.row(0)),
                self.col(3).dot(other.row(1)),
                self.col(3).dot(other.row(2)),
                self.col(3).dot(other.row(3)),
            ),
        );
    }

    pub fn mul_f4(self: *Float4x4, vec: Float4) Float4 {
        return Float4.new(
            self.row(0).dot(vec),
            self.row(1).dot(vec),
            self.row(2).dot(vec),
            self.row(3).dot(vec),
        );
    }
};

pub const Quat = struct {
    v: Float4,

    const EPSILON: f32 = 0.000001;

    pub fn mul_f(self: Quat, scalar: f32) Quat {
        return Quat{
            .v = float4(self.v.x * scalar, self.v.y * scalar, self.v.z * scalar, self.v.w * scalar)
        };
    }

    pub fn add(self: Quat, other: Quat) Quat {
        return Quat{
            .v = self.v.add(other.v)
        };
    }

    pub fn dot(self: Quat, other: Quat) Quat {
        return Quat{
            .v = self.v.dot(other.v)
        };
    }

    pub fn norm(self: Quat) Quat {
        const lensq = self.v.x * self.v.x + self.v.y * self.v.y + self.v.z * self.v.z + self.v.w * self.v.w;
        if (lensq < Quat.EPSILON) {
            return self;
        }
        const i_len = 1.0 / @sqrt(lensq);

        self.v.x *= i_len;
        self.v.y *= i_len;
        self.v.z *= i_len;
        self.v.w *= i_len;
        return self;
    }

    pub fn mix(from: Quat, to: Quat, t: f32) Quat {
        return from.mul_f(1.0 - t).add(to.mul_f(t));
    }

    pub fn interpolate(a: Quat, b: Quat, t: f32) Quat {
        var result = Quat.mix(a, b, t);
        if (Quat.dot(a, b) < 0) {
            result = Quat.mix(a, b.mul_f(-1), t);
        }
        result = result.norm();
        return result;
    }

    pub fn hermite(t: f32, p1: Quat, s1: Quat, p2: Quat, s2: Quat) Quat {
        return hermite_generic(Quat, t, p1, s1, p2, s2);
    }

    pub fn default() Quat {
        return .{
            .v = float4(0, 0, 0, 1),
        };
    }
};

fn hermite_generic(comptime T: type, t: f32, p1: T, s1: T, _p2: T, s2: T) T {
    const tt = t * t;
    const ttt = tt * t;
    
    var p2 = _p2;

    const h1 = 2.0 * ttt - 3.0 * tt + 1.0;
    const h2 = -2.0 * ttt + 3.0 * tt;
    const h3 = ttt - 2.0 * tt + t;
    const h4 = ttt - tt;

    //   float result = p1 * h1 + p2 * h2 + s1 * h3 + s2 * h4;
    return p1.mul_f(h1).add(p2.mul_f(h2)).add(s1.mul_f(h3)).add(s2.mul_f(h4));
    // return p1.mul_f(h1).add(p2.mul_f(h2)).add(s1.mul_f(h3).add(s2.mul_f(h4)));
}

fn hex_to_decimal(hex: u8) f32 {
    switch (hex) {
        '0' => return 0.0,
        '1' => return 1.0,
        '2' => return 2.0,
        '3' => return 3.0,
        '4' => return 4.0,
        '5' => return 5.0,
        '6' => return 6.0,
        '7' => return 7.0,
        '8' => return 8.0,
        '9' => return 9.0,
        'A', 'a' => return 10.0,
        'B', 'b' => return 11.0,
        'C', 'c' => return 12.0,
        'D', 'd' => return 13.0,
        'E', 'e' => return 14.0,
        'F', 'f' => return 15.0,
        else => unreachable,
    }
}

fn decimal_to_hex(dec: u8) u8 {
    switch (dec) {
        0 => return '0',
        1 => return '1',
        2 => return '2',
        3 => return '3',
        4 => return '4',
        5 => return '5',
        6 => return '6',
        7 => return '7',
        8 => return '8',
        9 => return '9',
        10 => return 'A',
        11 => return 'B',
        12 => return 'C',
        13 => return 'D',
        14 => return 'E',
        15 => return 'F',
        else => unreachable,
    }
}

test "conversion" {
    const hex_str = "#BB9AF7";
    const color = hex4(hex_str);
    const backToHex = color.to_hex();
    try std.testing.expectEqualStrings(hex_str, &backToHex);
}
