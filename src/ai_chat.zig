//! AI Chat session state and OpenAI-compatible API bridge.
//!
//! This is intentionally kept outside Surface/PTY/VT paths: Ghostty keeps
//! terminal surfaces focused on terminal emulation, and Phantty's AI Chat is a
//! Phantty-specific session kind rendered by the window chrome.

const std = @import("std");
const win32_backend = @import("apprt/win32.zig");

pub const DEFAULT_NAME = "DeepSeek";
pub const DEFAULT_BASE_URL = "https://api.deepseek.com";
pub const DEFAULT_MODEL = "deepseek-v4-pro";
pub const DEFAULT_SYSTEM_PROMPT = "You are a helpful assistant.";
pub const DEFAULT_THINKING = "enabled";
pub const DEFAULT_REASONING_EFFORT = "high";
pub const DEFAULT_STREAM = "false";
pub const DEFAULT_AGENT = "false";

const MAX_AGENT_ITERATIONS = 12;
const DEFAULT_AGENT_TIMEOUT_MS: u32 = 60_000;
const DEFAULT_AGENT_OUTPUT_LIMIT: u32 = 16 * 1024;

pub const Role = enum {
    user,
    assistant,
    tool,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .user => "You",
            .assistant => "AI",
            .tool => "Tool",
        };
    }

    pub fn apiName(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const Message = struct {
    role: Role,
    content: []u8,
    reasoning: ?[]u8 = null,
};

const RequestMessage = struct {
    role: Role,
    content: []u8,
    tool_call_id: ?[]u8 = null,
    tool_calls: ?[]ToolCall = null,

    fn deinit(self: RequestMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
    }
};

const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments: []u8,

    fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
    }
};

pub const AgentPermission = enum {
    confirm,
    full,

    pub fn parse(value: []const u8) ?AgentPermission {
        if (std.mem.eql(u8, value, "confirm")) return .confirm;
        if (std.mem.eql(u8, value, "full") or std.mem.eql(u8, value, "full-permission")) return .full;
        return null;
    }

    pub fn name(self: AgentPermission) []const u8 {
        return switch (self) {
            .confirm => "confirm",
            .full => "full",
        };
    }
};

pub const AgentSettings = struct {
    enabled: bool = false,
    permission: AgentPermission = .confirm,
    command_timeout_ms: u32 = DEFAULT_AGENT_TIMEOUT_MS,
    output_limit: u32 = DEFAULT_AGENT_OUTPUT_LIMIT,
};

pub const ToolSurface = struct {
    id: []u8,
    title: []u8,
    cwd: []u8,
    snapshot: []u8,
    tab_index: usize,
    focused: bool,
    is_ssh: bool,
    ptr: *anyopaque,

    pub fn deinit(self: ToolSurface, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.cwd);
        allocator.free(self.snapshot);
    }
};

pub const ToolSnapshot = struct {
    surfaces: []ToolSurface,
    active_tab: usize,

    pub fn deinit(self: ToolSnapshot, allocator: std.mem.Allocator) void {
        for (self.surfaces) |surface| surface.deinit(allocator);
        allocator.free(self.surfaces);
    }
};

pub const ToolHost = struct {
    ctx: *anyopaque,
    collectSnapshot: *const fn (*anyopaque, std.mem.Allocator) anyerror!ToolSnapshot,
    surfaceSnapshot: *const fn (*anyopaque, std.mem.Allocator, *anyopaque) anyerror![]u8,
    writeSurface: *const fn (*anyopaque, *anyopaque, []const u8) bool,
};

const ChatRequest = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    system_prompt: []u8,
    messages: []RequestMessage,
    thinking_enabled: bool,
    reasoning_effort: []u8,
    stream: bool,
    agent_enabled: bool,
    tool_host: ?ToolHost,
    tool_snapshot: ?ToolSnapshot,

    fn deinit(self: *ChatRequest) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.system_prompt);
        self.allocator.free(self.reasoning_effort);
        for (self.messages) |msg| msg.deinit(self.allocator);
        self.allocator.free(self.messages);
        if (self.tool_snapshot) |snapshot| snapshot.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const ApiResult = struct {
    content: []u8,
    reasoning: ?[]u8 = null,
    tool_calls: ?[]ToolCall = null,

    fn deinit(self: ApiResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.reasoning) |reasoning| allocator.free(reasoning);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
    }
};

var g_agent_mutex: std.Thread.Mutex = .{};
var g_agent_settings: AgentSettings = .{};
var g_tool_host: ?ToolHost = null;

pub fn configureAgent(settings: AgentSettings) void {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    g_agent_settings = settings;
}

pub fn setToolHost(host: ?ToolHost) void {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    g_tool_host = host;
}

fn currentAgentSettings() AgentSettings {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    return g_agent_settings;
}

