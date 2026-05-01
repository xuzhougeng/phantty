//! Input handling for AppWindow.
//!
//! Processes Win32 input events (keyboard, mouse, resize) and dispatches
//! to appropriate handlers. Manages clipboard, selection, scrollbar dragging,
//! split divider dragging, and fullscreen toggle.

const std = @import("std");
const AppWindow = @import("AppWindow.zig");
const tab = AppWindow.tab;
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const overlays = AppWindow.overlays;
const split_layout = AppWindow.split_layout;
const window_state = AppWindow.window_state;
const win32_backend = @import("apprt/win32.zig");
const Config = @import("config.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("split_tree.zig");
const windows = @import("std").os.windows;
const Selection = Surface.Selection;

/// Write data to the PTY's input pipe (us -> child stdin).
fn writeToPty(surface: *Surface, data: []const u8) void {
    var bytes_written: windows.DWORD = 0;
    _ = windows.kernel32.WriteFile(
        surface.pty.in_pipe,
        data.ptr,
        @intCast(data.len),
        &bytes_written,
        null,
    );
}

// Selection + divider drag state (moved from AppWindow.zig)
pub threadlocal var g_selecting: bool = false; // True while mouse button is held
pub threadlocal var g_click_x: f64 = 0; // X position of initial click (for threshold calculation)
pub threadlocal var g_click_y: f64 = 0; // Y position of initial click

pub const SPLIT_DIVIDER_HIT_WIDTH: f32 = 8; // Larger hit area for easier grabbing

pub threadlocal var g_divider_hover: bool = false; // Mouse is over a divider
pub threadlocal var g_divider_dragging: bool = false; // Currently dragging a divider
pub threadlocal var g_divider_drag_handle: ?SplitTree.Node.Handle = null; // Handle of the split node being resized
pub threadlocal var g_divider_drag_layout: ?SplitTree.Split.Layout = null; // horizontal or vertical

// Internal state (moved from win32_input struct)
threadlocal var plus_btn_pressed: bool = false;
threadlocal var saved_style: win32_backend.DWORD = 0;
threadlocal var saved_rect: win32_backend.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
threadlocal var is_fullscreen: bool = false;

fn titlebarHeight() f64 {
    return if (AppWindow.g_window) |w| @floatFromInt(w.titlebar_height) else @as(f64, @floatFromInt(win32_backend.TITLEBAR_HEIGHT));
}

fn syncGridFromWindowSize(width: i32, height: i32) void {
    const render_padding: f32 = 10;
    const tb_offset: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
    const sidebar_w = titlebar.sidebarWidth();
    const explicit_left: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);
    const explicit_right: f32 = @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING)) + overlays.SCROLLBAR_WIDTH;
    const explicit_top: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);
    const explicit_bottom: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);

    const total_width_padding = sidebar_w + explicit_left + explicit_right;
    const total_height_padding = render_padding * 2 + tb_offset + explicit_top + explicit_bottom;

    const avail_width = @as(f32, @floatFromInt(width)) - total_width_padding;
    const avail_height = @as(f32, @floatFromInt(height)) - total_height_padding;

    const new_cols: u16 = @intFromFloat(@max(1, avail_width / font.cell_width));
    const new_rows: u16 = @intFromFloat(@max(1, avail_height / font.cell_height));

    if (new_cols != AppWindow.term_cols or new_rows != AppWindow.term_rows) {
        AppWindow.g_pending_resize = true;
        AppWindow.g_pending_cols = new_cols;
        AppWindow.g_pending_rows = new_rows;
        AppWindow.g_last_resize_time = std.time.milliTimestamp();
    }
}

pub fn toggleSidebar() void {
    tab.g_sidebar_visible = !tab.g_sidebar_visible;
    if (AppWindow.g_window) |win| {
        syncGridFromWindowSize(win.width, win.height);
        win.sidebar_width = @intFromFloat(titlebar.sidebarWidth());
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

// ============================================================================
// Shared helpers (used by input + cell_renderer)
// ============================================================================

/// Get the viewport's absolute row offset into the scrollback.
/// Row 0 on screen corresponds to absolute row `viewportOffset()`.
pub fn viewportOffset() usize {
    const surface = AppWindow.activeSurface() orelse return 0;
    return surface.terminal.screens.active.pages.scrollbar().offset;
}

/// Convert mouse position to terminal cell coordinates.
pub fn mouseToCell(xpos: f64, ypos: f64) struct { col: usize, row: usize } {
    const padding_d: f64 = 10;
    const tb_d: f64 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
    const sidebar_d: f64 = @floatCast(titlebar.sidebarWidth());
    const col_f = (xpos - sidebar_d - padding_d) / @as(f64, font.cell_width);
    const row_f = (ypos - padding_d - tb_d) / @as(f64, font.cell_height);

    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(AppWindow.term_cols))) AppWindow.term_cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(AppWindow.term_rows))) AppWindow.term_rows - 1 else @as(usize, @intFromFloat(row_f));

    return .{ .col = col, .row = row };
}

/// Update split focus based on mouse position (focus follows mouse).
pub fn updateFocusFromMouse(mouse_x: i32, mouse_y: i32) void {
    const t = tab.activeTab() orelse return;
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (mouse_x >= rect.x and mouse_x < rect.x + rect.width and
            mouse_y >= rect.y and mouse_y < rect.y + rect.height)
        {
            if (rect.handle != t.focused) {
                t.focused = rect.handle;
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
            }
            return;
        }
    }
}

/// Process all queued Win32 input events. Called once per frame from the main loop.
pub fn processEvents(win: *win32_backend.Window) void {
    processKeyEvents(win);
    processCharEvents(win);
    processMouseButtonEvents(win);
    processMouseMoveEvents(win);
    processMouseWheelEvents(win);
    processSizeChange(win);
}

