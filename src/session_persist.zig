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
