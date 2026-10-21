//! RFC 9110 `Range` header parsing and `206 Partial Content` helpers.
//!
//! `<video>` and `<audio>` playback (and seeking) in WebKit only works when a
//! byte range request is answered with `206` + a correct `Content-Range`
//! header. This module parses the three standard forms:
//!
//! - `bytes=start-end` (inclusive)
//! - `bytes=start-`    (open ended)
//! - `bytes=-suffix`   (last N bytes)
//!
//! Multi-range requests (`bytes=0-1,4-5`) are parsed as `error.TooManyRanges`
//! and should be answered with a normal `200` full-body response: implementing
//! `multipart/byteranges` is optional per RFC 9110 and unnecessary here.
//!
//! The distinction between *malformed* and *unsatisfiable* requests matters:
//! malformed headers must be ignored (serve `200`), while a syntactically valid
//! but unsatisfiable range must produce `416` with `Content-Range: bytes */len`.

const std = @import("std");

pub const ParseError = error{
    /// Not `unit=range` shaped, non-numeric offsets, reversed ranges, ...
    Malformed,
    /// A range unit other than `bytes` (e.g. `items=0-1`).
    UnsupportedUnit,
    /// Syntactically valid but outside the resource (or empty resource).
    Unsatisfiable,
    /// Comma-separated range sets are not supported (serve `200` instead).
    TooManyRanges,
    /// Offset does not fit in `u64`.
    Overflow,
};

/// An inclusive byte range, as used by `Content-Range`.
pub const ByteRange = struct {
    start: u64,
    end: u64,

    pub fn length(self: ByteRange) u64 {
        if (self.end < self.start) return 0;
        return self.end - self.start + 1;
    }

    /// Borrows the covered slice from `data`, or null when out of bounds.
    pub fn slice(self: ByteRange, data: []const u8) ?[]const u8 {
        if (self.end < self.start) return null;
        if (self.end >= data.len) return null;
        return data[@intCast(self.start)..@intCast(self.end + 1)];
    }

    pub fn eql(self: ByteRange, other: ByteRange) bool {
        return self.start == other.start and self.end == other.end;
    }
};

/// Parses a single `Range` header value against a known resource length.
pub fn parse(value: []const u8, total_len: u64) ParseError!ByteRange {
    const trimmed = std.mem.trim(u8, value, " \t");
    const equals = std.mem.findScalar(u8, trimmed, '=') orelse return error.Malformed;
    const unit = std.mem.trim(u8, trimmed[0..equals], " \t");
    if (!std.ascii.eqlIgnoreCase(unit, "bytes")) {
        return if (unit.len == 0) error.Malformed else error.UnsupportedUnit;
    }

    const set = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
    if (set.len == 0) return error.Malformed;
    if (std.mem.findScalar(u8, set, ',') != null) return error.TooManyRanges;

    const dash = std.mem.findScalar(u8, set, '-') orelse return error.Malformed;
    const start_text = std.mem.trim(u8, set[0..dash], " \t");
    const end_text = std.mem.trim(u8, set[dash + 1 ..], " \t");

    if (start_text.len == 0) {
        // Suffix form: `bytes=-N`.
        if (end_text.len == 0) return error.Malformed;
        const suffix = try parseOffset(end_text);
        if (suffix == 0) return error.Unsatisfiable;
        if (total_len == 0) return error.Unsatisfiable;
        const length = @min(suffix, total_len);
        return .{ .start = total_len - length, .end = total_len - 1 };
    }

    const start = try parseOffset(start_text);
    if (total_len == 0 or start >= total_len) return error.Unsatisfiable;

    if (end_text.len == 0) {
        return .{ .start = start, .end = total_len - 1 };
    }

    const requested_end = try parseOffset(end_text);
    if (requested_end < start) return error.Malformed;
    return .{ .start = start, .end = @min(requested_end, total_len - 1) };
}

fn parseOffset(text: []const u8) ParseError!u64 {
    if (text.len == 0) return error.Malformed;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return error.Malformed;
    }
    return std.fmt.parseInt(u64, text, 10) catch error.Overflow;
}

