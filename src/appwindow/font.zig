//! Font loading, glyph caching, and atlas management for AppWindow.
//!
//! Owns all font state: FreeType faces, glyph caches, font atlases,
//! HarfBuzz shaping, fallback font discovery, and cell metrics.
//! Uses AppWindow's GL context for GPU texture operations.

const std = @import("std");
const freetype = @import("freetype");
const harfbuzz = @import("harfbuzz");
const sprite = @import("../font/sprite.zig");
const directwrite = @import("../directwrite.zig");
const embedded = @import("../font/embedded.zig");
const Config = @import("../config.zig");
const AppWindow = @import("../AppWindow.zig");

const c = @cImport({
    @cInclude("glad/gl.h");
});

pub const FontAtlas = @import("../font/Atlas.zig");

const Theme = Config.Theme;

// ============================================================================
// Types
// ============================================================================

pub const Character = struct {
    // Atlas region (UV coordinates derived from this + atlas size)
    region: FontAtlas.Region,
    size_x: i32,
    size_y: i32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i64,
    valid: bool = false,
    is_color: bool = false, // true if stored in BGRA color atlas (emoji)
};

pub const GlyphUV = struct { u0: f32, v0: f32, u1: f32, v1: f32 };

/// Cached bell emoji glyph (loaded once from color emoji font)
pub const BellCache = struct {
    region: FontAtlas.Region,
    bmp_w: f32,
    bmp_h: f32,
};

// ============================================================================
// Constants
// ============================================================================

pub const DEFAULT_FONT_SIZE: u32 = 14;
pub const MAX_GRAPHEME: usize = 8; // Max codepoints per grapheme cluster (covers flags, ZWJ sequences, etc.)

// ============================================================================
// Globals — threadlocal font state
// ============================================================================

// Cell dimensions (set by preloadCharacters from font metrics)
pub threadlocal var cell_width: f32 = 10;
pub threadlocal var cell_height: f32 = 20;
pub threadlocal var cell_baseline: f32 = 4; // Distance from bottom of cell to baseline
pub threadlocal var cursor_height: f32 = 16; // Height of cursor (ascender portion)
pub threadlocal var box_thickness: u32 = 1; // Thickness for box drawing characters

// Glyph cache using a hashmap for Unicode support
pub threadlocal var glyph_cache: std.AutoHashMapUnmanaged(u32, Character) = .empty;
// Grapheme cluster cache — keyed by hash of full codepoint sequence
pub threadlocal var grapheme_cache: std.AutoHashMapUnmanaged(u64, Character) = .empty;
pub threadlocal var glyph_face: ?freetype.Face = null;
pub threadlocal var icon_face: ?freetype.Face = null; // Segoe MDL2 Assets for caption button icons
pub threadlocal var icon_cache: std.AutoHashMapUnmanaged(u32, Character) = .empty;

// Font atlas — single texture for all glyphs (replaces per-glyph textures)
pub threadlocal var g_atlas: ?FontAtlas = null;
pub threadlocal var g_atlas_texture: c.GLuint = 0;
pub threadlocal var g_atlas_modified: usize = 0; // Last synced modified counter

// Color atlas — BGRA texture for color emoji (like Ghostty's separate color atlas)
pub threadlocal var g_color_atlas: ?FontAtlas = null;
pub threadlocal var g_color_atlas_texture: c.GLuint = 0;
pub threadlocal var g_color_atlas_modified: usize = 0;

// Icon atlas — separate atlas for caption button icons (Segoe MDL2)
pub threadlocal var g_icon_atlas: ?FontAtlas = null;
pub threadlocal var g_icon_atlas_texture: c.GLuint = 0;
pub threadlocal var g_icon_atlas_modified: usize = 0;

// Titlebar font — separate face/cache/atlas at fixed 14pt for crisp titlebar text.
// Avoids scaling artifacts from rendering terminal-size glyphs at a smaller size.
pub threadlocal var g_titlebar_face: ?freetype.Face = null;
pub threadlocal var g_titlebar_cache: std.AutoHashMapUnmanaged(u32, Character) = .empty;
pub threadlocal var g_titlebar_atlas: ?FontAtlas = null;
pub threadlocal var g_titlebar_atlas_texture: c.GLuint = 0;
pub threadlocal var g_titlebar_atlas_modified: usize = 0;
pub threadlocal var g_titlebar_cell_width: f32 = 8;
pub threadlocal var g_titlebar_cell_height: f32 = 14;
pub threadlocal var g_titlebar_baseline: f32 = 3;

// Font fallback system
pub threadlocal var g_ft_lib: ?freetype.Library = null;
pub threadlocal var g_font_discovery: ?*directwrite.FontDiscovery = null;
pub threadlocal var g_fallback_faces: std.AutoHashMapUnmanaged(u32, freetype.Face) = .empty; // codepoint -> fallback face
pub threadlocal var g_no_fallback: std.AutoHashMapUnmanaged(u32, void) = .empty; // codepoints with no fallback (negative cache)
pub threadlocal var g_font_size: u32 = DEFAULT_FONT_SIZE;

// HarfBuzz shaping state
pub threadlocal var g_hb_buf: ?harfbuzz.Buffer = null;
pub threadlocal var g_hb_font: ?harfbuzz.Font = null; // HB font for primary face
pub threadlocal var g_hb_fallback_fonts: std.AutoHashMapUnmanaged(u32, harfbuzz.Font) = .empty; // codepoint -> HB font for fallback faces

// Bell emoji
pub threadlocal var g_bell_cache: ?BellCache = null;
pub threadlocal var g_bell_emoji_face: ?freetype.Face = null;

// ============================================================================
// Helper functions
// ============================================================================

/// Convert FreeType 26.6 fixed-point to f64 (like Ghostty)
fn f26dot6ToF64(v: anytype) f64 {
    return @as(f64, @floatFromInt(v)) / 64.0;
}

