const std = @import("std");
const log = std.log.scoped(.agent_history);

const DEFAULT_HISTORY_BASENAME = "agent-history.json";
const MAX_HISTORY_BYTES = 8 * 1024 * 1024;

pub const MessageRole = enum {
    user,
    assistant,
    tool,
};

pub const MessageRecord = struct {
    role: MessageRole,
    content: []const u8,
    reasoning: ?[]const u8 = null,
    usage_footer: ?[]const u8 = null,
};

pub const SessionRecord = struct {
    session_id: []const u8,
    title: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    system_prompt: []const u8,
    thinking_enabled: bool,
    reasoning_effort: []const u8,
    stream: bool,
    agent_enabled: bool,
    created_at: i64,
    updated_at: i64,
    messages: []MessageRecord,
};

pub const Row = struct {
    session_id: []const u8,
    title: []const u8,
    model: []const u8,
    updated_at: i64,
};

const PersistedStore = struct {
    records: []SessionRecord = &.{},
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(SessionRecord) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.records.deinit(self.allocator);
    }

    pub fn clear(self: *Store) void {
        for (self.records.items) |*record| freeOwnedRecord(self.allocator, record);
        self.records.clearRetainingCapacity();
    }

    pub fn upsertRecord(self: *Store, input: anytype) !void {
        var cloned = try cloneRecord(self.allocator, input);
        errdefer freeOwnedRecord(self.allocator, &cloned);

        try self.upsertOwnedRecord(cloned);
    }

    pub fn upsertOwnedRecord(self: *Store, record: SessionRecord) !void {
        var owned = record;
        errdefer freeOwnedRecord(self.allocator, &owned);

        if (self.findIndexBySessionId(owned.session_id)) |idx| {
            freeOwnedRecord(self.allocator, &self.records.items[idx]);
            self.records.items[idx] = owned;
            return;
        }

        try self.records.append(self.allocator, owned);
    }

    /// Returns rows with owned string slices. Call `freeRows()` when done.
    pub fn buildRows(self: *const Store, allocator: std.mem.Allocator) ![]Row {
        const rows = try allocator.alloc(Row, self.records.items.len);
        var initialized: usize = 0;
        errdefer {
            while (initialized > 0) {
                initialized -= 1;
                freeOwnedRow(allocator, &rows[initialized]);
            }
            allocator.free(rows);
        }

        for (self.records.items, 0..) |record, i| {
            rows[i] = try cloneRow(allocator, .{
                .session_id = record.session_id,
                .title = record.title,
                .model = record.model,
                .updated_at = record.updated_at,
            });
            initialized += 1;
        }
        sortRows(rows);
        return rows;
    }

    pub fn toJsonString(self: *const Store, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, PersistedStore{
            .records = self.records.items,
        }, .{});
    }

    pub fn fromJsonString(allocator: std.mem.Allocator, bytes: []const u8) !Store {
        var parsed = try std.json.parseFromSlice(PersistedStore, allocator, bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var store = Store.init(allocator);
        errdefer store.deinit();

        for (parsed.value.records) |record| {
            try store.upsertRecord(record);
        }
        return store;
    }

    pub fn fromJsonStringLenient(allocator: std.mem.Allocator, bytes: []const u8) !Store {
        return fromJsonString(allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                if (isLenientJsonLoadError(err)) return Store.init(allocator);
                return err;
            },
        };
    }

    pub fn cloneRecordBySessionId(self: *const Store, allocator: std.mem.Allocator, session_id: []const u8) !?SessionRecord {
        const idx = self.findIndexBySessionId(session_id) orelse return null;
        return try cloneRecord(allocator, self.records.items[idx]);
    }

    pub fn saveToPath(self: *const Store, path: []const u8) !void {
        const json = try self.toJsonString(self.allocator);
        defer self.allocator.free(json);

        try saveJsonToPath(path, json);
    }

    pub fn saveDefault(self: *const Store) !void {
        const path = try defaultPath(self.allocator);
        defer self.allocator.free(path);
        try self.saveToPath(path);
    }

    fn findIndexBySessionId(self: *const Store, session_id: []const u8) ?usize {
        for (self.records.items, 0..) |record, i| {
            if (std.mem.eql(u8, record.session_id, session_id)) return i;
        }
        return null;
    }
};

