//! Input handling for AppWindow.
//!
//! Processes Win32 input events (keyboard, mouse, resize) and dispatches
//! to appropriate handlers. Manages clipboard, selection, scrollbar dragging,
//! split divider dragging, and fullscreen toggle.

const std = @import("std");
const AppWindow = @import("AppWindow.zig");
const tab = AppWindow.tab;
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const overlays = AppWindow.overlays;
const split_layout = AppWindow.split_layout;
const window_state = AppWindow.window_state;
const file_explorer = AppWindow.file_explorer;
const file_backend = @import("file_backend.zig");
const markdown_preview = @import("markdown_preview.zig");
const markdown_preview_panel = AppWindow.markdown_preview_panel;
const preview_token = @import("preview_token.zig");
const browser_panel = AppWindow.browser_panel;
const scp = @import("scp.zig");
const input_shortcuts = @import("input_shortcuts.zig");
const win32_backend = @import("apprt/win32.zig");
const Config = @import("config.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("split_tree.zig");
const selection_unit = @import("selection_unit.zig");
const Selection = Surface.Selection;
const CellPos = struct { col: usize, row: usize };

const CF_TEXT: win32_backend.UINT = 1;
const CF_DIB: win32_backend.UINT = 8;
const CF_UNICODETEXT: win32_backend.UINT = 13;
const CF_DIBV5: win32_backend.UINT = 17;
const BI_RGB: u32 = 0;
const BI_BITFIELDS: u32 = 3;
const GDIP_OK: win32_backend.INT = 0;
const PNG_ENCODER_CLSID: win32_backend.GUID = .{
    .Data1 = 0x557CF406,
    .Data2 = 0x1A04,
    .Data3 = 0x11D3,
    .Data4 = .{ 0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E },
};

const BitmapInfoHeader = extern struct {
    biSize: u32,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: u32,
    biSizeImage: u32,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: u32,
    biClrImportant: u32,
};

fn isPasteStripByte(byte: u8) bool {
    return switch (byte) {
        0x00, // NUL
        0x08, // BS
        0x05, // ENQ
        0x04, // EOT
        0x1B, // ESC
        0x7F, // DEL
        0x03, // VINTR (Ctrl+C)
        0x1C, // VQUIT (Ctrl+\)
        0x15, // VKILL (Ctrl+U)
        0x1A, // VSUSP (Ctrl+Z)
        0x11, // VSTART (Ctrl+Q)
        0x13, // VSTOP (Ctrl+S)
        0x17, // VWERASE (Ctrl+W)
        0x16, // VLNEXT (Ctrl+V)
        0x12, // VREPRINT (Ctrl+R)
        0x0F, // VDISCARD (Ctrl+O)
        => true,
        else => false,
    };
}

fn pasteNeedsMutation(data: []const u8, bracketed: bool) bool {
    for (data) |byte| {
        if (isPasteStripByte(byte)) return true;
        if (!bracketed and byte == '\n') return true;
    }
    return false;
}

fn mutatePasteData(data: []u8, bracketed: bool) void {
    for (data) |*byte| {
        if (isPasteStripByte(byte.*)) {
            byte.* = ' ';
        } else if (!bracketed and byte.* == '\n') {
            byte.* = '\r';
        }
    }
}

/// Write data to the PTY's input pipe (us -> child stdin).
fn writeToPty(surface: *Surface, data: []const u8) void {
    surface.queuePtyWrite(data);
}

fn writePasteToPty(surface: *Surface, allocator: std.mem.Allocator, data: []const u8) void {
    const bracketed = surface.terminal.modes.get(.bracketed_paste);
    var owned: ?[]u8 = null;
    var body = data;
    if (pasteNeedsMutation(data, bracketed)) {
        owned = allocator.dupe(u8, data) catch return;
        mutatePasteData(owned.?, bracketed);
        body = owned.?;
    }
    defer {
        if (owned) |buf| allocator.free(buf);
    }

    if (bracketed) {
        writeToPty(surface, "\x1b[200~");
        writeToPty(surface, body);
        writeToPty(surface, "\x1b[201~");
    } else {
        writeToPty(surface, body);
    }
}

fn clipboardTempDir(allocator: std.mem.Allocator) ?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "TEMP")) |v| return v else |_| {}
    if (std.process.getEnvVarOwned(allocator, "TMP")) |v| return v else |_| {}
    if (std.process.getEnvVarOwned(allocator, "LOCALAPPDATA")) |v| {
        return std.fs.path.join(allocator, &.{ v, "Temp" }) catch {
            allocator.free(v);
            return null;
        };
    } else |_| {}
    return null;
}

fn clipboardImagePath(allocator: std.mem.Allocator) ?[]u8 {
    const temp_dir = clipboardTempDir(allocator) orelse return null;
    defer allocator.free(temp_dir);

    const ts = std.time.milliTimestamp();
    return std.fmt.allocPrint(allocator, "{s}\\phantty-clipboard-{d}.png", .{ temp_dir, ts }) catch null;
}

fn quotePathForPaste(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (std.mem.indexOfAny(u8, path, " \t\"") == null) return allocator.dupe(u8, path) catch null;
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{path}) catch null;
}

fn windowsPathToWslPath(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (path.len < 3 or path[1] != ':' or (path[2] != '\\' and path[2] != '/')) return null;
    const drive = std.ascii.toLower(path[0]);
    if (drive < 'a' or drive > 'z') return null;

    const out_len = 6 + path.len - 2; // "/mnt/<drive>" plus the path after "C:"
    const out = allocator.alloc(u8, out_len) catch return null;
    @memcpy(out[0..5], "/mnt/");
    out[5] = drive;
    for (path[2..], 6..) |ch, i| {
        out[i] = if (ch == '\\') '/' else ch;
    }
    return out;
}

fn clipboardImageBasename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '\\' or ch == '/') start = i + 1;
    }
    return path[start..];
}

fn remoteClipboardImagePath(allocator: std.mem.Allocator, local_path: []const u8) ?[]u8 {
    const basename = clipboardImageBasename(local_path);
    if (basename.len == 0) return null;
    return std.fmt.allocPrint(allocator, "/tmp/{s}", .{basename}) catch null;
}

fn sshAskPassScriptPath(allocator: std.mem.Allocator) ?[]u8 {
    const temp_dir = clipboardTempDir(allocator) orelse return null;
    defer allocator.free(temp_dir);

    return std.fmt.allocPrint(allocator, "{s}\\phantty-ssh-askpass.cmd", .{temp_dir}) catch null;
}

fn ensureSshAskPassScript(allocator: std.mem.Allocator) ?[]u8 {
    const path = sshAskPassScriptPath(allocator) orelse return null;
    errdefer allocator.free(path);

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return null;
    defer file.close();

    file.writeAll(
        "@echo off\r\n" ++
            "powershell.exe -NoLogo -NoProfile -Command \"[Console]::Out.Write($env:PHANTTY_SSH_PASSWORD)\"\r\n",
    ) catch return null;
    return path;
}

fn uploadClipboardImageForSsh(allocator: std.mem.Allocator, surface: *const Surface, local_path: []const u8) ?[]u8 {
    const conn = surface.ssh_connection orelse {
        std.debug.print("SSH image paste skipped: no SSH profile metadata for this surface\n", .{});
        return null;
    };

    const remote_path = remoteClipboardImagePath(allocator, local_path) orelse return null;
    var keep_remote_path = false;
    defer if (!keep_remote_path) allocator.free(remote_path);

    var spec_buf: [512]u8 = undefined;
    const destination = scp.remoteSpec(&spec_buf, &conn, remote_path);

    const result = scp.transfer(allocator, &conn, local_path, destination);
    if (result != .ok) {
        std.debug.print("SSH image upload failed\n", .{});
        return null;
    }

    keep_remote_path = true;
    return remote_path;
}

fn imagePathForSurfacePaste(allocator: std.mem.Allocator, surface: *const Surface, path: []const u8) ?[]u8 {
    switch (surface.launch_kind) {
        .wsl => if (windowsPathToWslPath(allocator, path)) |wsl_path| return wsl_path,
        .ssh => return uploadClipboardImageForSsh(allocator, surface, path),
        .windows => {},
    }
    return allocator.dupe(u8, path) catch null;
}

fn readClipboardUnicodeText(allocator: std.mem.Allocator, hmem: *anyopaque) ?[]u8 {
    const ptr = win32_backend.GlobalLock(hmem) orelse return null;
    defer _ = win32_backend.GlobalUnlock(hmem);

    const data: [*]const u16 = @ptrCast(@alignCast(ptr));
    var len: usize = 0;
    while (data[len] != 0) : (len += 1) {}
    if (len == 0) return null;

    return std.unicode.utf16LeToUtf8Alloc(allocator, data[0..len]) catch null;
}

fn readClipboardAnsiText(allocator: std.mem.Allocator, hmem: *anyopaque) ?[]u8 {
    const ptr = win32_backend.GlobalLock(hmem) orelse return null;
    defer _ = win32_backend.GlobalUnlock(hmem);

    const data: [*]const u8 = @ptrCast(ptr);
    var len: usize = 0;
    while (data[len] != 0) : (len += 1) {}
    if (len == 0) return null;

    return allocator.dupe(u8, data[0..len]) catch null;
}

fn dibColorTableBytes(header: BitmapInfoHeader) usize {
    if (header.biBitCount > 8) return 0;
    const colors = if (header.biClrUsed != 0) header.biClrUsed else (@as(u32, 1) << @intCast(header.biBitCount));
    return @as(usize, colors) * 4;
}

fn dibMaskBytes(header: BitmapInfoHeader) usize {
    if (header.biCompression != BI_BITFIELDS) return 0;
    return if (header.biSize == @sizeOf(BitmapInfoHeader)) 12 else 0;
}

fn saveClipboardDibAsPng(allocator: std.mem.Allocator, hmem: *anyopaque) ?[]u8 {
    const total_size = win32_backend.GlobalSize(hmem);
    if (total_size < @sizeOf(BitmapInfoHeader)) return null;

    const ptr = win32_backend.GlobalLock(hmem) orelse return null;
    defer _ = win32_backend.GlobalUnlock(hmem);

    const bytes: [*]const u8 = @ptrCast(ptr);
    const dib = bytes[0..total_size];
    const header: *align(1) const BitmapInfoHeader = @ptrCast(dib.ptr);

    if (header.biSize < @sizeOf(BitmapInfoHeader) or header.biPlanes != 1) return null;
    if (header.biCompression != BI_RGB and header.biCompression != BI_BITFIELDS) return null;

    const pixel_offset = @as(usize, header.biSize) + dibColorTableBytes(header.*) + dibMaskBytes(header.*);
    if (pixel_offset > dib.len) return null;

    const out_path = clipboardImagePath(allocator) orelse return null;
    var keep_out_path = false;
    defer if (!keep_out_path) allocator.free(out_path);

    const out_path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, out_path) catch return null;
    defer allocator.free(out_path_w);

    const startup_input: win32_backend.GdiplusStartupInput = .{
        .GdiplusVersion = 1,
        .DebugEventCallback = null,
        .SuppressBackgroundThread = 0,
        .SuppressExternalCodecs = 0,
    };
    var gdip_token: usize = 0;
    if (win32_backend.GdiplusStartup(&gdip_token, &startup_input, null) != GDIP_OK) return null;
    defer win32_backend.GdiplusShutdown(gdip_token);

    const info_ptr: *const anyopaque = @ptrCast(dib.ptr);
    const data_ptr: *const anyopaque = @ptrCast(dib[pixel_offset..].ptr);
    var bitmap: ?*win32_backend.GpBitmap = null;
    if (win32_backend.GdipCreateBitmapFromGdiDib(info_ptr, data_ptr, &bitmap) != GDIP_OK) return null;
    const gdip_bitmap = bitmap orelse return null;
    defer _ = win32_backend.GdipDisposeImage(gdip_bitmap);

    if (win32_backend.GdipSaveImageToFile(gdip_bitmap, out_path_w.ptr, &PNG_ENCODER_CLSID, null) != GDIP_OK) return null;
    keep_out_path = true;
    return out_path;
}

fn saveClipboardImageToTemp(allocator: std.mem.Allocator) ?[]u8 {
    const hmem = win32_backend.GetClipboardData(CF_DIBV5) orelse win32_backend.GetClipboardData(CF_DIB) orelse return null;
    return saveClipboardDibAsPng(allocator, hmem);
}

fn pasteSavedClipboardImage(surface: *Surface, allocator: std.mem.Allocator, image_path: []const u8) bool {
    const target_path = imagePathForSurfacePaste(allocator, surface, image_path) orelse return false;
    defer allocator.free(target_path);

    const pasted = quotePathForPaste(allocator, target_path) orelse return false;
    defer allocator.free(pasted);

    std.debug.print("Pasting clipboard image path: {s}\n", .{target_path});
    writePasteToPty(surface, allocator, pasted);
    return true;
}

// Selection + divider drag state (moved from AppWindow.zig)
pub threadlocal var g_selecting: bool = false; // True while mouse button is held
pub threadlocal var g_click_x: f64 = 0; // X position of initial click (for threshold calculation)
pub threadlocal var g_click_y: f64 = 0; // Y position of initial click
var g_selection_changed_for_copy: bool = false;
threadlocal var g_left_click_count: u8 = 0;
threadlocal var g_left_click_time_ms: i64 = 0;
threadlocal var g_left_click_x: f64 = 0;
threadlocal var g_left_click_y: f64 = 0;
const MULTI_CLICK_INTERVAL_MS: i64 = 500;
const MAX_SELECTION_COLS: usize = 4096;

const UrlUnderline = struct {
    surface: ?*Surface = null,
    row_abs: usize = 0,
    start_col: usize = 0,
    end_col: usize = 0,

    fn active(self: UrlUnderline) bool {
        return self.surface != null;
    }
};

threadlocal var g_url_underline: UrlUnderline = .{};

const TokenAtCell = struct {
    text: []u8,
    row: usize,
    start_col: usize,
    end_col: usize,

    fn deinit(self: TokenAtCell, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const SPLIT_DIVIDER_HIT_WIDTH: f32 = 8; // Larger hit area for easier grabbing

pub threadlocal var g_divider_hover: bool = false; // Mouse is over a divider
pub threadlocal var g_divider_dragging: bool = false; // Currently dragging a divider
pub threadlocal var g_divider_drag_handle: ?SplitTree.Node.Handle = null; // Handle of the split node being resized
pub threadlocal var g_divider_drag_layout: ?SplitTree.Split.Layout = null; // horizontal or vertical
threadlocal var g_scrollbar_drag_surface: ?*Surface = null;
threadlocal var g_scrollbar_drag_view_y: f32 = 0;
threadlocal var g_scrollbar_drag_view_h: f32 = 0;
threadlocal var g_scrollbar_drag_top_pad: f32 = 0;
threadlocal var g_ai_input_scroll_dragging: bool = false;
threadlocal var g_ai_input_scroll_chat: ?*AppWindow.ai_chat.Session = null;
threadlocal var g_ai_input_scroll_drag_offset: f32 = 0;
pub threadlocal var g_sidebar_resize_hover: bool = false; // Mouse is over the sidebar resize edge
pub threadlocal var g_sidebar_resize_dragging: bool = false; // Currently dragging the sidebar edge
pub threadlocal var g_explorer_resize_hover: bool = false; // Mouse is over the file explorer resize edge
pub threadlocal var g_explorer_resize_dragging: bool = false; // Currently dragging the file explorer edge
pub threadlocal var g_markdown_preview_resize_hover: bool = false; // Mouse is over the preview resize edge
pub threadlocal var g_markdown_preview_resize_dragging: bool = false; // Currently dragging the preview edge
pub threadlocal var g_browser_resize_hover: bool = false; // Mouse is over the WebView2 browser edge
pub threadlocal var g_browser_resize_dragging: bool = false; // Currently dragging the browser edge

// Internal state (moved from win32_input struct)
threadlocal var plus_btn_pressed: bool = false;
threadlocal var saved_style: win32_backend.DWORD = 0;
threadlocal var saved_rect: win32_backend.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
threadlocal var is_fullscreen: bool = false;
const CLOSE_SHORTCUT_CONFIRM_MS: i64 = 5000;
threadlocal var g_close_shortcut_confirm_until_ms: i64 = 0;

fn titlebarHeight() f64 {
    return @floatCast(AppWindow.currentTitlebarHeight());
}

fn syncGridFromWindowSize(width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    const render_padding: f32 = 10;
    const tb_offset: f32 = @floatCast(titlebarHeight());
    const left_panels_w = AppWindow.leftPanelsWidth();
    const right_panels_w = AppWindow.rightPanelsWidthForWindow(width);
    const explicit_left: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);
    const explicit_right: f32 = @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING)) + overlays.SCROLLBAR_WIDTH;
    const explicit_top: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);
    const explicit_bottom: f32 = @floatFromInt(split_layout.DEFAULT_PADDING);

    const total_width_padding = left_panels_w + right_panels_w + explicit_left + explicit_right;
    const total_height_padding = render_padding * 2 + tb_offset + explicit_top + explicit_bottom;

    const avail_width = @as(f32, @floatFromInt(width)) - total_width_padding;
    const avail_height = @as(f32, @floatFromInt(height)) - total_height_padding;

    const new_cols: u16 = @intFromFloat(@max(1, avail_width / font.cell_width));
    const new_rows: u16 = @intFromFloat(@max(1, avail_height / font.cell_height));

    if (new_cols != AppWindow.term_cols or new_rows != AppWindow.term_rows) {
        AppWindow.g_pending_resize = true;
        AppWindow.g_pending_cols = new_cols;
        AppWindow.g_pending_rows = new_rows;
        AppWindow.g_last_resize_time = std.time.milliTimestamp();
    }
}

