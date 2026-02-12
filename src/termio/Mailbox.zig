/// SPSC mailbox: fixed-capacity ring buffer with mutex + xev.Async wakeup.
///
/// The main thread pushes messages via send(), then calls notify() to wake
/// the IO writer thread's xev event loop. The writer thread pops messages
/// via pop() in its wakeup callback.
///
/// Design notes:
/// - send() + notify() are separate (like Ghostty) so the caller can batch
///   sends before one notify
/// - Drop-oldest on overflow (not blocking) — simpler than Ghostty's
///   blocking-with-mutex-release, and resize messages are last-writer-wins anyway
/// - Mutex-based, not lock-free — adequate for our SPSC pattern with tiny
///   critical sections

const std = @import("std");
const xev = @import("xev");
const Message = @import("message.zig").Message;

const Mailbox = @This();

const CAPACITY = 64;

queue: [CAPACITY]Message = undefined,
head: usize = 0,
tail: usize = 0,
count: usize = 0,
mutex: std.Thread.Mutex = .{},
wakeup: xev.Async,

pub fn init() !Mailbox {
    return .{
        .wakeup = try xev.Async.init(),
    };
}

pub fn deinit(self: *Mailbox) void {
    self.wakeup.deinit();
}

/// Push a message onto the ring buffer. If full, drops the oldest message.
/// Thread-safe (uses mutex).
pub fn send(self: *Mailbox, msg: Message) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.count == CAPACITY) {
        // Drop oldest: advance head
        self.head = (self.head + 1) % CAPACITY;
        self.count -= 1;
    }

    self.queue[self.tail] = msg;
    self.tail = (self.tail + 1) % CAPACITY;
    self.count += 1;
}

/// Wake the IO writer thread's xev event loop.
/// Call after one or more send() calls.
pub fn notify(self: *Mailbox) void {
    self.wakeup.notify() catch {};
}

/// Pop a message from the ring buffer. Returns null if empty.
/// Thread-safe (uses mutex).
pub fn pop(self: *Mailbox) ?Message {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.count == 0) return null;

    const msg = self.queue[self.head];
    self.head = (self.head + 1) % CAPACITY;
    self.count -= 1;
    return msg;
}
