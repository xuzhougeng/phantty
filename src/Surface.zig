/// A terminal surface — the core unit of Phantty.
/// Each Surface is a fully independent terminal session, owning a PTY,
/// terminal state machine, selection, and OSC title state.
///
/// Modeled after Ghostty's `src/Surface.zig`:
/// - Ghostty: Surface owns terminal, PTY, IO thread, renderer thread
/// - Phantty (Phase 1): Surface owns terminal, PTY, selection, OSC state
///   (IO thread added in Phase 2, renderer stays in main.zig for now)
///
/// TabState in main.zig becomes a thin wrapper: `{ surface: *Surface }`.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Pty = @import("pty.zig").Pty;
const renderer = @import("renderer.zig");
const termio = @import("termio.zig");
const Config = @import("config.zig");
const Renderer = @import("Renderer.zig");
const RendererThread = @import("RendererThread.zig");

const windows = std.os.windows;

const Surface = @This();

/// CancelIoEx is not exposed by Zig's std library.
/// We import it directly from kernel32.
extern "kernel32" fn CancelIoEx(
    hFile: windows.HANDLE,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

// ============================================================================
// Types
// ============================================================================

/// Selection state for text selection.
/// Rows are stored as absolute scrollback positions (viewport offset + screen row)
/// so the selection stays anchored to the text when scrolling.
pub const Selection = struct {
    start_col: usize = 0,
    start_row: usize = 0,
    end_col: usize = 0,
    end_row: usize = 0,
    active: bool = false,
};

/// OSC parser state machine — handles sequences split across PTY reads.
const OscParseState = enum { ground, esc, osc_num, osc_semi, osc_title };

// ============================================================================
// VT stream handler — wraps ghostty's readonly handler to intercept bell
// ============================================================================

/// Custom VT stream handler that delegates to the readonly handler but
/// intercepts the bell action to set a flag on the Surface.
/// This is necessary because ConPTY consumes BEL characters and the
/// readonly handler ignores them, so we can't detect bells from raw bytes.
pub const VtHandler = struct {
    /// The inner readonly handler type, obtained via Terminal.vtHandler's return type.
    const InnerHandler = @typeInfo(@TypeOf(ghostty_vt.Terminal.vtHandler)).@"fn".return_type.?;

    inner: InnerHandler,
    surface: *Surface,

    pub fn init(terminal: *ghostty_vt.Terminal, surface: *Surface) VtHandler {
        return .{
            .inner = terminal.vtHandler(),
            .surface = surface,
        };
    }

    pub fn deinit(self: *VtHandler) void {
        self.inner.deinit();
    }

    pub fn vt(
        self: *VtHandler,
        comptime action: ghostty_vt.StreamAction.Tag,
        value: ghostty_vt.StreamAction.Value(action),
    ) !void {
        if (action == .bell) {
            self.surface.bell_pending.store(true, .release);
            return;
        }
        try self.inner.vt(action, value);
    }
};

/// Our custom stream type using the bell-aware handler.
pub const VtStream = ghostty_vt.Stream(VtHandler);

// ============================================================================
// Core state
// ============================================================================

terminal: ghostty_vt.Terminal,
pty: Pty,
selection: Selection,
render_state: renderer.State,

/// Size information for this surface (screen size, cell size, padding).
/// Used by the renderer to position content correctly.
size: renderer.size.Size = .{},

// ============================================================================
// Per-surface renderer (Ghostty architecture)
// ============================================================================

/// Per-surface renderer with its own cell buffers
surface_renderer: Renderer,

/// Per-surface renderer thread (processes frames independently)
renderer_thread: RendererThread,

/// Dirty flag — set by IO thread (Phase 2), read by render loop.
/// For Phase 1 this is always effectively true (we render every frame).
dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

/// Set when the PTY process has exited.
exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

// ============================================================================
// Bell state
// ============================================================================

/// Set by the IO thread when BEL (0x07) is detected in PTY output.
/// Cleared by the main thread after handling the bell notification.
bell_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// Timestamp of the last bell notification, for rate limiting (100ms like Ghostty).
last_bell_time: i64 = 0,

/// Bell indicator opacity (0.0 = hidden, 1.0 = fully visible).
/// Fades in when bell fires, fades out on active tab after hold period.
bell_opacity: f32 = 0,

/// Whether the bell indicator should be showing (drives the fade target).
bell_indicator: bool = false,

/// Timestamp (ms) when the bell indicator was activated, for the 1s hold on active tabs.
bell_indicator_time: i64 = 0,

// ============================================================================
// Scrollbar state (per-surface, macOS-style overlay with fade)
// ============================================================================

scrollbar_opacity: f32 = 0,
scrollbar_show_time: i64 = 0,

// Per-surface resize overlay state (for divider dragging)
resize_overlay_active: bool = false, // Whether to show resize overlay on this surface
resize_overlay_last_cols: u16 = 0, // Last known cols (to detect changes)
resize_overlay_last_rows: u16 = 0, // Last known rows (to detect changes)

// ============================================================================
// Reference counting (for split tree mutations)
// ============================================================================

/// Reference count for split tree management. When a surface is added to
/// a split tree, it gets ref'd. When removed, it gets unref'd. When the
/// ref count reaches 0, the surface is destroyed.
ref_count: u32 = 1,

/// IO thread handle (null until Phase 2).
io_thread: ?std.Thread = null,

// ============================================================================
// OSC title fields
// ============================================================================

window_title: [256]u8 = undefined,
window_title_len: usize = 0,

/// User-set title override. When set, this takes priority over automatic titles.
/// Set via double-click on tab or keyboard shortcut. Clear by setting len to 0.
title_override: [256]u8 = undefined,
title_override_len: usize = 0,
osc_state: OscParseState = .ground,
osc_is_title: bool = false,
osc_num: u8 = 0,
osc_buf: [512]u8 = undefined,
osc_buf_len: usize = 0,
osc7_title: [256]u8 = undefined,
osc7_title_len: usize = 0,
got_osc7_this_batch: bool = false,

// Raw CWD path from OSC 7 (Unix-style, e.g., "/home/user/dir")
cwd_path: [512]u8 = undefined,
cwd_path_len: usize = 0,

// ============================================================================
// VT stream
// ============================================================================

/// Create a VT stream that processes terminal output and intercepts bell events.
/// Use this instead of terminal.vtStream() to get bell notifications.
pub fn vtStream(self: *Surface) VtStream {
    return VtStream.initAlloc(
        self.terminal.screens.active.alloc,
        VtHandler.init(&self.terminal, self),
    );
}

// ============================================================================
// Lifecycle
// ============================================================================

/// Initialize a new Surface with its own PTY and terminal.
/// If cwd is provided, the shell will start in that directory.
pub fn init(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    shell_cmd: [:0]const u16,
    scrollback_limit: u32,
    cursor_style: Config.CursorStyle,
    cursor_blink: bool,
    cwd: ?[*:0]const u16,
) !*Surface {
    const surface = try allocator.create(Surface);
    errdefer allocator.destroy(surface);

    // Initialize terminal
    surface.terminal = ghostty_vt.Terminal.init(allocator, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = scrollback_limit,
        .default_modes = .{ .grapheme_cluster = true },
    }) catch |err| {
        return err;
    };
    errdefer surface.terminal.deinit(allocator);

    // Set cursor style/blink from config
    surface.terminal.screens.active.cursor.cursor_style = switch (cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    surface.terminal.modes.set(.cursor_blinking, cursor_blink);

    // Spawn PTY
    surface.pty = Pty.spawn(cols, rows, shell_cmd, cwd) catch |err| {
        surface.terminal.deinit(allocator);
        return err;
    };

    // Init remaining fields
    surface.selection = .{};
    surface.render_state = renderer.State.init(&surface.terminal);
    surface.dirty = std.atomic.Value(bool).init(true);
    surface.exited = std.atomic.Value(bool).init(false);
    surface.io_thread = null;

    // Initialize per-surface renderer (Ghostty architecture)
    surface.surface_renderer = Renderer.init(surface);
    surface.renderer_thread = RendererThread.init(&surface.surface_renderer, surface);

    // Init OSC state
    surface.window_title_len = 0;
    surface.title_override_len = 0;
    surface.osc_state = .ground;
    surface.osc_is_title = false;
    surface.osc_num = 0;
    surface.osc_buf_len = 0;
    surface.osc7_title_len = 0;
    surface.got_osc7_this_batch = false;
    surface.cwd_path_len = 0;

    // Init bell state
    surface.bell_pending = std.atomic.Value(bool).init(false);
    surface.last_bell_time = 0;
    surface.bell_opacity = 0;
    surface.bell_indicator = false;
    surface.bell_indicator_time = 0;

    // Init scrollbar state
    surface.scrollbar_opacity = 0;
    surface.scrollbar_show_time = 0;

    // Init ref count (for split tree ownership)
    surface.ref_count = 1;

    // Spawn IO thread — must be last, after all state is initialized.
    // The thread starts reading from the PTY immediately.
    surface.io_thread = std.Thread.spawn(.{}, termio.Thread.threadMain, .{surface}) catch |err| {
        std.debug.print("Failed to spawn IO thread: {}\n", .{err});
        surface.pty.deinit();
        surface.terminal.deinit(allocator);
        return err;
    };

    // Start renderer thread (Ghostty architecture - each surface has its own render thread)
    surface.renderer_thread.start() catch |err| {
        std.debug.print("Failed to spawn renderer thread: {}\n", .{err});
        // Non-fatal: rendering will fall back to main thread updates
        _ = &err;
    };

    return surface;
}

/// Deinitialize and free a Surface.
/// Stops the IO thread first, then cleans up PTY and terminal.
pub fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
    // 1. Stop the renderer thread first (it accesses terminal state)
    self.renderer_thread.stop();
    self.surface_renderer.deinit();

    // 2. Signal the IO thread to stop.
    self.exited.store(true, .release);

    if (self.io_thread) |thread| {
        // Cancel the blocking ReadFile on the pipe handle.
        // Must happen BEFORE closing the handle (like Ghostty does).
        const read_handle = self.pty.pipe_in_read;
        if (read_handle != windows.INVALID_HANDLE_VALUE) {
            _ = CancelIoEx(read_handle, null);
        }

        // Close the read pipe — causes ReadFile to fail with BROKEN_PIPE
        // if CancelIoEx didn't already unblock it.
        self.pty.closeReadPipe();

        thread.join();
        self.io_thread = null;
    }

    // 3. Now safe to tear down everything — no other thread is accessing.
    self.pty.deinit();
    self.terminal.deinit(allocator);
    allocator.destroy(self);
}

