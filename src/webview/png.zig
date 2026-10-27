//! Minimal PNG inspection + test-image encoding for `zts_webview`.
//!
//! The screenshot API (`Engine.captureWindow` / `takeCapture`) hands PNG bytes back from three
//! completely different native encoders (cairo, `NSBitmapImageRep`, WebView2 `CapturePreview`), so
//! the only cross-platform way to learn the image size is to read the IHDR chunk. That parsing
//! lives here, next to a *stored-block* PNG writer used by `HeadlessMock` and the unit tests — no
//! zlib compressor is involved, so this file stays dependency-free and dead-code-eliminated out of
//! production builds that never touch the mock.
//!
//! Everything here is deliberately strict: a truncated or non-PNG buffer returns an error instead
//! of guessing, because a silently-zero size would make a blank CI artifact look like a pass.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// The 8-byte PNG magic (`\x89PNG\r\n\x1A\n`).
pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const Error = error{
    NotPng,
    Truncated,
    InvalidChunk,
};

/// Reads `width` / `height` from the mandatory leading `IHDR` chunk.
///
/// A conforming encoder always writes `IHDR` first, so a byte-accurate check of the signature, the
/// chunk type and the length (13 bytes) is enough — no full decoder, no allocations.
pub fn parseSize(bytes: []const u8) Error!Size {
    if (bytes.len < 8 + 8 + 13 + 4) return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &signature)) return Error.NotPng;

    const ihdr_len = std.mem.readInt(u32, bytes[8..12], .big);
    if (ihdr_len != 13) return Error.InvalidChunk;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return Error.InvalidChunk;

    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width == 0 or height == 0) return Error.InvalidChunk;
    return .{ .width = width, .height = height };
}

/// True when `bytes` starts with the PNG signature (cheap pre-check for logs / C callers).
pub fn isPng(bytes: []const u8) bool {
    return bytes.len >= signature.len and std.mem.eql(u8, bytes[0..signature.len], &signature);
}

/// Encodes an 8-bit RGBA image as a valid PNG using **stored (uncompressed) deflate blocks**.
///
/// Only used by the mock backend and tests: it keeps `zts_webview` free of a zlib dependency while
/// still producing bytes that every browser, `file(1)` and the CI verifier accept. Real backends
/// always use their platform encoder.
pub fn encode(allocator: Allocator, width: u32, height: u32, rgba: []const u8) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const stride: usize = @as(usize, width) * 4;
    const expected = stride * @as(usize, height);
    if (rgba.len != expected) return error.InvalidDimensions;

    // Raw scanlines, each prefixed with filter type 0 (`None`).
    const raw_len = (stride + 1) * @as(usize, height);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    for (0..height) |y| {
        const dst = y * (stride + 1);
        raw[dst] = 0;
        @memcpy(raw[dst + 1 ..][0..stride], rgba[y * stride ..][0..stride]);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &signature);

    try writeChunk(allocator, &out, "IHDR", &ihdrData(width, height));

    const idat = try zlibStored(allocator, raw);
    defer allocator.free(idat);
    try writeChunk(allocator, &out, "IDAT", idat);

    try writeChunk(allocator, &out, "IEND", &.{});

    return out.toOwnedSlice(allocator);
}

fn ihdrData(width: u32, height: u32) [13]u8 {
    var data: [13]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], width, .big);
    std.mem.writeInt(u32, data[4..8], height, .big);
    data[8] = 8; // bit depth
    data[9] = 6; // colour type: truecolour + alpha
    data[10] = 0; // deflate
    data[11] = 0; // adaptive filtering
    data[12] = 0; // no interlace
    return data;
}

/// Wraps `raw` in a zlib stream made of stored deflate blocks (max 65 535 bytes each).
fn zlibStored(allocator: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // CMF=0x78 (deflate, 32 KiB window), FLG=0x01 (check bits make CMF*256+FLG a multiple of 31).
    try out.appendSlice(allocator, &.{ 0x78, 0x01 });

    var offset: usize = 0;
    while (offset < raw.len) {
        const len = @min(raw.len - offset, 65_535);
        const is_final: bool = offset + len == raw.len;
        try out.append(allocator, if (is_final) 0x01 else 0x00);
        try out.append(allocator, @truncate(len));
        try out.append(allocator, @truncate(len >> 8));
        try out.append(allocator, ~@as(u8, @truncate(len)));
        try out.append(allocator, ~@as(u8, @truncate(len >> 8)));
        try out.appendSlice(allocator, raw[offset..][0..len]);
        offset += len;
    }

    var adler: Adler32 = .{};
    adler.update(raw);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, adler.final(), .big);
    try out.appendSlice(allocator, &sum);
    return out.toOwnedSlice(allocator);
}

