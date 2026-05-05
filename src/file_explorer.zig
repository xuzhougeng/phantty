//! File Explorer state and directory tree model.
//!
//! Manages the right-side file explorer sidebar: visibility, width, directory
//! scanning, tree expand/collapse, selection, scroll, and file operations.
//! Supports both local (std.fs) and remote (ssh ls / scp) modes.

const std = @import("std");
const Surface = @import("Surface.zig");
const scp = @import("scp.zig");

pub const DEFAULT_WIDTH: f32 = 240;
pub const MIN_WIDTH: f32 = 160;
pub const MAX_WIDTH: f32 = 420;
pub const MIN_CONTENT_WIDTH: f32 = 240;
pub const RESIZE_HIT_WIDTH: f32 = 8;
pub const ROW_HEIGHT: f32 = 24;
pub const HEADER_HEIGHT: f32 = 36;
pub const INDENT_WIDTH: f32 = 16;

pub const Mode = enum { local, remote };

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;
pub threadlocal var g_focused: bool = false;
pub threadlocal var g_mode: Mode = .local;

// Remote SSH connection state (copied from surface when entering remote mode)
pub threadlocal var g_ssh_conn: Surface.SshConnection = .{};
pub threadlocal var g_has_ssh_conn: bool = false;

// Transfer status
pub threadlocal var g_transfer_status: TransferStatus = .idle;
pub threadlocal var g_transfer_msg: [128]u8 = undefined;
pub threadlocal var g_transfer_msg_len: u8 = 0;
pub threadlocal var g_transfer_time: i64 = 0;

pub const TransferStatus = enum { idle, in_progress, success, failed };

// Scroll state
pub threadlocal var g_scroll_offset: f32 = 0;

// Selection state (index into flattened visible entries)
pub threadlocal var g_selected: ?usize = null;

// Root directory (UTF-8 path)
pub threadlocal var g_root_path: [260]u8 = undefined;
pub threadlocal var g_root_path_len: usize = 0;

// Flat list of currently visible entries (rebuilt on expand/collapse/rescan)
pub threadlocal var g_entries: [2048]FlatEntry = undefined;
pub threadlocal var g_entry_count: usize = 0;

pub const FlatEntry = struct {
    name_buf: [256]u8 = undefined,
    name_len: u8 = 0,
    is_dir: bool = false,
    expanded: bool = false,
    depth: u16 = 0,
    // Full relative path for operations
    path_buf: [512]u8 = undefined,
    path_len: u16 = 0,
};

pub fn width() f32 {
    return if (g_visible) g_width else 0;
}

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

pub fn clampWidth(w: f32, window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(maxWidthForWindow(window_width), w));
}

pub fn setWidth(w: f32, window_width: f32) bool {
    const next = clampWidth(w, window_width);
    if (next == g_width) return false;
    g_width = next;
    return true;
}

pub fn toggle() void {
    g_visible = !g_visible;
    if (g_visible and g_entry_count == 0) {
        if (g_mode == .remote and g_has_ssh_conn) {
            rescanRemote();
        } else {
            rescan();
        }
    }
}

/// Enter remote mode with the given SSH connection.
pub fn enterRemoteMode(conn: *const Surface.SshConnection, remote_cwd: []const u8) void {
    g_mode = .remote;
    g_ssh_conn = conn.*;
    g_has_ssh_conn = true;
    setRoot(remote_cwd);
}

/// Switch back to local mode.
pub fn enterLocalMode() void {
    g_mode = .local;
    g_has_ssh_conn = false;
    g_entry_count = 0;
    g_root_path_len = 0;
}

pub fn setRoot(path: []const u8) void {
    const len = @min(path.len, g_root_path.len);
    @memcpy(g_root_path[0..len], path[0..len]);
    g_root_path_len = len;
    if (g_mode == .remote and g_has_ssh_conn) {
        rescanRemote();
    } else {
        rescan();
    }
}

pub fn rescan() void {
    g_entry_count = 0;
    g_scroll_offset = 0;
    g_selected = null;

    if (g_mode == .remote and g_has_ssh_conn) {
        rescanRemote();
        return;
    }

    if (g_root_path_len == 0) return;

    const path = g_root_path[0..g_root_path_len];
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    scanDir(&dir, 0, path);
}

