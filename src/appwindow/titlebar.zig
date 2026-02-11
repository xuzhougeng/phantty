//! Titlebar rendering — tab bar, caption buttons, bell indicator, placeholder.
//!
//! Owns the visual rendering of the tab bar (active/inactive tabs, close buttons,
//! + button, caption buttons). Uses AppWindow's GL context and shared rendering
//! primitives. Depends on font module for glyph loading and tab module for state.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const font = AppWindow.font;
const tab = AppWindow.tab;
const cell_renderer = AppWindow.cell_renderer;
const win32_backend = @import("../win32.zig");
const c = @cImport({
    @cInclude("glad/gl.h");
});
const Character = font.Character;

pub const CaptionButtonType = enum { minimize, maximize, close };

/// Render a titlebar glyph at 1:1 atlas size (no scaling).
/// Supports both grayscale (titlebar atlas) and color emoji (color atlas).
pub fn renderTitlebarChar(codepoint: u32, x: f32, y: f32, color: [3]f32) void {
    const gl = AppWindow.gl;
    if (codepoint < 32) return;
    const ch: Character = font.loadTitlebarGlyph(codepoint) orelse return;
    if (ch.region.width == 0 or ch.region.height == 0) return;

    if (ch.is_color) {
        // Color emoji — scale down to fit titlebar height and render with simple color shader
        const scale = font.g_titlebar_cell_height / @as(f32, @floatFromInt(ch.size_y));
        const w = @as(f32, @floatFromInt(ch.size_x)) * scale;
        const h = @as(f32, @floatFromInt(ch.size_y)) * scale;
        const x0 = x;
        const y0 = y;

        const atlas_size = if (font.g_color_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
        const uv = font.glyphUV(ch.region, atlas_size);

        const vertices = [6][4]f32{
            .{ x0, y0 + h, uv.u0, uv.v0 },
            .{ x0, y0, uv.u0, uv.v1 },
            .{ x0 + w, y0, uv.u1, uv.v1 },
            .{ x0, y0 + h, uv.u0, uv.v0 },
            .{ x0 + w, y0, uv.u1, uv.v1 },
            .{ x0 + w, y0 + h, uv.u1, uv.v0 },
        };

        // Use simple color shader (same vertex layout as text shader, but samples RGBA)
        // Set projection matrix from current viewport (same ortho as text shader)
        var viewport: [4]c.GLint = undefined;
        gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
        const vp_w: f32 = @floatFromInt(viewport[2]);
        const vp_h: f32 = @floatFromInt(viewport[3]);
        const projection = [16]f32{
            2.0 / vp_w, 0.0,        0.0,  0.0,
            0.0,        2.0 / vp_h, 0.0,  0.0,
            0.0,        0.0,         -1.0, 0.0,
            -1.0,       -1.0,        0.0,  1.0,
        };
        gl.UseProgram.?(AppWindow.simple_color_shader);
        gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(AppWindow.simple_color_shader, "projection"), 1, c.GL_FALSE, &projection);
        gl.Uniform1f.?(gl.GetUniformLocation.?(AppWindow.simple_color_shader, "opacity"), 1.0);
        // Premultiplied alpha blend for color emoji (BGRA bitmaps from FreeType)
        gl.BlendFunc.?(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        gl.BindTexture.?(c.GL_TEXTURE_2D, font.g_color_atlas_texture);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, AppWindow.vbo);
        gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
        gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); AppWindow.g_draw_call_count += 1;
        // Restore text shader and standard alpha blend
        gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        gl.UseProgram.?(AppWindow.shader_program);
    } else {
        // Grayscale glyph — render with text shader from titlebar atlas
        const x0 = x + @as(f32, @floatFromInt(ch.bearing_x));
        const y0 = y + font.g_titlebar_baseline - @as(f32, @floatFromInt(ch.size_y - ch.bearing_y));
        const w = @as(f32, @floatFromInt(ch.size_x));
        const h = @as(f32, @floatFromInt(ch.size_y));

        const atlas_size = if (font.g_titlebar_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
        const uv = font.glyphUV(ch.region, atlas_size);

        const vertices = [6][4]f32{
            .{ x0, y0 + h, uv.u0, uv.v0 },
            .{ x0, y0, uv.u0, uv.v1 },
            .{ x0 + w, y0, uv.u1, uv.v1 },
            .{ x0, y0 + h, uv.u0, uv.v0 },
            .{ x0 + w, y0, uv.u1, uv.v1 },
            .{ x0 + w, y0 + h, uv.u1, uv.v0 },
        };

        gl.Uniform3f.?(gl.GetUniformLocation.?(AppWindow.shader_program, "textColor"), color[0], color[1], color[2]);
        gl.BindTexture.?(c.GL_TEXTURE_2D, font.g_titlebar_atlas_texture);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, AppWindow.vbo);
        gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
        gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); AppWindow.g_draw_call_count += 1;
    }
}