fn processKeyEvents(win: *win32_backend.Window) void {
    while (win.key_events.pop()) |ev| {
        handleKey(ev);
    }
}

fn processCharEvents(win: *win32_backend.Window) void {
    while (win.char_events.pop()) |ev| {
        handleChar(ev);
    }
}

fn processMouseButtonEvents(win: *win32_backend.Window) void {
    while (win.mouse_button_events.pop()) |ev| {
        handleMouseButton(ev);
    }
}

fn processMouseMoveEvents(win: *win32_backend.Window) void {
    // Only process the latest move event (coalesce)
    var latest: ?win32_backend.MouseMoveEvent = null;
    while (win.mouse_move_events.pop()) |ev| {
        latest = ev;
    }
    if (latest) |ev| {
        handleMouseMove(ev);
    }
}

fn processMouseWheelEvents(win: *win32_backend.Window) void {
    while (win.mouse_wheel_events.pop()) |ev| {
        handleMouseWheel(ev);
    }
}

fn processSizeChange(win: *win32_backend.Window) void {
    if (!win.size_changed) return;
    win.size_changed = false;

    syncGridFromWindowSize(win.width, win.height);
}

fn handleChar(ev: win32_backend.CharEvent) void {
    overlays.startupShortcutsDismiss();
    if (overlays.sessionLauncherVisible()) {
        if (!ev.ctrl and !ev.alt) overlays.sessionLauncherInsertChar(ev.codepoint);
        return;
    }
    if (overlays.commandPaletteVisible()) {
        if (!ev.ctrl and !ev.alt) overlays.commandPaletteInsertChar(ev.codepoint);
        return;
    }
    // When tab rename is active, route chars to the rename buffer
    if (tab.g_tab_rename_active) {
        AppWindow.g_cursor_blink_visible = true;
        AppWindow.g_last_blink_time = std.time.milliTimestamp();
        tab.handleRenameChar(ev.codepoint);
        return;
    }
    if (!AppWindow.isActiveTabTerminal()) return;
    // Skip chars when Alt is held without Ctrl — those are part of Alt+key
    // combos (e.g. Shift+Alt+4) and shouldn't produce text input.
    // However, AltGr on international keyboards reports as Ctrl+Alt, so
    // we must allow chars when both Ctrl and Alt are held (AltGr chars).
    // This matches Ghostty's consumed_mods / effectiveMods approach.
    if (ev.alt and !ev.ctrl) return;
    const surface = AppWindow.activeSurface() orelse return;
    AppWindow.resetCursorBlink();
    {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        surface.terminal.scrollViewport(.bottom);
    }
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(ev.codepoint, &buf) catch return;
    writeToPty(surface, buf[0..len]);
}

