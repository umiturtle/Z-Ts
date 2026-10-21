//! Static MIME table plus magic-byte sniffing for embedded / directory assets.
//!
//! WebView engines are strict about module MIME types (`.mjs`, `.js`, `.wasm`)
//! and about `<video>`/`<audio>` payloads, so the extension table is the source
//! of truth for known extensions and magic bytes are only a fallback for
//! extensionless or unknown files. No allocation is ever needed: every returned
//! content type is a `comptime` string literal.

const std = @import("std");

pub const octet_stream = "application/octet-stream";

/// Maximum number of bytes inspected by `sniff` (enough for all signatures).
pub const sniff_window: usize = 512;

const Map = std.StaticStringMap([]const u8);

/// Lowercase extension (without the dot) to full `Content-Type` value.
const table = Map.initComptime(.{
    // Documents / script / style
    .{ "html", "text/html; charset=utf-8" },
    .{ "htm", "text/html; charset=utf-8" },
    .{ "js", "text/javascript; charset=utf-8" },
    .{ "mjs", "text/javascript; charset=utf-8" },
    .{ "cjs", "text/javascript; charset=utf-8" },
    .{ "css", "text/css; charset=utf-8" },
    .{ "json", "application/json; charset=utf-8" },
    .{ "map", "application/json; charset=utf-8" },
    .{ "jsonld", "application/ld+json; charset=utf-8" },
    .{ "webmanifest", "application/manifest+json; charset=utf-8" },
    .{ "xml", "application/xml; charset=utf-8" },
    .{ "txt", "text/plain; charset=utf-8" },
    .{ "md", "text/markdown; charset=utf-8" },
    .{ "csv", "text/csv; charset=utf-8" },
    .{ "wasm", "application/wasm" },
    .{ "pdf", "application/pdf" },
    // Images
    .{ "svg", "image/svg+xml" },
    .{ "svgz", "image/svg+xml" },
    .{ "png", "image/png" },
    .{ "jpg", "image/jpeg" },
    .{ "jpeg", "image/jpeg" },
    .{ "jfif", "image/jpeg" },
    .{ "gif", "image/gif" },
    .{ "webp", "image/webp" },
    .{ "avif", "image/avif" },
    .{ "bmp", "image/bmp" },
    .{ "ico", "image/x-icon" },
    .{ "tif", "image/tiff" },
    .{ "tiff", "image/tiff" },
    // Audio
    .{ "mp3", "audio/mpeg" },
    .{ "m4a", "audio/mp4" },
    .{ "aac", "audio/aac" },
    .{ "wav", "audio/wav" },
    .{ "flac", "audio/flac" },
    .{ "ogg", "audio/ogg" },
    .{ "oga", "audio/ogg" },
    .{ "opus", "audio/ogg" },
    .{ "weba", "audio/webm" },
    // Video (Range requests are mandatory for these in WebKit)
    .{ "mp4", "video/mp4" },
    .{ "m4v", "video/mp4" },
    .{ "webm", "video/webm" },
    .{ "ogv", "video/ogg" },
    .{ "mov", "video/quicktime" },
    .{ "avi", "video/x-msvideo" },
    // Web fonts
    .{ "woff", "font/woff" },
    .{ "woff2", "font/woff2" },
    .{ "ttf", "font/ttf" },
    .{ "otf", "font/otf" },
    .{ "ttc", "font/collection" },
    .{ "eot", "application/vnd.ms-fontobject" },
    // Misc
    .{ "zip", "application/zip" },
    .{ "gz", "application/gzip" },
    .{ "tar", "application/x-tar" },
});

const textual_essences = std.StaticStringMap(void).initComptime(.{
    .{ "text/html", {} },
    .{ "text/css", {} },
    .{ "text/javascript", {} },
    .{ "text/plain", {} },
    .{ "text/markdown", {} },
    .{ "text/csv", {} },
    .{ "application/json", {} },
    .{ "application/ld+json", {} },
    .{ "application/manifest+json", {} },
    .{ "application/xml", {} },
    .{ "image/svg+xml", {} },
});

/// Extracts the extension (without the dot) from a path. Returns `""` when the
/// path has no usable extension. Query strings must be stripped by the caller.
pub fn extensionOf(path: []const u8) []const u8 {
    const slash = std.mem.findScalarLast(u8, path, '/') orelse 0;
    const basename = path[slash..];
    const dot = std.mem.findScalarLast(u8, basename, '.') orelse return "";
    const ext = basename[dot + 1 ..];
    if (ext.len == 0 or ext.len > 31) return "";
    return ext;
}

