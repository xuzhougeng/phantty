//! AI Chat session state and OpenAI-compatible API bridge.
//!
//! This is intentionally kept outside Surface/PTY/VT paths: Ghostty keeps
//! terminal surfaces focused on terminal emulation, and Phantty's AI Chat is a
//! Phantty-specific session kind rendered by the window chrome.

const std = @import("std");
const win32_backend = @import("apprt/win32.zig");
const agent_detector = @import("agent_detector.zig");

pub const DEFAULT_NAME = "DeepSeek";
pub const DEFAULT_BASE_URL = "https://api.deepseek.com";
pub const DEFAULT_MODEL = "deepseek-v4-pro";
pub const DEFAULT_SYSTEM_PROMPT = "You are a helpful assistant.";
pub const DEFAULT_THINKING = "enabled";
pub const DEFAULT_REASONING_EFFORT = "high";
pub const DEFAULT_STREAM = "false";
pub const DEFAULT_AGENT = "true";

const DEFAULT_AGENT_TIMEOUT_MS: u32 = 60_000;
const DEFAULT_AGENT_OUTPUT_LIMIT: u32 = 16 * 1024;
const REMOTE_SNAPSHOT_MAX_BYTES: usize = 24 * 1024;

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
    content_collapsed: bool = false,
    content_auto_expand: bool = false,
    tool_grouped: bool = false,
    tool_group_collapsed: bool = false,
    reasoning_collapsed: bool = true,
    reasoning_auto_expand: bool = false,
};

const RequestMessage = struct {
    role: Role,
    content: []u8,
    reasoning: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_calls: ?[]ToolCall = null,

    fn deinit(self: RequestMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.reasoning) |reasoning| allocator.free(reasoning);
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
    is_wsl: bool,
    agent_app: agent_detector.App = .none,
    agent_state: agent_detector.State = .none,
    agent_confidence: u8 = 0,
    ptr: *anyopaque,

    pub fn deinit(self: ToolSurface, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.cwd);
        allocator.free(self.snapshot);
    }

    pub fn clone(self: ToolSurface, allocator: std.mem.Allocator) !ToolSurface {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        const title = try allocator.dupe(u8, self.title);
        errdefer allocator.free(title);
        const cwd = try allocator.dupe(u8, self.cwd);
        errdefer allocator.free(cwd);
        const snapshot = try allocator.dupe(u8, self.snapshot);
        errdefer allocator.free(snapshot);
        return .{
            .id = id,
            .title = title,
            .cwd = cwd,
            .snapshot = snapshot,
            .tab_index = self.tab_index,
            .focused = self.focused,
            .is_ssh = self.is_ssh,
            .is_wsl = self.is_wsl,
            .agent_app = self.agent_app,
            .agent_state = self.agent_state,
            .agent_confidence = self.agent_confidence,
            .ptr = self.ptr,
        };
    }
};

pub const ToolSnapshot = struct {
    surfaces: []ToolSurface,
    active_tab: usize,

    pub fn deinit(self: ToolSnapshot, allocator: std.mem.Allocator) void {
        for (self.surfaces) |surface| surface.deinit(allocator);
        allocator.free(self.surfaces);
    }

    pub fn clone(self: ToolSnapshot, allocator: std.mem.Allocator) !ToolSnapshot {
        const surfaces = try allocator.alloc(ToolSurface, self.surfaces.len);
        errdefer allocator.free(surfaces);
        var written: usize = 0;
        errdefer {
            for (surfaces[0..written]) |surface| surface.deinit(allocator);
        }
        for (self.surfaces) |surface| {
            surfaces[written] = try surface.clone(allocator);
            written += 1;
        }
        return .{
            .surfaces = surfaces,
            .active_tab = self.active_tab,
        };
    }
};

pub const ToolClosedTab = struct {
    tab_index: usize,
    active_tab: usize,
    title: []u8,

    pub fn deinit(self: ToolClosedTab, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
    }
};