fn syncGridFromWindowSizeImmediate(width: i32, height: i32) void {
    AppWindow.requestImmediateLayoutResize();
    syncGridFromWindowSize(width, height);
}

fn markBrowserUrlBarDirty() void {
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn blurBrowserUrlBarIfFocused() void {
    if (!browser_panel.urlBarFocused()) return;
    browser_panel.blurUrlBar();
    markBrowserUrlBarDirty();
}

pub fn cancelTransientMouseState(win: ?*win32_backend.Window) void {
    g_divider_hover = false;
    g_divider_dragging = false;
    g_divider_drag_handle = null;
    g_divider_drag_layout = null;
    g_sidebar_resize_hover = false;
    g_sidebar_resize_dragging = false;
    g_explorer_resize_hover = false;
    g_explorer_resize_dragging = false;
    g_markdown_preview_resize_hover = false;
    g_markdown_preview_resize_dragging = false;
    g_browser_resize_hover = false;
    g_browser_resize_dragging = false;
    g_selecting = false;
    plus_btn_pressed = false;
    tab.g_tab_close_pressed = null;
    overlays.g_scrollbar_dragging = false;
    g_scrollbar_drag_surface = null;
    g_ai_input_scroll_dragging = false;
    g_ai_input_scroll_chat = null;
    if (win) |w| w.clearTransientInputQueues();
}

pub fn toggleSidebar() void {
    tab.g_sidebar_visible = !tab.g_sidebar_visible;
    if (AppWindow.g_window) |win| {
        syncGridFromWindowSizeImmediate(win.width, win.height);
        win.sidebar_width = @intFromFloat(titlebar.sidebarWidth());
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

pub fn toggleFileExplorer() void {
    file_explorer.toggle();
    if (file_explorer.g_visible) {
        AppWindow.syncVisibleFileExplorerForActiveTab();
    }
    if (AppWindow.g_window) |win| {
        syncGridFromWindowSizeImmediate(win.width, win.height);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

pub fn toggleBrowserPanel() void {
    const allocator = AppWindow.g_allocator orelse return;
    const parent = if (AppWindow.g_window) |win| win.hwnd else null;
    const surface = AppWindow.activeSurface();
    if (!browser_panel.toggleForSurface(allocator, parent, surface)) return;
    if (AppWindow.g_window) |win| {
        syncGridFromWindowSizeImmediate(win.width, win.height);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

pub fn closePanelOrTab() void {
    if (markdown_preview_panel.g_visible) {
        g_close_shortcut_confirm_until_ms = 0;
        markdown_preview_panel.close();
        if (AppWindow.g_window) |win| syncGridFromWindowSizeImmediate(win.width, win.height);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    if (browser_panel.g_visible) {
        g_close_shortcut_confirm_until_ms = 0;
        browser_panel.close();
        if (AppWindow.g_window) |win| syncGridFromWindowSizeImmediate(win.width, win.height);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    if (AppWindow.closeFocusedSplitWouldCloseWindow()) {
        const now = std.time.milliTimestamp();
        if (now < g_close_shortcut_confirm_until_ms) {
            g_close_shortcut_confirm_until_ms = 0;
            AppWindow.closeFocusedSplit();
            return;
        }
        g_close_shortcut_confirm_until_ms = now + CLOSE_SHORTCUT_CONFIRM_MS;
        overlays.showCloseShortcutConfirm(CLOSE_SHORTCUT_CONFIRM_MS);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    g_close_shortcut_confirm_until_ms = 0;
    AppWindow.closeFocusedSplit();
}

pub fn adjustFontSize(delta: i32) void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    const current: i32 = @intCast(cfg.@"font-size");
    var next = current + delta;
    if (next < 6) next = 6;
    if (next > 72) next = 72;
    if (next == current) return;

    var buf: [16]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d}", .{next}) catch return;
    Config.setConfigValue(allocator, "font-size", value) catch {};
}

pub fn copyRemoteSessionKeyToClipboard() bool {
    const app = AppWindow.g_app orelse return false;
    const client = app.remote_client orelse return false;
    const key = client.sessionKey();
    if (!copyTextToClipboard(key)) return false;
    overlays.remoteKeyCopiedFlash();
    overlays.remoteKeyOverlayDismiss(key);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
    std.debug.print("Remote session key copied to clipboard\n", .{});
    return true;
}

// ============================================================================
// Shared helpers (used by input + cell_renderer)
// ============================================================================

/// Get the viewport's absolute row offset into the scrollback.
/// Row 0 on screen corresponds to absolute row `viewportOffset()`.
pub fn viewportOffset() usize {
    const surface = AppWindow.activeSurface() orelse return 0;
    return viewportOffsetForSurface(surface);
}

pub const ScrollbarState = struct {
    total: usize,
    offset: usize,
    len: usize,
};

/// Convert mouse position to terminal cell coordinates.
pub fn mouseToCell(xpos: f64, ypos: f64) CellPos {
    const padding_d: f64 = 10;
    const tb_d = titlebarHeight();
    const sidebar_d: f64 = @floatCast(titlebar.sidebarWidth());
    const col_f = (xpos - sidebar_d - padding_d) / @as(f64, font.cell_width);
    const row_f = (ypos - padding_d - tb_d) / @as(f64, font.cell_height);

    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(AppWindow.term_cols))) AppWindow.term_cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(AppWindow.term_rows))) AppWindow.term_rows - 1 else @as(usize, @intFromFloat(row_f));

    return .{ .col = col, .row = row };
}

fn splitRectForSurface(surface: *Surface) ?split_layout.SplitRect {
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (!split_layout.cachedRectIsLive(rect)) continue;
        if (rect.surface == surface) return rect;
    }
    return null;
}

const ScrollbarTarget = struct {
    surface: *Surface,
    view_x: f32,
    view_y: f32,
    view_w: f32,
    view_h: f32,
    top_pad: f32,
};

fn scrollbarTargetAt(xpos: f64, ypos: f64, window_w: f32, window_h: f32, top_pad: f32) ?ScrollbarTarget {
    if (split_layout.g_split_rect_count > 1) {
        for (0..split_layout.g_split_rect_count) |i| {
            const rect = split_layout.g_split_rects[i];
            if (!split_layout.cachedRectIsLive(rect)) continue;
            const pad = rect.surface.getPadding();
            const view_x: f32 = @floatFromInt(rect.x);
            const view_y: f32 = @floatFromInt(rect.y);
            const view_w: f32 = @floatFromInt(rect.width);
            const view_h: f32 = @floatFromInt(rect.height);
            const local_top_pad: f32 = @floatFromInt(pad.top);
            if (overlays.scrollbarHitTestForSurface(rect.surface, xpos, ypos, view_x, view_y, view_w, view_h, local_top_pad)) {
                return .{
                    .surface = rect.surface,
                    .view_x = view_x,
                    .view_y = view_y,
                    .view_w = view_w,
                    .view_h = view_h,
                    .top_pad = local_top_pad,
                };
            }
        }
        return null;
    }

    const surface = AppWindow.activeSurface() orelse return null;
    if (!overlays.scrollbarHitTestForSurface(surface, xpos, ypos, 0, 0, window_w, window_h, top_pad)) return null;
    return .{
        .surface = surface,
        .view_x = 0,
        .view_y = 0,
        .view_w = window_w,
        .view_h = window_h,
        .top_pad = top_pad,
    };
}

pub fn viewportOffsetForSurface(surface: *Surface) usize {
    return scrollbarForSurface(surface).offset;
}

pub fn scrollbarForSurface(surface: *Surface) ScrollbarState {
    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();
    return scrollbarForSurfaceLocked(surface);
}

pub fn viewportOffsetForSurfaceLocked(surface: *Surface) usize {
    return scrollbarForSurfaceLocked(surface).offset;
}

pub fn scrollbarForSurfaceLocked(surface: *Surface) ScrollbarState {
    var pages = &surface.terminal.screens.active.pages;
    const rows: usize = @intCast(pages.rows);
    if (pages.total_rows <= rows) {
        return .{
            .total = rows,
            .offset = 0,
            .len = rows,
        };
    }

    const sb = pages.scrollbar();
    return .{
        .total = sb.total,
        .offset = sb.offset,
        .len = sb.len,
    };
}

/// Convert a window mouse position to a cell in the clicked split surface.
fn mouseToSurfaceCell(surface: *Surface, xpos: f64, ypos: f64) CellPos {
    const rect = splitRectForSurface(surface) orelse return mouseToCell(xpos, ypos);
    const pad = surface.getPadding();
    const col_f = (xpos - @as(f64, @floatFromInt(rect.x)) - @as(f64, @floatFromInt(pad.left))) / @as(f64, @floatCast(font.cell_width));
    const row_f = (ypos - @as(f64, @floatFromInt(rect.y)) - @as(f64, @floatFromInt(pad.top))) / @as(f64, @floatCast(font.cell_height));
    const cols = @max(@as(usize, 1), @as(usize, @intCast(surface.size.grid.cols)));
    const rows = @max(@as(usize, 1), @as(usize, @intCast(surface.size.grid.rows)));

    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(cols))) cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(rows))) rows - 1 else @as(usize, @intFromFloat(row_f));

    return .{ .col = col, .row = row };
}

fn mouseToSurfacePixel(surface: *Surface, xpos: i32, ypos: i32) struct { x: i32, y: i32 } {
    if (splitRectForSurface(surface)) |rect| {
        const pad = surface.getPadding();
        return .{
            .x = xpos - rect.x - @as(i32, @intCast(pad.left)),
            .y = ypos - rect.y - @as(i32, @intCast(pad.top)),
        };
    }
    return .{
        .x = xpos - @as(i32, @intFromFloat(titlebar.sidebarWidth())) - 10,
        .y = ypos - @as(i32, @intFromFloat(titlebarHeight())) - 10,
    };
}

/// Update split focus based on mouse position (focus follows mouse).
pub fn updateFocusFromMouse(mouse_x: i32, mouse_y: i32) void {
    const t = tab.activeTab() orelse return;
    for (0..split_layout.g_split_rect_count) |i| {
        const rect = split_layout.g_split_rects[i];
        if (!split_layout.cachedRectIsLive(rect)) continue;
        if (mouse_x >= rect.x and mouse_x < rect.x + rect.width and
            mouse_y >= rect.y and mouse_y < rect.y + rect.height)
        {
            if (rect.handle != t.focused) {
                t.focused = rect.handle;
                AppWindow.handleActiveSurfaceChangeWithinTab();
            }
            return;
        }
    }
}

/// Process all queued Win32 input events. Called once per frame from the main loop.
pub fn processEvents(win: *win32_backend.Window) void {
    if (win.is_minimized) {
        cancelTransientMouseState(win);
        win.size_changed = false;
        return;
    }
    processKeyAndCharEvents(win);
    processMouseButtonEvents(win);
    processMouseMoveEvents(win);
    processMouseWheelEvents(win);
    processSizeChange(win);
}

// Interleave key and char events so they fire in the order Windows
// generated them. WM_KEYDOWN is dispatched before its matching WM_CHAR
// (TranslateMessage posts the char), so popping one event from each
// queue per iteration replays the original temporal order. Draining
// keys fully before chars meant a focus-shifting key (Enter, Tab,
// Down) typed right after a character changed focus before the queued
// char was inserted, dropping the last password byte into the Port
// field and silently breaking SSH connect via the form.
fn processKeyAndCharEvents(win: *win32_backend.Window) void {
    while (true) {
        var did_anything = false;
        if (win.key_events.pop()) |ev| {
            handleKey(ev);
            did_anything = true;
        }
        if (win.char_events.pop()) |ev| {
            handleChar(ev);
            did_anything = true;
        }
        if (!did_anything) break;
    }
}

fn processMouseButtonEvents(win: *win32_backend.Window) void {
    while (win.mouse_button_events.pop()) |ev| {
        handleMouseButton(ev);
    }
}

fn processMouseMoveEvents(win: *win32_backend.Window) void {
    // Only process the latest move event (coalesce)
    var latest: ?win32_backend.MouseMoveEvent = null;
    while (win.mouse_move_events.pop()) |ev| {
        latest = ev;
    }
    if (latest) |ev| {
        handleMouseMove(ev);
    }
}

fn processMouseWheelEvents(win: *win32_backend.Window) void {
    while (win.mouse_wheel_events.pop()) |ev| {
        handleMouseWheel(ev);
    }
}

fn processSizeChange(win: *win32_backend.Window) void {
    if (!win.size_changed) return;
    win.size_changed = false;
    if (win.is_minimized or win.width <= 0 or win.height <= 0) return;
    if (titlebar.setSidebarWidth(titlebar.g_sidebar_width, @floatFromInt(win.width))) {
        win.sidebar_width = @intFromFloat(titlebar.sidebarWidth());
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
    }

    syncGridFromWindowSize(win.width, win.height);
}

fn handleChar(ev: win32_backend.CharEvent) void {
    overlays.startupShortcutsDismiss();
    if (overlays.sessionLauncherVisible()) {
        if (!ev.ctrl and !ev.alt) overlays.sessionLauncherInsertChar(ev.codepoint);
        return;
    }
    if (overlays.commandPaletteVisible()) {
        if (!ev.ctrl and !ev.alt) overlays.commandPaletteInsertChar(ev.codepoint);
        return;
    }
    if (browser_panel.urlBarFocused()) {
        if (!ev.ctrl and !ev.alt) {
            browser_panel.insertUrlBarChar(ev.codepoint);
            markBrowserUrlBarDirty();
        }
        return;
    }
    // File explorer inline editing
    if (file_explorer.g_focused and file_explorer.g_visible and file_explorer.g_op_mode != .none and file_explorer.g_op_mode != .confirm_delete) {
        if (!ev.ctrl and !ev.alt) file_explorer.inputChar(ev.codepoint);
        return;
    }
    // When tab rename is active, route chars to the rename buffer
    if (tab.g_tab_rename_active) {
        AppWindow.g_cursor_blink_visible = true;
        AppWindow.g_last_blink_time = std.time.milliTimestamp();
        tab.handleRenameChar(ev.codepoint);
        return;
    }
    if (AppWindow.activeAiChat()) |chat| {
        if (!ev.ctrl and !ev.alt) {
            AppWindow.resetCursorBlink();
            chat.handleChar(ev.codepoint);
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        }
        return;
    }
    if (!AppWindow.isActiveTabTerminal()) return;
    // Skip chars when Alt is held without Ctrl — those are part of Alt+key
    // combos (e.g. Shift+Alt+4) and shouldn't produce text input.
    // However, AltGr on international keyboards reports as Ctrl+Alt, so
    // we must allow chars when both Ctrl and Alt are held (AltGr chars).
    // This matches Ghostty's consumed_mods / effectiveMods approach.
    if (ev.alt and !ev.ctrl) return;
    const surface = AppWindow.activeSurface() orelse return;
    AppWindow.resetCursorBlink();
    {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        surface.terminal.scrollViewport(.bottom);
    }
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(ev.codepoint, &buf) catch return;
    writeToPty(surface, buf[0..len]);
}

