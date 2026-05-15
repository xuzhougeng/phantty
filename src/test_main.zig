//! Test entry point — imports modules containing unit tests.
//! Run with: zig build test

const build_options = @import("build_options");
const std = @import("std");
const app_metadata = @import("app_metadata.zig");

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
    _ = @import("native_scrollbar.zig");
    _ = @import("preview_token.zig");
    _ = @import("remote_client.zig");
    _ = @import("remote_snapshot.zig");
    _ = @import("selection_unit.zig");
    _ = @import("session_persist.zig");
    _ = @import("scrollbar_model.zig");
    _ = @import("ssh_prompt.zig");
    _ = @import("split_tree.zig");
}

test "app version metadata is exposed for CLI and command center" {
    try std.testing.expectEqualStrings("Phantty", app_metadata.name);
    try std.testing.expect(app_metadata.version.len > 0);

    var buf: [64]u8 = undefined;
    const line = try app_metadata.versionLine(&buf);
    try std.testing.expectEqualStrings("Phantty " ++ app_metadata.version, line);
}