pub const ToolHost = struct {
    ctx: *anyopaque,
    collectSnapshot: *const fn (*anyopaque, std.mem.Allocator) anyerror!ToolSnapshot,
    surfaceSnapshot: *const fn (*anyopaque, std.mem.Allocator, *anyopaque) anyerror![]u8,
    writeSurface: *const fn (*anyopaque, *anyopaque, []const u8) bool,
    spawnTab: *const fn (*anyopaque, std.mem.Allocator, []const u8, ?[]const u8) anyerror!ToolSurface,
    closeTab: *const fn (*anyopaque, std.mem.Allocator, ?usize, ?[]const u8, ?[]const u8) anyerror!ToolClosedTab,
    connectSshProfile: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!ToolSurface,
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

pub const ApprovalView = struct {
    tool: []const u8,
    command: []const u8,
    reason: []const u8,
};

var g_agent_mutex: std.Thread.Mutex = .{};
var g_agent_settings: AgentSettings = .{};
threadlocal var g_tool_host: ?ToolHost = null;

pub fn configureAgent(settings: AgentSettings) void {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    g_agent_settings = settings;
}

pub fn setToolHost(host: ?ToolHost) void {
    g_tool_host = host;
}

fn currentAgentSettings() AgentSettings {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    return g_agent_settings;
}

fn currentToolHost() ?ToolHost {
    return g_tool_host;
}

pub fn agentPermission() AgentPermission {
    return currentAgentSettings().permission;
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    messages: std.ArrayListUnmanaged(Message) = .empty,
    input_buf: [8192]u8 = undefined,
    input_len: usize = 0,
    input_select_all: bool = false,
    transcript_select_all: bool = false,
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
    request_stopping: bool = false,
    request_thread: ?std.Thread = null,
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scroll_px: f32 = 0,
    approval_mutex: std.Thread.Mutex = .{},
    approval_cond: std.Thread.Condition = .{},
    approval_pending: bool = false,
    approval_resolved: bool = false,
    approval_allowed: bool = false,
    approval_tool_buf: [64]u8 = undefined,
    approval_tool_len: usize = 0,
    approval_command_buf: [1024]u8 = undefined,
    approval_command_len: usize = 0,
    approval_reason_buf: [256]u8 = undefined,
    approval_reason_len: usize = 0,

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
        self.approval_cond.broadcast();
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
        if (codepoint == 'y' or codepoint == 'Y') {
            if (self.resolveApproval(true)) return;
        }
        if (codepoint == 'n' or codepoint == 'N') {
            if (self.resolveApproval(false)) return;
        }
        if (codepoint < 0x20 or codepoint == 0x7f) return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input_select_all) {
            self.input_len = 0;
            self.input_select_all = false;
        }
        self.transcript_select_all = false;
        if (self.input_len + len > self.input_buf.len) return;
        @memcpy(self.input_buf[self.input_len..][0..len], buf[0..len]);
        self.input_len += len;
    }

    pub fn appendInputText(self: *Session, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input_select_all) {
            self.input_len = 0;
            self.input_select_all = false;
        }
        self.transcript_select_all = false;
        const len = @min(text.len, self.input_buf.len - self.input_len);
        if (len == 0) return;
        @memcpy(self.input_buf[self.input_len..][0..len], text[0..len]);
        self.input_len += len;
    }

    pub fn applyRemoteInput(self: *Session, data: []const u8) void {
        var text_start: usize = 0;
        var i: usize = 0;
        while (i < data.len) {
            const ch = data[i];
            const is_control = ch == '\r' or ch == '\n' or ch == 0x1b or ch == 0x7f or ch == 0x08;
            if (!is_control) {
                i += 1;
                continue;
            }

            if (i > text_start) self.appendInputText(data[text_start..i]);
            switch (ch) {
                '\r', '\n' => self.submit(),
                0x1b => {
                    self.stopRequest();
                    if (i + 1 < data.len and data[i + 1] == '[') {
                        i += 2;
                        while (i < data.len and !std.ascii.isAlphabetic(data[i])) : (i += 1) {}
                    }
                },
                0x7f, 0x08 => self.backspaceInput(),
                else => {},
            }
            i += 1;
            text_start = i;
        }
        if (text_start < data.len) self.appendInputText(data[text_start..]);
    }

    pub fn handleKey(self: *Session, ev: win32_backend.KeyEvent) void {
        if (self.handleApprovalKey(ev)) return;

        if (ev.ctrl and !ev.alt and ev.vk == 0x41) {
            self.selectAll();
            return;
        }
        if (ev.ctrl and !ev.alt and ev.vk == 0x55) {
            self.mutex.lock();
            self.input_len = 0;
            self.clearSelectionLocked();
            self.mutex.unlock();
            return;
        }
        if (ev.ctrl and !ev.alt and ev.vk == 0x4C) {
            self.clearMessages();
            return;
        }

        switch (ev.vk) {
            win32_backend.VK_BACK => self.backspaceInput(),
            win32_backend.VK_ESCAPE => {
                if (self.request_inflight) {
                    self.stopRequest();
                } else {
                    self.clearSelection();
                }
            },
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

    pub fn stopRequest(self: *Session) void {
        self.stop_requested.store(true, .release);

        self.approval_mutex.lock();
        if (self.approval_pending and !self.approval_resolved) {
            self.approval_allowed = false;
            self.approval_resolved = true;
            self.approval_pending = false;
            self.approval_cond.signal();
        }
        self.approval_mutex.unlock();

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.request_inflight) {
            self.stop_requested.store(false, .release);
            self.request_stopping = false;
            return;
        }
        self.request_stopping = true;
        self.setStatusLocked("Stopping...");
    }

    pub fn selectAll(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.input_select_all = self.input_len > 0;
        self.transcript_select_all = !self.input_select_all and self.messages.items.len > 0;
    }

    pub fn clearSelection(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
    }

    pub fn allocClipboardText(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.input_select_all and self.input_len > 0) {
            return allocator.dupe(u8, self.input());
        }
        if (self.messages.items.len > 0) {
            return self.allocTranscriptClipboardTextLocked(allocator);
        }
        if (self.input_len > 0) {
            return allocator.dupe(u8, self.input());
        }
        return allocator.dupe(u8, "");
    }

    pub fn allocRemoteSnapshot(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try appendLimitedSection(allocator, &out, "Model", self.model(), REMOTE_SNAPSHOT_MAX_BYTES);
        try appendLimitedSection(allocator, &out, "Status", self.status(), REMOTE_SNAPSHOT_MAX_BYTES);
        for (self.messages.items) |msg| {
            try appendLimitedSection(allocator, &out, msg.role.label(), msg.content, REMOTE_SNAPSHOT_MAX_BYTES);
            if (msg.reasoning) |reasoning| {
                if (reasoning.len > 0) try appendLimitedSection(allocator, &out, "Reasoning", reasoning, REMOTE_SNAPSHOT_MAX_BYTES);
            }
        }
        if (out.items.len == 0) try out.appendSlice(allocator, "No messages yet.");
        return out.toOwnedSlice(allocator);
    }

    pub fn allocMessageClipboardText(self: *Session, allocator: std.mem.Allocator, message_index: usize) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (message_index >= self.messages.items.len) return allocator.dupe(u8, "");
        return allocator.dupe(u8, self.messages.items[message_index].content);
    }

    pub fn toggleToolMessageCollapsed(self: *Session, message_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (message_index >= self.messages.items.len) return;
        var msg = &self.messages.items[message_index];
        if (msg.role != .tool) return;
        msg.content_collapsed = !msg.content_collapsed;
        msg.content_auto_expand = false;
    }

    pub fn toggleToolGroupCollapsed(self: *Session, message_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (message_index >= self.messages.items.len) return;
        var msg = &self.messages.items[message_index];
        if (msg.role != .tool or !msg.tool_grouped) return;
        msg.tool_group_collapsed = !msg.tool_group_collapsed;
    }

    pub fn toggleReasoningCollapsed(self: *Session, message_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (message_index >= self.messages.items.len) return;
        var msg = &self.messages.items[message_index];
        const reasoning = msg.reasoning orelse return;
        if (reasoning.len == 0) return;
        msg.reasoning_collapsed = !msg.reasoning_collapsed;
        msg.reasoning_auto_expand = false;
    }

    pub fn approvalView(self: *Session) ?ApprovalView {
        self.approval_mutex.lock();
        defer self.approval_mutex.unlock();
        if (!self.approval_pending or self.approval_resolved) return null;
        return .{
            .tool = self.approval_tool_buf[0..self.approval_tool_len],
            .command = self.approval_command_buf[0..self.approval_command_len],
            .reason = self.approval_reason_buf[0..self.approval_reason_len],
        };
    }

    fn handleApprovalKey(self: *Session, ev: win32_backend.KeyEvent) bool {
        const approve = ev.vk == win32_backend.VK_RETURN or ev.vk == 0x59; // Y
        const reject = ev.vk == win32_backend.VK_ESCAPE or ev.vk == 0x4E; // N
        if (!approve and !reject) return false;
        return self.resolveApproval(approve);
    }

    fn resolveApproval(self: *Session, approve: bool) bool {
        self.approval_mutex.lock();
        defer self.approval_mutex.unlock();
        if (!self.approval_pending or self.approval_resolved) return false;
        self.approval_allowed = approve;
        self.approval_resolved = true;
        self.approval_pending = false;
        self.approval_cond.signal();
        return true;
    }

    fn requestApproval(self: *Session, tool: []const u8, command: []const u8, reason: []const u8) bool {
        if (self.stop_requested.load(.acquire)) return false;
        self.approval_mutex.lock();
        self.copyApprovalLocked(tool, command, reason);
        self.approval_pending = true;
        self.approval_resolved = false;
        self.approval_allowed = false;
        self.approval_mutex.unlock();

        self.setStatus("Approval needed");

        self.approval_mutex.lock();
        defer self.approval_mutex.unlock();
        while (!self.approval_resolved and !self.closing.load(.acquire) and !self.stop_requested.load(.acquire)) {
            self.approval_cond.wait(&self.approval_mutex);
        }
        const allowed = self.approval_resolved and self.approval_allowed and !self.closing.load(.acquire) and !self.stop_requested.load(.acquire);
        self.approval_pending = false;
        self.approval_resolved = false;
        self.approval_allowed = false;
        return allowed;
    }

    fn copyApprovalLocked(self: *Session, tool: []const u8, command: []const u8, reason: []const u8) void {
        self.approval_tool_len = @min(tool.len, self.approval_tool_buf.len);
        @memcpy(self.approval_tool_buf[0..self.approval_tool_len], tool[0..self.approval_tool_len]);
        self.approval_command_len = @min(command.len, self.approval_command_buf.len);
        @memcpy(self.approval_command_buf[0..self.approval_command_len], command[0..self.approval_command_len]);
        self.approval_reason_len = @min(reason.len, self.approval_reason_buf.len);
        @memcpy(self.approval_reason_buf[0..self.approval_reason_len], reason[0..self.approval_reason_len]);
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
        self.clearSelectionLocked();
        self.scroll_px = 1_000_000;

        const request = self.buildRequestLocked() catch {
            self.setStatusLocked("Could not prepare request");
            self.mutex.unlock();
            return;
        };

        self.stop_requested.store(false, .release);
        self.request_stopping = false;
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
        self.clearSelectionLocked();
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
        if (self.input_select_all) {
            self.input_len = 0;
            self.clearSelectionLocked();
            return;
        }
        self.transcript_select_all = false;
        if (self.input_len == 0) return;
        self.input_len -= 1;
        while (self.input_len > 0 and (self.input_buf[self.input_len] & 0xC0) == 0x80) {
            self.input_len -= 1;
        }
    }

    fn clearSelectionLocked(self: *Session) void {
        self.input_select_all = false;
        self.transcript_select_all = false;
    }

    fn collapseAutoExpandedDetailsLocked(self: *Session) void {
        var i: usize = 0;
        while (i < self.messages.items.len) {
            if (self.messages.items[i].role != .tool) {
                var msg = &self.messages.items[i];
                if (msg.reasoning_auto_expand) {
                    msg.reasoning_collapsed = true;
                    msg.reasoning_auto_expand = false;
                }
                i += 1;
                continue;
            }

            const group_start = i;
            var group_end = i;
            var has_auto_tool = false;
            while (group_end < self.messages.items.len and self.messages.items[group_end].role == .tool) : (group_end += 1) {
                var msg = &self.messages.items[group_end];
                if (msg.content_auto_expand) {
                    msg.content_collapsed = true;
                    msg.content_auto_expand = false;
                    has_auto_tool = true;
                }
                if (msg.reasoning_auto_expand) {
                    msg.reasoning_collapsed = true;
                    msg.reasoning_auto_expand = false;
                }
            }

            if (has_auto_tool) {
                var j = group_start;
                while (j < group_end) : (j += 1) {
                    self.messages.items[j].tool_grouped = false;
                    self.messages.items[j].tool_group_collapsed = false;
                }
                self.messages.items[group_start].tool_grouped = true;
                self.messages.items[group_start].tool_group_collapsed = true;
            }

            i = group_end;
        }
    }

    fn allocTranscriptClipboardTextLocked(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.messages.items) |msg| {
            try appendClipboardSection(allocator, &out, msg.role.label(), msg.content);
            if (msg.reasoning) |reasoning| {
                if (reasoning.len > 0) try appendClipboardSection(allocator, &out, "Reasoning", reasoning);
            }
        }
        return out.toOwnedSlice(allocator);
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
                .reasoning = if (msg.reasoning) |reasoning| try self.allocator.dupe(u8, reasoning) else null,
            };
            written += 1;
        }

        const settings = currentAgentSettings();
        const agent_enabled = self.agent_enabled or settings.enabled;
        const tool_host = if (agent_enabled) currentToolHost() else null;
        var tool_snapshot: ?ToolSnapshot = null;
        errdefer if (tool_snapshot) |snapshot| snapshot.deinit(self.allocator);
        if (tool_host) |host| {
            // The tab model is thread-local to the UI thread. Capture the agent
            // view before spawning the request worker so tools do not read an
            // empty thread-local copy from the background thread.
            tool_snapshot = host.collectSnapshot(host.ctx, self.allocator) catch null;
        }

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