/// Increase the reference count of this surface.
/// Used by SplitTree when a surface is added to a new tree.
pub fn ref(self: *Surface) *Surface {
    self.ref_count += 1;
    return self;
}

/// Decrease the reference count of this surface.
/// When the count reaches 0, the surface is destroyed.
/// Used by SplitTree when a surface is removed from a tree.
pub fn unref(self: *Surface, allocator: std.mem.Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        self.deinit(allocator);
    }
}

// ============================================================================
// Size and Resize
// ============================================================================

/// Update the surface size and resize the terminal/PTY if needed.
/// This is called by the split layout computation to set each surface
/// to its correct dimensions based on the split geometry.
///
/// Parameters:
/// - allocator: Used for terminal resize operations
/// - screen_width: Total pixel width available for this surface
/// - screen_height: Total pixel height available for this surface  
/// - cell_width: Width of a single cell in pixels
/// - cell_height: Height of a single cell in pixels
/// - explicit_padding: Minimum padding to apply (from config)
///
/// Returns true if the terminal was resized.
pub fn setScreenSize(
    self: *Surface,
    allocator: std.mem.Allocator,
    screen_width: u32,
    screen_height: u32,
    cell_width: f32,
    cell_height: f32,
    explicit_padding: renderer.size.Padding,
) bool {
    // Update screen size
    self.size.screen.width = screen_width;
    self.size.screen.height = screen_height;
    self.size.cell.width = cell_width;
    self.size.cell.height = cell_height;

    // Store explicit padding (used for rendering offset)
    self.size.padding = explicit_padding;

    // Update screen and cell info
    self.size.screen.width = screen_width;
    self.size.screen.height = screen_height;
    self.size.cell.width = cell_width;
    self.size.cell.height = cell_height;

    // Compute grid size from available space (screen minus padding)
    const avail_width = screen_width -| explicit_padding.left -| explicit_padding.right;
    const avail_height = screen_height -| explicit_padding.top -| explicit_padding.bottom;

    const new_cols: u16 = if (avail_width > 0 and cell_width > 0)
        @intFromFloat(@max(1, @as(f32, @floatFromInt(avail_width)) / cell_width))
    else
        1;
    const new_rows: u16 = if (avail_height > 0 and cell_height > 0)
        @intFromFloat(@max(1, @as(f32, @floatFromInt(avail_height)) / cell_height))
    else
        1;

    self.size.grid.cols = new_cols;
    self.size.grid.rows = new_rows;

    // Resize terminal if dimensions changed
    if (self.terminal.cols != new_cols or self.terminal.rows != new_rows) {
        self.render_state.mutex.lock();
        defer self.render_state.mutex.unlock();

        self.terminal.resize(allocator, new_cols, new_rows) catch {};
        self.terminal.scrollViewport(.{ .bottom = {} }) catch {};
        self.pty.resize(new_cols, new_rows);
        return true;
    }

    return false;
}

