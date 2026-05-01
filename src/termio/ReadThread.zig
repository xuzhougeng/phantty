/// Blocking PTY reader thread (matches Ghostty's threadMainWindows).
///
/// Runs a tight blocking ReadFile loop on the PTY output pipe, processing
/// VT data under the render lock. The output pipe is created via CreatePipe
/// (anonymous, synchronous), so blocking ReadFile properly registers a
/// kernel IRP on the pipe.
///
/// This is critical for resize: ResizePseudoConsole (called on the writer
/// thread) makes ConPTY send a full screen redraw through the pipe. The
/// pending ReadFile on this thread absorbs that output, preventing the
/// pipe from filling up and deadlocking ResizePseudoConsole.
///
/// Shutdown via CancelIoEx from Surface.deinit().

const std = @import("std");
const windows = std.os.windows;
const Surface = @import("../Surface.zig");

const READ_BUF_SIZE = 4096;

pub fn threadMain(surface: *Surface) void {
    var buf: [READ_BUF_SIZE]u8 = undefined;

    while (!surface.exited.load(.acquire)) {
        var bytes_read: windows.DWORD = 0;
        if (windows.kernel32.ReadFile(
            surface.pty.out_pipe,
            &buf,
            READ_BUF_SIZE,
            &bytes_read,
            null, // synchronous — properly registers kernel IRP
        ) == 0) {
            const err = windows.kernel32.GetLastError();
            switch (err) {
                // CancelIoEx from deinit, or ConPTY internally cancelling
                // I/O during resize. Retry unless we're shutting down.
                .OPERATION_ABORTED => continue,

                // Pipe closed — child process exited
                .BROKEN_PIPE => {
                    surface.exited.store(true, .release);
                    return;
                },

                // Any other error — exit
                else => {
                    std.debug.print("ReadThread: ReadFile error: {}\n", .{err});
                    surface.exited.store(true, .release);
                    return;
                },
            }
        }
        if (bytes_read == 0) {
            surface.exited.store(true, .release);
            return;
        }

        // Process VT data under render lock
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();

        surface.resetOscBatch();
        var stream = surface.vtStream();
        const data = buf[0..@intCast(bytes_read)];
        stream.nextSlice(data);
        surface.scanForOscTitle(data);
        surface.dirty.store(true, .release);
    }
}