/// Get the advance width of a titlebar glyph.
pub fn titlebarGlyphAdvance(codepoint: u32) f32 {
    if (font.loadTitlebarGlyph(codepoint)) |g| {
        const raw_advance = @as(f32, @floatFromInt(g.advance >> 6));
        if (g.is_color) {
            // Color emoji: scale advance to match the scaled-down rendering size
            const scale = font.g_titlebar_cell_height / @as(f32, @floatFromInt(g.size_y));
            return raw_advance * scale;
        }
        return raw_advance;
    }
    return font.g_titlebar_cell_width;
}

pub fn renderBellEmoji(x: f32, y: f32, opacity: f32) void {
    const gl = AppWindow.gl;
    const bell = font.loadBellEmoji() orelse {
        renderTitlebarChar(0x1F514, x, y, .{ 1.0, 0.84, 0.0 });
        return;
    };

    const aspect = bell.bmp_w / bell.bmp_h;
    const h = font.g_titlebar_cell_height * 0.85;
    const w = h * aspect;
    const x0 = x;
    const y0 = y;

    const atlas_size = if (font.g_color_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = font.glyphUV(bell.region, atlas_size);

    const vertices = [6][4]f32{
        .{ x0, y0 + h, uv.u0, uv.v0 },
        .{ x0, y0, uv.u0, uv.v1 },
        .{ x0 + w, y0, uv.u1, uv.v1 },
        .{ x0, y0 + h, uv.u0, uv.v0 },
        .{ x0 + w, y0, uv.u1, uv.v1 },
        .{ x0 + w, y0 + h, uv.u1, uv.v0 },
    };

    // Compute projection from current viewport
    var viewport: [4]c.GLint = undefined;
    gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
    const vp_w: f32 = @floatFromInt(viewport[2]);
    const vp_h: f32 = @floatFromInt(viewport[3]);
    const projection = [16]f32{
        2.0 / vp_w, 0.0,        0.0,  0.0,
        0.0,        2.0 / vp_h, 0.0,  0.0,
        0.0,        0.0,         -1.0, 0.0,
        -1.0,       -1.0,        0.0,  1.0,
    };

    // Render with simple color shader (premultiplied alpha + opacity fade)
    gl.UseProgram.?(AppWindow.simple_color_shader);
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(AppWindow.simple_color_shader, "projection"), 1, c.GL_FALSE, &projection);
    gl.Uniform1f.?(gl.GetUniformLocation.?(AppWindow.simple_color_shader, "opacity"), opacity);
    gl.BlendFunc.?(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.BindTexture.?(c.GL_TEXTURE_2D, font.g_color_atlas_texture);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, AppWindow.vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); AppWindow.g_draw_call_count += 1;

    // Restore text shader and standard blend
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(AppWindow.shader_program);
}

/// Render an icon glyph centered within a button rect, using the icon atlas.
pub fn renderIconGlyph(ch: Character, btn_x: f32, btn_y: f32, btn_w: f32, btn_h: f32, color: [3]f32, scale: f32) void {
    const gl = AppWindow.gl;
    if (ch.region.width == 0 or ch.region.height == 0) return;

    const gw = @as(f32, @floatFromInt(ch.size_x)) * scale;
    const gh = @as(f32, @floatFromInt(ch.size_y)) * scale;
    const gx = btn_x + (btn_w - gw) / 2;
    const gy = btn_y + (btn_h - gh) / 2;

    const icon_atlas_size = if (font.g_icon_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = font.glyphUV(ch.region, icon_atlas_size);

    const vertices = [6][4]f32{
        .{ gx, gy + gh, uv.u0, uv.v0 },
        .{ gx, gy, uv.u0, uv.v1 },
        .{ gx + gw, gy, uv.u1, uv.v1 },
        .{ gx, gy + gh, uv.u0, uv.v0 },
        .{ gx + gw, gy, uv.u1, uv.v1 },
        .{ gx + gw, gy + gh, uv.u1, uv.v0 },
    };

    gl.Uniform3f.?(gl.GetUniformLocation.?(AppWindow.shader_program, "textColor"), color[0], color[1], color[2]);
    gl.BindTexture.?(c.GL_TEXTURE_2D, font.g_icon_atlas_texture);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, AppWindow.vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); AppWindow.g_draw_call_count += 1;
}

