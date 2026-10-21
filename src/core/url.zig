//! Origin extraction / comparison and remote-URL matching for WebView traffic.
//!
//! Security model: every input is treated as hostile and the parser fails
//! closed. The following are rejected outright, because each one has been used
//! to bypass origin checks in real browsers:
//!
//! - userinfo (`http://good.example\@evil.example`, `http://evil@localhost`)
//! - percent-encoded hosts (`http://local%68ost`) — decoded only after the
//!   origin decision would already have been made by naive code
//! - backslashes (browsers normalize `\` to `/` in special schemes)
//! - control characters / whitespace (header/URL smuggling)
//!
//! Custom WebView schemes (`tauri://localhost`, `asset://localhost`,
//! `ipc://localhost`) are first-class origins, and default ports are
//! normalized so `http://localhost` and `http://localhost:80` compare equal.

const std = @import("std");
const glob = @import("glob.zig");

pub const tauri_origin: Origin = .{ .scheme = "tauri", .host = "localhost", .port = null };
pub const asset_origin: Origin = .{ .scheme = "asset", .host = "localhost", .port = null };
pub const ipc_origin: Origin = .{ .scheme = "http", .host = "ipc.localhost", .port = null };

pub const ParseError = error{
    /// Empty string, whitespace/control characters, or a backslash.
    InvalidUrl,
    /// No `scheme:` prefix.
    RelativeUrl,
    /// `scheme:` was not followed by an authority although the scheme needs one.
    MissingHost,
    /// Credentials embedded in the authority (`user:pass@host`).
    HasUserInfo,
    /// Empty host, percent-encoded host, non-ASCII host, or host too long.
    InvalidHost,
    /// Non-numeric or out-of-range port.
    InvalidPort,
};

pub const PercentDecodeError = error{ OutOfMemory, InvalidPercentEncoding };

/// A parsed absolute URL. All slices borrow from the input string.
pub const Url = struct {
    raw: []const u8,
    scheme: []const u8,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,

    pub fn origin(self: Url) ParseError!Origin {
        const host = self.host orelse return error.MissingHost;
        return .{ .scheme = self.scheme, .host = host, .port = self.port };
    }

    pub fn isLocal(self: Url) bool {
        return isLocalScheme(self.scheme);
    }

    pub fn isRemote(self: Url) bool {
        return isRemoteScheme(self.scheme);
    }

    /// Case-insensitive scheme comparison.
    pub fn schemeIs(self: Url, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.scheme, name);
    }
};

/// A normalized `scheme://host[:port]` triple.
pub const Origin = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16 = null,

    /// Same scheme, host and effective port (default ports normalized).
    pub fn eql(self: Origin, other: Origin) bool {
        if (!std.ascii.eqlIgnoreCase(self.scheme, other.scheme)) return false;
        if (!std.ascii.eqlIgnoreCase(self.host, other.host)) return false;
        return effectivePort(self.scheme, self.port) == effectivePort(other.scheme, other.port);
    }

    pub fn isLocal(self: Origin) bool {
        return isLocalScheme(self.scheme);
    }

    /// Writes the canonical origin. Default ports are omitted.
    pub fn write(self: Origin, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}://{s}", .{ self.scheme, self.host });
        if (self.port) |port| {
            if (defaultPort(self.scheme) != port) try writer.print(":{d}", .{port});
        }
    }

    /// Allocates the canonical origin string (caller owns the memory).
    pub fn toOwnedString(self: Origin, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        errdefer buffer.deinit();
        // The allocating writer can only fail when the allocator is exhausted.
        self.write(&buffer.writer) catch return error.OutOfMemory;
        return buffer.toOwnedSlice();
    }
};

/// Default port for a scheme, if the scheme defines one.
pub fn defaultPort(scheme: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "ws")) return 80;
    if (std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "wss")) return 443;
    if (std.ascii.eqlIgnoreCase(scheme, "ftp")) return 21;
    return null;
}