/// Returns true if the codepoint is a Regional Indicator Symbol (used for flag emoji).
pub fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// Hash a grapheme cluster (base codepoint + extra codepoints) for cache lookup.
pub fn graphemeHash(base_cp: u21, extra: []const u21) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&base_cp));
    for (extra) |cp| {
        h.update(std.mem.asBytes(&cp));
    }
    return h.final();
}

/// Compute UV coordinates from an atlas region and atlas size.
pub fn glyphUV(region: FontAtlas.Region, atlas_size: f32) GlyphUV {
    return .{
        .u0 = @as(f32, @floatFromInt(region.x)) / atlas_size,
        .v0 = @as(f32, @floatFromInt(region.y)) / atlas_size,
        .u1 = @as(f32, @floatFromInt(region.x + region.width)) / atlas_size,
        .v1 = @as(f32, @floatFromInt(region.y + region.height)) / atlas_size,
    };
}

pub fn getGlyphInfo(codepoint: u32) ?Character {
    return glyph_cache.get(codepoint);
}

pub fn indexToRgb(color_idx: u8) [3]f32 {
    // Use theme palette for colors 0-15
    if (color_idx < 16) {
        return AppWindow.g_theme.palette[color_idx];
    } else if (color_idx < 232) {
        // 216 color cube (6x6x6): indices 16-231
        const idx = color_idx - 16;
        const r = idx / 36;
        const g = (idx / 6) % 6;
        const b = idx % 6;
        return .{
            if (r == 0) 0.0 else (@as(f32, @floatFromInt(r)) * 40.0 + 55.0) / 255.0,
            if (g == 0) 0.0 else (@as(f32, @floatFromInt(g)) * 40.0 + 55.0) / 255.0,
            if (b == 0) 0.0 else (@as(f32, @floatFromInt(b)) * 40.0 + 55.0) / 255.0,
        };
    } else {
        // Grayscale: indices 232-255 (24 shades)
        const gray = (@as(f32, @floatFromInt(color_idx - 232)) * 10.0 + 8.0) / 255.0;
        return .{ gray, gray, gray };
    }
}

// ============================================================================
// Atlas management
// ============================================================================

/// Pack a bitmap into an atlas (growing if necessary), returning the region.
/// `src_buffer` may be null for zero-size bitmaps (returns a zero-size region).
/// `src_pitch` is the stride of the source bitmap in bytes (may differ from width).
pub fn packBitmapIntoAtlas(
    atlas_ptr: *?FontAtlas,
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    src_buffer: ?[*]const u8,
    src_pitch: u32,
) ?FontAtlas.Region {
    // Zero-size glyph (e.g., space) — return a trivial region
    if (width == 0 or height == 0) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    // Ensure atlas exists
    if (atlas_ptr.* == null) {
        atlas_ptr.* = FontAtlas.init(alloc, 512, .grayscale) catch return null;
    }
    var atlas = &atlas_ptr.*.?;

    // Copy source bitmap to tightly-packed buffer (FreeType pitch may != width)
    const tight = alloc.alloc(u8, width * height) catch return null;
    defer alloc.free(tight);
    const src = src_buffer orelse return null;
    for (0..height) |row| {
        const src_offset = row * src_pitch;
        const dst_offset = row * width;
        @memcpy(tight[dst_offset..][0..width], src[src_offset..][0..width]);
    }

    // Try to reserve space; grow atlas if full (up to reasonable max)
    var region = atlas.reserve(alloc, width, height) catch |err| switch (err) {
        error.AtlasFull => blk: {
            const new_size = atlas.size * 2;
            if (new_size > 8192) return null; // Safety cap
            std.debug.print("Atlas full ({0}x{0}), growing to {1}x{1}\n", .{ atlas.size, new_size });
            atlas.grow(alloc, new_size) catch return null;
            break :blk atlas.reserve(alloc, width, height) catch return null;
        },
        else => return null,
    };

    // Copy pixels into atlas
    atlas.set(region, tight);

    // Ensure region dimensions match what we asked for
    region.width = width;
    region.height = height;

    return region;
}

/// Pack a tightly-packed pixel buffer into an atlas (no pitch conversion needed).
pub fn packPixelsIntoAtlas(
    atlas_ptr: *?FontAtlas,
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []const u8,
) ?FontAtlas.Region {
    if (width == 0 or height == 0) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    if (atlas_ptr.* == null) {
        atlas_ptr.* = FontAtlas.init(alloc, 512, .grayscale) catch return null;
    }
    var atlas = &atlas_ptr.*.?;

    var region = atlas.reserve(alloc, width, height) catch |err| switch (err) {
        error.AtlasFull => blk: {
            const new_size = atlas.size * 2;
            if (new_size > 8192) return null;
            std.debug.print("Atlas full ({0}x{0}), growing to {1}x{1}\n", .{ atlas.size, new_size });
            atlas.grow(alloc, new_size) catch return null;
            break :blk atlas.reserve(alloc, width, height) catch return null;
        },
        else => return null,
    };

    atlas.set(region, pixels);
    region.width = width;
    region.height = height;

    return region;
}

/// Pack a BGRA color bitmap into the color emoji atlas.
/// Handles pitch != width*4 (FreeType BGRA bitmaps may have padding).
pub fn packColorBitmapIntoAtlas(
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    src_buffer: ?[*]const u8,
    src_pitch: u32,
) ?FontAtlas.Region {
    if (width == 0 or height == 0) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    if (g_color_atlas == null) {
        g_color_atlas = FontAtlas.init(alloc, 512, .bgra) catch return null;
    }
    var atlas = &g_color_atlas.?;

    // Copy source bitmap to tightly-packed BGRA buffer
    const depth: u32 = 4; // BGRA
    const tight = alloc.alloc(u8, width * height * depth) catch return null;
    defer alloc.free(tight);
    const src = src_buffer orelse return null;
    for (0..height) |row| {
        const src_offset = row * src_pitch;
        const dst_offset = row * width * depth;
        @memcpy(tight[dst_offset..][0..width * depth], src[src_offset..][0..width * depth]);
    }

    var region = atlas.reserve(alloc, width, height) catch |err| switch (err) {
        error.AtlasFull => blk: {
            const new_size = atlas.size * 2;
            if (new_size > 8192) return null;
            std.debug.print("Color atlas full ({0}x{0}), growing to {1}x{1}\n", .{ atlas.size, new_size });
            atlas.grow(alloc, new_size) catch return null;
            break :blk atlas.reserve(alloc, width, height) catch return null;
        },
        else => return null,
    };

    atlas.set(region, tight);
    region.width = width;
    region.height = height;

    return region;
}

