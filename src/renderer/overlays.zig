//! Overlay rendering for AppWindow.
//!
//! Scrollbar (macOS-style overlay with fade), resize overlay ("cols x rows"),
//! debug overlays (FPS, draw calls), split dividers, and unfocused split overlays.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const tab = AppWindow.tab;
const gl_init = AppWindow.gl_init;
const split_layout = AppWindow.split_layout;
const Surface = @import("../Surface.zig");
const SplitTree = @import("../split_tree.zig");

const c = @cImport({
    @cInclude("glad/gl.h");
});

const TabState = tab.TabState;
const SplitRect = split_layout.SplitRect;

// ============================================================================
// Scrollbar — macOS-style overlay scrollbar with fade
// ============================================================================

pub const SCROLLBAR_WIDTH: f32 = 12; // Width of the scrollbar track
const SCROLLBAR_MARGIN: f32 = 2; // Margin from right edge
const SCROLLBAR_MIN_THUMB: f32 = 20; // Minimum thumb height in pixels
const SCROLLBAR_FADE_DELAY_MS: i64 = 800; // ms to wait before fading
const SCROLLBAR_FADE_DURATION_MS: i64 = 400; // ms for fade-out animation
const SCROLLBAR_HOVER_WIDTH: f32 = 12; // Wider hit area for hover/drag

// Per-surface scrollbar opacity/timing lives in Surface.zig.
// These are global interaction state (only one mouse):
pub threadlocal var g_scrollbar_hover: bool = false; // Mouse is over scrollbar area
pub threadlocal var g_scrollbar_dragging: bool = false; // Currently dragging the thumb
pub threadlocal var g_scrollbar_drag_offset: f32 = 0; // Offset within thumb where drag started

// ============================================================================
// Split divider rendering
// ============================================================================

const SPLIT_DIVIDER_WIDTH = tab.SPLIT_DIVIDER_WIDTH;

/// Unfocused split opacity (default 0.7, configurable)
pub threadlocal var g_unfocused_split_opacity: f32 = 0.7;

/// Split divider color (null = use scrollbar style with alpha)
pub threadlocal var g_split_divider_color: ?[3]f32 = null;

// Split resize overlay (for equalize/keyboard resize - shows overlay on all splits temporarily)
pub threadlocal var g_split_resize_overlay_until: i64 = 0; // Timestamp when overlay should hide

// ============================================================================
// Resize overlay — shows terminal size during resize (like Ghostty)
// ============================================================================

pub const RESIZE_OVERLAY_DURATION_MS: i64 = 750; // How long to show after resize stops
const RESIZE_OVERLAY_FADE_MS: i64 = 150; // Fade out duration
const RESIZE_OVERLAY_FIRST_DELAY_MS: i64 = 500; // Delay before first overlay shows

// Global resize overlay state
pub threadlocal var g_resize_overlay_visible: bool = false; // Whether overlay should be showing
threadlocal var g_resize_overlay_last_change: i64 = 0; // When size last changed
threadlocal var g_resize_overlay_cols: u16 = 0; // Current cols being displayed
threadlocal var g_resize_overlay_rows: u16 = 0; // Current rows being displayed
threadlocal var g_resize_overlay_last_cols: u16 = 0; // Last "settled" cols (after timeout)
threadlocal var g_resize_overlay_last_rows: u16 = 0; // Last "settled" rows (after timeout)
threadlocal var g_resize_overlay_ready: bool = false; // Set after initial delay
threadlocal var g_resize_overlay_init_time: i64 = 0; // When window was created
pub threadlocal var g_resize_overlay_opacity: f32 = 0; // For fade out animation

// Resize active state (for cursor hiding) - separate from overlay visibility
const RESIZE_ACTIVE_TIMEOUT_MS: i64 = 50; // Consider resize "done" after this many ms of no changes
pub threadlocal var g_resize_active: bool = false; // True while actively resizing

// Suppress resize overlay briefly after tab switch/creation to avoid false triggers
pub threadlocal var g_resize_overlay_suppress_until: i64 = 0;
// ============================================================================
// Startup shortcuts overlay
// ============================================================================