/// Scan remote directory via `ssh ls -1paF`.
pub fn rescanRemote() void {
    g_entry_count = 0;
    g_scroll_offset = 0;
    g_selected = null;

    if (!g_has_ssh_conn) return;
    if (g_root_path_len == 0) return;

    const path = g_root_path[0..g_root_path_len];

    // Build command: ls -1p <path> (no -a to skip dotfiles, -p appends / to dirs)
    var cmd_buf: [320]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "ls -1p {s}", .{path}) catch return;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const output = scp.sshExec(allocator, &g_ssh_conn, cmd) orelse return;
    defer allocator.free(output);

    parseRemoteLsOutput(output, 0, path);
}

fn parseRemoteLsOutput(output: []const u8, depth: u16, parent_path: []const u8) void {
    var line_start: usize = 0;
    for (output, 0..) |ch, i| {
        if (ch == '\n') {
            var line = output[line_start..i];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len > 0) {
                addRemoteEntry(line, depth, parent_path);
            }
            line_start = i + 1;
        }
    }
    // Last line without newline
    if (line_start < output.len) {
        var line = output[line_start..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > 0) {
            addRemoteEntry(line, depth, parent_path);
        }
    }

    // Sort entries at this depth
    sortEntries(depth);
}

fn addRemoteEntry(line: []const u8, depth: u16, parent_path: []const u8) void {
    if (g_entry_count >= g_entries.len) return;
    // Skip . and ..
    const is_dir = line.len > 0 and line[line.len - 1] == '/';
    const name = if (is_dir) line[0 .. line.len - 1] else line;
    if (name.len == 0) return;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return;

    var e = &g_entries[g_entry_count];
    const name_len: u8 = @intCast(@min(name.len, 255));
    @memcpy(e.name_buf[0..name_len], name[0..name_len]);
    e.name_len = name_len;
    e.is_dir = is_dir;
    e.expanded = false;
    e.depth = depth;

    // Build remote path: parent/name
    const plen = @as(u16, @intCast(parent_path.len));
    @memcpy(e.path_buf[0..plen], parent_path);
    e.path_buf[plen] = '/';
    @memcpy(e.path_buf[plen + 1 ..][0..name_len], name[0..name_len]);
    e.path_len = plen + 1 + name_len;

    g_entry_count += 1;
}

fn scanDir(dir: *std.fs.Dir, depth: u16, parent_path: []const u8) void {
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (g_entry_count >= g_entries.len) break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        var e = &g_entries[g_entry_count];
        const name_len: u8 = @intCast(@min(entry.name.len, 255));
        @memcpy(e.name_buf[0..name_len], entry.name[0..name_len]);
        e.name_len = name_len;
        e.is_dir = entry.kind == .directory;
        e.expanded = false;
        e.depth = depth;

        // Build relative path
        const sep_len: u16 = if (parent_path.len > 0) 1 else 0;
        const total_path_len = @as(u16, @intCast(@min(parent_path.len + sep_len + name_len, 511)));
        if (parent_path.len > 0) {
            @memcpy(e.path_buf[0..parent_path.len], parent_path);
            e.path_buf[parent_path.len] = '\\';
            @memcpy(e.path_buf[parent_path.len + 1 ..][0..name_len], entry.name[0..name_len]);
        } else {
            @memcpy(e.path_buf[0..name_len], entry.name[0..name_len]);
        }
        e.path_len = total_path_len;

        g_entry_count += 1;
    }

    // Sort: directories first, then alphabetical
    if (g_entry_count > 0) {
        sortEntries(depth);
    }
}

fn sortEntries(depth: u16) void {
    // Find range of entries at this depth that were just added
    var start: usize = g_entry_count;
    var i: usize = g_entry_count;
    while (i > 0) {
        i -= 1;
        if (g_entries[i].depth == depth) {
            start = i;
        } else break;
    }
    if (start >= g_entry_count) return;

    const slice = g_entries[start..g_entry_count];
    std.sort.insertion(FlatEntry, slice, {}, lessThan);
}

fn lessThan(_: void, a: FlatEntry, b: FlatEntry) bool {
    if (a.is_dir and !b.is_dir) return true;
    if (!a.is_dir and b.is_dir) return false;
    const a_name = a.name_buf[0..a.name_len];
    const b_name = b.name_buf[0..b.name_len];
    return std.mem.order(u8, a_name, b_name) == .lt;
}

pub fn toggleExpand(idx: usize) void {
    if (idx >= g_entry_count) return;
    if (!g_entries[idx].is_dir) return;

    if (g_entries[idx].expanded) {
        collapse(idx);
    } else {
        if (g_mode == .remote and g_has_ssh_conn) {
            expandRemote(idx);
        } else {
            expand(idx);
        }
    }
}

