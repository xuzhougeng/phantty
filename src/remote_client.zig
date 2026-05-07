//! Outbound remote relay client shared by one Phantty instance.
//!
//! Surfaces do not own network state. They register as sinks on this shared
//! client, then publish PTY output with their own stable surface id.

const std = @import("std");
const windows = std.os.windows;

const HINTERNET = *opaque {};

extern "winhttp" fn WinHttpOpen(
    pszAgentW: ?windows.LPCWSTR,
    dwAccessType: windows.DWORD,
    pszProxyW: ?windows.LPCWSTR,
    pszProxyBypassW: ?windows.LPCWSTR,
    dwFlags: windows.DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpConnect(
    hSession: HINTERNET,
    pswzServerName: windows.LPCWSTR,
    nServerPort: u16,
    dwReserved: windows.DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpOpenRequest(
    hConnect: HINTERNET,
    pwszVerb: windows.LPCWSTR,
    pwszObjectName: windows.LPCWSTR,
    pwszVersion: ?windows.LPCWSTR,
    pwszReferrer: ?windows.LPCWSTR,
    ppwszAcceptTypes: ?*const ?windows.LPCWSTR,
    dwFlags: windows.DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpSetOption(
    hInternet: HINTERNET,
    dwOption: windows.DWORD,
    lpBuffer: ?*anyopaque,
    dwBufferLength: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "winhttp" fn WinHttpSendRequest(
    hRequest: HINTERNET,
    lpszHeaders: ?windows.LPCWSTR,
    dwHeadersLength: windows.DWORD,
    lpOptional: ?*anyopaque,
    dwOptionalLength: windows.DWORD,
    dwTotalLength: windows.DWORD,
    dwContext: usize,
) callconv(.winapi) windows.BOOL;

extern "winhttp" fn WinHttpReceiveResponse(
    hRequest: HINTERNET,
    lpReserved: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "winhttp" fn WinHttpWebSocketCompleteUpgrade(
    hRequest: HINTERNET,
    pContext: usize,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpWebSocketSend(
    hWebSocket: HINTERNET,
    eBufferType: windows.DWORD,
    pvBuffer: ?*anyopaque,
    dwBufferLength: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "winhttp" fn WinHttpWebSocketReceive(
    hWebSocket: HINTERNET,
    pvBuffer: ?*anyopaque,
    dwBufferLength: windows.DWORD,
    pdwBytesRead: *windows.DWORD,
    peBufferType: *windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "winhttp" fn WinHttpWebSocketClose(
    hWebSocket: HINTERNET,
    usStatus: u16,
    pvReason: ?*anyopaque,
    dwReasonLength: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "winhttp" fn WinHttpCloseHandle(hInternet: HINTERNET) callconv(.winapi) windows.BOOL;

const WINHTTP_ACCESS_TYPE_DEFAULT_PROXY: windows.DWORD = 0;
const WINHTTP_FLAG_SECURE: windows.DWORD = 0x00800000;
const WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET: windows.DWORD = 114;
const WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE: windows.DWORD = 2;
const WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE: windows.DWORD = 3;
const WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE: windows.DWORD = 4;
const WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS: u16 = 1000;

const QUEUE_LIMIT = 512;
const RETRY_DELAY_NS = 2 * std.time.ns_per_s;
const INPUT_BUF_SIZE = 16 * 1024;

var next_surface_counter = std.atomic.Value(u64).init(1);

pub const State = enum(u8) {
    disabled,
    connecting,
    connected,
    disconnected,
    failed,
};

pub const Options = struct {
    server_url: []const u8,
    device_name: ?[]const u8 = null,
};

pub const SurfaceWriteFn = *const fn (ctx: *anyopaque, data: []const u8) void;

const SurfaceSink = struct {
    id: [16]u8,
    ctx: *anyopaque,
    write_fn: SurfaceWriteFn,
};

const Endpoint = struct {
    secure: bool,
    host: []u8,
    port: u16,
    object_name: []u8,

    fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.object_name);
    }
};

const Handles = struct {
    session: ?HINTERNET = null,
    connect: ?HINTERNET = null,
    request: ?HINTERNET = null,
    websocket: ?HINTERNET = null,

    fn close(self: *Handles) void {
        if (self.websocket) |h| {
            _ = WinHttpWebSocketClose(h, WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, null, 0);
            _ = WinHttpCloseHandle(h);
            self.websocket = null;
        }
        if (self.request) |h| {
            _ = WinHttpCloseHandle(h);
            self.request = null;
        }
        if (self.connect) |h| {
            _ = WinHttpCloseHandle(h);
            self.connect = null;
        }
        if (self.session) |h| {
            _ = WinHttpCloseHandle(h);
            self.session = null;
        }
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: Endpoint,
    device_name: ?[]u8,
    session_key: [32]u8,

    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    surface_sinks: std.ArrayListUnmanaged(SurfaceSink) = .empty,
    last_layout: ?[]u8 = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.disconnected),
    control_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    control_granted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Client {
        const client = try allocator.create(Client);
        errdefer allocator.destroy(client);

        var key: [32]u8 = undefined;
        fillSessionKey(&key);

        var endpoint = try buildEndpoint(allocator, options.server_url, &key, options.device_name);
        errdefer endpoint.deinit(allocator);

        const device_name = if (options.device_name) |name| try allocator.dupe(u8, name) else null;
        errdefer if (device_name) |name| allocator.free(name);

        client.* = .{
            .allocator = allocator,
            .endpoint = endpoint,
            .device_name = device_name,
            .session_key = key,
        };

        client.thread = try std.Thread.spawn(.{}, threadMain, .{client});
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.stop_requested.store(true, .release);
        self.condition.broadcast();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.mutex.lock();
        while (self.queue.pop()) |message| {
            self.allocator.free(message);
        }
        self.queue.deinit(self.allocator);
        self.surface_sinks.deinit(self.allocator);
        self.mutex.unlock();

        if (self.last_layout) |layout| self.allocator.free(layout);
        self.endpoint.deinit(self.allocator);
        if (self.device_name) |name| self.allocator.free(name);
    }

    pub fn destroy(self: *Client) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn sessionKey(self: *const Client) []const u8 {
        return self.session_key[0..];
    }

    pub fn loadState(self: *const Client) State {
        return self.state.load(.acquire);
    }

    pub fn hasControlRequest(self: *const Client) bool {
        return self.control_requested.load(.acquire);
    }

    pub fn controlGranted(self: *const Client) bool {
        return self.control_granted.load(.acquire);
    }

    pub fn grantControl(self: *Client) void {
        self.control_requested.store(false, .release);
        self.control_granted.store(true, .release);
        self.enqueueControlMessage("control-granted");
    }

    pub fn revokeControl(self: *Client) void {
        self.control_requested.store(false, .release);
        self.control_granted.store(false, .release);
        self.enqueueControlMessage("control-revoked");
    }

    pub fn sendOutput(self: *Client, surface_id: []const u8, data: []const u8) void {
        if (data.len == 0 or self.stop_requested.load(.acquire)) return;

        const message = buildOutputMessage(self.allocator, surface_id, data) catch return;
        self.enqueueOwnedMessage(message);
    }

    pub fn sendLayout(self: *Client, layout_json: []const u8) void {
        if (layout_json.len == 0 or self.stop_requested.load(.acquire)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.last_layout) |last| {
            if (std.mem.eql(u8, last, layout_json)) return;
        }

        const next_layout = self.allocator.dupe(u8, layout_json) catch return;
        const queued = self.allocator.dupe(u8, layout_json) catch {
            self.allocator.free(next_layout);
            return;
        };

        if (self.last_layout) |last| self.allocator.free(last);
        self.last_layout = next_layout;
        self.enqueueOwnedMessageLocked(queued);
    }

    pub fn registerSurface(
        self: *Client,
        surface_id: [16]u8,
        ctx: *anyopaque,
        write_fn: SurfaceWriteFn,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.surface_sinks.items) |*sink| {
            if (std.mem.eql(u8, sink.id[0..], surface_id[0..])) {
                sink.ctx = ctx;
                sink.write_fn = write_fn;
                return;
            }
        }

        self.surface_sinks.append(self.allocator, .{
            .id = surface_id,
            .ctx = ctx,
            .write_fn = write_fn,
        }) catch {};
    }

    pub fn unregisterSurface(self: *Client, surface_id: [16]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.surface_sinks.items, 0..) |sink, i| {
            if (std.mem.eql(u8, sink.id[0..], surface_id[0..])) {
                _ = self.surface_sinks.swapRemove(i);
                return;
            }
        }
    }

    fn enqueueOwnedMessage(self: *Client, message: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enqueueOwnedMessageLocked(message);
    }

    fn enqueueOwnedMessageLocked(self: *Client, message: []u8) void {
        while (self.queue.items.len >= QUEUE_LIMIT) {
            const dropped = self.queue.orderedRemove(0);
            self.allocator.free(dropped);
        }
        self.queue.append(self.allocator, message) catch {
            self.allocator.free(message);
            return;
        };
        self.condition.signal();
    }

    fn replayLastLayout(self: *Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const last = self.last_layout orelse return;
        const queued = self.allocator.dupe(u8, last) catch return;
        self.enqueueOwnedMessageLocked(queued);
    }

    fn replayControlState(self: *Client) void {
        if (self.control_granted.load(.acquire)) {
            self.enqueueControlMessage("control-granted");
        } else if (self.control_requested.load(.acquire)) {
            self.enqueueControlMessage("control-requested");
        } else {
            self.enqueueControlMessage("control-revoked");
        }
    }

    fn popMessage(self: *Client) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn waitForMessageOrStop(self: *Client, connection_alive: *std.atomic.Value(bool)) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.items.len == 0 and
            !self.stop_requested.load(.acquire) and
            connection_alive.load(.acquire))
        {
            self.condition.timedWait(&self.mutex, std.time.ns_per_s) catch {};
        }
        return !self.stop_requested.load(.acquire) and connection_alive.load(.acquire);
    }

    fn dispatchInput(self: *Client, surface_id: []const u8, data: []const u8) void {
        if (data.len == 0 or !self.control_granted.load(.acquire)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.surface_sinks.items) |sink| {
            if (std.mem.eql(u8, sink.id[0..], surface_id)) {
                sink.write_fn(sink.ctx, data);
                return;
            }
        }
    }

    fn markControlRequested(self: *Client) void {
        if (self.control_granted.load(.acquire)) {
            self.enqueueControlMessage("control-granted");
            return;
        }

        self.control_requested.store(true, .release);
        self.enqueueControlMessage("control-requested");
    }

    fn markControlRevokedByRelay(self: *Client) void {
        self.control_requested.store(false, .release);
        self.control_granted.store(false, .release);
    }

    fn enqueueControlMessage(self: *Client, message_type: []const u8) void {
        if (self.stop_requested.load(.acquire)) return;
        const message = buildTypeMessage(self.allocator, message_type) catch return;
        self.enqueueOwnedMessage(message);
    }
};

fn threadMain(client: *Client) void {
    while (!client.stop_requested.load(.acquire)) {
        client.state.store(.connecting, .release);
        var handles = connectWebSocket(client) catch |err| {
            client.state.store(.failed, .release);
            std.debug.print("Remote client connect failed: {}\n", .{err});
            sleepUntilRetryOrStop(client);
            continue;
        };
        defer handles.close();

        var connection_alive = std.atomic.Value(bool).init(true);
        const receive_thread = if (handles.websocket) |websocket|
            std.Thread.spawn(.{}, receiveThreadMain, .{ client, websocket, &connection_alive }) catch null
        else
            null;

        client.state.store(.connected, .release);
        std.debug.print("Remote client connected\n", .{});
        client.replayLastLayout();
        client.replayControlState();

        while (!client.stop_requested.load(.acquire) and connection_alive.load(.acquire)) {
            const message = client.popMessage() orelse {
                if (!client.waitForMessageOrStop(&connection_alive)) break;
                continue;
            };
            defer client.allocator.free(message);

            const websocket = handles.websocket orelse break;
            if (WinHttpWebSocketSend(
                websocket,
                WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
                @constCast(message.ptr),
                @intCast(message.len),
            ) != 0) {
                connection_alive.store(false, .release);
                client.state.store(.disconnected, .release);
                break;
            }
        }

        handles.close();
        if (receive_thread) |thread| {
            thread.join();
        }
        if (!client.stop_requested.load(.acquire)) {
            client.state.store(.disconnected, .release);
            sleepUntilRetryOrStop(client);
        }
    }

    client.state.store(.disabled, .release);
}

fn receiveThreadMain(client: *Client, websocket: HINTERNET, connection_alive: *std.atomic.Value(bool)) void {
    var buf: [INPUT_BUF_SIZE]u8 = undefined;

    while (!client.stop_requested.load(.acquire)) {
        var bytes_read: windows.DWORD = 0;
        var buffer_type: windows.DWORD = 0;
        const rc = WinHttpWebSocketReceive(
            websocket,
            &buf,
            @intCast(buf.len),
            &bytes_read,
            &buffer_type,
        );
        if (rc != 0 or buffer_type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
            connection_alive.store(false, .release);
            client.condition.broadcast();
            return;
        }
        if (bytes_read == 0) continue;

        if (buffer_type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE or
            buffer_type == WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE)
        {
            handleIncomingMessage(client, buf[0..@intCast(bytes_read)]);
        }
    }
}

fn sleepUntilRetryOrStop(client: *Client) void {
    const step_ns = 100 * std.time.ns_per_ms;
    var elapsed: u64 = 0;
    while (elapsed < RETRY_DELAY_NS and !client.stop_requested.load(.acquire)) : (elapsed += step_ns) {
        std.Thread.sleep(step_ns);
    }
}

fn connectWebSocket(client: *Client) !Handles {
    var handles: Handles = .{};
    errdefer handles.close();

    const agent = std.unicode.utf8ToUtf16LeStringLiteral("Phantty Remote");
    handles.session = WinHttpOpen(agent, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0) orelse return error.WinHttpOpenFailed;

    const host_w = try std.unicode.utf8ToUtf16LeAllocZ(client.allocator, client.endpoint.host);
    defer client.allocator.free(host_w);
    handles.connect = WinHttpConnect(handles.session.?, host_w, client.endpoint.port, 0) orelse return error.WinHttpConnectFailed;

    const get_w = std.unicode.utf8ToUtf16LeStringLiteral("GET");
    const object_w = try std.unicode.utf8ToUtf16LeAllocZ(client.allocator, client.endpoint.object_name);
    defer client.allocator.free(object_w);

    const flags: windows.DWORD = if (client.endpoint.secure) WINHTTP_FLAG_SECURE else 0;
    handles.request = WinHttpOpenRequest(handles.connect.?, get_w, object_w, null, null, null, flags) orelse return error.WinHttpOpenRequestFailed;

    if (WinHttpSetOption(handles.request.?, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, null, 0) == 0) {
        return error.WinHttpUpgradeOptionFailed;
    }
    if (WinHttpSendRequest(handles.request.?, null, 0, null, 0, 0, 0) == 0) {
        return error.WinHttpSendRequestFailed;
    }
    if (WinHttpReceiveResponse(handles.request.?, null) == 0) {
        return error.WinHttpReceiveResponseFailed;
    }

    handles.websocket = WinHttpWebSocketCompleteUpgrade(handles.request.?, 0) orelse return error.WinHttpCompleteUpgradeFailed;
    return handles;
}

fn fillSessionKey(out: *[32]u8) void {
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const hex = "0123456789abcdef";
    for (random, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
}

pub fn nextSurfaceId(out: *[16]u8) void {
    const value = next_surface_counter.fetchAdd(1, .monotonic);
    const hex = "0123456789abcdef";
    for (0..16) |i| {
        const shift: u6 = @intCast((15 - i) * 4);
        const nibble: u8 = @intCast((value >> shift) & 0x0f);
        out[i] = hex[nibble];
    }
}

fn buildEndpoint(
    allocator: std.mem.Allocator,
    server_url: []const u8,
    session_key: []const u8,
    device_name: ?[]const u8,
) !Endpoint {
    const uri = try std.Uri.parse(server_url);
    const host_component = uri.host orelse return error.MissingHost;
    const host = host_component.percent_encoded;
    if (host.len == 0) return error.MissingHost;

    const secure = if (std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "wss"))
        true
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "ws"))
        false
    else
        return error.UnsupportedScheme;

    const port: u16 = uri.port orelse if (secure) 443 else 80;
    const owned_host = try allocator.dupe(u8, host);
    errdefer allocator.free(owned_host);

    var object: std.ArrayListUnmanaged(u8) = .empty;
    errdefer object.deinit(allocator);

    const base_path = uri.path.percent_encoded;
    if (base_path.len > 1 and !std.mem.eql(u8, base_path, "/")) {
        try object.appendSlice(allocator, base_path);
        if (object.items[object.items.len - 1] == '/') {
            _ = object.pop();
        }
    }
    try object.appendSlice(allocator, "/ws/phantty?session=");
    try appendQueryEscaped(&object, allocator, session_key);
    if (device_name) |device| {
        if (device.len > 0) {
            try object.appendSlice(allocator, "&device=");
            try appendQueryEscaped(&object, allocator, device);
        }
    }

    return .{
        .secure = secure,
        .host = owned_host,
        .port = port,
        .object_name = try object.toOwnedSlice(allocator),
    };
}

fn appendQueryEscaped(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }
}

