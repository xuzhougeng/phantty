# Plan: Issue #14 - Resize splits by dragging the divider

**Status: COMPLETED**

## Overview

Allow users to resize split panes by clicking and dragging the split divider.

## Current State

- Split dividers are rendered as 2-pixel wide lines between split panes
- `SPLIT_DIVIDER_WIDTH = 2` pixels (in `AppWindow.zig:602`)
- Dividers are rendered in `renderSplitDividers()` at line 4234
- No mouse interaction with dividers currently exists
- Mouse handling is in `handleMouseButton()` (line 5793) and `handleMouseMove()` (line 6071)

## Ghostty Reference

Ghostty uses GTK's `Paned` widget which has built-in drag-to-resize. Key insights from `src/apprt/gtk/class/split_tree.zig`:

1. Uses `gtk.Paned` which handles all the drag interaction natively
2. When the user drags, it detects the change via `propPosition` callback
3. Updates the split ratio in the tree via `tree.resizeInPlace(handle, ratio)`
4. The ratio is a value between 0 and 1

For Phantty, we need to implement this manually since we render with OpenGL.

## Implementation Plan

### Step 1: Add State Variables for Divider Dragging

Add new threadlocal state variables in `AppWindow.zig`:

```zig
// Split divider dragging state
threadlocal var g_divider_dragging: bool = false;
threadlocal var g_divider_drag_handle: ?SplitTree.Node.Handle = null;  // Handle of the split node being resized
threadlocal var g_divider_drag_layout: ?SplitTree.Split.Layout = null; // horizontal or vertical
threadlocal var g_divider_drag_start_ratio: f16 = 0.5;  // ratio when drag started
threadlocal var g_divider_drag_start_pos: f32 = 0;  // mouse position when drag started
```

### Step 2: Define Hit Area for Dividers

Increase the hit area from 2 pixels to a more usable size:

```zig
const SPLIT_DIVIDER_HIT_WIDTH: i32 = 8;  // Larger hit area for easier grabbing
```

### Step 3: Implement Divider Hit Testing

Create a function to detect if a mouse position is over a split divider:

```zig
/// Check if a point is over a split divider.
/// Returns the split node handle and layout if found, null otherwise.
fn hitTestDivider(x: i32, y: i32) ?struct {
    handle: SplitTree.Node.Handle,
    layout: SplitTree.Split.Layout,
    ratio_pos: f32,  // position along the divider axis (0-1)
} {
    const tab = activeTab() orelse return null;
    if (tab.tree.isEmpty()) return null;
    
    const allocator = g_allocator orelse return null;
    var spatial = tab.tree.spatial(allocator) catch return null;
    defer spatial.deinit(allocator);
    
    // Get content area dimensions
    const win = g_window orelse return null;
    const fb = win.getFramebufferSize();
    const content_x = DEFAULT_PADDING;
    const content_y = win32_backend.TITLEBAR_HEIGHT;
    const content_w = fb.width - 2 * DEFAULT_PADDING;
    const content_h = fb.height - content_y - DEFAULT_PADDING;
    
    // Check each split node
    for (tab.tree.nodes, 0..) |node, i| {
        switch (node) {
            .split => |s| {
                const handle: SplitTree.Node.Handle = @enumFromInt(i);
                const slot = spatial.slots[i];
                
                // Convert normalized coords to pixels
                const slot_x = content_x + slot.x * content_w;
                const slot_y = content_y + slot.y * content_h;
                const slot_w = slot.width * content_w;
                const slot_h = slot.height * content_h;
                
                // Calculate divider position
                const half_hit = SPLIT_DIVIDER_HIT_WIDTH / 2;
                
                switch (s.layout) {
                    .horizontal => {
                        // Vertical divider line
                        const div_x = slot_x + slot_w * s.ratio;
                        if (x >= div_x - half_hit and x <= div_x + half_hit and
                            y >= slot_y and y <= slot_y + slot_h) {
                            return .{
                                .handle = handle,
                                .layout = .horizontal,
                                .ratio_pos = (y - slot_y) / slot_h,
                            };
                        }
                    },
                    .vertical => {
                        // Horizontal divider line
                        const div_y = slot_y + slot_h * s.ratio;
                        if (y >= div_y - half_hit and y <= div_y + half_hit and
                            x >= slot_x and x <= slot_x + slot_w) {
                            return .{
                                .handle = handle,
                                .layout = .vertical,
                                .ratio_pos = (x - slot_x) / slot_w,
                            };
                        }
                    },
                }
            },
            .leaf => {},
        }
    }
    
    return null;
}
```

### Step 4: Update Cursor on Divider Hover

In `handleMouseMove()`, check if hovering over a divider and change the cursor:

```zig
// Check for divider hover (after checking scrollbar)
if (!g_scrollbar_dragging and !g_divider_dragging) {
    if (hitTestDivider(@intFromFloat(xpos), @intFromFloat(ypos))) |hit| {
        // Set resize cursor based on layout
        switch (hit.layout) {
            .horizontal => win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE)),
            .vertical => win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZENS)),
        }
        g_divider_hover = true;
    } else if (g_divider_hover) {
        // Reset to default cursor
        win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_ARROW));
        g_divider_hover = false;
    }
}
```

### Step 5: Handle Mouse Press on Divider

In `handleMouseButton()`, detect clicks on dividers:

```zig
// Check if click is on a split divider
if (hitTestDivider(@intFromFloat(xpos), @intFromFloat(ypos))) |hit| {
    g_divider_dragging = true;
    g_divider_drag_handle = hit.handle;
    g_divider_drag_layout = hit.layout;
    
    // Store the starting position and ratio
    const split = tab.tree.nodes[hit.handle.idx()].split;
    g_divider_drag_start_ratio = split.ratio;
    g_divider_drag_start_pos = switch (hit.layout) {
        .horizontal => @floatCast(xpos),
        .vertical => @floatCast(ypos),
    };
    return;
}
```

### Step 6: Handle Divider Dragging

In `handleMouseMove()`, update the split ratio when dragging:

```zig
// Handle divider drag
if (g_divider_dragging) {
    if (g_divider_drag_handle) |handle| {
        const tab = activeTab() orelse return;
        
        // Get content area dimensions
        const win = g_window orelse return;
        const fb = win.getFramebufferSize();
        const content_x = DEFAULT_PADDING;
        const content_y = win32_backend.TITLEBAR_HEIGHT;
        const content_w = fb.width - 2 * DEFAULT_PADDING;
        const content_h = fb.height - content_y - DEFAULT_PADDING;
        
        // Get spatial info for this split
        const allocator = g_allocator orelse return;
        var spatial = tab.tree.spatial(allocator) catch return;
        defer spatial.deinit(allocator);
        
        const slot = spatial.slots[handle.idx()];
        
        // Calculate new ratio based on mouse position
        const layout = g_divider_drag_layout orelse return;
        const new_ratio: f16 = switch (layout) {
            .horizontal => blk: {
                const slot_x = content_x + slot.x * content_w;
                const slot_w = slot.width * content_w;
                const mouse_x: f32 = @floatCast(xpos);
                break :blk @floatCast(@max(0.1, @min(0.9, (mouse_x - slot_x) / slot_w)));
            },
            .vertical => blk: {
                const slot_y = content_y + slot.y * content_h;
                const slot_h = slot.height * content_h;
                const mouse_y: f32 = @floatCast(ypos);
                break :blk @floatCast(@max(0.1, @min(0.9, (mouse_y - slot_y) / slot_h)));
            },
        };
        
        // Update the ratio in place
        tab.tree.resizeInPlace(handle, new_ratio);
        
        // Force layout recalculation and redraw
        g_force_rebuild = true;
        g_cells_valid = false;
    }
    return;
}
```

### Step 7: Handle Mouse Release

In `handleMouseButton()`, end the drag:

```zig
if (ev.action == .release) {
    if (g_divider_dragging) {
        g_divider_dragging = false;
        g_divider_drag_handle = null;
        g_divider_drag_layout = null;
        // Reset cursor
        win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_ARROW));
        return;
    }
    // ... existing release handling
}
```

### Step 8: Resize Surfaces After Ratio Change

After updating the ratio, the `computeSplitLayout()` function already recalculates surface sizes and calls `setScreenSize()` on each surface. This should automatically handle terminal content reflow.

### Step 9: Add Win32 Cursor Functions

Add the necessary Win32 cursor functions to `win32.zig`:

```zig
pub extern "user32" fn SetCursor(hCursor: HCURSOR) callconv(WINAPI) HCURSOR;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: [*:0]const u16) callconv(WINAPI) ?HCURSOR;

pub const HCURSOR = *opaque {};
pub const IDC_ARROW = @intToPtr([*:0]const u16, 32512);
pub const IDC_SIZEWE = @intToPtr([*:0]const u16, 32644);  // horizontal resize
pub const IDC_SIZENS = @intToPtr([*:0]const u16, 32645);  // vertical resize
```

## Testing

1. Create a split (Ctrl+Shift+O or Ctrl+Shift+E)
2. Hover over the divider - cursor should change to resize cursor
3. Click and drag - split should resize in real-time
4. Terminal content in both panes should reflow during drag
5. Release - cursor should return to normal
6. Test with multiple nested splits
7. Test edge cases: minimum size constraints (10% min ratio)

## Files to Modify

1. `src/AppWindow.zig` - Main implementation
2. `src/win32.zig` - Add cursor functions (if not already present)

## Notes

- Minimum ratio of 0.1 (10%) prevents splits from becoming too small
- Maximum ratio of 0.9 (90%) prevents opposite split from becoming too small
- The `resizeInPlace` function on SplitTree is specifically designed for this use case
- Consider adding a visual highlight when hovering over a divider (future enhancement)

## Implementation Summary

### Files Modified

1. **`src/win32.zig`**
   - Added `SetCursor` function export
   - Added public `LoadCursor` helper wrapper  
   - Added cursor resource constants: `IDC_ARROW`, `IDC_SIZEWE`, `IDC_SIZENS`

2. **`src/AppWindow.zig`**
   - Added state variables for divider dragging:
     - `SPLIT_DIVIDER_HIT_WIDTH` (8 pixels)
     - `g_divider_hover`, `g_divider_dragging`
     - `g_divider_drag_handle`, `g_divider_drag_layout`
   - Added `DividerHit` struct and `hitTestDivider()` function
   - Updated `handleMouseButton()` to start/end divider drag
   - Updated `handleMouseMove()` to:
     - Handle divider dragging with ratio calculation
     - Update cursor on divider hover
   - Added `renderResizeOverlayForSurface()` function
   - Refactored `renderResizeOverlayText()` as shared core
   - Updated render loop to show resize overlays on ALL splits during divider drag

### Behavior

- Hovering over a split divider changes cursor to resize cursor (↔ or ↕)
- Click and drag to resize splits in real-time
- During drag, resize overlay shows dimensions on ALL splits (not just focused)
- Minimum 10% / maximum 90% ratio prevents splits from becoming too small
- Terminal content reflows during the drag