fn handleKey(ev: win32_backend.KeyEvent) void {
    overlays.startupShortcutsDismiss();
    if (overlays.windowCloseConfirmVisible()) {
        overlays.windowCloseConfirmHandleKey(ev);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
    const is_close_shortcut = ev.ctrl and ev.shift and ev.vk == 0x57;
    if (!is_close_shortcut and !isModifierKey(ev.vk)) g_close_shortcut_confirm_until_ms = 0;
    if (overlays.sessionLauncherVisible()) {
        if (ev.ctrl and !ev.shift and !ev.alt and ev.vk == 0x56) { // Ctrl+V
            if (pasteClipboardIntoSessionLauncher()) {
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
            }
            return;
        }
        overlays.sessionLauncherHandleKey(ev);
        return;
    }
    // Ctrl+Shift+P = command center (even during tab rename)
    if (ev.ctrl and ev.shift and ev.vk == 0x50) { // 'P'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        overlays.commandPaletteToggle();
        return;
    }
    if (overlays.commandPaletteVisible()) {
        if (overlays.commandPaletteAgentHistoryVisible()) {
            switch (ev.vk) {
                win32_backend.VK_ESCAPE => overlays.commandPaletteLeaveAgentHistory(),
                win32_backend.VK_UP => overlays.commandPaletteMoveAgentHistory(-1),
                win32_backend.VK_DOWN => overlays.commandPaletteMoveAgentHistory(1),
                win32_backend.VK_RETURN => overlays.commandPaletteExecuteSelected(),
                else => {},
            }
        } else {
            switch (ev.vk) {
                win32_backend.VK_ESCAPE => overlays.commandPaletteClose(),
                win32_backend.VK_UP => overlays.commandPaletteMove(-1),
                win32_backend.VK_DOWN => overlays.commandPaletteMove(1),
                win32_backend.VK_RETURN => overlays.commandPaletteExecuteSelected(),
                win32_backend.VK_BACK => overlays.commandPaletteBackspace(),
                win32_backend.VK_DELETE => overlays.commandPaletteClearFilter(),
                else => {},
            }
        }
        return;
    }
    if (overlays.settingsPageVisible()) {
        overlays.settingsPageHandleKey(ev);
        return;
    }
    // File explorer key handling (when focused and in operation mode)
    if (file_explorer.g_focused and file_explorer.g_visible) {
        if (handleFileExplorerKey(ev)) return;
    }
    // Ctrl+Shift+N = new window (even during tab rename)
    if (ev.ctrl and ev.shift and ev.vk == 0x4E) { // 'N'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        if (AppWindow.g_app) |app| {
            const hwnd = if (AppWindow.g_window) |w| w.hwnd else null;
            // Get CWD from active tab for working directory inheritance
            var cwd_buf: [260]u16 = undefined;
            var cwd: ?[]const u16 = null;
            if (AppWindow.activeSurface()) |surface| {
                if (surface.getCwd()) |unix_path| {
                    std.debug.print("CWD from OSC 7: {s}\n", .{unix_path});
                    if (AppWindow.wsl_paths.unixPathToWindows(unix_path, &cwd_buf)) |len| {
                        cwd = cwd_buf[0..len];
                        var path_u8: [260]u8 = undefined;
                        for (cwd_buf[0..len], 0..) |wc, i| {
                            path_u8[i] = @truncate(wc);
                        }
                        std.debug.print("Converted to Windows path: {s}\n", .{path_u8[0..len]});
                    } else {
                        std.debug.print("Failed to convert Unix path to Windows\n", .{});
                    }
                } else {
                    std.debug.print("No CWD from active surface (OSC 7 not received)\n", .{});
                }
            }
            app.requestNewWindow(hwnd, cwd);
        }
        return;
    }
    // Ctrl+Shift+T = new session chooser (even during tab rename)
    if (ev.ctrl and ev.shift and ev.vk == 0x54) { // 'T'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        overlays.sessionLauncherOpen();
        return;
    }
    // Ctrl+Shift+O = new split right (vertical divider)
    if (ev.ctrl and ev.shift and ev.vk == 0x4F) { // 'O'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        AppWindow.splitFocused(.right);
        return;
    }
    // Ctrl+Shift+E = toggle file explorer sidebar
    if (ev.ctrl and ev.shift and ev.vk == 0x45) { // 'E'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        toggleFileExplorer();
        return;
    }
    // Ctrl+Shift+B = show/hide tab sidebar
    if (ev.ctrl and ev.shift and ev.vk == 0x42) { // 'B'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        toggleSidebar();
        return;
    }
    // Ctrl+Shift+W = close focused panel/tab/window
    if (ev.ctrl and ev.shift and ev.vk == 0x57) { // 'W'
        if (tab.g_tab_rename_active) tab.commitTabRename();
        closePanelOrTab();
        return;
    }
    // Alt+Enter = maximize / restore window
    if (ev.alt and !ev.ctrl and !ev.shift and ev.vk == win32_backend.VK_RETURN) {
        if (tab.g_tab_rename_active) tab.commitTabRename();
        toggleMaximize();
        return;
    }
    // Ctrl++ / Ctrl+- = adjust font size
    if (ev.ctrl and !ev.alt and ev.vk == win32_backend.VK_OEM_PLUS) {
        if (tab.g_tab_rename_active) tab.commitTabRename();
        adjustFontSize(1);
        return;
    }
    if (ev.ctrl and !ev.alt and ev.vk == win32_backend.VK_OEM_MINUS) {
        if (tab.g_tab_rename_active) tab.commitTabRename();
        adjustFontSize(-1);
        return;
    }
    // When tab rename is active, handle special keys
    if (tab.g_tab_rename_active) {
        AppWindow.g_cursor_blink_visible = true;
        AppWindow.g_last_blink_time = std.time.milliTimestamp();
        tab.handleRenameKey(ev);
        return;
    }
    if (browser_panel.urlBarFocused()) {
        handleBrowserUrlBarKey(ev);
        return;
    }
    if (AppWindow.activeAiChat()) |chat| {
        if (ev.ctrl and !ev.alt and ev.vk == 0x41) { // Ctrl+A
            chat.selectAll();
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
            return;
        }
        if (ev.ctrl and !ev.alt and ev.vk == 0x43) { // Ctrl+C / Ctrl+Shift+C
            copyAiChatToClipboard(chat);
            return;
        }
    }
    // Ctrl+Shift+C = copy
    if (ev.ctrl and ev.shift and ev.vk == 0x43) { // 'C'
        copySelectionToClipboard();
        return;
    }
    // Ctrl+V = paste text
    if (ev.ctrl and !ev.shift and !ev.alt and ev.vk == 0x56) { // 'V'
        if (AppWindow.activeAiChat()) |chat| {
            pasteFromClipboardIntoAiChat(chat);
        } else {
            pasteFromClipboard();
        }
        return;
    }
    // Ctrl+Shift+V = paste image
    if (ev.ctrl and ev.shift and !ev.alt and ev.vk == 0x56) { // 'V'
        pasteImageFromClipboard();
        return;
    }
    // Ctrl+Shift+T and Ctrl+Shift+N are handled above (before rename guard)
    // Alt+Arrows = goto split (spatial navigation)
    if (input_shortcuts.spatialFocusDirection(ev)) |dir| {
        AppWindow.gotoSplit(.{ .spatial = dir });
        return;
    }
    // Ctrl+Shift+[ = goto previous split
    if (ev.ctrl and ev.shift and ev.vk == win32_backend.VK_OEM_4) { // '['
        AppWindow.gotoSplit(.previous_wrapped);
        return;
    }
    // Ctrl+Shift+] = goto next split
    if (ev.ctrl and ev.shift and ev.vk == win32_backend.VK_OEM_6) { // ']'
        AppWindow.gotoSplit(.next_wrapped);
        return;
    }
    // Ctrl+Shift+Z = equalize splits
    if (ev.ctrl and ev.shift and ev.vk == 0x5A) { // 'Z'
        AppWindow.equalizeSplits();
        return;
    }
    // Ctrl+Tab = next tab
    if (ev.ctrl and ev.vk == win32_backend.VK_TAB) {
        if (ev.shift) {
            // Ctrl+Shift+Tab = previous tab
            if (tab.g_active_tab > 0) AppWindow.switchTab(tab.g_active_tab - 1) else AppWindow.switchTab(tab.g_tab_count - 1);
        } else {
            AppWindow.switchTab((tab.g_active_tab + 1) % tab.g_tab_count);
        }
        return;
    }
    // Alt+1-9 = switch to tab N
    if (ev.alt and !ev.ctrl and !ev.shift and ev.vk >= 0x31 and ev.vk <= 0x39) { // '1'-'9'
        const tab_idx = @as(usize, @intCast(ev.vk - 0x31));
        if (tab_idx < tab.g_tab_count) AppWindow.switchTab(tab_idx);
        return;
    }
    // Ctrl+, = open config
    if (ev.ctrl and ev.vk == win32_backend.VK_OEM_COMMA) {
        std.debug.print("[keybind] Ctrl+, pressed\n", .{});
        if (AppWindow.g_allocator) |alloc| Config.openConfigInEditor(alloc);
        return;
    }
    // Alt+Enter handled above as maximize/restore.

    if (AppWindow.activeAiChat()) |chat| {
        if (isAiChatKey(ev)) {
            AppWindow.resetCursorBlink();
            chat.handleKeyWithWrapCols(ev, aiChatInputWrapCols());
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
            return;
        }
    }

    // Don't send input to PTY if active tab isn't the terminal
    if (!AppWindow.isActiveTabTerminal()) return;

    const surface = AppWindow.activeSurface() orelse return;

    // Track whether this keypress actually sends data to the PTY.
    // Like Ghostty, we only scroll-to-bottom when input is actually generated,
    // not for modifier-only keys or key combos that don't produce PTY output.
    var wrote_to_pty = false;

    const seq: ?[]const u8 = switch (ev.vk) {
        win32_backend.VK_RETURN => "\r",
        win32_backend.VK_BACK => "\x7f",
        win32_backend.VK_TAB => "\t",
        win32_backend.VK_ESCAPE => "\x1b",
        win32_backend.VK_UP, win32_backend.VK_DOWN, win32_backend.VK_RIGHT, win32_backend.VK_LEFT => input_shortcuts.terminalArrowSequence(ev),
        win32_backend.VK_HOME => "\x1b[H",
        win32_backend.VK_END => "\x1b[F",
        win32_backend.VK_PRIOR => blk: { // Page Up
            if (ev.shift) {
                surface.render_state.mutex.lock();
                surface.terminal.scrollViewport(.{ .delta = -@as(isize, AppWindow.term_rows / 2) });
                surface.render_state.mutex.unlock();
                overlays.scrollbarShow();
                break :blk null;
            }
            break :blk "\x1b[5~";
        },
        win32_backend.VK_NEXT => blk: { // Page Down
            if (ev.shift) {
                surface.render_state.mutex.lock();
                surface.terminal.scrollViewport(.{ .delta = @as(isize, AppWindow.term_rows / 2) });
                surface.render_state.mutex.unlock();
                overlays.scrollbarShow();
                break :blk null;
            }
            break :blk "\x1b[6~";
        },
        win32_backend.VK_INSERT => "\x1b[2~",
        win32_backend.VK_DELETE => "\x1b[3~",
        else => blk: {
            // Ctrl+A through Ctrl+Z
            if (ev.ctrl and ev.vk >= 0x41 and ev.vk <= 0x5A) {
                // Shifted Ctrl+letter chords are application shortcuts above.
                if (!ev.shift) {
                    const ctrl_char: u8 = @intCast(ev.vk - 0x41 + 1);
                    writeToPty(surface, &[_]u8{ctrl_char});
                    wrote_to_pty = true;
                }
            }
            break :blk null;
        },
    };

    if (seq) |s| {
        writeToPty(surface, s);
        wrote_to_pty = true;
    }

    // Only scroll to bottom and reset cursor blink when we actually sent
    // data to the PTY. This matches Ghostty's behavior: modifier-only keys,
    // unbound key combos (like Shift+Alt+4), and scroll keys don't snap
    // the viewport to the bottom.
    if (wrote_to_pty) {
        AppWindow.resetCursorBlink();
        surface.render_state.mutex.lock();
        surface.terminal.scrollViewport(.bottom);
        surface.render_state.mutex.unlock();
    }
}

fn isModifierKey(vk: win32_backend.WPARAM) bool {
    return vk == win32_backend.VK_SHIFT or
        vk == win32_backend.VK_CONTROL or
        vk == win32_backend.VK_MENU or
        vk == win32_backend.VK_LSHIFT or
        vk == win32_backend.VK_RSHIFT or
        vk == win32_backend.VK_LCONTROL or
        vk == win32_backend.VK_RCONTROL or
        vk == win32_backend.VK_LMENU or
        vk == win32_backend.VK_RMENU;
}

fn isAiChatKey(ev: win32_backend.KeyEvent) bool {
    if (ev.vk == win32_backend.VK_RETURN or
        ev.vk == win32_backend.VK_BACK or
        ev.vk == win32_backend.VK_DELETE or
        ev.vk == win32_backend.VK_LEFT or
        ev.vk == win32_backend.VK_RIGHT or
        ev.vk == win32_backend.VK_UP or
        ev.vk == win32_backend.VK_DOWN or
        ev.vk == win32_backend.VK_HOME or
        ev.vk == win32_backend.VK_END or
        ev.vk == win32_backend.VK_ESCAPE) return true;
    if (ev.ctrl and !ev.alt and (ev.vk == 0x41 or ev.vk == 0x55 or ev.vk == 0x4C)) return true; // Ctrl+A / Ctrl+U / Ctrl+L
    return false;
}

fn aiChatInputWrapCols() usize {
    const win = AppWindow.g_window orelse return std.math.maxInt(usize);
    const ww: f32 = @floatFromInt(win.width);
    const panel_w = @max(1.0, ww - AppWindow.leftPanelsWidth() - AppWindow.rightPanelsWidth());
    return AppWindow.ai_chat_renderer.inputWrapColumns(panel_w);
}

fn handleBrowserUrlBarKey(ev: win32_backend.KeyEvent) void {
    if (ev.ctrl and !ev.shift and !ev.alt and ev.vk == 0x41) { // Ctrl+A
        browser_panel.selectAllUrlBar();
        markBrowserUrlBarDirty();
        return;
    }
    if (ev.ctrl and !ev.shift and !ev.alt and ev.vk == 0x56) { // Ctrl+V
        if (pasteClipboardIntoBrowserUrlBar()) markBrowserUrlBarDirty();
        return;
    }

    switch (ev.vk) {
        win32_backend.VK_ESCAPE => {
            browser_panel.blurUrlBar();
            markBrowserUrlBarDirty();
        },
        win32_backend.VK_RETURN => {
            const allocator = AppWindow.g_allocator orelse return;
            const parent = if (AppWindow.g_window) |win| win.hwnd else null;
            _ = browser_panel.submitUrlBar(allocator, parent, AppWindow.activeSurface());
            markBrowserUrlBarDirty();
        },
        win32_backend.VK_BACK => {
            browser_panel.backspaceUrlBar();
            markBrowserUrlBarDirty();
        },
        win32_backend.VK_DELETE => {
            browser_panel.clearUrlBar();
            markBrowserUrlBarDirty();
        },
        else => {},
    }
}

fn hitTestSidebarTab(xpos: f64, ypos: f64) ?usize {
    if (!tab.g_sidebar_visible) return null;
    if (xpos < 0 or xpos >= @as(f64, @floatCast(titlebar.sidebarWidth()))) return null;

    const list_top = titlebarHeight() + @as(f64, @floatCast(titlebar.sidebarHeaderHeight())) + 6;
    if (ypos < list_top) return null;

    const idx_f = (ypos - list_top) / @as(f64, @floatCast(titlebar.sidebarRowHeight()));
    const idx: usize = @intFromFloat(@floor(idx_f));
    if (idx >= tab.g_tab_count) return null;
    return idx;
}

fn hitTestSidebarPlusButton(xpos: f64, ypos: f64) bool {
    if (!tab.g_sidebar_visible) return false;
    const top = titlebarHeight();
    const plus_w: f64 = 42;
    const plus_x = @as(f64, @floatCast(titlebar.sidebarWidth())) - plus_w - 6;
    return xpos >= plus_x and xpos < plus_x + plus_w and
        ypos >= top and ypos < top + @as(f64, @floatCast(titlebar.sidebarHeaderHeight()));
}

fn hitTestSidebarTabCloseButton(xpos: f64, ypos: f64, tab_idx: usize) bool {
    if (!tab.g_sidebar_visible or tab_idx >= tab.g_tab_count or tab.g_tab_count <= 1) return false;
    const row = hitTestSidebarTab(xpos, ypos) orelse return false;
    if (row != tab_idx) return false;
    const close_x = @as(f64, @floatCast(titlebar.sidebarWidth() - tab.TAB_CLOSE_BTN_W - 4));
    return xpos >= close_x and xpos < close_x + @as(f64, tab.TAB_CLOSE_BTN_W);
}

fn shouldStartSidebarTabRename(xpos: f64, ypos: f64, tab_idx: usize) bool {
    if (tab_idx >= tab.g_tab_count) return false;
    if (hitTestSidebarPlusButton(xpos, ypos)) return false;
    if (hitTestSidebarResizeHandle(xpos, ypos)) return false;
    if (hitTestSidebarTabCloseButton(xpos, ypos, tab_idx)) return false;
    return true;
}

fn hitTestSidebarResizeHandle(xpos: f64, ypos: f64) bool {
    if (!tab.g_sidebar_visible) return false;
    if (ypos < titlebarHeight()) return false;
    const sidebar_w: f64 = @floatCast(titlebar.sidebarWidth());
    const half_hit: f64 = @as(f64, @floatCast(titlebar.SIDEBAR_RESIZE_HIT_WIDTH)) / 2;
    return xpos >= sidebar_w - half_hit and xpos <= sidebar_w + half_hit;
}

fn applySidebarWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    if (!titlebar.setSidebarWidth(@floatCast(xpos), @floatFromInt(win.width))) return;
    syncGridFromWindowSize(win.width, win.height);
    win.sidebar_width = @intFromFloat(titlebar.sidebarWidth());
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn hitTestFileExplorer(xpos: f64, ypos: f64) bool {
    if (!file_explorer.g_visible) return false;
    if (ypos < titlebarHeight()) return false;
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    return xpos >= panel_x and xpos < panel_right;
}