fn appendClipboardSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    label: []const u8,
    text: []const u8,
) !void {
    if (out.items.len > 0) try out.appendSlice(allocator, "\r\n\r\n");
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, ":\r\n");
    try out.appendSlice(allocator, text);
}

fn appendLimitedSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    label: []const u8,
    text: []const u8,
    max_bytes: usize,
) !void {
    if (out.items.len >= max_bytes) return;
    if (out.items.len > 0) try out.appendSlice(allocator, "\r\n\r\n");
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, ":\r\n");
    if (out.items.len >= max_bytes) return;

    const remaining = max_bytes - out.items.len;
    const take = @min(text.len, remaining);
    try out.appendSlice(allocator, text[0..take]);
    if (take < text.len and out.items.len + 18 <= max_bytes) {
        try out.appendSlice(allocator, "\r\n...[truncated]");
    }
}

fn requestThreadMain(request: *ChatRequest) void {
    const allocator = request.allocator;
    defer request.deinit();

    if (request.agent_enabled) {
        const result = runAgentRequest(request) catch |err| blk: {
            if (requestCancelled(request)) {
                finishStoppedRequest(request.session);
                return;
            }
            const text = std.fmt.allocPrint(allocator, "Agent request failed: {}", .{err}) catch return;
            break :blk ApiResult{ .content = text };
        };
        defer result.deinit(allocator);
        if (requestCancelled(request)) {
            finishStoppedRequest(request.session);
            return;
        }
        appendAssistantResult(request.session, result);
        return;
    }

    if (request.stream) {
        runChatRequestStreaming(request) catch |err| {
            if (requestCancelled(request)) {
                finishStoppedRequest(request.session);
                return;
            }
            const text = std.fmt.allocPrint(allocator, "AI stream failed: {}", .{err}) catch return;
            defer allocator.free(text);
            appendAssistantResult(request.session, .{ .content = text });
        };
        if (requestCancelled(request)) {
            finishStoppedRequest(request.session);
            return;
        }
        return;
    }

    const result = runChatRequest(request) catch |err| blk: {
        if (requestCancelled(request)) {
            finishStoppedRequest(request.session);
            return;
        }
        const text = std.fmt.allocPrint(allocator, "AI request failed: {}", .{err}) catch return;
        break :blk ApiResult{ .content = text };
    };
    defer result.deinit(allocator);

    if (requestCancelled(request)) {
        finishStoppedRequest(request.session);
        return;
    }
    appendAssistantResult(request.session, result);
}

fn requestCancelled(request: *const ChatRequest) bool {
    return request.session.closing.load(.acquire) or request.session.stop_requested.load(.acquire);
}

fn sessionCancelled(session: *Session) bool {
    return session.closing.load(.acquire) or session.stop_requested.load(.acquire);
}

fn finishStoppedRequest(session: *Session) void {
    if (session.closing.load(.acquire)) return;
    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;
    session.request_inflight = false;
    session.request_stopping = false;
    session.stop_requested.store(false, .release);
    session.collapseAutoExpandedDetailsLocked();
    session.setStatusLocked("Stopped");
}

fn runAgentRequest(request: *ChatRequest) !ApiResult {
    var transcript: std.ArrayListUnmanaged(RequestMessage) = .empty;
    defer {
        for (transcript.items) |msg| msg.deinit(request.allocator);
        transcript.deinit(request.allocator);
    }

    for (request.messages) |msg| {
        try transcript.append(request.allocator, try cloneRequestMessage(request.allocator, msg));
    }

    while (true) {
        if (requestCancelled(request)) return error.Canceled;
        const result = try runChatRequestForMessages(request, transcript.items, true);
        if (requestCancelled(request)) {
            result.deinit(request.allocator);
            return error.Canceled;
        }
        if (result.tool_calls == null or result.tool_calls.?.len == 0) return result;
        errdefer result.deinit(request.allocator);

        if (result.content.len > 0) {
            appendProgressMessage(request.session, result.content) catch {};
        }

        try transcript.append(request.allocator, try assistantToolCallMessage(request.allocator, result.content, result.reasoning, result.tool_calls.?));
        for (result.tool_calls.?) |call| {
            if (requestCancelled(request)) return error.Canceled;
            const progress = try std.fmt.allocPrint(request.allocator, "running {s} {s}", .{ call.name, call.arguments });
            defer request.allocator.free(progress);
            appendProgressMessage(request.session, progress) catch {};

            const tool_result = try executeToolCall(request, call);
            defer request.allocator.free(tool_result);
            if (requestCancelled(request)) return error.Canceled;
            try transcript.append(request.allocator, .{
                .role = .tool,
                .content = try request.allocator.dupe(u8, tool_result),
                .tool_call_id = try request.allocator.dupe(u8, call.id),
            });
        }
        result.deinit(request.allocator);
    }
}

fn cloneRequestMessage(allocator: std.mem.Allocator, msg: RequestMessage) !RequestMessage {
    return .{
        .role = msg.role,
        .content = try allocator.dupe(u8, msg.content),
        .reasoning = if (msg.reasoning) |reasoning| try allocator.dupe(u8, reasoning) else null,
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

fn assistantToolCallMessage(allocator: std.mem.Allocator, content: []const u8, reasoning: ?[]const u8, calls: []const ToolCall) !RequestMessage {
    return .{
        .role = .assistant,
        .content = try allocator.dupe(u8, content),
        .reasoning = if (reasoning) |text| try allocator.dupe(u8, text) else null,
        .tool_calls = try cloneToolCalls(allocator, calls),
    };
}

fn appendAssistantResult(session: *Session, result: ApiResult) void {
    const allocator = session.allocator;
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }

    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        session.request_inflight = false;
        session.request_stopping = false;
        session.stop_requested.store(false, .release);
        session.setStatusLocked("Stopped");
        return;
    }

    const content = allocator.dupe(u8, result.content) catch {
        session.request_inflight = false;
        session.collapseAutoExpandedDetailsLocked();
        session.setStatusLocked("Out of memory");
        return;
    };
    var reasoning_copy: ?[]u8 = null;
    if (result.reasoning) |reasoning| {
        reasoning_copy = allocator.dupe(u8, reasoning) catch null;
    }
    const reasoning_visible = if (reasoning_copy) |r| r.len > 0 else false;
    session.messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .reasoning = reasoning_copy,
        .reasoning_collapsed = reasoning_visible,
        .reasoning_auto_expand = false,
    }) catch {
        allocator.free(content);
        if (reasoning_copy) |r| allocator.free(r);
        session.request_inflight = false;
        session.collapseAutoExpandedDetailsLocked();
        session.setStatusLocked("Out of memory");
        return;
    };
    session.request_inflight = false;
    session.collapseAutoExpandedDetailsLocked();
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Ready");
}

fn appendProgressMessage(session: *Session, text: []const u8) !void {
    if (sessionCancelled(session)) return error.Canceled;
    const allocator = session.allocator;
    const content = try allocator.dupe(u8, text);
    errdefer allocator.free(content);

    session.mutex.lock();
    defer session.mutex.unlock();
    if (sessionCancelled(session)) return error.Canceled;
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = content,
        .reasoning = null,
        .content_collapsed = false,
        .content_auto_expand = true,
    });
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Running tools...");
}

fn beginAssistantStream(session: *Session) !usize {
    const allocator = session.allocator;
    if (sessionCancelled(session)) return error.Canceled;

    session.mutex.lock();
    defer session.mutex.unlock();
    if (sessionCancelled(session)) return error.Canceled;

    const content = try allocator.dupe(u8, "");
    errdefer allocator.free(content);
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .reasoning = null,
        .reasoning_collapsed = false,
        .reasoning_auto_expand = true,
    });
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Streaming...");
    return session.messages.items.len - 1;
}

