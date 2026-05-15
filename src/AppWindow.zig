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
const build_options = @import("build_options");
const Surface = @import("Surface.zig");
const SplitTree = @import("split_tree.zig");
const renderer = @import("renderer.zig");
const win32_backend = @import("apprt/win32.zig");
const App = @import("App.zig");
const Renderer = @import("renderer/Renderer.zig");
const remote = @import("remote_client.zig");
const remote_snapshot = @import("remote_snapshot.zig");
const memory_debug = @import("memory_debug.zig");
const agent_detector = @import("agent_detector.zig");
const agent_history = @import("agent_history.zig");
pub const ai_chat = @import("ai_chat.zig");
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
pub const background_image = @import("renderer/background_image.zig");
pub const file_explorer = @import("file_explorer.zig");
pub const file_explorer_renderer = @import("renderer/file_explorer_renderer.zig");
pub const markdown_preview_panel = @import("markdown_preview_panel.zig");
pub const markdown_preview_renderer = @import("renderer/markdown_preview_renderer.zig");
pub const browser_panel = if (build_options.webview)
    @import("browser_panel.zig")
else
    @import("browser_panel_stub.zig");
pub const ai_chat_renderer = @import("renderer/ai_chat_renderer.zig");
const log = std.log.scoped(.app_window);

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
hwnd_bits: std.atomic.Value(usize) = .init(0),

/// Initialize an AppWindow with the given App.
pub fn init(allocator: std.mem.Allocator, app: *App) !AppWindow {
    // Store allocator globally for now (used by many functions)
    g_allocator = allocator;

    // Store app pointer globally for requestNewWindow
    g_app = app;

    try ensureGlobalAgentHistoryStore(allocator);
    tab.g_ai_history_change_hook = saveAiHistoryChangeEvent;

    // Apply config from App to globals
    g_theme = app.theme;
    g_force_rebuild = true;
    g_cursor_style = app.cursor_style;
    g_cursor_blink = app.cursor_blink;
    overlays.g_debug_fps = app.debug_fps;
    overlays.g_debug_draw_calls = app.debug_draw_calls;
    g_debug_memory = app.debug_memory;

    // Split config
    overlays.g_unfocused_split_opacity = app.unfocused_split_opacity;
    g_focus_follows_mouse = app.focus_follows_mouse;
    g_copy_on_select = app.copy_on_select;
    g_right_click_action = app.right_click_action;
    g_ssh_legacy_algorithms = app.ssh_legacy_algorithms;
    tab.g_ssh_legacy_algorithms = app.ssh_legacy_algorithms;
    overlays.g_split_divider_color = app.split_divider_color;

    // Apply window size from config
    term_cols = app.initial_cols;
    term_rows = app.initial_rows;

    tab.g_scrollback_limit = app.scrollback_limit;
    tab.g_remote_client = app.remote_client;
    ai_chat.configureAgent(.{
        .enabled = app.ai_agent_enabled,
        .permission = app.ai_agent_permission,
        .command_timeout_ms = app.ai_agent_command_timeout_ms,
        .output_limit = app.ai_agent_output_limit,
    });
    // Copy shell command from App
    @memcpy(tab.g_shell_cmd_buf[0..app.shell_cmd_len], app.shell_cmd_buf[0..app.shell_cmd_len]);
    tab.g_shell_cmd_buf[app.shell_cmd_len] = 0;
    tab.g_shell_cmd_len = app.shell_cmd_len;

    // Store config values we need for init
    g_requested_font = app.font_family;
    font.g_cjk_font_family = app.font_family_cjk;
    font.g_fallback_font_families = app.font_family_fallback;
    g_requested_weight = app.font_weight;
    font.g_font_size = app.font_size;
    g_shader_path = app.shader_path;
    g_start_maximize = app.maximize;
    g_start_fullscreen = app.fullscreen;
    background_image.g_mode = app.background_image_mode;
    gl_init.g_bg_opacity = app.background_opacity;
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
    runMainLoop(self) catch |err| {
        std.debug.print("AppWindow run failed: {}\n", .{err});
    };
}

/// Get the Win32 HWND for this window (for cross-thread communication).
pub fn getHwnd(self: *AppWindow) ?win32_backend.HWND {
    const bits = self.hwnd_bits.load(.acquire);
    return if (bits == 0) null else @ptrFromInt(bits);
}

/// Clean up resources.
pub fn deinit(self: *AppWindow) void {
    // Persist the session to disk if restore-tabs-on-startup is enabled.
    // Only the LAST window to close performs the dump — this matches the
    // first-window-only restore behavior in run() and avoids losing the
    // tabs of other still-open windows when one window closes early.
    // (When this deinit runs, the window has already been swap-removed
    // from app.windows by the caller in App.run/windowThreadMain.)
    //
    // Errors are logged inside dumpSessionToFile and must not block shutdown.
    var is_last_window = false;
    {
        const restore_enabled = self.app.restore_tabs_on_startup;
        {
            self.app.mutex.lock();
            defer self.app.mutex.unlock();
            is_last_window = self.app.windows.items.len == 0;
        }
        if (restore_enabled and is_last_window) {
            tab.dumpSessionToFile(self.allocator);
        }
    }

    // Clean up all tabs
    for (0..tab.g_tab_count) |ti| {
        if (tab.g_tabs[ti]) |t| {
            t.deinit(self.allocator);
            self.allocator.destroy(t);
            tab.g_tabs[ti] = null;
        }
    }
    tab.g_tab_count = 0;
    tab.g_remote_client = null;
    if (is_last_window) deinitGlobalAgentHistoryStore(self.allocator);
    browser_panel.deinit();
}

// ============================================================================
// Module-level state (will be moved into AppWindow struct in future)
// ============================================================================

// App pointer for requestNewWindow
pub threadlocal var g_app: ?*App = null;
var g_agent_history_mutex: std.Thread.Mutex = .{};
pub var g_agent_history: ?*agent_history.Store = null;
var g_agent_history_dirty: bool = false;
var g_agent_history_next_flush_ms: i64 = 0;
var g_agent_history_revision: u64 = 0;
const AGENT_HISTORY_FLUSH_DEBOUNCE_MS: i64 = 350;

// Initial CWD for this window (used when spawning the first tab)
threadlocal var g_initial_cwd_buf: [260]u16 = undefined;
threadlocal var g_initial_cwd_len: usize = 0;

// Tracks whether session restore has been attempted this process. We only
// try to restore tabs from session.json once — for the first window. New
// windows spawned via Ctrl+Shift+N still get a fresh default tab.
var g_session_restore_attempted: std.atomic.Value(bool) = .init(false);

// Stored config values for deferred initialization
threadlocal var g_requested_font: []const u8 = "";
threadlocal var g_requested_weight: directwrite.DWRITE_FONT_WEIGHT = .NORMAL;
threadlocal var g_shader_path: ?[]const u8 = null;
threadlocal var g_start_maximize: bool = false;
threadlocal var g_start_fullscreen: bool = false;
threadlocal var g_debug_memory: bool = false;
threadlocal var g_debug_memory_last_ms: i64 = 0;
threadlocal var g_remote_layout_last_ms: i64 = 0;
threadlocal var g_remote_ai_sinks: [tab.MAX_TABS]RemoteAiInputSink = undefined;

// Global theme (set at startup via config)
pub threadlocal var g_theme: Theme = Theme.default();

// WSL path conversion — see appwindow/wsl_paths.zig
pub const unixPathToWindows = wsl_paths.unixPathToWindows;

// Global pointers for callbacks
pub threadlocal var g_window: ?*win32_backend.Window = null;
pub threadlocal var g_allocator: ?std.mem.Allocator = null;

// Selection is defined in Surface.zig
const Selection = Surface.Selection;

pub threadlocal var g_should_close: bool = false; // Set when the final tab closes

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

const WM_PHANTTY_AGENT_SSH_CONNECT = win32_backend.WM_APP + 0x51;
const WM_PHANTTY_AGENT_TAB_NEW = win32_backend.WM_APP + 0x52;
const WM_PHANTTY_AGENT_TAB_CLOSE = win32_backend.WM_APP + 0x53;
const WM_PHANTTY_REMOTE_AI_INPUT = win32_backend.WM_APP + 0x54;

const AgentSshConnectRequest = struct {
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    result: ?ai_chat.ToolSurface = null,
    err: ?anyerror = null,
};

const AgentTabNewRequest = struct {
    allocator: std.mem.Allocator,
    kind: []const u8,
    command: ?[]const u8,
    result: ?ai_chat.ToolSurface = null,
    err: ?anyerror = null,
};

const AgentTabCloseRequest = struct {
    allocator: std.mem.Allocator,
    tab_index: ?usize,
    surface_id: ?[]const u8,
    title: ?[]const u8,
    result: ?ai_chat.ToolClosedTab = null,
    err: ?anyerror = null,
};

const RemoteAiInputSink = struct {
    hwnd: win32_backend.HWND,
    tab_index: usize,
};

const RemoteAiInputRequest = struct {
    tab_index: usize,
    data: []u8,
};

// ============================================================================
// Tab/split operation wrappers — delegate to tab module, handle UI side effects
// ============================================================================

/// Clear the framebuffer with the theme background color, then draw the
/// background image (if any) over the cleared color. The current viewport
/// must already cover (0,0)..(fb_w,fb_h).
fn clearWithBackground(fb_w: c_int, fb_h: c_int) void {
    gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
    background_image.drawFullscreen(@floatFromInt(fb_w), @floatFromInt(fb_h));
}

fn renderAiChatFrame(fb_width: c_int, fb_height: c_int, titlebar_offset: f32, left_panels_w: f32, right_panels_w: f32) void {
    gl.Viewport.?(0, 0, fb_width, fb_height);
    gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
    clearWithBackground(fb_width, fb_height);
    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    markdown_preview_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, 0);
    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    if (activeAiChat()) |session| {
        ai_chat_renderer.render(
            session,
            @floatFromInt(fb_width),
            @floatFromInt(fb_height),
            titlebar_offset,
            left_panels_w,
            right_panels_w,
        );
    }
}

pub fn activeTab() ?*TabState {
    return tab.activeTab();
}

pub fn activeSurface() ?*Surface {
    return tab.activeSurface();
}

pub fn activeAiChat() ?*ai_chat.Session {
    return tab.activeAiChat();
}

pub fn currentTitlebarHeight() f32 {
    if (g_window) |w| return @floatFromInt(w.titlebar_height);
    return titlebar.titlebarHeight();
}

pub fn leftPanelsWidth() f32 {
    return titlebar.sidebarWidth() + file_explorer.width();
}

pub fn rightPanelsWidth() f32 {
    return markdown_preview_panel.width() + browser_panel.width();
}

pub fn rightPanelsWidthForWindow(window_width: i32) f32 {
    const preview_w = markdown_preview_panel.width();
    const browser_w = browser_panel.panelWidthForWindow(window_width, leftPanelsWidth(), preview_w);
    return preview_w + browser_w;
}

pub fn browserPanelRightOffset() f32 {
    return markdown_preview_panel.width();
}

