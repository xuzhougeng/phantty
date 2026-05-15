//! AI Chat session state and OpenAI-compatible API bridge.
//!
//! This is intentionally kept outside Surface/PTY/VT paths: Ghostty keeps
//! terminal surfaces focused on terminal emulation, and Phantty's AI Chat is a
//! Phantty-specific session kind rendered by the window chrome.

const std = @import("std");
const win32_backend = @import("apprt/win32.zig");
const agent_detector = @import("agent_detector.zig");
const agent_history = @import("agent_history.zig");

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
const INPUT_PROMPT_MAX_BYTES: usize = 64 * 1024;

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
    usage_footer: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    replay_to_model: bool = false,
    content_collapsed: bool = false,
    content_auto_expand: bool = false,
    reasoning_collapsed: bool = true,
    reasoning_auto_expand: bool = false,

    fn deinit(self: Message, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.reasoning) |reasoning| allocator.free(reasoning);
        if (self.usage_footer) |footer| allocator.free(footer);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.tool_name) |name| allocator.free(name);
    }
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
    started_ms: i64,

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
    usage: ?ApiUsage = null,

    fn deinit(self: ApiResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.reasoning) |reasoning| allocator.free(reasoning);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
    }
};

pub const ApiUsage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    prompt_cache_hit_tokens: u64 = 0,
    prompt_cache_miss_tokens: u64 = 0,
    total_tokens: u64 = 0,

    fn add(self: *ApiUsage, other: ApiUsage) void {
        self.prompt_tokens += other.prompt_tokens;
        self.completion_tokens += other.completion_tokens;
        self.prompt_cache_hit_tokens += other.prompt_cache_hit_tokens;
        self.prompt_cache_miss_tokens += other.prompt_cache_miss_tokens;
        self.total_tokens += other.total_tokens;
    }
};

pub const ApprovalView = struct {
    tool: []const u8,
    command: []const u8,
    reason: []const u8,
};

/// History hooks may run on request worker threads as well as the UI thread.
/// Consumers must treat the callback as asynchronous cross-thread delivery and
/// take ownership of the provided self-contained snapshot event.
pub const HistoryChangeHook = *const fn (HistoryChangeEvent) void;

pub const HistoryChangeEvent = struct {
    allocator: std.mem.Allocator,
    record: agent_history.SessionRecord,

    pub fn deinit(self: *HistoryChangeEvent) void {
        agent_history.freeOwnedRecord(self.allocator, &self.record);
        self.* = undefined;
    }
};

const PendingHistoryChange = struct {
    hook: HistoryChangeHook,
    event: HistoryChangeEvent,
};