fn appendAssistantStreamDelta(session: *Session, message_idx: usize, content_delta: []const u8, reasoning_delta: []const u8) !void {
    if (content_delta.len == 0 and reasoning_delta.len == 0) return;
    const allocator = session.allocator;
    if (sessionCancelled(session)) return;

    session.mutex.lock();
    defer session.mutex.unlock();
    if (sessionCancelled(session)) return;
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
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }

    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        session.request_inflight = false;
        session.request_stopping = false;
        session.stop_requested.store(false, .release);
        session.setStatusLocked("Stopped");
        return;
    }
    if (message_idx < session.messages.items.len) {
        const msg = &session.messages.items[message_idx];
        if (msg.content.len == 0 and msg.reasoning == null) {
            msg.content = session.allocator.realloc(msg.content, "No response".len) catch msg.content;
            if (msg.content.len == "No response".len) @memcpy(msg.content, "No response");
        }
    }
    session.request_inflight = false;
    session.collapseAutoExpandedDetailsLocked();
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Ready");
}

fn failAssistantStream(session: *Session, message_idx: ?usize, text: []const u8) void {
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }
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
    if (requestCancelled(request)) return error.Canceled;
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
    if (requestCancelled(request)) return error.Canceled;

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
    if (requestCancelled(request)) return error.Canceled;
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
    if (requestCancelled(request)) return error.Canceled;
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
        if (requestCancelled(request)) return error.Canceled;
        const line = reader.takeDelimiter('\n') catch |err| {
            if (requestCancelled(request)) return error.Canceled;
            const msg = std.fmt.allocPrint(allocator, "Stream read failed: {}", .{err}) catch return err;
            defer allocator.free(msg);
            failAssistantStream(request.session, message_idx, msg);
            return;
        } orelse break;

        if (requestCancelled(request)) return error.Canceled;
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
        if (msg.role == .assistant) {
            if (msg.reasoning) |reasoning| {
                if (reasoning.len > 0) {
                    try out.appendSlice(allocator, ",\"reasoning_content\":");
                    try appendJsonString(allocator, &out, reasoning);
                }
            }
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
    try out.appendSlice(allocator, toolSchema("ssh_session_exec", "Run a POSIX shell command in an already-open SSH terminal surface. Use only when the surface is at a shell prompt; for R, Python, Codex, Claude Code, or other REPLs use terminal_repl_exec.", "{\"surface_id\":{\"type\":\"string\"},\"command\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("wsl_session_exec", "Run a POSIX shell command in an already-open WSL terminal surface. Use only when the surface is at a shell prompt; for R, Python, Codex, Claude Code, or other REPLs use terminal_repl_exec.", "{\"surface_id\":{\"type\":\"string\"},\"command\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("terminal_repl_exec", "Send code or text to an already-open interactive REPL/app terminal without shell syntax. Use repl=r for R, repl=python for Python, repl=codex for Codex, repl=claude_code for Claude Code, or repl=plain for raw text input.", "{\"surface_id\":{\"type\":\"string\"},\"repl\":{\"type\":\"string\",\"description\":\"r, python, codex, claude_code, or plain\"},\"code\":{\"type\":\"string\",\"description\":\"Code or plain text to submit.\"},\"timeout_ms\":{\"type\":\"integer\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("ssh_profile_connect", "Create a new tab connected to a saved Phantty SSH server profile by its profile name or host.", "{\"profile_name\":{\"type\":\"string\",\"description\":\"Saved SSH profile name or host to open in a new tab.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("tab_new", "Create a new local terminal tab. Use kind=default, powershell, pwsh, cmd, wsl, or command with an explicit command line.", "{\"kind\":{\"type\":\"string\",\"description\":\"default, powershell, pwsh, cmd, wsl, or command.\"},\"command\":{\"type\":\"string\",\"description\":\"Optional explicit Windows command line; used when kind is command or to override kind.\"}}"));
    try out.append(allocator, ',');
    try out.appendSlice(allocator, toolSchema("tab_close", "Close a terminal tab by zero-based tab_index, surface_id, title, or the active terminal tab when no selector is provided. Cannot close the AI chat tab running the agent.", "{\"tab_index\":{\"type\":\"integer\",\"description\":\"Zero-based tab index from terminal_list.\"},\"tab_number\":{\"type\":\"integer\",\"description\":\"One-based UI tab number, accepted as a convenience.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Surface id from terminal_list.\"},\"title\":{\"type\":\"string\",\"description\":\"Terminal tab title to close, such as CPU2.\"}}"));
    try out.append(allocator, ']');
    try out.appendSlice(allocator, ",\"tool_choice\":\"auto\"");
}

fn toolSchema(comptime name: []const u8, comptime description: []const u8, comptime properties: []const u8) []const u8 {
    return "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++ "\",\"description\":\"" ++ description ++ "\",\"parameters\":{\"type\":\"object\",\"properties\":" ++ properties ++ ",\"additionalProperties\":false}}}";
}

fn executeToolCall(request: *ChatRequest, call: ToolCall) ![]u8 {
    if (requestCancelled(request)) return request.allocator.dupe(u8, "Canceled.");
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
        const timeout_ms = jsonIntArg(args.value, "timeout_ms") orelse currentAgentSettings().command_timeout_ms;
        return powershellExecTool(request, command, cwd, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "ssh_session_exec")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = jsonStringArg(args.value, "surface_id") orelse return request.allocator.dupe(u8, "Missing surface_id");
        const command = jsonStringArg(args.value, "command") orelse return request.allocator.dupe(u8, "Missing command");
        const timeout_ms = jsonIntArg(args.value, "timeout_ms") orelse currentAgentSettings().command_timeout_ms;
        return sshSessionExecTool(request, surface_id, command, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "wsl_session_exec")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = jsonStringArg(args.value, "surface_id") orelse return request.allocator.dupe(u8, "Missing surface_id");
        const command = jsonStringArg(args.value, "command") orelse return request.allocator.dupe(u8, "Missing command");
        const timeout_ms = jsonIntArg(args.value, "timeout_ms") orelse currentAgentSettings().command_timeout_ms;
        return wslSessionExecTool(request, surface_id, command, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "terminal_repl_exec")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = jsonStringArg(args.value, "surface_id") orelse return request.allocator.dupe(u8, "Missing surface_id");
        const repl = jsonStringArg(args.value, "repl") orelse return request.allocator.dupe(u8, "Missing repl");
        const code = jsonStringArg(args.value, "code") orelse return request.allocator.dupe(u8, "Missing code");
        const timeout_ms = jsonIntArg(args.value, "timeout_ms") orelse currentAgentSettings().command_timeout_ms;
        return terminalReplExecTool(request, surface_id, repl, code, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "ssh_profile_connect")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const profile_name = jsonStringArg(args.value, "profile_name") orelse return request.allocator.dupe(u8, "Missing profile_name");
        return sshProfileConnectTool(request, profile_name);
    }
    if (std.mem.eql(u8, call.name, "tab_new")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const kind = jsonStringArg(args.value, "kind") orelse "default";
        const command = jsonStringArg(args.value, "command");
        return tabNewTool(request, kind, command);
    }
    if (std.mem.eql(u8, call.name, "tab_close")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        var tab_index = jsonIndexArg(args.value, "tab_index");
        if (tab_index == null) {
            if (jsonIndexArg(args.value, "tab_number")) |tab_number| {
                if (tab_number > 0) tab_index = tab_number - 1;
            }
        }
        const surface_id = jsonStringArg(args.value, "surface_id");
        const title = jsonStringArg(args.value, "title");
        return tabCloseTool(request, tab_index, surface_id, title);
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

fn jsonIndexArg(root: std.json.Value, name: []const u8) ?usize {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .integer => |v| if (v >= 0 and v <= std.math.maxInt(usize)) @intCast(v) else null,
        .float => |v| if (v >= 0 and v <= @as(f64, @floatFromInt(std.math.maxInt(usize)))) @intFromFloat(v) else null,
        else => null,
    };
}

fn toolSurfaceKind(surface: ToolSurface) []const u8 {
    if (surface.is_ssh) return "ssh";
    if (surface.is_wsl) return "wsl";
    return "terminal";
}

fn terminalListTool(request: *const ChatRequest) ![]u8 {
    const snapshot = collectToolSnapshot(request) catch return request.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(request.allocator);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(request.allocator);
    try out.print(request.allocator, "active_tab={d}\n", .{snapshot.active_tab});
    for (snapshot.surfaces) |surface| {
        try out.print(request.allocator, "- id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\"", .{
            surface.id,
            surface.tab_index,
            surface.focused,
            toolSurfaceKind(surface),
            surface.title,
            surface.cwd,
        });
        if (surface.agent_app != .none) {
            try out.print(request.allocator, " agent={s}:{s} confidence={d}", .{
                surface.agent_app.label(),
                surface.agent_state.label(),
                surface.agent_confidence,
            });
        }
        try out.append(request.allocator, '\n');
    }
    return truncateOwned(request.allocator, try out.toOwnedSlice(request.allocator));
}

fn terminalSnapshotTool(request: *const ChatRequest, surface_id: ?[]const u8) ![]u8 {
    const snapshot = collectToolSnapshot(request) catch return request.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(request.allocator);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(request.allocator);

    for (snapshot.surfaces) |surface| {
        if (surface_id) |id| {
            if (!std.mem.eql(u8, surface.id, id)) continue;
        }
        try out.print(request.allocator, "surface={s} title=\"{s}\" kind={s} focused={}", .{
            surface.id,
            surface.title,
            toolSurfaceKind(surface),
            surface.focused,
        });
        if (surface.agent_app != .none) {
            try out.print(request.allocator, " agent={s}:{s} confidence={d}", .{
                surface.agent_app.label(),
                surface.agent_state.label(),
                surface.agent_confidence,
            });
        }
        try out.append(request.allocator, '\n');
        try out.appendSlice(request.allocator, surface.snapshot);
        try out.appendSlice(request.allocator, "\n---\n");
    }
    if (out.items.len == 0) try out.appendSlice(request.allocator, "No matching terminal surface.");
    return truncateOwned(request.allocator, try out.toOwnedSlice(request.allocator));
}

fn collectToolSnapshot(request: *const ChatRequest) !ToolSnapshot {
    if (request.tool_snapshot) |snapshot| {
        return snapshot.clone(request.allocator);
    }
    const host = request.tool_host orelse return error.NoTerminalSnapshotHost;
    return host.collectSnapshot(host.ctx, request.allocator);
}

fn rememberConnectedSurface(request: *ChatRequest, surface: ToolSurface) !void {
    if (request.tool_snapshot) |*snapshot| {
        for (snapshot.surfaces) |*existing| {
            existing.focused = false;
        }
        const prev_len = snapshot.surfaces.len;
        snapshot.surfaces = try request.allocator.realloc(snapshot.surfaces, prev_len + 1);
        snapshot.surfaces[prev_len] = surface;
        snapshot.active_tab = surface.tab_index;
        return;
    }

    const surfaces = try request.allocator.alloc(ToolSurface, 1);
    surfaces[0] = surface;
    request.tool_snapshot = .{
        .surfaces = surfaces,
        .active_tab = surface.tab_index,
    };
}

fn rememberClosedTab(request: *ChatRequest, closed: ToolClosedTab) !void {
    if (request.tool_snapshot) |*snapshot| {
        var write: usize = 0;
        const closed_active = snapshot.active_tab == closed.tab_index;
        for (snapshot.surfaces) |*surface| {
            if (surface.tab_index == closed.tab_index) {
                surface.deinit(request.allocator);
                continue;
            }
            if (surface.tab_index > closed.tab_index) {
                surface.tab_index -= 1;
            }
            snapshot.surfaces[write] = surface.*;
            write += 1;
        }

        snapshot.surfaces = try request.allocator.realloc(snapshot.surfaces, write);
        snapshot.active_tab = closed.active_tab;

        if (closed_active) {
            var focused_set = false;
            for (snapshot.surfaces) |*surface| {
                if (surface.tab_index == snapshot.active_tab and !focused_set) {
                    surface.focused = true;
                    focused_set = true;
                } else {
                    surface.focused = false;
                }
            }
        } else {
            for (snapshot.surfaces) |*surface| {
                surface.focused = surface.focused and surface.tab_index == snapshot.active_tab;
            }
        }
    }
}

fn powershellExecTool(request: *const ChatRequest, command: []const u8, cwd: ?[]const u8, timeout_ms: u32) ![]u8 {
    const settings = currentAgentSettings();
    if (requestCancelled(request)) return request.allocator.dupe(u8, "Canceled.");
    if (settings.permission != .full) {
        if (!request.session.requestApproval("powershell_exec", command, "Run local PowerShell command")) {
            return deniedResult(request.allocator, command, "operator rejected local PowerShell command");
        }
    }
    const warning = if (isDangerousCommand(command)) "warning: command matched a dangerous-command pattern; full-permission allowed it.\n" else "";
    const result = runShellCommand(request.allocator, command, cwd, settings.output_limit, timeout_ms, request.session) catch |err| {
        return std.fmt.allocPrint(request.allocator, "{s}PowerShell failed: {}", .{ warning, err });
    };
    defer request.allocator.free(result.stdout);
    defer request.allocator.free(result.stderr);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(request.allocator);
    try out.appendSlice(request.allocator, warning);
    if (result.timed_out) try out.appendSlice(request.allocator, "timed_out=true\n");
    try out.print(request.allocator, "exit_code={d}\nstdout:\n{s}\nstderr:\n{s}", .{ result.exit_code, result.stdout, result.stderr });
    return truncateOwned(request.allocator, try out.toOwnedSlice(request.allocator));
}

const ShellResult = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool = false,
};

fn runShellCommand(allocator: std.mem.Allocator, command: []const u8, cwd: ?[]const u8, output_limit: u32, timeout_ms: u32, session: ?*Session) !ShellResult {
    const pwsh_argv = [_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", command };
    if (runArgv(allocator, pwsh_argv[0..], cwd, output_limit, timeout_ms, session)) |result| return result else |_| {}
    const powershell_argv = [_][]const u8{ "powershell.exe", "-NoProfile", "-Command", command };
    if (runArgv(allocator, powershell_argv[0..], cwd, output_limit, timeout_ms, session)) |result| return result else |_| {}
    const cmd_argv = [_][]const u8{ "cmd.exe", "/C", command };
    return runArgv(allocator, cmd_argv[0..], cwd, output_limit, timeout_ms, session);
}

const CaptureOutput = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    max_bytes: usize,
    data: []u8 = &.{},
    truncated: bool = false,
    failed: bool = false,

    fn deinit(self: *CaptureOutput) void {
        self.allocator.free(self.data);
        self.data = &.{};
    }
};

fn runArgv(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, output_limit: u32, timeout_ms: u32, session: ?*Session) !ShellResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;
    try child.spawn();

    var stdout_capture = CaptureOutput{
        .allocator = allocator,
        .file = child.stdout.?,
        .max_bytes = output_limit,
    };
    errdefer stdout_capture.deinit();
    var stderr_capture = CaptureOutput{
        .allocator = allocator,
        .file = child.stderr.?,
        .max_bytes = output_limit,
    };
    errdefer stderr_capture.deinit();

    const stdout_thread = try std.Thread.spawn(.{}, captureOutputThread, .{&stdout_capture});
    const stderr_thread = try std.Thread.spawn(.{}, captureOutputThread, .{&stderr_capture});

    const wait_ms = @max(timeout_ms, 1);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(wait_ms));
    var timed_out = false;
    var canceled = false;
    while (true) {
        const rc = win32_backend.WaitForSingleObject(child.id, 25);
        if (rc == win32_backend.WAIT_OBJECT_0) break;
        if (session) |s| {
            if (sessionCancelled(s)) {
                canceled = true;
                _ = child.kill() catch {};
                break;
            }
        }
        if (std.time.milliTimestamp() >= deadline) {
            timed_out = true;
            _ = child.kill() catch {};
            break;
        }
    }

    stdout_thread.join();
    stderr_thread.join();

    const exit_code: i32 = if (timed_out or canceled) 124 else blk: {
        const term = try child.wait();
        break :blk switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| -@as(i32, @intCast(sig)),
            .Stopped => |sig| -@as(i32, @intCast(sig)),
            .Unknown => |code| @intCast(code),
        };
    };
    return .{
        .exit_code = exit_code,
        .stdout = stdout_capture.data,
        .stderr = stderr_capture.data,
        .timed_out = timed_out or canceled,
    };
}

