// src/session_persist.zig
const std = @import("std");

const log = std.log.scoped(.session_persist);

// On-disk JSON uses std.json's default tagged-union encoding:
// nodes appear as {"leaf": {...}} or {"split": {...}}, not {"kind": ..., ...}.
// Surface kinds appear as {"local_shell": {...}} or {"ssh": {...}}.
// The spec illustrates the conceptual schema; this is the literal wire format.

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

pub fn dumpSessionToString(allocator: std.mem.Allocator, session: Session) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, session, .{});
}

pub fn loadSessionFromString(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(Session) {
    return std.json.parseFromSlice(Session, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
}

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

test "session_persist: empty Session compiles and has expected defaults" {
    const empty: Session = .{ .tabs = &.{} };
    try std.testing.expectEqual(@as(u32, 1), empty.version);
    try std.testing.expectEqual(@as(u32, 0), empty.active_tab);
    try std.testing.expectEqual(@as(usize, 0), empty.tabs.len);
}

test "session_persist: round-trip simple local-shell session via JSON" {
    const allocator = std.testing.allocator;

    const leaf_node = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{
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
    const split = NodeSnap{ .split = .{
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
        if (loadSessionFromString(allocator, bad)) |*ok| {
            var pm = ok.*;
            pm.deinit();
            std.debug.print("expected error for input: {s}\n", .{bad});
            return error.ExpectedFailure;
        } else |_| {
            // any error is acceptable
        }
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

test "session_persist: I1 — serialized SSH leaf contains no 'password' substring" {
    const allocator = std.testing.allocator;

    const leaf = NodeSnap{ .leaf = .{ .surface = .{ .ssh = .{
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

/// Serialize and atomically write the session to `path`. Uses
/// std.fs.Dir.atomicFile so the write is replace-safe on both POSIX and
/// Windows (NTFS) — std's AtomicFile passes replace_if_exists=TRUE on the
/// Windows rename, unlike the bare std.fs.Dir.rename. Partial writes are
/// auto-cleaned on error via AtomicFile.deinit (the temp uses an opaque
/// random hex name, not `<path>.tmp`). On any I/O failure, log a warning
/// and return the error; callers in the close path swallow the error.
pub fn dumpSession(allocator: std.mem.Allocator, path: []const u8, session: Session) !void {
    const json = try dumpSessionToString(allocator, session);
    defer allocator.free(json);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            log.warn("failed to create session dir {s}: {}", .{ dir, err });
            return err;
        };
    }

    // AtomicFileOptions.write_buffer is required in Zig 0.15.2; we pass an
    // empty slice and bypass the buffered writer by calling writeAll on the
    // underlying File directly (the JSON payload is already in memory).
    var write_buffer: [0]u8 = .{};
    var atomic = try std.fs.cwd().atomicFile(path, .{ .write_buffer = &write_buffer });
    defer atomic.deinit();
    try atomic.file_writer.file.writeAll(json);
    try atomic.finish();
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

test "session_persist: dumpSession writes atomically and loadSession reads back" {
    const allocator = std.testing.allocator;

    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const realpath = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(realpath);
    const path = try std.fs.path.join(allocator, &.{ realpath, "sess.json" });
    defer allocator.free(path);

    const leaf = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{ .cwd = "/x" } } } };
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
    try std.fs.cwd().access(bak, .{}); // should exist; throws if missing

    const orig_exists = blk: {
        std.fs.cwd().access(path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!orig_exists);
}