fn hitTestMarkdownPreviewPanel(xpos: f64, ypos: f64) bool {
    if (!markdown_preview_panel.g_visible) return false;
    if (ypos < titlebarHeight()) return false;
    const win = AppWindow.g_window orelse return false;
    const preview_w: f64 = @floatCast(markdown_preview_panel.width());
    const panel_x: f64 = @as(f64, @floatFromInt(win.width)) - preview_w;
    return xpos >= panel_x and xpos < panel_x + preview_w;
}

fn browserPanelBounds() ?browser_panel.Bounds {
    if (!browser_panel.g_visible) return null;
    const win = AppWindow.g_window orelse return null;
    return browser_panel.boundsForWindow(
        win.width,
        win.height,
        @floatCast(titlebarHeight()),
        AppWindow.leftPanelsWidth(),
        AppWindow.browserPanelRightOffset(),
    );
}

fn hitTestBrowserPanel(xpos: f64, ypos: f64) bool {
    const bounds = browserPanelBounds() orelse return false;
    return xpos >= @as(f64, @floatFromInt(bounds.left)) and
        xpos < @as(f64, @floatFromInt(bounds.right)) and
        ypos >= @as(f64, @floatFromInt(bounds.top)) and
        ypos < @as(f64, @floatFromInt(bounds.bottom));
}

fn hitTestBrowserUrlBar(xpos: f64, ypos: f64) bool {
    const bounds = browserPanelBounds() orelse return false;
    const url_bar = browser_panel.urlBarBounds(bounds) orelse return false;
    return xpos >= @as(f64, @floatFromInt(url_bar.left)) and
        xpos < @as(f64, @floatFromInt(url_bar.right)) and
        ypos >= @as(f64, @floatFromInt(url_bar.top)) and
        ypos < @as(f64, @floatFromInt(url_bar.bottom));
}

fn hitTestBrowserResizeHandle(xpos: f64, ypos: f64) bool {
    if (!browser_panel.g_visible) return false;
    if (ypos < titlebarHeight()) return false;
    const bounds = browserPanelBounds() orelse return false;
    const panel_x: f64 = @floatFromInt(bounds.left);
    const half_hit: f64 = @as(f64, @floatCast(browser_panel.RESIZE_HIT_WIDTH)) / 2;
    return xpos >= panel_x - half_hit and xpos <= panel_x + half_hit;
}

fn applyBrowserWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const right_edge = @as(f64, @floatFromInt(win.width)) - @as(f64, @floatCast(AppWindow.browserPanelRightOffset()));
    const new_width = right_edge - xpos;
    const available_width: f32 = @as(f32, @floatFromInt(win.width)) - AppWindow.leftPanelsWidth() - AppWindow.browserPanelRightOffset();
    if (!browser_panel.setWidth(@floatCast(new_width), available_width)) return;
    syncGridFromWindowSize(win.width, win.height);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn hitTestMarkdownPreviewResizeHandle(xpos: f64, ypos: f64) bool {
    if (!markdown_preview_panel.g_visible) return false;
    if (ypos < titlebarHeight()) return false;
    const win = AppWindow.g_window orelse return false;
    const preview_w: f64 = @floatCast(markdown_preview_panel.width());
    const panel_x: f64 = @as(f64, @floatFromInt(win.width)) - preview_w;
    const half_hit: f64 = @as(f64, @floatCast(markdown_preview_panel.RESIZE_HIT_WIDTH)) / 2;
    return xpos >= panel_x - half_hit and xpos <= panel_x + half_hit;
}

fn applyMarkdownPreviewWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const right_edge = @as(f64, @floatFromInt(win.width));
    const new_width = right_edge - xpos;
    if (!markdown_preview_panel.setWidth(@floatCast(new_width), @floatFromInt(win.width))) return;
    syncGridFromWindowSize(win.width, win.height);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn hitTestFileExplorerResizeHandle(xpos: f64, ypos: f64) bool {
    if (!file_explorer.g_visible) return false;
    if (ypos < titlebarHeight()) return false;
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    const half_hit: f64 = @as(f64, @floatCast(file_explorer.RESIZE_HIT_WIDTH)) / 2;
    return xpos >= panel_right - half_hit and xpos <= panel_right + half_hit;
}

fn applyExplorerWidthFromMouse(xpos: f64) void {
    const win = AppWindow.g_window orelse return;
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const new_width = xpos - panel_x;
    if (!file_explorer.setWidth(@floatCast(new_width), @floatFromInt(win.width))) return;
    syncGridFromWindowSize(win.width, win.height);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn handleFileExplorerKey(ev: win32_backend.KeyEvent) bool {
    if (file_explorer.g_panel_mode == .agent_history) {
        return handleAgentHistoryKey(ev);
    }

    const VK_ESCAPE = win32_backend.VK_ESCAPE;
    const VK_RETURN = win32_backend.VK_RETURN;
    const VK_BACK = win32_backend.VK_BACK;
    const VK_UP = win32_backend.VK_UP;
    const VK_DOWN = win32_backend.VK_DOWN;

    // In input mode (rename/new file/new dir)
    if (file_explorer.g_op_mode != .none) {
        switch (ev.vk) {
            VK_ESCAPE => {
                file_explorer.cancelOp();
                return true;
            },
            VK_RETURN => {
                file_explorer.commitOp();
                return true;
            },
            VK_BACK => {
                file_explorer.inputBackspace();
                return true;
            },
            else => return false,
        }
    }

    // Normal navigation mode
    switch (ev.vk) {
        VK_ESCAPE => {
            file_explorer.g_focused = false;
            return true;
        },
        VK_UP => {
            file_explorer.moveSelection(-1);
            return true;
        },
        VK_DOWN => {
            file_explorer.moveSelection(1);
            return true;
        },
        VK_RETURN => {
            // Enter on directory = toggle expand
            if (file_explorer.g_selected) |sel| {
                if (sel < file_explorer.g_entry_count and file_explorer.g_entries[sel].is_dir) {
                    file_explorer.toggleExpand(sel);
                }
            }
            return true;
        },
        0x52 => { // 'R' key = rename
            if (!ev.ctrl and !ev.alt) {
                file_explorer.startRename();
                return true;
            }
            return false;
        },
        0x4E => { // 'N' key = new file, Shift+N = new dir
            if (!ev.ctrl and !ev.alt) {
                if (ev.shift) {
                    file_explorer.startNewDir();
                } else {
                    file_explorer.startNewFile();
                }
                return true;
            }
            return false;
        },
        0x44 => { // 'D' key = delete
            if (!ev.ctrl and !ev.alt and !ev.shift) {
                file_explorer.startDelete();
                return true;
            }
            return false;
        },
        0x53 => { // 'S' key: Ctrl+S = download selected file
            if (ev.ctrl and !ev.alt and !ev.shift) {
                if (file_explorer.g_mode == .remote) {
                    // Download to user's Downloads folder
                    var dl_buf: [260]u8 = undefined;
                    const dl_path = getDownloadsFolder(&dl_buf);
                    if (dl_path.len > 0) {
                        file_explorer.downloadSelected(dl_path);
                    }
                    return true;
                }
            }
            return false;
        },
        0x55 => { // 'U' key = upload local file to remote
            if (!ev.ctrl and !ev.alt and !ev.shift) {
                if (file_explorer.g_mode == .remote) {
                    openFileDialogAndUpload();
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn handleAgentHistoryKey(ev: win32_backend.KeyEvent) bool {
    switch (ev.vk) {
        win32_backend.VK_ESCAPE => {
            file_explorer.g_focused = false;
            return true;
        },
        win32_backend.VK_UP => {
            file_explorer.moveHistorySelection(-1);
            return true;
        },
        win32_backend.VK_DOWN => {
            file_explorer.moveHistorySelection(1);
            return true;
        },
        win32_backend.VK_RETURN => {
            activateSelectedAgentHistoryRow();
            return true;
        },
        else => return false,
    }
}

fn getDownloadsFolder(buf: *[260]u8) []const u8 {
    // Use %USERPROFILE%\Downloads
    const userprofile = std.process.getEnvVarOwned(std.heap.page_allocator, "USERPROFILE") catch return "";
    defer std.heap.page_allocator.free(userprofile);
    const suffix = "\\Downloads";
    if (userprofile.len + suffix.len > buf.len) return "";
    @memcpy(buf[0..userprofile.len], userprofile);
    @memcpy(buf[userprofile.len..][0..suffix.len], suffix);
    return buf[0 .. userprofile.len + suffix.len];
}

fn openFileDialogAndUpload() void {
    // Use Win32 GetOpenFileNameA for simplicity
    var filename_buf: [260]u8 = .{0} ** 260;

    var ofn: win32_backend.OPENFILENAMEA = .{
        .lStructSize = @sizeOf(win32_backend.OPENFILENAMEA),
        .hwndOwner = if (AppWindow.g_window) |w| w.hwnd else null,
        .lpstrFile = &filename_buf,
        .nMaxFile = 260,
        .lpstrFilter = "All Files\x00*.*\x00\x00",
        .nFilterIndex = 1,
        .lpstrTitle = "Upload file to remote",
        .Flags = 0x00001000 | 0x00000800, // OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST
    };

    if (win32_backend.GetOpenFileNameA(&ofn) != 0) {
        // Find null terminator
        var len: usize = 0;
        while (len < 260 and filename_buf[len] != 0) len += 1;
        if (len > 0) {
            file_explorer.uploadFile(filename_buf[0..len]);
        }
    }
}

fn handleFileExplorerPress(xpos: f64, ypos: f64, ctrl: bool, shift: bool, alt: bool) void {
    file_explorer.g_focused = true;

    // Check resize handle first
    if (hitTestFileExplorerResizeHandle(xpos, ypos)) {
        g_explorer_resize_dragging = true;
        g_explorer_resize_hover = true;
        _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
        return;
    }

    if (file_explorer.g_panel_mode == .agent_history) {
        handleAgentHistoryPress(xpos, ypos);
        return;
    }

    // Cancel any active op on click elsewhere in the panel
    if (file_explorer.g_op_mode != .none) {
        file_explorer.cancelOp();
    }

    // Click on a file entry
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    if (xpos < panel_x or xpos >= panel_right) return;

    const titlebar_h = titlebarHeight();
    const header_h: f64 = @floatCast(file_explorer.headerHeight());
    const list_top = titlebar_h + header_h;
    if (ypos < list_top) return;

    const row_h: f64 = @floatCast(file_explorer.rowHeight());
    const scroll: f64 = @floatCast(file_explorer.g_scroll_offset);
    const row_idx: usize = @intFromFloat((ypos - list_top + scroll) / row_h);

    if (row_idx < file_explorer.g_entry_count) {
        const click_count = nextLeftClickCount(xpos, ypos);
        file_explorer.g_selected = row_idx;
        if (!file_explorer.g_entries[row_idx].is_dir and ((ctrl and !shift and !alt) or click_count == 2)) {
            if (openFileExplorerPreview(row_idx)) {
                AppWindow.g_force_rebuild = true;
                return;
            }
        }
        if (file_explorer.g_entries[row_idx].is_dir) {
            file_explorer.toggleExpand(row_idx);
        }
        AppWindow.g_force_rebuild = true;
    }
}

fn handleAgentHistoryPress(xpos: f64, ypos: f64) void {
    const panel_x: f64 = @floatCast(titlebar.sidebarWidth());
    const panel_right = panel_x + @as(f64, @floatCast(file_explorer.width()));
    if (xpos < panel_x or xpos >= panel_right) return;

    const titlebar_h = titlebarHeight();
    const header_h: f64 = @floatCast(file_explorer.headerHeight());
    const list_top = titlebar_h + header_h;
    if (ypos < list_top) return;

    const row_h: f64 = @floatCast(file_explorer.rowHeight());
    const scroll: f64 = @floatCast(file_explorer.g_history_scroll_offset);
    const row_idx: usize = @intFromFloat((ypos - list_top + scroll) / row_h);
    if (row_idx >= file_explorer.g_history_row_count) return;

    const click_count = nextLeftClickCount(xpos, ypos);
    file_explorer.g_history_selected = row_idx;
    if (click_count == 2) {
        activateSelectedAgentHistoryRow();
        return;
    }
    AppWindow.g_force_rebuild = true;
}

fn activateSelectedAgentHistoryRow() void {
    const session_id = file_explorer.selectedHistorySessionId() orelse return;
    file_explorer.g_focused = false;
    if (!AppWindow.reopenAiChatTabFromHistorySessionId(session_id)) return;
    file_explorer.g_focused = false;
}

fn hitTestConfigButton(xpos: f64, ypos: f64) bool {
    const titlebar_h = titlebarHeight();
    if (ypos < 0 or ypos >= titlebar_h) return false;

    const win = AppWindow.g_window orelse return false;
    const window_width: f64 = @floatFromInt(win.width);
    const caption_w: f64 = 46 * 3;
    const config_w: f64 = @floatCast(titlebar.TITLEBAR_CONFIG_W);
    const config_x = window_width - caption_w - config_w;
    return xpos >= config_x and xpos < config_x + config_w;
}

fn hitTestHelpButton(xpos: f64, ypos: f64) bool {
    const titlebar_h = titlebarHeight();
    if (ypos < 0 or ypos >= titlebar_h) return false;

    const win = AppWindow.g_window orelse return false;
    const window_width: f64 = @floatFromInt(win.width);
    const caption_w: f64 = 46 * 3;
    const config_w: f64 = @floatCast(titlebar.TITLEBAR_CONFIG_W);
    const help_w: f64 = @floatCast(titlebar.TITLEBAR_HELP_W);
    const help_x = window_width - caption_w - config_w - help_w;
    return xpos >= help_x and xpos < help_x + help_w;
}

fn handleTopbarPress(xpos: f64) void {
    if (xpos >= 0 and xpos < @as(f64, titlebar.TITLEBAR_TOGGLE_W)) {
        toggleSidebar();
        return;
    }

    if (hitTestHelpButton(xpos, titlebarHeight() / 2)) {
        overlays.startupShortcutsToggle();
        return;
    }

    if (hitTestConfigButton(xpos, titlebarHeight() / 2)) {
        overlays.settingsPageOpen();
    }
}

fn handleSidebarPress(xpos: f64, ypos: f64) void {
    if (tab.g_tab_rename_active) tab.commitTabRename();

    if (hitTestSidebarPlusButton(xpos, ypos)) {
        overlays.sessionLauncherOpen();
        return;
    }

    if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
        if (tab.g_tab_count > 1 and tab.g_tab_close_opacity[tab_idx] > 0.1 and hitTestSidebarTabCloseButton(xpos, ypos, tab_idx)) {
            tab.g_tab_close_pressed = tab_idx;
            return;
        }
        AppWindow.switchTab(tab_idx);
    }
}

fn viewportCellCodepoint(surface: *Surface, col: usize, row: usize) u21 {
    const cell_data = surface.terminal.screens.active.pages.getCell(.{ .viewport = .{
        .x = @intCast(col),
        .y = @intCast(row),
    } }) orelse return 0;
    return @intCast(cell_data.cell.codepoint());
}

fn markSelectionChanged() void {
    g_selection_changed_for_copy = true;
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn nextLeftClickCount(xpos: f64, ypos: f64) u8 {
    const now = std.time.milliTimestamp();
    const max_distance: f64 = @floatCast(@max(font.cell_width, font.cell_height));
    const dx = xpos - g_left_click_x;
    const dy = ypos - g_left_click_y;
    const distance = @sqrt(dx * dx + dy * dy);
    const within_interval = g_left_click_count > 0 and now - g_left_click_time_ms <= MULTI_CLICK_INTERVAL_MS;
    const within_distance = g_left_click_count > 0 and distance <= max_distance;

    if (!within_interval or !within_distance) g_left_click_count = 0;

    g_left_click_count += 1;
    if (g_left_click_count > 4) g_left_click_count = 1;
    g_left_click_time_ms = now;
    g_left_click_x = xpos;
    g_left_click_y = ypos;
    return g_left_click_count;
}

fn resetLeftClickCount() void {
    g_left_click_count = 0;
    g_left_click_time_ms = 0;
    g_left_click_x = 0;
    g_left_click_y = 0;
}

fn readViewportRowLocked(surface: *Surface, row: usize, buf: *[MAX_SELECTION_COLS]u21) []const u21 {
    const cols = @min(@as(usize, @intCast(surface.size.grid.cols)), buf.len);
    if (row >= @as(usize, @intCast(surface.size.grid.rows))) return buf[0..0];
    for (0..cols) |col| {
        buf[col] = viewportCellCodepoint(surface, col, row);
    }
    return buf[0..cols];
}

fn viewportRowIsBlankLocked(surface: *Surface, row: usize, buf: *[MAX_SELECTION_COLS]u21) bool {
    return selection_unit.rowIsBlank(readViewportRowLocked(surface, row, buf));
}

fn activateSelection(surface: *Surface, start_col: usize, start_row: usize, end_col: usize, end_row: usize) void {
    surface.selection.has_anchor = true;
    surface.selection.start_col = start_col;
    surface.selection.start_row = start_row;
    surface.selection.end_col = end_col;
    surface.selection.end_row = end_row;
    surface.selection.active = true;
    markSelectionChanged();
}

fn clearSelectionAtCell(surface: *Surface, cell_pos: CellPos) void {
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    surface.selection.has_anchor = true;
    surface.selection.start_col = cell_pos.col;
    surface.selection.start_row = abs_row;
    surface.selection.end_col = cell_pos.col;
    surface.selection.end_row = abs_row;
    surface.selection.active = false;
    markSelectionChanged();
}

fn startSelectionAtCell(surface: *Surface, cell_pos: CellPos, xpos: f64, ypos: f64) void {
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    surface.selection.has_anchor = true;
    surface.selection.start_col = cell_pos.col;
    surface.selection.start_row = abs_row;
    surface.selection.end_col = cell_pos.col;
    surface.selection.end_row = abs_row;
    surface.selection.active = false;
    g_selecting = true;
    g_click_x = xpos;
    g_click_y = ypos;
    markSelectionChanged();
}

fn extendSelectionAtCell(surface: *Surface, cell_pos: CellPos, xpos: f64, ypos: f64) bool {
    if (!surface.selection.has_anchor) return false;
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    const same_cell = surface.selection.start_col == cell_pos.col and surface.selection.start_row == abs_row;
    surface.selection.end_col = cell_pos.col;
    surface.selection.end_row = abs_row;
    surface.selection.active = !same_cell;
    g_selecting = true;
    g_click_x = xpos;
    g_click_y = ypos;
    markSelectionChanged();
    return true;
}

fn selectWordAtCell(surface: *Surface, cell_pos: CellPos) bool {
    var row_buf: [MAX_SELECTION_COLS]u21 = undefined;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const row = readViewportRowLocked(surface, cell_pos.row, &row_buf);
    if (cell_pos.col >= row.len) return false;
    const range = selection_unit.wordRange(row, cell_pos.col) orelse return false;
    const abs_row = viewportOffsetForSurfaceLocked(surface) + cell_pos.row;
    activateSelection(surface, range.start, abs_row, range.end, abs_row);
    return true;
}

fn selectSentenceAtCell(surface: *Surface, cell_pos: CellPos) bool {
    var row_buf: [MAX_SELECTION_COLS]u21 = undefined;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const row = readViewportRowLocked(surface, cell_pos.row, &row_buf);
    if (cell_pos.col >= row.len) return false;
    const range = selection_unit.sentenceRange(row, cell_pos.col) orelse return false;
    const abs_row = viewportOffsetForSurfaceLocked(surface) + cell_pos.row;
    activateSelection(surface, range.start, abs_row, range.end, abs_row);
    return true;
}

fn selectParagraphAtCell(surface: *Surface, cell_pos: CellPos) bool {
    var row_buf: [MAX_SELECTION_COLS]u21 = undefined;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const rows = @as(usize, @intCast(surface.size.grid.rows));
    if (cell_pos.row >= rows or viewportRowIsBlankLocked(surface, cell_pos.row, &row_buf)) return false;

    var start_row = cell_pos.row;
    while (start_row > 0 and !viewportRowIsBlankLocked(surface, start_row - 1, &row_buf)) : (start_row -= 1) {}

    var end_row = cell_pos.row;
    while (end_row + 1 < rows and !viewportRowIsBlankLocked(surface, end_row + 1, &row_buf)) : (end_row += 1) {}

    const start_cols = readViewportRowLocked(surface, start_row, &row_buf);
    const start_col = selection_unit.firstNonBlankCol(start_cols) orelse 0;
    const end_cols = readViewportRowLocked(surface, end_row, &row_buf);
    const end_col = selection_unit.lastNonBlankCol(end_cols) orelse 0;
    const vp_off = viewportOffsetForSurfaceLocked(surface);

    activateSelection(surface, start_col, vp_off + start_row, end_col, vp_off + end_row);
    return true;
}

fn utf8CodepointCount(text: []const u8) usize {
    const view = std.unicode.Utf8View.init(text) catch return text.len;
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint() != null) count += 1;
    return count;
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn isPreviewImagePath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".png") or
        endsWithIgnoreCase(path, ".jpg") or
        endsWithIgnoreCase(path, ".jpeg") or
        endsWithIgnoreCase(path, ".gif") or
        endsWithIgnoreCase(path, ".bmp") or
        endsWithIgnoreCase(path, ".webp");
}

fn looksLikePreviewPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) return false;
    if (markdown_preview.detectKind(path) != null) return true;
    if (path[0] == '~') return true;
    if (path.len >= 2 and path[1] == ':') return true;
    if (std.mem.indexOfScalar(u8, path, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return true;
    return endsWithIgnoreCase(path, ".pdf") or isPreviewImagePath(path);
}

fn extractTokenRangeAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?TokenAtCell {
    const cols = @as(usize, @intCast(surface.size.grid.cols));
    const rows = @as(usize, @intCast(surface.size.grid.rows));
    if (cols == 0 or rows == 0 or cell_pos.row >= rows) return null;
    const click_col = @min(cell_pos.col, cols - 1);

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    if (preview_token.isDelimiter(viewportCellCodepoint(surface, click_col, cell_pos.row))) return null;

    var start = click_col;
    while (start > 0) {
        const cp = viewportCellCodepoint(surface, start - 1, cell_pos.row);
        if (preview_token.isDelimiter(cp)) break;
        start -= 1;
    }

    var end = click_col + 1;
    while (end < cols) : (end += 1) {
        const cp = viewportCellCodepoint(surface, end, cell_pos.row);
        if (preview_token.isDelimiter(cp)) break;
    }

    var token: std.ArrayListUnmanaged(u8) = .empty;
    defer token.deinit(allocator);
    var col = start;
    while (col < end) : (col += 1) {
        const cp = viewportCellCodepoint(surface, col, cell_pos.row);
        if (preview_token.isDelimiter(cp)) break;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch continue;
        token.appendSlice(allocator, buf[0..len]) catch return null;
    }

    const span = preview_token.trimSpan(token.items);
    if (span.start >= span.end) return null;

    const leading_cols = utf8CodepointCount(token.items[0..span.start]);
    const trailing_cols = utf8CodepointCount(token.items[span.end..]);
    const start_col = @min(start + leading_cols, cols - 1);
    const end_exclusive = if (end > trailing_cols) end - trailing_cols else start_col + 1;
    const end_col = @max(start_col, @min(end_exclusive - 1, cols - 1));
    const text = allocator.dupe(u8, token.items[span.start..span.end]) catch return null;

    return .{
        .text = text,
        .row = cell_pos.row,
        .start_col = start_col,
        .end_col = end_col,
    };
}

fn extractTokenAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    return token.text;
}

fn looksLikeUrl(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "http://") or
        std.mem.startsWith(u8, text, "https://") or
        std.mem.startsWith(u8, text, "www.");
}

fn extractUrlRangeAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?TokenAtCell {
    const token = extractTokenRangeAtCell(allocator, surface, cell_pos) orelse return null;
    if (!looksLikeUrl(token.text)) {
        token.deinit(allocator);
        return null;
    }
    return token;
}

fn extractUrlAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractUrlRangeAtCell(allocator, surface, cell_pos) orelse return null;
    return token.text;
}

fn markUrlUnderlineDirty(surface: ?*Surface) void {
    const s = surface orelse return;
    s.surface_renderer.markDirty();
    AppWindow.g_force_rebuild = true;
}

fn setUrlUnderline(surface: *Surface, row_abs: usize, start_col: usize, end_col: usize) void {
    const old_surface = g_url_underline.surface;
    if (g_url_underline.surface == surface and
        g_url_underline.row_abs == row_abs and
        g_url_underline.start_col == start_col and
        g_url_underline.end_col == end_col)
    {
        return;
    }

    g_url_underline = .{
        .surface = surface,
        .row_abs = row_abs,
        .start_col = start_col,
        .end_col = end_col,
    };
    markUrlUnderlineDirty(old_surface);
    markUrlUnderlineDirty(surface);
}

fn clearUrlUnderline() void {
    if (!g_url_underline.active()) return;
    const old_surface = g_url_underline.surface;
    g_url_underline = .{};
    markUrlUnderlineDirty(old_surface);
}

pub fn isUrlUnderlineCell(surface: *Surface, col: usize, row: usize) bool {
    if (g_url_underline.surface != surface) return false;
    const abs_row = viewportOffsetForSurface(surface) + row;
    return abs_row == g_url_underline.row_abs and
        col >= g_url_underline.start_col and
        col <= g_url_underline.end_col;
}

fn extractPreviewPathAtCell(allocator: std.mem.Allocator, surface: *Surface, cell_pos: CellPos) ?[]u8 {
    const token = extractTokenAtCell(allocator, surface, cell_pos) orelse return null;
    if (!looksLikePreviewPath(token)) {
        allocator.free(token);
        return null;
    }
    return token;
}

fn openUrl(surface: *Surface, url: []const u8) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const target = if (std.mem.startsWith(u8, url, "www."))
        std.fmt.allocPrint(allocator, "https://{s}", .{url}) catch return false
    else
        allocator.dupe(u8, url) catch return false;
    defer allocator.free(target);

    const hwnd = if (AppWindow.g_window) |win| win.hwnd else null;
    if (!browser_panel.openForSurface(allocator, hwnd, target, surface)) return false;
    if (AppWindow.g_window) |win| {
        syncGridFromWindowSizeImmediate(win.width, win.height);
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
    return true;
}

fn openUrlAtCell(surface: *Surface, cell_pos: CellPos) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const token = extractUrlRangeAtCell(allocator, surface, cell_pos) orelse return false;
    defer token.deinit(allocator);
    setUrlUnderline(surface, viewportOffsetForSurface(surface) + token.row, token.start_col, token.end_col);
    const opened = openUrl(surface, token.text);
    if (opened) clearUrlUnderline();
    return opened;
}

