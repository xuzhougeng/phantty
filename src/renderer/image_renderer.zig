const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Renderer = @import("Renderer.zig");
const AppWindow = @import("../AppWindow.zig");
const gl_init = AppWindow.gl_init;
const font = AppWindow.font;

const c = @cImport({
    @cInclude("glad/gl.h");
});

const KittyImage = ghostty_vt.kitty.graphics.Image;
const KittyStorage = ghostty_vt.kitty.graphics.ImageStorage;
const KittyUnicode = ghostty_vt.kitty.graphics.unicode;

pub fn snapshot(rend: *Renderer, terminal: *ghostty_vt.Terminal) void {
    const alloc = rend.surface.allocator;
    const storage = &terminal.screens.active.kitty_images;

    for (rend.kitty_pending_uploads.items) |pending| {
        alloc.free(pending.rgba);
    }
    rend.kitty_pending_uploads.clearRetainingCapacity();
    rend.kitty_placements.clearRetainingCapacity();

    if (!storage.enabled()) {
        storage.dirty = false;
        return;
    }

    var top_y: u32 = 0;
    var bot_y: u32 = 0;
    {
        const top = terminal.screens.active.pages.getTopLeft(.viewport);
        const bottom = top.downOverflow(terminal.rows - 1);
        top_y = terminal.screens.active.pages.pointFromPin(.screen, top).?.screen.y;
        bot_y = switch (bottom) {
            .offset => |pin| terminal.screens.active.pages.pointFromPin(.screen, pin).?.screen.y,
            .overflow => |overflow| terminal.screens.active.pages.pointFromPin(.screen, overflow.end).?.screen.y,
        };
    }

    var placements = storage.placements.iterator();
    while (placements.next()) |entry| {
        const placement = entry.value_ptr.*;
        const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
        addPlacementSnapshot(
            alloc,
            rend,
            terminal,
            storage,
            image,
            placement,
            top_y,
            bot_y,
        ) catch {};
    }

    const top = terminal.screens.active.pages.getTopLeft(.viewport);
    const bot = switch (top.downOverflow(terminal.rows - 1)) {
        .offset => |pin| pin,
        .overflow => |overflow| overflow.end,
    };
    var virtual_it = KittyUnicode.placementIterator(top, bot);
    while (virtual_it.next()) |placement| {
        addVirtualPlacementSnapshot(alloc, rend, terminal, storage, placement) catch {};
    }

    std.mem.sortUnstable(
        Renderer.KittyPlacement,
        rend.kitty_placements.items,
        {},
        struct {
            fn lessThan(_: void, lhs: Renderer.KittyPlacement, rhs: Renderer.KittyPlacement) bool {
                return lhs.z < rhs.z or (lhs.z == rhs.z and lhs.image_id < rhs.image_id);
            }
        }.lessThan,
    );

    storage.dirty = false;
}

pub fn uploadPending(rend: *Renderer) void {
    const gl = AppWindow.gl;
    const alloc = rend.surface.allocator;

    for (rend.kitty_pending_uploads.items) |pending| {
        var texture_handle: c.GLuint = 0;
        if (findTexture(rend, pending.image_id)) |existing| {
            texture_handle = existing.texture;
        } else {
            gl.GenTextures.?(1, &texture_handle);
            rend.kitty_textures.append(alloc, .{
                .image_id = pending.image_id,
                .width = pending.width,
                .height = pending.height,
                .transmit_time = pending.transmit_time,
                .texture = texture_handle,
            }) catch {
                gl.DeleteTextures.?(1, &texture_handle);
                alloc.free(pending.rgba);
                continue;
            };
        }

        gl.BindTexture.?(c.GL_TEXTURE_2D, texture_handle);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, 1);
        gl.TexImage2D.?(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA8,
            @intCast(pending.width),
            @intCast(pending.height),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            pending.rgba.ptr,
        );

        if (findTextureMut(rend, pending.image_id)) |tex| {
            tex.width = pending.width;
            tex.height = pending.height;
            tex.transmit_time = pending.transmit_time;
            tex.texture = texture_handle;
        }

        alloc.free(pending.rgba);
    }

    rend.kitty_pending_uploads.clearRetainingCapacity();
}