const STARTUP_SHORTCUTS_DURATION_MS: i64 = 12000;
const STARTUP_SHORTCUTS_FADE_MS: i64 = 800;

const STARTUP_SHORTCUT_LINES = [_][]const u8{
    "Keyboard shortcuts",
    "Ctrl+Shift+T      New tab",
    "Ctrl+W            Close split / tab",
    "Ctrl+Shift+O      Split right",
    "Ctrl+Shift+E      Split down",
    "Ctrl+Alt+Arrows   Focus split",
    "Ctrl+Shift+C/V    Copy / paste",
    "Ctrl+,            Open config",
    "Alt+Enter / F11   Fullscreen",
    "Press any key or click to hide",
};

pub threadlocal var g_startup_shortcuts_visible: bool = false;
threadlocal var g_startup_shortcuts_started_at: i64 = 0;

pub fn startupShortcutsShow() void {
    g_startup_shortcuts_visible = true;
    g_startup_shortcuts_started_at = std.time.milliTimestamp();
}

pub fn startupShortcutsDismiss() void {
    g_startup_shortcuts_visible = false;
}

// ============================================================================
// FPS debug overlay state
// ============================================================================

pub threadlocal var g_debug_fps: bool = false; // Whether to show FPS overlay
pub threadlocal var g_debug_draw_calls: bool = false; // Whether to show draw call count overlay
threadlocal var g_fps_frame_count: u32 = 0; // Frames since last FPS update
pub threadlocal var g_fps_last_time: i64 = 0; // Timestamp of last FPS calculation
threadlocal var g_fps_value: f32 = 0; // Current FPS value to display

// ============================================================================
// Scrollbar geometry
// ============================================================================

/// Scrollbar geometry result.
pub const ScrollbarGeometry = struct {
    track_x: f32,
    track_y: f32, // bottom of track (GL coords, y=0 is bottom)
    track_h: f32,
    thumb_y: f32,
    thumb_h: f32,
};

/// Compute scrollbar geometry for a specific surface.
/// Returns null if there's no scrollback (nothing to scroll).
pub fn scrollbarGeometryForSurface(surface: *Surface, view_height: f32, top_padding: f32) ?ScrollbarGeometry {
    const sb = surface.terminal.screens.active.pages.scrollbar();
    if (sb.total <= sb.len) return null; // No scrollback, no scrollbar

    // Track spans the terminal content area (below top padding, all the way to bottom)
    const track_top = view_height - top_padding; // top of terminal area in GL coords
    const track_bottom: f32 = 0; // extend to bottom edge
    const track_h = track_top - track_bottom;
    if (track_h <= 0) return null;

    // Thumb proportional to visible / total
    const ratio = @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total));
    const thumb_h = @max(SCROLLBAR_MIN_THUMB, track_h * ratio);

    // Thumb position: offset=0 means top, offset=total-len means bottom
    const max_offset = @as(f32, @floatFromInt(sb.total - sb.len));
    const scroll_frac = if (max_offset > 0)
        @as(f32, @floatFromInt(sb.offset)) / max_offset
    else
        0;
    // In GL coords: top of track is higher y value
    const thumb_top = track_top - scroll_frac * (track_h - thumb_h);
    const thumb_y = thumb_top - thumb_h;

    return .{
        .track_x = 0, // placeholder — caller provides view_width
        .track_y = track_bottom,
        .track_h = track_h,
        .thumb_y = thumb_y,
        .thumb_h = thumb_h,
    };
}

/// Compute scrollbar geometry from terminal state (uses active surface).
/// Returns null if there's no scrollback (nothing to scroll).
pub fn scrollbarGeometry(window_height: f32, top_padding: f32) ?ScrollbarGeometry {
    const surface = AppWindow.activeSurface() orelse return null;
    return scrollbarGeometryForSurface(surface, window_height, top_padding);
}

/// Show the scrollbar on the active surface (reset fade timer).
pub fn scrollbarShow() void {
    const surface = AppWindow.activeSurface() orelse return;
    surface.scrollbar_opacity = 1.0;
    surface.scrollbar_show_time = std.time.milliTimestamp();
}

