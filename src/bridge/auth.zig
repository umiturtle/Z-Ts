//! Cryptographic Session Tokens & Triple-Layer CSRF Defense (`src/bridge/auth.zig`).
//!
//! Protects `POST /__zts_ipc__/<cmd>` and `GET /__zts_events__` against local cross-site
//! attacks (DNS rebinding, malicious browser tabs, `<form>` CSRF, `<script>` hijacking):
//! 1. **256-bit `HttpOnly; SameSite=Strict` Session Cookie** (`__zts_session=<64 hex>`)
//! 2. **256-bit Injected Header Token** (`Tauri-Invoke-Key` / `X-Zts-Invoke-Key`)
//! 3. **Strict Web `Origin` Verification** (`same_host` matching `Host`, or explicit allowlist)
//!
//! All secret comparisons run in strict constant time (`constantTimeEql`).

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

/// Entropy of the per-run session token, in bytes. 32 bytes (256 bits) makes guessing infeasible and
/// still fits one cookie value comfortably.
pub const token_bytes = 32; // 256-bit entropy
/// Length of the hex-encoded session token — 64 characters for 256 bits of entropy, which is what
/// `Config.invoke_key` holds.
pub const token_hex_len = token_bytes * 2; // 64 hex chars
/// Name of the session cookie. `__Host-`/`__Secure-` prefixes are avoided on purpose: the bridge is
/// served over plain `http://127.0.0.1`, where a browser would silently drop a `Secure` cookie.
pub const cookie_name = "__zts_session";

/// Which browser origins may call the bridge. The default `.same_host` compares the `Origin`
/// authority with the request's `Host`, which blocks a malicious tab on another origin while still
/// working behind a port-forwarding proxy; `.allow_list` adds explicit dev-server origins.
pub const OriginPolicy = union(enum) {
    /// Requires `Origin` header authority (`host[:port]`) to match the request `Host` header
    /// case-insensitively. Works seamlessly on `http://127.0.0.1:<port>`, `http://localhost:<port>`,
    /// IPv6 `[::1]:<port>`, AND cloud reverse proxies (`https://<port>-<id>.e2b.app`) while
    /// strictly blocking cross-origin tabs (`https://evil.example`, `null`, or missing `Origin`).
    same_host,
    /// Accepts `same_host` OR any exact origin listed here (e.g. `"http://localhost:5173"` for HMR).
    allow_list: []const []const u8,
};

/// Constant-time byte comparison that leaks neither content nor early-mismatch position.
pub fn constantTimeEql(expected: []const u8, candidate: []const u8) bool {
    if (candidate.len != expected.len) return false;
    var diff: u8 = 0;
    for (expected, candidate) |a, b| {
        diff |= a ^ b;
    }
    return diff == 0;
}

/// Generates a 256-bit random token encoded as 64 lowercase hexadecimal ASCII characters.
pub fn generateTokenHex(io: Io) [token_hex_len]u8 {
    var raw: [token_bytes]u8 = undefined;
    io.randomSecure(&raw) catch {
        io.random(&raw);
    };
    const hex_chars = "0123456789abcdef";
    var out: [token_hex_len]u8 = undefined;
    for (raw, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    @memset(&raw, 0);
    return out;
}

/// Extracts a named cookie value from a raw `Cookie:` header string.
pub fn extractCookieValue(cookie_header: []const u8, target_name: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, cookie_header, ';');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len <= target_name.len + 1) continue;
        if (std.mem.startsWith(u8, trimmed, target_name) and trimmed[target_name.len] == '=') {
            const raw_val = std.mem.trim(u8, trimmed[target_name.len + 1 ..], " \t\"");
            return raw_val;
        }
    }
    return null;
}

/// Extracts a raw query parameter value (`?key=...&foo=bar`) without allocating.
pub fn extractQueryParam(raw_target: []const u8, param_name: []const u8) ?[]const u8 {
    const q_idx = std.mem.indexOfScalar(u8, raw_target, '?') orelse return null;
    const query = raw_target[q_idx + 1 ..];
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len <= param_name.len + 1) continue;
        if (std.mem.startsWith(u8, pair, param_name) and pair[param_name.len] == '=') {
            return pair[param_name.len + 1 ..];
        }
    }
    return null;
}