fn currentToolHost() ?ToolHost {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    return g_tool_host;
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    messages: std.ArrayListUnmanaged(Message) = .empty,
    input_buf: [8192]u8 = undefined,
    input_len: usize = 0,
    status_buf: [512]u8 = undefined,
    status_len: usize = 0,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    base_url_buf: [256]u8 = undefined,
    base_url_len: usize = 0,
    api_key_buf: [512]u8 = undefined,
    api_key_len: usize = 0,
    model_buf: [128]u8 = undefined,
    model_len: usize = 0,
    system_prompt_buf: [512]u8 = undefined,
    system_prompt_len: usize = 0,
    thinking_enabled: bool = true,
    reasoning_effort_buf: [16]u8 = undefined,
    reasoning_effort_len: usize = 0,
    stream: bool = false,
    agent_enabled: bool = false,
    request_inflight: bool = false,
    request_thread: ?std.Thread = null,
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scroll_px: f32 = 0,

    pub fn reasoningEffort(self: *const Session) []const u8 {
        return self.reasoning_effort_buf[0..self.reasoning_effort_len];
    }

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        model_name: []const u8,
        system_prompt: []const u8,
        thinking: []const u8,
        reasoning_effort: []const u8,
        stream_val: []const u8,
        agent_val: []const u8,
    ) !*Session {
        const session = try allocator.create(Session);
        session.* = .{
            .allocator = allocator,
        };
        session.copyTitle(if (name.len > 0) name else DEFAULT_NAME);
        session.copyBaseUrl(if (base_url.len > 0) base_url else DEFAULT_BASE_URL);
        session.copyModel(if (model_name.len > 0) model_name else DEFAULT_MODEL);
        session.copySystemPrompt(if (system_prompt.len > 0) system_prompt else DEFAULT_SYSTEM_PROMPT);
        session.thinking_enabled = !std.mem.eql(u8, thinking, "disabled");
        session.copyReasoningEffort(if (reasoning_effort.len > 0) reasoning_effort else DEFAULT_REASONING_EFFORT);
        session.stream = std.mem.eql(u8, stream_val, "true");
        session.agent_enabled = std.mem.eql(u8, agent_val, "true") or std.mem.eql(u8, agent_val, "enabled");
        session.copyApiKey(api_key);
        if (session.api_key_len == 0 and isDeepSeekBaseUrl(session.baseUrl())) {
            if (std.process.getEnvVarOwned(allocator, "DEEPSEEK_API_KEY")) |env_key| {
                defer allocator.free(env_key);
                session.copyApiKey(env_key);
            } else |_| {}
        }
        session.setStatus("Ready");
        return session;
    }

    pub fn deinit(self: *Session) void {
        self.closing.store(true, .release);
        if (self.request_thread) |thread| {
            thread.join();
            self.request_thread = null;
        }
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.reasoning) |reasoning| self.allocator.free(reasoning);
        }
        self.messages.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn title(self: *const Session) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn baseUrl(self: *const Session) []const u8 {
        return self.base_url_buf[0..self.base_url_len];
    }

    pub fn model(self: *const Session) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn systemPrompt(self: *const Session) []const u8 {
        return self.system_prompt_buf[0..self.system_prompt_len];
    }

    pub fn apiKey(self: *const Session) []const u8 {
        return self.api_key_buf[0..self.api_key_len];
    }

    pub fn input(self: *const Session) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    pub fn status(self: *const Session) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn setTitle(self: *Session, title_text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.copyTitle(title_text);
    }

    pub fn handleChar(self: *Session, codepoint: u21) void {
        if (codepoint < 0x20 or codepoint == 0x7f) return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input_len + len > self.input_buf.len) return;
        @memcpy(self.input_buf[self.input_len..][0..len], buf[0..len]);
        self.input_len += len;
    }

    pub fn appendInputText(self: *Session, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const len = @min(text.len, self.input_buf.len - self.input_len);
        if (len == 0) return;
        @memcpy(self.input_buf[self.input_len..][0..len], text[0..len]);
        self.input_len += len;
    }

    pub fn handleKey(self: *Session, ev: win32_backend.KeyEvent) void {
        if (ev.ctrl and !ev.alt and ev.vk == 0x55) {
            self.mutex.lock();
            self.input_len = 0;
            self.mutex.unlock();
            return;
        }
        if (ev.ctrl and !ev.alt and ev.vk == 0x4C) {
            self.clearMessages();
            return;
        }

        switch (ev.vk) {
            win32_backend.VK_BACK => self.backspaceInput(),
            win32_backend.VK_RETURN => {
                if (ev.shift) {
                    self.appendInputText("\n");
                } else {
                    self.submit();
                }
            },
            else => {},
        }
    }

    pub fn submit(self: *Session) void {
        self.mutex.lock();
        if (self.request_thread) |thread| {
            if (self.request_inflight) {
                self.mutex.unlock();
                return;
            }
            self.request_thread = null;
            self.mutex.unlock();
            thread.join();
            self.mutex.lock();
        }

        const prompt_raw = std.mem.trim(u8, self.input(), " \t\r\n");
        if (prompt_raw.len == 0) {
            self.mutex.unlock();
            return;
        }
        if (self.api_key_len == 0) {
            self.setStatusLocked("Missing API key. Edit the AI Chat profile or set DEEPSEEK_API_KEY.");
            self.mutex.unlock();
            return;
        }

        const prompt = self.allocator.dupe(u8, prompt_raw) catch {
            self.setStatusLocked("Out of memory");
            self.mutex.unlock();
            return;
        };
        self.messages.append(self.allocator, .{ .role = .user, .content = prompt }) catch {
            self.allocator.free(prompt);
            self.setStatusLocked("Out of memory");
            self.mutex.unlock();
            return;
        };
        self.input_len = 0;
        self.scroll_px = 1_000_000;

        const request = self.buildRequestLocked() catch {
            self.setStatusLocked("Could not prepare request");
            self.mutex.unlock();
            return;
        };

        self.request_inflight = true;
        self.setStatusLocked("Thinking...");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, requestThreadMain, .{request}) catch {
            request.deinit();
            self.mutex.lock();
            self.request_inflight = false;
            self.setStatusLocked("Failed to start request thread");
            self.mutex.unlock();
            return;
        };

        self.mutex.lock();
        self.request_thread = thread;
        self.mutex.unlock();
    }

    fn clearMessages(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.request_inflight) return;
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.reasoning) |reasoning| self.allocator.free(reasoning);
        }
        self.messages.clearRetainingCapacity();
        self.scroll_px = 0;
        self.setStatusLocked("Cleared");
    }

    pub fn scrollBy(self: *Session, delta_px: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scroll_px = @max(0.0, self.scroll_px + delta_px);
    }

    fn backspaceInput(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input_len == 0) return;
        self.input_len -= 1;
        while (self.input_len > 0 and (self.input_buf[self.input_len] & 0xC0) == 0x80) {
            self.input_len -= 1;
        }
    }

    fn buildRequestLocked(self: *Session) !*ChatRequest {
        const req = try self.allocator.create(ChatRequest);
        errdefer self.allocator.destroy(req);

        var visible_count: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.role != .tool) visible_count += 1;
        }

        const messages = try self.allocator.alloc(RequestMessage, visible_count);
        errdefer self.allocator.free(messages);

        var written: usize = 0;
        errdefer {
            for (messages[0..written]) |msg| msg.deinit(self.allocator);
        }

        for (self.messages.items) |msg| {
            if (msg.role == .tool) continue;
            messages[written] = .{
                .role = msg.role,
                .content = try self.allocator.dupe(u8, msg.content),
            };
            written += 1;
        }

        const settings = currentAgentSettings();
        const agent_enabled = self.agent_enabled or settings.enabled;
        const tool_host = if (agent_enabled) currentToolHost() else null;
        var tool_snapshot: ?ToolSnapshot = null;
        if (tool_host) |host| {
            tool_snapshot = host.collectSnapshot(host.ctx, self.allocator) catch null;
        }
        errdefer if (tool_snapshot) |snapshot| snapshot.deinit(self.allocator);

        req.* = .{
            .allocator = self.allocator,
            .session = self,
            .base_url = try self.allocator.dupe(u8, self.baseUrl()),
            .api_key = try self.allocator.dupe(u8, self.apiKey()),
            .model = try self.allocator.dupe(u8, self.model()),
            .system_prompt = try self.allocator.dupe(u8, self.systemPrompt()),
            .messages = messages,
            .thinking_enabled = self.thinking_enabled,
            .reasoning_effort = try self.allocator.dupe(u8, self.reasoningEffort()),
            .stream = self.stream and !agent_enabled,
            .agent_enabled = agent_enabled,
            .tool_host = tool_host,
            .tool_snapshot = tool_snapshot,
        };
        return req;
    }

    fn copyTitle(self: *Session, value: []const u8) void {
        self.title_len = @min(value.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], value[0..self.title_len]);
    }

    fn copyBaseUrl(self: *Session, value: []const u8) void {
        self.base_url_len = @min(value.len, self.base_url_buf.len);
        @memcpy(self.base_url_buf[0..self.base_url_len], value[0..self.base_url_len]);
    }

    fn copyApiKey(self: *Session, value: []const u8) void {
        self.api_key_len = @min(value.len, self.api_key_buf.len);
        @memcpy(self.api_key_buf[0..self.api_key_len], value[0..self.api_key_len]);
    }

    fn copyModel(self: *Session, value: []const u8) void {
        self.model_len = @min(value.len, self.model_buf.len);
        @memcpy(self.model_buf[0..self.model_len], value[0..self.model_len]);
    }

    fn copySystemPrompt(self: *Session, value: []const u8) void {
        self.system_prompt_len = @min(value.len, self.system_prompt_buf.len);
        @memcpy(self.system_prompt_buf[0..self.system_prompt_len], value[0..self.system_prompt_len]);
    }

    fn copyReasoningEffort(self: *Session, value: []const u8) void {
        self.reasoning_effort_len = @min(value.len, self.reasoning_effort_buf.len);
        @memcpy(self.reasoning_effort_buf[0..self.reasoning_effort_len], value[0..self.reasoning_effort_len]);
    }

    fn setStatus(self: *Session, value: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.setStatusLocked(value);
    }

    fn setStatusLocked(self: *Session, value: []const u8) void {
        self.status_len = @min(value.len, self.status_buf.len);
        @memcpy(self.status_buf[0..self.status_len], value[0..self.status_len]);
    }
};

