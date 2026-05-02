//! App — coordinates multiple terminal windows.
//!
//! Owns shared configuration and manages the lifecycle of AppWindow instances.
//! Each window runs on its own thread with independent Win32 message pump,
//! OpenGL context, fonts, and terminal state.

const std = @import("std");
const Config = @import("config.zig");
const AppWindow = @import("AppWindow.zig");
const directwrite = @import("directwrite.zig");
const win32_backend = @import("apprt/win32.zig");

extern "user32" fn MonitorFromPoint(pt: win32_backend.POINT, dwFlags: u32) callconv(.winapi) ?win32_backend.HMONITOR;

const App = @This();

// ============================================================================
// Fields
// ============================================================================

allocator: std.mem.Allocator,

// Resolved shell command (UTF-16, null-terminated)
shell_cmd_buf: [256]u16,
shell_cmd_len: usize,

// Config values (read-only after init)
scrollback_limit: u32,
font_family: []const u8,
font_family_cjk: ?[]const u8,
font_family_fallback: ?[]const u8,
font_weight: directwrite.DWRITE_FONT_WEIGHT,
font_size: u32,
cursor_style: Config.CursorStyle,
cursor_blink: bool,
theme: Config.Theme,
shader_path: ?[]const u8,

// Terminal dimensions from config
initial_cols: u16,
initial_rows: u16,

// Window state options
maximize: bool,
fullscreen: bool,
title: ?[]const u8,

// Debug flags
debug_fps: bool,
debug_draw_calls: bool,

// Split config
unfocused_split_opacity: f32,
split_divider_color: ?Config.Color,
focus_follows_mouse: bool,

// Window management
windows: std.ArrayListUnmanaged(*AppWindow),
mutex: std.Thread.Mutex,
window_threads: std.ArrayListUnmanaged(std.Thread),

// Position for next spawned window (cascading)
next_window_x: ?i32 = null,
next_window_y: ?i32 = null,

// CWD for next spawned window (working directory inheritance)
next_window_cwd: [260]u16 = undefined,
next_window_cwd_len: usize = 0,

// ============================================================================
// Initialization
// ============================================================================

/// Initialize the App with configuration.
pub fn init(allocator: std.mem.Allocator, cfg: Config) !App {
    var app = App{
        .allocator = allocator,
        .shell_cmd_buf = undefined,
        .shell_cmd_len = 0,
        .scrollback_limit = cfg.@"scrollback-limit",
        .font_family = cfg.@"font-family",
        .font_family_cjk = cfg.@"font-family-cjk",
        .font_family_fallback = cfg.@"font-family-fallback",
        .font_weight = cfg.@"font-style".toDwriteWeight(),
        .font_size = cfg.@"font-size",
        .cursor_style = cfg.@"cursor-style",
        .cursor_blink = cfg.@"cursor-style-blink",
        .theme = cfg.resolved_theme,
        .shader_path = cfg.@"custom-shader",
        .initial_cols = if (cfg.@"window-width" > 0) cfg.@"window-width" else 80,
        .initial_rows = if (cfg.@"window-height" > 0) cfg.@"window-height" else 24,
        .maximize = cfg.maximize,
        .fullscreen = cfg.fullscreen,
        .title = cfg.title,
        .debug_fps = cfg.@"phantty-debug-fps",
        .debug_draw_calls = cfg.@"phantty-debug-draw-calls",
        .unfocused_split_opacity = cfg.@"unfocused-split-opacity",
        .split_divider_color = cfg.@"split-divider-color",
        .focus_follows_mouse = cfg.@"focus-follows-mouse",
        .windows = .empty,
        .mutex = .{},
        .window_threads = .empty,
    };

    // Resolve shell command from config
    const cmd = cfg.shell;
    if (std.mem.eql(u8, cmd, "cmd")) {
        const lit = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
        @memcpy(app.shell_cmd_buf[0..lit.len], lit);
        app.shell_cmd_buf[lit.len] = 0;
        app.shell_cmd_len = lit.len;
    } else if (std.mem.eql(u8, cmd, "powershell")) {
        const lit = std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe");
        @memcpy(app.shell_cmd_buf[0..lit.len], lit);
        app.shell_cmd_buf[lit.len] = 0;
        app.shell_cmd_len = lit.len;
    } else if (std.mem.eql(u8, cmd, "pwsh")) {
        const lit = std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe");
        @memcpy(app.shell_cmd_buf[0..lit.len], lit);
        app.shell_cmd_buf[lit.len] = 0;
        app.shell_cmd_len = lit.len;
    } else if (std.mem.eql(u8, cmd, "wsl")) {
        const lit = std.unicode.utf8ToUtf16LeStringLiteral("wsl.exe");
        @memcpy(app.shell_cmd_buf[0..lit.len], lit);
        app.shell_cmd_buf[lit.len] = 0;
        app.shell_cmd_len = lit.len;
    } else {
        const len = std.unicode.utf8ToUtf16Le(&app.shell_cmd_buf, cmd) catch 0;
        app.shell_cmd_buf[len] = 0;
        app.shell_cmd_len = len;
    }
    std.debug.print("Shell command resolved: '{s}'\n", .{cfg.shell});

    return app;
}