fn captureOutputThread(capture: *CaptureOutput) void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer {
        if (capture.failed) out.deinit(capture.allocator);
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = capture.file.read(&buf) catch {
            break;
        };
        if (n == 0) break;
        if (out.items.len < capture.max_bytes) {
            const remaining = capture.max_bytes - out.items.len;
            const take = @min(remaining, n);
            out.appendSlice(capture.allocator, buf[0..take]) catch {
                capture.failed = true;
                return;
            };
            if (take < n) capture.truncated = true;
        } else {
            capture.truncated = true;
        }
    }

    if (capture.truncated) {
        out.appendSlice(capture.allocator, "\n...[truncated]\n") catch {};
    }
    capture.data = out.toOwnedSlice(capture.allocator) catch blk: {
        capture.failed = true;
        break :blk &.{};
    };
}

const UnixSessionKind = enum {
    ssh,
    wsl,

    fn toolName(self: UnixSessionKind) []const u8 {
        return switch (self) {
            .ssh => "ssh_session_exec",
            .wsl => "wsl_session_exec",
        };
    }

    fn label(self: UnixSessionKind) []const u8 {
        return switch (self) {
            .ssh => "SSH",
            .wsl => "WSL",
        };
    }

    fn matches(self: UnixSessionKind, surface: ToolSurface) bool {
        return switch (self) {
            .ssh => surface.is_ssh,
            .wsl => surface.is_wsl,
        };
    }
};