fn requestThreadMain(request: *ChatRequest) void {
    const allocator = request.allocator;
    defer request.deinit();

    if (request.agent_enabled) {
        const result = runAgentRequest(request) catch |err| blk: {
            const text = std.fmt.allocPrint(allocator, "Agent request failed: {}", .{err}) catch return;
            break :blk ApiResult{ .content = text };
        };
        defer result.deinit(allocator);
        appendAssistantResult(request.session, result);
        return;
    }

    if (request.stream) {
        runChatRequestStreaming(request) catch |err| {
            const text = std.fmt.allocPrint(allocator, "AI stream failed: {}", .{err}) catch return;
            defer allocator.free(text);
            appendAssistantResult(request.session, .{ .content = text });
        };
        return;
    }

    const result = runChatRequest(request) catch |err| blk: {
        const text = std.fmt.allocPrint(allocator, "AI request failed: {}", .{err}) catch return;
        break :blk ApiResult{ .content = text };
    };
    defer result.deinit(allocator);

    appendAssistantResult(request.session, result);
}

fn runAgentRequest(request: *const ChatRequest) !ApiResult {
    var transcript: std.ArrayListUnmanaged(RequestMessage) = .empty;
    defer {
        for (transcript.items) |msg| msg.deinit(request.allocator);
        transcript.deinit(request.allocator);
    }

    for (request.messages) |msg| {
        try transcript.append(request.allocator, try cloneRequestMessage(request.allocator, msg));
    }

    for (0..MAX_AGENT_ITERATIONS) |_| {
        if (request.session.closing.load(.acquire)) return error.Closing;
        const result = try runChatRequestForMessages(request, transcript.items, true);
        if (result.tool_calls == null or result.tool_calls.?.len == 0) return result;

        if (result.content.len > 0) {
            appendProgressMessage(request.session, result.content) catch {};
        }

        try transcript.append(request.allocator, try assistantToolCallMessage(request.allocator, result.content, result.tool_calls.?));
        for (result.tool_calls.?) |call| {
            const progress = try std.fmt.allocPrint(request.allocator, "running {s} {s}", .{ call.name, call.arguments });
            defer request.allocator.free(progress);
            appendProgressMessage(request.session, progress) catch {};

            const tool_result = try executeToolCall(request, call);
            defer request.allocator.free(tool_result);
            try transcript.append(request.allocator, .{
                .role = .tool,
                .content = try request.allocator.dupe(u8, tool_result),
                .tool_call_id = try request.allocator.dupe(u8, call.id),
            });
        }
        result.deinit(request.allocator);
    }

    return ApiResult{ .content = try request.allocator.dupe(u8, "Agent stopped after reaching the max tool-iteration limit.") };
}

fn cloneRequestMessage(allocator: std.mem.Allocator, msg: RequestMessage) !RequestMessage {
    return .{
        .role = msg.role,
        .content = try allocator.dupe(u8, msg.content),
        .tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null,
        .tool_calls = if (msg.tool_calls) |calls| try cloneToolCalls(allocator, calls) else null,
    };
}

