//! Tab and split management for AppWindow.
//!
//! Owns all tab state (TabState, tab array, tab count, active tab),
//! tab rename state, and tab/split operations. Does NOT depend on
//! rendering or GL — only on Surface, SplitTree, and win32_backend.

const std = @import("std");
const Config = @import("../config.zig");
const Surface = @import("../Surface.zig");
const SplitTree = @import("../split_tree.zig");
const win32_backend = @import("../apprt/win32.zig");
const remote_client = @import("../remote_client.zig");
const session_persist = @import("../session_persist.zig");
const ai_chat = @import("../ai_chat.zig");
const agent_history = @import("../agent_history.zig");

const CursorStyle = Config.CursorStyle;
const Selection = Surface.Selection;

// ============================================================================
// Constants
// ============================================================================

pub const MAX_TABS = 16;
pub const MAX_SPLITS_PER_TAB = 16;
pub const SPLIT_DIVIDER_WIDTH: i32 = 2;
pub const DEFAULT_PADDING: u32 = 10;

// Tab close button
pub const TAB_CLOSE_BTN_W: f32 = 36;
pub const TAB_CLOSE_FADE_SPEED: f32 = 6.0;

pub threadlocal var g_ssh_legacy_algorithms: bool = false;

// ============================================================================
// Tab model — each tab owns a SplitTree of Surfaces
// ============================================================================

pub const TabState = struct {
    kind: Kind = .terminal,
    tree: SplitTree,
    focused: SplitTree.Node.Handle = .root,
    ai_chat_session: ?*ai_chat.Session = null,

    pub const Kind = enum {
        terminal,
        ai_chat,
    };

    /// Get the focused surface in this tab, or null if tree is empty
    pub fn focusedSurface(self: *const TabState) ?*Surface {
        if (self.kind != .terminal) return null;
        if (self.tree.isEmpty()) return null;
        if (self.focused.idx() >= self.tree.nodes.len) return null;
        return switch (self.tree.nodes[self.focused.idx()]) {
            .leaf => |surface| surface,
            .split => null,
        };
    }

    /// Get the display title for this tab
    pub fn getTitle(self: *const TabState) []const u8 {
        if (g_forced_title) |forced| {
            return forced;
        }
        if (self.kind == .ai_chat) {
            const chat = self.ai_chat_session orelse return "AI Chat";
            const chat_title = chat.title();
            return if (chat_title.len > 0) chat_title else "AI Chat";
        }
        const surface = self.focusedSurface() orelse return "phantty";
        return surface.getTitle();
    }

    pub fn deinit(self: *TabState, allocator: std.mem.Allocator) void {
        _ = allocator;
        switch (self.kind) {
            .terminal => self.tree.deinit(),
            .ai_chat => {
                if (self.ai_chat_session) |session| {
                    session.deinit();
                    self.ai_chat_session = null;
                }
            },
        }
    }
};

// ============================================================================
// Tab globals
// ============================================================================

pub threadlocal var g_tabs: [MAX_TABS]?*TabState = .{null} ** MAX_TABS;
pub threadlocal var g_tab_count: usize = 0;
pub threadlocal var g_active_tab: usize = 0;

// Shell command for spawning new tabs (set once at startup from config)
pub threadlocal var g_shell_cmd_buf: [256]u16 = undefined;
pub threadlocal var g_shell_cmd_len: usize = 0;
pub threadlocal var g_scrollback_limit: u32 = 10_000_000;
pub threadlocal var g_remote_client: ?*remote_client.Client = null;
pub threadlocal var g_ai_history_change_hook: ?ai_chat.HistoryChangeHook = null;

// Forced title from config (overrides all tab titles)
pub threadlocal var g_forced_title: ?[]const u8 = null;

// ============================================================================
// Tab close button state
// ============================================================================

pub threadlocal var g_tab_close_opacity: [MAX_TABS]f32 = .{0} ** MAX_TABS;
pub threadlocal var g_tab_close_pressed: ?usize = null;
pub threadlocal var g_last_frame_time_ms: i64 = 0;

// ============================================================================
// Tab text hit regions (synced from renderer for double-click rename)
// ============================================================================

pub threadlocal var g_tab_text_x_start: [MAX_TABS]f32 = .{0} ** MAX_TABS;
pub threadlocal var g_tab_text_x_end: [MAX_TABS]f32 = .{0} ** MAX_TABS;
pub threadlocal var g_tab_text_y_start: [MAX_TABS]f32 = .{0} ** MAX_TABS;
pub threadlocal var g_tab_text_y_end: [MAX_TABS]f32 = .{0} ** MAX_TABS;

// Sidebar tab navigation state. This lives beside the tab model because the
// renderer and input layer both need to agree on whether tab navigation is
// currently visible.
pub threadlocal var g_sidebar_visible: bool = true;

// ============================================================================
// Tab rename state
// ============================================================================

pub threadlocal var g_tab_rename_active: bool = false;
pub threadlocal var g_tab_rename_idx: usize = 0;
pub threadlocal var g_tab_rename_buf: [256]u8 = undefined;
pub threadlocal var g_tab_rename_len: usize = 0;
pub threadlocal var g_tab_rename_cursor: usize = 0;
pub threadlocal var g_tab_rename_select_all: bool = false;
pub threadlocal var g_tab_rename_orig_buf: [256]u8 = undefined;
pub threadlocal var g_tab_rename_orig_len: usize = 0;

// ============================================================================
// Query functions
// ============================================================================

pub fn getShellCmd() [:0]const u16 {
    return g_shell_cmd_buf[0..g_shell_cmd_len :0];
}

pub fn activeTab() ?*TabState {
    if (g_tab_count == 0) return null;
    return g_tabs[g_active_tab];
}

