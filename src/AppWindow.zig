//! AppWindow — per-window state and rendering.
//!
//! This module contains all the terminal rendering, input handling, and
//! per-window state. Currently uses module-level globals for state, which
//! will be converted to struct fields in a future refactoring step.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const freetype = @import("freetype");
const Pty = @import("pty.zig").Pty;
const directwrite = @import("directwrite.zig");
const Config = @import("config.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("split_tree.zig");
const renderer = @import("renderer.zig");
const win32_backend = @import("win32.zig");
const App = @import("App.zig");
const Renderer = @import("Renderer.zig");
pub const tab = @import("appwindow/tab.zig");
pub const font = @import("appwindow/font.zig");
pub const cell_renderer = @import("appwindow/cell_renderer.zig");
pub const titlebar = @import("appwindow/titlebar.zig");

const c = @cImport({
    @cInclude("glad/gl.h");
});

// Type aliases from config module
const Color = Config.Color;
const Theme = Config.Theme;
const CursorStyle = Config.CursorStyle;
const hexToColor = Config.hexToColor;
const parseColor = Config.parseColor;

/// AppWindow represents a single terminal window.
/// For now, this is a thin wrapper that uses module-level globals.
/// TODO: Move all globals into this struct for true multi-window support.
pub const AppWindow = @This();

allocator: std.mem.Allocator,
app: *App,

/// Initialize an AppWindow with the given App.
pub fn init(allocator: std.mem.Allocator, app: *App) !AppWindow {
    // Store allocator globally for now (used by many functions)
    g_allocator = allocator;

    // Store app pointer globally for requestNewWindow
    g_app = app;

    // Apply config from App to globals
    g_theme = app.theme;
    g_force_rebuild = true;
    g_cursor_style = app.cursor_style;
    g_cursor_blink = app.cursor_blink;
    g_debug_fps = app.debug_fps;
    g_debug_draw_calls = app.debug_draw_calls;

    // Split config
    g_unfocused_split_opacity = app.unfocused_split_opacity;
    g_focus_follows_mouse = app.focus_follows_mouse;
    g_split_divider_color = app.split_divider_color;

    // Apply window size from config
    term_cols = app.initial_cols;
    term_rows = app.initial_rows;

    tab.g_scrollback_limit = app.scrollback_limit;

    // Copy shell command from App
    @memcpy(tab.g_shell_cmd_buf[0..app.shell_cmd_len], app.shell_cmd_buf[0..app.shell_cmd_len]);
    tab.g_shell_cmd_buf[app.shell_cmd_len] = 0;
    tab.g_shell_cmd_len = app.shell_cmd_len;

    // Store config values we need for init
    g_requested_font = app.font_family;
    g_requested_weight = app.font_weight;
    font.g_font_size = app.font_size;
    g_shader_path = app.shader_path;
    g_start_maximize = app.maximize;
    g_start_fullscreen = app.fullscreen;
    tab.g_forced_title = app.title;

    // Get initial CWD for this window (if any) - copy into thread-local buffer
    g_initial_cwd_len = app.takeInitialCwd(&g_initial_cwd_buf);

    return AppWindow{
        .allocator = allocator,
        .app = app,
    };
}

/// Run the window's main loop. Blocks until the window is closed.
pub fn run(self: *AppWindow) void {
    runMainLoop(self.allocator) catch |err| {
        std.debug.print("AppWindow run failed: {}\n", .{err});
    };
}

/// Get the Win32 HWND for this window (for cross-thread communication).
pub fn getHwnd(self: *AppWindow) ?win32_backend.HWND {
    _ = self;
    if (g_window) |w| return w.hwnd;
    return null;
}

/// Clean up resources.
pub fn deinit(self: *AppWindow) void {
    // Clean up all tabs
    for (0..tab.g_tab_count) |ti| {
        if (tab.g_tabs[ti]) |t| {
            t.deinit(self.allocator);
            self.allocator.destroy(t);
            tab.g_tabs[ti] = null;
        }
    }
    tab.g_tab_count = 0;
}

// ============================================================================
// Module-level state (will be moved into AppWindow struct in future)
// ============================================================================

// App pointer for requestNewWindow
threadlocal var g_app: ?*App = null;

// Initial CWD for this window (used when spawning the first tab)
threadlocal var g_initial_cwd_buf: [260]u16 = undefined;
threadlocal var g_initial_cwd_len: usize = 0;

// Stored config values for deferred initialization
threadlocal var g_requested_font: []const u8 = "";
threadlocal var g_requested_weight: directwrite.DWRITE_FONT_WEIGHT = .NORMAL;
threadlocal var g_shader_path: ?[]const u8 = null;
threadlocal var g_start_maximize: bool = false;
threadlocal var g_start_fullscreen: bool = false;

// Global theme (set at startup via config)
pub threadlocal var g_theme: Theme = Theme.default();

/// Convert a Unix-style path to a Windows path (UTF-16).
/// Handles:
///   /mnt/c/Users/... -> C:\Users\...
///   /home/user/...   -> \\wsl.localhost\<distro>\home\user\...
/// Returns the length of the converted path, or null if conversion failed.
fn unixPathToWindows(unix_path: []const u8, out: *[260]u16) ?usize {
    // Handle WSL /mnt/X/... paths (Windows drives mounted in WSL)
    if (unix_path.len >= 7 and std.mem.startsWith(u8, unix_path, "/mnt/")) {
        const drive_letter = unix_path[5];
        if (drive_letter >= 'a' and drive_letter <= 'z') {
            // Convert /mnt/c/foo/bar -> C:\foo\bar
            out[0] = std.ascii.toUpper(drive_letter);
            out[1] = ':';
            var out_idx: usize = 2;

            // Copy the rest of the path, converting / to \
            const rest = unix_path[6..]; // Skip "/mnt/c"
            for (rest) |ch| {
                if (out_idx >= out.len - 1) break;
                out[out_idx] = if (ch == '/') '\\' else ch;
                out_idx += 1;
            }
            out[out_idx] = 0;
            return out_idx;
        }
    }

    // Handle pure Linux paths (e.g., /home/user) via \\wsl.localhost\<distro>\path
    if (unix_path.len > 0 and unix_path[0] == '/') {
        // Try to get distro name from OSC 7 hostname (file://hostname/path)
        // or fall back to querying WSL for the default distro
        const distro = getWslDistroName() orelse return null;

        // Build \\wsl.localhost\<distro><path>
        const prefix = "\\\\wsl.localhost\\";
        var out_idx: usize = 0;

        // Write prefix
        for (prefix) |ch| {
            if (out_idx >= out.len - 1) return null;
            out[out_idx] = ch;
            out_idx += 1;
        }

        // Write distro name
        for (distro) |ch| {
            if (out_idx >= out.len - 1) return null;
            out[out_idx] = ch;
            out_idx += 1;
        }

        // Write path, converting / to \
        for (unix_path) |ch| {
            if (out_idx >= out.len - 1) break;
            out[out_idx] = if (ch == '/') '\\' else ch;
            out_idx += 1;
        }

        out[out_idx] = 0;
        return out_idx;
    }

    return null;
}

/// Get the WSL distro name by running `wsl.exe --list --quiet` and taking the first line.
/// Returns a static buffer with the distro name, or null if detection failed.
fn getWslDistroName() ?[]const u8 {
    const Static = struct {
        threadlocal var cached: bool = false;
        threadlocal var distro_buf: [64]u8 = undefined;
        threadlocal var distro_len: usize = 0;
    };

    // Return cached result if available
    if (Static.cached) {
        if (Static.distro_len > 0) {
            return Static.distro_buf[0..Static.distro_len];
        }
        return null;
    }
    Static.cached = true;

    // Run wsl.exe --list --quiet to get distro names
    const allocator = g_allocator orelse return null;

    var child = std.process.Child.init(&.{ "wsl.exe", "--list", "--quiet" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    // Read first line of output (default/first distro)
    const stdout = child.stdout orelse return null;
    var buf: [256]u8 = undefined;
    const n = stdout.read(&buf) catch 0;

    _ = child.wait() catch {};

    if (n == 0) return null;

    // WSL outputs UTF-16LE, convert to UTF-8
    // Find first line (up to \r\n or \n)
    var i: usize = 0;
    var out_idx: usize = 0;
    while (i + 1 < n and out_idx < Static.distro_buf.len) {
        const lo = buf[i];
        const hi = buf[i + 1];

        // Skip BOM if present
        if (i == 0 and lo == 0xFF and hi == 0xFE) {
            i += 2;
            continue;
        }

        // End of line?
        if (lo == '\r' or lo == '\n' or lo == 0) break;

        // ASCII character (hi should be 0 for ASCII)
        if (hi == 0 and lo >= 0x20 and lo < 0x7F) {
            Static.distro_buf[out_idx] = lo;
            out_idx += 1;
        }

        i += 2;
    }

    if (out_idx > 0) {
        Static.distro_len = out_idx;
        std.debug.print("Detected WSL distro: {s}\n", .{Static.distro_buf[0..out_idx]});
        return Static.distro_buf[0..out_idx];
    }

    return null;
}

// Global pointers for callbacks
pub threadlocal var g_window: ?*win32_backend.Window = null;
pub threadlocal var g_allocator: ?std.mem.Allocator = null;

// Selection is defined in Surface.zig
const Selection = Surface.Selection;

threadlocal var g_should_close: bool = false; // Set by Ctrl+W with 1 tab
pub threadlocal var g_selecting: bool = false; // True while mouse button is held
threadlocal var g_click_x: f64 = 0; // X position of initial click (for threshold calculation)
threadlocal var g_click_y: f64 = 0; // Y position of initial click

// ============================================================================
// Scrollbar — macOS-style overlay scrollbar with fade
// ============================================================================

const SCROLLBAR_WIDTH: f32 = 12; // Width of the scrollbar track
const SCROLLBAR_MARGIN: f32 = 2; // Margin from right edge
const SCROLLBAR_MIN_THUMB: f32 = 20; // Minimum thumb height in pixels
const SCROLLBAR_FADE_DELAY_MS: i64 = 800; // ms to wait before fading
const SCROLLBAR_FADE_DURATION_MS: i64 = 400; // ms for fade-out animation
const SCROLLBAR_HOVER_WIDTH: f32 = 12; // Wider hit area for hover/drag

// Per-surface scrollbar opacity/timing lives in Surface.zig.
// These are global interaction state (only one mouse):
threadlocal var g_scrollbar_hover: bool = false; // Mouse is over scrollbar area
threadlocal var g_scrollbar_dragging: bool = false; // Currently dragging the thumb
threadlocal var g_scrollbar_drag_offset: f32 = 0; // Offset within thumb where drag started

// ============================================================================
// Split divider dragging — resize splits by dragging the divider
// ============================================================================

const SPLIT_DIVIDER_HIT_WIDTH: f32 = 8; // Larger hit area for easier grabbing

threadlocal var g_divider_hover: bool = false; // Mouse is over a divider
threadlocal var g_divider_dragging: bool = false; // Currently dragging a divider
threadlocal var g_divider_drag_handle: ?SplitTree.Node.Handle = null; // Handle of the split node being resized
threadlocal var g_divider_drag_layout: ?SplitTree.Split.Layout = null; // horizontal or vertical

// Split resize overlay (for equalize/keyboard resize - shows overlay on all splits temporarily)
threadlocal var g_split_resize_overlay_until: i64 = 0; // Timestamp when overlay should hide

// ============================================================================
// Resize overlay — shows terminal size during resize (like Ghostty)
// ============================================================================

const RESIZE_OVERLAY_DURATION_MS: i64 = 750; // How long to show after resize stops
const RESIZE_OVERLAY_FADE_MS: i64 = 150; // Fade out duration
const RESIZE_OVERLAY_FIRST_DELAY_MS: i64 = 500; // Delay before first overlay shows

// Global resize overlay state
threadlocal var g_resize_overlay_visible: bool = false; // Whether overlay should be showing
threadlocal var g_resize_overlay_last_change: i64 = 0; // When size last changed
threadlocal var g_resize_overlay_cols: u16 = 0; // Current cols being displayed
threadlocal var g_resize_overlay_rows: u16 = 0; // Current rows being displayed
threadlocal var g_resize_overlay_last_cols: u16 = 0; // Last "settled" cols (after timeout)
threadlocal var g_resize_overlay_last_rows: u16 = 0; // Last "settled" rows (after timeout)
threadlocal var g_resize_overlay_ready: bool = false; // Set after initial delay
threadlocal var g_resize_overlay_init_time: i64 = 0; // When window was created
threadlocal var g_resize_overlay_opacity: f32 = 0; // For fade out animation

// Resize active state (for cursor hiding) - separate from overlay visibility
const RESIZE_ACTIVE_TIMEOUT_MS: i64 = 50; // Consider resize "done" after this many ms of no changes
pub threadlocal var g_resize_active: bool = false; // True while actively resizing

// Suppress resize overlay briefly after tab switch/creation to avoid false triggers
threadlocal var g_resize_overlay_suppress_until: i64 = 0;


// Tab model — see appwindow/tab.zig
const TabState = tab.TabState;

// ============================================================================
// Split layout — computed pixel rects for each surface in a split tree
// ============================================================================

/// Pixel rectangle for a split surface, including computed terminal dimensions
pub const SplitRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    cols: u16,
    rows: u16,
    surface: *Surface,
    handle: SplitTree.Node.Handle,
};

const MAX_SPLITS_PER_TAB = tab.MAX_SPLITS_PER_TAB;
const SPLIT_DIVIDER_WIDTH = tab.SPLIT_DIVIDER_WIDTH;
const DEFAULT_PADDING = tab.DEFAULT_PADDING;

/// Computed split rects for the active tab (updated each frame)
threadlocal var g_split_rects: [MAX_SPLITS_PER_TAB]SplitRect = undefined;
threadlocal var g_split_rect_count: usize = 0;

/// Find the surface under a given point (window coordinates).
/// Returns null if no surface is found at that position.
fn surfaceAtPoint(x: i32, y: i32) ?*Surface {
    for (0..g_split_rect_count) |i| {
        const rect = g_split_rects[i];
        if (x >= rect.x and x < rect.x + rect.width and
            y >= rect.y and y < rect.y + rect.height)
        {
            return rect.surface;
        }
    }
    return null;
}

/// Hit test result for split dividers
const DividerHit = struct {
    handle: SplitTree.Node.Handle,
    layout: SplitTree.Split.Layout,
};

/// Check if a point is over a split divider.
/// Returns the split node handle and layout if found, null otherwise.
fn hitTestDivider(x: i32, y: i32) ?DividerHit {
    const active_tab = activeTab() orelse return null;
    if (active_tab.tree.isEmpty() or !active_tab.tree.isSplit()) return null;

    const allocator = g_allocator orelse return null;
    var spatial = active_tab.tree.spatial(allocator) catch return null;
    defer spatial.deinit(allocator);

    // Get content area dimensions
    const win = g_window orelse return null;
    const fb = win.getFramebufferSize();
    const content_x: f32 = @floatFromInt(DEFAULT_PADDING);
    const content_y: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
    const content_w: f32 = @floatFromInt(@as(i32, @intCast(fb.width)) - @as(i32, @intCast(2 * DEFAULT_PADDING)));
    const content_h: f32 = @floatFromInt(@as(i32, @intCast(fb.height)) - win32_backend.TITLEBAR_HEIGHT - @as(i32, @intCast(DEFAULT_PADDING)));

    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);
    const half_hit = SPLIT_DIVIDER_HIT_WIDTH / 2;

    // Check each split node for divider hit
    for (active_tab.tree.nodes, 0..) |node, i| {
        switch (node) {
            .split => |s| {
                const handle: SplitTree.Node.Handle = @enumFromInt(i);
                const slot = spatial.slots[i];

                // Convert normalized coords to pixels
                const slot_x = content_x + @as(f32, @floatCast(slot.x)) * content_w;
                const slot_y = content_y + @as(f32, @floatCast(slot.y)) * content_h;
                const slot_w = @as(f32, @floatCast(slot.width)) * content_w;
                const slot_h = @as(f32, @floatCast(slot.height)) * content_h;

                switch (s.layout) {
                    .horizontal => {
                        // Vertical divider line at ratio position
                        const div_x = slot_x + slot_w * @as(f32, @floatCast(s.ratio));
                        if (xf >= div_x - half_hit and xf <= div_x + half_hit and
                            yf >= slot_y and yf <= slot_y + slot_h)
                        {
                            return .{ .handle = handle, .layout = .horizontal };
                        }
                    },
                    .vertical => {
                        // Horizontal divider line at ratio position
                        const div_y = slot_y + slot_h * @as(f32, @floatCast(s.ratio));
                        if (yf >= div_y - half_hit and yf <= div_y + half_hit and
                            xf >= slot_x and xf <= slot_x + slot_w)
                        {
                            return .{ .handle = handle, .layout = .vertical };
                        }
                    },
                }
            },
            .leaf => {},
        }
    }

    return null;
}

/// Compute split layout for a tab, returning pixel rects for each surface.
/// Each surface is resized to fit its allocated area with proper padding.
/// Returns the number of surfaces (0 if tree is empty).
fn computeSplitLayout(
    active_tab: *const TabState,
    content_x: i32,
    content_y: i32,
    content_w: i32,
    content_h: i32,
    cw: f32, // font.cell_width
    ch: f32, // font.cell_height
) usize {
    if (active_tab.tree.isEmpty()) return 0;

    // Get spatial representation (normalized 0-1 coordinates)
    const allocator = g_allocator orelse return 0;
    var spatial = active_tab.tree.spatial(allocator) catch return 0;
    defer spatial.deinit(allocator);

    var count: usize = 0;
    var it = active_tab.tree.iterator();
    while (it.next()) |entry| {
        if (count >= MAX_SPLITS_PER_TAB) break;

        const slot = spatial.slots[entry.handle.idx()];

        // Convert normalized coords to pixels
        const x_f: f32 = @as(f32, @floatCast(slot.x)) * @as(f32, @floatFromInt(content_w));
        const y_f: f32 = @as(f32, @floatCast(slot.y)) * @as(f32, @floatFromInt(content_h));
        const w_f: f32 = @as(f32, @floatCast(slot.width)) * @as(f32, @floatFromInt(content_w));
        const h_f: f32 = @as(f32, @floatCast(slot.height)) * @as(f32, @floatFromInt(content_h));

        // Apply divider insets (half-divider on each side adjacent to other splits)
        var px: i32 = content_x + @as(i32, @intFromFloat(x_f));
        var py: i32 = content_y + @as(i32, @intFromFloat(y_f));
        var pw: i32 = @as(i32, @intFromFloat(w_f));
        var ph: i32 = @as(i32, @intFromFloat(h_f));

        // Inset for dividers (only if not at edge)
        const half_div = @divTrunc(SPLIT_DIVIDER_WIDTH, 2);
        const at_left_edge = slot.x < 0.001;
        const at_right_edge = slot.x + slot.width >= 0.999;
        if (slot.x > 0.001) {
            px += half_div;
            pw -= half_div;
        }
        if (slot.x + slot.width < 0.999) {
            pw -= half_div;
        }
        if (slot.y > 0.001) {
            py += half_div;
            ph -= half_div;
        }
        if (slot.y + slot.height < 0.999) {
            ph -= half_div;
        }

        // Extend splits at left edge to window edge (consistent left margin)
        if (at_left_edge) {
            px -= @intCast(DEFAULT_PADDING);
            pw += @intCast(DEFAULT_PADDING);
        }

        // Extend splits at right edge to window edge (so scrollbar hugs window edge)
        if (at_right_edge) {
            pw += @intCast(DEFAULT_PADDING);
        }

        // Set the surface screen size with padding.
        // The surface computes grid size and balanced padding internally.
        // Right padding must account for scrollbar width plus gap.
        const surface = entry.surface;
        const scrollbar_padding: u32 = @intFromFloat(SCROLLBAR_WIDTH + DEFAULT_PADDING);
        const explicit_padding = renderer.size.Padding{
            .top = DEFAULT_PADDING,
            .bottom = DEFAULT_PADDING,
            .left = DEFAULT_PADDING,
            .right = scrollbar_padding,
        };

        const resized = surface.setScreenSize(
            allocator,
            if (pw > 0) @intCast(pw) else 1,
            if (ph > 0) @intCast(ph) else 1,
            cw,
            ch,
            explicit_padding,
        );

        if (resized) {
            g_force_rebuild = true;
            // Show resize overlay with new dimensions (but not during divider drag,
            // which has its own per-surface overlay logic)
            if (!g_divider_dragging) {
                resizeOverlayShow(surface.size.grid.cols, surface.size.grid.rows);
            }
        }

        // Track per-surface size changes for divider drag overlay
        if (g_divider_dragging) {
            const cols = surface.size.grid.cols;
            const rows = surface.size.grid.rows;
            if (cols != surface.resize_overlay_last_cols or rows != surface.resize_overlay_last_rows) {
                surface.resize_overlay_active = true;
                surface.resize_overlay_last_cols = cols;
                surface.resize_overlay_last_rows = rows;
            }
        }

        g_split_rects[count] = .{
            .x = px,
            .y = py,
            .width = pw,
            .height = ph,
            .cols = surface.size.grid.cols,
            .rows = surface.size.grid.rows,
            .surface = surface,
            .handle = entry.handle,
        };
        count += 1;
    }

    g_split_rect_count = count;
    return count;
}

const MAX_TABS = tab.MAX_TABS;

// ============================================================================
// Tab/split operation wrappers — delegate to tab module, handle UI side effects
// ============================================================================

fn activeTab() ?*TabState {
    return tab.activeTab();
}

fn activeSurface() ?*Surface {
    return tab.activeSurface();
}

fn activeSelection() *Selection {
    return tab.activeSelection();
}

fn isActiveTabTerminal() bool {
    return tab.isActiveTabTerminal();
}

/// Clear UI state after tab creation or switch.
fn clearUiStateOnTabChange() void {
    g_selecting = false;
    g_divider_dragging = false;
    g_divider_drag_handle = null;
    g_divider_drag_layout = null;
    g_resize_overlay_visible = false;
    g_resize_overlay_opacity = 0;
    g_resize_overlay_suppress_until = std.time.milliTimestamp() + 100;
    g_force_rebuild = true;
    g_cells_valid = false;
}

/// Convert the active surface's CWD from Unix to Windows path.
fn getActiveCwd(cwd_buf: *[260]u16) ?[*:0]const u16 {
    if (tab.activeSurface()) |surface| {
        if (surface.getCwd()) |unix_path| {
            if (unixPathToWindows(unix_path, cwd_buf)) |len| {
                cwd_buf[len] = 0;
                return @ptrCast(cwd_buf);
            }
        }
    }
    return null;
}

fn spawnTabWithCwd(allocator: std.mem.Allocator, cwd: ?[*:0]const u16) bool {
    if (!tab.spawnTabWithCwd(allocator, term_cols, term_rows, g_cursor_style, g_cursor_blink, cwd)) return false;
    clearUiStateOnTabChange();
    return true;
}

fn spawnTab(allocator: std.mem.Allocator) bool {
    var cwd_buf: [260]u16 = undefined;
    const cwd = getActiveCwd(&cwd_buf);
    return spawnTabWithCwd(allocator, cwd);
}

fn closeTab(idx: usize) void {
    const allocator = g_allocator orelse return;
    tab.closeTab(idx, allocator);
    g_selecting = false;
    g_force_rebuild = true;
    g_cells_valid = false;
}

fn switchTab(idx: usize) void {
    tab.switchTab(idx);
    clearUiStateOnTabChange();
}

fn splitFocused(direction: SplitTree.Split.Direction) void {
    const allocator = g_allocator orelse return;
    var cwd_buf: [260]u16 = undefined;
    var cwd: ?[*:0]const u16 = null;
    if (tab.activeSurface()) |surface| {
        if (surface.getCwd()) |unix_path| {
            if (unixPathToWindows(unix_path, &cwd_buf)) |len| {
                cwd_buf[len] = 0;
                cwd = @ptrCast(&cwd_buf);
            }
        }
    }
    if (tab.splitFocused(allocator, direction, font.cell_width, font.cell_height, g_cursor_style, g_cursor_blink, cwd)) {
        g_resize_active = false;
        g_force_rebuild = true;
        g_cells_valid = false;
    }
}

fn closeFocusedSplit() void {
    const allocator = g_allocator orelse return;
    switch (tab.closeFocusedSplit(allocator)) {
        .closed_split => {
            g_force_rebuild = true;
            g_cells_valid = false;
        },
        .closed_tab => {
            g_selecting = false;
            g_force_rebuild = true;
            g_cells_valid = false;
        },
        .close_window => {
            g_should_close = true;
        },
        .no_op => {},
    }
}

fn gotoSplit(direction: SplitTree.Goto) void {
    const allocator = g_allocator orelse return;
    if (tab.gotoSplit(allocator, direction)) {
        g_force_rebuild = true;
        g_cells_valid = false;
    }
}

fn equalizeSplits() void {
    const allocator = g_allocator orelse return;
    if (tab.equalizeSplits(allocator)) {
        g_split_resize_overlay_until = std.time.milliTimestamp() + RESIZE_OVERLAY_DURATION_MS;
        g_force_rebuild = true;
        g_cells_valid = false;
    }
}

fn updateFocusFromMouse(mouse_x: i32, mouse_y: i32) void {
    const t = tab.activeTab() orelse return;
    for (0..g_split_rect_count) |i| {
        const rect = g_split_rects[i];
        if (mouse_x >= rect.x and mouse_x < rect.x + rect.width and
            mouse_y >= rect.y and mouse_y < rect.y + rect.height)
        {
            if (rect.handle != t.focused) {
                t.focused = rect.handle;
                g_force_rebuild = true;
                g_cells_valid = false;
            }
            return;
        }
    }
}

// Embed the font
// Embedded fallback font (JetBrains Mono, like Ghostty)
const embedded = @import("font/embedded.zig");

// Terminal dimensions (initial, will be updated on resize)
// Defaults match Ghostty's default of 0 (auto-size), but we set
// reasonable defaults since we don't auto-detect screen size.
threadlocal var term_cols: u16 = 80;
threadlocal var term_rows: u16 = 24;
// OpenGL context from glad
pub threadlocal var gl: c.GladGLContext = undefined;

// Convenience aliases for font types used throughout this file
const Character = font.Character;
const FontAtlas = font.FontAtlas;
const GlyphUV = font.GlyphUV;

pub threadlocal var vao: c.GLuint = 0;
pub threadlocal var vbo: c.GLuint = 0;
pub threadlocal var shader_program: c.GLuint = 0;

// ============================================================================
// Instanced rendering — BG + FG cell buffers
// ============================================================================

/// Per-instance data for background cells (one per grid cell with non-default bg).
const CellBg = extern struct {
    grid_col: f32,
    grid_row: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// Per-instance data for foreground cells (one per visible glyph).
const CellFg = extern struct {
    grid_col: f32,
    grid_row: f32,
    glyph_x: f32, // offset from cell left to glyph left
    glyph_y: f32, // offset from cell bottom to glyph bottom
    glyph_w: f32, // glyph width in pixels
    glyph_h: f32, // glyph height in pixels
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
    r: f32,
    g: f32,
    b: f32,
};

// Max cells = 300 cols x 100 rows = 30000 (generous)
const MAX_CELLS = 30000;
threadlocal var bg_cells: [MAX_CELLS]CellBg = undefined;
threadlocal var fg_cells: [MAX_CELLS]CellFg = undefined;
threadlocal var color_fg_cells: [MAX_CELLS]CellFg = undefined; // Color emoji cells (separate draw pass)
threadlocal var bg_cell_count: usize = 0;
threadlocal var fg_cell_count: usize = 0;
threadlocal var color_fg_cell_count: usize = 0;

// Snapshot buffer: resolved cell data copied under the lock so that
// rebuildCells can run outside the lock (like Ghostty's RenderState).
const SnapCell = struct {
    codepoint: u21,
    fg: [3]f32,
    bg: ?[3]f32,
    wide: enum(u2) { narrow = 0, wide = 1, spacer_tail = 2, spacer_head = 3 } = .narrow,
    grapheme: [font.MAX_GRAPHEME]u21 = .{0} ** font.MAX_GRAPHEME,
    grapheme_len: u4 = 0, // 0 = single codepoint, >0 = multi-codepoint cluster
};
const MAX_SNAP = MAX_CELLS;
threadlocal var g_snap: [MAX_SNAP]SnapCell = undefined;
threadlocal var g_snap_rows: usize = 0;
threadlocal var g_snap_cols: usize = 0;

// Dirty tracking — skip rebuildCells when nothing changed
threadlocal var g_cells_valid: bool = false; // true if bg_cells/fg_cells have valid data from a previous rebuild
threadlocal var g_force_rebuild: bool = true; // set on resize, scroll, selection, theme change
threadlocal var g_last_cursor_blink_visible: bool = true; // track cursor blink transitions

// Cached cursor state for lock-free rendering (used when tryLock fails)
threadlocal var g_cached_cursor_x: usize = 0;
threadlocal var g_cached_cursor_y: usize = 0;
threadlocal var g_cached_cursor_style: CursorStyle = .block;
threadlocal var g_cached_cursor_effective: ?CursorStyle = .block;
threadlocal var g_cached_cursor_visible: bool = true;
threadlocal var g_cached_cursor_in_viewport: bool = true; // cursor is within visible viewport
threadlocal var g_cached_viewport_at_bottom: bool = true;

threadlocal var g_last_viewport_active: bool = true; // track viewport position changes (scroll)
// Viewport pin tracking — detects scroll position changes (like Ghostty's RenderState.viewport_pin)
threadlocal var g_last_viewport_node: ?*anyopaque = null;
threadlocal var g_last_viewport_y: usize = 0;
// Cursor pin tracking — detects cursor position changes
threadlocal var g_last_cursor_node: ?*anyopaque = null;
threadlocal var g_last_cursor_pin_y: usize = 0;
threadlocal var g_last_cursor_x: usize = 0;
threadlocal var g_last_cols: usize = 0; // detect resize
threadlocal var g_last_rows: usize = 0; // detect resize
threadlocal var g_last_selection_active: bool = false; // detect selection changes

// GL objects for instanced rendering
pub threadlocal var bg_shader: c.GLuint = 0;
pub threadlocal var fg_shader: c.GLuint = 0;
pub threadlocal var color_fg_shader: c.GLuint = 0; // Color emoji shader (BGRA sampling)
pub threadlocal var bg_vao: c.GLuint = 0;
pub threadlocal var fg_vao: c.GLuint = 0;
pub threadlocal var color_fg_vao: c.GLuint = 0;
pub threadlocal var bg_instance_vbo: c.GLuint = 0;
pub threadlocal var fg_instance_vbo: c.GLuint = 0;
pub threadlocal var color_fg_instance_vbo: c.GLuint = 0;
threadlocal var quad_vbo: c.GLuint = 0; // shared unit quad for instanced draws

// --- Instanced shader sources ---

const bg_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\// Unit quad (0,0)-(1,1)
    \\layout (location = 0) in vec2 aQuad;
    \\// Per-instance
    \\layout (location = 1) in vec2 aGridPos;
    \\layout (location = 2) in vec3 aColor;
    \\uniform mat4 projection;
    \\uniform vec2 cellSize;
    \\uniform vec2 gridOffset;
    \\uniform float windowHeight;
    \\flat out vec3 vColor;
    \\void main() {
    \\    // Cell top-left in screen coords
    \\    float cx = gridOffset.x + aGridPos.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (aGridPos.y + 1.0) * cellSize.y;
    \\    vec2 pos = vec2(cx, cy) + aQuad * cellSize;
    \\    gl_Position = projection * vec4(pos, 0.0, 1.0);
    \\    vColor = aColor;
    \\}
;

const bg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\flat in vec3 vColor;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragColor = vec4(vColor, 1.0);
    \\}
;

const fg_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 aQuad;
    \\// Per-instance
    \\layout (location = 1) in vec2 aGridPos;
    \\layout (location = 2) in vec4 aGlyphRect;  // x, y, w, h in pixels
    \\layout (location = 3) in vec4 aUV;          // left, top, right, bottom
    \\layout (location = 4) in vec3 aColor;
    \\uniform mat4 projection;
    \\uniform vec2 cellSize;
    \\uniform vec2 gridOffset;
    \\uniform float windowHeight;
    \\out vec2 vTexCoord;
    \\flat out vec3 vColor;
    \\void main() {
    \\    float cx = gridOffset.x + aGridPos.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (aGridPos.y + 1.0) * cellSize.y;
    \\    // Glyph quad within cell
    \\    vec2 pos = vec2(cx + aGlyphRect.x, cy + aGlyphRect.y) + aQuad * aGlyphRect.zw;
    \\    gl_Position = projection * vec4(pos, 0.0, 1.0);
    \\    // UV interpolation — V is flipped because atlas Y=0 is top but GL quad Y=0 is bottom
    \\    vTexCoord = vec2(mix(aUV.x, aUV.z, aQuad.x), mix(aUV.w, aUV.y, aQuad.y));
    \\    vColor = aColor;
    \\}
;

const fg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 vTexCoord;
    \\flat in vec3 vColor;
    \\uniform sampler2D atlas;
    \\out vec4 fragColor;
    \\void main() {
    \\    float a = texture(atlas, vTexCoord).r;
    \\    fragColor = vec4(vColor, 1.0) * vec4(1.0, 1.0, 1.0, a);
    \\}
;

// Color emoji fragment shader — samples RGBA directly from the color atlas.
// FreeType's color emoji bitmaps (CBDT/CBLC) use premultiplied alpha,
// so we output them directly and use premultiplied blend mode (GL_ONE, GL_ONE_MINUS_SRC_ALPHA).
const color_fg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 vTexCoord;
    \\flat in vec3 vColor;
    \\uniform sampler2D atlas;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragColor = texture(atlas, vTexCoord);
    \\}
