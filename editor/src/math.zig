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
        const tz = (far + near) / dz;

        return @This().new(float4(2 / dx, 0, 0, 0), float4(0, 2 / dy, 0, 0), float4(0, 0, 2 / dz, 0), float4(tx, ty, tz, 1));
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

    pub fn row(self: *Float4x4, comptime row_idx: usize) *Float4 {
        switch (row_idx) {
            0 => return &self._0,
            1 => return &self._1,
            2 => return &self._2,
            3 => return &self._3,
            else => unreachable,
        }
    }

    pub fn col(self: *Float4x4, comptime col_idx: usize) Float4 {
        return Float4{
            .x = self.row(0).col(col_idx),
            .y = self.row(1).col(col_idx),
            .z = self.row(2).col(col_idx),
            .w = self.row(3).col(col_idx),
        };
    }

    pub fn mul(self: *Float4x4, other: *Float4x4) Float4x4 {
        return Float4x4.new(
            Float4.new(
                self.row(0).dot(other.col(0)),
                self.row(0).dot(other.col(1)),
                self.row(0).dot(other.col(2)),
                self.row(0).dot(other.col(3)),
            ),
            Float4.new(
                self.row(1).dot(other.col(0)),
                self.row(1).dot(other.col(1)),
                self.row(1).dot(other.col(2)),
                self.row(1).dot(other.col(3)),
            ),
            Float4.new(
                self.row(2).dot(other.col(0)),
                self.row(2).dot(other.col(1)),
                self.row(2).dot(other.col(2)),
                self.row(2).dot(other.col(3)),
            ),
            Float4.new(
                self.row(3).dot(other.col(0)),
                self.row(3).dot(other.col(1)),
                self.row(3).dot(other.col(2)),
                self.row(3).dot(other.col(3)),
            ),
        );
    }
};

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