/// Get the padding for rendering. Returns the computed padding
/// which includes both explicit padding and balanced centering.
pub fn getPadding(self: *const Surface) renderer.size.Padding {
    return self.size.padding;
}

// ============================================================================
// Title
// ============================================================================

/// Get the display title for this surface.
pub fn getTitle(self: *const Surface) []const u8 {
    // User override takes highest priority (like Ghostty's title_override)
    if (self.title_override_len > 0)
        return self.title_override[0..self.title_override_len];
    if (self.osc7_title_len > 0)
        return self.osc7_title[0..self.osc7_title_len];
    if (self.window_title_len > 0)
        return self.window_title[0..self.window_title_len];
    return "phantty";
}

/// Set a manual title override. Pass empty slice to clear.
pub fn setTitleOverride(self: *Surface, title: []const u8) void {
    const len = @min(title.len, self.title_override.len);
    @memcpy(self.title_override[0..len], title[0..len]);
    self.title_override_len = len;
}

/// Get the current working directory path (from OSC 7), or null if not set.
/// Returns a Unix-style path (e.g., "/home/user/dir" or "/mnt/c/Users/...").
pub fn getCwd(self: *const Surface) ?[]const u8 {
    if (self.cwd_path_len > 0)
        return self.cwd_path[0..self.cwd_path_len];
    return null;
}

