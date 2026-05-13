//! State and WebView2 interop for the right-side browser panel.

const std = @import("std");
const win32 = @import("apprt/win32.zig");
const Surface = @import("Surface.zig");
const browser_url = @import("browser_url.zig");

pub const DEFAULT_WIDTH: f32 = 720;
pub const MIN_WIDTH: f32 = 360;
pub const MAX_WIDTH: f32 = 1280;
pub const MIN_CONTENT_WIDTH: f32 = 320;
pub const RESIZE_HIT_WIDTH: f32 = 12;
pub const URL_BAR_HEIGHT: f32 = 42;
pub const URL_BAR_MARGIN: f32 = 8;
pub const DEFAULT_URL = "http://localhost:3000";

const MAX_URL_BYTES = 2048;
const MAX_SSH_DEST_BYTES = 280;
const MAX_TUNNEL_SPEC_BYTES = 96;
const MAX_LOCAL_HOST_BYTES = 32;
const TUNNEL_READY_TIMEOUT_MS = 8000;
const TUNNEL_READY_POLL_NS = 50 * std.time.ns_per_ms;
const BrowserHandle = opaque {};

extern fn phantty_webview2_create(
    parent: win32.HWND,
    left: c_int,
    top: c_int,
    right: c_int,
    bottom: c_int,
    initial_url: [*:0]const u16,
) callconv(.c) ?*BrowserHandle;
extern fn phantty_webview2_set_bounds(browser: *BrowserHandle, left: c_int, top: c_int, right: c_int, bottom: c_int) callconv(.c) void;
extern fn phantty_webview2_set_visible(browser: *BrowserHandle, visible: c_int) callconv(.c) void;
extern fn phantty_webview2_focus(browser: *BrowserHandle) callconv(.c) void;
extern fn phantty_webview2_navigate(browser: *BrowserHandle, url: [*:0]const u16) callconv(.c) void;
extern fn phantty_webview2_is_ready(browser: *BrowserHandle) callconv(.c) c_int;
extern fn phantty_webview2_last_error(browser: *BrowserHandle) callconv(.c) win32.HRESULT;
extern fn phantty_webview2_destroy(browser: *BrowserHandle) callconv(.c) void;

pub const Bounds = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub fn urlBarBounds(bounds: Bounds) ?Bounds {
    const grip: i32 = @intFromFloat(@round(RESIZE_HIT_WIDTH));
    const left = @min(bounds.right, bounds.left + grip);
    const bottom = @min(bounds.bottom, bounds.top + @as(i32, @intFromFloat(@round(URL_BAR_HEIGHT))));
    if (bounds.right <= left or bottom <= bounds.top) return null;
    return .{
        .left = left,
        .top = bounds.top,
        .right = bounds.right,
        .bottom = bottom,
    };
}

pub fn contentBounds(bounds: Bounds) ?Bounds {
    const grip: i32 = @intFromFloat(@round(RESIZE_HIT_WIDTH));
    const left = @min(bounds.right, bounds.left + grip);
    const top = @min(bounds.bottom, bounds.top + @as(i32, @intFromFloat(@round(URL_BAR_HEIGHT))));
    if (bounds.right <= left or bounds.bottom <= top) return null;
    return .{
        .left = left,
        .top = top,
        .right = bounds.right,
        .bottom = bounds.bottom,
    };
}

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;
pub threadlocal var g_last_error: win32.HRESULT = 0;
threadlocal var g_browser: ?*BrowserHandle = null;
threadlocal var g_url_buf: [MAX_URL_BYTES]u8 = undefined;
threadlocal var g_url_len: usize = 0;
threadlocal var g_url_bar_focused: bool = false;
threadlocal var g_url_edit_buf: [MAX_URL_BYTES]u8 = undefined;
threadlocal var g_url_edit_len: usize = 0;
threadlocal var g_url_edit_select_all: bool = false;
threadlocal var g_tunnel: ?SshTunnel = null;

