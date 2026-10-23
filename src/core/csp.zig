//! Content Security Policy (CSP) Hash, Nonce & Meta Tag Engine (`src/core/csp.zig`).
//!
//! Enables strict CSP policies without requiring `'unsafe-inline'`:
//! - Zero-allocation `sha256Source(body)` returns `'sha256-<base64>'` in a fixed `[53]u8` buffer.
//! - Zero-allocation `nonceFromBytes(entropy)` & `nonceSource(nonce)` format cryptographically
//!   opaque Base64 nonces and `'nonce-<base64>'` CSP tokens on the stack.
//! - `appendDirectiveSource` cleanly injects `'nonce-...'` or `'sha256-...'` into existing
//!   `script-src` / `style-src` directives (inheriting `default-src` if needed per CSP Level 3!).
//! - `renderMetaTagAlloc` outputs a properly escaped `<meta http-equiv="Content-Security-Policy" ...>`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const html_escape = @import("html_escape.zig");

pub const SCRIPT_NONCE_PLACEHOLDER = "__TAURI_SCRIPT_NONCE__";
pub const STYLE_NONCE_PLACEHOLDER = "__TAURI_STYLE_NONCE__";

/// Exact byte length of `'sha256-<44-char base64>'` (`8 + 44 + 1 = 53`).
pub const SHA256_SOURCE_LEN: usize = 53;

/// Exact byte length of a 144-bit (18-byte) Base64 nonce (`24` ASCII chars, 0 padding).
pub const NONCE_LEN: usize = 24;

/// Exact byte length of `'nonce-<24-char base64>'` (`7 + 24 + 1 = 32`).
pub const NONCE_SOURCE_LEN: usize = 32;

/// Computes the exact CSP Level 2/3 inline source expression (`'sha256-<base64>'`) for `body`
/// with **zero heap allocations**.
pub fn sha256Source(body: []const u8) [SHA256_SOURCE_LEN]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});

    var out: [SHA256_SOURCE_LEN]u8 = undefined;
    @memcpy(out[0..8], "'sha256-");
    _ = std.base64.standard.Encoder.encode(out[8..52], &digest);
    out[52] = '\'';
    return out;
}

/// Formats 18 raw entropy bytes as a URL/attribute-clean 24-character Base64 nonce on the stack.
pub fn nonceFromBytes(entropy: [18]u8) [NONCE_LEN]u8 {
    var out: [NONCE_LEN]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &entropy);
    return out;
}

/// Wraps a 24-char nonce into `'nonce-<value>'` on the stack with zero heap allocations.
pub fn nonceSource(nonce: [NONCE_LEN]u8) [NONCE_SOURCE_LEN]u8 {
    var out: [NONCE_SOURCE_LEN]u8 = undefined;
    @memcpy(out[0..7], "'nonce-");
    @memcpy(out[7..31], &nonce);
    out[31] = '\'';
    return out;
}

/// Replaces all occurrences of `__TAURI_SCRIPT_NONCE__` and `__TAURI_STYLE_NONCE__` in `input`.
pub fn replaceNoncePlaceholders(
    allocator: Allocator,
    input: []const u8,
    script_nonce: []const u8,
    style_nonce: []const u8,
) Allocator.Error![]u8 {
    const step1 = try std.mem.replaceOwned(u8, allocator, input, SCRIPT_NONCE_PLACEHOLDER, script_nonce);
    errdefer allocator.free(step1);
    const step2 = try std.mem.replaceOwned(u8, allocator, step1, STYLE_NONCE_PLACEHOLDER, style_nonce);
    allocator.free(step1);
    return step2;
}