fn cloneToolCalls(allocator: std.mem.Allocator, calls: []const ToolCall) ![]ToolCall {
    const out = try allocator.alloc(ToolCall, calls.len);
    errdefer allocator.free(out);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |call| call.deinit(allocator);
    }
    for (calls, 0..) |call, i| {
        out[i] = .{
            .id = try allocator.dupe(u8, call.id),
            .name = try allocator.dupe(u8, call.name),
            .arguments = try allocator.dupe(u8, call.arguments),
        };
        written += 1;
    }
    return out;
}

fn assistantToolCallMessage(allocator: std.mem.Allocator, content: []const u8, calls: []const ToolCall) !RequestMessage {
    return .{
        .role = .assistant,
        .content = try allocator.dupe(u8, content),
        .tool_calls = try cloneToolCalls(allocator, calls),
    };
}

fn appendAssistantResult(session: *Session, result: ApiResult) void {
    const allocator = session.allocator;
    if (session.closing.load(.acquire)) return;

    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;

    const content = allocator.dupe(u8, result.content) catch {
        session.request_inflight = false;
        session.setStatusLocked("Out of memory");
        return;
    };
    var reasoning_copy: ?[]u8 = null;
    if (result.reasoning) |reasoning| {
        reasoning_copy = allocator.dupe(u8, reasoning) catch null;
    }
    session.messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .reasoning = reasoning_copy,
    }) catch {
        allocator.free(content);
        if (reasoning_copy) |r| allocator.free(r);
        session.request_inflight = false;
        session.setStatusLocked("Out of memory");
        return;
    };
    session.request_inflight = false;
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Ready");
}

fn appendProgressMessage(session: *Session, text: []const u8) !void {
    if (session.closing.load(.acquire)) return error.Closing;
    const allocator = session.allocator;
    const content = try allocator.dupe(u8, text);
    errdefer allocator.free(content);

    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return error.Closing;
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = content,
        .reasoning = null,
    });
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Running tools...");
}

fn beginAssistantStream(session: *Session) !usize {
    const allocator = session.allocator;
    if (session.closing.load(.acquire)) return error.Closing;

    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return error.Closing;

    const content = try allocator.dupe(u8, "");
    errdefer allocator.free(content);
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .reasoning = null,
    });
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Streaming...");
    return session.messages.items.len - 1;
}

fn appendAssistantStreamDelta(session: *Session, message_idx: usize, content_delta: []const u8, reasoning_delta: []const u8) !void {
    if (content_delta.len == 0 and reasoning_delta.len == 0) return;
    const allocator = session.allocator;
    if (session.closing.load(.acquire)) return;

    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;
    if (message_idx >= session.messages.items.len) return error.StreamMessageMissing;

    var msg = &session.messages.items[message_idx];
    if (content_delta.len > 0) {
        const old_len = msg.content.len;
        msg.content = try allocator.realloc(msg.content, old_len + content_delta.len);
        @memcpy(msg.content[old_len..], content_delta);
    }
    if (reasoning_delta.len > 0) {
        if (msg.reasoning) |old_reasoning| {
            const old_len = old_reasoning.len;
            const resized = try allocator.realloc(old_reasoning, old_len + reasoning_delta.len);
            @memcpy(resized[old_len..], reasoning_delta);
            msg.reasoning = resized;
        } else {
            msg.reasoning = try allocator.dupe(u8, reasoning_delta);
        }
    }
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Streaming...");
}

fn finishAssistantStream(session: *Session, message_idx: usize) void {
    if (session.closing.load(.acquire)) return;

    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;
    if (message_idx < session.messages.items.len) {
        const msg = &session.messages.items[message_idx];
        if (msg.content.len == 0 and msg.reasoning == null) {
            msg.content = session.allocator.realloc(msg.content, "No response".len) catch msg.content;
            if (msg.content.len == "No response".len) @memcpy(msg.content, "No response");
        }
    }
    session.request_inflight = false;
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Ready");
}

fn failAssistantStream(session: *Session, message_idx: ?usize, text: []const u8) void {
    if (message_idx) |idx| {
        appendAssistantStreamDelta(session, idx, text, "") catch {};
        finishAssistantStream(session, idx);
        return;
    }

    appendAssistantResult(session, .{ .content = @constCast(text) });
}

fn runChatRequest(request: *const ChatRequest) !ApiResult {
    return runChatRequestForMessages(request, request.messages, request.agent_enabled);
}

fn runChatRequestForMessages(request: *const ChatRequest, messages: []const RequestMessage, include_tools: bool) !ApiResult {
    const allocator = request.allocator;
    const endpoint = try chatEndpoint(allocator, request.base_url);
    defer allocator.free(endpoint);

    const body = try buildRequestJsonForMessages(allocator, request, messages, include_tools);
    defer allocator.free(body);

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.api_key});
    defer allocator.free(bearer);

    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16384,
    };
    defer client.deinit();

    var resp_buf: std.Io.Writer.Allocating = .init(allocator);
    defer resp_buf.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = bearer },
        },
        .response_writer = &resp_buf.writer,
    }) catch return error.RequestFailed;

    var resp_list = resp_buf.toArrayList();
    defer resp_list.deinit(allocator);

    if (result.status != .ok) {
        const trimmed = std.mem.trim(u8, resp_list.items, " \t\r\n");
        if (trimmed.len > 0) return ApiResult{ .content = try allocator.dupe(u8, trimmed) };
        return ApiResult{ .content = try std.fmt.allocPrint(allocator, "HTTP {d}", .{@intFromEnum(result.status)}) };
    }

    return if (request.stream)
        parseApiStreamResponse(allocator, resp_list.items)
    else
        parseApiResponse(allocator, resp_list.items);
}