fn syncWindowTitlebarHeight(win: *win32_backend.Window) f32 {
    const next: i32 = @intFromFloat(titlebar.titlebarHeight());
    win.titlebar_height = next;
    return @floatFromInt(next);
}

pub fn activeSelection() *Selection {
    return tab.activeSelection();
}

pub fn isActiveTabTerminal() bool {
    return tab.isActiveTabTerminal();
}

/// Clear UI state after tab creation or switch.
fn syncActiveSurfaceCaches() void {
    split_layout.invalidateCachedRects();
    cell_renderer.g_current_render_surface = activeSurface();
}

pub fn handleActiveSurfaceChangeWithinTab() void {
    syncVisibleFileExplorerForActiveTab();
    syncActiveSurfaceCaches();
    g_force_rebuild = true;
    g_cells_valid = false;
}

fn clearUiStateOnTabChange() void {
    input.g_selecting = false;
    input.g_sidebar_resize_hover = false;
    input.g_sidebar_resize_dragging = false;
    input.g_explorer_resize_hover = false;
    input.g_explorer_resize_dragging = false;
    input.g_markdown_preview_resize_hover = false;
    input.g_markdown_preview_resize_dragging = false;
    input.g_browser_resize_hover = false;
    input.g_browser_resize_dragging = false;
    browser_panel.blurUrlBar();
    input.g_divider_dragging = false;
    input.g_divider_drag_handle = null;
    input.g_divider_drag_layout = null;
    overlays.g_resize_overlay_visible = false;
    overlays.g_resize_overlay_opacity = 0;
    overlays.g_resize_overlay_suppress_until = std.time.milliTimestamp() + 100;
    syncVisibleFileExplorerForActiveTab();
    syncActiveSurfaceCaches();
    requestImmediateLayoutResize();
    g_force_rebuild = true;
    g_cells_valid = false;
}

fn isUnsupportedShellCwd(path: []const u16) bool {
    if (path.len < 2) return false;
    if (path[0] != '\\' or path[1] != '\\') return false;
    return !(path.len >= 4 and path[2] == '?' and path[3] == '\\');
}

fn utf8PathToCwdPtr(path: []const u8, cwd_buf: *[260]u16) ?[*:0]const u16 {
    const len = std.unicode.utf8ToUtf16Le(cwd_buf[0 .. cwd_buf.len - 1], path) catch return null;
    if (isUnsupportedShellCwd(cwd_buf[0..len])) return null;
    cwd_buf[len] = 0;
    return @ptrCast(cwd_buf);
}

/// Convert the active surface's CWD from Unix to Windows path.
fn getActiveCwd(cwd_buf: *[260]u16) ?[*:0]const u16 {
    if (tab.activeSurface()) |surface| {
        if (surface.getCwd()) |unix_path| {
            if (unixPathToWindows(unix_path, cwd_buf)) |len| {
                if (isUnsupportedShellCwd(cwd_buf[0..len])) return null;
                cwd_buf[len] = 0;
                return @ptrCast(cwd_buf);
            }
        }
        if (surface.launch_kind == .windows) {
            if (surface.getInitialCwd()) |initial_cwd| {
                return utf8PathToCwdPtr(initial_cwd, cwd_buf);
            }
        }
    }
    return null;
}

fn ensureGlobalAgentHistoryStore(allocator: std.mem.Allocator) !void {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (g_agent_history != null) return;

    const store = try allocator.create(agent_history.Store);
    errdefer allocator.destroy(store);
    store.* = try agent_history.loadDefault(allocator);
    g_agent_history = store;
    g_agent_history_dirty = false;
    g_agent_history_next_flush_ms = 0;
    g_agent_history_revision = 0;
}

fn deinitGlobalAgentHistoryStore(allocator: std.mem.Allocator) void {
    flushAgentHistoryStoreIfDirty(true);

    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (g_agent_history) |store| {
        store.deinit();
        allocator.destroy(store);
        g_agent_history = null;
    }
    g_agent_history_dirty = false;
    g_agent_history_next_flush_ms = 0;
    g_agent_history_revision = 0;
}

fn saveAiHistoryChangeEvent(event: ai_chat.HistoryChangeEvent) void {
    var owned_event = event;
    defer owned_event.deinit();

    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    const store = g_agent_history orelse return;
    store.upsertRecord(owned_event.record) catch |err| {
        log.warn("failed to clone AI history update for session {s}: {}", .{ owned_event.record.session_id, err });
        return;
    };
    if (!g_agent_history_dirty) {
        g_agent_history_dirty = true;
        g_agent_history_next_flush_ms = std.time.milliTimestamp() + AGENT_HISTORY_FLUSH_DEBOUNCE_MS;
    }
    g_agent_history_revision +%= 1;
}

fn flushAgentHistoryStoreIfDirty(force: bool) void {
    const now = std.time.milliTimestamp();
    var json: ?[]u8 = null;
    var path: ?[]const u8 = null;
    var snapshot_allocator: ?std.mem.Allocator = null;

    g_agent_history_mutex.lock();
    if (!g_agent_history_dirty) {
        g_agent_history_mutex.unlock();
        return;
    }
    if (!force and now < g_agent_history_next_flush_ms) {
        g_agent_history_mutex.unlock();
        return;
    }

    const store = g_agent_history orelse {
        g_agent_history_mutex.unlock();
        return;
    };
    snapshot_allocator = store.allocator;
    json = store.toJsonString(store.allocator) catch |err| {
        log.warn("failed to snapshot agent history store for flush: {}", .{err});
        g_agent_history_next_flush_ms = now + AGENT_HISTORY_FLUSH_DEBOUNCE_MS;
        g_agent_history_mutex.unlock();
        return;
    };
    path = agent_history.defaultPath(store.allocator) catch |err| {
        log.warn("failed to resolve agent history path for flush: {}", .{err});
        store.allocator.free(json.?);
        g_agent_history_next_flush_ms = now + AGENT_HISTORY_FLUSH_DEBOUNCE_MS;
        g_agent_history_mutex.unlock();
        return;
    };
    g_agent_history_dirty = false;
    g_agent_history_next_flush_ms = 0;
    g_agent_history_mutex.unlock();

    agent_history.saveJsonToPath(path.?, json.?) catch |err| {
        log.warn("failed to flush agent history store: {}", .{err});
        g_agent_history_mutex.lock();
        if (!g_agent_history_dirty) {
            g_agent_history_dirty = true;
            g_agent_history_next_flush_ms = std.time.milliTimestamp() + AGENT_HISTORY_FLUSH_DEBOUNCE_MS;
        }
        snapshot_allocator.?.free(path.?);
        snapshot_allocator.?.free(json.?);
        g_agent_history_mutex.unlock();
        return;
    };

    g_agent_history_mutex.lock();
    snapshot_allocator.?.free(path.?);
    snapshot_allocator.?.free(json.?);
    g_agent_history_mutex.unlock();
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

pub fn spawnTabWithCommandUtf8(command: []const u8) bool {
    return spawnTabWithCommandUtf8ReturningSurface(command) != null;
}

pub fn spawnTabWithCommandUtf8ReturningSurface(command: []const u8) ?*Surface {
    const allocator = g_allocator orelse return null;
    const command_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, command) catch return null;
    defer allocator.free(command_w);

    var cwd_buf: [260]u16 = undefined;
    const cwd = getActiveCwd(&cwd_buf);
    if (!tab.spawnTabWithCommandAndCwd(allocator, term_cols, term_rows, command_w, g_cursor_style, g_cursor_blink, cwd)) return null;
    clearUiStateOnTabChange();
    return activeSurface();
}

pub fn spawnAiChatTab(
    name: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    system_prompt: []const u8,
    thinking: []const u8,
    reasoning_effort: []const u8,
    stream_val: []const u8,
    agent_val: []const u8,
) bool {
    const allocator = g_allocator orelse return false;
    if (!tab.spawnAiChatTab(allocator, name, base_url, api_key, model, system_prompt, thinking, reasoning_effort, stream_val, agent_val)) return false;
    clearUiStateOnTabChange();
    return true;
}

pub fn reopenAiChatTabFromHistorySessionId(session_id: []const u8) bool {
    if (tab.switchToAiTabBySessionId(session_id)) {
        clearUiStateOnTabChange();
        return true;
    }

    const allocator = g_allocator orelse return false;
    g_agent_history_mutex.lock();
    const record = if (g_agent_history) |store|
        store.cloneRecordBySessionId(allocator, session_id) catch null
    else
        null;
    g_agent_history_mutex.unlock();

    var owned_record = record orelse return false;
    defer agent_history.freeOwnedRecord(allocator, &owned_record);

    if (!tab.spawnAiChatTabFromHistoryRecord(allocator, owned_record)) return false;
    clearUiStateOnTabChange();
    return true;
}

pub const AgentHistoryRowsSnapshot = struct {
    rows: []agent_history.Row,
    revision: u64,
};

pub fn snapshotAgentHistoryRowsForCommandPalette(allocator: std.mem.Allocator) !AgentHistoryRowsSnapshot {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (g_agent_history) |store| {
        return .{
            .rows = try store.buildRows(allocator),
            .revision = g_agent_history_revision,
        };
    }

    return .{
        .rows = try allocator.alloc(agent_history.Row, 0),
        .revision = g_agent_history_revision,
    };
}

pub fn agentHistoryRevision() u64 {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();
    return g_agent_history_revision;
}

pub fn syncVisibleFileExplorerForActiveTab() void {
    if (!file_explorer.g_visible) return;

    const is_ai_tab = activeAiChat() != null;
    if (is_ai_tab) {
        file_explorer.syncPanelForTabKind(true);
        syncFileExplorerAgentHistoryRows();
        return;
    }

    syncFileExplorerToActiveTerminalSurface();
}

pub fn syncFileExplorerAgentHistoryRows() void {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();

    if (g_agent_history) |store| {
        file_explorer.syncAgentHistoryRows(store);
        return;
    }

    var empty_store = agent_history.Store.init(std.heap.page_allocator);
    defer empty_store.deinit();
    file_explorer.syncAgentHistoryRows(&empty_store);
}

fn syncFileExplorerToActiveTerminalSurface() void {
    const surface = activeSurface() orelse {
        file_explorer.syncPanelForTabKind(false);
        return;
    };

    switch (surface.launch_kind) {
        .ssh => {
            if (surface.ssh_connection) |conn| {
                file_explorer.syncPanelForTerminalTarget(.{
                    .remote = .{
                        .conn = &conn,
                        .cwd = surface.getCwd() orelse "",
                    },
                });
                return;
            }
            file_explorer.syncPanelForTabKind(false);
        },
        .wsl => {
            file_explorer.syncPanelForTerminalTarget(.{ .wsl = surface.getCwd() orelse "~" });
        },
        .windows => {
            if (surface.getCwd()) |unix_path| {
                var wpath: [260]u16 = undefined;
                if (wsl_paths.unixPathToWindows(unix_path, &wpath)) |wlen| {
                    var utf8_buf: [260]u8 = undefined;
                    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wpath[0..wlen]) catch 0;
                    if (utf8_len > 0) {
                        file_explorer.syncPanelForTerminalTarget(.{ .local = utf8_buf[0..utf8_len] });
                        return;
                    }
                }
            }
            if (surface.getInitialCwd()) |initial_cwd| {
                file_explorer.syncPanelForTerminalTarget(.{ .local = initial_cwd });
                return;
            }
            file_explorer.syncPanelForTabKind(false);
        },
    }
}