fn writeChunk(allocator: Allocator, out: *std.ArrayList(u8), kind: []const u8, data: []const u8) !void {
    std.debug.assert(kind.len == 4);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len_buf);
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, data);

    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try out.appendSlice(allocator, &crc_buf);
}

/// zlib's Adler-32 (RFC 1950 §9) — needed because the deflate stream above is "stored".
pub const Adler32 = struct {
    a: u32 = 1,
    b: u32 = 0,

    pub fn update(self: *Adler32, bytes: []const u8) void {
        const mod = 65521;
        for (bytes) |byte| {
            self.a = (self.a + byte) % mod;
            self.b = (self.b + self.a) % mod;
        }
    }

    pub fn final(self: Adler32) u32 {
        return (self.b << 16) | self.a;
    }
};

/// Deterministic test image: a diagonal RGBA gradient plus a solid marker square in the top-left.
/// Used by `HeadlessMock` so every capture is non-blank and byte-identical across runs (CI can
/// hash it), without needing a real renderer.
pub fn testImage(allocator: Allocator, width: u32, height: u32) ![]u8 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const rgba = try allocator.alloc(u8, w * h * 4);
    defer allocator.free(rgba);

    const marker = @max(2, @min(w / 8, h / 8));
    for (0..h) |y| {
        for (0..w) |x| {
            const idx = (y * w + x) * 4;
            const in_marker = x < marker and y < marker;
            rgba[idx + 0] = if (in_marker) 0xFF else @intCast((x * 255) / @max(1, w - 1));
            rgba[idx + 1] = if (in_marker) 0x00 else @intCast((y * 255) / @max(1, h - 1));
            rgba[idx + 2] = if (in_marker) 0x40 else 0x80;
            rgba[idx + 3] = 0xFF;
        }
    }
    return encode(allocator, width, height, rgba);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "png: encode produces a valid RGBA PNG whose IHDR round-trips" {
    const budget = 16 * 16 * 4;
    const rgba = try testing.allocator.alloc(u8, budget);
    defer testing.allocator.free(rgba);
    @memset(rgba, 0x40);

    const bytes = try encode(testing.allocator, 16, 16, rgba);
    defer testing.allocator.free(bytes);

    try testing.expect(isPng(bytes));
    const size = try parseSize(bytes);
    try testing.expectEqual(@as(u32, 16), size.width);
    try testing.expectEqual(@as(u32, 16), size.height);
    // `IEND` must be the last chunk, with an empty body.
    try testing.expectEqualStrings("IEND", bytes[bytes.len - 8 ..][0..4]);
}

test "png: test image is deterministic and non-uniform" {
    const a = try testImage(testing.allocator, 32, 24);
    defer testing.allocator.free(a);
    const b = try testImage(testing.allocator, 32, 24);
    defer testing.allocator.free(b);

    try testing.expectEqualSlices(u8, a, b);
    const size = try parseSize(a);
    try testing.expectEqual(@as(u32, 32), size.width);
    try testing.expectEqual(@as(u32, 24), size.height);
}

test "png: a truncated or foreign buffer is rejected instead of guessed" {
    const full = try testImage(testing.allocator, 8, 8);
    defer testing.allocator.free(full);

    try testing.expectError(Error.Truncated, parseSize(full[0..20]));
    const zeros: [64]u8 = @splat(0);
    try testing.expectError(Error.NotPng, parseSize(&zeros));

    // Right length, wrong chunk type.
    var bogus: [64]u8 = undefined;
    @memcpy(bogus[0..8], &signature);
    std.mem.writeInt(u32, bogus[8..12], 13, .big);
    @memcpy(bogus[12..16], "IDAT");
    try testing.expectError(Error.InvalidChunk, parseSize(&bogus));
}

test "png: zero-sized or mismatched pixel buffers are rejected" {
    var one: [4]u8 = .{ 0, 0, 0, 0xFF };
    try testing.expectError(error.InvalidDimensions, encode(testing.allocator, 0, 4, &one));
    try testing.expectError(error.InvalidDimensions, encode(testing.allocator, 2, 2, &one));
    _ = &one;
}

test "png: a multi-block (> 64 KiB) image still round-trips its size" {
    const w: u32 = 128;
    const h: u32 = 200; // 128*200*4 = 102 400 bytes => two stored deflate blocks
    const bytes = try testImage(testing.allocator, w, h);
    defer testing.allocator.free(bytes);

    const size = try parseSize(bytes);
    try testing.expectEqual(w, size.width);
    try testing.expectEqual(h, size.height);
    try testing.expect(bytes.len > 100_000);
}