var g_agent_mutex: std.Thread.Mutex = .{};
var g_agent_settings: AgentSettings = .{};
var g_session_id_counter = std.atomic.Value(u64).init(1);
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
    session_id_buf: [64]u8 = undefined,
    session_id_len: usize = 0,
    input_buf: [INPUT_PROMPT_MAX_BYTES]u8 = undefined,
    input_len: usize = 0,
    input_cursor: usize = 0,
    input_scroll_row: usize = 0,
    input_scroll_follow_cursor: bool = true,
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
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
    history_on_change: ?HistoryChangeHook = null,
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

    pub fn sessionId(self: *const Session) []const u8 {
        return self.session_id_buf[0..self.session_id_len];
    }

    pub fn setHistoryChangeHook(self: *Session, hook: ?HistoryChangeHook) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.history_on_change = hook;
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
        session.assignSessionId();
        session.created_at_ms = std.time.milliTimestamp();
        session.updated_at_ms = session.created_at_ms;
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

    pub fn initFromHistoryRecord(allocator: std.mem.Allocator, record: agent_history.SessionRecord) !*Session {
        const session = try init(
            allocator,
            record.title,
            record.base_url,
            record.api_key,
            record.model,
            record.system_prompt,
            if (record.thinking_enabled) "enabled" else "disabled",
            record.reasoning_effort,
            if (record.stream) "true" else "false",
            if (record.agent_enabled) "true" else "false",
        );
        errdefer session.deinit();

        session.mutex.lock();
        defer session.mutex.unlock();
        if (record.session_id.len > 0) session.copySessionId(record.session_id);
        session.created_at_ms = record.created_at;
        session.updated_at_ms = record.updated_at;
        for (record.messages) |msg| {
            var cloned_msg = Message{
                .role = switch (msg.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .tool => .tool,
                },
                .content = try allocator.dupe(u8, msg.content),
            };
            errdefer cloned_msg.deinit(allocator);

            cloned_msg.reasoning = if (msg.reasoning) |reasoning| try allocator.dupe(u8, reasoning) else null;
            cloned_msg.usage_footer = if (msg.usage_footer) |footer| try allocator.dupe(u8, footer) else null;
            cloned_msg.tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null;
            cloned_msg.tool_name = if (msg.tool_name) |name| try allocator.dupe(u8, name) else null;
            cloned_msg.replay_to_model = msg.replay_to_model;

            try session.messages.append(allocator, cloned_msg);
        }
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
            msg.deinit(self.allocator);
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

    pub fn inputCursor(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.input_cursor;
    }

    pub fn status(self: *const Session) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn setTitle(self: *Session, title_text: []const u8) void {
        var history_change: ?PendingHistoryChange = null;
        self.mutex.lock();
        self.copyTitle(title_text);
        history_change = self.captureHistoryChangeLocked();
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
    }

    pub fn toHistoryRecord(self: *Session, allocator: std.mem.Allocator) !agent_history.SessionRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.toHistoryRecordLocked(allocator);
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
            self.input_cursor = 0;
            self.input_scroll_row = 0;
            self.input_scroll_follow_cursor = true;
            self.input_select_all = false;
        }
        self.transcript_select_all = false;
        self.insertInputBytesLocked(buf[0..len]);
    }

    pub fn appendInputText(self: *Session, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input_select_all) {
            self.input_len = 0;
            self.input_cursor = 0;
            self.input_scroll_row = 0;
            self.input_scroll_follow_cursor = true;
            self.input_select_all = false;
        }
        self.transcript_select_all = false;
        self.insertInputBytesLocked(text);
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
        self.handleKeyWithWrapCols(ev, std.math.maxInt(usize));
    }

    pub fn handleKeyWithWrapCols(self: *Session, ev: win32_backend.KeyEvent, max_cols: usize) void {
        if (self.handleApprovalKey(ev)) return;

        if (ev.ctrl and !ev.alt and ev.vk == 0x41) {
            self.selectAll();
            return;
        }
        if (ev.ctrl and !ev.alt and ev.vk == 0x55) {
            self.mutex.lock();
            self.input_len = 0;
            self.input_cursor = 0;
            self.input_scroll_row = 0;
            self.input_scroll_follow_cursor = true;
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
            win32_backend.VK_DELETE => self.deleteInput(),
            win32_backend.VK_LEFT => self.moveInputCursorLeft(),
            win32_backend.VK_RIGHT => self.moveInputCursorRight(),
            win32_backend.VK_UP => self.moveInputCursorVertical(max_cols, -1),
            win32_backend.VK_DOWN => self.moveInputCursorVertical(max_cols, 1),
            win32_backend.VK_HOME => self.moveInputCursorHome(),
            win32_backend.VK_END => self.moveInputCursorEnd(),
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
            if (msg.usage_footer) |footer| {
                if (footer.len > 0) try appendLimitedSection(allocator, &out, "Usage", footer, REMOTE_SNAPSHOT_MAX_BYTES);
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
        var history_change: ?PendingHistoryChange = null;
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
        history_change = self.captureHistoryChangeLocked();
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.clearSelectionLocked();
        self.scroll_px = 1_000_000;

        const request = self.buildRequestLocked() catch {
            self.setStatusLocked("Could not prepare request");
            self.mutex.unlock();
            self.notifyHistoryChange(history_change);
            return;
        };

        self.stop_requested.store(false, .release);
        self.request_stopping = false;
        self.request_inflight = true;
        self.setStatusLocked("Thinking...");
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);

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
        var history_change: ?PendingHistoryChange = null;
        self.mutex.lock();
        if (self.request_inflight) {
            self.mutex.unlock();
            return;
        }
        for (self.messages.items) |msg| msg.deinit(self.allocator);
        self.messages.clearRetainingCapacity();
        self.scroll_px = 0;
        self.clearSelectionLocked();
        self.setStatusLocked("Cleared");
        history_change = self.captureHistoryChangeLocked();
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
    }

    pub fn scrollBy(self: *Session, delta_px: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scroll_px = @max(0.0, self.scroll_px + delta_px);
    }

    pub fn inputScrollRow(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.input_scroll_row;
    }

    pub fn scrollInputRows(self: *Session, delta_rows: i32, max_cols_raw: usize, visible_rows_raw: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const before = self.input_scroll_row;
        const max_row = self.maxInputScrollRowLocked(max_cols_raw, visible_rows_raw);
        var next = @min(self.input_scroll_row, max_row);
        if (delta_rows < 0) {
            const amount: usize = @intCast(-delta_rows);
            next -|= amount;
        } else if (delta_rows > 0) {
            const amount: usize = @intCast(delta_rows);
            next = @min(max_row, next +| amount);
        }
        self.input_scroll_row = next;
        if (before != next) self.input_scroll_follow_cursor = false;
        return before != next;
    }

    pub fn setInputScrollRow(self: *Session, row: usize, max_cols_raw: usize, visible_rows_raw: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const before = self.input_scroll_row;
        const max_row = self.maxInputScrollRowLocked(max_cols_raw, visible_rows_raw);
        self.input_scroll_row = @min(row, max_row);
        if (max_row > 0) self.input_scroll_follow_cursor = false;
        return before != self.input_scroll_row;
    }

    fn backspaceInput(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input_select_all) {
            self.input_len = 0;
            self.input_cursor = 0;
            self.input_scroll_row = 0;
            self.input_scroll_follow_cursor = true;
            self.clearSelectionLocked();
            return;
        }
        self.transcript_select_all = false;
        self.clampInputCursorLocked();
        if (self.input_cursor == 0) return;
        const start = previousUtf8Boundary(self.input(), self.input_cursor);
        self.deleteInputRangeLocked(start, self.input_cursor);
        self.input_cursor = start;
        self.input_scroll_follow_cursor = true;
    }

    fn deleteInput(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input_select_all) {
            self.input_len = 0;
            self.input_cursor = 0;
            self.input_scroll_row = 0;
            self.input_scroll_follow_cursor = true;
            self.clearSelectionLocked();
            return;
        }
        self.transcript_select_all = false;
        self.clampInputCursorLocked();
        if (self.input_cursor >= self.input_len) return;
        const end = nextUtf8Boundary(self.input(), self.input_cursor);
        self.deleteInputRangeLocked(self.input_cursor, end);
        self.input_scroll_follow_cursor = true;
    }

    fn moveInputCursorLeft(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
        self.input_cursor = previousUtf8Boundary(self.input(), self.input_cursor);
        self.input_scroll_follow_cursor = true;
    }

    fn moveInputCursorRight(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
        self.input_cursor = nextUtf8Boundary(self.input(), self.input_cursor);
        self.input_scroll_follow_cursor = true;
    }

    fn moveInputCursorHome(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
        self.input_cursor = 0;
        self.input_scroll_follow_cursor = true;
    }

    fn moveInputCursorEnd(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
        self.input_cursor = self.input_len;
        self.input_scroll_follow_cursor = true;
    }

    fn moveInputCursorVertical(self: *Session, max_cols_raw: usize, delta: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
        self.clampInputCursorLocked();

        const text = self.input();
        const max_cols = @max(@as(usize, 1), max_cols_raw);
        const current = visualCursorPosition(text, self.input_cursor, max_cols);
        if (delta < 0 and current.row == 0) return;
        const target_row = if (delta < 0) current.row - 1 else current.row + 1;
        self.input_cursor = byteOffsetForVisualPosition(text, target_row, current.col, max_cols) orelse return;
        self.input_scroll_follow_cursor = true;
    }

    fn insertInputBytesLocked(self: *Session, text: []const u8) void {
        self.clampInputCursorLocked();
        var len = @min(text.len, self.input_buf.len - self.input_len);
        while (len > 0 and len < text.len and (text[len] & 0xC0) == 0x80) {
            len -= 1;
        }
        if (len == 0) return;
        if (self.input_cursor < self.input_len) {
            std.mem.copyBackwards(
                u8,
                self.input_buf[self.input_cursor + len .. self.input_len + len],
                self.input_buf[self.input_cursor..self.input_len],
            );
        }
        @memcpy(self.input_buf[self.input_cursor..][0..len], text[0..len]);
        self.input_len += len;
        self.input_cursor += len;
        self.input_scroll_follow_cursor = true;
    }

    fn deleteInputRangeLocked(self: *Session, start: usize, end: usize) void {
        if (start >= end or end > self.input_len) return;
        const removed = end - start;
        if (end < self.input_len) {
            std.mem.copyForwards(
                u8,
                self.input_buf[start .. self.input_len - removed],
                self.input_buf[end..self.input_len],
            );
        }
        self.input_len -= removed;
        if (self.input_cursor > self.input_len) self.input_cursor = self.input_len;
    }

    fn clampInputCursorLocked(self: *Session) void {
        if (self.input_cursor > self.input_len) self.input_cursor = self.input_len;
        while (self.input_cursor > 0 and self.input_cursor < self.input_len and (self.input_buf[self.input_cursor] & 0xC0) == 0x80) {
            self.input_cursor -= 1;
        }
    }

    fn maxInputScrollRowLocked(self: *Session, max_cols_raw: usize, visible_rows_raw: usize) usize {
        const rows = inputWrappedLineCount(self.input(), max_cols_raw);
        const visible_rows = @max(@as(usize, 1), visible_rows_raw);
        return if (rows > visible_rows) rows - visible_rows else 0;
    }

    fn clearSelectionLocked(self: *Session) void {
        self.input_select_all = false;
        self.transcript_select_all = false;
    }

    fn collapseAutoExpandedDetailsLocked(self: *Session) void {
        for (self.messages.items) |*msg| {
            if (msg.role == .tool and msg.content_auto_expand) {
                msg.content_collapsed = true;
                msg.content_auto_expand = false;
            }
            if (msg.reasoning_auto_expand) {
                msg.reasoning_collapsed = true;
                msg.reasoning_auto_expand = false;
            }
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
            if (msg.usage_footer) |footer| {
                if (footer.len > 0) try appendClipboardSection(allocator, &out, "Usage", footer);
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn buildRequestLocked(self: *Session) !*ChatRequest {
        const req = try self.allocator.create(ChatRequest);
        errdefer self.allocator.destroy(req);

        var visible_count: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.role != .tool) {
                visible_count += 1;
            } else if (msg.replay_to_model) {
                const id = msg.tool_call_id orelse continue;
                const name = msg.tool_name orelse continue;
                if (id.len == 0 or name.len == 0) continue;
                visible_count += 2;
            }
        }

        const messages = try self.allocator.alloc(RequestMessage, visible_count);
        errdefer self.allocator.free(messages);

        var written: usize = 0;
        errdefer {
            for (messages[0..written]) |msg| msg.deinit(self.allocator);
        }

        for (self.messages.items) |msg| {
            if (msg.role == .tool) {
                if (!msg.replay_to_model) continue;
                const id = msg.tool_call_id orelse continue;
                const name = msg.tool_name orelse continue;
                if (id.len == 0 or name.len == 0) continue;

                messages[written] = try durableToolAssistantRequestMessage(self.allocator, id, name);
                written += 1;
                messages[written] = try requestMessageWithClonedFields(self.allocator, .tool, msg.content, null, id, null);
                written += 1;
                continue;
            }

            messages[written] = try requestMessageWithClonedFields(self.allocator, msg.role, msg.content, msg.reasoning, null, null);
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

        const base_url = try self.allocator.dupe(u8, self.baseUrl());
        var base_url_owned = true;
        errdefer if (base_url_owned) self.allocator.free(base_url);
        const api_key = try self.allocator.dupe(u8, self.apiKey());
        var api_key_owned = true;
        errdefer if (api_key_owned) self.allocator.free(api_key);
        const model_name = try self.allocator.dupe(u8, self.model());
        var model_owned = true;
        errdefer if (model_owned) self.allocator.free(model_name);
        const system_prompt = try self.allocator.dupe(u8, self.systemPrompt());
        var system_prompt_owned = true;
        errdefer if (system_prompt_owned) self.allocator.free(system_prompt);
        const reasoning_effort = try self.allocator.dupe(u8, self.reasoningEffort());
        var reasoning_effort_owned = true;
        errdefer if (reasoning_effort_owned) self.allocator.free(reasoning_effort);

        req.* = .{
            .allocator = self.allocator,
            .session = self,
            .base_url = base_url,
            .api_key = api_key,
            .model = model_name,
            .system_prompt = system_prompt,
            .messages = messages,
            .thinking_enabled = self.thinking_enabled,
            .reasoning_effort = reasoning_effort,
            .stream = self.stream and !agent_enabled,
            .agent_enabled = agent_enabled,
            .tool_host = tool_host,
            .tool_snapshot = tool_snapshot,
            .started_ms = std.time.milliTimestamp(),
        };
        base_url_owned = false;
        api_key_owned = false;
        model_owned = false;
        system_prompt_owned = false;
        reasoning_effort_owned = false;
        return req;
    }

    fn toHistoryRecordLocked(self: *Session, allocator: std.mem.Allocator) !agent_history.SessionRecord {
        const messages = try allocator.alloc(agent_history.MessageRecord, self.messages.items.len);
        var initialized: usize = 0;
        errdefer {
            while (initialized > 0) {
                initialized -= 1;
                agent_history.freeOwnedMessage(allocator, &messages[initialized]);
            }
            allocator.free(messages);
        }

        for (self.messages.items, 0..) |msg, i| {
            var record_msg = agent_history.MessageRecord{
                .role = switch (msg.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .tool => .tool,
                },
                .content = try allocator.dupe(u8, msg.content),
            };
            errdefer agent_history.freeOwnedMessage(allocator, &record_msg);

            record_msg.reasoning = if (msg.reasoning) |reasoning| try allocator.dupe(u8, reasoning) else null;
            record_msg.usage_footer = if (msg.usage_footer) |footer| try allocator.dupe(u8, footer) else null;
            record_msg.tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null;
            record_msg.tool_name = if (msg.tool_name) |name| try allocator.dupe(u8, name) else null;
            record_msg.replay_to_model = msg.replay_to_model;

            messages[i] = record_msg;
            initialized += 1;
        }

        const session_id = try allocator.dupe(u8, self.sessionId());
        errdefer allocator.free(session_id);
        const session_title = try allocator.dupe(u8, self.title());
        errdefer allocator.free(session_title);
        const base_url = try allocator.dupe(u8, self.baseUrl());
        errdefer allocator.free(base_url);
        const api_key = try allocator.dupe(u8, self.apiKey());
        errdefer allocator.free(api_key);
        const model_name = try allocator.dupe(u8, self.model());
        errdefer allocator.free(model_name);
        const system_prompt = try allocator.dupe(u8, self.systemPrompt());
        errdefer allocator.free(system_prompt);
        const reasoning_effort = try allocator.dupe(u8, self.reasoningEffort());
        errdefer allocator.free(reasoning_effort);

        return .{
            .session_id = session_id,
            .title = session_title,
            .base_url = base_url,
            .api_key = api_key,
            .model = model_name,
            .system_prompt = system_prompt,
            .thinking_enabled = self.thinking_enabled,
            .reasoning_effort = reasoning_effort,
            .stream = self.stream,
            .agent_enabled = self.agent_enabled,
            .created_at = self.created_at_ms,
            .updated_at = self.updated_at_ms,
            .messages = messages,
        };
    }

    fn captureHistoryChangeLocked(self: *Session) ?PendingHistoryChange {
        self.updated_at_ms = std.time.milliTimestamp();
        const hook = self.history_on_change orelse return null;
        const record = self.toHistoryRecordLocked(self.allocator) catch return null;
        return .{
            .hook = hook,
            .event = .{
                .allocator = self.allocator,
                .record = record,
            },
        };
    }

    fn notifyHistoryChange(_: *Session, change: ?PendingHistoryChange) void {
        if (change) |pending| pending.hook(pending.event);
    }

    fn assignSessionId(self: *Session) void {
        const counter = g_session_id_counter.fetchAdd(1, .monotonic);
        const text = std.fmt.bufPrint(&self.session_id_buf, "session-{d}-{d}", .{ std.time.milliTimestamp(), counter }) catch {
            self.copySessionId("session");
            return;
        };
        self.session_id_len = text.len;
    }

    fn copySessionId(self: *Session, value: []const u8) void {
        self.session_id_len = @min(value.len, self.session_id_buf.len);
        @memcpy(self.session_id_buf[0..self.session_id_len], value[0..self.session_id_len]);
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

    fn setCompletionStatusLocked(self: *Session, started_ms: i64, usage: ?ApiUsage) void {
        if (started_ms <= 0 and usage == null) {
            self.setStatusLocked("Ready");
            return;
        }

        var buf: [32]u8 = undefined;
        const elapsed_ms: i64 = if (started_ms > 0) @max(@as(i64, 0), std.time.milliTimestamp() - started_ms) else 0;
        const secs: i64 = @divTrunc(elapsed_ms, 1000);
        const tenths: i64 = @divTrunc(@mod(elapsed_ms, 1000), 100);
        const text = if (started_ms > 0)
            std.fmt.bufPrint(&buf, "Done in {d}.{d}s", .{ secs, tenths }) catch "Ready"
        else
            "Done";
        self.setStatusLocked(text);
    }

    fn setStatusLocked(self: *Session, value: []const u8) void {
        self.status_len = @min(value.len, self.status_buf.len);
        @memcpy(self.status_buf[0..self.status_len], value[0..self.status_len]);
    }
};

fn allocUsageFooter(allocator: std.mem.Allocator, started_ms: i64, usage: ?ApiUsage) !?[]u8 {
    const u = usage orelse return null;
    var buf: [160]u8 = undefined;
    const text = if (started_ms > 0) blk: {
        const elapsed_ms: i64 = @max(@as(i64, 0), std.time.milliTimestamp() - started_ms);
        const secs: i64 = @divTrunc(elapsed_ms, 1000);
        const tenths: i64 = @divTrunc(@mod(elapsed_ms, 1000), 100);
        break :blk std.fmt.bufPrint(
            &buf,
            "time {d}.{d}s | total {d} | input {d} | output {d} | cache {d}/{d}",
            .{ secs, tenths, u.total_tokens, u.prompt_tokens, u.completion_tokens, u.prompt_cache_hit_tokens, u.prompt_cache_miss_tokens },
        ) catch "usage unavailable";
    } else std.fmt.bufPrint(
        &buf,
        "total {d} | input {d} | output {d} | cache {d}/{d}",
        .{ u.total_tokens, u.prompt_tokens, u.completion_tokens, u.prompt_cache_hit_tokens, u.prompt_cache_miss_tokens },
    ) catch "usage unavailable";
    return try allocator.dupe(u8, text);
}

fn previousUtf8Boundary(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var i = @min(cursor, text.len);
    i -= 1;
    while (i > 0 and (text[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

fn nextUtf8Boundary(text: []const u8, cursor: usize) usize {
    if (cursor >= text.len) return text.len;
    var i = cursor + 1;
    while (i < text.len and (text[i] & 0xC0) == 0x80) : (i += 1) {}
    return i;
}

const VisualCursor = struct {
    row: usize,
    col: usize,
};

const VisualRow = struct {
    start: usize,
    end: usize,
};

fn nextUtf8Step(text: []const u8, index: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    return if (index + len <= text.len) len else 1;
}

fn visualCursorPosition(text: []const u8, cursor_raw: usize, max_cols_raw: usize) VisualCursor {
    const cursor = @min(cursor_raw, text.len);
    const max_cols = @max(@as(usize, 1), max_cols_raw);
    var row: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < cursor) {
        if (text[i] == '\n') {
            row += 1;
            col = 0;
            i += 1;
            continue;
        }
        if (col >= max_cols) {
            row += 1;
            col = 0;
        }
        col += 1;
        i += nextUtf8Step(text, i);
    }
    return .{ .row = row, .col = col };
}

fn visualRowAt(text: []const u8, target_row: usize, max_cols_raw: usize) ?VisualRow {
    const max_cols = @max(@as(usize, 1), max_cols_raw);
    var row: usize = 0;
    var row_start: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            if (row == target_row) return .{ .start = row_start, .end = i };
            row += 1;
            row_start = i + 1;
            col = 0;
            i += 1;
            continue;
        }
        if (col >= max_cols) {
            if (row == target_row) return .{ .start = row_start, .end = i };
            row += 1;
            row_start = i;
            col = 0;
        }
        col += 1;
        i += nextUtf8Step(text, i);
    }
    if (row == target_row) return .{ .start = row_start, .end = text.len };
    return null;
}

fn byteOffsetForVisualPosition(text: []const u8, target_row: usize, target_col: usize, max_cols: usize) ?usize {
    const row = visualRowAt(text, target_row, max_cols) orelse return null;
    var col: usize = 0;
    var i = row.start;
    while (i < row.end and col < target_col) {
        i += nextUtf8Step(text, i);
        col += 1;
    }
    return i;
}

pub fn inputWrappedLineCount(text: []const u8, max_cols_raw: usize) usize {
    if (text.len == 0) return 1;
    const max_cols = @max(@as(usize, 1), max_cols_raw);
    var lines: usize = 1;
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            lines += 1;
            cols = 0;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (cols >= max_cols) {
            lines += 1;
            cols = 0;
        }
        cols += 1;
        i += if (i + len <= text.len) len else 1;
    }
    return lines;
}

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
        appendAssistantResult(request.session, result, request.started_ms);
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
            appendAssistantResult(request.session, .{ .content = text }, request.started_ms);
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
    appendAssistantResult(request.session, result, request.started_ms);
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

    var total_usage: ApiUsage = .{};
    var has_usage = false;
    while (true) {
        if (requestCancelled(request)) return error.Canceled;
        const result = try runChatRequestForMessages(request, transcript.items, true);
        if (requestCancelled(request)) {
            result.deinit(request.allocator);
            return error.Canceled;
        }
        if (result.usage) |usage| {
            total_usage.add(usage);
            has_usage = true;
        }
        if (result.tool_calls == null or result.tool_calls.?.len == 0) {
            var final = result;
            if (has_usage) final.usage = total_usage;
            return final;
        }
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
    return requestMessageWithClonedFields(allocator, msg.role, msg.content, msg.reasoning, msg.tool_call_id, msg.tool_calls);
}

fn cloneToolCalls(allocator: std.mem.Allocator, calls: []const ToolCall) ![]ToolCall {
    const out = try allocator.alloc(ToolCall, calls.len);
    errdefer allocator.free(out);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |call| call.deinit(allocator);
    }
    for (calls, 0..) |call, i| {
        {
            const id = try allocator.dupe(u8, call.id);
            errdefer allocator.free(id);
            const name = try allocator.dupe(u8, call.name);
            errdefer allocator.free(name);
            const arguments = try allocator.dupe(u8, call.arguments);
            errdefer allocator.free(arguments);
            out[i] = .{
                .id = id,
                .name = name,
                .arguments = arguments,
            };
        }
        written += 1;
    }
    return out;
}

fn assistantToolCallMessage(allocator: std.mem.Allocator, content: []const u8, reasoning: ?[]const u8, calls: []const ToolCall) !RequestMessage {
    return requestMessageWithClonedFields(allocator, .assistant, content, reasoning, null, calls);
}

fn requestMessageWithClonedFields(
    allocator: std.mem.Allocator,
    role: Role,
    content: []const u8,
    reasoning: ?[]const u8,
    tool_call_id: ?[]const u8,
    tool_calls: ?[]const ToolCall,
) !RequestMessage {
    const content_copy = try allocator.dupe(u8, content);
    errdefer allocator.free(content_copy);

    var reasoning_copy: ?[]u8 = null;
    errdefer if (reasoning_copy) |text| allocator.free(text);
    if (reasoning) |text| reasoning_copy = try allocator.dupe(u8, text);

    var tool_call_id_copy: ?[]u8 = null;
    errdefer if (tool_call_id_copy) |id| allocator.free(id);
    if (tool_call_id) |id| tool_call_id_copy = try allocator.dupe(u8, id);

    var tool_calls_copy: ?[]ToolCall = null;
    errdefer if (tool_calls_copy) |calls| {
        for (calls) |call| call.deinit(allocator);
        allocator.free(calls);
    };
    if (tool_calls) |calls| tool_calls_copy = try cloneToolCalls(allocator, calls);

    return .{
        .role = role,
        .content = content_copy,
        .reasoning = reasoning_copy,
        .tool_call_id = tool_call_id_copy,
        .tool_calls = tool_calls_copy,
    };
}

fn durableToolAssistantRequestMessage(allocator: std.mem.Allocator, id: []const u8, name: []const u8) !RequestMessage {
    const content = try allocator.dupe(u8, "");
    errdefer allocator.free(content);

    const calls = try allocator.alloc(ToolCall, 1);
    errdefer allocator.free(calls);

    {
        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const arguments = try allocator.dupe(u8, "{}");
        errdefer allocator.free(arguments);

        calls[0] = .{
            .id = id_copy,
            .name = name_copy,
            .arguments = arguments,
        };
    }

    return .{
        .role = .assistant,
        .content = content,
        .tool_calls = calls,
    };
}

fn appendAssistantResult(session: *Session, result: ApiResult, started_ms: i64) void {
    const allocator = session.allocator;
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
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
    var usage_footer = allocUsageFooter(allocator, started_ms, result.usage) catch null;
    var reasoning_copy: ?[]u8 = null;
    if (result.reasoning) |reasoning| {
        reasoning_copy = allocator.dupe(u8, reasoning) catch null;
    }
    const reasoning_visible = if (reasoning_copy) |r| r.len > 0 else false;
    session.messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .reasoning = reasoning_copy,
        .usage_footer = usage_footer,
        .reasoning_collapsed = reasoning_visible,
        .reasoning_auto_expand = false,
    }) catch {
        allocator.free(content);
        if (reasoning_copy) |r| allocator.free(r);
        if (usage_footer) |footer| allocator.free(footer);
        session.request_inflight = false;
        session.collapseAutoExpandedDetailsLocked();
        session.setStatusLocked("Out of memory");
        return;
    };
    usage_footer = null;
    session.request_inflight = false;
    session.collapseAutoExpandedDetailsLocked();
    session.scroll_px = 1_000_000;
    session.setCompletionStatusLocked(started_ms, result.usage);
    history_change = session.captureHistoryChangeLocked();
}

