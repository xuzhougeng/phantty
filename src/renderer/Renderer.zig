/// Per-surface renderer — owns cell buffers, render state, and FBO handles.
/// Following Ghostty's architecture where each Surface has its own Renderer.
///
/// Ghostty reference: `src/renderer/generic.zig`, `src/renderer/opengl/Target.zig`
/// - Each Renderer instance has its own `cells: cellpkg.Contents`
/// - Each Renderer has its own uniforms, state, and GPU buffers
/// - Each Renderer renders to its own FBO (framebuffer object)
///
/// The FBO approach:
/// 1. Each surface renders to its own texture via FBO
/// 2. Main render loop composites all surface textures to screen
/// 3. No scissor needed - each surface has isolated render target
///
/// Note: GL operations are performed by AppWindow since it owns the GL context.
/// Renderer just stores the handles.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const Surface = @import("../Surface.zig");

const Renderer = @This();

/// OpenGL handle type (GLuint)
pub const GLuint = u32;

// ============================================================================
// Constants
// ============================================================================

/// Max cells = 300 cols x 100 rows = 30000 (generous)
pub const MAX_CELLS: usize = 30000;

/// Max codepoints per grapheme cluster (covers flags, ZWJ sequences, etc.)
const MAX_GRAPHEME: usize = 8;

// ============================================================================
// Cell Types
// ============================================================================