/// Sync the font atlas CPU data to the GPU texture.
/// Called once per frame before rendering. Only uploads if the atlas was modified.
/// Supports both grayscale (GL_RED) and BGRA (GL_RGBA) atlas formats.
pub fn syncAtlasTexture(atlas_ptr: *?FontAtlas, texture_ptr: *c.GLuint, modified_ptr: *usize) void {
    const atlas = atlas_ptr.*.?;
    const modified = atlas.modified.load(.monotonic);
    if (modified <= modified_ptr.*) return;

    const gl = &AppWindow.gl;
    const size: c_int = @intCast(atlas.size);

    // Pick GL format based on atlas pixel format.
    // FreeType color emoji bitmaps are BGRA byte order, so we upload with GL_BGRA
    // which tells OpenGL to swizzle B↔R on upload, giving us proper RGBA in the texture.
    const gl_internal: c.GLint = if (atlas.format == .bgra) c.GL_RGBA8 else c.GL_RED;
    const gl_format: c.GLenum = if (atlas.format == .bgra) c.GL_BGRA else c.GL_RED;

    if (texture_ptr.* == 0) {
        // First time — create the texture
        gl.GenTextures.?(1, texture_ptr);
        gl.BindTexture.?(c.GL_TEXTURE_2D, texture_ptr.*);
        gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, gl_internal, size, size, 0, gl_format, c.GL_UNSIGNED_BYTE, atlas.data.ptr);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    } else {
        gl.BindTexture.?(c.GL_TEXTURE_2D, texture_ptr.*);
        // Check if atlas grew beyond current GPU texture size
        var current_size: c.GLint = 0;
        gl.GetTexLevelParameteriv.?(c.GL_TEXTURE_2D, 0, c.GL_TEXTURE_WIDTH, &current_size);
        if (current_size < size) {
            // Atlas grew — need a new texture
            gl.DeleteTextures.?(1, texture_ptr);
            gl.GenTextures.?(1, texture_ptr);
            gl.BindTexture.?(c.GL_TEXTURE_2D, texture_ptr.*);
            gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, gl_internal, size, size, 0, gl_format, c.GL_UNSIGNED_BYTE, atlas.data.ptr);
            gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        } else {
            // Same size — sub-image upload
            gl.TexSubImage2D.?(c.GL_TEXTURE_2D, 0, 0, 0, size, size, gl_format, c.GL_UNSIGNED_BYTE, atlas.data.ptr);
        }
    }

    modified_ptr.* = modified;
}

// ============================================================================
// Glyph loading
// ============================================================================

pub fn loadGlyph(codepoint: u32) ?Character {
    // Check if already cached
    if (glyph_cache.get(codepoint)) |ch| {
        return ch;
    }

    const alloc = AppWindow.g_allocator orelse return null;

    // Try sprite rendering first for special characters
    if (sprite.isSprite(codepoint)) {
        if (loadSpriteGlyph(codepoint, alloc)) |char_data| {
            glyph_cache.put(alloc, codepoint, char_data) catch return null;
            return char_data;
        }
    }

    // Fall back to FreeType font rendering
    const primary_face = glyph_face orelse return null;

    // Get glyph index for this codepoint from primary font
    var glyph_index = primary_face.getCharIndex(codepoint) orelse 0;
    var face_to_use = primary_face;

    // If glyph is missing (index 0), try to find a fallback font
    if (glyph_index == 0) {
        if (findOrLoadFallbackFace(codepoint, alloc)) |fallback| {
            const fallback_index = fallback.getCharIndex(codepoint) orelse 0;
            if (fallback_index != 0) {
                glyph_index = fallback_index;
                face_to_use = fallback;
            }
        }
    }

    // If still no glyph found, don't render the .notdef tofu box
    if (glyph_index == 0) return null;

    // Detect if this face has color glyphs (emoji fonts like Segoe UI Emoji, Noto Color Emoji).
    // Like Ghostty, we set FT_LOAD_COLOR so FreeType renders BGRA bitmaps for color glyphs.
    const is_color_face = face_to_use.hasColor();
    face_to_use.loadGlyph(@intCast(glyph_index), .{
        .target = .light,
        .color = is_color_face,
    }) catch return null;
    face_to_use.renderGlyph(.light) catch return null;

    const glyph = face_to_use.handle.*.glyph;
    const bitmap = glyph.*.bitmap;

    // Check if this glyph actually rendered as BGRA (color emoji)
    const is_color_glyph = bitmap.pixel_mode == freetype.c.FT_PIXEL_MODE_BGRA;

    if (is_color_glyph) {
        // Color emoji — pack into BGRA atlas
        const region = packColorBitmapIntoAtlas(
            alloc,
            bitmap.width,
            bitmap.rows,
            bitmap.buffer,
            @intCast(@as(c_uint, @intCast(@abs(bitmap.pitch)))),
        ) orelse return null;

        // Scale color emoji to fit cell height (like Ghostty's constraint system)
        // Color emoji bitmaps are often much larger than the cell, so we record
        // the original bitmap size and let the renderer scale them.
        const char_data = Character{
            .region = region,
            .size_x = @intCast(bitmap.width),
            .size_y = @intCast(bitmap.rows),
            .bearing_x = glyph.*.bitmap_left,
            .bearing_y = glyph.*.bitmap_top,
            .advance = glyph.*.advance.x,
            .valid = true,
            .is_color = true,
        };

        glyph_cache.put(alloc, codepoint, char_data) catch return null;
        return char_data;
    }

    // Grayscale glyph — pack into grayscale atlas
    const region = packBitmapIntoAtlas(
        &g_atlas,
        alloc,
        bitmap.width,
        bitmap.rows,
        bitmap.buffer,
        @intCast(bitmap.pitch),
    ) orelse return null;

    const char_data = Character{
        .region = region,
        .size_x = @intCast(bitmap.width),
        .size_y = @intCast(bitmap.rows),
        .bearing_x = glyph.*.bitmap_left,
        .bearing_y = glyph.*.bitmap_top,
        .advance = glyph.*.advance.x,
        .valid = true,
    };

    // Store in cache
    glyph_cache.put(alloc, codepoint, char_data) catch return null;

    return char_data;
}

