//! Split layout computation for AppWindow.
//!
//! Computes pixel rectangles for each surface in a split tree, handles
//! hit-testing for split dividers, and provides surface-at-point lookup.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const tab = AppWindow.tab;
const input = AppWindow.input;
const overlays = AppWindow.overlays;
const font = AppWindow.font;
const gl_init = AppWindow.gl_init;
const Surface = @import("../Surface.zig");
const SplitTree = @import("../split_tree.zig");
const renderer = @import("../renderer.zig");
const win32_backend = @import("../win32.zig");

const TabState = tab.TabState;
pub const MAX_SPLITS_PER_TAB = tab.MAX_SPLITS_PER_TAB;
const SPLIT_DIVIDER_WIDTH = tab.SPLIT_DIVIDER_WIDTH;
pub const DEFAULT_PADDING = tab.DEFAULT_PADDING;

/// Pixel rectangle for a split surface, including computed terminal dimensions
pub const SplitRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    cols: u16,
    rows: u16,
    surface: *Surface,
    handle: SplitTree.Node.Handle,
};

/// Hit test result for split dividers
pub const DividerHit = struct {
    handle: SplitTree.Node.Handle,
    layout: SplitTree.Split.Layout,
};

/// Computed split rects for the active tab (updated each frame)
pub threadlocal var g_split_rects: [MAX_SPLITS_PER_TAB]SplitRect = undefined;
pub threadlocal var g_split_rect_count: usize = 0;

/// Find the surface under a given point (window coordinates).
/// Returns null if no surface is found at that position.
pub fn surfaceAtPoint(x: i32, y: i32) ?*Surface {
    for (0..g_split_rect_count) |i| {
        const rect = g_split_rects[i];
        if (x >= rect.x and x < rect.x + rect.width and
            y >= rect.y and y < rect.y + rect.height)
        {
            return rect.surface;
        }
    }
    return null;
}

/// Check if a point is over a split divider.
/// Returns the split node handle and layout if found, null otherwise.
pub fn hitTestDivider(x: i32, y: i32) ?DividerHit {
    const active_tab = tab.activeTab() orelse return null;
    if (active_tab.tree.isEmpty() or !active_tab.tree.isSplit()) return null;

    const allocator = AppWindow.g_allocator orelse return null;
    var spatial = active_tab.tree.spatial(allocator) catch return null;
    defer spatial.deinit(allocator);

    // Get content area dimensions
    const win = AppWindow.g_window orelse return null;
    const fb = win.getFramebufferSize();
    const content_x: f32 = @floatFromInt(DEFAULT_PADDING);
    const content_y: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
    const content_w: f32 = @floatFromInt(@as(i32, @intCast(fb.width)) - @as(i32, @intCast(2 * DEFAULT_PADDING)));
    const content_h: f32 = @floatFromInt(@as(i32, @intCast(fb.height)) - win32_backend.TITLEBAR_HEIGHT - @as(i32, @intCast(DEFAULT_PADDING)));

    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);
    const half_hit = input.SPLIT_DIVIDER_HIT_WIDTH / 2;

    // Check each split node for divider hit
    for (active_tab.tree.nodes, 0..) |node, i| {
        switch (node) {
            .split => |s| {
                const handle: SplitTree.Node.Handle = @enumFromInt(i);
                const slot = spatial.slots[i];

                // Convert normalized coords to pixels
                const slot_x = content_x + @as(f32, @floatCast(slot.x)) * content_w;
                const slot_y = content_y + @as(f32, @floatCast(slot.y)) * content_h;
                const slot_w = @as(f32, @floatCast(slot.width)) * content_w;
                const slot_h = @as(f32, @floatCast(slot.height)) * content_h;

                switch (s.layout) {
                    .horizontal => {
                        // Vertical divider line at ratio position
                        const div_x = slot_x + slot_w * @as(f32, @floatCast(s.ratio));
                        if (xf >= div_x - half_hit and xf <= div_x + half_hit and
                            yf >= slot_y and yf <= slot_y + slot_h)
                        {
                            return .{ .handle = handle, .layout = .horizontal };
                        }
                    },
                    .vertical => {
                        // Horizontal divider line at ratio position
                        const div_y = slot_y + slot_h * @as(f32, @floatCast(s.ratio));
                        if (yf >= div_y - half_hit and yf <= div_y + half_hit and
                            xf >= slot_x and xf <= slot_x + slot_w)
                        {
                            return .{ .handle = handle, .layout = .vertical };
                        }
                    },
                }
            },
            .leaf => {},
        }
    }

    return null;
}