/// Reset OSC batch state — call before each PTY read batch.
pub fn resetOscBatch(self: *Surface) void {
    self.got_osc7_this_batch = false;
}

/// Scan PTY output for OSC 0/1/2/7 title sequences.
/// Handles sequences split across multiple reads via state machine.
pub fn scanForOscTitle(self: *Surface, data: []const u8) void {
    for (data) |byte| {
        switch (self.osc_state) {
            .ground => {
                if (byte == 0x1b) {
                    self.osc_state = .esc;
                }
            },
            .esc => {
                if (byte == ']') {
                    self.osc_state = .osc_num;
                    self.osc_is_title = false;
                } else {
                    self.osc_state = .ground;
                }
            },
            .osc_num => {
                if (byte == '0' or byte == '1' or byte == '2' or byte == '7') {
                    self.osc_is_title = true;
                    self.osc_num = byte;
                    self.osc_state = .osc_semi;
                } else if (byte >= '0' and byte <= '9') {
                    self.osc_is_title = false;
                    self.osc_num = byte;
                    self.osc_state = .osc_semi;
                } else {
                    self.osc_state = .ground;
                }
            },
            .osc_semi => {
                if (byte == ';') {
                    if (self.osc_is_title) {
                        self.osc_buf_len = 0;
                        self.osc_state = .osc_title;
                    } else {
                        self.osc_state = .ground;
                    }
                } else if (byte >= '0' and byte <= '9') {
                    // Multi-digit OSC number, stay in osc_semi
                } else {
                    self.osc_state = .ground;
                }
            },
            .osc_title => {
                if (byte == 0x07) {
                    self.updateTitle(self.osc_buf[0..self.osc_buf_len], self.osc_num);
                    self.osc_state = .ground;
                } else if (byte == 0x1b) {
                    self.updateTitle(self.osc_buf[0..self.osc_buf_len], self.osc_num);
                    self.osc_state = .esc;
                } else if (self.osc_buf_len < self.osc_buf.len) {
                    self.osc_buf[self.osc_buf_len] = byte;
                    self.osc_buf_len += 1;
                }
            },
        }
    }
}

