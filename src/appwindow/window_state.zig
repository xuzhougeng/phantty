//! Window state persistence — save/restore window position across sessions.
//!
//! Saves the window position to a state file in the user's config directory
//! and restores it on next launch. Validates that the saved position is
//! on a visible monitor before applying.

const std = @import("std");
const win32_backend = @import("../win32.zig");

/// Saved window position state.
pub const WindowState = struct {
    x: i32,
    y: i32,
};

// Saved windowed position for restore (used by window state persistence)
pub threadlocal var g_windowed_x: c_int = 0;
pub threadlocal var g_windowed_y: c_int = 0;

/// Return the state file path: %APPDATA%\phantty\state
pub fn stateFilePath(allocator: std.mem.Allocator) ?[]const u8 {
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
pub fn loadWindowState(allocator: std.mem.Allocator) ?WindowState {
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
pub fn saveWindowState(allocator: std.mem.Allocator, state: WindowState) void {
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