pub fn activeSurface() ?*Surface {
    if (g_tab_count == 0) return null;
    const t = g_tabs[g_active_tab] orelse return null;
    return t.focusedSurface();
}

pub fn activeAiChat() ?*ai_chat.Session {
    if (g_tab_count == 0) return null;
    const t = g_tabs[g_active_tab] orelse return null;
    if (t.kind != .ai_chat) return null;
    return t.ai_chat_session;
}

pub fn findAiTabBySessionId(session_id: []const u8) ?usize {
    for (0..g_tab_count) |idx| {
        const t = g_tabs[idx] orelse continue;
        if (t.kind != .ai_chat) continue;
        const session = t.ai_chat_session orelse continue;
        if (std.mem.eql(u8, session.sessionId(), session_id)) return idx;
    }
    return null;
}

pub fn switchToAiTabBySessionId(session_id: []const u8) bool {
    const idx = findAiTabBySessionId(session_id) orelse return false;
    switchTab(idx);
    return true;
}

fn splitSpawnCommand(
    allocator: std.mem.Allocator,
    surface: *const Surface,
) ?[:0]const u16 {
    return switch (surface.launch_kind) {
        .wsl => splitWslCommand(allocator, surface),
        .ssh => splitSshCommand(allocator, surface),
        .windows => null,
    };
}

fn appendAscii(buf: *[1024]u8, pos: *usize, text: []const u8) bool {
    if (pos.* + text.len > buf.len) return false;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
    return true;
}

fn appendWindowsQuotedArg(buf: *[1024]u8, pos: *usize, arg: []const u8) bool {
    if (pos.* >= buf.len) return false;
    buf[pos.*] = '"';
    pos.* += 1;
    for (arg) |ch| {
        if (ch == '"') {
            if (!appendAscii(buf, pos, "\\\"")) return false;
        } else {
            if (pos.* >= buf.len) return false;
            buf[pos.*] = ch;
            pos.* += 1;
        }
    }
    if (pos.* >= buf.len) return false;
    buf[pos.*] = '"';
    pos.* += 1;
    return true;
}

fn splitWslCommand(
    allocator: std.mem.Allocator,
    surface: *const Surface,
) ?[:0]const u16 {
    var command_buf: [1024]u8 = undefined;
    var pos: usize = 0;
    if (!appendAscii(&command_buf, &pos, "wsl.exe")) return null;

    if (surface.getCwd()) |cwd| {
        if (cwd.len > 0) {
            if (!appendAscii(&command_buf, &pos, " --cd ")) return null;
            if (!appendWindowsQuotedArg(&command_buf, &pos, cwd)) return null;
            return std.unicode.utf8ToUtf16LeAllocZ(allocator, command_buf[0..pos]) catch null;
        }
    }

    if (!appendAscii(&command_buf, &pos, " ~")) return null;
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, command_buf[0..pos]) catch null;
}

fn splitSshCommand(
    allocator: std.mem.Allocator,
    surface: *const Surface,
) ?[:0]const u16 {
    const conn = surface.ssh_connection orelse return null;

    var command_buf: [512]u8 = undefined;
    // Keep this in sync with overlays.connectSshProfile — see comment there
    // for why ServerAlive* is mandatory for split-inherited SSH sessions too.
    const auth_flags = if (conn.password_auth)
        "-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no "
    else
        "-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 ";
    const command = if (conn.port().len > 0)
        std.fmt.bufPrint(&command_buf, "cmd.exe /k ssh.exe -tt {s}-p {s} {s}@{s}", .{ auth_flags, conn.port(), conn.user(), conn.host() }) catch return null
    else
        std.fmt.bufPrint(&command_buf, "cmd.exe /k ssh.exe -tt {s}{s}@{s}", .{ auth_flags, conn.user(), conn.host() }) catch return null;

    return std.unicode.utf8ToUtf16LeAllocZ(allocator, command) catch null;
}

/// Get the active tab's focused surface's selection
pub fn activeSelection() *Selection {
    if (g_tab_count > 0) {
        if (g_tabs[g_active_tab]) |t| {
            if (t.kind != .terminal) {
                const S = struct {
                    var dummy: Selection = .{};
                };
                return &S.dummy;
            }
            if (t.focusedSurface()) |surface| {
                return &surface.selection;
            }
        }
    }
    const S = struct {
        var dummy: Selection = .{};
    };
    return &S.dummy;
}

pub fn isActiveTabTerminal() bool {
    if (g_tab_count == 0) return false;
    const t = g_tabs[g_active_tab] orelse return false;
    return t.kind == .terminal;
}

// ============================================================================
// Tab operations
// ============================================================================

/// Spawn a new tab with its own Surface (PTY + terminal).
/// The caller is responsible for clearing UI state (selection, divider, resize overlay)
/// and setting rebuild flags after a successful spawn.
pub fn spawnTabWithCwd(allocator: std.mem.Allocator, cols: u16, rows: u16, cursor_style: CursorStyle, cursor_blink: bool, cwd: ?[*:0]const u16) bool {
    return spawnTabWithCommandAndCwd(allocator, cols, rows, getShellCmd(), cursor_style, cursor_blink, cwd);
}