fn expandRemote(idx: usize) void {
    const entry = &g_entries[idx];
    entry.expanded = true;

    const path = entry.path_buf[0..entry.path_len];
    const child_depth = entry.depth + 1;

    // Build command
    var cmd_buf: [560]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "ls -1p {s}", .{path}) catch return;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const output = scp.sshExec(allocator, &g_ssh_conn, cmd) orelse return;
    defer allocator.free(output);

    // Count entries to insert
    const insert_pos = idx + 1;
    const max_new = g_entries.len - g_entry_count;
    if (max_new == 0) return;

    // Parse into tail of array, then move into place (same pattern as local expand)
    const old_count = g_entry_count;
    var filled: usize = 0;

    var line_start: usize = 0;
    for (output, 0..) |ch, i| {
        if (ch == '\n') {
            var line = output[line_start..i];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len > 0 and filled < max_new) {
                if (addRemoteEntryAtTail(line, child_depth, path, old_count + filled))
                    filled += 1;
            }
            line_start = i + 1;
        }
    }
    if (line_start < output.len and filled < max_new) {
        var line = output[line_start..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > 0) {
            if (addRemoteEntryAtTail(line, child_depth, path, old_count + filled))
                filled += 1;
        }
    }

    if (filled == 0) return;

    // Sort tail entries
    std.sort.insertion(FlatEntry, g_entries[old_count .. old_count + filled], {}, lessThan);

    // Shift existing entries after insert_pos down
    if (insert_pos < old_count) {
        var j: usize = old_count - 1;
        while (true) {
            g_entries[j + filled] = g_entries[j];
            if (j == insert_pos) break;
            j -= 1;
        }
    }

    // Copy from tail to insert position
    for (0..filled) |fi| {
        g_entries[insert_pos + fi] = g_entries[old_count + fi];
    }

    g_entry_count += filled;
}

fn addRemoteEntryAtTail(line: []const u8, depth: u16, parent_path: []const u8, target_idx: usize) bool {
    const is_dir = line.len > 0 and line[line.len - 1] == '/';
    const name = if (is_dir) line[0 .. line.len - 1] else line;
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;

    var e = &g_entries[target_idx];
    const name_len: u8 = @intCast(@min(name.len, 255));
    @memcpy(e.name_buf[0..name_len], name[0..name_len]);
    e.name_len = name_len;
    e.is_dir = is_dir;
    e.expanded = false;
    e.depth = depth;

    const plen = @as(u16, @intCast(parent_path.len));
    @memcpy(e.path_buf[0..plen], parent_path);
    e.path_buf[plen] = '/';
    @memcpy(e.path_buf[plen + 1 ..][0..name_len], name[0..name_len]);
    e.path_len = plen + 1 + name_len;

    return true;
}

fn expand(idx: usize) void {
    const entry = &g_entries[idx];
    entry.expanded = true;

    const path = entry.path_buf[0..entry.path_len];
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    const child_depth = entry.depth + 1;
    const insert_pos = idx + 1;
    const max_new = g_entries.len - g_entry_count;
    if (max_new == 0) return;

    // Collect children into the tail of the entries array temporarily
    var filled: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |child| {
        if (filled >= max_new) break;
        if (child.name.len == 0 or child.name[0] == '.') continue;

        // Use temp storage at the end
        const tmp_idx = g_entry_count + filled;
        var e = &g_entries[tmp_idx];
        const name_len: u8 = @intCast(@min(child.name.len, 255));
        @memcpy(e.name_buf[0..name_len], child.name[0..name_len]);
        e.name_len = name_len;
        e.is_dir = child.kind == .directory;
        e.expanded = false;
        e.depth = child_depth;

        // Build path: parent_path + \ + name
        const parent_path = entry.path_buf[0..entry.path_len];
        const plen = @as(u16, @intCast(parent_path.len));
        @memcpy(e.path_buf[0..plen], parent_path);
        e.path_buf[plen] = '\\';
        @memcpy(e.path_buf[plen + 1 ..][0..name_len], child.name[0..name_len]);
        e.path_len = plen + 1 + name_len;

        filled += 1;
    }

    if (filled == 0) return;

    // Sort the collected children (at tail)
    std.sort.insertion(FlatEntry, g_entries[g_entry_count .. g_entry_count + filled], {}, lessThan);

    // Shift existing entries after insert_pos down by `filled`
    if (insert_pos < g_entry_count) {
        var j: usize = g_entry_count - 1;
        while (true) {
            g_entries[j + filled] = g_entries[j];
            if (j == insert_pos) break;
            j -= 1;
        }
    }

    // Copy from tail temp to insert position
    for (0..filled) |fi| {
        g_entries[insert_pos + fi] = g_entries[g_entry_count + fi];
    }

    g_entry_count += filled;
}

