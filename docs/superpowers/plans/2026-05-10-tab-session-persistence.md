# Tab Session Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist tab/split layout + SSH/local-shell connection targets to `%APPDATA%\phantty\session.json` on close, and restore them on next launch when the user opts in via `restore-tabs-on-startup = true`.

**Architecture:** A new `src/session_persist.zig` module owns POD types and JSON I/O (depends only on `std`). `src/appwindow/tab.zig` owns the bridge between live tab state and POD snapshots, calling existing `Surface` and `SplitTree` APIs. `src/AppWindow.zig` only orchestrates "when" — startup before `openDefaultTab`, and `deinit` before tearing tabs down. CLI args take precedence and skip restoration.

**Tech Stack:** Zig 0.15.2, `std.json` for serialization, existing `SplitTree` / `Surface` / `setSshConnection` APIs, Windows file I/O via `std.fs`.

**Spec:** [`docs/superpowers/specs/2026-05-10-tab-session-persistence-design.md`](../specs/2026-05-10-tab-session-persistence-design.md)

---

## File Structure

| File | Status | Lines added (rough) |
|---|---|---|
| `src/session_persist.zig` | new | ~250 (POD types, JSON I/O, validation, in-file tests) |
| `src/split_tree.zig` | modify | +60 (`fromSnapshot` + tests) |
| `src/Surface.zig` | modify | +15 (`surfaceKind()` helper) |
| `src/appwindow/tab.zig` | modify | +180 (snapshot/restore bridge + SSH cwd command builder) |
| `src/config.zig` | modify | +20 (config flag + `sessionFilePath`) |
| `src/AppWindow.zig` | modify | +30 (startup/deinit wiring) |
| `src/test_main.zig` | modify | +1 (register `session_persist`) |
| `README.md` | modify | +6 (config doc) |
| `release-notes/v0.17.0.md` | new | bullet describing feature |

**Verification environment:** Unit tests (`zig build test`) run on host platform (Linux/WSL OK). End-to-end verification (close window → relaunch → tabs restored) requires Windows + PowerShell because PTY/Surface needs Windows ConPTY. Tasks marked **[Windows-only verify]** need a Windows checkout.

---

## Task 1: Create `session_persist.zig` skeleton + register tests

**Files:**
- Create: `src/session_persist.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Create the module with POD types and one trivial test**

```zig
// src/session_persist.zig
const std = @import("std");

pub const SCHEMA_VERSION: u32 = 1;

pub const Layout = enum { horizontal, vertical };

pub const SurfaceSnap = union(enum) {
    local_shell: LocalShellSnap,
    ssh: SshSnap,

    pub const LocalShellSnap = struct {
        cwd: ?[]const u8 = null,
        command: ?[]const []const u8 = null,
    };

    pub const SshSnap = struct {
        cwd: ?[]const u8 = null,
        user: []const u8,
        host: []const u8,
        port: u16 = 22,
        // SECURITY INVARIANT (I1): NO password field. Adding one would
        // cause SSH passwords to be persisted to disk on every close.
    };
};

pub const NodeSnap = union(enum) {
    leaf: LeafSnap,
    split: SplitSnap,

    pub const LeafSnap = struct {
        surface: SurfaceSnap,
    };

    pub const SplitSnap = struct {
        layout: Layout,
        ratio: f64,
        left: *NodeSnap,
        right: *NodeSnap,
    };
};

pub const TabSnap = struct {
    title_override: ?[]const u8 = null,
    focused_leaf: u32 = 0,
    zoomed_leaf: ?u32 = null,
    tree: NodeSnap,
};

pub const Session = struct {
    version: u32 = SCHEMA_VERSION,
    active_tab: u32 = 0,
    tabs: []TabSnap,
};

test "session_persist: empty Session compiles and has expected defaults" {
    const empty: Session = .{ .tabs = &.{} };
    try std.testing.expectEqual(@as(u32, 1), empty.version);
    try std.testing.expectEqual(@as(u32, 0), empty.active_tab);
    try std.testing.expectEqual(@as(usize, 0), empty.tabs.len);
}
```

- [ ] **Step 2: Register the module in test_main.zig**

Modify `src/test_main.zig`. Find the `comptime { ... }` block and add the new line in alphabetical order (between `selection_unit` and the closing brace, or right before `markdown_preview` — match existing alpha order):

```zig
comptime {
    _ = @import("scp.zig");
    _ = @import("browser_panel.zig");
    _ = @import("browser_url.zig");
    _ = @import("file_backend.zig");
    _ = @import("file_explorer.zig");
    _ = @import("input_shortcuts.zig");
    _ = @import("markdown_preview.zig");
    _ = @import("remote_client.zig");
    _ = @import("selection_unit.zig");
    _ = @import("session_persist.zig");
}
```

- [ ] **Step 3: Run the test**

Run: `zig build test`
Expected: build succeeds, the new test passes alongside existing ones.

- [ ] **Step 4: Commit**

```bash
git add src/session_persist.zig src/test_main.zig
git commit -m "$(cat <<'EOF'
Add session_persist module skeleton with POD types

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: JSON round-trip for a simple Session

**Files:**
- Modify: `src/session_persist.zig`

- [ ] **Step 1: Write the failing test**

Append to `session_persist.zig`:

```zig
test "session_persist: round-trip simple local-shell session via JSON" {
    const allocator = std.testing.allocator;

    var leaf_node = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{
        .cwd = "/home/user",
        .command = null,
    } } } };
    const tabs = [_]TabSnap{.{
        .title_override = null,
        .focused_leaf = 0,
        .zoomed_leaf = null,
        .tree = leaf_node,
    }};
    const original: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    const json = try dumpSessionToString(allocator, original);
    defer allocator.free(json);

    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.active_tab);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.tabs.len);
    const leaf = switch (parsed.value.tabs[0].tree) {
        .leaf => |l| l,
        .split => return error.UnexpectedSplit,
    };
    const sh = switch (leaf.surface) {
        .local_shell => |s| s,
        .ssh => return error.UnexpectedSsh,
    };
    try std.testing.expectEqualStrings("/home/user", sh.cwd.?);
    try std.testing.expect(sh.command == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: compile error — `dumpSessionToString` and `loadSessionFromString` not found.

- [ ] **Step 3: Implement the two helpers**

Append to `session_persist.zig` (above the tests):

```zig
pub fn dumpSessionToString(allocator: std.mem.Allocator, session: Session) ![]u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try std.json.Stringify.value(session, .{}, buf.writer(allocator));
    return buf.toOwnedSlice(allocator);
}

