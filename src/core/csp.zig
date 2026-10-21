//! Content-Security-Policy helpers: nonces, inline-script hashes, header
//! assembly and `<head>` injection.
//!
//! Linux WebKit2GTK frequently ignores CSP delivered via HTTP headers when the
//! page is served from a custom scheme, so Z-Ts injects the policy as a `<meta>`
//! tag (or relies on a nonce/hash allow-list) during HTML post-processing. This
//! module keeps that rewriting in one place:
//!
//! - 128-bit random nonce (CSP §6.1 recommends at least 128 bits of entropy)
//! - `'sha256-<base64>'` source expressions for static inline scripts
//! - nonce placeholder replacement that cannot inject attributes
//! - `<head>` snippet injection that works even for fragments without `<head>`

const std = @import("std");

const Writer = std.Io.Writer;

/// Writer failure merged with CSP validation failures.
const NonceWriteError = error{InvalidNonce} || Writer.Error;
const PolicyWriteError = error{ InvalidDirective, InvalidSource } || Writer.Error;

/// Nonce entropy in bytes (128 bits).
pub const nonce_bytes = 16;
/// Base64 length of a nonce (no padding is needed because 16 % 3 == 1, but
/// standard padded base64 is used for compatibility with CSP tooling).
pub const nonce_encoded_len = std.base64.standard.Encoder.calcSize(nonce_bytes);

/// A cryptographically random CSP nonce.
pub const Nonce = struct {
    bytes: [nonce_bytes]u8,

    /// Draws a fresh nonce from the platform CSPRNG (`Io.randomSecure`).
    pub fn random(io: std.Io) !Nonce {
        var bytes: [nonce_bytes]u8 = undefined;
        try io.randomSecure(&bytes);
        return .{ .bytes = bytes };
    }

    pub fn fromBytes(bytes: [nonce_bytes]u8) Nonce {
        return .{ .bytes = bytes };
    }

    /// Encodes into `buf` and returns the borrowed base64 slice.
    pub fn encode(self: Nonce, buf: *[nonce_encoded_len]u8) []const u8 {
        return std.base64.standard.Encoder.encode(buf, &self.bytes);
    }

    pub fn write(self: Nonce, writer: *Writer) Writer.Error!void {
        var buf: [nonce_encoded_len]u8 = undefined;
        try writer.writeAll(self.encode(&buf));
    }
};

/// Writes `'nonce-<base64>'` as a CSP source expression.
pub fn writeNonceSource(writer: *Writer, nonce_base64: []const u8) NonceWriteError!void {
    try validateNonce(nonce_base64);
    try writer.writeAll("'nonce-");
    try writer.writeAll(nonce_base64);
    try writer.writeByte('\'');
}

/// Writes `'sha256-<base64(sha256(code))>'` as a CSP source expression.
pub fn writeHashSource(writer: *Writer, code: []const u8) Writer.Error!void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(code, &digest, .{});
    var encoded: [std.base64.standard.Encoder.calcSize(digest.len)]u8 = undefined;
    const base64 = std.base64.standard.Encoder.encode(&encoded, &digest);
    try writer.writeAll("'sha256-");
    try writer.writeAll(base64);
    try writer.writeByte('\'');
}

/// Allocates the `'sha256-…'` source expression for `code`.
pub fn hashSourceAlloc(allocator: std.mem.Allocator, code: []const u8) error{OutOfMemory}![]u8 {
    var buffer = Writer.Allocating.init(allocator);
    defer buffer.deinit();
    writeHashSource(&buffer.writer, code) catch return error.OutOfMemory;
    return buffer.toOwnedSlice();
}

/// A single CSP directive, e.g. `script-src 'self' 'nonce-…'`.
pub const Directive = struct {
    name: []const u8,
    sources: []const []const u8 = &.{},
};