/// Looks up a content type by extension. A leading `.` is accepted and the
/// comparison is ASCII case-insensitive. Unknown extensions map to
/// `application/octet-stream`.
pub fn fromExtension(extension: []const u8) []const u8 {
    var ext = extension;
    if (ext.len > 0 and ext[0] == '.') ext = ext[1..];
    if (ext.len == 0 or ext.len > 31) return octet_stream;
    var lower: [31]u8 = undefined;
    for (ext, 0..) |c, index| lower[index] = std.ascii.toLower(c);
    return table.get(lower[0..ext.len]) orelse octet_stream;
}

/// Looks up a content type by file path.
pub fn fromPath(path: []const u8) []const u8 {
    return fromExtension(extensionOf(path));
}

/// Sniffs a content type from the leading bytes. Returns `null` when the payload
/// is not recognized.
pub fn sniff(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0) return null;

    // 8-byte signatures first.
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a }))
        return "image/png";
    if (bytes.len >= 6 and std.mem.eql(u8, bytes[0..6], "GIF87a")) return "image/gif";
    if (bytes.len >= 6 and std.mem.eql(u8, bytes[0..6], "GIF89a")) return "image/gif";

    // 4-byte signatures.
    if (std.mem.startsWith(u8, bytes, &[_]u8{ 0xff, 0xd8, 0xff })) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "\x00asm")) return "application/wasm";
    if (std.mem.startsWith(u8, bytes, "OggS")) return "audio/ogg";
    if (std.mem.startsWith(u8, bytes, "fLaC")) return "audio/flac";
    if (std.mem.startsWith(u8, bytes, &[_]u8{ 0x1a, 0x45, 0xdf, 0xa3 })) return "video/webm";
    if (std.mem.startsWith(u8, bytes, &[_]u8{ 0x00, 0x00, 0x01, 0x00 })) return "image/x-icon";
    if (std.mem.startsWith(u8, bytes, "\x00\x01\x00\x00")) return "font/ttf";
    if (std.mem.startsWith(u8, bytes, "true")) return "font/ttf";
    if (std.mem.startsWith(u8, bytes, "OTTO")) return "font/otf";
    if (std.mem.startsWith(u8, bytes, "ttcf")) return "font/collection";
    if (std.mem.startsWith(u8, bytes, "wOFF")) return "font/woff";
    if (std.mem.startsWith(u8, bytes, "wOF2")) return "font/woff2";
    if (std.mem.startsWith(u8, bytes, "%PDF")) return "application/pdf";
    if (std.mem.startsWith(u8, bytes, "PK\x03\x04") or std.mem.startsWith(u8, bytes, "PK\x05\x06"))
        return "application/zip";
    if (std.mem.startsWith(u8, bytes, "\x1f\x8b")) return "application/gzip";
    if (std.mem.startsWith(u8, bytes, "ID3")) return "audio/mpeg";
    if (bytes.len >= 2 and bytes[0] == 0xff and (bytes[1] & 0xe0) == 0xe0) return "audio/mpeg";

    // RIFF container family.
    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "RIFF")) {
        const form = bytes[8..12];
        if (std.mem.eql(u8, form, "WEBP")) return "image/webp";
        if (std.mem.eql(u8, form, "WAVE")) return "audio/wav";
        if (std.mem.eql(u8, form, "AVI ")) return "video/x-msvideo";
    }

    // ISO base media (mp4 / m4a / avif / mov).
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp")) {
        const brand = bytes[8..12];
        if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) return "image/avif";
        if (std.mem.eql(u8, brand, "M4A ") or std.mem.eql(u8, brand, "M4B ")) return "audio/mp4";
        if (std.mem.eql(u8, brand, "qt  ")) return "video/quicktime";
        return "video/mp4";
    }

    if (std.mem.startsWith(u8, bytes, "BM")) return "image/bmp";

    // Text-ish signatures (SVG / HTML) after BOM and whitespace.
    const head = skipPreamble(bytes);
    if (head.len == 0) return null;
    if (startsWithIgnoreCase(head, "<!doctype html")) return "text/html; charset=utf-8";
    if (startsWithIgnoreCase(head, "<html")) return "text/html; charset=utf-8";
    const window = head[0..@min(head.len, sniff_window)];
    if (startsWithIgnoreCase(head, "<svg") or
        (startsWithIgnoreCase(head, "<?xml") and indexOfIgnoreCase(window, "<svg") != null))
        return "image/svg+xml";

    return null;
}