;

// Simple (non-instanced) color emoji fragment shader for titlebar/overlay use.
// Uses the same vertex layout as the text shader (vec4: xy=pos, zw=texcoord).
const simple_color_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 TexCoords;
    \\out vec4 color;
    \\uniform sampler2D text;
    \\uniform float opacity;
    \\void main() {
    \\    vec4 texColor = texture(text, TexCoords);
    \\    color = texColor * opacity;
    \\}
;
pub threadlocal var simple_color_shader: c.GLuint = 0;

// Solid color overlay shader - outputs a solid color with alpha for true blending.
const overlay_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\out vec4 color;
    \\uniform vec4 overlayColor;
    \\void main() {
    \\    color = overlayColor;
    \\}
;
threadlocal var overlay_shader: c.GLuint = 0;
pub threadlocal var window_focused: bool = true; // Track window focus state

// Fullscreen state (Alt+Enter to toggle)
threadlocal var g_is_fullscreen: bool = false;
threadlocal var g_windowed_x: c_int = 0; // Saved windowed position/size for restore
threadlocal var g_windowed_y: c_int = 0;
threadlocal var g_windowed_width: c_int = 800;
threadlocal var g_windowed_height: c_int = 600;

// ============================================================================
// Window state persistence — save/restore position across sessions
// ============================================================================

