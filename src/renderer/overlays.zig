//! Overlay rendering for AppWindow.
//!
//! Scrollbar (macOS-style overlay with fade), resize overlay ("cols x rows"),
//! debug overlays (FPS, draw calls), split dividers, and unfocused split overlays.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const tab = AppWindow.tab;
const gl_init = AppWindow.gl_init;
const split_layout = AppWindow.split_layout;
const Surface = @import("../Surface.zig");
const SplitTree = @import("../split_tree.zig");
const Config = @import("../config.zig");
const win32_backend = @import("../apprt/win32.zig");

const c = @cImport({
    @cInclude("glad/gl.h");
});

const TabState = tab.TabState;
const SplitRect = split_layout.SplitRect;

// ============================================================================
// Scrollbar — macOS-style overlay scrollbar with fade
// ============================================================================

pub const SCROLLBAR_WIDTH: f32 = 12; // Width of the scrollbar track
const SCROLLBAR_MARGIN: f32 = 2; // Margin from right edge
const SCROLLBAR_MIN_THUMB: f32 = 20; // Minimum thumb height in pixels
const SCROLLBAR_FADE_DELAY_MS: i64 = 800; // ms to wait before fading
const SCROLLBAR_FADE_DURATION_MS: i64 = 400; // ms for fade-out animation
const SCROLLBAR_HOVER_WIDTH: f32 = 12; // Wider hit area for hover/drag

// Per-surface scrollbar opacity/timing lives in Surface.zig.
// These are global interaction state (only one mouse):
pub threadlocal var g_scrollbar_hover: bool = false; // Mouse is over scrollbar area
pub threadlocal var g_scrollbar_dragging: bool = false; // Currently dragging the thumb
pub threadlocal var g_scrollbar_drag_offset: f32 = 0; // Offset within thumb where drag started

// ============================================================================
// Split divider rendering
// ============================================================================

const SPLIT_DIVIDER_WIDTH = tab.SPLIT_DIVIDER_WIDTH;

/// Unfocused split opacity (default 0.7, configurable)
pub threadlocal var g_unfocused_split_opacity: f32 = 0.7;

/// Split divider color (null = use scrollbar style with alpha)
pub threadlocal var g_split_divider_color: ?[3]f32 = null;

// Split resize overlay (for equalize/keyboard resize - shows overlay on all splits temporarily)
pub threadlocal var g_split_resize_overlay_until: i64 = 0; // Timestamp when overlay should hide

// ============================================================================
// Resize overlay — shows terminal size during resize (like Ghostty)
// ============================================================================

pub const RESIZE_OVERLAY_DURATION_MS: i64 = 750; // How long to show after resize stops
const RESIZE_OVERLAY_FADE_MS: i64 = 150; // Fade out duration
const RESIZE_OVERLAY_FIRST_DELAY_MS: i64 = 500; // Delay before first overlay shows

// Global resize overlay state
pub threadlocal var g_resize_overlay_visible: bool = false; // Whether overlay should be showing
threadlocal var g_resize_overlay_last_change: i64 = 0; // When size last changed
threadlocal var g_resize_overlay_cols: u16 = 0; // Current cols being displayed
threadlocal var g_resize_overlay_rows: u16 = 0; // Current rows being displayed
threadlocal var g_resize_overlay_last_cols: u16 = 0; // Last "settled" cols (after timeout)
threadlocal var g_resize_overlay_last_rows: u16 = 0; // Last "settled" rows (after timeout)
threadlocal var g_resize_overlay_ready: bool = false; // Set after initial delay
threadlocal var g_resize_overlay_init_time: i64 = 0; // When window was created
pub threadlocal var g_resize_overlay_opacity: f32 = 0; // For fade out animation

// Resize active state (for cursor hiding) - separate from overlay visibility
const RESIZE_ACTIVE_TIMEOUT_MS: i64 = 50; // Consider resize "done" after this many ms of no changes
pub threadlocal var g_resize_active: bool = false; // True while actively resizing

// Suppress resize overlay briefly after tab switch/creation to avoid false triggers
pub threadlocal var g_resize_overlay_suppress_until: i64 = 0;
// ============================================================================
// Startup shortcuts overlay
// ============================================================================

const STARTUP_SHORTCUTS_DURATION_MS: i64 = 12000;
const STARTUP_SHORTCUTS_FADE_MS: i64 = 800;

const StartupShortcut = struct {
    keys: []const u8,
    action: []const u8,
};

const STARTUP_SHORTCUT_ENTRIES = [_]StartupShortcut{
    .{ .keys = "Ctrl+Shift+P", .action = "Command center" },
    .{ .keys = "Ctrl+Shift+T", .action = "New session" },
    .{ .keys = "Ctrl+Shift+B", .action = "Toggle sidebar" },
    .{ .keys = "Ctrl+W", .action = "Close panel / tab" },
    .{ .keys = "Ctrl+Shift+O", .action = "Split right" },
    .{ .keys = "Ctrl+Shift+E", .action = "Split down" },
    .{ .keys = "Ctrl+Shift+[ / ]", .action = "Previous / next panel" },
    .{ .keys = "Ctrl+Alt+Arrows", .action = "Focus panel" },
    .{ .keys = "Ctrl+Shift+Z", .action = "Equalize panels" },
    .{ .keys = "Ctrl+Shift+C/V", .action = "Copy / paste" },
    .{ .keys = "Ctrl+,", .action = "Open config" },
    .{ .keys = "Ctrl++ / Ctrl+-", .action = "Font size" },
    .{ .keys = "Ctrl+Enter", .action = "Maximize / restore" },
};

pub threadlocal var g_startup_shortcuts_visible: bool = false;
threadlocal var g_startup_shortcuts_started_at: i64 = 0;

pub fn startupShortcutsShow() void {
    g_startup_shortcuts_visible = true;
    g_startup_shortcuts_started_at = std.time.milliTimestamp();
}

pub fn startupShortcutsDismiss() void {
    g_startup_shortcuts_visible = false;
}

// ============================================================================
// Command center
// ============================================================================

const COMMAND_PALETTE_FILTER_MAX = 64;
const COMMAND_PALETTE_MAX_VISIBLE_ROWS = 14;

const CommandAction = enum {
    new_tab,
    split_right,
    split_down,
    split_left,
    split_up,
    focus_previous,
    focus_next,
    equalize_splits,
    close_split_or_tab,
    toggle_sidebar,
    show_shortcuts,
    open_config,
    font_size_decrease,
    font_size_increase,
    toggle_maximize,
};

const CommandEntry = struct {
    title: []const u8,
    detail: []const u8,
    shortcut: []const u8,
    action: CommandAction,
};

const COMMAND_ENTRIES = [_]CommandEntry{
    .{ .title = "New Session", .detail = "Choose PowerShell, SSH, or WSL", .shortcut = "Ctrl+Shift+T", .action = .new_tab },
    .{ .title = "Split Right", .detail = "Create a panel to the right", .shortcut = "Ctrl+Shift+O", .action = .split_right },
    .{ .title = "Split Down", .detail = "Create a panel below", .shortcut = "Ctrl+Shift+E", .action = .split_down },
    .{ .title = "Split Left", .detail = "Create a panel to the left", .shortcut = "", .action = .split_left },
    .{ .title = "Split Up", .detail = "Create a panel above", .shortcut = "", .action = .split_up },
    .{ .title = "Previous Panel", .detail = "Move focus to the previous panel", .shortcut = "Ctrl+Shift+[", .action = .focus_previous },
    .{ .title = "Next Panel", .detail = "Move focus to the next panel", .shortcut = "Ctrl+Shift+]", .action = .focus_next },
    .{ .title = "Equalize Panels", .detail = "Reset split sizes in the current tab", .shortcut = "Ctrl+Shift+Z", .action = .equalize_splits },
    .{ .title = "Close Panel / Tab", .detail = "Close the focused panel, tab, or window", .shortcut = "Ctrl+W", .action = .close_split_or_tab },
    .{ .title = "Toggle Sidebar", .detail = "Show or hide the tab sidebar", .shortcut = "Ctrl+Shift+B", .action = .toggle_sidebar },
    .{ .title = "Keyboard Shortcuts", .detail = "Show the shortcut reference overlay", .shortcut = "Ctrl+Shift+P", .action = .show_shortcuts },
    .{ .title = "Open Config", .detail = "Open the Phantty config file", .shortcut = "Ctrl+,", .action = .open_config },
    .{ .title = "Decrease Font Size", .detail = "Make terminal text smaller", .shortcut = "Ctrl+-", .action = .font_size_decrease },
    .{ .title = "Increase Font Size", .detail = "Make terminal text larger", .shortcut = "Ctrl++", .action = .font_size_increase },
    .{ .title = "Toggle Maximize", .detail = "Maximize or restore the window", .shortcut = "Ctrl+Enter", .action = .toggle_maximize },
};

pub threadlocal var g_command_palette_visible: bool = false;
threadlocal var g_command_palette_selected: usize = 0;
threadlocal var g_command_palette_filter: [COMMAND_PALETTE_FILTER_MAX]u8 = undefined;
threadlocal var g_command_palette_filter_len: usize = 0;

const CommandPaletteLayout = struct {
    box_x: f32,
    box_top_px: f32,
    box_w: f32,
    box_h: f32,
    row_top_px: f32,
    row_h: f32,
};

pub fn commandPaletteVisible() bool {
    return g_command_palette_visible;
}

pub fn commandPaletteOpen() void {
    g_command_palette_visible = true;
    g_command_palette_selected = 0;
    g_command_palette_filter_len = 0;
    g_startup_shortcuts_visible = false;
}

pub fn commandPaletteClose() void {
    g_command_palette_visible = false;
    g_command_palette_filter_len = 0;
    g_command_palette_selected = 0;
}

pub fn commandPaletteToggle() void {
    if (g_command_palette_visible) {
        commandPaletteClose();
    } else {
        commandPaletteOpen();
    }
}

pub fn commandPaletteMove(delta: i32) void {
    const count = commandPaletteVisibleCount();
    if (count == 0) {
        g_command_palette_selected = 0;
        return;
    }

    const current: i32 = @intCast(g_command_palette_selected);
    const count_i: i32 = @intCast(count);
    var next = current + delta;
    while (next < 0) next += count_i;
    next = @mod(next, count_i);
    g_command_palette_selected = @intCast(next);
}

pub fn commandPaletteBackspace() void {
    if (g_command_palette_filter_len == 0) return;
    g_command_palette_filter_len -= 1;
    commandPaletteClampSelection();
}

pub fn commandPaletteClearFilter() void {
    g_command_palette_filter_len = 0;
    commandPaletteClampSelection();
}

pub fn commandPaletteInsertChar(codepoint: u21) void {
    if (codepoint < 0x20 or codepoint == 0x7f) return;
    if (g_command_palette_filter_len >= g_command_palette_filter.len) return;

    if (codepoint <= 0x7f) {
        g_command_palette_filter[g_command_palette_filter_len] = @intCast(codepoint);
        g_command_palette_filter_len += 1;
        commandPaletteClampSelection();
    }
}

pub fn commandPaletteExecuteSelected() void {
    const entry_index = commandPaletteSelectedEntryIndex() orelse return;
    const action = COMMAND_ENTRIES[entry_index].action;
    commandPaletteClose();
    executeCommand(action);
}

pub fn commandPaletteExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const entry_index = commandPaletteHitTest(xpos, ypos, window_width, window_height, top_offset) orelse return false;
    commandPaletteClose();
    executeCommand(COMMAND_ENTRIES[entry_index].action);
    return true;
}