const SshTunnel = struct {
    child: std.process.Child,
    local_port: u16,
    remote_port: u16,
    local_host_buf: [MAX_LOCAL_HOST_BYTES]u8 = undefined,
    local_host_len: usize = 0,
    remote_host_buf: [MAX_LOCAL_HOST_BYTES]u8 = undefined,
    remote_host_len: usize = 0,
    user_buf: [128]u8 = undefined,
    user_len: usize = 0,
    host_buf: [128]u8 = undefined,
    host_len: usize = 0,
    ssh_port_buf: [16]u8 = undefined,
    ssh_port_len: usize = 0,

    fn init(child: std.process.Child, conn: *const Surface.SshConnection, remote_port: u16, local_port: u16, local_host: []const u8, remote_host: []const u8) SshTunnel {
        var tunnel: SshTunnel = .{
            .child = child,
            .local_port = local_port,
            .remote_port = remote_port,
        };
        tunnel.local_host_len = copyBounded(tunnel.local_host_buf[0..], local_host);
        tunnel.remote_host_len = copyBounded(tunnel.remote_host_buf[0..], remote_host);
        tunnel.user_len = copyBounded(tunnel.user_buf[0..], conn.user());
        tunnel.host_len = copyBounded(tunnel.host_buf[0..], conn.host());
        tunnel.ssh_port_len = copyBounded(tunnel.ssh_port_buf[0..], conn.port());
        return tunnel;
    }

    fn matches(self: *const SshTunnel, conn: *const Surface.SshConnection, remote_port: u16, local_host: []const u8, remote_host: []const u8) bool {
        return self.remote_port == remote_port and
            std.mem.eql(u8, self.localHost(), local_host) and
            std.mem.eql(u8, self.remoteHost(), remote_host) and
            std.mem.eql(u8, self.user(), conn.user()) and
            std.mem.eql(u8, self.host(), conn.host()) and
            std.mem.eql(u8, self.sshPort(), conn.port());
    }

    fn localHost(self: *const SshTunnel) []const u8 {
        return self.local_host_buf[0..self.local_host_len];
    }

    fn remoteHost(self: *const SshTunnel) []const u8 {
        return self.remote_host_buf[0..self.remote_host_len];
    }

    fn user(self: *const SshTunnel) []const u8 {
        return self.user_buf[0..self.user_len];
    }

    fn host(self: *const SshTunnel) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    fn sshPort(self: *const SshTunnel) []const u8 {
        return self.ssh_port_buf[0..self.ssh_port_len];
    }
};

pub fn width() f32 {
    return if (g_visible) g_width else 0;
}

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

pub fn setWidth(w: f32, window_width: f32) bool {
    const next = @max(MIN_WIDTH, @min(maxWidthForWindow(window_width), w));
    if (next == g_width) return false;
    g_width = next;
    return true;
}

pub fn panelWidthForWindow(window_width: i32, left_offset: f32, right_offset: f32) f32 {
    if (!g_visible) return 0;
    const win_w: f32 = @floatFromInt(window_width);
    const max_width = @max(MIN_WIDTH, @min(MAX_WIDTH, win_w - left_offset - right_offset - MIN_CONTENT_WIDTH));
    return @max(MIN_WIDTH, @min(g_width, max_width));
}

pub fn open(parent: ?win32.HWND, url: []const u8) void {
    setUrl(url);
    g_visible = true;

    if (g_browser) |browser| {
        navigateCurrentUrl(browser);
        phantty_webview2_set_visible(browser, 1);
        focus();
        return;
    }

    _ = parent;
}

pub fn openForSurface(allocator: std.mem.Allocator, parent: ?win32.HWND, url: []const u8, surface: ?*const Surface) bool {
    var target = url;
    var tunneled_url: ?[]u8 = null;
    defer if (tunneled_url) |owned| allocator.free(owned);

    if (sshLoopbackUrl(surface, target)) |request| {
        const local_port = ensureSshTunnel(allocator, &request.conn, request.parsed.port, browser_url.localTunnelHost(request.parsed.host), browser_url.remoteTunnelHost(request.parsed.host)) orelse return false;
        tunneled_url = browser_url.buildLocalTunnelUrl(allocator, request.parsed, local_port) orelse return false;
        target = tunneled_url.?;
    } else {
        stopTunnel();
        if (browser_url.parseHttpUrl(target)) |parsed| {
            if (browser_url.isUnspecifiedHost(parsed.host)) {
                tunneled_url = browser_url.buildLocalTunnelUrl(allocator, parsed, parsed.port) orelse return false;
                target = tunneled_url.?;
            }
        }
    }

    open(parent, target);
    return true;
}

pub fn toggle(parent: ?win32.HWND) void {
    if (g_visible) {
        close();
    } else {
        open(parent, DEFAULT_URL);
    }
}