pub fn closeTab(idx: usize) void {
    const allocator = g_allocator orelse return;
    tab.closeTab(idx, allocator);
    clearUiStateOnTabChange();
}

pub fn closeFocusedSplitWouldCloseWindow() bool {
    const active_tab = activeTab() orelse return false;
    if (active_tab.kind == .ai_chat) return tab.g_tab_count <= 1;
    return tab.g_tab_count <= 1 and !active_tab.tree.isSplit();
}

pub fn switchTab(idx: usize) void {
    tab.switchTab(idx);
    clearUiStateOnTabChange();
}

pub fn splitFocused(direction: SplitTree.Split.Direction) void {
    _ = splitFocusedReturningSurface(direction);
}

pub fn splitFocusedReturningSurface(direction: SplitTree.Split.Direction) ?*Surface {
    const allocator = g_allocator orelse return null;
    var cwd_buf: [260]u16 = undefined;
    const cwd = getActiveCwd(&cwd_buf);
    const surface = tab.splitFocusedReturningSurface(allocator, direction, font.cell_width, font.cell_height, g_cursor_style, g_cursor_blink, cwd) orelse return null;
    if (surface.ssh_connection) |conn| {
        if (conn.password_auth) {
            const pw = conn.password();
            if (pw.len > 0)
                overlays.scheduleSshPasswordForSurface(surface, pw);
        }
    }
    handleActiveSurfaceChangeWithinTab();
    {
        overlays.g_resize_active = false;
        requestImmediateLayoutResize();
    }
    return surface;
}

pub fn closeFocusedSplit() void {
    const allocator = g_allocator orelse return;
    switch (tab.closeFocusedSplit(allocator)) {
        .closed_split => {
            input.g_selecting = false;
            handleActiveSurfaceChangeWithinTab();
            requestImmediateLayoutResize();
        },
        .closed_tab => {
            clearUiStateOnTabChange();
        },
        .close_window => {
            split_layout.invalidateCachedRects();
            cell_renderer.g_current_render_surface = null;
            g_should_close = true;
        },
        .no_op => {},
    }
}

pub fn gotoSplit(direction: SplitTree.Goto) void {
    const allocator = g_allocator orelse return;
    if (tab.gotoSplit(allocator, direction)) {
        handleActiveSurfaceChangeWithinTab();
    }
}