fn sshSessionExecTool(request: *const ChatRequest, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    return unixSessionExecTool(request, .ssh, surface_id, command, timeout_ms);
}

fn wslSessionExecTool(request: *const ChatRequest, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    return unixSessionExecTool(request, .wsl, surface_id, command, timeout_ms);
}

const ReplKind = enum {
    r,
    python,
    codex,
    claude_code,
    plain,

    fn parse(value: []const u8) ?ReplKind {
        if (std.ascii.eqlIgnoreCase(value, "r") or std.ascii.eqlIgnoreCase(value, "R")) return .r;
        if (std.ascii.eqlIgnoreCase(value, "python") or std.ascii.eqlIgnoreCase(value, "py")) return .python;
        if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
        if (std.ascii.eqlIgnoreCase(value, "claude") or
            std.ascii.eqlIgnoreCase(value, "claude_code") or
            std.ascii.eqlIgnoreCase(value, "claude-code"))
        {
            return .claude_code;
        }
        if (std.ascii.eqlIgnoreCase(value, "plain") or std.ascii.eqlIgnoreCase(value, "text")) return .plain;
        return null;
    }

    fn label(self: ReplKind) []const u8 {
        return switch (self) {
            .r => "R",
            .python => "Python",
            .codex => "Codex",
            .claude_code => "Claude Code",
            .plain => "plain",
        };
    }
};

fn terminalReplExecTool(request: *const ChatRequest, surface_id: []const u8, repl_name: []const u8, code: []const u8, timeout_ms: u32) ![]u8 {
    const repl = ReplKind.parse(repl_name) orelse return std.fmt.allocPrint(request.allocator, "Unsupported repl \"{s}\". Use r, python, codex, claude_code, or plain.", .{repl_name});
    const settings = currentAgentSettings();
    if (requestCancelled(request)) return request.allocator.dupe(u8, "Canceled.");
    if (settings.permission != .full) {
        var reason_buf: [96]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "Type input into opened {s} REPL/app terminal", .{repl.label()}) catch "Type input into terminal";
        if (!request.session.requestApproval("terminal_repl_exec", code, reason)) {
            return deniedResult(request.allocator, code, "operator rejected REPL terminal input");
        }
    }

    const snapshot = collectToolSnapshot(request) catch return request.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(request.allocator);
    const host = request.tool_host orelse return request.allocator.dupe(u8, "No terminal tool host is available.");
    const surface = findSurface(snapshot, surface_id) orelse return request.allocator.dupe(u8, "No matching terminal surface.");

    return switch (repl) {
        .r => rSessionEvalTool(request, host, surface, code, timeout_ms),
        .python => pythonSessionEvalTool(request, host, surface, code, timeout_ms),
        .codex, .claude_code => plainReplInputTool(request, host, surface, code, timeout_ms),
        .plain => plainReplInputTool(request, host, surface, code, timeout_ms),
    };
}

fn plainReplInputTool(request: *const ChatRequest, host: ToolHost, surface: ToolSurface, text: []const u8, timeout_ms: u32) ![]u8 {
    const input = try std.fmt.allocPrint(request.allocator, "{s}\r", .{text});
    defer request.allocator.free(input);

    if (!host.writeSurface(host.ctx, surface.ptr, input)) {
        return request.allocator.dupe(u8, "Failed to write to terminal surface.");
    }

    const wait_ms = @min(@max(timeout_ms, 500), 5000);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(wait_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (requestCancelled(request)) return request.allocator.dupe(u8, "Canceled.");
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const latest = host.surfaceSnapshot(host.ctx, request.allocator, surface.ptr) catch return request.allocator.dupe(u8, "Input sent; failed to read terminal snapshot.");
    return truncateOwned(request.allocator, latest);
}

fn rSessionEvalTool(request: *const ChatRequest, host: ToolHost, surface: ToolSurface, code: []const u8, timeout_ms: u32) ![]u8 {
    const nonce = std.time.milliTimestamp();
    const code_literal = try rStringLiteral(request.allocator, code);
    defer request.allocator.free(code_literal);

    const wrapped = try std.fmt.allocPrint(
        request.allocator,
        "cat(\"\\n__PHANTTY_AGENT_START_{d}__\\n\", sep=\"\")\n.phantty_agent_status <- 0L\n.phantty_agent_code <- {s}\ntryCatch({{\n  eval(parse(text=.phantty_agent_code), envir=.GlobalEnv)\n}}, error=function(e) {{\n  .phantty_agent_status <<- 1L\n  message(\"Error: \", conditionMessage(e))\n}})\ncat(\"\\n__PHANTTY_AGENT_END_{d}__:\", .phantty_agent_status, \"\\n\", sep=\"\")\nrm(.phantty_agent_status, .phantty_agent_code)\r",
        .{ nonce, code_literal, nonce },
    );
    defer request.allocator.free(wrapped);

    if (!host.writeSurface(host.ctx, surface.ptr, wrapped)) {
        return request.allocator.dupe(u8, "Failed to write to R terminal surface.");
    }

    const start_marker = try std.fmt.allocPrint(request.allocator, "__PHANTTY_AGENT_START_{d}__", .{nonce});
    defer request.allocator.free(start_marker);
    const end_marker = try std.fmt.allocPrint(request.allocator, "__PHANTTY_AGENT_END_{d}__", .{nonce});
    defer request.allocator.free(end_marker);
    return waitForSentinelResult(request, host, surface, "R", start_marker, end_marker, timeout_ms);
}

fn pythonSessionEvalTool(request: *const ChatRequest, host: ToolHost, surface: ToolSurface, code: []const u8, timeout_ms: u32) ![]u8 {
    const nonce = std.time.milliTimestamp();
    const code_literal = try pythonStringLiteral(request.allocator, code);
    defer request.allocator.free(code_literal);

    const wrapper = try std.fmt.allocPrint(
        request.allocator,
        "print(\"\\\\n__PHANTTY_AGENT_START_{d}__\")\n__phantty_agent_status = 0\n__phantty_agent_code = {s}\ntry:\n    exec(__phantty_agent_code, globals())\nexcept Exception:\n    __phantty_agent_status = 1\n    import traceback\n    traceback.print_exc()\nprint(\"\\\\n__PHANTTY_AGENT_END_{d}__:%s\" % __phantty_agent_status)\ndel __phantty_agent_status, __phantty_agent_code",
        .{ nonce, code_literal, nonce },
    );
    defer request.allocator.free(wrapper);

    const wrapper_literal = try pythonStringLiteral(request.allocator, wrapper);
    defer request.allocator.free(wrapper_literal);
    const wrapped = try std.fmt.allocPrint(request.allocator, "exec({s})\r", .{wrapper_literal});
    defer request.allocator.free(wrapped);

    if (!host.writeSurface(host.ctx, surface.ptr, wrapped)) {
        return request.allocator.dupe(u8, "Failed to write to Python terminal surface.");
    }

    const start_marker = try std.fmt.allocPrint(request.allocator, "__PHANTTY_AGENT_START_{d}__", .{nonce});
    defer request.allocator.free(start_marker);
    const end_marker = try std.fmt.allocPrint(request.allocator, "__PHANTTY_AGENT_END_{d}__", .{nonce});
    defer request.allocator.free(end_marker);
    return waitForSentinelResult(request, host, surface, "Python", start_marker, end_marker, timeout_ms);
}

fn rStringLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return doubleQuotedStringLiteral(allocator, text);
}

fn pythonStringLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return doubleQuotedStringLiteral(allocator, text);
}

fn doubleQuotedStringLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn unixSessionExecTool(request: *const ChatRequest, kind: UnixSessionKind, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    const settings = currentAgentSettings();
    if (requestCancelled(request)) return request.allocator.dupe(u8, "Canceled.");
    if (settings.permission != .full) {
        var reason_buf: [64]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "Type command into opened {s} terminal", .{kind.label()}) catch "Type command into terminal";
        if (!request.session.requestApproval(kind.toolName(), command, reason)) {
            return deniedResult(request.allocator, command, if (kind == .ssh) "operator rejected SSH PTY command" else "operator rejected WSL PTY command");
        }
    }
    const snapshot = collectToolSnapshot(request) catch return request.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(request.allocator);
    const host = request.tool_host orelse return request.allocator.dupe(u8, "No terminal tool host is available.");
    const surface = findSurface(snapshot, surface_id) orelse return request.allocator.dupe(u8, "No matching terminal surface.");
    if (!kind.matches(surface)) {
        return std.fmt.allocPrint(request.allocator, "Target surface is not an opened {s} session.", .{kind.label()});
    }

    const nonce = std.time.milliTimestamp();
    const wrapped = try std.fmt.allocPrint(
        request.allocator,
        "printf '\\n__PHANTTY_AGENT_START_{d}__\\n'; {{ {s}; }} 2>&1; __phantty_agent_status=$?; printf '\\n__PHANTTY_AGENT_END_{d}__:%s\\n' \"$__phantty_agent_status\"\r",
        .{ nonce, command, nonce },
    );
    defer request.allocator.free(wrapped);

    if (!host.writeSurface(host.ctx, surface.ptr, wrapped)) {
        return std.fmt.allocPrint(request.allocator, "Failed to write to {s} terminal surface.", .{kind.label()});
    }

    const start_marker = try std.fmt.allocPrint(request.allocator, "__PHANTTY_AGENT_START_{d}__", .{nonce});
    defer request.allocator.free(start_marker);
    const end_marker = try std.fmt.allocPrint(request.allocator, "__PHANTTY_AGENT_END_{d}__", .{nonce});
    defer request.allocator.free(end_marker);
    return waitForSentinelResult(request, host, surface, kind.label(), start_marker, end_marker, timeout_ms);
}