pub fn spawnTabWithCommandAndCwd(allocator: std.mem.Allocator, cols: u16, rows: u16, command: [:0]const u16, cursor_style: CursorStyle, cursor_blink: bool, cwd: ?[*:0]const u16) bool {
    if (g_tab_count >= MAX_TABS) return false;

    const surface = Surface.init(
        allocator,
        cols,
        rows,
        command,
        g_scrollback_limit,
        cursor_style,
        cursor_blink,
        cwd,
    ) catch {
        std.debug.print("Failed to create Surface for new tab\n", .{});
        return false;
    };
    surface.attachRemoteClient(g_remote_client);

    const tree = SplitTree.init(allocator, surface) catch {
        std.debug.print("Failed to create SplitTree for new tab\n", .{});
        surface.deinit(allocator);
        return false;
    };
    surface.unref(allocator);

    const t = allocator.create(TabState) catch {
        std.debug.print("Failed to allocate TabState\n", .{});
        var tree_mut = tree;
        tree_mut.deinit();
        return false;
    };
    t.kind = .terminal;
    t.tree = tree;
    t.focused = .root;
    t.ai_chat_session = null;

    g_tabs[g_tab_count] = t;
    g_active_tab = g_tab_count;
    g_tab_count += 1;

    std.debug.print("New tab spawned (count={}), active: {}\n", .{ g_tab_count, g_active_tab });
    return true;
}

pub fn spawnAiChatTab(
    allocator: std.mem.Allocator,
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
    if (g_tab_count >= MAX_TABS) return false;

    const session = ai_chat.Session.init(
        allocator,
        name,
        base_url,
        api_key,
        model,
        system_prompt,
        thinking,
        reasoning_effort,
        stream_val,
        agent_val,
    ) catch {
        std.debug.print("Failed to create AI Chat session\n", .{});
        return false;
    };
    installAiChatHistoryHook(session);

    const t = allocator.create(TabState) catch {
        session.deinit();
        return false;
    };
    t.kind = .ai_chat;
    t.tree = .empty;
    t.focused = .root;
    t.ai_chat_session = session;

    g_tabs[g_tab_count] = t;
    g_active_tab = g_tab_count;
    g_tab_count += 1;

    std.debug.print("New AI Chat tab spawned (count={}), active: {}\n", .{ g_tab_count, g_active_tab });
    return true;
}

pub fn spawnAiChatTabFromHistoryRecord(allocator: std.mem.Allocator, record: agent_history.SessionRecord) bool {
    if (switchToAiTabBySessionId(record.session_id)) return true;
    if (g_tab_count >= MAX_TABS) return false;

    const session = ai_chat.Session.initFromHistoryRecord(allocator, record) catch {
        std.debug.print("Failed to restore AI Chat session from history\n", .{});
        return false;
    };
    installAiChatHistoryHook(session);

    const t = allocator.create(TabState) catch {
        session.deinit();
        return false;
    };
    t.kind = .ai_chat;
    t.tree = .empty;
    t.focused = .root;
    t.ai_chat_session = session;

    g_tabs[g_tab_count] = t;
    g_active_tab = g_tab_count;
    g_tab_count += 1;

    std.debug.print("Restored AI Chat tab from history (count={}), active: {}\n", .{ g_tab_count, g_active_tab });
    return true;
}

/// Close the tab at the given index.
/// The caller is responsible for clearing selection state and setting rebuild flags.
pub fn closeTab(idx: usize, allocator: std.mem.Allocator) void {
    if (g_tab_count <= 1) return;
    if (idx >= g_tab_count) return;

    if (g_tabs[idx]) |t| {
        t.deinit(allocator);
        allocator.destroy(t);
    }

    // Shift tabs and close button opacity down
    var i = idx;
    while (i + 1 < g_tab_count) : (i += 1) {
        g_tabs[i] = g_tabs[i + 1];
        g_tab_close_opacity[i] = g_tab_close_opacity[i + 1];
    }
    g_tabs[g_tab_count - 1] = null;
    g_tab_close_opacity[g_tab_count - 1] = 0;
    g_tab_count -= 1;

    if (g_active_tab == idx) {
        if (g_active_tab >= g_tab_count) {
            g_active_tab = g_tab_count - 1;
        }
    } else if (g_active_tab > idx) {
        g_active_tab -= 1;
    }
}

/// Switch to the tab at the given index.
/// The caller is responsible for clearing selection/divider/resize state and setting rebuild flags.
pub fn switchTab(idx: usize) void {
    if (idx >= g_tab_count) return;
    g_active_tab = idx;
    // Clear bell indicator and force rebuild for surfaces in this tab
    if (g_tabs[idx]) |t| {
        if (t.kind != .terminal) return;
        var it = t.tree.iterator();
        while (it.next()) |entry| {
            entry.surface.bell_indicator = false;
            entry.surface.surface_renderer.force_rebuild = true;
            entry.surface.surface_renderer.cells_valid = false;
        }
    }
}

fn installAiChatHistoryHook(session: *ai_chat.Session) void {
    session.setHistoryChangeHook(g_ai_history_change_hook);
}

// ============================================================================
// Split operations
// ============================================================================

/// Split the focused surface in the given direction.
/// Returns true on success. The caller handles g_resize_active and rebuild flags.
pub fn splitFocused(
    allocator: std.mem.Allocator,
    direction: SplitTree.Split.Direction,
    cell_w: f32,
    cell_h: f32,
    cursor_style: CursorStyle,
    cursor_blink: bool,
    cwd: ?[*:0]const u16,
) bool {
    return splitFocusedReturningSurface(allocator, direction, cell_w, cell_h, cursor_style, cursor_blink, cwd) != null;
}

/// Split the focused surface and return the newly-created surface.
/// Returns null on failure. The caller handles g_resize_active and rebuild flags.
pub fn splitFocusedReturningSurface(
    allocator: std.mem.Allocator,
    direction: SplitTree.Split.Direction,
    cell_w: f32,
    cell_h: f32,
    cursor_style: CursorStyle,
    cursor_blink: bool,
    cwd: ?[*:0]const u16,
) ?*Surface {
    const t = activeTab() orelse return null;
    if (t.kind != .terminal) return null;
    const focused_surface = t.focusedSurface() orelse return null;
    const split_command = splitSpawnCommand(allocator, focused_surface);
    defer if (split_command) |command| allocator.free(command);
    const shell_cmd = split_command orelse getShellCmd();

    return splitFocusedSurfaceWithCommand(
        allocator,
        t,
        focused_surface,
        direction,
        cell_w,
        cell_h,
        cursor_style,
        cursor_blink,
        cwd,
        shell_cmd,
        true,
    );
}