pub fn equalizeSplits() void {
    const allocator = g_allocator orelse return;
    if (tab.equalizeSplits(allocator)) {
        overlays.g_split_resize_overlay_until = std.time.milliTimestamp() + overlays.RESIZE_OVERLAY_DURATION_MS;
        requestImmediateLayoutResize();
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
const RESIZE_COALESCE_MS: i64 = 25; // Same as Ghostty

// One-shot layout changes such as opening a browser panel or creating a split
// should not wait for the drag/window-resize coalescing timer.
pub threadlocal var g_layout_resize_immediate: bool = false;

pub fn requestImmediateLayoutResize() void {
    g_layout_resize_immediate = true;
}

pub fn consumeImmediateLayoutResize() bool {
    const immediate = g_layout_resize_immediate;
    g_layout_resize_immediate = false;
    return immediate;
}

pub threadlocal var g_cursor_style: CursorStyle = .block; // Default cursor style
pub threadlocal var g_cursor_blink: bool = true; // Whether cursor should blink (default: true like Ghostty)
pub threadlocal var g_cursor_blink_visible: bool = true; // Current blink state (toggled by timer)
pub threadlocal var g_last_blink_time: i64 = 0; // Timestamp of last blink toggle
const CURSOR_BLINK_INTERVAL_MS: i64 = 600; // Blink interval in ms (same as Ghostty)

const ConfigWatcher = @import("config_watcher.zig");

// GL init, shader sources, render helpers — see appwindow/gl_init.zig

/// Focus follows mouse - when true, moving mouse into a split pane focuses it
pub threadlocal var g_focus_follows_mouse: bool = false;
pub threadlocal var g_copy_on_select: bool = false;
pub threadlocal var g_right_click_action: Config.RightClickAction = .copy;
pub threadlocal var g_ssh_legacy_algorithms: bool = false;

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
    if (g_allocator == null) return;

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
    const tb = currentTitlebarHeight();
    const left_panels_w = leftPanelsWidth();
    const right_panels_w = rightPanelsWidthForWindow(width);
    const avail_w = @as(f32, @floatFromInt(width)) - left_panels_w - right_panels_w - padding_left - padding_right;
    const avail_h = @as(f32, @floatFromInt(height)) - (render_padding * 2 + tb) - padding_top - padding_bottom;
    if (avail_w <= 0 or avail_h <= 0) return;

    const new_cols: u16 = @intFromFloat(@max(1, avail_w / font.cell_width));
    const new_rows: u16 = @intFromFloat(@max(1, avail_h / font.cell_height));

    // Update root grid dimensions (used for spawning new tabs).
    // Actual terminal + PTY resize is handled by computeSplitLayout → setScreenSize
    // below, which is the single resize path for all surfaces.
    if (new_cols != term_cols or new_rows != term_rows) {
        term_cols = new_cols;
        term_rows = new_rows;
        // Clear any pending coalesced resize — we're handling it now
        g_pending_resize = false;
    }

    // Sync atlas textures
    if (font.g_atlas != null) font.syncAtlasTexture(&font.g_atlas, &font.g_atlas_texture, &font.g_atlas_modified);
    if (font.g_color_atlas != null) font.syncAtlasTexture(&font.g_color_atlas, &font.g_color_atlas_texture, &font.g_color_atlas_modified);
    if (font.g_icon_atlas != null) font.syncAtlasTexture(&font.g_icon_atlas, &font.g_icon_atlas_texture, &font.g_icon_atlas_modified);
    if (font.g_titlebar_atlas != null) font.syncAtlasTexture(&font.g_titlebar_atlas, &font.g_titlebar_atlas_texture, &font.g_titlebar_atlas_modified);

    const fb_width: c_int = width;
    const fb_height: c_int = height;
    const titlebar_offset: f32 = tb;
    if (g_window) |w| {
        browser_panel.sync(w.hwnd, width, height, titlebar_offset, left_panels_w, browserPanelRightOffset());
    }

    // Snapshot + rebuild + draw (split-aware, mirrors main loop)
    if (activeTab()) |active_tab| {
        // Compute split layout — also calls setScreenSize on each surface,
        // which corrects the per-surface dimensions for splits.
        const content_x: i32 = @intFromFloat(left_panels_w + render_padding);
        const content_y: i32 = @intFromFloat(render_padding + tb);
        const content_w: i32 = @intFromFloat(@as(f32, @floatFromInt(width)) - left_panels_w - right_panels_w - render_padding * 2);
        const content_h: i32 = @intFromFloat(@as(f32, @floatFromInt(height)) - (render_padding + tb) - render_padding);
        const split_count = computeSplitLayout(active_tab, content_x, content_y, content_w, content_h, font.cell_width, font.cell_height);
        if (g_allocator) |alloc| syncRemoteLayout(alloc);

        if (split_count <= 1) {
            if (active_tab.kind == .ai_chat) {
                renderAiChatFrame(fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (activeSurface()) |surface| {
                // Single surface: simple render path
                const rend = &surface.surface_renderer;
                var needs_rebuild: bool = false;
                {
                    surface.render_state.mutex.lock();
                    defer surface.render_state.mutex.unlock();
                    cell_renderer.g_current_render_surface = surface;
                    rend.force_rebuild = true;
                    needs_rebuild = cell_renderer.updateTerminalCells(rend, &surface.terminal);
                }
                if (needs_rebuild) cell_renderer.rebuildCells(rend);

                gl.Viewport.?(0, 0, fb_width, fb_height);
                gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                clearWithBackground(fb_width, fb_height);

                const pad = surface.getPadding();
                const pad_top = @as(f32, @floatFromInt(pad.top)) + titlebar_offset;
                titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                markdown_preview_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, 0);
                file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                cell_renderer.drawCells(rend, @floatFromInt(fb_height), left_panels_w + @as(f32, @floatFromInt(pad.left)), pad_top);
                overlays.renderScrollbar(@floatFromInt(fb_width), @floatFromInt(fb_height), pad_top);
                overlays.renderResizeOverlayWithOffset(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            }
        } else {
            // Multiple splits: render each surface in its own viewport
            gl.Viewport.?(0, 0, fb_width, fb_height);
            gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
            clearWithBackground(fb_width, fb_height);

            titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            markdown_preview_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, 0);
            file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);

            for (0..split_count) |i| {
                const rect = split_layout.g_split_rects[i];
                const is_focused = (rect.handle == active_tab.focused);
                const rend = &rect.surface.surface_renderer;

                const viewport_y = fb_height - rect.y - rect.height;
                gl.Viewport.?(rect.x, viewport_y, rect.width, rect.height);
                gl_init.setProjection(@floatFromInt(rect.width), @floatFromInt(rect.height));

                {
                    rect.surface.render_state.mutex.lock();
                    defer rect.surface.render_state.mutex.unlock();
                    rend.force_rebuild = true;
                    cell_renderer.g_current_render_surface = rect.surface;
                    _ = cell_renderer.updateTerminalCellsForSurface(rend, &rect.surface.terminal, is_focused);
                }
                cell_renderer.rebuildCells(rend);

                const pad = rect.surface.getPadding();
                cell_renderer.drawCells(rend, @floatFromInt(rect.height), @floatFromInt(pad.left), @floatFromInt(pad.top));
                overlays.renderScrollbarForSurface(rect.surface, @floatFromInt(rect.width), @floatFromInt(rect.height), @floatFromInt(pad.top));

                if (!is_focused) {
                    overlays.renderUnfocusedOverlaySimple(@floatFromInt(rect.width), @floatFromInt(rect.height));
                }

                // Show resize overlay on all splits during window resize
                if (is_focused) {
                    overlays.renderResizeOverlay(@floatFromInt(rect.width), @floatFromInt(rect.height));
                }
            }

            // Restore full viewport for dividers
            gl.Viewport.?(0, 0, fb_width, fb_height);
            gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
            overlays.renderSplitDividers(active_tab, content_x, content_y, content_w, content_h, @floatFromInt(fb_height));
        }
    } else {
        gl.Viewport.?(0, 0, fb_width, fb_height);
        gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
        clearWithBackground(fb_width, fb_height);
        titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        markdown_preview_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, 0);
        file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    }

    overlays.renderBrowserUrlBar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderCommandPalette(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderSettingsPage(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderSessionLauncher(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    overlays.renderDebugOverlay(@floatFromInt(fb_width));
    overlays.renderCloseShortcutConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderCopyToast(@floatFromInt(fb_width), @floatFromInt(fb_height));
    overlays.renderWindowCloseConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));

    if (g_window) |w| w.swapBuffers();
}

fn resizeWindowToGrid() void {
    const padding: f32 = 10;
    const tb = currentTitlebarHeight();
    const content_w: f32 = font.cell_width * @as(f32, @floatFromInt(term_cols));
    const content_h: f32 = font.cell_height * @as(f32, @floatFromInt(term_rows));
    const win_w: i32 = @intFromFloat(content_w + leftPanelsWidth() + rightPanelsWidth() + padding * 2);
    const win_h: i32 = @intFromFloat(content_h + padding + (padding + tb));
    if (g_window) |w| w.setSize(win_w, win_h);
}

/// Reload config from disk and apply theme/font/cursor/etc. (used after UI writes config).
pub fn reloadConfigImmediate(allocator: std.mem.Allocator) void {
    const cfg = Config.load(allocator) catch |err| {
        std.debug.print("reloadConfigImmediate: failed to load config: {}\n", .{err});
        return;
    };
    defer cfg.deinit(allocator);
    applyReloadedConfig(allocator, &cfg);
}

/// Apply freshly loaded configuration to this window/font/theme state.
fn applyReloadedConfig(allocator: std.mem.Allocator, cfg: *const Config) void {
    // Update App's cached config so new windows get the new settings
    if (g_app) |app| {
        app.updateConfig(cfg);
    }
    ai_chat.configureAgent(.{
        .enabled = cfg.@"ai-agent-enabled",
        .permission = cfg.@"ai-agent-permission",
        .command_timeout_ms = cfg.@"ai-agent-command-timeout-ms",
        .output_limit = cfg.@"ai-agent-output-limit",
    });

    if (g_window == null) return;
    const ft_lib = font.g_ft_lib orelse return;

    // --- Theme, cursor, debug ---
    g_theme = cfg.resolved_theme;
    g_force_rebuild = true;
    g_cursor_style = cfg.@"cursor-style";
    g_cursor_blink = cfg.@"cursor-style-blink";
    overlays.g_debug_fps = cfg.@"phantty-debug-fps";
    overlays.g_debug_draw_calls = cfg.@"phantty-debug-draw-calls";
    g_debug_memory = cfg.@"phantty-debug-memory";

    // --- Split config ---
    overlays.g_unfocused_split_opacity = cfg.@"unfocused-split-opacity";
    g_focus_follows_mouse = cfg.@"focus-follows-mouse";
    g_copy_on_select = cfg.@"copy-on-select";
    g_right_click_action = cfg.@"right-click-action";
    g_ssh_legacy_algorithms = cfg.@"ssh-legacy-algorithms";
    tab.g_ssh_legacy_algorithms = cfg.@"ssh-legacy-algorithms";
    overlays.g_split_divider_color = cfg.@"split-divider-color";

    // --- Background image ---
    {
        const mode_changed = background_image.g_mode != cfg.@"background-image-mode";
        background_image.g_mode = cfg.@"background-image-mode";
        gl_init.g_bg_opacity = cfg.@"background-opacity";
        if (!background_image.isLoaded(cfg.@"background-image")) {
            background_image.load(allocator, cfg.@"background-image");
        } else if (mode_changed) {
            background_image.refreshWrapMode();
        }
    }

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
    font.g_cjk_font_family = cfg.@"font-family-cjk";
    font.g_fallback_font_families = cfg.@"font-family-fallback";

    const font_changed = new_font_size != font.g_font_size;

    // Only reload font faces when font parameters actually changed.
    // Theme-only changes must not trigger a font reload + window resize.
    if (font_changed) {
        if (reloadFontFaces(allocator, new_family, new_weight, new_font_size, ft_lib)) {
            if (g_window) |w| {
                const is_os_sized = w.is_fullscreen or win32_backend.IsZoomed(w.hwnd) != 0;
                if (is_os_sized) {
                    onWin32Resize(w.width, w.height);
                } else {
                    if (cfg.@"window-width" > 0) term_cols = cfg.@"window-width";
                    if (cfg.@"window-height" > 0) term_rows = cfg.@"window-height";
                    resizeWindowToGrid();
                }
            }
        } else {
            std.debug.print("Reload: failed to load font, keeping current font\n", .{});
        }
    }

    std.debug.print("Config reloaded successfully\n", .{});
}

const MemoryDebugTotals = struct {
    tabs: usize = 0,
    ai_tabs: usize = 0,
    visible_surfaces: usize = 0,
    surfaces: usize = 0,
    terminal_page_bytes: usize = 0,
    terminal_page_limit_bytes: usize = 0,
    terminal_min_page_bytes: usize = 0,
    renderer_cpu_capacity_bytes: usize = 0,
    kitty_pending_cpu_bytes: usize = 0,
    kitty_texture_pixel_bytes: usize = 0,
    fbo_pixel_bytes: usize = 0,
};

const SurfaceMemoryDebug = struct {
    cols: usize = 0,
    rows: usize = 0,
    screen_count: usize = 0,
    terminal_page_bytes: usize = 0,
    terminal_page_limit_bytes: usize = 0,
    terminal_min_page_bytes: usize = 0,
    renderer_cpu_capacity_bytes: usize = 0,
    bg_cell_count: usize = 0,
    fg_cell_count: usize = 0,
    color_fg_cell_count: usize = 0,
    kitty_textures: usize = 0,
    kitty_pending_uploads: usize = 0,
    kitty_pending_cpu_bytes: usize = 0,
    kitty_texture_pixel_bytes: usize = 0,
    fbo_width: u32 = 0,
    fbo_height: u32 = 0,
    fbo_pixel_bytes: usize = 0,
};

fn collectSurfaceMemoryDebug(surface: *Surface) SurfaceMemoryDebug {
    var stats: SurfaceMemoryDebug = .{};

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    stats.cols = surface.terminal.cols;
    stats.rows = surface.terminal.rows;

    var screen_it = surface.terminal.screens.all.iterator();
    while (screen_it.next()) |entry| {
        const screen = entry.value.*;
        stats.screen_count += 1;
        stats.terminal_page_bytes += screen.pages.page_size;
        stats.terminal_page_limit_bytes += screen.pages.explicit_max_size;
        stats.terminal_min_page_bytes += screen.pages.min_max_size;
    }

    const rend = &surface.surface_renderer;
    stats.renderer_cpu_capacity_bytes = rend.cpuBufferCapacityBytes();
    stats.bg_cell_count = rend.bg_cell_count;
    stats.fg_cell_count = rend.fg_cell_count;
    stats.color_fg_cell_count = rend.color_fg_cell_count;
    stats.kitty_textures = rend.kitty_textures.items.len;
    stats.kitty_pending_uploads = rend.kitty_pending_uploads.items.len;
    stats.kitty_pending_cpu_bytes = rend.kittyPendingCpuBytes();
    stats.kitty_texture_pixel_bytes = rend.kittyTexturePixelBytes();
    stats.fbo_width = rend.fbo_width;
    stats.fbo_height = rend.fbo_height;
    stats.fbo_pixel_bytes = rend.fboPixelBytes();

    return stats;
}

fn maybePrintMemoryDebug(now: i64) void {
    if (!g_debug_memory) return;
    if (now - g_debug_memory_last_ms < 5000) return;
    g_debug_memory_last_ms = now;

    var totals: MemoryDebugTotals = .{};

    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        totals.tabs += 1;

        if (tab_state.kind == .ai_chat) {
            totals.ai_tabs += 1;
            continue;
        }

        var it = tab_state.tree.iterator();
        while (it.next()) |entry| {
            const visible = tab_index == tab.g_active_tab;
            const stats = collectSurfaceMemoryDebug(entry.surface);

            totals.surfaces += 1;
            if (visible) totals.visible_surfaces += 1;
            totals.terminal_page_bytes += stats.terminal_page_bytes;
            totals.terminal_page_limit_bytes += stats.terminal_page_limit_bytes;
            totals.terminal_min_page_bytes += stats.terminal_min_page_bytes;
            totals.renderer_cpu_capacity_bytes += stats.renderer_cpu_capacity_bytes;
            totals.kitty_pending_cpu_bytes += stats.kitty_pending_cpu_bytes;
            totals.kitty_texture_pixel_bytes += stats.kitty_texture_pixel_bytes;
            totals.fbo_pixel_bytes += stats.fbo_pixel_bytes;

            if (totals.surfaces <= 8) {
                std.debug.print(
                    "[memory] surface#{d}{s} grid={}x{} screens={} pages={d:.1}/{d:.1}MiB min={d:.1}MiB renderer_cap={d:.1}MiB cells(bg/fg/color)={}/{}/{} kitty(tex/pending)={}/{} kitty_bytes(cpu/gpu)={d:.1}/{d:.1}MiB fbo={}x{} {d:.1}MiB\n",
                    .{
                        totals.surfaces,
                        if (visible) " visible" else "",
                        stats.cols,
                        stats.rows,
                        stats.screen_count,
                        memory_debug.mib(stats.terminal_page_bytes),
                        memory_debug.mib(stats.terminal_page_limit_bytes),
                        memory_debug.mib(stats.terminal_min_page_bytes),
                        memory_debug.mib(stats.renderer_cpu_capacity_bytes),
                        stats.bg_cell_count,
                        stats.fg_cell_count,
                        stats.color_fg_cell_count,
                        stats.kitty_textures,
                        stats.kitty_pending_uploads,
                        memory_debug.mib(stats.kitty_pending_cpu_bytes),
                        memory_debug.mib(stats.kitty_texture_pixel_bytes),
                        stats.fbo_width,
                        stats.fbo_height,
                        memory_debug.mib(stats.fbo_pixel_bytes),
                    },
                );
            }
        }
    }

    const font_stats = font.memoryStats();
    const font_cpu_bytes =
        font_stats.atlas_cpu_bytes +
        font_stats.color_atlas_cpu_bytes +
        font_stats.icon_atlas_cpu_bytes +
        font_stats.titlebar_atlas_cpu_bytes;
    const font_gpu_bytes =
        font_stats.atlas_gpu_bytes +
        font_stats.color_atlas_gpu_bytes +
        font_stats.icon_atlas_gpu_bytes +
        font_stats.titlebar_atlas_gpu_bytes;
    const tracked_cpu_bytes =
        totals.terminal_page_bytes +
        totals.renderer_cpu_capacity_bytes +
        font_cpu_bytes +
        totals.kitty_pending_cpu_bytes;

    std.debug.print(
        "[memory] font glyphs={} graphemes={} titlebar={} icons={} fallback_faces={} no_fallback={} hb_fallback={} atlas(text/color/icon/titlebar)={}x{}/{}x{}/{}x{}/{}x{} font_atlas(cpu/gpu)={d:.1}/{d:.1}MiB\n",
        .{
            font_stats.glyphs,
            font_stats.graphemes,
            font_stats.titlebar_glyphs,
            font_stats.icons,
            font_stats.fallback_faces,
            font_stats.no_fallback_entries,
            font_stats.hb_fallback_fonts,
            font_stats.atlas_size,
            font_stats.atlas_size,
            font_stats.color_atlas_size,
            font_stats.color_atlas_size,
            font_stats.icon_atlas_size,
            font_stats.icon_atlas_size,
            font_stats.titlebar_atlas_size,
            font_stats.titlebar_atlas_size,
            memory_debug.mib(font_cpu_bytes),
            memory_debug.mib(font_gpu_bytes),
        },
    );

    if (memory_debug.queryProcess()) |process| {
        const untracked_private = process.private_usage -| tracked_cpu_bytes;
        std.debug.print(
            "[memory] process private={d:.1}MiB ws={d:.1}MiB commit={d:.1}MiB peak_ws={d:.1}MiB tabs={} ai_tabs={} surfaces={} visible_surfaces={} terminal_pages={d:.1}/{d:.1}MiB min={d:.1}MiB renderer_cap={d:.1}MiB font_atlas(cpu/gpu)={d:.1}/{d:.1}MiB kitty_bytes(cpu/gpu)={d:.1}/{d:.1}MiB fbo={d:.1}MiB tracked_cpu={d:.1}MiB untracked_private~={d:.1}MiB faults={}\n",
            .{
                memory_debug.mib(process.private_usage),
                memory_debug.mib(process.working_set),
                memory_debug.mib(process.pagefile_usage),
                memory_debug.mib(process.peak_working_set),
                totals.tabs,
                totals.ai_tabs,
                totals.surfaces,
                totals.visible_surfaces,
                memory_debug.mib(totals.terminal_page_bytes),
                memory_debug.mib(totals.terminal_page_limit_bytes),
                memory_debug.mib(totals.terminal_min_page_bytes),
                memory_debug.mib(totals.renderer_cpu_capacity_bytes),
                memory_debug.mib(font_cpu_bytes),
                memory_debug.mib(font_gpu_bytes),
                memory_debug.mib(totals.kitty_pending_cpu_bytes),
                memory_debug.mib(totals.kitty_texture_pixel_bytes),
                memory_debug.mib(totals.fbo_pixel_bytes),
                memory_debug.mib(tracked_cpu_bytes),
                memory_debug.mib(untracked_private),
                process.page_fault_count,
            },
        );
    } else {
        std.debug.print(
            "[memory] process query failed tabs={} ai_tabs={} surfaces={} terminal_pages={d:.1}MiB renderer_cap={d:.1}MiB\n",
            .{
                totals.tabs,
                totals.ai_tabs,
                totals.surfaces,
                memory_debug.mib(totals.terminal_page_bytes),
                memory_debug.mib(totals.renderer_cpu_capacity_bytes),
            },
        );
    }
}