/// Background cell instance data for GPU
pub const CellBg = extern struct {
    grid_col: f32,
    grid_row: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// Foreground (glyph) cell instance data for GPU
pub const CellFg = extern struct {
    grid_col: f32,
    grid_row: f32,
    glyph_x: f32,
    glyph_y: f32,
    glyph_w: f32,
    glyph_h: f32,
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// Snapshot of a single cell's state (copied from terminal under lock)
pub const SnapCell = struct {
    codepoint: u21,
    fg: [3]f32,
    bg: ?[3]f32,
    wide: enum(u2) { narrow = 0, wide = 1, spacer_tail = 2, spacer_head = 3 } = .narrow,
    grapheme: [MAX_GRAPHEME]u21 = .{0} ** MAX_GRAPHEME,
    grapheme_len: u4 = 0, // 0 = single codepoint, >0 = multi-codepoint cluster
};

/// Cursor style enum matching ghostty's
pub const CursorStyle = enum {
    block,
    block_hollow,
    bar,
    underline,
};

// ============================================================================
// Renderer State
// ============================================================================

/// Owning surface
surface: *Surface,

/// Cell buffers for rendering
bg_cells: [MAX_CELLS]CellBg,
fg_cells: [MAX_CELLS]CellFg,
color_fg_cells: [MAX_CELLS]CellFg,
bg_cell_count: usize,
fg_cell_count: usize,
color_fg_cell_count: usize,

/// Snapshot buffer — cell data copied under terminal lock
snap: [MAX_CELLS]SnapCell,
snap_rows: usize,
snap_cols: usize,

/// Dirty/rebuild tracking
cells_valid: bool,
force_rebuild: bool,
last_cursor_blink_visible: bool,
last_viewport_active: bool,
last_viewport_node: ?*anyopaque,
last_viewport_y: usize,
last_cursor_node: ?*anyopaque,
last_cursor_pin_y: usize,
last_cursor_x: usize,
last_cols: usize,
last_rows: usize,
last_selection_active: bool,

/// Cached cursor state (for lock-free rendering)
cached_cursor_x: usize,
cached_cursor_y: usize,
cached_cursor_style: CursorStyle,
cached_cursor_effective: ?CursorStyle,
cached_cursor_visible: bool,
cached_viewport_at_bottom: bool,

/// Cursor blink state (managed by renderer thread)
cursor_blink_visible: bool,
last_cursor_blink_time: i64,

/// Focus state for this surface
is_focused: bool,

/// Mutex for protecting render state during updates
mutex: std.Thread.Mutex,

/// Signal that this surface needs redraw (set by renderer thread, read by main thread)
needs_redraw: std.atomic.Value(bool),

// ============================================================================
// FBO (Framebuffer Object) for off-screen rendering
// ============================================================================

/// OpenGL framebuffer object - renders to texture instead of screen
fbo: GLuint,

/// Color texture attached to FBO - contains rendered surface
fbo_texture: GLuint,

/// Current FBO dimensions (resized when surface size changes)
fbo_width: u32,
fbo_height: u32,

/// Whether FBO has been initialized
fbo_initialized: bool,

// ============================================================================
// Lifecycle
// ============================================================================

/// Initialize a new renderer for the given surface
pub fn init(surface: *Surface) Renderer {
    return Renderer{
        .surface = surface,
        .bg_cells = undefined,
        .fg_cells = undefined,
        .color_fg_cells = undefined,
        .bg_cell_count = 0,
        .fg_cell_count = 0,
        .color_fg_cell_count = 0,
        .snap = undefined,
        .snap_rows = 0,
        .snap_cols = 0,
        .cells_valid = false,
        .force_rebuild = true,
        .last_cursor_blink_visible = true,
        .last_viewport_active = true,
        .last_viewport_node = null,
        .last_viewport_y = 0,
        .last_cursor_node = null,
        .last_cursor_pin_y = 0,
        .last_cursor_x = 0,
        .last_cols = 0,
        .last_rows = 0,
        .last_selection_active = false,
        .cached_cursor_x = 0,
        .cached_cursor_y = 0,
        .cached_cursor_style = .block,
        .cached_cursor_effective = .block,
        .cached_cursor_visible = true,
        .cached_viewport_at_bottom = true,
        .cursor_blink_visible = true,
        .last_cursor_blink_time = 0,
        .is_focused = true,
        .mutex = .{},
        .needs_redraw = std.atomic.Value(bool).init(true),
        .fbo = 0,
        .fbo_texture = 0,
        .fbo_width = 0,
        .fbo_height = 0,
        .fbo_initialized = false,
    };
}

/// Clean up renderer resources.
/// Note: FBO cleanup must be done by AppWindow which has GL context.
pub fn deinit(self: *Renderer) void {
    // FBO resources are cleaned up by AppWindow.cleanupRendererFBO()
    // We just reset our state
    self.fbo = 0;
    self.fbo_texture = 0;
    self.fbo_width = 0;
    self.fbo_height = 0;
    self.fbo_initialized = false;
}

// ============================================================================
// FBO State (GL operations done by AppWindow)
// ============================================================================

/// Check if FBO needs to be created or resized
pub fn needsFBOUpdate(self: *const Renderer, width: u32, height: u32) bool {
    if (width == 0 or height == 0) return false;
    if (!self.fbo_initialized) return true;
    return self.fbo_width != width or self.fbo_height != height;
}

/// Set FBO handles after creation by AppWindow
pub fn setFBOHandles(self: *Renderer, fbo: GLuint, texture: GLuint, width: u32, height: u32) void {
    self.fbo = fbo;
    self.fbo_texture = texture;
    self.fbo_width = width;
    self.fbo_height = height;
    self.fbo_initialized = true;
}

/// Clear FBO handles (called before AppWindow deletes them)
pub fn clearFBOHandles(self: *Renderer) void {
    self.fbo = 0;
    self.fbo_texture = 0;
    self.fbo_width = 0;
    self.fbo_height = 0;
    self.fbo_initialized = false;
}

/// Get the FBO handle
pub fn getFBO(self: *const Renderer) GLuint {
    return self.fbo;
}

/// Get the texture handle for compositing
pub fn getTexture(self: *const Renderer) GLuint {
    return self.fbo_texture;
}

/// Get FBO dimensions
pub fn getFBOSize(self: *const Renderer) struct { width: u32, height: u32 } {
    return .{ .width = self.fbo_width, .height = self.fbo_height };
}

/// Check if FBO is ready for use
pub fn isFBOReady(self: *const Renderer) bool {
    return self.fbo_initialized and self.fbo != 0 and self.fbo_texture != 0;
}

// ============================================================================
// State Updates
// ============================================================================

/// Mark the renderer as needing a full rebuild on next frame
pub fn markDirty(self: *Renderer) void {
    self.force_rebuild = true;
    self.needs_redraw.store(true, .release);
}

/// Set focus state for this renderer
pub fn setFocused(self: *Renderer, focused: bool) void {
    if (self.is_focused != focused) {
        self.is_focused = focused;
        self.force_rebuild = true;
        self.needs_redraw.store(true, .release);
    }
}

/// Update cursor blink state. Called periodically by renderer thread.
pub fn updateCursorBlink(self: *Renderer, now_ms: i64, interval_ms: i64) void {
    if (now_ms - self.last_cursor_blink_time >= interval_ms) {
        self.cursor_blink_visible = !self.cursor_blink_visible;
        self.last_cursor_blink_time = now_ms;
        self.needs_redraw.store(true, .release);
    }
}

// ============================================================================
// Cell Count Accessors (for external use)
// ============================================================================

pub fn getBgCellCount(self: *const Renderer) usize {
    return self.bg_cell_count;
}

pub fn getFgCellCount(self: *const Renderer) usize {
    return self.fg_cell_count;
}

pub fn getColorFgCellCount(self: *const Renderer) usize {
    return self.color_fg_cell_count;
}