fn runChatRequestStreaming(request: *const ChatRequest) !void {
    const allocator = request.allocator;
    const endpoint = try chatEndpoint(allocator, request.base_url);
    defer allocator.free(endpoint);

    const body = try buildRequestJson(allocator, request);
    defer allocator.free(body);

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.api_key});
    defer allocator.free(bearer);

    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16384,
    };
    defer client.deinit();

    const uri = try std.Uri.parse(endpoint);
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = bearer },
        },
        .keep_alive = false,
    });
    defer req.deinit();

    try req.sendBodyComplete(body);

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    if (response.head.status != .ok) {
        var err_buf: std.Io.Writer.Allocating = .init(allocator);
        defer err_buf.deinit();
        _ = reader.streamRemaining(&err_buf.writer) catch {};
        var err_list = err_buf.toArrayList();
        defer err_list.deinit(allocator);
        const trimmed = std.mem.trim(u8, err_list.items, " \t\r\n");
        if (trimmed.len > 0) {
            failAssistantStream(request.session, null, trimmed);
        } else {
            const msg = try std.fmt.allocPrint(allocator, "HTTP {d}", .{@intFromEnum(response.head.status)});
            defer allocator.free(msg);
            failAssistantStream(request.session, null, msg);
        }
        return;
    }

    const message_idx = try beginAssistantStream(request.session);
    while (true) {
        if (request.session.closing.load(.acquire)) return;
        const line = reader.takeDelimiter('\n') catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Stream read failed: {}", .{err}) catch return err;
            defer allocator.free(msg);
            failAssistantStream(request.session, message_idx, msg);
            return;
        } orelse break;

        if (try applyApiStreamLineToSession(allocator, request.session, message_idx, line)) break;
    }
    finishAssistantStream(request.session, message_idx);
}

fn chatEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, base_url_raw, " \t\r\n");
    if (trimmed.len == 0) return error.MissingBaseUrl;
    if (std.mem.endsWith(u8, trimmed, "/chat/completions")) {
        return allocator.dupe(u8, trimmed);
    }
    var end = trimmed.len;
    while (end > 0 and trimmed[end - 1] == '/') end -= 1;
    return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{trimmed[0..end]});
}

fn buildRequestJson(allocator: std.mem.Allocator, request: *const ChatRequest) ![]u8 {
    return buildRequestJsonForMessages(allocator, request, request.messages, request.agent_enabled);
}

fn buildRequestJsonForMessages(
    allocator: std.mem.Allocator,
    request: *const ChatRequest,
    messages: []const RequestMessage,
    include_tools: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"model\":");
    try appendJsonString(allocator, &out, request.model);
    try out.appendSlice(allocator, ",\"messages\":[");
    if (request.system_prompt.len > 0) {
        try out.appendSlice(allocator, "{\"role\":\"system\",\"content\":");
        try appendJsonString(allocator, &out, request.system_prompt);
        try out.append(allocator, '}');
        if (messages.len > 0) try out.append(allocator, ',');
    }
    for (messages, 0..) |msg, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"role\":");
        try appendJsonString(allocator, &out, msg.role.apiName());
        try out.appendSlice(allocator, ",\"content\":");
        try appendJsonString(allocator, &out, msg.content);
        if (msg.role == .tool) {
            if (msg.tool_call_id) |id| {
                try out.appendSlice(allocator, ",\"tool_call_id\":");
                try appendJsonString(allocator, &out, id);
            }
        }
        if (msg.tool_calls) |calls| {
            try out.appendSlice(allocator, ",\"tool_calls\":[");
            for (calls, 0..) |call, call_i| {
                if (call_i > 0) try out.append(allocator, ',');
                try out.appendSlice(allocator, "{\"id\":");
                try appendJsonString(allocator, &out, call.id);
                try out.appendSlice(allocator, ",\"type\":\"function\",\"function\":{\"name\":");
                try appendJsonString(allocator, &out, call.name);
                try out.appendSlice(allocator, ",\"arguments\":");
                try appendJsonString(allocator, &out, call.arguments);
                try out.appendSlice(allocator, "}}");
            }
            try out.append(allocator, ']');
        }
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"thinking\":{\"type\":");
    try appendJsonString(allocator, &out, if (request.thinking_enabled) "enabled" else "disabled");
    try out.appendSlice(allocator, "},\"reasoning_effort\":");
    try appendJsonString(allocator, &out, if (request.reasoning_effort.len > 0) request.reasoning_effort else "high");
    try out.appendSlice(allocator, ",\"stream\":");
    try out.appendSlice(allocator, if (request.stream) "true" else "false");
    if (include_tools) {
        try appendToolSchemas(allocator, &out);
    }
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

fn appendToolSchemas(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"tools\":[");
    try out.appendSlice(allocator, toolSchema("terminal_list", "List Phantty terminal surfaces visible to the agent.", "{}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("terminal_snapshot", "Read a bounded text snapshot from one terminal surface or all surfaces.", "{\"surface_id\":{\"type\":\"string\",\"description\":\"Optional surface id from terminal_list.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("powershell_exec", "Run a local PowerShell command on Windows and return stdout, stderr, and exit status.", "{\"command\":{\"type\":\"string\"},\"cwd\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("ssh_session_exec", "Type a command into an already-open SSH terminal surface and observe the resulting terminal snapshot.", "{\"surface_id\":{\"type\":\"string\"},\"command\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}"));
    try out.append(allocator, ']');
}

fn toolSchema(comptime name: []const u8, comptime description: []const u8, comptime properties: []const u8) []const u8 {
    return "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++ "\",\"description\":\"" ++ description ++ "\",\"parameters\":{\"type\":\"object\",\"properties\":" ++ properties ++ ",\"additionalProperties\":false}}}";
}

fn executeToolCall(request: *const ChatRequest, call: ToolCall) ![]u8 {
    if (std.mem.eql(u8, call.name, "terminal_list")) {
        return terminalListTool(request);
    }
    if (std.mem.eql(u8, call.name, "terminal_snapshot")) {
        const args = parseArgs(request.allocator, call.arguments);
        defer if (args) |parsed| parsed.deinit();
        const surface_id = if (args) |parsed| jsonStringArg(parsed.value, "surface_id") else null;
        return terminalSnapshotTool(request, surface_id);
    }
    if (std.mem.eql(u8, call.name, "powershell_exec")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const command = jsonStringArg(args.value, "command") orelse return request.allocator.dupe(u8, "Missing command");
        const cwd = jsonStringArg(args.value, "cwd");
        return powershellExecTool(request, command, cwd);
    }
    if (std.mem.eql(u8, call.name, "ssh_session_exec")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = jsonStringArg(args.value, "surface_id") orelse return request.allocator.dupe(u8, "Missing surface_id");
        const command = jsonStringArg(args.value, "command") orelse return request.allocator.dupe(u8, "Missing command");
        const timeout_ms = jsonIntArg(args.value, "timeout_ms") orelse currentAgentSettings().command_timeout_ms;
        return sshSessionExecTool(request, surface_id, command, timeout_ms);
    }
    return std.fmt.allocPrint(request.allocator, "Unknown tool: {s}", .{call.name});
}

fn parseArgs(allocator: std.mem.Allocator, text: []const u8) ?std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const body = if (trimmed.len == 0) "{}" else trimmed;
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch null;
}

fn jsonStringArg(root: std.json.Value, name: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn jsonIntArg(root: std.json.Value, name: []const u8) ?u32 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .integer => |v| if (v > 0 and v <= std.math.maxInt(u32)) @intCast(v) else null,
        .float => |v| if (v > 0 and v <= @as(f64, @floatFromInt(std.math.maxInt(u32)))) @intFromFloat(v) else null,
        else => null,
    };
}

