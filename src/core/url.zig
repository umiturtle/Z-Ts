//! Zero-Allocation URL / Origin Parser & Path-Traversal Guard (`src/core/url.zig`).
//!
//! Security boundary shared across `zts_core.Assets`, `zts_bridge` HTTP handlers,
//! WebView custom URI protocols (`tauri://`, `ipc://`, `asset://`), and `zts_tauri` ACL checks.

const std = @import("std");
const testing = std.testing;

pub const UrlError = error{
    MissingScheme,
    InvalidScheme,
    InvalidHost,
    InvalidPort,
    InvalidPercentEncoding,
    NullByteInPath,
    ControlCharInPath,
    PathTraversal,
    BufferTooSmall,
};

/// Zero-allocation borrowed components of a parsed URL (`scheme://host[:port][/path][?query][#frag]`).
pub const ParsedUrl = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
    query: ?[]const u8,
    fragment: ?[]const u8,

    /// Returns the effective port, normalizing standard `http` (`80`) and `https` (`443`).
    pub fn effectivePort(self: ParsedUrl) ?u16 {
        if (self.port) |p| return p;
        if (std.ascii.eqlIgnoreCase(self.scheme, "http") or std.ascii.eqlIgnoreCase(self.scheme, "ws")) return 80;
        if (std.ascii.eqlIgnoreCase(self.scheme, "https") or std.ascii.eqlIgnoreCase(self.scheme, "wss")) return 443;
        return null;
    }

    /// Parses a URL string with zero heap allocations.
    pub fn parse(raw: []const u8) UrlError!ParsedUrl {
        const scheme_sep = std.mem.indexOf(u8, raw, "://") orelse return error.MissingScheme;
        const scheme = raw[0..scheme_sep];
        if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return error.InvalidScheme;
        for (scheme[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
                return error.InvalidScheme;
            }
        }

        var rest = raw[scheme_sep + 3 ..];

        // Detach `#fragment`
        var fragment: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, '#')) |hash_idx| {
            fragment = rest[hash_idx + 1 ..];
            rest = rest[0..hash_idx];
        }

        // Detach `?query`
        var query: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, '?')) |q_idx| {
            query = rest[q_idx + 1 ..];
            rest = rest[0..q_idx];
        }

        // Split authority vs path
        const slash_idx = std.mem.indexOfScalar(u8, rest, '/');
        const authority = if (slash_idx) |idx| rest[0..idx] else rest;
        const path = if (slash_idx) |idx| rest[idx..] else "/";

        var host: []const u8 = authority;
        var port: ?u16 = null;

        if (authority.len > 0 and authority[0] == '[') {
            // IPv6 literal host `[::1]` or `[::1]:5173`
            const close_bracket = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidHost;
            host = authority[0 .. close_bracket + 1];
            const after = authority[close_bracket + 1 ..];
            if (after.len > 0) {
                if (after[0] != ':' or after.len == 1) return error.InvalidPort;
                port = std.fmt.parseInt(u16, after[1..], 10) catch return error.InvalidPort;
            }
        } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon_idx| {
            host = authority[0..colon_idx];
            const port_str = authority[colon_idx + 1 ..];
            if (port_str.len == 0) return error.InvalidPort;
            port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
        }

        return .{
            .scheme = scheme,
            .host = host,
            .port = port,
            .path = path,
            .query = query,
            .fragment = fragment,
        };
    }
};

/// Strict Web Origin equality (`scheme` + ASCII-lowercased `host` + normalized `effectivePort`).
pub fn isSameOrigin(url_a: []const u8, url_b: []const u8) bool {
    const a = ParsedUrl.parse(url_a) catch return false;
    const b = ParsedUrl.parse(url_b) catch return false;
    return std.ascii.eqlIgnoreCase(a.scheme, b.scheme) and
        std.ascii.eqlIgnoreCase(a.host, b.host) and
        a.effectivePort() == b.effectivePort();
}

/// Returns `true` when `origin_or_url` matches a built-in local Tauri WebView origin across
/// macOS/Linux (`tauri://localhost`, `ipc://localhost`, `asset://localhost`) or Windows WebView2
/// (`http://tauri.localhost`, `https://tauri.localhost`, `http://ipc.localhost`, etc.).
pub fn isBuiltInLocalWebViewOrigin(origin_or_url: []const u8) bool {
    const u = ParsedUrl.parse(origin_or_url) catch return false;
    if (std.ascii.eqlIgnoreCase(u.scheme, "tauri") or
        std.ascii.eqlIgnoreCase(u.scheme, "ipc") or
        std.ascii.eqlIgnoreCase(u.scheme, "asset"))
    {
        return u.port == null and std.ascii.eqlIgnoreCase(u.host, "localhost");
    }
    if (std.ascii.eqlIgnoreCase(u.scheme, "http") or std.ascii.eqlIgnoreCase(u.scheme, "https")) {
        return u.port == null and (std.ascii.eqlIgnoreCase(u.host, "tauri.localhost") or
            std.ascii.eqlIgnoreCase(u.host, "ipc.localhost") or
            std.ascii.eqlIgnoreCase(u.host, "asset.localhost"));
    }
    return false;
}

