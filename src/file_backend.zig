//! Lightweight file access backends for the sidebar explorer.
//!
//! This keeps the explorer UI independent from how files are listed. The first
//! implementation intentionally uses local std.fs and Windows OpenSSH tools so
//! we avoid adding a new SSH library dependency.

const std = @import("std");
const Surface = @import("Surface.zig");
const scp = @import("scp.zig");

pub const MAX_NAME_LEN = 255;

pub const Backend = union(enum) {
    local,
    ssh: *const Surface.SshConnection,
};

pub const Entry = struct {
    name_buf: [MAX_NAME_LEN]u8 = undefined,
    name_len: u8 = 0,
    is_dir: bool = false,

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const ListStatus = enum {
    ok,
    empty_root,
    open_failed,
    ssh_failed,
};

pub const ListResult = struct {
    status: ListStatus,
    count: usize = 0,
};

pub fn list(
    allocator: std.mem.Allocator,
    backend: Backend,
    path: []const u8,
    out: []Entry,
) ListResult {
    return switch (backend) {
        .local => listLocal(path, out),
        .ssh => |conn| listSsh(allocator, conn, path, out),
    };
}

pub fn resolveRoot(
    allocator: std.mem.Allocator,
    backend: Backend,
    out: []u8,
) ?usize {
    return switch (backend) {
        .local => blk: {
            const cwd = std.process.getCwd(out) catch break :blk null;
            break :blk cwd.len;
        },
        .ssh => |conn| sshPwd(allocator, conn, out),
    };
}

fn listLocal(path: []const u8, out: []Entry) ListResult {
    if (path.len == 0) return .{ .status = .empty_root };

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        std.debug.print("FileBackend local open failed for '{s}': {}\n", .{ path, err });
        return .{ .status = .open_failed };
    };
    defer dir.close();

    var count: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (count >= out.len) break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        addEntry(&out[count], entry.name, entry.kind == .directory) orelse continue;
        count += 1;
    }

    sort(out[0..count]);
    return .{ .status = .ok, .count = count };
}

fn listSsh(
    allocator: std.mem.Allocator,
    conn: *const Surface.SshConnection,
    path: []const u8,
    out: []Entry,
) ListResult {
    if (path.len == 0) return .{ .status = .empty_root };

    var quoted_buf: [1024]u8 = undefined;
    const quoted = shellQuote(&quoted_buf, path) orelse return .{ .status = .ssh_failed };

    var cmd_buf: [1200]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "ls -1p -- {s}", .{quoted}) catch
        return .{ .status = .ssh_failed };

    const output = scp.sshExec(allocator, conn, cmd) orelse {
        std.debug.print("FileBackend ssh list failed for '{s}'\n", .{path});
        return .{ .status = .ssh_failed };
    };
    defer allocator.free(output);

    const count = parseRemoteList(output, out);
    sort(out[0..count]);
    return .{ .status = .ok, .count = count };
}

fn sshPwd(
    allocator: std.mem.Allocator,
    conn: *const Surface.SshConnection,
    out: []u8,
) ?usize {
    const output = scp.sshExec(allocator, conn, "pwd") orelse return null;
    defer allocator.free(output);

    var line: []const u8 = output;
    if (std.mem.indexOfScalar(u8, line, '\n')) |idx| line = line[0..idx];
    line = std.mem.trimRight(u8, line, "\r");
    if (line.len == 0 or line.len > out.len) return null;
    @memcpy(out[0..line.len], line);
    return line.len;
}

fn parseRemoteList(output: []const u8, out: []Entry) usize {
    var count: usize = 0;
    var line_start: usize = 0;
    for (output, 0..) |ch, i| {
        if (ch == '\n') {
            count = parseRemoteLine(output[line_start..i], out, count);
            line_start = i + 1;
        }
    }
    if (line_start < output.len) {
        count = parseRemoteLine(output[line_start..], out, count);
    }
    return count;
}

fn parseRemoteLine(raw_line: []const u8, out: []Entry, count: usize) usize {
    if (count >= out.len) return count;
    var line = std.mem.trimRight(u8, raw_line, "\r");
    if (line.len == 0) return count;

    const is_dir = line[line.len - 1] == '/';
    if (is_dir) line = line[0 .. line.len - 1];
    if (line.len == 0) return count;
    if (std.mem.eql(u8, line, ".") or std.mem.eql(u8, line, "..")) return count;

    addEntry(&out[count], line, is_dir) orelse return count;
    return count + 1;
}

fn addEntry(out: *Entry, name: []const u8, is_dir: bool) ?void {
    if (name.len == 0) return null;
    const len: u8 = @intCast(@min(name.len, MAX_NAME_LEN));
    @memcpy(out.name_buf[0..len], name[0..len]);
    out.name_len = len;
    out.is_dir = is_dir;
}

fn sort(entries: []Entry) void {
    std.sort.insertion(Entry, entries, {}, lessThan);
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir and !b.is_dir) return true;
    if (!a.is_dir and b.is_dir) return false;
    return std.mem.order(u8, a.name(), b.name()) == .lt;
}

fn shellQuote(buf: *[1024]u8, arg: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (pos >= buf.len) return null;
    buf[pos] = '\'';
    pos += 1;

    for (arg) |ch| {
        if (ch == '\'') {
            const escaped = "'\\''";
            if (pos + escaped.len >= buf.len) return null;
            @memcpy(buf[pos..][0..escaped.len], escaped);
            pos += escaped.len;
        } else {
            if (pos + 1 >= buf.len) return null;
            buf[pos] = ch;
            pos += 1;
        }
    }

    if (pos >= buf.len) return null;
    buf[pos] = '\'';
    pos += 1;
    return buf[0..pos];
}

test "shellQuote escapes single quotes" {
    var buf: [1024]u8 = undefined;
    const quoted = shellQuote(&buf, "/tmp/it's here") orelse unreachable;
    try std.testing.expectEqualStrings("'/tmp/it'\\''s here'", quoted);
}

test "parseRemoteList sorts directories first and skips dot entries" {
    var entries: [8]Entry = undefined;
    const count = parseRemoteList("./\n../\nzeta.txt\nalpha/\nbeta.txt\n", &entries);
    sort(entries[0..count]);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("alpha", entries[0].name());
    try std.testing.expect(entries[0].is_dir);
    try std.testing.expectEqualStrings("beta.txt", entries[1].name());
    try std.testing.expectEqualStrings("zeta.txt", entries[2].name());
}
