const std = @import("std");

const SplitTree = @import("split_tree.zig");
const win32_backend = @import("apprt/win32.zig");

pub fn spatialFocusDirection(ev: win32_backend.KeyEvent) ?SplitTree.Spatial.Direction {
    if (!ev.ctrl or !ev.shift or ev.alt) return null;

    return switch (ev.vk) {
        win32_backend.VK_LEFT => .left,
        win32_backend.VK_RIGHT => .right,
        win32_backend.VK_UP => .up,
        win32_backend.VK_DOWN => .down,
        else => null,
    };
}

test "spatial focus uses Ctrl+Shift+Arrow and not Alt+Arrow" {
    try std.testing.expectEqual(
        @as(?SplitTree.Spatial.Direction, .up),
        spatialFocusDirection(.{ .vk = win32_backend.VK_UP, .ctrl = true, .shift = true, .alt = false }),
    );
    try std.testing.expectEqual(
        @as(?SplitTree.Spatial.Direction, .down),
        spatialFocusDirection(.{ .vk = win32_backend.VK_DOWN, .ctrl = true, .shift = true, .alt = false }),
    );
    try std.testing.expectEqual(
        @as(?SplitTree.Spatial.Direction, .left),
        spatialFocusDirection(.{ .vk = win32_backend.VK_LEFT, .ctrl = true, .shift = true, .alt = false }),
    );
    try std.testing.expectEqual(
        @as(?SplitTree.Spatial.Direction, .right),
        spatialFocusDirection(.{ .vk = win32_backend.VK_RIGHT, .ctrl = true, .shift = true, .alt = false }),
    );
    try std.testing.expectEqual(
        @as(?SplitTree.Spatial.Direction, null),
        spatialFocusDirection(.{ .vk = win32_backend.VK_UP, .ctrl = false, .shift = false, .alt = true }),
    );
}
