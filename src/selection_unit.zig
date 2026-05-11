const std = @import("std");

pub const ColRange = struct {
    start: usize,
    end: usize,
};

pub const RowRange = struct {
    start_row: usize,
    end_row: usize,
    start_col: usize,
    end_col: usize,
};

pub fn wordRange(row: []const u21, col: usize) ?ColRange {
    if (col >= row.len or !isWordCodepoint(row[col])) return null;

    var start = col;
    while (start > 0 and isWordCodepoint(row[start - 1])) : (start -= 1) {}

    var end = col;
    while (end + 1 < row.len and isWordCodepoint(row[end + 1])) : (end += 1) {}

    return .{ .start = start, .end = end };
}

pub fn sentenceRange(row: []const u21, col: usize) ?ColRange {
    if (col >= row.len) return null;
    const first = firstNonBlankCol(row) orelse return null;
    const last = lastNonBlankCol(row) orelse return null;
    if (col < first or col > last) return null;

    var start: usize = 0;
    var cursor = col;
    while (cursor > 0) {
        cursor -= 1;
        if (isSentenceTerminator(row[cursor])) {
            start = cursor + 1;
            while (start <= last and isSentenceCloser(row[start])) : (start += 1) {}
            break;
        }
    }
    while (start <= last and isBlankCodepoint(row[start])) : (start += 1) {}

    var end = last;
    cursor = col;
    while (cursor <= last) : (cursor += 1) {
        if (isSentenceTerminator(row[cursor])) {
            end = cursor;
            while (end + 1 <= last and isSentenceCloser(row[end + 1])) : (end += 1) {}
            break;
        }
    }
    while (end > start and isBlankCodepoint(row[end])) : (end -= 1) {}

    if (start > end) return null;
    return .{ .start = start, .end = end };
}

pub fn paragraphRange(rows: []const []const u21, row: usize) ?RowRange {
    if (row >= rows.len or rowIsBlank(rows[row])) return null;

    var start_row = row;
    while (start_row > 0 and !rowIsBlank(rows[start_row - 1])) : (start_row -= 1) {}

    var end_row = row;
    while (end_row + 1 < rows.len and !rowIsBlank(rows[end_row + 1])) : (end_row += 1) {}

    return .{
        .start_row = start_row,
        .end_row = end_row,
        .start_col = firstNonBlankCol(rows[start_row]) orelse 0,
        .end_col = lastNonBlankCol(rows[end_row]) orelse 0,
    };
}

pub fn firstNonBlankCol(row: []const u21) ?usize {
    for (row, 0..) |cp, i| {
        if (!isBlankCodepoint(cp)) return i;
    }
    return null;
}

pub fn lastNonBlankCol(row: []const u21) ?usize {
    var i = row.len;
    while (i > 0) {
        i -= 1;
        if (!isBlankCodepoint(row[i])) return i;
    }
    return null;
}

pub fn rowIsBlank(row: []const u21) bool {
    return firstNonBlankCol(row) == null;
}

pub fn trimTrailingClipboardSpaces(row: []const u8) []const u8 {
    var end = row.len;
    while (end > 0 and row[end - 1] <= ' ') : (end -= 1) {}
    return row[0..end];
}

pub fn isWordCodepoint(cp: u21) bool {
    if (cp >= '0' and cp <= '9') return true;
    if (cp >= 'A' and cp <= 'Z') return true;
    if (cp >= 'a' and cp <= 'z') return true;
    if (cp == '_') return true;
    return cp > 0x7f and !isBlankCodepoint(cp);
}

fn isBlankCodepoint(cp: u21) bool {
    return cp == 0 or cp <= 0x20;
}

fn isSentenceTerminator(cp: u21) bool {
    return cp == '.' or cp == '!' or cp == '?';
}

fn isSentenceCloser(cp: u21) bool {
    return switch (cp) {
        '"', '\'', ')', ']', '}' => true,
        else => false,
    };
}

test "selection unit: word range selects an alphanumeric token" {
    const row = comptime toCodepoints("alpha beta_42.");
    try std.testing.expectEqual(ColRange{ .start = 6, .end = 12 }, wordRange(&row, 8).?);
}

test "selection unit: sentence range trims surrounding whitespace and includes terminator" {
    const row = comptime toCodepoints("  first sentence. second one!  ");
    try std.testing.expectEqual(ColRange{ .start = 18, .end = 28 }, sentenceRange(&row, 23).?);
}

test "selection unit: paragraph range selects contiguous nonblank rows" {
    const row0 = comptime toCodepoints("");
    const row1 = comptime toCodepoints("  first line");
    const row2 = comptime toCodepoints("second line  ");
    const row3 = comptime toCodepoints("   ");
    const rows = [_][]const u21{ &row0, &row1, &row2, &row3 };
    try std.testing.expectEqual(RowRange{
        .start_row = 1,
        .end_row = 2,
        .start_col = 2,
        .end_col = 10,
    }, paragraphRange(&rows, 2).?);
}

test "selection unit: clipboard row trim removes trailing terminal blanks only" {
    try std.testing.expectEqualStrings(
        "CC_AGENT_API_KEY=\"$(cat ~/.cc-agent-key)\" \\",
        trimTrailingClipboardSpaces("CC_AGENT_API_KEY=\"$(cat ~/.cc-agent-key)\" \\     "),
    );
    try std.testing.expectEqualStrings(
        "           -cwd ~/cc-agent/yard \\",
        trimTrailingClipboardSpaces("           -cwd ~/cc-agent/yard \\     "),
    );
    try std.testing.expectEqualStrings("", trimTrailingClipboardSpaces("     \t  "));
}

fn toCodepoints(comptime text: []const u8) [text.len]u21 {
    var out: [text.len]u21 = undefined;
    for (text, 0..) |ch, i| out[i] = ch;
    return out;
}
