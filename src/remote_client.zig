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

extern "kernel32" fn CreateMutexW(
    lpMutexAttributes: ?*anyopaque,
    bInitialOwner: windows.BOOL,
    lpName: windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;

const WINHTTP_ACCESS_TYPE_DEFAULT_PROXY: windows.DWORD = 0;
const WINHTTP_FLAG_SECURE: windows.DWORD = 0x00800000;
const WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET: windows.DWORD = 114;
const WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE: windows.DWORD = 2;
const WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE: windows.DWORD = 3;
const WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE: windows.DWORD = 4;
const WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS: u16 = 1000;

const QUEUE_LIMIT = 512;
const RETRY_DELAY_NS = 2 * std.time.ns_per_s;
const WEBSOCKET_IO_CHUNK_SIZE = 16 * 1024;
const MAX_INCOMING_MESSAGE_BYTES = 1024 * 1024;
const HEARTBEAT_INTERVAL_MS: i64 = 25 * 1000;
const PING_MESSAGE = "{\"type\":\"ping\"}";
const PONG_MESSAGE = "{\"type\":\"pong\"}";
const MAX_FIXED_SESSION_KEY_ATTEMPTS = 256;

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
    session_key: ?[]const u8 = null,
};

pub const SurfaceWriteFn = *const fn (ctx: *anyopaque, data: []const u8) void;
pub const AiAgentOpenStatus = enum {
    opened,
    no_profile,
    failed,
};
pub const AiAgentOpenFn = *const fn (ctx: *anyopaque, request_id: []const u8) void;

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

