//! RFC 9110 HTTP `Range` Parser & `206 Partial Content` Responder (`src/core/http_range.zig`).
//!
//! HTML5 `<video>` and `<audio>` elements in WKWebView, WebView2, and WebKit2GTK require
//! HTTP `Range: bytes=...` support with `206 Partial Content`, `Accept-Ranges: bytes`, and
//! `Content-Range: bytes <start>-<end>/<total>` to seek and stream media assets properly.

const std = @import("std");
const testing = std.testing;

/// Closed, validated byte interval `[start, end_inclusive]` (`0 <= start <= end_inclusive < total_len`).
pub const ByteRange = struct {
    /// First byte of the slice.
    start: u64,
    /// Last byte of the slice (inclusive, as HTTP spells it).
    end_inclusive: u64,

    /// Exact byte length of this partial slice (`end_inclusive - start + 1`).
    pub inline fn len(self: ByteRange) u64 {
        return (self.end_inclusive - self.start) + 1;
    }

    /// Slices an in-memory buffer safely according to this validated range.
    pub fn slice(self: ByteRange, data: []const u8) []const u8 {
        const s: usize = @intCast(self.start);
        const e: usize = @intCast(self.end_inclusive + 1);
        return data[s..e];
    }

    /// Formats the `Content-Range` response header value (`"bytes <start>-<end>/<total>"`)
    /// into a stack buffer with zero heap allocations.
    pub fn formatContentRange(self: ByteRange, buf: *[64]u8, total_len: u64) []const u8 {
        return std.fmt.bufPrint(buf, "bytes {d}-{d}/{d}", .{
            self.start,
            self.end_inclusive,
            total_len,
        }) catch unreachable;
    }
};

/// Formats a `416 Range Not Satisfiable` `Content-Range` value (`"bytes */<total>"`).
pub fn formatUnsatisfiableContentRange(buf: *[48]u8, total_len: u64) []const u8 {
    return std.fmt.bufPrint(buf, "bytes */{d}", .{total_len}) catch unreachable;
}

/// Outcome of evaluating an incoming `Range` request header against an asset of `total_len` bytes.
pub const RangeEval = union(enum) {
    /// Serve `206 Partial Content` for this exact closed byte interval.
    partial: ByteRange,
    /// Serve `416 Range Not Satisfiable` with `Content-Range: bytes */<total_len>`.
    unsatisfiable: void,
    /// Ignore the `Range` header and serve the full representation with `200 OK`
    /// (per RFC 9110 Section 14.2 for unknown units, malformed syntax, or unserved multipart sets).
    ignore: void,
};

