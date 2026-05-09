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

pub fn terminalArrowSequence(ev: win32_backend.KeyEvent) ?[]const u8 {
    const modifier: u8 = 1 +
        @as(u8, if (ev.shift) 1 else 0) +
        @as(u8, if (ev.alt) 2 else 0) +
        @as(u8, if (ev.ctrl) 4 else 0);

    inline for (terminal_arrow_sequences) |entry| {
        if (ev.vk == entry.vk) {
            return if (modifier == 1) entry.plain else entry.modified[modifier - 2];
        }
    }
    return null;
}

const TerminalArrowSequence = struct {
    vk: usize,
    plain: []const u8,
    modified: [7][]const u8,
};

const terminal_arrow_sequences = [_]TerminalArrowSequence{
    .{ .vk = win32_backend.VK_UP, .plain = "\x1b[A", .modified = .{ "\x1b[1;2A", "\x1b[1;3A", "\x1b[1;4A", "\x1b[1;5A", "\x1b[1;6A", "\x1b[1;7A", "\x1b[1;8A" } },
    .{ .vk = win32_backend.VK_DOWN, .plain = "\x1b[B", .modified = .{ "\x1b[1;2B", "\x1b[1;3B", "\x1b[1;4B", "\x1b[1;5B", "\x1b[1;6B", "\x1b[1;7B", "\x1b[1;8B" } },
    .{ .vk = win32_backend.VK_RIGHT, .plain = "\x1b[C", .modified = .{ "\x1b[1;2C", "\x1b[1;3C", "\x1b[1;4C", "\x1b[1;5C", "\x1b[1;6C", "\x1b[1;7C", "\x1b[1;8C" } },
    .{ .vk = win32_backend.VK_LEFT, .plain = "\x1b[D", .modified = .{ "\x1b[1;2D", "\x1b[1;3D", "\x1b[1;4D", "\x1b[1;5D", "\x1b[1;6D", "\x1b[1;7D", "\x1b[1;8D" } },
};

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

test "terminal arrow sequence preserves Alt modifiers" {
    try std.testing.expectEqualStrings(
        "\x1b[A",
        terminalArrowSequence(.{ .vk = win32_backend.VK_UP, .ctrl = false, .shift = false, .alt = false }).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[1;3D",
        terminalArrowSequence(.{ .vk = win32_backend.VK_LEFT, .ctrl = false, .shift = false, .alt = true }).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[1;3C",
        terminalArrowSequence(.{ .vk = win32_backend.VK_RIGHT, .ctrl = false, .shift = false, .alt = true }).?,
    );
    try std.testing.expect(terminalArrowSequence(.{ .vk = 0x41, .ctrl = false, .shift = false, .alt = true }) == null);
}