fn handleKey(ev: win32_backend.KeyEvent) void {
    overlays.startupShortcutsDismiss();
    if (overlays.sessionLauncherVisible()) {
        overlays.sessionLauncherHandleKey(ev);
        return;
    }
    // Ctrl+Shift+P = command center (even during tab rename)
    if (ev.ctrl and ev.shift and ev.vk == 0x50) { // 'P'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        overlays.commandPaletteToggle();
        return;
    }
    if (overlays.commandPaletteVisible()) {
        switch (ev.vk) {
            win32_backend.VK_ESCAPE => overlays.commandPaletteClose(),
            win32_backend.VK_UP => overlays.commandPaletteMove(-1),
            win32_backend.VK_DOWN => overlays.commandPaletteMove(1),
            win32_backend.VK_RETURN => overlays.commandPaletteExecuteSelected(),
            win32_backend.VK_BACK => overlays.commandPaletteBackspace(),
            win32_backend.VK_DELETE => overlays.commandPaletteClearFilter(),
            else => {},
        }
        return;
    }
    if (overlays.settingsPageVisible()) {
        if (ev.vk == win32_backend.VK_ESCAPE) overlays.settingsPageClose();
        return;
    }
    // Ctrl+Shift+N = new window (even during tab rename)
    if (ev.ctrl and ev.shift and ev.vk == 0x4E) { // 'N'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        if (AppWindow.g_app) |app| {
            const hwnd = if (AppWindow.g_window) |w| w.hwnd else null;
            // Get CWD from active tab for working directory inheritance
            var cwd_buf: [260]u16 = undefined;
            var cwd: ?[]const u16 = null;
            if (AppWindow.activeSurface()) |surface| {
                if (surface.getCwd()) |unix_path| {
                    std.debug.print("CWD from OSC 7: {s}\n", .{unix_path});
                    if (AppWindow.wsl_paths.unixPathToWindows(unix_path, &cwd_buf)) |len| {
                        cwd = cwd_buf[0..len];
                        var path_u8: [260]u8 = undefined;
                        for (cwd_buf[0..len], 0..) |wc, i| {
                            path_u8[i] = @truncate(wc);
                        }
                        std.debug.print("Converted to Windows path: {s}\n", .{path_u8[0..len]});
                    } else {
                        std.debug.print("Failed to convert Unix path to Windows\n", .{});
                    }
                } else {
                    std.debug.print("No CWD from active surface (OSC 7 not received)\n", .{});
                }
            }
            app.requestNewWindow(hwnd, cwd);
        }
        return;
    }
    // Ctrl+Shift+T = new session chooser (even during tab rename)
    if (ev.ctrl and ev.shift and ev.vk == 0x54) { // 'T'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        overlays.sessionLauncherOpen();
        return;
    }
    // Ctrl+Shift+O = new split right (vertical divider)
    if (ev.ctrl and ev.shift and ev.vk == 0x4F) { // 'O'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        AppWindow.splitFocused(.right);
        return;
    }
    // Ctrl+Shift+E = new split down (horizontal divider)
    if (ev.ctrl and ev.shift and ev.vk == 0x45) { // 'E'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        AppWindow.splitFocused(.down);
        return;
    }
    // Ctrl+Shift+B = show/hide tab sidebar
    if (ev.ctrl and ev.shift and ev.vk == 0x42) { // 'B'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        toggleSidebar();
        return;
    }
    // When tab rename is active, handle special keys
    if (tab.g_tab_rename_active) {
        AppWindow.g_cursor_blink_visible = true;
        AppWindow.g_last_blink_time = std.time.milliTimestamp();
        tab.handleRenameKey(ev);
        return;
    }
    // Ctrl+Shift+C = copy
    if (ev.ctrl and ev.shift and ev.vk == 0x43) { // 'C'
        copySelectionToClipboard();
        return;
    }
    // Ctrl+Shift+V = paste
    if (ev.ctrl and ev.shift and ev.vk == 0x56) { // 'V'
        pasteFromClipboard();
        return;
    }
    // Ctrl+Shift+T and Ctrl+Shift+N are handled above (before rename guard)
    // Ctrl+W = close focused split (or tab if no splits, or app if last tab)
    if (ev.ctrl and ev.vk == 0x57) { // 'W'
        AppWindow.closeFocusedSplit();
        return;
    }
    // Ctrl+Alt+Arrows = goto split (spatial navigation)
    if (ev.ctrl and ev.alt and !ev.shift) {
        const dir: ?SplitTree.Spatial.Direction = switch (ev.vk) {
            win32_backend.VK_LEFT => .left,
            win32_backend.VK_RIGHT => .right,
            win32_backend.VK_UP => .up,
            win32_backend.VK_DOWN => .down,
            else => null,
        };
        if (dir) |d| {
            AppWindow.gotoSplit(.{ .spatial = d });
            return;
        }
    }
    // Ctrl+Shift+[ = goto previous split
    if (ev.ctrl and ev.shift and ev.vk == win32_backend.VK_OEM_4) { // '['
        AppWindow.gotoSplit(.previous_wrapped);
        return;
    }
    // Ctrl+Shift+] = goto next split
    if (ev.ctrl and ev.shift and ev.vk == win32_backend.VK_OEM_6) { // ']'
        AppWindow.gotoSplit(.next_wrapped);
        return;
    }
    // Ctrl+Shift+Z = equalize splits
    if (ev.ctrl and ev.shift and ev.vk == 0x5A) { // 'Z'
        AppWindow.equalizeSplits();
        return;
    }
    // Ctrl+Tab = next tab
    if (ev.ctrl and ev.vk == win32_backend.VK_TAB) {
        if (ev.shift) {
            // Ctrl+Shift+Tab = previous tab
            if (tab.g_active_tab > 0) AppWindow.switchTab(tab.g_active_tab - 1) else AppWindow.switchTab(tab.g_tab_count - 1);
        } else {
            AppWindow.switchTab((tab.g_active_tab + 1) % tab.g_tab_count);
        }
        return;
    }
    // Ctrl+1-9 = switch to tab N
    if (ev.ctrl and !ev.shift and ev.vk >= 0x31 and ev.vk <= 0x39) { // '1'-'9'
        const tab_idx = @as(usize, @intCast(ev.vk - 0x31));
        if (tab_idx < tab.g_tab_count) AppWindow.switchTab(tab_idx);
        return;
    }
    // Ctrl+, = open config
    if (ev.ctrl and ev.vk == win32_backend.VK_OEM_COMMA) {
        std.debug.print("[keybind] Ctrl+, pressed\n", .{});
        if (AppWindow.g_allocator) |alloc| Config.openConfigInEditor(alloc);
        return;
    }
    // Alt+Enter = toggle fullscreen
    if (ev.alt and ev.vk == win32_backend.VK_RETURN) {
        toggleFullscreen();
        return;
    }

    // Don't send input to PTY if active tab isn't the terminal
    if (!AppWindow.isActiveTabTerminal()) return;

    const surface = AppWindow.activeSurface() orelse return;

    // Track whether this keypress actually sends data to the PTY.
    // Like Ghostty, we only scroll-to-bottom when input is actually generated,
    // not for modifier-only keys or key combos that don't produce PTY output.
    var wrote_to_pty = false;

    const seq: ?[]const u8 = switch (ev.vk) {
        win32_backend.VK_RETURN => "\r",
        win32_backend.VK_BACK => "\x7f",
        win32_backend.VK_TAB => "\t",
        win32_backend.VK_ESCAPE => "\x1b",
        win32_backend.VK_UP => "\x1b[A",
        win32_backend.VK_DOWN => "\x1b[B",
        win32_backend.VK_RIGHT => "\x1b[C",
        win32_backend.VK_LEFT => "\x1b[D",
        win32_backend.VK_HOME => "\x1b[H",
        win32_backend.VK_END => "\x1b[F",
        win32_backend.VK_PRIOR => blk: { // Page Up
            if (ev.shift) {
                surface.render_state.mutex.lock();
                surface.terminal.scrollViewport(.{ .delta = -@as(isize, AppWindow.term_rows / 2) });
                surface.render_state.mutex.unlock();
                overlays.scrollbarShow();
                break :blk null;
            }
            break :blk "\x1b[5~";
        },
        win32_backend.VK_NEXT => blk: { // Page Down
            if (ev.shift) {
                surface.render_state.mutex.lock();
                surface.terminal.scrollViewport(.{ .delta = @as(isize, AppWindow.term_rows / 2) });
                surface.render_state.mutex.unlock();
                overlays.scrollbarShow();
                break :blk null;
            }
            break :blk "\x1b[6~";
        },
        win32_backend.VK_INSERT => "\x1b[2~",
        win32_backend.VK_DELETE => "\x1b[3~",
        win32_backend.VK_F11 => blk: {
            toggleFullscreen();
            break :blk null;
        },
        else => blk: {
            // Ctrl+A through Ctrl+Z
            if (ev.ctrl and ev.vk >= 0x41 and ev.vk <= 0x5A) {
                // Don't send Ctrl+C/V when shift is held (those are copy/paste)
                if (!ev.shift) {
                    const ctrl_char: u8 = @intCast(ev.vk - 0x41 + 1);
                    writeToPty(surface, &[_]u8{ctrl_char});
                    wrote_to_pty = true;
                }
            }
            break :blk null;
        },
    };

    if (seq) |s| {
        writeToPty(surface, s);
        wrote_to_pty = true;
    }

    // Only scroll to bottom and reset cursor blink when we actually sent
    // data to the PTY. This matches Ghostty's behavior: modifier-only keys,
    // unbound key combos (like Shift+Alt+4), and scroll keys don't snap
    // the viewport to the bottom.
    if (wrote_to_pty) {
        AppWindow.resetCursorBlink();
        surface.render_state.mutex.lock();
        surface.terminal.scrollViewport(.bottom);
        surface.render_state.mutex.unlock();
    }
}