pub fn saveJsonToPath(path: []const u8, json: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            log.warn("failed to create history dir {s}: {}", .{ dir, err });
            return err;
        };
    }

    var write_buffer: [0]u8 = .{};
    var atomic = try std.fs.cwd().atomicFile(path, .{ .write_buffer = &write_buffer });
    defer atomic.deinit();
    try atomic.file_writer.file.writeAll(json);
    try atomic.finish();
}

pub fn sortRows(rows: []Row) void {
    std.sort.block(Row, rows, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            if (a.updated_at != b.updated_at) return a.updated_at > b.updated_at;
            return std.mem.order(u8, a.session_id, b.session_id) == .lt;
        }
    }.lessThan);
}

pub fn cloneRecord(allocator: std.mem.Allocator, input: anytype) !SessionRecord {
    const session_id = try allocator.dupe(u8, input.session_id);
    errdefer allocator.free(session_id);
    const title = try allocator.dupe(u8, input.title);
    errdefer allocator.free(title);
    const base_url = try allocator.dupe(u8, input.base_url);
    errdefer allocator.free(base_url);
    const api_key = try allocator.dupe(u8, input.api_key);
    errdefer allocator.free(api_key);
    const model = try allocator.dupe(u8, input.model);
    errdefer allocator.free(model);
    const system_prompt = try allocator.dupe(u8, input.system_prompt);
    errdefer allocator.free(system_prompt);
    const reasoning_effort = try allocator.dupe(u8, input.reasoning_effort);
    errdefer allocator.free(reasoning_effort);

    const messages = try cloneMessages(allocator, input.messages);
    errdefer {
        for (messages) |*message| deinitMessage(allocator, message);
        allocator.free(messages);
    }

    return .{
        .session_id = session_id,
        .title = title,
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .system_prompt = system_prompt,
        .thinking_enabled = input.thinking_enabled,
        .reasoning_effort = reasoning_effort,
        .stream = input.stream,
        .agent_enabled = input.agent_enabled,
        .created_at = input.created_at,
        .updated_at = input.updated_at,
        .messages = messages,
    };
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Store {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_HISTORY_BYTES) catch |err| switch (err) {
        error.FileNotFound => return Store.init(allocator),
        else => {
            log.warn("failed to read {s}: {}", .{ path, err });
            return err;
        },
    };
    defer allocator.free(bytes);

    return Store.fromJsonStringLenient(allocator, bytes);
}

pub fn loadDefault(allocator: std.mem.Allocator) !Store {
    const path = try defaultPath(allocator);
    defer allocator.free(path);
    return loadFromPath(allocator, path);
}

pub fn freeOwnedRecord(allocator: std.mem.Allocator, record: *SessionRecord) void {
    allocator.free(record.session_id);
    allocator.free(record.title);
    allocator.free(record.base_url);
    allocator.free(record.api_key);
    allocator.free(record.model);
    allocator.free(record.system_prompt);
    allocator.free(record.reasoning_effort);
    for (record.messages) |*message| freeOwnedMessage(allocator, message);
    allocator.free(record.messages);
    record.* = undefined;
}

pub fn cloneMessage(allocator: std.mem.Allocator, input: anytype) !MessageRecord {
    const content = try allocator.dupe(u8, input.content);
    errdefer allocator.free(content);
    const reasoning = try dupeOptionalString(allocator, input.reasoning);
    errdefer if (reasoning) |value| allocator.free(value);
    const usage_footer = try dupeOptionalString(allocator, input.usage_footer);
    errdefer if (usage_footer) |value| allocator.free(value);

    return .{
        .role = input.role,
        .content = content,
        .reasoning = reasoning,
        .usage_footer = usage_footer,
    };
}

pub fn deinitMessage(allocator: std.mem.Allocator, message: *MessageRecord) void {
    freeOwnedMessage(allocator, message);
}

pub fn freeOwnedMessage(allocator: std.mem.Allocator, message: *MessageRecord) void {
    allocator.free(message.content);
    if (message.reasoning) |reasoning| allocator.free(reasoning);
    if (message.usage_footer) |usage_footer| allocator.free(usage_footer);
    message.* = undefined;
}

