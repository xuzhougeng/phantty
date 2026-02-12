# Threaded Resize: Ghostty's IO-Thread Resize Model

## Context

Currently, terminal + PTY resize in Phantty happens synchronously on the **main thread** (inside `computeSplitLayout` → `Surface.setScreenSize`). This blocks rendering during resize and doesn't match Ghostty's architecture.

Ghostty's model: main thread detects pixel size change → queues message to IO thread → IO thread coalesces (25ms timer) → IO thread does PTY + terminal resize → notifies renderer. The main thread never directly calls `terminal.resize()` or `pty.setSize()`.

This plan implements that same threading model for Phantty.

## Message Flow (Target)

```
Main thread (computeSplitLayout)
  → Surface.setScreenSize()     // updates pixel/grid size in surface.size
  → Surface.queueResize(size)   // stores pending resize, signals IO thread
      ↓
IO thread (termio/Thread.zig)
  → WaitForMultipleObjects([read_event, wakeup_event], timeout)
  → on wakeup: store resize, set coalesce deadline (now + 25ms)
  → on timeout: apply coalesced resize
      → pty.setSize(cols, rows)
      → lock { terminal.resize(cols, rows); scrollViewport(.bottom) }
      → dirty = true
```

## Files to Modify

| File | Action |
|---|---|
| `src/apprt/win32.zig` | Add `CreateEventW`, `SetEvent`, `PIPE_ACCESS_INBOUND`, `GENERIC_WRITE` |
| `src/pty.zig` | Convert `out_pipe` to named pipe with `FILE_FLAG_OVERLAPPED` |
| `src/Surface.zig` | Add `allocator`, `io_wakeup`, `pending_resize`, `resize_mutex`; add `queueResize()`; remove terminal/PTY resize from `setScreenSize()` |
| `src/termio/Thread.zig` | Rewrite: overlapped I/O + `WaitForMultipleObjects` event loop with resize coalescing |

## Step 1: Extend `apprt/win32.zig`

Add these new declarations to the ConPTY/pipe section:

**Constants:**
- `PIPE_ACCESS_INBOUND: DWORD = 0x00000001` — server reads from named pipe
- `GENERIC_WRITE: DWORD = 0x40000000` — for client-side write access
- `ERROR_IO_PENDING: DWORD = 997` — overlapped operation in progress

**Functions:**
- `CreateEventW(lpEventAttributes, bManualReset, bInitialState, lpName) → ?HANDLE`
- `SetEvent(hEvent) → BOOL`

Note: `WaitForMultipleObjects`, `GetOverlappedResult`, `CancelIo` are already in `std.os.windows.kernel32` and don't need wrappers.

## Step 2: Convert `out_pipe` to named pipe

In `pty.zig`, replace the anonymous pipe for output with a named pipe pair (same pattern as `in_pipe`):

```zig
// Current: CreatePipe(&self.out_pipe, &self.out_pipe_pty, null, 0)
// New: createNamedPipePair with reversed direction

fn createOutputPipePair() !struct { server: HANDLE, client: HANDLE } {
    // Server (us): PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED  (we read)
    // Client (PTY): GENERIC_WRITE  (ConPTY writes)
}
```

Refactor `createNamedPipePair` to accept direction parameter, or create a second helper. The pipe name pattern `\\.\pipe\phantty-pty-{pid}-{counter}` remains the same (counter ensures uniqueness).

## Step 3: Add resize messaging to `Surface.zig`

**New fields:**
```zig
allocator: std.mem.Allocator,          // Stored for IO thread to use in terminal.resize()
io_wakeup: windows.HANDLE,             // Auto-reset event to wake IO thread
resize_mutex: std.Thread.Mutex = .{},  // Protects pending_resize
pending_resize: ?renderer.size.Size = null,  // Queued resize for IO thread
```

**New method — `queueResize()`:**
```zig
pub fn queueResize(self: *Surface, size: renderer.size.Size) void {
    self.resize_mutex.lock();
    self.pending_resize = size;
    self.resize_mutex.unlock();
    _ = win32.SetEvent(self.io_wakeup);
}
```

**Modify `setScreenSize()`:**
- Keep: update `self.size` (screen, cell, padding, grid) — main thread needs this for layout
- Remove: `self.pty.setSize(...)` and `self.terminal.resize(...)` calls
- Add: `self.queueResize(self.size)` when grid dimensions change

**Modify `init()`:**
- Store allocator: `surface.allocator = allocator`
- Create wakeup event: `surface.io_wakeup = win32.CreateEventW(null, 0, 0, null)` (auto-reset, initially non-signaled)

**Modify `deinit()`:**
- Signal wakeup event before joining IO thread (so it unblocks from WaitForMultipleObjects)
- Close `io_wakeup` handle after IO thread joins

## Step 4: Rewrite IO thread with overlapped I/O

Replace the blocking ReadFile loop in `termio/Thread.zig` with an event-driven loop using `WaitForMultipleObjects`:

```zig
const COALESCE_MS: i64 = 25;

pub fn threadMain(surface: *Surface) void {
    var buf: [READ_BUF_SIZE]u8 = undefined;

    // Create event for overlapped ReadFile
    const read_event = win32.CreateEventW(null, 1, 0, null);  // manual-reset
    if (read_event == null) return;
    defer windows.CloseHandle(read_event.?);

    const handles = [2]windows.HANDLE{ read_event.?, surface.io_wakeup };
    var coalesce_deadline: ?i64 = null;

    while (!surface.exited.load(.acquire)) {
        // Start overlapped read
        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        overlapped.hEvent = read_event;
        var bytes_read: windows.DWORD = 0;

        const read_result = windows.kernel32.ReadFile(
            surface.pty.out_pipe, &buf, READ_BUF_SIZE, &bytes_read, &overlapped
        );

        if (read_result == 0 and windows.kernel32.GetLastError() != ERROR_IO_PENDING) {
            // Real error (pipe closed)
            surface.exited.store(true, .release);
            return;
        }

        // Calculate wait timeout
        var timeout: windows.DWORD = win32.INFINITE;
        if (coalesce_deadline) |deadline| {
            const remaining = deadline - std.time.milliTimestamp();
            timeout = if (remaining <= 0) 0 else @intCast(remaining);
        }

        // Wait for: read complete, wakeup, or coalesce timeout
        const wait_result = windows.kernel32.WaitForMultipleObjects(
            2, &handles, 0, timeout
        );

        if (wait_result == win32.WAIT_OBJECT_0) {
            // Pipe data ready
            if (windows.kernel32.GetOverlappedResult(
                surface.pty.out_pipe, &overlapped, &bytes_read, 0
            ) != 0 and bytes_read > 0) {
                processData(surface, &buf, bytes_read);
            } else {
                surface.exited.store(true, .release);
                return;
            }
        } else {
            // Wakeup or timeout — cancel pending read
            _ = windows.kernel32.CancelIo(surface.pty.out_pipe);
            // Wait for cancellation to complete
            _ = windows.kernel32.GetOverlappedResult(
                surface.pty.out_pipe, &overlapped, &bytes_read, 1
            );
            // Process any data that arrived before cancellation
            if (bytes_read > 0) {
                processData(surface, &buf, bytes_read);
            }
        }

        // Handle resize coalescing
        if (wait_result == win32.WAIT_OBJECT_0 + 1) {
            // New resize message — set deadline if not already set
            if (coalesce_deadline == null) {
                coalesce_deadline = std.time.milliTimestamp() + COALESCE_MS;
            }
        }

        // Apply resize if deadline passed
        if (coalesce_deadline) |deadline| {
            if (std.time.milliTimestamp() >= deadline) {
                applyResize(surface);
                coalesce_deadline = null;
            }
        }
    }
}

fn processData(surface: *Surface, buf: *[READ_BUF_SIZE]u8, bytes_read: windows.DWORD) void {
    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    surface.resetOscBatch();
    var stream = surface.vtStream();

    const data = buf[0..@intCast(bytes_read)];
    stream.nextSlice(data) catch {};
    surface.scanForOscTitle(data);

    // Coalesce: drain additional buffered data (same as current)
    const MAX_COALESCE = 16;
    var coalesce_count: usize = 0;
    while (coalesce_count < MAX_COALESCE) : (coalesce_count += 1) {
        var avail: windows.DWORD = 0;
        if (win32.PeekNamedPipe(surface.pty.out_pipe, null, 0, null, &avail, null) == 0) break;
        if (avail == 0) break;

        var extra_bytes: windows.DWORD = 0;
        if (windows.kernel32.ReadFile(surface.pty.out_pipe, buf, READ_BUF_SIZE, &extra_bytes, null) == 0) break;
        if (extra_bytes == 0) break;

        const extra_data = buf[0..@intCast(extra_bytes)];
        stream.nextSlice(extra_data) catch {};
        surface.scanForOscTitle(extra_data);
    }

    surface.dirty.store(true, .release);
}

fn applyResize(surface: *Surface) void {
    surface.resize_mutex.lock();
    const size_opt = surface.pending_resize;
    surface.pending_resize = null;
    surface.resize_mutex.unlock();

    const size = size_opt orelse return;
    const new_cols = size.grid.cols;
    const new_rows = size.grid.rows;

    // PTY resize first (like Ghostty), then terminal
    surface.pty.setSize(.{ .ws_col = new_cols, .ws_row = new_rows }) catch {};

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    surface.terminal.resize(surface.allocator, new_cols, new_rows) catch {};
    surface.terminal.scrollViewport(.{ .bottom = {} }) catch {};
    surface.dirty.store(true, .release);
}
```

**Note on PeekNamedPipe coalescing within processData:** After the initial overlapped read completes, additional data may already be buffered. We drain it synchronously (same as current behavior) using regular ReadFile. This is safe because the overlapped read already completed.

**Simplified approach:** Consider removing the inner PeekNamedPipe coalescing loop entirely. The outer event loop already handles rapid data: if data arrives while we're processing, the next WaitForMultipleObjects returns immediately. The lock is held per-chunk (1KB), same as Ghostty.

## Step 5: Verify and clean up

1. `zig build` — compiles clean
2. Verify no direct `terminal.resize()` or `pty.setSize()` outside of IO thread
3. Functional test: shell starts, type, resize window (single + splits), tab switch, close
4. Verify resize overlay appears during window drag (should work unchanged — `computeSplitLayout` detects grid change via `setScreenSize` returning true)

## Edge Cases

- **Snapshot during resize gap:** Between `setScreenSize` updating `surface.size.grid` and the IO thread calling `terminal.resize()`, the terminal has old rows/cols. The snapshot function iterates `terminal.rows` (not `surface.size.grid.rows`), so it reads whatever rows exist — safe but may show blank space briefly.
- **Rapid resizing:** Multiple resizes within 25ms → only the latest is applied (coalesced). Same as Ghostty.
- **Inactive tabs:** Resized lazily when they become active (already the case after the unified resize change).
- **IO thread shutdown:** `deinit()` signals wakeup event + sets exited flag. IO thread sees exited or wakeup and exits cleanly. Then CancelIoEx cancels any pending overlapped read.
