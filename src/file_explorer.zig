//! File Explorer state and directory tree model.
//!
//! Manages the left-side file explorer sidebar: visibility, width, directory
//! scanning, tree expand/collapse, selection, scroll, and file operations.
//! Supports local (std.fs), WSL (wsl.exe), and remote (ssh ls / scp) modes.

const std = @import("std");
const Surface = @import("Surface.zig");
const agent_history = @import("agent_history.zig");
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
pub const MAX_HISTORY_ROWS: usize = 256;

pub const Mode = enum { local, wsl, remote };
pub const PanelMode = enum { files, agent_history };

pub const HistoryRow = struct {
    title_buf: [128]u8 = undefined,
    title_len: u8 = 0,
    model_buf: [64]u8 = undefined,
    model_len: u8 = 0,
    updated_at: i64 = 0,
};

pub const TerminalPanelTarget = union(enum) {
    remote: struct {
        conn: *const Surface.SshConnection,
        cwd: []const u8,
    },
    wsl: []const u8,
    local: []const u8,
};

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;
pub threadlocal var g_focused: bool = false;
pub threadlocal var g_mode: Mode = .local;
pub threadlocal var g_panel_mode: PanelMode = .files;
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
pub threadlocal var g_history_scroll_offset: f32 = 0;
pub threadlocal var g_visible_height: f32 = 400;
pub threadlocal var g_history_visible_height: f32 = 400;

// Selection state (index into flattened visible entries)
pub threadlocal var g_selected: ?usize = null;
pub threadlocal var g_history_rows: [MAX_HISTORY_ROWS]HistoryRow = undefined;
pub threadlocal var g_history_session_ids: [MAX_HISTORY_ROWS]?[]u8 = [_]?[]u8{null} ** MAX_HISTORY_ROWS;
pub threadlocal var g_history_row_count: usize = 0;
pub threadlocal var g_history_selected: ?usize = null;

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