/// Update scrollbar fade animation for a surface. Call once per frame.
fn scrollbarUpdateFade(surface: *Surface) void {
    if (g_scrollbar_hover or g_scrollbar_dragging) {
        surface.scrollbar_opacity = 1.0;
        return;
    }
    if (surface.scrollbar_opacity <= 0) return;

    const now = std.time.milliTimestamp();
    const elapsed = now - surface.scrollbar_show_time;

    if (elapsed < SCROLLBAR_FADE_DELAY_MS) {
        surface.scrollbar_opacity = 1.0;
    } else {
        const fade_elapsed = elapsed - SCROLLBAR_FADE_DELAY_MS;
        if (fade_elapsed >= SCROLLBAR_FADE_DURATION_MS) {
            surface.scrollbar_opacity = 0;
        } else {
            surface.scrollbar_opacity = 1.0 - @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(SCROLLBAR_FADE_DURATION_MS));
        }
    }
}

/// Render the scrollbar overlay for a specific surface within the current viewport.
/// view_width/view_height are the viewport dimensions (not full window).
/// top_padding is the padding from the top of the viewport to the terminal content.
pub fn renderScrollbarForSurface(surface: *Surface, view_width: f32, view_height: f32, top_padding: f32) void {
    const gl = &AppWindow.gl;
    scrollbarUpdateFade(surface);
    if (surface.scrollbar_opacity <= 0.01) return;

    const geo = scrollbarGeometryForSurface(surface, view_height, top_padding) orelse return;

    const bar_x = view_width - SCROLLBAR_WIDTH;
    const bar_w = SCROLLBAR_WIDTH;

    // Use the shader_program for quad rendering
    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);

    const fade = surface.scrollbar_opacity;

    // Track background: black at low alpha to subtly lift it from the terminal bg
    const track_alpha = fade * 0.08;
    gl_init.renderQuadAlpha(bar_x, geo.track_y, bar_w, geo.track_h, .{ 0, 0, 0 }, track_alpha);

    // Thumb: black at 45% opacity
    const thumb_alpha = fade * 0.45;
    gl_init.renderQuadAlpha(bar_x, geo.thumb_y, bar_w, geo.thumb_h, .{ 0, 0, 0 }, thumb_alpha);
}

/// Render the scrollbar overlay (uses active surface at full window size).
pub fn renderScrollbar(window_width: f32, window_height: f32, top_padding: f32) void {
    const surface = AppWindow.activeSurface() orelse return;
    renderScrollbarForSurface(surface, window_width, window_height, top_padding);
}

/// Check if a point (in client pixel coords, origin top-left) is over the scrollbar.
pub fn scrollbarHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_padding: f32) bool {
    const bar_right = window_width;
    const bar_left = window_width - SCROLLBAR_HOVER_WIDTH;
    const track_top_px = top_padding; // in pixel coords (top-left origin)
    const track_bottom_px = window_height;

    return @as(f32, @floatCast(xpos)) >= bar_left and
        @as(f32, @floatCast(xpos)) <= bar_right and
        @as(f32, @floatCast(ypos)) >= track_top_px and
        @as(f32, @floatCast(ypos)) <= track_bottom_px;
}

/// Check if a point is over the scrollbar thumb specifically.
pub fn scrollbarThumbHitTest(ypos: f64, window_height: f32, top_padding: f32) bool {
    const geo = scrollbarGeometry(window_height, top_padding) orelse return false;
    // Convert ypos (top-left origin) to GL coords (bottom-left origin)
    const gl_y = window_height - @as(f32, @floatCast(ypos));
    return gl_y >= geo.thumb_y and gl_y <= geo.thumb_y + geo.thumb_h;
}