fn terminalListTool(request: *const ChatRequest) ![]u8 {
    const snapshot = request.tool_snapshot orelse return request.allocator.dupe(u8, "No terminal snapshot host is available.");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(request.allocator);
    try out.print(request.allocator, "active_tab={d}\n", .{snapshot.active_tab});
    for (snapshot.surfaces) |surface| {
        try out.print(request.allocator, "- id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\"\n", .{
            surface.id,
            surface.tab_index,
            surface.focused,
            if (surface.is_ssh) "ssh" else "terminal",
            surface.title,
            surface.cwd,
        });
    }
    return truncateOwned(request.allocator, try out.toOwnedSlice(request.allocator));
}

fn terminalSnapshotTool(request: *const ChatRequest, surface_id: ?[]const u8) ![]u8 {
    const snapshot = request.tool_snapshot orelse return request.allocator.dupe(u8, "No terminal snapshot host is available.");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(request.allocator);

    for (snapshot.surfaces) |surface| {
        if (surface_id) |id| {
            if (!std.mem.eql(u8, surface.id, id)) continue;
        }
        try out.print(request.allocator, "surface={s} title=\"{s}\" kind={s} focused={}\n", .{
            surface.id,
            surface.title,
            if (surface.is_ssh) "ssh" else "terminal",
            surface.focused,
        });
        try out.appendSlice(request.allocator, surface.snapshot);
        try out.appendSlice(request.allocator, "\n---\n");
    }
    if (out.items.len == 0) try out.appendSlice(request.allocator, "No matching terminal surface.");
    return truncateOwned(request.allocator, try out.toOwnedSlice(request.allocator));
}

fn powershellExecTool(request: *const ChatRequest, command: []const u8, cwd: ?[]const u8) ![]u8 {
    const settings = currentAgentSettings();
    if (settings.permission != .full) {
        return deniedResult(request.allocator, command, "local PowerShell execution requires ai-agent-permission = full");
    }
    const warning = if (isDangerousCommand(command)) "warning: command matched a dangerous-command pattern; full-permission allowed it.\n" else "";
    const result = runShellCommand(request.allocator, command, cwd, settings.output_limit) catch |err| {
        return std.fmt.allocPrint(request.allocator, "{s}PowerShell failed: {}", .{ warning, err });
    };
    defer request.allocator.free(result.stdout);
    defer request.allocator.free(result.stderr);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(request.allocator);
    try out.appendSlice(request.allocator, warning);
    try out.print(request.allocator, "exit_code={d}\nstdout:\n{s}\nstderr:\n{s}", .{ result.exit_code, result.stdout, result.stderr });
    return truncateOwned(request.allocator, try out.toOwnedSlice(request.allocator));
}

const ShellResult = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,
};

fn runShellCommand(allocator: std.mem.Allocator, command: []const u8, cwd: ?[]const u8, output_limit: u32) !ShellResult {
    const pwsh_argv = [_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", command };
    if (runArgv(allocator, pwsh_argv[0..], cwd, output_limit)) |result| return result else |_| {}
    const powershell_argv = [_][]const u8{ "powershell.exe", "-NoProfile", "-Command", command };
    if (runArgv(allocator, powershell_argv[0..], cwd, output_limit)) |result| return result else |_| {}
    const cmd_argv = [_][]const u8{ "cmd.exe", "/C", command };
    return runArgv(allocator, cmd_argv[0..], cwd, output_limit);
}

fn runArgv(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, output_limit: u32) !ShellResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = output_limit,
    });
    const exit_code: i32 = switch (result.term) {
        .Exited => |code| @intCast(code),
        .Signal => |sig| -@as(i32, @intCast(sig)),
        .Stopped => |sig| -@as(i32, @intCast(sig)),
        .Unknown => |code| @intCast(code),
    };
    return .{ .exit_code = exit_code, .stdout = result.stdout, .stderr = result.stderr };
}

