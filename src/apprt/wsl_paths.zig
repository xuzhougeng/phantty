//! WSL path conversion utilities.
//!
//! Converts between Unix-style paths and Windows paths for WSL interop.
//! Handles /mnt/X/... → X:\... and /home/... → \\wsl.localhost\<distro>\... paths.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");

/// Convert a Unix-style path to a Windows path (UTF-16).
/// Handles:
///   /mnt/c/Users/... -> C:\Users\...
///   /home/user/...   -> \\wsl.localhost\<distro>\home\user\...
/// Returns the length of the converted path, or null if conversion failed.
pub fn unixPathToWindows(unix_path: []const u8, out: *[260]u16) ?usize {
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
    const allocator = AppWindow.g_allocator orelse return null;

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
