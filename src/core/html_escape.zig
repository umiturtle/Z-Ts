//! HTML-safe JSON and HTML text escaping.
//!
//! An HTML parser terminates a `<script>` element at the first `</script`,
//! *even inside a JSON string literal*. `JSON.stringify` does not escape `/`,
//! `<` or `&`, so embedding user data (`{"name":"</script><img onerror=...>"}`)
//! directly into a `<script>` tag is an instant XSS. Every JSON document that
//! ends up inside HTML must therefore pass through this module:
//!
//! - `<` → `\u003c`, `>` → `\u003e`, `&` → `\u0026`
//! - U+2028 / U+2029 → `\u2028` / `\u2029` (legal JSON, illegal in pre-ES2019
//!   JavaScript string literals)
//! - invalid UTF-8 → `\ufffd` (lossy, same as `JSON.stringify` on lone
//!   surrogates)
//!
//! `writeEmbeddedJson` serializes any Zig value with `std.json.Stringify` and
//! post-processes the result in one pass, allocating only when escaping is
//! actually required.

const std = @import("std");

const Writer = std.Io.Writer;

/// Escapes text for use between HTML tags / in attribute values.
pub fn writeHtmlEscaped(writer: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Escapes the *contents* of a JSON string (no surrounding quotes) while also
/// making it safe to embed inside a `<script>` element.
pub fn writeJsonStringContent(writer: *Writer, text: []const u8) Writer.Error!void {
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '<' => try writer.writeAll("\\u003c"),
                '>' => try writer.writeAll("\\u003e"),
                '&' => try writer.writeAll("\\u0026"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x08 => try writer.writeAll("\\b"),
                0x0c => try writer.writeAll("\\f"),
                else => if (byte < 0x20 or byte == 0x7f)
                    try writeUnicodeEscape(writer, byte)
                else
                    try writer.writeByte(byte),
            }
            index += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writer.writeAll("\\ufffd");
            index += 1;
            continue;
        };
        if (index + sequence_len > text.len) {
            try writer.writeAll("\\ufffd");
            break;
        }
        const codepoint = std.unicode.utf8Decode(text[index..][0..sequence_len]) catch {
            // Overlong encodings / surrogate halves / out-of-range code points.
            try writer.writeAll("\\ufffd");
            index += 1;
            continue;
        };
        switch (codepoint) {
            0x2028 => try writer.writeAll("\\u2028"),
            0x2029 => try writer.writeAll("\\u2029"),
            else => try writer.writeAll(text[index..][0..sequence_len]),
        }
        index += sequence_len;
    }
}

/// Writes a complete JSON string literal (`"..."`), HTML-safe.
pub fn writeJsonString(writer: *Writer, text: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    try writeJsonStringContent(writer, text);
    try writer.writeByte('"');
}

fn writeUnicodeEscape(writer: *Writer, byte: u8) Writer.Error!void {
    const digits = "0123456789abcdef";
    try writer.writeAll("\\u00");
    try writer.writeByte(digits[byte >> 4]);
    try writer.writeByte(digits[byte & 0x0f]);
}

/// Rewrites already-serialized JSON so it is safe to inline in HTML. This is a
/// byte-level pass: the escaped sequences only ever occur inside string
/// literals in valid JSON.
pub fn writeScriptSafe(writer: *Writer, json: []const u8) Writer.Error!void {
    var index: usize = 0;
    while (index < json.len) {
        const byte = json[index];
        switch (byte) {
            '<' => {
                try writer.writeAll("\\u003c");
                index += 1;
            },
            '>' => {
                try writer.writeAll("\\u003e");
                index += 1;
            },
            '&' => {
                try writer.writeAll("\\u0026");
                index += 1;
            },
            0xe2 => {
                if (index + 2 < json.len and json[index + 1] == 0x80) {
                    if (json[index + 2] == 0xa8) {
                        try writer.writeAll("\\u2028");
                        index += 3;
                        continue;
                    } else if (json[index + 2] == 0xa9) {
                        try writer.writeAll("\\u2029");
                        index += 3;
                        continue;
                    }
                }
                try writer.writeByte(byte);
                index += 1;
            },
            else => {
                try writer.writeByte(byte);
                index += 1;
            },
        }
    }
}