pub fn syncViewportMetrics(window_height: f32, titlebar_h: f32) void {
    const visible_height = @max(0, window_height - titlebar_h - headerHeight());
    g_visible_height = visible_height;
    g_history_visible_height = visible_height;
    clampFileScroll();
    clampHistoryScroll();
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

pub fn setPanelMode(mode: PanelMode) void {
    if (mode == .agent_history) clearFileOpState();
    if (g_panel_mode == mode) {
        switch (mode) {
            .files => clampFileScroll(),
            .agent_history => {
                clampHistorySelection();
                clampHistoryScroll();
            },
        }
        return;
    }
    g_panel_mode = mode;
    switch (mode) {
        .files => clampFileScroll(),
        .agent_history => {
            clampHistorySelection();
            clampHistoryScroll();
        },
    }
}

pub fn syncPanelForTabKind(is_ai_tab: bool) void {
    g_focused = false;
    setPanelMode(if (is_ai_tab) .agent_history else .files);
}

pub fn syncPanelForTerminalTarget(target: TerminalPanelTarget) void {
    if (terminalTargetMatchesCurrentState(target)) return;

    applyTerminalTargetState(target);
    switch (target) {
        .remote => rescanRemote(),
        .wsl, .local => {
            if (g_root_path_len > 0) rescan();
        },
    }
}

pub fn syncAgentHistoryRows(store: *const agent_history.Store) void {
    const allocator = std.heap.page_allocator;
    const selected_session_id_copy = if (g_history_selected) |selected|
        if (historySessionIdAt(selected)) |session_id|
            allocator.dupe(u8, session_id) catch null
        else
            null
    else
        null;
    defer if (selected_session_id_copy) |session_id| allocator.free(session_id);

    const rows = store.buildRows(allocator) catch {
        clearHistoryRows();
        g_history_selected = null;
        g_history_scroll_offset = 0;
        return;
    };
    defer agent_history.freeRows(allocator, rows);

    clearHistoryRows();
    var filled: usize = 0;
    for (rows[0..@min(rows.len, g_history_rows.len)], 0..) |row, idx| {
        const owned_session_id = allocator.dupe(u8, row.session_id) catch break;
        g_history_session_ids[idx] = owned_session_id;
        copyHistoryText(&g_history_rows[idx].title_buf, &g_history_rows[idx].title_len, row.title);
        copyHistoryText(&g_history_rows[idx].model_buf, &g_history_rows[idx].model_len, row.model);
        g_history_rows[idx].updated_at = row.updated_at;
        filled += 1;
    }
    g_history_row_count = filled;

    if (selected_session_id_copy != null) {
        g_history_selected = null;
        for (0..g_history_row_count) |idx| {
            if (std.mem.eql(u8, historySessionIdAt(idx).?, selected_session_id_copy.?)) {
                g_history_selected = idx;
                break;
            }
        }
    }

    clampHistorySelection();
    if (g_panel_mode == .agent_history) clampHistoryScroll();
}

pub fn moveHistorySelection(delta: i32) void {
    if (g_history_row_count == 0) {
        g_history_selected = null;
        return;
    }

    if (g_history_selected) |selected| {
        const next = @as(i32, @intCast(selected)) + delta;
        g_history_selected = @intCast(@max(0, @min(@as(i32, @intCast(g_history_row_count - 1)), next)));
    } else {
        g_history_selected = 0;
    }
    ensureHistorySelectedVisible();
}

pub fn historySessionIdAt(idx: usize) ?[]const u8 {
    if (idx >= g_history_row_count) return null;
    return g_history_session_ids[idx];
}

pub fn selectedHistorySessionId() ?[]const u8 {
    const selected = g_history_selected orelse return null;
    return historySessionIdAt(selected);
}

fn clampHistorySelection() void {
    if (g_history_row_count == 0) {
        g_history_selected = null;
        return;
    }

    if (g_history_selected) |selected| {
        if (selected >= g_history_row_count) {
            g_history_selected = g_history_row_count - 1;
        }
    }
}

fn copyHistoryText(buf: anytype, len_out: *u8, value: []const u8) void {
    var len: usize = 0;
    while (len < value.len and len < buf.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(value[len]) catch break;
        if (len + seq_len > value.len or len + seq_len > buf.len) break;
        @memcpy(buf[len .. len + seq_len], value[len .. len + seq_len]);
        len += seq_len;
    }
    len_out.* = @intCast(len);
}

fn ensureHistorySelectedVisible() void {
    const selected = g_history_selected orelse return;
    const row_h = rowHeight();
    const selected_top = @as(f32, @floatFromInt(selected)) * row_h;
    if (selected_top < g_history_scroll_offset) {
        g_history_scroll_offset = selected_top;
    } else if (selected_top + row_h > g_history_scroll_offset + g_history_visible_height) {
        g_history_scroll_offset = selected_top + row_h - g_history_visible_height;
    }
    clampHistoryScroll();
}

fn clampHistoryScroll() void {
    g_history_scroll_offset = @max(0, @min(maxHistoryScroll(), g_history_scroll_offset));
}

fn maxHistoryScroll() f32 {
    const total_h = @as(f32, @floatFromInt(g_history_row_count)) * rowHeight();
    return @max(0, total_h - g_history_visible_height);
}

fn clearHistoryRows() void {
    for (&g_history_session_ids) |*session_id| {
        if (session_id.*) |owned| std.heap.page_allocator.free(owned);
        session_id.* = null;
    }
    g_history_row_count = 0;
}

fn clearFileOpState() void {
    g_op_mode = .none;
    g_input_len = 0;
}

fn terminalTargetMatchesCurrentState(target: TerminalPanelTarget) bool {
    if (g_panel_mode != .files) return false;

    const current_root = g_root_path[0..g_root_path_len];
    return switch (target) {
        .remote => |remote| g_mode == .remote and
            g_has_ssh_conn and
            sshConnectionsEqual(&g_ssh_conn, remote.conn) and
            std.mem.eql(u8, current_root, remote.cwd),
        .wsl => |cwd| g_mode == .wsl and
            !g_has_ssh_conn and
            std.mem.eql(u8, current_root, if (cwd.len > 0) cwd else "~"),
        .local => |path| g_mode == .local and
            !g_has_ssh_conn and
            std.mem.eql(u8, current_root, path),
    };
}

fn sshConnectionsEqual(a: *const Surface.SshConnection, b: *const Surface.SshConnection) bool {
    return std.mem.eql(u8, a.user(), b.user()) and
        std.mem.eql(u8, a.host(), b.host()) and
        std.mem.eql(u8, a.port(), b.port()) and
        std.mem.eql(u8, a.password(), b.password()) and
        a.password_auth == b.password_auth and
        a.legacy_algorithms == b.legacy_algorithms;
}

fn applyTerminalTargetState(target: TerminalPanelTarget) void {
    syncPanelForTabKind(false);
    g_async_context_id +%= 1;
    g_pending_async_list = null;
    g_loading = false;
    g_entry_count = 0;
    g_selected = null;

    switch (target) {
        .remote => |remote| {
            g_mode = .remote;
            g_ssh_conn = remote.conn.*;
            g_has_ssh_conn = true;
            copyRootPathOnly(remote.cwd);
        },
        .wsl => |cwd| {
            g_mode = .wsl;
            g_has_ssh_conn = false;
            copyRootPathOnly(if (cwd.len > 0) cwd else "~");
        },
        .local => |path| {
            g_mode = .local;
            g_has_ssh_conn = false;
            copyRootPathOnly(path);
        },
    }
}

fn copyRootPathOnly(path: []const u8) void {
    const len = @min(path.len, g_root_path.len);
    @memcpy(g_root_path[0..len], path[0..len]);
    g_root_path_len = len;
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

/// Enter WSL mode. Paths are Linux-style and listed via wsl.exe.
pub fn enterWslMode(wsl_cwd: []const u8) void {
    g_async_context_id +%= 1;
    g_pending_async_list = null;
    g_loading = false;
    g_mode = .wsl;
    g_has_ssh_conn = false;
    if (wsl_cwd.len > 0) {
        setRoot(wsl_cwd);
    } else {
        setRoot("~");
    }
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
    const backend: file_backend.Backend = switch (g_mode) {
        .local => .local,
        .wsl => .wsl,
        .remote => unreachable,
    };
    const sep: u8 = if (g_mode == .wsl) '/' else '\\';
    const result = loadBackendEntries(backend, path, 0, path, sep);
    if (result != .ok) {
        setTransferStatus(.failed, if (g_mode == .wsl) "WSL list failed" else "Cannot open folder");
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
        } else if (g_mode == .wsl) {
            expandWsl(idx);
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
            switch (g_mode) {
                .remote => "SSH list failed",
                .wsl => "WSL list failed",
                .local => "Cannot open folder",
            },
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

/// Clean up any in-flight async job. Call on window close to avoid leaking
/// the job allocation and its thread.
pub fn deinit() void {
    if (g_async_job) |job| {
        // Wait for the background thread to finish
        if (job.thread) |thread| thread.join();
        destroyAsyncJob(job);
        g_async_job = null;
    }
    g_pending_async_list = null;
    g_loading = false;
    clearHistoryRows();
}

fn setLoading(msg: []const u8) void {
    g_loading = true;
    g_loading_msg_len = @intCast(@min(msg.len, g_loading_msg.len));
    @memcpy(g_loading_msg[0..g_loading_msg_len], msg[0..g_loading_msg_len]);
}

fn expand(idx: usize) void {
    expandWithBackend(idx, .local, '\\');
}

fn expandWsl(idx: usize) void {
    expandWithBackend(idx, .wsl, '/');
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
    switch (g_panel_mode) {
        .files => {
            const max_scroll = maxScroll();
            g_scroll_offset = @max(0, @min(max_scroll, g_scroll_offset + delta));
        },
        .agent_history => {
            const max_scroll = maxHistoryScroll();
            g_history_scroll_offset = @max(0, @min(max_scroll, g_history_scroll_offset + delta));
        },
    }
}

fn maxScroll() f32 {
    const total_h = @as(f32, @floatFromInt(g_entry_count)) * rowHeight();
    return @max(0, total_h - g_visible_height);
}

fn clampFileScroll() void {
    g_scroll_offset = @max(0, @min(maxScroll(), g_scroll_offset));
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
    } else if (sel_top + row_h > g_scroll_offset + g_visible_height) {
        g_scroll_offset = sel_top + row_h - g_visible_height;
    }
    clampFileScroll();
}

// ============================================================================
// SCP Transfer Operations
// ============================================================================

pub fn setTransferStatus(status: TransferStatus, msg: []const u8) void {
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
    try std.testing.expectEqual(Mode.wsl, .wsl);
    try std.testing.expectEqual(Mode.remote, .remote);
    // Default state
    g_mode = .local;
    try std.testing.expect(!g_has_ssh_conn);
}

test "file_explorer: agent history mode selection clamps to row count" {
    g_panel_mode = .agent_history;
    g_history_row_count = 2;
    g_history_selected = 10;
    clampHistorySelection();
    try std.testing.expectEqual(@as(?usize, 1), g_history_selected);
}

test "file_explorer: history selection visibility uses history viewport height" {
    g_panel_mode = .agent_history;
    g_row_height = 20;
    g_history_visible_height = 60;
    g_history_row_count = 10;
    g_history_scroll_offset = 0;
    g_history_selected = 4;
    ensureHistorySelectedVisible();
    try std.testing.expectEqual(@as(f32, 40), g_history_scroll_offset);
}

test "file_explorer: moveHistorySelection walks selected row" {
    g_panel_mode = .agent_history;
    g_row_height = 20;
    g_history_visible_height = 200;
    g_history_row_count = 3;
    g_history_selected = 0;
    g_history_scroll_offset = 0;

    moveHistorySelection(1);
    try std.testing.expectEqual(@as(?usize, 1), g_history_selected);

    moveHistorySelection(10);
    try std.testing.expectEqual(@as(?usize, 2), g_history_selected);
}

test "file_explorer: history scroll does not mutate file scroll" {
    g_panel_mode = .files;
    g_row_height = 20;
    g_visible_height = 100;
    g_entry_count = 10;
    g_scroll_offset = 30;
    scrollBy(10);
    try std.testing.expectEqual(@as(f32, 40), g_scroll_offset);

    g_panel_mode = .agent_history;
    g_history_visible_height = 60;
    g_history_row_count = 10;
    g_history_scroll_offset = 5;
    scrollBy(10);

    try std.testing.expectEqual(@as(f32, 40), g_scroll_offset);
    try std.testing.expectEqual(@as(f32, 15), g_history_scroll_offset);
}

test "file_explorer: switching to agent history clears file op state" {
    g_panel_mode = .files;
    g_op_mode = .rename;
    g_input_len = 3;
    g_scroll_offset = 77;
    g_history_scroll_offset = 12;

    setPanelMode(.agent_history);

    try std.testing.expectEqual(PanelMode.agent_history, g_panel_mode);
    try std.testing.expectEqual(OpMode.none, g_op_mode);
    try std.testing.expectEqual(@as(u8, 0), g_input_len);
    try std.testing.expectEqual(@as(f32, 77), g_scroll_offset);
    try std.testing.expectEqual(@as(f32, 12), g_history_scroll_offset);
}

test "file_explorer: syncPanelForTabKind resets focus and mode" {
    g_focused = true;
    g_panel_mode = .files;

    syncPanelForTabKind(true);
    try std.testing.expectEqual(false, g_focused);
    try std.testing.expectEqual(PanelMode.agent_history, g_panel_mode);

    g_focused = true;
    syncPanelForTabKind(false);
    try std.testing.expectEqual(false, g_focused);
    try std.testing.expectEqual(PanelMode.files, g_panel_mode);
}

test "file_explorer: applyTerminalTargetState updates terminal backend and root" {
    const conn: Surface.SshConnection = .{
        .user_len = 4,
        .host_len = 4,
        .port_len = 2,
        .password_len = 2,
        .password_auth = true,
        .legacy_algorithms = false,
    };
    const saved_focused = g_focused;
    const saved_panel_mode = g_panel_mode;
    const saved_mode = g_mode;
    const saved_has_ssh_conn = g_has_ssh_conn;
    const saved_root_len = g_root_path_len;
    const saved_async_context = g_async_context_id;
    defer {
        g_focused = saved_focused;
        g_panel_mode = saved_panel_mode;
        g_mode = saved_mode;
        g_has_ssh_conn = saved_has_ssh_conn;
        g_root_path_len = saved_root_len;
        g_async_context_id = saved_async_context;
    }

    g_focused = true;
    applyTerminalTargetState(.{ .wsl = "/home/test" });
    try std.testing.expectEqual(false, g_focused);
    try std.testing.expectEqual(PanelMode.files, g_panel_mode);
    try std.testing.expectEqual(Mode.wsl, g_mode);
    try std.testing.expectEqualStrings("/home/test", g_root_path[0..g_root_path_len]);

    g_focused = true;
    applyTerminalTargetState(.{ .local = "C:\\Users\\tester" });
    try std.testing.expectEqual(false, g_focused);
    try std.testing.expectEqual(Mode.local, g_mode);
    try std.testing.expect(!g_has_ssh_conn);
    try std.testing.expectEqualStrings("C:\\Users\\tester", g_root_path[0..g_root_path_len]);

    g_focused = true;
    applyTerminalTargetState(.{ .remote = .{ .conn = &conn, .cwd = "/var/tmp" } });
    try std.testing.expectEqual(false, g_focused);
    try std.testing.expectEqual(Mode.remote, g_mode);
    try std.testing.expect(g_has_ssh_conn);
    try std.testing.expectEqualStrings("/var/tmp", g_root_path[0..g_root_path_len]);
}

test "file_explorer: unchanged terminal target preserves file state" {
    const saved_panel_mode = g_panel_mode;
    const saved_mode = g_mode;
    const saved_has_ssh_conn = g_has_ssh_conn;
    const saved_root_len = g_root_path_len;
    const saved_entry_count = g_entry_count;
    const saved_selected = g_selected;
    const saved_scroll_offset = g_scroll_offset;
    const saved_focused = g_focused;
    const saved_async_context = g_async_context_id;
    defer {
        g_panel_mode = saved_panel_mode;
        g_mode = saved_mode;
        g_has_ssh_conn = saved_has_ssh_conn;
        g_root_path_len = saved_root_len;
        g_entry_count = saved_entry_count;
        g_selected = saved_selected;
        g_scroll_offset = saved_scroll_offset;
        g_focused = saved_focused;
        g_async_context_id = saved_async_context;
    }

    g_panel_mode = .files;
    g_mode = .local;
    g_has_ssh_conn = false;
    copyRootPathOnly("");
    g_entry_count = 7;
    g_selected = 3;
    g_scroll_offset = 42;
    g_focused = true;
    g_async_context_id = 99;

    syncPanelForTerminalTarget(.{ .local = "" });

    try std.testing.expectEqual(@as(usize, 7), g_entry_count);
    try std.testing.expectEqual(@as(?usize, 3), g_selected);
    try std.testing.expectEqual(@as(f32, 42), g_scroll_offset);
    try std.testing.expectEqual(true, g_focused);
    try std.testing.expectEqual(@as(u64, 99), g_async_context_id);
}

test "file_explorer: terminal target equality checks ssh identity and cwd" {
    const conn_a: Surface.SshConnection = .{
        .user_buf = [_]u8{ 'r', 'o', 'o', 't' } ++ [_]u8{0} ** 124,
        .user_len = 4,
        .host_buf = [_]u8{ 'h', 'o', 's', 't' } ++ [_]u8{0} ** 124,
        .host_len = 4,
        .port_buf = [_]u8{ '2', '2' } ++ [_]u8{0} ** 14,
        .port_len = 2,
        .password_buf = [_]u8{ 'p', 'w' } ++ [_]u8{0} ** 126,
        .password_len = 2,
        .password_auth = true,
        .legacy_algorithms = false,
    };
    const conn_b: Surface.SshConnection = .{
        .user_buf = [_]u8{ 'r', 'o', 'o', 't' } ++ [_]u8{0} ** 124,
        .user_len = 4,
        .host_buf = [_]u8{ 'h', 'o', 's', 't' } ++ [_]u8{0} ** 124,
        .host_len = 4,
        .port_buf = [_]u8{ '2', '2' } ++ [_]u8{0} ** 14,
        .port_len = 2,
        .password_buf = [_]u8{ 'p', 'x' } ++ [_]u8{0} ** 126,
        .password_len = 2,
        .password_auth = true,
        .legacy_algorithms = false,
    };
    const saved_panel_mode = g_panel_mode;
    const saved_mode = g_mode;
    const saved_has_ssh_conn = g_has_ssh_conn;
    const saved_ssh_conn = g_ssh_conn;
    const saved_root_len = g_root_path_len;
    defer {
        g_panel_mode = saved_panel_mode;
        g_mode = saved_mode;
        g_has_ssh_conn = saved_has_ssh_conn;
        g_ssh_conn = saved_ssh_conn;
        g_root_path_len = saved_root_len;
    }

    g_panel_mode = .files;
    g_mode = .remote;
    g_has_ssh_conn = true;
    g_ssh_conn = conn_a;
    copyRootPathOnly("/tmp");

    try std.testing.expect(terminalTargetMatchesCurrentState(.{ .remote = .{ .conn = &conn_a, .cwd = "/tmp" } }));
    try std.testing.expect(!terminalTargetMatchesCurrentState(.{ .remote = .{ .conn = &conn_a, .cwd = "/var/tmp" } }));
    try std.testing.expect(!terminalTargetMatchesCurrentState(.{ .remote = .{ .conn = &conn_b, .cwd = "/tmp" } }));
}

test "file_explorer: history session ids preserve full utf8 ids" {
    const allocator = std.testing.allocator;
    var store = agent_history.Store.init(allocator);
    defer store.deinit();

    const long_session_id =
        "会話-会話-会話-会話-会話-会話-会話-会話-会話-会話-会話-会話-会話-会話-会話";
    try store.upsertRecord(.{
        .session_id = long_session_id,
        .title = "Saved chat",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "gpt-test",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{},
    });

    syncAgentHistoryRows(&store);

    try std.testing.expectEqual(@as(usize, 1), g_history_row_count);
    try std.testing.expectEqualStrings(long_session_id, historySessionIdAt(0).?);
}

test "file_explorer: history row text keeps valid utf8 when truncated" {
    const allocator = std.testing.allocator;
    var store = agent_history.Store.init(allocator);
    defer store.deinit();

    const long_title = "界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界";
    const long_model = "模模模模模模模模模模模模模模模模模模模模模模";
    try store.upsertRecord(.{
        .session_id = "session-1",
        .title = long_title,
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = long_model,
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{},
    });

    syncAgentHistoryRows(&store);

    try std.testing.expectEqual(@as(usize, 1), g_history_row_count);
    try std.testing.expect(std.unicode.utf8ValidateSlice(g_history_rows[0].title_buf[0..g_history_rows[0].title_len]));
    try std.testing.expect(std.unicode.utf8ValidateSlice(g_history_rows[0].model_buf[0..g_history_rows[0].model_len]));
}