const WindowState = struct {
    x: i32,
    y: i32,
};

/// Return the state file path: %APPDATA%\phantty\state
fn stateFilePath(allocator: std.mem.Allocator) ?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "APPDATA")) |appdata| {
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, "phantty", "state" }) catch null;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "phantty", "state" }) catch null;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".config", "phantty", "state" }) catch null;
    } else |_| {}
    return null;
}

/// Load window state from the state file.
fn loadWindowState(allocator: std.mem.Allocator) ?WindowState {
    const path = stateFilePath(allocator) orelse return null;
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch return null;
    defer allocator.free(data);

    var state = WindowState{ .x = 0, .y = 0 };
    var has_x = false;
    var has_y = false;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            const key = std.mem.trim(u8, trimmed[0..eq], &[_]u8{ ' ', '\t' });
            const val = std.mem.trim(u8, trimmed[eq + 1 ..], &[_]u8{ ' ', '\t' });
            if (std.mem.eql(u8, key, "window-x")) {
                state.x = std.fmt.parseInt(i32, val, 10) catch continue;
                has_x = true;
            } else if (std.mem.eql(u8, key, "window-y")) {
                state.y = std.fmt.parseInt(i32, val, 10) catch continue;
                has_y = true;
            }
        }
    }

    if (!has_x or !has_y) return null;

    // Validate that the position is on a visible monitor
    // Use MonitorFromPoint with MONITOR_DEFAULTTONULL - returns null if point is off-screen
    const pt = win32_backend.POINT{ .x = state.x + 50, .y = state.y + 50 }; // Check a point inside the window
    const monitor = monitorFromPoint(pt, 0); // MONITOR_DEFAULTTONULL = 0
    if (monitor == null) {
        std.debug.print("Saved window position ({}, {}) is off-screen, ignoring\n", .{ state.x, state.y });
        return null;
    }

    return state;
}

extern "user32" fn MonitorFromPoint(pt: win32_backend.POINT, dwFlags: u32) callconv(.winapi) ?win32_backend.HMONITOR;

fn monitorFromPoint(pt: win32_backend.POINT, flags: u32) ?win32_backend.HMONITOR {
    return MonitorFromPoint(pt, flags);
}

/// Save window state to the state file.
fn saveWindowState(allocator: std.mem.Allocator, state: WindowState) void {
    const path = stateFilePath(allocator) orelse return;
    defer allocator.free(path);

    var buf: [128]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "window-x = {d}\nwindow-y = {d}\n", .{
        state.x, state.y,
    }) catch return;

    if (std.fs.cwd().createFile(path, .{})) |file| {
        defer file.close();
        file.writeAll(content) catch {};
    } else |_| {}
}

// Post-processing custom shader (Ghostty-compatible)
threadlocal var g_post_fbo: c.GLuint = 0; // Framebuffer object for off-screen render
threadlocal var g_post_texture: c.GLuint = 0; // Color attachment texture
threadlocal var g_post_program: c.GLuint = 0; // Post-processing shader program
threadlocal var g_post_vao: c.GLuint = 0; // Fullscreen quad VAO
threadlocal var g_post_vbo: c.GLuint = 0; // Fullscreen quad VBO
threadlocal var g_post_enabled: bool = false; // Whether custom shader is active
threadlocal var g_post_fb_width: c_int = 0; // Current FBO texture dimensions
threadlocal var g_post_fb_height: c_int = 0;
threadlocal var g_frame_count: u32 = 0; // Frame counter for iFrame
threadlocal var g_start_time: i64 = 0; // Start time for iTime

// Pending resize state (resize is deferred to main loop to avoid PageList integrity issues)
// Ghostty coalesces resize events with a 25ms timer to batch rapid resizes
threadlocal var g_pending_resize: bool = false;
threadlocal var g_pending_cols: u16 = 0;
threadlocal var g_pending_rows: u16 = 0;
threadlocal var g_last_resize_time: i64 = 0;
threadlocal var g_resize_in_progress: bool = false; // Prevent rendering during resize
const RESIZE_COALESCE_MS: i64 = 25; // Same as Ghostty

threadlocal var g_cursor_style: CursorStyle = .block; // Default cursor style
pub threadlocal var g_cursor_blink: bool = true; // Whether cursor should blink (default: true like Ghostty)
pub threadlocal var g_cursor_blink_visible: bool = true; // Current blink state (toggled by timer)
threadlocal var g_last_blink_time: i64 = 0; // Timestamp of last blink toggle
const CURSOR_BLINK_INTERVAL_MS: i64 = 600; // Blink interval in ms (same as Ghostty)

const ConfigWatcher = @import("config_watcher.zig");

// FPS debug overlay state
threadlocal var g_debug_fps: bool = false; // Whether to show FPS overlay
threadlocal var g_debug_draw_calls: bool = false; // Whether to show draw call count overlay
pub threadlocal var g_draw_call_count: u32 = 0; // Reset each frame, incremented on each glDraw* call
threadlocal var g_fps_frame_count: u32 = 0; // Frames since last FPS update
threadlocal var g_fps_last_time: i64 = 0; // Timestamp of last FPS calculation
threadlocal var g_fps_value: f32 = 0; // Current FPS value to display

const vertex_shader_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec4 vertex;
    \\out vec2 TexCoords;
    \\uniform mat4 projection;
    \\void main() {
    \\    gl_Position = projection * vec4(vertex.xy, 0.0, 1.0);
    \\    TexCoords = vertex.zw;
    \\}
;

const fragment_shader_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 TexCoords;
    \\out vec4 color;
    \\uniform sampler2D text;
    \\uniform vec3 textColor;
    \\void main() {
    \\    vec4 sampled = vec4(1.0, 1.0, 1.0, texture(text, TexCoords).r);
    \\    color = vec4(textColor, 1.0) * sampled;
    \\}
;

fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    const shader = gl.CreateShader.?(shader_type);
    if (shader == 0) {
        const gl_err = if (gl.GetError) |getErr| getErr() else 0;
        std.debug.print("Shader error: glCreateShader returned 0, type=0x{X}, glError=0x{X}\n", .{ shader_type, gl_err });
        return null;
    }

    gl.ShaderSource.?(shader, 1, &source, null);
    gl.CompileShader.?(shader);

    var success: c.GLint = 0;
    gl.GetShaderiv.?(shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetShaderInfoLog.?(shader, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) {
            std.debug.print("Shader compilation failed: {s}\n", .{info_log[0..len]});
        } else {
            std.debug.print("Shader compilation failed (no error log, shader={})\n", .{shader});
        }
        return null;
    }
    return shader;
}

fn initShaders() bool {
    const vertex_shader = compileShader(c.GL_VERTEX_SHADER, vertex_shader_source) orelse return false;
    defer gl.DeleteShader.?(vertex_shader);

    const fragment_shader = compileShader(c.GL_FRAGMENT_SHADER, fragment_shader_source) orelse return false;
    defer gl.DeleteShader.?(fragment_shader);

    shader_program = gl.CreateProgram.?();
    gl.AttachShader.?(shader_program, vertex_shader);
    gl.AttachShader.?(shader_program, fragment_shader);
    gl.LinkProgram.?(shader_program);

    var success: c.GLint = 0;
    gl.GetProgramiv.?(shader_program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetProgramInfoLog.?(shader_program, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) {
            std.debug.print("Shader linking failed: {s}\n", .{info_log[0..len]});
        } else {
            std.debug.print("Shader linking failed (no error log available)\n", .{});
        }
        return false;
    }

    return true;
}

fn initBuffers() void {
    gl.GenVertexArrays.?(1, &vao);
    gl.GenBuffers.?(1, &vbo);
    gl.BindVertexArray.?(vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(f32) * 6 * 4, null, c.GL_DYNAMIC_DRAW);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 4, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.BindVertexArray.?(0);
}

fn linkProgram(vs_src: [*c]const u8, fs_src: [*c]const u8) c.GLuint {
    const vs = compileShader(c.GL_VERTEX_SHADER, vs_src) orelse return 0;
    defer gl.DeleteShader.?(vs);
    const fs = compileShader(c.GL_FRAGMENT_SHADER, fs_src) orelse return 0;
    defer gl.DeleteShader.?(fs);
    const prog = gl.CreateProgram.?();
    gl.AttachShader.?(prog, vs);
    gl.AttachShader.?(prog, fs);
    gl.LinkProgram.?(prog);
    var success: c.GLint = 0;
    gl.GetProgramiv.?(prog, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetProgramInfoLog.?(prog, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) std.debug.print("Shader link failed: {s}\n", .{info_log[0..len]});
        return 0;
    }
    return prog;
}

fn initInstancedBuffers() void {
    // Shared unit quad (triangle strip: 4 verts)
    const quad_verts = [4][2]f32{
        .{ 0.0, 0.0 }, // bottom-left
        .{ 1.0, 0.0 }, // bottom-right
        .{ 0.0, 1.0 }, // top-left
        .{ 1.0, 1.0 }, // top-right
    };
    gl.GenBuffers.?(1, &quad_vbo);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad_verts)), &quad_verts, c.GL_STATIC_DRAW);

    // --- BG VAO ---
    gl.GenVertexArrays.?(1, &bg_vao);
    gl.GenBuffers.?(1, &bg_instance_vbo);
    gl.BindVertexArray.?(bg_vao);

    // Attr 0: unit quad (per-vertex)
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);

    // Attrs 1-2: per-instance BG data
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, bg_instance_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(CellBg) * MAX_CELLS, null, c.GL_STREAM_DRAW);
    const bg_stride: c.GLsizei = @sizeOf(CellBg);
    // Attr 1: grid_col, grid_row
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    // Attr 2: r, g, b
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 3, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);

    gl.BindVertexArray.?(0);

    // --- FG VAO ---
    gl.GenVertexArrays.?(1, &fg_vao);
    gl.GenBuffers.?(1, &fg_instance_vbo);
    gl.BindVertexArray.?(fg_vao);

    // Attr 0: unit quad (per-vertex)
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);

    // Attrs 1-4: per-instance FG data
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, fg_instance_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(CellFg) * MAX_CELLS, null, c.GL_STREAM_DRAW);
    const fg_stride: c.GLsizei = @sizeOf(CellFg);
    // Attr 1: grid_col, grid_row
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    // Attr 2: glyph_x, glyph_y, glyph_w, glyph_h
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    // Attr 3: uv_left, uv_top, uv_right, uv_bottom
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(6 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    // Attr 4: r, g, b
    gl.EnableVertexAttribArray.?(4);
    gl.VertexAttribPointer.?(4, 3, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(10 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(4, 1);

    gl.BindVertexArray.?(0);

    // --- Color FG VAO (same layout as FG, separate buffer for color emoji) ---
    gl.GenVertexArrays.?(1, &color_fg_vao);
    gl.GenBuffers.?(1, &color_fg_instance_vbo);
    gl.BindVertexArray.?(color_fg_vao);

    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);

    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, color_fg_instance_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(CellFg) * MAX_CELLS, null, c.GL_STREAM_DRAW);
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(6 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    gl.EnableVertexAttribArray.?(4);
    gl.VertexAttribPointer.?(4, 3, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(10 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(4, 1);

    gl.BindVertexArray.?(0);

    // --- Compile instanced shaders ---
    bg_shader = linkProgram(bg_vertex_source, bg_fragment_source);
    fg_shader = linkProgram(fg_vertex_source, fg_fragment_source);
    color_fg_shader = linkProgram(fg_vertex_source, color_fg_fragment_source);
    if (bg_shader == 0) std.debug.print("BG instanced shader failed\n", .{});
    if (fg_shader == 0) std.debug.print("FG instanced shader failed\n", .{});
    if (color_fg_shader == 0) std.debug.print("Color FG instanced shader failed\n", .{});

    // Simple color shader for titlebar emoji (uses same vertex layout as text shader)
    simple_color_shader = linkProgram(vertex_shader_source, simple_color_fragment_source);
    if (simple_color_shader == 0) std.debug.print("Simple color shader failed\n", .{});

    // Overlay shader for unfocused split dimming (solid color with alpha)
    overlay_shader = linkProgram(vertex_shader_source, overlay_fragment_source);
    if (overlay_shader == 0) std.debug.print("Overlay shader failed\n", .{});
}

// Font functions moved to appwindow/font.zig

// Titlebar functions moved to appwindow/titlebar.zig
// (renderTitlebarChar, titlebarGlyphAdvance, renderBellEmoji, renderIconGlyph,
//  renderTitlebar, CaptionButtonType, renderCaptionButton, renderPlaceholderTab)

// renderChar moved to appwindow/cell_renderer.zig
// Cell rendering functions (snapshotCells, rebuildCells, updateTerminalCells,
// drawCells, cursorEffectiveStyleForRenderer, currentRenderSelection,
// updateTerminalCellsForSurface) moved to appwindow/cell_renderer.zig

// Solid white texture for drawing filled quads
threadlocal var solid_texture: c.GLuint = 0;

fn initSolidTexture() void {
    const white_pixel = [_]u8{ 255 };
    gl.GenTextures.?(1, &solid_texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, solid_texture);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RED, 1, 1, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &white_pixel);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
}

// ============================================================================
// Split rendering helpers
// ============================================================================

/// Render a semi-transparent overlay over an unfocused split pane.
fn renderUnfocusedOverlay(rect: SplitRect, window_height: f32) void {
    const opacity = 1.0 - g_unfocused_split_opacity;
    if (opacity < 0.01) return;

    gl.UseProgram.?(shader_program);
    gl.BindVertexArray.?(vao);

    // Draw semi-transparent background color overlay
    const px: f32 = @floatFromInt(rect.x);
    const py: f32 = window_height - @as(f32, @floatFromInt(rect.y + rect.height));
    const pw: f32 = @floatFromInt(rect.width);
    const ph: f32 = @floatFromInt(rect.height);

    // Use background color with alpha for the overlay
    renderQuadAlpha(px, py, pw, ph, g_theme.background, opacity);
}

/// Render unfocused overlay within current viewport (for split rendering).
/// Assumes viewport is already set to the split's region.
/// Uses true alpha blending so it blends with actual rendered content.
fn renderUnfocusedOverlaySimple(width: f32, height: f32) void {
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
    gl.UseProgram.?(overlay_shader);
    
    // Set overlay color (background color with alpha)
    gl.Uniform4f.?(
        gl.GetUniformLocation.?(overlay_shader, "overlayColor"),
        g_theme.background[0],
        g_theme.background[1],
        g_theme.background[2],
        alpha,
    );
    
    // Set projection for current viewport
    var viewport: [4]c.GLint = undefined;
    gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
    const vp_width: f32 = @floatFromInt(viewport[2]);
    const vp_height: f32 = @floatFromInt(viewport[3]);
    const projection = [16]f32{
        2.0 / vp_width, 0.0,            0.0,  0.0,
        0.0,            2.0 / vp_height, 0.0,  0.0,
        0.0,            0.0,            -1.0, 0.0,
        -1.0,           -1.0,           0.0,  1.0,
    };
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(overlay_shader, "projection"), 1, c.GL_FALSE, &projection);

    gl.BindVertexArray.?(vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    g_draw_call_count += 1;
}

/// Render split dividers between panes in the active tab.
/// If split-divider-color is configured, uses that color (solid).
/// Otherwise uses scrollbar-style rendering: black with alpha transparency.
fn renderSplitDividers(active_tab: *const TabState, content_x: i32, content_y: i32, content_w: i32, content_h: i32, window_height: f32) void {
    if (!active_tab.tree.isSplit()) return;

    const allocator = g_allocator orelse return;

    // Get spatial representation
    var spatial = active_tab.tree.spatial(allocator) catch return;
    defer spatial.deinit(allocator);

    gl.UseProgram.?(shader_program);
    gl.BindVertexArray.?(vao);

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
                            renderQuad(div_x, div_y, @floatFromInt(SPLIT_DIVIDER_WIDTH), slot_h, custom_color);
                        } else {
                            renderQuadAlpha(div_x, div_y, @floatFromInt(SPLIT_DIVIDER_WIDTH), slot_h, .{ 0, 0, 0 }, default_alpha);
                        }
                    },
                    .vertical => {
                        // Horizontal divider at ratio position
                        const div_x = slot_x;
                        const div_y = window_height - slot_y - slot_h * @as(f32, @floatCast(s.ratio)) - @as(f32, @floatFromInt(@divTrunc(SPLIT_DIVIDER_WIDTH, 2)));
                        if (use_custom_color) {
                            renderQuad(div_x, div_y, slot_w, @floatFromInt(SPLIT_DIVIDER_WIDTH), custom_color);
                        } else {
                            renderQuadAlpha(div_x, div_y, slot_w, @floatFromInt(SPLIT_DIVIDER_WIDTH), .{ 0, 0, 0 }, default_alpha);
                        }
                    },
                }
            },
        }
    }
}