/// Schemes served by the embedded WebView itself (never network-bound).
pub fn isLocalScheme(scheme: []const u8) bool {
    const local = [_][]const u8{ "tauri", "asset", "ipc", "about", "data", "blob" };
    for (local) |candidate| {
        if (std.ascii.eqlIgnoreCase(scheme, candidate)) return true;
    }
    return false;
}

/// Schemes that may reach the network; remote-URL capabilities only apply here.
pub fn isRemoteScheme(scheme: []const u8) bool {
    const remote = [_][]const u8{ "http", "https", "ws", "wss", "ftp" };
    for (remote) |candidate| {
        if (std.ascii.eqlIgnoreCase(scheme, candidate)) return true;
    }
    return false;
}

fn effectivePort(scheme: []const u8, port: ?u16) ?u16 {
    return port orelse defaultPort(scheme);
}

/// Parses an absolute URL, rejecting the spoofing vectors described above.
pub fn parse(raw: []const u8) ParseError!Url {
    if (raw.len == 0) return error.InvalidUrl;
    for (raw) |c| {
        if (c <= 0x20 or c == 0x7f) return error.InvalidUrl;
        if (c == '\\') return error.InvalidUrl;
    }
    if (std.mem.findScalar(u8, raw, ':') == null) return error.RelativeUrl;

    const uri = std.Uri.parse(raw) catch |err| switch (err) {
        error.InvalidPort => return error.InvalidPort,
        error.InvalidHostName => return error.InvalidHost,
        error.UnexpectedCharacter, error.InvalidFormat => return if (std.mem.find(u8, raw, "://") != null)
            error.MissingHost
        else if (std.mem.findScalar(u8, raw, ':') == null)
            error.RelativeUrl
        else
            error.InvalidUrl,
    };

    if (uri.user != null or uri.password != null) return error.HasUserInfo;
    if (uri.scheme.len == 0) return error.RelativeUrl;

    const host = if (uri.host) |component| component.percent_encoded else null;
    if (host) |value| {
        if (value.len == 0 or value.len > 253) return error.InvalidHost;
        // Percent-encoded or non-ASCII hosts would need decoding; reject them so
        // the origin is always exactly the bytes that were compared.
        for (value) |c| {
            if (c == '%' or c >= 0x80) return error.InvalidHost;
        }
    }

    if (host == null and isRemoteScheme(uri.scheme)) return error.MissingHost;

    return .{
        .raw = raw,
        .scheme = uri.scheme,
        .host = host,
        .port = uri.port,
        .path = uri.path.percent_encoded,
        .query = if (uri.query) |q| q.percent_encoded else null,
        .fragment = if (uri.fragment) |f| f.percent_encoded else null,
    };
}

/// Parses an absolute URL and extracts its origin.
pub fn parseOrigin(raw: []const u8) ParseError!Origin {
    return (try parse(raw)).origin();
}

/// Same-origin check that returns false on any parse failure (fail closed).
pub fn sameOrigin(a: []const u8, b: []const u8) bool {
    const left = parseOrigin(a) catch return false;
    const right = parseOrigin(b) catch return false;
    return left.eql(right);
}

/// Percent-decodes `input` into a freshly allocated buffer.
pub fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) PercentDecodeError![]u8 {
    var output_len: usize = 0;
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] == '%') {
            if (index + 2 >= input.len) return error.InvalidPercentEncoding;
            _ = hexValue(input[index + 1]) orelse return error.InvalidPercentEncoding;
            _ = hexValue(input[index + 2]) orelse return error.InvalidPercentEncoding;
            index += 3;
        } else {
            index += 1;
        }
        output_len += 1;
    }

    const output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);

    index = 0;
    var out_index: usize = 0;
    while (index < input.len) {
        if (input[index] == '%') {
            const high = hexValue(input[index + 1]).?;
            const low = hexValue(input[index + 2]).?;
            output[out_index] = (high << 4) | low;
            index += 3;
        } else {
            output[out_index] = input[index];
            index += 1;
        }
        out_index += 1;
    }
    return output;
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Matches a remote URL against a capability pattern such as
/// `https://*.example.com/*`. Only network schemes qualify, the fragment is
/// stripped (never sent on the wire), and the match is case-sensitive so a
/// pattern can never be widened by case folding.
pub fn matchesRemotePattern(pattern: []const u8, raw_url: []const u8) bool {
    const url = parse(raw_url) catch return false;
    if (!isRemoteScheme(url.scheme)) return false;
    const without_fragment = if (std.mem.findScalar(u8, raw_url, '#')) |index| raw_url[0..index] else raw_url;
    return glob.matchWith(pattern, without_fragment, .{ .backslash_is_separator = false });
}