fn syncRemoteLayout(allocator: std.mem.Allocator) void {
    const app = g_app orelse return;
    const client = app.remote_client orelse return;

    const now = std.time.milliTimestamp();
    if (now - g_remote_layout_last_ms < 250) return;
    g_remote_layout_last_ms = now;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    buildRemoteLayoutJson(allocator, &out) catch return;
    client.sendLayout(out.items);
}

fn appendAgentDetectionJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    surface: ?*const Surface,
) !void {
    const detection: agent_detector.Detection = if (surface) |s| s.agent_detection else .{};
    try out.appendSlice(allocator, ",\"agentApp\":\"");
    try remote.appendJsonString(out, allocator, detection.appLabel());
    try out.appendSlice(allocator, "\",\"agentState\":\"");
    try remote.appendJsonString(out, allocator, detection.stateLabel());
    try out.appendSlice(allocator, "\",\"agentBadge\":\"");
    try remote.appendJsonString(out, allocator, detection.badge());
    try out.appendSlice(allocator, "\",\"agentConfidence\":");
    try out.print(allocator, "{d}", .{detection.confidence});
}

fn buildRemoteLayoutJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "{\"type\":\"layout\",\"activeTab\":");
    try out.print(allocator, "{d}", .{tab.g_active_tab});
    try out.appendSlice(allocator, ",\"tabs\":[");

    var wrote_tab = false;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (wrote_tab) try out.append(allocator, ',');
        wrote_tab = true;

        if (tab_state.kind == .ai_chat) {
            try appendRemoteAiChatTabJson(allocator, out, tab_state, tab_index);
            continue;
        }

        try out.appendSlice(allocator, "{\"index\":");
        try out.print(allocator, "{d}", .{tab_index});
        try out.appendSlice(allocator, ",\"title\":\"");
        try remote.appendJsonString(out, allocator, tab_state.getTitle());
        try out.appendSlice(allocator, "\",\"focusedSurfaceId\":\"");
        var focused_surface: ?*Surface = null;
        if (tab_state.focusedSurface()) |focused| {
            focused_surface = focused;
            try remote.appendJsonString(out, allocator, focused.remote_id[0..]);
        }
        try out.append(allocator, '"');
        try appendAgentDetectionJson(allocator, out, focused_surface);
        try out.appendSlice(allocator, ",\"surfaces\":[");

        var spatial = tab_state.tree.spatial(allocator) catch null;
        defer if (spatial) |*sp| sp.deinit(allocator);

        var wrote_surface = false;
        var it = tab_state.tree.iterator();
        while (it.next()) |entry| {
            if (wrote_surface) try out.append(allocator, ',');
            wrote_surface = true;

            try out.appendSlice(allocator, "{\"id\":\"");
            try remote.appendJsonString(out, allocator, entry.surface.remote_id[0..]);
            try out.appendSlice(allocator, "\",\"title\":\"");
            try remote.appendJsonString(out, allocator, entry.surface.getTitle());
            try out.appendSlice(allocator, "\",\"focused\":");
            try out.appendSlice(allocator, if (entry.handle == tab_state.focused) "true" else "false");
            try appendAgentDetectionJson(allocator, out, entry.surface);
            try out.appendSlice(allocator, ",\"cols\":");
            try out.print(allocator, "{d}", .{entry.surface.size.grid.cols});
            try out.appendSlice(allocator, ",\"rows\":");
            try out.print(allocator, "{d}", .{entry.surface.size.grid.rows});
            var cursor_x: usize = 0;
            var cursor_y: usize = 0;
            {
                entry.surface.render_state.mutex.lock();
                defer entry.surface.render_state.mutex.unlock();
                cursor_x = entry.surface.terminal.screens.active.cursor.x;
                cursor_y = entry.surface.terminal.screens.active.cursor.y;
            }
            try out.appendSlice(allocator, ",\"cursorX\":");
            try out.print(allocator, "{d}", .{cursor_x});
            try out.appendSlice(allocator, ",\"cursorY\":");
            try out.print(allocator, "{d}", .{cursor_y});
            try out.appendSlice(allocator, ",\"snapshot\":\"");
            const snapshot = buildRemoteSurfaceSnapshot(allocator, entry.surface) catch null;
            defer if (snapshot) |text| allocator.free(text);
            if (snapshot) |text| try remote.appendJsonString(out, allocator, text);
            try out.append(allocator, '"');

            if (spatial) |sp| {
                const slot = sp.slots[entry.handle.idx()];
                try out.appendSlice(allocator, ",\"x\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.x))});
                try out.appendSlice(allocator, ",\"y\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.y))});
                try out.appendSlice(allocator, ",\"w\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.width))});
                try out.appendSlice(allocator, ",\"h\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.height))});
            } else {
                try out.appendSlice(allocator, ",\"x\":0,\"y\":0,\"w\":1,\"h\":1");
            }

            try out.append(allocator, '}');
        }

        try out.appendSlice(allocator, "]}");
    }

    try out.appendSlice(allocator, "]}");
}

fn remoteAiSurfaceId(tab_index: usize) [16]u8 {
    var id: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&id, "aichat{d:0>10}", .{tab_index}) catch unreachable;
    return id;
}

fn registerRemoteAiInputSink(tab_index: usize) void {
    const app = g_app orelse return;
    const client = app.remote_client orelse return;
    const window = g_window orelse return;
    if (tab_index >= g_remote_ai_sinks.len) return;

    g_remote_ai_sinks[tab_index] = .{
        .hwnd = window.hwnd,
        .tab_index = tab_index,
    };
    client.registerSurface(remoteAiSurfaceId(tab_index), &g_remote_ai_sinks[tab_index], remoteAiWrite);
}

fn remoteAiWrite(ctx: *anyopaque, data: []const u8) void {
    const sink: *RemoteAiInputSink = @ptrCast(@alignCast(ctx));
    const request = std.heap.page_allocator.create(RemoteAiInputRequest) catch return;
    request.* = .{
        .tab_index = sink.tab_index,
        .data = std.heap.page_allocator.dupe(u8, data) catch {
            std.heap.page_allocator.destroy(request);
            return;
        },
    };

    const ok = win32_backend.PostMessageW(
        sink.hwnd,
        WM_PHANTTY_REMOTE_AI_INPUT,
        0,
        @bitCast(@as(isize, @intCast(@intFromPtr(request)))),
    ) != 0;
    if (!ok) {
        std.heap.page_allocator.free(request.data);
        std.heap.page_allocator.destroy(request);
    }
}

fn appendRemoteAiChatTabJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    tab_state: *tab.TabState,
    tab_index: usize,
) !void {
    registerRemoteAiInputSink(tab_index);
    const surface_id = remoteAiSurfaceId(tab_index);
    const title_text = tab_state.getTitle();

    try out.appendSlice(allocator, "{\"index\":");
    try out.print(allocator, "{d}", .{tab_index});
    try out.appendSlice(allocator, ",\"title\":\"");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"focusedSurfaceId\":\"");
    try remote.appendJsonString(out, allocator, surface_id[0..]);
    try out.append(allocator, '"');
    try appendAgentDetectionJson(allocator, out, null);
    try out.appendSlice(allocator, ",\"surfaces\":[{\"id\":\"");
    try remote.appendJsonString(out, allocator, surface_id[0..]);
    try out.appendSlice(allocator, "\",\"title\":\"");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"focused\":true");
    try appendAgentDetectionJson(allocator, out, null);
    try out.appendSlice(allocator, ",\"kind\":\"ai_chat\",\"readOnly\":false,\"cols\":120,\"rows\":30,\"cursorX\":0,\"cursorY\":0,\"snapshot\":\"");
    if (tab_state.ai_chat_session) |session| {
        const snapshot = session.allocRemoteSnapshot(allocator) catch null;
        defer if (snapshot) |text| allocator.free(text);
        if (snapshot) |text| try remote.appendJsonString(out, allocator, text);
    }
    try out.appendSlice(allocator, "\",\"x\":0,\"y\":0,\"w\":1,\"h\":1}]}");
}

fn handleRemoteAiInputRequest(request: *RemoteAiInputRequest) void {
    defer {
        std.heap.page_allocator.free(request.data);
        std.heap.page_allocator.destroy(request);
    }
    if (request.tab_index >= tab.g_tab_count) return;
    const tab_state = tab.g_tabs[request.tab_index] orelse return;
    if (tab_state.kind != .ai_chat) return;
    const session = tab_state.ai_chat_session orelse return;
    session.applyRemoteInput(request.data);
    g_force_rebuild = true;
}

