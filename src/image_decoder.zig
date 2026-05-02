const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub fn install() void {
    ghostty_vt.sys.decode_png = &decodePng;
}

fn decodePng(
    alloc: std.mem.Allocator,
    data: []const u8,
) ghostty_vt.sys.DecodeError!ghostty_vt.sys.Image {
    const len = std.math.cast(c_int, data.len) orelse return error.InvalidData;

    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const decoded = c.stbi_load_from_memory(
        data.ptr,
        len,
        &width,
        &height,
        &channels,
        4,
    ) orelse return error.InvalidData;
    defer c.stbi_image_free(decoded);

    if (width <= 0 or height <= 0) return error.InvalidData;

    const width_u32: u32 = @intCast(width);
    const height_u32: u32 = @intCast(height);
    const pixel_count = std.math.mul(usize, width_u32, height_u32) catch return error.InvalidData;
    const byte_len = std.math.mul(usize, pixel_count, 4) catch return error.InvalidData;

    const rgba = try alloc.alloc(u8, byte_len);
    @memcpy(rgba, @as([*]const u8, @ptrCast(decoded))[0..byte_len]);

    return .{
        .width = width_u32,
        .height = height_u32,
        .data = rgba,
    };
}
