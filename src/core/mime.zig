//! Web Standard MIME Type Lookup & Magic-Byte Sniffer (`src/core/mime.zig`).
//!
//! Resolves accurate `Content-Type` header values for embedded and dev-server WebView assets
//! without any external database files or OS registry dependencies (`link_libc = false`).
//!
//! Why accuracy matters in WebViews:
//! - ES Modules (`<script type="module" src="/app.js">`) strictly reject non-JS MIME types.
//! - `WebAssembly.instantiateStreaming(fetch('/pkg.wasm'))` strictly requires `application/wasm`.
//! - `<svg>` images fail to render as `<img>` unless served as `image/svg+xml`.

const std = @import("std");
const testing = std.testing;

pub const DEFAULT_BINARY: []const u8 = "application/octet-stream";
pub const HTML_UTF8: []const u8 = "text/html; charset=utf-8";
pub const JS_UTF8: []const u8 = "text/javascript; charset=utf-8";
pub const CSS_UTF8: []const u8 = "text/css; charset=utf-8";
pub const JSON_UTF8: []const u8 = "application/json";
pub const WASM: []const u8 = "application/wasm";
pub const SVG: []const u8 = "image/svg+xml";

const ExtensionEntry = struct {
    ext: []const u8,
    mime: []const u8,
};

const extension_table = std.StaticStringMap([]const u8).initComptime(.{
    // Web documents & scripts
    .{ "html", HTML_UTF8 },
    .{ "htm", HTML_UTF8 },
    .{ "xhtml", "application/xhtml+xml" },
    .{ "js", JS_UTF8 },
    .{ "mjs", JS_UTF8 },
    .{ "cjs", JS_UTF8 },
    .{ "css", CSS_UTF8 },
    .{ "json", JSON_UTF8 },
    .{ "map", JSON_UTF8 },
    .{ "webmanifest", "application/manifest+json" },
    .{ "wasm", WASM },
    .{ "txt", "text/plain; charset=utf-8" },
    .{ "md", "text/markdown; charset=utf-8" },
    .{ "csv", "text/csv; charset=utf-8" },
    .{ "xml", "application/xml" },

    // Images
    .{ "svg", SVG },
    .{ "svgz", SVG },
    .{ "png", "image/png" },
    .{ "jpg", "image/jpeg" },
    .{ "jpeg", "image/jpeg" },
    .{ "jpe", "image/jpeg" },
    .{ "gif", "image/gif" },
    .{ "webp", "image/webp" },
    .{ "avif", "image/avif" },
    .{ "ico", "image/x-icon" },
    .{ "bmp", "image/bmp" },
    .{ "tif", "image/tiff" },
    .{ "tiff", "image/tiff" },

    // Fonts
    .{ "woff2", "font/woff2" },
    .{ "woff", "font/woff" },
    .{ "ttf", "font/ttf" },
    .{ "otf", "font/otf" },

    // Audio & Video
    .{ "mp3", "audio/mpeg" },
    .{ "m4a", "audio/mp4" },
    .{ "aac", "audio/aac" },
    .{ "wav", "audio/wav" },
    .{ "ogg", "audio/ogg" },
    .{ "oga", "audio/ogg" },
    .{ "opus", "audio/opus" },
    .{ "flac", "audio/flac" },
    .{ "mp4", "video/mp4" },
    .{ "m4v", "video/mp4" },
    .{ "webm", "video/webm" },
    .{ "ogv", "video/ogg" },
    .{ "mov", "video/quicktime" },

    // Archives & Documents
    .{ "pdf", "application/pdf" },
    .{ "zip", "application/zip" },
    .{ "gz", "application/gzip" },
    .{ "wasm.map", JSON_UTF8 },
});

/// Looks up a MIME type from a file extension (with or without a leading `.`, case-insensitive).
/// Returns `null` if the extension is unknown or exceeds 16 ASCII characters.
pub fn fromExtension(raw_ext: []const u8) ?[]const u8 {
    const ext = if (raw_ext.len > 0 and raw_ext[0] == '.') raw_ext[1..] else raw_ext;
    if (ext.len == 0 or ext.len > 16) return null;

    var lower_buf: [16]u8 = undefined;
    for (ext, 0..) |ch, i| {
        lower_buf[i] = std.ascii.toLower(ch);
    }
    return extension_table.get(lower_buf[0..ext.len]);
}

/// Extracts the final file extension from a URL or filesystem path (ignoring query/fragment)
/// and returns its MIME type if known.
pub fn fromPath(path: []const u8) ?[]const u8 {
    const clean = stripQueryAndFragment(path);
    const last_sep = std.mem.lastIndexOfAny(u8, clean, "/\\");
    const filename = if (last_sep) |idx| clean[idx + 1 ..] else clean;
    const dot_idx = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return null;
    if (dot_idx == 0) return null; // dotfiles like `.gitignore` have no extension
    return fromExtension(filename[dot_idx + 1 ..]);
}