/// Render the Ghostty-style tab bar.
/// Single row: [tabs...][+][  ][min][max][close]
///
/// Design (from Ghostty macOS screenshot):
/// - Tabs fill available width equally (left of + and caption buttons)
/// - Active tab: same color as terminal background (merges with content)
/// - Inactive tabs: slightly lighter shade
/// - Thin vertical separators between tabs
/// - No rounded corners, no accent lines — purely shade-based
/// - + button right of last tab
/// - Caption buttons on far right
///
/// OpenGL Y=0 is BOTTOM, so titlebar top = window_height - titlebar_h.
pub fn renderTitlebar(window_width: f32, window_height: f32, titlebar_h: f32) void {
    const gl = AppWindow.gl;
    if (titlebar_h <= 0) return;

    gl.UseProgram.?(AppWindow.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(AppWindow.vao);

    const tb_top = window_height - titlebar_h; // top of titlebar in GL coords
    const bg = AppWindow.g_theme.background;

    // Colors — Ghostty style:
    // - Active tab: same as terminal bg, no border (merges with content)
    // - Inactive tabs & + button: slightly lighter bg with 1px darker inset border
    const inactive_tab_bg = [3]f32{
        @min(1.0, bg[0] + 0.05),
        @min(1.0, bg[1] + 0.05),
        @min(1.0, bg[2] + 0.05),
    };
    const border_color = [3]f32{
        @max(0.0, bg[0] - 0.02),
        @max(0.0, bg[1] - 0.02),
        @max(0.0, bg[2] - 0.02),
    };
    const text_active = [3]f32{ 0.9, 0.9, 0.9 };
    const text_inactive = [3]f32{ 0.55, 0.55, 0.55 };

    // Layout constants
    const caption_btn_w: f32 = 46;
    const caption_area_w: f32 = caption_btn_w * 3; // min + max + close
    const plus_btn_w: f32 = 46; // + button width (same as caption buttons)
    const gap_w: f32 = 42; // breathing room between + and caption buttons
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    // Calculate space: tabs fill remaining width after + button, gap, and caption buttons
    const plus_total: f32 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f32 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f32 = window_width - right_reserved;
    const tab_w: f32 = if (num_tabs > 0) tab_area_w / @as(f32, @floatFromInt(num_tabs)) else tab_area_w;

    // --- Tab bar background (same as terminal bg) ---
    AppWindow.renderQuad(0, tb_top, window_width, titlebar_h, bg);

    // --- Tabs ---
    var cursor_x: f32 = 0;
    const bdr: f32 = 1; // border thickness

    // --- Update close button fade animation (delta-time based) ---
    const now_ms = std.time.milliTimestamp();
    const dt: f32 = if (tab.g_last_frame_time_ms > 0)
        @as(f32, @floatFromInt(now_ms - tab.g_last_frame_time_ms)) / 1000.0
    else
        0.016; // ~60fps default on first frame
    tab.g_last_frame_time_ms = now_ms;

    for (0..num_tabs) |tab_idx| {
        const is_active = (tab_idx == tab.g_active_tab);

        // Check if mouse is hovering this tab
        const tab_hovered = blk: {
            const win = AppWindow.g_window orelse break :blk false;
            if (win.mouse_y < 0 or win.mouse_y >= @as(i32, @intFromFloat(titlebar_h))) break :blk false;
            const fx: f32 = @floatFromInt(win.mouse_x);
            break :blk fx >= cursor_x and fx < cursor_x + tab_w;
        };

        // Animate close button opacity: fade in when hovered, fade out when not
        if (num_tabs > 1) {
            if (tab_hovered) {
                tab.g_tab_close_opacity[tab_idx] = @min(1.0, tab.g_tab_close_opacity[tab_idx] + tab.TAB_CLOSE_FADE_SPEED * dt);
            } else {
                tab.g_tab_close_opacity[tab_idx] = @max(0.0, tab.g_tab_close_opacity[tab_idx] - tab.TAB_CLOSE_FADE_SPEED * dt);
            }
        } else {
            tab.g_tab_close_opacity[tab_idx] = 0;
        }

        // Animate bell indicator opacity (for focused surface in tab)
        if (tab.g_tabs[tab_idx]) |tb| {
            if (tb.focusedSurface()) |surface| {
                if (surface.bell_indicator) {
                    // Fade in
                    surface.bell_opacity = @min(1.0, surface.bell_opacity + tab.TAB_CLOSE_FADE_SPEED * dt);

                    // On active tab: after 1s hold, start fading out and clear indicator
                    if (is_active and surface.bell_opacity >= 1.0) {
                        const elapsed = now_ms - surface.bell_indicator_time;
                        if (elapsed >= 1000) {
                            surface.bell_indicator = false;
                        }
                    }
                } else {
                    // Fade out
                    surface.bell_opacity = @max(0.0, surface.bell_opacity - tab.TAB_CLOSE_FADE_SPEED * dt);
                }
            }
        }

        // Inactive tabs: slightly lighter bg with 1px darker inset border
        // Active tab: no border, same as terminal bg (merges with content)
        if (!is_active) {
            // Fill — slightly lighter on hover
            const tab_bg = if (tab_hovered) [3]f32{
                @min(1.0, inactive_tab_bg[0] + 0.04),
                @min(1.0, inactive_tab_bg[1] + 0.04),
                @min(1.0, inactive_tab_bg[2] + 0.04),
            } else inactive_tab_bg;
            AppWindow.renderQuad(cursor_x, tb_top, tab_w, titlebar_h, tab_bg);

            // 1px inset border — left border only (skip on first tab), bottom
            AppWindow.renderQuad(cursor_x, tb_top, tab_w, bdr, border_color); // bottom
            if (tab_idx > 0) {
                AppWindow.renderQuad(cursor_x, tb_top, bdr, titlebar_h, border_color); // left
            }
        }

        // Tab title text — rendered at native 14pt via titlebar font (no scaling)
        // Shortcut label (^1 through ^0) rendered right-aligned, only for tabs 1–10 in multi-tab
        const is_renaming = tab.g_tab_rename_active and tab_idx == tab.g_tab_rename_idx;
        const title = if (is_renaming)
            tab.g_tab_rename_buf[0..tab.g_tab_rename_len]
        else if (tab.g_tabs[tab_idx]) |t|
            t.getTitle()
        else
            "New Tab";
        if (title.len > 0 or is_renaming) {
            const text_color = if (is_active) text_active else text_inactive;
            const shortcut_color = [3]f32{ 0.45, 0.45, 0.45 };
            const tab_pad: f32 = 12;

            // Shortcut label: "^1" through "^9", "^0" for tab 10
            const has_shortcut = num_tabs > 1 and tab_idx < 10;
            const shortcut_digit: u8 = if (has_shortcut)
                (if (tab_idx == 9) '0' else @as(u8, @intCast('1' + tab_idx)))
            else
                0;

            // Measure shortcut width
            var shortcut_w: f32 = 0;
            if (has_shortcut) {
                shortcut_w += titlebarGlyphAdvance('^');
                shortcut_w += titlebarGlyphAdvance(@intCast(shortcut_digit));
            }

            const shortcut_gap: f32 = if (has_shortcut) 6 else 0;
            const shortcut_reserved = if (has_shortcut) shortcut_w + shortcut_gap else 0;

            const center_region = if (num_tabs == 1) window_width else tab_w;
            const center_offset = if (num_tabs == 1) @as(f32, 0) else cursor_x;
            const avail_w = center_region - tab_pad * 2 - shortcut_reserved;

            // Decode title into codepoints for proper UTF-8 handling
            var codepoints: [256]u32 = undefined;
            var cp_count: usize = 0;
            var text_width: f32 = 0;

            // Bell indicator opacity (rendered independently of text layout)
            const bell_opacity: f32 = if (tab.g_tabs[tab_idx]) |t| (if (t.focusedSurface()) |s| s.bell_opacity else 0) else 0;
            const has_bell = bell_opacity > 0.01;
            const bell_emoji_width: f32 = if (has_bell) blk: {
                if (font.loadBellEmoji()) |bell| {
                    const aspect = bell.bmp_w / bell.bmp_h;
                    break :blk font.g_titlebar_cell_height * 0.85 * aspect;
                }
                break :blk titlebarGlyphAdvance(0x1F514);
            } else 0;

            {
                const view = std.unicode.Utf8View.initUnchecked(title);
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| {
                    if (cp_count >= 256) break;
                    codepoints[cp_count] = cp;
                    text_width += titlebarGlyphAdvance(cp);
                    cp_count += 1;
                }
            }

            const text_y = tb_top + (titlebar_h - font.g_titlebar_cell_height) / 2;

            // Left edge the bell must not cross (same padding as close button side)
            const left_edge = center_offset + tab_pad;
            const bell_gap: f32 = 4;

            // Compute how much space the bell needs from the left of the text
            const bell_reserved: f32 = if (has_bell) bell_emoji_width + bell_gap else 0;

            // Check if text + bell would overflow: center the text, see if bell fits
            const text_area = center_region - shortcut_reserved;
            const ideal_text_x = center_offset + (text_area - @min(text_width, avail_w)) / 2;
            const bell_would_be_at = ideal_text_x - bell_reserved;
            const bell_overflows = has_bell and bell_would_be_at < left_edge;

            // If bell overflows, shrink available text width to make room
            const effective_avail_w = if (bell_overflows)
                avail_w - bell_reserved
            else
                avail_w;

            if (text_width <= effective_avail_w) {
                // Fits — center text (accounting for bell space if needed)
                var text_x: f32 = undefined;
                if (bell_overflows) {
                    // Bell at left edge, text right after it
                    const remaining_area = center_region - shortcut_reserved - bell_reserved - tab_pad;
                    text_x = left_edge + bell_reserved + (remaining_area - text_width) / 2;
                } else {
                    text_x = ideal_text_x;
                }

                // Render bell emoji just to the left of the text
                if (has_bell) {
                    renderBellEmoji(text_x - bell_reserved, text_y, bell_opacity);
                }

                const text_start_x = text_x;

                // Track byte position to find rename cursor location
                var rename_cursor_x: f32 = text_x;
                var byte_pos: usize = 0;
                var found_cursor = false;

                for (codepoints[0..cp_count]) |cp| {
                    if (is_renaming and !found_cursor and byte_pos >= tab.g_tab_rename_cursor) {
                        rename_cursor_x = text_x;
                        found_cursor = true;
                    }
                    renderTitlebarChar(cp, text_x, text_y, text_color);
                    text_x += titlebarGlyphAdvance(cp);
                    byte_pos += std.unicode.utf8CodepointSequenceLength(@truncate(cp)) catch 1;
                }

                // Render rename selection highlight or cursor
                if (is_renaming) {
                    if (tab.g_tab_rename_select_all and text_width > 0) {
                        // Highlight behind the text — use cursor color
                        AppWindow.renderQuad(text_start_x, text_y, text_width, font.g_titlebar_cell_height, AppWindow.g_theme.cursor_color);
                        // Re-render text on top in contrasting color
                        const sel_text_color = AppWindow.g_theme.cursor_text orelse AppWindow.g_theme.background;
                        var sel_x = text_start_x;
                        for (codepoints[0..cp_count]) |cp| {
                            renderTitlebarChar(cp, sel_x, text_y, sel_text_color);
                            sel_x += titlebarGlyphAdvance(cp);
                        }
                    } else {
                        if (!found_cursor) rename_cursor_x = text_x;
                        // Blink the cursor using the existing blink timer
                        if (AppWindow.g_cursor_blink_visible) {
                            AppWindow.renderQuad(rename_cursor_x, text_y, 1.0, font.g_titlebar_cell_height, text_active);
                        }
                    }
                }

                // Record text bounds for double-click hit testing
                tab.g_tab_text_x_start[tab_idx] = text_start_x;
                tab.g_tab_text_x_end[tab_idx] = text_x;
            } else {
                // Middle truncation
                const ellipsis_char: u32 = 0x2026;
                const ellipsis_w = titlebarGlyphAdvance(ellipsis_char);
                const text_budget = effective_avail_w - ellipsis_w;
                const half_budget = text_budget / 2;

                // Measure codepoints from start
                var start_w: f32 = 0;
                var start_end: usize = 0;
                for (codepoints[0..cp_count], 0..) |cp, idx| {
                    const char_w = titlebarGlyphAdvance(cp);
                    if (start_w + char_w > half_budget) break;
                    start_w += char_w;
                    start_end = idx + 1;
                }

                // Measure codepoints from end
                var end_w: f32 = 0;
                var end_start: usize = cp_count;
                var j: usize = cp_count;
                while (j > start_end) {
                    j -= 1;
                    const char_w = titlebarGlyphAdvance(codepoints[j]);
                    if (end_w + char_w > half_budget) break;
                    end_w += char_w;
                    end_start = j;
                }

                const text_x_start = if (bell_overflows)
                    left_edge + bell_reserved
                else
                    left_edge;

                // Render bell emoji
                if (has_bell) {
                    renderBellEmoji(text_x_start - bell_reserved, text_y, bell_opacity);
                }

                var text_x = text_x_start;
                for (codepoints[0..start_end]) |cp| {
                    renderTitlebarChar(cp, text_x, text_y, text_color);
                    text_x += titlebarGlyphAdvance(cp);
                }
                renderTitlebarChar(ellipsis_char, text_x, text_y, text_color);
                text_x += ellipsis_w;
                for (codepoints[end_start..cp_count]) |cp| {
                    renderTitlebarChar(cp, text_x, text_y, text_color);
                    text_x += titlebarGlyphAdvance(cp);
                }

                // Render rename selection highlight or cursor (same as non-truncated path)
                if (is_renaming) {
                    const trunc_width = text_x - text_x_start;
                    if (tab.g_tab_rename_select_all and trunc_width > 0) {
                        // Highlight behind the text — use cursor color
                        AppWindow.renderQuad(text_x_start, text_y, trunc_width, font.g_titlebar_cell_height, AppWindow.g_theme.cursor_color);
                        // Re-render text on top in contrasting color
                        const sel_text_color = AppWindow.g_theme.cursor_text orelse AppWindow.g_theme.background;
                        var sel_x = text_x_start;
                        for (codepoints[0..start_end]) |cp| {
                            renderTitlebarChar(cp, sel_x, text_y, sel_text_color);
                            sel_x += titlebarGlyphAdvance(cp);
                        }
                        renderTitlebarChar(ellipsis_char, sel_x, text_y, sel_text_color);
                        sel_x += ellipsis_w;
                        for (codepoints[end_start..cp_count]) |cp| {
                            renderTitlebarChar(cp, sel_x, text_y, sel_text_color);
                            sel_x += titlebarGlyphAdvance(cp);
                        }
                    } else if (!tab.g_tab_rename_select_all) {
                        // Blink cursor at end (cursor position tracking in truncated
                        // text is approximate — place at end for simplicity)
                        if (AppWindow.g_cursor_blink_visible) {
                            AppWindow.renderQuad(text_x, text_y, 1.0, font.g_titlebar_cell_height, text_active);
                        }
                    }
                }

                // Record text bounds for double-click hit testing
                tab.g_tab_text_x_start[tab_idx] = text_x_start;
                tab.g_tab_text_x_end[tab_idx] = text_x;
            }

            // Right side: shortcut and close button crossfade in the same position.
            // close_opacity (0→1) drives the animation:
            //   0 = shortcut visible, close hidden
            //   1 = shortcut slid down + faded out, close faded in
            const close_opacity = tab.g_tab_close_opacity[tab_idx];
            const shortcut_opacity = 1.0 - close_opacity;

            const right_edge = center_offset + center_region - tab_pad;

            // Shortcut label — fades out and slides down on hover
            if (has_shortcut and shortcut_opacity > 0.01) {
                const sc_x = right_edge - shortcut_w;
                const slide_down: f32 = close_opacity * 6; // slide 6px down
                const sc_y = text_y - slide_down;

                const sc_base = if (is_active) text_active else shortcut_color;
                const sc_faded = [3]f32{
                    sc_base[0] * shortcut_opacity + bg[0] * close_opacity,
                    sc_base[1] * shortcut_opacity + bg[1] * close_opacity,
                    sc_base[2] * shortcut_opacity + bg[2] * close_opacity,
                };
                var sx = sc_x;
                renderTitlebarChar('^', sx, sc_y, sc_faded);
                sx += titlebarGlyphAdvance('^');
                renderTitlebarChar(@intCast(shortcut_digit), sx, sc_y, sc_faded);
            }

            // Close button — fades in, centered on the shortcut's visual center
            if (close_opacity > 0.01 and num_tabs > 1) {
                const shortcut_center = right_edge - shortcut_w / 2;
                const close_btn_x = shortcut_center - tab.TAB_CLOSE_BTN_W / 2;
                const close_hovered = blk: {
                    if (!tab_hovered) break :blk false;
                    const win = AppWindow.g_window orelse break :blk false;
                    const fx: f32 = @floatFromInt(win.mouse_x);
                    break :blk fx >= close_btn_x and fx < close_btn_x + tab.TAB_CLOSE_BTN_W;
                };

                const base_close_color = [3]f32{ 0.6, 0.6, 0.6 };
                const hover_close_color = [3]f32{ 0.95, 0.95, 0.95 };
                const raw_color = if (close_hovered) hover_close_color else base_close_color;
                const faded_close_color = [3]f32{
                    raw_color[0] * close_opacity + bg[0] * shortcut_opacity,
                    raw_color[1] * close_opacity + bg[1] * shortcut_opacity,
                    raw_color[2] * close_opacity + bg[2] * shortcut_opacity,
                };

                // Subtle hover highlight
                if (close_hovered) {
                    const hover_bg = [3]f32{
                        @min(1.0, bg[0] + 0.1),
                        @min(1.0, bg[1] + 0.1),
                        @min(1.0, bg[2] + 0.1),
                    };
                    const btn_size: f32 = 22;
                    const bx = close_btn_x + (tab.TAB_CLOSE_BTN_W - btn_size) / 2;
                    const by = tb_top + (titlebar_h - btn_size) / 2;
                    AppWindow.renderQuadAlpha(bx, by, btn_size, btn_size, hover_bg, close_opacity);
                }

                if (font.icon_face != null) {
                    if (font.loadIconGlyph(0xE8BB)) |ch| {
                        renderIconGlyph(ch, close_btn_x, tb_top, tab.TAB_CLOSE_BTN_W, titlebar_h, faded_close_color, 1.0);
                    }
                } else {
                    const cx = close_btn_x + tab.TAB_CLOSE_BTN_W / 2;
                    const cy = tb_top + titlebar_h / 2;
                    const arm: f32 = 4;
                    const t: f32 = 1.0;
                    const steps: usize = 24;
                    for (0..steps) |si| {
                        const frac = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(steps - 1));
                        const px = cx - arm + frac * arm * 2;
                        AppWindow.renderQuad(px - t / 2, (cy + arm - frac * arm * 2) - t / 2, t, t, faded_close_color);
                        AppWindow.renderQuad(px - t / 2, (cy - arm + frac * arm * 2) - t / 2, t, t, faded_close_color);
                    }
                }
            }
        }

        // Sync close button position for double-click suppression in WndProc
        if (AppWindow.g_window) |w| {
            if (num_tabs > 1 and tab_idx < 10 and font.g_titlebar_face != null) {
                // Close button is centered on shortcut position at right edge of tab
                const tp: f32 = 12; // tab_pad
                const digit: u32 = if (tab_idx == 9) '0' else @as(u32, @intCast('1' + tab_idx));
                const sc_w = titlebarGlyphAdvance('^') + titlebarGlyphAdvance(digit);
                const re = cursor_x + tab_w - tp;
                const sc_center = re - sc_w / 2;
                const cb_x = sc_center - tab.TAB_CLOSE_BTN_W / 2;
                w.close_btn_x_start[tab_idx] = @intFromFloat(cb_x);
                w.close_btn_x_end[tab_idx] = @intFromFloat(cb_x + tab.TAB_CLOSE_BTN_W);
            }
        }

        cursor_x += tab_w;
    }

    // --- + (new tab) button — transparent bg, inactive_tab_bg on hover ---
    if (show_plus) {
        // Check if mouse is hovering the + button
        const plus_hovered = blk: {
            const win = AppWindow.g_window orelse break :blk false;
            const mouse_x = win.mouse_x;
            const mouse_y = win.mouse_y;
            if (mouse_y < 0 or mouse_y >= @as(i32, @intFromFloat(titlebar_h))) break :blk false;
            const fx: f32 = @floatFromInt(mouse_x);
            break :blk fx >= cursor_x and fx < cursor_x + plus_btn_w;
        };

        if (plus_hovered) {
            AppWindow.renderQuad(cursor_x, tb_top, plus_btn_w, titlebar_h, inactive_tab_bg);
            AppWindow.renderQuad(cursor_x, tb_top, plus_btn_w, bdr, border_color); // bottom
        }

        // Left border — skip when last tab is active (no visual break needed)
        if (tab.g_active_tab != num_tabs - 1) {
            AppWindow.renderQuad(cursor_x, tb_top, bdr, titlebar_h, border_color);
        }

        // + icon — same font/color as caption buttons, scaled up 15% to match stroke weight
        const plus_icon_color = [3]f32{ 0.75, 0.75, 0.75 };
        const plus_scale: f32 = 1.15;
        if (font.icon_face != null) {
            if (font.loadIconGlyph(0xE948)) |ch| {
                renderIconGlyph(ch, cursor_x, tb_top, plus_btn_w, titlebar_h, plus_icon_color, plus_scale);
            }
        } else {
            const plus_cx = cursor_x + plus_btn_w / 2;
            const plus_cy = tb_top + titlebar_h / 2;
            const arm: f32 = 5;
            const t: f32 = 1.0;
            AppWindow.renderQuad(plus_cx - arm, plus_cy - t / 2, arm * 2, t, plus_icon_color);
            AppWindow.renderQuad(plus_cx - t / 2, plus_cy - arm, t, arm * 2, plus_icon_color);
        }
        // Sync plus button position for double-click suppression in WndProc
        if (AppWindow.g_window) |w| {
            w.plus_btn_x_start = @intFromFloat(cursor_x);
            w.plus_btn_x_end = @intFromFloat(cursor_x + plus_btn_w);
        }
        cursor_x += plus_btn_w;
    }

    // --- Caption buttons (minimize, maximize, close) ---
    const btn_h: f32 = titlebar_h;
    const hovered: win32_backend.CaptionButton = if (AppWindow.g_window) |w| w.hovered_button else .none;

    const caption_start = window_width - caption_area_w;
    renderCaptionButton(caption_start, tb_top, caption_btn_w, btn_h, .minimize, hovered == .minimize);
    renderCaptionButton(caption_start + caption_btn_w, tb_top, caption_btn_w, btn_h, .maximize, hovered == .maximize);
    renderCaptionButton(caption_start + caption_btn_w * 2, tb_top, caption_btn_w, btn_h, .close, hovered == .close);

    // --- Focus border: 1px accent border when window is focused (matches Explorer/DWM) ---
    {
        const is_focused = if (AppWindow.g_window) |w| w.focused else false;
        const is_maximized = if (AppWindow.g_window) |w| win32_backend.IsZoomed(w.hwnd) != 0 else false;
        if (is_focused and !is_maximized) {
            // Same color as active tab (terminal background)
            const accent = bg;
            const b: f32 = 1; // 1px border
            AppWindow.renderQuad(0, 0, window_width, b, accent); // bottom
            AppWindow.renderQuad(0, window_height - b, window_width, b, accent); // top
            AppWindow.renderQuad(0, 0, b, window_height, accent); // left
            AppWindow.renderQuad(window_width - b, 0, b, window_height, accent); // right
        }
    }
}