/// Handle scrollbar drag: convert pixel y to scroll position.
pub fn scrollbarDrag(ypos: f64, window_height: f32, top_padding: f32) void {
    const surface = AppWindow.activeSurface() orelse return;
    const sb = surface.terminal.screens.active.pages.scrollbar();
    if (sb.total <= sb.len) return;

    const padding: f32 = 10;
    const track_top_px = top_padding;
    const track_bottom_px = window_height - padding;
    const track_h = track_bottom_px - track_top_px;
    if (track_h <= 0) return;

    const ratio = @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total));
    const thumb_h = @max(SCROLLBAR_MIN_THUMB, track_h * ratio);
    const scrollable_h = track_h - thumb_h;
    if (scrollable_h <= 0) return;

    // ypos is in top-left coords; track_top_px is the top of the track
    const y_in_track = @as(f32, @floatCast(ypos)) - track_top_px - g_scrollbar_drag_offset;
    const frac = std.math.clamp(y_in_track / scrollable_h, 0, 1);

    const max_offset = sb.total - sb.len;
    const target_offset: isize = @intFromFloat(frac * @as(f32, @floatFromInt(max_offset)));
    const current_offset: isize = @intCast(sb.offset);
    const delta = target_offset - current_offset;

    if (delta != 0) {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        surface.terminal.scrollViewport(.{ .delta = delta });
    }
}

// ============================================================================
// Resize overlay
// ============================================================================

/// Trigger the resize overlay to show with the given dimensions.
/// Called whenever the terminal size changes.
pub fn resizeOverlayShow(cols: u16, rows: u16) void {
    const now = std.time.milliTimestamp();

    // Check if overlay is suppressed (e.g., after tab switch)
    if (now < g_resize_overlay_suppress_until) {
        // Still update last cols/rows so we don't flash when suppression ends
        g_resize_overlay_last_cols = cols;
        g_resize_overlay_last_rows = rows;
        return;
    }

    // Mark resize as active (for cursor hiding)
    g_resize_active = true;
    g_resize_overlay_last_change = now;

    // Check if we're past the initial delay (avoid showing during initial window setup)
    if (!g_resize_overlay_ready) {
        if (g_resize_overlay_init_time == 0) {
            g_resize_overlay_init_time = now;
        }
        if (now - g_resize_overlay_init_time < RESIZE_OVERLAY_FIRST_DELAY_MS) {
            // Still in initial delay - update last_cols/rows so we don't flash when ready
            g_resize_overlay_last_cols = cols;
            g_resize_overlay_last_rows = rows;
            return;
        }
        g_resize_overlay_ready = true;
    }

    // Update current size
    g_resize_overlay_cols = cols;
    g_resize_overlay_rows = rows;

    // Show overlay if size differs from last settled size
    if (cols != g_resize_overlay_last_cols or rows != g_resize_overlay_last_rows) {
        g_resize_overlay_visible = true;
        g_resize_overlay_opacity = 1.0;
    }
}

/// Update resize overlay state. Call once per frame.
/// Handles the timeout logic and fade animation.
fn resizeOverlayUpdate() void {
    const now = std.time.milliTimestamp();
    const elapsed = now - g_resize_overlay_last_change;

    // Update resize active state (short timeout for cursor to reappear)
    if (g_resize_active and elapsed >= RESIZE_ACTIVE_TIMEOUT_MS) {
        g_resize_active = false;
    }

    if (!g_resize_overlay_visible and g_resize_overlay_opacity <= 0) return;

    if (g_resize_overlay_visible) {
        // Check if we should start hiding (size hasn't changed for DURATION_MS)
        if (elapsed >= RESIZE_OVERLAY_DURATION_MS) {
            // Timer completed - "settle" the size and start fade out
            g_resize_overlay_last_cols = g_resize_overlay_cols;
            g_resize_overlay_last_rows = g_resize_overlay_rows;
            g_resize_overlay_visible = false;
            // opacity stays at current value, will fade in next block
        }
    }

    // Handle fade out when not visible
    if (!g_resize_overlay_visible and g_resize_overlay_opacity > 0) {
        const fade_start = g_resize_overlay_last_change + RESIZE_OVERLAY_DURATION_MS;
        const fade_elapsed = now - fade_start;
        if (fade_elapsed >= RESIZE_OVERLAY_FADE_MS) {
            g_resize_overlay_opacity = 0;
        } else if (fade_elapsed > 0) {
            g_resize_overlay_opacity = 1.0 - @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(RESIZE_OVERLAY_FADE_MS));
        }
    }
}