/// True when the URL is a network URL a capability may need to allow.
pub fn isRemoteUrl(raw_url: []const u8) bool {
    const url = parse(raw_url) catch return false;
    return isRemoteScheme(url.scheme);
}

const testing = std.testing;

test "url: parses custom schemes and borrowed components" {
    const tauri = try parse("tauri://localhost");
    try testing.expectEqualStrings("tauri", tauri.scheme);
    try testing.expectEqualStrings("localhost", tauri.host.?);
    try testing.expectEqualStrings("", tauri.path);
    try testing.expect(tauri.isLocal());
    try testing.expect(!tauri.isRemote());

    const asset = try parse("asset://localhost/assets/app.js");
    try testing.expectEqualStrings("/assets/app.js", asset.path);
    try testing.expect(asset.schemeIs("ASSET"));

    const web = try parse("https://example.com:8443/a/b?q=1#frag");
    try testing.expectEqualStrings("/a/b", web.path);
    try testing.expectEqualStrings("q=1", web.query.?);
    try testing.expectEqualStrings("frag", web.fragment.?);
    try testing.expectEqual(@as(?u16, 8443), web.port);
}

test "url: origins compare case-insensitively and normalize default ports" {
    try testing.expect((try parseOrigin("http://localhost")).eql(try parseOrigin("http://localhost:80")));
    try testing.expect((try parseOrigin("https://Example.COM")).eql(try parseOrigin("HTTPS://example.com:443")));
    try testing.expect(!(try parseOrigin("http://localhost")).eql(try parseOrigin("https://localhost")));
    try testing.expect(!(try parseOrigin("http://localhost:8080")).eql(try parseOrigin("http://localhost")));
    try testing.expect(!(try parseOrigin("http://localhost")).eql(try parseOrigin("http://127.0.0.1")));
    try testing.expect(!(try parseOrigin("tauri://localhost")).eql(try parseOrigin("http://localhost")));
}

test "url: builtin WebView origins" {
    try testing.expect((try parseOrigin("http://ipc.localhost")).eql(ipc_origin));
    try testing.expect((try parseOrigin("tauri://localhost")).eql(tauri_origin));
    try testing.expect((try parseOrigin("asset://localhost")).eql(asset_origin));
    try testing.expect(!(try parseOrigin("http://ipc.localhost")).eql(tauri_origin));
    try testing.expect((try parseOrigin("http://ipc.localhost:80")).eql(ipc_origin));
}

test "url: userinfo and spoofing vectors are rejected" {
    try testing.expectError(error.HasUserInfo, parse("http://evil.com@localhost"));
    try testing.expectError(error.HasUserInfo, parse("http://user:pass@localhost/x"));
    try testing.expectError(error.InvalidUrl, parse("http://evil.com\\@localhost"));
    try testing.expectError(error.InvalidUrl, parse("http://local\\host"));
    try testing.expectError(error.InvalidHost, parse("http://local%68ost"));
    try testing.expectError(error.InvalidUrl, parse("http://local host"));
    try testing.expectError(error.InvalidUrl, parse("http://local\nhost"));
    try testing.expectError(error.InvalidUrl, parse(""));
}