fn appendProgressMessage(session: *Session, text: []const u8) !void {
    if (sessionCancelled(session)) return error.Canceled;
    const allocator = session.allocator;
    const content = try allocator.dupe(u8, text);
    errdefer allocator.free(content);

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
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
    history_change = session.captureHistoryChangeLocked();
}

fn beginAssistantStream(session: *Session) !usize {
    const allocator = session.allocator;
    if (sessionCancelled(session)) return error.Canceled;

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
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
    history_change = session.captureHistoryChangeLocked();
    return session.messages.items.len - 1;
}

fn appendAssistantStreamDelta(session: *Session, message_idx: usize, content_delta: []const u8, reasoning_delta: []const u8) !void {
    if (content_delta.len == 0 and reasoning_delta.len == 0) return;
    const allocator = session.allocator;
    if (sessionCancelled(session)) return;

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
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
    history_change = session.captureHistoryChangeLocked();
}

fn finishAssistantStream(session: *Session, message_idx: usize, started_ms: i64, usage: ?ApiUsage) void {
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
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
        if (allocUsageFooter(session.allocator, started_ms, usage) catch null) |footer| {
            if (msg.usage_footer) |old_footer| session.allocator.free(old_footer);
            msg.usage_footer = footer;
        }
        history_change = session.captureHistoryChangeLocked();
    }
    session.request_inflight = false;
    session.collapseAutoExpandedDetailsLocked();
    session.scroll_px = 1_000_000;
    session.setCompletionStatusLocked(started_ms, usage);
}