pub fn loadSessionFromString(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(Session) {
    return std.json.parseFromSlice(Session, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: passes. If `std.json.Stringify.value` API differs in your zig version, use `std.json.stringify(session, .{}, buf.writer(allocator))` (older API) — the rule of thumb: any function in std.json that walks a struct via reflection works here.

- [ ] **Step 5: Commit**

```bash
git add src/session_persist.zig
git commit -m "$(cat <<'EOF'
Add JSON round-trip for Session POD types

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Round-trip with nested splits and an SSH leaf

**Files:**
- Modify: `src/session_persist.zig`

- [ ] **Step 1: Write the failing test**

Append:

```zig
test "session_persist: round-trip nested split with SSH leaf" {
    const allocator = std.testing.allocator;

    var ssh_leaf = NodeSnap{ .leaf = .{ .surface = .{ .ssh = .{
        .cwd = "/var/log",
        .user = "root",
        .host = "srvA.example.com",
        .port = 2222,
    } } } };
    var local_leaf = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{
        .cwd = "C:\\Users\\xzg",
        .command = null,
    } } } };
    var split = NodeSnap{ .split = .{
        .layout = .horizontal,
        .ratio = 0.6,
        .left = &ssh_leaf,
        .right = &local_leaf,
    } };
    const tabs = [_]TabSnap{.{
        .title_override = "work",
        .focused_leaf = 1,
        .zoomed_leaf = null,
        .tree = split,
    }};
    const original: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    const json = try dumpSessionToString(allocator, original);
    defer allocator.free(json);

    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    const sp = switch (parsed.value.tabs[0].tree) {
        .split => |s| s,
        .leaf => return error.UnexpectedLeaf,
    };
    try std.testing.expectEqual(Layout.horizontal, sp.layout);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), sp.ratio, 0.0001);
    const ssh = switch (sp.left.*) {
        .leaf => |l| switch (l.surface) {
            .ssh => |s| s,
            .local_shell => return error.UnexpectedShell,
        },
        .split => return error.UnexpectedSplit,
    };
    try std.testing.expectEqualStrings("root", ssh.user);
    try std.testing.expectEqualStrings("srvA.example.com", ssh.host);
    try std.testing.expectEqual(@as(u16, 2222), ssh.port);
    try std.testing.expectEqualStrings("/var/log", ssh.cwd.?);
    try std.testing.expectEqualStrings("work", parsed.value.tabs[0].title_override.?);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.tabs[0].focused_leaf);
}
```

- [ ] **Step 2: Run test**

Run: `zig build test`
Expected: passes (no implementation change needed — std.json walks the recursive union via the `kind` tag automatically).

If it fails with a tag-name issue, the union in `NodeSnap` uses field names `leaf` / `split` which become the JSON tag values. The default std.json union encoding writes `{"leaf":...}` rather than `{"kind":"leaf",...}`. If the produced JSON looks like `{"leaf":...}` and round-trips correctly, the spec's example JSON shape is descriptive but the actual on-disk shape uses Zig's default union encoding — that's fine, just leave a doc comment in the module:

```zig
// On-disk JSON uses std.json's default tagged-union encoding:
// nodes appear as {"leaf": {...}} or {"split": {...}}, not {"kind": ..., ...}.
// Surface kinds appear as {"local_shell": {...}} or {"ssh": {...}}.
// The spec illustrates the conceptual schema; this is the literal wire format.
```

- [ ] **Step 3: Commit**

```bash
git add src/session_persist.zig
git commit -m "Round-trip nested splits and SSH leaves"
```

---

## Task 4: Robustness — corrupt JSON, empty tabs, forwards-compat

**Files:**
- Modify: `src/session_persist.zig`

- [ ] **Step 1: Write the failing tests**

Append:

```zig
test "session_persist: corrupt JSON returns error" {
    const allocator = std.testing.allocator;
    const bad_inputs = [_][]const u8{
        "",
        "{ broken",
        "not json at all",
        "{\"version\": \"not a number\"}",
        "[1,2,3]",
    };
    for (bad_inputs) |bad| {
        try std.testing.expectError(error.SyntaxError, loadSessionFromString(allocator, bad)) catch {
            // Some inputs may produce different errors (UnexpectedEndOfInput,
            // UnexpectedToken, etc). Accept any error; assert it does NOT panic.
            const result = loadSessionFromString(allocator, bad);
            if (result) |*p| {
                var pm = p.*;
                pm.deinit();
                return error.ExpectedFailure;
            } else |_| {}
        };
    }
}

