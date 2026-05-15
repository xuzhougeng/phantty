# Agent History Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent global AI/Agent conversation history and show it in the existing left sidebar whenever the active tab is an AI/Agent tab.

**Architecture:** Introduce a dedicated `agent_history.zig` persistence module, extend `ai_chat.Session` with a stable `session_id` plus history serialization hooks, and branch the existing left sidebar container between file mode and agent-history mode. Keep file explorer internals file-specific; add a parallel lightweight history row model and tab lookup/reopen flow for persisted AI sessions.

**Tech Stack:** Zig 0.15.2, std.json, existing AppWindow/tab/input/renderer modules, Phantty AI chat runtime.

---

## File Structure

- Create: `src/agent_history.zig`
  - Own persistent history JSON schema, load/save helpers, in-memory record store, sort/normalize logic, and row projection for sidebar rendering.
- Modify: `src/ai_chat.zig`
  - Add `session_id`, history serialization/deserialization helpers, and persistence callbacks at session mutation points.
- Modify: `src/appwindow/tab.zig`
  - Add AI session reopen/find-by-id helpers and spawn-from-history path.
- Modify: `src/AppWindow.zig`
  - Wire global history store lifecycle into app-window startup/runtime helpers.
- Modify: `src/file_explorer.zig`
  - Add left-panel content mode switching plus agent-history list state, selection, and scrolling.
- Modify: `src/renderer/file_explorer_renderer.zig`
  - Render agent-history mode with the existing sidebar visual language.
- Modify: `src/input.zig`
  - Route sidebar keyboard, mouse, and wheel input to either file mode or history mode.
- Modify: `src/test_main.zig`
  - Import the new module so unit tests compile.

### Task 1: Create Persistent Agent History Store

**Files:**
- Create: `src/agent_history.zig`
- Modify: `src/test_main.zig`
- Test: `src/agent_history.zig`

- [ ] **Step 1: Write the failing tests**

Add these tests to `src/agent_history.zig` before implementation:

```zig
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
    defer allocator.free(rows);

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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`

Expected: FAIL because `src/agent_history.zig` and its `Store` API do not exist yet.

- [ ] **Step 3: Write the minimal history store implementation**

Create `src/agent_history.zig` with:

```zig
const std = @import("std");

pub const MessageRole = enum { user, assistant, tool };

pub const MessageRecord = struct {
    role: MessageRole,
    content: []u8,
    reasoning: ?[]u8 = null,
    usage_footer: ?[]u8 = null,
};

pub const SessionRecord = struct {
    session_id: []u8,
    title: []u8,
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    system_prompt: []u8,
    thinking_enabled: bool,
    reasoning_effort: []u8,
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

pub const Store = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(SessionRecord) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.records.items) |record| freeRecord(self.allocator, record);
        self.records.deinit(self.allocator);
    }

    pub fn upsertRecord(self: *Store, input: anytype) !void {
        if (self.findIndexBySessionId(input.session_id)) |idx| {
            freeRecord(self.allocator, self.records.items[idx]);
            self.records.items[idx] = try cloneRecord(self.allocator, input);
            return;
        }
        try self.records.append(self.allocator, try cloneRecord(self.allocator, input));
    }

    pub fn buildRows(self: *Store, allocator: std.mem.Allocator) ![]Row {
        const rows = try allocator.alloc(Row, self.records.items.len);
        for (self.records.items, 0..) |record, i| {
            rows[i] = .{
                .session_id = record.session_id,
                .title = record.title,
                .model = record.model,
                .updated_at = record.updated_at,
            };
        }
        std.sort.block(Row, rows, {}, struct {
            fn lessThan(_: void, a: Row, b: Row) bool {
                return a.updated_at > b.updated_at;
            }
        }.lessThan);
        return rows;
    }

    pub fn toJsonString(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, .{ .records = self.records.items }, .{});
    }

    pub fn fromJsonString(allocator: std.mem.Allocator, bytes: []const u8) !Store {
        var parsed = try std.json.parseFromSlice(struct { records: []SessionRecord }, allocator, bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var store = Store.init(allocator);
        errdefer store.deinit();
        for (parsed.value.records) |record| try store.upsertRecord(record);
        return store;
    }

    pub fn fromJsonStringLenient(allocator: std.mem.Allocator, bytes: []const u8) !Store {
        return fromJsonString(allocator, bytes) catch Store.init(allocator);
    }

    fn findIndexBySessionId(self: *Store, session_id: []const u8) ?usize {
        for (self.records.items, 0..) |record, i| {
            if (std.mem.eql(u8, record.session_id, session_id)) return i;
        }
        return null;
    }
};
```

