# Plan: Migrate to Per-Surface Render State

## Problem
AppWindow.zig uses global `threadlocal` variables for render state, but we already have a `Renderer` struct per Surface that contains the same fields. When rendering multiple surfaces (splits), the globals get overwritten, causing cursor/content misalignment.

## Current State
- `src/Renderer.zig` - Already has per-surface state (snap, cells, cursor cache, etc.)
- `src/Surface.zig` - Each Surface owns a `surface_renderer: Renderer`
- `src/AppWindow.zig` - Still uses global `g_snap[]`, `g_cached_cursor_*`, etc.

## Goal
Use `surface.surface_renderer.*` instead of globals when rendering each surface.

## Implementation Steps

### Phase 1: Remove Duplicate Globals
Remove these threadlocal globals from AppWindow.zig (they're duplicated in Renderer):
- `g_snap[]`, `g_snap_rows`, `g_snap_cols`
- `g_cached_cursor_x`, `g_cached_cursor_y`, `g_cached_cursor_style`, etc.
- `g_cached_viewport_at_bottom`, `g_cached_cursor_in_viewport`
- `g_cells_valid`, `g_force_rebuild`
- `g_last_cursor_*`, `g_last_viewport_*`, `g_last_rows`, `g_last_cols`
- `bg_cells[]`, `fg_cells[]`, `color_fg_cells[]`, `*_cell_count`
- `g_split_is_focused`

Keep these globals (they're truly global, not per-surface):
- `g_cursor_blink_visible`, `g_last_blink_time` (shared blink state)
- `g_current_render_surface` (tracks which surface we're rendering)
- Theme/color globals
- GL shader/VAO handles (shared across surfaces)
- Atlas textures (shared)

### Phase 2: Update updateTerminalCells()
Change signature to take Renderer* and write to it:
```zig
fn updateTerminalCells(rend: *Renderer, terminal: *ghostty_vt.Terminal, is_focused: bool) bool
```

Update all reads/writes from globals to `rend.*`:
- `g_cached_cursor_y` → `rend.cached_cursor_y`
- `g_snap[...]` → `rend.snap[...]`
- etc.

### Phase 3: Update snapshotCells()
Change signature:
```zig
fn snapshotCells(rend: *Renderer, terminal: *ghostty_vt.Terminal) void
```

### Phase 4: Update rebuildCells()
Change signature to read from Renderer and write to Renderer:
```zig
fn rebuildCells(rend: *Renderer) void
```

Reads: `rend.snap_rows`, `rend.snap_cols`, `rend.snap[]`, `rend.cached_cursor_*`
Writes: `rend.bg_cells[]`, `rend.fg_cells[]`, `rend.bg_cell_count`, etc.

### Phase 5: Update drawCells()
Change signature to read from Renderer:
```zig
fn drawCells(rend: *const Renderer, window_height: f32, offset_x: f32, offset_y: f32) void
```

Reads cursor position, cell buffers from `rend.*`

### Phase 6: Update Render Loop
In the main render loop, pass the surface's renderer to each function:

Single surface path:
```zig
if (activeSurface()) |surface| {
    const rend = &surface.surface_renderer;
    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();
    updateCursorBlink();
    const needs_rebuild = updateTerminalCells(rend, &surface.terminal, true);
    if (needs_rebuild) rebuildCells(rend);
    drawCells(rend, ...);
}
```

Multi-split path:
```zig
for (splits) |rect| {
    const rend = &rect.surface.surface_renderer;
    rect.surface.render_state.mutex.lock();
    defer rect.surface.render_state.mutex.unlock();
    const is_focused = (rect.handle == tab.focused);
    const needs_rebuild = updateTerminalCells(rend, &rect.surface.terminal, is_focused);
    if (needs_rebuild) rebuildCells(rend);
    drawCells(rend, ...);
}
```

### Phase 7: Cursor Blink
Move cursor blink to per-surface (it's already in Renderer):
- Each Renderer has `cursor_blink_visible`, `last_cursor_blink_time`
- Update `updateCursorBlink()` to take Renderer*
- Or keep global blink state if we want all cursors to blink in sync

## Files to Modify
1. `src/AppWindow.zig` - Main changes
2. `src/Renderer.zig` - May need minor adjustments

## Testing
1. Single tab, single surface - cursor alignment
2. Multiple tabs - switching doesn't carry over stale state
3. Splits - each split has independent cursor state
4. Ctrl+L clear - cursor stays aligned with prompt
5. Resize - cursor stays correct after terminal resize