fn updateUrlUnderlineAtMouse(xpos: f64, ypos: f64) void {
    if (g_selecting or overlays.g_scrollbar_dragging or g_divider_dragging) {
        clearUrlUnderline();
        return;
    }
    if (ypos < titlebarHeight() or hitTestFileExplorer(xpos, ypos) or hitTestMarkdownPreviewPanel(xpos, ypos) or hitTestBrowserPanel(xpos, ypos)) {
        clearUrlUnderline();
        return;
    }
    if (tab.g_sidebar_visible and xpos < @as(f64, @floatCast(titlebar.sidebarWidth()))) {
        clearUrlUnderline();
        return;
    }

    const surface = split_layout.surfaceAtPoint(@intFromFloat(xpos), @intFromFloat(ypos)) orelse {
        clearUrlUnderline();
        return;
    };
    const allocator = AppWindow.g_allocator orelse return;
    const cell_pos = mouseToSurfaceCell(surface, xpos, ypos);
    const token = extractUrlRangeAtCell(allocator, surface, cell_pos) orelse {
        clearUrlUnderline();
        return;
    };
    defer token.deinit(allocator);

    setUrlUnderline(surface, viewportOffsetForSurface(surface) + token.row, token.start_col, token.end_col);
}

fn appendShellQuoted(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try list.append(allocator, '\'');
    for (text) |ch| {
        if (ch == '\'') {
            try list.appendSlice(allocator, "'\\''");
        } else {
            try list.append(allocator, ch);
        }
    }
    try list.append(allocator, '\'');
}

fn readLocalPreviewSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = blk: {
        if (std.fs.path.isAbsolute(path)) {
            break :blk std.fs.openFileAbsolute(path, .{}) catch return error.PreviewFailed;
        }
        break :blk std.fs.cwd().openFile(path, .{}) catch return error.PreviewFailed;
    };
    defer file.close();

    const source = file.readToEndAlloc(allocator, markdown_preview.MAX_SOURCE_BYTES + 1) catch return error.PreviewFailed;
    errdefer allocator.free(source);
    if (source.len > markdown_preview.MAX_SOURCE_BYTES) return error.PreviewTooLarge;
    return source;
}

fn buildRemotePreviewReadCommand(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buf: [1024]u8 = undefined;
    const path_expr = file_backend.shellPathExpr(&path_buf, path) orelse return error.PreviewFailed;
    return std.fmt.allocPrint(allocator, "head -c {} -- {s}", .{ markdown_preview.MAX_SOURCE_BYTES + 1, path_expr });
}

fn readSshPreviewSource(allocator: std.mem.Allocator, conn: *const Surface.SshConnection, path: []const u8) ![]u8 {
    const command = buildRemotePreviewReadCommand(allocator, path) catch return error.PreviewFailed;
    defer allocator.free(command);

    const source = scp.sshExec(allocator, conn, command) orelse return error.PreviewFailed;
    errdefer allocator.free(source);
    if (source.len > markdown_preview.MAX_SOURCE_BYTES) return error.PreviewTooLarge;
    return source;
}

fn readRemotePreviewSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!file_explorer.g_has_ssh_conn) return error.PreviewFailed;
    return readSshPreviewSource(allocator, &file_explorer.g_ssh_conn, path);
}

fn buildWslPreviewReadCommand(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buf: [1024]u8 = undefined;
    const path_expr = file_backend.wslPathExpr(&path_buf, path) orelse return error.PreviewFailed;
    return std.fmt.allocPrint(allocator, "head -c {} -- {s}", .{ markdown_preview.MAX_SOURCE_BYTES + 1, path_expr });
}

fn readWslPreviewSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const command = buildWslPreviewReadCommand(allocator, path) catch return error.PreviewFailed;
    defer allocator.free(command);

    const source = file_backend.wslExec(allocator, command) orelse return error.PreviewFailed;
    errdefer allocator.free(source);
    if (source.len > markdown_preview.MAX_SOURCE_BYTES) return error.PreviewTooLarge;
    return source;
}

fn basenameForPreview(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') start = i + 1;
    }
    return path[start..];
}

fn isUnixAbsoluteOrHome(path: []const u8) bool {
    return path.len > 0 and (path[0] == '/' or path[0] == '~');
}

fn joinUnixPreviewPath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (isUnixAbsoluteOrHome(path)) return allocator.dupe(u8, path);
    if (cwd.len == 0) return allocator.dupe(u8, path);
    if (std.mem.eql(u8, cwd, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{path});
    const base = std.mem.trimRight(u8, cwd, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path });
}

fn resolveTerminalPreviewPath(allocator: std.mem.Allocator, surface: *Surface, path: []const u8) ![]u8 {
    return switch (surface.launch_kind) {
        .wsl, .ssh => blk: {
            const cwd = surface.getCwd() orelse "~";
            break :blk try joinUnixPreviewPath(allocator, cwd, path);
        },
        .windows => blk: {
            if (std.fs.path.isAbsolute(path) or (path.len >= 2 and path[1] == ':')) {
                break :blk try allocator.dupe(u8, path);
            }
            const cwd = surface.getInitialCwd() orelse {
                break :blk try allocator.dupe(u8, path);
            };
            break :blk try std.fs.path.join(allocator, &.{ cwd, path });
        },
    };
}

fn readTerminalPreviewSource(allocator: std.mem.Allocator, surface: *Surface, path: []const u8) ![]u8 {
    return switch (surface.launch_kind) {
        .wsl => readWslPreviewSource(allocator, path),
        .ssh => blk: {
            const conn = surface.ssh_connection orelse {
                std.debug.print("Markdown preview over SSH needs Phantty SSH connection metadata; manual ssh sessions are not supported yet\n", .{});
                return error.PreviewFailed;
            };
            break :blk try readSshPreviewSource(allocator, &conn, path);
        },
        .windows => readLocalPreviewSource(allocator, path),
    };
}

fn openRenderedPreview(allocator: std.mem.Allocator, kind: markdown_preview.Kind, title: []const u8, path: []const u8, source: []const u8) bool {
    _ = allocator;
    markdown_preview_panel.open(kind, title, path, source);
    if (AppWindow.g_window) |win| syncGridFromWindowSizeImmediate(win.width, win.height);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
    file_explorer.setTransferStatus(.success, title);
    return true;
}

fn openFileExplorerPreview(row_idx: usize) bool {
    if (row_idx >= file_explorer.g_entry_count) return false;
    const entry = &file_explorer.g_entries[row_idx];
    if (entry.is_dir) return false;

    const path = entry.path_buf[0..entry.path_len];
    const kind = markdown_preview.detectKind(path) orelse return false;
    const allocator = AppWindow.g_allocator orelse return false;
    const title = entry.name_buf[0..entry.name_len];

    const source = switch (file_explorer.g_mode) {
        .local => readLocalPreviewSource(allocator, path),
        .wsl => readWslPreviewSource(allocator, path),
        .remote => readRemotePreviewSource(allocator, path),
    } catch |err| {
        file_explorer.setTransferStatus(.failed, if (err == error.PreviewTooLarge) "Preview too large" else "Preview failed");
        return true;
    };
    defer allocator.free(source);

    return openRenderedPreview(allocator, kind, title, path, source);
}

