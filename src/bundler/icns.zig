//! Pure-Zig `.icns` (Apple icon) writer — P2 #17 (`src/bundler/icns.zig`).
//!
//! The macOS icon container is a trivially deterministic format:
//!
//! ```text
//! "icns" | u32be total_length
//!   ┌─ u32 type ("ic07", "ic08", …) | u32be entry_length (= 8 + data.len) | data
//!   └─ repeated, in the order the caller supplies (we sort the kinds for reproducibility)
//! ```
//!
//! `iconutil` is a macOS-only external tool, so generating the container ourselves keeps the
//! 3-OS build identical and `link_libc = false`. The icon *images* are PNG bytes supplied by the
//! caller; ziggurats does not need an image encoder to wrap them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const magic = "icns";
pub const header_size = 8;
pub const entry_header_size = 8;
pub const max_entries = 32;

pub const IcnsError = error{
    OutOfMemory,
    TooManyEntries,
    BadType,
    TooLarge,
    Truncated,
    BadLength,
};

pub const Entry = struct {
    /// Four ASCII bytes, e.g. `ic07` (128×128 PNG) or `ic10` (1024×1024 PNG).
    kind: [4]u8,
    bytes: []const u8,
};

/// Common PNG-backed `icns` types and their nominal pixel sizes.
pub const kinds = struct {
    pub const icon_16: [4]u8 = "ic04".*;
    pub const icon_32: [4]u8 = "ic05".*;
    pub const icon_128: [4]u8 = "ic07".*;
    pub const icon_256: [4]u8 = "ic08".*;
    pub const icon_512: [4]u8 = "ic09".*;
    pub const icon_1024: [4]u8 = "ic10".*;
};

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, &a.kind, &b.kind) == .lt;
}

fn writeU32be(dest: []u8, value: u32) void {
    dest[0] = @intCast(value >> 24);
    dest[1] = @intCast((value >> 16) & 0xff);
    dest[2] = @intCast((value >> 8) & 0xff);
    dest[3] = @intCast(value & 0xff);
}

fn readU32be(src: []const u8) u32 {
    return (@as(u32, src[0]) << 24) | (@as(u32, src[1]) << 16) | (@as(u32, src[2]) << 8) | @as(u32, src[3]);
}

/// Builds a deterministic `.icns`. Duplicate kinds are rejected (an icon with two `ic08` blobs is
/// ambiguous), entries are sorted by kind, and all lengths are big-endian.
pub fn buildAlloc(allocator: Allocator, entries: []const Entry) IcnsError![]u8 {
    if (entries.len > max_entries) return error.TooManyEntries;
    var total: u64 = header_size;
    for (entries) |entry| {
        for (entry.kind) |c| {
            if (!std.ascii.isPrint(c)) return error.BadType;
        }
        total += entry_header_size + entry.bytes.len;
    }
    if (total > std.math.maxInt(u32)) return error.TooLarge;

    const sorted = try allocator.dupe(Entry, entries);
    defer allocator.free(sorted);
    std.mem.sort(Entry, sorted, {}, lessEntry);
    for (0..sorted.len -| 1) |i| {
        if (std.mem.eql(u8, &sorted[i].kind, &sorted[i + 1].kind)) return error.BadType;
    }

    const out = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(out);
    @memcpy(out[0..4], magic);
    writeU32be(out[4..8], @intCast(total));
    var cursor: usize = header_size;
    for (sorted) |entry| {
        @memcpy(out[cursor .. cursor + 4], &entry.kind);
        writeU32be(out[cursor + 4 .. cursor + 8], @intCast(entry_header_size + entry.bytes.len));
        cursor += entry_header_size;
        @memcpy(out[cursor .. cursor + entry.bytes.len], entry.bytes);
        cursor += entry.bytes.len;
    }
    return out;
}

/// Parses a container produced by `buildAlloc` (also useful for CI parity checks).
pub fn parseAlloc(allocator: Allocator, blob: []const u8) IcnsError![]Entry {
    if (blob.len < header_size or !std.mem.eql(u8, blob[0..4], magic)) return error.Truncated;
    const declared = readU32be(blob[4..8]);
    if (declared != blob.len) return error.BadLength;
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |e| allocator.free(e.bytes);
        out.deinit(allocator);
    }
    var cursor: usize = header_size;
    while (cursor < blob.len) {
        if (blob.len - cursor < entry_header_size) return error.Truncated;
        var kind: [4]u8 = undefined;
        @memcpy(&kind, blob[cursor .. cursor + 4]);
        const entry_len = readU32be(blob[cursor + 4 .. cursor + 8]);
        if (entry_len < entry_header_size or cursor + entry_len > blob.len) return error.BadLength;
        const data = try allocator.dupe(u8, blob[cursor + entry_header_size .. cursor + entry_len]);
        try out.append(allocator, .{ .kind = kind, .bytes = data });
        cursor += entry_len;
    }
    return out.toOwnedSlice(allocator);
}

test "P2 #17: .icns is deterministic, sorted, big-endian and round-trips" {
    const png_a = "PNG-A";
    const png_b = "PNG-B";
    const entries = [_]Entry{
        .{ .kind = kinds.icon_256, .bytes = png_b },
        .{ .kind = kinds.icon_128, .bytes = png_a },
    };
    const first = try buildAlloc(testing.allocator, &entries);
    defer testing.allocator.free(first);
    const second = try buildAlloc(testing.allocator, &[_]Entry{
        .{ .kind = kinds.icon_128, .bytes = png_a },
        .{ .kind = kinds.icon_256, .bytes = png_b },
    });
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);
    try testing.expectEqualStrings("icns", first[0..4]);
    try testing.expectEqual(@as(u32, 8 + 13 + 13), readU32be(first[4..8]));
    // Sorted by kind: ic07 before ic08.
    try testing.expectEqualStrings("ic07", first[8..12]);
    try testing.expectEqualStrings("ic08", first[21..25]);

    const parsed = try parseAlloc(testing.allocator, first);
    defer {
        for (parsed) |e| testing.allocator.free(e.bytes);
        testing.allocator.free(parsed);
    }
    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectEqualStrings("ic07", &parsed[0].kind);
    try testing.expectEqualStrings(png_a, parsed[0].bytes);
    try testing.expectEqualStrings(png_b, parsed[1].bytes);
}

test "P2 #17: duplicate kinds, bad magic and truncated blobs are rejected" {
    const one = [_]Entry{.{ .kind = kinds.icon_128, .bytes = "x" }};
    const dup = [_]Entry{
        .{ .kind = kinds.icon_128, .bytes = "x" },
        .{ .kind = kinds.icon_128, .bytes = "y" },
    };
    try testing.expectError(error.BadType, buildAlloc(testing.allocator, &dup));
    try testing.expectError(error.Truncated, parseAlloc(testing.allocator, "icns"));
    const good = try buildAlloc(testing.allocator, &one);
    defer testing.allocator.free(good);
    try testing.expectError(error.BadLength, parseAlloc(testing.allocator, good[0 .. good.len - 1]));
}