pub fn commandPaletteContainsPoint(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const layout = commandPaletteLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    return x >= layout.box_x and x <= layout.box_x + layout.box_w and
        y >= layout.box_top_px and y <= layout.box_top_px + layout.box_h;
}

fn executeCommand(action: CommandAction) void {
    switch (action) {
        .new_tab => sessionLauncherOpen(),
        .split_right => AppWindow.splitFocused(.right),
        .split_down => AppWindow.splitFocused(.down),
        .split_left => AppWindow.splitFocused(.left),
        .split_up => AppWindow.splitFocused(.up),
        .focus_previous => AppWindow.gotoSplit(.previous_wrapped),
        .focus_next => AppWindow.gotoSplit(.next_wrapped),
        .equalize_splits => AppWindow.equalizeSplits(),
        .close_split_or_tab => AppWindow.closeFocusedSplit(),
        .toggle_sidebar => AppWindow.input.toggleSidebar(),
        .show_shortcuts => startupShortcutsShow(),
        .open_config => if (AppWindow.g_allocator) |alloc| Config.openConfigInEditor(alloc),
        .font_size_decrease => AppWindow.input.adjustFontSize(-1),
        .font_size_increase => AppWindow.input.adjustFontSize(1),
        .toggle_maximize => AppWindow.input.toggleMaximize(),
    }
}

fn commandPaletteFilter() []const u8 {
    return g_command_palette_filter[0..g_command_palette_filter_len];
}