fn hitTestSidebarTab(xpos: f64, ypos: f64) ?usize {
    if (!tab.g_sidebar_visible) return null;
    if (xpos < 0 or xpos >= @as(f64, titlebar.SIDEBAR_WIDTH)) return null;

    const list_top = titlebarHeight() + @as(f64, titlebar.SIDEBAR_HEADER_H) + 6;
    if (ypos < list_top) return null;

    const idx_f = (ypos - list_top) / @as(f64, titlebar.SIDEBAR_ROW_H);
    const idx: usize = @intFromFloat(@floor(idx_f));
    if (idx >= tab.g_tab_count) return null;
    return idx;
}

fn hitTestSidebarPlusButton(xpos: f64, ypos: f64) bool {
    if (!tab.g_sidebar_visible) return false;
    const top = titlebarHeight();
    const plus_w: f64 = 42;
    const plus_x = @as(f64, titlebar.SIDEBAR_WIDTH) - plus_w - 6;
    return xpos >= plus_x and xpos < plus_x + plus_w and
        ypos >= top and ypos < top + @as(f64, titlebar.SIDEBAR_HEADER_H);
}

fn hitTestSidebarTabCloseButton(xpos: f64, ypos: f64, tab_idx: usize) bool {
    if (!tab.g_sidebar_visible or tab_idx >= tab.g_tab_count or tab.g_tab_count <= 1) return false;
    const row = hitTestSidebarTab(xpos, ypos) orelse return false;
    if (row != tab_idx) return false;
    const close_x = @as(f64, titlebar.SIDEBAR_WIDTH - tab.TAB_CLOSE_BTN_W - 4);
    return xpos >= close_x and xpos < close_x + @as(f64, tab.TAB_CLOSE_BTN_W);
}

fn hitTestConfigButton(xpos: f64, ypos: f64) bool {
    const titlebar_h = titlebarHeight();
    if (ypos < 0 or ypos >= titlebar_h) return false;

    const win = AppWindow.g_window orelse return false;
    const window_width: f64 = @floatFromInt(win.width);
    const caption_w: f64 = 46 * 3;
    const config_w: f64 = @floatCast(titlebar.TITLEBAR_CONFIG_W);
    const config_x = window_width - caption_w - config_w;
    return xpos >= config_x and xpos < config_x + config_w;
}

fn handleTopbarPress(xpos: f64) void {
    if (xpos >= 0 and xpos < @as(f64, titlebar.TITLEBAR_TOGGLE_W)) {
        toggleSidebar();
        return;
    }

    if (hitTestConfigButton(xpos, titlebarHeight() / 2)) {
        overlays.settingsPageOpen();
    }
}

fn handleSidebarPress(xpos: f64, ypos: f64) void {
    if (tab.g_tab_rename_active) tab.commitTabRename();

    if (hitTestSidebarPlusButton(xpos, ypos)) {
        overlays.sessionLauncherOpen();
        return;
    }

    if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
        if (tab.g_tab_count > 1 and tab.g_tab_close_opacity[tab_idx] > 0.1 and hitTestSidebarTabCloseButton(xpos, ypos, tab_idx)) {
            tab.g_tab_close_pressed = tab_idx;
            return;
        }
        AppWindow.switchTab(tab_idx);
    }
}