fn sshSessionExecTool(request: *const ChatRequest, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    const settings = currentAgentSettings();
    if (settings.permission != .full) {
        return deniedResult(request.allocator, command, "SSH PTY injection requires ai-agent-permission = full");
    }
    const snapshot = request.tool_snapshot orelse return request.allocator.dupe(u8, "No terminal snapshot host is available.");
    const host = request.tool_host orelse return request.allocator.dupe(u8, "No terminal tool host is available.");
    const surface = findSurface(snapshot, surface_id) orelse return request.allocator.dupe(u8, "No matching terminal surface.");
    if (!surface.is_ssh) return request.allocator.dupe(u8, "Target surface is not an opened SSH session.");

    const nonce = std.time.milliTimestamp();
    const wrapped = try std.fmt.allocPrint(
        request.allocator,
        "printf '\\n__PHANTTY_AGENT_START_{d}__\\n'; {{ {s}; }} 2>&1; __phantty_agent_status=$?; printf '\\n__PHANTTY_AGENT_END_{d}__:%s\\n' \"$__phantty_agent_status\"\r",
        .{ nonce, command, nonce },
    );
    defer request.allocator.free(wrapped);

    if (!host.writeSurface(host.ctx, surface.ptr, wrapped)) {
        return request.allocator.dupe(u8, "Failed to write to SSH terminal surface.");
    }

    const start_marker = try std.fmt.allocPrint(request.allocator, "__PHANTTY_AGENT_START_{d}__", .{nonce});
    defer request.allocator.free(start_marker);
    const end_marker = try std.fmt.allocPrint(request.allocator, "__PHANTTY_AGENT_END_{d}__", .{nonce});
    defer request.allocator.free(end_marker);

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(@max(timeout_ms, 1000)));
    var last: ?[]u8 = null;
    defer if (last) |text| request.allocator.free(text);

    while (std.time.milliTimestamp() < deadline) {
        if (last) |old| request.allocator.free(old);
        last = host.surfaceSnapshot(host.ctx, request.allocator, surface.ptr) catch null;
        if (last) |text| {
            if (std.mem.indexOf(u8, text, end_marker) != null) {
                return extractSshCommandResult(request.allocator, text, start_marker, end_marker);
            }
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    if (last) |text| {
        return std.fmt.allocPrint(request.allocator, "Timed out waiting for SSH command sentinel.\nLatest snapshot:\n{s}", .{text});
    }
    return request.allocator.dupe(u8, "Timed out waiting for SSH command sentinel.");
}

fn findSurface(snapshot: ToolSnapshot, surface_id: []const u8) ?ToolSurface {
    for (snapshot.surfaces) |surface| {
        if (std.mem.eql(u8, surface.id, surface_id)) return surface;
    }
    return null;
}

fn extractSshCommandResult(allocator: std.mem.Allocator, text: []const u8, start_marker: []const u8, end_marker: []const u8) ![]u8 {
    const start = std.mem.indexOf(u8, text, start_marker) orelse return allocator.dupe(u8, text);
    const body_start = start + start_marker.len;
    const end = std.mem.indexOfPos(u8, text, body_start, end_marker) orelse return allocator.dupe(u8, text[body_start..]);
    return allocator.dupe(u8, std.mem.trim(u8, text[body_start..end], " \t\r\n"));
}

fn deniedResult(allocator: std.mem.Allocator, command: []const u8, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "DENIED by operator (reason: {s})\ncommand: {s}", .{ reason, command });
}

fn truncateOwned(allocator: std.mem.Allocator, text: []u8) ![]u8 {
    const limit = currentAgentSettings().output_limit;
    if (text.len <= limit) return text;
    const truncated = try std.fmt.allocPrint(allocator, "{s}\n...[truncated to {d} bytes]", .{ text[0..limit], limit });
    allocator.free(text);
    return truncated;
}

fn isDangerousCommand(command: []const u8) bool {
    const needles = [_][]const u8{
        "rm -rf",
        "Remove-Item -Recurse -Force",
        "format ",
        "mkfs",
        "shutdown",
        "Stop-Computer",
        "Restart-Computer",
        "git push --force",
        ":(){",
        "del /s",
    };
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(command, needle) != null) return true;
    }
    return false;
}

fn parseApiResponse(allocator: std.mem.Allocator, body: []const u8) !ApiResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyResponse;
        return ApiResult{ .content = try allocator.dupe(u8, trimmed) };
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    const obj = root.object;

    if (obj.get("error")) |err_value| {
        if (err_value == .object) {
            if (err_value.object.get("message")) |message_value| {
                if (message_value == .string) {
                    return ApiResult{ .content = try allocator.dupe(u8, message_value.string) };
                }
            }
        }
        return ApiResult{ .content = try allocator.dupe(u8, "API returned an error") };
    }

    const choices_value = obj.get("choices") orelse return error.MissingChoices;
    if (choices_value != .array or choices_value.array.items.len == 0) return error.MissingChoices;
    const choice = choices_value.array.items[0];
    if (choice != .object) return error.InvalidChoice;
    const message_value = choice.object.get("message") orelse return error.MissingMessage;
    if (message_value != .object) return error.MissingMessage;

    const content = if (message_value.object.get("content")) |content_value|
        if (content_value == .string) content_value.string else ""
    else
        "";
    const reasoning = if (message_value.object.get("reasoning_content")) |reasoning_value|
        if (reasoning_value == .string and reasoning_value.string.len > 0) reasoning_value.string else null
    else
        null;
    const tool_calls = try parseToolCalls(allocator, message_value);

    return .{
        .content = try allocator.dupe(u8, content),
        .reasoning = if (reasoning) |r| try allocator.dupe(u8, r) else null,
        .tool_calls = tool_calls,
    };
}

fn parseToolCalls(allocator: std.mem.Allocator, message_value: std.json.Value) !?[]ToolCall {
    const calls_value = message_value.object.get("tool_calls") orelse return null;
    if (calls_value != .array or calls_value.array.items.len == 0) return null;

    const calls = try allocator.alloc(ToolCall, calls_value.array.items.len);
    errdefer allocator.free(calls);
    var written: usize = 0;
    errdefer {
        for (calls[0..written]) |call| call.deinit(allocator);
    }

    for (calls_value.array.items) |item| {
        if (item != .object) continue;
        const call_obj = item.object;
        const id_value = call_obj.get("id") orelse continue;
        const function_value = call_obj.get("function") orelse continue;
        if (id_value != .string or function_value != .object) continue;
        const name_value = function_value.object.get("name") orelse continue;
        const args_value = function_value.object.get("arguments") orelse continue;
        if (name_value != .string) continue;
        const args = switch (args_value) {
            .string => args_value.string,
            else => "",
        };
        calls[written] = .{
            .id = try allocator.dupe(u8, id_value.string),
            .name = try allocator.dupe(u8, name_value.string),
            .arguments = try allocator.dupe(u8, args),
        };
        written += 1;
    }

    if (written == 0) {
        allocator.free(calls);
        return null;
    }
    return try allocator.realloc(calls, written);
}