/// Render a rounded rectangle with the given color and alpha.
/// Uses multiple quads to approximate rounded corners.
pub fn renderRoundedQuadAlpha(x: f32, y: f32, w: f32, h: f32, radius: f32, color: [3]f32, alpha: f32) void {
    const r = @min(radius, @min(w, h) / 2); // Clamp radius to half of smallest dimension

    // Main body (center rectangle, full height minus corners)
    gl_init.renderQuadAlpha(x + r, y, w - r * 2, h, color, alpha);

    // Left strip (between corners)
    gl_init.renderQuadAlpha(x, y + r, r, h - r * 2, color, alpha);

    // Right strip (between corners)
    gl_init.renderQuadAlpha(x + w - r, y + r, r, h - r * 2, color, alpha);

    // Approximate corners with small quads (simple 2-step approximation)
    // Bottom-left corner
    const r2 = r * 0.7; // Inner radius approximation
    gl_init.renderQuadAlpha(x + r - r2, y + r - r2, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x, y + r - r2, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + r - r2, y, r2, r - r2, color, alpha);

    // Bottom-right corner
    gl_init.renderQuadAlpha(x + w - r, y + r - r2, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r + r2, y + r - r2, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r, y, r2, r - r2, color, alpha);

    // Top-left corner
    gl_init.renderQuadAlpha(x + r - r2, y + h - r, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x, y + h - r, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + r - r2, y + h - r + r2, r2, r - r2, color, alpha);

    // Top-right corner
    gl_init.renderQuadAlpha(x + w - r, y + h - r, r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r + r2, y + h - r, r - r2, r2, color, alpha);
    gl_init.renderQuadAlpha(x + w - r, y + h - r + r2, r2, r - r2, color, alpha);
}

/// Render the resize overlay centered on screen.
pub fn renderResizeOverlay(window_width: f32, window_height: f32) void {
    renderResizeOverlayWithOffset(window_width, window_height, 0);
}

/// Render the resize overlay centered in the content area (below titlebar).
pub fn renderResizeOverlayWithOffset(window_width: f32, window_height: f32, top_offset: f32) void {
    resizeOverlayUpdate();
    if (g_resize_overlay_opacity <= 0.01) return;

    renderResizeOverlayText(g_resize_overlay_cols, g_resize_overlay_rows, window_width, window_height, top_offset, g_resize_overlay_opacity);
}

/// Render the resize overlay for a specific surface (used during divider dragging or equalize).
/// Shows the surface's current dimensions centered in the viewport.
/// Only shows if this surface's size actually changed during the drag/equalize.
pub fn renderResizeOverlayForSurface(surface: *Surface, window_width: f32, window_height: f32) void {
    // Show during divider dragging OR during timed split resize overlay (equalize, keyboard resize)
    const show_timed = std.time.milliTimestamp() < g_split_resize_overlay_until;
    if (!AppWindow.input.g_divider_dragging and !show_timed) return;
    if (!surface.resize_overlay_active) return;

    const cols = surface.size.grid.cols;
    const rows = surface.size.grid.rows;

    renderResizeOverlayText(cols, rows, window_width, window_height, 0, 1.0);
}

/// Core function to render a resize overlay with specific dimensions.
fn renderResizeOverlayText(cols: u16, rows: u16, window_width: f32, window_height: f32, top_offset: f32, alpha: f32) void {
    const gl = &AppWindow.gl;
    if (alpha <= 0.01) return;

    // Format the size string: "cols x rows"
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d} x {d}", .{ cols, rows }) catch return;

    // Measure text width using titlebar glyph system
    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
    const text_height = font.g_titlebar_cell_height;

    // Padding around text (compact)
    const pad_x: f32 = 10;
    const pad_y: f32 = 6;

    // Box dimensions
    const box_width = text_width + pad_x * 2;
    const box_height = text_height + pad_y * 2;

    // Center horizontally, center vertically in content area (below top_offset)
    const content_height = window_height - top_offset;
    const box_x = (window_width - box_width) / 2;
    const box_y = (content_height - box_height) / 2; // Centered in content area (GL coords)

    // Enable blending
    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);

    // Draw rounded background box (black with alpha, slightly more transparent than scrollbar)
    const corner_radius: f32 = 6;
    renderRoundedQuadAlpha(box_x, box_y, box_width, box_height, corner_radius, .{ 0.0, 0.0, 0.0 }, alpha * 0.35);

    // Draw text using titlebar rendering system (dimmed gray text)
    var x = box_x + pad_x;
    const y = box_y + pad_y;
    const text_gray: f32 = 0.6; // Dimmed gray
    for (text) |ch| {
        titlebar.renderTitlebarChar(@intCast(ch), x, y, .{ text_gray, text_gray, text_gray });
        x += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
}
fn startupShortcutsOpacity() f32 {
    if (!g_startup_shortcuts_visible) return 0;

    if (g_startup_shortcuts_started_at == 0) {
        g_startup_shortcuts_started_at = std.time.milliTimestamp();
    }

    const now = std.time.milliTimestamp();
    const elapsed = now - g_startup_shortcuts_started_at;
    if (elapsed >= STARTUP_SHORTCUTS_DURATION_MS) {
        g_startup_shortcuts_visible = false;
        return 0;
    }

    const fade_start = STARTUP_SHORTCUTS_DURATION_MS - STARTUP_SHORTCUTS_FADE_MS;
    if (elapsed > fade_start) {
        const fade_elapsed = elapsed - fade_start;
        return 1.0 - @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(STARTUP_SHORTCUTS_FADE_MS));
    }

    return 1.0;
}