/// High-level outcome of a `Range` header for a specific body.
pub const Resolution = union(enum) {
    /// No header, malformed header, or unsupported form: send the whole body.
    full,
    /// Send `206` with this range.
    partial: ByteRange,
    /// Send `416` with `Content-Range: bytes */<total>`.
    unsatisfiable,
};

/// Applies a `Range` header the way an HTTP server should.
pub fn resolve(header: ?[]const u8, total_len: u64) Resolution {
    const value = header orelse return .full;
    const range = parse(value, total_len) catch |err| switch (err) {
        error.Unsatisfiable => return .unsatisfiable,
        // Ignoring an unparseable/unsupported header is explicitly allowed and
        // is far friendlier than failing a media load.
        else => return .full,
    };
    return .{ .partial = range };
}

/// Formats `Content-Range: bytes start-end/total` into `buf`.
pub fn contentRange(buf: []u8, range: ByteRange, total_len: u64) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "bytes {d}-{d}/{d}", .{ range.start, range.end, total_len });
}

/// Formats the `416` variant `Content-Range: bytes *\/total` into `buf`.
pub fn unsatisfiedContentRange(buf: []u8, total_len: u64) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "bytes */{d}", .{total_len});
}

/// RFC 9110 §13.1.5 `If-Range` evaluation. `etag` must include its quotes and
/// must be a strong validator; `last_modified` is compared verbatim because
/// date parsing is not required for correctness (a mismatch simply disables the
/// range, which is always safe).
pub fn ifRangeMatches(if_range: []const u8, etag: ?[]const u8, last_modified: ?[]const u8) bool {
    const trimmed = std.mem.trim(u8, if_range, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.startsWith(u8, trimmed, "W/")) return false; // weak validators never match
    if (trimmed[0] == '"') {
        const candidate = etag orelse return false;
        return std.mem.eql(u8, candidate, trimmed);
    }
    const date = last_modified orelse return false;
    return std.mem.eql(u8, date, trimmed);
}

const testing = std.testing;

test "http_range: explicit start-end, open ended and suffix forms" {
    try testing.expect((try parse("bytes=0-0", 100)).eql(.{ .start = 0, .end = 0 }));
    try testing.expect((try parse("bytes=0-99", 100)).eql(.{ .start = 0, .end = 99 }));
    try testing.expect((try parse("bytes=10-", 100)).eql(.{ .start = 10, .end = 99 }));
    try testing.expect((try parse("bytes=-10", 100)).eql(.{ .start = 90, .end = 99 }));
    try testing.expect((try parse("bytes=-1", 100)).eql(.{ .start = 99, .end = 99 }));
    try testing.expect((try parse("bytes=99-", 100)).eql(.{ .start = 99, .end = 99 }));
}

test "http_range: end offsets are clamped and suffix larger than body is clamped" {
    try testing.expect((try parse("bytes=50-1000", 100)).eql(.{ .start = 50, .end = 99 }));
    try testing.expect((try parse("bytes=-500", 100)).eql(.{ .start = 0, .end = 99 }));
    try testing.expect((try parse("bytes=0-", 1)).eql(.{ .start = 0, .end = 0 }));
}

test "http_range: whitespace and case of the unit are tolerated" {
    try testing.expect((try parse("  bytes=1-2  ", 10)).eql(.{ .start = 1, .end = 2 }));
    try testing.expect((try parse("BYTES = 1 - 2", 10)).eql(.{ .start = 1, .end = 2 }));
}

test "http_range: unsatisfiable ranges" {
    try testing.expectError(error.Unsatisfiable, parse("bytes=100-", 100));
    try testing.expectError(error.Unsatisfiable, parse("bytes=100-200", 100));
    try testing.expectError(error.Unsatisfiable, parse("bytes=-0", 100));
    try testing.expectError(error.Unsatisfiable, parse("bytes=0-0", 0));
    try testing.expectError(error.Unsatisfiable, parse("bytes=-10", 0));
}