fn failAssistantStream(session: *Session, message_idx: ?usize, text: []const u8) void {
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }
    if (message_idx) |idx| {
        appendAssistantStreamDelta(session, idx, text, "") catch {};
        finishAssistantStream(session, idx, 0, null);
        return;
    }

    appendAssistantResult(session, .{ .content = @constCast(text) }, 0);
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
    var usage: ?ApiUsage = null;
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
        if (try applyApiStreamLineToSession(allocator, request.session, message_idx, line, &usage)) break;
    }
    finishAssistantStream(request.session, message_idx, request.started_ms, usage);
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
    if (request.stream) {
        try out.appendSlice(allocator, ",\"stream_options\":{\"include_usage\":true}");
    }
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
    child.create_no_window = true;
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
        .usage = parseApiUsage(root),
    };
}

fn parseApiUsage(root: std.json.Value) ?ApiUsage {
    if (root != .object) return null;
    const usage_value = root.object.get("usage") orelse return null;
    if (usage_value != .object) return null;
    return .{
        .prompt_tokens = jsonU64Value(usage_value.object.get("prompt_tokens")),
        .completion_tokens = jsonU64Value(usage_value.object.get("completion_tokens")),
        .prompt_cache_hit_tokens = jsonU64Value(usage_value.object.get("prompt_cache_hit_tokens")),
        .prompt_cache_miss_tokens = jsonU64Value(usage_value.object.get("prompt_cache_miss_tokens")),
        .total_tokens = jsonU64Value(usage_value.object.get("total_tokens")),
    };
}

