// src/session_persist.zig
const std = @import("std");

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
