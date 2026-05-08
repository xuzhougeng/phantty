//! URL helpers for the embedded browser panel.

const std = @import("std");

pub const HttpUrl = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    suffix: []const u8,
};

pub fn parseHttpUrl(url: []const u8) ?HttpUrl {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..scheme_end];
    const is_http = std.ascii.eqlIgnoreCase(scheme, "http");
    const is_https = std.ascii.eqlIgnoreCase(scheme, "https");
    if (!is_http and !is_https) return null;

    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfAnyPos(u8, url, authority_start, "/?#") orelse url.len;
    const authority = url[authority_start..authority_end];
    if (authority.len == 0) return null;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return null;

    var host = authority;
    var port: ?u16 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        host = authority[1..close];
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return null;
            port = std.fmt.parseInt(u16, authority[close + 2 ..], 10) catch return null;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        const maybe_port = authority[colon + 1 ..];
        if (maybe_port.len > 0 and allDigits(maybe_port)) {
            host = authority[0..colon];
            port = std.fmt.parseInt(u16, maybe_port, 10) catch return null;
        }
    }
    if (host.len == 0) return null;

    return .{
        .scheme = scheme,
        .host = host,
        .port = port orelse if (is_https) 443 else 80,
        .suffix = url[authority_end..],
    };
}

pub fn isLoopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "0.0.0.0");
}

pub fn localTunnelHost(host: []const u8) []const u8 {
    return if (std.ascii.eqlIgnoreCase(host, "localhost")) "localhost" else "127.0.0.1";
}

pub fn remoteTunnelHost(host: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return "localhost";
    return "127.0.0.1";
}

pub fn isUnspecifiedHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "0.0.0.0");
}

pub fn buildLocalTunnelUrl(allocator: std.mem.Allocator, parsed: HttpUrl, local_port: u16) ?[]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}://{s}:{d}{s}",
        .{ parsed.scheme, localTunnelHost(parsed.host), local_port, parsed.suffix },
    ) catch null;
}

fn allDigits(text: []const u8) bool {
    for (text) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return text.len > 0;
}

test "parse localhost URL with explicit port" {
    const parsed = parseHttpUrl("http://localhost:43455/path?q=1#frag") orelse unreachable;
    try std.testing.expectEqualStrings("http", parsed.scheme);
    try std.testing.expectEqualStrings("localhost", parsed.host);
    try std.testing.expectEqual(@as(u16, 43455), parsed.port);
    try std.testing.expectEqualStrings("/path?q=1#frag", parsed.suffix);
    try std.testing.expect(isLoopbackHost(parsed.host));
}

test "parse 127 URL with default https port" {
    const parsed = parseHttpUrl("https://127.0.0.1") orelse unreachable;
    try std.testing.expectEqualStrings("https", parsed.scheme);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("", parsed.suffix);
    try std.testing.expect(isLoopbackHost(parsed.host));
}

test "non-loopback host remains direct" {
    const parsed = parseHttpUrl("https://10.10.1.20:8443") orelse unreachable;
    try std.testing.expectEqualStrings("10.10.1.20", parsed.host);
    try std.testing.expectEqual(@as(u16, 8443), parsed.port);
    try std.testing.expect(!isLoopbackHost(parsed.host));
}

test "0.0.0.0 maps to loopback tunnel targets" {
    const parsed = parseHttpUrl("http://0.0.0.0:1234") orelse unreachable;
    try std.testing.expectEqualStrings("0.0.0.0", parsed.host);
    try std.testing.expect(isLoopbackHost(parsed.host));
    try std.testing.expectEqualStrings("127.0.0.1", localTunnelHost(parsed.host));
    try std.testing.expectEqualStrings("127.0.0.1", remoteTunnelHost(parsed.host));
}

test "build local tunnel URL preserves suffix" {
    const parsed = parseHttpUrl("http://127.0.0.1:4232/app?q=1") orelse unreachable;
    const target = buildLocalTunnelUrl(std.testing.allocator, parsed, 55001) orelse unreachable;
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("http://127.0.0.1:55001/app?q=1", target);
}
