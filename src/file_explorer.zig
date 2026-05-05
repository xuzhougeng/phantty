//! File Explorer state and directory tree model.
//!
//! Manages the right-side file explorer sidebar: visibility, width, directory
//! scanning, tree expand/collapse, selection, scroll, and file operations.
//! Supports both local (std.fs) and remote (ssh ls / scp) modes.

const std = @import("std");
const Surface = @import("Surface.zig");
const scp = @import("scp.zig");
const file_backend = @import("file_backend.zig");

pub const DEFAULT_WIDTH: f32 = 240;
pub const MIN_WIDTH: f32 = 160;
pub const MAX_WIDTH: f32 = 420;
pub const MIN_CONTENT_WIDTH: f32 = 240;
pub const RESIZE_HIT_WIDTH: f32 = 8;
pub const ROW_HEIGHT: f32 = 24;
pub const HEADER_HEIGHT: f32 = 36;
pub const INDENT_WIDTH: f32 = 16;
pub const MAX_ENTRIES: usize = 2048;

pub const Mode = enum { local, remote };

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;
pub threadlocal var g_focused: bool = false;
pub threadlocal var g_mode: Mode = .local;
pub threadlocal var g_row_height: f32 = ROW_HEIGHT;
pub threadlocal var g_header_height: f32 = HEADER_HEIGHT;

// Remote SSH connection state (copied from surface when entering remote mode)
pub threadlocal var g_ssh_conn: Surface.SshConnection = .{};
pub threadlocal var g_has_ssh_conn: bool = false;

// Transfer status
pub threadlocal var g_transfer_status: TransferStatus = .idle;
pub threadlocal var g_transfer_msg: [128]u8 = undefined;
pub threadlocal var g_transfer_msg_len: u8 = 0;
pub threadlocal var g_transfer_time: i64 = 0;
pub threadlocal var g_loading: bool = false;
pub threadlocal var g_loading_msg: [128]u8 = undefined;
pub threadlocal var g_loading_msg_len: u8 = 0;

pub const TransferStatus = enum { idle, in_progress, success, failed };

// Scroll state
pub threadlocal var g_scroll_offset: f32 = 0;

// Selection state (index into flattened visible entries)
pub threadlocal var g_selected: ?usize = null;

// Root directory (UTF-8 path)
pub threadlocal var g_root_path: [260]u8 = undefined;
pub threadlocal var g_root_path_len: usize = 0;

// Flat list of currently visible entries (rebuilt on expand/collapse/rescan)
pub threadlocal var g_entries: [MAX_ENTRIES]FlatEntry = undefined;
pub threadlocal var g_entry_count: usize = 0;

const AsyncListKind = enum { rescan, expand };

