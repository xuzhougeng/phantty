const std = @import("std");

pub const State = struct {
    total: usize,
    len: usize,
    offset: usize,
};

pub const Command = enum {
    line_up,
    line_down,
    page_up,
    page_down,
    thumb,
    top,
    bottom,
    end_scroll,
};

pub fn maxOffset(state: State) usize {
    if (state.total <= state.len) return 0;
    return state.total - state.len;
}

pub fn clampedOffset(state: State, offset: usize) usize {
    return @min(offset, maxOffset(state));
}

pub fn targetOffset(state: State, command: Command, thumb_pos: ?i32) ?usize {
    const max_offset = maxOffset(state);
    if (max_offset == 0) return null;
    const current = @min(state.offset, max_offset);

    return switch (command) {
        .line_up => if (current == 0) 0 else current - 1,
        .line_down => @min(current + 1, max_offset),
        .page_up => if (current <= state.len) 0 else current - state.len,
        .page_down => @min(current + state.len, max_offset),
        .thumb => blk: {
            const pos = thumb_pos orelse return null;
            if (pos <= 0) break :blk 0;
            break :blk @min(@as(usize, @intCast(pos)), max_offset);
        },
        .top => 0,
        .bottom => max_offset,
        .end_scroll => null,
    };
}

pub fn deltaToTarget(state: State, target: usize) isize {
    const current: i64 = @intCast(clampedOffset(state, state.offset));
    const wanted: i64 = @intCast(clampedOffset(state, target));
    return @intCast(wanted - current);
}

test "native scrollbar commands clamp to scrollback range" {
    const state = State{ .total = 200, .len = 40, .offset = 30 };

    try std.testing.expectEqual(@as(?usize, 70), targetOffset(state, .page_down, null));
    try std.testing.expectEqual(@as(?usize, 0), targetOffset(state, .thumb, -20));
    try std.testing.expectEqual(@as(?usize, 160), targetOffset(state, .thumb, 240));
}

test "native scrollbar delta is relative to current viewport offset" {
    const state = State{ .total = 200, .len = 40, .offset = 30 };

    try std.testing.expectEqual(@as(isize, -30), deltaToTarget(state, 0));
    try std.testing.expectEqual(@as(isize, 130), deltaToTarget(state, 160));
}