fn buildRemoteSurfaceSnapshot(allocator: std.mem.Allocator, surface: *Surface) ![]u8 {
    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();
    return remote_snapshot.allocTerminalSnapshot(
        allocator,
        &surface.terminal,
        remote_snapshot.default_max_history_rows,
    );
}

const AgentSurfaceLocation = struct {
    tab_index: usize,
    focused: bool,
};

fn findAgentSurfaceLocation(surface: *const Surface) ?AgentSurfaceLocation {
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.iterator();
        while (it.next()) |entry| {
            if (entry.surface == surface) {
                return .{
                    .tab_index = tab_index,
                    .focused = tab_index == tab.g_active_tab and entry.handle == tab_state.focused,
                };
            }
        }
    }
    return null;
}

fn makeAgentToolSurface(
    allocator: std.mem.Allocator,
    surface: *Surface,
    tab_index: usize,
    focused: bool,
) anyerror!ai_chat.ToolSurface {
    return .{
        .id = try allocator.dupe(u8, surface.remote_id[0..]),
        .title = try allocator.dupe(u8, surface.getTitle()),
        .cwd = try allocator.dupe(u8, surface.getCwd() orelse surface.getInitialCwd() orelse ""),
        .snapshot = buildRemoteSurfaceSnapshot(allocator, surface) catch try allocator.dupe(u8, ""),
        .tab_index = tab_index,
        .focused = focused,
        .is_ssh = surface.launch_kind == .ssh and surface.ssh_connection != null,
        .is_wsl = surface.launch_kind == .wsl,
        .agent_app = surface.agent_detection.app,
        .agent_state = surface.agent_detection.state,
        .agent_confidence = surface.agent_detection.confidence,
        .ptr = @ptrCast(surface),
    };
}

fn collectAgentToolSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!ai_chat.ToolSnapshot {
    _ = ctx;
    var surfaces: std.ArrayListUnmanaged(ai_chat.ToolSurface) = .empty;
    errdefer {
        for (surfaces.items) |surface| surface.deinit(allocator);
        surfaces.deinit(allocator);
    }

    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.iterator();
        while (it.next()) |entry| {
            try surfaces.append(allocator, try makeAgentToolSurface(
                allocator,
                entry.surface,
                tab_index,
                tab_index == tab.g_active_tab and entry.handle == tab_state.focused,
            ));
        }
    }

    return .{
        .surfaces = try surfaces.toOwnedSlice(allocator),
        .active_tab = tab.g_active_tab,
    };
}

fn agentSurfaceSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator, surface_ptr: *anyopaque) anyerror![]u8 {
    _ = ctx;
    const surface: *Surface = @ptrCast(@alignCast(surface_ptr));
    return buildRemoteSurfaceSnapshot(allocator, surface);
}

fn agentWriteSurface(ctx: *anyopaque, surface_ptr: *anyopaque, data: []const u8) bool {
    _ = ctx;
    const surface: *Surface = @ptrCast(@alignCast(surface_ptr));
    surface.queuePtyWrite(data);
    return true;
}

fn postAgentTabNew(hwnd: win32_backend.HWND, request: *AgentTabNewRequest) void {
    _ = win32_backend.SendMessageW(
        hwnd,
        WM_PHANTTY_AGENT_TAB_NEW,
        0,
        @as(win32_backend.LPARAM, @bitCast(@intFromPtr(request))),
    );
}

fn postAgentTabClose(hwnd: win32_backend.HWND, request: *AgentTabCloseRequest) void {
    _ = win32_backend.SendMessageW(
        hwnd,
        WM_PHANTTY_AGENT_TAB_CLOSE,
        0,
        @as(win32_backend.LPARAM, @bitCast(@intFromPtr(request))),
    );
}

fn postAgentSshConnect(hwnd: win32_backend.HWND, request: *AgentSshConnectRequest) void {
    _ = win32_backend.SendMessageW(
        hwnd,
        WM_PHANTTY_AGENT_SSH_CONNECT,
        0,
        @as(win32_backend.LPARAM, @bitCast(@intFromPtr(request))),
    );
}

fn agentSpawnTab(ctx: *anyopaque, allocator: std.mem.Allocator, kind: []const u8, command: ?[]const u8) anyerror!ai_chat.ToolSurface {
    const window: *AppWindow = @ptrCast(@alignCast(ctx));
    const hwnd = window.getHwnd() orelse return error.WindowUnavailable;

    var request = AgentTabNewRequest{
        .allocator = allocator,
        .kind = kind,
        .command = command,
    };

    if (g_window) |current| {
        if (current.hwnd == hwnd) {
            handleAgentTabNewRequest(&request);
        } else {
            postAgentTabNew(hwnd, &request);
        }
    } else {
        postAgentTabNew(hwnd, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.SpawnFailed;
}

fn agentCloseTab(ctx: *anyopaque, allocator: std.mem.Allocator, tab_index: ?usize, surface_id: ?[]const u8, title_text: ?[]const u8) anyerror!ai_chat.ToolClosedTab {
    const window: *AppWindow = @ptrCast(@alignCast(ctx));
    const hwnd = window.getHwnd() orelse return error.WindowUnavailable;

    var request = AgentTabCloseRequest{
        .allocator = allocator,
        .tab_index = tab_index,
        .surface_id = surface_id,
        .title = title_text,
    };

    if (g_window) |current| {
        if (current.hwnd == hwnd) {
            handleAgentTabCloseRequest(&request);
        } else {
            postAgentTabClose(hwnd, &request);
        }
    } else {
        postAgentTabClose(hwnd, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.TabNotFound;
}

fn agentConnectSshProfile(ctx: *anyopaque, allocator: std.mem.Allocator, profile_name: []const u8) anyerror!ai_chat.ToolSurface {
    const window: *AppWindow = @ptrCast(@alignCast(ctx));
    const hwnd = window.getHwnd() orelse return error.WindowUnavailable;

    var request = AgentSshConnectRequest{
        .allocator = allocator,
        .profile_name = profile_name,
    };

    if (g_window) |current| {
        if (current.hwnd == hwnd) {
            handleAgentSshConnectRequest(&request);
        } else {
            postAgentSshConnect(hwnd, &request);
        }
    } else {
        postAgentSshConnect(hwnd, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.ConnectFailed;
}

fn agentTabCommand(kind_raw: []const u8, command_raw: ?[]const u8) anyerror!?[]const u8 {
    if (command_raw) |command| {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }

    const kind = std.mem.trim(u8, kind_raw, " \t\r\n");
    if (kind.len == 0 or std.ascii.eqlIgnoreCase(kind, "default")) return null;
    if (std.ascii.eqlIgnoreCase(kind, "powershell")) return "powershell.exe -NoLogo -NoProfile";
    if (std.ascii.eqlIgnoreCase(kind, "pwsh")) return "pwsh.exe -NoLogo -NoProfile";
    if (std.ascii.eqlIgnoreCase(kind, "cmd")) return "cmd.exe";
    if (std.ascii.eqlIgnoreCase(kind, "wsl")) return "wsl.exe ~";
    if (std.ascii.eqlIgnoreCase(kind, "command") or std.ascii.eqlIgnoreCase(kind, "custom")) return error.CommandRequired;
    return error.InvalidTabKind;
}

fn handleAgentTabNewRequest(request: *AgentTabNewRequest) void {
    const command = agentTabCommand(request.kind, request.command) catch |err| {
        request.err = err;
        return;
    };

    const surface = if (command) |cmd|
        spawnTabWithCommandUtf8ReturningSurface(cmd)
    else blk: {
        const allocator = g_allocator orelse {
            request.err = error.SpawnFailed;
            return;
        };
        if (!spawnTab(allocator)) {
            request.err = error.SpawnFailed;
            return;
        }
        break :blk activeSurface();
    };

    const new_surface = surface orelse {
        request.err = error.SpawnFailed;
        return;
    };

    const location = findAgentSurfaceLocation(new_surface) orelse {
        request.err = error.SpawnFailed;
        return;
    };
    request.result = makeAgentToolSurface(
        request.allocator,
        new_surface,
        location.tab_index,
        location.focused,
    ) catch |err| {
        request.err = err;
        return;
    };
}

fn findTabIndexBySurfaceId(surface_id: []const u8) ?usize {
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.surface.remote_id[0..], surface_id)) return tab_index;
        }
    }
    return null;
}

fn findTabIndexByTitle(title_text: []const u8) ?usize {
    const title_trimmed = std.mem.trim(u8, title_text, " \t\r\n");
    if (title_trimmed.len == 0) return null;

    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (std.ascii.eqlIgnoreCase(tab_state.getTitle(), title_trimmed)) return tab_index;
    }

    var partial: ?usize = null;
    var partial_count: usize = 0;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (std.ascii.indexOfIgnoreCase(tab_state.getTitle(), title_trimmed) != null) {
            partial = tab_index;
            partial_count += 1;
        }
    }
    return if (partial_count == 1) partial else null;
}

fn resolveAgentCloseTabIndex(request: *const AgentTabCloseRequest) ?usize {
    if (request.tab_index) |idx| return idx;
    if (request.surface_id) |surface_id| {
        if (findTabIndexBySurfaceId(surface_id)) |idx| return idx;
    }
    if (request.title) |title_text| {
        if (findTabIndexByTitle(title_text)) |idx| return idx;
    }
    return tab.g_active_tab;
}

fn handleAgentTabCloseRequest(request: *AgentTabCloseRequest) void {
    if (tab.g_tab_count <= 1) {
        request.err = error.LastTab;
        return;
    }

    const idx = resolveAgentCloseTabIndex(request) orelse {
        request.err = error.TabNotFound;
        return;
    };
    if (idx >= tab.g_tab_count) {
        request.err = error.TabNotFound;
        return;
    }

    const tab_state = tab.g_tabs[idx] orelse {
        request.err = error.TabNotFound;
        return;
    };
    if (tab_state.kind != .terminal) {
        request.err = error.CannotCloseAiChatTab;
        return;
    }

    const title_copy = request.allocator.dupe(u8, tab_state.getTitle()) catch |err| {
        request.err = err;
        return;
    };

    closeTab(idx);
    request.result = .{
        .tab_index = idx,
        .active_tab = tab.g_active_tab,
        .title = title_copy,
    };
}

fn handleAgentSshConnectRequest(request: *AgentSshConnectRequest) void {
    switch (overlays.agentConnectSshProfile(request.profile_name)) {
        .connected => |surface| {
            const location = findAgentSurfaceLocation(surface) orelse {
                request.err = error.ConnectFailed;
                return;
            };
            request.result = makeAgentToolSurface(
                request.allocator,
                surface,
                location.tab_index,
                location.focused,
            ) catch |err| {
                request.err = err;
                return;
            };
        },
        .not_found => request.err = error.ProfileNotFound,
        .failed => request.err = error.ConnectFailed,
    }
}