const AsyncListJob = struct {
    kind: AsyncListKind,
    conn: Surface.SshConnection,
    context_id: u64,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,
    depth: u16 = 0,
    resolve_root: bool = false,
    root_buf: [512]u8 = undefined,
    root_len: usize = 0,
    entries: []file_backend.Entry,
    status: file_backend.ListStatus = .ssh_failed,
    count: usize = 0,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

const PendingAsyncList = struct {
    kind: AsyncListKind,
    context_id: u64,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,
    depth: u16 = 0,
    resolve_root: bool = false,
};

const AsyncListStart = enum { started, queued, blocked };

threadlocal var g_async_job: ?*AsyncListJob = null;
threadlocal var g_pending_async_list: ?PendingAsyncList = null;
threadlocal var g_async_context_id: u64 = 1;

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

pub fn syncLayoutMetrics(text_height: f32) void {
    g_row_height = @max(ROW_HEIGHT, @round(text_height + 8));
    g_header_height = @max(HEADER_HEIGHT, @round(text_height + 16));
}

pub fn rowHeight() f32 {
    return g_row_height;
}

pub fn headerHeight() f32 {
    return g_header_height;
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
}

/// Enter remote mode with the given SSH connection.
pub fn enterRemoteMode(conn: *const Surface.SshConnection, remote_cwd: []const u8) void {
    g_async_context_id +%= 1;
    g_mode = .remote;
    g_ssh_conn = conn.*;
    g_has_ssh_conn = true;
    if (remote_cwd.len > 0) {
        setRoot(remote_cwd);
    } else {
        g_root_path_len = 0;
        rescanRemote();
    }
}

/// Switch back to local mode.
pub fn enterLocalMode() void {
    g_async_context_id +%= 1;
    g_pending_async_list = null;
    g_loading = false;
    g_mode = .local;
    g_has_ssh_conn = false;
    g_entry_count = 0;
    g_root_path_len = 0;
}

pub fn setRoot(path: []const u8) void {
    g_async_context_id +%= 1;
    const len = @min(path.len, g_root_path.len);
    @memcpy(g_root_path[0..len], path[0..len]);
    g_root_path_len = len;
    if (g_mode == .remote and g_has_ssh_conn) {
        rescanRemote();
    } else {
        rescan();
    }
}

pub fn tickAsync() void {
    const job = g_async_job orelse return;
    if (!job.done.load(.acquire)) return;

    if (job.thread) |thread| thread.join();
    g_async_job = null;
    g_loading = false;
    defer maybeStartPendingAsyncList();
    defer destroyAsyncJob(job);

    if (job.context_id != g_async_context_id or g_mode != .remote or !g_has_ssh_conn) {
        return;
    }

    if (job.status != .ok) {
        setTransferStatus(.failed, if (job.resolve_root) "SSH pwd failed" else "SSH list failed");
        if (job.kind == .expand) {
            if (findEntryByPath(job.path_buf[0..job.path_len])) |idx| {
                g_entries[idx].expanded = false;
            }
        }
        return;
    }

    switch (job.kind) {
        .rescan => {
            if (job.resolve_root) {
                const root_len = @min(job.root_len, g_root_path.len);
                @memcpy(g_root_path[0..root_len], job.root_buf[0..root_len]);
                g_root_path_len = root_len;
            }
            g_entry_count = 0;
            g_scroll_offset = 0;
            g_selected = null;
            const root = g_root_path[0..g_root_path_len];
            _ = insertBackendChildren(0, job.entries[0..job.count], 0, root, '/');
        },
        .expand => {
            const path = job.path_buf[0..job.path_len];
            const idx = findEntryByPath(path) orelse return;
            if (!g_entries[idx].expanded) return;
            _ = insertBackendChildren(idx + 1, job.entries[0..job.count], job.depth, path, '/');
        },
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
    const result = loadBackendEntries(.local, path, 0, path, '\\');
    if (result != .ok) {
        setTransferStatus(.failed, "Cannot open folder");
    }
}

/// Scan remote directory via the configured SSH backend.
pub fn rescanRemote() void {
    g_entry_count = 0;
    g_scroll_offset = 0;
    g_selected = null;

    if (!g_has_ssh_conn) return;

    if (g_root_path_len == 0) {
        if (startAsyncList(.rescan, "", 0, true) == .blocked) {
            setTransferStatus(.failed, "SSH list busy");
        }
        return;
    }

    const path = g_root_path[0..g_root_path_len];
    if (startAsyncList(.rescan, path, 0, false) == .blocked) {
        setTransferStatus(.failed, "SSH list busy");
    }
}

fn loadBackendEntries(
    backend: file_backend.Backend,
    path: []const u8,
    depth: u16,
    parent_path: []const u8,
    sep: u8,
) file_backend.ListStatus {
    const capacity = g_entries.len - g_entry_count;
    if (capacity == 0) return .ok;

    const allocator = std.heap.page_allocator;
    const entries = allocator.alloc(file_backend.Entry, capacity) catch return .open_failed;
    defer allocator.free(entries);

    const result = file_backend.list(allocator, backend, path, entries);
    if (result.status != .ok) return result.status;

    for (entries[0..result.count]) |*entry| {
        if (g_entry_count >= g_entries.len) break;
        if (copyBackendEntry(&g_entries[g_entry_count], entry, depth, parent_path, sep)) {
            g_entry_count += 1;
        }
    }

    return .ok;
}

fn copyBackendEntry(
    dest: *FlatEntry,
    src: *const file_backend.Entry,
    depth: u16,
    parent_path: []const u8,
    sep: u8,
) bool {
    const name = src.name();
    const name_len: u8 = @intCast(@min(name.len, 255));
    @memcpy(dest.name_buf[0..name_len], name[0..name_len]);
    dest.name_len = name_len;
    dest.is_dir = src.is_dir;
    dest.expanded = false;
    dest.depth = depth;

    const path_len = buildChildPathInto(&dest.path_buf, parent_path, name[0..name_len], sep) orelse return false;
    dest.path_len = @intCast(path_len);
    return true;
}

fn buildChildPathInto(buf: *[512]u8, parent: []const u8, name: []const u8, sep: u8) ?usize {
    if (parent.len > buf.len) return null;
    var pos: usize = 0;
    @memcpy(buf[0..parent.len], parent);
    pos = parent.len;

    const add_sep = parent.len > 0 and !pathEndsWithSeparator(parent, sep);
    if (add_sep) {
        if (pos >= buf.len) return null;
        buf[pos] = sep;
        pos += 1;
    }

    if (pos + name.len > buf.len) return null;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    return pos;
}

fn pathEndsWithSeparator(path: []const u8, sep: u8) bool {
    if (path.len == 0) return false;
    const last = path[path.len - 1];
    if (sep == '\\') return last == '\\' or last == '/';
    return last == sep;
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
    if (startAsyncList(.expand, path, entry.depth + 1, false) == .blocked) {
        entry.expanded = false;
        setTransferStatus(.failed, "SSH list busy");
    }
}

fn expandWithBackend(idx: usize, backend: file_backend.Backend, sep: u8) void {
    const entry = &g_entries[idx];
    entry.expanded = true;

    const path = entry.path_buf[0..entry.path_len];
    const child_depth = entry.depth + 1;
    const insert_pos = idx + 1;
    const max_new = g_entries.len - g_entry_count;
    if (max_new == 0) return;

    const allocator = std.heap.page_allocator;
    const backend_entries = allocator.alloc(file_backend.Entry, max_new) catch {
        entry.expanded = false;
        return;
    };
    defer allocator.free(backend_entries);

    const result = file_backend.list(allocator, backend, path, backend_entries);
    if (result.status != .ok) {
        entry.expanded = false;
        setTransferStatus(
            .failed,
            if (g_mode == .remote) "SSH list failed" else "Cannot open folder",
        );
        return;
    }

    const inserted = insertBackendChildren(insert_pos, backend_entries[0..result.count], child_depth, path, sep);
    if (inserted == 0) entry.expanded = false;
}

fn insertBackendChildren(
    insert_pos: usize,
    backend_entries: []const file_backend.Entry,
    child_depth: u16,
    parent_path: []const u8,
    sep: u8,
) usize {
    if (backend_entries.len == 0) return 0;
    if (g_entry_count >= g_entries.len) return 0;

    const allocator = std.heap.page_allocator;
    const max_new = g_entries.len - g_entry_count;
    const flat_children = allocator.alloc(FlatEntry, @min(backend_entries.len, max_new)) catch {
        return 0;
    };
    defer allocator.free(flat_children);

    var filled: usize = 0;
    for (backend_entries) |*child| {
        if (filled >= flat_children.len) break;
        if (copyBackendEntry(&flat_children[filled], child, child_depth, parent_path, sep)) {
            filled += 1;
        }
    }

    if (filled == 0) return 0;

    if (insert_pos < g_entry_count) {
        std.mem.copyBackwards(
            FlatEntry,
            g_entries[insert_pos + filled .. g_entry_count + filled],
            g_entries[insert_pos..g_entry_count],
        );
    }

    @memcpy(g_entries[insert_pos .. insert_pos + filled], flat_children[0..filled]);
    g_entry_count += filled;
    return filled;
}

fn findEntryByPath(path: []const u8) ?usize {
    for (0..g_entry_count) |idx| {
        const entry_path = g_entries[idx].path_buf[0..g_entries[idx].path_len];
        if (std.mem.eql(u8, entry_path, path)) return idx;
    }
    return null;
}

fn startAsyncList(kind: AsyncListKind, path: []const u8, depth: u16, resolve_root: bool) AsyncListStart {
    if (!g_has_ssh_conn) return .blocked;
    if (path.len > 512) return .blocked;
    if (g_async_job != null) return queueAsyncList(kind, path, depth, resolve_root);

    const allocator = std.heap.page_allocator;
    const entries = allocator.alloc(file_backend.Entry, MAX_ENTRIES) catch return .blocked;
    const job = allocator.create(AsyncListJob) catch {
        allocator.free(entries);
        return .blocked;
    };

    job.* = .{
        .kind = kind,
        .conn = g_ssh_conn,
        .context_id = g_async_context_id,
        .path_len = path.len,
        .depth = depth,
        .resolve_root = resolve_root,
        .entries = entries,
    };
    @memcpy(job.path_buf[0..path.len], path);

    const thread = std.Thread.spawn(.{}, asyncListThread, .{job}) catch {
        allocator.free(entries);
        allocator.destroy(job);
        return .blocked;
    };
    job.thread = thread;
    g_async_job = job;
    setLoading(if (resolve_root) "remote folder" else path);
    return .started;
}

fn queueAsyncList(kind: AsyncListKind, path: []const u8, depth: u16, resolve_root: bool) AsyncListStart {
    if (path.len > 512) return .blocked;
    var pending = PendingAsyncList{
        .kind = kind,
        .context_id = g_async_context_id,
        .path_len = path.len,
        .depth = depth,
        .resolve_root = resolve_root,
    };
    @memcpy(pending.path_buf[0..path.len], path);
    g_pending_async_list = pending;
    setLoading(if (resolve_root) "remote folder" else path);
    return .queued;
}

fn maybeStartPendingAsyncList() void {
    if (g_async_job != null) return;
    const pending = g_pending_async_list orelse return;
    g_pending_async_list = null;

    if (pending.context_id != g_async_context_id or g_mode != .remote or !g_has_ssh_conn) {
        return;
    }

    const path = pending.path_buf[0..pending.path_len];
    if (startAsyncList(pending.kind, path, pending.depth, pending.resolve_root) == .blocked) {
        setTransferStatus(.failed, "SSH list failed");
    }
}

fn asyncListThread(job: *AsyncListJob) void {
    const allocator = std.heap.page_allocator;
    var path = job.path_buf[0..job.path_len];

    if (job.resolve_root) {
        const root_len = file_backend.resolveRoot(allocator, .{ .ssh = &job.conn }, &job.root_buf) orelse {
            job.status = .ssh_failed;
            job.done.store(true, .release);
            return;
        };
        job.root_len = root_len;
        path = job.root_buf[0..root_len];
    }

    const result = file_backend.list(allocator, .{ .ssh = &job.conn }, path, job.entries);
    job.status = result.status;
    job.count = result.count;
    job.done.store(true, .release);
}

fn destroyAsyncJob(job: *AsyncListJob) void {
    const allocator = std.heap.page_allocator;
    allocator.free(job.entries);
    allocator.destroy(job);
}

fn setLoading(msg: []const u8) void {
    g_loading = true;
    g_loading_msg_len = @intCast(@min(msg.len, g_loading_msg.len));
    @memcpy(g_loading_msg[0..g_loading_msg_len], msg[0..g_loading_msg_len]);
}

fn expand(idx: usize) void {
    expandWithBackend(idx, .local, '\\');
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
    const total_h = @as(f32, @floatFromInt(g_entry_count)) * rowHeight();
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
    const row_h = rowHeight();
    const sel_top = @as(f32, @floatFromInt(sel)) * row_h;
    if (sel_top < g_scroll_offset) {
        g_scroll_offset = sel_top;
    } else if (sel_top + row_h > g_scroll_offset + 400) {
        g_scroll_offset = sel_top + row_h - 400;
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

test "setTransferStatus stores message" {
    setTransferStatus(.success, "test_file.txt");
    try std.testing.expectEqual(TransferStatus.success, g_transfer_status);
    try std.testing.expectEqualStrings("test_file.txt", g_transfer_msg[0..g_transfer_msg_len]);
}

test "buildChildPathInto avoids duplicate separators" {
    var buf: [512]u8 = undefined;

    const remote = buildChildPathInto(&buf, "/var/log", "syslog", '/') orelse unreachable;
    try std.testing.expectEqualStrings("/var/log/syslog", buf[0..remote]);

    const remote_root = buildChildPathInto(&buf, "/", "home", '/') orelse unreachable;
    try std.testing.expectEqualStrings("/home", buf[0..remote_root]);

    const local = buildChildPathInto(&buf, "C:\\Users", "xzg", '\\') orelse unreachable;
    try std.testing.expectEqualStrings("C:\\Users\\xzg", buf[0..local]);
}

test "Mode enum values" {
    try std.testing.expectEqual(Mode.local, .local);
    try std.testing.expectEqual(Mode.remote, .remote);
    // Default state
    g_mode = .local;
    try std.testing.expect(!g_has_ssh_conn);
}