pub fn draw(
    rend: *const Renderer,
    window_height: f32,
    offset_x: f32,
    offset_y: f32,
    layer: Renderer.KittyLayer,
) void {
    const gl = AppWindow.gl;
    if (gl_init.simple_color_shader == 0) return;

    gl.UseProgram.?(gl_init.simple_color_shader);
    gl_init.setProjectionForProgram(gl_init.simple_color_shader, window_height);
    gl.Uniform1f.?(gl.GetUniformLocation.?(gl_init.simple_color_shader, "opacity"), 1.0);

    for (rend.kitty_placements.items) |placement| {
        if (placement.layer != layer) continue;
        const texture = findTextureConst(rend, placement.image_id) orelse continue;

        const x = offset_x + @as(f32, @floatFromInt(placement.grid_col)) * font.cell_width + placement.offset_x;
        const y = window_height -
            offset_y -
            @as(f32, @floatFromInt(placement.grid_row)) * font.cell_height -
            placement.offset_y -
            placement.height;

        const vertices = [6][4]f32{
            .{ x, y + placement.height, placement.uv_left, placement.uv_top },
            .{ x, y, placement.uv_left, placement.uv_bottom },
            .{ x + placement.width, y, placement.uv_right, placement.uv_bottom },
            .{ x, y + placement.height, placement.uv_left, placement.uv_top },
            .{ x + placement.width, y, placement.uv_right, placement.uv_bottom },
            .{ x + placement.width, y + placement.height, placement.uv_right, placement.uv_top },
        };

        gl.BindTexture.?(c.GL_TEXTURE_2D, texture.texture);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, gl_init.vbo);
        gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
        gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
        gl_init.g_draw_call_count += 1;
    }
}

fn addPlacementSnapshot(
    alloc: std.mem.Allocator,
    rend: *Renderer,
    terminal: *ghostty_vt.Terminal,
    storage: *const KittyStorage,
    image: KittyImage,
    placement: KittyStorage.Placement,
    top_y: u32,
    bot_y: u32,
) !void {
    _ = storage;
    const rect = placement.rect(image, terminal) orelse return;
    const img_top_y = terminal.screens.active.pages.pointFromPin(.screen, rect.top_left).?.screen.y;
    const img_bot_y = terminal.screens.active.pages.pointFromPin(.screen, rect.bottom_right).?.screen.y;
    if (img_top_y > bot_y or img_bot_y < top_y) return;

    try ensurePendingTexture(alloc, rend, image);

    const dest_size = placement.pixelSize(image, terminal);
    if (dest_size.width == 0 or dest_size.height == 0) return;

    const source_x = @min(image.width, placement.source_x);
    const source_y = @min(image.height, placement.source_y);
    const source_width = if (placement.source_width > 0)
        @min(image.width - source_x, placement.source_width)
    else
        image.width - source_x;
    const source_height = if (placement.source_height > 0)
        @min(image.height - source_y, placement.source_height)
    else
        image.height - source_y;
    if (source_width == 0 or source_height == 0) return;

    const y_pos: i32 = @intCast(@as(i32, @intCast(img_top_y)) - @as(i32, @intCast(top_y)));
    try rend.kitty_placements.append(alloc, .{
        .image_id = image.id,
        .grid_col = @intCast(rect.top_left.x),
        .grid_row = y_pos,
        .offset_x = @floatFromInt(placement.x_offset),
        .offset_y = @floatFromInt(placement.y_offset),
        .width = @floatFromInt(dest_size.width),
        .height = @floatFromInt(dest_size.height),
        .uv_left = @as(f32, @floatFromInt(source_x)) / @as(f32, @floatFromInt(image.width)),
        .uv_top = @as(f32, @floatFromInt(source_y)) / @as(f32, @floatFromInt(image.height)),
        .uv_right = @as(f32, @floatFromInt(source_x + source_width)) / @as(f32, @floatFromInt(image.width)),
        .uv_bottom = @as(f32, @floatFromInt(source_y + source_height)) / @as(f32, @floatFromInt(image.height)),
        .z = placement.z,
        .layer = if (placement.z < std.math.minInt(i32) / 2)
            .below_bg
        else if (placement.z < 0)
            .below_text
        else
            .above_text,
    });
}