fn jsonU64Value(value_opt: ?std.json.Value) u64 {
    const value = value_opt orelse return 0;
    return switch (value) {
        .integer => |v| if (v > 0) @intCast(v) else 0,
        .float => |v| if (v > 0 and v <= @as(f64, @floatFromInt(std.math.maxInt(u64)))) @intFromFloat(v) else 0,
        else => 0,
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
    var usage: ?ApiUsage = null;

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
        if (parseApiUsage(root)) |u| usage = u;

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
        .usage = usage,
    };
}

fn applyApiStreamLineToSession(
    allocator: std.mem.Allocator,
    session: *Session,
    message_idx: usize,
    line_raw: []const u8,
    usage_out: *?ApiUsage,
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
    if (parseApiUsage(root)) |usage| usage_out.* = usage;

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

const TestHistoryHookCapture = struct {
    event: ?HistoryChangeEvent = null,
    calls: usize = 0,

    fn deinit(self: *TestHistoryHookCapture) void {
        if (self.event) |*event| {
            event.deinit();
            self.event = null;
        }
        self.calls = 0;
    }
};

var g_test_history_hook_capture: ?*TestHistoryHookCapture = null;

fn testHistoryHookCaptureCallback(event: HistoryChangeEvent) void {
    var owned = event;
    const capture = g_test_history_hook_capture orelse {
        owned.deinit();
        return;
    };
    if (capture.event) |*previous| {
        previous.deinit();
    }
    capture.event = owned;
    capture.calls += 1;
}

test "ai_chat: session serializes to history record" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "History Test",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "hello") });
    session.mutex.unlock();

    var record = try session.toHistoryRecord(allocator);
    defer agent_history.freeOwnedRecord(allocator, &record);

    try std.testing.expect(record.agent_enabled);
    try std.testing.expectEqual(@as(usize, 1), record.messages.len);
    try std.testing.expectEqualStrings("hello", record.messages[0].content);
}