fn splitFocusedSurfaceWithCommand(
    allocator: std.mem.Allocator,
    t: *TabState,
    focused_surface: *Surface,
    direction: SplitTree.Split.Direction,
    cell_w: f32,
    cell_h: f32,
    cursor_style: CursorStyle,
    cursor_blink: bool,
    cwd: ?[*:0]const u16,
    shell_cmd: [:0]const u16,
    inherit_ssh_connection: bool,
) ?*Surface {
    // Calculate exact dimensions for the new split surface
    const screen_w = focused_surface.size.screen.width;
    const screen_h = focused_surface.size.screen.height;
    const pad = focused_surface.getPadding();
    const pad_w = pad.left + pad.right;
    const pad_h = pad.top + pad.bottom;

    const half_div = @divTrunc(SPLIT_DIVIDER_WIDTH, 2);
    const new_screen_w: u32 = switch (direction) {
        .left, .right => @max(1, (screen_w / 2) -| half_div),
        .up, .down => screen_w,
    };
    const new_screen_h: u32 = switch (direction) {
        .left, .right => screen_h,
        .up, .down => @max(1, (screen_h / 2) -| half_div),
    };

    const avail_w = @as(i32, @intCast(new_screen_w)) - @as(i32, @intCast(pad_w));
    const avail_h = @as(i32, @intCast(new_screen_h)) - @as(i32, @intCast(pad_h));
    const calc_cols: u16 = if (avail_w > 0) @intFromFloat(@max(1, @as(f32, @floatFromInt(avail_w)) / cell_w)) else 10;
    const calc_rows: u16 = if (avail_h > 0) @intFromFloat(@max(1, @as(f32, @floatFromInt(avail_h)) / cell_h)) else 5;

    const MIN_COLS: u16 = 20;
    const MIN_ROWS: u16 = 5;
    const split_cols = @max(MIN_COLS, calc_cols);
    const split_rows = @max(MIN_ROWS, calc_rows);

    const new_surface = Surface.init(
        allocator,
        split_cols,
        split_rows,
        shell_cmd,
        g_scrollback_limit,
        cursor_style,
        cursor_blink,
        cwd,
    ) catch {
        std.debug.print("Failed to create Surface for split\n", .{});
        return null;
    };
    new_surface.attachRemoteClient(g_remote_client);

    if (inherit_ssh_connection) {
        if (focused_surface.ssh_connection) |conn| {
            new_surface.setSshConnection(conn.user(), conn.host(), conn.port(), conn.password(), conn.password_auth, conn.legacy_algorithms);
        }
    }

    // Pre-initialize size state to match what computeSplitLayout will compute
    new_surface.size.screen.width = new_screen_w;
    new_surface.size.screen.height = new_screen_h;
    new_surface.size.cell.width = cell_w;
    new_surface.size.cell.height = cell_h;
    new_surface.size.padding = pad;

    var insert_tree = SplitTree.init(allocator, new_surface) catch {
        std.debug.print("Failed to create SplitTree for split\n", .{});
        new_surface.deinit(allocator);
        return null;
    };
    new_surface.unref(allocator);
    defer insert_tree.deinit();

    const new_tree = t.tree.split(
        allocator,
        t.focused,
        direction,
        0.5,
        &insert_tree,
    ) catch {
        std.debug.print("Failed to split tree\n", .{});
        return null;
    };

    const new_handle: SplitTree.Node.Handle = @enumFromInt(t.tree.nodes.len);

    var old_tree = t.tree;
    t.tree = new_tree;
    old_tree.deinit();

    t.focused = new_handle;

    std.debug.print("Split created: initial size {}x{}, handle: {}, tree nodes: {}\n", .{ split_cols, split_rows, @intFromEnum(new_handle), t.tree.nodes.len });
    return new_surface;
}

/// Result of closing the focused split.
pub const CloseResult = enum {
    /// A split was removed from the tree. Caller should set rebuild flags.
    closed_split,
    /// The last split in the tab was closed, and there are other tabs.
    /// The tab has been closed via closeTab. Caller should clear UI state.
    closed_tab,
    /// The last split in the last tab was closed. Caller should set g_should_close.
    close_window,
    /// Nothing happened (no active tab).
    no_op,
};

/// Close the focused split. Returns what happened so the caller can handle side effects.
pub fn closeFocusedSplit(allocator: std.mem.Allocator) CloseResult {
    const t = activeTab() orelse return .no_op;
    if (t.kind == .ai_chat) {
        if (g_tab_count <= 1) return .close_window;
        closeTab(g_active_tab, allocator);
        return .closed_tab;
    }

    if (!t.tree.isSplit()) {
        if (g_tab_count <= 1) {
            return .close_window;
        } else {
            closeTab(g_active_tab, allocator);
            return .closed_tab;
        }
    }

    const next_focus = t.tree.goto(allocator, t.focused, .next_wrapped) catch null;

    const new_tree = t.tree.remove(allocator, t.focused) catch {
        std.debug.print("Failed to remove split from tree\n", .{});
        return .no_op;
    };

    var old_tree = t.tree;
    t.tree = new_tree;
    old_tree.deinit();

    if (t.tree.isEmpty()) {
        if (g_tab_count <= 1) {
            return .close_window;
        } else {
            closeTab(g_active_tab, allocator);
            return .closed_tab;
        }
    }

    // Find valid focus in new tree
    var it = t.tree.iterator();
    if (it.next()) |entry| {
        if (next_focus) |nf| {
            if (nf != t.focused and @intFromEnum(nf) < t.tree.nodes.len) {
                t.focused = nf;
            } else {
                t.focused = entry.handle;
            }
        } else {
            t.focused = entry.handle;
        }
    } else {
        t.focused = .root;
    }

    std.debug.print("Split closed, new focused handle: {}, tree nodes: {}\n", .{ @intFromEnum(t.focused), t.tree.nodes.len });
    return .closed_split;
}