fn collapse(idx: usize) void {
    var entry = &g_entries[idx];
    entry.expanded = false;

    // Remove all entries after idx with depth > entry.depth
    const base_depth = entry.depth;
    var end = idx + 1;
    while (end < g_entry_count and g_entries[end].depth > base_depth) {
        end += 1;
    }

    const remove_count = end - (idx + 1);
    if (remove_count == 0) return;

    // Shift remaining entries up
    const remaining = g_entry_count - end;
    var k: usize = 0;
    while (k < remaining) : (k += 1) {
        g_entries[idx + 1 + k] = g_entries[end + k];
    }
    g_entry_count -= remove_count;

    // Adjust selection
    if (g_selected) |sel| {
        if (sel > idx and sel < end) {
            g_selected = idx;
        } else if (sel >= end) {
            g_selected = sel - remove_count;
        }
    }
}

pub fn scrollBy(delta: f32) void {
    const max_scroll = maxScroll();
    g_scroll_offset = @max(0, @min(max_scroll, g_scroll_offset + delta));
}

fn maxScroll() f32 {
    const total_h = @as(f32, @floatFromInt(g_entry_count)) * ROW_HEIGHT;
    return @max(0, total_h - 400);
}

// ============================================================================
// File Operations
// ============================================================================

pub const OpMode = enum { none, rename, new_file, new_dir, confirm_delete };

pub threadlocal var g_op_mode: OpMode = .none;
pub threadlocal var g_input_buf: [256]u8 = undefined;
pub threadlocal var g_input_len: u8 = 0;

pub fn startRename() void {
    const sel = g_selected orelse return;
    if (sel >= g_entry_count) return;
    g_op_mode = .rename;
    const entry = &g_entries[sel];
    @memcpy(g_input_buf[0..entry.name_len], entry.name_buf[0..entry.name_len]);
    g_input_len = entry.name_len;
}

pub fn startNewFile() void {
    g_op_mode = .new_file;
    g_input_len = 0;
}

pub fn startNewDir() void {
    g_op_mode = .new_dir;
    g_input_len = 0;
}

pub fn startDelete() void {
    if (g_selected == null) return;
    g_op_mode = .confirm_delete;
}

pub fn cancelOp() void {
    g_op_mode = .none;
    g_input_len = 0;
}

pub fn commitOp() void {
    switch (g_op_mode) {
        .rename => commitRename(),
        .new_file => commitNewFile(),
        .new_dir => commitNewDir(),
        .confirm_delete => commitDelete(),
        .none => {},
    }
    g_op_mode = .none;
    g_input_len = 0;
}

fn commitRename() void {
    const sel = g_selected orelse return;
    if (sel >= g_entry_count) return;
    if (g_input_len == 0) return;

    const entry = &g_entries[sel];
    const old_path = entry.path_buf[0..entry.path_len];
    const new_name = g_input_buf[0..g_input_len];

    // Build new path: parent dir + new name
    var new_path_buf: [512]u8 = undefined;
    const parent_end = blk: {
        var i: usize = old_path.len;
        while (i > 0) {
            i -= 1;
            if (old_path[i] == '\\' or old_path[i] == '/') break :blk i + 1;
        }
        break :blk 0;
    };
    @memcpy(new_path_buf[0..parent_end], old_path[0..parent_end]);
    @memcpy(new_path_buf[parent_end..][0..new_name.len], new_name);
    const new_path = new_path_buf[0 .. parent_end + new_name.len];

    // Perform rename via std.fs
    const cwd = std.fs.cwd();
    cwd.rename(old_path, new_path) catch return;

    rescan();
}

fn commitNewFile() void {
    if (g_input_len == 0) return;
    const new_name = g_input_buf[0..g_input_len];
    const parent = getSelectedParentPath();

    var path_buf: [512]u8 = undefined;
    const path = buildChildPath(&path_buf, parent, new_name);

    const cwd = std.fs.cwd();
    const file = cwd.createFile(path, .{}) catch return;
    file.close();

    rescan();
}

fn commitNewDir() void {
    if (g_input_len == 0) return;
    const new_name = g_input_buf[0..g_input_len];
    const parent = getSelectedParentPath();

    var path_buf: [512]u8 = undefined;
    const path = buildChildPath(&path_buf, parent, new_name);

    const cwd = std.fs.cwd();
    cwd.makeDir(path) catch return;

    rescan();
}

