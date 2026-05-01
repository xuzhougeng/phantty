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
    .{ .keys = "Ctrl+Shift+T", .action = "New tab" },
    .{ .keys = "Ctrl+Shift+B", .action = "Toggle sidebar" },
    .{ .keys = "Ctrl+W", .action = "Close panel / tab" },
    .{ .keys = "Ctrl+Shift+O", .action = "Split right" },
    .{ .keys = "Ctrl+Shift+E", .action = "Split down" },
    .{ .keys = "Ctrl+Shift+[ / ]", .action = "Previous / next panel" },
    .{ .keys = "Ctrl+Alt+Arrows", .action = "Focus panel" },
    .{ .keys = "Ctrl+Shift+Z", .action = "Equalize panels" },
    .{ .keys = "Ctrl+Shift+C/V", .action = "Copy / paste" },
    .{ .keys = "Ctrl+,", .action = "Open config" },
    .{ .keys = "Alt+Enter / F11", .action = "Fullscreen" },
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
    toggle_fullscreen,
};

const CommandEntry = struct {
    title: []const u8,
    detail: []const u8,
    shortcut: []const u8,
    action: CommandAction,
};

const COMMAND_ENTRIES = [_]CommandEntry{
    .{ .title = "New Tab", .detail = "Create a new terminal tab", .shortcut = "Ctrl+Shift+T", .action = .new_tab },
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
    .{ .title = "Toggle Fullscreen", .detail = "Enter or exit fullscreen", .shortcut = "Alt+Enter / F11", .action = .toggle_fullscreen },
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
        .new_tab => _ = AppWindow.spawnTab(AppWindow.g_allocator orelse return),
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
        .toggle_fullscreen => AppWindow.input.toggleFullscreen(),
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

    const box_w = @round(@min(@max(360, window_width - 32), 720));
    const row_h: f32 = 34;
    const header_h: f32 = 42;
    const filter_h: f32 = 36;
    const footer_h: f32 = 24;
    const row_area_h = row_h * @as(f32, @floatFromInt(@max(rendered_rows, 1)));
    const box_h = @round(header_h + filter_h + row_area_h + footer_h + 24);
    const box_x = @round(@max(12, (window_width - box_w) / 2));
    const box_top_px = @round(top_offset + @max(12, (content_height - box_h) / 2));
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
                renderTitlebarTextStrong("...", x, y_aligned, color);
            }
            return;
        }
        titlebar.renderTitlebarChar(@intCast(ch), x, y_aligned, color);
        titlebar.renderTitlebarChar(@intCast(ch), x + 1, y_aligned, color);
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

    gl_init.renderQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.30);
    renderRoundedQuadAlpha(layout.box_x, box_y, layout.box_w, layout.box_h, 10, .{ 0.0, 0.0, 0.0 }, 0.88);

    const fg: [3]f32 = .{ 1.0, 1.0, 1.0 };
    const muted: [3]f32 = .{ 0.84, 0.84, 0.84 };
    const dim: [3]f32 = .{ 0.68, 0.68, 0.68 };
    const accent: [3]f32 = .{ 0.18, 0.36, 0.74 };

    const pad_x: f32 = 18;
    const title_y = @round(window_height - layout.box_top_px - 29);
    renderTitlebarTextStrong("Command Center", layout.box_x + pad_x, title_y, fg);
    renderTitlebarTextStrong("Esc closes", layout.box_x + layout.box_w - pad_x - measureTitlebarText("Esc closes") - 1, title_y, muted);

    const filter_x = @round(layout.box_x + pad_x);
    const filter_y = @round(window_height - (layout.box_top_px + 74));
    const filter_w = layout.box_w - pad_x * 2;
    renderRoundedQuadAlpha(filter_x, filter_y - 7, filter_w, 26, 5, .{ 1.0, 1.0, 1.0 }, 0.10);

    const filter = commandPaletteFilter();
    if (filter.len > 0) {
        renderTitlebarTextStrong(filter, filter_x + 10, filter_y, fg);
    } else {
        renderTitlebarTextStrong("Type to filter commands", filter_x + 10, filter_y, dim);
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
                renderRoundedQuadAlpha(layout.box_x + 8, row_y + 2, layout.box_w - 16, layout.row_h - 4, 6, accent, 0.72);
            }

            const title_color: [3]f32 = if (selected) fg else .{ 0.92, 0.92, 0.92 };
            const shortcut_color = if (selected) fg else muted;

            const text_y = @round(row_y + 17);
            const title_x = @round(layout.box_x + pad_x);
            var shortcut_left = layout.box_x + layout.box_w - pad_x;
            if (entry.shortcut.len > 0) {
                const shortcut_w = measureTitlebarText(entry.shortcut);
                shortcut_left = @round(layout.box_x + layout.box_w - pad_x - shortcut_w - 1);
                renderTitlebarTextStrong(entry.shortcut, shortcut_left, text_y, shortcut_color);
            }

            renderTitlebarTextLimited(entry.title, title_x, text_y, title_color, shortcut_left - title_x - 18);

            visible_idx += 1;
            rendered_rows += 1;
        }
    }

    const footer = "Up/Down select, Enter run";
    renderTitlebarTextStrong(footer, layout.box_x + pad_x, box_y + 15, muted);
}

// ============================================================================
// Settings page
// ============================================================================

const SETTINGS_ROW_COUNT = 7;