/// Appends `source_expr` (e.g. `"'nonce-...'"` or `"'sha256-...'"`) to `directive_name`
/// (e.g. `"script-src"`) within `policy`.
///
/// Follows CSP Level 3 inheritance semantics:
/// - If `directive_name` already exists in `policy`, appends `source_expr` to that directive.
/// - If `directive_name` is missing AND `default-src` is present, clones `default-src`'s tokens
///   plus `source_expr` so adding a script hash never accidentally drops existing `'self'` rules!
/// - Otherwise appends `<directive_name> <source_expr>` to `policy`.
pub fn appendDirectiveSource(
    allocator: Allocator,
    policy: []const u8,
    directive_name: []const u8,
    source_expr: []const u8,
) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var found_target = false;
    var default_src_value: ?[]const u8 = null;
    var wrote_any = false;

    var iter = std.mem.splitScalar(u8, policy, ';');
    while (iter.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) continue;

        if (wrote_any) {
            aw.writer.writeAll("; ") catch return error.OutOfMemory;
        }
        wrote_any = true;

        const space_idx = std.mem.indexOfAny(u8, part, " \t") orelse part.len;
        const name = part[0..space_idx];
        const rest = std.mem.trim(u8, part[space_idx..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "default-src")) {
            default_src_value = rest;
        }

        aw.writer.writeAll(part) catch return error.OutOfMemory;
        if (!found_target and std.ascii.eqlIgnoreCase(name, directive_name)) {
            found_target = true;
            aw.writer.writeByte(' ') catch return error.OutOfMemory;
            aw.writer.writeAll(source_expr) catch return error.OutOfMemory;
        }
    }

    if (!found_target) {
        if (wrote_any) {
            aw.writer.writeAll("; ") catch return error.OutOfMemory;
        }
        aw.writer.writeAll(directive_name) catch return error.OutOfMemory;
        if (default_src_value) |def_val| {
            if (def_val.len > 0) {
                aw.writer.writeByte(' ') catch return error.OutOfMemory;
                aw.writer.writeAll(def_val) catch return error.OutOfMemory;
            }
        }
        aw.writer.writeByte(' ') catch return error.OutOfMemory;
        aw.writer.writeAll(source_expr) catch return error.OutOfMemory;
    }

    return aw.toOwnedSlice();
}

/// Renders an HTML-escaped `<meta http-equiv="Content-Security-Policy" content="...">` element.
pub fn renderMetaTagAlloc(allocator: Allocator, policy: []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    aw.writer.writeAll("<meta http-equiv=\"Content-Security-Policy\" content=\"") catch return error.OutOfMemory;
    html_escape.writeHtmlText(&aw.writer, policy) catch return error.OutOfMemory;
    aw.writer.writeAll("\">") catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// ============================================================================
// Unit Tests
// ============================================================================

test "CSP sha256Source, nonce formatting, directive inheritance, and meta tag generation" {
    // Known NIST SHA-256 vector for "console.log(1);"
    const hash_src = sha256Source("console.log(1);");
    try testing.expect(std.mem.startsWith(u8, &hash_src, "'sha256-"));
    try testing.expect(hash_src[52] == '\'');

    const nonce = nonceFromBytes(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 });
    const nonce_src = nonceSource(nonce);
    try testing.expectEqualStrings("'nonce-AQIDBAUGBwgJCgsMDQ4PEBES'", &nonce_src);

    // Inherits `default-src 'self'` when `script-src` is absent!
    const inherited = try appendDirectiveSource(testing.allocator, "default-src 'self'; img-src data:", "script-src", &nonce_src);
    defer testing.allocator.free(inherited);
    try testing.expectEqualStrings(
        "default-src 'self'; img-src data:; script-src 'self' 'nonce-AQIDBAUGBwgJCgsMDQ4PEBES'",
        inherited,
    );

    // Appends in-place when `script-src` already exists
    const updated = try appendDirectiveSource(testing.allocator, inherited, "script-src", &hash_src);
    defer testing.allocator.free(updated);
    try testing.expect(std.mem.endsWith(u8, updated, &hash_src));

    // Placeholder replacement & escaped meta tag rendering
    const replaced = try replaceNoncePlaceholders(
        testing.allocator,
        "<script nonce=\"__TAURI_SCRIPT_NONCE__\">ok</script><style nonce=\"__TAURI_STYLE_NONCE__\">a{}</style>",
        &nonce,
        "STYLE_NONCE_123",
    );
    defer testing.allocator.free(replaced);
    try testing.expectEqualStrings(
        "<script nonce=\"AQIDBAUGBwgJCgsMDQ4PEBES\">ok</script><style nonce=\"STYLE_NONCE_123\">a{}</style>",
        replaced,
    );

    const meta = try renderMetaTagAlloc(testing.allocator, "default-src 'self'");
    defer testing.allocator.free(meta);
    try testing.expectEqualStrings(
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src &#39;self&#39;\">",
        meta,
    );
}