fn needsScriptEscaping(json: []const u8) bool {
    var index: usize = 0;
    while (index < json.len) : (index += 1) {
        switch (json[index]) {
            '<', '>', '&' => return true,
            0xe2 => {
                if (index + 2 < json.len and json[index + 1] == 0x80 and
                    (json[index + 2] == 0xa8 or json[index + 2] == 0xa9)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Serializes `value` as JSON and makes the result safe for inline `<script>`
/// embedding. Caller owns the returned slice.
pub fn writeEmbeddedJson(allocator: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    var raw_buffer = Writer.Allocating.init(allocator);
    defer raw_buffer.deinit();
    // The allocating writer only fails when the allocator is exhausted.
    std.json.Stringify.value(value, .{}, &raw_buffer.writer) catch return error.OutOfMemory;
    const raw = raw_buffer.written();

    if (!needsScriptEscaping(raw)) return raw_buffer.toOwnedSlice();

    var escaped = Writer.Allocating.init(allocator);
    defer escaped.deinit();
    writeScriptSafe(&escaped.writer, raw) catch return error.OutOfMemory;
    return escaped.toOwnedSlice();
}

/// Allocates an HTML-escaped copy of `text`.
pub fn escapeHtmlAlloc(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    var buffer = Writer.Allocating.init(allocator);
    defer buffer.deinit();
    writeHtmlEscaped(&buffer.writer, text) catch return error.OutOfMemory;
    return buffer.toOwnedSlice();
}

/// Allocates a JSON-string-escaped (HTML-safe) copy of `text`, with quotes.
pub fn escapeJsonStringAlloc(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    var buffer = Writer.Allocating.init(allocator);
    defer buffer.deinit();
    writeJsonString(&buffer.writer, text) catch return error.OutOfMemory;
    return buffer.toOwnedSlice();
}

/// Allocates a script-safe copy of an existing JSON document.
pub fn scriptSafeAlloc(allocator: std.mem.Allocator, json: []const u8) error{OutOfMemory}![]u8 {
    var buffer = Writer.Allocating.init(allocator);
    defer buffer.deinit();
    writeScriptSafe(&buffer.writer, json) catch return error.OutOfMemory;
    return buffer.toOwnedSlice();
}

const testing = std.testing;

test "html_escape: HTML text escaping" {
    const allocator = testing.allocator;
    const escaped = try escapeHtmlAlloc(allocator, "<script>alert(\"x\" & 'y')</script>");
    defer allocator.free(escaped);
    try testing.expectEqualStrings(
        "&lt;script&gt;alert(&quot;x&quot; &amp; &#39;y&#39;)&lt;/script&gt;",
        escaped,
    );
}

test "html_escape: JSON strings escape quotes, backslashes and control chars" {
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);
    try writeJsonString(&writer, "a\"b\\c\nd\te\x01");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001\"", writer.buffered());
}

test "html_escape: </script> injection vectors are neutralized" {
    const allocator = testing.allocator;
    const payload = "</script><script>alert(document.cookie)</script>";
    const escaped = try escapeJsonStringAlloc(allocator, payload);
    defer allocator.free(escaped);

    try testing.expect(std.mem.findScalar(u8, escaped, '<') == null);
    try testing.expect(std.mem.findScalar(u8, escaped, '>') == null);
    try testing.expect(std.mem.find(u8, escaped, "\\u003c/script\\u003e") != null);

    // The escaped literal must still round-trip to the original string.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, escaped, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(payload, parsed.value.string);
}

test "html_escape: ampersand and U+2028/U+2029 are escaped" {
    const allocator = testing.allocator;
    const text = "a&b\u{2028}c\u{2029}d";
    const escaped = try escapeJsonStringAlloc(allocator, text);
    defer allocator.free(escaped);
    try testing.expectEqualStrings("\"a\\u0026b\\u2028c\\u2029d\"", escaped);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, escaped, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(text, parsed.value.string);
}

test "html_escape: invalid UTF-8 becomes U+FFFD instead of breaking the script" {
    const allocator = testing.allocator;
    const escaped = try escapeJsonStringAlloc(allocator, "ok\xff\xfe");
    defer allocator.free(escaped);
    try testing.expectEqualStrings("\"ok\\ufffd\\ufffd\"", escaped);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, escaped, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("ok\u{fffd}\u{fffd}", parsed.value.string);
}

test "html_escape: embedded JSON is serialized and script-safe" {
    const allocator = testing.allocator;
    const value = .{
        .name = "</script><img src=x onerror=alert(1)>",
        .message = "line\u{2028}separator",
        .count = 3,
        .ok = true,
    };
    const json = try writeEmbeddedJson(allocator, value);
    defer allocator.free(json);

    try testing.expect(std.mem.findScalar(u8, json, '<') == null);
    try testing.expect(std.mem.findScalar(u8, json, '>') == null);
    try testing.expect(std.mem.find(u8, json, "\\u2028") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("</script><img src=x onerror=alert(1)>", parsed.value.object.get("name").?.string);
    try testing.expectEqualStrings("line\u{2028}separator", parsed.value.object.get("message").?.string);
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("count").?.integer);
}

test "html_escape: embedded JSON without special characters allocates once and stays valid" {
    const allocator = testing.allocator;
    const json = try writeEmbeddedJson(allocator, .{ .plain = "hello", .n = 1 });
    defer allocator.free(json);
    try testing.expectEqualStrings("{\"plain\":\"hello\",\"n\":1}", json);
}

test "html_escape: writeScriptSafe on an existing document" {
    const allocator = testing.allocator;
    const safe = try scriptSafeAlloc(allocator, "{\"x\":\"<>&\u{2029}\"}");
    defer allocator.free(safe);
    try testing.expectEqualStrings("{\"x\":\"\\u003c\\u003e\\u0026\\u2029\"}", safe);
}

test "html_escape: fixed buffers surface WriteFailed instead of silently truncating" {
    var buf: [4]u8 = undefined;
    var writer = Writer.fixed(&buf);
    try testing.expectError(error.WriteFailed, writeHtmlEscaped(&writer, "abcdef"));
}