const SessionKeyReservation = struct {
    handle: ?windows.HANDLE = null,

    fn deinit(self: *SessionKeyReservation) void {
        if (self.handle) |handle| {
            windows.CloseHandle(handle);
            self.handle = null;
        }
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: Endpoint,
    device_name: ?[]u8,
    session_key: []u8,
    session_key_reservation: SessionKeyReservation = .{},

    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    surface_sinks: std.ArrayListUnmanaged(SurfaceSink) = .empty,
    ai_agent_open_ctx: ?*anyopaque = null,
    ai_agent_open_fn: ?AiAgentOpenFn = null,
    last_layout: ?[]u8 = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.disconnected),
    thread: ?std.Thread = null,

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Client {
        const client = try allocator.create(Client);
        errdefer allocator.destroy(client);

        var session_key_reservation: SessionKeyReservation = .{};
        errdefer session_key_reservation.deinit();

        const key = try sessionKeyAlloc(allocator, options.session_key, &session_key_reservation);
        errdefer allocator.free(key);

        var endpoint = try buildEndpoint(allocator, options.server_url, key, options.device_name);
        errdefer endpoint.deinit(allocator);

        const device_name = if (options.device_name) |name| try allocator.dupe(u8, name) else null;
        errdefer if (device_name) |name| allocator.free(name);

        client.* = .{
            .allocator = allocator,
            .endpoint = endpoint,
            .device_name = device_name,
            .session_key = key,
            .session_key_reservation = session_key_reservation,
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
        self.session_key_reservation.deinit();
        self.allocator.free(self.session_key);
    }

    pub fn destroy(self: *Client) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn sessionKey(self: *const Client) []const u8 {
        return self.session_key;
    }

    pub fn loadState(self: *const Client) State {
        return self.state.load(.acquire);
    }

    pub fn sendOutput(self: *Client, surface_id: []const u8, data: []const u8) void {
        if (data.len == 0 or self.stop_requested.load(.acquire)) return;

        const message = buildOutputMessage(self.allocator, surface_id, data) catch return;
        self.enqueueOwnedMessage(message);
    }

    pub fn sendAiAgentOpenResult(self: *Client, request_id: []const u8, status: AiAgentOpenStatus) void {
        if (request_id.len == 0 or self.stop_requested.load(.acquire)) return;

        const message = buildAiAgentOpenResultMessage(self.allocator, request_id, status) catch return;
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

    pub fn registerAiAgentOpener(
        self: *Client,
        ctx: *anyopaque,
        open_fn: AiAgentOpenFn,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.ai_agent_open_ctx = ctx;
        self.ai_agent_open_fn = open_fn;
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
        if (data.len == 0) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.surface_sinks.items) |sink| {
            if (std.mem.eql(u8, sink.id[0..], surface_id)) {
                sink.write_fn(sink.ctx, data);
                return;
            }
        }
    }

    fn dispatchAiAgentOpen(self: *Client, request_id: []const u8) void {
        self.mutex.lock();
        const ctx = self.ai_agent_open_ctx;
        const open_fn = self.ai_agent_open_fn;
        self.mutex.unlock();

        if (ctx) |callback_ctx| {
            if (open_fn) |callback| {
                callback(callback_ctx, request_id);
            }
        }
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

        var next_heartbeat_ms = std.time.milliTimestamp() + HEARTBEAT_INTERVAL_MS;
        while (!client.stop_requested.load(.acquire) and connection_alive.load(.acquire)) {
            const websocket = handles.websocket orelse break;
            const message = client.popMessage() orelse {
                const now = std.time.milliTimestamp();
                if (now >= next_heartbeat_ms) {
                    if (!sendWebSocketUtf8(websocket, PING_MESSAGE)) {
                        connection_alive.store(false, .release);
                        client.state.store(.disconnected, .release);
                        break;
                    }
                    next_heartbeat_ms = now + HEARTBEAT_INTERVAL_MS;
                    continue;
                }

                if (!client.waitForMessageOrStop(&connection_alive)) break;
                continue;
            };
            defer client.allocator.free(message);

            if (!sendWebSocketUtf8(websocket, message)) {
                connection_alive.store(false, .release);
                client.state.store(.disconnected, .release);
                break;
            }
            next_heartbeat_ms = std.time.milliTimestamp() + HEARTBEAT_INTERVAL_MS;
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
    var buf: [WEBSOCKET_IO_CHUNK_SIZE]u8 = undefined;
    var incoming: IncomingMessageAssembler = .{};
    defer incoming.deinit(client.allocator);

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
            const maybe_message = incoming.push(
                client.allocator,
                buf[0..@intCast(bytes_read)],
                buffer_type,
            ) catch continue;
            const message = maybe_message orelse continue;
            defer client.allocator.free(message);

            if (isJsonMessageType(message, "ping")) {
                _ = sendWebSocketUtf8(websocket, PONG_MESSAGE);
                continue;
            }
            if (isJsonMessageType(message, "pong")) continue;

            handleIncomingMessage(client, message);
        }
    }
}

fn sendWebSocketUtf8(websocket: HINTERNET, message: []const u8) bool {
    if (message.len <= WEBSOCKET_IO_CHUNK_SIZE) {
        return sendWebSocketUtf8Chunk(websocket, message, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE);
    }

    var offset: usize = 0;
    while (offset < message.len) {
        const remaining = message.len - offset;
        const take = @min(WEBSOCKET_IO_CHUNK_SIZE, remaining);
        const end = offset + take;
        const buffer_type: windows.DWORD = if (end == message.len)
            WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE
        else
            WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE;
        if (!sendWebSocketUtf8Chunk(websocket, message[offset..end], buffer_type)) return false;
        offset = end;
    }
    return true;
}

fn sendWebSocketUtf8Chunk(websocket: HINTERNET, message: []const u8, buffer_type: windows.DWORD) bool {
    return WinHttpWebSocketSend(
        websocket,
        buffer_type,
        @constCast(message.ptr),
        @intCast(message.len),
    ) == 0;
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

fn sessionKeyAlloc(allocator: std.mem.Allocator, configured_key: ?[]const u8, reservation: *SessionKeyReservation) ![]u8 {
    if (configured_key) |raw| {
        const base = std.mem.trim(u8, raw, " \t\r\n");
        if (base.len > 0) {
            return try reserveFixedSessionKey(allocator, base, reservation);
        }
    }

    var generated: [32]u8 = undefined;
    fillSessionKey(&generated);
    return allocator.dupe(u8, generated[0..]);
}

fn reserveFixedSessionKey(allocator: std.mem.Allocator, base: []const u8, reservation: *SessionKeyReservation) ![]u8 {
    for (0..MAX_FIXED_SESSION_KEY_ATTEMPTS) |idx| {
        const candidate = try fixedSessionKeyCandidate(allocator, base, idx);
        errdefer allocator.free(candidate);

        if (try reserveSessionKeyMutex(allocator, candidate)) |handle| {
            reservation.handle = handle;
            return candidate;
        }

        allocator.free(candidate);
    }

    return error.NoAvailableFixedSessionKey;
}

fn fixedSessionKeyCandidate(allocator: std.mem.Allocator, base: []const u8, index: usize) ![]u8 {
    if (index == 0) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "{s}_{d}", .{ base, index });
}

fn reserveSessionKeyMutex(allocator: std.mem.Allocator, session_key: []const u8) !?windows.HANDLE {
    const name_w = try sessionKeyMutexName(allocator, session_key);
    defer allocator.free(name_w);

    const handle = CreateMutexW(null, 0, name_w.ptr) orelse return error.CreateMutexFailed;
    if (windows.kernel32.GetLastError() == .ALREADY_EXISTS) {
        windows.CloseHandle(handle);
        return null;
    }

    return handle;
}

fn sessionKeyMutexName(allocator: std.mem.Allocator, session_key: []const u8) ![:0]u16 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(session_key, &digest, .{});

    const prefix = "Local\\PhanttyRemoteSessionKey-";
    var ascii: [prefix.len + digest.len * 2]u8 = undefined;
    @memcpy(ascii[0..prefix.len], prefix);

    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        ascii[prefix.len + i * 2] = hex[byte >> 4];
        ascii[prefix.len + i * 2 + 1] = hex[byte & 0x0f];
    }

    return std.unicode.utf8ToUtf16LeAllocZ(allocator, ascii[0..]);
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