/// Compute split layout for a tab, returning pixel rects for each surface.
/// Each surface is resized to fit its allocated area with proper padding.
/// Returns the number of surfaces (0 if tree is empty).
pub fn computeSplitLayout(
    active_tab: *const TabState,
    content_x: i32,
    content_y: i32,
    content_w: i32,
    content_h: i32,
    cw: f32, // font.cell_width
    ch: f32, // font.cell_height
) usize {
    if (active_tab.tree.isEmpty()) return 0;

    // Get spatial representation (normalized 0-1 coordinates)
    const allocator = AppWindow.g_allocator orelse return 0;
    var spatial = active_tab.tree.spatial(allocator) catch return 0;
    defer spatial.deinit(allocator);

    _ = cw;
    _ = ch;

    var count: usize = 0;
    var it = active_tab.tree.iterator();
    while (it.next()) |entry| {
        if (count >= MAX_SPLITS_PER_TAB) break;

        const slot = spatial.slots[entry.handle.idx()];

        // Convert normalized coords to pixels
        const x_f: f32 = @as(f32, @floatCast(slot.x)) * @as(f32, @floatFromInt(content_w));
        const y_f: f32 = @as(f32, @floatCast(slot.y)) * @as(f32, @floatFromInt(content_h));
        const w_f: f32 = @as(f32, @floatCast(slot.width)) * @as(f32, @floatFromInt(content_w));
        const h_f: f32 = @as(f32, @floatCast(slot.height)) * @as(f32, @floatFromInt(content_h));

        // Apply divider insets (half-divider on each side adjacent to other splits)
        var px: i32 = content_x + @as(i32, @intFromFloat(x_f));
        var py: i32 = content_y + @as(i32, @intFromFloat(y_f));
        var pw: i32 = @as(i32, @intFromFloat(w_f));
        var ph: i32 = @as(i32, @intFromFloat(h_f));

        // Inset for dividers (only if not at edge)
        const half_div = @divTrunc(SPLIT_DIVIDER_WIDTH, 2);
        const at_left_edge = slot.x < 0.001;
        const at_right_edge = slot.x + slot.width >= 0.999;
        if (slot.x > 0.001) {
            px += half_div;
            pw -= half_div;
        }
        if (slot.x + slot.width < 0.999) {
            pw -= half_div;
        }
        if (slot.y > 0.001) {
            py += half_div;
            ph -= half_div;
        }
        if (slot.y + slot.height < 0.999) {
            ph -= half_div;
        }

        // Extend splits at left edge to window edge (consistent left margin)
        if (at_left_edge) {
            px -= @intCast(DEFAULT_PADDING);
            pw += @intCast(DEFAULT_PADDING);
        }

        // Extend splits at right edge to window edge (so scrollbar hugs window edge)
        if (at_right_edge) {
            pw += @intCast(DEFAULT_PADDING);
        }

        // Set the surface screen size with padding.
        // The surface computes grid size and balanced padding internally.
        // Right padding must account for scrollbar width plus gap.
        const surface = entry.surface;
        const scrollbar_padding: u32 = @intFromFloat(overlays.SCROLLBAR_WIDTH + DEFAULT_PADDING);
        const explicit_padding = renderer.size.Padding{
            .top = DEFAULT_PADDING,
            .bottom = DEFAULT_PADDING,
            .left = DEFAULT_PADDING,
            .right = scrollbar_padding,
        };

        const resized = surface.setScreenSize(
            allocator,
            if (pw > 0) @intCast(pw) else 1,
            if (ph > 0) @intCast(ph) else 1,
            font.cell_width,
            font.cell_height,
            explicit_padding,
        );

        if (resized) {
            AppWindow.g_force_rebuild = true;
            // Show resize overlay with new dimensions (but not during divider drag,
            // which has its own per-surface overlay logic)
            if (!input.g_divider_dragging) {
                overlays.resizeOverlayShow(surface.size.grid.cols, surface.size.grid.rows);
            }
        }

        // Track per-surface size changes for divider drag overlay
        if (input.g_divider_dragging) {
            const cols = surface.size.grid.cols;
            const rows = surface.size.grid.rows;
            if (cols != surface.resize_overlay_last_cols or rows != surface.resize_overlay_last_rows) {
                surface.resize_overlay_active = true;
                surface.resize_overlay_last_cols = cols;
                surface.resize_overlay_last_rows = rows;
            }
        }

        g_split_rects[count] = .{
            .x = px,
            .y = py,
            .width = pw,
            .height = ph,
            .cols = surface.size.grid.cols,
            .rows = surface.size.grid.rows,
            .surface = surface,
            .handle = entry.handle,
        };
        count += 1;
    }

    g_split_rect_count = count;
    return count;
}