fn buildPreviewCommand(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var cmd: std.ArrayListUnmanaged(u8) = .empty;

    if (endsWithIgnoreCase(path, ".pdf")) {
        cmd.appendSlice(allocator, "pdfcat ") catch {
            cmd.deinit(allocator);
            return null;
        };
    } else if (isPreviewImagePath(path)) {
        cmd.appendSlice(allocator, "imgcat ") catch {
            cmd.deinit(allocator);
            return null;
        };
    } else {
        cmd.appendSlice(allocator, "less ") catch {
            cmd.deinit(allocator);
            return null;
        };
    }
    appendShellQuoted(&cmd, allocator, path) catch {
        cmd.deinit(allocator);
        return null;
    };
    cmd.append(allocator, '\r') catch {
        cmd.deinit(allocator);
        return null;
    };
    return cmd.toOwnedSlice(allocator) catch {
        cmd.deinit(allocator);
        return null;
    };
}

fn openPreviewPanelForCell(surface: *Surface, cell_pos: CellPos) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const path = extractPreviewPathAtCell(allocator, surface, cell_pos) orelse return false;
    defer allocator.free(path);

    if (markdown_preview.detectKind(path)) |kind| {
        const resolved_path = resolveTerminalPreviewPath(allocator, surface, path) catch {
            file_explorer.setTransferStatus(.failed, "Preview failed");
            return true;
        };
        defer allocator.free(resolved_path);

        const source = readTerminalPreviewSource(allocator, surface, resolved_path) catch |err| {
            file_explorer.setTransferStatus(.failed, if (err == error.PreviewTooLarge) "Preview too large" else "Preview failed");
            return true;
        };
        defer allocator.free(source);

        return openRenderedPreview(allocator, kind, basenameForPreview(path), resolved_path, source);
    }

    const command = buildPreviewCommand(allocator, path) orelse return false;
    defer allocator.free(command);

    const preview_surface = AppWindow.splitFocusedReturningSurface(.right) orelse return false;
    writeTextToSurfacePty(preview_surface, command);
    return true;
}

fn handleMouseButton(ev: win32_backend.MouseButtonEvent) void {
    if (ev.action == .press) g_close_shortcut_confirm_until_ms = 0;
    if (overlays.windowCloseConfirmVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            _ = overlays.windowCloseConfirmExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height));
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        }
        return;
    }
    if (!hitTestHelpButton(@floatFromInt(ev.x), @floatFromInt(ev.y)))
        overlays.startupShortcutsDismiss();
    if (overlays.sessionLauncherVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.sessionLauncherExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.sessionLauncherContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.sessionLauncherClose();
            }
        }
        return;
    }
    if (overlays.settingsPageVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.settingsPageExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.settingsPageContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.settingsPageClose();
            }
        }
        return;
    }
    if (overlays.commandPaletteVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.commandPaletteExecuteAt(xpos, ypos, w_f, h_f, top_offset)) return;
            if (!overlays.commandPaletteContainsPoint(xpos, ypos, w_f, h_f, top_offset)) {
                overlays.commandPaletteClose();
            }
        }
        return;
    }
    if (ev.button == .left and ev.action == .press) {
        const win = AppWindow.g_window orelse return;
        const fb = win.getFramebufferSize();
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        if (overlays.remoteKeyCopyHitTest(xpos, ypos, @floatFromInt(fb.height))) {
            _ = copyRemoteSessionKeyToClipboard();
            return;
        }
    }
    // Double-click on tab text to rename, elsewhere to maximize
    if (ev.button == .left and ev.action == .double_click) {
        const xpos: f64 = @floatFromInt(ev.x);
        const titlebar_h: f64 = titlebarHeight();
        const ypos: f64 = @floatFromInt(ev.y);
        if (hitTestFileExplorer(xpos, ypos)) {
            handleFileExplorerPress(xpos, ypos, ev.ctrl, ev.shift, ev.alt);
            return;
        }
        if (ypos < titlebar_h) {
            if (hitTestConfigButton(xpos, ypos)) {
                overlays.settingsPageOpen();
            } else if (xpos >= @as(f64, titlebar.TITLEBAR_TOGGLE_W)) {
                toggleMaximize();
            }
        } else if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
            if (shouldStartSidebarTabRename(xpos, ypos, tab_idx)) {
                tab.startTabRename(tab_idx);
            }
        }
        return;
    }

    // Middle-click on tab to close it
    if (ev.button == .middle and ev.action == .release) {
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        if (hitTestSidebarTab(xpos, ypos)) |tab_idx| {
            if (tab.g_tab_count <= 1) {
                AppWindow.g_should_close = true;
            } else {
                AppWindow.closeTab(tab_idx);
            }
            return;
        }
        if (AppWindow.activeAiChat()) |chat| {
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            if (AppWindow.ai_chat_renderer.inputFieldMetricsAt(
                chat,
                xpos,
                ypos,
                @floatFromInt(fb.width),
                @floatFromInt(fb.height),
                AppWindow.leftPanelsWidth(),
                AppWindow.rightPanelsWidthForWindow(fb.width),
            ) != null) {
                pasteFromClipboardIntoAiChat(chat);
                return;
            }
        }
        return;
    }

    // Right-click follows Ghostty-compatible right-click-action config.
    if (ev.button == .right and ev.action == .release) {
        handleConfiguredRightClick();
        return;
    }

    if (ev.button == .left) {
        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        const titlebar_h: f64 = titlebarHeight();

        if (ev.action == .press) {
            g_selection_changed_for_copy = false;

            // Commit rename on any click
            if (tab.g_tab_rename_active) tab.commitTabRename();

            // Check if click is in the titlebar (tab bar area)
            if (ypos < titlebar_h) {
                blurBrowserUrlBarIfFocused();
                handleTopbarPress(xpos);
                return;
            }
            const over_browser_url_bar = hitTestBrowserUrlBar(xpos, ypos);
            if (!over_browser_url_bar) blurBrowserUrlBarIfFocused();
            if (hitTestSidebarResizeHandle(xpos, ypos)) {
                g_sidebar_resize_dragging = true;
                g_sidebar_resize_hover = true;
                _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
                return;
            }
            if (hitTestFileExplorerResizeHandle(xpos, ypos)) {
                g_explorer_resize_dragging = true;
                g_explorer_resize_hover = true;
                _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
                return;
            }
            if (hitTestMarkdownPreviewResizeHandle(xpos, ypos)) {
                g_markdown_preview_resize_dragging = true;
                g_markdown_preview_resize_hover = true;
                _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
                return;
            }
            if (hitTestBrowserResizeHandle(xpos, ypos)) {
                g_browser_resize_dragging = true;
                g_browser_resize_hover = true;
                _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
                return;
            }

            if (over_browser_url_bar) {
                file_explorer.g_focused = false;
                if (file_explorer.g_op_mode != .none) file_explorer.cancelOp();
                browser_panel.focusUrlBar();
                markBrowserUrlBarDirty();
                return;
            }

            if (tab.g_sidebar_visible and xpos < @as(f64, @floatCast(titlebar.sidebarWidth()))) {
                handleSidebarPress(xpos, ypos);
                return;
            }

            if (hitTestBrowserPanel(xpos, ypos)) {
                file_explorer.g_focused = false;
                if (file_explorer.g_op_mode != .none) file_explorer.cancelOp();
                browser_panel.blurUrlBar();
                markBrowserUrlBarDirty();
                browser_panel.focus();
                return;
            }

            // File explorer left sidebar click
            if (hitTestFileExplorer(xpos, ypos)) {
                handleFileExplorerPress(xpos, ypos, ev.ctrl, ev.shift, ev.alt);
                return;
            }

            if (hitTestMarkdownPreviewPanel(xpos, ypos)) {
                file_explorer.g_focused = false;
                if (file_explorer.g_op_mode != .none) file_explorer.cancelOp();
                return;
            }

            // Clicking outside file explorer unfocuses it
            file_explorer.g_focused = false;
            if (file_explorer.g_op_mode != .none) file_explorer.cancelOp();

            if (AppWindow.activeAiChat()) |chat| {
                const win = AppWindow.g_window orelse return;
                const fb = win.getFramebufferSize();
                if (AppWindow.ai_chat_renderer.stopButtonHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    AppWindow.rightPanelsWidthForWindow(fb.width),
                )) {
                    chat.stopRequest();
                    AppWindow.g_force_rebuild = true;
                    AppWindow.g_cells_valid = false;
                    return;
                }
                if (AppWindow.ai_chat_renderer.interactionHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatFromInt(fb.height),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    AppWindow.rightPanelsWidthForWindow(fb.width),
                )) |target| {
                    switch (target) {
                        .copy_message => |message_index| copyAiChatMessageToClipboard(chat, message_index),
                        .toggle_tool => |message_index| {
                            chat.toggleToolMessageCollapsed(message_index);
                            AppWindow.g_force_rebuild = true;
                            AppWindow.g_cells_valid = false;
                        },
                        .toggle_reasoning => |message_index| {
                            chat.toggleReasoningCollapsed(message_index);
                            AppWindow.g_force_rebuild = true;
                            AppWindow.g_cells_valid = false;
                        },
                    }
                    return;
                }
                if (AppWindow.ai_chat_renderer.permissionChipHitTest(
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatCast(titlebarHeight()),
                    AppWindow.leftPanelsWidth(),
                    AppWindow.rightPanelsWidthForWindow(fb.width),
                )) {
                    toggleAiAgentPermission();
                    return;
                }
                if (AppWindow.ai_chat_renderer.inputScrollbarHitTest(
                    chat,
                    xpos,
                    ypos,
                    @floatFromInt(fb.width),
                    @floatFromInt(fb.height),
                    AppWindow.leftPanelsWidth(),
                    AppWindow.rightPanelsWidthForWindow(fb.width),
                )) |hit| {
                    g_ai_input_scroll_dragging = true;
                    g_ai_input_scroll_chat = chat;
                    g_ai_input_scroll_drag_offset = hit.drag_offset_px;
                    applyAiInputScrollbarDrag(chat, ypos);
                    AppWindow.g_force_rebuild = true;
                    AppWindow.g_cells_valid = false;
                    return;
                }
                chat.clearSelection();
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
                return;
            }

            // Click in terminal content area: update split focus
            updateFocusFromMouse(@intFromFloat(xpos), @intFromFloat(ypos));

            // Check if click is on the scrollbar
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const tb_f: f32 = @floatCast(titlebarHeight());
            const top_pad: f32 = 10 + tb_f;
            if (scrollbarTargetAt(xpos, ypos, w_f, h_f, top_pad)) |target| {
                if (overlays.scrollbarGeometryForSurface(target.surface, target.view_h, target.top_pad)) |geo| {
                    overlays.g_scrollbar_dragging = true;
                    g_scrollbar_drag_surface = target.surface;
                    g_scrollbar_drag_view_y = target.view_y;
                    g_scrollbar_drag_view_h = target.view_h;
                    g_scrollbar_drag_top_pad = target.top_pad;
                    overlays.scrollbarShowForSurface(target.surface);

                    const y_f: f32 = @as(f32, @floatCast(ypos)) - target.view_y;
                    const thumb_top_px = target.view_h - (geo.thumb_y + geo.thumb_h); // convert GL→pixel
                    const thumb_bottom_px = target.view_h - geo.thumb_y;
                    if (y_f >= thumb_top_px and y_f <= thumb_bottom_px) {
                        // Clicked on thumb — offset from top of thumb
                        overlays.g_scrollbar_drag_offset = y_f - thumb_top_px;
                    } else {
                        // Clicked on track — jump thumb center to click position
                        overlays.g_scrollbar_drag_offset = geo.thumb_h / 2;
                        overlays.scrollbarDragForSurface(target.surface, ypos, target.view_y, target.view_h, target.top_pad);
                    }
                    return;
                }
            }

            // Check if click is on a split divider
            if (split_layout.hitTestDivider(ev.x, ev.y)) |hit| {
                g_divider_dragging = true;
                g_divider_drag_handle = hit.handle;
                g_divider_drag_layout = hit.layout;
                // Initialize per-surface resize tracking with current sizes
                // so we only show overlays on surfaces that actually change
                if (AppWindow.activeTab()) |tb| {
                    var it = tb.tree.iterator();
                    while (it.next()) |entry| {
                        entry.surface.resize_overlay_active = false;
                        entry.surface.resize_overlay_last_cols = entry.surface.size.grid.cols;
                        entry.surface.resize_overlay_last_rows = entry.surface.size.grid.rows;
                    }
                }
                return;
            }

            // Find which surface was clicked and focus it
            const clicked_surface = split_layout.surfaceAtPoint(@intFromFloat(xpos), @intFromFloat(ypos)) orelse AppWindow.activeSurface() orelse return;

            // Focus the clicked split if different from current focus
            if (AppWindow.activeTab()) |tb| {
                const previous_focus = tb.focused;
                for (0..split_layout.g_split_rect_count) |i| {
                    const rect = split_layout.g_split_rects[i];
                    if (!split_layout.cachedRectIsLive(rect)) continue;
                    if (rect.surface == clicked_surface) {
                        tb.focused = rect.handle;
                        break;
                    }
                }
                if (tb.focused != previous_focus) {
                    AppWindow.handleActiveSurfaceChangeWithinTab();
                }
            }

            const cell_pos = mouseToSurfaceCell(clicked_surface, xpos, ypos);
            if (ev.ctrl and !ev.shift and !ev.alt) {
                if (openUrlAtCell(clicked_surface, cell_pos)) return;
                if (openPreviewPanelForCell(clicked_surface, cell_pos)) return;
            }

            clearUrlUnderline();
            const shift_range_select = ev.shift and !ev.ctrl and !ev.alt;
            const click_count: u8 = if (shift_range_select) blk: {
                resetLeftClickCount();
                break :blk 1;
            } else nextLeftClickCount(xpos, ypos);
            switch (click_count) {
                1 => {
                    // Shift-click extends from the last click anchor, matching
                    // document editor style range selection.
                    if (!(shift_range_select and extendSelectionAtCell(clicked_surface, cell_pos, xpos, ypos))) {
                        startSelectionAtCell(clicked_surface, cell_pos, xpos, ypos);
                    }
                },
                2 => {
                    g_selecting = false;
                    if (!selectWordAtCell(clicked_surface, cell_pos)) clearSelectionAtCell(clicked_surface, cell_pos);
                },
                3 => {
                    g_selecting = false;
                    if (!selectSentenceAtCell(clicked_surface, cell_pos)) clearSelectionAtCell(clicked_surface, cell_pos);
                },
                4 => {
                    g_selecting = false;
                    if (!selectParagraphAtCell(clicked_surface, cell_pos)) clearSelectionAtCell(clicked_surface, cell_pos);
                },
                else => unreachable,
            }
        } else {
            // Mouse up
            overlays.g_scrollbar_dragging = false;
            g_scrollbar_drag_surface = null;
            g_ai_input_scroll_dragging = false;
            g_ai_input_scroll_chat = null;
            if (g_sidebar_resize_dragging) {
                g_sidebar_resize_dragging = false;
                g_sidebar_resize_hover = hitTestSidebarResizeHandle(xpos, ypos);
                const cursor_id = if (g_sidebar_resize_hover) win32_backend.IDC_SIZEWE else win32_backend.IDC_ARROW;
                _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, cursor_id));
                return;
            }
            if (g_explorer_resize_dragging) {
                g_explorer_resize_dragging = false;
                g_explorer_resize_hover = hitTestFileExplorerResizeHandle(xpos, ypos);
                const cursor_id = if (g_explorer_resize_hover) win32_backend.IDC_SIZEWE else win32_backend.IDC_ARROW;
                _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, cursor_id));
                return;
            }
            if (g_markdown_preview_resize_dragging) {
                g_markdown_preview_resize_dragging = false;
                g_markdown_preview_resize_hover = hitTestMarkdownPreviewResizeHandle(xpos, ypos);
                const cursor_id = if (g_markdown_preview_resize_hover) win32_backend.IDC_SIZEWE else win32_backend.IDC_ARROW;
                _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, cursor_id));
                return;
            }
            if (g_browser_resize_dragging) {
                g_browser_resize_dragging = false;
                g_browser_resize_hover = hitTestBrowserResizeHandle(xpos, ypos);
                const cursor_id = if (g_browser_resize_hover) win32_backend.IDC_SIZEWE else win32_backend.IDC_ARROW;
                _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, cursor_id));
                return;
            }

            // Handle divider drag release
            if (g_divider_dragging) {
                g_divider_dragging = false;
                g_divider_drag_handle = null;
                g_divider_drag_layout = null;
                // Reset per-surface resize overlay state
                if (AppWindow.activeTab()) |tb| {
                    var it = tb.tree.iterator();
                    while (it.next()) |entry| {
                        entry.surface.resize_overlay_active = false;
                    }
                }
                // Cursor will be reset in handleMouseMove
                return;
            }

            // Handle close button release — close tab if still on the close button
            if (tab.g_tab_close_pressed) |pressed_idx| {
                tab.g_tab_close_pressed = null;
                if (pressed_idx < tab.g_tab_count and hitTestSidebarTabCloseButton(xpos, ypos, pressed_idx)) {
                    if (tab.g_tab_count <= 1) {
                        AppWindow.g_should_close = true;
                    } else {
                        AppWindow.closeTab(pressed_idx);
                    }
                }
                return;
            }

            if (plus_btn_pressed) {
                plus_btn_pressed = false;
                // Only fire if still in the + button area
                if (hitTestSidebarPlusButton(xpos, ypos)) {
                    overlays.sessionLauncherOpen();
                }
                return;
            }
            if (AppWindow.g_copy_on_select and g_selection_changed_for_copy and activeTerminalSelectionExists()) {
                copySelectionToClipboard();
            }
            g_selection_changed_for_copy = false;
            g_selecting = false;
        }
    }
}