fn handleMouseButton(ev: win32_backend.MouseButtonEvent) void {
    overlays.startupShortcutsDismiss();
    if (overlays.sessionLauncherVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.sessionLauncherExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.sessionLauncherContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.sessionLauncherClose();
            }
        }
        return;
    }
    if (overlays.settingsPageVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.settingsPageExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.settingsPageContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.settingsPageClose();
            }
        }
        return;
    }
    if (overlays.commandPaletteVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.commandPaletteExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.commandPaletteContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.commandPaletteClose();
            }
        }
        return;
    }
    // Double-click on tab text to rename, elsewhere to maximize
    if (ev.button == .left and ev.action == .double_click) {
        const xpos: f64 = @floatFromInt(ev.x);
        const xf: f32 = @floatFromInt(ev.x);
        const titlebar_h: f64 = titlebarHeight();
        const ypos: f64 = @floatFromInt(ev.y);
        if (ypos < titlebar_h) {
            if (hitTestConfigButton(xpos, ypos)) {
                overlays.settingsPageOpen();
            } else if (xpos >= @as(f64, titlebar.TITLEBAR_TOGGLE_W)) {
                if (AppWindow.g_window) |w| {
                    if (win32_backend.IsZoomed(w.hwnd) != 0) {
                        _ = win32_backend.ShowWindow(w.hwnd, win32_backend.SW_RESTORE);
                    } else {
                        _ = win32_backend.ShowWindow(w.hwnd, win32_backend.SW_MAXIMIZE);
                    }
                }
            }
        } else if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
            // Only rename if clicking on the rendered title text itself.
            if (tab_idx < AppWindow.MAX_TABS and
                xf >= tab.g_tab_text_x_start[tab_idx] and xf <= tab.g_tab_text_x_end[tab_idx] and
                ypos >= @as(f64, @floatCast(tab.g_tab_text_y_start[tab_idx])) and
                ypos <= @as(f64, @floatCast(tab.g_tab_text_y_end[tab_idx])))
            {
                tab.startTabRename(tab_idx);
            }
        }
        return;
    }

    // Middle-click on tab to close it
    if (ev.button == .middle and ev.action == .release) {
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
            if (tab.g_tab_count <= 1) {
                AppWindow.g_should_close = true;
            } else {
                AppWindow.closeTab(tab_idx);
            }
        }
        return;
    }

    if (ev.button == .left) {
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        const titlebar_h: f64 = titlebarHeight();

        if (ev.action == .press) {
            // Commit rename on any click
            if (tab.g_tab_rename_active) tab.commitTabRename();

            // Check if click is in the titlebar (tab bar area)
            if (ypos < titlebar_h) {
                handleTopbarPress(xpos);
                return;
            }

            if (tab.g_sidebar_visible and xpos < @as(f64, titlebar.SIDEBAR_WIDTH)) {
                handleSidebarPress(xpos, ypos);
                return;
            }

            // Click in terminal content area: update split focus
            updateFocusFromMouse(@intFromFloat(xpos), @intFromFloat(ypos));

            // Check if click is on the scrollbar
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const tb_f: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
            const top_pad: f32 = 10 + tb_f;
            const sb_opacity = if (AppWindow.activeSurface()) |s| s.scrollbar_opacity else 0;
            if (sb_opacity > 0 and overlays.scrollbarHitTest(xpos, ypos, w_f, h_f, top_pad)) {
                overlays.g_scrollbar_dragging = true;
                overlays.scrollbarShow();
                // Calculate drag offset within thumb
                if (overlays.scrollbarThumbHitTest(ypos, h_f, top_pad)) {
                    // Clicked on thumb — offset from top of thumb
                    const geo = overlays.scrollbarGeometry(h_f, top_pad) orelse return;
                    const thumb_top_px = h_f - (geo.thumb_y + geo.thumb_h); // convert GL→pixel
                    overlays.g_scrollbar_drag_offset = @as(f32, @floatCast(ypos)) - thumb_top_px;
                } else {
                    // Clicked on track — jump thumb center to click position
                    const geo = overlays.scrollbarGeometry(h_f, top_pad) orelse return;
                    overlays.g_scrollbar_drag_offset = geo.thumb_h / 2;
                    overlays.scrollbarDrag(ypos, h_f, top_pad);
                }
                return;
            }

            // Check if click is on a split divider
            if (split_layout.hitTestDivider(ev.x, ev.y)) |hit| {
                g_divider_dragging = true;
                g_divider_drag_handle = hit.handle;
                g_divider_drag_layout = hit.layout;
                // Initialize per-surface resize tracking with current sizes
                // so we only show overlays on surfaces that actually change
                if (AppWindow.activeTab()) |tb| {
                    var it = tb.tree.iterator();
                    while (it.next()) |entry| {
                        entry.surface.resize_overlay_active = false;
                        entry.surface.resize_overlay_last_cols = entry.surface.size.grid.cols;
                        entry.surface.resize_overlay_last_rows = entry.surface.size.grid.rows;
                    }
                }
                return;
            }

            // Find which surface was clicked and focus it
            const clicked_surface = split_layout.surfaceAtPoint(@intFromFloat(xpos), @intFromFloat(ypos)) orelse AppWindow.activeSurface() orelse return;

            // Focus the clicked split if different from current focus
            if (AppWindow.activeTab()) |tb| {
                for (0..split_layout.g_split_rect_count) |i| {
                    if (split_layout.g_split_rects[i].surface == clicked_surface) {
                        tb.focused = split_layout.g_split_rects[i].handle;
                        break;
                    }
                }
            }

            const cell_pos = mouseToCell(xpos, ypos);
            const abs_row = viewportOffset() + cell_pos.row;
            // Start selection on the clicked surface
            clicked_surface.selection.start_col = cell_pos.col;
            clicked_surface.selection.start_row = abs_row;
            clicked_surface.selection.end_col = cell_pos.col;
            clicked_surface.selection.end_row = abs_row;
            clicked_surface.selection.active = false;
            g_selecting = true;
            g_click_x = xpos;
            g_click_y = ypos;
        } else {
            // Mouse up
            overlays.g_scrollbar_dragging = false;

            // Handle divider drag release
            if (g_divider_dragging) {
                g_divider_dragging = false;
                g_divider_drag_handle = null;
                g_divider_drag_layout = null;
                // Reset per-surface resize overlay state
                if (AppWindow.activeTab()) |tb| {
                    var it = tb.tree.iterator();
                    while (it.next()) |entry| {
                        entry.surface.resize_overlay_active = false;
                    }
                }
                // Cursor will be reset in handleMouseMove
                return;
            }

            // Handle close button release — close tab if still on the close button
            if (tab.g_tab_close_pressed) |pressed_idx| {
                tab.g_tab_close_pressed = null;
                if (pressed_idx < tab.g_tab_count and hitTestSidebarTabCloseButton(xpos, ypos, pressed_idx)) {
                    if (tab.g_tab_count <= 1) {
                        AppWindow.g_should_close = true;
                    } else {
                        AppWindow.closeTab(pressed_idx);
                    }
                }
                return;
            }

            if (plus_btn_pressed) {
                plus_btn_pressed = false;
                // Only fire if still in the + button area
                if (hitTestSidebarPlusButton(xpos, ypos)) {
                    overlays.sessionLauncherOpen();
                }
                return;
            }
            g_selecting = false;
        }
    }
}