/// Percent-decodes the path component of a request target (automatically stripping `?query` and `#frag`),
/// converts Windows `\` separators to `/`, collapses duplicate slashes and `.` segments, resolves
/// in-bounds `..` segments, and **strictly rejects any root escape (`..` above `/`), `%00` NUL bytes,
/// control characters, or invalid `%XX` sequences**.
///
/// Output always begins with `'/'` (e.g. `""` or `"/"` -> `"/"`, `"/a/b/../c.js?v=1"` -> `"/a/c.js"`).
pub fn decodeAndNormalizeUrlPath(out_buf: []u8, raw_target: []const u8) UrlError![]const u8 {
    if (out_buf.len == 0) return error.BufferTooSmall;

    const clean_raw = if (std.mem.indexOfAny(u8, raw_target, "?#")) |idx| raw_target[0..idx] else raw_target;

    // Step 1: Percent-decode into temporary tail or stack scratch (cap at out_buf.len * 2 via small stack + slice)
    var decoded_stack: [4096]u8 = undefined;
    if (clean_raw.len > decoded_stack.len) return error.BufferTooSmall;

    var dec_len: usize = 0;
    var i: usize = 0;
    while (i < clean_raw.len) {
        var byte = clean_raw[i];
        if (byte == '%') {
            if (i + 2 >= clean_raw.len) return error.InvalidPercentEncoding;
            const hi = hexVal(clean_raw[i + 1]) orelse return error.InvalidPercentEncoding;
            const lo = hexVal(clean_raw[i + 2]) orelse return error.InvalidPercentEncoding;
            byte = (@as(u8, hi) << 4) | @as(u8, lo);
            i += 3;
        } else {
            i += 1;
        }

        if (byte == 0) return error.NullByteInPath;
        if (byte < 0x20 or byte == 0x7F) return error.ControlCharInPath;
        if (byte == '\\') byte = '/';

        decoded_stack[dec_len] = byte;
        dec_len += 1;
    }

    // Step 2: Canonicalize path segments in `out_buf` using segment start offsets
    var seg_starts: [256]usize = undefined;
    var depth: usize = 0;
    var out_len: usize = 0;

    var iter = std.mem.tokenizeScalar(u8, decoded_stack[0..dec_len], '/');
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (depth == 0) return error.PathTraversal;
            depth -= 1;
            out_len = seg_starts[depth];
            continue;
        }

        if (depth >= seg_starts.len) return error.BufferTooSmall;
        if (out_len + 1 + seg.len > out_buf.len) return error.BufferTooSmall;

        seg_starts[depth] = out_len;
        depth += 1;
        out_buf[out_len] = '/';
        @memcpy(out_buf[out_len + 1 .. out_len + 1 + seg.len], seg);
        out_len += 1 + seg.len;
    }

    if (out_len == 0) {
        out_buf[0] = '/';
        return out_buf[0..1];
    }
    return out_buf[0..out_len];
}

inline fn hexVal(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "ParsedUrl, Web Origin comparison, and Tauri local origin checks" {
    const u = try ParsedUrl.parse("https://Example.COM:443/app/index.html?token=abc#sec");
    try testing.expectEqualStrings("https", u.scheme);
    try testing.expectEqualStrings("Example.COM", u.host);
    try testing.expectEqual(@as(?u16, 443), u.port);
    try testing.expectEqualStrings("/app/index.html", u.path);
    try testing.expectEqualStrings("token=abc", u.query.?);
    try testing.expectEqualStrings("sec", u.fragment.?);

    try testing.expect(isSameOrigin("https://example.com:443/a", "HTTPS://EXAMPLE.COM/b"));
    try testing.expect(isSameOrigin("http://[::1]:5173/x", "http://[::1]:5173/y"));
    try testing.expect(!isSameOrigin("http://localhost:5173/", "http://localhost:5174/"));
    try testing.expect(!isSameOrigin("http://localhost/", "https://localhost/"));

    try testing.expect(isBuiltInLocalWebViewOrigin("tauri://localhost/index.html"));
    try testing.expect(isBuiltInLocalWebViewOrigin("http://tauri.localhost/api"));
    try testing.expect(!isBuiltInLocalWebViewOrigin("https://evil.example.com"));
    try testing.expect(!isBuiltInLocalWebViewOrigin("http://tauri.localhost:8080/"));
}

test "decodeAndNormalizeUrlPath blocks encoded traversal, backslashes, and NUL injection" {
    var buf: [512]u8 = undefined;

    try testing.expectEqualStrings("/", try decodeAndNormalizeUrlPath(&buf, ""));
    try testing.expectEqualStrings("/", try decodeAndNormalizeUrlPath(&buf, "///./"));
    try testing.expectEqualStrings("/assets/app.js", try decodeAndNormalizeUrlPath(&buf, "/assets/sub/../app.js?v=9#x"));
    try testing.expectEqualStrings("/日本語/file name.png", try decodeAndNormalizeUrlPath(&buf, "/%E6%97%A5%E6%9C%AC%E8%AA%9E/file%20name.png"));

    // Security rejections
    try testing.expectError(error.PathTraversal, decodeAndNormalizeUrlPath(&buf, "/../etc/passwd"));
    try testing.expectError(error.PathTraversal, decodeAndNormalizeUrlPath(&buf, "/assets/../../secret.key"));
    try testing.expectError(error.PathTraversal, decodeAndNormalizeUrlPath(&buf, "/%2e%2e/%2e%2e/etc/shadow"));
    try testing.expectError(error.PathTraversal, decodeAndNormalizeUrlPath(&buf, "/assets%5c..%5c..%5cwin.ini"));
    try testing.expectError(error.NullByteInPath, decodeAndNormalizeUrlPath(&buf, "/index.html%00.png"));
    try testing.expectError(error.InvalidPercentEncoding, decodeAndNormalizeUrlPath(&buf, "/bad%2G"));
}
