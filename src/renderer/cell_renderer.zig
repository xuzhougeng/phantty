//! Cell rendering pipeline for AppWindow.
//!
//! Owns the snapshot→rebuild→draw pipeline: reads terminal state under lock,
//! builds GPU cell buffers, and draws them. Also provides renderChar for
//! immediate-mode text rendering (UI overlays, placeholder text).
//! Uses AppWindow's GL context and shared rendering primitives.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Surface = @import("../Surface.zig");
const Renderer = @import("Renderer.zig");
const AppWindow = @import("../AppWindow.zig");
const font = AppWindow.font;
const tab = AppWindow.tab;
const gl_init = AppWindow.gl_init;

const c = @cImport({
    @cInclude("glad/gl.h");
});

const Character = font.Character;
const Selection = Surface.Selection;

// ============================================================================
// State
// ============================================================================

/// Current surface being rendered (for per-surface selection)
pub threadlocal var g_current_render_surface: ?*Surface = null;

// ============================================================================
// Public API
// ============================================================================

/// Render a single character at the given position using the text shader.
/// Used for UI text (placeholder messages, overlays), not terminal cells.
pub fn renderChar(codepoint: u32, x: f32, y: f32, color: [3]f32) void {
    const gl = AppWindow.gl;

    // Skip control characters
    if (codepoint < 32) return;

    // Get character from cache (load on-demand if needed)
    const ch: Character = font.loadGlyph(codepoint) orelse return;
    if (ch.region.width == 0 or ch.region.height == 0) return;

    // Position glyph relative to baseline (like Ghostty)
    const x0 = x + @as(f32, @floatFromInt(ch.bearing_x));
    const y0 = y + font.cell_baseline - @as(f32, @floatFromInt(ch.size_y - ch.bearing_y));
    const w = @as(f32, @floatFromInt(ch.size_x));
    const h = @as(f32, @floatFromInt(ch.size_y));

    // Compute atlas UVs from region
    const atlas_size = if (font.g_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = font.glyphUV(ch.region, atlas_size);

    const vertices = [6][4]f32{
        .{ x0, y0 + h, uv.u0, uv.v0 },
        .{ x0, y0, uv.u0, uv.v1 },
        .{ x0 + w, y0, uv.u1, uv.v1 },
        .{ x0, y0 + h, uv.u0, uv.v0 },
        .{ x0 + w, y0, uv.u1, uv.v1 },
        .{ x0 + w, y0 + h, uv.u1, uv.v0 },
    };

    gl.Uniform3f.?(gl.GetUniformLocation.?(gl_init.shader_program, "textColor"), color[0], color[1], color[2]);
    gl.BindTexture.?(c.GL_TEXTURE_2D, font.g_atlas_texture);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, gl_init.vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); gl_init.g_draw_call_count += 1;
}

/// Update terminal cells for a specific surface in a split tree.
/// is_focused controls cursor appearance (unfocused shows block_hollow).
pub fn updateTerminalCellsForSurface(rend: *Renderer, terminal: *ghostty_vt.Terminal, is_focused: bool) bool {
    rend.is_focused = is_focused;
    return updateTerminalCells(rend, terminal);
}

/// Get the selection for the current surface being rendered.
/// Returns the focused surface's selection if no surface is set.
pub fn currentRenderSelection() *Selection {
    if (g_current_render_surface) |surface| {
        return &surface.selection;
    }
    return tab.activeSelection();
}