/// Load a glyph for a grapheme cluster (multi-codepoint emoji) using HarfBuzz shaping.
/// The cluster is: base_cp followed by extra_cps[0..extra_len].
/// HarfBuzz shapes the sequence into the correct glyph (flags, skin tones, ZWJ, VS16, etc.)
pub fn loadGraphemeGlyph(base_cp: u21, extra_cps: []const u21) ?Character {
    const hash = graphemeHash(base_cp, extra_cps);


    // Check grapheme cache first
    if (grapheme_cache.get(hash)) |ch| {
        return ch;
    }

    const alloc = AppWindow.g_allocator orelse {
        return null;
    };
    var hb_buf = g_hb_buf orelse {
        return null;
    };

    // Build the full codepoint sequence: base + extras
    var codepoints: [1 + MAX_GRAPHEME]u32 = undefined;
    codepoints[0] = @intCast(base_cp);
    for (extra_cps, 0..) |cp, i| {
        codepoints[1 + i] = @intCast(cp);
    }
    const total_len = 1 + extra_cps.len;

    // Try primary face first, then fallback
    const primary_face = glyph_face orelse return null;
    var face_to_use = primary_face;
    var hb_font = g_hb_font orelse return null;

    // For multi-codepoint grapheme clusters (emoji sequences), we try the fallback
    // font (typically an emoji font like Segoe UI Emoji) FIRST, because the primary
    // monospace font will shape regional indicators / skin tones as separate glyphs
    // (not composed), and we'd never fall back. The emoji font has GSUB ligatures
    // that compose these sequences into single glyphs.
    var glyph_infos: []harfbuzz.GlyphInfo = &.{};
    var tried_fallback = false;

    if (findOrLoadFallbackFace(@intCast(base_cp), alloc)) |fallback_face| {
        if (fallback_face.hasColor()) {
            // Emoji/color font — try this first for grapheme clusters
            const fb_hb_font = g_hb_fallback_fonts.get(@intCast(base_cp)) orelse blk: {
                const new_hb = harfbuzz.freetype.createFont(fallback_face.handle) catch null;
                if (new_hb) |hf| {
                    g_hb_fallback_fonts.put(alloc, @intCast(base_cp), hf) catch {
                        var f = hf;
                        f.destroy();
                        break :blk null;
                    };
                    break :blk hf;
                }
                break :blk null;
            };

            if (fb_hb_font) |fb_font| {
                hb_buf.reset();
                hb_buf.addCodepoints(codepoints[0..total_len]);
                hb_buf.guessSegmentProperties();
                harfbuzz.shape(fb_font, hb_buf, &.{});

                glyph_infos = hb_buf.getGlyphInfos();
                tried_fallback = true;

                // Check if the emoji font successfully composed the sequence
                // (produced a non-.notdef glyph)
                if (glyph_infos.len > 0 and glyph_infos[0].codepoint != 0) {
                    face_to_use = fallback_face;
                    hb_font = fb_font;
                } else {
                    // Emoji font didn't help, will try primary below
                    glyph_infos = &.{};
                }
            }
        }
    } else {}

    // If fallback didn't produce a result, try primary font
    if (glyph_infos.len == 0) {
        hb_buf.reset();
        hb_buf.addCodepoints(codepoints[0..total_len]);
        hb_buf.guessSegmentProperties();
        harfbuzz.shape(hb_font, hb_buf, &.{});
        glyph_infos = hb_buf.getGlyphInfos();

        // If primary also failed, try non-color fallback
        if (!tried_fallback and (glyph_infos.len == 0 or glyph_infos[0].codepoint == 0)) {
            if (findOrLoadFallbackFace(@intCast(base_cp), alloc)) |fallback_face| {
                const fb_hb_font = g_hb_fallback_fonts.get(@intCast(base_cp)) orelse blk: {
                    const new_hb = harfbuzz.freetype.createFont(fallback_face.handle) catch null;
                    if (new_hb) |hf| {
                        g_hb_fallback_fonts.put(alloc, @intCast(base_cp), hf) catch {
                            var f = hf;
                            f.destroy();
                            break :blk null;
                        };
                        break :blk hf;
                    }
                    break :blk null;
                };

                if (fb_hb_font) |fb_font| {
                    hb_buf.reset();
                    hb_buf.addCodepoints(codepoints[0..total_len]);
                    hb_buf.guessSegmentProperties();
                    harfbuzz.shape(fb_font, hb_buf, &.{});

                    glyph_infos = hb_buf.getGlyphInfos();
                    if (glyph_infos.len > 0 and glyph_infos[0].codepoint != 0) {
                        face_to_use = fallback_face;
                        hb_font = fb_font;
                    }
                }
            }
        }
    }

    if (glyph_infos.len == 0 or glyph_infos[0].codepoint == 0) {
        return null;
    }

    // Use the first shaped glyph (HarfBuzz composes the sequence into one glyph for emoji)
    const shaped_glyph_index = glyph_infos[0].codepoint;

    // Render the glyph via FreeType using the glyph index from HarfBuzz
    const is_color_face = face_to_use.hasColor();
    face_to_use.loadGlyph(@intCast(shaped_glyph_index), .{
        .target = .light,
        .color = is_color_face,
    }) catch return null;
    face_to_use.renderGlyph(.light) catch return null;

    const glyph = face_to_use.handle.*.glyph;
    const bitmap = glyph.*.bitmap;

    const is_color_glyph = bitmap.pixel_mode == freetype.c.FT_PIXEL_MODE_BGRA;

    if (is_color_glyph) {
        const region = packColorBitmapIntoAtlas(
            alloc,
            bitmap.width,
            bitmap.rows,
            bitmap.buffer,
            @intCast(@as(c_uint, @intCast(@abs(bitmap.pitch)))),
        ) orelse return null;

        const char_data = Character{
            .region = region,
            .size_x = @intCast(bitmap.width),
            .size_y = @intCast(bitmap.rows),
            .bearing_x = glyph.*.bitmap_left,
            .bearing_y = glyph.*.bitmap_top,
            .advance = glyph.*.advance.x,
            .valid = true,
            .is_color = true,
        };
        grapheme_cache.put(alloc, hash, char_data) catch return null;
        return char_data;
    }

    // Grayscale glyph
    const region = packBitmapIntoAtlas(
        &g_atlas,
        alloc,
        bitmap.width,
        bitmap.rows,
        bitmap.buffer,
        @intCast(bitmap.pitch),
    ) orelse return null;

    const char_data = Character{
        .region = region,
        .size_x = @intCast(bitmap.width),
        .size_y = @intCast(bitmap.rows),
        .bearing_x = glyph.*.bitmap_left,
        .bearing_y = glyph.*.bitmap_top,
        .advance = glyph.*.advance.x,
        .valid = true,
    };
    grapheme_cache.put(alloc, hash, char_data) catch return null;
    return char_data;
}

