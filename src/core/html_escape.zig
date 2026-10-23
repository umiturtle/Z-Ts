//! HTML-Safe JSON String Escaping & `<head>` Initialization Script Injection (`src/core/html_escape.zig`).
//!
//! Provides two security-critical primitives shared across `zts_rpc`, `zts_bridge`, and `zts_tauri`:
//! 1. **Chunk-accelerated JSON string literal serialization** with optional HTML-safe escaping
//!    (`<` -> `\u003c`, `>` -> `\u003e`, `&` -> `\u0026`, `U+2028` -> `\u2028`, `U+2029` -> `\u2029`),
//!    guaranteeing that arbitrary user strings inside `<script>` blocks can NEVER break out via
//!    `</script>`, `<!--`, or legacy JS line terminators (Boundary Case #8).
//! 2. **HTML `<head>` injection** (`injectIntoHead`) that inserts initialization scripts and CSP
//!    `<meta>` tags at the earliest valid point in an HTML document without being fooled by
//!    HTML comments (`<!-- <head> -->`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const hex_digits = "0123456789abcdef";

/// Writes `value` as a double-quoted JSON string literal (`"..."`) to `writer`.
///
/// Scans contiguous runs of safe unescaped bytes and emits them via bulk `writeAll` calls
/// rather than byte-by-byte writes.
/// When `html_safe` is `true`, `<`, `>`, `&`, `U+2028`, and `U+2029` are escaped as `\uXXXX`.
pub fn writeJsonString(writer: *std.Io.Writer, value: []const u8, html_safe: bool) std.Io.Writer.Error!void {
    try writer.writeByte('"');

    var chunk_start: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        const b = value[i];
        if (b < 0x80) {
            const esc: ?[]const u8 = switch (b) {
                '"' => "\\\"",
                '\\' => "\\\\",
                0x08 => "\\b",
                0x0C => "\\f",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                '<' => if (html_safe) "\\u003c" else null,
                '>' => if (html_safe) "\\u003e" else null,
                '&' => if (html_safe) "\\u0026" else null,
                0x00...0x07, 0x0B, 0x0E...0x1F => "", // sentinel handled below
                else => null,
            };

            if (esc) |seq| {
                if (i > chunk_start) try writer.writeAll(value[chunk_start..i]);
                if (seq.len > 0) {
                    try writer.writeAll(seq);
                } else {
                    const ctl = [6]u8{ '\\', 'u', '0', '0', hex_digits[b >> 4], hex_digits[b & 0x0F] };
                    try writer.writeAll(&ctl);
                }
                i += 1;
                chunk_start = i;
                continue;
            }
            i += 1;
        } else {
            // Check U+2028 (E2 80 A8) and U+2029 (E2 80 A9) when html_safe is active
            if (html_safe and b == 0xE2 and i + 2 < value.len and value[i + 1] == 0x80 and
                (value[i + 2] == 0xA8 or value[i + 2] == 0xA9))
            {
                if (i > chunk_start) try writer.writeAll(value[chunk_start..i]);
                try writer.writeAll(if (value[i + 2] == 0xA8) "\\u2028" else "\\u2029");
                i += 3;
                chunk_start = i;
                continue;
            }
            i += 1;
        }
    }

    if (chunk_start < value.len) {
        try writer.writeAll(value[chunk_start..]);
    }
    try writer.writeByte('"');
}

/// Allocates and returns a double-quoted JSON string literal (`"..."`).
pub fn escapeJsonStringAlloc(allocator: Allocator, value: []const u8, html_safe: bool) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeJsonString(&aw.writer, value, html_safe) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Writes `text` with standard HTML entity escaping (`&`, `<`, `>`, `"`, `'`), safe for
/// embedding inside HTML element bodies and double/single-quoted attribute values.
pub fn writeHtmlText(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var chunk_start: usize = 0;
    for (text, 0..) |b, i| {
        const entity: ?[]const u8 = switch (b) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => null,
        };
        if (entity) |ent| {
            if (i > chunk_start) try writer.writeAll(text[chunk_start..i]);
            try writer.writeAll(ent);
            chunk_start = i + 1;
        }
    }
    if (chunk_start < text.len) {
        try writer.writeAll(text[chunk_start..]);
    }
}