/// Unfocused split opacity (default 0.7, configurable)
threadlocal var g_unfocused_split_opacity: f32 = 0.7;

/// Split divider color (null = use scrollbar style with alpha)
threadlocal var g_split_divider_color: ?[3]f32 = null;

/// Focus follows mouse - when true, moving mouse into a split pane focuses it
threadlocal var g_focus_follows_mouse: bool = false;

// ============================================================================
// Post-Processing Custom Shader System (Ghostty-compatible)
// ============================================================================
//
// Ghostty custom shaders use Shadertoy-style conventions:
//   - iResolution: vec3 (viewport resolution in pixels, z=1.0)
//   - iTime: float (elapsed time in seconds)
//   - iTimeDelta: float (time since last frame)
//   - iFrame: int (frame counter)
//   - iChannel0: sampler2D (the terminal framebuffer)
//   - iChannelResolution[0]: vec3 (texture resolution)
//
// The shader must define: void mainImage(out vec4 fragColor, in vec2 fragCoord)

/// Vertex shader for the fullscreen post-processing quad
const post_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\layout (location = 1) in vec2 aTexCoord;
    \\out vec2 vTexCoord;
    \\void main() {
    \\    gl_Position = vec4(aPos, 0.0, 1.0);
    \\    vTexCoord = aTexCoord;
    \\}
;

/// Build the post-processing fragment shader by wrapping a Ghostty/Shadertoy-style
/// mainImage shader with our uniform declarations and main() entry point.
fn buildPostFragmentSource(allocator: std.mem.Allocator, user_shader: []const u8) ![:0]const u8 {
    const preamble =
        \\#version 330 core
        \\out vec4 _fragColor;
        \\in vec2 vTexCoord;
        \\
        \\uniform vec3 iResolution;
        \\uniform float iTime;
        \\uniform float iTimeDelta;
        \\uniform int iFrame;
        \\uniform sampler2D iChannel0;
        \\uniform vec3 iChannelResolution[1];
        \\
        \\// Provide textureLod via extension or fallback
        \\
    ;
    const epilogue =
        \\
        \\void main() {
        \\    vec2 fragCoord = vTexCoord * iResolution.xy;
        \\    mainImage(_fragColor, fragCoord);
        \\}
    ;

    const total_len = preamble.len + user_shader.len + epilogue.len;
    const buf = try allocator.alloc(u8, total_len + 1); // +1 for sentinel
    @memcpy(buf[0..preamble.len], preamble);
    @memcpy(buf[preamble.len..][0..user_shader.len], user_shader);
    @memcpy(buf[preamble.len + user_shader.len ..][0..epilogue.len], epilogue);
    buf[total_len] = 0; // null-terminate

    return buf[0..total_len :0];
}

/// Load and compile a custom post-processing shader from a file
fn initPostShader(allocator: std.mem.Allocator, shader_path: []const u8) bool {
    // Read shader source file
    const file = std.fs.cwd().openFile(shader_path, .{}) catch |err| {
        std.debug.print("Failed to open shader file '{s}': {}\n", .{ shader_path, err });
        return false;
    };
    defer file.close();

    const user_source = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read shader file: {}\n", .{err});
        return false;
    };
    defer allocator.free(user_source);

    // Build complete fragment shader
    const frag_source = buildPostFragmentSource(allocator, user_source) catch |err| {
        std.debug.print("Failed to build shader source: {}\n", .{err});
        return false;
    };
    defer allocator.free(frag_source);

    // Compile vertex shader
    const vert = compileShader(c.GL_VERTEX_SHADER, post_vertex_source) orelse return false;
    defer gl.DeleteShader.?(vert);

    // Compile fragment shader
    const frag = compileShader(c.GL_FRAGMENT_SHADER, frag_source.ptr) orelse return false;
    defer gl.DeleteShader.?(frag);

    // Link program
    g_post_program = gl.CreateProgram.?();
    gl.AttachShader.?(g_post_program, vert);
    gl.AttachShader.?(g_post_program, frag);
    gl.LinkProgram.?(g_post_program);

    var success: c.GLint = 0;
    gl.GetProgramiv.?(g_post_program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        gl.GetProgramInfoLog.?(g_post_program, 512, null, &info_log);
        std.debug.print("Post shader linking failed: {s}\n", .{&info_log});
        return false;
    }

    // Set up fullscreen quad VAO/VBO
    // Two triangles covering [-1,1] NDC with tex coords [0,1]
    const quad_verts = [_]f32{
        // pos      // tex
        -1.0, -1.0, 0.0, 0.0,
        1.0,  -1.0, 1.0, 0.0,
        -1.0, 1.0,  0.0, 1.0,

        1.0,  -1.0, 1.0, 0.0,
        1.0,  1.0,  1.0, 1.0,
        -1.0, 1.0,  0.0, 1.0,
    };

    gl.GenVertexArrays.?(1, &g_post_vao);
    gl.GenBuffers.?(1, &g_post_vbo);
    gl.BindVertexArray.?(g_post_vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, g_post_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad_verts)), &quad_verts, c.GL_STATIC_DRAW);
    // position (location 0)
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    // texcoord (location 1)
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
    gl.BindVertexArray.?(0);

    std.debug.print("Custom shader loaded: {s}\n", .{shader_path});
    return true;
}

/// Create or resize the off-screen framebuffer for post-processing
fn ensurePostFBO(width: c_int, height: c_int) void {
    if (width == g_post_fb_width and height == g_post_fb_height and g_post_fbo != 0) return;

    // Delete old FBO/texture if resizing
    if (g_post_fbo != 0) {
        gl.DeleteFramebuffers.?(1, &g_post_fbo);
        gl.DeleteTextures.?(1, &g_post_texture);
    }

    // Create FBO
    gl.GenFramebuffers.?(1, &g_post_fbo);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, g_post_fbo);

    // Create color texture
    gl.GenTextures.?(1, &g_post_texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_post_texture);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

    // Attach to FBO
    gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, g_post_texture, 0);

    if (gl.CheckFramebufferStatus.?(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("Post-processing FBO is incomplete!\n", .{});
    }

    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    g_post_fb_width = width;
    g_post_fb_height = height;
}

/// Render the fullscreen quad with post-processing shader applied
fn renderPostProcess(width: c_int, height: c_int) void {
    // Bind default framebuffer (screen)
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    gl.Viewport.?(0, 0, width, height);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

    // Disable blending for the fullscreen quad - shader output is final color
    gl.Disable.?(c.GL_BLEND);

    gl.UseProgram.?(g_post_program);

    // Set uniforms (Ghostty/Shadertoy conventions)
    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);
    const now_ms = std.time.milliTimestamp();
    const elapsed: f32 = @floatCast(@as(f64, @floatFromInt(now_ms - g_start_time)) / 1000.0);

    // iResolution
    gl.Uniform3f.?(gl.GetUniformLocation.?(g_post_program, "iResolution"), w_f, h_f, 1.0);
    // iTime
    gl.Uniform1f.?(gl.GetUniformLocation.?(g_post_program, "iTime"), elapsed);
    // iTimeDelta (approximate ~16ms)
    gl.Uniform1f.?(gl.GetUniformLocation.?(g_post_program, "iTimeDelta"), 0.016);
    // iFrame
    gl.Uniform1i.?(gl.GetUniformLocation.?(g_post_program, "iFrame"), @intCast(g_frame_count));
    // iChannel0 = texture unit 0
    gl.Uniform1i.?(gl.GetUniformLocation.?(g_post_program, "iChannel0"), 0);
    // iChannelResolution[0]
    gl.Uniform3f.?(gl.GetUniformLocation.?(g_post_program, "iChannelResolution[0]"), w_f, h_f, 1.0);

    // Bind the terminal framebuffer texture
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_post_texture);

    // Draw fullscreen quad
    gl.BindVertexArray.?(g_post_vao);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); g_draw_call_count += 1;
    gl.BindVertexArray.?(0);

    // Re-enable blending for next terminal render pass
    gl.Enable.?(c.GL_BLEND);

    g_frame_count +%= 1;
}

/// Helper: render a frame to FBO, then apply post-processing to screen
/// Render with post-processing. Called after updateTerminalCells() has
/// already been called under the lock — this only does GL work.
fn renderFrameWithPostFromCells(rend: *const Renderer, width: c_int, height: c_int, padding: f32) void {
    ensurePostFBO(width, height);

    // 1. Render terminal to FBO
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, g_post_fbo);
    gl.Viewport.?(0, 0, width, height);
    setProjection(@floatFromInt(width), @floatFromInt(height));
    gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
    cell_renderer.drawCells(rend, @floatFromInt(height), padding, padding);

    // 2. Apply post-processing shader to screen
    renderPostProcess(width, height);
}

pub fn renderQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    renderQuadAlpha(x, y, w, h, color, 1.0);
}

pub fn renderQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
    const vertices = [6][4]f32{
        .{ x, y + h, 0.0, 0.0 },
        .{ x, y, 0.0, 1.0 },
        .{ x + w, y, 1.0, 1.0 },
        .{ x, y + h, 0.0, 0.0 },
        .{ x + w, y, 1.0, 1.0 },
        .{ x + w, y + h, 1.0, 0.0 },
    };

    // Pre-multiply alpha into color and use the solid texture (which has alpha=1).
    // With GL_SRC_ALPHA blending, we set textColor to full RGB and modulate alpha
    // via the vec4 output. Since our fragment shader does:
    //   color = vec4(textColor, 1.0) * sampled
    // and sampled = vec4(1,1,1, texture.r) with solid_texture.r = 1,
    // the output alpha is always 1. To get transparency we use a small trick:
    // temporarily blend manually by dimming the color toward the background.
    // This avoids needing a shader change.
    const r = color[0] * alpha + g_theme.background[0] * (1 - alpha);
    const g = color[1] * alpha + g_theme.background[1] * (1 - alpha);
    const b = color[2] * alpha + g_theme.background[2] * (1 - alpha);

    gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), r, g, b);
    gl.BindTexture.?(c.GL_TEXTURE_2D, solid_texture);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); g_draw_call_count += 1;
}

// Terminal cursor style defined in renderer/cursor.zig
const TerminalCursorStyle = renderer.cursor.TerminalCursorStyle;

// ============================================================================
// FBO Management for Per-Surface Rendering
// ============================================================================

/// Create or resize an FBO for a renderer.
/// Must be called from main thread with GL context current.
fn ensureRendererFBO(rend: *Renderer, width: u32, height: u32) void {
    if (!rend.needsFBOUpdate(width, height)) return;

    // Clean up existing FBO if resizing
    if (rend.isFBOReady()) {
        cleanupRendererFBO(rend);
    }

    // Create framebuffer
    var fbo: c.GLuint = 0;
    gl.GenFramebuffers.?(1, &fbo);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, fbo);

    // Create texture for color attachment
    var texture: c.GLuint = 0;
    gl.GenTextures.?(1, &texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, texture);
    gl.TexImage2D.?(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RGBA8,
        @intCast(width),
        @intCast(height),
        0,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        null,
    );
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

    // Attach texture to framebuffer
    gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, texture, 0);

    // Check framebuffer completeness
    const status = gl.CheckFramebufferStatus.?(c.GL_FRAMEBUFFER);
    if (status != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("FBO incomplete: 0x{X}\n", .{status});
    }

    // Unbind
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, 0);

    // Store handles in renderer
    rend.setFBOHandles(fbo, texture, width, height);
}

/// Clean up FBO resources for a renderer.
fn cleanupRendererFBO(rend: *Renderer) void {
    if (!rend.isFBOReady()) return;

    var texture = rend.getTexture();
    var fbo = rend.getFBO();

    if (texture != 0) {
        gl.DeleteTextures.?(1, &texture);
    }
    if (fbo != 0) {
        gl.DeleteFramebuffers.?(1, &fbo);
    }

    rend.clearFBOHandles();
}

/// Bind a renderer's FBO for drawing.
fn bindRendererFBO(rend: *Renderer) void {
    if (!rend.isFBOReady()) return;
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, rend.getFBO());
    const size = rend.getFBOSize();
    gl.Viewport.?(0, 0, @intCast(size.width), @intCast(size.height));
}

/// Unbind FBO (return to default framebuffer).
fn unbindFBO() void {
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
}

/// Draw a renderer's FBO texture as a quad at the given screen position.
/// This composites the surface onto the main framebuffer.
fn drawRendererFBOToScreen(rend: *Renderer, x: f32, y: f32, w: f32, h: f32, window_height: f32, window_width: f32) void {
    if (!rend.isFBOReady()) return;

    // Convert from top-left screen coords to OpenGL bottom-left coords
    const gl_y = window_height - y - h;

    // Vertices for textured quad (position + texcoord)
    const vertices = [6][4]f32{
        .{ x, gl_y + h, 0.0, 1.0 }, // top-left
        .{ x, gl_y, 0.0, 0.0 }, // bottom-left
        .{ x + w, gl_y, 1.0, 0.0 }, // bottom-right
        .{ x, gl_y + h, 0.0, 1.0 }, // top-left
        .{ x + w, gl_y, 1.0, 0.0 }, // bottom-right
        .{ x + w, gl_y + h, 1.0, 1.0 }, // top-right
    };

    // Set up projection matrix for screen space
    const projection = [16]f32{
        2.0 / window_width, 0.0,                 0.0,  0.0,
        0.0,                2.0 / window_height, 0.0,  0.0,
        0.0,                0.0,                 -1.0, 0.0,
        -1.0,               -1.0,                0.0,  1.0,
    };

    // Use the color texture shader (samples RGBA directly)
    gl.UseProgram.?(simple_color_shader);
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(simple_color_shader, "projection"), 1, c.GL_FALSE, &projection);
    gl.Uniform1f.?(gl.GetUniformLocation.?(simple_color_shader, "opacity"), 1.0);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, rend.getTexture());
    gl.Uniform1i.?(gl.GetUniformLocation.?(simple_color_shader, "text"), 0);
    gl.BindVertexArray.?(vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    g_draw_call_count += 1;
}

/// Update the FPS counter. Call once per frame.
fn updateFps() void {
    g_fps_frame_count += 1;
    const now = std.time.milliTimestamp();
    const elapsed = now - g_fps_last_time;
    if (elapsed >= 1000) {
        g_fps_value = @as(f32, @floatFromInt(g_fps_frame_count)) * 1000.0 / @as(f32, @floatFromInt(elapsed));
        g_fps_frame_count = 0;
        g_fps_last_time = now;
    }
}

// ============================================================================
// Scrollbar — macOS-style overlay with fade
// ============================================================================

/// Scrollbar geometry result.
const ScrollbarGeometry = struct {
    track_x: f32,
    track_y: f32, // bottom of track (GL coords, y=0 is bottom)
    track_h: f32,
    thumb_y: f32,
    thumb_h: f32,
};