pub fn loadSpriteGlyph(codepoint: u32, alloc: std.mem.Allocator) ?Character {
    const metrics = sprite.Metrics{
        .cell_width = @intFromFloat(cell_width),
        .cell_height = @intFromFloat(cell_height),
        .box_thickness = box_thickness,
    };

    var result = sprite.renderSprite(alloc, codepoint, metrics) catch return null;
    if (result == null) return null;

    defer result.?.deinit();

    const r = result.?;

    // Extract only the trimmed region for the texture (like Ghostty's writeAtlas)
    // We need to copy row by row since the trimmed region is smaller than the surface
    var trimmed_data = alloc.alloc(u8, r.width * r.height) catch return null;
    defer alloc.free(trimmed_data);

    const src_stride = r.surface_width;
    for (0..r.height) |y| {
        const src_y = y + r.clip_top;
        const src_start = src_y * src_stride + r.clip_left;
        const dst_start = y * r.width;
        @memcpy(trimmed_data[dst_start..][0..r.width], r.data[src_start..][0..r.width]);
    }

    // Pack into font atlas
    const region = packPixelsIntoAtlas(&g_atlas, alloc, @intCast(r.width), @intCast(r.height), trimmed_data) orelse return null;

    // Calculate glyph offsets like Ghostty does:
    // Ghostty: offset_x = clip_left - padding_x
    // Ghostty: offset_y = region.height + clip_bottom - padding_y
    //
    // Ghostty's offset_y is the distance from cell BOTTOM to glyph TOP.
    //
    // Our renderChar formula: y0 = y + cell_baseline - (size_y - bearing_y)
    //                         glyph_top = y0 + size_y = y + cell_baseline + bearing_y
    //
    // We want glyph_top = y + offset_y (cell bottom + distance to glyph top)
    // So: y + cell_baseline + bearing_y = y + offset_y
    // Thus: bearing_y = offset_y - cell_baseline
    const offset_x: i32 = @as(i32, @intCast(r.clip_left)) - @as(i32, @intCast(r.padding_x));
    var offset_y: i32 = @as(i32, @intCast(r.height + r.clip_bottom)) - @as(i32, @intCast(r.padding_y));
    const baseline_i: i32 = @intFromFloat(cell_baseline);

    // For braille (no trim, no padding), offset_y = cell_height, meaning glyph top = cell top.
    // But braille should sit ON the baseline like text, not fill from cell top.
    // Experimentally: subtracting full baseline (6) is too low, 0 is too high.
    // Try half the baseline as a compromise.
    if (codepoint >= 0x2800 and codepoint <= 0x28FF) {
        offset_y -= @divFloor(baseline_i, 2);
    }

    const bearing_y = offset_y - baseline_i;

    return Character{
        .region = region,
        .size_x = @intCast(r.width),
        .size_y = @intCast(r.height),
        .bearing_x = offset_x,
        .bearing_y = bearing_y,
        .advance = @as(i64, @intCast(r.cell_width)) << 6, // Cell width in 26.6 fixed point
        .valid = true,
    };
}

/// Load a glyph for the titlebar (14pt, separate cache/atlas).
pub fn loadTitlebarGlyph(codepoint: u32) ?Character {
    if (g_titlebar_cache.get(codepoint)) |ch| return ch;

    const alloc = AppWindow.g_allocator orelse return null;
    const face = g_titlebar_face orelse return null;

    var glyph_index = face.getCharIndex(codepoint) orelse 0;
    var face_to_use = face;

    // Try fallback for missing glyphs
    if (glyph_index == 0) {
        if (findOrLoadFallbackFace(codepoint, alloc)) |fallback| {
            const fi = fallback.getCharIndex(codepoint) orelse 0;
            if (fi != 0) {
                glyph_index = fi;
                face_to_use = fallback;
            }
        }
    }

    face_to_use.loadGlyph(@intCast(glyph_index), .{ .target = .light }) catch return null;
    face_to_use.renderGlyph(.light) catch return null;

    const glyph = face_to_use.handle.*.glyph;
    const bitmap = glyph.*.bitmap;
    const region = packBitmapIntoAtlas(
        &g_titlebar_atlas,
        alloc,
        bitmap.width,
        bitmap.rows,
        bitmap.buffer,
        @intCast(bitmap.pitch),
    ) orelse return null;

    const ch = Character{
        .region = region,
        .size_x = @intCast(bitmap.width),
        .size_y = @intCast(bitmap.rows),
        .bearing_x = glyph.*.bitmap_left,
        .bearing_y = glyph.*.bitmap_top,
        .advance = glyph.*.advance.x,
        .valid = true,
    };

    g_titlebar_cache.put(alloc, codepoint, ch) catch return null;
    return ch;
}