fn onWin32Message(msg: win32_backend.UINT, wParam: win32_backend.WPARAM, lParam: win32_backend.LPARAM) ?win32_backend.LRESULT {
    _ = wParam;
    switch (msg) {
        WM_PHANTTY_AGENT_SSH_CONNECT => {
            const request: *AgentSshConnectRequest = @ptrFromInt(@as(usize, @bitCast(lParam)));
            handleAgentSshConnectRequest(request);
            return 1;
        },
        WM_PHANTTY_AGENT_TAB_NEW => {
            const request: *AgentTabNewRequest = @ptrFromInt(@as(usize, @bitCast(lParam)));
            handleAgentTabNewRequest(request);
            return 1;
        },
        WM_PHANTTY_AGENT_TAB_CLOSE => {
            const request: *AgentTabCloseRequest = @ptrFromInt(@as(usize, @bitCast(lParam)));
            handleAgentTabCloseRequest(request);
            return 1;
        },
        WM_PHANTTY_REMOTE_AI_INPUT => {
            const request: *RemoteAiInputRequest = @ptrFromInt(@as(usize, @bitCast(lParam)));
            handleRemoteAiInputRequest(request);
            return 1;
        },
        else => return null,
    }
}

fn installAgentToolHost(self: *AppWindow) void {
    ai_chat.setToolHost(.{
        .ctx = @ptrCast(self),
        .collectSnapshot = collectAgentToolSnapshot,
        .surfaceSnapshot = agentSurfaceSnapshot,
        .writeSurface = agentWriteSurface,
        .spawnTab = agentSpawnTab,
        .closeTab = agentCloseTab,
        .connectSshProfile = agentConnectSshProfile,
    });
}

fn uiFontSize(term_font_size: u32) u32 {
    return @min(24, @max(9, term_font_size));
}

fn markAllRenderersDirty() void {
    g_force_rebuild = true;
    g_cells_valid = false;
    for (0..tab.g_tab_count) |ti| {
        if (tab.g_tabs[ti]) |tb| {
            var it = tb.tree.iterator();
            while (it.next()) |entry| {
                entry.surface.surface_renderer.markDirty();
            }
        }
    }
}

fn clearIconFont(allocator: std.mem.Allocator) void {
    if (font.icon_face) |old_icon| old_icon.deinit();
    font.icon_face = null;
    font.icon_cache.deinit(allocator);
    font.icon_cache = .empty;
    if (font.g_icon_atlas) |*a| {
        a.deinit(allocator);
        font.g_icon_atlas = null;
    }
    if (font.g_icon_atlas_texture != 0) {
        gl.DeleteTextures.?(1, &font.g_icon_atlas_texture);
        font.g_icon_atlas_texture = 0;
        font.g_icon_atlas_modified = 0;
    }
}

fn rebuildIconFont(allocator: std.mem.Allocator, ft_lib: freetype.Library) void {
    clearIconFont(allocator);

    if (ft_lib.initFace("C:\\Windows\\Fonts\\segmdl2.ttf", 0)) |iface| {
        // 10px at 96 DPI, scaled to the current monitor DPI.
        const icon_size_26_6: i32 = @intCast(10 * 64 * font.g_dpi / 96);
        iface.setCharSize(0, icon_size_26_6, 72, 72) catch {};
        font.icon_face = iface;
        std.debug.print("Loaded Segoe MDL2 Assets for caption icons (dpi={})\n", .{font.g_dpi});
    } else |_| {
        std.debug.print("Segoe MDL2 Assets not found, using quad-based caption icons\n", .{});
    }
}

fn clearTitlebarFont(allocator: std.mem.Allocator) void {
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
}

fn reloadFontFaces(
    allocator: std.mem.Allocator,
    family: []const u8,
    weight: directwrite.DWRITE_FONT_WEIGHT,
    font_size: u32,
    ft_lib: freetype.Library,
) bool {
    const new_face = font.loadFontFromConfig(allocator, family, weight, font_size, ft_lib) orelse return false;

    if (font.glyph_face) |old| old.deinit();
    font.clearGlyphCache(allocator);
    font.clearFallbackFaces(allocator);
    font.g_bell_cache = null;
    if (font.g_bell_emoji_face) |f| f.deinit();
    font.g_bell_emoji_face = null;

    font.g_font_size = font_size;
    font.preloadCharacters(new_face);

    rebuildTitlebarFont(allocator, family, weight, uiFontSize(font_size), ft_lib);
    rebuildIconFont(allocator, ft_lib);
    if (g_window) |w| _ = syncWindowTitlebarHeight(w);
    markAllRenderersDirty();
    return true;
}

fn handleWindowDpiChanged(
    allocator: std.mem.Allocator,
    win: *win32_backend.Window,
    ft_lib: freetype.Library,
    family: []const u8,
    weight: directwrite.DWRITE_FONT_WEIGHT,
) void {
    const new_dpi = if (win.dpi == 0) win32_backend.GetDpiForWindow(win.hwnd) else win.dpi;
    if (new_dpi == 0) return;
    if (font.g_dpi == new_dpi) {
        onWin32Resize(win.width, win.height);
        return;
    }

    std.debug.print("DPI changed: {} -> {}\n", .{ font.g_dpi, new_dpi });
    font.g_dpi = new_dpi;
    if (reloadFontFaces(allocator, family, weight, font.g_font_size, ft_lib)) {
        onWin32Resize(win.width, win.height);
    } else {
        std.debug.print("DPI font reload failed, keeping previous font\n", .{});
    }
}

fn rebuildTitlebarFont(
    allocator: std.mem.Allocator,
    family: []const u8,
    weight: directwrite.DWRITE_FONT_WEIGHT,
    pt: u32,
    ft_lib: freetype.Library,
) void {
    clearTitlebarFont(allocator);

    if (font.loadFontFromConfig(allocator, family, weight, pt, ft_lib)) |tb_face| {
        font.g_titlebar_face = tb_face;

        const sm = tb_face.handle.*.size.*.metrics;
        const tb_ascent = @as(f32, @floatFromInt(sm.ascender)) / 64.0;
        const tb_descent = @as(f32, @floatFromInt(sm.descender)) / 64.0;
        const tb_height = @as(f32, @floatFromInt(sm.height)) / 64.0;
        font.g_titlebar_cell_height = @round(tb_height);
        font.g_titlebar_baseline = @round(-tb_descent);

        var max_adv: f32 = 0;
        for (32..127) |cp| {
            if (font.loadTitlebarGlyph(@intCast(cp))) |g| {
                const adv = @as(f32, @floatFromInt(g.advance >> 6));
                max_adv = @max(max_adv, adv);
            }
        }
        if (max_adv > 0) font.g_titlebar_cell_width = max_adv;

        std.debug.print("UI font: {}pt {d:.0}x{d:.0} (ascent={d:.1}, descent={d:.1}, baseline={d:.0})\n", .{
            pt, font.g_titlebar_cell_width, font.g_titlebar_cell_height, tb_ascent, tb_descent, font.g_titlebar_baseline,
        });
    } else {
        std.debug.print("UI font init failed, keeping titlebar fallback metrics\n", .{});
    }
}

/// Check if the config file has changed (via ReadDirectoryChangesW) and reload if so.
/// Debounces rapid changes (e.g. settings page writing multiple keys) into a single reload.
threadlocal var g_config_change_time: i64 = 0;
const CONFIG_DEBOUNCE_MS: i64 = 250;

fn checkConfigReload(allocator: std.mem.Allocator, watcher: *ConfigWatcher) void {
    if (watcher.hasChanged()) {
        g_config_change_time = std.time.milliTimestamp();
        return;
    }

    if (g_config_change_time == 0) return;
    const elapsed = std.time.milliTimestamp() - g_config_change_time;
    if (elapsed < CONFIG_DEBOUNCE_MS) return;

    g_config_change_time = 0;
    std.debug.print("Config file changed, reloading...\n", .{});

    const cfg = Config.load(allocator) catch |err| {
        std.debug.print("Failed to reload config: {}\n", .{err});
        return;
    };
    defer cfg.deinit(allocator);
    applyReloadedConfig(allocator, &cfg);
}

/// Reset cursor blink to visible state (call on keypress like Ghostty)
pub fn resetCursorBlink() void {
    g_cursor_blink_visible = true;
    g_last_blink_time = std.time.milliTimestamp();
}

// Cached cursor sampling state for the IME caret. TUIs (e.g. Claude Code)
// emit cursor save/restore sequences many times per second to animate a
// status line; the render-loop sampler would otherwise catch the cursor
// mid-animation and re-anchor the IME popup / inline preedit on the wrong row.
threadlocal var g_ime_caret_last_sample_x: i64 = -1;
threadlocal var g_ime_caret_last_sample_y: i64 = -1;
threadlocal var g_ime_caret_committed_x: i64 = -1;
threadlocal var g_ime_caret_committed_y: i64 = -1;

fn syncImeCaretPosition(win: *win32_backend.Window, split_count: usize) void {
    // Freeze the caret during composition so the IMM popup, anchored when the
    // composition started, doesn't drift onto another line as the cursor moves.
    if (win.ime_composing) return;

    if (activeAiChat()) |session| {
        syncAiChatImeCaret(win, session);
        return;
    }

    const surface = activeSurface() orelse return;

    var cursor_x: usize = 0;
    var cursor_y: usize = 0;
    {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        const screen = surface.terminal.screens.active;
        cursor_x = screen.cursor.x;
        cursor_y = screen.cursor.y;
    }

    // Require two consecutive frames at the same position before committing,
    // so single-frame transients during status-line animations are skipped.
    const sx: i64 = @intCast(cursor_x);
    const sy: i64 = @intCast(cursor_y);
    if (sx != g_ime_caret_last_sample_x or sy != g_ime_caret_last_sample_y) {
        g_ime_caret_last_sample_x = sx;
        g_ime_caret_last_sample_y = sy;
        return;
    }
    if (sx == g_ime_caret_committed_x and sy == g_ime_caret_committed_y) return;
    g_ime_caret_committed_x = sx;
    g_ime_caret_committed_y = sy;

    const pad = surface.getPadding();
    const cell_w = font.cell_width;
    const cell_h = font.cell_height;

    var x: f32 = titlebar.sidebarWidth() + @as(f32, @floatFromInt(pad.left)) + @as(f32, @floatFromInt(cursor_x)) * cell_w;
    var y: f32 = currentTitlebarHeight() + @as(f32, @floatFromInt(pad.top)) + @as(f32, @floatFromInt(cursor_y)) * cell_h;

    if (split_count > 1) {
        for (0..split_layout.g_split_rect_count) |i| {
            const rect = split_layout.g_split_rects[i];
            if (rect.surface == surface) {
                x = @as(f32, @floatFromInt(rect.x)) + @as(f32, @floatFromInt(pad.left)) + @as(f32, @floatFromInt(cursor_x)) * cell_w;
                y = @as(f32, @floatFromInt(rect.y)) + @as(f32, @floatFromInt(pad.top)) + @as(f32, @floatFromInt(cursor_y)) * cell_h;
                break;
            }
        }
    }

    win.setImeCaret(
        @intFromFloat(@round(x)),
        @intFromFloat(@round(y)),
        @intFromFloat(@max(1.0, @round(cell_h))),
    );
}