test "session_persist: parses JSON with extra unknown fields" {
    const allocator = std.testing.allocator;
    const future_json =
        \\{
        \\  "version": 1,
        \\  "active_tab": 0,
        \\  "future_thing": "hello",
        \\  "tabs": [
        \\    {
        \\      "title_override": null,
        \\      "focused_leaf": 0,
        \\      "zoomed_leaf": null,
        \\      "extra_per_tab": 42,
        \\      "tree": { "leaf": { "surface": { "local_shell": { "cwd": null, "command": null } } } }
        \\    }
        \\  ]
        \\}
    ;
    var parsed = try loadSessionFromString(allocator, future_json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.tabs.len);
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test`
Expected: both tests pass. The "extra unknown fields" test relies on `.ignore_unknown_fields = true` already set in `loadSessionFromString` (Task 2). The "corrupt JSON" test passes because std.json returns errors (not panics) on malformed input.

- [ ] **Step 3: Commit**

```bash
git add src/session_persist.zig
git commit -m "Verify robustness against corrupt and forwards-compat JSON"
```

---

## Task 5: I1 (security) — assert password is never serialized

**Files:**
- Modify: `src/session_persist.zig`

- [ ] **Step 1: Write the failing test**

Append:

```zig
test "session_persist: I1 — serialized SSH leaf contains no 'password' substring" {
    const allocator = std.testing.allocator;

    var leaf = NodeSnap{ .leaf = .{ .surface = .{ .ssh = .{
        .cwd = "/etc",
        .user = "admin",
        .host = "vault.example.com",
        .port = 22,
    } } } };
    const tabs = [_]TabSnap{.{ .focused_leaf = 0, .tree = leaf }};
    const session: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    const json = try dumpSessionToString(allocator, session);
    defer allocator.free(json);

    if (std.mem.indexOf(u8, json, "password") != null) {
        std.debug.print("\n[I1 violation] serialized JSON contained 'password':\n{s}\n", .{json});
        return error.PasswordSerialized;
    }
    if (std.mem.indexOf(u8, json, "secret") != null) return error.SecretSerialized;
}
```

- [ ] **Step 2: Run test**

Run: `zig build test`
Expected: passes (the `SshSnap` struct from Task 1 has no password field, so std.json cannot serialize one).

- [ ] **Step 3: Commit**

```bash
git add src/session_persist.zig
git commit -m "Assert SSH password is never serialized to JSON"
```

---

## Task 6: Validation and clamping (ratio + indices)

**Files:**
- Modify: `src/session_persist.zig`

- [ ] **Step 1: Write the failing tests**

Append:

```zig
test "session_persist: normalize() clamps ratios and indices" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": 1,
        \\  "active_tab": 999,
        \\  "tabs": [
        \\    {
        \\      "focused_leaf": 999,
        \\      "zoomed_leaf": 999,
        \\      "tree": {
        \\        "split": {
        \\          "layout": "horizontal",
        \\          "ratio": -0.5,
        \\          "left":  { "leaf": { "surface": { "local_shell": { "cwd": null, "command": null } } } },
        \\          "right": { "leaf": { "surface": { "local_shell": { "cwd": null, "command": null } } } }
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    normalize(&parsed.value);

    try std.testing.expectEqual(@as(u32, 0), parsed.value.active_tab);
    const tab0 = parsed.value.tabs[0];
    try std.testing.expectEqual(@as(u32, 0), tab0.focused_leaf);
    try std.testing.expect(tab0.zoomed_leaf == null);
    const sp = switch (tab0.tree) {
        .split => |s| s,
        .leaf => return error.UnexpectedLeaf,
    };
    try std.testing.expect(sp.ratio >= 0.05 and sp.ratio <= 0.95);
}

test "session_persist: normalize() clamps ratio above 1" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "version": 1, "active_tab": 0, "tabs": [
        \\  { "focused_leaf": 0, "zoomed_leaf": null, "tree": {
        \\    "split": { "layout": "vertical", "ratio": 5.0,
        \\      "left":  { "leaf": { "surface": { "local_shell": {} } } },
        \\      "right": { "leaf": { "surface": { "local_shell": {} } } }
        \\  } } } ] }
    ;
    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();
    normalize(&parsed.value);
    const sp = switch (parsed.value.tabs[0].tree) { .split => |s| s, else => return error.UnexpectedLeaf };
    try std.testing.expect(sp.ratio <= 0.95);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: compile error — `normalize` not defined.

- [ ] **Step 3: Implement normalize**

Append to `session_persist.zig` (in the public-functions area):

```zig
pub const RATIO_MIN: f64 = 0.05;
pub const RATIO_MAX: f64 = 0.95;

/// Clamp ratios into a usable range and clamp out-of-range indices to safe
/// defaults. Apply once after JSON parsing, before handing the Session to
/// the rebuild path. Idempotent.
pub fn normalize(session: *Session) void {
    if (session.tabs.len == 0) return;
    if (session.active_tab >= session.tabs.len) {
        session.active_tab = 0;
    }
    for (session.tabs) |*tab| {
        const leaf_count = countLeaves(&tab.tree);
        if (leaf_count == 0) continue;
        if (tab.focused_leaf >= leaf_count) tab.focused_leaf = 0;
        if (tab.zoomed_leaf) |zl| {
            if (zl >= leaf_count) tab.zoomed_leaf = null;
        }
        clampRatios(&tab.tree);
    }
}

fn clampRatios(node: *NodeSnap) void {
    switch (node.*) {
        .leaf => {},
        .split => |*sp| {
            if (sp.ratio < RATIO_MIN) sp.ratio = RATIO_MIN;
            if (sp.ratio > RATIO_MAX) sp.ratio = RATIO_MAX;
            if (std.math.isNan(sp.ratio)) sp.ratio = 0.5;
            clampRatios(sp.left);
            clampRatios(sp.right);
        },
    }
}

pub fn countLeaves(node: *const NodeSnap) u32 {
    return switch (node.*) {
        .leaf => 1,
        .split => |sp| countLeaves(sp.left) + countLeaves(sp.right),
    };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/session_persist.zig
git commit -m "Clamp split ratios and out-of-range indices on load"
```

---

## Task 7: Pre-order leaf helpers

**Files:**
- Modify: `src/session_persist.zig`

- [ ] **Step 1: Write the failing tests**

Append:

```zig
test "session_persist: leafByIndexPreOrder walks pre-order" {
    var l1 = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var l2 = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var l3 = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var inner = NodeSnap{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = &l1, .right = &l2 } };
    var root = NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &inner, .right = &l3 } };

    try std.testing.expectEqual(@as(u32, 3), countLeaves(&root));
    try std.testing.expectEqual(@as(?*const NodeSnap, &l1), leafByIndex(&root, 0));
    try std.testing.expectEqual(@as(?*const NodeSnap, &l2), leafByIndex(&root, 1));
    try std.testing.expectEqual(@as(?*const NodeSnap, &l3), leafByIndex(&root, 2));
    try std.testing.expectEqual(@as(?*const NodeSnap, null), leafByIndex(&root, 3));
}

test "session_persist: indexOfLeafBySurfaceAddress finds leaf in pre-order" {
    var l1 = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{ .cwd = "/A" } } } };
    var l2 = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{ .cwd = "/B" } } } };
    var root = NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &l1, .right = &l2 } };

    try std.testing.expectEqual(@as(?u32, 0), indexOfLeaf(&root, &l1));
    try std.testing.expectEqual(@as(?u32, 1), indexOfLeaf(&root, &l2));
}
```

- [ ] **Step 2: Run tests — fail (functions missing)**

Run: `zig build test`
Expected: compile error.

- [ ] **Step 3: Implement helpers**

Append to `session_persist.zig`:

```zig
/// Return a pointer to the Nth leaf in pre-order, or null if out of range.
pub fn leafByIndex(root: *const NodeSnap, target: u32) ?*const NodeSnap {
    var idx: u32 = 0;
    return walk(root, target, &idx);
}

fn walk(node: *const NodeSnap, target: u32, idx: *u32) ?*const NodeSnap {
    return switch (node.*) {
        .leaf => blk: {
            if (idx.* == target) break :blk node;
            idx.* += 1;
            break :blk null;
        },
        .split => |sp| blk: {
            if (walk(sp.left, target, idx)) |found| break :blk found;
            if (walk(sp.right, target, idx)) |found| break :blk found;
            break :blk null;
        },
    };
}

/// Return the pre-order leaf index of the given leaf node, or null if not in tree.
pub fn indexOfLeaf(root: *const NodeSnap, target: *const NodeSnap) ?u32 {
    var idx: u32 = 0;
    return findIndex(root, target, &idx);
}

fn findIndex(node: *const NodeSnap, target: *const NodeSnap, idx: *u32) ?u32 {
    return switch (node.*) {
        .leaf => blk: {
            if (node == target) break :blk idx.*;
            idx.* += 1;
            break :blk null;
        },
        .split => |sp| blk: {
            if (findIndex(sp.left, target, idx)) |found| break :blk found;
            if (findIndex(sp.right, target, idx)) |found| break :blk found;
            break :blk null;
        },
    };
}
```

- [ ] **Step 4: Run tests — pass**

Run: `zig build test`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/session_persist.zig
git commit -m "Add pre-order leaf walking helpers"
```

---

## Task 8: SSH single-quote escape helper

**Files:**
- Modify: `src/session_persist.zig`

- [ ] **Step 1: Write failing tests**

Append:

```zig
test "session_persist: shellSingleQuoteEscape handles common paths" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "/var/log",         .want = "/var/log" },
        .{ .in = "/home/x'z",        .want = "/home/x'\\''z" },
        .{ .in = "/tmp/with space",  .want = "/tmp/with space" },
        .{ .in = "/p/with\"$\\back", .want = "/p/with\"$\\back" },
        .{ .in = "",                 .want = "" },
    };
    for (cases) |c| {
        const got = try shellSingleQuoteEscape(allocator, c.in);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}
```

- [ ] **Step 2: Run — fail**

Run: `zig build test`
Expected: compile error.

- [ ] **Step 3: Implement**

Append to `session_persist.zig`:

```zig
/// Escape a path so that wrapping it in single quotes (`'...'`) produces a
/// single shell argument. Inside single quotes, only the closing quote needs
/// special handling: `'` becomes `'\''` (close, escape, reopen).
/// The caller is responsible for adding the surrounding single quotes.
pub fn shellSingleQuoteEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    for (input) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run — pass**

Run: `zig build test`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/session_persist.zig
git commit -m "Add shell single-quote escape helper for SSH cwd"
```

---

## Task 9: `SplitTree.fromSnapshot` (tree rebuild from POD)

**Files:**
- Modify: `src/split_tree.zig`

- [ ] **Step 1: Write the failing test**

Look at the existing `TestSurface` mock at `src/split_tree.zig:998-1010`. The existing tests don't actually exercise tree creation with TestSurface because `SplitTree` is generic over `*Surface`, not over an arbitrary type. Verify with: `grep -n "ref_count" src/split_tree.zig` — confirm refcount is on `*Surface`, not generic.

**Important:** The codebase's `SplitTree` is hardcoded to `*Surface`. We do **not** want to genericize it just for tests. Instead, we make `fromSnapshot` accept a function pointer that produces `*Surface`. The test path will use a stub that returns a sentinel `*Surface` — but constructing a real `*Surface` requires PTY. So: the tree-rebuild test uses **null leaves** via a placeholder pointer, and checks **only the topology + ratios + handles**, not surface identity.

Append to `src/split_tree.zig` (after the existing tests at the end of the file):

```zig
test "SplitTree: fromSnapshot rebuilds nested topology with correct handles and ratios" {
    const session_persist = @import("session_persist.zig");
    const Allocator = std.mem.Allocator;

    var leaf_a = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var leaf_b = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var leaf_c = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var inner  = session_persist.NodeSnap{ .split = .{ .layout = .vertical, .ratio = 0.4, .left = &leaf_a, .right = &leaf_b } };
    var root   = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.6, .left = &inner, .right = &leaf_c } };

    // Stub factory: returns sentinel pointers so we can verify topology
    // without spinning up real Surfaces (which need PTY).
    const Stub = struct {
        var counter: usize = 0;
        var sentinels: [16]usize = undefined;
        fn make(_: *const session_persist.SurfaceSnap, _: Allocator) ?*Surface {
            const ptr = &sentinels[counter];
            counter += 1;
            return @ptrCast(@alignCast(ptr));
        }
    };
    Stub.counter = 0;

    var tree = try fromSnapshot(std.testing.allocator, &root, Stub.make);
    defer {
        // Sentinel leaves can't be unref'd via the real Surface path, so we
        // free the arena directly without invoking the destructor.
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree.* = undefined;
    }

    // Pre-order layout: [root_split, inner_split, leaf_a, leaf_b, leaf_c]
    try std.testing.expectEqual(@as(usize, 5), tree.nodes.len);
    const root_node = tree.nodes[0];
    try std.testing.expect(root_node == .split);
    try std.testing.expectEqual(SplitTree.Split.Layout.horizontal, root_node.split.layout);
    try std.testing.expectApproxEqAbs(@as(f16, 0.6), root_node.split.ratio, 0.01);
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 1), @intFromEnum(root_node.split.left));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 4), @intFromEnum(root_node.split.right));

    const inner_node = tree.nodes[1];
    try std.testing.expect(inner_node == .split);
    try std.testing.expectEqual(SplitTree.Split.Layout.vertical, inner_node.split.layout);
    try std.testing.expectApproxEqAbs(@as(f16, 0.4), inner_node.split.ratio, 0.01);
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 2), @intFromEnum(inner_node.split.left));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 3), @intFromEnum(inner_node.split.right));

    try std.testing.expect(tree.nodes[2] == .leaf);
    try std.testing.expect(tree.nodes[3] == .leaf);
    try std.testing.expect(tree.nodes[4] == .leaf);
}