/// Load a glyph from the Segoe MDL2 Assets icon font.
pub fn loadIconGlyph(codepoint: u32) ?Character {
    if (icon_cache.get(codepoint)) |ch| return ch;

    const face = icon_face orelse return null;
    const alloc = AppWindow.g_allocator orelse return null;

    const glyph_index = face.getCharIndex(codepoint) orelse return null;
    if (glyph_index == 0) return null;

    // Use mono hinting for crisp icon rendering (snaps to pixel grid)
    face.loadGlyph(@intCast(glyph_index), .{ .target = .normal }) catch return null;
    face.renderGlyph(.normal) catch return null;

    const glyph = face.handle.*.glyph;
    const bitmap = glyph.*.bitmap;

    // Pack into icon atlas
    const region = packBitmapIntoAtlas(
        &g_icon_atlas,
        alloc,
        bitmap.width,
        bitmap.rows,
        bitmap.buffer,
        @intCast(bitmap.pitch),
    ) orelse return null;

    const ch = Character{
        .region = region,
        .size_x = @intCast(bitmap.width),
        .size_y = @intCast(bitmap.rows),
        .bearing_x = @intCast(glyph.*.bitmap_left),
        .bearing_y = @intCast(glyph.*.bitmap_top),
        .advance = @intCast(glyph.*.advance.x),
    };

    icon_cache.put(alloc, codepoint, ch) catch return null;
    return ch;
}

pub fn loadBellEmoji() ?BellCache {
    if (g_bell_cache) |cached| return cached;

    const alloc = AppWindow.g_allocator orelse return null;
    const ft_lib = g_ft_lib orelse return null;
    const bell_cp: u32 = 0x1F514;

    // Load a color emoji font face if we haven't yet
    if (g_bell_emoji_face == null) {
        const dw = g_font_discovery orelse return null;
        // Try well-known color emoji fonts
        const emoji_fonts = [_][]const u8{ "Segoe UI Emoji", "Noto Color Emoji" };
        for (emoji_fonts) |font_name| {
            if (dw.findFontFilePath(alloc, font_name, .NORMAL, .NORMAL) catch null) |result| {
                defer alloc.free(result.path);
                const emoji_face = ft_lib.initFace(result.path, @intCast(result.face_index)) catch continue;
                // Set a large size for crisp color emoji bitmaps
                emoji_face.setCharSize(0, 12 * 64, 96, 96) catch {
                    emoji_face.deinit();
                    continue;
                };
                if (emoji_face.hasColor()) {
                    g_bell_emoji_face = emoji_face;
                    break;
                }
                emoji_face.deinit();
            }
        }
    }

    const face = g_bell_emoji_face orelse return null;
    const glyph_index = face.getCharIndex(bell_cp) orelse return null;
    if (glyph_index == 0) return null;

    face.loadGlyph(@intCast(glyph_index), .{ .target = .light, .color = true }) catch return null;
    face.renderGlyph(.light) catch return null;

    const glyph = face.handle.*.glyph;
    const bitmap = glyph.*.bitmap;
    if (bitmap.pixel_mode != freetype.c.FT_PIXEL_MODE_BGRA) return null;

    const region = packColorBitmapIntoAtlas(
        alloc,
        bitmap.width,
        bitmap.rows,
        bitmap.buffer,
        @intCast(@as(c_uint, @intCast(@abs(bitmap.pitch)))),
    ) orelse return null;

    g_bell_cache = .{
        .region = region,
        .bmp_w = @floatFromInt(bitmap.width),
        .bmp_h = @floatFromInt(bitmap.rows),
    };
    return g_bell_cache;
}

// ============================================================================
// Font fallback
// ============================================================================

/// Find or load a fallback font that contains the given codepoint
pub fn findOrLoadFallbackFace(codepoint: u32, alloc: std.mem.Allocator) ?freetype.Face {
    // Check if we already have a fallback for this codepoint
    if (g_fallback_faces.get(codepoint)) |face| {
        return face;
    }

    // Check negative cache - if we already know there's no fallback, skip DirectWrite
    if (g_no_fallback.contains(codepoint)) {
        return null;
    }

    // Need DirectWrite and FreeType library to find fallbacks
    const dw = g_font_discovery orelse return null;
    const ft_lib = g_ft_lib orelse return null;

    // Use DirectWrite to find a font with this codepoint
    const maybe_font = dw.findFallbackFont(codepoint) catch {
        // Cache the negative result to avoid repeated DirectWrite queries
        g_no_fallback.put(alloc, codepoint, {}) catch {};
        return null;
    };
    const font = maybe_font orelse {
        // Cache the negative result
        g_no_fallback.put(alloc, codepoint, {}) catch {};
        return null;
    };
    defer font.release();

    // Get the font face to extract file path
    const dw_face = font.createFontFace() catch return null;
    defer dw_face.release();

    // Get font file
    const font_file = dw_face.getFiles() catch return null;
    defer font_file.release();

    // Get file loader
    const loader = font_file.getLoader() catch return null;
    defer loader.release();

    // Get local font file loader
    const local_loader = loader.queryLocalFontFileLoader() orelse return null;
    defer local_loader.release();

    // Get reference key
    const ref_key = font_file.getReferenceKey() catch return null;

    // Get path length
    const path_len = local_loader.getFilePathLengthFromKey(ref_key.key, ref_key.size) catch return null;

    // Allocate buffer for path
    var path_buf = alloc.alloc(u16, path_len + 1) catch return null;
    defer alloc.free(path_buf);

    // Get the path
    local_loader.getFilePathFromKey(ref_key.key, ref_key.size, path_buf) catch return null;

    // Convert to UTF-8
    const utf8_path = std.unicode.utf16LeToUtf8AllocZ(alloc, path_buf[0..path_len]) catch return null;
    defer alloc.free(utf8_path);

    const face_index = dw_face.getIndex();

    // Load with FreeType
    const ft_face = ft_lib.initFace(utf8_path, @intCast(face_index)) catch return null;

    // Set size to match primary font
    ft_face.setCharSize(0, @as(i32, @intCast(g_font_size)) * 64, 96, 96) catch {
        ft_face.deinit();
        return null;
    };

    // Cache the fallback face for this codepoint
    g_fallback_faces.put(alloc, codepoint, ft_face) catch {
        ft_face.deinit();
        return null;
    };

    return ft_face;
}