/// Draw a Windows Terminal-style caption button with hover support.
/// Each button is 46×40px with a 10×10 icon centered inside.
/// Matches Windows Terminal's visual style:
///   - Normal: transparent bg, light gray icon
///   - Hover (min/max): subtle light fill bg, white icon
///   - Hover (close): red #C42B1C bg, white icon
pub fn renderCaptionButton(x: f32, y: f32, w: f32, h: f32, btn_type: CaptionButtonType, hovered: bool) void {
    // Draw hover background, respecting the 1px focus border on edges
    if (hovered) {
        const hover_bg = switch (btn_type) {
            .close => [3]f32{ 0.77, 0.17, 0.11 }, // #C42B1C
            else => [3]f32{
                @min(1.0, AppWindow.g_theme.background[0] + 0.05),
                @min(1.0, AppWindow.g_theme.background[1] + 0.05),
                @min(1.0, AppWindow.g_theme.background[2] + 0.05),
            },
        };
        // Close button is at the window edge — inset by 1px on top/right
        // to respect the focus border (matches Explorer behavior)
        if (btn_type == .close) {
            const is_focused = if (AppWindow.g_window) |win| win.focused else false;
            const is_maximized = if (AppWindow.g_window) |win| win32_backend.IsZoomed(win.hwnd) != 0 else false;
            const b: f32 = if (is_focused and !is_maximized) 1 else 0;
            AppWindow.renderQuad(x, y + b, w - b, h - b, hover_bg);
        } else {
            AppWindow.renderQuad(x, y, w, h, hover_bg);
        }
    }

    // Icon color: white when hovered, light gray otherwise
    const icon_color: [3]f32 = if (hovered) .{ 1.0, 1.0, 1.0 } else .{ 0.75, 0.75, 0.75 };

    // Check if window is maximized or fullscreen (for restore icon)
    const is_maximized = if (AppWindow.g_window) |win| win32_backend.IsZoomed(win.hwnd) != 0 else false;
    const is_fullscreen = if (AppWindow.g_window) |win| win.is_fullscreen else false;

    // Segoe MDL2 Assets glyph codepoints (same as Windows Terminal)
    const icon_codepoint: u32 = switch (btn_type) {
        .close => 0xE8BB,
        .maximize => if (is_maximized or is_fullscreen) @as(u32, 0xE923) else @as(u32, 0xE922),
        .minimize => 0xE921,
    };

    // Try rendering from Segoe MDL2 Assets icon font
    if (font.icon_face != null) {
        if (font.loadIconGlyph(icon_codepoint)) |ch| {
            renderIconGlyph(ch, x, y, w, h, icon_color, 1.0);
            return;
        }
    }

    // Fallback: quad-based icons
    const cx = x + w / 2;
    const cy = y + h / 2;

    switch (btn_type) {
        .close => {
            const size: f32 = 5;
            const steps: usize = 32;
            const t: f32 = 1.5;
            for (0..steps) |i| {
                const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps - 1));
                const px = cx - size + frac * size * 2;
                const py1 = cy + size - frac * size * 2;
                AppWindow.renderQuad(px - t / 2, py1 - t / 2, t, t, icon_color);
                const py2 = cy - size + frac * size * 2;
                AppWindow.renderQuad(px - t / 2, py2 - t / 2, t, t, icon_color);
            }
        },
        .maximize => {
            const size: f32 = 5;
            const t: f32 = 1;
            AppWindow.renderQuad(cx - size, cy + size - t, size * 2, t, icon_color); // top
            AppWindow.renderQuad(cx - size, cy - size, size * 2, t, icon_color); // bottom
            AppWindow.renderQuad(cx - size, cy - size, t, size * 2, icon_color); // left
            AppWindow.renderQuad(cx + size - t, cy - size, t, size * 2, icon_color); // right
        },
        .minimize => {
            const size: f32 = 5;
            const t: f32 = 1;
            AppWindow.renderQuad(cx - size, cy - t / 2, size * 2, t, icon_color);
        },
    }
}