fn mixColor(from: [3]f32, to: [3]f32, amount: f32) [3]f32 {
    const inv = 1.0 - amount;
    return .{
        from[0] * inv + to[0] * amount,
        from[1] * inv + to[1] * amount,
        from[2] * inv + to[2] * amount,
    };
}

fn measureTitlebarText(text: []const u8) f32 {
    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
    return text_width;
}

/// Render a centered startup overlay listing common keyboard shortcuts.
pub fn renderStartupShortcutsOverlay(window_width: f32, window_height: f32, top_offset: f32) void {
    const alpha = startupShortcutsOpacity();
    if (alpha <= 0.01) return;

    const gl = &AppWindow.gl;

    var max_text_width: f32 = 0;
    for (STARTUP_SHORTCUT_LINES) |line| {
        max_text_width = @max(max_text_width, measureTitlebarText(line));
    }

    const pad_x: f32 = 24;
    const pad_y: f32 = 18;
    const line_gap: f32 = 6;
    const line_height = font.g_titlebar_cell_height + line_gap;
    const line_count: f32 = @floatFromInt(STARTUP_SHORTCUT_LINES.len);
    const gap_count: f32 = @floatFromInt(STARTUP_SHORTCUT_LINES.len - 1);
    const box_width = max_text_width + pad_x * 2;
    const box_height = font.g_titlebar_cell_height * line_count + line_gap * gap_count + pad_y * 2;

    const content_height = window_height - top_offset;
    const box_x = @max(12, (window_width - box_width) / 2);
    const box_y = @max(12, (content_height - box_height) / 2);

    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    renderRoundedQuadAlpha(box_x, box_y, box_width, box_height, 10, .{ 0.0, 0.0, 0.0 }, alpha * 0.48);

    const heading_color = mixColor(AppWindow.g_theme.background, .{ 0.86, 0.86, 0.86 }, alpha);
    const body_color = mixColor(AppWindow.g_theme.background, .{ 0.68, 0.68, 0.68 }, alpha);
    const hint_color = mixColor(AppWindow.g_theme.background, .{ 0.50, 0.50, 0.50 }, alpha);

    var y = box_y + box_height - pad_y - font.g_titlebar_cell_height;
    for (STARTUP_SHORTCUT_LINES, 0..) |line, idx| {
        const is_heading = idx == 0;
        const is_hint = idx == STARTUP_SHORTCUT_LINES.len - 1;
        const line_width = measureTitlebarText(line);
        var x = if (is_heading or is_hint)
            box_x + (box_width - line_width) / 2
        else
            box_x + pad_x;
        const text_color = if (is_heading)
            heading_color
        else if (is_hint)
            hint_color
        else
            body_color;

        for (line) |ch| {
            titlebar.renderTitlebarChar(@intCast(ch), x, y, text_color);
            x += titlebar.titlebarGlyphAdvance(@intCast(ch));
        }

        y -= line_height;
    }
}

// ============================================================================
// Split rendering helpers
// ============================================================================