// ============================================================================
// Font init / cleanup
// ============================================================================

/// Preload common character ranges
pub fn preloadCharacters(face: freetype.Face) void {
    const gl = &AppWindow.gl;
    gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, 1);

    // Store face for later on-demand loading
    glyph_face = face;

    // Create HarfBuzz font from primary FreeType face for grapheme cluster shaping
    if (g_hb_font) |*hf| hf.destroy();
    g_hb_font = harfbuzz.freetype.createFont(face.handle) catch null;
    if (g_hb_buf == null) {
        g_hb_buf = harfbuzz.Buffer.create() catch null;
    }

    std.debug.print("Starting glyph preload, g_allocator set: {}\n", .{AppWindow.g_allocator != null});

    // Calculate cell dimensions FIRST from font metrics (like Ghostty)
    // This must happen before loading sprites so they use correct dimensions
    //
    // Cell width is the maximum advance of all visible ASCII characters (like Ghostty)
    // This ensures proper spacing for monospace fonts
    {
        var max_advance: f64 = 0;
        var ascii_char: u8 = ' ';
        while (ascii_char < 127) : (ascii_char += 1) {
            if (loadGlyph(ascii_char)) |char| {
                const advance = @as(f64, @floatFromInt(char.advance)) / 64.0; // 26.6 fixed point
                max_advance = @max(max_advance, advance);
            }
        }
        if (max_advance > 0) {
            cell_width = @floatCast(max_advance);
        }
    }

    if (loadGlyph('M')) |_| {

        // Get metrics like Ghostty does - from font tables with fallback to FreeType
        const size_metrics = face.handle.*.size.*.metrics;
        const px_per_em: f64 = @floatFromInt(size_metrics.y_ppem);

        // Get units_per_em from head table or FreeType
        const units_per_em: f64 = blk: {
            if (face.getSfntTable(.head)) |head| {
                break :blk @floatFromInt(head.Units_Per_EM);
            }
            if (face.handle.*.face_flags & freetype.c.FT_FACE_FLAG_SCALABLE != 0) {
                break :blk @floatFromInt(face.handle.*.units_per_EM);
            }
            break :blk @floatFromInt(size_metrics.y_ppem);
        };
        const px_per_unit = px_per_em / units_per_em;

        // Get vertical metrics from font tables (like Ghostty)
        const ascent: f64, const descent: f64, const line_gap: f64 = vertical_metrics: {
            const hhea_ = face.getSfntTable(.hhea);
            const os2_ = face.getSfntTable(.os2);

            // If no hhea table, fall back to FreeType metrics
            const hhea = hhea_ orelse {
                const ft_ascender = f26dot6ToF64(size_metrics.ascender);
                const ft_descender = f26dot6ToF64(size_metrics.descender);
                const ft_height = f26dot6ToF64(size_metrics.height);
                break :vertical_metrics .{
                    ft_ascender,
                    ft_descender,
                    ft_height + ft_descender - ft_ascender,
                };
            };

            const hhea_ascent: f64 = @floatFromInt(hhea.Ascender);
            const hhea_descent: f64 = @floatFromInt(hhea.Descender);
            const hhea_line_gap: f64 = @floatFromInt(hhea.Line_Gap);

            // If no OS/2 table, use hhea metrics
            const os2 = os2_ orelse break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };

            // Check for invalid OS/2 table
            if (os2.version == 0xFFFF) break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };

            const os2_ascent: f64 = @floatFromInt(os2.sTypoAscender);
            const os2_descent: f64 = @floatFromInt(os2.sTypoDescender);
            const os2_line_gap: f64 = @floatFromInt(os2.sTypoLineGap);

            // If USE_TYPO_METRICS bit is set (bit 7), use OS/2 typo metrics
            if (os2.fsSelection & (1 << 7) != 0) {
                break :vertical_metrics .{
                    os2_ascent * px_per_unit,
                    os2_descent * px_per_unit,
                    os2_line_gap * px_per_unit,
                };
            }

            // Otherwise prefer hhea if available
            if (hhea.Ascender != 0 or hhea.Descender != 0) {
                break :vertical_metrics .{
                    hhea_ascent * px_per_unit,
                    hhea_descent * px_per_unit,
                    hhea_line_gap * px_per_unit,
                };
            }

            // Fall back to OS/2 sTypo metrics
            if (os2_ascent != 0 or os2_descent != 0) {
                break :vertical_metrics .{
                    os2_ascent * px_per_unit,
                    os2_descent * px_per_unit,
                    os2_line_gap * px_per_unit,
                };
            }

            // Last resort: OS/2 usWin metrics
            const win_ascent: f64 = @floatFromInt(os2.usWinAscent);
            const win_descent: f64 = @floatFromInt(os2.usWinDescent);
            break :vertical_metrics .{
                win_ascent * px_per_unit,
                -win_descent * px_per_unit, // usWinDescent is positive, flip sign
                0.0,
            };
        };

        // Calculate cell dimensions like Ghostty
        const face_height = ascent - descent + line_gap;
        cell_height = @floatCast(@round(face_height));

        // Split line gap in half for top/bottom padding (like Ghostty)
        const half_line_gap = line_gap / 2.0;

        // Calculate baseline from bottom of cell (like Ghostty)
        // face_baseline = half_line_gap - descent (descent is negative, so this adds)
        const face_baseline = half_line_gap - descent;
        // Center the baseline by accounting for rounding difference
        const baseline_centered = face_baseline - (cell_height - face_height) / 2.0;
        cell_baseline = @floatCast(@round(baseline_centered));

        // Cursor height is the ascender
        cursor_height = @floatCast(@round(ascent));

        // Get underline thickness from post table for box drawing (like Ghostty)
        const underline_thickness: f64 = ul_thick: {
            if (face.getSfntTable(.post)) |post| {
                if (post.underlineThickness != 0) {
                    break :ul_thick @as(f64, @floatFromInt(post.underlineThickness)) * px_per_unit;
                }
            }
            // Fallback: use a reasonable default based on cell height
            break :ul_thick @max(1.0, @round(cell_height / 16.0));
        };
        // Use ceiling like Ghostty
        box_thickness = @max(1, @as(u32, @intFromFloat(@ceil(underline_thickness))));

        std.debug.print("Cell dimensions: {d:.0}x{d:.0} (ascent={d:.1}, descent={d:.1}, line_gap={d:.1}, baseline={d:.0}, box_thick={})\n", .{
            cell_width, cell_height, ascent, descent, line_gap, cell_baseline, box_thickness,
        });
    } else {
        std.debug.print("ERROR: Could not load 'M' glyph!\n", .{});
    }

    // Preload ASCII printable characters (32-126)
    var ascii_loaded: u32 = 0;
    for (32..127) |char| {
        if (loadGlyph(@intCast(char)) != null) {
            ascii_loaded += 1;
        }
    }
    std.debug.print("ASCII glyphs loaded: {}\n", .{ascii_loaded});

    // Preload box drawing characters (U+2500 - U+257F)
    var box_loaded: u32 = 0;
    for (0x2500..0x2580) |char| {
        if (loadGlyph(@intCast(char)) != null) {
            box_loaded += 1;
        }
    }
    std.debug.print("Box drawing glyphs loaded: {}\n", .{box_loaded});

    // Preload block elements (U+2580 - U+259F)
    for (0x2580..0x25A0) |char| {
        _ = loadGlyph(@intCast(char));
    }

    std.debug.print("Total glyphs in cache: {}\n", .{glyph_cache.count()});
}