/// An ordered set of directives serialized as a CSP header value.
pub const Policy = struct {
    directives: []const Directive = &.{},
    /// Emit `Content-Security-Policy-Report-Only` instead.
    report_only: bool = false,

    pub fn headerName(self: Policy) []const u8 {
        return if (self.report_only)
            "Content-Security-Policy-Report-Only"
        else
            "Content-Security-Policy";
    }

    /// Writes the policy value (`directive source …; directive …`).
    pub fn write(self: Policy, writer: *Writer) PolicyWriteError!void {
        for (self.directives, 0..) |directive, index| {
            try validateDirectiveName(directive.name);
            if (index != 0) try writer.writeAll("; ");
            try writer.writeAll(directive.name);
            for (directive.sources) |source| {
                try validateSource(source);
                try writer.writeByte(' ');
                try writer.writeAll(source);
            }
        }
    }

    /// Allocates the serialized policy value (caller owns the memory).
    pub fn toOwnedString(
        self: Policy,
        allocator: std.mem.Allocator,
    ) error{ OutOfMemory, InvalidDirective, InvalidSource }![]u8 {
        var buffer = Writer.Allocating.init(allocator);
        defer buffer.deinit();
        self.write(&buffer.writer) catch |err| switch (err) {
            error.InvalidDirective => return error.InvalidDirective,
            error.InvalidSource => return error.InvalidSource,
            error.WriteFailed => return error.OutOfMemory,
        };
        return buffer.toOwnedSlice();
    }
};

/// Baseline policy for a Z-Ts window with an injected bootstrap script.
pub fn writeDefaultPolicy(
    writer: *Writer,
    nonce_base64: []const u8,
) NonceWriteError!void {
    try validateNonce(nonce_base64);
    try writer.writeAll("default-src 'self'; script-src 'self' 'nonce-");
    try writer.writeAll(nonce_base64);
    try writer.writeAll(
        "'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: asset:; " ++
            "font-src 'self' data:; media-src 'self' data: blob:; " ++
            "connect-src 'self' ipc: http://ipc.localhost tauri: asset:; " ++
            "object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
    );
}

fn validateNonce(nonce_base64: []const u8) error{InvalidNonce}!void {
    if (nonce_base64.len < 16 or nonce_base64.len > 128) return error.InvalidNonce;
    for (nonce_base64) |c| {
        const allowed = std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=' or c == '-' or c == '_';
        if (!allowed) return error.InvalidNonce;
    }
}

fn validateDirectiveName(name: []const u8) error{InvalidDirective}!void {
    if (name.len == 0 or name.len > 64) return error.InvalidDirective;
    for (name) |c| {
        const allowed = std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-';
        if (!allowed) return error.InvalidDirective;
    }
}

fn validateSource(source: []const u8) error{InvalidSource}!void {
    if (source.len == 0 or source.len > 2048) return error.InvalidSource;
    for (source) |c| {
        // `;` would start a new directive, CR/LF would split the header.
        if (c == ';' or c < 0x20 or c == 0x7f) return error.InvalidSource;
    }
}

/// Replaces every occurrence of `needle` with `replacement`.
pub fn replaceAll(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
) error{ OutOfMemory, InvalidArgument }![]u8 {
    if (needle.len == 0) return error.InvalidArgument;

    var buffer = Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var rest = haystack;
    while (std.mem.find(u8, rest, needle)) |index| {
        buffer.writer.writeAll(rest[0..index]) catch return error.OutOfMemory;
        buffer.writer.writeAll(replacement) catch return error.OutOfMemory;
        rest = rest[index + needle.len ..];
    }
    buffer.writer.writeAll(rest) catch return error.OutOfMemory;
    return buffer.toOwnedSlice();
}

/// Inserts `snippet` into the document's `<head>`.
///
/// `</head>` (case-insensitive) is preferred; otherwise the opening `<head …>`
/// tag is used; if the document is a fragment without `<head>`, the snippet is
/// prepended so the script still runs before any other markup.
pub fn injectIntoHead(
    allocator: std.mem.Allocator,
    html: []const u8,
    snippet: []const u8,
) error{OutOfMemory}![]u8 {
    var insert_at: usize = undefined;
    if (findIgnoreCase(html, "</head")) |index| {
        insert_at = index;
    } else if (findHeadOpenEnd(html)) |index| {
        insert_at = index;
    } else {
        insert_at = 0;
    }

    var buffer = Writer.Allocating.init(allocator);
    defer buffer.deinit();
    buffer.writer.writeAll(html[0..insert_at]) catch return error.OutOfMemory;
    buffer.writer.writeAll(snippet) catch return error.OutOfMemory;
    buffer.writer.writeAll(html[insert_at..]) catch return error.OutOfMemory;
    return buffer.toOwnedSlice();
}