fn lowerAscii(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, i| {
            if (lowerAscii(haystack[start + i]) != lowerAscii(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn commandEntryMatches(entry: CommandEntry) bool {
    const filter = commandPaletteFilter();
    if (filter.len == 0) return true;
    return containsIgnoreCase(entry.title, filter) or
        containsIgnoreCase(entry.detail, filter) or
        containsIgnoreCase(entry.shortcut, filter);
}

fn commandPaletteVisibleCount() usize {
    var count: usize = 0;
    for (COMMAND_ENTRIES) |entry| {
        if (commandEntryMatches(entry)) count += 1;
    }
    return count;
}

fn commandPaletteSelectedEntryIndex() ?usize {
    var visible_idx: usize = 0;
    for (COMMAND_ENTRIES, 0..) |entry, entry_idx| {
        if (!commandEntryMatches(entry)) continue;
        if (visible_idx == g_command_palette_selected) return entry_idx;
        visible_idx += 1;
    }
    return null;
}

fn commandPaletteEntryIndexAtVisibleRow(row: usize) ?usize {
    var visible_idx: usize = 0;
    for (COMMAND_ENTRIES, 0..) |entry, entry_idx| {
        if (!commandEntryMatches(entry)) continue;
        if (visible_idx == row) return entry_idx;
        visible_idx += 1;
    }
    return null;
}

fn commandPaletteClampSelection() void {
    const count = commandPaletteVisibleCount();
    if (count == 0) {
        g_command_palette_selected = 0;
    } else if (g_command_palette_selected >= count) {
        g_command_palette_selected = count - 1;
    }
}

fn commandPaletteLayout(window_width: f32, window_height: f32, top_offset: f32) CommandPaletteLayout {
    const content_height = @max(1, window_height - top_offset);
    const visible_count = commandPaletteVisibleCount();
    const rendered_rows = @min(visible_count, COMMAND_PALETTE_MAX_VISIBLE_ROWS);

    const box_w = @round(@min(@max(520, window_width - 64), 760));
    const row_h: f32 = 38;
    const header_h: f32 = 48;
    const filter_h: f32 = 42;
    const footer_h: f32 = 30;
    const row_area_h = row_h * @as(f32, @floatFromInt(@max(rendered_rows, 1)));
    const box_h = @round(header_h + filter_h + row_area_h + footer_h + 28);
    const box_x = @round(@max(16, (window_width - box_w) / 2));
    const box_top_px = @round(top_offset + @max(16, (content_height - box_h) / 2));
    const row_top_px = @round(box_top_px + header_h + filter_h + 10);

    return .{
        .box_x = box_x,
        .box_top_px = box_top_px,
        .box_w = box_w,
        .box_h = box_h,
        .row_top_px = row_top_px,
        .row_h = row_h,
    };
}

fn commandPaletteHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) ?usize {
    const layout = commandPaletteLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    if (x < layout.box_x or x > layout.box_x + layout.box_w) return null;
    if (y < layout.row_top_px) return null;

    const row_f = (y - layout.row_top_px) / layout.row_h;
    if (row_f < 0) return null;
    const row: usize = @intFromFloat(@floor(row_f));
    if (row >= @min(commandPaletteVisibleCount(), COMMAND_PALETTE_MAX_VISIBLE_ROWS)) return null;
    return commandPaletteEntryIndexAtVisibleRow(row);
}

fn renderTitlebarText(text: []const u8, x_start: f32, y: f32, color: [3]f32) void {
    var x = @round(x_start);
    const y_aligned = @round(y);
    for (text) |ch| {
        titlebar.renderTitlebarChar(@intCast(ch), x, y_aligned, color);
        x += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
}

fn renderTitlebarTextStrong(text: []const u8, x_start: f32, y: f32, color: [3]f32) void {
    const x = @round(x_start);
    const y_aligned = @round(y);
    renderTitlebarText(text, x, y_aligned, color);
    renderTitlebarText(text, x + 1, y_aligned, color);
}

fn renderTitlebarTextLimited(text: []const u8, x_start: f32, y: f32, color: [3]f32, max_w: f32) void {
    if (max_w <= 0) return;

    var x = @round(x_start);
    const y_aligned = @round(y);
    for (text, 0..) |ch, idx| {
        const advance = titlebar.titlebarGlyphAdvance(@intCast(ch));
        if (x + advance > x_start + max_w) {
            const ellipsis_w = titlebar.titlebarGlyphAdvance('.') * 3;
            if (idx > 0 and x + ellipsis_w <= x_start + max_w) {
                renderTitlebarText("...", x, y_aligned, color);
            }
            return;
        }
        titlebar.renderTitlebarChar(@intCast(ch), x, y_aligned, color);
        x += advance;
    }
}

/// Render the command center overlay.
pub fn renderCommandPalette(window_width: f32, window_height: f32, top_offset: f32) void {
    if (!g_command_palette_visible) return;

    const gl = &AppWindow.gl;
    const layout = commandPaletteLayout(window_width, window_height, top_offset);
    const box_y = @round(window_height - layout.box_top_px - layout.box_h);

    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_color = mixColor(bg, fg, 0.035);
    const border_color = mixColor(bg, fg, 0.16);
    const field_color = mixColor(bg, fg, 0.075);
    const field_border = mixColor(bg, fg, 0.19);
    const muted = mixColor(bg, fg, 0.62);
    const dim = mixColor(bg, fg, 0.44);
    const title_color = mixColor(fg, accent, 0.08);
    const selected_bg = mixColor(bg, accent, 0.50);
    const selected_border = mixColor(accent, fg, 0.16);

    gl_init.renderQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.22);
    renderRoundedQuadAlpha(layout.box_x - 1, box_y - 1, layout.box_w + 2, layout.box_h + 2, 9, border_color, 0.42);
    renderRoundedQuadAlpha(layout.box_x, box_y, layout.box_w, layout.box_h, 8, panel_color, 0.98);

    const pad_x: f32 = 24;
    const title_y = @round(window_height - layout.box_top_px - 31);
    renderTitlebarText("Command Center", layout.box_x + pad_x, title_y, title_color);
    renderTitlebarText("Esc closes", layout.box_x + layout.box_w - pad_x - measureTitlebarText("Esc closes"), title_y, muted);

    const filter_x = @round(layout.box_x + pad_x);
    const filter_y = @round(window_height - (layout.box_top_px + 80));
    const filter_w = layout.box_w - pad_x * 2;
    renderRoundedQuadAlpha(filter_x - 1, filter_y - 9, filter_w + 2, 32, 6, field_border, 0.42);
    renderRoundedQuadAlpha(filter_x, filter_y - 8, filter_w, 30, 5, field_color, 0.92);

    const filter = commandPaletteFilter();
    if (filter.len > 0) {
        renderTitlebarText(filter, filter_x + 12, filter_y, fg);
    } else {
        renderTitlebarText("Type to filter commands", filter_x + 12, filter_y, dim);
    }

    const visible_count = commandPaletteVisibleCount();
    if (visible_count == 0) {
        const empty_text = "No matching commands";
        renderTitlebarText(empty_text, layout.box_x + (layout.box_w - measureTitlebarText(empty_text)) / 2, window_height - layout.row_top_px - 26, muted);
    } else {
        var visible_idx: usize = 0;
        var rendered_rows: usize = 0;
        for (COMMAND_ENTRIES) |entry| {
            if (!commandEntryMatches(entry)) continue;
            if (rendered_rows >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;

            const row_top = @round(layout.row_top_px + @as(f32, @floatFromInt(rendered_rows)) * layout.row_h);
            const row_y = @round(window_height - row_top - layout.row_h);
            const selected = visible_idx == g_command_palette_selected;
            if (selected) {
                renderRoundedQuadAlpha(layout.box_x + 12, row_y + 4, layout.box_w - 24, layout.row_h - 8, 5, selected_border, 0.38);
                renderRoundedQuadAlpha(layout.box_x + 13, row_y + 5, layout.box_w - 26, layout.row_h - 10, 4, selected_bg, 0.78);
            }

            const row_title_color = if (selected) fg else mixColor(bg, fg, 0.86);
            const shortcut_color = if (selected) mixColor(fg, accent, 0.08) else mixColor(bg, fg, 0.54);

            const text_y = @round(row_y + (layout.row_h - font.g_titlebar_cell_height) / 2);
            const title_x = @round(layout.box_x + pad_x + 2);
            var shortcut_left = layout.box_x + layout.box_w - pad_x;
            if (entry.shortcut.len > 0) {
                const shortcut_w = measureTitlebarText(entry.shortcut);
                shortcut_left = @round(layout.box_x + layout.box_w - pad_x - shortcut_w);
                renderTitlebarText(entry.shortcut, shortcut_left, text_y, shortcut_color);
            }

            renderTitlebarTextLimited(entry.title, title_x, text_y, row_title_color, shortcut_left - title_x - 18);

            visible_idx += 1;
            rendered_rows += 1;
        }
    }

    const footer = "Up/Down select, Enter run";
    renderTitlebarText(footer, layout.box_x + pad_x, box_y + 17, muted);
}

// ============================================================================
// New session / SSH launcher
// ============================================================================

const SSH_FIELD_COUNT = 5;
const SSH_FIELD_MAX = 128;
const SSH_PROFILE_MAX = 16;
const SSH_PROFILE_NONE = std.math.maxInt(usize);
const SESSION_LAUNCHER_ROW_COUNT = 3;

const SshField = enum(usize) {
    name = 0,
    ip = 1,
    user = 2,
    password = 3,
    port = 4,
};

const SessionAction = enum {
    powershell,
    ssh,
    wsl,
    connect_selected,
    new_ssh,
    edit_selected,
    delete_selected,
    connect,
    save,
    cancel,
};

const SshProfile = struct {
    fields: [SSH_FIELD_COUNT][SSH_FIELD_MAX]u8 = undefined,
    lens: [SSH_FIELD_COUNT]usize = .{0} ** SSH_FIELD_COUNT,
};

const SessionLayout = struct {
    box_x: f32,
    box_top_px: f32,
    box_w: f32,
    box_h: f32,
    first_row_top_px: f32,
    row_h: f32,
};

pub threadlocal var g_session_launcher_visible: bool = false;
threadlocal var g_session_launcher_selected: usize = 0;
threadlocal var g_ssh_list_visible: bool = false;
threadlocal var g_ssh_form_visible: bool = false;
threadlocal var g_ssh_focus: usize = @intFromEnum(SshField.name);
threadlocal var g_ssh_bufs: [SSH_FIELD_COUNT][SSH_FIELD_MAX]u8 = undefined;
threadlocal var g_ssh_lens: [SSH_FIELD_COUNT]usize = .{0} ** SSH_FIELD_COUNT;
threadlocal var g_ssh_profiles: [SSH_PROFILE_MAX]SshProfile = undefined;
threadlocal var g_ssh_profile_count: usize = 0;
threadlocal var g_ssh_profiles_loaded: bool = false;
threadlocal var g_ssh_list_selected: usize = 0;
threadlocal var g_ssh_edit_index: usize = SSH_PROFILE_NONE;
threadlocal var g_pending_ssh_password: [SSH_FIELD_MAX + 1]u8 = undefined;
threadlocal var g_pending_ssh_password_len: usize = 0;
threadlocal var g_pending_ssh_password_due_ms: i64 = 0;
threadlocal var g_pending_ssh_surface: ?*Surface = null;

pub fn sessionLauncherVisible() bool {
    return g_session_launcher_visible or g_ssh_list_visible or g_ssh_form_visible;
}

pub fn sessionLauncherOpen() void {
    g_session_launcher_visible = true;
    g_session_launcher_selected = 0;
    g_ssh_list_visible = false;
    g_ssh_form_visible = false;
    g_command_palette_visible = false;
    g_settings_visible = false;
    g_startup_shortcuts_visible = false;
}

pub fn sessionLauncherClose() void {
    g_session_launcher_visible = false;
    g_ssh_list_visible = false;
    g_ssh_form_visible = false;
}

pub fn sessionLauncherInsertChar(codepoint: u21) void {
    if (!g_ssh_form_visible) return;
    if (g_ssh_focus >= SSH_FIELD_COUNT) return;
    if (codepoint < 0x20 or codepoint == 0x7f or codepoint > 0x7f) return;
    const field = g_ssh_focus;
    if (g_ssh_lens[field] >= SSH_FIELD_MAX) return;
    g_ssh_bufs[field][g_ssh_lens[field]] = @intCast(codepoint);
    g_ssh_lens[field] += 1;
}

pub fn sessionLauncherHandleKey(ev: win32_backend.KeyEvent) void {
    if (ev.vk == win32_backend.VK_ESCAPE) {
        sessionLauncherClose();
        return;
    }

    if (!g_ssh_form_visible) {
        if (g_ssh_list_visible) {
            handleSshListKey(ev);
            return;
        }
        switch (ev.vk) {
            win32_backend.VK_DOWN, win32_backend.VK_TAB => g_session_launcher_selected = (g_session_launcher_selected + 1) % SESSION_LAUNCHER_ROW_COUNT,
            win32_backend.VK_UP => g_session_launcher_selected = if (g_session_launcher_selected == 0) SESSION_LAUNCHER_ROW_COUNT - 1 else g_session_launcher_selected - 1,
            win32_backend.VK_RETURN => runSessionLauncherRow(g_session_launcher_selected),
            0x50 => {
                g_session_launcher_selected = 0;
                runSessionLauncherRow(g_session_launcher_selected);
            },
            0x53 => {
                g_session_launcher_selected = 1;
                runSessionLauncherRow(g_session_launcher_selected);
            },
            0x57 => {
                g_session_launcher_selected = 2;
                runSessionLauncherRow(g_session_launcher_selected);
            },
            else => {},
        }
        return;
    }

    switch (ev.vk) {
        win32_backend.VK_TAB, win32_backend.VK_DOWN => g_ssh_focus = (g_ssh_focus + 1) % (SSH_FIELD_COUNT + 3),
        win32_backend.VK_UP => g_ssh_focus = if (g_ssh_focus == 0) SSH_FIELD_COUNT + 2 else g_ssh_focus - 1,
        win32_backend.VK_BACK => {
            if (g_ssh_focus < SSH_FIELD_COUNT and g_ssh_lens[g_ssh_focus] > 0) g_ssh_lens[g_ssh_focus] -= 1;
        },
        win32_backend.VK_RETURN => runSshFormFocusAction(),
        else => {},
    }
}

pub fn sessionLauncherContainsPoint(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const layout = sessionLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    return x >= layout.box_x and x <= layout.box_x + layout.box_w and
        y >= layout.box_top_px and y <= layout.box_top_px + layout.box_h;
}

pub fn sessionLauncherExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const action = sessionHitTest(xpos, ypos, window_width, window_height, top_offset) orelse return false;
    switch (action) {
        .powershell => openPowerShellSession(),
        .ssh => openSshList(),
        .wsl => openWslSession(),
        .connect_selected => runSshListRow(g_ssh_list_selected),
        .new_ssh => openSshFormNew(),
        .edit_selected => if (g_ssh_profile_count > 0) openSshFormEdit(@min(g_ssh_list_selected, g_ssh_profile_count - 1)),
        .delete_selected => deleteSelectedSshProfile(),
        .connect => connectSshFromForm(),
        .save => saveSshFormOnly(),
        .cancel => sessionLauncherClose(),
    }
    return true;
}

fn openPowerShellSession() void {
    sessionLauncherClose();
    _ = AppWindow.spawnTabWithCommandUtf8("powershell.exe -NoLogo -NoProfile");
}

fn openWslSession() void {
    sessionLauncherClose();
    _ = AppWindow.spawnTabWithCommandUtf8("wsl.exe ~");
}

fn runSessionLauncherRow(row: usize) void {
    switch (row) {
        0 => openPowerShellSession(),
        1 => openSshList(),
        2 => openWslSession(),
        else => {},
    }
}

fn openSshList() void {
    loadSshProfiles();
    g_session_launcher_visible = false;
    g_ssh_list_visible = true;
    g_ssh_form_visible = false;
    g_ssh_list_selected = @min(g_ssh_list_selected, sshListRowCount() - 1);
}

fn openSshFormNew() void {
    clearSshForm();
    g_ssh_edit_index = SSH_PROFILE_NONE;
    openSshForm();
}

fn openSshFormEdit(index: usize) void {
    if (index >= g_ssh_profile_count) return;
    clearSshForm();
    for (0..SSH_FIELD_COUNT) |i| {
        g_ssh_lens[i] = @min(g_ssh_profiles[index].lens[i], SSH_FIELD_MAX);
        @memcpy(g_ssh_bufs[i][0..g_ssh_lens[i]], g_ssh_profiles[index].fields[i][0..g_ssh_lens[i]]);
    }
    g_ssh_edit_index = index;
    openSshForm();
}

fn openSshForm() void {
    g_ssh_list_visible = false;
    g_session_launcher_visible = false;
    g_ssh_form_visible = true;
    g_ssh_focus = @intFromEnum(SshField.name);
    if (g_ssh_lens[@intFromEnum(SshField.port)] == 0) {
        g_ssh_bufs[@intFromEnum(SshField.port)][0] = '2';
        g_ssh_bufs[@intFromEnum(SshField.port)][1] = '2';
        g_ssh_lens[@intFromEnum(SshField.port)] = 2;
    }
}

fn clearSshForm() void {
    g_ssh_lens = .{0} ** SSH_FIELD_COUNT;
    g_ssh_bufs[@intFromEnum(SshField.port)][0] = '2';
    g_ssh_bufs[@intFromEnum(SshField.port)][1] = '2';
    g_ssh_lens[@intFromEnum(SshField.port)] = 2;
}

fn handleSshListKey(ev: win32_backend.KeyEvent) void {
    const row_count = sshListRowCount();
    switch (ev.vk) {
        win32_backend.VK_DOWN, win32_backend.VK_TAB => g_ssh_list_selected = (g_ssh_list_selected + 1) % row_count,
        win32_backend.VK_UP => g_ssh_list_selected = if (g_ssh_list_selected == 0) row_count - 1 else g_ssh_list_selected - 1,
        win32_backend.VK_RETURN => runSshListRow(g_ssh_list_selected),
        else => {},
    }
}

fn sshListRowCount() usize {
    return g_ssh_profile_count + 4;
}

fn sshField(field: SshField) []const u8 {
    const idx: usize = @intFromEnum(field);
    return g_ssh_bufs[idx][0..g_ssh_lens[idx]];
}

fn profileField(profile: *const SshProfile, field: SshField) []const u8 {
    const idx: usize = @intFromEnum(field);
    return profile.fields[idx][0..profile.lens[idx]];
}

fn runSshListRow(row: usize) void {
    if (row < g_ssh_profile_count) {
        connectSshProfile(row);
        return;
    }
    const action_row = row - g_ssh_profile_count;
    switch (action_row) {
        0 => openSshFormNew(),
        1 => if (g_ssh_profile_count > 0) openSshFormEdit(@min(g_ssh_list_selected, g_ssh_profile_count - 1)),
        2 => deleteSelectedSshProfile(),
        else => sessionLauncherClose(),
    }
}

fn deleteSelectedSshProfile() void {
    if (g_ssh_profile_count == 0) return;
    const idx = @min(g_ssh_list_selected, g_ssh_profile_count - 1);
    var i = idx;
    while (i + 1 < g_ssh_profile_count) : (i += 1) {
        g_ssh_profiles[i] = g_ssh_profiles[i + 1];
    }
    g_ssh_profile_count -= 1;
    g_ssh_list_selected = @min(g_ssh_list_selected, sshListRowCount() - 1);
    if (AppWindow.g_allocator) |allocator| saveSshProfiles(allocator);
}

fn connectSshFromForm() void {
    const idx = saveSshFormProfile() orelse return;
    connectSshProfile(idx);
}

fn saveSshFormOnly() void {
    _ = saveSshFormProfile() orelse return;
    openSshList();
}

fn runSshFormFocusAction() void {
    if (g_ssh_focus < SSH_FIELD_COUNT) {
        g_ssh_focus = (g_ssh_focus + 1) % (SSH_FIELD_COUNT + 3);
        return;
    }
    switch (g_ssh_focus - SSH_FIELD_COUNT) {
        0 => connectSshFromForm(),
        1 => saveSshFormOnly(),
        else => openSshList(),
    }
}

fn saveSshFormProfile() ?usize {
    const allocator = AppWindow.g_allocator orelse return null;
    const ip = sshField(.ip);
    const user = sshField(.user);
    const port = sshField(.port);
    if (ip.len == 0 or user.len == 0) return null;
    if (!isSshTokenSafe(ip) or !isSshTokenSafe(user)) return null;
    if (port.len > 0 and !isPortTokenSafe(port)) return null;

    const idx = if (g_ssh_edit_index != SSH_PROFILE_NONE)
        g_ssh_edit_index
    else blk: {
        if (g_ssh_profile_count >= SSH_PROFILE_MAX) return null;
        const next = g_ssh_profile_count;
        g_ssh_profile_count += 1;
        break :blk next;
    };

    for (0..SSH_FIELD_COUNT) |i| {
        g_ssh_profiles[idx].lens[i] = g_ssh_lens[i];
        @memcpy(g_ssh_profiles[idx].fields[i][0..g_ssh_lens[i]], g_ssh_bufs[i][0..g_ssh_lens[i]]);
    }
    if (g_ssh_profiles[idx].lens[@intFromEnum(SshField.name)] == 0) {
        const host = sshField(.ip);
        const len = @min(host.len, SSH_FIELD_MAX);
        @memcpy(g_ssh_profiles[idx].fields[@intFromEnum(SshField.name)][0..len], host[0..len]);
        g_ssh_profiles[idx].lens[@intFromEnum(SshField.name)] = len;
    }

    saveSshProfiles(allocator);
    g_ssh_edit_index = idx;
    return idx;
}

fn connectSshProfile(idx: usize) void {
    if (idx >= g_ssh_profile_count) return;
    const profile = &g_ssh_profiles[idx];
    const ip = profileField(profile, .ip);
    const user = profileField(profile, .user);
    const port = profileField(profile, .port);
    const password = profileField(profile, .password);
    const server_name = profileField(profile, .name);
    if (ip.len == 0 or user.len == 0) return;
    if (!isSshTokenSafe(ip) or !isSshTokenSafe(user)) return;
    if (port.len > 0 and !isPortTokenSafe(port)) return;

    var command_buf: [512]u8 = undefined;
    const auth_flags = if (password.len > 0)
        "-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no "
    else
        "-o StrictHostKeyChecking=accept-new ";
    const command = if (port.len > 0)
        std.fmt.bufPrint(&command_buf, "cmd.exe /k ssh.exe -tt {s}-p {s} {s}@{s}", .{ auth_flags, port, user, ip }) catch return
    else
        std.fmt.bufPrint(&command_buf, "cmd.exe /k ssh.exe -tt {s}{s}@{s}", .{ auth_flags, user, ip }) catch return;

    sessionLauncherClose();
    if (AppWindow.spawnTabWithCommandUtf8ReturningSurface(command)) |surface| {
        if (server_name.len > 0) {
            surface.setTitleOverride(server_name);
        }
        if (password.len > 0) {
            schedulePasswordForSurface(surface, password);
        }
    }
}

fn isSshTokenSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_' or ch == '@') continue;
        return false;
    }
    return true;
}

fn isPortTokenSafe(value: []const u8) bool {
    if (value.len == 0) return true;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn schedulePasswordForSurface(surface: *Surface, password: []const u8) void {
    const len = @min(password.len, SSH_FIELD_MAX);
    @memcpy(g_pending_ssh_password[0..len], password[0..len]);
    g_pending_ssh_password[len] = '\r';
    g_pending_ssh_password_len = len + 1;
    g_pending_ssh_password_due_ms = std.time.milliTimestamp() + 1800;
    g_pending_ssh_surface = surface;
}

pub fn tickSessionLauncher() void {
    if (g_pending_ssh_password_len == 0) return;
    if (std.time.milliTimestamp() < g_pending_ssh_password_due_ms) return;
    if (g_pending_ssh_surface) |surface| {
        AppWindow.input.writeTextToSurfacePty(surface, g_pending_ssh_password[0..g_pending_ssh_password_len]);
    }
    g_pending_ssh_password_len = 0;
    g_pending_ssh_surface = null;
}

fn sshProfilesPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "APPDATA")) |appdata| {
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, "phantty", "ssh_hosts" });
    } else |_| {}
    return std.fs.path.join(allocator, &.{ ".", "ssh_hosts" });
}