fn parseApiStreamResponse(allocator: std.mem.Allocator, body: []const u8) !ApiResult {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    errdefer content.deinit(allocator);
    var reasoning: std.ArrayListUnmanaged(u8) = .empty;
    errdefer reasoning.deinit(allocator);

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;

        const data = std.mem.trim(u8, line["data:".len..], " \t");
        if (data.len == 0) continue;
        if (std.mem.eql(u8, data, "[DONE]")) break;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;
        const obj = root.object;

        if (obj.get("error")) |err_value| {
            if (err_value == .object) {
                if (err_value.object.get("message")) |message_value| {
                    if (message_value == .string) {
                        return ApiResult{ .content = try allocator.dupe(u8, message_value.string) };
                    }
                }
            }
            return ApiResult{ .content = try allocator.dupe(u8, "API returned an error") };
        }

        const choices_value = obj.get("choices") orelse continue;
        if (choices_value != .array or choices_value.array.items.len == 0) continue;
        const choice = choices_value.array.items[0];
        if (choice != .object) continue;
        const delta_value = choice.object.get("delta") orelse continue;
        if (delta_value != .object) continue;

        if (delta_value.object.get("content")) |content_value| {
            if (content_value == .string and content_value.string.len > 0) {
                try content.appendSlice(allocator, content_value.string);
            }
        }
        if (delta_value.object.get("reasoning_content")) |reasoning_value| {
            if (reasoning_value == .string and reasoning_value.string.len > 0) {
                try reasoning.appendSlice(allocator, reasoning_value.string);
            }
        }
    }

    if (content.items.len == 0 and reasoning.items.len == 0) {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyResponse;
        return ApiResult{ .content = try allocator.dupe(u8, trimmed) };
    }

    return .{
        .content = try content.toOwnedSlice(allocator),
        .reasoning = if (reasoning.items.len > 0) try reasoning.toOwnedSlice(allocator) else null,
    };
}

fn applyApiStreamLineToSession(
    allocator: std.mem.Allocator,
    session: *Session,
    message_idx: usize,
    line_raw: []const u8,
) !bool {
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (!std.mem.startsWith(u8, line, "data:")) return false;

    const data = std.mem.trim(u8, line["data:".len..], " \t");
    if (data.len == 0) return false;
    if (std.mem.eql(u8, data, "[DONE]")) return true;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return false;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return false;
    const obj = root.object;

    if (obj.get("error")) |err_value| {
        if (err_value == .object) {
            if (err_value.object.get("message")) |message_value| {
                if (message_value == .string) {
                    try appendAssistantStreamDelta(session, message_idx, message_value.string, "");
                    return true;
                }
            }
        }
        try appendAssistantStreamDelta(session, message_idx, "API returned an error", "");
        return true;
    }

    const choices_value = obj.get("choices") orelse return false;
    if (choices_value != .array or choices_value.array.items.len == 0) return false;
    const choice = choices_value.array.items[0];
    if (choice != .object) return false;
    const delta_value = choice.object.get("delta") orelse return false;
    if (delta_value != .object) return false;

    const content_delta = if (delta_value.object.get("content")) |content_value|
        if (content_value == .string) content_value.string else ""
    else
        "";
    const reasoning_delta = if (delta_value.object.get("reasoning_content")) |reasoning_value|
        if (reasoning_value == .string) reasoning_value.string else ""
    else
        "";
    try appendAssistantStreamDelta(session, message_idx, content_delta, reasoning_delta);
    return false;
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (ch < 0x20) {
                try out.appendSlice(allocator, "\\u00");
                try out.append(allocator, hex[ch >> 4]);
                try out.append(allocator, hex[ch & 0x0f]);
            } else try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}

fn isDeepSeekBaseUrl(base_url: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(base_url, "deepseek.com") != null;
}

test "ai chat endpoint normalization" {
    const allocator = std.testing.allocator;
    const endpoint = try chatEndpoint(allocator, "https://api.deepseek.com/");
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", endpoint);
}

test "ai chat request json includes deepseek thinking mode" {
    const allocator = std.testing.allocator;
    var messages = [_]RequestMessage{.{
        .role = .user,
        .content = @constCast("Hello"),
    }};
    const request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = @constCast("https://api.deepseek.com"),
        .api_key = @constCast("key"),
        .model = @constCast(DEFAULT_MODEL),
        .system_prompt = @constCast(DEFAULT_SYSTEM_PROMPT),
        .messages = messages[0..],
        .thinking_enabled = true,
        .reasoning_effort = @constCast("high"),
        .stream = false,
        .agent_enabled = false,
        .tool_host = null,
        .tool_snapshot = null,
    };
    const json = try buildRequestJson(allocator, &request);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reasoning_effort\":\"high\"") != null);
}

test "ai chat agent request json includes tool schemas" {
    const allocator = std.testing.allocator;
    var messages = [_]RequestMessage{.{
        .role = .user,
        .content = @constCast("List terminals"),
    }};
    const request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = @constCast("https://api.deepseek.com"),
        .api_key = @constCast("key"),
        .model = @constCast(DEFAULT_MODEL),
        .system_prompt = @constCast(DEFAULT_SYSTEM_PROMPT),
        .messages = messages[0..],
        .thinking_enabled = true,
        .reasoning_effort = @constCast("high"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
    };
    const json = try buildRequestJson(allocator, &request);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ssh_session_exec\"") != null);
}

test "ai chat parses OpenAI tool calls" {
    const allocator = std.testing.allocator;
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"terminal_list","arguments":"{}"}}]}}]}
    ;
    const result = try parseApiResponse(allocator, body);
    defer result.deinit(allocator);
    try std.testing.expect(result.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", result.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("terminal_list", result.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("{}", result.tool_calls.?[0].arguments);
}

test "ai chat detects dangerous shell commands" {
    try std.testing.expect(isDangerousCommand("rm -rf /tmp/demo"));
    try std.testing.expect(isDangerousCommand("git push --force origin main"));
    try std.testing.expect(!isDangerousCommand("Get-ComputerInfo | Select-Object OsName"));
}

test "ai chat stream response aggregates content and reasoning chunks" {
    const allocator = std.testing.allocator;
    const body =
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Think\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"ing\",\"content\":null}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"!\"}}]}\n\n" ++
        "data: [DONE]\n\n";

    const result = try parseApiStreamResponse(allocator, body);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("Hello!", result.content);
    try std.testing.expect(result.reasoning != null);
    try std.testing.expectEqualStrings("Thinking", result.reasoning.?);
}
