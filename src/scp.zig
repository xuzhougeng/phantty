//! Shared SCP/SSH command helpers.
//!
//! Provides reusable functions for executing scp and ssh commands using
//! the SshConnection metadata from Surface.zig. Used by both the clipboard
//! image paste path and the file explorer remote operations.

const std = @import("std");
const Surface = @import("Surface.zig");
const SshConnection = Surface.SshConnection;
const windows = std.os.windows;

/// Result of a transfer operation.
pub const TransferResult = enum { ok, failed, spawn_error };

/// Run `scp src dst` with proper SSH auth options from the connection.
/// `src` and `dst` are scp-style paths (local or user@host:remote).
pub fn transfer(allocator: std.mem.Allocator, conn: *const SshConnection, src: []const u8, dst: []const u8) TransferResult {
    var askpass_path: ?[]u8 = null;
    defer if (askpass_path) |p| allocator.free(p);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.password_auth) {
        askpass_path = ensureAskPassScript(allocator) orelse return .spawn_error;
        env_map = std.process.getEnvMap(allocator) catch return .spawn_error;
        if (env_map) |*map| {
            map.put("SSH_ASKPASS", askpass_path.?) catch return .spawn_error;
            map.put("SSH_ASKPASS_REQUIRE", "force") catch return .spawn_error;
            map.put("DISPLAY", "phantty") catch return .spawn_error;
            map.put("PHANTTY_SSH_PASSWORD", conn.password()) catch return .spawn_error;
        }
    }

    // Windows OpenSSH's ControlMaster support relies on Unix-domain socket
    // semantics that fail here with "getsockname failed: Not a socket".
    // Keep helper SSH/SCP calls independent; the real interactive SSH session
    // remains untouched.
    const control_path: ?[]const u8 = null;

    const env_ptr: ?*std.process.EnvMap = if (env_map) |*map| map else null;
    const default_result = runScpTransfer(allocator, conn, src, dst, control_path, env_ptr, false);
    if (default_result == .ok or default_result == .spawn_error) return default_result;

    std.debug.print("SCP default mode failed; retrying legacy scp protocol (-O)\n", .{});
    const legacy_result = runScpTransfer(allocator, conn, src, dst, control_path, env_ptr, true);
    if (legacy_result == .ok or legacy_result == .spawn_error) return legacy_result;

    std.debug.print("SCP legacy mode failed; retrying over ssh stream\n", .{});
    return runSshStreamTransfer(allocator, conn, src, dst, control_path, env_ptr);
}

/// Build a remote scp path: "user@host:path"
pub fn remoteSpec(buf: *[512]u8, conn: *const SshConnection, remote_path: []const u8) []const u8 {
    const user = conn.user();
    const host = conn.host();
    var pos: usize = 0;
    @memcpy(buf[pos..][0..user.len], user);
    pos += user.len;
    buf[pos] = '@';
    pos += 1;
    @memcpy(buf[pos..][0..host.len], host);
    pos += host.len;
    buf[pos] = ':';
    pos += 1;
    @memcpy(buf[pos..][0..remote_path.len], remote_path);
    pos += remote_path.len;
    return buf[0..pos];
}

// ============================================================================
// Internal helpers
// ============================================================================

const PortMode = enum { ssh, scp };

fn runScpTransfer(
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    src: []const u8,
    dst: []const u8,
    control_path: ?[]const u8,
    env_map: ?*std.process.EnvMap,
    legacy_protocol: bool,
) TransferResult {
    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "scp.exe";
    argc += 1;
    argv_buf[argc] = "-q";
    argc += 1;
    if (legacy_protocol) {
        argv_buf[argc] = "-O";
        argc += 1;
    }

    argc = appendSshOptions(&argv_buf, argc, conn, .scp, control_path);

    argv_buf[argc] = src;
    argc += 1;
    argv_buf[argc] = dst;
    argc += 1;

    std.debug.print("SCP: {s} -> {s}\n", .{ src, dst });
    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    if (env_map) |map| child.env_map = map;
    child.spawn() catch |err| {
        std.debug.print("SCP spawn failed: {}\n", .{err});
        return .spawn_error;
    };

    var stderr_output: ?[]u8 = null;
    defer if (stderr_output) |stderr| allocator.free(stderr);
    if (child.stderr) |stderr| {
        stderr_output = stderr.readToEndAlloc(allocator, 16 * 1024) catch null;
    }

    const term = child.wait() catch return .failed;
    const result: TransferResult = switch (term) {
        .Exited => |code| if (code == 0) .ok else .failed,
        else => .failed,
    };
    if (result != .ok) {
        logProcessFailure(if (legacy_protocol) "SCP -O failed" else "SCP failed", stderr_output);
    }
    return result;
}