/// Clear all GL textures from the glyph cache and reset it.
pub fn clearGlyphCache(allocator: std.mem.Allocator) void {
    const gl = &AppWindow.gl;

    glyph_cache.deinit(allocator);
    glyph_cache = .empty;
    grapheme_cache.deinit(allocator);
    grapheme_cache = .empty;

    // Reset grayscale atlas — destroy GPU texture and CPU data, recreate fresh
    if (g_atlas) |*a| {
        a.deinit(allocator);
        g_atlas = null;
    }
    if (g_atlas_texture != 0) {
        gl.DeleteTextures.?(1, &g_atlas_texture);
        g_atlas_texture = 0;
        g_atlas_modified = 0;
    }

    // Reset color atlas (BGRA emoji)
    if (g_color_atlas) |*a| {
        a.deinit(allocator);
        g_color_atlas = null;
    }
    if (g_color_atlas_texture != 0) {
        gl.DeleteTextures.?(1, &g_color_atlas_texture);
        g_color_atlas_texture = 0;
        g_color_atlas_modified = 0;
    }
}

/// Clear fallback font faces.
pub fn clearFallbackFaces(allocator: std.mem.Allocator) void {
    var it = g_fallback_faces.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
    }
    g_fallback_faces.deinit(allocator);
    g_fallback_faces = .empty;

    // Also clear negative cache
    g_no_fallback.deinit(allocator);
    g_no_fallback = .empty;

    // Clean up HarfBuzz fallback fonts
    var hb_it = g_hb_fallback_fonts.iterator();
    while (hb_it.next()) |entry| {
        entry.value_ptr.destroy();
    }
    g_hb_fallback_fonts.deinit(allocator);
    g_hb_fallback_fonts = .empty;

    if (g_hb_font) |*hf| {
        hf.destroy();
        g_hb_font = null;
    }
    if (g_hb_buf) |*hb| {
        hb.destroy();
        g_hb_buf = null;
    }
}

/// Try to load a font face from config, returning the face or null on failure.
pub fn loadFontFromConfig(
    allocator: std.mem.Allocator,
    font_family: []const u8,
    weight: directwrite.DWRITE_FONT_WEIGHT,
    font_size: u32,
    ft_lib: freetype.Library,
) ?freetype.Face {
    // Try system font via DirectWrite
    if (font_family.len > 0) {
        if (g_font_discovery) |dw| {
            if (dw.findFontFilePath(allocator, font_family, weight, .NORMAL) catch null) |result| {
                var r = result;
                defer r.deinit();
                if (ft_lib.initFace(r.path, @intCast(r.face_index))) |face| {
                    face.setCharSize(0, @as(i32, @intCast(font_size)) * 64, 96, 96) catch {
                        face.deinit();
                        return null;
                    };
                    std.debug.print("Reload: loaded system font '{s}'\n", .{font_family});
                    return face;
                } else |_| {}
            }
        }
        std.debug.print("Reload: font '{s}' not found, using embedded fallback\n", .{font_family});
    }

    // Fall back to embedded font
    const face = ft_lib.initMemoryFace(embedded.regular, 0) catch return null;
    face.setCharSize(0, @as(i32, @intCast(font_size)) * 64, 96, 96) catch {
        face.deinit();
        return null;
    };
    return face;
}