/// Extracts the authority (`host[:port]`) portion from an HTTP `Origin` header (`http://...` or `https://...`).
/// Rejects `null`, `file://`, malformed schemes, userinfo (`@`), or trailing paths.
pub fn extractOriginAuthority(origin: []const u8) ?[]const u8 {
    const rest = if (std.ascii.startsWithIgnoreCase(origin, "http://"))
        origin["http://".len..]
    else if (std.ascii.startsWithIgnoreCase(origin, "https://"))
        origin["https://".len..]
    else
        return null;

    if (rest.len == 0) return null;
    if (std.mem.indexOfAny(u8, rest, "/?#@ \t\r\n") != null) return null;
    return rest;
}

/// Validates `origin_header` against `host_header` under `policy`.
pub fn isOriginAllowed(policy: OriginPolicy, origin_header: ?[]const u8, host_header: ?[]const u8) bool {
    const origin = std.mem.trim(u8, origin_header orelse return false, " \t");
    if (origin.len == 0 or std.ascii.eqlIgnoreCase(origin, "null")) return false;

    if (extractOriginAuthority(origin)) |origin_auth| {
        if (host_header) |raw_host| {
            const host = std.mem.trim(u8, raw_host, " \t");
            if (host.len > 0 and std.ascii.eqlIgnoreCase(origin_auth, host)) {
                return true;
            }
        }
    }

    switch (policy) {
        .same_host => return false,
        .allow_list => |allowed| {
            for (allowed) |entry| {
                if (std.ascii.eqlIgnoreCase(origin, entry)) return true;
            }
            return false;
        },
    }
}

/// Percent-decodes a URL command segment (e.g. `"plugin%3Awindow%7Cset_title"` -> `"plugin:window|set_title"`)
/// into caller buffer `out` with zero heap allocation. Rejects NUL bytes (`%00`) and truncated `%XX`.
pub fn percentDecodeSegment(out: []u8, raw: []const u8) error{ InvalidEncoding, BufferTooSmall }![]const u8 {
    var r: usize = 0;
    var w: usize = 0;
    while (r < raw.len) {
        if (w >= out.len) return error.BufferTooSmall;
        if (raw[r] == '%') {
            if (r + 2 >= raw.len) return error.InvalidEncoding;
            const hi = std.fmt.charToDigit(raw[r + 1], 16) catch return error.InvalidEncoding;
            const lo = std.fmt.charToDigit(raw[r + 2], 16) catch return error.InvalidEncoding;
            const decoded: u8 = (hi << 4) | lo;
            if (decoded == 0) return error.InvalidEncoding;
            out[w] = decoded;
            w += 1;
            r += 3;
        } else {
            if (raw[r] == 0) return error.InvalidEncoding;
            out[w] = raw[r];
            w += 1;
            r += 1;
        }
    }
    return out[0..w];
}

