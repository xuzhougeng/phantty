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
const Command = @import("Command.zig");
const win32 = @import("apprt/win32.zig");
const renderer = @import("renderer.zig");
const termio = @import("termio.zig");
const Config = @import("config.zig");
const Renderer = @import("renderer/Renderer.zig");
const RendererThread = @import("RendererThread.zig");

const windows = std.os.windows;

const Surface = @This();

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

/// Coarse launch environment for terminal-side integrations such as path paste.
pub const LaunchKind = enum {
    windows,
    wsl,
    ssh,
};

pub const SshConnection = struct {
    user_buf: [128]u8 = undefined,
    user_len: usize = 0,
    host_buf: [128]u8 = undefined,
    host_len: usize = 0,
    port_buf: [16]u8 = undefined,
    port_len: usize = 0,
    password_buf: [128]u8 = undefined,
    password_len: usize = 0,
    password_auth: bool = false,

    pub fn user(self: *const SshConnection) []const u8 {
        return self.user_buf[0..self.user_len];
    }

    pub fn host(self: *const SshConnection) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    pub fn port(self: *const SshConnection) []const u8 {
        return self.port_buf[0..self.port_len];
    }

    pub fn password(self: *const SshConnection) []const u8 {
        return self.password_buf[0..self.password_len];
    }
};

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
    ) void {
        if (action == .bell) {
            self.surface.bell_pending.store(true, .release);
            return;
        }
        self.inner.vt(action, value);
    }
};

/// Our custom stream type using the bell-aware handler.
pub const VtStream = ghostty_vt.Stream(VtHandler);

fn detectLaunchKind(command: []const u16) LaunchKind {
    var buf: [512]u8 = undefined;
    const len = @min(command.len, buf.len);
    for (command[0..len], 0..) |wc, i| {
        const ch: u8 = if (wc < 0x80) @intCast(wc) else ' ';
        buf[i] = std.ascii.toLower(ch);
    }
    const lower = buf[0..len];

    if (std.mem.indexOf(u8, lower, "ssh.exe") != null or
        std.mem.startsWith(u8, lower, "ssh "))
    {
        return .ssh;
    }
    if (std.mem.indexOf(u8, lower, "wsl.exe") != null or
        std.mem.startsWith(u8, lower, "wsl "))
    {
        return .wsl;
    }
    return .windows;
}

// ============================================================================
// Core state
// ============================================================================

allocator: std.mem.Allocator,
terminal: ghostty_vt.Terminal,
pty: Pty,
command: Command,
selection: Selection,
render_state: renderer.State,
launch_kind: LaunchKind,
ssh_connection: ?SshConnection,

/// Size information for this surface (screen size, cell size, padding).
/// Used by the renderer to position content correctly.
size: renderer.size.Size = .{},

// ============================================================================
// IO threads (Ghostty two-thread architecture: writer + reader)
// ============================================================================

/// Mailbox for sending messages from main thread to IO writer thread.
mailbox: termio.Mailbox,

/// IO writer thread state (xev event loop, coalesce timer, etc.).
/// Heap-allocated so the pointer stays stable when passed to the thread.
io_thread_state: ?*termio.Thread = null,

/// IO writer thread (xev event loop — handles resize, future messages).
io_writer_thread: ?std.Thread = null,

/// IO reader thread (blocking ReadFile loop).
io_reader_thread: ?std.Thread = null,

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