fn handleTabBarPress(xpos: f64) void {
    // Commit any active rename when clicking in the tab bar
    if (tab.g_tab_rename_active) {
        tab.commitTabRename();
    }
    const win = AppWindow.g_window orelse return;
    const window_width: f64 = blk: {
        var rect: win32_backend.RECT = undefined;
        _ = win32_backend.GetClientRect(win.hwnd, &rect);
        break :blk @floatFromInt(rect.right);
    };

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    // Check which tab was clicked — also check close button
    var cursor: f64 = 0;
    for (0..num_tabs) |tab_idx| {
        if (xpos >= cursor and xpos < cursor + tab_w) {
            // Check if the close button was clicked (centered on shortcut position)
            if (num_tabs > 1 and tab.g_tab_close_opacity[tab_idx] > 0.1) {
                const sc_w: f64 = @floatCast(titlebar.titlebarGlyphAdvance('^') + titlebar.titlebarGlyphAdvance(if (tab_idx == 9) @as(u32, '0') else @as(u32, @intCast('1' + tab_idx))));
                const sc_center = cursor + tab_w - 12 - sc_w / 2;
                const close_btn_x = sc_center - tab.TAB_CLOSE_BTN_W / 2;
                if (xpos >= close_btn_x and xpos < close_btn_x + tab.TAB_CLOSE_BTN_W) {
                    tab.g_tab_close_pressed = tab_idx;
                    return;
                }
            }
            AppWindow.switchTab(tab_idx);
            return;
        }
        cursor += tab_w;
    }

    // Check if + button was pressed
    if (show_plus and xpos >= cursor and xpos < cursor + plus_btn_w) {
        plus_btn_pressed = true;
    }
}

fn hitTestTab(xpos: f64) ?usize {
    const win = AppWindow.g_window orelse return null;
    const window_width: f64 = blk: {
        var rect: win32_backend.RECT = undefined;
        _ = win32_backend.GetClientRect(win.hwnd, &rect);
        break :blk @floatFromInt(rect.right);
    };

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    var cursor: f64 = 0;
    for (0..num_tabs) |tab_idx| {
        if (xpos >= cursor and xpos < cursor + tab_w) {
            return tab_idx;
        }
        cursor += tab_w;
    }
    return null;
}

fn hitTestTabCloseButton(xpos: f64, tab_idx: usize) bool {
    const window_width: f64 = blk: {
        const win = AppWindow.g_window orelse break :blk 800.0;
        var rect: win32_backend.RECT = undefined;
        _ = win32_backend.GetClientRect(win.hwnd, &rect);
        break :blk @floatFromInt(rect.right);
    };

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    const tab_x = tab_w * @as(f64, @floatFromInt(tab_idx));
    const sc_w: f64 = @floatCast(titlebar.titlebarGlyphAdvance('^') + titlebar.titlebarGlyphAdvance(if (tab_idx == 9) @as(u32, '0') else @as(u32, @intCast('1' + tab_idx))));
    const sc_center = tab_x + tab_w - 12 - sc_w / 2;
    const close_btn_x = sc_center - tab.TAB_CLOSE_BTN_W / 2;
    return xpos >= close_btn_x and xpos < close_btn_x + tab.TAB_CLOSE_BTN_W;
}

fn hitTestPlusButton(xpos: f64) bool {
    const win = AppWindow.g_window orelse return false;
    const window_width: f64 = blk: {
        var rect: win32_backend.RECT = undefined;
        _ = win32_backend.GetClientRect(win.hwnd, &rect);
        break :blk @floatFromInt(rect.right);
    };

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    if (tab.g_tab_count <= 1) return false;

    const right_reserved: f64 = caption_area_w + gap_w + plus_btn_w;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = tab_area_w / @as(f64, @floatFromInt(tab.g_tab_count));
    const plus_x = tab_w * @as(f64, @floatFromInt(tab.g_tab_count));

    return xpos >= plus_x and xpos < plus_x + plus_btn_w;
}

