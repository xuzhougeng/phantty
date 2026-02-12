# General-Purpose Mailbox + xev Event Loop

## Context

We just implemented threaded resize using `WaitForMultipleObjects` + manual timestamp-based coalescing + a mutex-protected `?GridSize` field. This works but is ad-hoc — the IO thread can only handle one kind of message (resize) and the event loop is hand-rolled Win32.

Ghostty uses a proper architecture: a SPSC mailbox with a tagged union `Message` type, and an xev event loop in the IO writer thread that provides `Async` (wakeup) and `Timer` (coalescing) primitives. This makes the IO thread extensible to future message types (writes, focus, config changes) without restructuring.

This plan replaces our hand-rolled approach with:
1. **libxev** as a dependency (IOCP backend on Windows)
2. **Tagged union `Message`** type (resize now, extensible later)
3. **SPSC `Mailbox`** (fixed-capacity ring buffer + `xev.Async` wakeup)
4. **Two IO threads per surface** (like Ghostty): writer (xev loop) + reader (blocking ReadFile)

## Architecture (Target)

```
Main thread
  → Surface.queueIo(.{ .resize = grid })
  → mailbox.send(msg)     // push to ring buffer
  → mailbox.notify()      // xev.Async.notify()
      ↓
IO Writer thread (xev event loop)
  → wakeupCallback → drainMailbox()
  → .resize → store in coalesce_data, start 25ms xev.Timer
  → coalesceCallback → applyResize()
      → pty.setSize()
      → lock { terminal.resize(); scrollViewport(.bottom) }
      → dirty = true

IO Reader thread (blocking loop)
  → ReadFile(out_pipe) in tight loop
  → lock { vtStream.nextSlice(); scanForOscTitle() }
  → dirty = true
  → on error/close: exited = true
```

## Files to Create/Modify

| File | Action |
|---|---|
| `build.zig.zon` | Add libxev dependency |
| `build.zig` | Wire xev module + link ws2_32/mswsock |
| `src/termio/message.zig` | **New:** Message tagged union |
| `src/termio/Mailbox.zig` | **New:** SPSC ring buffer + xev.Async |
| `src/termio/Thread.zig` | Rewrite: xev event loop, mailbox drain, coalesce timer |
| `src/termio/ReadThread.zig` | **New:** Blocking ReadFile reader loop |
| `src/termio.zig` | Re-export new modules |
| `src/Surface.zig` | Replace io_wakeup/resize_mutex/pending_resize with Mailbox; add `queueIo()` |

## Step 1: Add libxev dependency

**`build.zig.zon`** — add to `.dependencies`:
```zig
.libxev = .{
    .url = "https://deps.files.ghostty.org/libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz",
    .hash = "libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs",
},
```

Use the same URL/hash Ghostty uses (already in zig cache). This is a Zig-only module, no C library to link.

**`build.zig`** — after ghostty-vt import, add:
```zig
if (b.lazyDependency("libxev", .{
    .target = target,
    .optimize = optimize,
})) |dep| {
    exe_mod.addImport("xev", dep.module("xev"));
}
```

Also link Windows socket libraries (required by xev IOCP backend):
```zig
exe_mod.linkSystemLibrary("ws2_32", .{});
exe_mod.linkSystemLibrary("mswsock", .{});
```

## Step 2: Create `src/termio/message.zig`

```zig
const renderer = @import("../renderer.zig");

pub const Message = union(enum) {
    resize: renderer.size.GridSize,
    // Future: write_small, focused, clear_screen, change_config, etc.
};
```

Start minimal. The tagged union is trivially extensible — adding a new variant requires only adding the field here and a switch case in `Thread.drainMailbox()`.

## Step 3: Create `src/termio/Mailbox.zig`

Fixed-capacity SPSC ring buffer with mutex + xev.Async wakeup.

```zig
const xev = @import("xev");
const Message = @import("message.zig").Message;

pub const CAPACITY = 64;

pub const Mailbox = struct {
    queue: [CAPACITY]Message = undefined,
    head: usize = 0,       // consumer reads from here
    tail: usize = 0,       // producer writes here
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    wakeup: xev.Async,

    pub fn init() !Mailbox { ... }   // creates xev.Async
    pub fn deinit(self: *Mailbox) void { ... }
    pub fn send(self: *Mailbox, msg: Message) void { ... }  // lock, push (drop oldest if full), unlock
    pub fn notify(self: *Mailbox) void { ... }  // wakeup.notify()
    pub fn pop(self: *Mailbox) ?Message { ... } // lock, pop, unlock
};
```

Design notes:
- `send()` + `notify()` are separate (like Ghostty) so the caller can batch sends before one notify
- Drop-oldest on overflow (not blocking) — simpler than Ghostty's blocking-with-mutex-release, and resize messages are last-writer-wins anyway
- Mutex-based, not lock-free — adequate for our single-producer single-consumer pattern with tiny critical sections

## Step 4: Create `src/termio/ReadThread.zig`

Extract the PTY reader into its own file. Matches Ghostty's `Exec.ReadThread.threadMainWindows`:

```zig
pub fn threadMain(surface: *Surface) void {
    var buf: [1024]u8 = undefined;
    while (true) {
        var bytes_read: windows.DWORD = 0;
        if (windows.kernel32.ReadFile(surface.pty.out_pipe, &buf, buf.len, &bytes_read, null) == 0) {
            surface.exited.store(true, .release);
            return;
        }
        if (bytes_read == 0) { surface.exited.store(true, .release); return; }

        // Process under render lock
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        surface.resetOscBatch();
        var stream = surface.vtStream();
        const data = buf[0..@intCast(bytes_read)];
        stream.nextSlice(data) catch {};
        surface.scanForOscTitle(data);
        surface.dirty.store(true, .release);
    }
}
```

Simple blocking ReadFile — no overlapped I/O needed. Ghostty deliberately chose this over async I/O because "empirically fast compared to putting the read into an async mechanism like io_uring/epoll because the reads are generally small." Shutdown via `CancelIoEx` from `deinit()`.

## Step 5: Rewrite `src/termio/Thread.zig`

The writer thread runs an xev event loop:

```zig
const xev = @import("xev");

pub const Thread = struct {
    loop: xev.Loop,
    wakeup_c: xev.Completion = .{},
    stop: xev.Async,
    stop_c: xev.Completion = .{},
    coalesce: xev.Timer,
    coalesce_c: xev.Completion = .{},
    coalesce_cancel_c: xev.Completion = .{},
    coalesce_data: ?renderer.size.GridSize = null,

    pub fn init() !Thread { ... }  // init loop, stop, coalesce
    pub fn deinit(self: *Thread) void { ... }

    pub fn threadMain(self: *Thread, surface: *Surface) void {
        // Register wakeup callback for mailbox
        surface.mailbox.wakeup.wait(&self.loop, &self.wakeup_c, ...);
        // Register stop callback
        self.stop.wait(&self.loop, &self.stop_c, ...);
        // Run event loop
        self.loop.run(.until_done) catch {};
    }

    fn wakeupCallback(...) { drainMailbox(); return .rearm; }
    fn stopCallback(...) { return .disarm; } // exits loop

    fn drainMailbox(self: *Thread, surface: *Surface) void {
        while (surface.mailbox.pop()) |msg| {
            switch (msg) {
                .resize => |grid| self.handleResize(surface, grid),
            }
        }
    }

    fn handleResize(self: *Thread, surface: *Surface, grid: GridSize) void {
        self.coalesce_data = grid;
        if (self.coalesce_c active) return; // timer already running
        self.coalesce.reset(&self.loop, &self.coalesce_c, ..., 25, coalesceCallback);
    }

    fn coalesceCallback(...) {
        if (self.coalesce_data) |grid| {
            self.coalesce_data = null;
            applyResize(surface, grid);
        }
        return .disarm;
    }

    fn applyResize(surface: *Surface, grid: GridSize) void {
        surface.pty.setSize(.{ .ws_col = grid.cols, .ws_row = grid.rows }) catch {};
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        surface.terminal.resize(surface.allocator, grid.cols, grid.rows) catch {};
        surface.terminal.scrollViewport(.{ .bottom = {} }) catch {};
        surface.dirty.store(true, .release);
    }
};
```

Key difference from current: xev.Timer gives precise 25ms callback instead of manual deadline checking. xev.Async replaces Win32 `SetEvent` for mailbox wakeup.

## Step 6: Update `src/Surface.zig`

**Remove:** `io_wakeup`, `resize_mutex`, `pending_resize` fields

**Add:**
```zig
mailbox: termio.Mailbox,
io_writer_thread: ?std.Thread = null,
io_reader_thread: ?std.Thread = null,
io_thread_state: ?termio.Thread = null,  // xev loop state, owned by writer thread
```

**Replace `queueResize()`** with general `queueIo()`:
```zig
pub fn queueIo(self: *Surface, msg: termio.Message) void {
    self.mailbox.send(msg);
    self.mailbox.notify();
}
```

**`setScreenSize()`** changes `self.queueResize(...)` → `self.queueIo(.{ .resize = .{ .cols = new_cols, .rows = new_rows } })`

**`init()`:**
- `surface.mailbox = try termio.Mailbox.init()`
- Spawn writer thread: `surface.io_writer_thread = Thread.spawn(.{}, writerThreadMain, .{surface})`
- Spawn reader thread: `surface.io_reader_thread = Thread.spawn(.{}, ReadThread.threadMain, .{surface})`

**`deinit()`:**
- Signal writer thread via `io_thread_state.stop.notify()`
- Cancel reader via `CancelIoEx(pty.out_pipe, null)`
- Join both threads
- `surface.mailbox.deinit()`

## Step 7: Update `src/termio.zig`

```zig
pub const Thread = @import("termio/Thread.zig");
pub const ReadThread = @import("termio/ReadThread.zig");
pub const Mailbox = @import("termio/Mailbox.zig").Mailbox;
pub const Message = @import("termio/message.zig").Message;
```

## Verification

1. `zig build` — compiles clean
2. `zig build -Doptimize=ReleaseFast` — release builds
3. Grep for direct `terminal.resize()` / `pty.setSize()` outside IO thread — should only be in Thread.zig
4. Functional: shell starts, type, resize window, splits, tab switch, close
5. Resize overlay still appears during drag (setScreenSize still returns true on grid change)