/// Render a semi-transparent overlay over an unfocused split pane.
pub fn renderUnfocusedOverlay(rect: SplitRect, window_height: f32) void {
    const gl = &AppWindow.gl;
    const opacity = 1.0 - g_unfocused_split_opacity;
    if (opacity < 0.01) return;

    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);

    // Draw semi-transparent background color overlay
    const px: f32 = @floatFromInt(rect.x);
    const py: f32 = window_height - @as(f32, @floatFromInt(rect.y + rect.height));
    const pw: f32 = @floatFromInt(rect.width);
    const ph: f32 = @floatFromInt(rect.height);

    // Use background color with alpha for the overlay
    gl_init.renderQuadAlpha(px, py, pw, ph, AppWindow.g_theme.background, opacity);
}

/// Render unfocused overlay within current viewport (for split rendering).
/// Assumes viewport is already set to the split's region.
/// Uses true alpha blending so it blends with actual rendered content.
pub fn renderUnfocusedOverlaySimple(width: f32, height: f32) void {
    const gl = &AppWindow.gl;
    const alpha = 1.0 - g_unfocused_split_opacity;
    if (alpha < 0.01) return;

    const vertices = [6][4]f32{
        .{ 0, height, 0.0, 0.0 },
        .{ 0, 0, 0.0, 1.0 },
        .{ width, 0, 1.0, 1.0 },
        .{ 0, height, 0.0, 0.0 },
        .{ width, 0, 1.0, 1.0 },
        .{ width, height, 1.0, 0.0 },
    };

    // Use overlay shader with true alpha blending
    gl.UseProgram.?(gl_init.overlay_shader);

    // Set overlay color (background color with alpha)
    gl.Uniform4f.?(
        gl.GetUniformLocation.?(gl_init.overlay_shader, "overlayColor"),
        AppWindow.g_theme.background[0],
        AppWindow.g_theme.background[1],
        AppWindow.g_theme.background[2],
        alpha,
    );

    // Set projection for current viewport
    var viewport: [4]c.GLint = undefined;
    gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
    const vp_width: f32 = @floatFromInt(viewport[2]);
    const vp_height: f32 = @floatFromInt(viewport[3]);
    const projection = [16]f32{
        2.0 / vp_width, 0.0,            0.0,  0.0,
        0.0,            2.0 / vp_height, 0.0,  0.0,
        0.0,            0.0,            -1.0, 0.0,
        -1.0,           -1.0,           0.0,  1.0,
    };
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(gl_init.overlay_shader, "projection"), 1, c.GL_FALSE, &projection);

    gl.BindVertexArray.?(gl_init.vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, gl_init.vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    gl_init.g_draw_call_count += 1;
}