pub fn toggleForSurface(allocator: std.mem.Allocator, parent: ?win32.HWND, surface: ?*const Surface) bool {
    if (g_visible) {
        close();
        return true;
    }
    return openForSurface(allocator, parent, DEFAULT_URL, surface);
}

pub fn close() void {
    g_visible = false;
    g_url_bar_focused = false;
    g_url_edit_select_all = false;
    stopTunnel();
    destroyBrowser();
}

pub fn focus() void {
    if (g_browser) |browser| {
        phantty_webview2_focus(browser);
    }
}

pub fn isReady() bool {
    const browser = g_browser orelse return false;
    return phantty_webview2_is_ready(browser) != 0;
}

pub fn lastError() win32.HRESULT {
    if (g_browser) |browser| {
        g_last_error = phantty_webview2_last_error(browser);
    }
    return g_last_error;
}

pub fn sync(parent: win32.HWND, window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) void {
    if (window_width <= 0 or window_height <= 0) return;

    if (!g_visible) {
        if (g_browser) |browser| phantty_webview2_set_visible(browser, 0);
        return;
    }

    const bounds = boundsForWindow(window_width, window_height, titlebar_height, left_offset, right_offset);
    if (bounds.right <= bounds.left or bounds.bottom <= bounds.top) return;

    const webview_bounds = contentBounds(bounds) orelse return;

    if (g_browser == null) {
        var wide_buf: [MAX_URL_BYTES]u16 = undefined;
        const wide_url = urlToWide(currentUrl(), &wide_buf) orelse return;
        g_browser = phantty_webview2_create(parent, webview_bounds.left, webview_bounds.top, webview_bounds.right, webview_bounds.bottom, wide_url);
        if (g_browser) |browser| {
            g_last_error = phantty_webview2_last_error(browser);
        }
    }

    if (g_browser) |browser| {
        phantty_webview2_set_bounds(browser, webview_bounds.left, webview_bounds.top, webview_bounds.right, webview_bounds.bottom);
        phantty_webview2_set_visible(browser, 1);
        g_last_error = phantty_webview2_last_error(browser);
    }
}

pub fn deinit() void {
    destroyBrowser();
    stopTunnel();
    g_visible = false;
    g_url_bar_focused = false;
    g_url_edit_select_all = false;
}

fn destroyBrowser() void {
    if (g_browser) |browser| {
        phantty_webview2_destroy(browser);
        g_browser = null;
    }
}

fn setUrl(url: []const u8) void {
    const n = @min(url.len, g_url_buf.len - 1);
    @memcpy(g_url_buf[0..n], url[0..n]);
    g_url_len = n;
}

pub fn currentUrl() []const u8 {
    if (g_url_len == 0) return DEFAULT_URL;
    return g_url_buf[0..g_url_len];
}

pub fn urlBarFocused() bool {
    return g_url_bar_focused;
}

pub fn urlBarText() []const u8 {
    if (g_url_bar_focused) return g_url_edit_buf[0..g_url_edit_len];
    return currentUrl();
}

pub fn urlBarSelectAll() bool {
    return g_url_bar_focused and g_url_edit_select_all and g_url_edit_len > 0;
}

pub fn focusUrlBar() void {
    g_url_bar_focused = true;
    g_url_edit_len = copyBounded(g_url_edit_buf[0 .. g_url_edit_buf.len - 1], currentUrl());
    g_url_edit_select_all = g_url_edit_len > 0;
}

pub fn blurUrlBar() void {
    g_url_bar_focused = false;
    g_url_edit_select_all = false;
}

pub fn insertUrlBarChar(codepoint: u21) void {
    if (!g_url_bar_focused) return;
    if (codepoint <= 0x20 or codepoint == 0x7F or codepoint > 0x7E) return;
    replaceSelectedUrlBeforeEdit();
    if (g_url_edit_len >= g_url_edit_buf.len - 1) return;
    g_url_edit_buf[g_url_edit_len] = @intCast(codepoint);
    g_url_edit_len += 1;
}

pub fn appendUrlBarText(text: []const u8) void {
    for (text) |ch| {
        if (ch <= 0x20 or ch == 0x7F) continue;
        replaceSelectedUrlBeforeEdit();
        if (g_url_edit_len >= g_url_edit_buf.len - 1) return;
        g_url_edit_buf[g_url_edit_len] = ch;
        g_url_edit_len += 1;
    }
}