fn buildOutputMessage(allocator: std.mem.Allocator, surface_id: []const u8, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"type\":\"output-bytes\",\"surfaceId\":\"");
    try appendJsonString(&out, allocator, surface_id);
    try out.appendSlice(allocator, "\",\"encoding\":\"hex\",\"data\":\"");
    try appendHex(&out, allocator, data);
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

fn handleIncomingMessage(client: *Client, message: []const u8) void {
    if (std.mem.indexOf(u8, message, "\"type\":\"request-control\"") != null) {
        client.markControlRequested();
        return;
    }

    if (std.mem.indexOf(u8, message, "\"type\":\"control-revoked\"") != null) {
        client.markControlRevokedByRelay();
        return;
    }

    if (std.mem.indexOf(u8, message, "\"type\":\"input-bytes\"") == null) return;
    const surface_id = extractJsonString(message, "surfaceId") orelse return;
    const hex_data = extractJsonString(message, "data") orelse return;

    const decoded = decodeHexAlloc(client.allocator, hex_data) catch return;
    defer client.allocator.free(decoded);
    client.dispatchInput(surface_id, decoded);
}

fn extractJsonString(message: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    if (field.len + 4 > needle_buf.len) return null;

    needle_buf[0] = '"';
    @memcpy(needle_buf[1..][0..field.len], field);
    needle_buf[field.len + 1] = '"';
    needle_buf[field.len + 2] = ':';
    needle_buf[field.len + 3] = '"';
    const needle = needle_buf[0 .. field.len + 4];

    const start = std.mem.indexOf(u8, message, needle) orelse return null;
    var i = start + needle.len;
    const value_start = i;
    while (i < message.len) : (i += 1) {
        if (message[i] == '"') return message[value_start..i];
        if (message[i] == '\\') return null;
    }
    return null;
}

