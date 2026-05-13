const std = @import("std");

pub const App = enum {
    none,
    codex,
    claude_code,

    pub fn label(self: App) []const u8 {
        return switch (self) {
            .none => "none",
            .codex => "codex",
            .claude_code => "claude_code",
        };
    }
};

pub const State = enum {
    none,
    running,
    waiting_approval,
    needs_input,
    halted,
    failed,
    done,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .none => "none",
            .running => "running",
            .waiting_approval => "waiting_approval",
            .needs_input => "needs_input",
            .halted => "halted",
            .failed => "failed",
            .done => "done",
        };
    }

    pub fn badge(self: State) []const u8 {
        return switch (self) {
            .none => "",
            .running => "run",
            .waiting_approval => "ask",
            .needs_input => "!",
            .halted => "halt",
            .failed => "err",
            .done => "done",
        };
    }
};

pub const Detection = struct {
    app: App = .none,
    state: State = .none,
    confidence: u8 = 0,

    pub fn visible(self: Detection) bool {
        return self.app != .none and self.state != .none and self.confidence > 0;
    }

    pub fn appLabel(self: Detection) []const u8 {
        return self.app.label();
    }

    pub fn stateLabel(self: Detection) []const u8 {
        return self.state.label();
    }

    pub fn badge(self: Detection) []const u8 {
        return self.state.badge();
    }
};

