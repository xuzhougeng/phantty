/// Per-surface renderer thread — handles cell updates independently.
/// Following Ghostty's architecture where each Surface has its own render thread.
///
/// Ghostty reference: `src/renderer/Thread.zig`
/// - Event loop with wakeup, stop, render timer, cursor blink timer
/// - Calls renderer.drawFrame() when needed
///
/// Phase 1: Basic structure - signals main thread to redraw
/// Phase 2: Full cell snapshotting will be moved here from AppWindow.zig

const std = @import("std");
const Surface = @import("Surface.zig");
const Renderer = @import("renderer/Renderer.zig");

const RendererThread = @This();

// ============================================================================
// Constants
// ============================================================================

/// Target frame rate (~120 FPS)
const RENDER_INTERVAL_MS: i64 = 8;

/// Cursor blink interval (matching Ghostty)
const CURSOR_BLINK_INTERVAL_MS: i64 = 600;

// ============================================================================
// State
// ============================================================================

/// The renderer this thread updates
renderer: *Renderer,

/// The surface we're rendering
surface: *Surface,

/// The actual OS thread
thread: ?std.Thread,

/// Signal to stop the thread
should_stop: std.atomic.Value(bool),

/// Event to wake up the thread for immediate render
wakeup_event: std.Thread.ResetEvent,

// ============================================================================
// Lifecycle
// ============================================================================

/// Initialize the renderer thread (does not start it)
pub fn init(renderer: *Renderer, surface: *Surface) RendererThread {
    return RendererThread{
        .renderer = renderer,
        .surface = surface,
        .thread = null,
        .should_stop = std.atomic.Value(bool).init(false),
        .wakeup_event = .{},
    };
}

/// Clean up the renderer thread
pub fn deinit(self: *RendererThread) void {
    self.stop();
}

/// Start the renderer thread
pub fn start(self: *RendererThread) !void {
    if (self.thread != null) return; // Already running

    self.should_stop.store(false, .release);
    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
}

/// Signal the thread to stop and wait for it to finish
pub fn stop(self: *RendererThread) void {
    if (self.thread) |thread| {
        self.should_stop.store(true, .release);
        self.wakeup_event.set();
        thread.join();
        self.thread = null;
    }
}

/// Wake up the renderer thread to force an immediate update
pub fn wakeup(self: *RendererThread) void {
    self.wakeup_event.set();
}

// ============================================================================
// Thread Main
// ============================================================================

fn threadMain(self: *RendererThread) void {
    var last_render_time: i64 = std.time.milliTimestamp();

    while (!self.should_stop.load(.acquire)) {
        // Wait for wakeup or timeout (render interval)
        const timeout_ns: u64 = @intCast(RENDER_INTERVAL_MS * std.time.ns_per_ms);
        self.wakeup_event.timedWait(timeout_ns) catch {};
        self.wakeup_event.reset();

        if (self.should_stop.load(.acquire)) break;

        const now = std.time.milliTimestamp();

        // Update cursor blink
        self.renderer.updateCursorBlink(now, CURSOR_BLINK_INTERVAL_MS);

        // Check if enough time has passed for a render
        if (now - last_render_time < RENDER_INTERVAL_MS) continue;
        last_render_time = now;

        // Check if the surface is dirty (PTY output received)
        // If so, signal that we need a redraw
        if (self.surface.dirty.swap(false, .acq_rel)) {
            self.renderer.markDirty();
        }

        // The actual cell snapshotting and rebuilding is still done in
        // AppWindow.zig on the main thread for now. This thread just:
        // 1. Manages cursor blink timing
        // 2. Monitors the dirty flag
        // 3. Signals need for redraw
        //
        // In Phase 2, we'll move snapshotCells() and rebuildCells() here.
    }
}
