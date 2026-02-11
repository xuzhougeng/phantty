//! AppWindow — per-window state and rendering.
//!
//! This module contains all the terminal rendering, input handling, and
//! per-window state. Currently uses module-level globals for state, which
//! will be converted to struct fields in a future refactoring step.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const freetype = @import("freetype");
const directwrite = @import("directwrite.zig");
const Config = @import("config.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("split_tree.zig");
const renderer = @import("renderer.zig");
const win32_backend = @import("apprt/win32.zig");
const App = @import("App.zig");
const Renderer = @import("Renderer.zig");
pub const tab = @import("appwindow/tab.zig");
pub const font = @import("font/manager.zig");
pub const cell_renderer = @import("renderer/cell_renderer.zig");
pub const titlebar = @import("renderer/titlebar.zig");
pub const input = @import("input.zig");
pub const overlays = @import("renderer/overlays.zig");
pub const post_process = @import("renderer/post_process.zig");
pub const gl_init = @import("renderer/gl_init.zig");
pub const split_layout = @import("appwindow/split_layout.zig");
pub const wsl_paths = @import("apprt/wsl_paths.zig");
pub const window_state = @import("apprt/window_state.zig");
pub const fbo = @import("renderer/fbo.zig");

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
    overlays.g_debug_fps = app.debug_fps;
    overlays.g_debug_draw_calls = app.debug_draw_calls;

    // Split config
    overlays.g_unfocused_split_opacity = app.unfocused_split_opacity;
    g_focus_follows_mouse = app.focus_follows_mouse;
    overlays.g_split_divider_color = app.split_divider_color;

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
pub threadlocal var g_app: ?*App = null;

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

// WSL path conversion — see appwindow/wsl_paths.zig
pub const unixPathToWindows = wsl_paths.unixPathToWindows;

// Global pointers for callbacks
pub threadlocal var g_window: ?*win32_backend.Window = null;
pub threadlocal var g_allocator: ?std.mem.Allocator = null;

// Selection is defined in Surface.zig
const Selection = Surface.Selection;

pub threadlocal var g_should_close: bool = false; // Set by Ctrl+W with 1 tab

// Tab model — see appwindow/tab.zig
const TabState = tab.TabState;

// Split layout — see appwindow/split_layout.zig
pub const SplitRect = split_layout.SplitRect;
pub const DividerHit = split_layout.DividerHit;
pub const DEFAULT_PADDING = split_layout.DEFAULT_PADDING;
pub const surfaceAtPoint = split_layout.surfaceAtPoint;
pub const hitTestDivider = split_layout.hitTestDivider;
const computeSplitLayout = split_layout.computeSplitLayout;

pub const MAX_TABS = tab.MAX_TABS;

// ============================================================================
// Tab/split operation wrappers — delegate to tab module, handle UI side effects
// ============================================================================

pub fn activeTab() ?*TabState {
    return tab.activeTab();
}

pub fn activeSurface() ?*Surface {
    return tab.activeSurface();
}

pub fn activeSelection() *Selection {
    return tab.activeSelection();
}

pub fn isActiveTabTerminal() bool {
    return tab.isActiveTabTerminal();
}

/// Clear UI state after tab creation or switch.
fn clearUiStateOnTabChange() void {
    input.g_selecting = false;
    input.g_divider_dragging = false;
    input.g_divider_drag_handle = null;
    input.g_divider_drag_layout = null;
    overlays.g_resize_overlay_visible = false;
    overlays.g_resize_overlay_opacity = 0;
    overlays.g_resize_overlay_suppress_until = std.time.milliTimestamp() + 100;
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

pub fn spawnTab(allocator: std.mem.Allocator) bool {
    var cwd_buf: [260]u16 = undefined;
    const cwd = getActiveCwd(&cwd_buf);
    return spawnTabWithCwd(allocator, cwd);
}

pub fn closeTab(idx: usize) void {
    const allocator = g_allocator orelse return;
    tab.closeTab(idx, allocator);
    input.g_selecting = false;
    g_force_rebuild = true;
    g_cells_valid = false;
}

pub fn switchTab(idx: usize) void {
    tab.switchTab(idx);
    clearUiStateOnTabChange();
}

pub fn splitFocused(direction: SplitTree.Split.Direction) void {
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
        overlays.g_resize_active = false;
        g_force_rebuild = true;
        g_cells_valid = false;
    }
}

pub fn closeFocusedSplit() void {
    const allocator = g_allocator orelse return;
    switch (tab.closeFocusedSplit(allocator)) {
        .closed_split => {
            g_force_rebuild = true;
            g_cells_valid = false;
        },
        .closed_tab => {
            input.g_selecting = false;
            g_force_rebuild = true;
            g_cells_valid = false;
        },
        .close_window => {
            g_should_close = true;
        },
        .no_op => {},
    }
}

pub fn gotoSplit(direction: SplitTree.Goto) void {
    const allocator = g_allocator orelse return;
    if (tab.gotoSplit(allocator, direction)) {
        g_force_rebuild = true;
        g_cells_valid = false;
    }
}

pub fn equalizeSplits() void {
    const allocator = g_allocator orelse return;
    if (tab.equalizeSplits(allocator)) {
        overlays.g_split_resize_overlay_until = std.time.milliTimestamp() + overlays.RESIZE_OVERLAY_DURATION_MS;
        g_force_rebuild = true;
        g_cells_valid = false;
    }
}


// Embed the font
// Embedded fallback font (JetBrains Mono, like Ghostty)
const embedded = @import("font/embedded.zig");

// Terminal dimensions (initial, will be updated on resize)
// Defaults match Ghostty's default of 0 (auto-size), but we set
// reasonable defaults since we don't auto-detect screen size.
pub threadlocal var term_cols: u16 = 80;
pub threadlocal var term_rows: u16 = 24;
// OpenGL context from glad
pub threadlocal var gl: c.GladGLContext = undefined;

// Dirty tracking — skip rebuildCells when nothing changed
pub threadlocal var g_cells_valid: bool = false;
pub threadlocal var g_force_rebuild: bool = true;

pub threadlocal var window_focused: bool = true; // Track window focus state

// Window state persistence — see appwindow/window_state.zig
const loadWindowState = window_state.loadWindowState;
const saveWindowState = window_state.saveWindowState;

// Pending resize state (resize is deferred to main loop to avoid PageList integrity issues)
// Ghostty coalesces resize events with a 25ms timer to batch rapid resizes
pub threadlocal var g_pending_resize: bool = false;
pub threadlocal var g_pending_cols: u16 = 0;
pub threadlocal var g_pending_rows: u16 = 0;
pub threadlocal var g_last_resize_time: i64 = 0;
threadlocal var g_resize_in_progress: bool = false; // Prevent rendering during resize
const RESIZE_COALESCE_MS: i64 = 25; // Same as Ghostty

pub threadlocal var g_cursor_style: CursorStyle = .block; // Default cursor style
pub threadlocal var g_cursor_blink: bool = true; // Whether cursor should blink (default: true like Ghostty)
pub threadlocal var g_cursor_blink_visible: bool = true; // Current blink state (toggled by timer)
pub threadlocal var g_last_blink_time: i64 = 0; // Timestamp of last blink toggle
const CURSOR_BLINK_INTERVAL_MS: i64 = 600; // Blink interval in ms (same as Ghostty)

const ConfigWatcher = @import("config_watcher.zig");

// GL init, shader sources, render helpers — see appwindow/gl_init.zig

/// Focus follows mouse - when true, moving mouse into a split pane focuses it
pub threadlocal var g_focus_follows_mouse: bool = false;

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
    const padding_right: f32 = @as(f32, @floatFromInt(DEFAULT_PADDING)) + overlays.SCROLLBAR_WIDTH;
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
        overlays.resizeOverlayShow(new_cols, new_rows);

        for (0..tab.g_tab_count) |ti| {
            if (tab.g_tabs[ti]) |active_t| {
                // Resize all surfaces in this tab's split tree
                var it = active_t.tree.iterator();
                while (it.next()) |entry| {
                    entry.surface.render_state.mutex.lock();
                    entry.surface.terminal.resize(allocator, term_cols, term_rows) catch {};
                    entry.surface.render_state.mutex.unlock();
                    entry.surface.pty.setSize(.{ .ws_col = term_cols, .ws_row = term_rows }) catch {};
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
        gl_init.setProjection(@floatFromInt(width), @floatFromInt(height));
        gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
        gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
        titlebar.renderTitlebar(@floatFromInt(width), @floatFromInt(height), tb);
        cell_renderer.drawCells(rend, @floatFromInt(height), padding_left, padding_top + tb);
        overlays.renderScrollbar(@floatFromInt(width), @floatFromInt(height), padding_top + tb);
        overlays.renderResizeOverlay(@floatFromInt(width), @floatFromInt(height));
        overlays.renderDebugOverlay(@floatFromInt(width));
    } else {
        gl.Viewport.?(0, 0, width, height);
        gl_init.setProjection(@floatFromInt(width), @floatFromInt(height));
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
    overlays.g_debug_fps = cfg.@"phantty-debug-fps";
    overlays.g_debug_draw_calls = cfg.@"phantty-debug-draw-calls";

    // --- Split config ---
    overlays.g_unfocused_split_opacity = cfg.@"unfocused-split-opacity";
    g_focus_follows_mouse = cfg.@"focus-follows-mouse";
    overlays.g_split_divider_color = cfg.@"split-divider-color";

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
                    entry.surface.pty.setSize(.{ .ws_col = term_cols, .ws_row = term_rows }) catch {};
                }
            }
        }
    } else {
        std.debug.print("Reload: failed to load font, keeping current font\n", .{});
    }

    std.debug.print("Config reloaded successfully\n", .{});
}