/// Compute scrollbar geometry for a specific surface.
/// Returns null if there's no scrollback (nothing to scroll).
fn scrollbarGeometryForSurface(surface: *Surface, view_height: f32, top_padding: f32) ?ScrollbarGeometry {
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
fn scrollbarGeometry(window_height: f32, top_padding: f32) ?ScrollbarGeometry {
    const surface = activeSurface() orelse return null;
    return scrollbarGeometryForSurface(surface, window_height, top_padding);
}

/// Show the scrollbar on the active surface (reset fade timer).
fn scrollbarShow() void {
    const surface = activeSurface() orelse return;
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
fn renderScrollbarForSurface(surface: *Surface, view_width: f32, view_height: f32, top_padding: f32) void {
    scrollbarUpdateFade(surface);
    if (surface.scrollbar_opacity <= 0.01) return;

    const geo = scrollbarGeometryForSurface(surface, view_height, top_padding) orelse return;

    const bar_x = view_width - SCROLLBAR_WIDTH;
    const bar_w = SCROLLBAR_WIDTH;

    // Use the shader_program for quad rendering
    gl.UseProgram.?(shader_program);
    gl.BindVertexArray.?(vao);

    const fade = surface.scrollbar_opacity;

    // Track background: black at low alpha to subtly lift it from the terminal bg
    const track_alpha = fade * 0.08;
    renderQuadAlpha(bar_x, geo.track_y, bar_w, geo.track_h, .{ 0, 0, 0 }, track_alpha);

    // Thumb: black at 45% opacity
    const thumb_alpha = fade * 0.45;
    renderQuadAlpha(bar_x, geo.thumb_y, bar_w, geo.thumb_h, .{ 0, 0, 0 }, thumb_alpha);
}

/// Render the scrollbar overlay (uses active surface at full window size).
fn renderScrollbar(window_width: f32, window_height: f32, top_padding: f32) void {
    const surface = activeSurface() orelse return;
    renderScrollbarForSurface(surface, window_width, window_height, top_padding);
}

// ============================================================================
// Resize overlay — shows "cols × rows" during terminal resize
// ============================================================================

/// Trigger the resize overlay to show with the given dimensions.
/// Called whenever the terminal size changes.
fn resizeOverlayShow(cols: u16, rows: u16) void {
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
fn renderRoundedQuadAlpha(x: f32, y: f32, w: f32, h: f32, radius: f32, color: [3]f32, alpha: f32) void {
    const r = @min(radius, @min(w, h) / 2); // Clamp radius to half of smallest dimension

    // Main body (center rectangle, full height minus corners)
    renderQuadAlpha(x + r, y, w - r * 2, h, color, alpha);

    // Left strip (between corners)
    renderQuadAlpha(x, y + r, r, h - r * 2, color, alpha);

    // Right strip (between corners)
    renderQuadAlpha(x + w - r, y + r, r, h - r * 2, color, alpha);

    // Approximate corners with small quads (simple 2-step approximation)
    // Bottom-left corner
    const r2 = r * 0.7; // Inner radius approximation
    renderQuadAlpha(x + r - r2, y + r - r2, r2, r2, color, alpha);
    renderQuadAlpha(x, y + r - r2, r - r2, r2, color, alpha);
    renderQuadAlpha(x + r - r2, y, r2, r - r2, color, alpha);

    // Bottom-right corner
    renderQuadAlpha(x + w - r, y + r - r2, r2, r2, color, alpha);
    renderQuadAlpha(x + w - r + r2, y + r - r2, r - r2, r2, color, alpha);
    renderQuadAlpha(x + w - r, y, r2, r - r2, color, alpha);

    // Top-left corner
    renderQuadAlpha(x + r - r2, y + h - r, r2, r2, color, alpha);
    renderQuadAlpha(x, y + h - r, r - r2, r2, color, alpha);
    renderQuadAlpha(x + r - r2, y + h - r + r2, r2, r - r2, color, alpha);

    // Top-right corner
    renderQuadAlpha(x + w - r, y + h - r, r2, r2, color, alpha);
    renderQuadAlpha(x + w - r + r2, y + h - r, r - r2, r2, color, alpha);
    renderQuadAlpha(x + w - r, y + h - r + r2, r2, r - r2, color, alpha);
}

/// Render the resize overlay centered on screen.
fn renderResizeOverlay(window_width: f32, window_height: f32) void {
    renderResizeOverlayWithOffset(window_width, window_height, 0);
}

/// Render the resize overlay centered in the content area (below titlebar).
fn renderResizeOverlayWithOffset(window_width: f32, window_height: f32, top_offset: f32) void {
    resizeOverlayUpdate();
    if (g_resize_overlay_opacity <= 0.01) return;

    renderResizeOverlayText(g_resize_overlay_cols, g_resize_overlay_rows, window_width, window_height, top_offset, g_resize_overlay_opacity);
}

/// Render the resize overlay for a specific surface (used during divider dragging or equalize).
/// Shows the surface's current dimensions centered in the viewport.
/// Only shows if this surface's size actually changed during the drag/equalize.
fn renderResizeOverlayForSurface(surface: *Surface, window_width: f32, window_height: f32) void {
    // Show during divider dragging OR during timed split resize overlay (equalize, keyboard resize)
    const show_timed = std.time.milliTimestamp() < g_split_resize_overlay_until;
    if (!g_divider_dragging and !show_timed) return;
    if (!surface.resize_overlay_active) return;

    const cols = surface.size.grid.cols;
    const rows = surface.size.grid.rows;

    renderResizeOverlayText(cols, rows, window_width, window_height, 0, 1.0);
}

/// Core function to render a resize overlay with specific dimensions.
fn renderResizeOverlayText(cols: u16, rows: u16, window_width: f32, window_height: f32, top_offset: f32, alpha: f32) void {
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

    gl.UseProgram.?(shader_program);
    gl.BindVertexArray.?(vao);

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

/// Check if a point (in client pixel coords, origin top-left) is over the scrollbar.
fn scrollbarHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_padding: f32) bool {
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
fn scrollbarThumbHitTest(ypos: f64, window_height: f32, top_padding: f32) bool {
    const geo = scrollbarGeometry(window_height, top_padding) orelse return false;
    // Convert ypos (top-left origin) to GL coords (bottom-left origin)
    const gl_y = window_height - @as(f32, @floatCast(ypos));
    return gl_y >= geo.thumb_y and gl_y <= geo.thumb_y + geo.thumb_h;
}

/// Handle scrollbar drag: convert pixel y to scroll position.
fn scrollbarDrag(ypos: f64, window_height: f32, top_padding: f32) void {
    const surface = activeSurface() orelse return;
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
        surface.terminal.scrollViewport(.{ .delta = delta }) catch {};
    }
}

/// Render the FPS debug overlay in the bottom-right corner.
fn renderDebugOverlay(window_width: f32) void {
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
            break :blk std.fmt.bufPrint(&buf, "{d} draws", .{g_draw_call_count}) catch break :blk "";
        }, .{ 1.0, 1.0, 0.0 });

    }
}

fn renderDebugLine(window_width: f32, y_pos: *f32, margin: f32, pad_h: f32, pad_v: f32, line_h: f32, text: []const u8, text_color: [3]f32) void {
    if (text.len == 0) return;

    gl.UseProgram.?(shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(vao);

    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }

    const bg_w = text_width + pad_h * 2;
    const bg_x = window_width - bg_w - margin;
    const bg_y = y_pos.*;

    renderQuad(bg_x, bg_y, bg_w, line_h, .{ 0.0, 0.0, 0.0 });

    var x = bg_x + pad_h;
    const y = bg_y + pad_v;
    for (text) |ch| {
        titlebar.renderTitlebarChar(@intCast(ch), x, y, text_color);
        x += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }

    y_pos.* += line_h + 2; // spacing between lines
}

/// Update cursor blink state based on time (call once per frame)
fn updateCursorBlink() void {
    if (!g_cursor_blink) {
        g_cursor_blink_visible = true;
        return;
    }

    const now = std.time.milliTimestamp();
    if (now - g_last_blink_time >= CURSOR_BLINK_INTERVAL_MS) {
        g_cursor_blink_visible = !g_cursor_blink_visible;
        g_last_blink_time = now;
    }
}

/// Update cursor blink for a specific renderer (per-surface blink state)
fn updateCursorBlinkForRenderer(rend: *Renderer) void {
    if (!g_cursor_blink) {
        rend.cursor_blink_visible = true;
        return;
    }

    const now = std.time.milliTimestamp();
    if (now - rend.last_cursor_blink_time >= CURSOR_BLINK_INTERVAL_MS) {
        rend.cursor_blink_visible = !rend.cursor_blink_visible;
        rend.last_cursor_blink_time = now;
    }
}

/// Resize the window to fit the current terminal grid and cell dimensions.
/// Called from WM_SIZE inside the Win32 modal resize loop.
/// Performs a full render cycle: resize terminal → snapshot → rebuild → draw.
/// This runs synchronously on the main thread (which owns the GL context)
/// while Win32's modal drag loop is active.
fn onWin32Resize(width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    const allocator = g_allocator orelse return;

    // Match exactly what computeSplitLayout → setScreenSize computes for a
    // root (full-window) surface, so term_cols/term_rows stay in sync and
    // new tabs don't see a spurious resize on first render.
    //
    // Width: render-loop subtracts 2*render_padding, then edge extensions add
    //        it back for the root surface, so only explicit L+R matter.
    // Height: render-loop subtracts (render_padding+TB) top and render_padding
    //         bottom, then setScreenSize subtracts explicit T+B on top of that.
    const padding_left: f32 = @floatFromInt(DEFAULT_PADDING);
    const padding_right: f32 = @as(f32, @floatFromInt(DEFAULT_PADDING)) + SCROLLBAR_WIDTH;
    const padding_top: f32 = @floatFromInt(DEFAULT_PADDING);
    const padding_bottom: f32 = @floatFromInt(DEFAULT_PADDING);
    const render_padding: f32 = 10;
    const tb: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
    const avail_w = @as(f32, @floatFromInt(width)) - padding_left - padding_right;
    const avail_h = @as(f32, @floatFromInt(height)) - (render_padding * 2 + tb) - padding_top - padding_bottom;
    if (avail_w <= 0 or avail_h <= 0) return;

    const new_cols: u16 = @intFromFloat(@max(1, avail_w / font.cell_width));
    const new_rows: u16 = @intFromFloat(@max(1, avail_h / font.cell_height));

    // Resize terminal + PTY if grid dimensions changed
    if (new_cols != term_cols or new_rows != term_rows) {
        term_cols = new_cols;
        term_rows = new_rows;
        // Clear any pending coalesced resize — we're handling it now
        g_pending_resize = false;

        // Show resize overlay with new dimensions
        resizeOverlayShow(new_cols, new_rows);

        for (0..tab.g_tab_count) |ti| {
            if (tab.g_tabs[ti]) |active_t| {
                // Resize all surfaces in this tab's split tree
                var it = active_t.tree.iterator();
                while (it.next()) |entry| {
                    entry.surface.render_state.mutex.lock();
                    entry.surface.terminal.resize(allocator, term_cols, term_rows) catch {};
                    entry.surface.render_state.mutex.unlock();
                    entry.surface.pty.resize(term_cols, term_rows);
                }
            }
        }
    }

    // Snapshot + rebuild + draw
    if (activeSurface()) |surface| {
        const rend = &surface.surface_renderer;
        var needs_rebuild: bool = false;
        {
            surface.render_state.mutex.lock();
            defer surface.render_state.mutex.unlock();
            rend.force_rebuild = true;
            needs_rebuild = cell_renderer.updateTerminalCells(rend, &surface.terminal);
        }
        if (needs_rebuild) cell_renderer.rebuildCells(rend);

        // Sync atlas if needed
        if (font.g_atlas != null) font.syncAtlasTexture(&font.g_atlas, &font.g_atlas_texture, &font.g_atlas_modified);
        if (font.g_color_atlas != null) font.syncAtlasTexture(&font.g_color_atlas, &font.g_color_atlas_texture, &font.g_color_atlas_modified);
        if (font.g_icon_atlas != null) font.syncAtlasTexture(&font.g_icon_atlas, &font.g_icon_atlas_texture, &font.g_icon_atlas_modified);
        if (font.g_titlebar_atlas != null) font.syncAtlasTexture(&font.g_titlebar_atlas, &font.g_titlebar_atlas_texture, &font.g_titlebar_atlas_modified);

        gl.Viewport.?(0, 0, width, height);
        setProjection(@floatFromInt(width), @floatFromInt(height));
        gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
        gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
        titlebar.renderTitlebar(@floatFromInt(width), @floatFromInt(height), tb);
        cell_renderer.drawCells(rend, @floatFromInt(height), padding_left, padding_top + tb);
        renderScrollbar(@floatFromInt(width), @floatFromInt(height), padding_top + tb);
        renderResizeOverlay(@floatFromInt(width), @floatFromInt(height));
        renderDebugOverlay(@floatFromInt(width));
    } else {
        gl.Viewport.?(0, 0, width, height);
        setProjection(@floatFromInt(width), @floatFromInt(height));
        gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
        gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
        titlebar.renderTitlebar(@floatFromInt(width), @floatFromInt(height), tb);
    }

    if (g_window) |w| w.swapBuffers();
}

fn resizeWindowToGrid() void {
    const padding: f32 = 10;
    const tb: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
    const content_w: f32 = font.cell_width * @as(f32, @floatFromInt(term_cols));
    const content_h: f32 = font.cell_height * @as(f32, @floatFromInt(term_rows));
    const win_w: i32 = @intFromFloat(content_w + padding * 2);
    const win_h: i32 = @intFromFloat(content_h + padding + (padding + tb));
    if (g_window) |w| w.setSize(win_w, win_h);
}

/// Check if the config file has changed (via ReadDirectoryChangesW) and reload if so.
fn checkConfigReload(allocator: std.mem.Allocator, watcher: *ConfigWatcher) void {
    if (!watcher.hasChanged()) return;

    std.debug.print("Config file changed, reloading...\n", .{});

    const cfg = Config.load(allocator) catch |err| {
        std.debug.print("Failed to reload config: {}\n", .{err});
        return;
    };
    defer cfg.deinit(allocator);

    // Update App's cached config so new windows get the new settings
    if (g_app) |app| {
        app.updateConfig(&cfg);
    }

    if (g_window == null) return;
    const ft_lib = font.g_ft_lib orelse return;

    // --- Theme, cursor, debug ---
    g_theme = cfg.resolved_theme;
    g_force_rebuild = true;
    g_cursor_style = cfg.@"cursor-style";
    g_cursor_blink = cfg.@"cursor-style-blink";
    g_debug_fps = cfg.@"phantty-debug-fps";
    g_debug_draw_calls = cfg.@"phantty-debug-draw-calls";

    // --- Split config ---
    g_unfocused_split_opacity = cfg.@"unfocused-split-opacity";
    g_focus_follows_mouse = cfg.@"focus-follows-mouse";
    g_split_divider_color = cfg.@"split-divider-color";

    // Sync cursor style to all tabs' terminals (rendering reads from terminal state)
    for (0..tab.g_tab_count) |ti| {
        if (tab.g_tabs[ti]) |tb| {
            // Update all surfaces in this tab's split tree
            var it = tb.tree.iterator();
            while (it.next()) |entry| {
                entry.surface.render_state.mutex.lock();
                entry.surface.terminal.screens.active.cursor.cursor_style = switch (g_cursor_style) {
                    .bar => .bar,
                    .block => .block,
                    .underline => .underline,
                    .block_hollow => .block_hollow,
                };
                entry.surface.render_state.mutex.unlock();
            }
        }
    }

    // --- Font ---
    const new_font_size = cfg.@"font-size";
    const new_weight = cfg.@"font-style".toDwriteWeight();
    const new_family = cfg.@"font-family";

    // Reload font: clear caches, load new face, recalculate metrics
    if (font.loadFontFromConfig(allocator, new_family, new_weight, new_font_size, ft_lib)) |new_face| {
        // Clean up old font state
        if (font.glyph_face) |old| old.deinit();
        font.clearGlyphCache(allocator);
        font.clearFallbackFaces(allocator);
        font.g_bell_cache = null;
        if (font.g_bell_emoji_face) |f| f.deinit();
        font.g_bell_emoji_face = null;

        font.g_font_size = new_font_size;
        font.preloadCharacters(new_face);
        // glyph_face is set inside preloadCharacters

        // Rebuild titlebar font at 14pt with the new family
        if (font.g_titlebar_face) |old_tb| old_tb.deinit();
        font.g_titlebar_face = null;
        font.g_titlebar_cache.deinit(allocator);
        font.g_titlebar_cache = .empty;
        if (font.g_titlebar_atlas) |*a| {
            a.deinit(allocator);
            font.g_titlebar_atlas = null;
        }
        if (font.g_titlebar_atlas_texture != 0) {
            gl.DeleteTextures.?(1, &font.g_titlebar_atlas_texture);
            font.g_titlebar_atlas_texture = 0;
            font.g_titlebar_atlas_modified = 0;
        }
        if (font.loadFontFromConfig(allocator, new_family, new_weight, 10, ft_lib)) |tb_face| {
            font.g_titlebar_face = tb_face;
            const sm = tb_face.handle.*.size.*.metrics;
            font.g_titlebar_cell_height = @round(@as(f32, @floatFromInt(sm.height)) / 64.0);
            font.g_titlebar_baseline = @round(-@as(f32, @floatFromInt(sm.descender)) / 64.0);
        }

        // --- Window size ---
        // If window size is configured, apply it; then resize window to match new cell dims
        if (cfg.@"window-width" > 0) term_cols = cfg.@"window-width";
        if (cfg.@"window-height" > 0) term_rows = cfg.@"window-height";
        resizeWindowToGrid();

        // Resize ALL tabs' terminals and PTYs to match
        for (0..tab.g_tab_count) |ti| {
            if (tab.g_tabs[ti]) |tb| {
                // Resize all surfaces in this tab's split tree
                var it = tb.tree.iterator();
                while (it.next()) |entry| {
                    entry.surface.render_state.mutex.lock();
                    entry.surface.terminal.resize(allocator, term_cols, term_rows) catch {};
                    entry.surface.render_state.mutex.unlock();
                    entry.surface.pty.resize(term_cols, term_rows);
                }
            }
        }
    } else {
        std.debug.print("Reload: failed to load font, keeping current font\n", .{});
    }

    std.debug.print("Config reloaded successfully\n", .{});
}