/// Evaluates an HTTP `Range` header (e.g. `"bytes=0-1023"`, `"bytes=1024-"`, `"bytes=-500"`)
/// against a resource of size `total_len` per RFC 9110 Section 14.1.2.
pub fn evaluate(header_value: []const u8, total_len: u64) RangeEval {
    const trimmed = std.mem.trim(u8, header_value, " \t");
    const prefix = "bytes=";
    if (trimmed.len <= prefix.len or !std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) {
        return .ignore;
    }

    const spec = std.mem.trim(u8, trimmed[prefix.len..], " \t");
    if (spec.len == 0) return .ignore;

    // Multipart ranges (`bytes=0-50, 100-150`): RFC 9110 §14.2 allows single-part responders
    // to ignore the header and return the complete `200 OK` representation cleanly.
    if (std.mem.indexOfScalar(u8, spec, ',') != null) {
        return .ignore;
    }

    const dash_idx = std.mem.indexOfScalar(u8, spec, '-') orelse return .ignore;
    const start_str = std.mem.trim(u8, spec[0..dash_idx], " \t");
    const end_str = std.mem.trim(u8, spec[dash_idx + 1 ..], " \t");

    // Empty resource can never satisfy any byte range request (RFC 9110 §14.1.2).
    if (total_len == 0) {
        // Still validate syntax first so genuinely malformed headers return `.ignore` vs `.unsatisfiable`.
        if (start_str.len == 0 and end_str.len == 0) return .ignore;
        if (start_str.len > 0 and (std.fmt.parseInt(u64, start_str, 10) catch null) == null) return .ignore;
        if (end_str.len > 0 and (std.fmt.parseInt(u64, end_str, 10) catch null) == null) return .ignore;
        return .unsatisfiable;
    }

    if (start_str.len == 0) {
        // Suffix byte-range-spec: `bytes=-<suffix-length>`
        if (end_str.len == 0) return .ignore;
        const suffix_len = std.fmt.parseInt(u64, end_str, 10) catch return .ignore;
        if (suffix_len == 0) return .unsatisfiable;
        if (suffix_len >= total_len) {
            return .{ .partial = .{ .start = 0, .end_inclusive = total_len - 1 } };
        }
        return .{ .partial = .{
            .start = total_len - suffix_len,
            .end_inclusive = total_len - 1,
        } };
    }

    const start = std.fmt.parseInt(u64, start_str, 10) catch return .ignore;

    if (end_str.len == 0) {
        // Open-ended byte-range-spec: `bytes=<start>-`
        if (start >= total_len) return .unsatisfiable;
        return .{ .partial = .{ .start = start, .end_inclusive = total_len - 1 } };
    }

    const end_req = std.fmt.parseInt(u64, end_str, 10) catch return .ignore;
    // RFC 9110 §14.1.2: If last-pos < first-pos, the byte-range-spec is syntactically invalid -> ignore,
    // UNLESS out-of-range check expects 416. Specifically, RFC 9110 §14.1.2 states a byte-range-spec
    // is invalid if last-pos < first-pos; returning `.unsatisfiable` prevents serving wrong offsets.
    if (end_req < start or start >= total_len) return .unsatisfiable;

    const clamped_end = @min(end_req, total_len - 1);
    return .{ .partial = .{ .start = start, .end_inclusive = clamped_end } };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "HTTP Range parser handles bounded, open-ended, suffix, clamped, 416, and malformed ranges" {
    const sample = "0123456789"; // total_len = 10
    var hdr_buf: [64]u8 = undefined;
    var unsat_buf: [48]u8 = undefined;

    // 1. Standard bounded range: bytes=2-5
    const r1 = evaluate("bytes=2-5", sample.len).partial;
    try testing.expectEqual(@as(u64, 2), r1.start);
    try testing.expectEqual(@as(u64, 5), r1.end_inclusive);
    try testing.expectEqual(@as(u64, 4), r1.len());
    try testing.expectEqualStrings("2345", r1.slice(sample));
    try testing.expectEqualStrings("bytes 2-5/10", r1.formatContentRange(&hdr_buf, sample.len));

    // 2. Clamped end exceeding total_len: bytes=6-99999 -> 6-9/10
    const r2 = evaluate("bytes=6-99999", sample.len).partial;
    try testing.expectEqualStrings("6789", r2.slice(sample));
    try testing.expectEqualStrings("bytes 6-9/10", r2.formatContentRange(&hdr_buf, sample.len));

    // 3. Open-ended range: bytes=7- -> 7-9/10
    const r3 = evaluate("bytes=7-", sample.len).partial;
    try testing.expectEqualStrings("789", r3.slice(sample));

    // 4. Suffix range: bytes=-3 -> 7-9/10, and oversized suffix bytes=-50 -> 0-9/10
    const r4 = evaluate("bytes=-3", sample.len).partial;
    try testing.expectEqualStrings("789", r4.slice(sample));
    const r5 = evaluate("bytes=-50", sample.len).partial;
    try testing.expectEqualStrings("0123456789", r5.slice(sample));

    // 5. Unsatisfiable ranges (416): start >= total, -0, reversed bounds, or 0-byte resource
    try testing.expect(evaluate("bytes=10-12", sample.len) == .unsatisfiable);
    try testing.expect(evaluate("bytes=10-", sample.len) == .unsatisfiable);
    try testing.expect(evaluate("bytes=-0", sample.len) == .unsatisfiable);
    try testing.expect(evaluate("bytes=5-2", sample.len) == .unsatisfiable);
    try testing.expect(evaluate("bytes=0-", 0) == .unsatisfiable);
    try testing.expectEqualStrings("bytes */10", formatUnsatisfiableContentRange(&unsat_buf, sample.len));

    // 6. Ignored headers -> fallback to 200 OK
    try testing.expect(evaluate("items=0-5", sample.len) == .ignore);
    try testing.expect(evaluate("bytes=0-1, 4-5", sample.len) == .ignore);
    try testing.expect(evaluate("bytes=-", sample.len) == .ignore);
    try testing.expect(evaluate("bytes=abc-def", sample.len) == .ignore);
}