fn syncAiChatImeCaret(win: *win32_backend.Window, session: *ai_chat.Session) void {
    const wh: f32 = @floatFromInt(win.height);
    const ww: f32 = @floatFromInt(win.width);
    const left_panels_w = leftPanelsWidth();
    const right_panels_w = rightPanelsWidthForWindow(win.width);
    const panel_w = @max(1.0, ww - left_panels_w - right_panels_w);
    session.mutex.lock();
    const input_text = session.input();
    const layout = ai_chat_renderer.inputLayout(left_panels_w, panel_w, input_text);
    const cursor = ai_chat_renderer.inputCursorRect(input_text, session.input_cursor, layout.text_x, layout.text_w);
    const scrolled_row = session.input_scroll_row;
    const follow_cursor = session.input_scroll_follow_cursor;
    session.mutex.unlock();
    const input_line_h = @round(@max(23.0, font.g_titlebar_cell_height + 8.0));
    const visible_rows = ai_chat_renderer.inputVisibleRowsForField(layout.field_h);
    var first_row = scrolled_row;
    if (follow_cursor) {
        if (cursor.row < first_row) {
            first_row = cursor.row;
        } else if (cursor.row >= first_row + visible_rows) {
            first_row = cursor.row - visible_rows + 1;
        }
    }
    if (cursor.row < first_row) return;
    const row = cursor.row - first_row;
    const field_top_px = wh - layout.field_y - layout.field_h;
    const cursor_top_px = field_top_px + ai_chat_renderer.INPUT_FIELD_PAD_TOP + @as(f32, @floatFromInt(row)) * input_line_h;
    const cursor_y = cursor_top_px;
    const h = font.g_titlebar_cell_height;
    win.setImeCaret(
        @intFromFloat(@round(cursor.x)),
        @intFromFloat(@round(cursor_y)),
        @intFromFloat(@max(1.0, @round(h))),
    );
}

fn renderImePreedit(win: *win32_backend.Window, fb_width: i32, fb_height: i32) void {
    _ = fb_width;
    const text = win.imePreeditText();
    if (text.len == 0) return;

    var view = std.unicode.Utf8View.init(text) catch return;
    var count_it = view.iterator();
    var cells: usize = 0;
    while (count_it.nextCodepoint()) |_| cells += 1;
    if (cells == 0) return;

    const x = @as(f32, @floatFromInt(win.ime_caret_x));
    const y = @as(f32, @floatFromInt(@max(0, fb_height - win.ime_caret_y - win.ime_caret_height)));
    const width = @as(f32, @floatFromInt(cells)) * font.cell_width;
    const height = @as(f32, @floatFromInt(win.ime_caret_height));

    const bg = g_theme.selection_background;
    const fg = g_theme.selection_foreground orelse g_theme.foreground;

    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);
    gl_init.renderQuad(x, y, width, height, bg);
    gl_init.renderQuad(x, y, width, @max(1.0, @as(f32, @floatFromInt(font.box_thickness))), g_theme.cursor_color);

    view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    var cursor_x = x;
    while (it.nextCodepoint()) |cp| {
        cell_renderer.renderChar(@intCast(cp), cursor_x, y, fg);
        cursor_x += font.cell_width;
    }

    gl.BindVertexArray.?(0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, 0);
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
fn runMainLoop(self: *AppWindow) !void {
    const allocator = self.allocator;

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
    self.hwnd_bits.store(@intFromPtr(win32_window.hwnd), .release);
    defer self.hwnd_bits.store(0, .release);
    win32_window.on_message = &onWin32Message;
    installAgentToolHost(self);
    font.g_dpi = win32_window.dpi;

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

    font.setFacePointSize(face, font_size) catch |err| {
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

    rebuildTitlebarFont(allocator, requested_font, requested_weight, uiFontSize(font_size), ft_lib);
    _ = syncWindowTitlebarHeight(&win32_window);

    // Load Segoe MDL2 Assets for caption button icons (Windows system font)
    rebuildIconFont(allocator, ft_lib);

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
    if (g_app) |app| {
        // Dupe the path under app.mutex so a concurrent updateConfig from
        // another window cannot free it out from under us.
        app.mutex.lock();
        const initial_path: ?[]u8 = if (app.background_image) |p| (allocator.dupe(u8, p) catch null) else null;
        app.mutex.unlock();
        if (initial_path) |p| {
            defer allocator.free(p);
            background_image.load(allocator, p);
        }
    }
    defer {
        background_image.deinit();
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
    const titlebar_height = currentTitlebarHeight();
    const explicit_left: f32 = @floatFromInt(DEFAULT_PADDING);
    const explicit_right: f32 = @as(f32, @floatFromInt(DEFAULT_PADDING)) + overlays.SCROLLBAR_WIDTH;
    const explicit_top: f32 = @floatFromInt(DEFAULT_PADDING);
    const explicit_bottom: f32 = @floatFromInt(DEFAULT_PADDING);
    const render_padding: f32 = 10;
    const initial_left_panels_w: f32 = leftPanelsWidth();

    // For width: pw = fb_width - left_panels_w, then subtract explicit_padding
    const total_width_padding = initial_left_panels_w + explicit_left + explicit_right;
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

        // Try to restore the previous session, but only:
        //   - once per process (first window only),
        //   - if config.restore-tabs-on-startup is true,
        //   - if no CWD override was provided (CLI/spawn).
        // TODO: also detect --command CLI override once a structured CLI
        // arg parser exists (today CLI args are merged into Config keys
        // and there is no positional/--command flag).
        const restore_once = !g_session_restore_attempted.swap(true, .seq_cst);
        const restore_enabled = if (g_app) |app| app.restore_tabs_on_startup else false;
        const should_try_restore = restore_once and restore_enabled and initial_cwd == null;
        const restored = should_try_restore and tab.restoreSessionFromFile(
            allocator,
            term_cols,
            term_rows,
            g_cursor_style,
            g_cursor_blink,
        );

        if (!restored) {
            if (!spawnTabWithCwd(allocator, initial_cwd)) {
                std.debug.print("Failed to spawn initial tab\n", .{});
                return error.SpawnFailed;
            }
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
        overlays.tickSessionLauncher();
        file_explorer.tickAsync();
        maybePrintMemoryDebug(std.time.milliTimestamp());
        flushAgentHistoryStoreIfDirty(false);

        // Process pending resize (coalesced, like Ghostty)
        // We wait for RESIZE_COALESCE_MS after last resize event before applying.
        // Only update the root grid dimensions here — actual terminal + PTY resize
        // is handled by computeSplitLayout → setScreenSize in the render loop below.
        if (g_pending_resize) {
            const now = std.time.milliTimestamp();
            if (now - g_last_resize_time >= RESIZE_COALESCE_MS) {
                g_pending_resize = false;

                if (g_pending_cols != term_cols or g_pending_rows != term_rows) {
                    term_cols = g_pending_cols;
                    term_rows = g_pending_rows;
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
        if (win.close_requested) {
            win.close_requested = false;
            overlays.windowCloseConfirmOpen();
            g_force_rebuild = true;
            g_cells_valid = false;
        }

        if (win.dpi_changed) {
            win.dpi_changed = false;
            handleWindowDpiChanged(allocator, win, ft_lib, requested_font, requested_weight);
        }

        // Sync tab count to win32 for hit-testing
        win.tab_count = tab.g_tab_count;
        win.sidebar_width = @intFromFloat(titlebar.sidebarWidth());

        // Process all queued input events (keyboard, mouse, resize)
        input.processEvents(win);

        // Update focus state
        if (window_focused != win.focused) g_force_rebuild = true;
        window_focused = win.focused;

        const fb = win.getFramebufferSize();
        const fb_width: c_int = fb.width;
        const fb_height: c_int = fb.height;
        if (win.is_minimized or fb_width <= 0 or fb_height <= 0) {
            std.Thread.sleep(16 * std.time.ns_per_ms);
            continue;
        }

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
        const titlebar_offset = syncWindowTitlebarHeight(win);
        const left_panels_w = leftPanelsWidth();
        const right_panels_w = rightPanelsWidthForWindow(fb_width);
        const top_padding: f32 = padding + titlebar_offset;
        browser_panel.sync(win.hwnd, fb_width, fb_height, titlebar_offset, left_panels_w, browserPanelRightOffset());

        if (activeTab()) |active_tab| {
            // Compute split layout for the active tab
            const content_x: i32 = @intFromFloat(left_panels_w + padding);
            const content_y: i32 = @intFromFloat(top_padding);
            const content_w: i32 = @intFromFloat(@as(f32, @floatFromInt(fb_width)) - left_panels_w - right_panels_w - padding * 2);
            const content_h: i32 = @intFromFloat(@as(f32, @floatFromInt(fb_height)) - top_padding - padding);
            const split_count = computeSplitLayout(active_tab, content_x, content_y, content_w, content_h, font.cell_width, font.cell_height);
            syncRemoteLayout(allocator);
            syncImeCaretPosition(win, split_count);

            // Debug: print split count on first few frames
            // GL rendering
            if (active_tab.kind == .ai_chat) {
                renderAiChatFrame(fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
            } else if (post_process.g_post_enabled) {
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
                    clearWithBackground(fb_width, fb_height);

                    // Use surface's computed padding (includes titlebar offset from content_y)
                    const pad = surface.getPadding();
                    const pad_top = @as(f32, @floatFromInt(pad.top)) + titlebar_offset;
                    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                    markdown_preview_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, 0);
                    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                    cell_renderer.drawCells(rend, @floatFromInt(fb_height), left_panels_w + @as(f32, @floatFromInt(pad.left)), pad_top);
                    overlays.renderScrollbar(@floatFromInt(fb_width), @floatFromInt(fb_height), pad_top);

                    // Render resize overlay centered in content area (offset for titlebar)
                    overlays.renderResizeOverlayWithOffset(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                }
            } else {
                // Multiple splits: render with scissor/viewport per surface
                gl.Viewport.?(0, 0, fb_width, fb_height);
                gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                clearWithBackground(fb_width, fb_height);

                titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
                markdown_preview_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, 0);
                file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);

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
            clearWithBackground(fb_width, fb_height);
            titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            markdown_preview_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, 0);
            file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        }

        gl.Viewport.?(0, 0, fb_width, fb_height);
        gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderBrowserUrlBar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderStartupShortcutsOverlay(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderCommandPalette(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderSettingsPage(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderSessionLauncher(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
        overlays.renderDebugOverlay(@floatFromInt(fb_width));
        overlays.renderCloseShortcutConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderCopyToast(@floatFromInt(fb_width), @floatFromInt(fb_height));
        overlays.renderWindowCloseConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height));
        renderImePreedit(win, fb_width, fb_height);

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

    // Clean up file explorer async state (join background thread, free job)
    file_explorer.deinit();
    browser_panel.deinit();

    // Tab cleanup is handled by AppWindow.deinit()
}
