const std = @import("std");
const windows = std.os.windows;
const win32 = @import("apprt/win32.zig");

const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;

pub const winsize = struct {
    ws_col: u16,
    ws_row: u16,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

pub const Pty = WindowsPty;

const WindowsPty = struct {
    out_pipe: HANDLE, // Our read end (child stdout -> us) -- anonymous pipe, synchronous
    in_pipe: HANDLE, // Our write end (us -> child stdin) -- anonymous pipe, synchronous
    out_pipe_pty: HANDLE, // PTY-side write end (ConPTY writes here)
    in_pipe_pty: HANDLE, // PTY-side read end (ConPTY reads here)
    pseudo_console: win32.HPCON,
    size: winsize,

    pub fn open(size: winsize) !Pty {
        var self: Pty = undefined;
        self.size = size;

        // Output pipe (ConPTY → us): anonymous pipe via CreatePipe.
        // Synchronous so ReadThread's blocking ReadFile properly registers
        // a kernel IRP — critical for draining during resize.
        if (win32.CreatePipe(&self.out_pipe, &self.out_pipe_pty, null, 0) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            windows.CloseHandle(self.out_pipe);
            windows.CloseHandle(self.out_pipe_pty);
        }

        // Input pipe (us → ConPTY): anonymous pipe via CreatePipe.
        // Synchronous — main thread writes with blocking WriteFile.
        // When xev IOCP writes are needed later, switch to CreateNamedPipeW
        // with FILE_FLAG_OVERLAPPED (like Ghostty).
        if (win32.CreatePipe(&self.in_pipe_pty, &self.in_pipe, null, 0) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            windows.CloseHandle(self.in_pipe);
            windows.CloseHandle(self.in_pipe_pty);
        }

        // Prevent pipe handles from being inherited by child processes
        _ = win32.SetHandleInformation(self.out_pipe, win32.HANDLE_FLAG_INHERIT, 0);
        _ = win32.SetHandleInformation(self.out_pipe_pty, win32.HANDLE_FLAG_INHERIT, 0);
        _ = win32.SetHandleInformation(self.in_pipe, win32.HANDLE_FLAG_INHERIT, 0);
        _ = win32.SetHandleInformation(self.in_pipe_pty, win32.HANDLE_FLAG_INHERIT, 0);

        // Create the pseudo console
        const coord = win32.COORD{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) };
        const hr = win32.CreatePseudoConsole(coord, self.in_pipe_pty, self.out_pipe_pty, 0, &self.pseudo_console);
        if (hr != win32.S_OK) {
            return error.CreatePseudoConsoleFailed;
        }

        return self;
    }

    pub fn deinit(self: *Pty) void {
        win32.ClosePseudoConsole(self.pseudo_console);
        if (self.out_pipe != INVALID_HANDLE_VALUE) windows.CloseHandle(self.out_pipe);
        if (self.in_pipe != INVALID_HANDLE_VALUE) windows.CloseHandle(self.in_pipe);
        windows.CloseHandle(self.out_pipe_pty);
        windows.CloseHandle(self.in_pipe_pty);
    }

    pub fn getSize(self: *const Pty) winsize {
        return self.size;
    }

    pub fn setSize(self: *Pty, s: winsize) !void {
        const coord = win32.COORD{ .X = @intCast(s.ws_col), .Y = @intCast(s.ws_row) };
        const hr = win32.ResizePseudoConsole(self.pseudo_console, coord);
        if (hr != win32.S_OK) return error.ResizePseudoConsoleFailed;
        self.size = s;
    }
};