fn buildAiAgentOpenResultMessage(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    status: AiAgentOpenStatus,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"type\":\"open-ai-agent-result\",\"requestId\":\"");
    try appendJsonString(&out, allocator, request_id);
    try out.appendSlice(allocator, "\",\"status\":\"");
    try out.appendSlice(allocator, aiAgentOpenStatusJson(status));
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

fn aiAgentOpenStatusJson(status: AiAgentOpenStatus) []const u8 {
    return switch (status) {
        .opened => "opened",
        .no_profile => "no-profile",
        .failed => "failed",
    };
}

fn handleIncomingMessage(client: *Client, message: []const u8) void {
    if (isJsonMessageType(message, "input-bytes")) {
        const surface_id = extractJsonString(message, "surfaceId") orelse return;
        const hex_data = extractJsonString(message, "data") orelse return;

        const decoded = decodeHexAlloc(client.allocator, hex_data) catch return;
        defer client.allocator.free(decoded);
        client.dispatchInput(surface_id, decoded);
        return;
    }

    if (isJsonMessageType(message, "open-ai-agent")) {
        const request_id = extractJsonString(message, "requestId") orelse return;
        client.dispatchAiAgentOpen(request_id);
    }
}

const IncomingMessageAssembler = struct {
    pending: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *IncomingMessageAssembler, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
    }

    fn push(
        self: *IncomingMessageAssembler,
        allocator: std.mem.Allocator,
        chunk: []const u8,
        buffer_type: windows.DWORD,
    ) !?[]u8 {
        switch (buffer_type) {
            WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE => {
                try self.append(allocator, chunk);
                return null;
            },
            WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE => {
                if (self.pending.items.len == 0) return try allocator.dupe(u8, chunk);
                try self.append(allocator, chunk);
                return try self.pending.toOwnedSlice(allocator);
            },
            else => return null,
        }
    }

    fn append(self: *IncomingMessageAssembler, allocator: std.mem.Allocator, chunk: []const u8) !void {
        if (self.pending.items.len + chunk.len > MAX_INCOMING_MESSAGE_BYTES) {
            self.pending.clearRetainingCapacity();
            return error.MessageTooLarge;
        }
        try self.pending.appendSlice(allocator, chunk);
    }
};

fn isJsonMessageType(message: []const u8, comptime kind: []const u8) bool {
    return std.mem.indexOf(u8, message, "\"type\":\"" ++ kind ++ "\"") != null;
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
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < data.len) {
        const ch = data[i];
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, hex[ch >> 4]);
                    try out.append(allocator, hex[ch & 0x0f]);
                } else if (ch < 0x80) {
                    try out.append(allocator, ch);
                } else {
                    const len = std.unicode.utf8ByteSequenceLength(ch) catch {
                        try out.appendSlice(allocator, "\\ufffd");
                        i += 1;
                        continue;
                    };
                    if (i + len > data.len) {
                        try out.appendSlice(allocator, "\\ufffd");
                        i += 1;
                        continue;
                    }
                    _ = std.unicode.utf8Decode(data[i .. i + len]) catch {
                        try out.appendSlice(allocator, "\\ufffd");
                        i += 1;
                        continue;
                    };
                    try out.appendSlice(allocator, data[i .. i + len]);
                    i += len;
                    continue;
                }
            },
        }
        i += 1;
    }
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