test "ai_chat: session loads from history record" {
    const allocator = std.testing.allocator;
    var record = try agent_history.cloneRecord(allocator, .{
        .session_id = "session-1",
        .title = "Saved",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "model-a",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{
            .{ .role = .user, .content = "hello", .reasoning = null, .usage_footer = null },
        },
    });
    defer agent_history.freeOwnedRecord(allocator, &record);

    const session = try Session.initFromHistoryRecord(allocator, record);
    defer session.deinit();

    try std.testing.expectEqualStrings("session-1", session.sessionId());
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
}

test "ai_chat: loading history record cleans up partial message clone on allocation failure" {
    const allocator = std.testing.allocator;
    var record = try agent_history.cloneRecord(allocator, .{
        .session_id = "session-tool",
        .title = "Saved",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "model-a",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{
            .{
                .role = .tool,
                .content = "# Skill: pdf",
                .reasoning = "reason",
                .usage_footer = "usage",
                .tool_call_id = "skill-preload-pdf",
                .tool_name = "skill_info",
                .replay_to_model = true,
            },
        },
    });
    defer agent_history.freeOwnedRecord(allocator, &record);

    var saw_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });

        const result = Session.initFromHistoryRecord(failing_allocator.allocator(), record);
        if (result) |session| {
            session.deinit();
            if (!failing_allocator.has_induced_failure) break;
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => return err,
        }
    }

    try std.testing.expect(saw_oom);
}

test "ai_chat: serializing history record cleans up partial message clone on allocation failure" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "History Test",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    defer session.mutex.unlock();
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "# Skill: pdf"),
        .reasoning = try allocator.dupe(u8, "reason"),
        .usage_footer = try allocator.dupe(u8, "usage"),
        .tool_call_id = try allocator.dupe(u8, "skill-preload-pdf"),
        .tool_name = try allocator.dupe(u8, "skill_info"),
        .replay_to_model = true,
    });

    var saw_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });

        const result = session.toHistoryRecordLocked(failing_allocator.allocator());
        if (result) |record| {
            var owned_record = record;
            agent_history.freeOwnedRecord(failing_allocator.allocator(), &owned_record);
            if (!failing_allocator.has_induced_failure) break;
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => return err,
        }
    }

    try std.testing.expect(saw_oom);
}

test "ai_chat: history hook receives self-owning snapshot event" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "History Hook",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    var capture = TestHistoryHookCapture{};
    defer capture.deinit();
    g_test_history_hook_capture = &capture;
    defer g_test_history_hook_capture = null;

    session.setHistoryChangeHook(testHistoryHookCaptureCallback);
    try appendProgressMessage(session, "running tool");

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.event != null);
    try std.testing.expectEqual(@as(usize, 1), capture.event.?.record.messages.len);
    try std.testing.expectEqualStrings("running tool", capture.event.?.record.messages[0].content);
    try std.testing.expect(capture.event.?.record.messages[0].content.ptr != session.messages.items[0].content.ptr);

    capture.deinit();
    try std.testing.expect(capture.event == null);
}

test "ai_chat: setTitle emits history hook snapshot" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Before",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    var capture = TestHistoryHookCapture{};
    defer capture.deinit();
    g_test_history_hook_capture = &capture;
    defer g_test_history_hook_capture = null;

    session.setHistoryChangeHook(testHistoryHookCaptureCallback);
    session.setTitle("After");

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.event != null);
    try std.testing.expectEqualStrings("After", capture.event.?.record.title);
    try std.testing.expectEqualStrings("After", session.title());
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
        .started_ms = 0,
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
        .started_ms = 0,
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