fn loadSshProfiles() void {
    if (g_ssh_profiles_loaded) return;
    g_ssh_profiles_loaded = true;
    g_ssh_profile_count = 0;
    const allocator = AppWindow.g_allocator orelse return;
    const path = sshProfilesPath(allocator) catch return;
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        if (g_ssh_profile_count >= SSH_PROFILE_MAX) break;
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var profile = SshProfile{};
        var parts = std.mem.splitScalar(u8, line, '\t');
        var field_idx: usize = 0;
        var ok = true;
        while (field_idx < SSH_FIELD_COUNT) : (field_idx += 1) {
            const part = parts.next() orelse {
                ok = false;
                break;
            };
            const decoded = decodeHexField(part, &profile.fields[field_idx]) orelse {
                ok = false;
                break;
            };
            profile.lens[field_idx] = decoded;
        }
        if (!ok) continue;
        g_ssh_profiles[g_ssh_profile_count] = profile;
        g_ssh_profile_count += 1;
    }
}

fn saveSshProfiles(allocator: std.mem.Allocator) void {
    const path = sshProfilesPath(allocator) catch return;
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, "# Phantty SSH profiles. Fields are hex encoded: name, host, user, password, port.\n") catch return;
    for (g_ssh_profiles[0..g_ssh_profile_count]) |profile| {
        for (0..SSH_FIELD_COUNT) |i| {
            if (i > 0) out.append(allocator, '\t') catch return;
            appendHexField(allocator, &out, profile.fields[i][0..profile.lens[i]]) catch return;
        }
        out.append(allocator, '\n') catch return;
    }

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer file.close();
    file.writeAll(out.items) catch {};
}

fn appendHexField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}

fn decodeHexField(value: []const u8, out: *[SSH_FIELD_MAX]u8) ?usize {
    if (value.len % 2 != 0) return null;
    const len = @min(value.len / 2, SSH_FIELD_MAX);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const hi = hexValue(value[i * 2]) orelse return null;
        const lo = hexValue(value[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return len;
}

fn hexValue(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

fn sessionLayout(window_width: f32, window_height: f32, top_offset: f32) SessionLayout {
    const content_height = @max(1, window_height - top_offset);
    const box_w: f32 = if (g_ssh_form_visible or g_ssh_list_visible) @round(@min(@max(460, window_width - 48), 760)) else 360;
    const row_h: f32 = 38;
    const row_count: usize = if (g_ssh_form_visible) SSH_FIELD_COUNT + 3 else if (g_ssh_list_visible) sshListRowCount() else SESSION_LAUNCHER_ROW_COUNT;
    const box_h = @round(74 + row_h * @as(f32, @floatFromInt(row_count)) + 28);
    const box_x = @round(@max(16, (window_width - box_w) / 2));
    const box_top_px = @round(top_offset + @max(16, (content_height - box_h) / 2));
    return .{
        .box_x = box_x,
        .box_top_px = box_top_px,
        .box_w = box_w,
        .box_h = box_h,
        .first_row_top_px = box_top_px + 68,
        .row_h = row_h,
    };
}

fn sessionHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) ?SessionAction {
    const layout = sessionLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    if (x < layout.box_x or x > layout.box_x + layout.box_w) return null;
    if (y < layout.first_row_top_px) return null;
    const row: usize = @intFromFloat(@floor((y - layout.first_row_top_px) / layout.row_h));

    if (g_ssh_list_visible) {
        if (row >= sshListRowCount()) return null;
        g_ssh_list_selected = row;
        if (row < g_ssh_profile_count) return .connect_selected;
        return switch (row - g_ssh_profile_count) {
            0 => .new_ssh,
            1 => .edit_selected,
            2 => .delete_selected,
            else => .cancel,
        };
    }

    if (!g_ssh_form_visible) {
        if (row >= SESSION_LAUNCHER_ROW_COUNT) return null;
        g_session_launcher_selected = row;
        return switch (row) {
            0 => .powershell,
            1 => .ssh,
            2 => .wsl,
            else => null,
        };
    }

    if (row < SSH_FIELD_COUNT) {
        g_ssh_focus = row;
        return null;
    }
    g_ssh_focus = row;
    return switch (row) {
        SSH_FIELD_COUNT => .connect,
        SSH_FIELD_COUNT + 1 => .save,
        SSH_FIELD_COUNT + 2 => .cancel,
        else => null,
    };
}

fn renderSessionRow(layout: SessionLayout, window_height: f32, row: usize, left: []const u8, right: []const u8, selected: bool) void {
    const row_top = @round(layout.first_row_top_px + @as(f32, @floatFromInt(row)) * layout.row_h);
    const row_y = @round(window_height - row_top - layout.row_h);
    const x = layout.box_x + 18;
    const w = layout.box_w - 36;
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const row_color = if (selected) mixColor(bg, accent, 0.34) else mixColor(bg, fg, 0.055);
    gl_init.renderQuadAlpha(x, row_y + 3, w, layout.row_h - 6, row_color, if (selected) 0.82 else 0.78);
    if (selected) gl_init.renderQuadAlpha(x, row_y + 3, 3, layout.row_h - 6, accent, 0.86);
    const text_y = row_y + 15;
    const left_color = if (selected) mixColor(fg, accent, 0.12) else mixColor(bg, fg, 0.88);
    renderTitlebarTextStrong(left, x + 12, text_y, left_color);
    if (right.len > 0) {
        const right_w = measureTitlebarText(right);
        const right_color = if (selected) mixColor(fg, accent, 0.08) else mixColor(bg, fg, 0.56);
        renderTitlebarTextStrong(right, layout.box_x + layout.box_w - 34 - right_w, text_y, right_color);
    }
}

fn renderSessionField(layout: SessionLayout, window_height: f32, row: usize, label: []const u8, value: []const u8, masked: bool) void {
    var display_buf: [SSH_FIELD_MAX]u8 = undefined;
    const display = if (masked) blk: {
        const len = @min(value.len, display_buf.len);
        @memset(display_buf[0..len], '*');
        break :blk display_buf[0..len];
    } else value;
    renderSessionRow(layout, window_height, row, label, display, g_ssh_focus == row);
}

fn renderSshProfileRow(layout: SessionLayout, window_height: f32, row: usize, profile: *const SshProfile, selected: bool) void {
    var target_buf: [SSH_FIELD_MAX * 2]u8 = undefined;
    const host = profileField(profile, .ip);
    const user = profileField(profile, .user);
    const port = profileField(profile, .port);
    const target = if (port.len > 0)
        std.fmt.bufPrint(&target_buf, "{s}@{s}:{s}", .{ user, host, port }) catch ""
    else
        std.fmt.bufPrint(&target_buf, "{s}@{s}", .{ user, host }) catch "";
    renderSessionRow(layout, window_height, row, profileField(profile, .name), target, selected);
}

pub fn renderSessionLauncher(window_width: f32, window_height: f32, top_offset: f32) void {
    if (!sessionLauncherVisible()) return;

    const gl = &AppWindow.gl;
    const layout = sessionLayout(window_width, window_height, top_offset);
    const box_y = @round(window_height - layout.box_top_px - layout.box_h);

    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_color = mixColor(bg, fg, 0.035);
    const border_color = mixColor(bg, accent, 0.24);
    const title_color = mixColor(fg, accent, 0.14);
    const muted_color = mixColor(bg, fg, 0.58);

    gl_init.renderQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.18);
    renderRoundedQuadAlpha(layout.box_x - 1, box_y - 1, layout.box_w + 2, layout.box_h + 2, 11, border_color, 0.24);
    renderRoundedQuadAlpha(layout.box_x, box_y, layout.box_w, layout.box_h, 10, panel_color, 0.96);

    const title = if (g_ssh_form_visible) "SSH Server" else if (g_ssh_list_visible) "SSH Servers" else "New Session";
    const hint = if (g_ssh_form_visible) "Tab changes field, Enter connects" else if (g_ssh_list_visible) "Enter connects, New/Edit/Delete manage" else "Up/Down select, Enter starts";
    const title_y = @round(window_height - layout.box_top_px - 34);
    renderTitlebarTextStrong(title, layout.box_x + 24, title_y, title_color);
    renderTitlebarTextStrong(hint, layout.box_x + 24, title_y - 24, muted_color);

    if (!g_ssh_form_visible) {
        if (g_ssh_list_visible) {
            var row: usize = 0;
            while (row < g_ssh_profile_count) : (row += 1) {
                renderSshProfileRow(layout, window_height, row, &g_ssh_profiles[row], g_ssh_list_selected == row);
            }
            renderSessionRow(layout, window_height, row, "New SSH Server", "add", g_ssh_list_selected == row);
            row += 1;
            renderSessionRow(layout, window_height, row, "Edit Selected", if (g_ssh_profile_count > 0) "edit" else "no server", g_ssh_list_selected == row);
            row += 1;
            renderSessionRow(layout, window_height, row, "Delete Selected", if (g_ssh_profile_count > 0) "delete" else "no server", g_ssh_list_selected == row);
            row += 1;
            renderSessionRow(layout, window_height, row, "Cancel", "Esc", g_ssh_list_selected == row);
            return;
        }
        renderSessionRow(layout, window_height, 0, "PowerShell", "new terminal", g_session_launcher_selected == 0);
        renderSessionRow(layout, window_height, 1, "SSH", "connect server", g_session_launcher_selected == 1);
        renderSessionRow(layout, window_height, 2, "WSL", "wsl.exe ~", g_session_launcher_selected == 2);
        return;
    }

    renderSessionField(layout, window_height, @intFromEnum(SshField.name), "Server name", sshField(.name), false);
    renderSessionField(layout, window_height, @intFromEnum(SshField.ip), "IP / host", sshField(.ip), false);
    renderSessionField(layout, window_height, @intFromEnum(SshField.user), "User", sshField(.user), false);
    renderSessionField(layout, window_height, @intFromEnum(SshField.password), "Password", sshField(.password), true);
    renderSessionField(layout, window_height, @intFromEnum(SshField.port), "Port", sshField(.port), false);
    renderSessionRow(layout, window_height, SSH_FIELD_COUNT, "Save & Connect", "ssh.exe", g_ssh_focus == SSH_FIELD_COUNT);
    renderSessionRow(layout, window_height, SSH_FIELD_COUNT + 1, "Save", "profile", g_ssh_focus == SSH_FIELD_COUNT + 1);
    renderSessionRow(layout, window_height, SSH_FIELD_COUNT + 2, "Cancel", "Esc", g_ssh_focus == SSH_FIELD_COUNT + 2);
}

// ============================================================================
// Settings page
// ============================================================================

const ThemePreset = struct {
    label: []const u8,
    theme: ?[]const u8,
    detail: []const u8,
};

const SETTINGS_THEME_PRESETS = [_]ThemePreset{
    .{ .label = "Phantty Default", .theme = null, .detail = "Warm balanced dark" },
    .{ .label = "Catppuccin Mocha", .theme = "Catppuccin Mocha", .detail = "Soft popular dark" },
    .{ .label = "TokyoNight Night", .theme = "TokyoNight Night", .detail = "Deep blue coding" },
    .{ .label = "GitHub Light", .theme = "GitHub Light Default", .detail = "Clean white" },
    .{ .label = "Xcode Light", .theme = "Xcode Light", .detail = "Bright native" },
};

const SETTINGS_THEME_ROW = 1;
const SETTINGS_CONTROL_ROW_START = SETTINGS_THEME_ROW + 1;
const SETTINGS_ROW_COUNT = SETTINGS_CONTROL_ROW_START + 6;

const SettingsAction = enum {
    font_size_minus,
    font_size_plus,
    cycle_theme,
    cycle_cursor_style,
    toggle_cursor_blink,
    toggle_focus_follows_mouse,
    cycle_shell,
    open_raw_config,
    close,
};

const SettingsLayout = struct {
    box_x: f32,
    box_top_px: f32,
    box_w: f32,
    box_h: f32,
    row_top_px: f32,
    row_h: f32,
};

pub threadlocal var g_settings_visible: bool = false;
threadlocal var g_settings_focus: usize = SETTINGS_THEME_ROW;

pub fn settingsPageVisible() bool {
    return g_settings_visible;
}

pub fn settingsPageOpen() void {
    g_settings_visible = true;
    g_settings_focus = SETTINGS_THEME_ROW;
    g_command_palette_visible = false;
    g_startup_shortcuts_visible = false;
}

pub fn settingsPageClose() void {
    g_settings_visible = false;
}

pub fn settingsPageHandleKey(ev: win32_backend.KeyEvent) void {
    switch (ev.vk) {
        win32_backend.VK_ESCAPE => settingsPageClose(),
        win32_backend.VK_DOWN, win32_backend.VK_TAB => g_settings_focus = (g_settings_focus + 1) % SETTINGS_ROW_COUNT,
        win32_backend.VK_UP => g_settings_focus = if (g_settings_focus == 0) SETTINGS_ROW_COUNT - 1 else g_settings_focus - 1,
        win32_backend.VK_LEFT => runSettingsFocusLeft(),
        win32_backend.VK_RIGHT => runSettingsFocusRight(),
        win32_backend.VK_RETURN => runSettingsFocusPrimary(),
        else => {},
    }
}

pub fn settingsPageContainsPoint(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const layout = settingsLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    return x >= layout.box_x and x <= layout.box_x + layout.box_w and
        y >= layout.box_top_px and y <= layout.box_top_px + layout.box_h;
}

pub fn settingsPageExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    const action = settingsHitTest(xpos, ypos, window_width, window_height, top_offset) orelse return false;
    executeSettingsAction(action);
    return true;
}