test "fixed session key candidates append numeric suffixes after first instance" {
    const allocator = std.testing.allocator;

    const first = try fixedSessionKeyCandidate(allocator, "fixed-password", 0);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("fixed-password", first);

    const second = try fixedSessionKeyCandidate(allocator, "fixed-password", 1);
    defer allocator.free(second);
    try std.testing.expectEqualStrings("fixed-password_1", second);

    const fourth = try fixedSessionKeyCandidate(allocator, "fixed-password", 3);
    defer allocator.free(fourth);
    try std.testing.expectEqualStrings("fixed-password_3", fourth);
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

test "remote json string replaces invalid utf8 bytes" {
    const allocator = std.testing.allocator;
    const bad = [_]u8{ 'o', 'k', ' ', 0xff, ' ', 0xc3 };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try appendJsonString(&out, allocator, bad[0..]);
    try std.testing.expectEqualStrings("ok \\ufffd \\ufffd", out.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.items));
}

test "remote json string preserves valid multibyte utf8" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try appendJsonString(&out, allocator, "标题 🚀");
    try std.testing.expectEqualStrings("标题 🚀", out.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.items));
}

test "decode input message bytes" {
    const allocator = std.testing.allocator;
    const bytes = try decodeHexAlloc(allocator, "0d1b5b41");
    defer allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, "\r\x1b[A", bytes);
}

test "incoming websocket fragments are reassembled before handling JSON" {
    const allocator = std.testing.allocator;
    var assembler: IncomingMessageAssembler = .{};
    defer assembler.deinit(allocator);

    const prefix = "{\"type\":\"input-bytes\",\"surfaceId\":\"aichat0000000000\",\"encoding\":\"hex\",\"data\":\"";
    const suffix = "68656c6c6f0d\"}";

    const first = try assembler.push(allocator, prefix, WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE);
    try std.testing.expect(first == null);

    const second = try assembler.push(allocator, suffix, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE);
    defer if (second) |message| allocator.free(message);
    try std.testing.expect(second != null);

    const expected = "{\"type\":\"input-bytes\",\"surfaceId\":\"aichat0000000000\",\"encoding\":\"hex\",\"data\":\"68656c6c6f0d\"}";
    try std.testing.expectEqualStrings(expected, second.?);
}

const TestAiAgentOpenCtx = struct {
    called: bool = false,
    request_id_buf: [128]u8 = undefined,
    request_id_len: usize = 0,

    fn onOpen(ctx: *anyopaque, request_id: []const u8) void {
        const self: *TestAiAgentOpenCtx = @ptrCast(@alignCast(ctx));
        self.called = true;
        self.request_id_len = @min(request_id.len, self.request_id_buf.len);
        @memcpy(self.request_id_buf[0..self.request_id_len], request_id[0..self.request_id_len]);
    }
};

fn initTestClient(allocator: std.mem.Allocator) !Client {
    return .{
        .allocator = allocator,
        .endpoint = .{
            .secure = false,
            .host = try allocator.dupe(u8, "127.0.0.1"),
            .port = 80,
            .object_name = try allocator.dupe(u8, "/ws/phantty?session=test"),
        },
        .device_name = null,
        .session_key = try allocator.dupe(u8, "test"),
    };
}

test "open ai agent message dispatches request id" {
    const allocator = std.testing.allocator;
    var client = try initTestClient(allocator);
    defer client.deinit();

    var ctx = TestAiAgentOpenCtx{};
    client.registerAiAgentOpener(&ctx, TestAiAgentOpenCtx.onOpen);

    handleIncomingMessage(&client, "{\"type\":\"open-ai-agent\",\"requestId\":\"remote-ai-1\"}");

    try std.testing.expect(ctx.called);
    try std.testing.expectEqualStrings("remote-ai-1", ctx.request_id_buf[0..ctx.request_id_len]);
}

test "open ai agent result message escapes request id" {
    const allocator = std.testing.allocator;
    const message = try buildAiAgentOpenResultMessage(allocator, "remote-\"one", .no_profile);
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "{\"type\":\"open-ai-agent-result\",\"requestId\":\"remote-\\\"one\",\"status\":\"no-profile\"}",
        message,
    );
}
