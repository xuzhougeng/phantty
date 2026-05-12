//! Test entry point — imports modules containing unit tests.
//! Run with: zig build test

comptime {
    _ = @import("scp.zig");
    _ = @import("browser_panel.zig");
    _ = @import("browser_url.zig");
    _ = @import("config.zig");
    _ = @import("file_backend.zig");
    _ = @import("file_explorer.zig");
    _ = @import("input_shortcuts.zig");
    _ = @import("markdown_preview.zig");
    _ = @import("preview_token.zig");
    _ = @import("remote_client.zig");
    _ = @import("selection_unit.zig");
    _ = @import("session_persist.zig");
    _ = @import("split_tree.zig");
}