fn handleTabBarPress(xpos: f64) void {
    // Commit any active rename when clicking in the tab bar
    if (tab.g_tab_rename_active) {
        tab.commitTabRename();
    }
    const win = AppWindow.g_window orelse return;
    const window_width: f64 = blk: {
        var rect: win32_backend.RECT = undefined;
        _ = win32_backend.GetClientRect(win.hwnd, &rect);
        break :blk @floatFromInt(rect.right);
    };

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    // Check which tab was clicked — also check close button
    var cursor: f64 = 0;
    for (0..num_tabs) |tab_idx| {
        if (xpos >= cursor and xpos < cursor + tab_w) {
            // Check if the close button was clicked (centered on shortcut position)
            if (num_tabs > 1 and tab.g_tab_close_opacity[tab_idx] > 0.1) {
                const sc_w: f64 = @floatCast(titlebar.titlebarGlyphAdvance(titlebar.tab_shortcut_modifier_cp) + titlebar.titlebarGlyphAdvance(if (tab_idx == 9) @as(u32, '0') else @as(u32, @intCast('1' + tab_idx))));
                const sc_center = cursor + tab_w - 12 - sc_w / 2;
                const close_btn_x = sc_center - tab.TAB_CLOSE_BTN_W / 2;
                if (xpos >= close_btn_x and xpos < close_btn_x + tab.TAB_CLOSE_BTN_W) {
                    tab.g_tab_close_pressed = tab_idx;
                    return;
                }
            }
            AppWindow.switchTab(tab_idx);
            return;
        }
        cursor += tab_w;
    }

    // Check if + button was pressed
    if (show_plus and xpos >= cursor and xpos < cursor + plus_btn_w) {
        plus_btn_pressed = true;
    }
}

fn hitTestTab(xpos: f64) ?usize {
    const win = AppWindow.g_window orelse return null;
    const window_width: f64 = blk: {
        var rect: win32_backend.RECT = undefined;
        _ = win32_backend.GetClientRect(win.hwnd, &rect);
        break :blk @floatFromInt(rect.right);
    };

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    var cursor: f64 = 0;
    for (0..num_tabs) |tab_idx| {
        if (xpos >= cursor and xpos < cursor + tab_w) {
            return tab_idx;
        }
        cursor += tab_w;
    }
    return null;
}

fn hitTestTabCloseButton(xpos: f64, tab_idx: usize) bool {
    const window_width: f64 = blk: {
        const win = AppWindow.g_window orelse break :blk 800.0;
        var rect: win32_backend.RECT = undefined;
        _ = win32_backend.GetClientRect(win.hwnd, &rect);
        break :blk @floatFromInt(rect.right);
    };

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    const show_plus = tab.g_tab_count > 1;
    const num_tabs = tab.g_tab_count;

    const plus_total: f64 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f64 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

    const tab_x = tab_w * @as(f64, @floatFromInt(tab_idx));
    const sc_w: f64 = @floatCast(titlebar.titlebarGlyphAdvance(titlebar.tab_shortcut_modifier_cp) + titlebar.titlebarGlyphAdvance(if (tab_idx == 9) @as(u32, '0') else @as(u32, @intCast('1' + tab_idx))));
    const sc_center = tab_x + tab_w - 12 - sc_w / 2;
    const close_btn_x = sc_center - tab.TAB_CLOSE_BTN_W / 2;
    return xpos >= close_btn_x and xpos < close_btn_x + tab.TAB_CLOSE_BTN_W;
}

fn hitTestPlusButton(xpos: f64) bool {
    const win = AppWindow.g_window orelse return false;
    const window_width: f64 = blk: {
        var rect: win32_backend.RECT = undefined;
        _ = win32_backend.GetClientRect(win.hwnd, &rect);
        break :blk @floatFromInt(rect.right);
    };

    const caption_area_w: f64 = 46 * 3;
    const gap_w: f64 = 42;
    const plus_btn_w: f64 = 46;
    if (tab.g_tab_count <= 1) return false;

    const right_reserved: f64 = caption_area_w + gap_w + plus_btn_w;
    const tab_area_w: f64 = window_width - right_reserved;
    const tab_w: f64 = tab_area_w / @as(f64, @floatFromInt(tab.g_tab_count));
    const plus_x = tab_w * @as(f64, @floatFromInt(tab.g_tab_count));

    return xpos >= plus_x and xpos < plus_x + plus_btn_w;
}

fn applyAiInputScrollbarDrag(chat: *AppWindow.ai_chat.Session, ypos: f64) void {
    const win = AppWindow.g_window orelse return;
    if (AppWindow.ai_chat_renderer.inputScrollbarDragRowAt(
        chat,
        ypos,
        @floatFromInt(win.width),
        @floatFromInt(win.height),
        AppWindow.leftPanelsWidth(),
        AppWindow.rightPanelsWidthForWindow(win.width),
        g_ai_input_scroll_drag_offset,
    )) |drag| {
        _ = chat.setInputScrollRow(drag.row, drag.max_cols, drag.visible_rows);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
    }
}

fn handleMouseMove(ev: win32_backend.MouseMoveEvent) void {
    const xpos: f64 = @floatFromInt(ev.x);
    const ypos: f64 = @floatFromInt(ev.y);
    if (g_sidebar_resize_dragging) {
        applySidebarWidthFromMouse(xpos);
        _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
        return;
    }
    if (g_explorer_resize_dragging) {
        applyExplorerWidthFromMouse(xpos);
        _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
        return;
    }
    if (g_markdown_preview_resize_dragging) {
        applyMarkdownPreviewWidthFromMouse(xpos);
        _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
        return;
    }
    if (g_browser_resize_dragging) {
        applyBrowserWidthFromMouse(xpos);
        _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
        return;
    }
    if (g_ai_input_scroll_dragging) {
        if (g_ai_input_scroll_chat) |chat| applyAiInputScrollbarDrag(chat, ypos);
        return;
    }

    // Handle divider dragging
    if (g_divider_dragging) {
        if (g_divider_drag_handle) |handle| {
            const active_tab = AppWindow.activeTab() orelse return;
            const allocator = AppWindow.g_allocator orelse return;

            // Get spatial info for this split
            var spatial = active_tab.tree.spatial(allocator) catch return;
            defer spatial.deinit(allocator);

            // Get content area dimensions
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const left_panels_w = AppWindow.leftPanelsWidth();
            const right_panels_w = AppWindow.rightPanelsWidthForWindow(fb.width);
            const content_x: f32 = left_panels_w + @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING));
            const content_y: f32 = @floatCast(titlebarHeight());
            const content_w: f32 = @as(f32, @floatFromInt(fb.width)) - left_panels_w - right_panels_w - @as(f32, @floatFromInt(2 * split_layout.DEFAULT_PADDING));
            const content_h: f32 = @as(f32, @floatFromInt(fb.height)) - content_y - @as(f32, @floatFromInt(split_layout.DEFAULT_PADDING));

            const slot = spatial.slots[handle.idx()];
            const layout = g_divider_drag_layout orelse return;

            // Calculate new ratio based on mouse position
            const new_ratio: f16 = switch (layout) {
                .horizontal => blk: {
                    const slot_x = content_x + @as(f32, @floatCast(slot.x)) * content_w;
                    const slot_w = @as(f32, @floatCast(slot.width)) * content_w;
                    const mouse_x: f32 = @floatCast(xpos);
                    // Clamp ratio to 0.1-0.9 to prevent splits from becoming too small
                    break :blk @floatCast(@max(0.1, @min(0.9, (mouse_x - slot_x) / slot_w)));
                },
                .vertical => blk: {
                    const slot_y = content_y + @as(f32, @floatCast(slot.y)) * content_h;
                    const slot_h = @as(f32, @floatCast(slot.height)) * content_h;
                    const mouse_y: f32 = @floatCast(ypos);
                    break :blk @floatCast(@max(0.1, @min(0.9, (mouse_y - slot_y) / slot_h)));
                },
            };

            // Update the ratio in place
            active_tab.tree.resizeInPlace(handle, new_ratio);

            // Force layout recalculation and redraw
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        }
        return;
    }
    if (!g_selecting and !overlays.g_scrollbar_dragging) {
        const over_sidebar_resize = hitTestSidebarResizeHandle(xpos, ypos);
        if (over_sidebar_resize) {
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
            g_sidebar_resize_hover = true;
            return;
        } else if (g_sidebar_resize_hover) {
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_ARROW));
            g_sidebar_resize_hover = false;
        }
        const over_explorer_resize = hitTestFileExplorerResizeHandle(xpos, ypos);
        if (over_explorer_resize) {
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
            g_explorer_resize_hover = true;
            return;
        } else if (g_explorer_resize_hover) {
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_ARROW));
            g_explorer_resize_hover = false;
        }
        const over_preview_resize = hitTestMarkdownPreviewResizeHandle(xpos, ypos);
        if (over_preview_resize) {
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
            g_markdown_preview_resize_hover = true;
            return;
        } else if (g_markdown_preview_resize_hover) {
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_ARROW));
            g_markdown_preview_resize_hover = false;
        }
        const over_browser_resize = hitTestBrowserResizeHandle(xpos, ypos);
        if (over_browser_resize) {
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_SIZEWE));
            g_browser_resize_hover = true;
            return;
        } else if (g_browser_resize_hover) {
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_ARROW));
            g_browser_resize_hover = false;
        }
    }

    if (hitTestBrowserPanel(xpos, ypos)) {
        clearUrlUnderline();
        return;
    }

    // Focus follows mouse: check if mouse is over a different split
    if (AppWindow.g_focus_follows_mouse) {
        updateFocusFromMouse(@intFromFloat(xpos), @intFromFloat(ypos));
    }
    updateUrlUnderlineAtMouse(xpos, ypos);

    // Update scrollbar hover state
    const win = AppWindow.g_window orelse return;
    const fb = win.getFramebufferSize();
    const w_f: f32 = @floatFromInt(fb.width);
    const h_f: f32 = @floatFromInt(fb.height);
    const tb_f: f32 = @floatCast(titlebarHeight());
    const top_pad: f32 = 10 + tb_f;

    const was_hover = overlays.g_scrollbar_hover;
    overlays.g_scrollbar_hover = false;
    if (scrollbarTargetAt(xpos, ypos, w_f, h_f, top_pad)) |target| {
        overlays.g_scrollbar_hover = true;
        if (!was_hover) overlays.scrollbarShowForSurface(target.surface);
    }

    // Handle scrollbar drag
    if (overlays.g_scrollbar_dragging) {
        if (g_scrollbar_drag_surface) |surface| {
            overlays.scrollbarDragForSurface(surface, ypos, g_scrollbar_drag_view_y, g_scrollbar_drag_view_h, g_scrollbar_drag_top_pad);
        } else {
            overlays.scrollbarDrag(ypos, h_f, top_pad);
        }
        return;
    }

    // Check for divider hover and update cursor
    if (!overlays.g_scrollbar_hover and !g_selecting) {
        if (split_layout.hitTestDivider(ev.x, ev.y)) |hit| {
            // Set resize cursor based on layout
            const cursor_id = switch (hit.layout) {
                .horizontal => win32_backend.IDC_SIZEWE, // left-right resize
                .vertical => win32_backend.IDC_SIZENS, // up-down resize
            };
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, cursor_id));
            g_divider_hover = true;
        } else if (g_divider_hover) {
            // Reset to default cursor when leaving divider
            _ = win32_backend.SetCursor(win32_backend.LoadCursor(null, win32_backend.IDC_ARROW));
            g_divider_hover = false;
        }
    }

    // Normal selection handling
    if (!g_selecting) return;

    const surface = AppWindow.activeSurface() orelse return;
    updateDragSelection(surface, xpos, ypos);
}

fn appendBytes(out: *[512]u8, len: *usize, bytes: []const u8) bool {
    if (len.* + bytes.len > out.len) return false;
    @memcpy(out[len.* .. len.* + bytes.len], bytes);
    len.* += bytes.len;
    return true;
}

fn appendByte(out: *[512]u8, len: *usize, byte: u8) bool {
    if (len.* >= out.len) return false;
    out[len.*] = byte;
    len.* += 1;
    return true;
}

fn appendFmt(out: *[512]u8, len: *usize, comptime fmt: []const u8, args: anytype) bool {
    const written = std.fmt.bufPrint(out[len.*..], fmt, args) catch return false;
    len.* += written.len;
    return true;
}

fn mouseWheelUnits(delta: i16) usize {
    const notches = @abs(@as(i32, delta));
    return @max(@as(usize, 1), @as(usize, @intCast((notches * 3 + 119) / 120)));
}

fn appendMouseWheelReport(surface: *Surface, ev: win32_backend.MouseWheelEvent, out: *[512]u8, len: *usize) bool {
    if (surface.terminal.flags.mouse_event == .none or surface.terminal.flags.mouse_event == .x10) return false;

    var button_code: u8 = if (ev.delta > 0) 64 else 65; // xterm wheel up/down buttons 4/5
    if (ev.shift) button_code += 4;
    if (ev.alt) button_code += 8;
    if (ev.ctrl) button_code += 16;

    const cell = mouseToSurfaceCell(surface, @floatFromInt(ev.xpos), @floatFromInt(ev.ypos));
    const x = cell.col + 1;
    const y = cell.row + 1;

    switch (surface.terminal.flags.mouse_format) {
        .sgr => return appendFmt(out, len, "\x1b[<{d};{d};{d}M", .{ button_code, x, y }),
        .urxvt => return appendFmt(out, len, "\x1b[{d};{d};{d}M", .{ 32 + @as(u16, button_code), x, y }),
        .sgr_pixels => {
            const pixel = mouseToSurfacePixel(surface, ev.xpos, ev.ypos);
            return appendFmt(out, len, "\x1b[<{d};{d};{d}M", .{ button_code, @max(0, pixel.x), @max(0, pixel.y) });
        },
        .x10, .utf8 => {
            if (cell.col > 222 or cell.row > 222) return false;
            if (!appendBytes(out, len, "\x1b[M")) return false;
            if (!appendByte(out, len, 32 + button_code)) return false;
            if (!appendByte(out, len, 32 + @as(u8, @intCast(cell.col)) + 1)) return false;
            if (!appendByte(out, len, 32 + @as(u8, @intCast(cell.row)) + 1)) return false;
            return true;
        },
    }
}

fn appendAlternateScrollKeys(surface: *Surface, ev: win32_backend.MouseWheelEvent, out: *[512]u8, len: *usize) bool {
    if (surface.terminal.screens.active_key != .alternate) return false;
    if (surface.terminal.flags.mouse_event != .none) return false;
    if (!surface.terminal.modes.get(.mouse_alternate_scroll)) return false;

    const seq = if (surface.terminal.modes.get(.cursor_keys))
        if (ev.delta > 0) "\x1bOA" else "\x1bOB"
    else if (ev.delta > 0) "\x1b[A" else "\x1b[B";

    for (0..mouseWheelUnits(ev.delta)) |_| {
        if (!appendBytes(out, len, seq)) return false;
    }
    return true;
}