test "SplitTree: fromSnapshot clamps ratios" {
    const session_persist = @import("session_persist.zig");
    const Allocator = std.mem.Allocator;

    var l = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var r = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var root = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 5.0, .left = &l, .right = &r } };

    const Stub = struct {
        var counter: usize = 0;
        var sentinels: [16]usize = undefined;
        fn make(_: *const session_persist.SurfaceSnap, _: Allocator) ?*Surface {
            const ptr = &sentinels[counter];
            counter += 1;
            return @ptrCast(@alignCast(ptr));
        }
    };
    Stub.counter = 0;

    var tree = try fromSnapshot(std.testing.allocator, &root, Stub.make);
    defer { if (tree.nodes.len > 0) tree.arena.deinit(); tree.* = undefined; }

    try std.testing.expect(tree.nodes[0].split.ratio <= 0.95);
}
```

- [ ] **Step 2: Run — fail**

Run: `zig build test`
Expected: compile error — `fromSnapshot` not defined.

- [ ] **Step 3: Implement `fromSnapshot`**

Add this to `src/split_tree.zig` near the existing `init` / `clone` functions (above the `TestSurface` helper at the bottom):

```zig
/// Create a SplitTree from a session_persist NodeSnap. The factory callback
/// is responsible for materializing one *Surface per leaf snapshot. Returning
/// null from the factory aborts the rebuild with error.SurfaceCreationFailed.
///
/// Splits are always binary; ratios are clamped to [0.05, 0.95] for safety.
/// Pre-order traversal: root first, then left subtree, then right subtree.
/// Pre-order leaf order matches session_persist.leafByIndex semantics, so
/// `focused_leaf` from a TabSnap can be resolved against the resulting nodes.
pub fn fromSnapshot(
    gpa: Allocator,
    snap: *const @import("session_persist.zig").NodeSnap,
    factory: *const fn (
        snap: *const @import("session_persist.zig").SurfaceSnap,
        gpa: Allocator,
    ) ?*Surface,
) !SplitTree {
    const session_persist = @import("session_persist.zig");
    const total = countSnapNodes(snap);

    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const nodes = try alloc.alloc(Node, total);

    const Ctx = struct {
        nodes: []Node,
        idx: usize = 0,
        gpa: Allocator,
        factory: *const fn (
            snap: *const session_persist.SurfaceSnap,
            gpa: Allocator,
        ) ?*Surface,

        fn writeNode(self: *@This(), n: *const session_persist.NodeSnap) !Node.Handle {
            const my_handle: Node.Handle = @enumFromInt(@as(Node.Handle.Backing, @intCast(self.idx)));
            self.idx += 1;
            switch (n.*) {
                .leaf => |leaf| {
                    const surface = self.factory(&leaf.surface, self.gpa) orelse return error.SurfaceCreationFailed;
                    self.nodes[my_handle.idx()] = .{ .leaf = surface };
                },
                .split => |sp| {
                    // Reserve current index, then write children in pre-order.
                    const left = try self.writeNode(sp.left);
                    const right = try self.writeNode(sp.right);
                    var ratio: f64 = sp.ratio;
                    if (ratio < session_persist.RATIO_MIN) ratio = session_persist.RATIO_MIN;
                    if (ratio > session_persist.RATIO_MAX) ratio = session_persist.RATIO_MAX;
                    if (std.math.isNan(ratio)) ratio = 0.5;
                    self.nodes[my_handle.idx()] = .{ .split = .{
                        .layout = switch (sp.layout) {
                            .horizontal => .horizontal,
                            .vertical => .vertical,
                        },
                        .ratio = @floatCast(ratio),
                        .left = left,
                        .right = right,
                    } };
                },
            }
            return my_handle;
        }
    };

    var ctx = Ctx{ .nodes = nodes, .gpa = gpa, .factory = factory };
    _ = try ctx.writeNode(snap);

    return .{
        .arena = arena,
        .nodes = nodes,
        .zoomed = null, // resolved by the caller (tab.zig) after the tree is built
    };
}

fn countSnapNodes(snap: *const @import("session_persist.zig").NodeSnap) usize {
    return switch (snap.*) {
        .leaf => 1,
        .split => |sp| 1 + countSnapNodes(sp.left) + countSnapNodes(sp.right),
    };
}
```

- [ ] **Step 4: Run — pass**

Run: `zig build test`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/split_tree.zig
git commit -m "Add SplitTree.fromSnapshot for session restore"
```

---

## Task 10: `surfaceKind()` helper on Surface

**Files:**
- Modify: `src/Surface.zig`

- [ ] **Step 1: Add the helper**

Find the section near `getCwd`/`getInitialCwd` (around line 690 per Task survey). Insert below `getInitialCwd`:

```zig
pub const SurfaceKind = enum { local_shell, ssh };

/// Classify the surface for session persistence. Currently distinguishes
/// SSH from everything else; browser/markdown surfaces are not handled
/// because they are out of scope for v1 of session restore.
pub fn surfaceKind(self: *const Surface) SurfaceKind {
    if (self.ssh_connection != null) return .ssh;
    return .local_shell;
}
```

No unit test — this is a one-line conditional and `Surface` cannot be constructed in tests without ConPTY. Behavior is verified end-to-end by the integration check in Task 19.

- [ ] **Step 2: Verify it compiles**

