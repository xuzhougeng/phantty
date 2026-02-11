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

// ============================================================================
// Tab model — each tab owns a SplitTree of Surfaces
// ============================================================================

pub const TabState = struct {
    tree: SplitTree,
    focused: SplitTree.Node.Handle = .root,

    /// Get the focused surface in this tab, or null if tree is empty
    pub fn focusedSurface(self: *const TabState) ?*Surface {
        if (self.tree.isEmpty()) return null;
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
        const surface = self.focusedSurface() orelse return "phantty";
        return surface.getTitle();
    }

    pub fn deinit(self: *TabState, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.tree.deinit();
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

/// Get the active tab's focused surface's selection
pub fn activeSelection() *Selection {
    if (g_tab_count > 0) {
        if (g_tabs[g_active_tab]) |t| {
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
    return g_tabs[g_active_tab] != null;
}

// ============================================================================
// Tab operations
// ============================================================================

/// Spawn a new tab with its own Surface (PTY + terminal).
/// The caller is responsible for clearing UI state (selection, divider, resize overlay)
/// and setting rebuild flags after a successful spawn.
pub fn spawnTabWithCwd(allocator: std.mem.Allocator, cols: u16, rows: u16, cursor_style: CursorStyle, cursor_blink: bool, cwd: ?[*:0]const u16) bool {
    if (g_tab_count >= MAX_TABS) return false;

    const surface = Surface.init(
        allocator,
        cols,
        rows,
        getShellCmd(),
        g_scrollback_limit,
        cursor_style,
        cursor_blink,
        cwd,
    ) catch {
        std.debug.print("Failed to create Surface for new tab\n", .{});
        return false;
    };

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
    t.tree = tree;
    t.focused = .root;

    g_tabs[g_tab_count] = t;
    g_active_tab = g_tab_count;
    g_tab_count += 1;

    std.debug.print("New tab spawned (count={}), active: {}\n", .{ g_tab_count, g_active_tab });
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
        var it = t.tree.iterator();
        while (it.next()) |entry| {
            entry.surface.bell_indicator = false;
            entry.surface.surface_renderer.force_rebuild = true;
            entry.surface.surface_renderer.cells_valid = false;
        }
    }
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
    const t = activeTab() orelse return false;
    const focused_surface = t.focusedSurface() orelse return false;

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
        getShellCmd(),
        g_scrollback_limit,
        cursor_style,
        cursor_blink,
        cwd,
    ) catch {
        std.debug.print("Failed to create Surface for split\n", .{});
        return false;
    };

    // Pre-initialize size state to match what computeSplitLayout will compute
    new_surface.size.screen.width = new_screen_w;
    new_surface.size.screen.height = new_screen_h;
    new_surface.size.cell.width = cell_w;
    new_surface.size.cell.height = cell_h;
    new_surface.size.padding = pad;

    var insert_tree = SplitTree.init(allocator, new_surface) catch {
        std.debug.print("Failed to create SplitTree for split\n", .{});
        new_surface.deinit(allocator);
        return false;
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
        return false;
    };

    const new_handle: SplitTree.Node.Handle = @enumFromInt(t.tree.nodes.len);

    var old_tree = t.tree;
    t.tree = new_tree;
    old_tree.deinit();

    t.focused = new_handle;

    std.debug.print("Split created: initial size {}x{}, handle: {}, tree nodes: {}\n", .{ split_cols, split_rows, @intFromEnum(new_handle), t.tree.nodes.len });
    return true;
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
                if (t.focusedSurface()) |surface| {
                    surface.setTitleOverride(g_tab_rename_buf[0..g_tab_rename_len]);
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