fn appendSshExecPrefix(
    argv_buf: *[32][]const u8,
    conn: *const SshConnection,
    control_path: ?[]const u8,
    dest_buf: *[280]u8,
) usize {
    var argc: usize = 0;
    argv_buf[argc] = "ssh.exe";
    argc += 1;

    argc = appendSshOptions(argv_buf, argc, conn, .ssh, control_path);
    argv_buf[argc] = "-T";
    argc += 1;

    // user@host
    const dest_len = conn.user().len + 1 + conn.host().len;
    @memcpy(dest_buf[0..conn.user().len], conn.user());
    dest_buf[conn.user().len] = '@';
    @memcpy(dest_buf[conn.user().len + 1 ..][0..conn.host().len], conn.host());
    argv_buf[argc] = dest_buf[0..dest_len];
    argc += 1;
    return argc;
}

/// Run `ssh user@host "<command>"` and capture stdout.
/// Returns allocated output slice on success, null on failure.
pub fn sshExec(allocator: std.mem.Allocator, conn: *const SshConnection, command: []const u8) ?[]u8 {
    var askpass_path: ?[]u8 = null;
    defer if (askpass_path) |p| allocator.free(p);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.password_auth) {
        askpass_path = ensureAskPassScript(allocator) orelse return null;
        env_map = std.process.getEnvMap(allocator) catch return null;
        if (env_map) |*map| {
            map.put("SSH_ASKPASS", askpass_path.?) catch return null;
            map.put("SSH_ASKPASS_REQUIRE", "force") catch return null;
            map.put("DISPLAY", "phantty") catch return null;
            map.put("PHANTTY_SSH_PASSWORD", conn.password()) catch return null;
        }
    }

    const control_path: ?[]const u8 = null;

    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "ssh.exe";
    argc += 1;

    argc = appendSshOptions(&argv_buf, argc, conn, .ssh, control_path);

    // user@host
    var dest_buf: [280]u8 = undefined;
    const dest_len = conn.user().len + 1 + conn.host().len;
    @memcpy(dest_buf[0..conn.user().len], conn.user());
    dest_buf[conn.user().len] = '@';
    @memcpy(dest_buf[conn.user().len + 1 ..][0..conn.host().len], conn.host());
    argv_buf[argc] = dest_buf[0..dest_len];
    argc += 1;

    argv_buf[argc] = command;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    if (env_map) |*map| child.env_map = map;
    child.spawn() catch return null;

    // Read stdout
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stdout.read(&buf) catch break;
        if (n == 0) break;
        output.appendSlice(allocator, buf[0..n]) catch break;
    }

    const term = child.wait() catch return null;
    const ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;

    return output.toOwnedSlice(allocator) catch null;
}

fn runSshStreamTransfer(
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    src: []const u8,
    dst: []const u8,
    control_path: ?[]const u8,
    env_map: ?*std.process.EnvMap,
) TransferResult {
    if (remotePathFromSpec(conn, dst)) |remote_path| {
        return sshStreamUpload(allocator, conn, src, remote_path, control_path, env_map);
    }
    if (remotePathFromSpec(conn, src)) |remote_path| {
        return sshStreamDownload(allocator, conn, remote_path, dst, control_path, env_map);
    }
    return .failed;
}

fn remotePathFromSpec(conn: *const SshConnection, spec: []const u8) ?[]const u8 {
    const user = conn.user();
    const host = conn.host();
    const prefix_len = user.len + 1 + host.len + 1;
    if (spec.len < prefix_len) return null;
    if (!std.mem.eql(u8, spec[0..user.len], user)) return null;
    if (spec[user.len] != '@') return null;
    if (!std.mem.eql(u8, spec[user.len + 1 .. user.len + 1 + host.len], host)) return null;
    if (spec[user.len + 1 + host.len] != ':') return null;
    return spec[prefix_len..];
}

fn localBasename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '\\' or ch == '/') start = i + 1;
    }
    return path[start..];
}

fn appendSlice(buf: *[2048]u8, pos: *usize, text: []const u8) bool {
    if (pos.* + text.len > buf.len) return false;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
    return true;
}