// Windows-side launch CWD. Used as a fallback for shells that do not emit OSC 7
// (cmd.exe and stock PowerShell, for example).
initial_cwd_path: [512]u8 = undefined,
initial_cwd_path_len: usize = 0,

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
        .kitty_image_storage_limit = 50 * 1024 * 1024,
        .kitty_image_loading_limits = .all,
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

    // Open PTY (pipes + pseudo console, no process)
    surface.pty = Pty.open(.{ .ws_col = cols, .ws_row = rows }) catch |err| {
        surface.terminal.deinit(allocator);
        return err;
    };
    errdefer surface.pty.deinit();

    // Spawn child process attached to the pseudo console
    surface.command = .{};
    surface.command.start(surface.pty.pseudo_console, shell_cmd, cwd) catch |err| {
        surface.pty.deinit();
        surface.terminal.deinit(allocator);
        return err;
    };

    // Init remaining fields
    surface.allocator = allocator;
    surface.selection = .{};
    surface.render_state = renderer.State.init(&surface.terminal);
    surface.launch_kind = detectLaunchKind(shell_cmd);
    surface.ssh_connection = null;
    surface.dirty = std.atomic.Value(bool).init(true);
    surface.exited = std.atomic.Value(bool).init(false);

    // Initialize mailbox for main thread → IO writer communication
    surface.mailbox = termio.Mailbox.init() catch |err| {
        surface.pty.deinit();
        surface.terminal.deinit(allocator);
        return err;
    };
    surface.io_thread_state = null;
    surface.io_writer_thread = null;
    surface.io_reader_thread = null;

    // Initialize grid size to match terminal dimensions.
    // This prevents spurious resize on first render when computeSplitLayout
    // calls setScreenSize - without this, the default 80x24 would differ from
    // the actual terminal dimensions, triggering a resize that can corrupt
    // terminal state if the shell has already output content.
    surface.size.grid.cols = cols;
    surface.size.grid.rows = rows;

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
    surface.initial_cwd_path_len = 0;
    surface.captureInitialCwd(cwd);

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

    // Initialize IO writer thread state (xev loop, async handles)
    const thread_state = allocator.create(termio.Thread) catch |err| {
        surface.mailbox.deinit();
        surface.pty.deinit();
        surface.terminal.deinit(allocator);
        return err;
    };
    thread_state.* = termio.Thread.init() catch |err| {
        allocator.destroy(thread_state);
        surface.mailbox.deinit();
        surface.pty.deinit();
        surface.terminal.deinit(allocator);
        return err;
    };
    surface.io_thread_state = thread_state;

    // Spawn IO writer thread (xev event loop — handles resize, future messages)
    surface.io_writer_thread = std.Thread.spawn(.{}, termio.Thread.threadMain, .{ thread_state, surface }) catch |err| {
        std.debug.print("Failed to spawn IO writer thread: {}\n", .{err});
        thread_state.deinit();
        allocator.destroy(thread_state);
        surface.mailbox.deinit();
        surface.pty.deinit();
        surface.terminal.deinit(allocator);
        return err;
    };

    // Spawn IO reader thread (blocking ReadFile loop)
    surface.io_reader_thread = std.Thread.spawn(.{}, termio.ReadThread.threadMain, .{surface}) catch |err| {
        std.debug.print("Failed to spawn IO reader thread: {}\n", .{err});
        // Stop writer thread since we can't proceed without reader
        thread_state.stop.notify() catch {};
        if (surface.io_writer_thread) |t| t.join();
        thread_state.deinit();
        allocator.destroy(thread_state);
        surface.mailbox.deinit();
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

    // 2. Signal both IO threads to stop.
    self.exited.store(true, .release);

    // Stop the writer thread (xev event loop) via its stop async
    if (self.io_thread_state) |state| {
        state.stop.notify() catch {};
    }

    // Cancel the reader thread's blocking ReadFile
    if (self.pty.out_pipe != windows.INVALID_HANDLE_VALUE) {
        _ = win32.CancelIoEx(self.pty.out_pipe, null);
    }

    // Join both threads
    if (self.io_writer_thread) |thread| {
        thread.join();
        self.io_writer_thread = null;
    }
    if (self.io_reader_thread) |thread| {
        thread.join();
        self.io_reader_thread = null;
    }

    // Clean up writer thread state and mailbox
    if (self.io_thread_state) |state| {
        state.deinit();
        self.allocator.destroy(state);
        self.io_thread_state = null;
    }
    self.mailbox.deinit();

    // 3. Now safe to tear down everything — no other thread is accessing.
    self.command.deinit();
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

pub fn setSshConnection(
    self: *Surface,
    user: []const u8,
    host: []const u8,
    port: []const u8,
    password: []const u8,
    password_auth: bool,
) void {
    var conn: SshConnection = .{};
    conn.user_len = @min(user.len, conn.user_buf.len);
    conn.host_len = @min(host.len, conn.host_buf.len);
    conn.port_len = @min(port.len, conn.port_buf.len);
    conn.password_len = @min(password.len, conn.password_buf.len);
    @memcpy(conn.user_buf[0..conn.user_len], user[0..conn.user_len]);
    @memcpy(conn.host_buf[0..conn.host_len], host[0..conn.host_len]);
    @memcpy(conn.port_buf[0..conn.port_len], port[0..conn.port_len]);
    @memcpy(conn.password_buf[0..conn.password_len], password[0..conn.password_len]);
    conn.password_auth = password_auth;

    self.launch_kind = .ssh;
    self.ssh_connection = conn;
}

// ============================================================================
// Size and Resize
// ============================================================================

/// Update the surface size and queue a resize to the IO thread if needed.
/// This is called by the split layout computation to set each surface
/// to its correct dimensions based on the split geometry.
///
/// The main thread updates pixel/grid dimensions in surface.size (needed
/// for layout/rendering), but the actual PTY + terminal resize happens
/// on the IO thread via queueIo() with 25ms coalescing.
///
/// Returns true if the grid dimensions changed (resize was queued).
pub fn setScreenSize(
    self: *Surface,
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
    self.terminal.width_px = @intFromFloat(@as(f32, @floatFromInt(self.size.grid.cols)) * cell_width);
    self.terminal.height_px = @intFromFloat(@as(f32, @floatFromInt(self.size.grid.rows)) * cell_height);

    // Store explicit padding (used for rendering offset)
    self.size.padding = explicit_padding;

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

    const changed = (self.size.grid.cols != new_cols or self.size.grid.rows != new_rows);
    self.size.grid.cols = new_cols;
    self.size.grid.rows = new_rows;
    self.terminal.width_px = @intFromFloat(@as(f32, @floatFromInt(new_cols)) * cell_width);
    self.terminal.height_px = @intFromFloat(@as(f32, @floatFromInt(new_rows)) * cell_height);

    // Queue resize to IO thread if grid dimensions changed
    if (changed) {
        self.queueIo(.{ .resize = .{ .cols = new_cols, .rows = new_rows } });
        return true;
    }

    return false;
}

/// Send a message to the IO writer thread via the mailbox.
pub fn queueIo(self: *Surface, msg: termio.Message) void {
    self.mailbox.send(msg);
    self.mailbox.notify();
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

/// Get the Windows-side launch directory for shells that do not report OSC 7.
pub fn getInitialCwd(self: *const Surface) ?[]const u8 {
    if (self.initial_cwd_path_len > 0)
        return self.initial_cwd_path[0..self.initial_cwd_path_len];
    return null;
}

fn captureInitialCwd(self: *Surface, cwd: ?[*:0]const u16) void {
    if (cwd) |ptr| {
        var len: usize = 0;
        while (ptr[len] != 0) : (len += 1) {}
        const utf8_len = std.unicode.utf16LeToUtf8(&self.initial_cwd_path, ptr[0..len]) catch 0;
        self.initial_cwd_path_len = utf8_len;
        return;
    }

    const path = std.process.getCwd(&self.initial_cwd_path) catch return;
    self.initial_cwd_path_len = path.len;
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
    if (std.mem.indexOf(u8, lower, "wsl.exe") != null) return "WSL";
    if (std.mem.eql(u8, lower, "wsl")) return "WSL";

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