fn settingsLayout(window_width: f32, window_height: f32, top_offset: f32) SettingsLayout {
    const content_height = @max(1, window_height - top_offset);
    const box_w = @round(@min(@max(420, window_width - 48), 760));
    const row_h: f32 = 42;
    const header_h: f32 = 70;
    const footer_h: f32 = 52;
    const box_h = @round(header_h + row_h * SETTINGS_ROW_COUNT + footer_h);
    const box_x = @round(@max(16, (window_width - box_w) / 2));
    const box_top_px = @round(top_offset + @max(16, (content_height - box_h) / 2));
    const row_top_px = @round(box_top_px + header_h);
    return .{
        .box_x = box_x,
        .box_top_px = box_top_px,
        .box_w = box_w,
        .box_h = box_h,
        .row_top_px = row_top_px,
        .row_h = row_h,
    };
}

fn settingsHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) ?SettingsAction {
    const layout = settingsLayout(window_width, window_height, top_offset);
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);

    const close_x = layout.box_x + layout.box_w - 62;
    if (y >= layout.box_top_px + 18 and y < layout.box_top_px + 46 and x >= close_x and x < close_x + 44) {
        return .close;
    }

    if (x < layout.box_x + 18 or x > layout.box_x + layout.box_w - 18) return null;
    if (y < layout.row_top_px) return null;
    const row: usize = @intFromFloat(@floor((y - layout.row_top_px) / layout.row_h));
    if (row >= SETTINGS_ROW_COUNT) return null;
    g_settings_focus = row;

    if (row == 0) {
        const plus_x = layout.box_x + layout.box_w - 70;
        const minus_x = plus_x - 42;
        if (x >= minus_x and x < minus_x + 30) return .font_size_minus;
        if (x >= plus_x and x < plus_x + 30) return .font_size_plus;
        return null;
    }

    if (row == SETTINGS_THEME_ROW) {
        return .cycle_theme;
    }

    return switch (row - SETTINGS_CONTROL_ROW_START) {
        0 => .cycle_cursor_style,
        1 => .toggle_cursor_blink,
        2 => .toggle_focus_follows_mouse,
        3 => .cycle_shell,
        4 => .open_raw_config,
        5 => .close,
        else => null,
    };
}

fn executeSettingsAction(action: SettingsAction) void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    switch (action) {
        .font_size_minus => {
            const next = if (cfg.@"font-size" > 6) cfg.@"font-size" - 1 else cfg.@"font-size";
            writeConfigInt("font-size", next);
        },
        .font_size_plus => {
            const next = @min(cfg.@"font-size" + 1, 72);
            writeConfigInt("font-size", next);
        },
        .cycle_theme => cycleThemePreset(1),
        .cycle_cursor_style => Config.setConfigValue(allocator, "cursor-style", nextCursorStyle(cfg.@"cursor-style")) catch {},
        .toggle_cursor_blink => Config.setConfigValue(allocator, "cursor-style-blink", if (cfg.@"cursor-style-blink") "false" else "true") catch {},
        .toggle_focus_follows_mouse => Config.setConfigValue(allocator, "focus-follows-mouse", if (cfg.@"focus-follows-mouse") "false" else "true") catch {},
        .cycle_shell => Config.setConfigValue(allocator, "shell", nextShell(cfg.shell)) catch {},
        .open_raw_config => Config.openConfigInEditor(allocator),
        .close => settingsPageClose(),
    }
}

fn writeConfigInt(key: []const u8, value: u32) void {
    const allocator = AppWindow.g_allocator orelse return;
    var buf: [32]u8 = undefined;
    const value_text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    Config.setConfigValue(allocator, key, value_text) catch {};
}

fn runSettingsFocusPrimary() void {
    switch (g_settings_focus) {
        0 => executeSettingsAction(.font_size_plus),
        SETTINGS_THEME_ROW => cycleThemePreset(1),
        SETTINGS_CONTROL_ROW_START + 0 => executeSettingsAction(.cycle_cursor_style),
        SETTINGS_CONTROL_ROW_START + 1 => executeSettingsAction(.toggle_cursor_blink),
        SETTINGS_CONTROL_ROW_START + 2 => executeSettingsAction(.toggle_focus_follows_mouse),
        SETTINGS_CONTROL_ROW_START + 3 => executeSettingsAction(.cycle_shell),
        SETTINGS_CONTROL_ROW_START + 4 => executeSettingsAction(.open_raw_config),
        SETTINGS_CONTROL_ROW_START + 5 => executeSettingsAction(.close),
        else => {},
    }
}

fn runSettingsFocusLeft() void {
    switch (g_settings_focus) {
        0 => executeSettingsAction(.font_size_minus),
        SETTINGS_THEME_ROW => cycleThemePreset(-1),
        else => {},
    }
}

fn runSettingsFocusRight() void {
    switch (g_settings_focus) {
        0 => executeSettingsAction(.font_size_plus),
        SETTINGS_THEME_ROW => cycleThemePreset(1),
        else => runSettingsFocusPrimary(),
    }
}

const THEME_OVERRIDE_KEYS = [_][]const u8{
    "background",
    "foreground",
    "cursor-color",
    "cursor-text",
    "selection-background",
    "selection-foreground",
    "palette",
};

const THEME_RESET_KEYS = [_][]const u8{
    "theme",
    "background",
    "foreground",
    "cursor-color",
    "cursor-text",
    "selection-background",
    "selection-foreground",
    "palette",
};

fn applyThemePreset(index: usize) void {
    const allocator = AppWindow.g_allocator orelse return;
    if (index >= SETTINGS_THEME_PRESETS.len) return;

    const preset = SETTINGS_THEME_PRESETS[index];
    if (preset.theme) |theme_name| {
        Config.removeConfigKeys(allocator, &THEME_OVERRIDE_KEYS) catch {};
        Config.setConfigValue(allocator, "theme", theme_name) catch {};
    } else {
        Config.removeConfigKeys(allocator, &THEME_RESET_KEYS) catch {};
    }
}

fn activeThemePresetIndex(cfg: *const Config) ?usize {
    for (SETTINGS_THEME_PRESETS, 0..) |preset, i| {
        if (themePresetIsActive(cfg, preset)) return i;
    }
    return null;
}

fn cycleThemePreset(delta: i32) void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    const count: i32 = @intCast(SETTINGS_THEME_PRESETS.len);
    const current: i32 = @intCast(activeThemePresetIndex(&cfg) orelse 0);
    const next = @mod(current + delta, count);
    applyThemePreset(@intCast(next));
}