Also add this import to `src/test_main.zig`:

```zig
_ = @import("agent_history.zig");
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`

Expected: PASS for the new `agent_history` tests.

- [ ] **Step 5: Commit**

```bash
git add src/agent_history.zig src/test_main.zig
git commit -m "feat: add persistent agent history store"
```

### Task 2: Extend AI Chat Sessions With History Serialization And Save Hooks

**Files:**
- Modify: `src/ai_chat.zig`
- Modify: `src/agent_history.zig`
- Test: `src/ai_chat.zig`

- [ ] **Step 1: Write the failing tests**

Add these tests near existing AI chat tests in `src/ai_chat.zig`:

```zig
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

    const record = try session.toHistoryRecord(allocator);
    defer agent_history.freeOwnedRecord(allocator, record);

    try std.testing.expect(record.agent_enabled);
    try std.testing.expectEqual(@as(usize, 1), record.messages.len);
    try std.testing.expectEqualStrings("hello", record.messages[0].content);
}

test "ai_chat: session loads from history record" {
    const allocator = std.testing.allocator;
    const record = try agent_history.cloneRecord(allocator, .{
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
    defer agent_history.freeOwnedRecord(allocator, record);

    const session = try Session.initFromHistoryRecord(allocator, record);
    defer session.deinit();

    try std.testing.expectEqualStrings("session-1", session.sessionId());
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`

Expected: FAIL because `Session.sessionId`, `Session.toHistoryRecord`, and `Session.initFromHistoryRecord` do not exist yet.

- [ ] **Step 3: Implement session-id support and history conversion**

In `src/ai_chat.zig`, add:

```zig
const agent_history = @import("agent_history.zig");
```

Extend `Session` with:

```zig
session_id_buf: [64]u8 = undefined,
session_id_len: usize = 0,
created_at_ms: i64 = 0,
updated_at_ms: i64 = 0,
history_on_change: ?*const fn (*Session) void = null,
```

Add methods:

```zig
pub fn sessionId(self: *const Session) []const u8 {
    return self.session_id_buf[0..self.session_id_len];
}

pub fn setHistoryChangeHook(self: *Session, hook: ?*const fn (*Session) void) void {
    self.history_on_change = hook;
}

pub fn initFromHistoryRecord(allocator: std.mem.Allocator, record: agent_history.SessionRecord) !*Session {
    var session = try init(
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
    session.copySessionId(record.session_id);
    session.created_at_ms = record.created_at;
    session.updated_at_ms = record.updated_at;
    for (record.messages) |msg| {
        try session.messages.append(allocator, .{
            .role = switch (msg.role) {
                .user => .user,
                .assistant => .assistant,
                .tool => .tool,
            },
            .content = try allocator.dupe(u8, msg.content),
            .reasoning = if (msg.reasoning) |r| try allocator.dupe(u8, r) else null,
            .usage_footer = if (msg.usage_footer) |u| try allocator.dupe(u8, u) else null,
        });
    }
    return session;
}

pub fn toHistoryRecord(self: *Session, allocator: std.mem.Allocator) !agent_history.SessionRecord {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.toHistoryRecordLocked(allocator);
}
```

Generate a new `session_id` inside `Session.init` with timestamp + counter or random bytes, store `created_at_ms` and `updated_at_ms`, and call a helper like this after any message mutation:

```zig
fn markHistoryDirtyLocked(self: *Session) void {
    self.updated_at_ms = std.time.milliTimestamp();
    if (self.history_on_change) |hook| hook(self);
}
```

Call `markHistoryDirtyLocked()` after:

- appending the user message in `submit`
- clearing messages in `clearMessages`
- final assistant/tool message append/update in request completion paths

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`

Expected: PASS for the new AI chat history tests and no regression in existing AI chat tests.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig src/agent_history.zig
git commit -m "feat: add ai chat history serialization hooks"
```

### Task 3: Wire Global History Store Into Tab And AppWindow Flows

**Files:**
- Modify: `src/AppWindow.zig`
- Modify: `src/appwindow/tab.zig`
- Modify: `src/ai_chat.zig`
- Modify: `src/agent_history.zig`
- Test: `src/agent_history.zig`

- [ ] **Step 1: Write the failing test**

Add this test to `src/agent_history.zig`:

```zig
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
```

- [ ] **Step 2: Run the tests to verify baseline behavior**

Run: `zig build test`

Expected: PASS after Task 1; if it fails, fix store replacement logic before continuing.

- [ ] **Step 3: Implement runtime store wiring**

In `src/AppWindow.zig`, add a threadlocal global store:

```zig
pub threadlocal var g_agent_history: ?*agent_history.Store = null;
```

Initialize it during `AppWindow.init` or first-window startup:

```zig
if (g_agent_history == null) {
    const store = allocator.create(agent_history.Store) catch return error.OutOfMemory;
    store.* = agent_history.loadDefault(allocator) catch agent_history.Store.init(allocator);
    g_agent_history = store;
}
```

Add a helper that persists a live session:

```zig
fn saveAiSessionToHistory(session: *ai_chat.Session) void {
    const store = g_agent_history orelse return;
    const record = session.toHistoryRecord(g_allocator orelse return) catch return;
    defer agent_history.freeOwnedRecord(g_allocator.?, record);
    store.upsertOwnedRecord(record) catch return;
    store.saveDefault() catch {};
}
```

Register that hook when spawning AI tabs.

In `src/appwindow/tab.zig`, add:

```zig
pub fn findAiTabBySessionId(session_id: []const u8) ?usize { ... }
pub fn switchToAiTabBySessionId(session_id: []const u8) bool { ... }
pub fn spawnAiChatTabFromHistoryRecord(allocator: std.mem.Allocator, record: agent_history.SessionRecord) bool { ... }
```

The reopen flow must:

- switch to an already-open matching AI tab if present
- otherwise create a new `ai_chat.Session` from the stored record
- install the history save hook on the loaded session

- [ ] **Step 4: Run the tests and a targeted build**

Run: `zig build test`

Expected: PASS.

Run: `zig build`

Expected: PASS and no compile errors from the new AppWindow/tab wiring.

- [ ] **Step 5: Commit**

```bash
git add src/AppWindow.zig src/appwindow/tab.zig src/ai_chat.zig src/agent_history.zig
git commit -m "feat: wire global agent history into ai tabs"
```

### Task 4: Add Left Sidebar Agent-History Mode State And Rendering

**Files:**
- Modify: `src/file_explorer.zig`
- Modify: `src/renderer/file_explorer_renderer.zig`
- Modify: `src/AppWindow.zig`
- Test: `src/file_explorer.zig`

- [ ] **Step 1: Write the failing test**

Add a small state test in `src/file_explorer.zig`:

```zig
test "file_explorer: agent history mode selection clamps to row count" {
    g_panel_mode = .agent_history;
    g_history_row_count = 2;
    g_history_selected = 10;
    clampHistorySelection();
    try std.testing.expectEqual(@as(?usize, 1), g_history_selected);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`

Expected: FAIL because `g_panel_mode`, `g_history_row_count`, and `clampHistorySelection` do not exist yet.

- [ ] **Step 3: Implement sidebar history mode state**

In `src/file_explorer.zig`, add:

```zig
pub const PanelMode = enum { files, agent_history };
pub threadlocal var g_panel_mode: PanelMode = .files;

pub const HistoryRow = struct {
    session_id_buf: [64]u8 = undefined,
    session_id_len: u8 = 0,
    title_buf: [128]u8 = undefined,
    title_len: u8 = 0,
    model_buf: [64]u8 = undefined,
    model_len: u8 = 0,
    updated_at: i64 = 0,
};

pub threadlocal var g_history_rows: [256]HistoryRow = undefined;
pub threadlocal var g_history_row_count: usize = 0;
pub threadlocal var g_history_selected: ?usize = null;
```