/// Navigate to a split in the given direction. Returns true if focus changed.
pub fn gotoSplit(allocator: std.mem.Allocator, direction: SplitTree.Goto) bool {
    const t = activeTab() orelse return false;
    if (t.kind != .terminal) return false;
    const new_focus = t.tree.goto(allocator, t.focused, direction) catch return false;
    if (new_focus) |handle| {
        t.focused = handle;
        return true;
    }
    return false;
}

/// Equalize all split ratios. Returns true if equalization was performed.
pub fn equalizeSplits(allocator: std.mem.Allocator) bool {
    const t = activeTab() orelse return false;
    if (t.kind != .terminal) return false;

    var it = t.tree.iterator();
    while (it.next()) |entry| {
        entry.surface.resize_overlay_active = true;
        entry.surface.resize_overlay_last_cols = entry.surface.size.grid.cols;
        entry.surface.resize_overlay_last_rows = entry.surface.size.grid.rows;
    }

    const new_tree = t.tree.equalize(allocator) catch return false;
    t.tree.deinit();
    t.tree = new_tree;

    return true;
}

// ============================================================================
// Tab rename
// ============================================================================

pub fn startTabRename(tab_idx: usize) void {
    if (tab_idx >= g_tab_count) return;
    const t = g_tabs[tab_idx] orelse return;
    const title = t.getTitle();
    const len = @min(title.len, g_tab_rename_buf.len);
    @memcpy(g_tab_rename_buf[0..len], title[0..len]);
    g_tab_rename_len = len;
    g_tab_rename_cursor = len;
    @memcpy(g_tab_rename_orig_buf[0..len], title[0..len]);
    g_tab_rename_orig_len = len;
    g_tab_rename_idx = tab_idx;
    g_tab_rename_active = true;
    g_tab_rename_select_all = true;
}

pub fn commitTabRename() void {
    if (!g_tab_rename_active) return;
    if (g_tab_rename_idx < g_tab_count) {
        if (g_tabs[g_tab_rename_idx]) |t| {
            const changed = g_tab_rename_len != g_tab_rename_orig_len or
                !std.mem.eql(u8, g_tab_rename_buf[0..g_tab_rename_len], g_tab_rename_orig_buf[0..g_tab_rename_orig_len]);
            if (changed) {
                switch (t.kind) {
                    .terminal => if (t.focusedSurface()) |surface| {
                        surface.setTitleOverride(g_tab_rename_buf[0..g_tab_rename_len]);
                    },
                    .ai_chat => if (t.ai_chat_session) |session| {
                        session.setTitle(g_tab_rename_buf[0..g_tab_rename_len]);
                    },
                }
            }
        }
    }
    g_tab_rename_active = false;
}

pub fn cancelTabRename() void {
    g_tab_rename_active = false;
}

/// Handle a key event during tab rename. Does NOT reset cursor blink —
/// the caller should reset blink state before calling this.
pub fn handleRenameKey(ev: win32_backend.KeyEvent) void {
    if (ev.vk == win32_backend.VK_RETURN) {
        commitTabRename();
        return;
    }
    if (ev.vk == win32_backend.VK_ESCAPE) {
        cancelTabRename();
        return;
    }
    if (ev.vk == win32_backend.VK_BACK) {
        if (g_tab_rename_select_all) {
            g_tab_rename_len = 0;
            g_tab_rename_cursor = 0;
            g_tab_rename_select_all = false;
            return;
        }
        if (g_tab_rename_cursor > 0) {
            var i = g_tab_rename_cursor - 1;
            while (i > 0 and (g_tab_rename_buf[i] & 0xC0) == 0x80) i -= 1;
            const removed = g_tab_rename_cursor - i;
            const remaining = g_tab_rename_len - g_tab_rename_cursor;
            if (remaining > 0) {
                std.mem.copyForwards(u8, g_tab_rename_buf[i..], g_tab_rename_buf[g_tab_rename_cursor .. g_tab_rename_cursor + remaining]);
            }
            g_tab_rename_len -= removed;
            g_tab_rename_cursor = i;
        }
        return;
    }
    if (ev.vk == win32_backend.VK_DELETE) {
        if (g_tab_rename_select_all) {
            g_tab_rename_len = 0;
            g_tab_rename_cursor = 0;
            g_tab_rename_select_all = false;
            return;
        }
        if (g_tab_rename_cursor < g_tab_rename_len) {
            var end = g_tab_rename_cursor + 1;
            while (end < g_tab_rename_len and (g_tab_rename_buf[end] & 0xC0) == 0x80) end += 1;
            const removed = end - g_tab_rename_cursor;
            const remaining = g_tab_rename_len - end;
            if (remaining > 0) {
                std.mem.copyForwards(u8, g_tab_rename_buf[g_tab_rename_cursor..], g_tab_rename_buf[end .. end + remaining]);
            }
            g_tab_rename_len -= removed;
        }
        return;
    }
    if (ev.vk == win32_backend.VK_LEFT) {
        g_tab_rename_select_all = false;
        if (g_tab_rename_cursor > 0) {
            g_tab_rename_cursor -= 1;
            while (g_tab_rename_cursor > 0 and (g_tab_rename_buf[g_tab_rename_cursor] & 0xC0) == 0x80)
                g_tab_rename_cursor -= 1;
        }
        return;
    }
    if (ev.vk == win32_backend.VK_RIGHT) {
        g_tab_rename_select_all = false;
        if (g_tab_rename_cursor < g_tab_rename_len) {
            g_tab_rename_cursor += 1;
            while (g_tab_rename_cursor < g_tab_rename_len and (g_tab_rename_buf[g_tab_rename_cursor] & 0xC0) == 0x80)
                g_tab_rename_cursor += 1;
        }
        return;
    }
    if (ev.ctrl and ev.vk == 0x41) {
        g_tab_rename_select_all = false;
        g_tab_rename_cursor = 0;
        return;
    }
    if (ev.ctrl and ev.vk == 0x45) {
        g_tab_rename_select_all = false;
        g_tab_rename_cursor = g_tab_rename_len;
        return;
    }
    if (ev.ctrl and ev.vk == 0x55) {
        if (g_tab_rename_select_all) {
            g_tab_rename_len = 0;
            g_tab_rename_cursor = 0;
            g_tab_rename_select_all = false;
        } else if (g_tab_rename_cursor > 0) {
            const remaining = g_tab_rename_len - g_tab_rename_cursor;
            if (remaining > 0) {
                std.mem.copyForwards(u8, g_tab_rename_buf[0..remaining], g_tab_rename_buf[g_tab_rename_cursor .. g_tab_rename_cursor + remaining]);
            }
            g_tab_rename_len = remaining;
            g_tab_rename_cursor = 0;
        }
        return;
    }
    if (ev.ctrl and ev.vk == 0x4B) {
        if (g_tab_rename_select_all) {
            g_tab_rename_len = 0;
            g_tab_rename_cursor = 0;
            g_tab_rename_select_all = false;
        } else {
            g_tab_rename_len = g_tab_rename_cursor;
        }
        return;
    }
}