/// Read terminal state under the lock: dirty check, snapshot cells, cache cursor.
/// Returns true if cells need rebuilding (caller should call rebuildCells()
/// after releasing the lock). Modeled after Ghostty's split:
///   lock → RenderState.update() (snapshot) → unlock → rebuildCells()
pub fn updateTerminalCells(rend: *Renderer, terminal: *ghostty_vt.Terminal) bool {
    // If the application has enabled synchronized output (Mode 2026),
    // skip rendering entirely until the batch ends. This prevents
    // mid-update artifacts (e.g. fzf drawing its UI). Matches Ghostty's
    // renderer/generic.zig which returns early when synchronized_output is set.
    if (terminal.modes.get(.synchronized_output)) return false;

    const screen = terminal.screens.active;
    const viewport_active = screen.pages.viewport == .active;
    const selection_active = currentRenderSelection().active;
    const viewport_pin = screen.pages.getTopLeft(.viewport);

    const needs_rebuild = blk: {
        if (rend.force_rebuild) {
            rend.force_rebuild = false;
            break :blk true;
        }
        if (!rend.cells_valid) break :blk true;
        if (rend.cursor_blink_visible != rend.last_cursor_blink_visible) break :blk true;
        if (viewport_active != rend.last_viewport_active) break :blk true;
        if (terminal.rows != rend.last_rows or terminal.cols != rend.last_cols) break :blk true;
        if (selection_active != rend.last_selection_active) break :blk true;
        if (AppWindow.input.g_selecting) break :blk true;
        // Cursor position changed — need to rebuild so cursor bg is at the right cell
        if (screen.cursor.x != rend.last_cursor_x or
            @as(?*anyopaque, screen.cursor.page_pin.node) != rend.last_cursor_node or
            screen.cursor.page_pin.y != rend.last_cursor_pin_y) break :blk true;
        // Viewport pin changed — scroll happened (matches Ghostty's RenderState viewport_pin comparison)
        if (@as(?*anyopaque, viewport_pin.node) != rend.last_viewport_node or
            viewport_pin.y != rend.last_viewport_y) break :blk true;
        // Terminal-level dirty flags (eraseDisplay, fullReset, palette change, etc.)
        {
            const DirtyInt = @typeInfo(@TypeOf(terminal.flags.dirty)).@"struct".backing_integer.?;
            if (@as(DirtyInt, @bitCast(terminal.flags.dirty)) > 0) break :blk true;
        }
        // Screen-level dirty flags (selection, hyperlink hover)
        {
            const ScreenDirtyInt = @typeInfo(@TypeOf(screen.dirty)).@"struct".backing_integer.?;
            if (@as(ScreenDirtyInt, @bitCast(screen.dirty)) > 0) break :blk true;
        }
        // Per-row/page dirty flags (set by VT parser on cell changes)
        var dirty_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        while (dirty_it.next()) |row_pin| {
            const rac = row_pin.rowAndCell();
            if (rac.row.dirty or row_pin.node.data.dirty) break :blk true;
        }
        break :blk false;
    };

    // Always cache cursor state for drawing outside the lock.
    // When viewport is at bottom (showing active area), cursor.y is in active coordinates
    // which matches viewport coordinates. When scrolled up, cursor is not visible.
    rend.cached_viewport_at_bottom = screen.pages.viewport == .active;
    rend.cached_cursor_x = screen.cursor.x;
    rend.cached_cursor_y = screen.cursor.y;


    rend.cached_cursor_visible = terminal.modes.get(.cursor_visible);
    const tcs: Renderer.CursorStyle = switch (screen.cursor.cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    rend.cached_cursor_effective = cursorEffectiveStyleForRenderer(rend, tcs, terminal.modes.get(.cursor_blinking));
    if (rend.cached_cursor_effective) |eff| {
        rend.cached_cursor_style = eff;
    }

    if (needs_rebuild) {
        // Snapshot cell data under the lock — fast memcpy of resolved colors
        // and codepoints. Like Ghostty's RenderState.update() fastmem.copy.
        snapshotCells(rend, terminal);

        // Debug: check for cursor/content mismatch
        if (rend.cached_cursor_y >= rend.snap_rows and rend.snap_rows > 0) {
            std.log.warn("CURSOR MISMATCH: cursor_y={} snap_rows={} terminal.rows={} viewport={s}", .{
                rend.cached_cursor_y, rend.snap_rows, terminal.rows,
                if (screen.pages.viewport == .active) "active" else "pin",
            });
        }


        rend.cells_valid = true;
        rend.last_cursor_blink_visible = rend.cursor_blink_visible;
        rend.last_viewport_active = viewport_active;
        rend.last_viewport_node = viewport_pin.node;
        rend.last_viewport_y = viewport_pin.y;
        rend.last_cursor_node = screen.cursor.page_pin.node;
        rend.last_cursor_pin_y = screen.cursor.page_pin.y;
        rend.last_cursor_x = screen.cursor.x;
        rend.last_rows = terminal.rows;
        rend.last_cols = terminal.cols;
        rend.last_selection_active = selection_active;

        // Clear dirty flags after snapshot
        terminal.flags.dirty = .{};
        screen.dirty = .{};
        var clear_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        while (clear_it.next()) |row_pin| {
            row_pin.rowAndCell().row.dirty = false;
        }
    }

    return needs_rebuild;
}

/// Build GPU cell buffers from the snapshot. Does NOT require the terminal
/// mutex — reads from rend.snap which was filled by snapshotCells.
pub fn rebuildCells(rend: *Renderer) void {
    const render_rows = rend.snap_rows;
    const render_cols = rend.snap_cols;
    const atlas_size = if (font.g_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const color_atlas_size = if (font.g_color_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const g_theme = AppWindow.g_theme;

    rend.bg_cell_count = 0;
    rend.fg_cell_count = 0;
    rend.color_fg_cell_count = 0;

    for (0..render_rows) |row_idx| {
        const row_f: f32 = @floatFromInt(row_idx);
        const row_base = row_idx * render_cols;

        var skip_next_ri = false;
        for (0..render_cols) |col_idx| {
            const snap_idx = row_base + col_idx;
            if (snap_idx >= Renderer.MAX_CELLS) break;
            const sc = rend.snap[snap_idx];

            const is_cursor = rend.cached_viewport_at_bottom and (col_idx == rend.cached_cursor_x and row_idx == rend.cached_cursor_y);
            const is_selected = isCellSelected(col_idx, row_idx);
            const col_f: f32 = @floatFromInt(col_idx);

            var fg_color = sc.fg;

            if (is_cursor and rend.cached_cursor_visible) {
                // Block cursor: invert fg for text under cursor (bg drawn by overlay)
                if (rend.cached_cursor_effective) |effective_style| {
                    if (effective_style == .block) {
                        fg_color = g_theme.cursor_text orelse g_theme.background;
                    }
                }
                // Draw cell background normally (cursor shape drawn by overlay)
                if (sc.bg) |bg| {
                    if (rend.bg_cell_count < Renderer.MAX_CELLS) {
                        rend.bg_cells[rend.bg_cell_count] = .{ .grid_col = col_f, .grid_row = row_f, .r = bg[0], .g = bg[1], .b = bg[2] };
                        rend.bg_cell_count += 1;
                    }
                }
            } else if (is_selected) {
                if (rend.bg_cell_count < Renderer.MAX_CELLS) {
                    rend.bg_cells[rend.bg_cell_count] = .{ .grid_col = col_f, .grid_row = row_f, .r = g_theme.selection_background[0], .g = g_theme.selection_background[1], .b = g_theme.selection_background[2] };
                    rend.bg_cell_count += 1;
                }
                fg_color = g_theme.selection_foreground orelse g_theme.foreground;
            } else if (sc.bg) |bg| {
                if (rend.bg_cell_count < Renderer.MAX_CELLS) {
                    rend.bg_cells[rend.bg_cell_count] = .{ .grid_col = col_f, .grid_row = row_f, .r = bg[0], .g = bg[1], .b = bg[2] };
                    rend.bg_cell_count += 1;
                }
            }

            // Skip spacer cells — the wide character's head cell handles rendering
            // across both cells (like Ghostty).
            if (sc.wide == .spacer_tail or sc.wide == .spacer_head) continue;

            // Skip the second regional indicator in a composed pair
            if (skip_next_ri) {
                skip_next_ri = false;
                continue;
            }

            const char = sc.codepoint;
            if (char != 0 and char != ' ') {
                // Track if we composed a regional indicator pair (for 2-cell width)
                var composed_ri_pair = false;

                // Use HarfBuzz shaping for grapheme clusters (multi-codepoint emoji),
                // fall back to single-codepoint lookup for regular characters.
                const maybe_ch: ?Character = if (sc.grapheme_len > 0)
                    font.loadGraphemeGlyph(char, sc.grapheme[0..sc.grapheme_len])
                else if (font.isRegionalIndicator(char)) ri: {
                    // Regional indicator without grapheme data — check if a following cell
                    // is also an RI and compose them into a flag pair for shaping.
                    // This handles the case where grapheme_cluster mode isn't active.
                    // Check +1 (narrow RI) and +2 (wide RI with spacer_tail at +1).
                    const offsets = [_]usize{ 1, 2 };
                    for (offsets) |off| {
                        const next_snap_idx = row_base + col_idx + off;
                        if (next_snap_idx < Renderer.MAX_CELLS and col_idx + off < render_cols) {
                            const next_sc = rend.snap[next_snap_idx];
                            if (font.isRegionalIndicator(next_sc.codepoint)) {
                                const extras = [1]u21{next_sc.codepoint};
                                const result = font.loadGraphemeGlyph(char, &extras);
                                if (result != null) {
                                    composed_ri_pair = true;
                                    skip_next_ri = true;
                                }
                                break :ri result;
                            }
                        }
                    }
                    break :ri font.loadGlyph(char);
                } else font.loadGlyph(char);
                if (maybe_ch) |ch| {
                    if (ch.region.width > 0 and ch.region.height > 0) {
                        // Wide characters (emoji) span 2 cells; narrow = 1 cell.
                        // Composed RI pairs also span 2 cells.
                        const grid_width: f32 = if (sc.wide == .wide or composed_ri_pair) 2.0 else 1.0;
                        if (ch.is_color) {
                            // Color emoji — route to separate color cell buffer.
                            // Scale the emoji bitmap to fit within grid_width cells, preserving aspect ratio.
                            const emoji_w = @as(f32, @floatFromInt(ch.size_x));
                            const emoji_h = @as(f32, @floatFromInt(ch.size_y));
                            const target_w = font.cell_width * grid_width;
                            const scale = @min(target_w / emoji_w, font.cell_height / emoji_h);
                            const gw = emoji_w * scale;
                            const gh = emoji_h * scale;
                            // Center within the grid_width cells
                            const gx = (target_w - gw) / 2.0;
                            const gy = (font.cell_height - gh) / 2.0;
                            const uv_val = font.glyphUV(ch.region, color_atlas_size);
                            if (rend.color_fg_cell_count < Renderer.MAX_CELLS) {
                                rend.color_fg_cells[rend.color_fg_cell_count] = .{
                                    .grid_col = col_f,
                                    .grid_row = row_f,
                                    .glyph_x = gx,
                                    .glyph_y = gy,
                                    .glyph_w = gw,
                                    .glyph_h = gh,
                                    .uv_left = uv_val.u0,
                                    .uv_top = uv_val.v0,
                                    .uv_right = uv_val.u1,
                                    .uv_bottom = uv_val.v1,
                                    .r = fg_color[0],
                                    .g = fg_color[1],
                                    .b = fg_color[2],
                                };
                                rend.color_fg_cell_count += 1;
                            }
                        } else {
                            // Grayscale text glyph
                            const uv_val = font.glyphUV(ch.region, atlas_size);
                            const gx = @as(f32, @floatFromInt(ch.bearing_x));
                            const gy = font.cell_baseline - @as(f32, @floatFromInt(@as(i32, @intCast(ch.size_y)) - ch.bearing_y));
                            const gw = @as(f32, @floatFromInt(ch.size_x));
                            const gh = @as(f32, @floatFromInt(ch.size_y));
                            if (rend.fg_cell_count < Renderer.MAX_CELLS) {
                                rend.fg_cells[rend.fg_cell_count] = .{
                                    .grid_col = col_f,
                                    .grid_row = row_f,
                                    .glyph_x = gx,
                                    .glyph_y = gy,
                                    .glyph_w = gw,
                                    .glyph_h = gh,
                                    .uv_left = uv_val.u0,
                                    .uv_top = uv_val.v0,
                                    .uv_right = uv_val.u1,
                                    .uv_bottom = uv_val.v1,
                                    .r = fg_color[0],
                                    .g = fg_color[1],
                                    .b = fg_color[2],
                                };
                                rend.fg_cell_count += 1;
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Draw terminal grid from CPU cell buffers. Does NOT require the terminal
/// mutex — all terminal state was already read by updateTerminalCells().
pub fn drawCells(rend: *const Renderer, window_height: f32, offset_x: f32, offset_y: f32) void {
    const gl = AppWindow.gl;
    const g_theme = AppWindow.g_theme;

    // --- Draw BG cells ---
    if (rend.bg_cell_count > 0 and gl_init.bg_shader != 0) {
        gl.UseProgram.?(gl_init.bg_shader);
        gl.Uniform2f.?(gl.GetUniformLocation.?(gl_init.bg_shader, "cellSize"), font.cell_width, font.cell_height);
        gl.Uniform2f.?(gl.GetUniformLocation.?(gl_init.bg_shader, "gridOffset"), offset_x, offset_y);
        gl.Uniform1f.?(gl.GetUniformLocation.?(gl_init.bg_shader, "windowHeight"), window_height);
        gl_init.setProjectionForProgram(gl_init.bg_shader, window_height);

        gl.BindVertexArray.?(gl_init.bg_vao);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, gl_init.bg_instance_vbo);
        gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @intCast(@sizeOf(Renderer.CellBg) * rend.bg_cell_count), &rend.bg_cells);
        gl.DrawArraysInstanced.?(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(rend.bg_cell_count)); gl_init.g_draw_call_count += 1;
    }

    // --- Draw FG cells ---
    if (rend.fg_cell_count > 0 and gl_init.fg_shader != 0) {
        gl.UseProgram.?(gl_init.fg_shader);
        gl.Uniform2f.?(gl.GetUniformLocation.?(gl_init.fg_shader, "cellSize"), font.cell_width, font.cell_height);
        gl.Uniform2f.?(gl.GetUniformLocation.?(gl_init.fg_shader, "gridOffset"), offset_x, offset_y);
        gl.Uniform1f.?(gl.GetUniformLocation.?(gl_init.fg_shader, "windowHeight"), window_height);
        gl_init.setProjectionForProgram(gl_init.fg_shader, window_height);

        gl.ActiveTexture.?(c.GL_TEXTURE0);
        gl.BindTexture.?(c.GL_TEXTURE_2D, font.g_atlas_texture);
        gl.Uniform1i.?(gl.GetUniformLocation.?(gl_init.fg_shader, "atlas"), 0);

        gl.BindVertexArray.?(gl_init.fg_vao);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, gl_init.fg_instance_vbo);
        gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @intCast(@sizeOf(Renderer.CellFg) * rend.fg_cell_count), &rend.fg_cells);
        gl.DrawArraysInstanced.?(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(rend.fg_cell_count)); gl_init.g_draw_call_count += 1;
    }

    // --- Draw color emoji cells ---
    // Color emoji use premultiplied alpha, so we switch blend mode to (ONE, ONE_MINUS_SRC_ALPHA)
    // for this pass, then restore the normal blend mode afterwards.
    if (rend.color_fg_cell_count > 0 and gl_init.color_fg_shader != 0) {
        gl.BlendFunc.?(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);

        gl.UseProgram.?(gl_init.color_fg_shader);
        gl.Uniform2f.?(gl.GetUniformLocation.?(gl_init.color_fg_shader, "cellSize"), font.cell_width, font.cell_height);
        gl.Uniform2f.?(gl.GetUniformLocation.?(gl_init.color_fg_shader, "gridOffset"), offset_x, offset_y);
        gl.Uniform1f.?(gl.GetUniformLocation.?(gl_init.color_fg_shader, "windowHeight"), window_height);
        gl_init.setProjectionForProgram(gl_init.color_fg_shader, window_height);

        gl.ActiveTexture.?(c.GL_TEXTURE0);
        gl.BindTexture.?(c.GL_TEXTURE_2D, font.g_color_atlas_texture);
        gl.Uniform1i.?(gl.GetUniformLocation.?(gl_init.color_fg_shader, "atlas"), 0);

        gl.BindVertexArray.?(gl_init.color_fg_vao);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, gl_init.color_fg_instance_vbo);
        gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @intCast(@sizeOf(Renderer.CellFg) * rend.color_fg_cell_count), &rend.color_fg_cells);
        gl.DrawArraysInstanced.?(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(rend.color_fg_cell_count)); gl_init.g_draw_call_count += 1;

        // Restore normal blend mode for subsequent draws (cursor, titlebar, etc.)
        gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    }

    // --- Cursor overlay from cached state ---
    if (rend.cached_viewport_at_bottom and rend.cached_cursor_visible) {
        // Use the pre-computed effective cursor style which already factors in
        // window focus, tab rename, split focus, and blink state.
        if (rend.cached_cursor_effective) |style| {
            const px = offset_x + @as(f32, @floatFromInt(rend.cached_cursor_x)) * font.cell_width;
            const py = window_height - offset_y - ((@as(f32, @floatFromInt(rend.cached_cursor_y)) + 1) * font.cell_height);

            gl.UseProgram.?(gl_init.shader_program);
            gl.BindVertexArray.?(gl_init.vao);

            const cursor_color = g_theme.cursor_color;
            const cursor_thickness: f32 = 1.0;

            switch (style) {
                .bar => gl_init.renderQuad(px, py, cursor_thickness, font.cell_height, cursor_color),
                .underline => gl_init.renderQuad(px, py, font.cell_width, cursor_thickness, cursor_color),
                .block_hollow => {
                    gl_init.renderQuad(px, py, font.cell_width, font.cell_height, cursor_color);
                    gl_init.renderQuad(
                        px + cursor_thickness,
                        py + cursor_thickness,
                        font.cell_width - cursor_thickness * 2,
                        font.cell_height - cursor_thickness * 2,
                        g_theme.background,
                    );
                },
                .block => gl_init.renderQuad(px, py, font.cell_width, font.cell_height, cursor_color),
            }
        }
    }

    gl.BindVertexArray.?(0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, 0);
}

/// Check if a cell is within the current selection.
/// `col` and `row` are screen-relative (viewport) coordinates.
/// Selection rows are stored as absolute scrollback positions.
pub fn isCellSelected(col: usize, row: usize) bool {
    const selection = currentRenderSelection();
    if (!selection.active) return false;

    // Convert screen row to absolute
    const vp_off = AppWindow.input.viewportOffset();
    const abs_row = vp_off + row;

    var start_row = selection.start_row;
    var start_col = selection.start_col;
    var end_row = selection.end_row;
    var end_col = selection.end_col;

    // Normalize
    if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
        std.mem.swap(usize, &start_row, &end_row);
        std.mem.swap(usize, &start_col, &end_col);
    }

    if (abs_row < start_row or abs_row > end_row) return false;
    if (abs_row == start_row and abs_row == end_row) {
        return col >= start_col and col <= end_col;
    }
    if (abs_row == start_row) return col >= start_col;
    if (abs_row == end_row) return col <= end_col;
    return true;
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Determine effective cursor style (factoring in blink, focus, and split focus).
/// Returns null during blink-off phase (cursor hidden).
/// This version uses per-surface renderer state.
fn cursorEffectiveStyleForRenderer(rend: *const Renderer, terminal_style: Renderer.CursorStyle, terminal_blink: bool) ?Renderer.CursorStyle {
    // Hide cursor during active resize to avoid flicker artifacts
    if (AppWindow.overlays.g_resize_active) return null;
    // Unfocused window or tab rename: show hollow block
    if (!AppWindow.window_focused or tab.g_tab_rename_active) return .block_hollow;
    // Unfocused split: show hollow block (no blinking)
    if (!rend.is_focused) return .block_hollow;
    const should_blink = terminal_blink and AppWindow.g_cursor_blink;
    if (should_blink and !rend.cursor_blink_visible) return null;
    return terminal_style;
}

/// Snapshot terminal cell data under the lock. Resolves colors and codepoints
/// into a flat buffer so rebuildCells can run outside the lock.
/// Modeled after Ghostty's RenderState.update() which copies row data via
/// fastmem.copy under the lock, then releases it for the renderer.
fn snapshotCells(rend: *Renderer, terminal: *ghostty_vt.Terminal) void {
    const g_theme = AppWindow.g_theme;
    const screen = terminal.screens.active;
    const render_cols = terminal.cols;

    rend.snap_cols = render_cols;

    var row_it = screen.pages.rowIterator(
        .right_down,
        .{ .viewport = .{} },
        null,
    );
    var row_idx: usize = 0;
    while (row_it.next()) |row_pin| {
        const p = &row_pin.node.data;
        const rac = row_pin.rowAndCell();
        const page_cells = p.getCells(rac.row);
        const num_cols = @min(page_cells.len, render_cols);
        const row_base = row_idx * render_cols;

        for (0..num_cols) |col_idx| {
            const cell = &page_cells[col_idx];
            var fg_color: [3]f32 = g_theme.foreground;
            var bg_color: ?[3]f32 = null;

            switch (cell.content_tag) {
                .bg_color_palette => bg_color = font.indexToRgb(cell.content.color_palette),
                .bg_color_rgb => {
                    const rgb = cell.content.color_rgb;
                    bg_color = .{
                        @as(f32, @floatFromInt(rgb.r)) / 255.0,
                        @as(f32, @floatFromInt(rgb.g)) / 255.0,
                        @as(f32, @floatFromInt(rgb.b)) / 255.0,
                    };
                },
                else => {},
            }

            if (cell.hasStyling()) {
                const style = p.styles.get(p.memory, cell.style_id);
                switch (style.fg_color) {
                    .none => {},
                    .palette => |idx| fg_color = font.indexToRgb(idx),
                    .rgb => |rgb| fg_color = .{
                        @as(f32, @floatFromInt(rgb.r)) / 255.0,
                        @as(f32, @floatFromInt(rgb.g)) / 255.0,
                        @as(f32, @floatFromInt(rgb.b)) / 255.0,
                    },
                }
                switch (style.bg_color) {
                    .none => {},
                    .palette => |idx| bg_color = font.indexToRgb(idx),
                    .rgb => |rgb| bg_color = .{
                        @as(f32, @floatFromInt(rgb.r)) / 255.0,
                        @as(f32, @floatFromInt(rgb.g)) / 255.0,
                        @as(f32, @floatFromInt(rgb.b)) / 255.0,
                    },
                }
            }

            if (row_base + col_idx < Renderer.MAX_CELLS) {
                var snap: Renderer.SnapCell = .{
                    .codepoint = cell.codepoint(),
                    .fg = fg_color,
                    .bg = bg_color,
                    .wide = @enumFromInt(@intFromEnum(cell.wide)),
                };

                // Store grapheme cluster data for multi-codepoint sequences
                // (emoji with skin tones, flags, ZWJ sequences, VS16, etc.)
                if (cell.hasGrapheme()) {
                    if (p.lookupGrapheme(cell)) |extra_cps| {
                        const len = @min(extra_cps.len, 8); // MAX_GRAPHEME
                        for (0..len) |gi| {
                            snap.grapheme[gi] = extra_cps[gi];
                        }
                        snap.grapheme_len = @intCast(len);
                    }
                }

                rend.snap[row_base + col_idx] = snap;
            }
        }
        row_idx += 1;
    }
    rend.snap_rows = row_idx;
}