/// Immutable per-server cryptographic credentials initialized at `BridgeServer.start`.
pub const SecurityState = struct {
    /// Hex token the browser session cookie must carry.
    session_token: [token_hex_len]u8,
    /// Hex token every `ipc://` request must present.
    invoke_key: [token_hex_len]u8,
    /// Which `Origin` values may connect at all.
    origin_policy: OriginPolicy = .same_host,

    /// Generates both tokens from the OS RNG.
    pub fn initRandom(io: Io, origin_policy: OriginPolicy) SecurityState {
        return .{
            .session_token = generateTokenHex(io),
            .invoke_key = generateTokenHex(io),
            .origin_policy = origin_policy,
        };
    }

    /// Formats the `Set-Cookie` value (`HttpOnly; SameSite=Strict`) into `buf`.
    pub fn setCookieHeaderValue(self: *const SecurityState, buf: *[160]u8) []const u8 {
        return std.fmt.bufPrint(
            buf,
            "{s}={s}; Path=/; HttpOnly; SameSite=Strict",
            .{ cookie_name, self.session_token },
        ) catch unreachable;
    }

    /// Constant-time check of the session cookie.
    pub fn hasValidSessionCookie(self: *const SecurityState, cookie_header: ?[]const u8) bool {
        const hdr = cookie_header orelse return false;
        const val = extractCookieValue(hdr, cookie_name) orelse return false;
        return constantTimeEql(&self.session_token, val);
    }

    /// Triple-check for `POST /__zts_ipc__/<cmd>`:
    /// 1. Valid `Origin` matching `Host` (or `allow_list`)
    /// 2. Valid `HttpOnly; SameSite=Strict` session cookie (`__zts_session`)
    /// 3. Valid `Tauri-Invoke-Key` (or `X-Zts-Invoke-Key`) header
    pub fn verifyIpcRequest(
        self: *const SecurityState,
        origin_header: ?[]const u8,
        host_header: ?[]const u8,
        cookie_header: ?[]const u8,
        invoke_key_header: ?[]const u8,
    ) bool {
        const origin_ok = isOriginAllowed(self.origin_policy, origin_header, host_header);
        const cookie_ok = self.hasValidSessionCookie(cookie_header);
        const key_ok = if (invoke_key_header) |k|
            constantTimeEql(&self.invoke_key, std.mem.trim(u8, k, " \t"))
        else
            false;
        return origin_ok and cookie_ok and key_ok;
    }

    /// Verification for `GET /__zts_events__` (SSE):
    /// Requires BOTH the `HttpOnly` session cookie AND the invoke key (`?key=...` or header),
    /// plus `Origin` validation whenever the browser sends an `Origin` header.
    pub fn verifySseRequest(
        self: *const SecurityState,
        raw_target: []const u8,
        origin_header: ?[]const u8,
        host_header: ?[]const u8,
        cookie_header: ?[]const u8,
        invoke_key_header: ?[]const u8,
    ) bool {
        if (origin_header != null and !isOriginAllowed(self.origin_policy, origin_header, host_header)) {
            return false;
        }
        const cookie_ok = self.hasValidSessionCookie(cookie_header);
        const key_candidate = invoke_key_header orelse extractQueryParam(raw_target, "key") orelse return false;
        const key_ok = constantTimeEql(&self.invoke_key, std.mem.trim(u8, key_candidate, " \t"));
        return cookie_ok and key_ok;
    }
};

test "Triple CSRF guard validates legitimate requests and blocks every missing/tampered vector" {
    const sec = SecurityState.initRandom(testing.io, .{
        .allow_list = &.{"http://localhost:5173"},
    });

    var cookie_hdr_buf: [128]u8 = undefined;
    const valid_cookie = try std.fmt.bufPrint(&cookie_hdr_buf, "theme=dark; {s}={s}; lang=ja", .{
        cookie_name,
        sec.session_token,
    });

    // Legitimate same-host & proxy host & allowlisted dev origin succeed
    try testing.expect(sec.verifyIpcRequest("http://127.0.0.1:49152", "127.0.0.1:49152", valid_cookie, &sec.invoke_key));
    try testing.expect(sec.verifyIpcRequest("https://3000-sandbox.e2b.app", "3000-sandbox.e2b.app", valid_cookie, &sec.invoke_key));
    try testing.expect(sec.verifyIpcRequest("http://localhost:5173", "127.0.0.1:49152", valid_cookie, &sec.invoke_key));

    // Any missing or forged pillar MUST fail!
    try testing.expect(!sec.verifyIpcRequest(null, "127.0.0.1:49152", valid_cookie, &sec.invoke_key));
    try testing.expect(!sec.verifyIpcRequest("null", "127.0.0.1:49152", valid_cookie, &sec.invoke_key));
    try testing.expect(!sec.verifyIpcRequest("https://evil.example", "127.0.0.1:49152", valid_cookie, &sec.invoke_key));
    try testing.expect(!sec.verifyIpcRequest("http://127.0.0.1:49152", "127.0.0.1:49152", null, &sec.invoke_key));
    try testing.expect(!sec.verifyIpcRequest("http://127.0.0.1:49152", "127.0.0.1:49152", valid_cookie, null));

    // Percent-decoding preserves namespaced commands & rejects NUL injection
    var cmd_buf: [128]u8 = undefined;
    try testing.expectEqualStrings("plugin:window|set_title", try percentDecodeSegment(&cmd_buf, "plugin%3Awindow%7Cset_title"));
    try testing.expectError(error.InvalidEncoding, percentDecodeSegment(&cmd_buf, "bad%00cmd"));
}