/// Insert a character during tab rename. Does NOT reset cursor blink —
/// the caller should reset blink state before calling this.
pub fn handleRenameChar(codepoint: u21) void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &buf) catch return;

    if (g_tab_rename_select_all) {
        if (len > g_tab_rename_buf.len) return;
        @memcpy(g_tab_rename_buf[0..len], buf[0..len]);
        g_tab_rename_len = len;
        g_tab_rename_cursor = len;
        g_tab_rename_select_all = false;
        return;
    }

    if (g_tab_rename_len + len > g_tab_rename_buf.len) return;

    if (g_tab_rename_cursor < g_tab_rename_len) {
        const remaining = g_tab_rename_len - g_tab_rename_cursor;
        std.mem.copyBackwards(u8, g_tab_rename_buf[g_tab_rename_cursor + len .. g_tab_rename_cursor + len + remaining], g_tab_rename_buf[g_tab_rename_cursor .. g_tab_rename_cursor + remaining]);
    }
    @memcpy(g_tab_rename_buf[g_tab_rename_cursor .. g_tab_rename_cursor + len], buf[0..len]);
    g_tab_rename_len += len;
    g_tab_rename_cursor += len;
}

// ============================================================================
// Session persistence — snapshot live tabs into POD for serialization
// ============================================================================

/// Build a session_persist.TabSnap from a live TabState by walking its
/// SplitTree. The returned snapshot owns its strings via `arena`. The arena
/// is the caller's responsibility to free (via Session.deinit pattern, or
/// shared across all tabs in a session).
pub fn snapshotTab(arena: std.mem.Allocator, t: *const TabState) !session_persist.TabSnap {
    if (t.kind != .terminal) return error.NotTerminalTab;
    if (t.tree.isEmpty()) return error.EmptyTree;

    // 1. Build NodeSnap tree.
    const tree = try snapshotNode(arena, &t.tree, .root);

    // 2. Find the focused leaf's index in pre-order. If `focused == .root`
    //    on a single-leaf tree, the root IS the leaf and computeFocusedLeafIndex
    //    correctly returns 0.
    const focused_leaf: u32 = computeFocusedLeafIndex(&t.tree, t.focused);

    // 3. Translate the optional zoomed handle to a pre-order leaf index.
    const zoomed_leaf: ?u32 = if (t.tree.zoomed) |z| computeFocusedLeafIndex(&t.tree, z) else null;

    return session_persist.TabSnap{
        .title_override = null,
        .focused_leaf = focused_leaf,
        .zoomed_leaf = zoomed_leaf,
        .tree = tree,
    };
}