const SettingsAction = enum {
    font_size_minus,
    font_size_plus,
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

pub fn settingsPageVisible() bool {
    return g_settings_visible;
}

pub fn settingsPageOpen() void {
    g_settings_visible = true;
    g_command_palette_visible = false;
    g_startup_shortcuts_visible = false;
}

pub fn settingsPageClose() void {
    g_settings_visible = false;
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

    if (row == 0) {
        const plus_x = layout.box_x + layout.box_w - 70;
        const minus_x = plus_x - 42;
        if (x >= minus_x and x < minus_x + 30) return .font_size_minus;
        if (x >= plus_x and x < plus_x + 30) return .font_size_plus;
        return null;
    }

    return switch (row) {
        1 => .cycle_cursor_style,
        2 => .toggle_cursor_blink,
        3 => .toggle_focus_follows_mouse,
        4 => .cycle_shell,
        5 => .open_raw_config,
        6 => .close,
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

fn renderSettingsRow(layout: SettingsLayout, window_height: f32, row: usize, title: []const u8, value: []const u8, hint: []const u8, clickable: bool) void {
    const row_y = @round(@as(f32, @floatFromInt(row)) * layout.row_h);
    const y_top_px = layout.row_top_px + row_y;
    const gl_y = @round(window_height - y_top_px - layout.row_h);
    const x = layout.box_x + 18;
    const w = layout.box_w - 36;

    if (clickable) {
        gl_init.renderQuadAlpha(x, gl_y + 3, w, layout.row_h - 6, .{ 1.0, 1.0, 1.0 }, 0.045);
    }

    const text_y = gl_y + 15;
    renderTitlebarTextStrong(title, x + 12, text_y, .{ 0.92, 0.92, 0.92 });

    if (value.len > 0) {
        const value_w = measureTitlebarText(value);
        renderTitlebarTextStrong(value, layout.box_x + layout.box_w - 36 - value_w, text_y, .{ 0.82, 0.82, 0.82 });
    }

    if (hint.len > 0) {
        renderTitlebarTextStrong(hint, x + 210, text_y, .{ 0.58, 0.58, 0.58 });
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

    gl_init.renderQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.18);
    renderRoundedQuadAlpha(layout.box_x, box_y, layout.box_w, layout.box_h, 10, .{ 0.0, 0.0, 0.0 }, 0.86);

    const title_y = @round(window_height - layout.box_top_px - 34);
    renderTitlebarTextStrong("Settings", layout.box_x + 24, title_y, .{ 1.0, 1.0, 1.0 });
    renderTitlebarTextStrong("Config changes save immediately", layout.box_x + 24, title_y - 24, .{ 0.66, 0.66, 0.66 });
    renderTitlebarTextStrong("Esc", layout.box_x + layout.box_w - 52, title_y, .{ 0.76, 0.76, 0.76 });

    var font_buf: [24]u8 = undefined;
    const font_value = std.fmt.bufPrint(&font_buf, "-  {d}  +", .{cfg.@"font-size"}) catch "";
    renderSettingsRow(layout, window_height, 0, "Font size", font_value, "Click - / +", true);
    renderSettingsRow(layout, window_height, 1, "Cursor style", cursorStyleText(cfg.@"cursor-style"), "Click to cycle", true);
    renderSettingsRow(layout, window_height, 2, "Cursor blink", boolText(cfg.@"cursor-style-blink"), "Click to toggle", true);
    renderSettingsRow(layout, window_height, 3, "Focus follows mouse", boolText(cfg.@"focus-follows-mouse"), "Click to toggle", true);
    renderSettingsRow(layout, window_height, 4, "Shell for new tabs", cfg.shell, "cmd / powershell / pwsh / wsl", true);
    renderSettingsRow(layout, window_height, 5, "Raw config file", "open", "Advanced editor", true);
    renderSettingsRow(layout, window_height, 6, "Close settings", "Esc", "", true);
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

    renderRoundedQuadAlpha(box_x, box_y, box_width, box_height, 10, .{ 0.0, 0.0, 0.0 }, alpha * 0.76);

    const heading_color = mixColor(AppWindow.g_theme.background, .{ 1.0, 1.0, 1.0 }, alpha);
    const keys_color = mixColor(AppWindow.g_theme.background, .{ 0.88, 0.88, 0.88 }, alpha);
    const action_color = mixColor(AppWindow.g_theme.background, .{ 0.78, 0.78, 0.78 }, alpha);
    const hint_color = mixColor(AppWindow.g_theme.background, .{ 0.68, 0.68, 0.68 }, alpha);

    const heading_w = measureTitlebarText(heading);
    const heading_y = @round(box_y + box_height - pad_y - font.g_titlebar_cell_height);
    renderTitlebarTextStrong(heading, box_x + (box_width - heading_w) / 2, heading_y, heading_color);

    const keys_x = @round(box_x + pad_x);
    const action_x = @round(keys_x + max_keys_width + col_gap);
    var y = @round(heading_y - heading_gap - line_height);
    for (STARTUP_SHORTCUT_ENTRIES) |entry| {
        renderTitlebarTextStrong(entry.keys, keys_x, y, keys_color);
        renderTitlebarTextStrong(entry.action, action_x, y, action_color);
        y -= line_height;
    }

    const hint_w = measureTitlebarText(hint);
    renderTitlebarTextStrong(hint, box_x + (box_width - hint_w) / 2, box_y + pad_y, hint_color);
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