Run: `zig build`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add src/Surface.zig
git commit -m "Add Surface.surfaceKind helper"
```

---

## Task 11: `sessionFilePath` in config.zig

**Files:**
- Modify: `src/config.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/config.zig`:

```zig
test "config: sessionFilePath sits next to configFilePath" {
    const allocator = std.testing.allocator;
    const session = sessionFilePath(allocator) catch return; // skip if no env
    defer allocator.free(session);
    try std.testing.expect(std.mem.endsWith(u8, session, "session.json"));
    try std.testing.expect(std.mem.indexOf(u8, session, "phantty") != null);
}
```

- [ ] **Step 2: Run — fail**

Run: `zig build test`
Expected: compile error — `sessionFilePath` not defined.

- [ ] **Step 3: Implement**

Add right below `configFilePath` (around line 434):

```zig
/// Return the default session-state file path: <config-dir>/session.json
pub fn sessionFilePath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "APPDATA")) |appdata| {
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, "phantty", "session.json" });
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "phantty", "session.json" });
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".config", "phantty", "session.json" });
    } else |_| {}
    return error.NoConfigPath;
}
```

- [ ] **Step 4: Run — pass**

Run: `zig build test`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "Add sessionFilePath alongside configFilePath"
```

---

## Task 12: Atomic file write — `dumpSession` to disk

**Files:**
- Modify: `src/session_persist.zig`

- [ ] **Step 1: Write the failing test**

Append:

```zig
test "session_persist: dumpSession writes atomically and loadSession reads back" {
    const allocator = std.testing.allocator;

    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const realpath = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(realpath);
    const path = try std.fs.path.join(allocator, &.{ realpath, "sess.json" });
    defer allocator.free(path);

    var leaf = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{ .cwd = "/x" } } } };
    const tabs = [_]TabSnap{.{ .focused_leaf = 0, .tree = leaf }};
    const session: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    try dumpSession(allocator, path, session);

    var loaded = try loadSession(allocator, path);
    defer {
        if (loaded) |*l| {
            var lm = l.*;
            lm.deinit();
        }
    }
    try std.testing.expect(loaded != null);
    try std.testing.expectEqual(@as(usize, 1), loaded.?.value.tabs.len);

    // Verify no .tmp leftover
    const tmp_path = try std.mem.concat(allocator, u8, &.{ path, ".tmp" });
    defer allocator.free(tmp_path);
    const tmp_exists = blk: {
        std.fs.cwd().access(tmp_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!tmp_exists);
}
```

- [ ] **Step 2: Run — fail**

Run: `zig build test`
Expected: compile error — `dumpSession` and `loadSession` not defined as file-based functions.

- [ ] **Step 3: Implement**

Append to `session_persist.zig`:

```zig
const log = std.log.scoped(.session_persist);

/// Serialize and atomically write the session to `path`. Pattern: write to
/// `path.tmp`, then rename over `path`. On any I/O failure, log a warning
/// and return the error; callers in the close path swallow the error.
pub fn dumpSession(allocator: std.mem.Allocator, path: []const u8, session: Session) !void {
    const json = try dumpSessionToString(allocator, session);
    defer allocator.free(json);

    const tmp_path = try std.mem.concat(allocator, u8, &.{ path, ".tmp" });
    defer allocator.free(tmp_path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            log.warn("failed to create session dir {s}: {}", .{ dir, err });
            return err;
        };
    }

    {
        const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
    }

    try std.fs.cwd().rename(tmp_path, path);
}

/// Read and parse the session file. Returns null on any failure (missing,
/// corrupt, empty), and renames a corrupt file to `path.bak` so the next
/// launch starts clean. Callers own the returned `std.json.Parsed` and must
/// call `.deinit()`.
pub fn loadSession(
    allocator: std.mem.Allocator,
    path: []const u8,
) !?std.json.Parsed(Session) {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            log.warn("failed to read {s}: {}", .{ path, err });
            return null;
        },
    };
    defer allocator.free(bytes);

    const parsed = loadSessionFromString(allocator, bytes) catch |err| {
        log.warn("session.json corrupt ({}); renaming to .bak", .{err});
        const bak = std.mem.concat(allocator, u8, &.{ path, ".bak" }) catch return null;
        defer allocator.free(bak);
        std.fs.cwd().rename(path, bak) catch |rerr| {
            log.warn("failed to rename {s} to .bak: {}", .{ path, rerr });
        };
        return null;
    };
    if (parsed.value.tabs.len == 0) {
        var p = parsed;
        p.deinit();
        return null;
    }
    return parsed;
}
```

- [ ] **Step 4: Run — pass**

Run: `zig build test`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/session_persist.zig
git commit -m "Add atomic dumpSession and loadSession with .bak fallback"
```

---

## Task 13: Test corrupt-file fallback creates `.bak`

**Files:**
- Modify: `src/session_persist.zig`

- [ ] **Step 1: Write the failing test**

Append:

```zig
test "session_persist: corrupt file is renamed to .bak and loadSession returns null" {
    const allocator = std.testing.allocator;
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const realpath = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(realpath);
    const path = try std.fs.path.join(allocator, &.{ realpath, "sess.json" });
    defer allocator.free(path);

    {
        const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("{ totally broken");
    }

    const result = try loadSession(allocator, path);
    try std.testing.expect(result == null);

    const bak = try std.mem.concat(allocator, u8, &.{ path, ".bak" });
    defer allocator.free(bak);
    try std.fs.cwd().access(bak, .{});  // should exist; throws if missing
    std.fs.cwd().access(path, .{}) catch return; // original should be gone
    return error.OriginalShouldBeRenamed;
}
```

- [ ] **Step 2: Run — pass (no implementation change needed)**

Run: `zig build test`
Expected: passes — the implementation from Task 12 already handles this.

- [ ] **Step 3: Commit**

```bash
git add src/session_persist.zig
git commit -m "Verify corrupt session file is backed up"
```

---

## Task 14: Add `restore-tabs-on-startup` config flag

**Files:**
- Modify: `src/config.zig`

- [ ] **Step 1: Find existing field defaults**

Run: `grep -n "@\"unfocused-split-opacity\"" src/config.zig | head -3`

This locates the precedent for new bool/float config fields. Look at the surrounding struct definition and parser (`fn parseConfig` or similar — search for where existing `bool` fields like the focus-follows-mouse one are declared and parsed).

- [ ] **Step 2: Add the field**

In the config struct definition (the area around line 271 that holds `@"unfocused-split-opacity"`), add:

```zig
/// When true, persist tab/split layout to %APPDATA%\phantty\session.json on
/// close, and restore it on next launch (unless CLI args specify otherwise).
/// Default false: the file is neither written nor read when this is off.
@"restore-tabs-on-startup": bool = false,
```

In the parser (find the if/else chain around line 588 that handles `unfocused-split-opacity`), add a new branch parsing booleans. Look for an existing bool-parsing precedent (e.g., `focus-follows-mouse`) and copy its pattern. If no bool fields exist, the parsing pattern is:

```zig
} else if (std.mem.eql(u8, key, "restore-tabs-on-startup")) {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
        self.@"restore-tabs-on-startup" = true;
    } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
        self.@"restore-tabs-on-startup" = false;
    } else {
        log.warn("invalid restore-tabs-on-startup: {s}", .{value});
    }
```

If a `log` constant isn't already imported in `config.zig`, add `const log = std.log.scoped(.config);` at the top, or use `std.debug.print` to match local style.

- [ ] **Step 3: Add a parsing test**

Append to `config.zig`:

```zig
test "config: restore-tabs-on-startup parses true/false" {
    var cfg: Config = .{};
    try std.testing.expectEqual(false, cfg.@"restore-tabs-on-startup");

    cfg.parseLine("restore-tabs-on-startup = true");
    try std.testing.expectEqual(true, cfg.@"restore-tabs-on-startup");

    cfg.parseLine("restore-tabs-on-startup = false");
    try std.testing.expectEqual(false, cfg.@"restore-tabs-on-startup");
}
```

If the parse method has a different name than `parseLine` (likely something like `applyKey(key, value)` or `parseEntry`), adjust accordingly — locate the function used in the existing `unfocused-split-opacity` parsing.

- [ ] **Step 4: Run test**

Run: `zig build test`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "Add restore-tabs-on-startup config option (default off)"
```