test "ai chat request json replays durable tool messages and skips progress tools" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "test-key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Use the skill."),
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "# Skill: pdf"),
        .tool_call_id = try allocator.dupe(u8, "skill-preload-pdf"),
        .tool_name = try allocator.dupe(u8, "skill_info"),
        .replay_to_model = true,
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "running terminal_list {}"),
        .replay_to_model = false,
    });
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();

    const json = try buildRequestJsonForMessages(allocator, request, request.messages, true);
    defer allocator.free(json);

    const assistant_tool_call =
        \\{"role":"assistant","content":"","tool_calls":[{"id":"skill-preload-pdf","type":"function","function":{"name":"skill_info","arguments":"{}"}}]}
    ;
    const tool_result =
        \\{"role":"tool","content":"# Skill: pdf","tool_call_id":"skill-preload-pdf"}
    ;
    const assistant_index = std.mem.indexOf(u8, json, assistant_tool_call) orelse return error.MissingAssistantToolCall;
    const tool_index = std.mem.indexOf(u8, json, tool_result) orelse return error.MissingToolResult;
    try std.testing.expect(assistant_index < tool_index);
    try std.testing.expect(std.mem.indexOf(u8, json, "running terminal_list") == null);
}

test "ai chat request skips replayable tool messages missing identity" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "test-key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Use the skill."),
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "# Skill without metadata"),
        .replay_to_model = true,
    });
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();

    try std.testing.expectEqual(@as(usize, 1), request.messages.len);

    const json = try buildRequestJsonForMessages(allocator, request, request.messages, true);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "# Skill without metadata") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"tool\"") == null);
}

test "ai chat request setup cleans scalar fields on allocation failure" {
    const allocator = std.testing.allocator;

    var saw_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });

        var session = Session{ .allocator = failing_allocator.allocator() };
        session.assignSessionId();
        session.copyTitle("Test");
        session.copyBaseUrl(DEFAULT_BASE_URL);
        session.copyApiKey("test-key");
        session.copyModel(DEFAULT_MODEL);
        session.copySystemPrompt(DEFAULT_SYSTEM_PROMPT);
        session.copyReasoningEffort(DEFAULT_REASONING_EFFORT);

        const result = session.buildRequestLocked();
        if (result) |request| {
            request.deinit();
            if (!failing_allocator.has_induced_failure) break;
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => return err,
        }
    }

    try std.testing.expect(saw_oom);
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
        .started_ms = 0,
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

test "ai chat parses token usage from OpenAI responses" {
    const allocator = std.testing.allocator;
    const body =
        \\{"usage":{"prompt_tokens":12,"completion_tokens":34,"prompt_cache_hit_tokens":5,"prompt_cache_miss_tokens":7,"total_tokens":46},"choices":[{"message":{"role":"assistant","content":"done"}}]}
    ;
    const result = try parseApiResponse(allocator, body);
    defer result.deinit(allocator);
    try std.testing.expect(result.usage != null);
    try std.testing.expectEqual(@as(u64, 12), result.usage.?.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 34), result.usage.?.completion_tokens);
    try std.testing.expectEqual(@as(u64, 5), result.usage.?.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u64, 7), result.usage.?.prompt_cache_miss_tokens);
    try std.testing.expectEqual(@as(u64, 46), result.usage.?.total_tokens);
}

test "ai chat usage footer includes time token and cache fields" {
    const footer = try allocUsageFooter(std.testing.allocator, std.time.milliTimestamp() - 2300, .{
        .prompt_tokens = 12,
        .completion_tokens = 34,
        .prompt_cache_hit_tokens = 5,
        .prompt_cache_miss_tokens = 7,
        .total_tokens = 46,
    });
    defer if (footer) |text| std.testing.allocator.free(text);
    try std.testing.expect(footer != null);
    try std.testing.expect(std.mem.indexOf(u8, footer.?, "time 2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer.?, "total 46") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer.?, "input 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer.?, "output 34") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer.?, "cache 5/7") != null);
}

test "ai chat completion status stays compact while usage is message footer" {
    var session = Session{ .allocator = std.testing.allocator };
    session.setCompletionStatusLocked(std.time.milliTimestamp() - 2300, .{
        .prompt_tokens = 12,
        .completion_tokens = 34,
        .total_tokens = 46,
    });
    try std.testing.expect(std.mem.indexOf(u8, session.status(), "Done in 2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.status(), "tok") == null);
}

test "ai chat appends usage footer to completed assistant message" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    appendAssistantResult(&session, .{
        .content = @constCast("done"),
        .usage = .{
            .prompt_tokens = 12,
            .completion_tokens = 34,
            .prompt_cache_hit_tokens = 5,
            .prompt_cache_miss_tokens = 7,
            .total_tokens = 46,
        },
    }, std.time.milliTimestamp() - 2300);

    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expect(session.messages.items[0].usage_footer != null);
    const footer = session.messages.items[0].usage_footer.?;
    try std.testing.expect(std.mem.indexOf(u8, footer, "total 46") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "cache 5/7") != null);
}

test "ai chat streaming request asks provider to include usage" {
    const allocator = std.testing.allocator;
    var content = [_]u8{ 'h', 'i' };
    var model = [_]u8{ 'd', 'e', 'e', 'p', 's', 'e', 'e', 'k', '-', 'v', '4', '-', 'p', 'r', 'o' };
    var reasoning = [_]u8{ 'h', 'i', 'g', 'h' };
    var msg = [_]RequestMessage{.{ .role = .user, .content = content[0..] }};
    var request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = &.{},
        .api_key = &.{},
        .model = model[0..],
        .system_prompt = &.{},
        .messages = msg[0..],
        .stream = true,
        .agent_enabled = false,
        .tool_host = null,
        .tool_snapshot = null,
        .thinking_enabled = true,
        .reasoning_effort = reasoning[0..],
        .started_ms = 0,
    };
    const body = try buildRequestJsonForMessages(allocator, &request, msg[0..], false);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
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
        .started_ms = 0,
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