test "http_range: malformed and unsupported headers" {
    try testing.expectError(error.Malformed, parse("", 100));
    try testing.expectError(error.Malformed, parse("bytes", 100));
    try testing.expectError(error.Malformed, parse("bytes=", 100));
    try testing.expectError(error.Malformed, parse("bytes=-", 100));
    try testing.expectError(error.Malformed, parse("bytes=abc", 100));
    try testing.expectError(error.Malformed, parse("bytes=1-2-3", 100));
    try testing.expectError(error.Malformed, parse("bytes=5-2", 100));
    try testing.expectError(error.Malformed, parse("bytes=1-+2", 100));
    try testing.expectError(error.Malformed, parse("bytes= 1 2 - 3", 100));
    try testing.expectError(error.UnsupportedUnit, parse("items=0-1", 100));
    try testing.expectError(error.Malformed, parse("=0-1", 100));
}

test "http_range: multiple ranges are rejected" {
    try testing.expectError(error.TooManyRanges, parse("bytes=0-1,4-5", 100));
    try testing.expectError(error.TooManyRanges, parse("bytes=0-1,", 100));
}

test "http_range: numeric overflow is rejected" {
    try testing.expectError(error.Overflow, parse("bytes=99999999999999999999999-", 100));
    try testing.expectError(error.Overflow, parse("bytes=-99999999999999999999999", 100));
}

test "http_range: resolve maps errors to the correct HTTP behaviour" {
    try testing.expect(resolve(null, 100) == .full);
    try testing.expect(resolve("bytes=garbage", 100) == .full);
    try testing.expect(resolve("items=0-1", 100) == .full);
    try testing.expect(resolve("bytes=0-1,4-5", 100) == .full);
    try testing.expect(resolve("bytes=500-", 100) == .unsatisfiable);
    switch (resolve("bytes=0-9", 100)) {
        .partial => |range| try testing.expect(range.eql(.{ .start = 0, .end = 9 })),
        else => return error.TestUnexpectedResult,
    }
}

test "http_range: content-range formatting" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("bytes 0-99/1000", try contentRange(&buf, .{ .start = 0, .end = 99 }, 1000));
    try testing.expectEqualStrings("bytes */0", try unsatisfiedContentRange(&buf, 0));
    try testing.expectError(error.NoSpaceLeft, contentRange(buf[0..5], .{ .start = 0, .end = 99 }, 1000));
}

test "http_range: ByteRange slice and length" {
    const data = "0123456789";
    try testing.expectEqualStrings("234", (ByteRange{ .start = 2, .end = 4 }).slice(data).?);
    try testing.expectEqual(@as(?[]const u8, null), (ByteRange{ .start = 8, .end = 10 }).slice(data));
    try testing.expectEqual(@as(?[]const u8, null), (ByteRange{ .start = 4, .end = 2 }).slice(data));
    try testing.expectEqual(@as(u64, 3), (ByteRange{ .start = 2, .end = 4 }).length());
    try testing.expectEqual(@as(u64, 0), (ByteRange{ .start = 4, .end = 2 }).length());
}

test "http_range: If-Range requires a matching strong validator" {
    try testing.expect(ifRangeMatches("\"abc\"", "\"abc\"", null));
    try testing.expect(ifRangeMatches("  \"abc\" ", "\"abc\"", null));
    try testing.expect(!ifRangeMatches("\"other\"", "\"abc\"", null));
    try testing.expect(!ifRangeMatches("W/\"abc\"", "\"abc\"", null));
    try testing.expect(!ifRangeMatches("\"abc\"", null, null));
    try testing.expect(ifRangeMatches("Wed, 21 Oct 2015 07:28:00 GMT", null, "Wed, 21 Oct 2015 07:28:00 GMT"));
    try testing.expect(!ifRangeMatches("Wed, 21 Oct 2015 07:28:00 GMT", null, "Thu, 22 Oct 2015 07:28:00 GMT"));
    try testing.expect(!ifRangeMatches("", "\"abc\"", null));
}