/// Render split dividers between panes in the active tab.
/// If split-divider-color is configured, uses that color (solid).
/// Otherwise uses scrollbar-style rendering: black with alpha transparency.
pub fn renderSplitDividers(active_tab: *const TabState, content_x: i32, content_y: i32, content_w: i32, content_h: i32, window_height: f32) void {
    const gl = &AppWindow.gl;
    if (!active_tab.tree.isSplit()) return;

    const allocator = AppWindow.g_allocator orelse return;

    // Get spatial representation
    var spatial = active_tab.tree.spatial(allocator) catch return;
    defer spatial.deinit(allocator);

    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);

    // Check if custom color is configured
    const use_custom_color = g_split_divider_color != null;
    const custom_color = g_split_divider_color orelse .{ 0, 0, 0 };
    // Default alpha - similar to scrollbar thumb (0.45) but slightly less prominent
    const default_alpha: f32 = 0.35;

    // Walk the tree nodes and draw dividers for each split
    for (active_tab.tree.nodes, 0..) |node, i| {
        switch (node) {
            .leaf => {},
            .split => |s| {
                const slot = spatial.slots[i];
                const slot_x: f32 = @as(f32, @floatCast(slot.x)) * @as(f32, @floatFromInt(content_w)) + @as(f32, @floatFromInt(content_x));
                const slot_y: f32 = @as(f32, @floatCast(slot.y)) * @as(f32, @floatFromInt(content_h)) + @as(f32, @floatFromInt(content_y));
                const slot_w: f32 = @as(f32, @floatCast(slot.width)) * @as(f32, @floatFromInt(content_w));
                const slot_h: f32 = @as(f32, @floatCast(slot.height)) * @as(f32, @floatFromInt(content_h));

                switch (s.layout) {
                    .horizontal => {
                        // Vertical divider at ratio position
                        const div_x = slot_x + slot_w * @as(f32, @floatCast(s.ratio)) - @as(f32, @floatFromInt(@divTrunc(SPLIT_DIVIDER_WIDTH, 2)));
                        const div_y = window_height - slot_y - slot_h;
                        if (use_custom_color) {
                            gl_init.renderQuad(div_x, div_y, @floatFromInt(SPLIT_DIVIDER_WIDTH), slot_h, custom_color);
                        } else {
                            gl_init.renderQuadAlpha(div_x, div_y, @floatFromInt(SPLIT_DIVIDER_WIDTH), slot_h, .{ 0, 0, 0 }, default_alpha);
                        }
                    },
                    .vertical => {
                        // Horizontal divider at ratio position
                        const div_x = slot_x;
                        const div_y = window_height - slot_y - slot_h * @as(f32, @floatCast(s.ratio)) - @as(f32, @floatFromInt(@divTrunc(SPLIT_DIVIDER_WIDTH, 2)));
                        if (use_custom_color) {
                            gl_init.renderQuad(div_x, div_y, slot_w, @floatFromInt(SPLIT_DIVIDER_WIDTH), custom_color);
                        } else {
                            gl_init.renderQuadAlpha(div_x, div_y, slot_w, @floatFromInt(SPLIT_DIVIDER_WIDTH), .{ 0, 0, 0 }, default_alpha);
                        }
                    },
                }
            },
        }
    }
}

// ============================================================================
// Debug overlays
// ============================================================================

/// Update the FPS counter. Call once per frame.
pub fn updateFps() void {
    g_fps_frame_count += 1;
    const now = std.time.milliTimestamp();
    const elapsed = now - g_fps_last_time;
    if (elapsed >= 1000) {
        g_fps_value = @as(f32, @floatFromInt(g_fps_frame_count)) * 1000.0 / @as(f32, @floatFromInt(elapsed));
        g_fps_frame_count = 0;
        g_fps_last_time = now;
    }
}

/// Render the FPS debug overlay in the bottom-right corner.
pub fn renderDebugOverlay(window_width: f32) void {
    const margin: f32 = 8;
    const pad_h: f32 = 4;
    const pad_v: f32 = 2;
    const line_h = font.g_titlebar_cell_height + pad_v * 2;
    var overlay_y: f32 = margin;

    if (g_debug_fps) {
        renderDebugLine(window_width, &overlay_y, margin, pad_h, pad_v, line_h, blk: {
            var buf: [32]u8 = undefined;
            const fps_int: u32 = @intFromFloat(@round(g_fps_value));
            break :blk std.fmt.bufPrint(&buf, "{d} fps", .{fps_int}) catch break :blk "";
        }, .{ 0.0, 1.0, 0.0 });
    }

    if (g_debug_draw_calls) {
        renderDebugLine(window_width, &overlay_y, margin, pad_h, pad_v, line_h, blk: {
            var buf: [32]u8 = undefined;
            break :blk std.fmt.bufPrint(&buf, "{d} draws", .{gl_init.g_draw_call_count}) catch break :blk "";
        }, .{ 1.0, 1.0, 0.0 });
    }
}

fn renderDebugLine(window_width: f32, y_pos: *f32, margin: f32, pad_h: f32, pad_v: f32, line_h: f32, text: []const u8, text_color: [3]f32) void {
    const gl = &AppWindow.gl;
    if (text.len == 0) return;

    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }

    const bg_w = text_width + pad_h * 2;
    const bg_x = window_width - bg_w - margin;
    const bg_y = y_pos.*;

    gl_init.renderQuad(bg_x, bg_y, bg_w, line_h, .{ 0.0, 0.0, 0.0 });

    var x = bg_x + pad_h;
    const y = bg_y + pad_v;
    for (text) |ch| {
        titlebar.renderTitlebarChar(@intCast(ch), x, y, text_color);
        x += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }

    y_pos.* += line_h + 2; // spacing between lines
}