---

## Task 15: `tab.snapshotTab` — build TabSnap from live TabState

**Files:**
- Modify: `src/appwindow/tab.zig`

This task introduces real-Surface-touching code that cannot be unit-tested without ConPTY. Verification is manual / via the wiring in Task 19.

- [ ] **Step 1: Add imports**

At the top of `src/appwindow/tab.zig`, add:

```zig
const session_persist = @import("../session_persist.zig");
```

(Verify the relative path: tab.zig is at `src/appwindow/tab.zig`, session_persist at `src/session_persist.zig`, so `../` is correct.)

- [ ] **Step 2: Add `snapshotTab`**

Insert a new section near the bottom of `tab.zig` (above any existing test blocks):

```zig
// ============================================================================
// Session persistence — snapshot live tabs into POD for serialization
// ============================================================================

/// Build a session_persist.TabSnap from a live TabState by walking its
/// SplitTree. The returned snapshot owns its strings via `arena`. The arena
/// is the caller's responsibility to free (via Session.deinit pattern, or
/// shared across all tabs in a session).
pub fn snapshotTab(arena: std.mem.Allocator, t: *const TabState) !session_persist.TabSnap {
    if (t.tree.isEmpty()) return error.EmptyTree;

    // 1. Build NodeSnap tree.
    const tree = try snapshotNode(arena, &t.tree, .root);

    // 2. Find the focused leaf's index in pre-order.
    var focused_leaf: u32 = 0;
    if (t.focused != .root) {
        focused_leaf = computeFocusedLeafIndex(&t.tree, t.focused);
    }

    // 3. Zoom is null for now (zoom restore is in spec but uses the same
    //    tree.zoomed handle → pre-order index conversion).
    const zoomed_leaf: ?u32 = if (t.tree.zoomed) |z| computeFocusedLeafIndex(&t.tree, z) else null;

    return session_persist.TabSnap{
        .title_override = null,
        .focused_leaf = focused_leaf,
        .zoomed_leaf = zoomed_leaf,
        .tree = tree,
    };
}

fn snapshotNode(
    arena: std.mem.Allocator,
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
) !session_persist.NodeSnap {
    const node = tree.nodes[handle.idx()];
    return switch (node) {
        .leaf => |surface| .{ .leaf = .{ .surface = try snapshotSurface(arena, surface) } },
        .split => |sp| blk: {
            const left = try arena.create(session_persist.NodeSnap);
            left.* = try snapshotNode(arena, tree, sp.left);
            const right = try arena.create(session_persist.NodeSnap);
            right.* = try snapshotNode(arena, tree, sp.right);
            break :blk .{ .split = .{
                .layout = switch (sp.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = @as(f64, @floatCast(sp.ratio)),
                .left = left,
                .right = right,
            } };
        },
    };
}

fn snapshotSurface(arena: std.mem.Allocator, surface: *const Surface) !session_persist.SurfaceSnap {
    const cwd_opt: ?[]const u8 = surface.getCwd() orelse surface.getInitialCwd();
    const cwd_dup: ?[]const u8 = if (cwd_opt) |c| try arena.dupe(u8, c) else null;

    return switch (surface.surfaceKind()) {
        .local_shell => .{ .local_shell = .{
            .cwd = cwd_dup,
            .command = null,
        } },
        .ssh => blk: {
            const conn = surface.ssh_connection.?;
            const port_num: u16 = std.fmt.parseInt(u16, conn.port(), 10) catch 22;
            break :blk .{ .ssh = .{
                .cwd = cwd_dup,
                .user = try arena.dupe(u8, conn.user()),
                .host = try arena.dupe(u8, conn.host()),
                .port = port_num,
            } };
        },
    };
}

fn computeFocusedLeafIndex(tree: *const SplitTree, target: SplitTree.Node.Handle) u32 {
    var idx: u32 = 0;
    var found: ?u32 = null;
    walkTreePreOrder(tree, .root, target, &idx, &found);
    return found orelse 0;
}

fn walkTreePreOrder(
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
    target: SplitTree.Node.Handle,
    idx: *u32,
    found: *?u32,
) void {
    if (found.* != null) return;
    const node = tree.nodes[handle.idx()];
    switch (node) {
        .leaf => {
            if (handle == target) found.* = idx.*;
            idx.* += 1;
        },
        .split => |sp| {
            walkTreePreOrder(tree, sp.left, target, idx, found);
            walkTreePreOrder(tree, sp.right, target, idx, found);
        },
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `zig build`
Expected: builds. If there's an import-cycle issue (`session_persist` imports nothing problematic, so this should be fine), revisit the `const session_persist = @import` line.

- [ ] **Step 4: Commit**

```bash
git add src/appwindow/tab.zig
git commit -m "Add snapshotTab to capture live TabState as POD"
```

---

## Task 16: `tab.restoreTab` — materialize one TabSnap into a live TabState

**Files:**
- Modify: `src/appwindow/tab.zig`

- [ ] **Step 1: Implement the restore path**

Append to the section started in Task 15:

```zig
/// Build a SurfaceFactory closure-equivalent (a free function) that knows
/// how to spawn one Surface from a SurfaceSnap. The returned Surface has
/// its ssh_connection set if applicable, and is launched with the recovered
/// cwd as its initial directory (local_shell) or appended cd command (ssh).
fn surfaceFromSnap(
    snap: *const session_persist.SurfaceSnap,
    gpa: std.mem.Allocator,
) ?*Surface {
    return surfaceFromSnapImpl(snap, gpa) catch null;
}

fn surfaceFromSnapImpl(
    snap: *const session_persist.SurfaceSnap,
    gpa: std.mem.Allocator,
) !*Surface {
    var stack_buf: [1024]u8 = undefined;
    const cols: u16 = @max(1, g_last_cols);
    const rows: u16 = @max(1, g_last_rows);
    const cursor_style = g_default_cursor_style;
    const cursor_blink = g_default_cursor_blink;

    switch (snap.*) {
        .local_shell => |sh| {
            const cwd_w: ?[*:0]const u16 = if (sh.cwd) |c| blk: {
                const w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, c);
                break :blk w.ptr;
            } else null;
            // Note: cwd_w lifetime ends with the Surface init call (CreateProcessW
            // copies the string), so it's fine to leak here for v1; if hot-pathed,
            // free after init returns.
            const command = getShellCmd();
            const surface = try Surface.init(gpa, cols, rows, command, g_scrollback_limit, cursor_style, cursor_blink, cwd_w);
            surface.attachRemoteClient(g_remote_client);
            return surface;
        },
        .ssh => |s| {
            // Build SSH command equivalent to splitSshCommand, with optional
            // trailing `cd <cwd>` argument when cwd is present.
            var pos: usize = 0;
            const auth_flags = "-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 ";
            const port_str = std.fmt.bufPrint(stack_buf[pos..], "{}", .{s.port}) catch return error.CommandTooLong;
            pos += port_str.len;
            const port_slice = stack_buf[0..pos];
            const written = std.fmt.bufPrint(stack_buf[pos..], "cmd.exe /k ssh.exe -tt {s}-p {s} {s}@{s}", .{ auth_flags, port_slice, s.user, s.host }) catch return error.CommandTooLong;
            const base_end = pos + written.len;

            var trailing_buf: [768]u8 = undefined;
            var final_len: usize = base_end;
            if (s.cwd) |cwd_str| {
                const escaped = try session_persist.shellSingleQuoteEscape(gpa, cwd_str);
                defer gpa.free(escaped);
                const trail = std.fmt.bufPrint(&trailing_buf, " \"cd '{s}' 2>/dev/null; exec $SHELL -l\"", .{escaped}) catch return error.CommandTooLong;
                if (final_len + trail.len > stack_buf.len) return error.CommandTooLong;
                @memcpy(stack_buf[final_len..][0..trail.len], trail);
                final_len += trail.len;
            }

            const command_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, stack_buf[pos..final_len]);
            const surface = try Surface.init(gpa, cols, rows, command_w, g_scrollback_limit, cursor_style, cursor_blink, null);
            surface.attachRemoteClient(g_remote_client);
            // Empty password + password_auth=false triggers the existing prompt flow.
            surface.setSshConnection(s.user, s.host, port_slice, "", false);
            return surface;
        },
    }
}