fn commitDelete() void {
    const sel = g_selected orelse return;
    if (sel >= g_entry_count) return;

    const entry = &g_entries[sel];
    const path = entry.path_buf[0..entry.path_len];

    const cwd = std.fs.cwd();
    if (entry.is_dir) {
        cwd.deleteTree(path) catch return;
    } else {
        cwd.deleteFile(path) catch return;
    }

    rescan();
}

fn getSelectedParentPath() []const u8 {
    if (g_selected) |sel| {
        if (sel < g_entry_count) {
            const entry = &g_entries[sel];
            if (entry.is_dir and entry.expanded) {
                return entry.path_buf[0..entry.path_len];
            }
            // Use parent directory of selected item
            const path = entry.path_buf[0..entry.path_len];
            var i: usize = path.len;
            while (i > 0) {
                i -= 1;
                if (path[i] == '\\' or path[i] == '/') return path[0..i];
            }
        }
    }
    return g_root_path[0..g_root_path_len];
}

fn buildChildPath(buf: *[512]u8, parent: []const u8, name: []const u8) []const u8 {
    @memcpy(buf[0..parent.len], parent);
    buf[parent.len] = '\\';
    @memcpy(buf[parent.len + 1 ..][0..name.len], name);
    return buf[0 .. parent.len + 1 + name.len];
}

pub fn inputChar(cp: u21) void {
    if (g_op_mode == .none or g_op_mode == .confirm_delete) return;
    if (g_input_len >= 255) return;
    // Encode codepoint to UTF-8
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return;
    if (@as(usize, g_input_len) + len > 255) return;
    @memcpy(g_input_buf[g_input_len..][0..len], buf[0..len]);
    g_input_len += @intCast(len);
}

pub fn inputBackspace() void {
    if (g_op_mode == .none or g_op_mode == .confirm_delete) return;
    if (g_input_len == 0) return;
    // Remove last UTF-8 char
    var i: u8 = g_input_len - 1;
    while (i > 0 and (g_input_buf[i] & 0xC0) == 0x80) i -= 1;
    g_input_len = i;
}

pub fn moveSelection(delta: i32) void {
    if (g_entry_count == 0) return;
    if (g_selected) |sel| {
        const new = @as(i32, @intCast(sel)) + delta;
        g_selected = @intCast(@max(0, @min(@as(i32, @intCast(g_entry_count - 1)), new)));
    } else {
        g_selected = 0;
    }
    ensureSelectedVisible();
}

fn ensureSelectedVisible() void {
    const sel = g_selected orelse return;
    const sel_top = @as(f32, @floatFromInt(sel)) * ROW_HEIGHT;
    if (sel_top < g_scroll_offset) {
        g_scroll_offset = sel_top;
    } else if (sel_top + ROW_HEIGHT > g_scroll_offset + 400) {
        g_scroll_offset = sel_top + ROW_HEIGHT - 400;
    }
}

// ============================================================================
// SCP Transfer Operations
// ============================================================================

fn setTransferStatus(status: TransferStatus, msg: []const u8) void {
    g_transfer_status = status;
    g_transfer_msg_len = @intCast(@min(msg.len, g_transfer_msg.len));
    @memcpy(g_transfer_msg[0..g_transfer_msg_len], msg[0..g_transfer_msg_len]);
    g_transfer_time = std.time.milliTimestamp();
}

/// Download the selected remote file to a local directory.
pub fn downloadSelected(local_dir: []const u8) void {
    if (g_mode != .remote or !g_has_ssh_conn) return;
    const sel = g_selected orelse return;
    if (sel >= g_entry_count) return;

    const entry = &g_entries[sel];
    if (entry.is_dir) return; // Only download files

    const remote_path = entry.path_buf[0..entry.path_len];

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build remote spec: user@host:path
    var spec_buf: [512]u8 = undefined;
    const src = scp.remoteSpec(&spec_buf, &g_ssh_conn, remote_path);

    // Destination: local_dir\filename
    var dst_buf: [512]u8 = undefined;
    const name = entry.name_buf[0..entry.name_len];
    const dst = std.fmt.bufPrint(&dst_buf, "{s}\\{s}", .{ local_dir, name }) catch return;

    setTransferStatus(.in_progress, name);

    const result = scp.transfer(allocator, &g_ssh_conn, src, dst);
    switch (result) {
        .ok => setTransferStatus(.success, name),
        else => setTransferStatus(.failed, name),
    }
}