fn appendShellQuote(buf: *[2048]u8, pos: *usize, arg: []const u8) bool {
    if (pos.* >= buf.len) return false;
    buf[pos.*] = '\'';
    pos.* += 1;
    for (arg) |ch| {
        if (ch == '\'') {
            if (!appendSlice(buf, pos, "'\\''")) return false;
        } else {
            if (pos.* >= buf.len) return false;
            buf[pos.*] = ch;
            pos.* += 1;
        }
    }
    if (pos.* >= buf.len) return false;
    buf[pos.*] = '\'';
    pos.* += 1;
    return true;
}

fn buildUploadCommand(buf: *[2048]u8, remote_path: []const u8, local_path: []const u8) ?[]const u8 {
    var pos: usize = 0;
    const basename = localBasename(local_path);
    if (basename.len == 0) return null;

    if (!appendSlice(buf, &pos, "if test -d ")) return null;
    if (!appendShellQuote(buf, &pos, remote_path)) return null;
    if (!appendSlice(buf, &pos, "; then cat > ")) return null;
    if (!appendShellQuote(buf, &pos, remote_path)) return null;
    if (!appendSlice(buf, &pos, "/")) return null;
    if (!appendShellQuote(buf, &pos, basename)) return null;
    if (!appendSlice(buf, &pos, "; else cat > ")) return null;
    if (!appendShellQuote(buf, &pos, remote_path)) return null;
    if (!appendSlice(buf, &pos, "; fi")) return null;
    return buf[0..pos];
}

fn buildDownloadCommand(buf: *[2048]u8, remote_path: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendSlice(buf, &pos, "cat -- ")) return null;
    if (!appendShellQuote(buf, &pos, remote_path)) return null;
    return buf[0..pos];
}

fn openLocalRead(path: []const u8) ?std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{}) catch null;
    return std.fs.cwd().openFile(path, .{}) catch null;
}

fn createLocalWrite(path: []const u8) ?std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{ .truncate = true }) catch null;
    return std.fs.cwd().createFile(path, .{ .truncate = true }) catch null;
}

const StdinWriteError = error{ BrokenPipe, WriteFailed };

fn writeAllToChildStdin(file: std.fs.File, data: []const u8) StdinWriteError!void {
    var index: usize = 0;
    while (index < data.len) {
        var written: windows.DWORD = 0;
        const remaining = data[index..];
        const chunk_len: windows.DWORD = @intCast(@min(remaining.len, std.math.maxInt(windows.DWORD)));
        if (windows.kernel32.WriteFile(file.handle, remaining.ptr, chunk_len, &written, null) == 0) {
            return switch (windows.GetLastError()) {
                .BROKEN_PIPE, .NO_DATA => error.BrokenPipe,
                else => error.WriteFailed,
            };
        }
        if (written == 0) return error.BrokenPipe;
        index += written;
    }
}

fn sshStreamUpload(
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    local_path: []const u8,
    remote_path: []const u8,
    control_path: ?[]const u8,
    env_map: ?*std.process.EnvMap,
) TransferResult {
    var file = openLocalRead(local_path) orelse return .failed;
    defer file.close();

    var command_buf: [2048]u8 = undefined;
    const command = buildUploadCommand(&command_buf, remote_path, local_path) orelse return .failed;

    var argv_buf: [32][]const u8 = undefined;
    var dest_buf: [280]u8 = undefined;
    var argc = appendSshExecPrefix(&argv_buf, conn, control_path, &dest_buf);
    argv_buf[argc] = command;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    if (env_map) |map| child.env_map = map;
    child.spawn() catch return .spawn_error;

    var write_ok = true;
    if (child.stdin) |stdin| {
        var in = stdin;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = file.read(&buf) catch {
                write_ok = false;
                break;
            };
            if (n == 0) break;
            writeAllToChildStdin(in, buf[0..n]) catch {
                write_ok = false;
                break;
            };
        }
        in.close();
    } else {
        write_ok = false;
    }

    var stderr_output: ?[]u8 = null;
    defer if (stderr_output) |stderr| allocator.free(stderr);
    if (child.stderr) |stderr| {
        stderr_output = stderr.readToEndAlloc(allocator, 16 * 1024) catch null;
    }

    const term = child.wait() catch return .failed;
    if (!write_ok) {
        logProcessFailure("SSH stream upload write failed", stderr_output);
        return .failed;
    }

    const result: TransferResult = switch (term) {
        .Exited => |code| if (code == 0) .ok else .failed,
        else => .failed,
    };
    if (result != .ok) logProcessFailure("SSH stream upload failed", stderr_output);
    return result;
}