/// Get the shell command as a null-terminated UTF-16 slice.
pub fn getShellCmd(self: *const App) [:0]const u16 {
    return self.shell_cmd_buf[0..self.shell_cmd_len :0];
}

/// Take the initial CWD for a new window (copies into provided buffer, clears source).
/// Returns the length of the CWD, or 0 if no CWD was set.
pub fn takeInitialCwd(self: *App, out_buf: *[260]u16) usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.next_window_cwd_len == 0) return 0;

    const len = self.next_window_cwd_len;
    @memcpy(out_buf[0..len], self.next_window_cwd[0..len]);
    out_buf[len] = 0;
    self.next_window_cwd_len = 0;
    return len;
}

/// Update cached config values from a reloaded config.
/// Called by windows when they detect a config change via hot-reload.
pub fn updateConfig(self: *App, cfg: *const Config) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.scrollback_limit = cfg.@"scrollback-limit";
    self.font_family = cfg.@"font-family";
    self.font_family_cjk = cfg.@"font-family-cjk";
    self.font_family_fallback = cfg.@"font-family-fallback";
    self.font_weight = cfg.@"font-style".toDwriteWeight();
    self.font_size = cfg.@"font-size";
    self.cursor_style = cfg.@"cursor-style";
    self.cursor_blink = cfg.@"cursor-style-blink";
    self.theme = cfg.resolved_theme;
    self.shader_path = cfg.@"custom-shader";
    self.initial_cols = cfg.@"window-width";
    self.initial_rows = cfg.@"window-height";
    self.debug_fps = cfg.@"phantty-debug-fps";
    self.debug_draw_calls = cfg.@"phantty-debug-draw-calls";
    self.unfocused_split_opacity = cfg.@"unfocused-split-opacity";
    self.split_divider_color = cfg.@"split-divider-color";
    self.focus_follows_mouse = cfg.@"focus-follows-mouse";
}

// ============================================================================
// Window Management
// ============================================================================

/// Run the first window on the main thread. Blocks until that window closes.
/// After returning, waits for all spawned window threads to finish.
pub fn run(self: *App) !void {
    // Create and run the first window on the main thread
    var first_window = try AppWindow.init(self.allocator, self);
    defer first_window.deinit();

    // Add to window list
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.windows.append(self.allocator, &first_window);
    }

    // Run blocks until window closes
    first_window.run();

    // Remove from list
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.windows.items, 0..) |w, i| {
            if (w == &first_window) {
                _ = self.windows.swapRemove(i);
                break;
            }
        }
    }

    // Wait for all spawned window threads to finish
    self.joinAllWindowThreads();
}