/// Upload a local file to the current remote directory.
pub fn uploadFile(local_path: []const u8) void {
    if (g_mode != .remote or !g_has_ssh_conn) return;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Destination: current remote dir
    const remote_dir = g_root_path[0..g_root_path_len];

    var spec_buf: [512]u8 = undefined;
    const dst = scp.remoteSpec(&spec_buf, &g_ssh_conn, remote_dir);

    // Extract filename for status
    var name_start: usize = 0;
    for (local_path, 0..) |ch, i| {
        if (ch == '\\' or ch == '/') name_start = i + 1;
    }
    const filename = local_path[name_start..];

    setTransferStatus(.in_progress, filename);

    const result = scp.transfer(allocator, &g_ssh_conn, local_path, dst);
    switch (result) {
        .ok => {
            setTransferStatus(.success, filename);
            rescanRemote();
        },
        else => setTransferStatus(.failed, filename),
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parseRemoteLsOutput basic entries" {
    // Reset state
    g_entry_count = 0;
    g_scroll_offset = 0;
    g_selected = null;

    const output = "documents/\nreadme.txt\nscripts/\n";
    parseRemoteLsOutput(output, 0, "/home/user");

    // After sorting: dirs first then files
    try std.testing.expectEqual(@as(usize, 3), g_entry_count);

    // dirs sorted: documents, scripts; then files: readme.txt
    try std.testing.expectEqualStrings("documents", g_entries[0].name_buf[0..g_entries[0].name_len]);
    try std.testing.expect(g_entries[0].is_dir);
    try std.testing.expectEqualStrings("scripts", g_entries[1].name_buf[0..g_entries[1].name_len]);
    try std.testing.expect(g_entries[1].is_dir);
    try std.testing.expectEqualStrings("readme.txt", g_entries[2].name_buf[0..g_entries[2].name_len]);
    try std.testing.expect(!g_entries[2].is_dir);
}

test "parseRemoteLsOutput skips . and .." {
    g_entry_count = 0;
    const output = "./\n../\nfoo.txt\n";
    parseRemoteLsOutput(output, 0, "/tmp");
    try std.testing.expectEqual(@as(usize, 1), g_entry_count);
    try std.testing.expectEqualStrings("foo.txt", g_entries[0].name_buf[0..g_entries[0].name_len]);
}

test "parseRemoteLsOutput handles CRLF" {
    g_entry_count = 0;
    const output = "alpha/\r\nbeta.txt\r\n";
    parseRemoteLsOutput(output, 0, "/data");
    try std.testing.expectEqual(@as(usize, 2), g_entry_count);
    try std.testing.expectEqualStrings("alpha", g_entries[0].name_buf[0..g_entries[0].name_len]);
    try std.testing.expect(g_entries[0].is_dir);
    try std.testing.expectEqualStrings("beta.txt", g_entries[1].name_buf[0..g_entries[1].name_len]);
}

test "parseRemoteLsOutput path construction" {
    g_entry_count = 0;
    const output = "sub/\nfile.log\n";
    parseRemoteLsOutput(output, 0, "/var/log");

    // Check path of first entry
    const path0 = g_entries[0].path_buf[0..g_entries[0].path_len];
    try std.testing.expectEqualStrings("/var/log/sub", path0);

    const path1 = g_entries[1].path_buf[0..g_entries[1].path_len];
    try std.testing.expectEqualStrings("/var/log/file.log", path1);
}

test "addRemoteEntry empty and dot entries rejected" {
    g_entry_count = 0;
    addRemoteEntry("", 0, "/x");
    try std.testing.expectEqual(@as(usize, 0), g_entry_count);

    addRemoteEntry("./", 0, "/x");
    try std.testing.expectEqual(@as(usize, 0), g_entry_count);

    addRemoteEntry("../", 0, "/x");
    try std.testing.expectEqual(@as(usize, 0), g_entry_count);
}

test "setTransferStatus stores message" {
    setTransferStatus(.success, "test_file.txt");
    try std.testing.expectEqual(TransferStatus.success, g_transfer_status);
    try std.testing.expectEqualStrings("test_file.txt", g_transfer_msg[0..g_transfer_msg_len]);
}

test "Mode enum values" {
    try std.testing.expectEqual(Mode.local, .local);
    try std.testing.expectEqual(Mode.remote, .remote);
    // Default state
    g_mode = .local;
    try std.testing.expect(!g_has_ssh_conn);
}