fn lowerAscii(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, i| {
            if (lowerAscii(haystack[start + i]) != lowerAscii(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return haystack.len;
    if (needle.len > haystack.len) return null;

    var start = haystack.len - needle.len;
    while (true) {
        var matched = true;
        for (needle, 0..) |needle_ch, i| {
            if (lowerAscii(haystack[start + i]) != lowerAscii(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return start;
        if (start == 0) return null;
        start -= 1;
    }
}

fn lastAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) ?usize {
    var latest: ?usize = null;
    for (needles) |needle| {
        if (lastIndexOfIgnoreCase(haystack, needle)) |idx| {
            if (latest == null or idx > latest.?) latest = idx;
        }
    }
    return latest;
}

fn newerThan(idx: usize, other: ?usize) bool {
    return other == null or idx > other.?;
}

fn titleHasAttentionMarker(title: []const u8) bool {
    return containsIgnoreCase(title, "[ ! ]") or
        containsIgnoreCase(title, "[!]") or
        containsIgnoreCase(title, " ! ");
}

fn titleHasRunningMarker(title: []const u8) bool {
    return containsIgnoreCase(title, "[ * ]") or
        containsIgnoreCase(title, "[*]");
}

fn titleHasClaudeStatusMarker(title: []const u8) bool {
    return containsAnyIgnoreCase(title, &.{
        "\xe2\x9c\xbb", // U+273B
        "\xe2\x9c\xa2", // U+2722
        "\xe2\x9c\xbd", // U+273D
    });
}

fn detectClaudeCode(title: []const u8, recent_output: []const u8) ?Detection {
    const claude_seen = containsAnyIgnoreCase(title, &.{
        "claude",
        "claude code",
        "claude-code",
    }) or titleHasClaudeStatusMarker(title) or
        containsAnyIgnoreCase(recent_output, &.{
            "claude code",
            "claude.ai/code/session",
            "do you want to make this edit",
            "do you want to make this change",
            "do you want to run this command",
            "yes, allow all edits during this session",
            "yes, allow all tools during this session",
        });
    if (!claude_seen) return null;

    const approval_idx = lastAnyIgnoreCase(recent_output, &.{
        "do you want to make this edit",
        "do you want to make this change",
        "do you want to create",
        "do you want to run this command",
        "do you want to proceed",
        "yes, allow all edits during this session",
        "yes, allow all tools during this session",
        "yes, allow all commands during this session",
    });
    const running_idx = lastAnyIgnoreCase(recent_output, &.{
        "thinking",
        "Update(",
        "Edit(",
        "MultiEdit(",
        "Write(",
        "Bash(",
        "Read(",
        "Grep(",
        "Glob(",
        "Task(",
        "TodoWrite(",
        "WebFetch(",
    });
    const halted_idx = lastAnyIgnoreCase(recent_output, &.{
        "interrupted by user",
        "operation cancelled",
        "operation canceled",
        "aborted",
    });
    const failure_idx = lastAnyIgnoreCase(recent_output, &.{
        "permission denied",
        "command failed",
        "error:",
        "failed",
    });
    const done_idx = lastAnyIgnoreCase(recent_output, &.{
        "no changes to make",
        "completed successfully",
        "all set",
    });

    if (approval_idx) |idx| {
        if (newerThan(idx, running_idx) and newerThan(idx, halted_idx) and newerThan(idx, failure_idx) and newerThan(idx, done_idx)) {
            return .{ .app = .claude_code, .state = .waiting_approval, .confidence = 90 };
        }
    }
    if (halted_idx) |idx| {
        if (newerThan(idx, done_idx) and newerThan(idx, running_idx)) {
            return .{ .app = .claude_code, .state = .halted, .confidence = 92 };
        }
    }
    if (failure_idx) |idx| {
        if (newerThan(idx, done_idx) and newerThan(idx, running_idx) and newerThan(idx, halted_idx)) {
            return .{ .app = .claude_code, .state = .failed, .confidence = 76 };
        }
    }
    if (done_idx) |idx| {
        if (newerThan(idx, running_idx) and newerThan(idx, halted_idx) and newerThan(idx, failure_idx)) {
            return .{ .app = .claude_code, .state = .done, .confidence = 76 };
        }
    }
    if (titleHasAttentionMarker(title)) {
        return .{ .app = .claude_code, .state = .needs_input, .confidence = 72 };
    }
    if (running_idx) |idx| {
        if (newerThan(idx, done_idx) and newerThan(idx, halted_idx)) {
            return .{ .app = .claude_code, .state = .running, .confidence = 82 };
        }
    }
    if (titleHasRunningMarker(title) or titleHasClaudeStatusMarker(title)) {
        return .{ .app = .claude_code, .state = .running, .confidence = 82 };
    }

    return .{ .app = .claude_code, .state = .none, .confidence = 45 };
}

pub fn detect(title: []const u8, recent_output: []const u8) Detection {
    if (detectClaudeCode(title, recent_output)) |detection| return detection;

    const codex_seen = containsAnyIgnoreCase(title, &.{ "codex", "[ ! ]", "[!]", "[ * ]", "[*]" }) or
        containsAnyIgnoreCase(recent_output, &.{
            "codex",
            "execution halted",
            "esc to interrupt",
            "transcript)",
            "background terminal",
            "approved codex",
            "would you like to make the following edits",
            "press enter to confirm or esc to cancel",
            "retry without sandbox",
        });
    if (!codex_seen) return .{};

    const approval_idx = lastAnyIgnoreCase(recent_output, &.{
        "do you want codex",
        "approve codex",
        "approval required",
        "would you like to make the following edits",
        "press enter to confirm or esc to cancel",
        "yes, proceed",
        "don't ask again",
        "retry without sandbox",
    });
    const approved_idx = lastAnyIgnoreCase(recent_output, &.{
        "you approved codex",
        "you approved",
    });
    const active_approval = if (approval_idx) |prompt_idx|
        approved_idx == null or prompt_idx > approved_idx.?
    else
        false;

    if (active_approval) {
        return .{ .app = .codex, .state = .waiting_approval, .confidence = 90 };
    }

    const halted_idx = lastAnyIgnoreCase(recent_output, &.{
        "execution halted",
    });
    const done_idx = lastAnyIgnoreCase(recent_output, &.{
        "worked for ",
    });
    const running_idx = lastAnyIgnoreCase(recent_output, &.{
        "working (",
        "esc to interrupt",
        "waited for background terminal",
    });
    const failure_idx = lastAnyIgnoreCase(recent_output, &.{ "permission denied", "command failed" });

    if (halted_idx) |idx| {
        if (newerThan(idx, done_idx)) {
            return .{ .app = .codex, .state = .halted, .confidence = 96 };
        }
    }
    if (failure_idx) |idx| {
        const is_after_approval = approved_idx == null or idx > approved_idx.?;
        if (is_after_approval and newerThan(idx, done_idx) and newerThan(idx, running_idx) and newerThan(idx, halted_idx)) {
            return .{ .app = .codex, .state = .failed, .confidence = 78 };
        }
    }
    if (done_idx) |idx| {
        if (newerThan(idx, running_idx) and newerThan(idx, halted_idx) and newerThan(idx, failure_idx)) {
            return .{ .app = .codex, .state = .done, .confidence = 82 };
        }
    }
    if (titleHasAttentionMarker(title)) {
        return .{ .app = .codex, .state = .needs_input, .confidence = 72 };
    }
    if (running_idx) |idx| {
        if (newerThan(idx, done_idx) and newerThan(idx, halted_idx)) {
            return .{ .app = .codex, .state = .running, .confidence = 82 };
        }
    }
    if (titleHasRunningMarker(title)) {
        return .{ .app = .codex, .state = .running, .confidence = 82 };
    }

    return .{ .app = .codex, .state = .none, .confidence = 45 };
}

test "agent detector recognizes Codex halted output" {
    const detection = detect("[ ! ]", "Execution halted\nWorking (3m 11s - esc to interrupt)");
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.halted, detection.state);
    try std.testing.expect(detection.visible());
}

test "agent detector recognizes Codex running output" {
    const detection = detect("codex", "Working (12s - esc to interrupt)");
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.running, detection.state);
}

test "agent detector treats Codex sandbox retry prompt as approval" {
    const output =
        \\Would you like to make the following edits?
        \\
        \\Reason: command failed; retry without sandbox?
        \\
        \\> 1. Yes, proceed (y)
        \\  2. Yes, and don't ask again for these files (a)
        \\  3. No, and tell codex what to do differently (esc)
        \\
        \\Press enter to confirm or esc to cancel
    ;
    const detection = detect("[ ! ]", output);
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.waiting_approval, detection.state);
    try std.testing.expectEqualStrings("ask", detection.badge());
}

test "agent detector ignores stale approval prompt after Codex approval" {
    const output =
        \\Would you like to make the following edits?
        \\Reason: command failed; retry without sandbox?
        \\Press enter to confirm or esc to cancel
        \\You approved codex to run python3 this time
        \\Working (3s - esc to interrupt)
    ;
    const detection = detect("codex", output);
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.running, detection.state);
}

test "agent detector marks Codex completion after running output as done" {
    const output =
        \\Working (12s - esc to interrupt)
        \\You approved codex to run zsh this time
        \\Ran zsh -lc 'node /data1/home/xzg/hell.js'
        \\Worked for 2m 14s
        \\› use /skills to list available skills
    ;
    const detection = detect("codex", output);
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.done, detection.state);
    try std.testing.expectEqualStrings("done", detection.badge());
}

