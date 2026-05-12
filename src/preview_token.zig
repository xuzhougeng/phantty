//! Token helpers for Ctrl-click URL and file preview extraction.

const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,
};

pub fn isDelimiter(cp: u21) bool {
    if (cp == 0 or cp <= 0x20) return true;
    return switch (cp) {
        '"', '\'', '`', '<', '>', '(', ')', '[', ']', '{', '}', '|', '\t', '\r', '\n' => true,
        else => false,
    };
}

pub fn trim(token: []const u8) []const u8 {
    const span = trimSpan(token);
    return token[span.start..span.end];
}

pub fn trimSpan(token: []const u8) Span {
    var start: usize = 0;
    var end: usize = token.len;

    while (start < end) {
        const decoded = codepointAt(token, start);
        if (!isLeadingTrimCodepoint(decoded.cp)) break;
        start += decoded.len;
    }

    while (end > start) {
        const prev = previousCodepointStart(token, start, end) orelse break;
        const decoded = codepointAt(token, prev);
        if (!isTrailingTrimCodepoint(decoded.cp)) break;
        end = prev;
    }

    return .{ .start = start, .end = end };
}

const Decoded = struct {
    cp: u21,
    len: usize,
};

fn codepointAt(text: []const u8, index: usize) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    if (index + len > text.len) return .{ .cp = text[index], .len = 1 };
    const cp = std.unicode.utf8Decode(text[index .. index + len]) catch text[index];
    return .{ .cp = cp, .len = len };
}

fn previousCodepointStart(text: []const u8, start: usize, end: usize) ?usize {
    var cursor = start;
    var previous: ?usize = null;
    while (cursor < end) {
        previous = cursor;
        cursor += codepointAt(text, cursor).len;
    }
    return if (cursor == end) previous else null;
}

fn isLeadingTrimCodepoint(cp: u21) bool {
    return switch (cp) {
        '\'',
        '"',
        '`',
        0x2018, // left single quotation mark
        0x201C, // left double quotation mark
        0x300C, // left corner bracket
        0x300E, // left white corner bracket
        0xFF02, // fullwidth quotation mark
        0xFF07, // fullwidth apostrophe
        => true,
        else => false,
    };
}

fn isTrailingTrimCodepoint(cp: u21) bool {
    return switch (cp) {
        '.',
        ',',
        ';',
        ':',
        '!',
        '?',
        ')',
        ']',
        '}',
        '"',
        '\'',
        '`',
        0x00BB, // right-pointing double angle quotation mark
        0x2019, // right single quotation mark
        0x201D, // right double quotation mark
        0x3001, // ideographic comma
        0x3002, // ideographic full stop
        0x300D, // right corner bracket
        0x300F, // right white corner bracket
        0x3011, // right black lenticular bracket
        0x3015, // right tortoise shell bracket
        0xFF01, // fullwidth exclamation mark
        0xFF09, // fullwidth right parenthesis
        0xFF0C, // fullwidth comma
        0xFF0E, // fullwidth full stop
        0xFF1A, // fullwidth colon
        0xFF1B, // fullwidth semicolon
        0xFF1F, // fullwidth question mark
        0xFF3D, // fullwidth right square bracket
        0xFF5D, // fullwidth right curly bracket
        => true,
        else => false,
    };
}

test "trim keeps preview path and drops ASCII sentence punctuation" {
    try std.testing.expectEqualStrings("docs/readme.md", trim("`docs/readme.md`."));
}

test "trim drops Chinese sentence punctuation after markdown path" {
    const token = "docs/superpowers/specs/2026-05-12-github-pages-docs-design.md\xE3\x80\x82";
    try std.testing.expectEqualStrings(
        "docs/superpowers/specs/2026-05-12-github-pages-docs-design.md",
        trim(token),
    );
}

test "trim preserves internal Unicode punctuation" {
    const token = "docs/\xE8\xAE\xBE\xE8\xAE\xA1\xE3\x80\x82notes.md\xEF\xBC\x8C";
    try std.testing.expectEqualStrings("docs/\xE8\xAE\xBE\xE8\xAE\xA1\xE3\x80\x82notes.md", trim(token));
}