/// Inspects leading magic bytes following WHATWG MIME Sniffing signatures.
/// Returns `null` when no known binary/markup signature matches.
pub fn sniff(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 4) {
        if (std.mem.eql(u8, bytes[0..4], "\x00asm")) return WASM;
        if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
        if (std.mem.eql(u8, bytes[0..3], "\xFF\xD8\xFF")) return "image/jpeg";
        if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "image/gif";
        if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF")) {
            if (std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
            if (std.mem.eql(u8, bytes[8..12], "WAVE")) return "audio/wav";
        }
        if (bytes.len >= 5 and std.mem.eql(u8, bytes[0..5], "%PDF-")) return "application/pdf";
        if (std.mem.eql(u8, bytes[0..4], "OggS")) return "application/ogg";
        if (std.mem.eql(u8, bytes[0..4], "\x1A\x45\xDF\xA3")) return "video/webm";
        if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp")) return "video/mp4";
        if (std.mem.eql(u8, bytes[0..4], "wOF2")) return "font/woff2";
        if (std.mem.eql(u8, bytes[0..4], "wOFF")) return "font/woff";
        if (std.mem.eql(u8, bytes[0..3], "ID3") or (bytes[0] == 0xFF and (bytes[1] & 0xE0) == 0xE0)) return "audio/mpeg";
        if (std.mem.eql(u8, bytes[0..4], "\x00\x00\x01\x00")) return "image/x-icon";
    }
    if (bytes.len >= 2 and std.mem.eql(u8, bytes[0..2], "BM")) return "image/bmp";

    const trimmed = std.mem.trimStart(u8, bytes[0..@min(bytes.len, 256)], " \t\r\n");
    if (startsWithIgnoreCase(trimmed, "<!doctype html") or startsWithIgnoreCase(trimmed, "<html")) {
        return HTML_UTF8;
    }
    if (startsWithIgnoreCase(trimmed, "<svg")) {
        return SVG;
    }
    return null;
}

/// Resolves the MIME type from `path` first, falling back to `sniff(bytes)` and finally
/// `"application/octet-stream"`. Never returns `null`.
pub fn detect(path: []const u8, bytes: []const u8) []const u8 {
    return fromPath(path) orelse sniff(bytes) orelse DEFAULT_BINARY;
}

pub fn isHtml(mime_type: []const u8) bool {
    return startsWithIgnoreCase(mime_type, "text/html") or
        startsWithIgnoreCase(mime_type, "application/xhtml+xml");
}

fn stripQueryAndFragment(path: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, path, "?#")) |idx| return path[0..idx];
    return path;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "MIME lookup covers ES modules, Wasm, SVG, media, case-insensitivity, and magic bytes" {
    try testing.expectEqualStrings(HTML_UTF8, fromPath("/index.html").?);
    try testing.expectEqualStrings(JS_UTF8, fromPath("/assets/app-B81a2.MJS?v=123#top").?);
    try testing.expectEqualStrings(JS_UTF8, fromExtension(".JS").?);
    try testing.expectEqualStrings(CSS_UTF8, fromPath("/styles/main.css").?);
    try testing.expectEqualStrings(WASM, fromPath("/pkg/core_bg.wasm").?);
    try testing.expectEqualStrings(SVG, fromPath("/icons/logo.svg").?);
    try testing.expectEqualStrings("font/woff2", fromPath("/fonts/Inter.woff2").?);
    try testing.expectEqualStrings("video/mp4", fromPath("/media/demo.mp4").?);
    try testing.expect(fromPath("/users/42/settings") == null);
    try testing.expect(fromPath("/.env") == null);

    // Magic-byte sniffing fallback
    try testing.expectEqualStrings(WASM, detect("/blob/no_ext", "\x00asm\x01\x00\x00\x00"));
    try testing.expectEqualStrings("image/png", detect("/blob/img", "\x89PNG\r\n\x1a\nxxxx"));
    try testing.expectEqualStrings("image/webp", detect("/blob/img", "RIFF\x24\x00\x00\x00WEBP"));
    try testing.expectEqualStrings(HTML_UTF8, detect("/route", "  \n<!DOCTYPE html><html></html>"));
    try testing.expectEqualStrings(DEFAULT_BINARY, detect("/unknown", "\x01\x02\x03"));
    try testing.expect(isHtml(HTML_UTF8));
    try testing.expect(!isHtml(JS_UTF8));
}