/// Render placeholder content for tabs that don't have a terminal yet.
pub fn renderPlaceholderTab(window_width: f32, window_height: f32, top_pad: f32) void {
    const gl = AppWindow.gl;
    gl.UseProgram.?(AppWindow.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(AppWindow.vao);

    const msg = "Tabs not yet implemented";
    const hint = "Press Ctrl+Shift+T to open, Ctrl+W to close";
    const text_color = [3]f32{ 0.4, 0.4, 0.4 };

    // Center the message vertically and horizontally
    const content_h = window_height - top_pad;
    const center_y = content_h / 2;

    // Measure and draw main message
    var msg_width: f32 = 0;
    for (msg) |ch| {
        if (font.getGlyphInfo(@intCast(ch))) |g| {
            msg_width += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            msg_width += font.cell_width;
        }
    }
    var x = (window_width - msg_width) / 2;
    var y = center_y + font.cell_height / 2;
    for (msg) |ch| {
        cell_renderer.renderChar(@intCast(ch), x, y, text_color);
        if (font.getGlyphInfo(@intCast(ch))) |g| {
            x += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            x += font.cell_width;
        }
    }

    // Measure and draw hint below
    var hint_width: f32 = 0;
    for (hint) |ch| {
        if (font.getGlyphInfo(@intCast(ch))) |g| {
            hint_width += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            hint_width += font.cell_width;
        }
    }
    x = (window_width - hint_width) / 2;
    y = center_y - font.cell_height;
    const hint_color = [3]f32{ 0.3, 0.3, 0.3 };
    for (hint) |ch| {
        cell_renderer.renderChar(@intCast(ch), x, y, hint_color);
        if (font.getGlyphInfo(@intCast(ch))) |g| {
            x += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            x += font.cell_width;
        }
    }
}
