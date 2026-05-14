//! Test entry point — imports modules containing unit tests.
//! Run with: zig build test

const build_options = @import("build_options");

comptime {
    _ = @import("ai_chat.zig");
    _ = @import("agent_detector.zig");
    _ = @import("scp.zig");
    _ = if (build_options.webview) @import("browser_panel.zig") else @import("browser_panel_stub.zig");
    _ = @import("browser_url.zig");
    _ = @import("config.zig");
    _ = @import("file_backend.zig");
    _ = @import("file_explorer.zig");
    _ = @import("input_shortcuts.zig");
    _ = @import("markdown_preview.zig");
    _ = @import("preview_token.zig");
    _ = @import("remote_client.zig");
    _ = @import("remote_snapshot.zig");
    _ = @import("selection_unit.zig");
    _ = @import("session_persist.zig");
    _ = @import("ssh_prompt.zig");
    _ = @import("split_tree.zig");
}