fn themePresetIsActive(cfg: *const Config, preset: ThemePreset) bool {
    if (preset.theme) |theme_name| {
        return if (cfg.theme) |active| std.mem.eql(u8, active, theme_name) else false;
    }
    return cfg.theme == null;
}

fn currentThemePresetLabel(cfg: *const Config) []const u8 {
    if (activeThemePresetIndex(cfg)) |idx| return SETTINGS_THEME_PRESETS[idx].label;
    if (cfg.theme) |theme_name| return theme_name;
    return SETTINGS_THEME_PRESETS[0].label;
}

fn currentThemePresetDetail(cfg: *const Config) []const u8 {
    if (activeThemePresetIndex(cfg)) |idx| return SETTINGS_THEME_PRESETS[idx].detail;
    if (cfg.theme != null) return "Custom theme";
    return SETTINGS_THEME_PRESETS[0].detail;
}

fn cursorStyleText(style: Config.CursorStyle) []const u8 {
    return switch (style) {
        .block => "block",
        .bar => "bar",
        .underline => "underline",
        .block_hollow => "block_hollow",
    };
}

fn nextCursorStyle(style: Config.CursorStyle) []const u8 {
    return switch (style) {
        .block => "bar",
        .bar => "underline",
        .underline => "block_hollow",
        .block_hollow => "block",
    };
}

fn nextShell(shell: []const u8) []const u8 {
    if (std.mem.eql(u8, shell, "cmd")) return "powershell";
    if (std.mem.eql(u8, shell, "powershell")) return "pwsh";
    if (std.mem.eql(u8, shell, "pwsh")) return "wsl";
    return "cmd";
}

fn boolText(value: bool) []const u8 {
    return if (value) "on" else "off";
}

fn renderSettingsRow(layout: SettingsLayout, window_height: f32, row: usize, title: []const u8, value: []const u8, hint: []const u8, clickable: bool, selected: bool) void {
    const row_y = @round(@as(f32, @floatFromInt(row)) * layout.row_h);
    const y_top_px = layout.row_top_px + row_y;
    const gl_y = @round(window_height - y_top_px - layout.row_h);
    const x = layout.box_x + 18;
    const w = layout.box_w - 36;
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const active = std.mem.eql(u8, value, "active");

    if (clickable) {
        const row_color = if (selected) mixColor(bg, accent, 0.24) else if (active) mixColor(bg, accent, 0.18) else mixColor(bg, fg, 0.055);
        gl_init.renderQuadAlpha(x, gl_y + 3, w, layout.row_h - 6, row_color, if (selected) 0.72 else if (active) 0.44 else 0.82);
        if (selected) gl_init.renderQuadAlpha(x, gl_y + 3, 3, layout.row_h - 6, accent, 0.82);
    }

    const text_y = gl_y + 15;
    const title_color = if (selected or active) mixColor(fg, accent, 0.18) else fg;
    renderTitlebarText(title, x + 12, text_y, title_color);

    if (value.len > 0) {
        const value_w = measureTitlebarText(value);
        const value_color = if (selected or active) accent else mixColor(bg, fg, 0.78);
        renderTitlebarText(value, layout.box_x + layout.box_w - 36 - value_w, text_y, value_color);
    }

    if (hint.len > 0) {
        renderTitlebarText(hint, x + 210, text_y, mixColor(bg, fg, 0.55));
    }
}

pub fn renderSettingsPage(window_width: f32, window_height: f32, top_offset: f32) void {
    if (!g_settings_visible) return;
    const allocator = AppWindow.g_allocator orelse return;

    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    const gl = &AppWindow.gl;
    const layout = settingsLayout(window_width, window_height, top_offset);
    const box_y = @round(window_height - layout.box_top_px - layout.box_h);

    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_color = mixColor(bg, fg, 0.035);
    const border_color = mixColor(bg, accent, 0.24);
    const muted_color = mixColor(bg, fg, 0.58);

    gl_init.renderQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.16);
    renderRoundedQuadAlpha(layout.box_x - 1, box_y - 1, layout.box_w + 2, layout.box_h + 2, 11, border_color, 0.24);
    renderRoundedQuadAlpha(layout.box_x, box_y, layout.box_w, layout.box_h, 10, panel_color, 0.96);

    const title_y = @round(window_height - layout.box_top_px - 34);
    renderTitlebarText("Settings", layout.box_x + 24, title_y, mixColor(fg, accent, 0.14));
    renderTitlebarText("Config changes save immediately", layout.box_x + 24, title_y - 24, muted_color);
    renderTitlebarText("Esc", layout.box_x + layout.box_w - 52, title_y, mixColor(bg, fg, 0.72));

    var font_buf: [24]u8 = undefined;
    const font_value = std.fmt.bufPrint(&font_buf, "-  {d}  +", .{cfg.@"font-size"}) catch "";
    renderSettingsRow(layout, window_height, 0, "Font size", font_value, "Left / Right", true, g_settings_focus == 0);

    var theme_buf: [96]u8 = undefined;
    const theme_value = std.fmt.bufPrint(&theme_buf, "< {s} >", .{currentThemePresetLabel(&cfg)}) catch currentThemePresetLabel(&cfg);
    renderSettingsRow(layout, window_height, SETTINGS_THEME_ROW, "Theme", theme_value, currentThemePresetDetail(&cfg), true, g_settings_focus == SETTINGS_THEME_ROW);

    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 0, "Cursor style", cursorStyleText(cfg.@"cursor-style"), "Enter / Right", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 0);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 1, "Cursor blink", boolText(cfg.@"cursor-style-blink"), "Enter / Right", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 1);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 2, "Focus follows mouse", boolText(cfg.@"focus-follows-mouse"), "Enter / Right", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 2);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 3, "Shell for new tabs", cfg.shell, "cmd / powershell / pwsh / wsl", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 3);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 4, "Raw config file", "open", "Advanced editor", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 4);
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 5, "Close settings", "Esc", "", true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 5);
}

// ============================================================================
// FPS debug overlay state
// ============================================================================

pub threadlocal var g_debug_fps: bool = false; // Whether to show FPS overlay
pub threadlocal var g_debug_draw_calls: bool = false; // Whether to show draw call count overlay
threadlocal var g_fps_frame_count: u32 = 0; // Frames since last FPS update
pub threadlocal var g_fps_last_time: i64 = 0; // Timestamp of last FPS calculation
threadlocal var g_fps_value: f32 = 0; // Current FPS value to display

// ============================================================================
// Scrollbar geometry
// ============================================================================

/// Scrollbar geometry result.
pub const ScrollbarGeometry = struct {
    track_x: f32,
    track_y: f32, // bottom of track (GL coords, y=0 is bottom)
    track_h: f32,
    thumb_y: f32,
    thumb_h: f32,
};

/// Compute scrollbar geometry for a specific surface.
/// Returns null if there's no scrollback (nothing to scroll).
pub fn scrollbarGeometryForSurface(surface: *Surface, view_height: f32, top_padding: f32) ?ScrollbarGeometry {
    const sb = surface.terminal.screens.active.pages.scrollbar();
    if (sb.total <= sb.len) return null; // No scrollback, no scrollbar

    // Track spans the terminal content area (below top padding, all the way to bottom)
    const track_top = view_height - top_padding; // top of terminal area in GL coords
    const track_bottom: f32 = 0; // extend to bottom edge
    const track_h = track_top - track_bottom;
    if (track_h <= 0) return null;

    // Thumb proportional to visible / total
    const ratio = @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total));
    const thumb_h = @max(SCROLLBAR_MIN_THUMB, track_h * ratio);

    // Thumb position: offset=0 means top, offset=total-len means bottom
    const max_offset = @as(f32, @floatFromInt(sb.total - sb.len));
    const scroll_frac = if (max_offset > 0)
        @as(f32, @floatFromInt(sb.offset)) / max_offset
    else
        0;
    // In GL coords: top of track is higher y value
    const thumb_top = track_top - scroll_frac * (track_h - thumb_h);
    const thumb_y = thumb_top - thumb_h;

    return .{
        .track_x = 0, // placeholder — caller provides view_width
        .track_y = track_bottom,
        .track_h = track_h,
        .thumb_y = thumb_y,
        .thumb_h = thumb_h,
    };
}

/// Compute scrollbar geometry from terminal state (uses active surface).
/// Returns null if there's no scrollback (nothing to scroll).
pub fn scrollbarGeometry(window_height: f32, top_padding: f32) ?ScrollbarGeometry {
    const surface = AppWindow.activeSurface() orelse return null;
    return scrollbarGeometryForSurface(surface, window_height, top_padding);
}

/// Show the scrollbar on the active surface (reset fade timer).
pub fn scrollbarShow() void {
    const surface = AppWindow.activeSurface() orelse return;
    surface.scrollbar_opacity = 1.0;
    surface.scrollbar_show_time = std.time.milliTimestamp();
}

/// Update scrollbar fade animation for a surface. Call once per frame.
fn scrollbarUpdateFade(surface: *Surface) void {
    if (g_scrollbar_hover or g_scrollbar_dragging) {
        surface.scrollbar_opacity = 1.0;
        return;
    }
    if (surface.scrollbar_opacity <= 0) return;

    const now = std.time.milliTimestamp();
    const elapsed = now - surface.scrollbar_show_time;

    if (elapsed < SCROLLBAR_FADE_DELAY_MS) {
        surface.scrollbar_opacity = 1.0;
    } else {
        const fade_elapsed = elapsed - SCROLLBAR_FADE_DELAY_MS;
        if (fade_elapsed >= SCROLLBAR_FADE_DURATION_MS) {
            surface.scrollbar_opacity = 0;
        } else {
            surface.scrollbar_opacity = 1.0 - @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(SCROLLBAR_FADE_DURATION_MS));
        }
    }
}

/// Render the scrollbar overlay for a specific surface within the current viewport.
/// view_width/view_height are the viewport dimensions (not full window).
/// top_padding is the padding from the top of the viewport to the terminal content.
pub fn renderScrollbarForSurface(surface: *Surface, view_width: f32, view_height: f32, top_padding: f32) void {
    const gl = &AppWindow.gl;
    scrollbarUpdateFade(surface);
    if (surface.scrollbar_opacity <= 0.01) return;

    const geo = scrollbarGeometryForSurface(surface, view_height, top_padding) orelse return;

    const bar_x = view_width - SCROLLBAR_WIDTH;
    const bar_w = SCROLLBAR_WIDTH;

    // Use the shader_program for quad rendering
    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);

    const fade = surface.scrollbar_opacity;

    // Track background: black at low alpha to subtly lift it from the terminal bg
    const track_alpha = fade * 0.08;
    gl_init.renderQuadAlpha(bar_x, geo.track_y, bar_w, geo.track_h, .{ 0, 0, 0 }, track_alpha);

    // Thumb: black at 45% opacity
    const thumb_alpha = fade * 0.45;
    gl_init.renderQuadAlpha(bar_x, geo.thumb_y, bar_w, geo.thumb_h, .{ 0, 0, 0 }, thumb_alpha);
}

/// Render the scrollbar overlay (uses active surface at full window size).
pub fn renderScrollbar(window_width: f32, window_height: f32, top_padding: f32) void {
    const surface = AppWindow.activeSurface() orelse return;
    renderScrollbarForSurface(surface, window_width, window_height, top_padding);
}

/// Check if a point (in client pixel coords, origin top-left) is over the scrollbar.
pub fn scrollbarHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_padding: f32) bool {
    const bar_right = window_width;
    const bar_left = window_width - SCROLLBAR_HOVER_WIDTH;
    const track_top_px = top_padding; // in pixel coords (top-left origin)
    const track_bottom_px = window_height;

    return @as(f32, @floatCast(xpos)) >= bar_left and
        @as(f32, @floatCast(xpos)) <= bar_right and
        @as(f32, @floatCast(ypos)) >= track_top_px and
        @as(f32, @floatCast(ypos)) <= track_bottom_px;
}