fn handleMouseWheel(ev: win32_backend.MouseWheelEvent) void {
    overlays.startupShortcutsDismiss();
    if (tab.g_sidebar_visible and ev.xpos >= 0 and ev.xpos < @as(i32, @intFromFloat(titlebar.sidebarWidth()))) return;
    if (hitTestBrowserPanel(@floatFromInt(ev.xpos), @floatFromInt(ev.ypos))) return;
    if (markdown_preview_panel.g_visible) {
        const win = AppWindow.g_window orelse return;
        const panel_x = @as(i32, @intFromFloat(@as(f32, @floatFromInt(win.width)) - markdown_preview_panel.width()));
        const panel_right = win.width;
        if (ev.xpos >= panel_x and ev.xpos < panel_right) {
            const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * 72.0 / 120.0;
            markdown_preview_panel.scrollBy(delta);
            AppWindow.g_force_rebuild = true;
            return;
        }
    }
    // Scroll in file explorer
    if (file_explorer.g_visible) {
        const panel_x = @as(i32, @intFromFloat(titlebar.sidebarWidth()));
        const panel_right = @as(i32, @intFromFloat(titlebar.sidebarWidth() + file_explorer.width()));
        if (ev.xpos >= panel_x and ev.xpos < panel_right) {
            const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * file_explorer.rowHeight() * 3 / 120.0;
            file_explorer.scrollBy(delta);
            return;
        }
    }
    if (AppWindow.activeAiChat()) |chat| {
        const win = AppWindow.g_window orelse return;
        const left = @as(i32, @intFromFloat(AppWindow.leftPanelsWidth()));
        const right = win.width - @as(i32, @intFromFloat(AppWindow.rightPanelsWidthForWindow(win.width)));
        if (ev.xpos >= left and ev.xpos < right) {
            if (AppWindow.ai_chat_renderer.inputFieldMetricsAt(
                chat,
                @floatFromInt(ev.xpos),
                @floatFromInt(ev.ypos),
                @floatFromInt(win.width),
                @floatFromInt(win.height),
                AppWindow.leftPanelsWidth(),
                AppWindow.rightPanelsWidthForWindow(win.width),
            )) |metrics| {
                const units: i32 = @intCast(mouseWheelUnits(ev.delta));
                const rows = if (ev.delta > 0) -units else units;
                _ = chat.scrollInputRows(rows, metrics.max_cols, metrics.visible_rows);
                AppWindow.g_force_rebuild = true;
                AppWindow.g_cells_valid = false;
                return;
            }
            const delta: f32 = -@as(f32, @floatFromInt(ev.delta)) * 72.0 / 120.0;
            chat.scrollBy(delta);
            AppWindow.g_force_rebuild = true;
            return;
        }
    }
    // Scroll the surface under the mouse cursor (like Ghostty), not the focused surface.
    // Fall back to focused surface if mouse is not over any split.
    const surface = split_layout.surfaceAtPoint(ev.xpos, ev.ypos) orelse AppWindow.activeSurface() orelse return;

    var terminal_input_buf: [512]u8 = undefined;
    var terminal_input_len: usize = 0;
    var sent_to_terminal = false;

    surface.render_state.mutex.lock();
    if (surface.terminal.flags.mouse_event != .none) {
        for (0..mouseWheelUnits(ev.delta)) |_| {
            if (!appendMouseWheelReport(surface, ev, &terminal_input_buf, &terminal_input_len)) break;
        }
        sent_to_terminal = terminal_input_len > 0;
    } else if (appendAlternateScrollKeys(surface, ev, &terminal_input_buf, &terminal_input_len)) {
        sent_to_terminal = true;
    } else {
        // WHEEL_DELTA is 120 per notch. Convert to lines (3 lines per notch, like GLFW).
        const notches = @as(f64, @floatFromInt(ev.delta)) / 120.0;
        const delta: isize = @intFromFloat(-notches * 3);
        surface.terminal.scrollViewport(.{ .delta = delta });

        // Show scrollbar for the scrolled surface
        surface.scrollbar_opacity = 1.0;
        surface.scrollbar_show_time = std.time.milliTimestamp();
    }
    surface.render_state.mutex.unlock();

    if (g_selecting and !sent_to_terminal) {
        updateDragSelection(surface, @floatFromInt(ev.xpos), @floatFromInt(ev.ypos));
    }

    if (sent_to_terminal) {
        writeToPty(surface, terminal_input_buf[0..terminal_input_len]);
    }
}

fn updateDragSelection(surface: *Surface, xpos: f64, ypos: f64) void {
    const selection = &surface.selection;
    const cell_pos = mouseToSurfaceCell(surface, xpos, ypos);
    const abs_row = viewportOffsetForSurface(surface) + cell_pos.row;
    selection.has_anchor = true;
    selection.end_col = cell_pos.col;
    selection.end_row = abs_row;

    const threshold = font.cell_width * 0.6;
    const grid_left = blk: {
        if (splitRectForSurface(surface)) |rect| {
            const pad = surface.getPadding();
            break :blk @as(f64, @floatFromInt(rect.x)) + @as(f64, @floatFromInt(pad.left));
        }
        break :blk @as(f64, @floatCast(titlebar.sidebarWidth())) + 10;
    };
    const click_cell_x = g_click_x - grid_left - @as(f64, @floatFromInt(selection.start_col)) * @as(f64, @floatCast(font.cell_width));
    const drag_cell_x = xpos - grid_left - @as(f64, @floatFromInt(cell_pos.col)) * @as(f64, @floatCast(font.cell_width));

    const same_cell = (selection.start_col == cell_pos.col and selection.start_row == abs_row);
    if (same_cell) {
        const moved_right = drag_cell_x >= threshold and click_cell_x < threshold;
        const moved_left = drag_cell_x < threshold and click_cell_x >= threshold;
        selection.active = moved_right or moved_left;
    } else {
        selection.active = true;
    }

    markSelectionChanged();
}

// --- Clipboard (Win32 native) ---

fn selectionSurfaceForClipboard() ?*Surface {
    if (AppWindow.activeTab()) |tb| {
        var selected_surface: ?*Surface = null;
        var it = tb.tree.iterator();
        while (it.next()) |entry| {
            if (!entry.surface.selection.active) continue;
            if (entry.handle == tb.focused) return entry.surface;
            if (selected_surface == null) selected_surface = entry.surface;
        }
        if (selected_surface) |surface| return surface;
    }
    return AppWindow.activeSurface();
}

fn activeTerminalSelectionExists() bool {
    const surface = selectionSurfaceForClipboard() orelse return false;
    return surface.selection.active;
}

fn handleConfiguredRightClick() void {
    switch (AppWindow.g_right_click_action) {
        .ignore => {},
        .copy => copySelectionToClipboard(),
        .paste => pasteFromClipboard(),
        .copy_or_paste => {
            if (activeTerminalSelectionExists()) {
                copySelectionToClipboard();
            } else {
                pasteFromClipboard();
            }
        },
    }
}

fn copyTextToClipboard(text: []const u8) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const win = AppWindow.g_window orelse return false;
    if (text.len == 0) return false;

    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch return false;
    defer allocator.free(utf16);

    // Win32 clipboard takes ownership of the moveable global handle after SetClipboardData.
    if (win32_backend.OpenClipboard(win.hwnd) == 0) return false;
    defer _ = win32_backend.CloseClipboard();
    _ = win32_backend.EmptyClipboard();

    const size = (utf16.len + 1) * @sizeOf(u16);
    const hmem = win32_backend.GlobalAlloc(0x0002, size) orelse return false; // GMEM_MOVEABLE
    const ptr = win32_backend.GlobalLock(hmem) orelse return false;
    const dest: [*]u16 = @ptrCast(@alignCast(ptr));
    @memcpy(dest[0..utf16.len], utf16);
    dest[utf16.len] = 0;
    _ = win32_backend.GlobalUnlock(hmem);

    return win32_backend.SetClipboardData(CF_UNICODETEXT, hmem) != null;
}

fn copyAiChatToClipboard(chat: *AppWindow.ai_chat.Session) void {
    const allocator = AppWindow.g_allocator orelse return;
    const text = chat.allocClipboardText(allocator) catch return;
    defer allocator.free(text);
    if (text.len == 0) return;
    if (copyTextToClipboard(text)) {
        overlays.showCopyToast(text.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Copied {} AI chat bytes to clipboard\n", .{text.len});
    }
}

fn copyAiChatMessageToClipboard(chat: *AppWindow.ai_chat.Session, message_index: usize) void {
    const allocator = AppWindow.g_allocator orelse return;
    const text = chat.allocMessageClipboardText(allocator, message_index) catch return;
    defer allocator.free(text);
    if (text.len == 0) return;
    if (copyTextToClipboard(text)) {
        overlays.showCopyToast(text.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Copied {} AI chat message bytes to clipboard\n", .{text.len});
    }
}

pub fn copySelectionToClipboard() void {
    const surface = selectionSurfaceForClipboard() orelse return;
    const allocator = AppWindow.g_allocator orelse return;

    if (!surface.selection.active) return;

    var start_row = surface.selection.start_row;
    var start_col = surface.selection.start_col;
    var end_row = surface.selection.end_row;
    var end_col = surface.selection.end_col;

    if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
        std.mem.swap(usize, &start_row, &end_row);
        std.mem.swap(usize, &start_col, &end_col);
    }

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);

    // Lock while reading terminal cells
    surface.render_state.mutex.lock();
    const screen = surface.terminal.screens.active;
    const grid_cols = @max(@as(usize, 1), @as(usize, @intCast(surface.size.grid.cols)));
    var row: usize = start_row;
    while (row <= end_row) : (row += 1) {
        const row_start_col = if (row == start_row) start_col else 0;
        var row_end_col = if (row == end_row) end_col else grid_cols - 1;
        if (row_start_col >= grid_cols) continue;
        row_end_col = @min(row_end_col, grid_cols - 1);
        if (row_start_col > row_end_col) continue;

        const row_text_start = text.items.len;
        var col: usize = row_start_col;
        while (col <= row_end_col) : (col += 1) {
            const cell_data = screen.pages.getCell(.{ .screen = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse continue;

            // Skip spacer cells for wide characters — the actual codepoint
            // lives in the head cell; spacers are layout-only.
            const wide_val: u2 = @intFromEnum(cell_data.cell.wide);
            if (wide_val == 2 or wide_val == 3) continue; // spacer_tail / spacer_head

            const cp = cell_data.cell.codepoint();
            if (cp == 0 or cp == ' ') {
                text.append(allocator, ' ') catch continue;
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
                text.appendSlice(allocator, buf[0..len]) catch continue;

                // Append grapheme cluster continuation codepoints (emoji ZWJ sequences, etc.)
                if (cell_data.cell.hasGrapheme()) {
                    const page = &cell_data.node.data;
                    if (page.lookupGrapheme(cell_data.cell)) |extra_cps| {
                        for (extra_cps) |ecp| {
                            const elen = std.unicode.utf8Encode(@intCast(ecp), &buf) catch continue;
                            text.appendSlice(allocator, buf[0..elen]) catch {};
                        }
                    }
                }
            }
        }
        text.items.len = row_text_start + selection_unit.trimTrailingClipboardSpaces(text.items[row_text_start..]).len;
        if (row < end_row) {
            text.appendSlice(allocator, "\r\n") catch {};
        }
    }
    surface.render_state.mutex.unlock();

    if (text.items.len == 0) return;

    if (copyTextToClipboard(text.items)) {
        overlays.showCopyToast(text.items.len);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        std.debug.print("Copied {} bytes to clipboard\n", .{text.items.len});
    }
}

pub fn pasteFromClipboard() void {
    const surface = AppWindow.activeSurface() orelse return;
    const win = AppWindow.g_window orelse return;
    const allocator = AppWindow.g_allocator orelse return;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
    defer {
        _ = win32_backend.CloseClipboard();
    }

    if (win32_backend.GetClipboardData(CF_UNICODETEXT)) |hmem| {
        const text = readClipboardUnicodeText(allocator, hmem) orelse return;
        defer allocator.free(text);
        if (text.len > 0) {
            std.debug.print("Pasting {} UTF-8 bytes from clipboard\n", .{text.len});
            writePasteToPty(surface, allocator, text);
        }
        return;
    }

    if (win32_backend.GetClipboardData(CF_TEXT)) |hmem| {
        const text = readClipboardAnsiText(allocator, hmem) orelse return;
        defer allocator.free(text);
        if (text.len > 0) {
            std.debug.print("Pasting {} ANSI bytes from clipboard\n", .{text.len});
            writePasteToPty(surface, allocator, text);
        }
        return;
    }
}

fn pasteClipboardIntoBrowserUrlBar() bool {
    const win = AppWindow.g_window orelse return false;
    const allocator = AppWindow.g_allocator orelse return false;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return false;
    defer {
        _ = win32_backend.CloseClipboard();
    }

    if (win32_backend.GetClipboardData(CF_UNICODETEXT)) |hmem| {
        const text = readClipboardUnicodeText(allocator, hmem) orelse return false;
        defer allocator.free(text);
        browser_panel.appendUrlBarText(text);
        return text.len > 0;
    }

    if (win32_backend.GetClipboardData(CF_TEXT)) |hmem| {
        const text = readClipboardAnsiText(allocator, hmem) orelse return false;
        defer allocator.free(text);
        browser_panel.appendUrlBarText(text);
        return text.len > 0;
    }

    return false;
}

fn pasteClipboardIntoSessionLauncher() bool {
    const win = AppWindow.g_window orelse return false;
    const allocator = AppWindow.g_allocator orelse return false;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return false;
    defer {
        _ = win32_backend.CloseClipboard();
    }

    if (win32_backend.GetClipboardData(CF_UNICODETEXT)) |hmem| {
        const text = readClipboardUnicodeText(allocator, hmem) orelse return false;
        defer allocator.free(text);
        return overlays.sessionLauncherPasteText(text);
    }

    if (win32_backend.GetClipboardData(CF_TEXT)) |hmem| {
        const text = readClipboardAnsiText(allocator, hmem) orelse return false;
        defer allocator.free(text);
        return overlays.sessionLauncherPasteText(text);
    }

    return false;
}

fn pasteFromClipboardIntoAiChat(chat: *AppWindow.ai_chat.Session) void {
    const win = AppWindow.g_window orelse return;
    const allocator = AppWindow.g_allocator orelse return;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
    defer {
        _ = win32_backend.CloseClipboard();
    }

    if (win32_backend.GetClipboardData(CF_UNICODETEXT)) |hmem| {
        const text = readClipboardUnicodeText(allocator, hmem) orelse return;
        defer allocator.free(text);
        chat.appendInputText(text);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }

    if (win32_backend.GetClipboardData(CF_TEXT)) |hmem| {
        const text = readClipboardAnsiText(allocator, hmem) orelse return;
        defer allocator.free(text);
        chat.appendInputText(text);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }
}

fn toggleAiAgentPermission() void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);

    const next = switch (cfg.@"ai-agent-permission") {
        .confirm => "full",
        .full => "confirm",
    };
    Config.setConfigValue(allocator, "ai-agent-permission", next) catch return;
    AppWindow.reloadConfigImmediate(allocator);
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

pub fn pasteImageFromClipboard() void {
    const surface = AppWindow.activeSurface() orelse return;
    const win = AppWindow.g_window orelse return;
    const allocator = AppWindow.g_allocator orelse return;

    if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
    var clipboard_open = true;
    defer if (clipboard_open) {
        _ = win32_backend.CloseClipboard();
    };

    const image_path = saveClipboardImageToTemp(allocator) orelse return;
    defer allocator.free(image_path);
    _ = win32_backend.CloseClipboard();
    clipboard_open = false;

    _ = pasteSavedClipboardImage(surface, allocator, image_path);
}

pub fn writeTextToActivePty(text: []const u8) void {
    const surface = AppWindow.activeSurface() orelse return;
    writeToPty(surface, text);
}

pub fn writeTextToSurfacePty(surface: *Surface, text: []const u8) void {
    writeToPty(surface, text);
}

// --- Maximize toggle (Win32 native) ---

pub fn toggleMaximize() void {
    const win = AppWindow.g_window orelse return;

    if (is_fullscreen or win.is_fullscreen) {
        toggleFullscreen();
        return;
    }

    if (win32_backend.IsZoomed(win.hwnd) != 0) {
        _ = win32_backend.ShowWindow(win.hwnd, win32_backend.SW_RESTORE);
    } else {
        _ = win32_backend.ShowWindow(win.hwnd, win32_backend.SW_MAXIMIZE);
    }
}

// --- Fullscreen toggle (Win32 native) ---

pub fn toggleFullscreen() void {
    const win = AppWindow.g_window orelse return;

    if (is_fullscreen) {
        // Restore windowed mode
        _ = win32_backend.SetWindowLongW(win.hwnd, -16, @bitCast(saved_style)); // GWL_STYLE
        _ = win32_backend.SetWindowPos(
            win.hwnd,
            null,
            saved_rect.left,
            saved_rect.top,
            saved_rect.right - saved_rect.left,
            saved_rect.bottom - saved_rect.top,
            0x0020 | 0x0040, // SWP_FRAMECHANGED | SWP_SHOWWINDOW
        );
        is_fullscreen = false;
        if (AppWindow.g_window) |w| w.is_fullscreen = false;
        std.debug.print("Exited fullscreen\n", .{});
    } else {
        // Save current state
        _ = win32_backend.GetWindowRect(win.hwnd, &saved_rect);
        saved_style = @bitCast(win32_backend.GetWindowLongW(win.hwnd, -16));

        // Set borderless style
        const new_style = saved_style & ~@as(u32, 0x00CF0000); // remove WS_OVERLAPPEDWINDOW
        _ = win32_backend.SetWindowLongW(win.hwnd, -16, @bitCast(new_style));

        // Get monitor info for the monitor containing this window
        const monitor = win32_backend.MonitorFromWindow(win.hwnd, 0x00000002) orelse return; // MONITOR_DEFAULTTONEAREST
        var mi = win32_backend.MONITORINFO{ .cbSize = @sizeOf(win32_backend.MONITORINFO) };
        if (win32_backend.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = win32_backend.SetWindowPos(
                win.hwnd,
                null,
                mi.rcMonitor.left,
                mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                0x0020 | 0x0040, // SWP_FRAMECHANGED | SWP_SHOWWINDOW
            );
        }
        is_fullscreen = true;
        if (AppWindow.g_window) |w| w.is_fullscreen = true;
        std.debug.print("Entered fullscreen\n", .{});
    }
}