fn snapshotNode(
    arena: std.mem.Allocator,
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
) !session_persist.NodeSnap {
    const node = tree.nodes[handle.idx()];
    return switch (node) {
        .leaf => |surface| .{ .leaf = .{ .surface = try snapshotSurface(arena, surface) } },
        .split => |sp| blk: {
            const left = try arena.create(session_persist.NodeSnap);
            left.* = try snapshotNode(arena, tree, sp.left);
            const right = try arena.create(session_persist.NodeSnap);
            right.* = try snapshotNode(arena, tree, sp.right);
            break :blk .{ .split = .{
                .layout = switch (sp.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = @as(f64, @floatCast(sp.ratio)),
                .left = left,
                .right = right,
            } };
        },
    };
}

fn snapshotSurface(arena: std.mem.Allocator, surface: *const Surface) !session_persist.SurfaceSnap {
    const cwd_opt: ?[]const u8 = surface.getCwd() orelse surface.getInitialCwd();
    const cwd_dup: ?[]const u8 = if (cwd_opt) |c| try arena.dupe(u8, c) else null;

    return switch (surface.surfaceKind()) {
        .local_shell => .{ .local_shell = .{
            .cwd = cwd_dup,
            .command = null,
        } },
        .ssh => blk: {
            // surfaceKind() returned .ssh, so ssh_connection is non-null.
            const conn = &surface.ssh_connection.?;
            const port_str = conn.port();
            const port_num: u16 = if (port_str.len == 0)
                22
            else
                std.fmt.parseInt(u16, port_str, 10) catch 22;
            break :blk .{ .ssh = .{
                .cwd = cwd_dup,
                .user = try arena.dupe(u8, conn.user()),
                .host = try arena.dupe(u8, conn.host()),
                .port = port_num,
            } };
        },
    };
}

fn computeFocusedLeafIndex(tree: *const SplitTree, target: SplitTree.Node.Handle) u32 {
    var idx: u32 = 0;
    var found: ?u32 = null;
    walkTreePreOrder(tree, .root, target, &idx, &found);
    return found orelse 0;
}

fn walkTreePreOrder(
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
    target: SplitTree.Node.Handle,
    idx: *u32,
    found: *?u32,
) void {
    if (found.* != null) return;
    const node = tree.nodes[handle.idx()];
    switch (node) {
        .leaf => {
            if (handle == target) found.* = idx.*;
            idx.* += 1;
        },
        .split => |sp| {
            walkTreePreOrder(tree, sp.left, target, idx, found);
            walkTreePreOrder(tree, sp.right, target, idx, found);
        },
    }
}

// ============================================================================
// Session persistence — restore one TabSnap into a live TabState
// ============================================================================
//
// SplitTree.fromSnapshot takes a free-function factory `(snap, gpa) -> ?*Surface`
// with no closure capture. The cols/rows/cursor settings the caller wants to
// apply to every restored Surface are conveyed through the thread-local
// "restore context" below: restoreTab sets it before calling fromSnapshot and
// the factory reads it for each leaf. This is safe because tab operations are
// single-threaded per appwindow and restore is synchronous.

threadlocal var g_restore_cols: u16 = 80;
threadlocal var g_restore_rows: u16 = 24;
threadlocal var g_restore_cursor_style: CursorStyle = .block;
threadlocal var g_restore_cursor_blink: bool = true;

/// Free-function factory passed to SplitTree.fromSnapshot. Reads dimensions
/// and cursor settings from the thread-local restore context populated by
/// restoreTab. Returns null on any failure so fromSnapshot can roll back the
/// whole tree.
fn surfaceFromSnap(
    snap: *const session_persist.SurfaceSnap,
    gpa: std.mem.Allocator,
) ?*Surface {
    return surfaceFromSnapImpl(snap, gpa) catch null;
}

fn surfaceFromSnapImpl(
    snap: *const session_persist.SurfaceSnap,
    gpa: std.mem.Allocator,
) !*Surface {
    const cols: u16 = @max(1, g_restore_cols);
    const rows: u16 = @max(1, g_restore_rows);
    const cursor_style = g_restore_cursor_style;
    const cursor_blink = g_restore_cursor_blink;

    switch (snap.*) {
        .local_shell => |sh| {
            // Convert cwd to UTF-16 (CreateProcessW copies the string during
            // Surface.init, so freeing after init is safe).
            var cwd_w_buf: ?[:0]u16 = null;
            defer if (cwd_w_buf) |b| gpa.free(b);
            const cwd_w: ?[*:0]const u16 = if (sh.cwd) |c| blk: {
                cwd_w_buf = try std.unicode.utf8ToUtf16LeAllocZ(gpa, c);
                break :blk cwd_w_buf.?.ptr;
            } else null;

            const command = getShellCmd();
            const surface = try Surface.init(gpa, cols, rows, command, g_scrollback_limit, cursor_style, cursor_blink, cwd_w);
            surface.attachRemoteClient(g_remote_client);
            return surface;
        },
        .ssh => |s| {
            // Build SSH command equivalent to splitSshCommand, with optional
            // trailing `cd <cwd>` argument when cwd is present. Mirrors the
            // password_auth=false (key-auth) branch since persisted SSH snaps
            // do not carry the password_auth flag. SSH password is never
            // persisted (security invariant I1); ssh.exe -tt handles any
            // password prompt interactively in the cmd.exe window.
            var stack_buf: [1024]u8 = undefined;
            const auth_flags = "-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 ";

            // Render the port to a stable scratch buffer first; we need the
            // port string both inside the spawned command and to pass to
            // setSshConnection below.
            var port_buf: [8]u8 = undefined;
            const port_slice = std.fmt.bufPrint(&port_buf, "{}", .{s.port}) catch return error.CommandTooLong;

            const base = std.fmt.bufPrint(&stack_buf, "cmd.exe /k ssh.exe -tt {s}-p {s} {s}@{s}", .{ auth_flags, port_slice, s.user, s.host }) catch return error.CommandTooLong;
            var final_len: usize = base.len;

            if (s.cwd) |cwd_str| {
                const escaped = try session_persist.shellSingleQuoteEscape(gpa, cwd_str);
                defer gpa.free(escaped);
                var trailing_buf: [768]u8 = undefined;
                const trail = std.fmt.bufPrint(&trailing_buf, " \"cd '{s}' 2>/dev/null; exec $SHELL -l\"", .{escaped}) catch return error.CommandTooLong;
                if (final_len + trail.len > stack_buf.len) return error.CommandTooLong;
                @memcpy(stack_buf[final_len..][0..trail.len], trail);
                final_len += trail.len;
            }

            const command_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, stack_buf[0..final_len]);
            defer gpa.free(command_w);
            const surface = try Surface.init(gpa, cols, rows, command_w, g_scrollback_limit, cursor_style, cursor_blink, null);
            surface.attachRemoteClient(g_remote_client);
            // SSH password is never persisted (security invariant I1). On restore,
            // ssh.exe -tt prompts interactively in cmd.exe if key auth fails;
            // the in-app password-autofill flow (which requires password_auth=true)
            // does not engage here.
            surface.setSshConnection(s.user, s.host, port_slice, "", false, g_ssh_legacy_algorithms);
            return surface;
        },
    }
}

