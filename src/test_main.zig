//! Test entry point — imports modules containing unit tests.
//! Run with: zig build test

comptime {
    _ = @import("scp.zig");
    _ = @import("file_backend.zig");
    _ = @import("file_explorer.zig");
}