fn sshStreamDownload(
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    remote_path: []const u8,
    local_path: []const u8,
    control_path: ?[]const u8,
    env_map: ?*std.process.EnvMap,
) TransferResult {
    var file = createLocalWrite(local_path) orelse return .failed;
    defer file.close();

    var command_buf: [2048]u8 = undefined;
    const command = buildDownloadCommand(&command_buf, remote_path) orelse return .failed;

    var argv_buf: [32][]const u8 = undefined;
    var dest_buf: [280]u8 = undefined;
    var argc = appendSshExecPrefix(&argv_buf, conn, control_path, &dest_buf);
    argv_buf[argc] = command;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (env_map) |map| child.env_map = map;
    child.spawn() catch return .spawn_error;

    if (child.stdout) |stdout| {
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = stdout.read(&buf) catch break;
            if (n == 0) break;
            file.writeAll(buf[0..n]) catch return .failed;
        }
    }

    var stderr_output: ?[]u8 = null;
    defer if (stderr_output) |stderr| allocator.free(stderr);
    if (child.stderr) |stderr| {
        stderr_output = stderr.readToEndAlloc(allocator, 16 * 1024) catch null;
    }

    const term = child.wait() catch return .failed;
    const result: TransferResult = switch (term) {
        .Exited => |code| if (code == 0) .ok else .failed,
        else => .failed,
    };
    if (result != .ok) logProcessFailure("SSH stream download failed", stderr_output);
    return result;
}

fn logProcessFailure(label: []const u8, stderr_output: ?[]const u8) void {
    if (stderr_output) |stderr| {
        const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
        if (trimmed.len > 0) {
            std.debug.print("{s}: {s}\n", .{ label, trimmed });
            return;
        }
    }
    std.debug.print("{s}\n", .{label});
}

fn appendSshOptions(
    argv_buf: *[32][]const u8,
    start_argc: usize,
    conn: *const SshConnection,
    port_mode: PortMode,
    control_path: ?[]const u8,
) usize {
    var argc = start_argc;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "StrictHostKeyChecking=accept-new";
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = "ConnectTimeout=8";
    argc += 1;
    if (conn.password_auth) {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "PreferredAuthentications=publickey,password,keyboard-interactive";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "NumberOfPasswordPrompts=1";
        argc += 1;
    } else {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "BatchMode=yes";
        argc += 1;
    }
    if (conn.port().len > 0) {
        argv_buf[argc] = switch (port_mode) {
            .ssh => "-p",
            .scp => "-P",
        };
        argc += 1;
        argv_buf[argc] = conn.port();
        argc += 1;
    }
    if (control_path) |path| {
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "ControlMaster=auto";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = "ControlPersist=10m";
        argc += 1;
        argv_buf[argc] = "-o";
        argc += 1;
        argv_buf[argc] = path;
        argc += 1;
    }
    return argc;
}

fn sshControlPathOption(allocator: std.mem.Allocator) ?[]u8 {
    const temp_raw = std.process.getEnvVarOwned(allocator, "TEMP") catch
        std.process.getEnvVarOwned(allocator, "TMP") catch return null;
    defer allocator.free(temp_raw);

    const trimmed = std.mem.trimRight(u8, temp_raw, "\\/");
    if (trimmed.len == 0) return null;

    var normalized: std.ArrayListUnmanaged(u8) = .empty;
    defer normalized.deinit(allocator);
    normalized.appendSlice(allocator, "ControlPath=") catch return null;
    for (trimmed) |ch| {
        normalized.append(allocator, if (ch == '\\') '/' else ch) catch return null;
    }
    normalized.appendSlice(allocator, "/phantty-ssh-%C") catch return null;
    return normalized.toOwnedSlice(allocator) catch null;
}

fn askPassScriptPath(allocator: std.mem.Allocator) ?[]u8 {
    const temp = std.process.getEnvVarOwned(allocator, "TEMP") catch
        std.process.getEnvVarOwned(allocator, "TMP") catch return null;
    defer allocator.free(temp);
    return std.fmt.allocPrint(allocator, "{s}\\phantty-ssh-askpass.cmd", .{temp}) catch null;
}

fn ensureAskPassScript(allocator: std.mem.Allocator) ?[]u8 {
    const path = askPassScriptPath(allocator) orelse return null;
    errdefer allocator.free(path);

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return null;
    defer file.close();

    file.writeAll(
        "@echo off\r\n" ++
            "powershell.exe -NoLogo -NoProfile -Command \"[Console]::Out.Write($env:PHANTTY_SSH_PASSWORD)\"\r\n",
    ) catch return null;
    return path;
}