fn addVirtualPlacementSnapshot(
    alloc: std.mem.Allocator,
    rend: *Renderer,
    terminal: *ghostty_vt.Terminal,
    storage: *const KittyStorage,
    placement: KittyUnicode.Placement,
) !void {
    const image = storage.imageById(placement.image_id) orelse return;
    const rp = placement.renderPlacement(
        storage,
        &image,
        @intFromFloat(font.cell_width),
        @intFromFloat(font.cell_height),
    ) catch return;
    if (rp.dest_width == 0 or rp.dest_height == 0) return;

    try ensurePendingTexture(alloc, rend, image);

    const viewport = terminal.screens.active.pages.pointFromPin(.viewport, rp.top_left) orelse return;
    try rend.kitty_placements.append(alloc, .{
        .image_id = image.id,
        .grid_col = @intCast(rp.top_left.x),
        .grid_row = @intCast(viewport.viewport.y),
        .offset_x = @floatFromInt(rp.offset_x),
        .offset_y = @floatFromInt(rp.offset_y),
        .width = @floatFromInt(rp.dest_width),
        .height = @floatFromInt(rp.dest_height),
        .uv_left = @as(f32, @floatFromInt(rp.source_x)) / @as(f32, @floatFromInt(image.width)),
        .uv_top = @as(f32, @floatFromInt(rp.source_y)) / @as(f32, @floatFromInt(image.height)),
        .uv_right = @as(f32, @floatFromInt(rp.source_x + rp.source_width)) / @as(f32, @floatFromInt(image.width)),
        .uv_bottom = @as(f32, @floatFromInt(rp.source_y + rp.source_height)) / @as(f32, @floatFromInt(image.height)),
        .z = -1,
        .layer = .below_text,
    });
}

fn ensurePendingTexture(
    alloc: std.mem.Allocator,
    rend: *Renderer,
    image: KittyImage,
) !void {
    if (findPendingUpload(rend, image.id) != null) return;
    if (findTexture(rend, image.id)) |existing| {
        if (existing.transmit_time.order(image.transmit_time) == .eq) return;
    }

    const rgba = try convertToRgba(alloc, image);
    try rend.kitty_pending_uploads.append(alloc, .{
        .image_id = image.id,
        .width = image.width,
        .height = image.height,
        .transmit_time = image.transmit_time,
        .rgba = rgba,
    });
}

fn convertToRgba(alloc: std.mem.Allocator, image: KittyImage) ![]u8 {
    const pixel_count = std.math.mul(usize, image.width, image.height) catch return error.OutOfMemory;
    const rgba = try alloc.alloc(u8, std.math.mul(usize, pixel_count, 4) catch return error.OutOfMemory);

    switch (image.format) {
        .rgba => @memcpy(rgba, image.data[0..rgba.len]),
        .rgb => {
            for (0..pixel_count) |i| {
                const src = i * 3;
                const dst = i * 4;
                rgba[dst + 0] = image.data[src + 0];
                rgba[dst + 1] = image.data[src + 1];
                rgba[dst + 2] = image.data[src + 2];
                rgba[dst + 3] = 255;
            }
        },
        .gray => {
            for (0..pixel_count) |i| {
                const dst = i * 4;
                const v = image.data[i];
                rgba[dst + 0] = v;
                rgba[dst + 1] = v;
                rgba[dst + 2] = v;
                rgba[dst + 3] = 255;
            }
        },
        .gray_alpha => {
            for (0..pixel_count) |i| {
                const src = i * 2;
                const dst = i * 4;
                const v = image.data[src + 0];
                rgba[dst + 0] = v;
                rgba[dst + 1] = v;
                rgba[dst + 2] = v;
                rgba[dst + 3] = image.data[src + 1];
            }
        },
        .png => return error.InvalidData,
    }

    return rgba;
}

fn findTexture(rend: *Renderer, image_id: u32) ?Renderer.KittyTexture {
    for (rend.kitty_textures.items) |tex| {
        if (tex.image_id == image_id) return tex;
    }
    return null;
}

fn findTextureConst(rend: *const Renderer, image_id: u32) ?Renderer.KittyTexture {
    for (rend.kitty_textures.items) |tex| {
        if (tex.image_id == image_id) return tex;
    }
    return null;
}

fn findTextureMut(rend: *Renderer, image_id: u32) ?*Renderer.KittyTexture {
    for (rend.kitty_textures.items) |*tex| {
        if (tex.image_id == image_id) return tex;
    }
    return null;
}

fn findPendingUpload(rend: *Renderer, image_id: u32) ?Renderer.KittyPendingUpload {
    for (rend.kitty_pending_uploads.items) |pending| {
        if (pending.image_id == image_id) return pending;
    }
    return null;
}
