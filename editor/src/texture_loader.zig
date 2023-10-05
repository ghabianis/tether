const std = @import("std");
const objc = @import("zig-objc");
const print = std.debug.print;
const ct = @import("./coretext.zig");
const metal = @import("./metal.zig");

/// Load an MTLTexture from the raw bytes of an image encoded in some image format (png, jpeg, etc.)
/// If you have raw image data (RGBA values for example), use `load_texture_from_cgimage` instead.
pub fn load_texture_from_img_bytes(device: metal.MTLDevice, bytes: []const u8, pixel_fmt: metal.MTLPixelFormat) metal.MTLTexture {
    const cgimage = cgimage_from_bytes(bytes) orelse @panic("Failed to create CGImage from bytes");
    defer ct.CGImageRelease(cgimage);
    return load_texture_from_cgimage(device, cgimage, pixel_fmt);
}

pub fn load_texture_from_cgimage(device: metal.MTLDevice, cgimage: ct.CGImageRef, pixel_fmt: metal.MTLPixelFormat) metal.MTLTexture {
    const width = ct.CGImageGetWidth(cgimage);
    const height = ct.CGImageGetHeight(cgimage);

    const color_space = ct.CGColorSpaceCreateWithName(ct.kCGColorSpaceSRGB);
    defer ct.CGColorSpaceRelease(color_space);

    const ctx = ct.CGBitmapContextCreate(null, width, height, 8, width * 4, color_space, ct.kCGImageAlphaPremultipliedLast);
    defer ct.CGContextRelease(ctx);
    ct.CGContextDrawImage(ctx, metal.CGRect.new(0.0, 0.0, @floatFromInt(width), @floatFromInt(height)), cgimage);
    
    const texture_descriptor = metal.MTLTextureDescriptor.new_2d_with_pixel_format(pixel_fmt, width, height, false);
    const texture = device.new_texture_with_descriptor(texture_descriptor);
    texture.replace_region_with_bytes(metal.MTLRegion2D{
        .origin = .{.x = 0, .y = 0, .z = 0},
        .size = .{ .width = width, .height = height, .depth = 1}
    }, 0, ct.CGBitmapContextGetData(ctx), width * 4);

    return texture;
}

fn cgimage_from_bytes(bytes: []const u8) ?ct.CGImageRef {
    const data = metal.NSData.new_with_bytes_no_copy(bytes, false);
    const image = metal.NSImage.new_with_data(data);
    if (image.obj.value == 0) @panic("Failed to create NSImage from data");
    var rect = metal.CGRect {
        .size = image.size(),
        .origin = metal.CGPoint.default(),
    };
    const cgimage_raw: objc.c.id = image.cgimage_for_proposed_rect(&rect, null, null);
    if (cgimage_raw == 0) @panic("UH OH");
    return cgimage_raw;
}