/// Allocates and returns HTML-escaped `text`.
pub fn escapeHtmlTextAlloc(allocator: Allocator, text: []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeHtmlText(&aw.writer, text) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Finds the optimal byte offset in `html` to inject early `<meta>` CSP tags and initialization
/// `<script>` blocks so they execute BEFORE any page script or resource load:
/// 1. Immediately after the opening `<head>` / `<head ...>` tag (ignoring HTML comments)
/// 2. Otherwise immediately after the opening `<html>` / `<html ...>` tag
/// 3. Otherwise immediately after `<!DOCTYPE ...>`
/// 4. Otherwise right after any UTF-8 BOM at offset 0.
pub fn findHeadInsertionOffset(html: []const u8) usize {
    var base: usize = 0;
    if (std.mem.startsWith(u8, html, "\xEF\xBB\xBF")) base = 3;

    var after_doctype: ?usize = null;
    var after_html: ?usize = null;

    var i: usize = base;
    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }

        // Skip HTML comments `<!-- ... -->` so `<!-- <head> -->` never misleads injection!
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            if (std.mem.indexOfPos(u8, html, i + 4, "-->")) |end_comment| {
                i = end_comment + 3;
                continue;
            }
            break;
        }

        if (matchOpeningTagEnd(html, i, "head")) |end_idx| {
            return end_idx;
        }
        if (after_html == null) {
            if (matchOpeningTagEnd(html, i, "html")) |end_idx| {
                after_html = end_idx;
            }
        }
        if (after_doctype == null) {
            if (matchOpeningTagEnd(html, i, "!doctype")) |end_idx| {
                after_doctype = end_idx;
            }
        }
        i += 1;
    }

    return after_html orelse after_doctype orelse base;
}

/// Injects `snippet` at the earliest `<head>` position of `html` and returns a newly allocated HTML buffer.
pub fn injectIntoHead(allocator: Allocator, html: []const u8, snippet: []const u8) Allocator.Error![]u8 {
    if (snippet.len == 0) return allocator.dupe(u8, html);
    const offset = findHeadInsertionOffset(html);
    var out = try allocator.alloc(u8, html.len + snippet.len);
    @memcpy(out[0..offset], html[0..offset]);
    @memcpy(out[offset .. offset + snippet.len], snippet);
    @memcpy(out[offset + snippet.len ..], html[offset..]);
    return out;
}

fn matchOpeningTagEnd(html: []const u8, lt_pos: usize, comptime tag_lower: []const u8) ?usize {
    const name_start = lt_pos + 1;
    const name_end = name_start + tag_lower.len;
    if (name_end >= html.len) return null;
    if (!std.ascii.eqlIgnoreCase(html[name_start..name_end], tag_lower)) return null;

    const boundary = html[name_end];
    if (boundary != '>' and boundary != '/' and !std.ascii.isWhitespace(boundary)) return null;

    // Scan until matching unquoted `>`
    var quote: u8 = 0;
    var j: usize = name_end;
    while (j < html.len) : (j += 1) {
        const c = html[j];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else {
            if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == '>') {
                return j + 1;
            }
        }
    }
    return null;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "HTML-safe JSON string escaping neutralizes </script>, HTML comments, control chars, and U+2028/2029" {
    const payload = "hello \"world\" \\ \x01 </script><!-- & \u{2028}\u{2029} 日本語";

    const safe = try escapeJsonStringAlloc(testing.allocator, payload, true);
    defer testing.allocator.free(safe);

    try testing.expect(std.mem.indexOf(u8, safe, "</script>") == null);
    try testing.expect(std.mem.indexOf(u8, safe, "<!--") == null);
    try testing.expectEqualStrings(
        "\"hello \\\"world\\\" \\\\ \\u0001 \\u003c/script\\u003e\\u003c!-- \\u0026 \\u2028\\u2029 日本語\"",
        safe,
    );

    // Standard JSON mode keeps `<`, `>`, `&` unescaped
    const plain = try escapeJsonStringAlloc(testing.allocator, "<b>a&b</b>", false);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("\"<b>a&b</b>\"", plain);
}

test "HTML entity escaping and <head> script injection ignore HTML comments and attributes containing >" {
    const attr = try escapeHtmlTextAlloc(testing.allocator, "default-src 'self'; img-src \"data:\" <x>&y");
    defer testing.allocator.free(attr);
    try testing.expectEqualStrings("default-src &#39;self&#39;; img-src &quot;data:&quot; &lt;x&gt;&amp;y", attr);

    const doc = "\xEF\xBB\xBF<!DOCTYPE html><!-- <head><script>bad()</script></head> --><HTML lang=\"ja\"><HEAD data-x=\"a>b\"><title>App</title></head>";
    const injected = try injectIntoHead(testing.allocator, doc, "<script>init()</script>");
    defer testing.allocator.free(injected);

    try testing.expectEqualStrings(
        "\xEF\xBB\xBF<!DOCTYPE html><!-- <head><script>bad()</script></head> --><HTML lang=\"ja\"><HEAD data-x=\"a>b\"><script>init()</script><title>App</title></head>",
        injected,
    );

    // Fallback when `<head>` is omitted
    const bare = "<!doctype html><body>hi</body>";
    const injected_bare = try injectIntoHead(testing.allocator, bare, "<script>x()</script>");
    defer testing.allocator.free(injected_bare);
    try testing.expectEqualStrings("<!doctype html><script>x()</script><body>hi</body>", injected_bare);
}