/// Builds `<script nonce="…">body</script>` and injects it into `<head>`.
pub fn injectScript(
    allocator: std.mem.Allocator,
    html: []const u8,
    body: []const u8,
    nonce_base64: []const u8,
) error{ OutOfMemory, InvalidNonce, UnsafeScriptBody }![]u8 {
    try validateNonce(nonce_base64);
    // A literal `</script` would terminate the element early and turn the rest
    // of the body into markup.
    if (findIgnoreCase(body, "</script") != null) return error.UnsafeScriptBody;

    var buffer = Writer.Allocating.init(allocator);
    defer buffer.deinit();
    buffer.writer.print("<script nonce=\"{s}\">", .{nonce_base64}) catch return error.OutOfMemory;
    buffer.writer.writeAll(body) catch return error.OutOfMemory;
    buffer.writer.writeAll("</script>") catch return error.OutOfMemory;
    return injectIntoHead(allocator, html, buffer.written());
}

fn findIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return index;
    }
    return null;
}

/// Returns the index just past `<head …>` (opening tag only).
fn findHeadOpenEnd(html: []const u8) ?usize {
    var search_from: usize = 0;
    while (findIgnoreCase(html[search_from..], "<head")) |relative| {
        const start = search_from + relative;
        const after = start + "<head".len;
        if (after >= html.len) return null;
        const boundary = html[after];
        if (boundary == '>') return after + 1;
        if (boundary == ' ' or boundary == '\t' or boundary == '\r' or boundary == '\n' or boundary == '/') {
            const close = std.mem.findScalarPos(u8, html, after, '>') orelse return null;
            return close + 1;
        }
        search_from = after;
    }
    return null;
}

const testing = std.testing;

test "csp: nonce encodes to base64 and round-trips" {
    const nonce = Nonce.fromBytes(@splat(0));
    var buf: [nonce_encoded_len]u8 = undefined;
    const encoded = nonce.encode(&buf);
    try testing.expectEqual(@as(usize, 24), encoded.len);
    try testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAA==", encoded);

    var decoded: [nonce_bytes]u8 = undefined;
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    try testing.expectEqual(@as(usize, nonce_bytes), decoded_len);
    try std.base64.standard.Decoder.decode(&decoded, encoded);
    try testing.expectEqualSlices(u8, &nonce.bytes, &decoded);
}

test "csp: random nonces differ and have 128 bits of entropy" {
    const first = try Nonce.random(testing.io);
    const second = try Nonce.random(testing.io);
    try testing.expect(!std.mem.eql(u8, &first.bytes, &second.bytes));
    try testing.expectEqual(@as(usize, nonce_bytes), first.bytes.len);
}

test "csp: nonce source expression" {
    var buf: [64]u8 = undefined;
    var writer = Writer.fixed(&buf);
    try writeNonceSource(&writer, "AAAAAAAAAAAAAAAAAAAAAA==");
    try testing.expectEqualStrings("'nonce-AAAAAAAAAAAAAAAAAAAAAA=='", writer.buffered());

    var small: [8]u8 = undefined;
    var failing = Writer.fixed(&small);
    try testing.expectError(error.InvalidNonce, writeNonceSource(&failing, "short"));
    try testing.expectError(error.InvalidNonce, writeNonceSource(&failing, "bad'nonce'value'here'"));
}

test "csp: sha256 source expression matches the RFC reference vector" {
    const allocator = testing.allocator;
    const source = try hashSourceAlloc(allocator, "abc");
    defer allocator.free(source);
    // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    try testing.expectEqualStrings("'sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0='", source);
    try testing.expectEqual(@as(usize, 53), source.len);
}

test "csp: policy serialization, header name and report-only mode" {
    const allocator = testing.allocator;
    const script_sources = [_][]const u8{ "'self'", "'nonce-abc'" };
    const directives = [_]Directive{
        .{ .name = "default-src", .sources = &.{"'self'"} },
        .{ .name = "script-src", .sources = &script_sources },
    };
    const policy = Policy{ .directives = &directives };
    try testing.expectEqualStrings("Content-Security-Policy", policy.headerName());

    const serialized = try policy.toOwnedString(allocator);
    defer allocator.free(serialized);
    try testing.expectEqualStrings("default-src 'self'; script-src 'self' 'nonce-abc'", serialized);

    const report_only = Policy{ .directives = &directives, .report_only = true };
    try testing.expectEqualStrings("Content-Security-Policy-Report-Only", report_only.headerName());
}