pub fn freeRows(allocator: std.mem.Allocator, rows: []Row) void {
    for (rows) |*row| freeOwnedRow(allocator, row);
    allocator.free(rows);
}

fn dupeOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |slice| return try allocator.dupe(u8, slice);
    return null;
}

fn cloneRow(allocator: std.mem.Allocator, input: anytype) !Row {
    const session_id = try allocator.dupe(u8, input.session_id);
    errdefer allocator.free(session_id);
    const title = try allocator.dupe(u8, input.title);
    errdefer allocator.free(title);
    const model = try allocator.dupe(u8, input.model);
    errdefer allocator.free(model);

    return .{
        .session_id = session_id,
        .title = title,
        .model = model,
        .updated_at = input.updated_at,
    };
}

fn freeOwnedRow(allocator: std.mem.Allocator, row: *Row) void {
    allocator.free(row.session_id);
    allocator.free(row.title);
    allocator.free(row.model);
    row.* = undefined;
}

fn cloneMessages(allocator: std.mem.Allocator, message_inputs: anytype) ![]MessageRecord {
    const count = messageInputCount(message_inputs);
    const messages = try allocator.alloc(MessageRecord, count);
    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            freeOwnedMessage(allocator, &messages[initialized]);
        }
        allocator.free(messages);
    }

    switch (@typeInfo(@TypeOf(message_inputs))) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                for (message_inputs) |message| {
                    messages[initialized] = try cloneMessage(allocator, message);
                    initialized += 1;
                }
            },
            .one => switch (@typeInfo(pointer.child)) {
                .array => {
                    for (message_inputs) |message| {
                        messages[initialized] = try cloneMessage(allocator, message);
                        initialized += 1;
                    }
                },
                .@"struct" => |info| {
                    if (!info.is_tuple) @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple");
                    inline for (info.fields) |field| {
                        messages[initialized] = try cloneMessage(allocator, @field(message_inputs.*, field.name));
                        initialized += 1;
                    }
                },
                else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
            },
            else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
        },
        .array => {
            for (message_inputs) |message| {
                messages[initialized] = try cloneMessage(allocator, message);
                initialized += 1;
            }
        },
        .@"struct" => |info| {
            if (!info.is_tuple) @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple");
            inline for (info.fields) |field| {
                messages[initialized] = try cloneMessage(allocator, @field(message_inputs, field.name));
                initialized += 1;
            }
        },
        else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
    }

    return messages;
}

fn isLenientJsonLoadError(err: anyerror) bool {
    return switch (err) {
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        error.UnexpectedToken,
        error.InvalidNumber,
        error.InvalidEnumTag,
        error.DuplicateField,
        error.UnknownField,
        error.MissingField,
        error.LengthMismatch,
        error.InvalidCharacter,
        error.Overflow,
        error.BufferUnderrun,
        => true,
        else => false,
    };
}

pub fn defaultPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "APPDATA")) |appdata| {
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, "phantty", DEFAULT_HISTORY_BASENAME });
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "phantty", DEFAULT_HISTORY_BASENAME });
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".config", "phantty", DEFAULT_HISTORY_BASENAME });
    } else |_| {}
    return error.NoConfigPath;
}

fn messageInputCount(message_inputs: anytype) usize {
    return switch (@typeInfo(@TypeOf(message_inputs))) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => message_inputs.len,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.len,
                .@"struct" => |info| if (info.is_tuple) info.fields.len else @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
                else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
            },
            else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
        },
        .array => |array| array.len,
        .@"struct" => |info| if (info.is_tuple) info.fields.len else @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
        else => @compileError("agent_history messages must be an array, slice, pointer-to-array, or tuple"),
    };
}

test "agent_history: sorts sessions by updated_at descending" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "old",
        .title = "Old",
        .base_url = "https://api.example.com",
        .api_key = "k1",
        .model = "m1",
        .system_prompt = "p1",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 100,
        .updated_at = 100,
        .messages = &.{},
    });
    try store.upsertRecord(.{
        .session_id = "new",
        .title = "New",
        .base_url = "https://api.example.com",
        .api_key = "k2",
        .model = "m2",
        .system_prompt = "p2",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 200,
        .updated_at = 300,
        .messages = &.{},
    });

    const rows = try store.buildRows(allocator);
    defer freeRows(allocator, rows);

    try std.testing.expectEqualStrings("new", rows[0].session_id);
    try std.testing.expectEqualStrings("old", rows[1].session_id);
}