fn handleMouseMove(ev: win32_backend.MouseMoveEvent) void {
    const xpos: f64 = @floatFromInt(ev.x);
    const ypos: f64 = @floatFromInt(ev.y);

    // Handle divider dragging
    if (g_divider_dragging) {
        if (g_divider_drag_handle) |handle| {
            const active_tab = AppWindow.activeTab() orelse return;
            const allocator = AppWindow.g_allocator orelse return;

            // Get spatial info for this split
            var spatial = active_tab.tree.spatial(allocator) catch return;
            defer spatial.deinit(allocator);

            // Get content area dimensions
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const sidebar_w = titlebar.sidebarWidth();
            const content_x: f32 = sidebar_w + @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING));
            const content_y: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
            const content_w: f32 = @as(f32, @floatFromInt(fb.width)) - sidebar_w - @as(f32, @floatFromInt(2 * split_layout.DEFAULT_PADDING));
            const content_h: f32 = @floatFromInt(@as(i32, @intCast(fb.height)) - win32_backend.TITLEBAR_HEIGHT - @as(i32, @intCast(split_layout.DEFAULT_PADDING)));

            const slot = spatial.slots[handle.idx()];
            const layout = g_divider_drag_layout orelse return;

            // Calculate new ratio based on mouse position
            const new_ratio: f16 = switch (layout) {
                .horizontal => blk: {
                    const slot_x = content_x + @as(f32, @floatCast(slot.x)) * content_w;
                    const slot_w = @as(f32, @floatCast(slot.width)) * content_w;
                    const mouse_x: f32 = @floatCast(xpos);
                    // Clamp ratio to 0.1-0.9 to prevent splits from becoming too small
                    break :blk @floatCast(@max(0.1, @min(0.9, (mouse_x - slot_x) / slot_w)));
                },
                .vertical => blk: {
                    const slot_y = content_y + @as(f32, @floatCast(slot.y)) * content_h;
                    const slot_h = @as(f32, @floatCast(slot.height)) * content_h;
                    const mouse_y: f32 = @floatCast(ypos);
                    break :blk @floatCast(@max(0.1, @min(0.9, (mouse_y - slot_y) / slot_h)));
                },
            };

            // Update the ratio in place
            active_tab.tree.resizeInPlace(handle, new_ratio);

            // Force layout recalculation and redraw
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        }
        return;
    }

    // Focus follows mouse: check if mouse is over a different split
    if (AppWindow.g_focus_follows_mouse) {
        updateFocusFromMouse(@intFromFloat(xpos), @intFromFloat(ypos));
    }

    // Update scrollbar hover state
    const win = AppWindow.g_window orelse return;
    const fb = win.getFramebufferSize();
    const w_f: f32 = @floatFromInt(fb.width);
    const h_f: f32 = @floatFromInt(fb.height);
    const tb_f: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
    const top_pad: f32 = 10 + tb_f;

    const was_hover = overlays.g_scrollbar_hover;
    overlays.g_scrollbar_hover = overlays.scrollbarHitTest(xpos, ypos, w_f, h_f, top_pad);
    const sb_opacity2 = if (AppWindow.activeSurface()) |s| s.scrollbar_opacity else 0;
    if (overlays.g_scrollbar_hover and !was_hover and sb_opacity2 > 0) {
        overlays.scrollbarShow(); // Reset fade timer when entering scrollbar area
    }

    // Handle scrollbar drag
    if (overlays.g_scrollbar_dragging) {
        overlays.scrollbarDrag(ypos, h_f, top_pad);
        return;
    }

    // Check for divider hover and update cursor
    if (!overlays.g_scrollbar_hover and !g_selecting) {
        if (split_layout.hitTestDivider(ev.x, ev.y)) |hit| {
            // Set resize cursor based on layout
            const cursor_id = switch (hit.layout) {
                .horizontal => win32_backend.IDC_SIZEWE, // left-right resize
                .vertical => win32_backend.IDC_SIZENS, // up-down resize
            };
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, cursor_id));
            g_divider_hover = true;
        } else if (g_divider_hover) {
            // Reset to default cursor when leaving divider
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_ARROW));
            g_divider_hover = false;
        }
    }

    // Normal selection handling
    if (!g_selecting) return;

    const cell_pos = mouseToCell(xpos, ypos);
    const abs_row = viewportOffset() + cell_pos.row;
    AppWindow.activeSelection().end_col = cell_pos.col;
    AppWindow.activeSelection().end_row = abs_row;

    const threshold = font.cell_width * 0.6;
    const padding_d: f64 = 10;
    const sidebar_d: f64 = @floatCast(titlebar.sidebarWidth());
    const click_cell_x = g_click_x - sidebar_d - padding_d - @as(f64, @floatFromInt(AppWindow.activeSelection().start_col)) * @as(f64, font.cell_width);
    const drag_cell_x = xpos - sidebar_d - padding_d - @as(f64, @floatFromInt(cell_pos.col)) * @as(f64, font.cell_width);

    const same_cell = (AppWindow.activeSelection().start_col == cell_pos.col and AppWindow.activeSelection().start_row == abs_row);
    if (same_cell) {
        const moved_right = drag_cell_x >= threshold and click_cell_x < threshold;
        const moved_left = drag_cell_x < threshold and click_cell_x >= threshold;
        AppWindow.activeSelection().active = moved_right or moved_left;
    } else {
        AppWindow.activeSelection().active = true;
    }
}

fn handleMouseWheel(ev: win32_backend.MouseWheelEvent) void {
    overlays.startupShortcutsDismiss();
    if (tab.g_sidebar_visible and ev.xpos >= 0 and ev.xpos < @as(i32, @intFromFloat(titlebar.SIDEBAR_WIDTH))) return;
    // Scroll the surface under the mouse cursor (like Ghostty), not the focused surface.
    // Fall back to focused surface if mouse is not over any split.
    const surface = split_layout.surfaceAtPoint(ev.xpos, ev.ypos) orelse AppWindow.activeSurface() orelse return;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();
    // WHEEL_DELTA is 120 per notch. Convert to lines (3 lines per notch, like GLFW).
    const notches = @as(f64, @floatFromInt(ev.delta)) / 120.0;
    const delta: isize = @intFromFloat(-notches * 3);
    surface.terminal.scrollViewport(.{ .delta = delta });

    // Show scrollbar for the scrolled surface
    surface.scrollbar_opacity = 1.0;
    surface.scrollbar_show_time = std.time.milliTimestamp();
}

// --- Clipboard (Win32 native) ---