test "ai chat input cursor supports insertion and deletion in the middle" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("hello");
    try std.testing.expectEqual(@as(usize, 5), session.inputCursor());

    session.handleKey(.{ .vk = win32_backend.VK_LEFT, .ctrl = false, .shift = false, .alt = false });
    session.handleKey(.{ .vk = win32_backend.VK_LEFT, .ctrl = false, .shift = false, .alt = false });
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());

    session.handleChar('X');
    try std.testing.expectEqualStrings("helXlo", session.input());
    try std.testing.expectEqual(@as(usize, 4), session.inputCursor());

    session.handleKey(.{ .vk = win32_backend.VK_BACK, .ctrl = false, .shift = false, .alt = false });
    try std.testing.expectEqualStrings("hello", session.input());
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());

    session.handleKey(.{ .vk = win32_backend.VK_DELETE, .ctrl = false, .shift = false, .alt = false });
    try std.testing.expectEqualStrings("helo", session.input());
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());
}

test "ai chat input accepts prompts longer than the old 8 KiB limit" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };

    const prompt = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(prompt);
    @memset(prompt, 'a');

    session.appendInputText(prompt);

    try std.testing.expectEqual(prompt.len, session.input().len);
    try std.testing.expectEqualStrings(prompt, session.input());
    try std.testing.expectEqual(prompt.len, session.inputCursor());
}

test "ai chat input cursor moves by utf8 codepoint boundaries" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("你a");
    session.handleKey(.{ .vk = win32_backend.VK_LEFT, .ctrl = false, .shift = false, .alt = false });
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());
    session.handleKey(.{ .vk = win32_backend.VK_BACK, .ctrl = false, .shift = false, .alt = false });
    try std.testing.expectEqualStrings("a", session.input());
    try std.testing.expectEqual(@as(usize, 0), session.inputCursor());
}

test "ai chat input cursor moves vertically across explicit lines" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("abc\ndefg\nhi");

    session.handleKey(.{ .vk = win32_backend.VK_HOME, .ctrl = false, .shift = false, .alt = false });
    session.handleKey(.{ .vk = win32_backend.VK_DOWN, .ctrl = false, .shift = false, .alt = false });
    try std.testing.expectEqual(@as(usize, 4), session.inputCursor());

    session.handleKey(.{ .vk = win32_backend.VK_RIGHT, .ctrl = false, .shift = false, .alt = false });
    session.handleKey(.{ .vk = win32_backend.VK_RIGHT, .ctrl = false, .shift = false, .alt = false });
    try std.testing.expectEqual(@as(usize, 6), session.inputCursor());

    session.handleKey(.{ .vk = win32_backend.VK_DOWN, .ctrl = false, .shift = false, .alt = false });
    try std.testing.expectEqual(@as(usize, 11), session.inputCursor());

    session.handleKey(.{ .vk = win32_backend.VK_UP, .ctrl = false, .shift = false, .alt = false });
    try std.testing.expectEqual(@as(usize, 6), session.inputCursor());
}

test "ai chat input cursor moves vertically across wrapped rows" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("abcdefghijkl");
    session.handleKey(.{ .vk = win32_backend.VK_HOME, .ctrl = false, .shift = false, .alt = false });
    session.handleKeyWithWrapCols(.{ .vk = win32_backend.VK_DOWN, .ctrl = false, .shift = false, .alt = false }, 5);
    try std.testing.expectEqual(@as(usize, 5), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .vk = win32_backend.VK_RIGHT, .ctrl = false, .shift = false, .alt = false }, 5);
    session.handleKeyWithWrapCols(.{ .vk = win32_backend.VK_RIGHT, .ctrl = false, .shift = false, .alt = false }, 5);
    session.handleKeyWithWrapCols(.{ .vk = win32_backend.VK_DOWN, .ctrl = false, .shift = false, .alt = false }, 5);
    try std.testing.expectEqual(@as(usize, 12), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .vk = win32_backend.VK_UP, .ctrl = false, .shift = false, .alt = false }, 5);
    try std.testing.expectEqual(@as(usize, 7), session.inputCursor());
}

test "ai chat composer wrapped row count grows with explicit lines and wrapping" {
    try std.testing.expectEqual(@as(usize, 1), inputWrappedLineCount("", 12));
    try std.testing.expectEqual(@as(usize, 2), inputWrappedLineCount("hello\nworld", 12));
    try std.testing.expectEqual(@as(usize, 3), inputWrappedLineCount("abcdefghijkl", 5));
}

test "ai chat input scroll clamps to wrapped rows" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        DEFAULT_THINKING,
        DEFAULT_REASONING_EFFORT,
        DEFAULT_STREAM,
        "false",
    );
    defer session.deinit();

    session.appendInputText("abcdefghijkl");

    try std.testing.expect(session.scrollInputRows(10, 5, 1));
    try std.testing.expectEqual(@as(usize, 2), session.inputScrollRow());

    try std.testing.expect(session.scrollInputRows(-1, 5, 1));
    try std.testing.expectEqual(@as(usize, 1), session.inputScrollRow());

    try std.testing.expect(session.scrollInputRows(10, 5, 3));
    try std.testing.expectEqual(@as(usize, 0), session.inputScrollRow());
    try std.testing.expect(!session.scrollInputRows(10, 5, 3));
}

test "ai chat manual input scroll pauses cursor following until cursor moves" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        DEFAULT_THINKING,
        DEFAULT_REASONING_EFFORT,
        DEFAULT_STREAM,
        "false",
    );
    defer session.deinit();

    session.appendInputText("abcdefghijkl");
    try std.testing.expect(session.input_scroll_follow_cursor);

    _ = session.scrollInputRows(1, 5, 1);
    try std.testing.expect(!session.input_scroll_follow_cursor);

    session.handleKeyWithWrapCols(.{ .vk = win32_backend.VK_RIGHT, .ctrl = false, .shift = false, .alt = false }, 5);
    try std.testing.expect(session.input_scroll_follow_cursor);
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
        for (session.messages.items) |msg| msg.deinit(allocator);
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
        for (session.messages.items) |msg| msg.deinit(allocator);
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
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    session.request_inflight = true;
    session.stopRequest();
    try std.testing.expect(session.request_stopping);
    try std.testing.expectEqualStrings("Stopping...", session.status());

    appendAssistantResult(&session, .{ .content = @constCast("late result") }, 0);
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
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":34,\"prompt_cache_hit_tokens\":5,\"prompt_cache_miss_tokens\":7,\"total_tokens\":46}}\n\n" ++
        "data: [DONE]\n\n";

    const result = try parseApiStreamResponse(allocator, body);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("Hello!", result.content);
    try std.testing.expect(result.reasoning != null);
    try std.testing.expectEqualStrings("Thinking", result.reasoning.?);
    try std.testing.expect(result.usage != null);
    try std.testing.expectEqual(@as(u64, 46), result.usage.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 5), result.usage.?.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u64, 7), result.usage.?.prompt_cache_miss_tokens);
}

test "ai chat collapse helper only closes auto-expanded details" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
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