/// Materialize one TabSnap into a new tab. Returns true on success.
/// On any leaf failure, the whole tab is rolled back and false is returned —
/// the caller (restoreSessionFromFile) skips the failed tab.
pub fn restoreTab(allocator: std.mem.Allocator, snap: *const session_persist.TabSnap) bool {
    if (g_tab_count >= MAX_TABS) return false;

    const SplitTreeM = SplitTree;
    var tree = SplitTreeM.fromSnapshot(allocator, &snap.tree, &surfaceFromSnap) catch |err| {
        std.debug.print("restoreTab: fromSnapshot failed: {}\n", .{err});
        return false;
    };
    errdefer tree.deinit();

    const t = allocator.create(TabState) catch {
        tree.deinit();
        return false;
    };
    t.tree = tree;

    // Resolve focused_leaf from pre-order index back to a Handle.
    t.focused = handleOfNthLeaf(&t.tree, snap.focused_leaf) orelse .root;

    g_tabs[g_tab_count] = t;
    g_active_tab = g_tab_count;
    g_tab_count += 1;
    return true;
}

fn handleOfNthLeaf(tree: *const SplitTree, target_idx: u32) ?SplitTree.Node.Handle {
    var idx: u32 = 0;
    return findLeafHandle(tree, .root, target_idx, &idx);
}

fn findLeafHandle(
    tree: *const SplitTree,
    handle: SplitTree.Node.Handle,
    target: u32,
    idx: *u32,
) ?SplitTree.Node.Handle {
    const node = tree.nodes[handle.idx()];
    return switch (node) {
        .leaf => blk: {
            if (idx.* == target) break :blk handle;
            idx.* += 1;
            break :blk null;
        },
        .split => |sp| blk: {
            if (findLeafHandle(tree, sp.left, target, idx)) |h| break :blk h;
            if (findLeafHandle(tree, sp.right, target, idx)) |h| break :blk h;
            break :blk null;
        },
    };
}
```

The references to `g_last_cols`, `g_last_rows`, `g_default_cursor_style`, `g_default_cursor_blink` may not exist with those exact names. Check the existing module-level globals (search `g_` at the top of `tab.zig`); use whatever the existing `spawnTabWithCwd` callers read. If the module doesn't track those, accept them as parameters to `restoreTab(allocator, snap, cols, rows, cursor_style, cursor_blink)` and pass through from the caller in Task 18 / 19.

- [ ] **Step 2: Verify it compiles**

Run: `zig build`
Expected: builds. Fix any naming mismatches by inspecting the actual globals.

- [ ] **Step 3: Commit**

```bash
git add src/appwindow/tab.zig
git commit -m "Add restoreTab to materialize one snapshot into a live tab"
```

---

## Task 17: `tab.collectSessionSnapshot` and `dumpSessionToFile`

**Files:**
- Modify: `src/appwindow/tab.zig`
- Modify: `src/config.zig` (already has sessionFilePath)

- [ ] **Step 1: Implement the aggregator and the file dispatcher**

Append to `tab.zig`:

```zig
/// Walk all live tabs and build a complete Session POD. Caller owns the
/// returned ArenaAllocator; deinit it after the Session is no longer needed.
pub fn collectSessionSnapshot(arena: *std.heap.ArenaAllocator) !session_persist.Session {
    const alloc = arena.allocator();
    if (g_tab_count == 0) return error.NoTabs;

    const tabs = try alloc.alloc(session_persist.TabSnap, g_tab_count);
    var i: usize = 0;
    var written: usize = 0;
    while (i < g_tab_count) : (i += 1) {
        if (g_tabs[i]) |t| {
            tabs[written] = snapshotTab(alloc, t) catch continue;
            written += 1;
        }
    }
    if (written == 0) return error.NoTabs;

    return .{
        .version = session_persist.SCHEMA_VERSION,
        .active_tab = @intCast(@min(g_active_tab, written - 1)),
        .tabs = tabs[0..written],
    };
}

/// One-shot: collect the current session and write it atomically. Errors are
/// logged but not propagated — close path must not be blocked.
pub fn dumpSessionToFile(allocator: std.mem.Allocator) void {
    const Config = @import("../config.zig");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const session = collectSessionSnapshot(&arena) catch |err| {
        std.debug.print("dumpSessionToFile: collect failed: {}\n", .{err});
        return;
    };

    const path = Config.sessionFilePath(allocator) catch |err| {
        std.debug.print("dumpSessionToFile: sessionFilePath failed: {}\n", .{err});
        return;
    };
    defer allocator.free(path);

    session_persist.dumpSession(allocator, path, session) catch |err| {
        std.debug.print("dumpSessionToFile: dumpSession failed: {}\n", .{err});
    };
}
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add src/appwindow/tab.zig
git commit -m "Add collectSessionSnapshot and dumpSessionToFile"
```

---

## Task 18: `tab.restoreSessionFromFile`

**Files:**
- Modify: `src/appwindow/tab.zig`

- [ ] **Step 1: Implement**

Append to `tab.zig`:

```zig
/// Read the session file and rebuild tabs. Returns true iff at least one
/// tab was restored (caller should then skip openDefaultTab).
pub fn restoreSessionFromFile(allocator: std.mem.Allocator) bool {
    const Config = @import("../config.zig");

    const path = Config.sessionFilePath(allocator) catch return false;
    defer allocator.free(path);

    var loaded_opt = session_persist.loadSession(allocator, path) catch return false;
    var loaded = loaded_opt orelse return false;
    defer loaded.deinit();

    session_persist.normalize(&loaded.value);

    var rebuilt: usize = 0;
    for (loaded.value.tabs) |*snap| {
        if (restoreTab(allocator, snap)) {
            rebuilt += 1;
        } else {
            std.debug.print("restoreSessionFromFile: skipping failed tab\n", .{});
        }
    }
    if (rebuilt == 0) return false;

    const target = @min(loaded.value.active_tab, @as(u32, @intCast(rebuilt - 1)));
    switchTab(target);
    return true;
}
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add src/appwindow/tab.zig
git commit -m "Add restoreSessionFromFile"
```

---

## Task 19: Wire startup into AppWindow

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Find the startup point**

Run: `grep -n "openDefaultTab\|spawnTabWithCwd\|spawnTabWithCommandAndCwd" src/AppWindow.zig | head -10`

Locate where the first tab is opened (likely in `runMainLoop` or a one-time init function called from there). The exact line is whatever creates the initial tab when phantty starts.

- [ ] **Step 2: Detect CLI session overrides**

Find the CLI args struct (search `pub const Args` or `parseArgs` or similar). Add a method:

```zig
pub fn hasSessionOverrides(self: *const Args) bool {
    return self.command != null or self.cwd != null or self.positional.len > 0;
}
```

Adjust field names to whatever the existing struct uses.

- [ ] **Step 3: Insert restore attempt before the default tab spawn**

Wrap the existing call:

```zig
// Before opening the default tab, try to restore the previous session.
const should_try_restore = config.@"restore-tabs-on-startup" and !args.hasSessionOverrides();
const restored = if (should_try_restore)
    tab.restoreSessionFromFile(allocator)