pub fn backspaceUrlBar() void {
    if (!g_url_bar_focused or g_url_edit_len == 0) return;
    if (g_url_edit_select_all) {
        g_url_edit_len = 0;
        g_url_edit_select_all = false;
        return;
    }
    g_url_edit_len -= 1;
}

pub fn clearUrlBar() void {
    if (!g_url_bar_focused) return;
    g_url_edit_len = 0;
    g_url_edit_select_all = false;
}

pub fn submitUrlBar(allocator: std.mem.Allocator, parent: ?win32.HWND, surface: ?*const Surface) bool {
    const target = normalizeUrlInput(allocator, g_url_edit_buf[0..g_url_edit_len]) orelse return false;
    defer allocator.free(target);

    if (!openForSurface(allocator, parent, target, surface)) return false;
    g_url_bar_focused = false;
    return true;
}

pub fn selectAllUrlBar() void {
    if (!g_url_bar_focused) return;
    g_url_edit_select_all = g_url_edit_len > 0;
}

fn replaceSelectedUrlBeforeEdit() void {
    if (!g_url_edit_select_all) return;
    g_url_edit_len = 0;
    g_url_edit_select_all = false;
}

fn navigateCurrentUrl(browser: *BrowserHandle) void {
    var wide_buf: [MAX_URL_BYTES]u16 = undefined;
    const wide_url = urlToWide(currentUrl(), &wide_buf) orelse return;
    phantty_webview2_navigate(browser, wide_url);
    g_last_error = phantty_webview2_last_error(browser);
}

fn urlToWide(url: []const u8, out: *[MAX_URL_BYTES]u16) ?[*:0]const u16 {
    if (url.len >= out.len) return null;
    @memset(out, 0);
    const len = std.unicode.utf8ToUtf16Le(out[0 .. out.len - 1], url) catch return null;
    out[len] = 0;
    return out[0..len :0].ptr;
}

pub fn boundsForWindow(window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) Bounds {
    const win_w: f32 = @floatFromInt(window_width);
    const win_h: f32 = @floatFromInt(window_height);
    const panel_w = panelWidthForWindow(window_width, left_offset, right_offset);
    const right = @max(0, win_w - right_offset);
    const left = @max(left_offset, right - panel_w);
    const top = @max(0, titlebar_height);
    const bottom = @max(top, win_h);

    return .{
        .left = @intFromFloat(@round(left)),
        .top = @intFromFloat(@round(top)),
        .right = @intFromFloat(@round(right)),
        .bottom = @intFromFloat(@round(bottom)),
    };
}

fn normalizeUrlInput(allocator: std.mem.Allocator, input: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOf(u8, trimmed, "://") != null) return allocator.dupe(u8, trimmed) catch null;

    const scheme = if (defaultsToHttp(trimmed)) "http" else "https";
    return std.fmt.allocPrint(allocator, "{s}://{s}", .{ scheme, trimmed }) catch null;
}