/// Check if a point is over the scrollbar thumb specifically.
pub fn scrollbarThumbHitTest(ypos: f64, window_height: f32, top_padding: f32) bool {
    const geo = scrollbarGeometry(window_height, top_padding) orelse return false;
    // Convert ypos (top-left origin) to GL coords (bottom-left origin)
    const gl_y = window_height - @as(f32, @floatCast(ypos));
    return gl_y >= geo.thumb_y and gl_y <= geo.thumb_y + geo.thumb_h;
}

/// Handle scrollbar drag: convert pixel y to scroll position.
pub fn scrollbarDrag(ypos: f64, window_height: f32, top_padding: f32) void {
    const surface = AppWindow.activeSurface() orelse return;
    const sb = surface.terminal.screens.active.pages.scrollbar();
    if (sb.total <= sb.len) return;

    const padding: f32 = 10;
    const track_top_px = top_padding;
    const track_bottom_px = window_height - padding;
    const track_h = track_bottom_px - track_top_px;
    if (track_h <= 0) return;

    const ratio = @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total));
    const thumb_h = @max(SCROLLBAR_MIN_THUMB, track_h * ratio);
    const scrollable_h = track_h - thumb_h;
    if (scrollable_h <= 0) return;

    // ypos is in top-left coords; track_top_px is the top of the track
    const y_in_track = @as(f32, @floatCast(ypos)) - track_top_px - g_scrollbar_drag_offset;
    const frac = std.math.clamp(y_in_track / scrollable_h, 0, 1);

    const max_offset = sb.total - sb.len;
    const target_offset: isize = @intFromFloat(frac * @as(f32, @floatFromInt(max_offset)));
    const current_offset: isize = @intCast(sb.offset);
    const delta = target_offset - current_offset;

    if (delta != 0) {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        surface.terminal.scrollViewport(.{ .delta = delta });
    }
}

// ============================================================================
// Resize overlay
// ============================================================================

/// Trigger the resize overlay to show with the given dimensions.
/// Called whenever the terminal size changes.
pub fn resizeOverlayShow(cols: u16, rows: u16) void {
    const now = std.time.milliTimestamp();

    // Check if overlay is suppressed (e.g., after tab switch)
    if (now < g_resize_overlay_suppress_until) {
        // Still update last cols/rows so we don't flash when suppression ends
        g_resize_overlay_last_cols = cols;
        g_resize_overlay_last_rows = rows;
        return;
    }

    // Mark resize as active (for cursor hiding)
    g_resize_active = true;
    g_resize_overlay_last_change = now;

    // Check if we're past the initial delay (avoid showing during initial window setup)
    if (!g_resize_overlay_ready) {
        if (g_resize_overlay_init_time == 0) {
            g_resize_overlay_init_time = now;
        }
        if (now - g_resize_overlay_init_time < RESIZE_OVERLAY_FIRST_DELAY_MS) {
            // Still in initial delay - update last_cols/rows so we don't flash when ready
            g_resize_overlay_last_cols = cols;
            g_resize_overlay_last_rows = rows;
            return;
        }
        g_resize_overlay_ready = true;
    }

    // Update current size
    g_resize_overlay_cols = cols;
    g_resize_overlay_rows = rows;

    // Show overlay if size differs from last settled size
    if (cols != g_resize_overlay_last_cols or rows != g_resize_overlay_last_rows) {
        g_resize_overlay_visible = true;
        g_resize_overlay_opacity = 1.0;
    }
}

/// Update resize overlay state. Call once per frame.
/// Handles the timeout logic and fade animation.
fn resizeOverlayUpdate() void {
    const now = std.time.milliTimestamp();
    const elapsed = now - g_resize_overlay_last_change;

    // Update resize active state (short timeout for cursor to reappear)
    if (g_resize_active and elapsed >= RESIZE_ACTIVE_TIMEOUT_MS) {
        g_resize_active = false;
    }

    if (!g_resize_overlay_visible and g_resize_overlay_opacity <= 0) return;

    if (g_resize_overlay_visible) {
        // Check if we should start hiding (size hasn't changed for DURATION_MS)
        if (elapsed >= RESIZE_OVERLAY_DURATION_MS) {
            // Timer completed - "settle" the size and start fade out
            g_resize_overlay_last_cols = g_resize_overlay_cols;
            g_resize_overlay_last_rows = g_resize_overlay_rows;
            g_resize_overlay_visible = false;
            // opacity stays at current value, will fade in next block
        }
    }

    // Handle fade out when not visible
    if (!g_resize_overlay_visible and g_resize_overlay_opacity > 0) {
        const fade_start = g_resize_overlay_last_change + RESIZE_OVERLAY_DURATION_MS;
        const fade_elapsed = now - fade_start;
        if (fade_elapsed >= RESIZE_OVERLAY_FADE_MS) {
            g_resize_overlay_opacity = 0;
        } else if (fade_elapsed > 0) {
            g_resize_overlay_opacity = 1.0 - @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(RESIZE_OVERLAY_FADE_MS));
        }
    }
}

/// Render a rounded rectangle with the given color and alpha.
/// Uses multiple quads to approximate rounded corners.
pub fn renderRoundedQuadAlpha(x: f32, y: f32, w: f32, h: f32, radius: f32, color: [3]f32, alpha: f32) void {
    const r = @min(radius, @min(w, h) / 2); // Clamp radius to half of smallest dimension

    // Main body (center rectangle, full height minus corners)
    gl_init.renderQuadAlpha(x + r, y, w - r * 2, h, color, alpha);

    // Left strip (between corners)
    gl_init.renderQuadAlpha(x, y + r, r, h - r * 2, color, alpha);

    // Right strip (between corners)
    gl_init.renderQuadAlpha(x + w - r, y + r, r, h - r * 2, color, alpha);

    // Approximate corners with small quads (simple 2-step approximation)
    // Bottom-left corner
    const r2 = r * 0.7; // Inner radius approximation
    gl_init.renderQuadAlpha(x + r - r2, y + r - r2, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x, y + r - r2, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + r - r2, y, r2, r - r2, color, alpha);

    // Bottom-right corner
    gl_init.renderQuadAlpha(x + w - r, y + r - r2, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r + r2, y + r - r2, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r, y, r2, r - r2, color, alpha);

    // Top-left corner
    gl_init.renderQuadAlpha(x + r - r2, y + h - r, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x, y + h - r, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + r - r2, y + h - r + r2, r2, r - r2, color, alpha);

    // Top-right corner
    gl_init.renderQuadAlpha(x + w - r, y + h - r, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r + r2, y + h - r, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r, y + h - r + r2, r2, r - r2, color, alpha);
}

/// Render the resize overlay centered on screen.
pub fn renderResizeOverlay(window_width: f32, window_height: f32) void {
    renderResizeOverlayWithOffset(window_width, window_height, 0);
}

/// Render the resize overlay centered in the content area (below titlebar).
pub fn renderResizeOverlayWithOffset(window_width: f32, window_height: f32, top_offset: f32) void {
    resizeOverlayUpdate();
    if (g_resize_overlay_opacity <= 0.01) return;

    renderResizeOverlayText(g_resize_overlay_cols, g_resize_overlay_rows, window_width, window_height, top_offset, g_resize_overlay_opacity);
}

/// Render the resize overlay for a specific surface (used during divider dragging or equalize).
/// Shows the surface's current dimensions centered in the viewport.
/// Only shows if this surface's size actually changed during the drag/equalize.
pub fn renderResizeOverlayForSurface(surface: *Surface, window_width: f32, window_height: f32) void {
    // Show during divider dragging OR during timed split resize overlay (equalize, keyboard resize)
    const show_timed = std.time.milliTimestamp() < g_split_resize_overlay_until;
    if (!AppWindow.input.g_divider_dragging and !show_timed) return;
    if (!surface.resize_overlay_active) return;

    const cols = surface.size.grid.cols;
    const rows = surface.size.grid.rows;

    renderResizeOverlayText(cols, rows, window_width, window_height, 0, 1.0);
}

/// Core function to render a resize overlay with specific dimensions.
fn renderResizeOverlayText(cols: u16, rows: u16, window_width: f32, window_height: f32, top_offset: f32, alpha: f32) void {
    const gl = &AppWindow.gl;
    if (alpha <= 0.01) return;

    // Format the size string: "cols x rows"
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d} x {d}", .{ cols, rows }) catch return;

    // Measure text width using titlebar glyph system
    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
    const text_height = font.g_titlebar_cell_height;

    // Padding around text (compact)
    const pad_x: f32 = 10;
    const pad_y: f32 = 6;

    // Box dimensions
    const box_width = text_width + pad_x * 2;
    const box_height = text_height + pad_y * 2;

    // Center horizontally, center vertically in content area (below top_offset)
    const content_height = window_height - top_offset;
    const box_x = (window_width - box_width) / 2;
    const box_y = (content_height - box_height) / 2; // Centered in content area (GL coords)

    // Enable blending
    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);

    // Draw rounded background box (black with alpha, slightly more transparent than scrollbar)
    const corner_radius: f32 = 6;
    renderRoundedQuadAlpha(box_x, box_y, box_width, box_height, corner_radius, .{ 0.0, 0.0, 0.0 }, alpha * 0.35);

    // Draw text using titlebar rendering system (dimmed gray text)
    var x = box_x + pad_x;
    const y = box_y + pad_y;
    const text_gray: f32 = 0.6; // Dimmed gray
    for (text) |ch| {
        titlebar.renderTitlebarChar(@intCast(ch), x, y, .{ text_gray, text_gray, text_gray });
        x += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
}
fn startupShortcutsOpacity() f32 {
    if (!g_startup_shortcuts_visible) return 0;

    if (g_startup_shortcuts_started_at == 0) {
        g_startup_shortcuts_started_at = std.time.milliTimestamp();
    }

    const now = std.time.milliTimestamp();
    const elapsed = now - g_startup_shortcuts_started_at;
    if (elapsed >= STARTUP_SHORTCUTS_DURATION_MS) {
        g_startup_shortcuts_visible = false;
        return 0;
    }

    const fade_start = STARTUP_SHORTCUTS_DURATION_MS - STARTUP_SHORTCUTS_FADE_MS;
    if (elapsed > fade_start) {
        const fade_elapsed = elapsed - fade_start;
        return 1.0 - @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(STARTUP_SHORTCUTS_FADE_MS));
    }

    return 1.0;
}

fn mixColor(from: [3]f32, to: [3]f32, amount: f32) [3]f32 {
    const inv = 1.0 - amount;
    return .{
        from[0] * inv + to[0] * amount,
        from[1] * inv + to[1] * amount,
        from[2] * inv + to[2] * amount,
    };
}

fn measureTitlebarText(text: []const u8) f32 {
    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
    return text_width;
}