test "csp: directive and source injection is rejected" {
    const allocator = testing.allocator;

    const bad_name = [_]Directive{.{ .name = "script-src; evil", .sources = &.{"'self'"} }};
    try testing.expectError(error.InvalidDirective, (Policy{ .directives = &bad_name }).toOwnedString(allocator));

    const empty_name = [_]Directive{.{ .name = "", .sources = &.{"'self'"} }};
    try testing.expectError(error.InvalidDirective, (Policy{ .directives = &empty_name }).toOwnedString(allocator));

    const bad_source = [_]Directive{.{ .name = "script-src", .sources = &.{"'self'; default-src *"} }};
    try testing.expectError(error.InvalidSource, (Policy{ .directives = &bad_source }).toOwnedString(allocator));

    const newline_source = [_]Directive{.{ .name = "script-src", .sources = &.{"'self'\r\nX-Evil: 1"} }};
    try testing.expectError(error.InvalidSource, (Policy{ .directives = &newline_source }).toOwnedString(allocator));
}

test "csp: default policy embeds the nonce and locks down the document" {
    var buf: [1024]u8 = undefined;
    var writer = Writer.fixed(&buf);
    try writeDefaultPolicy(&writer, "AAAAAAAAAAAAAAAAAAAAAA==");
    const policy = writer.buffered();
    try testing.expect(std.mem.find(u8, policy, "'nonce-AAAAAAAAAAAAAAAAAAAAAA=='") != null);
    try testing.expect(std.mem.find(u8, policy, "object-src 'none'") != null);
    try testing.expect(std.mem.find(u8, policy, "http://ipc.localhost") != null);

    var small: [8]u8 = undefined;
    var failing = Writer.fixed(&small);
    try testing.expectError(error.InvalidNonce, writeDefaultPolicy(&failing, "nope"));
}

test "csp: injectIntoHead inserts before the closing tag" {
    const allocator = testing.allocator;
    const html = "<!doctype html><html><head><title>x</title></HEAD><body></body></html>";
    const result = try injectIntoHead(allocator, html, "<meta charset=\"utf-8\">");
    defer allocator.free(result);
    try testing.expectEqualStrings(
        "<!doctype html><html><head><title>x</title><meta charset=\"utf-8\"></HEAD><body></body></html>",
        result,
    );
}

test "csp: injectIntoHead supports attributes and fragments" {
    const allocator = testing.allocator;
    const with_attributes = try injectIntoHead(allocator, "<html><head lang=\"ja\"><script src=x></script></head></html>", "<meta x>");
    defer allocator.free(with_attributes);
    try testing.expectEqualStrings(
        "<html><head lang=\"ja\"><script src=x></script><meta x></head></html>",
        with_attributes,
    );

    const fragment = try injectIntoHead(allocator, "<div>hello</div>", "<style>p{}</style>");
    defer allocator.free(fragment);
    try testing.expectEqualStrings("<style>p{}</style><div>hello</div>", fragment);
}

test "csp: injectScript writes a nonce attribute and rejects injection" {
    const allocator = testing.allocator;
    const html = "<html><head></head><body></body></html>";
    const nonce = "AAAAAAAAAAAAAAAAAAAAAA==";

    const result = try injectScript(allocator, html, "window.__ZTS__ = 1;", nonce);
    defer allocator.free(result);
    try testing.expectEqualStrings(
        "<html><head><script nonce=\"AAAAAAAAAAAAAAAAAAAAAA==\">window.__ZTS__ = 1;</script></head><body></body></html>",
        result,
    );

    try testing.expectError(error.InvalidNonce, injectScript(allocator, html, "x", "bad nonce"));
    try testing.expectError(
        error.UnsafeScriptBody,
        injectScript(allocator, html, "var x = '</script><img src=x>';", nonce),
    );
}

test "csp: replaceAll replaces every placeholder occurrence" {
    const allocator = testing.allocator;
    const result = try replaceAll(
        allocator,
        "<script nonce=\"__ZTS_CSP_NONCE__\"></script><style nonce=\"__ZTS_CSP_NONCE__\"></style>",
        "__ZTS_CSP_NONCE__",
        "abc123",
    );
    defer allocator.free(result);
    try testing.expectEqualStrings(
        "<script nonce=\"abc123\"></script><style nonce=\"abc123\"></style>",
        result,
    );

    const untouched = try replaceAll(allocator, "no placeholder", "__ZTS_CSP_NONCE__", "x");
    defer allocator.free(untouched);
    try testing.expectEqualStrings("no placeholder", untouched);

    try testing.expectError(error.InvalidArgument, replaceAll(allocator, "abc", "", "x"));
}