/// Map known shell executable paths/titles to friendly display names.
fn shellFriendlyName(title: []const u8) []const u8 {
    var lower_buf: [512]u8 = undefined;
    const len = @min(title.len, lower_buf.len);
    for (0..len) |i| {
        lower_buf[i] = if (title[i] >= 'A' and title[i] <= 'Z') title[i] + 32 else title[i];
    }
    const lower = lower_buf[0..len];

    if (std.mem.indexOf(u8, lower, "powershell.exe") != null) return "Windows PowerShell";
    if (std.mem.indexOf(u8, lower, "pwsh.exe") != null) return "PowerShell";
    if (std.mem.indexOf(u8, lower, "powershell") != null and
        std.mem.indexOf(u8, lower, ".exe") == null) return "Windows PowerShell";
    if (std.mem.indexOf(u8, lower, "pwsh") != null and
        std.mem.indexOf(u8, lower, ".exe") == null) return "PowerShell";
    if (std.mem.indexOf(u8, lower, "cmd.exe") != null) return "Command Prompt";
    if (std.mem.eql(u8, lower, "cmd")) return "Command Prompt";

    return title;
}

/// Update the surface title from an OSC sequence.
/// Like Ghostty, reject titles that aren't valid UTF-8 — this filters out
/// garbage from random byte streams (e.g. cat /dev/urandom) that happen to
/// form accidental OSC sequences.
fn updateTitle(self: *Surface, title: []const u8, osc_num: u8) void {
    if (title.len == 0) return;
    if (!std.unicode.utf8ValidateSlice(title)) return;

    if (osc_num == '7') {
        // OSC 7: file://host/path — extract the path
        self.got_osc7_this_batch = true;
        const prefix = "file://";
        if (std.mem.startsWith(u8, title, prefix)) {
            const after_prefix = title[prefix.len..];
            if (std.mem.indexOfScalar(u8, after_prefix, '/')) |slash| {
                const path = after_prefix[slash..];

                // Store raw path for CWD inheritance
                const raw_len = @min(path.len, self.cwd_path.len);
                @memcpy(self.cwd_path[0..raw_len], path[0..raw_len]);
                self.cwd_path_len = raw_len;

                // Format for display (with ~ for home)
                const home_prefix = "/home/";
                if (std.mem.startsWith(u8, path, home_prefix)) {
                    const after_home = path[home_prefix.len..];
                    const user_end = std.mem.indexOfScalar(u8, after_home, '/') orelse after_home.len;
                    const home_len = home_prefix.len + user_end;

                    const rest = path[home_len..];
                    self.osc7_title[0] = '~';
                    const rest_len = @min(rest.len, self.osc7_title.len - 1);
                    @memcpy(self.osc7_title[1 .. 1 + rest_len], rest[0..rest_len]);
                    self.osc7_title_len = 1 + rest_len;
                } else {
                    const path_len = @min(path.len, self.osc7_title.len);
                    @memcpy(self.osc7_title[0..path_len], path[0..path_len]);
                    self.osc7_title_len = path_len;
                }
            }
        }
    } else {
        // OSC 0/1/2 — skip if we already got OSC 7 in this same batch
        if (self.got_osc7_this_batch) return;

        const friendly = shellFriendlyName(title);

        // Accept and clear OSC 7 cache
        self.osc7_title_len = 0;
        const friendly_len = @min(friendly.len, self.window_title.len);
        @memcpy(self.window_title[0..friendly_len], friendly[0..friendly_len]);
        self.window_title_len = friendly_len;
    }
}