/// Materialize one TabSnap into a new live tab. Returns true on success.
/// On any leaf failure, the SplitTree is rolled back, no tab is appended,
/// and false is returned — the caller (Task 18 wrapper) skips the failed tab.
///
/// cols/rows/cursor are sourced from the caller (AppWindow) since tab.zig
/// does not maintain its own copy of those values.
pub fn restoreTab(
    allocator: std.mem.Allocator,
    snap: *const session_persist.TabSnap,
    cols: u16,
    rows: u16,
    cursor_style: CursorStyle,
    cursor_blink: bool,
) bool {
    if (g_tab_count >= MAX_TABS) return false;

    // Populate the thread-local restore context so surfaceFromSnap can read
    // these values without changing the SplitTree.fromSnapshot factory ABI.
    g_restore_cols = cols;
    g_restore_rows = rows;
    g_restore_cursor_style = cursor_style;
    g_restore_cursor_blink = cursor_blink;

    var tree = SplitTree.fromSnapshot(allocator, &snap.tree, &surfaceFromSnap) catch |err| {
        std.debug.print("restoreTab: fromSnapshot failed: {}\n", .{err});
        return false;
    };

    const t = allocator.create(TabState) catch {
        tree.deinit();
        return false;
    };
    t.kind = .terminal;
    t.tree = tree;

    // Resolve focused_leaf from pre-order index back to a Handle.
    t.focused = handleOfNthLeaf(&t.tree, snap.focused_leaf) orelse .root;
    t.ai_chat_session = null;

    g_tabs[g_tab_count] = t;
    g_active_tab = g_tab_count;
    g_tab_count += 1;
    return true;
}

fn handleOfNthLeaf(tree: *const SplitTree, target_idx: u32) ?SplitTree.Node.Handle {
    var idx: u32 = 0;
    return findLeafHandle(tree, .root, target_idx, &idx);
}

fn findLeafHandle(
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
    target: u32,
    idx: *u32,
) ?SplitTree.Node.Handle {
    const node = tree.nodes[handle.idx()];
    return switch (node) {
        .leaf => blk: {
            if (idx.* == target) break :blk handle;
            idx.* += 1;
            break :blk null;
        },
        .split => |sp| blk: {
            if (findLeafHandle(tree, sp.left, target, idx)) |h| break :blk h;
            if (findLeafHandle(tree, sp.right, target, idx)) |h| break :blk h;
            break :blk null;
        },
    };
}

/// Walk all live tabs and build a complete Session POD. Caller owns the
/// returned ArenaAllocator; deinit it after the Session is no longer needed.
pub fn collectSessionSnapshot(arena: *std.heap.ArenaAllocator) !session_persist.Session {
    const alloc = arena.allocator();
    if (g_tab_count == 0) return error.NoTabs;

    const tabs = try alloc.alloc(session_persist.TabSnap, g_tab_count);
    var i: usize = 0;
    var written: usize = 0;
    while (i < g_tab_count) : (i += 1) {
        if (g_tabs[i]) |t| {
            tabs[written] = snapshotTab(alloc, t) catch continue;
            written += 1;
        }
    }
    if (written == 0) return error.NoTabs;

    return .{
        .version = session_persist.SCHEMA_VERSION,
        .active_tab = @intCast(@min(g_active_tab, written - 1)),
        .tabs = tabs[0..written],
    };
}

/// One-shot: collect the current session and write it atomically. Errors are
/// logged but not propagated — close path must not be blocked.
pub fn dumpSessionToFile(allocator: std.mem.Allocator) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const session = collectSessionSnapshot(&arena) catch |err| {
        std.debug.print("dumpSessionToFile: collect failed: {}\n", .{err});
        return;
    };

    const path = Config.sessionFilePath(allocator) catch |err| {
        std.debug.print("dumpSessionToFile: sessionFilePath failed: {}\n", .{err});
        return;
    };
    defer allocator.free(path);

    session_persist.dumpSession(allocator, path, session) catch |err| {
        std.debug.print("dumpSessionToFile: dumpSession failed: {}\n", .{err});
    };
}

/// Read the session file and rebuild tabs. Returns true iff at least one
/// tab was restored (caller should then skip openDefaultTab).
///
/// Caller passes the same cols/rows/cursor that openDefaultTab would use.
pub fn restoreSessionFromFile(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    cursor_style: CursorStyle,
    cursor_blink: bool,
) bool {
    const path = Config.sessionFilePath(allocator) catch return false;
    defer allocator.free(path);

    var loaded = (session_persist.loadSession(allocator, path) catch return false) orelse return false;
    defer loaded.deinit();

    session_persist.normalize(&loaded.value);

    var rebuilt: usize = 0;
    for (loaded.value.tabs) |*snap| {
        if (restoreTab(allocator, snap, cols, rows, cursor_style, cursor_blink)) {
            rebuilt += 1;
        } else {
            std.debug.print("restoreSessionFromFile: skipping failed tab\n", .{});
        }
    }
    if (rebuilt == 0) return false;

    const target = @min(@as(usize, loaded.value.active_tab), rebuilt - 1);
    switchTab(target);
    return true;
}