Add helpers:

```zig
pub fn setPanelMode(mode: PanelMode) void { ... }
pub fn syncAgentHistoryRows(store: *const agent_history.Store) void { ... }
pub fn moveHistorySelection(delta: i32) void { ... }
pub fn historySessionIdAt(idx: usize) ?[]const u8 { ... }
fn clampHistorySelection() void { ... }
```

In `src/renderer/file_explorer_renderer.zig`, branch early on `g_panel_mode`:

```zig
switch (file_explorer.g_panel_mode) {
    .files => renderFiles(...),
    .agent_history => renderAgentHistory(...),
}
```

Render `AGENT History` in the header and rows using the existing background/hover/selection colors. Show title as the primary line and model or relative timestamp as a secondary muted line if there is enough vertical space.

- [ ] **Step 4: Run the tests and build**

Run: `zig build test`

Expected: PASS.

Run: `zig build`

Expected: PASS with the renderer split compiled cleanly.

- [ ] **Step 5: Commit**

```bash
git add src/file_explorer.zig src/renderer/file_explorer_renderer.zig src/AppWindow.zig
git commit -m "feat: add sidebar agent history mode"
```

### Task 5: Route Shortcut, Keyboard, Mouse, And Scroll Input To History Mode

**Files:**
- Modify: `src/input.zig`
- Modify: `src/file_explorer.zig`
- Modify: `src/AppWindow.zig`
- Test: `src/file_explorer.zig`

- [ ] **Step 1: Write the failing test**

Add this test to `src/file_explorer.zig`:

```zig
test "file_explorer: moveHistorySelection walks selected row" {
    g_panel_mode = .agent_history;
    g_history_row_count = 3;
    g_history_selected = 0;
    moveHistorySelection(1);
    try std.testing.expectEqual(@as(?usize, 1), g_history_selected);
    moveHistorySelection(10);
    try std.testing.expectEqual(@as(?usize, 2), g_history_selected);
}
```

- [ ] **Step 2: Run the tests to verify they fail or are incomplete**

Run: `zig build test`

Expected: FAIL until `moveHistorySelection` behavior is finished.

- [ ] **Step 3: Implement input routing**

In `src/input.zig`, change `toggleFileExplorer()` to choose panel mode from the active tab:

```zig
pub fn toggleFileExplorer() void {
    file_explorer.toggle();
    if (!file_explorer.g_visible) { ... }

    if (AppWindow.activeAiChat()) |_| {
        file_explorer.setPanelMode(.agent_history);
        if (AppWindow.g_agent_history) |store| file_explorer.syncAgentHistoryRows(store);
    } else {
        file_explorer.setPanelMode(.files);
        // existing root-detection logic stays here
    }
    ...
}
```

Split sidebar handlers:

```zig
fn handleFileExplorerKey(ev: win32_backend.KeyEvent) bool {
    if (file_explorer.g_panel_mode == .agent_history) return handleAgentHistoryKey(ev);
    ...
}

fn handleAgentHistoryKey(ev: win32_backend.KeyEvent) bool {
    switch (ev.vk) {
        win32_backend.VK_ESCAPE => { file_explorer.g_focused = false; return true; },
        win32_backend.VK_UP => { file_explorer.moveHistorySelection(-1); return true; },
        win32_backend.VK_DOWN => { file_explorer.moveHistorySelection(1); return true; },
        win32_backend.VK_RETURN => { activateSelectedAgentHistoryRow(); return true; },
        else => return false,
    }
}
```

Add mouse support in `handleFileExplorerPress()`:

```zig
if (file_explorer.g_panel_mode == .agent_history) {
    handleAgentHistoryPress(xpos, ypos);
    return;
}
```

`handleAgentHistoryPress()` should:

- compute the clicked row from header height, row height, and scroll
- select it
- on double-click activate it

Add wheel routing in `handleMouseWheel()` so history mode scrolls its own list rather than file rows.

Activation helper:

```zig
fn activateSelectedAgentHistoryRow() void {
    const session_id = file_explorer.selectedHistorySessionId() orelse return;
    if (tab.switchToAiTabBySessionId(session_id)) return;
    const store = AppWindow.g_agent_history orelse return;
    const record = store.cloneRecordBySessionId(AppWindow.g_allocator orelse return, session_id) orelse return;
    defer agent_history.freeOwnedRecord(AppWindow.g_allocator.?, record);
    _ = AppWindow.spawnAiChatTabFromHistoryRecord(record);
}
```

- [ ] **Step 4: Run the tests and build**

Run: `zig build test`

Expected: PASS.

Run: `zig build`

Expected: PASS and `Ctrl+Shift+E` now shows history on AI tabs and files on terminal tabs.

- [ ] **Step 5: Commit**

```bash
git add src/input.zig src/file_explorer.zig src/AppWindow.zig src/appwindow/tab.zig
git commit -m "feat: show persistent agent history in sidebar"
```

### Task 6: Manual Verification And Windows Compatibility Check

**Files:**
- No code changes expected unless verification finds bugs

- [ ] **Step 1: Run the full Zig test suite**

Run: `zig build test`

Expected: PASS.

- [ ] **Step 2: Run a debug build**

Run: `zig build`

Expected: PASS and the app still builds for the normal debug target.

- [ ] **Step 3: Manually verify the history flow**

Run these manual checks in the built app:

1. Open an AI/Agent tab
2. Send two or more prompts
3. Close the AI tab
4. Open a fresh AI tab
5. Press `Ctrl+Shift+E`
6. Confirm the sidebar header says `AGENT History`
7. Confirm the previous conversation appears
8. Press `Enter` on that row
9. Confirm the conversation transcript is restored
10. Send another prompt
11. Reopen the sidebar and confirm the same session moved to the top
12. Quit and relaunch Phantty, then confirm the history list still exists from a fresh AI tab

- [ ] **Step 4: Run the Windows path compatibility check**

Run:

```powershell
$paths = git ls-files
$reserved = @('CON', 'PRN', 'AUX', 'NUL') + (1..9 | ForEach-Object { "COM$_"; "LPT$_" })
$violations = [System.Collections.Generic.List[object]]::new()
$collisions = [System.Collections.Generic.List[object]]::new()
$seen = @{}

foreach ($path in $paths) {
    foreach ($part in ($path -split '/')) {
        $stem = ($part -split '\.')[0].ToUpperInvariant()
        $reasons = @()
        if ($part.IndexOfAny([char[]]'<>:"\|?*') -ge 0) { $reasons += 'illegal_char' }
        if ($part.EndsWith(' ') -or $part.EndsWith('.')) { $reasons += 'trailing_space_or_dot' }
        if ($reserved -contains $stem) { $reasons += 'reserved_name' }
        if ($reasons.Count -gt 0) {
            $violations.Add([pscustomobject]@{ Path = $path; Part = $part; Reasons = ($reasons -join ',') })
        }
    }

    $key = $path.ToLowerInvariant()
    if ($seen.ContainsKey($key) -and $seen[$key] -ne $path) {
        $collisions.Add([pscustomobject]@{ A = $seen[$key]; B = $path })
    } else {
        $seen[$key] = $path
    }
}

"tracked_files=$($paths.Count)"
"windows_name_violations=$($violations.Count)"
$violations | ForEach-Object { "violation`t$($_.Path)`t$($_.Part)`t$($_.Reasons)" }
"casefold_collisions=$($collisions.Count)"
$collisions | ForEach-Object { "collision`t$($_.A)`t$($_.B)" }
$longest = $paths | Sort-Object Length -Descending | Select-Object -First 1
"max_path_length=$($longest.Length) $longest"
```

Expected: zero new violations and zero casefold collisions introduced by the feature work.

- [ ] **Step 5: Final commit if verification required follow-up fixes**

```bash
git add src/agent_history.zig src/ai_chat.zig src/appwindow/tab.zig src/AppWindow.zig src/file_explorer.zig src/renderer/file_explorer_renderer.zig src/input.zig src/test_main.zig
git commit -m "test: verify persistent agent history sidebar"
```