/// Extension first (authoritative for known web asset types), magic bytes as a
/// fallback for unknown or missing extensions.
pub fn detect(path: []const u8, bytes: []const u8) []const u8 {
    const by_extension = fromPath(path);
    if (!std.mem.eql(u8, by_extension, octet_stream)) return by_extension;
    return sniff(bytes) orelse octet_stream;
}

/// Returns the media type without parameters, trimmed.
pub fn essence(content_type: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, content_type, ';') orelse content_type.len;
    return std.mem.trim(u8, content_type[0..end], " \t");
}

/// Extracts a `charset=` parameter, if present.
pub fn charsetOf(content_type: []const u8) ?[]const u8 {
    var rest = content_type;
    const semi = std.mem.findScalar(u8, rest, ';') orelse return null;
    rest = rest[semi + 1 ..];
    var parameters = std.mem.splitScalar(u8, rest, ';');
    while (parameters.next()) |parameter| {
        const trimmed = std.mem.trim(u8, parameter, " \t");
        const equals = std.mem.findScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "charset")) continue;
        var value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        if (value.len == 0) return null;
        return value;
    }
    return null;
}

/// True when the media type is human-readable text (safe to inspect / modify).
pub fn isTextual(content_type: []const u8) bool {
    return textual_essences.has(essence(content_type));
}

/// True when gzip/br compression is worthwhile for this media type.
pub fn isCompressible(content_type: []const u8) bool {
    if (isTextual(content_type)) return true;
    const media = essence(content_type);
    return std.mem.eql(u8, media, "application/wasm") or
        std.mem.eql(u8, media, "application/javascript") or
        std.mem.eql(u8, media, "application/pdf");
}

fn skipPreamble(bytes: []const u8) []const u8 {
    var rest = bytes;
    if (std.mem.startsWith(u8, rest, "\xef\xbb\xbf")) rest = rest[3..];
    return std.mem.trimStart(u8, rest, " \t\r\n");
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return index;
    }
    return null;
}

const testing = std.testing;

test "mime: ES modules, styles and wasm get strict types" {
    try testing.expectEqualStrings("text/javascript; charset=utf-8", fromExtension("js"));
    try testing.expectEqualStrings("text/javascript; charset=utf-8", fromExtension(".MJS"));
    try testing.expectEqualStrings("text/css; charset=utf-8", fromPath("/assets/app.css"));
    try testing.expectEqualStrings("application/wasm", fromPath("pkg/core.wasm"));
    try testing.expectEqualStrings("text/html; charset=utf-8", fromPath("/index.html"));
}

test "mime: images, fonts, audio and video" {
    try testing.expectEqualStrings("image/svg+xml", fromPath("logo.svg"));
    try testing.expectEqualStrings("image/png", fromPath("a/b/icon.PNG"));
    try testing.expectEqualStrings("image/webp", fromPath("hero.webp"));
    try testing.expectEqualStrings("font/woff2", fromPath("fonts/inter.woff2"));
    try testing.expectEqualStrings("audio/mpeg", fromPath("sound.mp3"));
    try testing.expectEqualStrings("video/mp4", fromPath("clip.mp4"));
    try testing.expectEqualStrings("video/webm", fromPath("clip.webm"));
}

test "mime: unknown and edge-case extensions fall back to octet-stream" {
    try testing.expectEqualStrings(octet_stream, fromExtension(""));
    try testing.expectEqualStrings(octet_stream, fromExtension("unknown-ext"));
    try testing.expectEqualStrings(octet_stream, fromExtension("this-extension-is-way-too-long-to-be-real"));
    try testing.expectEqualStrings(octet_stream, fromPath("Makefile"));
    try testing.expectEqualStrings(octet_stream, fromPath("archive."));
    try testing.expectEqualStrings(octet_stream, fromPath("dir.with.dots/file"));
    try testing.expectEqualStrings(octet_stream, fromPath(""));
}