/// Request a new window to be spawned on a separate thread.
/// Called from Ctrl+Shift+N in any window.
/// If parent_hwnd is provided, the new window will cascade from that position.
/// If cwd is provided, the new window's first tab will start in that directory.
pub fn requestNewWindow(self: *App, parent_hwnd: ?win32_backend.HWND, cwd: ?[]const u16) void {
    self.mutex.lock();

    // Get parent window position for cascading
    if (parent_hwnd) |hwnd| {
        var rect: win32_backend.RECT = undefined;
        if (win32_backend.GetWindowRect(hwnd, &rect) != 0) {
            const new_x = rect.left + 30;
            const new_y = rect.top + 30;
            // Validate that the new position is on a visible monitor
            const pt = win32_backend.POINT{ .x = new_x + 50, .y = new_y + 50 };
            const monitor = MonitorFromPoint(pt, 0); // MONITOR_DEFAULTTONULL
            if (monitor != null) {
                self.next_window_x = new_x;
                self.next_window_y = new_y;
            }
            // If off-screen, don't set position - window will use default
        }
    }

    // Store CWD for new window
    if (cwd) |dir| {
        const len = @min(dir.len, self.next_window_cwd.len - 1);
        @memcpy(self.next_window_cwd[0..len], dir[0..len]);
        self.next_window_cwd[len] = 0;
        self.next_window_cwd_len = len;
    } else {
        self.next_window_cwd_len = 0;
    }

    self.mutex.unlock();

    const thread = std.Thread.spawn(.{}, windowThreadMain, .{self}) catch |err| {
        std.debug.print("Failed to spawn window thread: {}\n", .{err});
        return;
    };

    // Track the thread so we can join it later
    self.mutex.lock();
    defer self.mutex.unlock();
    self.window_threads.append(self.allocator, thread) catch {
        std.debug.print("Failed to track window thread\n", .{});
        // Thread will still run, just won't be joined properly
    };
}

/// Thread entry point for spawned windows.
fn windowThreadMain(app: *App) void {
    // Initialize COM for this thread (required for DirectWrite)
    const ole32 = std.os.windows.kernel32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ole32.dll"));
    var co_initialized = false;
    if (ole32) |h| {
        const CoInit = std.os.windows.kernel32.GetProcAddress(h, "CoInitializeEx");
        if (CoInit) |f| {
            const coInitFn: *const fn (?*anyopaque, u32) callconv(.winapi) i32 = @ptrCast(f);
            const hr = coInitFn(null, 0x0); // COINIT_MULTITHREADED
            co_initialized = (hr >= 0);
        }
    }
    defer if (co_initialized) {
        if (ole32) |h| {
            const CoUninit = std.os.windows.kernel32.GetProcAddress(h, "CoUninitialize");
            if (CoUninit) |f| {
                const coUninitFn: *const fn () callconv(.winapi) void = @ptrCast(f);
                coUninitFn();
            }
        }
    };

    std.debug.print("Window thread started\n", .{});

    // Create the window
    var window = AppWindow.init(app.allocator, app) catch |err| {
        std.debug.print("Failed to create window: {}\n", .{err});
        return;
    };
    defer window.deinit();

    // Add to window list
    {
        app.mutex.lock();
        defer app.mutex.unlock();
        app.windows.append(app.allocator, &window) catch {
            std.debug.print("Failed to add window to list\n", .{});
        };
    }

    // Run the window (blocks until closed)
    window.run();

    // Remove from list
    {
        app.mutex.lock();
        defer app.mutex.unlock();
        for (app.windows.items, 0..) |w, i| {
            if (w == &window) {
                _ = app.windows.swapRemove(i);
                break;
            }
        }
    }

    std.debug.print("Window thread exiting\n", .{});
}

/// Wait for all spawned window threads to finish.
fn joinAllWindowThreads(self: *App) void {
    // Take ownership of the thread list
    self.mutex.lock();
    const threads = self.window_threads.toOwnedSlice(self.allocator) catch {
        self.mutex.unlock();
        return;
    };
    self.mutex.unlock();

    defer self.allocator.free(threads);

    for (threads) |thread| {
        thread.join();
    }
}

// ============================================================================
// Shutdown
// ============================================================================

/// Request all windows to close. Posts WM_CLOSE to each window's HWND.
/// Windows will exit their run loops and threads will terminate.
pub fn requestShutdown(self: *App) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.windows.items) |window| {
        if (window.getHwnd()) |hwnd| {
            // Post WM_CLOSE (0x0010) to the window
            _ = win32_backend.PostMessageW(hwnd, 0x0010, 0, 0);
        }
    }
}

// ============================================================================
// Cleanup
// ============================================================================

pub fn deinit(self: *App) void {
    // Join any remaining threads
    self.joinAllWindowThreads();

    self.windows.deinit(self.allocator);
    self.window_threads.deinit(self.allocator);
}