/// Reset cursor blink to visible state (call on keypress like Ghostty)
pub fn resetCursorBlink() void {
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

    if (!gl_init.initShaders()) {
        std.debug.print("Failed to initialize shaders\n", .{});
        return error.ShaderInitFailed;
    }
    gl_init.initBuffers();
    gl_init.initInstancedBuffers();
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
    gl_init.initSolidTexture();

    // Initialize custom post-processing shader if requested
    post_process.init(allocator, shader_path);
    defer {
        post_process.deinit();
        gl_init.deinitInstancedResources();
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
    const explicit_right: f32 = @as(f32, @floatFromInt(DEFAULT_PADDING)) + overlays.SCROLLBAR_WIDTH;
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
    overlays.g_fps_last_time = std.time.milliTimestamp();

    // Apply fullscreen if requested (after all initialization is complete)
    std.debug.print("g_start_fullscreen = {}\n", .{g_start_fullscreen});
    if (g_start_fullscreen) {
        std.debug.print("Entering fullscreen at startup...\n", .{});
        input.toggleFullscreen();
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
                                entry.surface.pty.setSize(.{ .ws_col = term_cols, .ws_row = term_rows }) catch {};
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
        input.processEvents(win);

        // Update focus state
        if (window_focused != win.focused) g_force_rebuild = true;
        window_focused = win.focused;

        const fb = win.getFramebufferSize();
        const fb_width: c_int = fb.width;
        const fb_height: c_int = fb.height;

        gl_init.g_draw_call_count = 0;
        overlays.updateFps();

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
            if (post_process.g_post_enabled) {
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
                    post_process.renderFrameWithPostFromCells(rend, fb_width, fb_height, padding);
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
                    gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                    gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

                    // Use surface's computed padding (includes titlebar offset from content_y)
                    const pad = surface.getPadding();
                    const pad_top = @as(f32, @floatFromInt(pad.top)) + titlebar_offset;
                    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                    cell_renderer.drawCells(rend, @floatFromInt(fb_height), @floatFromInt(pad.left), pad_top);
                    overlays.renderScrollbar(@floatFromInt(fb_width), @floatFromInt(fb_height), pad_top);

                    // Render resize overlay centered in content area (offset for titlebar)
                    overlays.renderResizeOverlayWithOffset(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                }
            } else {
                // Multiple splits: render with scissor/viewport per surface
                gl.Viewport.?(0, 0, fb_width, fb_height);
                gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

                titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);

                // Render each split surface directly to screen using viewport
                if (split_count > 0) {
                    for (0..split_count) |i| {
                        const rect = split_layout.g_split_rects[i];
                        const is_focused = (rect.handle == active_tab.focused);
                        const rend = &rect.surface.surface_renderer;

                        // Set viewport to this split's region
                        // OpenGL viewport: (x, y, width, height) where y is from bottom
                        const viewport_y = fb_height - rect.y - rect.height;
                        gl.Viewport.?(rect.x, viewport_y, rect.width, rect.height);
                        
                        // Set projection for this viewport size
                        gl_init.setProjection(@floatFromInt(rect.width), @floatFromInt(rect.height));

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
                        overlays.renderScrollbarForSurface(rect.surface, @floatFromInt(rect.width), @floatFromInt(rect.height), @floatFromInt(pad.top));

                        // Draw unfocused overlay if not focused
                        if (!is_focused) {
                            overlays.renderUnfocusedOverlaySimple(@floatFromInt(rect.width), @floatFromInt(rect.height));
                        }

                        // Render resize overlay:
                        // - During divider dragging or timed overlay (equalize): show on ALL splits
                        // - Otherwise: show only on focused split (for window resize)
                        const show_timed_overlay = std.time.milliTimestamp() < overlays.g_split_resize_overlay_until;
                        if (input.g_divider_dragging or show_timed_overlay) {
                            overlays.renderResizeOverlayForSurface(rect.surface, @floatFromInt(rect.width), @floatFromInt(rect.height));
                        } else if (is_focused) {
                            overlays.renderResizeOverlay(@floatFromInt(rect.width), @floatFromInt(rect.height));
                        }
                    }

                    // Restore full viewport for dividers
                    gl.Viewport.?(0, 0, fb_width, fb_height);
                    gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));

                    // Draw split dividers
                    overlays.renderSplitDividers(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
                }
            }
        } else if (!post_process.g_post_enabled) {
            gl.Viewport.?(0, 0, fb_width, fb_height);
            gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
            gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
            gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
            titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        }

        overlays.renderDebugOverlay(@floatFromInt(fb_width));

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
                saveWindowState(allocator, .{ .x = window_state.g_windowed_x, .y = window_state.g_windowed_y });
            }
        }
    }

    // Tab cleanup is handled by AppWindow.deinit()
}