fn waitForSentinelResult(
    request: *const ChatRequest,
    host: ToolHost,
    surface: ToolSurface,
    label: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
    timeout_ms: u32,
) ![]u8 {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(@max(timeout_ms, 1000)));
    var last: ?[]u8 = null;
    defer if (last) |text| request.allocator.free(text);

    while (std.time.milliTimestamp() < deadline) {
        if (requestCancelled(request)) return request.allocator.dupe(u8, "Canceled.");
        if (last) |old| request.allocator.free(old);
        last = host.surfaceSnapshot(host.ctx, request.allocator, surface.ptr) catch null;
        if (last) |text| {
            if (std.mem.indexOf(u8, text, end_marker) != null) {
                return extractUnixCommandResult(request.allocator, text, start_marker, end_marker);
            }
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    if (last) |text| {
        return std.fmt.allocPrint(request.allocator, "Timed out waiting for {s} command sentinel.\nLatest snapshot:\n{s}", .{ label, text });
    }
    return std.fmt.allocPrint(request.allocator, "Timed out waiting for {s} command sentinel.", .{label});
}

fn sshProfileConnectTool(request: *ChatRequest, profile_name: []const u8) ![]u8 {
    const settings = currentAgentSettings();
    if (requestCancelled(request)) return request.allocator.dupe(u8, "Canceled.");
    if (settings.permission != .full) {
        if (!request.session.requestApproval("ssh_profile_connect", profile_name, "Open saved SSH server in a new tab")) {
            return deniedResult(request.allocator, profile_name, "operator rejected saved SSH profile connection");
        }
    }

    const host = request.tool_host orelse return request.allocator.dupe(u8, "No terminal tool host is available.");
    var surface = host.connectSshProfile(host.ctx, request.allocator, profile_name) catch |err| switch (err) {
        error.ProfileNotFound => return std.fmt.allocPrint(request.allocator, "No saved SSH profile matched \"{s}\".", .{profile_name}),
        else => return std.fmt.allocPrint(request.allocator, "Failed to connect saved SSH profile \"{s}\": {}", .{ profile_name, err }),
    };
    var surface_owned = true;
    errdefer if (surface_owned) surface.deinit(request.allocator);

    const out = try std.fmt.allocPrint(
        request.allocator,
        "connected profile=\"{s}\" surface_id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\"",
        .{
            profile_name,
            surface.id,
            surface.tab_index,
            surface.focused,
            toolSurfaceKind(surface),
            surface.title,
            surface.cwd,
        },
    );
    errdefer request.allocator.free(out);

    try rememberConnectedSurface(request, surface);
    surface_owned = false;
    return truncateOwned(request.allocator, out);
}

fn tabNewTool(request: *ChatRequest, kind: []const u8, command: ?[]const u8) ![]u8 {
    const settings = currentAgentSettings();
    if (requestCancelled(request)) return request.allocator.dupe(u8, "Canceled.");

    const trimmed_kind = std.mem.trim(u8, kind, " \t\r\n");
    const command_for_approval = command orelse trimmed_kind;
    if (settings.permission != .full) {
        if (!request.session.requestApproval("tab_new", command_for_approval, "Open a new local terminal tab")) {
            return deniedResult(request.allocator, command_for_approval, "operator rejected new tab creation");
        }
    }

    const host = request.tool_host orelse return request.allocator.dupe(u8, "No terminal tool host is available.");
    var surface = host.spawnTab(host.ctx, request.allocator, trimmed_kind, command) catch |err| switch (err) {
        error.CommandRequired => return request.allocator.dupe(u8, "tab_new kind=command requires a non-empty command."),
        error.InvalidTabKind => return std.fmt.allocPrint(request.allocator, "Unsupported tab kind \"{s}\". Use default, powershell, pwsh, cmd, wsl, or command.", .{trimmed_kind}),
        else => return std.fmt.allocPrint(request.allocator, "Failed to create new tab: {}", .{err}),
    };
    var surface_owned = true;
    errdefer if (surface_owned) surface.deinit(request.allocator);

    const out = try std.fmt.allocPrint(
        request.allocator,
        "created tab kind={s} surface_id={s} tab={d} focused={} surface_kind={s} title=\"{s}\" cwd=\"{s}\"",
        .{
            if (trimmed_kind.len > 0) trimmed_kind else "default",
            surface.id,
            surface.tab_index,
            surface.focused,
            toolSurfaceKind(surface),
            surface.title,
            surface.cwd,
        },
    );
    errdefer request.allocator.free(out);

    try rememberConnectedSurface(request, surface);
    surface_owned = false;
    return truncateOwned(request.allocator, out);
}

fn tabCloseTool(request: *ChatRequest, tab_index: ?usize, surface_id: ?[]const u8, title: ?[]const u8) ![]u8 {
    const settings = currentAgentSettings();
    if (requestCancelled(request)) return request.allocator.dupe(u8, "Canceled.");

    var selector_buf: [256]u8 = undefined;
    const selector = if (surface_id) |id|
        std.fmt.bufPrint(&selector_buf, "surface_id={s}", .{id}) catch "surface_id"
    else if (title) |text|
        std.fmt.bufPrint(&selector_buf, "title={s}", .{text}) catch "title"
    else if (tab_index) |idx|
        std.fmt.bufPrint(&selector_buf, "tab_index={d}", .{idx}) catch "tab_index"
    else
        "active terminal tab";

    if (settings.permission != .full) {
        if (!request.session.requestApproval("tab_close", selector, "Close a terminal tab")) {
            return deniedResult(request.allocator, selector, "operator rejected tab close");
        }
    }

    const host = request.tool_host orelse return request.allocator.dupe(u8, "No terminal tool host is available.");
    var closed = host.closeTab(host.ctx, request.allocator, tab_index, surface_id, title) catch |err| switch (err) {
        error.TabNotFound => return request.allocator.dupe(u8, "No matching terminal tab was found."),
        error.CannotCloseAiChatTab => return request.allocator.dupe(u8, "Refusing to close an AI Chat tab from the agent."),
        error.LastTab => return request.allocator.dupe(u8, "Refusing to close the last remaining tab."),
        else => return std.fmt.allocPrint(request.allocator, "Failed to close tab: {}", .{err}),
    };
    defer closed.deinit(request.allocator);

    try rememberClosedTab(request, closed);

    const out = try std.fmt.allocPrint(
        request.allocator,
        "closed tab={d} title=\"{s}\" active_tab={d}",
        .{ closed.tab_index, closed.title, closed.active_tab },
    );
    return truncateOwned(request.allocator, out);
}

fn findSurface(snapshot: ToolSnapshot, surface_id: []const u8) ?ToolSurface {
    for (snapshot.surfaces) |surface| {
        if (std.mem.eql(u8, surface.id, surface_id)) return surface;
    }
    return null;
}

fn extractUnixCommandResult(allocator: std.mem.Allocator, text: []const u8, start_marker: []const u8, end_marker: []const u8) ![]u8 {
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
    var i: usize = 0;
    while (i < value.len) {
        const ch = value[i];
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
            } else if (ch < 0x80) {
                try out.append(allocator, ch);
            } else {
                const len = std.unicode.utf8ByteSequenceLength(ch) catch {
                    try out.appendSlice(allocator, "\\ufffd");
                    i += 1;
                    continue;
                };
                if (i + len > value.len) {
                    try out.appendSlice(allocator, "\\ufffd");
                    i += 1;
                    continue;
                }
                _ = std.unicode.utf8Decode(value[i .. i + len]) catch {
                    try out.appendSlice(allocator, "\\ufffd");
                    i += 1;
                    continue;
                };
                try out.appendSlice(allocator, value[i .. i + len]);
                i += len;
                continue;
            },
        }
        i += 1;
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ssh_session_exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"wsl_session_exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"terminal_repl_exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ssh_profile_connect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tab_new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tab_close\"") != null);
}