/// Render a centered startup overlay listing common keyboard shortcuts.
pub fn renderStartupShortcutsOverlay(window_width: f32, window_height: f32, top_offset: f32) void {
    const alpha = startupShortcutsOpacity();
    if (alpha <= 0.01) return;

    const gl = &AppWindow.gl;

    var max_keys_width: f32 = 0;
    var max_action_width: f32 = 0;
    for (STARTUP_SHORTCUT_ENTRIES) |entry| {
        max_keys_width = @max(max_keys_width, measureTitlebarText(entry.keys));
        max_action_width = @max(max_action_width, measureTitlebarText(entry.action));
    }

    const pad_x: f32 = 24;
    const pad_y: f32 = 18;
    const col_gap: f32 = 48;
    const line_height = font.g_titlebar_cell_height + 9;
    const heading_gap: f32 = 16;
    const hint_gap: f32 = 12;
    const hint = "Press any key or click to hide";
    const heading = "Keyboard shortcuts";
    const entries_height = line_height * @as(f32, @floatFromInt(STARTUP_SHORTCUT_ENTRIES.len));
    const box_width = @round(@max(
        measureTitlebarText(heading) + pad_x * 2,
        max_keys_width + col_gap + max_action_width + pad_x * 2,
    ));
    const box_height = @round(pad_y * 2 + font.g_titlebar_cell_height + heading_gap + entries_height + hint_gap + font.g_titlebar_cell_height);

    const content_height = window_height - top_offset;
    const box_x = @round(@max(12, (window_width - box_width) / 2));
    const box_y = @round(@max(12, (content_height - box_height) / 2));

    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const panel_color = mixColor(AppWindow.g_theme.background, AppWindow.g_theme.foreground, 0.035);
    const border_color = mixColor(AppWindow.g_theme.background, AppWindow.g_theme.cursor_color, 0.24);
    renderRoundedQuadAlpha(box_x - 1, box_y - 1, box_width + 2, box_height + 2, 11, border_color, alpha * 0.24);
    renderRoundedQuadAlpha(box_x, box_y, box_width, box_height, 10, panel_color, alpha * 0.94);

    const heading_base = mixColor(AppWindow.g_theme.foreground, AppWindow.g_theme.cursor_color, 0.18);
    const keys_base = mixColor(AppWindow.g_theme.foreground, AppWindow.g_theme.cursor_color, 0.08);
    const action_base = AppWindow.g_theme.foreground;
    const hint_base = mixColor(AppWindow.g_theme.background, AppWindow.g_theme.foreground, 0.58);
    const heading_color = mixColor(AppWindow.g_theme.background, heading_base, alpha);
    const keys_color = mixColor(AppWindow.g_theme.background, keys_base, alpha);
    const action_color = mixColor(AppWindow.g_theme.background, action_base, alpha);
    const hint_color = mixColor(AppWindow.g_theme.background, hint_base, alpha);

    const heading_w = measureTitlebarText(heading);
    const heading_y = @round(box_y + box_height - pad_y - font.g_titlebar_cell_height);
    renderTitlebarText(heading, box_x + (box_width - heading_w) / 2, heading_y, heading_color);
    gl_init.renderQuadAlpha(box_x + pad_x, heading_y - heading_gap / 2 - 1, box_width - pad_x * 2, 1, border_color, alpha * 0.36);

    const keys_x = @round(box_x + pad_x);
    const action_x = @round(keys_x + max_keys_width + col_gap);
    var y = @round(heading_y - heading_gap - line_height);
    for (STARTUP_SHORTCUT_ENTRIES) |entry| {
        renderTitlebarText(entry.keys, keys_x, y, keys_color);
        renderTitlebarText(entry.action, action_x, y, action_color);
        y -= line_height;
    }

    const hint_w = measureTitlebarText(hint);
    renderTitlebarText(hint, box_x + (box_width - hint_w) / 2, box_y + pad_y, hint_color);
}

// ============================================================================
// Split rendering helpers
// ============================================================================

/// Render a semi-transparent overlay over an unfocused split pane.
pub fn renderUnfocusedOverlay(rect: SplitRect, window_height: f32) void {
    const gl = &AppWindow.gl;
    const opacity = 1.0 - g_unfocused_split_opacity;
    if (opacity < 0.01) return;

    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);

    // Draw semi-transparent background color overlay
    const px: f32 = @floatFromInt(rect.x);
    const py: f32 = window_height - @as(f32, @floatFromInt(rect.y + rect.height));
    const pw: f32 = @floatFromInt(rect.width);
    const ph: f32 = @floatFromInt(rect.height);

    // Use background color with alpha for the overlay
    gl_init.renderQuadAlpha(px, py, pw, ph, AppWindow.g_theme.background, opacity);
}

/// Render unfocused overlay within current viewport (for split rendering).
/// Assumes viewport is already set to the split's region.
/// Uses true alpha blending so it blends with actual rendered content.
pub fn renderUnfocusedOverlaySimple(width: f32, height: f32) void {
    const gl = &AppWindow.gl;
    const alpha = 1.0 - g_unfocused_split_opacity;
    if (alpha < 0.01) return;

    const vertices = [6][4]f32{
        .{ 0, height, 0.0, 0.0 },
        .{ 0, 0, 0.0, 1.0 },
        .{ width, 0, 1.0, 1.0 },
        .{ 0, height, 0.0, 0.0 },
        .{ width, 0, 1.0, 1.0 },
        .{ width, height, 1.0, 0.0 },
    };

    // Use overlay shader with true alpha blending
    gl.UseProgram.?(gl_init.overlay_shader);

    // Set overlay color (background color with alpha)
    gl.Uniform4f.?(
        gl.GetUniformLocation.?(gl_init.overlay_shader, "overlayColor"),
        AppWindow.g_theme.background[0],
        AppWindow.g_theme.background[1],
        AppWindow.g_theme.background[2],
        alpha,
    );

    // Set projection for current viewport
    var viewport: [4]c.GLint = undefined;
    gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
    const vp_width: f32 = @floatFromInt(viewport[2]);
    const vp_height: f32 = @floatFromInt(viewport[3]);
    const projection = [16]f32{
        2.0 / vp_width, 0.0,             0.0,  0.0,
        0.0,            2.0 / vp_height, 0.0,  0.0,
        0.0,            0.0,             -1.0, 0.0,
        -1.0,           -1.0,            0.0,  1.0,
    };
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(gl_init.overlay_shader, "projection"), 1, c.GL_FALSE, &projection);

    gl.BindVertexArray.?(gl_init.vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, gl_init.vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    gl_init.g_draw_call_count += 1;
}

/// Render split dividers between panes in the active tab.
/// If split-divider-color is configured, uses that color (solid).
/// Otherwise uses scrollbar-style rendering: black with alpha transparency.
pub fn renderSplitDividers(active_tab: *const TabState, content_x: i32, content_y: i32, content_w: i32, content_h: i32, window_height: f32) void {
    const gl = &AppWindow.gl;
    if (!active_tab.tree.isSplit()) return;

    const allocator = AppWindow.g_allocator orelse return;

    // Get spatial representation
    var spatial = active_tab.tree.spatial(allocator) catch return;
    defer spatial.deinit(allocator);

    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);

    // Check if custom color is configured
    const use_custom_color = g_split_divider_color != null;
    const custom_color = g_split_divider_color orelse .{ 0, 0, 0 };
    // Default alpha - similar to scrollbar thumb (0.45) but slightly less prominent
    const default_alpha: f32 = 0.35;

    // Walk the tree nodes and draw dividers for each split
    for (active_tab.tree.nodes, 0..) |node, i| {
        switch (node) {
            .leaf => {},
            .split => |s| {
                const slot = spatial.slots[i];
                const slot_x: f32 = @as(f32, @floatCast(slot.x)) * @as(f32, @floatFromInt(content_w)) + @as(f32, @floatFromInt(content_x));
                const slot_y: f32 = @as(f32, @floatCast(slot.y)) * @as(f32, @floatFromInt(content_h)) + @as(f32, @floatFromInt(content_y));
                const slot_w: f32 = @as(f32, @floatCast(slot.width)) * @as(f32, @floatFromInt(content_w));
                const slot_h: f32 = @as(f32, @floatCast(slot.height)) * @as(f32, @floatFromInt(content_h));

                switch (s.layout) {
                    .horizontal => {
                        // Vertical divider at ratio position
                        const div_x = slot_x + slot_w * @as(f32, @floatCast(s.ratio)) - @as(f32, @floatFromInt(@divTrunc(SPLIT_DIVIDER_WIDTH, 2)));
                        const div_y = window_height - slot_y - slot_h;
                        if (use_custom_color) {
                            gl_init.renderQuad(div_x, div_y, @floatFromInt(SPLIT_DIVIDER_WIDTH), slot_h, custom_color);
                        } else {
                            gl_init.renderQuadAlpha(div_x, div_y, @floatFromInt(SPLIT_DIVIDER_WIDTH), slot_h, .{ 0, 0, 0 }, default_alpha);
                        }
                    },
                    .vertical => {
                        // Horizontal divider at ratio position
                        const div_x = slot_x;
                        const div_y = window_height - slot_y - slot_h * @as(f32, @floatCast(s.ratio)) - @as(f32, @floatFromInt(@divTrunc(SPLIT_DIVIDER_WIDTH, 2)));
                        if (use_custom_color) {
                            gl_init.renderQuad(div_x, div_y, slot_w, @floatFromInt(SPLIT_DIVIDER_WIDTH), custom_color);
                        } else {
                            gl_init.renderQuadAlpha(div_x, div_y, slot_w, @floatFromInt(SPLIT_DIVIDER_WIDTH), .{ 0, 0, 0 }, default_alpha);
                        }
                    },
                }
            },
        }
    }
}

// ============================================================================
// Debug overlays
// ============================================================================

/// Update the FPS counter. Call once per frame.
pub fn updateFps() void {
    g_fps_frame_count += 1;
    const now = std.time.milliTimestamp();
    const elapsed = now - g_fps_last_time;
    if (elapsed >= 1000) {
        g_fps_value = @as(f32, @floatFromInt(g_fps_frame_count)) * 1000.0 / @as(f32, @floatFromInt(elapsed));
        g_fps_frame_count = 0;
        g_fps_last_time = now;
    }
}

/// Render the FPS debug overlay in the bottom-right corner.
pub fn renderDebugOverlay(window_width: f32) void {
    const margin: f32 = 8;
    const pad_h: f32 = 4;
    const pad_v: f32 = 2;
    const line_h = font.g_titlebar_cell_height + pad_v * 2;
    var overlay_y: f32 = margin;

    if (g_debug_fps) {
        renderDebugLine(window_width, &overlay_y, margin, pad_h, pad_v, line_h, blk: {
            var buf: [32]u8 = undefined;
            const fps_int: u32 = @intFromFloat(@round(g_fps_value));
            break :blk std.fmt.bufPrint(&buf, "{d} fps", .{fps_int}) catch break :blk "";
        }, .{ 0.0, 1.0, 0.0 });
    }

    if (g_debug_draw_calls) {
        renderDebugLine(window_width, &overlay_y, margin, pad_h, pad_v, line_h, blk: {
            var buf: [32]u8 = undefined;
            break :blk std.fmt.bufPrint(&buf, "{d} draws", .{gl_init.g_draw_call_count}) catch break :blk "";
        }, .{ 1.0, 1.0, 0.0 });
    }
}

fn renderDebugLine(window_width: f32, y_pos: *f32, margin: f32, pad_h: f32, pad_v: f32, line_h: f32, text: []const u8, text_color: [3]f32) void {
    const gl = &AppWindow.gl;
    if (text.len == 0) return;

    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }

    const bg_w = text_width + pad_h * 2;
    const bg_x = window_width - bg_w - margin;
    const bg_y = y_pos.*;

    gl_init.renderQuad(bg_x, bg_y, bg_w, line_h, .{ 0.0, 0.0, 0.0 });

    var x = bg_x + pad_h;
    const y = bg_y + pad_v;
    for (text) |ch| {
        titlebar.renderTitlebarChar(@intCast(ch), x, y, text_color);
        x += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }

    y_pos.* += line_h + 2; // spacing between lines
}
