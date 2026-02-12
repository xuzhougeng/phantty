/// Message types for the IO thread mailbox.
///
/// The main thread sends these to the IO writer thread via the Mailbox.
/// The tagged union is trivially extensible — adding a new variant requires
/// only adding the field here and a switch case in Thread.drainMailbox().

const renderer = @import("../renderer.zig");

pub const Message = union(enum) {
    /// Resize the terminal grid to the given dimensions.
    /// Coalesced with a 25ms timer before applying.
    resize: renderer.size.GridSize,

    // Future variants:
    // write_small: [64]u8,
    // focused: bool,
    // clear_screen: void,
};