pub fn copySelectionToClipboard() void {
    const surface = AppWindow.activeSurface() orelse return;
    const allocator = AppWindow.g_allocator orelse return;
    const win = AppWindow.g_window orelse return;

    if (!AppWindow.activeSelection().active) return;

    var start_row = AppWindow.activeSelection().start_row;
    var start_col = AppWindow.activeSelection().start_col;
    var end_row = AppWindow.activeSelection().end_row;
    var end_col = AppWindow.activeSelection().end_col;

    if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
        std.mem.swap(usize, &start_row, &end_row);
        std.mem.swap(usize, &start_col, &end_col);
    }

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);

    // Lock while reading terminal cells
    surface.render_state.mutex.lock();
    const screen = surface.terminal.screens.active;
    const vp_off = surface.terminal.screens.active.pages.scrollbar().offset;
    var row: usize = start_row;
    while (row <= end_row) : (row += 1) {
        // Convert absolute row to viewport-relative for getCell
        const vp_row = if (row >= vp_off) row - vp_off else continue;
        if (vp_row >= AppWindow.term_rows) continue;

        const row_start_col = if (row == start_row) start_col else 0;
        const row_end_col = if (row == end_row) end_col else AppWindow.term_cols - 1;

        var col: usize = row_start_col;
        while (col <= row_end_col) : (col += 1) {
            const cell_data = screen.pages.getCell(.{ .viewport = .{
                .x = @intCast(col),
                .y = @intCast(vp_row),
            } }) orelse continue;

            const cp = cell_data.cell.codepoint();
            if (cp == 0 or cp == ' ') {
                text.append(allocator, ' ') catch continue;
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
                text.appendSlice(allocator, buf[0..len]) catch continue;
            }
        }
        if (row < end_row) {
            text.append(allocator, '\n') catch {};
        }
    }
    surface.render_state.mutex.unlock();

    if (text.items.len == 0) return;

    // Win32 clipboard: OpenClipboard → EmptyClipboard → SetClipboardData → CloseClipboard
    if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
    defer _ = win32_backend.CloseClipboard();
    _ = win32_backend.EmptyClipboard();

    // Clipboard wants a GlobalAlloc'd GMEM_MOVEABLE buffer with null-terminated data
    const size = text.items.len + 1;
    const hmem = win32_backend.GlobalAlloc(0x0002, size) orelse return; // GMEM_MOVEABLE
    const ptr = win32_backend.GlobalLock(hmem) orelse return;
    const dest: [*]u8 = @ptrCast(ptr);
    @memcpy(dest[0..text.items.len], text.items);
    dest[text.items.len] = 0;
    _ = win32_backend.GlobalUnlock(hmem);

    _ = win32_backend.SetClipboardData(1, hmem); // CF_TEXT = 1
    std.debug.print("Copied {} bytes to clipboard\n", .{text.items.len});
}

pub fn pasteFromClipboard() void {
    const surface = AppWindow.activeSurface() orelse return;
    const win = AppWindow.g_window orelse return;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
    defer _ = win32_backend.CloseClipboard();

    const hmem = win32_backend.GetClipboardData(1) orelse return; // CF_TEXT
    const ptr = win32_backend.GlobalLock(hmem) orelse return;
    defer _ = win32_backend.GlobalUnlock(hmem);

    const data: [*]const u8 = @ptrCast(ptr);
    var len: usize = 0;
    while (data[len] != 0) : (len += 1) {}

    if (len > 0) {
        std.debug.print("Pasting {} bytes from clipboard\n", .{len});
        writeToPty(surface, data[0..len]);
    }
}

pub fn writeTextToActivePty(text: []const u8) void {
    const surface = AppWindow.activeSurface() orelse return;
    writeToPty(surface, text);
}

pub fn writeTextToSurfacePty(surface: *Surface, text: []const u8) void {
    writeToPty(surface, text);
}

// --- Fullscreen toggle (Win32 native) ---

pub fn toggleFullscreen() void {
    const win = AppWindow.g_window orelse return;

    if (is_fullscreen) {
        // Restore windowed mode
        _ = win32_backend.SetWindowLongW(win.hwnd, -16, @bitCast(saved_style)); // GWL_STYLE
        _ = win32_backend.SetWindowPos(
            win.hwnd,
            null,
            saved_rect.left,
            saved_rect.top,
            saved_rect.right - saved_rect.left,
            saved_rect.bottom - saved_rect.top,
            0x0020 | 0x0040, // SWP_FRAMECHANGED | SWP_SHOWWINDOW
        );
        is_fullscreen = false;
        if (AppWindow.g_window) |w| w.is_fullscreen = false;
        std.debug.print("Exited fullscreen\n", .{});
    } else {
        // Save current state
        _ = win32_backend.GetWindowRect(win.hwnd, &saved_rect);
        saved_style = @bitCast(win32_backend.GetWindowLongW(win.hwnd, -16));

        // Set borderless style
        const new_style = saved_style & ~@as(u32, 0x00CF0000); // remove WS_OVERLAPPEDWINDOW
        _ = win32_backend.SetWindowLongW(win.hwnd, -16, @bitCast(new_style));

        // Get monitor info for the monitor containing this window
        const monitor = win32_backend.MonitorFromWindow(win.hwnd, 0x00000002) orelse return; // MONITOR_DEFAULTTONEAREST
        var mi = win32_backend.MONITORINFO{ .cbSize = @sizeOf(win32_backend.MONITORINFO) };
        if (win32_backend.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = win32_backend.SetWindowPos(
                win.hwnd,
                null,
                mi.rcMonitor.left,
                mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                0x0020 | 0x0040, // SWP_FRAMECHANGED | SWP_SHOWWINDOW
            );
        }
        is_fullscreen = true;
        if (AppWindow.g_window) |w| w.is_fullscreen = true;
        std.debug.print("Entered fullscreen\n", .{});
    }
}