/// Reset cursor blink to visible state (call on keypress like Ghostty)
fn resetCursorBlink() void {
    g_cursor_blink_visible = true;
    g_last_blink_time = std.time.milliTimestamp();
}

/// Handle a bell notification from the terminal.
/// Rate-limited to once per 100ms (matching Ghostty).
fn handleBell(surface: *Surface, win: *win32_backend.Window, is_active_tab: bool) void {
    _ = is_active_tab;
    const now = std.time.milliTimestamp();
    if (now - surface.last_bell_time < 100) return;
    surface.last_bell_time = now;

    // Activate bell indicator (shown on both active and background tabs)
    surface.bell_indicator = true;
    surface.bell_indicator_time = now;

    win.playBell();
    win.flashTaskbar();
}

// ============================================================================
// Shared helpers (used by both backends)
// ============================================================================

// Convert mouse position to terminal cell coordinates
/// Get the viewport's absolute row offset into the scrollback.
/// Row 0 on screen corresponds to absolute row `viewportOffset()`.
pub fn viewportOffset() usize {
    const surface = activeSurface() orelse return 0;
    return surface.terminal.screens.active.pages.scrollbar().offset;
}

fn mouseToCell(xpos: f64, ypos: f64) struct { col: usize, row: usize } {
    const padding_d: f64 = 10;
    const tb_d: f64 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
    const col_f = (xpos - padding_d) / @as(f64, font.cell_width);
    const row_f = (ypos - padding_d - tb_d) / @as(f64, font.cell_height);

    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(term_cols))) term_cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(term_rows))) term_rows - 1 else @as(usize, @intFromFloat(row_f));

    return .{ .col = col, .row = row };
}

// Cell rendering functions moved to appwindow/cell_renderer.zig


// ============================================================================
// Win32-specific input processing (only compiled for Win32 backend)
// ============================================================================