test "url: schemes and relative inputs fail closed" {
    try testing.expectError(error.RelativeUrl, parse("/just/a/path"));
    try testing.expectError(error.RelativeUrl, parse("just/a/path"));
    try testing.expectError(error.MissingHost, parse("http://"));
    try testing.expectError(error.MissingHost, parse("https:example.com"));
    try testing.expectError(error.InvalidPort, parse("http://localhost:99999"));
    try testing.expectError(error.MissingHost, parseOrigin("about:blank"));
    try testing.expectError(error.InvalidUrl, parse("http://localhost:80\\@evil.com"));
}

test "url: IPv6 hosts keep their brackets and compare correctly" {
    const origin = try parseOrigin("http://[::1]:8080/x");
    try testing.expectEqualStrings("[::1]", origin.host);
    try testing.expectEqual(@as(?u16, 8080), origin.port);
    try testing.expect((try parseOrigin("http://[::1]:8080")).eql(origin));
    try testing.expect(!(try parseOrigin("http://[::1]:9090")).eql(origin));
}

test "url: sameOrigin handles parse failures as non-matching" {
    try testing.expect(sameOrigin("tauri://localhost/a", "tauri://LOCALHOST/b"));
    try testing.expect(!sameOrigin("tauri://localhost", "http://localhost"));
    try testing.expect(!sameOrigin("not a url", "http://localhost"));
    try testing.expect(!sameOrigin("http://localhost", "/relative"));
}

test "url: percent decoding" {
    const allocator = testing.allocator;
    const decoded = try percentDecodeAlloc(allocator, "a%20b%2Fc");
    defer allocator.free(decoded);
    try testing.expectEqualStrings("a b/c", decoded);

    const plain = try percentDecodeAlloc(allocator, "plain");
    defer allocator.free(plain);
    try testing.expectEqualStrings("plain", plain);

    const empty = try percentDecodeAlloc(allocator, "");
    defer allocator.free(empty);
    try testing.expectEqualStrings("", empty);

    try testing.expectError(error.InvalidPercentEncoding, percentDecodeAlloc(allocator, "%"));
    try testing.expectError(error.InvalidPercentEncoding, percentDecodeAlloc(allocator, "%2"));
    try testing.expectError(error.InvalidPercentEncoding, percentDecodeAlloc(allocator, "%zz"));
}

test "url: remote URL patterns only match network schemes" {
    try testing.expect(matchesRemotePattern("https://*.example.com/*", "https://api.example.com/v1"));
    try testing.expect(matchesRemotePattern("https://api.example.com/**", "https://api.example.com/v1/users"));
    try testing.expect(!matchesRemotePattern("https://*.example.com/*", "https://api.example.com/v1/users"));
    try testing.expect(!matchesRemotePattern("https://*.example.com/*", "https://evil.example.org/v1"));
    try testing.expect(!matchesRemotePattern("https://*.example.com/*", "tauri://localhost/v1"));
    try testing.expect(!matchesRemotePattern("**", "javascript:alert(1)"));
    try testing.expect(matchesRemotePattern("wss://socket.example.com/**", "wss://socket.example.com/room/1"));
}

test "url: remote URL detection" {
    try testing.expect(isRemoteUrl("http://localhost:1420/"));
    try testing.expect(isRemoteUrl("wss://example.com"));
    try testing.expect(!isRemoteUrl("tauri://localhost"));
    try testing.expect(!isRemoteUrl("garbage"));
}

test "url: origin formatting omits default ports" {
    const allocator = testing.allocator;
    const plain = try (try parseOrigin("http://localhost:80")).toOwnedString(allocator);
    defer allocator.free(plain);
    try testing.expectEqualStrings("http://localhost", plain);

    const custom = try (try parseOrigin("tauri://localhost")).toOwnedString(allocator);
    defer allocator.free(custom);
    try testing.expectEqualStrings("tauri://localhost", custom);

    const non_default = try (try parseOrigin("https://example.com:8443")).toOwnedString(allocator);
    defer allocator.free(non_default);
    try testing.expectEqualStrings("https://example.com:8443", non_default);
}