// ============================================================================
// Tests
// ============================================================================

test "remoteSpec builds user@host:path" {
    var conn: SshConnection = .{};
    @memcpy(conn.user_buf[0..4], "root");
    conn.user_len = 4;
    @memcpy(conn.host_buf[0..11], "example.com");
    conn.host_len = 11;

    var buf: [512]u8 = undefined;
    const result = remoteSpec(&buf, &conn, "/home/data/file.txt");
    try std.testing.expectEqualStrings("root@example.com:/home/data/file.txt", result);
}

test "remoteSpec with empty path" {
    var conn: SshConnection = .{};
    @memcpy(conn.user_buf[0..5], "admin");
    conn.user_len = 5;
    @memcpy(conn.host_buf[0..7], "srv.lan");
    conn.host_len = 7;

    var buf: [512]u8 = undefined;
    const result = remoteSpec(&buf, &conn, "");
    try std.testing.expectEqualStrings("admin@srv.lan:", result);
}

test "remotePathFromSpec matches connection" {
    var conn: SshConnection = .{};
    @memcpy(conn.user_buf[0..10], "xuzhougeng");
    conn.user_len = 10;
    @memcpy(conn.host_buf[0..11], "10.10.87.92");
    conn.host_len = 11;

    const path = remotePathFromSpec(&conn, "xuzhougeng@10.10.87.92:/tmp/image.png") orelse unreachable;
    try std.testing.expectEqualStrings("/tmp/image.png", path);
    try std.testing.expect(remotePathFromSpec(&conn, "other@10.10.87.92:/tmp/image.png") == null);
}

test "appendShellQuote escapes single quotes" {
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    try std.testing.expect(appendShellQuote(&buf, &pos, "/tmp/it's here.png"));
    try std.testing.expectEqualStrings("'/tmp/it'\\''s here.png'", buf[0..pos]);
}

test "buildUploadCommand handles target directories" {
    var buf: [2048]u8 = undefined;
    const command = buildUploadCommand(&buf, "/tmp", "C:\\Users\\me\\image.png") orelse unreachable;
    try std.testing.expectEqualStrings("if test -d '/tmp'; then cat > '/tmp'/'image.png'; else cat > '/tmp'; fi", command);
}

test "appendSshOptions key-based auth" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    conn.port_len = 0;

    var argv_buf: [32][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, null);
    // -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o BatchMode=yes = 6 args
    try std.testing.expectEqual(@as(usize, 6), argc);
    try std.testing.expectEqualStrings("BatchMode=yes", argv_buf[5]);
}

test "appendSshOptions password auth" {
    var conn: SshConnection = .{};
    conn.password_auth = true;
    conn.port_len = 0;

    var argv_buf: [32][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, null);
    // -o StrictHostKeyChecking -o ConnectTimeout -o PreferredAuth -o NumPasswords = 8
    try std.testing.expectEqual(@as(usize, 8), argc);
    try std.testing.expectEqualStrings("NumberOfPasswordPrompts=1", argv_buf[7]);
}

test "appendSshOptions with ssh port" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    @memcpy(conn.port_buf[0..4], "2222");
    conn.port_len = 4;

    var argv_buf: [32][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, null);
    // 6 (base key-auth) + 2 (-p 2222) = 8
    try std.testing.expectEqual(@as(usize, 8), argc);
    try std.testing.expectEqualStrings("-p", argv_buf[6]);
    try std.testing.expectEqualStrings("2222", argv_buf[7]);
}

test "appendSshOptions with scp port" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    @memcpy(conn.port_buf[0..4], "2222");
    conn.port_len = 4;

    var argv_buf: [32][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .scp, null);
    try std.testing.expectEqual(@as(usize, 8), argc);
    try std.testing.expectEqualStrings("-P", argv_buf[6]);
    try std.testing.expectEqualStrings("2222", argv_buf[7]);
}

test "appendSshOptions with control path" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    conn.port_len = 0;

    var argv_buf: [32][]const u8 = undefined;
    const argc = appendSshOptions(&argv_buf, 0, &conn, .ssh, "ControlPath=C:/Temp/phantty-ssh-%C");
    try std.testing.expectEqual(@as(usize, 12), argc);
    try std.testing.expectEqualStrings("ControlMaster=auto", argv_buf[7]);
    try std.testing.expectEqualStrings("ControlPersist=10m", argv_buf[9]);
    try std.testing.expectEqualStrings("ControlPath=C:/Temp/phantty-ssh-%C", argv_buf[11]);
}