test "agent detector prefers newer running marker after old completion" {
    const output =
        \\Worked for 2m 14s
        \\Working (3s - esc to interrupt)
    ;
    const detection = detect("codex", output);
    try std.testing.expectEqual(App.codex, detection.app);
    try std.testing.expectEqual(State.running, detection.state);
}

test "agent detector recognizes Claude Code approval prompt" {
    const output =
        \\Claude Code v2.1.140
        \\Update(tools/clashmate/index.html)
        \\Do you want to make this edit to index.html?
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    const detection = detect("Claude Code v2.1.140", output);
    try std.testing.expectEqual(App.claude_code, detection.app);
    try std.testing.expectEqual(State.waiting_approval, detection.state);
    try std.testing.expectEqualStrings("ask", detection.badge());
}

test "agent detector recognizes Claude Code running title marker" {
    const detection = detect("\xe2\x9c\xbb Hiding advanced features", "Read 5 files, listed 5 directories, ran 1 shell command");
    try std.testing.expectEqual(App.claude_code, detection.app);
    try std.testing.expectEqual(State.running, detection.state);
}

test "agent detector ignores stale Claude Code approval after newer tool output" {
    const output =
        \\Do you want to make this edit to index.html?
        \\  1. Yes
        \\Update(tools/clashmate/index.html)
    ;
    const detection = detect("Claude Code", output);
    try std.testing.expectEqual(App.claude_code, detection.app);
    try std.testing.expectEqual(State.running, detection.state);
}

test "agent detector ignores normal shell output" {
    const detection = detect("PowerShell", "PS C:\\Users> ls");
    try std.testing.expectEqual(App.none, detection.app);
    try std.testing.expectEqual(State.none, detection.state);
    try std.testing.expect(!detection.visible());
}