fn defaultsToHttp(input: []const u8) bool {
    return startsWithIgnoreCase(input, "localhost") or
        startsWithIgnoreCase(input, "127.") or
        startsWithIgnoreCase(input, "0.0.0.0") or
        startsWithIgnoreCase(input, "[::1]") or
        std.mem.indexOfScalar(u8, input, ':') != null;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

const SshLoopbackUrl = struct {
    conn: Surface.SshConnection,
    parsed: browser_url.HttpUrl,
};

fn sshLoopbackUrl(surface: ?*const Surface, url: []const u8) ?SshLoopbackUrl {
    const s = surface orelse return null;
    if (s.launch_kind != .ssh) return null;
    const conn = s.ssh_connection orelse return null;
    const parsed = browser_url.parseHttpUrl(url) orelse return null;
    if (!browser_url.isLoopbackHost(parsed.host)) return null;
    return .{ .conn = conn, .parsed = parsed };
}

fn ensureSshTunnel(allocator: std.mem.Allocator, conn: *const Surface.SshConnection, remote_port: u16, local_host: []const u8, remote_host: []const u8) ?u16 {
    if (g_tunnel) |*tunnel| {
        if (tunnel.matches(conn, remote_port, local_host, remote_host) and
            !childHasExited(&tunnel.child) and
            canConnectToLocalPort(allocator, tunnel.localHost(), tunnel.local_port))
        {
            return tunnel.local_port;
        }
    }

    stopTunnel();

    const local_port = reservePreferredLocalPort(remote_port) orelse return null;
    var local_spec_buf: [MAX_TUNNEL_SPEC_BYTES]u8 = undefined;
    const local_spec = std.fmt.bufPrint(
        &local_spec_buf,
        "{s}:{d}:{s}:{d}",
        .{ local_host, local_port, remote_host, remote_port },
    ) catch return null;

    var dest_buf: [MAX_SSH_DEST_BYTES]u8 = undefined;
    const dest = sshDestination(&dest_buf, conn) orelse return null;

    var askpass_path: ?[]u8 = null;
    defer if (askpass_path) |path| allocator.free(path);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.password_auth) {
        askpass_path = ensureAskPassScript(allocator) orelse return null;
        env_map = std.process.getEnvMap(allocator) catch return null;
        if (env_map) |*map| {
            map.put("SSH_ASKPASS", askpass_path.?) catch return null;
            map.put("SSH_ASKPASS_REQUIRE", "force") catch return null;
            map.put("DISPLAY", "phantty") catch return null;
            map.put("PHANTTY_SSH_PASSWORD", conn.password()) catch return null;
        }
    }

    var argv_buf: [48][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "ssh.exe";
    argc += 1;
    argv_buf[argc] = "-N";
    argc += 1;
    argv_buf[argc] = "-T";
    argc += 1;
    argv_buf[argc] = "-L";
    argc += 1;
    argv_buf[argc] = local_spec;
    argc += 1;

    appendSshOption(&argv_buf, &argc, "ExitOnForwardFailure=yes");
    appendSshOption(&argv_buf, &argc, "StrictHostKeyChecking=accept-new");
    appendSshOption(&argv_buf, &argc, "ConnectTimeout=8");
    appendSshOption(&argv_buf, &argc, "ServerAliveInterval=60");
    appendSshOption(&argv_buf, &argc, "ServerAliveCountMax=3");
    if (conn.password_auth) {
        appendSshOption(&argv_buf, &argc, "PreferredAuthentications=publickey,password,keyboard-interactive");
        appendSshOption(&argv_buf, &argc, "NumberOfPasswordPrompts=1");
    } else {
        appendSshOption(&argv_buf, &argc, "BatchMode=yes");
    }
    if (conn.port().len > 0) {
        argv_buf[argc] = "-p";
        argc += 1;
        argv_buf[argc] = conn.port();
        argc += 1;
    }
    argv_buf[argc] = dest;
    argc += 1;

    // Keep this helper independent. Windows OpenSSH ControlMaster options are
    // intentionally not used here; they break on Windows socket semantics.
    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    if (env_map) |*map| child.env_map = map;
    child.spawn() catch |err| {
        std.debug.print("SSH browser tunnel spawn failed: {}\n", .{err});
        return null;
    };

    g_tunnel = SshTunnel.init(child, conn, remote_port, local_port, local_host, remote_host);
    if (!waitForTunnelReady(allocator, local_host, local_port)) {
        std.debug.print("SSH browser tunnel did not become ready on {s}:{d}\n", .{ local_host, local_port });
        stopTunnel();
        return null;
    }

    std.debug.print("SSH browser tunnel: {s}:{d} -> remote {s}:{d}\n", .{ local_host, local_port, remote_host, remote_port });
    return local_port;
}

fn stopTunnel() void {
    if (g_tunnel) |*tunnel| {
        if (childHasExited(&tunnel.child)) {
            _ = tunnel.child.wait() catch {};
        } else {
            _ = tunnel.child.kill() catch {};
        }
        g_tunnel = null;
    }
}

fn waitForTunnelReady(allocator: std.mem.Allocator, local_host: []const u8, local_port: u16) bool {
    const deadline = std.time.milliTimestamp() + TUNNEL_READY_TIMEOUT_MS;
    while (std.time.milliTimestamp() < deadline) {
        if (canConnectToLocalPort(allocator, local_host, local_port)) return true;
        if (g_tunnel) |*tunnel| {
            if (childHasExited(&tunnel.child)) return false;
        } else {
            return false;
        }
        std.Thread.sleep(TUNNEL_READY_POLL_NS);
    }
    return false;
}

fn canConnectToLocalPort(allocator: std.mem.Allocator, local_host: []const u8, local_port: u16) bool {
    if (std.mem.eql(u8, local_host, "127.0.0.1") or std.mem.eql(u8, local_host, "localhost")) {
        const address = std.net.Address.parseIp4("127.0.0.1", local_port) catch return false;
        var stream = std.net.tcpConnectToAddress(address) catch {
            if (!std.mem.eql(u8, local_host, "localhost")) return false;
            return canConnectToLocalHostName(allocator, local_host, local_port);
        };
        stream.close();
        return true;
    }
    return canConnectToLocalHostName(allocator, local_host, local_port);
}

fn canConnectToLocalHostName(allocator: std.mem.Allocator, local_host: []const u8, local_port: u16) bool {
    var stream = std.net.tcpConnectToHost(allocator, local_host, local_port) catch return false;
    stream.close();
    return true;
}

fn childHasExited(child: *const std.process.Child) bool {
    return win32.WaitForSingleObject(child.id, 0) == win32.WAIT_OBJECT_0;
}

fn reservePreferredLocalPort(preferred_port: u16) ?u16 {
    var port: u32 = if (preferred_port == 0) 1 else preferred_port;
    while (port <= std.math.maxInt(u16)) : (port += 1) {
        const candidate: u16 = @intCast(port);
        if (isLocalPortAvailable(candidate)) return candidate;
    }
    return null;
}

fn isLocalPortAvailable(port: u16) bool {
    const address = std.net.Address.parseIp4("127.0.0.1", port) catch return false;
    var server = address.listen(.{}) catch return false;
    server.deinit();
    return true;
}

fn reserveLocalPort() ?u16 {
    const address = std.net.Address.parseIp4("127.0.0.1", 0) catch return null;
    var server = address.listen(.{}) catch return null;
    const port = server.listen_address.getPort();
    server.deinit();
    return if (port == 0) null else port;
}

fn sshDestination(buf: *[MAX_SSH_DEST_BYTES]u8, conn: *const Surface.SshConnection) ?[]const u8 {
    const user = conn.user();
    const host = conn.host();
    const len = user.len + 1 + host.len;
    if (len > buf.len) return null;
    @memcpy(buf[0..user.len], user);
    buf[user.len] = '@';
    @memcpy(buf[user.len + 1 ..][0..host.len], host);
    return buf[0..len];
}

fn appendSshOption(argv_buf: *[48][]const u8, argc: *usize, option: []const u8) void {
    argv_buf[argc.*] = "-o";
    argc.* += 1;
    argv_buf[argc.*] = option;
    argc.* += 1;
}

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

fn askPassScriptPath(allocator: std.mem.Allocator) ?[]u8 {
    const temp = std.process.getEnvVarOwned(allocator, "TEMP") catch
        std.process.getEnvVarOwned(allocator, "TMP") catch return null;
    defer allocator.free(temp);
    return std.fmt.allocPrint(allocator, "{s}\\phantty-ssh-askpass.cmd", .{temp}) catch null;
}

fn ensureAskPassScript(allocator: std.mem.Allocator) ?[]u8 {
    const path = askPassScriptPath(allocator) orelse return null;
    errdefer allocator.free(path);

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return null;
    defer file.close();

    file.writeAll(
        "@echo off\r\n" ++
            "powershell.exe -NoLogo -NoProfile -Command \"[Console]::Out.Write($env:PHANTTY_SSH_PASSWORD)\"\r\n",
    ) catch return null;
    return path;
}

test "reservePreferredLocalPort returns the preferred port when it is free" {
    const preferred = reserveLocalPort() orelse return error.SkipZigTest;
    const selected = reservePreferredLocalPort(preferred) orelse return error.SkipZigTest;
    try std.testing.expectEqual(preferred, selected);
}

test "reservePreferredLocalPort skips an occupied preferred port" {
    const preferred = reserveLocalPort() orelse return error.SkipZigTest;
    if (preferred == std.math.maxInt(u16)) return error.SkipZigTest;

    const address = std.net.Address.parseIp4("127.0.0.1", preferred) catch return error.SkipZigTest;
    var server = address.listen(.{}) catch return error.SkipZigTest;
    defer server.deinit();

    const selected = reservePreferredLocalPort(preferred) orelse return error.SkipZigTest;
    try std.testing.expect(selected > preferred);
}
