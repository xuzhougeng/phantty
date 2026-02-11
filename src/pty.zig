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

var pipe_name_counter = std.atomic.Value(u32).init(0);

const WindowsPty = struct {
    out_pipe: HANDLE, // Our read end (child stdout -> us)
    in_pipe: HANDLE, // Our write end (us -> child stdin) -- named pipe, overlapped-capable
    out_pipe_pty: HANDLE, // PTY-side write end (ConPTY writes here)
    in_pipe_pty: HANDLE, // PTY-side read end (ConPTY reads here)
    pseudo_console: win32.HPCON,
    size: winsize,

    pub fn open(size: winsize) !Pty {
        var self: Pty = undefined;
        self.size = size;

        // Create anonymous pipe for output (ConPTY -> us).
        // Default 4KB buffer creates natural backpressure -- the child and VT
        // parser work in lockstep, which yields better throughput.
        if (win32.CreatePipe(&self.out_pipe, &self.out_pipe_pty, null, 0) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            windows.CloseHandle(self.out_pipe);
            windows.CloseHandle(self.out_pipe_pty);
        }

        // Create named pipe for input (us -> ConPTY).
        // Named pipe enables future overlapped (async) I/O.
        const pipe_pair = try createNamedPipePair();
        self.in_pipe = pipe_pair.server;
        self.in_pipe_pty = pipe_pair.client;
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

    fn createNamedPipePair() !struct { server: HANDLE, client: HANDLE } {
        const pid = win32.GetCurrentProcessId();
        const counter = pipe_name_counter.fetchAdd(1, .monotonic);

        // Format pipe name (ASCII, so direct byte-to-u16 widening is safe)
        var name_buf: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "\\\\.\\pipe\\phantty-pty-{d}-{d}", .{ pid, counter }) catch unreachable;

        var wide_buf: [128:0]u16 = [_:0]u16{0} ** 128;
        for (name, 0..) |byte, i| {
            wide_buf[i] = byte;
        }

        const server = win32.CreateNamedPipeW(
            &wide_buf,
            win32.PIPE_ACCESS_OUTBOUND | win32.FILE_FLAG_FIRST_PIPE_INSTANCE | win32.FILE_FLAG_OVERLAPPED,
            win32.PIPE_TYPE_BYTE,
            1, // nMaxInstances
            0, // nOutBufferSize (default)
            0, // nInBufferSize (default)
            0, // nDefaultTimeOut
            null,
        );
        if (server == INVALID_HANDLE_VALUE) return error.CreateNamedPipeFailed;
        errdefer windows.CloseHandle(server);

        const client = win32.CreateFileW(
            &wide_buf,
            win32.GENERIC_READ,
            0, // dwShareMode
            null,
            win32.OPEN_EXISTING,
            win32.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (client == INVALID_HANDLE_VALUE) return error.CreateNamedPipeFailed;

        return .{ .server = server, .client = client };
    }
};