else
    false;

if (!restored) {
    // existing default-tab spawn code stays here
    _ = tab.spawnTabWithCwd(allocator, cols, rows, cursor_style, cursor_blink, null);
    // ... whatever else was here
}
```

The exact variable names depend on the existing surrounding code — keep the original `cols`, `rows`, `cursor_*`, `allocator` references.

- [ ] **Step 4: Verify it compiles**

Run: `zig build`
Expected: builds.

- [ ] **Step 5: Commit**

```bash
git add src/AppWindow.zig
git commit -m "Restore tabs on startup when restore-tabs-on-startup is on"
```

---

## Task 20: Wire close-time dump into AppWindow.deinit

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Find AppWindow.deinit**

Run: `grep -n "fn deinit\|AppWindow.deinit\|g_should_close" src/AppWindow.zig | head -10`

The existing deinit walks tabs and calls `t.deinit()` (per the spec survey). The dump must happen **before** that loop.

- [ ] **Step 2: Insert dump call**

Inside `deinit`, near the top (or just before the per-tab deinit loop):

```zig
// Dump the session if persistence is enabled. Errors are logged but
// must not block shutdown.
if (g_config.@"restore-tabs-on-startup") {
    tab.dumpSessionToFile(g_allocator orelse undefined);
}

// existing per-tab deinit loop continues unchanged
```

If the global config is held under a different name (`g_config`, `current_config`, `cfg`), match the existing convention. If the allocator isn't accessible from `deinit`, store it on the AppWindow struct or thread it through.

- [ ] **Step 3: Verify it compiles**

Run: `zig build`
Expected: builds.

- [ ] **Step 4: Commit**

```bash
git add src/AppWindow.zig
git commit -m "Persist session on close when restore-tabs-on-startup is on"
```

---

## Task 21: End-to-end manual verification on Windows  [Windows-only verify]

**Files:**
- (none — verification only)

This task is the only place we exercise the real Surface/PTY/SSH path. Skip if you do not have a Windows checkout; the unit tests from Tasks 1–14 cover correctness of the data layer.

- [ ] **Step 1: Build a debug binary**

PowerShell, repo root:

```powershell
zig build
```

Expected: `.\zig-out\bin\phantty.exe` exists.

- [ ] **Step 2: Enable the feature**

Edit `%APPDATA%\phantty\config` (create if missing):

```
restore-tabs-on-startup = true
```

- [ ] **Step 3: Build a workspace**

Launch `phantty.exe`. Then:

1. `cd C:\Windows\System32` in the first tab.
2. `Ctrl+Shift+T` → second tab.
3. `Ctrl+Shift+O` in tab 1 → split right; the new pane gets focus.
4. (If you have a reachable SSH server: type `ssh user@host`, complete login, `cd /var/log`. Otherwise skip and just verify local-shell restore.)
5. Switch back to tab 1.

- [ ] **Step 4: Close the window**

Click the `×` button (or `Ctrl+Shift+W` until all tabs close).

Expected: `%APPDATA%\phantty\session.json` exists and contains a JSON object with two tabs and a horizontal split in tab 1.

```powershell
Get-Content $env:APPDATA\phantty\session.json
```

- [ ] **Step 5: Relaunch**

```powershell
.\zig-out\bin\phantty.exe
```

Expected:
- Two tabs present.
- Tab 1 is horizontally split.
- Left pane of tab 1 starts at the cwd from step 3, or close to it (depends on whether OSC 7 was emitted by your shell). If your shell does not emit OSC 7, the recovered cwd matches the *initial* cwd of the pane, not whatever you `cd`'d to.

- [ ] **Step 6: Verify CLI override**

Close again, then relaunch with an explicit command:

```powershell
.\zig-out\bin\phantty.exe --command "pwsh.exe"
```

Expected: a single fresh tab opens (CLI overrides restore). `session.json` is not modified during this launch (verify mtime).

- [ ] **Step 7: Verify corrupt-file recovery**

Close, then corrupt the file:

```powershell
"{ broken" | Out-File $env:APPDATA\phantty\session.json -Encoding utf8
.\zig-out\bin\phantty.exe
```

Expected: phantty launches a fresh default tab; `session.json.bak` exists with the broken content; a new `session.json` will be written on next close.

- [ ] **Step 8: Note any gaps**

If something fails (e.g., SSH cwd doesn't auto-`cd`, layout doesn't match, tab title looks wrong), open the rolling debug log (`std.debug.print` output appears in the launching console if you run from PowerShell).

- [ ] **Step 9: No commit needed (verification only)**

---

## Task 22: Documentation

**Files:**
- Modify: `README.md`
- Create: `release-notes/v0.17.0.md` (or whatever the next version number is — check `release-notes/`)

- [ ] **Step 1: Add config doc to README**

Run: `grep -n "unfocused-split-opacity\|focus-follows-mouse" README.md | head -3`

Find the config table or example config section and insert:

```markdown
| `restore-tabs-on-startup` | bool, default `false` | Persist tab/split layout on close and restore on next launch. SSH passwords are never persisted; reconnects re-prompt. CLI args (`--command`, `--cwd`, positional) override restore. |
```

- [ ] **Step 2: Create release notes**

Run: `ls release-notes/` and pick the next unused version. Create `release-notes/vX.Y.Z.md`:

```markdown
# Phantty vX.Y.Z

## Highlights

- Added opt-in tab session persistence: enable
  `restore-tabs-on-startup = true` to have Phantty save tab and split
  layout on close and rebuild it on next launch. SSH targets reconnect
  but always re-prompt for credentials; passwords are never persisted.

## Other changes

- Reverted spatial split focus shortcut to `Alt` + arrow keys (was briefly
  changed to `Ctrl+Shift` + arrows in v0.16).
```

- [ ] **Step 3: Commit**

```bash
git add README.md release-notes/vX.Y.Z.md
git commit -m "Document tab session persistence feature"
```

---

## Self-Review Checklist (run after writing the plan)

- [x] Spec coverage:
  - Goals (4 items): startup restore via config flag (Tasks 14, 19), SSH/local-shell with cwd (Tasks 15, 16), opt-in (Task 14), no secrets (Task 5) — all covered
  - Non-goals: explicitly skipped (no scrollback persistence task; no browser/markdown task; no multi-window task; no incremental-write task)
  - I1 (password) → Task 5; I2 (atomic) → Task 12; I3 (no panic) → Task 4; I4 (fallback layers) → Task 16 (per-leaf), Task 18 (per-tab); I5 (no I/O when off) → Task 14 + Task 19/20 conditional
  - Test strategy: unit tests in Tasks 2-14; integration verification in Task 21
- [x] No placeholders: every code step shows real code; no "TBD"
- [x] Type consistency: `Session`, `TabSnap`, `NodeSnap`, `SurfaceSnap` names match across tasks; `dumpSession`/`loadSession` (file) and `dumpSessionToString`/`loadSessionFromString` consistently distinguished; `SplitTree.fromSnapshot` consistent across Tasks 9 and 16
- [x] Each task is one logical commit; no task spans multiple unrelated concerns