test "agent_history: json round trip preserves messages" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "Chat 1",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "m1",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 10,
        .updated_at = 20,
        .messages = &.{
            .{ .role = .user, .content = "hello", .reasoning = null, .usage_footer = null },
            .{ .role = .assistant, .content = "world", .reasoning = "r", .usage_footer = "u" },
        },
    });

    const json = try store.toJsonString(allocator);
    defer allocator.free(json);

    var parsed = try Store.fromJsonString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.records.items.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.records.items[0].messages.len);
    try std.testing.expectEqualStrings("world", parsed.records.items[0].messages[1].content);
}

test "agent_history: malformed json falls back to empty store" {
    const allocator = std.testing.allocator;
    var parsed = try Store.fromJsonStringLenient(allocator, "{not json");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.records.items.len);
}

test "agent_history: lenient parse propagates out of memory" {
    const json =
        \\{"records":[{"session_id":"s1","title":"Chat 1","base_url":"https://api.example.com","api_key":"secret","model":"m1","system_prompt":"system","thinking_enabled":true,"reasoning_effort":"high","stream":false,"agent_enabled":true,"created_at":10,"updated_at":20,"messages":[]}]}
    ;

    try expectLenientParseOutOfMemory(json);
}

test "agent_history: upsertOwnedRecord takes ownership and replaces existing record" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    const original = try cloneRecord(allocator, .{
        .session_id = "s1",
        .title = "Old",
        .base_url = "https://api.example.com",
        .api_key = "k1",
        .model = "m1",
        .system_prompt = "p1",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 10,
        .updated_at = 10,
        .messages = &.{},
    });
    try store.upsertOwnedRecord(original);

    const replacement = try cloneRecord(allocator, .{
        .session_id = "s1",
        .title = "New",
        .base_url = "https://api.example.com",
        .api_key = "k2",
        .model = "m2",
        .system_prompt = "p2",
        .thinking_enabled = true,
        .reasoning_effort = "medium",
        .stream = true,
        .agent_enabled = true,
        .created_at = 10,
        .updated_at = 20,
        .messages = &.{
            .{ .role = .assistant, .content = "updated", .reasoning = null, .usage_footer = null },
        },
    });
    try store.upsertOwnedRecord(replacement);

    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    try std.testing.expectEqualStrings("New", store.records.items[0].title);
    try std.testing.expectEqualStrings("updated", store.records.items[0].messages[0].content);
}

test "agent_history: upsert replaces existing session id instead of duplicating" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "same",
        .title = "First",
        .base_url = "https://api.example.com",
        .api_key = "a",
        .model = "m",
        .system_prompt = "p",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 1,
        .messages = &.{},
    });
    try store.upsertRecord(.{
        .session_id = "same",
        .title = "Second",
        .base_url = "https://api.example.com",
        .api_key = "b",
        .model = "m2",
        .system_prompt = "p2",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 10,
        .messages = &.{},
    });

    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    try std.testing.expectEqualStrings("Second", store.records.items[0].title);
}

test "agent_history: buildRows returns owned rows that survive store cleanup" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "s1",
        .title = "Chat 1",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "m1",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 10,
        .updated_at = 20,
        .messages = &.{},
    });

    const rows = try store.buildRows(allocator);
    defer freeRows(allocator, rows);

    store.clear();

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("s1", rows[0].session_id);
    try std.testing.expectEqualStrings("Chat 1", rows[0].title);
    try std.testing.expectEqualStrings("m1", rows[0].model);
}

fn expectLenientParseOutOfMemory(json: []const u8) !void {
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = Store.fromJsonStringLenient(failing_allocator.allocator(), json);
        if (result) |store| {
            var owned_store = store;
            owned_store.deinit();
            if (failing_allocator.has_induced_failure) return error.SwallowedOutOfMemory;
            continue;
        } else |err| switch (err) {
            error.OutOfMemory => return,
            else => return err,
        }
    }

    return error.MissingOutOfMemoryPath;
}
