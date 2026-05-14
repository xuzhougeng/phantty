const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub const default_max_history_rows: usize = 10_000;

const RowSpace = enum {
    active,
    screen,
};

pub fn allocTerminalSnapshot(
    allocator: std.mem.Allocator,
    terminal: *const ghostty_vt.Terminal,
    max_history_rows: usize,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const screen = terminal.screens.active;
    const rows: usize = @intCast(screen.pages.rows);
    const cols: usize = @intCast(screen.pages.cols);
    const total_rows = @max(rows, screen.pages.total_rows);
    const history_total = total_rows - rows;
    const history_rows = @min(history_total, max_history_rows);
    const history_start = history_total - history_rows;

    var wrote_row = false;
    for (history_start..history_total) |row| {
        try appendSnapshotRow(allocator, &out, screen, .screen, row, cols, &wrote_row);
    }
    for (0..rows) |row| {
        try appendSnapshotRow(allocator, &out, screen, .active, row, cols, &wrote_row);
    }

    return out.toOwnedSlice(allocator);
}

fn appendSnapshotRow(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    screen: *const ghostty_vt.Screen,
    row_space: RowSpace,
    row: usize,
    cols: usize,
    wrote_row: *bool,
) !void {
    if (wrote_row.*) try out.appendSlice(allocator, "\r\n");
    wrote_row.* = true;

    var last_col: ?usize = null;
    for (0..cols) |col| {
        const cell_data = screen.pages.getCell(snapshotPoint(row_space, col, row)) orelse continue;
        const cp = cell_data.cell.codepoint();
        if (cp != 0 and cp != ' ') last_col = col;
    }

    const end_col = last_col orelse return;
    for (0..end_col + 1) |col| {
        const cell_data = screen.pages.getCell(snapshotPoint(row_space, col, row)) orelse {
            try out.append(allocator, ' ');
            continue;
        };
        try appendCellText(allocator, out, cell_data);
    }
}

fn snapshotPoint(row_space: RowSpace, col: usize, row: usize) ghostty_vt.Point {
    const coord: ghostty_vt.Coordinate = .{
        .x = @intCast(col),
        .y = @intCast(row),
    };
    return switch (row_space) {
        .active => .{ .active = coord },
        .screen => .{ .screen = coord },
    };
}

fn appendCellText(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    cell_data: ghostty_vt.PageList.Cell,
) !void {
    const wide_val: u2 = @intFromEnum(cell_data.cell.wide);
    if (wide_val == 2 or wide_val == 3) return;

    const cp = cell_data.cell.codepoint();
    if (cp == 0 or cp == ' ') {
        try out.append(allocator, ' ');
        return;
    }

    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch {
        try out.append(allocator, ' ');
        return;
    };
    try out.appendSlice(allocator, buf[0..len]);

    if (!cell_data.cell.hasGrapheme()) return;
    const page = &cell_data.node.data;
    if (page.lookupGrapheme(cell_data.cell)) |extra_cps| {
        for (extra_cps) |ecp| {
            const extra_len = std.unicode.utf8Encode(@intCast(ecp), &buf) catch continue;
            try out.appendSlice(allocator, buf[0..extra_len]);
        }
    }
}

test "remote terminal snapshot includes scrollback before active screen" {
    var terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 3,
        .max_scrollback = 1024,
    });
    defer terminal.deinit(std.testing.allocator);

    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("line1\r\nline2\r\nline3\r\nline4\r\nline5\r\nline6");

    const snapshot = try allocTerminalSnapshot(std.testing.allocator, &terminal, 1024);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "line6") != null);
    try std.testing.expectEqual(terminal.screens.active.pages.total_rows, snapshotRowCount(snapshot));
}

fn snapshotRowCount(snapshot: []const u8) usize {
    if (snapshot.len == 0) return 0;
    return std.mem.count(u8, snapshot, "\r\n") + 1;
}
