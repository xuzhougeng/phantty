//! File explorer sidebar renderer.
//!
//! Renders the right-side file explorer panel using the same OpenGL primitives
//! as the left tab sidebar (titlebar.zig). Uses gl_init.renderQuad for backgrounds
//! and titlebar.renderTextLimited / renderTitlebarChar for text.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const gl_init = AppWindow.gl_init;
const file_explorer = @import("../file_explorer.zig");
const win32_backend = @import("../apprt/win32.zig");
const c = @cImport({
    @cInclude("glad/gl.h");
});

fn blend(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

pub fn render(window_width: f32, window_height: f32, titlebar_h: f32) void {
    if (!file_explorer.g_visible) return;
    file_explorer.syncLayoutMetrics(font.g_titlebar_cell_height);
    const header_h = file_explorer.headerHeight();
    const row_h = file_explorer.rowHeight();
    const explorer_w = file_explorer.width();
    if (explorer_w <= 0) return;

    const gl = AppWindow.gl;
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const sidebar_bg = blend(bg, fg, 0.035);
    const border_color = blend(bg, .{ 0.0, 0.0, 0.0 }, 0.20);
    const header_text = blend(bg, fg, 0.84);
    const text_normal = blend(bg, fg, 0.88);
    const text_dir = AppWindow.g_theme.foreground;
    const hover_bg = blend(bg, fg, 0.09);
    const selected_bg = blend(bg, AppWindow.g_theme.cursor_color, 0.16);
    const accent = AppWindow.g_theme.cursor_color;

    const side_h = window_height - titlebar_h;
    if (side_h <= 0) return;

    const panel_x = window_width - explorer_w;

    // Background
    gl_init.renderQuad(panel_x, 0, explorer_w, side_h, sidebar_bg);

    // Left border (resize edge)
    const resize_hovered = blk: {
        const win = AppWindow.g_window orelse break :blk false;
        if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
        const mx: f32 = @floatFromInt(win.mouse_x);
        const my: f32 = @floatFromInt(win.mouse_y);
        const half_hit = file_explorer.RESIZE_HIT_WIDTH / 2;
        break :blk mx >= panel_x - half_hit and mx <= panel_x + half_hit and my >= titlebar_h and my < window_height;
    };
    const edge_color = if (resize_hovered) blend(bg, accent, 0.38) else border_color;
    gl_init.renderQuad(panel_x, 0, if (resize_hovered) 2 else 1, side_h, edge_color);

    // Header with mode indicator
    const header_y = window_height - titlebar_h - header_h;
    const mode_label = if (file_explorer.g_mode == .remote) "REMOTE" else "LOCAL";
    const mode_color = if (file_explorer.g_mode == .remote) accent else header_text;
    const header_text_y = header_y + (header_h - font.g_titlebar_cell_height) / 2;
    const label_end = titlebar.renderTextLimited(mode_label, panel_x + 12, header_text_y, mode_color, explorer_w - 24);
    _ = titlebar.renderTextLimited(" Explorer", label_end, header_text_y, header_text, explorer_w - (label_end - panel_x) - 12);
    gl_init.renderQuad(panel_x, header_y, explorer_w, 1, border_color);

    // File entries
    const list_top_px = titlebar_h + header_h;
    const visible_height = window_height - list_top_px;
    const scroll = file_explorer.g_scroll_offset;

    var i: usize = 0;
    while (i < file_explorer.g_entry_count) : (i += 1) {
        const row_y_from_top = @as(f32, @floatFromInt(i)) * row_h - scroll;
        if (row_y_from_top + row_h < 0) continue;
        if (row_y_from_top >= visible_height) break;

        const row_top_px = list_top_px + row_y_from_top;
        const row_y = window_height - row_top_px - row_h;

        const entry = &file_explorer.g_entries[i];
        const indent = @as(f32, @floatFromInt(entry.depth)) * file_explorer.INDENT_WIDTH;

        // Hover detection
        const row_hovered = blk: {
            const win = AppWindow.g_window orelse break :blk false;
            if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
            const mx: f32 = @floatFromInt(win.mouse_x);
            const my: f32 = @floatFromInt(win.mouse_y);
            break :blk mx >= panel_x and mx < panel_x + explorer_w and my >= row_top_px and my < row_top_px + row_h;
        };

        const is_selected = if (file_explorer.g_selected) |sel| sel == i else false;

        if (is_selected) {
            gl_init.renderQuad(panel_x, row_y, explorer_w, row_h, selected_bg);
        } else if (row_hovered) {
            gl_init.renderQuad(panel_x, row_y, explorer_w, row_h, hover_bg);
        }

        // Expand/collapse indicator for directories
        const text_x = panel_x + 8 + indent;
        const text_y = row_y + (row_h - font.g_titlebar_cell_height) / 2;

        // When renaming this entry, show input buffer instead of name
        const is_renaming = is_selected and file_explorer.g_op_mode == .rename;

        if (entry.is_dir) {
            const arrow: u32 = if (entry.expanded) 0x25BE else 0x25B8; // ▾ or ▸
            titlebar.renderTitlebarChar(arrow, text_x, text_y, text_dir);
            if (is_renaming) {
                renderInputField(text_x + 14, text_y, explorer_w - indent - 34, fg, accent);
            } else {
                _ = titlebar.renderTextLimited(
                    entry.name_buf[0..entry.name_len],
                    text_x + 14,
                    text_y,
                    text_dir,
                    explorer_w - indent - 34,
                );
            }
        } else {
            if (is_renaming) {
                renderInputField(text_x + 14, text_y, explorer_w - indent - 34, fg, accent);
            } else {
                _ = titlebar.renderTextLimited(
                    entry.name_buf[0..entry.name_len],
                    text_x + 14,
                    text_y,
                    text_normal,
                    explorer_w - indent - 34,
                );
            }
        }
    }

    if (file_explorer.g_loading and file_explorer.g_entry_count == 0) {
        const row_y = window_height - list_top_px - row_h;
        const ty = row_y + (row_h - font.g_titlebar_cell_height) / 2;
        const prefix_end = titlebar.renderTextLimited("Loading: ", panel_x + 8, ty, accent, explorer_w - 16);
        _ = titlebar.renderTextLimited(file_explorer.g_loading_msg[0..file_explorer.g_loading_msg_len], prefix_end, ty, text_normal, explorer_w - (prefix_end - panel_x) - 8);
    }

    // Render new file/dir input or delete confirmation at bottom of list
    if (file_explorer.g_op_mode == .new_file or file_explorer.g_op_mode == .new_dir) {
        const new_row_top = list_top_px + @as(f32, @floatFromInt(file_explorer.g_entry_count)) * row_h - scroll;
        if (new_row_top >= 0 and new_row_top < visible_height) {
            const new_row_y = window_height - new_row_top - row_h;
            gl_init.renderQuad(panel_x, new_row_y, explorer_w, row_h, selected_bg);
            const label = if (file_explorer.g_op_mode == .new_dir) "New folder: " else "New file: ";
            const input_y = new_row_y + (row_h - font.g_titlebar_cell_height) / 2;
            const op_label_end = titlebar.renderTextLimited(label, panel_x + 8, input_y, header_text, explorer_w - 16);
            renderInputField(op_label_end + 2, input_y, explorer_w - (op_label_end - panel_x) - 10, fg, accent);
        }
    } else if (file_explorer.g_op_mode == .confirm_delete) {
        const del_row_top = list_top_px + @as(f32, @floatFromInt(file_explorer.g_entry_count)) * row_h - scroll;
        if (del_row_top >= 0 and del_row_top < visible_height) {
            const del_row_y = window_height - del_row_top - row_h;
            const warn_bg = blend(bg, .{ 0.8, 0.2, 0.2 }, 0.2);
            gl_init.renderQuad(panel_x, del_row_y, explorer_w, row_h, warn_bg);
            _ = titlebar.renderTextLimited("Delete? Enter=yes Esc=no", panel_x + 8, del_row_y + (row_h - font.g_titlebar_cell_height) / 2, fg, explorer_w - 16);
        }
    }

    // Transfer status bar at bottom of panel (auto-hides after 5 seconds)
    if (file_explorer.g_loading) {
        const status_h: f32 = @max(24, font.g_titlebar_cell_height + 8);
        const status_y: f32 = 0;
        gl_init.renderQuad(panel_x, status_y, explorer_w, status_h, blend(bg, accent, 0.15));
        const ty = status_y + (status_h - font.g_titlebar_cell_height) / 2;
        const prefix_end = titlebar.renderTextLimited("Loading: ", panel_x + 8, ty, accent, explorer_w - 16);
        _ = titlebar.renderTextLimited(file_explorer.g_loading_msg[0..file_explorer.g_loading_msg_len], prefix_end, ty, fg, explorer_w - (prefix_end - panel_x) - 8);
    } else if (file_explorer.g_transfer_status != .idle) {
        const now = std.time.milliTimestamp();
        const elapsed = now - file_explorer.g_transfer_time;
        if (elapsed < 5000 or file_explorer.g_transfer_status == .in_progress) {
            const status_h: f32 = @max(24, font.g_titlebar_cell_height + 8);
            const status_y: f32 = 0; // bottom of panel (GL y=0)
            const status_bg_color = switch (file_explorer.g_transfer_status) {
                .in_progress => blend(bg, accent, 0.15),
                .success => blend(bg, .{ 0.2, 0.8, 0.2 }, 0.15),
                .failed => blend(bg, .{ 0.8, 0.2, 0.2 }, 0.15),
                .idle => unreachable,
            };
            gl_init.renderQuad(panel_x, status_y, explorer_w, status_h, status_bg_color);

            const prefix = switch (file_explorer.g_transfer_status) {
                .in_progress => "Transferring: ",
                .success => "Done: ",
                .failed => "Failed: ",
                .idle => unreachable,
            };
            const status_text_color = switch (file_explorer.g_transfer_status) {
                .in_progress => accent,
                .success => blend(bg, .{ 0.2, 0.9, 0.2 }, 0.9),
                .failed => blend(bg, .{ 0.9, 0.2, 0.2 }, 0.9),
                .idle => unreachable,
            };
            const ty = status_y + (status_h - font.g_titlebar_cell_height) / 2;
            const prefix_end = titlebar.renderTextLimited(prefix, panel_x + 8, ty, status_text_color, explorer_w - 16);
            _ = titlebar.renderTextLimited(file_explorer.g_transfer_msg[0..file_explorer.g_transfer_msg_len], prefix_end, ty, fg, explorer_w - (prefix_end - panel_x) - 8);
        } else {
            // Auto-hide after timeout
            file_explorer.g_transfer_status = .idle;
        }
    }
}

fn renderInputField(x: f32, y: f32, max_w: f32, text_color: [3]f32, cursor_color: [3]f32) void {
    const text = file_explorer.g_input_buf[0..file_explorer.g_input_len];
    const text_end = titlebar.renderTextLimited(text, x, y, text_color, max_w);
    // Blinking cursor
    const now = std.time.milliTimestamp();
    if (@mod(@divTrunc(now, 530), 2) == 0) {
        const font_mod = @import("../font/manager.zig");
        gl_init.renderQuad(text_end + 1, y, 1, font_mod.g_titlebar_cell_height, cursor_color);
    }
}