fn decodeHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);

    for (out, 0..) |*byte, i| {
        const high = try hexValue(hex[i * 2]);
        const low = try hexValue(hex[i * 2 + 1]);
        byte.* = (high << 4) | low;
    }
    return out;
}

fn hexValue(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn appendHex(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    const hex = "0123456789abcdef";
    for (data) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}

pub fn appendJsonString(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    for (data) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    const hex = "0123456789abcdef";
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, hex[ch >> 4]);
                    try out.append(allocator, hex[ch & 0x0f]);
                } else {
                    try out.append(allocator, ch);
                }
            },
        }
    }
}

fn buildTypeMessage(allocator: std.mem.Allocator, message_type: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"type\":\"");
    try appendJsonString(&out, allocator, message_type);
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

test "buildEndpoint maps relay URL to Phantty websocket route" {
    const allocator = std.testing.allocator;
    const key = "0123456789abcdef0123456789abcdef";

    var endpoint = try buildEndpoint(allocator, "https://remote.example.com", key, "workstation");
    defer endpoint.deinit(allocator);

    try std.testing.expect(endpoint.secure);
    try std.testing.expectEqualStrings("remote.example.com", endpoint.host);
    try std.testing.expectEqual(@as(u16, 443), endpoint.port);
    try std.testing.expectEqualStrings("/ws/phantty?session=0123456789abcdef0123456789abcdef&device=workstation", endpoint.object_name);
}

test "buildOutputMessage preserves PTY bytes as hex" {
    const allocator = std.testing.allocator;
    const message = try buildOutputMessage(allocator, "0000000000000001", "\x1b[31mhi\r\n");
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "{\"type\":\"output-bytes\",\"surfaceId\":\"0000000000000001\",\"encoding\":\"hex\",\"data\":\"1b5b33316d68690d0a\"}",
        message,
    );
}

test "decode input message bytes" {
    const allocator = std.testing.allocator;
    const bytes = try decodeHexAlloc(allocator, "0d1b5b41");
    defer allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, "\r\x1b[A", bytes);
}

test "buildTypeMessage emits a relay control event" {
    const allocator = std.testing.allocator;
    const message = try buildTypeMessage(allocator, "control-granted");
    defer allocator.free(message);

    try std.testing.expectEqualStrings("{\"type\":\"control-granted\"}", message);
}
