//! Process spawning, decoupled from PTY.
//!
//! Manages the child process lifecycle: starting a process attached to a
//! pseudo console, waiting for exit, and cleaning up handles. Modeled after
//! Ghostty's `src/Command.zig`.

const std = @import("std");
const windows = std.os.windows;
const win32 = @import("apprt/win32.zig");

const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;

const Command = @This();

pub const Exit = union(enum) {
    exited: u32,
    unknown,
};

process: HANDLE = INVALID_HANDLE_VALUE,
thread: HANDLE = INVALID_HANDLE_VALUE,
attr_list: ?*anyopaque = null,
attr_list_size: usize = 0,

pub fn start(self: *Command, pseudo_console: win32.HPCON, command: [*:0]const u16, cwd: ?[*:0]const u16) !void {
    // Query required attribute list size
    var attr_size: usize = 0;
    _ = win32.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);

    const attr_list_mem = std.heap.page_allocator.alloc(u8, attr_size) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(attr_list_mem);

    const attr_list: ?*anyopaque = attr_list_mem.ptr;

    if (win32.InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) == 0) {
        return error.InitializeAttributeListFailed;
    }
    errdefer win32.DeleteProcThreadAttributeList(attr_list);

    if (win32.UpdateProcThreadAttribute(
        attr_list,
        0,
        win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        pseudo_console,
        @sizeOf(win32.HPCON),
        null,
        null,
    ) == 0) {
        return error.UpdateAttributeFailed;
    }

    // Set up startup info
    var startup_info = win32.STARTUPINFOEXW{
        .StartupInfo = std.mem.zeroes(windows.STARTUPINFOW),
        .lpAttributeList = attr_list,
    };
    startup_info.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);

    // Copy command to mutable buffer (CreateProcessW may modify it).
    // Dynamically sized — no fixed 256-char limit.
    var cmd_len: usize = 0;
    while (command[cmd_len] != 0) : (cmd_len += 1) {}
    cmd_len += 1; // include null terminator

    const cmd_buf = std.heap.page_allocator.alloc(u16, cmd_len) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(cmd_buf);
    @memcpy(cmd_buf, command[0..cmd_len]);

    var proc_info: windows.PROCESS_INFORMATION = undefined;
    if (win32.CreateProcessW(
        null,
        @ptrCast(cmd_buf.ptr),
        null,
        null,
        0, // Don't inherit handles
        win32.EXTENDED_STARTUPINFO_PRESENT,
        null,
        cwd,
        &startup_info,
        &proc_info,
    ) == 0) {
        return error.CreateProcessFailed;
    }

    // Success — commit to self
    self.process = proc_info.hProcess;
    self.thread = proc_info.hThread;
    self.attr_list = attr_list;
    self.attr_list_size = attr_size;
}

pub fn wait(self: *const Command, block: bool) !?Exit {
    if (self.process == INVALID_HANDLE_VALUE) return null;

    const timeout: DWORD = if (block) win32.INFINITE else 0;
    const result = win32.WaitForSingleObject(self.process, timeout);

    if (result == win32.WAIT_TIMEOUT) return null;
    if (result != win32.WAIT_OBJECT_0) return error.WaitFailed;

    var exit_code: DWORD = 0;
    if (win32.GetExitCodeProcess(self.process, &exit_code) == 0) return error.GetExitCodeFailed;

    return Exit{ .exited = exit_code };
}

pub fn deinit(self: *Command) void {
    if (self.process != INVALID_HANDLE_VALUE) {
        windows.CloseHandle(self.process);
        self.process = INVALID_HANDLE_VALUE;
    }
    if (self.thread != INVALID_HANDLE_VALUE) {
        windows.CloseHandle(self.thread);
        self.thread = INVALID_HANDLE_VALUE;
    }
    if (self.attr_list) |attr| {
        win32.DeleteProcThreadAttributeList(attr);
        const slice: [*]u8 = @ptrCast(attr);
        std.heap.page_allocator.free(slice[0..self.attr_list_size]);
        self.attr_list = null;
    }
}