test "ai chat request json replays assistant reasoning content" {
    const allocator = std.testing.allocator;
    var messages = [_]RequestMessage{.{
        .role = .assistant,
        .content = @constCast("I will inspect the system."),
        .reasoning = @constCast("Need system info before answering."),
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reasoning_content\":\"Need system info before answering.\"") != null);
}

test "ai chat request json replaces invalid utf8 bytes" {
    const allocator = std.testing.allocator;
    const bad = [_]u8{ 'o', 'k', ' ', 0xff, ' ', 0xc3 };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try appendJsonString(allocator, &out, bad[0..]);
    try std.testing.expectEqualStrings("\"ok \\ufffd \\ufffd\"", out.items);
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

test "ai chat tools prefer request-local terminal snapshot" {
    const allocator = std.testing.allocator;
    var surfaces = try allocator.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "surface-1"),
        .title = try allocator.dupe(u8, "PowerShell"),
        .cwd = try allocator.dupe(u8, "C:\\Users"),
        .snapshot = try allocator.dupe(u8, "PS C:\\Users>"),
        .tab_index = 1,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    const cached_snapshot = ToolSnapshot{
        .surfaces = surfaces,
        .active_tab = 1,
    };
    defer cached_snapshot.deinit(allocator);

    var messages = [_]RequestMessage{.{
        .role = .user,
        .content = @constCast("list terminals"),
    }};
    const request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = @constCast(""),
        .api_key = @constCast(""),
        .model = @constCast(""),
        .system_prompt = @constCast(""),
        .messages = messages[0..],
        .thinking_enabled = true,
        .reasoning_effort = @constCast(""),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = cached_snapshot,
    };

    const snapshot = try collectToolSnapshot(&request);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.active_tab);
    try std.testing.expectEqual(@as(usize, 1), snapshot.surfaces.len);
    try std.testing.expectEqualStrings("surface-1", snapshot.surfaces[0].id);
    try std.testing.expect(snapshot.surfaces[0].id.ptr != cached_snapshot.surfaces[0].id.ptr);
}

test "ai chat R string literal escapes code for REPL eval" {
    const allocator = std.testing.allocator;
    const literal = try rStringLiteral(allocator, "print(\"hello\")\npath <- \"C:\\\\tmp\"");
    defer allocator.free(literal);

    try std.testing.expectEqualStrings("\"print(\\\"hello\\\")\\npath <- \\\"C:\\\\\\\\tmp\\\"\"", literal);
}

test "ai chat REPL kind parses Python Codex and Claude Code aliases" {
    try std.testing.expectEqual(ReplKind.python, ReplKind.parse("python").?);
    try std.testing.expectEqual(ReplKind.python, ReplKind.parse("py").?);
    try std.testing.expectEqual(ReplKind.codex, ReplKind.parse("codex").?);
    try std.testing.expectEqual(ReplKind.claude_code, ReplKind.parse("claude").?);
    try std.testing.expectEqual(ReplKind.claude_code, ReplKind.parse("claude-code").?);
}

test "ai chat Python string literal escapes code for REPL eval" {
    const allocator = std.testing.allocator;
    const literal = try pythonStringLiteral(allocator, "print(\"hello\")\npath = \"C:\\\\tmp\"");
    defer allocator.free(literal);

    try std.testing.expectEqualStrings("\"print(\\\"hello\\\")\\npath = \\\"C:\\\\\\\\tmp\\\"\"", literal);
}

test "ai chat ctrl a selects input and replacement clears selection" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("hello");
    session.handleKey(.{ .vk = 0x41, .ctrl = true, .shift = false, .alt = false });
    try std.testing.expect(session.input_select_all);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("hello", copied);

    session.handleChar('x');
    try std.testing.expect(!session.input_select_all);
    try std.testing.expectEqualStrings("x", session.input());
}

test "ai chat remote snapshot omits local draft input" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "DeepSeek",
        DEFAULT_BASE_URL,
        "key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        DEFAULT_THINKING,
        DEFAULT_REASONING_EFFORT,
        DEFAULT_STREAM,
        DEFAULT_AGENT,
    );
    defer session.deinit();

    session.appendInputText("local draft only");
    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "local draft only") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Draft") == null);
}

test "ai chat clipboard text exports transcript when input is empty" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| {
            allocator.free(msg.content);
            if (msg.reasoning) |reasoning| allocator.free(reasoning);
        }
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "status?"),
        .reasoning = null,
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "ready"),
        .reasoning = try allocator.dupe(u8, "checked state"),
    });

    session.handleKey(.{ .vk = 0x41, .ctrl = true, .shift = false, .alt = false });
    try std.testing.expect(session.transcript_select_all);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expect(std.mem.indexOf(u8, copied, "You:\r\nstatus?") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied, "AI:\r\nready") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied, "Reasoning:\r\nchecked state") != null);
}

test "ai chat message clipboard exports one bubble" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| {
            allocator.free(msg.content);
            if (msg.reasoning) |reasoning| allocator.free(reasoning);
        }
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "first"),
        .reasoning = null,
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "second"),
        .reasoning = try allocator.dupe(u8, "not part of the bubble"),
    });

    const copied = try session.allocMessageClipboardText(allocator, 1);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("second", copied);
}

test "ai chat stop request suppresses late assistant result" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| {
            allocator.free(msg.content);
            if (msg.reasoning) |reasoning| allocator.free(reasoning);
        }
        session.messages.deinit(allocator);
    }

    session.request_inflight = true;
    session.stopRequest();
    try std.testing.expect(session.request_stopping);
    try std.testing.expectEqualStrings("Stopping...", session.status());

    appendAssistantResult(&session, .{ .content = @constCast("late result") });
    try std.testing.expect(!session.request_inflight);
    try std.testing.expect(!session.request_stopping);
    try std.testing.expect(!session.stop_requested.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqualStrings("Stopped", session.status());
}

test "ai chat escape stops in-flight request" {
    var session = Session{ .allocator = std.testing.allocator };
    session.request_inflight = true;

    session.handleKey(.{ .vk = win32_backend.VK_ESCAPE, .ctrl = false, .shift = false, .alt = false });

    try std.testing.expect(session.request_stopping);
    try std.testing.expect(session.stop_requested.load(.acquire));
    try std.testing.expectEqualStrings("Stopping...", session.status());
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

test "ai chat collapse helper only closes auto-expanded details" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| {
            allocator.free(msg.content);
            if (msg.reasoning) |reasoning| allocator.free(reasoning);
        }
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "running powershell_exec {\"command\":\"Get-ChildItem\"}"),
        .content_collapsed = false,
        .content_auto_expand = true,
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "done"),
        .reasoning = try allocator.dupe(u8, "inspect the filesystem first"),
        .reasoning_collapsed = false,
        .reasoning_auto_expand = true,
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "manual"),
        .content_collapsed = false,
        .content_auto_expand = false,
    });

    session.mutex.lock();
    session.collapseAutoExpandedDetailsLocked();
    session.mutex.unlock();

    try std.testing.expect(session.messages.items[0].content_collapsed);
    try std.testing.expect(!session.messages.items[0].content_auto_expand);
    try std.testing.expect(session.messages.items[1].reasoning_collapsed);
    try std.testing.expect(!session.messages.items[1].reasoning_auto_expand);
    try std.testing.expect(!session.messages.items[2].content_collapsed);
}

test "ai chat collapse helper creates a collapsed tool group" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| {
            allocator.free(msg.content);
            if (msg.reasoning) |reasoning| allocator.free(reasoning);
        }
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "running terminal_list {}"),
        .content_collapsed = false,
        .content_auto_expand = true,
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "running terminal_snapshot {\"surface_id\":\"1\"}"),
        .content_collapsed = false,
        .content_auto_expand = true,
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "done"),
    });

    session.mutex.lock();
    session.collapseAutoExpandedDetailsLocked();
    session.mutex.unlock();

    try std.testing.expect(session.messages.items[0].tool_grouped);
    try std.testing.expect(session.messages.items[0].tool_group_collapsed);
    try std.testing.expect(session.messages.items[0].content_collapsed);
    try std.testing.expect(!session.messages.items[0].content_auto_expand);
    try std.testing.expect(!session.messages.items[1].tool_grouped);
    try std.testing.expect(!session.messages.items[1].tool_group_collapsed);
    try std.testing.expect(session.messages.items[1].content_collapsed);
    try std.testing.expect(!session.messages.items[1].content_auto_expand);

    session.toggleToolGroupCollapsed(0);
    try std.testing.expect(!session.messages.items[0].tool_group_collapsed);
    session.toggleToolGroupCollapsed(1);
    try std.testing.expect(!session.messages.items[0].tool_group_collapsed);
}