const win32_input = struct {

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

        const width = win.width;
        const height = win.height;
        // Match exactly what computeSplitLayout → setScreenSize computes for a
        // root (full-window) surface.
        //
        // Width: render-loop subtracts 2*render_padding, but edge extensions
        //        add it back for the root surface → only explicit L+R matter.
        // Height: render-loop subtracts (render_padding+TB) top + render_padding
        //         bottom, then setScreenSize subtracts explicit T+B.
        const render_padding: f32 = 10;
        const tb_offset: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
        const explicit_left: f32 = @floatFromInt(DEFAULT_PADDING);
        const explicit_right: f32 = @as(f32, @floatFromInt(DEFAULT_PADDING)) + SCROLLBAR_WIDTH;
        const explicit_top: f32 = @floatFromInt(DEFAULT_PADDING);
        const explicit_bottom: f32 = @floatFromInt(DEFAULT_PADDING);

        const total_width_padding = explicit_left + explicit_right;
        const total_height_padding = render_padding * 2 + tb_offset + explicit_top + explicit_bottom;
        
        const avail_width = @as(f32, @floatFromInt(width)) - total_width_padding;
        const avail_height = @as(f32, @floatFromInt(height)) - total_height_padding;

        const new_cols: u16 = @intFromFloat(@max(1, avail_width / font.cell_width));
        const new_rows: u16 = @intFromFloat(@max(1, avail_height / font.cell_height));

        if (new_cols != term_cols or new_rows != term_rows) {
            g_pending_resize = true;
            g_pending_cols = new_cols;
            g_pending_rows = new_rows;
            g_last_resize_time = std.time.milliTimestamp();
        }
    }

    fn handleChar(ev: win32_backend.CharEvent) void {
        // When tab rename is active, route chars to the rename buffer
        if (tab.g_tab_rename_active) {
            g_cursor_blink_visible = true;
            g_last_blink_time = std.time.milliTimestamp();
            tab.handleRenameChar(ev.codepoint);
            return;
        }
        if (!isActiveTabTerminal()) return;
        // Skip chars when Alt is held without Ctrl — those are part of Alt+key
        // combos (e.g. Shift+Alt+4) and shouldn't produce text input.
        // However, AltGr on international keyboards reports as Ctrl+Alt, so
        // we must allow chars when both Ctrl and Alt are held (AltGr chars).
        // This matches Ghostty's consumed_mods / effectiveMods approach.
        if (ev.alt and !ev.ctrl) return;
        const surface = activeSurface() orelse return;
        resetCursorBlink();
        {
            surface.render_state.mutex.lock();
            defer surface.render_state.mutex.unlock();
            surface.terminal.scrollViewport(.bottom) catch {};
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(ev.codepoint, &buf) catch return;
        _ = surface.pty.write(buf[0..len]) catch {};
    }

    fn handleKey(ev: win32_backend.KeyEvent) void {
        // Ctrl+Shift+N = new window (even during tab rename)
        if (ev.ctrl and ev.shift and ev.vk == 0x4E) { // 'N'
            if (tab.g_tab_rename_active) tab.commitTabRename();
            if (g_app) |app| {
                const hwnd = if (g_window) |w| w.hwnd else null;
                // Get CWD from active tab for working directory inheritance
                var cwd_buf: [260]u16 = undefined;
                var cwd: ?[]const u16 = null;
                if (activeSurface()) |surface| {
                    if (surface.getCwd()) |unix_path| {
                        std.debug.print("CWD from OSC 7: {s}\n", .{unix_path});
                        if (unixPathToWindows(unix_path, &cwd_buf)) |len| {
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
        // Ctrl+Shift+T = new tab (even during tab rename)
        if (ev.ctrl and ev.shift and ev.vk == 0x54) { // 'T'
            if (tab.g_tab_rename_active) tab.commitTabRename();
            _ = spawnTab(g_allocator orelse return);
            return;
        }
        // Ctrl+Shift+O = new split right (vertical divider)
        if (ev.ctrl and ev.shift and ev.vk == 0x4F) { // 'O'
            if (tab.g_tab_rename_active) tab.commitTabRename();
            splitFocused(.right);
            return;
        }
        // Ctrl+Shift+E = new split down (horizontal divider)
        if (ev.ctrl and ev.shift and ev.vk == 0x45) { // 'E'
            if (tab.g_tab_rename_active) tab.commitTabRename();
            splitFocused(.down);
            return;
        }
        // When tab rename is active, handle special keys
        if (tab.g_tab_rename_active) {
            g_cursor_blink_visible = true;
            g_last_blink_time = std.time.milliTimestamp();
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
            closeFocusedSplit();
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
                gotoSplit(.{ .spatial = d });
                return;
            }
        }
        // Ctrl+Shift+[ = goto previous split
        if (ev.ctrl and ev.shift and ev.vk == win32_backend.VK_OEM_4) { // '['
            gotoSplit(.previous_wrapped);
            return;
        }
        // Ctrl+Shift+] = goto next split
        if (ev.ctrl and ev.shift and ev.vk == win32_backend.VK_OEM_6) { // ']'
            gotoSplit(.next_wrapped);
            return;
        }
        // Ctrl+Shift+Z = equalize splits
        if (ev.ctrl and ev.shift and ev.vk == 0x5A) { // 'Z'
            equalizeSplits();
            return;
        }
        // Ctrl+Tab = next tab
        if (ev.ctrl and ev.vk == win32_backend.VK_TAB) {
            if (ev.shift) {
                // Ctrl+Shift+Tab = previous tab
                if (tab.g_active_tab > 0) switchTab(tab.g_active_tab - 1) else switchTab(tab.g_tab_count - 1);
            } else {
                switchTab((tab.g_active_tab + 1) % tab.g_tab_count);
            }
            return;
        }
        // Ctrl+1-9 = switch to tab N
        if (ev.ctrl and !ev.shift and ev.vk >= 0x31 and ev.vk <= 0x39) { // '1'-'9'
            const tab_idx = @as(usize, @intCast(ev.vk - 0x31));
            if (tab_idx < tab.g_tab_count) switchTab(tab_idx);
            return;
        }
        // Ctrl+, = open config
        if (ev.ctrl and ev.vk == win32_backend.VK_OEM_COMMA) {
            std.debug.print("[keybind] Ctrl+, pressed\n", .{});
            if (g_allocator) |alloc| Config.openConfigInEditor(alloc);
            return;
        }
        // Alt+Enter = toggle fullscreen
        if (ev.alt and ev.vk == win32_backend.VK_RETURN) {
            toggleFullscreen();
            return;
        }

        // Don't send input to PTY if active tab isn't the terminal
        if (!isActiveTabTerminal()) return;

        const surface = activeSurface() orelse return;
        const pty = &surface.pty;

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
                    surface.terminal.scrollViewport(.{ .delta = -@as(isize, term_rows / 2) }) catch {};
                    surface.render_state.mutex.unlock();
                    scrollbarShow();
                    break :blk null;
                }
                break :blk "\x1b[5~";
            },
            win32_backend.VK_NEXT => blk: { // Page Down
                if (ev.shift) {
                    surface.render_state.mutex.lock();
                    surface.terminal.scrollViewport(.{ .delta = @as(isize, term_rows / 2) }) catch {};
                    surface.render_state.mutex.unlock();
                    scrollbarShow();
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
                        _ = pty.write(&[_]u8{ctrl_char}) catch {};
                        wrote_to_pty = true;
                    }
                }
                break :blk null;
            },
        };

        if (seq) |s| {
            _ = pty.write(s) catch {};
            wrote_to_pty = true;
        }

        // Only scroll to bottom and reset cursor blink when we actually sent
        // data to the PTY. This matches Ghostty's behavior: modifier-only keys,
        // unbound key combos (like Shift+Alt+4), and scroll keys don't snap
        // the viewport to the bottom.
        if (wrote_to_pty) {
            resetCursorBlink();
            surface.render_state.mutex.lock();
            surface.terminal.scrollViewport(.bottom) catch {};
            surface.render_state.mutex.unlock();
        }
    }

    var plus_btn_pressed: bool = false;

    fn handleMouseButton(ev: win32_backend.MouseButtonEvent) void {
        // Double-click on tab text to rename, elsewhere to maximize
        if (ev.button == .left and ev.action == .double_click) {
            const xpos: f64 = @floatFromInt(ev.x);
            const xf: f32 = @floatFromInt(ev.x);
            const titlebar_h: f64 = if (g_window) |w| @floatFromInt(w.titlebar_height) else 40;
            const ypos: f64 = @floatFromInt(ev.y);
            if (ypos < titlebar_h) {
                if (hitTestTab(xpos)) |tab_idx| {
                    // Only rename if clicking on the text itself
                    if (tab_idx < MAX_TABS and xf >= tab.g_tab_text_x_start[tab_idx] and xf <= tab.g_tab_text_x_end[tab_idx]) {
                        tab.startTabRename(tab_idx);
                    } else {
                        // Double-click on tab but not on text — maximize/restore
                        if (g_window) |w| {
                            if (win32_backend.IsZoomed(w.hwnd) != 0) {
                                _ = win32_backend.ShowWindow(w.hwnd, win32_backend.SW_RESTORE);
                            } else {
                                _ = win32_backend.ShowWindow(w.hwnd, win32_backend.SW_MAXIMIZE);
                            }
                        }
                    }
                } else {
                    // Double-click on empty titlebar area — maximize/restore
                    if (g_window) |w| {
                        if (win32_backend.IsZoomed(w.hwnd) != 0) {
                            _ = win32_backend.ShowWindow(w.hwnd, win32_backend.SW_RESTORE);
                        } else {
                            _ = win32_backend.ShowWindow(w.hwnd, win32_backend.SW_MAXIMIZE);
                        }
                    }
                }
            }
            return;
        }

        // Middle-click on tab to close it
        if (ev.button == .middle and ev.action == .release) {
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            const titlebar_h: f64 = if (g_window) |w| @floatFromInt(w.titlebar_height) else 40;
            if (ypos < titlebar_h) {
                if (hitTestTab(xpos)) |tab_idx| {
                    if (tab.g_tab_count <= 1) {
                        g_should_close = true;
                    } else {
                        closeTab(tab_idx);
                    }
                }
            }
            return;
        }

        if (ev.button == .left) {
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            const titlebar_h: f64 = if (g_window) |w| @floatFromInt(w.titlebar_height) else 40;

            if (ev.action == .press) {
                // Commit rename on any click
                if (tab.g_tab_rename_active) tab.commitTabRename();

                // Check if click is in the titlebar (tab bar area)
                if (ypos < titlebar_h) {
                    handleTabBarPress(xpos);
                    return;
                }

                // Click in terminal content area: update split focus
                updateFocusFromMouse(@intFromFloat(xpos), @intFromFloat(ypos));

                // Check if click is on the scrollbar
                const win = g_window orelse return;
                const fb = win.getFramebufferSize();
                const w_f: f32 = @floatFromInt(fb.width);
                const h_f: f32 = @floatFromInt(fb.height);
                const tb_f: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
                const top_pad: f32 = 10 + tb_f;
                const sb_opacity = if (activeSurface()) |s| s.scrollbar_opacity else 0;
                if (sb_opacity > 0 and scrollbarHitTest(xpos, ypos, w_f, h_f, top_pad)) {
                    g_scrollbar_dragging = true;
                    scrollbarShow();
                    // Calculate drag offset within thumb
                    if (scrollbarThumbHitTest(ypos, h_f, top_pad)) {
                        // Clicked on thumb — offset from top of thumb
                        const geo = scrollbarGeometry(h_f, top_pad) orelse return;
                        const thumb_top_px = h_f - (geo.thumb_y + geo.thumb_h); // convert GL→pixel
                        g_scrollbar_drag_offset = @as(f32, @floatCast(ypos)) - thumb_top_px;
                    } else {
                        // Clicked on track — jump thumb center to click position
                        const geo = scrollbarGeometry(h_f, top_pad) orelse return;
                        g_scrollbar_drag_offset = geo.thumb_h / 2;
                        scrollbarDrag(ypos, h_f, top_pad);
                    }
                    return;
                }

                // Check if click is on a split divider
                if (hitTestDivider(ev.x, ev.y)) |hit| {
                    g_divider_dragging = true;
                    g_divider_drag_handle = hit.handle;
                    g_divider_drag_layout = hit.layout;
                    // Initialize per-surface resize tracking with current sizes
                    // so we only show overlays on surfaces that actually change
                    if (activeTab()) |tb| {
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
                const clicked_surface = surfaceAtPoint(@intFromFloat(xpos), @intFromFloat(ypos)) orelse activeSurface() orelse return;

                // Focus the clicked split if different from current focus
                if (activeTab()) |tb| {
                    for (0..g_split_rect_count) |i| {
                        if (g_split_rects[i].surface == clicked_surface) {
                            tb.focused = g_split_rects[i].handle;
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
                g_scrollbar_dragging = false;

                // Handle divider drag release
                if (g_divider_dragging) {
                    g_divider_dragging = false;
                    g_divider_drag_handle = null;
                    g_divider_drag_layout = null;
                    // Reset per-surface resize overlay state
                    if (activeTab()) |tb| {
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
                    if (ypos < titlebar_h and pressed_idx < tab.g_tab_count) {
                        if (hitTestTabCloseButton(xpos, pressed_idx)) {
                            if (tab.g_tab_count <= 1) {
                                g_should_close = true;
                            } else {
                                closeTab(pressed_idx);
                            }
                        }
                    }
                    return;
                }

                if (plus_btn_pressed) {
                    plus_btn_pressed = false;
                    // Only fire if still in the + button area
                    if (ypos < titlebar_h and hitTestPlusButton(xpos)) {
                        _ = spawnTab(g_allocator orelse return);
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
        const win = g_window orelse return;
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
                switchTab(tab_idx);
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
        const win = g_window orelse return null;
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
            const win = g_window orelse break :blk 800.0;
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
        const win = g_window orelse return false;
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
                const active_tab = activeTab() orelse return;
                const allocator = g_allocator orelse return;

                // Get spatial info for this split
                var spatial = active_tab.tree.spatial(allocator) catch return;
                defer spatial.deinit(allocator);

                // Get content area dimensions
                const win = g_window orelse return;
                const fb = win.getFramebufferSize();
                const content_x: f32 = @floatFromInt(DEFAULT_PADDING);
                const content_y: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
                const content_w: f32 = @floatFromInt(@as(i32, @intCast(fb.width)) - @as(i32, @intCast(2 * DEFAULT_PADDING)));
                const content_h: f32 = @floatFromInt(@as(i32, @intCast(fb.height)) - win32_backend.TITLEBAR_HEIGHT - @as(i32, @intCast(DEFAULT_PADDING)));

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
                g_force_rebuild = true;
                g_cells_valid = false;
            }
            return;
        }

        // Focus follows mouse: check if mouse is over a different split
        if (g_focus_follows_mouse) {
            updateFocusFromMouse(@intFromFloat(xpos), @intFromFloat(ypos));
        }

        // Update scrollbar hover state
        const win = g_window orelse return;
        const fb = win.getFramebufferSize();
        const w_f: f32 = @floatFromInt(fb.width);
        const h_f: f32 = @floatFromInt(fb.height);
        const tb_f: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
        const top_pad: f32 = 10 + tb_f;

        const was_hover = g_scrollbar_hover;
        g_scrollbar_hover = scrollbarHitTest(xpos, ypos, w_f, h_f, top_pad);
        const sb_opacity2 = if (activeSurface()) |s| s.scrollbar_opacity else 0;
        if (g_scrollbar_hover and !was_hover and sb_opacity2 > 0) {
            scrollbarShow(); // Reset fade timer when entering scrollbar area
        }

        // Handle scrollbar drag
        if (g_scrollbar_dragging) {
            scrollbarDrag(ypos, h_f, top_pad);
            return;
        }

        // Check for divider hover and update cursor
        if (!g_scrollbar_hover and !g_selecting) {
            if (hitTestDivider(ev.x, ev.y)) |hit| {
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
        activeSelection().end_col = cell_pos.col;
        activeSelection().end_row = abs_row;

        const threshold = font.cell_width * 0.6;
        const padding_d: f64 = 10;
        const click_cell_x = g_click_x - padding_d - @as(f64, @floatFromInt(activeSelection().start_col)) * @as(f64, font.cell_width);
        const drag_cell_x = xpos - padding_d - @as(f64, @floatFromInt(cell_pos.col)) * @as(f64, font.cell_width);

        const same_cell = (activeSelection().start_col == cell_pos.col and activeSelection().start_row == abs_row);
        if (same_cell) {
            const moved_right = drag_cell_x >= threshold and click_cell_x < threshold;
            const moved_left = drag_cell_x < threshold and click_cell_x >= threshold;
            activeSelection().active = moved_right or moved_left;
        } else {
            activeSelection().active = true;
        }
    }

    fn handleMouseWheel(ev: win32_backend.MouseWheelEvent) void {
        // Scroll the surface under the mouse cursor (like Ghostty), not the focused surface.
        // Fall back to focused surface if mouse is not over any split.
        const surface = surfaceAtPoint(ev.xpos, ev.ypos) orelse activeSurface() orelse return;

        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        // WHEEL_DELTA is 120 per notch. Convert to lines (3 lines per notch, like GLFW).
        const notches = @as(f64, @floatFromInt(ev.delta)) / 120.0;
        const delta: isize = @intFromFloat(-notches * 3);
        surface.terminal.scrollViewport(.{ .delta = delta }) catch {};

        // Show scrollbar for the scrolled surface
        surface.scrollbar_opacity = 1.0;
        surface.scrollbar_show_time = std.time.milliTimestamp();
    }

    // --- Clipboard (Win32 native) ---

    fn copySelectionToClipboard() void {
        const surface = activeSurface() orelse return;
        const allocator = g_allocator orelse return;
        const win = g_window orelse return;

        if (!activeSelection().active) return;

        var start_row = activeSelection().start_row;
        var start_col = activeSelection().start_col;
        var end_row = activeSelection().end_row;
        var end_col = activeSelection().end_col;

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
            if (vp_row >= term_rows) continue;

            const row_start_col = if (row == start_row) start_col else 0;
            const row_end_col = if (row == end_row) end_col else term_cols - 1;

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

    fn pasteFromClipboard() void {
        const surface = activeSurface() orelse return;
        const win = g_window orelse return;

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
            _ = surface.pty.write(data[0..len]) catch {};
        }
    }

    // --- Fullscreen toggle (Win32 native) ---

    var saved_style: win32_backend.DWORD = 0;
    var saved_rect: win32_backend.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var is_fullscreen: bool = false;

    fn toggleFullscreen() void {
        const win = g_window orelse return;

        if (is_fullscreen) {
            // Restore windowed mode
            _ = win32_backend.SetWindowLongW(win.hwnd, -16, @bitCast(saved_style)); // GWL_STYLE
            _ = win32_backend.SetWindowPos(
                win.hwnd, null,
                saved_rect.left, saved_rect.top,
                saved_rect.right - saved_rect.left,
                saved_rect.bottom - saved_rect.top,
                0x0020 | 0x0040, // SWP_FRAMECHANGED | SWP_SHOWWINDOW
            );
            is_fullscreen = false;
            if (g_window) |w| w.is_fullscreen = false;
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
                    win.hwnd, null,
                    mi.rcMonitor.left, mi.rcMonitor.top,
                    mi.rcMonitor.right - mi.rcMonitor.left,
                    mi.rcMonitor.bottom - mi.rcMonitor.top,
                    0x0020 | 0x0040, // SWP_FRAMECHANGED | SWP_SHOWWINDOW
                );
            }
            is_fullscreen = true;
            if (g_window) |w| w.is_fullscreen = true;
            std.debug.print("Entered fullscreen\n", .{});
        }
    }
};

fn setProjection(width: f32, height: f32) void {
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };

    gl.UseProgram.?(shader_program);
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(shader_program, "projection"), 1, c.GL_FALSE, &projection);
}

/// Set the orthographic projection matrix on a specific shader program.
pub fn setProjectionForProgram(program: c.GLuint, window_height: f32) void {
    var viewport: [4]c.GLint = undefined;
    gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
    const width: f32 = @floatFromInt(viewport[2]);
    const height: f32 = @floatFromInt(viewport[3]);
    _ = window_height;

    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };

    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(program, "projection"), 1, c.GL_FALSE, &projection);
}

/// Internal main loop - called by AppWindow.run() after init() has set up globals.
fn runMainLoop(allocator: std.mem.Allocator) !void {
    // Use stored config values from init()
    const requested_font = g_requested_font;
    const requested_weight = g_requested_weight;
    const font_size = font.g_font_size;
    const shader_path = g_shader_path;

    // NOTE: Initial tab is spawned AFTER window sizing (see below),
    // so the terminal is created with the correct dimensions.

    // ================================================================
    // Initialize windowing backend
    // Defers MUST be at function scope so the window/GL context
    // stays alive for the rest of main().
    // ================================================================

    // --- Win32 window (cascade from parent or restore from last session) ---
    // Check if App has a suggested position (for cascading from parent window)
    var init_x: ?i32 = null;
    var init_y: ?i32 = null;
    if (g_app) |app| {
        app.mutex.lock();
        if (app.next_window_x) |x| {
            init_x = x;
            app.next_window_x = null;
        }
        if (app.next_window_y) |y| {
            init_y = y;
            app.next_window_y = null;
        }
        app.mutex.unlock();
    }
    // Fall back to saved state if no cascade position
    if (init_x == null or init_y == null) {
        const saved_state = loadWindowState(allocator);
        if (saved_state) |s| {
            if (init_x == null) init_x = s.x;
            if (init_y == null) init_y = s.y;
        }
    }
    var win32_window = win32_backend.Window.init(
        800,
        600,
        std.unicode.utf8ToUtf16LeStringLiteral("Phantty"),
        init_x,
        init_y,
        g_start_maximize and !g_start_fullscreen, // Don't maximize if going fullscreen
    ) catch |err| {
        std.debug.print("Failed to create Win32 window: {}\n", .{err});
        return err;
    };
    defer win32_window.deinit();
    win32_backend.setGlobalWindow(&win32_window);
    g_window = &win32_window;

    // --- Load OpenGL via GLAD ---
    {
        const version = c.gladLoadGLContext(&gl, @ptrCast(&win32_backend.glGetProcAddress));
        if (version == 0) {
            std.debug.print("Failed to initialize GLAD\n", .{});
            return error.GLADInitFailed;
        }
        std.debug.print("OpenGL {}.{}\n", .{ c.GLAD_VERSION_MAJOR(version), c.GLAD_VERSION_MINOR(version) });
    }

    // Initialize FreeType
    const ft_lib = freetype.Library.init() catch |err| {
        std.debug.print("Failed to initialize FreeType: {}\n", .{err});
        return err;
    };
    defer ft_lib.deinit();

    // Store globally for fallback font loading
    font.g_ft_lib = ft_lib;
    defer font.g_ft_lib = null;

    std.debug.print("Requested font: {s} (weight: {})\n", .{ requested_font, @intFromEnum(requested_weight) });
    std.debug.print("Cursor style: {s}, blink: {}\n", .{ @tagName(g_cursor_style), g_cursor_blink });

    // Initialize DirectWrite for font discovery (keep alive for fallback lookups)
    var dw_discovery: ?directwrite.FontDiscovery = directwrite.FontDiscovery.init() catch |err| blk: {
        std.debug.print("DirectWrite init failed: {}\n", .{err});
        break :blk null;
    };
    defer if (dw_discovery) |*dw| dw.deinit();

    // Store globally for fallback font lookups
    font.g_font_discovery = if (dw_discovery) |*dw| dw else null;
    defer font.g_font_discovery = null;

    // Fallback faces are cleaned up in the main defer block (with font.glyph_face)

    // Try to find the requested font via DirectWrite
    var font_result: ?directwrite.FontDiscovery.FontResult = null;

    if (dw_discovery) |*dw| {
        if (requested_font.len > 0) {
            if (dw.findFontFilePath(allocator, requested_font, requested_weight, .NORMAL) catch null) |result| {
                font_result = result;
                std.debug.print("Found system font: {s}\n", .{result.path});
            } else {
                std.debug.print("Font '{s}' not found, will use embedded fallback\n", .{requested_font});
            }
        } else {
            std.debug.print("No font-family set, will use embedded fallback\n", .{});
        }
    }

    defer if (font_result) |*fr| fr.deinit();

    // Load the font with FreeType
    const face: freetype.Face = blk: {
        // Try system font first
        if (font_result) |fr| {
            if (ft_lib.initFace(fr.path, @intCast(fr.face_index))) |f| {
                break :blk f;
            } else |err| {
                std.debug.print("Failed to load system font: {}, using embedded fallback\n", .{err});
            }
        }

        // Fall back to embedded JetBrains Mono
        std.debug.print("Using embedded JetBrains Mono as fallback\n", .{});
        break :blk ft_lib.initMemoryFace(embedded.regular, 0) catch |err| {
            std.debug.print("Failed to load embedded font: {}\n", .{err});
            return err;
        };
    };
    // Don't defer face.deinit() here — glyph_face owns it and may be
    // replaced by hot-reload. Cleanup is in the defer block below.

    face.setCharSize(0, @as(i32, @intCast(font_size)) * 64, 96, 96) catch |err| {
        std.debug.print("Failed to set font size: {}\n", .{err});
        return err;
    };

    // Store font size globally for fallback fonts
    font.g_font_size = font_size;

    if (!initShaders()) {
        std.debug.print("Failed to initialize shaders\n", .{});
        return error.ShaderInitFailed;
    }
    initBuffers();
    initInstancedBuffers();
    font.preloadCharacters(face);

    // Initialize titlebar font — same family at fixed 14pt for crisp tab titles
    {
        const titlebar_pt: u32 = 10;
        const tb_face = font.loadFontFromConfig(allocator, requested_font, requested_weight, titlebar_pt, ft_lib);
        if (tb_face) |tf| {
            font.g_titlebar_face = tf;

            // Calculate titlebar cell metrics from the 14pt face
            const sm = tf.handle.*.size.*.metrics;
            // Simple approach: use FreeType metrics directly
            const tb_ascent = @as(f32, @floatFromInt(sm.ascender)) / 64.0;
            const tb_descent = @as(f32, @floatFromInt(sm.descender)) / 64.0;
            const tb_height = @as(f32, @floatFromInt(sm.height)) / 64.0;
            font.g_titlebar_cell_height = @round(tb_height);
            font.g_titlebar_baseline = @round(-tb_descent);
            // Measure max advance across ASCII
            var max_adv: f32 = 0;
            for (32..127) |cp| {
                if (font.loadTitlebarGlyph(@intCast(cp))) |g| {
                    const adv = @as(f32, @floatFromInt(g.advance >> 6));
                    max_adv = @max(max_adv, adv);
                }
            }
            if (max_adv > 0) font.g_titlebar_cell_width = max_adv;

            std.debug.print("Titlebar font: {d:.0}x{d:.0} (ascent={d:.1}, descent={d:.1}, baseline={d:.0})\n", .{
                font.g_titlebar_cell_width, font.g_titlebar_cell_height, tb_ascent, tb_descent, font.g_titlebar_baseline,
            });
        } else {
            std.debug.print("Titlebar font init failed, will fall back to scaled terminal font\n", .{});
        }
    }

    // Load Segoe MDL2 Assets for caption button icons (Windows system font)
    // Size is DPI-dependent: 10px at 96 DPI, scales proportionally
    if (ft_lib.initFace("C:\\Windows\\Fonts\\segmdl2.ttf", 0)) |iface| {
        const dpi: u32 = if (g_window) |w| win32_backend.GetDpiForWindow(w.hwnd) else 96;
        // 10px at 96 DPI = 10pt at 72 DPI. Scale for actual DPI.
        const icon_size_26_6: i32 = @intCast(10 * 64 * dpi / 96);
        iface.setCharSize(0, icon_size_26_6, 72, 72) catch {};
        font.icon_face = iface;
        std.debug.print("Loaded Segoe MDL2 Assets for caption icons (dpi={})\n", .{dpi});
    } else |_| {
        std.debug.print("Segoe MDL2 Assets not found, using quad-based caption icons\n", .{});
    }

    defer {
        // Clean up icon font
        if (font.icon_face) |f| {
            f.deinit();
            font.icon_face = null;
        }

        // Clean up the current font face (may have been replaced by hot-reload)
        if (font.glyph_face) |f| f.deinit();
        font.glyph_face = null;
        // Clean up glyph cache and atlas
        font.clearGlyphCache(allocator);
        font.clearFallbackFaces(allocator);
        // Clean up icon cache and icon atlas
        font.icon_cache.deinit(allocator);
        if (font.g_icon_atlas) |*a| {
            a.deinit(allocator);
            font.g_icon_atlas = null;
        }
        if (font.g_icon_atlas_texture != 0) {
            gl.DeleteTextures.?(1, &font.g_icon_atlas_texture);
            font.g_icon_atlas_texture = 0;
        }

        // Clean up titlebar font
        if (font.g_titlebar_face) |f| f.deinit();
        font.g_titlebar_face = null;
        font.g_titlebar_cache.deinit(allocator);
        if (font.g_titlebar_atlas) |*a| {
            a.deinit(allocator);
            font.g_titlebar_atlas = null;
        }
        if (font.g_titlebar_atlas_texture != 0) {
            gl.DeleteTextures.?(1, &font.g_titlebar_atlas_texture);
            font.g_titlebar_atlas_texture = 0;
        }
    }
    initSolidTexture();

    // Initialize custom post-processing shader if requested
    if (shader_path) |sp| {
        if (initPostShader(allocator, sp)) {
            g_post_enabled = true;
            g_start_time = std.time.milliTimestamp();
        } else {
            std.debug.print("Warning: custom shader failed to load, continuing without it\n", .{});
        }
    }
    defer {
        if (g_post_enabled) {
            gl.DeleteProgram.?(g_post_program);
            gl.DeleteVertexArrays.?(1, &g_post_vao);
            gl.DeleteBuffers.?(1, &g_post_vbo);
            if (g_post_fbo != 0) {
                gl.DeleteFramebuffers.?(1, &g_post_fbo);
                gl.DeleteTextures.?(1, &g_post_texture);
            }
        }
        // Clean up instanced rendering resources
        if (bg_shader != 0) gl.DeleteProgram.?(bg_shader);
        if (fg_shader != 0) gl.DeleteProgram.?(fg_shader);
        if (color_fg_shader != 0) gl.DeleteProgram.?(color_fg_shader);
        if (bg_vao != 0) gl.DeleteVertexArrays.?(1, &bg_vao);
        if (fg_vao != 0) gl.DeleteVertexArrays.?(1, &fg_vao);
        if (color_fg_vao != 0) gl.DeleteVertexArrays.?(1, &color_fg_vao);
        if (bg_instance_vbo != 0) gl.DeleteBuffers.?(1, &bg_instance_vbo);
        if (fg_instance_vbo != 0) gl.DeleteBuffers.?(1, &fg_instance_vbo);
        if (color_fg_instance_vbo != 0) gl.DeleteBuffers.?(1, &color_fg_instance_vbo);
        if (quad_vbo != 0) gl.DeleteBuffers.?(1, &quad_vbo);
    }

    // Ghostty approach: calculate grid size from ACTUAL window size.
    // This ensures the terminal is created with dimensions that match
    // what setScreenSize will compute, avoiding any resize on startup.
    //
    // Padding breakdown for a SINGLE FULL-WINDOW split:
    // - Render loop: content_w = fb_width - 20 (symmetric padding)
    // - computeSplitLayout: adds back padding for edge splits: pw = content_w + 20 = fb_width
    // - setScreenSize: subtracts explicit_padding: avail = pw - 32 (L=10, R=22)
    // - So total subtracted from fb_width: 32
    //
    // For height:
    // - Render loop: content_h = fb_height - top_padding - padding = fb_height - 44 - 10 = fb_height - 54
    //   (where top_padding = padding + titlebar = 10 + 34 = 44)
    // - computeSplitLayout: no edge extension for top/bottom, so ph = content_h
    // - setScreenSize: subtracts explicit_padding: avail = ph - 20 (T=10, B=10)
    // - So total subtracted from fb_height: 54 + 20 = 74
    //   Wait, let me recalculate...
    //   Actually: content_h = fb_height - (10+34) - 10 = fb_height - 54
    //   Then setScreenSize: avail_h = content_h - 20 = fb_height - 74
    //
    // Actually there might be edge extension for top/bottom too. Let me just match exactly:
    // For a full-window single split (at all edges):
    //   pw = fb_width (after adding back padding for left+right edges)
    //   ph = content_h = fb_height - top_padding - padding = fb_height - 44 - 10 = fb_height - 54
    //   Wait, is there edge extension for y too?
    //
    // Looking at the code: only left/right edges get extension, not top/bottom.
    // So:
    //   setScreenSize(pw=fb_width, ph=fb_height-54, explicit_padding)
    //   avail_w = fb_width - 10 - 22 = fb_width - 32
    //   avail_h = (fb_height - 54) - 10 - 10 = fb_height - 74
    const titlebar_height: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
    const explicit_left: f32 = @floatFromInt(DEFAULT_PADDING);
    const explicit_right: f32 = @as(f32, @floatFromInt(DEFAULT_PADDING)) + SCROLLBAR_WIDTH;
    const explicit_top: f32 = @floatFromInt(DEFAULT_PADDING);
    const explicit_bottom: f32 = @floatFromInt(DEFAULT_PADDING);
    const render_padding: f32 = 10;
    
    // For width: pw = fb_width, then subtract explicit_padding
    const total_width_padding = explicit_left + explicit_right; // 32
    // For height: ph = fb_height - (render_padding + titlebar) - render_padding, then subtract explicit_padding
    const total_height_padding = (render_padding + titlebar_height) + render_padding + explicit_top + explicit_bottom; // 44 + 10 + 20 = 74

    // If config specifies window-width/window-height, resize window to fit that grid.
    // term_cols/term_rows were set from config at init.
    if (term_cols > 0 and term_rows > 0) {
        // Calculate window size needed for desired grid
        const desired_grid_width = font.cell_width * @as(f32, @floatFromInt(term_cols));
        const desired_grid_height = font.cell_height * @as(f32, @floatFromInt(term_rows));
        
        // Work backwards: fb_width = grid_width + total_width_padding
        //                 fb_height = grid_height + total_height_padding
        const target_fb_width: i32 = @intFromFloat(desired_grid_width + total_width_padding);
        const target_fb_height: i32 = @intFromFloat(desired_grid_height + total_height_padding);
        
        win32_window.setSize(target_fb_width, target_fb_height);
    }

    // Get actual window client size (after potential resize)
    const init_fb = win32_window.getFramebufferSize();
    const actual_width: f32 = @floatFromInt(init_fb.width);
    const actual_height: f32 = @floatFromInt(init_fb.height);
    
    // Calculate grid that fits in this window
    const avail_width = actual_width - total_width_padding;
    const avail_height = actual_height - total_height_padding;
    
    const computed_cols: u16 = @intFromFloat(@max(1, avail_width / font.cell_width));
    const computed_rows: u16 = @intFromFloat(@max(1, avail_height / font.cell_height));
    
    // Update term_cols/term_rows to match what the window can actually display
    term_cols = computed_cols;
    term_rows = computed_rows;
    
    // Now spawn the initial tab with the correct dimensions.
    // No resize will be needed because term_cols/term_rows match
    // what setScreenSize will compute from the window size.
    {
        const initial_cwd: ?[*:0]const u16 = if (g_initial_cwd_len > 0)
            @ptrCast(&g_initial_cwd_buf)
        else
            null;
        g_initial_cwd_len = 0; // Clear after use
        if (!spawnTabWithCwd(allocator, initial_cwd)) {
            std.debug.print("Failed to spawn initial tab\n", .{});
            return error.SpawnFailed;
        }
    }

    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    // Register resize callback so newly exposed pixels get filled with the
    // terminal background during live resize (Win32 modal resize loop blocks
    // our main loop, so we must render from inside WM_SIZE).
    win32_window.on_resize = &onWin32Resize;

    std.debug.print("Ready! Cell size: {d:.1}x{d:.1}\n", .{ font.cell_width, font.cell_height });

    // Ensure config directory + file exist so the watcher can observe from startup
    Config.ensureConfigExists(allocator);

    // Set up config file watcher (ReadDirectoryChangesW)
    var config_watcher = ConfigWatcher.init(allocator);
    if (config_watcher == null) {
        std.debug.print("Config watcher not available (config directory may not exist)\n", .{});
    }
    defer if (config_watcher) |*w| w.deinit();

    // Initialize FPS timer
    g_fps_last_time = std.time.milliTimestamp();

    // Apply fullscreen if requested (after all initialization is complete)
    std.debug.print("g_start_fullscreen = {}\n", .{g_start_fullscreen});
    if (g_start_fullscreen) {
        std.debug.print("Entering fullscreen at startup...\n", .{});
        win32_input.toggleFullscreen();
    }

    // Main loop — shared logic with backend-specific window management
    var running = true;
    while (running) {
        // Check for config file changes
        if (config_watcher) |*w| checkConfigReload(allocator, w);

        // Process pending resize (coalesced, like Ghostty)
        // We wait for RESIZE_COALESCE_MS after last resize event before applying
        if (g_pending_resize) {
            const now = std.time.milliTimestamp();
            if (now - g_last_resize_time >= RESIZE_COALESCE_MS) {
                g_pending_resize = false;

                if (g_pending_cols != term_cols or g_pending_rows != term_rows) {
                    // Mark resize in progress to prevent rendering with inconsistent state
                    g_resize_in_progress = true;
                    defer g_resize_in_progress = false;

                    term_cols = g_pending_cols;
                    term_rows = g_pending_rows;

                    // Resize ALL tabs' terminals and PTYs (lock each surface)
                    for (0..tab.g_tab_count) |ti| {
                        if (tab.g_tabs[ti]) |tb| {
                            // Resize all surfaces in this tab's split tree
                            var it = tb.tree.iterator();
                            while (it.next()) |entry| {
                                entry.surface.render_state.mutex.lock();
                                entry.surface.terminal.resize(allocator, term_cols, term_rows) catch |err| {
                                    std.debug.print("Terminal resize error (tab {}): {}\n", .{ ti, err });
                                };
                                entry.surface.render_state.mutex.unlock();
                                // PTY resize doesn't need the mutex (independent Win32 call)
                                entry.surface.pty.resize(term_cols, term_rows);
                            }
                        }
                    }

                    // Scroll active tab to bottom after resize
                    if (activeSurface()) |surface| {
                        surface.render_state.mutex.lock();
                        defer surface.render_state.mutex.unlock();
                        surface.terminal.scrollViewport(.{ .bottom = {} }) catch {};
                    }
                }
            }
        }

        // PTY reading is handled by per-surface IO threads (termio.Thread).
        // We just need to render. The IO threads set surface.dirty when
        // new data arrives.

        // Get framebuffer size and render
        const win = g_window orelse break;

        // Poll Win32 messages (fills event queues + checks WM_QUIT)
        running = win.pollEvents() and !g_should_close;

        // Sync tab count to win32 for hit-testing
        win.tab_count = tab.g_tab_count;

        // Process all queued input events (keyboard, mouse, resize)
        win32_input.processEvents(win);

        // Update focus state
        if (window_focused != win.focused) g_force_rebuild = true;
        window_focused = win.focused;

        const fb = win.getFramebufferSize();
        const fb_width: c_int = fb.width;
        const fb_height: c_int = fb.height;

        g_draw_call_count = 0;
        updateFps();

        // Sync atlas textures to GPU if modified
        if (font.g_atlas != null) font.syncAtlasTexture(&font.g_atlas, &font.g_atlas_texture, &font.g_atlas_modified);
        if (font.g_color_atlas != null) font.syncAtlasTexture(&font.g_color_atlas, &font.g_color_atlas_texture, &font.g_color_atlas_modified);
        if (font.g_icon_atlas != null) font.syncAtlasTexture(&font.g_icon_atlas, &font.g_icon_atlas_texture, &font.g_icon_atlas_modified);
        if (font.g_titlebar_atlas != null) font.syncAtlasTexture(&font.g_titlebar_atlas, &font.g_titlebar_atlas_texture, &font.g_titlebar_atlas_modified);

        // Check all tabs for pending bell notifications (set by IO thread)
        for (0..tab.g_tab_count) |ti| {
            if (tab.g_tabs[ti]) |tb| {
                // Check all surfaces in this tab's split tree for pending bells
                var it = tb.tree.iterator();
                while (it.next()) |entry| {
                    if (entry.surface.bell_pending.swap(false, .acquire)) {
                        handleBell(entry.surface, win, ti == tab.g_active_tab);
                    }
                }
            }
        }

        // Render padding constants - used for content area and titlebar positioning
        const padding: f32 = 10;
        const titlebar_offset: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
        const top_padding: f32 = padding + titlebar_offset;

        if (activeTab()) |active_tab| {
            // Compute split layout for the active tab
            const content_x: i32 = @intFromFloat(padding);
            const content_y: i32 = @intFromFloat(top_padding);
            const content_w: i32 = @intFromFloat(@as(f32, @floatFromInt(fb_width)) - padding * 2);
            const content_h: i32 = @intFromFloat(@as(f32, @floatFromInt(fb_height)) - top_padding - padding);
            const split_count = computeSplitLayout(active_tab, content_x, content_y, content_w, content_h, font.cell_width, font.cell_height);

            // Debug: print split count on first few frames
            // GL rendering
            if (g_post_enabled) {
                // Post-processing path: only render focused surface for now
                if (activeSurface()) |surface| {
                    var needs_rebuild: bool = false;
                    const rend = &surface.surface_renderer;
                    {
                        surface.render_state.mutex.lock();
                        defer surface.render_state.mutex.unlock();
                        updateCursorBlinkForRenderer(rend);
                        cell_renderer.g_current_render_surface = surface;
                        rend.is_focused = true; // Single surface is always focused
                        needs_rebuild = cell_renderer.updateTerminalCells(rend, &surface.terminal);
                    }
                    if (needs_rebuild) cell_renderer.rebuildCells(rend);
                    renderFrameWithPostFromCells(rend, fb_width, fb_height, padding);
                }
            } else if (split_count == 1) {
                // Single surface (no splits): use original simple rendering path
                // The surface padding is set by computeSplitLayout, so we use it here
                if (activeSurface()) |surface| {
                    const rend = &surface.surface_renderer;
                    var needs_rebuild: bool = false;
                    {
                        surface.render_state.mutex.lock();
                        defer surface.render_state.mutex.unlock();
                        updateCursorBlinkForRenderer(rend);
                        cell_renderer.g_current_render_surface = surface;
                        rend.is_focused = true; // Single surface is always focused
                        needs_rebuild = cell_renderer.updateTerminalCells(rend, &surface.terminal);
                    }
                    if (needs_rebuild) cell_renderer.rebuildCells(rend);

                    gl.Viewport.?(0, 0, fb_width, fb_height);
                    setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                    gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

                    // Use surface's computed padding (includes titlebar offset from content_y)
                    const pad = surface.getPadding();
                    const pad_top = @as(f32, @floatFromInt(pad.top)) + titlebar_offset;
                    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                    cell_renderer.drawCells(rend, @floatFromInt(fb_height), @floatFromInt(pad.left), pad_top);
                    renderScrollbar(@floatFromInt(fb_width), @floatFromInt(fb_height), pad_top);

                    // Render resize overlay centered in content area (offset for titlebar)
                    renderResizeOverlayWithOffset(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                }
            } else {
                // Multiple splits: render with scissor/viewport per surface
                gl.Viewport.?(0, 0, fb_width, fb_height);
                setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

                titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);

                // Render each split surface directly to screen using viewport
                if (split_count > 0) {
                    for (0..split_count) |i| {
                        const rect = g_split_rects[i];
                        const is_focused = (rect.handle == active_tab.focused);
                        const rend = &rect.surface.surface_renderer;

                        // Set viewport to this split's region
                        // OpenGL viewport: (x, y, width, height) where y is from bottom
                        const viewport_y = fb_height - rect.y - rect.height;
                        gl.Viewport.?(rect.x, viewport_y, rect.width, rect.height);
                        
                        // Set projection for this viewport size
                        setProjection(@floatFromInt(rect.width), @floatFromInt(rect.height));

                        // Update cells for this surface
                        {
                            rect.surface.render_state.mutex.lock();
                            defer rect.surface.render_state.mutex.unlock();
                            if (is_focused) updateCursorBlinkForRenderer(rend);
                            rend.force_rebuild = true;
                            cell_renderer.g_current_render_surface = rect.surface;
                            _ = cell_renderer.updateTerminalCellsForSurface(rend, &rect.surface.terminal, is_focused);
                        }
                        cell_renderer.rebuildCells(rend);

                        // Draw cells using the surface's computed padding
                        const pad = rect.surface.getPadding();
                        cell_renderer.drawCells(rend, @floatFromInt(rect.height), @floatFromInt(pad.left), @floatFromInt(pad.top));

                        // Render scrollbar for this surface within its viewport
                        renderScrollbarForSurface(rect.surface, @floatFromInt(rect.width), @floatFromInt(rect.height), @floatFromInt(pad.top));

                        // Draw unfocused overlay if not focused
                        if (!is_focused) {
                            renderUnfocusedOverlaySimple(@floatFromInt(rect.width), @floatFromInt(rect.height));
                        }

                        // Render resize overlay:
                        // - During divider dragging or timed overlay (equalize): show on ALL splits
                        // - Otherwise: show only on focused split (for window resize)
                        const show_timed_overlay = std.time.milliTimestamp() < g_split_resize_overlay_until;
                        if (g_divider_dragging or show_timed_overlay) {
                            renderResizeOverlayForSurface(rect.surface, @floatFromInt(rect.width), @floatFromInt(rect.height));
                        } else if (is_focused) {
                            renderResizeOverlay(@floatFromInt(rect.width), @floatFromInt(rect.height));
                        }
                    }

                    // Restore full viewport for dividers
                    gl.Viewport.?(0, 0, fb_width, fb_height);
                    setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));

                    // Draw split dividers
                    renderSplitDividers(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
                }
            }
        } else if (!g_post_enabled) {
            gl.Viewport.?(0, 0, fb_width, fb_height);
            setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
            gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
            gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
            titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        }

        renderDebugOverlay(@floatFromInt(fb_width));

        win.swapBuffers();
    }

    // Save window position for next session
    if (g_window) |w| {
        var rect: win32_backend.RECT = undefined;
        if (win32_backend.GetWindowRect(w.hwnd, &rect) != 0) {
            const is_maximized = win32_backend.IsZoomed(w.hwnd) != 0;
            if (!is_maximized and !w.is_fullscreen) {
                saveWindowState(allocator, .{ .x = rect.left, .y = rect.top });
            } else {
                // Save the last known windowed position before maximize/fullscreen
                saveWindowState(allocator, .{ .x = g_windowed_x, .y = g_windowed_y });
            }
        }
    }

    // Tab cleanup is handled by AppWindow.deinit()
}