test "mime: magic byte sniffing for binary formats" {
    try testing.expectEqualStrings("image/png", sniff(&[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0 }).?);
    try testing.expectEqualStrings("image/jpeg", sniff(&[_]u8{ 0xff, 0xd8, 0xff, 0xe0 }).?);
    try testing.expectEqualStrings("image/gif", sniff("GIF89a....").?);
    try testing.expectEqualStrings("application/wasm", sniff("\x00asm\x01\x00\x00\x00").?);
    try testing.expectEqualStrings("application/pdf", sniff("%PDF-1.7").?);
    try testing.expectEqualStrings("application/zip", sniff("PK\x03\x04xyz").?);
    try testing.expectEqualStrings("application/gzip", sniff("\x1f\x8b\x08").?);
    try testing.expectEqualStrings("audio/mpeg", sniff("ID3\x04").?);
    try testing.expectEqualStrings("audio/wav", sniff("RIFF\x00\x00\x00\x00WAVEfmt ").?);
    try testing.expectEqualStrings("image/webp", sniff("RIFF\x00\x00\x00\x00WEBPVP8 ").?);
    try testing.expectEqualStrings("audio/mp4", sniff("\x00\x00\x00\x18ftypM4A \x00\x00\x00\x00").?);
    try testing.expectEqualStrings("image/avif", sniff("\x00\x00\x00\x18ftypavif\x00\x00\x00\x00").?);
    try testing.expectEqualStrings("font/woff2", sniff("wOF2\x00\x01").?);
    try testing.expectEqualStrings("application/octet-stream", detect("blob.bin", &[_]u8{ 1, 2, 3 }));
    try testing.expectEqual(@as(?[]const u8, null), sniff("plain text"));
}

test "mime: SVG and HTML sniffing is case-insensitive and BOM tolerant" {
    try testing.expectEqualStrings("image/svg+xml", sniff("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>").?);
    try testing.expectEqualStrings("image/svg+xml", sniff("\xef\xbb\xbf  <?xml version=\"1.0\"?><SVG></SVG>").?);
    try testing.expectEqualStrings("text/html; charset=utf-8", sniff("<!DOCTYPE html><html></html>").?);
    try testing.expectEqualStrings("text/html; charset=utf-8", sniff("\n<HTML lang=\"ja\">").?);
}

test "mime: detect prefers known extension over magic bytes" {
    // A JS file with an unusual prefix must stay JavaScript for module loading.
    try testing.expectEqualStrings("text/javascript; charset=utf-8", detect("app.js", "\x00asm"));
    // Unknown extension falls back to the signature.
    try testing.expectEqualStrings("image/png", detect("asset.bin", &[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a }));
    // No extension at all.
    try testing.expectEqualStrings("application/pdf", detect("download", "%PDF-1.4"));
}

test "mime: essence and charset parameter parsing" {
    try testing.expectEqualStrings("text/html", essence("text/html; charset=utf-8"));
    try testing.expectEqualStrings("application/wasm", essence("application/wasm"));
    try testing.expectEqualStrings("utf-8", charsetOf("text/html; charset=utf-8").?);
    try testing.expectEqualStrings("Shift_JIS", charsetOf("text/html;charset=\"Shift_JIS\"").?);
    try testing.expectEqual(@as(?[]const u8, null), charsetOf("application/wasm"));
    try testing.expectEqual(@as(?[]const u8, null), charsetOf("text/plain; boundary=x"));
    try testing.expectEqual(@as(?[]const u8, null), charsetOf("text/plain; charset="));
}

test "mime: textual and compressible classification" {
    try testing.expect(isTextual("text/html; charset=utf-8"));
    try testing.expect(isTextual("application/json; charset=utf-8"));
    try testing.expect(isTextual("image/svg+xml"));
    try testing.expect(!isTextual("image/png"));
    try testing.expect(!isTextual("application/octet-stream"));
    try testing.expect(isCompressible("text/javascript; charset=utf-8"));
    try testing.expect(isCompressible("application/wasm"));
    try testing.expect(!isCompressible("image/jpeg"));
}

test "mime: extension extraction ignores directories and query-less paths" {
    try testing.expectEqualStrings("js", extensionOf("/a/b/app.js"));
    try testing.expectEqualStrings("", extensionOf("/a/b.c/file"));
    try testing.expectEqualStrings("", extensionOf("/a/b/"));
    try testing.expectEqualStrings("gz", extensionOf("a.tar.gz"));
}
